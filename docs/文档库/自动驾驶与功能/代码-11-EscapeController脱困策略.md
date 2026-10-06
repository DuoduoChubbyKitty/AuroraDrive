# 代码-11 EscapeController 脱困策略

> 🚨 **本文档已整体失效（2026-10-02 复核）** —— 请先读这段，再看下面正文。
>
> ## 事实：脱困功能已不存在
>
> | 项 | 原文档说 | 当前事实 |
> |---|---|---|
> | 源文件行数 | 217 行 | **44 行** |
> | 文件内容 | 脱困三阶段策略 | **只剩公共类型 `ControlCommand`** |
> | `EscapeController` 类 | 有 | **❌ 已删除** |
> | 档位 `.recover` | 有 | **❌ 已整体删除**（现存三档：`.e2e` / `.yolo` / `.rule`） |
> | 三阶段循环「倒车 1.5s → 反打 0.8s → 前进 2.0s」 | 有 | **❌ 已删除** |
> | `enter()` / 随机选脱困方向 | 有 | **❌ 已删除** |
>
> ## 删除原因（源码 `EscapeController.swift:12–15` 原文）
>
> > 注（2026-09-30）：EscapeController 脱困策略已按用户要求整体删除 ——
> > **脱困档（`.recover`）实测压低速且无法退出，自动驾驶最多维持 ~12 秒。**
> > ControlCommand 类型保留：E2E/Rule 两段决策的统一输出格式。
> > 超时保护说明随脱困删除一并移除。
>
> ⟹ **脱困不是"没配好"，是"实测压低速且无法退出"**，所以整体砍掉。
>
> ## 这个文件现在还有什么用
>
> **只剩 `ControlCommand`**（`Sources/AuroraDrive/Control/EscapeController.swift:28`）：
>
> ```swift
> struct ControlCommand: Equatable {
>     var steer: Double = 0        // [-1, 1] 左负右正
>     var throttle: Double = 0     // [0, 1]
>     var brake: Double = 0        // [0, 1]
>     var confidence: Double = 1.0 // [0, 1]
>     static let idle = ControlCommand()
> }
> ```
>
> **它仍是活跃类型** —— `AuroraDriveApp.swift` 的 `currentCommand` 就是它。
> 只是**文件名已名不副实**（叫 EscapeController，里面没有 EscapeController）。
>
> ⚠️ **改文件名不在本次范围内**（改名=破坏，且要动 Package 与引用点）。
>
> ---
>
> **以下为 2026-09-29 原文，全部已失效，仅作留痕。切勿据此写代码。**
>
> ---

> 覆盖源文件：`Sources/AuroraDrive/Control/EscapeController.swift`（**44 行**，**2026-10-02 `wc -l` 实测**；原文写 217 行）

## 一、ControlCommand 公共类型与脱困参数（第 1–102 行）

**双职责（4–16 行头注释）**：

1. **公共类型 `ControlCommand`**：统一三段决策（E2E/Rule/Escape）的输出格式——`steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]`，调用方（DriveState）把 ControlCommand 映射到 ControlEngine 按键注入
2. **EscapeController 脱困策略**：状态机进入 `.recover` 时调用，输出**倒车→转向→前进的循环动作**；**纯硬编码规则，不依赖模型**；超时保护：总时长超限强制报告失败，避免无限脱困

**`ControlCommand`（struct，第 28–44 行）——决策输出（三段胶水代码统一返回此类型）：**

| 字段 | 默认值 | 说明 |
|---|---|---|
| `steer` | 0 | 转向 [-1, 1]，左负右正 |
| `throttle` | 0 | 油门 [0, 1] |
| `brake` | 0 | 刹车 [0, 1]（**游戏里 S 键通常兼作倒车**） |
| `confidence` | 1.0 | 本次决策的置信度 [0, 1]，**供状态机降级用**：E2E 填模型置信度、Rule 填启发式分、**Escape 固定 0.3 表示低置信脱困中** |

- `static let idle = ControlCommand()`——空操作（松开所有键）
- `init(steer:throttle:brake:confidence:)`——全部带默认值（便于 EscapeController 表达"按 W"+"按 A"）

**`EscapeController`（@Observable final class，第 53–54 行）**——脱困控制器：UI 可观察脱困阶段与倒计时；内部三阶段状态机 `REVERSE → TURN → FORWARD`；进入 `.recover` 态时调用 `enter()`，每帧 `update(dt)` 返回 ControlCommand；**脱困成功（前进时车速恢复）或超时失败时，调用方应退出 .recover 态**。

**五个可调参数（第 56–71 行）：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `reverseDuration` | 1.5 秒 | 倒车时长：先倒车拉开距离 |
| `turnDuration` | 0.8 秒 | 转向时长：原地打方向，为前进做准备 |
| `forwardDuration` | 2.0 秒 | 前进时长：尝试前进，观察是否脱困 |
| `maxTotalDuration` | 15.0 秒 | 最大脱困总时长：**超时强制失败，避免无限循环** |
| `escapeSpeedThreshold` | 8.0 km/h | 脱困成功车速阈值：前进阶段车速超过此值视为脱困成功 |

**状态输出（第 73–102 行）：**

| 成员 | 说明 |
|---|---|
| `phase: Phase`（private(set)） | 当前阶段——enum：`.reverse = "倒车" / .turn = "转向" / .forward = "前进" / .done = "完成"`（rawValue 中文，UI 直接展示） |
| `phaseRemaining: Double`（private(set)） | 当前阶段剩余时间（秒） |
| `totalElapsed: Double`（private(set)） | 累计脱困时长（秒） |
| `escapeDirection: Double`（private(set)，默认 +1） | 脱困转向方向：+1 右转 / -1 左转——**进入脱困时随机选一边，整个脱困过程保持一致，避免左右横跳** |
| `isEscaping`（private） | 是否脱困中 |
| `lastUpdateTime: Date?`（private） | 上次 update 调用的实际时间戳——**phase 计时/超时保护用真实经过时间累加，避免主线程 tick 掉拍时 dt 恒 1/30 导致倒车/转向/前进各阶段计时偏慢** |

## 二、enter / update / reset 三阶段状态机（第 104–217 行）

**`enter()`（第 108–115 行）**——进入脱困态（状态机转入 .recover 时调用）：

```swift
isEscaping = true
totalElapsed = 0
lastUpdateTime = nil   // 重新进入脱困时重置计时基准，避免把上一次脱困的间隔算进本周期
escapeDirection = Bool.random() ? 1.0 : -1.0   // 随机选脱困方向，避免每次都往同一边撞
startPhase(.reverse)
```

- **随机选方向**：`Bool.random()`——每次脱困往不同边撞
- **重置计时基准**：lastUpdateTime = nil（不把上一次脱困的间隔算进本周期）

**`update(dt: Double, speedKmh: Double) -> (command: ControlCommand, escaped: Bool)`（@discardableResult，第 123–194 行）——每帧更新脱困策略：**

1. `guard isEscaping else { return (.idle, false) }`
2. **真实时间累加（128–137 行）**：`actualDt` 优先用 `Date()` 差值，`dt=1/30` 仅作首次调用回退——主线程掉拍时不会让各阶段相位计时偏慢；`lastUpdateTime = now`
3. `totalElapsed += actualDt`、`phaseRemaining -= actualDt`
4. **超时保护（142–147 行）**：`totalElapsed >= maxTotalDuration` → `isEscaping = false`、`phase = .done`、返回 `(ControlCommand(confidence: 0.3), false)`——**强制失败**
5. **按阶段输出控制量（150–181 行）**——confidence 全部固定 0.3（低置信脱困中）：

| Phase | steer | throttle | brake | 说明 |
|---|---|---|---|---|
| `.reverse` | `-escapeDirection × 0.5` | 0 | **1.0** | 倒车：按 S（brake）+ 反向轻微转向 |
| `.turn` | `escapeDirection × 1.0` | 0 | 0 | 转向：松开油门刹车，纯打方向 |
| `.forward` | `escapeDirection × 0.7` | **1.0** | 0 | 前进：油门 + 脱困方向转向；**`speedKmh > escapeSpeedThreshold` → 脱困成功**（isEscaping=false、phase=.done、返回 `(cmd, true)`） |
| `.done` | idle | — | — | 返回 `(.idle, false)` |

6. **阶段切换（183–191 行）**：`phaseRemaining <= 0` 时——`.reverse → .turn → .forward → .reverse` **循环**（注释原文："前进没脱困就再倒车"）；`.done` 不切
7. 返回 `(cmd, false)`

**`reset()`（第 197–203 行）**——重置（退出 .recover 态时调用）：isEscaping=false、phase=.done、phaseRemaining=0、totalElapsed=0、lastUpdateTime=nil——全状态归零。

**`startPhase(_ p: Phase)`（private，第 208–216 行）**——启动某个阶段：置 phase + 按 p 填 phaseRemaining（reverse→1.5 / turn→0.8 / forward→2.0 / done→0）。

**调用契约与映射链**：DriveState 在状态机 `.recover` 态每 tick 调 `update(dt:speedKmh:)`，拿 `command` 映射到 ControlEngine（steer→steerLeft/Right 键、throttle→W、brake→S）——映射逻辑在 DriveState 侧（见 代码-24/25 文档）；`escaped == true` 或超时后调用方退出 .recover 态并 `reset()`。

**EscapeController 文档至此完整**（217 行全覆盖：公共类型与参数 → 三阶段状态机）。