// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LeanRecordEngine.swift — 精简录制模式（只录画面 + 抓包数据，不跑任何模型）
//
//  【为什么要有它】App 里现有的 `RecordEngine` 专家模式在 UI 进程每帧要读
//  键盘、生成连续量标签、缩放到 640×360、还要和 OCR/字形/插帧抢主线程，
//  实际跑起来太重、会拖慢采集。用户 2026-11-03 拍板：另做一套**极薄**的录制器，
//  录制期**什么模型都不跑**，把重活全部推到录制结束后的离线标注。
//
//  ── 录制期做什么（有且只有三件）──────────────────────────────────────────
//    1. 把抓屏层送来的**全分辨率**帧编码成 JPEG 落盘
//    2. 按 15Hz 记时间戳与**按键快照**（按键就是 V3 的训练标签）
//    3. 从抓包解析里取 位置 / 朝向 / 加速度（`CoordinateCapture`，libpcap）
//
//  ── 录制期**不**做什么（全部离线）────────────────────────────────────────
//    · 速度 OCR：全屏原图里天然带着速度表，离线裁 `speedROINorm` 区域再识别。
//      ⟹ 所以**不需要**额外存「速度表长条」（用户明确否掉了这个设计）。
//    · 超采样到 384×224：离线做（录制期存原图，保留全部信息，便于换输入尺寸重训）。
//    · 坐标表 / 世界模型 / 任何感知模型。
//
//  ── 为什么帧号必须在**写盘队列**里分配（关键不变量）──────────────────────
//    `dataset_v3._build_index` 里 `n_frames = len(rows)`，读图时按
//    `frames/{j:06d}.jpg`（j = CSV 行序）找文件。也就是说
//    **CSV 第 j 行 ⟷ frames/0000jj.jpg 必须严格对应**。
//    若在主线程预先分配帧号、而某帧 JPEG 编码失败被丢弃，后面所有帧号就会
//    整体错位一格 → 整批数据的标签与画面对不上，且**不会报错**。
//    ⟹ 本文件的写法：帧号只在写盘成功后递增，失败则重试/丢帧且**不写 CSV 行**。
//
//  ── 线程模型 ─────────────────────────────────────────────────────────────
//    · `start()` / `stop()`：主线程
//    · `appendFrame(pixelBuffer:)`：**captureQueue**（CaptureEngine 帧回调）
//      ⚠️ 这里绝不做 JPEG 编码！只做「取时间戳 + 按键快照 + 入队」。
//         本仓库已有前例：在 captureQueue 上做同步重活曾把 capGap 从 11ms 抬到
//         2081ms（见 CaptureEngine 里对 onYoloFrame 的注释）。
//    · JPEG 编码 + 写盘 + CSV 追加：`writeQueue` 串行队列
// ============================================================================

import AppKit
import CoreVideo
import Foundation
import Observation

// MARK: - 会话元数据（写进 meta.json，事后可查这份数据能不能用）

/// 一次精简录制的元信息。
/// 为什么要把这些写进 meta：录制期的"静默失效"事后无法从数据本身反推
/// （例如抓包全程没锁上 → 定位列全空，但文件看起来完全正常）。
struct LeanRecordMeta {
    var fps: Double
    var width: Int
    var height: Int
    var frames: Int
    var framesFailed: Int
    var durationSeconds: Double
    var segmentIndex: Int
    /// 定位是否可用（抓包锁上网卡且解析出过坐标）
    var pcapOK: Bool
    /// 朝向语义：**相机朝向，不是车辆朝向**（用户 2026-11-03 确认的已知缺陷）
    var headingIsCamera: Bool
    var note: String

    func jsonObject(createdAt: String) -> [String: Any] {
        [
            "mode": "lean",
            "created_at": createdAt,
            "fps": fps,
            "width": width,
            "height": height,
            "total_frames": frames,
            "frame_write_failures": framesFailed,
            "frames_complete": framesFailed == 0,
            "duration_seconds": durationSeconds,
            "segment_index": segmentIndex,
            "pcap_ok": pcapOK,
            "heading_semantics": "camera",
            "heading_is_camera_not_vehicle": headingIsCamera,
            "speed_source": "offline_ocr",
            "needs_annotation": true,
            "note": note,
        ]
    }
}

// MARK: - 精简录制引擎

/// 精简录制引擎：只负责落盘，不跑任何模型。
///
/// 输出目录（与训练用的 `data/raw_clips` 隔离，避免未标注数据混进训练扫描）：
/// ```
/// data/lean_clips/clip_<yyyyMMdd_HHmmss>/
///   frames/00000.jpg …     全分辨率 JPEG（q92），文件名 = CSV 行号
///   controls.csv           19 列：时间/定位/加速度/按键（speed_kmh 留空待离线填）
///   meta.json              本会话的可信度自述
/// ```
@Observable
final class LeanRecordEngine: @unchecked Sendable {

    // MARK: 可配置项

    /// 目标帧率。默认 15：V3 的 24 帧时序窗口按 15Hz 设计（=1.6s），
    /// `dataset_v3` 对偏差 >15% 会直接 raise，不是警告。
    var fps: Double = 15

    /// JPEG 质量。q92 实测（真实游戏截图 1280 宽）156–279 KB/帧。
    var jpegQuality: CGFloat = 0.92

    /// 单段时长上限（秒）。到点自动切段，防单文件过大/一次录几十分钟难管理。
    var maxSegmentSeconds: Double = 600

    /// 剩余磁盘低于此值时停止录制（不删用户数据），返回警告。
    var minFreeDiskBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// 视角标签（写进 view.txt）。《异环》本身就是第三视角，录制恒为 TPV。
    /// 仅供 `--lean-selftest` 或将来切换视角用，正常录制不需要改。
    var viewLabel: String = "TPV"

    /// 录制根目录覆盖（仅自检用：让自检写到临时目录，不污染 data/lean_clips）。
    /// nil = 用默认的 `data/lean_clips`。
    var clipsRootOverride: URL?

    // MARK: 数据源（由接线方注入，引擎自己不抓包也不监听键盘）

    /// 取当前按键快照。UI 进程注入 → `keyboardMonitor` 的实时状态。
    var keyProvider: () -> RawKeySample = { RawKeySample() }

    /// 取当前定位与加速度。返回 nil 表示这一帧没有可用定位（抓包未锁上/未进游戏）。
    /// 朝向语义是**相机朝向**（见 `headingIsCamera`）。
    var poseProvider: () -> (pose: Pose?, accel: Vec3?) = { (nil, nil) }

    /// 每关闭一段就回调一次（含 10 分钟自动分段切出来的中间段），参数是产物目录路径。
    ///
    /// 【为什么需要它】一次长录会被切成多段，若只标注"最后一段"，前面的中间段
    ///   `speed_kmh` 会永久为空 —— 训练端 `speed_valid=0`，速度这一路特征等于没数据，
    ///   而且屏外完全看不出来（录制日志一切正常）。
    /// 【为什么由被叫方决定何时标注】本类只在段收尾那一刻报告"这段完事了"，
    ///   不做任何耗 CPU 的活：录制期间跑 OCR 会与抓屏抢 CPU，帧率被挤出
    ///   `dataset_v3` 的 15±15% 容差会让整段数据作废。
    var onSegmentClosed: ((String) -> Void)?

    // MARK: 可观察状态

    private(set) var isRecording = false
    /// 本次会话已成功落盘的帧数（= 当前 CSV 行数）
    private(set) var frameCount = 0
    /// 本次会话编码/写盘失败次数（>0 说明 frames/ 有过洞，但已被我们"不写行"守住配对）
    ///
    /// 【为什么 @ObservationIgnored】这两个值由 **writeQueue / captureQueue** 在锁内写，
    ///   而 @Observable 的存储走 observation 注册表、不是单纯写一个字段：在非主线程
    ///   写它会跨线程改注册表状态（本类 :375 附近的注释已就这一点警告过 frameCount）。
    ///   界面从不直接观察它们（失败数走 `framesFailedSafe` 锁内读），故排除观察。
    @ObservationIgnored private(set) var writeFailureCount = 0
    /// 本会话是否存在过可用定位（任意一帧解析出坐标即 true）；同上，只在锁内读写
    @ObservationIgnored private(set) var sawPose = false
    /// 当前段序号（0 起）
    private(set) var segmentIndex = 0

    // MARK: 私有状态

    private let writeQueue = DispatchQueue(label: "com.aurora.leanrecord.write")
    private let stateLock = NSLock()

    private var sessionDir: URL?
    /// 最近一段的产物目录（stop() 清空 sessionDir 后仍保留，供 UI 显示/离线标注用）
    private var lastClipDir: URL?
    private var framesDir: URL?
    private var csvHandle: FileHandle?
    private var sessionStart: Date?
    /// 下一帧要用的帧号（**只在 writeQueue 内读写**，保证与 CSV 行号一致）
    private var nextFrameIndex = 0
    /// 会话世代号：每开一段新会话 +1（stateLock 保护）。
    ///
    /// 【为什么需要它】10 分钟自动分段是主线程 `stop()`→`start()`；抓屏队列上可能
    ///   还有一帧已通过"在录"判断、正排队等着 `writeQueue.async` 写盘。它若落在
    ///   `start()` 之后执行，就会用**新段**的 framesDir 和 nextFrameIndex=0 落盘，
    ///   覆盖新段 000000.jpg：旧段少一帧、新段多一张旧画面，而帧号仍连续
    ///   ⇒ `dataset_v3` 的 frame==i 校验照常通过，是**静默**的标签错配。
    ///   写盘前比对世代号，不等就整帧丢弃（宁可少一帧，不可错一帧）。
    private var sessionGeneration = 0
    /// 已成功落盘的帧数（**权威计数**，stateLock 保护）。
    /// 为什么不能直接用 @Observable 的 `frameCount`：它只能在主线程写，
    /// 而 stop() 排空队列那一刻主线程的更新可能还没跑到 → 日志/meta 会少报帧数。
    private var framesWrittenLocked = 0
    private var restartedPending = false
    /// 上一帧被接受的时刻（用于 15fps 限流；stateLock 保护）。
    /// `start()`/`closeSessionLocked()` 会置 nil，否则新会话第一帧会被上段的旧时刻误挡。
    private var lastAcceptedFrameTime: Date?

    private let dirFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 录制根目录：data/lean_clips/
    /// 刻意与 `data/raw_clips`（V2/V3 训练扫描目录）分开：
    /// 未标注的速度列会让训练端把 speed 当"缺失"，混在一起容易被误当成品数据集。
    private var clipsRoot: URL {
        if let override = clipsRootOverride { return override }
        return AuroraPaths.projectRoot()
            .appendingPathComponent("data")
            .appendingPathComponent("lean_clips")
    }

    // MARK: - 启停（主线程）

    /// 开始录制。返回 false 表示没能开始（磁盘不足/目录创建失败），原因见 `lastError`。
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }

        if let free = Self.freeDiskBytes(), free < minFreeDiskBytes {
            lastError = "磁盘剩余 \(free / 1024 / 1024 / 1024) GB，低于下限"
                + " \(minFreeDiskBytes / 1024 / 1024 / 1024) GB，已拒绝开始录制"
            print("[lean] ❌ \(lastError ?? "")")
            return false
        }

        guard let dir = makeSessionDir() else {
            lastError = "无法创建录制目录 \(clipsRoot.path)"
            print("[lean] ❌ \(lastError ?? "")")
            return false
        }
        guard openSession(at: dir) else {
            lastError = "无法创建 controls.csv / frames/"
            print("[lean] ❌ \(lastError ?? "")")
            return false
        }

        stateLock.lock()
        isRecording = true
        stateLock.unlock()
        print("[lean] ▶ 开始精简录制 → \(dir.lastPathComponent)（\(fps) fps，段 \(segmentIndex)）")
        return true
    }

    /// 停止录制。会同步等待写盘队列排空，保证最后几帧与 meta.json 都落盘。
    func stop() {
        guard isRecording else { return }

        stateLock.lock()
        isRecording = false
        stateLock.unlock()

        // 同步排空：writeQueue 是串行队列，sync 会排在所有已入队帧之后执行，
        // 从而保证「关闭 CSV 句柄」一定发生在最后一帧写完之后（否则尾部丢行）。
        writeQueue.sync {
            self.closeSessionLocked()
        }

        stateLock.lock()
        let written = framesWrittenLocked
        let failed = writeFailureCount
        let gotPose = sawPose
        stateLock.unlock()

        print("[lean] ⏹ 停止精简录制：成功 \(written) 帧，失败 \(failed) 帧")
        if failed > 0 {
            print("[lean] ⚠️ 有 \(failed) 帧没能落盘（已跳过对应 CSV 行以保持帧号配对）")
        }
        if !gotPose {
            print("[lean] ⚠️ 本段全程没有可用定位（抓包未锁上？游戏未开始？）"
                  + " → CSV 的 x/y/z/pitch/heading/accel 列为空，meta.json 已标记 pcap_ok=false")
        }
        // 报告"这一段收尾了"。放在所有收尾动作之后：此时 CSV 句柄已关、
        // meta.json 已写，回调方拿到的是一份可直接标注的完整产物。
        // 自动分段时本方法由轮转逻辑调用，随后立刻 start() 开新段 ——
        // 所以回调**只能登记路径，不能在这里做标注**（会与新段抓屏抢 CPU）。
        if let closedPath = lastClipPath {
            onSegmentClosed?(closedPath)
        }
    }

    // MARK: - 帧追加（**captureQueue** 调用）

    /// 追加一帧。**只做取快照 + 入队，绝不编码**（理由见文件头线程模型）。
    /// - Parameter pixelBuffer: 全分辨率帧的**自持副本**（CaptureEngine.copyRecordFrame
    ///   已经做过 memcpy，本类可以直接持有到写盘结束，不存在 use-after-release）。
    func appendFrame(pixelBuffer: CVPixelBuffer) {
        guard isRecordingSnapshot else { return }

        // ── 15fps 限流（**必须在取时间戳之前**）────────────────────────────
        // UI 进程的抓屏基准是 15fps（`CaptureEngine._targetCaptureHz` 初值 15，
        // 且 AuroraDriveApp 只调 `start()`、从不调 `setCaptureHz` —— 20/45fps 是
        // **引擎进程**按档位下发的值，与本录制器所处的 UI 进程无关）。
        // 所以这里不是"把 20 压到 15"，而是**防御 SCStream 的额外推送**：
        // 画面内容剧烈变化时系统会多发帧，若照单全收，t_sec 会被拉密，
        // 而 dataset_v3 用 `actual_fps = 1/median(dts)` 校验 15±15%（12.75–17.25），
        // 超了直接 ValueError，整份数据一帧都加载不了。
        //
        // 判据用 0.9 个周期（6.0ms 余量）而不是严格的 1/15：
        //   15fps 源的真实间隔会在 66.7ms 附近抖动，卡死 66.7ms 会把正常帧也挡掉，
        //   反而把有效帧率压低、同样掉出容差下界。
        let now = Date()
        let minGap = 1.0 / fps * 0.9
        // 【为什么"在录判断"和"世代号"必须在同一次加锁里取】
        //   10 分钟自动分段是主线程 stop()→start()；而本函数在抓屏队列。若两者
        //   分开取，中间恰好切段，就会把**旧段的在途帧**带进新段：它随后按新段的
        //   framesDir + nextFrameIndex=0 落盘，覆盖新段 000000.jpg。旧段少一帧、
        //   新段多一张旧画面，而帧号仍连续 ⇒ dataset_v3 不会报错，属静默错配。
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return
        }
        let generation = sessionGeneration
        if let last = lastAcceptedFrameTime, now.timeIntervalSince(last) < minGap {
            stateLock.unlock()
            return
        }
        lastAcceptedFrameTime = now
        stateLock.unlock()

        // 时间戳与标签必须在**帧到达的这一刻**取，不能等到写盘时再取：
        // 写盘是异步的，晚取会把"下一帧的按键"贴到"这一帧的画面"上（标签错位）。
        let keys = keyProvider()
        let (pose, accel) = poseProvider()

        stateLock.lock()
        let elapsed = now.timeIntervalSince(sessionStart ?? now)
        if pose != nil { sawPose = true }
        let needRestart = elapsed >= maxSegmentSeconds && !restartedPending
        if needRestart { restartedPending = true }
        stateLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.writeFrame(pixelBuffer: pixelBuffer, at: now, keys: keys,
                                pose: pose, accel: accel, generation: generation)
            }
        }

        if needRestart {
            // 切段在主线程做（改 sessionDir 等都是主线程状态）。
            // 先 stop 再 start：stop 内部会 writeQueue.sync 排空，保证前一段完整。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecordingSnapshot else { return }
                self.stop()
                self.stateLock.lock()
                self.segmentIndex += 1
                self.restartedPending = false
                self.stateLock.unlock()
                // 返回值不可丢弃：磁盘掉到下限（正是长时间连续录制最可能发生的情况）
                // 时 start() 会返回 false，而此刻段号已 +1、restartedPending 已复位。
                // 若静默吞掉，用户只看到"录制停止"却不知原因；lastError 由
                // syncLeanMirror 镜像到界面。
                if !self.start() {
                    print("[lean] ❌ 自动分段失败，录制已停止：\(self.lastError ?? "未知原因")")
                }
            }
        }
    }

    // MARK: - 写盘（writeQueue 内执行）

    private func writeFrame(pixelBuffer: CVPixelBuffer, at date: Date,
                            keys: RawKeySample, pose: Pose?, accel: Vec3?,
                            generation: Int) {
        // 世代校验必须在取 framesDir / nextFrameIndex **之前**：
        //   本帧是在旧会话里取的快照，若期间已切段（自动分段 stop→start），
        //   用新段的目录和帧号落盘 = 静默错配（详见 sessionGeneration 注释）。
        //   这里在 writeQueue 内读，与 openSession 的写互斥于 stateLock。
        //
        // ⚠️ 这里**刻意不检查 isRecording**：stop() 是先置 isRecording=false、
        //   再 writeQueue.sync 排空。若在这里要求 isRecording 为真，排空时
        //   队列里的尾部帧会被全部丢弃 —— 恰恰丢掉每段最后几帧。世代号已经
        //   足够区分"这是旧段的帧"，不需要第二个判据。
        stateLock.lock()
        guard generation == sessionGeneration else {
            stateLock.unlock()
            return
        }
        let framesDir = self.framesDir
        stateLock.unlock()
        guard let framesDir else { return }

        // ── 1. 编码 ──
        guard let data = Self.encodeJPEG(pixelBuffer, quality: jpegQuality) else {
            recordFailure("JPEG 编码失败")
            return
        }

        // ── 2. 帧号在**写盘成功前后**分配：失败就重试，绝不产生"有行无图" ──
        let idx = nextFrameIndex
        let url = framesDir.appendingPathComponent(String(format: "%06d.jpg", idx))
        // ⚠️ 这里刻意**没有**「文件已存在就换下一个帧号」的重试分支，原因有二：
        //   ① `Data.write(to:options:.atomic)` 本身就会覆盖已存在文件 → 该分支永远
        //      进不去，是死代码；
        //   ② 若它真被执行，`idx += 1` 会在 frames/ 留下空洞，而下面 CSV 行写的是
        //      `idx` → 直接破坏「CSV 第 j 行 ⟷ 0000jj.jpg」这条硬约束，
        //      整份数据的标签会与画面对不上，且**不会报错**。
        //   正确做法：帧号只随「已成功落盘的帧数」前进；写失败就整帧丢弃、不写行。
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            recordFailure("帧写入失败：\(url.lastPathComponent)")
            return
        }

        // ── 3. 图片已落盘，才写 CSV 行（保证 CSV 第 j 行 ⟷ 0000jj.jpg）──
        let t = date.timeIntervalSince(sessionStart ?? date)
        guard appendCSVRow(index: idx, tSec: t, keys: keys, pose: pose, accel: accel) else {
            // CSV 行没写进去 ⇒ 这张图**必须删**，否则就是「有图无行」：
            //   frames/ 多一张、CSV 少一行，后续行号继续前进，
            //   训练端按行号拼文件名会整体错位 → 整段一帧都加载不了。
            // 帧号**不推进**，下一帧复用同一个 idx（Data.write .atomic 直接覆盖），
            // 所以即便删除失败也不会在 frames/ 留下永久空洞。
            try? FileManager.default.removeItem(at: url)
            // 不重复 recordFailure：该次失败已在 appendCSVRow 内计过，再计会把
            // "一帧写失败"报成两次，与自检「失败计数记为 1」的断言冲突。
            print("[lean] ⚠️ CSV 行写入失败，已回滚帧 \(url.lastPathComponent)（帧号未推进）")
            return
        }

        nextFrameIndex = idx + 1
        let total = idx + 1
        // 宽高必须在这里从真实缓冲取值写进 meta：
        // 否则 meta.json 会永远写着 0×0 —— 这是一条**错误信息**，事后分析会误判分辨率。
        let fw = CVPixelBufferGetWidth(pixelBuffer)
        let fh = CVPixelBufferGetHeight(pixelBuffer)
        stateLock.lock()
        framesWrittenLocked = total
        lastFrameWidth = fw
        lastFrameHeight = fh
        stateLock.unlock()
        // @Observable 的存储不是线程安全的，只能在主线程写；
        // 权威计数用 `framesWrittenLocked`（stateLock 保护），日志与 meta 都读它，
        // 因为 stop() 排空队列那一刻主线程的 frameCount 可能还没被更新。
        DispatchQueue.main.async { [weak self] in
            self?.frameCount = total
        }
    }

    /// 写一行 CSV。**返回是否真的写进去了** —— 调用方靠它决定要不要回滚该帧。
    ///
    /// 【为什么必须返回 Bool】此前失败时只记录计数就 return，但 `writeFrame` 接着
    ///   把 `nextFrameIndex` 推进了：frames/ 留下一张图，CSV 却没有对应行，后续
    ///   行号继续前进 ⇒ 训练端「按行号拼文件名」会整体错位，`dataset_v3` 的
    ///   `frame == i` 校验直接抛 ValueError，**整段一帧都加载不了**。
    @discardableResult
    private func appendCSVRow(index: Int, tSec: Double, keys: RawKeySample,
                              pose: Pose?, accel: Vec3?) -> Bool {
        // 缺值一律写空串，不写 0：
        //   `dataset_v3` 对空串判 speed_valid=0；写 0 会被当成"真实值为 0"。
        //   定位同理 —— 写 0 会让人以为车正好在世界原点。
        let x = pose.map { String(format: "%.3f", $0.0) } ?? ""
        let y = pose.map { String(format: "%.3f", $0.1) } ?? ""
        let z = pose.map { String(format: "%.3f", $0.2) } ?? ""
        let pitch = pose.map { String(format: "%.3f", $0.3) } ?? ""
        let heading = pose.map { String(format: "%.3f", $0.4) } ?? ""
        let ax = accel.map { String(format: "%.3f", $0.0) } ?? ""
        let ay = accel.map { String(format: "%.3f", $0.1) } ?? ""
        let az = accel.map { String(format: "%.3f", $0.2) } ?? ""

        // 用拼接而不是 `String(format: "%.5f,%d,%@,…")`：
        // `%@` 依赖 String→NSString 的 CVarArg 桥接，一旦某个值是空串或含非 ASCII
        // 就可能产出不可预期的结果；拼接是确定性的，且列数一眼可数。
        // 列序必须与 openSession 写的表头**逐字一致**（19 列）。
        let line = String(format: "%.5f", tSec) + "," + String(index) + ","
            + x + "," + y + "," + z + "," + pitch + "," + heading + ","
            + ax + "," + ay + "," + az + ","
            + ""                                    // speed_kmh：待离线 OCR 回填
            + "," + String(keys.w) + "," + String(keys.a) + ","
            + String(keys.s) + "," + String(keys.d) + ","
            + String(keys.shift) + "," + String(keys.space) + ","
            + String(keys.superBrake) + "," + String(keys.ultimateBrake) + "\n"

        guard let data = line.data(using: .utf8) else {
            recordFailure("CSV 行编码失败")
            return false
        }
        // 【为什么用 try write(contentsOf:) 而不是 write(_:)】
        //   `FileHandle.write(_:)` 是非 throwing 的旧 API，出错时**raise ObjC 异常**
        //   （磁盘满 / IO 错误），Swift 的 do/catch 抓不到 → 直接崩掉整个 App。
        //   录制中崩溃还会留下未 flush 的 CSV，比"少一帧"严重得多。
        do {
            try csvHandle?.write(contentsOf: data)
            return true
        } catch {
            recordFailure("CSV 行写入失败：\(error.localizedDescription)")
            return false
        }
    }

    private func recordFailure(_ reason: String) {
        stateLock.lock()
        writeFailureCount += 1
        let n = writeFailureCount
        stateLock.unlock()
        if n <= 3 { print("[lean] ⚠️ \(reason)（第 \(n) 次）") }
    }

    // MARK: - 会话目录 / CSV

    private func makeSessionDir() -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: clipsRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // 目录名沿用仓库既有约定 clip_<yyyyMMdd_HHmmss>（训练端只扫 clip_ 前缀、
        // 保留清理按名字典序 ≈ 时间序）。
        //
        // ⚠️ 但**绝不接受重名复用**：名字只精确到秒，而自动切段就是 stop() 紧接
        // start()（同一秒内必然撞名）；`createDirectory(withIntermediateDirectories:)`
        // 对已存在目录**不报错**，紧接着 openSession 里的 createFile 会**截断**上一段
        // controls.csv，帧又从 000000 覆盖 ⇒ 整段数据静默丢失且无任何报错。
        // 出现重名时加数字后缀，保证每段独占一个目录。
        let base = "clip_\(dirFormatter.string(from: Date()))"
        var dir = clipsRoot.appendingPathComponent(base)
        var suffix = 1
        while fm.fileExists(atPath: dir.path) {
            suffix += 1
            guard suffix <= 999 else { return nil }
            dir = clipsRoot.appendingPathComponent("\(base)_\(suffix)")
        }
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("frames"),
                                   withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    private func openSession(at dir: URL) -> Bool {
        let fm = FileManager.default
        // view.txt：与仓库里其它 clip 保持一致（内容 "TPV"）。
        // `dataset_v3` 只在显式传 view_filter 时才读它；train_v3.py:263 目前不传，
        // 所以缺它不会静默丢段 —— 但保持文件集一致，避免将来开 view_filter 时
        // 整批 clip 被静默跳过（那种跳过**不报错**，只是样本变少）。
        let viewURL = dir.appendingPathComponent("view.txt")
        if !fm.fileExists(atPath: viewURL.path) {
            try? viewLabel.data(using: .utf8)?.write(to: viewURL, options: .atomic)
        }
        let csvURL = dir.appendingPathComponent("controls.csv")
        // 19 列。前 10 列为定位/加速度（空=本帧无定位），第 11 列 speed_kmh
        // **故意留空**（离线 OCR 后回填），后 8 列是 V3 的原生按键标签。
        let header = "t_sec,frame,x,y,z,pitch,heading,ax,ay,az,speed_kmh,"
            + "w,a,s,d,shift,space,super_brake,ultimate_brake\n"
        guard fm.createFile(atPath: csvURL.path, contents: header.data(using: .utf8)) else {
            return false
        }
        guard let handle = FileHandle(forWritingAtPath: csvURL.path) else { return false }
        handle.seekToEndOfFile()

        stateLock.lock()
        sessionDir = dir
        lastClipDir = dir
        framesDir = dir.appendingPathComponent("frames")
        csvHandle = handle
        sessionStart = Date()
        // 新段 = 新世代：在途的旧帧写盘时会因世代不符被丢弃，绝不污染本段。
        sessionGeneration &+= 1
        frameCount = 0
        writeFailureCount = 0
        sawPose = false
        nextFrameIndex = 0
        // ⚠️ 必须一起清零：这是**权威计数**，漏清会让第二段的日志/meta 继承上一段的帧数。
        framesWrittenLocked = 0
        lastFrameWidth = 0
        lastFrameHeight = 0
        restartedPending = false
        // ⚠️ 必须清零：限流用"距上一帧的时刻"判间隔，不清的话 10 分钟自动分段
        //    切到新会话后，第一帧会被上一段的旧时刻挡掉（每段开头稳定丢 1 帧）。
        lastAcceptedFrameTime = nil
        lastError = nil
        stateLock.unlock()
        return true
    }

    /// 关闭句柄并写 meta.json。**只在 writeQueue.sync 里调用**（见 stop()）。
    private func closeSessionLocked() {
        guard let dir = sessionDir else { return }
        csvHandle?.synchronizeFile()
        csvHandle?.closeFile()
        csvHandle = nil

        // 读计数必须在锁内：这些值由 writeQueue 写、主线程读，直接读是数据竞争；
        // 且必须读 `framesWrittenLocked`（权威值），不能用 @Observable 的 frameCount
        // —— 后者靠 main.async 更新，此刻可能还没跑到，会把帧数报少。
        stateLock.lock()
        let totalFrames = framesWrittenLocked
        let failures = writeFailureCount
        let gotPose = sawPose
        let fw = lastFrameWidth
        let fh = lastFrameHeight
        let segIdx = segmentIndex
        let startedAt = sessionStart ?? Date()
        stateLock.unlock()

        let meta = LeanRecordMeta(
            fps: fps,
            width: fw,
            height: fh,
            frames: totalFrames,
            framesFailed: failures,
            durationSeconds: Date().timeIntervalSince(startedAt),
            segmentIndex: segIdx,
            pcapOK: gotPose,
            headingIsCamera: true,
            note: gotPose
                ? "定位来自 libpcap 解析；heading 是**相机朝向**（非车辆朝向，已知缺陷）。"
                    + "速度列为空，需跑离线标注回填。"
                : "本段全程无定位（抓包未锁上/未进游戏），定位与加速度列全空。"
                    + "画面与按键仍然可用。")

        if let data = try? JSONSerialization.data(
            withJSONObject: meta.jsonObject(createdAt: isoFormatter.string(from: Date())),
            options: [.prettyPrinted]) {
            // .atomic 不可省：崩溃/断电时留下半个 JSON，解析直接失败，而该段此时
            // 已经通过 onSegmentClosed 交给标注器了 —— 事后查不到分辨率/帧数/
            // pcap_ok，等于失去"这份数据能不能用"的唯一自述。
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        // 三行置空必须放进 stateLock：`appendFrame`（抓屏队列）在**锁内**读
        //   `sessionStart` 算 elapsed 来判自动分段。在锁外置 nil 就是跨线程无同步
        //   读写 Optional<Date>，撕读可能拿到垃圾值 → needRestart 误判：多切一段
        //   （凭空多出半截 clip）或漏切（单段超 10 分钟）。窗口窄但后果是数据错。
        stateLock.lock()
        sessionDir = nil
        framesDir = nil
        sessionStart = nil
        stateLock.unlock()
    }

    // MARK: - 辅助

    private var isRecordingSnapshot: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRecording
    }

    /// 供抓屏队列每帧求值的门禁（`CaptureEngine.isRecordFrameWanted`）。
    ///
    /// 为什么不直接读 `isRecording`：它是 `@Observable` 的存储属性，由主线程
    /// `start()/stop()` 写、由**抓屏队列**每帧读 —— 跨线程裸读是数据竞争
    /// （@Observable 的访问要走 observation 注册表，不是单纯读一个 Bool）。
    /// 本属性内部走 `stateLock`，可安全跨线程调用。
    var wantsFrames: Bool { isRecordingSnapshot }

    /// 最近一段的产物目录路径（stop() 之后仍可读，供离线标注/UI 显示）。
    var lastClipPath: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastClipDir?.path
    }

    /// 失败帧数（`writeFailureCount` 由 writeQueue 写，主线程裸读是数据竞争）。
    var framesFailedSafe: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return writeFailureCount
    }

    /// 已**成功落盘**的帧数（stateLock 保护，可跨线程读）。
    ///
    /// 【为什么要单独开这个口】引擎交接要用它判定「本地真的接到画面了」。
    ///   不能用 `frameCount`：那是 @Observable 属性、只能主线程写，且靠
    ///   `main.async` 更新，比真实落盘晚一个主线程回合。用它当判据会在
    ///   「看起来有帧、实际还没写进盘」时就把引擎踢掉 —— 正好是双输窗口。
    var framesWrittenSafe: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framesWrittenLocked
    }

    /// 最近一帧的宽高（写 meta 用；在 writeQueue 里更新）
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0

    /// 最近一次失败原因（供 UI 展示）
    private(set) var lastError: String?

    /// 剩余磁盘容量（字节）。取不到返回 nil（视为未知，不阻塞录制）。
    static func freeDiskBytes() -> Int64? {
        let url = AuroraPaths.projectRoot()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(free)
    }

    /// CVPixelBuffer(32BGRA) → JPEG。写法与 `RecordEngine` 的 PNG/JPEG 编码一致。
    static func encodeJPEG(_ pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        guard let cg = cgImage(from: pixelBuffer) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg,
                                  properties: [NSBitmapImageRep.PropertyKey.compressionFactor: quality])
    }

    /// CVPixelBuffer(32BGRA) → CGImage。
    /// 32BGRA 对应 premultipliedFirst + byteOrder32Little（与 CaptureEngine 的
    /// UI 渲染色序一致）；不翻转方向 —— 抓屏缓冲行序本就是 top-down。
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        return ctx.makeImage()
    }
}
