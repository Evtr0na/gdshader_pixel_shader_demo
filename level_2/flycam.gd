extends Camera3D
## Minimal free-fly camera for the Shadow Glass demo: WASD + E/Q vertical,
## Shift to sprint, right-click to capture/release the mouse for mouselook.

@export var move_speed := 4.0
@export var look_speed := 0.003

var _yaw := 0.0
var _pitch := 0.0
var _captured := true


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_captured = not _captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * look_speed
		_pitch = clampf(_pitch - event.relative.y * look_speed, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir += forward
	if Input.is_key_pressed(KEY_S):
		dir -= forward
	if Input.is_key_pressed(KEY_D):
		dir += right
	if Input.is_key_pressed(KEY_A):
		dir -= right
	if Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		dir -= Vector3.UP
	dir = dir.normalized()
	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 2.0
	global_position += dir * speed * delta