// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapLayers.swift — AuroraDrive 原生地图图层（路网 / 骨架 / POI）
// ============================================================================
//
//  【为什么要有这个文件】
//  原生大地图原先只画底图 + 标记。要把「我们自己的路网」叠上去，最直接的写法是
//  每帧遍历 1517 条折线逐条 stroke —— 那是网页版的死法（1517 次 draw call）。
//
//  本文件的策略：
//    ① 加载时**一次性**把 JSON 展平成地图像素空间的扁平点数组（之后不再解析 JSON）
//    ② 每条折线预先算好包围盒，每帧只做**视口剔除**
//    ③ 把「可见路网」渲染成**一张与底图同尺寸的 CGImage**，并按视野缓存
//       → 每帧只剩 1 次图片绘制，与折线数量无关
//
//  【坐标系】全部归一到 13056 地图像素空间（与 kCalib* 标定同一套）：
//    · roads.json       6528 空间  → ×2
//    · route_graph.json 13056 空间 → 原值
//    · poi.json         13056 空间 → 原值
//
//  【视口唯一来源】MapLayerViewport 是 cx/cy/spanPx 的**唯一**出处。
//  历史上出过「底图与标记各算一套比例」导致标记整体偏移的事故，
//  所以任何图层都必须吃同一个 MapLayerViewport，禁止自己再推一遍比例。
// ============================================================================

import Foundation
import CoreGraphics
import SwiftUI

// ============================================================================
// MARK: - 视口
// ============================================================================

/// 地图视口（地图像素空间）。所有图层共用同一个实例，保证对齐。
struct MapLayerViewport: Equatable {
    /// 视口中心（地图像素 X）
    let centerX: Double
    /// 视口中心（地图像素 Y）
    let centerY: Double
    /// 视口边长（地图像素）
    let spanPx: Double

    /// 视口覆盖的地图像素矩形
    var rect: CGRect {
        CGRect(x: centerX - spanPx / 2, y: centerY - spanPx / 2,
               width: spanPx, height: spanPx)
    }

    /// 地图像素 → 视口归一化坐标（0…1）
    @inline(__always)
    func normalized(x: Double, y: Double) -> CGPoint {
        CGPoint(x: (x - centerX) / spanPx + 0.5,
                y: (y - centerY) / spanPx + 0.5)
    }

    /// 量化到 4px 网格。
    ///
    /// 必须与 `MapTileCache.tile` 内部的量化规则**完全一致**：
    /// 底图是按量化后的视野裁的，叠加图层若按未量化视野渲染就会错位。
    var quantized: MapLayerViewport {
        MapLayerViewport(centerX: (centerX / 4).rounded() * 4,
                    centerY: (centerY / 4).rounded() * 4,
                    spanPx: (spanPx / 4).rounded() * 4)
    }

    /// 缓存键（量化后）
    /// 缓存键。
    ///
    /// ⚠️ 2026-10-04 修复：**必须含「数据世代」`gen`**。
    /// 事故经过：地图窗口的图层数据是**异步**加载的，第一帧 `roads == nil`，
    /// 于是画出一张**空图**并按视口为键缓存；等数据到位（实测 12.5ms 后）时
    /// **视口没变 → 命中缓存 → 永远返回那张空图**，路网再也不出现。
    /// （`--mc-map` 夹具是同步加载，第一帧就有数据，所以从没暴露这个问题。）
    /// 把数据世代编进键，数据一变键就变，旧空图自然作废。
    func cacheKey(outSize: CGFloat, flags: Int, gen: Int) -> String {
        let q = quantized
        return "\(Int(q.centerX))|\(Int(q.centerY))|\(Int(q.spanPx))|\(Int(outSize))|\(flags)|g\(gen)"
    }

    /// **底图瓦片**的缓存键。
    ///
    /// 与 `cacheKey(outSize:flags:gen:)` **同源**（都基于 `quantized`，量化规则
    /// 只有那一处实现），但底图不依赖图层开关与图层数据世代 —— 那两项对底图
    /// 恒为常量，编进键里只会让"两个键格式不同"看起来像两套逻辑。
    ///
    /// 为什么要有这个方法而不是让调用方自己拼字符串：
    /// 本项目已经踩过「底图按 4px 跳、标记连续滑」的错位事故，
    /// 根因就是**量化规则被复制到了第二个地方**。键的构造也必须只有一份。
    func tileCacheKey(outSize: CGFloat) -> String {
        let q = quantized
        return "\(Int(q.centerX))|\(Int(q.centerY))|\(Int(q.spanPx))|\(Int(outSize))"
    }
}

// ============================================================================
// MARK: - 折线存储（展平 + 包围盒）
// ============================================================================

/// 折线集合的展平存储：所有折线的顶点存在一个连续数组里，用 range 索引。
///
/// 为什么展平：`[[CGPoint]]` 在 Swift 里是「数组的数组」，每帧遍历会产生
/// 大量 ARC 引用与缓存未命中；展平成 `[CGPoint]` 后是连续内存，遍历近乎免费。
struct PolylineStore {
    /// 全部顶点（地图像素空间）
    let points: [CGPoint]
    /// 每条折线在 points 中的下标区间
    let ranges: [Range<Int>]
    /// 每条折线的包围盒（用于视口剔除）
    let boxes: [CGRect]
    /// 全部折线的总包围盒
    let bounds: CGRect

    var count: Int { ranges.count }

    /// 从 `[[[Double]]]`（JSON 形态）构建。`scale` 把源坐标换算到 13056 空间。
    static func build(edges: [[[Double]]], scale: Double) -> PolylineStore {
        var points: [CGPoint] = []
        var ranges: [Range<Int>] = []
        var boxes: [CGRect] = []
        points.reserveCapacity(edges.count * 8)
        ranges.reserveCapacity(edges.count)
        boxes.reserveCapacity(edges.count)

        for edge in edges {
            guard edge.count >= 2 else { continue }
            let start = points.count
            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            for pair in edge {
                guard pair.count >= 2 else { continue }
                let x = pair[0] * scale
                let y = pair[1] * scale
                points.append(CGPoint(x: x, y: y))
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
            guard points.count - start >= 2 else {
                points.removeSubrange(start..<points.count)
                continue
            }
            ranges.append(start..<points.count)
            boxes.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }

        var total = CGRect.null
        for b in boxes { total = total.union(b) }
        return PolylineStore(points: points, ranges: ranges, boxes: boxes,
                             bounds: total.isNull ? .zero : total)
    }

    /// 视口内可见折线的索引（包围盒相交测试）
    func visibleIndices(in rect: CGRect) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(64)
        for i in boxes.indices where boxes[i].intersects(rect) {
            out.append(i)
        }
        return out
    }
}

// ============================================================================
// MARK: - 路网叠加渲染缓存
// ============================================================================

/// 把可见路网渲染成一张与底图同尺寸的 CGImage，并按视野缓存。
///
/// 关键：**每帧只画 1 张图**，与路网折线数量无关。
/// 视野不变 → 直接命中缓存，零成本；视野变化 → 只重画可见的那几十条。
final class RoadOverlayCache {
    static let shared = RoadOverlayCache()

    private var key: String = ""
    private var cached: CGImage?

    // ── 诊断（供自检断言「视野变化重渲染」成本，缓存命中不计入）──
    /// 最近一次真实重渲染耗时（毫秒）
    private(set) var lastRenderMs: Double = 0
    /// 累计真实重渲染次数
    private(set) var renderCount: Int = 0
    /// 累计缓存命中次数
    private(set) var hitCount: Int = 0

    /// 缓存上限：只留最近一张（与 MapTileCache 同策略，避免多视野并存吃爆内存）
    private init() {}

    struct Style {
        var roadColor: CGColor
        var graphColor: CGColor
        var poiColor: CGColor
        /// 屏幕像素线宽（不随缩放变化）
        var roadWidth: CGFloat = 1.6
        var graphWidth: CGFloat = 2.2
        var poiRadius: CGFloat = 2.0
    }

    // ══════════════════════════════════════════════════════════════════════
    // ⚠️ 2026-10-06 线宽加粗（用户投诉：线太细，像"凭空多出来的细线"）
    // ══════════════════════════════════════════════════════════════════════
    //
    // 【用户原话】
    //   「地图上凭空多了好多细线，让我修，可能是bug。我跟他说这是路网他才
    //     才知道，太小了那个线给我粗一点像条路网」
    //   「路网那个线不要那么细嘛，给我加粗一点点，加粗一点点，尽量粗一点，
    //     让人感觉像条路嘛」
    //
    // 【实测证据（不是拍脑袋）】用 --mc-map 出图（2640×1720，2x scale），
    //   逐行量青绿像素的连续段宽度：
    //     · 路网骨架线：中位 **6.0 px**（2x）→ 屏幕 3.0 px
    //     · 底图路面像素占比 **10.01%**，路网像素仅 **3.89%**
    //   → 路网线被底图路面**视觉淹没**，所以用户第一眼以为是 bug 而不是路网。
    //
    // 【为什么不能只加粗 graphWidth 一个数】
    //   `roadWidth`(1.6) 是 roads.json 那 1517 条自采路网，`graphWidth`(2.2)
    //   是 route_graph.json 那 932 条骨架。用户看到的是**两者叠加**。
    //   只加粗一个会让两组线粗细不一致，看起来更像 bug。
    //   → 两个一起加，并保持"骨架略粗于自采路网"的层级关系。
    //
    // 【数值选择】2.2 → 3.6（+64%），1.6 → 2.6（+63%）。
    //   保持 3.6/2.6 ≈ 1.38 的层级比（原 2.2/1.6 = 1.375），只整体放大。
    //   为什么不到 5.0：地图上还有 POI 标记与文字标签，线太粗会盖住它们。
    //   3.6 屏幕像素 ≈ 单条车道视觉宽度，既能"看出是路"，又不遮标记。
    //
    // 【可覆盖】AURORA_MAP_GRAPH_W / AURORA_MAP_ROAD_W 供出图对照用，
    //   与项目里其他诊断 flag 一致（见 AuroraFlags）。
    private static func envWidth(_ key: String, _ fallback: CGFloat) -> CGFloat {
        guard let s = ProcessInfo.processInfo.environment[key],
              let v = Double(s), v > 0, v <= 20 else { return fallback }
        return CGFloat(v)
    }

    static let defaultStyle: Style = {
        var st = Style(
            roadColor: CGColor(red: 0x4C / 255.0, green: 0xC9 / 255.0, blue: 0xFF / 255.0, alpha: 0.85),
            graphColor: CGColor(red: 0x34 / 255.0, green: 0xE5 / 255.0, blue: 0xAA / 255.0, alpha: 0.90),
            poiColor: CGColor(red: 0xFF / 255.0, green: 0xB6 / 255.0, blue: 0x48 / 255.0, alpha: 0.85)
        )
        st.roadWidth  = envWidth("AURORA_MAP_ROAD_W", 2.6)
        st.graphWidth = envWidth("AURORA_MAP_GRAPH_W", 3.6)
        return st
    }()

    /// 渲染可见路网叠加层。
    /// - Parameters:
    ///   - viewport: 必须传**量化后**的视口（与底图裁切一致），否则错位
    ///   - outSize: 输出位图边长（像素）
    ///   - flags: 图层开关位（1=路网 2=骨架 4=POI），参与缓存键
    func overlay(roads: PolylineStore?,
                 graph: PolylineStore?,
                 poi: [CGPoint],
                 viewport: MapLayerViewport,
                 outSize: CGFloat,
                 flags: Int,
                 generation gen: Int = 0,
                 style: Style = RoadOverlayCache.defaultStyle) -> CGImage? {
        guard outSize > 0, viewport.spanPx > 0 else { return nil }
        let k = viewport.cacheKey(outSize: outSize, flags: flags, gen: gen)
        if k == key, let c = cached {
            hitCount += 1
            return c
        }
        guard flags != 0 else { return nil }

        let t0 = DispatchTime.now().uptimeNanoseconds

        let side = Int(outSize.rounded())
        guard side > 0, side <= 8192 else { return nil }

        // ── 复用位图上下文（2026-10-04 优化）──
        // 视野每变一次就重画，若每次新分配 1200×1200 RGBA 位图，
        // 等于每帧申请+清零 5.76 MB —— 拖动时这是纯浪费。
        // 尺寸不变就复用同一个 context，只 clear 后重画。
        //
        // 安全性：`CGBitmapContextCreateImage` 是**写时复制**语义 ——
        // 返回的 CGImage 持有当前位图，之后再往该 context 画会触发一次
        // 内部拷贝，**不会**篡改已返回的图。所以复用 context 不会让
        // 上一帧的缓存图“跟着变”。
        guard let ctx = obtainContext(side: side) else { return nil }

        // 地图像素 → 输出像素的缩放
        let s = CGFloat(side) / CGFloat(viewport.spanPx)
        let rect = viewport.rect

        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-10-04 修复：**Y 轴必须翻转**（路网与底图永远错位的根因）
        // ══════════════════════════════════════════════════════════════════
        // 【症状】拖动时路网和底图一起动，但**永远对不上**（用户原话
        //   「路网和地图各栋各的，百分百错位」）。
        //
        // 【根因】两套坐标系的 Y 方向相反：
        //   · 底图走 `ctx.draw(cg, in:)` —— CoreGraphics 把源图**第 0 行**
        //     （即地图像素 y 最小的那一行 = 最上面）画在上下文的 **y 最大**处。
        //   · 折线坐标 `PolylineStore.points` 用的是**地图像素 y**（向下增大）。
        //   原来的变换只有 `scaleBy(s,s)` + `translateBy(-minX,-minY)`，
        //   于是路网被**上下镜像**了。
        //
        // 【实测证据】把「带路网」与「不带路网」两次渲染相减取出线像素，
        //   再看这些像素在底图上的亮度：只有 **20.2%** 落在亮路面（top12%）上，
        //   而随机落点基线是 12% —— 等于乱落。翻转后应显著 >60%。
        //
        // 【修法】先平移到 y=side，再用负缩放翻 Y，最后平移视口左上角。
        //   等价于：ctxY = side - (mapY - rect.minY) * s
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)

        // 线宽要除以缩放，才能在屏幕上保持恒定宽度
        let roadLW = style.roadWidth / s
        let graphLW = style.graphWidth / s

        // ── 我们的路网 ──
        if flags & 1 != 0, let store = roads {
            ctx.setStrokeColor(style.roadColor)
            ctx.setLineWidth(roadLW)
            ctx.beginPath()
            appendVisible(store, in: rect, to: ctx)
            ctx.strokePath()
        }

        // ── 路网骨架 ──
        if flags & 2 != 0, let store = graph {
            ctx.setStrokeColor(style.graphColor)
            ctx.setLineWidth(graphLW)
            ctx.beginPath()
            appendVisible(store, in: rect, to: ctx)
            ctx.strokePath()
        }

        // ── POI ──
        if flags & 4 != 0, !poi.isEmpty {
            ctx.setFillColor(style.poiColor)
            let r = style.poiRadius / s
            let rr = r * r
            for p in poi {
                // 点在视口外就跳过（视口外画了也看不见）
                if p.x < rect.minX - r || p.x > rect.maxX + r { continue }
                if p.y < rect.minY - r || p.y > rect.maxY + r { continue }
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                _ = rr
            }
        }

        // 恢复单位矩阵（obtainContext 里 saveGState 过），否则下次复用时
        // 变换会叠加，画出来的东西越缩越小 —— 复用 context 必须成对 restore。
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return nil }
        lastRenderMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        renderCount += 1
        key = k
        cached = image
        return image
    }

    // ── 位图上下文复用（见 overlay 内注释）──
    private var reusableCtx: CGContext?
    private var reusableSide: Int = 0

    /// 取一个干净的、单位矩阵的位图上下文。同尺寸复用，异尺寸重建。
    private func obtainContext(side: Int) -> CGContext? {
        if let c = reusableCtx, reusableSide == side {
            c.clear(CGRect(x: 0, y: 0, width: side, height: side))
            c.saveGState()
            return c
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let c = CGContext(data: nil, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: bitmapInfo) else { return nil }
        reusableCtx = c
        reusableSide = side
        c.saveGState()
        return c
    }

    /// 只把视口内的折线写进当前路径
    private func appendVisible(_ store: PolylineStore, in rect: CGRect, to ctx: CGContext) {
        for i in store.visibleIndices(in: rect) {
            let range = store.ranges[i]
            var first = true
            for idx in range {
                let p = store.points[idx]
                if first {
                    ctx.move(to: p)
                    first = false
                } else {
                    ctx.addLine(to: p)
                }
            }
        }
    }

    /// 诊断用：清缓存
    func invalidate() {
        key = ""
        cached = nil
    }
}

// ============================================================================
// MARK: - 叠加层视图
// ============================================================================

/// 把路网/骨架/POI 叠到底图上。
///
/// 【对齐要点】必须与 `MapTileImage` 用**同一套**几何：
///   · `side = max(宽, 高)`（cover，等比铺满，非正方形面板不露白边）
///   · 视口取**量化后**的（`MapTileCache.tile` 内部也是量化后再裁，
///     量化规则必须一致，否则底图与叠加层会差半格）
///   · `.frame(side, side)` + 同一个居中 offset
/// 任何一项不同都会错位，而地图错位是最不能忍的。
struct RoadOverlayLayer: View {
    nonisolated(unsafe) static var diagCount = 0

    /// 诊断：只打前 4 次，确认路网层到底拿到数据没有
    @discardableResult
    static func diag(side: CGFloat, flags: Int, store: MapLayerStore, spanPx: Double) -> Int {
        guard diagCount < 4 else { return 0 }
        diagCount += 1
        NSLog("[ROAD-DIAG] side=%.0f flags=%d ready=%d roads=%@ graph=%@ poi=%d span=%.0f",
              side, flags, store.isReady ? 1 : 0,
              store.roads == nil ? "nil" as NSString : "有" as NSString,
              store.graph == nil ? "nil" as NSString : "有" as NSString,
              store.poi.count, spanPx)
        return 1
    }
    let centerX: Double
    let centerY: Double
    let spanPx: Double
    /// 图层开关位：1=路网 2=骨架 4=POI
    var flags: Int

    @ObservedObject private var store = MapLayerStore.shared

    var body: some View {
        GeometryReader { g in
            let side = max(g.size.width, g.size.height)
            let vp = MapLayerViewport(centerX: centerX, centerY: centerY, spanPx: spanPx).quantized
            let _ = RoadOverlayLayer.diag(side: side, flags: flags, store: store, spanPx: spanPx)
            if side > 0, flags != 0,
               let img = RoadOverlayCache.shared.overlay(
                    roads: store.roads,
                    graph: store.graph,
                    poi: store.poi,
                    viewport: vp,
                    outSize: side,
                    flags: flags,
                    generation: store.generation) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .offset(x: (g.size.width - side) / 2,
                            y: (g.size.height - side) / 2)
            }
        }
        .clipped()
        .allowsHitTesting(false)   // 叠加层不吃点击，手势留给外层
    }
}

// ============================================================================
// MARK: - 图层数据源
// ============================================================================

/// 地图图层数据（路网 / 骨架 / POI）。进程内只加载一次。
final class MapLayerStore: ObservableObject {
    static let shared = MapLayerStore()

    @Published private(set) var isReady = false
    /// 数据世代：每次 `apply` 自增。缓存键要含它，否则「数据到位前画的空图」
    /// 会在视口不变时被永久命中（见 `MapLayerViewport.cacheKey` 的说明）。
    @Published private(set) var generation = 0
    @Published private(set) var loadError: String?
    @Published private(set) var loadMs: Double = 0

    private(set) var roads: PolylineStore?
    private(set) var graph: PolylineStore?
    private(set) var poi: [CGPoint] = []

    private var didLoad = false

    private init() {}

    /// 幂等加载。解析与展平在后台队列，完成后主线程发布。
    func ensureLoaded() {
        if didLoad { return }
        didLoad = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Self.loadAll()
            DispatchQueue.main.async { self?.apply(loaded) }
        }
    }

    /// **同步**加载（离屏夹具专用）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【为什么必须有这条路径】`ImageRenderer` **不触发 `onAppear`**。
    /// ══════════════════════════════════════════════════════════════════════
    /// UI 路径是在 `onAppear` 里调 `ensureLoaded()` 的；离屏夹具（`--mc-map`
    /// 等）走 `ImageRenderer`，`onAppear` 永不触发，于是渲染那一刻
    /// `roads` 还是 nil —— 出图里没有路网，夹具就失去了验证意义
    /// （实测踩过：出图只有底图+标记，看不到路网）。
    ///
    /// 这与 `MapDatabase.ensureLoadedSyncLegacy()` 是**同一个理由、同一套做法**：
    /// 夹具是同步一次性渲染，没有「稍后再刷新」的机会。
    func ensureLoadedSync() {
        if isReady { return }
        didLoad = true
        apply(Self.loadAll())
    }

    /// 真正干活的部分（纯函数：只读盘 + 解析，不碰实例状态）。
    ///
    /// 抽成 `static` 是为了让同步/异步两条路径共用同一份逻辑 ——
    /// 否则两边会漂移，而「夹具看到的和真机跑的不是一套数据」是最坏的情况。
    private static func loadAll()
        -> (roads: PolylineStore?, graph: PolylineStore?, poi: [CGPoint], problems: [String], ms: Double) {
        let t0 = Date()
        var roads: PolylineStore?
        var graph: PolylineStore?
        var poi: [CGPoint] = []
        var problems: [String] = []

        // ── roads.json（6528 空间 → ×2 到 13056）──
        if let url = resolve(["tools/roadnet/web/roads.json",
                              "models/map/roads.json"]) {
            if let edges = parseEdgeList(url) {
                roads = PolylineStore.build(edges: edges, scale: 2.0)
            } else {
                problems.append("roads.json 解析失败")
            }
        } else {
            problems.append("roads.json 未找到")
        }

        // ── route_graph.json（13056 空间 → 原值）──
        if let url = resolve(["models/route_graph.json",
                              "tools/roadnet/web/route_graph.json"]) {
            if let edges = parseGraphEdges(url) {
                graph = PolylineStore.build(edges: edges, scale: 1.0)
            } else {
                problems.append("route_graph.json 解析失败")
            }
        } else {
            problems.append("route_graph.json 未找到")
        }

        // ── poi.json（13056 空间 → 原值）──
        if let url = resolve(["tools/roadnet/web/poi.json",
                              "models/map/poi.json"]) {
            poi = parsePOI(url)
        } else {
            problems.append("poi.json 未找到")
        }

        return (roads, graph, poi, problems, Date().timeIntervalSince(t0) * 1000)
    }

    /// 把加载结果写进实例并发布
    private func apply(_ loaded: (roads: PolylineStore?, graph: PolylineStore?, poi: [CGPoint], problems: [String], ms: Double)) {
        roads = loaded.roads
        graph = loaded.graph
        poi = loaded.poi
        loadMs = loaded.ms
        loadError = loaded.problems.isEmpty ? nil : loaded.problems.joined(separator: " / ")
        isReady = true
        generation &+= 1
        NSLog("[MapLayers] 就绪 %.1fms 路网=%@ 骨架=%@ POI=%d %@",
              loaded.ms,
              loaded.roads.map { "\($0.count)条" } ?? "无",
              loaded.graph.map { "\($0.count)条" } ?? "无",
              loaded.poi.count,
              loaded.problems.isEmpty ? "" : "⚠️ \(loaded.problems.joined(separator: "/"))")
    }

    // MARK: - 文件定位

    /// 按候选相对路径依次尝试，返回第一个存在的文件
    private static func resolve(_ candidates: [String]) -> URL? {
        let root = AuroraPaths.projectRoot()
        let fm = FileManager.default
        for rel in candidates {
            let url = root.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - JSON 解析（JSONSerialization：比 Codable 少一层中间对象）

    /// 解析 `{"edges": [[[x,y],...], ...]}`
    private static func parseEdgeList(_ url: URL) -> [[[Double]]]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edges = obj["edges"] as? [[[Double]]] else { return nil }
        return edges
    }

    /// 解析 `{"nodes": [[id,x,y],...], "edges": [[id,from,to,dist,[[x,y],...]],...]}`
    ///
    /// 优先用边自带的折线（e[4]）以贴合真实道路形状；缺失时退化为两节点直线。
    private static func parseGraphEdges(_ url: URL) -> [[[Double]]]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = obj["nodes"] as? [[Double]],
              let edges = obj["edges"] as? [[Any]] else { return nil }

        var out: [[[Double]]] = []
        out.reserveCapacity(edges.count)

        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-10-04 修正 schema（由 map-tests 抓出，已复核）
        // ══════════════════════════════════════════════════════════════════
        // 每条边是 **4 个元素**：`[a, b, len_m, poly]`
        //     edges[0] = [0, 2, 1011.2, [[3150,1391],[3168,1387],…]]
        //                 a  b   len_m    poly（形状折线，13056 空间）
        // 与 `RouteGraph.swift:310-334` 的生产解析口径一致（已比对）。
        //
        // 本文件初版误按 5 元素 `[id, from, to, dist, poly]` 读，后果：
        //   · `e[1]`(=b) 被当成 from —— 碰巧是合法下标，不报错
        //   · `e[2]`(=len_m，米制长度如 1011.2) 被当成 to —— 越界即丢弃
        //   · `e[4]` 永远不存在 → 形状分支从不命中
        //   实测：825 条里只接受 802 条，且那 802 条把「米数」当节点下标，
        //   **连的是随机节点** —— 典型「不崩但结果错」，骨架层会画出一堆跨全图直线。
        //
        // 现在 825/825 全部走 poly 分支，骨架与真实道路形状一致。
        for e in edges {
            guard e.count >= 4 else { continue }
            // 形状折线在 e[3]
            if let shape = e[3] as? [[Double]], shape.count >= 2 {
                out.append(shape)
                continue
            }
            // 兜底：没有形状折线时，用两端节点连直线
            guard let a = e[0] as? Double, let b = e[1] as? Double else { continue }
            let ia = Int(a), ib = Int(b)
            guard ia >= 0, ia < nodes.count, ib >= 0, ib < nodes.count else { continue }
            let na = nodes[ia], nb = nodes[ib]
            guard na.count >= 3, nb.count >= 3 else { continue }
            out.append([[na[1], na[2]], [nb[1], nb[2]]])
        }
        return out
    }

    /// 解析 `[{"x":..,"y":..,"n":..,"t":..}, ...]`
    private static func parsePOI(_ url: URL) -> [CGPoint] {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            guard let x = item["x"] as? Double, let y = item["y"] as? Double else { continue }
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}
