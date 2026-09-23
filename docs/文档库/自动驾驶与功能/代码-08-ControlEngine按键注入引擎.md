# 代码-08 ControlEngine 按键注入引擎

> 覆盖源文件：`Sources/AuroraDrive/Control/ControlEngine.swift`（373 行）。基于当前仓库逐单元编写。

## 一、语义动作、KeyMap 与 HID 事件源（第 1–111 行）

**类声明（第 21–22 行）**：`@Observable final class ControlEngine: @unchecked Sendable`——通过 CGEvent 向系统**全局键盘队列**注入按键事件，控制游戏（WASD + 空格 + Shift）。需要"辅助功能"权限（Accessibility）。@Observable 让 SwiftUI 自动观察按键状态变化（键盘可视化条用）。

**`Action`（enum，第 25–32 行）**——按键动作枚举（**语义化，与具体键位解耦**）：

| case | 语义 |
|---|---|
| `throttle` | 油门（前进） |
| `brake` | 刹车（后退） |
| `steerLeft / steerRight` | 左转 / 右转 |
| `handbrake` | 手刹（空格） |
| `boost` | 极速（Shift） |

**`KeyMap`（struct，第 37–56 行）**——按键映射：语义动作 → macOS 键码。键码参考（HID Usage Table → macOS virtualKey）：**W=13, A=0, S=1, D=2, 空格=49, LeftShift=56, RightShift=60**。

| 字段 | 默认值 | 键 |
|---|---|---|
| `throttle` | 13 | W |
| `brake` | 1 | S |
| `steerLeft` | 0 | A |
| `steerRight` | 2 | D |
| `handbrake` | 49 | 空格 |
| `boost` | 56 | Left Shift |

`func keyCode(for action: Action) -> CGKeyCode`（46–55 行）：switch 语义动作取键码。

- `var keyMap = KeyMap()`（59 行）——当前按键映射，**可运行时修改**

**权限与按键状态（第 62–70 行）**：

- `hasAccessibilityPermission`（private(set)）——是否拥有辅助功能权限
- `heldKeys: Set<CGKeyCode>`（private(set)，@Observable）——当前按住的键集合，键盘可视化条观察此属性；每次按下/释放都更新，SwiftUI 自动刷新键帽颜色
- `postedEventCount: Int`（**@ObservationIgnored**）——累计成功注入的键盘事件总数（诊断用：判断事件流是否持续产生）；标记 @ObservationIgnored 因为每帧递增，不应触发 SwiftUI 重绘

**`eventSource`（lazy 闭包，第 73–84 行）——本引擎最关键的实测结论：**

```swift
private let eventSource: CGEventSource? = {
    return CGEventSource(stateID: .hidSystemState)
}()
```

- **必须用 `.hidSystemState`（对应 C API 的 kCGEventSourceStateHIDSystemState）**：实测目标游戏（异环 NTE）的输入层只读取 HID 系统状态层的键盘事件
- `.combinedSessionState`（曾用）：实测对该游戏无效——该层的合成事件会被系统 UI 正常接收（键盘可视化条会亮、系统提示音会响），**但游戏输入层直接忽略**，表现为「UI 显示已输出 W，但游戏纹丝不动」
- `.privateState`：更私有的状态层，游戏更加读不到，**禁止使用**
- `.hidSystemState`：事件进入 HID 系统状态层，与真实物理键盘同层，配合 `.cghidEventTap` 投递，即为已验证可突破该游戏反作弊拦截的方案

**权限函数（第 88–111 行）**：

- `checkPermission() -> Bool`（90–104 行）：`AXIsProcessTrustedWithOptions(nil)`——**P0 修复 (2026-09-07)**：字符串字面量 `"kAXTrustedCheckOptionPrompt"` 不是有效的 CFString 常量，导致 options 字典无效 → 收到 nil 等价参数 → 访问空指针崩溃（**EXC_BAD_ACCESS at 0x8**）。正确做法是直接传 nil（不弹窗）——首次调用会自动弹系统授权提示，后续调用仅返回当前权限状态
- 无权限时注入事件会被系统**静默丢弃**
- `openAccessibilitySettings()`（107–111 行）：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` URL → `NSWorkspace.shared.open`（引导用户授权）

## 二、按键注入五件套与 refreshHeldKeys（第 113–227 行）

**五个注入方法（语义动作版）：**

| 方法 | 签名 | 行为 |
|---|---|---|
| `press` | `(_ action: Action, duration: TimeInterval = 0.05)` | 按下并立即释放（短按）；`usleep(duration × 1_000_000)` 短暂等待后释放（模拟真实按键时长）；无权限时先 checkPermission 再 return |
| `hold` | `(_ action: Action)` | 持续按住不释放（直到 release/releaseAll）；**已按住则跳过**（`heldKeys.contains(keyCode)` 防重复按下）；无权限 guard |
| `release` | `(_ action: Action)` | 释放一个键；`heldKeys` 不含则跳过（幂等） |
| `refreshHeldKeys` | `()` | **刷新所有按住键的按下状态（每个控制周期调用一次）**——见下面详解 |
| `releaseAll` | `()` | 释放所有按住的键（停止自动驾驶时调用，避免按键卡住） |

**`refreshHeldKeys()`（第 172–177 行）——为什么必须有这一步（153–171 行注释，本引擎的核心机制）：**

- **真实物理键盘**按住不放时，键盘硬件会持续向系统上报按键状态，系统据此持续产生带 autorepeat 标记的 keyDown 事件流。游戏的输入状态机依赖这个事件流判断"键还按着"
- **CGEvent 注入是「一次性事件」**：hold() 只在按下瞬间发一个 keyDown，之后若控制量保持稳定（例如 E2E 模型在直道恒定输出 throttle=0.98），就再也不会有任何键盘事件产生——系统键盘状态虽然是"按住"，但游戏从未收到过属于它的事件，表现为「UI 显示 W 已按住，游戏纹丝不动」
- 因此**持续按住的键必须按周期重发 keyDown**。调用频率跟随控制主循环（30Hz），与 macOS 默认按键重复率同量级
- **关键：重发的 keyDown 必须是「新按下」语义（autorepeat = false）**——带 autorepeat 标记的事件会被该游戏的输入层忽略（它只认新按下），导致稳定输出档位（如 M9）下只有 auto-repeat 事件流、游戏完全不动。已验证方案（V1）同样是每次都发新按下，此处与之对齐

```swift
func refreshHeldKeys() {
    guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }
    for keyCode in heldKeys {
        postKeyEvent(keyCode: keyCode, keyDown: true)   // 全部重发「新按下」
    }
}
```

**`releaseAll()`（第 182–192 行）**：**无条件对所有映射键发释放事件**——即使本会话没记录按过（例如上次进程异常退出残留的系统级卡键），也主动清掉，保证系统键盘状态干净。六个映射键全部 post keyDown=false，然后 `heldKeys.removeAll()`。

**`postKeyEvent(keyCode:keyDown:autorepeat: Bool = false)`（private，第 204–227 行）**——底层 CGEvent 注入：

1. `CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown)`——nil eventSource 时使用默认源；创建失败打印并 return
2. 仅在显式要求时 `event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)`——**目标游戏（异环 NTE）会忽略带 auto-repeat 标记的 keyDown，因此所有实际调用路径均使用默认 false**（每次都发「新按下」）
3. `event.post(tap: .cghidEventTap)`——**tap: .cghidEventTap 注入到硬件事件层（最底层，游戏必响应）**；`postToPid` 注入到特定进程更精确但需要 PID，这里用全局注入对所有前台应用生效
4. `postedEventCount &+= 1`（wrapping 递增，诊断用）

## 三、GameKey 游戏键位、typeText 与状态查询（第 229–373 行）

**`GameKey`（enum: String, CaseIterable，第 233–282 行）**——游戏常用键枚举（**MaaNTE 实际使用的所有键**），CGKeyCode 值来自 macOS HID Usage Table。**按功能分组 38 个键**：

| 组 | 键 → 键码 |
|---|---|
| 移动 | W=87, A=65, S=83, D=68 |
| 交互 | F=70, E=69, Space=32 |
| UI | ESC=27, Q=81, R=82, M=77, B=66, **T=84**（开车键） |
| 异环 HUD 功能热键 | F1=122, F2=120, F4=118（G2：rewards 入口页切换用；实测 F3=卡布罗集市 F4=活动页） |
| 修饰键 | Shift=160 (0xA0, Left Shift), Ctrl=162 (0xA2, Right Ctrl) |
| 数字选择 | 1=49, 2=50, 3=51, 4=52, 5=53, 6=54, 7=55 |
| 俄罗斯方块/节奏游戏 | J=74, K=75, L=76 |
| 钢琴低音 | Z=90, X=88, C=67, V=86, N=78 |
| 钢琴中音 | G=71, H=72, I=73 |
| 钢琴高音 | Y=89, U=85 |

**⚠️ 两套键码体系并存**：`KeyMap`（驾驶语义键，W=13/A=0/S=1/D=2）用 **macOS virtualKey**；`GameKey` 枚举注释里的"87/65"是 **ASCII 值**，但实际映射表（`gameKeyToKeyCode`）写的是 HID Usage 值——两者数值相同（W 的 HID Usage 87 vs virtualKey 13 **不同**！）。**给别的 AI 的提示：驾驶路径（throttle 等）走 KeyMap（virtualKey 13），技能路径（pressGameKey）走 gameKeyToKeyCode（87）——两套不能混用**，否则驾驶键和技能键会打到不同键。

**`gameKeyToKeyCode`（private static let，第 285–297 行）**：GameKey → CGKeyCode 完整映射表（38 条）。

**`keyCode(for key: GameKey) -> CGKeyCode?`（第 300–302 行）**：查表，未知键返回 nil。

**游戏键注入三件套（第 305–326 行）**——与语义动作版同构，全部走 `postKeyEvent`（所以同样是 `.hidSystemState` + `.cghidEventTap` + 新按下语义）：

- `pressGameKey(_ key: GameKey, duration: TimeInterval = 0.05)`：短按（keyDown → usleep → keyUp）
- `holdGameKey(_ key: GameKey)`：持续按住（已按住跳过，insert heldKeys）
- `releaseGameKey(_ key: GameKey)`：释放（heldKeys 不含跳过）

**`releaseAllGameKeys()`（第 329–336 行）**：**批量释放所有游戏键**——`heldKeys.filter { gameKeyCodes.contains($0) }` 只释放游戏键部分（**不影响驾驶语义键的追踪**，但清理所有 held 状态）；逐个 post keyDown=false + `heldKeys.subtract(toRelease)`。

**`typeText(_ text: String)`（第 341–353 行）**——文本输入（**聊天刷屏类技能用**）：

```swift
let utf16 = Array(text.utf16)
guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
      let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { ... }
down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
postedEventCount &+= 2
```

- Unicode 字符串注入到**当前焦点输入框**——**调用方需先自行把焦点切到目标**（如按 F/回车打开游戏聊天框），并受游戏窗口护栏约束
- 实现：virtualKey 0 的 keyDown/keyUp 各带一份 UTF16 字符串，成对 post（`postedEventCount &+= 2`）

**状态查询（第 358–372 行）**：

- `isHeld(_ action: Action) -> Bool`：语义键是否按住（查 heldKeys）
- `isHeld(_ key: GameKey) -> Bool`：游戏键是否按住（键码 nil 返回 false）
- `heldCount: Int`：当前按住的键数量

**ControlEngine 文档至此完整**（373 行全覆盖：语义动作与 KeyMap → 注入五件套与 refreshHeldKeys → GameKey 与 typeText）。