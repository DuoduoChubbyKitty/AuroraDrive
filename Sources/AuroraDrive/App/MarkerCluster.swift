// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ═══════════════════════════════════════════════════════════════════════════
// 【出处标注 · 品牌澄清】2026-10-04
//   本文件的**聚类格边长取值（52 px）**对齐上游开源项目 **MaaNTE**
//   （其 `maxClusterRadius: 52`）。下文注释里的小写「maante」= 该上游项目，
//   用于交代这个 52 是哪来的 —— **它不是本产品的品牌**。
//   本产品品牌：`AuroraDrive`（见 `App/AuroraBrand.swift`）。
//   保留出处的理由：「为什么是 52 而不是 48/64」只有回到上游取值才能复核；
//   抹掉出处会让这个数变成无法追问的魔法数字。
//   故：出处保留；品牌层（用户可见字符串 / 标识符）不得出现上游名。
// ═══════════════════════════════════════════════════════════════════════════
// ============================================================================
//  MarkerCluster.swift — 标记网格聚类（C 阶段）
// ============================================================================
//
//  ── 为什么必须聚类 ────────────────────────────────────────────────────────
//  实测（中心 6500,6500，52 屏幕 px 格）：
//
//      视野      格边长    视野内标记   聚团数    压缩比
//      120 m     10 px         19        16      1.2×
//      300 m     26 px         53        37      1.4×
//      1200 m   102 px        855       241      3.5×
//      3000 m   256 px       4824       305     15.8×
//      6000 m   511 px       5635       114     49.4×
//      12000 m 1023 px       5677        39    145.6×
//
//  即：越往外拉视野，压缩越猛。但**最关键的一条是：单一 52px 规则在全
//  120 m ~ 12 km 区间都成立**，不需要按 zoom 分级 —— 最坏情况 305 个团，
//  Canvas 画 305 个圆约 0.2 ms，远在预算内。
//
//  ── 为什么格边长要用「屏幕像素」而不是「地图像素」 ──────────────────────
//  格边长 = (clusterPx / 视野屏幕宽度) × 视野地图像素。
//  这样**屏幕上每个格子的视觉大小恒定**（52 px），与上游参考项目 MaaNTE 的
//  `maxClusterRadius: 52` 同源。若直接用固定地图像素格，放大时格子会越来越
//  稀疏（近处该合并的没合并），缩小时又会把整片糊成一坨。
//
//  ── 代表点优先级 ──────────────────────────────────────────────────────────
//  一团里选谁当代表？按语义重要性：
//      传送点 > 探索度 > 资源 > 商店 > 服务 > 怪物 > 地标
//  理由：用户看地图主要为了「去哪」，传送点/资源是决策目标；
//  地标（viewpoint）数量大且信息量低，不该抢掉一个传送站的显示位置。

import Foundation
import SwiftUI

/// 一个聚团（或单个未成团的标记）
struct MarkerCluster: Identifiable {
    /// 稳定 id：未成团用标记 id；成团用「格坐标 + 代表点 id」。
    /// 不用「格子序号」是因为格子序号会随视野中心平移而整体漂移，
    /// 导致 SwiftUI 每帧都认为所有元素都是新的（动画错乱 + 无谓重建）。
    let id: String
    /// 代表点
    let representative: MapDatabase.PlacedMarker
    /// 团内标记总数（含代表点）。1 = 未成团
    let count: Int
    /// 团内所有标记（未成团时只有一个）。用于点击展开/详情面板。
    let members: [MapDatabase.PlacedMarker]

    var isCluster: Bool { count > 1 }
    /// 团的形心（地图像素）—— 比代表点位置更能代表整团
    let centerX: Double
    let centerY: Double
}

enum MarkerClusterer {

    /// 聚类格边长（屏幕像素）。默认 52，对齐上游参考项目 MaaNTE 的 maxClusterRadius。
    static var clusterPx: Double { clusterPxCached }

    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 为什么环境变量要**缓存**而不是每次现读
    /// ══════════════════════════════════════════════════════════════════════
    /// 实测：`ProcessInfo.processInfo.environment` 单次读取 **0.032 ms**
    /// （macOS 上它每次都要重建整个环境字典）。
    ///
    /// 原先 `priority` 写成计算属性、`rank()` 又在两个循环里逐点调用，
    /// 541 个点要读上千次环境 → 光这一项就 **35 ms+**，
    /// 聚类整体实测 120 ms（正常应 <1 ms）—— 一个"读环境变量"的写法
    /// 把聚类拖慢了 100 倍。
    ///
    /// 这种错最难发现：代码逻辑完全正确、结果也对，只是慢。
    /// 所以这里用 `static let` 只读一次，之后都是内存访问。
    private static let clusterPxCached: Double = {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_CLUSTER_PX"],
           let v = Double(s), v >= 8, v <= 400 { return v }
        return 52
    }()

    /// 代表点优先级（组 id → 权重，越小越优先）。
    /// `AURORA_MAP_CLUSTER_PRIORITY` 可用逗号分隔的组 id 覆写。
    /// 同样必须缓存，理由见 `clusterPxCached`。
    static var priority: [String: Int] { priorityCached }

    private static let priorityCached: [String: Int] = {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_CLUSTER_PRIORITY"], !s.isEmpty {
            var m: [String: Int] = [:]
            for (i, g) in s.split(separator: ",").enumerated() {
                m[g.trimmingCharacters(in: .whitespaces)] = i
            }
            if !m.isEmpty { return m }
        }
        return ["travel": 0, "explore": 1, "resource": 2,
                "shop": 3, "service": 4, "monster": 5, "landmark": 6]
    }()

    private static func rank(_ m: MapDatabase.PlacedMarker) -> Int {
        // 用已缓存的 priority（**不要**在这里现读环境变量 —— 见 priorityCached）
        if let g = m.group, let r = priorityCached[g] { return r }
        return 99   // 无组信息（词表缺失）排最后，但仍会被显示，不会丢
    }

    /// 预先把每个标记的 rank 算好：`rank()` 内含字典查找，
    /// 在「代表点选择」的内层循环里逐点调用会重复付出这个成本。
    /// 用一个局部字典缓存，541 个点只需算一遍。
    private static func rankTable(_ markers: [MapDatabase.PlacedMarker]) -> [String: Int] {
        var t: [String: Int] = [:]
        t.reserveCapacity(markers.count)
        let p = priorityCached
        for m in markers {
            if let g = m.group, let r = p[g] { t[m.id] = r } else { t[m.id] = 99 }
        }
        return t
    }

    /// 网格聚类。
    ///
    /// - Parameters:
    ///   - spanPx: 视野边长（**地图像素**）
    ///   - viewWidth: 视野在屏幕上的宽度（点）。决定「屏幕格」的地图尺寸。
    ///   - centerX/Y: 视野中心（地图像素）。**格原点与世界坐标对齐，不看视野** ——
    ///     见下方 A15 说明（旧版以视野左上角为原点，拖动时格线跟着平移）。
    static func cluster(_ markers: [MapDatabase.PlacedMarker],
                        spanPx: Double,
                        viewWidth: Double,
                        centerX: Double,
                        centerY: Double) -> [MarkerCluster] {
        guard !markers.isEmpty, spanPx > 0, viewWidth > 1 else { return [] }
        // 52 屏幕 px 对应多少地图像素
        let cell = max(1.0, (clusterPx / viewWidth) * spanPx)

        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-10-04（A15）：格原点改为**世界坐标对齐**，不再跟着视野走
        // ══════════════════════════════════════════════════════════════════
        // 【旧行为】`gx = Int((m.mapX - left) / cell)`，left = 视野左上角。
        //   后果：**视野每移动一点，格线就跟着平移** —— 同一个点的格号一直在变，
        //   团的成员与 `+N` 数字持续重组跳动，拖起来满屏数字在闪。
        //   （旧注释写「这样拖动时格边界跟着视野走，屏幕上的格线是稳定的」，
        //    只说对了屏幕侧，漏了「成员不稳定」这一半。）
        // 【新行为】格号只由世界坐标决定：`floor(mapX / cell)`。
        //   拖动时格线**钉死在世界里**，团稳定；只有缩放（cell 变）才重划格。
        // 【键的打包】旧写法 `(gx+4096) << 13 | (gy+4096)` 只在小范围成立
        //   （旧语义下 gx/gy 只是「视野内第几格」，很小）。世界对齐后
        //   gx/gy 可达 13056/cell，cell=1 时 13056+4096 = 17152 > 2¹³
        //   → **高位字段会溢出污染低位**，两个不同的格会算出同一个键。
        //   故改为 21 位字段 + 10⁶ 偏移（|gx|,|gy| < 10⁶ 时无碰撞）。
        let cellBits: Int64 = 1 << 21
        let cellBias: Int64 = 1_000_000
        func cellKey(_ x: Double, _ y: Double) -> Int64 {
            let gx = Int64((x / cell).rounded(.down)) + cellBias
            let gy = Int64((y / cell).rounded(.down)) + cellBias
            return gx &* cellBits &+ gy
        }

        // 分组：格 → 成员
        var buckets: [Int64: [MapDatabase.PlacedMarker]] = [:]
        buckets.reserveCapacity(markers.count / 2 + 16)
        for m in markers {
            buckets[cellKey(m.mapX, m.mapY), default: []].append(m)
        }

        // rank 表：预先算好，避免内层循环里反复做字典查找 + 读 environment
        let ranks = rankTable(markers)

        var out: [MarkerCluster] = []
        out.reserveCapacity(buckets.count)
        for (_, members) in buckets {
            if members.count == 1 {
                let m = members[0]
                out.append(MarkerCluster(id: m.id, representative: m, count: 1,
                                         members: members, centerX: m.mapX, centerY: m.mapY))
                continue
            }
            // 选代表：优先级最高；同优先级取离形心最近的（视觉更居中）
            var sx = 0.0, sy = 0.0
            for m in members { sx += m.mapX; sy += m.mapY }
            let cx = sx / Double(members.count), cy = sy / Double(members.count)
            var best = members[0]
            var bestKey = (ranks[best.id] ?? 99, Double.infinity)
            for m in members {
                let d = (m.mapX - cx) * (m.mapX - cx) + (m.mapY - cy) * (m.mapY - cy)
                let key = (ranks[m.id] ?? 99, d)
                if key < bestKey { bestKey = key; best = m }
            }
            // 团 id 用「代表点 id + 成员数」：代表点变了（优先级变了）或
            // 团大小变了都会重新生成 id，SwiftUI 会正确重建而不是错位复用。
            out.append(MarkerCluster(id: "c:\(best.id):\(members.count)",
                                     representative: best, count: members.count,
                                     members: members, centerX: cx, centerY: cy))
        }
        // 稳定输出顺序：先按优先级，再按坐标 —— 保证同输入同输出
        // （否则 Dictionary 遍历顺序随机，截图每次都不同，无法做 A/B 比对）
        // 用预排序键而不是比较器里查表：比较器会被调用 O(n log n) 次，
        // 每次查两次字典在 300+ 团时也不是零成本。
        var keyed: [(rank: Int, y: Double, x: Double, c: MarkerCluster)] = []
        keyed.reserveCapacity(out.count)
        for c in out {
            keyed.append((ranks[c.representative.id] ?? 99, c.centerY, c.centerX, c))
        }
        keyed.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }
        return keyed.map { $0.c }
    }

    /// 按组筛选（**必须在聚类前调用**）。
    ///
    /// 为什么强调顺序：若先聚类再过滤，团的 `count` 会包含被隐藏组的成员，
    /// 用户看到「+12」点开却只有 3 个 —— 数字骗人比没数字更糟。
    ///
    /// ⚠️ 参数是**中文名（groupLabel）**不是组 id。
    /// 原因：筛选条的 state 里存的是用户能看懂的中文名，而地图上画的是
    /// `groupLabel`；若这里改成用 id 比较，就需要在 UI 层做一次 id↔名转换，
    /// 两边一旦不同步（比如词表里改了 label）就会出现「点了没反应」。
    /// 全链路统一用中文名，只有一处口径。
    ///
    /// 词表缺失（`groupLabel == nil`）时**无条件通过** —— 不能因为分类坏了
    /// 就让地图空掉。
    static func filter(_ markers: [MapDatabase.PlacedMarker],
                       enabledLabels: Set<String>) -> [MapDatabase.PlacedMarker] {
        guard !enabledLabels.isEmpty else { return [] }
        return markers.filter { m in
            guard let label = m.groupLabel else { return true }
            return enabledLabels.contains(label)
        }
    }
}
