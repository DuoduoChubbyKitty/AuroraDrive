// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapSelfTest.swift — 原生地图严格自检（`--map-selftest`）
// ============================================================================
//
//  设计原则：**门槛写进断言，不靠人看**。
//  任何一项不达标 → 返回非 0 退出码 → 构建/CI 直接失败。
//
//  覆盖：
//    T1 坐标黄金样本   世界→像素，误差 < 0.5px（用上游标定点做标准答案）
//    T1b 往返一致性    世界→像素→世界，相对误差 < 1e-6
//    T2 图层对齐       底图/路网/标记必须共用同一个 MapViewport
//    T3 图层加载       路网/骨架/POI 数量与数据文件一致
//    T4 性能门禁       首帧加载 / 首帧渲染 / 缓存命中 / 视口剔除
//    T5 内存浸泡       240 个不同视口后 RSS 无增长趋势（mach task_info 实测）
//    T6 断网可用       源码静态扫描（无远端瓦片/网页字样）+ 本地底图可加载
// ============================================================================

import Foundation
import CoreGraphics
import AppKit
import Darwin

// ============================================================================
// MARK: - 结果记录
// ============================================================================

struct MapTestResult {
    var passed = 0
    var failed = 0
    var lines: [String] = []

    mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1; lines.append("  ✅ \(name)  \(detail)") }
        else { failed += 1; lines.append("  ❌ \(name)  \(detail)") }
    }

    mutating func info(_ text: String) { lines.append("     \(text)") }
}

// ============================================================================
// MARK: - T1 坐标黄金样本
// ============================================================================

/// 上游 `navi-coordinate-calibration.json` 的标定点：世界坐标 → 地图像素（13056 空间）。
///
/// 这三个点是**外部标准答案**，不是我们自己算出来的 —— 用它们做黄金样本，
/// 才能证明「我们的标定与上游同一套」。允许误差 0.5px。
private let kGoldenSamples: [(wx: Double, wy: Double, mx: Double, my: Double)] = [
    (-134_394.56, 199_913.53, 4323, 8488),
    (39_731.64, 100_731.11, 7178, 6862),
    (-102_621.85, 66_062.87, 4844, 6294),
]

// ============================================================================
// MARK: - T4~T6 扩展（性能门禁 / 内存浸泡 / 断网）
// ============================================================================

/// 扩展自检：T4 性能门禁 / T5 内存浸泡 / T6 断网可用。
///
/// 设计原则同文件头：**门槛写进断言，不靠人看**。
/// 任何一项不达标 → `MapTestResult.failed` 增加 → 进程退出码非 0。
func runMapSelfTestExt(_ r: inout MapTestResult) {
    // 先把「这台机器此刻有多忙」打出来 —— 时间门禁的读数必须带着环境一起看，
    // 否则「40.50ms 红灯」到底是代码退化还是别人在编译，读者无从判断。
    let load = MapLoad.summaryLine()
    print("\n[T4~T6 环境] \(load)")
    r.info("环境：\(load)（时间阈值按此系数放宽；结构类断言不受影响）")
    mapTestT4(&r)
    mapTestT5(&r)
    mapTestT6(&r)
    mapTestT7(&r)
}

// ---------------------------------------------------------------------------
// MARK: T4~T6 公共工具
// ---------------------------------------------------------------------------

/// 单调时钟（纳秒）。
///
/// 测微秒级耗时不能用 `Date()`：它会随系统时间调整/校时跳变，一次 NTP 校正
/// 就能把「缓存命中 0.02ms」测成负数或几秒。`DispatchTime` 是单调钟。
@inline(__always)
private func mapNowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// 本进程常驻内存 RSS（字节）；读取失败返回 nil —— **绝不编造数字**。
///
/// 写法对齐 `PerfSelfTest.swift:230` 的 `processCPUPercent()`（同样直接走 mach、
/// 同样失败即 nil）。取 `resident_size` 而不是 `virtual_size`：前者是真实驻留
/// 物理页；后者包含大量未触碰的保留地址空间，拿它做泡测会被虚高数字骗。
private func mapProcessRSSBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                       / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}

@inline(__always)
private func mapMB(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576.0 }

// ---------------------------------------------------------------------------
// MARK: 负载归一化（A14）
// ---------------------------------------------------------------------------

/// 机器负载归一化 —— 让时间门禁能区分「机器忙」与「代码退化」。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 【为什么必须做】2026-10-04 实测：**同一个二进制、同一条命令**，在别的队友
/// 正在编译/跑基准时：
///     首帧渲染        6.98ms ✅ → 40.50ms ❌   （5.8×）
///     视野变化重渲染   4.43ms ✅ → 28.34ms ❌   （6.4×）
///     MapTileCache.tile 81.9ms → 388.7ms      （4.7×）
/// 而代码**一个字没改**（`perf-core` 空载重测全绿：首帧 5.75ms / 重渲染 4.26ms）。
/// 门禁若不能区分这两者，多人协作时就会天天假红灯 —— 最后没人再信它，
/// 等于没有门禁。这比"阈值定松一点"严重得多。
///
/// 【做法】用系统负载均值 `getloadavg` 估计 CPU 争用系数：
///     系数 = clamp(loadavg(1min) / 活跃核数, 1, 8)
/// 时间阈值统一乘这个系数：
///     · 空载（loadavg ≤ 核数）→ 系数 = 1 → 阈值**原样**，真退化照样抓得住
///     · 满载 → 阈值最多放宽 8×，不把「别人在编译」判成缺陷
/// 系数上限 8 是**故意的**：再忙也不该放过 8 倍以上的退化。
///
/// 【为什么不采用「进程内微基准取最小值当空闲基准」】在**持续**负载下，
/// min-of-N 本身也是慢的，比值恒为 1 —— 等于没归一化。系统负载均值才是
/// 「这台机器此刻有多忙」的直接观测，且不受本进程内测量方法影响。
///
/// 【仍然保留的绝对门禁】结构类断言（数量、坐标、缓存同一实例、剔除无漏检）
/// **一律不做负载归一化** —— 它们与时间无关，永远该咬人。
enum MapLoad {
    /// 诊断开关：`AURORA_MAP_NO_LOADNORM=1` 强制系数 = 1（= 关掉归一化）。
    ///
    /// 存在的唯一目的：**做 A/B 对照**。在同一个高负载环境下跑两遍，
    /// 一遍开、一遍关，才能证明「红灯是负载造成的、归一化确实救了它」，
    /// 而不是嘴上说「应该是负载吧」。没有这个开关，归一化就是不可证伪的。
    static var disabled: Bool {
        ProcessInfo.processInfo.environment["AURORA_MAP_NO_LOADNORM"] == "1"
    }

    /// 采样当前负载。(load1, cores, factor)
    static func snapshot() -> (load1: Double, cores: Int, factor: Double) {
        var avg = [Double](repeating: 0, count: 3)
        let n = getloadavg(&avg, 3)
        let load1 = (n > 0 && avg[0].isFinite) ? avg[0] : 0
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let factor = disabled ? 1.0 : min(8.0, max(1.0, load1 / Double(cores)))
        return (load1, cores, factor)
    }

    /// 一行负载摘要（放进输出，让人一眼看到门禁是在什么环境下跑的）
    static func summaryLine() -> String {
        let s = snapshot()
        return String(format: "负载 loadavg(1m)=%.2f / %d 核 → 时间阈值系数 ×%.2f",
                      s.load1, s.cores, s.factor)
    }

    /// 负载归一化后的时间阈值
    static func budget(_ base: Double) -> Double { base * snapshot().factor }
}

/// 时间门禁的统一表述：**原始值 / 基准阈值 / 负载系数 / 实际阈值** 一次说清。
/// 只报「通过/失败」的测试在负载下没人能判断真假 —— 必须四件事都给出来。
private func mapTimeDetail(_ measured: Double, base: Double,
                           extra: String = "") -> String {
    let s = MapLoad.snapshot()
    let budget = base * s.factor
    let tail = extra.isEmpty ? "" : "  \(extra)"
    return String(format: "实测 %.2f ms < 基准 %.2f ms ×%.2f 负载 = %.2f ms%@",
                  measured, base, s.factor, budget, tail)
}

/// 时间门禁的统一执行器：**超预算即复测一次**，两次都超才判失败。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 【为什么光有负载系数不够】`getloadavg` 是 **1 分钟滑动平均**，对「瞬时争用」
/// 反应极慢。实测（2026-10-04，本机）：
///     loadavg(1m) = 5.31 / 8 核 → 系数被 clamp 成 **1.00**
///     而同一时刻首帧渲染已从 6.41ms 涨到 **27.07ms（4.2×）** → 门禁照样假红。
/// 负载均值只能覆盖「持续满载」，覆盖不了「别的智能体正好在这一秒编译」。
///
/// 【做法】第一次超预算时**再测一次**，取两次里较好的那次作为判定值：
///   · 瞬时争用 / 冷页缓存 / 首次触碰 → 只影响第一次，复测即恢复 → 通过
///   · 真退化（代码变慢）→ 两次都超 → 红灯
/// **这不是放宽阈值**：判据仍是同一个基准阈值，只是不允许用**单次**受扰读数定罪。
/// 两次的数值都会打印，不做任何隐瞒 —— 读者能自己判断是哪一种。
///
/// 【与负载系数的关系】两者是**互补**的：系数处理"持续满载"，复测处理"瞬时尖峰"。
/// 只有复测、没有系数时，持续满载会让两次都超 → 误判真退化；
/// 只有系数、没有复测时，瞬时尖峰（本函数注释里的 27.07ms）→ 误判真退化。
private func mapGateWithRetry(_ r: inout MapTestResult, name: String, base: Double,
                              extra: String = "", _ measure: () -> Double) {
    let first = measure()
    if first < MapLoad.budget(base) {
        r.check(name, true, mapTimeDetail(first, base: base, extra: extra))
        return
    }
    // 超预算 → 复测一次（排除瞬时争用 / 冷缓存）
    let second = measure()
    let ok = second < MapLoad.budget(base)
    let s = MapLoad.snapshot()
    let detail = ok
        ? String(format: "首次 %.2f ms 超预算 → 复测 %.2f ms 通过（首次判为瞬时争用/冷缓存）；%@",
                 first, second, mapTimeDetail(second, base: base, extra: extra))
        : String(format: "首次 %.2f ms、复测 %.2f ms **两次都超**（基准 %.2f ×%.2f 负载 = %.2f ms）→ 判为真退化；%@",
                 first, second, base, s.factor, base * s.factor, extra)
    r.check(name, ok, detail)
}


/// 确定性伪随机（LCG）。
///
/// 泡测必须**可复现**：换台机器重跑要能重放同一串视口，否则「这次涨了 12MB」
/// 无法归因。`Double.random` 做不到，所以自带一个固定种子 LCG。
private struct MapSoakRNG {
    private var s: UInt64
    init(seed: UInt64) { s = seed }

    mutating func next() -> UInt64 {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return s >> 33
    }

    /// [lo, hi] 内的值（1e-6 分辨率足够覆盖 13056px 空间）
    mutating func value(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * (Double(next() % 1_000_001) / 1_000_000.0)
    }
}

// ---------------------------------------------------------------------------
// MARK: T4 性能门禁
// ---------------------------------------------------------------------------

private func mapTestT4(_ r: inout MapTestResult) {
    print("\n[T4] 性能门禁（首帧加载 / 首帧渲染 / 缓存命中 / 视口剔除）")
    let store = MapLayerStore.shared
    guard let roads = store.roads, let graph = store.graph else {
        r.check("T4 · 图层就绪（前置条件）", false,
                "roads=\(store.roads?.count ?? -1) graph=\(store.graph?.count ?? -1) —— 图层缺失，性能项无从测量")
        return
    }
    let poi = store.poi

    // ── ① 首帧加载：1517 路网 + 825 骨架 + 1622 POI 的解析与展平 ──
    r.check("T4 · 首帧加载 < 3000ms", store.loadMs > 0 && store.loadMs < 3000,
            String(format: "%.1f ms（路网 %d 条 / 骨架 %d 条 / POI %d 点）",
                   store.loadMs, roads.count, graph.count, poi.count))

    // ── ② 典型视野首帧渲染（flags=7：路网+骨架+POI 全开，最坏情况）──
    let vp = MapLayerViewport(centerX: 6528, centerY: 6528, spanPx: 1200).quantized
    let outSize: CGFloat = 1200
    let flags = 7
    let style = RoadOverlayCache.defaultStyle

    func render(_ v: MapLayerViewport, _ f: Int) -> CGImage? {
        RoadOverlayCache.shared.overlay(roads: roads, graph: graph, poi: poi,
                                        viewport: v, outSize: outSize, flags: f, style: style)
    }

    // 首帧渲染门禁：走统一执行器（超预算自动复测一次，两次都超才判真退化）。
    // `cold` 取第一次的产物 —— 缓存同一性断言要用它，不能是复测那次的图。
    var capturedCold: CGImage?
    mapGateWithRetry(&r, name: "T4 · 首帧渲染 < 16.7ms（60fps 单帧预算 ×负载系数）",
                     base: 16.7, extra: "spanPx=1200 out=1200 flags=7") {
        RoadOverlayCache.shared.invalidate()   // 每次都从「冷」开始，否则测到的是命中
        let t = mapNowNs()
        let img = render(vp, flags)
        if capturedCold == nil { capturedCold = img }
        return Double(mapNowNs() - t) / 1e6
    }
    let cold = capturedCold
    r.check("T4 · 首帧渲染出图", cold != nil, cold.map { "\($0.width)×\($0.height)" } ?? "nil")

    // ── ③ 缓存命中：必须直接返回同一张 CGImage，不得重算 ──
    let hitN = 300
    var hitSum = 0.0
    var hitWorst = 0.0
    var sameObject = true
    for _ in 0..<hitN {
        let t = mapNowNs()
        let img = render(vp, flags)
        let ms = Double(mapNowNs() - t) / 1e6
        hitSum += ms
        if ms > hitWorst { hitWorst = ms }
        if img !== cold { sameObject = false }
    }
    let hitAvg = hitSum / Double(hitN)
    // 这一条**不做负载归一化**：命中路径是「字典比 key + 返回指针」，实测 0.0002ms，
    // 阈值 0.1ms 有 500 倍余量；能被负载顶破就说明它真的不是常数时间了。
    r.check("T4 · 缓存命中平均 < 0.1ms", hitAvg < 0.1,
            String(format: "平均 %.4f ms / 最差 %.4f ms（%d 次同视野）", hitAvg, hitWorst, hitN))
    r.check("T4 · 命中不重算（同一 CGImage 实例）", sameObject,
            sameObject ? "\(hitN)/\(hitN) 次同一实例" : "出现新实例 → 缓存未生效，每帧都在重算")

    // ── ③b 视野变化重渲染成本（★ 拖动地图时的真实每帧成本）──
    //
    // 缓存命中率再高，**拖动时视野每帧都在变**，命中不了 —— 所以真正决定
    // 「拖起来跟不跟手」的是这一项，不是命中耗时。2026-10-04 加入。
    //
    // 同时验证「位图上下文复用」优化生效：旧实现每次新分配 1200×1200 RGBA
    // （5.76MB 申请+清零），复用后只 clear 重画。
    var reRenderAvg = 0.0
    var reRenderWorst = 0.0
    /// 跑一轮「30 个互不相同视口」的重渲染，返回平均耗时。
    /// 抽成闭包是为了能**复测**（超预算时再跑一轮，见 mapGateWithRetry）。
    func measureReRender() -> Double {
        RoadOverlayCache.shared.invalidate()
        let out: CGFloat = 1200
        var worst = 0.0
        var total = 0.0
        let n = 30
        for i in 0..<n {
            // 每次给一个**不同**的视口 → 必然走重渲染路径
            // （用与真实拖动相同的步长语义：中心每步移动几像素，量化后键必变）
            let vp = MapLayerViewport(centerX: 6528 + Double(i) * 7,
                                      centerY: 6528 + Double(i) * 5,
                                      spanPx: 1200).quantized
            _ = RoadOverlayCache.shared.overlay(
                roads: store.roads, graph: store.graph, poi: store.poi,
                viewport: vp, outSize: out, flags: 7)
            let ms = RoadOverlayCache.shared.lastRenderMs
            worst = max(worst, ms)
            total += ms
        }
        reRenderWorst = worst
        return total / Double(n)
    }
    // 阈值 16.7ms 是 60fps 单帧预算的**全部**；路网层自己不该吃掉它。
    // 取 8ms（约为预算一半）作为门禁，留一半给底图与标记。
    //
    // 【2026-10-07 基准调整：8.0 → 10.0ms，有实测依据】
    //   · 路网修复引入 **+107 边（825→932，+13.0%）**，绘制对象同步变多；
    //   · 实测重渲染 8.34–9.50ms（3 轮稳定超 8.0），而非偶发抖动；
    //   · 10.0ms 仍只占 60fps 单帧预算（16.7ms）的 **60%**，门禁意义保留；
    //   · 若将来对象数继续涨而耗时跟着涨，该调基准的**前提是有对照数据**，
    //     不许因为"看着超了"就放松阈值（本项目 13 项想当然的优化已被实测否决）。
    mapGateWithRetry(&r, name: "T4 · 视野变化重渲染平均 < 10ms（×负载系数，10-07 因 +13% 对象调基）",
                     base: 10.0, extra: "30 个互不相同视口，flags=7") {
        reRenderAvg = measureReRender()
        return reRenderAvg
    }
    r.info(String(format: "     该轮最差单次 %.2f ms（均值 %.2f ms）", reRenderWorst, reRenderAvg))

    // ── ③c 负载无关的相对门禁（★ 保证「忙的时候也还能抓到真问题」）──
    //
    // 上面两条按负载放宽了阈值，代价是「真退化恰好撞上高负载」会被放过。
    // 这一条用**同一进程、同一负载下**的两个量做比值：命中 vs 重渲染。
    // 负载对两者是同比例影响的，比值里被约掉 —— 所以它**恒不受负载影响**。
    // 若有人把缓存写坏（每次都重算），比值会从 ~10⁵ 掉到 ~1，立刻红灯。
    if reRenderAvg > 0 {
        let ratio = reRenderAvg / max(hitAvg, 1e-9)
        r.check("T4 · 命中比重渲染快 ≥100×（负载无关的缓存有效性门禁）",
                ratio >= 100,
                String(format: "重渲染 %.3f ms ÷ 命中 %.5f ms = %.0f×（阈值 100×）",
                       reRenderAvg, hitAvg, ratio))
    }

    // ── ④ 视口剔除有效性 ──
    let fullIdx = roads.visibleIndices(in: roads.bounds.insetBy(dx: -1, dy: -1))
    r.check("T4 · 全图视野包含全部折线", fullIdx.count == roads.count,
            "\(fullIdx.count)/\(roads.count)")

    let smallRect = MapLayerViewport(centerX: 6528, centerY: 6528, spanPx: 1200).rect
    let smallIdx = roads.visibleIndices(in: smallRect)
    let ratio = Double(smallIdx.count) / Double(max(roads.count, 1))
    r.check("T4 · 小视野剔除生效（< 总数 25%）", ratio < 0.25,
            String(format: "%d/%d = %.1f%%（1200px 视野）", smallIdx.count, roads.count, ratio * 100))

    // 剔除用包围盒法：允许保守多给（盒子相交但折线本身不在视口内），**不许漏**。
    // 漏一条 = 地图上凭空少一条路 —— 正是「不崩但结果错」那类事故。
    //
    // 判据必须用「**严格内部**」，不能用 `CGRect.contains`：后者把 min 边也算包含，
    // 而 CoreGraphics 的 `intersects` 对「只相切、交集面积为 0」的两矩形返回 false。
    // 实测本视野下恰有 1 条这种边（roads 第 385 条：x=6554 的垂直段，y∈[5758,5928]，
    // 只与视口上边界 y=5928 相切）—— 它整体在视口**外**，1.6px 线宽下最多在边缘
    // 画出 <1px 的一丝，判「不可见」是对的，不该算漏检。第一版断言就是踩了这个坑
    // （报「漏检 1 条」），是判据错、不是剔除错。
    let visSet = Set(smallIdx)
    var missed = 0
    var boundaryOnly = 0
    for i in roads.ranges.indices {
        var strictlyInside = false
        var touchesBoundary = false
        for j in roads.ranges[i] {
            let p = roads.points[j]
            if p.x > smallRect.minX, p.x < smallRect.maxX,
               p.y > smallRect.minY, p.y < smallRect.maxY {
                strictlyInside = true
                break
            }
            if smallRect.contains(p) { touchesBoundary = true }
        }
        if strictlyInside && !visSet.contains(i) {
            missed += 1
        } else if !strictlyInside, touchesBoundary, !visSet.contains(i) {
            boundaryOnly += 1
        }
    }
    r.check("T4 · 剔除无漏检（视口内有顶点的必被包含）", missed == 0, "漏检 \(missed) 条")
    r.info("     仅与视口边界相切（交集面积 0，渲染贡献 <1px）被剔除：\(boundaryOnly) 条")

    // 剔除本身的开销（1517 次包围盒相交测试）—— 证明「不是每帧全量遍历折线」
    var cullSum = 0.0
    let cullN = 500
    for _ in 0..<cullN {
        let t = mapNowNs()
        _ = roads.visibleIndices(in: smallRect)
        cullSum += Double(mapNowNs() - t) / 1e6
    }
    r.info(String(format: "     剔除开销 平均 %.4f ms/次（全扫 %d 条包围盒 → 命中 %d 条）",
                  cullSum / Double(cullN), roads.count, smallIdx.count))
}

// ---------------------------------------------------------------------------
// MARK: T5 内存浸泡
// ---------------------------------------------------------------------------

private func mapTestT5(_ r: inout MapTestResult) {
    let iterations = 240          // 要求 ≥200 个**互不相同**的 center/span 组合
    let outSize: CGFloat = 1200

    print("\n[T5] 内存浸泡（\(iterations) 个不同视口，RSS 增长 < 50MB 且无上升趋势）")
    let store = MapLayerStore.shared
    guard let roads = store.roads, let graph = store.graph else {
        r.check("T5 · 图层就绪（前置条件）", false, "图层缺失，泡测无法进行")
        return
    }
    let poi = store.poi
    guard let rss0 = mapProcessRSSBytes() else {
        r.check("T5 · RSS 可读（mach task_info）", false, "task_info 返回非 KERN_SUCCESS")
        return
    }
    r.info(String(format: "     起始 RSS %.1f MB", mapMB(rss0)))

    var rng = MapSoakRNG(seed: 0xA0_2026_1004)
    var seen = Set<String>()
    var samples: [UInt64] = []
    samples.reserveCapacity(iterations)

    while samples.count < iterations {
        // 视口必须互不相同：同一视野第二次调用会命中缓存，测不出任何分配行为
        var picked: MapLayerViewport?
        for _ in 0..<1000 {
            let cx = (rng.value(2400, 10600) / 4).rounded() * 4
            let cy = (rng.value(2400, 10600) / 4).rounded() * 4
            let sp = (rng.value(600, 2000) / 4).rounded() * 4
            let k = "\(cx)|\(cy)|\(sp)"
            if !seen.contains(k) {
                seen.insert(k)
                picked = MapLayerViewport(centerX: cx, centerY: cy, spanPx: sp)
                break
            }
        }
        guard let vp = picked else { break }   // 理论不可达，防 RNG 退化时死循环

        // 图层开关轮换，把四条渲染分支都泡到（只泡 flags=7 会漏掉分支内的分配）
        let flags = [7, 7, 7, 3, 5, 1][samples.count % 6]
        // autoreleasepool：一次「渲染一帧」的完整生命周期，与真实 UI 帧一致
        autoreleasepool {
            _ = RoadOverlayCache.shared.overlay(roads: roads, graph: graph, poi: poi,
                                                viewport: vp.quantized, outSize: outSize,
                                                flags: flags)
        }
        guard let s = mapProcessRSSBytes() else { break }
        samples.append(s)
    }

    guard samples.count == iterations else {
        r.check("T5 · 浸泡采样完整", false, "只采到 \(samples.count)/\(iterations) 个样本")
        return
    }

    let first = samples[0]
    let last = samples[samples.count - 1]
    let peak = samples.max() ?? last
    let growthMB = Double(Int64(last) - Int64(first)) / 1_048_576.0

    // 分三段：比较「前 1/3 的平均增量」与「后 1/3 的平均增量」。
    // 真泄漏的特征是后段增量仍显著为正；只是启动期/分配器扩容的话，后段会回到 ~0。
    var deltas: [Double] = []
    deltas.reserveCapacity(samples.count - 1)
    for i in 1..<samples.count {
        deltas.append(Double(Int64(samples[i]) - Int64(samples[i - 1])) / 1_048_576.0)
    }
    let third = max(1, deltas.count / 3)
    let head = deltas[0..<third]
    let tail = deltas[(deltas.count - third)...]
    let headAvg = head.reduce(0, +) / Double(head.count)
    let tailAvg = tail.reduce(0, +) / Double(tail.count)

    r.check("T5 · RSS 增长 < 50MB", growthMB < 50,
            String(format: "增长 %+.2f MB（%.1f → %.1f MB，峰值 %.1f MB）",
                   growthMB, mapMB(first), mapMB(last), mapMB(peak)))
    r.check("T5 · 无单调上升趋势", tailAvg < 0.25 && tailAvg <= headAvg + 0.25,
            String(format: "前 1/3 平均增量 %+.3f MB/次 → 后 1/3 %+.3f MB/次（%d 个不同视口）",
                   headAvg, tailAvg, iterations))

    mapTestT5bBaseMapSoak(&r)
}

// ---------------------------------------------------------------------------
// MARK: T5b 底图取图路径浸泡（B1「视野窗口解码」的内存看守）
// ---------------------------------------------------------------------------

/// 浸泡**底图取图路径**（`MapTileCache.tile`），断言 RSS 不随视口数增长。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 【为什么必须单列一条】T5 只浸泡 `RoadOverlayCache`，**完全不碰 MapTileCache**。
/// 而 B1「3072² 视野窗口解码」把约 **37.7MB**（3072×3072×4）的窗口放进底图路径：
/// 若实现成「每次换窗新分配」，泄漏在 T5 里**根本看不见** —— 这正是
/// 「测试全绿但线上内存爆掉」的典型缺口。
///
/// 【预算先算清楚】37.7MB 窗口 vs 本条的 50MB 上限：
///   · 单窗口复用（正确实现）→ RSS 只涨一次 ≈ 38MB，**贴着上限但不超**
///   · 每次换窗新分配（错误实现）→ 60 个视口 × 38MB = 2.3GB，**必然爆**
/// 所以上限保持 50MB 是**故意**贴边的：它同时容忍「一次窗口」、拒绝「每次窗口」。
/// 若将来 B1 把窗口调大（如 4096² = 67MB），这里会立刻红 —— 那时该调的是
/// 上限与实现，而不是把断言删掉。
///
/// 【为什么用 outSize=600 而不是 1200】本条只关心**内存**，不关心像素。
/// 600² 输出让单次耗时降到 ~1/4，60 个视口才跑得动（否则要几十秒）。
/// 内存行为与 outSize 无关（窗口大小由 spanPx 决定，不由 outSize 决定）。
private func mapTestT5bBaseMapSoak(_ r: inout MapTestResult) {
    let iterations = 60
    let outSize: CGFloat = 600

    let bmPath = AuroraPaths.projectRoot()
        .appendingPathComponent("models/bigworldmap-13056.jpg").path
    guard FileManager.default.fileExists(atPath: bmPath),
          let img = NSImage(contentsOfFile: bmPath) else {
        r.check("T5b · 底图存在（前置条件）", false, "models/bigworldmap-13056.jpg 不可读")
        return
    }
    guard let rss0 = mapProcessRSSBytes() else {
        r.check("T5b · RSS 可读（mach task_info）", false, "task_info 失败")
        return
    }
    print("\n[T5b] 底图取图路径浸泡（\(iterations) 个视口，B1 视野窗口的内存看守）")
    r.info(String(format: "     起始 RSS %.1f MB（含 7.7MB JPEG 的懒解码句柄）", mapMB(rss0)))

    var rng = MapSoakRNG(seed: 0xB1_2026_1004)
    var samples: [UInt64] = []
    samples.reserveCapacity(iterations)
    var seen = Set<String>()

    while samples.count < iterations {
        var picked: MapLayerViewport?
        for _ in 0..<1000 {
            let cx = (rng.value(2400, 10600) / 4).rounded() * 4
            let cy = (rng.value(2400, 10600) / 4).rounded() * 4
            let sp = (rng.value(600, 3000) / 4).rounded() * 4
            let k = "\(cx)|\(cy)|\(sp)"
            if !seen.contains(k) {
                seen.insert(k)
                picked = MapLayerViewport(centerX: cx, centerY: cy, spanPx: sp)
                break
            }
        }
        guard let vp = picked else { break }

        autoreleasepool {
            if Thread.isMainThread {
                _ = MainActor.assumeIsolated {
                    MapTileCache.shared.tile(from: img, mapPixels: MapTileImage.mapPixels,
                                             centerX: vp.centerX, centerY: vp.centerY,
                                             spanPx: vp.spanPx, outSize: outSize)
                }
            }
        }
        guard let s = mapProcessRSSBytes() else { break }
        samples.append(s)
    }

    guard samples.count == iterations else {
        r.check("T5b · 采样完整", false, "只采到 \(samples.count)/\(iterations)")
        return
    }

    let first = samples[0], last = samples[samples.count - 1]
    let growthMB = Double(Int64(last) - Int64(first)) / 1_048_576.0
    let peak = samples.max() ?? last

    var deltas: [Double] = []
    for i in 1..<samples.count {
        deltas.append(Double(Int64(samples[i]) - Int64(samples[i - 1])) / 1_048_576.0)
    }
    let third = max(1, deltas.count / 3)
    let headAvg = deltas[0..<third].reduce(0, +) / Double(third)
    let tailAvg = deltas[(deltas.count - third)...].reduce(0, +) / Double(third)

    r.check("T5b · 底图路径 RSS 增长 < 50MB", growthMB < 50,
            String(format: "增长 %+.2f MB（%.1f → %.1f MB，峰值 %.1f MB，%d 个不同视口）",
                   growthMB, mapMB(first), mapMB(last), mapMB(peak), iterations))
    r.check("T5b · 底图路径无单调上升", tailAvg < 0.5 && tailAvg <= headAvg + 0.5,
            String(format: "前 1/3 平均增量 %+.3f MB/次 → 后 1/3 %+.3f MB/次（B1 窗口若每次新分配，这里会是 ~38MB/次）",
                   headAvg, tailAvg))
}

// ---------------------------------------------------------------------------
// MARK: T6 断网可用
// ---------------------------------------------------------------------------

private func mapTestT6(_ r: inout MapTestResult) {
    print("\n[T6] 断网可用（零远端依赖：源码静态扫描 + 本地底图）")

    // ── ① 静态扫描：源码里不许再出现远端瓦片 / 网页容器字样 ──
    // 专门防「以后有人又把远端瓦片或 WKWebView 塞回来」。
    // 扫描器自身（MapSelfTest.swift）必须排除 —— 下面 needles 的字面量就在这里，
    // 不排除会自匹配。除它以外 Sources/AuroraDrive 下所有 .swift 全扫。
    //
    // 【2026-10-07 精度修正】T6 原来把裸词 `"WebKit"` 当禁用词，结果误判
    //   `Agent/WebSearch.swift` —— 那里是 **HTTP User-Agent 字符串**里的
    //   `AppleWebKit/605.1.15`（浏览器标识），不是 WebKit 框架依赖。
    //   真实意图是「不许引入 WebKit 容器/框架」，故改成**精确匹配**：
    //     · `import WebKit`（框架导入）
    //     · `WKWebView`（网页容器，已单独在列）
    //   UA 字符串不再误伤。
    let needles = ["raw.githubusercontent.com", "maante.org",
                   "MapSource", "map-tiles", "import WebKit", "WKWebView"]
    let srcRoot = AuroraPaths.projectRoot().appendingPathComponent("Sources/AuroraDrive")
    var scanned = 0
    var hits: [String] = []
    if let en = FileManager.default.enumerator(at: srcRoot, includingPropertiesForKeys: nil) {
        var files: [URL] = []
        for case let u as URL in en where u.pathExtension == "swift" { files.append(u) }
        files.sort { $0.path < $1.path }
        for f in files where f.lastPathComponent != "MapSelfTest.swift" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            scanned += 1
            for n in needles where text.contains(n) {
                hits.append("\(f.lastPathComponent)→\(n)")
            }
        }
    }
    r.check("T6 · 静态扫描无远端依赖字样", scanned > 0 && hits.isEmpty,
            "扫描 \(scanned) 个 .swift，命中 \(hits.count) 处"
            + (hits.isEmpty ? "" : "：" + hits.prefix(5).joined(separator: "，")))
    r.info("     禁用词：\(needles.joined(separator: " / "))（排除扫描器自身）")

    // ── ② 底图必须来自本地，且能被 MapTileImage 的真实取图路径加载 ──
    let bmPath = AuroraPaths.projectRoot()
        .appendingPathComponent("models/bigworldmap-13056.jpg").path
    let exists = FileManager.default.fileExists(atPath: bmPath)
    r.check("T6 · 本地底图存在", exists, "models/bigworldmap-13056.jpg")

    var decodedOK = false
    var tileOK = false
    var dims = "—"
    var tileMs = 0.0
    // 提升到函数级：下面的「冷 tile 门禁」复测时还要用同一张源图
    let bmImage: NSImage? = exists ? NSImage(contentsOfFile: bmPath) : nil
    if let img = bmImage {
        if let rep = img.representations.first {
            dims = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            decodedOK = (rep.pixelsWide == 13056 && rep.pixelsHigh == 13056)
        }
        // MapTileImage 生产路径就是 MapTileCache.tile（@MainActor）。
        // 自检从 CLI 主线程进来，用 assumeIsolated 声明「我确实在主线程」。
        if Thread.isMainThread {
            let t0 = mapNowNs()
            let tile = MainActor.assumeIsolated {
                MapTileCache.shared.tile(from: img, mapPixels: MapTileImage.mapPixels,
                                         centerX: 6528, centerY: 6528,
                                         spanPx: 1200, outSize: 1200)
            }
            tileMs = Double(mapNowNs() - t0) / 1e6
            tileOK = (tile?.width == 1200 && tile?.height == 1200)
        } else {
            r.info("     ⚠️ 非主线程调用，跳过 MapTileCache 取图验证")
        }
    }
    r.check("T6 · 底图可解码为 13056×13056", decodedOK, dims)
    r.check("T6 · MapTileImage 取图路径可用", tileOK,
            String(format: "MapTileCache.tile → 1200×1200，%.1f ms", tileMs))
    // 冷 tile 的真实成本取决于走了哪条解码路径（B1 之后有两条）：
    //   · spanPx ≤ 3072（≲1874m）→ **视野窗口**：首次解码 3072² ≈ 42~74ms，
    //     窗口内换视野只做 1:1 crop+draw（~18ms）
    //   · spanPx > 3072（4000m/12000m）→ 窗口装不下视口，回**源图直裁**：
    //     每次都要全图解码 80~130ms（空载）/ 388.7ms（高负载）
    // 阈值 300ms × 负载系数 —— 空载时仍是 300ms，一旦有人把解码改慢到秒级照样红灯。
    //
    // ⚠️ 复测必须**跨越换窗阈值**：`MapTileCache` 有 (中心,span,out) 量化键缓存
    //    **且**有视野窗口（`ViewportWindowMetrics.recenterDistance = 3072×1/4 = 768px`）。
    //    只挪 400px 会落在同一个窗口里 → 测出 2.31ms 的窗口命中，
    //    那不是「冷解码」，是自欺（第一版就是挪 400px，被这条注释记下来）。
    //    故每轮挪 4000px（> 768），强制重建窗口 = 真实冷路径。
    if let img = bmImage {
        var tileProbeIdx = 0
        mapGateWithRetry(&r, name: "T6 · 冷 tile < 300ms（×负载系数）",
                         base: 300, extra: "spanPx=1200 out=1200 冷解码（跨越换窗阈值 4000px）") {
            tileProbeIdx += 1
            let cx = 6528 + Double(tileProbeIdx) * 4000
            guard Thread.isMainThread else { return Double.infinity }
            let t = mapNowNs()
            _ = MainActor.assumeIsolated {
                MapTileCache.shared.tile(from: img, mapPixels: MapTileImage.mapPixels,
                                         centerX: cx, centerY: 6528,
                                         spanPx: 1200, outSize: 1200)
            }
            return Double(mapNowNs() - t) / 1e6
        }
    }
}

// ============================================================================
// MARK: - T7 底图 ↔ 路网 像素级对齐 + 方向一致性（2026-10-05）
// ============================================================================
//
// 【为什么必须有 T7】用户实测报告「拖动时路网与底图朝**相反方向**跑」，
//   而 `--map-selftest` **34 项全绿**。为什么全绿却抓不住？因为：
//     · `T2` 只验「同一 MapViewport 下的**归一化一致性**」——那是**数学恒等式**：
//       只要两层共用同一个 `MapViewport` 公式，它就恒过，
//       而它**从不渲染任何像素**，所以渲染侧的翻转/错位它结构上看不见。
//     · `T4` 的视野是 `centerX: 6528, centerY: 6528` —— **地图正中**。
//       而 X 相关误差（历史事故 `oxOut` 多算了 `2·qx·s`）在正中**恰好为零**。
//       拿正中当唯一测试点 = 永远测不出 X 方向的错。
//   本测试补上这两块：**真渲染** + **视口必须离中心** + **显式判方向**。
//
// 【判据（四条，每条都必须能失败）】
//   ① 路网像素覆盖率落在合理区间 —— 防「路网根本没画出来」时后面三条变成空断言
//   ② 路网像素下的底图亮度显著高于底图整体均值（道路在底图上更亮）
//   ③ 把路网掩码**水平镜像**后得分必须更低（否则 X 翻转）
//   ④ 把路网掩码**垂直镜像**后得分必须更低（否则 Y 翻转）
//
// 【坐标轴口径】镜像是相对**输出画布中心**（`side/2`）做的，不是相对地图中心。
//   这正是「用户在屏幕上看到翻转」的等价判据。

/// 把 CGImage 画进固定边长 RGBA 缓冲，返回灰度与 alpha。
///
/// 位图格式固定 `premultipliedFirst | byteOrder32Little` ⇒ 内存序 **BGRA**，
/// 与 `MapTileCache` / `RoadOverlayCache` 内部一致（不猜通道顺序）。
private func mapRasterize(_ img: CGImage, side: Int) -> (gray: [Double], alpha: [UInt8])? {
    let bpr = side * 4
    var buf = [UInt8](repeating: 0, count: side * bpr)
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let ctx = CGContext(data: base, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard ok else { return nil }
    var gray = [Double](repeating: 0, count: side * side)
    var alpha = [UInt8](repeating: 0, count: side * side)
    for i in 0..<(side * side) {
        let o = i * 4
        let b = Double(buf[o]), g = Double(buf[o + 1]), r = Double(buf[o + 2])
        gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
        alpha[i] = buf[o + 3]
    }
    return (gray, alpha)
}

private func mapTestT7(_ r: inout MapTestResult) {
    print("\n[T7] 底图 ↔ 路网 像素级对齐 + 方向一致性")

    guard Thread.isMainThread else {
        r.check("T7 · 主线程前置条件", false, "本测试必须跑在主线程")
        return
    }
    let bmPath = AuroraPaths.projectRoot()
        .appendingPathComponent("models/bigworldmap-13056.jpg").path
    guard let bm = NSImage(contentsOfFile: bmPath) else {
        r.check("T7 · 底图可读（前置条件）", false, "models/bigworldmap-13056.jpg 打不开")
        return
    }
    MapLayerStore.shared.ensureLoaded()
    let deadline = Date().addingTimeInterval(20)
    while !MapLayerStore.shared.isReady && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let roads = MapLayerStore.shared.roads else {
        r.check("T7 · 路网就绪（前置条件）", false, "roads == nil —— 本测试会变成空断言，直接判失败")
        return
    }

    let side = 512
    // ── 视口中心**取自真实折线的包围盒中心**，不是拍脑袋的坐标 ──────────
    // 第一版手写了 5 个坐标（含 9028,6528），结果那个点落在**海上**：
    // 底图均值 3.7、路网覆盖率 0.00% → 三条方向断言变成「0.0 vs 0.0」，
    // 全过但什么都没验（**空断言**）。覆盖率那条断言当场把它抓了出来。
    // 现在改成数据驱动：按包围盒面积取最长的折线，并强制中心两两相距 ≥1500px，
    // 保证每个视口都真的压着路网、且分散在地图各处（X 方向尤其要散开）。
    let ranked = roads.boxes.enumerated()
        .filter { $0.element.width.isFinite && $0.element.height.isFinite }
        .sorted { ($0.element.width * $0.element.height) > ($1.element.width * $1.element.height) }
    var cases: [(String, Double, Double, Double)] = []
    for (i, b) in ranked {
        guard cases.count < 5 else { break }
        let mx = Double(b.midX), my = Double(b.midY)
        guard mx.isFinite, my.isFinite else { continue }
        if cases.contains(where: { hypot($0.1 - mx, $0.2 - my) < 1500 }) { continue }
        let dx = Int(mx - 6528)
        cases.append(("最长折线#\(i)（中心 X\(dx >= 0 ? "+" : "")\(dx)px）", mx, my, 1200))
    }
    // 至少要有 3 个有效视口，否则本测试不构成方向验证 —— 直接判失败而不是"少测几条"
    r.check("T7 · 有效视口数 ≥ 3（前置条件）", cases.count >= 3,
            "实得 \(cases.count) 个（数据驱动选取，太少说明折线数据异常）")
    if cases.isEmpty {
        return
    }

    for (name, cx, cy, span) in cases {
        let vp = MapLayerViewport(centerX: cx, centerY: cy, spanPx: span).quantized
        let baseImg = MainActor.assumeIsolated {
            MapTileCache.shared.tile(from: bm, viewport: vp,
                                     mapPixels: MapTileImage.mapPixels,
                                     outSize: CGFloat(side))
        }
        // flags = 1（只画路网）：掩码越干净，方向判定越锐利
        let ovImg = MainActor.assumeIsolated {
            RoadOverlayCache.shared.overlay(roads: roads, graph: nil, poi: [],
                                            viewport: vp, outSize: CGFloat(side), flags: 1)
        }
        guard let b = baseImg.flatMap({ mapRasterize($0, side: side) }),
              let o = ovImg.flatMap({ mapRasterize($0, side: side) }) else {
            r.check("T7 · \(name)：两层都渲染出来", false, "base 或 overlay 为 nil")
            continue
        }
        let mask = o.alpha.map { $0 > 32 }
        let cov = Double(mask.filter { $0 }.count) / Double(side * side)

        func flipX(_ m: [Bool]) -> [Bool] {
            var out = [Bool](repeating: false, count: m.count)
            for y in 0..<side {
                for x in 0..<side { out[y * side + (side - 1 - x)] = m[y * side + x] }
            }
            return out
        }
        func flipY(_ m: [Bool]) -> [Bool] {
            var out = [Bool](repeating: false, count: m.count)
            for y in 0..<side {
                for x in 0..<side { out[(side - 1 - y) * side + x] = m[y * side + x] }
            }
            return out
        }
        func score(_ m: [Bool]) -> Double {
            var s = 0.0; var n = 0
            for i in 0..<m.count where m[i] { s += b.gray[i]; n += 1 }
            return n > 0 ? s / Double(n) : 0
        }
        let baseMean = b.gray.reduce(0, +) / Double(b.gray.count)
        let idS = score(mask), fxS = score(flipX(mask)), fyS = score(flipY(mask))

        // ① 防空断言：路网没画出来时，下面三条会「全过」——那才是真正的假绿。
        //    下界取 0.15%：512² 的 0.15% ≈ 393 px，足够构成一个有意义的掩码；
        //    而「没画出来」是 0.00%（实测过：选到海上的视口就是 0.00%，
        //    当时三条方向断言全变成「0.0 vs 0.0」——正是这条断言把它抓出来的）。
        //    上界 60% 防「整张图都被当成路网」（那说明掩码取错了，方向判定无意义）。
        r.check("T7 · \(name)：路网覆盖率合理", cov > 0.0015 && cov < 0.60,
                String(format: "覆盖 %.2f%%（0.00%%=没画出来，本测试将变成空断言）", cov * 100))
        // ② 对齐：道路在底图上比平均更亮
        r.check("T7 · \(name)：路网落在亮路面上", idS > baseMean * 1.15,
                String(format: "路网下亮度 %.1f vs 底图均值 %.1f（%.2f×）",
                       idS, baseMean, idS / max(1, baseMean)))
        // ③ X 方向：原样必须优于水平镜像
        r.check("T7 · \(name)：X 方向未翻转", idS > fxS * 1.15,
                String(format: "原样 %.1f vs X镜像 %.1f —— 若镜像更高即为左右反了", idS, fxS))
        // ④ Y 方向
        r.check("T7 · \(name)：Y 方向未翻转", idS > fyS * 1.15,
                String(format: "原样 %.1f vs Y镜像 %.1f —— 若镜像更高即为上下反了", idS, fyS))
    }
}

// ============================================================================
// MARK: - 入口
// ============================================================================

/// 运行地图严格自检。返回 0 = 全部通过。
func runMapSelfTest() -> Int {
    var r = MapTestResult()
    print("═══ 原生地图严格自检（--map-selftest）═══")

    // ── T1 坐标黄金样本 ──
    print("\n[T1] 坐标黄金样本（世界 → 地图像素，阈值 0.5px）")
    var worst = 0.0
    for s in kGoldenSamples {
        let mx = DriveState.worldToMapPixelX(s.wx, s.wy)
        let my = DriveState.worldToMapPixelY(s.wx, s.wy)
        let err = hypot(mx - s.mx, my - s.my)
        worst = max(worst, err)
        r.check("世界(\(Int(s.wx)), \(Int(s.wy)))",
                err < 0.5,
                String(format: "期望(%d,%d) 实得(%.1f,%.1f) 误差%.2fpx", Int(s.mx), Int(s.my), mx, my, err))
    }
    r.info(String(format: "最大误差 %.3f px（阈值 0.5）", worst))

    // ── T1b 往返一致性 ──
    print("\n[T1b] 世界 → 像素 → 世界 往返（阈值 1e-6 px）")
    var worstRT = 0.0
    for s in kGoldenSamples {
        let e = DriveState.roundTripPixelError(wx: s.wx, wy: s.wy)
        worstRT = max(worstRT, e)
    }
    r.check("往返误差", worstRT < 1e-6, String(format: "%.3e px", worstRT))

    // ── T2 图层对齐（视口唯一来源）──
    print("\n[T2] 图层对齐（同一 MapViewport 下的归一化一致性）")
    let vp = MapLayerViewport(centerX: 6528, centerY: 6528, spanPx: 1200)
    let center = vp.normalized(x: 6528, y: 6528)
    r.check("视口中心归一化", abs(center.x - 0.5) < 1e-9 && abs(center.y - 0.5) < 1e-9,
            String(format: "(%.6f, %.6f)", center.x, center.y))
    let corner = vp.normalized(x: 6528 - 600, y: 6528 - 600)
    r.check("视口左上角归一化", abs(corner.x - 0.0) < 1e-9 && abs(corner.y - 0.0) < 1e-9,
            String(format: "(%.6f, %.6f)", corner.x, corner.y))
    // 量化必须稳定：同一视野反复量化结果一致（否则底图与叠加层会错位）
    let q1 = vp.quantized
    let q2 = vp.quantized.quantized
    r.check("视口量化幂等", q1 == q2, "\(q1.centerX),\(q1.centerY),\(q1.spanPx)")

    // ── T3 图层加载 ──
    print("\n[T3] 图层加载（数量须与数据文件一致）")
    MapLayerStore.shared.ensureLoaded()
    let deadline = Date().addingTimeInterval(20)
    while !MapLayerStore.shared.isReady && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let store = MapLayerStore.shared
    r.check("图层加载完成", store.isReady, String(format: "%.1f ms", store.loadMs))
    r.check("路网线段 = 1517", store.roads?.count == 1517, "实得 \(store.roads?.count ?? -1)")
    // 【2026-10-07 更新】路网修复后（612→664 节点 / 825→932 边，断头 118→36）
    //   骨架边基线从 825 改为 932。旧断言的 825 是修复前快照。
    r.check("骨架边 = 932", store.graph?.count == 932, "实得 \(store.graph?.count ?? -1)")
    r.check("POI = 1622", store.poi.count == 1622, "实得 \(store.poi.count)")
    if let err = store.loadError { r.info("⚠️ \(err)") }

    // ── 标记数据库：按组统计必须与「生成器写进点位的内嵌 group」对账 ──
    //
    // 这条是 `MapDatabase.countByGroup` 的**自验证**（2026-10-04 合并真源时新增）。
    // 它是从点位内嵌 `group` 现算的真源派生量，期望值就是 `map_categories.json`
    // 的 `count` 字段 —— 两者不一致 = 「点位内嵌组」与「分类表」分家了，
    // 正是本次合并要结构性消灭的那类事故。
    //
    // ⚠️ 必须在 `MapDatabase` 加载**之后**取数（`markers` 为空时统计恒为 0，
    //    那会变成另一种"假绿"）。`ensureLoadedSyncLegacy()` 幂等，这里显式调用。
    MapDatabase.ensureLoadedSyncLegacy()
    let cbg = MapDatabase.countByGroup
    let cbgExpect: [String: Int] = ["explore": 450, "resource": 1045, "travel": 28,
                                    "monster": 254, "shop": 0, "service": 0, "landmark": 0]
    // 判据用 `?? 0`：`countByGroup` 是**纯派生量** —— 只统计实际出现过的组，
    // 没有点位的组**缺席而非置 0**。这是刻意的：它不依赖任何外部组清单，
    // 因此**结构上不可能与数据源分家**（若为凑齐 7 个键去读组清单，
    // 就又把「组清单」变成了第二个真源）。消费方统一用 `?? 0` 即可。
    let cbgBad = cbgExpect.filter { (cbg[$0.key] ?? 0) != $0.value }
    let cbgTotal = cbg.values.reduce(0, +)
    let withGroup = MapDatabase.markers.filter { $0.group != nil }.count
    r.check("标记按组统计与 map_categories.json 一致",
            !MapDatabase.markers.isEmpty && cbgBad.isEmpty && cbgTotal == 1777,
            "合计 \(cbgTotal)（期望 1777），点位 \(MapDatabase.markers.count)"
            + (cbgBad.isEmpty ? "" : "；不符 \(cbgBad)"))
    r.check("标记点位全部有组（内嵌 group 非空）", withGroup == 1777,
            "有组 \(withGroup)/\(MapDatabase.markers.count)")

    // ── 视口剔除正确性：全图视野必须包含所有折线 ──
    if let roads = store.roads {
        let all = roads.visibleIndices(in: CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6))
        r.check("视口剔除（全图包含全部）", all.count == roads.count,
                "\(all.count)/\(roads.count)")
        let none = roads.visibleIndices(in: CGRect(x: -1e6, y: -1e6, width: 1, height: 1))
        r.check("视口剔除（远处应为空）", none.isEmpty, "\(none.count) 条")
    }

    // ── T4~T6 由 MapSelfTestExt 补充（性能门禁 / 内存浸泡 / 断网）──
    runMapSelfTestExt(&r)

    // ── 汇总 ──
    print("")
    for line in r.lines { print(line) }
    print("\n═══════════════════════════════════════")
    print("  通过 \(r.passed)   失败 \(r.failed)")
    print("═══════════════════════════════════════")
    return r.failed == 0 ? 0 : 1
}
