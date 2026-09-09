extends Node3D
## Slowly oscillating occluder for testing anchor staleness / disocclusion.


@export var axis := Vector3(1, 0, 0)
@export var distance := 4.0
@export var speed := 1.5

var _t := 0.0


func _process(delta: float) -> void:
	_t += delta * speed
	position = axis * (sin(_t) * distance)