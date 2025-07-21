extends Node

# The MultiplayerManager contains all of the networking related code, for both the server and the client

const Player = preload("res://Game/Player/player.tscn")
const LagCompensationPlayer = preload("res://Game/Player/lag_compensation_player.tscn")
const Projectile = preload("res://Game/Projectile/projectile.tscn")
const LagCompensationProjectile = preload("res://Game/Projectile/lag_compensation_projectile.tscn")
const enums = preload("res://Game/enums.gd")
const GameState = preload("res://Game/proto/game_state.gd")
const PlayerInputProto = preload("res://Game/proto/player_input.gd")

const PORT = 6969
const MAX_CLIENTS = 20
const clock_sync_delay := 3.0 # how long to wait at game start, allowing players to sync clocks with server
const player_connection_wait := .5 # how long to wait once player initiates connection to initialize them

var is_host := false
var is_server := false

##################################################################################################
# server variables
##################################################################################################

var player_dict := {}
var projectile_dict := {}

const hard_reset_server_client_reconciliation_distance = 100     # the distance of player from servers expected position to cause a hard reset
const soft_correction_server_client_reconciliation_distance = 1  # the distance of player from servers expected position to cause a soft interpolation
const soft_correction_rate = .01							     # how quickly we should interpolate to where the server expected us
var server_tick_rate := 1.0 / Engine.physics_ticks_per_second    # the millisecond time for each tick (for a physics tick of 60 this is 0.016666)

signal player_connected_to_lobby(player_name: String)
signal player_disconnected_from_lobby(player_name: String)

signal projectile_added(projectile: Projectile)
signal lag_compensation_player_added(lag_compensation_player: LagCompensationPlayer)				# TODO this may not be important for PVE
signal lag_compensation_projectile_added(lag_compensation_projectile: LagCompensationProjectile)	# TODO this may not be important for PVE

##################################################################################################
# client variables
##################################################################################################

var player: Player
var ping_in_ms := 0
var username: String
var server_tick: int

signal lobby_player_list_updated(player_names: Array)

signal ping_calculated(ping: int)
signal player_added(player_: Player)
signal player_removed(player_id: int)
signal player_updated(player_proto: GameState.GameState.PlayerProto)
signal projectile_added_proto(projectile: GameState.GameState.ProjectileProto)

##################################################################################################
# Shared functions
##################################################################################################

func reset() -> void: # Fully resets networking state and data, for returning to main menu
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	player = null
	username = ""
	player_dict = {}
	projectile_dict = {}
	is_host = false

##################################################################################################
# Client functions
##################################################################################################

@rpc("reliable")
func start_loading() -> void:
	Clock.start_sync() 					 # get current tick from server and start sending sync packets to server
	GameManager.client_start_loading()	 # change scene to loading


@rpc("reliable")
func game_started() -> void:
	GameManager.client_game_started()    # transition client into active, main game state
	

# Initializes the client’s network connection to the server and stores their username
func join_lobby(ip_address: String, username_: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	peer.create_client(ip_address, PORT)
	multiplayer.multiplayer_peer = peer
	username = username_
	
	
@rpc("reliable")
# Server notifies the client of the updated list of players in the lobby
func client_lobby_player_list_updated(player_names: Array) -> void:
	lobby_player_list_updated.emit(player_names)
	
	
@rpc("reliable")
# Server tells client to instantiate their local player. Then, it sends their username to the server
func setup_lobby_player() -> void:
	player = Player.instantiate()
	player.set_id(multiplayer.get_unique_id())
	player.this_player = true
	player.set_username(username)
	set_server_username.rpc_id(1, username)


@rpc("reliable")
# Used by the client to manually send its username again. Likely used after reconnection or late join
func retrieve_username() -> void:
	set_server_username.rpc_id(1, username)
	
	
@rpc("reliable")
# Server sends corrected/adjusted username back to the client 
func set_client_username(username_: String) -> void:
	username = username_
	if player != null:
		player.set_username(username_)
	
	
@rpc("reliable")
# Client predicted position vs. server expected position too great causing a hard positional reset
func client_hard_reset_position(position: Vector3) -> void:
	player.set_position(position)


@rpc("unreliable")
func receive_game_state(game_state: PackedByteArray) -> void:
	# Early return if this is the host or not in the main game client state. Hosts don't need state from themselves
	if is_host or GameManager.current_state != GameManager.game_state.MAIN_GAME_CLIENT:
		return
		
	# Deserialize the received PackedByteArray into a usable GameState object. Ignore if 0 code (OK) received meaning no errors
	var gs := GameState.GameState.new()
	var result := gs.from_bytes(game_state)
	if result != GameState.PB_ERR.NO_ERRORS:
		return
	
	# Prep tracking structure for players seen in this state. Early return if scene isn’t ready yet.
	var player_ids := {}
	if get_tree().current_scene == null:
		return
	var other_players: Dictionary = get_tree().current_scene.other_players
	
	for p in gs.get_players():		  # Collect all player IDs from this update
		player_ids[p.get_id()] = true # to later prune disconnected players.
		if p.get_id() == multiplayer.get_unique_id(): 
			# server/client reconciliation
			server_tick = gs.get_tick() # if the player is ourselves, reconcile our predicted state with the authoritative one from server.
			if server_tick > Clock.tick:
				print("ruh roh: " + str(server_tick) + " > " + str(Clock.tick))
			if player == null:
				continue
			player.prune_old_inputs(server_tick) # Remove old inputs 
			if player.previous_inputs_and_positions.get(server_tick) == null: #check if we have historical data for this tick
				continue
			# get our client position for this tick (our local prediction)
			var client_position: Vector3 = player.previous_inputs_and_positions.get(server_tick).get("position")
			if client_position == null:
				continue
			# 
			var diff := client_position.distance_to(Vector3(p.get_position_x(), p.get_position_y(), p.get_position_z()))
			if diff > hard_reset_server_client_reconciliation_distance:
				player.position.x = p.get_position_x()
				player.position.y = p.get_position_y()
				player.position.z = p.get_position_z()
				player.state = p.get_state()
				player.reapply_inputs(server_tick, server_tick_rate)
			elif p.get_state() == enums.states.IDLE and player.state == enums.states.IDLE and diff > soft_correction_server_client_reconciliation_distance:
				player.position.x += (p.get_position_x() - player.position.x) * soft_correction_rate
				player.position.y += (p.get_position_y() - player.position.y) * soft_correction_rate
				player.position.z += (p.get_position_z() - player.position.z) * soft_correction_rate
			
			player.health = p.get_health()
			ping_calculated.emit(ping_in_ms)
			continue
		
		if p.get_id() not in other_players:
			var new_player: = Player.instantiate()
			new_player.set_id(p.get_id())
			player_added.emit(new_player)
		player_updated.emit(p)
	
	for player_id: int in other_players.keys():
		if not player_id in player_ids:
			player_removed.emit(player_id)
	
	var other_player_projectiles: Dictionary = get_tree().current_scene.other_player_projectiles
	for p in gs.get_projectiles():
		if p.get_owner_id() == multiplayer.get_unique_id():
			continue
		if p.get_owner_id() not in other_player_projectiles or p.get_id() not in other_player_projectiles[p.get_owner_id()]:
			projectile_added_proto.emit(p)
			

func report_hit(projectile_id: int, victim_id: int, shooter_id: int) -> void:
	if is_host:
		return
	hit_reported.rpc_id(1, projectile_id, victim_id, shooter_id, server_tick, Clock.tick)

##################################################################################################
# Server functions
##################################################################################################


####################################
# Dedicated Server
####################################

func setup_multiplayer_server() -> void:
	# Initialize this peer as a dedicated server
	is_host = true
	var peer := ENetMultiplayerPeer.new()
	peer.create_server(PORT, MAX_CLIENTS)
	peer.peer_connected.connect(_on_peer_connected_to_lobby)
	peer.peer_disconnected.connect(_on_peer_disconnected_from_lobby)
	multiplayer.multiplayer_peer = peer
	
func setup_server_lobby() -> void:
	# Used for dedicated server hosting lobby
	setup_multiplayer_server()
	is_server = true

###################################
###################################

	
func setup_host_lobby(_username: String) -> void:
	# Used when the host is also a client (host-client)
	setup_multiplayer_server()
	username = _username
	player = Player.instantiate()
	player.set_id(1)
	player.this_player = true
	player.set_username(username)
	player_dict[1] = player
	player_connected_to_lobby.emit(username)
	update_lobby_player_list()
	
	
func _on_peer_connected_to_lobby(id: int) -> void:
	# Called when a new client connects to the lobby
	var new_player := Player.instantiate()
	new_player.set_id(id)
	player_dict[id] = new_player
	await get_tree().create_timer(player_connection_wait).timeout   # delay to allow player to connect
	setup_lobby_player.rpc_id(id) 									# Call client to set up its player
	
	
func _on_peer_disconnected_from_lobby(id: int) -> void:
	#  Cleanup when a client disconnects
	player_disconnected_from_lobby.emit(player_dict[id].username)
	player_dict.erase(id)
	update_lobby_player_list()


func setup_game_server() -> void:
	# Begin game for dedicated server
	start_loading.rpc() 											# Ask clients to load scene
	var mg: MainGame = get_tree().current_scene
	for player_: Player in player_dict.values():
		mg.add_child(player_)										# Add all players to scene
	# Give clients time to sync their clocks
	await get_tree().create_timer(clock_sync_delay).timeout			# wait for players to sync their clocks with servers
	GameManager.server_game_start()


func setup_game_host() -> void:
	# Begin game for when the host is also a client (host-client)
	start_loading.rpc() 											# Ask clients to load
	var mg: MainGame = get_tree().current_scene
	for player_: Player in player_dict.values():
		if player_.id != 1:										    
			mg.add_child(player_)									# Add all other players except host, since we've initialized it already (see setup_host_lobby())
	# Give clients time to sync their clocks
	await get_tree().create_timer(clock_sync_delay).timeout			# wait for players to sync their clocks with servers
	GameManager.host_game_start()


func start_game_for_players() -> void:
	# Notify all clients game has officially started
	game_started.rpc()


@rpc("any_peer", "call_remote", "reliable")
# Clients send their username to server for lobby display
func set_server_username(username_: String) -> void:
	var username_to_set := username_
	while !username_is_unique(username_to_set):
		username_to_set = username_to_set + "1"
	player_dict[multiplayer.get_remote_sender_id()].set_username(username_to_set)
	player_connected_to_lobby.emit(username_to_set)
	if username_ != username_to_set:
		set_client_username.rpc_id(multiplayer.get_remote_sender_id(), username_to_set)
	update_lobby_player_list()


func update_lobby_player_list() -> void:
	# Sends the full lobby player name list to all clients
	var player_names := []
	for player_: Player in player_dict.values():
		player_names.append(player_.username)
	client_lobby_player_list_updated.rpc(player_names)


# Updates the initial player lobby list for host mode
func initial_lobby_update() -> void:
	if player != null:
		player_connected_to_lobby.emit(username)


func username_is_unique(username_: String) -> bool:
	# Check if a given username is unique across all connected players
	for player_: Player in player_dict.values():
		if player_.username == username_:
			# username was found in our list already taken
			return false
	return true


@rpc("any_peer", "call_remote", "unreliable")
# Called by clients to send their input to the server
# Only the server/host will process it
func recieve_player_input(inputs_proto: PackedByteArray) -> void:
	if not is_host:
		return
	player_dict[multiplayer.get_remote_sender_id()].update_input_dict(inputs_proto, Clock.tick)


func add_projectile(projectile: Projectile) -> void:
	if projectile.owner_id not in projectile_dict:
		projectile_dict[projectile.owner_id] = {}
	projectile_dict[projectile.owner_id][projectile.id] = projectile
	projectile_added.emit(projectile)
	
	
func remove_projectile(projectile: Projectile) -> void:
	projectile_dict[projectile.owner_id].erase(projectile.id)
	
	
func hard_reset_position(player_id: int, position: Vector3) -> void:
	player_dict[player_id].set_position(position)
	if player_id != 1:
		client_hard_reset_position.rpc_id(player_id, position)
	
	
func _physics_process(_delta: float) -> void:
	if not is_host or GameManager.current_state not in [GameManager.game_state.MAIN_GAME_SERVER, GameManager.game_state.MAIN_GAME_HOST]:
		return
		
	if player != null:
		player.prune_old_inputs(server_tick)

	var game_state := GameState.GameState.new()
	game_state.set_tick(Clock.tick)
	for player_id: int in player_dict.keys():
		var p := game_state.add_players()
		p.set_id(player_id)
		p.set_username(player_dict[player_id].username)
		p.set_position_x(player_dict[player_id].position.x)
		p.set_position_y(player_dict[player_id].position.y)
		p.set_position_z(player_dict[player_id].position.z)
		p.set_state(player_dict[player_id].state)
		p.set_health(player_dict[player_id].health)
	
	for player_id: int in projectile_dict.keys():
		for projectile_id: int in projectile_dict[player_id]:
			var p := game_state.add_projectiles()
			p.set_id(projectile_id)
			p.set_owner_id(player_id)
			p.set_position_x(projectile_dict[player_id][projectile_id].position.x)
			p.set_position_y(projectile_dict[player_id][projectile_id].position.y)
			p.set_position_z(projectile_dict[player_id][projectile_id].position.z)
			p.set_velocity_x(projectile_dict[player_id][projectile_id].velocity.x)
			p.set_velocity_y(projectile_dict[player_id][projectile_id].velocity.y)
			p.set_velocity_z(projectile_dict[player_id][projectile_id].velocity.z)
			p.set_damage(projectile_dict[player_id][projectile_id].damage)
	
	receive_game_state.rpc(game_state.to_bytes())
	
	
@rpc("any_peer", "call_remote", "reliable")
func hit_reported(projectile_id: int, victim_id: int, shooter_id: int, client_server_tick: int, client_tick: int) -> void:
	# Verify the client reported hit by checking that the projectile at time client_tick does indeed
	# collide with the victim at time client_server_tick by adding phantom players and projectiles 
	# that are only used to check this collision
	if victim_id not in player_dict:
		return
	var lag_compensation_player := LagCompensationPlayer.instantiate()
	lag_compensation_player.actual_player = player_dict[victim_id]
	if client_server_tick not in lag_compensation_player.actual_player.previous_positions:
		return
	lag_compensation_player.position = lag_compensation_player.actual_player.previous_positions[client_server_tick]
	if shooter_id not in projectile_dict or projectile_id not in projectile_dict[shooter_id]:
		return
	var lag_compensation_projectile := LagCompensationProjectile.instantiate()
	lag_compensation_projectile.actual_projectile = projectile_dict[shooter_id][projectile_id]
	lag_compensation_projectile.victim = lag_compensation_player
	lag_compensation_projectile.damage = lag_compensation_projectile.actual_projectile.damage
	var current_server_tick := Clock.tick
	if client_tick < current_server_tick:
		if client_tick not in lag_compensation_projectile.actual_projectile.previous_positions:
			return
		lag_compensation_projectile.position = lag_compensation_projectile.actual_projectile.previous_positions[client_tick]
	else: 
		lag_compensation_projectile.position = lag_compensation_projectile.actual_projectile.apply_physics((client_tick - current_server_tick) * server_tick_rate)
	
	lag_compensation_player_added.emit(lag_compensation_player)
	lag_compensation_projectile_added.emit(lag_compensation_projectile)
