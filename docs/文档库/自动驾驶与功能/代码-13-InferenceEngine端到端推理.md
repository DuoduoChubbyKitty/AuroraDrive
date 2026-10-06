# 代码-13 InferenceEngine 端到端推理

> 覆盖源文件：`Sources/AuroraDrive/Inference/InferenceEngine.swift`（**522 行**，2026-10-06 `wc -l` 实测重核；本篇原按 432 行版本编写，行号已全部按当前快照校正）+ `Sources/AuroraDrive/Inference/QuestPanelReader.swift`（**1160 行**，Inference/ 下未跟踪新文件）。基于当前仓库逐单元编写。

## 一、模型接口、状态与双缓冲（第 1–135 行）

**定位（6–24 行头注释）**：CoreML E2E 推理引擎——加载 m9_mono.mlpackage，把**截屏画面 + 车辆状态 → steer/throttle/brake**。

**模型接口（10–15 行注释，来自 tools/export_game_assist_coreml.py 与 src/model.py）：**

| 张量 | 形状 | 类型/范围 |
|---|---|---|
| 输入 `image` | `[1, 3, 180, 320]` | Float32, CHW, 归一化 [0,1] |
| 输入 `vehicle_state` | `[1, 6]` | Float32 |
| 输出 `steer` | `[1]` | **tanh** ∈ [-1, 1] |
| 输出 `throttle` | `[1]` | **sigmoid** ∈ [0, 1] |
| 输出 `brake` | `[1]` | **sigmoid** ∈ [0, 1] |

vehicle_state 6 维 = `[speed, rpm, gear, speed_norm, gear_norm, reserved]`（原始导出注释口径；**实际喂的契约见单元三的 buildVehicleState**——两者不同！头注释是导出脚本口径，运行时已改为训练契约 v2_new）。

**四个设计要点（源注释原文，16–24 行）**：① 异步推理——后台队列跑，不阻塞主线程 tick；② 频率解耦——tick 30Hz 调用，推理约 24Hz，结果缓存供 tick 读最新值；③ 线程安全——预处理/推理用 nonisolated 静态函数，无 self 捕获，MLMultiArray/MLModel 非 Sendable 但单线程访问安全；④ 车辆状态——游戏状态读取未接入前，speed 用 DriveState.speed 估算，rpm/gear 用启发式占位。

**类声明（第 48–50 行）**：`@Observable @MainActor final class InferenceEngine`。

**模型参数与状态（第 52–129 行，行号已按 522 行版重核）：**

| 成员 | 行号 | 说明 |
|---|---|---|
| `inputHeight = 180` / `inputWidth = 320`（static） | :55-56 | 输入图像尺寸 H×W（模型训练时的分辨率） |
| `stateDim = 6`（private nonisolated static） | :59 | vehicle_state 维度（编译期常量，无 actor 依赖） |
| `isLoaded`（private(set)） | :64 | 是否已加载模型（启动时 lazy 加载） |
| `isLoadingModel`（private） | :72 | A19 后台兜底加载的在途标记（一次只允许一个在途加载） |
| `isInferencing`（private(set)） | :75 | 是否正在推理中（防止重叠推理） |
| `lastResult: InferenceResult?`（private(set)） | :78 | 最新推理结果（tick 读取此值） |
| `lastResultTime: Date?`（private(set)） | :81 | 最近一次成功推理的时间戳（**判结果新鲜度：链路是否真的活着**） |
| `inferenceCount`（private(set)） | :84 | 累计推理次数（性能监控） |
| `errorMessage: String?`（private(set)） | :87 | 加载/推理错误信息（UI 展示用） |
| `lastLoadAttempt: Date`（@ObservationIgnored） | :90-91 | P0-4 修复：上次加载尝试时间戳（**失败冷却用**） |
| `loadRetryCooldown: TimeInterval = 5.0` | :94 | 加载失败冷却时长（秒） |
| `generation`（@ObservationIgnored） | :98-99 | P1 修复：**reloadModel()/reset() 时递增；在途推理完成后比对，不匹配则丢弃过期结果**，防 reset/reload 后旧在途结果写回 lastResult |
| `model: MLModel?`（@ObservationIgnored + **nonisolated(unsafe)**） | :106-107 | CoreML 模型实例——MLModel.prediction 内部线程安全，可跨队列调用；不参与 SwiftUI 观察 |
| `inferenceQueue` | :116-117 | 后台推理队列（**串行**，保证推理不重叠；`com.aurora.inference`, .userInteractive） |
| `reusableImageBuffer / reusableStateBuffer`（nonisolated(unsafe)） | :117-120 | P1 修复：**可复用的推理输入缓冲**（image 1×3×180×320 ≈691KB + state 1×6），尺寸不变时复用，避免每帧新建 MLMultiArray；只在串行 inferenceQueue 上创建与读写，isInferencing 防重叠保证无并发访问 |
| `modelFileName`（private let） | :125 | 本引擎加载的模型文件名（不带扩展名） |
| `perfChannel`（private var 计算属性） | :128-133 | A20：PerfBus 上报通道名（按模型文件名区分） |

**`init(modelFileName: String = "m9_mono")`（第 135–137 行）**：

- 默认 `"m9_mono"` 端到端主驾；**`"game_assist_control"` 为第二套驾驶模型（YOLO 接管档的司机）**
- init 只记文件名——**模型 lazy 加载**（首次 infer 经 loadIfNeeded），启动不卡顿

**`modelURL`（计算属性，第 142–153 行）**：`AuroraPaths.projectRoot() + models + "\(modelFileName)"`；**优先加载训练产出的编译模型 `<name>.mlmodelc`**（.mlmodelc 为 coremlcompiler 编译产物），**回退到历史未编译的 `<name>.mlpackage`**——保证「训练完一键热替换」生效。

**`InferenceResult`（struct，第 34–40 行）**：`steer / throttle / brake / latencyMs`——单次推理输出（**与 ControlCommand 兼容**）；latencyMs 推理耗时（毫秒）用于性能监控；标记 `Sendable`（跨 actor 传递）。

## 二、loadIfNeeded / scheduleBackgroundLoadIfNeeded / warmUp / reloadModel（第 155–272 行）

**`loadIfNeeded()`（第 157–177 行）**——加载 CoreML 模型（启动路径显式预热用，**保持同步、MainActor**）：

```swift
guard !isLoaded else { return }
// P0-4 修复：失败后冷却期内不再重试，避免主线程同步 MLModel() 30Hz 重试风暴
guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
lastLoadAttempt = Date()
```

- **P0-4 修复**：失败后 5 秒冷却期内不再重试——避免主线程同步 `MLModel()` 30Hz **重试风暴**（模型文件缺失时每帧同步 IO）
- `MLModelConfiguration` + `config.computeUnits = .all`——**自动选 ANE/GPU/CPU，优先 ANE**
- `try MLModel(contentsOf: modelURL, configuration: config)` 成功 → `isLoaded = true`、errorMessage = nil、**环3：后台跑一次 dummy prediction 预热 ANE**（:175）
- 失败 → `errorMessage = "模型加载失败: ..."`、isLoaded = false

**`scheduleBackgroundLoadIfNeeded()`（private，第 190–223 行）——A19（2026-10-04）后台兜底加载**，由 `infer()` 在「模型尚未加载」时调用（:299）。改前是同步 `loadIfNeeded()`：冷态 250–1330ms/热态 16–62ms 直接冻结主线程，最坏情形 4 个模型连续兜底合计 **2876ms 单帧冻结**（:278–296 注释）。

- **三重门（缺一不可，:183–188 注释）**：① `isLoadingModel`——一次只允许一个在途加载（30Hz 每帧都会进来）；② `loadRetryCooldown`——失败后 5s 内不重试；③ `generation` 比对——加载期间若被 `reloadModel()`/`reset()` 作废，回来的结果必须丢弃
- `modelURL` 是计算属性（内部走 AuroraPaths 缓存），**在进后台队列之前求值**，避免后台线程碰 MainActor 状态（:211–212）
- 后台队列做 `MLModel(contentsOf:)`（真正耗时的磁盘 I/O + CoreML 图编译，:204–209），**只把结果赋值这一小步回主线程**（`Task { @MainActor }`，:211–222）——`isLoaded`/`errorMessage` 的写满足 MainActor 约束
- 成功 → `model = loaded`、`isLoaded = true`、`Self.warmUp(...)`（:218–220）；失败 → errorMessage「模型加载失败（后台兜底加载）」

**`warmUp(model:label:queue:)`（private nonisolated static，第 229–257 行）**——模型预热（环3）：

- **后台队列跑一次 dummy prediction，把 ANE 计算图编译/内存分配提前做完，避免首帧真实推理出现冷启动尖峰**（162–163 行注释）。全零输入即可（数据内容不影响预热）
- 构造：`MLMultiArray(shape: [1, 3, h, w], .float32)` + `MLMultiArray(shape: [1, 6], .float32)` → `MLDictionaryFeatureProvider(["image": ..., "vehicle_state": ...])`
- 成功打印 `[warmup] <label> 预热完成: Xms computeUnits=all`；失败打印原因（不阻塞）

**`reloadModel()`（第 260–266 行）**——训练完成后热替换模型：

```swift
generation += 1      // 在途推理结果过期
model = nil
isLoaded = false
isInferencing = false
errorMessage = nil
```

- **置空当前模型引用与加载标记，下一次 infer() 会经 loadIfNeeded 自动重读 modelURL**（优先指向新训练的 m9_mono.mlmodelc）——实现「点完训练即用新模型」
- `generation += 1`：在途推理结果过期（finishInference 里比对丢弃）

**热替换链路**：UI 侧训练脚本产出 `models/m9_mono.mlmodelc` → socket 命令 `reloadmodel`（EngineMain.handleCommand）→ 三引擎（inferenceEngine/assistEngine/yoloEngine）各自 reloadModel → 下次推理重读磁盘。**注意 reloadModel 只置空引用不重命名文件**——文件名仍是 modelFileName，靠 mlmodelc 优先规则指向新产物。

## 三、infer() 推理流程与 readScalar（第 274–394 行）

**`infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double)`（第 276–378 行）**——异步推理主线程入口：

1. `guard isLoaded, let modelRef = model else { scheduleBackgroundLoadIfNeeded(); return }`（:298–300）——未加载时走 **A19 后台兜底加载**（绝不同步、绝不冻主线程）
2. `guard !isInferencing else { return }`（:301）——**防重叠：上一帧还没跑完就跳过**
3. `isInferencing = true`（:303）；**CGImage 不可变，可安全跨线程**（环2 由 CaptureEngine 直传，省 NSImage→CGImage 转换，:305）；快照 `gen = generation`（:307）
4. `inferenceQueue.async { [weak self] in ... }`（:308，后台串行队列，`start = Date()` :311）：

**① 预处理 + 车辆状态构造（第 314–331 行）**：

- **P1 修复：复用输入缓冲**——`reusableImageBuffer`/`reusableStateBuffer` 为 nil 时才新建（:314–322，image ≈691KB），尺寸不变时复用
- `Self.preprocessImage(image, height: h, width: w, into: self.reusableImageBuffer)`（:326）+ `Self.buildVehicleState(speedKmh:speedLimitKmh:into: self.reusableStateBuffer)`（:327）——**nonisolated 静态函数，无 actor 依赖**
- 任一失败 → `Task { @MainActor in self.finishInference(gen, nil, error: "预处理失败") }`（:330）

**② CoreML 输入构造（第 335–342 行）**：`MLFeatureValue(multiArray:)` 是 **non-throwing 初始化器**直接构造——`imageFeature`（:336）+ `stateFeature`（:337）→ `inputDict: ["image": ..., "vehicle_state": ...]`（:339–341）。

**③ 同步推理（第 349–350 行）**：`try MLDictionaryFeatureProvider(dictionary: inputDict)` → `try modelRef.prediction(from: provider)`——已在后台队列，不阻塞主线程；MLModel.prediction 内部线程安全。

**④ 输出解析（第 354–373 行）——readScalar 关键坑：**

```swift
func readScalar(_ name: String) -> Double {
    guard let fv = output.featureValue(for: name) else { return 0 }
    if let mv = fv.multiArrayValue {
        return mv[[0, 0]].doubleValue     // 关键：按 [0,0] 下标读
    }
    return fv.doubleValue
}
let steer = readScalar("steer")
let throttle = readScalar("throttle")
let brake = readScalar("brake")
```

⚠️ **源注释（355–357 行附近）**：CoreML 输出是 `MLMultiArray(shape [1,1])`，**必须用 `multiArrayValue[[0,0]].doubleValue` 读取。直接用 `featureValue(for:)?.doubleValue` 对 multiArray 类型会返回 0**，导致 e2eCommand 恒为 idle（**端到端主驾完全不决策的元凶**）。

- `latency = Date().timeIntervalSince(start) * 1000`（:365）→ `InferenceResult(...)`（:367–371）→ `Task { @MainActor in self.finishInference(gen, result, error: nil) }`（:371）
- 推理异常 → `finishInference(gen, nil, error: "推理失败: ...")`（:373）

**`finishInference(_ gen:result:error:)`（private，第 380–394 行）**：

- **`guard gen == generation else { return }`**（:381）——reset()/reloadModel() 后在途结果过期，丢弃（与 SpeedOCRReader.finish 同机制）
- `isInferencing = false`（:382）
- result 非空 → `lastResult = result` + `lastResultTime = Date()` + `inferenceCount += 1`（:384–386），并 **A20：`PerfBus.shared.record(perfChannel, ms: result.latencyMs)` 汇报真实推理耗时**（:388–391）——注意区分：`--perf-selftest` 的 submit.m9/submit.assist 通道测的是 DispatchQueue.async 的**提交开销**（p50 ≈0.008ms），与真正推理耗时差三个数量级
- error 非空 → `errorMessage = error`（:392–393）

**线程安全小结**：预处理/推理全在后台串行队列（nonisolated 静态函数 + reusable 缓冲）；结果写回经 Task @MainActor；generation 防过期——三重保证"结果要么是新鲜的，要么被丢弃"。

## 四、buildVehicleState 训练契约与 preprocessImage（第 396–522 行）

**`buildVehicleState(speedKmh:speedLimitKmh:into:) -> MLMultiArray?`（private nonisolated static，第 412–443 行）**——构造 vehicle_state 6 维向量。**⚠️ 本单元是整个推理引擎最重要的契约（399–411 行注释）：**

```
与训练契约一致（src/mono_dataset.py v2_new 格式）：
  [speed_norm, curvature*5, sin(heading), cos(heading), speed_limit_norm, 0]
之前喂的是启发式 [speed原始值, rpm(800~8000), gear(1~6), ...]，
前三维超出训练分布 60~8000 倍 → 模型收到垃圾状态 → 恒输出 steer=-1/throttle=1
（已用真实帧 + 训练权重逐组验证：正确契约 steer≈-0.04/throttle≈0.99）
```

- **头注释里的 [speed, rpm, gear, ...] 口径是导出脚本的历史口径，运行时已改为上面的训练契约**——换模型/换训练版本时两边必须同步
- **游戏遥测未接入前的占位**：`speed_norm = speed/120`、`curvature*5 = 0`（取训练分布内零值）、`sin/cos(heading) = 0/1`（等价 heading=0）、`speed_limit_norm = speedLimit/120`、`reserved = 0`（实现 :415–419）
- **P1 修复**：复用传入的 state 缓冲（尺寸 1×6 不变），避免每帧新建 MLMultiArray——复用前校验 shape（`[1, 6]`，:421–424），不匹配才新建
- 归一化：`max(0.0, min(1.0, speedKmh / 120.0))`（:415）——120 是训练时的速度归一化基准

**`preprocessImage(_ cgImage:height:width:into:) -> MLMultiArray?`（private nonisolated static，第 445–513 行）**——CGImage → MLMultiArray [1, 3, H, W] Float32 CHW 归一化 [0,1]：

1. **缩放绘制**：CGContext（DeviceRGB + premultipliedLast）+ `interpolationQuality = .high` + `ctx.draw` 到 180×320——RGBA 像素读入 pixelData
2. **复用 image 缓冲（P1 修复）**：调用方在 infer 里已做 nil 检查复用（:314–322），preprocess 内部写入前按 shape 校验
3. **RGBA → CHW 重排（:488–498）**：三平面布局，`[0,c,y,x] = outputPtr[c*planeSize + y*width + x]`——**先写原始 0~255 值，保留与旧双循环完全一致的通道顺序与布局（R/G/B 三平面）**
4. **一次性向量化归一化（:503–506）**：`vDSP_vsdiv(outputPtr, 1, &divisor, outputPtr, 1, vDSP_Length(3 * planeSize))` 整块除以 255 → [0,1]——源注释：**vDSP_vsdiv 与逐像素 Float32(x)/255.0 同为 IEEE Float 除法，位级一致；只把除法移出 CHW 双循环，通道顺序/布局不动，训练契约不变**

**`reset()`（第 515–521 行）**——重置（停止驾驶时调用）：`generation += 1`（在途推理结果过期）、lastResult = nil、lastResultTime = nil、isInferencing = false、errorMessage = nil。**注意 reset 不清 reusable 缓冲**（尺寸不变可继续复用，内容下次推理覆写）。

**InferenceEngine 文档至此完整**（522 行全覆盖：模型接口 → 加载与 A19 后台兜底加载 → 热替换 → infer 流程 → PerfBus 耗时上报 → 训练契约与预处理）。给别的 AI 的最关键提示：**vehicle_state 必须喂训练契约 v2_new 格式**（喂启发式 rpm/gear 会让模型恒输出 steer=-1/throttle=1），**CoreML 标量输出必须按 [0,0] 下标读**，**热路径兜底加载绝不能同步**（A19）。

---

# 五、任务面板 OCR —— QuestPanelReader.swift（1160 行，完整机制）

> 覆盖源文件：`Sources/AuroraDrive/Inference/QuestPanelReader.swift`（1160 行，2026-10-06 快照实测）。它是 `tools/quest/quest_matcher.py` 的 Swift 逐位对齐移植：**OCR 读面板 → 查 `models/quest_index.json` → 世界坐标（UE5 厘米）→ setLocatorTarget**。所有论断均带 `文件:行号`，行号已逐条核实。

## 5.1 数据流总览（帧 → ROI → OCR → 投票 → 匹配 → verdict → setLocatorTarget）

```
DriveState.tick（AuroraDriveApp.swift:6549-6557；⚠️ 2026-10-07 实测已漂移，原引用 6435-6438）
  │  gate：AuroraFlags.questOCR（AuroraFlags.swift:201，AURORA_QUEST_OCR，默认 true）
  │        且 currentFrameCG != nil
  ▼
questPanel.ingest(cgImage:)                         QuestPanelReader.swift:541
  ├─ 节流 0.7s：shouldRun(now:)                     :543 → :509-511（minInterval :431）
  ├─ 防堆积：ocrInFlight guard（上一次 OCR 未回 → 跳过）  :544
  ├─ markRan + ocrRuns += 1                         :545-546
  ├─ cropROI：归一化 ROI → 像素裁剪                  :548 → :634-642
  │    questROI = (x:0.030, y:0.240, w:0.370, h:0.070)   :424（左上原点，y 向下）
  │    2940×1912 下 = x 88~1176 / y 458~592（自检断言 :1089-1093）
  ├─ ocrQueue.async（label "aurora.quest.ocr", qos .utility）  :555（队列声明 :483）
  ▼
后台：recognizeLines(in:)（:556 → :648-661）
  ├─ VNRecognizeTextRequest：.accurate              :650
  ├─ usesLanguageCorrection = false                 :651
  ├─ recognitionLanguages = ["zh-Hans", "en-US"]    :652
  ├─ boundingBox.midY 降序 → 从上到下                :658-659（Vision 原点在左下）
  └─ isHintLine 过滤（「V 按下进行追踪」等）          :556 → :453-462
  ▼
DispatchQueue.main.async（:557）
  ├─ ocrInFlight = false；空行 → lastDiagnostic，return   :559-563
  ├─ ocrCompletions += 1                            :564
  ▼
ingest(text:)（投票 + 匹配）                         :575-608
  ├─ clean（剥 <…> 标签 + Python 式 strip，标量级）   :577 → :266-280
  ├─ 投票：连续 voteNeed=3 次相同文本才放行           :580-581（voteNeed :427）；
  │    文本抖动即重置计数（:580 else 分支）；只存 String 不存图像
  ▼
match(_:)（五路匹配 + 兜底，见 5.3）                 :583 → :690-829
  ▼
verdict switch（:586-607）
  ├─ .miss → missCount+1，lastDiagnostic「未命中」    :587-590
  ├─ .low  → lastDiagnostic「置信不足」              :592-594
  ├─ .ambiguous → resolveAmbiguous（:596-602 → :883-902）
  └─ .ok → entries.first（:604-606）
  ▼
commit → QuestPanelReading                          :610-619（confirmedCount+1、currentQID=qid :612-613）
  ▼
onConfirmed?(reading)（:566，回调声明 :489）
  ▼
AuroraDriveApp.swift:5695-5701（接线在 DriveState；⚠️ 2026-10-07 实测已漂移，原引用 5574-5580）
  ├─ questName 先比后写                              :5698
  ├─ setLocatorTarget(x:y:) —— 零转换直传 UE5 厘米    :5699 → :4414
  └─ dlog("[QUEST-OCR] …")                          :5700
```

**坐标系红线**：quest_index 的 x/y 与 `DriveState.locatorTarget` 同为世界坐标（UE5 厘米），全程不做任何换算（QuestPanelReader.swift:26-35 文件头注释；自检第 5 项 :1069-1081）。坐标等价半径是相对 Python 参考实现的有意增强（:442-449）。

**懒加载**：索引在**第一次 match 时**才加载（ensureIndex :665-676，由 match :691 调用）；任务链索引 20MB 更贵，只在**真的遇到多候选**时才加载（ensureChain :678-684，chainTried 单次尝试 :680-681）。

## 5.2 为什么 OCR 必须走后台队列 aurora.quest.ocr（实测数字）

- ROI 暖机后 n=120 实测（:521-533 注释）：`.accurate` p50 **33.6ms** / p95 40.7ms，读出 **4/4 全对**；`.fast` p50 4.2ms / p95 7.2ms，读出 **0/4 全错**。⟹ 中文 UI 文字**只能**用 `.accurate`（`.fast` 完全读不出中文，不是"慢一点但能用"的关系）；⟹ 33.6ms ≈ **一整个 30Hz 帧预算（33.3ms）**，同步跑每 0.7s 卡掉一整帧。
- 故：ROI 裁剪在主线程（微秒级，:634-642），**Vision OCR 丢到专用后台队列** `aurora.quest.ocr`（.utility，:483、:555），完成后回主线程投票+匹配（:557）。
- **绝不复用 captureQueue**：那是 SCStream 的 sampleHandlerQueue（queueDepth=3），上面做同步计算会推迟帧消费并引发雪崩——项目已有实测记录（capGap 11ms → 2081ms，:477-482 注释）。
- 并发保护：`ocrInFlight`（:486、:544、:559）——上一次没回来就不再发起，任务面板文字变化远慢于 0.7s，丢弃中间帧无信息损失。
- 语言纠错必须关（:651）：UI 文字里的专有名词会被"纠"成常用词反而错（:644-647 注释）。

## 5.3 五路匹配（exact → substr → core/coreSub → fuzzy → name）与 verdict 门槛

匹配主函数：`match(_:)` QuestPanelReader.swift:690-829。顺序执行，前面命中即短路（每路都有 `entries.isEmpty` 守卫）。

### 匹配路径表

| # | 路径 | 行号 | score | 细节 |
|---|---|---|---|---|
| ① | exact | :709-711 | 1.0 | `idx.exact[q]` 整串查表 |
| ② | substr | :716-740 | 0.95 | 双向子串（:723）；守卫：`t.count>=4`（:716，t 是 `[Unicode.Scalar]`）、key ≥4 标量（:720）、长度比 `min/max ≥ 0.5`（:724-725）；排序 ratio↓ → len(k)↓ → 字典序↓（:730-734，对齐 Python `subs.sort(reverse=True)`） |
| ③ | core / core-sub | :743-777 | core 0.9（:746）/ coreSub 0.85（:771） | coreCandidates 剥前缀（:315-347，prefixPatterns 逐字照抄 Python :287-298，长度降序稳定排序 :343-346）；core 命中后立刻尝试 core-sub：**比对对象是整条查询 t，不是候选 c**（:768；2026-10-06 bug 修复注释 :752-762——比错对象会让 core-sub 落空掉进 fuzzy 被判 low）；胜者由 `pickCoreSub` 确定性挑选（:846-856：key ⊇ query 优先 → 更长优先 → 字典序），key ≥4 标量（:766） |
| ④ | fuzzy | :780-794 | = bestR | 对 `exactKeys` 全量算 `sequenceRatio`（:782-783），≥0.62 入选（:784）；平局取字典序更大者（:785）；Ratcliff-Obershelp 递归累加实现 :353-400（b2j + find_longest_match 平局规则对齐 difflib :362-387） |
| ⑤ | name（兜底） | :800-817 | 0.8 | 双向子串 + 同 substr 守卫（查询 ≥4 :800、任务名 ≥4 :804、长度比 ≥0.5 :807-808）；2026-10-06 修复单字假阳性（注释 :797-799） |

`contains` 为标量级朴素匹配（:859-873）。所有长度计数用 `unicodeScalars.count`——**CRLF 字素簇陷阱**（文件头「坑 2」:57-61）：索引里有 4 条 key 含 CRLF（如「前往牛奶雪冰山\r\n（小队成员均达到15级）」，实测抽查），Python `len()` 按码点数 2 个字符、Swift `Character` 按字素簇算 1 个，长度比/切片/守卫会全部错位，故全程用 `Unicode.Scalar`（修掉后 5157 对向量零偏差，:61）。

### ratio 的真实语义：Ratcliff-Obershelp，不是 LCS

`sequenceRatio`（:353-400）是 `difflib.SequenceMatcher.ratio()` 的等价实现：`2 × 全部匹配块大小之和 / (len(a)+len(b))`，**递归地在左右剩余区间继续找最长匹配块并累加**——不是「最长公共子序列 ×2/总长」（文件头「坑 1」:52-55：第一版只算单个最长块，与 Python 最大偏差 0.476，348 对里错 226 对）。自检用 4 个 Python 实跑期望值逐位比对（:1119-1133）。

### verdict 门槛（统一置信判定 :820-825，对齐 Python `match_confident`）

| 条件（按顺序） | verdict | 行号 |
|---|---|---|
| entries 为空 | miss | :821 |
| 查询标量数 < minQueryLen=4（:437） | low | :822 |
| kind == .fuzzy 且 score < fuzzyConfident=0.75（:440） | low | :823 |
| 候选 >1（ambiguous 标志，各路 `e.count > 1` 时置位，如 :710/:738/:748） | ambiguous | :824 |
| 否则 | ok（唯一可寻路） | :825 |

只有 `.ok` 与「ambiguous 消歧成功」产出 QuestPanelReading；fuzzy 落在 [0.62, 0.75) 一律判 low（自检第 7 项 :1139-1143 钉死该区间）。

### 运行时常量表

| 常量 | 值 | 行号 |
|---|---|---|
| questROI | (0.030, 0.240, 0.370, 0.070) | :424 |
| voteNeed | 3 | :427 |
| minInterval | 0.7 s | :431 |
| fuzzyThreshold | 0.62 | :434 |
| minQueryLen | 4 | :437 |
| fuzzyConfident | 0.75 | :440 |
| equivalentRadiusMeters | 25.0（厘米制比较 ×100） | :449 |

## 5.4 投票缓冲与确认节奏（≈2.1s）

- 连续 `voteNeed=3` 次相同文本才确认（:580-581，常量 :427）；文本抖动即重置计数（:580 else 分支）。
- OCR 以 `minInterval=0.7s` 节流（:431、:509-511），故确认节奏 = 3 次 × 0.7s ≈ **2.1 秒**——这是「面板换任务后约两秒才更新导航目标」的来源。
- 空文本不动投票计数（:578，同 Python）；投票只在主线程做，且只存 String 不存图像（:576 注释）。
- 自检第 3 项钉死行为：第 1/2 次不确认、第 3 次确认、抖动后重新计票（:1016-1041）。

## 5.5 任务链消歧（NextQuests / 坐标等价）—— resolveAmbiguous :883-902

多候选时按顺序：

1. **链消歧 chain-next**：若有当前任务锚点 `currentQID`（commit 时写入 :613），且它的 `NextQuests` 后继里**恰好一个**在候选中 → 采用（:886-890）。
2. **坐标等价 coord-equivalent**：全部候选有坐标且距质心 ≤ `equivalentRadiusMeters × 100`（25.0m，厘米制比较 :897）→ 任取其一 entries[0]（:892-899）。这是对 Python 的有意增强：Python 链上找不到就永远等下一帧，但「下一帧」不会让同样的文字给出不同候选集（:445-448 注释：实测 346 个多候选 key 里 111 个彼此 ≤5m 该放行，235 个公里级必须拦）。
3. **否则返回 nil，等下一帧（不猜）**（:901）。

自检第 4 项：无锚点不猜、锚点 WJ101302 → 唯一后继 WJ101303、3 候选坐标相同被坐标等价放行（:1043-1066）。任务链索引来源与加载见 5.7。

## 5.6 运行时日志现状（如实查证）与最小日志方案

**现状：QuestPanelReader.swift 自身没有任何运行时日志原语。**

- 全文件的 `print(...)` 全部位于 `runSelfTest()`（--quest-selftest 自检路径）：:932、:936、:939-940、:943、:947-950、:955-1157。无 dlog / Logger / os_log。
- 运行时可观测性只有**状态字段**：`lastDiagnostic`（:496，在 :549 ROI 裁剪失败、:561 无可读文字、:589 未命中、:593 置信不足、:599 歧义未消解、:615 确认、:628 复位、:674 索引加载失败处更新）和统计计数（ocrRuns/ocrCompletions/confirmedCount/missCount/ambiguousCount，:499-503）。这些字段**自身不输出任何东西**。
- 唯一进入日志文件的路径在**调用方 App 层**：AuroraDriveApp.swift:5700 的 `dlog("[QUEST-OCR] …")`（⚠️ 2026-10-07 实测；原引用 5579），但它只在 `onConfirmed` 触发（投票达标 + verdict=ok/消歧成功）时打一行——**miss / low / 歧义未消解 / 节流跳过 / OCR 在途全部无日志**（grep 全仓库仅此一处消费 lastDiagnostic；未验证是否有其它隐性消费方）。

**最小改动方案（每 5 秒一条运行时日志：hasFrame/OCR文本/verdict/耗时），两条路线：**

- **方案 A（最小，推荐）**：全改在 QuestPanelReader.swift。① 新增常量 `logInterval = 5.0`（放 :431 旁）；② 新增状态 `lastLogTime/ocrStart/lastLines`（放 :473-475 附近）；③ 在 `ingest(cgImage:)` 记 `ocrStart`（:542-552 之间），在 `DispatchQueue.main.async` 回调里（:557-568，lines/ocrCompletions 都在手）做 5s 节流输出。注意 :560-563 空文本 early-return 分支也要记，否则丢 verdict=nil 情形。输出原语二选一：直接 `print`（与 YoloEngine.swift:214、YolopxEngine.swift:791 的 `[warmup]`/`[yolopx]` 前缀同款），或仿 `onConfirmed`（:489）加 `var onLog: ((String) -> Void)?` 由 App 层接 dlog 落 `/tmp/aurora_debug.log`。局限：只打印真实发起的 OCR（≥0.7s 一次），被节流跳过的帧不打印（本来也无 OCR 信息）。
- **方案 B（零改 QuestPanelReader）**：在 AuroraDriveApp.swift:6556-6558 喂帧点外包 5s 节流打印（仿 lastTickLog 1Hz 节流模式，AuroraDriveApp.swift:4770 声明 / :7192-7193 使用；⚠️ 2026-10-07 实测，原引用 6435-6438 与 4648-4649），输出 `currentFrameCG != nil` + `questPanel.lastDiagnostic` + `questPanel.lastMatch?.verdict`。局限：拿不到**本次 OCR 耗时**（:499-503 统计里没有耗时字段），OCR 文本只能从 `lastMatch?.query`（:134/:828）间接拿，且 miss/low 的 query 是清洗后文本而非原始 OCR 行。若「耗时」是硬需求，只能走方案 A。

## 5.7 models/quest_index.json：磁盘结构、加载与内存形态

**磁盘结构（2026-10-06 python3 实测，文件 2,693,278 字节 ≈ 2.57MB）**：顶层键 `version(=1) / source / stats / exact / core / byname`。stats = `{files:39, objectives:3819, with_coord:2938, with_desc:3086, exact_keys:1372, core_keys:1984, name_keys:1128}`（与文件头注释 :10-11「39 张表 / 1372 精确文本 / 2938 带坐标」一致）。exact/core/byname 均为 `key → [entry]`，entry 字段 = `qid/quest/desc/otype/x/y/z/force/src`（实测示例：「『渣土车』驾驶车辆至指定点位」→ qid=C101007、x=-192934.36 等 6 个候选）。

**加载**：`QuestIndex.load(url:)` QuestPanelReader.swift:213-249。

- `Data(contentsOf:)` + `JSONSerialization`（:214-216），非 Codable，手工解析。
- `parse(_:)`（:218-237）：每个 entry 只读 `qid/quest/desc/x/y/z` 六个字段（:228-232）；磁盘里的 `otype/force/src` **被丢弃**（本文件内确实不读；未验证是否有其他读取方）。
- 缺坐标条目已在生成期过滤，但 x/y 仍可各自缺失 → QuestEntry 三个坐标均为可选（:90-103，worldTarget 要求 x、y 同时存在 :98-102）。
- `stats` 解析为 `[String: Int]`（:240-243），仅自检打印用（:947-949）。

**内存结构** `QuestIndex`（:201-211）：`exact/core/byname: [String: [QuestEntry]]` 三张查表 + 三个**排序后**的 key 数组 `exactKeys/coreKeys/bynameKeys`（:244-248）。排序数组的存在理由：Swift 字典迭代序每进程随机（哈希随机化），凡「遍历全部 key」的分支（substr :718、fuzzy :782、name :802）都走排序数组保证确定性（:205-210 注释）。

**加载时机**：懒加载。ensureIndex（:665-676）在第一次 `match()` 时调用（:691），路径 `AuroraPaths.projectRoot() + models/quest_index.json`（:668）；加载失败置 `indexLoadFailed` 后不再重试（:667、:673，并写 lastDiagnostic :674）。

**任务链 QuestChainIndex**（:155-196）：扫描 `tools/nte_datatables/**/DT_Quest*.json`（实测 32 文件 / 约 19MB，:153-154 注释写 20MB），抽取 `qid → NextQuests[]`（:180-183）与 `qid → ChapterProgress`（:184），兼容 `{Rows:{…}}` 与 `[{Rows:{…}}]` 两种壳（:172-175）。懒加载一次（ensureChain :678-684，chainTried 单次尝试），只在 ambiguous 消歧（:886）时才付磁盘成本。

## 5.8 自检与开关

- 自检入口 `--quest-selftest`（runSelfTest :928-1159）：8 条真实面板文字回归（5 ok/2 ambiguous/1 low，:916-925；可寻路 6/8 :988）、反向假阳性用例（:993-1013）、投票（:1016-1041）、链消歧+坐标等价（:1043-1066）、坐标零换算（:1069-1081）、ROI+提示行过滤（:1084-1109）、fuzzy 阈值区间 [0.62,0.75) 判 low（:1139-1143）、节流（:1146-1154）。退出码 = 失败项数。
- 开关：`AuroraFlags.questOCR`（AuroraFlags.swift:201）默认 **true**（:193-199 注释：2026-10-06 应用户要求改默认开）。⚠️ 元数据滞后：同文件 :445 的 flag 注册表 summary 仍写「默认关」，AuroraDriveApp.swift **:6549** 的调用点注释也写「默认关：AURORA_QUEST_OCR=1 打开」（⚠️ 2026-10-07 实测；原文引用的 :5497 与 :6428 已随文件增长漂移到无关代码）——行为以 AuroraFlags.swift:201 为准（代码层面确认，运行时行为未验证）。

### 相邻 OCR/检测文件速览（非重点，仅定位）

- **SpeedOCRReader.swift**（1540 行）：@MainActor @Observable（:47-50）；PP-OCRv6 整行主路径 + per-digit CNN 备用（文件头 :3-20）；PP-OCR 故障同帧自动降级并写 engineNotice（:11-13）；CTC 解码 :1063；后台 ocrQueue + generation 计数防过期（:199-205）。详见代码-12。
- **YoloEngine.swift**（843 行）：输入 640×640、整帧非等比拉伸不 letterbox（:20-21、:42-44、:707-709）；COCO 标签映射 :805-807。
- **YolopxEngine.swift**（1666 行）：YOLOPv2 族（PerceptionModelFamily :173，PerceptionMode 档位 :203）；MaskGrid :45 / LetterboxMetrics :93；det 后处理 :1103、掩码提取 :1246。

---

# 九、2026-10-07 补记：另一条 OCR/推理链路 —— AI 助手（与任务面板 OCR 完全独立）

> 本节只补 **10-07 那批 AI 助手施工**（`git log` 实测：`2c0459a` / `d9675ab` / `db0ce81` / `22a6604`）里与「推理 / OCR」相关的部分。
> **不推翻上文**：上半部分（InferenceEngine、QuestPanelReader）在 10-07 期间**未被改动**——
> `git diff --stat HEAD~5..HEAD -- Sources/AuroraDrive/Inference/` **输出为空**，
> `wc -l` 实测 `InferenceEngine.swift` 仍 **522 行**、`QuestPanelReader.swift` 仍 **1160 行**，
> 与上文口径**完全一致**（含文中所有 10-06 修复注释）。
>
> **本节行号为 2026-10-07 `grep -n` 实测**（`AgentChatService.swift` 618 行 / `LLMTransport.swift` 1580 行 / `LLMHealth.swift` 1791 行）。

## 9.0 上文 App 层行号漂移修正（2026-10-07 实测）

上文对 `QuestPanelReader`（1160 行）**自身**的行号引用**全部仍然有效**（该文件本次未改动，逐条复核一致）。但上文引用的 **`AuroraDriveApp.swift` 行号已漂移**——该文件在 `2c0459a`（AI 助手施工）里 +122 行，插在上文引用的位置**之前**。逐条实测校正如下（**上文原处已就地改写，此处留档**）：

| 上文原引用 | 2026-10-07 实测 | 现在指向什么 |
|---|---|---|
| `AuroraDriveApp.swift:6435-6438` 喂帧点 | **:6549-6557**（`if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }` 在 **:6556-6558**） | ✅ 同一处逻辑，只是整体下移 |
| `AuroraDriveApp.swift:5574-5580` onConfirmed 接线 | **:5695-5701** | ✅ 同一处逻辑 |
| `dlog("[QUEST-OCR] …")` :5579 | **:5700** | ✅ 同一行 |
| `setLocatorTarget(x:y:)` :4293 | **:4414** | ✅ 同一函数（单行实现） |
| 「默认关」注释 :5497 与 :6428 | **:6549**（仅此一处仍写「默认关」；原 :5497 / :6428 处现已是**光流开关**与**自检钩子**的无关注释） | ⚠️ 上文说「两处注释都写默认关」——**现在只剩一处** |
| `lastTickLog` 节流模式 :4648-4649 | 声明 **:4770** / 使用 **:7192-7193** | ✅ 同一机制 |

> **教训（给后来者）**：`AuroraDriveApp.swift` 是 7000+ 行的巨型文件，**每次有人改动都会让它下游的行号全部失效**。引用它的行号时，务必与「引用时刻的 commit」绑定；只引用 `QuestPanelReader.swift` / `InferenceEngine.swift` 这类**小且稳定**的文件行号才是安全做法。

## 9.1 关键结论：这是**两条互不相干**的链路

AuroraDrive 里存在**两条**「截图 → 得到结构化信息」的链路，它们**不共享任何代码**，唯一的共同点是「都会调 Vision / 都会调远端模型」：

| | **① 任务面板 OCR 链路** | **② AI 助手链路** |
|---|---|---|
| 入口 | `QuestPanelReader.ingest(cgImage:)` | `AgentSkillCenter.sendChatMessage` |
| 触发 | 30Hz tick 里按 **0.7s 节流**自动跑（无需用户操作） | **用户打字**才发起（或 AI 自主调工具） |
| 看图方式 | **本地 Vision OCR**（`VNRecognizeTextRequest`，`.accurate`） | **把图片发给远端多模态 LLM** |
| 识别对象 | 固定 ROI `questROI=(0.030, 0.240, 0.370, 0.070)` 的任务面板文字 | 整帧（可开关），人/模型自己看 |
| 中间层 | `quest_index.json` 五路匹配 → verdict | 无本地索引，模型自由生成 |
| 出口 | `setLocatorTarget(x:y:)`（UE5 厘米，**零换算**） | 文本回复 + **工具调用**（键鼠真实注入） |
| 网络 | **零网络**（纯本地） | 需网络（**8** 渠道候选链）⚠️ 2026-10-07 D6b 校正：原写「7 渠道」，`LLMBackendKind` 实测 8 个 case |
| 延迟量级 | p50 **33.6ms**（本地，仍必须丢后台队列） | 秒级（远端流式） |
| 开关 | `AuroraFlags.questOCR`（AuroraFlags.swift:201，默认 true） | `AgentSettings.visionEnabled`（默认 **false**，隐私优先） |
| 文档 | 本篇第五单元（上文） | **本节** |

**为什么必须写清「两条」**：两者都会「OCR / 看图」，容易被后来者误认为同一条流水线——例如以为 AI 助手能看到任务面板文字是因为 QuestPanelReader 跑了。**事实是相反的**：AI 助手想「看到」任务面板，只能靠 `screenshot` 工具或 📷 视觉开关**把整帧图发给远端模型**，它**读不到** QuestPanelReader 的 `lastMatch` / `lastDiagnostic`（那两者之间**没有任何数据通道**，grep 实测全仓无引用）。

**唯一的「间接血缘」**：两条链路都遵守同一条**性能红线**——`QuestPanelReader` 实测 Vision OCR p50 33.6ms ≈ 一整个 30Hz 帧预算，因此**网络、SSE 解析、图片编码、历史裁剪绝不允许碰主线程**。`AgentChatService.swift:27-31` 的注释原文就是拿这个 33.6ms 数字当依据的。**这是设计上的传承，不是运行时的耦合。**

## 9.2 AgentChatService.swift（618 行）—— 聊天编排 actor

**定位**（`AgentChatService.swift:4-32` 头注释）：面板要的是「用户说一句 → 边收边显示 → 得到最终文本」，而底下是「候选链 × 传输层 × 健康监控」的分布式状态。把这层编排独立成 **`actor`**（`:97`）有三个好处：① UI 不必知道候选/降级/错误分类细节；② 编排逻辑可被 CLI 自检复用（`--llm-selftest` 与面板走**同一条路径**）；③ 网络与解析全留在 actor 内，**绝不碰主线程**。

**修掉的病根**（`:16-19`）：改造前 `sendUserMessage` 的自由文本分支走 `localReply()` 硬编码套话，真正的模型问答函数 `plainAnswer` 写好了却**从未被生产路径调用**。本文件就是那条缺失的生产路径。

**常量表（`:105-122` 实测）**：

| 常量 | 值 | 行号 | 含义 |
|---|---|---|---|
| `maxHistoryTurns` | **12** | `:107` | 历史最多保留轮数（防 token 爆炸），超出直接丢弃 |
| `maxCandidatesPerRequest` | **4** | `:111` | 降级链最多尝试候选数——**4 是权衡值**：免费档限流时要给活路，但一次对话拖成十几次往返不可接受（且触发更多限流） |
| `deltaThrottleInterval` | **1/15 s ≈ 66ms** | `:118` | 流式增量回调最小间隔（15Hz），避免 SwiftUI 每 token 重绘 |
| `requestTimeout` | **30s** | `:122` | **空闲**超时语义（两包之间的最大间隔），不会把流式长回答腰斩 |
| `systemPrompt` | 约 220 行字符串 | `:151-372` | 唯一提示词来源，见代码-23 §十 |

**主入口 `reply(text:history:image:onDelta:)`（`:397` 起）** 的执行序：

1. **空输入短路** → `.failure(reason: "空输入")`（`:403`）
2. **候选链**：`candidates(requireVision:)`（`:377`）→ 转调 `LLMHealthMonitor.shared.candidates(preferred:requireVision:requireTools: true)`（`:379-382`），**始终要求模型支持工具**；空链 → 如实失败（视觉/纯文本两种文案，`:410-416`）
3. **消息组装**：`buildMessages(history:userText:image:)`（`:555`）—— system 提示 + 裁剪后历史 + 本轮；**历史裁剪在 `:562-564`**：先过滤空文本轮次，再 `.suffix(maxHistoryTurns)`
4. **逐个候选尝试**（`:426`，上限 `min(4, chain.count)`）：
   - 需 key 渠道但用户没配 key → **`continue` 跳过，不消耗一次往返**（`:431`）
   - 构造 `LLMRequest` 时 **`tools: nil`**（`:448`，注释原文：*聊天路径不带工具（工具调度走 AgentLoop）*）——**这是两条 AI 路径的分界点**：面板聊天**不带** function calling，要调工具走 `AgentLoop`
   - 空正文且无推理内容 → **视为该候选失败**（`:464-470`，注释：实测 `space-bunny-free` 会返回空串）
   - 成功 → `noteSuccess` 记账 + 返回 `ChatReply`（含实际 `model` / `backend` / `viaFallback = index > 0` / `attemptedCandidates`）
   - `CancellationError` → 直接返回「已取消」，**不再尝试后续候选**（`:483-484`）
5. **全链失败不抛错给 UI**：返回 `text=""` + `errorMessage`（`:492`），由面板决定回退 `localReply` 并标注「离线回复」（`:24-25` 注释、代码-23 §十一）

**`consumeStream`（`:503`）—— 流事件只有 4 个 case**（`:499` 注释实测）：`delta` / `reasoning` / `toolCall` / `done`。
- `delta` 累积文本，**距上次回调 ≥66ms 才 `onDelta(text)`**（`:519-522`），且**传全量**而非增量——调用方直接覆盖显示，天然幂等
- **收尾必补发一次**（`:534`），否则最后一段（仍在节流窗口内）会丢
- `done` **一次性带回完整 `LLMCompletion`**，以其为准；但若 `done.text` 为空而流里攒到了文本，**用攒的**（`:536-546`，注释：部分渠道 done 只给 usage 不给全文）
- `toolCall` 在聊天路径 **`break` 不消费**（`:525-527`）

**渠道参数三函数（`:579-609`）**：`baseURL` / `apiKey` / `extraHeaders` —— 注释明写「与 W7/AgentLoop 同一套规则，**避免两处漂移**」。免 key 渠道的 `apiKey` 返回 `nil`（**Zen 的 `Bearer public` 走 extraHeaders**，`:591`）；`temperature(depth)` 四档表 0.9 / 0.5 / 0.2 / 0.05（`:602-609`）。

## 9.3 LLMTransport.swift（1580 行）—— 传输层三件事

**① SSE 流式**：`stream(_:) -> AsyncThrowingStream<LLMStreamEvent, Error>`（协议声明 `:528`，具体实现 `:1286`）。

**② 图片编码 `LLMImageEncoder`（`:917` 起）—— 三档硬门限**：

| 门限 | 值 | 行号 |
|---|---|---|
| 长边上限 | **1568 px** | `:929` |
| JPEG 质量 | **0.8** | `:931` |
| 压缩后字节上限 | **2,000,000**（超 → 明确报错，**不硬发**） | `:933`、`:1031-1036` |

- **实测依据（`:918-921` 注释，出自 task-2 第 7 条）**：762KB base64 的截图实测可用；**2940×1912 原图（未压缩）约 8MB，发给上游会超限被拒**——所以发送前一律缩放 + JPEG 0.8。
- `encode(data:)` 的短路优化（`:1013-1015`）：**输入本来就是 JPEG 且尺寸在门限内 → 原样返回，不重编码**（避免二次压缩损失）。
- 输入收敛范围（`:917-918`）：CGImage / PNG / JPEG / base64 / data URL / **HTML 错误页** / http URL 全部收敛成合规 `LLMImage`。
- **线程约定（`:924-925`）**：全部是**纯 CPU 函数**（除 `prepare(urlString:)` 会同步下载），**调用方必须在后台上下文**——`prepare(urlString:)` **禁止在主线程**。

**③ 12 类错误分类 `LLMErrorKind`（`:62-87`，枚举名 `String` 已冻结）**：

| # | case | 语义（源码注释口径） |
|---|---|---|
| 1 | `missingKey` | 本地校验失败：需 key 的渠道没给 key（**根本没发请求**） |
| 2 | `invalidKey` | 401：key 无效/过期（**配置问题，不是模型问题**） |
| 3 | `rateLimited` | 429：限流（可能带 `Retry-After`） |
| 4 | `gated` | 免费档门禁（上游 FreeTierError）：容量池可能恢复，**冷却后重试** |
| 5 | `regionBlocked` | 地区封锁（上游 RegionError）：**换网络才会变，本会话内不必重探** |
| 6 | `modelDeprecated` | 模型下线（上游给了 `replacement`）→ **可切模型** |
| 7 | `modelNotFound` | 模型不存在/下线且**无替代**（404） |
| 8 | `upstream` | 上游服务端错误（HTTP 5xx / `server_error`） |
| 9 | `timeout` | 超时（`URLError.timedOut`）；**对流式是「空闲」超时语义** |
| 10 | `network` | 网络层失败（DNS / 不可达 / 连接中断） |
| 11 | `badResponse` | **HTTP 成功但响应结构不可用**（含实测的 200 + 空 content） |
| 12 | `cancelled` | `Task.cancel`（用户取消）——**不是模型问题，不要记账、不要换候选** |

**分类的用途**：`LLMHealthMonitor.noteFailure` 按 `LLMError.kind` **逐条分派状态**（`:60-61` 注释）——这是「12 类」存在的意义：不同错误对应不同处置（换模型 / 冷却 / 不重探 / 不记账）。`LLMError` 另带诊断字段：`retryAfter` / `replacementModel` / `httpStatus` / 上游 `error.type`（`:89-100`）。

## 9.4 LLMHealth.swift（1791 行）—— 探活、候选链、熔断、双层缓存

**定位**：`actor LLMHealthMonitor`（`:295`），提供「哪些模型现在能用」的单一事实来源。

| 机制 | 常量 / 入口 | 行号 |
|---|---|---|
| 自适应探活 | `probeAll(force:includeWholeCatalog:)` | `:436` |
| 空闲单探 | `probeCurrentIfIdle(force:)`——每 `probeInterval`（默认 **60s**）**只探当前模型**，失效才全量重探 | `:570`、`:546` |
| 候选链聚合 | `candidates(preferred:requireVision:requireTools:)` | `:840` |
| 成功记账 | `noteSuccess(_:latencyMs:)` | `:671` |
| 失败记账（按 12 类分派） | `noteFailure(_:error:)` | `:694` |
| **熔断** | 连续失败 **3** 次 → 冷却 **300s** | `:330-331`、`:819-823` |
| 磁盘缓存 | `llm-health-cache.json`，**7 天**过期 → 过期即当空 | `:327`、`:1377` |
| 设置缓存 | `AgentSettings` 缓存 **2s** TTL（`invalidateSettingsCache()` 可主动失效） | `:395`、`:1442-1454` |

- **熔断开闸的日志是显式的**（`:822`）：`NSLog("[LLMHealth] 熔断 <key>：连续 N 次失败（reason），冷却 300s")` —— 出问题时可直接在系统日志里定位。
- 熔断判定独立成函数（`:1541`）：`consecutiveFailures >= circuitBreakerThreshold`。
- **候选链是「降级链」的供给方**：`AgentChatService` 只取前 4 个，因为链本身把所有可达渠道按健康度排好了序。

## 9.5 与 10-07 其余改动的接口（交叉引用）

本节写的三条链路层文件**只被 AI 助手使用**，与驾驶链路（InferenceEngine / YoloEngine）**无调用关系**。10-07 其余改动分别记录在：

- **F1–F12 从工具面排除**、**会话滑动窗口**、**提示词异环定制** → 见 **代码-23 §九/§十/§十一**
- **`ControlEngine.GameKey` 键码表 35/38 项修复**（ASCII 码误当 CGKeyCode）→ 见 **代码-08**（本次 AI 自主按键暴露的既存缺陷）
- **SpeedOCRReader 本次是否改动** → 见 **代码-12** 末节（结论：**未改动**）

**补记完 · 2026-10-07**