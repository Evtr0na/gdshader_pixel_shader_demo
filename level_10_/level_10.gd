extends Node3D
## Level 10 demo controller — Project Shadow Glass style 3D pixel art.
##
## Owns the on-screen HUD, drives ShadowGlassConfig from the keyboard, and adds
## two camera moves that make the technique easy to judge:
##   * R = rotate in place. Rotation must be perfectly stable; if the image
##     shimmers here, the cube map is wrong.
##   * T = dolly in and out. Translation is where the anchor crossfade and the
##     disocclusion fallback show up.
##   * A = hands-free orbit, so the effect can be watched without touching keys.
##
## Every HUD change writes straight into `config`; ShadowGlassSystem pushes it
## to the GPU on the next frame.

@onready var system: ShadowGlassSystem = $ShadowGlassSystem
@onready var camera: Camera3D = $MainCamera

var _hud: RichTextLabel
var _hud_timer := 0.0

var _auto := false
var _auto_t := 0.0
var _spin_t := 0.0
var _dolly_t := 0.0
var _auto_center := Vector3.ZERO

const ORBIT_RADIUS := 11.0
const ORBIT_HEIGHT := 3.5


func _ready() -> void:
	_auto_center = camera.global_position + Vector3(0, -ORBIT_HEIGHT, 0)
	_auto_center.y = 0.0
	_build_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(14, 10)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1, 1, 1, 0.92)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	_hud = RichTextLabel.new()
	_hud.name = "Help"
	_hud.bbcode_enabled = true
	_hud.fit_content = true
	_hud.scroll_active = false
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.custom_minimum_size = Vector2(440, 0)
	margin.add_child(_hud)
	_refresh_hud()


func _refresh_hud() -> void:
	if _hud == null or system == null or system.config == null:
		return
	var cfg := system.config
	_hud.text = (
		"[b]Level 10 — 3D Pixel Art (cube map reprojection)[/b]\n"
		+ "[color=#7ab]RMB[/color] grab mouse · [color=#7ab]WASD/QE[/color] fly · "
		+ "[color=#7ab]Shift[/color] sprint\n"
		+ "[color=#7ab]R[/color] rotate · [color=#7ab]T[/color] dolly · "
		+ "[color=#7ab]A[/color] auto-orbit\n"
		+ "\n"
		+ "resolution   [color=#fc6]%d[/color]  (F6)\n" % cfg.capture_resolution
		+ "quantize     [color=#fc6]%s[/color]  (Q)   " % _on_off(cfg.quantization_enabled)
		+ "dither [color=#fc6]%s[/color]  (D)\n" % _on_off(cfg.dither_enabled)
		+ "quant mode   [color=#fc6]%s[/color]  (M)\n" % _enum_name(
			ShadowGlassConfig.QuantizeMode, int(cfg.quantize_mode)
		)
		+ "quant levels [color=#fc6]%d[/color]  ( [ / ] )\n" % cfg.quantization_levels
		+ "fallback     [color=#fc6]%s[/color]  (F)\n" % _enum_name(
			ShadowGlassConfig.FallbackMode, int(cfg.fallback_mode)
		)
		+ "depth tol    [color=#fc6]%.3f[/color]  ( , / . )   " % cfg.occlusion_relative_threshold
		+ "face blend [color=#fc6]%.0f[/color]  ( ; / ' )\n" % cfg.face_blend_sharpness
		+ "capture dist [color=#fc6]%.1f[/color]  ( - / = )   " % cfg.capture_distance
		+ "blend [color=#fc6]%.2fs[/color]  (N)\n" % cfg.transition_time
		+ "sky          [color=#fc6]%s[/color]  (K)\n" % (
			"pixelated" if cfg.pixelate_sky else "raw scene"
		)
		+ "cubemap sky  [color=#fc6]%s[/color]  (J)\n" % _on_off(cfg.capture_sky)
		+ "anchor       [color=#fc6]%s[/color]  (H)   " % (
			"frozen" if cfg.debug_freeze_anchor else "auto-capture"
		)
		+ "live [color=#fc6]%s[/color]  (G)\n" % (
			"frozen" if cfg.debug_freeze_live else "tracking"
		)
		+ "\n"
		+ "[color=#7ab]F1[/color] effect on/off · [color=#7ab]F2[/color] validity · "
		+ "[color=#7ab]F3[/color] original · [color=#7ab]F5[/color] force capture\n"
		+ "debug view   [color=#fc6]%s[/color]  (0-9)\n" % _enum_name(
			ShadowGlassConfig.DebugMode, int(cfg.debug_mode)
		)
		+ "[color=#888]ESC quit[/color]"
	)


func _on_off(v: bool) -> String:
	return "on" if v else "off"


func _enum_name(enum_dict: Dictionary, value: int) -> String:
	for key in enum_dict:
		if enum_dict[key] == value:
			return str(key)
	return str(value)


func _process(delta: float) -> void:
	if _auto:
		_auto_t += delta * 0.35
		camera.global_position = _auto_center + Vector3(
			cos(_auto_t) * ORBIT_RADIUS, ORBIT_HEIGHT, sin(_auto_t) * ORBIT_RADIUS
		)
		camera.look_at(_auto_center + Vector3(0, 1.5, 0), Vector3.UP)
	elif Input.is_key_pressed(KEY_R):
		_spin_t += delta * 0.7
		camera.rotate_object_local(Vector3.UP, delta * 0.7)
	elif Input.is_key_pressed(KEY_T):
		_dolly_t += delta
		camera.global_position -= (
			camera.global_transform.basis.z * sin(_dolly_t * 1.5) * delta * 7.0
		)

	# The system's own debug keys (F1-F6) also change config, so poll the HUD
	# at a low rate instead of trying to hook every writer.
	_hud_timer += delta
	if _hud_timer >= 0.15:
		_hud_timer = 0.0
		_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var cfg := system.config
	match (event as InputEventKey).keycode:
		KEY_Q:
			cfg.quantization_enabled = not cfg.quantization_enabled
		KEY_D:
			cfg.dither_enabled = not cfg.dither_enabled
		KEY_M:
			cfg.quantize_mode = (
				(int(cfg.quantize_mode) + 1) % 3
			) as ShadowGlassConfig.QuantizeMode
		KEY_F:
			cfg.fallback_mode = (
				(int(cfg.fallback_mode) + 1) % 3
			) as ShadowGlassConfig.FallbackMode
		KEY_K:
			cfg.pixelate_sky = not cfg.pixelate_sky
		KEY_J:
			cfg.capture_sky = not cfg.capture_sky
			system.rebuild()
		KEY_H:
			cfg.debug_freeze_anchor = not cfg.debug_freeze_anchor
		KEY_G:
			cfg.debug_freeze_live = not cfg.debug_freeze_live
		KEY_A:
			_auto = not _auto
			_auto_t = 0.0
		KEY_BRACKETLEFT:
			cfg.quantization_levels = maxi(2, cfg.quantization_levels - 2)
		KEY_BRACKETRIGHT:
			cfg.quantization_levels = mini(64, cfg.quantization_levels + 2)
		KEY_MINUS:
			cfg.capture_distance = maxf(0.5, cfg.capture_distance - 0.5)
		KEY_EQUAL:
			cfg.capture_distance = minf(64.0, cfg.capture_distance + 0.5)
		KEY_COMMA:
			cfg.occlusion_relative_threshold = maxf(
				0.001, cfg.occlusion_relative_threshold - 0.005
			)
		KEY_PERIOD:
			cfg.occlusion_relative_threshold = minf(
				0.5, cfg.occlusion_relative_threshold + 0.005
			)
		KEY_SEMICOLON:
			cfg.face_blend_sharpness = maxf(1.0, cfg.face_blend_sharpness / 1.5)
		KEY_APOSTROPHE:
			cfg.face_blend_sharpness = minf(256.0, cfg.face_blend_sharpness * 1.5)
		KEY_N:
			cfg.transition_time = 0.0 if cfg.transition_time > 0.001 else 0.5
		KEY_ESCAPE:
			get_tree().quit()
		_:
			var keycode := (event as InputEventKey).keycode
			if keycode >= KEY_0 and keycode <= KEY_9:
				cfg.debug_mode = (keycode - KEY_0) as ShadowGlassConfig.DebugMode
	_refresh_hud()
