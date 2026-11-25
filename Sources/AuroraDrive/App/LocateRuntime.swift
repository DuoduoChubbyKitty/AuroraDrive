// ============================================================================
// LocateRuntime.swift — 定位运行时支撑类型
// ----------------------------------------------------------------------------
// 从已删除的 MinimapLocatorView.swift 中析出的纯逻辑类型（非 UI）。
// 原文件里 LocateGate / LocateContext 与视图混在一起，删除旧视图时被一并
// 带走导致编译失败；此处按职责单独留存，UI 侧改由 MissionConsole 承载。
// ============================================================================

import Foundation

/// 定位互斥闸：保证同一时刻只有一路定位在跑（视觉/网络共用）。
/// ⚠️ 2026-11 核实：`locateGate` 虽被 `AuroraDriveApp` 持有（DriveState 字段），
///   但 `tryBegin()/end()/isBusy` **全仓无任何调用点** —— 视觉定位未接线，
///   此闸当前实际未生效（见本文件末尾 LocateContext 的同款说明）。
///   2026-11-25：任务书原判「全仓仅在自身文件出现」有漂移——实际有 1 处真实
///   引用（DriveState 的构造行），故按「有引用不删、标记 deprecated」处理；
///   接线或删除请连 DriveState 的构造行一起改。
@available(*, deprecated, message: "未接线：被 DriveState 构造但 tryBegin/end/isBusy 全仓零调用（防复活断言见 scripts/check-dead-code.sh）")
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
    // ⚠️ 2026-11-25 复核：本类**不整体 deprecated**——networkReady 是活字段
    //   （AuroraDriveApp 网络定位步真实驱动/读取）。以下四字段才是死字段：
    //   全仓无任何读写点，唯一引用就是各自的声明行。注意别和 AuroraDriveApp
    //   的 `visualLocator: MapLocBridge?` 字段（真在跑的视觉定位）重名混淆。
    @available(*, deprecated, message: "未接线：恒为 nil，无读写点；现行视觉定位走 MapLocBridge，不经过本字段（防复活断言见 scripts/check-dead-code.sh）")
    var visualLocator: VisualLocator? = nil
    @available(*, deprecated, message: "未接线：恒为 nil，无读写点；现行网络定位走 CoordinateCapture，不经过本字段")
    var networkLocator: NetworkLocator? = nil
    @available(*, deprecated, message: "未接线：无读写点")
    var visualReady = false
    var networkReady = false
    @available(*, deprecated, message: "未接线：无读写点")
    var activeMode = "fallback"
}
