class_name ShadowGlassSystem
extends Node
## Owns three capture banks (Live, AnchorA, AnchorB), drives the anchor
## capture / crossfade state machine, and installs the ReprojectionEffect on
## the main camera. Main-thread only (render thread work lives in the effects).

enum CaptureState { IDLE, CAPTURE_READY, BLENDING }

const RESOLUTIONS: Array[int] = [64, 128, 256]

@export var config: ShadowGlassConfig
## The camera whose compositor receives the reprojection effect.
@export var main_camera: Camera3D

var reprojection: ReprojectionEffect
var main_compositor: Compositor

var live_bank: CaptureBank
var anchor_banks: Array[CaptureBank] = []
var anchor_positions: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]

var active_index := 0
var transition_progress := 0.0
var state: CaptureState = CaptureState.IDLE

var _wait_frames := 0
var _last_live_center := Vector3.ZERO


func _ready() -> void:
	if config == null:
		config = ShadowGlassConfig.new()
	if main_camera == null:
		main_camera = _find_main_camera()
	_build_banks()
	_install_reprojection()
	_initial_capture()


func _find_main_camera() -> Camera3D:
	var vp := get_viewport()
	if vp != null:
		return vp.get_camera_3d()
	return null


func _build_banks() -> void:
	for b in anchor_banks:
		if is_instance_valid(b):
			b.release()
			b.queue_free()
	anchor_banks.clear()
	if is_instance_valid(live_bank):
		live_bank.release()
		live_bank.queue_free()

	live_bank = _make_bank(&"live")
	var a := _make_bank(&"anchor")
	var b := _make_bank(&"anchor")
	anchor_banks = [a, b]

	var world: World3D = null
	if main_camera != null:
		world = main_camera.get_world_3d()
	for bank in [live_bank, a, b]:
		if world != null:
			bank.set_world(world)

	if reprojection != null:
		reprojection.configure_atlases(live_bank.get_atlas_rid(), a.get_atlas_rid(), b.get_atlas_rid())


func _make_bank(kind: StringName) -> CaptureBank:
	var bank := CaptureBank.new()
	bank.name = String(kind)
	bank.kind = kind
	add_child(bank)
	bank.setup(config.capture_resolution, config)
	return bank


func _install_reprojection() -> void:
	if main_camera == null:
		return
	if reprojection == null:
		reprojection = ReprojectionEffect.new()
		main_compositor = Compositor.new()
		main_compositor.compositor_effects = [reprojection]
		main_camera.compositor = main_compositor
	reprojection.set_capture_resolution(config.capture_resolution)
	reprojection.configure_atlases(
		live_bank.get_atlas_rid(),
		anchor_banks[0].get_atlas_rid(),
		anchor_banks[1].get_atlas_rid()
	)


func _initial_capture() -> void:
	var start := Vector3.ZERO
	if main_camera != null:
		start = main_camera.global_position
	anchor_positions = [start, start]
	for i in range(2):
		anchor_banks[i].set_center(start)
		anchor_banks[i].set_update_mode(SubViewport.UPDATE_ONCE)
	_wait_frames = 3
	state = CaptureState.CAPTURE_READY


func _process(delta: float) -> void:
	if main_camera == null or reprojection == null:
		return
	reprojection.apply_config(config)
	reprojection.set_capture_resolution(config.capture_resolution)

	var cam_pos := main_camera.global_position
	if not config.debug_freeze_live:
		live_bank.set_center(cam_pos)
		_last_live_center = cam_pos

	_run_state_machine(delta, cam_pos)
	_push_reprojection(cam_pos)


func _run_state_machine(delta: float, cam_pos: Vector3) -> void:
	match state:
		CaptureState.CAPTURE_READY:
			_wait_frames -= 1
			if _wait_frames <= 0:
				for i in range(2):
					anchor_banks[i].set_update_mode(SubViewport.UPDATE_DISABLED)
				state = CaptureState.IDLE
		CaptureState.BLENDING:
			var t := config.transition_time
			if t > 0.001:
				transition_progress += delta / t
			else:
				transition_progress += 1.0
			if transition_progress >= 1.0:
				transition_progress = 1.0
				anchor_banks[1 - _active()].set_update_mode(SubViewport.UPDATE_DISABLED)
				active_index = 1 - _active()
				state = CaptureState.IDLE
		CaptureState.IDLE:
			if config.debug_freeze_anchor:
				return
			var active_pos := anchor_positions[_active()]
			if cam_pos.distance_to(active_pos) > config.capture_distance:
				_begin_capture(cam_pos)


func _begin_capture(new_pos: Vector3) -> void:
	var inactive := 1 - _active()
	anchor_banks[inactive].set_center(new_pos)
	anchor_banks[inactive].set_update_mode(SubViewport.UPDATE_ONCE)
	anchor_positions[inactive] = new_pos
	transition_progress = 0.0
	_wait_frames = 3
	state = CaptureState.CAPTURE_READY


func _active() -> int:
	if active_index >= 0 and active_index < 2:
		return active_index
	return 0


func _push_reprojection(_cam_pos: Vector3) -> void:
	reprojection.set_centers(
		_last_live_center,
		anchor_positions[0],
		anchor_positions[1],
		_current_blend()
	)


func _current_blend() -> float:
	# anchor_blend semantics: 0 -> fully anchor A, 1 -> fully anchor B.
	if state == CaptureState.BLENDING:
		if _active() == 0:
			return transition_progress
		return 1.0 - transition_progress
	if _active() == 0:
		return 0.0
	return 1.0


func set_resolution(res: int) -> void:
	config.capture_resolution = res
	_build_banks()
	_install_reprojection()
	_initial_capture()


func force_capture() -> void:
	if state == CaptureState.IDLE and main_camera != null:
		_begin_capture(main_camera.global_position)


func _cycle_resolution() -> void:
	var idx := RESOLUTIONS.find(config.capture_resolution)
	var next_idx := 0
	if idx >= 0:
		next_idx = (idx + 1) % RESOLUTIONS.size()
	set_resolution(RESOLUTIONS[next_idx])
	push_warning("ShadowGlass resolution -> %d" % RESOLUTIONS[next_idx])


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_F1:
			config.enabled = not config.enabled
		KEY_F2:
			if config.debug_mode == ShadowGlassConfig.DebugMode.VALIDITY:
				config.debug_mode = ShadowGlassConfig.DebugMode.FINAL
			else:
				config.debug_mode = ShadowGlassConfig.DebugMode.VALIDITY
		KEY_F3:
			if config.debug_mode == ShadowGlassConfig.DebugMode.ORIGINAL:
				config.debug_mode = ShadowGlassConfig.DebugMode.FINAL
			else:
				config.debug_mode = ShadowGlassConfig.DebugMode.ORIGINAL
		KEY_F4:
			config.debug_freeze_live = not config.debug_freeze_live
		KEY_F5:
			force_capture()
		KEY_F6:
			_cycle_resolution()
