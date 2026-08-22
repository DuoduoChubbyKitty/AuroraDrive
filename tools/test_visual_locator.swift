// NTE 视觉定位预处理 + 定位测试
// 编译：swift test_visual_locator.swift（仅用 stdlib + CoreGraphics + ImageIO + Accelerate）
import Foundation
import CoreGraphics
import ImageIO
import Accelerate

// ---- 预处理参数（来自 MaaNTE map_locator.py）----
struct PreprocessParams {
    static let circlePadding: Int = 11
    static let saturationMax: UInt8 = 66
    static let valueMax: UInt8 = 80
    static let grayAlignOffset: UInt8 = 3
}

// ---- 数据结构 ----
struct LocateResult {
    var found: Bool = false
    var x: Double = 0
    var y: Double = 0
    var score: Double = 0
}

struct LocatorScale {
    let scale: Double
    let width: Int
    let height: Int
    let gray: [Float]
    let luminanceMean: Float
    let integral: [Float]
    let integralSq: [Float]
}

// ---- 工具常量（仅一处声明）----
private let inv255f: Float = 1.0 / 255.0
private let globalScanSize: CGFloat = 192

// ---- 预处理管线 ----

func convertToBGR(_ img: CGImage, size: (Int, Int)) -> [UInt8]? {
    let w = size.0, h = size.1
    var b = [UInt8](repeating: 0, count: w * h * 3)
    guard let ctx = CGContext(data: &b, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 3,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo.byteOrderDefault.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return b
}

func rgbToHSV(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn, v = mx
    var h: Float = 0
    if d > 1e-6 {
        if mx == r { h = 60 * ((g - b) / d) }
        else if mx == g { h = 60 * (2 + (b - r) / d) }
        else { h = 60 * (4 + (r - g) / d) }
        if h < 0 { h += 360 }
    }
    return (h, mx > 1e-6 ? (d / mx) * 255 : 0, v * 255)
}

func convertToHSV(_ img: CGImage, size: (Int, Int)) -> ([UInt8], [UInt8], [UInt8])? {
    let w = size.0, h = size.1
    guard let bgr = convertToBGR(img, size: size) else { return nil }
    var H = [UInt8](repeating: 0, count: w * h)
    var S = [UInt8](repeating: 0, count: w * h)
    var V = [UInt8](repeating: 0, count: w * h)
    for i in 0..<w * h {
        let r = Float(bgr[i * 3 + 2]), g = Float(bgr[i * 3 + 1]), b = Float(bgr[i * 3])
        let (h_, s_, v_) = rgbToHSV(r, g, b)
        H[i] = UInt8(h_); S[i] = UInt8(s_); V[i] = UInt8(v_)
    }
    return (H, S, V)
}

func createCircleMask(size: (Int, Int), padding: Int) -> [UInt8] {
    let w = size.0, h = size.1
    var m = [UInt8](repeating: 0, count: w * h)
    let r = min(w, h) / 2 - padding
    for y in 0..<h {
        for x in 0..<w {
            let dx = x - w / 2, dy = y - h / 2
            if dx * dx + dy * dy <= r * r { m[y * w + x] = 255 }
        }
    }
    return m
}

func applyHSVFilter(hsvImg: ([UInt8], [UInt8], [UInt8]), satMax: UInt8, valMax: UInt8) -> [UInt8] {
    let (_, S, V) = hsvImg
    var m = [UInt8](repeating: 0, count: V.count)
    for i in 0..<V.count { if S[i] <= satMax && V[i] <= valMax { m[i] = 255 } }
    return m
}

func bitwiseAnd(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: a.count)
    for i in 0..<a.count { r[i] = a[i] & b[i] }
    return r
}

func subtractConstant(_ img: [UInt8], constant: UInt8) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: img.count)
    for i in 0..<img.count { if img[i] >= constant { r[i] = img[i] - constant } }
    return r
}

/// MaaNTE 预处理：HSV过滤 + 圆形掩码 + 灰度对齐
func preprocessMinimap(from img: CGImage, side: Int) -> [UInt8]? {
    guard let hsvImg = convertToHSV(img, size: (side, side)) else { return nil }
    let mask = createCircleMask(size: (side, side), padding: PreprocessParams.circlePadding)
    let colorMask = applyHSVFilter(hsvImg: hsvImg, satMax: PreprocessParams.saturationMax, valMax: PreprocessParams.valueMax)
    let combinedMask = bitwiseAnd(colorMask, mask)
    let vChannel = hsvImg.2
    let miniGray = bitwiseAnd(vChannel, combinedMask)
    return subtractConstant(miniGray, constant: PreprocessParams.grayAlignOffset)
}

/// 旧版灰度预处理（对比用）
func minimapBytes(from img: CGImage, side: Int) -> [UInt8]? {
    guard let f = scaledGrayFloatPixels(img, targetW: side, targetH: side) else { return nil }
    return f.map { UInt8(min(255, max(0, Int($0 * 255.0)))) }
}

// ---- 灰度/积分图工具 ----

func grayFloatPixels(_ img: CGImage) -> [Float]? {
    let w = img.width, h = img.height
    var bytes = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &bytes, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h), byTiling: false)
    return bytes.map { Float($0) * inv255f }
}

func scaledGrayFloatPixels(_ img: CGImage, targetW: Int, targetH: Int) -> [Float]? {
    guard targetW > 0, targetH > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: targetW * targetH)
    guard let ctx = CGContext(data: &bytes, width: targetW, height: targetH,
                              bitsPerComponent: 8, bytesPerRow: targetW,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    return bytes.map { Float($0) * inv255f }
}

func buildIntegral(_ gray: [Float], w: Int, h: Int) -> (sum: [Float], sq: [Float]) {
    let stride = w + 1
    var sum = [Float](repeating: 0, count: stride * (h + 1))
    var sq = [Float](repeating: 0, count: stride * (h + 1))
    for y in 0..<h {
        let cur = (y + 1) * stride, prev = y * stride, src = y * w
        for x in 0..<w {
            let v = gray[src + x], i = cur + x + 1
            sum[i] = v + sum[i - 1] + sum[prev + x + 1] - sum[prev + x]
            sq[i] = v * v + sq[i - 1] + sq[prev + x + 1] - sq[prev + x]
        }
    }
    return (sum, sq)
}

// ---- 模板工具 ----

func templateFloat(_ t: [UInt8], tw: Int, th: Int) -> ([Float], Float)? {
    guard tw * th <= t.count, tw > 0, th > 0 else { return nil }
    let f = t.prefix(tw * th).map { Float($0) * inv255f }
    return (f, f.reduce(0.0, +) / Float(f.count))
}

func centeredTemplate(_ t: [Float], side: Int) -> ([Float], Float)? {
    guard side > 0, t.count >= side * side else { return nil }
    return (t, t.reduce(0.0, +) / Float(t.count))
}

func sumSqErr(_ a: [Float], mean: Float) -> Double {
    var s = 0.0
    for v in a { let d = v - mean; s += Double(d * d) }
    return s
}

func resizeTemplate(_ t: [Float], fromW: Int, fromH: Int, toW: Int, toH: Int) -> [Float]? {
    guard fromW > 0, fromH > 0, toW > 0, toH > 0, t.count >= fromW * fromH else { return nil }
    var out = [Float](repeating: 0, count: toW * toH)
    let sx: Float = fromW > 1 ? Float(Double(fromW - 1) / Double(max(1, toW - 1))) : 0
    let sy: Float = fromH > 1 ? Float(Double(fromH - 1) / Double(max(1, toH - 1))) : 0
    for y in 0..<toH {
        let fy = Double(y) * Double(sy), y0 = min(fromH - 1, Int(fy)), y1 = min(fromH - 1, y0 + 1), wy = fy - Double(y0)
        let r0 = y0 * fromW, r1 = y1 * fromW
        for x in 0..<toW {
            let fx = Double(x) * Double(sx), x0 = min(fromW - 1, Int(fx)), x1 = min(fromW - 1, x0 + 1), wx = fx - Double(x0)
            let v00 = t[r0 + x0], v01 = t[r0 + x1], v10 = t[r1 + x0], v11 = t[r1 + x1]
            out[y * toW + x] = (v00 * Float(1 - wx) + v01 * Float(wx)) * Float(1 - wy)
                              + (v10 * Float(1 - wx) + v11 * Float(wx)) * Float(wy)
        }
    }
    return out
}

// ---- NCC 匹配 ----

func boxSum(_ integral: [Float], w: Int, x: Int, y: Int, tw: Int, th: Int) -> Float {
    let stride = w + 1
    let a = y * stride + x
    return integral[a + th * stride + tw] - integral[a + th * stride] - integral[a + tw] + integral[a]
}

func nccAt(scale: LocatorScale, template tF: [Float], tMean: Float, tVar: Float,
           tw: Int, th: Int, tcount: Int,
           startX: Int, startY: Int, rowBase: Int,
           work: inout [Float]) -> Double {
    let sw = scale.width, n = Double(tcount)
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
        tF.withUnsafeBufferPointer { t in
            vDSP_dotpr(w.baseAddress!, 1, t.baseAddress!, 1, &sumVT, vDSP_Length(tcount))
        }
    }
    let meanV = sumV / n
    let varV = sumV2 - n * meanV * meanV
    let stdV = sqrt(max(0.0, varV))
    let denom = stdV * Double(tVar)
    guard denom > 1e-8 else { return -1 }
    let cov = Double(sumVT) - n * meanV * Double(tMean)
    return max(-1, min(1, cov / denom))
}

func matchOneScale(scale: LocatorScale, template tF: [Float], tMean: Float, tVar: Float,
                   tw: Int, th: Int, hintPixel: (Double, Double)?,
                   strideOverride: Int? = nil) -> LocateResult {
    var best = LocateResult(); best.score = -1
    let sw = scale.width, sh = scale.height
    let tcount = tw * th
    guard tcount > 0, sw >= tw, sh >= th else { return best }
    var work = [Float](repeating: 0, count: tcount)
    var x0 = 0, y0 = 0, x1 = sw - tw, y1 = sh - th
    if let (hx, hy) = hintPixel {
        let r: Double = 120
        x0 = max(0, Int(hx.rounded()) - Int(r))
        x1 = min(sw - tw, Int(hx.rounded()) + Int(r))
        y0 = max(0, Int(hy.rounded()) - Int(r))
        y1 = min(sh - th, Int(hy.rounded()) + Int(r))
    }
    let stride = strideOverride ?? ((hintPixel != nil) ? 2 : 16)
    let topK = 8
    var candidates: [(score: Double, x: Int, y: Int)] = []
    func offer(_ s: Double, _ X: Int, _ Y: Int) {
        if candidates.count < topK {
            candidates.append((s, X, Y))
            if candidates.count == topK { candidates.sort { $0.score > $1.score } }
        } else if s > candidates[candidates.count - 1].score {
            candidates[candidates.count - 1] = (s, X, Y)
            var i = candidates.count - 2
            while i >= 0 && candidates[i].score < candidates[i + 1].score {
                candidates.swapAt(i, i + 1); i -= 1
            }
        }
    }
    var yy = y0
    while yy <= y1 {
        let rowBase = yy * sw
        var xx = x0
        while xx <= x1 {
            let ncc = nccAt(scale: scale, template: tF, tMean: tMean, tVar: tVar,
                            tw: tw, th: th, tcount: tcount,
                            startX: xx, startY: yy, rowBase: rowBase, work: &work)
            offer(ncc, xx, yy)
            xx += stride
        }
        yy += stride
    }
    guard !candidates.isEmpty else { return best }
    for cand in candidates {
        let d = stride - 1
        let fx0 = max(x0, cand.x - d), fx1 = min(x1, cand.x + d)
        let fy0 = max(y0, cand.y - d), fy1 = min(y1, cand.y + d)
        for cyy in fy0...fy1 {
            let rowBase = cyy * sw
            for cxx in fx0...fx1 {
                let ncc = nccAt(scale: scale, template: tF, tMean: tMean, tVar: tVar,
                                tw: tw, th: th, tcount: tcount,
                                startX: cxx, startY: cyy, rowBase: rowBase, work: &work)
                if ncc > best.score {
                    best = LocateResult(found: true, x: Double(cxx), y: Double(cyy), score: ncc)
                }
            }
        }
    }
    return LocateResult(found: best.found && best.score > -0.5 && best.score.isFinite,
                        x: best.x, y: best.y, score: best.score)
}

// ---- 定位器 ----

class VisualLocatorTest {
    private let mapPath: String
    private let workSizes: [CGFloat]
    private var scales: [LocatorScale] = []

    init(mapPath: String, workSizes: [CGFloat] = [1280, 1024, 768]) {
        self.mapPath = mapPath
        self.workSizes = workSizes
    }

    var scaleCount: Int { scales.count }
    var scaleWidths: [Int] { scales.map { $0.width } }

    func prepare() -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil) else { return "无法打开地图" }
        guard let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "无法解码地图" }
        for target in workSizes {
            guard target > 64 else { continue }
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                  let chunk = grayFloatPixels(thumb), thumb.width > 8, thumb.height > 8 else { continue }
            let ints = buildIntegral(chunk, w: thumb.width, h: thumb.height)
            let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
            scales.append(LocatorScale(scale: Double(thumb.width) / Double(full.width),
                                       width: thumb.width, height: thumb.height,
                                       gray: chunk, luminanceMean: mean,
                                       integral: ints.sum, integralSq: ints.sq))
        }
        if let coarsest = scales.min(by: { $0.scale < $1.scale }),
           coarsest.width > Int(globalScanSize * 1.4) {
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: globalScanSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                  let chunk = grayFloatPixels(thumb), thumb.width > 8, thumb.height > 8 else { return nil }
            let ints = buildIntegral(chunk, w: thumb.width, h: thumb.height)
            let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
            scales.append(LocatorScale(scale: Double(thumb.width) / Double(full.width),
                                       width: thumb.width, height: thumb.height,
                                       gray: chunk, luminanceMean: mean,
                                       integral: ints.sum, integralSq: ints.sq))
        }
        return nil
    }

    func locate(template: [UInt8], tw: Int, th: Int, scoreThreshold: Double = 0.5) -> LocateResult {
        guard let (tF, tMean) = templateFloat(template, tw: tw, th: th),
              !scales.isEmpty, tw >= 8, th >= 8 else { return LocateResult() }
        let tVar = Float(sqrt(sumSqErr(tF, mean: tMean)))
        guard tVar > 1e-6 else { return LocateResult() }
        let stdOverAll = sqrt(sumSqErr(tF, mean: tMean) / Double(tw * th))
        guard Double(stdOverAll) >= 0.02 else { return LocateResult() }
        var best = LocateResult(); best.score = -1
        guard let finest = scales.max(by: { $0.scale < $1.scale }) else { return best }
        if let coarse = scales.min(by: { $0.scale < $1.scale }) {
            let cs = max(8, Int((Double(tw) * coarse.scale / finest.scale).rounded()))
            guard let ct = resizeTemplate(tF, fromW: tw, fromH: th, toW: cs, toH: cs),
                  let (cf, cm) = centeredTemplate(ct, side: cs) else { return best }
            let coarseResult = matchOneScale(scale: coarse, template: cf, tMean: cm, tVar: Float(sqrt(sumSqErr(cf, mean: cm))),
                                             tw: cs, th: cs, hintPixel: nil, strideOverride: 2)
            if coarseResult.found && coarseResult.score > best.score {
                let hintX = (coarseResult.x + Double(cs) / 2) / coarse.scale
                let hintY = (coarseResult.y + Double(cs) / 2) / coarse.scale
                best = LocateResult(found: true, x: hintX, y: hintY, score: coarseResult.score)
                for scale in scales {
                    let ss = max(8, Int((Double(tw) * scale.scale / finest.scale).rounded()))
                    guard let st = resizeTemplate(tF, fromW: tw, fromH: th, toW: ss, toH: ss),
                          let (sf, sm) = centeredTemplate(st, side: ss) else { continue }
                    let r = matchOneScale(scale: scale, template: sf, tMean: sm, tVar: Float(sqrt(sumSqErr(sf, mean: sm))),
                                          tw: ss, th: ss, hintPixel: (hintX, hintY))
                    if r.found && r.score > best.score {
                        let px = (r.x + Double(ss) / 2) / scale.scale
                        let py = (r.y + Double(ss) / 2) / scale.scale
                        best = LocateResult(found: true, x: px, y: py, score: r.score)
                    }
                }
            } else {
                return best
            }
        }
        guard best.found, best.score >= scoreThreshold else { best.found = false; return best }
        return best
    }
}

// ---- 主测试 ----

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func stats(_ data: [UInt8]) -> (mean: Double, std: Double, nz: Int) {
    let n = Double(data.count)
    let m = Double(data.reduce(0, +)) / n
    var sq = 0.0
    var nz = 0
    for b in data {
        let d = Double(b) - m; sq += d * d
        if b > 0 { nz += 1 }
    }
    return (m, sqrt(sq / n), nz)
}

print("=== 异环视觉定位预处理测试 ===")

for (path, name) in [
    ("/tmp/nte_test_screenshots/nte_driving1.jpg", "异环驾驶截图1"),
    ("/tmp/nte_test_screenshots/nte_driving2.jpg", "异环驾驶截图2"),
    ("/tmp/nte_test_screenshots/nte_city.jpg", "异环城市截图"),
    ("/tmp/nte_test_screenshots/nte_dream1.jpg", "异环梦幻场景1"),
    ("/tmp/nte_test_screenshots/nte_dream2.jpg", "异环梦幻场景2"),
] {
    guard let img = loadImage(path) else { print("\(name): 加载失败"); continue }
    print("\n--- \(name) (\(img.width)x\(img.height)) ---")
    if let p = preprocessMinimap(from: img, side: 150) {
        let (m, sd, nz) = stats(p)
        print("  预处理(MaaNTE): mean=\(String(format: "%.1f", m)) std=\(String(format: "%.2f", sd)) nonzero=\(nz)/\(p.count) (\(String(format: "%.0f", Double(nz) / Double(p.count) * 100))%)")
    }
    if let o = minimapBytes(from: img, side: 150) {
        let (m, sd, _) = stats(o)
        print("  旧版灰度:       mean=\(String(format: "%.1f", m)) std=\(String(format: "%.2f", sd))")
    }
}

print("\n\n=== 定位器自检（合成坐标回测）===")
print("(地图 11264² 全量加载在 standalone Swift 中易 segfault，改为分块测试)")
let mapPath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"

// 用 ImageIO 逐档缩略加载（模拟生产代码 prepare() 行为）
func loadThumbnail(scale: CGFloat, from path: String) -> LocatorScale? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: scale,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
          let chunk = grayFloatPixels(thumb), thumb.width > 8, thumb.height > 8 else { return nil }
    let ints = buildIntegral(chunk, w: thumb.width, h: thumb.height)
    let mean = chunk.reduce(0.0, +) / Float(max(1, chunk.count))
    return LocatorScale(scale: Double(thumb.width) / Double(full.width),
                        width: thumb.width, height: thumb.height,
                        gray: chunk, luminanceMean: mean,
                        integral: ints.sum, integralSq: ints.sq)
}

var scales: [LocatorScale] = []
for target in [1280.0, 1024.0, 768.0] {
    if let s = loadThumbnail(scale: target, from: mapPath) { scales.append(s) }
}
print("定位器就绪，\(scales.count)档匹配图")

if scales.isEmpty { print("无匹配档，跳过定位测试"); print("\n测试完成"); exit(0) }

let finestW = scales.map { $0.width }.max()!
let finestScale = scales.max(by: { $0.scale < $1.scale })!
let fullScale = finestScale.scale
let spanPx = Int((150.0 / fullScale).rounded())
print("最细档宽度=\(finestW)px scale=\(String(format: "%.4f", fullScale)) → 模板 spanPx=\(spanPx)px")

func loadBlock(at x: Int, y: Int, size: Int, from path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let hx = max(0, min(full.width - size, x - size / 2))
    let hy = max(0, min(full.height - size, y - size / 2))
    return full.cropping(to: CGRect(x: hx, y: hy, width: size, height: size))
}

let candidates = [
    (6200, 5100, "候选A_中心区"),
    (4000, 4500, "候选B_西北"),
    (7800, 8200, "候选C_东南"),
    (5200, 2600, "候选D_东北"),
]
for (cx, cy, label) in candidates {
    guard let block = loadBlock(at: cx, y: cy, size: spanPx, from: mapPath) else { continue }
    guard let pb = preprocessMinimap(from: block, side: 150),
          let ob = minimapBytes(from: block, side: 150) else { continue }
    func locate(template: [UInt8]) -> LocateResult {
        guard let (tF, tMean) = templateFloat(template, tw: 150, th: 150) else { return LocateResult() }
        let tVar = Float(Foundation.sqrt(sumSqErr(tF, mean: tMean)))
        guard tVar > 1e-6, Foundation.sqrt(sumSqErr(tF, mean: tMean) / Double(150 * 150)) >= 0.02 else { return LocateResult() }
        var best = LocateResult(); best.score = -1
        guard let finest = scales.max(by: { $0.scale < $1.scale }) else { return best }
        for scale in scales {
            let ss = max(8, Int((Double(150) * scale.scale / finest.scale).rounded()))
            guard let st = resizeTemplate(tF, fromW: 150, fromH: 150, toW: ss, toH: ss),
                  let (sf, sm) = centeredTemplate(st, side: ss) else { continue }
            let r = matchOneScale(scale: scale, template: sf, tMean: sm, tVar: Float(Foundation.sqrt(sumSqErr(sf, mean: sm))),
                                  tw: ss, th: ss, hintPixel: nil)
            if r.found && r.score > best.score {
                let px = (r.x + Double(ss) / 2) / scale.scale
                let py = (r.y + Double(ss) / 2) / scale.scale
                best = LocateResult(found: true, x: px, y: py, score: r.score)
            }
        }
        guard best.score >= 0.5 else { best.found = false; return best }
        return best
    }
    let pr = locate(template: pb)
    let or_ = locate(template: ob)
    let ddx = pr.x - Double(cx), ddy = pr.y - Double(cy)
    let pe = Foundation.sqrt(ddx * ddx + ddy * ddy)
    let oex = or_.x - Double(cx), oeY = or_.y - Double(cy)
    let oe = Foundation.sqrt(oex * oex + oeY * oeY)
    print("\n\(label): 期望(\(cx),\(cy))")
    print("  预处理: found=\(pr.found) score=\(String(format: "%.3f", pr.score)) 命中(\(Int(pr.x)),\(Int(pr.y))) err=\(String(format: "%.0f", pe))px")
    print("  旧版:   found=\(or_.found) score=\(String(format: "%.3f", or_.score)) 命中(\(Int(or_.x)),\(Int(or_.y))) err=\(String(format: "%.0f", oe))px")
}
print("\n测试完成")

