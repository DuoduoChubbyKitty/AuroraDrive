// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EscapeController.swift — 脱困策略 + 公共控制输出类型
//
//  公共类型 ControlCommand：
//    统一三段决策（E2E/Rule/Escape）的输出格式
//    steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]
//    调用方（DriveState）把 ControlCommand 映射到 ControlEngine 按键注入
//
//  EscapeController 脱困策略：
//    状态机进入 .recover 时调用，输出倒车→转向→前进的循环动作
//    纯硬编码规则，不依赖模型
//    超时保护：总时长超限强制报告失败，避免无限脱困
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
struct ControlCommand {
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

// MARK: - 脱困策略

/// 脱困控制器
/// - @Observable：UI 可观察脱困阶段与倒计时
/// - 内部三阶段状态机：REVERSE → TURN → FORWARD
/// - 进入 .recover 态时调用 enter()，每帧 update(dt) 返回 ControlCommand
/// - 脱困成功（前进时车速恢复）或超时失败时，调用方应退出 .recover 态
@Observable
final class EscapeController {

    // MARK: - 可调参数

    /// 倒车时长（秒）：先倒车拉开距离
    var reverseDuration: Double = 1.5

    /// 转向时长（秒）：原地打方向，为前进做准备
    var turnDuration: Double = 0.8

    /// 前进时长（秒）：尝试前进，观察是否脱困
    var forwardDuration: Double = 2.0

    /// 最大脱困总时长（秒）：超时强制失败，避免无限循环
    var maxTotalDuration: Double = 15.0

    /// 脱困成功车速阈值（km/h）：前进阶段车速超过此值视为脱困成功
    var escapeSpeedThreshold: Double = 8.0

    // MARK: - 状态输出

    /// 脱困阶段
    enum Phase: String {
        case reverse = "倒车"
        case turn    = "转向"
        case forward = "前进"
        case done    = "完成"
    }

    /// 当前阶段（UI 可展示）
    private(set) var phase: Phase = .done

    /// 当前阶段剩余时间（秒）
    private(set) var phaseRemaining: Double = 0

    /// 累计脱困时长（秒）
    private(set) var totalElapsed: Double = 0

    /// 脱困转向方向：+1 右转 / -1 左转
    /// 进入脱困时随机选一边，整个脱困过程保持一致，避免左右横跳
    private(set) var escapeDirection: Double = 1

    // MARK: - 内部状态

    private var isEscaping = false

    /// 上次 update 调用的实际时间戳：phase 计时/超时保护用真实经过时间累加，
    /// 避免主线程 tick 掉拍时 dt 恒 1/30 导致倒车/转向/前进各阶段计时偏慢。
    private var lastUpdateTime: Date?

    // MARK: - 主入口

    /// 进入脱困态（状态机转入 .recover 时调用）
    /// - Parameter currentSteer: 当前转向，用于决定脱困方向（反向脱困）
    func enter() {
        isEscaping = true
        totalElapsed = 0
        lastUpdateTime = nil   // 重新进入脱困时重置计时基准，避免把上一次脱困的间隔算进本周期
        // 随机选脱困方向，避免每次都往同一边撞
        escapeDirection = Bool.random() ? 1.0 : -1.0
        startPhase(.reverse)
    }

    /// 每帧更新脱困策略
    /// - Parameters:
    ///   - dt: 时间步长（秒）
    ///   - speedKmh: 当前车速
    /// - Returns: 控制命令 + 是否脱困成功
    @discardableResult
    func update(dt: Double, speedKmh: Double) -> (command: ControlCommand, escaped: Bool) {
        guard isEscaping else {
            return (.idle, false)
        }

        // 计时用真实经过时间（Date 差值），dt=1/30 仅作首次调用回退；
        // 主线程掉拍时不会让各阶段相位计时偏慢。
        let now = Date()
        let actualDt: Double
        if let last = lastUpdateTime {
            actualDt = now.timeIntervalSince(last)
        } else {
            actualDt = dt
        }
        lastUpdateTime = now

        totalElapsed += actualDt
        phaseRemaining -= actualDt

        // 超时保护：强制失败
        if totalElapsed >= maxTotalDuration {
            isEscaping = false
            phase = .done
            return (ControlCommand(confidence: 0.3), false)
        }

        // 根据阶段输出控制量
        var cmd: ControlCommand
        switch phase {
        case .reverse:
            // 倒车：按 S（brake）+ 反向轻微转向
            cmd = ControlCommand(steer: -escapeDirection * 0.5,
                                 throttle: 0,
                                 brake: 1.0,
                                 confidence: 0.3)

        case .turn:
            // 转向：松开油门刹车，纯打方向
            cmd = ControlCommand(steer: escapeDirection * 1.0,
                                 throttle: 0,
                                 brake: 0,
                                 confidence: 0.3)

        case .forward:
            // 前进：油门 + 脱困方向转向
            cmd = ControlCommand(steer: escapeDirection * 0.7,
                                 throttle: 1.0,
                                 brake: 0,
                                 confidence: 0.3)
            // 前进阶段车速恢复 → 脱困成功
            if speedKmh > escapeSpeedThreshold {
                isEscaping = false
                phase = .done
                return (cmd, true)
            }

        case .done:
            return (.idle, false)
        }

        // 阶段切换
        if phaseRemaining <= 0 {
            switch phase {
            case .reverse: startPhase(.turn)
            case .turn:    startPhase(.forward)
            case .forward: startPhase(.reverse)   // 循环：前进没脱困就再倒车
            case .done:    break
            }
        }

        return (cmd, false)
    }

    /// 重置（退出 .recover 态时调用）
    func reset() {
        isEscaping = false
        phase = .done
        phaseRemaining = 0
        totalElapsed = 0
        lastUpdateTime = nil
    }

    // MARK: - 内部

    /// 启动某个阶段
    private func startPhase(_ p: Phase) {
        phase = p
        switch p {
        case .reverse: phaseRemaining = reverseDuration
        case .turn:    phaseRemaining = turnDuration
        case .forward: phaseRemaining = forwardDuration
        case .done:    phaseRemaining = 0
        }
    }
}
