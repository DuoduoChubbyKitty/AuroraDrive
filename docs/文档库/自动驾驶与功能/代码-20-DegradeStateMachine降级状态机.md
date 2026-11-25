# 代码-20 DegradeStateMachine 降级状态机
> ♻️ **符号校准**：`DriveMode` 的引用现统一指向 `enum DriveMode` 本体（`case e2e` / `case yolo` / `case rule` 是它的三个 case，不再用行号定位）。「分节注释写四档梯子」这条已不成立（当前注释为三档），已同步更新该段。
> ♻️ **引用已全面改为符号名**：`DegradeStateMachine.swift` 的参数、字段、方法与 `AuroraDriveApp.swift` 的消费点，全部按符号定位（如 `DegradeStateMachine.update`、`degradeHealth`、`recov`、`sportOverride`、`previousMode`、`pct`、`DriveState.tick`、`degradeStm.reset()` 等），不再记录行号。历史各轮的行号漂移记录已全部删除——那些行号现已失效，四节调用现场表改为符号对照。
> ✅ 2026-10-17 复核（T7）：第四节「调用现场」的符号与结论已全部核对（tick / update 九参 / mode 同步 / degradeHealth / 暖机 / switch / rule / lane 门 / reset / 卡死块 / 卡死字段）；`DegradeStateMachine.swift` 未变。
>
> ✅ **2026-10-18 复核（agent-reader）**：`DegradeStateMachine.swift` 内部结构不变，但 `AuroraDriveApp.swift` 持续膨胀，第四节所有行号均已失效。本次修订已把全部引用改为符号名：
> - **阈值三项逐个复核，全部属实**：`degradeHealth = 0.65`、`recoverHysteresis = 0.15`、恢复阈值 `recov = min(0.99, degradeHealth + recoverHysteresis)` 由 `update` 现算（**不是常量**，需与 `min(0.99, …)` 上限一起理解）——文档 §一/§二 表述正确，无需改数值。
> - **新增：`sportOverride` 与 `previousMode` 是「只写不读」的死字段**（§一末尾新增说明）。`grep -rn` 全仓核实：两个字段在本文件之外**零引用**，本文件内也只有赋值（`sportOverride` 在 `update` 中赋值、`reset` 中重置；`previousMode` 在 `transition` 与 `reset` 中赋值），**没有任何读取点**。
> - **修正第四节调用现场**：全部改为符号定位（`DriveState.tick` / `degradeStm.update` / `mode` 同步 / `degradeStm.degradeHealth` / 暖机判据 / `switch decided` / `ruleController.decide` / `Self.laneKeepTiers` / `degradeStm.reset()` / 卡死判定块 / 卡死字段声明）。
> - **确认无误**：`.recover` 已删除的描述（§一、§二 层 0、§三 reset、文末提示）与源码一致，**无需改动**；三档梯子、九参数、优先级链、P0-1 死锁注释全部属实。

> 覆盖源文件：`Sources/AuroraDrive/Agent/DegradeStateMachine.swift`。
> 本文 2026-10-06 由文档更新代理 A5 全文按当前源码重写：旧文基于含 `.recover` 脱困档的四档版本，该档已于 **2026-09-30 整体删除**——现为**三档梯子**，卡住检测计时/脱困超时等机制一并移除。
> **2026-10-07 由文档核对代理 E4 复核**：源文件与三档梯子描述**全部属实**；仅**第四节「调用现场」的 AuroraDriveApp.swift 行号持续漂移**。**2026-10-17（T7）**：第四节 App 引用已改为符号定位，旧值作废。

## 一、三档梯子与可调阈值（DegradeStateMachine.swift）

**定位（文件头注释）**：降级状态机——**三档梯子：端到端主驾(E2E) → YOLO接管(第二套神经网) → 纯规则兜底**。

> ⚠️ **2026-09-30：脱困档（.recover）已按用户要求整体删除**（头注释）——实测脱困策略压低速且无法退出，自动驾驶最多维持 ~12 秒即被脱困循环打断。

- 输入：M9 存活 / 控制模型存活 / 当前档位健康度 / 极速开关 / 暖机标记（头注释）
- 输出：当前 DriveMode + 转换原因（头注释 `mode` / `lastTransitionReason`）

**设计原则（头注释原文，注意第 3 条已随脱困删除失效但注释保留）**：

1. **单调降级、滞后恢复**——防止在阈值附近抖动反复横跳
2. **极速模式覆盖一切**——速度优先，关闭避障，强制走 E2E
3. ~~卡住检测独立于模型~~（`.recover` 删除后无消费者，源码 `stuckSpeedThreshold` 等字段删除注释明确）
4. **降级阈值外部可调**——UI 滑块可实时调

**类声明**：`@Observable final class DegradeStateMachine`——SwiftUI 观察当前模式与转换原因；**纯函数式转移：`update` 计算下一态，无副作用**；**线程：仅主线程访问（与 `DriveState.tick` 同步调用）**。

**两个可调阈值（与 DriveState 同步，UI 可改）**：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `degradeHealth` | 0.65 | 触发降级的健康度下限：当前档位驾驶模型健康度低于此值 → 降一级（典型 0.65：健康巡航 0.9+，正常不会误降；0 表示模型死）。DriveState 每帧同步（`degradeStm.degradeHealth = degradeThreshold`） |
| `recoverHysteresis` | 0.15 | **恢复所需的滞回量**：健康度 > degradeHealth + 此值 → 回升一档 |

**随脱困档删除一并移除**（源码删除注释）：`stuckSpeedThreshold` / `stuckTimeThreshold` / `recoverTimeout` / `stuckSeconds` / `recoverElapsed` / `lastUpdateTime` / `updateStuckTimer`——卡住检测的唯一用途就是触发 .recover，删除后不再有任何消费者（speedKmh/speedValid/dt 三个参数**保留在 `update` 签名里但已不参与决策**）。

**状态输出**：

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（private(set)，默认 .e2e） | **当前模式（UI 观察此属性刷新模式芯片高亮）** |
| `lastTransitionReason`（private(set)，默认 "初始化"） | 最近一次状态转换的原因（UI 可展示，调试用） |
| `sportOverride`（private(set)） | 极速模式是否激活（由 DriveState.sportMode 同步过来）。⚠️ **✅ 2026-10-18 复核：死字段**——全仓 `grep -rn sportOverride Sources/` 在本文件之外**零引用**，本文件内仅在 `DegradeStateMachine.update` 赋值、`reset` 重置，**没有任何读取点**。`@Observable` 标了但无 UI 消费者 → 赋值不会触发任何重绘逻辑（无效通知）。 |

**内部状态**：`previousMode`（上一帧模式，`transition` 时更新）。⚠️ **✅ 2026-10-18 复核：死字段**——全仓 `grep -rn previousMode Sources/` 在本文件之外**零引用**，本文件内仅在 `transition` 与 `reset` 中赋值，**没有任何读取点**（原脱困档 `.recover` 的边沿检测逻辑曾依赖它，随该档删除一并失去消费者）。

**DriveMode 枚举**：`.e2e`（端到端主驾）/ `.yolo`（YOLO 接管）/ `.rule`（纯规则兜底）——rawValue 用于引擎心跳的 modeRaw 字段（见 代码-07）。

## 二、update() 主入口与优先级链

**`update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:) -> DriveMode`（@discardableResult）**——根据输入更新状态机，返回本次应使用的 DriveMode。

**九个输入参数（`update` 注释）**：

| 参数 | 含义 |
|---|---|
| `m9Live` | 端到端模型（M9）推理链路是否存活（加载+新鲜结果） |
| `assistLive` | 控制模型（YOLO接管档司机）推理链路是否存活 |
| `health` | 当前档位驾驶模型的健康度 [0,1]（**置信度估计器输出**） |
| `warmingUp` | 启动暖机期（还没出推理结果）→ 保持档位不降级 |
| `speedKmh` | 当前有效车速 km/h（**保留在 `update` 签名中，已不参与决策**） |
| `speedValid` | 同上（保留签名，已不参与决策） |
| `dt` | 同上（保留签名，已不参与决策） |
| `sportMode` | 极速模式开关 |
| `forceRule` | **紧急切纯规则开关；true 时强制停在纯规则兜底档（最高优先，压过极速模式）** |

**优先级链（从高到低，3 层 + 梯子）**：

**层 0：紧急切纯规则（`update` 内 `forceRule` 分支，最高优先，覆盖极速模式）**——`forceRule == true` 时：`mode != .rule` 才 `transition(to: .rule, reason: "紧急切纯规则")` → return。**不再有任何卡住/脱困分支**（旧文的 forceRule 脱困例外已随档删除）。

**层 1：极速模式覆盖（`update` 内 `sportMode` 分支）**——`sportMode == true` 时：`transition(to: .e2e, reason: "极速模式覆盖")` → return。**速度至上，关闭避障，强制 E2E 主驾**。

**层 1.5：启动暖机（`update` 内 `warmingUp` 分支）**——`warmingUp == true` 时：保持当前档位直接 return。**否则启动瞬间 M9 未出结果会被当成"死了"，瞬间掉到纯规则兜底**。

**层 2：模型存活 + 健康度驱动的三档梯子（`update` 内 `clampedHealth` / `recov` 段）**：

```swift
let clampedHealth = max(0.0, min(1.0, health))
let recov = min(0.99, degradeHealth + recoverHysteresis)    // 恢复阈值（滞回）
```

- **P0-1 死锁修复（`recov` 计算行内注释）**：**0.99 上限保证严格 <1.0，健康度 1.0 时永远能恢复，避免 degradeHealth ≥0.85 时 recov=1.0 → clampedHealth > 1.0 永不成立 → 永久卡最低档**

| 当前档 | 降级条件 | 升级条件 |
|---|---|---|
| `.e2e`（档1） | `!m9Live \|\| clampedHealth < degradeHealth` → `transition(to: .yolo, reason: "M9 不可用…")` | — |
| `.yolo`（档2） | `!assistLive \|\| clampedHealth < degradeHealth` → `transition(to: .rule, reason: "控制模型不可用…")` | `m9Live && clampedHealth > recov` → `transition(to: .e2e, reason: "M9 恢复…")` |
| `.rule`（档3） | — | `assistLive && clampedHealth > recov` → `transition(to: .yolo, reason: "控制模型恢复…")` |

**滞后恢复的原理**：降级阈值 0.65，恢复阈值 0.65+0.15=0.80——健康度在 0.65~0.80 之间徘徊时**既不降也不升**，防止抖动反复横跳。

## 三、transition / reset / pct

**`transition(to:reason:)`（private）**——执行状态转换并记录原因：`guard newMode != mode`（幂等）→ `previousMode = mode` → `mode = newMode` → `lastTransitionReason = reason`。

**`reset()`**——重置到初始态（**停止自动驾驶时调用**，`degradeStm.reset()`）：mode=.e2e、previousMode=.e2e、lastTransitionReason="已重置"、sportOverride=false——**全状态归零**（旧文的 stuckSeconds/recoverElapsed 归零项已随字段删除）。注意：其中 `previousMode` 与 `sportOverride` 两个被重置的字段**本身无任何读取者**（见 §一）。

**`pct(_ v: Double) -> String`（private）**：置信度百分比字符串——`String(format: "%.0f%%", v * 100)`（转换原因里的"健康 92%"就是它拼的）。

## 四、调用现场（DriveState.tick；全部按符号定位）

> ✅ **2026-10-18 复核（agent-reader）**：本节所有引用已改为符号名——`AuroraDriveApp.swift` 持续膨胀，行号引用全部作废，下表按代码中的函数 / 属性 / 表达式定位。

| 项 | 符号 / 表达式 |
|---|---|
| 持有状态机 | `let degradeStm = DegradeStateMachine()` |
| 每帧入口 | `DriveState.tick()` |
| 九参数更新 | `degradeStm.update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:)` |
| 档位同步 | `if mode != decided { mode = decided }` |
| 阈值同步 | `degradeStm.degradeHealth = degradeThreshold` |
| 暖机判据 | `let warmingUp = inferenceEngineV3.lastResult == nil …` |
| 按档取控制量 | `switch decided` |
| 纯规则决策 | `ruleController.decide(detections:)` |
| 车道保持门控 | `Self.laneKeepTiers.contains(decided)` |
| 状态机复位 | `degradeStm.reset()` |
| 卡死判定块 | `if isDriving && speedValid && effectiveSpeed < 1.0` |
| 卡死字段 | `stuckZeroSince` / `stuckZeroThreshold` / `needsManualIntervention` / `stuckZeroHeldSeconds` |

**正文（符号引用）：**

- 持有：`let degradeStm = DegradeStateMachine()`（`DriveState` 内）。
- 每帧调用：`DriveState.tick()` 内 `degradeStm.update(...)`（九参数：m9Live/assistLive/confidence 作 health/warmingUp/speedKmh/speedValid/dt/sportMode/forceRuleMode）→ 先比后写同步 `mode`。
- 阈值同步：`degradeStm.degradeHealth = degradeThreshold`。
- 暖机判据：`inferenceEngineV3.lastResult == nil && Date().timeIntervalSince(drivingStartTime) < 3.0`（`tick` 内 `warmingUp`）。
- 决策结果消费：`switch decided` 按档取控制量——`.rule` 档即 `ruleController.decide(detections:)`；档位门控见 `Self.laneKeepTiers`。
- 停止驾驶时复位：`degradeStm.reset()`。

> ✅ **`DriveMode` 枚举位置**：`enum DriveMode` 在 `AuroraDriveApp.swift`；`case e2e` / `case yolo` / `case rule` 是它的三个 case，不是 enum 本身。两种引法都对，但勿混为一谈。
> ✅ **原先记录的「分节注释写四档梯子」已不存在**：当前注释为「降级状态机决策（**三档**梯子：模型存活 + 健康度驱动）」，并补注「（原写「四档梯子」，脱困档 .recover 已于 2026-09-30 删除，2026-10-18 修正）」。同类「规则组只剩 .rule 一个成员」与「**3 个**档位」均正确。

**DegradeStateMachine 文档至此完整**。给别的 AI 的最关键提示：**forceRule > 极速 > 暖机 > 健康度梯子**的优先级顺序不能颠倒（forceRule 是紧急安全开关，必须压过一切）；**脱困档与卡住计时已于 2026-09-30 整体删除，不要再按四档模型理解本文件**；卡死（零速 30s）现在走 `DriveState` 的 `needsManualIntervention` 人工介入横幅，与状态机完全解耦。