// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Observation

@Observable
final class ControlEngine {

    enum Action {
        case throttle, brake, steerLeft, steerRight, handbrake, boost
    }

    struct KeyMap {
        var throttle:    CGKeyCode = 13
        var brake:       CGKeyCode = 1
        var steerLeft:   CGKeyCode = 0
        var steerRight:  CGKeyCode = 2
        var handbrake:   CGKeyCode = 49
        var boost:       CGKeyCode = 56

        func keyCode(for action: Action) -> CGKeyCode {
            switch action {
            case .throttle:    return throttle
            case .brake:       return brake
            case .steerLeft:   return steerLeft
            case .steerRight:  return steerRight
            case .handbrake:   return handbrake
            case .boost:       return boost
            }
        }
    }

    var keyMap = KeyMap()

    private(set) var hasAccessibilityPermission = false

    private(set) var heldKeys: Set<CGKeyCode> = []

    @ObservationIgnored private(set) var postedEventCount: Int = 0

    private let eventSource: CGEventSource? = {
        return CGEventSource(stateID: .hidSystemState)
    }()

    // MARK: - 权限

    func checkPermission() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
        return trusted
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 按键注入

    func press(_ action: Action, duration: TimeInterval = 0.05) {
        guard ensurePermission() else { return }
        let keyCode = keyMap.keyCode(for: action)
        postKeyEvent(keyCode: keyCode, keyDown: true)
        usleep(useconds_t(duration * 1_000_000))
        postKeyEvent(keyCode: keyCode, keyDown: false)
    }

    func hold(_ action: Action) {
        guard ensurePermission() else { return }
        let keyCode = keyMap.keyCode(for: action)
        if heldKeys.contains(keyCode) { return }
        postKeyEvent(keyCode: keyCode, keyDown: true)
        heldKeys.insert(keyCode)
    }

    private func ensurePermission() -> Bool {
        guard hasAccessibilityPermission else { _ = checkPermission(); return false }
        return true
    }

    func release(_ action: Action) {
        let keyCode = keyMap.keyCode(for: action)
        guard heldKeys.contains(keyCode) else { return }
        postKeyEvent(keyCode: keyCode, keyDown: false)
        heldKeys.remove(keyCode)
    }

    func refreshHeldKeys() {
        guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }
        for keyCode in heldKeys {
            postKeyEvent(keyCode: keyCode, keyDown: true)
        }
    }

    func releaseAll() {
        let allMappedKeys: [CGKeyCode] = [
            keyMap.throttle, keyMap.brake,
            keyMap.steerLeft, keyMap.steerRight,
            keyMap.handbrake, keyMap.boost,
        ]
        for keyCode in allMappedKeys {
            postKeyEvent(keyCode: keyCode, keyDown: false)
        }
        heldKeys.removeAll()
    }

    // MARK: - 底层 CGEvent 注入

    private func postKeyEvent(keyCode: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown) else {
            print("[ControlEngine] CGEvent 创建失败 keyCode=\(keyCode) keyDown=\(keyDown)")
            return
        }
        event.post(tap: .cghidEventTap)
        postedEventCount &+= 1
    }

    func isHeld(_ action: Action) -> Bool {
        let keyCode = keyMap.keyCode(for: action)
        return heldKeys.contains(keyCode)
    }

    var heldCount: Int {
        return heldKeys.count
    }
}
