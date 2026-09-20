# Level 10 — Project Shadow Glass 风格 3D 像素化

对应视频：`reference/reference.md`
- 第 1 章：用 **六个 SubViewport + 六台相机** 把场景渲染成 cubemap，再在相机前的 quad 上采样，得到旋转时完全不闪的像素画。
- 第 2 章：在第 1 章基础上加入 **深度 + 锚点/实时双 cubemap 重投影**，解决移动时的闪烁（disocclusion）。

本 level 实现的是**第 2 章**的完整技术，并保留了第 1 章的 cubemap 采样内核。

---

## 1. 为什么"把场景降采样"不行

最直觉的做法是把屏幕分辨率降低（或按格子取色，见 Level 5）。这在 2D 下没问题，在 3D 下必然闪：

相机稍微一动，几何体边缘就会跨过像素格边界，格子中心的颜色在"命中物体"和"命中背景"之间跳变。
**像素格是屏幕空间的，几何体是世界空间的，两者没有稳定对应关系。**

视频里的关键观察：

> 旋转相机时画面完全不变 —— 因为周围是六张场景渲染图。

也就是说，真正稳定的东西不是"屏幕上的像素格"，而是**cubemap**：

- cubemap 的纹素在**世界空间**是固定的；
- 相机旋转 = 换一个采样方向，纹素位置不变 → **零闪烁**；
- 相机平移 = 采样方向改变，纹素会爬行 → **会闪**。

所以：

| 操作 | 直接降采样 | cubemap 重投影 |
|---|---|---|
| 旋转 | 闪 | **不闪** |
| 平移 | 闪 | 闪（需要用下面的技术压制）|

---

## 2. 核心思路：不移动相机，而是让 cubemap 变形

> The only way to stabilize translation is to stop translating altogether.
> Instead, we warp the cube map as we move so it stays correctly projected onto the geometry.

既然平移会闪，那就**不让 cubemap 跟着相机走**：

1. 在某个固定位置拍一张 cubemap（**anchor / 静态 cubemap**），它**不动**；
2. 相机移动时，对每个像素：
   - 用深度缓冲反推该像素的**世界坐标** `p`；
   - 采样方向 = `normalize(p - anchor_center)`；
   - 用这个方向去查 anchor cubemap。

因为 anchor 中心和纹素都是固定的，**同一个世界表面点永远查到同一个纹素** → 平移时也不闪。
相机移动的效果，是通过"改变采样方向"来实现的，而不是移动 cubemap。

```
        静态 cubemap（固定中心 C）
        ┌─────────────────────────┐
        │  ● 纹素 (世界空间固定)   │
        └─────────────────────────┘
                    ▲
                    │  dir = normalize(p - C)
                    │
   相机 ────────►  p (由深度反推的世界坐标)
   (可以自由移动)
```

### 2.1 单张 anchor 不够：disocclusion

相机离 anchor 越远，`p` 的方向和当初拍摄时的方向偏得越多，就会露出**当初被挡住、cubemap 里没有记录**的表面 —— 这就是 disocclusion（遮挡解除）。

解决办法（视频里用品红高亮的部分）：

1. anchor 离相机太远时，**重新拍一张**（snap）；
2. 重拍前先把旧的那张存一份，新旧的**平滑插值**过渡；
3. 用**深度**判断每个像素到底能不能信任 cubemap，不能信任的部分回退到"跟随相机的 cubemap"或"原始画面"。

这就是需要**两张 cubemap** 的原因：

| cubemap | 中心 | 用途 |
|---|---|---|
| **Live** | 每帧跟随相机 | 永远正确（不会 disocclusion），但会爬行。作为兜底 |
| **Anchor A / B** | 固定，超距才重拍 | 稳定不闪。两张交替，用来做重拍时的交叉淡入 |

---

## 3. 实现结构

```
addons/shadowglass/
├── core/
│   ├── capture_bank.gd          # 一个 bank = 6 个 SubViewport + 6 台相机 → 1 张 3x2 图集
│   ├── shadowglass_system.gd    # 状态机：锚点重拍 / 交叉淡入；往 effect 推参数
│   └── shadow_glass_utils.gd    # mat4 打包、运行时编译 GLSL、安全释放 RID
├── effects/
│   ├── capture_pack_effect.gd   # 每个 capture 相机一个：颜色 + 径向深度 → 图集
│   └── reprojection_effect.gd   # 主相机的合成器效果：重投影 + 校验 + 回退 + 像素化
├── shaders/
│   ├── cube_atlas.glslinc       # 面/方向约定的**唯一真相来源**
│   ├── capture_pack.glsl
│   └── reprojection.glsl        # 内含 sample_cube_atlas() 的副本（与 glslinc 同步）
└── resources/
    └── shadowglass_config.gd    # 所有可调参数
```

`level_10_/` 里是演示场景：

- `level_10.tscn` — 场景 + HUD
- `level_10.gd` — HUD 与键盘控制
- `shadowglass_config.tres` — 调好的参数

### 3.1 为什么用 3×2 图集而不是 6 张独立纹理

6 个 SubViewport 各自渲染，但都写进**同一张 GPU 图集**（`3*res × 2*res`）：

- 只需在 shader 里绑定 1 张纹理，而不是 6 张；
- 采样时按面号算图集 UV 即可；
- 一张纹理可以直接 `texture_get_data()` 读回做验证。

每个面的 tile 原点：`col = face % 3`，`row = face / 3`。

### 3.2 面方向约定（重要）

`cube_atlas.glslinc` 是唯一真相来源，`capture_bank.gd` 的 `FACE_VIEW` / `FACE_UP` 和
`reprojection.glsl` 里 `sample_cube_atlas()` 的副本都必须与它一致。

```
face 0 = +X   face 1 = -X   face 2 = +Y
face 3 = -Y   face 4 = +Z   face 5 = -Z

u = 0.5 * (1 + dot(dir, right) / dot(dir, view))
v = 0.5 * (1 - dot(dir, up)    / dot(dir, view))
```

相机 `fov = 90`、`keep_aspect = KEEP_WIDTH`、视口为正方形，正好得到 aspect = 1 的立方体面投影。

---

## 4. 深度：cubemap 本身不带深度，所以塞进 alpha

cubemap（这里是 2D 图集）只有颜色。要判断"这个像素能不能信任 cubemap"，需要知道
**cubemap 在那个方向上看到的表面离中心有多远**。

做法（视频 02:54–03:18）：每个 capture 相机挂一个 `CapturePackEffect` 合成器效果，
用 compute shader 把深度写进 alpha 通道：

```glsl
// capture_pack.glsl
vec4 color = imageLoad(src_color, pix);
float d = texelFetch(src_depth, pix, 0).r;

// Godot 4 是 reverse-Z：近平面 = 1.0，远平面 = 0.0
bool sky = d <= 1e-6;

float radial_depth;
if (sky) {
    radial_depth = -1.0;          // 天空哨兵值
} else {
    vec2 uv = (vec2(pix) + 0.5) / vec2(float(res));
    vec3 ndc = vec3(uv * 2.0 - 1.0, d);
    vec4 clip = pack_params.inv_proj * vec4(ndc, 1.0);
    radial_depth = length(clip.xyz / clip.w);   // 沿射线的距离
}
imageStore(dst_atlas, tile + pix, vec4(color.rgb, radial_depth));
```

存的是 **radial depth（沿射线的距离）**，不是 view-space 的 z。这样校验时只要比较两个长度：

```
error = abs(cubemap_radial_depth - length(p - center))
valid = 1 - smoothstep(tol, tol * softness, error)
```

`tol = max(绝对阈值, 距离 * 相对阈值)` —— 相对阈值让容差随距离放大，远处的精度要求自然更低
（视频里说的"preserves precision in the near field"）。

**天空用 alpha < 0 作为哨兵值**：`0` 是合法的"紧贴中心"，所以必须用负数区分"cubemap 在这里什么都没看到"。

---

## 5. 重投影主循环

`reprojection.glsl` 的 `main()`：

```
1. 读原色 original、深度 d
2. 若 d ≈ 0 → 天空，单独处理
3. 否则反推世界坐标：
      clip = inv_proj * vec4(ndc, d, 1)
      view = clip.xyz / clip.w
      world_pos = view_to_world * vec4(view, 1)
4. 对 Anchor A / B 各做一次 reproject_face()，得到颜色 + valid
5. 按 valid 加权混合两个 anchor：
      wA = validA * (1 - blend)
      wB = validB * blend
      anchor_color = (colorA*wA + colorB*wB) / (wA + wB)
6. 同样对 Live 做一次
7. 按 fallback_mode 选最终颜色
8. 近处像素混回原始画面（保护武器/近墙）
9. 像素化：抖动 + 量化
```

第 5 步的加权混合是关键：**在交叉淡入期间，每个像素按自己的有效程度参与混合**，
而不是整屏一起淡。这样 disocclusion 区域不会把错误的颜色混进来。

---

## 6. 三种回退模式

`FallbackMode`（HUD 按 `F` 切换）：

| 模式 | 行为 | 特点 |
|---|---|---|
| `ORIGINAL_SCENE` | 无效处直接用原始画面 | **完全不闪**，代价是 disocclusion 区域不是像素画 |
| `LIVE_CAPTURE` | 无效处用 Live cubemap | **全屏都是像素画**，边缘爬行更明显 |
| `LIVE_THEN_ORIGINAL` | 先试 Live，再退回原始 | 折中（默认）|

这正对应视频 02:14–02:28 的取舍。

---

## 7. 像素观感：抖动 + 量化

采样用 **nearest**（`nearest_sampling`），这就是硬边像素块的来源。

`QuantizeMode`（HUD 按 `M`）在 **YCoCg** 空间量化：

| 模式 | 说明 |
|---|---|
| `NAIVE` | RGB 逐通道取整。颜色数最多，但饱和色会偏色 |
| `LUMA` | 只量化亮度，色度连续。保留色彩层次 |
| `LUMA_CHROMA` | 亮度 + 色度分别量化。最像限定调色板 |

量化在 **sRGB（gamma）空间**做，步长在视觉上才均匀 —— 直接在线性空间量化会把暗部细节全压掉。

抖动用 4×4 Bayer，并且**在量化所在的同一空间里加噪声**，这样一个噪声单位正好等于一个调色板步长：

```glsl
vec3 space = quantize_in_srgb ? linear_to_srgb(out_color) : out_color;
space += vec3((bayer4(pix) - 0.5) * dither_strength / levels);
out_color = quantize_in_srgb ? srgb_to_linear(space) : space;
```

视频 07:04 提醒的 HDR 问题：本场景用了 ACES tonemap，所以调试色（纯红/纯绿）会被
tonemapper 加进一些蓝色分量 —— 验证脚本里因此不能断言"蓝通道接近 0"。

---

## 8. 调试视图

HUD 按 `0`–`8`（或 `F2` / `F3`）：

| 值 | 视图 | 用途 |
|---|---|---|
| 0 | FINAL | 最终效果 |
| 1 | ORIGINAL | 旁路整个效果 |
| 2 | LIVE_ONLY | 只看 Live cubemap |
| 3 / 4 | ANCHOR_A / B | 只看某一张 anchor |
| 5 | DEPTH_ERROR | 径向深度误差大小 |
| 6 | VALIDITY | 红=无效(disocclusion)，绿=有效 |
| 7 | FACE_INDEX | 面号着色，验证面朝向约定 |
| 8 | FALLBACK_SOURCE | 绿=anchor，青=live，黄=原始，蓝=天空 |
| 9 | FACE_BLEND | 三个轴向混合权重（验证无缝混合是否生效）|

`FACE_INDEX` 和 `FALLBACK_SOURCE` 是排查"画面错位"最有效的两个视图。
`FACE_BLEND` 在立方体面边界附近应该看到柔和渐变，而不是硬台阶。

---

## 9. 操作说明

| 按键 | 功能 |
|---|---|
| 右键 | 捕获/释放鼠标 |
| WASD / QE / Shift | 自由飞行 |
| **R** | 原地旋转 —— 验证旋转零闪烁 |
| **T** | 前后推拉 —— 验证平移稳定性与交叉淡入 |
| **A** | 自动环绕 |
| Q / D | 量化 / 抖动 开关 |
| M | 量化模式 |
| F | 回退模式 |
| `,` / `.` | 深度容差 |
| `-` / `=` | 锚点重拍距离 |
| N | 交叉淡入时间（0 = 直接切换）|
| K | 天空是否像素化 |
| J | cubemap 是否渲染天空 |
| H / G | 冻结锚点 / 冻结 Live |
| F1 / F2 / F3 / F5 / F6 | 开关效果 / 有效性 / 原始 / 强制重拍 / 切分辨率 |
| ESC | 退出 |

---

## 10. 参数怎么调

视频 01:19 的建议 —— **减少闪烁的手段**：

1. **避免细几何体**（栏杆、细杆、薄片）。细结构最容易在纹素边界跳变。
2. **降低分辨率**（`capture_resolution`）。64–128 是效果和稳定性的平衡点。
   太低（32）会明显糊，太高（512）会开始闪。
3. **用雾或景深**藏掉高频细节。
4. **放宽深度容差**（`occlusion_relative_threshold`）。容差越大，越多像素用稳定的
   anchor，闪得越少，但 disocclusion 的错色会更明显。
5. **回退到原始画面**（`fallback_mode = ORIGINAL_SCENE`）—— 完全不闪，代价是
   遮挡解除区域不是像素画。
6. **天空**：`pixelate_sky = false` 让天空保持原始渲染，可以避免几何体与天空交界处的爬行。

反过来，想要**更像像素画**：`LIVE_CAPTURE` 回退 + `pixelate_sky = true` + 低分辨率 +
`LUMA_CHROMA` 量化，代价是闪烁更明显。

---

## 11. 踩过的坑（实现要点）

这些是实现过程中真实遇到并修掉的问题，复现时容易再踩：

### 11.1 `Compositor.compositor_effects` 返回的是**副本**

```gdscript
# ❌ 静默失效，effects 永远是空的
compositor.compositor_effects.append(effect)

# ✅ 整体赋值
var effects: Array[CompositorEffect] = [effect]
compositor.compositor_effects = effects
```

这个坑非常隐蔽：赋值给 `camera.compositor` 成功，`enabled = true`，`pipeline` 有效，
但合成器效果**永远不执行**。是本项目花时间最多的一个 bug。

### 11.2 `SubViewport` 没有 `environment` 属性

环境要设在 `Camera3D.environment` 上（它只覆盖自己所在视口的 world environment）。
设成 `SubViewport.environment` 会直接运行时报错。

### 11.3 capture 的 Environment 必须复制世界环境

如果给 capture 相机 new 一个全新的 `Environment`，会**丢掉环境光、雾、tonemap**，
cubemap 拍出来比真实场景暗一截（实测平均亮度 0.37 vs 0.46）。
正确做法是 `world.environment.duplicate()`，只覆盖背景模式。

### 11.4 `world_3d` 必须在入树之后设置

`SubViewport.world_3d` 在节点入树时会被 Godot 的 World3D 生命周期逻辑重置回自己的私有 world。
所以 `set_world()` 要在 `add_child()` 之后调用，否则 cubemap 拍到的是一个**空场景**
（所有纹素都是天空哨兵值，重投影全部失效）。

### 11.5 `free_rid()` 只能在渲染线程调用

从 `_notification(PREDELETE)` 直接调会报
`This function (free_rid) can only be called from the render thread.` 并静默泄漏。
要走 `RenderingServer.call_on_render_thread()`。

### 11.6 `effect_callback_type` 必须是 `POST_TRANSPARENT`

只有这个阶段才能同时拿到已解析的颜色和深度。

### 11.7 天空不能用 `d >= 1.0 - 1e-5` 判断

Godot 4 用 reverse-Z，**远平面是 0.0**，所以天空是 `d <= 1e-6`，不是 `d >= 1.0`。

---

## 12. 性能

每次 anchor 重拍要渲染 6 个面；Live 每帧渲染 6 个面。128×128 下开销很小。

想省性能：把 `capture_resolution` 降到 64，或调大 `capture_distance` 减少重拍频率。
Live 只在 disocclusion 回退时才真正被采样，但仍需每帧更新。

---

## 13. 已知限制

- 需要 **Forward+**（依赖 compute shader 和 `RenderSceneBuffersRD`）。
- 反射/折射类材质、billboard 粒子在 cubemap 里表现不理想：billboard 永远朝向
  cubemap 中心，而不是对齐相机平面（视频 09:39 提到这点，插件里用自定义粒子解决）。
  本 demo 没有包含粒子。
- 全屏后处理（glow、DOF）在 cubemap 里是缺失的，因此 cubemap 的颜色和主画面
  在强后处理下会有差异。
- 阴影贴图是按相机渲染的，anchor 离得远时 cubemap 里的阴影会和主画面对不上。

---

## 14. 验证结果

在 Godot 4.7.1 / Forward+ / 1920×1080 下实测：

| 检查项 | 结果 |
|---|---|
| cubemap 图集尺寸 | 384×256 = (3×128)×(2×128) ✅ |
| 各面几何纹素数 | `[8568, 8568, 14, 16384, 7552, 9714]` ✅ |
| 面朝向 | 6 个方向与约定完全一致 ✅ |
| 重投影正确性 | 与原始画面 box-average 亮度相关性 **0.914** ✅ |
| 亮度一致性 | 0.460 vs 0.457（环境修复后）✅ |
| 像素化 | 8px 平坦邻域比 78.7% → **88.6%** ✅ |
| 分辨率生效 | res 16 → 94.2%，res 256 → 86.3% ✅ |
| **旋转稳定性** | 像素化画面波动 **0.03** vs 原始画面 **0.09** ✅ |
| disocclusion 检出 | 遮挡物移开后 **24.6%** 像素被正确判为无效 ✅ |
| 量化模式 | 三种模式颜色数 139 / 116 / 97，依次递减 ✅ |
| 锚点状态机 | 超距 → CAPTURE_READY → BLENDING → IDLE，active 翻转 ✅ |

第 3 行的 `[..., 14, 16384, ...]` 特别能说明问题：`+Y` 面朝上只看到 14 个几何纹素
（其余全是天空），`-Y` 面朝下是 16384 = 128² 全部是地面 —— 完全符合预期。

**旋转稳定性**（第 9 行）是这项技术的核心主张：像素化后的画面在旋转时比原始画面
**稳定 3 倍**（波动 0.03 vs 0.09）。

### 参考截图

| 文件 | 内容 |
|---|---|
| `image/level_10_original.png` | 原始画面（旁路效果）|
| `image/level_10_pixelated.png` | 最终像素化效果 |
| `image/level_10_validity.png` | 有效性调试视图 |
| `image/level_10_fallback_source.png` | 回退来源调试视图 |

原始 866 KB vs 像素化 292 KB —— 平坦色块更容易压缩，这也侧面印证了像素化确实生效。

---

## 15. 和视频插件的差异

视频第 2 章后半段介绍的是作者的付费插件 **CUBY**。本实现只做了视频**公开讲解的核心技术**：

**已实现**
- 六视口 cubemap + 3×2 图集
- 深度压缩进 alpha（径向深度 + 天空哨兵）
- 双 anchor 交叉淡入 + 逐像素有效性加权
- 三种回退模式
- 像素化：nearest + 抖动 + 三种量化模式
- 像素化天空
- 调试视图（有效性 / 面号 / 回退来源 / 深度误差）
- 武器层排除（`capture_cull_mask`）

**未实现**（视频提到但属于插件功能，或明确说不讲）
- LUT 3D 纹理调色板（视频 05:55 起）—— 本实现用量化代替
- 调色板 → LUT 烘焙脚本（视频 10:07）
- 自定义 billboard 粒子（视频 09:39）
- 昼夜循环脚本（视频 05:47）
- 累积式运动模糊（视频 04:02 明确说"不教"）
- HDR 对数压缩（本 demo 用 ACES tonemap 代替）

---

## 16. 视频源码对照（`reference/image/` 截图）

`reference/image/` 里有 17 张视频代码截图，按时间顺序。转录在
`reference/transcripts/`。对照本实现，值得记录的差异：

### 16.1 视频第 1 章的控制器

```gdscript
@export var step = 0.001
@onready var viewports_256 = $"Cubemap-256"
@onready var viewports_128 = $"Cubemap-128"

func _process(_delta):
    var p_pos = player.get_child(0).global_position
    for vp in subviewports_256:
        vp.get_child(0).global_position = p_pos        # 跟随玩家
    for vp in subviewports_128:
        vp.get_child(0).global_position = p_pos.snapped(Vector3(step, step, step))  # 网格吸附
```

即第 1 章用**两张不同分辨率的 cubemap**（256 跟随 / 128 吸附到 0.001 网格），
而第 2 章演进为 **anchor + previous 的时间混合** —— 本实现做的是第 2 章。

### 16.2 视频第 1 章的 shader 关键片段

```glsl
// 逐面 UV
vec2 cube_uv(vec3 dir, int face) { ... }

// 六面加权混合（blend_sharpness 控制混合宽度）
vec3 weights = pow(abs_dir / max_axis, vec3(blend_sharpness));
weights /= (weights.x + weights.y + weights.z);

// 量化后再混合 —— 为了得到中间色
color  = floor(color  * 6.0) / 6.0;
color2 = floor(color2 * 6.0) / 6.0;
ALBEDO = mix(color, color2, 0.5);
```

**"quantize before mixing, so we have intermediate colors for blending"** ——
这是本实现采纳的关键点之一（见 16.4）。

### 16.3 视频第 2 章的深度与重投影

```glsl
// 深度压缩（保留近处精度）
float log_depth = pow(depth / z_range, 0.2);   // 解压用 pow(x, 5.0)

// 重投影误差与拒绝阈值
float diff1 = length(reproj1 - world_pos);
float reject = 0.01 + cam_dist * 0.05;
float valid1 = 1.0 - smoothstep(reject, reject * 2.0, diff1);

// 时间混合（sqrt 缓动）
float t = sqrt(smoothstep(0.0, 1.0, temporal_blend));
float w_curr = t * valid1;
float w_prev = (1.0 - t) * valid2;

// 回退：把 alpha 置 0，让原始画面透出来
if (!fallback_to_cubemap) ALPHA = 0.0;
```

本实现采纳了 `reject = abs + cam_dist * rel` 与 `sqrt(smoothstep(...))` 缓动，
但**额外增加了一项按像素距离缩放的容差**（见 16.5）—— 只有 `cam_dist` 项时，
浅角度地面会被整体拒绝。

### 16.4 采纳的改进（本轮通过视觉闭环发现并修复）

| 改进 | 问题 | 修复 |
|---|---|---|
| **面间无缝混合** | 立方体面边界有硬直角色阶 | 按轴向对齐度加权混合三个轴对，`face_blend_sharpness` 控制宽度 |
| **容差按像素距离缩放** | 只按 `cam_dist` 缩放时，浅角度地面被整体拒绝 —— 实测地面 **55–60%** 退回原始画面（`FALLBACK_SOURCE` 视图显示大片黄色），地面因此完全不像素化 | `tol = abs + expected * rel + cam_dist * probe_rel`，三项覆盖三种独立误差源 |
| **面间混合必须按深度门控** | 深度只校验主面，颜色却混合三个面 → 邻面的纹素看到了**别的物体**（遮挡物），把它的颜色混了进来 | 每个轴对只有在**自己的深度与待绘表面一致**时才参与混合 |
| **亚纹素深度引导取样** | 最近的纹素中心不一定看到了这个表面 | 取 5 个亚纹素采样，选深度最吻合的那个 |
| **抖动默认关闭** | 全局 Bayer 抖动会在**每个**平面上加规则图案，128px 下读起来是噪点而非质感 | 默认关闭；A/B 对比确认关闭后甲板/天空/地面才读作"刻意的平色块" |
| **抖动强度 1.0 → 0.35** | 1.0 等于一整个调色板步长的噪声，把接触阴影撕成麻点 | 降到 0.35，并说明何时才值得开 |

`face_blend_sharpness` 的取值是实测出来的，两个极端都明显不对：

| 值 | 现象 |
|---|---|
| 8（软混合） | 两个不同纹素网格被平均在一起 → 表面布满**对角斜纹** |
| **77（参考实现的值）** | 斜纹几乎消失，只剩极淡的接缝线 |
| 256（等价硬查找） | 接缝完全变硬 |

### 16.5 一个重要的测量陷阱

本轮迭代中，视觉模型两次报告"橙色色块泄漏到绿色地面上"。
逐像素采样后确认**这是误报**：

```
遮挡物显示时：  原始画面 (239,145,70)  效果 (243,134,77)   ← 都是橙色
遮挡物隐藏时：  原始画面 (84,77,72)    效果 (88,88,88)     ← 都是深色
```

也就是说那个橙色块**本来就是场景里的遮挡物方块**，不是泄漏。

误报的根源是 demo 场景里那个**来回摆动的遮挡物**（振幅 ±5、速度 0.9），
相隔几秒拍的两张图它已经跑到别的位置了，于是"效果图里有、基准图里没有"
就被误判成泄漏。

**教训**：用视觉模型做 A/B 对比时，场景里不能有快速运动的东西，
否则模型看到的是"时间差"而不是"效果差"。已把遮挡物速度从 0.9 降到 0.22。

真正需要警惕的"泄漏"是这样验证的 —— 直接采样同一像素在两种模式下的数值，
而不是靠模型描述：

```gdscript
for mode in [1, 0]:          # 1 = 原始画面, 0 = 最终效果
    cfg.debug_mode = mode
    ...
    var c = img.get_pixel(x, y)   # 逐像素比较
```

### 16.6 已知限制（实测）

- **细几何体会碎**：船的缆绳在 128px cubemap 下大量断裂/消失。
  视频 01:19 明确警告过"必须避免场景中的细几何体"。

  这一条做了**决定性验证** —— 隐藏船模型后，异常暗像素从 **83 个降到 0 个**：

  | 场景 | 效果图中异常暗像素（原始画面是中间调、效果接近纯黑）|
  |---|---|
  | 完整场景 | 83 |
  | 隐藏 Ship | **0** |

  这些像素在 `FALLBACK_SOURCE` 视图里是**绿色**（用了 anchor）、`VALIDITY` 里是
  **绿色**（判定有效），也就是深度校验通过了、但 anchor 那张 cubemap 里那个
  方向**确实渲染成了黑色** —— 细缆绳在低分辨率下覆盖不足，采到了背光/背面。
  已验证**与阴影无关**（开/关阴影分别是 83 / 93）。

- **贴在表面上的物体会在接触线产生 1 纹素宽的伪影**：物体底部与地面深度
  在接触线几乎重合，任何深度测试都无法区分。提高 `capture_resolution`
  可以把这个带宽变窄，但无法消除。
- **运动物体在 anchor 里是冻结的**：这是静态 cubemap 技术的本质限制，
  参考实现的目标场景也是静态环境。
- **cubemap 里没有全屏后处理**（glow / DOF），也没有主相机的阴影贴图细节，
  所以强后处理场景下 cubemap 与主画面会有色差。

> **给场景作者的建议**：把 demo 里的 `Ship` 换成体块化的低模，异常暗像素
> 立刻归零。这项技术对"体块感"的场景效果最好 —— 这也是视频反复强调
> "避免细几何体、用激进的 LOD"的原因。

### 16.7 本轮迭代的量化结果

| 指标 | 迭代前 | 迭代后 |
|---|---|---|
| 地面使用 anchor 重投影的比例 | ~40–45%（大片退回原始画面）| **100%** |
| 像素化（8px 平坦邻域比）| 78.7% | **88.6%** |
| 视觉评分（同一模型、同题）| 6/10 | **8/10** |
| 对角斜纹 | 明显 | 基本消失 |

地面覆盖率是用 `FALLBACK_SOURCE` 调试视图统计的：修复前地面大片是黄色
（退回原始画面），修复后 100% 是绿色（anchor 重投影生效）。

