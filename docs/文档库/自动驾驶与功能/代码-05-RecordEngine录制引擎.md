# 代码-05 RecordEngine 录制引擎

> 覆盖源文件：`Sources/AuroraDrive/Capture/RecordEngine.swift`（424 行）。基于当前仓库逐单元编写。

## 一、录制参数、模式与输出格式（第 1–107 行）

**类声明（第 25–26 行）**：`@Observable final class RecordEngine: @unchecked Sendable`——@Observable 让 UI 观察录制状态与已录帧数；主线程跑 appendFrame/start/stop，后台串行队列做编码+写文件。

**输出格式（4–15 行头注释）**——兼容现有 `recordings/{perspective}_{timestamp}/` 格式：

```
frames/00000.jpg   (640x360 JPEG)
controls.csv       (timestamp,frame,steer,throttle,brake)
meta.json          (录制元信息)
```

**四个设计要点（源注释原文）**：① 异步写盘——主线程只入队，后台串行队列做缩放+写文件；② 帧顺序保证——单后台串行队列，FIFO；③ 内存安全——一帧写完即释放，不缓存多帧；④ 停止时写 meta.json 并 flush，保证数据完整。

**录制参数：**

| 参数 | 值 | 说明 |
|---|---|---|
| `targetSize` | `CGSize(width: 640, height: 360)` | 输出帧尺寸（16:9 横屏，与 m9_mono 输入 180×320 同比例；训练端 MonoClipsDataset 等比缩放） |
| `targetFps` | `24` | 录制帧率上限（Hz），与推理同频；**实际帧率以 appendFrame 调用频率为准**，此值仅用于 meta 记录 |
| `maxClipsPerKind` | `10` | 每类 clip 目录保留上限：录制启动时删最旧目录。源注释估算了不清理的后果：640×360 JPEG 30fps 日积约 230GB/天撑爆磁盘。**可调常量：调大保留更多历史，调小更省磁盘（raw_clips 与 glyph_clips 共用此上限）** |

**字模模式（第 43–56 行）**：

- `var glyphMode = false`——开启后录制「原生分辨率速度表区域 PNG」供字模训练，**不写训练录制帧（640×360 JPEG）与控制量**（字模只关心画面）。默认关，不影响训练录制
- **时序约定（47–48 行注释）**：值仅在 `start()` 时被读取一次用于决定会话输出形态，**录制中途切换不生效**（需停止后重新开始录制才应用新值）
- `glyphRoot`（计算属性，52–56 行）：`AuroraPaths.projectRoot() + data + glyph_clips`——与训练 raw_clips 隔离，互不干扰

**状态与内部资源（第 58–114 行）：**

| 成员 | 说明 |
|---|---|
| `isRecording`（private(set)） | 是否正在录制 |
| `frameCount`（private(set)） | 已录制帧数（UI 实时展示） |
| `sessionURL`（private(set)） | 本次录制会话目录 URL |
| `startTime`（private） | 录制开始时间（用于时间戳） |
| `writeQueue` | 后台串行写盘队列（`com.aurora.record.write`，保证帧顺序） |
| `maxPendingWrites`（static = 1） | **写盘背压阈值**：待处理帧数超过即丢帧（帧号不入队不自增，保持写入帧号连续）；appendFrame 与 appendGlyphNative 共用，保证两路录制背压行为一致 |
| `pendingWrites`（NSLock 保护） | 背压计数：主线程入队前自增，后台写完自减 |
| `_decPending()`（89–93 行） | Swift 6：defer 块在 async 闭包内被视为 isolated local function，直接访问 self?.pendingWrites 会触发非 Sendable 捕获错误——**提取为私有方法由 defer 调用** |
| `csvHandle: FileHandle?` | CSV 追加写句柄。**线程约定（96–98 行）**：主线程在 start() 创建并赋值，stop() 中经 writeQueue.sync 关闭置 nil；实际 write 只在 writeQueue 串行队列内执行。依靠"主线程建 → writeQueue 串行写"的提交顺序 happens-before 保序，**不额外加锁**（避免每帧写盘引入锁开销） |
| `dirFormatter` | `yyyyMMdd_HHmmss` + `en_US_POSIX`（唯一目录名） |
| `isoFormatter` | ISO8601 `.withInternetDateTime`（meta.json 用） |
| `recordingsRoot`（计算属性，121–125 行） | `AuroraPaths.projectRoot() + data + raw_clips`——录制输出根目录（训练端 mono_dataset 默认扫描路径）。计算属性：@Observable 宏不追踪（路径不变），避免 lazy 冲突 |

## 二、start / stop / flushSync 与磁盘清理（第 129–272 行）

**`start(perspective: String = "first")`（第 131–184 行）**：

1. `guard !isRecording else { return }`（幂等）
2. **磁盘上限清理（134–137 行）**：`pruneOldClips(in: recordingsRoot)` + `pruneOldClips(in: glyphRoot)`——**只在启动时清理，不在录制中动当前 clip**；两个根都纳入
3. **字模模式分支（141–154 行）**：`glyphMode == true` 时——建 `glyphRoot/clip_<ts>/frames/` 目录（不写 view.txt / controls.csv，字模只关心原生画面帧），置 sessionURL/startTime/frameCount/isRecording 后 **直接 return**（与训练录制完全隔离）
4. **训练录制分支（156–183 行）**：
   - 建 `recordingsRoot/clip_{yyyyMMdd_HHmmss}/frames/`——**训练端只扫 `clip_` 前缀**
   - **写视角标签（166–169 行）**：`viewLabel = (perspective == "first") ? "FPV" : "TPV"` 写入 `view.txt`——供训练端 `_clip_view` 过滤
   - **初始化 CSV（171–177 行）**：`controls.csv` 写表头 `"t_sec,frame,steer,throttle,brake\n"`，`FileHandle(forWritingAtPath:)` + `seekToEndOfFile()`
   - 重置状态：sessionURL/startTime/frameCount=0/isRecording=true

**`stop()`（第 187–246 行）**：

1. `guard isRecording else { return }`，置 `isRecording = false`
2. **P1 修复（191–200 行）**：**先把 CSV 句柄同步 flush+关闭，再判 guard**——旧代码 guard 提前 return 会漏关 csvHandle（fd 泄漏）；`writeQueue.sync { self.csvHandle?.synchronizeFile(); closeFile(); csvHandle = nil }` 强制 fsync 保证已写行落盘，且 sync 排在已入队 appendFrame 写块之后执行
3. 捕获会话信息（url/start），算 totalFrames/duration
4. **字模模式 meta（208–223 行）**：无 CSV，写简单 meta.json（`glyph_mode: true, total_frames, created_at, duration_seconds`），writeQueue.async 写，return
5. **训练模式 meta（225–245 行）**：完整格式 meta.json——`capture_interval_ms: Int(1000.0/fps), target_h, target_w, total_frames, created_at, duration_seconds, perspective`（perspective 从 url.lastPathComponent 取 `_` 前第一段）。writeQueue.async 异步写

**`flushSync()`（第 251–253 行）**：`writeQueue.sync { }`——**等待写盘队列排空（含 stop() 里异步写的 meta.json）**。用途：进程即将 exit 前调用——stop() 的 meta.json 是 writeQueue.async 写的，直接 `exit(0)` 会在元信息落盘前杀掉进程，导致录制会话缺 meta.json。

**`pruneOldClips(in root: URL)`（第 260–272 行）**——清理最旧 clip 目录，仅保留最近 maxClipsPerKind 个：

- `contentsOfDirectory(includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])`
- 过滤 `clip_` 前缀，**按目录名字典序升序排序（最旧在前）**——`clip_yyyyMMdd_HHmmss` 同格式，字典序即时间序
- `clipDirs.count > maxClipsPerKind` 才删：`prefix(clipDirs.count - maxClipsPerKind)` 逐个 `removeItem`
- 全部 `try?`——清理失败不阻塞录制启动

## 三、appendFrame / appendGlyphNative 与两个编码器（第 274–424 行）

**`appendFrame(image:steer:throttle:brake:)`（第 283–331 行）**——追加一帧（画面 + 控制量），主线程调用：

1. `guard isRecording, let start = startTime, let url = sessionURL else { return }`
2. `timestamp = Date().timeIntervalSince(start)`（相对录制起点的秒）
3. **背压判定（288–295 行）**：读 `pendingWrites`（锁内），`guard pending <= Self.maxPendingWrites else { return }`——**丢帧时帧号不入队不自增，保持写入帧号连续**；配合写盘闭包内 autoreleasepool 封顶内存，防 7×24 长录时编码慢于采集导致 NSImage 在队列里无限堆积
4. `idx = frameCount` → `frameCount += 1` → `pendingWrites += 1`（锁内）
5. `writeQueue.async { [weak self, image] in defer { self?._decPending() } ... }`——串行队列保证帧顺序（FIFO）：
   - **autoreleasepool（311–315 行，P1 修复）**：NSImage 被强捕获进写盘闭包，缩放/编码产生大量临时对象，闭包不自动包池，背压窗口内的多帧叠加会放大峰值内存、诱发缓冲池扩容——帧末及时释放
   - 缩放编码 JPEG → 写 `frames/%06ld.jpg`（`String(format: "%06ld.jpg", idx)`）
   - CSV 追加：`String(format: "%.4f,%ld,%.4f,%.4f,%.4f\n", timestamp, idx, steer, throttle, brake)` → `csvHandle?.write`

**`appendGlyphNative(pixelBuffer:)`（第 338–362 行）**——字模模式专用，主线程调用：

- 参数：CaptureEngine `onNativeFrame` 投递的原生 ROI 缓冲（speedROINorm 区域，**原生分辨率未缩放——数字 ~95px**）
- **帧号/背压逻辑与 appendFrame 完全一致**（共用 pendingWrites 计数 + 丢帧阈值 maxPendingWrites=1）
- 直接编码 PNG 存盘 `frames/%06ld.png`；不写 640×360 训练帧 / CSV（字模只关心画面）

**`resizeAndEncodeJPEG(image:size:) -> Data?`（第 368–394 行）**：

1. `image.cgImage(forProposedRect: nil, context: nil, hints: nil)` 取 CGImage
2. 创建目标位图上下文：RGB 颜色空间、`premultipliedLast`、`bytesPerRow: 0`（自动）
3. `context.interpolationQuality = .high` + `context.draw(cgImage, in: CGRect(origin: .zero, size: size))`——**保持比例填充，可能裁切，与 UI 显示一致**（源注释）
4. `context.makeImage()` → `NSBitmapImageRep(cgImage:)` → JPEG **质量 0.9**（训练端 mono_dataset 读 .jpg，平衡清晰度/体积）

**`encodeNativePNG(pixelBuffer:) -> Data?`（第 403–423 行）**——原生 ROI 编码 PNG（不缩放、无损失）：

- **P1-2 修复**：字模录制改走原生路径（不再从 480px UI 缩略图裁剪 → 数字 ~95px 恢复）
- `CVPixelBufferLockBaseAddress` + defer 解锁 → 取 base/宽高
- bitmapInfo：`premultipliedFirst | byteOrder32Little` == BGRA 内存序——**与 CaptureEngine 原生 ROI 池（copyNativeFrame）的像素格式一致**
- `CGContext(data: base, ...)` **直接引用缓冲基址** → `makeImage()` → `NSBitmapImageRep.png`
- 无 CIContext、**无方向翻转**（缓冲行序 top-down 与屏幕一致，字模训练所见即所得）
- 编码失败返回 nil（不阻塞录制主流程）

**RecordEngine 文档至此完整**（424 行全覆盖：参数与格式 → 启停与清理 → 帧追加与编码）。