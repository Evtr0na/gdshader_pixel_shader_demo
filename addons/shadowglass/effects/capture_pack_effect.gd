class_name CapturePackEffect
extends CompositorEffect
## Reads one capture-face viewport's resolved color + depth in the render thread
## and writes rgb=linear color / a=radial depth into the shared GPU atlas tile.
## The atlas RID and face index are assigned by CaptureBank.

const GROUP_SIZE := 8

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID
var params_buffer: RID

## Assigned by CaptureBank (plain RIDs are safe to read on the render thread).
var atlas_rid := RID()
var face_index := 0
var capture_near := 0.1
var capture_far := 256.0
var capture_resolution := 128


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("ShadowGlass CapturePackEffect: RenderingDevice unavailable (Forward+ required).")
		return
	var spirv := ShadowGlassUtils.compile_compute(
		rd, "res://addons/shadowglass/shaders/capture_pack.glsl"
	)
	if spirv.compile_error_compute != "":
		push_error("ShadowGlass capture_pack.glsl:\n%s" % spirv.compile_error_compute)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.max_lod = 0.0
	depth_sampler = rd.sampler_create(ss)

	# std430: mat4 (64 bytes) + vec4 (16 bytes) = 80 bytes.
	params_buffer = rd.storage_buffer_create(80)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		ShadowGlassUtils.free_rids(rd, [pipeline, shader, depth_sampler, params_buffer])


func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not enabled or not atlas_rid.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var scene_data := render_data.get_render_scene_data() as RenderSceneData
	if scene_data == null:
		return
	var view_count := buffers.get_view_count()
	for view in range(view_count):
		var color_img := buffers.get_color_layer(view)
		var depth_img := buffers.get_depth_layer(view)
		if color_img.is_valid() and depth_img.is_valid():
			_pack(scene_data, color_img, depth_img)


func _pack(scene_data: RenderSceneData, color_img: RID, depth_img: RID) -> void:
	var inv: Projection = scene_data.get_cam_projection().inverse()
	var p32 := PackedFloat32Array()
	p32.resize(20)
	ShadowGlassUtils.write_projection(p32, 0, inv)
	p32[16] = capture_near
	p32[17] = capture_far
	p32[18] = float(face_index)
	p32[19] = float(capture_resolution)
	rd.buffer_update(params_buffer, 0, p32.size() * 4, p32.to_byte_array())

	var uniforms: Array[RDUniform] = []

	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_img)
	uniforms.push_back(u_color)

	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(depth_sampler)
	u_depth.add_id(depth_img)
	uniforms.push_back(u_depth)

	var u_atlas := RDUniform.new()
	u_atlas.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_atlas.binding = 2
	u_atlas.add_id(atlas_rid)
	uniforms.push_back(u_atlas)

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 3
	u_params.add_id(params_buffer)
	uniforms.push_back(u_params)

	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, uniforms)

	var groups := (capture_resolution + GROUP_SIZE - 1) / GROUP_SIZE
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, groups, groups, 1)
	rd.compute_list_end()