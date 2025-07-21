extends Node

# This is a clock for both the client and the server/host. The client's clock attempt to run ahead 
# of the server's clock by a fixed amount to facilitate client prediction/reconcillation and lag 
# compensation.

##################################################################################################
# Tunable consts
##################################################################################################

const ideal_client_tick_buffer := 9 # how far ahead client should try and stay. 1 tick == 16.6667ms, so 150ms buffer
const min_client_server_tick_diff := 6 # lower limit of allowable tick buffer range from server, aboslute difference and not relative to ideal_client_tick_buffer
const max_client_server_tick_diff := 20 # upper limit of allowable tick buffer range, aboslute difference and not relative to ideal_client_tick_buffer
const sync_period_ms := 100 # how often we send/receive sync packets

const averaging_sample_size := 10 # Used for averaging tick adjustment over the last 10 sync packets to avoid jitter
								  # This is how many packets we wait to receive before evaluating last_offsets to get an average of how far off the server time we are

##################################################################################################
# Shared variables
##################################################################################################

var tick := 0

##################################################################################################
# Client variables
##################################################################################################

var tick_adjustment := 0 # a one-time correction applied at next tick
var average_latency_in_ticks := 0
var sync_timer : Timer = null # handles periodic client sync requests
var last_offsets := [] # stores tick corrections before averaging

##################################################################################################
# Shared functions
##################################################################################################

func _ready() -> void:
	process_physics_priority = -100 # Ensure the clock runs first or at least early in the physics step so all systems get the current tick consistently
	
func _physics_process(_delta: float) -> void:
	advance_tick() # Advance the tick every physics frame (i.e., 60 times per second)

func advance_tick() -> void:
	tick += 1 + tick_adjustment  # Increments the tick, possibly adjusting if out of sync
	tick_adjustment = 0 # resets tick adjustment after making the adjustment (or having done nothing bc it was 0)
	
static func ms_to_ticks(ms: int) -> int:
	return (int) (ceil( (ms / 1000.0) * Engine.physics_ticks_per_second)) # Converts milliseconds to ticks, rounding up

##################################################################################################
# Client functions
##################################################################################################

func start_sync() -> void: # Called on client startup: sends initial_sync() to server and starts the periodic syncing timer
	initial_sync.rpc_id(1) # in response to this line, the server responds with the current tick (reset_tick.rpc_id(multiplayer.get_remote_sender_id(), tick))
	start_periodic_sync()  # start sending sync packets to server
	
	
@rpc("reliable")
func reset_tick(tick_: int) -> void: # The server sends its current tick so the client can sync up initially
	tick = tick_					 # see initial_sync(): reset_tick.rpc_id(multiplayer.get_remote_sender_id(), tick)
									 # in start_sync() we call initial_sync.rpc_id(1)


func start_periodic_sync() -> void: # Creates and starts a Timer that will send sync packets every 100 ms (sync_period_ms)
	if sync_timer != null:
		return
	sync_timer = Timer.new()
	sync_timer.wait_time = sync_period_ms / 1000.0
	sync_timer.one_shot = false
	sync_timer.connect("timeout", send_sync_packet)
	add_child(sync_timer)
	sync_timer.start()
	

# called every sync_period_ms
func send_sync_packet() -> void: # Client sends its client engine tick time in ms to server using an unreliable RPC
	server_receive_sync_packet.rpc_id(1, Time.get_ticks_msec()) # this is where we get client_sync_packet_time_ms in calc_offset


#This computes how far the client tick is off from the ideal buffer ahead of server
static func calc_offset(local_time_ms: int,							# the local engine ms tick (Time.get_ticks_msec())
						client_sync_packet_time_ms: int,			# the local engine ms tick at time of last sync packet sent
						server_tick: int,							# the current server tick
						client_tick: int,							# the current client tick
						ideal_client_tick_buffer_: int,				# desired client buffer time ahead of server
						min_client_server_tick_diff_: int,			# minimum range of allowable difference in tick from server
						max_client_server_tick_diff_: int) -> int:  # maximum range of allowable difference in tick from server
	var instantaneous_latency_in_ms := (local_time_ms - client_sync_packet_time_ms) / 2 # half round trip time
	# we've just received a packet. we get the local time minus the time we last sent a packet, which is the total trip time.
	# but we divide it by two, because we want the Half Round Trip Time. we are asking 'how old is this data i have received?'
	# "what time was it on the server when they sent this?"
	var instantaneous_latency_in_ticks := ms_to_ticks(instantaneous_latency_in_ms) # convert the latency (ms) to our server ticks
	MultiplayerManager.ping_in_ms = instantaneous_latency_in_ms # TODO this is atually the half round trip ping, and not the RTT (actual player ping)
	
	# the formula we are trying to achieve is the below:
	# client_tick - server_tick = latency_in_ticks + client_tick_buffer, just get our latency and add our buffer
	var client_tick_buffer := client_tick - server_tick - instantaneous_latency_in_ticks # How many ticks ahead the client is, after subtracting latency
	if client_tick_buffer < min_client_server_tick_diff_ or  client_tick_buffer > max_client_server_tick_diff_: 
		# tick difference betwene client and server is less than 6 or greater than 20
		# we're outside our allowable range, we need to return an offset that would appropriately nudge us back into our allowable
		# range and closer to our ideal_client_tick_buffer
		return ideal_client_tick_buffer_ - client_tick_buffer
	return 0 # otherwise we just send 0 offset back, because we are in allowable range and no adjustment is needed


@rpc("unreliable")
func client_receive_sync_packet(client_time: int, server_tick: int) -> void:
	# calculates our tick difference from the server and adds it to an array
	last_offsets.push_front(calc_offset(Time.get_ticks_msec(), 		# local time ms
										client_time, 				# local time ms at time of last sync packet sent
										server_tick, 
										tick, 
										ideal_client_tick_buffer, 
										min_client_server_tick_diff, 
										max_client_server_tick_diff))

	if len(last_offsets) > averaging_sample_size: # if we have reached our sample size threshold (default 10), add up our tick differences
		var sum := 0
		for each: int in last_offsets:
			sum += each
		tick_adjustment = (int) (ceil((sum / len(last_offsets) ))) # get our tick_adjustment based off the summation of all tick differences in array
		last_offsets = [] # clear the array and start resampling

##################################################################################################
# Server functions
##################################################################################################

@rpc("any_peer", "call_remote", "reliable")
# when a client requests initial_sync(), the server responds with the current tick
func initial_sync() -> void:
	reset_tick.rpc_id(multiplayer.get_remote_sender_id(), tick)


@rpc("any_peer", "call_remote", "unreliable")
# When server gets a sync packet from a client, it replies with the current server tick and echoes back the client time to calculate round-trip
func server_receive_sync_packet(client_time: int) -> void:
	client_receive_sync_packet.rpc_id(multiplayer.get_remote_sender_id(), client_time, tick)
