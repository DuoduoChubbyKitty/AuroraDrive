// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
// MinimapTileCache.swift — 左上角小地图瓦片缓存
//
// 坐标语义移植自参考项目 MaaNTE/agent/custom/action/Navi/coordinate_position.py：
//   COORDINATE_MAP_SIZE = (11264, 11264)，底图 bigworldmapSecond.png 即此尺寸。
//   NetworkPacketCapture 抓包解码后经标定变换输出的 point.x/y ∈ [0, 11264) 像素。
//
// 本类把 11264×11264 底图预切成 8×8=64 块（每块 1408×1408），并各自缩到
// minimapPx×minimapPx 缓存。小地图只显示角色当前所在瓦片（局部放大视图，
// 与参考 MapLocator.MINI_MAP_ROI 的"局部小地图"语义一致），瓦片切换 = 数组索引 O(1)。
//
// 切图在后台 utility 队列一次性完成；主线程（30Hz tick / SwiftUI body）只读缓存，
// 绝不重复解码大图——11264 PNG 解码百毫秒级，放热路径必卡顿。
// ============================================================================

import AppKit
import SwiftUI

final class MinimapTileCache: ObservableObject {

    // MARK: 常量（来源：参考项目坐标系 + 用户需求）

    /// 参考项目 COORDINATE_MAP_SIZE：游戏世界→地图像素的变换目标尺寸。
    static let mapPixelSize: Int = 11264
    /// 用户需求：把地图切成 8×8 = 64 块。
    static let tilesPerSide: Int = 8
    /// 单瓦片像素尺寸 = 11264 / 8。
    static let tilePixelSize: Int = mapPixelSize / tilesPerSide
    /// 小地图显示边长（pt）。
    static let minimapPx: CGFloat = 200

    // MARK: 状态（主线程读写）

    /// 64 块预缩瓦片，索引 [row * tilesPerSide + col]，已缩到 minimapPx×minimapPx。
    @Published private(set) var tiles: [CGImage?] = Array(repeating: nil, count: tilesPerSide * tilesPerSide)

    /// 全图缩略图（无网络定位时兜底，让小地图始终是可用地图，而非空白）。
    @Published private(set) var overview: CGImage?

    /// 切图完成标志。
    @Published private(set) var isReady = false

    /// 加载失败原因（nil = 未失败）。UI 占位时展示，避免静默失败。
    @Published private(set) var loadError: String?

    /// 全图加载耗时（ms），用于自检与性能观测。
    @Published private(set) var loadMs: Double = 0

    // MARK: 私有

    private let ioQueue = DispatchQueue(label: "aurora.minimap.tileio", qos: .utility)
    /// 防重入：ensureLoaded 只生效一次。
    private var didLoad = false

    // MARK: 对外接口

    /// 触发后台切图。幂等，重复调用无副作用。应在小地图 onAppear 时调用。
    func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        ioQueue.async { [weak self] in
            self?.buildTiles()
        }
    }

    /// 取角色像素坐标所在瓦片的预缩图。越界/未就绪返回 nil。
    /// O(1)：纯数组索引。
    func tileAt(mapPixelX: Double, mapPixelY: Double) -> CGImage? {
        guard isReady else { return nil }
        let col = Self.tileIndex(mapPixelX)
        let row = Self.tileIndex(mapPixelY)
        return tiles[row * Self.tilesPerSide + col]
    }

    /// 角色在当前瓦片内的相对偏移（0~minimapPx），用于画光标。
    static func inTileOffset(mapPixel: Double) -> CGFloat {
        let r = mapPixel.truncatingRemainder(dividingBy: Double(tilePixelSize))
        return CGFloat(r / Double(tilePixelSize)) * minimapPx
    }

    /// 像素坐标→瓦片索引（夹紧到 [0, tilesPerSide-1]）。
    static func tileIndex(mapPixel: Double) -> Int {
        let clamped = min(max(mapPixel, 0), Double(mapPixelSize - 1))
        let v = Int(clamped) / tilePixelSize
        return min(max(v, 0), tilesPerSide - 1)
    }

    // MARK: 后台切图（非主线程）

    private func buildTiles() {
        let t0 = Date()
        guard let url = resolveMapURL() else {
            DispatchQueue.main.async { [weak self] in
                self?.loadError = "未找到 bigworldmapSecond.png（11264×11264 底图）"
            }
            return
        }
        guard let full = loadFullCGImage(url: url) else {
            DispatchQueue.main.async { [weak self] in
                self?.loadError = "底图解码失败：\(url.lastPathComponent)"
            }
            return
        }

        // 全图缩略（无定位兜底）。
        let ov = downscale(full, to: Int(Self.minimapPx))

        // 64 块：cropping 取 1408×1408 子图 → 缩到 200×200。
        // CGImage cropping 的矩形坐标系原点在左上、y 向下，与参考项目 pixelY 语义一致。
        var arr: [CGImage?] = Array(repeating: nil, count: Self.tilesPerSide * Self.tilesPerSide)
        for row in 0..<Self.tilesPerSide {
            for col in 0..<Self.tilesPerSide {
                let rect = CGRect(x: col * Self.tilePixelSize,
                                  y: row * Self.tilePixelSize,
                                  width: Self.tilePixelSize,
                                  height: Self.tilePixelSize)
                if let crop = full.cropping(to: rect) {
                    arr[row * Self.tilesPerSide + col] = downscale(crop, to: Int(Self.minimapPx))
                }
            }
        }

        let ms = Date().timeIntervalSince(t0) * 1000
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overview = ov
            self.tiles = arr
            self.isReady = true
            self.loadMs = ms
        }
    }

    // MARK: 辅助

    /// 解析底图路径。优先级：开发机源码目录 → 可执行文件旁 → Bundle 资源。
    /// 覆盖交付场景：根目录裸可执行文件运行时 cwd 不确定，故多级回退。
    private func resolveMapURL() -> URL? {
        let candidates: [String] = [
            "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png",
            "/Users/Shared/AuroraDrive/bigworldmapSecond.png",
            Bundle.main.path(forResource: "bigworldmapSecond", ofType: "png") ?? "",
            Bundle.main.path(forResource: "map", ofType: "png") ?? "",
        ]
        return candidates
            .compactMap { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 加载完整底图为 CGImage。后台线程调用。
    private func loadFullCGImage(url: URL) -> CGImage? {
        guard let ns = NSImage(contentsOfFile: url.path) else { return nil }
        var rect = CGRect.zero
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 将 CGImage 缩放到目标像素边长。使用高质量插值，预缩一次供热路径复用。
    private func downscale(_ src: CGImage, to px: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: px,
                                  height: px,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage()
    }
}
