# 代码-15 ConfidenceEstimator 置信度估计
> 覆盖源文件：`Sources/AuroraDrive/Inference/ConfidenceEstimator.swift`（**357 行**，2026-10-18 `wc -l` 实测）。基于当前仓库逐单元编写。
>
> **✅ 2026-10-18 复核（T6）**：本次逐条 `read` 源码核对，**全部单元行号已按当前 357 行版重测**（旧版按 348 行编写，源文件在 :75-84 新增「20Hz 口径漂移」注释块后整体下移 9 行）。
> 三处实质修正：
> 1. **行数 348 → 357**；§一 区间由「第 1–100 行」改为「第 1–97 行」（`update` 主入口实际从 :98 起，旧文写 :89–140）。
> 2. **`longExtremeWindow = 90` 的口径漂移已标注**（源注释 :75-84，2026-10-18 加入）：90 帧按 **30Hz** 设计意图是 3 秒，但 tick 已于 2026-10-12 定档 **20Hz** → 实际是 **4.5 秒**（比设计意图慢 50%）。属 20Hz 迁移漏改项（同批还有 `YoloEngine.lockLostFrames` / `MotionPredictor.maxPredictionFrames` / `maxMissingFrames` / `LaneFallback.stabilityFrames`）。**源注释明确「只标注不改数值」**（改数值会改变降级时序，属产品决策）。⚠️ **待确认**：是否要恢复 3 秒语义（改为 60 帧，或按 tickHz 换算）。
> 3. **`computeImageScore` 的亮度路径注释与实现已对齐**：默认走**纯 CPU 直接采样**（:282-333），`brightnessContext`（:229-240）与 `averageBrightnessViaCoreImage`（:335-356）**仅在 `AURORA_CONF_CI=1` 时启用**——旧文已正确描述，本次仅核对行号。
>
> **🔁 行号已按当前版重基准（2026-10-18，源码冻结）**：`ConfidenceEstimator.swift` 稳定在 **357 行**（即 lead 加完 `:75-84` 口径漂移注释后的冻结版，此后未再变动）。本篇 **84 条行号引用逐条 `sed -n` 复验，全部命中、零修正**（含 37/39/41/44/47/50/53/54/59/62-64/69/71/73/75-85/87/89/98/112-113/119/120-121/122-123/131-134/148/153-156/159/167-172/177-187/194-196/203-214/229-240/246-257/269/282-295/299/304-310/320/327/332/335-356）。**本篇不引用 `AuroraDriveApp.swift`，因此不受 9097 行重基准影响**。

## 一、门控与三信号融合架构（第 1–97 行）

**定位（4–25 行头注释）**：置信度估计器——**E2E 模型不输出置信度，用启发式从"模型输出历史 + 当前画面"估算**。输出 [0,1] 置信度分，**供降级状态机决策**。

**门控 + 三个信号融合（源注释原文 10–19 行）：**

| # | 信号 | 说明 |
|---|---|---|
| 0 | **链路存活门控** | 模型未加载 / 无推理结果 / 结果过期 → 置信度直接 0（**修复退化平衡点**：E2E 恒输出 idle/恒定值时旧公式会算出 0.70，高于降级阈值 0.65，**导致死模型永远卡在端到端档不降级**） |
| 1 | 输出一致性 | 最近 N 帧 steer 抖动越小越可信（模型稳定） |
| 2 | 转向极端度 | steer 长时间打满（\|steer\|>0.95）视为退化——（**油门/刹车贴边属正常驾驶行为，不再扣分**——修复"健康巡航恒 0.70、导致永远够不到 0.75 恢复阈值、卡死在规则档"的缺陷；**输出稳定不判冻结**——直道上模型本来就该稳定输出） |
| 3 | 画面有效性 | 亮度异常（全黑/全白）直接判低置信 |

**设计（21–25 行）**：滑动窗口存最近 N 帧输出，O(1) 更新；三个信号加权融合，权重可调；**线程安全：仅主线程调用（与 tick 同步）**——注意单元三会看到例外（亮度计算移到后台队列）。

**类声明（第 31–32 行）**：`@Observable final class ConfidenceEstimator: @unchecked Sendable`。

**可调参数（第 34–54 行，属性实际定义 36–54 行）：**

| 参数 | 默认值 | 行号 | 说明 |
|---|---|---|---|
| `consistencyWeight` | 0.5 | :37 | 输出一致性权重（抖动越小分越高） |
| `extremityWeight` | 0.3 | :39 | 输出极端度权重（贴边越久分越低） |
| `imageWeight` | 0.2 | :41 | 画面有效性权重（亮度异常分越低） |
| `windowSize` | 20 | :44 | 滑动窗口大小（最近 N 帧用于算一致性） |
| `extremeThreshold` | 0.95 | :47 | 极端值阈值：\|steer\|>0.95 视为转向打满（退化） |
| `extremeRatioThreshold` | 0.7 | :50 | 极端持续帧数超过此**比例** → 判退化 |
| `brightnessMin / brightnessMax` | 0.08 / 0.95 | :53 / :54 | 画面亮度正常范围（归一化 0~1），超出视为异常 |

**状态输出（第 56–64 行，属性实际定义 58–64 行）**：`confidence`（当前置信度估计值 [0,1]，UI 观察，默认 1.0，:59）+ 三路子分 `consistencyScore / extremityScore / imageScore`（:62-64，调试/UI 展示用，各默认 1.0）。

**内部状态（第 66–87 行，旧文误写 66–78）：**

| 成员 | 行号 | 说明 |
|---|---|---|
| `steerHistory: [Double]` | :69 | 最近 N 帧 steer，算抖动 |
| `extremeHistory: [Bool]` | :71 | 最近 N 帧是否极端（短窗口） |
| `longExtremeHistory: [Bool]` | :73 | **长窗口极端标记，判"持续打满=贴墙/打转退化"**（长度见 `longExtremeWindow`） |
| `longExtremeWindow: Int = 90` | :75-85 | 长窗口帧数。⚠️ **口径漂移（源注释 :77-84）**：按「3 秒 @30Hz」定为 90 帧，但 tick 已定档 **20Hz** → 实际 **4.5 秒**（慢 50%），即"方向持续打满"要更久才判退化。**源注释只标注不改**；要恢复 3 秒语义应改 60 帧或按 tickHz 换算。**⚠️ 待确认（产品决策）** |
| `longExtremeRatioThreshold = 0.7` | :87 | 长窗口打满占比阈值：超过 → 判持续退化 |

**`update(command: ControlCommand, image: CGImage?, isLive: Bool)`（第 98–149 行，旧文误写 89–140）——主入口，四步：**

1. **链路健康门控（99–109 行，旧文误写 90–100）**：`guard isLive else { confidence = 0; 三个子分全 0; return }`——isLive 参数含义（**92–97 行**注释，旧文误写 86–88）：**推理链路是否真的活着（模型已加载 && 最近有新鲜结果）**；链路死 → 置信度直接置 0，**强制降级到 YOLO 接管，避免 E2E 空转却卡在 .e2e 档**
2. **更新历史窗口（111–123 行，旧文误写 102–114）**：`steerHistory.append` + 超窗 `removeFirst`（:112-113）；`isExtreme = abs(command.steer) > extremeThreshold`（:119）——**只判转向打满**（**115–118 行**注释，旧文误写 106–109：油门/刹车贴边（0 或 1）是正常驾驶行为，不判极端——旧定义把"巡航全油门"误判为退化，导致置信度恒 0.70、永远够不到 .rule→.e2e 的 0.75 恢复阈值，卡死在规则档）；`extremeHistory`（:120-121）+ `longExtremeHistory`（:122-123）双窗口都追加
3. **三路子分 + 加权融合（125–134 行，旧文误写 116–125）**：`confidence = (一致性×0.5 + 极端度×0.3 + 画面×0.2) / max(total, 1e-6)`（:131-134）
4. **持续转向打满 → 压置信（136–147 行，旧文误写 127–138）**：长窗口内 \|steer\|>0.95 占比 >70% → `confidence = min(confidence, 0.30)` **强制降级**——源注释（**136–140 行**，旧文误写 128–131）：一致性满分会把"打满恒定输出"洗成 0.70（高于降级阈值 0.65），导致模型打满 16 秒还卡在端到端档**继续注入错误按键**；只判"转向打满"，不是判"输出恒定"。注意源注释写「长窗口（3s）」——**⚠️ 该 3 秒表述已因 20Hz 漂移失效，实际 4.5s**（见上表 `longExtremeWindow`）
5. `confidence = max(0, min(1, confidence))`（:148）——夹到 [0,1]

## 二、reset 与三路子分计算（第 151–356 行）

**`reset()`（第 151–160 行，旧文误写 143–151）**——重置（停止驾驶时调用）：三个历史窗口全清（steerHistory :153 / extremeHistory :154 / longExtremeHistory :155）、confidence 与三路子分全部回 1.0（:156-159）——**注意重置后 confidence 是 1.0 不是 0**（新会话从"默认可信"开始，首次 update 会立刻用真实信号覆盖）。

**`computeConsistency() -> Double`（private，第 164–173 行，旧文误写 157–164）**——输出一致性：steer 历史的标准差越小，分越高：

- `guard steerHistory.count >= 3 else { return 0.8 }`（:167）——**帧数不足给中等分**
- 均值（:168）→ 方差（:169）→ 标准差（:170）；**线性映射：`max(0, min(1, 1.0 - std * 2.0))`**（:172）——std 0→1.0，std 0.5→0.0

**`computeExtremity() -> Double`（private，第 175–188 行，旧文误写 167–179）**——输出极端度：极端帧占比越低，分越高：

- `guard !extremeHistory.isEmpty else { return 1.0 }`（:177）
- `extremeRatio = 极端帧数 / 总帧数`（:178）；`extremeRatio <= extremeRatioThreshold`（0.7，:50）→ **1.0**（:180-182）；高于 → 线性下降到 0（:187）
- **P2 修复（183–187 行，旧文误写 174–178）**：极端占比阈值滑到 1.0（或异常值/NaN）时分母 `(1.0 - threshold)` 为 0——**除零会产出 inf/NaN 污染置信度。`guard denom > 0 else { return 0 }`**（:185-186）——异常时极端度直接判 0（保守降级）

**`computeImageScore(_ image: CGImage?) -> Double`（private，第 190–218 行，旧文误写 184–209）**——画面有效性：亮度在正常范围 → 1.0，异常 → 0.1：

- **亮度计算已移到后台队列（纯 CPU 抽样求均值，主线程零绘制、零 GPU）**，结果**异步回写 imageScore**；**本帧融合沿用上一帧已算好的缓存分**（**190–192 行**注释，旧文误写 182–183）
- `image == nil` → `imageScore = 0.5`（:194-196，无图像给中等分）
- **只保留最新帧（201–204 行，旧文误写 192–195）**：`guard !brightnessInFlight else { return imageScore }`（:203）——上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，沿用缓存分即可），**避免每 tick 无脑入队、后台亮度任务堆积**
- `brightnessInFlight = true`（:204）→ `Self.brightnessQueue.async { ... }`（:205）：后台算亮度（:206）→ `score = (brightness < minB || brightness > maxB) ? 0.1 : 1.0`（:207，异常给 **0.1** 不是 0）→ 回主线程清 inFlight + 写 imageScore（:211-214）
- **Swift 6 跨域注意（208–210 行注释，旧文误写 199–201）**：**在后台队列提前解包 weak self，避免将非 Sendable 的 self 引用传入 @MainActor Task（Swift 6 会检查跨域发送）**——`let target: ConfidenceEstimator? = self`（:210）先解包，再 `Task { @MainActor [target] in ... }`（:211）

**`brightnessInFlight`（@ObservationIgnored，第 220–223 行，旧文误写 213–214）**：亮度后台任务 in-flight 标志——**主线程置位 / 后台回主线程清除，全程主线程访问无锁**。

**`brightnessQueue`（static，第 225–227 行，旧文误写 217–218）**：后台亮度计算队列（**独立于推理队列的 serial queue**；`com.aurora.confidence.brightness`, .userInitiated）。

**`brightnessContext`（static，第 229–240 行，旧文误写 228–231）**：复用的 CoreImage 渲染上下文（`[.cacheIntermediates: false]` + `.useSoftwareRenderer: true`，:237-240）——**仅供 `AURORA_CONF_CI=1` 排查对比的 CoreImage 回退路径使用，默认路径不碰 CIContext**。⚠️ 源注释（:231-236）记录：`.useSoftwareRenderer` 在 Apple Silicon **被静默忽略**（`CIContext.h:184`：仅 OpenCL 平台生效），故该"CPU 渲染"实际仍走 Metal——这正是 2026-10-11 彻底移除 CIContext 的原因。

**`useCoreImagePath`（static，第 273–275 行，旧文误写 265–266）**：回退开关，`AURORA_CONF_CI=1` 时走 CoreImage 路径，默认 false（纯 CPU）。

**`averageBrightness(cgImage:) -> Double`（private static，第 277–280 行，旧文误写 268–271）**——平均亮度入口，按 `useCoreImagePath` 分流到两条实现（后台执行）。

- **默认纯 CPU 路径 `averageBrightnessViaCPU`（第 282–333 行，旧文误写 273–324）**：直接从 CGImage data provider 读字节指针（:288-292），按步长抽样 ~4096 点求均值（:299，1280×832 约 0.4% 采样）——**无 CIContext / 无 CIImage / 无 Metal 提交，绝不与游戏抢 GPU**；开销约 0.05ms（:269 注释）。字节序按 `bitmapInfo.byteOrder32Little` 精确判定（:304-310），防御性边界检查 `offset + 3 >= CFDataGetLength(data) → break`（:320）。2026-10-11 实测：旧 CIContext 路径在 Apple Silicon 走 Metal 并 `waitUntilCompleted` 阻塞等 GPU（:246-257 采样栈铁证：679 样本全卡在 `_MTLCommandBuffer waitUntilCompleted`），是「没开游戏也卡到 12fps」的根因
- **CoreImage 回退路径 `averageBrightnessViaCoreImage`（第 335–356 行，旧文误写 326–347，仅 `AURORA_CONF_CI=1` 时启用）**：`CIFilter(name: "CIAreaAverage")`（:339）+ inputImage/extent（:340-341）→ 渲染到 1×1 RGBA8 缓冲（:344-351）
- 两条路径都读平均 RGB → **Rec.601 亮度近似**：`0.299 × r + 0.587 × g + 0.114 × b`（:332 / :355）——与旧 DeviceGray 转灰的视觉亮度一致；阈值 0.08/0.95 粗糙，语义等价
- 不支持格式 / 无像素数据 / 计数为 0 返回 0.5（:291 / :295 / :327，中等分，不误判）

**ConfidenceEstimator 文档至此完整**（357 行全覆盖：门控与融合 → reset 与子分计算）。给别的 AI 的最关键提示：**isLive 门控是降级链条的发令枪**——链路死必须归零，否则退化平衡点公式会让死模型永远卡在 .e2e 档；**只判转向打满、不判油门贴边**（否则健康巡航被误判退化，永远回不到端到端档）；**长窗口 90 帧在 20Hz 下是 4.5 秒不是 3 秒**（20Hz 迁移漏改，待产品决策）。
