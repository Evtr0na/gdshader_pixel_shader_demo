extends CompositorEffect
class_name PracticeCaptureColorEffect


const GROUP_SIZE := 8
const SHADER_PATH := "res://level_11/step02/pack_color.glsl"

var rd: RenderingDevice

var shader := RID()#资源句柄
var pipeline := RID()

var atlas_rid := RID()

var face_index:int = 0
var capture_resolution:int = 128

func _init() -> void:
	#不透明物体(opaque) → 天空(sky) → 透明物体(transparent) → POST_TRANSPARENT → 引擎自带后处理(Bloom、色阶等) → 输出画面
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

	access_resolved_color = true #开启MSAA的时候自动降采样,单像素多采样无法直接使用

	rd = RenderingServer.get_rendering_device()

	if rd == null:
		push_error("RenderingDevice unavailable")	
		return

	#`RDShaderFile` is only meant to be used with the `RenderingDevice` API.
	var shader_file := load(SHADER_PATH) as RDShaderFile

	if shader_file == null:
		push_error("cannot load shader: %s" % SHADER_PATH)
		return

	#RDShaderSPIRV 就是**存放 SPIR-V 字节码与编译错误信息的资源对象**，是 RDShaderFile 里面的核心数据单元。
	var spirv: RDShaderSPIRV = shader_file.get_spirv()

	#- `RDShaderFile` 内部包含 `RDShaderSPIRV`。调用 `RDShaderFile.get_spirv()` 拿到它。
	#- 存储：SPIR-V 字节码 + 每个着色器阶段的编译报错信息。
	if spirv.compile_error_compute != "":
		push_error(
			"Compute shader compile error:\n%s" 
			% spirv.compile_error_compute
		)
		return

	shader = rd.shader_create_from_spirv(spirv)

	#pipeline打包
	# - 着色器本身（你传进去的 `shader` RID，就是 `shader_create_from_spirv` 的结果）
	# - 工作组布局（`local_size_x/y/z`，在 GLSL 里写死的那 8×8）
	# - 推送常量布局（push constant）
	# - 描述符集布局（descriptor set，用来绑定 buffer、texture）
	pipeline = rd.compute_pipeline_create(shader)


func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	#render_data:存放这一帧渲染相关的全部数据。

	if rd == null:
		return
	if not atlas_rid.is_valid():
		return

	var buffer := (
		render_data.get_render_scene_buffers()#返回场景渲染缓冲对象，即颜色纹理、深度纹理等 GPU 资源 
		as RenderSceneBuffersRD#强转成 `RenderSceneBuffersRD`，才能调用
		)

	if buffer == null:
		return

	var color_image:RID = buffer.get_color_layer(0)

	if not color_image.is_valid():
		return

	_write_to_atlas(color_image)
	


func _write_to_atlas(color_image:RID)->void:
	# RDUniform = 描述**单个绑定项**的配置对象，记录 binding 号、资源类型，挂载纹理 / Buffer 的 RID；
	# 多个 RDUniform 打包成 uniform_set，传给 Compute Shader。
	var uniforms:Array[RDUniform] = []

	var src_uniform := RDUniform.new()

	src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	src_uniform.binding = 0
	src_uniform.add_id(color_image)

	uniforms.append(src_uniform)

	var atlas_uniform := RDUniform.new()

	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atlas_uniform.binding = 1
	atlas_uniform.add_id(atlas_rid)

	uniforms.append(atlas_uniform)
	
	var uniform_set := UniformSetCacheRD.get_cache(
		shader,
		0, #set = 0
		uniforms
		)	

	var push_data := PackedInt32Array([
		face_index,
		capture_resolution,
		0,
		0
	])

	var push_bytes := push_data.to_byte_array()

	var groups:int = (capture_resolution + GROUP_SIZE  - 1)/GROUP_SIZE#向上取整

	var compute_list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(
		compute_list,
		pipeline
	)	

	rd.compute_list_bind_uniform_set(
		compute_list,
		uniform_set,
		0
		)

	rd.compute_list_set_push_constant(
		compute_list,
		push_bytes,
		push_bytes.size()
		)

	rd.compute_list_dispatch(
		compute_list,
		groups,
		groups,
		1
		)
	
	rd.compute_list_end()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return

	if rd == null:
		return

	if pipeline.is_valid():
		rd.free_rid(pipeline)

	if shader.is_valid():
		rd.free_rid(shader)	
	

