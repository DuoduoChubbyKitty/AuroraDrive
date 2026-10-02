// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  DriveSegmentController.swift — 驾驶分段状态机（地图段 / 回正段 / 交接确认）
//
//  【用户 2026-09-30 明确要求的流程】
//      ① 车接近地图打点（弯道）→ 进入**地图段**：用地图指引按方向键拐过去
//      ② 拐过去后车头是斜的 → **必须有回正**：按地图路走向把车头掰正
//      ③ 回正完成后 → 交给**模型/视觉**做车道线保持（它本来就干这个）
//      ④ 交接必须**确认真实成功**，四条件全满足才算，否则留在原地保守行驶
//
//  【为什么必须有交接四条件（用户原话）】
//      "判断成功标准是在那条道路里…而且已经向前行驶一段距离…而且都能拟合在道路里…
//       并且模型已经能正常识别到车道线，才能算准确性"
//    ⟹ 四条件 AND：
//       ① 定位落在目标道路走廊内（RoadMapPrior.isOnRoad）
//       ② 已向前行驶一段距离（网络定位坐标积分位移）
//       ③ 拟合连续多帧稳定落在道路里（视觉置信 + 无跳变）
//       ④ 视觉能正常识别到车道线（laneMask 有效）
//
//  【为什么不"过去了就立刻交"】拐过弯的一瞬间车头还斜、车道线可能还没识别到；
//   此时交给视觉，视觉大概率给不出可信方向 → 车会甩。必须等条件齐备。
//
//  【安全边界（不可放松）】
//   · 本机只决定"用哪一路的控制量"，**不做限幅**；
//     最终仍走 applyLaneAdvice（限幅 + 置信度加权 + 油门只压不抬 + 刹车取 max）
//   · 任何不确定 → 回落到视觉段；视觉也不可信且地图也查不到 → 返回 nil（上层降速保持）
//   · 转向始终是开关量（A/D），由 applyCommand 的 ±0.1 死区决定是否真按下
// ============================================================================

import Foundation

// MARK: - 分段

/// 当前驾驶分段
enum DriveSegment: String {
    /// 视觉段（常态）：车道线线性拟合 + PD。直道 / 高速微弯走这里
    case vision = "视觉"
    /// 地图段：按地图打点的指引转向（进弯 / 过弯）
    case mapTurn = "地图转向"
    /// 路口段：按地图路口的支路几何选一条出口（纯几何，无目的地）
    case junction = "路口选路"
    /// 回正段：车头偏离目标路走向 → 先掰正再交给视觉
    case straighten = "回正"
    /// 交接确认：四条件逐条累计中，凑齐才真正交给视觉
    case handover = "交接确认"

    var display: String { rawValue }
}

/// 分段决策输出
struct SegmentDecision {
    /// 当前分段
    let segment: DriveSegment
    /// 地图段/回正段给出的转向建议（steer ∈ [-1,1]，正=右）；视觉段为 nil
    let mapSteer: Double?
    /// 建议限速（km/h）；nil = 不表态
    let speedLimitKmh: Double?
    /// 是否要求地图段/回正段**覆盖**视觉的转向
    var overridesVision: Bool { mapSteer != nil }
    let reason: String
}

// MARK: - 控制器

final class DriveSegmentController {

    // MARK: 可调参数（AURORA_SEG_* 覆盖）

    /// 回正触发角差（度）：车头与目标路走向差超过此值 → 进回正段
    private let straightenTriggerDeg: Double
    /// 回正完成角差（度）
    private let straightenDoneDeg: Double
    /// 交接需要的最小行驶距离（米）
    private let handoverMinDistanceM: Double
    /// 交接需要的连续稳定帧数
    private let handoverMinFrames: Int
    /// 目标路走廊容差（米）—— 判定"已在目标路上"
    private let corridorToleranceM: Double
    /// 地图段最长持续时间（秒）：超过则放弃（避免卡在地图段）
    private let mapTurnTimeoutS: Double

    // MARK: 状态

    private(set) var segment: DriveSegment = .vision

    /// 当前地图段/回正段所跟踪的弯道点（世界坐标，cm）
    private var targetCorner: (x: Double, y: Double, headingOut: Double, grade: String)?
    /// 当前路口段跟踪的路口点 + 选定的出口
    private var targetJunction: (x: Double, y: Double, exitHeading: Double, confidence: Double)?
    /// 进入当前分段的时间
    private var segmentSince = Date()
    /// 交接累计：起始位置
    private var handoverOrigin: (x: Double, y: Double)?
    /// 交接累计：连续满足帧数
    private var handoverFrames = 0
    /// 已经处理过的弯道点（避免同一弯道反复触发）
    private var consumedCorners: [(x: Double, y: Double)] = []
    /// 诊断
    private(set) var lastReason: String = "未启动"
    private(set) var handoverProgress = "—"

    init() {
        let env = ProcessInfo.processInfo.environment
        straightenTriggerDeg = env["AURORA_SEG_STRAIGHTEN_DEG"].flatMap(Double.init) ?? 15.0
        straightenDoneDeg = env["AURORA_SEG_STRAIGHTEN_DONE_DEG"].flatMap(Double.init) ?? 8.0
        handoverMinDistanceM = env["AURORA_SEG_HANDOVER_M"].flatMap(Double.init) ?? 15.0
        handoverMinFrames = env["AURORA_SEG_HANDOVER_FRAMES"].flatMap(Int.init) ?? 10
        corridorToleranceM = env["AURORA_SEG_CORRIDOR_M"].flatMap(Double.init) ?? 8.0
        mapTurnTimeoutS = env["AURORA_SEG_MAP_TIMEOUT_S"].flatMap(Double.init) ?? 20.0
    }

    // MARK: - 主更新

    /// 每控制周期调用一次。
    ///
    /// - Parameters:
    ///   - worldX/worldY: 自车世界坐标（cm），来自网络定位（C2S UDP 解码）。nil = 定位不可信
    ///   - headingDeg: 自车罗盘朝向
    ///   - speedKmh: 车速（可选，用于限速建议）
    ///   - visionConfidence: 视觉置信度（0~1）。nil = 视觉这帧没给建议
    ///   - visionStable: 视觉拟合是否稳定（无跳变）
    ///   - onRoad: 是否在道路上（RoadMapPrior.isOnRoad）；nil = 先验不可用
    /// - Returns: 分段决策
    func update(worldX: Double?, worldY: Double?,
                headingDeg: Double?,
                speedKmh: Double?,
                visionConfidence: Double?,
                visionStable: Bool,
                onRoad: Bool?) -> SegmentDecision {

        // ── 定位不可信 → 直接视觉段（地图无从谈起）──
        guard let wx = worldX, let wy = worldY, let hdg = headingDeg else {
            reset(to: .vision, reason: "定位不可信 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil,
                                   reason: lastReason)
        }

        switch segment {
        case .vision:      return stepFromVision(wx, wy, hdg, speedKmh)
        case .mapTurn:     return stepMapTurn(wx, wy, hdg, speedKmh)
        case .junction:    return stepJunction(wx, wy, hdg, speedKmh)
        case .straighten:  return stepStraighten(wx, wy, hdg)
        case .handover:    return stepHandover(wx, wy, hdg,
                                               visionConfidence: visionConfidence,
                                               visionStable: visionStable,
                                               onRoad: onRoad)
        }
    }

    // MARK: - 各段

    private func stepFromVision(_ wx: Double, _ wy: Double, _ hdg: Double, _ spd: Double?) -> SegmentDecision {
        // 找前方弯道点（方向匹配由 RoadCornerGuide 内部负责）
        guard let hit = RoadCornerGuide.shared.cornerAhead(worldX: wx, worldY: wy, headingDeg: hdg) else {
            // ── 弯道优先；没有弯道则查路口（★ 2026-09-30 新增）──
            // 为什么弯道优先：弯道打点是**密集 + 双向**（每 23m 一个、两个进入方向），
            // 数据比路口（1 个/路口）更精确；且路口点多在弯道之外，二者实测 0 重叠。
            if let jh = RoadCornerGuide.shared.junctionAhead(worldX: wx, worldY: wy, headingDeg: hdg),
               !isConsumed(jh.corner.worldX, jh.corner.worldY) {
                guard let exit = RoadCornerGuide.shared.chooseExit(
                        junction: jh.corner, worldX: wx, worldY: wy, headingDeg: hdg) else {
                    // 选不出出口（支路不足/畸形路口）→ 不硬拐，保持视觉 + 降速提示
                    lastReason = String(format: "前方 %.0fm 有路口但选不出出口 → 保持视觉", jh.distanceM)
                    return SegmentDecision(segment: .vision, mapSteer: nil,
                                           speedLimitKmh: 30.0, reason: lastReason)
                }
                targetJunction = (jh.corner.worldX, jh.corner.worldY,
                                  exit.exitHeading, exit.confidence)
                segment = .junction
                segmentSince = Date()
                lastReason = String(format: "进入路口段：前方 %.0fm，%@（置信 %.2f）",
                                    jh.distanceM, exit.reason, exit.confidence)
                return SegmentDecision(segment: .junction, mapSteer: nil,
                                       speedLimitKmh: 30.0, reason: lastReason)
            }
            lastReason = "视觉段：前方无弯道点/路口"
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }
        // 已处理过的点跳过（同一弯道不重复触发）
        if isConsumed(hit.corner.worldX, hit.corner.worldY) {
            lastReason = "视觉段：该弯道点已处理"
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        // 进入地图段
        targetCorner = (hit.corner.worldX, hit.corner.worldY,
                        hit.corner.headingOut ?? hit.corner.headingIn ?? hdg,
                        hit.corner.grade)
        segment = .mapTurn
        segmentSince = Date()
        let lim = speedLimitForCorner(hit, spd)
        lastReason = String(format: "进入地图转向段：前方 %.0fm %@弯（半径 %.0fm）",
                            hit.distanceM, hit.corner.grade, hit.corner.radiusM)
        return SegmentDecision(segment: .mapTurn, mapSteer: nil, speedLimitKmh: lim, reason: lastReason)
    }

    private func stepMapTurn(_ wx: Double, _ wy: Double, _ hdg: Double, _ spd: Double?) -> SegmentDecision {
        guard let t = targetCorner else {
            // 目标丢了 → 回视觉
            reset(to: .vision, reason: "地图段目标丢失 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }
        // 超时保护
        if Date().timeIntervalSince(segmentSince) > mapTurnTimeoutS {
            consume(t.x, t.y)
            reset(to: .vision, reason: "地图段超时 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        // 是否已到达/驶过该点：以"到目标点的距离开始增大且已很近"为判据
        let dist = hypot(t.x - wx, t.y - wy) / 100.0
        // 用车头朝向与目标方向的角差判断转向需求
        let bearing = Self.compassBearing(fromX: wx, fromY: wy, toX: t.x, toY: t.y)
        let diff = RoadCornerGuide.signedHeadingDiff(from: hdg, to: bearing)
        let mag = abs(diff)

        // 到达判定：距离 < 提前量的一半 且 车头大致指向目标（说明拐过来了）
        let arrived = dist < 12.0 && mag < 30.0
        if arrived {
            // 进回正段
            segment = .straighten
            segmentSince = Date()
            lastReason = String(format: "已过弯道点（距 %.0fm）→ 回正段", dist)
            return SegmentDecision(segment: .straighten, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        // 转向建议：朝目标点方向（这就是"地图指引"）
        var steer = 0.0
        if mag > straightenDoneDeg {
            let span = max(1.0, 45.0 - straightenDoneDeg)
            let norm = min(1.0, (mag - straightenDoneDeg) / span)
            steer = (diff > 0 ? 1.0 : -1.0) * max(0.12, norm * 0.5)
        }
        let lim = speedLimitForCorner(nil, spd, radius: nil)
        lastReason = String(format: "地图段：目标 %.0fm，需向%@ %@%.0f°",
                            dist, diff > 0 ? "右" : "左",
                            mag > 8 ? "" : "（已对齐）", mag)
        return SegmentDecision(segment: .mapTurn, mapSteer: steer, speedLimitKmh: lim, reason: lastReason)
    }

    /// 路口段：车逼近路口 → 按选定出口转向 → 通过后进回正段 → 四条件交接。
    ///
    /// 与 stepMapTurn 同构，差别：
    ///   · 目标点稀疏（1 个/路口），到达判定用固定半径（不靠"距离开始变大"）
    ///   · 转向量来自 `chooseExit` 的几何选路（排除来路 + 主路判据）
    private func stepJunction(_ wx: Double, _ wy: Double, _ hdg: Double,
                              _ spd: Double?) -> SegmentDecision {
        guard let t = targetJunction else {
            reset(to: .vision, reason: "路口段目标丢失 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }
        // 超时保护（复用地图段同一参数）
        if Date().timeIntervalSince(segmentSince) > mapTurnTimeoutS {
            consume(t.x, t.y)
            reset(to: .vision, reason: "路口段超时 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        let dist = hypot(t.x - wx, t.y - wy) / 100.0
        let diff = RoadCornerGuide.signedHeadingDiff(from: hdg, to: t.exitHeading)
        let mag = abs(diff)

        // 到达判定：已过路口点（距离开始回增）或用固定半径
        let arrived = dist < 12.0 && mag < 30.0
        if arrived {
            consume(t.x, t.y)
            targetCorner = (t.x, t.y, t.exitHeading, "路口")
            segment = .straighten
            segmentSince = Date()
            targetJunction = nil
            lastReason = String(format: "已过路口（距 %.0fm）→ 回正段", dist)
            return SegmentDecision(segment: .straighten, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        // 转向建议（复用 steerForJunction 的两阶段逻辑）
        var steer = 0.0
        if let jh = RoadCornerGuide.shared.junctionAhead(worldX: wx, worldY: wy, headingDeg: hdg),
           let exit = RoadCornerGuide.shared.chooseExit(junction: jh.corner,
                                                        worldX: wx, worldY: wy,
                                                        headingDeg: hdg) {
            let (st, why) = RoadCornerGuide.shared.steerForJunction(jh, exit: exit, headingDeg: hdg)
            steer = st
            lastReason = why
        } else {
            // 出口重算失败 → 用进入时锁定的出口方向
            if mag > straightenDoneDeg {
                let span = max(1.0, 45.0 - straightenDoneDeg)
                let norm = min(1.0, (mag - straightenDoneDeg) / span)
                steer = (diff > 0 ? 1.0 : -1.0) * max(0.12, norm * 0.5 * t.confidence)
                lastReason = String(format: "路口段（锁定出口）：向%@ %.0f°，距 %.0fm",
                                    diff > 0 ? "右" : "左", mag, dist)
            } else {
                lastReason = String(format: "路口段：已对准出口，距 %.0fm", dist)
            }
        }
        // 路口一律限速 30（保守），并压住油门
        return SegmentDecision(segment: .junction, mapSteer: steer, speedLimitKmh: 30.0, reason: lastReason)
    }

    private func stepStraighten(_ wx: Double, _ wy: Double, _ hdg: Double) -> SegmentDecision {
        guard let t = targetCorner else {
            reset(to: .vision, reason: "回正段目标丢失 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }
        // 回正目标 = 进入目标路的方向（用"从当前位置到目标点再往前"的方向近似）
        let bearing = Self.compassBearing(fromX: wx, fromY: wy, toX: t.x, toY: t.y)
        let diff = RoadCornerGuide.signedHeadingDiff(from: hdg, to: t.headingOut)
        let mag = abs(diff)

        if mag <= straightenDoneDeg {
            // 回正完成 → 进交接确认
            segment = .handover
            segmentSince = Date()
            handoverOrigin = (wx, wy)
            handoverFrames = 0
            lastReason = String(format: "回正完成（差 %.1f°）→ 交接确认", mag)
            return SegmentDecision(segment: .handover, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        let span = max(1.0, straightenTriggerDeg * 2 - straightenDoneDeg)
        let norm = min(1.0, (mag - straightenDoneDeg) / span)
        let steer = (diff > 0 ? 1.0 : -1.0) * max(0.12, norm * 0.5)
        lastReason = String(format: "回正段：车头差 %.1f°（目标 %@），向%@打",
                            mag, bearing > 180 ? "南向" : "北向", diff > 0 ? "右" : "左")
        return SegmentDecision(segment: .straighten, mapSteer: steer, speedLimitKmh: nil, reason: lastReason)
    }

    private func stepHandover(_ wx: Double, _ wy: Double, _ hdg: Double,
                              visionConfidence: Double?,
                              visionStable: Bool,
                              onRoad: Bool?) -> SegmentDecision {
        guard let t = targetCorner, let origin = handoverOrigin else {
            reset(to: .vision, reason: "交接段状态丢失 → 视觉段")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }
        // ── 四条件 ──
        // ① 定位落在道路走廊内
        let cond1: Bool
        if let on = onRoad {
            cond1 = on
        } else {
            // 先验不可用 → 用"距目标点距离"近似（车没跑远就算在路上）
            let d = hypot(t.x - wx, t.y - wy) / 100.0
            cond1 = d < corridorToleranceM + 25.0
        }
        // ② 已向前行驶一段距离
        let travelled = hypot(wx - origin.x, wy - origin.y) / 100.0
        let cond2 = travelled >= handoverMinDistanceM
        // ③ 拟合连续多帧稳定
        let cond3 = visionStable
        // ④ 视觉能正常识别到车道线
        let cond4 = (visionConfidence ?? 0) > 0.25

        if cond1 && cond2 && cond3 && cond4 {
            handoverFrames += 1
        } else {
            handoverFrames = max(0, handoverFrames - 1)     // 破裂则退，不硬凑
        }

        handoverProgress = String(format: "①%@ ②%@(%.0f/%.0fm) ③%@ ④%@(%d/%d)",
                                  cond1 ? "✓" : "✗",
                                  cond2 ? "✓" : "✗", travelled, handoverMinDistanceM,
                                  cond3 ? "✓" : "✗",
                                  cond4 ? "✓" : "✗", handoverFrames, handoverMinFrames)

        if handoverFrames >= handoverMinFrames {
            consume(t.x, t.y)
            reset(to: .vision, reason: "交接成功（四条件齐备）→ 视觉段接管")
            return SegmentDecision(segment: .vision, mapSteer: nil, speedLimitKmh: nil, reason: lastReason)
        }

        // 交接未完成期间：保守（不加油、不给转向）
        lastReason = "交接确认中：\(handoverProgress)"
        // 长时间凑不齐 → 也要给个出路：回退到回正段重试（而不是永远卡住）
        if Date().timeIntervalSince(segmentSince) > 12.0 {
            segment = .straighten
            segmentSince = Date()
            lastReason = "交接迟迟不齐（\(handoverProgress)）→ 退回回正段"
        }
        return SegmentDecision(segment: .handover, mapSteer: nil, speedLimitKmh: 30.0, reason: lastReason)
    }

    // MARK: - 工具

    /// 从 A 点看 B 点的罗盘方位角（0=北，90=东）
    static func compassBearing(fromX: Double, fromY: Double, toX: Double, toY: Double) -> Double {
        let dx = toX - fromX          // 世界 +X = 东
        let dy = toY - fromY          // 世界 +Y = 南（北 = -Y）
        var deg = atan2(dx, -dy) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return deg
    }

    private func isConsumed(_ x: Double, _ y: Double) -> Bool {
        consumedCorners.contains { hypot($0.x - x, $0.y - y) < 20.0 * 100.0 }  // 20m 内视为同一点
    }

    private func consume(_ x: Double, _ y: Double) {
        consumedCorners.append((x, y))
        if consumedCorners.count > 64 { consumedCorners.removeFirst() }
    }

    private func speedLimitForCorner(_ hit: CornerHit?, _ spd: Double?, radius: Double? = nil) -> Double? {
        if let h = hit {
            return RoadCornerGuide.shared.speedAdviceForCorner(h, speedKmh: spd)
        }
        return nil
    }

    /// 复位（停止驾驶 / 模式切换时调用）
    func reset(to seg: DriveSegment = .vision, reason: String) {
        segment = seg
        segmentSince = Date()
        targetCorner = nil
        targetJunction = nil
        handoverOrigin = nil
        handoverFrames = 0
        handoverProgress = "—"
        lastReason = reason
    }

    /// 停止驾驶时的完整清理
    func fullReset() {
        reset(to: .vision, reason: "已复位")
        consumedCorners.removeAll()
    }
}
