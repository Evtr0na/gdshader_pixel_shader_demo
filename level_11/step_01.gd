extends Node3D

const CAPTURE_RESOLUTION := 128

const FACE_NAMES := ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]

const FACE_VIEW: Array[Vector3] = [
	Vector3(1, 0, 0),
	Vector3(-1, 0, 0),
	Vector3(0, 1, 0),
	Vector3(0, -1, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1),
]

const FACE_UP: Array[Vector3] = [
	Vector3(0, -1, 0),
	Vector3(0, -1, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1),
	Vector3(0, -1, 0),
	Vector3(0, -1, 0),
]

const TEST_POSITIONS: Array[Vector3] = [
	Vector3(4, 0, 0),
	Vector3(-4, 0, 0),
	Vector3(0, 4, 0),
	Vector3(0, -4, 0),
	Vector3(0, 0, 4),
	Vector3(0, 0, -4),
]

const TEST_COLORS: Array[Color] = [
	Color(1.0, 0.15, 0.15), # +X 红
	Color(0.15, 1.0, 0.15), # -X 绿
	Color(0.15, 0.35, 1.0), # +Y 蓝
	Color(1.0, 0.9, 0.1), # -Y 黄
	Color(1.0, 0.15, 1.0), # +Z 紫
	Color(0.1, 1.0, 1.0), # -Z 青
]

var capture_viewports: Array[SubViewport] = []
var capture_cameras: Array[Camera3D] = []

var rd:RenderingDevice

var atlas_rid := RID()
var atlas_texture: Texture2DRD # 用于将底层资源给上层节点看的

var capture_effects:Array[PracticeCaptureColorEffect] = []

func _ready() -> void:

	_create_environment()

	_create_test_objects()

	_create_main_camera()
	
	_create_atlas()

	_create_capture_cameras()

	_create_atlas_debug_ui()

	# _create_debug_ui()


func _create_atlas()->void:

	rd = RenderingServer.get_rendering_device()
	
	if rd == null:
		push_error("RenderingDevice unavailable")
		return

	var format := RDTextureFormat.new()

	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D

	format.format = (RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)

	format.width = CAPTURE_RESOLUTION * 3
	format.height = CAPTURE_RESOLUTION * 2 

	format.depth = 1 #仅1，非3d体纹理
	format.array_layers = 1#仅1，非纹理数组
	format.mipmaps = 1

	format.samples = RenderingDevice.TEXTURE_SAMPLES_1 #单采样

	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT #shader 可以用`texture()`采样读取（只读采样）
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT #可以作为 storage image，compute shader 用`imageLoad/imageStore`读写
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT #允许**拷贝数据到这个纹理**（GPU 内部拷贝写入）
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT #允许**从这个纹理拷贝出去**（GPU 内部拷贝读出）
		)

func _create_environment() -> void:
	var environment := Environment.new()

	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.03, 0.03, 0.04)

	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment

	add_child(world_environment)


func _create_test_objects() -> void:
	for i in range(6):
		var mesh_instance := MeshInstance3D.new()

		var box := BoxMesh.new()
		box.size = Vector3(1.5, 1.5, 1.5)

		var material := StandardMaterial3D.new()
		material.albedo_color = TEST_COLORS[i]
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		mesh_instance.mesh = box
		mesh_instance.material_override = material
		mesh_instance.position = TEST_POSITIONS[i]

		add_child(mesh_instance)


func _create_main_camera() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(2, 2, 2)

	add_child(camera)

	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.current = true


func _create_capture_cameras() -> void:
	for face in range(6):
		_create_capture_face(face)


func _create_capture_face(face: int) -> void:
	#--viewport--
	var viewport: SubViewport = SubViewport.new()

	viewport.name = "Capture_{0}".format([FACE_NAMES[face]])

	viewport.size = Vector2i(CAPTURE_RESOLUTION, CAPTURE_RESOLUTION)

	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false

	viewport.own_world_3d = false

	add_child(viewport)

	viewport.world_3d = get_world_3d() #指定环境世界

	#--添加相机--
	var camera: Camera3D = Camera3D.new()

	camera.fov = 90.0
	camera.keep_aspect = Camera3D.KEEP_WIDTH

	camera.near = 0.05
	camera.far = 100.0

	viewport.add_child(camera)
	camera.current = true

	#--相机视角--
	var view: Vector3 = FACE_VIEW[face]
	var up: Vector3 = FACE_UP[face]

	var right: Vector3 = view.cross(up)
	var z_axis := -view

	var basis_ := Basis(right, up, z_axis)

	camera.global_transform = Transform3D(basis_, Vector3.ZERO)

	#--save--
	capture_viewports.append(viewport)
	capture_cameras.append(camera)


func _create_debug_ui() -> void:
	var canvas := CanvasLayer.new()

	add_child(canvas)

	var ui_root = Control.new()

	canvas.add_child(ui_root)

	var grid := GridContainer.new()

	grid.columns = 3
	# grid.position = Vector2(20, 20)

	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	ui_root.add_child(grid)

	grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  

	for i in range(6):
		#cell
		var cell := VBoxContainer.new()

		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL

		#label
		var label := Label.new()

		label.text = FACE_NAMES[i]
		label.label_settings = LabelSettings.new()
		label.label_settings.font_size = 40 
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

		cell.add_child(label)

		#preview
		var preview := TextureRect.new()

		preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		preview.size_flags_vertical = Control.SIZE_EXPAND_FILL

		preview.custom_minimum_size = Vector2(180 ,180)

		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED

		preview.texture = capture_viewports[i].get_texture()

		cell.add_child(preview)

		grid.add_child(cell)
