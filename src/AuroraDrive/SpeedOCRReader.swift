// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class SpeedOCRReader {

    // MARK: - 槽位常量

    nonisolated(unsafe) static var slotCentersNorm: [CGFloat] = [0.600, 0.660, 0.720]
    nonisolated(unsafe) static var slotWidthNorm: CGFloat = 0.020
    nonisolated(unsafe) static var slotYMinNorm: CGFloat = 0.800
    nonisolated(unsafe) static var slotYMaxNorm: CGFloat = 0.880
    nonisolated static let templateHeight: Int = 45
    nonisolated static let templateWidth: Int = 25

    // MARK: - 节流 / 范围 / 校验常量

    nonisolated static let inferInterval: TimeInterval = 1.0 / 30.0
    nonisolated static let speedRange: ClosedRange<Double> = 0.0...400.0
    nonisolated static let minSpeed: Int = 0
    nonisolated static let maxSpeed: Int = 300
    nonisolated static let minValidForegroundPixels: Int = 80
    nonisolated static let maxJumpKmh: Double = 60.0
    nonisolated static let confirmCount: Int = 3
    nonisolated static let confirmWindowSec: TimeInterval = 1.0
    nonisolated static let confirmToleranceKmh: Int = 2
    nonisolated static var minConfirmAgreement: Int { confirmCount / 2 + 1 }
    nonisolated static let maxSlotResidualRatio: Double = 0.30

    // MARK: - 状态输出（主线程读）

    private(set) var speedKmh: Double = -1
    private(set) var confidence: Double = 0
    private(set) var isInferencing = false
    private(set) var errorMessage: String?
    private(set) var lastResultTime: Date?
    private(set) var loadedGlyphs: [String: [UInt8]] = [:]

    @ObservationIgnored
    private(set) var lastOCRDiagnostic: String = ""

    @ObservationIgnored
    private(set) var lastNativeSize: CGSize = .zero

    // MARK: - 内部状态

    private final class NativeFrameBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }

    @ObservationIgnored
    private let ocrQueue = DispatchQueue(label: "com.aurora.speedocr",
                                         qos: .userInteractive)

    @ObservationIgnored
    private var generation = 0

    @ObservationIgnored private var lastInferTime: Date?
    @ObservationIgnored private var lastDebugWriteTime: Date?
    @ObservationIgnored private var lastValidSpeed: Double?

    @ObservationIgnored private var candidates: [(speed: Int, time: Date)] = []

    // MARK: - 初始化

    init() { loadGlyphsSync() }

    private func loadGlyphsSync() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("models/speed_glyphs.json")
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(SpeedGlyphLibrary.self, from: data),
              lib.version == 1,
              lib.templateHeight == Self.templateHeight,
              lib.templateWidth == Self.templateWidth else { return }
        var out: [String: [UInt8]] = [:]
        for (k, rows) in lib.templates {
            var flat = [UInt8](repeating: 0, count: Self.templateHeight * Self.templateWidth)
            var i = 0
            for row in rows where i < flat.count {
                for v in row { if i < flat.count { flat[i] = v == 0 ? 0 : 1 }; i += 1 }
            }
            if i == flat.count { out[k] = flat }
        }
        loadedGlyphs = out
    }

    func reloadGlyphs() { loadGlyphsSync() }

    // MARK: - 推理入口（主线程）

    func infer(nativePixelBuffer: CVPixelBuffer) {
        lastNativeSize = CGSize(width: CVPixelBufferGetWidth(nativePixelBuffer),
                                height: CVPixelBufferGetHeight(nativePixelBuffer))

        guard lastInferTime == nil
                || Date().timeIntervalSince(lastInferTime!) >= Self.inferInterval
        else { return }
        guard !isInferencing else { return }
        guard !loadedGlyphs.isEmpty else {
            lastOCRDiagnostic = "字模未加载"; return
        }

        lastInferTime = Date()
        let gen = generation
        let glyphsSnapshot = loadedGlyphs
        let roiNorm = CaptureEngine.speedROINorm
        let frame = NativeFrameBox(nativePixelBuffer)
        isInferencing = true
        ocrQueue.async { [weak self] in
            guard let self else { return }
            guard let slotImages = Self.cropSlots(from: frame.buffer, roiNorm: roiNorm) else {
                if self.lastDebugWriteTime == nil
                    || Date().timeIntervalSince(self.lastDebugWriteTime!) >= 1.0 {
                    self.lastDebugWriteTime = Date()
                    Self.saveOCRDebug(buffer: frame.buffer, slots: [], fg: 0)
                }
                Task { @MainActor in self.finish(gen, RecognitionResult(diag: "槽位裁剪失败")) }
                return
            }

            let result = Self.recognize(slotImages: slotImages, glyphs: glyphsSnapshot)
            if result.speed == nil {
                if self.lastDebugWriteTime == nil
                    || Date().timeIntervalSince(self.lastDebugWriteTime!) >= 1.0 {
                    self.lastDebugWriteTime = Date()
                    Self.saveOCRDebug(buffer: frame.buffer, slots: slotImages, fg: result.fgTotal)
                }
            }
            Task { @MainActor in self.finish(gen, result) }
        }
    }

    private func finish(_ gen: Int, _ result: RecognitionResult) {
        guard gen == generation else { return }
        isInferencing = false
        if let error = result.error { errorMessage = error; return }
        guard let speed = result.speed, result.unknownSlots.isEmpty else {
            lastOCRDiagnostic = result.diag ?? "无法识别"; return
        }
        lastOCRDiagnostic = ""
        guard Self.speedRange.contains(Double(speed)) else {
            errorMessage = "out of range \(speed)"; return
        }
        if let last = lastValidSpeed, abs(Double(speed) - last) > Self.maxJumpKmh {
            errorMessage = "jump too large \(last)→\(speed)"; confidence = 0; return
        }
        let now = Date()
        candidates.append((speed, now))
        let windowStart = now.addingTimeInterval(-Self.confirmWindowSec)
        candidates.removeAll { $0.time < windowStart }
        guard let confirmed = Self.confirmedSpeed(
            in: candidates.suffix(Self.confirmCount),
            tolerance: Self.confirmToleranceKmh,
            minAgreement: Self.minConfirmAgreement
        ) else { return }
        speedKmh = Double(confirmed)
        confidence = result.confidence
        lastValidSpeed = Double(confirmed)
        lastResultTime = now
        errorMessage = nil
    }

    private static func confirmedSpeed<S: Sequence>(
        in list: S,
        tolerance: Int,
        minAgreement: Int
    ) -> Int? where S.Element == (speed: Int, time: Date) {
        var iterator = list.makeIterator()
        guard let first = iterator.next() else { return nil }
        var bestSpeed = first.speed, bestCount = 0, bestTime = first.time
        for item in list {
            var count = 0
            for other in list where abs(other.speed - item.speed) <= tolerance { count += 1 }
            if count > bestCount || (count == bestCount && item.time > bestTime) {
                bestCount = count; bestSpeed = item.speed; bestTime = item.time
            }
        }
        guard bestCount >= minAgreement else { return nil }
        return bestSpeed
    }

    func reset() {
        generation += 1
        speedKmh = -1; confidence = 0; isInferencing = false
        errorMessage = nil; lastResultTime = nil; lastInferTime = nil
        lastValidSpeed = nil; lastOCRDiagnostic = ""
        candidates.removeAll(keepingCapacity: true)
    }

    nonisolated static func cropSlots(from src: CVPixelBuffer, roiNorm: CGRect? = nil) -> [CGImage]? {
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }
        let input = CIImage(cvPixelBuffer: src)
        var out: [CGImage] = []
        out.reserveCapacity(slotCentersNorm.count)
        for ci in 0..<slotCentersNorm.count {
            var cxNorm = slotCentersNorm[ci]
            var halfWNorm = slotWidthNorm / 2.0
            var yMinNorm = slotYMinNorm
            var yMaxNorm = slotYMaxNorm
            if let roi = roiNorm {
                cxNorm = (cxNorm - roi.origin.x) / roi.width
                halfWNorm = halfWNorm / roi.width
                yMinNorm = (yMinNorm - roi.origin.y) / roi.height
                yMaxNorm = (yMaxNorm - roi.origin.y) / roi.height
            }
            let xCenter = (cxNorm * CGFloat(sw)).rounded(.toNearestOrEven)
            let halfW = (halfWNorm * CGFloat(sw)).rounded(.toNearestOrEven)
            let yMin = (yMinNorm * CGFloat(sh)).rounded(.toNearestOrEven)
            let yMax = (yMaxNorm * CGFloat(sh)).rounded(.toNearestOrEven)
            let ciRect = CGRect(x: xCenter - halfW, y: CGFloat(sh) - yMax,
                                width: halfW * 2.0, height: yMax - yMin)
            guard ciRect.minX >= 0, ciRect.minY >= 0,
                  ciRect.maxX <= CGFloat(sw), ciRect.maxY <= CGFloat(sh),
                  ciRect.width > 0, ciRect.height > 0 else { return nil }
            let cropped = input.cropped(to: ciRect)
            guard let cg = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
            out.append(cg)
        }
        return out
    }

    private nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - 模板匹配（nonisolated 纯函数）

    private struct RecognitionResult {
        var speed: Int?
        var unknownSlots: [Int] = []
        var confidence: Double = 0
        var diag: String?
        var fgTotal: Int = 0
        var error: String?
    }

    nonisolated private static func recognize(
        slotImages: [CGImage], glyphs: [String: [UInt8]]
    ) -> RecognitionResult {
        var slotBinaries: [[UInt8]] = []
        slotBinaries.reserveCapacity(slotImages.count)
        var fgTotal = 0
        for (idx, cg) in slotImages.enumerated() {
            guard cg.width > 0, cg.height > 0,
                  let gray = grayscalePixels(cgImage: cg) else {
                return RecognitionResult(error: "grayscale failed slot \(idx)")
            }
            let binaryResized = resizeNearest(src: binarizeOtsu(gray: gray),
                                              srcH: cg.height, srcW: cg.width,
                                              dstH: templateHeight, dstW: templateWidth)
            fgTotal += binaryResized.reduce(0) { $0 + Int($1) }
            slotBinaries.append(binaryResized)
        }
        guard fgTotal >= minValidForegroundPixels else {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "fg=\(fgTotal) 过低(画面无速度表)", fgTotal: fgTotal)
        }
        guard let (speed, dist) = matchSpeed(slotBinaries: slotBinaries, glyphs: glyphs) else {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "残差超阈值(3槽前景=\(fgTotal))")
        }
        let area = Double(templateHeight * templateWidth * slotImages.count)
        return RecognitionResult(speed: speed, unknownSlots: [],
                                 confidence: max(0, min(1, 1.0 - dist / area)))
    }

    nonisolated private static func matchSpeed(
        slotBinaries: [[UInt8]], glyphs: [String: [UInt8]]
    ) -> (speed: Int, dist: Double)? {
        let h = templateHeight; let w = templateWidth
        guard slotBinaries.count == 3 else { return nil }
        var cost = [Double](repeating: .infinity, count: 30)
        for si in 0..<3 {
            let slotBinary = slotBinaries[si]
            for d in 0...9 {
                guard let tmpl = glyphs[String(d)] else { continue }
                var localMin = Double.infinity
                for dy in -1...1 { for dx in -1...1 {
                    let r = residualShifted(binary: slotBinary, tmpl: tmpl, h: h, w: w, dy: dy, dx: dx)
                    if Double(r) < localMin { localMin = Double(r) }
                }}
                cost[si * 10 + d] = localMin
            }
        }
        var bestSpeed = minSpeed; var bestDist = Double.infinity
        for v in minSpeed...maxSpeed {
            let dist = cost[v / 100] + cost[10 + (v / 10) % 10] + cost[20 + v % 10]
            if dist < bestDist { bestDist = dist; bestSpeed = v }
        }
        guard bestDist <= maxSlotResidualRatio * Double(h * w * 3) else { return nil }
        return (bestSpeed, bestDist)
    }

    nonisolated private static func residualShifted(
        binary: [UInt8], tmpl: [UInt8], h: Int, w: Int, dy: Int, dx: Int
    ) -> Int {
        let r0 = max(0, -dy), r1 = min(h, h - dy)
        let c0 = max(0, -dx), c1 = min(w, w - dx)
        guard r1 > r0, c1 > c0 else { return h * w }
        var diff = 0
        let colCount = c1 - c0
        for r in r0..<r1 {
            let br = r * w + c0; let tr = (r + dy) * w + c0 + dx
            for k in 0..<colCount { if binary[br + k] != tmpl[tr + k] { diff += 1 } }
        }
        return diff
    }

    // MARK: - 图像处理（nonisolated 纯函数）

    nonisolated private static func grayscalePixels(cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width; let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    nonisolated private static func binarizeOtsu(gray: [UInt8]) -> [UInt8] {
        var hist = [Int](repeating: 0, count: 256)
        for v in gray { hist[Int(v)] += 1 }
        let total = gray.count; guard total > 0 else { return [] }
        guard hist.contains(where: { $0 > 0 }) &&
              hist.filter({ $0 > 0 }).count >= 2 else {
            return [UInt8](repeating: 0, count: total)
        }
        var sumAll: Double = 0
        for i in 0..<256 { sumAll += Double(i) * Double(hist[i]) }
        var sumB: Double = 0; var wB: Int = 0; var varMax: Double = -1; var thr = 0
        for t in 0..<256 {
            wB += hist[t]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(t) * Double(hist[t])
            let mB = sumB / Double(wB); let mF = (sumAll - sumB) / Double(wF)
            let v = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if v > varMax { varMax = v; thr = t }
        }
        var out = [UInt8](repeating: 0, count: total)
        for i in 0..<total { out[i] = gray[i] > thr ? 1 : 0 }
        return out
    }

    nonisolated private static func resizeNearest(
        src: [UInt8], srcH: Int, srcW: Int, dstH: Int, dstW: Int
    ) -> [UInt8] {
        guard srcH > 0, srcW > 0, dstH > 0, dstW > 0, src.count == srcH * srcW else { return [] }
        var out = [UInt8](repeating: 0, count: dstH * dstW)
        for y in 0..<dstH {
            let srcY = nearestSourceIndex(y, srcN: srcH, dstN: dstH)
            for x in 0..<dstW {
                out[y * dstW + x] = src[srcY * srcW + nearestSourceIndex(x, srcN: srcW, dstN: dstW)]
            }
        }
        return out
    }

    private nonisolated static func nearestSourceIndex(_ i: Int, srcN: Int, dstN: Int) -> Int {
        guard dstN > 1, srcN > 1 else { return 0 }
        guard i != 0, i != dstN - 1 else { return i == 0 ? 0 : srcN - 1 }
        return Int(Double(i) * Double(srcN - 1) / Double(dstN - 1))
    }

    // MARK: - 调试存盘

    nonisolated private static func saveOCRDebug(buffer: CVPixelBuffer, slots: [CGImage], fg: Int) {
        let sw = CVPixelBufferGetWidth(buffer); let sh = CVPixelBufferGetHeight(buffer)
        let input = CIImage(cvPixelBuffer: buffer)
        let scale = min(1.0, 800.0 / Double(max(sw, sh)))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ciContext.createCGImage(small, from: small.extent) {
            writePNG(cg, to: "/tmp/aurora_ocr_dbg_full.png")
        }
        for (i, cg) in slots.enumerated() { writePNG(cg, to: "/tmp/aurora_ocr_dbg_slot\(i).png") }
        try? "fg=\(fg)  native=\(sw)x\(sh)\n".write(
            to: URL(fileURLWithPath: "/tmp/aurora_ocr_dbg.txt"),
            atomically: true, encoding: .utf8)
    }

    nonisolated private static func writePNG(_ cg: CGImage, to path: String) {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - 自检（命令行 --speed-selftest <目录>）

    @MainActor
    func selfTestDirectory(_ dirPath: String, roiNorm: CGRect? = nil) -> String {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: dirPath)
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: nil) else {
            return "✗ 无法列目录: \(dirPath)"
        }
        let images = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "png" || ext == "jpg" || ext == "jpeg"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if images.isEmpty {
            return "✗ 目录里没有 PNG/JPG: \(dirPath)"
        }
        if loadedGlyphs.isEmpty {
            return "✗ 字模库为空：未找到 models/speed_glyphs.json 或模板尺寸不匹配"
        }

        var lines: [String] = []
        lines.append("== SpeedOCRReader 自检 ==")
        lines.append("目录: \(dirPath)")
        lines.append("字模: \(loadedGlyphs.keys.sorted().joined(separator: ", "))")
        lines.append("槽位: x=\(Self.slotCentersNorm) w=\(Self.slotWidthNorm) y=[\(Self.slotYMinNorm),\(Self.slotYMaxNorm)]")
        lines.append("帧数: \(images.count)")
        lines.append("")

        var passCount = 0
        var failCount = 0
        let glyphsSnapshot = loadedGlyphs
        for url in images {
            let name = url.lastPathComponent
            guard let cg = Self.loadCGImage(from: url) else {
                lines.append("  [skip] \(name): 读图失败")
                failCount += 1
                continue
            }
            guard let pb = Self.makeBGRABuffer(from: cg) else {
                lines.append("  [skip] \(name): 像素缓冲创建失败")
                failCount += 1
                continue
            }
            guard let slots = Self.cropSlots(from: pb, roiNorm: roiNorm) else {
                lines.append("  [skip] \(name): 槽位裁剪失败")
                failCount += 1
                continue
            }
            let result = Self.recognize(slotImages: slots, glyphs: glyphsSnapshot)
            if let err = result.error {
                lines.append("  [FAIL] \(name): \(err)")
                failCount += 1
                continue
            }
            guard let speed = result.speed else {
                lines.append("  [FAIL] \(name): 无法识别 \(result.unknownSlots)")
                failCount += 1
                continue
            }
            let speedStr = String(format: "%03ld", speed)
            let isExpected = (Self.minSpeed...Self.maxSpeed).contains(speed)
            let mark = isExpected ? "✓" : "✗"
            lines.append(String(format: "  [\(mark)] %@: speed=%@ conf=%.3f",
                               name, speedStr, result.confidence))
            if isExpected { passCount += 1 } else { failCount += 1 }
        }

        lines.append("")
        lines.append("汇总: \(passCount)/\(images.count) 通过, \(failCount) 失败")
        return lines.joined(separator: "\n")
    }

    private nonisolated static func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return cg
    }

    private nonisolated static func makeBGRABuffer(from cg: CGImage) -> CVPixelBuffer? {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         w, h,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}

// MARK: - 字模库 JSON 解码模型

private struct SpeedGlyphLibrary: Decodable {
    let version: Int
    let templateWidth: Int
    let templateHeight: Int
    let slotCentersNorm: [Double]
    let slotWidthNorm: Double
    let slotYMinNorm: Double
    let slotYMaxNorm: Double
    let templates: [String: [[Int]]]

    private enum CodingKeys: String, CodingKey {
        case version, templates
        case templateWidth = "template_width"
        case templateHeight = "template_height"
        case slotCentersNorm = "slot_centers_norm"
        case slotWidthNorm = "slot_width_norm"
        case slotYMinNorm = "slot_y_min_norm"
        case slotYMaxNorm = "slot_y_max_norm"
    }
}
