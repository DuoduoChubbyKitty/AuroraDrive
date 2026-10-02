// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EscapeController.swift — 公共控制输出类型（ControlCommand）
//
//  公共类型 ControlCommand：
//    统一三段决策（E2E/Rule/Escape）的输出格式
//    steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]
//    调用方（DriveState）把 ControlCommand 映射到 ControlEngine 按键注入
//
//  注（2026-09-30）：EscapeController 脱困策略已按用户要求整体删除 ——
//  脱困档（.recover）实测压低速且无法退出，自动驾驶最多维持 ~12 秒。
//  ControlCommand 类型保留：E2E/Rule 两段决策的统一输出格式。
//  超时保护说明随脱困删除一并移除。
// ============================================================================
import Foundation
import Observation

// MARK: - 公共控制输出类型

/// 决策输出（E2E/Rule/Escape 三段胶水代码统一返回此类型）
/// - steer: 转向 [-1, 1]，左负右正
/// - throttle: 油门 [0, 1]
/// - brake: 刹车 [0, 1]（游戏里 S 键通常兼作倒车）
/// - confidence: 本次决策的置信度 [0, 1]，供状态机降级用（E2E 填模型置信度，
///   Rule 填启发式分，Escape 固定 0.3 表示低置信脱困中）
struct ControlCommand: Equatable {
    var steer: Double = 0
    var throttle: Double = 0
    var brake: Double = 0
    var confidence: Double = 1.0

    /// 空操作（松开所有键）
    static let idle = ControlCommand()

    /// 从语义动作构造（便于 EscapeController 表达"按 W"+"按 A"）
    init(steer: Double = 0, throttle: Double = 0, brake: Double = 0, confidence: Double = 1.0) {
        self.steer = steer
        self.throttle = throttle
        self.brake = brake
        self.confidence = confidence
    }
}
