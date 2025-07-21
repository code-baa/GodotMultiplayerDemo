extends Node

# TODO: consolidate with proto files to avoid duplicates
enum movement_input {NONE, MOVE_RIGHT, MOVE_LEFT, MOVE_FORWARD, MOVE_BACKWARD}
enum states {IDLE, MOVE, ATTACK, DEAD, JUMPING, FALLING, LANDING}
enum directions {RIGHT, LEFT, FORWARD, BACKWARD}
