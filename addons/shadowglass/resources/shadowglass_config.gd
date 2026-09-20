class_name ShadowGlassConfig
extends Resource
## Runtime-tunable configuration for the Shadow Glass cubemap reprojection
## system. Every field is a plain typed value so it survives hot-reload and can
## be driven from a demo scene, the inspector, or the debug keys.
##
## See level_10_/reference/implementation.md for how each value maps onto the
## two-stage technique (capture -> reproject).

## How invalid (disoccluded) reprojection results are resolved.
enum FallbackMode {
	ORIGINAL_SCENE = 0,     ## Show the real (smooth) scene colour. Zero flicker.
	LIVE_CAPTURE = 1,       ## Show the camera-following capture. Fully pixelated.
	LIVE_THEN_ORIGINAL = 2, ## Live capture first, original scene if that also fails.
}

## Channel-space used when quantizing to a limited palette.
enum QuantizeMode {
	NAIVE = 0,       ## Per-channel rounding in display space.
	LUMA = 1,        ## Quantize luminance only, keep chroma continuous.
	LUMA_CHROMA = 2, ## Quantize luminance and chroma separately (best banding control).
}

## Full-screen visualization override. Anything other than FINAL also disables
## quantization / dithering so the debug image stays readable.
enum DebugMode {
	FINAL = 0,
	ORIGINAL = 1,      ## Bypass the effect entirely.
	LIVE_ONLY = 2,     ## Live (camera-following) capture only.
	ANCHOR_A_ONLY = 3,
	ANCHOR_B_ONLY = 4,
	DEPTH_ERROR = 5,   ## Radial depth mismatch magnitude vs. anchor A.
	VALIDITY = 6,      ## Red = disoccluded, green = valid.
	FACE_INDEX = 7,    ## Colour-code which cube face was sampled.
	FALLBACK_SOURCE = 8, ## Colour-code which source produced the pixel.
	FACE_BLEND = 9,    ## Per-axis blend weights (verifies seam-free sampling).
}

## Master switch. When false the reprojection effect passes the scene through.
@export var enabled: bool = true

## Edge length in pixels of one cube face. The atlas is 3x2 faces, so the GPU
## texture is (3*res) x (2*res). 64-256 is the useful range.
@export_range(16, 1024, 1, "or_greater") var capture_resolution: int = 128

## World-space distance the camera may travel from the active anchor before a
## fresh anchor capture is triggered and crossfaded in.
@export var capture_distance: float = 4.0

## Seconds the anchor-to-anchor crossfade takes. 0 snaps instantly.
@export_range(0.0, 4.0, 0.01) var transition_time: float = 0.5

## Number of frames to let the inactive anchor bank render before blending.
@export_range(1, 16, 1) var capture_warmup_frames: int = 3

@export var capture_near: float = 0.05
@export var capture_far: float = 512.0

## Cull mask used by the six capture cameras. Bit 19 (value 0x80000) is cleared
## by default so a first-person weapon on layer 20 is excluded from the cubemap.
@export_flags_3d_render var capture_cull_mask: int = 0x7FFFF

## When false the capture cameras use a flat background instead of the sky, so
## geometry meeting the skyline stops crawling (at the cost of a flat sky in the
## cubemap).
@export var capture_sky: bool = true
## Background colour used when capture_sky is false. Leave at the sky horizon
## colour so the seam is hard to spot.
@export var capture_sky_color: Color = Color(0.66, 0.67, 0.69, 1.0)

## Sample the cubemap along the camera ray for sky pixels, which pixelates the
## skybox the same way as the geometry.
@export var pixelate_sky: bool = false

## Occlusion / depth-consistency validation. A reprojected sample is accepted
## when |captured_radial_depth - expected_radial_depth| is below
##
##     absolute + expected * relative + dist(camera, probe) * probe_relative
##
## Three terms, because there are three independent error sources:
##
##  * `absolute` is the floor - sub-centimetre noise.
##  * `relative` scales with the pixel's own distance. The cubemap stores depth
##    for each texel's *centre* ray, so on a surface seen at a grazing angle one
##    texel spans a large depth range. Without this term shallow ground is
##    rejected wholesale and the effect falls back to the raw scene across most
##    of the floor (measured: 55-60% of the frame).
##  * `probe_relative` scales with how far the camera has strayed from the cube
##    centre. That distance is what turns a stale sample into a wrong-colour
##    patch on a disoccluded surface. This is the reference's term
##    (reject = 0.01 + cam_dist * 0.05).
##
## Too loose overall and stale samples survive as colour leakage; too tight and
## valid geometry is thrown away, which shows up as a smooth, un-pixelated floor.
@export var occlusion_absolute_threshold: float = 0.01
@export_range(0.0, 0.5, 0.001) var occlusion_relative_threshold: float = 0.03
@export_range(0.0, 0.5, 0.001) var occlusion_probe_threshold: float = 0.05
## Width of the accept/reject fade band, as a multiple of the tolerance.
@export_range(1.0, 16.0, 0.1) var occlusion_softness: float = 2.0

## How sharply the six cube faces are blended when sampling.
##
## 1.0 blends the three axis pairs almost evenly; high values approach a hard
## per-face lookup. This is a narrow trade-off and both extremes are visibly
## wrong: a soft blend smears two different texel grids together and covers the
## surface in diagonal hatch streaks, while a hard lookup leaves a crisp seam
## line along every cube edge.
##
## ~77 is the value the reference implementation ships (its material had
## 77.299). At that sharpness the blend only engages in a thin band right at the
## edge, so the seam is softened without streaking. Measured: going 8 -> 77
## removes almost all hatch artifacts while reintroducing only faint seam lines.
@export_range(1.0, 256.0, 0.5) var face_blend_sharpness: float = 77.0

## Geometry closer than this (view distance from the main camera) fades back to
## the original scene colour, protecting weapons / near walls from stretching.
@export var near_original_fallback_distance: float = 0.6

@export var fallback_mode: FallbackMode = FallbackMode.LIVE_THEN_ORIGINAL

## Nearest filtering on the capture atlas is what produces the hard pixel edges.
@export var nearest_sampling: bool = true

## --- Pixel look -------------------------------------------------------------

@export var quantization_enabled: bool = false
@export var quantize_mode: QuantizeMode = QuantizeMode.LUMA_CHROMA
## Number of steps per quantized channel. 4-32 reads as a retro palette.
@export_range(2, 256, 1, "or_greater") var quantization_levels: int = 12
## Quantize in gamma (sRGB) space, which spreads the steps perceptually instead
## of crushing all the detail into the dark end.
@export var quantize_in_srgb: bool = true

## Ordered dithering, applied before quantization.
##
## Off by default. A global Bayer pass puts a regular pattern on *every* flat
## surface, including ones with no gradient to break up, and at 128px that reads
## as speckle rather than texture. Verified by A/B: with dithering on, the deck,
## sky and ground all pick up a mechanical grid; with it off they read as
## deliberate flat colour blocks.
##
## Worth enabling for gradient-heavy scenes (large smooth skies, day-night
## cycles) where banding is the bigger problem than noise.
@export var dither_enabled: bool = false
## Ordered-dither amplitude in quantization steps. 1.0 is a full palette step of
## noise, which shreds smooth dark gradients (contact shadows) into speckle.
@export_range(0.0, 2.0, 0.01) var dither_strength: float = 0.35

## --- Debug ------------------------------------------------------------------

@export var debug_mode: DebugMode = DebugMode.FINAL
## Freeze the camera-following capture (shows how much the live bank matters).
@export var debug_freeze_live: bool = false
## Freeze anchor re-capture (shows disocclusion growing as you walk away).
@export var debug_freeze_anchor: bool = false
