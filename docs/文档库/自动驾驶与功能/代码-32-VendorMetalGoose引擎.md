# 代码-32 Vendor/MetalGoose Metal 引擎

> 覆盖源文件：`Vendor/MetalGoose/Engine/`（6 文件 3161 行）：GooseEngine.swift（1988 行）+ CaptureSettings.swift（236）+ GooseUpscaler.swift（91，代码-26 单元十已详）+ WindowCaptureManager.swift（364）+ Shaders.metal（466）+ Stubs.swift（16）。基于当前仓库逐单元编写。

## 一、GooseEngine 类头与管线建立（第 1–537 行）

**文件定位**：MetalGoose——上游 vendor 的 Metal 插帧/超分引擎（**byte-for-byte 保留，成员 internal**）；GooseUpscaler 是薄封装门面（public，代码-26 单元十）。**架构注（GooseUpscaler 12–14 行）**：喂到这里的帧只走显示/叠加路径；capture → CoreML 推理 → 按键注入决策链路永不经过本引擎。

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

**`setupPipelines()`（private，第 440–521 行）——着色器编译与 10 条管线：**

- **⚠️ Shaders.metal 运行时编译（441–466 行注释，代码-26 单元十已详）**："SwiftPM does not auto-compile .metal into a default.metallib, so compile Shaders.metal from source at runtime. Falls back to makeDefaultLibrary() when a prebuilt metallib happens to be present"——三候选：Bundle.main（Xcode Run）/ **可执行文件目录**（exeDir/Shaders.metal、exeDir/Vendor/MetalGoose/Engine/Shaders.metal、**硬编码 /Users/dupi/Desktop/自动驾驶系统/Vendor/MetalGoose/Engine/Shaders.metal**）→ makeDefaultLibrary 兜底
- **8 个 compute 管线（477–485 行）**：`contrastAdaptiveSharpening`（CAS 锐化）/ `copyTexture` / `bgraToLuma` / `extrapolateFrame` / `fxaa` / `smaaEdgeDetection` / `smaaBlendingWeights` / `smaaBlend`——**失败不崩（try? 静默 nil，reportError 记录）**
- **render 管线（487–518 行）**：texture_vertex/texture_fragment（bgra8Unorm）+ **cursor_vertex/cursor_fragment（**isBlendingEnabled + add 混合 + sourceAlpha → oneMinusSourceAlpha——光标 alpha 混合**，MG-ENG-011）**
- `loadCursorTexture()（523–537 行）`：**NSCursor.arrow.image** → MTKTextureLoader（SRGB false + shaderRead + private 存储）——**用系统箭头光标做合成光标纹理**

**错误码体系（grep 实测）**：MG-ENG-001（管线建立失败）/ 002（无 Metal 设备）/ 003（无命令队列）/ 010（MetalFX 插值器创建失败）/ 011（光标管线失败）/ EXT-001~004（ingest 扩展：CVPixelBufferCreate/IOSurface/MTKView/drawableSize）——**显式暴露"插帧为何静默不产帧"的根因**（pendingError 消费）。

## 二、Vendor 两层结构与关键常量

**⚠️ Vendor/MetalGoose 有两层（本机验证）：**

| 层 | 文件 | 总行数 | 状态 |
|---|---|---|---|
| **根层**（原版完整 goose 应用） | AutoUpdater(310)/CaptureSettings(236)/ContentView(**891**)/GlobalHotkeyManager(74)/GooseEngine(**1890**)/LICENSE/Localizable.xcstrings/MGHUD(**409**)/MetalGooseApp(10)/NOTICE.md/OverlayWindowManager(**503**)/README.md/Shaders.metal(468)/WindowCaptureManager(364) | 4687 | **原版独立 MetalGoose.app（插帧超分应用），不参与 AuroraDrive 编译（⚠️ 2026-09-20 起 Package.swift `exclude` 已显式列出根层这 15 个文件，消除 unhandled 告警；sources 白名单始终未列根层）** |
| **Engine/ 子目录**（AuroraDrive 编译子集） | GooseEngine(**1988**)/CaptureSettings(236)/GooseUpscaler(91)/Shaders.metal(466)/Stubs(16)/WindowCaptureManager(364) | 3161 | **Package.swift sources 白名单 84–88 行列 5 个 .swift——AuroraDrive 只用 Engine/ 子集** |

- **Engine/ 版 GooseEngine 比根层多 98 行**（1988 vs 1890）：AuroraDrive 扩展（`public func ingest` + updateCaptureStats 调用 + 错误码 EXT 系列）
- **Shaders.metal 两份**（根层 468 / Engine/ 466）——几乎一致；**运行时编译读的是 Engine/ 那份**（候选路径 ②③）
- **`Stubs.swift`（Engine/ 独有，16 行）**："Minimal stub for MetalGoose's `MouseConstraintManager` (cursor-drawing helper). **The full implementation lives in MetalGoose's OverlayWindowManager.swift and is intentionally NOT vendored.** GooseEngine only requires this single accessor on the display path, so a trivial stub is sufficient. **This file is AuroraDrive's own addition and is NOT part of the upstream GPL v3.0 source**"——**`currentCursorFraction()` 恒返回 (0.5, 0.5)（屏幕中心）：合成光标永远画在 drawable 中心**（不追踪真实鼠标——显示路径不需要）

**关键常量（grep 实测）**：`maxInFlight = 3`（在途帧上限）/ `measurementWindow = 0.5`（测量窗口，5 处使用：帧率偏好节流:808 / 历史容量:939 / pllGain:952 / EMA alpha:1336 / CPU 采样节流:1384）/ `minFrameTimeSamples = 8`（统计下限）/ `frameTimeHistoryCapacity`（refreshRate × 0.5 动态）/ `texturePoolDepth = capacity + maxInFlight`（= 7）。

**`interpolationDelay(outputInterval:mode:)`（private，第 839–846 行）——插帧目标时间回退量**：

| mode | delay | 语义 |
|---|---|---|
| `.interpolation` | `max(outputInterval, captureInterval)` | **插帧模式：目标时间回退一个输出间隔（取两帧之间括号中部）** |
| `.extrapolation` | **0** | 外推模式：目标时间 = 当前（最新帧之后外推） |
| `.off` | `max(outputInterval, captureInterval)` | 关闭（同插帧——直通时也要找对帧） |

**`applyBufferDepth(_ depth:)`（private，第 850–863 行）——"Emulates a shallower pipeline by parking permits on processingQueue rather than replacing the semaphore out from under in-flight frames"**：

- `wanted = maxInFlight - clamp(depth, 2, maxInFlight)`——**目标在途深度**
- processingQueue 异步：**parkedPermits < wanted → 逐个 wait（park 信号量）；> wanted → 逐个 signal（归还）**——**模拟浅管线：不动在途帧的信号量，靠停票/还票调深度**

**`pllGain(outputInterval:)`（950–953 行）**：`min(1, outputInterval / measurementWindow)`——**一阶环增益：相位误差每输出帧衰减该比例；固定增益在 480Hz 面板快 4 倍、30fps 慢 4 倍——按视图实际速率自适应**。

## 三、帧率偏好与捕获处理管线（第 780–846、1409–1647 行）

**`desiredOutputFPS(_ config:)`（private，第 780–798 行）——目标输出帧率**：

- `requested = frameGenEnabled ? currentRefreshRate : (sourceFPS > 0 ? sourceFPS : currentRefreshRate)`——**插帧开 → 冲到刷新率；关 → 跟捕获帧率**
- `target = vsync ? snapToRefreshDivisor(requested) : rounded`（**vsync 开 → 吸附到刷新率整数因子**，snapToRefreshDivisor 759 行）
- **钳制（788–797 行）**：target = min(target, currentRefreshRate)；**"A variable-refresh panel cannot be driven below its own floor"——minRefreshRate < currentRefreshRate 且 target < minRefreshRate → target = minRefreshRate**（可变刷新面板不能低于自身下限；固定面板无下限要尊重）
- 返回 max(1, target)

**`applyFrameRatePreference(_ preferred:)`（private，第 805–817 行）**：

- **节流（808 行）**：`now - lastPreferredUpdateTime < measurementWindow → return`——**"The target is derived from a filter that settles over one measurement window, so it cannot honestly change faster than that——re-tuning more often only resets CADisplayLink's pacing. The window is the whole hysteresis"**
- `lastPreferredFPS = preferred` + 主线程异步 `view?.preferredFramesPerSecond = preferred`

**`applyDisplaySync(to:vsync:)`（819–825 行）**：CAMetalLayer——**displaySyncEnabled = vsync + presentsWithTransaction = false**。

**`processSurface(_ surface:pixelBuffer:timestamp:isSceneCut:)`（private，1409–1427 行）**：IOSurface → **bgra8Unorm MTLTexture（shaderRead，IOSurface 共享零拷贝）**——失败 → "MG-ENG-008 IOSurface texture creation failed" + **inFlightSemaphore.signal()（背压归还，防卡死）**。

**`processCapturedTexture(_ inputTex:pixelBuffer:timestamp:isSceneCut:)`（private，1429–1571 行）——捕获处理管线（CAS/AA/还原 → ring）：**

1. **信号量背压（1430–1439 行）**：commandBuffer nil → signal + return；**addCompletedHandler 里 signal——GPU 完成才归还（在途帧上限 3）**
2. **尺寸还原（1443–1462 行）**："ScreenCaptureKit now delivers the render resolution directly……**Render scale reduces the capture, but frame generation must not inherit that reduction: interpolation and the motion field would then work on a fraction of the pixels and smear. Bring the frame back to the window's native size first**"——`restoreActive = scalingType == .mgup1 && native >= input + 1` → width/height 用 native；**尺寸变化 → resetProcessingState(clearFrames: true)**
3. **ring 槽位（1468–1479 行）**：**"Every scratch texture is reused next frame, so the LAST active stage writes straight into the ring slot; a passthrough config needs a copy"**——`historyTextureIndex % count` 轮换 → ensureTexture（shaderRead|shaderWrite|renderTarget）——失败 → droppedFrames += 1 + commit
4. **还原执行（1483–1505 行）**：restoreActive → ensureSpatialScaler（captureScaler）→ scaler.encode（workingTex = destination；CAS/AA 活跃时写 scratch，否则直写 historyTex）
5. **CAS 锐化（1507–1534 行）**：sharpness > 0.01 → casPipeline + SharpenParams → dispatchThreads（**AA 活跃写 scratch 否则直写 historyTex**）；失败 "MG-ENG-007 CAS pipeline unavailable"
6. **AA（1536–1554 行）**：encodeAntiAliasing（mode/profile）→ 失败 droppedFrames；**全关（restoreActive 也关）→ encodeCopy 直写**
7. **captureGPUTime（1556–1563 行）**：completedHandler 里 gpuTime 记录
8. **motion（1565–1567 行）**：**extrapolation 模式才 encodeMotion（插帧不需要运动场——MetalFX 自带）**
9. **`frameBuffer.push(FrameHistory(...))`（1569–1570 行）**——**进环形缓冲（每帧入 ring）**

**`encodeMotion(from:width:height:)`（private，1573–1603 行）——运动场编码（luma → media engine → slot）**：

- **头注释（1573–1575 行）**："Converts the frame to luma, hands it to the media engine, and copies the resulting vectors into a slot we own——**VideoToolbox recycles its own buffers, and the ring holds each field until the frame leaves it**"
- **luma 转换（1577–1586 行）**：lumaPipeline + motionEstimator.prepare（slot 目的地）→ dispatchThreads
- **异步 estimate（1588–1600 行注释）**："**VideoToolbox reads the IOSurface outside Metal's ordering, so the estimate has to follow the write——but waiting for it here would serialise the capture pipeline, so it runs on the completion handler and the result is picked up by the next frame instead**"——completedHandler → processingQueue → `motionEstimator.estimate()` → `storeMotion(field)`——**结果下一帧才可用（首帧 latestMotion() 为 nil）**
- 返回 `latestMotion()`（最新运动场）

**`storeMotion(_ field:)`（1605–1628 行）——"Copies the estimator's output into a slot we own, since VideoToolbox recycles its buffers while the ring still references the field"**：motionTextureIndex 轮换 → ensureTexture（**rg16Float，shaderRead|shaderWrite**）→ **blit 拷贝**（field → destination）→ motionLock 内 `_latestMotion = destination`——**自有槽位持有，不受 VideoToolbox 回收影响**。

**`latestMotion()`（1630–1634 行）**：motionLock 内返回 `_latestMotion`。

**`SharpenParams`（1636–1638 行）**：sharpness（Float）；**`AntiAliasParams`（1640–1643 行）**：threshold/maxSearchSteps（FXAA/SMAA 参数）。

## 四、renderFrame 主渲染循环（第 956–1233 行）

**`draw(in view:)`（nonisolated，913–917 行）**：MTKViewDelegate 入口——`MainActor.assumeIsolated { renderFrame(in: view) }`——**非隔离回调假设主线程隔离（MTKView 在主线程驱动）**。

**drawable 死锁根因（957–967 行注释，本文件最重要的工程注解）**：

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

**renderFrame 流程（956–1233 行）**：

1. **入口 guard（968–972 行）**：view.window != nil + drawableSize > 0 + renderPipeline + commandBuffer——**先确认有地方呈现，再做不需要 drawable 的工作**
2. **frameGenNeedsTeardown（979–993 行）**：锁内取标志 + 清零 → **teardown 在渲染线程执行（"every MetalFX frame-gen object lives and dies on this thread"）**：frameInterpolator/spatialScaler/纹理/缓存时间戳全清
3. **帧间隔历史（995–1002 行）**：outputFrameTimeHistory.append + 超容量 removeFirst——**实际驱动速率的滚动平均**
4. **目标帧率（1007–1011 行）**：desiredOutputFPS + applyFrameRatePreference + _stats.targetOutputFPS
5. **采样时钟（1013–1036 行）**："**The frame clock has to advance at the rate the view is actually being driven at. preferredFramesPerSecond is only a hint——a ProMotion panel happily runs the callback at 120 while we asked for 60——and a clock built on the requested rate runs ahead of real time, pushes targetTime past the newest captured frame, and turns every frame into passthrough**"——measuredInterval（≥8 样本才用均值）→ nominalInterval；**"Several frames' worth of deviation is a stall, not phase error a first-order loop should chase; resynchronise instead of crawling back"**——偏差 > 3×nominalInterval → 重同步（pllPhase = currentTime）；否则 PLL 一阶推进（`advanced + phaseError × pllGain`）
6. **targetTime（1038 行）**：`sampleClock - interpolationDelay(...)`——**插帧模式下时钟回退一个间隔**

**三种帧生成模式分支（1040–1138 行）：**

| 分支 | 条件 | 输出 |
|---|---|---|
| **外推 extrapolation**（1047–1083 行） | frameGenMode == .extrapolation + newest 帧存在 | **"The multiplier is how many images the gap should carry, so the gap is cut into that many slots: slot 0 is the captured frame itself and each later slot is one warp phase. Letting every present pick its own continuous phase ignored the multiplier entirely"**——`steps = max(1, multiplier); rawPhase = clamp((currentTime - newest.timestamp)/interval, 0, 1); step = min(steps-1, Int(rawPhase × steps))`；**"A capture that has not been shown yet is always presented as it was captured. Only the gaps between captures are generated——warping real frames as well destroys the image for no benefit"**：newest 未呈现 → 直出；step > 0 且非场景切换且有 motion → `encodeExtrapolation`（warp 前向）；否则直出 |
| **插帧 interpolation**（1084–1133 行） | frameGenMode == .interpolation + getFramesForTime(targetTime) 命中 + 双帧同尺寸 | `duration = next - prev; t = clamp((targetTime - prev)/duration, 0, 1)`；**"MetalFX synthesises exactly one phase between a pair——the midpoint——so the images available for this bracket are prev at 0, the generated frame at 0.5 and next at 1. Each sample is served by whichever of those sits closest to it, which puts the boundaries at 0.25 and 0.75 for free"**——`phase = (t × 2).rounded() / 2`（0/0.5/1 三档）：phase==0 → prev 直出；==1 → next 直出；**next.isSceneCut → 直出 + history reset**；否则 `interpolateFrame(prev:next:)`（MetalFX 中点合成）；**"The generated frame stands for targetTime, not for prev——using prev here overstated latency by up to a whole capture interval"**——sourceTimestamp = next.timestamp；**contentKey = prev + next（"MetalFX yields one image per frame pair, so the pair identifies the content however many times it is presented"）** |
| **else 直通**（1134–1138 行） | 其他 | newest 帧直出 |

**输出编码（1140–1233 行）：**

1. `guard finalTex` → commit + return（无帧）
2. **`encodeUpscale`（1145–1149 行）**——**"Spatial upscale lives on the render path so that frame interpolation can run at capture resolution. Interpolation cost scales with pixel count, so paying for one upscale per presented frame is far cheaper than making every generated frame an output-resolution interpolation"**
3. **presentLatency（1154–1160 行）**：`(currentTime - sourceTimestamp) × 1000` → presentLatency + **endToEndLatency = captureLatency + presentLatency**
4. **计数（1162–1168 行）**：renderFrameCount/isInterpolated/generatedNewImage——**"Only a cache miss put a new image on screen. Counting every present that carried generated content instead reported the same synthesised image once per present, which at 120 Hz over a 15 fps capture inflated the figure by roughly the refresh ratio"**
5. **1s 节流统计（1169–1180 行）**：outputFPS/generatedFPS + **updateFramePacingStats()**
6. **drawable 最后获取（1182–1187 行）**："**Last possible moment: everything above is encoded and the only thing left is the pass that writes into the drawable and presents it**"——`guard view.currentDrawable` → commit + return
7. **渲染 pass（1189–1205 行）**：clear→store + **presentTex 全屏 triangleStrip 4 顶点** + **captureCursorEnabled → drawSyntheticCursor**
8. **present + 完成统计（1209–1232 行）**：`commandBuffer.present(drawable)` + addCompletedHandler——**"Interpolation and the upscale live here now, so the capture buffer alone no longer represents the pipeline's GPU cost"**：gpuTime = captureGPUTime + renderGPU；**outputFrameCount += 1 + frameGenActive ? (interpolated ? interpolatedFrameCount : passthroughFrameCount) : passthroughFrameCount**——**present 侧计数（与 render 侧分开）**

**`drawSyntheticCursor`（@MainActor，1274–1297 行）——合成光标绘制**：

- `guard cursorPipeline/cursorTexture/... /MouseConstraintManager.shared.currentCursorFraction()`——**stub 恒 (0.5, 0.5)（屏幕中心）**
- **NDC 换算（1283–1288 行）**：`backingScaleFactor`（默认 2.0）→ `widthNDC = 纹理宽 × scale / drawable × 2` → `centerX = -1 + 2 × fraction.x`（**NDC [-1,1]**）→ CursorUniforms → setVertexBytes + setFragmentTexture + triangleStrip 4 顶点

## 五、帧缓冲环与 MotionEstimator（第 165–408 行）

**`FrameHistory`（struct，165–172 行）——帧历史条目**：texture（MTLTexture）/ timestamp / isSceneCut / **motion: MTLTexture?（"Backward motion against the previous frame, in pixels, one vector per 16x16 block. Only produced in extrapolation mode"）**。

**`MotionEstimator`（private final class，174–278 行）——运动估计器（包装 VTMotionEstimationSession，跑在 media engine 而非 GPU）**：

- **头注释（174–176 行）**："It takes single-component luma, so each frame is converted first, and it returns backward vectors in pixels at one vector per block"
- **`ensureSession(width:height:)`（200–238 行）**：session 已有且尺寸同 → true；**"Default block size and a single search pass: a 4x4 grid measures 12x slower, which no real-time budget can absorb"**（单 pass 搜索）→ `__VTMotionEstimationSessionCreate` → **两块 OneComponent8 luma buffer（IOSurface + r8Unorm 纹理，shaderRead|shaderWrite）**
- **`prepare(width:height:)`（241–244 行）**：返回 lumaTextures[slot]（本帧 luma 转换目的地）
- **`estimate()`（247–266 行）**：current/reference 双缓冲切换（slot 翻转）→ **首帧无 reference 返回 nil（hasReference 标记）** → `__VTMotionEstimationSessionEstimateMotionVectors` + semaphore（**异步回调 + 信号量等待**）→ 返回运动向量 CVPixelBuffer
- **`texture(for:)`（268–277 行）**：运动向量 → **rg16Float MTLTexture**（IOSurface 共享）

**`FrameRingBuffer`（private final class，@unchecked Sendable，280–330 行）——帧环形缓冲**：

- **`capacity = GooseEngine.maxInFlight + 1`（= 4，285 行）**——**"The render clock samples at most one capture interval behind the newest frame, so two entries always bracket it; the rest is headroom for captures still in flight"**
- `push(_ frame:)`：lock + append + **超 capacity removeFirst**（FIFO 裁剪）
- **`getFramesForTime(targetTime:)`（297–316 行）**：找 targetTime 落在哪个相邻对（prev.timestamp <= t <= next.timestamp）→ (prev, next)；**越界回退**：t > last → (倒数第二, last)；t < 第一 → (第一, 第二)——**永不返回 nil（有 2 帧以上）**
- `newestFrame`：buffer.last（最新帧）
- **`newestPair`（328–330 行）**："**The two most recent captures. Interpolation works on this pair and no other: the midpoint MetalFX can add belongs between them, and asking for the pair directly cannot miss the way searching for a timestamp could when the estimated capture interval drifted from the real one**"

**`maxInFlight = 3`（93 行）+ `inFlightSemaphore = DispatchSemaphore(3)`（105 行）**——**在途帧上限（捕获处理并发 3；信号量背压：processIOSurfaceFrame 先 wait）**；`texturePoolDepth = capacity + maxInFlight`（= 7，348 行——纹理池深度）。

**`EngineConfig`（private struct，约 375–397 行）**：bufferDepth（默认 3）/ scalingType / aaMode / qualityProfile / frameGenMode / frameGenEnabled / frameGenMultiplier / vsyncEnabled / captureCursorEnabled。

**`estimatedCaptureInterval`（399–402 行）**：捕获间隔估计（EMA 更新，1338 行：`+= (interval - est) × alpha`）；**728 行 resetProcessingState 清零**；750 行 `measuredSourceFPS()` 用它（1.0/interval）。

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

**喂帧链（Engine/GooseEngine 第 1873–1982 行）——捕获帧如何进引擎**：

| 方法 | 行为 |
|---|---|
| `startCaptureFromWindow(_:)`（1873–1894 行） | resetProcessingStateAsync(clearFrames: true) + resetFrameCounters + resetErrorReporting + applyBufferDepth(config.bufferDepth) → 持有 manager → **onFrameReceived → processingQueue.async → processIOSurfaceFrame**（1896–1901 行：inFlightSemaphore.wait() → updateCaptureStats → processSurface） |
| `stopCapture()`（1903–1910 行） | onFrameReceived = nil + manager 释放——**源注释（1907–1908 行）："The ring holds a texture from the pool for every entry; leaving them there keeps the whole pool alive until the next capture overwrites it"** → resetProcessingStateAsync(clearFrames: true) |
| `updateSettings` 模式切换失效（1855–1870 行） | **源注释（1855–1858 行）："across a mode switch mixes two schedules into one set of totals and the generated/passthrough split stops meaning anything"** → frameGenMode 或 frameGenMultiplier 变化 → 6 个计数（droppedFrames/frameCount/outputFrameCount/interpolatedFrameCount/passthroughFrameCount/generatedFrameCount）清零 + lastPresentedCaptureTimestamp = -1 |
| **`ingest(cgImage:)`（1915–1982 行，AuroraDrive 扩展）** | 头注释（1912–1914 行）："把外部已捕获帧(CGImage)注入显示链路……避免 AuroraDrive 再起一路 ScreenCaptureKit。仅用于『给人看的显示叠加层』"；CGImage → CVPixelBuffer（BGRA + IOSurface 属性）→ CGContext（premultipliedFirst + byteOrder32Little）→ processSurface(isSceneCut: **false**——ingest 路径无场景检测，固定 false)；**⚠️ 坑位（1975–1979 行源注释）："若这里不更新估计器，估计区间恒为 0 → delay=输出间隔 → targetTime 永远贴在最新帧之后 → phase 恒判 1（纯透传，插帧不产帧）。这正是 APP 经 ingest 喂帧时插帧失效的根因"** → 故 1980 行显式 `updateCaptureStats(currentTime:captureTimestamp:)`；错误码 MG-ENG-EXT-001~004（CVPixelBufferCreate/IOSurface/MTKView ready/drawableSize） |

**`CaptureSettings`（final class ObservableObject，1–205 行）——配置面 + 持久化**：

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

**代码-32 文档至此完整**（六单元，覆盖 Engine/ 全部 6 文件 3161 行：GooseEngine 1988 + WindowCaptureManager 364 + Shaders.metal 466 + CaptureSettings 236 + GooseUpscaler 91 + Stubs 16；另述根层 4687 行不参与编译的原版应用）