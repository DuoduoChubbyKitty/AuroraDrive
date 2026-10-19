# 代码-32 Vendor/MetalGoose Metal 引擎

## ♻️ 行号已按 9097 行版重基准（2026-10-18 收尾批次）

> **`CaptureEngine.swift` 1584 行未变，本文档对所有 CaptureEngine 引用零修正。**
>
> lead 同日改的 `:479`/`:654` 两处是**同位置注释文字替换**（`:479` 频段说明 1280×832@20fps、`:654` `setCaptureHz` 接线状态），行数不变——且**本文档不引用这两行**（`grep "479\|654"` 零命中），故零影响。
>
> 逐条复核本文档的 CaptureEngine 引用，全部准确：
>
> | 引用 | 语义 | 复核 |
> |---|---|---|
> | `CaptureEngine.swift:130` | `var onUpscaleFrame: ((CVPixelBuffer) -> Void)?` 单向回调 | ✅ |
> | `:138` | `var isUpscaleWanted: () -> Bool = { false }` 门禁默认 false | ✅ |
> | `:1104` | 「门禁先于拷贝求值」注释 | ✅ |
> | `:1106-1109` | `if let onUpscaleFrame, isUpscaleWanted(), ... { onUpscaleFrame(...) }` | ✅ |
> | `:1111` | YOLO 直通段注释（与插帧段并列） | ✅ |
>
> **其余无前缀 `:NNN` 引用全部指向 `Vendor/MetalGoose/Engine/GooseEngine.swift`（2057 行，未改动）**，抽验 20 处（maxInFlight :93 / measurementWindow :100 / inFlightSemaphore :105 / texturePoolDepth :348 / estimatedCaptureInterval :399 / :743 / measuredSourceFPS :764 / snapToRefreshDivisor :774 / :823 / :954 / :967 / :1351 / :1353 / :1399 / startCaptureFromWindow :1888 / processIOSurfaceFrame :1911 / ingest :1930 / :1995）**全部命中**。

---

> ✅ **2026-10-18 复核**（merge-arch）：逐文件 `wc -l` + 抽查 GooseEngine 20+ 处行号，全部命中无漂移（2057/236/107/364/466/16 = 3246 行）。`Package.swift:182-185` 的 `sources: ["Sources/AuroraDrive", "Vendor/MetalGoose/Engine"]` 确认 Engine/ 子集进编译；`:163-178` exclude 显式排除根层 15 个文件 + **两份 Shaders.metal**（根层 `:176` + Engine/ `:178`）。本次补两处缺失：
> 1. **GPL v3 强传染论证完全缺失**——本文通篇未提 GPL，而 `Vendor/MetalGoose/LICENSE` 首行就是 `GNU GENERAL PUBLIC LICENSE Version 3`，且 Engine/ 已进 `sources:` 编译。已补 §七。
> 2. **「仅显示层」缺代码级证据**——原文 §一只写了一句「决策链路永不经过本引擎」，但没给 `onUpscaleFrame` 的出处。已补 `CaptureEngine.swift:1106-1109` + `isUpscaleWanted` 默认 false（:138）的逐行证据。

> ✅ 2026-10-17 复核：覆盖源文件行数已按当前实测更新；正文全部 `GooseEngine.swift:NNNN` 行号已按当前 **2057 行版**逐符号 `grep -n` 重测修正（旧基准为 1890/1988 行版，已作废）。

> 覆盖源文件：`Vendor/MetalGoose/Engine/`（6 文件 **3246 行**）：GooseEngine.swift（**2057 行**，2026-10-16 `wc -l` 实测；10-02 曾为 1890 行）+ CaptureSettings.swift（236）+ GooseUpscaler.swift（**107**，代码-26 单元十已详）+ WindowCaptureManager.swift（364）+ Shaders.metal（466）+ Stubs.swift（16）。基于当前仓库逐单元编写。
>
> **2026-09-25 深度复核记录**：GooseEngine 1988→**2057 行**（+69）、GooseUpscaler 91→**107 行**（+16）——增量为 9-24 优化改动 11（**新增 `GooseEngine.ingest(pixelBuffer:)` façade 转发**，与 ingest(cgImage:) 的 MTKView 检查逐行一致）与改动 9（引擎进程跳过 Metal 初始化）配套；其余 4 文件行数零变化（byte-for-byte 保留原则不变）。

## 一、GooseEngine 类头与管线建立（第 1–557 行）

**文件定位**：MetalGoose——上游 vendor 的 Metal 插帧/超分引擎（**byte-for-byte 保留，成员 internal**）；GooseUpscaler 是薄封装门面（public，代码-26 单元十）。**架构注（GooseUpscaler 12–14 行）**：喂到这里的帧只走显示/叠加路径；capture → CoreML 推理 → 按键注入决策链路永不经过本引擎。

**「仅显示层」的代码级证据（2026-10-18 补，三处独立证据）：**

| # | 位置 | 证据 |
|---|---|---|
| ① | `CaptureEngine.swift:130` | `var onUpscaleFrame: ((CVPixelBuffer) -> Void)?`——**单向回调，只出不进**（回调无返回值，引擎拿不到任何回读结果） |
| ② | `CaptureEngine.swift:1106-1109` | 调用点：`if let onUpscaleFrame, isUpscaleWanted(), let upscaleCopy = copyUpscaleFrame(...) { onUpscaleFrame(upscaleCopy) }`——**在「插帧/超分直通」段，与下游 YOLO 直通（:1111）并列，不改写 `pixelBuffer`** |
| ③ | `CaptureEngine.swift:138` | `var isUpscaleWanted: () -> Bool = { false }`——**门禁默认 false**：默认路径下 MetalGoose 根本不参与，连全分辨率拷贝都不做（:1104 注释「门禁先于拷贝求值」） |

即：MetalGoose **只吃像素、只吐像素**，拿不到 `ControlCommand`、检测结果、坐标；且默认关闭。
⚠️ **这条是产品的硬红线**（不是实现细节）：插帧必然引入额外延迟，一旦进入「捕获→推理→按键」决策链会害死驾驶决策——改动此处前必须先确认。

**依赖（1–10 行）**：Metal/MetalKit/**MetalFX**/IOSurface/QuartzCore/CoreVideo/VideoToolbox——**@preconcurrency 全部导入（Sendable 检查放宽）**。

**`CursorUniforms`（12–15 行）**：合成光标 uniforms——center/size（SIMD2<Float>）。

**`PipelineStats`（@unchecked Sendable，17–52 行）——引擎统计（26 字段）：**

| 组 | 字段 | 说明 |
|---|---|---|
| 帧率 | captureFPS / outputFPS / **generatedFPS** | 捕获/输出/**生成（distinct images/s，cache hits excluded——面板显示两次算一张）** |
| 延迟 | frameTime / gpuTime / captureGPUTime / captureLatency / presentLatency / **endToEndLatency** / avgFrameTime | 六段延迟链 |
| 节奏 | **framePacingScore（默认 100）** | 节奏评分 |
| 计数 | frameCount / outputFrameCount / droppedFrames / **interpolatedFrameCount**（present 侧）/ passthroughFrameCount / **generatedFrameCount**（distinct，累计） | **interpolated + passthrough = outputFrameCount**（36–38 行注释） |
| 资源 | gpuMemoryUsed/Total / processMemoryUsed / cpuUsage | GPU/进程资源 |
| 环境 | outputResolution / screenRefreshRate / **isProMotion** / targetOutputFPS | 输出环境 |

**`GooseEngine`（NSObject, MTKViewDelegate, @unchecked Sendable，54 行起）**：

| 成员 | 说明 |
|---|---|
| `_stats` + `statsLock`（OSAllocatedUnfairLock） | 统计 + 锁（`stats` 计算属性锁内返回**值拷贝**） |
| `renderStateLock` | 渲染状态锁 |
| `errorLock` + `reportedErrors: Set<String>` + `pendingErrors: [String]` | **错误上报：Set 去重（同一错误只报一次）+ 队列待消费** |
| `nonisolated(unsafe) static lastInitError` | **静态初始化错误（make() 失败时写，供调用方读）** |

**`make()`（static，第 420–431 行）——工厂**：`MTLCreateSystemDefaultDevice()` 为 nil → lastInitError = "MG-ENG-002 Metal device not available" + nil；`makeCommandQueue()` 为 nil → "MG-ENG-003" + nil；成功 → lastInitError = nil + GooseEngine(device:queue:)。

**`init(device:commandQueue:)`（private，433–438 行）**：device/queue 持有 → setupPipelines()。

**`setupPipelines()`（private，第 440–536 行）——着色器编译与 10 条管线：**

- **⚠️ Shaders.metal 运行时编译（441–481 行注释，代码-26 单元十已详）**："SwiftPM does not auto-compile .metal into a default.metallib, so compile Shaders.metal from source at runtime. Falls back to makeDefaultLibrary() when a prebuilt metallib happens to be present"——三候选：Bundle.main（Xcode Run）/ **可执行文件目录**（exeDir/Shaders.metal、exeDir/Vendor/MetalGoose/Engine/Shaders.metal、**硬编码 /Users/dupi/Desktop/自动驾驶系统/Vendor/MetalGoose/Engine/Shaders.metal**）→ makeDefaultLibrary 兜底
- **8 个 compute 管线（492–500 行）**：`contrastAdaptiveSharpening`（CAS 锐化）/ `copyTexture` / `bgraToLuma` / `extrapolateFrame` / `fxaa` / `smaaEdgeDetection` / `smaaBlendingWeights` / `smaaBlend`——**失败不崩（try? 静默 nil，reportError 记录）**
- **render 管线（502–533 行）**：texture_vertex/texture_fragment（bgra8Unorm）+ **cursor_vertex/cursor_fragment（**isBlendingEnabled + add 混合 + sourceAlpha → oneMinusSourceAlpha——光标 alpha 混合**，MG-ENG-011）**
- `loadCursorTexture()`（538–557 行）：**NSCursor.arrow.image** → MTKTextureLoader（SRGB false + shaderRead + private 存储）——**用系统箭头光标做合成光标纹理**

**错误码体系（grep 实测）**：MG-ENG-001（管线建立失败）/ 002（无 Metal 设备）/ 003（无命令队列）/ 010（MetalFX 插值器创建失败）/ 011（光标管线失败）/ EXT-001~004（ingest 扩展：CVPixelBufferCreate/IOSurface/MTKView/drawableSize）——**显式暴露"插帧为何静默不产帧"的根因**（pendingError 消费）。

## 二、Vendor 两层结构与关键常量

**⚠️ Vendor/MetalGoose 有两层（本机验证）：**

| 层 | 文件 | 总行数 | 状态 |
|---|---|---|---|
| **根层**（原版完整 goose 应用） | AutoUpdater(310)/CaptureSettings(236)/ContentView(**891**)/GlobalHotkeyManager(74)/GooseEngine(**1890**)/LICENSE/Localizable.xcstrings/MGHUD(**409**)/**MetalGoose.entitlements**/MetalGooseApp(10)/NOTICE.md/OverlayWindowManager(**503**)/README.md/Shaders.metal(**466**)/WindowCaptureManager(364) | 4687 | **原版独立 MetalGoose.app（插帧超分应用），不参与 AuroraDrive 编译（⚠️ 2026-09-20 起 Package.swift `exclude` 已显式列出根层这 15 个文件，消除 unhandled 告警；sources 白名单始终未列根层）** |
| | | | ⚠️ **2026-09-29 实测订正**：① 上表原漏列 `MetalGoose.entitlements`（但它在 `Package.swift` exclude 里，**共 15 项是对的**）；② 根层 `Shaders.metal` 实为 **466 行**（非 468），且与 Engine/ 版**完全相同** |
| **Engine/ 子目录**（AuroraDrive 编译子集） | GooseEngine(**2057**)/CaptureSettings(236)/GooseUpscaler(**107**)/Shaders.metal(466)/Stubs(16)/WindowCaptureManager(364) | 3246 | **Package.swift sources 白名单列 5 个 .swift——AuroraDrive 只用 Engine/ 子集** |

- **Engine/ 版 GooseEngine 比根层多 167 行**（2057 vs 1890）：AuroraDrive 扩展（`public func ingest(cgImage:)` / `ingest(pixelBuffer:)` + updateCaptureStats 调用 + 错误码 EXT 系列）
- **Shaders.metal 两份**（根层 / Engine/）——**⚠️ 2026-09-29 实测订正：两份完全相同**
  （均 **466 行 / 17,016 字节**，`diff` 零差异；本文原写「根层 468 / Engine 466，几乎一致」，
  行数与"几乎"均不准确）；**运行时编译读的是 Engine/ 那份**（候选路径 ②③）
- **`Stubs.swift`（Engine/ 独有，16 行）**："Minimal stub for MetalGoose's `MouseConstraintManager` (cursor-drawing helper). **The full implementation lives in MetalGoose's OverlayWindowManager.swift and is intentionally NOT vendored.** GooseEngine only requires this single accessor on the display path, so a trivial stub is sufficient. **This file is AuroraDrive's own addition and is NOT part of the upstream GPL v3.0 source**"——**`currentCursorFraction()` 恒返回 (0.5, 0.5)（屏幕中心）：合成光标永远画在 drawable 中心**（不追踪真实鼠标——显示路径不需要）

**关键常量（grep 实测）**：`maxInFlight = 3`（:93）/ `measurementWindow = 0.5`（:100；使用处：帧率偏好节流 :823 / 历史容量 :954 / pllGain :967 / EMA alpha :1351 / CPU 采样节流 :1399）/ `minFrameTimeSamples = 8`（统计下限）/ `frameTimeHistoryCapacity`（refreshRate × 0.5 动态）/ `texturePoolDepth = capacity + maxInFlight`（= 7）。

**`interpolationDelay(outputInterval:mode:)`（private，第 854–863 行）——插帧目标时间回退量**：

| mode | delay | 语义 |
|---|---|---|
| `.interpolation` | `max(outputInterval, captureInterval)` | **插帧模式：目标时间回退一个输出间隔（取两帧之间括号中部）** |
| `.extrapolation` | **0** | 外推模式：目标时间 = 当前（最新帧之后外推） |
| `.off` | `max(outputInterval, captureInterval)` | 关闭（同插帧——直通时也要找对帧） |

**`applyBufferDepth(_ depth:)`（private，第 865–877 行）——"Emulates a shallower pipeline by parking permits on processingQueue rather than replacing the semaphore out from under in-flight frames"**：

- `wanted = maxInFlight - clamp(depth, 2, maxInFlight)`——**目标在途深度**
- processingQueue 异步：**parkedPermits < wanted → 逐个 wait（park 信号量）；> wanted → 逐个 signal（归还）**——**模拟浅管线：不动在途帧的信号量，靠停票/还票调深度**

**`pllGain(outputInterval:)`（965–968 行）**：`min(1, outputInterval / measurementWindow)`——**一阶环增益：相位误差每输出帧衰减该比例；固定增益在 480Hz 面板快 4 倍、30fps 慢 4 倍——按视图实际速率自适应**。

## 三、帧率偏好与捕获处理管线（第 783–877、1424–1658 行）

**`desiredOutputFPS(_ config:)`（private，第 795–818 行）——目标输出帧率**：

- `requested = frameGenEnabled ? currentRefreshRate : (sourceFPS > 0 ? sourceFPS : currentRefreshRate)`——**插帧开 → 冲到刷新率；关 → 跟捕获帧率**
- `target = vsync ? snapToRefreshDivisor(requested) : rounded`（**vsync 开 → 吸附到刷新率整数因子**，snapToRefreshDivisor :774）
- **钳制（788–797 行）**：target = min(target, currentRefreshRate)；**"A variable-refresh panel cannot be driven below its own floor"——minRefreshRate < currentRefreshRate 且 target < minRefreshRate → target = minRefreshRate**（可变刷新面板不能低于自身下限；固定面板无下限要尊重）
- 返回 max(1, target)

**`applyFrameRatePreference(_ preferred:)`（private，第 820–832 行）**：

- **节流（823 行）**：`now - lastPreferredUpdateTime < measurementWindow → return`——**"The target is derived from a filter that settles over one measurement window, so it cannot honestly change faster than that——re-tuning more often only resets CADisplayLink's pacing. The window is the whole hysteresis"**
- `lastPreferredFPS = preferred` + 主线程异步 `view?.preferredFramesPerSecond = preferred`

**`applyDisplaySync(to:vsync:)`（834–841 行）**：CAMetalLayer——**displaySyncEnabled = vsync + presentsWithTransaction = false**。

**`processSurface(_ surface:pixelBuffer:timestamp:isSceneCut:)`（private，1424–1442 行）**：IOSurface → **bgra8Unorm MTLTexture（shaderRead，IOSurface 共享零拷贝）**——失败 → "MG-ENG-008 IOSurface texture creation failed" + **inFlightSemaphore.signal()（背压归还，防卡死）**。

**`processCapturedTexture(_ inputTex:pixelBuffer:timestamp:isSceneCut:)`（private，1444–1589 行）——捕获处理管线（CAS/AA/还原 → ring）：**

1. **信号量背压（1445–1454 行）**：commandBuffer nil → signal + return；**addCompletedHandler 里 signal——GPU 完成才归还（在途帧上限 3）**
2. **尺寸还原（1458–1477 行）**："ScreenCaptureKit now delivers the render resolution directly……**Render scale reduces the capture, but frame generation must not inherit that reduction: interpolation and the motion field would then work on a fraction of the pixels and smear. Bring the frame back to the window's native size first**"——`restoreActive = scalingType == .mgup1 && native >= input + 1` → width/height 用 native；**尺寸变化 → resetProcessingState(clearFrames: true)**
3. **ring 槽位（1483–1494 行）**：**"Every scratch texture is reused next frame, so the LAST active stage writes straight into the ring slot; a passthrough config needs a copy"**——`historyTextureIndex % count` 轮换 → ensureTexture（shaderRead|shaderWrite|renderTarget）——失败 → droppedFrames += 1 + commit
4. **还原执行（1498–1520 行）**：restoreActive → ensureSpatialScaler（captureScaler）→ scaler.encode（workingTex = destination；CAS/AA 活跃时写 scratch，否则直写 historyTex）
5. **CAS 锐化（1522–1549 行）**：sharpness > 0.01 → casPipeline + SharpenParams → dispatchThreads（**AA 活跃写 scratch 否则直写 historyTex**）；失败 "MG-ENG-007 CAS pipeline unavailable"
6. **AA（1551–1569 行）**：encodeAntiAliasing（mode/profile）→ 失败 droppedFrames；**全关（restoreActive 也关）→ encodeCopy 直写**
7. **captureGPUTime（1571–1578 行）**：completedHandler 里 gpuTime 记录
8. **motion（1580–1582 行）**：**extrapolation 模式才 encodeMotion（插帧不需要运动场——MetalFX 自带）**
9. **`frameBuffer.push(FrameHistory(...))`（1584–1585 行）**——**进环形缓冲（每帧入 ring）**

**`encodeMotion(from:width:height:)`（private，1591–1618 行）——运动场编码（luma → media engine → slot）**：

- **头注释（1588–1591 行）**："Converts the frame to luma, hands it to the media engine, and copies the resulting vectors into a slot we own——**VideoToolbox recycles its own buffers, and the ring holds each field until the frame leaves it**"
- **luma 转换（1592–1601 行）**：lumaPipeline + motionEstimator.prepare（slot 目的地）→ dispatchThreads
- **异步 estimate（1603–1614 行注释）**："**VideoToolbox reads the IOSurface outside Metal's ordering, so the estimate has to follow the write——but waiting for it here would serialise the capture pipeline, so it runs on the completion handler and the result is picked up by the next frame instead**"——completedHandler → processingQueue → `motionEstimator.estimate()` → `storeMotion(field)`——**结果下一帧才可用（首帧 latestMotion() 为 nil）**
- 返回 `latestMotion()`（最新运动场）

**`storeMotion(_ field:)`（1622–1643 行）——"Copies the estimator's output into a slot we own, since VideoToolbox recycles its buffers while the ring still references the field"**：motionTextureIndex 轮换 → ensureTexture（**rg16Float，shaderRead|shaderWrite**）→ **blit 拷贝**（field → destination）→ motionLock 内 `_latestMotion = destination`——**自有槽位持有，不受 VideoToolbox 回收影响**。

**`latestMotion()`（1645–1649 行）**：motionLock 内返回 `_latestMotion`。

**`SharpenParams`（1651–1653 行）**：sharpness（Float）；**`AntiAliasParams`（1655–1658 行）**：threshold/maxSearchSteps（FXAA/SMAA 参数）。

## 四、renderFrame 主渲染循环（第 928–1248 行）

**`draw(in view:)`（nonisolated，928–932 行）**：MTKViewDelegate 入口——`MainActor.assumeIsolated { renderFrame(in: view) }`——**非隔离回调假设主线程隔离（MTKView 在主线程驱动）**。

**drawable 死锁根因（972–982 行注释，本文件最重要的工程注解）**：

```
The drawable is deliberately not acquired here. `currentDrawable` blocks the
calling thread — this one, the main thread — for as long as the layer's pool
is empty, and a layer whose window has gone away never refills it: recycling
happens on display refresh, and a layer with nowhere to present never gets one.
Taking a drawable at the top of the function put every early return on the
wrong side of that, so closing the window while the view was still being driven
left the main thread spinning inside nextDrawable until the app had to be force quit.

So: establish there is somewhere to present first, do all the work that
does not need a drawable, and take one at the last possible moment.
```

**renderFrame 流程（971–1248 行）**：

1. **入口 guard（983–987 行）**：view.window != nil + drawableSize > 0 + renderPipeline + commandBuffer——**先确认有地方呈现，再做不需要 drawable 的工作**
2. **frameGenNeedsTeardown（992–1002 行）**：锁内取标志 + 清零 → **teardown 在渲染线程执行（"every MetalFX frame-gen object lives and dies on this thread"）**：frameInterpolator/spatialScaler/纹理/缓存时间戳全清
3. **帧间隔历史（1008–1015 行）**：outputFrameTimeHistory.append + 超容量 removeFirst——**实际驱动速率的滚动平均**
4. **目标帧率（1020–1024 行）**：desiredOutputFPS + applyFrameRatePreference + _stats.targetOutputFPS
5. **采样时钟（1026–1052 行）**："**The frame clock has to advance at the rate the view is actually being driven at. preferredFramesPerSecond is only a hint——a ProMotion panel happily runs the callback at 120 while we asked for 60——and a clock built on the requested rate runs ahead of real time, pushes targetTime past the newest captured frame, and turns every frame into passthrough**"——measuredInterval（≥8 样本才用均值）→ nominalInterval；**"Several frames' worth of deviation is a stall, not phase error a first-order loop should chase; resynchronise instead of crawling back"**——偏差 > 3×nominalInterval → 重同步（pllPhase = currentTime）；否则 PLL 一阶推进（`advanced + phaseError × pllGain`）
6. **targetTime（1053 行）**：`sampleClock - interpolationDelay(...)`——**插帧模式下时钟回退一个间隔**

**三种帧生成模式分支（1055–1153 行）：**

| 分支 | 条件 | 输出 |
|---|---|---|
| **外推 extrapolation**（1062–1098 行） | frameGenMode == .extrapolation + newest 帧存在 | **"The multiplier is how many images the gap should carry, so the gap is cut into that many slots: slot 0 is the captured frame itself and each later slot is one warp phase. Letting every present pick its own continuous phase ignored the multiplier entirely"**——`steps = max(1, multiplier); rawPhase = clamp((currentTime - newest.timestamp)/interval, 0, 1); step = min(steps-1, Int(rawPhase × steps))`；**"A capture that has not been shown yet is always presented as it was captured. Only the gaps between captures are generated——warping real frames as well destroys the image for no benefit"**：newest 未呈现 → 直出；step > 0 且非场景切换且有 motion → `encodeExtrapolation`（warp 前向）；否则直出 |
| **插帧 interpolation**（1099–1148 行） | frameGenMode == .interpolation + getFramesForTime(targetTime) 命中 + 双帧同尺寸 | `duration = next - prev; t = clamp((targetTime - prev)/duration, 0, 1)`；**"MetalFX synthesises exactly one phase between a pair——the midpoint——so the images available for this bracket are prev at 0, the generated frame at 0.5 and next at 1. Each sample is served by whichever of those sits closest to it, which puts the boundaries at 0.25 and 0.75 for free"**——`phase = (t × 2).rounded() / 2`（0/0.5/1 三档）：phase==0 → prev 直出；==1 → next 直出；**next.isSceneCut → 直出 + history reset**；否则 `interpolateFrame(prev:next:)`（MetalFX 中点合成）；**"The generated frame stands for targetTime, not for prev——using prev here overstated latency by up to a whole capture interval"**——sourceTimestamp = next.timestamp；**contentKey = prev + next（"MetalFX yields one image per frame pair, so the pair identifies the content however many times it is presented"）** |
| **else 直通**（1149–1153 行） | 其他 | newest 帧直出 |

**输出编码（1155–1248 行）：**

1. `guard finalTex` → commit + return（无帧）
2. **`encodeUpscale`（1160–1167 行）**——**"Spatial upscale lives on the render path so that frame interpolation can run at capture resolution. Interpolation cost scales with pixel count, so paying for one upscale per presented frame is far cheaper than making every generated frame an output-resolution interpolation"**
3. **presentLatency（1169–1175 行）**：`(currentTime - sourceTimestamp) × 1000` → presentLatency + **endToEndLatency = captureLatency + presentLatency**
4. **计数（1177–1183 行）**：renderFrameCount/isInterpolated/generatedNewImage——**"Only a cache miss put a new image on screen. Counting every present that carried generated content instead reported the same synthesised image once per present, which at 120 Hz over a 15 fps capture inflated the figure by roughly the refresh ratio"**
5. **1s 节流统计（1184–1195 行）**：outputFPS/generatedFPS + **updateFramePacingStats()**
6. **drawable 最后获取（1197–1202 行）**："**Last possible moment: everything above is encoded and the only thing left is the pass that writes into the drawable and presents it**"——`guard view.currentDrawable` → commit + return
7. **渲染 pass（1204–1222 行）**：clear→store + **presentTex 全屏 triangleStrip 4 顶点** + **captureCursorEnabled → drawSyntheticCursor**
8. **present + 完成统计（1224–1247 行）**：`commandBuffer.present(drawable)` + addCompletedHandler——**"Interpolation and the upscale live here now, so the capture buffer alone no longer represents the pipeline's GPU cost"**：gpuTime = captureGPUTime + renderGPU；**outputFrameCount += 1 + frameGenActive ? (interpolated ? interpolatedFrameCount : passthroughFrameCount) : passthroughFrameCount**——**present 侧计数（与 render 侧分开）**

**`drawSyntheticCursor`（@MainActor，1289–1312 行）——合成光标绘制**：

- `guard cursorPipeline/cursorTexture/... /MouseConstraintManager.shared.currentCursorFraction()`——**stub 恒 (0.5, 0.5)（屏幕中心）**
- **NDC 换算（1298–1306 行）**：`backingScaleFactor`（默认 2.0）→ `widthNDC = 纹理宽 × scale / drawable × 2` → `centerX = -1 + 2 × fraction.x`（**NDC [-1,1]**）→ CursorUniforms → setVertexBytes + setFragmentTexture + triangleStrip 4 顶点

## 五、帧缓冲环与 MotionEstimator（第 165–418 行）

**`FrameHistory`（struct，165–172 行）——帧历史条目**：texture（MTLTexture）/ timestamp / isSceneCut / **motion: MTLTexture?（"Backward motion against the previous frame, in pixels, one vector per 16x16 block. Only produced in extrapolation mode"）**。

**`MotionEstimator`（private final class，177–278 行）——运动估计器（包装 VTMotionEstimationSession，跑在 media engine 而非 GPU）**：

- **头注释（174–176 行）**："It takes single-component luma, so each frame is converted first, and it returns backward vectors in pixels at one vector per block"
- **`ensureSession(width:height:)`（200–238 行）**：session 已有且尺寸同 → true；**"Default block size and a single search pass: a 4x4 grid measures 12x slower, which no real-time budget can absorb"**（单 pass 搜索）→ `__VTMotionEstimationSessionCreate` → **两块 OneComponent8 luma buffer（IOSurface + r8Unorm 纹理，shaderRead|shaderWrite）**
- **`prepare(width:height:)`（241–244 行）**：返回 lumaTextures[slot]（本帧 luma 转换目的地）
- **`estimate()`（247–266 行）**：current/reference 双缓冲切换（slot 翻转）→ **首帧无 reference 返回 nil（hasReference 标记）** → `__VTMotionEstimationSessionEstimateMotionVectors` + semaphore（**异步回调 + 信号量等待**）→ 返回运动向量 CVPixelBuffer
- **`texture(for:)`（268–277 行）**：运动向量 → **rg16Float MTLTexture**（IOSurface 共享）

**`FrameRingBuffer`（private final class，@unchecked Sendable，280–340 行）——帧环形缓冲**：

- **`capacity = GooseEngine.maxInFlight + 1`（= 4，285 行）**——**"The render clock samples at most one capture interval behind the newest frame, so two entries always bracket it; the rest is headroom for captures still in flight"**
- `push(_ frame:)`：lock + append + **超 capacity removeFirst**（FIFO 裁剪）
- **`getFramesForTime(targetTime:)`（297–316 行）**：找 targetTime 落在哪个相邻对（prev.timestamp <= t <= next.timestamp）→ (prev, next)；**越界回退**：t > last → (倒数第二, last)；t < 第一 → (第一, 第二)——**永不返回 nil（有 2 帧以上）**
- `newestFrame`：buffer.last（最新帧）
- **`newestPair`（328–333 行）**："**The two most recent captures. Interpolation works on this pair and no other: the midpoint MetalFX can add belongs between them, and asking for the pair directly cannot miss the way searching for a timestamp could when the estimated capture interval drifted from the real one**"

**`maxInFlight = 3`（:93）+ `inFlightSemaphore = DispatchSemaphore(3)`（:105）**——**在途帧上限（捕获处理并发 3；信号量背压：processIOSurfaceFrame 先 wait）**；`texturePoolDepth = capacity + maxInFlight`（= 7，:348——纹理池深度）。

**`EngineConfig`（private struct，365–396 行）**：bufferDepth（默认 3）/ scalingType / aaMode / qualityProfile / frameGenMode / frameGenEnabled / frameGenMultiplier / vsyncEnabled / captureCursorEnabled。

**`estimatedCaptureInterval`（399–402 行）**：捕获间隔估计（EMA 更新在 :1353：`+= (interval - est) × alpha`）；**resetProcessingState 内 :743 清零**；`measuredSourceFPS()`（:764–772）用它（1.0/interval）。

## 六、WindowCaptureManager 捕获与场景切换检测 + CaptureSettings 配置面（第 1–364、1–236 行）

**`WindowCaptureManager`（final class，1–364 行）——ScreenCaptureKit 窗口捕获管理器（引擎自带）**：`NSObject + SCStreamDelegate + SCStreamOutput + @unchecked Sendable`。

**定位（grep 实测）**：AuroraDrive 的 `GooseUpscaler` 公共门面只暴露 `make/attachToView/detachFromView/ingest/configureInterpolation/statsSnapshot/pendingError`（代码-26 单元十）——**`startCaptureFromWindow` 是 `GooseEngine` 的 internal 方法，未经门面公开**：项目实际走 `ingest(cgImage:)`（主采集管线 CaptureEngine，代码-03）；本类是 vendor 自带的捕获选项 + 一套与捕获线程同跑的**场景切换检测器**（插帧模式的 `isSceneCut` 输入）。

**并发与配置锁（12–26 行）**：

| 成员 | 说明 |
|---|---|
| `captureQueue`（"com.metalgoose.capture"，qos .userInteractive） | SCStream 样本回调专用线程 |
| `configLock`（OSAllocatedUnfairLock）+ 6 个锁内字段 | _basePixelSize / _currentRenderScale / _capturePixelSize / _maxFPS / _showsCursor / _queueDepth——**源注释（18–19 行）："startCapture and updateRenderScale are nonisolated async, so they do not run on the main thread, while the HUD reads capturePixelSize from it"** |
| `capturePixelSize`（30–34 行） | 计算属性，锁内读——**"The compositor does the downscale, so nothing further down the pipeline pays for it"**（合成器侧完成降采样） |
| `nativePixelSize`（38–42 行） | render scale 之前的窗口像素尺寸——**"Frame generation runs here so that lowering render scale cannot degrade it"**（插帧永远跑在原生分辨率） |

**`backingScale(for:)`（static，57–67 行）**：Cocoa 坐标翻转（primaryHeight - maxY）→ 找 intersect 的 NSScreen → backingScaleFactor；**源注释（54–56 行）："A missing screen means there is nothing to capture from, so 1.0 — unscaled — is the only neutral answer; assuming Retina would silently double the capture resolution"**（无屏兜底 1.0，不许瞎猜 Retina）。

**`minimumCaptureDimension = 16`（69–71 行）**：**"MetalFX will not build a scaler below this"**——render scale 缩小的硬下限。

**`makeConfiguration(renderScale:)`（73–104 行）——SCStreamConfiguration 构造**：

- scaled = base × renderScale（向下钳到 16）→ 写回 _capturePixelSize/_currentRenderScale
- maxFPS > 0 → `minimumFrameInterval = CMTime(1, maxFPS)`（帧间隔下限）
- `kCVPixelFormatType_32BGRA` + showsCursor + **queueDepth 源注释（94–96 行）："ScreenCaptureKit's queue and the render pipeline's buffer depth are the same decision — a deeper capture queue than the pipeline will drain only adds latency"**（采集队列深度 = 管线缓冲深度，同一决策）
- `captureResolution = .best` / `shouldBeOpaque = false` / 背景 clear

**`updateRenderScale(_:)`（109–122 行）——热重配**：`stream.updateConfiguration(config)`（不停流换配置）；失败 → **MG-CAP-007**；**源注释（106–108 行）："The frames arrive already reduced, so the GPU never encodes a downscale pass and every later stage — including the CPU surface scan — works on proportionally fewer pixels"**（在源头降采样：连 CPU 场景检测扫描都跟着省像素）。

**`startCapture(windowID:maxFPS:showsCursor:renderScale:queueDepth:)`（124–171 行）**：

1. `await stopCapture()`（先停旧流）
2. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` → 按 windowID 找目标窗，找不到 → **MG-CAP-001 "Target window not found"**
3. `SCContentFilter(desktopIndependentWindow:)`（桌面无关窗口过滤）
4. base = 窗 frame × backingScale → 6 字段锁内写入
5. `SCStream(filter:configuration:delegate:)` + `addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)` + `startCapture()`
6. **检测状态全清零**（hasLastSignature/lastLumaGrid/changedFractionEMA/VarEMA/cutWarmupRemaining——**新流不继承旧统计**）

**`stopCapture()` / `didStopWithError`（173–196 行）——-3808 吞错**：`SCStreamErrorDomain -3808`（对未启动流调用 stop 的竞态）→ **不记错误**；其他 → **MG-CAP-003**（stop）/ **MG-CAP-004**（stream stopped，delegate 回调）。

**`didOutputSampleBuffer`（198–228 行）——样本回调唯一入口，五级过滤**：

| 步 | 条件 | 说明 |
|---|---|---|
| 1 | `type == .screen` | 只处理屏幕样本 |
| 2 | **SCStreamFrameInfo.status == .complete** | **不完整/损坏帧静默丢弃（不回调、不计数）** |
| 3 | `CVPixelBufferGetIOSurface` 非 nil | 取 IOSurface（共享内存直通） |
| 4 | **signature == lastFrameSignature → 整帧丢弃** | **重复帧（画面没变）不进下游——静止画面零成本** |
| 5 | `isSceneCut(previous:current:)` → `onFrameReceived(surface, pixelBuffer, timestamp, isSceneCut)` | 场景切换判定随帧下发 |

**`frameSignatureAndLuma(_:)`（static，230–288 行）——64×64 固定预算双输出采样**：

- **源注释（240–244 行）："A fixed sample budget, deliberately not derived from the frame size: this runs on the capture thread for every frame, so its cost must stay flat as resolution rises"**（成本与分辨率无关——升 4K 采样代价不变）
- **双输出要相反的东西（248–256 行）**："The hash wants the sharpest sample it can get, so it reads the grid point itself. The luma statistic feeds a scene-cut test and wants the opposite: a single pixel per grid point aliases badly once the frame is much larger than the grid, and detail finer than the sample spacing — a pixel-scale checkerboard, dense text — swings a sample the full range as it moves, which reads as a cut in content that never cut. **Averaging a small block around each point resolves that structure into its mean**, at a cost that is still a constant multiple of the grid rather than of the frame."
  - **hash = FNV-1a**（种子 `0xcbf29ce484222325`，素数 `0x100000001b3`）：读网格点本身 BGRA 4 字节拼 UInt32（`px[0]|px[1]<<8|px[2]<<16|px[3]<<24`——32BGRA 小端内存序 B,G,R,A）
  - **luma 网格**：每网格点取 4×4 块（blockSpan=4，边缘 clamp）平均 `(B×54 + G×183 + R×19) >> 8`（**BT.709 系数 ÷256**：R 0.2126/G 0.7152/B 0.0722）
- 网格坐标：`y = (height-1) × gy / (gridY-1)`（**首末像素都对齐，64 点跨满全帧**）

**`isSceneCut(previous:current:)`（313–355 行）——帧间变化离群点检测（三常量自适应）**：

| 常量 | 值 | 语义（源注释） |
|---|---|---|
| `cutSigma` | 6.0 | 超过运行均值 + 6σ 才算 cut |
| `minCutChange` | 0.125 | **下限**："A cut replaces the image, so it moves a large fraction of the grid a long way; ordinary camera motion does not reach a mean absolute luma change of an eighth of full range. **Without a floor, an estimator whose variance has not grown yet puts the threshold at the mean and calls every above-average frame a cut**" |
| `cutWarmupFrames` | 30 | **"so the spread is measured rather than assumed"**（预热期内只学不报） |

- **算法（290–298 行源注释）**："A cut is an outlier in how much the frame changed, so it is detected as one: the mean absolute luma change over the sample grid is tracked with a running mean and variance, and a frame is a cut when it sits more than `cutSigma` standard deviations above that. **This replaces a per-cell threshold plus a floor plus a cap, which were three fixed numbers that fought the adaptive part** — content whose normal motion sat above the floor could never register a cut, and content quieter than the cap could never clear it."
- `change = Σ|current - previous| / (count × 255)`（**对全 luma 范围归一到 0–1，不随网格尺寸/位深漂移**）
- `threshold = max(0.125, mean + 6 × √var)`；`isCut = 预热完成 && change > threshold`
- **⚠️ 坑位（336–347 行源注释，本文件最重要的调参事故记录）**："Every frame updates the baseline, but a cut enters it held at the threshold rather than at its own value: it must not pull the mean up behind it, or the frames after a transition inherit its statistics and the next cut is missed. **Skipping the update entirely — which is what this did — censors the sample down to the frames that passed the test. The spread then gets measured from the quiet half alone, so it collapses toward zero, the threshold collapses onto the mean, and from there every frame that moves more than average is a cut. In gameplay that is about half of them, which is what killed interpolation: the schedule reached the generator and was turned away at the cut check.**"——旧版"cut 帧跳过 EMA 更新"导致样本被审查成安静的一半 → 方差塌缩 → 阈值塌到均值上 → **游戏里约一半帧被误判为 cut，插帧被挡在检测门外**；现行方案 `observed = min(change, threshold)` 钳在阈值上进基线
- **`emaAlpha`（360–363 行）**：`1 / max(8, fps)`——**源注释（357–359 行）："The baseline spans roughly one second of capture whatever the frame rate is, instead of a fixed number of frames that means half a second at 20 fps and a tenth of one at 120"**（基线时间窗恒 ≈1s，不随帧率变语义）

**喂帧链（Engine/GooseEngine 第 1888–2057 行）——捕获帧如何进引擎**：

| 方法 | 行为 |
|---|---|
| `startCaptureFromWindow(_:)`（1888–1909 行） | resetProcessingStateAsync(clearFrames: true) + resetFrameCounters + resetErrorReporting + applyBufferDepth(config.bufferDepth) → 持有 manager → **onFrameReceived → processingQueue.async → processIOSurfaceFrame**（1895–1902 行；`processIOSurfaceFrame` 定义 :1911–1916：inFlightSemaphore.wait() → updateCaptureStats → processSurface） |
| `stopCapture()`（1918–1925 行） | onFrameReceived = nil + manager 释放——**源注释（1922–1924 行）："The ring holds a texture from the pool for every entry; leaving them there keeps the whole pool alive until the next capture overwrites it"** → resetProcessingStateAsync(clearFrames: true) |
| `updateSettings` 模式切换计数清零（1869–1885 行；方法体 1827–1886） | **源注释（1869–1873 行）："across a mode switch mixes two schedules into one set of totals and the generated/passthrough split stops meaning anything"** → frameGenMode 或 frameGenMultiplier 变化 → 6 个计数（droppedFrames/frameCount/outputFrameCount/interpolatedFrameCount/passthroughFrameCount/generatedFrameCount）清零 + lastPresentedCaptureTimestamp = -1 |
| **`ingest(cgImage:)`（1930–1997 行，AuroraDrive 扩展）** | 头注释（1927–1929 行）："把外部已捕获帧(CGImage)注入显示链路……避免 AuroraDrive 再起一路 ScreenCaptureKit。仅用于『给人看的显示叠加层』"；CGImage → CVPixelBuffer（BGRA + IOSurface 属性）→ CGContext（premultipliedFirst + byteOrder32Little）→ processSurface(isSceneCut: **false**——ingest 路径无场景检测，固定 false)；**⚠️ 坑位（1990–1994 行源注释）："若这里不更新估计器，估计区间恒为 0 → delay=输出间隔 → targetTime 永远贴在最新帧之后 → phase 恒判 1（纯透传，插帧不产帧）。这正是 APP 经 ingest 喂帧时插帧失效的根因"** → 故 :1995 显式 `updateCaptureStats(currentTime:captureTimestamp:)`；错误码 MG-ENG-EXT-001~004（CVPixelBufferCreate/IOSurface/MTKView ready/drawableSize） |

**`CaptureSettings`（final class ObservableObject，1–236 行）——配置面 + 持久化**：

- `nonisolated(unsafe) static let shared` 单例 + 12 个 `@Published`（didSet 自动 store）
- **枚举表**：

| 枚举 | 值 | 用途 |
|---|---|---|
| `RenderScale` | native/p75/p67/p50/p33（multiplier 1.0/0.75/0.67/0.50/0.33） | 合成器侧捕获降采样 |
| `ScalingType` | off / mgup1 | 空间超分（MGUP-1）开关 |
| `QualityMode` | performance / balanced / ultra | 映射 QualityProfile |
| `ScaleFactorOption` | 1.0x/1.5x/2.0x/2.5x/3.0x/4.0x/5.0x/6.0x/8.0x/10.0x/fullscreen（`fillsScreen`——"aspect ratio follows the screen rather than the source window"） | 显示放大 |
| `FrameGenMode` | off / interpolation（"MGFG-1-Interpolation"）/ extrapolation（"MGFG-1-Extrapolation"） | 帧生成模式 |
| `AAMode` | off / fxaa / smaa | 抗锯齿 |

- **⚠️ 插帧/外推倍率互斥约束（77–94、115–135 行）**："MetalFX interpolation synthesises exactly one image per frame pair — the midpoint — **so interpolation is 2x and cannot be anything else**. The warp used by extrapolation takes a continuous phase, so it can be sampled at as many points in the gap as asked for." → `maxFrameGenMultiplier(for:)`：off→`minFrameGenMultiplier`（=2 存储下限）/ **interpolation→固定 2** / **extrapolation→4**；`effectiveFrameGenMultiplier`：**off→1；否则 clamp(stored, 2, modeMax)**——**源注释（109–111 行）："Stored raw and clamped on read, so switching to interpolation and back does not destroy an extrapolation setting the user chose"**（原始存储、读时钳制，来回切换不毁用户设置）
- **持久化（147–204 行）**：UserDefaults + 前缀 **`"MetalGoose."`**；`isRestoring` 标志（init 内 restore 赋值不写回）；**源注释（186–188 行）："An unrecognised stored value means the option was renamed or removed, so the current default stands rather than a forced fallback elsewhere"**（`T(rawValue:)` 失败 → 当前默认值，不做强制迁移）
- **`QualityProfile`（207–236 行）**：

| QualityMode | sharpnessScale | aaThreshold | smaaSearchSteps |
|---|---|---|---|
| performance | 0.8 | 0.18 | 8 |
| balanced | 1.0 | 0.12 | 12 |
| ultra | 1.2 | 0.08 | 16 |

- **⚠️ 共享持久化（grep 实测）**：根层 `Vendor/MetalGoose/ContentView.swift`（不编译）与 Engine/ 子集（编译）持有**同一个** `CaptureSettings.shared` + 同一 UserDefaults 前缀——**根层独立 MetalGoose.app 与 AuroraDrive 对配置的修改互相可见**；AuroraDrive 侧唯一入口是 `GooseUpscaler.configureInterpolation()`（GooseUpscaler.swift 54–61 行：scalingType=.off + aaMode=.off + frameGenMode=.interpolation + multiplier=2 → `engine.updateSettings(settings)`——**注释："it does not touch any vendored source"**）

**MG-CAP 错误码（grep 实测）**：001（目标窗口未找到）/ 002（SCStream start 失败）/ 003（stop 失败，-3808 除外）/ 004（流停止错误，-3808 除外）/ **005（仅根层 ContentView 660 行："Target entered macOS fullscreen, which cannot be captured with the overlay. Please use windowed or borderless (windowed fullscreen) mode."——Engine/ 子集没有全屏检查）**/ 007（重配失败）；**MG-CAP-006 全仓库无出现（编号空洞）**。

---

## 七、⚠️ GPL v3 强传染——分发二进制时的强制义务（2026-10-18 补）

> **本节原文完全缺失**，是本文最严重的遗漏。前面六节都在讲"引擎怎么工作"，但没讲"用了它会背什么法律义务"。

**事实认定（三条，全部可复核）：**

| # | 事实 | 证据 |
|---|---|---|
| ① | MetalGoose 是 **GPL v3** | `Vendor/MetalGoose/LICENSE` 首行：`GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007` |
| ② | **源码已进 `sources:` 编译**，不是"只放个参考" | `Package.swift:182-185`：`sources: ["Sources/AuroraDrive", "Vendor/MetalGoose/Engine"]` |
| ③ | 因此是**链接式衍生作品** | SwiftPM 把 Engine/ 的 5 个 .swift 编进 `AuroraDrive` 同一个 module，与主代码同一二进制 |

**结论（与 `docs/整合文档/09-模型资产与第三方依赖.md` §4.2 口径一致）**：

> 按 GPL v3 定义，**链接 GPL 代码的衍生作品整体必须以 GPL v3 发布并提供对应源码**。
> 因此 AuroraDrive 若要**分发二进制**，**整体须按 GPL v3 开源**——这不是「放个 LICENSE 文件」能了事，
> 而是**整套 `Sources/` 都要可公开获取**。

**当前的现实状态**：本仓库根 `NOTICE` 写的是 `Copyright (C) 2026 DuoduoChubbyKitty`（自有版权声明），
而分发物里链接着 GPL v3 代码。**这两者是否已协调好，属于产品/法务决策，不是本文能判定的**——
⚠️ **待确认**：若要对外分发 `AuroraDriveUI` 二进制，需先确认整体许可口径（GPL v3 双许可 / 停止分发 / 移除 MetalGoose）。

**未受影响的边界（常见误解澄清）**：

- `Stubs.swift`（16 行）是 **AuroraDrive 自有代码**，源码注释明确写 *"This file is AuroraDrive's own addition and is NOT part of the upstream GPL v3.0 source"* ——它不受 GPL 约束，但它与 GPL 代码在同一 module 里，**不改变整体传染结论**。
- **根层 15 个文件不参与编译**（`Package.swift:163-178` exclude）——根层的 `ContentView.swift` / `MGHUD.swift` / `OverlayWindowManager.swift` 等**不构成衍生作品**，但 Engine/ 子集构成。

## 八、`Shaders.metal` 不参与编译（2026-10-18 补强）

原文 §一 已提到「Shaders.metal 运行时编译」，但没点明它在 `Package.swift` 里的处置。补三点：

1. **两份都被显式 exclude**：根层 `Vendor/MetalGoose/Shaders.metal`（`Package.swift:176`）+ Engine/ `Vendor/MetalGoose/Engine/Shaders.metal`（`:178`）。
2. **466 行 / 17,016 字节**，两份内容完全相同（`diff` 零差异）——原文此结论今日复核仍成立。
3. **运行时按路径加载**，三候选路径见 §一 `setupPipelines`（441–481 行）：`Bundle.main` → 可执行文件目录（`exeDir/Shaders.metal`、`exeDir/Vendor/MetalGoose/Engine/Shaders.metal`、以及一条硬编码绝对路径 `/Users/dupi/Desktop/自动驾驶系统/Vendor/MetalGoose/Engine/Shaders.metal`）→ `makeDefaultLibrary()` 兜底。
   ⚠️ 那条硬编码绝对路径是 vendor 原样保留的（换机器会失效，但只是三候选之一，不影响功能）。

**为什么它不参与编译**：SwiftPM 不会把 `.metal` 自动编成 `default.metallib`（GooseEngine 源注释原文："SwiftPM does not auto-compile .metal into a default.metallib, so compile Shaders.metal from source at runtime"）。项目改用 `run.sh:121-130` 预编译（`xcrun metal -c ... -o /tmp/Shaders.air` → `metallib`），产物双路径部署到 bundle `Contents/Resources/` 与项目根；**编译失败不阻塞部署**，回退运行时编译（功能零损失，只多 100ms-1s 启动开销）。

---

**代码-32 文档至此完整**（六单元，覆盖 Engine/ 全部 6 文件 3246 行：GooseEngine 2057 + WindowCaptureManager 364 + Shaders.metal 466 + CaptureSettings 236 + GooseUpscaler 107 + Stubs 16；另述根层 4687 行不参与编译的原版应用）