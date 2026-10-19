# 代码-10 KeyboardMonitor 键盘监视与打标签
> 覆盖源文件：`Sources/AuroraDrive/Control/KeyboardMonitor.swift`（**166 行**，2026-10-18 `wc -l` 实测）。基于当前仓库逐单元编写。

> ♻️ **行号已按 9097 行版重基准（2026-10-18，sys-reader）**：检查 **6 条**跨文件引用（`AuroraDriveApp.swift` 2 + `EngineMain.swift` 4），**全部准确、修正 0 条**：
>
> | 引用 | 行号 | 实测 |
> |---|---|---|
> | `keyboardMonitor.onUserKeyDown` 接线 | `AuroraDriveApp.swift:6277-6281` | ✅ `:6277` onUserKeyDown `{` / `:6280` onUserKeyUp `{` / `:6281` `takeover: false` —— 逐行命中 |
> | ET-4 接线段（§三标题引用） | `AuroraDriveApp.swift:6277-6281` | ✅ 同上 |
> | `cTakeover` 解析 | `EngineMain.swift:1710` | ✅ `let cTakeover = obj["takeover"] as? Bool` |
> | `noteUserKeyDown()` 调用 | `EngineMain.swift:1754` | ✅ 逐行命中 |
> | ET-5 语义注释段 | `EngineMain.swift:1705-1707` | ✅ `:1705` takeover=true 语义 / `:1706` takeover=false / `:1707` 状态守卫说明 |
>
> ⚠️ **本轮发现 1 处本文内部锚点小瑕疵（非跨文件）**：本文 §一 写「`:32-43` 的 `onUserKeyDown`/`onUserKeyUp`」——`:32` 实际是 `// MARK: - 用户按键回调（ET-2 · 应急接管用）` 标记行，**`onUserKeyDown` 声明在 `:40`**（`:43` 是 `onUserKeyUp`，这两条是对的）。`:32-43` 作为「区块范围」描述可接受，但精确到符号应写 `:40`/`:43`。
>
> ✅ 其余内部锚点逐条核对无误：`:52` controlledKeyCodes / `:93` addGlobalMonitorForEvents / `:128` onUserKeyDown 短路调用 / `:138` onUserKeyUp 短路调用。
>
> **✅ 2026-10-18 复核（T6）**：逐条 `read` 源码核对。两处实质修正（一处推翻原文档结论）：
> 1. 🔴 **原文档称「仅供显示，不是急停」——该结论已不成立**。本类现有 **ET-2 应急接管回调链**（:32-43 的 `onUserKeyDown`/`onUserKeyUp` + :52-73 的 `controlledKeyCodes` 38 个受控键 + :128/:138 的短路调用）。接线在 `AuroraDriveApp.swift:6277-6281`（ET-4，2026-10-12）：用户按下受控键 → UI 进程经 socket 发 `config` 命令（`takeover: true/false`）→ 引擎侧 `EngineMain.swift:1754` 的 `EmergencyTakeover.shared.noteUserKeyDown()` → 冲刺态（5Hz）把算力让给用户。即**物理按键当前就是「让位/回巡航」的触发源**，不只是显示。详见下文 §三。
> 2. **行数 113 → 166**（源文件新增 ET-2/ET-4 回调链 + 受控键镜像表，+53 行）；§一区间「第 1–117 行」→ **第 1–117 行**（`start()`/`stop()` 止于 :117，此段仍正确），但**§一漏了整个 :32-73 的回调与受控键块**，已补为独立小节；§二起点 119 行仍正确。

## 一、监视器、auto-repeat 过滤与启停（第 1–117 行）

**定位（4–9 行头注释）**：物理键盘全局监听——用 `NSEvent.addGlobalMonitorForEvents` 监听**系统级**键盘按下/释放，实时反映用户物理键盘状态，供 KeyboardBar 显示。**注意：全局监听需要辅助功能权限（与 ControlEngine 共用）**。

**类声明（第 18–19 行）**：`@Observable final class KeyboardMonitor`——监听系统级 keyDown / keyUp 事件（**即使 app 不在前台也能收到**），实时更新 heldKeys 供 KeyboardBar 显示真实按键状态。

**状态字段（第 21–30 行、第 75–77 行）：**

| 成员 | 行号 | 说明 |
|---|---|---|
| `heldKeys: Set<CGKeyCode>`（private(set)） | :23 | 当前**物理**按住的键码集合——KeyboardBar 观察此属性，实时高亮 |
| `keyDownTimes: [CGKeyCode: Date]`（**@ObservationIgnored**） | :29-30 | 受控键最近一次 keyDown 的时间戳（按住起点）；keyUp / stop / clearAll 时同步移除；用于把"按住时长"换算成**连续控制标签（录制端专家模式）**。@ObservationIgnored：纯内部计时数据，无 UI 观察（KeyboardBar 只读 heldKeys） |
| `keyDownMonitor / keyUpMonitor: Any?` | :76-77 | 全局监听句柄（启动时保存，停止时移除） |

**`start()`（第 84–103 行）**——启动全局键盘监听：

1. `guard keyDownMonitor == nil else { return }`（:85，幂等）
2. **监听 keyDown（93–96 行）**：`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`，**`guard !event.isARepeat else { return }` 过滤 auto-repeat**（:94）——为什么（89–92 行注释）：物理键持续按住时，系统在 ~0.5s 后会以 ~50ms 周期派发带 autorepeat 标记的 keyDown；**若不过滤，handleKeyDown 每次都会重置 keyDownTimes 时间戳 → holdDuration 永远只有 ~50ms，比例标签无法达到满刻度，按键时长功能失效**
3. **监听 keyUp（100–102 行）**：`NSEvent.addGlobalMonitorForEvents(matching: .keyUp)` → `handleKeyUp`

**`stop()`（第 106–117 行）**：两个 monitor 都 `NSEvent.removeMonitor`（:108/:112）+ 置 nil；`heldKeys.removeAll()`（:115）+ `keyDownTimes.removeAll()`（:116）——**停监听同时清状态**（防残留卡键显示）。

**线程约定**（155 行注释）：holdDuration 与 heldKeys 同一线程模型访问（监听回调线程），按现有主线程约定使用即可。

## 二、事件处理与状态查询（第 119–165 行）

## 一之补、ET-2 应急接管回调链（第 32–73 行）—— **不是「仅供显示」**

🔴 **原文档结论「仅供显示，不是急停」已不成立**。源文件现有完整的应急接管回调链：

**两个回调（第 32–43 行）**：

| 成员 | 行号 | 说明 |
|---|---|---|
| `onUserKeyDown: (() -> Void)?` | :40 | 用户真实按下**受控键**（W/A/S/D/空格等驾驶键）时回调。**平时为 nil**（省资源） |
| `onUserKeyUp: (() -> Void)?` | :43 | 用户松开受控键时回调 |

**零开销设计**（:37-39 注释）：nil 时 `handleKeyDown` 只做一次 `if let` 即返回，**不查受控键集合**（短路顺序：先判 nil，再判集合）——平时（非接管态）零额外成本。

**`controlledKeyCodes`（private static，第 52–73 行）——38 个受控键**：

```swift
private static let controlledKeyCodes: Set<CGKeyCode> = [
    13, 0, 1, 2,          // 移动 W/A/S/D
    3, 14, 49,            // 交互 F/E/Space
    53, 12, 15, 46, 11, 17,   // UI：ESC/Q/R/M/B/T
    122, 120, 118,        // 功能热键 F1/F2/F4
    56, 59,               // 修饰 Shift/Ctrl
    18, 19, 20, 21, 23, 22, 26,  // 数字 1-7
    38, 40, 37,           // 俄罗斯方块/节奏 J/K/L
    6, 7, 8, 9, 45,       // 钢琴低音 Z/X/C/V/N
    5, 4, 34,             // 钢琴中音 G/H/I
    16, 32,               // 钢琴高音 Y/U
]
```

⚠️ **必须与 `ControlEngine.gameKeyToKeyCode`（ControlEngine.swift:624-641）保持一致**（:47-51 注释）：那张表是 `private static`，本类访问不到，故在此**镜像一份**。若 ControlEngine 新增 GameKey，**必须同步加到这里**（否则新键的接管回调失效）。

**调用点**（短路顺序同上，先判 nil 再查集合）：

- `handleKeyDown`（:128-130）：`if let onUserKeyDown, Self.controlledKeyCodes.contains(keyCode) { onUserKeyDown() }`
- `handleKeyUp`（:138-140）：`if let onUserKeyUp, Self.controlledKeyCodes.contains(keyCode) { onUserKeyUp() }`

### ET-4 跨进程接线（2026-10-12，`AuroraDriveApp.swift:6277-6281`）

```
UI 进程：KeyboardMonitor.onUserKeyDown = { EngineClient.shared.sendCommand("config", extra: ["takeover": true]) }
         KeyboardMonitor.onUserKeyUp   = { EngineClient.shared.sendCommand("config", extra: ["takeover": false]) }
   ↓ socket
引擎进程：EngineMain.swift:1710 解析 cTakeover
          EngineMain.swift:1754 EmergencyTakeover.shared.noteUserKeyDown()
          （引擎侧内部有状态守卫：只在 sprinting 冲刺态生效）
```

**语义**（EngineMain.swift:1705-1707 注释）：`takeover=true` = 用户按下受控键 → 让位（5Hz，把算力让给用户）；`takeover=false` = 用户松开 → 回巡航（20Hz）。

**跨进程架构原因**（:6266-6270 注释）：KeyboardMonitor 只在 **UI 进程**（引擎进程是后台无 GUI，收不到 NSEvent）；而真正注入按键、需要"让位"的是引擎进程。故 UI 监听按键 → socket config → 引擎设 takeover 状态。

**为什么不门控 `takeoverActive`**（:6272-6276 注释，Lead 裁决）：回调是轻量的（发一条 socket JSON），且引擎侧 `noteUserKeyDown` 只在 sprinting 状态才生效，平时无害；加门控反而要跨进程同步 `takeoverActive`（复杂且有时序 gap）。⚠️ **注意**：这意味着**只要在开车中，用户按任何受控键都会发 socket 命令**（哪怕当前不是冲刺态）。

## 二、事件处理与状态查询（第 119–165 行）

**事件处理（第 122–141 行）**：

```swift
private func handleKeyDown(keyCode: CGKeyCode) {
    heldKeys.insert(keyCode)
    keyDownTimes[keyCode] = Date()      // 记录按住起点
    // ET-2：用户真实按下受控键 → 回调应急接管。
    // 短路顺序：先判闭包 nil（零开销），再查受控键集合（O(1) Set）。
    if let onUserKeyDown, Self.controlledKeyCodes.contains(keyCode) {
        onUserKeyDown()
    }
}

private func handleKeyUp(keyCode: CGKeyCode) {
    heldKeys.remove(keyCode)
    keyDownTimes.removeValue(forKey: keyCode)   // 清除时间戳
    // ET-2：松开同理（短路顺序同上）
    if let onUserKeyUp, Self.controlledKeyCodes.contains(keyCode) {
        onUserKeyUp()
    }
}
```

- 按下：加入 heldKeys + 记录按住起点时间戳（+ 受控键则触发接管回调）
- 释放：从 heldKeys 移除 + 清除时间戳（**两者必须同步**，否则 holdDuration 会把已释放的键算出超长时长）（+ 受控键则触发松开回调）

**状态查询（第 145–159 行）：**

| 方法 | 行号 | 签名 | 说明 |
|---|---|---|---|
| `isHeld` | :148-150 | `(_ keyCode: CGKeyCode) -> Bool` | 某个键是否正在**物理**按住（查 heldKeys） |
| `holdDuration` | :156-159 | `(keyCode: CGKeyCode) -> TimeInterval` | 某个键当前已连续按住的时长（秒）；**未按住或从未记录返回 0**。`guard let down = keyDownTimes[keyCode] else { return 0 }`（:157）+ `Date().timeIntervalSince(down)`（:158） |

**`clearAll()`（第 161–165 行）**：清空所有按键状态（**失去焦点时调用，避免按键卡住**，:161 注释）——heldKeys（:163）+ keyDownTimes（:164）都清。

**与 ControlEngine 的关系**（一个监视一个注入，方向相反）：

- KeyboardMonitor 读**物理键盘**（用户手）→ `heldKeys`（KeyboardBar 显示 + 录制标签 + ET-2 接管回调）
- ControlEngine 写**合成键盘**（AI 手）→ 自己的 `heldKeys`（键盘可视化条）
- 两个类各自维护 heldKeys，**互不混用**——KeyboardBar 若要显示"全部按键"，需要合并两处状态（当前实现分别显示）
- 全局监听与注入共用辅助功能权限（一个 TCC 授权管两个）
- **⚠️ 受控键码双份维护**：`KeyboardMonitor.controlledKeyCodes`（:52-73，38 个）与 `ControlEngine.gameKeyToKeyCode`（:624-641）是两份镜像——改一处必须同步另一处，否则新键的接管回调静默失效

**holdDuration 的下游用途**：录制端专家模式（expertMode）把"按住时长"换算成连续控制标签——holdDuration 越长，标签越接近满刻度（配合 auto-repeat 过滤才有效，见单元一）。

**KeyboardMonitor 文档至此完整**（166 行全覆盖：监视器启停 → ET-2 接管回调链 + 38 受控键 → 事件处理 → 状态查询）。