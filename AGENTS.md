# Project instructions — pixel_shader_demo

## You cannot see images

The main model is **text-only**. `read_image` on any PNG will fail. Do not claim
a shader, material, or rendering effect "looks right" based on code alone.

## Always verify visual work by looking

This project has a working vision loop. **Use it whenever you create, modify, or
debug anything visual** — shaders, materials, gradients, pixelation, blur,
post-processing, HUD. Also use it before reporting that a visual change is done.

```
edit shader → project_run → capture frame → look + measure → judge → fix → repeat
```

Load the **`godot-vision`** skill for the full procedure. Short version:

1. **Capture** — via Godot MCP `editor_manage` / `game_eval`:
   ```gdscript
   var sc = Engine.get_main_loop().root.get_node("ScreenCapture")
   return await sc.capture("name")
   ```
   `capture("name")` gives a stable filename for before/after; `capture()` numbers
   frames without overwriting.

2. **Look** — `node tools/look_at_frame.cjs screenshots/name.png`
   (add a second image to compare two frames)

3. **Measure** — `node tools/pixel_diff.cjs screenshots/before.png screenshots/after.png`
   Prefer this number over a model's prose. It reports `DIFF RATIO` plus the worst
   grid cells with pixel coordinates.

## Ground rules

- **Measure every visual change** with `pixel_diff.cjs`. A description cannot tell
  you whether the effect converged.
- Vision output is **evidence, not ground truth** — cross-check with pixel numbers.
- Do not delete `screenshots/.gdignore`; it keeps Godot from importing capture churn.
- Do not ask the user to paste screenshots. Use the loop above.

Reference: `docs/VISION_LOOP.md`
