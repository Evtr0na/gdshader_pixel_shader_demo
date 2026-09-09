extends Control


@export var WIDTH := 1920
@export var HEIGHT := 1080


func _ready() -> void:
	# 创建一个 RenderingDevice。
	var rd := RenderingServer.create_local_rendering_device()


	# -------------------------
	# 1. 加载 Compute Shader
	# -------------------------

	var shader_path := "res://level_3/gradient.glsl"

	print("文件存在吗：", FileAccess.file_exists(shader_path))

	var shader_file := load(shader_path)

	print("加载结果：", shader_file)

	if shader_file == null:
		push_error("gradient.glsl 加载失败")
		return

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()

	print("GLSL 编译错误：", shader_spirv.compile_error_compute)

	var shader := rd.shader_create_from_spirv(shader_spirv)


	# -------------------------
	# 2. 创建一张 512×512 图片
	# -------------------------

	var format := RDTextureFormat.new()

	format.width = WIDTH
	format.height = HEIGHT

	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM

	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	var view := RDTextureView.new()

	var output_texture := rd.texture_create(
		format,
		view,
		[]
	)


	# -------------------------
	# 3. 把图片插到 binding = 0
	# -------------------------

	var uniform := RDUniform.new()

	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(output_texture)

	var uniform_set := rd.uniform_set_create(
		[uniform],
		shader,
		0
	)


	# -------------------------
	# 4. 准备参数
	# -------------------------
	var params := PackedFloat32Array(
		[
			0.0, # x = time
			WIDTH, # y = width
			HEIGHT, # z = height
			0.0, # w = 暂时没用
		]
	)

	var params_bytes := params.to_byte_array()


	# -------------------------
	# 5. 让 GPU 执行 Shader
	# -------------------------

	var pipeline := rd.compute_pipeline_create(shader)

	#“这次计算任务，用这个 shader 配置。”
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(
		compute_list,
		pipeline
	)

	# “这次计算任务，把这些 GPU 资源接上。”
	rd.compute_list_bind_uniform_set(
		compute_list,
		uniform_set,
		0
	)
	
	# “这次计算任务，把几个小参数传进去。”
	rd.compute_list_set_push_constant(
		compute_list,
		params_bytes,
		params_bytes.size()
	)

	var groups_x := int(ceil(WIDTH / 8.0))
	var groups_y := int(ceil(HEIGHT / 8.0))

	# “启动这么多工作组。”
	rd.compute_list_dispatch(
		compute_list,
		groups_x,
		groups_y,
		1
	)

	rd.compute_list_end()


	# 真正提交给 GPU。
	rd.submit()

	# 等 GPU 算完。
	rd.sync()


	# -------------------------
	# 6. 把 GPU 图片拿回来
	# -------------------------

	var bytes := rd.texture_get_data(
		output_texture,
		0
	)

	var image := Image.create_from_data(
		WIDTH,
		HEIGHT,
		false,
		Image.FORMAT_RGBA8,
		bytes
	)

	var texture := ImageTexture.create_from_image(image)


	# -------------------------
	# 7. 显示到 TextureRect
	# -------------------------

	$TextureRect.texture = texture
