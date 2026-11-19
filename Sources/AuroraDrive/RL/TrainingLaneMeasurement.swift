import Foundation

/// One image owns one result. PPO can consume a completed measurement without waiting for perception.
final class TrainingLaneMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var measured: Double?
    var offset: Double? { lock.withLock { measured } }

    func record(_ geometry: LaneGeometry) {
        guard geometry.lateralOffsetReliable, geometry.lateralOffset.isFinite else { return }
        lock.withLock { measured = geometry.lateralOffset }
    }
}
