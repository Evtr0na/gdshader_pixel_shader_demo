class_name ShadowGlassConfig
extends Resource
## Runtime-tunable configuration for the Shadow Glass cubemap
## reprojection system. All values are plain typed fields so they survive
## hot-reload and can be toggled from the demo scene / debug keys.

enum FallbackMode {
	ORIGINAL_SCENE = 0,   ## Invalid reprojection falls straight back to original scene color.
	LIVE_CAPTURE = 1,     ## Invalid reprojection falls back to the live (camera-following) capture.
	LIVE_THEN_ORIGINAL = 2, ## Try live capture first, then original scene color.
}

enum DebugMode {
	FINAL = 0,
	ORIGINAL = 1,
	LIVE_ONLY = 2,
	ANCHOR_A_ONLY = 3,
	ANCHOR_B_ONLY = 4,
	DEPTH_ERROR = 5,
	VALIDITY = 6,
	FACE_INDEX = 7,
	FALLBACK_SOURCE = 8,
}

## Master switch. When false the reprojection effect passes original scene through.
@export var enabled: bool = true

## Edge length in pixels for a single cube face (atlas is 3x2 faces).
@export var capture_resolution: int = 128

## World-units distance the camera must travel from the active anchor before a
## new anchor capture is triggered.
@export var capture_distance: float = 4.0

## Seconds over which the anchor crossfade completes.
@export var transition_time: float = 0.5

@export var capture_near: float = 0.1
@export var capture_far: float = 256.0

## Cull mask used by all six capture cameras. Default excludes visual layer 20
## (bit 19 == first-person weapon/arms).
@export var capture_cull_mask: int = 0x7FFFF

@export var capture_sky: bool = true
@export var pixelate_sky: bool = false

## Occlusion / depth-consistency validation.
@export var occlusion_absolute_threshold: float = 0.05
@export var occlusion_relative_threshold: float = 0.01
@export var occlusion_softness: float = 2.0

## Geometry pixels closer than this (view distance from main camera) fade back
## to original scene color, protecting weapons / near walls from stretching.
@export var near_original_fallback_distance: float = 0.8

@export var fallback_mode: FallbackMode = FallbackMode.LIVE_THEN_ORIGINAL

## Use nearest filtering when sampling the capture atlas (pixel-art look).
@export var nearest_sampling: bool = true

@export var debug_mode: DebugMode = DebugMode.FINAL
@export var debug_freeze_live: bool = false
@export var debug_freeze_anchor: bool = false
@export var debug_show_face_index: bool = false
@export var debug_show_depth: bool = false
@export var debug_show_validity: bool = false

@export var pixel_quantization_enabled: bool = false
@export_range(2, 256, 1, "or_greater") var quantization_levels: int = 16

@export var dither_enabled: bool = false
@export_range(0.0, 1.0, 0.01) var dither_strength: float = 1.0


func _to_dict() -> Dictionary:
	## Compact snapshot used by the system to push uniforms to the GPU.
	return {
		"enabled": enabled,
		"capture_resolution": capture_resolution,
		"capture_distance": capture_distance,
		"transition_time": transition_time,
		"capture_near": capture_near,
		"capture_far": capture_far,
		"capture_cull_mask": capture_cull_mask,
		"capture_sky": capture_sky,
		"pixelate_sky": pixelate_sky,
		"occlusion_absolute_threshold": occlusion_absolute_threshold,
		"occlusion_relative_threshold": occlusion_relative_threshold,
		"occlusion_softness": occlusion_softness,
		"near_original_fallback_distance": near_original_fallback_distance,
		"fallback_mode": int(fallback_mode),
		"nearest_sampling": nearest_sampling,
		"debug_mode": int(debug_mode),
		"debug_freeze_live": debug_freeze_live,
		"debug_freeze_anchor": debug_freeze_anchor,
		"debug_show_face_index": debug_show_face_index,
		"debug_show_depth": debug_show_depth,
		"debug_show_validity": debug_show_validity,
		"pixel_quantization_enabled": pixel_quantization_enabled,
		"quantization_levels": quantization_levels,
		"dither_enabled": dither_enabled,
		"dither_strength": dither_strength,
	}