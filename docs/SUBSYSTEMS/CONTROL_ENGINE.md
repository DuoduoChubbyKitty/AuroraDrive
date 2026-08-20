# ControlEngine 子系统文档

> **文件**: `src/AuroraDrive/ControlEngine.swift`  
> **版本**: v2.4.1  
> **最后更新**: 2026-08-21

---

## 1. 职责概述

ControlEngine 是 AuroraDrive 的**执行层**，通过 CGEvent 向系统注入键盘事件，控制游戏角色移动。它是整个系统的"手"，将决策层的控制量转化为实际的游戏操作。

**关键设计目标**:
- 精确映射：语义动作（转向/油门/刹车）到具体键码
- 防游戏忽略：使用 .hidSystemState 确保游戏能识别
- 持续按住：支持 hold 模式，自动重复发送按下事件

---

## 2. 按键映射

### 2.1 默认映射

```swift
struct KeyMap {
    var throttle:    CGKeyCode = 13   // W - 前进
    var brake:       CGKeyCode = 1    // S - 后退/刹车
    var steerLeft:   CGKeyCode = 0    // A - 左转
    var steerRight:  CGKeyCode = 2    // D - 右转
    var handbrake:   CGKeyCode = 49   // 空格 - 手刹
    var boost:       CGKeyCode = 56   // Left Shift - 加速/闪避
}
```

### 2.2 macOS 键码参考

| 语义动作 | 默认键 | CGKeyCode | 用途 |
|----------|--------|-----------|------|
| `throttle` | W | 13 | 前进油门 |
| `brake` | S | 1 | 后退/刹车 |
| `steerLeft` | A | 0 | 左转 |
| `steerRight` | D | 2 | 右转 |
| `handbrake` | Space | 49 | 手刹/脱困 |
| `boost` | Left Shift | 56 | 极速/闪避 |

**注意**: 键码基于标准 US 键盘布局。使用其他布局时需重新映射。

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable
final class ControlEngine {
    var keyMap = KeyMap()
    private(set) var hasAccessibilityPermission = false
    private(set) var heldKeys: Set<CGKeyCode> = []
    
    // CGEventSource 必须用 .hidSystemState
    private let eventSource: CGEventSource? = {
        CGEventSource(state: .hidSystemState)
    }()
    
    init() {
        checkPermissions()
    }
}
```

### 3.2 权限检查

```swift
/// 检查辅助功能权限（AXIsProcessTrustedWithOptions）
func checkPermissions() -> Bool {
    let options: [CFString: Any] = [
        kAXTrustedCheckOptionPrompt as CFString: true  // 无权限时弹出授权对话框
    ]
    hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options as CFDictionary)
    
    if !hasAccessibilityPermission {
        print("[Control] 缺少辅助功能权限，请在系统设置中授权")
    }
    return hasAccessibilityPermission
}
```

**权限说明**:
- **屏幕录制权限**: CaptureEngine 需要，用于获取游戏画面
- **辅助功能权限**: ControlEngine 需要，用于注入键盘事件
- 两者缺一不可，否则应用无法正常工作

### 3.3 按键注入

```swift
/// 按下并立即释放（单次按键）
func press(_ action: Action) {
    guard hasAccessibilityPermission else { return }
    
    let keyCode = keyMap.keyCode(for: action)
    
    // 1. 按下事件
    if let event = CGEvent(keyboardEventSource: eventSource,
                           virtualKey: keyCode,
                           keyDown: true) {
        event?.post(tap: .cghidEventTap)
    }
    
    // 2. 释放事件
    if let event = CGEvent(keyboardEventSource: eventSource,
                           virtualKey: keyCode,
                           keyDown: false) {
        event?.post(tap: .cghidEventTap)
    }
    
    postedEventCount += 2
}

/// 持续按住（需配合 release 使用）
func hold(_ action: Action) {
    guard hasAccessibilityPermission, !heldKeys.contains(keyMap.keyCode(for: action)) else {
        return
    }
    
    let keyCode = keyMap.keyCode(for: action)
    heldKeys.insert(keyCode)
    
    // 按下事件
    if let event = CGEvent(keyboardEventSource: eventSource,
                           virtualKey: keyCode,
                           keyDown: true) {
        event?.post(tap: .cghidEventTap)
    }
    
    postedEventCount += 1
    
    // 启动自动重复（每 100ms 重新发送按下事件）
    startAutoRepeat(keyCode: keyCode)
}

/// 释放指定键
func release(_ action: Action) {
    guard hasAccessibilityPermission else { return }
    
    let keyCode = keyMap.keyCode(for: action)
    heldKeys.remove(keyCode)
    
    // 释放事件
    if let event = CGEvent(keyboardEventSource: eventSource,
                           virtualKey: keyCode,
                           keyDown: false) {
        event?.post(tap: .cghidEventTap)
    }
    
    stopAutoRepeat(keyCode: keyCode)
    postedEventCount += 1
}
```

### 3.4 自动重复机制

```swift
/// 自动重复按下事件，防止游戏忽略长按
private var autoRepeatTimers: [CGKeyCode: Timer] = [:]

private func startAutoRepeat(keyCode: CGKeyCode) {
    // 每 100ms 重新发送按下事件
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self = self, self.hasAccessibilityPermission else { return }
        
        if let event = CGEvent(keyboardEventSource: self.eventSource,
                               virtualKey: keyCode,
                               keyDown: true) {
            event?.post(tap: .cghidEventTap)
            self.postedEventCount += 1
        }
    }
    autoRepeatTimers[keyCode] = timer
}

private func stopAutoRepeat(keyCode: CGKeyCode) {
    autoRepeatTimers.removeValue(forKey: keyCode)?.invalidate()
}
```

**为什么需要自动重复**:
- 某些游戏（包括异环）会忽略单次 CGEvent 的长按
- 必须每 100ms 重新发送按下事件，游戏才能识别为"持续按住"
- 释放时必须同步发送释放事件，否则按键会卡住

---

## 4. 控制量转换

### 4.1 连续量 → 离散键

```swift
/// 根据连续控制量生成按键组合
func apply(_ steer: Double, _ throttle: Double, _ brake: Double) {
    // 1. 转向处理
    if steer < -0.1 {
        hold(.steerLeft)
    } else if steer > 0.1 {
        hold(.steerRight)
    } else {
        release(.steerLeft)
        release(.steerRight)
    }
    
    // 2. 油门处理
    if throttle > 0.1 {
        hold(.throttle)
    } else {
        release(.throttle)
    }
    
    // 3. 刹车处理
    if brake > 0.1 {
        hold(.brake)
    } else {
        release(.brake)
    }
}

/// 完全停止（释放所有键）
func stopAll() {
    release(.steerLeft)
    release(.steerRight)
    release(.throttle)
    release(.brake)
}
```

### 4.2 边界处理

```swift
/// 防止控制量溢出
private func clamp(_ value: Double, min: Double, max: Double) -> Double {
    return max(min, min(max, value))
}

/// 转向量映射（考虑死区）
private func mapSteer(_ steer: Double) -> Action? {
    let deadZone = 0.1  // 中心死区，防止微小抖动
    if steer < -deadZone { return .steerLeft }
    if steer > deadZone { return .steerRight }
    return nil
}
```

---

## 5. UI 集成

### 5.1 键盘可视化

```swift
/// 键盘状态可视化条（SwiftUI 观察此属性）
var keyboardBar: some View {
    HStack(spacing: 8) {
        KeyCaps(actions: [.steerLeft, .throttle, .steerRight, .brake],
                heldKeys: $controlEngine.heldKeys)
    }
}

struct KeyCaps: View {
    let actions: [Action]
    @Binding var heldKeys: Set<CGKeyCode>
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(actions, id: \.self) { action in
                KeyCap(keyMap: keyMap, action: action, heldKeys: heldKeys)
            }
        }
    }
}

struct KeyCap: View {
    let keyMap: ControlEngine.KeyMap
    let action: Action
    @Environment(\.heldKeys) var heldKeys
    
    var isPressed: Bool {
        heldKeys.contains(keyMap.keyCode(for: action))
    }
    
    var body: some View {
        Text(keyFor(action))
            .font(.title2)
            .foregroundColor(isPressed ? .black : .white)
            .background(isPressed ? Color.cyan : Color.gray.opacity(0.3))
            .cornerRadius(4)
            .padding(4)
    }
}
```

### 5.2 观察标记

```swift
// 累计事件计数标 @ObservationIgnored，避免触发 SwiftUI 重绘
@ObservationIgnored private(set) var postedEventCount: Int = 0
```

---

## 6. 调试工具

### 6.1 按键测试

```swift
/// 测试单个按键（通过 UI 按钮触发）
func testKey(_ action: Action) {
    press(action)
    Thread.sleep(forTimeInterval: 0.1)
    release(action)
}

/// 测试连续控制
func testContinuous() {
    for angle in stride(from: -1.0, to: 1.0, by: 0.1) {
        apply(steer: angle, throttle: 0.5, brake: 0)
        Thread.sleep(forTimeInterval: 0.05)
    }
    stopAll()
}
```

### 6.2 事件日志

```swift
/// 打印最近的按键事件（诊断用）
func printRecentEvents() {
    print("[Control] 已发送 \(postedEventCount) 个事件")
    print("[Control] 当前按住: \(heldKeys.map { CGKeyCode($0) })")
}
```

---

## 7. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `autoRepeatInterval` | 0.1s | 自动重复间隔 |
| `steerDeadZone` | 0.1 | 转向死区（防止抖动） |
| `throttleMin` | 0.1 | 最小油门阈值 |
| `brakeMin` | 0.1 | 最小刹车阈值 |

---

## 8. 常见问题

### Q1: 游戏没有响应按键？

检查项:
1. 辅助功能权限是否授予（系统设置 → 隐私与安全性 → 辅助功能）
2. 游戏是否在前台运行
3. 是否使用了错误的 CGEventSource 状态（必须用 `.hidSystemState`）

### Q2: 按键卡住（持续按住不放）？

原因: 应用崩溃前未释放所有键。  
解决: 重启应用，或手动按对应物理键释放。

### Q3: 转向不灵敏？

调整死区：
```swift
// 减小死区（更灵敏，可能抖动）
controlEngine.steerDeadZone = 0.05

// 增大死区（更稳定，可能迟钝）
controlEngine.steerDeadZone = 0.2
```

---

## 导航链接

| 方向 | 链接 | 说明 |
|------|------|------|
| ⬆️ 回到上级 | [DEVELOPER.md](../DEVELOPER.md) | 二级开发者文档（引擎总览） |
| ⬆️ 回到首页 | [README.md](../../README.md) | 一级项目简介 |
| 🔙 返回列表 | [SUBSYSTEMS/](./) | 所有子系统文档 |

---

## 开源声明与致谢

**GNU GPL v3.0**  
Copyright © 2026 DuoduoChubbyKitty

依赖组件:
- Apple CoreGraphics (CGEvent)
- Apple ApplicationKit (NSApplication)
- Accessibility.framework (权限检查)

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
