class_name CaptureBank
extends Node3D
## One capture bank: six SubViewports (each with a Camera3D + CapturePackEffect)
## rendering into a single GPU 3x2 atlas texture (R16G16B16A16_SFLOAT, rgb color
## + alpha radial depth). SubViewports share the main World3D, so no scene copy
## is made. Face orientation must stay in sync with shaders/cube_atlas.glslinc.

const FACES := 6

## Face convention: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z (see cube_atlas.glslinc).
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
var kind: StringName = &"live"  # "live" updates every frame; "anchor" is frozen.

var subviewports: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var effects: Array[CapturePackEffect] = []


func setup(res: int, cfg: ShadowGlassConfig) -> void:
	resolution = res
	rd = RenderingServer.get_rendering_device()
	_create_atlas()
	for i in range(FACES):
		_add_face(i, cfg)


func _create_atlas() -> void:
	if rd == null:
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
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var view := RDTextureView.new()
	atlas_rid = rd.texture_create(fmt, view)
	# Initialize to the sky sentinel (alpha < 0) so un-captured anchors are
	# never mistaken for valid geometry.
	rd.texture_clear(atlas_rid, Color(0.0, 0.0, 0.0, -1.0), 0, 1, 0, 1)


func _add_face(i: int, cfg: ShadowGlassConfig) -> void:
	var sv := SubViewport.new()
	sv.name = FACE_NAME[i]
	sv.size = Vector2i(resolution, resolution)
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED if kind == &"anchor" else SubViewport.UPDATE_ALWAYS
	sv.msaa_3d = Viewport.MSAA_DISABLED
	sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	sv.use_taa = false
	add_child(sv)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 90.0
	cam.near = cfg.capture_near
	cam.far = cfg.capture_far
	cam.cull_mask = cfg.capture_cull_mask
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.current = false
	sv.add_child(cam)

	var effect := CapturePackEffect.new()
	effect.face_index = i
	effect.capture_near = cfg.capture_near
	effect.capture_far = cfg.capture_far
	effect.capture_resolution = resolution
	effect.atlas_rid = atlas_rid

	var comp := Compositor.new()
	comp.compositor_effects = [effect]
	cam.compositor = comp

	subviewports.append(sv)
	cameras.append(cam)
	effects.append(effect)


func set_world(world: World3D) -> void:
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


func set_update_mode(mode: int) -> void:
	for sv in subviewports:
		sv.render_target_update_mode = mode


func get_atlas_rid() -> RID:
	return atlas_rid


func release() -> void:
	if rd != null and atlas_rid.is_valid():
		rd.free_rid(atlas_rid)
		atlas_rid = RID()