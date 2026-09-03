extends Node3D

var Right_button_down:bool
var camera_rotation:Vector2

@export_range(0.001,0.1,0.001) var look_speed:float
@export var speed_walk:float = 2.0 

func _physics_process(_delta: float) -> void:
	easy_motion()

func easy_motion()->void:
	if Input.is_action_just_pressed("camera_move_mode"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.is_action_just_released("camera_move_mode"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if	Input.is_action_pressed("move_forward"):
		translate(Vector3.FORWARD*speed_walk)
	if	Input.is_action_pressed("move_backward"):
		translate(-Vector3.FORWARD*speed_walk)
	if	Input.is_action_pressed("move_left"):
		translate(Vector3.LEFT*speed_walk)
	if	Input.is_action_pressed("move_right"):
		translate(Vector3.RIGHT*speed_walk)
	if Input.is_key_pressed(KEY_E):
		translate(Vector3.UP*speed_walk)
	if Input.is_key_pressed(KEY_Q):
		translate(Vector3.DOWN*speed_walk)



func _input(_event: InputEvent) -> void:
	if _event is InputEventMouseButton:
		if _event.button_index  == MOUSE_BUTTON_RIGHT:
			Right_button_down = _event.pressed
	
	if _event is InputEventMouseMotion and Right_button_down:
		camera_rotation -= _event.relative*look_speed
		transform.basis = Basis()
		rotate_object_local(Vector3(0,1,0),camera_rotation.x)
		rotate_object_local(Vector3(1,0,0),camera_rotation.y)




		
