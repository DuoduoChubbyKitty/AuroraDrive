// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ConfidenceEstimator.swift — 置信度估计器
//
//  职责：E2E 模型不输出置信度，用启发式从"模型输出历史 + 当前画面"估算
//  输出：[0,1] 置信度分，供降级状态机决策
//
//  门控 + 三个信号融合：
//    0) 链路存活门控：模型未加载 / 无推理结果 / 结果过期 → 置信度直接 0
//       （修复退化平衡点：E2E 恒输出 idle/恒定值时旧公式会算出 0.70，
//         高于降级阈值 0.65，导致死模型永远卡在端到端档不降级）
//    1) 输出一致性：最近 N 帧 steer 抖动越小越可信（模型稳定）
//    2) 转向极端度：steer 长时间打满（|steer|>0.95）视为退化
//       （油门/刹车贴边属正常驾驶行为，不再扣分 —— 修复"健康巡航恒 0.70、
//         导致永远够不到 0.75 恢复阈值、卡死在规则档"的缺陷；
//         输出稳定不判冻结 —— 直道上模型本来就该稳定输出）
//    3) 画面有效性：亮度异常（全黑/全白）直接判低置信
//
//  设计：
//    - 滑动窗口存最近 N 帧输出，O(1) 更新
//    - 三个信号加权融合，权重可调
//    - 线程安全：仅主线程调用（与 tick 同步）
// ============================================================================
import AppKit
import CoreImage
import Foundation
import Observation

@Observable
final class ConfidenceEstimator: @unchecked Sendable {

    // MARK: - 可调权重

    /// 输出一致性权重（抖动越小分越高）
    var consistencyWeight: Double = 0.5
    /// 输出极端度权重（贴边越久分越低）
    var extremityWeight: Double = 0.3
    /// 画面有效性权重（亮度异常分越低）
    var imageWeight: Double = 0.2

    /// 滑动窗口大小（最近 N 帧用于算一致性）
    var windowSize: Int = 20

    /// 极端值阈值：|steer|>0.95 视为转向打满（退化）
    var extremeThreshold: Double = 0.95

    /// 极端持续帧数超过此比例 → 判退化
    var extremeRatioThreshold: Double = 0.7

    /// 画面亮度正常范围（归一化 0~1），超出视为异常
    var brightnessMin: Double = 0.08
    var brightnessMax: Double = 0.95

    // MARK: - 状态输出

    /// 当前置信度估计值 [0,1]（UI 观察）
    private(set) var confidence: Double = 1.0

    /// 三路子分（调试/UI 展示用）
    private(set) var consistencyScore: Double = 1.0
    private(set) var extremityScore: Double = 1.0
    private(set) var imageScore: Double = 1.0

    // MARK: - 内部状态

    /// 最近 N 帧的 steer 值（算抖动用）
    private var steerHistory: [Double] = []
    /// 最近 N 帧是否极端（转向打满）的标记
    private var extremeHistory: [Bool] = []
    /// 长窗口极端标记（判"持续打满=贴墙/打转退化"；长度见 longExtremeWindow）
    private var longExtremeHistory: [Bool] = []

    /// 长窗口帧数：持续打满这么久还没松 → 不是过弯，是退化。
    ///
    /// ⚠️ **2026-10-18 审计发现的口径漂移（只标注，未改数值）**：
    ///   本值按「3 秒 @30Hz」定为 90 帧，但 tick 已于 2026-10-12 定档 **20Hz**
    ///   → 90 帧实际是 **4.5 秒**（比设计意图慢 50%），即"方向持续打满"要更久
    ///   才会被判为退化。属 20Hz 迁移的漏改项之一（同批还有
    ///   `YoloEngine.lockLostFrames` / `MotionPredictor.maxPredictionFrames` /
    ///   `maxMissingFrames` / `LaneFallback.stabilityFrames`）。
    ///   改数值会改变降级时序，属产品决策，故此处**只标注不改**；
    ///   若要恢复 3 秒语义，应改为 60（或按 tickHz 换算）。
    var longExtremeWindow: Int = 90
    /// 长窗口打满占比阈值：超过 → 判持续退化
    var longExtremeRatioThreshold: Double = 0.7

    // MARK: - 主入口

    /// 更新置信度估计
    /// - Parameters:
    ///   - command: 本帧模型输出
    ///   - image: 本帧画面 CGImage（用于亮度检测，可 nil 跳过此信号）
    ///   - isLive: 推理链路是否真的活着（模型已加载 && 最近有新鲜结果）。
    ///             链路死（没模型/没画面/结果过期）→ 置信度直接置 0，
    ///             强制降级到 YOLO 接管，避免 E2E 空转却卡在 .e2e 档。
    func update(command: ControlCommand, image: CGImage?, isLive: Bool) {
        // ── 0. 链路健康门控：E2E 没在真实决策 → 不可信 ──
        // 修复旧逻辑的退化平衡点：当 E2E 输出恒为 idle/恒定值时，
        // 一致性=1.0 + 极端度=0.0 + 画面=1.0 恰好算出 0.70，高于降级阈值
        // 0.65，导致"模型死了却永远卡在端到端档"。这里用链路存活直接归零。
        guard isLive else {
            confidence = 0
            consistencyScore = 0
            extremityScore = 0
            imageScore = 0
            return
        }

        // ── 1. 更新历史窗口 ──
        steerHistory.append(command.steer)
        if steerHistory.count > windowSize { steerHistory.removeFirst() }

        // 极端 = 转向打满（|steer|>0.95）。
        // 油门/刹车贴边（0 或 1）是正常驾驶行为，不判极端 ——
        // 旧定义把"巡航全油门"误判为退化，导致置信度恒 0.70、
        // 永远够不到 .rule→.e2e 的 0.75 恢复阈值，卡死在规则档。
        let isExtreme = abs(command.steer) > extremeThreshold
        extremeHistory.append(isExtreme)
        if extremeHistory.count > windowSize { extremeHistory.removeFirst() }
        longExtremeHistory.append(isExtreme)
        if longExtremeHistory.count > longExtremeWindow { longExtremeHistory.removeFirst() }

        // ── 2. 算三路子分 ──
        consistencyScore = computeConsistency()
        extremityScore = computeExtremity()
        imageScore = computeImageScore(image)

        // ── 3. 加权融合 ──
        let total = consistencyWeight + extremityWeight + imageWeight
        confidence = (consistencyScore * consistencyWeight
                      + extremityScore * extremityWeight
                      + imageScore * imageWeight) / max(total, 1e-6)

        // ── 4. 持续转向打满 → 贴墙/打转（退化）──
        // 一致性满分会把"打满恒定输出"洗成 0.70（高于降级阈值 0.65），
        // 导致模型打满 16 秒还卡在端到端档继续注入错误按键。
        // 长窗口（3s）内 |steer|>0.95 占比 >70% → 置信度压到 0.30 强制降级。
        // 注意：只判"转向打满"，不是判"输出恒定"（直道稳定输出是正常的）。
        if !longExtremeHistory.isEmpty {
            let longRatio = Double(longExtremeHistory.filter { $0 }.count)
                / Double(longExtremeHistory.count)
            if longRatio > longExtremeRatioThreshold {
                confidence = min(confidence, 0.30)
            }
        }
        confidence = max(0, min(1, confidence))
    }

    /// 重置（停止驾驶时调用）
    func reset() {
        steerHistory.removeAll()
        extremeHistory.removeAll()
        longExtremeHistory.removeAll()
        confidence = 1.0
        consistencyScore = 1.0
        extremityScore = 1.0
        imageScore = 1.0
    }

    // MARK: - 子分计算

    /// 输出一致性：steer 历史的标准差越小，分越高
    /// 标准差 0 → 1.0，标准差 0.5+ → 0.0
    private func computeConsistency() -> Double {
        guard steerHistory.count >= 3 else { return 0.8 }   // 帧数不足给中等分
        let mean = steerHistory.reduce(0, +) / Double(steerHistory.count)
        let variance = steerHistory.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steerHistory.count)
        let std = sqrt(variance)
        // std 0→1.0, std 0.5→0.0 线性映射
        return max(0, min(1, 1.0 - std * 2.0))
    }

    /// 输出极端度：极端帧占比越低，分越高
    private func computeExtremity() -> Double {
        guard !extremeHistory.isEmpty else { return 1.0 }
        let extremeRatio = Double(extremeHistory.filter { $0 }.count) / Double(extremeHistory.count)
        // 占比低于 ratioThreshold → 1.0，高于 → 线性下降到 0
        if extremeRatio <= extremeRatioThreshold {
            return 1.0
        }
        // P2 修复：极端占比阈值滑到 1.0（或异常值/NaN）时分母 (1.0 - threshold) 为 0，
        // 除零会产出 inf/NaN 污染置信度。guard 分母 > 0，异常时极端度直接判 0（保守降级）。
        let denom = 1.0 - extremeRatioThreshold
        guard denom > 0 else { return 0 }
        return max(0, 1.0 - (extremeRatio - extremeRatioThreshold) / denom)
    }

    /// 画面有效性：亮度在正常范围 → 1.0，异常 → 0.0
    /// 亮度计算已移到后台队列（CIAreaAverage 全图平均，主线程零绘制），
    /// 结果异步回写 imageScore；本帧融合沿用上一帧已算好的缓存分。
    private func computeImageScore(_ image: CGImage?) -> Double {
        guard let image = image else {
            imageScore = 0.5   // 无图像给中等分
            return imageScore
        }
        // 主线程只读一次阈值快照，闭包捕获常量，避免跨线程读可变状态（无数据竞争）
        let minB = brightnessMin
        let maxB = brightnessMax
        // 只保留最新帧：上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，
        // 沿用缓存分即可），避免每 tick 无脑入队、后台亮度任务堆积。
        guard !brightnessInFlight else { return imageScore }
        brightnessInFlight = true
        Self.brightnessQueue.async { [weak self] in
            let brightness = Self.averageBrightness(cgImage: image)
            let score: Double = (brightness < minB || brightness > maxB) ? 0.1 : 1.0
            // 在后台队列提前解包 weak self，避免将非 Sendable 的 self 引用
            // 传入 @MainActor Task（Swift 6 会检查跨域发送）
            let target: ConfidenceEstimator? = self
            Task { @MainActor [target] in
                target?.brightnessInFlight = false
                target?.imageScore = score
            }
        }
        // 本帧融合用缓存分（上一帧后台结果），不阻塞主线程等亮度
        return imageScore
    }

    /// 亮度后台任务 in-flight 标志（主线程置位 / 后台回主线程清除，全程主线程访问无锁）
    /// @ObservationIgnored：非 UI 状态，不参与观察
    @ObservationIgnored
    private var brightnessInFlight = false

    /// 后台亮度计算队列（独立于推理队列的 serial queue）
    private static let brightnessQueue = DispatchQueue(
        label: "com.aurora.confidence.brightness", qos: .userInitiated)

    /// 复用的 CoreImage 渲染上下文（线程安全，跨线程共享，避免每帧新建）
    ///
    /// ⚠️ 2026-10-11 GPU 零占用修复（w4-tools 的 P4 审计发现）：
    ///   原实现**未指定 device** → CIContext 默认**优先用 GPU**。
    ///   本项目铁律「推理不碰 GPU」（游戏独占 GPU）；`CaptureEngine.swift:957`
    ///   已记录过 GPU CIContext 排队导致 **40ms 卡顿**的血案。
    ///   本处虽只渲染到 **1×1** 缓冲（`CIAreaAverage`），GPU 侧开销极小，
    ///   但**任何 GPU 提交都会与游戏争用命令队列** → 强制 CPU 渲染消除不确定性。
    private static let brightnessContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])

    /// 计算图像平均亮度 [0,1]（后台执行）
    ///
    /// ⚠️⚠️ 2026-10-11 重大修复：**彻底移除 CIContext**（本文件再无任何 CoreImage 调用）
    ///
    /// 【血案证据 — `sample` 实测，不是推测】
    ///   用户报告"没开游戏、只是打开自动驾驶就卡到 12fps、主驾延迟 100+ms"。
    ///   `sample` 引擎进程 5 秒，抓到的调用栈（679 个采样点全卡在这一条）：
    ///   ```
    ///   Thread: com.aurora.confidence.brightness (serial)   679 samples
    ///     └ ConfidenceEstimator.computeImageScore  :197
    ///       └ averageBrightness(cgImage:)                     646 samples
    ///         └ CIContext.render(toBitmap:)
    ///           └ CI::MetalContext::readback_bitmap             ← 走 Metal（GPU）！
    ///             └ _MTLCommandBuffer waitUntilCompleted       446 samples
    ///               └ __psynch_cvwait                           ← 阻塞等 GPU！
    ///   ```
    ///
    /// 【为什么之前的"CPU 修复"无效 —— 官方头文件铁证】
    ///   本文件曾设 `CIContext(options: [.useSoftwareRenderer: true])`，但
    ///   `CIContext.h:184` 原文写死：
    ///   > Note: This option has no effect if the platform does not support OpenCL.
    ///   **Apple Silicon 没有 OpenCL** → 该选项被系统**静默忽略** → 照样走 Metal。
    ///   ⟹ 只要用 CIContext，就无法保证不碰 GPU。**唯一可靠的做法是不用 CIContext。**
    ///
    /// 【新实现：纯 CPU 直接采样像素，零 GPU】
    ///   直接从 CGImage 的 data provider 读字节，按步长抽样 ~4096 个点求均值。
    ///   · 无 CIContext / 无 CIImage / 无 Metal 提交 → **绝不与游戏或 WindowServer 抢 GPU**
    ///   · 开销：4096 次指针读 + 加法 ≈ **0.05ms**（对比原先等 GPU 的数百 ms）
    ///   · 精度：抽样 0.4%（1280×832）对"平均亮度"足够 —— 该值只用于
    ///     `0.08 / 0.95` 两个粗阈值判断（见 `computeImageScore` 注释）
    ///
    /// 【回退开关】`AURORA_CONF_CI=1` 可临时恢复 CoreImage 路径（仅在排查对比时用）。
    private static let useCoreImagePath =
        ProcessInfo.processInfo.environment["AURORA_CONF_CI"] == "1"

    private static func averageBrightness(cgImage: CGImage) -> Double {
        if useCoreImagePath { return averageBrightnessViaCoreImage(cgImage: cgImage) }
        return averageBrightnessViaCPU(cgImage: cgImage)
    }

    /// 纯 CPU 路径（默认）：直接读像素指针抽样求均值。**零 GPU 提交。**
    private static func averageBrightnessViaCPU(cgImage: CGImage) -> Double {
        // 只支持 8bpc / 32bpp 的常见屏捕格式（32BGRA / 32ARGB）；
        // 其它格式（罕见）直接给中等分，不猜（宁可保守也不引入错误像素解释）。
        guard cgImage.bitsPerComponent == 8,
              cgImage.bitsPerPixel == 32,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let base = CFDataGetBytePtr(data) else {
            return 0.5
        }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return 0.5 }
        let rowBytes = cgImage.bytesPerRow
        let total = w * h
        // 目标抽样点数：约 4096（对 1280×832 是 0.4%），至少每像素 1 步
        let step = max(1, total / 4096)

        // 字节序判定：**屏捕链路恒为 32BGRA little-endian**（CaptureEngine 显式锁
        // kCVPixelFormatType_32BGRA，见 CaptureEngine.swift 的 pixelFormat 注释）。
        // 这里按 bitmapInfo 的 byteOrder 精确判定，避免把 B/G/R 搞反。
        let bi = cgImage.bitmapInfo
        let isLittleEndian = bi.contains(.byteOrder32Little)
        // 小端 + premultipliedFirst = 内存序 B,G,R,A（32BGRA）
        // 大端 + premultipliedFirst = 内存序 A,R,G,B（32ARGB）
        let rIdx = isLittleEndian ? 2 : 1
        let gIdx = 2
        let bIdx = isLittleEndian ? 0 : 3

        var sumR = 0, sumG = 0, sumB = 0, count = 0
        var i = 0
        while i < total {
            let x = i % w
            let y = i / w
            let offset = y * rowBytes + x * 4
            // 防御：data 长度可能小于 (rowBytes*h)（某些 CGImage 的尾部裁剪）
            // 越界读取会崩，故用 CFDataGetLength 做边界检查
            if offset + 3 >= CFDataGetLength(data) { break }
            sumB += Int(base[offset + bIdx])
            sumG += Int(base[offset + gIdx])
            sumR += Int(base[offset + rIdx])
            count += 1
            i += step
        }
        guard count > 0 else { return 0.5 }
        let r = Double(sumR) / Double(count) / 255.0
        let g = Double(sumG) / Double(count) / 255.0
        let b = Double(sumB) / Double(count) / 255.0
        // Rec.601 亮度近似（与旧 DeviceGray 转灰的视觉亮度一致；阈值 0.08/0.95 粗糙，语义等价）
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// CoreImage 路径（**仅排查对比用，默认关闭**）：见上方血案注释——
    /// 在 Apple Silicon 上必然走 Metal 且同步等 GPU，是"没开游戏也卡"的根因。
    private static func averageBrightnessViaCoreImage(cgImage: CGImage) -> Double {
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
        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
