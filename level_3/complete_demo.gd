extends Control

const WIDTH := 1920
const HEIGTH := 1080

var rd: RenderingDevice

var shader_rid:RID
var pipeline_rid:RID
var output_texture_rid:RID
var uniform_set_rid:RID

var display_texture:ImageTexture

var time := 0.0 

func _ready():
	setup_compute()

#life_cycle
func _physics_process(_delta: float) -> void:
	timer(_delta)
	run_compute()


func timer(delta:float)->void:
	time += delta


func setup_compute()->void:
	#-------------------------------
	#-- RenderingDevice
	#-------------------------------
	rd = RenderingServer.create_local_rendering_device()
	

	#-------------------------------
	#-- Shader
	#-------------------------------
	var shader_file: RDShaderFile = load("res://level_3/gradient.glsl")

	var spirv: RDShaderSPIRV = (shader_file.get_spirv())

	push_error("GLSL error:",spirv.compile_error_compute)

	shader_rid = (rd.shader_create_from_spirv(spirv))


	#-------------------------------
	#-- Output Texture
	#-------------------------------
	var format := RDTextureFormat.new()

	format.width = WIDTH
	format.height = HEIGTH

	format.format = ( RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM )

	format.usage_bits = (
	RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	|
	RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	var view := RDTextureView.new()

	output_texture_rid = rd.texture_create(
		format,
		view,
		[]
	)



	#-------------------------------
	#-- Binding
	#-------------------------------
	var uniform := RDUniform.new()

	uniform.uniform_type = (RenderingDevice.UNIFORM_TYPE_IMAGE)

	uniform.binding = 0

	uniform.add_id(output_texture_rid)

	uniform_set_rid = rd.uniform_set_create(
		[uniform],
		shader_rid,
		0
	)


	#-------------------------------
	#-- Pipeline
	#-------------------------------
	pipeline_rid = (rd.compute_pipeline_create(shader_rid))


func run_compute()->void:

	#-------------------------------
	#-- Push Constant
	#-------------------------------
	var params := PackedFloat32Array([
		time,
		WIDTH,
		HEIGTH,
		0.0
	])

	var params_bytes := (params.to_byte_array())

	#-------------------------------
	#-- Compute Commands
	#-------------------------------
	var compute_list := (rd.compute_list_begin())

	rd.compute_list_bind_compute_pipeline(
		compute_list,
		pipeline_rid
	)

	rd.compute_list_bind_uniform_set(
		compute_list,
		uniform_set_rid,
		0
	)

	rd.compute_list_set_push_constant(
		compute_list,
		params_bytes,
		params_bytes.size()
	)
	
	#-------------------------------
	#-- Dispatch
	#-------------------------------
	var groups_x := int(ceil(WIDTH / 8.0))

	var groups_y := int( ceil(HEIGTH / 8.0) )

	rd.compute_list_dispatch(
		compute_list,
		groups_x,
		groups_y,
		1
		)


	rd.compute_list_end()


	#-------------------------------
	#-- Execute
	#-------------------------------
	rd.submit()
	rd.sync()


	#-------------------------------
	#-- Read Back
	#-------------------------------
	var bytes := rd.texture_get_data(
		output_texture_rid,
		0
		)
	
	var image := Image.create_from_data(
		WIDTH,
		HEIGTH,
		false,
		Image.FORMAT_RGBA8,
		bytes
	)

	#-------------------------------
	#-- Display
	#-------------------------------
	if display_texture == null:
		display_texture = (ImageTexture.create_from_image(image))
		$TextureRect.texture = (display_texture)

	else:
		display_texture.update(image)
