// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ControlEngine.swift — 按键注入引擎（CGEvent）
//  通过 CGEvent 向系统注入键盘事件，控制游戏（WASD + 空格 + Shift）
//  支持按下/释放/持续按住，支持按键映射配置
//  需要"辅助功能"权限（Accessibility）
// ============================================================================

import AppKit
import CoreGraphics
import Observation

/// 按键注入引擎
/// - 通过 CGEvent 向系统全局键盘队列注入按键事件
/// - 支持 press（按下后立即释放）、hold（持续按住）、release（释放）
/// - 按键映射可通过 keyMap 自定义
/// - 启动时检查辅助功能权限，无权限时引导用户到系统设置
/// - @Observable 让 SwiftUI 自动观察按键状态变化（键盘可视化条用）
@Observable
final class ControlEngine {

    /// 按键动作枚举（语义化，与具体键位解耦）
    enum Action {
        case throttle    // 油门（前进）
        case brake       // 刹车（后退）
        case steerLeft   // 左转
        case steerRight  // 右转
        case handbrake   // 手刹（空格）
        case boost       // 极速（Shift）
    }

    /// 按键映射：语义动作 → macOS 键码
    /// macOS 键码参考（HID Usage Table → macOS virtualKey）：
    /// W=13, A=0, S=1, D=2, 空格=49, LeftShift=56, RightShift=60
    struct KeyMap {
        var throttle:    CGKeyCode = 13   // W
        var brake:       CGKeyCode = 1    // S
        var steerLeft:   CGKeyCode = 0    // A
        var steerRight:  CGKeyCode = 2    // D
        var handbrake:   CGKeyCode = 49   // 空格
        var boost:       CGKeyCode = 56   // Left Shift

        /// 根据语义动作获取键码
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

    /// 当前按键映射（可运行时修改）
    var keyMap = KeyMap()

    /// 是否拥有辅助功能权限
    private(set) var hasAccessibilityPermission = false

    /// 当前按住的键集合（@Observable，键盘可视化条观察此属性）
    /// 每次按下/释放都更新，SwiftUI 自动刷新键帽颜色
    private(set) var heldKeys: Set<CGKeyCode> = []

    /// 累计成功注入的键盘事件总数（诊断用：判断事件流是否持续产生）
    /// 标记 @ObservationIgnored：此值每帧递增，不应触发 SwiftUI 重绘。
    @ObservationIgnored private(set) var postedEventCount: Int = 0

    /// CGEventSource（HID 系统状态层，注入的键对游戏「等同于真实物理按键」）
    private let eventSource: CGEventSource? = {
        // 必须用 .hidSystemState（对应 C API 的 kCGEventSourceStateHIDSystemState）：
        // 实测目标游戏（异环 NTE）的输入层只读取 HID 系统状态层的键盘事件。
        //
        // - .combinedSessionState（曾用）：实测对该游戏无效。该层的合成事件会被
        //   系统 UI 正常接收（键盘可视化条会亮、系统提示音会响），但游戏输入层
        //   直接忽略，表现为「UI 显示已输出 W，但游戏纹丝不动」。
        // - .privateState：更私有的状态层，游戏更加读不到，禁止使用。
        // - .hidSystemState：事件进入 HID 系统状态层，与真实物理键盘同层，
        //   配合下方 .cghidEventTap 投递，即为已验证可突破该游戏反作弊拦截的方案。
        return CGEventSource(stateID: .hidSystemState)
    }()

    // MARK: - 权限

    /// 检查辅助功能权限（macOS 10.9+）
    /// 无权限时注入事件会被系统静默丢弃
    func checkPermission() -> Bool {
        // AXIsProcessTrustedWithOptions 会触发系统授权弹窗（首次）
        // kAXTrustedCheckOptionPrompt: true 表示弹窗提示
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
        return trusted
    }

    /// 打开系统设置的辅助功能面板（引导用户授权）
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 按键注入

    /// 按下并立即释放一个键（短按）
    /// - Parameter action: 语义动作
    /// - Parameter duration: 按住时长（秒），默认 0.05s（50ms）
    func press(_ action: Action, duration: TimeInterval = 0.05) {
        guard hasAccessibilityPermission else {
            _ = checkPermission()
            return
        }
        let keyCode = keyMap.keyCode(for: action)
        postKeyEvent(keyCode: keyCode, keyDown: true)
        // 短暂等待后释放（模拟真实按键时长）
        usleep(useconds_t(duration * 1_000_000))
        postKeyEvent(keyCode: keyCode, keyDown: false)
    }

    /// 持续按住一个键（不释放，直到调用 release 或 releaseAll）
    /// - Parameter action: 语义动作
    func hold(_ action: Action) {
        guard hasAccessibilityPermission else {
            _ = checkPermission()
            return
        }
        let keyCode = keyMap.keyCode(for: action)
        // 避免重复按下（已按住则跳过）
        if heldKeys.contains(keyCode) { return }
        postKeyEvent(keyCode: keyCode, keyDown: true)
        heldKeys.insert(keyCode)
    }

    /// 释放一个键
    /// - Parameter action: 语义动作
    func release(_ action: Action) {
        let keyCode = keyMap.keyCode(for: action)
        guard heldKeys.contains(keyCode) else { return }
        postKeyEvent(keyCode: keyCode, keyDown: false)
        heldKeys.remove(keyCode)
    }

    /// 刷新所有按住键的按下状态（每个控制周期调用一次）
    ///
    /// 为什么必须有这一步：
    /// 真实物理键盘按住不放时，键盘硬件会持续向系统上报按键状态，系统据此
    /// 持续产生带 autorepeat 标记的 keyDown 事件流。游戏的输入状态机依赖
    /// 这个事件流判断"键还按着"。
    ///
    /// 而 CGEvent 注入是「一次性事件」：hold() 只在按下瞬间发一个 keyDown，
    /// 之后若控制量保持稳定（例如 E2E 模型在直道恒定输出 throttle=0.98），
    /// 就再也不会有任何键盘事件产生 —— 系统键盘状态虽然是"按住"，但游戏
    /// 从未收到过属于它的事件，表现为「UI 显示 W 已按住，游戏纹丝不动」。
    ///
    /// 因此持续按住的键必须按周期重发 keyDown。调用频率跟随控制主循环（30Hz），
    /// 与 macOS 默认按键重复率同量级。
    ///
    /// 关键：重发的 keyDown 必须是「新按下」语义（autorepeat = false）。
    /// 带 autorepeat 标记的事件会被该游戏的输入层忽略（它只认新按下），
    /// 导致稳定输出档位（如 M9）下只有 auto-repeat 事件流、游戏完全不动。
    /// 已验证方案（V1）同样是每次都发新按下，此处与之对齐。
    func refreshHeldKeys() {
        guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }
        for keyCode in heldKeys {
            postKeyEvent(keyCode: keyCode, keyDown: true)
        }
    }

    /// 释放所有按住的键（停止自动驾驶时调用，避免按键卡住）
    /// 无条件对所有映射键发释放事件：即使本会话没记录按过（例如上次进程
    /// 异常退出残留的系统级卡键），也主动清掉，保证系统键盘状态干净。
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

    /// 发送键盘事件（keyDown 或 keyUp）
    /// - Parameters:
    ///   - keyCode: macOS 键码
    ///   - keyDown: true=按下, false=释放
    ///   - autorepeat: 是否标记为「按住重复」事件（对应真实键盘的 auto-repeat）。
    ///                 保留该参数以备其他输入层使用，但针对目标游戏必须保持
    ///                 默认 false —— 该游戏输入层只认「新按下」，会忽略
    ///                 auto-repeat 事件（详见 refreshHeldKeys 说明）。
    private func postKeyEvent(keyCode: CGKeyCode, keyDown: Bool, autorepeat: Bool = false) {
        // CGEvent 创建：nil eventSource 时使用默认源
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            print("[ControlEngine] CGEvent 创建失败 keyCode=\(keyCode) keyDown=\(keyDown)")
            return
        }

        // 仅在显式要求时标记为按键重复事件。
        // 注意：目标游戏（异环 NTE）会忽略带 auto-repeat 标记的 keyDown，
        // 因此所有实际调用路径均使用默认 false，即每次都发「新按下」。
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }

        // postToPid 注入到特定进程（更精确，但需要 PID）
        // 这里用 CGEvent.post 全局注入，对所有前台应用生效
        // tap: .cghidEventTap 注入到硬件事件层（最底层，游戏必响应）
        event.post(tap: .cghidEventTap)
        postedEventCount &+= 1
    }

    // MARK: - 状态查询

    /// 某个键是否正在按住
    func isHeld(_ action: Action) -> Bool {
        let keyCode = keyMap.keyCode(for: action)
        return heldKeys.contains(keyCode)
    }

    /// 当前按住的键数量
    var heldCount: Int {
        return heldKeys.count
    }
}
