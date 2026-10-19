# 代码-25 AuroraDriveApp 之 DriveState 状态主体

> ✅ **2026-10-18 复核**（`wc -l` = **9096 行**，较 10-17 版 9088 行 +8）：
> Lead 今日改 `AuroraDriveApp.swift` 三处，均已逐条 `read` 核实**语义正确**，仅行号漂移：
> 1. `DriveMode` 枚举注释「4 档」→「3 档」（`:4048`，✅ 已改对，`.recover` 删除说明保留）
> 2. `QUEST_OCR` 两处注释修正（`:5902` questPanel 注释 + `:6966` tick 内注释，✅ 均已标注「原注释误写默认关，2026-10-17 修正」）
> 3. tick 内 20Hz 注释（`:7135-7140`）+ `lastDecided` 两处先比后写（`:7559` / `:7619`，✅ 语义正确）
>
> **行号漂移**：系统性 +2（:4047~:5527 段）/ +3（:5898~:6865 段）/ **+8（:7899~:8082 段；Lead 又改 :7405/:7582 两处注释各 +1）**。
> 下表「2026-10-18 实测锚点表」与「§附 当前实测锚点表」均已按 **9096 行版**实测重写。
> `tick()` 驱动者更正：**20Hz**（非旧文 30Hz），由 `MissionConsole.swift:6117` DispatchSource `1.0/20.0` 驱动，回调 `:6140` `state.tick()`（非 ContentView Timer）。

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（**9096 行**，2026-10-18 `wc -l` 实测；9094/9088 为当日/10-17 旧基准，8456 行为 10-07 旧基准，10-06 版为 8335 行）之中部：DriveMode/DriveModeGroup/RecordLabelMapper + DriveState。
> **✅ 2026-10-17 复核**：正文原含 291 处基于 8335/8456/9088 多版本的行号引用（已漂移 Δ275~632），**已按 2026-10-17 9088 行版实测更新，再经 2026-10-18 复核至 9096 行版**——正文行号引用（符号名 + （第 N–M 行）区间）均基于当前 9096 行版重测，不再基于 8335/8456 旧基准。精确行号见下方「2026-10-18 实测锚点表」。

> （历史沿革已归档：8335/8456 旧基准的行号换算规则不再适用；正文数字行号已按 9096 行版实测更新。）
> **✅ 2026-10-18 「指向相邻符号」审计（lead 脚本抓 3 条可疑 → 实测实为 6 处区间错位，全部修正）**：
> - `sendChatMessage` **:1557-1620 → :1570-1632**（:1557 是上一条函数的尾部空白，声明在 :1570、闭合在 :1632）
> - `appendMessage` 一组 **:201/:203/:205/:208-215/:218-220/:223-226 → :208/:210/:212/:215-222/:225-227/:230-233**
> - `apiKey` **AgentSettings :149 → :142**（:149 是 `backendKind`，`apiKey` 在 :142；`enum LLMBackendKind` 在 :29）
> - 连带修正：`sendUserMessage :1487→:1500`、`sendChatMessage 调用 :1541→:1555`、`messages.suffix(40) :1559→:1572`、
>   `replaceMessage 调用 :1592-1598→:1609`、`离线回复 :1610-1613→:1624`、`wantVision :1571→:1584`、
>   `encodeCurrentFrameForVision :1636-1641→:1649-1655`、`init 接线 :484-486→:492`、`sendUserMessage 接线 :1490→:1503`、
>   `占位 :1575→:1588`、`replyAssistant :1694→:1707`、`appendSystem :1698→:1711`、`newConversation :1749-1753→:1762-1768`、
>   `AgentConversationView :2947→:2967`、后端选择器 :2296-2340→:2314-2360、视觉开关 :2342-2360→:2362-2385、
>   `AgentSettingsSheet :2547→:2567`、`navigationTitle :2611→:2631`、`applyKeyless :2699-2702→:2720-2727`、
>   连通性回写 :2820-2830→:2837/:2847/:2857
> - **根因**：`AIAgentPanel.swift`（3273 行）在 10-18 之后仍有改动，整段 +13 左右漂移；且**多处引用的是区间内部行**，
>   无法靠统一平移修正，只能逐符号 `grep -n` 定位。
>
> ② **AI 面板改动不在本文覆盖范围**（用户明确要求核实项）：`sendChatMessage` / 滑动窗口 `appendMessage`+`maxMessages=200` / 后端选择器 / 视觉开关 / 配置向导 / 底部小字 / 诊断面板 **全部落在 `Agent/AIAgentPanel.swift`**，与本文覆盖的 `AuroraDriveApp.swift` 中段（DriveMode + DriveState）**无重叠**。`AuroraDriveApp.swift` 本次仅两处变动，均在本文范围外：自检 flag 登记与分发（:935-1094），以及 `ControlEngine`（另一文件）。→ **本文本次未改动任何 DriveState 逻辑**，10-06 复核结论全部继续有效。
>
> ③ 与 AI 面板的**唯一接口点**是 `AgentSkillCenter.configure(control:capture:)`（`AuroraDriveApp.swift:533`，`AppDelegate` 侧；DriveState 侧另见 `MissionConsole.swift:6226/6245/6261`），**本次未改动**（`git diff HEAD~5..HEAD -- Sources/AuroraDrive/App/AuroraDriveApp.swift` 仅 3 个 hunk，均在 :701/:935/:1001 附近，未触及 `configure` 调用点）。

## 〇·五、AI 面板改动落点（2026-10-07，**代码不在本文覆盖文件内**）
>
> **✅ 2026-10-17 复核（功能描述准确；行号引用已全部改为文件级）**：
> ① 功能语义逐条核验仍准确：startDriving/stopDriving 引擎分流与本地清卡键、tick() 完整决策管线、
>   三档 switch decided、转向死区 ±0.1 / 油门刹车互斥 0.3、stuckZeroThreshold 默认 30s、
>   questOCR（AF:201 默认 true）、laneKeepTiers（默认 rule,yolo）——均与源码一致；
> ② 唯一内容增量：stopDriving 重置链现含 inferenceEngineV2.reset()（V2 时序环形缓冲 + 冷启动门控，见 §五）；
> ③ 正文原 291 处 `App:NNNN` 数字行号已全部移除（改为 `AuroraDriveApp.swift` 文件级引用 + 符号名）；正文（第 N–M 行）区间引用已按 **9096 行版**实测更新；精确行号以「2026-10-18 实测锚点表」为准。覆盖文件当前 9096 行。

> ### ✅ 2026-10-18 实测锚点表（**当前 9096 行版**，优先用此表定位，替代正文所有旧行号）
>
> | 单元 | 当前行号 | 旧记（已失效） |
> |---|---|---|
> | `enum DriveMode` | **:4047** | 2273–2300 / 3981 |
> | `enum DriveModeGroup` | **:4082** | — |
> | `enum RecordLabelMapper` | **:4121** | 3952 / 855–880 |
> | `final class DriveState` | **:4150** | 3981 / 4102 / 1304–3079 / 2373 |
> | 定位器字段 `locatorFound/X/Y/Score/Heading` | **:4367–4371** | 4145–4149 / 4266 |
> | `locatorAccelX` / `locatorTarget` / `questName` | **:4375 / :4378 / :4384** | 4156 / 4162 |
> | `isDriving` / `expertMode` / `glyphMode` / `forceRuleMode` / `agentMode` | **:4182 / :4241 / :4245 / :4307 / :4335** | 4015–4113 |
> | `isRecording`（didSet） | **:4988** | 4766 / 1091–1121 |
> | `clearRoute()` / `planRouteToMapPixel()` / `setLocatorTarget()` | **:4416 / :4431 / :4515** | 4194 / 4293 |
> | `runNetworkLocateStep()` | **:4546** | — |
> | `startDriving()` / `stopDriving()` | **:6190 / :6300** | — |
> | 决策组件：`degradeStm` / `ruleController` / `confidenceEst` / `inferenceEngine` / `inferenceEngineV2` / `assistEngine` / `yoloEngine` / `yolopxEngine` | **:5653 / :5671 / :5672 / :5677 / :5692 / :5697 / :5702 / :5716** | 5276–5362 / 5300 等 |
> | `egoBoxFilter` / `laneFallback` / `driveSegment` / `fallbackGuard` | **:5723 / :5727 / :5733 / :5754** | 5331–5362 |
> | `captureEngine` / `speedOCR` / `questPanel` | **:5529 / :5898 / :5908** | 5502 |
> | `tickEngineMode()` / `pushEngineConfigIfChanged()` | **:6522 / :6745** | — |
> | `tick()` | **:6865** | 6383 / 6505 |
> | `recordFrameIfNeeded()` | **:7899** | — |
> | `readPose()` | **:8032** | 7271 / 7392 |
> | `applyCommand(_:)` | **:8082** | — |
> | `applyLaneAdvice`（自由函数） | **:8379** | 7618 / 7739 |
>
> 说明：旧行号因文件从 8335→8456→9088→9094→**9096** 行多次增长而漂移；上表为 2026-10-18 `grep -n` 逐一实测。
> 用户要求核实"代码-25 的 AI 面板相关改动"。

| 改动 | 实现位置（2026-10-07 实测） | 一句话说明 |
|---|---|---|
| **真实对话接线** `sendChatMessage` | `AIAgentPanel.swift:**1570-1632**`（`private func`，`:1570` 为声明行） | 自由聊天从"硬编码套话"改为真实 LLM：`sendUserMessage` **:1500** → 无技能命中时 **:1555** `sendChatMessage(trimmed, source:)`。带最近 40 条历史（**:1572** `messages.suffix(40)`）转 `ChatTurn`，服务端再裁到 12 轮。占位消息 + 流式增量 `replaceMessage`（**:1609**，`self.replaceMessage(id: placeholder.id, text: delta)`），失败走 `localReply` 并标注"（离线回复：无可用模型）"（**:1624**） |
| **滑动窗口** `appendMessage` / `maxMessages=200` | `AIAgentPanel.swift:**208**`（`messages`）、**:210**（`static let maxMessages = 200`）、**:212**（`droppedMessageCount`）、**`appendMessage` :215-222**、`resetDroppedMessageCount` **:225-227**、**`replaceMessage` :230-233** | 修「AI 那个窗口会无限变大」：超 200 条丢最旧的并累计 `droppedMessageCount`。**所有写入路径统一走 `appendMessage`**（原 6 处直接 `append` 已改造：`init` **:492**、`sendUserMessage` **:1503**、`sendChatMessage` 占位 **:1588**、`replyAssistant` **:1707**、`appendSystem` **:1711**、`newConversation` **:1765**）。UI 提示"更早的 N 条消息已折叠"（`:2955-2962` 附近，`AgentConversationView` **:2967**）；"新建对话"重置计数（`newConversation` **:1762-1768**，`droppedMessageCount = 0` :1766） |
| **后端选择器** | `AIAgentPanel.swift:**2314-2360**`（`:2314` 第二行 HStack 起、`:2316` 后端选择器注释、`:2320` Menu、`:2360` help 收尾） | 免 key 渠道开箱即用、需 key 渠道在 `apiKey` 为空时置灰；`apiKey` 声明 `AgentSettings.swift:**142**`（`var apiKey: String = ""`）；`backendKind` 声明 **:149**（`var backendKind: LLMBackendKind = .ovhAnonymous`），`enum LLMBackendKind` 定义在 **:29**，切换落盘 `AgentSettings.keyBackend`（:167） |
| **📷 视觉开关** | `AIAgentPanel.swift:**2362-2385**`（`:2363` `Toggle(isOn: Binding(`）；消费点 `sendChatMessage` **:1584** `let wantVision = aiSettings.visionEnabled` | 默认**关**（隐私优先，`AgentSettings.swift:153` `var visionEnabled: Bool = false` ✓）。开启后随请求带当前帧；**拿不到帧不静默降级**——如实告知"本次按纯文本发送"（`:1599-1603` 附近）。取帧 `encodeCurrentFrameForVision()` **:1649-1655**（`@MainActor`，长边 1568px + JPEG 0.8） |
| **配置向导** | `AIAgentPanel.swift:**2567**（`struct AgentSettingsSheet: View`）、`navigationTitle("AI 助手配置向导")` **:2631**、底部导航（`stepDot` :2584/:2586、定义 :2638） | 三步向导：免 key 路线 `applyKeyless()` **:2720-2727** 把后端设为免 key 渠道；渠道连通性测试结果回写 **:2837/:2847/:2857**（`testResults[kind.rawValue] = ...`） |
| **底部小字 + 诊断面板** | 小字 :2245-2292（`healthSnapshot.displayLine`，hover tooltip 展示候选链）；"诊断"按钮 :2266-2274；`struct LLMDiagnosticsSheet` **:2453**（`navigationTitle("模型渠道诊断")` :2523） | 数据源 `LLMHealthMonitor.snapshot()`（actor，进面板即刷 + 30s 轮询 :2276-2285）。全挂时显示"⚠️ 无可用模型（点此诊断）"；正常形如 `免费档 · ovh · Qwen2.5-VL-72B · 健康 4/7 · 0.9s` |

**语义边界提示**：本表信息来自当前源码行号实测，**未逐条通读 `AgentChatService` / `LLMHealthMonitor` 内部实现**——涉及"7 渠道聚合 / 降级链 / 探活策略"等细节请以 [代码-23-AIAgentPanel与17技能](代码-23-AIAgentPanel与17技能.md) 为准（**未验证**：本文未核对该文档是否已覆盖 10-07 增量）。

> 常用锚点（2026-10-18 逐条 `grep -n` / `sed -n` 实测）：`final class DriveState` 在 **AuroraDriveApp.swift:4150**；定位器/任务字段在 **4367–4384**；`setLocatorTarget` **4515**；`clearRoute` **4416**；决策组件持有 **5653–5754**；`questPanel` **5908** + `onConfirmed` 接线 **5981**；onFrame 接线 **5988**；`tick()` **6865 起**（引擎分流 **6939–6943**、quest OCR 门 **6973–6974**、卡死检测 **7391–7395**、`warmingUp` **7406**、`degradeStm.update` **7408**、`confidenceEst.update` **7433**、`switch decided` **7591**、`ruleController.decide` **7602**、`segmentDecisionForRule` **7652**（定义 **8044**、`driveSegment.update` **8054**））；`readPose()` **8030–8037**。
>
> - 3665 行版（09-29）：DriveState 记 1304–3079
> - 5175 行版（09-29）：DriveMode 2273–2300、DriveState 2373 起
> - 6698 行版（10-02）：全文按该版行号编写
>
> **2026-09-25 深度复核块结论仍有效**（行号以本节新锚点为准）：
> ① DriveMode 内部档位现行为 **e2e/yolo/rule 三档**（`.recover` 脱困档已于 2026-09-30 整体删除，见 DegradeStateMachine.swift:7-8；下文 ⑥ 及第八节里「.recover 档」表述已过时）；
> ② RecordLabelMapper 语义未变；
> ③ DriveState 核心机制（引擎模式五件套、effectiveDetections、权限状态组、路况自适应、effectiveSpeed/speedValid、m9Status 三态、frameHost 直绘）均仍在；
> ④ tick 决策链以第八节新核实行号为准。

## 〇、定位器与任务状态字段（定义 / 写入者 / 读取者，2026-10-06 新增）

`final class DriveState`（AuroraDriveApp.swift:4148）中的定位器/任务字段，全部主线程读写：

| 字段 | 定义处 | 写入者 | 读取者 |
|---|---|---|---|
| `locatorFound` | AuroraDriveApp.swift:4365 | 网络定位回调 AuroraDriveApp.swift（**先比后写**：`if self?.locatorFound == false`）；游戏未运行时清除 AuroraDriveApp.swift | `planRouteToMapPixel` 起点判断 AuroraDriveApp.swift；`readPose()` 门槛 AuroraDriveApp.swift；决策门槛与 UI（注释称 24 处 UI 读取，AuroraDriveApp.swift） |
| `locatorX` / `locatorY` | AuroraDriveApp.swift | 网络定位回调 AuroraDriveApp.swift（**写世界坐标 UE5 厘米**——坐标系统一修复取证见 AuroraDriveApp.swift） | `DriveState.worldToMapPixelX/Y` 各调用点（MapWiring.swift:29 定义；AuroraDriveApp.swift、MissionConsole.swift:2589-2590、:3969-3970、:4045-4046）；`readPose()` AuroraDriveApp.swift；NavGuidance 距离 `(t.x - locatorX)/100`（MissionConsole.swift:847 注释） |
| `locatorScore` | AuroraDriveApp.swift | AuroraDriveApp.swift（按新鲜度 tier 分级 `locatorScoreForTier`，AuroraDriveApp.swift：live=1.0 / recent=0.3 / stale=0.1 / lost=0） | 决策门槛 0.4（`readPose()` AuroraDriveApp.swift）；诊断打印 MissionConsole.swift:2886 |
| `locatorHeading` | AuroraDriveApp.swift | AuroraDriveApp.swift | `readPose()` AuroraDriveApp.swift（供 DriveSegmentController，AuroraDriveApp.swift 调用） |
| `locatorAccelX/Y/Z` | AuroraDriveApp.swift | AuroraDriveApp.swift | 仅如实展示（AuroraDriveApp.swift 注释：坐标系未实测确认，**不参与控制**） |
| `locatorTarget` | AuroraDriveApp.swift | ① `setLocatorTarget(x:y:)` AuroraDriveApp.swift（QuestPanelReader 确认回调 AuroraDriveApp.swift 调用，来自 quest_index 世界坐标）② `clearRoute()` AuroraDriveApp.swift（置 nil）③ 演示/自检夹具 MissionConsole.swift:5687、:5838、:6124、:6285 | MissionConsole.swift:634、:1457、:2540-2547、:3968（距离计算与路线规划） |
| `questName` | AuroraDriveApp.swift | QuestPanelReader 确认回调 AuroraDriveApp.swift（**先比后写**，注释 AuroraDriveApp.swift） | 任务卡片渲染 MissionConsole.swift:632、:861、:904、:927 |

**quest 数据流闭环**：`tick()` 主线程调 `questPanel.ingest(cgImage:)`（AuroraDriveApp.swift，门 `AuroraFlags.questOCR`）→ ROI 裁剪在主线程、Vision OCR 丢到 `aurora.quest.ocr` 后台串行队列（QuestPanelReader.swift:483，`qos: .utility`）→ OCR 完成回主线程（QuestPanelReader.swift:557 `DispatchQueue.main.async`）→ `onConfirmed` 回调（AuroraDriveApp.swift，主线程执行）→ 写 `questName`（AuroraDriveApp.swift）+ `setLocatorTarget`（AuroraDriveApp.swift）。QuestPanelReader.swift 文件头明确 `locatorTarget` 与 quest_index 同为世界坐标（UE5 厘米）。

### 决策组件的持有与所有权（全部为 DriveState 成员，主线程访问）

| 组件 | 持有处 | 说明 |
|---|---|---|
| degradeStm | AuroraDriveApp.swift | tick 每帧 update（AuroraDriveApp.swift）；阈值同步 AuroraDriveApp.swift |
| ruleController | AuroraDriveApp.swift | AuroraDriveApp.swift 调 decide |
| egoBoxFilter | AuroraDriveApp.swift（= EgoBoxFilter.configured，EgoBoxFilter.swift:77） | 决策层过滤 `effectiveDetections` AuroraDriveApp.swift |
| laneFallback | AuroraDriveApp.swift | 车道线兜底决策器（fail-open） |
| driveSegment | AuroraDriveApp.swift | AuroraDriveApp.swift 调 update（segmentDecisionForRule 内） |
| fallbackGuard | AuroraDriveApp.swift | **主链路已停用**（AuroraDriveApp.swift：不再调用 evaluate；实例保留仅供自检 AuroraDriveApp.swift 中 `guardA` 等） |
| inferenceEngine / assistEngine / yoloEngine / yolopxEngine | AuroraDriveApp.swift / 5675 / 5695 / 5700 / 5714 | 三套推理引擎 + YOLOPX |
| questPanel | AuroraDriveApp.swift（@ObservationIgnored let） | 任务面板 OCR，见上表 |

## 一、RecordLabelMapper 与 DriveState 开关字段

> 新锚点：`RecordLabelMapper` AuroraDriveApp.swift、`fullScaleDuration=0.6` AuroraDriveApp.swift；开关字段 AuroraDriveApp.swift（isTraining 4182 / expertMode 4239 / glyphMode 4243 / forceRuleMode 4305 / agentMode 4333）；`isRecording didSet` AuroraDriveApp.swift。下表语义逐项复核仍准确。

**`RecordLabelMapper`（enum，第 4119–4144 行）**——专家模式录制标签换算器（**纯函数，便于单测**）。语义（4121–4123 行注释）：把物理按键的"按住时长"换算成连续控制标签——**与推理端闭环一致：ControlEngine 按 \|steer\|>阈值 决定是否按住键，游戏自身再把按住时长平滑成转角——录制端用按住时长作为监督信号，让模型学到"打得越满 → 按住越久"的连续映射，替代二值标签带来的顿挫**。

| 方法/常量 | 签名 | 说明 |
|---|---|---|
| `fullScaleDuration` | `static let = 0.6` 秒 | **满刻度时长：按住满该时长 → 标签饱和 ±1**；默认 0.6s：30Hz 下约 18 帧，覆盖"轻点 → 满打"的常见手感区间 |
| `holdRatio(_:)` | `TimeInterval -> Double` | 按住时长 → [0,1] 比例（钳制）：`min(1, max(0, duration / 0.6))` |
| `steer(leftHeld:rightHeld:)` | 双时长 → Double | **D 按住比例 − A 按住比例，净差钳制到 [-1,1]（左负右正）** |
| `throttle(wHeld:)` | 时长 → Double | W 按住比例 [0,1] |
| `brake(sHeld:spaceHeld:)` | 双时长 → Double | **S 或 空格(手刹) 任一按住即刹车，取两者按住比例较大者 [0,1]** |

**`DriveState`（@Observable @MainActor final class，现 AuroraDriveApp.swift 中）**——全局状态 + 驾驶闭环。**开关字段（现 AuroraDriveApp.swift）：**

| 开关 | 默认 | 说明 |
|---|---|---|
| `isDriving` | false | 是否驾驶中 |
| `sportMode` | false | 极速模式 |
| `isTraining` | false | 是否训练中 |
| `expertMode` | false | **专家模式：录制时控制量来源切到真人物理键（模仿学习的专家演示），而非 AI 决策（currentCommand）。关 → 录 AI 决策（DAgger 自训练）** |
| `glyphMode` | false | **字模模式：录制时输出原生分辨率速度表区域帧（供字模训练），与专家模式/训练录制互不影响，仅影响 RecordEngine 的输出内容** |
| `controlDisabled` | false | **禁用控制：模型照常检测画面（YOLO 框 + E2E 推理照跑），但不把 AI 决策注入按键——人工驾驶 + 模型辅助提示** |
| `forceRuleMode` | false | **紧急切纯规则：开启后降级状态机强制停在纯规则兜底档（档4），且 M9 端到端推理停跑（省资源）。用途：紧急情况（游戏鼠标点不过去）一键切规则兜底，直到用户手动关闭** |
| `agentMode` | false | **AI Agent 模式：开启后显示更多游戏键位，支持模型直接操作** |
| `enableNetworkLocate` | false | 网络定位开关 |
| `trainingLog` | "" | 训练按钮状态/日志（UI 展示：启动中/完成/失败原因） |

**引擎模式字段（现 AuroraDriveApp.swift）：**

| 成员 | 说明 |
|---|---|
| `remoteDetections: [Detection]` | **引擎回传的检测结果（引擎模式下每 tick 刷新）** |
| `engineModeActive` | 引擎模式是否激活（镜像自 EngineClient，供 UI 观察刷新） |
| `engineConnected` | 引擎心跳是否正常（false = 失联，UI 显示告警） |
| `remoteSpeedKmh: Double`（默认 -1） | **引擎回传的车速表读数——引擎模式下本地 speedOCR 不跑，用它顶上** |
| `lastDriveCommandTime`（@ObservationIgnored） | **最后一次「开始/停止」命令时间：引擎状态回同步的 1 秒宽限期，防切换瞬间 UI 闪烁** |
| `effectiveDetections`（计算属性） | **决策层统一检测结果读取点：`egoBoxFilter.filter(displayDetections)`**（`AuroraDriveApp.swift:4244-4246`）——在 `displayDetections` 之上套一层 `EgoBoxFilter` 剔除自车框。⚠️ **2026-10-19 订正**：旧文写「UI 统一读取点：`EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`」已不符现码——该式子是 `displayDetections`（`:4217`）的算法，且 2026-10-02 起 `effectiveDetections` 语义已收窄为**决策层专用**（UI 画框走 `displayDetections`，两条链路在 `:4236` 分家）。`.rule` 纯规则档亦已于 2026-10-19 改为吃本属性（goal-3279b59b 需求4，见 `:7514-7538`） |

**BPF/Daemon 字段**：`bpfAuthorized`（启动时检测 BPF 权限）/ `showBPFPasswordSheet` / `bpfInstallMessage` / `bpfInstalling`；`daemonInstalled` / `showDaemonInstallSheet` / `daemonInstallMessage` / `daemonInstalling` / `isDaemonMode`——**Daemon 系统服务相关字段（安装引导弹窗/结果消息）**。

**网络定位字段**：`networkLocateX/Y/Score/Mode/Pitch/Heading`（六件套，UI 小地图显示用；`locateGameOffline` 计算属性 AuroraDriveApp.swift）。

> ⚠️ 修正一处旧文错误：`enableNetworkLocate` **默认 true 且「网络定位常开、不提供关闭入口」，保留字段仅为兼容**（AuroraDriveApp.swift 注释），不是旧表写的 false。

## 二、定位器字段与 runNetworkLocateStep / dlog 10MB 封顶

> ✅ 本节及以下至第九节的行号已按 **9096 行版（2026-10-18 实测）** 更新（原 9088/6698 行版历史基准已作废），语义经复核仍准确；新锚点见文首「常用锚点」与第〇节。

**定位器字段（现 AuroraDriveApp.swift，`lastNetworkLocPos` AuroraDriveApp.swift / `healerInitLock` AuroraDriveApp.swift / `locateCtx` AuroraDriveApp.swift；从外置盘移植，MinimapLocatorView 需要）**：`locatorFound/X/Y/Score/Heading`（五件套）+ `locatorTarget: (x: Double, y: Double)?`（传送目标）+ `lastNetworkLocPos`（@ObservationIgnored，上次定位位置——朝向反推基线）+ `healerInitLock`（os_unfair_lock，懒初始化锁）+ `coordinateCapture: CoordinateCapture?`（@ObservationIgnored，网络坐标抓取器）+ `locateCtx/locateGate`（LocateContext/LocateGate）。

**`mapPath`（lazy 闭包）**——底图路径解析（**用可执行文件所在目录找地图，不用 currentDirectoryPath（那是 Home 目录）**）：

- 四候选：`execDir/models/bigworldmap-13056.jpg`（首选）/ `execDir/models/bigworldmapSecond.png` / 硬编码 `/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg` / 旧图 png
- 全败返回**最后一个候选**（"返回最后一个作为默认，让错误信息有意义"——错误信息里能看到路径）

**`setLocatorTarget(x:y:)`（现 AuroraDriveApp.swift）**：设置传送目标（locatorTarget）。

**`heading(from:to:)`（static，现 AuroraDriveApp.swift）**：两点间朝向——`atan2(dy, dx) × 180/π`，负值 +360 归一到 [0, 360)。

**`runNetworkLocateStep()`（现 AuroraDriveApp.swift 中）**——网络定位步（**懒初始化 CoordinateCapture（纯网络定位，无自愈引擎）**）：

1. **懒初始化（4547–4562 行）**：`coordinateCapture == nil` 时——`os_unfair_lock_lock(&healerInitLock)` + `defer` 解锁 + **双检**（锁内再判 nil，防并发重复初始化）→ `cc.start()`（libpcap 起抓包，见 代码-04）→ `pcapLog("[NETWORK-LOCATE] cc.start()返回=…")` 记录成败 → `locateCtx.networkReady = true`
2. `guard let cc, locateCtx.networkReady`——未就绪 → 主线程 `networkLocateScore = 0` + `mode = "not_ready"` → return
3. **★ G 第 4 批（2026-10-04）：三级新鲜度取代旧 `cc.read(maxAge:)`**——`let tierRead = cc.readWithTier()`（AuroraDriveApp.swift），分 live（≤18s）/ recent（≤40s）/ stale（≤90s）/ lost 四档（AuroraDriveApp.swift 注释：UI 显示/决策层/控制层三列态度）；`locatorScoreForTier` 映射分数（live=1.0，其余低于 0.4 决策门槛），**只有 live 档允许驱动驾驶**（AuroraDriveApp.swift）。有数据时 `worldToMapPixel(pose)` 换算 + 主线程异步更新 networkLocate 六件套 + locator 五件套（**双份字段同步**——MinimapLocatorView 读 locator、大地图读 networkLocate）。
4. **游戏未运行**（AuroraDriveApp.swift）：`!cc.hasRecentTraffic(window: trafficFreshWindow=12s)`（突发式包流，旧 3s 窗口会在静默间隙误报，AuroraDriveApp.swift 注释）→ `networkLocateMode = "game_not_running"` + **清 locatorFound/locatorScore**（不保留旧坐标，防界面显示"假跳"定位，AuroraDriveApp.swift）；未就绪 → `"not_ready"`（AuroraDriveApp.swift）。

**`networkLocateLastUpdate`（第 4849 行）**：上次定位更新时间（默认 .distantPast）。

**三个时间戳（第 4865–4873 行）**：`drivingStartTime`（**本次开车会话开始时间——暖机期判定：启动后头几秒还没出推理结果时保持高置信度，避免启动瞬间误降级**）、`lastTickLog`（tick 摘要 1Hz 节流）、`lastUpscaleLiveLog`（插帧状态更新节流 1Hz）。

**`dlog(_ msg: String)`（private，现 AuroraDriveApp.swift 中；10MB 封顶语义见 AuroraDriveApp.swift、:9071-9080——已迁入 LogSink 但格式/封顶/回退链不变）**——调试日志：**stdout + `/tmp/aurora_debug.log`（App 启动时清空）**；"用户从终端启动可实时看到；事后我读文件定位运行时问题"。

- **P1 修复（9076–9080 行）**：**dlog 每秒追加，7×24 运行日志无限增长。写前检查大小，超 10MB 直接覆盖重写（truncate，atomic 写），只保留最近日志，封顶磁盘占用**
- 追加写：FileHandle seekToEndOfFile + write；文件不存在 createFile 等价路径（data.write）

## 三、isRecording didSet 与引擎模式回声防环

> 新锚点：`var isRecording didSet` AuroraDriveApp.swift 中；`guard isRecording != oldValue` AuroraDriveApp.swift、`guard !applyingRemoteRecord` AuroraDriveApp.swift、`lastRecordCommandTime` 记点 AuroraDriveApp.swift（声明 AuroraDriveApp.swift）。

**`var isRecording = false { didSet ... }`（第 4986–5025 行）**——行驶录制开关（didSet 触发 RecordEngine 启停 + 画面流/键盘监听接管）：

- true → 开始录制会话；**未在驾驶时由录制器负责拉起截屏画面流与键盘监听（否则不开车就开录制器会录出空目录）**
- false → 写 meta.json 并关闭；**驾驶仍开着时不关画面流/键盘监听（驾驶还在用）**

**⚠️ 引擎模式回声防环（4982–5001 行注释与实现）**：

- **"帧只存在于引擎进程（UI 没有画面流），录制必须由引擎执行，这里只把开关转发过去。早先在引擎模式下仍然本地 recordEngine.start()，结果是「目录建了、文件建了，但录不进任何东西」——因为 UI 的 tick 在引擎模式下提前 return，recordFrameIfNeeded() 永远不执行"**
- `guard isRecording != oldValue`（值未变不动）+ **`guard !applyingRemoteRecord else { return }`——来自引擎回同步，别回声**
- **引擎模式分支（4990–5001 行）**：`EngineClient.shared.isActive` 时——`lastRecordCommandTime = Date()`（**宽限期起点：别让未更新的心跳把开关弹回去**）+ `sendCommand("record", extra: ["on": isRecording, "glyph": glyphMode, "expert": expertMode])` → return——**只转发，不本地执行**

**本地模式分支（5002–5023 行）**：

- 开始：**每次开始录制前同步字模模式开关（5003–5012 行）**——"注意：录制中途切换 glyphMode 不影响本次会话（语义为「录制中切换不生效，需重启录制」），故不做实时热切换"：`recordEngine.glyphMode = glyphMode` + `recordEngine.start(perspective: "first")` + **`if !captureEngine.isCapturing { captureEngine.start() }`**（画面流没跑才拉起）+ `keyboardMonitor.start()`
- 停止：`recordEngine.stop()` + **`if !isDriving { captureEngine.stop(); keyboardMonitor.stop() }`**（驾驶还开着不关画面流/键盘——驾驶还在用）

**配套状态（第 5027–5037 行）：**

| 成员 | 说明 |
|---|---|
| `applyingRemoteRecord`（@ObservationIgnored） | **防回环标记：tickEngineMode 把引擎录制状态镜像到 isRecording 时置位，避免 didSet 又把「record」命令回声给引擎** |
| `lastRecordCommandTime`（@ObservationIgnored） | **最后一次向引擎发送「record」命令的时间。心跳周期 1s，命令刚发出时引擎还没来得及上报，若不设宽限期，UI 会在下一次 tick（30Hz）立刻把 isRecording 弹回旧值 → 开关按下即回弹** |
| `engineVersionWarning` | **引擎协议版本不匹配时的用户可见告警（空 = 无告警）** |

**驾驶核心字段（第 5039–5125 行）：**

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（默认 .e2e） | **当前驾驶模式（由降级状态机计算，每帧 tick 同步）——UI 观察此属性刷新模式芯片高亮** |
| `confidence`（默认 0.92） | 置信度 0~1 |
| `lastDecided`（private，默认 .e2e） | **上一帧状态机决策档位。⚠️ 2026-09-30 起 `.recover` 已删——现在仅作诊断留档，先比后写（不再做边沿检测）** |
| `effectiveSpeed`（默认 0） | **有效车速（km/h）：每帧由 OCR 新鲜读数（EMA 平滑）或一阶滤波回退计算——供 M9 vehicle_state、卡死判据、脱困退出使用（替代原模拟速度）** |
| `speedValid` | **有效车速是否新鲜（OCR 读数新鲜：lastResultTime < 0.5s 且 confidence > 0.3）——不新鲜时卡死判据不计入 stuckSeconds；感知融合层可直接消费此健康标志** |
| `speed`（计算属性） | **兼容属性：旧代码读 speed 的地方统一读到 effectiveSpeed（不再有模拟值/随机抖动）** |

**显示与 OCR 字段（第 5127–5154 行）：**

| 成员 | 说明 |
|---|---|
| `fps`（默认 60） | 标称帧率 |
| `speedKmh`（计算属性） | **车速 OCR 最新快照：`EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh`**——读自 speedOCR（@Observable 嵌套，body 访问会跟踪其更新） |
| `speedConfidence`（计算属性） | speedOCR.confidence |
| `m9Status`（计算属性） | **M9 推理链路状态（UI 显示：M9 到底有没有真的在参与开车）**——`M9未加载`（!isLoaded，tertiary）/ `M9活跃`（**模型已加载 && 最近 1s 内出过推理结果 → 真在开车**，cyan）/ `M9失联`（**结果超过 1s 没更新（没画面/推理卡死）→ 没参与**，danger） |
| `speedLimit`（默认 120） | 速度上限——**不是显示项，经 InferenceEngine 变成 vehicle_state[4] 参与推理**（见 代码-06 的 config 命令） |
| `degradeThreshold`（默认 0.65） | 降级阈值（同步给状态机，UI 可调） |
| `modelVersion` / `frames` | "v2.4.1-e2e-fsd" / 128_402（**装饰性展示值**） |

## 四、跳帧防堆积与诊断尺子

> 新锚点：跳帧缓冲 pendingFrame/pendingYolo/pendingNative AuroraDriveApp.swift（写侧 5985-5997 / 6000-6006 / 6029-6036）；引擎实例 AuroraDriveApp.swift 中（captureEngine/controlEngine 等）；`mode` AuroraDriveApp.swift、`confidence` AuroraDriveApp.swift、`effectiveSpeed` AuroraDriveApp.swift、`speedValid` AuroraDriveApp.swift、`speedLimit` AuroraDriveApp.swift、`degradeThreshold` AuroraDriveApp.swift、`currentCommand` AuroraDriveApp.swift、`upscaleEnabled` AuroraDriveApp.swift、`gameModeBoost` AuroraDriveApp.swift。

**画面流与显示字段（第 5156–5166、5273 行）：**

| 成员 | 说明 |
|---|---|
| `currentScreenImage: NSImage?`（**@ObservationIgnored**） | 由 CaptureEngine 的 onFrame 闭包更新，仍是录制/现有引用的数据源 |
| `currentFrameCG: CGImage?`（@ObservationIgnored） | **同源（同一回调直传的 CGImage），供推屏/推理/置信度使用，省 NSImage→CGImage 重复转换** |
| `frameHost = FrameHost()` | **UI 显示已改走 frameHost 直绘（绕开 SwiftUI diff）**，故两者均标 @ObservationIgnored |
| `screenSize: CGSize?`（普通 @Observable） | **源画面尺寸——驱动 ObstacleOverlay 的 aspect-fill 对齐**。注释（5163–5165 行）："**不能从 @ObservationIgnored 的 frameHost.latestSize 读，否则尺寸变化不触发观察导致检测框错位；仅在尺寸变化时写，避免每帧失效**" |
| `isStreaming`（普通 @Observable） | **控制 GameViewportView 显示"实时画面 vs 黑底提示"分支，启/停各翻转一次——必须保持 @Observable（观察成本可忽略），否则停止后分支不触发重绘导致画面冻结** |

**插帧/超分字段（第 5275–5321 行）**：

- `upscaleHost = UpscaleFrameHost()`（@ObservationIgnored）——插帧帧宿主
- `upscaleEnabled: Bool = false` / `upscaleSupported` / `upscaleLive: String?` / `upscaleEngineError: String?`——插帧状态四件套
- **仅显示路径，绝不进入决策链路**（5275 行注释）——插帧是给"人眼看得更顺"的，YOLO/OCR/E2E 走各自直通路径
- **`gameModeBoost: Bool = true { didSet ... }`（5308–5321 行）**——游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权）：值变化时 `applyMainThreadBoost(gameModeBoost)`（见 代码-24 单元三）+ **启用时 `startAntiFreeze()` 加强心跳防冻结 / 关闭时 `stopAntiFreeze()`**

**跳帧防堆积（第 5450–5473 行，用户拍板方案）：**

- **设计（5450–5453 行注释）**："onFrame 在 captureQueue 线程只「**覆盖**」最新一帧（**不 main.async 排队**）；tick 主线程每帧取最新一帧给 UI——主线程处理不过来时**旧帧被覆盖丢弃，永不堆积（= 强制同步跳帧）**。捕获/推理频率不变（30fps 红线）"
- **`pendingFrame / pendingFrameCG / pendingFrameTime`（nonisolated(unsafe) private）** + `pendingFrameLock = NSLock()`——覆盖式最新帧三件套 + 锁
- **`pendingYoloFrame: CVPixelBuffer?` + `pendingYoloLock`（5463–5467 行）**——**YOLO 直通帧跳帧（同 pendingFrame 模式）：captureQueue 覆盖最新帧，tick 消费**
- **`pendingNativeFrame: CVPixelBuffer?` + `pendingNativeLock`（5469–5473 行）**——**原生 ROI 帧跳帧（同模式）：OCR/字模录制消费**
- 三组跳帧缓冲全部 `nonisolated(unsafe)` + NSLock——**跨线程覆盖写/读的统一模式**

**诊断字段（第 5325、5445–5523 行）：**

| 成员 | 说明 |
|---|---|
| `frameDeliveryLagMs`（nonisolated(unsafe)） | **onFrame 帧从入队到主线程执行的延迟(ms)——验证"越到后面越卡=积压"：若该值随时间持续增长 → main 队列积压确认（每帧 main.async + 22MB 大图堆积）**（旧架构的诊断尺子，跳帧方案后应恒定） |
| `lastTickTime` / `tickGapMs` | **主线程 tick 实际间隔(ms)（>33ms = 主线程掉拍/被卡）——tick 由 30Hz Timer 驱动，间隔应稳定 ~33ms；出现 66/99ms 或更大 = 主线程被阻塞** |
| `antiFreezeTimer`（private @ObservationIgnored） | **防冻结心跳定时器（游戏模式下强制唤醒主线程）** |
| `processMemoryMB() -> Double`（第 5513–5523 行） | **进程物理内存占用（MB）——诊断用：积压 → 内存随时间线性上涨的验证指标**：`task_info(MACH_TASK_BASIC_INFO)` → `resident_size / 1024 / 1024`；KERN_SUCCESS 才返回，否则 0 |

**引擎实例字段（第 5525–5656 行）：**

| 成员 | 说明 |
|---|---|
| `captureEngine = CaptureEngine()`（let） | **截屏引擎实例（启动时创建，全屏画面流 30fps）——isDriving 启动时 start()，停止时 stop()** |
| `gameHUD = GameHUDWindow()`（let） | **游戏画面左上角帧率 HUD（绿色两行：辅助帧率/游戏帧率）——兼作对抗 Game Mode 的"可见窗口"（见 GameHUDWindow.swift 头注释）** |
| `capturePermissionDenied` | 截屏权限状态（首次启动若未授权，引导用户到系统设置） |
| `controlEngine = ControlEngine()`（let） | **按键注入引擎（CGEvent 控制 WASD/空格/Shift）——启动时检查辅助功能权限，停止时释放所有按住的键** |
| `controlPermissionDenied` | 辅助功能权限状态 |
| `keyboardMonitor = KeyboardMonitor()`（let） | **物理键盘监听——与 controlEngine 区别：controlEngine = AI 注入的按键（输出）；keyboardMonitor = 用户物理按下的键（输入，仅显示用 + 录制专家演示）** |
| `degradeStm = DegradeStateMachine()`（let） | **降级状态机（四态 + 极速覆盖 + 卡住检测）——tick() 每帧调用 update()，结果同步到 self.mode；阈值由本类的 degradeThreshold 等属性同步过去，UI 可调** |
| `recordEngine = RecordEngine()`（let，5653–5656 行） | **行驶录制引擎——isRecording didSet 触发启停，tick() 每帧调用 appendFrame；兼容现有 recordings 格式，供 DAgger 增量训练消费** |

## 五、三段胶水、startDriving / stopDriving

> 新锚点：`startDriving()` AuroraDriveApp.swift、`stopDriving()` AuroraDriveApp.swift。组件持有：captureEngine AuroraDriveApp.swift / gameHUD AuroraDriveApp.swift / controlEngine AuroraDriveApp.swift / keyboardMonitor AuroraDriveApp.swift / degradeStm AuroraDriveApp.swift / ruleController AuroraDriveApp.swift / confidenceEst AuroraDriveApp.swift / inferenceEngine AuroraDriveApp.swift / assistEngine AuroraDriveApp.swift / yoloEngine AuroraDriveApp.swift / yolopxEngine AuroraDriveApp.swift / egoBoxFilter AuroraDriveApp.swift / driveSegment AuroraDriveApp.swift / fallbackGuard AuroraDriveApp.swift / speedOCR AuroraDriveApp.swift / questPanel AuroraDriveApp.swift。

**旧网络定位已移除（5658–5662 行注释）**：`NetworkPacketCapture` 已移除（不编译），**使用移植的 NetworkLocator**。

**三段胶水代码（第 5664–5675、5695–5700、5896、5909 行，接模型输出 → 状态机 → 按键注入）：**

| 实例 | 说明 |
|---|---|
| ~~`escapeController`~~ | **已删除（2026-09-30，脱困档整体移除）**——AuroraDriveApp.swift 注释明确；旧文此行作废 |
| `ruleController = RuleController()`（AuroraDriveApp.swift） | **.yolo/.rule 态 YOLO 检测→控制量规则** |
| `confidenceEst = ConfidenceEstimator()` | **E2E 无置信度头，用启发式从输出/画面估算** |
| `inferenceEngine = InferenceEngine()` | **CoreML E2E 推理引擎（m9_mono）——tick 异步触发推理，读 lastResult 作为本帧 E2E 输出；推理约 24Hz，tick 30Hz，未完成推理时沿用上一帧结果** |
| `assistEngine = InferenceEngine(modelFileName: "game_assist_control")` | **第二套驾驶模型（YOLO接管档的司机）——与 M9 同架构（画面+车辆状态→steer/throttle/brake），独立权重文件。档2 YOLO接管用它的输出开车；当前与 M9 同权重，后续可换训练权重** |
| `yoloEngine = YoloEngine()` | **CoreML YOLO 检测引擎——tick 异步触发**。⚠️ **2026-10-19 订正**：旧文写「检测结果同时喂 RuleController 决策 + UI 画框」**已不同源**——现码 RuleController 只吃 `effectiveDetections`（`AuroraDriveApp.swift:7538` 定义 → `:7753` `ruleController.decide`），UI 画框走 `state.displayDetections`（`MissionConsole.swift:609`），两条链路在 `:4236` 就已分家、不经 RuleController。另：A 模型档（默认档）下本引擎**不加载、不推理**（仅 legacy 三件套档加载，详见 `代码-14` 文首「2026-10-19 档位语义变更」） |
| `speedOCR = SpeedOCRReader()` | **车速表 OCR 读取引擎——CaptureEngine 原生帧 → 后台 OCR 读车速 → 主线程读 speedKmh/speedConfidence** |
| `currentCommand: ControlCommand = .idle`（private(set)） | **本帧最终决策命令（tick 末尾写出，供按键注入用）** |

**`init()`（第 5911–6180 行）——接线与 HUD 安装：**

1. `try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")`——**每次启动清空调试日志**（新会话从干净日志开始）
2. **帧率 HUD 接线（5925–5934 行）**：`gameHUD.fpsProvider = { (assist, game) }`——**辅助帧率 = 主线程 tick 速率（1000/tickGapMs）；游戏帧率 = ScreenCaptureKit 实际捕获到的合成帧率（≈游戏渲染帧率）**
3. **★ 仅 UI 进程安装（5935–5965 行注释）**：`if !CommandLine.arguments.contains("--engine") { gameHUD.install() }`——**引擎进程（--engine）也创建 DriveState，但它没有 NSApplication UI 上下文，在其中创建 NSWindow 会触发 AppKit 断言崩溃（实测：NSViewSetCurrentlyBuildingLayerTreeForDisplay, NSView.m:12937，导致引擎「就绪」后 1ms 即崩、UI 显示失联）**
4. **onFrame 接线（5966–5997 行）——跳帧防堆积**：captureQueue 后台线程**只"覆盖"最新待显示帧（加锁），不再 main.async 排队**——"主线程（tick）卡时，旧帧被下一帧覆盖丢弃 → 天然跳帧，永不积压。SwiftUI 更新由 tick 在主线程赋 currentScreenImage 触发"；**NSImage + CGImage 同回调原子写入，避免推屏/推理/录制跨帧错位**
5. **onYoloFrame 接线（5998–6025 行）**：CaptureEngine 源头缩放好的缓冲**直接喂推理引擎（跳过 NSImage/CGImage 大图转换 → 检测帧率↑）**——跳帧覆盖式（不往 main 队列堆积 1.6MB 缓冲）
6. **onNativeFrame 接线（6026–6036 行）**：**P1-2：字模录制复用同一条原生 ROI 直通（speedROINorm 与 glyphROI 同区域），直接把原生缓冲交给 RecordEngine 存字模 PNG（数字 ~95px，不再走 480px 缩略图）**
7. **onUpscaleFrame 接线（6037–6041 行）**：全分辨率帧 → `upscaleHost.push`（**仅显示路径**）
8. **onStatusChange 接线（6044–6105 行）**：permissionDenied → capturePermissionDenied=true；started → false + isStreaming=true；stopped/error → isStreaming=false + **frameHost.clear()（画面回落黑底，避免常驻 + 重启闪旧帧）** + **三组 pending 帧全部清空（6090–6102 行）——"清残留 pending 帧，避免停止后下一 tick 消费旧帧再 push（重启闪旧帧）"**（三把锁逐个清）
9. `upscaleHost.prepare()` + `upscaleSupported = isAvailable` + dlog
10. **EngineClient.onActivated 接线（6141–6159 行）**：**引擎（重新）连上时把 UI 当前的画面档位同步给引擎——否则引擎默认发 480 宽缩略帧，UI 开着插帧就会一直等不到全分辨率帧**：`setUpscale(upscaleEnabled && upscaleSupported)` + `sendCommand("status")`
11. 旧网络定位回调已移除（6161–6178 行注释）+ dlog

**`startDriving()`（第 6182–6289 行）——启动自动驾驶，引擎模式分支：**

- **引擎模式（6188–6196 行）**：`EngineClient.shared.isActive` 时——`sendCommand("start")` + lastDriveCommandTime + isDriving=true + drivingStartTime → **return（UI 不启动本地抓屏/推理/按键）**
- **本地模式（6197–6289 行）**：
  1. `guard controlEngine.checkPermission()`——无权限 → controlPermissionDenied=true + `openAccessibilitySettings()`（引导授权）+ return
  2. **开始驾驶前清掉系统里残留的卡键（6256–6258 行）**："上次进程异常退出可能留下未释放的 W/A/S/D，污染游戏输入；releaseAll 无条件清理"
  3. isDriving=true + drivingStartTime + `keyboardMonitor.start()`（KeyboardBar + 录制用）+ `captureEngine.start()`
  4. **三模型 loadIfNeeded（6282–6286 行）**：M9 / assistEngine（第二司机）/ yoloEngine——**首次启动加载**
  5. dlog 启动状态（权限/专家/禁用 + 三模型加载结果）

**`stopDriving()`（第 6291–6321 行）——停止自动驾驶：**

- **引擎模式（6298–6305 行）**：`sendCommand("stop")` + lastDriveCommandTime + isDriving=false → return（**引擎侧释放按键并停止抓屏**）
- **本地模式（6306–6321 行）**：isDriving=false → `controlEngine.releaseAll()`（**1. 释放所有按住的键，避免按键卡住**）→ `keyboardMonitor.stop()` → `captureEngine.stop()` → **4. 重置链**（AuroraDriveApp.swift）：`degradeStm.reset()` + `confidenceEst.reset()` + `inferenceEngine.reset()` + `inferenceEngineV2.reset()`（V2 时序环形缓冲 + 冷启动门控）+ `assistEngine.reset()` + `yoloEngine.reset()` + `speedOCR.reset()`（**escapeController.reset 已随脱困删除**） → `currentCommand = .idle` → **5. `if isRecording { isRecording = false }`（didSet 会触发 recordEngine.stop()，保证 meta.json 落盘）**

## 六、档位开关 / 防冻结禁用 / 一键训练与模型热部署

> 新锚点（**2026-10-17 实测**）：`setUpscaleEnabled` **AuroraDriveApp.swift**、`setGameModeBoost` **AuroraDriveApp.swift**、`startTraining` **AuroraDriveApp.swift**、`deployTrainedModel` **AuroraDriveApp.swift**、`clearRawClips` **AuroraDriveApp.swift**。

**`setUpscaleEnabled(_ on: Bool)`（第 6340–6349 行）**——插帧/超分开关：

1. `upscaleEnabled = on` + `captureEngine.upscaleEnabled = on`（采集侧同步）
2. **引擎模式（6343–6347 行注释）**：**通知后台引擎切画面档位（全分辨率 ↔ 480 宽缩略），否则引擎不知道 UI 开没开插帧，会一直发缩略帧导致插帧没数据**——`EngineClient.shared.setUpscale(on)`
3. dlog 开关状态

**`setGameModeBoost(_ on: Bool)`（第 6351–6369 行）**——游戏模式兼容开关：

1. `gameModeBoost = on`（didSet 会触发 applyMainThreadBoost——见单元四）+ `captureEngine.gameModeBoostEnabled = on`（捕获线程同步）+ `applyMainThreadBoost(on)`（**主线程时间约束调度**）
2. **开启时（6356–6364 行）**：`startAntiFreeze()` + **检查是否已安装 daemon，未安装则弹出安装引导**——`DaemonSetupManager.needsInstall()` → 延迟 0.5s 弹出（**避免与启动时的弹窗冲突**）`showDaemonInstallSheet = true`
3. 关闭时：`stopAntiFreeze()`

**防冻结心跳已禁用（第 6371–6384 行，诚实标注）：**

- **`startAntiFreeze()`——已禁用，不再启动心跳**——源注释（6373–6377 行）："**原因：每 100ms 发送键盘事件导致系统崩溃，鼠标无法移动**"——只 dlog"[antifreeze] 心跳已禁用（避免系统崩溃）"
- `stopAntiFreeze()`：antiFreezeTimer cancel + nil（残留清理保留）

**`startTraining()`（@MainActor，第 6386–6445 行）——一键训练（拉起 Python 训练进程）**：

- **注释（6388–6392 行）**："拉起 python3.11 训练脚本（**只训控制模型**）：`--skip_view`（视角分类器按决策删除不做，不训练）+ `--skip_yolo`（YOLO 用现成预训练 CoreML，无需重训）。**训练完成后自动把新控制模型热替换进推理引擎（点完即用）**。进程后台运行，UI 按钮文字切到「训练中…」，结束经 terminationHandler 回主线程"

1. `guard !isTraining` → isTraining=true + trainingLog="启动训练进程…"
2. **Process 组装（6399–6422 行）**：`/usr/local/bin/python3.11` + `["src/train_game_assist.py", "--skip_view", "--skip_yolo"]` + currentDirectoryURL 硬编码项目根 + **输出重定向到 `train.log`（standardOutput + standardError 同一 FileHandle——"避免管道缓冲区满导致训练进程挂起"）**
3. **terminationHandler（6424–6437 行）**：主线程——isTraining=false → 成功（退出码 0）：trainingLog="训练完成，应用新模型…" → `deployTrainedModel()` 成功才 `clearRawClips()`；失败：trainingLog="训练失败（退出码 N），详见 train.log"
4. `try proc.run()`；失败 isTraining=false + "无法启动训练"

**`deployTrainedModel() -> Bool`（@discardableResult，第 6447–6496 行）——把训练产出的控制模型复制到 m9_mono 并热替换：**

- **注释（6447–6450 行）**："**优先 FPV 专用模型（当前录制为 FPV 视角），回退 TPV/FPV 共用模型**。扩展名跟随源：若 coremlcompiler 缺失，coremltools 仍会 save 出 .mlpackage，**CoreML 运行时可直接加载未编译的 .mlpackage，链路照样闭环**"

1. **四候选（6456–6461 行）**：`game_assist_control_fpv.mlmodelc` / `game_assist_control.mlmodelc` / `game_assist_control_fpv.mlpackage` / `game_assist_control.mlpackage`——第一个存在的入选；全无 → "未找到训练产出的控制模型，请检查 train.log" + false
2. **清理旧模型（6464–6474 行）**：**清理另一扩展名的旧模型，避免 InferenceEngine.modelURL 误选**（两种 ext 各删 m9_mono）+ 删目标位置的旧文件
3. `copyItem(at: src, to: dst)`——dst = `m9_mono.{src扩展名}`
4. **引擎模式分支（6476–6490 行注释）**："**模型文件已落盘；但真正开车的推理引擎可能不在本进程：引擎模式 → 命令引擎重新加载（否则引擎一直用内存里的旧模型）；本地模式 → 直接置空本进程的三个引擎**"——引擎模式：`sendCommand("reloadmodel")` + `inferenceEngine.reloadModel()` + trainingLog"已应用新模型（引擎侧已通知重载）"；本地模式：**三引擎全部 reloadModel()**
5. 失败 → "模型部署失败"

**`clearRawClips()`（第 6498–6516 行）——训练成功且模型部署后，清理 data/raw_clips 下所有录制 clip：**

- **注释（6498–6500 行）**："录制数据仅用于训练，**训完即弃**，避免无限累积、下次训练重复读取旧数据。**仅在部署成功时调用；失败保留数据以便排查**"
- 列目录 → `clip_` 前缀逐个 removeItem → trainingLog"已应用新模型，并清理 N 段录制数据"；失败 → "模型已应用，但清理录制数据失败"

## 七、tickEngineMode 回声防环与 pushEngineConfigIfChanged

> 新锚点（**2026-10-17 实测**）：`tickEngineMode()` **AuroraDriveApp.swift** 起；版本守卫实测 **AuroraDriveApp.swift**（`if client.isEngineStale` :6571、`engineRelaunching` 防重入 :6572-6573、驾驶中提示 :6576-6577、无错配清空 :6579-6580）；速度回传落位实测 **AuroraDriveApp.swift**（mode/confidence/remoteSpeedKmh/effectiveSpeed/speedValid 逐个先比后写）；`pushEngineConfigIfChanged()` 实测 **AuroraDriveApp.swift**。本节逐条语义复核仍准确。

**`tickEngineMode()`（@MainActor，第 6519–6619 行）**——引擎模式下每 tick 拉取显示数据（**本地抓屏/推理/按键全部不跑**）：

1. `let client = EngineClient.shared` + `guard client.isActive else { return }`
2. **消费最新待显示帧（6530–6548 行）**：`client.poll() -> CGImage?`；非 nil 时 `currentScreenImage = image` + `currentFrameCG = cg`（**仅主线程，SwiftUI 自动刷新**）+ **帧宿主直绘** + **isStreaming = true**
   - **CVPixelBuffer 分支（6531–6541 行）**：`upscaleHost.push(pixelBuffer: pb)` + isStreaming + **源尺寸必须随帧更新（不能只在 nil 时设一次）**——"检测框叠加、框选手势的坐标换算都以 screenSize 为基准，尺寸变了却不更新 → 框错位、框选选不中"（`if screenSize != sz { screenSize = sz }`）
   - CGImage 分支（6542–6548 行）：同构 + frameHost.push
3. **引擎已停止抓屏同步收尾（6555–6563 行）**：`!client.engineIsStreaming && isStreaming` → isStreaming=false + upscaleLive=nil + **`upscaleHost.clear()`（停掉 MetalGoose 渲染 detach）** + frameHost.clear()——"**否则 isStreaming 会一直停在 true（引擎模式下只在有帧时被置 true，从不复位），导致插帧视图继续挂着、徽章一直显示'插帧中'（用户实测反馈）**"
4. **协议版本守卫（6564–6581 行）——必须放在状态镜像之前**：
   - `client.isEngineStale` 且 `!isDriving && !client.engineRelaunching` → `engineRelaunching = true` + engineVersionWarning"检测到旧版引擎，正在重启…" + **`client.relaunchStaleEngine()`**（重启旧引擎）
   - 驾驶中或重启中 → engineVersionWarning"⚠️ 引擎版本不匹配，停止驾驶后自动重启"
   - **engineRelaunching 由 EngineClient 持有并在重启完成后清除——不能用 UI 局部标志，否则重启流程中途 isEngineStale 仍为真时会无限重复触发**（6569–6570 行注释）
   - 无错配时清空警告
5. **驾驶状态回传落位（6582–6589 行）**：**引擎模式下 UI 不跑推理，面板/状态栏依赖的驾驶状态由引擎心跳回传后落到这里——档位、车速（含车速表读数）、置信度、有效车速。缺了这些，右侧状态栏与自车信息会「空掉」**——mode/confidence/remoteSpeedKmh/effectiveSpeed 逐个 `if !=` 才写（**逐帧无条件赋值也会触发 SwiftUI 刷新 → 只在变化时写**）；speedValid = `engineSpeedKmh >= 0 && engineSpeed > 0.5`
6. **锁定目标追踪（6590–6592 行）**：`yoloEngine.trackLockFromRemote(client.engineDetections)`——**引擎模式下必须用引擎回传的检测框推进，否则锁定框冻在原地不动、目标离开也不会自动解除**
7. **isDriving 回同步（6593–6597 行）**：**引擎是状态权威源；命令发出后 1 秒内保留 UI 乐观值，避免切换瞬间闪烁**——`Date().timeIntervalSince(lastDriveCommandTime) > 1.0` 时才镜像
8. **录制状态回同步（6599–6610 行）**：**引擎是权威源：引擎进程真正写盘，UI 只显示帧数。置 applyingRemoteRecord 防回环，否则 isRecording 的 didSet 会把命令回声给引擎。宽限期 2 秒**（心跳 1Hz + 引擎带即时回执，否则命令刚发出、心跳还没更新时会把用户刚拨的开关弹回去）；frames 镜像（引擎录制 ? engineRecordFrames : 0）
9. `pushEngineConfigIfChanged()`——**驾驶参数下发（极速/禁用控制/紧急切规则/专家/字模/降级阈值）——这些只在 tick() 里被读，而引擎模式下 tick() 跑在引擎进程——必须显式推送。只在变化时发，避免 30Hz 刷屏**
10. **插帧实时统计（6615–6618 行）**：useUpscale 时 upscaleLive 字符串（"产出 N · 透传 N · 输入 Nfps → 输出 Nfps"）

**`pushEngineConfigIfChanged()`（private，第 6742–6777 行）**：

- **快照对比**：`snap = "\(sportMode)|\(controlDisabled)|\(forceRuleMode)|\(expertMode)|\(glyphMode)|\(degradeThreshold %.3f)|\(speedLimit %.1f)"` → `guard snap != lastPushedEngineConfig`（变化检测，6783 行 lastPushedEngineConfig 默认 ""）
- `sendCommand("config", extra: [...])` 七参数——**"速度上限直接进 vehicle_state[4]，不是显示项"**（6765 行注释）

## 八、tick() 主循环——完整决策管线

> ✅ 本节行号已按 **9096 行版（2026-10-18 实测）** 重写；旧版 1837–2092 / 8335 版行号均作废。

**`tick()`（AuroraDriveApp.swift:6865 起）**——每帧推进（**20Hz**，由 MissionConsole.swift:6117 的 DispatchSource `com.aurora.tick`（`repeating: 1.0 / 20.0`）驱动，事件回调 `DispatchQueue.main.async { state.tick() }`（MissionConsole.swift:6140）——**不是 ContentView 的 Timer**，旧文有误；待机时 `idleSkip < 8` 降频至 **约 2.5Hz**（MissionConsole.swift:6197-6200，即 20Hz/8）。**完整决策管线：跳帧消费 → quest OCR → 速度/卡死 → 降级决策 → 按态输出 → 注入 → 录制**。

**① 诊断 + 引擎分流（AuroraDriveApp.swift）**：tickGapMs（实际间隔，>33ms = 主线程掉拍）；`if EngineClient.shared.isActive { tickEngineMode(); return }`（AuroraDriveApp.swift，**本地抓屏/推理/按键全部不跑**）。

**② 消费跳帧缓冲（AuroraDriveApp.swift）**：锁内取 pendingFrame/CG/Time → `frameDeliveryLagMs` → currentScreenImage/currentFrameCG 赋值（SwiftUI 刷新）→ `frameHost.push(cg)`（isStreaming 时）→ screenSize 更新。

**②.6 原生 ROI 帧消费（AuroraDriveApp.swift）**：取最新 pendingNativeFrame → `speedOCR.infer(nativePixelBuffer:)`（AuroraDriveApp.swift）+ 字模录制（`recordEngine.glyphMode && isRecording` 时 `appendGlyphNative` + frames 同步，AuroraDriveApp.swift）。

**②.5 任务面板 OCR（AuroraDriveApp.swift，2026-10-06 task-1 新增，旧文无此节）**：门 `AuroraFlags.questOCR`（AF:201，默认 true）——`if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（AuroraDriveApp.swift）；节流与在途保护在 QuestPanelReader 内部（0.7s 间隔 + ocrInFlight）。

**②.7 YOLO 直通帧 + 光流（AuroraDriveApp.swift）**：取最新 pendingYoloFrame → `yoloEngine.inferFast(pixelBuffer:)`（AuroraDriveApp.swift）；同一份 640×640 直通帧喂 `runOpticalFlow`（AuroraDriveApp.swift 中；函数定义 AuroraDriveApp.swift），受**两条闸门"与"关系**控制：`!Self.opticalFlowDisabled`（AuroraDriveApp.swift；该静态属性 AuroraDriveApp.swift 仍直接下标读 `AURORA_DISABLE_OPTICAL_FLOW`，未走 AuroraFlags——全仓残留的一处直接读）+ `perceptionMode.needsOpticalFlow`（AuroraDriveApp.swift，按档位门控：仅 `.legacy` 档跑光流）。

**③ 待机分支（AuroraDriveApp.swift）**：`guard isDriving else {` 内：`if speedValid { speedValid = false }` + `effectiveSpeed` 每帧 -6 衰减（AuroraDriveApp.swift）+ `currentCommand` 回 .idle——**全部先比后写**（AuroraDriveApp.swift 注释）；`recordFrameIfNeeded()`（**待机也写帧：录制不依赖驾驶状态**，AuroraDriveApp.swift）→ return。

**⑤ 有效车速（AuroraDriveApp.swift）**——OCR 新鲜 → EMA 追真实读数；否则一阶滤波回退：

- `ocrFresh = speedOCR.speedKmh >= 0 && confidence > 0.3 && lastResultTime < 0.5`（AuroraDriveApp.swift）→ 先比后写 `speedValid`（AuroraDriveApp.swift）
- ocrFresh → `effectiveSpeed += (ocr - effectiveSpeed) × 0.7`（**快跟踪**，AuroraDriveApp.swift）；否则 `× 0.9` 向 0 衰减（<0.5 归零，AuroraDriveApp.swift）
- `fps` 如实反映捕获帧率，**不回退成 60 伪造**（AuroraDriveApp.swift）

**⑥ 卡死 → 请求人工介入（AuroraDriveApp.swift，2026-10-02 新增）**：`isDriving && speedValid && effectiveSpeed < 1.0` 持续 ≥ `stuckZeroThreshold`（AuroraDriveApp.swift，读 `AURORA_STUCK_SECONDS`，默认 30s）→ `needsManualIntervention = true` 拉横幅。**只提示不动车——AI 绝不自行脱困**（AuroraDriveApp.swift 注释；历史教训见 FallbackGuard 取证 AuroraDriveApp.swift）；零速判据要求 `speedValid` 为真，避免「OCR 读不到就误报卡死」；车动起来立即撤横幅清计时（AuroraDriveApp.swift）。

**⑥.5 降级状态机决策（AuroraDriveApp.swift）**：暖机期 `warmingUp = inferenceEngine.lastResult == nil && 开车 < 3.0s`（AuroraDriveApp.swift）；`decided = degradeStm.update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:)`（AuroraDriveApp.swift）→ **先比后写** `if mode != decided { mode = decided }`（AuroraDriveApp.swift）。三档梯子与优先级链详见 代码-20 文档。

**⑦ 置信度估计（AuroraDriveApp.swift）**：暖机期 `if confidence != 1.0 { confidence = 1.0 }`（AuroraDriveApp.swift，先比后写）；否则 `confidenceEst.update(command:image:isLive:)`（AuroraDriveApp.swift）——喂**当前档位**驾驶模型的输出 + 画面；先比后写 AuroraDriveApp.swift。

**⑧ 按态输出控制量（AuroraDriveApp.swift）**：

```swift
switch decided {                                    // AuroraDriveApp.swift
case .e2e:  if currentCommand != m9Command { currentCommand = m9Command }         // 档1 M9 直接开车（AuroraDriveApp.swift）
case .yolo: if currentCommand != assistCommand { currentCommand = assistCommand } // 档2 第二套网开车（AuroraDriveApp.swift）
case .rule: let ruleCmd = ruleController.decide(detections: detections)           // 档3 手写规则最后防线（AuroraDriveApp.swift）
}                                                   // 全部先比后写（AuroraDriveApp.swift 注释）
```

- `detections` 已经 `effectiveDetections`（AuroraDriveApp.swift `egoBoxFilter.filter(displayDetections)`）**剔除自车框**——只作用于决策层，UI 照画全部框。
- **`.recover` 档已删除**（旧文此行作废）：脱困策略整体移除（AuroraDriveApp.swift 注释），`lastDecided` 仅作诊断留档、不再做边沿检测（AuroraDriveApp.swift 注释）。

**⑧.5 车道保持 / 驾驶分段覆盖（AuroraDriveApp.swift，2026-10-02 起生效）**：档位门 `if Self.laneKeepTiers.contains(decided)`（AuroraDriveApp.swift；`laneKeepTiers` 定义 AuroraDriveApp.swift，默认 `rule,yolo`，`AURORA_LANEKEEP_TIERS=rule` 一键回退）→ LaneFallback 车道保持 + `segmentDecisionForRule(pose:)`（AuroraDriveApp.swift 中）调用 `driveSegment.update(...)`（AuroraDriveApp.swift）：地图段/回正段的 mapSteer **覆盖**视觉转向、建议限速参与后续油门计算。

**⑨ 按键注入（AuroraDriveApp.swift）**：专家/禁用控制分支走节流版 `controlEngine.releaseAllIfNeeded()`（AuroraDriveApp.swift；旧行为每帧无条件 `releaseAll()` 由回退开关 `AURORA_RELEASE_ALL_EVERY_TICK=1` 保留，AuroraDriveApp.swift、AF:283）；否则 `applyCommand(currentCommand)`（AuroraDriveApp.swift；转向死区 ±0.1、油门/刹车互斥阈值 0.3、`refreshHeldKeys()` 每帧重发——applyCommand 定义 AuroraDriveApp.swift 中，语义与旧文一致）。

**⑩ 录制 + 插帧状态 + 调试摘要**：`recordFrameIfNeeded()`（AuroraDriveApp.swift；函数定义 AuroraDriveApp.swift 中——字模走原生路径防双写、专家模式录按键时长标签、默认录 AI 决策；键码 A=0/D=2/W=13/S=1/Space=49，AuroraDriveApp.swift 注释）；调试摘要 1Hz（写 /tmp/aurora_debug.log，AuroraDriveApp.swift 中：mode/模型存活/命令/注入权限/front 前台应用/capGap/capWork/tickGap 等；插帧统计与分段打点导出共用同一 1Hz 闸门，AuroraDriveApp.swift、:7772-7790、:7822-7835）。

## 九、recordFrameIfNeeded 与 applyCommand 按键映射

> 新锚点（**2026-10-17 实测**）：`recordFrameIfNeeded()` **AuroraDriveApp.swift** 起（glyph 跳过实测 **:7894** `guard !recordEngine.glyphMode else { return }`、专家模式键码标签实测 **:7900-7909**：`:7903-7904` A=0/D=2、`:7906` W=13、`:7908-7909` S=1/Space=49）；`applyCommand` **AuroraDriveApp.swift** 起（转向死区/互斥/refreshHeldKeys 语义不变）。

**`recordFrameIfNeeded()`（private，第 7887–7945 行）**——每帧录制写帧（画面 + 控制量），驾驶与待机共用：

1. **`guard !recordEngine.glyphMode else { return }`**——字模模式走 onNativeFrame 原生路径（appendGlyphNative），**此处跳过，避免 appendFrame 再写一遍 640px/480px 缩略图造成双写**
2. `guard isRecording, let image = currentScreenImage`
3. **控制量来源二选一（7896–7914 行）：**
   - **expertMode（专家模式）**：`RecordLabelMapper` 连续标签——`steer(leftHeld: keyboardMonitor.holdDuration(keyCode: 0), rightHeld: holdDuration(keyCode: 2))`、`throttle(wHeld: holdDuration(keyCode: 13))`、`brake(sHeld: holdDuration(keyCode: 1), spaceHeld: holdDuration(keyCode: 49))`——**标签语义：按键按住时长/满刻度时长 → 连续值（0~1，带符号），与推理端"|steer|>阈值 → 按住键 → 游戏按按住时长平滑转角"闭环一致**
   - 否则（AI 决策）：`recSteer/Throttle/Brake = currentCommand` 三元组——**默认录 AI 决策（供 DAgger 自训练）**
4. `recordEngine.appendFrame(image:steer:throttle:brake:)` + `frames = recordEngine.frameCount`

**键码对照（7768、7890 行注释）**：**与 ControlEngine 注入一致：A=0 左 / D=2 右 / W=13 油门 / S=1 刹车 / Space=49 手刹**（macOS virtualKey 体系）。

**`applyCommand(_ cmd: ControlCommand)`（private，第 8074–8103 行）**——把 ControlCommand 映射到按键注入（**steer>0 右转，<0 左转；throttle 油门；brake 刹车/倒车**）：

```swift
// 转向：死区 ±0.1，避免微抖动
if cmd.steer > 0.1 { hold(.steerRight); release(.steerLeft) }
else if cmd.steer < -0.1 { hold(.steerLeft); release(.steerRight) }
else { release(.steerLeft); release(.steerRight) }

// 油门 / 刹车互斥（不能同时按 W 和 S）
if cmd.throttle > 0.3 { hold(.throttle); release(.brake) }
else if cmd.brake > 0.3 { hold(.brake); release(.throttle) }
else { release(.throttle); release(.brake) }

// 持续按住的键按控制周期重发按下事件（等价真实键盘 auto-repeat）
controlEngine.refreshHeldKeys()
```

- **转向死区 ±0.1**：避免微抖动（E2E 输出的微小噪声不触发转向键）
- **油门/刹车互斥**（阈值 0.3）：不能同时按 W 和 S——throttle 优先（>0.3 时按 W 松 S）
- **`refreshHeldKeys()` 必须每帧调用（8099–8102 行注释）**：**持续按住的键按控制周期重发按下事件（等价真实键盘 auto-repeat）。缺了这一步，控制量稳定时（E2E 直道恒定油门）整段驾驶只会产生一个 keyDown，游戏收不到任何后续事件——表现为「UI 显示按住、车不动」**

**DriveState 状态主体文档至此完整**（4119–8103 行全覆盖：RecordLabelMapper → 开关字段 → isRecording didSet → 跳帧防堆积 → startDriving/stopDriving → 一键训练热部署 → tickEngineMode → tick() 决策管线 → 录制与按键映射）。
## 十、AuroraFlags.swift 全部开关清单（2026-10-06 逐行核实，Core/AuroraFlags.swift，543 行）

`AuroraFlags` 是环境开关的**唯一事实源**（AF:5），读取收敛到唯一入口 `raw()`（AF:89-92）；布尔语义「只有 `"1"` 算开」（AF:99-102），反向布尔「只有 `"0"` 算关」（AF:106-109）。全表 `all` 在 AF:426-510，`--flags-help` 由 `helpText()`（AF:521-530）打印。

唯一例外：`egoCheck` **刻意不 static let 化**，每次现读（AF:235），因 AuroraDriveApp.swift 的自检会在运行时 `setenv("AURORA_EGO_CHECK","off",1)` / AuroraDriveApp.swift `unsetenv`（佐证 EgoMotionModel.swift:207-208）。

> ⚠️ **已发现的源码内不一致（文档如实记录，未改产品代码）**：`all` 表中 `AURORA_QUEST_OCR` 条目仍写 `defaultValue: "0"`、"默认关"（AF:445），与实际声明 `questOCR = bool("AURORA_QUEST_OCR", default: true)`（AF:201，2026-10-06 改默认开）**自相矛盾**——`--flags-help` 会打印错误的默认值。

### A. 运行模式 / 进程（AF:133-152）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| uiLocal | AURORA_UI_LOCAL | false | AF:138 |
| daemonMode | AURORA_DAEMON_MODE | false | AF:141 |
| observeOnly | AURORA_OBSERVE_ONLY | false | AF:145 |
| tccTest | AURORA_TCC_TEST | (未设) | AF:148 |
| apiKey | AURORA_API_KEY | (未设) | AF:152 |

### B. 引擎 / IPC / 网络（AF:154-168）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| engineDiagSkipTCC | AURORA_ENGINE_DIAG_SKIP_TCC | false | AF:159 |
| engineDiagCaptureOnly | AURORA_ENGINE_DIAG_CAPTURE_ONLY | false | AF:162 |
| legacyProto | AURORA_LEGACY_PROTO | false | AF:165 |
| nicTestTarget | AURORA_NIC_TEST_TARGET | "49.232.46.87" | AF:168 |

### C. 推理 / 感知（AF:170-201）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| ayolom | AURORA_AYOLOM | (未设→A-YOLOM) | AF:175 |
| inferQoS | AURORA_INFER_QOS | (未设) | AF:178 |
| yolopxIntervalMs | AURORA_YOLOPX_INTERVAL_MS | 0 | AF:181 |
| yolopxLetterboxMain | AURORA_YOLOPX_LETTERBOX_MAIN | false | AF:184 |
| skipModelLoad | AURORA_SKIP_MODEL_LOAD | false | AF:187 |
| ocrDebug | AURORA_OCR_DEBUG | false | AF:190 |
| **questOCR** | **AURORA_QUEST_OCR** | **true**（2026-10-06 改默认开，注释 AF:192-200） | **AF:201** |

### D. 光流 / 自车运动（AF:203-273）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| disableOpticalFlow | AURORA_DISABLE_OPTICAL_FLOW | false | AF:211 |
| egoArea | AURORA_EGO_AREA | 0.04（含 isFinite/非负校验 AF:219-226） | AF:219 |
| **egoCheck** | AURORA_EGO_CHECK | (未设=开，**每次现读**) | AF:235 |
| egoMaxFwd | AURORA_EGO_MAX_FWD | 0.5 | AF:238 |
| egoMaxFlowPx | AURORA_EGO_MAX_FLOW_PX | 80.0 | AF:240 |
| egoResidualRatio | AURORA_EGO_RESIDUAL_RATIO | 0.6 | AF:242 |
| egoMinConf | AURORA_EGO_MIN_CONF | 0.35 | AF:244 |
| egoDiag | AURORA_EGO_DIAG | false | AF:258 |
| keyRefreshHz | AURORA_KEY_REFRESH_HZ | 0（有效 (0,60]，越界回 0） | AF:270-273 |

### E. 驾驶 / 控制（AF:275-302）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| laneKeepTiers | AURORA_LANEKEEP_TIERS | (未设→`rule,yolo`，解析在 AuroraDriveApp.swift 中 / 消费 AuroraDriveApp.swift) | AF:280 |
| releaseAllEveryTick | AURORA_RELEASE_ALL_EVERY_TICK | false | AF:283 |
| stuckSeconds | AURORA_STUCK_SECONDS | 30 | AF:286 |
| enableBgDrift | AURORA_ENABLE_BG_DRIFT | false | AF:289 |
| segStraightenDeg | AURORA_SEG_STRAIGHTEN_DEG | 15.0 | AF:292 |
| segStraightenDoneDeg | AURORA_SEG_STRAIGHTEN_DONE_DEG | 8.0 | AF:294 |
| segHandoverM | AURORA_SEG_HANDOVER_M | 15.0 | AF:296 |
| segHandoverFrames | AURORA_SEG_HANDOVER_FRAMES | 10 | AF:298 |
| segCorridorM | AURORA_SEG_CORRIDOR_M | 8.0 | AF:300 |
| segMapTimeoutS | AURORA_SEG_MAP_TIMEOUT_S | 20.0 | AF:302 |

> 口径提醒：`AURORA_STUCK_SECONDS` 的**实际消费者**是 AuroraDriveApp.swift 的 `stuckZeroThreshold`（直接下标现读，未走 AuroraFlags）；AuroraFlags.stuckSeconds（AF:286）为收敛层声明，两条读取路径并存。

### F. 路网 / 弯道引导（AF:304-333，readBy 均为 Inference/RoadCornerGuide.swift，AF:468-480）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| cornerLookaheadM | AURORA_CORNER_LOOKAHEAD_M | 40.0 | AF:309 |
| cornerHeadingTolDeg | AURORA_CORNER_HEADING_TOL_DEG | 60.0 | AF:311 |
| cornerDeadbandDeg | AURORA_CORNER_DEADBAND_DEG | 8.0 | AF:313 |
| cornerSatDeg | AURORA_CORNER_SAT_DEG | 35.0 | AF:315 |
| cornerPassedM | AURORA_CORNER_PASSED_M | 15.0 | AF:317 |
| cornerConeDeg | AURORA_CORNER_CONE_DEG | 75.0 | AF:319 |
| cornerTightRM | AURORA_CORNER_TIGHT_R_M | 80.0 | AF:321 |
| cornerTightSpeed | AURORA_CORNER_TIGHT_SPEED | 40.0 | AF:323 |
| juncLookaheadM | AURORA_JUNC_LOOKAHEAD_M | 45.0 | AF:325 |
| juncApproachM | AURORA_JUNC_APPROACH_M | 25.0 | AF:327 |
| juncExcludeDeg | AURORA_JUNC_EXCLUDE_DEG | 35.0 | AF:329 |
| juncForkTolDeg | AURORA_JUNC_FORK_TOL_DEG | 25.0 | AF:331 |
| juncReachRatio | AURORA_JUNC_REACH_RATIO | 1.2 | AF:333 |

### G. 地图 UI（AF:335-392）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| mapWindow | AURORA_MAP_WINDOW | false | AF:340 |
| mapTileWindow | AURORA_MAP_TILE_WINDOW | true（boolNotZero） | AF:352 |
| baseMapGrade | AURORA_BASEMAP_GRADE | true（boolNotZero） | AF:359 |
| mapSpanM | AURORA_MAP_SPAN_M | (未设) | AF:361 |
| mapLayers | AURORA_MAP_LAYERS | (未设) | AF:363 |
| mapLegacyMarkers | AURORA_MAP_LEGACY_MARKERS | false | AF:365 |
| mapFilterBar | AURORA_MAP_FILTER_BAR | true（boolNotZero） | AF:367 |
| mapNoMarkers | AURORA_MAP_NO_MARKERS | false | AF:369 |
| mapMaxLabels | AURORA_MAP_MAX_LABELS | (未设) | AF:371 |
| mapNoLoadNorm | AURORA_MAP_NO_LOADNORM | false | AF:374 |
| mapLabelSpanM | AURORA_MAP_LABEL_SPAN_M | (未设) | AF:376 |
| mapClusterPx | AURORA_MAP_CLUSTER_PX | (未设) | AF:378 |
| mapClusterPriority | AURORA_MAP_CLUSTER_PRIORITY | (未设) | AF:380 |
| mapClusterTrace | AURORA_MAP_CLUSTER_TRACE | false | AF:382 |
| mapDefaultGroups | AURORA_MAP_DEFAULT_GROUPS | (未设) | AF:384 |
| markerTaxonomy | AURORA_MARKER_TAXONOMY | (未设) | AF:386 |
| routeGraph | AURORA_ROUTE_GRAPH | (未设) | AF:388 |
| routeStraight | AURORA_ROUTE_STRAIGHT | false | AF:390 |
| routeTurnW | AURORA_ROUTE_TURN_W | (未设) | AF:392 |

### H. 性能 / 日志（AF:394-410）+ I. 缓存（AF:412-418）

| 属性 | env | 默认 | 行号 |
|---|---|---|---|
| perf | AURORA_PERF | false | AF:399 |
| perfRounds | AURORA_PERF_ROUNDS | 6 | AF:401 |
| logSync | AURORA_LOG_SYNC | false | AF:403 |
| disableHUD | AURORA_DISABLE_HUD | false | AF:405 |
| benchDrain | AURORA_BENCH_DRAIN | false | AF:407 |
| benchDragPx | AURORA_BENCH_DRAG_PX | 8 | AF:410 |
| cacheEnabled | AURORA_CACHE | true（boolNotZero） | AF:418 |

⚠️ 口径说明：上表为 `AuroraFlags` 的 static 属性全集（按分区合计 74 个：A5+B4+C7+D9+E10+F13+G19+H6+I1）。文件头自述「72 个变量」（AF:10、AF:86）为 2026-10-04 落地时的统计，与当前属性数已不完全一致（差异来源未验证：应为后续分区新增，未逐一考古）。另：`AURORA_DISABLE_OPTICAL_FLOW` 在 AuroraDriveApp.swift 仍有**独立重复读取**（`Self.opticalFlowDisabled`，未走 AuroraFlags）；`AURORA_STUCK_SECONDS` 在 AuroraDriveApp.swift 同样直接下标读（见 E 区口径提醒）。

## 十一、线程 / 队列模型（2026-10-06 核实）

### 11.1 队列清单

| 队列 label | 定义处 | QoS | 用途 |
|---|---|---|---|
| `aurora.capture`（captureQueue） | CaptureEngine.swift:91 | userInteractive | **SCStream sampleHandlerQueue**（CaptureEngine.swift:237）：每帧拷贝逻辑见 :120 注释/实现；串行清理缓冲池（:269-272） |
| `aurora.quest.ocr`（ocrQueue） | QuestPanelReader.swift:483 | utility | Vision OCR 专用。**刻意不复用 captureQueue**：SCStream 队列上同步计算会推迟帧消费引发雪崩（capGap 11ms→2081ms 实测，QPR:477-482 注释）；OCR .accurate p50 33.6ms ≈ 整帧预算（QPR:524-528 注释） |
| `com.aurora.speedocr` | SpeedOCRReader.swift:200 | userInteractive | 速度表 OCR |
| `com.aurora.speedocr.modelload` | SpeedOCRReader.swift:223 | serial | 模型加载 |
| `com.aurora.yolo` | YoloEngine.swift:145 | userInteractive | YOLO 检测推理（:307 提及避免与 captureQueue 写竞争） |
| `com.aurora.inference` | InferenceEngine.swift:111 | userInteractive | M9/assist E2E 推理 |
| `com.aurora.yolopx` | YolopxEngine.swift:445 | env `AURORA_INFER_QOS=interactive` 可覆盖（默认 userInitiated，YolopxEngine.swift:441-443） | YOLOPX/A-YOLOM 推理 |
| `agent.skill`（workQueue） | AIAgentPanel.swift:**263** | userInteractive | AI 技能工作队列 |
| `aurora.engine.client` | EngineClient.swift:156 | userInteractive | UI 侧 socket 读 + 重连定时器 |
| `aurora.engine.socket` | EngineMain.swift:457 | userInteractive | 引擎侧 socket 服务 |
| `aurora.engine.tick` | EngineMain.swift:1061 | userInteractive | 引擎 30Hz tick 定时源，**回调再 main.async 进主线程**（:784-789） |
| `aurora.engine.heartbeat` | EngineMain.swift:1090 | （默认） | 引擎 1Hz 心跳（:797） |
| `aurora.engine.signal` | EngineMain.swift:976 | （默认） | SIGTERM/SIGINT 处理，置 shutdownRequested 后 main.async 安全停车（:694-709） |
| `aurora.defender` | GameModeDefender.swift:153 | userInteractive | Game Mode 对抗，每 3s 重主张（:19、:94） |
| `aurora.privilege.process` | PrivilegePill.swift:251 | utility | 提权脚本执行 |
| `com.aurora.tick` | MissionConsole.swift:6111 | userInteractive | 地图控制台 tick 驱动（30Hz / 待机 3.75Hz），回调 main.async（:5558） |
| `com.aurora.netlocate` | MissionConsole.swift:6186 | userInteractive | 网络定位轮询 10Hz，回调 main.async（:5607） |
| `com.aurora.logsink` | AuroraDriveApp.swift:**8969** | utility | 日志缓冲写盘 |
| `aurora.upscale.ingest` | AuroraDriveApp.swift:**8733** | userInitiated | 插帧 ingest |
| `com.aurora.record.write` | RecordEngine.swift:128 | （默认/unspecified） | 录制写盘 |
| `com.aurora.confidence.brightness`（brightnessQueue） | ConfidenceEstimator.swift:217-218 | userInitiated | 画面亮度估计 |

### 11.2 主线程 / 后台分工（关键事实）

- **主线程（MainActor）**：`DriveState.tick()` 全部决策（AuroraDriveApp.swift 中；DegradeStateMachine 仅主线程访问 DegradeStateMachine.swift:23）；`tick()` 由 `com.aurora.tick` DispatchSource 触发后 `DispatchQueue.main.async` 投递（MissionConsole.swift:5558）；`EngineGlobals` 全部 @MainActor（EngineMain.swift:582-590）；QuestPanelReader 的投票/匹配/落库回主线程（QPR:557，onConfirmed 主线程执行 AuroraDriveApp.swift 注释）。
- **captureQueue 特殊性**：它是 SCStream 采样队列，「不是普通后台队列」（AuroraDriveApp.swift 注释）；回调里只做**覆盖式写 pendingFrame**（加锁，AuroraDriveApp.swift），SwiftUI 更新由 tick 主线程消费（AuroraDriveApp.swift）。光流曾于 09-27 被移到 captureQueue，09-28 **已回退主线程 tick**（AuroraDriveApp.swift 注释、AuroraDriveApp.swift 说明）。
- **引擎进程**：30Hz tick 定时器在 `aurora.engine.tick` 触发但计算 `tickOnce()` 强制回主线程（EngineMain.swift:781-791）；共享内存 BGRA 双缓冲由引擎写/UI 读（EngineMain.swift:18 注释、:353/:378 写入）；`latestFullFrame` 采集线程写/主线程读 + NSLock（EngineMain.swift:592-593、:763-766 写侧 / :891-893 读侧）。
- **跳帧防堆积模式**（贯穿全项目）：生产者（后台队列）只覆盖「最新一帧」槽位，消费者（主线程 tick）取最新——pendingFrame/pendingYoloFrame/pendingNativeFrame 三处（AuroraDriveApp.swift 写 / 6942-6960、6974-6978、7087-7091 消费）。
- **@Observable 先比后写纪律**：值不变不赋值，省观察者通知（questName AuroraDriveApp.swift、mode AuroraDriveApp.swift、confidence AuroraDriveApp.swift、locatorFound AuroraDriveApp.swift 等）。

## 十二、引擎现场判定链：日志「有帧=false 帧数=0 降级=true」怎么读（2026-10-06 核实）

引擎进程 1Hz 统计日志（EngineMain.swift:823-833）：

```
[ENGINE] 统计: seq=N 有帧=X det=N driving=X yolopx:加载=X 帧数=N da=N格 ll=N格 降级=X maskSeq=N 耗时=Nms
```

各字段的**代码判定链**：

| 字段 | 判定 | 出处 |
|---|---|---|
| `有帧=false` | `EngineGlobals.state?.currentFrameCG != nil` 为假——引擎的 DriveState 还没有消费到任何一帧画面（抓屏未启动 / SCStream 无输出 / tick 未消费） | EngineMain.swift:810 |
| `帧数=0` | `yolopxEngine.inferenceCount == 0`——YOLOPX 一次推理都没跑过 | EngineMain.swift:824、YolopxEngine.swift:406 |
| `降级=true` | `yolopxEngine.isDegraded == true`——**初值就是 true**（YolopxEngine.swift:382「模型没跑起来之前一律视为不可信」），只有推理出过有效掩码才会翻 false | EngineMain.swift:826、YolopxEngine.swift:382 |
| `det=0` / `driving=false` | YOLO 检测框数 / `state.isDriving` | EngineMain.swift:823 |
| `maskSeq` | 掩码世代号（YOLOPX 每次产出新掩码 +1） | EngineMain.swift:599 |

**「有帧=false 帧数=0 降级=true」组合的解释链**（与状态机的关系）：

1. **引擎模式下 YOLOPX 根本不跑**（EngineMain.swift:22-36 头注释明确：tick 在 `EngineClient.shared.isActive` 时 `tickEngineMode(); return` 提前返回，本地推理分支走不到）→ `帧数=0` 与 `降级=true` 是**引擎模式的既定常态**，不是故障（副作用：引擎侧 `isDegraded` 恒 true → LaneFallback 不介入；掩码只能由引擎把 YOLOPX 结果写进共享内存掩码区后 UI 才有）。
2. 该日志的 `降级=` 反映的是**引擎进程内 yolopxEngine 的掩码可信度**，与 UI 侧降级状态机（DegradeStateMachine 的 e2e/yolo/rule 三档）**不是一回事**：驾驶档位降级由引擎进程自己的 `DriveState.tick → degradeStm.update` 决定（AuroraDriveApp.swift），经心跳 `engineMode` 回传 UI（EngineClient.swift:116-118「降级档位（引擎是权威源）」）。日志里看不到档位，要看心跳/面板。
3. 若 `有帧=false` 持续出现（非刚启动）：先查抓屏权限 / `AURORA_ENGINE_DIAG_CAPTURE_ONLY` 诊断 / `frameHost` 是否从未 push——即**帧管道问题**，与降级状态机无关；降级状态机此时也不会动（tick 在引擎模式提前 return 前就跑了完整本地管线？——不是：引擎进程 isActive 恒 true，走 tickEngineMode 的是 **UI 进程**；引擎进程自己的 tick 跑完整决策管线，其降级档位经心跳回传）。
4. UI 侧看到的 `engineMode/engineSpeed/engineConfidence` 等驾驶状态全部来自引擎心跳字段（EngineClient.swift:116-126），`speedValid = client.engineSpeedKmh >= 0 && client.engineSpeed > 0.5`（AuroraDriveApp.swift，先比后写）。引擎失联（`engineConnected=false`）时 UI 状态面板显示「未连接」（MissionConsole.swift:3312-3313），档位显示沿用引擎最后回传值，UI 不自行接管档位。


## 附：Core/ 其余文件一句话职责（2026-10-06 核实，详见各专篇文档）

- **AuroraCache.swift**（726 行）：全 App 统一缓存层（A16），明确弃用 NSCache 的四条理由（:12-20 起：单条目覆盖式/TTL 不一/零指标/零统一开关）；`AURORA_CACHE=0` 全直通（AF:416-418）。详见 代码-18 与 代码-30。
- **AuroraPaths.swift**（118 行）：项目根多候选解析；`cachedRoot` 曾有数据竞争，改为 static let（:16-30 注释）。详见 代码-02。
- **BPFSetup.swift**（134 行）：BPF 权限自检——**逐个探测 /dev/bpfN（0..<64，多扫几个防空洞）**，旧版只看 bpf0 的 bug 记录（:19 注释、:30-33）。详见 bpf-daemon.md。
- **DaemonSetup.swift**（108 行）：引擎拆分后的简化编排器——launchd 拉后台进程拿不到 TCC 权限（ax=false、screen=false），方案已废弃（:11-15 注释），仅保留 BPF LaunchDaemon。详见 bpf-daemon.md 与 代码-01。
- **EngineClient.swift / EngineMain.swift**：见 代码-07 / 代码-06。
- **GameModeDefender.swift**（217 行）：对抗 Game Mode 压制——静音音频豁免 App Nap + 每 3s 重主张 nice/-activity（:19、:94），日志 /tmp/aurora_defender.log（:23、:37），队列 `aurora.defender`（:153）。详见 代码-30。
- **PrioritySetup.swift**（74 行）：root renice 守护，每 5s 把本进程（含 --engine 引擎子进程）renice -20（:12-14）。详见 代码-30。
- **PrivilegePill.swift**（472 行）：应用内密码提权（`sudo -S` 走 stdin，不进 argv；绝不用系统授权弹窗，:8-25 设计约束）；`aurora.privilege.process` 队列 qos .utility（:251-252）。详见 代码-30。
- **WireSelfTest.swift**（222 行）：引擎配置通道自检（`--wire-selftest`），起因「手切档位静默失效」四处缺陷叠加（:12-28：①sendCommand 静默失败 ②pushConfig 日志说谎 ③先记账后发送 ④心跳超时只置 isConnected 不动 isActive，:28）。详见 代码-33。

## §附、当前实测锚点表（2026-10-18 逐条 `grep -n` 实测，**9096 行版**，可直接引用）

> 正文已改为文件级引用（`AuroraDriveApp.swift`）+ 符号名定位；下表提供精确行号。
> 覆盖文件当前 **9096 行**（`wc -l` 实测）。

### 类型与状态字段

| 单元 | 行号 |
|---|---|
| `enum DriveMode` | **:4047** |
| `enum DriveModeGroup` | **:4082** |
| `enum RecordLabelMapper` | **:4121** |
| `final class DriveState` | **:4150** |
| `isDriving` / `expertMode` / `glyphMode` / `forceRuleMode` / `agentMode` | **:4182 / :4241 / :4245 / :4307 / :4335** |
| `locatorFound` / `locatorX` / `locatorY` / `locatorScore` / `locatorHeading` | **:4367 / :4368 / :4369 / :4370 / :4371** |
| `locatorAccelX` / `locatorTarget` / `questName` | **:4375 / :4378 / :4384** |
| `isRecording`（didSet） | **:4988** |

### 方法与函数

| 方法 | 行号 |
|---|---|
| `clearRoute()` | **:4416** |
| `planRouteToMapPixel(x:y:)` | **:4431** |
| `setLocatorTarget(x:y:)` | **:4515** |
| `runNetworkLocateStep()` | **:4546** |
| `startDriving()` / `stopDriving()` | **:6190 / :6300** |
| `tickEngineMode()` | **:6522** |
| `pushEngineConfigIfChanged()` | **:6745** |
| `tick()` | **:6865** |
| `recordFrameIfNeeded()` | **:7899** |
| `readPose()` | **:8032** |
| `applyCommand(_:)` | **:8082** |
| `applyLaneAdvice`（自由函数） | **:8379** |

### 引擎与决策组件持有

| 组件 | 行号 |
|---|---|
| `captureEngine` | **:5529** |
| `degradeStm` / `ruleController` / `confidenceEst` | **:5653 / :5671 / :5672** |
| `inferenceEngine` / `inferenceEngineV2` / `assistEngine` | **:5677 / :5692 / :5697** |
| `yoloEngine` / `yolopxEngine` | **:5702 / :5716** |
| `egoBoxFilter` / `laneFallback` / `driveSegment` / `fallbackGuard` | **:5723 / :5727 / :5733 / :5754** |
| `speedOCR` / `questPanel` | **:5898 / :5908** |

> ⚠️ 本表为 2026-10-18 `grep -n` 逐条实测；源码改动后需重跑 `grep -n` 更新。
