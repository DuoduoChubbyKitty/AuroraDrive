// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import Accelerate

struct LocatorScale {
    let scale: Double
    let width: Int
    let height: Int
    let gray: [Float]
    let luminanceMean: Float
    let integral: [Float]
    let integralSq: [Float]
}

struct LocateResult {
    var found: Bool = false
    var x: Double = 0
    var y: Double = 0
    var score: Double = 0
    var scaleIndex: Int = 0
}

final class VisualLocator {

    private let mapPath: String
    private var workSizes: [CGFloat]

    private var scales: [LocatorScale] = []

    private var wasLastCentered = false
    private var lastSmoothX: Double = 0
    private var lastSmoothY: Double = 0
    private let smoothAlpha: Double

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

    var scaleCount: Int { scales.count }

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
            let opts = [
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
                Self.tryAppendScale(thumb: thumb, originWidth: originWidth, to: &built)
            }
        }
        // P修复：NCC峰宽~2px、stride=16跨峰顶漏检；追加全局粗扫档，仅当最粗档仍远大于192时追加（防小图重复建档）
        if let coarsest = built.min(by: { $0.scale < $1.scale }),
           coarsest.width > Int(Self.globalScanSize * 1.4) {
            let opts = [
                kCGImageSourceThumbnailMaxPixelSize: Self.globalScanSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
                Self.tryAppendScale(thumb: thumb, originWidth: originWidth, to: &built)
            }
        }
        guard !built.isEmpty else { return "VisualLocator: 未能生成任何匹配档" }
        scales = built
        return nil
    }

    private static func tryAppendScale(thumb: CGImage, originWidth: Int, to built: inout [LocatorScale]) {
        let w = thumb.width, h = thumb.height
        guard w > 8, h > 8 else { return }
        guard let chunk = Self.grayFloatPixels(thumb) else { return }
        let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
        let ints = Self.buildIntegral(chunk, w: w, h: h)
        built.append(LocatorScale(scale: Double(w) / Double(originWidth),
                                  width: w, height: h,
                                  gray: chunk, luminanceMean: mean,
                                  integral: ints.sum, integralSq: ints.sq))
    }

    private static let globalScanSize: CGFloat = 192
    private nonisolated static let inv255f: Float = 1.0 / 255.0
    private nonisolated static func floatToUInt8(_ f: Float) -> UInt8 { UInt8(min(255, max(0, Int(f * 255.0)))) }

    // MARK: - 定位

    func locate(template: [UInt8], tw: Int, th: Int,
                scoreThreshold: Double = 0.80) -> LocateResult {
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

        let sumSq = Double(Self.sumSqErr(tF, mean: tMean))
        let tVar = Float(sqrt(sumSq))
        guard tVar > 1e-6 else { return LocateResult() }

        let perStd = sqrt(sumSq / Double(tw * th))
        guard perStd >= 0.02 else { return LocateResult() }

        var best = LocateResult()
        best.score = -1

        var hint: (x: Double, y: Double)? = nil
        if wasLastCentered {
            hint = (lastSmoothX, lastSmoothY)
        }

        // P修复：无hint时最细档全图粗扫~1.1亿次NCC内循环会卡死；模板150px是finest档，更粗档需按scale缩小否则NCC永远低分
        guard let finest = scales.max(by: { $0.scale < $1.scale }) else { return best }

        if hint == nil {
            guard let coarse = scales.min(by: { $0.scale < $1.scale }) else { return best }
            let coarseSide = max(8, Int((Double(tw) * coarse.scale / finest.scale).rounded()))
            guard let coarseT = Self.resizeTemplate(tF, fromW: tw, fromH: th, toW: coarseSide, toH: coarseSide),
                  let (coarseF, coarseM) = Self.centeredTemplate(coarseT, side: coarseSide) else { return best }
            let coarseVar = Float(sqrt(Self.sumSqErr(coarseF, mean: coarseM)))
            let coarseResult = Self.matchOneScale(scale: coarse,
                                                  template: coarseF, tMean: coarseM, tVar: coarseVar,
                                                  tw: coarseSide, th: coarseSide, hintPixel: nil,
                                                  strideOverride: 2)
            if coarseResult.found {
                let hintX = (coarseResult.x + Double(coarseSide) / 2) / coarse.scale
                let hintY = (coarseResult.y + Double(coarseSide) / 2) / coarse.scale
                hint = (hintX, hintY)
                best = coarseResult
                best.scaleIndex = scales.firstIndex(where: { $0.scale == coarse.scale }) ?? 0
            } else {
                wasLastCentered = false
                return best
            }
        }

        for (si, scale) in scales.enumerated() {
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
            if CommandLine.arguments.contains("--locate-live") {
                FileHandle.standardError.write("[LOCATELIVE-DIAG] threshold reject found=\(best.found) score=\(String(format: "%.3f", best.score)) thr=\(String(format: "%.2f", scoreThreshold))\n".data(using: .utf8)!)
            }
            best.found = false
            wasLastCentered = false
            return best
        }

        let bestScale = scales[best.scaleIndex]
        let bestSide = max(8, Int((Double(tw) * bestScale.scale / finest.scale).rounded()))
        let px = (best.x + Double(bestSide) / 2) / bestScale.scale
        let py = (best.y + Double(bestSide) / 2) / bestScale.scale

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

    func reset() {
        wasLastCentered = false
        lastSmoothX = 0
        lastSmoothY = 0
    }

    // MARK: - 单档匹配

    private static func matchOneScale(scale: LocatorScale,
                                      template tF: [Float], tMean: Float, tVar: Float,
                                      tw: Int, th: Int,
                                      hintPixel: (Double, Double)?,
                                      strideOverride: Int? = nil) -> LocateResult {
        let sw = scale.width, sh = scale.height
        let tcount = tw * th
        guard tcount > 0, sw >= tw, sh >= th else { return LocateResult() }
        var work = [Float](repeating: 0, count: tcount)

        var x0 = 0, y0 = 0, x1 = sw - tw, y1 = sh - th
        if let (hx, hy) = hintPixel {
            let r: Double = 120
            x0 = max(0, Int(hx.rounded()) - Int(r))
            x1 = min(sw - tw, Int(hx.rounded()) + Int(r))
            y0 = max(0, Int(hy.rounded()) - Int(r))
            y1 = min(sh - th, Int(hy.rounded()) + Int(r))
        }
        guard x1 >= x0, y1 >= y0 else { return LocateResult() }

        // P修复：NCC峰宽~2px、stride=16跨峰漏检；全局扫必须stride=2（strideOverride传入）

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

    private static func nccAt(scale: LocatorScale, template tF: [Float], tMean: Float, tVar: Float,
                              tw: Int, th: Int, tcount: Int,
                              startX: Int, startY: Int, rowBase: Int,
                              work: inout [Float]) -> Double {
        let sw = scale.width
        let n = Double(tcount)
        let sumV = Double(boxSum(scale.integral, w: sw, x: startX, y: startY, tw: tw, th: th))
        let sumV2 = Double(boxSum(scale.integralSq, w: sw, x: startX, y: startY, tw: tw, th: th))
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

    private static func boxSum(_ integral: [Float], w: Int,
                               x: Int, y: Int, tw: Int, th: Int) -> Float {
        let stride = w + 1
        let a = y * stride + x
        return integral[a + th * stride + tw]
             - integral[a + th * stride]
             - integral[a + tw]
             + integral[a]
    }

    private static func grayFloatPixels(_ img: CGImage, targetW: Int? = nil, targetH: Int? = nil) -> [Float]? {
        let w = targetW ?? img.width, h = targetH ?? img.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        if targetW != nil { ctx.interpolationQuality = .high }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h),
                 byTiling: targetH == nil)
        return bytes.map { Float($0) * Self.inv255f }
    }

    // P4优化：直接在灰度图中写入UInt8，跳过Float32中转分配（~22.5KB）。
    static func minimapBytes(from img: CGImage, side: Int) -> [UInt8]? {
        let w = side, h = side
        var bytes = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    private static func templateFloat(_ t: [UInt8], tw: Int, th: Int) -> ([Float], Float)? {
        guard tw * th <= t.count, tw > 0, th > 0 else { return nil }
        let f = t.prefix(tw * th).map { Float($0) * Self.inv255f }
        let mean = f.reduce(0.0, +) / Float(f.count)
        return (f, mean)
    }

    private static func resizeTemplate(_ t: [Float], fromW: Int, fromH: Int,
                                       toW: Int, toH: Int) -> [Float]? {
        guard fromW > 0, fromH > 0, toW > 0, toH > 0,
              t.count >= fromW * fromH else { return nil }
        var out = [Float](repeating: 0, count: toW * toH)
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

    func runSelfTest(expectedX: Double, expectedY: Double,
                     templateSide: Int = 150) -> String {
        guard !scales.isEmpty,
              let fine = scales.max(by: { $0.scale < $1.scale }),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return "SELFTEST FAIL: 未准备/无法读地图/无匹配档"
        }
        let fw = full.width, fh = full.height
        let srcSpan = Int(Double(templateSide) / fine.scale + 0.5)
        let half = srcSpan / 2
        let cx = min(max(0, Int(expectedX)), fw - 1)
        let cy = min(max(0, Int(expectedY)), fh - 1)
        let rx = min(max(0, cx - half), fw - srcSpan)
        let ry = min(max(0, cy - half), fh - srcSpan)
        guard let cropped = full.cropping(to: CGRect(x: rx, y: ry, width: srcSpan, height: srcSpan)),
              let tpl = Self.grayFloatPixels(cropped, targetW: templateSide, targetH: templateSide) else {
            return "SELFTEST FAIL: 模板构造失败"
        }
        let tmplBytes = tpl.map(Self.floatToUInt8)
        let expectCx = Double(rx) + Double(srcSpan) / 2
        let expectCy = Double(ry) + Double(srcSpan) / 2
        let res = locate(template: tmplBytes, tw: templateSide, th: templateSide, scoreThreshold: 0.5)
        guard res.found else { return "SELFTEST FAIL: 未命中 (score=\(res.score))" }
        let dx = res.x - expectCx
        let dy = res.y - expectCy
        let err = sqrt(dx * dx + dy * dy)
        let pass = err <= 300
        return "SELFTEST \(pass ? "PASS" : "FAIL") err=\(String(format: "%.1f", err))px " +
               "expected=\(Int(expectCx)),\(Int(expectCy)) got=\(Int(res.x)),\(Int(res.y)) " +
               "score=\(String(format: "%.3f", res.score)) 档#\(res.scaleIndex)"
    }
}
