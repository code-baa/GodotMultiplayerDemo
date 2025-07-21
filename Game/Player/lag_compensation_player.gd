extends Area3D

# Represents the position and shape of a player when it was hit by a projectile as reported by a 
# client and to be verified by the server
class_name LagCompensationPlayer

@onready var collision_shape_dd := $CollisionShape3D
var actual_player: Player

func _ready() -> void:
	if actual_player != null:
		collision_shape_dd = actual_player.collision_shape_3d.duplicate()
