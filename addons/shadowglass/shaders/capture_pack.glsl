#version 450
// =============================================================================
// Shadow Glass - capture pack compute shader.
//
// Runs as a CompositorEffect on each capture SubViewport. Reads that viewport's
// resolved colour + depth and writes one face tile of the shared GPU atlas:
//
//   rgb = linear scene colour
//   a   = radial depth, i.e. the distance from the cube centre to the surface
//         along this texel's ray (world units)
//
// Sky / background pixels write a = -1.0. That sentinel is what lets the
// reprojection pass tell "the cubemap saw nothing here" apart from "the
// cubemap saw a surface 3 units away", which is the whole basis of the
// occlusion test. See cube_atlas.glslinc for the matching sampler.
// =============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform readonly image2D src_color;
layout(set = 0, binding = 1) uniform sampler2D src_depth;
layout(rgba16f, set = 0, binding = 2) uniform writeonly image2D dst_atlas;

layout(std430, set = 0, binding = 3) buffer PackParams {
	mat4 inv_proj; // capture camera inverse projection (view space)
	vec4 p;        // x = capture_near, y = capture_far, z = face_index, w = capture_resolution
} pack_params;

void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	int res = int(pack_params.p.w + 0.5);
	if (pix.x >= res || pix.y >= res) {
		return;
	}

	vec4 color = imageLoad(src_color, pix);
	float d = texelFetch(src_depth, pix, 0).r;

	// Godot 4 uses reverse-Z: the near plane maps to 1.0 and the far plane to
	// 0.0, so the cleared / sky value is ~0.0.
	bool sky = d <= 1e-6;

	float radial_depth;
	if (sky) {
		radial_depth = -1.0;
	} else {
		// Reconstruct the view-space position. This matches Godot's spatial
		// shader convention (SCREEN_UV * 2.0 - 1.0 fed to INV_PROJECTION_MATRIX,
		// with no explicit Y flip).
		vec2 uv = (vec2(pix) + 0.5) / vec2(float(res));
		vec3 ndc = vec3(uv * 2.0 - 1.0, d);
		vec4 clip = pack_params.inv_proj * vec4(ndc, 1.0);
		vec3 view = clip.xyz / clip.w;
		radial_depth = length(view);
	}

	int face = int(pack_params.p.z + 0.5);
	int col = face % 3;
	int row = face / 3;
	ivec2 tile = ivec2(col * res, row * res);

	imageStore(dst_atlas, tile + pix, vec4(color.rgb, radial_depth));
}
