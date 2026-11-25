# 代码-05 RecordEngine 录制引擎

> ✅ **2026-11-25 去行号化复核**：全文行号引用已全部替换为 `RecordEngine.swift` 中真实存在的符号名（`RecordEngine`、`start(perspective:)`、`stop()`、`flushSync()`、`pruneOldClips(in:)`、`appendFrame(...)`、`appendGlyphNative(pixelBuffer:)`、`resizeAndEncodeJPEG(image:size:)`、`encodeNativePNG(pixelBuffer:)`、`recordingsRoot`、`glyphRoot`、`maxClipsPerKind`、`defaultMaxClipsPerKind`、`maxPendingWrites`、`pendingWrites`、`_decPending()`、`csvHandle`、`RawKeySample` 等）。

> **2026-11-25 重基准（以代码为准）**：`Sources/AuroraDrive/Capture/RecordEngine.swift` 当前版本（全文件，从文件头注释到 `encodeNativePNG(pixelBuffer:)` 收尾）。原文档的若干数值描述已被代码演进超越，本次按源码改写：
> 1. **CSV 已是 17 列**：前 9 列 V2 连续量（`t_sec,frame,steer,throttle,brake,speed_kmh,heading,curvature,speed_limit`）+ 后 8 列 V3 原生按键（`w,a,s,d,shift,space,super_brake,ultimate_brake`），表头由 `start()` 内的 `header` 常量拼接；`dataset_v3` 按列名取值、忽略多余列，`dataset_v2` 先判 `speed_kmh`+`curvature` 走 v2_new 分支，故一份数据喂两条训练管道。
> 2. **`targetFps` 现为 15**（`let targetFps: Double = 15`），不是 20 也不是 24。源码注释记录：2026-10-22 起推理定档 15Hz（`EngineMain.tickHz` 两档都返回 15.0），20 已超 `dataset_v3.EXPECTED_FPS` 的 15% 容差。
> 3. **`maxClipsPerKind` 默认 200 已抽成常量 `static let defaultMaxClipsPerKind = 200`**（计算属性 `maxClipsPerKind` 的第三优先级），优先级仍为 `AURORA_MAX_CLIPS` 环境变量 > `maxClipsOverride` > `defaultMaxClipsPerKind`。
> 4. **`maxPendingWrites = 1`**（`private static let maxPendingWrites = 1`）✅
> 5. **`AURORA_MAX_CLIPS` 仍不在 AuroraFlags 注册表**：只在 `maxClipsPerKind` 计算属性与 `pruneOldClips(in:)` 日志措辞两处直读 `ProcessInfo.environment`（全仓 `AuroraFlags.swift` 无此键）。
> 6. **`appendFrame` 现为 9 参数**：除 4 个车辆状态可选参数外，还有一个 `keys: RawKeySample = RawKeySample()`（V3 原生按键标签，不传则全 0）。
> 7. ⚠️ `resizeAndEncodeJPEG` 的源码注释仍写「保持比例填充，可能裁切」，但实现是 `context.draw(cgImage, in: CGRect(origin: .zero, size: size))` —— **纯拉伸填满**（无 aspect-fit、无裁切裁剪），任意其它源宽高比会被拉变形（实测 +15.6% 各向异性，见 `docs/整合文档/05-性能与优化全史.md` §2.5）。**源码注释本身有误，文档如实记录**。
> 8. ⚠️ 源码头注释与 `targetFps` 上方注释里仍留有「20fps / 约 230GB/天」的旧口径；按 15fps 估算约 115GB/天（230 × 15/30）。**源码注释未完全同步，文档按代码实际值记录**。

> 覆盖源文件：`Sources/AuroraDrive/Capture/RecordEngine.swift`（全文件）。

## 一、录制参数、模式与输出格式

**类型声明**：`@Observable final class RecordEngine: @unchecked Sendable`——@Observable 让 UI 观察录制状态与已录帧数；主线程跑 `appendFrame` / `start` / `stop`，后台串行队列做编码+写文件。同文件另有 `struct RawKeySample`（V3 纯按键标签值类型：`w/a/s/d/shift/space` 六个原子键 + 派生 `superBrake`、`ultimateBrake`、`hasAnyKey`）。

**输出格式**（文件头注释）——兼容 `recordings/{perspective}_{timestamp}/` 格式：

```
frames/00000.jpg   (640x360 JPEG)
controls.csv       (17 列：9 列 V2 连续量 + 8 列 V3 原生按键)
meta.json          (录制元信息)
```
> ⚠️ 文件头注释里「controls.csv 前 9 列 / 后 8 列」的说明已同步，但同段仍保留旧 5 列的历史注记；**以 `start()` 内 `header` 常量的 17 列为准**。

**四个设计要点（源注释原文）**：① 异步写盘——主线程只入队，后台串行队列做缩放+写文件；② 帧顺序保证——单后台串行队列，FIFO；③ 内存安全——一帧写完即释放，不缓存多帧；④ 停止时写 `meta.json` 并 flush，保证数据完整。

**录制参数：**

| 参数 | 值 | 说明 |
|---|---|---|
| `targetSize` | `CGSize(width: 640, height: 360)` | 输出帧尺寸（16:9 横屏，与 m9_mono 输入 180×320 同比例；训练端 MonoClipsDataset 等比缩放） |
| `targetFps` | `15`（`let targetFps: Double = 15`） | 录制帧率上限（Hz），必须与真实 tick 频率一致；此值写进 `meta.json` 供下游反算时间轴。**实际帧率以 `appendFrame` 调用频率为准** |
| `maxClipsPerKind` | 计算属性，默认 `defaultMaxClipsPerKind = 200`（可被 `AURORA_MAX_CLIPS` / `maxClipsOverride` 覆盖） | 每类 clip 目录保留上限：录制启动时删最旧目录。源码注释记 640×360 JPEG 的日积估算（旧 30fps/230GB·天 口径已过时）。**raw_clips 与 glyph_clips 共用此上限** |

**字模模式：**

- `var glyphMode = false`——开启后录制「原生分辨率速度表区域 PNG」供字模训练，**不写训练录制帧（640×360 JPEG）与控制量**（字模只关心画面）。默认关，不影响训练录制
- **时序约定**（`glyphMode` 声明上方注释）：值仅在 `start()` 时被读取一次用于决定会话输出形态，**录制中途切换不生效**（需停止后重新开始录制才应用新值）
- `glyphRoot`（计算属性）：`AuroraPaths.projectRoot() + data + glyph_clips`——与训练 raw_clips 隔离，互不干扰
- `var expertMode = false`：专家模式标志，true = 录真人物理按键（标签来自 `KeyboardMonitor`）；**不参与录制逻辑**，只用于 `stop()` 时判断是否做「专家模式标签全零」告警，由 `EngineMain` 的 `case "record"` 在 start 时同步

**状态与内部资源：**

| 成员 | 说明 |
|---|---|
| `isRecording`（private(set)） | 是否正在录制 |
| `frameCount`（private(set)） | 已录制帧数（UI 实时展示） |
| `sessionURL`（private(set)） | 本次录制会话目录 URL |
| `sessionPerspective`（private(set)） | 本次会话视角，`start()` 里归一化后记录，`stop()` 写 meta.json 时用（与 view.txt 同源） |
| `labeledFrameCount`（private(set)） | 本会话标签非零的帧数（专家模式标签全零检测） |
| `frameWriteFailureCount`（private(set)） | 本会话帧编码/写盘失败帧数（2026-11-03 新增的静默失效防线） |
| `sessionExpertMode`（private(set)） | 本会话是否专家模式启动（决定 stop 告警） |
| `startTime`（private） | 录制开始时间（用于时间戳） |
| `writeQueue` | 后台串行写盘队列（`com.aurora.record.write`，保证帧顺序） |
| `maxPendingWrites`（static = 1） | **写盘背压阈值**：待处理帧数超过即丢帧（帧号不入队不自增，保持写入帧号连续）；`appendFrame` 与 `appendGlyphNative` 共用，保证两路录制背压行为一致 |
| `pendingLock` / `pendingWrites`（`NSLock` 保护） | 背压计数：主线程入队前自增，后台写完自减 |
| `_decPending()` | Swift 6：defer 块在 async 闭包内被视为 isolated local function，直接访问 `self?.pendingWrites` 会触发非 Sendable 捕获错误——**提取为私有方法由 defer 调用**（`appendFrame` 与 `appendGlyphNative` 的写盘闭包均调用它） |
| `csvHandle: FileHandle?` | CSV 追加写句柄。**线程约定**（其声明上方注释）：主线程在 `start()` 创建并赋值，`stop()` 中经 `writeQueue.sync` 关闭置 nil；实际 write 只在 `writeQueue` 串行队列内执行。依靠「主线程建 → writeQueue 串行写」的提交顺序 happens-before 保序，**不额外加锁**（避免每帧写盘引入锁开销） |
| `dirFormatter` | `yyyyMMdd_HHmmss` + `en_US_POSIX`（唯一目录名） |
| `isoFormatter` | ISO8601 `.withInternetDateTime`（meta.json 用） |
| `recordingsRoot`（计算属性） | `AuroraPaths.projectRoot() + data + raw_clips`——录制输出根目录（训练端 mono_dataset 默认扫描路径）。计算属性：@Observable 宏不追踪（路径不变），避免 lazy 冲突 |

## 二、start / stop / flushSync 与磁盘清理

**`start(perspective: String = "first")`**：

1. `guard !isRecording else { return }`（幂等）
2. **视角归一化**：`Self.normalizePerspective(perspective)`，非法值一律回落 `Perspective.first`（不抛错：录制是主流程）
3. **磁盘上限清理**：`pruneOldClips(in: recordingsRoot)` + `pruneOldClips(in: glyphRoot)`——**只在启动时清理，不在录制中动当前 clip**；两个根都纳入
4. **字模模式分支**：`if glyphMode` 时——建 `glyphRoot/clip_<ts>/frames/` 目录（不写 view.txt / controls.csv，字模只关心原生画面帧），置 `sessionURL` / `startTime` / `frameCount` / `isRecording` 后 **直接 return**（与训练录制完全隔离）
5. **训练录制分支**：
   - 建 `recordingsRoot/clip_{yyyyMMdd_HHmmss}/frames/`——**训练端只扫 `clip_` 前缀**
   - **写视角标签**：`let viewLabel = (normalized == "first") ? "FPV" : "TPV"` 写入 `view.txt`——供训练端 `_clip_view` 过滤；同时记入 `sessionPerspective`
   - **初始化 CSV**：由 `header` 常量拼接 **17 列**表头，`FileManager.default.createFile` 建文件后 `FileHandle(forWritingAtPath:)` + `seekToEndOfFile()`。`header` 上方注释记录为何从 5 列扩到 9 列再追加 8 列：`dataset_v2.py` 的 `_load_controls_csv` 期望 9 字段，缺 4 列会让 `vehicle_state[10]` 的 speed/accel/heading/curvature 全为 0 → **模型把 0 当真实状态学**；缺值语义**写空串不写 0**（`_safe_float("")` → None → mask=0）
   - 重置状态：`sessionURL` / `startTime` / `frameCount = 0` / `labeledFrameCount = 0` / `frameWriteFailureCount = 0` / `sessionExpertMode = expertMode` / `isRecording = true`

**`stop()`**：

1. `guard isRecording else { return }`，置 `isRecording = false`
2. **P1 修复**：**先把 CSV 句柄同步 flush+关闭，再判 guard**——旧代码 guard 提前 return 会漏关 `csvHandle`（fd 泄漏）；`writeQueue.sync { csvHandle?.synchronizeFile(); closeFile(); csvHandle = nil }` 强制 fsync 保证已写行落盘，且 sync 排在已入队 `appendFrame` 写块之后执行
3. 捕获会话信息（`sessionURL` / `startTime`），算 `totalFrames` / `duration`；**全部定值在进入 async 前捕获**（闭包异步执行时属性可能已被下一次 `start()` 清零）
4. **字模模式 meta**：`if glyphMode` 时无 CSV，写简单 meta.json（`glyph_mode: true, total_frames, created_at, duration_seconds`），`writeQueue.async` 写，return
5. **训练模式 meta 与两条告警**（在写 meta 前执行）：
   - **专家模式标签全零告警**：`if sessionExpertMode, totalFrames >= 30, labeledFrameCount == 0` → 打印大声告警（判定阈值取严格全零，避免误报）；源码注释解释引擎进程 `dispatchMain()` 无 run loop、从未申请 Input Monitoring，极可能收不到物理按键，而 CSV 照写、帧数照涨——**静默失效最危险**
   - **帧文件写盘失败告警**：`if frameWriteFailureCount > 0` → 打印「CSV 有 N 行、图却少 M 张」的告警；源码注释记录缺 1 帧会让其后 23 个样本的 24 帧窗口全部不可用（`dataset_v3.__getitem__` 抛 FileNotFoundError）
   - **完整 meta.json 字段**：`capture_interval_ms: Int(1000.0/fps), target_h, target_w, total_frames, created_at, duration_seconds, perspective, expert_mode, labeled_frames, labeling_ok, frame_write_failures, frames_complete`（`perspective` 取 `sessionPerspective`；旧代码取目录名首段恒为 `clip` 的坏字段已修）

**`flushSync()`**：`writeQueue.sync { }`——**等待写盘队列排空（含 `stop()` 里异步写的 meta.json）**。用途：进程即将 exit 前调用——`stop()` 的 meta.json 是 `writeQueue.async` 写的，直接 `exit(0)` 会在元信息落盘前杀掉进程，导致录制会话缺 meta.json。

**`pruneOldClips(in root: URL)`**——清理最旧 clip 目录，仅保留最近 `maxClipsPerKind` 个：

- `fm.contentsOfDirectory(at:includingPropertiesForKeys:options:)` 取目录项（`[.isDirectoryKey]` + `[.skipsHiddenFiles]`）
- 过滤 `clip_` 前缀，**按目录名字典序升序排序（最旧在前）**——`clip_yyyyMMdd_HHmmss` 同格式，字典序即时间序
- `clipDirs.count > limit` 才删：`clipDirs.prefix(clipDirs.count - limit)` 逐个 `removeItem`
- 全部 `try?`——清理失败不阻塞录制启动
- **日志措辞含 AURORA_MAX_CLIPS 提示**：`pruneOldClips(in:)` 末尾又读一次 `ProcessInfo.environment["AURORA_MAX_CLIPS"]`，只为判断日志里该说「环境变量 AURORA_MAX_CLIPS」「UI 设置」还是「默认值」，并打印「要保留更多请设 AURORA_MAX_CLIPS=1000」。⚠️ 这是**第二处直读 environment**（第一处在 `maxClipsPerKind` 计算属性）——两处读同一个键，`AURORA_MAX_CLIPS` 全程不走 AuroraFlags 注册表。

## 三、appendFrame / appendGlyphNative 与两个编码器

**`appendFrame(image:steer:throttle:brake:speedKmh:headingDeg:curvature:speedLimit:keys:)`**——追加一帧（画面 + 控制量 + 车辆状态 + 按键），主线程调用：

1. `guard isRecording, let start = startTime, let url = sessionURL else { return }`
2. `timestamp = Date().timeIntervalSince(start)`（相对录制起点的秒）
3. **背压判定**：`pendingLock` 内读 `pendingWrites`，`guard pending <= Self.maxPendingWrites else { return }`——**丢帧时帧号不入队不自增，保持写入帧号连续**；配合写盘闭包内 `autoreleasepool` 封顶内存，防 7×24 长录时编码慢于采集导致 NSImage 在队列里无限堆积
4. `idx = frameCount` → `frameCount += 1`；**标签健康统计**：`abs(steer) > 1e-9 || throttle > 1e-9 || brake > 1e-9 || keys.hasAnyKey` 时 `labeledFrameCount += 1`（按键也算标签，否则「录到按键却仍报警」）
5. `pendingWrites += 1`（锁内）
6. `writeQueue.async { [weak self, image] in defer { self?._decPending() } ... }`——串行队列保证帧顺序（FIFO）：
   - **`autoreleasepool`（P1 修复）**：NSImage 被强捕获进写盘闭包，缩放/编码产生大量临时对象，闭包不自动包池，背压窗口内的多帧叠加会放大峰值内存、诱发缓冲池扩容——帧末及时释放
   - 缩放编码 JPEG → 写 `frames/%06ld.jpg`（`String(format: "%06ld.jpg", idx)`）；编码失败与写盘失败**都计入 `frameWriteFailureCount`**（各只在前 3 次打印详情）
   - CSV 追加：先由局部 `fmtOpt(_:)` 对 nil/非有限值返回**空串**（不写 0），再由 `keyCols` 拼出 8 个按键列，最后 `String(format:)` 统一写入 `csvHandle`。源码注释说明为何用 `%@` 而非 8 个 `%d` 占位符：Swift 的 Int 在 CVarArg 里与 C 的 `%d`（期望 Int32）宽度不匹配，混用会读到错位或垃圾值

**`appendGlyphNative(pixelBuffer:)`**——字模模式专用，主线程调用：

- 参数：`CaptureEngine` 的 `onNativeFrame` 投递的原生 ROI 缓冲（speedROINorm 区域，**原生分辨率未缩放——数字 ~95px**）
- **帧号/背压逻辑与 `appendFrame` 完全一致**（共用 `pendingWrites` 计数 + 丢帧阈值 `maxPendingWrites=1`）
- 直接编码 PNG 存盘 `frames/%06ld.png`；不写 640×360 训练帧 / CSV（字模只关心画面）

**`resizeAndEncodeJPEG(image:size:) -> Data?`**：

1. `image.cgImage(forProposedRect:context:hints:)` 取 CGImage
2. 创建目标位图上下文：`CGContext(data: nil, width:, height:, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)`（bytesPerRow: 0 = 自动）
3. `context.interpolationQuality = .high` + `context.draw(cgImage, in: CGRect(origin: .zero, size: size))`
   ⚠️ **源码注释写「保持比例填充，可能裁切，与 UI 显示一致」——与实现不符**：`draw(in:)` 传入的 CGRect 尺寸就是目标尺寸，无 aspect-fit 计算、无裁切裁剪逻辑，是**纯拉伸填满**。实际效果 = 各向异性缩放，源 16:9 到 640×360 恰好同比不失真，但**任意其它源宽高比会被拉变形**（实测 +15.6% 各向异性，见 `docs/整合文档/05-性能与优化全史.md` §2.5）。**源码注释本身有误**
4. `context.makeImage()` → `NSBitmapImageRep(cgImage:)` → JPEG **质量 0.9**（`compressionFactor: 0.9`，训练端 mono_dataset 读 .jpg，平衡清晰度/体积）

**`encodeNativePNG(pixelBuffer:) -> Data?`**——原生 ROI 编码 PNG（不缩放、无损失）：

- **P1-2 修复**：字模录制改走原生路径（不再从 480px UI 缩略图裁剪 → 数字 ~95px 恢复）
- `CVPixelBufferLockBaseAddress` + defer 解锁 → 取 base/宽高（`CVPixelBufferGetWidth/Height/BytesPerRow`）
- bitmapInfo：`premultipliedFirst | byteOrder32Little` == BGRA 内存序——**与 `CaptureEngine` 原生 ROI 池（`copyNativeFrame`）的像素格式一致**
- `CGContext(data: base, ...)` **直接引用缓冲基址** → `makeImage()` → `NSBitmapImageRep.representation(using: .png)`
- 无 CIContext、**无方向翻转**（缓冲行序 top-down 与屏幕一致，字模训练所见即所得）
- 编码失败返回 nil（不阻塞录制主流程）

**RecordEngine 文档至此完整**（全文件覆盖：参数与格式 → 启停与清理 → 帧追加与编码）。
