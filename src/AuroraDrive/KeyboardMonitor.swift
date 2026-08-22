// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation

@Observable
final class KeyboardMonitor {

    private(set) var heldKeys: Set<CGKeyCode> = []

    @ObservationIgnored
    private var keyDownTimes: [CGKeyCode: Date] = [:]

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    // MARK: - 启动 / 停止

    func start() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat else { return }
            self?.handleKeyDown(keyCode: event.keyCode)
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(keyCode: event.keyCode)
        }
    }

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

    private func handleKeyDown(keyCode: CGKeyCode) {
        heldKeys.insert(keyCode)
        keyDownTimes[keyCode] = Date()
    }

    private func handleKeyUp(keyCode: CGKeyCode) {
        heldKeys.remove(keyCode)
        keyDownTimes.removeValue(forKey: keyCode)
    }

    // MARK: - 状态查询

    func isHeld(_ keyCode: CGKeyCode) -> Bool { heldKeys.contains(keyCode) }

    func holdDuration(keyCode: CGKeyCode) -> TimeInterval {
        guard let down = keyDownTimes[keyCode] else { return 0 }
        return Date().timeIntervalSince(down)
    }

    func clearAll() {
        heldKeys.removeAll()
        keyDownTimes.removeAll()
    }
}
