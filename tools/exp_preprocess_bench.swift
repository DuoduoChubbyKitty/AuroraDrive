// ============================================================================
//  exp_preprocess_bench.swift — 引擎每帧「预处理 + 装配」成本实测
//
//  【为什么必须单独测这一块】
//    CoreML 侧实测（exp_exec_bench）：enc p50 0.59ms + ctl p50 1.60ms = 2.19ms。
//    但 `InferenceEngineV2.infer()` 每帧还要做**两件 CoreML 之外的重活**：
//      ① preprocessImage：CGImage 缩放绘制 + 逐像素 RGBA→CHW 重排 + vDSP 归一化
//         （InferenceEngineV2.swift:1881-1926，180×320×3 = 172,800 次逐元素写）
//      ② 特征装配：makeSplitProvider 里把 [8×256] 写进 MLMultiArray
//         （+ lane 25,600 / dets 240 / state 8）
//    ⚠️ 本文件**逐位复刻** preprocessImage 的算法（同一份逻辑），因为原函数是
//       `private`。若原函数改动，本基准须同步——这是它的已知局限。
//
//  【测什么】
//    · preprocessImage 单帧耗时（min / p50 / p95）
//    · featSeq 装配耗时（[8×256] 写入）
//    · lane 装配耗时（160×160）
//    · 三者之和 = 每帧 CoreML 之外的开销
//
//  用法：swiftc -O exp_preprocess_bench.swift -o /tmp/exp_pre_bench && /tmp/exp_pre_bench
// ============================================================================

import Foundation
import CoreGraphics
import Accelerate

let H = 180, W = 320
let LANE = 160, FEAT = 256, NFRAMES = 8

func log(_ s: String) { print(s); fflush(stdout) }

// ───────────────────────── 合成画面（复刻自 makeSyntheticImage）─────────────────────────
func makeSyntheticImage(w: Int, h: Int, frameIndex: Int) -> CGImage? {
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let base = UInt8((x * 255 / max(1, w - 1)))
            let shift = UInt8((frameIndex * 8 + y / 4) % 64)
            pixels[i]     = base &+ shift
            pixels[i + 1] = UInt8((y * 255 / max(1, h - 1)))
            pixels[i + 2] = UInt8(128)
            pixels[i + 3] = 255
        }
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: .init(rawValue: bitmapInfo),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

// ───────────────────────── 逐位复刻 preprocessImage（InferenceEngineV2.swift:1881）─────────
@inline(never)
func preprocessImage(_ cgImage: CGImage, height: Int, width: Int,
                     into output: inout [Float32]) -> Bool {
    let bytesPerRow = width * 4
    var pixelData = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: &pixelData, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
    }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let planeSize = height * width
    output.withUnsafeMutableBufferPointer { ptr in
        let p = ptr.baseAddress!
        for y in 0..<height {
            for x in 0..<width {
                let pixelIdx = (y * width + x) * 4
                let outIdx = y * width + x
                p[outIdx]                 = Float32(pixelData[pixelIdx])
                p[planeSize + outIdx]     = Float32(pixelData[pixelIdx + 1])
                p[planeSize * 2 + outIdx] = Float32(pixelData[pixelIdx + 2])
            }
        }
        var divisor: Float32 = 255.0
        vDSP_vsdiv(p, 1, &divisor, p, 1, vDSP_Length(3 * planeSize))
    }
    return true
}

// ───────────────────────── 特征/lane 装配 ─────────────────────────
@inline(never)
func assembleFeatSeq(_ src: [Float32], into dst: inout [Float32]) {
    let n = NFRAMES * FEAT
    for i in 0..<n { dst[i] = src[i] }
}

@inline(never)
func assembleLane(_ src: [Float32], into dst: inout [Float32]) {
    let n = LANE * LANE
    for i in 0..<n { dst[i] = src[i] }
}

// ───────────────────────── 计时 ─────────────────────────
func stats(_ xs: [Double]) -> (Double, Double, Double, Double) {
    let s = xs.sorted()
    let p = { (q: Double) -> Double in s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))] }
    return (s[0], p(0.5), p(0.95), s.max() ?? 0)
}

func bench(_ label: String, iters: Int = 300, _ body: () -> Void) {
    for _ in 0..<30 { body() }                     // warmup
    var ts: [Double] = []
    ts.reserveCapacity(iters)
    for _ in 0..<iters {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        ts.append(Double(t1 - t0) / 1_000_000.0)
    }
    let (mn, p50, p95, mx) = stats(ts)
    log(String(format: "  %-34@ min=%7.3f  p50=%7.3f  p95=%7.3f  max=%7.3f  (ms)",
               label as NSString, mn, p50, p95, mx))
}

// ───────────────────────── main ─────────────────────────
log("═══════════════════════════════════════════════════════════════════")
log("每帧「CoreML 之外」的开销实测（Swift 原生，逐位复刻引擎算法）")
log("═══════════════════════════════════════════════════════════════════")

guard let img = makeSyntheticImage(w: 640, h: 360, frameIndex: 0) else {
    log("FATAL 合成画面失败"); exit(2)
}
log("  输入画面: 640×360 → 缩放到 \(W)×\(H)")
log("  主机负载: \(String(format: "%.2f", Double(ProcessInfo.processInfo.systemUptime > 0 ? 0 : 0)))")

var preOut = [Float32](repeating: 0, count: 3 * H * W)
var featSrc = [Float32](repeating: 0.5, count: NFRAMES * FEAT)
var featDst = [Float32](repeating: 0, count: NFRAMES * FEAT)
var laneSrc = [Float32](repeating: 1.0, count: LANE * LANE)
var laneDst = [Float32](repeating: 0, count: LANE * LANE)

bench("① preprocessImage (CGImage→CHW)") {
    _ = preprocessImage(img, height: H, width: W, into: &preOut)
}
bench("② featSeq 装配 [8×256]") {
    assembleFeatSeq(featSrc, into: &featDst)
}
bench("③ lane 装配 [160×160]") {
    assembleLane(laneSrc, into: &laneDst)
}
bench("④ ①②③ 合计（每帧引擎侧开销）") {
    _ = preprocessImage(img, height: H, width: W, into: &preOut)
    assembleFeatSeq(featSrc, into: &featDst)
    assembleLane(laneSrc, into: &laneDst)
}

log("")
log("  参考：CoreML 侧实测（exp_exec_bench, Swift 原生）")
log("    enc (ANE)  p50 0.59  p95 0.95")
log("    ctl (ANE)  p50 1.60  p95 5.04")
log("    串联       p50 2.19  p95 5.99")
log("")
log("  ⟹ 每帧总成本 = 上表合计 + 2.19ms(CoreML 串联)")
log("═══════════════════════════════════════════════════════════════════")
