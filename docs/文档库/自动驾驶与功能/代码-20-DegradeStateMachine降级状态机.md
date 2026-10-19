# 代码-20 DegradeStateMachine 降级状态机
> ♻️ **「指向相邻符号」二次校准（2026-10-18）**：`DriveMode` 的引用原写 `AuroraDriveApp.swift:4050`——`:4050` 实为 `case e2e = "端到端主驾"`，**`enum DriveMode` 声明在 `:4047`**。已改为 :4047 并注明 `:4050-4052` 是它的三个 case。另核实「分节注释写四档梯子」这条已不成立（Lead 已改 `:7404` 为三档），已同步更新该段。
> ♻️ **行号已按 9097 行版重基准（2026-10-18）**：`DegradeStateMachine.swift` **165 行冻结未变**，其内部 40+ 处 `:N` 引用逐条 `sed -n` 验语义，**零漂移**（含 `:31` degradeHealth=0.65、`:34` recoverHysteresis=0.15、`:114` recov 计算、`:50`/`:55` 两个死字段、`:141-164` pct 段）。`AuroraDriveApp.swift` 引用按冻结版重测，**8 条更新**（update 块 :7408→**:7409-7417**、mode 同步 :7419→**:7420**、暖机 :7406→**:7407-7408**、switch :7591→**:7593-7606**、rule :7602→**:7604**、lane 门 :7640→**:7642**、分节注释 :7404→**:7405**），其余 6 条（:5653/:6865/:7105/:6314/:7391/:5352）**未再漂**。§四 表已改为三列对照（9088 → 9094 → 9097）。
> ✅ 2026-10-17 复核（T7）：第四节「调用现场」App 行号已按当前 AuroraDriveApp.swift（9088 行）`grep -n` 全部实测修正（tick=6862 / update 九参=7403-7411 / mode 同步=7414 / degradeHealth=7102 / 暖机=7401-7402 / switch=7585-7598 / rule=7596 / lane=7634 / reset=6311 / 卡死块=7386-7397 / 字段=5350-5372）；正文遗留旧值 :6558/:5866 已修正为 :7102/:6311；DegradeStateMachine.swift 165 行不变。
>
> ✅ **2026-10-18 复核（agent-reader）**：DegradeStateMachine.swift **165 行不变**，但 `AuroraDriveApp.swift` 已从 9088 增至 **9094 行**，第四节 11 个行号**全部漂移**。本次修订：
> - **阈值三项逐个复核，全部属实**（源码逐行 read）：`degradeHealth = 0.65`（:31）、`recoverHysteresis = 0.15`（:34）、恢复阈值 `rec(min(0.99, 0.65+0.15)=0.80)` 由 :114 现算（**不是常量**，需与 `min(0.99, …)` 上限一起理解）——文档 §一/§二 表述正确，无需改数值。
> - **新增：`sportOverride`（:50）与 `previousMode`（:55）是「只写不读」的死字段**（§一末尾新增说明）。`grep -rn` 全仓核实：两个字段在本文件之外**零引用**，本文件内也只有赋值（sportOverride :84/:156、previousMode :146/:154），**没有任何读取点**。
> - **修正第四节 App 行号**（详见 §四 表头，含三列对照 9088→9094→**9097 冻结版**）：tick 6862→**6865**、update 7403-7411→**7409-7417**、mode 同步 7414→**7420**、degradeHealth 7102→**7105**、暖机 7401-7402→**7407-7408**、switch 7585-7598→**7593-7606**、rule 7596→**7604**、lane 7634→**7642**、reset 6311→**6314**、卡死块 7386-7397→**7391-7402**、字段 5350-5372→**5352/5356/5368/5374**、持有 5651→**5653**。
> - **确认无误**：`.recover` 已删除的描述（§一 :12、§二 层 0、§三 reset、文末提示）与源码 :7-8/:36-38/:86-89 完全一致，**无需改动**；三档梯子、九参数、优先级链、P0-1 死锁注释全部属实。

> 覆盖源文件：`Sources/AuroraDrive/Agent/DegradeStateMachine.swift`（**165 行**，2026-10-07 `wc -l` 复测，与旧记一致）。
> 本文 2026-10-06 由文档更新代理 A5 全文按当前源码重写：旧文基于含 `.recover` 脱困档的四档版本（250 行），该档已于 **2026-09-30 整体删除**——现为**三档梯子**，卡住检测计时/脱困超时等机制一并移除。
> **2026-10-07 由文档核对代理 E4 复核**：源文件 165 行与三档梯子描述**全部属实**；仅**第四节「调用现场」的 AuroraDriveApp.swift 行号整体漂移**（因为 App 主文件当时已增至 8456 行）。**2026-10-17（T7）**：第四节 App 引用已按 9088 行版全部重测，正文遗留的 :6558/:5866 两处旧值已修正为 :7102/:6311。

## 一、三档梯子与可调阈值（DegradeStateMachine.swift:1-56）

**定位（:4-15 头注释）**：降级状态机——**三档梯子：端到端主驾(E2E) → YOLO接管(第二套神经网) → 纯规则兜底**。

> ⚠️ **2026-09-30：脱困档（.recover）已按用户要求整体删除**（:7-8）——实测脱困策略压低速且无法退出，自动驾驶最多维持 ~12 秒即被脱困循环打断。

- 输入：M9 存活 / 控制模型存活 / 当前档位健康度 / 极速开关 / 暖机标记（:9）
- 输出：当前 DriveMode + 转换原因（:10）

**设计原则（:11-15 注释原文，注意第 3 条已随脱困删除失效但注释保留）**：

1. **单调降级、滞后恢复**——防止在阈值附近抖动反复横跳
2. **极速模式覆盖一切**——速度优先，关闭避障，强制走 E2E
3. ~~卡住检测独立于模型~~（`.recover` 删除后无消费者，:36-38 注释明确）
4. **降级阈值外部可调**——UI 滑块可实时调

**类声明（:20-25）**：`@Observable final class DegradeStateMachine`——SwiftUI 观察当前模式与转换原因；**纯函数式转移：update(inputs) 计算下一态，无副作用**（:22）；**线程：仅主线程访问（与 DriveState.tick 同步调用）**（:23）。

**两个可调阈值（:27-34，与 DriveState 同步，UI 可改）**：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `degradeHealth` | 0.65 | 触发降级的健康度下限：当前档位驾驶模型健康度低于此值 → 降一级（典型 0.65：健康巡航 0.9+，正常不会误降；0 表示模型死）。DriveState 每帧同步（AuroraDriveApp.swift:**7105**，✅ 2026-10-18 修正：原写 :7102） |
| `recoverHysteresis` | 0.15 | **恢复所需的滞回量**：健康度 > degradeHealth + 此值 → 回升一档 |

**随脱困档删除一并移除**（:36-38 注释）：`stuckSpeedThreshold` / `stuckTimeThreshold` / `recoverTimeout` / `stuckSeconds` / `recoverElapsed` / `lastUpdateTime` / `updateStuckTimer`——卡住检测的唯一用途就是触发 .recover，删除后不再有任何消费者（speedKmh/speedValid/dt 三个参数**保留在签名里但已不参与决策**，:89）。

**状态输出（:40-50）**：

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（private(set)，默认 .e2e，:43） | **当前模式（UI 观察此属性刷新模式芯片高亮）** |
| `lastTransitionReason`（private(set)，默认 "初始化"，:46） | 最近一次状态转换的原因（UI 可展示，调试用） |
| `sportOverride`（private(set)，:50） | 极速模式是否激活（由 DriveState.sportMode 同步过来）。⚠️ **✅ 2026-10-18 复核：死字段**——全仓 `grep -rn sportOverride Sources/` 在本文件之外**零引用**，本文件内仅 :84 赋值 + :156 重置，**没有任何读取点**。`@Observable` 标了但无 UI 消费者 → 赋值不会触发任何重绘逻辑（无效通知）。 |

**内部状态（:52-55）**：`previousMode`（上一帧模式，:55，transition 时更新）。⚠️ **✅ 2026-10-18 复核：死字段**——全仓 `grep -rn previousMode Sources/` 在本文件之外**零引用**，本文件内仅 :146 赋值 + :154 重置，**没有任何读取点**（原脱困档 `.recover` 的边沿检测逻辑曾依赖它，随该档删除一并失去消费者）。

**DriveMode 枚举**：`.e2e`（端到端主驾）/ `.yolo`（YOLO 接管）/ `.rule`（纯规则兜底）——rawValue 用于引擎心跳的 modeRaw 字段（见 代码-07）。

## 二、update() 主入口与优先级链（:58-139）

**`update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:) -> DriveMode`（@discardableResult，:73-139）**——根据输入更新状态机，返回本次应使用的 DriveMode。

**九个输入参数（:62-71 注释）**：

| 参数 | 含义 |
|---|---|
| `m9Live` | 端到端模型（M9）推理链路是否存活（加载+新鲜结果） |
| `assistLive` | 控制模型（YOLO接管档司机）推理链路是否存活 |
| `health` | 当前档位驾驶模型的健康度 [0,1]（**置信度估计器输出**） |
| `warmingUp` | 启动暖机期（还没出推理结果）→ 保持档位不降级 |
| `speedKmh` | 当前有效车速 km/h（**保留签名，已不参与决策**，:89） |
| `speedValid` | 同上（保留签名，已不参与决策） |
| `dt` | 同上（保留签名，已不参与决策） |
| `sportMode` | 极速模式开关 |
| `forceRule` | **紧急切纯规则开关；true 时强制停在纯规则兜底档（最高优先，压过极速模式）** |

**优先级链（从高到低，3 层 + 梯子）**：

**层 0：紧急切纯规则（:91-97，最高优先，覆盖极速模式）**——`forceRule == true` 时：`mode != .rule` 才 transition（"紧急切纯规则"）→ return。**不再有任何卡住/脱困分支**（旧文的 forceRule 脱困例外已随档删除）。

**层 1：极速模式覆盖（:99-104）**——`sportMode == true` 时：`transition(to: .e2e, reason: "极速模式覆盖")` → return。**速度至上，关闭避障，强制 E2E 主驾**。

**层 1.5：启动暖机（:106-110）**——`warmingUp == true` 时：保持当前档位直接 return。**否则启动瞬间 M9 未出结果会被当成"死了"，瞬间掉到纯规则兜底**。

**层 2：模型存活 + 健康度驱动的三档梯子（:112-137）**：

```swift
let clampedHealth = max(0.0, min(1.0, health))              // :113
let recov = min(0.99, degradeHealth + recoverHysteresis)    // :114 恢复阈值（滞回）
```

- **P0-1 死锁修复（:114 行内注释）**：**0.99 上限保证严格 <1.0，健康度 1.0 时永远能恢复，避免 degradeHealth ≥0.85 时 recov=1.0 → clampedHealth > 1.0 永不成立 → 永久卡最低档**

| 当前档 | 降级条件 | 升级条件 |
|---|---|---|
| `.e2e`（档1） | `!m9Live \|\| clampedHealth < degradeHealth` → `.yolo`（"M9 不可用（健康 X%）"）（:116-120） | — |
| `.yolo`（档2） | `!assistLive \|\| clampedHealth < degradeHealth` → `.rule`（"控制模型不可用"）（:122-125） | `m9Live && clampedHealth > recov` → `.e2e`（"M9 恢复"）（:126-129） |
| `.rule`（档3） | — | `assistLive && clampedHealth > recov` → `.yolo`（"控制模型恢复"）（:131-135） |

**滞后恢复的原理**：降级阈值 0.65，恢复阈值 0.65+0.15=0.80——健康度在 0.65~0.80 之间徘徊时**既不降也不升**，防止抖动反复横跳。

## 三、transition / reset / pct（:141-164）

**`transition(to:reason:)`（private，:144-149）**——执行状态转换并记录原因：`guard newMode != mode`（幂等）→ previousMode = mode → mode = newMode → lastTransitionReason = reason。

**`reset()`（:151-157）**——重置到初始态（**停止自动驾驶时调用**，AuroraDriveApp.swift:**6314**，✅ 2026-10-18 修正：原写 :6311）：mode=.e2e、previousMode=.e2e、lastTransitionReason="已重置"、sportOverride=false——**全状态归零**（旧文的 stuckSeconds/recoverElapsed 归零项已随字段删除）。注意：其中 `previousMode` 与 `sportOverride` 两个被重置的字段**本身无任何读取者**（见 §一）。

**`pct(_ v: Double) -> String`（private，:162-164）**：置信度百分比字符串——`String(format: "%.0f%%", v * 100)`（转换原因里的"健康 92%"就是它拼的）。

## 四、调用现场（DriveState.tick；行号 **2026-10-18 按 AuroraDriveApp.swift 9094 行版**实测）

> ✅ **2026-10-18 复核（agent-reader）**：本节行号已按 **9094 行版**全部重新 `grep -n` 实测。2026-10-17 T7 的 9088 行版数字**已整体漂移 +3～+6 行**，下表新旧对照可直接用于定位。

| 项 | 2026-10-17 T7（9088 行） | 2026-10-18 一次（9094 行） | **2026-10-18 重基准（9097 行，冻结版）** |
|---|---|---|---|
| 持有 `let degradeStm = DegradeStateMachine()` | :5651 | :5653 | **:5653**（未再漂） |
| `func tick()` | :6862 | :6865 | **:6865**（未再漂） |
| `degradeStm.update(...)` 九参数块 | :7403-7411 | :7408-7416 | **:7409-7417** |
| `if mode != decided { mode = decided }` | :7414 | :7419 | **:7420** |
| `degradeStm.degradeHealth = degradeThreshold` | :7102 | :7105 | **:7105**（未再漂） |
| 暖机判据 `let warmingUp = …` | :7401-7402 | :7406-7407 | **:7407-7408** |
| `switch decided` 按档取控制量 | :7585-7598 | :7591-7604 | **:7593-7606** |
| `.rule` 档 `ruleController.decide(...)` | :7596 | :7602 | **:7604** |
| `Self.laneKeepTiers.contains(decided)` | :7634 | :7640 | **:7642** |
| `degradeStm.reset()` | :6311 | :6314 | **:6314**（未再漂） |
| 卡死判定块 `if isDriving && speedValid && effectiveSpeed < 1.0` | :7386-7397 | :7391-7402 | **:7391-7402**（未再漂） |
| 卡死字段声明区（`stuckZeroSince`/`stuckZeroThreshold`/`needsManualIntervention`/`stuckZeroHeldSeconds`） | :5350-5372 | :5352-5377 | **:5352 / :5356 / :5368 / :5374**（逐符号实测） |

**正文（行号已更新）**：

- 持有：`let degradeStm = DegradeStateMachine()`（AuroraDriveApp.swift:**5653**）。
- 每帧调用：`func tick()`（App:**6865**）内 App:**7409-7417**（九参数：m9Live/assistLive/confidence 作 health/warmingUp/speedKmh/speedValid/dt/sportMode/forceRuleMode）→ 先比后写同步 `mode`（App:**7420**）。
- 阈值同步：`degradeStm.degradeHealth = degradeThreshold`（App:**7105**）。
- 暖机判据：`inferenceEngine.lastResult == nil && Date().timeIntervalSince(drivingStartTime) < 3.0`（App:**7406-7407**）。
- 决策结果消费：`switch decided` 按档取控制量（App:**7593-7606**）——`.rule` 档即 `ruleController.decide(detections:)`（App:**7604**）；档位门控见 `Self.laneKeepTiers`（App:**7642**）。
- 停止驾驶时复位：`degradeStm.reset()`（App:**6314**）。

> ✅ **`DriveMode` 枚举位置（♻️ 2026-10-18 二次校准）**：`enum DriveMode` 在 **`AuroraDriveApp.swift:4047`**（`:4047` 是 `enum DriveMode: String, CaseIterable, Identifiable {`）；**`:4050-4052` 是它的三个 case**（`case e2e` / `case yolo` / `case rule`），不是 enum 本身的声明行。两种引法都对，但勿混为一谈。
> ✅ **原先记录的「分节注释写四档梯子」已不存在（2026-10-18 已修）**：`App:7404` 现为「降级状态机决策（**三档**梯子：模型存活 + 健康度驱动）」，`App:7405` 补了一行「（原写「四档梯子」，脱困档 .recover 已于 2026-09-30 删除，2026-10-18 修正）」。同类 `App:4069`「规则组只剩 .rule 一个成员」与 `App:4048`「**3 个**档位」均正确。

**DegradeStateMachine 文档至此完整**（165 行全覆盖：三档梯子 → update 优先级链 → transition/reset）。给别的 AI 的最关键提示：**forceRule > 极速 > 暖机 > 健康度梯子**的优先级顺序不能颠倒（forceRule 是紧急安全开关，必须压过一切）；**脱困档与卡住计时已于 2026-09-30 整体删除，不要再按四档模型理解本文件**；卡死（零速 30s）现在走 DriveState 的 `needsManualIntervention` 人工介入横幅（判定块 AuroraDriveApp.swift:**7391-7402**，字段声明 App:**5352-5377**），与状态机完全解耦。
