# 代码-25 AuroraDriveApp 之 DriveState 状态主体

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（**8456 行**，2026-10-07 `wc -l` 实测；10-06 版为 8335 行）之中部：DriveMode/DriveModeGroup/RecordLabelMapper + DriveState。
> 本文 2026-10-06 由文档更新代理 A5 复核：旧正文行号基准（5175 行版）已整体过期，**本文内所有 文件:行号 均按 8335 行版本重新核实**；无法核实的论断一律标「未验证」。

> **🔄 2026-10-07 增量复核（D7）——本文覆盖内容本次未改动，但行号整体 +121：**
>
> ① **行号 +121 的成因**：10-06 深夜 AI 助手施工（提交 `2c0459a`）与滑动窗口修复（`22a6604`）使文件由 8335 → **8456 行**。新增内容全在文件前部（`SelfTestResultBox` :704-716、自检 flag 登记 :935-948、自检分发块 :1001-1094），**位于 `DriveState` 之前**，故 `DriveState` 及其后所有行号统一 **+121**。抽查验证（2026-10-07 逐条 `sed` 实测旧锚点 +121 后命中）：`final class DriveState` 3981→**4102** ✓、`locatorFound` 4145→4266 ✓、`setLocatorTarget` 4293→4414 ✓、`clearRoute` 4194→4315 ✓、`degradeStm` 5276→5397 ✓、`inferenceEngine` 5300→5421 ✓、`egoBoxFilter` 5331→5452 ✓、`fallbackGuard` 5362→5483 ✓、`questPanel` 5502→5623 ✓、`tick()` 6383→**6505**（起）✓、`degradeStm.update` 6686→6807 ✓、`ruleController.decide` 6879→7000 ✓、`readPose()` 7271→**7392** ✓、`applyLaneAdvice` 7618→7739 ✓。
> **阅读换算规则：本文正文里的 `App:NNNN` + 121 = 当前真实行号**（内容语义未变，仅偏移）。
>
> ⚠️ **2026-10-07 D7b 补记（重要，先读再读正文）**：**文首这条 `+121` 规则本身在 §六、§七、§九 被违反了**——那三节的「新锚点」写的是**未加 121 的旧值**（且 §九 还混用了新值 `applyCommand` App:7321）。D7b 已逐条实测，**统一汇总为下方「§附·换算总表」**，请一律以该表为准；§六/§七/§九 的内联锚点按表理解即 `+121`（已就地标注 3 处明显矛盾的锚点）。§八、§十、§十一、§十二 的锚点经抽检**基本正确**（§十一 队列表 1 处、§十二 若干处偏差见总表末段）。
>
> ② **AI 面板改动不在本文覆盖范围**（用户明确要求核实项）：`sendChatMessage` / 滑动窗口 `appendMessage`+`maxMessages=200` / 后端选择器 / 视觉开关 / 配置向导 / 底部小字 / 诊断面板 **全部落在 `Agent/AIAgentPanel.swift`**，与本文覆盖的 `AuroraDriveApp.swift` 中段（DriveMode + DriveState）**无重叠**。`AuroraDriveApp.swift` 本次仅两处变动，均在本文范围外：自检 flag 登记与分发（:935-1094），以及 `ControlEngine`（另一文件）。→ **本文本次未改动任何 DriveState 逻辑**，10-06 复核结论全部继续有效。
>
> ③ 与 AI 面板的**唯一接口点**是 `AgentSkillCenter.configure(control:capture:)`（`AuroraDriveApp.swift:533`，`AppDelegate` 侧；DriveState 侧另见 `MissionConsole.swift:5635/5641/5657`），**本次未改动**（`git diff HEAD~5..HEAD -- Sources/AuroraDrive/App/AuroraDriveApp.swift` 仅 3 个 hunk，均在 :701/:935/:1001 附近，未触及 `configure` 调用点）。

## 〇·五、AI 面板改动落点（2026-10-07，**代码不在本文覆盖文件内**）

> 用户要求核实"代码-25 的 AI 面板相关改动"。**实测结论：这些改动在 `AuroraDriveApp.swift` 里一条都没有**——它们全在 `Sources/AuroraDrive/Agent/AIAgentPanel.swift`（3253 行）+ `AgentChatService.swift`。本节只做**落点索引**，避免后续读者到 `DriveState` 里翻找。

| 改动 | 实现位置（2026-10-07 实测） | 一句话说明 |
|---|---|---|
| **真实对话接线** `sendChatMessage` | `AIAgentPanel.swift:1557-1620`（`private func`） | 自由聊天从"硬编码套话"改为真实 LLM：`sendUserMessage` :1487 → 无技能命中时 :1541 `sendChatMessage(trimmed, source:)`。带最近 40 条历史（:1559 `messages.suffix(40)`）转 `ChatTurn`，服务端再裁到 12 轮。占位消息 + 流式增量 `replaceMessage`（:1592-1598），失败走 `localReply` 并标注"（离线回复：无可用模型）"（:1610-1613） |
| **滑动窗口** `appendMessage` / `maxMessages=200` | `AIAgentPanel.swift:201`（`messages`）、**:203**（`static let maxMessages = 200`）、:205（`droppedMessageCount`）、**`appendMessage` :208-215**、`resetDroppedMessageCount` :218-220、**`replaceMessage` :223-226** | 修「AI 那个窗口会无限变大」：超 200 条丢最旧的并累计 `droppedMessageCount`。**所有写入路径统一走 `appendMessage`**（原 6 处直接 `append` 已改造：`init` :484-486、`sendUserMessage` :1490、`sendChatMessage` 占位 :1575、`replyAssistant` :1694、`appendSystem` :1698、:1752）。UI 提示"更早的 N 条消息已折叠"（:2955-2962，`AgentConversationView` :2947）；"新建对话"重置计数（`newConversation` :1749-1753，`droppedMessageCount = 0` :1751） |
| **后端选择器** | `AIAgentPanel.swift:2296-2340` | 免 key 渠道开箱即用、需 key 渠道在 `apiKey` 为空时置灰；`backendKind` 定义 `AgentSettings.swift:149`（`LLMBackendKind`，默认 `.ovhAnonymous` 免 key），切换落盘 `AgentSettings.keyBackend`（:167） |
| **📷 视觉开关** | `AIAgentPanel.swift:2342-2360`（`Toggle`）；消费点 `sendChatMessage` :1571 `let wantVision = aiSettings.visionEnabled` + 取帧 :1583-1586 | 默认**关**（隐私优先，`AgentSettings.swift:153` 默认 `false`、:233 注释"缺省 false"）。开启后随请求带当前帧；**拿不到帧不静默降级**——如实告知"本次按纯文本发送"（:1587-1591）。取帧 `encodeCurrentFrameForVision()` :1636-1641（`@MainActor`，长边 1568px + JPEG 0.8，:1631-1635 实测理由） |
| **配置向导** | `AIAgentPanel.swift:2547`（`struct AgentSettingsSheet`）、`navigationTitle("AI 助手配置向导")` :2611、底部导航 :2586-2608 | 三步向导：免 key 路线 `applyKeyless()` :2699-2702 把后端设为免 key 渠道；渠道连通性测试结果回写 :2820-2830 |
| **底部小字 + 诊断面板** | 小字 :2245-2292（`healthSnapshot.displayLine`，hover tooltip 展示候选链）；"诊断"按钮 :2266-2274；`struct LLMDiagnosticsSheet` **:2453**（`navigationTitle("模型渠道诊断")` :2523） | 数据源 `LLMHealthMonitor.snapshot()`（actor，进面板即刷 + 30s 轮询 :2276-2285）。全挂时显示"⚠️ 无可用模型（点此诊断）"；正常形如 `免费档 · ovh · Qwen2.5-VL-72B · 健康 4/7 · 0.9s` |

**语义边界提示**：本表信息来自当前源码行号实测，**未逐条通读 `AgentChatService` / `LLMHealthMonitor` 内部实现**——涉及"7 渠道聚合 / 降级链 / 探活策略"等细节请以 [代码-23-AIAgentPanel与17技能](代码-23-AIAgentPanel与17技能.md) 为准（**未验证**：本文未核对该文档是否已覆盖 10-07 增量）。

> 常用锚点（2026-10-06 实测）：`final class DriveState` 在 **AuroraDriveApp.swift:3981**；定位器/任务字段在 **4144–4162**；`setLocatorTarget` **4293**；`clearRoute` **4194**；决策组件持有 **5276–5362**；`questPanel` **5502** + `onConfirmed` 接线 **5575–5579**；onFrame 接线 **5583–5596**；`tick()` **6383 起**（引擎分流 6400–6403、quest OCR 门 6435–6436、卡死检测 6653–6680、降级决策 6686–6697、置信度 6699–6717、按档输出 6872–6886、`ruleController.decide` 6879、分段决策 7252–7295）；`readPose()` **7271–7282**。
>
> ⚠️ **历史行号基准存档**（下列旧正文小节标题里的行号来自更早版本，与当前 **8456 行**版已不对应——各节内容经 2026-10-06 复核后仅行号偏移、语义以本节内带新行号的表述为准；**2026-10-07 起再统一 +121**）：
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

`final class DriveState`（AuroraDriveApp.swift:3981）中的定位器/任务字段，全部主线程读写：

| 字段 | 定义处 | 写入者 | 读取者 |
|---|---|---|---|
| `locatorFound` | AuroraDriveApp.swift:4145 | 网络定位回调 App:4548（**先比后写**：`if self?.locatorFound == false`）；游戏未运行时清除 App:4371 | `planRouteToMapPixel` 起点判断 App:4215；`readPose()` 门槛 App:7272；决策门槛与 UI（注释称 24 处 UI 读取，App:4547） |
| `locatorX` / `locatorY` | App:4146-4147 | 网络定位回调 App:4544-4545（**写世界坐标 UE5 厘米**——坐标系统一修复取证见 App:4445-4468） | `DriveState.worldToMapPixelX/Y` 各调用点（MapWiring.swift:29 定义；App:4216-4217、MissionConsole.swift:2589-2590、:3969-3970、:4045-4046）；`readPose()` App:7273-7274；NavGuidance 距离 `(t.x - locatorX)/100`（MissionConsole.swift:847 注释） |
| `locatorScore` | App:4148 | App:4553（按新鲜度 tier 分级 `locatorScoreForTier`，App:7252-7268：live=1.0 / recent=0.3 / stale=0.1 / lost=0） | 决策门槛 0.4（`readPose()` App:7275）；诊断打印 MissionConsole.swift:2886 |
| `locatorHeading` | App:4149 | App:4554 | `readPose()` App:7275（供 DriveSegmentController，App:6928 调用） |
| `locatorAccelX/Y/Z` | App:4153-4155 | App:4555-4557 | 仅如实展示（App:4150-4152 注释：坐标系未实测确认，**不参与控制**） |
| `locatorTarget` | App:4156 | ① `setLocatorTarget(x:y:)` App:4293（QuestPanelReader 确认回调 App:5578 调用，来自 quest_index 世界坐标）② `clearRoute()` App:4199（置 nil）③ 演示/自检夹具 MissionConsole.swift:5687、:5838、:6124、:6285 | MissionConsole.swift:634、:1457、:2540-2547、:3968（距离计算与路线规划） |
| `questName` | App:4162 | QuestPanelReader 确认回调 App:5577（**先比后写**，注释 App:5570-5571） | 任务卡片渲染 MissionConsole.swift:632、:861、:904、:927 |

**quest 数据流闭环**：`tick()` 主线程调 `questPanel.ingest(cgImage:)`（App:6435-6436，门 `AuroraFlags.questOCR`）→ ROI 裁剪在主线程、Vision OCR 丢到 `aurora.quest.ocr` 后台串行队列（QuestPanelReader.swift:483，`qos: .utility`）→ OCR 完成回主线程（QuestPanelReader.swift:557 `DispatchQueue.main.async`）→ `onConfirmed` 回调（App:5575，主线程执行）→ 写 `questName`（App:5577）+ `setLocatorTarget`（App:5578）。QuestPanelReader.swift 文件头明确 `locatorTarget` 与 quest_index 同为世界坐标（UE5 厘米）。

### 决策组件的持有与所有权（全部为 DriveState 成员，主线程访问）

| 组件 | 持有处 | 说明 |
|---|---|---|
| degradeStm | App:5276 | tick 每帧 update（App:6686）；阈值同步 App:6558 |
| ruleController | App:5294 | App:6879 调 decide |
| egoBoxFilter | App:5331（= EgoBoxFilter.configured，EgoBoxFilter.swift:77） | 决策层过滤 `effectiveDetections` App:4067 |
| laneFallback | App:5334 | 车道线兜底决策器（fail-open） |
| driveSegment | App:5341 | App:7295 调 update（segmentDecisionForRule 内） |
| fallbackGuard | App:5362 | **主链路已停用**（App:6250：不再调用 evaluate；实例保留仅供自检 App:3212 起 `guardA` 等） |
| inferenceEngine / assistEngine / yoloEngine / yolopxEngine | App:5300 / 5305 / 5310 / 5324 | 三套推理引擎 + YOLOPX |
| questPanel | App:5502（@ObservationIgnored let） | 任务面板 OCR，见上表 |

## 一、RecordLabelMapper 与 DriveState 开关字段

> 新锚点：`RecordLabelMapper` App:3952、`fullScaleDuration=0.6` App:3956；开关字段 App:4015-4113（isTraining 4015 / expertMode 4072 / glyphMode 4076 / forceRuleMode 4085 / agentMode 4113）；`isRecording didSet` App:4766。下表语义逐项复核仍准确。

**`RecordLabelMapper`（enum，第 855–880 行）**——专家模式录制标签换算器（**纯函数，便于单测**）。语义（851–854 行注释）：把物理按键的"按住时长"换算成连续控制标签——**与推理端闭环一致：ControlEngine 按 \|steer\|>阈值 决定是否按住键，游戏自身再把按住时长平滑成转角——录制端用按住时长作为监督信号，让模型学到"打得越满 → 按住越久"的连续映射，替代二值标签带来的顿挫**。

| 方法/常量 | 签名 | 说明 |
|---|---|---|
| `fullScaleDuration` | `static let = 0.6` 秒 | **满刻度时长：按住满该时长 → 标签饱和 ±1**；默认 0.6s：30Hz 下约 18 帧，覆盖"轻点 → 满打"的常见手感区间 |
| `holdRatio(_:)` | `TimeInterval -> Double` | 按住时长 → [0,1] 比例（钳制）：`min(1, max(0, duration / 0.6))` |
| `steer(leftHeld:rightHeld:)` | 双时长 → Double | **D 按住比例 − A 按住比例，净差钳制到 [-1,1]（左负右正）** |
| `throttle(wHeld:)` | 时长 → Double | W 按住比例 [0,1] |
| `brake(sHeld:spaceHeld:)` | 双时长 → Double | **S 或 空格(手刹) 任一按住即刹车，取两者按住比例较大者 [0,1]** |

**`DriveState`（@Observable @MainActor final class，现 App:3981 起）**——全局状态 + 驾驶闭环。**开关字段（现 App:4013-4093）：**

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

**引擎模式字段（现 App:4019-4042）：**

| 成员 | 说明 |
|---|---|
| `remoteDetections: [Detection]` | **引擎回传的检测结果（引擎模式下每 tick 刷新）** |
| `engineModeActive` | 引擎模式是否激活（镜像自 EngineClient，供 UI 观察刷新） |
| `engineConnected` | 引擎心跳是否正常（false = 失联，UI 显示告警） |
| `remoteSpeedKmh: Double`（默认 -1） | **引擎回传的车速表读数——引擎模式下本地 speedOCR 不跑，用它顶上** |
| `lastDriveCommandTime`（@ObservationIgnored） | **最后一次「开始/停止」命令时间：引擎状态回同步的 1 秒宽限期，防切换瞬间 UI 闪烁** |
| `effectiveDetections`（计算属性） | **UI 统一检测结果读取点：`EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`**——引擎模式用引擎回传，本地模式用本地 YoloEngine |

**BPF/Daemon 字段**：`bpfAuthorized`（启动时检测 BPF 权限）/ `showBPFPasswordSheet` / `bpfInstallMessage` / `bpfInstalling`；`daemonInstalled` / `showDaemonInstallSheet` / `daemonInstallMessage` / `daemonInstalling` / `isDaemonMode`——**Daemon 系统服务相关字段（安装引导弹窗/结果消息）**。

**网络定位字段**：`networkLocateX/Y/Score/Mode/Pitch/Heading`（六件套，UI 小地图显示用；`locateGameOffline` 计算属性 App:4140）。

> ⚠️ 修正一处旧文错误：`enableNetworkLocate` **默认 true 且「网络定位常开、不提供关闭入口」，保留字段仅为兼容**（App:4090-4093 注释），不是旧表写的 false。

## 二、定位器字段与 runNetworkLocateStep / dlog 10MB 封顶

> ⚠️ 本节及以下至第九节的行号为 **6698 行版（2026-10-02）** 历史基准，语义经复核仍准确；新锚点见文首「常用锚点」与第〇节。

**定位器字段（现 App:4144-4162，`lastNetworkLocPos` App:4269 / `healerInitLock` App:4273 / `locateCtx` App:4275；从外置盘移植，MinimapLocatorView 需要）**：`locatorFound/X/Y/Score/Heading`（五件套）+ `locatorTarget: (x: Double, y: Double)?`（传送目标）+ `lastNetworkLocPos`（@ObservationIgnored，上次定位位置——朝向反推基线）+ `healerInitLock`（os_unfair_lock，懒初始化锁）+ `coordinateCapture: CoordinateCapture?`（@ObservationIgnored，网络坐标抓取器）+ `locateCtx/locateGate`（LocateContext/LocateGate）。

**`mapPath`（lazy 闭包）**——底图路径解析（**用可执行文件所在目录找地图，不用 currentDirectoryPath（那是 Home 目录）**）：

- 四候选：`execDir/models/bigworldmap-13056.jpg`（首选）/ `execDir/models/bigworldmapSecond.png` / 硬编码 `/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg` / 旧图 png
- 全败返回**最后一个候选**（"返回最后一个作为默认，让错误信息有意义"——错误信息里能看到路径）

**`setLocatorTarget(x:y:)`（现 App:4293）**：设置传送目标（locatorTarget）。

**`heading(from:to:)`（static，现 App:4295-4300）**：两点间朝向——`atan2(dy, dx) × 180/π`，负值 +360 归一到 [0, 360)。

**`runNetworkLocateStep()`（现 App:4324 起）**——网络定位步（**懒初始化 CoordinateCapture（纯网络定位，无自愈引擎）**）：

1. **懒初始化（987–1002 行）**：`coordinateCapture == nil` 时——`os_unfair_lock_lock(&healerInitLock)` + `defer` 解锁 + **双检**（锁内再判 nil，防并发重复初始化）→ `cc.start()`（libpcap 起抓包，见 代码-04）→ `pcapLog("[NETWORK-LOCATE] cc.start()返回=…")` 记录成败 → `locateCtx.networkReady = true`
2. `guard let cc, locateCtx.networkReady`——未就绪 → 主线程 `networkLocateScore = 0` + `mode = "not_ready"` → return
3. **★ G 第 4 批（2026-10-04）：三级新鲜度取代旧 `cc.read(maxAge:)`**——`let tierRead = cc.readWithTier()`（App:4412），分 live（≤18s）/ recent（≤40s）/ stale（≤90s）/ lost 四档（App:4394-4410 注释：UI 显示/决策层/控制层三列态度）；`locatorScoreForTier` 映射分数（live=1.0，其余低于 0.4 决策门槛），**只有 live 档允许驱动驾驶**（App:4436-4439）。有数据时 `worldToMapPixel(pose)` 换算 + 主线程异步更新 networkLocate 六件套 + locator 五件套（**双份字段同步**——MinimapLocatorView 读 locator、大地图读 networkLocate）。
4. **游戏未运行**（App:4360-4377）：`!cc.hasRecentTraffic(window: trafficFreshWindow=12s)`（突发式包流，旧 3s 窗口会在静默间隙误报，App:4355-4357 注释）→ `networkLocateMode = "game_not_running"` + **清 locatorFound/locatorScore**（不保留旧坐标，防界面显示"假跳"定位，App:4370-4373）；未就绪 → `"not_ready"`（App:4344-4351）。

**`networkLocateLastUpdate`（第 1041 行）**：上次定位更新时间（默认 .distantPast）。

**三个时间戳（第 1043–1054 行）**：`drivingStartTime`（**本次开车会话开始时间——暖机期判定：启动后头几秒还没出推理结果时保持高置信度，避免启动瞬间误降级**）、`lastTickLog`（tick 摘要 1Hz 节流）、`lastUpscaleLiveLog`（插帧状态更新节流 1Hz）。

**`dlog(_ msg: String)`（private，现 App:4657 起；10MB 封顶语义见 App:4726、:8299——已迁入 LogSink 但格式/封顶/回退链不变）**——调试日志：**stdout + `/tmp/aurora_debug.log`（App 启动时清空）**；"用户从终端启动可实时看到；事后我读文件定位运行时问题"。

- **P1 修复（1063–1070 行）**：**dlog 每秒追加，7×24 运行日志无限增长。写前检查大小，超 10MB 直接覆盖重写（truncate，atomic 写），只保留最近日志，封顶磁盘占用**
- 追加写：FileHandle seekToEndOfFile + write；文件不存在 createFile 等价路径（data.write）

## 三、isRecording didSet 与引擎模式回声防环

> 新锚点：`var isRecording didSet` App:4766-4768 起；`guard isRecording != oldValue` App:4768、`guard !applyingRemoteRecord` App:4769、`lastRecordCommandTime` 记点 App:4771（声明 App:4805）。

**`var isRecording = false { didSet ... }`（第 1091–1121 行）**——行驶录制开关（didSet 触发 RecordEngine 启停 + 画面流/键盘监听接管）：

- true → 开始录制会话；**未在驾驶时由录制器负责拉起截屏画面流与键盘监听（否则不开车就开录制器会录出空目录）**
- false → 写 meta.json 并关闭；**驾驶仍开着时不关画面流/键盘监听（驾驶还在用）**

**⚠️ 引擎模式回声防环（1087–1103 行注释与实现）**：

- **"帧只存在于引擎进程（UI 没有画面流），录制必须由引擎执行，这里只把开关转发过去。早先在引擎模式下仍然本地 recordEngine.start()，结果是「目录建了、文件建了，但录不进任何东西」——因为 UI 的 tick 在引擎模式下提前 return，recordFrameIfNeeded() 永远不执行"**
- `guard isRecording != oldValue`（值未变不动）+ **`guard !applyingRemoteRecord else { return }`——来自引擎回同步，别回声**
- **引擎模式分支（1095–1103 行）**：`EngineClient.shared.isActive` 时——`lastRecordCommandTime = Date()`（**宽限期起点：别让未更新的心跳把开关弹回去**）+ `sendCommand("record", extra: ["on": isRecording, "glyph": glyphMode, "expert": expertMode])` → return——**只转发，不本地执行**

**本地模式分支（1104–1119 行）**：

- 开始：**每次开始录制前同步字模模式开关（1107 行）**——"注意：录制中途切换 glyphMode 不影响本次会话（语义为「录制中切换不生效，需重启录制」），故不做实时热切换"：`recordEngine.glyphMode = glyphMode` + `recordEngine.start(perspective: "first")` + **`if !captureEngine.isCapturing { captureEngine.start() }`**（画面流没跑才拉起）+ `keyboardMonitor.start()`
- 停止：`recordEngine.stop()` + **`if !isDriving { captureEngine.stop(); keyboardMonitor.stop() }`**（驾驶还开着不关画面流/键盘——驾驶还在用）

**配套状态（第 1123–1133 行）：**

| 成员 | 说明 |
|---|---|
| `applyingRemoteRecord`（@ObservationIgnored） | **防回环标记：tickEngineMode 把引擎录制状态镜像到 isRecording 时置位，避免 didSet 又把「record」命令回声给引擎** |
| `lastRecordCommandTime`（@ObservationIgnored） | **最后一次向引擎发送「record」命令的时间。心跳周期 1s，命令刚发出时引擎还没来得及上报，若不设宽限期，UI 会在下一次 tick（30Hz）立刻把 isRecording 弹回旧值 → 开关按下即回弹** |
| `engineVersionWarning` | **引擎协议版本不匹配时的用户可见告警（空 = 无告警）** |

**驾驶核心字段（第 1135–1155 行）：**

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（默认 .e2e） | **当前驾驶模式（由降级状态机计算，每帧 tick 同步）——UI 观察此属性刷新模式芯片高亮** |
| `confidence`（默认 0.92） | 置信度 0~1 |
| `lastDecided`（private，默认 .e2e） | **上一帧状态机决策档位。⚠️ 2026-09-30 起 `.recover` 已删——现在仅作诊断留档，先比后写（不再做边沿检测）** |
| `effectiveSpeed`（默认 0） | **有效车速（km/h）：每帧由 OCR 新鲜读数（EMA 平滑）或一阶滤波回退计算——供 M9 vehicle_state、卡死判据、脱困退出使用（替代原模拟速度）** |
| `speedValid` | **有效车速是否新鲜（OCR 读数新鲜：lastResultTime < 0.5s 且 confidence > 0.3）——不新鲜时卡死判据不计入 stuckSeconds；感知融合层可直接消费此健康标志** |
| `speed`（计算属性） | **兼容属性：旧代码读 speed 的地方统一读到 effectiveSpeed（不再有模拟值/随机抖动）** |

**显示与 OCR 字段（第 1155–1180 行）：**

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

> 新锚点：跳帧缓冲 pendingFrame/pendingYolo/pendingNative App:5207-5229（写侧 5583-5596 / 5601 附近 / 5630-5632）；引擎实例 App:5246 起（captureEngine/controlEngine 等）；`mode` App:4812、`confidence` App:4815、`effectiveSpeed` App:4889、`speedValid` App:4893、`speedLimit` App:4920、`degradeThreshold` App:4921、`currentCommand` App:5506、`upscaleEnabled` App:5048、`gameModeBoost` App:5080。

**画面流与显示字段（第 1182–1195 行）：**

| 成员 | 说明 |
|---|---|
| `currentScreenImage: NSImage?`（**@ObservationIgnored**） | 由 CaptureEngine 的 onFrame 闭包更新，仍是录制/现有引用的数据源 |
| `currentFrameCG: CGImage?`（@ObservationIgnored） | **同源（同一回调直传的 CGImage），供推屏/推理/置信度使用，省 NSImage→CGImage 重复转换** |
| `frameHost = FrameHost()` | **UI 显示已改走 frameHost 直绘（绕开 SwiftUI diff）**，故两者均标 @ObservationIgnored |
| `screenSize: CGSize?`（普通 @Observable） | **源画面尺寸——驱动 ObstacleOverlay 的 aspect-fill 对齐**。注释（1189–1191 行）："**不能从 @ObservationIgnored 的 frameHost.latestSize 读，否则尺寸变化不触发观察导致检测框错位；仅在尺寸变化时写，避免每帧失效**" |
| `isStreaming`（普通 @Observable） | **控制 GameViewportView 显示"实时画面 vs 黑底提示"分支，启/停各翻转一次——必须保持 @Observable（观察成本可忽略），否则停止后分支不触发重绘导致画面冻结** |

**插帧/超分字段（第 1197–1217 行）**：

- `upscaleHost = UpscaleFrameHost()`（@ObservationIgnored）——插帧帧宿主
- `upscaleEnabled: Bool = false` / `upscaleSupported` / `upscaleLive: String?` / `upscaleEngineError: String?`——插帧状态四件套
- **仅显示路径，绝不进入决策链路**（1197 行注释）——插帧是给"人眼看得更顺"的，YOLO/OCR/E2E 走各自直通路径
- **`gameModeBoost: Bool = true { didSet ... }`（1204–1217 行）**——游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权）：值变化时 `applyMainThreadBoost(gameModeBoost)`（见 代码-24 单元三）+ **启用时 `startAntiFreeze()` 加强心跳防冻结 / 关闭时 `stopAntiFreeze()`**

**跳帧防堆积（第 1228–1251 行，用户拍板方案）：**

- **设计（1228–1231 行注释）**："onFrame 在 captureQueue 线程只「**覆盖**」最新一帧（**不 main.async 排队**）；tick 主线程每帧取最新一帧给 UI——主线程处理不过来时**旧帧被覆盖丢弃，永不堆积（= 强制同步跳帧）**。捕获/推理频率不变（30fps 红线）"
- **`pendingFrame / pendingFrameCG / pendingFrameTime`（nonisolated(unsafe) private）** + `pendingFrameLock = NSLock()`——覆盖式最新帧三件套 + 锁
- **`pendingYoloFrame: CVPixelBuffer?` + `pendingYoloLock`（1241–1245 行）**——**YOLO 直通帧跳帧（同 pendingFrame 模式）：captureQueue 覆盖最新帧，tick 消费**
- **`pendingNativeFrame: CVPixelBuffer?` + `pendingNativeLock`（1247–1251 行）**——**原生 ROI 帧跳帧（同模式）：OCR/字模录制消费**
- 三组跳帧缓冲全部 `nonisolated(unsafe)` + NSLock——**跨线程覆盖写/读的统一模式**

**诊断字段（第 1223–1270 行）：**

| 成员 | 说明 |
|---|---|
| `frameDeliveryLagMs`（nonisolated(unsafe)） | **onFrame 帧从入队到主线程执行的延迟(ms)——验证"越到后面越卡=积压"：若该值随时间持续增长 → main 队列积压确认（每帧 main.async + 22MB 大图堆积）**（旧架构的诊断尺子，跳帧方案后应恒定） |
| `lastTickTime` / `tickGapMs` | **主线程 tick 实际间隔(ms)（>33ms = 主线程掉拍/被卡）——tick 由 30Hz Timer 驱动，间隔应稳定 ~33ms；出现 66/99ms 或更大 = 主线程被阻塞** |
| `antiFreezeTimer`（private @ObservationIgnored） | **防冻结心跳定时器（游戏模式下强制唤醒主线程）** |
| `processMemoryMB() -> Double`（第 1261–1270 行） | **进程物理内存占用（MB）——诊断用：积压 → 内存随时间线性上涨的验证指标**：`task_info(MACH_TASK_BASIC_INFO)` → `resident_size / 1024 / 1024`；KERN_SUCCESS 才返回，否则 0 |

**引擎实例字段（第 1272–1298 行）：**

| 成员 | 说明 |
|---|---|
| `captureEngine = CaptureEngine()`（let） | **截屏引擎实例（启动时创建，全屏画面流 30fps）——isDriving 启动时 start()，停止时 stop()** |
| `gameHUD = GameHUDWindow()`（let） | **游戏画面左上角帧率 HUD（绿色两行：辅助帧率/游戏帧率）——兼作对抗 Game Mode 的"可见窗口"（见 GameHUDWindow.swift 头注释）** |
| `capturePermissionDenied` | 截屏权限状态（首次启动若未授权，引导用户到系统设置） |
| `controlEngine = ControlEngine()`（let） | **按键注入引擎（CGEvent 控制 WASD/空格/Shift）——启动时检查辅助功能权限，停止时释放所有按住的键** |
| `controlPermissionDenied` | 辅助功能权限状态 |
| `keyboardMonitor = KeyboardMonitor()`（let） | **物理键盘监听——与 controlEngine 区别：controlEngine = AI 注入的按键（输出）；keyboardMonitor = 用户物理按下的键（输入，仅显示用 + 录制专家演示）** |
| `degradeStm = DegradeStateMachine()`（let） | **降级状态机（四态 + 极速覆盖 + 卡住检测）——tick() 每帧调用 update()，结果同步到 self.mode；阈值由本类的 degradeThreshold 等属性同步过去，UI 可调** |
| `recordEngine = RecordEngine()`（let，1301–1303 行） | **行驶录制引擎——isRecording didSet 触发启停，tick() 每帧调用 appendFrame；兼容现有 recordings 格式，供 DAgger 增量训练消费** |

## 五、三段胶水、startDriving / stopDriving

> 新锚点：`startDriving()` App:5760、`stopDriving()` App:5852。组件持有：captureEngine App:5252 / gameHUD App:5255 / controlEngine App:5262 / keyboardMonitor App:5271 / degradeStm App:5276 / ruleController App:5294 / confidenceEst App:5295 / inferenceEngine App:5300 / assistEngine App:5305 / yoloEngine App:5310 / yolopxEngine App:5324 / egoBoxFilter App:5331 / driveSegment App:5341 / fallbackGuard App:5362 / speedOCR App:5493 / questPanel App:5502。

**旧网络定位已移除（1305–1309 行注释）**：`NetworkPacketCapture` 已移除（不编译），**使用移植的 NetworkLocator**。

**三段胶水代码（第 1311–1336 行，接模型输出 → 状态机 → 按键注入）：**

| 实例 | 说明 |
|---|---|
| ~~`escapeController`~~ | **已删除（2026-09-30，脱困档整体移除）**——App:5290 注释明确；旧文此行作废 |
| `ruleController = RuleController()`（App:5294） | **.yolo/.rule 态 YOLO 检测→控制量规则** |
| `confidenceEst = ConfidenceEstimator()` | **E2E 无置信度头，用启发式从输出/画面估算** |
| `inferenceEngine = InferenceEngine()` | **CoreML E2E 推理引擎（m9_mono）——tick 异步触发推理，读 lastResult 作为本帧 E2E 输出；推理约 24Hz，tick 30Hz，未完成推理时沿用上一帧结果** |
| `assistEngine = InferenceEngine(modelFileName: "game_assist_control")` | **第二套驾驶模型（YOLO接管档的司机）——与 M9 同架构（画面+车辆状态→steer/throttle/brake），独立权重文件。档2 YOLO接管用它的输出开车；当前与 M9 同权重，后续可换训练权重** |
| `yoloEngine = YoloEngine()` | **CoreML YOLO 检测引擎——tick 异步触发，检测结果同时喂 RuleController 决策 + UI 画框** |
| `speedOCR = SpeedOCRReader()` | **车速表 OCR 读取引擎——CaptureEngine 原生帧 → 后台 OCR 读车速 → 主线程读 speedKmh/speedConfidence** |
| `currentCommand: ControlCommand = .idle`（private(set)） | **本帧最终决策命令（tick 末尾写出，供按键注入用）** |

**`init()`（第 1342–1463 行）——接线与 HUD 安装：**

1. `try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")`——**每次启动清空调试日志**（新会话从干净日志开始）
2. **帧率 HUD 接线（1344–1353 行）**：`gameHUD.fpsProvider = { (assist, game) }`——**辅助帧率 = 主线程 tick 速率（1000/tickGapMs）；游戏帧率 = ScreenCaptureKit 实际捕获到的合成帧率（≈游戏渲染帧率）**
3. **★ 仅 UI 进程安装（1354–1360 行注释）**：`if !CommandLine.arguments.contains("--engine") { gameHUD.install() }`——**引擎进程（--engine）也创建 DriveState，但它没有 NSApplication UI 上下文，在其中创建 NSWindow 会触发 AppKit 断言崩溃（实测：NSViewSetCurrentlyBuildingLayerTreeForDisplay, NSView.m:12937，导致引擎「就绪」后 1ms 即崩、UI 显示失联）**
4. **onFrame 接线（1364–1376 行）——跳帧防堆积**：captureQueue 后台线程**只"覆盖"最新待显示帧（加锁），不再 main.async 排队**——"主线程（tick）卡时，旧帧被下一帧覆盖丢弃 → 天然跳帧，永不积压。SwiftUI 更新由 tick 在主线程赋 currentScreenImage 触发"；**NSImage + CGImage 同回调原子写入，避免推屏/推理/录制跨帧错位**
5. **onYoloFrame 接线（1377–1386 行）**：CaptureEngine 源头缩放好的缓冲**直接喂推理引擎（跳过 NSImage/CGImage 大图转换 → 检测帧率↑）**——跳帧覆盖式（不往 main 队列堆积 1.6MB 缓冲）
6. **onNativeFrame 接线（1387–1397 行）**：**P1-2：字模录制复用同一条原生 ROI 直通（speedROINorm 与 glyphROI 同区域），直接把原生缓冲交给 RecordEngine 存字模 PNG（数字 ~95px，不再走 480px 缩略图）**
7. **onUpscaleFrame 接线（1398–1402 行）**：全分辨率帧 → `upscaleHost.push`（**仅显示路径**）
8. **onStatusChange 接线（1403–1430 行）**：permissionDenied → capturePermissionDenied=true；started → false + isStreaming=true；stopped/error → isStreaming=false + **frameHost.clear()（画面回落黑底，避免常驻 + 重启闪旧帧）** + **三组 pending 帧全部清空（1415–1427 行）——"清残留 pending 帧，避免停止后下一 tick 消费旧帧再 push（重启闪旧帧）"**（三把锁逐个清）
9. `upscaleHost.prepare()` + `upscaleSupported = isAvailable` + dlog
10. **EngineClient.onActivated 接线（1436–1442 行）**：**引擎（重新）连上时把 UI 当前的画面档位同步给引擎——否则引擎默认发 480 宽缩略帧，UI 开着插帧就会一直等不到全分辨率帧**：`setUpscale(upscaleEnabled && upscaleSupported)` + `sendCommand("status")`
11. 旧网络定位回调已移除（1444–1461 行注释）+ dlog

**`startDriving()`（第 1470–1503 行）——启动自动驾驶，引擎模式分支：**

- **引擎模式（1471–1479 行）**：`EngineClient.shared.isActive` 时——`sendCommand("start")` + lastDriveCommandTime + isDriving=true + drivingStartTime → **return（UI 不启动本地抓屏/推理/按键）**
- **本地模式（1480–1503 行）**：
  1. `guard controlEngine.checkPermission()`——无权限 → controlPermissionDenied=true + `openAccessibilitySettings()`（引导授权）+ return
  2. **开始驾驶前清掉系统里残留的卡键（1489–1491 行）**："上次进程异常退出可能留下未释放的 W/A/S/D，污染游戏输入；releaseAll 无条件清理"
  3. isDriving=true + drivingStartTime + `keyboardMonitor.start()`（KeyboardBar + 录制用）+ `captureEngine.start()`
  4. **三模型 loadIfNeeded（1498–1500 行）**：M9 / assistEngine（第二司机）/ yoloEngine——**首次启动加载**
  5. dlog 启动状态（权限/专家/禁用 + 三模型加载结果）

**`stopDriving()`（第 1511–1535 行）——停止自动驾驶：**

- **引擎模式（1512–1519 行）**：`sendCommand("stop")` + lastDriveCommandTime + isDriving=false → return（**引擎侧释放按键并停止抓屏**）
- **本地模式（1520–1535 行）**：isDriving=false → `controlEngine.releaseAll()`（**1. 释放所有按住的键，避免按键卡住**）→ `keyboardMonitor.stop()` → `captureEngine.stop()` → **4. 重置链**（App:5864-5872）：`degradeStm.reset()` + `confidenceEst.reset()` + `inferenceEngine.reset()` + `assistEngine.reset()` + `yoloEngine.reset()` + `speedOCR.reset()`（**escapeController.reset 已随脱困删除**） → `currentCommand = .idle` → **5. `if isRecording { isRecording = false }`（didSet 会触发 recordEngine.stop()，保证 meta.json 落盘）**

## 六、档位开关 / 防冻结禁用 / 一键训练与模型热部署

> 新锚点（**2026-10-07 D7b 实测，已含 +121**）：`setUpscaleEnabled` **App:6015**、`setGameModeBoost` **App:6026**、`startTraining` **App:6069**、`deployTrainedModel` **App:6115**、`clearRawClips` **App:6161**。
> ⚠️ 旧版本行写 5894/5905/5948/5994/6040 = **未加 121 的旧值**；`+121` 后为 6015/6026/6069/6115/6161，与实测函数声明**逐条吻合**（`sed` 核过）。

**`setUpscaleEnabled(_ on: Bool)`（第 1554–1563 行）**——插帧/超分开关：

1. `upscaleEnabled = on` + `captureEngine.upscaleEnabled = on`（采集侧同步）
2. **引擎模式（1557–1561 行注释）**：**通知后台引擎切画面档位（全分辨率 ↔ 480 宽缩略），否则引擎不知道 UI 开没开插帧，会一直发缩略帧导致插帧没数据**——`EngineClient.shared.setUpscale(on)`
3. dlog 开关状态

**`setGameModeBoost(_ on: Bool)`（第 1565–1583 行）**——游戏模式兼容开关：

1. `gameModeBoost = on`（didSet 会触发 applyMainThreadBoost——见单元四）+ `captureEngine.gameModeBoostEnabled = on`（捕获线程同步）+ `applyMainThreadBoost(on)`（**主线程时间约束调度**）
2. **开启时（1570–1578 行）**：`startAntiFreeze()` + **检查是否已安装 daemon，未安装则弹出安装引导**——`DaemonSetupManager.needsInstall()` → 延迟 0.5s 弹出（**避免与启动时的弹窗冲突**）`showDaemonInstallSheet = true`
3. 关闭时：`stopAntiFreeze()`

**防冻结心跳已禁用（第 1585–1598 行，诚实标注）：**

- **`startAntiFreeze()`——已禁用，不再启动心跳**——源注释（1587–1588 行）："**原因：每 100ms 发送键盘事件导致系统崩溃，鼠标无法移动**"——只 dlog"[antifreeze] 心跳已禁用（避免系统崩溃）"
- `stopAntiFreeze()`：antiFreezeTimer cancel + nil（残留清理保留）

**`startTraining()`（@MainActor，第 1608–1646 行）——一键训练（拉起 Python 训练进程）**：

- **注释（1602–1606 行）**："拉起 python3.11 训练脚本（**只训控制模型**）：`--skip_view`（视角分类器按决策删除不做，不训练）+ `--skip_yolo`（YOLO 用现成预训练 CoreML，无需重训）。**训练完成后自动把新控制模型热替换进推理引擎（点完即用）**。进程后台运行，UI 按钮文字切到「训练中…」，结束经 terminationHandler 回主线程"

1. `guard !isTraining` → isTraining=true + trainingLog="启动训练进程…"
2. **Process 组装（1613–1623 行）**：`/usr/local/bin/python3.11` + `["src/train_game_assist.py", "--skip_view", "--skip_yolo"]` + currentDirectoryURL 硬编码项目根 + **输出重定向到 `train.log`（standardOutput + standardError 同一 FileHandle——"避免管道缓冲区满导致训练进程挂起"）**
3. **terminationHandler（1625–1638 行）**：主线程——isTraining=false → 成功（退出码 0）：trainingLog="训练完成，应用新模型…" → `deployTrainedModel()` 成功才 `clearRawClips()`；失败：trainingLog="训练失败（退出码 N），详见 train.log"
4. `try proc.run()`；失败 isTraining=false + "无法启动训练"

**`deployTrainedModel() -> Bool`（@discardableResult，第 1654–1695 行）——把训练产出的控制模型复制到 m9_mono 并热替换：**

- **注释（1648–1652 行）**："**优先 FPV 专用模型（当前录制为 FPV 视角），回退 TPV/FPV 共用模型**。扩展名跟随源：若 coremlcompiler 缺失，coremltools 仍会 save 出 .mlpackage，**CoreML 运行时可直接加载未编译的 .mlpackage，链路照样闭环**"

1. **四候选（1657–1660 行）**：`game_assist_control_fpv.mlmodelc` / `game_assist_control.mlmodelc` / `game_assist_control_fpv.mlpackage` / `game_assist_control.mlpackage`——第一个存在的入选；全无 → "未找到训练产出的控制模型，请检查 train.log" + false
2. **清理旧模型（1666–1675 行）**：**清理另一扩展名的旧模型，避免 InferenceEngine.modelURL 误选**（两种 ext 各删 m9_mono）+ 删目标位置的旧文件
3. `copyItem(at: src, to: dst)`——dst = `m9_mono.{src扩展名}`
4. **引擎模式分支（1680–1689 行注释）**："**模型文件已落盘；但真正开车的推理引擎可能不在本进程：引擎模式 → 命令引擎重新加载（否则引擎一直用内存里的旧模型）；本地模式 → 直接置空本进程的三个引擎**"——引擎模式：`sendCommand("reloadmodel")` + `inferenceEngine.reloadModel()` + trainingLog"已应用新模型（引擎侧已通知重载）"；本地模式：**三引擎全部 reloadModel()**
5. 失败 → "模型部署失败"

**`clearRawClips()`（第 1700–1715 行）——训练成功且模型部署后，清理 data/raw_clips 下所有录制 clip：**

- **注释（1697–1699 行）**："录制数据仅用于训练，**训完即弃**，避免无限累积、下次训练重复读取旧数据。**仅在部署成功时调用；失败保留数据以便排查**"
- 列目录 → `clip_` 前缀逐个 removeItem → trainingLog"已应用新模型，并清理 N 段录制数据"；失败 → "模型已应用，但清理录制数据失败"

## 七、tickEngineMode 回声防环与 pushEngineConfigIfChanged

> 新锚点（**2026-10-07 D7b 实测，已含 +121**）：`tickEngineMode()` **App:6179** 起；版本守卫实测 **App:6231-6241**（`if client.isEngineStale` :6231、`engineRelaunching` 防重入 :6232-6235、驾驶中提示 :6236-6237、无错配清空 :6239-6240）；速度回传落位实测 **App:6244-6249**（mode/confidence/remoteSpeedKmh/effectiveSpeed/speedValid 逐个先比后写）；`pushEngineConfigIfChanged()` 实测 **App:6385**。本节逐条语义复核仍准确。
> ⚠️ 旧版此行写「App:6058 起 / 6125-6128 / 6106-6120」= **未加 121 的旧值**（`+121` → 6179 / 6246-6249 / 6227-6241）。

**`tickEngineMode()`（@MainActor，第 1719–1813 行）**——引擎模式下每 tick 拉取显示数据（**本地抓屏/推理/按键全部不跑**）：

1. `let client = EngineClient.shared` + `guard client.isActive else { return }`
2. **消费最新待显示帧（1723–1747 行）**：`client.poll() -> CGImage?`；非 nil 时 `currentScreenImage = image` + `currentFrameCG = cg`（**仅主线程，SwiftUI 自动刷新**）+ **帧宿主直绘** + **isStreaming = true**
   - **CVPixelBuffer 分支（1708–1740 行）**：`upscaleHost.push(pixelBuffer: pb)` + isStreaming + **源尺寸必须随帧更新（不能只在 nil 时设一次）**——"检测框叠加、框选手势的坐标换算都以 screenSize 为基准，尺寸变了却不更新 → 框错位、框选选不中"（`if screenSize != sz { screenSize = sz }`）
   - CGImage 分支（1741–1747 行）：同构 + frameHost.push
3. **引擎已停止抓屏同步收尾（1748–1757 行）**：`!client.engineIsStreaming && isStreaming` → isStreaming=false + upscaleLive=nil + **`upscaleHost.clear()`（停掉 MetalGoose 渲染 detach）** + frameHost.clear()——"**否则 isStreaming 会一直停在 true（引擎模式下只在有帧时被置 true，从不复位），导致插帧视图继续挂着、徽章一直显示'插帧中'（用户实测反馈）**"
4. **协议版本守卫（1758–1775 行）——必须放在状态镜像之前**：
   - `client.isEngineStale` 且 `!isDriving && !client.engineRelaunching` → `engineRelaunching = true` + engineVersionWarning"检测到旧版引擎，正在重启…" + **`client.relaunchStaleEngine()`**（重启旧引擎）
   - 驾驶中或重启中 → engineVersionWarning"⚠️ 引擎版本不匹配，停止驾驶后自动重启"
   - **engineRelaunching 由 EngineClient 持有并在重启完成后清除——不能用 UI 局部标志，否则重启流程中途 isEngineStale 仍为真时会无限重复触发**（1763–1764 行注释）
   - 无错配时清空警告
5. **驾驶状态回传落位（1776–1791 行）**：**引擎模式下 UI 不跑推理，面板/状态栏依赖的驾驶状态由引擎心跳回传后落到这里——档位、车速（含车速表读数）、置信度、有效车速。缺了这些，右侧状态栏与自车信息会「空掉」**——mode/confidence/remoteSpeedKmh/effectiveSpeed 逐个 `if !=` 才写（**逐帧无条件赋值也会触发 SwiftUI 刷新 → 只在变化时写**）；speedValid = `engineSpeedKmh >= 0 && engineSpeed > 0.5`
6. **锁定目标追踪（1784–1786 行）**：`yoloEngine.trackLockFromRemote(client.engineDetections)`——**引擎模式下必须用引擎回传的检测框推进，否则锁定框冻在原地不动、目标离开也不会自动解除**
7. **isDriving 回同步（1787–1791 行）**：**引擎是状态权威源；命令发出后 1 秒内保留 UI 乐观值，避免切换瞬间闪烁**——`Date().timeIntervalSince(lastDriveCommandTime) > 1.0` 时才镜像
8. **录制状态回同步（1793–1804 行）**：**引擎是权威源：引擎进程真正写盘，UI 只显示帧数。置 applyingRemoteRecord 防回环，否则 isRecording 的 didSet 会把命令回声给引擎。宽限期 2 秒**（心跳 1Hz + 引擎带即时回执，否则命令刚发出、心跳还没更新时会把用户刚拨的开关弹回去）；frames 镜像（引擎录制 ? engineRecordFrames : 0）
9. `pushEngineConfigIfChanged()`——**驾驶参数下发（极速/禁用控制/紧急切规则/专家/字模/降级阈值）——这些只在 tick() 里被读，而引擎模式下 tick() 跑在引擎进程——必须显式推送。只在变化时发，避免 30Hz 刷屏**
10. **插帧实时统计（1809–1812 行）**：useUpscale 时 upscaleLive 字符串（"产出 N · 透传 N · 输入 Nfps → 输出 Nfps"）

**`pushEngineConfigIfChanged()`（private，第 1818–1832 行）**：

- **快照对比**：`snap = "\(sportMode)|\(controlDisabled)|\(forceRuleMode)|\(expertMode)|\(glyphMode)|\(degradeThreshold %.3f)|\(speedLimit %.1f)"` → `guard snap != lastPushedEngineConfig`（变化检测，1835 行 lastPushedEngineConfig 默认 ""）
- `sendCommand("config", extra: [...])` 七参数——**"速度上限直接进 vehicle_state[4]，不是显示项"**（1829 行注释）

## 八、tick() 主循环——完整决策管线

> ⚠️ 本节行号已按 **8335 行版（2026-10-06 实测）** 重写；旧版 1837–2092 行号作废。

**`tick()`（App:6383 起）**——每帧推进（30Hz，由 MissionConsole.swift:5529-5558 的 DispatchSource `com.aurora.tick` 驱动，事件回调 `DispatchQueue.main.async { state.tick() }`（MissionConsole.swift:5558）——**不是 ContentView 的 Timer**，旧文有误；待机时降频至约 3.75Hz（MissionConsole.swift:5539-5549）。**完整决策管线：跳帧消费 → quest OCR → 速度/卡死 → 降级决策 → 按态输出 → 注入 → 录制**。

**① 诊断 + 引擎分流（App:6384-6404）**：tickGapMs（实际间隔，>33ms = 主线程掉拍）；`if EngineClient.shared.isActive { tickEngineMode(); return }`（App:6400-6403，**本地抓屏/推理/按键全部不跑**）。

**② 消费跳帧缓冲（App:6406-6425）**：锁内取 pendingFrame/CG/Time → `frameDeliveryLagMs` → currentScreenImage/currentFrameCG 赋值（SwiftUI 刷新）→ `frameHost.push(cg)`（isStreaming 时）→ screenSize 更新。

**②.6 原生 ROI 帧消费（App:6543-6554）**：取最新 pendingNativeFrame → `speedOCR.infer(nativePixelBuffer:)`（App:6549）+ 字模录制（`recordEngine.glyphMode && isRecording` 时 `appendGlyphNative` + frames 同步，App:6551-6553）。

**②.5 任务面板 OCR（App:6427-6436，2026-10-06 task-1 新增，旧文无此节）**：门 `AuroraFlags.questOCR`（AF:201，默认 true）——`if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（App:6435-6436）；节流与在途保护在 QuestPanelReader 内部（0.7s 间隔 + ocrInFlight）。

**②.7 YOLO 直通帧 + 光流（App:6441-6542）**：取最新 pendingYoloFrame → `yoloEngine.inferFast(pixelBuffer:)`（App:6442-6444）；同一份 640×640 直通帧喂 `runOpticalFlow`（App:6447 起；函数定义 App:6181），受**两条闸门"与"关系**控制：`!Self.opticalFlowDisabled`（App:6535；该静态属性 App:5399-5400 仍直接下标读 `AURORA_DISABLE_OPTICAL_FLOW`，未走 AuroraFlags——全仓残留的一处直接读）+ `perceptionMode.needsOpticalFlow`（App:6535，按档位门控：仅 `.legacy` 档跑光流）。

**③ 待机分支（App:6556-6572）**：`guard isDriving else {` 内：`if speedValid { speedValid = false }` + `effectiveSpeed` 每帧 -6 衰减（App:6569）+ `currentCommand` 回 .idle——**全部先比后写**（App:6560-6567 注释）；`recordFrameIfNeeded()`（**待机也写帧：录制不依赖驾驶状态**，App:6570）→ return。

**⑤ 有效车速（App:6636-6645）**——OCR 新鲜 → EMA 追真实读数；否则一阶滤波回退：

- `ocrFresh = speedOCR.speedKmh >= 0 && confidence > 0.3 && lastResultTime < 0.5`（App:6636-6638）→ 先比后写 `speedValid`（App:6641）
- ocrFresh → `effectiveSpeed += (ocr - effectiveSpeed) × 0.7`（**快跟踪**，App:6643）；否则 `× 0.9` 向 0 衰减（<0.5 归零，App:6645-6647）
- `fps` 如实反映捕获帧率，**不回退成 60 伪造**（App:6649-6651）

**⑥ 卡死 → 请求人工介入（App:6653-6680，2026-10-02 新增）**：`isDriving && speedValid && effectiveSpeed < 1.0` 持续 ≥ `stuckZeroThreshold`（App:5127-5131，读 `AURORA_STUCK_SECONDS`，默认 30s）→ `needsManualIntervention = true` 拉横幅。**只提示不动车——AI 绝不自行脱困**（App:6655-6657 注释；历史教训见 FallbackGuard 取证 App:6250）；零速判据要求 `speedValid` 为真，避免「OCR 读不到就误报卡死」；车动起来立即撤横幅清计时（App:6678-6681）。

**⑥.5 降级状态机决策（App:6682-6697）**：暖机期 `warmingUp = inferenceEngine.lastResult == nil && 开车 < 3.0s`（App:6684-6685）；`decided = degradeStm.update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:)`（App:6686-6695）→ **先比后写** `if mode != decided { mode = decided }`（App:6697）。三档梯子与优先级链详见 代码-20 文档。

**⑦ 置信度估计（App:6699-6717）**：暖机期 `if confidence != 1.0 { confidence = 1.0 }`（App:6707，先比后写）；否则 `confidenceEst.update(command:image:isLive:)`（App:6711-6714）——喂**当前档位**驾驶模型的输出 + 画面；先比后写 App:6716。

**⑧ 按态输出控制量（App:6871-6886）**：

```swift
switch decided {                                    // App:6871
case .e2e:  if currentCommand != m9Command { currentCommand = m9Command }         // 档1 M9 直接开车（App:6873-6874）
case .yolo: if currentCommand != assistCommand { currentCommand = assistCommand } // 档2 第二套网开车（App:6875-6877）
case .rule: let ruleCmd = ruleController.decide(detections: detections)           // 档3 手写规则最后防线（App:6878-6880）
}                                                   // 全部先比后写（App:6855-6870 注释）
```

- `detections` 已经 `effectiveDetections`（App:4067 `egoBoxFilter.filter(displayDetections)`）**剔除自车框**——只作用于决策层，UI 照画全部框。
- **`.recover` 档已删除**（旧文此行作废）：脱困策略整体移除（App:5290 注释），`lastDecided` 仅作诊断留档、不再做边沿检测（App:6882-6888 注释）。

**⑧.5 车道保持 / 驾驶分段覆盖（App:6900-7295，2026-10-02 起生效）**：档位门 `if Self.laneKeepTiers.contains(decided)`（App:6917；`laneKeepTiers` 定义 App:5427-5428，默认 `rule,yolo`，`AURORA_LANEKEEP_TIERS=rule` 一键回退）→ LaneFallback 车道保持 + `segmentDecisionForRule(pose:)`（App:7252 起）调用 `driveSegment.update(...)`（App:7295）：地图段/回正段的 mapSteer **覆盖**视觉转向、建议限速参与后续油门计算。

**⑨ 按键注入（App:7014-7035）**：专家/禁用控制分支走节流版 `controlEngine.releaseAllIfNeeded()`（App:7029；旧行为每帧无条件 `releaseAll()` 由回退开关 `AURORA_RELEASE_ALL_EVERY_TICK=1` 保留，App:7026-7028、AF:283）；否则 `applyCommand(currentCommand)`（App:7034；转向死区 ±0.1、油门/刹车互斥阈值 0.3、`refreshHeldKeys()` 每帧重发——applyCommand 定义 App:7321 起，语义与旧文一致）。

**⑩ 录制 + 插帧状态 + 调试摘要**：`recordFrameIfNeeded()`（App:7042；函数定义 App:7162 起——字模走原生路径防双写、专家模式录按键时长标签、默认录 AI 决策；键码 A=0/D=2/W=13/S=1/Space=49，App:7039 注释）；调试摘要 1Hz（写 /tmp/aurora_debug.log，App:7065 起：mode/模型存活/命令/注入权限/front 前台应用/capGap/capWork/tickGap 等；插帧统计与分段打点导出共用同一 1Hz 闸门，App:7100、:7120-7128）。

## 九、recordFrameIfNeeded 与 applyCommand 按键映射

> 新锚点（**2026-10-07 D7b 实测，已含 +121**）：`recordFrameIfNeeded()` **App:7283** 起（glyph 跳过实测 **:7286** `guard !recordEngine.glyphMode else { return }`、专家模式键码标签实测 **:7294-7301**：`:7295/:7296` A=0/D=2、`:7298` W=13、`:7300/:7301` S=1/Space=49）；`applyCommand` **App:7442** 起（转向死区/互斥/refreshHeldKeys 语义不变）。
> ⚠️ 旧版此行写 `recordFrameIfNeeded` App:7162、`applyCommand` App:7321 = **未加 121 的旧值**；`+121` → 7283 / 7442，与实测声明吻合。**本节内联的「2038/2096」「2097–2127」「2131–2160」等行号同样是旧基准**（见文末换算总表）。

**`recordFrameIfNeeded()`（private，第 2097–2127 行）**——每帧录制写帧（画面 + 控制量），驾驶与待机共用：

1. **`guard !recordEngine.glyphMode else { return }`**——字模模式走 onNativeFrame 原生路径（appendGlyphNative），**此处跳过，避免 appendFrame 再写一遍 640px/480px 缩略图造成双写**
2. `guard isRecording, let image = currentScreenImage`
3. **控制量来源二选一（2102–2120 行）：**
   - **expertMode（专家模式）**：`RecordLabelMapper` 连续标签——`steer(leftHeld: keyboardMonitor.holdDuration(keyCode: 0), rightHeld: holdDuration(keyCode: 2))`、`throttle(wHeld: holdDuration(keyCode: 13))`、`brake(sHeld: holdDuration(keyCode: 1), spaceHeld: holdDuration(keyCode: 49))`——**标签语义：按键按住时长/满刻度时长 → 连续值（0~1，带符号），与推理端"|steer|>阈值 → 按住键 → 游戏按按住时长平滑转角"闭环一致**
   - 否则（AI 决策）：`recSteer/Throttle/Brake = currentCommand` 三元组——**默认录 AI 决策（供 DAgger 自训练）**
4. `recordEngine.appendFrame(image:steer:throttle:brake:)` + `frames = recordEngine.frameCount`

**键码对照（2038/2096 行注释）**：**与 ControlEngine 注入一致：A=0 左 / D=2 右 / W=13 油门 / S=1 刹车 / Space=49 手刹**（macOS virtualKey 体系）。

**`applyCommand(_ cmd: ControlCommand)`（private，第 2131–2160 行）**——把 ControlCommand 映射到按键注入（**steer>0 右转，<0 左转；throttle 油门；brake 刹车/倒车**）：

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
- **`refreshHeldKeys()` 必须每帧调用（2156–2159 行注释）**：**持续按住的键按控制周期重发按下事件（等价真实键盘 auto-repeat）。缺了这一步，控制量稳定时（E2E 直道恒定油门）整段驾驶只会产生一个 keyDown，游戏收不到任何后续事件——表现为「UI 显示按住、车不动」**

**DriveState 状态主体文档至此完整**（851–2161 行全覆盖：RecordLabelMapper → 开关字段 → isRecording didSet → 跳帧防堆积 → startDriving/stopDriving → 一键训练热部署 → tickEngineMode → tick() 决策管线 → 录制与按键映射）。
## 十、AuroraFlags.swift 全部开关清单（2026-10-06 逐行核实，Core/AuroraFlags.swift，543 行）

`AuroraFlags` 是环境开关的**唯一事实源**（AF:5），读取收敛到唯一入口 `raw()`（AF:89-92）；布尔语义「只有 `"1"` 算开」（AF:99-102），反向布尔「只有 `"0"` 算关」（AF:106-109）。全表 `all` 在 AF:426-510，`--flags-help` 由 `helpText()`（AF:521-530）打印。

唯一例外：`egoCheck` **刻意不 static let 化**，每次现读（AF:235），因 App:3420 的自检会在运行时 `setenv("AURORA_EGO_CHECK","off",1)` / App:3424 `unsetenv`（佐证 EgoMotionModel.swift:207-208）。

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
| laneKeepTiers | AURORA_LANEKEEP_TIERS | (未设→`rule,yolo`，解析在 App:7578 起 / 消费 App:5427-5428) | AF:280 |
| releaseAllEveryTick | AURORA_RELEASE_ALL_EVERY_TICK | false | AF:283 |
| stuckSeconds | AURORA_STUCK_SECONDS | 30 | AF:286 |
| enableBgDrift | AURORA_ENABLE_BG_DRIFT | false | AF:289 |
| segStraightenDeg | AURORA_SEG_STRAIGHTEN_DEG | 15.0 | AF:292 |
| segStraightenDoneDeg | AURORA_SEG_STRAIGHTEN_DONE_DEG | 8.0 | AF:294 |
| segHandoverM | AURORA_SEG_HANDOVER_M | 15.0 | AF:296 |
| segHandoverFrames | AURORA_SEG_HANDOVER_FRAMES | 10 | AF:298 |
| segCorridorM | AURORA_SEG_CORRIDOR_M | 8.0 | AF:300 |
| segMapTimeoutS | AURORA_SEG_MAP_TIMEOUT_S | 20.0 | AF:302 |

> 口径提醒：`AURORA_STUCK_SECONDS` 的**实际消费者**是 App:5127-5131 的 `stuckZeroThreshold`（直接下标现读，未走 AuroraFlags）；AuroraFlags.stuckSeconds（AF:286）为收敛层声明，两条读取路径并存。

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

⚠️ 口径说明：上表为 `AuroraFlags` 的 static 属性全集（按分区合计 74 个：A5+B4+C7+D9+E10+F13+G19+H6+I1）。文件头自述「72 个变量」（AF:10、AF:86）为 2026-10-04 落地时的统计，与当前属性数已不完全一致（差异来源未验证：应为后续分区新增，未逐一考古）。另：`AURORA_DISABLE_OPTICAL_FLOW` 在 App:5399-5400 仍有**独立重复读取**（`Self.opticalFlowDisabled`，未走 AuroraFlags）；`AURORA_STUCK_SECONDS` 在 App:5127-5131 同样直接下标读（见 E 区口径提醒）。

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
| `agent.skill`（workQueue） | AIAgentPanel.swift:**256**（⚠️ D7b 订正：旧写 :276——实测 :276 是 `guard !settings.apiKey.isEmpty`，队列声明在 :256） | userInteractive | AI 技能工作队列 |
| `aurora.engine.client` | EngineClient.swift:147 | userInteractive | UI 侧 socket 读 + 重连定时器 |
| `aurora.engine.socket` | EngineMain.swift:437 | userInteractive | 引擎侧 socket 服务 |
| `aurora.engine.tick` | EngineMain.swift:781 | userInteractive | 引擎 30Hz tick 定时源，**回调再 main.async 进主线程**（:784-789） |
| `aurora.engine.heartbeat` | EngineMain.swift:795 | （默认） | 引擎 1Hz 心跳（:797） |
| `aurora.engine.signal` | EngineMain.swift:696 | （默认） | SIGTERM/SIGINT 处理，置 shutdownRequested 后 main.async 安全停车（:694-709） |
| `aurora.defender` | GameModeDefender.swift:153 | userInteractive | Game Mode 对抗，每 3s 重主张（:19、:94） |
| `aurora.privilege.process` | PrivilegePill.swift:251 | utility | 提权脚本执行 |
| `com.aurora.tick` | MissionConsole.swift:5534 | userInteractive | 地图控制台 tick 驱动（30Hz / 待机 3.75Hz），回调 main.async（:5558） |
| `com.aurora.netlocate` | MissionConsole.swift:5604 | userInteractive | 网络定位轮询 10Hz，回调 main.async（:5607） |
| `com.aurora.logsink` | App:**8337-8338**（⚠️ D7b 订正：旧写 :8216-8217） | utility | 日志缓冲写盘 |
| `aurora.upscale.ingest` | App:**8101**（⚠️ D7b 订正：旧写 :7980） | userInitiated | 插帧 ingest |
| `com.aurora.record.write` | RecordEngine.swift:75 | （默认/unspecified） | 录制写盘 |
| `com.aurora.confidence.brightness`（brightnessQueue） | ConfidenceEstimator.swift:217-218 | userInitiated | 画面亮度估计 |

### 11.2 主线程 / 后台分工（关键事实）

- **主线程（MainActor）**：`DriveState.tick()` 全部决策（App:6384 起；DegradeStateMachine 仅主线程访问 DegradeStateMachine.swift:23）；`tick()` 由 `com.aurora.tick` DispatchSource 触发后 `DispatchQueue.main.async` 投递（MissionConsole.swift:5558）；`EngineGlobals` 全部 @MainActor（EngineMain.swift:582-590）；QuestPanelReader 的投票/匹配/落库回主线程（QPR:557，onConfirmed 主线程执行 App:5568-5572 注释）。
- **captureQueue 特殊性**：它是 SCStream 采样队列，「不是普通后台队列」（App:5614 注释）；回调里只做**覆盖式写 pendingFrame**（加锁，App:5583-5596），SwiftUI 更新由 tick 主线程消费（App:6406-6425）。光流曾于 09-27 被移到 captureQueue，09-28 **已回退主线程 tick**（App:5364-5372 注释、App:6452-6458 说明）。
- **引擎进程**：30Hz tick 定时器在 `aurora.engine.tick` 触发但计算 `tickOnce()` 强制回主线程（EngineMain.swift:781-791）；共享内存 BGRA 双缓冲由引擎写/UI 读（EngineMain.swift:18 注释、:353/:378 写入）；`latestFullFrame` 采集线程写/主线程读 + NSLock（EngineMain.swift:592-593、:763-766 写侧 / :891-893 读侧）。
- **跳帧防堆积模式**（贯穿全项目）：生产者（后台队列）只覆盖「最新一帧」槽位，消费者（主线程 tick）取最新——pendingFrame/pendingYoloFrame/pendingNativeFrame 三处（App:5583-5596 写 / 6406-6444 消费）。
- **@Observable 先比后写纪律**：值不变不赋值，省观察者通知（questName App:5577、mode App:6697、confidence App:6716、locatorFound App:4548 等）。

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
2. 该日志的 `降级=` 反映的是**引擎进程内 yolopxEngine 的掩码可信度**，与 UI 侧降级状态机（DegradeStateMachine 的 e2e/yolo/rule 三档）**不是一回事**：驾驶档位降级由引擎进程自己的 `DriveState.tick → degradeStm.update` 决定（App:6686），经心跳 `engineMode` 回传 UI（EngineClient.swift:116-118「降级档位（引擎是权威源）」）。日志里看不到档位，要看心跳/面板。
3. 若 `有帧=false` 持续出现（非刚启动）：先查抓屏权限 / `AURORA_ENGINE_DIAG_CAPTURE_ONLY` 诊断 / `frameHost` 是否从未 push——即**帧管道问题**，与降级状态机无关；降级状态机此时也不会动（tick 在引擎模式提前 return 前就跑了完整本地管线？——不是：引擎进程 isActive 恒 true，走 tickEngineMode 的是 **UI 进程**；引擎进程自己的 tick 跑完整决策管线，其降级档位经心跳回传）。
4. UI 侧看到的 `engineMode/engineSpeed/engineConfidence` 等驾驶状态全部来自引擎心跳字段（EngineClient.swift:116-126），`speedValid = client.engineSpeedKmh >= 0 && client.engineSpeed > 0.5`（App:6127-6128，先比后写）。引擎失联（`engineConnected=false`）时 UI 状态面板显示「未连接」（MissionConsole.swift:3312-3313），档位显示沿用引擎最后回传值，UI 不自行接管档位。


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

## §附、D7b 行号换算总表与勘误（2026-10-07 逐条 `sed` 实测）

**背景**：`AuroraDriveApp.swift` 由 8335 → **8456 行**（提交 `2c0459a` 真对话/自主按键 + `22a6604` 会话滑动窗口，新增内容全在 `DriveState` 之前的文件前部），故 `DriveState` 及其后统一 **+121**。文首已给出该规则，但 **§六/§七/§九 的「新锚点」行违反了它**（写成未加 121 的旧值）。下表为实测汇总。

### A. 正文内联锚点勘误（已就地订正 6 处）

| 节 | 旧写 | ✅ 实测（= 旧值 +121） |
|---|---|---|
| §六 头部 | setUpscaleEnabled 5894 / setGameModeBoost 5905 / startTraining 5948 / deployTrainedModel 5994 / clearRawClips 6040 | **6015 / 6026 / 6069 / 6115 / 6161**（`sed` 逐条命中函数声明） |
| §七 头部 | tickEngineMode 6058 / 速度回传 6125-6128 / 版本守卫 6106-6120 | **6179 / 6244-6249 / 6231-6241** |
| §七 头部 | `pushEngineConfigIfChanged` 「在其后」 | **6385**（实测函数声明） |
| §九 头部 | recordFrameIfNeeded 7162 / applyCommand 7321 | **7283 / 7442** |
| §十一 队列表 | `agent.skill` AIAgentPanel.swift:**276** | **256**（:276 实为 `guard !settings.apiKey`） |
| §十一 队列表 | logsink App:8216-8217 / upscale.ingest App:7980 | **8337-8338 / 8101** |

### B. 未订正但需按 `+121` 理解的内联行号（§九 正文）

`recordFrameIfNeeded` 正文里的「第 2097–2127 行」「2038/2096 行注释」、`applyCommand` 的「第 2131–2160 行」「2156–2159 行注释」等，均为**旧基准**；语义（glyph 跳过 / 专家模式键码标签 / 转向死区 ±0.1 / 油门刹车互斥 0.3 / 每帧 `refreshHeldKeys()`）经实测仍然正确，仅行号需按函数名重新定位。

### C. 已实测确认**正确**的关键锚点（可直接引用）

`final class DriveState` **:4102**、`locatorFound` **:4266**、`locatorX/Y/Score/Heading` **:4267-4270**、`locatorAccelX/Z` **:4274/:4276**、`locatorTarget` **:4277**、`questName` **:4283**、`routePlan` **:4293**、`clearRoute()` **:4315**（`locatorTarget = nil` :4320）、`setLocatorTarget(x:y:)` **:4414**、`heading(from:to:)` **:4416**、`runNetworkLocateStep()` **:4445**（懒初始化 :4448-4461）、`locateSource()` **:4438**、`dlog` **:4778**、`isRecording didSet` **:4887**、`stuckZeroThreshold` **:5248**、`captureEngine` **:5373**、`degradeStm` **:5397**、`ruleController` **:5415**、`confidenceEst` **:5416**、`inferenceEngine` **:5421**、`assistEngine` **:5426**、`yoloEngine` **:5431**、`yolopxEngine` **:5445**、`egoBoxFilter` **:5452**、`driveSegment` **:5462**、`fallbackGuard` **:5483**、`speedOCR` **:5614**、`questPanel` **:5623**、`startDriving()` **:5881**、`stopDriving()` **:5973**、`tick()` **:6505**、`readPose()` **:7392**、`segmentDecisionForRule` **:7406**、`applyCommand` **:7442**、`recordFrameIfNeeded` **:7283**、`applyLaneAdvice` **:7739**、`setenv("AURORA_EGO_CHECK")` **:3541** / `unsetenv` **:3545**。

### D. 本档本次**未验证**的残留项（诚实记录）

- §八 tick 内部若干细分锚点（如「待机分支 App:6556-6572」「卡死 App:6653-6680」「降级 6682-6697」）为 10-06 基准的 `+121` 推算值，**未逐条 `sed` 复核**（抽查 `tick()` :6505、感知层 :6701、降级 update :6807、按档输出 :6992/:7000 命中）。
- §十二 若干 EngineMain 行号（:810/:823-826/:599）实测**命中**；但 `App:6127-6128`（speedValid）实测指向的是**模型部署**区（应为 :6248-6249），已在 §七 订正。
- AI 面板改动全在 `Agent/AIAgentPanel.swift`（**3253 行**，最后一次改动 `22a6604` 2026-10-07 02:29），与本文覆盖的 `DriveState` 段**无重叠**——§〇·五 落点表行号经抽查基本吻合（`appendMessage` :208-215、`sendChatMessage` :1557、`encodeCurrentFrameForVision` :1636-1641、`AgentSettingsSheet` :2547、`LLMDiagnosticsSheet` :2453、`AgentConversationView` :2947、折叠提示 :2955-2962）。
