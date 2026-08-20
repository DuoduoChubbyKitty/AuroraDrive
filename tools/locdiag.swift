import Foundation
import CoreGraphics
import ImageIO

// 复现 VisualLocator.prepare() 的档构建 + 模板 + ncc
let mapPath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
      let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("FAIL: 无法读地图"); exit(1)
}
print("full", full.width, "x", full.height)

// 与 prepare() 一致：ImageIO 缩略
func grayFloatPixels(_ img: CGImage) -> [Float] {
    let w = img.width, h = img.height
    var bytes = [UInt8](repeating: 0, count: w * h)
    let cs = CGColorSpaceCreateDeviceGray()
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w, space: cs,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h), byTiling: false)
    return bytes.map { Float($0) / 255.0 }
}

let workSizes: [CGFloat] = [1280, 1024, 768]
var scales: [(scale: Double, gray: [Float])] = []
for target in workSizes {
    let opts = [kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
        let w = thumb.width, h = thumb.height
        scales.append((scale: Double(w) / Double(full.width), gray: grayFloatPixels(thumb)))
        print("scale target=\(Int(target)) -> \(w)x\(h) scale=\(String(format: "%.4f", Double(w)/Double(full.width)))")
    }
}

// 模板：原图 (6200,5100) 1320px crop → 150
func scaledGray(_ img: CGImage, _ tw: Int, _ th: Int) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: tw * th)
    let ctx = CGContext(data: &bytes, width: tw, height: th, bitsPerComponent: 8,
                        bytesPerRow: tw, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: tw, height: th))
    return bytes.map { Float($0) / 255.0 }
}

let spanPx = 1320
let hx = min(max(0, 6200 - spanPx / 2), full.width - spanPx)
let hy = min(max(0, 5100 - spanPx / 2), full.height - spanPx)
guard let block = full.cropping(to: CGRect(x: hx, y: hy, width: spanPx, height: spanPx)) else {
    print("FAIL crop"); exit(1)
}
let tpl = scaledGray(block, 150, 150)
print("template mean", tpl.reduce(0,+) / Float(tpl.count))

// 最近邻缩放模板
func resizeNearest(_ t: [Float], _ fromW: Int, _ fromH: Int, _ toW: Int, _ toH: Int) -> [Float] {
    var out = [Float](repeating: 0, count: toW * toH)
    for y in 0..<toH {
        let sy = min(fromH - 1, (y * fromH) / toH)
        for x in 0..<toW {
            let sx = min(fromW - 1, (x * fromW) / toW)
            out[y * toW + x] = t[sy * fromW + sx]
        }
    }
    return out
}

// NCC 单点
func ncc(_ scale: [Float], _ sw: Int, _ tw: Int, _ th: Int, _ x: Int, _ y: Int,
         _ tF: [Float], _ tMean: Float, _ tVar: Float) -> Double {
    var sumV = 0.0, sumV2 = 0.0, sumVT = 0.0
    for r in 0..<th {
        let rowBase = (y + r) * sw + x
        let tb = r * tw
        for c in 0..<tw {
            let v = Double(scale[rowBase + c])
            let t = Double(tF[tb + c])
            sumV += v; sumV2 += v*v; sumVT += v*t
        }
    }
    let n = Double(tw*th)
    let meanV = sumV / n
    let varV = sumV2 - n*meanV*meanV
    let stdV = sqrt(max(0, varV))
    let denom = stdV * Double(tVar)
    guard denom > 1e-8 else { return -1 }
    let cov = sumVT - n*meanV*Double(tMean)
    return max(-1, min(1, cov/denom))
}

// 逐档探针：模板缩到 scaledSide，在真实位置算 NCC
let finest = scales.max { $0.scale < $1.scale }!.scale
for s in scales {
    let side = Int(round(Double(150) * s.scale / finest))
    let tS = resizeNearest(tpl, 150, 150, side, side)
    let tMean = tS.reduce(0,+) / Float(tS.count)
    let sqErr = tS.reduce(0.0) { $0 + Double(($1 - tMean) * ($1 - tMean)) }
    let tVar = Float(sqrt(sqErr))
    let sw = Int(sqrt(Double(s.gray.count)))
    // 真实位置
    let cx = Int(round(Double(6200) * s.scale)) - side/2
    let cy = Int(round(Double(5100) * s.scale)) - side/2
    let sc = s.gray
    let v = ncc(sc, sw, side, side, max(0,cx), max(0,cy), tS, tMean, tVar)
    print(String(format: "scale=%.4f scaledSide=%d NCC@true=%.3f", s.scale, side, v))
}

// 全图粗扫(步长16) at 最粗档 768，复现 locate() 首帧路径
if let coarseScale = scales.min(by: { $0.scale < $1.scale }) {
    let side = Int(round(Double(150) * coarseScale.scale / finest))
    // 双线性缩放模板（真双线性）
    var tS = [Float](repeating: 0, count: side * side)
    let tH = Int(sqrt(Double(tpl.count)))
    for y in 0..<side {
        let fy = Double(y) * Double(tH - 1) / Double(side - 1)
        let y0 = Int(floor(fy)), y1 = min(tH - 1, y0 + 1)
        let wy = fy - Double(y0)
        for x in 0..<side {
            let fx = Double(x) * Double(tH - 1) / Double(side - 1)
            let x0 = Int(floor(fx)), x1 = min(tH - 1, x0 + 1)
            let wx = fx - Double(x0)
            let v = (tpl[y0 * tH + x0] * Float(1 - wx) * Float(1 - wy))
                  + (tpl[y0 * tH + x1] * Float(wx) * Float(1 - wy))
                  + (tpl[y1 * tH + x0] * Float(1 - wx) * Float(wy))
                  + (tpl[y1 * tH + x1] * Float(wx) * Float(wy))
            tS[y * side + x] = v
        }
    }
    let tMean = tS.reduce(0,+) / Float(tS.count)
    let sqErr = tS.reduce(0.0) { $0 + Double(($1 - tMean) * ($1 - tMean)) }
    let tVar = Float(sqrt(sqErr))
    let sw = Int(sqrt(Double(coarseScale.gray.count)))
    let sc = coarseScale.gray
    let sh = sw
    var best: (Double, Int, Int) = (-1, 0, 0)
    var y = 0
    while y <= sh - side {
        var x = 0
        while x <= sw - side {
            let v = ncc(sc, sw, side, side, x, y, tS, tMean, tVar)
            if v > best.0 { best = (v, x, y) }
            x += 16
        }
        y += 16
    }
    print(String(format: "粗扫@768(双线性模板) best=%.3f at (%d,%d)", best.0, best.1, best.2))
    // 真实位置(378,303)附近逐像素扫描，测量峰宽
    var pxvals: [Double] = []
    let pcx = 377, pcy = 302
    for dx in -30...30 {
        let v = ncc(sc, sw, side, side, pcx + dx, pcy, tS, tMean, tVar)
        pxvals.append(v)
    }
    print("横向峰宽(中心30px内>0.5数):", pxvals.filter { $0 > 0.5 }.count, "max:", String(format: "%.3f", pxvals.max()!))
}

// 双线性缩放辅助（从 Float 数组）
func scaledGray(fromTpl t: [Float]) -> [Float] { t }

// 测试更粗档的峰宽：384 / 256
let tplFine = tpl  // 150px 模板（覆盖 1320 orig px）
print("=== 峰宽 vs 档位（模板覆盖 1320 orig px） ===")
for target: CGFloat in [768, 512, 384, 256] {
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceThumbnailMaxPixelSize: target,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
    let w = thumb.width, h = thumb.height
    let sc = Double(w) / Double(full.width)
    let gray = grayFloatPixels(thumb)
    let sw = w
    // 模板缩到该档
    let side = Int(round(Double(150) * sc / finest))
    var tS2 = [Float](repeating: 0, count: side * side)
    let tH = 150
    for y in 0..<side {
        let fy = Double(y) * Double(tH - 1) / Double(side - 1)
        let y0 = Int(floor(fy)), y1 = min(tH - 1, y0 + 1)
        let wy = fy - Double(y0)
        for x in 0..<side {
            let fx = Double(x) * Double(tH - 1) / Double(side - 1)
            let x0 = Int(floor(fx)), x1 = min(tH - 1, x0 + 1)
            let wx = fx - Double(x0)
            tS2[y * side + x] = (tpl[y0*tH+x0]*Float(1-wx)*Float(1-wy))
                              + (tpl[y0*tH+x1]*Float(wx)*Float(1-wy))
                              + (tpl[y1*tH+x0]*Float(1-wx)*Float(wy))
                              + (tpl[y1*tH+x1]*Float(wx)*Float(wy))
        }
    }
    let tM = tS2.reduce(0,+) / Float(tS2.count)
    let sE = tS2.reduce(0.0) { $0 + Double(($1 - tM) * ($1 - tM)) }
    let tV = Float(sqrt(sE))
    let pcx = Int(round(Double(6200) * sc)) - side/2
    let pcy = Int(round(Double(5100) * sc)) - side/2
    // 峰宽：横向 >0.5 的像素数
    var cnt = 0, mx = -1.0
    for dx in -40...40 {
        let v = ncc(gray, sw, side, side, pcx + dx, pcy, tS2, tM, tV)
        if v > mx { mx = v }
        if v > 0.5 { cnt += 1 }
    }
    print(String(format: "target=%d -> %dx%d scale=%.4f scaledSide=%d 峰宽(>0.5)=%d max=%.3f",
                 Int(target), w, h, sc, side, cnt, mx))
}

// 测试：更粗档 stride-2 全局扫描能否命中（128/160/192/256 档）
print("=== 更粗档全局 stride-2 粗扫（验证低阶全局扫不丢峰） ===")
for target: CGFloat in [256, 192, 160, 128] {
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceThumbnailMaxPixelSize: target,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
    let w = thumb.width, h = thumb.height
    let sc = Double(w) / Double(full.width)
    let gray = grayFloatPixels(thumb)
    let sw = w
    let side = Int(round(Double(150) * sc / finest))
    let span = 1320
    let hx = min(max(0, 6200 - span/2), full.width - span)
    let hy = min(max(0, 5100 - span/2), full.height - span)
    guard let block = full.cropping(to: CGRect(x: hx, y: hy, width: span, height: span)) else { continue }
    let tD = scaledGray(block, side, side)
    let tM = tD.reduce(0,+) / Float(tD.count)
    let sE = tD.reduce(0.0) { $0 + Double(($1 - tM) * ($1 - tM)) }
    let tV = Float(sqrt(sE))
    var best: (Double, Int, Int) = (-1, 0, 0)
    var y = 0
    while y <= h - side {
        var x = 0
        while x <= w - side {
            let v = ncc(gray, sw, side, side, x, y, tD, tM, tV)
            if v > best.0 { best = (v, x, y) }
            x += 2
        }
        y += 2
    }
    let trueX = Int(round(6200*sc))-side/2, trueY = Int(round(5100*sc))-side/2
    let dist = sqrt(Double(best.1-trueX)*Double(best.1-trueX) + Double(best.2-trueY)*Double(best.2-trueY))
    print(String(format: "target=%d side=%d stride2: best=%.3f@(%d,%d) 真实(%d,%d) 距=%.1fpx",
                 Int(target), side, best.0, best.1, best.2, trueX, trueY, dist))
}

// 复现 runLocateStep 的「屏幕模板」路径：从合成屏幕 CGImage 裁 ROI → 150 灰度模板
// → 192 档 stride-2 全局扫，验证与直接地图模板是否等价。
print("=== 屏幕模板路径（runLocateStep 等价） ===")
if let screenCG = CGImageSourceCreateWithURL(URL(fileURLWithPath: "/tmp/locatelive_screen.png") as CFURL, nil),
   let screenImg = CGImageSourceCreateImageAtIndex(screenCG, 0, nil) {
    let sW = screenImg.width, sH = screenImg.height
    let sidePt = Int((Double(min(sW, sH)) * 0.16).rounded())
    let cxPx = Int(CGFloat(sW) * 0.13)
    let cyPx = Int(CGFloat(sH) * 0.14)
    let roX0 = min(max(0, cxPx - sidePt / 2), sW)
    let roY0 = min(max(0, cyPx - sidePt / 2), sH)
    let roX1 = min(max(0, cxPx + sidePt / 2), sW)
    let roY1 = min(max(0, cyPx + sidePt / 2), sH)
    let rect = CGRect(x: CGFloat(roX0), y: CGFloat(roY0),
                      width: CGFloat(roX1 - roX0), height: CGFloat(roY1 - roY0))
    print("ROI rect:", rect)
    if let crop = screenImg.cropping(to: rect) {
        let tplS = scaledGray(crop, 150, 150)
        let tM = tplS.reduce(0,+) / Float(tplS.count)
        print("screen template mean:", tM)
        // 192 档
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            let w = thumb.width, h = thumb.height
            let sc = Double(w) / Double(full.width)
            let gray = grayFloatPixels(thumb)
            let sw = w
            let side = max(8, Int((Double(150) * sc / finest).rounded()))
            let tS2 = resizeNearest(tplS, 150, 150, side, side)
            let tM2 = tS2.reduce(0,+) / Float(tS2.count)
            let sE2 = tS2.reduce(0.0) { $0 + Double(($1 - tM2) * ($1 - tM2)) }
            let tV2 = Float(sqrt(sE2))
            var best: (Double, Int, Int) = (-1, 0, 0)
            var y = 0
            while y <= h - side {
                var x = 0
                while x <= w - side {
                    let v = ncc(gray, sw, side, side, x, y, tS2, tM2, tV2)
                    if v > best.0 { best = (v, x, y) }
                    x += 2
                }
                y += 2
            }
            let trueX = Int(round(6200*sc))-side/2, trueY = Int(round(5100*sc))-side/2
            print(String(format: "screen 模板 192: best=%.3f@(%d,%d) 真实(%d,%d) 距=%.1fpx",
                         best.0, best.1, best.2, trueX, trueY,
                         sqrt(Double(best.1-trueX)*Double(best.1-trueX) + Double(best.2-trueY)*Double(best.2-trueY))))
        }
    }
}




