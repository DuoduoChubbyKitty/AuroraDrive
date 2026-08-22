// test_final.swift - Avoids Swift -O crash by using single array
import Foundation
import CoreGraphics
import ImageIO

struct PreprocessParams {
    static let circlePadding: Int = 11
    static let saturationMax: UInt8 = 66
    static let valueMax: UInt8 = 80
    static let grayAlignOffset: UInt8 = 3
}

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func extractBGRFromCGImage(_ img: CGImage) -> [UInt8]? {
    guard let provider = img.dataProvider, let data = provider.data else { return nil }
    let ptr = CFDataGetBytePtr(data as CFData)
    if ptr == nil { return nil }
    let w = Int(img.width), h = Int(img.height)
    let bpr = Int(img.bytesPerRow)
    var bgr = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        let rowPtr = ptr! + y * bpr
        for x in 0..<w {
            let srcOff = x * 4
            let dstOff = (y * w + x) * 3
            bgr[dstOff]     = rowPtr[srcOff + 2]
            bgr[dstOff + 1] = rowPtr[srcOff + 1]
            bgr[dstOff + 2] = rowPtr[srcOff]
        }
    }
    return bgr
}

func resizeBGRNearest(bgr: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: dw * dh * 3)
    for y in 0..<dh {
        let sy = (y * sh) / dh
        for x in 0..<dw {
            let sx = (x * sw) / dw
            let dOff = (y * dw + x) * 3
            let sOff = (sy * sw + sx) * 3
            result[dOff]     = bgr[sOff]
            result[dOff + 1] = bgr[sOff + 1]
            result[dOff + 2] = bgr[sOff + 2]
        }
    }
    return result
}

func rgbToHSV(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h: Float = 0
    if d > 1e-6 && d.isFinite && mx.isFinite {
        if mx == r { h = 60 * ((g - b) / d) }
        else if mx == g { h = 60 * (2 + (b - r) / d) }
        else { h = 60 * (4 + (r - g) / d) }
        if h < 0 { h += 360 }
        if !h.isFinite { h = 0 }
    }
    let s = mx > 1e-6 ? (d / mx) * 255 : 0
    return (h, s, mx)
}

// FIXED: Use a single packed array (HHHSSSVVV...) to avoid multiple large allocations
// This also improves cache locality
func buildHSVFromBGR(bgr: [UInt8], w: Int, h: Int) -> ([UInt8], [UInt8], [UInt8]) {
    let total = w * h
    // Pack H,S,V into a single array: [H0,S0,V0, H1,S1,V1, ...]
    var packed = [UInt8](repeating: 0, count: total * 3)
    
    // Process pixel by pixel
    for i in 0..<total {
        let b = Float(bgr[i * 3])
        let g = Float(bgr[i * 3 + 1])
        let r = Float(bgr[i * 3 + 2])
        let (hh, ss, vv) = rgbToHSV(r: r, g: g, b: b)
        
        // Clamp using bitwise operations to avoid potential overflow
        let hInt = Int(hh.rounded())
        let sInt = Int(ss.rounded())
        let vInt = Int(vv.rounded())
        
        var hVal = hInt & 0xFF // Keep lower 8 bits (safe since hInt is always >=0 after clamp in rgbToHSV)
        if hVal > 359 { hVal = 359 }
        
        var sVal = sInt & 0xFF
        if sVal > 255 { sVal = 255 }
        
        var vVal = vInt & 0xFF
        if vVal > 255 { vVal = 255 }
        
        let pIdx = i * 3
        packed[pIdx] = UInt8(hVal)
        packed[pIdx + 1] = UInt8(sVal)
        packed[pIdx + 2] = UInt8(vVal)
    }
    
    // Split into separate arrays
    var H = [UInt8](repeating: 0, count: total)
    var S = [UInt8](repeating: 0, count: total)
    var V = [UInt8](repeating: 0, count: total)
    for i in 0..<total {
        H[i] = packed[i * 3]
        S[i] = packed[i * 3 + 1]
        V[i] = packed[i * 3 + 2]
    }
    return (H, S, V)
}

func createCircleMask(size: (Int, Int), padding: Int) -> [UInt8] {
    let (w, h) = size
    var mask = [UInt8](repeating: 255, count: w * h)
    let cx = Double(w - 1) / 2.0
    let cy = Double(h - 1) / 2.0
    let radius = Double(min(w, h) - padding) / 2.0
    let rSq = radius * radius
    for y in 0..<h {
        let dy = Double(y) - cy
        let dy2 = dy * dy
        for x in 0..<w {
            let dx = Double(x) - cx
            if dx * dx + dy2 > rSq { mask[y * w + x] = 0 }
        }
    }
    return mask
}

func applyHSVFilter(h: [UInt8], s: [UInt8], v: [UInt8],
                    satMax: UInt8, valMax: UInt8) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: h.count)
    for i in 0..<h.count {
        out[i] = (s[i] <= satMax && v[i] <= valMax) ? 255 : 0
    }
    return out
}

func bitwiseAnd(a: [UInt8], b: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: a.count)
    for i in 0..<a.count { out[i] = a[i] & b[i] }
    return out
}

func subtractConstant(g: [UInt8], constant: UInt8) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: g.count)
    for i in 0..<g.count {
        if g[i] >= constant { out[i] = g[i] - constant }
    }
    return out
}

func stats(_ pixels: [UInt8]) -> (mean: Float, std: Float, nonzero: Int, minVal: UInt8, maxVal: UInt8) {
    var nz = 0, sum = 0, mn = UInt8(255), mx = UInt8(0)
    for b in pixels {
        if b > 0 { nz += 1; sum += Int(b) }
        if b < mn { mn = b }
        if b > mx { mx = b }
    }
    let m = nz > 0 ? Float(sum) / Float(nz) : 0
    var sqDiff: Double = 0
    for b in pixels {
        if b > 0 { let d = Double(Int(b)) - Double(m); sqDiff += d * d }
    }
    let sd = nz > 1 ? Float(Foundation.sqrt(sqDiff / Double(nz - 1))) : 0
    return (m, sd, nz, mn, mx)
}

func preprocessMinimapDirect(bgr: [UInt8], side: Int) -> [UInt8]? {
    let w = side, h = side
    let (H, S, V) = buildHSVFromBGR(bgr: bgr, w: w, h: h)
    let mask = createCircleMask(size: (w, h), padding: PreprocessParams.circlePadding)
    let colorMask = applyHSVFilter(h: H, s: S, v: V,
                                   satMax: PreprocessParams.saturationMax,
                                   valMax: PreprocessParams.valueMax)
    let combinedMask = bitwiseAnd(a: colorMask, b: mask)
    let miniGray = bitwiseAnd(a: V, b: combinedMask)
    return subtractConstant(g: miniGray, constant: PreprocessParams.grayAlignOffset)
}

func main() {
    print("=== Final Test ===")
    
    // Synthetic test
    print("\n=== 合成图测试 ===")
    let TW = 64, TH = 64
    var testData = [UInt8](repeating: 0, count: TW * TH * 3)
    let rng = 42
    for y in 0..<TH {
        for x in 0..<TW {
            let idx = (y * TW + x) * 3
            let isCenter = (x - TW/2) * (x - TW/2) + (y - TH/2) * (y - TH/2) < (TW/3) * (TW/3)
            if isCenter {
                let gray = UInt8(30 + ((rng + x * 3 + y * 7) % 40))
                testData[idx] = gray
                testData[idx + 1] = UInt8(min(255, gray + 3))
                testData[idx + 2] = UInt8(min(255, gray + 6))
            } else {
                testData[idx] = 200; testData[idx + 1] = 200; testData[idx + 2] = 200
            }
        }
    }
    if let result = preprocessMinimapDirect(bgr: testData, side: TW) {
        let (m, sd, nz, mn, mx) = stats(result)
        let pct = Double(nz) / Double(result.count)
        print("  mean=\(String(format:"%.1f",m)) std=\(String(format:"%.2f",sd)) range=[\(mn),\(mx)] nonzero=\(nz)/\(result.count)")
        print("  有效像素比: \(String(format:"%.0f",pct*100))%")
        if pct > 0.30 && sd > 5 {
            print("  OK")
        } else {
            print("  WARN")
        }
    }
    
    // NTE screenshots
    print("\n=== NTE 截图测试 ===")
    let screenshots = [
        "/tmp/nte_test_screenshots/nte_driving1.jpg",
        "/tmp/nte_test_screenshots/nte_driving2.jpg",
        "/tmp/nte_test_screenshots/nte_city.jpg",
        "/tmp/nte_test_screenshots/nte_dream1.jpg",
        "/tmp/nte_test_screenshots/nte_dream2.jpg",
    ]
    
    for path in screenshots {
        let basename = (path as NSString).lastPathComponent
        guard let img = loadImage(path) else {
            print("SKIP \(basename)")
            continue
        }
        let iw = Int(img.width), ih = Int(img.height)
        print("\n--- \(basename) (\(iw)x\(ih)) ---")
        
        let bgr = extractBGRFromCGImage(img)!
        let res = resizeBGRNearest(bgr: bgr, sw: iw, sh: ih, dw: 150, dh: 150)
        
        if let final = preprocessMinimapDirect(bgr: res, side: 150) {
            let (m, sd, nz, mn, mx) = stats(final)
            let pct = Double(nz) / Double(final.count)
            print("  MaaNTE: mean=\(String(format:"%.1f",m)) std=\(String(format:"%.1f",sd))")
            print("    range=[\(mn),\(mx)] nonzero=\(nz)/\(final.count) (\(String(format:"%.0f",pct*100))%)")
        }
    }
    
    print("\n=== 完成 ===")
}

main()
