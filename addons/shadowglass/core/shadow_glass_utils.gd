class_name ShadowGlassUtils
extends RefCounted
## Column-major mat4 packing helpers shared by the compositor effects.
## Godot Projection stores columns in x/y/z/w (Vector4); Transform3D stores
## basis axis vectors plus an origin. GLSL mat4 is column-major, matching both.

static func write_projection(dst: PackedFloat32Array, base: int, p: Projection) -> void:
	dst[base + 0] = p.x.x
	dst[base + 1] = p.x.y
	dst[base + 2] = p.x.z
	dst[base + 3] = p.x.w
	dst[base + 4] = p.y.x
	dst[base + 5] = p.y.y
	dst[base + 6] = p.y.z
	dst[base + 7] = p.y.w
	dst[base + 8] = p.z.x
	dst[base + 9] = p.z.y
	dst[base + 10] = p.z.z
	dst[base + 11] = p.z.w
	dst[base + 12] = p.w.x
	dst[base + 13] = p.w.y
	dst[base + 14] = p.w.z
	dst[base + 15] = p.w.w


static func write_transform(dst: PackedFloat32Array, base: int, t: Transform3D) -> void:
	var b := t.basis
	# column 0
	dst[base + 0] = b.x.x
	dst[base + 1] = b.x.y
	dst[base + 2] = b.x.z
	dst[base + 3] = 0.0
	# column 1
	dst[base + 4] = b.y.x
	dst[base + 5] = b.y.y
	dst[base + 6] = b.y.z
	dst[base + 7] = 0.0
	# column 2
	dst[base + 8] = b.z.x
	dst[base + 9] = b.z.y
	dst[base + 10] = b.z.z
	dst[base + 11] = 0.0
	# column 3
	dst[base + 12] = t.origin.x
	dst[base + 13] = t.origin.y
	dst[base + 14] = t.origin.z
	dst[base + 15] = 1.0


## Compile a plain-GLSL compute shader (.glsl source file) at runtime instead of
## relying on Godot's .glsl import section parser. Returns a stage SPIR-V object.
static func compile_compute(rd: RenderingDevice, path: String) -> RDShaderSPIRV:
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = FileAccess.get_file_as_string(path)
	return rd.shader_compile_spirv_from_source(src)


## Free RenderingDevice resources safely from the main thread.
##
## RenderingDevice.free_rid() is render-thread only: calling it from a
## _notification(PREDELETE) or a _ready() path logs
## "This function (free_rid) can only be called from the render thread."
## and silently leaks. Route it through the render thread instead.
static func free_rids(rd: RenderingDevice, rids: Array) -> void:
	if rd == null:
		return
	var valid: Array[RID] = []
	for rid in rids:
		if rid is RID and (rid as RID).is_valid():
			valid.append(rid)
	if valid.is_empty():
		return
	RenderingServer.call_on_render_thread(_free_rids_on_render_thread.bind(rd, valid))


static func _free_rids_on_render_thread(rd: RenderingDevice, rids: Array[RID]) -> void:
	for rid in rids:
		rd.free_rid(rid)