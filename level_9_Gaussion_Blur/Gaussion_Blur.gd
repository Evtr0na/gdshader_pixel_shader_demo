@tool
class_name InvertEffect_Gaussion_Blur
extends CompositorEffect


var rd: RenderingDevice

var shader: RID
var pipeline: RID

#---------------------------
# custom_paramter
#---------------------------

@export var sigma : float = 0.5
@export var radius_ : int = 8
#---------------------------
# 一次性初始化
#---------------------------
func _init() -> void:

	#仅开始游戏后生效
	enabled = true

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
        "res://level_9_Gaussion_Blur/Gaussion_Blur.glsl"
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
func _render_callback(callback_type: EffectCallbackType,render_data:RenderData)->void:

	if callback_type != (EFFECT_CALLBACK_TYPE_POST_TRANSPARENT):
		return

	if not pipeline.is_valid():
		return
	
	var buffers := (render_data.get_render_scene_buffers() as RenderSceneBuffersRD)

	if not buffers:
		return

	var size  := buffers.get_internal_size()

	if size.x == 0 or size.y == 0 :
		return

	#origin image
	var color_image := buffers.get_color_layer(0,false)



	#-----------------------
	# temp GPU image
	#-----------------------

	var temp_image := buffers.create_texture(
			"pixelate",   #context，类似命名空间
			"horizontal_result",#纹理名字

			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,#RGBA 每通道 16-bit 浮点

			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,#允许当 image2D 给 Compute Shader 读写

			RenderingDevice.TEXTURE_SAMPLES_1,#不用 MSAA，1 sample

			size,#图片尺寸，例如 1920×1080

			1,			#layer
			1,			#mipmap
			false,		#unique 不要求每次都创建唯一新纹理，可复用同名缓存
			false
		)	


	#-----------------------
	# two sets of resource links
	#-----------------------

	#pass 1
	#Scene -> Temp
	var horizontal_set := make_uniform_set(
			color_image,
			temp_image
		)
	
	
	#pass 2
	# Temp -> Scene
	var vertical_set := make_uniform_set(
		temp_image,
		color_image
		)

	var group_x := int(ceil(size.x/8.0))

	var group_y := int(ceil(size.y/8.0))

	#-----------------------
	# Start GPU Command
	#-----------------------
	var compute_list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)


	#-----------------------
	# PASS 1: copy
	#-----------------------
	#store a texture first as the target for subsequent pixelation.
	var horiziontal_params := make_params(
			size.x,
			size.y,
			0,  #mode = pixelate
			sigma,
			radius_,
		)

	rd.compute_list_bind_uniform_set(
		compute_list,
		horizontal_set,	 #一整组已经配好的 uniform 资源
		0		     #set = 0 
	)

	rd.compute_list_set_push_constant(
		compute_list,
		horiziontal_params,
		horiziontal_params.size()
	)
	rd.compute_list_dispatch(
		compute_list,
		group_x,
	group_y,
		1 # local_size_z
	)	


	#-----------------------
	# wait pass1 Horiziontal Gaussion
	#-----------------------
	rd.compute_list_add_barrier(compute_list)

	#-----------------------
	# PASS 2: Vertical Gaussion
	#-----------------------
	var vertical_params:= make_params(
			size.x,
			size.y,
			1,  #mode = pixelate
			sigma,
			radius_,
		)

	rd.compute_list_bind_uniform_set(
		compute_list,
		vertical_set,	 #一整组已经配好的 uniform 资源
		0		     #set = 0 
	)

	rd.compute_list_set_push_constant(
		compute_list,
		vertical_params,
		vertical_params.size()
	)
	rd.compute_list_dispatch(
		compute_list,
		group_x,
		group_y,
		1 # local_size_z
	)	
																			

	rd.compute_list_end()
																			
														
#手动打包二进制数据,再在glsl那边解析读取
#类似 var a := PackedInt32Array.to_byte_array() 不过这个只能自定转化整数
#但实际上统一使用PackedFloat32Array就行了
func make_params(
	size_x : int,
	size_y : int,
	mode : int,
	strength_ : float,
	sample_count_ : int,
)->PackedByteArray:

	var data_ := PackedByteArray()
	data_.resize(4*5)

	data_.encode_s32(4*0,size_x)
	data_.encode_s32(4*1,size_y)
	data_.encode_s32(4*2,mode)
	data_.encode_float(4*3,strength_)
	data_.encode_s32(4*4,sample_count_)

	return data_

func make_uniform_set(source:RID,target:RID)->RID:

	#source
	var source_uniform := RDUniform.new()

	source_uniform.uniform_type = (RenderingDevice.UNIFORM_TYPE_IMAGE)

	source_uniform.binding = 0
	source_uniform.add_id(source)

	#target
	var target_uniform := RDUniform.new()

	target_uniform.uniform_type = (RenderingDevice.UNIFORM_TYPE_IMAGE)

	target_uniform.binding = 1
	target_uniform.add_id(target)

	return UniformSetCacheRD.get_cache(
			shader,
			0,
			[
				source_uniform,
				target_uniform

				]
		)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
