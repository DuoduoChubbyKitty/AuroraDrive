// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RouteGraph.swift — 路网图 + A*(拐弯惩罚) 路径规划
// ============================================================================
//
//  数据来源：models/route_graph.json
//    由 tools/roadnet/v5_to_graph.py 从 V5 中心线（1px 骨架）抽出，再经
//    tools/roadnet/export_route_web.py 导出。同一份文件驱动网页版工具
//    （tools/roadnet/web/index.html），故本实现是**网页版算法的逐行移植**，
//    数值语义必须与之一致 —— 冻结基线见 `--route-selftest`。
//
//  与网页版的对照关系（改本文件前先看那边）：
//    navRoute()      ↔ RoutePlanner.route(...)
//    dirAt()         ↔ RouteGraph.dirAt(...)
//    endNode/leaveDir/arriveDir ↔ 同名静态方法
//    nearestNode()   ↔ RouteGraph.nearestNode(...)
//    stateId()       ↔ RoutePlanner.stateID(...)
//
//  ── 为什么状态是「半边」而不是「节点」────────────────────────────────────
//  只用节点建图**算不出拐弯**：到路口时只知道"我在这"，不知道"我从哪条路
//  拐进来"，也就无从计算转向角。故状态定义为
//      state = (edgeIndex, dirFlag)      dirFlag 0 = a→b，1 = b→a
//  共 2×825 = 1650 个状态。有了「进入路口的朝向」，才能
//      cost = 边长 + W × (转向角 / 90°)
//  这才是「拐弯最少」能被 A* 优化的前提。
//
//  ── 为什么启发式用欧氏直线还是最优 ───────────────────────────────────────
//      h(u) = hypot(Δx, Δy) × 米/像素
//  两点之间直线最短，而实际还要沿路绕行，故 h 恒 ≤ 真实剩余代价
//  （可采纳 admissible）→ 不会高估 → A* 的解仍然最优。
//  实测：展开节点数 214 vs Dijkstra 的 410，答案分毫不差。

import Foundation
import CoreGraphics

// ============================================================================
// MARK: - 路网图
// ============================================================================

/// 路网图（只读，加载后不可变）。
///
/// 线程约定：`load()` 可在任意线程调用（内部串行）；`shared` 的读取
/// 在加载完成后从主线程访问是安全的（加载完成前 `shared` 为 nil）。
final class RouteGraph {

    // ── 数据 ──

    /// 节点坐标（地图像素，与 worldToMapPixel 输出同系）
    let nodes: [(x: Double, y: Double)]
    /// 边：起点节点、终点节点、长度（米）、折线（地图像素）
    let edges: [(a: Int, b: Int, len: Double, poly: [(Double, Double)])]
    /// 每条边两端「离开该端点」的单位方向向量：`[离开 a, 离开 b]`
    let dirs: [[(Double, Double)]]
    /// 邻接表：`inc[node] = [(edgeIndex, dirFlag)]`
    let inc: [[(Int, Int)]]

    /// 米 / 地图像素（1 像素 = 0.61 m）
    let metersPerPixel: Double
    /// 地图边长（像素）
    let mapSize: Double
    /// 来源描述（写进日志，便于确认加载的是哪份数据）
    let source: String

    /// 网格加速用的格子边长（地图像素）
    static let gridCell = 200.0
    /// 网格：`(gx, gy)` → 节点下标数组（经 `gridKey` 编码）
    private let grid: [Int64: [Int]]

    /// 取方向向量时沿边走多少像素（与网页版 NAV_LM 一致）
    static let dirLookAheadPx = 6.0

    // MARK: 构造

    private init(nodes: [(x: Double, y: Double)],
                 edges: [(a: Int, b: Int, len: Double, poly: [(Double, Double)])],
                 metersPerPixel: Double,
                 mapSize: Double,
                 source: String) {
        self.nodes = nodes
        self.edges = edges
        self.metersPerPixel = metersPerPixel
        self.mapSize = mapSize
        self.source = source

        // dirs + inc：一次遍历建成（与网页版 loadNav 同构）
        var dirsOut: [[(Double, Double)]] = []
        dirsOut.reserveCapacity(edges.count)
        var incOut: [[(Int, Int)]] = Array(repeating: [], count: nodes.count)
        for (i, e) in edges.enumerated() {
            dirsOut.append([
                Self.dirAt(poly: e.poly, atStart: true),
                Self.dirAt(poly: e.poly, atStart: false),
            ])
            incOut[e.a].append((i, 0))
            incOut[e.b].append((i, 1))
        }
        self.dirs = dirsOut
        self.inc = incOut

        // 网格哈希：nearestNode 用（替代上千次线性扫描）
        var g: [Int64: [Int]] = [:]
        for (i, n) in nodes.enumerated() {
            g[Self.gridKey(Int(n.x / Self.gridCell), Int(n.y / Self.gridCell)), default: []].append(i)
        }
        self.grid = g
    }

    private static func gridKey(_ gx: Int, _ gy: Int) -> Int64 {
        // 地图 13056 / 200 = 65 格，偏移 1024 保证非负，乘 4096 无冲突
        Int64(gx + 1024) << 12 | Int64(gy + 1024)
    }

    // MARK: 方向向量

    /// 从端点沿折线走 ≥6px 取方向（对齐网页版 `dirAt`）。
    ///
    /// 注意网页版原实现里 `acc` 是**死变量**（每轮覆盖、从未用于判断），
    /// 真正的判据是 `seg >= 6`。本实现保留同样的语义 —— 别"顺手修正"，
    /// 否则 `dirs` 会与冻结基线不一致。
    static func dirAt(poly: [(Double, Double)], atStart: Bool) -> (Double, Double) {
        guard !poly.isEmpty else { return (0, 0) }
        let pts = atStart ? poly : poly.reversed()
        let p0 = pts[0]
        guard pts.count > 1 else { return (0, 0) }
        var last = pts[1]
        for i in 1..<pts.count {
            let seg = hypot(pts[i].0 - p0.0, pts[i].1 - p0.1)
            last = pts[i]
            if seg >= dirLookAheadPx || i == pts.count - 1 { break }
        }
        let dx = last.0 - p0.0, dy = last.1 - p0.1
        let n = hypot(dx, dy)
        return n > 0 ? (dx / n, dy / n) : (0, 0)
    }

    // MARK: 半边状态

    /// 半边状态编号：边 i 正向 = 2i，反向 = 2i+1
    @inline(__always) static func stateID(_ edge: Int, _ dirFlag: Int) -> Int { 2 * edge + dirFlag }
    @inline(__always) static func stEdge(_ state: Int) -> Int { state >> 1 }
    @inline(__always) static func stFwd(_ state: Int) -> Bool { (state & 1) == 0 }

    /// 沿该半边走到哪一端（对齐网页版 `endNode`）。
    ///
    /// ⚠️ 第一版把 df 索引写反过 → 起终点永远对不上、全部不可达。三处必须一致：
    ///    endNode    = df ? edges[i][0] : edges[i][1]
    ///    leaveDir   = dirs[i][df ? 1 : 0]
    ///    arriveDir  = -dirs[i][df ? 0 : 1]
    @inline(__always) static func endNode(edges: [(a: Int, b: Int, len: Double, poly: [(Double, Double)])],
                                          _ i: Int, _ df: Int) -> Int {
        df == 1 ? edges[i].a : edges[i].b
    }

    @inline(__always) func endNode(_ i: Int, _ df: Int) -> Int {
        df == 1 ? edges[i].a : edges[i].b
    }

    /// 离开该半边当前所在端的单位方向
    @inline(__always) func leaveDir(_ i: Int, _ df: Int) -> (Double, Double) {
        dirs[i][df == 1 ? 1 : 0]
    }

    /// 沿该半边「进入」当前端时的行进方向（= 离开方向的取反）
    @inline(__always) func arriveDir(_ i: Int, _ df: Int) -> (Double, Double) {
        let d = dirs[i][df == 1 ? 0 : 1]
        return (-d.0, -d.1)
    }

    // MARK: 最近节点

    /// 吸附：找离 (x,y) 最近的节点。返回 nil 表示图为空。
    /// 同心方环向外扩，与网页版 `nearestNode` 同判据。
    func nearestNode(x: Double, y: Double) -> Int? {
        guard !nodes.isEmpty else { return nil }
        let c = Self.gridCell
        let gx0 = Int(x / c), gy0 = Int(y / c)
        for r in 0..<40 {
            var best = -1
            var bd = Double.infinity
            for gx in (gx0 - r)...(gx0 + r) {
                for gy in (gy0 - r)...(gy0 + r) {
                    guard let arr = grid[Self.gridKey(gx, gy)] else { continue }
                    for i in arr {
                        let n = nodes[i]
                        let d = (n.x - x) * (n.x - x) + (n.y - y) * (n.y - y)
                        if d < bd { bd = d; best = i }
                    }
                }
            }
            if best >= 0, r > 0, bd <= Double(r * r) * c * c { return best }
            if best >= 0, r >= 3 { return best }
        }
        // 极端兜底：全图线性扫描（只在图非常稀疏时才会走到）
        var best = 0
        var bd = Double.infinity
        for (i, n) in nodes.enumerated() {
            let d = (n.x - x) * (n.x - x) + (n.y - y) * (n.y - y)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    // MARK: 加载

    /// 已加载的图（进程内单例）。`ensureLoaded()` 之前为 nil。
    private(set) static var shared: RouteGraph?
    private static var isLoading = false
    private static var didTry = false
    /// 最近一次加载失败原因（供 UI 如实显示，不编造）
    private(set) static var loadError: String?

    /// 图文件路径。可用 `AURORA_ROUTE_GRAPH` 覆写（便于 A/B 换图）。
    static var graphURL: URL {
        if let p = ProcessInfo.processInfo.environment["AURORA_ROUTE_GRAPH"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return AuroraPaths.modelsDir().appendingPathComponent("route_graph.json")
    }

    /// 幂等异步加载（后台线程读盘+解析，主线程落 `shared`）。
    /// 模板与语义对齐 `MapDatabase.ensureLoaded()`：绝不在 body 求值期做磁盘 I/O。
    static func ensureLoaded() {
        if shared != nil || isLoading { return }
        isLoading = true
        loadError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadFromDisk()
            DispatchQueue.main.async {
                switch result {
                case .success(let g):
                    shared = g
                    print("[ROUTEGRAPH] 已加载 \(g.source) 节点=\(g.nodes.count) 边=\(g.edges.count)")
                case .failure(let e):
                    loadError = e.description
                    print("[ROUTEGRAPH] ✗ \(e)")
                }
                isLoading = false
                didTry = true
            }
        }
    }

    /// 同步加载（**仅离屏夹具**使用；真机 UI 一律走 `ensureLoaded()`）。
    @discardableResult
    static func ensureLoadedSync() -> Bool {
        if shared != nil { return true }
        switch loadFromDisk() {
        case .success(let g):
            shared = g
            print("[ROUTEGRAPH] 已加载 \(g.source) 节点=\(g.nodes.count) 边=\(g.edges.count)")
            didTry = true
            return true
        case .failure(let e):
            loadError = e.description
            didTry = true
            print("[ROUTEGRAPH] ✗ \(e)")
            return false
        }
    }

    enum LoadFailure: Error, CustomStringConvertible {
        case fileMissing(String)
        case parseFailed(String)
        case malformed(String)

        var description: String {
            switch self {
            case .fileMissing(let p): return "路网文件不存在：\(p)"
            case .parseFailed(let p): return "路网 JSON 解析失败：\(p)"
            case .malformed(let why): return "路网结构非法：\(why)"
            }
        }
    }

    private static func loadFromDisk() -> Result<RouteGraph, LoadFailure> {
        let url = graphURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileMissing(url.path))
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .failure(.fileMissing(url.path))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.parseFailed(url.path))
        }
        guard let meta = root["meta"] as? [String: Any],
              let rawNodes = root["nodes"] as? [[Any]],
              let rawEdges = root["edges"] as? [[Any]] else {
            return .failure(.malformed("缺少 meta/nodes/edges"))
        }

        let mPerPx = (meta["m_per_px"] as? NSNumber)?.doubleValue ?? 0.61
        let mapSize = (meta["map_size"] as? NSNumber)?.doubleValue ?? 13056
        let source = (meta["source"] as? String) ?? url.lastPathComponent

        // nodes: [[id, x, y]]
        var nodes: [(x: Double, y: Double)] = []
        nodes.reserveCapacity(rawNodes.count)
        for n in rawNodes {
            guard n.count >= 3,
                  let x = (n[1] as? NSNumber)?.doubleValue,
                  let y = (n[2] as? NSNumber)?.doubleValue else {
                return .failure(.malformed("nodes 项格式应为 [id,x,y]"))
            }
            nodes.append((x: x, y: y))
        }

        // edges: [[a, b, len_m, poly]]
        var edges: [(a: Int, b: Int, len: Double, poly: [(Double, Double)])] = []
        edges.reserveCapacity(rawEdges.count)
        for e in rawEdges {
            guard e.count >= 4,
                  let a = (e[0] as? NSNumber)?.intValue,
                  let b = (e[1] as? NSNumber)?.intValue,
                  let len = (e[2] as? NSNumber)?.doubleValue,
                  let rawPoly = e[3] as? [[Any]] else {
                return .failure(.malformed("edges 项格式应为 [a,b,len,poly]"))
            }
            guard a >= 0, a < nodes.count, b >= 0, b < nodes.count else {
                return .failure(.malformed("边端点越界：\(a)→\(b)（节点数 \(nodes.count)）"))
            }
            var poly: [(Double, Double)] = []
            poly.reserveCapacity(rawPoly.count)
            for p in rawPoly {
                guard p.count >= 2,
                      let px = (p[0] as? NSNumber)?.doubleValue,
                      let py = (p[1] as? NSNumber)?.doubleValue else {
                    return .failure(.malformed("poly 点格式应为 [x,y]"))
                }
                poly.append((px, py))
            }
            edges.append((a: a, b: b, len: len, poly: poly))
        }

        guard !nodes.isEmpty, !edges.isEmpty else {
            return .failure(.malformed("节点或边为空"))
        }

        return .success(RouteGraph(nodes: nodes, edges: edges,
                                   metersPerPixel: mPerPx, mapSize: mapSize,
                                   source: source))
    }
}

// ============================================================================
// MARK: - 路径规划（A* + 拐弯惩罚）
// ============================================================================

/// 一次规划的结果。
struct RoutePlan {
    /// 路线总长（米）
    let distanceMeters: Double
    /// 转向超过阈值（25°）的次数
    let turns: Int
    /// 经过的边数
    let segments: Int
    /// 折线顶点（地图像素），已按行进顺序排列
    let points: [(Double, Double)]
    /// 规划耗时（毫秒）
    let elapsedMs: Double
    /// 起点节点 / 终点节点
    let startNode: Int
    let endNode: Int

    /// 折线总顶点数（便于日志/自检断言）
    var pointCount: Int { points.count }
}

enum RouteError: Error, CustomStringConvertible {
    case graphMissing
    case startEqualsEnd
    case unreachable

    var description: String {
        switch self {
        case .graphMissing:   return "路网未加载"
        case .startEqualsEnd: return "起点与终点是同一节点"
        case .unreachable:    return "两点之间没有可达路径"
        }
    }
}

/// 路由器：纯计算，无状态，可从任意线程调用。
enum RoutePlanner {

    /// 转向判定阈值（度）。超过它才算「拐弯」。
    static let turnThresholdDeg = 25.0
    /// `turnsFirst` 模式下对拐弯的惩罚（实质是字典序：先比拐弯数，再比距离）
    static let turnsFirstPenalty = 1e7
    /// 默认拐弯权重（实测最优：与字典序同解但更快更短）
    static let defaultTurnWeight: Double = {
        if let s = ProcessInfo.processInfo.environment["AURORA_ROUTE_TURN_W"],
           let v = Double(s) { return v }
        return 200
    }()

    /// 规划从 `s` 到 `t`（节点下标）的路线。
    ///
    /// - Parameters:
    ///   - turnWeight: 拐弯权重 W，`cost = 边长 + W×(角度/90°)`
    ///   - turnsFirst: true 时改用字典序（拐弯数优先，用大常数惩罚）
    static func route(graph: RouteGraph,
                      from s: Int,
                      to t: Int,
                      turnWeight W: Double = defaultTurnWeight,
                      turnsFirst: Bool = false) throws -> RoutePlan {
        let t0 = DispatchTime.now()
        guard s != t else { throw RouteError.startEqualsEnd }

        let nEdges = graph.edges.count
        let stateCount = nEdges * 2

        // h：欧氏直线（可采纳 → 不破坏最优性）
        let mPerPx = graph.metersPerPixel
        @inline(__always)
        func h(_ u: Int) -> Double {
            let a = graph.nodes[u], b = graph.nodes[t]
            return hypot(a.x - b.x, a.y - b.y) * mPerPx
        }

        var gScore = [Double](repeating: .infinity, count: stateCount)
        var prev = [Int](repeating: -1, count: stateCount)
        var closed = [Bool](repeating: false, count: stateCount)

        // 手写二叉堆（与网页版同构：元素为 (f, 插入序, state)）
        var heap: [(f: Double, seq: Int, st: Int)] = []
        heap.reserveCapacity(4096)
        var seq = 0
        func push(_ f: Double, _ st: Int) {
            heap.append((f, seq, st)); seq += 1
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) >> 1
                if heap[p].f <= heap[i].f { break }
                heap.swapAt(p, i); i = p
            }
        }
        func pop() -> (f: Double, seq: Int, st: Int) {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count, heap[l].f < heap[m].f { m = l }
                    if r < heap.count, heap[r].f < heap[m].f { m = r }
                    if m == i { break }
                    heap.swapAt(m, i); i = m
                }
            }
            return top
        }

        // 初始化：从 s 出发的所有半边
        for (i, flag) in graph.inc[s] {
            let df = flag
            let st = RouteGraph.stateID(i, df)
            let g = graph.edges[i].len
            if g < gScore[st] {
                gScore[st] = g
                prev[st] = -1
                push(g + h(graph.endNode(i, df)), st)
            }
        }

        var goal = -1
        while !heap.isEmpty {
            let (_, _, st) = pop()
            if closed[st] { continue }
            closed[st] = true

            let i = RouteGraph.stEdge(st)
            let df = RouteGraph.stFwd(st) ? 0 : 1
            let u = graph.endNode(i, df)
            if u == t { goal = st; break }

            let aD = graph.arriveDir(i, df)
            let g0 = gScore[st]
            for (j, flag) in graph.inc[u] {
                if j == i { continue }   // 同一条边原路折返不算换路
                let df2 = flag
                let st2 = RouteGraph.stateID(j, df2)
                if closed[st2] { continue }
                let d1 = aD
                let d2 = graph.leaveDir(j, df2)
                let dot = max(-1.0, min(1.0, d1.0 * d2.0 + d1.1 * d2.1))
                let ang = acos(dot) * 180.0 / .pi
                let pen = turnsFirst
                    ? (ang > turnThresholdDeg ? turnsFirstPenalty : 0)
                    : W * (ang / 90.0)
                let ng = g0 + graph.edges[j].len + pen
                if ng < gScore[st2] {
                    gScore[st2] = ng
                    prev[st2] = st
                    push(ng + h(graph.endNode(j, df2)), st2)
                }
            }
        }

        guard goal >= 0 else { throw RouteError.unreachable }

        // 回溯
        var chain: [Int] = []
        var cur = goal
        while cur >= 0 { chain.append(cur); cur = prev[cur] }
        chain.reverse()

        var dist = 0.0
        var turns = 0
        var pts: [(Double, Double)] = []
        for (k, st) in chain.enumerated() {
            let i = RouteGraph.stEdge(st)
            let df = RouteGraph.stFwd(st) ? 0 : 1
            let e = graph.edges[i]
            dist += e.len
            if k > 0 {
                let pst = chain[k - 1]
                let pi = RouteGraph.stEdge(pst)
                let pdf = RouteGraph.stFwd(pst) ? 0 : 1
                let d1 = graph.arriveDir(pi, pdf)
                let d2 = graph.leaveDir(i, df)
                let dot = max(-1.0, min(1.0, d1.0 * d2.0 + d1.1 * d2.1))
                let ang = acos(dot) * 180.0 / .pi
                if ang > turnThresholdDeg { turns += 1 }
            }
            let poly = df == 1 ? e.poly.reversed() : e.poly
            for p in poly {
                if let l = pts.last, l.0 == p.0, l.1 == p.1 { continue }
                pts.append(p)
            }
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        return RoutePlan(distanceMeters: dist, turns: turns, segments: chain.count,
                         points: pts, elapsedMs: ms, startNode: s, endNode: t)
    }

    /// 便捷入口：按地图像素坐标规划（内部各做一次最近节点吸附）。
    static func route(graph: RouteGraph,
                      fromPixel: (Double, Double),
                      toPixel: (Double, Double),
                      turnWeight W: Double = defaultTurnWeight,
                      turnsFirst: Bool = false) throws -> RoutePlan {
        guard let s = graph.nearestNode(x: fromPixel.0, y: fromPixel.1),
              let t = graph.nearestNode(x: toPixel.0, y: toPixel.1) else {
            throw RouteError.graphMissing
        }
        return try route(graph: graph, from: s, to: t, turnWeight: W, turnsFirst: turnsFirst)
    }
}
