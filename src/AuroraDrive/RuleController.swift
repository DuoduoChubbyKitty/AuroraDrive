// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

// MARK: - 规则控制器的危险区判断和紧迫度扩展（作用于 Detection）

extension Detection {
    func isInDangerZone(dangerHalfWidth: Double = 0.18, dangerYMin: Double = 0.45) -> Bool {
        abs(x - 0.5) < dangerHalfWidth && y > dangerYMin
    }

    var urgency: Double {
        let sizeScore = width * height
        let centerScore = 1.0 - abs(x - 0.5) * 2.0
        return max(0, min(1, sizeScore * 8.0 * centerScore))
    }
}

// MARK: - 规则控制器

@Observable
final class RuleController {

    // MARK: - 可调阈值

    var dangerHalfWidth: Double = 0.18

    var dangerYMin: Double = 0.45

    var hardBrakeUrgency: Double = 0.55

    var brakeUrgency: Double = 0.25

    var steerStrength: Double = 1.0

    // MARK: - 状态输出（UI 观察）

    enum DangerLevel: String {
        case safe     = "安全"
        case caution  = "注意"
        case danger   = "危险"
        case critical = "急刹"
    }

    private(set) var dangerLevel: DangerLevel = .safe
    private(set) var nearestDetection: Detection?

    // MARK: - 主入口

    func decide(detections: [Detection]) -> ControlCommand {
        // P5优化：单次扫描找最高 urgency 的危险检测，替代 filter+max 两次分配（~50 元素 → 0 分配）。
        var nearest: Detection?
        var bestUrgency: Double = -1
        for d in detections where d.isInDangerZone(dangerHalfWidth: dangerHalfWidth, dangerYMin: dangerYMin) {
            if d.urgency > bestUrgency {
                bestUrgency = d.urgency
                nearest = d
            }
        }
        nearestDetection = nearest

        guard let obs = nearest else {
            dangerLevel = .safe
            return ControlCommand(steer: 0, throttle: 0.8, brake: 0, confidence: 0.8)
        }

        let urgency = obs.urgency
        let offset = obs.x - 0.5

        if urgency > hardBrakeUrgency {
            dangerLevel = .critical
            return ControlCommand(steer: offset > 0 ? -1.0 : 1.0,
                                  throttle: 0,
                                  brake: 1.0,
                                  confidence: obs.confidence)
        } else if urgency > brakeUrgency {
            dangerLevel = .danger
            return ControlCommand(steer: (offset > 0 ? -1.0 : 1.0) * steerStrength,
                                  throttle: 0.2,
                                  brake: 0.6,
                                  confidence: obs.confidence)
        } else {
            dangerLevel = .caution
            return ControlCommand(steer: (offset > 0 ? -0.5 : 0.5) * steerStrength,
                                  throttle: 0.6,
                                  brake: 0.1,
                                  confidence: obs.confidence)
        }
    }

    func fuse(detections: [Detection], e2e: ControlCommand) -> ControlCommand {
        let ruleCmd = decide(detections: detections)

        switch dangerLevel {
        case .safe:
            return e2e
        case .caution:
            return ControlCommand(steer: e2e.steer * 0.5 + ruleCmd.steer * 0.5,
                                  throttle: e2e.throttle,
                                  brake: e2e.brake,
                                  confidence: e2e.confidence * 0.9)
        case .danger, .critical:
            return ruleCmd
        }
    }
}
