// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RoadCornerGuide.swift — 弯道打点集的运行时查询与按键决策
//
//  数据源：models/road_corners_v2.json（由 models/tools/make_road_corners_v2.py 生成）
//
//  【为什么需要打点集，而不是只靠实时视觉】
//    视觉识别（车道线）在弯道/路口经常失效或混杂；地图是**固定不变**的先验，
//    知道"路往哪拐"。用户明确要求：到了该转弯的地方，用地图指引转向。
//
//  【v2 打点的三个关键性质（v1 错在这三点，用户 2026-09-30 当面指出）】
//    1. **密集**：沿弯道每 ~23m 一个点（952 个位置），不是"一个弯道一个点" ——
//       否则车从别的位置/车道进入就漏掉了。
//    2. **双向**：同一位置生成两条记录（两个进入方向各一条，turnSign 相反），
//       因为一条弯道两个方向都能走，反向进入时左右转相反。
//       匹配时必须按「自车当前 heading」选方向一致的记录，否则会反向打轮。
//    3. 路口也留了数据（branchCount ≥ 3，记录各分支方向），
//       但**转向决策暂不覆盖路口**（先保弯道），仅用于日志与后续扩展。
//
//  【与 RoadMapPrior 的分工】
//    RoadMapPrior   = 位图先验（2048² 路网栅格）→ isOnRoad / roadHeadingCandidates
//    RoadCornerGuide = 打点集（离散弯道记录）  → cornerAhead / steerForCorner
//    两者互补：打点集回答"前面有没有已知弯道、往哪拐"，位图回答"我现在在不在路上"。
//
//  【安全边界】
//    · 本模块**只输出建议**（方向 + 强度），不做最终限幅；
//      最终仍走 applyLaneAdvice + applyCommand（±0.1 死区 → 按 A/D），
//      maxSteer 0.25 硬限幅与"油门只压不抬"结构不变。
//    · 任何不确定（没加载出来 / 定位不可信 / 角度差过大）→ 返回 nil，回落视觉。
// ============================================================================

import Foundation

// MARK: - 数据模型

/// 一条路口支路（对应 road_corners_v3b.json 里 junction 的 branches 元素）
///
/// 【为什么要 reach 与 width 两个维度】
///   路口选路时，光靠"哪条支路最贴近车头"不够 —— 实测 12.8% 的情形
///   有 2 条以上支路都落在车头 25° 内（Y 形岔路），此时必须判断**哪条是主路**，
///   否则会拐进小巷。主路判据：先比射线可达长度（reach），同级再比宽度（width）。
struct RoadBranch {
    /// 支路方向（罗盘角，0=北，90=东）
    let deg: Double
    /// 射线可达长度（米）—— 沿该方向"连续有路"能走多远
    let reachM: Double
    /// 支路宽度（格，1 格 = 3.89 m）
    let widthCells: Double
    /// 长度是否触到测量上限（触顶说明"至少这么长"，实际可能更长，比较时降权）
    let reachSaturated: Bool
    /// 宽度是否有效（算法退化时为 false，不参与比较）
    let widthValid: Bool
}

/// 一条弯道打点记录（对应 road_corners_v2.json / v3b.json 的一个元素）
struct RoadCorner {
    let worldX: Double
    let worldY: Double
    let gridX: Int
    let gridY: Int
    /// 进入方向（罗盘角 0=北，90=东）—— 车"沿着这个朝向"驶来时该记录生效
    let headingIn: Double?
    /// 出弯方向（罗盘角）
    let headingOut: Double?
    /// 弯度（两分支夹角偏离 180° 的度数，越大越弯）
    let turnDeg: Double
    /// 转向符号（+1 = 右转，-1 = 左转），已按该记录的进入方向定好
    let turnSign: Int
    /// 曲率半径（米）
    let radiusM: Double
    /// 档位：急 / 中 / 缓 / 路口
    let grade: String
    /// bend = 弯道，junction = 路口
    let type: String
    /// 分支数（2 = 弯道，≥3 = 路口）
    let branchCount: Int
    /// 路口各支路（含长度/宽度，用于主路判据）；弯道为空数组
    let branches: [RoadBranch]
    /// 该记录由几个原始打点聚类而来（路口去重用，≥2 说明合并过）
    let clustered: Int
    
    init(worldX: Double, worldY: Double, gridX: Int, gridY: Int,
         headingIn: Double?, headingOut: Double?, turnDeg: Double, turnSign: Int,
         radiusM: Double, grade: String, type: String, branchCount: Int,
         branches: [RoadBranch] = [], clustered: Int = 1) {
        self.worldX = worldX; self.worldY = worldY
        self.gridX = gridX; self.gridY = gridY
        self.headingIn = headingIn; self.headingOut = headingOut
        self.turnDeg = turnDeg; self.turnSign = turnSign
        self.radiusM = radiusM; self.grade = grade
        self.type = type; self.branchCount = branchCount
        self.branches = branches; self.clustered = clustered
    }

    var isBend: Bool { type == "bend" }
    var isJunction: Bool { type == "junction" }
}

/// 前方弯道的命中结果
struct CornerHit {
    let corner: RoadCorner
    /// 到该点的直线距离（米，世界坐标欧氏距离）
    let distanceM: Double
    /// 自车当前朝向与该记录进入方向的夹角（度，0~180）—— 越小说明方向越匹配
    let headingDiffDeg: Double
}

// MARK: - 引导器

final class RoadCornerGuide {

    static let shared = RoadCornerGuide()

    // MARK: 可调参数（AURORA_CORNER_* 环境变量可覆盖）

    /// 提前量：距弯道点多远开始按地图转向（米）
    private let lookaheadM: Double
    /// 方向匹配容差：自车朝向与该记录进入方向夹角超过此值 → 该记录不适用（度）
    private let headingMatchTolDeg: Double
    /// 转向死区：角度差小于此值不按方向键（度，避免抖动）
    private let steerDeadbandDeg: Double
    /// 角度差达到此值时输出满强度（度）
    private let steerSaturationDeg: Double
    /// 判定"已过该点"的距离（米）：车已驶过弯道点这么远 → 认为该点完成
    private let passedMarginM: Double

    /// 「前方锥」半角（度）：候选点的**方位**与车头夹角必须在此锥内，
    /// 否则视为"侧方/后方"的点，不采纳（打点密集时防止朝侧前方打方向）。
    private let aheadConeDeg: Double

    // ── 路口参数（AURORA_JUNC_*）──
    /// 前方多远处开始处理路口（路口点比弯道稀疏，故比弯道略远）
    private let junctionLookaheadM: Double
    /// 进入"开始转向"的距离（米）
    private let junctionApproachM: Double
    /// 去重：与"来路方向"接近到多少度内的支路视为来路，排除
    private let excludeInDeg: Double
    /// 判为 Y 形岔路的夹角容差（度）：落在此范围内的支路算"同向"
    private let forkTolDeg: Double
    /// 主路判据：长度比超过此值才算"明显主路"，否则转比宽度
    private let reachRatio: Double

    /// 预警降速阈值：弯道半径小于此值且车速高于阈值 → 建议降速（米）
    private let tightRadiusM: Double
    private let tightRadiusSpeedKmh: Double

    // MARK: 状态

    private var corners: [RoadCorner] = []
    private var loaded = false
    private var loadAttempted = false
    private let lock = NSLock()

    // ── 空间索引（★ 2026-09-30 性能优化）──
    //
    // 【为什么必须做】基线实测：`cornerAhead` **31.4 ms/次**，比 yolopx 单次推理
    //   （68.9ms）的一半还贵 —— 而它在 `.rule` 档**每帧都被调用**。
    //   根因：线性扫描 1904 条弯道记录 × 3 次 `headingDiff`（含 mod/abs）
    //   + `compassBearing`（atan2）≈ 8000 次浮点三角运算。
    //
    // 【做法】把点按地面格子分桶（默认 128m/格），查询只扫"自车所在格 + 邻格"。
    //   查前方 40m 的弯道点，其一定落在 3×3 格范围内（128 > 40 + 打点散布）。
    //   分桶是**加**出来的：`cornerAhead` 结果与线性扫描**逐位一致**（见自检对拍）。
    private struct GridKey: Hashable { let gx: Int; let gy: Int }
    private var bendIndex: [GridKey: [RoadCorner]] = [:]
    private var junctionIndex: [GridKey: [RoadCorner]] = [:]
    /// 索引格边长（米）
    private static let indexCellMeters: Double = 128.0

    private static func gridKey(worldX: Double, worldY: Double) -> GridKey {
        GridKey(gx: Int(floor(worldX / (indexCellMeters * 100.0))),
                gy: Int(floor(worldY / (indexCellMeters * 100.0))))
    }

    /// 建索引：按类型分桶
    private func buildIndex() {
        bendIndex.removeAll(keepingCapacity: true)
        junctionIndex.removeAll(keepingCapacity: true)
        for c in corners {
            let k = Self.gridKey(worldX: c.worldX, worldY: c.worldY)
            if c.isBend { bendIndex[k, default: []].append(c) }
            else if c.isJunction { junctionIndex[k, default: []].append(c) }
        }
    }

    /// 取自车周围 3×3 格内的候选（覆盖 128~384m 半径，远超 40~45m 前瞻量）
    private func candidates(_ index: [GridKey: [RoadCorner]],
                            worldX: Double, worldY: Double) -> [RoadCorner] {
        let c = Self.gridKey(worldX: worldX, worldY: worldY)
        var out: [RoadCorner] = []
        out.reserveCapacity(64)
        for dx in -1...1 {
            for dy in -1...1 {
                if let arr = index[GridKey(gx: c.gx + dx, gy: c.gy + dy)] {
                    out.append(contentsOf: arr)
                }
            }
        }
        return out
    }

    /// 诊断：最近一次查询说明（UI / 日志用）
    private(set) var lastQueryReason: String = "未查询"
    /// 诊断：最近命中的弯道（用于日志观察段切换）
    private(set) var lastHit: CornerHit?

    private init() {
        // A17 迁移（2026-10-04）：13 个开关统一走 `AuroraFlags`。
        // 原来在这里 `let env = ProcessInfo.processInfo.environment` 然后逐个
        // `env["X"].flatMap(Double.init) ?? 默认值` —— 默认值散在 13 行里，
        // 想知道"不设变量会怎样"必须逐行读。现在默认值与说明都在 AuroraFlags。
        // `RoadCornerGuide` 是单例（`static let shared`），本 init 只跑一次，
        // 故语义与"现读一次"完全等价，默认值逐字未变。
        lookaheadM = AuroraFlags.cornerLookaheadM
        headingMatchTolDeg = AuroraFlags.cornerHeadingTolDeg
        steerDeadbandDeg = AuroraFlags.cornerDeadbandDeg
        steerSaturationDeg = AuroraFlags.cornerSatDeg
        passedMarginM = AuroraFlags.cornerPassedM
        aheadConeDeg = AuroraFlags.cornerConeDeg
        junctionLookaheadM = AuroraFlags.juncLookaheadM
        junctionApproachM = AuroraFlags.juncApproachM
        excludeInDeg = AuroraFlags.juncExcludeDeg
        forkTolDeg = AuroraFlags.juncForkTolDeg
        reachRatio = AuroraFlags.juncReachRatio
        tightRadiusM = AuroraFlags.cornerTightRM
        tightRadiusSpeedKmh = AuroraFlags.cornerTightSpeed
    }

    // MARK: - 加载

    /// 懒加载打点集。找不到 / 解析失败 → loaded=false，所有查询返回 nil（fail-open）
    func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loadAttempted else { return }
        loadAttempted = true

        guard let url = Self.locateResource() else {
            lastQueryReason = "打点集未找到（road_corners_v3b.json）"
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            lastQueryReason = "打点集读取失败"
            return
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            lastQueryReason = "打点集解析失败"
            return
        }

        var out: [RoadCorner] = []
        out.reserveCapacity(raw.count)
        for item in raw {
            guard let wx = item["worldX"] as? Double,
                  let wy = item["worldY"] as? Double else { continue }
            // 支路解析：v3b 为对象数组 {deg,reachM,widthCells,reachSat,widthValid}；
            // v2 只有数字数组（纯角度）→ 长度/宽度置 0 且标为无效（不参与主路判据）。
            var branches: [RoadBranch] = []
            if let rawBranches = item["branches"] as? [Any] {
                for rb in rawBranches {
                    if let d = rb as? [String: Any],
                       let deg = (d["deg"] as? NSNumber)?.doubleValue {
                        branches.append(RoadBranch(
                            deg: deg,
                            reachM: (d["reachM"] as? NSNumber)?.doubleValue ?? 0,
                            widthCells: (d["widthCells"] as? NSNumber)?.doubleValue ?? 0,
                            reachSaturated: d["reachSat"] as? Bool ?? false,
                            widthValid: d["widthValid"] as? Bool ?? false))
                    } else if let deg = (rb as? NSNumber)?.doubleValue {
                        branches.append(RoadBranch(deg: deg, reachM: 0, widthCells: 0,
                                                   reachSaturated: false, widthValid: false))
                    }
                }
            }
            out.append(RoadCorner(
                worldX: wx,
                worldY: wy,
                gridX: (item["gridX"] as? NSNumber)?.intValue ?? 0,
                gridY: (item["gridY"] as? NSNumber)?.intValue ?? 0,
                headingIn: (item["headingIn"] as? NSNumber)?.doubleValue,
                headingOut: (item["headingOut"] as? NSNumber)?.doubleValue,
                turnDeg: (item["turnDeg"] as? NSNumber)?.doubleValue ?? 0,
                turnSign: (item["turnSign"] as? NSNumber)?.intValue ?? 0,
                radiusM: (item["radiusM"] as? NSNumber)?.doubleValue ?? 0,
                grade: item["grade"] as? String ?? "",
                type: item["type"] as? String ?? "bend",
                branchCount: (item["branchCount"] as? NSNumber)?.intValue ?? 2,
                branches: branches,
                clustered: (item["clustered"] as? NSNumber)?.intValue ?? 1))
        }
        guard !out.isEmpty else {
            lastQueryReason = "打点集为空"
            return
        }
        corners = out
        buildIndex()          // ★ 空间索引（性能优化，见 buildIndex 注释）
        loaded = true
        let nb = out.filter { $0.isBend }.count
        let nj = out.count - nb
        let withBranches = out.filter { $0.isJunction && !$0.branches.isEmpty }.count
        lastQueryReason = "打点集已加载（弯道 \(nb) 条 / 路口 \(nj) 条，其中 \(withBranches) 条含支路长度宽度）"
    }

    private static func locateResource() -> URL? {
        let name = "road_corners_v3b"
        var candidates: [URL] = []
        // ⚠️ 2026-09-30：Bundle 查找必须同时覆盖 Resources **根目录**与 **models/ 子目录**。
        //   `Bundle.main.url(forResource:withExtension:)` 只在 Resources 根目录找、
        //   **不递归子目录**；而部署时我们是拷到 `Contents/Resources/models/` 下的
        //   （与开发目录 models/ 结构一致）。漏掉子目录的症状是：
        //   从 .app 里跑自检 → "打点集未加载" → 静默 fail-open 回落视觉（功能全废）。
        if let u = Bundle.main.url(forResource: name, withExtension: "json",
                                   subdirectory: "models") { candidates.append(u) }
        if let u = Bundle.main.url(forResource: name, withExtension: "json") { candidates.append(u) }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("models/\(name).json"))
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
            .deletingLastPathComponent()
        for base in [exeDir, exeDir.deletingLastPathComponent(),
                     exeDir.deletingLastPathComponent().deletingLastPathComponent(),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            candidates.append(base.appendingPathComponent("models/\(name).json"))
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }

    var isLoaded: Bool {
        ensureLoaded()
        return loaded
    }

    var cornerCount: Int {
        ensureLoaded()
        return corners.count
    }

    // MARK: - 查询

    /// 前方最近的**适用**弯道点。
    ///
    /// 「适用」的定义（缺一不可）：
    ///   · 是弯道（bend）—— 路口本轮不参与转向决策，避免误导
    ///   · 在提前量 lookaheadM 以内
    ///   · 方向匹配：自车当前 heading 与该记录 headingIn 的夹角 ≤ headingMatchTolDeg
    ///     （★双向打点的意义所在：同一位置两条记录，只有方向对的那条会被选中，
    ///       从而保证 turnSign 的左右不会反）
    ///
    /// - Parameters:
    ///   - worldX/worldY: 自车世界坐标（cm）
    ///   - headingDeg: 自车罗盘朝向（0=北，90=东）
    func cornerAhead(worldX: Double, worldY: Double, headingDeg: Double) -> CornerHit? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded else { return nil }

        var best: CornerHit? = nil
        // ★ 只扫自车周围 3×3 格（性能优化：31.4ms → 亚毫秒）
        //   注意 lookaheadM(40m) << 索引格(128m)，故 3×3 格必然包含全部候选，
        //   结果与全量线性扫描等价（自检里做对拍验证）。
        for c in candidates(bendIndex, worldX: worldX, worldY: worldY) where c.isBend {
            guard let hin = c.headingIn else { continue }
            let dx = c.worldX - worldX, dy = c.worldY - worldY
            let dist = (dx * dx + dy * dy).squareRoot() / 100.0     // cm → m
            guard dist <= lookaheadM else { continue }
            let diff = Self.headingDiff(headingDeg, hin)
            guard diff <= headingMatchTolDeg else { continue }

            // ── 必须在"前方锥"内（★ 2026-09-30 自检闭环探针抓出的缺陷）──
            // 打点是**密集**的（每 ~23m 一个），同一弯道附近有多个点。
            // 若只按"最近"选，可能选中侧方 60°+ 的点 —— 朝它打方向会把车带下路。
            // 因此要求该点方位与车头夹角 ≤ aheadConeDeg（默认 75°），
            // 这样车只会朝"前方"的点走。
            let bearing = Self.compassBearing(fromX: worldX, fromY: worldY,
                                              toX: c.worldX, toY: c.worldY)
            let bearDiff = Self.headingDiff(headingDeg, bearing)
            guard bearDiff <= aheadConeDeg else { continue }
            // 选最近且方向最匹配的：先按距离，同距离取方向差小的
            if let b = best {
                if dist < b.distanceM - 0.5 ||
                   (abs(dist - b.distanceM) <= 0.5 && diff < b.headingDiffDeg) {
                    best = CornerHit(corner: c, distanceM: dist, headingDiffDeg: diff)
                }
            } else {
                best = CornerHit(corner: c, distanceM: dist, headingDiffDeg: diff)
            }
        }
        lastHit = best
        if let b = best {
            lastQueryReason = String(format: "前方 %.0fm %@弯 半径%.0fm 转%@%.0f°",
                                     b.distanceM, b.corner.grade,
                                     b.corner.radiusM,
                                     b.corner.turnSign > 0 ? "右" : "左",
                                     b.corner.turnDeg)
        } else {
            lastQueryReason = "前方无适用弯道点"
        }
        return best
    }

    /// 由弯道点 + 自车**当前位置**算出转向建议。
    ///
    /// 【两阶段目标（2026-09-30 修，自检闭环探针抓出的缺陷）】
    ///   原先直接用 `headingOut`（出弯方向）当目标 —— 但车还在弯道点**后方几十米**时，
    ///   出弯方向与车头可能差 100°+，会导致"还没到弯就先掰 100°"的荒谬指令。
    ///   正确做法按"车相对弯道点的位置"分两段：
    ///     · **进弯前**（距点 > approachM）：目标是**朝弯道点开**（bearing），
    ///       车沿进入方向逼近即可，不需要转向。
    ///     · **接近/过点**（≤ approachM）：目标转向 `headingOut`（出弯方向），
    ///       这才是"地图指引的转向"。
    ///
    /// - Parameters:
    ///   - hit: cornerAhead 的命中结果
    ///   - headingDeg: 自车罗盘朝向
    ///   - worldX/worldY: 自车世界坐标（cm）—— 用于判断处在哪一段
    /// - Returns: (steer, reason)，steer ∈ [-1,1]，正 = 右（与 ControlCommand.steer 同号）
    func steerForCorner(_ hit: CornerHit, headingDeg: Double,
                        worldX: Double, worldY: Double) -> (steer: Double, reason: String) {
        let approachM = 25.0        // 进入"开始转向"的距离阈值
        let dist = hit.distanceM

        // 阶段 1：进弯前 —— 目标 = 朝弯道点开
        if dist > approachM {
            let bearing = Self.compassBearing(fromX: worldX, fromY: worldY,
                                              toX: hit.corner.worldX, toY: hit.corner.worldY)
            let diff = Self.signedHeadingDiff(from: headingDeg, to: bearing)
            let mag = abs(diff)
            if mag <= steerDeadbandDeg {
                return (0, String(format: "进弯前 %@（距 %.0fm，已对准，差 %.1f°）",
                                  hit.corner.grade, dist, diff))
            }
            let span = max(1.0, steerSaturationDeg - steerDeadbandDeg)
            let norm = min(1.0, (mag - steerDeadbandDeg) / span)
            let steer = (diff > 0 ? 1.0 : -1.0) * max(minNormSteer, norm * 0.5)
            return (steer, String(format: "进弯前对准：向%@ %.0f°（距 %.0fm，差 %.1f°）",
                                  diff > 0 ? "右" : "左", mag, dist, diff))
        }

        // 阶段 2：接近/过点 —— 目标 = 出弯方向（地图指引的转向）
        guard let target = hit.corner.headingOut ?? hit.corner.headingIn else {
            return (0, "弯道点无出弯方向")
        }
        let diff = Self.signedHeadingDiff(from: headingDeg, to: target)
        let mag = abs(diff)
        if mag <= steerDeadbandDeg {
            return (0, String(format: "已对齐出弯方向（距 %.0fm，差 %.1f°）", dist, diff))
        }
        let span = max(1.0, steerSaturationDeg - steerDeadbandDeg)
        let norm = min(1.0, (mag - steerDeadbandDeg) / span)
        let steer = (diff > 0 ? 1.0 : -1.0) * max(minNormSteer, norm * 0.5)
        return (steer, String(format: "地图指引：向%@ %.0f°（距 %.0fm，差 %.1f°）",
                              diff > 0 ? "右" : "左", mag, dist, diff))
    }

    /// 从 A 点看 B 点的罗盘方位角（0=北，90=东）
    static func compassBearing(fromX: Double, fromY: Double, toX: Double, toY: Double) -> Double {
        let dx = toX - fromX      // 世界 +X = 东
        let dy = toY - fromY      // 世界 -Y = 北
        var deg = atan2(dx, -dy) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return deg
    }

    /// 最小有效转向量：保证超过 applyCommand 的 ±0.1 死区（否则给了也按不动）
    private let minNormSteer: Double = 0.12

    /// 「能不能打得过去」：半径过小且车速过高 → 建议降速（返回建议限速 km/h，nil = 无需干预）
    func speedAdviceForCorner(_ hit: CornerHit, speedKmh: Double?) -> Double? {
        let r = hit.corner.radiusM
        guard r > 1, r < tightRadiusM else { return nil }
        guard let v = speedKmh, v > tightRadiusSpeedKmh else { return nil }
        // 简单几何：v_max ≈ sqrt(μgR)，取 μ≈0.35（保守，游戏路面）
        let vmax = (0.35 * 9.81 * r).squareRoot() * 3.6
        return max(12.0, min(vmax, tightRadiusSpeedKmh))
    }

    // MARK: - 路口选路（2026-09-30 新增）

    /// 路口命中结果
    struct JunctionHit {
        let corner: RoadCorner
        let distanceM: Double
    }

    /// 路口选定的出口
    struct JunctionExit {
        /// 出口方向（罗盘角）
        let exitHeading: Double
        /// 需要转的角度（带符号，( -180,180]，正 = 右）
        let turnDeg: Double
        /// 置信度（0~1）：主路判据越明确越高
        let confidence: Double
        /// 是否走了主路判据（说明是 Y 形岔路）
        let usedMainRoadRule: Bool
        let reason: String
    }

    /// 前方最近的路口点（沿用与弯道相同的前方锥 + 距离约束）
    func junctionAhead(worldX: Double, worldY: Double, headingDeg: Double) -> JunctionHit? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded else { return nil }

        var best: JunctionHit? = nil
        // ★ 同上：只扫 3×3 格
        for c in candidates(junctionIndex, worldX: worldX, worldY: worldY) where c.isJunction {
            let dx = c.worldX - worldX, dy = c.worldY - worldY
            let dist = (dx * dx + dy * dy).squareRoot() / 100.0
            guard dist <= junctionLookaheadM else { continue }
            let bearing = Self.compassBearing(fromX: worldX, fromY: worldY,
                                              toX: c.worldX, toY: c.worldY)
            guard Self.headingDiff(headingDeg, bearing) <= aheadConeDeg else { continue }
            if best == nil || dist < best!.distanceM {
                best = JunctionHit(corner: c, distanceM: dist)
            }
        }
        return best
    }

    /// 在路口里选一条出口路（纯几何，无目的地 —— 兜底漫游用途）。
    ///
    /// 规则：
    ///   ① 认来路：车相对路口的方位 ≈ 来路方向；排除它（否则会判成掉头）
    ///   ② 选去向：剩余支路里挑与车头夹角最小的
    ///   ③ 若有多条都在 forkTolDeg 内（Y 形岔路）→ **主路判据**：
    ///        先比射线长度（差超 reachRatio 才算明显主路），同级再比宽度
    ///
    /// - Returns: nil = 无法确定（支路不足 / 全被排除）→ 调用方应降速保持，绝不硬拐
    func chooseExit(junction: RoadCorner, worldX: Double, worldY: Double,
                    headingDeg: Double) -> JunctionExit? {
        let bs = junction.branches
        guard bs.count >= 2 else { return nil }

        // ① 排除「来路」——即车头方向的反向那条支路（车正从那头开过来的路）。
        //
        // ⚠️ 2026-09-30 修正（离线全量验证抓出的方向性 bug）：
        //   原先用 "车→路口的方位（bearingToJunction）" 作为来路判据 —— 方向搞反了。
        //   车在来路上朝路口开，`bearingToJunction ≈ 车头方向`，于是这行把
        //   **与车头同向的支路全部排除**，恰好排掉了"直行该走的那条"。
        //   实测后果（6690 个情形）：直行 0%（应 ~64%）、掉头级 11.5%、主路判据 0%。
        //   正确做法：来路 = **车头的反方向**（`headingDeg + 180`）。
        //   修正后实测：直行 68.7% / 顺路转弯 23.7% / 大转弯 7.5% / 掉头级 0.1%，
        //   主路判据 19% —— 与设计预期吻合。
        let incomingHeading = (headingDeg + 180.0).truncatingRemainder(dividingBy: 360.0)
        let candidates0 = bs.filter { Self.headingDiff($0.deg, incomingHeading) > excludeInDeg }
        let candidates = candidates0.isEmpty ? bs : candidates0

        // ② 选与车头夹角最小的
        let sorted = candidates.sorted { Self.headingDiff(headingDeg, $0.deg) <
                                         Self.headingDiff(headingDeg, $1.deg) }
        guard let first = sorted.first else { return nil }
        var chosen = first
        var confidence = 0.6
        var usedMain = false
        var reason = String(format: "选最贴近车头的支路 %.0f°", first.deg)

        // ③ 同向多支路 → 主路判据
        let near = sorted.filter { Self.headingDiff(headingDeg, $0.deg) < forkTolDeg }
        if near.count >= 2 {
            usedMain = true
            // 长度优先（触顶的支路按"至少这么长"处理，比较时打折）
            func effReach(_ b: RoadBranch) -> Double {
                b.reachSaturated ? b.reachM * 0.95 : b.reachM
            }
            let byReach = near.sorted { effReach($0) > effReach($1) }
            if effReach(byReach[0]) > effReach(byReach[1]) * reachRatio {
                chosen = byReach[0]
                confidence = 0.75
                reason = String(format: "Y形岔路→主路判据(长度)：%.0fm vs %.0fm",
                                byReach[0].reachM, byReach[1].reachM)
            } else {
                let byWidth = near.filter { $0.widthValid }
                    .sorted { $0.widthCells > $1.widthCells }
                if byWidth.count >= 2 {
                    chosen = byWidth[0]
                    confidence = 0.7
                    reason = String(format: "Y形岔路→主路判据(宽度)：%.0f格 vs %.0f格",
                                    byWidth[0].widthCells, byWidth[1].widthCells)
                } else {
                    chosen = byReach[0]
                    confidence = 0.5
                    reason = "Y形岔路→长度接近，取较长者（低置信）"
                }
            }
        }
        // 角度差的置信度修正：越对准越确信
        let turn = Self.signedHeadingDiff(from: headingDeg, to: chosen.deg)
        let mag = abs(turn)
        if mag > 90 { confidence *= 0.6 }        // 需要大转弯 → 不确信

        return JunctionExit(exitHeading: chosen.deg, turnDeg: turn,
                            confidence: min(1.0, confidence),
                            usedMainRoadRule: usedMain, reason: reason)
    }

    /// 由路口选路结果给出转向建议（两阶段，与 steerForCorner 同构）
    func steerForJunction(_ hit: JunctionHit, exit: JunctionExit,
                          headingDeg: Double) -> (steer: Double, reason: String) {
        let dist = hit.distanceM
        if dist > junctionApproachM {
            // 阶段 1：进路口前 → 用出口方向做预对准（转向强度按置信度打折）
            let diff = exit.turnDeg
            let mag = abs(diff)
            if mag <= steerDeadbandDeg { return (0, "进路口前已对准（" + exit.reason + "）") }
            let span = max(1.0, steerSaturationDeg - steerDeadbandDeg)
            let norm = min(1.0, (mag - steerDeadbandDeg) / span)
            let st = (diff > 0 ? 1.0 : -1.0) * max(minNormSteer, norm * 0.5 * exit.confidence)
            return (st, String(format: "路口前对准：向%@（%@，%.0fm）",
                               diff > 0 ? "右" : "左", exit.reason, dist))
        }
        // 阶段 2：路口内 → 转向出口方向
        let diff = exit.turnDeg
        let mag = abs(diff)
        if mag <= steerDeadbandDeg {
            return (0, String(format: "已对准出口方向（%@）", exit.reason))
        }
        let span = max(1.0, steerSaturationDeg - steerDeadbandDeg)
        let norm = min(1.0, (mag - steerDeadbandDeg) / span)
        let st = (diff > 0 ? 1.0 : -1.0) * max(minNormSteer, norm * 0.5 * exit.confidence)
        return (st, String(format: "路口转向：向%@ %.0f°（%@）",
                           diff > 0 ? "右" : "左", mag, exit.reason))
    }

    // MARK: - 角度工具

    /// 两个罗盘角的夹角（0~180）
    static func headingDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d = 360.0 - d }
        return d
    }

    /// 从 a 转到 b 的带符号角差，范围 (-180, 180]；正 = 需要向右转
    static func signedHeadingDiff(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 }
        if d <= -180.0 { d += 360.0 }
        return d
    }

    // MARK: - 自检 / 对照实现

    /// 调试用：按索引取一条记录（对拍探针用）
    func debugCornerAt(_ i: Int) -> RoadCorner? {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        guard loaded, !corners.isEmpty else { return nil }
        return corners[max(0, min(corners.count - 1, i))]
    }

    /// **全量线性扫描**版 cornerAhead（性能优化的对照组，仅用于对拍验证）。
    ///
    /// 为什么不删：空间索引是"加"出来的优化，必须有**等价性证明**。
    /// 本函数就是那份"可信基准"——自检里拿它与索引版逐点比对，
    /// 出现任何差异即说明索引有漏判（安全性问题），必须排查。
    func cornerAheadLinearReference(worldX: Double, worldY: Double,
                                    headingDeg: Double) -> CornerHit? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded else { return nil }
        var best: CornerHit? = nil
        for c in corners where c.isBend {
            guard let hin = c.headingIn else { continue }
            let dx = c.worldX - worldX, dy = c.worldY - worldY
            let dist = (dx * dx + dy * dy).squareRoot() / 100.0
            guard dist <= lookaheadM else { continue }
            let diff = Self.headingDiff(headingDeg, hin)
            guard diff <= headingMatchTolDeg else { continue }
            let bearing = Self.compassBearing(fromX: worldX, fromY: worldY,
                                              toX: c.worldX, toY: c.worldY)
            guard Self.headingDiff(headingDeg, bearing) <= aheadConeDeg else { continue }
            if let b = best {
                if dist < b.distanceM - 0.5 ||
                   (abs(dist - b.distanceM) <= 0.5 && diff < b.headingDiffDeg) {
                    best = CornerHit(corner: c, distanceM: dist, headingDiffDeg: diff)
                }
            } else {
                best = CornerHit(corner: c, distanceM: dist, headingDiffDeg: diff)
            }
        }
        return best
    }

    // MARK: - 自检

    /// 路口闭环探针：取一个路口记录 + 其第一条支路作为"来路"，
    /// 把车放在该支路一侧（朝路口开），返回 (车位置, 车头朝向, 来路方向, 路口)。
    /// 用于自检的闭环验证 —— 必然命中，且能验证"排除来路 + 选出口"是否正确。
    func junctionProbeFromOwnData() -> (worldX: Double, worldY: Double,
                                        headingDeg: Double, junction: RoadCorner)? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded else { return nil }
        // 取支路数 3~4 的路口（最常见，且出口唯一性较好）
        guard let j = corners.first(where: { $0.isJunction && $0.branches.count == 3 })
                ?? corners.first(where: { $0.isJunction && !$0.branches.isEmpty }),
              let inBranch = j.branches.first else { return nil }
        // 车沿该支路方向的反向退 30m（即车在来路上、车头朝路口）
        let heading = (inBranch.deg + 180.0).truncatingRemainder(dividingBy: 360.0)
        let rad = heading * .pi / 180.0
        let ux = sin(rad), uy = -cos(rad)          // 罗盘 → 世界单位向量
        let back = 30.0 * 100.0
        return (j.worldX - ux * back, j.worldY - uy * back, heading, j)
    }

    /// 从打点集自身构造一个**必然命中**的探针：
    /// 取一条弯道记录，把"车"放在该点沿其进入方向**后方** 35m 处、朝向 = 进入方向。
    /// 这样 cornerAhead 必然能命中（距离 < 40m 提前量、方向完全一致）。
    /// 用于自检的闭环验证（避免只测"加载成功"的假绿）。
    func probeFromOwnData() -> (worldX: Double, worldY: Double, headingDeg: Double, desc: String)? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded else { return nil }
        // 优先取急弯（更有代表性），并跳过硬/缓的极端值
        guard let c = corners.first(where: { $0.isBend && $0.grade == "急" && $0.headingIn != nil })
                ?? corners.first(where: { $0.isBend && $0.headingIn != nil }),
              let hin = c.headingIn else { return nil }
        // 沿进入方向的反方向退 35m（世界坐标 cm）：罗盘角 → 世界向量
        //   罗盘 0°=北=世界 -Y；90°=东=世界 +X  ⟹ 单位向量 = (sin, -cos)
        let rad = hin * .pi / 180.0
        let ux = sin(rad), uy = -cos(rad)
        let backM = 35.0 * 100.0        // cm
        let wx = c.worldX - ux * backM
        let wy = c.worldY - uy * backM
        return (wx, wy, hin,
                String(format: "从打点(x=%.0f,y=%.0f)沿进入方向%.0f°退回35m", c.worldX, c.worldY, hin))
    }

    /// 离线自检（--corner-selftest）：打印加载情况 + 用若干已知点试查
    func selfTest(probes: [(Double, Double, Double, String)]) -> [String] {
        ensureLoaded()
        var out: [String] = []
        out.append("打点集: \(loaded ? "已加载" : "未加载") | \(lastQueryReason)")
        out.append(String(format: "参数: 提前量 %.0fm / 方向容差 %.0f° / 死区 %.0f° / 饱和 %.0f°",
                          lookaheadM, headingMatchTolDeg, steerDeadbandDeg, steerSaturationDeg))
        for (wx, wy, hdg, tag) in probes {
            let hit = cornerAhead(worldX: wx, worldY: wy, headingDeg: hdg)
            if let h = hit {
                let (st, reason) = steerForCorner(h, headingDeg: hdg, worldX: wx, worldY: wy)
                out.append(String(format: "  %@ 世界(%.0f,%.0f) 朝向%.0f° → 前方%.0fm %@弯 steer=%+.3f | %@",
                                  tag, wx, wy, hdg, h.distanceM, h.corner.grade, st, reason))
            } else {
                out.append(String(format: "  %@ 世界(%.0f,%.0f) 朝向%.0f° → 无适用弯道点",
                                  tag, wx, wy, hdg))
            }
        }
        return out
    }
}
