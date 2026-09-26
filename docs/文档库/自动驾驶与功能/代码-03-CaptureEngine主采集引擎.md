# 代码-03 CaptureEngine 主采集引擎

> 覆盖源文件：`Sources/AuroraDrive/Capture/CaptureEngine.swift`（**654 行**）。基于当前仓库逐单元编写。
>
> **2026-09-25 深度复核记录**：9-24 性能优化落地了「插帧门禁 `isUpscaleWanted`」（源码 58–64 行 + 帧回调 331 行），本档已补上；源码 639→654 行，全文行号引用已按新版本复核，**58 行之后的小节标题行号整体 +8~+15**（门禁声明及其注释所占比行）。核心架构（四路回调/四池/锁保护/480px 渲染）与上版一致，零变化。

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

**CaptureEngine 文档至此完整**（639 行全覆盖：公开接口 → 线程安全 → 启停 → 帧回调 → 直通路径 → 渲染 → 缓冲池）。
