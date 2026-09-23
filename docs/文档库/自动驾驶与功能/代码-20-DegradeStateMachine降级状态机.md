# 代码-20 DegradeStateMachine 降级状态机

> 覆盖源文件：`Sources/AuroraDrive/Agent/DegradeStateMachine.swift`（250 行）。基于当前仓库逐单元编写。

## 一、四档梯子与可调阈值（第 1–70 行）

**定位（4–14 行头注释）**：降级状态机——**四档梯子：端到端主驾(E2E) → YOLO接管(第二套神经网) → 纯规则兜底 → 脱困中**。

- 输入：M9 存活 / 控制模型存活 / 当前档位健康度 / 车速 / 卡住时长 / 极速开关 / 暖机标记
- 输出：当前 DriveMode + 转换原因

**四个设计原则（源注释原文）：**

1. **单调降级、滞后恢复**——防止在阈值附近抖动反复横跳
2. **极速模式覆盖一切**——速度优先，关闭避障，强制走 E2E
3. **卡住检测独立于模型**——即便模型很自信，车不动就脱困
4. **降级阈值外部可调**——UI 滑块可实时调

**类声明（第 18–23 行）**：`@Observable final class DegradeStateMachine`——@Observable 让 SwiftUI 观察当前模式与内部诊断量（卡住时长等）；**纯函数式转移：update(inputs) 根据输入计算下一态，无副作用**；线程：仅主线程访问（与 DriveState.tick 同步调用）。

**五个可调阈值（第 25–43 行，与 DriveState 同步，UI 可改）：**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `degradeHealth` | 0.65 | 触发降级的健康度下限：当前档位驾驶模型健康度低于此值 → 降一级（典型 0.65：健康巡航 0.9+，正常不会误降；0 表示模型死） |
| `recoverHysteresis` | 0.15 | **恢复所需的滞回量**：健康度 > degradeHealth + 此值 → 回升一档 |
| `stuckSpeedThreshold` | 3.0 km/h | 卡住检测：车速低于此值视为"不动" |
| `stuckTimeThreshold` | 3.0 秒 | 卡住检测：持续不动超过此秒数 → 进入 ESCAPE 脱困 |
| `recoverTimeout` | 30.0 秒 | **脱困超时兜底**：OCR 不新鲜时 speedValid 恒 false，正常退出路径失效；脱困档累计时长超过此值强制转 .rule，**避免永久卡死 .recover（不再死等 OCR）**。可调：过大脱困周期更长，过小可能未脱困即被兜底拉回 |

**状态输出（第 45–57 行）：**

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（private(set)，默认 .e2e） | **当前模式（UI 观察此属性刷新模式芯片高亮）** |
| `lastTransitionReason`（private(set)，默认 "初始化"） | 最近一次状态转换的原因（UI 可展示，调试用） |
| `stuckSeconds: Double`（private(set)） | 当前连续低速时长（秒），UI 可展示诊断 |
| `sportOverride: Bool`（private(set)） | 极速模式是否激活（由 DriveState.sportMode 同步过来） |

**内部状态（第 59–69 行）**：`previousMode`（上一帧模式，检测转换用）、`recoverElapsed`（**脱困档累计时长：进入 .recover 时从 0 累加，离开即清零**）、`lastUpdateTime: Date?`（**recoverElapsed 用真实经过时间累加，不受 tick 掉拍导致的 dt=1/30 计时漂移影响（决策逻辑仍用传入 dt）**）。

**DriveMode 枚举**：`.e2e`（端到端主驾）/ `.yolo`（YOLO 接管）/ `.rule`（纯规则兜底）/ `.recover`（脱困中）——rawValue 用于引擎心跳的 modeRaw 字段（见 代码-07）。

## 二、update() 主入口与优先级链（第 71–206 行）

**`update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:) -> DriveMode`（@discardableResult，第 87–206 行）**——根据输入更新状态机，返回本次应使用的 DriveMode。

**九个输入参数（74–95 行注释）：**

| 参数 | 含义 |
|---|---|
| `m9Live` | 端到端模型（M9）推理链路是否存活（加载+新鲜结果） |
| `assistLive` | 控制模型（YOLO接管档司机）推理链路是否存活 |
| `health` | 当前档位驾驶模型的健康度 [0,1]（**置信度估计器输出**） |
| `warmingUp` | 启动暖机期（还没出推理结果）→ 保持档位不降级 |
| `speedKmh` | 当前有效车速 km/h |
| `speedValid` | **有效车速是否有新鲜来源；false 时不累计卡死时长（防"读不到速度→误判卡死"）** |
| `dt` | 距离上次调用的时间间隔（秒） |
| `sportMode` | 极速模式开关 |
| `forceRule` | **紧急切纯规则开关；true 时强制停在纯规则兜底档（最高优先，压过极速模式；卡死仍临时进脱困，车动起来后回到纯规则）** |

**计时修正（97–118 行，P2 修复）**：`recoverElapsed` 与 `stuckSeconds` 都改用「实际经过时间」（Date 差值）累加——tick 掉拍时 dt 恒 1/30 会让计时偏慢/漏判；`dt=1/30` 仅作首次调用回退。脱困档累计：仅 `.recover` 累加、离开清零——**与 speedValid 无关（OCR 死锁也能计时），是脱困退出兜底的时钟**。

**优先级链（从高到低，5 层）：**

**层 0：紧急切纯规则（120–140 行，最高优先，覆盖极速模式）**——`forceRule == true` 时：

- 卡住计时照常（`allowEscape: true`）
- 卡住 ≥ 阈值且不在脱困 → `.recover`（"卡住 Xs"）
- 在脱困：`speedValid && speedKmh > stuckSpeedThreshold × 2` → 脱困成功回 `.rule`；`recoverElapsed >= recoverTimeout` → **兜底超时强制转 .rule**（"OCR 死锁时不再死等"）
- 其他 → `.rule`（"紧急切纯规则"）

**层 1：极速模式覆盖（142–148 行）**——`sportMode == true` 时：`transition(to: .e2e, reason: "极速模式覆盖")` + 卡住计时（allowEscape: true）→ return。**速度至上，关闭避障，强制 E2E 主驾**。

**层 1.5：启动暖机（150–155 行）**——`warmingUp == true` 时：保持当前档位不降级 → return。**否则启动瞬间 M9 未出结果会被当成"死了"，瞬间掉到纯规则兜底**。

**层 2：卡住检测（157–175 行，独立于模型）**：

- `updateStuckTimer(allowEscape: true)` → `stuckSeconds >= stuckTimeThreshold && mode != .recover` → `.recover`（"卡住 Xs"）→ return
- **已在脱困中（163–175 行）**：等车动起来才退出——**需有新鲜速度来源，避免用衰减值误判成功**：`speedValid && speedKmh > stuckSpeedThreshold × 2` → `.e2e`（"脱困成功"）；`recoverElapsed >= recoverTimeout` → `.rule`（"脱困超时兜底"）

**层 3：模型存活 + 健康度驱动的四档梯子（177–204 行）：**

```swift
let clampedHealth = max(0.0, min(1.0, health))
let recov = min(0.99, degradeHealth + recoverHysteresis)   // 恢复阈值（滞回）
```

- **P0-1 死锁修复（179 行注释）**：**0.99 上限保证严格 <1.0，健康度 1.0 时永远能恢复，避免 degradeHealth ≥0.85 时 recov=1.0 → clampedHealth > 1.0 永不成立 → 永久卡最低档**

| 当前档 | 降级条件 | 升级条件 |
|---|---|---|
| `.e2e`（档1） | `!m9Live \|\| clampedHealth < degradeHealth` → `.yolo`（"M9 不可用（健康 X%）"） | — |
| `.yolo`（档2） | `!assistLive \|\| clampedHealth < degradeHealth` → `.rule`（"控制模型不可用"） | `m9Live && clampedHealth > recov` → `.e2e`（"M9 恢复"） |
| `.rule`（档4） | — | `assistLive && clampedHealth > recov` → `.yolo`（"控制模型恢复"） |
| `.recover` | 由卡住检测管理（202 行 break） | — |

**滞后恢复的原理**：降级阈值 0.65，恢复阈值 0.65+0.15=0.80——健康度在 0.65~0.80 之间徘徊时**既不降也不升**，防止抖动反复横跳。

## 三、卡住计时器 / transition / reset（第 208–250 行）

**`updateStuckTimer(speedKmh:dt:allowEscape:speedValid:)`（private，第 213–221 行）**——更新低速持续时长：

```swift
guard speedValid else { return }   // 读不到速度：不计入卡死，避免误判脱困
if speedKmh < stuckSpeedThreshold {
    stuckSeconds += dt              // 不动：累加
} else {
    stuckSeconds = max(0, stuckSeconds - dt * 2)   // 车动了：快速衰减（0.5s 内清零，避免长尾）
}
```

- **allowEscape 参数（211 行注释）**：是否允许触发 ESCAPE（极速模式仍允许，因为它只覆盖置信度路径）——注意：本实现里 allowEscape 参数实际未参与判定（卡住触发在 update 的层 0/2 里做），它是签名预留
- **speedValid 参数（212 行注释）**：有效车速是否有新鲜来源；**false 时既不累计也不清零（速度未知不判定卡死）**

**`transition(to:reason:)`（private，第 226–231 行）**——执行状态转换并记录原因：`guard newMode != mode`（幂等）→ previousMode = mode → mode = newMode → lastTransitionReason = reason。

**`reset()`（第 234–242 行）**——重置到初始态（**停止自动驾驶时调用**）：mode=.e2e、previousMode=.e2e、stuckSeconds=0、recoverElapsed=0、lastUpdateTime=nil、lastTransitionReason="已重置"、sportOverride=false——**全状态归零**。

**`pct(_ v: Double) -> String`（private，第 247–249 行）**：置信度百分比字符串——`String(format: "%.0f%%", v * 100)`（转换原因里的"健康 92%"就是它拼的）。

**DegradeStateMachine 文档至此完整**（250 行全覆盖：四档梯子 → update 优先级链 → 计时器与转换）。给别的 AI 的最关键提示：**forceRule > 极速 > 暖机 > 卡住 > 健康度**五层优先级顺序不能颠倒（forceRule 是紧急安全开关，必须压过一切）；**recoverTimeout 兜底是防"OCR 死锁 + 卡死"组合拳把车永久锁在脱困档的最后一道闸**。