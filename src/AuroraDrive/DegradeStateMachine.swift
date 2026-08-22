// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

@Observable
final class DegradeStateMachine {

    // MARK: - 可调阈值（与 DriveState 同步，UI 可改）

    var degradeHealth: Double = 0.65
    var recoverHysteresis: Double = 0.15
    var stuckSpeedThreshold: Double = 3.0
    var stuckTimeThreshold: Double = 3.0
    var recoverTimeout: Double = 30.0

    // MARK: - 状态输出

    private(set) var mode: DriveMode = .e2e
    private(set) var lastTransitionReason: String = "初始化"
    private(set) var stuckSeconds: Double = 0
    private(set) var sportOverride: Bool = false

    // MARK: - 内部状态

    private var previousMode: DriveMode = .e2e
    private var recoverElapsed: Double = 0
    private var lastUpdateTime: Date?

    // MARK: - 主入口

    @discardableResult
    func update(m9Live: Bool,
                assistLive: Bool,
                health: Double,
                warmingUp: Bool,
                speedKmh: Double,
                speedValid: Bool,
                dt: Double,
                sportMode: Bool,
                forceRule: Bool,
                now: Date) -> DriveMode {
        sportOverride = sportMode

        let actualDt: Double = lastUpdateTime.map(now.timeIntervalSince) ?? dt
        lastUpdateTime = now

        if mode == .recover { recoverElapsed += actualDt } else { recoverElapsed = 0 }

        if forceRule {
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            if stuckSeconds >= stuckTimeThreshold && mode != .recover {
                transition(to: .recover, reason: "卡住 \(String(format: "%.1f", stuckSeconds))s")
            } else if mode == .recover {
                if speedValid && speedKmh > stuckSpeedThreshold * 2 {
                    stuckSeconds = 0; recoverElapsed = 0; transition(to: .rule, reason: "脱困成功（纯规则）")
                } else if recoverElapsed >= recoverTimeout {
                    stuckSeconds = 0; recoverElapsed = 0; transition(to: .rule, reason: "脱困超时兜底（纯规则）")
                }
            } else if mode != .rule { transition(to: .rule, reason: "紧急切纯规则") }
            return mode
        }

        if sportMode {
            transition(to: .e2e, reason: "极速模式覆盖")
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            return mode
        }

        if warmingUp {
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            return mode
        }

        updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
        if stuckSeconds >= stuckTimeThreshold && mode != .recover {
            transition(to: .recover, reason: "卡住 \(String(format: "%.1f", stuckSeconds))s")
            return mode
        }
        if mode == .recover {
            if speedValid && speedKmh > stuckSpeedThreshold * 2 {
                stuckSeconds = 0; transition(to: .e2e, reason: "脱困成功")
            } else if recoverElapsed >= recoverTimeout {
                stuckSeconds = 0; recoverElapsed = 0; transition(to: .rule, reason: "脱困超时兜底")
            }
            return mode
        }

        let clampedHealth = max(0.0, min(1.0, health))
        let recov = min(0.99, degradeHealth + recoverHysteresis)
        switch mode {
        case .e2e:
            if !m9Live || clampedHealth < degradeHealth {
                transition(to: .yolo, reason: "M9 不可用（健康 \(pct(clampedHealth))）")
            }

        case .yolo:
            if !assistLive || clampedHealth < degradeHealth {
                transition(to: .rule, reason: "控制模型不可用（健康 \(pct(clampedHealth))）")
            } else if m9Live && clampedHealth > recov {
                transition(to: .e2e, reason: "M9 恢复（健康 \(pct(clampedHealth))）")
            }

        case .rule:
            if assistLive && clampedHealth > recov {
                transition(to: .yolo, reason: "控制模型恢复（健康 \(pct(clampedHealth))）")
            }

        case .recover:
            break
        }
        return mode
    }

    // MARK: - 卡住计时器

    private func updateStuckTimer(speedKmh: Double, dt: Double, allowEscape: Bool, speedValid: Bool) {
        guard speedValid else { return }
        if speedKmh < stuckSpeedThreshold {
            stuckSeconds += dt
        } else {
            stuckSeconds = max(0, stuckSeconds - dt * 2)
        }
    }

    // MARK: - 状态转换

    private func transition(to newMode: DriveMode, reason: String) {
        guard newMode != mode else { return }
        previousMode = mode
        mode = newMode
        lastTransitionReason = reason
    }

    func reset() {
        mode = .e2e; previousMode = .e2e; stuckSeconds = 0; recoverElapsed = 0
        lastUpdateTime = nil; lastTransitionReason = "已重置"; sportOverride = false
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
