class_name CaptureBank
extends Node3D
## One capture bank: six SubViewports (each with a Camera3D + CapturePackEffect)
## rendering into a single GPU 3x2 atlas texture (R16G16B16A16_SFLOAT, rgb =
## linear colour, a = radial depth).
##
## The SubViewports share the main World3D (own_world_3d = false) so no scene
## copy is made and the capture always sees the live scene.
##
## Face orientation is duplicated in shaders/cube_atlas.glslinc — that file is
## the source of truth. Keep FACE_VIEW / FACE_UP in sync with it.

const FACES := 6

## Face convention: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z.
const FACE_VIEW: Array[Vector3] = [
	Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
	Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
]
const FACE_UP: Array[Vector3] = [
	Vector3(0, -1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1),
	Vector3(0, 0, -1), Vector3(0, -1, 0), Vector3(0, -1, 0),
]
const FACE_NAME: Array[String] = ["PX", "NX", "PY", "NY", "PZ", "NZ"]

var rd: RenderingDevice
var resolution: int = 128
var atlas_rid := RID()
## "live" updates every frame; "anchor" is frozen between captures.
var kind: StringName = &"live"

var subviewports: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var effects: Array[CapturePackEffect] = []

var _env: Environment
var _capture_sky := true


func setup(res: int, cfg: ShadowGlassConfig, world: World3D = null) -> void:
	resolution = res
	rd = RenderingServer.get_rendering_device()
	_create_atlas()
	_build_environment(cfg, world)
	for i in range(FACES):
		_add_face(i, cfg)


func _create_atlas() -> void:
	if rd == null:
		push_warning("ShadowGlass CaptureBank: RenderingDevice unavailable (Forward+ required).")
		return
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = resolution * 3
	fmt.height = resolution * 2
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		# Lets the atlas be read back with RenderingDevice.texture_get_data(),
		# which is what the debug/verification path uses.
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var view := RDTextureView.new()
	atlas_rid = rd.texture_create(fmt, view)
	# Initialise to the sky sentinel (alpha < 0) so an anchor that has not been
	# captured yet can never be mistaken for valid geometry.
	rd.texture_clear(atlas_rid, Color(0.0, 0.0, 0.0, -1.0), 0, 1, 0, 1)


## Built once and shared by all six SubViewports. Kept as a member so the
## Environment object is not garbage collected out from under the viewports.
##
## The environment is installed on the capture cameras' `environment` property,
## which overrides the WorldEnvironment for those viewports only.
##
## It is a *copy of the world environment* with only the background overridden.
## Building a fresh Environment instead would silently drop ambient light, fog
## and tonemapping, and the cubemap would come back noticeably darker than the
## scene it is meant to reproduce.
func _build_environment(cfg: ShadowGlassConfig, world: World3D) -> void:
	var base: Environment = world.environment if world != null else null
	_env = base.duplicate() if base != null else Environment.new()

	if not cfg.capture_sky:
		# Flat background: geometry meeting the skyline stops crawling, at the
		# cost of a plain colour in the cubemap.
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = cfg.capture_sky_color
	elif _env.background_mode == Environment.BG_CANVAS:
		# A canvas background has no meaning inside a 3D-only capture viewport.
		_env.background_mode = Environment.BG_SKY


func _add_face(i: int, cfg: ShadowGlassConfig) -> void:
	var sv := SubViewport.new()
	sv.name = FACE_NAME[i]
	sv.size = Vector2i(resolution, resolution)
	sv.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED if kind == &"anchor" else SubViewport.UPDATE_ALWAYS
	)
	sv.msaa_3d = Viewport.MSAA_DISABLED
	sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	sv.use_taa = false
	sv.use_debanding = false
	sv.transparent_bg = false
	sv.own_world_3d = false
	add_child(sv)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 90.0
	cam.near = cfg.capture_near
	cam.far = cfg.capture_far
	cam.cull_mask = cfg.capture_cull_mask
	# A 90 degree fov on a square target gives the aspect=1 cube face mapping
	# that cube_atlas.glslinc assumes.
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.current = false
	# Camera3D.environment overrides the WorldEnvironment for this viewport only,
	# which is what lets the cubemap use a flat background while the main view
	# keeps the real sky.
	cam.environment = _env
	sv.add_child(cam)

	var effect := CapturePackEffect.new()
	effect.face_index = i
	effect.capture_near = cfg.capture_near
	effect.capture_far = cfg.capture_far
	effect.capture_resolution = resolution
	effect.atlas_rid = atlas_rid

	# NOTE: Compositor.compositor_effects returns a copy of the typed array, so
	# mutating it in place (append) is silently discarded. Assign a new array.
	var comp := Compositor.new()
	var comp_effects: Array[CompositorEffect] = [effect]
	comp.compositor_effects = comp_effects
	cam.compositor = comp

	subviewports.append(sv)
	cameras.append(cam)
	effects.append(effect)


## Must be called after the node is in the tree, otherwise world_3d is reset
## back to the viewport's own world by the World3D lifetime bookkeeping.
func set_world(world: World3D) -> void:
	if world == null:
		return
	for sv in subviewports:
		sv.own_world_3d = false
		sv.world_3d = world


func set_center(center: Vector3) -> void:
	for i in range(FACES):
		var view := FACE_VIEW[i]
		var up := FACE_UP[i]
		var right := view.cross(up)
		var z := -view
		cameras[i].global_transform = Transform3D(Basis(right, up, z), center)


func set_update_mode(mode: SubViewport.UpdateMode) -> void:
	for sv in subviewports:
		sv.render_target_update_mode = mode


func get_atlas_rid() -> RID:
	return atlas_rid


func release() -> void:
	if rd != null and atlas_rid.is_valid():
		ShadowGlassUtils.free_rids(rd, [atlas_rid])
		atlas_rid = RID()
