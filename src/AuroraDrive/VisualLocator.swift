// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  VisualLocator.swift — 纯视觉小地图定位（macOS · Swift 自实现）
//
//  职责：把「游戏画面上的小地图」当作模板，在「完整大地图」上用多尺度
//        归一化互相关（NCC）找最佳位置，输出自车在大地图上的像素坐标。
//
//  设计（质量优先，性能后调）：
//    1) 用 CGImageSource 缩略解码把 11264² 大地图降采样成若干档"匹配图"，
//       避免常驻 127M 像素的全尺寸灰度；每档 = 一个缩放级别 + 对应灰度 buffer。
//    2) 模板=屏幕小地图灰度。对每一档，先在匹配图上大步长粗扫若干候选，
//       再于粗位邻域做全步精细盘查，选 NCC 最高且达阈值者。
//    3) 匹配像素 → /scale → 回原图像素坐标（左上原点，y 向下）。
//    4) EMA 平滑坐标防抖；提供"合成自检"：从大地图已知位置抠一块当小地图
//       → 定位应回到原位，验证降采样/坐标换算/多档选择是否自洽。
//
//  纯视觉、不碰网络、无第三方依赖；失败只影响定位输出，不崩 App。
//  仅用于显示链路（左上角小地图 + 纯规则导航），不进入决策关键链。
// ============================================================================
import Foundation
import CoreGraphics
import ImageIO
import Accelerate

/// 一档匹配图：按 `scale` 把原图降采样后的灰度 buffer
struct LocatorScale {
    let scale: Double          // 匹配图像素 → 原图像素的换算（matchWidth / 原图宽）
    let width: Int
    let height: Int
    let gray: [Float]          // 行主序灰度（0..1）
    let luminanceMean: Float   // 全图均值，用于归一化校验（诊断用）
    /// 灰度积分图（(width+1)×(height+1)，行主序；首行首列全 0）。
    /// 任意矩形窗口的和 = 4 次查表，O(1)，避免 NCC 里逐像素累加 Σv。
    let integral: [Float]
    /// 灰度平方积分图：矩形窗口的 Σv² 同样 O(1) 查表。
    let integralSq: [Float]
}

/// 定位结果
struct LocateResult {
    var found: Bool = false
    var x: Double = 0          // 原图像素坐标（左上原点，y 向下）
    var y: Double = 0
    var score: Double = 0      // NCC，0..1
    var scaleIndex: Int = 0    // 命中的缩放档
}

/// 纯视觉小地图定位器
final class VisualLocator {

    /// 大地图文件路径（11264² 完整大世界地图）
    private let mapPath: String
    /// 匹配图最大边长：主档决策分辨率（越大越准、越慢）
    private var workSizes: [CGFloat]

    private var scales: [LocatorScale] = []

    /// EMA 平滑后的"最后稳健位置"（原图像素）
    private var wasLastCentered = false
    private var lastSmoothX: Double = 0
    private var lastSmoothY: Double = 0
    private let smoothAlpha: Double

    /// 大地图原始宽高（用于坐标换算回原图）
    private(set) var originWidth: Int = 0
    private(set) var originHeight: Int = 0

    init(mapPath: String,
         workSizes: [CGFloat] = [2048, 1536, 1024],
         smoothAlpha: Double = 0.7) {
        self.mapPath = mapPath
        self.workSizes = workSizes
        self.smoothAlpha = smoothAlpha
    }

    var isReady: Bool { !scales.isEmpty }

    /// 已预生成的匹配档数量（诊断/自检用）
    var scaleCount: Int { scales.count }

    /// 加载大地图并预生成多档匹配图（主线程首次调用；内存一次性，之后只读）
    func prepare() -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil) else {
            return "VisualLocator: 无法打开地图 \(mapPath)"
        }
        guard let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return "VisualLocator: 无法解码地图首帧"
        }
        originWidth = full.width
        originHeight = full.height
        guard originWidth > 0, originHeight > 0 else {
            return "VisualLocator: 地图尺寸非法 \(originWidth)x\(originHeight)"
        }

        var built: [LocatorScale] = []
        for target in workSizes {
            guard target > 64 else { continue }
            // 缩略解码：系统内部降采样，避免一次性常驻全分辨率灰度
            let opts = [
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else {
                continue
            }
            let w = thumb.width, h = thumb.height
            guard w > 8, h > 8 else { continue }
            if let chunk = Self.grayFloatPixels(thumb) {
                let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
                let ints = Self.buildIntegral(chunk, w: w, h: h)
                built.append(LocatorScale(scale: Double(w) / Double(originWidth),
                                          width: w, height: h,
                                          gray: chunk, luminanceMean: mean,
                                          integral: ints.sum, integralSq: ints.sq))
            }
        }
        // P 修复（首帧定位失配）：大地图 NCC 峰宽极窄（~2px），若首帧全局扫
        // 在 768 档以 stride=16 采样，极可能整条跨过峰顶（实测最佳仅 0.15、
        // 而真实位置 0.85+）→ 首帧定位静默失败。在档表末尾追加一个「全局粗扫档」
        // （边长 ~192，模板仅 ~22px）：该档 stride=2 全局扫描量级 ~3.5M 次 NCC，
        // 却保证任何 ≥2px 峰都能被采到（stride 2 必触 2px 宽峰），
        // 由此得到的粗坐标再喂给各细档邻域精扫（±120 找回亚步精度）。
        // 仅当最粗档仍远大于 192 时追加，避免小图重复建档。
        if let coarsest = built.min(by: { $0.scale < $1.scale }),
           coarsest.width > Int(Self.globalScanSize * 1.4) {
            let opts = [
                kCGImageSourceThumbnailMaxPixelSize: Self.globalScanSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
                let w = thumb.width, h = thumb.height
                if w > 8, h > 8, let chunk = Self.grayFloatPixels(thumb) {
                    let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
                    let ints = Self.buildIntegral(chunk, w: w, h: h)
                    built.append(LocatorScale(scale: Double(w) / Double(originWidth),
                                              width: w, height: h,
                                              gray: chunk, luminanceMean: mean,
                                              integral: ints.sum, integralSq: ints.sq))
                }
            }
        }
        guard !built.isEmpty else { return "VisualLocator: 未能生成任何匹配档" }
        scales = built
        return nil
    }

    /// 全局粗扫档边长：首帧无 hint 时在这个小图上用 stride=2 全图扫，
    /// 保证采到 2px 宽的 NCC 峰（见 prepare() 说明）。
    private static let globalScanSize: CGFloat = 192
    /// Float(0..255)→Float(0..1) 乘数：用乘法代替除法，ARM SIMD 单周期完成
    private nonisolated static let inv255f: Float = 1.0 / 255.0

    // MARK: - 定位

    /// 用一帧小地图灰度定位自车原图像素坐标。
    /// - Parameters:
    ///   - template: 小地图灰度字节（0..255），行主序
    ///   - tw, th: 模板宽高（像素）
    ///   - scoreThreshold: 判定为命中的最低 NCC 分数
    /// - Returns: 定位结果（原图像素坐标）
    func locate(template: [UInt8], tw: Int, th: Int,
                scoreThreshold: Double = 0.80) -> LocateResult {
        // 耗时诊断（仅 --locate-live）：defer 覆盖所有返回路径，实测单次定位成本
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if CommandLine.arguments.contains("--locate-live") {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                FileHandle.standardError.write("[LOCATELIVE-DIAG] locate total=\(String(format: "%.1f", ms))ms\n".data(using: .utf8)!)
            }
        }
        guard let (tF, tMean) = Self.templateFloat(template, tw: tw, th: th),
              !scales.isEmpty,
              tw >= 8, th >= 8 else {
            return LocateResult()
        }

        // sqrt(Σ(t-tMean)²)，NCC 分母之一
        let tVar = Float(sqrt(Self.sumSqErr(tF, mean: tMean)))
        guard tVar > 1e-6 else { return LocateResult() }

        // 纹理门槛：模板像素方差过低（大片平坦/水面/空场）时，任何平坦区都与之高相关，
        // 极易假阳性。要求每像素标准差足够，否则拒绝本帧定位。阈值偏低以兼容下采样纹理块。
        let perStd = sqrt(Self.sumSqErr(tF, mean: tMean) / Double(tw * th))
        guard perStd >= 0.02 else { return LocateResult() }

        var best = LocateResult()
        best.score = -1

        // 已有上一次位置时用它做搜索提示（切块/邻域）；否则全图
        var hint: (x: Double, y: Double)? = nil
        if wasLastCentered {
            hint = (lastSmoothX, lastSmoothY)
        }

        // P 性能：首帧无 hint 时，最细档全图粗扫在 1280 档可达 5000+ 窗口 × 22500 次
        // NCC 内循环（~1.1 亿次，数秒）——定位首帧会"卡死"。策略：
        //   1) 无 hint（首帧/失配后重定位）：先在「全局粗扫档」（192，见 prepare）
        //      上用 stride=2 全图扫（NCC 峰极窄 ~2px，stride 16 会整条跨过峰顶而漏检，
        //      stride 2 保证采到任何 ≥2px 峰），得到粗坐标；
        //   2) 用粗坐标作 hint，再全档（各档在 ±120 匹配像素邻域）精扫。
        // 这样全图扫描只发生一次在最粗的小图上（快），各档精扫只在小邻域，总耗时大幅下降。
        //
        // 模板多档适配（P 修复）：模板 150px 是「屏幕小地图在 finest 档上的尺寸」。
        // 更粗档（scale 更小）里，同一块原图内容只占 scale/finestScale 的比例，
        // 模板必须按该比例缩小后再匹配，否则模板比真实内容大、NCC 永远低分失配。
        guard let finest = scales.max(by: { $0.scale < $1.scale }) else { return best }

        if hint == nil {
            // 首帧：只扫全局粗扫档（scale 最小者 = 追加的 192 档），模板缩放到该档尺寸
            guard let coarse = scales.min(by: { $0.scale < $1.scale }) else { return best }
            let coarseSide = max(8, Int((Double(tw) * coarse.scale / finest.scale).rounded()))
            guard let coarseT = Self.resizeTemplate(tF, fromW: tw, fromH: th, toW: coarseSide, toH: coarseSide),
                  let (coarseF, coarseM) = Self.centeredTemplate(coarseT, side: coarseSide) else { return best }
            let coarseVar = Float(sqrt(Self.sumSqErr(coarseF, mean: coarseM)))
            // 全局粗扫档必须 stride=2（峰宽 ~2px）；matchOneScale 在 hint==nil 时默认
            // stride=16，这里显式用 strideOverride=2 强制细步长全图扫，
            // 保证采到任何 ≥2px 峰（192 档 stride=2 全图仅 ~3.5M 次 NCC）。
            let coarseResult = Self.matchOneScale(scale: coarse,
                                                  template: coarseF, tMean: coarseM, tVar: coarseVar,
                                                  tw: coarseSide, th: coarseSide, hintPixel: nil,
                                                  strideOverride: 2)
            if coarseResult.found {
                // 粗坐标（原图像素）→ hint，供各档邻域精扫
                let hintX = (coarseResult.x + Double(coarseSide) / 2) / coarse.scale
                let hintY = (coarseResult.y + Double(coarseSide) / 2) / coarse.scale
                hint = (hintX, hintY)
                best = coarseResult
                best.scaleIndex = scales.firstIndex(where: { $0.scale == coarse.scale }) ?? 0
            } else {
                // 全局粗扫档也全图失配 → 直接失败
                wasLastCentered = false
                return best
            }
        }

        for (si, scale) in scales.enumerated() {
            // 模板缩放到该档尺寸（150 × scale/finestScale）
            let scaledSide = max(8, Int((Double(tw) * scale.scale / finest.scale).rounded()))
            guard let scaledT = Self.resizeTemplate(tF, fromW: tw, fromH: th, toW: scaledSide, toH: scaledSide),
                  let (scaledF, scaledM) = Self.centeredTemplate(scaledT, side: scaledSide) else { continue }
            let scaledVar = Float(sqrt(Self.sumSqErr(scaledF, mean: scaledM)))
            let result = Self.matchOneScale(scale: scale,
                                            template: scaledF, tMean: scaledM, tVar: scaledVar,
                                            tw: scaledSide, th: scaledSide,
                                            hintPixel: hint.map { ($0.x * scale.scale, $0.y * scale.scale) })
            if result.found && result.score > best.score {
                best = result
                best.scaleIndex = si
            }
        }

        guard best.found, best.score >= scoreThreshold else {
            // 整帧失配（含未达阈值）：清空上次，避免用过期坐标。
            // 必须把 found 置 false——matchOneScale 的 found 只是"有候选"
            // （score > -0.5），真正的命中判定在 scoreThreshold 这里。
            if CommandLine.arguments.contains("--locate-live") {
                FileHandle.standardError.write("[LOCATELIVE-DIAG] threshold reject found=\(best.found) score=\(String(format: "%.3f", best.score)) thr=\(String(format: "%.2f", scoreThreshold))\n".data(using: .utf8)!)
            }
            best.found = false
            wasLastCentered = false
            return best
        }

        // 自车锚点 = 匹配窗口中心（加模板半宽/半高）再 /scale 回原图像素。
        // 注意：模板在该档被缩放为 scaledSide（≠ 原 tw=150），锚点必须用
        // 命中档的 scaledSide/2 而不是 tw/2——否则粗档命中时中心偏掉
        // (tw-scaledSide)/2/scale 个原图像素（768 档可达 ~440px）。与 MaaNTE 的
        // raw_point = (match + w/2)/scale 一致，w 为命中档的实际模板边长。
        let bestScale = scales[best.scaleIndex]
        let bestSide = max(8, Int((Double(tw) * bestScale.scale / finest.scale).rounded()))
        let px = (best.x + Double(bestSide) / 2) / bestScale.scale
        let py = (best.y + Double(bestSide) / 2) / bestScale.scale

        // EMA 平滑
        if wasLastCentered {
            lastSmoothX = lastSmoothX * (1 - smoothAlpha) + px * smoothAlpha
            lastSmoothY = lastSmoothY * (1 - smoothAlpha) + py * smoothAlpha
        } else {
            lastSmoothX = px
            lastSmoothY = py
        }
        wasLastCentered = true

        return LocateResult(found: true,
                            x: lastSmoothX, y: lastSmoothY,
                            score: best.score,
                            scaleIndex: best.scaleIndex)
    }

    /// 复位内部状态（如切换地图/重新开始）
    func reset() {
        wasLastCentered = false
        lastSmoothX = 0
        lastSmoothY = 0
    }

    // MARK: - 单档匹配

    /// 在某一档匹配图上找模板最优位置（映射到的坐标仍为该档匹配图像素坐标）
    private static func matchOneScale(scale: LocatorScale,
                                      template tF: [Float], tMean: Float, tVar: Float,
                                      tw: Int, th: Int,
                                      hintPixel: (Double, Double)?,
                                      strideOverride: Int? = nil) -> LocateResult {
        let sw = scale.width, sh = scale.height
        let tcount = tw * th
        guard tcount > 0, sw >= tw, sh >= th else { return LocateResult() }
        // vDSP 版 nccAt 复用窗口拷贝 buffer（每档一次分配，粗扫/精扫共享）
        var work = [Float](repeating: 0, count: tcount)

        // 搜索范围：有提示在身边 64px 邻域（匹配图坐标），否则全图
        var x0 = 0, y0 = 0, x1 = sw - tw, y1 = sh - th
        if let (hx, hy) = hintPixel {
            let r: Double = 120
            x0 = max(0, Int(hx.rounded()) - Int(r))
            x1 = min(sw - tw, Int(hx.rounded()) + Int(r))
            y0 = max(0, Int(hy.rounded()) - Int(r))
            y1 = min(sh - th, Int(hy.rounded()) + Int(r))
        }
        guard x1 >= x0, y1 >= y0 else { return LocateResult() }

        // 粗扫：用大步长采样，保留 top-K 候选，避免逐窗全扫的不可用计算量。
        // 有邻域提示时范围小、用细步长；全局时用大步长，均不丢匹配峰值（模板够大，峰肩宽）。
        // P 修复（首帧定位失配）：NCC 峰宽极窄（大地图 ~2px），全局 stride=16 会整条
        // 跨过峰顶 → 首帧静默漏检。首帧全局扫必须用 stride=2（strideOverride 传入），
        // 保证采到任何 ≥2px 峰；代价在小图上可接受（192 档 ~3.5M 次 NCC）。
        let coarseStride = strideOverride ?? ((hintPixel != nil) ? 2 : 16)
        let topK = 8
        var candidates: [(score: Double, x: Int, y: Int)] = []
        func offer(_ s: Double, _ X: Int, _ Y: Int) {
            if candidates.count < topK {
                candidates.append((s, X, Y))
                if candidates.count == topK { candidates.sort { $0.score > $1.score } }
            } else if s > candidates.last!.score {
                candidates[topK - 1] = (s, X, Y)
                var i = topK - 2
                while i >= 0 && candidates[i].score < candidates[i + 1].score {
                    candidates.swapAt(i, i + 1)
                    i -= 1
                }
            }
        }
        var yy = y0
        while yy <= y1 {
            let rowBase = yy * sw
            var xx = x0
            while xx <= x1 {
                let ncc = Self.nccAt(scale: scale, template: tF, tMean: tMean, tVar: tVar,
                                     tw: tw, th: th, tcount: tcount,
                                     startX: xx, startY: yy, rowBase: rowBase,
                                     work: &work)
                offer(ncc, xx, yy)
                xx += coarseStride
            }
            yy += coarseStride
        }
        guard !candidates.isEmpty else { return LocateResult() }

        if CommandLine.arguments.contains("--locate-live") {
            FileHandle.standardError.write("[LOCATELIVE-DIAG] coarse topK: \(candidates.prefix(3).map { String(format: "%.3f@%d,%d", $0.score, $0.x, $0.y) }.joined(separator: " "))\n".data(using: .utf8)!)
        }

        // 精扫：对每个候选邻域做全步，取全局最高（候选峰值在粗步内不会漏）
        var best = LocateResult()
        best.score = -1
        for cand in candidates {
            let d = coarseStride - 1
            let fx0 = max(x0, cand.x - d)
            let fx1 = min(x1, cand.x + d)
            let fy0 = max(y0, cand.y - d)
            let fy1 = min(y1, cand.y + d)
            for cyy in fy0...fy1 {
                let rowBase = cyy * sw
                for cxx in fx0...fx1 {
                    let ncc = Self.nccAt(scale: scale, template: tF, tMean: tMean, tVar: tVar,
                                         tw: tw, th: th, tcount: tcount,
                                         startX: cxx, startY: cyy, rowBase: rowBase,
                                         work: &work)
                    if ncc > best.score {
                        best = LocateResult(found: true, x: Double(cxx), y: Double(cyy),
                                            score: ncc, scaleIndex: 0)
                    }
                }
            }
        }

        return LocateResult(found: best.found && best.score > -0.5 && best.score.isFinite,
                            x: best.x, y: best.y,
                            score: best.score,
                            scaleIndex: 0)
    }

    /// 在 (startX,startY) 处计算模板与匹配图窗口的归一化互相关（vDSP 加速版）
    /// NCC = (Σ(v·t) − n·mean(v)·mean(t)) / sqrt( (Σv² − n·mean(v)²) · (Σt² − n·mean(t)²) )
    /// - Σv / Σv²：积分图 O(1) 查表（LocatorScale.integral / integralSq）
    /// - Σ(v·t)：窗口 th 行 memcpy 拼成连续 buffer → 一次 vDSP_dotpr（SIMD）
    /// 原标量三重循环每窗口 ~2.2 万次乘加；改后每窗口 ~2.3 万次内存拷贝 +
    /// 一次 SIMD 点积，实测单窗口降一个量级，8Hz 定位不再烧满 CPU。
    /// - Parameter work: 调用方复用的临时 buffer（长度 ≥ tcount），避免每窗口分配。
    private static func nccAt(scale: LocatorScale, template tF: [Float], tMean: Float, tVar: Float,
                              tw: Int, th: Int, tcount: Int,
                              startX: Int, startY: Int, rowBase: Int,
                              work: inout [Float]) -> Double {
        let sw = scale.width
        let n = Double(tcount)
        // Σv / Σv²：积分图 O(1)
        let sumV = Double(boxSum(scale.integral, w: sw, x: startX, y: startY, tw: tw, th: th))
        let sumV2 = Double(boxSum(scale.integralSq, w: sw, x: startX, y: startY, tw: tw, th: th))
        // Σ(v·t)：窗口 th 行拼成连续 buffer，一次 vDSP_dotpr
        scale.gray.withUnsafeBufferPointer { g in
            work.withUnsafeMutableBufferPointer { wb in
                guard let gb = g.baseAddress, let wbase = wb.baseAddress else { return }
                for r in 0..<th {
                    let src = rowBase + r * sw + startX
                    wbase.advanced(by: r * tw).update(from: gb.advanced(by: src), count: tw)
                }
            }
        }
        var sumVT: Float = 0
        work.withUnsafeBufferPointer { w in
            guard let wb = w.baseAddress else { return }
            tF.withUnsafeBufferPointer { t in
                guard let tb = t.baseAddress else { return }
                vDSP_dotpr(wb, 1, tb, 1, &sumVT, vDSP_Length(tcount))
            }
        }
        let meanV = sumV / n
        let varV = sumV2 - n * meanV * meanV
        let stdV = sqrt(max(0, varV))
        let denom = stdV * Double(tVar)
        guard denom > 1e-8 else { return -1 }
        let cov = Double(sumVT) - n * meanV * Double(tMean)
        return max(-1, min(1, cov / denom))
    }

    // MARK: - 工具

    /// 构建灰度积分图 + 平方积分图（各 (w+1)×(h+1)，首行首列全 0）。
    /// 构建成本 O(w·h)，一次；此后任意窗口 Σv / Σv² 均 O(1) 查表。
    private static func buildIntegral(_ gray: [Float], w: Int, h: Int) -> (sum: [Float], sq: [Float]) {
        let stride = w + 1
        var sum = [Float](repeating: 0, count: stride * (h + 1))
        var sq = [Float](repeating: 0, count: stride * (h + 1))
        for y in 0..<h {
            let cur = (y + 1) * stride
            let prev = y * stride
            let src = y * w
            for x in 0..<w {
                let v = gray[src + x]
                let i = cur + x + 1
                sum[i] = v + sum[i - 1] + sum[prev + x + 1] - sum[prev + x]
                sq[i] = v * v + sq[i - 1] + sq[prev + x + 1] - sq[prev + x]
            }
        }
        return (sum, sq)
    }

    /// 积分图矩形窗口求和：I[y+th][x+tw] − I[y][x+tw] − I[y+th][x] + I[y][x]
    private static func boxSum(_ integral: [Float], w: Int,
                               x: Int, y: Int, tw: Int, th: Int) -> Float {
        let stride = w + 1
        let a = y * stride + x
        return integral[a + th * stride + tw]
             - integral[a + th * stride]
             - integral[a + tw]
             + integral[a]
    }

    /// CGImage → 灰度 Float（0..1），行主序
    private static func grayFloatPixels(_ img: CGImage) -> [Float]? {
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h),
                 byTiling: false)
        return bytes.map { Float($0) * Self.inv255f }
    }

    /// CGImage → 缩放到目标尺寸的灰度 Float（0..1），行主序
    private static func scaledGrayFloatPixels(_ img: CGImage, targetW: Int, targetH: Int) -> [Float]? {
        guard targetW > 0, targetH > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: targetW * targetH)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: targetW, height: targetH,
                                  bitsPerComponent: 8, bytesPerRow: targetW,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return bytes.map { Float($0) * Self.inv255f }
    }

    /// 接地：把一张被裁出的小地图 CGImage 缩放到统一模板边长并输出灰度字节（0..255）
    /// 供定位器 `locate(template:...)` 消费。任何一步失败返回 nil。
    static func minimapBytes(from img: CGImage, side: Int) -> [UInt8]? {
        guard let f = scaledGrayFloatPixels(img, targetW: side, targetH: side) else { return nil }
        return f.map { UInt8(min(255, max(0, Int($0 * 255.0)))) }
    }

    /// 模板灰度 → Float + 均值
    private static func templateFloat(_ t: [UInt8], tw: Int, th: Int) -> ([Float], Float)? {
        guard tw * th <= t.count, tw > 0, th > 0 else { return nil }
        let f = t.prefix(tw * th).map { Float($0) * Self.inv255f }
        let mean = f.reduce(0.0, +) / Float(f.count)
        return (f, mean)
    }

    /// 双线性缩放模板（行主序 Float 0..1）到 (toW×toH)。
    /// 多档匹配时模板按 scale 比例缩小，必须与 matchOneScale 的图档像素对齐。
    /// P 修复：改用**双线性**（而非旧最近邻/floor）——最近邻在缩小 150→23px 这类
    /// 大比例时会把高频细节压缩成整块伪影（走样），而地图档是 ImageIO 高质量
    /// 缩略（平滑），两者频谱不匹配 → 小档上 NCC 峰被削到 ~0.36 甚至漏检。
    /// 双线性与地图的平滑缩略同源，峰恢复 ~0.74（实测）。成本可忽略（模板 ≤150²）。
    private static func resizeTemplate(_ t: [Float], fromW: Int, fromH: Int,
                                       toW: Int, toH: Int) -> [Float]? {
        guard fromW > 0, fromH > 0, toW > 0, toH > 0,
              t.count >= fromW * fromH else { return nil }
        var out = [Float](repeating: 0, count: toW * toH)
        // 双线性：目标像素映射到源坐标（连续），取 2×2 邻域加权
        let sx = fromW > 1 ? Double(fromW - 1) / Double(max(1, toW - 1)) : 0
        let sy = fromH > 1 ? Double(fromH - 1) / Double(max(1, toH - 1)) : 0
        for y in 0..<toH {
            let fy = Double(y) * sy
            let y0 = min(fromH - 1, Int(fy))
            let y1 = min(fromH - 1, y0 + 1)
            let wy = fy - Double(y0)
            let row0 = y0 * fromW
            let row1 = y1 * fromW
            for x in 0..<toW {
                let fx = Double(x) * sx
                let x0 = min(fromW - 1, Int(fx))
                let x1 = min(fromW - 1, x0 + 1)
                let wx = fx - Double(x0)
                let v00 = t[row0 + x0]
                let v01 = t[row0 + x1]
                let v10 = t[row1 + x0]
                let v11 = t[row1 + x1]
                let top = v00 * Float(1 - wx) + v01 * Float(wx)
                let bot = v10 * Float(1 - wx) + v11 * Float(wx)
                out[y * toW + x] = top * Float(1 - wy) + bot * Float(wy)
            }
        }
        return out
    }

    /// 把缩放的模板转成 (Float, mean) 元组（供 matchOneScale 的 tMean/tVar 使用）
    private static func centeredTemplate(_ t: [Float], side: Int) -> ([Float], Float)? {
        guard side > 0, t.count >= side * side else { return nil }
        let mean = t.reduce(0.0, +) / Float(t.count)
        return (t, mean)
    }

    private static func sumSqErr(_ a: [Float], mean: Float) -> Double {
        var s = 0.0
        for v in a {
            let d = v - mean
            s += Double(d * d)
        }
        return s
    }

    // MARK: - 合成自检

    /// 合成自检：真实地模拟「屏幕小地图 → 定位」。
    /// 在某一参考尺度下，取一个"屏幕小地图"（原图 `templateSide/scale` 的范围缩放到
    /// `templateSide`），喂给 locate 后，返回的原图中心应回到裁剪中心附近，
    /// 从而证明 降采样 / 坐标换算 / 多档选择 自洽。
    func runSelfTest(expectedX: Double, expectedY: Double,
                     templateSide: Int = 150) -> String {
        guard !scales.isEmpty,
              let fine = scales.max(by: { $0.scale < $1.scale }),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return "SELFTEST FAIL: 未准备/无法读地图/无匹配档"
        }
        let fw = full.width, fh = full.height
        // "屏幕小地图"边长固定 templateSide（匹配图坐标）；对应原图范围 = templateSide / scale
        let srcSpan = Int(Double(templateSide) / fine.scale + 0.5)
        let half = srcSpan / 2
        let cx = min(max(0, Int(expectedX)), fw - 1)
        let cy = min(max(0, Int(expectedY)), fh - 1)
        let rx = min(max(0, cx - half), fw - srcSpan)
        let ry = min(max(0, cy - half), fh - srcSpan)
        guard let cropped = full.cropping(to: CGRect(x: rx, y: ry, width: srcSpan, height: srcSpan)),
              let tpl = Self.scaledGrayFloatPixels(cropped, targetW: templateSide, targetH: templateSide) else {
            return "SELFTEST FAIL: 模板构造失败"
        }
        let tmplBytes = tpl.map { UInt8(min(255, max(0, Int($0 * 255.0)))) }
        let expectCx = Double(rx) + Double(srcSpan) / 2
        let expectCy = Double(ry) + Double(srcSpan) / 2
        let res = locate(template: tmplBytes, tw: templateSide, th: templateSide, scoreThreshold: 0.5)
        guard res.found else { return "SELFTEST FAIL: 未命中 (score=\(res.score))" }
        let dx = res.x - expectCx
        let dy = res.y - expectCy
        let err = sqrt(dx * dx + dy * dy)
        // 容忍：降采样四舍五入 + 平滑。主档 ~0.09x 下 1 匹配像素≈11 原图px，给 300 余量
        let pass = err <= 300
        return "SELFTEST \(pass ? "PASS" : "FAIL") err=\(String(format: "%.1f", err))px " +
               "expected=\(Int(expectCx)),\(Int(expectCy)) got=\(Int(res.x)),\(Int(res.y)) " +
               "score=\(String(format: "%.3f", res.score)) 档#\(res.scaleIndex)"
    }
}