# 代码-05 RecordEngine 录制引擎

> ✅ **2026-10-18 复核**（`wc -l` = 623 行）：逐条 `read` 核实全部行号锚点 + 参数值，发现并修正以下问题：
> 1. 🔴 **CSV 列数错误**：文档原写「5 列 `t_sec,frame,steer,throttle,brake`」——实际为 **9 列 v2 格式**（`:288` 表头 `t_sec,frame,steer,throttle,brake,speed_kmh,heading,curvature,speed_limit`，`:521` 数据行同 9 列）。源码注释 `:278-281` 明确记录：原 5 列 → 缺 4 列车辆状态 → `dataset_v2.py` 的 `vehicle_state[10]` 里 speed/accel/heading/curvature 全为 0 → **模型把 0 当真实状态学** → 新增 4 列追加在末尾（向后兼容）。已修正三处引用。
> 2. `targetFps = 20`（`:36`，✅ 已对齐 20Hz 定档，注释「2026-10-11 用户定档：推理 20Hz，故录制也 20」）。
> 3. `maxClipsPerKind` 默认 **200**（`:68` `return 200`；声明在 `:62`，计算属性；优先级：`AURORA_MAX_CLIPS` env > `maxClipsOverride` > 默认 200）。源码注释 `:48-54` 记录「原默认 10 → 2026-10-10 改 200（w4-tools V4 发现的血案：默认 10 意味着录到第 11 段就静默删第 1 段）」。
> 4. `maxPendingWrites = 1`（`:132`，✅ static let）。
> 5. `AURORA_MAX_CLIPS` 不在 AuroraFlags 注册表，是 `:63` 直读 `ProcessInfo.environment`（计算属性体内；✅ 与 Lead 提示一致）。
> 6. `appendFrame` 签名含 4 个可选车辆状态参数（`:465-467`），与 9 列 CSV 对应。
> 7. ⚠️ `resizeAndEncodeJPEG` 注释「保持比例填充，可能裁切」（`:583` 源码注释）与实现不符——`context.draw(in: CGRect(origin:.zero, size: size))`（`:584`）是纯拉伸填满（详见 `docs/整合文档/05-性能与优化全史.md` §2.5，各向异性 +15.6%）。**源码注释本身有误，文档如实记录**。
> 8. ⚠️ 源码 `:39` 注释「640×360 JPEG 30fps 日积约 230GB/天」——30fps 是 20Hz 定档前的旧口径，20fps 下应约 153GB/天。**源码注释未同步，文档保留原文引用但标注**。
>
> **2026-10-18 二次复核（T6，Lead 指派）**：Lead 给的 7 项核查清单**逐条实证全部成立**，另修正 3 处行号边界：
> - ✅ `targetFps = 20`（:36）——不是 24Hz
> - ✅ `maxClipsPerKind` 默认 **200**（:68 `return 200`；声明 :62；`AURORA_MAX_CLIPS` 读在 :63）
> - ✅ `targetSize = 640×360`（:31）
> - ✅ `maxPendingWrites = 1`（:132）
> - ✅ CSV **9 列**（表头 :288-289，数据行 :521-523）
> - ✅ `AURORA_MAX_CLIPS` **不在 AuroraFlags 注册表**，是 :63（`maxClipsPerKind` 计算属性体）与 :438（`pruneOldClips` 日志措辞）两处直读 `ProcessInfo.environment`；全仓 grep `AuroraFlags.swift` 无此键
> - ✅ 双模式：`raw_clips`（:174-179 `recordingsRoot`）vs `glyph_clips`（:84-89 `glyphRoot`）
> - **行号修正**：`glyphRoot` 文档写 84–88 → 实际 **84–89**；`recordingsRoot` 文档写 169–178 → 实际 **174–179**；`csvHandle` 线程约定注释 文档写 149–151 → 实际 **148–152**；`pruneOldClips` 文档写 420–440 → 实际 **420–440**（✓）；`stop()` 字模 meta 分支 326–341 实际 **326–341**（✓）。
> - **新增确认**：`_decPending()` 实际 **142–146**（✓）；写盘闭包 `autoreleasepool` 实际 **504**（文档写 500–504 ✓）；`:39` 的 230GB/天估算按 20fps 应为 **~153GB/天**（230 × 20/30）。

> ♻️ **行号已按 9097 行版重基准（2026-10-18）**——本篇对应 `RecordEngine.swift` **627 行**（lead 同日 +4 行：`:8` 头注释 CSV 列、`:41` 注释频段）。
>
> **本次实测 31 处，修正 27 处**。偏移规律：**`:77` 之前零漂移**（`:8`/`:31`/`:36`/`:39`/`:41` 全部命中），**`:88` 起统一 +4**（+4 行插在 `:77`~`:88` 之间）。
>
> 逐项：`maxClipsPerKind` return `200` 在 **:68**（原写 :62/:64 均错，:62 是声明）；`glyphMode` :73→**77**；`glyphRoot` :84-89→**88-93**；`isRecording` :93→**97**；`frameCount` :96→**100**；`sessionURL` :99→**103**；`startTime` :123→**127**；`writeQueue` :128→**132**；`maxPendingWrites` :132→**136**；`pendingWrites` :136-137→**140-141**；`_decPending` :142-146→**146-150**；`csvHandle` :152→**156**；`dirFormatter` :155→**159**；`isoFormatter` :163→**167**；`recordingsRoot` :174-179→**178-183**；`start()` :228-302→**232-306**；`stop()` :305-402→**309-406**；`flushSync()` :407-409→**411-413**；`pruneOldClips()` :420-440→**424-444**；`appendFrame()` :465-530→**469-534**；`appendGlyphNative()` :537-561→**541-565**；`resizeAndEncodeJPEG()` :567-593→**571-597**；`encodeNativePNG()` :602-622→**606-626**。
>
> **未决 0**。文中三处「源码注释本身有误」的记录（`:8` 旧 5 列、`:41` 30fps→20fps、`:583` 拉伸非裁切）**仍然成立**，已随行号更新。

> > 覆盖源文件：`Sources/AuroraDrive/Capture/RecordEngine.swift`（**627 行**，2026-10-18 `wc -l` 实测；lead 同日 +4 行）。基于当前仓库逐单元编写。

## 一、录制参数、模式与输出格式（第 1–178 行）

**类声明（第 25–26 行）**：`@Observable final class RecordEngine: @unchecked Sendable`——@Observable 让 UI 观察录制状态与已录帧数；主线程跑 appendFrame/start/stop，后台串行队列做编码+写文件。

**输出格式（4–15 行头注释）**——兼容现有 `recordings/{perspective}_{timestamp}/` 格式：

```
frames/00000.jpg   (640x360 JPEG)
controls.csv       (t_sec,frame,steer,throttle,brake,speed_kmh,heading,curvature,speed_limit)  ← 9 列 v2
meta.json          (录制元信息)
```
> ⚠️ 源码 `:8` 头注释仍写旧 5 列 `(timestamp,frame,steer,throttle,brake)`，**与 `:288` 实际表头 9 列不符**——头注释未同步，以实现为准。

**四个设计要点（源注释原文）**：① 异步写盘——主线程只入队，后台串行队列做缩放+写文件；② 帧顺序保证——单后台串行队列，FIFO；③ 内存安全——一帧写完即释放，不缓存多帧；④ 停止时写 meta.json 并 flush，保证数据完整。

**录制参数：**

| 参数 | 值 | 说明 |
|---|---|---|
| `targetSize` | `CGSize(width: 640, height: 360)` | 输出帧尺寸（16:9 横屏，与 m9_mono 输入 180×320 同比例；训练端 MonoClipsDataset 等比缩放） |
| `targetFps` | `20` | 录制帧率上限（Hz），与推理同频（2026-10-11 用户定档 20Hz）；**实际帧率以 appendFrame 调用频率为准**，此值仅用于 meta 记录 |
| `maxClipsPerKind` | `200`（可被 `AURORA_MAX_CLIPS` 环境变量 / `maxClipsOverride` 覆盖） | 每类 clip 目录保留上限：录制启动时删最旧目录。源注释估算了不清理的后果：640×360 JPEG 30fps 日积约 230GB/天撑爆磁盘。**可调常量：调大保留更多历史，调小更省磁盘（raw_clips 与 glyph_clips 共用此上限）** |

**字模模式（第 67–89 行）**：

- `var glyphMode = false`（**:77**）——开启后录制「原生分辨率速度表区域 PNG」供字模训练，**不写训练录制帧（640×360 JPEG）与控制量**（字模只关心画面）。默认关，不影响训练录制
- **时序约定（:71-72 注释）**：值仅在 `start()` 时被读取一次用于决定会话输出形态，**录制中途切换不生效**（需停止后重新开始录制才应用新值）
- `glyphRoot`（计算属性，**:88-93**）：`AuroraPaths.projectRoot() + data + glyph_clips`——与训练 raw_clips 隔离，互不干扰

**状态与内部资源（第 90–179 行）：**

| 成员 | 行号 | 说明 |
|---|---|---|
| `isRecording`（private(set)） | :97 | 是否正在录制 |
| `frameCount`（private(set)） | :100 | 已录制帧数（UI 实时展示） |
| `sessionURL`（private(set)） | :103 | 本次录制会话目录 URL |
| `startTime`（private） | :127 | 录制开始时间（用于时间戳） |
| `writeQueue` | :132 | 后台串行写盘队列（`com.aurora.record.write`，保证帧顺序） |
| `maxPendingWrites`（static = 1） | :136 | **写盘背压阈值**：待处理帧数超过即丢帧（帧号不入队不自增，保持写入帧号连续）；appendFrame（:479）与 appendGlyphNative（:544）共用，保证两路录制背压行为一致 |
| `pendingLock` / `pendingWrites`（NSLock 保护） | :140-141 | 背压计数：主线程入队前自增，后台写完自减 |
| `_decPending()` | :146-150 | Swift 6：defer 块在 async 闭包内被视为 isolated local function，直接访问 self?.pendingWrites 会触发非 Sendable 捕获错误——**提取为私有方法由 defer 调用**（调用点 :501/:557） |
| `csvHandle: FileHandle?` | :156 | CSV 追加写句柄。**线程约定（:152-156 注释）**：主线程在 start() 创建并赋值，stop() 中经 writeQueue.sync 关闭置 nil；实际 write 只在 writeQueue 串行队列内执行。依靠"主线程建 → writeQueue 串行写"的提交顺序 happens-before 保序，**不额外加锁**（避免每帧写盘引入锁开销） |
| `dirFormatter` | :159 | `yyyyMMdd_HHmmss` + `en_US_POSIX`（唯一目录名） |
| `isoFormatter` | :167 | ISO8601 `.withInternetDateTime`（meta.json 用） |
| `recordingsRoot`（计算属性） | :178-183 | `AuroraPaths.projectRoot() + data + raw_clips`——录制输出根目录（训练端 mono_dataset 默认扫描路径）。计算属性：@Observable 宏不追踪（路径不变），避免 lazy 冲突 |

## 二、start / stop / flushSync 与磁盘清理（第 180–440 行）

**`start(perspective: String = "first")`（第 232–306 行）**：

1. `guard !isRecording else { return }`（幂等）
2. **磁盘上限清理（237–240 行）**：`pruneOldClips(in: recordingsRoot)` + `pruneOldClips(in: glyphRoot)`——**只在启动时清理，不在录制中动当前 clip**；两个根都纳入
3. **字模模式分支（242–257 行）**：`glyphMode == true` 时——建 `glyphRoot/clip_<ts>/frames/` 目录（不写 view.txt / controls.csv，字模只关心原生画面帧），置 sessionURL/startTime/frameCount/isRecording 后 **直接 return**（与训练录制完全隔离）
4. **训练录制分支（259–301 行）**：
   - 建 `recordingsRoot/clip_{yyyyMMdd_HHmmss}/frames/`——**训练端只扫 `clip_` 前缀**
   - **写视角标签（269–273 行）**：`viewLabel = (perspective == "first") ? "FPV" : "TPV"` 写入 `view.txt`——供训练端 `_clip_view` 过滤
   - **初始化 CSV（275–293 行）**：`controls.csv` 写 **9 列**表头 `"t_sec,frame,steer,throttle,brake,speed_kmh,heading,curvature,speed_limit\n"`（`:288-289`），`FileHandle(forWritingAtPath:)` + `seekToEndOfFile()`。源码 `:278-286` 注释记录为何从 5 列扩到 9 列：`dataset_v2.py` 的 `_load_controls_csv` 期望 9 字段，缺 4 列会让 `vehicle_state[10]` 的 speed/accel/heading/curvature 全为 0 → **模型把 0 当真实状态学**；缺值语义**写空串不写 0**（`_safe_float("")` → None → mask=0，可区分「真值 0」与「读不到」）
   - 重置状态：sessionURL/startTime/frameCount=0/isRecording=true

**`stop()`（第 309–406 行）**：

1. `guard isRecording else { return }`，置 `isRecording = false`
2. **P1 修复（309–318 行）**：**先把 CSV 句柄同步 flush+关闭，再判 guard**——旧代码 guard 提前 return 会漏关 csvHandle（fd 泄漏）；`writeQueue.sync { self.csvHandle?.synchronizeFile(); closeFile(); csvHandle = nil }` 强制 fsync 保证已写行落盘，且 sync 排在已入队 appendFrame 写块之后执行
3. 捕获会话信息（url/start），算 totalFrames/duration
4. **字模模式 meta（326–341 行）**：无 CSV，写简单 meta.json（`glyph_mode: true, total_frames, created_at, duration_seconds`），writeQueue.async 写，return
5. **训练模式 meta（343–401 行）**：完整格式 meta.json——`capture_interval_ms: Int(1000.0/fps), target_h, target_w, total_frames, created_at, duration_seconds, perspective`（perspective 从 url.lastPathComponent 取 `_` 前第一段）。writeQueue.async 异步写

**`flushSync()`（第 411–413 行）**：`writeQueue.sync { }`——**等待写盘队列排空（含 stop() 里异步写的 meta.json）**。用途：进程即将 exit 前调用——stop() 的 meta.json 是 writeQueue.async 写的，直接 `exit(0)` 会在元信息落盘前杀掉进程，导致录制会话缺 meta.json。

**`pruneOldClips(in root: URL)`（第 424–444 行）**——清理最旧 clip 目录，仅保留最近 maxClipsPerKind 个：

- `contentsOfDirectory(includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])`（:421-424）
- 过滤 `clip_` 前缀，**按目录名字典序升序排序（最旧在前）**——`clip_yyyyMMdd_HHmmss` 同格式，字典序即时间序（:426-430）
- `clipDirs.count > maxClipsPerKind` 才删：`prefix(clipDirs.count - maxClipsPerKind)` 逐个 `removeItem`（:428-436）
- 全部 `try?`——清理失败不阻塞录制启动
- **日志措辞含 AURORA_MAX_CLIPS 提示**（:434-439）：`:434` 又读了一次 `ProcessInfo.environment["AURORA_MAX_CLIPS"]` 只为判断日志里该说「环境变量 AURORA_MAX_CLIPS」还是「UI 设置/默认值」，并打印「要保留更多请设 AURORA_MAX_CLIPS=1000」。⚠️ 这是**第二处直读 environment**（第一处在 :59 的 `maxClipsPerKind` 计算属性）——两处读同一个键，`AURORA_MAX_CLIPS` 全程不走 AuroraFlags 注册表。

## 三、appendFrame / appendGlyphNative 与两个编码器（第 442–623 行）

**`appendFrame(image:steer:throttle:brake:speedKmh:headingDeg:curvature:speedLimit:)`（第 469–534 行，签名 4 个可选车辆状态参数在 `:469-471`）**——追加一帧（画面 + 控制量），主线程调用：

1. `guard isRecording, let start = startTime, let url = sessionURL else { return }`
2. `timestamp = Date().timeIntervalSince(start)`（相对录制起点的秒）
3. **背压判定（472–479 行）**：读 `pendingWrites`（锁内），`guard pending <= Self.maxPendingWrites else { return }`——**丢帧时帧号不入队不自增，保持写入帧号连续**；配合写盘闭包内 autoreleasepool 封顶内存，防 7×24 长录时编码慢于采集导致 NSImage 在队列里无限堆积
4. `idx = frameCount` → `frameCount += 1` → `pendingWrites += 1`（锁内）
5. `writeQueue.async { [weak self, image] in defer { self?._decPending() } ... }`——串行队列保证帧顺序（FIFO）：
   - **autoreleasepool（500–504 行，P1 修复）**：NSImage 被强捕获进写盘闭包，缩放/编码产生大量临时对象，闭包不自动包池，背压窗口内的多帧叠加会放大峰值内存、诱发缓冲池扩容——帧末及时释放
   - 缩放编码 JPEG → 写 `frames/%06ld.jpg`（`String(format: "%06ld.jpg", idx)`）
   - CSV 追加（`:521-526`）：`String(format: "%.4f,%ld,%.4f,%.4f,%.4f,%@,%@,%@,%@\n", timestamp, idx, steer, throttle, brake, fmtOpt(speedKmh), fmtOpt(headingDeg), fmtOpt(curvature), fmtOpt(speedLimit))` → `csvHandle?.write`；`fmtOpt` 对 nil/非有限值返回**空串**（不写 0）

**`appendGlyphNative(pixelBuffer:)`（第 541–565 行）**——字模模式专用，主线程调用：

- 参数：CaptureEngine `onNativeFrame` 投递的原生 ROI 缓冲（speedROINorm 区域，**原生分辨率未缩放——数字 ~95px**）
- **帧号/背压逻辑与 appendFrame 完全一致**（共用 pendingWrites 计数 + 丢帧阈值 maxPendingWrites=1）
- 直接编码 PNG 存盘 `frames/%06ld.png`；不写 640×360 训练帧 / CSV（字模只关心画面）

**`resizeAndEncodeJPEG(image:size:) -> Data?`（第 571–597 行）**：

1. `image.cgImage(forProposedRect: nil, context: nil, hints: nil)` 取 CGImage（:568-570）
2. 创建目标位图上下文：RGB 颜色空间、`premultipliedLast`、`data: nil`、`bytesPerRow: 0`（自动）（:573-581）
3. `context.interpolationQuality = .high`（:584）+ `context.draw(cgImage, in: CGRect(origin: .zero, size: size))`（:585）
   ⚠️ **源注释（:583）写「保持比例填充，可能裁切，与 UI 显示一致」——与实现不符**：`draw(in: CGRect(origin:.zero, size: size))` 是**纯拉伸填满**（CGRect 尺寸=目标尺寸，无 aspect-fit 计算，无裁切裁剪逻辑）。实际效果 = 各向异性缩放，源 16:9 到 640×360 恰好同比不失真，但**任意其它源宽高比会被拉变形**（实测 +15.6% 各向异性，见 `docs/整合文档/05-性能与优化全史.md` §2.5）。**源码注释本身有误**（与同文件 `:8` 头注释 5 列过期、`:39` 30fps 过期同类）
4. `context.makeImage()`（:587）→ `NSBitmapImageRep(cgImage:)`（:590）→ JPEG **质量 0.9**（:591-592，训练端 mono_dataset 读 .jpg，平衡清晰度/体积）

**`encodeNativePNG(pixelBuffer:) -> Data?`（第 606–626 行）**——原生 ROI 编码 PNG（不缩放、无损失）：

- **P1-2 修复**：字模录制改走原生路径（不再从 480px UI 缩略图裁剪 → 数字 ~95px 恢复）
- `CVPixelBufferLockBaseAddress` + defer 解锁 → 取 base/宽高
- bitmapInfo：`premultipliedFirst | byteOrder32Little` == BGRA 内存序——**与 CaptureEngine 原生 ROI 池（copyNativeFrame）的像素格式一致**
- `CGContext(data: base, ...)` **直接引用缓冲基址** → `makeImage()` → `NSBitmapImageRep.png`
- 无 CIContext、**无方向翻转**（缓冲行序 top-down 与屏幕一致，字模训练所见即所得）
- 编码失败返回 nil（不阻塞录制主流程）

**RecordEngine 文档至此完整**（627 行全覆盖：参数与格式 → 启停与清理 → 帧追加与编码）。