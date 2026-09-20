# Godot + DSH 视觉闭环

让**纯文本**的 DeepSeek 能自己看到 Godot 的渲染结果，用于 shader 迭代。

## 自动触发（新会话无需提醒）

主模型保持 `deepseek-v4.1-flash`（text-only），视觉交给本工作流。两个机制协同：

| 机制 | 位置 | 作用 |
|---|---|---|
| **`AGENTS.md`** | 项目根目录 | **始终**注入上下文。声明"你看不到图，改视觉必须验证"，agent 不需要"想起来" |
| **`godot-vision` skill** | `.dsh/skills/godot-vision/SKILL.md` | 任务命中时自动加载，给出完整操作步骤 |

两者都是**项目级**：任何 cwd 在本项目的会话都会自动获得。
已实测——创建后**当前会话立即生效**（DSH 有文件监听，无需重启）。

> 想在**其他 Godot 项目**也用：把 `autoload/screen_capture.gd`、`tools/*.cjs`、
> `.dsh/skills/godot-vision/` 一起复制过去，并在 `project.godot` 注册 autoload。

## 组成

| 部件 | 位置 | 作用 |
|---|---|---|
| `ScreenCapture` autoload | `autoload/screen_capture.gd` | 把当前帧写成 PNG 到 `screenshots/` |
| `look_at_frame.cjs` | `tools/look_at_frame.cjs` | 把 PNG 交给视觉模型并打印描述（支持多图对比） |
| `pixel_diff.cjs` | `tools/pixel_diff.cjs` | 逐像素量化对比 + 最差区域坐标 |
| `check_vision_models.cjs` | `tools/check_vision_models.cjs` | 用已知内容的探针图检测哪些模型真能识图 |
| `dsh-vision-router` | DSH web profile 插件 | 在 DSH 会话内提供 `vision_*` 工具 |

## 闭环

```
改 shader → 跑游戏 → ScreenCapture.capture() → PNG
                              ↓
              ┌───────────────┴───────────────┐
        look_at_frame.cjs              pixel_diff.cjs
        （模型看到什么）                （变了多少像素）
              └───────────────┬───────────────┘
                          判断 → 再改
```

## 用法

### 1. 截图（agent 从 MCP 调用）

```gdscript
var sc = Engine.get_main_loop().root.get_node("ScreenCapture")
var p = await sc.capture("after_blur")   # -> <项目>/screenshots/after_blur.png
```

- `capture()` 无参 → `frame_0001.png` 递增，**永不覆盖**
- `capture("名字")` → 固定文件名，**适合前后对比**
- 人工操作：按 **F12**

### 2. 看图

```powershell
cd D:\2zhuomian\Projects\GameDev\Active\pixel_shader_demo
node tools\look_at_frame.cjs screenshots\after_blur.png
```

### 3. 前后对比

```powershell
node tools\pixel_diff.cjs screenshots\before.png screenshots\after.png
node tools\look_at_frame.cjs screenshots\before.png screenshots\after.png --ask "描述变化"
```

`pixel_diff.cjs` 输出示例（实测改 `offest_1/2` 后）：

```
DIFF RATIO   : 16.31%
mean delta   : 21.47 (over all px)
worst 8x8-grid cells (cell = 240x135 px):
  cell(2,3)  px[480,405]  29531 px  (1.42%)
  ...
```

**量化数字比模型描述更可靠**：先看 diff 确认"确实变了"，再让模型描述"变成了什么"。

## 视觉后端

`look_at_frame.cjs` 按顺序尝试：

1. **你自己的视觉模型**（`VISION_API_KEY`）——快、不限流
2. **OVH 匿名免费链**——免 key，但 IP 级限流约 1 req/min

### 已实测可用的自有模型

`settings.yaml` → `llm-pi-ai.providers.vision`（`openai-completions` + ark 端点）：

| 模型 | 探针图 | 真实 Godot 帧 | 速度 | 特点 |
|---|---|---|---|---|
| `kimi-k3` | ✅ | ✅ | ~9–37 s | 最详细，会主动指出渐变接缝、抗锯齿、雾效 |
| `minimax-m3` | ✅ | ✅ | **~2.5–6.6 s** | 最快，简洁准确 |
| `doubao-seed-2.1-turbo` | ✅ | ✅ | ~5–22 s | 细节多但最慢 |

三个都**正常接受 base64 data URL**，所以本地截图可直接用，无需图床。

### 为什么这三个能用、另一个不能

区别在**协议**，不在端点：

| 模型 | 协议 | base64 本地图 |
|---|---|---|
| `kimi-k3` / `minimax-m3` / `doubao-seed-2.1-turbo` | `openai-completions` | ✅ 正常 |
| `deepseek-v4-flash-vision-exp` | `openai-responses` | ❌ 挂起/超时，只吃远程 URL |

`ScreenCapture` 产出本地文件必须转 base64，所以**用上面三个**。
若要用 `deepseek-v4-flash-vision-exp`，得先把图传到可公开访问的 URL。

### 免费链限流比文档说的严重

`dsh-vision-router` README 称 OVH 匿名端点是"每模型独立配额桶 ≈10 RPM"。
**实测不成立**：连打 4 个模型全部 429，是 **IP 级限流，约 1 请求/分钟**。

所以长期使用建议配自有模型（见上），或注册 OVH 账号拿 key（2 → 400 req/min）。

## 排障

| 现象 | 原因 |
|---|---|
| `NO_AUTOLOAD` | `project.godot` 的 `[autoload]` 缺 `ScreenCapture` |
| 截图全黑 | 在 `_ready()` 里就调了 capture；要等 `await RenderingServer.frame_post_draw`（脚本已处理） |
| 工具报 `unknown attachment handle` | 传的是 sha256 句柄而非文件路径；本闭环应传**绝对路径** |
| 429 rate limit | 等 60 秒，或确认 `VISION_API_KEY` 存在（自有模型优先，不会走到免费链） |
| 模型说"图片被截断" | 该模型是 `openai-responses` 协议，不吃 base64；换 `openai-completions` 的模型 |
| `dsh web` 里看不到 `vision_*` 工具 | 插件 bundle 只在启动时发现——装完必须重启 `dsh web` |
