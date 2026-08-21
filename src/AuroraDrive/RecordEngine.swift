// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RecordEngine.swift — 行驶录制引擎
//  兼容现有 recordings/{perspective}_{timestamp}/ 格式：
//    frames/00000.jpg   (640x360 JPEG)
//    controls.csv       (timestamp,frame,steer,throttle,brake)
//    meta.json          (录制元信息)
//  设计要点：
//    1) 异步写盘 —— 主线程只入队，后台串行队列做缩放+写文件
//    2) 帧顺序保证 —— 单后台串行队列，FIFO
//    3) 内存安全 —— 一帧写完即释放，不缓存多帧
//    4) 停止时写 meta.json 并 flush，保证数据完整
// ============================================================================
import AppKit
import Foundation
import CoreFoundation  // CFAbsoluteTimeGetCurrent：零分配时间戳（录制 CSV 写盘用）
import Observation
import CoreVideo

/// 行驶录制引擎
/// - @Observable：让 UI 观察录制状态与已录帧数
/// - 主线程：appendFrame / start / stop
/// - 后台队列：实际 PNG 编码 + CSV 追加
@Observable
final class RecordEngine {

    // MARK: - 录制参数

    /// 输出帧尺寸（16:9 横屏，与 m9_mono 输入 180×320 同比例；训练端 MonoClipsDataset 等比缩放）
    let targetSize = CGSize(width: 640, height: 360)

    /// 录制帧率上限（Hz），与推理同频
    /// 实际帧率以 appendFrame 调用频率为准，此值仅用于 meta 记录
    let targetFps: Double = 24

    /// 每类 clip 目录保留上限：只保留最近 N 个 clip（目录名 clip_<ts> 字典序≈时间序）。
    /// 录制启动时删除最旧目录，防 640×360 JPEG 30fps（像素量约 4.6×224²，估算日积约 230GB/天）无上限累积撑爆磁盘；
    /// 有 maxClipsPerKind=10 自动清理兜底（仅保留最近 10 个 clip）。
    /// 可调常量：调大保留更多历史数据，调小更省磁盘（raw_clips 与 glyph_clips 共用此上限）。
    let maxClipsPerKind = 10

    // MARK: - 字模模式

    /// 字模模式：开启后录制「原生分辨率速度表区域 PNG」供字模训练，
    /// 不写训练录制帧（640×360 JPEG）与控制量（字模只关心画面）。默认关，不影响训练录制。
    /// 时序约定：值仅在 start() 时被读取一次用于决定会话输出形态，
    /// 录制中途切换不生效（需停止后重新开始录制才应用新值）。
    var glyphMode = false

    /// 字模模式输出根目录：data/glyph_clips/（与训练 raw_clips 隔离，互不干扰）
    private var glyphRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("data")
            .appendingPathComponent("glyph_clips")
    }

    // MARK: - 状态

    /// 是否正在录制
    private(set) var isRecording = false

    /// 已录制帧数（UI 实时展示）
    private(set) var frameCount: Int = 0

    /// 本次录制会话目录 URL
    private(set) var sessionURL: URL?

    /// 录制开始时间（用于时间戳）
    private var startTime: Date?

    // MARK: - 内部资源

    /// 后台串行写盘队列（保证帧顺序）
    private let writeQueue = DispatchQueue(label: "com.aurora.record.write")

    /// 写盘背压阈值：待处理帧数超过此值即丢帧（帧号不入队不自增，保持写入帧号连续）。
    /// appendFrame 与 appendGlyphNative 共用同一阈值，保证两路录制背压行为一致。
    private static let maxPendingWrites = 1

    /// 写盘队列待处理帧数（背压计数）：主线程入队前自增，后台写完自减
    /// NSLock 保护跨线程读写（appendFrame 主线程 / writeQueue 后台线程）
    private let pendingLock = NSLock()
    private var pendingWrites: Int = 0

    /// CSV 文件句柄（追加写）
    /// 线程约定：主线程在 start() 中创建并赋值，stop() 中经 writeQueue.sync 关闭置 nil；
    /// 实际 write 只在 writeQueue 串行队列内执行。依靠「主线程建 → writeQueue 串行写」的
    /// 提交顺序 happens-before 保序，不额外加锁（避免每帧写盘引入锁开销）。
    private var csvHandle: FileHandle?

    /// 用于生成唯一目录名的时间戳格式器
    private let dirFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 用于 meta.json 的时间戳格式器（ISO8601）
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// recordings 根目录定位
    /// 用 #filePath 定位本文件所在目录（项目根），recordings 为同级子目录
    /// 计算属性：@Observable 宏不追踪（无需追踪，路径不变），避免 lazy 冲突
    /// 录制输出根目录：data/raw_clips/（训练端 mono_dataset 默认扫描路径）
    /// 用 #filePath 定位本文件所在目录（项目根），data/raw_clips 为同级子目录
    private var recordingsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("data")
            .appendingPathComponent("raw_clips")
    }

    // MARK: - 录制控制

    /// 开始录制
    /// - Parameter perspective: 视角标签（如 "third"），用于目录命名
    func start(perspective: String = "first") {
        guard !isRecording else { return }

        // ── 磁盘上限清理：录制启动时删最旧 clip，防 7×24 无上限累积撑爆磁盘 ──
        // 只在启动时清理，不在录制中动当前 clip；raw_clips 与 glyph_clips 都纳入。
        pruneOldClips(in: recordingsRoot)
        pruneOldClips(in: glyphRoot)

        // ── 0. 字模模式：独立会话目录 data/glyph_clips/clip_<ts>/frames/ ──
        // 不写 view.txt / controls.csv（字模只关心原生画面帧），与训练录制完全隔离
        if glyphMode {
            try? FileManager.default.createDirectory(at: glyphRoot,
                                                     withIntermediateDirectories: true)
            let dirName = "clip_\(dirFormatter.string(from: Date()))"
            let sessionDir = glyphRoot.appendingPathComponent(dirName)
            let framesDir = sessionDir.appendingPathComponent("frames")
            try? FileManager.default.createDirectory(at: framesDir,
                                                     withIntermediateDirectories: true)
            sessionURL = sessionDir
            startTime = Date()
            frameCount = 0
            isRecording = true
            return
        }

        // ── 1. 创建会话目录 ──
        // 路径：{data/raw_clips}/clip_{yyyyMMdd_HHmmss}/（训练端只扫 clip_ 前缀）
        try? FileManager.default.createDirectory(at: recordingsRoot,
                                                 withIntermediateDirectories: true)
        let dirName = "clip_\(dirFormatter.string(from: Date()))"
        let sessionDir = recordingsRoot.appendingPathComponent(dirName)
        let framesDir = sessionDir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: framesDir,
                                                 withIntermediateDirectories: true)

        // 写视角标签，供训练端 _clip_view 过滤（first→FPV, third→TPV）
        let viewLabel = (perspective == "first") ? "FPV" : "TPV"
        try? viewLabel.write(to: sessionDir.appendingPathComponent("view.txt"),
                             atomically: true, encoding: .utf8)

        // ── 2. 初始化 CSV（写表头）──
        let csvURL = sessionDir.appendingPathComponent("controls.csv")
        let header = "t_sec,frame,steer,throttle,brake\n"
        FileManager.default.createFile(atPath: csvURL.path,
                                       contents: header.data(using: .utf8))
        csvHandle = FileHandle(forWritingAtPath: csvURL.path)
        csvHandle?.seekToEndOfFile()

        // ── 3. 重置状态 ──
        sessionURL = sessionDir
        startTime = Date()
        frameCount = 0
        isRecording = true
    }

    /// 停止录制并写 meta.json
    func stop() {
        guard isRecording else { return }
        isRecording = false

        // P1 修复（漏关句柄 + 无 fsync）：先把 CSV 句柄同步 flush+关闭，再判 guard。
        // 旧代码 guard 提前 return 会漏关 csvHandle（fd 泄漏）；synchronizeFile() 强制
        // fsync 保证已写行落盘。writeQueue.sync 排在已入队 appendFrame 写块之后执行。
        if csvHandle != nil {
            writeQueue.sync {
                self.csvHandle?.synchronizeFile()
                self.csvHandle?.closeFile()
                self.csvHandle = nil
            }
        }

        // 捕获本次会话信息，后台写 meta.json
        guard let url = sessionURL,
              let start = startTime else { return }
        let totalFrames = frameCount
        let duration = Date().timeIntervalSince(start)

        if glyphMode {
            // 字模模式：无 CSV，写简单 meta（记录帧数/时长供训练工具参考）
            writeQueue.async { [isoFormatter] in
                let meta: [String: Any] = [
                    "glyph_mode": true,
                    "total_frames": totalFrames,
                    "created_at": isoFormatter.string(from: start),
                    "duration_seconds": duration,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                          options: [.prettyPrinted]) {
                    try? data.write(to: url.appendingPathComponent("meta.json"))
                }
            }
            return
        }

        let size = targetSize
        let fps = targetFps
        let perspective = url.lastPathComponent
            .components(separatedBy: "_").first ?? "unknown"

        writeQueue.async { [isoFormatter] in
            // 写 meta.json（与现有格式完全一致）
            let meta: [String: Any] = [
                "capture_interval_ms": Int(1000.0 / fps),
                "target_h": Int(size.height),
                "target_w": Int(size.width),
                "total_frames": totalFrames,
                "created_at": isoFormatter.string(from: start),
                "duration_seconds": duration,
                "perspective": perspective
            ]
            if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                     options: [.prettyPrinted]) {
                try? data.write(to: url.appendingPathComponent("meta.json"))
            }
        }
    }

    // MARK: - 磁盘清理

    /// 清理某录制根目录下最旧的 clip_<ts> 目录，仅保留最近 maxClipsPerKind 个。
    /// - 只在录制启动时调用（start() 里），绝不在录制中动当前 clip；
    /// - 目录名 clip_yyyyMMdd_HHmmss 同格式，字典序即时间序（升序 = 最旧在前）。
    private func pruneOldClips(in root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let clipDirs = entries
            .filter { $0.lastPathComponent.hasPrefix("clip_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // 最旧在前
        guard clipDirs.count > maxClipsPerKind else { return }
        for dir in clipDirs.prefix(clipDirs.count - maxClipsPerKind) {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - 帧追加（主线程调用）

    /// 追加一帧（画面 + 控制量）
    /// - Parameters:
    ///   - image: 截屏画面（任意尺寸，内部缩放到 640x360）
    ///   - steer: 转向 [-1, 1]，左负右正
    ///   - throttle: 油门 [0, 1]
    ///   - brake: 刹车 [0, 1]
    /// 在主线程调用，实际写盘异步进行
    func appendFrame(image: NSImage, steer: Double, throttle: Double, brake: Double) {
        guard isRecording, let start = startTime, let url = sessionURL else { return }

        // 用 CFAbsoluteTime 替代 Date：timeIntervalSince(start) 只需 Double 差值，
        // 无需分配 Date 对象；精度到微秒级，对训练数据完全够用。
        let timestamp = CFAbsoluteTimeGetCurrent() - (start.timeIntervalSinceReferenceDate)

        // ── 背压：写盘队列待处理帧数超过 maxPendingWrites 时丢帧
        // （帧号不入队不自增，保持写入帧号连续）──
        // 配合写盘闭包内 autoreleasepool 封顶内存：防 7×24 长录时编码慢于采集
        // 导致 NSImage 在队列里无限堆积、内存缓涨。
        pendingLock.lock()
        let pending = pendingWrites
        pendingLock.unlock()
        guard pending <= Self.maxPendingWrites else { return }

        let idx = frameCount
        frameCount += 1
        pendingLock.lock()
        pendingWrites += 1
        pendingLock.unlock()

        let size = targetSize

            // 异步写盘：缩放 + JPEG 编码 + CSV 追加
            // 串行队列保证帧顺序（FIFO）
            writeQueue.async { [weak self, image] in
                defer {
                    self?.pendingLock.lock()
                    self?.pendingWrites -= 1
                    self?.pendingLock.unlock()
                }
                guard let self else { return }

                // P1 修复：NSImage 被强捕获进写盘闭包，缩放/编码（CGContext/CGImage/
                // NSBitmapImageRep/JPEG Data）产生大量临时对象，闭包不自动包池，
                // 背压窗口内的多帧叠加会放大峰值内存、诱发缓冲池扩容。包 autoreleasepool
                // 帧末及时释放临时对象，配合背压阈值降到 1 封顶内存。
                autoreleasepool {
                    // ── 1. 缩放到目标尺寸并编码 JPEG（训练端读 .jpg）──
                    if let jpgData = self.resizeAndEncodeJPEG(image: image, size: size) {
                        let frameURL = url.appendingPathComponent("frames")
                            .appendingPathComponent(String(format: "%06ld.jpg", idx))
                        try? jpgData.write(to: frameURL)
                    }

                    // ── 2. 追加 CSV 行 ──
                    let line = String(format: "%.4f,%ld,%.4f,%.4f,%.4f\n",
                                      timestamp, Int(idx), steer, throttle, brake)
                    if let data = line.data(using: .utf8),
                       data.count > 0 {
                        self.csvHandle?.write(data)
                    }
                }
            }
    }

    /// 追加一帧原生速度表 ROI 缓冲（字模模式专用，主线程调用）。
    /// - Parameter pixelBuffer: CaptureEngine onNativeFrame 投递的原生 ROI 缓冲
    ///   （speedROINorm 区域，原生分辨率未缩放 —— 数字 ~95px）。
    /// 帧号/背压逻辑与 appendFrame 完全一致（共用 pendingWrites 计数 + 丢帧阈值），
    /// 直接编码 PNG 存盘；不写 640×360 训练帧 / CSV（字模只关心画面）。
    func appendGlyphNative(pixelBuffer: CVPixelBuffer) {
        guard isRecording, let url = sessionURL else { return }

        // 背压：写盘队列待处理帧数超过 maxPendingWrites 时丢帧（与 appendFrame 共用同一阈值）
        pendingLock.lock()
        let pending = pendingWrites
        pendingLock.unlock()
        guard pending <= Self.maxPendingWrites else { return }

        let idx = frameCount
        frameCount += 1
        pendingLock.lock()
        pendingWrites += 1
        pendingLock.unlock()

        writeQueue.async { [weak self, pixelBuffer] in
            defer {
                self?.pendingLock.lock()
                self?.pendingWrites -= 1
                self?.pendingLock.unlock()
            }
            guard let self else { return }
            if let pngData = self.encodeNativePNG(pixelBuffer: pixelBuffer) {
                let frameURL = url.appendingPathComponent("frames")
                    .appendingPathComponent(String(format: "%06ld.png", idx))
                try? pngData.write(to: frameURL)
            }
        }
    }

    // MARK: - 画面缩放与编码

    /// 将 NSImage 缩放到指定尺寸并编码为 JPEG
    /// - Returns: JPEG 数据，失败返回 nil
    private func resizeAndEncodeJPEG(image: NSImage, size: CGSize) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                          context: nil,
                                          hints: nil) else { return nil }

        // 创建目标位图上下文（颜色空间 RGB，alpha 保留）
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 绘制（保持比例填充，可能裁切，与 UI 显示一致）
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        guard let outImage = context.makeImage() else { return nil }

        // 位图表示 → JPEG（训练端 mono_dataset 读 .jpg，质量 0.9 平衡清晰度/体积）
        let bitmapRep = NSBitmapImageRep(cgImage: outImage)
        return bitmapRep.representation(using: .jpeg,
                                         properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.9])
    }

    // MARK: - 字模模式：原生 ROI 编码

    /// 把 CaptureEngine onNativeFrame 投递的**原生速度表 ROI 缓冲**直接编码 PNG（不缩放、无损失）。
    /// P1-2 修复：字模录制改走原生路径（不再从 480px UI 缩略图裁剪 → 数字 ~95px 恢复）。
    /// 用 CGContext 直接引用缓冲基址 → CGImage → NSBitmapImageRep.png，
    /// 无 CIContext、无方向翻转（缓冲行序 top-down 与屏幕一致，字模训练所见即所得）。
    /// - Returns: PNG 数据；编码失败返回 nil（不阻塞录制主流程）
    private func encodeNativePNG(pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }
        // 32BGRA + premultipliedFirst + littleEndian32 == BGRA 内存序，
        // 与 CaptureEngine 原生 ROI 池（copyNativeFrame）的像素格式一致
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
