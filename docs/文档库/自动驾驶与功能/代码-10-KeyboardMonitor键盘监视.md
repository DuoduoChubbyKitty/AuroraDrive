# 代码-10 KeyboardMonitor 键盘监视与打标签

> 覆盖源文件：`Sources/AuroraDrive/Control/KeyboardMonitor.swift`（113 行）。基于当前仓库逐单元编写。

## 一、监视器、auto-repeat 过滤与启停（第 1–74 行）

**定位（4–9 行头注释）**：物理键盘全局监听——用 `NSEvent.addGlobalMonitorForEvents` 监听**系统级**键盘按下/释放，实时反映用户物理键盘状态，供 KeyboardBar 显示。**注意：全局监听需要辅助功能权限（与 ControlEngine 共用）**。

**类声明（第 18–19 行）**：`@Observable final class KeyboardMonitor`——监听系统级 keyDown / keyUp 事件（**即使 app 不在前台也能收到**），实时更新 heldKeys 供 KeyboardBar 显示真实按键状态。

**状态字段（第 21–34 行）：**

| 成员 | 说明 |
|---|---|
| `heldKeys: Set<CGKeyCode>`（private(set)） | 当前**物理**按住的键码集合——KeyboardBar 观察此属性，实时高亮 |
| `keyDownTimes: [CGKeyCode: Date]`（**@ObservationIgnored**） | 受控键最近一次 keyDown 的时间戳（按住起点）；keyUp / stop / clearAll 时同步移除；用于把"按住时长"换算成**连续控制标签（录制端专家模式）**。@ObservationIgnored：纯内部计时数据，无 UI 观察（KeyboardBar 只读 heldKeys） |
| `keyDownMonitor / keyUpMonitor: Any?` | 全局监听句柄（启动时保存，停止时移除） |

**`start()`（第 41–60 行）**——启动全局键盘监听：

1. `guard keyDownMonitor == nil else { return }`（幂等）
2. **监听 keyDown（50–53 行）**：`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`，**`guard !event.isARepeat else { return }` 过滤 auto-repeat**——为什么（46–49 行注释）：物理键持续按住时，系统在 ~0.5s 后会以 ~50ms 周期派发带 autorepeat 标记的 keyDown；**若不过滤，handleKeyDown 每次都会重置 keyDownTimes 时间戳 → holdDuration 永远只有 ~50ms，比例标签无法达到满刻度，按键时长功能失效**
3. **监听 keyUp（57–59 行）**：`NSEvent.addGlobalMonitorForEvents(matching: .keyUp)` → `handleKeyUp`

**`stop()`（第 63–74 行）**：两个 monitor 都 `NSEvent.removeMonitor` + 置 nil；`heldKeys.removeAll()` + `keyDownTimes.removeAll()`——**停监听同时清状态**（防残留卡键显示）。

**线程约定**（102 行注释）：holdDuration 与 heldKeys 同一线程模型访问（监听回调线程），按现有主线程约定使用即可。

## 二、事件处理与状态查询（第 76–113 行）

**事件处理（第 79–88 行）**：

```swift
private func handleKeyDown(keyCode: CGKeyCode) {
    heldKeys.insert(keyCode)
    keyDownTimes[keyCode] = Date()      // 记录按住起点
}

private func handleKeyUp(keyCode: CGKeyCode) {
    heldKeys.remove(keyCode)
    keyDownTimes.removeValue(forKey: keyCode)   // 清除时间戳
}
```

- 按下：加入 heldKeys + 记录按住起点时间戳
- 释放：从 heldKeys 移除 + 清除时间戳（**两者必须同步**，否则 holdDuration 会把已释放的键算出超长时长）

**状态查询（第 92–106 行）：**

| 方法 | 签名 | 说明 |
|---|---|---|
| `isHeld` | `(_ keyCode: CGKeyCode) -> Bool` | 某个键是否正在**物理**按住（查 heldKeys） |
| `holdDuration` | `(keyCode: CGKeyCode) -> TimeInterval` | 某个键当前已连续按住的时长（秒）；**未按住或从未记录返回 0**。`guard let down = keyDownTimes[keyCode] else { return 0 }` + `Date().timeIntervalSince(down)` |

**`clearAll()`（第 109–112 行）**：清空所有按键状态（**失去焦点时调用，避免按键卡住**）——heldKeys + keyDownTimes 都清。

**与 ControlEngine 的关系**（一个监视一个注入，方向相反）：

- KeyboardMonitor 读**物理键盘**（用户手）→ `heldKeys`（KeyboardBar 显示）
- ControlEngine 写**合成键盘**（AI 手）→ 自己的 `heldKeys`（键盘可视化条）
- 两个类各自维护 heldKeys，**互不混用**——KeyboardBar 若要显示"全部按键"，需要合并两处状态（当前实现分别显示）
- 全局监听与注入共用辅助功能权限（一个 TCC 授权管两个）

**holdDuration 的下游用途**：录制端专家模式（expertMode）把"按住时长"换算成连续控制标签——holdDuration 越长，标签越接近满刻度（配合 auto-repeat 过滤才有效，见单元一）。

**KeyboardMonitor 文档至此完整**（113 行全覆盖）。