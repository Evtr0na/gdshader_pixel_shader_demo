class_name ReprojectionEffect
extends CompositorEffect
## Main reprojection pass. Runs on the main Camera3D's compositor. Reconstructs
## world positions from the main depth buffer, reprojects them against the
## Live / AnchorA / AnchorB capture atlases, and writes the pixelated result back.

const GROUP_SIZE := 8

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID
var nearest_sampler: RID
var linear_sampler: RID
var params_buffer: RID

var live_atlas_rid := RID()
var anchor_a_atlas_rid := RID()
var anchor_b_atlas_rid := RID()

# State pushed from ShadowGlassSystem each frame (main thread). Plain float /
# Vector3 single-writer fields — safe enough for a one-frame-late read on the
# render thread; no Node/SceneTree access happens here.
var live_center := Vector3.ZERO
var anchor_a_center := Vector3.ZERO
var anchor_b_center := Vector3.ZERO
var anchor_blend := 0.0
var capture_resolution := 128

var occlusion_abs := 0.05
var occlusion_rel := 0.01
var occlusion_softness := 2.0
var near_fallback := 0.8

var fallback_mode := 2
var debug_mode := 0
var quantization_levels := 16.0
var dither_strength := 1.0
var quant_enabled := false
var dither_enabled := false
var pixelate_sky := false
var capture_sky := true
var nearest_sampling := true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("ShadowGlass ReprojectionEffect: RenderingDevice unavailable (Forward+ required).")
		return
	var spirv := ShadowGlassUtils.compile_compute(rd, "res://addons/shadowglass/shaders/reprojection.glsl")
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

	depth_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST)
	nearest_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST)
	linear_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_LINEAR)

	# std430: 2 * mat4 (128) + 7 * vec4 (112) = 240 bytes = 60 floats.
	params_buffer = rd.storage_buffer_create(240)


func _make_sampler(filter: int) -> RID:
	var ss := RDSamplerState.new()
	ss.mag_filter = filter
	ss.min_filter = filter
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.max_lod = 0.0
	return rd.sampler_create(ss)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if depth_sampler.is_valid():
			rd.free_rid(depth_sampler)
		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler)
		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler)
		if params_buffer.is_valid():
			rd.free_rid(params_buffer)


func configure_atlases(live: RID, a: RID, b: RID) -> void:
	live_atlas_rid = live
	anchor_a_atlas_rid = a
	anchor_b_atlas_rid = b


func set_centers(live: Vector3, a: Vector3, b: Vector3, blend: float) -> void:
	live_center = live
	anchor_a_center = a
	anchor_b_center = b
	anchor_blend = blend


func set_capture_resolution(res: int) -> void:
	capture_resolution = res


func apply_config(cfg: ShadowGlassConfig) -> void:
	occlusion_abs = cfg.occlusion_absolute_threshold
	occlusion_rel = cfg.occlusion_relative_threshold
	occlusion_softness = cfg.occlusion_softness
	near_fallback = cfg.near_original_fallback_distance
	fallback_mode = int(cfg.fallback_mode)
	debug_mode = int(cfg.debug_mode)
	quantization_levels = float(cfg.quantization_levels)
	dither_strength = cfg.dither_strength
	quant_enabled = cfg.pixel_quantization_enabled
	dither_enabled = cfg.dither_enabled
	pixelate_sky = cfg.pixelate_sky
	capture_sky = cfg.capture_sky
	nearest_sampling = cfg.nearest_sampling
	enabled = cfg.enabled


func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not enabled:
		return
	if not live_atlas_rid.is_valid() or not anchor_a_atlas_rid.is_valid() or not anchor_b_atlas_rid.is_valid():
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
			_reproject(scene_data, buffers, color_img, depth_img)


func _reproject(scene_data: RenderSceneData, buffers: RenderSceneBuffersRD, color_img: RID, depth_img: RID) -> void:
	var inv: Projection = scene_data.get_cam_projection().inverse()
	var cam: Transform3D = scene_data.get_cam_transform()
	var size := buffers.get_internal_size()

	var p32 := PackedFloat32Array()
	p32.resize(60)
	ShadowGlassUtils.write_projection(p32, 0, inv)
	ShadowGlassUtils.write_transform(p32, 16, cam)
	var k := 32
	p32[k] = live_center.x
	p32[k + 1] = live_center.y
	p32[k + 2] = live_center.z
	p32[k + 3] = 0.0
	k += 4
	p32[k] = anchor_a_center.x
	p32[k + 1] = anchor_a_center.y
	p32[k + 2] = anchor_a_center.z
	p32[k + 3] = anchor_blend
	k += 4
	p32[k] = anchor_b_center.x
	p32[k + 1] = anchor_b_center.y
	p32[k + 2] = anchor_b_center.z
	p32[k + 3] = float(capture_resolution)
	k += 4
	p32[k] = occlusion_abs
	p32[k + 1] = occlusion_rel
	p32[k + 2] = occlusion_softness
	p32[k + 3] = near_fallback
	k += 4
	p32[k] = 0.0
	p32[k + 1] = 0.0
	p32[k + 2] = float(fallback_mode)
	p32[k + 3] = float(debug_mode)
	k += 4
	p32[k] = quantization_levels
	p32[k + 1] = dither_strength
	p32[k + 2] = 1.0 if quant_enabled else 0.0
	p32[k + 3] = 1.0 if dither_enabled else 0.0
	k += 4
	p32[k] = float(size.x)
	p32[k + 1] = float(size.y)
	p32[k + 2] = 1.0 if pixelate_sky else 0.0
	p32[k + 3] = 1.0 if capture_sky else 0.0
	rd.buffer_update(params_buffer, 0, p32.size() * 4, p32.to_byte_array())

	var atlas_sampler := nearest_sampler if nearest_sampling else linear_sampler

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

	var u_live := RDUniform.new()
	u_live.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_live.binding = 2
	u_live.add_id(atlas_sampler)
	u_live.add_id(live_atlas_rid)
	uniforms.push_back(u_live)

	var u_a := RDUniform.new()
	u_a.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_a.binding = 3
	u_a.add_id(atlas_sampler)
	u_a.add_id(anchor_a_atlas_rid)
	uniforms.push_back(u_a)

	var u_b := RDUniform.new()
	u_b.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_b.binding = 4
	u_b.add_id(atlas_sampler)
	u_b.add_id(anchor_b_atlas_rid)
	uniforms.push_back(u_b)

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 5
	u_params.add_id(params_buffer)
	uniforms.push_back(u_params)

	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, uniforms)

	var gx := (size.x + GROUP_SIZE - 1) / GROUP_SIZE
	var gy := (size.y + GROUP_SIZE - 1) / GROUP_SIZE
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, gx, gy, 1)
	rd.compute_list_end()