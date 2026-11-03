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

    // MARK: - 用户按键回调（ET-2 · 应急接管用）

    /// 用户真实按下受控键（W/A/S/D/空格等驾驶键）时回调。
    /// 只在 EmergencyTakeover.takeoverActive 时接线方会设值；平时为 nil（省资源）。
    ///
    /// 【零开销】nil 时本类只在 handleKeyDown 里做一次 `if let` 即返回，
    /// 不查受控键集合（短路顺序：先判 nil，再判集合）。
    /// 【线程】与 heldKeys 同模型：全局监听回调投递在主线程，接线方也在主线程设值。
    var onUserKeyDown: (() -> Void)?

    /// 用户松开受控键时回调
    var onUserKeyUp: (() -> Void)?

    /// 受控键的 macOS 虚拟键码集合（用于判定 onUserKeyDown/Up 是否触发）。
    ///
    /// ⚠️ **必须与 `ControlEngine.gameKeyToKeyCode`（`ControlEngine.swift:624-641`）
    ///   保持一致** —— 那张表是 `private static`，本类访问不到，故在此镜像一份。
    ///   GameKey 极少变动（上次加键是 2026-09 钢琴键），漂移风险低；
    ///   若 ControlEngine 新增 GameKey，**必须同步加到这里**（否则新键的接管回调失效）。
    ///   键码是稳定的 kVK_ANSI_* 常量，不会随版本变。
    private static let controlledKeyCodes: Set<CGKeyCode> = [
        // 移动 W/A/S/D
        13, 0, 1, 2,
        // 交互 F/E/Space
        3, 14, 49,
        // UI：ESC/Q/R/M/B/T
        53, 12, 15, 46, 11, 17,
        // 功能热键 F1/F2/F4
        122, 120, 118,
        // 修饰 Shift/Ctrl
        56, 59,
        // 数字 1-7
        18, 19, 20, 21, 23, 22, 26,
        // 俄罗斯方块/节奏 J/K/L
        38, 40, 37,
        // 钢琴低音 Z/X/C/V/N
        6, 7, 8, 9, 45,
        // 钢琴中音 G/H/I
        5, 4, 34,
        // 钢琴高音 Y/U
        16, 32,
    ]

    /// 全局监听句柄（启动时保存，停止时移除）
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    /// 修饰键监听句柄（.flagsChanged）
    private var flagsMonitor: Any?

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

        // 监听修饰键变化（.flagsChanged）
        //
        // 【为什么必须有】修饰键（Shift/Ctrl/Alt/Cmd）按下与松开**只产生
        //   flagsChanged**，不产生 keyDown/keyUp（本机实测：合成为 Shift 时
        //   down/up 两相的事件类型都是 12=flagsChanged）。
        //   而 Shift 在本项目里是**手刹**（用户确认的键位语义），也是超级刹车
        //   （Shift+Space）与极致刹车（Shift+Space+S）的前置条件。
        //   没有这条监听 → heldKeys 永远不含 56 → 录制出的 controls.csv 里
        //   shift 列全程为 0 → handbrake/super_brake/ultimate 三个安全头
        //   一个正样本都拿不到，训练出来的模型永远不会拉手刹。
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlags(event)
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
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        heldKeys.removeAll()
        keyDownTimes.removeAll()
    }

    // MARK: - 事件处理

    /// 按键按下：加入 heldKeys，并记录按住起点时间戳
    private func handleKeyDown(keyCode: CGKeyCode) {
        heldKeys.insert(keyCode)
        keyDownTimes[keyCode] = Date()
        // ET-2：用户真实按下受控键 → 回调应急接管。
        // 短路顺序：先判闭包 nil（零开销），再查受控键集合（O(1) Set）。
        // nil 时不查集合 = 平时（非接管态）无任何额外成本。
        if let onUserKeyDown, Self.controlledKeyCodes.contains(keyCode) {
            onUserKeyDown()
        }
    }

    /// 按键释放：从 heldKeys 移除，并清除时间戳
    private func handleKeyUp(keyCode: CGKeyCode) {
        heldKeys.remove(keyCode)
        keyDownTimes.removeValue(forKey: keyCode)
        // ET-2：松开同理（短路顺序同上）
        if let onUserKeyUp, Self.controlledKeyCodes.contains(keyCode) {
            onUserKeyUp()
        }
    }

    /// 修饰键左/右键码 → 对应的 flags 位。
    ///
    /// 为什么统一映射到**左**键码：`modifierFlags` 里左右两侧共用同一位，
    /// 无法区分；而项目（`ControlEngine.gameKeyToKeyCode`）只用左键码
    /// （Shift=56、Ctrl=59）。统一到左键码，`isHeld(56)` 对左右 Shift
    /// 都成立，语义是"Shift 是否按住"。
    private static let modifierKeyCodes: [(keyCode: CGKeyCode, mask: NSEvent.ModifierFlags)] = [
        (56, .shift),      // 左 Shift（56）；右 Shift=60，共用 .shift 位
        (59, .control),    // 左 Ctrl （59）；右 Ctrl =62
        (58, .option),     // 左 Option(58)；右 Option=61
        (55, .command),    // 左 Cmd  （55）；右 Cmd  =54
    ]

    /// 修饰键状态变化处理（.flagsChanged）
    ///
    /// 【为什么不能翻转状态位】修饰键按住期间，按下任意其它键都会再派发一次
    /// flagsChanged（带同样的修饰位）。若按"每次事件翻转"实现，第二次事件
    /// 就会把 Shift 错误翻成松开 → 手刹丢失。录制器 C 版踩过同一个坑
    /// （见 `tools/aurora_recorder.c` 中 `recorder_update_modifier_state` 的注释，
    ///   `tools/test_recorder_derive.c` 有对应回归用例）。
    /// 因此一律以事件携带的 `modifierFlags` **实际状态**为准，只在状态
    /// 真正发生变化时才更新 heldKeys 与计时。
    ///
    /// 【为什么不复用 handleKeyDown / handleKeyUp】那两个方法会触发
    /// `onUserKeyDown/Up` → UI 侧向引擎发 `takeover`（让位）信号。
    ///   56/59 在 `controlledKeyCodes` 里，而 Shift 是本项目的**手刹**；
    ///   若复用，按手刹就会变成"用户要接管" —— 这是本次改动**不应引入**的语义
    ///   变化（加监听前 Shift 根本收不到，从不触发让位）。故这里只更新键状态。
    private func handleModifierFlags(_ event: NSEvent) {
        let flags = event.modifierFlags
        for (keyCode, mask) in Self.modifierKeyCodes {
            let isPhysicallyHeld = flags.contains(mask)
            let wasHeld = heldKeys.contains(keyCode)
            // 状态未变（含"按住期间按其它键"产生的重复事件）→ 不重置计时
            guard isPhysicallyHeld != wasHeld else { continue }
            if isPhysicallyHeld {
                heldKeys.insert(keyCode)
                keyDownTimes[keyCode] = Date()
            } else {
                heldKeys.remove(keyCode)
                keyDownTimes.removeValue(forKey: keyCode)
            }
        }
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
