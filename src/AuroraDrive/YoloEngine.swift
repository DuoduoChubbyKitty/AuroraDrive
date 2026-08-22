// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreML
import Vision
import AppKit

// MARK: - COCO 类别映射
enum CocoLabels {
    static let names = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench",
        "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
        "backpack", "umbrella", "handbag", "tie", "suitcase",
        "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove",
        "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl",
        "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza",
        "donut", "cake", "chair", "couch", "potted plant", "bed",
        "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
        "cell phone", "microwave", "oven", "toaster", "sink", "refridgerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    enum Category: String {
        case person, bicycle, car, motorcycle, airplane, bus, train, truck, boat
        case trafficLight, stopSign, parkingMeter
        case fireHydrant, bench
        case backpack, umbrella, handbag, tie, suitcase
        case bird, cat, dog, horse, sheep, cow, elephant, bear, zebra, giraffe
        case frame, obstacle
    }

    static func map(_ idx: Int) -> (Category, String) {
        let i = max(0, min(idx, names.count - 1))
        let name = names[i]
        let cat: Category
        switch name {
        case "traffic light":   cat = .trafficLight
        case "stop sign":       cat = .stopSign
        case "parking meter":   cat = .parkingMeter
        case "fire hydrant":    cat = .fireHydrant
        case "bench":           cat = .bench
        default:
            if let c = Category(rawValue: name) { cat = c }
            else { cat = .frame }
        }
        return (cat, name)
    }
}

// MARK: - 检测结果
struct Detection {
    let x, y, width, height: Double
    let label: CocoLabels.Category
    let confidence: Double
    let rawName: String

    init(x: Double, y: Double, width: Double, height: Double,
         label: CocoLabels.Category, confidence: Double, rawName: String) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.label = label; self.confidence = confidence; self.rawName = rawName
    }

    var minX: Double { x - width / 2 }
    var minY: Double { y - height / 2 }
    var maxX: Double { x + width / 2 }
    var maxY: Double { y + height / 2 }

    enum DangerZone { case none, caution, danger }
    func isInDangerZone() -> DangerZone {
        let cx = x, cy = y, w = width, h = height
        if cy > 0.65 && w > 0.18 && h > 0.18 {
            if cx > 0.25 && cx < 0.75 { return .danger }
        }
        if cy > 0.50 && w > 0.10 && h > 0.10 {
            if cx > 0.20 && cx < 0.80 { return .caution }
        }
        return .none
    }
}

// MARK: - 检测引擎
@MainActor
class YoloEngine: ObservableObject {
    @Published var detections: [Detection] = []
    @Published var errorMessage: String?
    @Published var lastLatencyMs: Double = 0
    @Published var inferenceCount: Int = 0
    @Published var isLoaded: Bool = false

    // MARK: - 模型常量
    static let modelURL = Bundle.main.url(forResource: "yolo26s",
                                          withExtension: "mlmodelc")!
    static let inputSize = 640
    static let invInputSize = 1.0 / Double(inputSize)

    // MARK: - 预热张量（一次性分配，避免每次 loadIfNeeded 重复生成 6MB 临时数组）
    static let warmupTensor: [Float] = {
        let count = 3 * 640 * 640
        var arr = [Float](repeating: 0.5, count: count)
        return arr
    }()

    // MARK: - 可调参数
    @Published var confidenceThreshold: Double = 0.25 {
        didSet { UserDefaults.standard.set(confidenceThreshold, forKey: "aurora.yoloConf") }
    }
    @Published var maxDetections: Int = 50 {
        didSet { UserDefaults.standard.set(maxDetections, forKey: "aurora.yoloMax") }
    }

    // MARK: - 状态输出
    @Published var isLocked: Bool = false
    @Published var lockedTarget: Detection?
    @Published var lockMessage: String?
    @Published var lockLostFrames: Int = 0

    // MARK: - 锁定追踪（手动框选 → 对焦式跟踪）
    private var trackedLock: Detection?
    private var trackLossFrames: Int = 0
    private let trackLostThreshold = 30

    // MARK: - 内部资源
    private let engineQueue = DispatchQueue(label: "aurora.yolo.engine", qos: .userInteractive)
    private var model: MLModel?
    private var lastFrame: [Detection] = []
    private var smoothUsed: [Bool] = []
    private var generation = 0
    private var isInferencing = false
    private var lastInferTime = Date()
    private let inferCooldownMs: TimeInterval = 1 / 24.0
    private var errorMessageInternal: String?
    internal var fastPathActive = false

    // MARK: - 模型加载
    func loadIfNeeded() {
        guard model == nil else { return }
        isLoaded = false
        do {
            model = try MLModel(contentsOf: YoloEngine.modelURL)
            isLoaded = true
            Task { @MainActor [weak self] in self?.errorMessage = nil }
            if let m = model {
                engineQueue.async(execute: DispatchWorkItem(block: {
                    // 复用静态预热张量，避免每次推理初始化时分配 6MB 临时数组
                    guard let arr = try? MLMultiArray(shape: [1, 3, 640, 640], dataType: .float32) else { return }
                    memcpy(arr.dataPointer, Self.warmupTensor.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }, Self.warmupTensor.count * MemoryLayout<Float>.size)
                    guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]) else { return }
                    _ = try? m.prediction(from: provider)
                }))
            }
        } catch {
            let msg = "模型加载失败: \(error.localizedDescription)"
            Task { @MainActor [weak self] in self?.errorMessage = msg }
        }
    }

    // MARK: - 推理入口（主线程）
    // 接受 CVPixelBuffer 直接推理（capture 回调路径，高频）
    func infer(pixelBuffer: CVPixelBuffer) {
        guard isLoaded, let modelRef = model else {
            loadIfNeeded(); return
        }
        guard !isInferencing else { return }
        guard Date().timeIntervalSince(lastInferTime) >= inferCooldownMs else { return }
        isInferencing = true
        lastInferTime = Date()

        let gen = generation
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
                self.finish(gen, [], 0, "CVPixelBuffer 创建失败"); return
            }
            let prepMs: Double
            if fastPathActive {
                let t0 = DispatchTime.now()
                guard Self.copyPixelBuffer(pixelBuffer, to: pb) else {
                    self.finish(gen, [], 0, "CVPixelBuffer 复制失败"); return
                }
                prepMs = Self.nsToMs(DispatchTime.now().uptimeNanoseconds - t0.rawValue)
            } else {
                let t0 = DispatchTime.now()
                Self.draw(from: pixelBuffer, into: pb, size: Self.inputSize)
                prepMs = Self.nsToMs(DispatchTime.now().uptimeNanoseconds - t0.rawValue)
            }
            do {
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: pb)])
                let out = try modelRef.prediction(from: input)
                guard let name = out.featureNames.first,
                      let arr = out.featureValue(for: name)?.multiArrayValue else {
                    self.finish(gen, [], 0, "输出缺失"); return
                }
                let inferenceMs = (try? Self.measureInferenceMs {
                    _ = try modelRef.prediction(from: input)
                }) ?? 0
                let latency = prepMs + inferenceMs
                let dets = Self.parse(arr, confidenceThreshold: self.confidenceThreshold,
                                      maxDetections: self.maxDetections)
                self.finish(gen, dets, latency, nil)
            } catch {
                self.finish(gen, [], prepMs, "推理失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 推理入口（CGImage 包装，tick 路径）
    // P3优化：从 CGImage → CVPixelBuffer 转换仅用于 tick 路径（非高频），
    // 高频路径走 infer(pixelBuffer:) 直接消费捕获回调。
    func infer(image cgImage: CGImage) {
        guard let pb = Self.makePixelBuffer(size: Self.inputSize) else { return }
        Self.draw(cgImage, into: pb, size: Self.inputSize)
        infer(pixelBuffer: pb)
    }

    private nonisolated static func measureInferenceMs(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now()
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0.rawValue) / 1_000_000
    }

    private nonisolated static func nsToMs(_ ns: UInt64) -> Double { Double(ns) / 1_000_000 }

    private func finish(_ gen: Int, _ dets: [Detection], _ latency: Double, _ error: String?) {
        guard gen == generation else { return }
        isInferencing = false
        if let error = error {
            errorMessage = error
        } else {
            Self.smoothInPlace(&lastFrame, newDets: dets, used: &smoothUsed)
            detections = lastFrame
            lastLatencyMs = latency
            inferenceCount += 1
            errorMessage = nil
            trackLock(with: detections)
        }
    }

    private nonisolated static func smoothInPlace(_ last: inout [Detection],
                                                  newDets: [Detection],
                                                  used: inout [Bool],
                                                  alpha: Double = 0.55) {
        guard !last.isEmpty, !newDets.isEmpty else {
            if last.isEmpty { last = newDets }
            return
        }
        // P9优化：确保 used 长度足够（首次调用时 smoothUsed 为空，避免越界）。
        if used.count < newDets.count { used = .init(repeating: false, count: newDets.count) }
        for i in 0..<newDets.count { used[i] = false }
        _smoothInPlaceCore(&last, newDets: newDets, used: &used, alpha: alpha)
    }

    private nonisolated static func _smoothInPlaceCore(_ last: inout [Detection],
                                                       newDets: [Detection],
                                                       used: inout [Bool],
                                                       alpha: Double) {
        var writeIdx = 0
        for l in last {
            var bestIdx = -1
            var bestIoU = 0.25
            for i in 0..<newDets.count where !used[i] {
                let v = iou(newDets[i], l)
                if v > bestIoU {
                    bestIoU = v
                    bestIdx = i
                }
            }
            if bestIdx >= 0 {
                used[bestIdx] = true
                let d = newDets[bestIdx]
                let ax = l.x + (d.x - l.x) * alpha
                let ay = l.y + (d.y - l.y) * alpha
                let aw = l.width + (d.width - l.width) * alpha
                let ah = l.height + (d.height - l.height) * alpha
                last[writeIdx] = Detection(x: ax, y: ay, width: aw, height: ah,
                                           label: d.label, confidence: d.confidence,
                                           rawName: d.rawName)
                writeIdx += 1
            } else {
                last[writeIdx] = l
                writeIdx += 1
            }
        }
        last.removeLast(last.count - writeIdx)
        for i in 0..<newDets.count where !used[i] {
            last.append(newDets[i])
        }
    }

    func reset() {
        generation += 1
        detections = []
        isInferencing = false
        lastLatencyMs = 0
        errorMessage = nil
        lastFrame = []
        clearLockInternal()
        fastPathActive = false
    }

    // MARK: - 锁定追踪控制（主线程调用）
    func setLock(x: Double, y: Double, width: Double, height: Double) {
        lockedTarget = Detection(x: x, y: y, width: width, height: height,
                                 label: .obstacle, confidence: 0,
                                 rawName: "LOCK")
        applyLock(message: "已锁定手动选框")
    }

    func setLock(to det: Detection) {
        lockedTarget = det
        applyLock(message: "已锁定 \(det.rawName)")
    }

    func clearLock() { clearLockInternal() }

    private func applyLock(message: String?) {
        isLocked = true
        lockLostFrames = 0
        lockMessage = message
    }

    private func clearLockInternal() {
        lockedTarget = nil
        isLocked = false
        lockLostFrames = 0
        lockMessage = nil
    }

    private func trackLock(with dets: [Detection]) {
        guard isLocked, let target = lockedTarget else { return }
        var best: Detection? = nil
        var bestScore = -0.35
        for d in dets {
            let iou = Self.iou(d, target)
            let dist = Self.centerDistance(d, target)
            let score = iou - dist * 0.4
            if score > bestScore {
                bestScore = score
                best = d
            }
        }

        if let m = best, bestScore > -0.25 {
            let alpha = 0.5
            let nx = target.x + (m.x - target.x) * alpha
            let ny = target.y + (m.y - target.y) * alpha
            let nw = target.width + (m.width - target.width) * alpha
            let nh = target.height + (m.height - target.height) * alpha
            lockedTarget = Detection(x: nx, y: ny, width: nw, height: nh,
                                     label: m.label,
                                     confidence: m.confidence,
                                     rawName: m.rawName)
            lockLostFrames = 0
        } else {
            lockLostFrames += 1
            if lockLostFrames > 15 {
                clearLockInternal()
                lockMessage = "目标丢失，锁定已解除"
            }
        }
    }

    private nonisolated static func centerDistance(_ a: Detection,
                                                   _ b: Detection) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - 自检（命令行 --yolo-selftest <图片路径>）
    private func rawDump(_ out: MLMultiArray) -> String {
        let n = out.shape.count >= 2 ? out.shape[1].intValue : 0
        var rr = ["原始输出行[0..12] (x1,y1,x2,y2,conf,class_id):"]
        for k in 0..<min(12, n) {
            let vals = (0..<6).map { Self.readML(out, [0, k, $0]) }
            rr.append(String(format: "  %2ld (%.3f,%.3f,%.3f,%.3f) conf=%.4f cls=%.0f",
                             k, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]))
        }
        return rr.joined(separator: "\n")
    }

    func selfTest(imagePath: String) -> String {
        loadIfNeeded()
        guard let modelRef = model else {
            return "✗ 模型加载失败: \(errorMessage ?? "未知")"
        }
        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "✗ 读图失败: \(imagePath)"
        }
        guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
            return "✗ CVPixelBuffer 创建失败"
        }
        Self.draw(cgImage, into: pb, size: Self.inputSize)
        Self.dumpPNG(pb, to: "/tmp/yolo_swift_input.png")

        do {
            let start = Date()
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
            let out = try modelRef.prediction(from: input)
            guard let name = out.featureNames.first,
                  let arr = out.featureValue(for: name)?.multiArrayValue else {
                return "✗ 输出缺失"
            }
            let kept = Self.parse(arr, confidenceThreshold: confidenceThreshold,
                                  maxDetections: maxDetections)
            let ms = Date().timeIntervalSince(start) * 1000

            var lines = ["图片: \(imagePath)  (\(Int(nsImage.size.width))×\(Int(nsImage.size.height)))",
                         "模型: \(Self.modelURL.lastPathComponent)",
                         String(format: "耗时: %.1f ms  阈值: %.2f", ms, confidenceThreshold),
                         "输出dtype: \(arr.dataType.rawValue)  shape=\(arr.shape.map(\.intValue))"]
            lines.append(self.rawDump(arr))
            lines.append("过阈值 \(kept.count) 个:")
            for d in kept {
                let flag = d.isInDangerZone() != .none ? "[危险区]" : ""
                lines.append(String(format: "  %-14@ %.3f  中心(%.3f,%.3f) 宽高(%.3f,%.3f) %@",
                                    d.rawName as NSString, d.confidence, d.x, d.y,
                                    d.width, d.height, flag as NSString))
            }
            return lines.joined(separator: "\n")
        } catch {
            return "✗ 推理失败: \(error.localizedDescription)"
        }
    }

    func benchmark(imagePath: String, iterations: Int = 30) -> String {
        loadIfNeeded()
        guard let modelRef = model else {
            return "✗ 模型加载失败: \(errorMessage ?? "未知")"
        }
        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "✗ 读图失败: \(imagePath)"
        }

        var lines = ["图片: \(imagePath)  (\(Int(nsImage.size.width))×\(Int(nsImage.size.height)))",
                     "迭代: \(iterations) 次/路径  模型: \(Self.modelURL.lastPathComponent)"]

        do {
            guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
                return "✗ CVPixelBuffer 创建失败"
            }
            var total = 0.0
            for _ in 0..<iterations {
                let start = Date()
                Self.draw(cgImage, into: pb, size: Self.inputSize)
                let input = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
                _ = try modelRef.prediction(from: input)
                total += Date().timeIntervalSince(start) * 1000
            }
            let avg = total / Double(iterations)
            lines.append(String(format: "慢路径(NSImage→CGImage→绘制→推理): %.1f ms/帧  ≈ %.0f FPS",
                                avg, 1000 / avg))
        } catch {
            lines.append("✗ 慢路径失败: \(error.localizedDescription)")
        }

        do {
            guard let src = Self.makePixelBuffer(size: Self.inputSize),
                  let pb = Self.makePixelBuffer(size: Self.inputSize) else {
                return "✗ CVPixelBuffer 创建失败"
            }
            Self.draw(cgImage, into: src, size: Self.inputSize)
            var total = 0.0
            for _ in 0..<iterations {
                let start = Date()
                _ = Self.copyPixelBuffer(src, to: pb)
                let input = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
                _ = try modelRef.prediction(from: input)
                total += Date().timeIntervalSince(start) * 1000
            }
            let avg = total / Double(iterations)
            lines.append(String(format: "直通路径(352缓冲+memcpy+推理): %.1f ms/帧  ≈ %.0f FPS",
                                avg, 1000 / avg))
        } catch {
            lines.append("✗ 直通路径失败: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 像素缓冲（nonisolated，纯函数）
    private nonisolated static func makePixelBuffer(size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    private nonisolated static func dumpPNG(_ pb: CVPixelBuffer, to path: String) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        guard let cg = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private nonisolated static func copyPixelBuffer(_ src: CVPixelBuffer,
                                                    to dst: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(src, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(src, [.readOnly]) }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return false }
        let srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src)
        let dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst)
        let srcBpr = CVPixelBufferGetBytesPerRow(src)
        let dstBpr = CVPixelBufferGetBytesPerRow(dst)
        let copyH = min(srcH, dstH), copyWBytes = min(srcBpr, dstBpr)
        for y in 0..<copyH {
            let s = srcBase.advanced(by: y * srcBpr)
            let d = dstBase.advanced(by: y * dstBpr)
            memcpy(d, s, copyWBytes)
        }
        return true
    }

    private nonisolated static func draw(_ cgImage: CGImage,
                                         into pb: CVPixelBuffer,
                                         size: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: size, height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private nonisolated static func draw(from src: CVPixelBuffer,
                                         into dst: CVPixelBuffer,
                                         size: Int) {
        CVPixelBufferLockBaseAddress(src, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(src, [.readOnly]) }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }
        let srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src)
        let srcBpr = CVPixelBufferGetBytesPerRow(src)
        let dstBpr = CVPixelBufferGetBytesPerRow(dst)
        let scaleW = Double(size) / Double(srcW)
        let scaleH = Double(size) / Double(srcH)

        for y in 0..<size {
            let sy = Int(Double(y) / scaleH)
            let sBase = srcBase + sy * srcBpr
            let dBase = dstBase + y * dstBpr
            let pxPerDst = Float(srcW) / Float(size)
            for x in 0..<size {
                let sx = Int(Float(x) * pxPerDst)
                let sp = sBase + sx * 4
                let dp = dBase + x * 4
                let spPtr = sp.assumingMemoryBound(to: UInt8.self)
                let dpPtr = dp.assumingMemoryBound(to: UInt8.self)
                dpPtr[0] = spPtr[0]; dpPtr[1] = spPtr[1]; dpPtr[2] = spPtr[2]; dpPtr[3] = spPtr[3]
            }
        }
    }

    // MARK: - 输出解析（nonisolated，纯函数）
    // P3优化：原 readML 每次调用通过 .map 分配 [NSNumber] 数组。
    // 改用 MLMultiArray 数据指针直接读取，零分配。
    // 输出形状 [1, n, 6]，每行 6 个 Float32，row i 偏移 i*6。
    private nonisolated static func readML(_ m: MLMultiArray, _ index: [Int]) -> Double {
        let ptr = m.dataPointer.bindMemory(to: Float32.self, capacity: m.count)
        let col = index.count >= 3 ? index[2] : (index.count >= 2 ? index[1] : 0)
        let row = index.count >= 2 ? index[1] : 0
        return Double(ptr[row * 6 + col])
    }

    private nonisolated static func parse(_ out: MLMultiArray,
                                          confidenceThreshold: Double,
                                          maxDetections: Int) -> [Detection] {
        let n = out.shape.count >= 2 ? out.shape[1].intValue : 0
        let invSize = 1.0 / 640.0
        var dets: [Detection] = []
        dets.reserveCapacity(min(maxDetections, n))

        for i in 0..<n {
            let conf = Self.readML(out, [0, i, 4])
            guard conf.isFinite, conf > confidenceThreshold else { continue }

            let x1 = Self.readML(out, [0, i, 0]) * invSize
            let y1 = Self.readML(out, [0, i, 1]) * invSize
            let x2 = Self.readML(out, [0, i, 2]) * invSize
            let y2 = Self.readML(out, [0, i, 3]) * invSize
            guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { continue }
            let w = x2 - x1, h = y2 - y1
            guard w > 0.001, h > 0.001 else { continue }

            let clsRaw = Self.readML(out, [0, i, 5])
            guard clsRaw.isFinite else { continue }
            let clsIdx = Int(min(max(clsRaw.rounded(), 0), Double(CocoLabels.names.count - 1)))
            let (label, name) = CocoLabels.map(clsIdx)

            dets.append(Detection(x: (x1 + x2) / 2,
                                  y: (y1 + y2) / 2,
                                  width: w,
                                  height: h,
                                  label: label,
                                  confidence: conf,
                                  rawName: name))
        }
        if dets.count > maxDetections { dets.removeSubrange(maxDetections..<dets.count) }
        return dets
    }

    private nonisolated static func iou(_ a: Detection, _ b: Detection) -> Double {
        let ax1 = a.x - a.width / 2, ax2 = a.x + a.width / 2
        let ay1 = a.y - a.height / 2, ay2 = a.y + a.height / 2
        let bx1 = b.x - b.width / 2, bx2 = b.x + b.width / 2
        let by1 = b.y - b.height / 2, by2 = b.y + b.height / 2

        let iw = max(0, min(ax2, bx2) - max(ax1, bx1))
        let ih = max(0, min(ay2, by2) - max(ay1, by1))
        let inter = iw * ih
        guard inter > 0 else { return 0 }
        let areaA = a.width * a.height, areaB = b.width * b.height
        let union = areaA + areaB - inter
        return inter / union
    }
}
