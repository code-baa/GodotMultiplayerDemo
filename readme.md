# Godot 4.4 Multiplayer Authoritative Server 3D Demo

## About

This project is a Godot 4.4 implementation of a multiplayer game using an authoritative server architecture with client side prediction, server reconciliation, and lag compensation.

### Originally made by [Seaciety](https://github.com/seaciety), this version features that same implementation in 3D. 
**Lag compensation and PVP projectile hit detection is not yet configured and does not work in this version**

## Features

☑️ Client side prediction and server reconciliation

🔲 Lag compensation for hit detection

☑️ Client/Server clock synchronization

☑️ Pregame lobby

☑️ Server mode, client mode and host mode

☑️ Protobufs used for network messages


## Outline

### multiplayer_manager.gd

The MultiplayerManager contains the functions that send messages back and forth between the client and server. This also includes the logic for client side prediction, server reconciliation, and lag compensation

### game_manager.gd

The GameManager is a state machine that switches between scenes and calls transition functions as needed.

### clock.gd

The Clock is used to synchronize time between the server and the client.

### player.gd

The player contains the logic to apply player inputs and apply the game physics to the players in the shared world. The same code runs on both the server and the client (for client side prediction), which allows the server and client to be automatically in sync under perfect conditions.

 ## Godot Addons used in this project
 - [Original codebase by seaciety](https://github.com/seaciety/GodotMultiplayerDemo)
 - [godobuf](https://github.com/oniksan/godobuf) to generate the protobuf files
 - [gut](https://github.com/bitwes/Gut) for unit testing

 ## Inspirations

  - https://gabrielgambetta.com/client-server-game-architecture.html
  - https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization
