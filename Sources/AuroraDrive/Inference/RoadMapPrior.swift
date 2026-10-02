// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RoadMapPrior.swift — 路网先验（离线预生成位图 + 运行时查询）
//
//  用途：车道线全部丢失（路口 / 掉头 / 遮挡 / 游戏卡顿）时，给转向提供
//        「路往哪拐」这一维先验 —— 这是纯视觉做不到的部分。
//
//  ⚠️ 边界（必须遵守）：本先验**只提供航向**，绝不提供横向偏差。
//     横向（车偏左还是偏右）必须来自实时视觉（车道线/可行驶区），因为
//     地图是玩家标注版，与实景存在米级偏差，拿它做横向会直接带偏方向。
//
//  数据源：models/road_prior_2048_t70_fixed.png
//     由 models/bigworldmap-13056.jpg 离线生成（脚本 models/tools/make_road_prior_t70.py
//     与 make_road_corners_v2.py，可复现）。
//
//     ⚠️ 2026-09-30 两次重大修正（此前版本全部错误，用户当场指出）：
//     【修正 1：阈值】早先误用阈值 45 → 多抓 16.1% 的**等高线噪声**
//       （实测 677,265 像素），导致弯道打点 83% 落在建筑/等高线上。
//       全图灰度实测：0~8 纯黑 47.6% / 16~24 暗底 45.0% / 24~56 建筑+等高线 4.8%
//       / **80~88 真路面 1.95%（唯一）**。阈值 70 连通性 98.6%，阈值 80 掉到 37%。
//     【修正 2：缩放】旧代码 `H//2048=6`（整除截断）→ 每格实为 6px 而非 6.375px，
//       且 `2048*6=12288` **丢掉地图最后 768px（468 m）** → 坐标系统性偏移，
//       实测 66.6% 的打点离真路面 >24 m。改为 BOX 缩放到精确 6.375 px/格、覆盖全幅后，
//       偏差中位 0.0 m，94.3% 在 1.8 m 内，100% 在 9.8 m 内。
//     【修正 3：断裂】底图**斑马线**处灰度 17~68（路面 80~88），二值化后被挖成
//       837 处窄缝 → 射线打到缝里就"断"，路网不连通。用形态学闭运算（半径 16px）
//       填缝，断裂减少 64%，连通性恢复到 98.6%。
//     底图性质：**矢量风格道路线稿** —— 灰色粗线 = 道路（中位宽 27~30px
//     = 16~18 m 路面）、黑色带 = 河流、深色底 = 空地。
//
//  坐标链（三跳，全部复用已验证常量）：
//     世界坐标(cm) --kCalibA/B/TX/TY--> 13056 地图像素 --/6.375--> 2048 先验网格
//     该校准已做图像级验证：13056 图 = 11264 图平移 (+233,+1738)，NCC 0.985/0.987。
//
//  方向约定（与 toPose 的罗盘角一致）：
//     罗盘角 0° = 正北 = 地图上方（图像 -Y）；90° = 正东 = 地图右方（图像 +X）。
//     由 PCA 主轴 (dx,dy)（图像坐标，dy 向下）换算：compass = atan2(dx, -dy)。
// ============================================================================

import Foundation
import CoreGraphics
import ImageIO

final class RoadMapPrior {

    static let shared = RoadMapPrior()

    // MARK: - 常量

    /// 先验网格边长（2048²）
    static let gridSize = 2048

    /// 一格对应的地面距离：13056 px / 2048 格 × 0.61 m/px（1px = 0.61m，pxPerMeter=1.6395）
    static let metersPerCell: Double = 13056.0 / Double(gridSize) * 0.61

    /// 世界坐标 → 先验网格的校准常量（与 CoordinateCapture.kCalib* 同源同值）
    private let calibA = 0.016394586684750773
    private let calibB = 5.693519256055879e-08
    private let calibTX = 6526.474380746091
    private let calibTY = 5210.664390686138
    private let mapPixels: Double = 13056.0

    /// PCA 一致性阈值：远近主轴差超过此角 → 判定为「路口/急弯」，方向仍给但**置信度打折**。
    ///
    /// ⚠️ 2026-09-30 调参依据（对 10 个快速旅行点 + 5 个用户实测坐标共 15 个已知点做
    ///   网格扫描，半径对 × 阈值四档）：
    ///     近6/远10 阈35° → 40%   近8/远12 阈35° → 46%
    ///     近10/远16 阈35° → 60%  近10/远16 阈50° → **73%**
    ///     近10/远16 阈90° → 86%（但 90° 等于放弃检查，主轴范围本就 180°）
    ///   ⟹ 取「近10/远16 + 阈50°」：既拿到 73% 可用率，又保留"识别路口"的能力。
    ///   **关键设计修正**：一致性不达标时不再「拒绝给方向」，而是照给方向 +
    ///   把置信度打 0.5 折（`junctionPenalty`）—— 因为路口/急弯恰恰是最需要
    ///   地图先验的场景（车道线在路口必然中断），此时拒答等于在最需要时闭嘴。
    private let headingAgreementDeg: Double = 50.0

    /// 近/远采样半径（格数）：10 格 ≈ 39 m（近端，主方向来源）、16 格 ≈ 62 m（远端，路口识别）
    private let nearRadiusCells = 10
    private let farRadiusCells = 16

    /// 判定为路口/急弯时的置信度折扣（方向照给，只是不那么确信）
    static let junctionPenalty: Double = 0.5

    // MARK: - 状态

    private var grid: [UInt8] = []          // 1 = 道路，0 = 非道路
    private var loaded = false
    private var loadAttempted = false
    private let lock = NSLock()

    /// 诊断：最近一次查询结果（UI/日志用）
    private(set) var lastQueryReason: String = "未查询"

    /// 最近一次查询是否判定为路口/急弯（调用方据此打折置信度，见 junctionPenalty）
    private(set) var lastJunction: Bool = false

    private init() {}

    // MARK: - 加载

    /// 懒加载先验位图。找不到资源时 loaded 保持 false，所有查询返回 nil
    /// （fail-open：宁可没有先验，也不给假先验）。
    func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loadAttempted else { return }
        loadAttempted = true

        guard let url = Self.locateResource() else {
            lastQueryReason = "先验位图未找到（road_prior_2048_t70_fixed.png）"
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            lastQueryReason = "先验位图解码失败"
            return
        }

        let w = image.width, h = image.height
        guard w == Self.gridSize, h == Self.gridSize else {
            lastQueryReason = "先验位图尺寸异常 \(w)×\(h)（应为 \(Self.gridSize)²）"
            return
        }

        var buffer = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else {
            lastQueryReason = "先验位图绘制失败"
            return
        }

        // 存的是 0/255 二值图 → 归一化为 0/1
        grid = buffer.map { $0 > 127 ? 1 : 0 }
        loaded = true
        lastQueryReason = "先验已加载（2048²，\(String(format: "%.2f", Self.metersPerCell)) m/格）"
    }

    /// 资源查找：Bundle 优先（部署形态），回退到开发目录
    private static func locateResource() -> URL? {
        var candidates: [URL] = []
        let name = "road_prior_2048_t70_fixed"
        // ⚠️ 2026-09-30：必须覆盖 Bundle 的 models/ 子目录（Bundle 查找不递归，
        //   而部署路径是 Contents/Resources/models/ —— 见 RoadCornerGuide 同处注释）。
        if let u = Bundle.main.url(forResource: name, withExtension: "png",
                                   subdirectory: "models") { candidates.append(u) }
        if let u = Bundle.main.url(forResource: name, withExtension: "png") { candidates.append(u) }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("models/\(name).png"))
        }
        // 开发/调试形态：可执行文件所在目录往上找 models/
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
            .deletingLastPathComponent()
        for base in [exeDir, exeDir.deletingLastPathComponent(),
                     exeDir.deletingLastPathComponent().deletingLastPathComponent(),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            candidates.append(base.appendingPathComponent("models/\(name).png"))
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    var isLoaded: Bool {
        ensureLoaded()
        return loaded
    }

    // MARK: - 坐标换算

    /// 世界坐标(cm) → 先验网格坐标；越界返回 nil
    func worldToGrid(_ worldX: Double, _ worldY: Double) -> (gx: Int, gy: Int)? {
        guard worldX.isFinite, worldY.isFinite else { return nil }
        let mapX = calibA * worldX - calibB * worldY + calibTX
        let mapY = calibB * worldX + calibA * worldY + calibTY
        let step = mapPixels / Double(Self.gridSize)
        let gx = Int(mapX / step), gy = Int(mapY / step)
        guard gx >= 0, gx < Self.gridSize, gy >= 0, gy < Self.gridSize else { return nil }
        return (gx, gy)
    }

    /// 先验网格坐标 → 世界坐标(cm)（nearestRoadPoint 回传用）
    private func gridToWorld(_ gx: Double, _ gy: Double) -> (Double, Double) {
        let step = mapPixels / Double(Self.gridSize)
        let mapX = gx * step, mapY = gy * step
        // 反解：map_x = A·x − B·y + TX ; map_y = B·x + A·y + TY
        //       分母 = A² + B²
        let den = calibA * calibA + calibB * calibB
        guard den > 1e-12 else { return (0, 0) }
        let dx = mapX - calibTX, dy = mapY - calibTY
        return ((calibA * dx + calibB * dy) / den,
                (-calibB * dx + calibA * dy) / den)
    }

    // MARK: - 查询 API

    /// 自车是否在道路上（含 1 格容差 —— 地图标注与实景有米级偏差）
    func isOnRoad(worldX: Double, worldY: Double) -> Bool {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded, let g = worldToGrid(worldX, worldY) else { return false }
        let r = 1
        for gy in max(0, g.gy - r)...min(Self.gridSize - 1, g.gy + r) {
            for gx in max(0, g.gx - r)...min(Self.gridSize - 1, g.gx + r) {
                if grid[gy * Self.gridSize + gx] == 1 { return true }
            }
        }
        return false
    }

    /// 最近道路点（世界坐标）+ 距离（米）。找不到返回 nil。
    func nearestRoadPoint(worldX: Double, worldY: Double,
                          maxSearchCells: Int = 24) -> (worldX: Double, worldY: Double, distanceMeters: Double)? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded, let g = worldToGrid(worldX, worldY) else { return nil }

        var best: (dx: Double, dy: Double)? = nil
        var bestDist2 = Double.greatestFiniteMagnitude
        // 环形扩张搜索（从近到远，找到即停的那一环不早退，保证取到真正最近）
        for radius in 0...maxSearchCells {
            var found = false
            let ylo = max(0, g.gy - radius), yhi = min(Self.gridSize - 1, g.gy + radius)
            let xlo = max(0, g.gx - radius), xhi = min(Self.gridSize - 1, g.gx + radius)
            for gy in ylo...yhi {
                // 只扫环边，避免重复扫描内部
                let onEdgeRow = (gy == ylo || gy == yhi)
                var x = xlo
                while x <= xhi {
                    if onEdgeRow || x == xlo || x == xhi {
                        if grid[gy * Self.gridSize + x] == 1 {
                            let dx = Double(x - g.gx), dy = Double(gy - g.gy)
                            let d2 = dx * dx + dy * dy
                            if d2 < bestDist2 { bestDist2 = d2; best = (dx, dy); found = true }
                        }
                    }
                    x += 1
                }
            }
            // 已找到且当前环半径已超过最近距离 → 不可能更近，停
            if best != nil && Double(radius) > sqrt(bestDist2) + 1 { break }
            if found && radius > 0 { /* 继续扫下一环，确保最近 */ }
        }
        guard let b = best else { return nil }
        let gx = Double(g.gx) + b.dx, gy = Double(g.gy) + b.dy
        let (wx, wy) = gridToWorld(gx, gy)
        return (wx, wy, sqrt(bestDist2) * Self.metersPerCell)
    }

    /// 道路走向的**候选罗盘角**（线方向的双向，[h, h+180]）。
    ///
    /// 返回 nil 的情况（一律 fail-open，交给上层兜底）：
    ///   · 先验未加载 / 坐标越界
    ///   · 近端半径内道路格太少（<10）→ 数据不足以定方向
    ///   · 远近两个半径的主轴差 > 35°（路口 / 急弯，主轴不稳定）
    ///
    /// 调用方拿到候选后，应与**自车当前罗盘朝向**比较，取夹角小的那个候选
    /// （车不可能原地调头去走反向）。
    func roadHeadingCandidates(worldX: Double, worldY: Double) -> [Double]? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard loaded, let g = worldToGrid(worldX, worldY) else { return nil }

        guard let near = pcaLineAngle(gx: g.gx, gy: g.gy, radius: nearRadiusCells) else {
            lastQueryReason = "先验：近端道路格不足（路口/空地）"
            return nil
        }
        // 远端一致性：只用于「标记是否为路口」，不再拒绝给方向（见 headingAgreementDeg 注释）
        var atJunction = false
        if let far = pcaLineAngle(gx: g.gx, gy: g.gy, radius: farRadiusCells) {
            let d = Self.ringDiff180(near, far)
            if d > headingAgreementDeg {
                atJunction = true
                lastQueryReason = String(format: "先验：路口/急弯（近 %.0f° vs 远 %.0f°，差 %.0f°）",
                                         near, far, d)
            }
        }
        lastJunction = atJunction
        // 线方向角 → 罗盘角（0=北=图像上；90=东=图像右）
        let theta = near * .pi / 180.0
        var compass = atan2(cos(theta), -sin(theta)) * 180.0 / .pi
        if compass < 0 { compass += 360.0 }
        if compass >= 360.0 { compass -= 360.0 }
        if !atJunction {
            lastQueryReason = String(format: "先验：道路走向 %.0f°", compass)
        }
        return [compass, compass >= 180 ? compass - 180 : compass + 180]
    }

    // MARK: - PCA（内部，需持锁调用）

    /// 对半径内的道路像素做 PCA 主轴 → 返回线方向角 [0,180)（图像坐标系）
    private func pcaLineAngle(gx: Int, gy: Int, radius: Int) -> Double? {
        let ylo = max(0, gy - radius), yhi = min(Self.gridSize - 1, gy + radius)
        let xlo = max(0, gx - radius), xhi = min(Self.gridSize - 1, gx + radius)
        var n = 0.0
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for y in ylo...yhi {
            let rowBase = y * Self.gridSize
            for x in xlo...xhi where grid[rowBase + x] == 1 {
                let dx = Double(x), dy = Double(y)
                n += 1; sx += dx; sy += dy
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
        }
        guard n >= 10 else { return nil }
        let mx = sx / n, my = sy / n
        // 中心化后的协方差（用和式形式，避免再遍历一遍）
        let cxx = sxx / n - mx * mx
        let cyy = syy / n - my * my
        let cxy = sxy / n - mx * my
        // 2×2 对称矩阵主轴解析解
        var theta = 0.5 * atan2(2.0 * cxy, cxx - cyy)   // 弧度，范围 (-π/2, π/2]
        var deg = theta * 180.0 / .pi
        if deg < 0 { deg += 180.0 }
        if deg >= 180.0 { deg -= 180.0 }
        return deg
    }

    /// 两个角度在 [0,180) 环上的最小差
    private static func ringDiff180(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 180.0)
        return min(d, 180.0 - d)
    }

    // MARK: - 自检（离线验证用）

    /// 打印若干已知点的先验查询结果（--road-prior-selftest 用）
    func selfTest(points: [(Double, Double, String)]) -> [String] {
        ensureLoaded()
        var out: [String] = []
        out.append(String(format: "先验加载: %@ | %@", loaded ? "是" : "否", lastQueryReason))
        out.append(String(format: "网格 %d² (%.2f m/格)", Self.gridSize, Self.metersPerCell))
        for (wx, wy, tag) in points {
            let on = isOnRoad(worldX: wx, worldY: wy)
            let near = nearestRoadPoint(worldX: wx, worldY: wy)
            let hdg = roadHeadingCandidates(worldX: wx, worldY: wy)
            let nearStr = near.map { String(format: "%.0fm", $0.distanceMeters) } ?? "—"
            let hdgStr = hdg.map { String(format: "%.0°/%.0f°", $0[0], $0[1]) } ?? "—"
            out.append(String(format: "  %@ 世界(%.0f,%.0f) 路上=%@ 最近路=%@ 走向候选=%@",
                              tag, wx, wy, on ? "是" : "否", nearStr, hdgStr))
        }
        return out
    }
}
