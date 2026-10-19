# 代码-03 CaptureEngine 主采集引擎

> 覆盖源文件：`Sources/AuroraDrive/Capture/CaptureEngine.swift`（**1584 行**，2026-10-18 `wc -l` 实测）。基于当前仓库逐单元编写。
>
> **✅ 2026-10-17 复核（T6）**：正文全部行号已按当前源码（1584 行版）`grep -n` / `sed -n` 逐条实测重写，均为当前真实值；旧版复核沿革与行号换算说明不再保留。精确锚点见文末「2026-10-17 实测锚点表」。
>
> **✅ 2026-10-18 复核（T7）**：lead 于 10-18 改过两处频率注释（`:479-484` 像素流 45→20fps、`:654-657` setCaptureHz 接线状态），导致 EngineMain.swift 行号整体漂移 +5~+18、AuroraDriveApp.swift 漂移 +2~+5。本次逐条核对修正了：
> - **内容**：默认帧率 30fps→20fps（`_targetCaptureHz = 20.0`，`:186`）；像素流 ~192 MB/s→~85 MB/s（`:481`）；capGap ~33ms→~50ms（20fps）；setCaptureHz 补「2026-10-12 已接线」注记（`:654-657`）
> - **行号**：CaptureEngine `:578→579`、`:592–594→595`、`:596–598→599`、`:600→601`；EngineMain `run() :880→885`、`DriveState() :1037→1042`、`tickOnce :1180–1182→1193–1195`、`st.tick() :1182→1195`、`shm.publish :1237–1248→1255–1263`、`handleCommand :1484→1497`、`收到命令 :1491→1504`、`sendHeartbeat :1887→1900`、`startDriving :1500→1513`、`isDriving= 日志 :1501→1514`、`wantFullFrame 下发 :1555→1561`、`sprint 联动 :1236→1244` 等共 18 条；AuroraDriveApp `DriveState :4148→4150`、`DriveState.shared :4178→4180`、`captureEngine 声明 :5527→5529`、`startDriving() :6187→6190`、`本地 captureEngine.start() :6280→6283`、`tick() :6862→6865`、`tickEngineMode() :6519→6522`、`client.poll() :6530→6533`、`questPanel.ingest :6970→6974`、`yolopxEngine.infer :7285→7290`、`onConfirmed :5978→5981`、`questPanel :5905→5908` 等共 12 条
> - **锚点表**：文末已逐条更新。1 条 CaptureEngine 本体行号（`:578→579`）+ 全部跨文件锚点均已修正。
> - **未改**：`Sources/` 下任何文件（纪律）。
>
> **✅ 2026-10-18 二次重基准（源码冻结于 AuroraDriveApp 9097 行版）**：逐条 `sed -n` 看现状 + `grep -n` 找真值，**不用统一 +N 平移**（实测同文件 +2/+3 都有）。修正 13 条：
> - **AuroraDriveApp.swift 11 条**：`onFrame 接线 :5981→:5988–6000`、`onYoloFrame :6000→:6003–6030`、`onNativeFrame :6029→:6032–6039`、`onUpscaleFrame+isUpscaleWanted :6038–6043→:6041–6044/:6046`、`currentFrameCG 写点 :6956→:6959`、`推理入口 :7149→:7154`、`DriveState.shared 定义 :4172→:4180`（原来引的是注释行，不是定义行）、`状态镜像区 :6582→:6577–6598`、`onActivated :6143→:6146`、`抓帧失败诊断 :6077–6080→:6079–6085`、`[CAPTURE] ❌ :6083→:6086`、`useUpscale 区间 :6530–6548→:6530–6551`、`capGap 注释 :6017→:6020`
> - **判定为「语义一致、无需改」的 43 条**：全部逐条 `sed -n` 验过 —— 见下方锚点表
> - **注意**：`yolopxEngine.infer` 真值仍是 **:7290**（我一度误改成 :7295，已回退）
>
> **✅ 2026-10-18 「指向相邻符号」审计（lead 脚本抓 8 条可疑，逐条 `sed -n` 判定）**：**修正 2 条 / 误报 6 条**
> - 修正 `handleConnectionLoss :552→:553`（:552 是 `/// - Parameter reason` 注释行）
> - 修正 `equivalentRadiusMeters :431→:449`（:431 是 `minInterval`，同类名相邻陷阱）
> - 误报 6 条（文档引用的是**使用点/区间**而非声明点，语义正确）：`wantFullFrame :1561`（使用点，声明在 :610）、`upscaleHost :6522–6551`（整个 tickEngineMode 函数区间）、`currentFrameCG :6959`（唯一写点，声明在 :5163）、`start :6192–6199`（引擎分支 if 区间）、`handleCommand :1497`（已正确）、`questOCR :201`（已正确，:138 是 uiLocal 在同行并列引用）
## 一、引擎概览与公开接口

**类声明（第 98 行）**：`final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable`
——基于 ScreenCaptureKit（macOS 12.3+ 官方截屏 API）建立一条 SCStream 持续画面流（默认 20fps，应急 45fps），系统在画面变化时自动推送新帧，**无需反复截图，内存固定不增长**。`@unchecked Sendable`：内部自管线程安全（见下），对外声明可跨线程传递。

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
| `lastFrameGapMs` | `private(set) var: Double` | 诊断：相邻两帧捕获间隔（ms），正常 ~50ms（20fps） |
| `lastFrameWorkMs` | `private(set) var: Double` | 诊断：每帧 captureQueue 处理耗时（ms） |

**`CaptureStatus`（enum，第 155–160 行）**：`started / stopped / error(String) / permissionDenied` 四种。

**`speedROINorm`（static let，第 148 行）**：

```swift
nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885, width: 0.080, height: 0.050)
```

速度表 ROI，**归一化坐标，左上角原点 y 向下**。字模录制（glyphMode）与 SpeedOCR 共用此 ROI：
- 环1 优化：`copyNativeFrame` 只拷贝该区域（≈100KB，替代整帧 22MB）
- `SpeedOCRReader` 用同一常量把槽位坐标换算到 ROI 相对坐标（与 Python `crop_slot(roi=...)` 一致）
- `nonisolated`：静态常量跨并发域访问无需隔离

**四条回调的分工**（这是本引擎的核心设计）：主路径 `onFrame`（UI 显示）之外，三条直通路径各自绕开不同瓶颈——YOLO 绕开"大图→NSImage→CGImage→再缩放"链路，Upscale 给 MetalGoose 完整帧，Native 给 SpeedOCR 原生分辨率直裁直读。四者互不影响，全部从同一个 SCStream 帧派生。

## 二、私有属性与线程安全模型（第 162–373 行）

**线程模型**：SCStream 帧回调跑在 `captureQueue`（`DispatchQueue(label: "aurora.capture", qos: .userInteractive)`，第 165 行）；诊断/状态属性**写于 captureQueue、读于主线程**——跨线程访问全部走锁。

**锁**：`private let stateLock = OSAllocatedUnfairLock()`（第 260 行）。源注释（第 257–259 行）说明了为什么：P0-3 修复——裸读写存在数据竞争（torn read 可能读出 NaN → 读侧 `Int(NaN)` trap）；OSAllocatedUnfairLock 纳秒级开销，**不触碰 20fps 红线**。

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

**不需要锁的属性（仅在 captureQueue 串行读写，第 166–167 行；源注释第 372 行）**：`lastFrameTime: Date`、`fpsAccumulator: Int`——源注释明确"无跨线程竞争，无需加锁"。

**四个 CVPixelBufferPool（自持缓冲池，与 SCStream 生命周期解耦）：**

| 池 | 字段 | 尺寸 | 用途 |
|---|---|---|---|
| `nativePool` | nativePoolWidth/Height | 速度表 ROI 尺寸 | `copyNativeFrame` 逐行拷贝 ROI，派发主线程；主线程永不接触系统托管缓冲 |
| `yoloBufferPool` | yoloBufferPoolSize | `YoloEngine.inputSize`（640×640） | vImage 直接缩放进池化私有缓冲，每帧独立，池深度 ≥4；全部在途时 `CVPixelBufferPoolCreatePixelBuffer` 自行扩容 |
| `uiBufferPool` | uiPoolWidth/Height | 480 宽等比 | vImage 缩放后 CGImage 经 CGDataProvider 零拷贝引用其基址；尺寸随源分辨率固定，变化则重建 |
| `upscalePool` | upscalePoolWidth/Height | 全分辨率 | 插帧/超分帧自持拷贝（标准内存布局，不带 IOSurface） |

**缓冲所有权约定**（第 291–293 行注释）：池缓冲由下游闭包持有引用，用完后自动回池——主线程永不接触系统托管缓冲（防 use-after-release：SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统回收/覆写）。

## 三、start() / startStream() 启动流程（第 385–562 行）

**`start()`（第 385–448 行）**——同步签名包装异步流程：

1. `guard !isCapturing else { return }`——防重复启动（幂等）
2. `Task { [weak self] in ... }` 包装 async 调用（weak 防循环持有）
3. **权限检查**：`try await SCShareableContent.current`——macOS 10.15+ 首次调用触发系统授权弹窗；无权限抛错 → `onStatusChange?(.error(...))` + `onStatusChange?(.permissionDenied)` 并 return（第 424–429 行）
4. **选主显示器**（第 431–443 行）：`CGMainDisplayID()` 精确匹配 `content.displays`，匹配不到回退 `displays.first`（避免抓任意顺序屏），再没有则报"未找到可用的显示器"。选中后 `print("[capture] selected displayID=... main=...")`
5. `await self.startStream(display: display)` 进入流创建

**`startStream(display:content:)`（第 451–562 行）**：

1. 诊断日志：`print("[capture] display frame=... w=... h=...")`——确认显示器输出分辨率
2. **SCStreamConfiguration**：装配已抽到静态纯函数 `Self.makeStreamConfiguration(configHz:display:)`（第 579–607 行），建流与热更共用同一份：

| 配置项 | 值 | 原因（源注释） |
|---|---|---|
| `width/height` | 目标宽 1280，高按屏幕宽高比等比算（3:2 → 832），`scalesToFit = false`（第 595 行） | 2026-10-11 降分辨率修复：原抓原生 Retina 像素 2940×1912 @30fps = 675 MB/s（历史基线），与游戏抢 GPU 带宽；现 1280×832 保持宽高比、不 letterbox，像素流降至 ~85 MB/s（@20fps） |
| `minimumFrameInterval` | 由参数 `configHz` 决定（第 599 行） | task-94 动态帧率：`start()` 与 `setCaptureHz()` 热更共用同一份配置（`updateConfiguration` 要求全量传）。⚠️ `setCaptureHz(_:)`（第 657 行）的**接线状态见下：2026-10-12 已接线**（该函数源注释 :654-657 已把旧的「零外部调用」标注为过期），`EngineMain.applyPerceptionMode` 两处（:884 切档 / :901 录制结束补切）与 `tickOnce` 的应急 sprint 联动（:1244）都在调它 |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | **显式锁 32BGRA**：vImageScale_ARGB8888 依赖此格式（防 SCStream 未来返回 420 花帧） |
| `queueDepth` | 3 | 平衡延迟与流畅 |
| `showsCursor` | true | 画面包含鼠标 |

3. **内容过滤器**（第 485–517 行，2026-10-08 双模式）：`.window(id)` 只捕获该窗口（第 494–507 行）；`.fullScreen` 捕获整屏但**排除自家全部窗口**（第 509–513 行），随后 `auditExclusion` 自动断言排除列表非空（第 516–517 行）
4. **创建 SCStream**（第 520 行）：`SCStream(filter:configuration:delegate:nil)`，delegate 传 nil（输出走 addStreamOutput）
5. **注册帧输出**（第 522–531 行）：`try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)`——type `.screen` 区别于 `.audio`；失败报错 return
6. **启动**（第 533–557 行）：`try await stream.startCapture()` 成功后：`self.stream = stream`、`isCapturing = true`、`lastFPSDate = Date()`、`onStatusChange?(.started)`；失败则 `onStatusChange?(.error(...))`

**TCC 依赖提示**：权限被拒（`permissionDenied`）时引擎不会启动——调用方（EngineMain/DriveState）收到该状态应走降级路径（本地模式），不要反复重试 start()。

## 四、stop() 与帧回调的诊断部分（stop() 第 703–753 行；帧回调诊断第 1061–1090 行）

**`stop()`（第 703–753 行）**：

1. `guard isCapturing, let stream = stream else { return }`——未在捕获时幂等返回
2. `Task { [weak self] in ... }`：
   - `try await stream.stopCapture()`——**停止失败不阻塞**（catch 空实现，继续清理状态）
   - `self.stream = nil`、`self.isCapturing = false`、`self.currentFrame = nil`
   - **P2 修复（第 731–748 行）**：停捕获时把四个池全部置 nil，释放 ~8MB 空闲缓冲（下次 start 按当前分辨率重建）。池只在 captureQueue 上被读写，这里同样 `self.captureQueue.sync { ... }` 串行清理——避免与在途帧回调竞争（跨线程写 nil 与建池构成数据竞争）
   - `self.onStatusChange?(.stopped)`

**`stream(_:didOutputSampleBuffer:of:)` 帧回调——诊断部分（第 1061–1090 行）：**

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen else { return }        // 只处理屏幕画面帧（忽略音频）
    autoreleasepool { ... }                      // 整个每帧处理包进 autoreleasepool
```

- **autoreleasepool 包裹（第 1073–1076 行，P1 修复）**：SCStream delegate 回调**不自动包 autoreleasepool**，20fps 下每帧临时对象（NSImage/CGImage/CGDataProvider/vImage 等）若不在帧末释放，长时间运行内存缓涨——整个每帧处理逻辑包进 autoreleasepool，帧末统一释放。
- **帧提取**：`guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }`
- **capGap 诊断（第 1080–1087 行）**：
  - `lastFrameGapMs = (lastFrameTime == .distantPast) ? 0 : frameStart.timeIntervalSince(lastFrameTime) * 1000`——**P2 修复**：首帧 lastFrameTime 为 `.distantPast`，timeIntervalSince 会得到 ~5e11 ms 假值；首帧 gap 记 0，避免诊断面板显示天文数字
  - `lastFrameTime = frameStart`
- **诊断兜底（第 1088–1090 行）**：`defer { lastFrameWorkMs = Date().timeIntervalSince(frameStart) * 1000 }`——无论本帧后续是否成功都统计 capWork（失败路径不跳过诊断）；随后 `updateFPS()`

**诊断尺子的用法**（第 363 行注释）：capGap 正常 ~50ms（20fps），变大/波动 = 捕获或处理慢；capWork 含 22MB 拷贝 + YOLO + UI 渲染 + 回调。两者配合定位"延迟高在哪一环"。

## 五、帧回调主体——三条直通路径（第 1092–1149 行）

帧回调在诊断之后依次执行三条直通路径（每条独立判断回调是否注册）：

**① 原生帧直通 → `onNativeFrame`（第 1092–1100 行）**

```swift
if let onNativeFrame, let nativeCopy = copyNativeFrame(from: pixelBuffer) {
    onNativeFrame(nativeCopy)
}
```

SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统回收/覆写 → use-after-release（轻则裁出垃圾、重则崩溃）。`copyNativeFrame` 用 CVPixelBufferPool 私有缓冲逐行整拷一份，行序照抄 src 的 bytesPerRow（不做方向解释，方向语义由下游 CIImage 路径负责）——主线程永远持有自己的拷贝，与 SCStream 生命周期彻底解耦。

**② 插帧/超分直通 → `onUpscaleFrame`（第 1102–1109 行）**

```swift
if let onUpscaleFrame, isUpscaleWanted(),
   let upscaleCopy = copyUpscaleFrame(from: pixelBuffer) {
    onUpscaleFrame(upscaleCopy)
}
```

必须复制到私有缓冲——源注释（MG-ENG-001）：否则下游 CGImage 创建会崩。**门禁先于拷贝求值**（9-24 改动 10）：插帧/清晰画面关闭时连全分辨率拷贝都不做（下游本就没人消费，拷了也是白费带宽与内存带宽）。`copyUpscaleFrame` 提供标准线性内存布局的 CGImage 即可，GooseEngine.ingest(cgImage:) 内部会自行创建 IOSurface-backed 缓冲。

**③ YOLO 直通 → `onYoloFrame`（第 1111–1149 行）**

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

## 六、UI 帧压缩渲染与 CGImage 生命周期（第 1151–1228 行）

**为什么是 480px（用户拍板，第 1151–1160 行注释）**：

- 旧实现：render 2940×1912 全分辨率 CGImage（~22MB）再靠 NSImage 的 size 参数"假装"缩放（size 只是绘制提示，底层位图仍全分辨率）→ 每帧 22MB 分配 + 全画面 GPU 渲染 + SwiftUI 每帧绘制大图，20fps 下 **660MB/s 分配速率**；运行 1–2 分钟后系统内存压力累积（实测 lag 飙到 878–1382ms、掉到 0 帧）
- 现实现：CPU vImage 全屏**等比**直缩到 480 宽（~0.6MB），CGImage 经 CGDataProvider 零拷贝引用缩放缓冲（并 retain 该缓冲保证生命周期），**完全绕开 CIContext(GPU)**，消除游戏占满 GPU 时的排队卡顿
- 捕获/推理频率不变（默认 20fps，应急冲刺 45fps）；OCR（onNativeFrame）、YOLO（onYoloFrame）走各自直通路径不受影响

**渲染流程：**

1. `let uiScale = min(1.0, maxWidth / sw)`（第 1161–1167 行）——等比，源小于 480 宽时不放大；`dW/dH` 四舍五入，`guard dW > 0, dH > 0` 防零尺寸
2. `makeUIBufferPool(width:height:)` 惰性建池 → `CVPixelBufferPoolCreatePixelBuffer` 取缓冲
3. vImage 等比缩放进 uiBuf（CPU 双线性，方向/字节序与 GPU 路径一致，**不翻转**）
4. **CGImage 生命周期绑定（第 1192–1220 行，关键）**：
   - 旧写法 `CGContext(data:)+makeImage()` 是 COW 快照，不保证物理拷贝；uiBuf 回池后被下一帧 vImage 覆写 → 屏幕显示撕裂/花帧（use-after-recycle）
   - 现用 `CGDataProvider(dataInfo:data:size:releaseData:)`，releaseData 回调里 `Unmanaged.fromOpaque(info!).release()`——即 `Unmanaged.passRetained(uiBuf).toOpaque()` 的 +1 retain 在图像销毁时释放，**图像存活期间池不会复用该缓冲**
   - 失败语义（第 1207–1219 行）：provider 创建失败 → 手动 release 那 +1 避免泄漏；cgImage 创建失败 → provider 已随 ARC 析构、其 releaseData 会释放 +1，不重复释放
5. `let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: dW, height: dH))`（第 1221 行）
6. `currentFrame = nsImage`（第 1224 行）→ `onFrame?(nsImage, cgImage)`（第 1227 行）——UI 显示和模型推理共用

**bitmapInfo（第 1198–1199 行）**：`premultipliedFirst | byteOrder32Little`——BGRA 排列的 32 位小端，与 CVPixelBuffer 的 32BGRA 一致。

## 七、四个缓冲池工厂与两个自持拷贝（第 1234–1428 行）

**四个池工厂（惰性创建或复用，尺寸变化才重建）——签名与差异：**

| 工厂 | 复用条件 | 池属性差异 |
|---|---|---|
| `makeYoloBufferPool(size:)`（第 1234–1255 行） | `yoloBufferPoolSize == size` | 32BGRA + CGImage/CGBitmapContext/**Metal 兼容**（与模型输入一致）；`kCVPixelBufferPoolMinimumBufferCountKey: 4` |
| `makeUIBufferPool(width:height:)`（第 1260–1281 行） | 宽高都相等 | 32BGRA + CGImage/CGBitmapContext 兼容（**无 Metal**）；深度 4 |
| `nativeBufferPool(width:height:)`（第 1335–1356 行） | 宽高都相等 | 同上（ROI 尺寸）；深度 4 |
| `upscaleBufferPool(width:height:)`（第 1394–1416 行） | 宽高都相等 | 32BGRA + CGImage/CGBitmapContext 兼容；**故意不加 `kCVPixelBufferIOSurfacePropertiesKey`**——IOSurface-backed 缓冲的 BaseAddress 不可读会导致 CGImage 创建失败（第 1404 行注释） |

全部工厂：`CVPixelBufferPoolCreate(kCFAllocatorDefault, [MinimumBufferCount: 4], attrs, &pool)` 失败返回 nil（调用方跳过该帧）。"全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容"（源注释）——池深度 4 是下限不是上限。

**`copyNativeFrame(from:) -> CVPixelBuffer?`（第 1290–1330 行）**——速度表 ROI 自持拷贝：

1. 取 src 宽高，`guard w > 0, h > 0`
2. **归一化 ROI → 像素**（第 1295–1300 行）：`Int((roi.origin.x * CGFloat(w)).rounded(.toNearestOrEven))`——用 `.toNearestOrEven` 与 cropSlots 的 `round()` 同源，**保证边界量化一致**（SpeedOCRReader 换算槽位坐标时不出 1px 偏差）
3. 边界校验：`roiX >= 0, roiY >= 0, roiW > 0, roiH > 0, roiX + roiW <= w, roiY + roiH <= h`
4. 从 nativePool 取缓冲 → 双锁 → 逐行 memcpy（第 1305–1328 行）：
   ```swift
   for r in 0..<dstRows {
       memcpy(dBase + r * dBPR, sBase + (roiY + r) * sBPR + srcOffset, copyBytes)
   }
   ```
   - `bytesPerPixel = 4`（32BGRA）、`srcOffset = roiX * 4`、`copyBytes = roiW * 4`
   - 行序照抄 src（row 0 = 画面顶部），ROI 顶部行 = src 的 roiY 行——**1:1 复制、不翻转、不解释方向**
5. 返回 ROI 自持拷贝（≈100KB）；拷贝失败返回 nil（调用方跳过该帧直通）

**`copyUpscaleFrame(from:) -> CVPixelBuffer?`（第 1363–1389 行）**——全分辨率自持拷贝：

- 与 copyNativeFrame 同构，但拷贝**整帧**（`copyBytes = w * 4`，`for r in 0..<h` 逐行全拷）
- 目的：GooseEngine.ingest(cgImage:) 需要标准线性内存布局的 CGImage（第 1361–1362 行注释），避免 IOSurface-backed 缓冲的 BaseAddress 不可读问题

**`updateFPS()`（第 1419–1428 行）**：`fpsAccumulator += 1`；elapsed ≥ 1.0 时 `captureFPS = Double(fpsAccumulator) / elapsed`、归零累计器、更新 lastFPSDate——每秒计算一次。

**CaptureEngine 本体文档至此完整**（1584 行全覆盖：公开接口 → 线程安全 → 启停 → 帧回调 → 直通路径 → 渲染 → 缓冲池）。以下三节为 2026-10-06 新增：帧的完整生命周期（含两种进程模式）、引擎日志「有帧=false 帧数=0」的代码判定、OCR 进程归属的修复方向。

## 八、帧完整生命周期（谁启动 SCStream、帧进哪个队列、到哪去）

### 8.1 SCStream 的启动者与帧队列

- **SCStream 由 `CaptureEngine.startStream(display:content:)` 创建并启动**：`SCStream(filter:configuration:delegate:nil)`（CaptureEngine.swift:521）→ `addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)`（:526）→ `try await stream.startCapture()`（:537）。启动成功后置 `isCapturing = true`（:553）、回调 `.started`（:557）。
- **帧队列**：系统把 CMSampleBuffer 推到 `captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)`（:165，注册点 :526）。**这条队列就是 SCStream 的采样队列**（`config.queueDepth = 3`，:601）——在上面做同步重活会推迟帧消费 → 3 帧缓冲填满 → capGap 拉长（AuroraDriveApp.swift:6020–6024 的回退注释实测过 11ms→2081ms 的雪崩）。
- **帧回调**：`stream(_:didOutputSampleBuffer:of:)`（:1061）在 captureQueue 上执行，进入 `autoreleasepool`（:1076）后依次走：诊断（:1080–1090）→ onNativeFrame 直通（:1092–1100）→ onUpscaleFrame 直通（:1102–1109）→ onYoloFrame 直通（:1111–1149）→ 480px UI 渲染 + `onFrame?(nsImage, cgImage)`（:1151–1228）。

### 8.2 引擎模式（`--engine`）的帧路径

| 步骤 | 位置 |
|---|---|
| 1. UI 连不上引擎时 spawn `--engine` 子进程；引擎入口 `EngineMain.run()` | EngineClient.swift `startup()`（AURORA_UI_LOCAL=1 时直接本地模式不 spawn，:166–171）；EngineMain.swift:885 |
| 2. 引擎进程创建 `DriveState()`，其成员 `captureEngine = CaptureEngine()` 随之创建；**覆盖式接线**：`onUpscaleFrame` → 存入 `EngineGlobals.latestFullFrame`（锁保护），`isUpscaleWanted = { EngineGlobals.wantFullFrame }` | EngineMain.swift:1042（DriveState 创建）、:1048–1055（覆盖式接线）；DriveState 的 captureEngine 声明 AuroraDriveApp.swift:5529 |
| 3. **启动时机 ①诊断模式**：`AURORA_ENGINE_DIAG_CAPTURE_ONLY` 时 EngineMain 直接 `captureEngine.start()`（EngineMain.swift:1059–1062，开关定义 AuroraFlags.swift:162；本次复核该区间准确）。**启动时机 ②生产路径**：UI 发 `start` 命令 → `EngineMain.handleCommand`（:1497）→ `EngineGlobals.state?.startDriving()`（:1513）→ DriveState.startDriving（AuroraDriveApp.swift:6190）→ `captureEngine.start()`（:6283）。UI 自己的 startDriving 在引擎模式下只发命令、不启动本地抓屏（:6192–6199 引擎分支） | |
| 4. SCStream 帧进引擎进程的 `aurora.capture` 队列 → 四路直通（Native/Yolo/Upscale/UI 480px）**全部在引擎进程内完成** | CaptureEngine.swift:1092–1228 |
| 5. `onFrame` 接线写在 DriveState `init()`（AuroraDriveApp.swift:5988–6000，引擎进程创建 DriveState 时同样执行）→ 覆盖写入 pendingFrame；引擎进程的 tick（`EngineMain.tickOnce`，DispatchSourceTimer，EngineMain.swift:1067–1081）调 `st.tick()`（:1195）消费帧：YOLO/YOLOPX/E2E 推理、置信度、按键注入全在引擎进程 | |
| 6. tickOnce 末尾 `shm.publish(image: st.currentFrameCG, detections:…, fps:…, isDriving:…, isStreaming:…, fullFrame:)` 发共享内存；`wantFullFrame` 为真时附全分辨率帧 | EngineMain.swift:1255–1263 |
| 7. UI 进程 `tickEngineMode()` 轮询：`client.poll()` 拿 CGImage → `currentFrameCG`/`screenSize`/`frameHost.push`；开插帧时 `client.takePixelBuffer()` 拿全分辨率帧喂 `upscaleHost` | AuroraDriveApp.swift:6522–6551 |

### 8.3 本地模式（`AURORA_UI_LOCAL=1` 或无引擎可连）的帧路径

- `AuroraFlags.uiLocal`（AuroraFlags.swift:138）→ `EngineClient.startup()` 直接不连不 spawn（EngineClient.swift:166–172（本次复核：:166 即 `func startup()`、:167 即 `if AuroraFlags.uiLocal`，准确））；连接失败/断开也回落本地（isActive=false，EngineClient.swift:180–183 spawn 失败回退、:552–566 `handleConnectionLoss`（本次复核：:552 即函数定义，准确））。
- UI 进程自己的 DriveState 在 `init()` 里完成四路接线：`onFrame` → pendingFrame/pendingFrameCG 覆盖写（AuroraDriveApp.swift:5988–6000）、`onYoloFrame` → pendingYoloFrame（:6003–6030）、`onNativeFrame` → pendingNativeFrame（:6032–6039）、`onUpscaleFrame` → `upscaleHost.push`（:6041–6044）、`isUpscaleWanted = { upscaleEnabled }`（:6046）。
- 启动：`startDriving()` 本地分支 `captureEngine.start()`（AuroraDriveApp.swift:6283）；录制也会拉起（`isRecording.didSet` → `captureEngine.start()`，:5016）。
- 消费：UI 进程 `tick()`（AuroraDriveApp.swift:6865 起）：消费 pendingFrame → `currentScreenImage`/`currentFrameCG`（:6946–6962，本次复核：:6946 注释起、:6959 赋 `currentFrameCG`）→ 任务面板 OCR（:6974）→ 消费 YOLO 帧推理+光流（:6986 起）→ 消费 native ROI 帧给 speedOCR/字模录制（:7087–7099，本次复核：:7092 即 `pendingNativeLock.lock()`，区间准确）→ `if let cg = currentFrameCG` 跑 M9/assist/YOLO/YOLOPX 推理（:7154 起，本次复核：:7154 即 `if let cg = currentFrameCG {`）。

### 8.4 两种模式帧路径差异小结

| 维度 | 引擎模式 | 本地模式 |
|---|---|---|
| SCStream 所在进程 | 引擎（--engine 子进程） | UI 进程 |
| tick/推理进程 | 引擎 | UI |
| isUpscaleWanted 接线 | `{ EngineGlobals.wantFullFrame }`（UI 经 socket `upscale` 命令下发，EngineMain.swift:1561） | `{ upscaleEnabled }`（本进程变量，AuroraDriveApp.swift:6046） |
| 全分辨率帧去向 | `EngineGlobals.latestFullFrame` → shm | `upscaleHost.push`（本进程 MetalGoose） |
| UI 侧取帧 | `tickEngineMode()` 轮询 shm（AuroraDriveApp.swift:6533 `client.poll()` 起） | captureQueue 回调覆盖写 + tick 消费（:6946 起） |
| 任务面板 OCR | **引擎进程照跑**（见下方 8.5 节：引擎 tick 走的就是同一份 `st.tick()`，:6974 在引擎进程同样执行），但**结果回传 UI 缺失**——onConfirmed 只写引擎进程的 state.questName，UI 看不见 | 跑（默认开：`AURORA_QUEST_OCR`，AuroraFlags.swift:201） |

### 8.5 引擎进程的 tick 语义（⚠️ 关键且反直觉）

`EngineMain.tickOnce()`（EngineMain.swift:1193–1195）调的是 **`st.tick()`——与 UI 本地模式完全同一份 `DriveState.tick()` 代码**（AuroraDriveApp.swift:6865 起）。而引擎进程从 `--engine` 入口直接进 `EngineMain.run()`（AuroraDriveApp.swift:822–824，本次复核：:822 确为 `if args.contains("--engine")`，准确），**不跑** `EngineClient.startup()`（:209 仅非 daemon UI 进程执行，且 --engine 在 :822 已提前 `exit` 分流），因此引擎进程内 `EngineClient.shared.isActive` **恒为 false**——tick 不走 `tickEngineMode` 提前 return（:6938–6940），**完整本地管线（含推理、按键注入、任务面板 OCR 喂帧 :6974）在引擎进程内全部执行**。`tickEngineMode()`（AuroraDriveApp.swift:6522）只存在于 UI 进程。

_driveState 单例说明_：`DriveState.shared` 是**每进程一个**的单例（`static let shared = DriveState()` @AuroraDriveApp.swift:4180；:4149–4177 注释明确「引擎进程与 UI 进程各自持有自己的实例，互不影响」）。另有第三种独立实例：`--agent-command` 命令模式由 AppDelegate 在 `applicationDidFinishLaunching`（:133）里单独创建 ControlEngine + CaptureEngine（:529–536，`cap.start()` :534，不走 DriveState）。

## 九、引擎日志「有帧=false 帧数=0」的代码判定

**日志出处**：EngineMain.swift:1105–1130（本次复核：:1108 即 `heartbeatCount % 5 == 0`，:1110 即 `let hasFrame =`，:1123 即 `统计:` 日志行，区间准确），心跳计时器每 5 秒输出一条 `[ENGINE] 统计: seq=… 有帧=… det=… … yolopx:加载=… 帧数=…`（`heartbeatCount % 5 == 0` 门控，:1108）。

- **`有帧` 的判定（:1110）**：`let hasFrame = EngineGlobals.state?.currentFrameCG != nil`。`currentFrameCG` 在引擎进程内的唯一写点是 tick 消费 pendingFrame 时（AuroraDriveApp.swift:6959，8.5 节已证该段代码在引擎进程执行）——因此 `有帧=false` ⇔ 引擎进程的 SCStream 从未成功产出一帧走到 `onFrame` 末尾，或 captureEngine 根本没启动。
- **`帧数` 的判定（:1124）**：`px?.inferenceCount ?? 0`，即 yolopxEngine 累计推理次数。它只在 `currentFrameCG != nil` 时才会增长（推理入口 `if let cg = currentFrameCG`，AuroraDriveApp.swift:7154；`yolopxEngine.infer(image: cg)` :7290）。**有帧=false ⇒ 帧数必然=0**：两者是同一条因果链（无帧 → 推理从未触发），不是两个独立故障。

**`有帧=false` 的全部分支排查表**（按数据流上游顺序）：

| # | 分支 | 代码依据 |
|---|---|---|
| 1a | **UI 从未发 `start` 命令**：UI `startDriving()` 在引擎模式下只转发命令（AuroraDriveApp.swift:6192–6199），用户没点开始驾驶就没有 start；UI 连上引擎后**不会**自动启动抓屏 | AuroraDriveApp.swift:6192–6199（本次复核：`startDriving()` 定义即 :6190，区间准确） |
| 1b | **引擎侧 startDriving 被辅助功能权限守卫拦下（最可疑）**：引擎侧 startDriving 走本地分支，`guard controlEngine.requestAccessibilityPermission() || controlDisabled else { return }`（AuroraDriveApp.swift:6249–6253）——引擎进程无辅助功能权限且未开观测模式时，在 :6283 `captureEngine.start()` **之前就 return**。日志特征：`[ENGINE] startDriving → isDriving=...`（EngineMain.swift:1514） | AuroraDriveApp.swift:6249–6253；EngineMain.swift:1514 |
| 2 | **引擎进程 TCC fail-fast 自杀**：辅助功能或屏幕录制缺失 → `exit(2)`（此时根本看不到统计日志；观测模式放宽为只查 screen；`AURORA_ENGINE_DIAG_SKIP_TCC=1` 可旁路继续运行，旁路后落到分支 3） | EngineMain.swift:942–958（本次复核：该区间内确有 `exit(2)`，:955 与 :958 两处，行号仍准确） |
| 3 | **屏幕录制权限缺失**：`SCShareableContent.current` 抛错 → `.error` + `.permissionDenied`，流没建起来 | CaptureEngine.swift:421–429 |
| 4 | **显示器枚举失败 / addStreamOutput / startCapture 失败**：找不到显示器（:438–442）；注册帧回调失败（:524–531）；启动失败（:558–561）→ `isCapturing` 保持 false | CaptureEngine.swift |
| 5 | **流活着但帧没走到 onFrame 末尾**：每帧在第④条 UI 缩放路径的 guard 处持续失败（建池/取缓冲失败 :1167–1168 / :1170–1171、BaseAddress :1180–1181、provider/CGImage :1207–1220）→ `onFrame` 永不出、`currentFrame`（:1224）永不置。此类失败日志**无任何打印**（与 AuroraDriveApp.swift:6079–6085 注释自认的「抓帧失败静默」同一盲区；理论存在，未验证实际发生过） | CaptureEngine.swift:1167–1220 |
| 6 | **onFrame 接线缺失**：接线在 DriveState `init()`（AuroraDriveApp.swift:5988–6000），引擎进程创建 DriveState（EngineMain.swift:1042）时同样执行——已排除漏接线；仅当 `EngineGlobals.state` 指向其它实例（如夹具）才可能错位 | |
| 7 | **tick 没跑**：tickTimer 未建/未 resume（EngineMain.swift:1067–1081）、`EngineGlobals.state == nil`（:1194 guard，state 启动即创建，正常不触发——未验证存在触发路径） | EngineMain.swift:1067–1081 / :1194 |

> **当前现场就是 false 的定位顺序建议**：日志里若有 `收到命令: start`（EngineMain.swift:1504）→ 看 1b：出现 `startDriving → isDriving=false` 即坐实权限守卫拦截；若连 `收到命令: start` 都没有 → 1a；若两者都有且无 `[CAPTURE] ❌`（AuroraDriveApp.swift:6086）却仍 false → 按 3→4→5 查。此为基于代码的推断，需对照引擎日志具体行确认（未验证）。

## 十、修复方向：任务面板 OCR 挪引擎进程 vs UI 进程保本地采集

**现状（2026-10-17 按当前源码复核）**：任务面板 OCR（QuestPanelReader，QuestPanelReader.swift:415–416 `@MainActor final class`，入口 `ingest(cgImage:)` :541，本次复核：:541 即入口）的**唯一生产喂帧点**是 `if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（AuroraDriveApp.swift:6974；0.7s 节流 `minInterval` QuestPanelReader.swift:431、防重入在 Reader 内部）。**结合 8.5 节：这段代码在引擎进程内本来就在执行**（引擎 tick 跑同一份 `st.tick()`），`questPanel` 也是引擎 DriveState 的成员（AuroraDriveApp.swift:5908，本次复核：`@ObservationIgnored let questPanel = QuestPanelReader()` 即该行，准确）。所以问题不是「引擎不跑 OCR」，而是**结果回传缺失**：`onConfirmed` 接线（:5981–5983，`questPanel.onConfirmed = { [weak self] reading in` 即 :5981）写的是引擎进程自己的 `questName`/`setLocatorTarget`，UI 进程看不见。**全分辨率前提**：questROI（QuestPanelReader.swift:424，归一化 0.030/0.240/0.370/0.070）按归一化裁剪，引擎帧是原生像素，OCR 输入质量与本地模式一致。

### 方向 A：OCR 留在引擎进程，把结果回传 UI（推荐、改动最小）

改动点清单：

1. **心跳加字段**：`sendHeartbeat` 的 JSON（EngineMain.swift:1900–1902，函数定义 :1900——本次复核确认 :1900 正是函数定义行，原「:1887」有误）追加 `questName` / `locatorTargetX` / `locatorTargetY`，来源 `EngineGlobals.state?.questName` 与引擎侧 locatorTarget（onConfirmed 落库值）。
2. **UI 解析**：EngineClient 心跳解析区新增 `engineQuestName` / `engineLocatorTarget` 镜像属性。
3. **UI 消费**：`tickEngineMode()`（AuroraDriveApp.swift:6577–6598 的状态镜像区，本次实测：:6577 起为 `engineVersionWarning` 镜像，:6598 止于 `isDriving != client.engineIsDriving`）先比后写回 `self.questName` / `setLocatorTarget(x:y:)`（与 onConfirmed :5981–5983 同款落库规则：@Observable 先比后写）。
4. **引擎侧 onConfirmed 保持现状**（AuroraDriveApp.swift:5981–5983 在引擎进程落库引擎 state 即可）；UI 进程的同一接线只在本地模式生效。
5. **开关**：`AURORA_QUEST_OCR` 默认已开（AuroraFlags.swift:201）；注意 AuroraFlags.swift:445 的 flags 清单仍写「默认关」——**两处描述不一致，以 :201 代码为准**（未验证文档化时机）。运行时开关如需 UI 控制再经命令下发（参照 `record` 命令带 extra 的模式，AuroraDriveApp.swift:4990–4994）。
6. **前置依赖**：先解决第九节的「有帧=false」——引擎无帧时 OCR 同样无输入。
7. **新鲜度**：quest 结果经 1Hz 心跳回传（EngineMain.swift:1105 `sendHeartbeat(reason: "periodic")`），任务名变化最多滞后 ~1s——可接受（未验证用户感知）。

### 方向 B：UI 进程保本地采集（引擎模式照旧，UI 另起一路采集/消费供 OCR）

改动点清单：

1. **真·第二路 SCStream 变体**：引擎模式激活时 UI 也启动本地 captureEngine（`EngineClient.onActivated` 回调处 AuroraDriveApp.swift:6146 起，或参照录制 didSet 的 `if !captureEngine.isCapturing { captureEngine.start() }` 写法 :5013–5015，本次复核：:5016 即 `captureEngine.start()`，准确）。UI 消费本地 pendingFrame 喂 questPanel（:6946–6960 + :6974 的逻辑不变，但 :6938–6940 的引擎模式提前 return 要改为放行 OCR 子集）。
2. **TCC 与成本**：UI 进程需自己的屏幕录制授权（本地模式已证明拿得到）；引擎+UI 双流 = 每帧四路拷贝 ×2（CaptureEngine.swift:1092–1228），CPU/内存带宽翻倍（未验证实测代价）；引擎 nice=-20 与 UI 的 captureQueue 并存需评估。
3. **显示源二选一**：UI 画面用本地 480 宽流还是引擎 shm 帧要拍板——frameHost/upscaleHost 只能吃一路（AuroraDriveApp.swift:6530–6551，本次复核：`client.poll()` 在 :6533、`takePixelBuffer()` 在 :6535、`upscaleHost.push` 在 :6536），两路同喂会打架。
4. **状态机冲突**：AuroraDriveApp.swift:6558–6563（本次复核仍准确） 的「引擎停抓 → UI 收尾」会把 isStreaming 复位，本地流启动后该判据需区分「引擎流」与「本地流」。
5. **优点**：OCR/预览帧源与本地模式完全一致（全分辨率、不依赖引擎 shm 档位）；缺点：双采集开销 + 产品决策 + 两处状态机耦合。

**结论**：**方向 A 是首选**——OCR 已经在引擎进程跑着，只缺心跳回传三个字段，UI 侧一次解析即可；方向 B 的任何变体都意味着双采集或显示源重构，仅在「引擎侧 OCR 无法满足实时性/精度」时再评估。两方向都需先解决第九节的「有帧=false」（引擎无帧则一切无输入）。

---

## 附：实测锚点表（2026-10-18 `grep -n` / `sed -n` 逐条实测，含 10-18 复核修订）

> 覆盖文件 `Sources/AuroraDrive/Capture/CaptureEngine.swift`（1584 行）。本次逐条核对了 CaptureEngine 28 条、EngineMain 18 条、AuroraDriveApp 12 条、EngineClient 2 条、AuroraFlags 3 条、QuestPanelReader 6 条引用。

| 符号 / 单元 | 行号 |
|---|---|
| `final class CaptureEngine` | :98 |
| `currentFrame` / `isCapturing` / `captureFPS` | :101 / :107 / :113 |
| `onFrame` / `onYoloFrame` / `onUpscaleFrame` / `isUpscaleWanted` / `onNativeFrame` | :121 / :126 / :130 / :138 / :143 |
| `nonisolated static let speedROINorm` | :148 |
| `enum CaptureStatus` | :155 |
| `captureQueue` / `stateLock` | :165 / :260 |
| `func start()` / `startStream(display:content:)` | :385 / :451 |
| `static func makeStreamConfiguration` / `func setCaptureHz` / `func stop()` / `func applyMode` | :579 / :657 / :703 / :905 |
| `func stream(_:didOutputSampleBuffer:of:)` / `autoreleasepool` | :1061 / :1076 |
| `makeYoloBufferPool` / `makeUIBufferPool` / `copyNativeFrame` / `nativeBufferPool` / `copyUpscaleFrame` / `upscaleBufferPool` / `updateFPS` | :1234 / :1260 / :1290 / :1335 / :1363 / :1394 / :1419 |

跨文件锚点（本文引用到的其他文件）：

| 符号 | 文件:行号 |
|---|---|
| `EngineMain.run()` / `tickOnce()` / `st.tick()` | EngineMain.swift:885 / :1193 / :1195 |
| `DriveState()` 创建 / `onUpscaleFrame` 覆盖接线 / `isUpscaleWanted` | EngineMain.swift:1042 / :1048–1051 / :1055 |
| `tickTimer` 装配 / 心跳 5 秒统计 / `hasFrame` | EngineMain.swift:1067–1081 / :1105–1130 / :1110 |
| `shm.publish` / `handleCommand` / `收到命令` | EngineMain.swift:1255–1263 / :1497 / :1504 |
| `final class DriveState` / `DriveState.shared` | AuroraDriveApp.swift:4150 / :4180 |
| `captureEngine` 声明 / `startDriving()` / 本地 `captureEngine.start()` | AuroraDriveApp.swift:5529 / :6190 / :6283 |
| 四路接线 `onFrame/onYolo/onNative/onUpscale/isUpscaleWanted` | AuroraDriveApp.swift:5988–6000 / :6003–6030 / :6032–6039 / :6041–6044 / :6046 |
| `questPanel` / `onConfirmed` 接线 | AuroraDriveApp.swift:5908 / :5981–5983 |
| `tick()` / `tickEngineMode()` / `client.poll()` / `takePixelBuffer()` | AuroraDriveApp.swift:6865 / :6522 / :6533 / :6534 |
| `questPanel.ingest` 门 / 推理入口 / `yolopxEngine.infer` | AuroraDriveApp.swift:6974 / :7154 / :7290 |
| `EngineClient.startup()` / `handleConnectionLoss` | EngineClient.swift:166 / **:553**（原写 :552 是 `/// - Parameter reason` 注释行，函数定义在 :553） |
| `AuroraFlags.uiLocal` / `questOCR` / `engineDiagCaptureOnly` | AuroraFlags.swift:138 / :201 / :162（本次复核：三处仍准确） |
| `final class QuestPanelReader` / `ingest(cgImage:)` | QuestPanelReader.swift:415 / :541（本次复核：类声明在 :415–416，:541 即 `ingest(cgImage:)`，准确） |
| `minInterval` / `voteNeed` / `fuzzyThreshold` / `fuzzyConfident` / `equivalentRadiusMeters` / `questROI` | QuestPanelReader.swift:431 / :427 / :434 / :440 / **:449** / :424（⚠️ 原表把 `equivalentRadiusMeters` 写成 :431，那是 `minInterval`；本行已按符号名逐一比对修正） |

---

### 2026-10-18 复核结论（T7）

| 类别 | 数量 | 说明 |
|---|---|---|
| CaptureEngine 本体锚点 | 28 条 | 27 条准确；**1 条需改**：`makeStreamConfiguration` `:578 → :579`（该行原本是 docstring，函数定义在 :579） |
| 内容性修正 | 4 处 | ①默认帧率 30fps → **20fps**（`_targetCaptureHz = 20.0`，`:186`；应急 45fps）②像素流 ~192 MB/s → **~85 MB/s**（`:481`，@20fps）③capGap ~33ms → **~50ms**（20fps 下 1/20s）④`setCaptureHz` 补「**2026-10-12 已接线**」注记（源码 `:654-657` 已自证旧「零外部调用」说法过期） |
| EngineMain.swift 行号 | 18 条 | 全部因 lead 10-18 改动而漂移 +5~+18，已逐条修正 |
| AuroraDriveApp.swift 行号 | 12 条 | 漂移 +2~+5，已逐条修正 |
| EngineClient / AuroraFlags / QuestPanelReader | 11 条 | 逐条复核**全部仍准确**，未改 |
| 需要产品决策 | 0 条 | 无。`AURORA_MAX_CLIPS` 不在 AuroraFlags 注册表（属 `RecordEngine.swift:45,59` 直读 environment 的 14 个开关之一），本文档未引用它，**无需改动** |
| 未验证 | 2 条 | ①9.1 节分支 5「流活着但帧没走到 onFrame 末尾」原文已自标「理论存在，未验证实际发生过」——维持原判；②10.2 节方向 B 的「双采集开销」原文已自标未验证——维持原判 |

**纪律确认**：本次仅改本文档，`Sources/` 下任何文件均未改动（git status 中的 7 个 M 是 lead 自己 10-18 改的，非本次）。
