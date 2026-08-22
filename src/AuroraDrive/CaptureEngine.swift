// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ScreenCaptureKit
import CoreVideo
import CoreImage
import CoreGraphics
import Accelerate
import os

final class CaptureEngine: NSObject, SCStreamOutput {

    private let stateLock = OSAllocatedUnfairLock()
    private var _currentFrame: NSImage?
    private var _isCapturing = false
    private var _captureFPS: Double = 0
    private var _lastFrameGapMs: Double = 0
    private var _lastFrameWorkMs: Double = 0
    private var _upscaleEnabled = false
    private var _gameModeBoostEnabled = true
    private var _yoloScalingEnabled = false

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.aurora.capture.engine", qos: .userInteractive)
    private var onFrame: ((NSImage, CGImage?) -> Void)?
    private var onStatusChange: ((CaptureStatus) -> Void)?
    private var didStartCapture: (() -> Void)?

    private var yoloBufferPool: CVPixelBufferPool?
    private var yoloBufferPoolSize: Int = 0
    private var uiBufferPool: CVPixelBufferPool?
    private var uiPoolWidth: Int = 0
    private var uiPoolHeight: Int = 0
    private var nativePool: CVPixelBufferPool?
    private var nativePoolWidth: Int = 0
    private var nativePoolHeight: Int = 0
    private var fullFramePool: CVPixelBufferPool?
    private var fullFramePoolWidth: Int = 0
    private var fullFramePoolHeight: Int = 0

    private var lastFrameTime = Date.distantPast
    private var fpsAccumulator: Int = 0
    private var lastFPSDate = Date()

    private(set) var currentFrame: NSImage? {
        get { stateLock.withLock { _currentFrame } }
        set { stateLock.withLock { _currentFrame = newValue } }
    }

    private(set) var isCapturing: Bool {
        get { stateLock.withLock { _isCapturing } }
        set { stateLock.withLock { _isCapturing = newValue } }
    }

    private(set) var captureFPS: Double {
        get { stateLock.withLock { _captureFPS } }
        set { stateLock.withLock { _captureFPS = newValue } }
    }

    private(set) var lastFrameGapMs: Double {
        get { stateLock.withLock { _lastFrameGapMs } }
        set { stateLock.withLock { _lastFrameGapMs = newValue } }
    }

    private(set) var lastFrameWorkMs: Double {
        get { stateLock.withLock { _lastFrameWorkMs } }
        set { stateLock.withLock { _lastFrameWorkMs = newValue } }
    }

    var upscaleEnabled: Bool {
        get { stateLock.withLock { _upscaleEnabled } }
        set { stateLock.withLock { _upscaleEnabled = newValue } }
    }

    var gameModeBoostEnabled: Bool {
        get { stateLock.withLock { _gameModeBoostEnabled } }
        set { stateLock.withLock { _gameModeBoostEnabled = newValue } }
    }

    var yoloScalingEnabled: Bool {
        get { stateLock.withLock { _yoloScalingEnabled } }
        set { stateLock.withLock { _yoloScalingEnabled = newValue } }
    }

    // speedOCR 区域归一化坐标，主线程写入，captureQueue 读取；
    // 声明在 CaptureEngine 上以便 SpeedOCRReader / AuroraDriveApp 跨文件访问
    nonisolated(unsafe) static var speedROINorm: CGRect = .zero

    // MARK: - 启动 / 停止

    func start() {
        guard !isCapturing else { return }
        Task { [weak self] in
            guard let self else { return }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.current
            } catch {
                self.onStatusChange?(.error("获取屏幕内容失败（可能未授权）: \(error.localizedDescription)"))
                self.onStatusChange?(.permissionDenied)
                return
            }
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
            await self.startStream(display: display)
        }
    }

    private func startStream(display: SCDisplay) async {
        print("[capture] display frame=\(display.frame.size) w=\(display.width) h=\(display.height)")
        let config = SCStreamConfiguration()
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)
        } catch {
            onStatusChange?(.error("注册帧回调失败: \(error.localizedDescription)"))
            return
        }
        do {
            try await stream.startCapture()
            self.stream = stream
            self.isCapturing = true
            self.lastFPSDate = Date()
            self.onStatusChange?(.started)
            self.didStartCapture?()
        } catch {
            onStatusChange?(.error("启动捕获失败: \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard isCapturing, let stream = stream else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await stream.stopCapture() } catch {}
            self.stream = nil
            self.isCapturing = false
            self.currentFrame = nil
            self.captureQueue.sync {
                self.nativePool = nil; self.nativePoolWidth = 0; self.nativePoolHeight = 0
                self.fullFramePool = nil; self.fullFramePoolWidth = 0; self.fullFramePoolHeight = 0
                self.yoloBufferPool = nil; self.yoloBufferPoolSize = 0
                self.uiBufferPool = nil; self.uiPoolWidth = 0; self.uiPoolHeight = 0
            }
            self.onStatusChange?(.stopped)
        }
    }

    // MARK: - SCStreamOutput 帧回调

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        if gameModeBoostEnabled { applyGameModeBoost() }

        // P1修复：SCStream delegate不自动包autoreleasepool，30fps下每帧NSImage/CGImage/vImage等临时对象需帧末释放否则内存缓涨
        autoreleasepool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let frameStart = Date()
        // P2修复：首帧lastFrameTime为.distantPast时gap记0，避免诊断面板显示天文数字
        lastFrameGapMs = (lastFrameTime == .distantPast)
            ? 0
            : frameStart.timeIntervalSince(lastFrameTime) * 1000
        lastFrameTime = frameStart
        defer { lastFrameWorkMs = Date().timeIntervalSince(frameStart) * 1000 }
        updateFPS()

        if upscaleEnabled, let onUpscaleFrame, let fullCopy = copyFullFrame(from: pixelBuffer) {
            onUpscaleFrame(fullCopy)
        }

        if let onNativeFrame, let nativeCopy = copyNativeFrame(from: pixelBuffer) {
            onNativeFrame(nativeCopy)
        }

        if yoloScalingEnabled, let onYoloFrame {
            let size = YoloEngine.inputSize
            if let pool = makeYoloBufferPool(size: size) {
                var yb: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &yb) == kCVReturnSuccess,
                   let yb {
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
                        onYoloFrame(yb)
                    }
                }
            }
        }

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

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(uiBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(uiBuf, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(uiBuf) else { return }
        let pW = CVPixelBufferGetWidth(pixelBuffer)
        let pH = CVPixelBufferGetHeight(pixelBuffer)
        let pBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(pH),
                                   width: vImagePixelCount(pW),
                                   rowBytes: pBPR)
        var dstBuf = vImage_Buffer(data: dstBase,
                                   height: vImagePixelCount(dH),
                                   width: vImagePixelCount(dW),
                                   rowBytes: CVPixelBufferGetBytesPerRow(uiBuf))
        vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))

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
            Unmanaged<CVPixelBuffer>.fromOpaque(uiBufPtr).release()
            return
        }
        guard let cgImage = CGImage(width: dW, height: dH,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: rowBytes, space: colorSpace,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            return
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: dW, height: dH))

        currentFrame = nsImage

        onFrame?(nsImage, cgImage)
        }
    }

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
            kCVPixelBufferMetalCompatibilityKey: true,
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

    private func copyNativeFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }

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
        let bytesPerPixel = 4
        let srcOffset = roiX * bytesPerPixel
        let copyBytes = roiW * bytesPerPixel
        let dstRows = min(roiH, CVPixelBufferGetHeight(dst))
        for r in 0..<dstRows {
            memcpy(dBase + r * dBPR,
                   sBase + (roiY + r) * sBPR + srcOffset,
                   copyBytes)
        }
        return dst
    }

    private func nativeBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        pool(width: width, height: height, storage: &nativePool, wKey: &nativePoolWidth, hKey: &nativePoolHeight)
    }

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
        let rowBytes = min(sBPR, dBPR)
        for r in 0..<h {
            memcpy(dBase + r * dBPR, sBase + r * sBPR, rowBytes)
        }
        return dst
    }

    private func fullFrameBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        pool(width: width, height: height, storage: &fullFramePool, wKey: &fullFramePoolWidth, hKey: &fullFramePoolHeight)
    }

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

    private func applyGameModeBoost() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func units(_ ns: UInt32) -> UInt32 {
            guard tb.denom > 0, tb.numer > 0 else { return ns }
            return UInt32((UInt64(ns) * UInt64(tb.denom)) / UInt64(tb.numer))
        }
        var pol = thread_time_constraint_policy_data_t(
            period: units(33_333_333),
            computation: units(18_000_000),
            constraint: units(30_000_000),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &pol) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                thread_policy_set(mach_thread_self(),
                                  UInt32(THREAD_TIME_CONSTRAINT_POLICY),
                                  ip,
                                  count)
            }
        }
    }
}
