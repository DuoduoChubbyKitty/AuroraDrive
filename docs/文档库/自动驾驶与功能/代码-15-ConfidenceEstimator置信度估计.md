# 代码-15 ConfidenceEstimator 置信度估计

> 覆盖源文件：`Sources/AuroraDrive/Inference/ConfidenceEstimator.swift`（248 行）。基于当前仓库逐单元编写。

## 一、门控与三信号融合架构（第 1–100 行）

**定位（4–25 行头注释）**：置信度估计器——**E2E 模型不输出置信度，用启发式从"模型输出历史 + 当前画面"估算**。输出 [0,1] 置信度分，**供降级状态机决策**。

**门控 + 三个信号融合（源注释原文）：**

| # | 信号 | 说明 |
|---|---|---|
| 0 | **链路存活门控** | 模型未加载 / 无推理结果 / 结果过期 → 置信度直接 0（**修复退化平衡点**：E2E 恒输出 idle/恒定值时旧公式会算出 0.70，高于降级阈值 0.65，**导致死模型永远卡在端到端档不降级**） |
| 1 | 输出一致性 | 最近 N 帧 steer 抖动越小越可信（模型稳定） |
| 2 | 转向极端度 | steer 长时间打满（\|steer\|>0.95）视为退化——（**油门/刹车贴边属正常驾驶行为，不再扣分**——修复"健康巡航恒 0.70、导致永远够不到 0.75 恢复阈值、卡死在规则档"的缺陷；**输出稳定不判冻结**——直道上模型本来就该稳定输出） |
| 3 | 画面有效性 | 亮度异常（全黑/全白）直接判低置信 |

**设计（21–25 行）**：滑动窗口存最近 N 帧输出，O(1) 更新；三个信号加权融合，权重可调；**线程安全：仅主线程调用（与 tick 同步）**——注意单元三会看到例外（亮度计算移到后台队列）。

**类声明（第 31–32 行）**：`@Observable final class ConfidenceEstimator: @unchecked Sendable`。

**可调参数（第 34–54 行）：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `consistencyWeight` | 0.5 | 输出一致性权重（抖动越小分越高） |
| `extremityWeight` | 0.3 | 输出极端度权重（贴边越久分越低） |
| `imageWeight` | 0.2 | 画面有效性权重（亮度异常分越低） |
| `windowSize` | 20 | 滑动窗口大小（最近 N 帧用于算一致性） |
| `extremeThreshold` | 0.95 | 极端值阈值：\|steer\|>0.95 视为转向打满（退化） |
| `extremeRatioThreshold` | 0.7 | 极端持续帧数超过此**比例** → 判退化 |
| `brightnessMin / brightnessMax` | 0.08 / 0.95 | 画面亮度正常范围（归一化 0~1），超出视为异常 |

**状态输出（第 56–64 行）**：`confidence`（当前置信度估计值 [0,1]，UI 观察，默认 1.0）+ 三路子分 `consistencyScore / extremityScore / imageScore`（调试/UI 展示用，各默认 1.0）。

**内部状态（第 66–78 行）**：`steerHistory: [Double]`（最近 N 帧 steer，算抖动）、`extremeHistory: [Bool]`（最近 N 帧是否极端）、`longExtremeHistory: [Bool]`（**长窗口极端标记，3 秒，判"持续打满=贴墙/打转退化"**）、`longExtremeWindow = 90`（长窗口帧数，3 秒 @30Hz：**持续打满这么久还没松 → 不是过弯，是退化**）、`longExtremeRatioThreshold = 0.7`（长窗口打满占比阈值：超过 → 判持续退化）。

**`update(command: ControlCommand, image: CGImage?, isLive: Bool)`（第 89–140 行）——主入口，四步：**

1. **链路健康门控（90–100 行）**：`guard isLive else { confidence = 0; 三个子分全 0; return }`——isLive 参数含义（86–88 行注释）：**推理链路是否真的活着（模型已加载 && 最近有新鲜结果）**；链路死 → 置信度直接置 0，**强制降级到 YOLO 接管，避免 E2E 空转却卡在 .e2e 档**
2. **更新历史窗口（102–114 行）**：steerHistory append + 超窗 removeFirst；`isExtreme = abs(command.steer) > extremeThreshold`——**只判转向打满**（106–109 行注释：油门/刹车贴边（0 或 1）是正常驾驶行为，不判极端——旧定义把"巡航全油门"误判为退化，导致置信度恒 0.70、永远够不到 .rule→.e2e 的 0.75 恢复阈值，卡死在规则档）；extremeHistory + longExtremeHistory 双窗口都追加
3. **三路子分 + 加权融合（116–125 行）**：`confidence = (一致性×0.5 + 极端度×0.3 + 画面×0.2) / max(total, 1e-6)`
4. **持续转向打满 → 压置信（127–138 行）**：长窗口（3s）内 \|steer\|>0.95 占比 >70% → `confidence = min(confidence, 0.30)` **强制降级**——源注释（128–131 行）：一致性满分会把"打满恒定输出"洗成 0.70（高于降级阈值 0.65），导致模型打满 16 秒还卡在端到端档**继续注入错误按键**；只判"转向打满"，不是判"输出恒定"
5. `confidence = max(0, min(1, confidence))`——夹到 [0,1]

## 二、reset 与三路子分计算（第 142–248 行）

**`reset()`（第 143–151 行）**——重置（停止驾驶时调用）：三个历史窗口全清（steerHistory/extremeHistory/longExtremeHistory）、confidence 与三路子分全部回 1.0——**注意重置后 confidence 是 1.0 不是 0**（新会话从"默认可信"开始，首次 update 会立刻用真实信号覆盖）。

**`computeConsistency() -> Double`（private，第 157–164 行）**——输出一致性：steer 历史的标准差越小，分越高：

- `guard steerHistory.count >= 3 else { return 0.8 }`——**帧数不足给中等分**
- 均值 → 方差 → 标准差；**线性映射：`max(0, min(1, 1.0 - std * 2.0))`**——std 0→1.0，std 0.5→0.0

**`computeExtremity() -> Double`（private，第 167–179 行）**——输出极端度：极端帧占比越低，分越高：

- `guard !extremeHistory.isEmpty else { return 1.0 }`
- `extremeRatio = 极端帧数 / 总帧数`；`extremeRatio <= extremeRatioThreshold`（0.7）→ **1.0**；高于 → 线性下降到 0
- **P2 修复（174–178 行）**：极端占比阈值滑到 1.0（或异常值/NaN）时分母 `(1.0 - threshold)` 为 0——**除零会产出 inf/NaN 污染置信度。`guard denom > 0 else { return 0 }`**——异常时极端度直接判 0（保守降级）

**`computeImageScore(_ image: CGImage?) -> Double`（private，第 184–209 行）**——画面有效性：亮度在正常范围 → 1.0，异常 → 0.0：

- **亮度计算已移到后台队列（CIAreaAverage 全图平均，主线程零绘制）**，结果**异步回写 imageScore**；**本帧融合沿用上一帧已算好的缓存分**（182–183 行注释）
- `image == nil` → `imageScore = 0.5`（无图像给中等分）
- **只保留最新帧（192–195 行）**：`guard !brightnessInFlight else { return imageScore }`——上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，沿用缓存分即可），**避免每 tick 无脑入队、后台亮度任务堆积**
- `brightnessInFlight = true` → `Self.brightnessQueue.async { ... }`：后台算亮度 → `score = (brightness < minB || brightness > maxB) ? 0.1 : 1.0`（异常给 **0.1** 不是 0）→ 回主线程清 inFlight + 写 imageScore
- **Swift 6 跨域注意（199–201 行注释）**：**在后台队列提前解包 weak self，避免将非 Sendable 的 self 引用传入 @MainActor Task（Swift 6 会检查跨域发送）**——`let target: ConfidenceEstimator? = self` 先解包，再 `Task { @MainActor [target] in ... }`

**`brightnessInFlight`（@ObservationIgnored，第 213–214 行）**：亮度后台任务 in-flight 标志——**主线程置位 / 后台回主线程清除，全程主线程访问无锁**。

**`brightnessQueue`（static，第 217–218 行）**：后台亮度计算队列（**独立于推理队列的 serial queue**；`com.aurora.confidence.brightness`, .userInitiated）。

**`brightnessContext`（static，第 221 行）**：复用的 CoreImage 渲染上下文（线程安全，跨线程共享，**避免每帧新建**；`[.cacheIntermediates: false]`）。

**`averageBrightness(cgImage: CGImage) -> Double`（private static，第 225–247 行）**——计算图像平均亮度 [0,1]（后台执行）：

- **用 CIAreaAverage 全图均值代替旧 32×32 降采样 draw，主线程零绘制开销**（224 行注释）
- `CIFilter(name: "CIAreaAverage")` + inputImage/extent → 渲染到 **1×1 RGBA8 缓冲**（`brightnessContext.render(toBitmap:rowBytes:4:bounds:1×1:format:.RGBA8:)`）
- 读平均 RGB → **Rec.601 亮度近似**：`0.299 × r + 0.587 × g + 0.114 × b`——与旧 DeviceGray 转灰的视觉亮度一致；阈值 0.08/0.95 粗糙，语义等价
- filter 构造失败/输出缺失返回 0.5（中等分，不误判）

**ConfidenceEstimator 文档至此完整**（248 行全覆盖：门控与融合 → reset 与子分计算）。给别的 AI 的最关键提示：**isLive 门控是降级链条的发令枪**——链路死必须归零，否则退化平衡点公式会让死模型永远卡在 .e2e 档；**只判转向打满、不判油门贴边**（否则健康巡航被误判退化，永远回不到端到端档）。