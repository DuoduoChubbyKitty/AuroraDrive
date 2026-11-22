// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapLocBridge.swift — 小地图视觉定位的 Swift 封装（OpenCV C 桥）
// ----------------------------------------------------------------------------
//  底层是 flow_bridge.h 的 ad_maploc_* 系列（CLAHE + 圆 mask matchTemplate），
//  已在独立 C++ 测试实测（2026-11-20，真实云游戏截图）：
//    · create（13056² 降采样4 + CLAHE）：23.5ms 一次性
//    · global 全局定位：~330ms 一次性（首次/跟丢重定位）
//    · track  局部跟踪：3.1~3.6ms/帧（400² 窗口，<7ms 红线）
//    · 坐标与 SIFT 交叉验证一致：(1236,1725)@1/4图 = (4944,6900)@全图
//
//  为什么不用同仓的 VisualLocator（纯 Swift NCC）：
//    它是无 hint 时多档全图扫描的慢路径（P修复注释自述会卡死，靠粗档+stride 补），
//    且从未被接线（LocateContext.visualLocator 恒 nil）。本桥走 OpenCV
//    matchTemplate + 圆 mask，实测才算准（无 mask 时坐标跑偏，见 flow_bridge.h）。
// ============================================================================

import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import OpenCVFlow

/// 小地图视觉定位器（线程模型：实例串行使用，内部无锁）。
final class MapLocBridge {

    /// 桥返回的坐标在「降采样图」上，乘 downscale 回到 13056 全图坐标。
    private(set) var downscale: Int = 4
    private var ctx: UnsafeMutableRawPointer? = nil
    private let mapWidth: Int      // 全图宽（像素）
    private let mapHeight: Int     // 全图高（像素）

    /// 定位结果（全图 13056 坐标系）。
    struct Result {
        var found: Bool = false
        var x: Double = 0   // 全图像素坐标
        var y: Double = 0
        var score: Double = 0
    }

    /// - Parameter mapPath: 大地图 jpg/png 路径（生产 models/bigworldmap-13056.jpg）。
    /// - Returns: nil = 初始化失败（文件不可读/尺寸非法/桥创建失败）。
    init?(mapPath: String, downscale: Int = 4) {
        // C 桥参数是 int32：越界值会被静默截断成错误比例（审查 2026-11-20）。
        guard (1...1000).contains(downscale) else { return nil }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        guard let gray = Self.grayBytes(from: img) else { return nil }
        self.mapWidth = w
        self.mapHeight = h
        self.downscale = max(1, downscale)
        gray.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            ctx = ad_maploc_create(base, Self.cInt(w), Self.cInt(w), Self.cInt(h),
                                   Self.cInt(self.downscale))
        }
        guard ctx != nil else { return nil }
    }

    deinit {
        if let c = ctx { ad_maploc_destroy(c) }
    }

    var isReady: Bool { ctx != nil }

    /// 全图尺寸（像素）。
    var fullMapSize: (width: Int, height: Int) { (mapWidth, mapHeight) }

    // MARK: - 定位入口

    /// 全局重定位（慢，~330ms。首次/跟丢后调用）。
    /// - Parameter minimap: 小地图 CGImage（任意尺寸，内部统一转 150² 灰度）。
    func globalLocate(minimap: CGImage) -> Result {
        guard let c = ctx, let tpl = Self.minimapTemplate(minimap) else { return Result() }
        return tpl.bytes.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return Result() }
            let r = ad_maploc_global(c, base, Self.cInt(tpl.side), Self.cInt(tpl.side))
            return Self.convert(r, downscale: downscale)
        }
    }

    /// 每帧局部跟踪（快，~3.5ms。用上一帧位置做 hint）。
    /// - Parameters:
    ///   - minimap: 小地图 CGImage。
    ///   - hint: 上一帧全图坐标（本类型 Result 的 x/y）。首次传 nil 走全局。
    ///   - window: 局部窗口边长（降采样坐标系，生产 400）。
    /// - Parameter allowGlobalFallback: 无 hint 时是否退化到全图搜索（`ad_maploc_global`
    ///   ~330ms 级）。⚠️ 2026-11-21 评审抓出：逐帧 worker 里同步跑全局搜索会堵住
    ///   唯一定位 worker（实测 8/8 超 7ms 红线，最大 357~715ms），期间新帧全被跳过。
    ///   逐帧路径必须传 **false**（无 hint 就返回空，由独立限频任务补做全局定位）；
    ///   只有那个独立任务传 true。
    func track(minimap: CGImage, hint: (x: Double, y: Double)?, window: Int = 400,
               allowGlobalFallback: Bool = true) -> Result {
        guard let c = ctx, let tpl = Self.minimapTemplate(minimap) else { return Result() }
        return tpl.bytes.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return Result() }
            let r: AD_MapLocResult
            if let hint = hint {
                // 全图坐标 → 降采样坐标
                let hx = hint.x / Double(downscale), hy = hint.y / Double(downscale)
                r = ad_maploc_track(c, base, Self.cInt(tpl.side), Self.cInt(tpl.side),
                                    hx, hy, Self.cInt(window))
            } else if allowGlobalFallback {
                r = ad_maploc_global(c, base, Self.cInt(tpl.side), Self.cInt(tpl.side))
            } else {
                // 逐帧路径无 hint：不做全局搜索，本帧无定位（等独立任务收敛）。
                return Result()
            }
            return Self.convert(r, downscale: downscale)
        }
    }

    // MARK: - 换算

    private static func convert(_ r: AD_MapLocResult, downscale: Int) -> Result {
        guard r.valid != 0 else { return Result() }
        return Result(found: true,
                      x: r.x * Double(downscale),
                      y: r.y * Double(downscale),
                      score: r.score)
    }

    // MARK: - 像素提取

    /// 小地图模板：150² 灰度字节（与桥验证口径一致）。
    private static let templateSide = 150

    /// 本帧 ROI 在 13056 大图上的实测宽度，仅供覆盖层。
    /// 定位器持有期间可与 track 并行。两条路径只读同一份大图，各自分配匹配缓冲。
    func measureGuideSpan(minimap: CGImage, at result: Result) -> Double? {
        guard result.found, let ctx, let template = Self.minimapTemplate(minimap) else { return nil }
        let scale = Double(downscale)
        let span = template.bytes.withUnsafeBufferPointer {
            ad_maploc_measure_span(ctx, $0.baseAddress, Self.cInt(template.side),
                                   result.x / scale, result.y / scale)
        }
        return span > 0 ? span * scale : nil
    }

    private static func minimapTemplate(_ img: CGImage) -> (bytes: [UInt8], side: Int)? {
        let side = templateSide
        guard let bytes = grayBytes(from: img, targetW: side, targetH: side) else { return nil }
        return (bytes, side)
    }

    /// CGImage → 灰度字节（可带缩放）。stride == width。
    private static func grayBytes(from img: CGImage, targetW: Int? = nil, targetH: Int? = nil) -> [UInt8]? {
        let w = targetW ?? img.width
        let h = targetH ?? img.height
        guard w > 0, h > 0, w * h <= 400_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    /// Swift Int → C int 的显式窄化（桥参数全是 int32；大图 13056 远在范围内）。
    private static func cInt(_ v: Int) -> Int32 { Int32(truncatingIfNeeded: v) }

    // MARK: - 纯 CPU 像素转换（零 CoreImage / 零 Metal）

    private static let bgraColorSpace = CGColorSpaceCreateDeviceRGB()

    /// 从采集端自持的 32BGRA 缓冲构造 CPU 图像。Provider 保持只读映射与缓冲所有权，
    /// 直到最后一个图像引用销毁。保留输入 stride，池不会在读者仍持有时复用该帧。
    nonisolated static func cgImageFromBGRA(_ pb: CVPixelBuffer) -> CGImage? {
        let pw = CVPixelBufferGetWidth(pb)
        let ph = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard pw > 0, ph > 0, pw <= stride / 4,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            return nil
        }
        let retained = Unmanaged.passRetained(pb)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: base, size: stride * ph,
                                            releaseData: { info, _, _ in
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(info!).takeRetainedValue()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            retained.release()
            return nil
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: bgraColorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - 圆形小地图自动标定（免手工 ROI）

    /// 整帧里检测到的圆形小地图（像素坐标）。
    struct DetectedCircle {
        var cx: Double
        var cy: Double
        var r: Double
    }

    /// 在灰度图里检测圆形小地图（HoughCircles，C 桥实现，无状态）。
    /// 视觉模式启动期自动标定用（gmw 的圆形校准思路）。
    /// - Parameters:
    ///   - regionGray: 输入图。isRegion=true 时须是「左上 30%×35%」裁剪区
    ///     （CaptureEngine.minimapCalibRegionROINorm 1:1 拷出），返回值即整帧坐标。
    ///   - frameW: 整帧宽（C 侧半径窗按它缩放；区域输入时传 regionW/0.30 反推值）。
    static func detectCircle(regionGray: CGImage, isRegion: Bool, frameW: Int) -> DetectedCircle? {
        let w = regionGray.width, h = regionGray.height
        guard w >= 64, h >= 64, let gray = grayBytes(from: regionGray) else { return nil }
        return gray.withUnsafeBufferPointer { p -> DetectedCircle? in
            guard let base = p.baseAddress else { return nil }
            let r = ad_maploc_detect_circle(base, cInt(w), cInt(w), cInt(h),
                                            cInt(isRegion ? 1 : 0), cInt(frameW))
            guard r.valid != 0 else { return nil }
            return DetectedCircle(cx: r.cx, cy: r.cy, r: r.r)
        }
    }
}
