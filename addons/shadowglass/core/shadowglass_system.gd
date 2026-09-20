class_name ShadowGlassSystem
extends Node
## Owns three capture banks (Live, AnchorA, AnchorB), drives the anchor
## capture / crossfade state machine, and installs the ReprojectionEffect on the
## main camera's compositor.
##
## Two cube maps do the work:
##   * the LIVE bank follows the camera every frame and is always correct, but
##     its cube centre moves, so sampling it crawls during translation;
##   * the ANCHOR banks are frozen snapshots. Because their centre is static,
##     reprojecting the scene into them is stable while the camera moves.
## Once the camera strays further than `capture_distance` from the active
## anchor, the inactive anchor bank re-captures at the new position and the two
## are crossfaded, weighted by per-pixel depth-validity so disoccluded regions
## never bleed the wrong colour in.
##
## Main-thread only; all render-thread work lives in the effects.

enum CaptureState { IDLE, CAPTURE_READY, BLENDING }

const RESOLUTIONS: Array[int] = [32, 64, 128, 256, 512]

@export var config: ShadowGlassConfig
## The camera whose compositor receives the reprojection effect. Leave empty to
## use the viewport's current 3D camera.
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
var _cam_ready := false


func _ready() -> void:
	if config == null:
		config = ShadowGlassConfig.new()
	# The main camera may not be resolvable until the whole scene has entered
	# the tree, so defer everything that depends on it.
	_build_banks.call_deferred()


func _build_banks() -> void:
	if main_camera == null:
		main_camera = _find_main_camera()
	if main_camera == null:
		push_warning(
			"ShadowGlassSystem: no Camera3D found. Assign `main_camera` or add "
			+ "a current Camera3D to the viewport."
		)
		return

	# Bind the capture viewports to the main World3D only once both are inside
	# the tree; setting world_3d earlier gets reset by Godot's World3D lifetime
	# bookkeeping.
	var world := main_camera.get_world_3d()

	live_bank = _make_bank(&"live", world)
	anchor_banks = [
		_make_bank(&"anchor", world),
		_make_bank(&"anchor", world),
	]

	_install_reprojection()
	_initial_capture()
	_cam_ready = true


func _find_main_camera() -> Camera3D:
	var vp := get_viewport()
	if vp != null:
		return vp.get_camera_3d()
	return null


func _make_bank(kind: StringName, world: World3D) -> CaptureBank:
	var bank := CaptureBank.new()
	bank.name = String(kind)
	bank.kind = kind
	add_child(bank)
	bank.setup(config.capture_resolution, config, world)
	bank.set_world(world)
	return bank


func _install_reprojection() -> void:
	if main_camera == null:
		return
	if reprojection == null:
		reprojection = ReprojectionEffect.new()

	# NOTE: Compositor.compositor_effects returns a *copy* of the typed array, so
	# `compositor.compositor_effects.append(x)` silently does nothing. Build the
	# whole array and assign it in one go.
	main_compositor = Compositor.new()
	var effects: Array[CompositorEffect] = []
	var existing := main_camera.compositor
	if existing != null:
		# Preserve any compositor the scene already assigned to the camera.
		for effect in existing.compositor_effects:
			if effect != null and effect != reprojection:
				effects.append(effect)
	effects.append(reprojection)
	main_compositor.compositor_effects = effects
	main_camera.compositor = main_compositor

	reprojection.apply_config(config)
	reprojection.set_capture_resolution(config.capture_resolution)
	reprojection.configure_atlases(
		live_bank.get_atlas_rid(),
		anchor_banks[0].get_atlas_rid(),
		anchor_banks[1].get_atlas_rid()
	)


func _initial_capture() -> void:
	var start := main_camera.global_position
	anchor_positions = [start, start]
	_last_live_center = start
	for i in range(2):
		anchor_banks[i].set_center(start)
		anchor_banks[i].set_update_mode(SubViewport.UPDATE_ONCE)
	# Let the anchor viewports actually render before the blend is allowed to
	# read them.
	_wait_frames = maxi(1, config.capture_warmup_frames)
	state = CaptureState.CAPTURE_READY


func _process(delta: float) -> void:
	if not _cam_ready or reprojection == null:
		return

	reprojection.apply_config(config)
	reprojection.set_capture_resolution(config.capture_resolution)

	var cam_pos := main_camera.global_position
	if not config.debug_freeze_live:
		live_bank.set_center(cam_pos)
		_last_live_center = cam_pos

	_run_state_machine(delta, cam_pos)
	_push_reprojection()


func _run_state_machine(delta: float, cam_pos: Vector3) -> void:
	match state:
		CaptureState.CAPTURE_READY:
			_wait_frames -= 1
			if _wait_frames <= 0:
				for i in range(2):
					anchor_banks[i].set_update_mode(SubViewport.UPDATE_DISABLED)
				state = CaptureState.BLENDING if _is_crossfading() else CaptureState.IDLE
		CaptureState.BLENDING:
			var t := config.transition_time
			transition_progress += (delta / t) if t > 0.001 else 1.0
			if transition_progress >= 1.0:
				transition_progress = 1.0
				anchor_banks[1 - _active()].set_update_mode(SubViewport.UPDATE_DISABLED)
				active_index = 1 - _active()
				state = CaptureState.IDLE
		CaptureState.IDLE:
			if config.debug_freeze_anchor:
				return
			if cam_pos.distance_to(anchor_positions[_active()]) > config.capture_distance:
				_begin_capture(cam_pos)


## True when the newly captured bank should be faded in rather than snapped to.
func _is_crossfading() -> bool:
	return config.transition_time > 0.001


func _begin_capture(new_pos: Vector3) -> void:
	var inactive := 1 - _active()
	anchor_banks[inactive].set_center(new_pos)
	anchor_banks[inactive].set_update_mode(SubViewport.UPDATE_ONCE)
	anchor_positions[inactive] = new_pos
	transition_progress = 0.0
	_wait_frames = maxi(1, config.capture_warmup_frames)
	state = CaptureState.CAPTURE_READY


func _active() -> int:
	return active_index if active_index in [0, 1] else 0


func _push_reprojection() -> void:
	reprojection.set_centers(
		_last_live_center,
		anchor_positions[0],
		anchor_positions[1],
		_current_blend()
	)


## anchor_blend semantics: 0 -> fully anchor A, 1 -> fully anchor B.
func _current_blend() -> float:
	if state == CaptureState.BLENDING:
		return transition_progress if _active() == 0 else 1.0 - transition_progress
	return 0.0 if _active() == 0 else 1.0


## --- Public control ---------------------------------------------------------

func rebuild() -> void:
	## Recreate every bank. Call after changing capture_near / capture_far /
	## capture_cull_mask / capture_sky, which are baked into the bank nodes.
	if not _cam_ready:
		return
	for bank in anchor_banks:
		if is_instance_valid(bank):
			bank.release()
			bank.queue_free()
	anchor_banks.clear()
	if is_instance_valid(live_bank):
		live_bank.release()
		live_bank.queue_free()
	live_bank = null
	_build_banks()


func set_resolution(res: int) -> void:
	config.capture_resolution = res
	rebuild()


func force_capture() -> void:
	if _cam_ready and state == CaptureState.IDLE and main_camera != null:
		_begin_capture(main_camera.global_position)


func cycle_resolution() -> int:
	var idx := RESOLUTIONS.find(config.capture_resolution)
	var next_idx := (idx + 1) % RESOLUTIONS.size() if idx >= 0 else 0
	set_resolution(RESOLUTIONS[next_idx])
	return RESOLUTIONS[next_idx]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_F1:
			config.enabled = not config.enabled
		KEY_F2:
			config.debug_mode = (
				ShadowGlassConfig.DebugMode.FINAL
				if config.debug_mode != ShadowGlassConfig.DebugMode.FINAL
				else ShadowGlassConfig.DebugMode.VALIDITY
			)
		KEY_F3:
			config.debug_mode = (
				ShadowGlassConfig.DebugMode.FINAL
				if config.debug_mode != ShadowGlassConfig.DebugMode.FINAL
				else ShadowGlassConfig.DebugMode.ORIGINAL
			)
		KEY_F4:
			config.debug_freeze_live = not config.debug_freeze_live
		KEY_F5:
			force_capture()
		KEY_F6:
			cycle_resolution()
