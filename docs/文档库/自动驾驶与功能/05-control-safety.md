# 五、控制与安全子系统

> 覆盖源码：`ControlEngine.swift`(373) `KeyboardMonitor.swift`(113) `RuleController.swift`(185) `EscapeController.swift`(217) `DegradeStateMachine.swift`(250)
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Control & Safety](../英文版/05-control-safety.en.md)

> **档案标注（2026-09-19 核对更新，基线 7b7d2db）**：ControlEngine 由 236 行增至 373 行（新增 AI Agent 游戏键位支持 `GameKey` 枚举等）；`postKeyEvent` 新增保留参数 `autorepeat`（默认 false，所有实际调用仍走「新按下」语义）。各节行号已按现码订正。

## 5.1 按键注入（ControlEngine）

**事件源选择是整个子系统的命门**（:74-84 注释原文）：`CGEventSource(stateID: .hidSystemState)`。项目早期试过 `.combinedSessionState`——UI 层按键指示灯会亮但游戏不动；`.privateState` 被游戏输入层禁用。只有 HID 层事件能被异环读到。

**注入流程**（`postKeyEvent`，:204）：

```swift
let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown)
event.post(tap: .cghidEventTap)     // 注入到硬件事件层
```

`postKeyEvent` 保留了一个 `autorepeat` 参数（默认 false；`true` 时标记 `.keyboardEventAutorepeat`）——但**所有实际调用路径都用默认 false**：游戏输入层忽略带 auto-repeat 标记的 keyDown，只认「新按下」语义；长按靠 `refreshHeldKeys` 每 tick（30Hz）重发 keyDown 模拟。

**键码表**（KeyMap，:37-56）：W=13 / S=1 / A=0 / D=2 / 空格(手刹)=49 / LeftShift(氮气)=56。

**动作函数**：

| 函数 | 行为 | 细节 |
|---|---|---|
| `press` | 按下→usleep 50ms→抬起 | 默认单击节奏 |
| `hold` / `release` | 持键 / 放键 | hold 防重复按下；release 校验 heldKeys |
| `refreshHeldKeys` | 对所有按住键重发 keyDown | 30Hz 每帧调用，维持"按住"语义 |
| `releaseAll` | 无条件对 6 键发 keyUp | 停车/切档时防卡键 |

**权限**：`AXIsProcessTrustedWithOptions`（带 `kAXTrustedCheckOptionPrompt` 弹授权窗；字符串字面量形式是避 Swift 6 并发报错）。press/hold/refreshHeldKeys 有权限 guard；release/releaseAll 无条件执行（任何时候都要能松键）。

**新增（2026-09）**：`GameKey` 枚举（MaaNTE 实际使用的游戏常用键 + 异环 HUD 热键 F1/F2/F4 + 数字/钢琴键，`gameKeyToKeyCode` 映射表）供 AI Agent 指令模式按键注入（如 G2 入口键序列）；`postKeyEvent` 注释中另有 `postToPid` 精确注入方案（需 PID），当前实现仍走全局 `.cghidEventTap`。

## 5.2 键盘监控（KeyboardMonitor）

`NSEvent.addGlobalMonitorForEvents` 监听全局 keyDown/keyUp（:50, :57）。`:51` 的 `guard !event.isARepeat` 很关键：过滤系统 autorepeat，否则按住时长会被反复重置成 ~50ms。

**如实说明**：这个模块只服务三件事——UI 键位条显示、按住时长统计、`clearAll`。**代码里没有任何"按 ESC 紧急停车"钩子**；紧急停车走 `stopDriving()`（releaseAll + 停推理）。

## 5.3 规则控制器（RuleController）——YOLO 检测 → 控制量

把 YOLO 的检测框翻译成驾驶动作，无任何模型推理。

**Detection 判定**（`isInDangerZone`/`urgency`，:55-68）：
- 危险区：`|x - 0.5| < 0.18 && y > 0.45`（画面中下方、左右 36% 宽的梯形区）
- `urgency = clamp(面积 × 8 × 居中度)`（越近越大、越居中越危险）

**decide() 决策表**（:114-160）：

| 场景 | steer | throttle | brake | confidence |
|---|---|---|---|---|
| 危险区无障碍（直行） | 0 | 0.8 | 0 | 0.8 |
| urgency > 0.55（急刹） | ±1.0 | 0 | 1.0 | 障碍置信度 |
| urgency > 0.25（减速避让） | ±1.0 | 0.2 | 0.6 | 同上 |
| 其余有障碍（轻微避让） | ±0.5 | 0.6 | 0.1 | 同上 |

**fuse()**（:167-184）用于 `.rule` 档的 E2E+规则融合：safe → 完全信 E2E；caution → 转向各半、置信度 ×0.9；danger/critical → 规则完全覆盖。

## 5.4 脱困（EscapeController）

三阶段循环：**倒车 1.5s → 反打方向 0.8s → 前进 2.0s**，总超时 15s，前进段车速 > 8 km/h 即判定脱困成功（:59-71）。

- `enter()`：随机选左/右脱困方向（`Bool.random()`，:113）
- `update(dt:speedKmh:)`：按阶段推进，超时返回 `(置信度0.3, escaped=false)`（:146）
- 各阶段 confidence 固定 0.3（提示降级状态机这是低置信操作）
- 输出类型 `ControlCommand`（:28-44，含 `idle`）是 Rule/Escape 的统一控制量格式

## 5.5 四档降级状态机（DegradeStateMachine）

`update()` 9 参数纯函数（`@discardableResult`，:87-95），仅主线程调用。

**核心阈值**：

| 常量 | 值 | 含义 |
|---|---|---|
| `degradeHealth` | 0.65 | 降级健康线 |
| 恢复阈值 | 0.80（`min(0.99, 0.65+0.15)`） | 滞回 0.15，防止在阈值边缘反复横跳 |
| `stuckSpeedThreshold` | 3.0 km/h | 低于此算"卡住" |
| `stuckTimeThreshold` | 3.0 s | 卡住持续时长 → 进脱困 |
| `recoverTimeout` | 30.0 s | 脱困总超时 |

**优先级链**（从高到低）：`forceRule`（一键规则）> `sportMode`（强制 e2e，且不进脱困）> `warmingUp`（暖机保持档位）> 卡住检测 > 健康梯子。

**档位转移条件**：

```
e2e  --(!m9Live || health<0.65)-->  yolo
yolo --(!assistLive || health<0.65)-->  rule
yolo --(m9Live && health>0.80)-->  e2e      # 滞回恢复
rule --(assistLive && health>0.80)-->  yolo
*    --(stuckSeconds≥3.0)-->  recover
recover --(speedValid && speed>6.0)-->  e2e  # 或 forceRule 时回 rule
recover --(超30s)-->  rule
```

**stuckSeconds 计时细节**（`updateStuckTimer`，:213 起）：
- `speedValid == false`（速度读不到）→ **冻结**：不累计也不清零
- 低速 → 按真实时间差累加（不是 dt）
- 车动了 → 2 倍速衰减，0.5s 内清零（防抖）

## 5.6 安全防线总览

| 风险 | 防线 |
|---|---|
| 卡键 | `stopDriving()` → `releaseAll()`；切档先松全键 |
| 失控 | `forceRule` 一键切规则；`stopDriving` 随时可停 |
| 决策吃旧帧 | pendingFrame 只存最新 + generation 丢弃过期写回 |
| 决策吃显示帧 | 架构红线：MetalFX 只挂 overlay（见三级文档四） |
| 卡死检测失灵 | 速度来自真实 CNN 读数；读不到时 stuck 计时冻结而非误触发 |
| 滞回震荡 | 恢复阈值 0.80 > 降级阈值 0.65，中间有 0.15 缓冲带 |
