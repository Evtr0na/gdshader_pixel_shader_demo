#version 450
// =============================================================================
// Shadow Glass - main reprojection compositor effect.
//
// Post-transparent compute pass on the main camera. For every pixel it:
//   1. reconstructs the world position from the main depth buffer,
//   2. re-projects that position into the Live / AnchorA / AnchorB atlases,
//   3. validates each sample by comparing the cubemap's stored radial depth
//      against the distance the reprojected ray actually travelled,
//   4. blends the two anchors with validity weighting (smooth hand-off), then
//   5. resolves disocclusions via the configured fallback source, and finally
//   6. applies the pixel look (nearest sampling, palette quantization, ordered
//      dithering).
//
// Three details are lifted from the reference implementation and each fixes a
// visible artifact (see level_10_/reference/implementation.md):
//
//   * Seam-free face blending - sample all three axis pairs and weight them by
//     |dir| alignment, instead of hard-switching at the face boundary. Without
//     this you get a straight colour discontinuity along every cube edge.
//   * Camera-distance rejection - tolerance is `abs + dist(camera, probe) * rel`
//     rather than a fraction of the pixel's own distance. The error that matters
//     is how far the camera has strayed from the probe, and a too-loose test is
//     what leaks wrong colours onto disoccluded surfaces.
//   * Quantize-then-blend - each cubemap sample is quantized *before* the two
//     are mixed, so the crossfade passes through intermediate palette colours
//     instead of snapping between them.
//
// The face helpers below mirror shaders/cube_atlas.glslinc, which is the source
// of truth for the face/direction convention. Edit that file first.
// =============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Main scene colour, read and written back.
layout(rgba16f, set = 0, binding = 0) uniform coherent image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D src_depth;

layout(set = 0, binding = 2) uniform sampler2D live_atlas;
layout(set = 0, binding = 3) uniform sampler2D anchor_a_atlas;
layout(set = 0, binding = 4) uniform sampler2D anchor_b_atlas;

layout(std430, set = 0, binding = 5) buffer Params {
	mat4 inv_proj;      // main camera inverse projection (view space)
	mat4 view_to_world; // main camera transform (view -> world)
	vec4 live_center;   // xyz = live cube centre, w unused
	vec4 anchor_a;      // xyz = anchor A centre, w = anchor blend (0 -> A, 1 -> B)
	vec4 anchor_b;      // xyz = anchor B centre, w = capture_resolution
	vec4 occ;           // x abs thr, y rel thr per unit cam dist, z softness, w near-fallback
	vec4 misc;          // x fallback_mode, y debug_mode, z pixelate_sky, w capture_sky
	vec4 px;            // x levels, y dither_strength, z quant_enabled, w dither_enabled
	vec4 px2;           // x quantize_mode, y quantize_in_srgb, z out_w, w out_h
	vec4 extra;         // x face_blend_sharpness, yzw unused
} params;

// --- constants shared with the config resource -------------------------------
const int FALLBACK_ORIGINAL = 0;
const int FALLBACK_LIVE = 1;
const int FALLBACK_LIVE_THEN_ORIGINAL = 2;

const int QUANT_NAIVE = 0;
const int QUANT_LUMA = 1;
const int QUANT_LUMA_CHROMA = 2;

// ---------------------------------------------------------------------------
// Cube atlas sampling (mirror of cube_atlas.glslinc).
// ---------------------------------------------------------------------------
struct CubeSample {
	vec3 color;         // seam-blended linear colour
	float radial_depth; // distance from the capture centre along the dominant ray
	bool is_sky;        // true when alpha < 0 (sky sentinel)
	int face;           // dominant face, 0..5, for debug visualisation
};

// Per-face (view, up) basis. Mirrors CaptureBank.FACE_VIEW / FACE_UP.
void face_basis(int face, out vec3 view, out vec3 up) {
	if (face == 0)      { view = vec3( 1.0, 0.0, 0.0); up = vec3(0.0, -1.0, 0.0); }
	else if (face == 1) { view = vec3(-1.0, 0.0, 0.0); up = vec3(0.0, -1.0, 0.0); }
	else if (face == 2) { view = vec3( 0.0, 1.0, 0.0); up = vec3(0.0,  0.0, 1.0); }
	else if (face == 3) { view = vec3( 0.0,-1.0, 0.0); up = vec3(0.0,  0.0,-1.0); }
	else if (face == 4) { view = vec3( 0.0, 0.0, 1.0); up = vec3(0.0, -1.0, 0.0); }
	else                { view = vec3( 0.0, 0.0,-1.0); up = vec3(0.0, -1.0, 0.0); }
}

// Direction -> UV inside one face tile.
vec2 face_uv(vec3 d, int face) {
	vec3 view;
	vec3 up;
	face_basis(face, view, up);
	vec3 right = normalize(cross(view, up));
	float dv = dot(d, view);
	float u = 0.5 * (1.0 + dot(d, right) / dv);
	float v = 0.5 * (1.0 - dot(d, up) / dv);
	return clamp(vec2(u, v), 0.0, 1.0);
}

// Fetch one specific face tile out of the 3x2 atlas, offset within the face.
vec4 fetch_face_at(sampler2D atlas, vec3 d, int face, vec2 uv_off) {
	vec2 uv = clamp(face_uv(d, face) + uv_off, 0.0, 1.0);
	int col = face % 3;
	int row = face / 3;
	return texture(atlas, (uv + vec2(float(col), float(row))) / vec2(3.0, 2.0));
}

vec4 fetch_face(sampler2D atlas, vec3 d, int face) {
	return fetch_face_at(atlas, d, face, vec2(0.0));
}

int dominant_face(vec3 d) {
	vec3 ad = abs(d);
	if (ad.x >= ad.y && ad.x >= ad.z) {
		return (d.x >= 0.0) ? 0 : 1;
	}
	if (ad.y >= ad.z) {
		return (d.y >= 0.0) ? 2 : 3;
	}
	return (d.z >= 0.0) ? 4 : 5;
}

// How much a stored radial depth agrees with the surface we are drawing.
// 1 = the probe saw this exact surface, 0 = it saw something else entirely.
float depth_agreement(float stored, float expected, float tol) {
	if (stored < 0.0) {
		return 0.0; // sky sentinel: the probe saw nothing here
	}
	return 1.0 - smoothstep(tol, tol * 2.0, abs(stored - expected));
}

// Seam-free AND surface-aware colour.
//
// Blending the three axis pairs removes the hard discontinuity along cube
// edges, but each face has its own texel grid, so at a given direction one
// face's nearest texel can have seen a *different* surface than another's.
// Blending them unconditionally mixes two different surfaces together, which
// is how a band of the occluder's colour ends up painted on the ground behind
// it (measured: solid orange band over ground the raw scene renders green,
// with a *valid* depth reading, because only the dominant face's depth was
// being checked).
//
// So each axis pair only contributes if its own stored depth agrees with the
// surface being drawn.
vec3 sample_cube_color_at(
	sampler2D atlas, vec3 d, float sharpness, vec2 uv_off, float expected, float tol
) {
	vec3 ad = abs(d);
	float max_axis = max(max(ad.x, ad.y), ad.z);
	vec3 w = pow(ad / max_axis, vec3(max(sharpness, 1.0)));

	// The face that actually contains this direction, per axis.
	vec4 cx = fetch_face_at(atlas, d, (d.x >= 0.0) ? 0 : 1, uv_off);
	vec4 cy = fetch_face_at(atlas, d, (d.y >= 0.0) ? 2 : 3, uv_off);
	vec4 cz = fetch_face_at(atlas, d, (d.z >= 0.0) ? 4 : 5, uv_off);

	w.x *= depth_agreement(cx.a, expected, tol);
	w.y *= depth_agreement(cy.a, expected, tol);
	w.z *= depth_agreement(cz.a, expected, tol);

	float ws = w.x + w.y + w.z;
	if (ws < 1e-5) {
		// Nothing agrees; let the caller's validity test reject this sample.
		return fetch_face_at(atlas, d, dominant_face(d), uv_off).rgb;
	}
	w /= ws;
	return w.x * cx.rgb + w.y * cy.rgb + w.z * cz.rgb;
}

// Full sample at a sub-texel offset: surface-aware seam-blended colour, plus
// strict single-face depth/validity data.
CubeSample sample_cube_atlas_at(
	sampler2D atlas, vec3 d, vec2 uv_off, float expected, float tol
) {
	int face = dominant_face(d);
	vec4 tex = fetch_face_at(atlas, d, face, uv_off);

	CubeSample s;
	s.color = sample_cube_color_at(atlas, d, params.extra.x, uv_off, expected, tol);
	s.radial_depth = tex.a;
	s.is_sky = tex.a < 0.0;
	s.face = face;
	return s;
}

CubeSample sample_cube_atlas(sampler2D atlas, vec3 direction, float res) {
	// Debug / sky paths only: no expected depth available, so no gating.
	vec3 d = normalize(direction);
	int face = dominant_face(d);
	vec4 tex = fetch_face(atlas, d, face);
	CubeSample s;
	s.color = tex.rgb;
	s.radial_depth = tex.a;
	s.is_sky = tex.a < 0.0;
	s.face = face;
	return s;
}

// Depth-guided sub-texel selection.
//
// The texel whose centre ray points closest to this pixel is not necessarily
// the texel that saw this surface: right at a silhouette the nearest centre can
// belong to a texel that saw the occluder. Evaluate a small cross of sub-texel
// taps and keep the one whose stored depth agrees best.
CubeSample sample_cube_atlas_depth_guided(
	sampler2D atlas, vec3 d, float expected, float tol
) {
	float texel = 1.0 / max(params.anchor_b.w, 1.0);
	// 0.45 texels: far enough to reach a neighbouring texel, small enough that
	// a tap still describes roughly the same surface.
	const float TAP = 0.45;

	CubeSample best = sample_cube_atlas_at(atlas, d, vec2(0.0), expected, tol);
	float best_err = best.is_sky ? 1e30 : abs(best.radial_depth - expected);

	vec2 offs[4] = vec2[4](
		vec2( TAP, 0.0) * texel,
		vec2(-TAP, 0.0) * texel,
		vec2(0.0,  TAP) * texel,
		vec2(0.0, -TAP) * texel
	);
	for (int i = 0; i < 4; i++) {
		CubeSample s = sample_cube_atlas_at(atlas, d, offs[i], expected, tol);
		if (s.is_sky) {
			continue;
		}
		float err = abs(s.radial_depth - expected);
		if (err < best_err) {
			best_err = err;
			best = s;
		}
	}
	return best;
}

// ---------------------------------------------------------------------------
// Ordered dithering (4x4 Bayer).
// ---------------------------------------------------------------------------
float bayer4(ivec2 p) {
	const int m[16] = int[16](
		0,  8,  2, 10,
		12, 4, 14,  6,
		3, 11,  1,  9,
		15, 7, 13,  5
	);
	return float(m[(p.y & 3) * 4 + (p.x & 3)]) / 16.0;
}

// ---------------------------------------------------------------------------
// Palette quantization. sRGB round-trips give perceptually even steps; the
// luma / luma-chroma modes avoid the hue shifting that naive per-channel
// rounding produces on saturated colours.
// ---------------------------------------------------------------------------
vec3 linear_to_srgb(vec3 c) {
	vec3 lo = c * 12.92;
	vec3 hi = 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(lo, hi, step(vec3(0.0031308), c));
}

vec3 srgb_to_linear(vec3 c) {
	vec3 lo = c / 12.92;
	vec3 hi = pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
	return mix(lo, hi, step(vec3(0.04045), c));
}

float quantize_channel(float x, float levels) {
	return floor(x * levels + 0.5) / levels;
}

vec3 quantize_color(vec3 color, int mode, float levels, int use_srgb) {
	if (levels < 1.0) {
		return color;
	}
	vec3 c = (use_srgb != 0) ? linear_to_srgb(color) : color;

	if (mode == QUANT_NAIVE) {
		c = vec3(
			quantize_channel(c.r, levels),
			quantize_channel(c.g, levels),
			quantize_channel(c.b, levels)
		);
	} else {
		// YCoCg: a cheap reversible luma/chroma split.
		float y = dot(c, vec3(0.25, 0.5, 0.25));
		float co = dot(c, vec3(0.5, 0.0, -0.5));
		float cg = dot(c, vec3(-0.25, 0.5, -0.25));

		y = quantize_channel(y, levels);
		if (mode == QUANT_LUMA_CHROMA) {
			co = quantize_channel(co, levels);
			cg = quantize_channel(cg, levels);
		}

		c = vec3(y + co - cg, y + cg, y - co - cg);
	}

	return (use_srgb != 0) ? srgb_to_linear(c) : c;
}

// Dither, then quantize. Dithering happens in the same space as the
// quantization so one step of noise equals exactly one palette step.
vec3 apply_pixel_look(vec3 color, ivec2 pix) {
	int quant_enabled = int(params.px.z + 0.5);
	int dither_enabled = int(params.px.w + 0.5);
	int use_srgb = int(params.px2.y + 0.5);
	float levels = max(params.px.x, 1.0);

	if (dither_enabled != 0 && quant_enabled != 0) {
		vec3 space = (use_srgb != 0) ? linear_to_srgb(color) : color;
		space += vec3((bayer4(pix) - 0.5) * params.px.y / levels);
		color = (use_srgb != 0) ? srgb_to_linear(space) : space;
	}

	if (quant_enabled != 0) {
		color = quantize_color(color, int(params.px2.x + 0.5), levels, use_srgb);
	}
	return color;
}

// ---------------------------------------------------------------------------
// Reprojection + depth validation for one cube centre.
//
// The stored depth is the distance from the probe centre to the surface along
// this texel's ray. `expected` is the same quantity for the pixel we are
// drawing. If the probe could see this surface, the two must agree; a large
// gap means the probe was looking at something else (a disocclusion).
// ---------------------------------------------------------------------------
vec3 reproject_face(
	sampler2D atlas,
	vec3 center,
	vec3 world_pos,
	vec3 cam_pos,
	ivec2 pix,
	out float valid,
	out int face
) {
	float res = params.anchor_b.w;
	vec3 delta = world_pos - center;
	float expected = length(delta);
	vec3 dir = expected > 1e-5 ? delta / expected : vec3(0.0, 0.0, 1.0);

	// Tolerance has to cover two independent error sources:
	//
	//  * The cubemap's own angular resolution. The stored depth belongs to the
	//    texel's *centre* ray, not to this pixel's ray. On a surface seen at a
	//    grazing angle one texel spans a large depth range, so this term must
	//    scale with the pixel's distance. Without it, shallow ground is
	//    rejected wholesale and the effect silently falls back to the raw
	//    scene over most of the floor.
	//  * How far the camera has strayed from the probe, which is what turns
	//    stale samples into wrong-colour patches on disoccluded surfaces.
	//
	// (Reference uses reject = 0.01 + cam_dist * 0.05; the per-pixel term is an
	// addition, needed because that formula alone rejects grazing ground.)
	float cam_dist = length(cam_pos - center);
	float tol = max(
		params.occ.x + expected * params.occ.y + cam_dist * params.extra.y,
		1e-5
	);

	// Depth-guided tap selection so a silhouette texel cannot paint the
	// occluder's colour onto the surface behind it, and per-face depth gating
	// so the seam blend cannot mix two different surfaces together.
	CubeSample s = sample_cube_atlas_depth_guided(atlas, dir, expected, tol);
	face = s.face;

	if (s.is_sky) {
		valid = 0.0;
		return s.color;
	}

	// |reproj - world_pos| is exactly |captured - expected| because both points
	// lie on the same ray from the probe; the scalar form is cheaper.
	float error = abs(s.radial_depth - expected);
	float hi = max(tol * max(params.occ.z, 1.0001), tol + 1e-6);
	valid = 1.0 - smoothstep(tol, hi, error);

	// Quantize here, before the two anchors are mixed, so the crossfade passes
	// through intermediate palette colours rather than snapping between them.
	return apply_pixel_look(s.color, pix);
}

void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	ivec2 outsz = ivec2(int(params.px2.z + 0.5), int(params.px2.w + 0.5));
	if (pix.x >= outsz.x || pix.y >= outsz.y) {
		return;
	}

	vec4 original = imageLoad(color_image, pix);
	float d = texelFetch(src_depth, pix, 0).r;

	vec2 uv = (vec2(pix) + 0.5) / vec2(outsz);
	vec2 nd = uv * 2.0 - 1.0;

	int fallback = int(params.misc.x + 0.5);
	int dbg = int(params.misc.y + 0.5);

	// Reverse-Z: the cleared / sky value is ~0.0.
	bool is_sky = d <= 1e-6;

	vec3 cam_pos = params.view_to_world[3].xyz;

	// --- reconstruct the world position of this pixel ---
	vec3 world_pos = vec3(0.0);
	float view_dist = 1e9;
	if (!is_sky) {
		vec4 clip = params.inv_proj * vec4(nd, d, 1.0);
		vec3 view = clip.xyz / clip.w;
		view_dist = length(view);
		world_pos = (params.view_to_world * vec4(view, 1.0)).xyz;
	}

	// --- anchor reprojection with validity-weighted temporal blend ---
	float valid_a = 0.0;
	float valid_b = 0.0;
	float valid_live = 0.0;
	int face_a = 0;
	int face_b = 0;
	int face_live = 0;

	vec3 color_a = reproject_face(anchor_a_atlas, params.anchor_a.xyz, world_pos, cam_pos, pix, valid_a, face_a);
	vec3 color_b = reproject_face(anchor_b_atlas, params.anchor_b.xyz, world_pos, cam_pos, pix, valid_b, face_b);

	// Ease the crossfade (reference: t = sqrt(smoothstep(0, 1, temporal_blend))).
	float raw_blend = clamp(params.anchor_a.w, 0.0, 1.0);
	float blend = sqrt(smoothstep(0.0, 1.0, raw_blend));

	float w_a = valid_a * (1.0 - blend);
	float w_b = valid_b * blend;
	float w_sum = w_a + w_b;

	vec3 anchor_color;
	float anchor_valid;
	if (w_sum > 1e-4) {
		anchor_color = (color_a * w_a + color_b * w_b) / w_sum;
		anchor_valid = clamp(w_sum, 0.0, 1.0);
	} else {
		anchor_color = original.rgb;
		anchor_valid = 0.0;
	}

	vec3 live_color = reproject_face(live_atlas, params.live_center.xyz, world_pos, cam_pos, pix, valid_live, face_live);

	// --- fallback selection ---
	vec3 out_color;
	int source = 0; // 0 anchor, 1 live, 2 original, 3 sky
	if (is_sky) {
		source = 3;
		if (int(params.misc.z + 0.5) != 0) {
			// Pixelated sky: march the current camera ray through the live
			// capture so the skybox quantizes like everything else.
			vec4 v0 = params.inv_proj * vec4(nd, 0.5, 1.0);
			vec3 dir_view = v0.xyz / v0.w;
			vec3 dir_world = normalize((params.view_to_world * vec4(dir_view, 1.0)).xyz - cam_pos);
			vec3 sky_col = sample_cube_atlas(live_atlas, dir_world, params.anchor_b.w).color;
			out_color = apply_pixel_look(sky_col, pix);
		} else {
			out_color = original.rgb;
		}
	} else if (anchor_valid > 1e-3) {
		source = 0;
		out_color = anchor_color;
	} else if (fallback == FALLBACK_LIVE) {
		// Always take the live capture, even where its depth disagrees: fully
		// pixelated, at the cost of more crawling at disocclusion edges.
		source = 1;
		out_color = live_color;
	} else if (valid_live > 1e-3) {
		source = 1;
		out_color = live_color;
	} else {
		source = 2;
		out_color = original.rgb;
	}

	// --- near-camera original fallback (weapons / near walls) ---
	// Deliberately after quantization: this path is meant to look like the raw
	// scene, not like palette-reduced pixel art.
	float near_f = params.occ.w;
	float near_blend = is_sky ? 0.0 : (1.0 - smoothstep(near_f * 0.5, near_f, view_dist));
	out_color = mix(out_color, original.rgb, near_blend);

	// --- debug visualisation (bypasses the pixel look) ---
	if (dbg == 1) {
		out_color = original.rgb;
	} else if (dbg == 2) {
		out_color = live_color;
	} else if (dbg == 3) {
		out_color = color_a;
	} else if (dbg == 4) {
		out_color = color_b;
	} else if (dbg == 5) {
		vec3 delta_d = world_pos - params.anchor_a.xyz;
		float expected = max(length(delta_d), 1e-5);
		float captured = sample_cube_atlas(anchor_a_atlas, delta_d / expected, params.anchor_b.w).radial_depth;
		out_color = vec3(clamp(abs(captured - expected) / 2.0, 0.0, 1.0));
	} else if (dbg == 6) {
		out_color = mix(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), anchor_valid);
	} else if (dbg == 7) {
		vec3 delta_f = world_pos - params.live_center.xyz;
		int f = (length(delta_f) > 1e-5)
			? sample_cube_atlas(live_atlas, delta_f, params.anchor_b.w).face
			: 0;
		vec3 face_cols[6];
		face_cols[0] = vec3(1.0, 0.0, 0.0);
		face_cols[1] = vec3(0.0, 1.0, 0.0);
		face_cols[2] = vec3(0.0, 0.0, 1.0);
		face_cols[3] = vec3(1.0, 1.0, 0.0);
		face_cols[4] = vec3(1.0, 0.0, 1.0);
		face_cols[5] = vec3(0.0, 1.0, 1.0);
		out_color = is_sky ? vec3(0.0) : face_cols[f];
	} else if (dbg == 8) {
		if (is_sky)            out_color = vec3(0.0, 0.0, 1.0);
		else if (source == 0)  out_color = vec3(0.0, 1.0, 0.0);
		else if (source == 1)  out_color = vec3(0.0, 1.0, 1.0);
		else                   out_color = vec3(1.0, 1.0, 0.0);
	} else if (dbg == 9) {
		// Face-blend weights: how much each axis pair contributes. Confirms the
		// seam-removal blend is engaging near cube edges (should show soft
		// gradients along the diagonals rather than hard steps).
		vec3 delta_w = world_pos - params.live_center.xyz;
		vec3 dd = normalize(length(delta_w) > 1e-5 ? delta_w : vec3(0.0, 0.0, 1.0));
		vec3 ad = abs(dd);
		float mx = max(max(ad.x, ad.y), ad.z);
		vec3 w = pow(ad / mx, vec3(max(params.extra.x, 1.0)));
		w /= (w.x + w.y + w.z);
		out_color = is_sky ? vec3(0.0) : w;
	}

	imageStore(color_image, pix, vec4(out_color, original.a));
}
