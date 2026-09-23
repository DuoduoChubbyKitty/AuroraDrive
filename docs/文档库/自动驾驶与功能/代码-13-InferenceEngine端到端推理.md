# 代码-13 InferenceEngine 端到端推理

> 覆盖源文件：`Sources/AuroraDrive/Inference/InferenceEngine.swift`（432 行）。基于当前仓库逐单元编写。

## 一、模型接口、状态与双缓冲（第 1–135 行）

**定位（4–24 行头注释）**：CoreML E2E 推理引擎——加载 m9_mono.mlpackage，把**截屏画面 + 车辆状态 → steer/throttle/brake**。

**模型接口（9–15 行注释，来自 tools/export_game_assist_coreml.py 与 src/model.py）：**

| 张量 | 形状 | 类型/范围 |
|---|---|---|
| 输入 `image` | `[1, 3, 180, 320]` | Float32, CHW, 归一化 [0,1] |
| 输入 `vehicle_state` | `[1, 6]` | Float32 |
| 输出 `steer` | `[1]` | **tanh** ∈ [-1, 1] |
| 输出 `throttle` | `[1]` | **sigmoid** ∈ [0, 1] |
| 输出 `brake` | `[1]` | **sigmoid** ∈ [0, 1] |

vehicle_state 6 维 = `[speed, rpm, gear, speed_norm, gear_norm, reserved]`（原始导出注释口径；**实际喂的契约见单元三的 buildVehicleState**——两者不同！头注释是导出脚本口径，运行时已改为训练契约 v2_new）。

**四个设计要点（源注释原文）**：① 异步推理——后台队列跑，不阻塞主线程 tick；② 频率解耦——tick 30Hz 调用，推理约 24Hz，结果缓存供 tick 读最新值；③ 线程安全——预处理/推理用 nonisolated 静态函数，无 self 捕获，MLMultiArray/MLModel 非 Sendable 但单线程访问安全；④ 车辆状态——游戏状态读取未接入前，speed 用 DriveState.speed 估算，rpm/gear 用启发式占位。

**类声明（第 48–50 行）**：`@Observable @MainActor final class InferenceEngine`。

**模型参数与状态（第 52–122 行）：**

| 成员 | 说明 |
|---|---|
| `inputHeight = 180` / `inputWidth = 320`（static） | 输入图像尺寸 H×W（模型训练时的分辨率） |
| `stateDim = 6`（private nonisolated static） | vehicle_state 维度（编译期常量，无 actor 依赖） |
| `isLoaded`（private(set)） | 是否已加载模型（启动时 lazy 加载） |
| `isInferencing`（private(set)） | 是否正在推理中（防止重叠推理） |
| `lastResult: InferenceResult?`（private(set)） | 最新推理结果（tick 读取此值） |
| `lastResultTime: Date?`（private(set)） | 最近一次成功推理的时间戳（**判结果新鲜度：链路是否真的活着**） |
| `inferenceCount`（private(set)） | 累计推理次数（性能监控） |
| `errorMessage: String?`（private(set)） | 加载/推理错误信息（UI 展示用） |
| `lastLoadAttempt: Date`（@ObservationIgnored） | P0-4 修复：上次加载尝试时间戳（**失败冷却用**） |
| `loadRetryCooldown: TimeInterval = 5.0` | 加载失败冷却时长（秒） |
| `generation`（@ObservationIgnored） | P1 修复：**reloadModel()/reset() 时递增；在途推理完成后比对，不匹配则丢弃过期结果**，防 reset/reload 后旧在途结果写回 lastResult |
| `model: MLModel?`（@ObservationIgnored + **nonisolated(unsafe)**） | CoreML 模型实例——MLModel.prediction 内部线程安全，可跨队列调用；不参与 SwiftUI 观察 |
| `inferenceQueue` | 后台推理队列（**串行**，保证推理不重叠；`com.aurora.inference`, .userInteractive） |
| `reusableImageBuffer / reusableStateBuffer`（nonisolated(unsafe)） | P1 修复：**可复用的推理输入缓冲**（image 1×3×180×320 ≈691KB + state 1×6），尺寸不变时复用，避免每帧新建 MLMultiArray；只在串行 inferenceQueue 上创建与读写，isInferencing 防重叠保证无并发访问 |
| `modelFileName`（private let） | 本引擎加载的模型文件名（不带扩展名） |

**`init(modelFileName: String = "m9_mono")`（第 120–122 行）**：

- 默认 `"m9_mono"` 端到端主驾；**`"game_assist_control"` 为第二套驾驶模型（YOLO 接管档的司机）**
- init 只记文件名——**模型 lazy 加载**（首次 infer 经 loadIfNeeded），启动不卡顿

**`modelURL`（计算属性，第 127–135 行）**：`AuroraPaths.projectRoot() + models + "\(modelFileName)"`；**优先加载训练产出的编译模型 `<name>.mlmodelc`**（.mlmodelc 为 coremlcompiler 编译产物），**回退到历史未编译的 `<name>.mlpackage`**——保证「训练完一键热替换」生效。

**`InferenceResult`（struct，第 34–40 行）**：`steer / throttle / brake / latencyMs`——单次推理输出（**与 ControlCommand 兼容**）；latencyMs 推理耗时（毫秒）用于性能监控；标记 `Sendable`（跨 actor 传递）。

## 二、loadIfNeeded / warmUp / reloadModel（第 137–201 行）

**`loadIfNeeded()`（第 142–160 行）**——加载 CoreML 模型（首次推理前 lazy 调用）：

```swift
guard !isLoaded else { return }
// P0-4 修复：失败后冷却期内不再重试，避免主线程同步 MLModel() 30Hz 重试风暴
guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
lastLoadAttempt = Date()
```

- **P0-4 修复**：失败后 5 秒冷却期内不再重试——避免主线程同步 `MLModel()` 30Hz **重试风暴**（模型文件缺失时每帧同步 IO）
- `MLModelConfiguration` + `config.computeUnits = .all`——**自动选 ANE/GPU/CPU，优先 ANE**
- `try MLModel(contentsOf: modelURL, configuration: config)` 成功 → `isLoaded = true`、errorMessage = nil、**环3：后台跑一次 dummy prediction 预热 ANE**
- 失败 → `errorMessage = "模型加载失败: ..."`、isLoaded = false

**`warmUp(model:label:queue:)`（private nonisolated static，第 164–190 行）**——模型预热（环3）：

- **后台队列跑一次 dummy prediction，把 ANE 计算图编译/内存分配提前做完，避免首帧真实推理出现冷启动尖峰**（162–163 行注释）。全零输入即可（数据内容不影响预热）
- 构造：`MLMultiArray(shape: [1, 3, h, w], .float32)` + `MLMultiArray(shape: [1, 6], .float32)` → `MLDictionaryFeatureProvider(["image": ..., "vehicle_state": ...])`
- 成功打印 `[warmup] <label> 预热完成: Xms computeUnits=all`；失败打印原因（不阻塞）

**`reloadModel()`（第 195–201 行）**——训练完成后热替换模型：

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

## 三、infer() 推理流程与 readScalar（第 203–306 行）

**`infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double)`（第 211–291 行）**——异步推理主线程入口：

1. `guard isLoaded, let modelRef = model else { loadIfNeeded(); return }`——未加载时 lazy 触发
2. `guard !isInferencing else { return }`——**防重叠：上一帧还没跑完就跳过**
3. `isInferencing = true`；**CGImage 不可变，可安全跨线程**（环2 由 CaptureEngine 直传，省 NSImage→CGImage 转换）；快照 `gen = generation`
4. `inferenceQueue.async { [weak self] in ... }`（后台串行队列）：

**① 预处理 + 车辆状态构造（228–247 行）**：

- **P1 修复：复用输入缓冲**——`reusableImageBuffer`/`reusableStateBuffer` 为 nil 时才新建（image ≈691KB），尺寸不变时复用
- `Self.preprocessImage(image, height: h, width: w, into: self.reusableImageBuffer)` + `Self.buildVehicleState(speedKmh:speedLimitKmh:into: self.reusableStateBuffer)`——**nonisolated 静态函数，无 actor 依赖**
- 任一失败 → `Task { @MainActor in self.finishInference(gen, nil, error: "预处理失败") }`

**② CoreML 输入构造（249–257 行）**：`MLFeatureValue(multiArray:)` 是 **non-throwing 初始化器**直接构造——`imageFeature` + `stateFeature` → `inputDict: ["image": ..., "vehicle_state": ...]`。

**③ 同步推理（259–263 行）**：`try MLDictionaryFeatureProvider(dictionary: inputDict)` → `try modelRef.prediction(from: provider)`——已在后台队列，不阻塞主线程；MLModel.prediction 内部线程安全。

**④ 输出解析（265–286 行）——readScalar 关键坑：**

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

⚠️ **源注释（266–269 行）**：CoreML 输出是 `MLMultiArray(shape [1,1])`，**必须用 `multiArrayValue[[0,0]].doubleValue` 读取。直接用 `featureValue(for:)?.doubleValue` 对 multiArray 类型会返回 0**，导致 e2eCommand 恒为 idle（**端到端主驾完全不决策的元凶**）。

- `latency = Date().timeIntervalSince(start) * 1000` → `InferenceResult(...)` → `Task { @MainActor in self.finishInference(gen, result, error: nil) }`
- 推理异常 → `finishInference(gen, nil, error: "推理失败: ...")`

**`finishInference(_ gen:result:error:)`（private，第 295–306 行）**：

- **`guard gen == generation else { return }`**——reset()/reloadModel() 后在途结果过期，丢弃（与 SpeedOCRReader.finish 同机制）
- `isInferencing = false`
- result 非空 → `lastResult = result` + `lastResultTime = Date()` + `inferenceCount += 1`
- error 非空 → `errorMessage = error`

**线程安全小结**：预处理/推理全在后台串行队列（nonisolated 静态函数 + reusable 缓冲）；结果写回经 Task @MainActor；generation 防过期——三重保证"结果要么是新鲜的，要么被丢弃"。

## 四、buildVehicleState 训练契约与 preprocessImage（第 308–432 行）

**`buildVehicleState(speedKmh:speedLimitKmh:into:) -> MLMultiArray?`（private nonisolated static，第 322–348 行）**——构造 vehicle_state 6 维向量。**⚠️ 本单元是整个推理引擎最重要的契约（311–321 行注释）：**

```
与训练契约一致（src/mono_dataset.py v2_new 格式）：
  [speed_norm, curvature*5, sin(heading), cos(heading), speed_limit_norm, 0]
之前喂的是启发式 [speed原始值, rpm(800~8000), gear(1~6), ...]，
前三维超出训练分布 60~8000 倍 → 模型收到垃圾状态 → 恒输出 steer=-1/throttle=1
（已用真实帧 + 训练权重逐组验证：正确契约 steer≈-0.04/throttle≈0.99）
```

- **头注释里的 [speed, rpm, gear, ...] 口径是导出脚本的历史口径，运行时已改为上面的训练契约**——换模型/换训练版本时两边必须同步
- **游戏遥测未接入前的占位**：`speed_norm = speed/120`、`curvature*5 = 0`（取训练分布内零值）、`sin/cos(heading) = 0/1`（等价 heading=0）、`speed_limit_norm = speedLimit/120`、`reserved = 0`
- **P1 修复**：复用传入的 state 缓冲（尺寸 1×6 不变），避免每帧新建 MLMultiArray——复用前校验 shape（`[1, 6]`），不匹配才新建
- 归一化：`max(0.0, min(1.0, speedKmh / 120.0))`——120 是训练时的速度归一化基准

**`preprocessImage(_ cgImage:height:width:into:) -> MLMultiArray?`（private nonisolated static，第 355–420 行）**——CGImage → MLMultiArray [1, 3, H, W] Float32 CHW 归一化 [0,1]：

1. **缩放绘制**：CGContext（DeviceRGB + premultipliedLast）+ `interpolationQuality = .high` + `ctx.draw` 到 180×320——RGBA 像素读入 pixelData
2. **复用 image 缓冲（377–393 行，P1 修复）**：shape 校验（[1, 3, H, W]）通过则复用，否则新建（每帧 ≈691KB 的分配）
3. **RGBA → CHW 重排（398–410 行）**：三平面布局，`[0,c,y,x] = outputPtr[c*planeSize + y*width + x]`——**先写原始 0~255 值，保留与旧双循环完全一致的通道顺序与布局（R/G/B 三平面）**
4. **一次性向量化归一化（412–417 行）**：`vDSP_vsdiv(outputPtr, 1, &divisor, outputPtr, 1, vDSP_Length(3 * planeSize))` 整块除以 255 → [0,1]——源注释：**vDSP_vsdiv 与逐像素 Float32(x)/255.0 同为 IEEE Float 除法，位级一致；只把除法移出 CHW 双循环，通道顺序/布局不动，训练契约不变**

**`reset()`（第 425–431 行）**——重置（停止驾驶时调用）：`generation += 1`（在途推理结果过期）、lastResult = nil、lastResultTime = nil、isInferencing = false、errorMessage = nil。**注意 reset 不清 reusable 缓冲**（尺寸不变可继续复用，内容下次推理覆写）。

**InferenceEngine 文档至此完整**（432 行全覆盖：模型接口 → 加载与热替换 → infer 流程 → 训练契约与预处理）。给别的 AI 的最关键提示：**vehicle_state 必须喂训练契约 v2_new 格式**（喂启发式 rpm/gear 会让模型恒输出 steer=-1/throttle=1），**CoreML 标量输出必须按 [0,0] 下标读**。