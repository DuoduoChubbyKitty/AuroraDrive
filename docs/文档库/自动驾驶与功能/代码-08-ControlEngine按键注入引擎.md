# 代码-08 ControlEngine 按键注入引擎

> 覆盖源文件：`Sources/AuroraDrive/Control/ControlEngine.swift`（**622 行，2026-10-06 `wc -l` 复测**；历史版本 373→550 行，行号以 622 行版为准，全行号 2026-10-06 逐条回读核实）。基于当前仓库逐单元编写。

## 一、语义动作、KeyMap 与 HID 事件源（第 1–140 行）

**类声明（第 31–32 行）**：`@Observable final class ControlEngine: @unchecked Sendable`——通过 CGEvent 向系统**全局键盘队列**注入按键事件，控制游戏（WASD + 空格 + Shift）。需要"辅助功能"权限（Accessibility）。@Observable 让 SwiftUI 自动观察按键状态变化（键盘可视化条用）。文件头（:15-18）自述："按键注入引擎（CGEvent）……需要'辅助功能'权限"。

**`Action`（enum，第 35–42 行）**——按键动作枚举（**语义化，与具体键位解耦**）：

| case | 语义 |
|---|---|
| `throttle` | 油门（前进） |
| `brake` | 刹车（后退） |
| `steerLeft / steerRight` | 左转 / 右转 |
| `handbrake` | 手刹（空格） |
| `boost` | 极速（Shift） |

**`KeyMap`（struct，第 47–66 行）**——按键映射：语义动作 → macOS 键码。键码参考（HID Usage Table → macOS virtualKey）：**W=13, A=0, S=1, D=2, 空格=49, LeftShift=56, RightShift=60**（注释在 :44-46）。`keyCode(for:)`（:56-65）：switch 语义动作取键码。

| 字段 | 默认值 | 键 |
|---|---|---|
| `throttle` | 13 | W |
| `brake` | 1 | S |
| `steerLeft` | 0 | A |
| `steerRight` | 2 | D |
| `handbrake` | 49 | 空格 |
| `boost` | 56 | Left Shift |

`func keyCode(for action: Action) -> CGKeyCode`（56–65 行）：switch 语义动作取键码。

- `var keyMap = KeyMap()`（69 行）——当前按键映射，**可运行时修改**

**权限与按键状态（第 71–80 行）**：

- `hasAccessibilityPermission`（private(set)，:72）——是否拥有辅助功能权限
- `heldKeys: Set<CGKeyCode>`（private(set)，@Observable，:76）——当前按住的键集合，键盘可视化条观察此属性；每次按下/释放都更新，SwiftUI 自动刷新键帽颜色
- `postedEventCount: Int`（**@ObservationIgnored**，:80）——累计成功注入的键盘事件总数（诊断用：判断事件流是否持续产生）；标记 @ObservationIgnored 因为每帧递增，不应触发 SwiftUI 重绘

**按住键重发节流（`keyRefreshInterval`，第 82–126 行）**——`AURORA_KEY_REFRESH_HZ`（`AuroraFlags.swift:271`，默认 0=关闭）换算成间隔（:121-122）；关闭时**与改动前逐帧一致**（每控制周期 30Hz 重发）。注释（:87-115）记录了启用节流的动机（严格 33.3ms 周期的机器特征）与风险（重发不足会「UI 显示 W 已按住，游戏纹丝不动」，见 refreshHeldKeys 历史事故），**默认关闭、启用须真机验证**；抖动 ±25%（:110-112）只挪事件时刻、不降频。

**`eventSource`（lazy 闭包，第 128–140 行）——本引擎最关键的实测结论：**

```swift
private let eventSource: CGEventSource? = {
    return CGEventSource(stateID: .hidSystemState)
}()
```

- **必须用 `.hidSystemState`（对应 C API 的 kCGEventSourceStateHIDSystemState）**：实测目标游戏（异环 NTE）的输入层只读取 HID 系统状态层的键盘事件
- `.combinedSessionState`（曾用）：实测对该游戏无效——该层的合成事件会被系统 UI 正常接收（键盘可视化条会亮、系统提示音会响），**但游戏输入层直接忽略**，表现为「UI 显示已输出 W，但游戏纹丝不动」
- `.privateState`：更私有的状态层，游戏更加读不到，**禁止使用**
- `.hidSystemState`：事件进入 HID 系统状态层，与真实物理键盘同层，配合 `.cghidEventTap` 投递，即为已验证可突破该游戏反作弊拦截的方案

**权限函数（第 142–210 行）**：

- `checkPermission() -> Bool`（149–172 行）：`AXIsProcessTrustedWithOptions(nil)`——**P0 修复 (2026-09-07)**：字符串字面量 `"kAXTrustedCheckOptionPrompt"` 不是有效的 CFString 常量，导致 options 字典无效 → 收到 nil 等价参数 → 访问空指针崩溃（**EXC_BAD_ACCESS at 0x8**）。正确做法是直接传 nil（不弹窗）——**2026-09-30 更正（:161-168）**：传 nil 时**只查询、绝不弹窗**，故拆分为两个方法：本方法保持"纯查询"（`press`/`hold` 的高频重试路径绝不能弹窗），`requestAccessibilityPermission()` 专用于一次性请求
- `requestAccessibilityPermission() -> Bool`（190–203 行）：`kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true` 传入触发**系统授权弹窗 + 把本程序登记进辅助功能列表**（:194-195）；被拒时幂等地 `openAccessibilitySettings()`（:200）。背景（:184-187）：修复前全项目只查询不请求 → 程序永远不进辅助功能列表 → 所有注入被系统静默丢弃
- 无权限时注入事件会被系统**静默丢弃**（:145 注释）
- `openAccessibilitySettings()`（206–210 行）：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` URL → `NSWorkspace.shared.open`（引导用户授权）

## 一·五、屏幕录制权限（第 212–294 行，2026-09-30 新增）

**为什么放在 ControlEngine**（:235-238）：与辅助功能权限是同一职责的两项（都是「注入/观测所需的一次性系统授权」），放一起便于对照维护。

- `requestScreenRecordingPermission() -> Bool`（246–257 行）：`CGRequestScreenCaptureAccess()` 弹系统授权框并登记进 TCC 列表（:250）；被拒时幂等打开设置面板（:254）。⚠️ 首次调用几乎必然返回 false，且勾选后通常要重启 App 才生效（:243-244）
- `openScreenRecordingSettings()`（260–264 行）：打开「屏幕录制」面板
- `static requestScreenRecordingPermissionOnStartup()`（291–294 行）：**启动期版本**（供 AppDelegate 调用），先 `CGPreflightScreenCaptureAccess()` 预检、已授权则完全静默（:288-289）。**它解决的死锁**（:266-281）：`captureEngine.start()` 只在 `startDriving()` 里被调，而 `startDriving()` 开头有辅助功能守卫——没辅助功能权限 → 截屏引擎永不启动 → 屏幕录制申请永不触发。把申请从 startDriving 解耦挂到 `applicationDidFinishLaunching`，「看画面」不再依赖「能按键」
- 背景（:216-228）：此前全项目只有 `CGPreflightScreenCaptureAccess()` 纯查询（EngineMain.swift:632、AuroraDriveApp.swift:158），`CGRequestScreenCaptureAccess()` **零调用** → 系统设置列表里根本不会出现本 App

## 二、按键注入五件套与 refreshHeldKeys（第 296–399 行）

**五个注入方法（语义动作版）：**

| 方法 | 行号 | 行为 |
|---|---|---|
| `press` | 301–311 | 按下并立即释放（短按）；`usleep(duration × 1_000_000)` 短暂等待后释放（模拟真实按键时长）；无权限时先 checkPermission 再 return |
| `hold` | 315–325 | 持续按住不释放（直到 release/releaseAll）；**已按住则跳过**（`heldKeys.contains(keyCode)` 防重复按下）；无权限 guard |
| `release` | 329–334 | 释放一个键；`heldKeys` 不含则跳过（幂等） |
| `refreshHeldKeys` | 362–376 | **刷新所有按住键的按下状态（每个控制周期调用一次）**——见下面详解 |
| `releaseAll` | 381–394 | 释放所有按住的键（停止自动驾驶时调用，避免按键卡住） |

**`refreshHeldKeys()`（第 362–376 行）——为什么必须有这一步（336–361 行注释，本引擎的核心机制）：**

- **真实物理键盘**按住不放时，键盘硬件会持续向系统上报按键状态，系统据此持续产生带 autorepeat 标记的 keyDown 事件流。游戏的输入状态机依赖这个事件流判断"键还按着"
- **CGEvent 注入是「一次性事件」**：hold() 只在按下瞬间发一个 keyDown，之后若控制量保持稳定（例如 E2E 模型在直道恒定输出 throttle=0.98），就再也不会有任何键盘事件产生——系统键盘状态虽然是"按住"，但游戏从未收到过属于它的事件，表现为「UI 显示 W 已按住，游戏纹丝不动」
- 因此**持续按住的键必须按周期重发 keyDown**。调用频率跟随控制主循环（30Hz），与 macOS 默认按键重复率同量级
- **关键：重发的 keyDown 必须是「新按下」语义（autorepeat = false）**——带 autorepeat 标记的事件会被该游戏的输入层忽略（它只认新按下），导致稳定输出档位（如 M9）下只有 auto-repeat 事件流、游戏完全不动。已验证方案（V1）同样是每次都发新按下，此处与之对齐

```swift
func refreshHeldKeys() {
    guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }
    if Self.keyRefreshInterval > 0 { /* 节流+抖动（默认关闭，:365-371） */ }
    for keyCode in heldKeys {
        postKeyEvent(keyCode: keyCode, keyDown: true)   // 全部重发「新按下」
    }
}
```

**`releaseAll()`（第 381–394 行）**：**无条件对所有映射键发释放事件**——即使本会话没记录按过（例如上次进程异常退出残留的系统级卡键），也主动清掉，保证系统键盘状态干净。六个映射键全部 post keyDown=false（:382-389），然后 `heldKeys.removeAll()`（:390）；末尾记录 `lastFullReleaseAt`（:393）供节流版判断。

**`releaseAllIfNeeded()`（第 401–441 行，2026-10-01 阶段4 性能折叠）**：节流版全量释放。背景（:403-411）：生产 tick 分段剖析实测 `tick.inject` p50=0.15ms 占整帧 71%——根因是 `expertMode || controlDisabled` 分支每帧无条件对 6 键各发一次 CGEvent。语义：有按住键 → 必须完整清扫（:432-436）；无按住键 → 同一秒内已清扫过就跳过（:437-440）。安全边界（:418-426）：1 秒内不可能凭空出现新的系统级残留；`applyCommand` 走 `release(_:)`、停止驾驶走 `releaseAll()`，都不受影响。回退开关 `AURORA_RELEASE_ALL_EVERY_TICK=1`（消费端 AuroraDriveApp.swift:5437-5438、AuroraFlags.swift:283）。

**`postKeyEvent(keyCode:keyDown:autorepeat: Bool = false)`（private，第 453–476 行）**——底层 CGEvent 注入：

1. `CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown)`——nil eventSource 时使用默认源；创建失败打印并 return（:455-462）
2. 仅在显式要求时 `event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)`（:467-469）——**目标游戏（异环 NTE）会忽略带 auto-repeat 标记的 keyDown，因此所有实际调用路径均使用默认 false**（每次都发「新按下」，:449-452/:464-466）
3. `event.post(tap: .cghidEventTap)`——**tap: .cghidEventTap 注入到硬件事件层（最底层，游戏必响应）**；`postToPid` 注入到特定进程更精确但需要 PID（:471-473 仅注释提及未使用），这里用全局注入对所有前台应用生效
4. `postedEventCount &+= 1`（wrapping 递增，诊断用，:475）

## 三、GameKey 游戏键位、typeText 与状态查询（第 478–622 行）

**`GameKey`（enum: String, CaseIterable，第 482–531 行）**——游戏常用键枚举（**MaaNTE 实际使用的所有键**，出处标注见文件头 :5-13 品牌澄清注释），CGKeyCode 值来自 macOS HID Usage Table。**按功能分组 38 个键**：

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

**`gameKeyToKeyCode`（private static let，第 534–546 行）**：GameKey → CGKeyCode 完整映射表（38 条）。

**`keyCode(for key: GameKey) -> CGKeyCode?`（第 549–551 行）**：查表，未知键返回 nil。

**游戏键注入三件套（第 554–575 行）**——与语义动作版同构，全部走 `postKeyEvent`（所以同样是 `.hidSystemState` + `.cghidEventTap` + 新按下语义）：

- `pressGameKey(_ key: GameKey, duration: TimeInterval = 0.05)`（:554-559）：短按（keyDown → usleep → keyUp）
- `holdGameKey(_ key: GameKey)`（:562-567）：持续按住（已按住跳过，insert heldKeys）
- `releaseGameKey(_ key: GameKey)`（:570-575）：释放（heldKeys 不含跳过）

**`releaseAllGameKeys()`（第 578–585 行）**：**批量释放所有游戏键**——`heldKeys.filter { gameKeyCodes.contains($0) }` 只释放游戏键部分（**不影响驾驶语义键的追踪**，但清理所有 held 状态）；逐个 post keyDown=false + `heldKeys.subtract(toRelease)`。

**`typeText(_ text: String)`（第 590–602 行）**——文本输入（**聊天刷屏类技能用**）：

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

- Unicode 字符串注入到**当前焦点输入框**——**调用方需先自行把焦点切到目标**（如按 F/回车打开游戏聊天框），并受游戏窗口护栏约束（:587-589 注释）
- 实现：virtualKey 0 的 keyDown/keyUp 各带一份 UTF16 字符串（`keyboardSetUnicodeString`，:597-598），成对 post（`postedEventCount &+= 2`，:601）

**状态查询（第 604–622 行）**：

- `isHeld(_ action: Action) -> Bool`（:607-610）：语义键是否按住（查 heldKeys）
- `isHeld(_ key: GameKey) -> Bool`（:613-616）：游戏键是否按住（键码 nil 返回 false）
- `heldCount: Int`（:619-621）：当前按住的键数量

**ControlEngine 文档至此完整**（622 行全覆盖：语义动作与 KeyMap → 屏幕录制权限 → 注入五件套与 refreshHeldKeys/releaseAllIfNeeded → GameKey 与 typeText → 状态查询）。

## 四、★ 驾驶控制全链路：RoutePlan 不直接产生按键（2026-10-06 核实）

> 本节为全链路总览，各环节的详细展开见 [代码-21-RuleController](代码-21-RuleController规则控制器.md)、[代码-34-DriveSegmentController](代码-34-DriveSegmentController驾驶分段控制器.md)、[代码-35-RoadCornerGuide](代码-35-RoadCornerGuide弯道先验.md)。

**核心结论（已逐条查证）**：**RoutePlan（A* 结果）不直接产生任何按键**。它只是地图折线 + 距离信息，消费点全部在显示/提示层；真正进入 ControlEngine 的控制量来自「感知 → 降级状态机 → ControlCommand → applyCommand」这条链。

1. **路线规划（显示/提示层）**：`RoutePlanner.route()` A* + 拐弯惩罚（`App/RouteGraph.swift:404-540`，手写二叉堆 :427-456，拐弯惩罚 `cost = 边长 + W×(角度/90°)` :492-495），输出 `RoutePlan{distanceMeters, turns, segments, points, …}`（结构体 `RouteGraph.swift:352-369`）。像素入口 `route(graph:fromPixel:toPixel:)` :543-553。触发点：`App/MissionConsole.swift:5829-5830`（任务面板规划）与 `App/AuroraDriveApp.swift:4259-4261`（遮罩规划）。
2. **RoutePlan 的实际消费（均为显示层）**：
   - 小地图画路网折线 — `App/MissionConsole.swift:3912-3942`（`plan.points` 逐点 `addLine`）；
   - 任务卡片弯道距离（米）— `App/MissionConsole.swift:627-635`（`state.routePlan?.distanceMeters`）与 :6294-6295（夹具日志）。
   - **未验证**：未发现 `routePlan.points` 被直接喂给转向控制。真实路径引导走的是另一条独立链路：`RoadCornerGuide`（`road_corners_v3b.json` 打点集，**非 RoutePlan**）+ `DriveSegmentController`（见第 5 步）。若 RoutePlan 未来要接管方向，目前是断开的（未验证有其它接线）。
3. **感知**（`DriveState.tick()`，`App/AuroraDriveApp.swift:6384` 起，30Hz）：M9 端到端主驾 `inferenceEngine.infer` :6585；第二套驾驶模型 `assistEngine.infer` :6587；YOLO 检测 :6593-6596；YOLOPX 三合一 :6599；光流+运动预测 `updateMotionPipeline` :6607。
4. **决策**：模型输出 → `ControlCommand`（`commandOf` :6611-6617）；降级状态机 `degradeStm.update()` :6686-6694 决定档位（`Agent/DegradeStateMachine.swift:74-139`：e2e→yolo→rule 三档梯子，健康度 <0.65 降级 :118/:124，滞回 +0.15 恢复 :114，极速模式强制 e2e :101-104，`forceRule` 最高优先 :92-97）。档位选择控制量 :6868-6881（e2e=M9 :6871 / yolo=assist :6875 / rule=`ruleController.decide(detections:)` :6879）。
5. **车道保持 / 地图分段覆盖**（门 = `Self.laneKeepTiers`，:6917；声明 :5426-5428 默认 `rule,yolo`，`AURORA_LANEKEEP_TIERS` 可改，回退值见 `AuroraFlags.swift:280`/`:456`）：
   - 分段优先：`readPose()`（定位位姿，**`locatorScore >= 0.4` 门** :7271-7279；新鲜度档位分 :7262-7269 只有 live=1.0 过门槛）→ `segmentDecisionForRule()` :7285-7301（`RoadMapPrior.isOnRoad` + `DriveSegmentController.update`）→ 地图段/回正段用 `mapSteer` **覆盖**视觉转向并压油门 :6930-6940。弯道点来自 `RoadCornerGuide.cornerAhead`（`Agent/DriveSegmentController.swift:157`），**不是 RoutePlan**。
   - 视觉兜底：`laneFallback.evaluate(laneMask:drivableMask:...)` 消费 YOLOPX 的 da/ll 掩码 :6946-6949 → `applyLaneAdvice`（文件级全局函数，:7618 起；转向 ±0.25 限幅+置信度加权、油门只压不抬、刹车只加不减）。
6. **按键注入**：`applyCommand(currentCommand)` :7034（在 `benchSuppressAllInjection` :7014-7016 与 `expertMode || controlDisabled` :7017-7032 两个抑制分支之后）→ `applyCommand` 实现 :7321-7350：steer 死区 ±0.1 → hold A/D（:7323-7332）；throttle>0.3 hold W、brake>0.3 hold S（互斥，:7335-7344）；末尾 `refreshHeldKeys()` :7349 重发按住键。
7. **限速硬闸（优先级高于一切模型）**：`mayInjectKeys = isDriving && !expertMode && !controlDisabled` :6793；超速时 `applySpeedLimitBrake()` :6820（实现 :7201-7221：松 W/Shift + 手刹脉冲 + 不打方向 + refreshHeldKeys），刹车期间提前 return（:6839），本帧 AI 决策键全部不执行；退出时 `releaseSpeedLimitBrake()` :7230-7232 必须松空格防卡死。
8. **引擎模式差异**：UI 的 `startDriving()` 只发 "start" 命令 :5760-5769；真实 tick/注入在引擎进程 `Core/EngineMain.swift`（`tickOnce()` :884-940 调同一个 `st.tick()` :887）。UI 的 `isDriving` 是引擎心跳的镜像（:6133-6136，命令后 1s 宽限）。

## 五、driving=false 的判定条件（引擎日志 driving 字段）

日志字段来源：`Core/EngineMain.swift:823` `driving=\(EngineGlobals.state?.isDriving ?? false)`，即**引擎进程内 DriveState.isDriving**。它由以下路径写定：

- **置 true**：仅 `startDriving()` — 引擎模式发命令成功后 :5765，本地模式通过辅助功能权限守卫后 :5833。守卫 `guard controlEngine.requestAccessibilityPermission() || controlDisabled else { return }` :5822（观测模式 `AURORA_OBSERVE_ONLY=1` 强制 `controlDisabled=true` :5816-5821，可无权限启动但不注入）。
- **置 false（四条路径）**：
  1. `stopDriving()`：UI 点停止（引擎模式 :5854-5859 / 本地 :5861-5862），并 `controlEngine.releaseAll()` :5862。
  2. `EngineMain.pauseDriving()`：`st.isDriving = false` + `releaseAll()` — `Core/EngineMain.swift:1122-1134`。触发源：UI 断开（bye，:972）与**看门狗超时**（"watchdog"，:1080，重连窗口 3 秒 :1084）。
  3. 引擎自动退出 `performShutdown`（含 30 秒无人使用 idle-exit :1099-1111，任何退出路径都先 releaseAll，:1136-1148 注释与兜底）。
  4. 引擎模式下 UI 侧镜像回写：心跳 `engineIsDriving` 不一致且命令后超过 1 秒 → `isDriving = client.engineIsDriving` — `AuroraDriveApp.swift:6133-6136`。
- 注意区分：`isDriving=false` 只是停掉决策与注入主路径（tick 待机分支 :6560-6576 清空决策）；权限拒绝**不是** driving=false 的来源——被守卫挡回时 `isDriving` 根本不会被置 true（:5822-5826 直接 return）。

## 六、da / ll / maskSeq / 降级 的确切含义与计算处

统计日志出处：`Core/EngineMain.swift:823-826`（每 5 秒心跳，:808 `heartbeatCount % 5 == 0`）。

| 字段 | 含义 | 计算处 |
|---|---|---|
| `da` | **drivable area，可行驶区域掩码**。来自 YOLOPX 模型的 `da` 输出头（`out.featureValue(for: "da")` — `Inference/YolopxEngine.swift:989`），经 argmax+4×4 多数表决下采样成 `MaskGrid`（:1008-1009，`extractMask`），再做跨帧 EMA 平滑（:1049）落到 `drivableMask`（:1057）。日志值 `drivableMask.positiveCount` = 掩码网格中前景格数（`MaskGrid.positiveCount` — YolopxEngine.swift:76；日志拼接 :825） | YolopxEngine.swift:988-1011, 1049-1057 |
| `ll` | **lane line，车道线掩码**。同源的 `ll` 输出头（:990）→ `laneMask`（:1058）。日志值 `laneMask.positiveCount` :825。⚠️ 「0 格」= 车道线信号塌陷/模型未出结果；`da=0 ll=0` 常伴随 `降级=true` | 同上 |
| `maskSeq` | 掩码世代号（u64，共享内存协议 offset 80 — `EngineMain.swift:99`；`@MainActor static var` 声明 :599）。掩码指纹（前景格数+宽度哈希，:918-919）变化时 +1（:920-923），UI 据此判断掩码新鲜度；停止驾驶时清 0 并发空掩码（:931-939）。仅 `st.isDriving` 时发布掩码（:915） | EngineMain.swift:915-939 |
| `降级` | `px?.isDegraded ?? true`（:826）= YOLOPX 决策层降级总开关。计算：`laneDegraded = laneRatio < 0.002 ‖ > 0.25`；`drivableDegraded = drivableRatio < 0.02 ‖ > 0.70`；`isDegraded = laneDegraded ‖ drivableDegraded`（YolopxEngine.swift:1079-1083；阈值 :288/:291/:336/:340）；推理出错直接置 true（:1044） | YolopxEngine.swift:1070-1083 |

配套语义：`isDegraded=true` 时 `LaneFallback`（车道兜底）fail-open 不给建议（tick :6948 传入 `isDegraded` 并被 LaneFallback 内部门控）；显示层另有独立的 `laneDegraded`/`drivableDegraded` 只压暗对应图层（YolopxEngine.swift:388-400 注释）。日志其余字段：`seq`=共享内存帧序号（:823），`有帧`=是否截到画面（:823），`det`=YoloEngine 检测框数（:823），`yolopx:加载/帧数`=模型是否加载/累计推理次数（`inferenceCount`，YolopxEngine.swift:1063），`耗时`=单帧推理+NMS+掩码提取耗时（`lastLatencyMs`，YolopxEngine.swift:403/:1060）。

## 七、键鼠模拟机制与安全护栏

### 机制（合规：CGEvent 模拟输入）
- 键盘：`CGEvent(virtualKey:keyDown:)` + `event.post(tap: .cghidEventTap)` — ControlEngine.swift:453-476。事件源 `.hidSystemState`（:129-140），autorepeat 恒 false（:464-469，游戏只认「新按下」）。坐标/文本注入：`typeText` 用 `keyboardSetUnicodeString` :590-602。
- 鼠标：`CGEvent(mouseEventSource:mouseType:mouseCursorPosition:)` 同 tap 投递 — MouseController.swift:57-148（move :57-70、click :79-107、doubleClick :111-148）；滚轮 :156-173；像素→点换算 `screenPoint(fromPixel:scale:)` :181-183。
- 读屏（合规：ScreenCaptureKit 截屏）：`CaptureEngine.start()`（tick 消费帧 :6582 起）；键盘只读监听 `NSEvent.addGlobalMonitorForEvents` — KeyboardMonitor.swift:50-59（过滤 auto-repeat :51）。
- 权限面：辅助功能（注入必需，ControlEngine.swift:149-203）+ 屏幕录制（ControlEngine.swift:246-294）。
- **合规声明（红线）**：本项目硬约束为**只做读屏 + 系统事件合成**——禁止内存读取、禁止进程注入、禁止反作弊规避。以上机制均为 ScreenCaptureKit 截屏 + CGEvent 模拟输入路径；未发现内存读取/进程注入/反作弊检测规避代码（`postToPid` 仅注释提及未使用，ControlEngine.swift:471-473；`AURORA_KEY_REFRESH_HZ` 节流+抖动 :110-112 只挪事件时刻，注释自证「抖动本身不降频」）。注意 :138 注释自称该方案「可突破该游戏反作弊拦截」，这是对「游戏输入层只认 HID 层合成事件」这一兼容性事实的描述，未见任何主动对抗反作弊的代码。

### 护栏（有急停语义，无独立热键急停）
- **停止/暂停即松键**：`stopDriving()` → `controlEngine.releaseAll()`（AuroraDriveApp.swift:5861-5862）；引擎看门狗/UI 断开 → `pauseDriving` EngineMain.swift:1122-1134；30s 无人 → idle-exit 先 releaseAll :1102-1107；进程启动/开始驾驶前清残留卡键 :5829-5831。
- **专家模式**（`expertMode`）：真人物理键独占，AI 不注入 :7017-7032（物理键由 KeyboardMonitor 只读采集用于录制标签 :7170-7180）。
- **控制禁用 / 观测模式**：`controlDisabled`（`AURORA_OBSERVE_ONLY=1` 强制置真，:5816-5821）全注入路径关闭 :5817-7032（同走 :7017 分支）。
- **夹具硬开关** `benchSuppressAllInjection`：连松键事件都不发 :7014-7016。
- **限速硬闸**：超速 → 纯规则刹车（松 W/Shift + 手刹），优先于一切模型 :6785-6849；准入条件与主注入同一道 `mayInjectKeys` 门 :6793；退出必须松手刹防卡键 :7223-7232。
- **卡死保护**：连续 30s 速度≈0（需 `isDriving && speedValid`，:6669）→ 拉横幅**请求人工介入，AI 不自行挣扎** :6654-6680（用户原话与设计要点见注释）。
- **脱困已删除**：EscapeController 恢复档 2026-09-30 整体删除（EscapeController.swift:12-15），避免 AI 与用户抢控制权（tick :6974-6999 取证注释：第三视角自车入框 → 框叠加误判碰撞 → brake 即倒车抢控制权，原理不成立）。
- **车道建议单向安全**：转向 ±0.25 限幅、油门只压不抬、刹车只加不减、fail-open（:6908-6912 注释；applyLaneAdvice :7618）。
- **权限死锁防御**：屏幕录制申请从 startDriving 解耦到启动期（ControlEngine.swift:266-294）。
- **缺口（诚实记录）**：未发现独立的「急停热键」（panic key）；急停语义由 UI 停止按钮 + 上述被动护栏构成（未验证有其它入口）。

## 附：一处命名陷阱
`Control/EscapeController.swift` 如今**不含**脱困逻辑，只有 `ControlCommand` 类型（44 行，2026-10-06 复测；`steer/throttle/brake/confidence` 字段 :28-43，`.idle` 空操作 :35）。查脱困相关历史请看文件头注释 :12-15 与 `AuroraDriveApp.swift:6974-6999` 的删除取证。