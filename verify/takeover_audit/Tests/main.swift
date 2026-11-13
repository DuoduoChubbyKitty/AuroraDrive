// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 隔离审核测试：人工接管（让位）链路
// ─────────────────────────────────────────────────────────────────────────────
// 【安全边界】
//   · 不启动完整 App、不加载模型、不联网、不创建窗口、不向系统注入事件。
//   · 直接编译并调用生产类型（KeyboardMonitor / ControlEngine / EmergencyTakeover），
//     只把 5 个外部 I/O 换成内存双（见 Support.swift / build_harness.py）；
//     业务逻辑逐字来自仓库当前五文件补丁。
//   · 时间相关用 EmergencyTakeover.testNow 模拟，不真等 35 秒。

import AppKit
import CoreGraphics
import Darwin
import Foundation

var failures = 0
var checks = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    let suffix = detail.isEmpty ? "" : "  — \(detail)"
    if ok { print("  ✓ \(name)\(suffix)") }
    else { failures += 1; print("  ✗ \(name)\(suffix)") }
}

let W: CGKeyCode = 13, A: CGKeyCode = 0, S: CGKeyCode = 1, D: CGKeyCode = 2
let SPACE: CGKeyCode = 49, SHIFT: CGKeyCode = 56, CTRL: CGKeyCode = 59
let TAG = ControlEngine.injectedEventTag

func resetAll() {
    TestEventSink.reset()
    TestPermission.reset()
    TestMonitors.reset()
    EmergencyTakeover.testNow = nil
    EmergencyTakeover.shared.noteUserKeyUp()   // 状态机回到巡航
}
func makeEngine() -> ControlEngine {
    let e = ControlEngine()
    e.digestMode = true                     // 双保险：即使出口替换失效也不会真发
    return e
}
func hold(_ e: ControlEngine, _ keys: [CGKeyCode]) {
    for k in keys { if let g = gameKey(k) { e.holdGameKey(g) } }
}
func gameKey(_ k: CGKeyCode) -> ControlEngine.GameKey? {
    switch k {
    case 13: return .w; case 0: return .a; case 1: return .s; case 2: return .d
    case 49: return .space; case 56: return .shift; case 59: return .ctrl
    default: return nil
    }
}

// ══════════════════════════════════════════════════════════════════════════════
print("=== A. 键盘状态与回调（生产 KeyboardMonitor，模拟 NSEvent）===")

// A1: W 按下 / 松开：集合、回调、按住时间
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0, ups = 0, snapshots = 0
    m.onUserKeyDown = { downs += 1 }
    m.onUserKeyUp = { ups += 1 }
    m.onPhysicalKeysChanged = { snapshots += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    check("A1a W 按下进入 heldKeys", m.heldKeys == [W] && m.isHeld(W), "\(m.heldKeys)")
    check("A1b W 按下触发一次接管回调", downs == 1, "downs=\(downs)")
    check("A1c 按住起点存在", m.holdDuration(keyCode: W) >= 0)
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W))
    check("A1d W 松开清空状态并回调", m.heldKeys.isEmpty && !m.isHeld(W) && ups == 1
          && m.holdDuration(keyCode: W) == 0, "ups=\(ups) held=\(m.heldKeys)")
    check("A1e 物理键变化回调逐次到达", snapshots == 2, "snapshots=\(snapshots)")
}

// A2: W+A 同按，两种释放顺序：最后一个接管键松开前不恢复
do {
    for order in [[W, A], [A, W]] {
        resetAll()
        let m = KeyboardMonitor()
        var ups = 0, sent: [Bool] = []
        m.onPhysicalKeysChanged = { sent.append(m.isUserHoldingControlKey) }
        m.onUserKeyUp = { ups += 1 }
        m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
        m.handleEvent(EventFactory.key(.keyDown, keyCode: A))
        m.handleEvent(EventFactory.key(.keyUp, keyCode: order[0]))
        check("A2a 释放 \(order[0]) 后仍让位", m.heldKeys.count == 1
              && m.isUserHoldingControlKey && ups == 0, "held=\(m.heldKeys) ups=\(ups)")
        m.handleEvent(EventFactory.key(.keyUp, keyCode: order[1]))
        check("A2b 释放最后一个键 \(order[1]) 才恢复", m.heldKeys.isEmpty
              && !m.isUserHoldingControlKey && ups == 1, "ups=\(ups)")
        check("A2c 同包快照按事件顺序更新", sent == [true, true, true, false], "\(sent)")
    }
}

// A3: 同一键重复 keyDown / autorepeat：不重置起点、不重复回调
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0, changes = 0
    m.onUserKeyDown = { downs += 1 }
    m.onPhysicalKeysChanged = { changes += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    let t0 = m.holdDuration(keyCode: W)
    Thread.sleep(forTimeInterval: 0.02)
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))                 // 重复非 autorepeat
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W, isARepeat: true)) // autorepeat
    let t1 = m.holdDuration(keyCode: W)
    check("A3a 重复按下/autorepeat 不重置按住起点", t1 >= t0 + 0.015, "t0=\(t0) t1=\(t1)")
    check("A3b 重复按下不重复触发接管回调", downs == 1, "downs=\(downs)")
    check("A3c autorepeat 不额外产生快照消息", changes == 3, "changes=\(changes)")
}

// A4: 未知 keyUp / 重复 keyUp 不误退出
do {
    resetAll()
    let m = KeyboardMonitor()
    var ups = 0
    m.onUserKeyUp = { ups += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    m.handleEvent(EventFactory.key(.keyUp, keyCode: 99))       // 未知键
    m.handleEvent(EventFactory.key(.keyUp, keyCode: A))        // 未按住的受控键
    check("A4a 未知/未按住 keyUp 不误退出", m.isUserHoldingControlKey && ups == 0)
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W))
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W))        // 重复 keyUp
    check("A4b 重复 keyUp 不重复恢复", ups == 1, "ups=\(ups)")
}

// A5: 非受控键不触发接管（但 heldKeys 仍记录）
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0
    m.onUserKeyDown = { downs += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: 200))
    check("A5 非受控键可观测但不接管", m.heldKeys == [200]
          && !m.isUserHoldingControlKey && downs == 0, "downs=\(downs)")
}

// A6: Shift / Ctrl 单独按下可观测但不接管；W+Shift 顺序
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0, ups = 0
    m.onUserKeyDown = { downs += 1 }
    m.onUserKeyUp = { ups += 1 }
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: SHIFT, flags: .shift))
    check("A6a Shift 状态可观测、不接管", m.isHeld(SHIFT)
          && !m.isUserHoldingControlKey && downs == 0, "held=\(m.heldKeys)")
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: CTRL, flags: [.shift, .control]))
    check("A6b Ctrl 状态可观测、不接管", m.isHeld(CTRL) && m.isHeld(SHIFT)
          && !m.isUserHoldingControlKey, "held=\(m.heldKeys)")
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    check("A6c W+Shift 进入让位", m.isUserHoldingControlKey && downs == 1)
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: SHIFT, flags: [.control]))
    check("A6d W 仍按住时松开 Shift 不恢复", m.isUserHoldingControlKey && ups == 0)
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W))
    check("A6d2 松 W 即恢复（Ctrl 不计入接管键）", !m.isUserHoldingControlKey && ups == 1)
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: CTRL, flags: []))
    check("A6e 最后控制键松开恢复，修饰键仍可观测", !m.isUserHoldingControlKey
          && m.heldKeys.isEmpty && ups == 1, "ups=\(ups) held=\(m.heldKeys)")
}

// A7: 自产 keyDown/keyUp/flagsChanged 不得污染物理集合与接管状态
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0, ups = 0, changes = 0
    m.onUserKeyDown = { downs += 1 }
    m.onUserKeyUp = { ups += 1 }
    m.onPhysicalKeysChanged = { changes += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W, tag: TAG))
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W, tag: TAG))
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: SHIFT, tag: TAG, flags: .shift))
    check("A7a 自产三类事件全部被过滤", m.heldKeys.isEmpty && !m.isUserHoldingControlKey
          && downs == 0 && ups == 0 && changes == 0,
          "held=\(m.heldKeys) downs=\(downs) ups=\(ups) changes=\(changes)")
    // 普通未标记事件不得误丢
    m.handleEvent(EventFactory.key(.keyDown, keyCode: A))
    check("A7b 普通未标记事件不被误丢", m.isHeld(A) && m.isUserHoldingControlKey && downs == 1)
}

// A8: clearAll() / stop() / 重复停止：状态与通知一致
do {
    resetAll()
    let m = KeyboardMonitor()
    var ups = 0, changes = 0
    m.onUserKeyUp = { ups += 1 }
    m.onPhysicalKeysChanged = { changes += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    m.clearAll()
    // clearAll 同时发 onUserKeyUp（释放）与 onPhysicalKeysChanged（快照），故 changes=2
    check("A8a clearAll 清空并通知释放", m.heldKeys.isEmpty && ups == 1 && changes == 2,
          "ups=\(ups) changes=\(changes)")
    check("A8b 权限已授权不重复申请", m.requestInputMonitoringPermission()
          && TestPermission.requestCount == 0, "requests=\(TestPermission.requestCount)")
    check("A8c start 注册 global×3 + local", m.start()
          && TestMonitors.handles.count == 4, "handles=\(TestMonitors.handles.count)")
    // local monitor 返回原事件、不吞键
    let ev = EventFactory.key(.keyDown, keyCode: W)
    var returned: NSEvent?
    for h in TestMonitors.handles { if let l = h.local { returned = l(ev) } }
    check("A8d local monitor 返回原事件", returned === ev && m.isHeld(W))
    // 重复 start 不叠加监听
    _ = m.start()
    check("A8e 重复 start 不叠加监听", TestMonitors.handles.count == 4)
    m.stop()
    m.stop()
    check("A8f stop/重复 stop 移除全部句柄并清空状态",
          TestMonitors.handles.isEmpty && TestMonitors.removeCount == 4
          && m.heldKeys.isEmpty && ups == 2,
          "removed=\(TestMonitors.removeCount) ups=\(ups)")
}

// A9: 监听开始前已按住 W：后续 autorepeat 无法建立状态（明确边界）
do {
    resetAll()
    let m = KeyboardMonitor()
    var downs = 0
    m.onUserKeyDown = { downs += 1 }
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W, isARepeat: true))
    check("A9 前置按住 W 后 autorepeat 不建立状态（已知边界）",
          m.heldKeys.isEmpty && downs == 0,
          "held=\(m.heldKeys)；非 autorepeat 的后续 keyDown 会补建")
}

// ══════════════════════════════════════════════════════════════════════════════
print("\n=== B. 接管状态机（生产 EmergencyTakeover，可控时间）===")

let et = EmergencyTakeover.shared
resetAll()
check("B1 初始巡航 15Hz", et.effectiveTickHz == 15 && !et.takeoverActive
      && !et.sprinting && !et.userHoldingKey, "hz=\(et.effectiveTickHz)")
et.noteUserKeyDown()
check("B2 巡航按键 → 让位 5Hz", et.effectiveTickHz == 5 && et.userHoldingKey
      && et.takeoverActive && !et.sprinting, "hz=\(et.effectiveTickHz)")
et.noteUserKeyDown()
check("B3 重复按键幂等", et.userHoldingKey && et.effectiveTickHz == 5)
et.noteTickGap(500)
et.noteModelDegraded(true)
check("B4 让位期间掉拍/退化不抢回控制", et.userHoldingKey
      && et.effectiveTickHz == 5 && !et.sprinting)
et.noteUserKeyUp()
check("B5 释放 → 巡航 15Hz 且标志一致", et.effectiveTickHz == 15
      && !et.takeoverActive && !et.sprinting && !et.userHoldingKey)
et.noteUserKeyUp()
check("B6 非让位态 keyUp 无误转换", !et.userHoldingKey && et.effectiveTickHz == 15)

// 掉拍阈值 / 正常帧打断 / 退化边沿
et.noteTickGap(101)
et.noteTickGap(50)
for _ in 0..<(EmergencyTakeover.triggerConsecutiveMisses - 1) { et.noteTickGap(101) }
check("B7 未达阈值 + 正常帧打断累计", !et.sprinting && et.effectiveTickHz == 15)
et.noteTickGap(101)
check("B8 达到阈值 → 冲刺 20Hz", et.sprinting && et.takeoverActive
      && et.effectiveTickHz == 20, "hz=\(et.effectiveTickHz)")
et.noteModelDegraded(true)
check("B9 冲刺期间持续 true 不重复触发", et.sprinting && et.effectiveTickHz == 20)
et.noteUserKeyDown()
check("B10 冲刺按键 → 让位 5Hz、清冲刺", !et.sprinting && et.userHoldingKey
      && et.effectiveTickHz == 5)
et.noteUserKeyUp()

// 35 秒超时：可控时钟，不真等
let t0 = Date()
EmergencyTakeover.testNow = t0        // 让 enterSprint 的 sprintStart 也落在模拟时间
et.noteModelDegraded(false)
et.noteModelDegraded(true)
check("B11a 让位结束后应急可再次触发", et.sprinting && et.effectiveTickHz == 20)
EmergencyTakeover.testNow = t0.addingTimeInterval(34.9)
et.noteTickGap(50)
check("B11b 34.9s 未超时", et.sprinting && et.effectiveTickHz == 20)
EmergencyTakeover.testNow = t0.addingTimeInterval(35.0)
et.noteTickGap(50)
check("B11c 35.0s 超时 → 巡航", !et.sprinting && !et.takeoverActive
      && !et.userHoldingKey && et.effectiveTickHz == 15, "hz=\(et.effectiveTickHz)")
EmergencyTakeover.testNow = t0.addingTimeInterval(99)
et.noteTickGap(50)
check("B11d 超阈值后不再误转换", !et.sprinting && et.effectiveTickHz == 15)
EmergencyTakeover.testNow = nil
// 超时后仍能再次触发
et.noteModelDegraded(false); et.noteModelDegraded(true)
check("B11e 超时后应急仍可再次触发", et.sprinting && et.effectiveTickHz == 20)
et.noteUserKeyDown(); et.noteUserKeyUp()
resetAll()

// ══════════════════════════════════════════════════════════════════════════════
print("\n=== C. AI 键所有权移交（生产 ControlEngine，内存事件出口）===")

func checkReleases(_ name: String, ai: [CGKeyCode], physical: Set<CGKeyCode>,
                   expected: Set<CGKeyCode>, file: StaticString = #filePath, line: UInt = #line) {
    resetAll()
    let e = makeEngine()
    hold(e, ai)
    TestEventSink.reset()
    e.releaseAIHeldKeys(preserving: physical)
    let actual = Set(TestEventSink.keyUps)
    check(name, actual == expected && TestEventSink.keyDowns.isEmpty
          && e.heldKeys.isEmpty,
          "keyUps=\(TestEventSink.keyUps.sorted()) expected=\(expected.sorted()) held=\(e.heldKeys)")
}

checkReleases("C1 AI 无持键、人按 W → 零释放", ai: [], physical: [W], expected: [])
checkReleases("C2 AI 持 A、人按 W → 只释放 A", ai: [A], physical: [W], expected: [A])
checkReleases("C3 AI 持 W、人按 W → 不发 W keyUp", ai: [W], physical: [W], expected: [])
checkReleases("C4 AI 持 W+A、人按 W → 只释放 A", ai: [W, A], physical: [W], expected: [A])
checkReleases("C5 六键 AI、人按 W/D/Shift → 只释放差集",
              ai: [W, A, S, D, SPACE, SHIFT], physical: [W, D, SHIFT],
              expected: [A, S, SPACE])

do {
    resetAll()
    let e = makeEngine()
    hold(e, [A, S])
    TestEventSink.reset()
    e.releaseAIHeldKeys(preserving: [W])
    e.releaseAIHeldKeys(preserving: [W])
    e.releaseAIHeldKeys(preserving: [W])
    check("C6 重复让位不重复 keyUp",
          TestEventSink.keyUps.sorted() == [A, S] && e.heldKeys.isEmpty,
          "keyUps=\(TestEventSink.keyUps)")
}

do {
    resetAll()
    let e = makeEngine()
    hold(e, [W, A])
    e.releaseAIHeldKeys(preserving: [W, A])
    TestEventSink.reset()
    e.releaseAllGameKeys()
    e.releaseAIHeldKeys(preserving: [])
    check("C7 移交后后续清理零事件", TestEventSink.events.isEmpty, "\(TestEventSink.events.count)")
}

do {
    resetAll()
    let e = makeEngine()
    hold(e, [W])
    e.releaseAIHeldKeys(preserving: [W])
    TestEventSink.reset()
    e.holdGameKey(.w)
    check("C8 人松开后 AI 可重新按住 W",
          TestEventSink.keyDowns == [W] && e.heldKeys == [W], "held=\(e.heldKeys)")
}

do {
    resetAll()
    let e = makeEngine()
    TestEventSink.reset()
    e.releaseAll()
    check("C9 releaseAll 保留六键全量清扫职责",
          Set(TestEventSink.keyUps) == [W, A, S, D, SPACE, SHIFT]
          && TestEventSink.keyUps.count == 6,
          "keyUps=\(TestEventSink.keyUps.sorted())")
}

do {
    resetAll()
    let e = makeEngine()
    TestEventSink.reset()
    e.holdGameKey(.w)
    e.pressGameKey(.a, duration: 0)
    e.typeText("x")
    check("C10 所有键盘注入入口附加自产标记",
          !TestEventSink.events.isEmpty
          && TestEventSink.events.allSatisfy { $0.tag == TAG },
          "tags=\(Set(TestEventSink.events.map(\.tag))) count=\(TestEventSink.events.count)")
}

// ══════════════════════════════════════════════════════════════════════════════
print("\n=== D. 权限与监听失败（模拟授权结果，不接触真实 TCC）===")

do {
    resetAll()
    let m = KeyboardMonitor()
    TestPermission.granted = true
    check("D1 已授权：start 成功且不重复申请",
          m.start() && TestPermission.requestCount == 0 && m.hasInputMonitoringPermission)
    m.stop()
}
do {
    resetAll()
    let m = KeyboardMonitor()
    TestPermission.granted = false
    check("D2 未授权：申请一次、start 返回 false",
          !m.start() && TestPermission.requestCount == 1 && !m.hasInputMonitoringPermission,
          "requests=\(TestPermission.requestCount)")
    _ = m.start()
    check("D3 申请后仍未授权：不重复申请、不伪装成功",
          !m.start() && TestPermission.requestCount == 1)
    TestPermission.granted = true
    check("D4 后续变已授权：重试启动成功", m.start() && m.hasInputMonitoringPermission)
    m.stop()
}
do {
    resetAll()
    let m = KeyboardMonitor()
    TestMonitors.failGlobalOnCall = 2
    check("D5 global 部分注册失败 → 清理全部句柄、返回 false",
          !m.start() && TestMonitors.handles.isEmpty && TestMonitors.removeCount == 3,
          "handles=\(TestMonitors.handles.count) removed=\(TestMonitors.removeCount)")
}
do {
    resetAll()
    let m = KeyboardMonitor()
    TestMonitors.failLocalOnCall = 1
    check("D6 local 注册失败 → 不留半初始化状态",
          !m.start() && TestMonitors.handles.isEmpty && TestMonitors.removeCount == 3)
}
do {
    resetAll()
    let m = KeyboardMonitor()
    TestPermission.isEngineProcess = true
    check("D7 引擎进程不注册 AppKit 监听", !m.start()
          && TestMonitors.handles.isEmpty && TestPermission.requestCount == 0)
}

// ══════════════════════════════════════════════════════════════════════════════
print("\n=== E. 端到端组合：巡航 → W → 让位 → 松 W → 巡航 ===")

do {
    resetAll()
    let e = makeEngine()
    hold(e, [W, A, S])
    TestEventSink.reset()
    // UI 事件 → syncPhysicalControlState → EngineMain.config → 快照先应用，再让位
    let physical: Set<CGKeyCode> = [W]
    var remotePhysicalKeys: Set<CGKeyCode> = []  // 模拟 DriveState.remotePhysicalKeys
    remotePhysicalKeys = physical               // ① 先应用快照
    et.noteUserKeyDown()                        // ② 再处理 takeover
    e.releaseAIHeldKeys(preserving: remotePhysicalKeys)
    check("E1a 巡航 → 让位 5Hz", et.effectiveTickHz == 5 && et.userHoldingKey && et.takeoverActive)
    check("E1b 同键 W 不放、只释放 A/S",
          Set(TestEventSink.keyUps) == [A, S] && !TestEventSink.keyUps.contains(W),
          "keyUps=\(TestEventSink.keyUps.sorted())")
    TestEventSink.reset()
    // 让位期间 tick 门控：releaseAIHeldKeys 幂等，且 AI 不产生 keyDown
    e.releaseAIHeldKeys(preserving: physical)
    check("E1c 让位期间零 AI keyDown / 零重复 keyUp", TestEventSink.events.isEmpty,
          "\(TestEventSink.events.count)")
    et.noteUserKeyUp()
    check("E1d 松 W → 巡航 15Hz", et.effectiveTickHz == 15 && !et.userHoldingKey
          && !et.takeoverActive && !et.sprinting)
}

// W+A 同按，松 A 后仍让位，松 W 后恢复（通过生产 KeyboardMonitor + 状态机联动）
do {
    resetAll()
    let m = KeyboardMonitor()
    let e = makeEngine()
    hold(e, [W, D])
    let sync = {
        if m.isUserHoldingControlKey { et.noteUserKeyDown() }
        else { et.noteUserKeyUp() }
        e.releaseAIHeldKeys(preserving: m.heldKeys)
    }
    m.onPhysicalKeysChanged = sync
    m.onUserKeyDown = sync
    m.onUserKeyUp = sync
    TestEventSink.reset()
    m.handleEvent(EventFactory.key(.keyDown, keyCode: W))
    m.handleEvent(EventFactory.key(.keyDown, keyCode: A))
    check("E2a W+A 同按 → 让位 5Hz",
          et.userHoldingKey && et.effectiveTickHz == 5 && Set(TestEventSink.keyUps) == [D],
          "keyUps=\(TestEventSink.keyUps)")
    m.handleEvent(EventFactory.key(.keyUp, keyCode: A))
    check("E2b 松 A 仍让位、不恢复", et.userHoldingKey && et.effectiveTickHz == 5)
    m.handleEvent(EventFactory.key(.keyUp, keyCode: W))
    check("E2c 松 W 恢复巡航 15Hz", !et.userHoldingKey && et.effectiveTickHz == 15)
}

// Shift 单独按下可记录但不接管（与 KeyboardMonitor + 状态机联动）
do {
    resetAll()
    let m = KeyboardMonitor()
    m.onPhysicalKeysChanged = {
        if m.isUserHoldingControlKey { et.noteUserKeyDown() } else { et.noteUserKeyUp() }
    }
    m.handleEvent(EventFactory.key(.flagsChanged, keyCode: SHIFT, flags: .shift))
    check("E3 Shift 单独按下可记录但不接管", m.isHeld(SHIFT)
          && !m.isUserHoldingControlKey && !et.userHoldingKey && et.effectiveTickHz == 15)
}

// ══════════════════════════════════════════════════════════════════════════════
print("\n=== F. 跨进程消息解析（生产 EngineMain 的 config 解析表达式）===")

do {
    // 从 EngineMain.swift 原样抽出的解析语句，用 JSONSerialization 驱动
    func parse(_ json: String) -> (obj: [String: Any], keys: Set<CGKeyCode>?, takeover: Bool?) {
        let o = (try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!)) as! [String: Any]
        let keys = (o["physicalKeys"] as? [Int]).map { Set($0.compactMap { CGKeyCode(exactly: $0) }) }
        return (o, keys, o["takeover"] as? Bool)
    }
    let good = parse("{\"physicalKeys\":[13,0],\"takeover\":true,\"keyMask\":3}")
    check("F1 正常快照 + takeover 同包解析", good.keys == [W, A] && good.takeover == true)
    let empty = parse("{\"physicalKeys\":[],\"takeover\":false}")
    check("F2 空集合解析", empty.keys == [] && empty.takeover == false)
    let bad = parse("{\"physicalKeys\":[13,70000,-1],\"takeover\":false}")
    check("F3 越界键码被过滤", bad.keys == [W], "keys=\(String(describing: bad.keys))")
    let missing = parse("{\"takeover\":false}")
    check("F4 字段缺失不崩溃、保持旧状态", missing.keys == nil && missing.takeover == false)
    for badType in ["{\"physicalKeys\":[\"13\"]}", "{\"physicalKeys\":13}", "{\"takeover\":\"true\"}"] {
        let r = parse(badType)
        check("F5 类型错误 \(badType) 不崩溃", r.keys == nil && r.takeover == nil)
    }
    // 应用顺序：先 keys 后 takeover；快照已就绪时 takeover 立即释放 AI 独占键
    resetAll()
    let e = makeEngine()
    hold(e, [W, A])
    TestEventSink.reset()
    var remote: Set<CGKeyCode> = []
    let msg = parse("{\"physicalKeys\":[13],\"takeover\":true}")
    if let keys = msg.keys { remote = keys }            // ① 先应用快照
    if msg.takeover == true {                           // ② 再处理 takeover
        et.noteUserKeyDown()
        e.releaseAIHeldKeys(preserving: remote)
    }
    check("F6 快照先于 takeover：只释放 A，无 W keyUp",
          TestEventSink.keyUps == [A] && et.effectiveTickHz == 5,
          "keyUps=\(TestEventSink.keyUps)")
}

// ══════════════════════════════════════════════════════════════════════════════
print("\n════════════════════════════════════════════════════════")
print(failures == 0 ? "全部通过（\(checks) checks）" : "失败 \(failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
