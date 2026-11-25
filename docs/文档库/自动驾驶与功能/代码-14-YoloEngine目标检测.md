# 代码-14 YoloEngine 目标检测
> 覆盖源文件：`Sources/AuroraDrive/Inference/YoloEngine.swift`。基于当前仓库逐单元编写。
>
> **引用纪律（本篇已重写为名字锚点）**：不再用「文件:行号」定位——行号随提交漂移，实测已大面积失真。本篇所有代码位置一律引用源码里**真实存在的名字**（类型/函数/属性/常量/枚举 case/环境变量）。行号指向内容已删除或改名的，已按当前代码重写该句。

---

## ⚠️⚠️ 2026-10-19 档位语义变更（本节为当前唯一权威口径，优先于下文所有「26S 是检测主路径」的表述）

> **用户拍板**（goal-3279b59b 需求 1/6/7）：A 模型档（`.ayolom`，**默认档**）下
> yolo26s **不加载、不推理**；只有 legacy 三件套档才加载并跑 26S。
> 用户原话逻辑：A 模型档的设计原话（`PerceptionMode` 的 `.ayolom` 注释）是
> 「**只跑 A-YOLOM(n) int8 一个三合一模型**」——26S 只属于 legacy 档，
> 却常驻 9.2MB 权重 + 每两帧 p50 6.2~14ms 推理，且 `computeUnits = .all`
> 会把算子派 GPU 与游戏抢卡（用户实测：裸游戏流畅、开 App 持续卡、GPU 恒 100%）。

**本篇行文口径的相应变化**：下文凡把 yolo26s 说成「检测主路径 / 与 yolopx 并列的第三条腿」的地方，
**只在 legacy 三件套档成立**。A 模型档（默认）下：

| 环节 | A 模型档（ayolom，默认） | legacy 三件套档 |
|---|---|---|
| 26S 加载 | **不加载**（开机由 `selectPerceptionMode` 按档位装卸，卸载走 `YoloEngine.unload()`） | 加载 |
| 26S 推理 | **不推理**（`detectGateB` 档位门，判据含 `forceYolo26s || perceptionMode == .legacy`） | 奇数帧 |
| 检测框来源 | yolopx（ayolom 小模型，每帧真值） | yolopx 偶数帧 + 26S 奇数帧错开 |
| 本文件 `loadIfNeeded()` 的行为 | 调用点已被档位门挡住；若误调会真的加载 | 正常加载 |

**回退开关**：`AURORA_FORCE_YOLO26S=1` → A 模型档也常驻加载并跑 26S（完全回到 2026-10-19 之前），供排查对照。
UI 侧读取方是 `DriveState.forceYolo26s`（转调 `AuroraFlags.forceYolo26s`）。
**引擎进程侧**：`EngineMain` 用同名环境变量实现同款语义（`EngineMain.needsYoloThrough` 档位门 + `CaptureEngine.isYoloWanted` 判据）。

---

## ✅ 2026-10-18 复核（本次改了什么）

> 复核人：infer-reader · 方法：逐条 `read` 源码核对语义（不只查行号存在）· **只改文档，未动 Sources/**

| # | 问题 | 修订内容 |
|---|---|---|
| R1 | **`iouThreshold` 被写成「NMS 的 IoU 阈值」，实为死代码** | 本引擎 `var iouThreshold: Double = 0.45` 声明后**全文件零读取**（`parse(_:confidenceThreshold:maxDetections:)` 不接收该参数，e2e 模型无 NMS）。已在 §一 参数表与正文标注「⚠️ **零调用死代码**，保留仅因历史上 NMS 需要」。**注意**：同名属性 `YolopxEngine.iouThreshold` 是**活的**（其 `nms` 后处理里真的按它做 IoU 抑制），两者同名不同命，勿混淆 |
| R2 | **`lockLostFrames > 15` 的「约 0.5s」在低频 tick 下已不成立** | `trackLock(with:)` 里的阈值仍为 15 帧（源码注释写「连续约 0.5s（15 帧）」，那是 **30Hz 口径**）。tick 频率由 `EngineMain.engineTickHz` 决定（2026-10-12 曾定档 20Hz，2026-10-22 又降到 15.0），帧预算口径随它漂移：20Hz 下 15 帧 = **0.75 秒**，比设计意图慢 50%；15Hz 下更慢。已标注为「帧计数常量口径漂移」之一 |
| R3 | **`AURORA_YOLO_FASTCOPY` 未在 AuroraFlags 注册表** | `inferFast(pixelBuffer:)` 里是裸 `ProcessInfo.processInfo.environment["AURORA_YOLO_FASTCOPY"]` 现读，`grep AURORA_YOLO_FASTCOPY Sources/AuroraDrive/Core/AuroraFlags.swift` **零命中**。已在 §三 标注「未注册的裸开关」，并提示若将来要做「所有开关集中在 AuroraFlags」需补登记 |
| R4 | **`maxDetections` 注释日期与实际提交不符** | 文档写「2026-10-11 从 20 放开到 300」，源码 `maxDetections` 的标定记录注释写的是 **2026-09-26 t23 标定**。已改为正确日期（值 300 正确，仅日期错） |

**未改的（源码核实仍准确）**：模型接口/NMS-free 结论、infer 慢路径与 inferFast 直通路径、`copyPixelBuffer` 的 min 防御、`smooth(_:against:alpha:)`（alpha=0.55）/`bestIoU` 0.25、`trackLock` 的 `iou - dist*0.4` 与 `-0.25` 门限、`parse` 的 NaN 防御与类别 clamp、`CocoLabels` 四个语义组、`selfTest`/`benchmark` 流程。

---

## 一、模型接口、可调参数与状态

**定位（文件头注释）**：CoreML YOLO 目标检测引擎——把截屏画面 → 障碍物检测框 `[Detection]`，供 RuleController 决策 + UI 画框。
> ⚠️ **2026-10-19 起该定位只在 legacy 三件套档成立**：A 模型档（默认档）下本引擎**不加载、不推理**，检测框来自 yolopx（ayolom 小模型）。详见文首「2026-10-19 档位语义变更」。

**模型**：`models/yolo26s.mlmodelc`（YOLOv26s，**NMS-free 端到端**），由 Ultralytics 导出（format="coreml"），自动标 colorSpace=RGB。

**模型接口：**

| 张量 | 形状 | 说明 |
|---|---|---|
| 输入 `image` | **640×640 CVPixelBuffer**，colorSpace = RGB | App 喂 32BGRA，**CoreML 运行时自动抽 R/G/B 按 RGB 喂入，无需手动转通道序** |
| 输出 | `[1, maxDet, 6]` Float32 | 每行 `[x1, y1, x2, y2, conf, class_id]`（**坐标为像素，相对 640 输入**；Swift `parse(...)` 除以 640 转归一化） |

**预处理约定（文件头注释）**：整帧**非等比拉伸**到 640×640（**不做 letterbox**），与训练端一致，因此像素坐标除以 640 即得整帧归一化坐标。

**说明（文件头注释）**：YOLOv26s 为 NMS-free 端到端，**无 anchor 概念，去重已在模型内部完成**，Swift 端只需要「置信度过滤 + 降序 + 截断 + 类别映射」。

**类声明**：`@Observable @MainActor final class YoloEngine`。

**模型常量**：`static let inputSize = 640`（nonisolated）——YOLOv26s 官方输入 640（**旧 FastestV2 是 352**）；后台推理队列要读且是编译期常量。**旧 FastestV2 的 numAnchors=1815 常量已不再需要**（源码注释）。

**六个可调参数：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `confidenceThreshold` | **0.22** | 置信度阈值：低于此值的框直接丢弃。YOLOv26s 比 FastestV2 强，**阈值可放宽到 0.22 提升召回**（小目标/远处障碍） |
| `iouThreshold` | 0.45 | ⚠️ **零调用死代码**（2026-10-18 复核）：声明后全文件零读取（`parse(...)` 不接收此参数，e2e 模型无 NMS）。保留仅因历史上 FastestV2 需要。**注意**：同名属性 `YolopxEngine.iouThreshold` 是**活的**——那边真做 NMS |
| `maxDetections` | **300** | 单帧最多保留多少个框（**2026-09-26 t23 标定**放开到 300：实测 P100 远低于 20，截断会人为限制路况三档可达性。⚠️ 2026-10-18 复核：原文写「2026-10-11」日期有误，源码标定记录写的是 09-26） |
| `enabled` | true | 是否启用（关掉可省算力） |
| `fastPathActive`（private(set)） | false | **直通路径是否已活跃**（CaptureEngine `onYoloFrame` 已产出过帧）——活跃后 tick() 不再走 NSImage→CGImage 慢路径，**避免双重推理**。**粘性标志（只在 `reset()` 清）**：若 CaptureEngine 停止直通它不会自动回落 |
| `lastFastPathTime`（@ObservationIgnored，private(set)） | `.distantPast` | **最近一次直通推理的时刻（9-24 改动 4 新增）**——`fastPathActive` 是粘性标志，若 CaptureEngine 停止直通，它不会自动回落，tick 会以为直通仍在而永不回退慢路径 → YOLO 停摆。**调用方据本时间戳做超时回退判断**（1s 无直通帧即回退慢路径）；仅供 tick 判活，不参与 UI 观察 |

**状态输出：**

| 成员 | 说明 |
|---|---|
| `isLoaded` / `isInferencing`（private(set)） | 加载状态 / 推理中 |
| `detections: [Detection]`（private(set)） | **最新一帧检测结果（tick 与 UI 都读这里）** |
| `lastLatencyMs`（private(set)） | 最近一次推理耗时（毫秒） |
| `inferenceCount`（private(set)） | 累计推理帧数 |
| `errorMessage: String?`（private(set)） | 错误信息 |
| `lastResultTime: Date?`（@ObservationIgnored，private(set)） | 最近一次成功推理时刻（判链路新鲜度） |
| `lastLoadAttempt` / `loadRetryCooldown = 5.0`（@ObservationIgnored） | P0-4：加载失败冷却（同 InferenceEngine） |
| `generation`（@ObservationIgnored） | P1：**`reloadModel()` / `reset()` / `unload()` 时递增；在途检测完成后比对，不匹配则丢弃过期结果** |
| `isLocked`（private(set)） | 锁定追踪：是否锁定目标 |
| `lockedTarget: Detection?`（private(set)） | 锁定目标（**归一化框，每帧经检测匹配 + EMA 平滑**）——UI 画「对焦」高亮框用这个 |
| `lockLostFrames`（private(set)） | 连续丢失帧数（**超过阈值自动解除锁定**） |
| `lockMessage: String?`（private(set)） | 锁定相关提示（丢失解除 / 手动锁定） |
| `lastFrame: [Detection]`（@ObservationIgnored） | 上一帧平滑结果（用于**全局乱飘抑制 + 锁定匹配基线**） |

**内部资源：**

- `model: MLModel?`（nonisolated(unsafe)）——CoreML 模型实例
- `inferenceQueue`——`DispatchQueue("com.aurora.yolo", qos: .userInteractive)` 串行
- `pixelBuffer: CVPixelBuffer?`（nonisolated(unsafe)）——复用的像素缓冲（慢路径拉伸用），避免每帧重新分配；只在串行 `inferenceQueue` 上创建与读写
- `yoloInputBuffer: CVPixelBuffer?`（nonisolated(unsafe)）——**直通路径（CaptureEngine 缩放置换的私有缓冲，来源是 `onYoloFrame` 的 640×640 帧）**：主线程把输入 memcpy 进来后交给推理队列，避免与捕获队列的写竞争。⚠️ **2026-10-19 订正**：旧文写「CaptureEngine **GPU 缩放**产出」是**错的**——直通帧的 640×640 缩放是 **CPU vImage**（`CaptureEngine` 的直通分支明确注释「vImage 缩放到模型输入尺寸（CPU，双线性 kvImageNoFlags）」，调用 `vImageScale_ARGB8888`）。当年正是为了避开 GPU 才改用 CPU：源码注释记录原始动机「消除游戏占满 GPU 时 `CIContext(GPU)` 排队导致的 40ms 卡顿」。GPU 上跑的只有推理本身
- `modelURL`（计算属性）：**优先编译产物 .mlmodelc，回退 .mlpackage**；YOLOv26s 替换后模型名从 game_assist_yolo 改为 yolo26s（旧文件保留作回滚）。源码注释另记录：`yolo26s` 与 `yolo26s_int8` 的 weight.bin md5 相同、280 帧输出张量 max|Δ|=0，两者本就是同一份导出

## 二、加载预热与 infer() 慢路径

**`loadIfNeeded()`**——与 InferenceEngine 同构：

- `guard !isLoaded` + **P0-4 冷却**（`loadRetryCooldown` 5 秒内不重试，防每帧重试风暴）
- `computeUnits = .all`（自动选 ANE/GPU/CPU，优先 ANE）；macOS 15+ 追加 `config.optimizationHints.specializationStrategy = .fastPrediction`（P3 推理优化，实测 1.12×、输出 bit-exact）
- **环3 预热**：加载成功后后台跑一次 dummy prediction（走 `warmUp(model:label:queue:)`）
- 失败 → `errorMessage = "YOLO 模型加载失败: ..."`

**`warmUp(model:label:queue:)`（private nonisolated static）**——模型预热（环3）：

- 后台跑一次 dummy prediction（**640×640 零缓冲**），把 ANE 计算图编译/内存分配提前做完，避免首帧真实检测冷启动尖峰
- `makePixelBuffer(size: inputSize)` + `MLDictionaryFeatureProvider(["image": MLFeatureValue(pixelBuffer: pb)])`
- 成功打印 `[warmup] yolo26s 预热完成: Xms computeUnits=all`；失败打印原因

**`reloadModel()`**——热替换（重训 YOLO 后调用）：`generation += 1` + model=nil + isLoaded=false + isInferencing=false + errorMessage=nil——**与 InferenceEngine 同机制**；下次 infer 经 `loadIfNeeded()` 重读。

**`unload()`（2026-10-19，A 模型档专用）**——把 yolo26s 从内存里卸掉（释放 9.2MB 权重 + CoreML 运行时占用）：`generation += 1` + model=nil + isLoaded=false + detections=[] + lastFrame=[] + `lastFastPathTime = .distantPast` + fastPathActive=false。**与 `reset()` 的分工**：`reset()` 清状态但**保留模型**（停止驾驶后再开要能立刻跑）；本方法连模型一起卸，调用方是 `selectPerceptionMode`（切到 A 模型档才卸）。**安全性**：`generation += 1` 让在途推理作废（`finish(...)` 的 `guard gen == generation`）；`detections = []` 必须清（否则 `.rule` 纯规则档会拿陈旧的 26S 残留框开车）；`lastFastPathTime = .distantPast` 让慢路径的 `fastPathStale` 判活立即为真，卸掉后若门被误开，`infer(...)` 会走 `loadIfNeeded()` 重新加载而非静默停摆。幂等（未加载时调用安全）。

**`infer(image: CGImage)`**——异步检测（**慢路径**：CGImage 拉伸）：

1. `guard enabled` → `guard isLoaded, let modelRef = model else { loadIfNeeded(); return }` → `guard !isInferencing`（防重叠）
2. 快照：conf/maxN/size/gen
3. `inferenceQueue.async { [weak self] in ... }`：
   - **整帧拉伸绘制进 BGRA 像素缓冲**：`pixelBuffer` 首帧创建后复用（`makePixelBuffer(size:)`）；`Self.draw(image, into: pb, size: size)`——**非等比拉伸到 640×640（不做 letterbox）**
   - **推理**：`MLDictionaryFeatureProvider(["image": MLFeatureValue(pixelBuffer: pb)])` → `modelRef.prediction(from: input)` → **输出名称动态取第一个 featureName**（`out.featureNames.first`）——源注释：**YOLOv26 e2e 单张量输出，名称由导出时自动生成（如 var_1442，不稳定），因此动态取第一个 featureName，不能硬编码**
   - **阈值过滤 + 截断**：`Self.parse(arr, confidenceThreshold: conf, maxDetections: maxN)`——**e2e 已内置 NMS/Top-K，无需再 NMS**；latency 计时
   - 结果回主线程 `finish(gen, kept, latency, nil)`；异常 `finish(gen, [], 0, "YOLO 推理失败: ...")`
   - 缓冲创建失败/输出缺失：`finish(gen, [], 0, "YOLO: CVPixelBuffer 创建失败" / "YOLO: 输出缺失")`

## 三、inferFast() 直通路径与 copyPixelBuffer / finish / smooth

**`inferFast(pixelBuffer: CVPixelBuffer)`**——直通路径（**快路径**）：

- **CaptureEngine 已在源头把全屏画面缩放到 640×640**（`onYoloFrame` 回调），这里直接推理，**跳过 NSImage/CGImage 大图转换链路（帧率瓶颈所在）**
- **fastPathActive 置位时机（9-24 改动 4 修复）**：`fastPathActive = true` 与 `lastFastPathTime = Date()` 放在「确实开始走直通」时（guard isLoaded 之后）——若放在 guard 之前，模型未加载时也会置 true，调用方（tick 的 `if !fastPathActive`）便永远不再回退慢路径，YOLO 会彻底停摆；**同时记录 `lastFastPathTime` 时间戳，供调用方做超时回退判断**
- `guard enabled` → `guard isLoaded, let modelRef = model else { loadIfNeeded(); return }` → `guard !isInferencing`
- **默认零拷贝（2026-10-11 P1 优化）**：不再每帧 memcpy 1.6MB，而是**直接捕获池化缓冲**（ARC 自动 retain；池深度 ≥4 + `isInferencing` 防重叠 + 同步 prediction 三重论证下无写竞争，省 70.3 MB/s ≈ 自动驾驶拷贝 42%）。`AURORA_YOLO_FASTCOPY=1` 可恢复旧拷贝路径（`yoloInputBuffer` + `copyPixelBuffer`，失败 → errorMessage "YOLO: 直通缓冲拷贝失败"）。⚠️ **2026-10-18 复核**：该开关是裸 `ProcessInfo.processInfo.environment` 现读，**不在 `AuroraFlags` 注册表**（`grep` 零命中）。若将来要求「所有开关集中登记」需补录
- `isInferencing = true` → `inferenceQueue.async`：
  - **P0-2 修复**：拷贝路径下 `guard let dst = yoloInputBuffer, Self.copyPixelBuffer(...)` 失败 → `Task { ... finish(gen, [], 0, "YOLO: 直通缓冲缺失") }`——**该 guard 失败路径必须复位 isInferencing（finish 里会复位），否则永久卡死、YOLO 停摆**
  - 推理（输入已是 inputSize×inputSize BGRA）→ 动态取 featureName → `Self.parse` → `finish(gen, kept, latency, nil)`

**`copyPixelBuffer(_ src: to dst:) -> Bool`（private nonisolated static）**——像素缓冲整块拷贝：

- 双锁 + defer 解锁 → 取 base 地址
- **`h = min(src高, dst高)`、`memcpy(d + y*dbpr, s + y*sbpr, min(sbpr, dbpr))`**——行数与每行字节都取 min（防御性：两边缓冲尺寸可能不同）

**`finish(_ gen:_ dets:_ latency:_ error:)`（private）**：

- **`guard gen == generation else { return }`**——`reset()` / `reloadModel()` / `unload()` 后在途结果过期，丢弃
- `isInferencing = false`
- error 非空 → `errorMessage = error`
- 否则：
  - **全局帧间平滑**：`let smoothed = Self.smooth(dets, against: lastFrame)`——**与上一帧做 IoU 匹配，命中目标用 EMA 稳住，治「框乱飘」（单帧检测框跳来跳去）。新出现的目标直接采用**；`lastFrame = smoothed`、`detections = smoothed`、`lastLatencyMs` / `lastResultTime` / `inferenceCount` 更新、errorMessage = nil；**A20：`PerfBus.shared.record("infer.yolo26s", ms: latency)` 汇报真实推理耗时**（对照 `--perf-selftest` 的 submit.yolo26s 通道只测 DispatchQueue.async 提交开销 p50 ≈ 0.012ms）
  - **锁定追踪**：`trackLock(with: smoothed)`——用平滑后的检测喂给锁定匹配

**`smooth(_ dets:against:alpha: Double = 0.55) -> [Detection]`（private nonisolated static）**——帧间平滑：

- **对每个检测框，找上一帧里 IoU 最大的框；命中 → 位置 EMA 平滑；未命中（新目标）→ 原样保留**（源码注释）
- **匹配阈值：`var bestIoU = 0.25`——低于此视为新目标**
- **EMA**：`Detection(x: l.x + (d.x - l.x) * alpha, ...)`——位置/宽高全部 EMA（alpha=0.55 偏向新帧），label/confidence/rawName 用新帧的
- `used` 数组防止上一帧同一框被匹配多次
- 空列表防御：`guard !last.isEmpty, !dets.isEmpty else { return dets }`

## 四、reset 与锁定追踪

**`reset()`**——停止驾驶时清空：`generation += 1`（在途检测结果过期）、detections=[]、isInferencing=false、lastLatencyMs=0、errorMessage=nil、lastFrame=[]、**lockedTarget=nil、isLocked=false、lockLostFrames=0、lockMessage=nil、fastPathActive=false**、lastResultTime=nil——全状态归零（含锁定与直通标记，但**保留模型**）。

**锁定追踪控制（主线程调用）：**

| 方法 | 签名 | 说明 |
|---|---|---|
| `setLock(x:y:width:height:)` | 归一化坐标 | **手动框选锁定**：`Detection(x:..., label: .obstacle, confidence: 0, rawName: "LOCK")` + isLocked=true + lockMessage="已锁定手动选框" |
| `setLock(to det: Detection)` | 检测框 | **点选检测框锁定**：锁定某个真实检测目标 + lockMessage="已锁定 \(rawName)" |
| `clearLock()` | — | 解除锁定（lockedTarget=nil、isLocked=false、lockLostFrames=0、lockMessage=nil） |
| `trackLockFromRemote(_ dets: [Detection])` | — | **用「外部来源」的检测结果推进锁定追踪（引擎拆分后新增）**。背景（源码注释）：本地模式下锁定追踪由推理流程逐帧内部调用（`finish` 里 `trackLock`）；但**引擎模式下 UI 不跑推理，检测框来自后台引擎回传**——若不调用本方法，锁定框会冻在原地不动、目标离开画面也不会自动解除（**用户实测反馈的两个现象**）。必须在主线程调用（与 trackLock 相同约束） |

**`trackLock(with dets: [Detection])`（private）**——锁定后每帧追踪：

- **匹配策略**：IoU 优先 + 中心距离辅助——**锁定框可以比检测框略大（用户框可能画大），所以 IoU 要求放宽，并加入中心距离惩罚，避免锁定目标在多个检测框间跳来跳去**：`let score = iou - dist * 0.4`，`var bestScore = -0.35`
- **匹配成功**：`bestScore > -0.25` → **EMA 平滑（`let alpha = 0.5`，兼顾响应速度与稳定性）**：位置/宽高全部 EMA，label/confidence/rawName 用新帧的；`lockLostFrames = 0`
- **匹配失败**：`lockLostFrames += 1`；`if lockLostFrames > 15`（连续 15 帧没匹配到）→ 目标可能离开画面，自动解除（lockedTarget=nil、isLocked=false、lockMessage="目标丢失，锁定已解除"）
  > ⚠️ **2026-10-18 复核：源码注释写「连续约 **0.5s**（15 帧）」，这是 30Hz 口径，在低频 tick 定档后已不成立。**
  > tick 频率由 `EngineMain.engineTickHz` 决定（历史上 30→20→15），20Hz 下 15 帧 = **0.75 秒**，15Hz 下 = **1.0 秒**，均比设计意图慢。
  > 这是帧计数常量口径漂移之一（同类：`ConfidenceEstimator.longExtremeWindow`、`MotionPredictor.maxPredictionFrames` / `maxMissingFrames`、`LaneFallback.stabilityFrames`）。
  > **修复方式二选一（⚠️ 待确认，需产品决策）**：① 把阈值 15 改小（保持 0.5s 语义）；② 改注释承认现值并说明可接受。

**`centerDistance(_ a:_ b:) -> Double`（private nonisolated static）**：两框中心距离（归一化）——`hypot(a.x - b.x, a.y - b.y)`。

## 五、自检 / 基准 / 像素缓冲 / parse / CocoLabels

**`selfTest(imagePath: String) -> String`**——同步跑一张图，返回可读报告：

- **用途（源码注释）**：验证 Swift 侧的 BGRA 像素缓冲路径与 Python 端（tools/verify_yolo_coreml.py）结果一致——**通道序如果搞反，模型不会报错，只会默默给出错误的框**
- 流程：`loadIfNeeded()` → 读图 → `makePixelBuffer(size: 640)` → `Self.draw(cgImage, into: pb, size:)` → **`dumpPNG(pb, to: "/tmp/yolo_swift_input.png")` 调试图：导出缓冲内容** → 推理 → 动态取 featureName → `Self.parse` → 报告（图片尺寸/模型名/耗时/阈值/输出 dtype 与 shape/**原始输出对拍前 12 行**/过阈值框列表 + 危险区标记 `d.isInDangerZone()`）
- `rawDump(_ out: MLMultiArray) -> String`（private）：打印单张量前 12 行 `(x1,y1,x2,y2,conf,class_id)`——**与 Python 端逐项核对**用

**`benchmark(imagePath:iterations: Int = 30) -> String`**——帧率基准：对比两条路径各跑 N 次取平均，量化 CaptureEngine 直通改造的收益：

- **慢路径**：CGContext 绘制到 640 缓冲 + 推理（`Self.draw` + prediction）
- **直通路径**：缓冲 + memcpy 拷贝 + 推理（`Self.copyPixelBuffer` + prediction——**模拟 inferFast**）
- 输出 `%.1f ms/帧 ≈ %.0f FPS`

**像素缓冲三件套（private nonisolated static）：**

| 方法 | 说明 |
|---|---|
| `makePixelBuffer(size: Int)` | CVPixelBufferCreate（32BGRA + CGImage/CGBitmapContext 兼容；**无 Metal**） |
| `dumpPNG(_ pb: to:)` | 像素缓冲导出 PNG（调试用：**验证 Swift 喂给模型的内容与 Python 端是否一致**）——CGContext(data: base) + makeImage + NSBitmapImageRep.png |
| `draw(_ cgImage:into:size:)` | 把整帧**拉伸**绘制进像素缓冲——**不 letterbox，与训练/官方 demo 的 resize 行为一致**（源码注释）；32BGRA+premultipliedFirst+littleEndian32 == BGRA 内存序，**模型实际声明 colorSpace=RGB，CoreML 运行时自动从 BGRA 抽 R/G/B（无需手动转）**；`interpolationQuality = .low`——**检测对插值质量不敏感，选快的** |

**输出解析：**

**`readML(_ m: MLMultiArray, _ index: [Int]) -> Double`（private nonisolated static）**——安全读取 MLMultiArray 元素：**让 CoreML 自己处理 dtype/stride/半精度**——直接读 dataPointer 在 FLOAT16 + 非连续 stride 下会错位，**用官方下标** `m[index.map { NSNumber(value: $0) }].doubleValue`。

**`parse(_ out: MLMultiArray, confidenceThreshold: Double, maxDetections: Int) -> [Detection]`（private nonisolated static）**——单张量 [1, maxDet, 6] → [Detection]：

- 每行 = `[x1, y1, x2, y2, conf, class_id]`，坐标为**像素**——**实测 YOLOv26s 输出为像素，此处统一除以 inputSize 转归一化 [0,1]**，与 Detection 契约及全链路（RuleController/overlay）一致
- **e2e 模型已内置 NMS + Top-K，此处只需置信度过滤 + 降序 + 截断**
- 动态读取候选数：`let n = out.shape.count >= 2 ? out.shape[1].intValue : 0`——**不依赖硬编码常量**
- **P0-1 修复**：YOLO 单帧可能输出 NaN/Inf——**任何非有限值都跳过该框，绝不进入 Int()（Int(NaN) 会 runtime trap 崩全车）**：`guard conf.isFinite, conf > confidenceThreshold else { continue }`
- 坐标四元组同样 `isFinite` 校验；**退化框过滤**：`guard w > 0.001, h > 0.001`
- **类别加固**：有限但超范围的大值（如 1e20）转 Int 会 overflow trap；越界索引也会异常——**先 clamp 到 [0, 类别数-1] 再转 Int，双保险**：`Int(min(max(clsRaw.rounded(), 0), Double(CocoLabels.names.count - 1)))` → `CocoLabels.map(clsIdx)`
- Detection 构造：`x: (x1+x2)/2, y: (y1+y2)/2`（**中心点 + 宽高**格式，与 Detection 契约一致）
- **兜底排序 + 截断**：`dets.sorted { $0.confidence > $1.confidence }.prefix(maxDetections)`——替代原 nms 的 limit 语义

**`iou(_ a:_ b:) -> Double`（private nonisolated static）**：标准 IoU——xywh（中心+宽高）格式转 x1y1x2y2 → 交并比，`union > 0 ? inter/union : 0`。

**`CocoLabels`（enum）**——COCO-80 类名 + 到 Detection.Label 的映射：

- `names: [String]`（static）——COCO 80 类顺序（data/coco.names）：person/bicycle/car/…/toothbrush
- **四个语义组**：`vehicleIdx = [1,2,3,4,5,6,7,8]`（两轮/轨道/船机——**游戏里都当「会动的大件」处理**）、`personIdx = [0]`、`signIdx = [9, 11, 12]`（红绿灯/停车标志/计时器）
- `map(_ idx: Int) -> (Detection.Label, String)`：越界返回 `(.obstacle, "OBJ")`；命中组返回对应 Label，**UI 显示名 `names[idx].uppercased()`**

**YoloEngine 文档至此完整**（模型接口 → 加载预热 → infer 慢/快双路径 → 帧间平滑 → 锁定追踪 → 模型卸载 → 自检基准 → parse 与类别映射）。
