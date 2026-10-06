# 代码-03 CaptureEngine 主采集引擎

> 覆盖源文件：`Sources/AuroraDrive/Capture/CaptureEngine.swift`（**654 行，2026-10-06 `wc -l` 实测**）。基于当前仓库逐单元编写。
>
> **2026-09-25 深度复核记录**：9-24 性能优化落地了「插帧门禁 `isUpscaleWanted`」（源码 58–64 行 + 帧回调 331 行），本档已补上；源码 639→654 行，全文行号引用已按新版本复核，**58 行之后的小节标题行号整体 +8~+15**（门禁声明及其注释所占比行）。核心架构（四路回调/四池/锁保护/480px 渲染）与上版一致，零变化。
>
> **✅ 2026-10-06 复核**：本档一~七节逐行对照 654 行现役源码，行号全部吻合；同日新增**八、九、十、十一**四节（帧完整生命周期 / 引擎模式 vs 本地模式 / 「有帧=false 帧数=0」判定 / OCR 进程归属修复方向）。`isUpscaleWanted` 声明现位于 **:64**（上文 58–64 行的说法仍成立，64 行为赋值行）。
>
> **🟢 2026-10-07 复核（D7）：本次未改动，行号零偏移。**
> - **文件**：仍为 **654 行**（2026-10-07 `wc -l` 实测），与 10-06 一致。
> - **git**：`git diff --stat HEAD~5..HEAD -- Sources/AuroraDrive/Capture/CaptureEngine.swift` **输出为空**（零改动）；工作树亦无未提交改动。该文件最后一次改动为 `37f92c2`（**09-24 08:33**，插帧帧拷贝门禁）——即**近 13 天未再触碰**。
> - **抽检锚点**（2026-10-07 `sed` 实测，与正文一致）：`final class CaptureEngine` :24 ✓、`onUpscaleFrame` :56 ✓、`isUpscaleWanted` :64 ✓、`onNativeFrame` :69 ✓、`captureQueue` :91 ✓、`start()` :165 ✓、`startStream` :203 ✓、`stop()` :256 ✓、原生帧直通 :317-325 ✓、插帧门禁调用 :331 ✓、原生 ROI 拷贝 :510 ✓。
> - **结论**：本文档一~十一节全部继续有效，**无需修订**；本次仅追加本条"未改动"标注。
> - ⚠️ 附带说明：本次 10-07 的 AI 助手施工**未改动采集链**——`AIAgentPanel.encodeCurrentFrameForVision()`（`AIAgentPanel.swift:1636`，`@MainActor private static`）只是**只读消费** `DriveState.currentFrameCG`（:1637；帧源回退 `captureEngine.currentFrame` :1638），未新增/修改任何 `CaptureEngine` 成员（未验证该只读路径在 30fps 下的实测开销）。
>
> **✅ 2026-10-07 D7b 复核补完（同日第二遍）**：上述结论**逐条复验成立**——文件确为 654 行、`git diff` 确为空、最后一次提交确为 `37f92c2`；正文全部锚点 `sed` 实测**命中**（:24/:56/:64/:69/:91/:165/:203/:256/:331/:510，另补验 :232 SCStream 创建、:237 addStreamOutput、:245 startCapture、:294 帧回调、:301 autoreleasepool、:323/:331/:338 三路直通、:376 UI 渲染、:449/:452 onFrame、:393/:396/:406/:434/:442 失败分支）。**本档 §八~§十一 跨引用的 `AuroraDriveApp.swift` 行号需整体 `+121`**（该文件已 8335→8456 行）：实测 `captureEngine` 声明 :5373、`startDriving()` :5881、本地 `captureEngine.start()` :5957、四路接线 :5703/:5718/:5747/:5756/:5761、录制拉起 :4906、tick 消费 :6532/:6556、感知入口 :6701、`tickEngineMode` :6178、UI 收尾 :6215 —— **正文里的 5252/5760/5836/5582/5597/5626/5635/5640/4785/6411/6435/6580/6057/6121/5716/4783/6070/6094 等一律 +121**。本文档 **§八~§十一 的结论与语义完全不受影响**，仅行号引用需换算（D7b 未逐条改写正文，改以本注集中说明）。

## 一、引擎概览与公开接口

**类声明（第 24 行）**：`final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable`
——基于 ScreenCaptureKit（macOS 12.3+ 官方截屏 API）建立一条 SCStream 持续画面流（30fps），系统在画面变化时自动推送新帧，**无需反复截图，内存固定不增长**。`@unchecked Sendable`：内部自管线程安全（见下），对外声明可跨线程传递。

**对外公开接口一览：**

| 成员 | 签名 | 说明 |
|---|---|---|
| `currentFrame` | `private(set) var: NSImage?` | 当前帧图像（UI 显示用），锁保护 |
| `isCapturing` | `private(set) var: Bool` | 是否正在捕获，锁保护 |
| `captureFPS` | `private(set) var: Double` | 捕获帧率（每秒更新一次），锁保护 |
| `onFrame` | `var: ((NSImage, CGImage) -> Void)?` | 主帧回调：NSImage 供录制/既有引用；CGImage 直传下游（推屏/推理/置信度），省去下游重复转换 |
| `onYoloFrame` | `var: ((CVPixelBuffer) -> Void)?` | YOLO 直通回调：源头用 vImage(CPU) 把全屏缩放到 `YoloEngine.inputSize`×inputSize BGRA 缓冲 |
| `onUpscaleFrame` | `var: ((CVPixelBuffer) -> Void)?` | 插帧/超分直通回调：全分辨率 CVPixelBuffer，MetalGoose 专用独立路径 |
| `isUpscaleWanted` | `var: () -> Bool`（默认 `{ false }`） | **插帧门禁（9-24 改动 10）**：每次帧回调时求值。`copyUpscaleFrame` 做一次全分辨率（可达数十 MB）内存拷贝，插帧/清晰画面关闭时这份拷贝纯属白费。引擎进程接线 `{ EngineGlobals.wantFullFrame }`（UI 经 socket 下发），UI 进程接线 `{ upscaleEnabled }`。与 onUpscaleFrame 同为 main 上赋值、captureQueue 上读的 @unchecked Sendable 模式 |
| `onNativeFrame` | `var: ((CVPixelBuffer) -> Void)?` | 原生帧直通回调：速度表 ROI 原生分辨率（未缩放），SpeedOCR 用 |
| `onStatusChange` | `var: ((CaptureStatus) -> Void)?` | 启动/停止/错误/权限被拒回调 |
| `upscaleEnabled` | `var: Bool` | 插帧/超分开关（锁保护） |
| `gameModeBoostEnabled` | `var: Bool` | 游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权），默认 `true` |
| `start()` | `func start()` | 启动捕获（异步流程，见单元三） |
| `stop()` | `func stop()` | 停止捕获并清理（见单元四） |
| `lastFrameGapMs` | `private(set) var: Double` | 诊断：相邻两帧捕获间隔（ms），正常 ~33ms |
| `lastFrameWorkMs` | `private(set) var: Double` | 诊断：每帧 captureQueue 处理耗时（ms） |

**`CaptureStatus`（enum，第 73–78 行）**：`started / stopped / error(String) / permissionDenied` 四种。

**`speedROINorm`（static let，第 66–67 行）**：

```swift
nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885, width: 0.080, height: 0.050)
```

速度表 ROI，**归一化坐标，左上角原点 y 向下**。字模录制（glyphMode）与 SpeedOCR 共用此 ROI：
- 环1 优化：`copyNativeFrame` 只拷贝该区域（≈100KB，替代整帧 22MB）
- `SpeedOCRReader` 用同一常量把槽位坐标换算到 ROI 相对坐标（与 Python `crop_slot(roi=...)` 一致）
- `nonisolated`：静态常量跨并发域访问无需隔离

**四条回调的分工**（这是本引擎的核心设计）：主路径 `onFrame`（UI 显示）之外，三条直通路径各自绕开不同瓶颈——YOLO 绕开"大图→NSImage→CGImage→再缩放"链路，Upscale 给 MetalGoose 完整帧，Native 给 SpeedOCR 原生分辨率直裁直读。四者互不影响，全部从同一个 SCStream 帧派生。

## 二、私有属性与线程安全模型（第 80–147 行）

**线程模型**：SCStream 帧回调跑在 `captureQueue`（`DispatchQueue(label: "aurora.capture", qos: .userInteractive)`，第 83 行）；诊断/状态属性**写于 captureQueue、读于主线程**——跨线程访问全部走锁。

**锁**：`private let stateLock = OSAllocatedUnfairLock()`（第 90 行）。源注释（87–89 行）说明了为什么：P0-3 修复——裸读写存在数据竞争（torn read 可能读出 NaN → 读侧 `Int(NaN)` trap）；OSAllocatedUnfairLock 纳秒级开销，**不触碰 30fps 红线**。

**锁保护的状态属性（读写都经 `stateLock.withLock`）：**

| 私有存储 | 公开访问器 | 默认值 |
|---|---|---|
| `_currentFrame: NSImage?` | `currentFrame` | nil |
| `_isCapturing: Bool` | `isCapturing` | false |
| `_captureFPS: Double` | `captureFPS` | 0 |
| `_lastFrameGapMs: Double` | `lastFrameGapMs` | 0 |
| `_lastFrameWorkMs: Double` | `lastFrameWorkMs` | 0 |
| `_upscaleEnabled: Bool` | `upscaleEnabled` | false |
| `_gameModeBoostEnabled: Bool` | `gameModeBoostEnabled` | true |

**不需要锁的属性（仅在 captureQueue 串行读写，第 146–147 行）**：`lastFrameTime: Date`、`fpsAccumulator: Int`——源注释明确"无跨线程竞争，无需加锁"。

**四个 CVPixelBufferPool（自持缓冲池，与 SCStream 生命周期解耦）：**

| 池 | 字段 | 尺寸 | 用途 |
|---|---|---|---|
| `nativePool` | nativePoolWidth/Height | 速度表 ROI 尺寸 | `copyNativeFrame` 逐行拷贝 ROI，派发主线程；主线程永不接触系统托管缓冲 |
| `yoloBufferPool` | yoloBufferPoolSize | `YoloEngine.inputSize`（640×640） | vImage 直接缩放进池化私有缓冲，每帧独立，池深度 ≥4；全部在途时 `CVPixelBufferPoolCreatePixelBuffer` 自行扩容 |
| `uiBufferPool` | uiPoolWidth/Height | 480 宽等比 | vImage 缩放后 CGImage 经 CGDataProvider 零拷贝引用其基址；尺寸随源分辨率固定，变化则重建 |
| `upscalePool` | upscalePoolWidth/Height | 全分辨率 | 插帧/超分帧自持拷贝（标准内存布局，不带 IOSurface） |

**缓冲所有权约定**（111–121 行注释）：池缓冲由下游闭包持有引用，用完后自动回池——主线程永不接触系统托管缓冲（防 use-after-release：SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统回收/覆写）。

## 三、start() / startStream() 启动流程（第 149–245 行）

**`start()`（第 157–192 行）**——同步签名包装异步流程：

1. `guard !isCapturing else { return }`——防重复启动（幂等）
2. `Task { [weak self] in ... }` 包装 async 调用（weak 防循环持有）
3. **权限检查**：`try await SCShareableContent.current`——macOS 10.15+ 首次调用触发系统授权弹窗；无权限抛错 → `onStatusChange?(.error(...))` + `onStatusChange?(.permissionDenied)` 并 return（第 167–174 行）
4. **选主显示器**（第 176–187 行）：`CGMainDisplayID()` 精确匹配 `content.displays`，匹配不到回退 `displays.first`（避免抓任意顺序屏），再没有则报"未找到可用的显示器"。选中后 `print("[capture] selected displayID=... main=...")`
5. `await self.startStream(display: display)` 进入流创建

**`startStream(display:)`（第 195–245 行）**：

1. 诊断日志：`print("[capture] display frame=... w=... h=...")`——确认显示器输出分辨率
2. **SCStreamConfiguration（第 200–218 行）**：

| 配置项 | 值 | 原因（源注释） |
|---|---|---|
| `width/height` | `NSScreen.frame(点) × backingScaleFactor`（换算真像素） | SCDisplay.width 实测可能返回**点值**（导致输出只有 ~1485×960、速度表数字仅 ~18px、OCR 精度不足）；换算后速度表数字 ~95px 清晰。NSScreen 匹配不到时回退 `display.width/height` |
| `minimumFrameInterval` | `CMTime(value: 1, timescale: 30)` | 30fps 上限 |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | **显式锁 32BGRA**：vImageScale_ARGB8888 依赖此格式（防 SCStream 未来返回 420 花帧） |
| `queueDepth` | 3 | 平衡延迟与流畅 |
| `showsCursor` | true | 画面包含鼠标 |

3. **内容过滤器**（第 221 行）：`SCContentFilter(display: display, excludingWindows: [])`——捕获整个显示器，不排除任何窗口
4. **创建 SCStream**（第 224 行）：`SCStream(filter:configuration:delegate:nil)`，delegate 传 nil（输出走 addStreamOutput）
5. **注册帧输出**（第 228–233 行）：`try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)`——type `.screen` 区别于 `.audio`；失败报错 return
6. **启动**（第 236–244 行）：`try await stream.startCapture()` 成功后：`self.stream = stream`、`isCapturing = true`、`lastFPSDate = Date()`、`onStatusChange?(.started)`；失败则 `onStatusChange?(.error(...))`

**TCC 依赖提示**：权限被拒（`permissionDenied`）时引擎不会启动——调用方（EngineMain/DriveState）收到该状态应走降级路径（本地模式），不要反复重试 start()。

## 四、stop() 与帧回调的诊断部分（第 247–303 行）

**`stop()`（第 248–276 行）**：

1. `guard isCapturing, let stream = stream else { return }`——未在捕获时幂等返回
2. `Task { [weak self] in ... }`：
   - `try await stream.stopCapture()`——**停止失败不阻塞**（catch 空实现，继续清理状态）
   - `self.stream = nil`、`self.isCapturing = false`、`self.currentFrame = nil`
   - **P2 修复（260–273 行）**：停捕获时把四个池全部置 nil，释放 ~8MB 空闲缓冲（下次 start 按当前分辨率重建）。池只在 captureQueue 上被读写，这里同样 `self.captureQueue.sync { ... }` 串行清理——避免与在途帧回调竞争（跨线程写 nil 与建池构成数据竞争）
   - `self.onStatusChange?(.stopped)`

**`stream(_:didOutputSampleBuffer:of:)` 帧回调——诊断部分（第 282–303 行）：**

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen else { return }        // 只处理屏幕画面帧（忽略音频）
    autoreleasepool { ... }                      // 整个每帧处理包进 autoreleasepool
```

- **autoreleasepool 包裹（286–289 行，P1 修复）**：SCStream delegate 回调**不自动包 autoreleasepool**，30fps 下每帧临时对象（NSImage/CGImage/CGDataProvider/vImage 等）若不在帧末释放，长时间运行内存缓涨——整个每帧处理逻辑包进 autoreleasepool，帧末统一释放。
- **帧提取**：`guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }`
- **capGap 诊断（293–300 行）**：
  - `lastFrameGapMs = (lastFrameTime == .distantPast) ? 0 : frameStart.timeIntervalSince(lastFrameTime) * 1000`——**P2 修复**：首帧 lastFrameTime 为 `.distantPast`，timeIntervalSince 会得到 ~5e11 ms 假值；首帧 gap 记 0，避免诊断面板显示天文数字
  - `lastFrameTime = frameStart`
- **诊断兜底（301–303 行）**：`defer { lastFrameWorkMs = Date().timeIntervalSince(frameStart) * 1000 }`——无论本帧后续是否成功都统计 capWork（失败路径不跳过诊断）；随后 `updateFPS()`

**诊断尺子的用法**（135–137 行注释）：capGap 正常 ~33ms，变大/波动 = 捕获或处理慢；capWork 含 22MB 拷贝 + YOLO + UI 渲染 + 回调。两者配合定位"延迟高在哪一环"。

## 五、帧回调主体——三条直通路径（第 305–359 行）

帧回调在诊断之后依次执行三条直通路径（每条独立判断回调是否注册）：

**① 原生帧直通 → `onNativeFrame`（第 305–313 行）**

```swift
if let onNativeFrame, let nativeCopy = copyNativeFrame(from: pixelBuffer) {
    onNativeFrame(nativeCopy)
}
```

SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统回收/覆写 → use-after-release（轻则裁出垃圾、重则崩溃）。`copyNativeFrame` 用 CVPixelBufferPool 私有缓冲逐行整拷一份，行序照抄 src 的 bytesPerRow（不做方向解释，方向语义由下游 CIImage 路径负责）——主线程永远持有自己的拷贝，与 SCStream 生命周期彻底解耦。

**② 插帧/超分直通 → `onUpscaleFrame`（第 327–334 行）**

```swift
if let onUpscaleFrame, isUpscaleWanted(),
   let upscaleCopy = copyUpscaleFrame(from: pixelBuffer) {
    onUpscaleFrame(upscaleCopy)
}
```

必须复制到私有缓冲——源注释（MG-ENG-001）：否则下游 CGImage 创建会崩。**门禁先于拷贝求值**（9-24 改动 10）：插帧/清晰画面关闭时连全分辨率拷贝都不做（下游本就没人消费，拷了也是白费带宽与内存带宽）。`copyUpscaleFrame` 提供标准线性内存布局的 CGImage 即可，GooseEngine.ingest(cgImage:) 内部会自行创建 IOSurface-backed 缓冲。

**③ YOLO 直通 → `onYoloFrame`（第 321–359 行）**

在**源头**用 CPU vImage 把全屏缩放到模型输入尺寸（`YoloEngine.inputSize` = 640），绕开"大图 → NSImage → CGImage → 再缩放"链路：

1. `makeYoloBufferPool(size:)` 惰性建池（每帧独立、池深度 ≥4）——下游 onYoloFrame 强捕获该缓冲，直到 tick 消费 + inferFast 拷贝完才释放回池；主线程卡顿也不会拿到被覆写的帧。相比旧"双缓冲 + copyYoloFrame 整拷一份"**省掉一次 640×640×4 ≈ 1.6MB 冗余 memcpy**
2. `CVPixelBufferPoolCreatePixelBuffer` 从池取缓冲
3. 双缓冲加锁：src `.readOnly`、dst `[]`，defer 解锁
4. **vImage 缩放**：`vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))`
   - CPU 双线性（`kvImageNoFlags`）：**消除游戏占满 GPU 时 CIContext(GPU) 排队导致的 40ms 卡顿**
   - **非等比拉伸**到 640×640（与训练/慢路径一致，不保持宽高比）
   - 字节序 32BGRA = ARGB8888 little-endian，vImage 正确处理，B/G/R 顺序不变
5. `onYoloFrame(yb)`——**仅缩放成功才送出**；GetBaseAddress 失败则跳过本帧直通

**三条路径的失败语义统一**：拷贝/缩放失败返回 nil 或跳过——调用方（下游）不会收到坏帧，但该帧也不补发（下一帧自然跟上）。

## 六、UI 帧压缩渲染与 CGImage 生命周期（第 361–438 行）

**为什么是 480px（用户拍板，361–370 行注释）**：

- 旧实现：render 2940×1912 全分辨率 CGImage（~22MB）再靠 NSImage 的 size 参数"假装"缩放（size 只是绘制提示，底层位图仍全分辨率）→ 每帧 22MB 分配 + 全画面 GPU 渲染 + SwiftUI 每帧绘制大图，30fps 下 **660MB/s 分配速率**；运行 1–2 分钟后系统内存压力累积（实测 lag 飙到 878–1382ms、掉到 0 帧）
- 现实现：CPU vImage 全屏**等比**直缩到 480 宽（~0.6MB），CGImage 经 CGDataProvider 零拷贝引用缩放缓冲（并 retain 该缓冲保证生命周期），**完全绕开 CIContext(GPU)**，消除游戏占满 GPU 时的排队卡顿
- 捕获/推理频率不变（30fps 红线）；OCR（onNativeFrame）、YOLO（onYoloFrame）走各自直通路径不受影响

**渲染流程：**

1. `let uiScale = min(1.0, maxWidth / sw)`（371–376 行）——等比，源小于 480 宽时不放大；`dW/dH` 四舍五入，`guard dW > 0, dH > 0` 防零尺寸
2. `makeUIBufferPool(width:height:)` 惰性建池 → `CVPixelBufferPoolCreatePixelBuffer` 取缓冲
3. vImage 等比缩放进 uiBuf（CPU 双线性，方向/字节序与 GPU 路径一致，**不翻转**）
4. **CGImage 生命周期绑定（402–430 行，关键）**：
   - 旧写法 `CGContext(data:)+makeImage()` 是 COW 快照，不保证物理拷贝；uiBuf 回池后被下一帧 vImage 覆写 → 屏幕显示撕裂/花帧（use-after-recycle）
   - 现用 `CGDataProvider(dataInfo:data:size:releaseData:)`，releaseData 回调里 `Unmanaged.fromOpaque(info!).release()`——即 `Unmanaged.passRetained(uiBuf).toOpaque()` 的 +1 retain 在图像销毁时释放，**图像存活期间池不会复用该缓冲**
   - 失败语义（417–429 行）：provider 创建失败 → 手动 release 那 +1 避免泄漏；cgImage 创建失败 → provider 已随 ARC 析构、其 releaseData 会释放 +1，不重复释放
5. `let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: dW, height: dH))`（431 行）
6. `currentFrame = nsImage`（434 行）→ `onFrame?(nsImage, cgImage)`（437 行）——UI 显示和模型推理共用

**bitmapInfo（408–409 行）**：`premultipliedFirst | byteOrder32Little`——BGRA 排列的 32 位小端，与 CVPixelBuffer 的 32BGRA 一致。

## 七、四个缓冲池工厂与两个自持拷贝（第 441–639 行）

**四个池工厂（惰性创建或复用，尺寸变化才重建）——签名与差异：**

| 工厂 | 复用条件 | 池属性差异 |
|---|---|---|
| `makeYoloBufferPool(size:)`（444–465 行） | `yoloBufferPoolSize == size` | 32BGRA + CGImage/CGBitmapContext/**Metal 兼容**（与模型输入一致）；`kCVPixelBufferPoolMinimumBufferCountKey: 4` |
| `makeUIBufferPool(width:height:)`（470–491 行） | 宽高都相等 | 32BGRA + CGImage/CGBitmapContext 兼容（**无 Metal**）；深度 4 |
| `nativeBufferPool(width:height:)`（545–566 行） | 宽高都相等 | 同上（ROI 尺寸）；深度 4 |
| `upscaleBufferPool(width:height:)`（604–626 行） | 宽高都相等 | 32BGRA + CGImage/CGBitmapContext 兼容；**故意不加 `kCVPixelBufferIOSurfacePropertiesKey`**——IOSurface-backed 缓冲的 BaseAddress 不可读会导致 CGImage 创建失败（614 行注释） |

全部工厂：`CVPixelBufferPoolCreate(kCFAllocatorDefault, [MinimumBufferCount: 4], attrs, &pool)` 失败返回 nil（调用方跳过该帧）。"全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容"（源注释）——池深度 4 是下限不是上限。

**`copyNativeFrame(from:) -> CVPixelBuffer?`（第 500–540 行）**——速度表 ROI 自持拷贝：

1. 取 src 宽高，`guard w > 0, h > 0`
2. **归一化 ROI → 像素**（506–510 行）：`Int((roi.origin.x * CGFloat(w)).rounded(.toNearestOrEven))`——用 `.toNearestOrEven` 与 cropSlots 的 `round()` 同源，**保证边界量化一致**（SpeedOCRReader 换算槽位坐标时不出 1px 偏差）
3. 边界校验：`roiX >= 0, roiY >= 0, roiW > 0, roiH > 0, roiX + roiW <= w, roiY + roiH <= h`
4. 从 nativePool 取缓冲 → 双锁 → 逐行 memcpy（534–538 行）：
   ```swift
   for r in 0..<dstRows {
       memcpy(dBase + r * dBPR, sBase + (roiY + r) * sBPR + srcOffset, copyBytes)
   }
   ```
   - `bytesPerPixel = 4`（32BGRA）、`srcOffset = roiX * 4`、`copyBytes = roiW * 4`
   - 行序照抄 src（row 0 = 画面顶部），ROI 顶部行 = src 的 roiY 行——**1:1 复制、不翻转、不解释方向**
5. 返回 ROI 自持拷贝（≈100KB）；拷贝失败返回 nil（调用方跳过该帧直通）

**`copyUpscaleFrame(from:) -> CVPixelBuffer?`（第 573–599 行）**——全分辨率自持拷贝：

- 与 copyNativeFrame 同构，但拷贝**整帧**（`copyBytes = w * 4`，`for r in 0..<h` 逐行全拷）
- 目的：GooseEngine.ingest(cgImage:) 需要标准线性内存布局的 CGImage（571–572 行注释），避免 IOSurface-backed 缓冲的 BaseAddress 不可读问题

**`updateFPS()`（第 629–638 行）**：`fpsAccumulator += 1`；elapsed ≥ 1.0 时 `captureFPS = Double(fpsAccumulator) / elapsed`、归零累计器、更新 lastFPSDate——每秒计算一次。

**CaptureEngine 本体文档至此完整**（654 行全覆盖：公开接口 → 线程安全 → 启停 → 帧回调 → 直通路径 → 渲染 → 缓冲池）。以下三节为 2026-10-06 新增：帧的完整生命周期（含两种进程模式）、引擎日志「有帧=false 帧数=0」的代码判定、OCR 进程归属的修复方向。

## 八、帧完整生命周期（谁启动 SCStream、帧进哪个队列、到哪去）

### 8.1 SCStream 的启动者与帧队列

- **SCStream 由 `CaptureEngine.startStream(display:)` 创建并启动**：`SCStream(filter:configuration:delegate:nil)`（CaptureEngine.swift:232）→ `addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)`（:237）→ `try await stream.startCapture()`（:245）。启动成功后置 `isCapturing = true`、回调 `.started`（:247–249）。
- **帧队列**：系统把 CMSampleBuffer 推到 `captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)`（:91，注册点 :237）。**这条队列就是 SCStream 的采样队列**（queueDepth=3，:225）——在上面做同步重活会推迟帧消费 → 3 帧缓冲填满 → capGap 拉长（AuroraDriveApp.swift:5605–5621 的回退注释实测过 11ms→2081ms 的雪崩）。
- **帧回调**：`stream(_:didOutputSampleBuffer:of:)`（:294）在 captureQueue 上执行，进入 `autoreleasepool`（:301）后依次走：诊断（:306–315）→ onNativeFrame 直通（:323–325）→ onUpscaleFrame 直通（:331–334）→ onYoloFrame 直通（:338–374）→ 480px UI 渲染 + `onFrame?(nsImage, cgImage)`（:376–452）。

### 8.2 引擎模式（`--engine`）的帧路径

| 步骤 | 位置 |
|---|---|
| 1. UI 连不上引擎时 spawn `--engine` 子进程；引擎入口 `EngineMain.run()` | EngineClient.swift `startup()`（AURORA_UI_LOCAL=1 时直接本地模式不 spawn，:159–164）；EngineMain.swift:608 |
| 2. 引擎进程创建 `DriveState()`，其成员 `captureEngine = CaptureEngine()` 随之创建；**覆盖式接线**：`onUpscaleFrame` → 存入 `EngineGlobals.latestFullFrame`（锁保护），`isUpscaleWanted = { EngineGlobals.wantFullFrame }` | EngineMain.swift:756–770；DriveState 的 captureEngine 声明 AuroraDriveApp.swift:5252 |
| 3. **启动时机 ①诊断模式**：`AURORA_ENGINE_DIAG_CAPTURE_ONLY` 时 EngineMain 直接 `captureEngine.start()`（EngineMain.swift:774–777）。**启动时机 ②生产路径**：UI 发 `start` 命令 → `EngineMain.handleCommand` → `EngineGlobals.state?.startDriving()`（EngineMain.swift:953–960）→ DriveState.startDriving（AuroraDriveApp.swift:5760）→ `captureEngine.start()`（:5836）。UI 自己的 startDriving 在引擎模式下只发命令、不启动本地抓屏（:5761–5769 引擎分支） | |
| 4. SCStream 帧进引擎进程的 `aurora.capture` 队列 → 四路直通（Native/Yolo/Upscale/UI 480px）**全部在引擎进程内完成** | CaptureEngine.swift:294–452 |
| 5. `onFrame` 接线写在 DriveState `init()`（AuroraDriveApp.swift:5582，引擎进程创建 DriveState 时同样执行）→ 覆盖写入 pendingFrame；引擎进程的 tick（`EngineMain.tickOnce`，30Hz DispatchSourceTimer，EngineMain.swift:781–791）调 `st.tick()`（:884–887）消费帧：YOLO/YOLOPX/E2E 推理、置信度、按键注入全在引擎进程 | |
| 6. tickOnce 末尾 `shm.publish(image: st.currentFrameCG, detections:…, fps:…, isDriving:…, isStreaming:…, fullFrame:)` 发共享内存；`wantFullFrame` 为真时附全分辨率帧 | EngineMain.swift:889–903 |
| 7. UI 进程 `tickEngineMode()` 轮询：`client.poll()` 拿 CGImage → `currentFrameCG`/`screenSize`/`frameHost.push`；开插帧时 `client.takePixelBuffer()` 拿全分辨率帧喂 `upscaleHost` | AuroraDriveApp.swift:6057–6087 |

### 8.3 本地模式（`AURORA_UI_LOCAL=1` 或无引擎可连）的帧路径

- `AuroraFlags.uiLocal`（AuroraFlags.swift:138）→ `EngineClient.startup()` 直接不连不 spawn（EngineClient.swift:159–164）；连接失败/断开也回落本地（isActive=false，EngineClient.swift:537–541）。
- UI 进程自己的 DriveState 在 `init()` 里完成四路接线：`onFrame` → pendingFrame/pendingFrameCG 覆盖写（AuroraDriveApp.swift:5582–5594）、`onYoloFrame` → pendingYoloFrame（:5597–5622）、`onNativeFrame` → pendingNativeFrame（:5626–5633）、`onUpscaleFrame` → `upscaleHost.push`（:5635–5638）、`isUpscaleWanted = { upscaleEnabled }`（:5640）。
- 启动：`startDriving()` 本地分支 `captureEngine.start()`（AuroraDriveApp.swift:5836）；录制也会拉起（`isRecording.didSet` → `captureEngine.start()`，:4785）。
- 消费：UI 进程 tick()（30Hz，SwiftUI Timer 驱动，:6384 起）：消费 pendingFrame → `currentScreenImage`/`currentFrameCG`（:6411–6425）→ 任务面板 OCR（:6435–6437）→ 消费 YOLO 帧推理+光流（:6440 起）→ 消费 native ROI 帧给 speedOCR/字模录制（:6538–6549）→ `if let cg = currentFrameCG` 跑 M9/assist/YOLO/YOLOPX 推理（:6580–6599）。

### 8.4 两种模式帧路径差异小结

| 维度 | 引擎模式 | 本地模式 |
|---|---|---|
| SCStream 所在进程 | 引擎（--engine 子进程） | UI 进程 |
| tick/推理进程 | 引擎 | UI |
| isUpscaleWanted 接线 | `{ EngineGlobals.wantFullFrame }`（UI 经 socket `upscale` 命令下发，EngineMain.swift:981–991） | `{ upscaleEnabled }`（本进程变量） |
| 全分辨率帧去向 | `EngineGlobals.latestFullFrame` → shm | `upscaleHost.push`（本进程 MetalGoose） |
| UI 侧取帧 | `tickEngineMode()` 轮询 shm（AuroraDriveApp.swift:6069 `client.poll()` 起） | captureQueue 回调覆盖写 + tick 消费（:6411 起） |
| 任务面板 OCR | **引擎进程照跑**（见下方 8.5 节：引擎 tick 走的就是同一份 `st.tick()`，:6436 在引擎进程同样执行），但**结果回传 UI 缺失**——onConfirmed 只写引擎进程的 state.questName，UI 看不见 | 跑（默认开：`AURORA_QUEST_OCR`，AuroraFlags.swift:201） |

### 8.5 引擎进程的 tick 语义（⚠️ 关键且反直觉）

`EngineMain.tickOnce()`（EngineMain.swift:884–887）调的是 **`st.tick()`——与 UI 本地模式完全同一份 `DriveState.tick()` 代码**（AuroraDriveApp.swift:6384 起）。而引擎进程从 `--engine` 入口直接进 `EngineMain.run()`（AuroraDriveApp.swift:809–811），**不跑** `EngineClient.startup()`（:208–210 仅非 daemon UI 进程执行，且 --engine 在 :809 已提前 `exit` 分流），因此引擎进程内 `EngineClient.shared.isActive` **恒为 false**——tick 不走 `tickEngineMode` 提前 return，**完整本地管线（含推理、按键注入、任务面板 OCR 喂帧 :6435–6437）在引擎进程内全部执行**。`tickEngineMode()`（:6058）只存在于 UI 进程。

_driveState 单例说明_：`DriveState.shared` 是**每进程一个**的单例（AuroraDriveApp.swift:4011；:4004–4008 注释明确「引擎进程与 UI 进程各自持有自己的实例，互不影响」）。另有第三种独立实例：`--agent-command` 命令模式由 AppDelegate 在 `applicationDidFinishLaunching`（:133）里单独创建 ControlEngine + CaptureEngine（:531–538，`cap.start()` :538，不走 DriveState）。

## 九、引擎日志「有帧=false 帧数=0」的代码判定

**日志出处**：EngineMain.swift:823–831，心跳计时器每 5 秒输出一条 `[ENGINE] 统计: seq=… 有帧=… det=… … yolopx:加载=… 帧数=…`（heartbeatCount % 5 == 0 门控，:808）。

- **`有帧` 的判定（:810）**：`let hasFrame = EngineGlobals.state?.currentFrameCG != nil`。`currentFrameCG` 在引擎进程内的唯一写点是 tick 消费 pendingFrame 时（AuroraDriveApp.swift:6421，8.5 节已证该段代码在引擎进程执行）——因此 `有帧=false` ⇔ 引擎进程的 SCStream 从未成功产出一帧走到 `onFrame` 末尾，或 captureEngine 根本没启动。
- **`帧数` 的判定（:824）**：`px?.inferenceCount ?? 0`，即 yolopxEngine 累计推理次数。它只在 `currentFrameCG != nil` 时才会增长（推理入口 `if let cg = currentFrameCG`，:6580；`yolopxEngine.infer(image: cg)` :6599）。**有帧=false ⇒ 帧数必然=0**：两者是同一条因果链（无帧 → 推理从未触发），不是两个独立故障。

**`有帧=false` 的全部分支排查表**（按数据流上游顺序）：

| # | 分支 | 代码依据 |
|---|---|---|
| 1a | **UI 从未发 `start` 命令**：UI `startDriving()` 在引擎模式下只转发命令（:5762–5768），用户没点开始驾驶就没有 start；UI 连上引擎后**不会**自动启动抓屏 | AuroraDriveApp.swift:5762–5768 |
| 1b | **引擎侧 startDriving 被辅助功能权限守卫拦下（最可疑）**：引擎侧 startDriving 走本地分支，`guard controlEngine.requestAccessibilityPermission() || controlDisabled else { return }`（:5822–5826）——引擎进程无辅助功能权限且未开观测模式时，在 :5836 `captureEngine.start()` **之前就 return**。日志特征：`[ENGINE] startDriving → isDriving=false`（EngineMain.swift:958） | AuroraDriveApp.swift:5822–5826；EngineMain.swift:958 |
| 2 | **引擎进程 TCC fail-fast 自杀**：辅助功能或屏幕录制缺失 → `exit(2)`（此时根本看不到统计日志；观测模式放宽为只查 screen；`AURORA_ENGINE_DIAG_SKIP_TCC=1` 可旁路继续运行，旁路后落到分支 3） | EngineMain.swift:662–678 |
| 3 | **屏幕录制权限缺失**：`SCShareableContent.current` 抛错 → `.error` + `.permissionDenied`，流没建起来 | CaptureEngine.swift:176–182 |
| 4 | **显示器枚举失败 / addStreamOutput / startCapture 失败**：找不到显示器（:189–194）；注册帧回调失败（:236–241）；启动失败（:250–252）→ `isCapturing` 保持 false | CaptureEngine.swift |
| 5 | **流活着但帧没走到 onFrame 末尾**：每帧在第④条 UI 缩放路径的 guard 处持续失败（建池/取缓冲失败 :393/:396、BaseAddress :406、provider/CGImage :434/:442）→ `onFrame` 永不出、`currentFrame`（:449）永不置。此类失败日志**无任何打印**（与 AuroraDriveApp.swift:5674–5677 注释自认的「抓帧失败静默」同一盲区；理论存在，未验证实际发生过） | CaptureEngine.swift:392–445 |
| 6 | **onFrame 接线缺失**：接线在 DriveState `init()`（AuroraDriveApp.swift:5582–5594），引擎进程创建 DriveState（EngineMain.swift:757）时同样执行——已排除漏接线；仅当 `EngineGlobals.state` 指向其它实例（如夹具）才可能错位 | |
| 7 | **tick 没跑**：tickTimer 未建/未 resume（EngineMain.swift:781–791）、`EngineGlobals.state == nil`（:886 guard，state 启动即创建，正常不触发——未验证存在触发路径） | EngineMain.swift:886 |

> **当前现场就是 false 的定位顺序建议**：日志里若有 `收到命令: start`（EngineMain.swift:949）→ 看 1b：出现 `startDriving → isDriving=false` 即坐实权限守卫拦截；若连 `收到命令: start` 都没有 → 1a；若两者都有且无 `[CAPTURE] ❌`（AuroraDriveApp.swift:5680）却仍 false → 按 3→4→5 查。此为基于代码的推断，需对照引擎日志具体行确认（未验证）。

## 十、修复方向：任务面板 OCR 挪引擎进程 vs UI 进程保本地采集

**现状（2026-10-06 核实）**：任务面板 OCR（QuestPanelReader，QuestPanelReader.swift:415–416 `@MainActor final class`，入口 `ingest(cgImage:)` :541）的**唯一生产喂帧点**是 `if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（AuroraDriveApp.swift:6435–6437；0.7s 节流 `minInterval` QuestPanelReader.swift:431、防重入在 Reader 内部）。**结合 8.5 节：这段代码在引擎进程内本来就在执行**（引擎 tick 跑同一份 `st.tick()`），`questPanel` 也是引擎 DriveState 的成员（:5502）。所以问题不是「引擎不跑 OCR」，而是**结果回传缺失**：`onConfirmed` 接线（:5575–5580）写的是引擎进程自己的 `questName`/`setLocatorTarget`，UI 进程看不见。**全分辨率前提**：questROI（:424，2940×1912 下 x 88~1176 / y 458~592）按归一化裁剪，引擎帧是原生像素，OCR 输入质量与本地模式一致。

### 方向 A：OCR 留在引擎进程，把结果回传 UI（推荐、改动最小）

改动点清单：

1. **心跳加字段**：`sendHeartbeat` 的 JSON（EngineMain.swift:1065–1069）追加 `questName` / `locatorTargetX` / `locatorTargetY`，来源 `EngineGlobals.state?.questName` 与引擎侧 locatorTarget（onConfirmed 落库值）。
2. **UI 解析**：EngineClient 心跳解析区新增 `engineQuestName` / `engineLocatorTarget` 镜像属性。
3. **UI 消费**：`tickEngineMode()`（AuroraDriveApp.swift:6121–6128 的状态镜像区）先比后写回 `self.questName` / `setLocatorTarget(x:y:)`（与 onConfirmed :5577–5578 同款落库规则：@Observable 先比后写）。
4. **引擎侧 onConfirmed 保持现状**（:5575–5580 在引擎进程落库引擎 state 即可）；UI 进程的同一接线只在本地模式生效。
5. **开关**：`AURORA_QUEST_OCR` 默认已开（AuroraFlags.swift:201）；注意 AuroraFlags.swift:445 的 flags 清单仍写「默认关」——**两处描述不一致，以 :201 代码为准**（未验证文档化时机）。运行时开关如需 UI 控制再经命令下发（参照 `record` 命令带 extra 的模式，AuroraDriveApp.swift:4770–4788）。
6. **前置依赖**：先解决第九节的「有帧=false」——引擎无帧时 OCR 同样无输入。
7. **新鲜度**：quest 结果经 1Hz 心跳回传（EngineMain.swift:797），任务名变化最多滞后 ~1s——可接受（未验证用户感知）。

### 方向 B：UI 进程保本地采集（引擎模式照旧，UI 另起一路采集/消费供 OCR）

改动点清单：

1. **真·第二路 SCStream 变体**：引擎模式激活时 UI 也启动本地 captureEngine（`EngineClient.onActivated` 回调处 AuroraDriveApp.swift:5716 起，或参照录制 didSet 的 `if !captureEngine.isCapturing { captureEngine.start() }` 写法 :4783–4786）。UI 消费本地 pendingFrame 喂 questPanel（:6411–6425 + :6435–6437 的逻辑不变，但 :6400–6405 的提前 return 要改为放行 OCR 子集）。
2. **TCC 与成本**：UI 进程需自己的屏幕录制授权（本地模式已证明拿得到）；引擎+UI 双 30fps SCK 流 = 每帧四路拷贝 ×2（CaptureEngine.swift:317–452），CPU/内存带宽翻倍（未验证实测代价）；引擎 nice=-20 与 UI 的 captureQueue 并存需评估。
3. **显示源二选一**：UI 画面用本地 480 宽流还是引擎 shm 帧要拍板——frameHost/upscaleHost 只能吃一路（:6070–6087），两路同喂会打架。
4. **状态机冲突**：:6094–6102 的「引擎停抓 → UI 收尾」会把 isStreaming 复位，本地流启动后该判据需区分「引擎流」与「本地流」。
5. **优点**：OCR/预览帧源与本地模式完全一致（全分辨率、不依赖引擎 shm 档位）；缺点：双采集开销 + 产品决策 + 两处状态机耦合。

**结论**：**方向 A 是首选**——OCR 已经在引擎进程跑着，只缺心跳回传三个字段，UI 侧一次解析即可；方向 B 的任何变体都意味着双采集或显示源重构，仅在「引擎侧 OCR 无法满足实时性/精度」时再评估。两方向都需先解决第九节的「有帧=false」（引擎无帧则一切无输入）。

