---
name: godot-vision
description: Give yourself eyes on Godot render output. Use this whenever you create, modify, or debug a Godot shader, material, or rendering effect; whenever you need to judge how something actually looks in the running game; or whenever the user asks about visual output such as pixelation, blur, aliasing, colors, gradients, artifacts, or on-screen HUD. Captures the running game to a PNG and reads it with a vision model, so a text-only main model can verify visual work instead of guessing. Also use before claiming any visual change is correct.
---

# Godot Vision Loop

## Why this exists

The main model (`deepseek-v4.1-flash` and other text-only routes) **cannot see images**.
Calling `read_image` or reading a PNG will fail with "does not declare image input".

Therefore: **never claim a shader or visual change "looks right" without actually looking.**
Guessing from code alone is the failure mode this skill prevents.

## The loop

```
edit shader → run game → capture frame → look + measure → judge → fix → repeat
```

## 1. Capture a frame

The project has a `ScreenCapture` autoload that writes the current frame to
`screenshots/`. Drive it through the Godot MCP tool `editor_manage` with
`op="game_eval"` (the game must be running — use `project_run` first):

```gdscript
var sc = Engine.get_main_loop().root.get_node_or_null("ScreenCapture")
if sc == null:
    return "NO_AUTOLOAD"
var p = await sc.capture("after_blur")
return p
```

Naming rules:

| Call | Writes | Use for |
|---|---|---|
| `capture()` | `frame_0001.png`, `frame_0002.png`, … | never overwrites; exploratory shots |
| `capture("name")` | `name.png` | **stable filename — use for before/after** |

Humans can also press **F12** in the running game.

If `ScreenCapture` is missing, the project's `project.godot` needs:

```ini
[autoload]
ScreenCapture="*res://autoload/screen_capture.gd"
```

## 2. Look at it

```powershell
cd <project>
node tools/look_at_frame.cjs screenshots/after_blur.png
node tools/look_at_frame.cjs screenshots/before.png screenshots/after.png --ask "what changed?"
```

Backends are tried in order:

1. **The user's own vision models** (`VISION_API_KEY`) — fast, no rate limit
   - `kimi-k3` — most detailed (notices gradient seams, anti-aliasing, fog)
   - `minimax-m3` — fastest (~2 s), concise and accurate
   - `doubao-seed-2.1-turbo` — detailed but slow (~20 s)
2. **OVH anonymous free tier** — no key, but **IP-throttled to ~1 req/min**

## 3. Measure it — do this before trusting prose

A vision model describes; `pixel_diff.cjs` measures. Prefer the number.

```powershell
node tools/pixel_diff.cjs screenshots/before.png screenshots/after.png
```

Output: `DIFF RATIO`, `mean delta`, and the worst 8×8-grid cells with pixel
coordinates — so you can locate the region that actually changed.

## Verifying vision backends

If a model's behaviour is unknown, probe it with a known-content image:

```powershell
node tools/check_vision_models.cjs                    # default model set
node tools/check_vision_models.cjs minimax-m3         # one model
node tools/check_vision_models.cjs --image screenshots/before.png
```

## Rules

- **Measure before/after with `pixel_diff.cjs`** on every visual change. A
  description alone cannot tell you whether the change converged.
- Treat vision output as **evidence, not ground truth** — cross-check against
  `pixel_diff.cjs` numbers and pixel sampling.
- If a model answers *"the image is truncated / I can't see it"*, that model uses
  the `openai-responses` protocol and does **not** accept base64 data URLs
  (e.g. `deepseek-v4-flash-vision-exp`). Switch to an `openai-completions` model
  instead of retrying.
- Keep `screenshots/` out of Godot's import scan — it contains a `.gdignore`.
  Do not delete that file; without it Godot generates `.import` churn.
- Do not paste images into chat to "show" the agent — that path needs the user
  and a vision wrapper. Use the capture → look → measure loop instead.

Full reference: `docs/VISION_LOOP.md`.
