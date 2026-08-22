// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreImage
import Foundation
import Observation

@Observable
final class ConfidenceEstimator {

    // MARK: - 可调权重

    var consistencyWeight: Double = 0.5
    var extremityWeight: Double = 0.3
    var imageWeight: Double = 0.2
    var windowSize: Int = 20
    var extremeThreshold: Double = 0.95
    var extremeRatioThreshold: Double = 0.7
    var brightnessMin: Double = 0.08
    var brightnessMax: Double = 0.95

    // MARK: - 状态输出

    private(set) var confidence: Double = 1.0

    private(set) var consistencyScore: Double = 1.0
    private(set) var extremityScore: Double = 1.0
    private(set) var imageScore: Double = 1.0

    // MARK: - 内部状态

    private struct Sample {
        let steer: Double
    }
    // P3优化：预分配容量，避免 ring buffer 填充期的多次 Array 重分配。
    // windowSize 固定 20、longExtremeWindow 固定 90，reserveCapacity 一次到位。
    private var steerBuf: [Sample] = []
    private var steerHead: Int = 0
    private var steerSum: Double = 0          // 增量维护：steerBuf 总和
    private var steerSumSq: Double = 0        // 增量维护：steerBuf 平方和
    private var extremeBuf: [Bool] = []
    private var extremeHead: Int = 0
    private var extremeCount: Int = 0         // 增量维护：extremeBuf 中 true 的计数
    private var longExtremeBuf: [Bool] = []
    private var longExtremeHead: Int = 0
    private var longExtremeCount: Int = 0     // 增量维护：longExtremeBuf 中 true 的计数
    var longExtremeWindow: Int = 90
    var longExtremeRatioThreshold: Double = 0.7

    // MARK: - 构造器

    init() {
        steerBuf.reserveCapacity(20)
        extremeBuf.reserveCapacity(20)
        longExtremeBuf.reserveCapacity(90)
    }

    // MARK: - 主入口

    func update(command: ControlCommand, image: CGImage?, isLive: Bool) {
        guard isLive else {
            confidence = 0
            consistencyScore = 0
            extremityScore = 0
            imageScore = 0
            return
        }

        let isExtreme = abs(command.steer) > extremeThreshold

        // 增量维护环形缓冲区：老值出、新值入，保持 sum/sumSq/count 一致。
        Self.appendRingSteer(&steerBuf, head: &steerHead, value: command.steer, cap: windowSize,
                             sum: &steerSum, sumSq: &steerSumSq)
        Self.appendRingBool(&extremeBuf, head: &extremeHead, value: isExtreme, cap: windowSize,
                            count: &extremeCount)
        Self.appendRingBool(&longExtremeBuf, head: &longExtremeHead, value: isExtreme, cap: longExtremeWindow,
                            count: &longExtremeCount)

        consistencyScore = computeConsistency()
        extremityScore = computeExtremity()
        imageScore = computeImageScore(image)

        let total = consistencyWeight + extremityWeight + imageWeight
        confidence = (consistencyScore * consistencyWeight
                      + extremityScore * extremityWeight
                      + imageScore * imageWeight) / max(total, 1e-6)

        if longExtremeCount > 0 {
            let longRatio = Double(longExtremeCount) / Double(longExtremeBuf.count)
            if longRatio > longExtremeRatioThreshold {
                confidence = min(confidence, 0.30)
            }
        }
        confidence = max(0, min(1, confidence))
    }

    func reset() {
        steerHead = 0; steerBuf.removeAll(); steerBuf.reserveCapacity(windowSize)
        steerSum = 0; steerSumSq = 0
        extremeHead = 0; extremeBuf.removeAll(); extremeBuf.reserveCapacity(windowSize)
        extremeCount = 0
        longExtremeHead = 0; longExtremeBuf.removeAll(); longExtremeBuf.reserveCapacity(longExtremeWindow)
        longExtremeCount = 0
        confidence = 1.0
        consistencyScore = 1.0
        extremityScore = 1.0
        imageScore = 1.0
    }

    // MARK: - 环形缓冲区工具

    // 通用环形缓冲区写入：填充期 append，满后覆盖 head 位置并循环。
    private static func appendRing<T>(_ buf: inout [T], head: inout Int, value: T, cap: Int) {
        if buf.count < cap {
            buf.append(value)
        } else {
            buf[head] = value
            head += 1
            if head == cap { head = 0 }
        }
    }

    // 增量维护 steer ring buffer：写入前减去被覆盖值，写入后加上新值。
    // O(1) 替代原来的 O(n) 全量 scanRingSum，steerSum/steerSumSq 始终保持一致。
    private static func appendRingSteer(_ buf: inout [Sample], head: inout Int, value: Double,
                                        cap: Int, sum: inout Double, sumSq: inout Double) {
        if buf.count < cap {
            buf.append(Sample(steer: value))
            sum += value; sumSq += value * value
        } else {
            let old = buf[head].steer
            buf[head] = Sample(steer: value)
            sum += value - old
            sumSq += value * value - old * old
            head += 1
            if head == cap { head = 0 }
        }
    }

    // 增量维护 Bool ring buffer：用 extremeCount 跟踪 true 的个数，O(1)。
    private static func appendRingBool(_ buf: inout [Bool], head: inout Int, value: Bool,
                                       cap: Int, count: inout Int) {
        if buf.count < cap {
            buf.append(value)
            if value { count += 1 }
        } else {
            if buf[head] { count -= 1 }
            buf[head] = value
            if value { count += 1 }
            head += 1
            if head == cap { head = 0 }
        }
    }

    // MARK: - 子分计算

    // P11优化：O(1) 版本，用增量维护的 steerSum/steerSumSq 替代全量遍历。
    // 原实现每次遍历 steerBuf（最多20个Sample），现在是纯算术运算。
    private func computeConsistency() -> Double {
        guard steerBuf.count >= 3 else { return 0.8 }
        let n = Double(steerBuf.count)
        let mean = steerSum / n
        let variance = steerSumSq / n - mean * mean
        let std = sqrt(max(0, variance))
        return max(0, min(1, 1.0 - std * 2.0))
    }

    // P11优化：O(1) 版本，用增量维护的 extremeCount 替代 scanRingSum 遍历。
    private func computeExtremity() -> Double {
        guard !extremeBuf.isEmpty else { return 1.0 }
        let extremeRatio = Double(extremeCount) / Double(extremeBuf.count)
        if extremeRatio <= extremeRatioThreshold { return 1.0 }
        let denom = 1.0 - extremeRatioThreshold
        guard denom > 0 else { return 0 }
        return max(0, 1.0 - (extremeRatio - extremeRatioThreshold) / denom)
    }

    private func computeImageScore(_ image: CGImage?) -> Double {
        guard let image = image else {
            imageScore = 0.5
            return imageScore
        }
        let minB = brightnessMin
        let maxB = brightnessMax
        guard !brightnessInFlight else { return imageScore }
        brightnessInFlight = true
        Self.brightnessQueue.async { [weak self] in
            let brightness = Self.averageBrightness(cgImage: image)
            let score: Double = (brightness < minB || brightness > maxB) ? 0.1 : 1.0
            Task { @MainActor in
                // P1修复：defer清in-flight标志，防异常/提前返回导致brightnessInFlight永久true卡死
                defer { self?.brightnessInFlight = false }
                self?.imageScore = score
            }
        }
        return imageScore
    }

    @ObservationIgnored
    private var brightnessInFlight = false
    private static let brightnessQueue = DispatchQueue(
        label: "com.aurora.confidence.brightness", qos: .userInitiated)
    private static let brightnessContext = CIContext(options: [.cacheIntermediates: false])
    private nonisolated static let inv255d: Double = 1.0 / 255.0

    private static func averageBrightness(cgImage: CGImage) -> Double {
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.5 }

        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { raw in
            brightnessContext.render(output,
                                     toBitmap: raw.baseAddress!,
                                     rowBytes: 4,
                                     bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     format: .RGBA8,
                                     colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let r = Double(pixel[0]) * Self.inv255d
        let g = Double(pixel[1]) * Self.inv255d
        let b = Double(pixel[2]) * Self.inv255d
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
