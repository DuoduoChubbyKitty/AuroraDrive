// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RuleController.swift — YOLO 检测 → 控制量 规则控制器
//
//  职责：把感知模型（game_assist_yolo.onnx）的障碍物检测结果，
//        用规则转换为 steer/throttle/brake 控制量
//
//  用途：
//    .yolo 态（YOLO_RULE）：纯规则，YOLO 检测 → 规则控制
//    .rule 态（E2E_ASSISTED）：E2E 输出 + 规则修正（避障覆盖）
//
//  设计：
//    1) 检测框用归一化坐标 [0,1]，与图像分辨率解耦
//    2) 只关心"正前方危险区"的障碍：水平中心带 + 垂直下方（近距）
//    3) 危险等级分三档：避让（转向绕开）/ 减速 / 急刹
//    4) .rule 态下与 E2E 输出融合：危险时规则覆盖，安全时信 E2E
// ============================================================================
import Foundation
import Observation

// MARK: - 检测结果类型

/// 单个障碍物检测结果（YOLO 输出解析后的统一格式）
/// 所有坐标归一化到 [0,1]，原点左上角，与图像分辨率解耦
struct Detection {

    /// 障碍物类别
    enum Label: String {
        case car        // 车辆
        case pedestrian // 行人
        case sign       // 交通牌
        case obstacle   // 通用障碍
    }

    /// 边界框（归一化）
    let x: Double       // 中心 x [0,1]
    let y: Double       // 中心 y [0,1]
    let width: Double   // 宽 [0,1]
    let height: Double  // 高 [0,1]

    /// 类别
    let label: Label

    /// 置信度 [0,1]
    let confidence: Double

    /// 原始检测类名（COCO 类名，如 "CAR"/"PERSON"/"TRAFFIC LIGHT"）
    /// 仅用于 UI 画框时显示；规则决策只看 label。
    /// 有默认值 → 不影响既有的 Detection(x:y:width:height:label:confidence:) 调用。
    var rawName: String = "OBJ"

    /// 是否在"正前方危险区"
    /// 危险区定义：水平中心带（|x-0.5|<dangerHalfWidth）+ 垂直下方（y>dangerYMin，近距）
    func isInDangerZone(dangerHalfWidth: Double = 0.18,
                        dangerYMin: Double = 0.45) -> Bool {
        abs(x - 0.5) < dangerHalfWidth && y > dangerYMin
    }

    /// 估算的"碰撞紧迫度" [0,1]
    /// 框越大（越近）+ 越居中 → 紧迫度越高
    var urgency: Double {
        let sizeScore = width * height                    // 框面积
        let centerScore = 1.0 - abs(x - 0.5) * 2.0        // 居中度（中心=1，边缘=0）
        return max(0, min(1, sizeScore * 8.0 * centerScore))
    }
}

// MARK: - 规则控制器

/// 规则控制器
/// - @Observable：UI 可观察危险等级与最近障碍
/// - 纯函数式：decide(detections, e2e?) → ControlCommand
/// - 无内部状态，线程安全
@Observable
final class RuleController {

    // MARK: - 可调阈值

    /// 危险区水平半宽（中心带宽度 = 2 × 此值）
    var dangerHalfWidth: Double = 0.18

    /// 危险区垂直下限（y 大于此值视为近距）
    var dangerYMin: Double = 0.45

    /// 急刹阈值：紧迫度超过此值直接急刹
    var hardBrakeUrgency: Double = 0.55

    /// 减速阈值：紧迫度超过此值减速
    var brakeUrgency: Double = 0.25

    /// 避让转向强度系数
    var steerStrength: Double = 1.0

    // MARK: - 状态输出（UI 观察）

    /// 当前危险等级
    enum DangerLevel: String {
        case safe     = "安全"
        case caution  = "注意"
        case danger   = "危险"
        case critical = "急刹"
    }

    private(set) var dangerLevel: DangerLevel = .safe
    private(set) var nearestDetection: Detection?

    // MARK: - 主入口

    /// 纯规则决策（.yolo 态用）
    /// - Parameter detections: 本帧 YOLO 检测结果
    /// - Returns: 控制命令
    func decide(detections: [Detection]) -> ControlCommand {
        // 找出正前方危险区最紧迫的障碍
        let dangers = detections.filter { $0.isInDangerZone(dangerHalfWidth: dangerHalfWidth,
                                                             dangerYMin: dangerYMin) }
        let nearest = dangers.max(by: { $0.urgency < $1.urgency })
        nearestDetection = nearest

        guard let obs = nearest else {
            // 无障碍：直行加速。
            // confidence 固定 0.8：直行是规则确定行为、无检测框可依，
            // 语义为"高但非满"的规则确定度（不再用危险等级反推置信度）。
            dangerLevel = .safe
            return ControlCommand(steer: 0, throttle: 0.8, brake: 0, confidence: 0.8)
        }

        let urgency = obs.urgency
        let offset = obs.x - 0.5    // 障碍相对中心的偏移：负=左，正=右

        // 有障碍时置信度 = YOLO 检测置信度 obs.confidence，反映"这个检测框可不可信"，
        // 与危险等级解耦：危险等级仍由 urgency 独立分档，只决定 steer/throttle/brake，
        // confidence 不再用危险等级分档给固定魔法值（原 0.4/0.5/0.6）。
        // 语义保持"越高越可靠"不变。

        // 危险等级分档
        if urgency > hardBrakeUrgency {
            dangerLevel = .critical
            // 急刹：刹死 + 向障碍反方向打满
            return ControlCommand(steer: offset > 0 ? -1.0 : 1.0,
                                  throttle: 0,
                                  brake: 1.0,
                                  confidence: obs.confidence)
        } else if urgency > brakeUrgency {
            dangerLevel = .danger
            // 减速避让：半刹车 + 向障碍反方向转向
            return ControlCommand(steer: (offset > 0 ? -1.0 : 1.0) * steerStrength,
                                  throttle: 0.2,
                                  brake: 0.6,
                                  confidence: obs.confidence)
        } else {
            dangerLevel = .caution
            // 轻微避让：保持油门 + 轻微转向绕开
            return ControlCommand(steer: (offset > 0 ? -0.5 : 0.5) * steerStrength,
                                  throttle: 0.6,
                                  brake: 0.1,
                                  confidence: obs.confidence)
        }
    }

    /// E2E + 规则融合决策（.rule 态用）
    /// - Parameters:
    ///   - detections: 本帧 YOLO 检测结果
    ///   - e2e: E2E 模型输出
    /// - Returns: 危险时规则覆盖 E2E，安全时信 E2E
    func fuse(detections: [Detection], e2e: ControlCommand) -> ControlCommand {
        let ruleCmd = decide(detections: detections)

        switch dangerLevel {
        case .safe:
            // 安全：完全信 E2E
            return e2e
        case .caution:
            // 注意：E2E 为主，规则只修正转向
            return ControlCommand(steer: e2e.steer * 0.5 + ruleCmd.steer * 0.5,
                                  throttle: e2e.throttle,
                                  brake: e2e.brake,
                                  confidence: e2e.confidence * 0.9)
        case .danger, .critical:
            // 危险/急刹：规则覆盖
            return ruleCmd
        }
    }
}
