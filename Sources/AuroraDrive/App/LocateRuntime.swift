// ============================================================================
// LocateRuntime.swift — 定位运行时支撑类型
// ----------------------------------------------------------------------------
// 从已删除的 MinimapLocatorView.swift 中析出的纯逻辑类型（非 UI）。
// 原文件里 LocateGate / LocateContext 与视图混在一起，删除旧视图时被一并
// 带走导致编译失败；此处按职责单独留存，UI 侧改由 MissionConsole 承载。
// ============================================================================

import Foundation

/// 定位互斥闸：保证同一时刻只有一路定位在跑（视觉/网络共用）。
/// ⚠️ 2026-11 核实：`locateGate` 虽被 `AuroraDriveApp` 持有，但
///   `tryBegin()/end()/isBusy` **全仓无任何调用点** —— 视觉定位未接线，
///   此闸当前实际未生效（见本文件末尾 LocateContext 的同款说明）。
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
/// ⚠️ 2026-11 核实：`visualLocator`/`networkLocator` 两个字段**恒为 nil**，
///   `visualReady`/`activeMode` 亦无任何读取方或赋值点（全仓 grep 只有声明）；
///   四个字段中当前**只有 `networkReady` 被真实驱动**
///   （`AuroraDriveApp.runNetworkLocateStep()` 内置 true）。
///   即：视觉定位未接线，`VisualLocator`/`NetworkLocator` 从未被构造；
///   现行网络定位走 `AuroraDriveApp.coordinateCapture`（CoordinateCapture），
///   **不经过**本 context。
final class LocateContext: @unchecked Sendable {
    var visualLocator: VisualLocator? = nil
    var networkLocator: NetworkLocator? = nil
    var visualReady = false
    var networkReady = false
    var activeMode = "fallback"
}
