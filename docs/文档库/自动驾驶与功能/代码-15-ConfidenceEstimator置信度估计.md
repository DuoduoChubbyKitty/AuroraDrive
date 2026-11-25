# 代码-15 ConfidenceEstimator 置信度估计
> 覆盖源文件：`Sources/AuroraDrive/Inference/ConfidenceEstimator.swift`。基于当前仓库逐单元编写。
>
> **引用纪律（本篇已重写为名字锚点）**：不再用「文件:行号」定位。本篇所有代码位置一律引用源码里**真实存在的名字**。
>
> **⚠️ 本次重写按当前代码做了实质校正**：旧文描述的是「三信号加权 + 无画面给 0.5 中等分」的旧结构；源码现已改为**硬门控（fail-closed）+ 软信号融合**两层结构，且**无画面改为 fail-closed 而非给 0.5**（源码注释明确记录改「0.5」会造出虚假降级）。详见 §一 与 §二。

## 一、门控与三信号融合架构

**定位（文件头注释）**：置信度估计器——**E2E 模型不输出置信度，用启发式从「模型输出历史 + 当前画面」估算**。输出 [0,1] 健康度分，**供降级状态机决策**。

**分层结构（源注释原文）：硬门控（fail-closed）+ 软信号（可融合）**

| 层 | # | 信号 | 说明 |
|---|---|---|---|
| 硬门控 | 0 | **链路存活** `isLive` | 模型未加载 / 无推理结果 / 结果过期（由调用方算好传入）→ 健康度直接 0（**修复退化平衡点**：E2E 恒输出 idle/恒定值时旧公式会算出 0.70，高于降级阈值 0.65，**导致死模型永远卡在端到端档不降级**） |
| 硬门控 | 0b | **输入新鲜度** `maxImageAge` | 画面本身超龄（默认 1.0s，与 App 既有存活判据同源：`AuroraDriveApp.v3MaxFrameAge`、`isAliveV3`）→ 输入不可用 |
| 硬门控 | 0c | **输入有效性** `isImageInvalid` | 画面亮度异常（全黑/全白）→ 输入不可用。实测依据：黑图/白图喂 V3 模型，confidence 仍 ≈0.9733 / 0.9977，说明模型 confidence **不能**用来判定输入是否有效（评审 P1-1） |
| 软信号 | 1 | 输出一致性 `consistencyScore` | 最近 N 帧 steer 抖动越小越可信（仅连续输出） |
| 软信号 | 2 | 转向极端度 `extremityScore` | steer 长时间打满（\|steer\|>0.95）视为退化（仅连续输出）——（**油门/刹车贴边属正常驾驶行为，不再扣分**——修复「健康巡航恒 0.70、导致永远够不到 0.75 恢复阈值、卡死在规则档」的缺陷；**输出稳定不判冻结**——直道上模型本来就该稳定输出） |
| 软信号 | 3 | 画面有效性 `imageScore` | 亮度在正常范围给满分（硬门控通过后基本恒 1.0） |
| 软信号 | 4 | 模型 confidence `modelConfidenceScore` | **仅 V3 离散输出**：**辅助信号**，权重 0.3（`discreteModelConfidenceWeight`），不能单独决定健康度 |

**为什么模型 confidence 不能当健康度（源注释原文要点）**：训练侧 `_confidence_targets` 的定义是 `conf[t] = exp(-0.15 × 相邻两帧(t-1,t)变化的原子键个数)`（值域 (0,1]）。它来自**控制变化量**，语义是「变化大 → 高动态/转折场景 → 判断更难」，是场景动态度代理，**不是**人工接管标签、不是预测正确率、也不是画面有效性。实测 5 段真实训练标签共 41411 帧：90.9% 的帧 diff=0（conf=1.0），diff=3 仅 19 帧（0.05%，conf≈0.6376 已低于 degradeHealth 0.65）。即：正常驾驶中它几乎恒为 1.0，而「连续变键」这种正常操作反而会击穿降级线——把它直接当健康度既漏判（黑图高 confidence）又会误判（正常变键）。

**设计**：滑动窗口存最近 N 帧输出，O(1) 更新；连续模型保持原三信号加权（0.5/0.3/0.2），行为不变；离散模型改为「模型 confidence 0.3 + 输入结构分 0.7」；**线程安全：仅主线程调用（与 tick 同步）**——注意 §二 的例外（亮度计算移到后台队列）。

**类声明**：`@Observable final class ConfidenceEstimator: @unchecked Sendable`。

**可调权重与阈值：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `consistencyWeight` | 0.5 | 输出一致性权重（抖动越小分越高） |
| `extremityWeight` | 0.3 | 输出极端度权重（贴边越久分越低） |
| `imageWeight` | 0.2 | 画面有效性权重（亮度异常分越低） |
| `windowSize` | 20 | 滑动窗口大小（最近 N 帧用于算一致性） |
| `extremeThreshold` | 0.95 | 极端值阈值：\|steer\|>0.95 视为转向打满（退化） |
| `extremeRatioThreshold` | 0.7 | 极端持续帧数超过此**比例** → 判退化 |
| `brightnessMin` / `brightnessMax` | 0.08 / 0.95 | 画面亮度正常范围（归一化 0~1），超出视为异常 |
| `maxImageAge` | 1.0 | **输入新鲜度硬门控阈值（秒）**。取 1.0s 不是随手拍的数：App 侧 `v3MaxFrameAge = 1.0`（`AuroraDriveApp`）与链路存活判据 `isAliveV3` 都用 1.0s，本估计器与它们保持同一尺度，否则会出现「链路判活、输入已超龄」这类互相矛盾的判定 |
| `discreteModelConfidenceWeight` | 0.3 | 离散模式（V3）下模型 confidence 在健康度里的权重（少数派份额）。**为什么是 0.3 而不是 1.0**：confidence 的训练语义是场景动态度代理，只配当辅助信号。可检验依据：融合式 `health = 结构分×(1−w) + conf×w`，输入通过硬门控后结构分=1.0，于是离散模式的健康度**恒有硬下限 `1−w = 0.70`**，而默认 `DegradeStateMachine.degradeHealth = 0.65` —— 即 confidence 无论多低都**不可能单独把健康度压到降级线以下** |
| `usesDiscreteSteering` | false | 是否按「离散按键式输出」评估极端度。V3 是**三分类**（A/NONE/D），映射后 steer 只取 `{-1, 0, +1}`，**正常转向本身就是 ±1**；沿用连续判据会让合法转向被误判成退化并强制降档（评审 P0-5）。置 true 时 `computeConsistency()` 直接返回 1.0（离散本来就不平滑），`isExtreme` 恒 false |

**状态输出**：`confidence`（当前健康度估计值 [0,1]，UI 观察，默认 1.0）+ 三路子分 `consistencyScore` / `extremityScore` / `imageScore`（调试/UI 展示用，各默认 1.0）+ `modelConfidenceScore`（最近一次**参与融合**的模型 confidence；硬门控拦下时**不更新**，保留最后一次实测值，便于对照「模型说 0.97 但输入被拦」）+ `gateReason`（最近一次被硬门控拦下的原因，空串 = 未拦下）+ `isImageInvalid`（最近一次亮度评估是否判无效画面）。

**内部状态：**

| 成员 | 说明 |
|---|---|
| `steerHistory: [Double]` | 最近 N 帧 steer，算抖动 |
| `extremeHistory: [Bool]` | 最近 N 帧是否极端（短窗口） |
| `longExtremeHistory: [Bool]` | **长窗口极端标记，判「持续打满=贴墙/打转退化」**（长度见 `longExtremeWindow`） |
| `longExtremeWindow: Int = 90` | 长窗口帧数。⚠️ **口径漂移（源码注释）**：按「3 秒 @30Hz」定为 90 帧，但 tick 频率由 `EngineMain.engineTickHz` 决定（历史上 30→20→15）→ 实际时长随之漂移，即「方向持续打满」要更久才判退化。**源注释只标注不改**；要恢复 3 秒语义应按 tickHz 换算。**⚠️ 待确认（产品决策）** |
| `longExtremeRatioThreshold = 0.7` | 长窗口打满占比阈值：超过 → 判持续退化 |

## 二、update 主入口、reset 与三路子分计算

**`update(command: ControlCommand, image: CGImage?, isLive: Bool, modelConfidence: Double? = nil, imageAge: TimeInterval? = nil)`——主入口：**

1. **§0 硬门控（fail-closed）：不满足即健康度归零，不参与加权。**
   - **§0a 链路存活**：`guard isLive else { failClosed(reason: "链路不存活"); return }`——**推理链路是否真的活着（模型已加载 && 最近有新鲜结果）**；链路死 → 健康度直接置 0，**强制降级到 YOLO 接管，避免 E2E 空转却卡在 .e2e 档**
   - **先刷新画面亮度评估**：`imageScore = computeImageScore(image)` 必须在门控**之前**调用——亮度是后台异步算的，若门控提前 return 就不再刷新，一旦判成「画面无效」就会**永远卡在 0**（画面恢复也无从得知）
   - **§0b 输入新鲜度**：`if let age = imageAge, age.isFinite, age > maxImageAge { failClosed(...); return }`。为什么链路存活之外还要单独判：`currentFrameCG` 全文没有置 nil 的地方，抓屏停摆后旧图会被反复推理并刷新 `lastResultTime`——只看链路存活会把「抓屏已死」误判成「模型活得很好」
   - **§0c 输入有效性**：`if image == nil { failClosed(reason: "无画面（输入不可验证）"); return }`；`if isImageInvalid { failClosed(reason: "画面亮度异常（全黑/全白）"); return }`（1 帧滞后：亮度在后台算，本帧沿用上一帧判定）
2. **§1 更新历史窗口（门控通过后才有意义）**：`steerHistory.append(command.steer)` + 超窗 `removeFirst()`；`let isExtreme = usesDiscreteSteering ? false : (abs(command.steer) > extremeThreshold)`——**只判转向打满**（源码注释：油门/刹车贴边（0 或 1）是正常驾驶行为，不判极端——旧定义把「巡航全油门」误判为退化，导致置信度恒 0.70、永远够不到 .rule→.e2e 的 0.75 恢复阈值，卡死在规则档）；`extremeHistory` + `longExtremeHistory` 双窗口都追加
3. **§2 软信号融合**：`consistencyScore = computeConsistency()`（离散模式恒 1.0）+ `extremityScore = computeExtremity()`；`total = consistencyWeight + extremityWeight + imageWeight`，`structuralScore = (一致性×0.5 + 极端度×0.3 + 画面×0.2) / max(total, 1e-6)`
   - **离散模式且给了 modelConfidence**：`confidence = structuralScore * (1 - w) + clampedMC * w`（`w = max(0, min(1, discreteModelConfidenceWeight))`）
   - **否则（连续模型 / 离散但没给 confidence）**：`confidence = structuralScore`——不臆造信号
4. **§3 持续转向打满 → 压置信**：`longRatio = longExtremeHistory 中 true 的占比`；`if longRatio > longExtremeRatioThreshold { confidence = min(confidence, 0.30) }` **强制降级**——源码注释：一致性满分会把「打满恒定输出」洗成 0.70（高于降级阈值 0.65），导致模型打满 16 秒还卡在端到端档**继续注入错误按键**；只判「转向打满」，不是判「输出恒定」。注意源注释写「长窗口（3s）」——**⚠️ 该 3 秒表述已因 tick 降频漂移失效**（见 `longExtremeWindow`）；离散模式下 `isExtreme` 恒 false → longRatio 恒 0 → 本段不生效（预期行为）
5. `gateReason = ""`；`confidence = max(0, min(1, confidence))`——夹到 [0,1]

**`failClosed(reason: String)`（private）**——硬门控失败：`confidence = 0`、`consistencyScore = 0`、`extremityScore = 0`、`gateReason = reason`。

> ⚠️ 源码注释明确：**不**在这里把 `imageScore` 清零（曾踩过，勿改回去）。`imageScore` 由独立的后台亮度任务测量并回写，描述「上一帧实测亮度是否正常」，不是本次门控的结论。清零会造成真实故障：链路短暂失活 → `imageScore` 被清 0 → 链路恢复的下一帧亮度任务还没算完（沿用缓存 0）→ 结构分 = (1.0×0.5 + 1.0×0.3 + 0×0.2)/1.0 = **0.80** → 离散模式健康度 ≈ 0.80×0.7 + 0.3×conf < 0.65 → **一次虚假降级**（`DegradeStateMachine` 没有去抖，单帧即可降档）。

> 台词之外，源码还解释了**为什么初始值 false**：尚未评估过亮度时不预先拦截，交由链路/无画面门控处理（避免启动首帧因「还没算完」就误判无效）；以及「分数低」与「输入不可用」在代码里保持两个概念（`imageScore` 连续软分 vs `isImageInvalid` 0/1 硬判定）。

**`reset()`**——重置（停止驾驶时调用）：三个历史窗口全清（`steerHistory` / `extremeHistory` / `longExtremeHistory` 各 `removeAll()`）、`confidence` 与三路子分及 `modelConfidenceScore` 全部回 1.0、`isImageInvalid = false`、`gateReason = ""`——**注意重置后 confidence 是 1.0 不是 0**（新会话从「默认可信」开始，首次 `update` 会立刻用真实信号覆盖）。

**`computeConsistency() -> Double`（private）**——输出一致性：steer 历史的标准差越小，分越高：

- `guard !usesDiscreteSteering else { return 1.0 }`——**离散输出必须跳过一致性判据**（源码注释 P0-1：连续模型直道 std≈0.05 → 0.90 分，但 V3 的 steer 只取 {-1,0,+1}，两次反向 → std=0.316 → 0.368 分，三次反向 → std=0.387 → 0.232 分 → 加权后 **0.616 < degradeHealth 0.65** → 正常变道 / S 弯 / 连续修正就会触发 `.e2e → .yolo` **假降级**）
- `guard steerHistory.count >= 3 else { return 0.8 }`——**帧数不足给中等分**
- 均值（`mean`）→ 方差（`variance`）→ 标准差（`std`）；**线性映射：`max(0, min(1, 1.0 - std * 2.0))`**——std 0→1.0，std 0.5→0.0

**`computeExtremity() -> Double`（private）**——输出极端度：极端帧占比越低，分越高：

- `guard !extremeHistory.isEmpty else { return 1.0 }`
- `extremeRatio = 极端帧数 / 总帧数`；`extremeRatio <= extremeRatioThreshold`（0.7）→ **1.0**；高于 → 线性下降到 0
- **P2 修复**：极端占比阈值滑到 1.0（或异常值/NaN）时分母 `(1.0 - threshold)` 为 0——**除零会产出 inf/NaN 污染置信度。`guard denom > 0 else { return 0 }`**——异常时极端度直接判 0（保守降级）

**`computeImageScore(_ image: CGImage?) -> Double`（private）**——画面有效性：亮度在正常范围 → 1.0，异常 → 0.1：

- **亮度计算已移到后台队列（纯 CPU 抽样求均值，主线程零绘制、零 GPU）**，结果**异步回写 `imageScore` 与 `isImageInvalid`**；**本帧融合沿用上一帧已算好的缓存分**
- `image == nil` → **直接 `return imageScore`（不改写）**——源码注释：无画面时调用方随即会被 §0c fail-closed，这里**不得改写 `imageScore`**。若写成 0.5（旧行为），「无画面 → 恢复」的第一帧会沿用这个假分数算结构分 = 1.0×0.5 + 1.0×0.3 + 0.5×0.2 = 0.90 → 离散模式 health ≈ 0.63 + 0.3×conf，conf 低时 < 0.65 → 一次虚假降级。亮度分是「实测值」，没有测量就不要伪造测量结果
- **只保留最新帧**：`guard !brightnessInFlight else { return imageScore }`——上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，沿用缓存分即可），**避免每 tick 无脑入队、后台亮度任务堆积**
- `brightnessInFlight = true` → `Self.brightnessQueue.async { ... }`：后台算亮度（`Self.averageBrightness(cgImage:)`）→ `score = (brightness < minB || brightness > maxB) ? 0.1 : 1.0`（异常给 **0.1** 不是 0）→ 回主线程清 inFlight + 写 `imageScore` + 写 `isImageInvalid`
- **Swift 6 跨域注意**：**在后台队列提前解包 weak self，避免将非 Sendable 的 self 引用传入 @MainActor Task（Swift 6 会检查跨域发送）**——`let target: ConfidenceEstimator? = self` 先解包，再 `Task { @MainActor [target] in ... }`

**`brightnessInFlight`（@ObservationIgnored）**：亮度后台任务 in-flight 标志——**主线程置位 / 后台回主线程清除，全程主线程访问无锁**。

**`brightnessQueue`（static）**：后台亮度计算队列（**独立于推理队列的 serial queue**；label `com.aurora.confidence.brightness`, .userInitiated）。

**`brightnessContext`（static）**：复用的 CoreImage 渲染上下文（`[.cacheIntermediates: false]` + `.useSoftwareRenderer: true`）——**仅供 `AURORA_CONF_CI=1` 排查对比的 CoreImage 回退路径使用，默认路径不碰 CIContext**。⚠️ 源注释记录：`.useSoftwareRenderer` 在 Apple Silicon **被静默忽略**（`CIContext.h`：仅 OpenCL 平台生效），故该「CPU 渲染」实际仍走 Metal——这正是 2026-10-11 彻底移除 CIContext 的原因。

**`useCoreImagePath`（static）**：回退开关，`ProcessInfo.processInfo.environment["AURORA_CONF_CI"] == "1"` 时走 CoreImage 路径，默认 false（纯 CPU）。

**`averageBrightness(cgImage:) -> Double`（private static）**——平均亮度入口，按 `useCoreImagePath` 分流到两条实现（后台执行）。

- **默认纯 CPU 路径 `averageBrightnessViaCPU(cgImage:)`**：直接从 CGImage data provider 读字节指针（`cgImage.dataProvider` / `CFDataGetBytePtr`），按步长抽样 ~4096 点求均值（`let step = max(1, total / 4096)`，1280×832 约 0.4% 采样）——**无 CIContext / 无 CIImage / 无 Metal 提交，绝不与游戏抢 GPU**；开销约 0.05ms（源码注释）。字节序按 `bitmapInfo.contains(.byteOrder32Little)` 精确判定，防御性边界检查 `offset + 3 >= CFDataGetLength(data) → break`。2026-10-11 实测：旧 CIContext 路径在 Apple Silicon 走 Metal 并 `waitUntilCompleted` 阻塞等 GPU（`sample` 采样栈铁证：679 样本全卡在 `_MTLCommandBuffer waitUntilCompleted`），是「没开游戏也卡到 12fps」的根因
- **CoreImage 回退路径 `averageBrightnessViaCoreImage(cgImage:)`（仅 `AURORA_CONF_CI=1` 时启用）**：`CIFilter(name: "CIAreaAverage")` + `kCIInputImageKey` / `kCIInputExtentKey` → 渲染到 1×1 RGBA8 缓冲（`brightnessContext.render(...)`）
- 两条路径都读平均 RGB → **Rec.601 亮度近似**：`0.299 × r + 0.587 × g + 0.114 × b`——与旧 DeviceGray 转灰的视觉亮度一致；阈值 0.08/0.95 粗糙，语义等价
- 不支持格式 / 无像素数据 / 计数为 0 返回 0.5（`guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32, ... else { return 0.5 }` / `guard count > 0 else { return 0.5 }`，中等分，不误判）

**ConfidenceEstimator 文档至此完整**（门控与融合 → reset 与子分计算）。给别的 AI 的最关键提示：**isLive 门控是降级链条的发令枪**——链路死必须归零，否则退化平衡点公式会让死模型永远卡在 .e2e 档；**只判转向打满、不判油门贴边**（否则健康巡航被误判退化，永远回不到端到端档）；**长窗口 90 帧的语义随 tick 频率漂移，不是恒定 3 秒**（帧计数常量口径漂移，待产品决策）。
