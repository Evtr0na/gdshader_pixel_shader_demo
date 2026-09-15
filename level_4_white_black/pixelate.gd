@tool
class_name InvertEffect
extends CompositorEffect


var rd: RenderingDevice

var shader: RID
var pipeline: RID

#---------------------------
# custom_paramter
#---------------------------
@export var values_1:float = 0.1

#---------------------------
# 一次性初始化
#---------------------------
func _init() -> void:
	#在哪个阶段执行
	effect_callback_type = (
		EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	)
	rd = RenderingServer.get_rendering_device()
	
	RenderingServer.call_on_render_thread(
		_initialize_compute
	)


func _initialize_compute() -> void:

	#获取 RenderingDeivce
	rd = RenderingServer.get_rendering_device()

	if not rd:
		return

	var shader_file: RDShaderFile = load(
        "res://level_4/post_invert.glsl"
	)

	var spirv: RDShaderSPIRV = (
		shader_file.get_spirv()
	)

	if spirv.compile_error_compute != "":
		push_error(
			spirv.compile_error_compute
		)
		return

	shader = rd.shader_create_from_spirv(
		spirv
	)


	if shader.is_valid():
		pipeline = (
			rd.compute_pipeline_create(shader)
		)


#---------------------------
# 每帧执行
#---------------------------
func _render_callback(
	callback_type: EffectCallbackType,
	render_data: RenderData
) -> void:

	if not rd:
		return

	if callback_type != (
		EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	):
		return

	if not pipeline.is_valid():
		return


	# 当前这一帧的 Render Buffers
	var buffers := (
		render_data.get_render_scene_buffers()
	)

	if not buffers:
		return


	# 当前 3D 渲染分辨率
	var size: Vector2i = (
		buffers.get_internal_size()
	)

	if size.x == 0 or size.y == 0:
		return


	# 8×8 work group
	@warning_ignore("integer_division")
	var groups_x := (
		(size.x - 1) / 8 + 1
	)

	@warning_ignore("integer_division")
	var groups_y := (
		(size.y - 1) / 8 + 1
	)


	# vec2 raster_size
	# vec2 reserved
	var push_constant := PackedFloat32Array([
		size.x,
		size.y,
		values_1,
	])


	# 一般普通游戏只有 1 个 view
	var view_count: int = (
		buffers.get_view_count()
	)

	for view in range(view_count):

		# 这一帧 Godot 已经渲染好的颜色图片
		var color_image: RID = (
			buffers.get_color_layer(view)
		)


		# GLSL:
		#
		# set = 0
		# binding = 0
		#
		var uniform := RDUniform.new()

		uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_IMAGE
		)

		uniform.binding = 0

		uniform.add_id(color_image)


		var uniform_set: RID = (
			UniformSetCacheRD.get_cache(
				shader,
				0,
				[uniform]
			)
		)


		# ----------------------
		# 本帧 GPU 工作
		# ----------------------

		var compute_list := (
			rd.compute_list_begin()
		)

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
			push_constant.to_byte_array(),
			push_constant.size() * 4
		)

		rd.compute_list_dispatch(
			compute_list,
			groups_x,
			groups_y,
			1
		)

		rd.compute_list_end()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
