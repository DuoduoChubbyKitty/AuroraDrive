// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

// Equatable：tick() 里做"值不变不写 @Observable"判断的前提，
// 避免 30Hz 无效化风暴（@Observable setter 无条件触发 willSet）
struct ControlCommand: Equatable {
    var steer: Double = 0, throttle: Double = 0, brake: Double = 0, confidence: Double = 1.0
    static let idle = ControlCommand()
    init(steer: Double = 0, throttle: Double = 0, brake: Double = 0, confidence: Double = 1.0) {
        self.steer = steer; self.throttle = throttle; self.brake = brake; self.confidence = confidence
    }
}

@Observable
final class EscapeController {

    // MARK: - 可调参数

    var reverseDuration: Double = 1.5
    var turnDuration: Double = 0.8
    var forwardDuration: Double = 2.0
    var maxTotalDuration: Double = 15.0
    var escapeSpeedThreshold: Double = 8.0

    // MARK: - 状态输出

    enum Phase: String {
        case reverse = "倒车"
        case turn    = "转向"
        case forward = "前进"
        case done    = "完成"
    }

    private(set) var phase: Phase = .done
    private(set) var phaseRemaining: Double = 0
    private(set) var totalElapsed: Double = 0
    private(set) var escapeDirection: Double = 1

    // MARK: - 内部状态

    private var isEscaping = false

    private var lastUpdateTime: Date?

    // MARK: - 主入口

    func enter() {
        isEscaping = true
        totalElapsed = 0
        lastUpdateTime = nil
        escapeDirection = Bool.random() ? 1.0 : -1.0
        startPhase(.reverse)
    }

    @discardableResult
    func update(dt: Double, speedKmh: Double) -> (command: ControlCommand, escaped: Bool) {
        guard isEscaping else { return (.idle, false) }
        let now = Date()
        let actualDt: Double = lastUpdateTime.map(now.timeIntervalSince) ?? dt
        lastUpdateTime = now
        totalElapsed += actualDt
        phaseRemaining -= actualDt

        if totalElapsed >= maxTotalDuration {
            isEscaping = false; phase = .done
            return (ControlCommand(confidence: 0.3), false)
        }

        var cmd: ControlCommand
        switch phase {
        case .reverse: cmd = ControlCommand(steer: -escapeDirection * 0.5, brake: 1.0, confidence: 0.3)
        case .turn:    cmd = ControlCommand(steer: escapeDirection * 1.0, confidence: 0.3)
        case .forward:
            cmd = ControlCommand(steer: escapeDirection * 0.7, throttle: 1.0, confidence: 0.3)
            if speedKmh > escapeSpeedThreshold { isEscaping = false; phase = .done; return (cmd, true) }
        case .done: return (.idle, false)
        }

        if phaseRemaining <= 0 {
            switch phase {
            case .reverse: startPhase(.turn)
            case .turn:    startPhase(.forward)
            case .forward: startPhase(.reverse)
            case .done:    break
            }
        }
        return (cmd, false)
    }

    func reset() { isEscaping = false; phase = .done; phaseRemaining = 0; totalElapsed = 0; lastUpdateTime = nil }

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
