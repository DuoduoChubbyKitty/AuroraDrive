// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  GuideLineReader.swift — 小地图引导线偏离度（导航/驾驶质量判据）
// ----------------------------------------------------------------------------
//  距离用于时序兜底，PCA 走向用于与自车定位位移比对。
//    · 线钉在世界上，车开过去才消失 → 车压线时距离小；
//    · 车偏离路线 → 该距离持续变大 → 判偏离 → 扣分；
//    · 路线重规划 → 最近点跟着新线走，天然鲁棒。
//
//  **明确不做**（用户逐条否决，勿再加回来）：
//    ✗ 不算车头朝向（用户：「那个车头朝向是乱七八糟的，没法用」）
//    ✗ 不算终点距离（用户：「终点读不到，不可能通过线虚空推算终点」）
//    ✗ 不新增 OCR（会卡帧导致用户游戏失败，外挂目的是帮用户赢）
//
//  ⚠️ 两个实测校正（2026-11-21，104067 帧训练数据 clip_20261114_161701）：
//    ① 训练帧（384×224）小地图圆心 ≈(31.6, 33.3)、半径 ≈33px —— 与桌面
//       截图（2940×1912，圆心 302,330、边长 280）完全不同尺度，必须分开标定。
//    ② 引导线在训练帧里是**亮米色 RGB≈(255,250,240)**，不是桌面截图的饱和黄。
//       只用黄色阈值（要求 B<110）在训练帧上抓到 0 像素。此处两种都认。
//
//  实测（201 帧全命中）：最近距离中位 12.2px（p25 10.8 / p75 14.9）、
//    相邻帧跳变中位 0.00px（p95 3.1px）、76% 帧距离 <15px（车压线）。
//    → 判据高度稳定，可直接用于「偏离扣分」。
// ============================================================================

import Foundation
import CoreGraphics
import CoreVideo
import OpenCVFlow

enum GuideLineReader {

    /// 车心到引导线的最近距离 + 引导线**走向**（同方向判定用）。
    struct Deviation {
        /// 车心到引导线的最近距离（小地图像素）。辅助判据：完全脱离线时兜底。
        var distancePx: Double
        /// 最近点相对车心的偏移（像素，x 右 y 下）——仅排障用。
        var offsetX: Double
        var offsetY: Double
        /// 引导线走向（0=正北顺时针，度，[0,180) 无正反歧义）。
        /// 用户 2026-11-21：高速时压不压线不重要，**方向一致才算对**；
        /// 方向不一致才扣分。走向用线体像素的协方差主轴拟合（PCA），
        /// 与「车头朝向」无关，也不依赖任何罗盘数据。
        var lineHeadingDeg: Double
        /// 走向拟合可信度 [0,1]：PCA 主轴特征值占比。线越直越高。
        var headingConfidence: Double
        /// 引导线像素总数（可信度参考）。
        var linePixelCount: Int
        /// **远端方位**（0=北顺时针，[0,360) 全向）——线体离车心最远处那段的方位，
        /// 即「这条路往哪边延伸」= 车该去的方向。
        /// 用户 2026-11-21 决定：**逆行必须判错**，所以需要这个带正反歧义的方位
        /// 来区分「沿路正向」与「沿路反向」。
        var farBearingDeg: Double
        /// 远端方位可信度 [0,1]：远端像素量与角度集中度。低时不参与正反判定。
        var farConfidence: Double
    }

    struct Detection {
        let deviation: Deviation
        /// 以 ROI 左上角为原点的线体采样。空隙两侧各自成段。
        let segments: [[CGPoint]]
    }

    /// 三帧 × 32 点，实际走过的定位轨迹另有 104 点预算。
    static let maxPolylinePoints = 32

    /// 玩家指示环半径下限（小地图像素）：环扣在车心周围，其像素不是引导线，
    /// 必须排除——不排除时「最近距离」恒等于环半径，永不为 0。
    /// 训练帧实测环约 6px（小地图半径 33）；桌面截图约 14px（半径 204 尺度）。
    private static func playerRingRadius(width: Int, height: Int) -> Double {
        // 按小地图尺寸比例：环约占半径的 1/5
        let radius = Double(min(width, height)) / 2
        return max(3.0, radius * 0.20)
    }
    /// 引导线像素总数低于此值判「无引导线」（遮挡/无导航/穿隧道）。
    private static let minLinePixels = 15

    /// 算车到引导线最近距离（核心函数）。
    ///
    /// - Parameters:
    ///   - bgra: 小地图 BGRA 字节（byte0=B,1=G,2=R,3=A；CVPixelBuffer 32BGRA 同布局）。
    ///   - width/height/bytesPerRow: 小地图尺寸与行跨度（车心 = 图像正中）。
    ///   - maxRadiusPx: 搜索半径上限（默认按短边一半减 2，圆边内）。
    /// - Returns: 引导线像素不足/尺寸非法返回 nil（调用方保持上一有效值）。
    static func deviation(bgra: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                          maxRadiusPx: Double? = nil) -> Deviation? {
        bgra.withUnsafeBufferPointer { bytes in
            guard height > 0, bytesPerRow > 0, height <= bytes.count / bytesPerRow,
                  let base = bytes.baseAddress else { return nil }
            return scan(base, width: width, height: height, bytesPerRow: bytesPerRow,
                        maxRadiusPx: maxRadiusPx, collectPoints: false)?.deviation
        }
    }

    static func detect(pixelBuffer: CVPixelBuffer, collectPoints: Bool = true) -> Detection? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return scan(base.assumingMemoryBound(to: UInt8.self),
                    width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), maxRadiusPx: nil,
                    collectPoints: collectPoints)
    }

    // ── 命中点缓冲复用（2026-11-21 评审 B 指出每帧按全图容量预分配 ≈306KB）──
    // 实测：实际线像素中位仅 62 点，却按 width*height=4356（280² 时 78400）预分配，
    // 浪费 70~1000 倍。改为 thread-local 复用缓冲：容量按需增长一次，之后零分配。
    // 线程安全：threadDictionary 天然每线程独立（visualLocQueue 串行 + 主线程各一份）。
    private static let hitBufferKey = "aurora.guideline.hitBuffer"

    /// 取（并在需要时扩容）本线程复用的命中点缓冲。
    private static func reusableHitBuffer(capacity: Int) -> UnsafeMutablePointer<UInt32> {
        let key = hitBufferKey
        let dict = Thread.current.threadDictionary
        var buf = dict[key] as? HitBuffer
        if buf == nil || buf!.capacity < capacity {
            buf = HitBuffer(capacity: max(capacity, 8192))
            dict[key] = buf
        }
        return buf!.pointer
    }

    /// 命中点缓冲（类：threadDictionary 持有，随线程销毁释放）。
    private final class HitBuffer {
        let capacity: Int
        let pointer: UnsafeMutablePointer<UInt32>
        init(capacity: Int) {
            self.capacity = capacity
            self.pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
        }
        deinit { pointer.deallocate() }
    }

    private static func scan(_ bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                             maxRadiusPx: Double?, collectPoints: Bool) -> Detection? {
        guard width > 16, height > 16, width <= bytesPerRow / 4,
              bytesPerRow <= Int32.max, height <= Int(Int32.max) / width else { return nil }
        let ring = playerRingRadius(width: width, height: height)
        let rMax = min(maxRadiusPx ?? Double(min(width, height)) / 2 - 2,
                       Double(min(width, height)) / 2)
        let ringSq = ring * ring, radiusSq = rMax * rMax
        var stats = AD_GuideLineScan()
        let hits: [UInt32]
        if collectPoints {
            // 复用 thread-local 缓冲（容量上限按全图；实际命中远小于此，但只分配一次）。
            let buf = Self.reusableHitBuffer(capacity: width * height)
            stats = ad_guideline_scan(bgra, Int32(width), Int32(height), Int32(bytesPerRow),
                                      ringSq, radiusSq, buf)
            // 只拷贝实际命中数（典型 62 点，非全图 4356）——这才是下游真正需要的量。
            hits = Array(UnsafeBufferPointer(start: buf, count: Int(stats.count)))
        } else {
            hits = []
            stats = ad_guideline_scan(bgra, Int32(width), Int32(height), Int32(bytesPerRow),
                                      ringSq, radiusSq, nil)
        }
        guard stats.count >= minLinePixels, stats.bestSq.isFinite else { return nil }
        let (heading, conf) = fitLineHeading(sumX: stats.sumX, sumY: stats.sumY,
                                             sumXX: stats.sumXX, sumYY: stats.sumYY,
                                             sumXY: stats.sumXY, count: Int(stats.shapeCount))
        // 远端方位（带正反歧义，逆行判定用）：单位向量和 → atan2(东, 北)。
        var farBearing = 0.0, farConf = 0.0
        if stats.farCount >= 8 {
            farBearing = (atan2(stats.farSin, stats.farCos) * 180 / .pi + 360)
                .truncatingRemainder(dividingBy: 360)
            let mag = (stats.farSin * stats.farSin + stats.farCos * stats.farCos).squareRoot()
            farConf = min(1.0, mag / Double(stats.farCount))
        }
        let deviation = Deviation(distancePx: stats.bestSq.squareRoot(),
                                  offsetX: stats.bestX, offsetY: stats.bestY,
                                  lineHeadingDeg: heading, headingConfidence: conf,
                                  linePixelCount: Int(stats.count),
                                  farBearingDeg: farBearing, farConfidence: farConf)
        let segments = hits.isEmpty ? [] : polyline(hits, width: width, height: height,
                                                    radius: abs(rMax), heading: heading)
        return Detection(deviation: deviation, segments: segments)
    }

    /// 沿拟合方向分箱，选取靠近上个点的实际命中像素。断口留空，避免穿过车身环或连到远侧图标。
    private static func polyline(_ pixels: [UInt32], width: Int, height: Int,
                                 radius: Double, heading: Double) -> [[CGPoint]] {
        let count = maxPolylinePoints
        let step = 2 * radius / Double(count)
        let centerX = Double(width - 1) / 2, centerY = Double(height - 1) / 2
        let angle = heading * .pi / 180
        let vx = sin(angle), vy = -cos(angle)
        var bins = [[CGPoint]](repeating: [], count: count)
        for pixel in pixels {
            let index = Int(pixel)
            let point = CGPoint(x: Double(index % width) - centerX, y: Double(index / width) - centerY)
            let along = point.x * vx + point.y * vy
            let bin = min(count - 1, max(0, Int((along + radius) / step)))
            bins[bin].append(point)
        }
        var segments: [[CGPoint]] = []
        var segment: [CGPoint] = []
        var prior: CGPoint?
        let maxGap = max(3.0, 3 * step)
        for bin in bins {
            if bin.isEmpty {
                if segment.count >= 2 { segments.append(segment) }
                segment = []
                prior = nil
                continue
            }
            // 起点用本分箱中心，后续保留与已有笔画最接近的真实像素。
            let reference = prior ?? CGPoint(x: bin.reduce(0) { $0 + $1.x } / Double(bin.count),
                                             y: bin.reduce(0) { $0 + $1.y } / Double(bin.count))
            let point = bin.min {
                let ax = $0.x - reference.x, ay = $0.y - reference.y
                let bx = $1.x - reference.x, by = $1.y - reference.y
                return ax * ax + ay * ay < bx * bx + by * by
            }!
            if let prior, hypot(point.x - prior.x, point.y - prior.y) > maxGap {
                if segment.count >= 2 { segments.append(segment) }
                segment = []
            }
            segment.append(CGPoint(x: point.x + centerX + 0.5, y: point.y + centerY + 0.5))
            prior = point
        }
        if segment.count >= 2 { segments.append(segment) }
        return segments
    }

    /// 线体像素的 PCA 主轴 → 走向（[0,180)，无正反歧义）。
    /// 协方差矩阵 [[sxx, sxy], [sxy, syy]] 的主特征向量方向即走向。
    /// - Returns: (走向度, 置信度)。点太少/退化为圆团时置信度 0。
    private static func fitLineHeading(sumX: Double, sumY: Double,
                                       sumXX: Double, sumYY: Double, sumXY: Double,
                                       count: Int) -> (Double, Double) {
        guard count >= 8 else { return (0, 0) }
        let n = Double(count)
        let mx = sumX / n, my = sumY / n
        let cxx = sumXX / n - mx * mx
        let cyy = sumYY / n - my * my
        let cxy = sumXY / n - mx * my
        // 2×2 对称阵主特征向量：tan(2θ) = 2cxy / (cxx - cyy)
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        // 主轴方向（画面坐标 x 右 y 下）→ 世界方位（0=北、顺时针）
        // 画面 dx 对应东、-dy 对应北 → bearing = atan2(dx, -dy)
        let dirX = cos(theta), dirY = sin(theta)
        var bearing = atan2(dirX, -dirY) * 180 / .pi
        bearing = bearing.truncatingRemainder(dividingBy: 180)
        if bearing < 0 { bearing += 180 }
        // 置信度：主特征值占比（1=完美直线，0.5=圆团）
        let tr = cxx + cyy
        let disc = ((cxx - cyy) * (cxx - cyy) + 4 * cxy * cxy).squareRoot()
        let lambda1 = (tr + disc) / 2, lambda2 = (tr - disc) / 2
        let conf = tr > 1e-9 ? max(0, min(1, (lambda1 - lambda2) / tr)) : 0
        return (bearing, conf)
    }

    /// CGImage 版（自检/离线分析用）：画进 BGRA 位图后走统一算法。
    static func deviation(minimap: CGImage, maxRadiusPx: Double? = nil) -> Deviation? {
        let w = minimap.width, h = minimap.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(minimap, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return deviation(bgra: data, width: w, height: h, bytesPerRow: w * 4,
                         maxRadiusPx: maxRadiusPx)
    }

    // MARK: - 方向一致性判定（用户 2026-11-21：压不压线不重要，方向一致才对）

    /// 方向判定结果。
    enum DirectionVerdict: Codable, Equatable {
        /// 方向一致（在容差内）→ 正常驾驶，不扣分。
        case aligned
        /// 方向偏离超过容差 → 需要扣分。
        case misaligned(degreesOff: Double)
        /// 数据不足（刚起步/定位丢失/线不清晰）→ 不判定，不扣分。
        case insufficient
    }

    /// 用「世界坐标位移方向」与「引导线走向」比夹角判方向一致性。
    ///
    /// **为什么不用车头朝向**：用户实测罗盘朝向混乱不可用；而世界坐标位移
    /// 是真实运动轨迹（车从 A 定位到 B），方向可靠。
    ///
    /// **为什么走向无正反歧义**：引导线是「要走的路」，车可能正向或反向行驶在
    /// 同一条线上；用 [0,180) 走向比对，正反向都能正确判（走对路就是走对路）。
    ///
    /// - Parameters:
    ///   - movedWorld: 自上一采样点以来世界坐标位移 (dx, dy)，单位世界厘米。
    ///     距离太小（< minMoveMeters）时不判（停着/刚起步，方向不可靠）。
    ///   - lineHeadingDeg: 引导线走向（Deviation.lineHeadingDeg，[0,180)）。
    ///   - confidence: 走向拟合置信度；过低时判 insufficient。
    ///   - toleranceDeg: 允许夹角（默认 50°：高速变线/路宽偏移仍在同向范畴）。
    /// - Returns: 判定结果。
    /// 方向可判定的最小位移（世界厘米）。
    ///
    /// ⚠️⚠️ 2026-11-21 二次修正（评审 A 实测反例）：
    /// 视觉定位 downscale=4、整数峰值无亚像素插值 → **单轴量化格宽 = 4/kCalibA
    /// ≈ 243.98 cm**。把门槛设成 100cm（1 米）低于量化格 → 反例：真车沿线朝 20°
    /// 直行，每帧仅 20cm，量化后连续 6 帧都读到同一个 (244,0) 格点跳变
    /// → 测得方位恒 90°、误差 70° → 重复计票 6 次判 offRoute（正常跟线被扣分）。
    /// 故门槛必须**高于 2 个量化格**，才保证方向由真实多格位移决定而非一个格点跳变。
    /// 取 500cm（≈2.05 格）：> 两格，且 15Hz 下 500cm 需 54km/h（1 秒窗）——
    /// 低速场景由「回看窗内累计」保证（GuideLineMotion 已按 movementWindow 累积）。
    /// 门槛取 **1 个量化格**（250cm ≈ 4/kCalibA=243.98+余量）：
    ///   · 低于 1 格 → 量化跳变可能与真实方向无关（评审 A 反例：120cm 真实位移
    ///     量化成 244cm 假跳变）；
    ///   · 高于 1 格 → 10km/h（1 秒 2.78m）也被误杀。
    /// 「同一格点重复计票」这个真正成因改由 GuideLineMotion 的
    /// **位置必须变化才计票** 处理（见 mismatchedPosition 逻辑），不再靠放大门槛。
    static let minMoveCm: Double = 250
    /// 位移越长越可信：达到 2 格（500cm）视为满可信度。
    static let fullConfidenceMoveCm: Double = 500

    /// - Parameters:
    ///   - farBearingDeg / farConfidence: 引导线**远端方位**与可信度。
    ///     用户 2026-11-21 决定「逆行必须判错」→ 用远端方位（线往远处延伸的方向）
    ///     与车运动方向比对，偏差 >90° 判逆行。远端不可信时跳过（防误杀）。
    static func judgeDirection(movedWorldX dx: Double, _ dy: Double,
                               lineHeadingDeg: Double,
                               confidence: Double,
                               farBearingDeg: Double? = nil,
                               farConfidence: Double = 0,
                               toleranceDeg: Double = 50) -> DirectionVerdict {
        let moveLen = (dx * dx + dy * dy).squareRoot()
        // 位移不足 1 米：方向噪声可能盖过真实运动（停车抖动/定位微跳），不判。
        guard moveLen >= Self.minMoveCm else { return .insufficient }

        // ── 逆行判定优先（用户 2026-11-21「必须判错」）──
        // ⚠️ 2026-11-22 实测修正：原先逆行检查放在 confidence 门槛**之后**，
        // 导致 headingConfidence < 0.35 的帧被提前判 insufficient → 逆行漏检
        // （真实数据实测捕获率仅 72.6%，26 帧漏检全是 insufficient）。
        // 逆行只需**远端方位**（farConfidence），与近段走向置信度是独立信号，
        // 故提到前面：只要求 farConfidence 足够即可判逆行。
        let moveFull = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        if let far = farBearingDeg, farConfidence >= 0.35 {
            var fullDiff = abs(moveFull - far).truncatingRemainder(dividingBy: 360)
            if fullDiff > 180 { fullDiff = 360 - fullDiff }
            if fullDiff > 90 {
                // 逆行同样要过位移可信度（防小位移噪声误杀）
                let moveConfRev = min(1.0, moveLen / Self.fullConfidenceMoveCm)
                if farConfidence * moveConfRev >= 0.25 {
                    return .misaligned(degreesOff: fullDiff)
                }
            }
        }

        guard confidence >= 0.35 else { return .insufficient }
        // 小位移（1~3 米）判定照样给出，但置信度按位移线性折算：
        // 与线走向置信度取较小值，避免急停/蠕行时的瞬时抖动被当方向错误。
        let moveConf = min(1.0, moveLen / Self.fullConfidenceMoveCm)
        // 组合门槛：线置信度 × 位移可信度。0.25（比原 0.20 严）——
        // 量化噪声下低置信度小位移不足以支撑扣分（评审 A 反例的成因之一）。
        guard confidence * moveConf >= 0.25 else { return .insufficient }
        // 沿路走向夹角（[0,180) 无正反歧义，最大 90°）
        var moveBearing = moveFull.truncatingRemainder(dividingBy: 180)
        var diff = abs(moveBearing - lineHeadingDeg).truncatingRemainder(dividingBy: 180)
        if diff > 90 { diff = 180 - diff }
        return diff <= toleranceDeg ? .aligned : .misaligned(degreesOff: diff)
    }

    /// 偏离判定器：吃连续帧的最近距离，判断「车是否持续偏离路线」。
    ///
    /// 判据（用户方案）：距离基线稳定 = 正常；**持续变大**才判偏离。
    /// 路线重规划会让距离突变，此时重置基线而不是判偏离（重规划不是车开错）。
    struct DeviationTracker {
        /// 基线距离（指数滑动平均；重规划/起步时重置）。
        private(set) var baselinePx: Double?
        /// 连续「超出基线阈值」的帧数。
        private(set) var offRouteStreak = 0
        /// 判定偏离所需的连续帧数（15Hz 下 6 帧 ≈ 0.4s — 单帧抖动不罚）。
        var framesToJudge = 6
        /// 超出基线多少算偏离（像素）。训练帧实测正常波动 p75 14.9 - 中位 12.2
        /// ≈ 2.7px；留足余量取 6px（避免正常路宽偏移误判）。
        var tolerancePx = 6.0
        /// 基线更新系数（越小越稳，越大越快跟线宽变化）。
        var baselineAlpha = 0.08
        /// 单帧跳变超过此值视为路线重规划 → 重置基线，不判偏离。
        /// 训练帧实测相邻帧跳变 p95 仅 3.1px，取 15px 留足余量。
        var replanJumpPx = 15.0

        mutating func update(distancePx: Double) -> Bool {
            guard let base = baselinePx else {
                baselinePx = distancePx
                offRouteStreak = 0
                return false
            }
            // 重规划检测：距离突变更可能是线被重画，不是车跑偏。
            if abs(distancePx - base) > replanJumpPx {
                baselinePx = distancePx
                offRouteStreak = 0
                return false
            }
            if distancePx > base + tolerancePx {
                offRouteStreak += 1
            } else {
                offRouteStreak = 0
                baselinePx = base + baselineAlpha * (distancePx - base)
            }
            return offRouteStreak >= framesToJudge
        }

        mutating func reset() {
            baselinePx = nil
            offRouteStreak = 0
        }
    }
}
