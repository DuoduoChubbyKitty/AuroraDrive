#!/usr/bin/env python3
"""把生产源码逐字复制到隔离构建目录，只替换系统边界（不重写业务逻辑）。

替换点（全部是外部 I/O 或时钟，不是控制逻辑）：
  ControlEngine  : CGEvent.post -> 内存记录器；TCC 查询 -> 固定已授权
  KeyboardMonitor: NSEvent.addGlobal/LocalMonitor -> 内存 monitor 注册表
                    CGPreflight/RequestListenEventAccess -> TestPermission
                    ProcessInfo --engine 判定 -> TestPermission.isEngineProcess
                    private handle* -> internal（便于直接注入模拟 NSEvent）
  EmergencyTakeover: Date() -> 可控时钟 TestClock.now
  AuroraFlags    : 逐字复制（ControlEngine 依赖）
"""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Sources" / "AuroraDrive"
OUT = Path(__file__).resolve().parent / "build"
OUT.mkdir(exist_ok=True)


def sub(path: Path, pairs) -> str:
    text = path.read_text()
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"替换锚点不存在于 {path.name}: {old[:90]!r}")
        text = text.replace(old, new)
    return text


# ---- ControlEngine：唯一的事件出口换成内存记录器 ----
ce = sub(SRC / "Control" / "ControlEngine.swift", [
    ("private(set) var hasAccessibilityPermission = false",
     "var hasAccessibilityPermission = true  // [TEST] 隔离测试固定已授权"),
    ("        event.post(tap: .cghidEventTap)\n        postedEventCount &+= 1",
     "        TestEventSink.record(keyCode: keyCode, keyDown: keyDown, tag: event.getIntegerValueField(.eventSourceUserData))\n        postedEventCount &+= 1"),
    ("        down.post(tap: .cghidEventTap)\n        up.post(tap: .cghidEventTap)\n        postedEventCount &+= 2",
     "        TestEventSink.record(keyCode: 0, keyDown: true, tag: down.getIntegerValueField(.eventSourceUserData))\n        TestEventSink.record(keyCode: 0, keyDown: false, tag: up.getIntegerValueField(.eventSourceUserData))\n        postedEventCount &+= 2"),
    # digest 短路会让事件到不了内存记录器；改成永不短路（出口已替换，零真实投递）
    ("        if digestMode {\n            digestedEventCount &+= 1\n            return\n        }",
     "        if false {  // [TEST] 出口已替换为内存记录器\n            digestedEventCount &+= 1\n            return\n        }"),
    ("        if digestMode {\n            digestedEventCount &+= 2\n            return\n        }",
     "        if false {  // [TEST] 出口已替换为内存记录器\n            digestedEventCount &+= 2\n            return\n        }"),
])
# 安全断言：源码副本里不得残留任何真实 CGEvent.post 语句
assert "event.post(tap: .cghidEventTap)" not in ce
assert "down.post(tap: .cghidEventTap)" not in ce
assert "up.post(tap: .cghidEventTap)" not in ce
(OUT / "ControlEngine.swift").write_text(ce)

# ---- KeyboardMonitor：监听注册 / 权限 / 进程身份换成内存双 ----
km = sub(SRC / "Control" / "KeyboardMonitor.swift", [
    ("    private func handleEvent(_ event: NSEvent)", "    func handleEvent(_ event: NSEvent)"),
    ("    private func handleKeyDown(keyCode: CGKeyCode)", "    func handleKeyDown(keyCode: CGKeyCode)"),
    ("    private func handleKeyUp(keyCode: CGKeyCode)", "    func handleKeyUp(keyCode: CGKeyCode)"),
    ("    private func handleModifierFlags(_ event: NSEvent)", "    func handleModifierFlags(_ event: NSEvent)"),
    ("        hasInputMonitoringPermission = CGPreflightListenEventAccess()",
     "        hasInputMonitoringPermission = TestPermission.granted"),
    ("            _ = CGRequestListenEventAccess()",
     "            TestPermission.requestCount += 1"),
    ("        guard !ProcessInfo.processInfo.arguments.contains(\"--engine\") else { return false }",
     "        guard !TestPermission.isEngineProcess else { return false }"),
    ("NSEvent.addGlobalMonitorForEvents(matching:", "TestMonitors.addGlobal(matching:"),
    ("NSEvent.addLocalMonitorForEvents(matching:", "TestMonitors.addLocal(matching:"),
    ("NSEvent.removeMonitor(monitor)", "TestMonitors.remove(monitor)"),
])
(OUT / "KeyboardMonitor.swift").write_text(km)

# ---- EmergencyTakeover：可控时间 ----
et = sub(SRC / "Agent" / "EmergencyTakeover.swift", [
    ("@MainActor\n@Observable", "@Observable  // [TEST] 去掉 MainActor 隔离，测试在单线程同步调用"),
    ("    static let shared = EmergencyTakeover()",
     "    static let shared = EmergencyTakeover()\n    /// [TEST] 可控时钟；nil 时走真实时间\n    static var testNow: Date?"),
    ("        sprintStart = Date()", "        sprintStart = Self.testNow ?? Date()"),
    ("               Date().timeIntervalSince(start) >= Self.sprintMaxSeconds {",
     "               (Self.testNow ?? Date()).timeIntervalSince(start) >= Self.sprintMaxSeconds {"),
])
(OUT / "EmergencyTakeover.swift").write_text(et)

# ---- 依赖：逐字复制 ----
shutil.copy(SRC / "Core" / "AuroraFlags.swift", OUT / "AuroraFlags.swift")

print("harness files:", ", ".join(p.name for p in sorted(OUT.glob("*.swift"))))
