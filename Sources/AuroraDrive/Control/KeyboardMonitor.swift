// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  KeyboardMonitor.swift — 物理键盘全局监听
//  用 NSEvent.addGlobalMonitorForEvents 监听系统级键盘按下/释放
//  实时反映用户物理键盘状态，供 KeyboardBar 显示
//  注意：全局监听需要辅助功能权限（与 ControlEngine 共用）
// ============================================================================

import AppKit
import Observation

/// 物理键盘全局监听器
/// - 监听系统级 keyDown / keyUp 事件（即使 app 不在前台也能收到）
/// - 实时更新 heldKeys，供 KeyboardBar 显示真实按键状态
/// - 需要"辅助功能"权限（与按键注入共用）
@Observable
final class KeyboardMonitor {

    /// 当前物理按住的键码集合
    /// KeyboardBar 观察此属性，实时高亮
    private(set) var heldKeys: Set<CGKeyCode> = []

    /// 受控键最近一次 keyDown 的时间戳（按住起点）
    /// keyUp / stop / clearAll 时同步移除；用于把"按住时长"换算成连续
    /// 控制标签（录制端专家模式）。@ObservationIgnored：纯内部计时数据，
    /// 无 UI 观察（KeyboardBar 只读 heldKeys）。
    @ObservationIgnored
    private var keyDownTimes: [CGKeyCode: Date] = [:]

    /// 全局监听句柄（启动时保存，停止时移除）
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    // MARK: - 启动 / 停止

    /// 启动全局键盘监听
    /// NSEvent.addGlobalMonitorForEvents：监听其他应用的事件（系统级）
    /// 需要"辅助功能"权限，否则收不到事件
    func start() {
        guard keyDownMonitor == nil else { return }

        // 监听 keyDown（物理按下）
        // mask: .keyDown 表示按键按下事件
        // 过滤 auto-repeat：物理键持续按住时，系统在 ~0.5s 后会以 ~50ms 周期
        // 派发带 autorepeat 标记的 keyDown；若不过滤，handleKeyDown 每次都会
        // 重置 keyDownTimes 时间戳 → holdDuration 永远只有 ~50ms，比例标签
        // 无法达到满刻度，按键时长功能失效。
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat else { return }
            self?.handleKeyDown(keyCode: event.keyCode)
        }

        // 监听 keyUp（物理释放）
        // mask: .keyUp 表示按键释放事件
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(keyCode: event.keyCode)
        }
    }

    /// 停止全局键盘监听
    func stop() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
        heldKeys.removeAll()
        keyDownTimes.removeAll()
    }

    // MARK: - 事件处理

    /// 按键按下：加入 heldKeys，并记录按住起点时间戳
    private func handleKeyDown(keyCode: CGKeyCode) {
        heldKeys.insert(keyCode)
        keyDownTimes[keyCode] = Date()
    }

    /// 按键释放：从 heldKeys 移除，并清除时间戳
    private func handleKeyUp(keyCode: CGKeyCode) {
        heldKeys.remove(keyCode)
        keyDownTimes.removeValue(forKey: keyCode)
    }

    // MARK: - 状态查询

    /// 某个键是否正在物理按住
    /// - Parameter keyCode: macOS 键码
    /// - Returns: 是否按住
    func isHeld(_ keyCode: CGKeyCode) -> Bool {
        return heldKeys.contains(keyCode)
    }

    /// 某个键当前已连续按住的时长（秒）
    /// - Parameter keyCode: macOS 键码（与 isHeld 同签名约定，CGKeyCode = UInt16）
    /// - Returns: 按住时长（秒）；未按住或从未记录返回 0
    /// 与 heldKeys 同一线程模型访问（监听回调线程），按现有主线程约定使用即可。
    func holdDuration(keyCode: CGKeyCode) -> TimeInterval {
        guard let down = keyDownTimes[keyCode] else { return 0 }
        return Date().timeIntervalSince(down)
    }

    /// 清空所有按键状态（失去焦点时调用，避免按键卡住）
    func clearAll() {
        heldKeys.removeAll()
        keyDownTimes.removeAll()
    }
}
