extends Node
## Deterministic frame capture for the shader iteration loop.
##
## A text-only agent cannot see the Godot window. This autoload turns
## "what does the shader look like right now?" into a PNG at a known path,
## so vision tools (vision_describe / vision_pixel_diff / vision_colors) can
## read the real rendered pixels and reason about them.
##
## Agent usage, from MCP game_eval:
##     var sc := Engine.get_main_loop().root.get_node("ScreenCapture")
##     var p: String = await sc.capture("after_blur")
##     return p
##
## Human usage: press F12.
##   * capture()             -> frame_0001.png, frame_0002.png, ... (never overwrites)
##   * capture("after_blur") -> after_blur.png (stable name, ideal for pixel_diff)
##
## Files land in <project>/screenshots/ when running from the editor.

const DIR := "res://screenshots"
const PREFIX := "frame_"

var _counter := 0


func _ready() -> void:
	_ensure_dir()


func _ensure_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(DIR)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_F12:
			await capture()


## Capture the current frame and write it as PNG. Waits for the frame to
## finish drawing first, so the image is never one frame stale.
## Returns the absolute path written, or "" on failure.
func capture(name_hint := "") -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("ScreenCapture: viewport image unavailable")
		return ""
	_ensure_dir()
	var abs_dir := ProjectSettings.globalize_path(DIR)
	var fname: String
	if name_hint.is_empty():
		_counter += 1
		fname = "%s%04d.png" % [PREFIX, _counter]
	else:
		fname = "%s.png" % name_hint
	var abs_path := abs_dir.path_join(fname)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("ScreenCapture: save_png failed (%d) for %s" % [err, abs_path])
		return ""
	print("ScreenCapture: wrote %s (%dx%d)" % [abs_path, img.get_width(), img.get_height()])
	return abs_path
