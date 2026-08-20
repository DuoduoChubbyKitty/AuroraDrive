// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  CaptureEngine.swift — 全屏画面流捕获引擎（ScreenCaptureKit）
//  macOS 12.3+ 的官方截屏 API，性能最佳，系统原生集成
//  建立持续画面流（30fps），系统自动推送新帧，内存固定不增长
//  通过闭包回调输出 NSImage，供 UI 显示和模型推理共用
// ============================================================================

import AppKit
import ScreenCaptureKit
import CoreVideo
import CoreImage
import CoreGraphics
import Accelerate
import os

/// 画面流捕获引擎（基于 ScreenCaptureKit）
/// - 建立一条 SCStream 持续画面流（30fps）
/// - 系统在画面变化时自动推送新帧，无需反复截图
/// - 每帧通过 onFrame 闭包输出 NSImage，UI 显示与模型推理共用同一条流
/// - 调用 start() 开始，stop() 停止
final class CaptureEngine: NSObject, SCStreamOutput {

    /// 当前帧图像（UI 显示用）
    private(set) var currentFrame: NSImage? {
        get { stateLock.withLock { _currentFrame } }
        set { stateLock.withLock { _currentFrame = newValue } }
    }

    /// 是否正在捕获
    private(set) var isCapturing: Bool {
        get { stateLock.withLock { _isCapturing } }
        set { stateLock.withLock { _isCapturing = newValue } }
    }

    /// 捕获帧率（每秒更新一次）
    private(set) var captureFPS: Double {
        get { stateLock.withLock { _captureFPS } }
        set { stateLock.withLock { _captureFPS = newValue } }
    }

    /// 帧回调（每帧调用，传入 NSImage + CGImage）
    /// NSImage 供录制/现有引用；CGImage 直传下游（推屏/推理/置信度），
    /// 省去下游 NSImage→CGImage 的重复转换（环2）
    var onFrame: ((NSImage, CGImage) -> Void)?

    /// YOLO 直通回调（每帧调用，传入 YoloEngine.inputSize×inputSize BGRA 像素缓冲）
    /// CaptureEngine 在源头用 vImage(CPU) 把全屏画面缩放到模型输入尺寸，
    /// 跳过 NSImage/CGImage 大图转换链路 → 检测帧率显著提升
    var onYoloFrame: ((CVPixelBuffer) -> Void)?

    /// 原生帧直通回调（每帧调用，传入速度表 ROI 原生分辨率 CVPixelBuffer，未缩放）
    /// SpeedOCR 等需要"原生分辨率直裁直读（不插值）"的下游用这条，
    /// 绕开 NSImage 缩放链路；与 onFrame / onYoloFrame 互不影响
    var onNativeFrame: ((CVPixelBuffer) -> Void)?

    /// 插帧引擎原生全帧直通回调（每帧调用，传入**整幅**原生分辨率 CVPixelBuffer，未缩放）
    /// MetalGoose 插帧（独立显示引擎）专用：与 onFrame(480px 显示帧)/onYoloFrame/onNativeFrame(ROI)
    /// 完全独立，自动驾驶决策链路不吃它。在 captureQueue 内同步整帧拷贝后送出。
    var onUpscaleFrame: ((CVPixelBuffer) -> Void)?

    /// 速度表 ROI（归一化，左上角原点 y 向下）。字模录制（glyphMode）与 SpeedOCR 共用此 ROI。
    /// 环1：copyNativeFrame 只拷贝该区域（≈100KB，替代整帧 22MB），
    /// SpeedOCRReader 用同一常量把槽位坐标换算到 ROI 相对坐标（与 Python crop_slot(roi=...) 一致）。
    /// 默认覆盖右下角 "N 000 km/h" 速度表；用户「标注HUD」手动框选覆盖，预设记忆。
    /// 写侧（主线程标注确认，低频）/读侧（copyNativeFrame，captureQueue 每帧）——
    /// nonisolated(unsafe)：CGRect 4×Double 的 torn 风险在低频写/高频读下可忽略。
    nonisolated(unsafe) static var speedROINorm = CGRect(x: 0.50, y: 0.76,
                                                         width: 0.32, height: 0.18)

    /// 状态变化回调（启动/停止/错误）
    var onStatusChange: ((CaptureStatus) -> Void)?

    /// 捕获状态
    enum CaptureStatus {
        case started
        case stopped
        case error(String)
        case permissionDenied
    }

    // MARK: - 私有属性

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)
    private var lastFPSDate: Date = .distantPast
    private var fpsAccumulator: Int = 0

    // P0-3 修复：诊断/状态属性写于 captureQueue、读于主线程，跨线程裸读写存在
    // 数据竞争（torn read 可能读出 NaN → 读侧 Int(NaN) trap）。
    // 用 OSAllocatedUnfairLock 保护读写（纳秒级开销，不触碰 30fps 红线）。
    private let stateLock = OSAllocatedUnfairLock()
    private var _currentFrame: NSImage?
    private var _isCapturing = false
    private var _captureFPS: Double = 0
    private var _lastFrameGapMs: Double = 0
    private var _lastFrameWorkMs: Double = 0

    /// 原生帧自持缓冲池（与 SCStream 生命周期解耦）
    /// 在 captureQueue 内同步把 SCStream 缓冲按行拷贝到池缓冲，再派发主线程；
    /// 池缓冲由下游闭包持有引用，用完后自动回池 —— 主线程永不接触系统托管缓冲
    private var nativePool: CVPixelBufferPool?
    private var nativePoolWidth = 0
    private var nativePoolHeight = 0

    /// 插帧引擎全帧缓冲池（整幅原生分辨率自持拷贝，深度 ≥4）
    private var fullFramePool: CVPixelBufferPool?
    private var fullFramePoolWidth = 0
    private var fullFramePoolHeight = 0

    /// 插帧直通开关（线程安全）：关闭时不整帧拷贝/不回调，零开销。
    /// DriveState 在主线程开关变化时写入，captureQueue 每帧读取。
    private let upscaleGateLock = OSAllocatedUnfairLock()
    private var _upscaleEnabled = false
    var upscaleEnabled: Bool {
        get { upscaleGateLock.withLock { _upscaleEnabled } }
        set { upscaleGateLock.withLock { _upscaleEnabled = newValue } }
    }

    /// 游戏模式兼容开关（线程安全）：开启时每帧对捕获线程设置
    /// THREAD_TIME_CONSTRAINT_POLICY 时间约束调度，对抗 macOS 游戏模式
    /// 对后台 App 的降权（游戏全屏时后台线程被饿，capWork 5ms→数秒、App 只有一帧）。
    /// 关闭恢复普通调度（游戏模式降权重新生效）。DriveState 主线程开关变化时写入，
    /// captureQueue 每帧读取。
    private let gameModeBoostLock = OSAllocatedUnfairLock()
    private var _gameModeBoostEnabled = true
    var gameModeBoostEnabled: Bool {
        get { gameModeBoostLock.withLock { _gameModeBoostEnabled } }
        set { gameModeBoostLock.withLock { _gameModeBoostEnabled = newValue } }
    }

    /// YOLO 直通缩放闸门（线程安全）：关闭时跳过 全屏→640 vImage 缩放 + onYoloFrame 回调。
    /// 待机（未驾驶）时 YOLO 检测既不被决策用也不被叠加层显示（ObstacleOverlay active=isDriving），
    /// 若录制（仅采集画面）仍每帧做 2940×1920→640 的 CPU vImage 缩放纯属浪费 ——
    /// DriveState 在开始驾驶时置 true、停止驾驶时置 false，captureQueue 每帧读取。
    private let yoloGateLock = OSAllocatedUnfairLock()
    private var _yoloScalingEnabled = false
    var yoloScalingEnabled: Bool {
        get { yoloGateLock.withLock { _yoloScalingEnabled } }
        set { yoloGateLock.withLock { _yoloScalingEnabled = newValue } }
    }

    /// YOLO 直通缩放缓冲池（vImage 直接缩放进池化私有缓冲，每帧独立，池深度 ≥4）
    /// 缓冲由下游 onYoloFrame 闭包强捕获持有，直到 tick 消费 + inferFast 拷贝完才释放回池；
    /// 全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容。
    private var yoloBufferPool: CVPixelBufferPool?
    private var yoloBufferPoolSize = 0

    /// UI 显示缓冲池（vImage 缩放到 480 宽后，CGImage 经 CGDataProvider 零拷贝引用其基址）
    /// 尺寸随源分辨率固定（dW×dH），若变化则重建。
    private var uiBufferPool: CVPixelBufferPool?
    private var uiPoolWidth = 0
    private var uiPoolHeight = 0

    // ── 诊断尺子（纯测量，定位延迟高在哪一环）──
    // capGap：相邻两帧捕获间隔(ms)，正常~33ms，变大/波动 = 捕获或处理慢
    // capWork：每帧 captureQueue 处理耗时(ms)，含 22MB 拷贝+YOLO+UI渲染+回调
    private(set) var lastFrameGapMs: Double {
        get { stateLock.withLock { _lastFrameGapMs } }
        set { stateLock.withLock { _lastFrameGapMs = newValue } }
    }
    private(set) var lastFrameWorkMs: Double {
        get { stateLock.withLock { _lastFrameWorkMs } }
        set { stateLock.withLock { _lastFrameWorkMs = newValue } }
    }
    // lastFrameTime / fpsAccumulator 仅在 captureQueue 串行读写，无跨线程竞争，无需加锁
    private var lastFrameTime: Date = .distantPast

    // MARK: - 启动 / 停止

    /// 启动全屏画面流捕获
    /// ScreenCaptureKit 流程（async/await 版本，macOS 12.3+）：
    /// 1. 请求屏幕录制权限（try await SCShareableContent.current 会触发权限弹窗）
    /// 2. 获取主显示器
    /// 3. 创建 SCStream 配置（30fps，全屏分辨率）
    /// 4. 启动流，通过 delegate 接收 CMSampleBuffer 帧
    func start() {
        guard !isCapturing else { return }

        // 用 Task 包装 async 调用
        Task { [weak self] in
            guard let self = self else { return }

            // 1. 获取可共享内容（包含权限检查）
            //    macOS 10.15+ 首次调用会触发系统授权弹窗
            //    无权限时会抛出错误
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.current
            } catch {
                self.onStatusChange?(.error("获取屏幕内容失败（可能未授权）: \(error.localizedDescription)"))
                self.onStatusChange?(.permissionDenied)
                return
            }

            // 2. 获取主显示器（避免抓 displays.first 的任意顺序屏）
            let mainDisplayID = CGMainDisplayID()
            let display: SCDisplay
            if let d = content.displays.first(where: { $0.displayID == mainDisplayID }) {
                display = d
            } else if let d = content.displays.first {
                display = d
            } else {
                self.onStatusChange?(.error("未找到可用的显示器"))
                return
            }
            print("[capture] selected displayID=\(display.displayID) main=\(mainDisplayID)")

            // 3. 创建并启动流
            await self.startStream(display: display)
        }
    }

    /// 创建并启动 SCStream（async 版本）
    private func startStream(display: SCDisplay) async {
        // 诊断日志：确认显示器输出分辨率（字模模式依赖原生分辨率，实测点/像素语义）
        // SCDisplay.width 按 Apple 文档是像素，但实测需确认；若为点值需 ×backingScaleFactor
        print("[capture] display frame=\(display.frame.size) w=\(display.width) h=\(display.height)")
        // 流配置
        let config = SCStreamConfiguration()
        // 输出显示器**原生像素**分辨率：SCDisplay.width 实测可能返回点值
        // （导致输出只有 ~1485×960、速度表数字仅 ~18px，字模/OCR 精度不足），
        // 这里用 NSScreen.frame(点) × backingScaleFactor 换算成真像素，
        // 保证速度表数字 ~95px 清晰（字模训练与运行时 OCR 都受益）。
        if let screen = NSScreen.screens.filter({
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                == NSNumber(value: display.displayID)
        }).first {
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
        } else {
            config.width = display.width
            config.height = display.height
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30fps 上限
        config.pixelFormat = kCVPixelFormatType_32BGRA  // 显式锁 32BGRA：vImageScale_ARGB8888 依赖此格式（防 SCStream 未来返回 420 花帧）
        config.queueDepth = 3                       // 帧队列深度 3（平衡延迟与流畅）
        config.showsCursor = true                   // 画面包含鼠标

        // 内容过滤器（捕获整个显示器，不排除任何窗口）
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 创建 SCStream（非 Optional，直接初始化）
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // 注册帧输出回调
        // type: SCStreamOutputType.screen 表示捕获屏幕画面（区别于 .audio 音频）
        do {
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)
        } catch {
            onStatusChange?(.error("注册帧回调失败: \(error.localizedDescription)"))
            return
        }

        // 启动流（async/await 版本）
        do {
            try await stream.startCapture()
            self.stream = stream
            self.isCapturing = true
            self.lastFPSDate = Date()
            self.onStatusChange?(.started)
        } catch {
            onStatusChange?(.error("启动捕获失败: \(error.localizedDescription)"))
        }
    }

    /// 停止画面流捕获
    func stop() {
        guard isCapturing, let stream = stream else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await stream.stopCapture()
            } catch {
                // 停止失败不阻塞，继续清理状态
            }
            self.stream = nil
            self.isCapturing = false
            self.currentFrame = nil
            // P2 修复：停捕获时把三个 CVPixelBufferPool 置 nil，释放 ~8MB 空闲缓冲
            //（下次 start 会按当前分辨率重建）。三个池只在 captureQueue 上被
            // stream() 回调经 make*BufferPool 读写，这里同样派发到 captureQueue
            // 串行清理，避免与在途帧回调竞争（否则跨线程写 nil 与建池构成数据竞争）。
            self.captureQueue.sync {
                self.nativePool = nil
                self.nativePoolWidth = 0
                self.nativePoolHeight = 0
                self.fullFramePool = nil
                self.fullFramePoolWidth = 0
                self.fullFramePoolHeight = 0
                self.yoloBufferPool = nil
                self.yoloBufferPoolSize = 0
                self.uiBufferPool = nil
                self.uiPoolWidth = 0
                self.uiPoolHeight = 0
            }
            self.onStatusChange?(.stopped)
        }
    }

    // MARK: - SCStreamOutput 帧回调

    /// ScreenCaptureKit 每帧回调
    /// 系统在画面变化时自动调用，传入 CMSampleBuffer
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 只处理屏幕画面帧（忽略音频）
        guard type == .screen else { return }

        // 游戏模式兼容：每帧对当前线程设置时间约束调度（幂等，<1µs），
        // 对抗游戏模式对后台 App 的降权；开关关闭时跳过（零开销）。
        if gameModeBoostEnabled { applyGameModeBoost() }

        // P1 修复：SCStream delegate 回调不自动包 autoreleasepool，30fps 下每帧
        // 临时对象（NSImage/CGImage/CGDataProvider/vImage 等）若不在帧末释放，
        // 长时间运行会内存缓涨。整个每帧处理逻辑包进 autoreleasepool，帧末统一释放。
        autoreleasepool {
        // 从 CMSampleBuffer 提取 CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 诊断：相邻帧到达间隔 + 本帧处理起点（定位"捕获慢 / 处理重"）
        let frameStart = Date()
        // P2 修复：首帧 lastFrameTime 为 .distantPast，timeIntervalSince 会得到 ~5e11 ms
        // 的假值；首帧 gap 记 0，避免诊断面板显示天文数字。
        lastFrameGapMs = (lastFrameTime == .distantPast)
            ? 0
            : frameStart.timeIntervalSince(lastFrameTime) * 1000
        lastFrameTime = frameStart
        // 诊断兜底：无论本帧后续是否成功，都统计 FPS 与 capWork（失败路径不跳过诊断）
        defer { lastFrameWorkMs = Date().timeIntervalSince(frameStart) * 1000 }
        updateFPS()

        // ── 插帧引擎原生全帧直通：整幅原生分辨率自持拷贝 ──
        // 独立显示引擎（MetalGoose），决策链路不吃；先于 ROI 拷贝送出，
        // 保证插帧拿到的是未缩放的完整游戏画面。开关关闭时跳过，零开销。
        if upscaleEnabled, let onUpscaleFrame, let fullCopy = copyFullFrame(from: pixelBuffer) {
            onUpscaleFrame(fullCopy)
        }

        // ── 原生帧直通：在 captureQueue 内同步拷贝到自持缓冲，再派发主线程 ──
        // SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统
        // 回收/覆写 → use-after-release（轻则裁出垃圾、重则崩溃）。
        // 这里用 CVPixelBufferPool 私有缓冲逐行整拷一份，行序照抄 src 的
        // bytesPerRow（不做方向解释，方向语义由下游 CIImage 路径负责），
        // 主线程永远持有自己的拷贝，与 SCStream 生命周期彻底解耦。
        if let onNativeFrame, let nativeCopy = copyNativeFrame(from: pixelBuffer) {
            onNativeFrame(nativeCopy)
        }

        // ── YOLO 直通：CPU vImage 缩放到模型输入尺寸（YoloEngine.inputSize，640）──
        // 在源头完成缩放，绕开大图 → NSImage → CGImage → 再缩放的链路。
        // 闸门 yoloScalingEnabled：未驾驶时（录制采集画面/待机预览）YOLO 检测无用，
        // 跳过 2940×1920→640 的整帧 vImage 缩放，避免白烧 CPU。
        if yoloScalingEnabled, let onYoloFrame {
            // 直接缩放进池化私有缓冲（每帧独立、池深度 ≥4），下游 onYoloFrame 强捕获该缓冲，
            // 直到 tick 消费 + inferFast 拷贝完才释放回池 —— 主线程卡顿也不会拿到被覆写的帧。
            // 相比旧「双缓冲 + copyYoloFrame 整拷一份」省掉一次 640×640×4 ≈ 1.6MB 冗余 memcpy。
            let size = YoloEngine.inputSize
            if let pool = makeYoloBufferPool(size: size) {
                var yb: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &yb) == kCVReturnSuccess,
                   let yb {
                    // vImage 缩放到模型输入尺寸（CPU，双线性 kvImageNoFlags）：
                    // 消除游戏占满 GPU 时 CIContext(GPU) 排队导致的 40ms 卡顿。
                    // 非等比拉伸到 640×640（与训练/慢路径一致，不保持宽高比）；
                    // 字节序 32BGRA = ARGB8888 little-endian，vImageScale_ARGB8888 正确处理，B/G/R 顺序不变。
                    let swv = CVPixelBufferGetWidth(pixelBuffer)
                    let shv = CVPixelBufferGetHeight(pixelBuffer)
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    CVPixelBufferLockBaseAddress(yb, [])
                    defer {
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                        CVPixelBufferUnlockBaseAddress(yb, [])
                    }
                    if let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
                       let dstBase = CVPixelBufferGetBaseAddress(yb) {
                        var srcBuf = vImage_Buffer(data: srcBase,
                                                   height: vImagePixelCount(shv),
                                                   width: vImagePixelCount(swv),
                                                   rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
                        var dstBuf = vImage_Buffer(data: dstBase,
                                                   height: vImagePixelCount(size),
                                                   width: vImagePixelCount(size),
                                                   rowBytes: CVPixelBufferGetBytesPerRow(yb))
                        vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
                        onYoloFrame(yb)   // 仅缩放成功才送出；GetBaseAddress 失败则跳过本帧直通
                    }
                }
            }
        }

        // ── UI 帧压缩渲染（用户拍板 480px，只降每帧成本、不降频率）──
        // 旧实现：render 2940×1912 全分辨率 CGImage（~22MB）再靠 NSImage 的 size
        // 参数"假装"缩放（size 只是绘制提示，底层位图仍全分辨率）→ 每帧 22MB
        // 分配 + 全画面 GPU 渲染 + SwiftUI 每帧绘制大图，30fps 下 660MB/s 分配速率；
        // 运行 1-2 分钟后系统内存压力累积（实测 lag 飙到 878-1382ms、掉到 0 帧）。
        // 现改为 CPU vImage 全屏等比直缩到 480 宽（~0.6MB），CGImage 经 CGDataProvider
        // 零拷贝引用缩放缓冲（并 retain 该缓冲保证生命周期），完全绕开 CIContext(GPU)，
        // 消除游戏占满 GPU 时的排队卡顿。
        // 捕获/推理频率不变（30fps 红线）；OCR（onNativeFrame）、YOLO（onYoloFrame）
        // 走各自直通路径不受影响。
        let maxWidth: CGFloat = 480
        let sw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sh = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let uiScale = min(1.0, maxWidth / sw)
        let dW = Int((sw * uiScale).rounded())
        let dH = Int((sh * uiScale).rounded())
        guard dW > 0, dH > 0,
              let uiPool = makeUIBufferPool(width: dW, height: dH) else { return }
        var uiBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, uiPool, &uiBuf) == kCVReturnSuccess,
              let uiBuf else { return }

        // vImage 等比缩放到 uiBuf（CPU 双线性，方向/字节序与 GPU 路径一致，不翻转）
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(uiBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(uiBuf, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(uiBuf) else { return }
        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        var dstBuf = vImage_Buffer(data: dstBase,
                                   height: vImagePixelCount(dH),
                                   width: vImagePixelCount(dW),
                                   rowBytes: CVPixelBufferGetBytesPerRow(uiBuf))
        vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))

        // 关键：CGImage 必须持有 uiBuf，零拷贝且生命周期正确绑定。
        // 旧写法 CGContext(data:)+makeImage() 是 COW 快照，不保证物理拷贝；
        // uiBuf 回池后被下一帧 vImage 覆写 → 屏幕显示撕裂/花帧（use-after-recycle）。
        // 这里用 CGDataProvider 的 releaseData 回调 retain uiBuf，图像存活期间池不会复用该缓冲。
        let rowBytes = CVPixelBufferGetBytesPerRow(uiBuf)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        let uiBufPtr = Unmanaged.passRetained(uiBuf).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: uiBufPtr,
            data: dstBase,
            size: rowBytes * dH,
            releaseData: { info, _, _ in
                Unmanaged<CVPixelBuffer>.fromOpaque(info!).release()
            }) else {
            // provider 创建失败：手动 release 那 +1，避免泄漏
            Unmanaged<CVPixelBuffer>.fromOpaque(uiBufPtr).release()
            return
        }
        guard let cgImage = CGImage(width: dW, height: dH,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: rowBytes, space: colorSpace,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            // cgImage 创建失败：provider 已随 ARC 析构，其 releaseData 会释放那 +1，此处不手动 release
            return
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: dW, height: dH))

        // 更新当前帧
        currentFrame = nsImage

        // 通过闭包回调输出（UI 显示和模型推理共用）
        onFrame?(nsImage, cgImage)
        }   // autoreleasepool 结束
    }

    /// 惰性创建（或复用）与 YOLO 输入同尺寸的私有缩放缓冲池
    /// attrs 与模型输入一致（32BGRA + CGImage/CGBitmapContext/Metal 兼容），
    /// 池深度 ≥4：主线程/推理队列通常 1-2 帧在途，留足余量避免频繁分配。
    private func makeYoloBufferPool(size: Int) -> CVPixelBufferPool? {
        if let pool = yoloBufferPool, yoloBufferPoolSize == size {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size,
            kCVPixelBufferHeightKey: size,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,   // 与模型输入一致
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        yoloBufferPool = pool
        yoloBufferPoolSize = size
        return pool
    }

    /// 惰性创建（或复用）UI 显示缓冲池（32BGRA，dW×dH）
    /// vImage 缩放到该缓冲后，CGImage 经 CGDataProvider 直接引用其基址零拷贝（并 retain 该缓冲），
    /// 池深度 ≥4（主线程 1-2 帧在途留余量），尺寸随源分辨率固定，dW/dH 变化则重建。
    private func makeUIBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = uiBufferPool, uiPoolWidth == width, uiPoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        uiBufferPool = pool
        uiPoolWidth = width
        uiPoolHeight = height
        return pool
    }

    // MARK: - 原生帧自持拷贝

    /// 同步拷贝原生帧的**速度表 ROI** 到自持小缓冲（仅 captureQueue 串行调用，无需加锁）
    /// - Note: 环1 优化 —— 只逐行 memcpy speedROINorm 区域（≈100KB），不再整帧 22MB。
    ///   行序照抄 src 的 bytesPerRow（row 0 = 画面顶部），ROI 顶部行 = src 的 roiY 行，
    ///   逐行 1:1 复制、不翻转、不解释方向；方向语义由下游（SpeedOCRReader CIImage 路径）负责。
    /// - Returns: ROI 自持拷贝缓冲（尺寸 ≈ 速度表区域）；拷贝失败返回 nil（调用方跳过该帧直通）
    private func copyNativeFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }

        // 归一化 ROI → 像素（用 .toNearestOrEven 与 cropSlots 的 round() 同源，保证边界量化一致）
        let roi = Self.speedROINorm
        let roiX = Int((roi.origin.x * CGFloat(w)).rounded(.toNearestOrEven))
        let roiY = Int((roi.origin.y * CGFloat(h)).rounded(.toNearestOrEven))
        let roiW = Int((roi.width * CGFloat(w)).rounded(.toNearestOrEven))
        let roiH = Int((roi.height * CGFloat(h)).rounded(.toNearestOrEven))
        guard roiX >= 0, roiY >= 0, roiW > 0, roiH > 0,
              roiX + roiW <= w, roiY + roiH <= h,
              let pool = nativeBufferPool(width: roiW, height: roiH) else { return nil }

        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let sBPR = CVPixelBufferGetBytesPerRow(src)
        let dBPR = CVPixelBufferGetBytesPerRow(dst)
        let bytesPerPixel = 4                          // 32BGRA
        let srcOffset = roiX * bytesPerPixel           // 每行起始像素偏移（字节）
        let copyBytes = roiW * bytesPerPixel           // 每行拷贝字节数
        let dstRows = min(roiH, CVPixelBufferGetHeight(dst))
        for r in 0..<dstRows {
            memcpy(dBase + r * dBPR,
                   sBase + (roiY + r) * sBPR + srcOffset,
                   copyBytes)
        }
        return dst
    }

    /// 惰性创建（或复用）与 ROI 同尺寸的私有缓冲池
    /// 池深度 ≥4：主线程通常 1-2 帧在途，留足余量避免频繁分配；
    /// 全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容。
    private func nativeBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = nativePool, nativePoolWidth == width, nativePoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        nativePool = pool
        nativePoolWidth = width
        nativePoolHeight = height
        return pool
    }

    /// 同步拷贝**整幅**原生帧到自持缓冲（仅 captureQueue 串行调用）
    /// 供插帧引擎（MetalGoose 独立显示链路）使用：保持原生分辨率喂入，
    /// 行序照抄 src bytesPerRow（row 0 = 画面顶部，不翻转、不解释方向）。
    /// - Returns: 整帧自持拷贝缓冲；拷贝失败返回 nil（调用方跳过该帧直通）
    private func copyFullFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0,
              let pool = fullFrameBufferPool(width: w, height: h) else { return nil }

        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let sBPR = CVPixelBufferGetBytesPerRow(src)
        let dBPR = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = min(sBPR, dBPR)          // 每行拷贝字节数（行尾对齐填充不拷）
        for r in 0..<h {
            memcpy(dBase + r * dBPR, sBase + r * sBPR, rowBytes)
        }
        return dst
    }

    /// 惰性创建（或复用）整幅原生分辨率缓冲池（深度 ≥4）
    private func fullFrameBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = fullFramePool, fullFramePoolWidth == width, fullFramePoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        fullFramePool = pool
        fullFramePoolWidth = width
        fullFramePoolHeight = height
        return pool
    }

    /// FPS 统计（每秒计算一次）
    private func updateFPS() {
        fpsAccumulator += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSDate)
        if elapsed >= 1.0 {
            captureFPS = Double(fpsAccumulator) / elapsed
            fpsAccumulator = 0
            lastFPSDate = now
        }
    }

    // MARK: - 游戏模式对抗（时间约束调度）

    /// 给当前线程设置时间约束调度（THREAD_TIME_CONSTRAINT_POLICY）。
    /// 系统保证该线程在每个 period 周期内至少拿到 computation 的 CPU 时间，
    /// 调度优先级高于游戏模式等"后台任务降权"——专业录屏/音频线程对抗
    /// macOS 游戏模式的标准做法（苹果官方：游戏模式"降低后台任务资源占用"）。
    ///
    /// 参数保守（30fps 决策链红线不动）：
    /// - period      = 33.3ms  （30fps 帧周期）
    /// - computation = 10ms    （每帧预算；正常 capWork≈5ms，留 2 倍余量）
    /// - constraint  = 20ms    （单帧硬上限，超限由系统仲裁，不会失控占核）
    /// 每帧只占用单核 ~30% 的保证份额，游戏仍拿大头；空闲（无帧）时线程阻塞不占片。
    ///
    /// GCD 捕获队列可能复用线程池线程，故每帧对"当前线程"幂等设置（一次 mach 调用，
    /// <1µs，不触碰 30fps 红线）；线程回池后带策略继续服务本 App 其他队列无碍
    /// （都是自家活，且空闲线程不占时间片）。
    private func applyGameModeBoost() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func units(_ ns: UInt32) -> UInt32 {
            guard tb.denom > 0, tb.numer > 0 else { return ns }
            return UInt32((UInt64(ns) * UInt64(tb.denom)) / UInt64(tb.numer))
        }
        var pol = thread_time_constraint_policy_data_t(
            period: units(33_333_333),      // 33.3ms 周期（30fps）
            computation: units(18_000_000), // 每帧预算 18ms（实测 capWork 游戏模式下需 ~15-20ms）
            constraint: units(30_000_000),  // 单帧硬上限 30ms
            preemptible: 1)                 // 可被更高优先级抢占（安全）
        // Mach 参数：flavor 用 UInt32；policy 指针须 rebind 到 integer_t (Int32)；
        // count = 策略结构体按 integer_t 计的元素数（thread_time_constraint = 4）。
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &pol) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                thread_policy_set(mach_thread_self(),
                                  UInt32(THREAD_TIME_CONSTRAINT_POLICY),
                                  ip,
                                  count)
            }
        }
    }
}
