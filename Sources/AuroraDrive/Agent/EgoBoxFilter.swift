// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EgoBoxFilter.swift — 自车框屏蔽（决策层专用）
//
//  【要解决的问题】
//    用户玩的是**第三视角**。无论用什么模型，它都会把**玩家自己的车**当成一个
//    障碍框标出来。这个框进入决策层后会造成实际危害（历史事故见
//    `AuroraDriveApp.swift` §5.5 删除记录：ego 框 + 前车框被几何兜底判为
//    「框叠加 = 碰撞」，输出 brake 0.8 → 而本游戏 brake 就是 S 键兼倒车，
//    于是托管状态不停给用户刹车/倒车）。
//
//  【用户原话】「无论是什么模型，他都会标注自己车辆，我们是救不了这个办法」
//             「可以可以做」→ 同意做屏蔽
//
//  【为什么按面积判，而不是按位置判】
//    用户明确说过镜头会到处跑（「官方为了帅车可能会到处跑……甚至可以到最远端」）。
//    本次实测（10000 帧真游戏画面）也证明位置判据更差：
//
//        规则                     屏蔽自车成功率   误伤真车/帧
//        面积 > 2%                    98.0%         0.08
//        面积 > 3%                    97.8%         0.05
//        仅位置(中心带 + 下方)          93.2%         0.06
//        面积 > 3% 且 位置             93.0%         0.03
//
//    **加位置条件反而把召回从 98% 拉到 93%** —— 因为镜头一动自车就不在
//    「中心下方」了。故本过滤器**只看面积，不看位置**。
//
//  【阈值怎么定的（实测，不是拍脑袋）】
//    用「连续 600 帧时序跟踪」定出自车轨迹（覆盖率 88.8%，第二名真车仅 6.2%，
//    差 14 倍 —— 自车是唯一「永远在画面里」的目标，这条判据不受镜头摇摆影响），
//    再量它的面积：
//
//        自车框   中位 5.57%   p5 4.71%   **min 4.25%**
//        真车框   中位 0.17%   p95 9.34%
//
//    两者中位相差 **33 倍**。阈值取 **4.0%**（自车下界 4.25% 再留 0.25pp 余量）
//    → 自车 **100%** 被屏蔽，误伤真车 0.112 框/帧。
//
//  【边界（有意为之）】
//    · fail-open：框面积算不出来（NaN / 非有限 / 零尺寸）→ **保留**，
//      宁可多留一个框，不可因异常值把真车吃掉。
//    · 纯函数、无状态、无副作用 —— 可单测（与 RuleController / LaneFallback 同风格）。
//    · **只作用于决策层**。UI 照旧画全部框（含自车），见 `displayDetections`。
// ============================================================================

import Foundation

// MARK: - 自车框过滤器

/// 按**面积**剔除自车框。纯函数式，无状态。
struct EgoBoxFilter: Equatable {

    /// 归一化面积阈值：框面积（width × height，均为 [0,1] 归一化值）**大于**此值即判为自车。
    ///
    /// 实测依据见文件头：自车 min 4.25% / 真车中位 0.17% → 取 4.0%。
    ///
    /// ⚠️ 这是本机制**唯一的**可调常量。若实测发现误伤近距离真车偏多，只调它。
    var areaThreshold: Double = EgoBoxFilter.defaultAreaThreshold

    /// 阈值默认值（4.0%）
    static let defaultAreaThreshold: Double = 0.04

    /// 环境变量名（`AURORA_EGO_AREA=0.03` 调阈值；`=0` 关闭屏蔽）
    static let envKey = "AURORA_EGO_AREA"

    /// 从环境变量构造（全生命周期只读一次，避免每帧读 ProcessInfo）。
    ///
    /// 与项目既有约定一致（`AURORA_YOLOPX_LETTERBOX_MAIN` / `AURORA_STUCK_SECONDS`
    /// 同风格）：用环境变量而不是新增 UI 控件。
    /// 解析失败 → 用默认值（不崩、不静默关掉功能）。
    static let configured: EgoBoxFilter = {
        guard let raw = ProcessInfo.processInfo.environment[envKey],
              let v = Double(raw), v.isFinite, v >= 0 else {
            return EgoBoxFilter()
        }
        return EgoBoxFilter(areaThreshold: v)
    }()

    /// 是否启用（阈值为 0 = 关闭屏蔽，供一键回滚）
    var isEnabled: Bool { areaThreshold > 0 }

    /// 单个框的归一化面积（width × height）。
    /// 非有限值返回 nil，交由调用方按 fail-open 处理。
    static func normalizedArea(of d: Detection) -> Double? {
        let a = d.width * d.height
        return a.isFinite && a >= 0 ? a : nil
    }

    /// 该框是否应判为自车。
    ///
    /// fail-open：面积异常（NaN/Inf/负）→ **false**（不屏蔽，保留）。
    func isEgo(_ d: Detection) -> Bool {
        guard isEnabled else { return false }
        guard let a = Self.normalizedArea(of: d) else { return false }
        return a > areaThreshold
    }

    /// 过滤：返回**去掉自车框**后的列表（保持原有顺序）。
    ///
    /// 这是决策层该拿到的列表；UI 要拿未过滤的原列表（见 `displayDetections`）。
    func filter(_ detections: [Detection]) -> [Detection] {
        guard isEnabled else { return detections }
        return detections.filter { !isEgo($0) }
    }

    /// 被剔除的框数量（诊断/自检用 —— 从计数也能看出阈值是否生效）。
    func droppedCount(_ detections: [Detection]) -> Int {
        guard isEnabled else { return 0 }
        return detections.reduce(into: 0) { n, d in if isEgo(d) { n += 1 } }
    }

    /// 诊断串（进日志/自检输出）
    var diagnosticDescription: String {
        isEnabled
            ? "自车屏蔽 开（面积 > \(String(format: "%.1f", areaThreshold * 100))%）"
            : "自车屏蔽 关"
    }
}
