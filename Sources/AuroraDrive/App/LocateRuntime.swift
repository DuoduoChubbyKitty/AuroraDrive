// ============================================================================
// LocateRuntime.swift — 定位运行时支撑类型
// ----------------------------------------------------------------------------
// 从已删除的 MinimapLocatorView.swift 中析出的纯逻辑类型（非 UI）。
// 原文件里 LocateGate / LocateContext 与视图混在一起，删除旧视图时被一并
// 带走导致编译失败；此处按职责单独留存，UI 侧改由 MissionConsole 承载。
// ============================================================================

import Foundation

/// 定位互斥闸：保证同一时刻只有一路定位在跑（视觉/网络共用）。
final class LocateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func end() { lock.lock(); defer { lock.unlock() }; busy = false }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
}

/// 定位上下文：持有两路定位器实例与就绪标志，供 DriveState 驱动。
final class LocateContext: @unchecked Sendable {
    var visualLocator: VisualLocator? = nil
    var networkLocator: NetworkLocator? = nil
    var visualReady = false
    var networkReady = false
    var activeMode = "fallback"
}
