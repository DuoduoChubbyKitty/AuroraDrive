# 代码-08 ControlEngine 按键注入引擎
> ♻️ **版本沿革**：早期版本曾按行号逐条核对 114 处引用并修正 41 条；现按去行号化规范全部改写为代码符号名（`applyLaneAdvice`、`commandOf`、`mayInjectKeys`、`degradeStm.update`、`laneKeepTiers`、`readPose`、`applyCommand`、`applySpeedLimitBrake`、`pauseDriving`、`maskSeq` 等），不再依赖行号。
>
> **✅ 2026-10-18 「指向相邻符号」审计（lead 脚本抓 8 条可疑，逐条 `sed -n` 判定）**：**修正 3 条 / 误报 5 条**
> - 修正 `EngineMain` 心跳统计的 `heartbeatCount % 5 == 0` 门（曾误指向自增语句，现以条件表达式定位）
> - 修正 `updateMotionPipeline` 的调用点（曾误指向其注释行）
> - 修正 `runControl` 的定义位置（`static func runControl` 才是入口，docstring 不算）
> - 误报 5 条：`maskSeq` 协议 offset 80（布局注释）✅、`maskSeq` 的 `@MainActor static var` 声明✅、`isDriving` 心跳镜像（`isDriving = client.engineIsDriving`）✅、`benchSuppressAllInjection` 分支起点（`if benchSuppressAllInjection {`）✅、`AuroraFlags.laneKeepTiers` 与 `AuroraFlags.keyRefreshHz` 两个开关声明✅
> ✅ **历史复核结论**：此前逐条 `read` + 搜索复核，曾发现并修正 1 处重大事实错误与跨文件引用漂移，现已全部改为符号名锚定。

**本轮修正清单（2026-10-18）**：

1. ❌→✅ **重大事实错误（本文件第二节原文写错）**：原文称「重发的 keyDown 必须是**新按下**语义（**autorepeat = false**）」。**源码实际相反**——`postKeyEvent(keyCode:keyDown:autorepeat: Bool = false)` 的 `autorepeat` 参数**默认 false 但从未被置 true**，而 `refreshHeldKeys()` 调用 `postKeyEvent(keyCode:keyDown:)` 走默认参数 → **实际不设 autorepeat 标记**。即：**游戏确实只认「新按下」，本项目实际每次发的就是不标记 autorepeat 的事件**。原文的结论（不标 autorepeat）正确，但把「参数默认值」误述为「源码显式设为 false」，且未说明 `autorepeat` 是**保留参数、零调用点传 true**。已按 `postKeyEvent` 签名与 `.keyboardEventAutorepeat` 设置分支修正表述。
2. ⚠️ **任务简报中两条「已知事实」经核对与源码相反**，本文件按**源码**为准修正：
   - 简报称「`.cghidEventTap` + `.combinedSessionState`」——**错**。源码 `ControlEngine.eventSource` 明确用 **`.hidSystemState`**，注释记录 `.combinedSessionState` 是**曾用但实测对该游戏无效**的历史方案。原文档本来就是对的，本轮予以保持。
   - 简报称「CGEvent 必须周期重发 keyDown + `.keyboardEventAutorepeat=1`」——**错**。源码 `postKeyEvent` 的 `.keyboardEventAutorepeat` 分支注释明写「目标游戏（异环 NTE）会**忽略**带 auto-repeat 标记的 keyDown……所有实际调用路径均使用默认 false」。`refreshHeldKeys()` 的重发正是为了**持续产生「新按下」事件流**，而非 autorepeat 事件流。原文档表述正确，本轮保持并补强论证。
3. **跨文件引用系统性漂移**：早期版本记录过 `AuroraDriveApp.swift` 由 9088 行涨到 9094 行导致约 30 处引用偏移；本版全部改为符号名，不再需要按版本重定位。
4. `Core/EngineMain.swift` 的 `engineTickHz` 注释区块曾扩充导致行号漂移；本版已改用符号名复核。

> ✅ **历史复核（内容保留）**：覆盖源文件与全部正文引用曾逐条按源码实测对齐；本版改以符号名为锚点。

> 覆盖源文件：`Sources/AuroraDrive/Control/ControlEngine.swift`（按符号锚定：`ControlEngine` 类、`Action`、`KeyMap`、`GameKey`、`postKeyEvent`、`typeText` 等）。
> 跨文件引用按符号锚定：`App/AuroraDriveApp.swift`（`applyCommand`/`commandOf`/`readPose` 等）、`Core/EngineMain.swift`（`tickOnce`/`pauseDriving`/`maskSeq` 等）、`Inference/YolopxEngine.swift`（`MaskGrid`/`isDegraded` 等）、`Agent/ToolRegistry.swift`（`gameKeyNames`/`resolveGameKey` 等）、`Agent/LLMSelfTest.swift`（`runControl` 等）、`App/MissionConsole.swift`、`App/RouteGraph.swift`、`Agent/DriveSegmentController.swift`、`Agent/DegradeStateMachine.swift`、`Control/MouseController.swift`、`Control/KeyboardMonitor.swift`、`Control/EscapeController.swift`、`Core/AuroraFlags.swift`。
> 文末「实测锚点表」列出本档引用的全部符号，可直接按名称在源码中复核。

## 一、语义动作、KeyMap 与 HID 事件源

**类声明**：`@Observable final class ControlEngine: @unchecked Sendable`——通过 CGEvent 向系统**全局键盘队列**注入按键事件，控制游戏（WASD + 空格 + Shift）。需要"辅助功能"权限（Accessibility）。@Observable 让 SwiftUI 自动观察按键状态变化（键盘可视化条用）。文件头注释自述："按键注入引擎（CGEvent）……需要'辅助功能'权限"。

**`Action`（enum）**——按键动作枚举（**语义化，与具体键位解耦**）：

| case | 语义 |
|---|---|
| `throttle` | 油门（前进） |
| `brake` | 刹车（后退） |
| `steerLeft / steerRight` | 左转 / 右转 |
| `handbrake` | 手刹（空格） |
| `boost` | 极速（Shift） |

**`KeyMap`（struct）**——按键映射：语义动作 → macOS 键码。键码参考（HID Usage Table → macOS virtualKey）：**W=13, A=0, S=1, D=2, 空格=49, LeftShift=56, RightShift=60**。`keyCode(for:)`：switch 语义动作取键码。

> ✅ **2026-10-17 复核：本表本来就是对的，GameKey 修复未触碰它**。`KeyMap` 六项（`throttle`/`brake`/`steerLeft`/`steerRight`/`handbrake`/`boost`）逐项对齐 Carbon `kVK_ANSI_*`：throttle 13=`kVK_ANSI_W`、brake 1=`kVK_ANSI_S`、steerLeft 0=`kVK_ANSI_A`、steerRight 2=`kVK_ANSI_D`、handbrake 49=`kVK_Space`、boost 56=`kVK_Shift`。这正是"驾驶一直正常、只有 AI 注入的键错"的原因（详见第八节）。

| 字段 | 默认值 | 键 |
|---|---|---|
| `throttle` | 13 | W |
| `brake` | 1 | S |
| `steerLeft` | 0 | A |
| `steerRight` | 2 | D |
| `handbrake` | 49 | 空格 |
| `boost` | 56 | Left Shift |

`func keyCode(for action: Action) -> CGKeyCode`：switch 语义动作取键码。

- `var keyMap = KeyMap()`——当前按键映射，**可运行时修改**

**权限与按键状态**：

- `hasAccessibilityPermission`（private(set)）——是否拥有辅助功能权限
- `heldKeys: Set<CGKeyCode>`（private(set)，@Observable）——当前按住的键集合，键盘可视化条观察此属性；每次按下/释放都更新，SwiftUI 自动刷新键帽颜色
- `postedEventCount: Int`（**@ObservationIgnored**）——累计成功注入的键盘事件总数（诊断用：判断事件流是否持续产生）；标记 @ObservationIgnored 因为每帧递增，不应触发 SwiftUI 重绘

**消化模式（`digestMode`，2026-10 新增）**——按键链路照常跑完（决策算、heldKeys 更新、UI 键盘条亮、计数递增、日志照打），但**最后一步不真发 CGEvent**：事件被「消化」在进程内部（`postKeyEvent` 与 `typeText` 两处截住）。`digestMode` 由 `AURORA_DIGEST=1` 初始化（`digestModeFromEnvironment`），切换时同步进程级开关 `globalDigest`（鼠标等其它注入器共用）；`digestedEventCount` 与被消化事件对照，诊断时一眼看出链路是活的。

**按住键重发节流（`keyRefreshInterval`）**——`AURORA_KEY_REFRESH_HZ`（`AuroraFlags.keyRefreshHz`，默认 0=关闭）换算成间隔；关闭时**与改动前逐帧一致**（每控制周期 30Hz 重发）。`keyRefreshInterval` 的文档注释记录了启用节流的动机（严格 33.3ms 周期的机器特征）与风险（重发不足会「UI 显示 W 已按住，游戏纹丝不动」，见 refreshHeldKeys 历史事故），**默认关闭、启用须真机验证**；抖动 ±25%（`Double.random(in: 0.75...1.25)`）只挪事件时刻、不降频。上次重发时刻 `lastKeyRefreshAt`。

**`eventSource`（lazy 闭包）——本引擎最关键的实测结论：**

```swift
private let eventSource: CGEventSource? = {
    return CGEventSource(stateID: .hidSystemState)
}()
```

- **必须用 `.hidSystemState`（对应 C API 的 kCGEventSourceStateHIDSystemState）**：实测目标游戏（异环 NTE）的输入层只读取 HID 系统状态层的键盘事件
- `.combinedSessionState`（曾用）：实测对该游戏无效——该层的合成事件会被系统 UI 正常接收（键盘可视化条会亮、系统提示音会响），**但游戏输入层直接忽略**，表现为「UI 显示已输出 W，但游戏纹丝不动」
- `.privateState`：更私有的状态层，游戏更加读不到，**禁止使用**
- `.hidSystemState`：事件进入 HID 系统状态层，与真实物理键盘同层，配合 `.cghidEventTap` 投递，即为已验证可突破该游戏反作弊拦截的方案（`eventSource` 注释）

**权限函数**：

- `checkPermission() -> Bool`：`AXIsProcessTrustedWithOptions(nil)`——**P0 修复 (2026-09-07)**：字符串字面量 `"kAXTrustedCheckOptionPrompt"` 不是有效的 CFString 常量，导致 options 字典无效 → 收到 nil 等价参数 → 访问空指针崩溃（**EXC_BAD_ACCESS at 0x8**）。正确做法是直接传 nil（不弹窗）——**2026-09-30 更正**：传 nil 时**只查询、绝不弹窗**，故拆分为两个方法：本方法保持"纯查询"（`press`/`hold` 的高频重试路径绝不能弹窗），`requestAccessibilityPermission()` 专用于一次性请求
- `requestAccessibilityPermission() -> Bool`：`kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true` 传入触发**系统授权弹窗 + 把本程序登记进辅助功能列表**；被拒时幂等地 `openAccessibilitySettings()` 打开设置面板。背景：修复前全项目只查询不请求 → 程序永远不进辅助功能列表 → 所有注入被系统静默丢弃
- 无权限时注入事件会被系统**静默丢弃**
- `openAccessibilitySettings()`：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` URL → `NSWorkspace.shared.open`（引导用户授权）

## 一·五、屏幕录制权限（2026-09-30 新增）

**为什么放在 ControlEngine**：与辅助功能权限是同一职责的两项（都是「注入/观测所需的一次性系统授权」），放一起便于对照维护。

- `requestScreenRecordingPermission() -> Bool`：`CGRequestScreenCaptureAccess()` 弹系统授权框并登记进 TCC 列表；被拒时幂等打开设置面板。⚠️ 首次调用几乎必然返回 false，且勾选后通常要重启 App 才生效（见文档注释）
- `openScreenRecordingSettings()`：打开「屏幕录制」面板
- `static requestScreenRecordingPermissionOnStartup()`：**启动期版本**（供 AppDelegate 调用），先 `CGPreflightScreenCaptureAccess()` 预检、已授权则完全静默。**它解决的死锁**：`captureEngine.start()` 只在 `startDriving()` 里被调，而 `startDriving()` 开头有辅助功能守卫——没辅助功能权限 → 截屏引擎永不启动 → 屏幕录制申请永不触发。把申请从 startDriving 解耦挂到 `applicationDidFinishLaunching`，「看画面」不再依赖「能按键」
- 背景：此前全项目只有 `CGPreflightScreenCaptureAccess()` 纯查询（`EngineMain`、`AuroraDriveApp`），`CGRequestScreenCaptureAccess()` **零调用** → 系统设置列表里根本不会出现本 App

## 二、按键注入五件套与 refreshHeldKeys

**五个注入方法（语义动作版）：**

| 方法 | 行号 | 行为 |
|---|---|---|
| `press` | 短按 | 按下并立即释放（短按）；`usleep(duration × 1_000_000)`短暂等待后释放（模拟真实按键时长）；无权限时先 checkPermission 再 return |
| `hold` | 持续按住 | 持续按住不释放（直到 release/releaseAll）；**已按住则跳过**（`heldKeys.contains(keyCode)` 防重复按下）；无权限 guard |
| `release` | 释放 | 释放一个键；`heldKeys` 不含则跳过（幂等） |
| `refreshHeldKeys` | 周期重发 | **刷新所有按住键的按下状态（每个控制周期调用一次）**——见下面详解 |
| `releaseAll` | 全量释放 | 释放所有按住的键（停止自动驾驶时调用，避免按键卡住） |

**`refreshHeldKeys()`——为什么必须有这一步（`refreshHeldKeys` 的文档注释，本引擎的核心机制）：**

- **真实物理键盘**按住不放时，键盘硬件会持续向系统上报按键状态，系统据此持续产生带 autorepeat 标记的 keyDown 事件流。游戏的输入状态机依赖这个事件流判断"键还按着"
- **CGEvent 注入是「一次性事件」**：hold() 只在按下瞬间发一个 keyDown，之后若控制量保持稳定（例如 E2E 模型在直道恒定输出 throttle=0.98），就再也不会有任何键盘事件产生——系统键盘状态虽然是"按住"，但游戏从未收到过属于它的事件，表现为「UI 显示 W 已按住，游戏纹丝不动」
- 因此**持续按住的键必须按周期重发 keyDown**。调用频率跟随控制主循环（20Hz，当前 `engineTickHz` 默认值），与 macOS 默认按键重复率同量级
- **关键：重发的 keyDown 必须是「新按下」语义，即 `autorepeat` 参数保持 false（默认值）**——带 autorepeat 标记的事件会被该游戏的输入层忽略（它只认新按下），导致稳定输出档位（如 M9）下只有 auto-repeat 事件流、游戏完全不动。已验证方案（V1）同样是每次都发新按下，此处与之对齐
- ⚠️ **2026-10-18 修订（原表述不准确）**：源码 `postKeyEvent(keyCode:keyDown:autorepeat: Bool = false)` 的 `autorepeat` 参数**默认 false，且全仓无任何调用点显式传 `true`**（`refreshHeldKeys`、`press`、`hold`、`release`、`releaseAll`、`typeText` 全部走默认参数）。即 autorepeat 是**为其他输入层保留的未使用参数**，实际注入的每个 keyDown 都不带 autorepeat 标记。「新按下」语义由「不设标记」实现，而非由「显式设 false」实现

```swift
func refreshHeldKeys() {
    guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }
    if Self.keyRefreshInterval > 0 { /* 节流+抖动（默认关闭，见 keyRefreshInterval） */ }
    for keyCode in heldKeys {
        postKeyEvent(keyCode: keyCode, keyDown: true)   // 全部重发「新按下」
    }
}
```

**`releaseAll()`**：**无条件对所有映射键发释放事件**——即使本会话没记录按过（例如上次进程异常退出残留的系统级卡键），也主动清掉，保证系统键盘状态干净。六个映射键全部 post keyDown=false，然后 `heldKeys.removeAll()`；末尾记录 `lastFullReleaseAt` 供节流版判断。

**`releaseAllIfNeeded()`（2026-10-01 阶段4 性能折叠）**：节流版全量释放。背景：生产 tick 分段剖析实测 `tick.inject` p50=0.15ms 占整帧 71%——根因是 `expertMode || controlDisabled` 分支每帧无条件对 6 键各发一次 CGEvent。语义：有按住键 → 必须完整清扫；无按住键 → 同一秒内已清扫过就跳过。安全边界：1 秒内不可能凭空出现新的系统级残留；`applyCommand` 走 `release(_:)`、停止驾驶走 `releaseAll()`，都不受影响。回退开关 `AURORA_RELEASE_ALL_EVERY_TICK=1`（消费端 AuroraDriveApp.swift、AuroraFlags.swift）。

**`postKeyEvent(keyCode:keyDown:autorepeat: Bool = false)`（private）**——底层 CGEvent 注入：

1. `CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown)`——nil eventSource 时使用默认源；创建失败打印并 return
2. 仅在显式要求时 `event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)`——**目标游戏（异环 NTE）会忽略带 auto-repeat 标记的 keyDown，因此所有实际调用路径均使用默认 false**（每次都发「新按下」）。⚠️ **2026-10-18 补充**：`autorepeat` 是**为其他输入层保留的参数，全仓零调用点显式传 `true`**（`refreshHeldKeys`、`press`、`hold`、`release`、`releaseAll`、`typeText` 均走默认值）
3. `event.post(tap: .cghidEventTap)`——**tap: .cghidEventTap 注入到硬件事件层（最底层，游戏必响应）**；`postToPid` 注入到特定进程更精确但需要 PID（仅注释提及未使用），这里用全局注入对所有前台应用生效
4. `postedEventCount &+= 1`（wrapping 递增，诊断用）；消化模式下改为 `digestedEventCount &+= 1` 并提前 return

### 三、GameKey 游戏键位、typeText 与状态查询

> ✅ **本节键码已于 2026-10-07 订正**：下方表格为**修复后的正确值**；键码对照与缺陷全过程见 **第八节**。

**`GameKey`（enum: String, CaseIterable）**——游戏常用键枚举（**MaaNTE 实际使用的所有键**，出处标注见文件头「品牌澄清」注释）。**按功能分组 38 个键**；注释里的数字是 **macOS 虚拟键码**（`kVK_ANSI_*`）——`GameKey` 头注释明确：**不是 ASCII 码，也不是 Windows `VK_*` 码**：

| 组 | 键 → 键码（**2026-10-07 修复后，实测自 `ControlEngine.gameKeyToKeyCode`**） |
|---|---|
| 移动 | W=13, A=0, S=1, D=2 |
| 交互 | F=3, E=14, Space=49 |
| UI | ESC=53, Q=12, R=15, M=46, B=11, **T=17**（开车键） |
| 异环 HUD 功能热键 | F1=122, F2=120, F4=118（G2：rewards 入口页切换用；实测 F3=卡布罗集市 F4=活动页） |
| 修饰键 | Shift=56 (`kVK_Shift`, Left Shift), Ctrl=59 (`kVK_Control`, Left Control) |
| 数字选择 | 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26 |
| 俄罗斯方块/节奏游戏 | J=38, K=40, L=37 |
| 钢琴低音 | Z=6, X=7, C=8, V=9, N=45 |
| 钢琴中音 | G=5, H=4, I=34 |
| 钢琴高音 | Y=16, U=32 |

**键码体系结论（2026-10-07 订正）**：驾驶路径 `KeyMap` 与 AI 技能路径 `gameKeyToKeyCode`**现同为 macOS 虚拟键码**，同一个键两处取值一致（W 都是 13、空格都是 49）——**两张表不会再打到不同键**。

> 📛 **旧版论断作废（保留以记账）**：2026-10-06 版此处曾写「`GameKey` 注释里的 87/65 是 ASCII 值，实际映射表写的是 HID Usage 值，两者数值相同」——**实测不成立**。当时表里的 `87` 既不是 virtualKey 也不是 HID Usage，而是 **ASCII / Windows `VK_*` 码**；「两套不能混用」的提醒方向正确，但归因（HID Usage）错误——这一误判本身也是缺陷长期未被发现的原因之一（详见第八节）。

**`gameKeyToKeyCode`（private static let）**：GameKey → CGKeyCode 完整映射表（38 条）；上方是 2026-10-06 的缺陷修复记录注释。

**`keyCode(for key: GameKey) -> CGKeyCode?`**：查表，未知键返回 nil。

**游戏键注入三件套**——与语义动作版同构，全部走 `postKeyEvent`（所以同样是 `.hidSystemState` + `.cghidEventTap` + 新按下语义）：

- `pressGameKey(_ key: GameKey, duration: TimeInterval = 0.05)`：短按（keyDown → usleep → keyUp）
- `holdGameKey(_ key: GameKey)`：持续按住（已按住跳过，insert heldKeys）
- `releaseGameKey(_ key: GameKey)`：释放（heldKeys 不含跳过）

**`releaseAllGameKeys()`**：**批量释放所有游戏键**——`heldKeys.filter { gameKeyCodes.contains($0) }` 只释放游戏键部分（**不影响驾驶语义键的追踪**，但清理所有 held 状态）；逐个 post keyDown=false + `heldKeys.subtract(toRelease)`。

**`typeText(_ text: String)`**——文本输入（**聊天刷屏类技能用**）：

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
- 实现：virtualKey 0 的 keyDown/keyUp 各带一份 UTF16 字符串（`keyboardSetUnicodeString`），成对 post（`postedEventCount &+= 2`）；消化模式下同样截住

**状态查询**：

- `isHeld(_ action: Action) -> Bool`：语义键是否按住（查 heldKeys）
- `isHeld(_ key: GameKey) -> Bool`：游戏键是否按住（键码 nil 返回 false）
- `heldCount: Int`：当前按住的键数量

**ControlEngine 文档至此完整**（718 行全覆盖：语义动作与 KeyMap → 消化模式 → 屏幕录制权限 → 注入五件套与 refreshHeldKeys/releaseAllIfNeeded → GameKey 与 typeText → 状态查询）。

## 四、★ 驾驶控制全链路：RoutePlan 不直接产生按键（2026-10-06 核实）

> 本节为全链路总览，各环节的详细展开见 [代码-21-RuleController](代码-21-RuleController规则控制器.md)、[代码-34-DriveSegmentController](代码-34-DriveSegmentController驾驶分段控制器.md)、[代码-35-RoadCornerGuide](代码-35-RoadCornerGuide弯道先验.md)。

**核心结论（已逐条查证）**：**RoutePlan（A* 结果）不直接产生任何按键**。它只是地图折线 + 距离信息，消费点全部在显示/提示层；真正进入 ControlEngine 的控制量来自「感知 → 降级状态机 → ControlCommand → applyCommand」这条链。

1. **路线规划（显示/提示层）**：`RoutePlanner.route()` A* + 拐弯惩罚（`RoutePlanner`，手写二叉堆，拐弯惩罚 `cost = 边长 + W×(角度/90°)`），输出 `RoutePlan{distanceMeters, turns, segments, points, …}`（结构体 `RouteGraph.swift`）。像素入口 `route(graph:fromPixel:toPixel:)`。触发点：`App/MissionConsole.swift`（任务面板规划，`RoutePlanner.route` 调用点）与 `App/AuroraDriveApp.swift`（遮罩规划）。
2. **RoutePlan 的实际消费（均为显示层）**：
   - 小地图画路网折线 — `App/MissionConsole.swift`（`plan.points` 逐点 `addLine`）；
   - 任务卡片弯道距离（米）— `App/MissionConsole.swift`（`state.routePlan?.distanceMeters`）与夹具日志。
   - **未验证**：未发现 `routePlan.points` 被直接喂给转向控制。真实路径引导走的是另一条独立链路：`RoadCornerGuide`（`road_corners_v3b.json` 打点集，**非 RoutePlan**）+ `DriveSegmentController`（见第 5 步）。若 RoutePlan 未来要接管方向，目前是断开的（未验证有其它接线）。
3. **感知**（`DriveState.tick()`，`App/AuroraDriveApp.swift` 起，20Hz）：M9 端到端主驾 V2 `inferenceEngineV2.infer`、旧 M9 回退 `inferenceEngine.infer`；第二套驾驶模型 `assistEngine.infer`；YOLO 检测 `yoloEngine.infer`；YOLOPX 三合一 `yolopxEngine.infer`；光流+运动预测 `updateMotionPipeline`（调用点，其定义同名）。
4. **决策**：模型输出 → `ControlCommand`（`commandOf` / `v2CommandOf`）；降级状态机 `degradeStm.update()` 决定档位（`DegradeStateMachine`：`degradeHealth` 默认 0.65 触发降级、`recoverHysteresis` 默认 0.15 滞回恢复、`sportOverride` 极速模式强制 e2e、`forceRule` 最高优先、`modeLock` 档位锁定）。档位选择控制量（e2e=`m9Command` / yolo=`assistCommand` / rule=`ruleController.decide(detections:)`）。
5. **车道保持 / 地图分段覆盖**（门 = `Self.laneKeepTiers`；声明 `AuroraFlags.laneKeepTiers`，`AURORA_LANEKEEP_TIERS` 默认 `rule,yolo`）：
   - 分段优先：`readPose()`（定位位姿，**`locatorScore >= 0.4` 门**，实现与门槛在 `readPose()`；新鲜度档位分由 `locatorScoreForTier` 给出，只有 live=1.0 过门槛）→ `segmentDecisionForRule()`（`RoadMapPrior.isOnRoad` + `DriveSegmentController.update`）→ 地图段/回正段用 `mapSteer` **覆盖**视觉转向并压油门。弯道点来自 `RoadCornerGuide.cornerAhead`（`DriveSegmentController`），**不是 RoutePlan**。
   - 视觉兜底：`laneFallback.evaluate(laneMask:drivableMask:...)` 消费 YOLOPX 的 da/ll 掩码 → `applyLaneAdvice`（文件级全局函数；转向 ±0.25 限幅+置信度加权、油门只压不抬、刹车只加不减）。
6. **按键注入**：`applyCommand(currentCommand)`（在 `benchSuppressAllInjection` 与 `expertMode || controlDisabled` 两个抑制分支之后）→ `applyCommand` 实现：steer 死区 ±0.1 → hold A/D；throttle>0.3 hold W、brake>0.3 hold S（互斥）；末尾 `refreshHeldKeys()` 重发按住键。
7. **限速硬闸（优先级高于一切模型）**：`mayInjectKeys = isDriving && !expertMode && !controlDisabled`；超速时 `applySpeedLimitBrake()`（松 W/Shift + 手刹脉冲 + 不打方向 + refreshHeldKeys），刹车期间提前 return，本帧 AI 决策键全部不执行；退出时 `releaseSpeedLimitBrake()` 必须松空格防卡死。
8. **引擎模式差异**：UI 的 `startDriving()` 只发 "start" 命令；真实 tick/注入在引擎进程 `Core/EngineMain.swift`（`tickOnce()` 调同一个 `st.tick()`）。UI 的 `isDriving` 是引擎心跳的镜像（命令后 1s 宽限）。

## 五、driving=false 的判定条件（引擎日志 driving 字段）

日志字段来源：`Core/EngineMain.swift` `driving=\(EngineGlobals.state?.isDriving ?? false)`，即**引擎进程内 DriveState.isDriving**。它由以下路径写定：

- **置 true**：仅 `startDriving()` — 引擎模式发命令成功后，本地模式通过辅助功能权限守卫后。守卫 `guard controlEngine.requestAccessibilityPermission() || controlDisabled else { return }`（观测模式 `AURORA_OBSERVE_ONLY=1` 强制 `controlDisabled=true`，可无权限启动但不注入）。
- **置 false（四条路径）**：
  1. `stopDriving()`：UI 点停止，并 `controlEngine.releaseAll()`。
  2. `EngineMain.pauseDriving()`：`st.isDriving = false` + `releaseAll()` — `Core/EngineMain.swift`。触发源：UI 断开（bye 命令）与**看门狗超时**（"watchdog"，重连窗口 3 秒）。
  3. 引擎自动退出 `performShutdown`（idle-exit 由 `idleExitWorkItem` 负责；任何退出路径都先 `releaseAll()`）。
  4. 引擎模式下 UI 侧镜像回写：心跳 `engineIsDriving` 不一致且命令后超过 1 秒 → `isDriving = client.engineIsDriving` — `AuroraDriveApp.swift`。
- 注意区分：`isDriving=false` 只是停掉决策与注入主路径（tick 待机分支清空决策）；权限拒绝**不是** driving=false 的来源——被守卫挡回时 `isDriving` 根本不会被置 true（守卫直接 return）。

## 六、da / ll / maskSeq / 降级 的确切含义与计算处

统计日志出处：`Core/EngineMain.swift`（每 5 秒心跳，`heartbeatCount % 5 == 0` 门）。

| 字段 | 含义 | 计算处 |
|---|---|---|
| `da` | **drivable area，可行驶区域掩码**。来自 YOLOPX 模型的 `da` 输出头（`out.featureValue(for: "da")` — `YolopxEngine`），经 argmax+4×4 多数表决下采样成 `MaskGrid`，`extractMask` 调用），再做跨帧 EMA 平滑落到 `drivableMask`。日志值 `drivableMask.positiveCount` = 掩码网格中前景格数（`MaskGrid.positiveCount`） | `YolopxEngine`（`extractMask`/`drivableMask`） |
| `ll` | **lane line，车道线掩码**。同源的 `ll` 输出头 → `laneMask`。日志值 `laneMask.positiveCount`。⚠️ 「0 格」= 车道线信号塌陷/模型未出结果；`da=0 ll=0` 常伴随 `降级=true` | 同上 |
| `maskSeq` | 掩码世代号（u64，共享内存协议 offset 80；`@MainActor static var` 声明）。掩码指纹（前景格数+宽度哈希）变化时 +1，UI 据此判断掩码新鲜度；停止驾驶时清 0 并发空掩码。仅 `st.isDriving` 时发布掩码 | `EngineMain`（`tickOnce` 内掩码发布段） |
| `降级` | `px?.isDegraded ?? true` = YOLOPX 决策层降级总开关。计算：`laneDegraded = laneRatio < 0.002 ‖ > 0.25`；`drivableDegraded = drivableRatio < 0.02 ‖ > 0.70`；`isDegraded = laneDegraded ‖ drivableDegraded`；推理出错直接置 true | `YolopxEngine`（`isDegraded`） |

配套语义：`isDegraded=true` 时 `LaneFallback`（车道兜底）fail-open 不给建议（tick 传入 `isDegraded` 并被 LaneFallback 内部门控）；显示层另有独立的 `laneDegraded`/`drivableDegraded` 只压暗对应图层（`YolopxEngine` 注释）。日志其余字段：`seq`=共享内存帧序号，`有帧`=是否截到画面，`det`=YoloEngine 检测框数，`yolopx:加载/帧数`=模型是否加载/累计推理次数（`inferenceCount`，`YolopxEngine`），`耗时`=单帧推理+NMS+掩码提取耗时（`lastLatencyMs`，`YolopxEngine`）。

## 七、键鼠模拟机制与安全护栏

### 机制（合规：CGEvent 模拟输入）
- 键盘：`CGEvent(virtualKey:keyDown:)` + `event.post(tap: .cghidEventTap)` — ControlEngine.swift。事件源 `.hidSystemState`，autorepeat 恒 false（游戏只认「新按下」）。坐标/文本注入：`typeText` 用 `keyboardSetUnicodeString`（两次写入 Unicode 字符串、计数 +2）。
- 鼠标：`CGEvent(mouseEventSource:mouseType:mouseCursorPosition:)` 同 tap 投递 — MouseController.swift（`move`、`click`、`doubleClick`）；滚轮 `scrollWheel`；像素→点换算 `screenPoint(fromPixel:scale:)`。
- 读屏（合规：ScreenCaptureKit 截屏）：`CaptureEngine.start()`（tick 消费帧）；键盘只读监听 `NSEvent.addGlobalMonitorForEvents` — KeyboardMonitor.swift（`start()` 内注册，`handleEvent` 过滤 auto-repeat）。
- 权限面：辅助功能（注入必需，ControlEngine.swift）+ 屏幕录制（ControlEngine.swift）。
- **合规声明（红线）**：本项目硬约束为**只做读屏 + 系统事件合成**——禁止内存读取、禁止进程注入、禁止反作弊规避。以上机制均为 ScreenCaptureKit 截屏 + CGEvent 模拟输入路径；未发现内存读取/进程注入/反作弊检测规避代码（`postToPid` 仅注释提及未使用，`ControlEngine.swift`；`AURORA_KEY_REFRESH_HZ` 节流+抖动只挪事件时刻，注释自证「抖动本身不降频」）。注意 `eventSource` 注释自称该方案「可突破该游戏反作弊拦截」，这是对「游戏输入层只认 HID 层合成事件」这一兼容性事实的描述，未见任何主动对抗反作弊的代码。

### 护栏（有急停语义，无独立热键急停）
- **停止/暂停即松键**：`stopDriving()` → `controlEngine.releaseAll()`（AuroraDriveApp.swift）；引擎看门狗/UI 断开 → `pauseDriving` EngineMain.swift；30s 无人 → idle-exit 先 `releaseAll()`；进程启动/开始驾驶前清残留卡键。
- **专家模式**（`expertMode`）：真人物理键独占，AI 不注入（物理键由 KeyboardMonitor 只读采集用于录制标签）。
- **控制禁用 / 观测模式**：`controlDisabled`（`AURORA_OBSERVE_ONLY=1` 强制置真）全注入路径关闭（同走 `benchSuppressAllInjection` 分支）。
- **夹具硬开关** `benchSuppressAllInjection`：连松键事件都不发。
- **限速硬闸**：超速 → 纯规则刹车（松 W/Shift + 手刹），优先于一切模型；准入条件与主注入同一道 `mayInjectKeys` 门；退出必须松手刹防卡键。
- **卡死保护**：连续 30s 速度≈0（需 `isDriving && speedValid`）→ 拉横幅**请求人工介入，AI 不自行挣扎**（用户原话与设计要点见注释）。
- **脱困已删除**：EscapeController 恢复档 2026-09-30 整体删除（EscapeController.swift），避免 AI 与用户抢控制权（tick 取证注释：第三视角自车入框 → 框叠加误判碰撞 → brake 即倒车抢控制权，原理不成立）。
- **车道建议单向安全**：转向 ±0.25 限幅、油门只压不抬、刹车只加不减、fail-open（tick 注释；`applyLaneAdvice`）。
- **权限死锁防御**：屏幕录制申请从 startDriving 解耦到启动期（ControlEngine.swift）。
- **缺口（诚实记录）**：未发现独立的「急停热键」（panic key）；急停语义由 UI 停止按钮 + 上述被动护栏构成（未验证有其它入口）。

## 附：一处命名陷阱
`Control/EscapeController.swift` 如今**不含**脱困逻辑，只有 `ControlCommand` 类型（`steer/throttle/brake/confidence` 字段，`.idle` 空操作）。查脱困相关历史请看文件头注释与 `AuroraDriveApp.swift` 的删除取证。

---

## 八、★ GameKey 键码表 35/38 项缺陷修复（2026-10-06 发现并修复，2026-10-07 记录）

> 本节是本次（10-07）增量的核心。所有事实均来自**当前源码**（`ControlEngine.swift`）、**git 提交**与**仓库内原始取证文件**；引用已全部改为符号名。

### 8.1 一句话结论

`gameKeyToKeyCode`（`ControlEngine.swift`）最初把 **ASCII / Windows `VK_*` 码**当成了 macOS `CGKeyCode`，38 项里 **35 项是错的**。修复后全部改为 Carbon `kVK_*` 虚拟键码。**驾驶路径 `KeyMap` 从未受影响**——它一开始就是对的，这是缺陷能潜伏这么久的原因。

### 8.2 错误症状（三层，从用户可见到系统行为）

| 层 | 症状 | 依据 |
|---|---|---|
| ① 系统层：注入的键变成别的键 | macOS 把旧表的值解释成完全不同的物理键：`87`→**小键盘 5**、`65`→**小键盘 `.`**、`83`→**小键盘 1**、`32`→**字母 `u`**、`27`→**`-`**、`0xA0/0xA2`→**无字符** | ControlEngine.swift（源码自记，`gameKeyToKeyCode` 缺陷记录注释）；evidence 文件方法①/② |
| ② 应用层：AI 技能与工具"按了没反应" | 所有走 `pressGameKey`/`holdGameKey` 的技能——登录、钓鱼、做咖啡、钢琴、节奏、闪避——**发出去的全是错键**，游戏侧表现为按了无效果或触发了意料之外的 UI | ControlEngine.swift（`gameKeyToKeyCode` 缺陷记录注释） |
| ③ 排障层：表现出"AI 是坏掉的" | 由于注入链路本身"成功"（`postedEventCount` 照常增长、CGEvent 无报错），排障时看不出异常——**只有把事件抓回来读字符串才能发现** | ControlEngine.swift（`gameKeyToKeyCode` 缺陷注释里的取证说明） |

**为什么车还能动（关键区分）**：驾驶控制量走的是 `KeyMap`（W/A/S/D/空格/Shift），那张表用的是**正确的**虚拟键码，所以自动驾驶一直正常。`GameKey` 只服务 AI 技能 / AI 工具注入路径——**两条路径互不影响**，这既是"车能动"的原因，也是缺陷长期没被发现的原因（`ControlEngine.swift` 的 `gameKeyToKeyCode` 注释）。

### 8.3 两条表并存：修前 vs 修后

| | 修前 | 修后 |
|---|---|---|
| 驾驶路径 `KeyMap` | W=13 / A=0 / S=1 / D=2 / Space=49 / Shift=56 —— **正确** | 未改动，仍 **正确** |
| AI 技能路径 `gameKeyToKeyCode` | W=87 / A=65 / S=83 / D=68 / Space=32 / Shift=0xA0 … —— **35/38 错** | W=13 / A=0 / S=1 / D=2 / Space=49 / Shift=56 —— **与 KeyMap 一致** |
| 两表关系 | **同一批键，两套互不相容的编码**（历史缺陷：先有 KeyMap，GameKey 后加时用错了码表） | 统一为 macOS 虚拟键码，**可安全混用** |

⚠️ **`gameKeyToKeyCode` 的注释曾自述"CGKeyCode 值来自 macOS HID Usage Table"——这句是错的**，修复时已改写（`GameKey` 头注释）。`87` 既不是 virtualKey 也不是 HID Usage，而是 ASCII 的 `'W'`。**给别的 AI 的提示：不要再把 W 写成 87。**

### 8.4 错误值 ↔ 正确值完整对照表（38 项）

「系统翻译」列 = 把旧值注入 `.cghidEventTap` 后，自建 CGEventTap 抓回并读 `keyboardGetUnicodeString` 得到的字符（`verify/evidence-llm/finding-F1-gamekey-keycodes.txt` 方法②；`—` = 该键在 UCKeyTranslate 下无字符，属正常情形，见下）。

| 键 | ❌ 错误值（ASCII/VK） | 系统实际收到 | ✅ 正确值（CGKeyCode） | kVK 常量 |
|---|---|---|---|---|
| W | 87 | `5`（小键盘 5） | **13** | `kVK_ANSI_W` |
| A | 65 | `.`（小键盘小数点） | **0** | `kVK_ANSI_A` |
| S | 83 | `1`（小键盘 1） | **1** | `kVK_ANSI_S` |
| D | 68 | （无字符） | **2** | `kVK_ANSI_D` |
| F | 70 | （无字符） | **3** | `kVK_ANSI_F` |
| E | 69 | `+` | **14** | `kVK_ANSI_E` |
| Space | 32 | **`u`** | **49** | `kVK_Space` |
| ESC | 27 | `-` | **53** | `kVK_Escape` |
| Q | 81 | `=` | **12** | `kVK_ANSI_Q` |
| R | 82 | 0 | **15** | `kVK_ANSI_R` |
| M | 77 | （无字符） | **46** | `kVK_ANSI_M` |
| B | 66 | （无字符） | **11** | `kVK_ANSI_B` |
| T | 84 | `2` | **17** | `kVK_ANSI_T` |
| F1 | 122 | （同值） | **122** ✅ 本来就对 | `kVK_F1` |
| F2 | 120 | （同值） | **120** ✅ 本来就对 | `kVK_F2` |
| F4 | 118 | （同值） | **118** ✅ 本来就对 | `kVK_F4` |
| Shift | 160 (0xA0) | （无字符） | **56** | `kVK_Shift`（Left Shift） |
| Ctrl | 162 (0xA2) | （无字符） | **59** | `kVK_Control`（Left Control） |
| 1 | 49 | （无字符） | **18** | `kVK_ANSI_1` |
| 2 | 50 | `\`` | **19** | `kVK_ANSI_2` |
| 3 | 51 | （无字符） | **20** | `kVK_ANSI_3` |
| 4 | 52 | （无字符） | **21** | `kVK_ANSI_4` |
| 5 | 53 | （无字符） | **23** | `kVK_ANSI_5` |
| 6 | 54 | （无字符） | **22** | `kVK_ANSI_6` |
| 7 | 55 | （无字符） | **26** | `kVK_ANSI_7` |
| J | 74 | （无字符） | **38** | `kVK_ANSI_J` |
| K | 75 | `/` | **40** | `kVK_ANSI_K` |
| L | 76 | （无字符） | **37** | `kVK_ANSI_L` |
| Z | 90 | （无字符） | **6** | `kVK_ANSI_Z` |
| X | 88 | 6 | **7** | `kVK_ANSI_X` |
| C | 67 | `*` | **8** | `kVK_ANSI_C` |
| V | 86 | 4 | **9** | `kVK_ANSI_V` |
| N | 78 | `-` | **45** | `kVK_ANSI_N` |
| G | 71 | （无字符） | **5** | `kVK_ANSI_G` |
| H | 72 | （无字符） | **4** | `kVK_ANSI_H` |
| I | 73 | （无字符） | **34** | `kVK_ANSI_I` |
| Y | 89 | 7 | **16** | `kVK_ANSI_Y` |
| U | 85 | 3 | **32** | `kVK_ANSI_U` |

**合计：38 项中 35 项错误**，只有 `F1=122 / F2=120 / F4=118` 三项本来就对（功能键的 `kVK_F*` 恰好与 ASCII 无冲突）。

> ⚠️ **易混点（务必注意）**：修复后 `U = 32`，而旧表的 `Space = 32`——**同一个数字在修前/修后指向完全不同的键**。查历史提交或旧笔记时不要直接套数字。
> ⚠️ **「无字符」不是失败**：修饰键（Shift/Ctrl）与功能键在 `UCKeyTranslate` 下本来就翻译不出字符（`ControlEngine` 的 `gameKeyToKeyCode` 缺陷记录注释；`LLMSelfTest` 明确将其标注为"正确情形而非失败"），判定这些键要看 `kVK_*` 常量而非 Unicode 翻译。

### 8.5 三重独立取证（可复核）

原始输出存档：`verify/evidence-llm/finding-F1-gamekey-keycodes.txt`。

| # | 方法 | 命令/入口 | 结果 |
|---|---|---|---|
| ① | Carbon 权威常量对照 | `swiftc keymap2.swift && ./keymap2`（`/tmp/ctrl_probe/keymap2.swift`） | 产品表 vs `kVK_*` → **不匹配 35 / 38 项** |
| ② | 事件投递实测：注入后抓回读翻译 | `./unicap`（post `virtualKey=N` 到 `.cghidEventTap`，CGEventTap 抓回读 Unicode） | 注入 87 → 得到 `"5"`；注入 **13 → 得到 `"w"`**（对照组） |
| ③ | 系统键盘布局翻译 | `TIS` / `UCKeyTranslate` | 87 翻译为 `5` |
| ④ | 回归入口（修复后新增） | `./AuroraDriveUI --control-selftest` | 断言每个键的 Unicode 翻译；`LLMSelfTest`（"F1 键码表回归"） |

- **证据与被验版本的可追溯性**：evidence 文件记录的文件指纹 `8e9c935f…73eefd3`，经 `git show 2c0459a^:Sources/AuroraDrive/Control/ControlEngine.swift | shasum -a 256` 实测**完全一致**——即该证据确实是对**修复前**版本的取证（2026-10-07 复核）。修复后的当前 HEAD 版本 SHA-256 为 `f1bf2118…bd8dad`。
- **③ 与 ② 同为"读翻译"，独立性有限**（同属 `UCKeyTranslate` 语义域），**① 才是与系统无关的权威判据**——此处如实标注，不夸大成"三条完全独立链路"。

### 8.6 修复内容与验证

- **改动**：`gameKeyToKeyCode` 全表（38 条）+ `GameKey` 枚举注释 + 新增的缺陷记录注释块。**未改动**注入机制本身（`postKeyEvent`、`.hidSystemState`、`.cghidEventTap` 投递语义全部原样）。
- **提交**：`2c0459a`（2026-10-06，`feat(AI助手): 真对话 + 自主按键 + 自主调工具（7渠道聚合 + 降级链 + 30工具挂载）`）——修复与 AI 助手施工在**同一个提交**内落地（`git log -S".w: 13, .a: 0" -- Sources/AuroraDrive/Control/ControlEngine.swift` 实测）。
- **验证**：`--control-selftest` 四证据链（权限 / 计数 / 自建 tap / NSEvent）逐键断言 Unicode 翻译；`LLMSelfTest.swift`、`LLMSelfTest.swift`、`LLMSelfTest.swift` 均引本缺陷为回归对象。
- **回归矩阵（提交信息自述，本次未独立复跑）**：A1 99/0 · A2 32/0 · A3 146/0 · 端到端 9/0 · 4 回归 EXIT=0。**「未验证」提示**：以上数字取自提交信息与源码注释，本轮文档复核**未在真机重跑自检**（本机无游戏）；如需权威结论请重跑 `./AuroraDriveUI --control-selftest`。

### 8.7 AI 工具面排除 F1–F12（macOS 系统功能键）

**结论**：底层 `GameKey` 枚举**保留** `f1/f2/f4`（人类操作路径可能仍需要），但 **AI 工具面（ToolRegistry）主动过滤掉它们，模型看不到、也选不了 F 键**。

- **过滤实现**：`ToolRegistry.gameKeyNames`（`Agent/ToolRegistry.swift`）——判据 `n.count >= 2 && n.first == "F" && n.dropFirst().allSatisfy(\.isNumber)`，命中即剔除；**保留 `"F"` 交互键**（rawValue 恰为 1 个字符，不命中判据，见 `gameKeyNames` 注释）。
- **过滤覆盖的三个工具**：`press_key`、`hold_key`、`release_key`——三者的 `key.enum` 全部取自 `gameKeyNames`，描述文案里的"可用键"取自 `gameKeyListText`。**注意键名解析 `resolveGameKey` 走的是 `gameKeyAliases`（由 `GameKey.allCases` 构造，即 F 键在其中）**——即模型若硬造 `"f1"` 参数字符串，schema 层会被 `enum` 挡下；`enum` 是主要防线（**这是设计意图的推断，未逐条实测越权路径**）。
- **为什么排除（源码理由，见 `ToolRegistry.gameKeyNames` 上方注释）**：macOS 上 F1–F12 默认是**系统功能键**（F1/F2 亮度、F3 调度中心、F4 聚焦、F5 听写、F10–F12 音量）；除非用户在「系统设置 → 键盘」勾选「将 F1、F2 等键用作标准功能键」，否则 `CGEvent` 发过去只会触发**系统动作**（改亮度 / 弹窗口），**游戏进程根本收不到**——对 AI 来说是"按了但没作用于游戏"的**假能力，会骗到模型**。
- **根因溯源**：`GameKey.f1/f2/f4` 的注释写「异环 HUD 功能热键（实测 F3=卡布罗集市 F4=活动页）」，那是**照抄 MaaNTE（Windows 版）**的结论——Windows 上 F 键是普通功能键，游戏能收；**macOS 不是一回事**（`ToolRegistry.swift`）。
- **提交**：`d9675ab`（2026-10-06，`fix(AI工具面): 排除 F1–F12 —— macOS 系统功能键不该暴露给 AI`）。
- **自检断言（`Agent/LLMSelfTest.swift`）**：
  - `LLMSelfTest.swift`「press_key schema 的 key enum = 全部键 − F1–F12」；
  - `LLMSelfTest.swift`「press_key 不暴露 F1–F12」（`functionKeys.isDisjoint(with: Set(enumValues))`）；
  - `LLMSelfTest.swift`「press_key 仍保留 F 交互键」（`Set(enumValues).contains("F")`）；
  - 提交信息记：A3 工具自检 144 → **146 通过 / 0 失败**（新增两条 F 键断言）；后续 `22a6604` 又增至 150。
- **`--tool-selftest` 工具总数复核**：`LLMSelfTest.swift` 断言「工具条目总数 = 30」（技能18 + 键位4 + 鼠标3 + 文本1 + 搜索2 + 观察2）——**与 F 键过滤无关，排除 F 键不减少工具条目数**。

### 8.8 本节自检清单（哪些已核 / 哪些未核）

| 论断 | 状态 |
|---|---|
| `gameKeyToKeyCode` 现 38 条全为虚拟键码、35 项修复 | ✅ 逐条读 `ControlEngine.swift` 的 `gameKeyToKeyCode` 核对 |
| `KeyMap` 本来正确、未被本次修复触碰 | ✅ 逐条读源码 + `git diff HEAD~5..HEAD` 确认该区块无改动 |
| 旧表 35/38 错误、`87→"5"`、`13→"w"` | ✅ 源码缺陷记录注释 + evidence 文件原始输出（含文件指纹与 `2c0459a^` 实测哈希一致） |
| 修复落地于提交 `2c0459a`、F 键排除落地于 `d9675ab` | ✅ `git log -S` 实测 |
| 四个哈希/证据可追溯 | ✅ 2026-10-07 `shasum -a 256` 实测 |
| 自检回归数字（99/0、32/0、146/0、9/0） | ⚠️ **未验证**——取自提交信息/源码注释，本轮未真机复跑 |
| `--control-selftest` 的"四证据链"具体四类 | ⚠️ **未验证**——四类名称取自 `AuroraDriveApp.swift` 的 `--control-selftest` flag 登记注释与 `LLMSelfTest` 中 `runControl` 的分段注释，`runControl` 内部未逐行通读 |
| 绕过 `enum` 硬造 `"f1"` 字符串是否会被 `resolveGameKey` 放行 | ⚠️ **未验证**——代码路径推断为"schema enum 挡下"（见 8.7），未实测 |
| `--control-selftest` 的"四证据链"注释行号 | ✅ 2026-10-17 实测：四类名称出自 `AuroraDriveApp.swift` 的 `--control-selftest` flag 登记注释——原文「`--control-selftest` 按键四证据链（**权限/计数/自建tap/NSEvent**）」（**四类内部实现仍未逐行通读**，见上行）；`LLMSelfTest` 亦自述本缺陷（"旧表 87 → \"5\" 是坏的，新表 13 → \"w\" 是对的"） |

---

## 附：符号锚点表（按名称定位，可直接在源码中搜索复核）

**ControlEngine.swift**

| 符号 | 说明 |
|---|---|
| 文件头注释（按键注入引擎 CGEvent） | 声明需要辅助功能权限 |
| `@Observable final class ControlEngine` | 类声明，`@unchecked Sendable` |
| `enum Action` | 语义按键动作（throttle/brake/steerLeft/steerRight/handbrake/boost） |
| `struct KeyMap` | 语义动作 → macOS 键码，六项默认键码 |
| `keyCode(for action: Action)` | switch 语义动作取键码 |
| `var keyMap` | 当前按键映射，可运行时修改 |
| `hasAccessibilityPermission` | 是否拥有辅助功能权限（private(set)） |
| `heldKeys` | 当前按住的键集合，@Observable |
| `postedEventCount` | 累计成功注入的键盘事件总数，@ObservationIgnored |
| `digestMode` / `digestedEventCount` / `globalDigest` | 消化模式开关与被消化计数、进程级开关 |
| `keyRefreshInterval` / `lastKeyRefreshAt` | 按住键重发节流间隔与上次重发时刻 |
| `eventSource` | lazy CGEventSource，`.hidSystemState` |
| `checkPermission()` | 纯查询辅助功能权限，不弹窗 |
| `requestAccessibilityPermission()` | 请求辅助功能权限（弹窗 + 登记） |
| `openAccessibilitySettings()` | 打开辅助功能设置面板 |
| `requestScreenRecordingPermission()` | 申请屏幕录制权限（弹窗 + 登记 TCC） |
| `openScreenRecordingSettings()` | 打开屏幕录制设置面板 |
| `requestScreenRecordingPermissionOnStartup()` | 启动期申请版本，供 AppDelegate 调用 |
| `press(_:duration:)` | 短按：按下 → usleep → 释放 |
| `hold(_:)` | 持续按住，已按住则跳过 |
| `release(_:)` | 释放一个键，幂等 |
| `refreshHeldKeys()` | 周期重发所有按住键的 keyDown |
| `releaseAll()` | 无条件释放全部映射键并清表 |
| `releaseAIHeldKeys(preserving:)` | 只清理本进程拥有的键，保留物理键 |
| `forceReleaseAIHeldKeys(preserving:targetPID:)` | 绕过消化直发 keyUp 的账本清理 |
| `releaseAllIfNeeded()` | 节流版全量释放（同秒内跳过） |
| `postKeyEvent(keyCode:keyDown:autorepeat:bypassDigest:targetPID:)` | 底层 CGEvent 注入唯一点 |
| `enum GameKey` | 游戏键枚举，按功能分组 38 个键 |
| `gameKeyToKeyCode` | GameKey → CGKeyCode 完整映射表（38 条） |
| `keyCode(for key: GameKey)` | 查表，未知键返回 nil |
| `pressGameKey` / `holdGameKey` / `releaseGameKey` | 游戏键注入三件套 |
| `releaseAllGameKeys()` | 批量释放所有游戏键所在键码 |
| `typeText(_:)` | Unicode 文本注入当前焦点输入框 |
| `isHeld(_:)` / `heldCount` | 语义键/游戏键是否按住、按住键数量 |

**跨文件锚点（均可在对应文件内按符号名搜索）**

| 符号 | 所在位置 |
|---|---|
| `startDriving()` / `stopDriving()` | `App/AuroraDriveApp.swift` |
| 观测模式 `AURORA_OBSERVE_ONLY` / `controlDisabled` / 权限守卫 | `AuroraFlags.swift`、`App/AuroraDriveApp.swift` |
| `isDriving` 心跳镜像 `engineIsDriving` | `App/AuroraDriveApp.swift`、`Core/EngineClient.swift` |
| `DriveState.tick()` / 待机分支 | `App/AuroraDriveApp.swift` |
| `inferenceEngineV2.infer` / `inferenceEngine.infer` / `assistEngine.infer` | `App/AuroraDriveApp.swift` |
| `yoloEngine.infer` / `yolopxEngine.infer` / `updateMotionPipeline` | `App/AuroraDriveApp.swift` |
| `commandOf` / `v2CommandOf` | `App/AuroraDriveApp.swift` |
| `degradeStm.update()` / 档位选择控制量 | `App/AuroraDriveApp.swift`、`Agent/DegradeStateMachine.swift` |
| `mayInjectKeys` / `applySpeedLimitBrake()` / `releaseSpeedLimitBrake()` | `App/AuroraDriveApp.swift` |
| `laneKeepTiers` 声明 / 档位门 / `releaseAllEveryTick` | `App/AuroraDriveApp.swift`、`Core/AuroraFlags.swift` |
| `readPose()` / `locatorScoreForTier` | `App/AuroraDriveApp.swift` |
| `segmentDecisionForRule()` / 地图段覆盖 / `laneFallback` | `App/AuroraDriveApp.swift` |
| `benchSuppressAllInjection` / `expertMode` / `controlDisabled` | `App/AuroraDriveApp.swift` |
| `applyCommand(currentCommand)` 调用与实现 | `App/AuroraDriveApp.swift` |
| `applyLaneAdvice`（文件级全局函数） | `App/AuroraDriveApp.swift` |
| 卡死检测（`speedValid` / 人工介入横幅） | `App/AuroraDriveApp.swift` |
| 脱困 / `fallbackGuard` 删除取证注释 | `App/AuroraDriveApp.swift` |
| `--control-selftest` flag 登记 | `App/AuroraDriveApp.swift` |
| 心跳统计日志（driving / da ll / 降级 / 耗时） | `Core/EngineMain.swift` |
| `heartbeatCount % 5 == 0` / `maskSeq` 协议 offset / 声明 | `Core/EngineMain.swift` |
| `tickOnce()` / `st.tick()` / 掩码发布段 | `Core/EngineMain.swift` |
| `pauseDriving()` / `performShutdown()` | `Core/EngineMain.swift` |
| 看门狗（pauseDriving / 3s 窗口）/ `idleExitWorkItem` | `Core/EngineMain.swift` |
| `da`/`ll` 输出头 / `extractMask` / EMA / `isDegraded` | `Inference/YolopxEngine.swift` |
| 降级阈值（lane 下限/上限、drivable 下限/上限） | `Inference/YolopxEngine.swift` |
| `positiveCount` / `isDegraded` / `inferenceCount` / `lastLatencyMs` | `Inference/YolopxEngine.swift` |
| `RoutePlan` / `RoutePlanner.route` / 堆 / 拐弯惩罚 / `fromPixel` | `App/RouteGraph.swift` |
| `DegradeStateMachine.update` / `forceRule` / `sportOverride` / `degradeHealth` / `recoverHysteresis` / `modeLock` | `Agent/DegradeStateMachine.swift` |
| `gameKeyNames` / `gameKeyListText` / `gameKeyAliases` / `resolveGameKey` | `Agent/ToolRegistry.swift` |
| 键位三工具（press/hold/release_key） | `Agent/ToolRegistry.swift` |
| F 键排除理由 / 根因注释 | `Agent/ToolRegistry.swift` |
| `runControl` 四证据链 / F1 回归断言 / 工具总数 30 | `Agent/LLMSelfTest.swift` |
| press_key schema 三断言 | `Agent/LLMSelfTest.swift` |
| 小地图路网折线 / 任务卡片弯道距离 / 规划入口 | `App/MissionConsole.swift` |
| `move`/`click`/`doubleClick`/`scrollWheel`/`screenPoint(fromPixel:scale:)` | `Control/MouseController.swift` |
| 键盘全局监听 / auto-repeat 过滤 | `Control/KeyboardMonitor.swift` |
| `ControlCommand` / 字段 / `.idle` / 脱困删除注记 | `Control/EscapeController.swift` |
| `keyRefreshHz` / `laneKeepTiers` / `releaseAllEveryTick` | `Core/AuroraFlags.swift` |
