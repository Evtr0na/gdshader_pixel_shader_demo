#version 450
// =============================================================================
// Shadow Glass — main reprojection compositor effect.
// Post-transparent compute: reconstructs the main-scene world position from
// depth, re-projects it against Live / AnchorA / AnchorB atlases, validates
// radial depth consistency, blends with validity weighting, then applies pixel
// look (nearest sampling, quantization, ordered dithering) as the final stage.
// =============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Main scene color, read then written back (single coherent image).
layout(rgba16f, set = 0, binding = 0) uniform coherent image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D src_depth;

layout(set = 0, binding = 2) uniform sampler2D live_atlas;
layout(set = 0, binding = 3) uniform sampler2D anchor_a_atlas;
layout(set = 0, binding = 4) uniform sampler2D anchor_b_atlas;

layout(std430, set = 0, binding = 5) buffer Params {
	mat4 inv_proj;       // main camera inverse projection (view space)
	mat4 view_to_world;  // main camera transform (view -> world)
	vec4 live_center_pad; // xyz = live center, w unused
	vec4 anchor_a_pad;    // xyz = anchor A center, w = anchor blend (0 -> A, 1 -> B)
	vec4 anchor_b_pad;    // xyz = anchor B center, w = capture_resolution
	vec4 occ;             // x abs thr, y rel thr, z softness, w near-original fallback distance
	vec4 misc;            // x near(unused), y far(unused), z fallback_mode, w debug_mode
	vec4 px;              // x quantization_levels, y dither_strength, z quant_enabled, w dither_enabled
	vec4 sz;              // x out_w, y out_h, z pixelate_sky, w capture_sky
} params;

// ---------------------------------------------------------------------------
// Inline copy of cube_atlas.glslinc (keep in sync — see that file for the
// single source-of-truth convention).
// ---------------------------------------------------------------------------
struct CubeSample {
	vec3 color;
	float radial_depth;
	bool is_sky;
	int face;
};

CubeSample sample_cube_atlas(sampler2D atlas, vec3 direction, float res) {
	vec3 d = normalize(direction);
	vec3 ad = abs(d);

	int face;
	if (ad.x >= ad.y && ad.x >= ad.z) {
		face = (d.x >= 0.0) ? 0 : 1;
	} else if (ad.y >= ad.x && ad.y >= ad.z) {
		face = (d.y >= 0.0) ? 2 : 3;
	} else {
		face = (d.z >= 0.0) ? 4 : 5;
	}

	vec3 view;
	vec3 up;
	if (face == 0)      { view = vec3( 1.0, 0.0, 0.0); up = vec3(0.0, -1.0, 0.0); }
	else if (face == 1) { view = vec3(-1.0, 0.0, 0.0); up = vec3(0.0, -1.0, 0.0); }
	else if (face == 2) { view = vec3( 0.0, 1.0, 0.0); up = vec3(0.0,  0.0, 1.0); }
	else if (face == 3) { view = vec3( 0.0,-1.0, 0.0); up = vec3(0.0,  0.0,-1.0); }
	else if (face == 4) { view = vec3( 0.0, 0.0, 1.0); up = vec3(0.0, -1.0, 0.0); }
	else                { view = vec3( 0.0, 0.0,-1.0); up = vec3(0.0, -1.0, 0.0); }

	vec3 right = normalize(cross(view, up));
	float dv = dot(d, view);
	float u = 0.5 * (1.0 + dot(d, right) / dv);
	float v = 0.5 * (1.0 - dot(d, up) / dv);
	u = clamp(u, 0.0, 1.0);
	v = clamp(v, 0.0, 1.0);

	int col = face % 3;
	int row = face / 3;
	vec2 atlas_uv = (vec2(u, v) + vec2(float(col), float(row))) / vec2(3.0, 2.0);

	vec4 tex = texture(atlas, atlas_uv);

	CubeSample s;
	s.color = tex.rgb;
	s.radial_depth = tex.a;
	s.is_sky = tex.a < 0.0;
	s.face = face;
	return s;
}
// ---------------------------------------------------------------------------

float bayer4(ivec2 p) {
	const int m[16] = int[16](
		0,  8,  2, 10,
		12,  4, 14,  6,
		3, 11,  1,  9,
		15,  7, 13,  5
	);
	int x = p.x & 3;
	int y = p.y & 3;
	return float(m[y * 4 + x]) / 16.0;
}

// Re-project one anchor/live atlas sample and validate radial depth.
vec3 reproject_face(sampler2D atlas, vec3 center, vec3 p, float res, out float valid, out int face) {
	vec3 delta = p - center;
	float expected = length(delta);
	vec3 dir = expected > 1e-5 ? delta / expected : vec3(0.0, 0.0, 1.0);
	CubeSample s = sample_cube_atlas(atlas, dir, res);
	face = s.face;
	if (s.is_sky) {
		valid = 0.0;
		return s.color;
	}
	float error = abs(s.radial_depth - expected);
	float tol = max(params.occ.x, expected * params.occ.y);
	valid = 1.0 - smoothstep(tol, tol * params.occ.z, error);
	return s.color;
}

void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	ivec2 outsz = ivec2(int(params.sz.x + 0.5), int(params.sz.y + 0.5));
	if (pix.x >= outsz.x || pix.y >= outsz.y) {
		return;
	}

	vec4 original = imageLoad(color_image, pix);
	float d = texelFetch(src_depth, pix, 0).r;
	float res = params.anchor_b_pad.w;

	vec2 uv = (vec2(pix) + 0.5) / vec2(outsz);
	vec2 nd = uv * 2.0 - 1.0;

	int dbg = int(params.misc.w + 0.5);
	int fallback = int(params.misc.z + 0.5);
	int quant_enabled = int(params.px.z + 0.5);
	int dither_enabled = int(params.px.w + 0.5);

	bool is_sky = (d <= 1e-5) || (d >= 1.0 - 1e-5);

	vec3 world_pos = vec3(0.0);
	float view_dist = 1e9;
	if (!is_sky) {
		vec3 ndc = vec3(nd, d);
		vec4 clip = params.inv_proj * vec4(ndc, 1.0);
		vec3 view = clip.xyz / clip.w;
		view_dist = length(view);
		vec4 wp = params.view_to_world * vec4(view, 1.0);
		world_pos = wp.xyz;
	}

	// --- anchor reprojection + validity-weighted temporal blend ---
	float validA = 0.0; float validB = 0.0; float validLive = 0.0;
	int faceA = 0; int faceB = 0; int faceLive = 0;
	vec3 colorA = reproject_face(anchor_a_atlas, params.anchor_a_pad.xyz, world_pos, res, validA, faceA);
	vec3 colorB = reproject_face(anchor_b_atlas, params.anchor_b_pad.xyz, world_pos, res, validB, faceB);

	float blend = clamp(params.anchor_a_pad.w, 0.0, 1.0);
	float wA = validA * (1.0 - blend);
	float wB = validB * blend;
	float wSum = wA + wB;
	vec3 anchor_color;
	float anchor_valid;
	if (wSum > 1e-4) {
		anchor_color = (colorA * wA + colorB * wB) / wSum;
		anchor_valid = clamp(wSum, 0.0, 1.0);
	} else {
		anchor_color = original.rgb;
		anchor_valid = 0.0;
	}

	vec3 live_color = reproject_face(live_atlas, params.live_center_pad.xyz, world_pos, res, validLive, faceLive);

	// --- fallback selection ---
	vec3 out_color;
	int source = 0; // 0 anchor, 1 live, 2 original, 3 invalid, 4 sky
	if (is_sky) {
		source = 4;
		if (int(params.sz.w + 0.5) != 0 && int(params.sz.z + 0.5) != 0) {
			// Pixelated sky: sample along the current main-camera ray.
			vec4 v0 = params.inv_proj * vec4(nd, 0.5, 1.0);
			vec3 dir_view = v0.xyz / v0.w;
			vec3 cam_origin = params.view_to_world[3].xyz;
			vec3 dir_world = normalize((params.view_to_world * vec4(dir_view, 1.0)).xyz - cam_origin);
			CubeSample ssky = sample_cube_atlas(live_atlas, dir_world, res);
			out_color = ssky.color;
		} else {
			out_color = original.rgb;
		}
	} else if (anchor_valid > 1e-3) {
		source = 0;
		out_color = anchor_color;
	} else if (fallback >= 1 && validLive > 1e-3) {
		source = 1;
		out_color = live_color;
	} else {
		source = 2;
		out_color = original.rgb;
	}

	// --- near-camera original fallback (weapons / near walls) ---
	float near_f = params.occ.w;
	float near_blend = is_sky ? 0.0 : (1.0 - smoothstep(near_f * 0.5, near_f, view_dist));
	out_color = mix(out_color, original.rgb, near_blend);

	// --- pixel look: quantization (final output only; debug modes bypass) ---
	bool disable_px = (dbg != 0);
	if (!disable_px && quant_enabled != 0) {
		float q = max(params.px.x, 1.0);
		out_color = floor(out_color * q + 0.5) / q;
	}

	// --- debug visualization override ---
	if (dbg == 1) {
		out_color = original.rgb;
	} else if (dbg == 2) {
		out_color = live_color;
	} else if (dbg == 3) {
		out_color = colorA;
	} else if (dbg == 4) {
		out_color = colorB;
	} else if (dbg == 5) {
		vec3 deltaD = world_pos - params.anchor_a_pad.xyz;
		float expected = max(length(deltaD), 1e-5);
		float captured = sample_cube_atlas(anchor_a_atlas, deltaD / expected, res).radial_depth;
		float err = abs(captured - expected);
		out_color = vec3(clamp(err / 2.0, 0.0, 1.0));
	} else if (dbg == 6) {
		out_color = mix(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), anchor_valid);
	} else if (dbg == 7) {
		vec3 deltaF = world_pos - params.live_center_pad.xyz;
		int f = (length(deltaF) > 1e-5) ? sample_cube_atlas(live_atlas, deltaF, res).face : 0;
		vec3 face_cols[6];
		face_cols[0] = vec3(1.0, 0.0, 0.0);
		face_cols[1] = vec3(0.0, 1.0, 0.0);
		face_cols[2] = vec3(0.0, 0.0, 1.0);
		face_cols[3] = vec3(1.0, 1.0, 0.0);
		face_cols[4] = vec3(1.0, 0.0, 1.0);
		face_cols[5] = vec3(0.0, 1.0, 1.0);
		out_color = is_sky ? vec3(0.0) : face_cols[f];
	} else if (dbg == 8) {
		if (is_sky)               out_color = vec3(0.0, 0.0, 1.0);   // sky
		else if (source == 0)     out_color = vec3(0.0, 1.0, 0.0);   // anchor
		else if (source == 1)     out_color = vec3(0.0, 1.0, 1.0);   // live
		else if (source == 2)     out_color = vec3(1.0, 1.0, 0.0);   // original
		else                      out_color = vec3(1.0, 0.0, 1.0);   // invalid
	}

	// --- ordered dithering (final output only) ---
	if (!disable_px && dither_enabled != 0) {
		out_color += (bayer4(pix) - 0.5) * params.px.y / 255.0;
	}

	imageStore(color_image, pix, vec4(out_color, original.a));
}
