// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 隔离测试的系统边界替身。生产源码逐字复制，只把下面 5 个外部 I/O 换成内存实现：
//   CGEvent.post / TCC 查询与申请 / NSEvent 监听注册 / 进程身份 / Date()
// 绝不重写任何控制逻辑。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 事件出口（替换 CGEvent.post）

struct TestEvent {
    let key: CGKeyCode
    let down: Bool
    let tag: Int64
}

enum TestEventSink {
    static var events: [TestEvent] = []
    static func record(keyCode: CGKeyCode, keyDown: Bool, tag: Int64) {
        events.append(TestEvent(key: keyCode, down: keyDown, tag: tag))
    }
    static func reset() { events.removeAll() }
    static var keyUps: [CGKeyCode] { events.filter { !$0.down }.map(\.key) }
    static var keyDowns: [CGKeyCode] { events.filter { $0.down }.map(\.key) }
}

// MARK: - 权限 / 进程身份替身

enum TestPermission {
    static var granted = true
    static var requestCount = 0
    static var isEngineProcess = false
    static func reset() {
        granted = true
        requestCount = 0
        isEngineProcess = false
    }
}

// MARK: - NSEvent 监听注册替身

final class TestMonitorHandle: NSObject {
    let mask: NSEvent.EventTypeMask
    let global: ((NSEvent) -> Void)?
    let local: ((NSEvent) -> NSEvent?)?
    init(mask: NSEvent.EventTypeMask, global: ((NSEvent) -> Void)? = nil,
         local: ((NSEvent) -> NSEvent?)? = nil) {
        self.mask = mask
        self.global = global
        self.local = local
    }
}

enum TestMonitors {
    static var handles: [TestMonitorHandle] = []
    static var removeCount = 0
    /// 设为 N 时，第 N 次 addGlobal 返回 nil（模拟部分注册失败）
    static var failGlobalOnCall: Int?
    static var failLocalOnCall: Int?
    private static var globalCalls = 0
    private static var localCalls = 0

    static func addGlobal(matching mask: NSEvent.EventTypeMask,
                          handler: @escaping (NSEvent) -> Void) -> Any? {
        globalCalls += 1
        if failGlobalOnCall == globalCalls { return nil }
        let h = TestMonitorHandle(mask: mask, global: handler)
        handles.append(h)
        return h
    }

    static func addLocal(matching mask: NSEvent.EventTypeMask,
                         handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        localCalls += 1
        if failLocalOnCall == localCalls { return nil }
        let h = TestMonitorHandle(mask: mask, local: handler)
        handles.append(h)
        return h
    }

    static func remove(_ monitor: Any) {
        removeCount += 1
        guard let h = monitor as? TestMonitorHandle else { return }
        handles.removeAll { $0 === h }
    }

    /// 把模拟事件投递给所有匹配的监听（模拟系统事件到达）。
    static func fire(_ event: NSEvent) {
        for h in handles {
            guard h.mask.contains(NSEvent.EventTypeMask(rawValue: 1 << UInt(event.type.rawValue)))
                    || matches(h.mask, event.type) else { continue }
            if let g = h.global { g(event) }
            if let l = h.local { _ = l(event) }
        }
    }

    private static func matches(_ mask: NSEvent.EventTypeMask, _ t: NSEvent.EventType) -> Bool {
        switch t {
        case .keyDown: return mask.contains(.keyDown)
        case .keyUp: return mask.contains(.keyUp)
        case .flagsChanged: return mask.contains(.flagsChanged)
        default: return false
        }
    }

    static func reset() {
        handles.removeAll()
        removeCount = 0
        failGlobalOnCall = nil
        failLocalOnCall = nil
        globalCalls = 0
        localCalls = 0
    }
}

// MARK: - 模拟 NSEvent（内存对象，不进入系统事件队列）

enum EventFactory {
    static func key(_ type: NSEvent.EventType,
                    keyCode: CGKeyCode,
                    isARepeat: Bool = false,
                    tag: Int64 = 0,
                    flags: NSEvent.ModifierFlags = []) -> NSEvent {
        // 统一用「同一个 CGEvent 包装成 NSEvent」：NSEvent.keyEvent(with:)
        // 每次访问 .cgEvent 会返回新对象，无法在 flagsChanged 上稳定附加自产标记。
        let cgType: CGEventType = type == .keyDown ? .keyDown
            : type == .keyUp ? .keyUp : .flagsChanged
        let cg = CGEvent(keyboardEventSource: nil, virtualKey: keyCode,
                         keyDown: type == .keyDown)!
        cg.type = cgType
        if type == .flagsChanged {
            var cgFlags: CGEventFlags = []
            if flags.contains(.shift) { cgFlags.insert(.maskShift) }
            if flags.contains(.control) { cgFlags.insert(.maskControl) }
            if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
            if flags.contains(.command) { cgFlags.insert(.maskCommand) }
            cg.flags = cgFlags
        }
        if isARepeat { cg.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if tag != 0 { cg.setIntegerValueField(.eventSourceUserData, value: tag) }
        return NSEvent(cgEvent: cg)!
    }
}
