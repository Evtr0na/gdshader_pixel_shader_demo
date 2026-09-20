class_name ReprojectionEffect
extends CompositorEffect
## Main reprojection pass. Installed on the main Camera3D's compositor by
## ShadowGlassSystem. Reconstructs world positions from the main depth buffer,
## reprojects them against the Live / AnchorA / AnchorB capture atlases, and
## writes the pixelated result back into the colour buffer.
##
## The ShadowGlassSystem pushes per-frame state onto this object as plain float
## fields. That is a single-writer / one-frame-late hand-off to the render
## thread: safe in practice, and it keeps every Node lookup off the render
## thread (which must never touch the SceneTree).

const GROUP_SIZE := 8

## mat4 (64) + mat4 (64) + 9 * vec4 (144) = 272 bytes = 68 floats.
const PARAMS_FLOATS := 68

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

var live_center := Vector3.ZERO
var anchor_a_center := Vector3.ZERO
var anchor_b_center := Vector3.ZERO
var anchor_blend := 0.0
var capture_resolution := 128

var occlusion_abs := 0.01
var occlusion_rel := 0.03
var occlusion_probe_rel := 0.05
var occlusion_softness := 2.0
var face_blend_sharpness := 8.0
var near_fallback := 0.6

var fallback_mode := 2
var debug_mode := 0
var pixelate_sky := false

var quantization_levels := 12.0
var quantize_mode := 2
var quantize_in_srgb := true
var quant_enabled := false
var dither_strength := 1.0
var dither_enabled := false

var nearest_sampling := true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("ShadowGlass ReprojectionEffect: RenderingDevice unavailable (Forward+ required).")
		return

	var spirv := ShadowGlassUtils.compile_compute(
		rd, "res://addons/shadowglass/shaders/reprojection.glsl"
	)
	if spirv.compile_error_compute != "":
		push_error("ShadowGlass reprojection.glsl:\n%s" % spirv.compile_error_compute)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

	depth_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST)
	nearest_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST)
	linear_sampler = _make_sampler(RenderingDevice.SAMPLER_FILTER_LINEAR)

	params_buffer = rd.storage_buffer_create(PARAMS_FLOATS * 4)


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
		ShadowGlassUtils.free_rids(
			rd,
			[pipeline, shader, depth_sampler, nearest_sampler, linear_sampler, params_buffer]
		)


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
	occlusion_probe_rel = cfg.occlusion_probe_threshold
	occlusion_softness = cfg.occlusion_softness
	face_blend_sharpness = cfg.face_blend_sharpness
	near_fallback = cfg.near_original_fallback_distance
	fallback_mode = int(cfg.fallback_mode)
	debug_mode = int(cfg.debug_mode)
	quantization_levels = float(cfg.quantization_levels)
	quantize_mode = int(cfg.quantize_mode)
	quantize_in_srgb = cfg.quantize_in_srgb
	quant_enabled = cfg.quantization_enabled
	dither_strength = cfg.dither_strength
	dither_enabled = cfg.dither_enabled
	pixelate_sky = cfg.pixelate_sky
	nearest_sampling = cfg.nearest_sampling
	enabled = cfg.enabled


func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not enabled:
		return
	if not live_atlas_rid.is_valid():
		return
	if not anchor_a_atlas_rid.is_valid() or not anchor_b_atlas_rid.is_valid():
		return
	if not pipeline.is_valid():
		return

	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var scene_data := render_data.get_render_scene_data()
	if scene_data == null:
		return

	for view in range(buffers.get_view_count()):
		var color_img := buffers.get_color_layer(view)
		var depth_img := buffers.get_depth_layer(view)
		if color_img.is_valid() and depth_img.is_valid():
			_reproject(scene_data, buffers, color_img, depth_img)


func _reproject(
	scene_data: RenderSceneData,
	buffers: RenderSceneBuffersRD,
	color_img: RID,
	depth_img: RID
) -> void:
	var inv: Projection = scene_data.get_cam_projection().inverse()
	var cam: Transform3D = scene_data.get_cam_transform()
	var size := buffers.get_internal_size()

	var p32 := PackedFloat32Array()
	p32.resize(PARAMS_FLOATS)
	ShadowGlassUtils.write_projection(p32, 0, inv)
	ShadowGlassUtils.write_transform(p32, 16, cam)

	var k := 32
	p32[k + 0] = live_center.x
	p32[k + 1] = live_center.y
	p32[k + 2] = live_center.z
	k += 4
	p32[k + 0] = anchor_a_center.x
	p32[k + 1] = anchor_a_center.y
	p32[k + 2] = anchor_a_center.z
	p32[k + 3] = anchor_blend
	k += 4
	p32[k + 0] = anchor_b_center.x
	p32[k + 1] = anchor_b_center.y
	p32[k + 2] = anchor_b_center.z
	p32[k + 3] = float(capture_resolution)
	k += 4
	p32[k + 0] = occlusion_abs
	p32[k + 1] = occlusion_rel
	p32[k + 2] = occlusion_softness
	p32[k + 3] = near_fallback
	k += 4
	p32[k + 0] = float(fallback_mode)
	p32[k + 1] = float(debug_mode)
	p32[k + 2] = 1.0 if pixelate_sky else 0.0
	k += 4
	p32[k + 0] = quantization_levels
	p32[k + 1] = dither_strength
	p32[k + 2] = 1.0 if quant_enabled else 0.0
	p32[k + 3] = 1.0 if dither_enabled else 0.0
	k += 4
	p32[k + 0] = float(quantize_mode)
	p32[k + 1] = 1.0 if quantize_in_srgb else 0.0
	p32[k + 2] = float(size.x)
	p32[k + 3] = float(size.y)
	k += 4
	p32[k + 0] = face_blend_sharpness
	p32[k + 1] = occlusion_probe_rel
	k += 4

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

	var atlases: Array[RID] = [live_atlas_rid, anchor_a_atlas_rid, anchor_b_atlas_rid]
	for i in range(atlases.size()):
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = 2 + i
		u.add_id(atlas_sampler)
		u.add_id(atlases[i])
		uniforms.push_back(u)

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
