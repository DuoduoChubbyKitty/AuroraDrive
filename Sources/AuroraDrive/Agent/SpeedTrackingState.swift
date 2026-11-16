// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 控制速度与诊断估计分开保存：外推历史永远不能进入可信 EMA。
/// 所有时间均为同一单调时钟的秒数；墙钟只供日志使用。
struct SpeedTrackingState {
    private(set) var trustedSpeedKmh = 0.0
    private(set) var estimatedSpeedKmh = 0.0
    private(set) var speedValid = false
    private var lastObservation: Double?
    private var invalidationID: UInt64 = 0
    private var extrapolator = SpeedExtrapolator()

    /// 返回是否需要撤销副驾旧结果（包括两次 tick 之间发生过失效又恢复）。
    @discardableResult
    mutating func update(speed: Double, confidence: Double, observedAt: Double?,
                         invalidationID: UInt64, now: Double) -> Bool {
        let invalidated = self.invalidationID != invalidationID
        self.invalidationID = invalidationID
        let age = observedAt.map { now - $0 } ?? .infinity
        let ocrFresh = speed.isFinite && speed >= 0 && speed <= 400
            && confidence.isFinite && confidence > 0.6
            && now.isFinite && age.isFinite && age >= 0 && age < 0.5
        let resume = !speedValid || invalidated
            || (observedAt.map { $0 - (lastObservation ?? $0) >= 0.5 } ?? false)
        speedValid = ocrFresh
        if ocrFresh, let observedAt {
            if resume || observedAt != lastObservation {
                trustedSpeedKmh = resume ? speed : trustedSpeedKmh + (speed - trustedSpeedKmh) * 0.7
            }
            if observedAt != lastObservation {
                // Date 仅作旧外推器接口的数值载体，绝不读取墙钟。
                extrapolator.recordValid(speed: speed, at: Date(timeIntervalSinceReferenceDate: observedAt))
                lastObservation = observedAt
            }
            estimatedSpeedKmh = trustedSpeedKmh
        } else {
            estimatedSpeedKmh = extrapolator.estimatedSpeed(
                at: Date(timeIntervalSinceReferenceDate: now)) ?? 0
        }
        return invalidated || !ocrFresh || resume
    }

    mutating func reset() { self = SpeedTrackingState() }
}
