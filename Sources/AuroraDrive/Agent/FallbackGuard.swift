// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  FallbackGuard.swift —— 双结构几何兜底
//
//  用户提的两个判据（原话整理）：
//
//    结构 A —— 自车位置判定：
//      「把画面中心点最大的那个检测框，就认为是自己自车的位置」
//      用途：即使感知模型链断了，也能回答"我前方正中央有没有东西"。
//
//    结构 B —— 框叠加碰撞判定：
//      「中间点那个检测框如果和别的车检测框叠加在一起了，
//        那么肯定就是需要避让或者撞车，所以距离检测框叠加
//        就可以进行紧急避让那种，就可以作为兜底」
//      用途：纯几何的碰撞判据，不依赖任何模型置信度。
//
//  ── 定位：这是兜底，不是主驾 ──
//
//  设计纪律完全沿用 LaneFallback 的四条（见该文件头）：
//    ① fail-open：输入不可信（框太少 / 尺寸异常）→ 返回 nil，调用方维持原决策
//    ② 有界输出：转向/刹车都有硬限幅，绝不输出满油门
//    ③ 连续帧确认：同一判定需连续 N 帧稳定才采纳
//    ④ 突变丢弃：单帧异常不改变结论
//
//  纯函数式（与 RuleController / LaneFallback 同风格）：无外部副作用。
//  唯一的内部状态是稳定性计数器，由调用方每帧按序喂入。
// ============================================================================

import CoreGraphics
import Foundation

// MARK: - 兜底输出

/// 自车位置估计的置信来源
enum EgoEstimateSource: String, Equatable {
    /// 无法估计（画面里没有像样的框）
    case none = "无"

    /// 用"画面中心附近面积最大的框"估的（用户结构 A）
    case centerLargestBox = "中心最大框"
}

/// 双结构兜底的结论
struct FallbackGuardResult: Equatable {

    /// 自车前方的领先车辆框（结构 A 的输出）。nil = 没找到可信的前车。
    let leadBox: Detection?

    /// 自车位置估计的来源
    let egoSource: EgoEstimateSource

    /// 结构 B：判定为"正在与前方目标重叠"的对（本车 vs 障碍）
    /// 空数组 = 无碰撞风险
    let overlappingPairs: [(ego: Detection, other: Detection)]

    /// 最高紧迫度（复用 Detection.urgency 的口径）
    let maxUrgency: Double

    /// 可读原因（日志/UI）
    let reason: String

    static func == (lhs: FallbackGuardResult, rhs: FallbackGuardResult) -> Bool {
        lhs.leadBox == rhs.leadBox
            && lhs.egoSource == rhs.egoSource
            && lhs.maxUrgency == rhs.maxUrgency
            && lhs.reason == rhs.reason
            && lhs.overlappingPairs.count == rhs.overlappingPairs.count
    }
}

// MARK: - 兜底判定器

/// 双结构几何兜底判定器。
///
/// - 有状态（稳定性计数），须由同一调用方按帧顺序喂入
/// - 非 @Observable：状态仅用于内部去抖
final class FallbackGuard {

    // MARK: - 可调阈值

    /// 结构 A：候选"自车/前车"框必须落在画面中心这个半宽内（归一化）
    ///
    /// 0.25 → 画面中央 50% 宽度。比 RuleController 的危险区（0.18）宽，
    /// 因为这里要找的是"离我最近的那台车"，允许它稍微偏一点。
    var egoCenterHalfWidth: Double = 0.25

    /// 结构 A：候选框的下边界必须低于此处（归一化 y）
    ///
    /// 0.40 → 框要出现在画面下半部分（近处）。远处的小框不算"前车"。
    var egoMinCenterY: Double = 0.40

    /// 结构 A：候选框最小面积（归一化，宽×高）
    ///
    /// 0.008 → 约等于 640 图上 57×57 像素。太小的是远处噪点。
    var egoMinArea: Double = 0.008

    /// 结构 B：两框 IoU 超过此值 → 判定为重叠（正在接触/即将碰撞）
    ///
    /// 0.15 的来历：两个车"贴在一起"时 IoU 大约在 0.2~0.4；
    /// 取 0.15 留出预警提前量（还没贴上就报警）。太低会误报（并排行驶的车
    /// 在透视下 IoU 可能到 0.05）。
    var overlapIoU: Double = 0.15

    /// 结构 B：两框中心距小于此值（归一化）也算重叠
    ///
    /// 补 IoU 的盲区：大框套小框时 IoU 可能很低（小框被完全包含时
    /// IoU = 小框面积/大框面积），但中心距很近，同样是危险。
    var overlapCenterDistance: Double = 0.06

    /// 连续帧确认数（与 LaneFallback 同思路：防单帧抖动）
    var confirmFrames: Int = 3

    /// 转向硬限幅（与 LaneFallback.maxSteer 同口径）
    var maxSteer: Double = 0.25

    // MARK: - 内部状态

    private var overlapStreak = 0
    private var lastResult: FallbackGuardResult?
    private(set) var collisionStreak: Int = 0

    // MARK: - 主入口

    /// 对一帧检测结果做双结构兜底判定。
    ///
    /// - Parameters:
    ///   - detections: 本帧检测框（建议喂 MotionPredictor 的输出，外推后的）
    ///   - isDegraded: 感知链是否已降级
    /// - Returns: 判定结果；输入不可信时返回 nil（fail-open）
    func evaluate(detections: [Detection], isDegraded: Bool) -> FallbackGuardResult? {

        // ── 门①：降级时仍然工作 ──
        //
        // 注意这与 LaneFallback 相反！LaneFallback 依赖掩码，掩码降级就不可信；
        // 但本兜底**只依赖检测框**，而降级往往意味着"掩码坏了但框还在"。
        // 所以这里不因 degraded 而闭嘴 —— 恰恰是降级时才最需要几何兜底。
        // 唯一的门槛是"有没有框"。

        // ── 门②：框数为 0 时无结论 ──
        guard !detections.isEmpty else {
            reset()
            lastResult = nil
            return nil
        }

        // ── 门③：几何合法性 ──
        // 归一化坐标必须在 [0,1] 内且尺寸为正。越界说明上游数据错乱，
        // 拿这种数据做碰撞判定等于瞎判。
        let sane = detections.filter { d in
            d.x >= 0 && d.x <= 1 && d.y >= 0 && d.y <= 1
                && d.width > 0 && d.height > 0
                && d.x - d.width / 2 >= -0.05 && d.x + d.width / 2 <= 1.05
                && d.y - d.height / 2 >= -0.05 && d.y + d.height / 2 <= 1.05
        }
        guard !sane.isEmpty else {
            reset()
            lastResult = nil
            return nil
        }

        // ── 结构 A：自车位置 = 画面中心附近面积最大的框 ──
        let lead = locateLeadBox(in: sane)

        // ── 结构 B：框叠加 = 碰撞 ──
        var overlaps: [(ego: Detection, other: Detection)] = []
        if let ego = lead {
            for other in sane where other != ego {
                let iou = Self.iou(ego, other)
                let dist = Self.centerDistance(ego, other)
                if iou >= overlapIoU || dist <= overlapCenterDistance {
                    overlaps.append((ego, other))
                }
            }
        }

        // ── 连续帧确认：防单帧抖动 ──
        if overlaps.isEmpty {
            overlapStreak = max(0, overlapStreak - 1)
            collisionStreak = 0
        } else {
            overlapStreak = min(overlapStreak + 1, confirmFrames)
            collisionStreak = overlapStreak
        }
        let confirmed = overlapStreak >= confirmFrames

        // 紧迫度：重叠用满值，否则取领先车自身的 urgency
        let urgency: Double
        let reason: String
        if confirmed, let ego = lead, let first = overlaps.first {
            urgency = 1.0
            reason = "框叠加碰撞（IoU/中心距超限）→ 紧急避让"
                + String(format: " ego=(%.2f,%.2f,%.2f,%.2f)", ego.x, ego.y, ego.width, ego.height)
                + String(format: " other=(%.2f,%.2f,%.2f,%.2f)", first.other.x, first.other.y,
                         first.other.width, first.other.height)
        } else if overlaps.isEmpty {
            urgency = lead?.urgency ?? 0
            reason = lead == nil ? "画面内无可信前车" : "前车正常，无重叠"
        } else {
            urgency = lead?.urgency ?? 0
            reason = "疑似重叠但未连续确认（\(overlapStreak)/\(confirmFrames) 帧）"
        }

        let result = FallbackGuardResult(leadBox: lead,
                                         egoSource: lead == nil ? .none : .centerLargestBox,
                                         overlappingPairs: confirmed ? overlaps : [],
                                         maxUrgency: urgency,
                                         reason: reason)
        lastResult = result
        return result
    }

    /// 结构 A 的实现：在画面中心带内找面积最大的框。
    ///
    /// 为什么是"面积最大"而不是"离中心最近"：用户的原话是「画面中心点最大的
    /// 那个检测框」。在行车视角下，越近的车在画面里越大 —— 面积是距离的
    /// 单调代理，而中心距只是横向偏移的代理。两者结合（中心带内取最大）
    /// 恰好等价于"正前方最近的障碍"。
    private func locateLeadBox(in detections: [Detection]) -> Detection? {
        var best: Detection?
        var bestArea = 0.0
        for d in detections {
            guard abs(d.x - 0.5) <= egoCenterHalfWidth else { continue }
            guard d.y >= egoMinCenterY else { continue }
            let area = d.width * d.height
            guard area >= egoMinArea else { continue }
            if area > bestArea {
                bestArea = area
                best = d
            }
        }
        return best
    }

    /// 清空状态
    func reset() {
        overlapStreak = 0
        collisionStreak = 0
        lastResult = nil
    }

    // MARK: - 建议输出

    /// 把判定结果转成控制建议（与 LaneAdvice 同口径的保守约束）。
    ///
    /// 保守性保证：只要真的在介入（转向或刹车），throttleCap 一定非 nil 且 ≤0.3。
    /// 返回 nil = 无建议（调用方维持原决策）。
    func advice(_ result: FallbackGuardResult?) -> LaneAdvice? {
        guard let r = result, let ego = r.leadBox else { return nil }
        guard !r.overlappingPairs.isEmpty else { return nil }   // 无碰撞不上报

        // 往障碍的反方向打（障碍在左 → 往右）
        let offset = ego.x - 0.5
        let steer = max(-maxSteer, min(maxSteer, (offset > 0 ? -1.0 : 1.0) * maxSteer))
        return LaneAdvice(steer: steer,
                          brake: 0.8,
                          throttleCap: 0.2,
                          confidence: 0.9,
                          reason: "几何兜底：\(r.reason)")
    }

    // MARK: - 工具

    private nonisolated static func iou(_ a: Detection, _ b: Detection) -> Double {
        let ax1 = a.x - a.width / 2, ax2 = a.x + a.width / 2
        let ay1 = a.y - a.height / 2, ay2 = a.y + a.height / 2
        let bx1 = b.x - b.width / 2, bx2 = b.x + b.width / 2
        let by1 = b.y - b.height / 2, by2 = b.y + b.height / 2
        let iw = max(0, min(ax2, bx2) - max(ax1, bx1))
        let ih = max(0, min(ay2, by2) - max(ay1, by1))
        let inter = iw * ih
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    private nonisolated static func centerDistance(_ a: Detection, _ b: Detection) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
