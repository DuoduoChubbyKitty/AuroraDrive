# 代码-25 AuroraDriveApp 之 DriveState 状态主体

> 🧭 **2026-11 规范化：本文不记录任何行号。** 代码位置一律用**源码中真实存在的符号**定位
> （类型 / 函数 / 属性 / 常量 / 环境变量），每个符号都能在 `Sources/` grep 到。行号随源码生长必然漂移，符号不会。
> 只改文档，未动 `Sources/`。

> ⚠️ **频率勘误（2026-11-08）**：当前 `DriveState.tick()` 正常由 **15Hz** 时钟驱动，待机分频约为 **15/8 = 1.875Hz**；
> 应急冲刺为 20Hz（`EmergencyTakeover` 提速）。下文出现的 20Hz/30Hz 数字多为 2026-10-18 快照或历史注释，
> 不能再当作当前运行值。`tick()` 的驱动者是 `MissionConsole` 里 label 为 `com.aurora.tick` 的 DispatchSource，
> 回调中 `DispatchQueue.main.async { state.tick() }`——**不是 ContentView 的 Timer**，旧文有误。

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift` 之中部：`DriveMode` / `DriveModeGroup` /
> `RecordLabelMapper` + `DriveState`。

### 符号锚点表（替代原「实测锚点表」）

| 单元 | 真实符号 |
|---|---|
| 三档模式 | `enum DriveMode`（`.recover` 已于 2026-09-30 删除） |
| 双档 UI 分组 | `enum DriveModeGroup` |
| 录制标签换算 | `enum RecordLabelMapper`（`fullScaleDuration` / `holdRatio(_:)` / `steer(leftHeld:rightHeld:)` / `throttle(wHeld:)` / `brake(sHeld:spaceHeld:)`） |
| 驾驶状态主体 | `final class DriveState`（`@Observable @MainActor`） |
| 定位器字段 | `locatorFound` / `locatorX` / `locatorY` / `locatorScore` / `locatorHeading` / `locatorAccelX` / `locatorTarget` / `questName` |
| 开关字段 | `isDriving` / `expertMode` / `glyphMode` / `forceRuleMode` / `agentMode` / `sportMode` / `controlDisabled` / `isTraining` / `isRecording`(didSet) |
| 路由方法 | `clearRoute()` / `planRouteToMapPixel(x:y:)` / `setLocatorTarget(x:y:)` / `runNetworkLocateStep()` |
| 驾驶方法 | `startDriving()` / `stopDriving()` |
| 引擎模式 | `tickEngineMode()` / `pushEngineConfigIfChanged()` |
| 主循环 | `tick()` |
| 录制与注入 | `recordFrameIfNeeded()` / `applyCommand(_:)` / `applyLaneAdvice(_:to:)`（文件级自由函数） |
| 引擎/决策组件 | `captureEngine` / `degradeStm` / `ruleController` / `confidenceEst` / `inferenceEngine` / `inferenceEngineV2` / `inferenceEngineV3` / `assistEngine` / `yoloEngine` / `yolopxEngine` / `egoBoxFilter` / `laneFallback` / `driveSegment` / `fallbackGuard` / `speedOCR` / `questPanel` / `recordEngine` |

## 〇、定位器与任务状态字段（定义 / 写入者 / 读取者）

`final class DriveState`（`AuroraDriveApp.swift`）中的定位器/任务字段，全部主线程读写：

| 字段 | 写入者 | 读取者 |
|---|---|---|
| `locatorFound` | 网络定位回调 `runNetworkLocateStep()`（**先比后写**：`if self?.locatorFound == false`）；游戏未运行时清除 | `planRouteToMapPixel(x:y:)` 起点判断；`readPose()` 门槛；决策门槛与 UI（注释称 24 处 UI 读取） |
| `locatorX` / `locatorY` | 网络定位回调（**写世界坐标 UE5 厘米**） | `DriveState.worldToMapPixelX/Y` 各调用点（`MapWiring.swift` 定义）；`readPose()`；NavGuidance 距离 `(t.x - locatorX)/100`（`MissionConsole.swift` 注释） |
| `locatorScore` | 网络定位回调（按新鲜度 tier 分级 `locatorScoreForTier`：live=1.0 / recent=0.3 / stale=0.1 / lost=0） | 决策门槛 0.4（`readPose()`）；诊断打印 |
| `locatorHeading` | 网络定位回调 | `readPose()`（供 `DriveSegmentController`） |
| `locatorAccelX/Y/Z` | 网络定位回调 | 仅如实展示（注释：坐标系未实测确认，**不参与控制**） |
| `locatorTarget` | ① `setLocatorTarget(x:y:)`（`QuestPanelReader` 确认回调调用，来自 quest_index 世界坐标）② `clearRoute()`（置 nil）③ 演示/自检夹具（`MissionConsole.swift`） | `MissionConsole.swift`（距离计算与路线规划） |
| `questName` | `QuestPanelReader` 确认回调（**先比后写**） | 任务卡片渲染（`MissionConsole.swift`） |

**quest 数据流闭环**：`tick()` 主线程调 `questPanel.ingest(cgImage:)`（门 `AuroraFlags.questOCR`）→
ROI 裁剪在主线程、Vision OCR 丢到 label `aurora.quest.ocr` 后台串行队列（`QuestPanelReader.swift`，`qos: .utility`）→
OCR 完成回主线程（`DispatchQueue.main.async`）→ `onConfirmed` 回调（主线程执行）→ 写 `questName` + `setLocatorTarget(x:y:)`。
`QuestPanelReader.swift` 文件头明确 `locatorTarget` 与 quest_index 同为世界坐标（UE5 厘米）。

### 决策组件的持有与所有权（全部为 DriveState 成员，主线程访问）

| 组件 | 说明 |
|---|---|
| `degradeStm` | `tick()` 每帧 update；阈值同步自 `degradeThreshold` |
| `ruleController` | `.rule` 档调 `decide(detections:)` |
| `egoBoxFilter` | `= EgoBoxFilter.configured`；决策层过滤 `effectiveDetections` |
| `laneFallback` | 车道线兜底决策器（fail-open） |
| `driveSegment` | `segmentDecisionForRule(pose:)` 内调 `update(...)` |
| `fallbackGuard` | **主链路已停用**（不再调用 `evaluate`；实例保留仅供自检中 `guardA` 等） |
| `inferenceEngine` / `inferenceEngineV2` / `inferenceEngineV3` / `assistEngine` / `yoloEngine` / `yolopxEngine` | 三套推理引擎 + V3 + 第二司机 + YOLO + YOLOPX |
| `questPanel` | `@ObservationIgnored let`，任务面板 OCR |

## 一、RecordLabelMapper 与 DriveState 开关字段

**`RecordLabelMapper`（enum，纯函数，便于单测）**——专家模式录制标签换算器。语义：把物理按键的"按住时长"
换算成连续控制标签——**与推理端闭环一致：`ControlEngine` 按 `|steer|>`阈值 决定是否按住键，游戏自身再把按住时长
平滑成转角——录制端用按住时长作为监督信号，让模型学到"打得越满 → 按住越久"的连续映射，替代二值标签带来的顿挫**。

| 方法/常量 | 签名 | 说明 |
|---|---|---|
| `fullScaleDuration` | `static let = 0.6` 秒 | **满刻度时长：按住满该时长 → 标签饱和 ±1**；默认 0.6s：30Hz 下约 18 帧，覆盖"轻点 → 满打"的常见手感区间 |
| `holdRatio(_:)` | `TimeInterval -> Double` | 按住时长 → [0,1] 比例（钳制）：`min(1, max(0, duration / 0.6))` |
| `steer(leftHeld:rightHeld:)` | 双时长 → Double | **D 按住比例 − A 按住比例，净差钳制到 [-1,1]（左负右正）** |
| `throttle(wHeld:)` | 时长 → Double | W 按住比例 [0,1] |
| `brake(sHeld:spaceHeld:)` | 双时长 → Double | **S 或 空格(手刹) 任一按住即刹车，取两者按住比例较大者 [0,1]** |

**`DriveState`（`@Observable @MainActor final class`）**——全局状态 + 驾驶闭环。**开关字段：**

| 开关 | 默认 | 说明 |
|---|---|---|
| `isDriving` | false | 是否驾驶中 |
| `sportMode` | false | 极速模式 |
| `isTraining` | false | 是否训练中 |
| `expertMode` | false | **专家模式：录制时控制量来源切到真人物理键（模仿学习的专家演示），而非 AI 决策（`currentCommand`）。关 → 录 AI 决策（DAgger 自训练）** |
| `glyphMode` | false | **字模模式：录制时输出原生分辨率速度表区域帧（供字模训练），与专家模式/训练录制互不影响，仅影响 `RecordEngine` 的输出内容** |
| `controlDisabled` | false | **禁用控制：模型照常检测画面（YOLO 框 + E2E 推理照跑），但不把 AI 决策注入按键——人工驾驶 + 模型辅助提示** |
| `forceRuleMode` | false | **紧急切纯规则：开启后降级状态机强制停在纯规则兜底档（档4），且 M9 端到端推理停跑（省资源）** |
| `agentMode` | false | **AI Agent 模式：开启后显示更多游戏键位，支持模型直接操作** |
| `enableNetworkLocate` | **true** | 网络定位开关（**默认 true 且「网络定位常开、不提供关闭入口」，保留字段仅为兼容**） |
| `trainingLog` | "" | 训练按钮状态/日志（UI 展示：启动中/完成/失败原因） |

**引擎模式字段：**

| 成员 | 说明 |
|---|---|
| `remoteDetections: [Detection]` | **引擎回传的检测结果（引擎模式下每 tick 刷新）** |
| `engineModeActive` | 引擎模式是否激活（镜像自 `EngineClient`，供 UI 观察刷新） |
| `engineConnected` | 引擎心跳是否正常（false = 失联，UI 显示告警） |
| `remoteSpeedKmh: Double`（默认 -1） | **引擎回传的车速表读数——引擎模式下本地 `speedOCR` 不跑，用它顶上** |
| `lastDriveCommandTime`（@ObservationIgnored） | **最后一次「开始/停止」命令时间：引擎状态回同步的 1 秒宽限期，防切换瞬间 UI 闪烁** |
| `effectiveDetections`（计算属性） | **决策层统一检测结果读取点：`egoBoxFilter.filter(displayDetections)`**——在 `displayDetections` 之上套一层 `EgoBoxFilter` 剔除自车框。⚠️ **2026-10-19 订正**：旧文写「UI 统一读取点：`EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`」已不符现码——该式子是 `displayDetections` 的算法；`effectiveDetections` 语义已收窄为**决策层专用**（UI 画框走 `displayDetections`，两条链路已分家）。`.rule` 纯规则档亦已改为吃本属性 |

**BPF/Daemon 字段**：`bpfAuthorized`（启动时检测 BPF 权限）/ `showBPFPasswordSheet` / `bpfInstallMessage` / `bpfInstalling`；
`daemonInstalled` / `showDaemonInstallSheet` / `daemonInstallMessage` / `daemonInstalling` / `isDaemonMode`——**Daemon 系统服务相关字段**。

**网络定位字段**：`networkLocateX/Y/Score/Mode/Pitch/Heading`（六件套，UI 小地图显示用；`locateGameOffline` 计算属性）。

## 二、定位器字段与 runNetworkLocateStep / dlog 10MB 封顶

**定位器字段**（`lastNetworkLocPos` / `healerInitLock` / `locateCtx`；从外置盘移植，`MinimapLocatorView` 需要）：
`locatorFound/X/Y/Score/Heading`（五件套）+ `locatorTarget: (x: Double, y: Double)?`（传送目标）+
`lastNetworkLocPos`（@ObservationIgnored，上次定位位置——朝向反推基线）+ `healerInitLock`（os_unfair_lock，懒初始化锁）+
`coordinateCapture: CoordinateCapture?`（@ObservationIgnored，网络坐标抓取器）+ `locateCtx`/`locateGate`（LocateContext/LocateGate）。

**`mapPath`（lazy 闭包）**——底图路径解析（**用可执行文件所在目录找地图，不用 `currentDirectoryPath`（那是 Home 目录）**）：

- 四候选：`execDir/models/bigworldmap-13056.jpg`（首选）/ `execDir/models/bigworldmapSecond.png` / 硬编码绝对路径 / 旧图 png
- 全败返回**最后一个候选**（"返回最后一个作为默认，让错误信息有意义"——错误信息里能看到路径）

**`setLocatorTarget(x:y:)`**：设置传送目标（`locatorTarget`）。

**`heading(from:to:)`（static）**：两点间朝向——`atan2(dy, dx) × 180/π`，负值 +360 归一到 [0, 360)。

**`runNetworkLocateStep()`**——网络定位步（**懒初始化 `CoordinateCapture`（纯网络定位，无自愈引擎）**）：

1. **懒初始化**：`coordinateCapture == nil` 时——`os_unfair_lock_lock(&healerInitLock)` + `defer` 解锁 + **双检**（锁内再判 nil，防并发重复初始化）→ `cc.start()`（libpcap 起抓包）→ `pcapLog("[NETWORK-LOCATE] cc.start()返回=…")` 记录成败 → `locateCtx.networkReady = true`
2. `guard let cc, locateCtx.networkReady`——未就绪 → 主线程 `networkLocateScore = 0` + `mode = "not_ready"` → return
3. **★ G 第 4 批（2026-10-04）：三级新鲜度取代旧 `cc.read(maxAge:)`**——`let tierRead = cc.readWithTier()`，分 live（≤18s）/ recent（≤40s）/ stale（≤90s）/ lost 四档（注释：UI 显示/决策层/控制层三列态度）；`locatorScoreForTier` 映射分数（live=1.0，其余低于 0.4 决策门槛），**只有 live 档允许驱动驾驶**。有数据时 `worldToMapPixel(pose)` 换算 + 主线程异步更新 `networkLocate` 六件套 + `locator` 五件套（**双份字段同步**——`MinimapLocatorView` 读 locator、大地图读 networkLocate）。
4. **游戏未运行**：`!cc.hasRecentTraffic(window: trafficFreshWindow=12s)`（突发式包流，旧 3s 窗口会在静默间隙误报）→ `networkLocateMode = "game_not_running"` + **清 `locatorFound`/`locatorScore`**（不保留旧坐标，防界面显示"假跳"定位）；未就绪 → `"not_ready"`。

**`networkLocateLastUpdate`**：上次定位更新时间（默认 `.distantPast`）。

**三个时间戳**：`drivingStartTime`（**本次开车会话开始时间——暖机期判定：启动后头几秒还没出推理结果时保持高置信度，避免启动瞬间误降级**）、`lastTickLog`（tick 摘要 1Hz 节流）、`lastUpscaleLiveLog`（插帧状态更新节流 1Hz）。

**`dlog(_ msg: String)`（private；10MB 封顶语义已迁入 `LogSink` 但格式/封顶/回退链不变）**——调试日志：
**stdout + `/tmp/aurora_debug.log`（App 启动时清空）**；"用户从终端启动可实时看到；事后我读文件定位运行时问题"。

- **P1 修复**：**dlog 每秒追加，7×24 运行日志无限增长。写前检查大小，超 10MB 直接覆盖重写（truncate，atomic 写），只保留最近日志，封顶磁盘占用**
- 追加写：`seekToEndOfFile` + write（`FileHandle`）；文件不存在 createFile 等价路径（`data.write`）


## 三、isRecording didSet 与引擎模式回声防环

**`var isRecording = false { didSet ... }`**——行驶录制开关（didSet 触发 `RecordEngine` 启停 + 画面流/键盘监听接管）：

- true → 开始录制会话；**未在驾驶时由录制器负责拉起截屏画面流与键盘监听（否则不开车就开录制器会录出空目录）**
- false → 写 meta.json 并关闭；**驾驶仍开着时不关画面流/键盘监听（驾驶还在用）**

**⚠️ 引擎模式回声防环（实现与注释）**：

- **"帧只存在于引擎进程（UI 没有画面流），录制必须由引擎执行，这里只把开关转发过去。早先在引擎模式下仍然本地 `recordEngine.start()`，结果是「目录建了、文件建了，但录不进任何东西」——因为 UI 的 `tick()` 在引擎模式下提前 return，`recordFrameIfNeeded()` 永远不执行"**
- `guard isRecording != oldValue`（值未变不动）+ **`guard !applyingRemoteRecord else { return }`——来自引擎回同步，别回声**
- **引擎模式分支**：`EngineClient.shared.isActive` 时——`lastRecordCommandTime = Date()`（**宽限期起点**）+ `sendCommand("record", extra: ["on": isRecording, "glyph": glyphMode, "expert": expertMode, "perspective": recordPerspective])` → return——**只转发，不本地执行**；并置 `lastSentKeyMask = -1`（保证下一 tick 必发掩码）+ 按 `isRecording` / `isDriving` 启停 `keyboardMonitor`

**本地模式分支**：

- 开始：**每次开始录制前同步字模模式开关**（"录制中切换 glyphMode 不影响本次会话（语义为「录制中切换不生效，需重启录制」），故不做实时热切换"）：`recordEngine.glyphMode = glyphMode` + `recordEngine.expertMode = expertMode` + `recordEngine.start(perspective: recordPerspective)` + **`if !captureEngine.isCapturing { captureEngine.start() }`**（画面流没跑才拉起）+ `keyboardMonitor.start()`
- 停止：`recordEngine.stop()` + **`if !isDriving && !isOnlineTraining && shellModeActive` 之外的条件下 `captureEngine.stop(); keyboardMonitor.stop()`**（驾驶/在线训练/壳模式还在用时都不关画面流）

**配套状态：**

| 成员 | 说明 |
|---|---|
| `applyingRemoteRecord`（@ObservationIgnored） | **防回环标记：`tickEngineMode()` 把引擎录制状态镜像到 `isRecording` 时置位，避免 didSet 又把「record」命令回声给引擎** |
| `lastRecordCommandTime`（@ObservationIgnored） | **最后一次向引擎发送「record」命令的时间。心跳周期 1s，命令刚发出时引擎还没来得及上报，若不设宽限期，UI 会在下一次 tick 立刻把 `isRecording` 弹回旧值 → 开关按下即回弹** |
| `engineVersionWarning` | **引擎协议版本不匹配时的用户可见告警（空 = 无告警）** |

**驾驶核心字段：**

| 成员 | 说明 |
|---|---|
| `mode: DriveMode`（默认 .e2e） | **当前驾驶模式（由降级状态机计算，每帧 tick 同步）——UI 观察此属性刷新模式芯片高亮** |
| `confidence`（默认 0.92） | 置信度 0~1 |
| `lastDecided`（private，默认 .e2e） | **上一帧状态机决策档位。⚠️ 2026-09-30 起 `.recover` 已删——现在仅作诊断留档，先比后写（不再做边沿检测）** |
| `effectiveSpeed`（默认 0） | **有效车速（km/h）：每帧由 OCR 新鲜读数（EMA 平滑）或一阶滤波回退计算——供 M9 vehicle_state、卡死判据、脱困退出使用** |
| `speedValid` | **有效车速是否新鲜（OCR 读数新鲜：`lastResultTime < 0.5s` 且 `confidence > 0.3`）——不新鲜时卡死判据不计入 `stuckSeconds`** |
| `speed`（计算属性） | **兼容属性：旧代码读 `speed` 的地方统一读到 `effectiveSpeed`** |

**显示与 OCR 字段：**

| 成员 | 说明 |
|---|---|
| `fps`（默认 60） | 标称帧率 |
| `speedKmh`（计算属性） | **车速 OCR 最新快照：`EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh`**——读自 `speedOCR`（@Observable 嵌套） |
| `speedConfidence`（计算属性） | `speedOCR.confidence` |
| `m9Status`（计算属性） | **M9 推理链路状态**——`M9未加载`（`!isLoaded`）/ `M9活跃`（**模型已加载 && 最近 1s 内出过推理结果**）/ `M9失联`（**结果超过 1s 没更新**） |
| `speedLimit`（默认 120） | 速度上限——**不是显示项，经 `InferenceEngine` 变成 `vehicle_state[4]` 参与推理** |
| `degradeThreshold`（默认 0.65） | 降级阈值（同步给状态机，UI 可调） |
| `modelVersion` / `frames` | "v2.4.1-e2e-fsd" / 128_402（**装饰性展示值**） |

## 四、跳帧防堆积与诊断尺子

**画面流与显示字段：**

| 成员 | 说明 |
|---|---|
| `currentScreenImage: NSImage?`（**@ObservationIgnored**） | 由 `CaptureEngine` 的 onFrame 闭包更新，仍是录制/现有引用的数据源 |
| `currentFrameCG: CGImage?`（@ObservationIgnored） | **同源（同一回调直传的 CGImage），供推屏/推理/置信度使用，省 NSImage→CGImage 重复转换** |
| `frameHost = FrameHost()` | **UI 显示已改走 `frameHost` 直绘（绕开 SwiftUI diff）**，故两者均标 @ObservationIgnored |
| `screenSize: CGSize?`（普通 @Observable） | **源画面尺寸——驱动 `ObstacleOverlay` 的 aspect-fill 对齐**。注释："**不能从 @ObservationIgnored 的 `frameHost.latestSize` 读，否则尺寸变化不触发观察导致检测框错位；仅在尺寸变化时写，避免每帧失效**" |
| `isStreaming`（普通 @Observable） | **控制 `GameViewportView` 显示"实时画面 vs 黑底提示"分支**——必须保持 @Observable，否则停止后分支不触发重绘导致画面冻结 |

**插帧/超分字段**：

- `upscaleHost = UpscaleFrameHost()`（@ObservationIgnored）——插帧帧宿主
- `upscaleEnabled: Bool = false` / `upscaleSupported` / `upscaleLive: String?` / `upscaleEngineError: String?`——插帧状态四件套
- **仅显示路径，绝不进入决策链路**——插帧是给"人眼看得更顺"的，YOLO/OCR/E2E 走各自直通路径
- **`gameModeBoost: Bool = true { didSet ... }`**——游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权）：值变化时 `applyMainThreadBoost(gameModeBoost)`（见 代码-24 单元三）+ **启用时 `startAntiFreeze()` 加强心跳防冻结 / 关闭时 `stopAntiFreeze()`**

**跳帧防堆积（用户拍板方案）：**

- **设计（注释原文）**："onFrame 在 captureQueue 线程只「**覆盖**」最新一帧（**不 main.async 排队**）；tick 主线程每帧取最新一帧给 UI——主线程处理不过来时**旧帧被覆盖丢弃，永不堆积（= 强制同步跳帧）**。捕获/推理频率不变"
- **`pendingFrame / pendingFrameCG / pendingFrameTime`（nonisolated(unsafe) private）** + `pendingFrameLock = NSLock()`——覆盖式最新帧三件套 + 锁
- **`pendingYoloFrame: CVPixelBuffer?` + `pendingYoloLock`**——**YOLO 直通帧跳帧（同 `pendingFrame` 模式）：captureQueue 覆盖最新帧，tick 消费**
- **`pendingNativeFrame: CVPixelBuffer?` + `pendingNativeLock`**——**原生 ROI 帧跳帧（同模式）：OCR/字模录制消费**
- 三组跳帧缓冲全部 `nonisolated(unsafe)` + NSLock——**跨线程覆盖写/读的统一模式**

**诊断字段：**

| 成员 | 说明 |
|---|---|
| `frameDeliveryLagMs`（nonisolated(unsafe)） | **onFrame 帧从入队到主线程执行的延迟(ms)——验证"越到后面越卡=积压"**（旧架构的诊断尺子，跳帧方案后应恒定） |
| `tickGapMs`（nonisolated(unsafe)） | **主线程 tick 实际间隔(ms)（>33ms = 主线程掉拍/被卡）** |
| `antiFreezeTimer`（private @ObservationIgnored） | **防冻结心跳定时器（游戏模式下强制唤醒主线程）** |
| `processMemoryMB() -> Double` | **进程物理内存占用（MB）——诊断用：积压 → 内存随时间线性上涨的验证指标**：`task_info(MACH_TASK_BASIC_INFO)` → `resident_size / 1024 / 1024`；KERN_SUCCESS 才返回，否则 0 |

**引擎实例字段：**

| 成员 | 说明 |
|---|---|
| `captureEngine = CaptureEngine()`（let） | **截屏引擎实例（启动时创建，全屏画面流）——`isDriving` 启动时 `start()`，停止时 `stop()`** |
| `gameHUD = GameHUDWindow()`（let） | **游戏画面左上角帧率 HUD**——兼作对抗 Game Mode 的"可见窗口"（见 `GameHUDWindow.swift` 头注释） |
| `capturePermissionDenied` | 截屏权限状态（首次启动若未授权，引导用户到系统设置） |
| `controlEngine = ControlEngine()`（let） | **按键注入引擎（CGEvent 控制 WASD/空格/Shift）——启动时检查辅助功能权限，停止时释放所有按住的键** |
| `controlPermissionDenied` | 辅助功能权限状态 |
| `keyboardMonitor = KeyboardMonitor()`（let） | **物理键盘监听——`controlEngine` = AI 注入的按键（输出）；`keyboardMonitor` = 用户物理按下的键（输入，录制专家演示）** |
| `degradeStm = DegradeStateMachine()`（let） | **降级状态机（四态 + 极速覆盖 + 卡住检测）——`tick()` 每帧调用 `update()`，结果同步到 `self.mode`** |
| `recordEngine = RecordEngine()`（let） | **行驶录制引擎——`isRecording` didSet 触发启停，`tick()` 每帧调用 `appendFrame`** |


## 五、三段胶水、startDriving / stopDriving

**旧网络定位已移除**：`NetworkPacketCapture` 已移除（不编译），**使用移植的 `NetworkLocator`**。

**三段胶水代码（接模型输出 → 状态机 → 按键注入）：**

| 实例 | 说明 |
|---|---|
| ~~`escapeController`~~ | **已删除（2026-09-30，脱困档整体移除）** |
| `ruleController = RuleController()` | **`.yolo`/`.rule` 态 YOLO 检测→控制量规则** |
| `confidenceEst = ConfidenceEstimator()` | **E2E 无置信度头，用启发式从输出/画面估算** |
| `inferenceEngine = InferenceEngine()` | **CoreML E2E 推理引擎（m9_mono）——`tick()` 异步触发推理，读 `lastResult` 作为本帧 E2E 输出** |
| `inferenceEngineV2 = InferenceEngineV2(modelFileName: "m9_v2")` / `inferenceEngineV3 = InferenceEngineV3()` | 新增的第二/第三代推理引擎 |
| `assistEngine = InferenceEngine(modelFileName: "game_assist_control")` | **第二套驾驶模型（YOLO 接管档的司机）——与 M9 同架构，独立权重文件** |
| `yoloEngine = YoloEngine()` | **CoreML YOLO 检测引擎——`tick()` 异步触发**。⚠️ **2026-10-19 订正**：旧文写「检测结果同时喂 `RuleController` 决策 + UI 画框」**已不同源**——现码 `RuleController` 只吃 `effectiveDetections`（`egoBoxFilter.filter(displayDetections)`），UI 画框走 `state.displayDetections`，两条链路已分家。另：A 模型档（默认档）下本引擎**不加载、不推理** |
| `speedOCR = SpeedOCRReader()` | **车速表 OCR 读取引擎——`CaptureEngine` 原生帧 → 后台 OCR 读车速 → 主线程读 `speedKmh`/`speedConfidence`** |
| `currentCommand: ControlCommand = .idle`（private(set)） | **本帧最终决策命令（`tick()` 末尾写出，供按键注入用）** |

**`init()`——接线与 HUD 安装：**

1. `try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")`——**每次启动清空调试日志**
2. **帧率 HUD 接线**：`gameHUD.fpsProvider = { (assist, game) }`——**辅助帧率 = 主线程 tick 速率（`1000/tickGapMs`）；游戏帧率 = ScreenCaptureKit 实际捕获到的合成帧率**
3. **★ 仅 UI 进程安装**：`if !CommandLine.arguments.contains("--engine") { gameHUD.install() }`——**引擎进程（`--engine`）也创建 `DriveState`，但它没有 NSApplication UI 上下文，在其中创建 NSWindow 会触发 AppKit 断言崩溃（实测「就绪」后 1ms 即崩）**
4. **onFrame 接线——跳帧防堆积**：captureQueue 后台线程**只"覆盖"最新待显示帧（加锁），不再 main.async 排队**——"主线程（tick）卡时，旧帧被下一帧覆盖丢弃 → 天然跳帧，永不积压"；**NSImage + CGImage 同回调原子写入**
5. **onYoloFrame 接线**：`CaptureEngine` 源头缩放好的缓冲**直接喂推理引擎（跳过 NSImage/CGImage 大图转换 → 检测帧率↑）**——跳帧覆盖式
6. **onNativeFrame 接线**：**P1-2：字模录制复用同一条原生 ROI 直通（speedROINorm 与 glyphROI 同区域），直接把原生缓冲交给 `RecordEngine` 存字模 PNG**
7. **onUpscaleFrame 接线**：全分辨率帧 → `upscaleHost.push`（**仅显示路径**）
8. **onStatusChange 接线**：`permissionDenied` → `capturePermissionDenied=true`；`started` → false + `isStreaming=true`；`stopped`/`error` → `isStreaming=false` + **`frameHost.clear()`** + **三组 pending 帧全部清空（三把锁逐个清）——"清残留 pending 帧，避免停止后下一 tick 消费旧帧再 push（重启闪旧帧）"**
9. `upscaleHost.prepare()` + `upscaleSupported = isAvailable` + dlog
10. **`EngineClient.onActivated` 接线**：**引擎（重新）连上时把 UI 当前的画面档位同步给引擎——否则引擎默认发 480 宽缩略帧，UI 开着插帧就会一直等不到全分辨率帧**：`setUpscale(upscaleEnabled && upscaleSupported)` + `sendCommand("status")`
11. 旧网络定位回调已移除 + dlog

**`startDriving()`——启动自动驾驶，引擎模式分支：**

- **引擎模式**：`EngineClient.shared.isActive` 时——`sendCommand("start")` + `lastDriveCommandTime` + `isDriving=true` + `drivingStartTime` → **return（UI 不启动本地抓屏/推理/按键）**
- **本地模式**：
  1. `guard controlEngine.checkPermission()`——无权限 → `controlPermissionDenied=true` + 引导授权 + return
  2. **开始驾驶前清掉系统里残留的卡键**："上次进程异常退出可能留下未释放的 W/A/S/D，污染游戏输入；`releaseAll` 无条件清理"
  3. `isDriving=true` + `drivingStartTime` + `keyboardMonitor.start()` + `captureEngine.start()`
  4. **三模型 `loadIfNeeded`（M9 / `assistEngine` / `yoloEngine`）**——**首次启动加载**
  5. dlog 启动状态

**`stopDriving()`——停止自动驾驶：**

- **引擎模式**：`sendCommand("stop")` + `lastDriveCommandTime` + `isDriving=false` → return（**引擎侧释放按键并停止抓屏**）
- **本地模式**：`isDriving=false` → `controlEngine.releaseAll()`（**1. 释放所有按住的键**）→ `keyboardMonitor.stop()` → `captureEngine.stop()` → **重置链**：`degradeStm.reset()` + `confidenceEst.reset()` + `inferenceEngine.reset()` + `inferenceEngineV2.reset()` + `assistEngine.reset()` + `yoloEngine.reset()` + `speedOCR.reset()`（**`escapeController.reset` 已随脱困删除**）→ `currentCommand = .idle` → **`if isRecording { isRecording = false }`**

## 六、档位开关 / 防冻结禁用 / 一键训练与模型热部署

**`setUpscaleEnabled(_ on: Bool)`**——插帧/超分开关：

1. `upscaleEnabled = on` + `captureEngine.upscaleEnabled = on`（采集侧同步）
2. **引擎模式**：**通知后台引擎切画面档位（全分辨率 ↔ 480 宽缩略），否则引擎不知道 UI 开没开插帧，会一直发缩略帧导致插帧没数据**——`EngineClient.shared.setUpscale(on)`
3. dlog 开关状态

**`setGameModeBoost(_ on: Bool)`**——游戏模式兼容开关：

1. `gameModeBoost = on`（didSet 会触发 `applyMainThreadBoost`）+ `captureEngine.gameModeBoostEnabled = on` + `applyMainThreadBoost(on)`
2. **开启时**：`startAntiFreeze()` + **检查是否已安装 daemon，未安装则弹出安装引导**——`DaemonSetupManager.needsInstall()` → 延迟 0.5s 弹出（**避免与启动时的弹窗冲突**）`showDaemonInstallSheet = true`
3. 关闭时：`stopAntiFreeze()`

**防冻结心跳已禁用（诚实标注）：**

- **`startAntiFreeze()`——已禁用，不再启动心跳**——源注释："**原因：每 100ms 发送键盘事件导致系统崩溃，鼠标无法移动**"——只 dlog"[antifreeze] 心跳已禁用（避免系统崩溃）"
- `stopAntiFreeze()`：`antiFreezeTimer` cancel + nil（残留清理保留）

**`startTraining()`（@MainActor）——一键训练（拉起 Python 训练进程）**：

- **注释**："拉起 python3.11 训练脚本（**只训控制模型**）：`--skip_view`（视角分类器按决策删除不做，不训练）+ `--skip_yolo`（YOLO 用现成预训练 CoreML，无需重训）。**训练完成后自动把新控制模型热替换进推理引擎（点完即用）**。进程后台运行，UI 按钮文字切到「训练中…」，结束经 `terminationHandler` 回主线程"

1. `guard !isTraining` → `isTraining=true` + `trainingLog="启动训练进程…"`
2. **Process 组装**：`/usr/local/bin/python3.11` + `["src/train_game_assist.py", "--skip_view", "--skip_yolo"]` + currentDirectoryURL 硬编码项目根 + **输出重定向到 `train.log`（standardOutput + standardError 同一 FileHandle——"避免管道缓冲区满导致训练进程挂起"）**
3. **`terminationHandler`**：主线程——`isTraining=false` → 成功（退出码 0）：`trainingLog="训练完成，应用新模型…"` → `deployTrainedModel()` 成功才 `clearRawClips()`；失败："训练失败（退出码 N），详见 train.log"
4. `try proc.run()`；失败 `isTraining=false` + "无法启动训练"

**`deployTrainedModel() -> Bool`（@discardableResult）——把训练产出的控制模型复制到 m9_mono 并热替换：**

- **注释**："**优先 FPV 专用模型（当前录制为 FPV 视角），回退 TPV/FPV 共用模型**。扩展名跟随源：若 coremlcompiler 缺失，coremltools 仍会 save 出 .mlpackage，**CoreML 运行时可直接加载未编译的 .mlpackage，链路照样闭环**"

1. **四候选**：`game_assist_control_fpv.mlmodelc` / `game_assist_control.mlmodelc` / `game_assist_control_fpv.mlpackage` / `game_assist_control.mlpackage`——第一个存在的入选；全无 → "未找到训练产出的控制模型，请检查 train.log" + false
2. **清理旧模型**：**清理另一扩展名的旧模型，避免 `InferenceEngine.modelURL` 误选**
3. `copyItem(at: src, to: dst)`——dst = `m9_mono.{src扩展名}`
4. **引擎模式分支**："**模型文件已落盘；但真正开车的推理引擎可能不在本进程：引擎模式 → 命令引擎重新加载（否则引擎一直用内存里的旧模型）；本地模式 → 直接置空本进程的三个引擎**"——引擎模式：`sendCommand("reloadmodel")` + `inferenceEngine.reloadModel()` + `trainingLog`"已应用新模型（引擎侧已通知重载）"；本地模式：**三引擎全部 `reloadModel()`**
5. 失败 → "模型部署失败"

**`clearRawClips()`——训练成功且模型部署后，清理 `data/raw_clips` 下所有录制 clip：**

- **注释**："录制数据仅用于训练，**训完即弃**，避免无限累积、下次训练重复读取旧数据。**仅在部署成功时调用；失败保留数据以便排查**"
- 列目录 → `clip_` 前缀逐个 `removeItem` → `trainingLog`"已应用新模型，并清理 N 段录制数据"；失败 → "模型已应用，但清理录制数据失败"

## 七、tickEngineMode 回声防环与 pushEngineConfigIfChanged

**`tickEngineMode()`（@MainActor）**——引擎模式下每 tick 拉取显示数据（**本地抓屏/推理/按键全部不跑**）：

1. `let client = EngineClient.shared` + `guard client.isActive else { return }`
2. **消费最新待显示帧**：`client.poll() -> CGImage?`；非 nil 时 `currentScreenImage = image` + `currentFrameCG = cg`（**仅主线程**）+ **帧宿主直绘** + `isStreaming = true`
   - **CVPixelBuffer 分支**：`upscaleHost.push(pixelBuffer: pb)` + `isStreaming` + **源尺寸必须随帧更新（不能只在 nil 时设一次）**——"检测框叠加、框选手势的坐标换算都以 `screenSize` 为基准，尺寸变了却不更新 → 框错位、框选选不中"
   - CGImage 分支：同构 + `frameHost.push`
3. **引擎已停止抓屏同步收尾**：`!client.engineIsStreaming && isStreaming` → `isStreaming=false` + `upscaleLive=nil` + **`upscaleHost.clear()` + `frameHost.clear()`**——"**否则 `isStreaming` 会一直停在 true（引擎模式下只在有帧时被置 true，从不复位），导致插帧视图继续挂着、徽章一直显示'插帧中'**"
4. **协议版本守卫——必须放在状态镜像之前**：
   - `client.isEngineStale` 且 `!isDriving && !client.engineRelaunching` → `engineRelaunching = true` + `engineVersionWarning`"检测到旧版引擎，正在重启…" + **`client.relaunchStaleEngine()`**
   - 驾驶中或重启中 → `engineVersionWarning`"⚠️ 引擎版本不匹配，停止驾驶后自动重启"
   - **`engineRelaunching` 由 `EngineClient` 持有并在重启完成后清除——不能用 UI 局部标志，否则重启流程中途 `isEngineStale` 仍为真时会无限重复触发**
   - 无错配时清空警告
5. **驾驶状态回传落位**：**引擎模式下 UI 不跑推理，面板/状态栏依赖的驾驶状态由引擎心跳回传后落到这里——档位、车速（含车速表读数）、置信度、有效车速**——`mode`/`confidence`/`remoteSpeedKmh`/`effectiveSpeed` 逐个 `if !=` 才写（**逐帧无条件赋值也会触发 SwiftUI 刷新 → 只在变化时写**）；`speedValid = engineSpeedKmh >= 0 && engineSpeed > 0.5`
6. **锁定目标追踪**：`yoloEngine.trackLockFromRemote(client.engineDetections)`——**引擎模式下必须用引擎回传的检测框推进，否则锁定框冻在原地不动**
7. **`isDriving` 回同步**：**引擎是状态权威源；命令发出后 1 秒内保留 UI 乐观值，避免切换瞬间闪烁**——`Date().timeIntervalSince(lastDriveCommandTime) > 1.0` 时才镜像
8. **录制状态回同步**：**引擎是权威源：引擎进程真正写盘，UI 只显示帧数。置 `applyingRemoteRecord` 防回环；宽限期 2 秒**；`frames` 镜像
9. `pushEngineConfigIfChanged()`——**驾驶参数下发（极速/禁用控制/紧急切规则/专家/字模/降级阈值）——这些只在 `tick()` 里被读，而引擎模式下 `tick()` 跑在引擎进程——必须显式推送。只在变化时发**
10. **插帧实时统计**：useUpscale 时 `upscaleLive` 字符串（"产出 N · 透传 N · 输入 Nfps → 输出 Nfps"）

**`pushEngineConfigIfChanged()`（private）**：

- **快照对比**：`snap = "\(sportMode)|\(controlDisabled)|\(forceRuleMode)|\(expertMode)|\(glyphMode)|\(degradeThreshold %.3f)|\(speedLimit %.1f)"` → `guard snap != lastPushedEngineConfig`（变化检测，`lastPushedEngineConfig` 默认 ""）
- `sendCommand("config", extra: [...])` 七参数——**"速度上限直接进 `vehicle_state[4]`，不是显示项"**

## 八、tick() 主循环——完整决策管线

**`tick()`**——每帧推进，**完整决策管线：跳帧消费 → quest OCR → 速度/卡死 → 降级决策 → 按态输出 → 注入 → 录制**。

**① 诊断 + 引擎分流**：`tickGapMs`（实际间隔，>33ms = 主线程掉拍）；`if EngineClient.shared.isActive { tickEngineMode(); return }`（**本地抓屏/推理/按键全部不跑**）。

**② 消费跳帧缓冲**：锁内取 `pendingFrame`/`pendingFrameCG`/`pendingFrameTime` → `frameDeliveryLagMs` → `currentScreenImage`/`currentFrameCG` 赋值 → `frameHost.push(cg)`（`isStreaming` 时）→ `screenSize` 更新。

**②.6 原生 ROI 帧消费**：取最新 `pendingNativeFrame` → `speedOCR.infer(nativePixelBuffer:)` + 字模录制（`recordEngine.glyphMode && isRecording` 时 `appendGlyphNative` + `frames` 同步）。

**②.5 任务面板 OCR**：门 `AuroraFlags.questOCR`（默认 true）——`if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`；节流与在途保护在 `QuestPanelReader` 内部（0.7s 间隔 + `ocrInFlight`）。

**②.7 YOLO 直通帧 + 光流**：取最新 `pendingYoloFrame` → `yoloEngine.inferFast(pixelBuffer:)`；同一份直通帧喂 `runOpticalFlow`，受**两条闸门"与"关系**控制：`!Self.opticalFlowDisabled`（该静态属性仍直接下标读 `AURORA_DISABLE_OPTICAL_FLOW`，未走 `AuroraFlags`——全仓残留的一处直接读）+ `perceptionMode.needsOpticalFlow`（按档位门控：仅 `.legacy` 档跑光流）。

**③ 待机分支**：`guard isDriving else {` 内：`if speedValid { speedValid = false }` + `effectiveSpeed` 每帧 -6 衰减 + `currentCommand` 回 `.idle`——**全部先比后写**；`recordFrameIfNeeded()`（**待机也写帧：录制不依赖驾驶状态**）→ return。

**⑤ 有效车速**——OCR 新鲜 → EMA 追真实读数；否则一阶滤波回退：

- `ocrFresh = speedOCR.speedKmh >= 0 && confidence > 0.3 && lastResultTime < 0.5` → 先比后写 `speedValid`
- `ocrFresh` → `effectiveSpeed += (ocr - effectiveSpeed) × 0.7`（**快跟踪**）；否则 `× 0.9` 向 0 衰减（<0.5 归零）
- `fps` 如实反映捕获帧率，**不回退成 60 伪造**

**⑥ 卡死 → 请求人工介入**：`isDriving && speedValid && effectiveSpeed < 1.0` 持续 ≥ `stuckZeroThreshold`（读 `AURORA_STUCK_SECONDS`，默认 30s）→ `needsManualIntervention = true` 拉横幅。**只提示不动车——AI 绝不自行脱困**；零速判据要求 `speedValid` 为真，避免「OCR 读不到就误报卡死」；车动起来立即撤横幅清计时。

**⑥.5 降级状态机决策**：暖机期 `warmingUp = inferenceEngine.lastResult == nil && 开车 < 3.0s`；
`decided = degradeStm.update(m9Live:assistLive:health:warmingUp:speedKmh:speedValid:dt:sportMode:forceRule:)`
→ **先比后写** `if mode != decided { mode = decided }`。

**⑦ 置信度估计**：暖机期 `if confidence != 1.0 { confidence = 1.0 }`（先比后写）；否则 `confidenceEst.update(command:image:isLive:)`——喂**当前档位**驾驶模型的输出 + 画面。

**⑧ 按态输出控制量**：

```swift
switch decided {
case .e2e:  if currentCommand != m9Command { currentCommand = m9Command }         // 档1 M9 直接开车
case .yolo: if currentCommand != assistCommand { currentCommand = assistCommand } // 档2 第二套网开车
case .rule: let ruleCmd = ruleController.decide(detections: detections)           // 档3 手写规则最后防线
}                                                   // 全部先比后写
```

- `detections` 已经 `effectiveDetections`（`egoBoxFilter.filter(displayDetections)`）**剔除自车框**——只作用于决策层，UI 照画全部框。
- **`.recover` 档已删除**：脱困策略整体移除，`lastDecided` 仅作诊断留档、不再做边沿检测。

**⑧.5 车道保持 / 驾驶分段覆盖**：档位门 `if laneAssistAllowed && Self.laneKeepTiers.contains(decided)`（`laneKeepTiers` 默认 `rule,yolo`，`AURORA_LANEKEEP_TIERS=rule` 一键回退）→ `LaneFallback` 车道保持 + `segmentDecisionForRule(pose:)` 调用 `driveSegment.update(...)`：地图段/回正段的 `mapSteer` **覆盖**视觉转向、建议限速参与后续油门计算。

**⑨ 按键注入**：专家/禁用控制分支走节流版 `controlEngine.releaseAllIfNeeded()`（旧行为每帧无条件 `releaseAll()` 由回退开关 `AURORA_RELEASE_ALL_EVERY_TICK=1` 保留）；否则 `applyCommand(currentCommand)`（转向死区 ±0.1、油门/刹车互斥阈值 0.3、`refreshHeldKeys()` 每帧重发）。

**⑩ 录制 + 插帧状态 + 调试摘要**：`recordFrameIfNeeded()`（字模走原生路径防双写、专家模式录按键时长标签、默认录 AI 决策；键码 A=0/D=2/W=13/S=1/Space=49）；调试摘要 1Hz（写 `/tmp/aurora_debug.log`，mode/模型存活/命令/注入权限/front 前台应用/capGap/capWork/tickGap 等；插帧统计与分段打点导出共用同一 1Hz 闸门）。

## 九、recordFrameIfNeeded 与 applyCommand 按键映射

**`recordFrameIfNeeded()`（private）**——每帧录制写帧（画面 + 控制量），驾驶与待机共用：

1. **`guard !recordEngine.glyphMode else { return }`**——字模模式走 onNativeFrame 原生路径（`appendGlyphNative`），**此处跳过，避免 `appendFrame` 再写一遍缩略图造成双写**
2. `guard isRecording, let image = currentScreenImage`
3. **控制量来源二选一**：
   - **`expertMode`（专家模式）**：`RecordLabelMapper` 连续标签——`steer(leftHeld: keyboardMonitor.holdDuration(keyCode: 0), rightHeld: holdDuration(keyCode: 2))`、`throttle(wHeld: holdDuration(keyCode: 13))`、`brake(sHeld: holdDuration(keyCode: 1), spaceHeld: holdDuration(keyCode: 49))`——**标签语义：按键按住时长/满刻度时长 → 连续值（0~1，带符号）**
   - 否则（AI 决策）：`recSteer/Throttle/Brake = currentCommand` 三元组——**默认录 AI 决策（供 DAgger 自训练）**
4. `recordEngine.appendFrame(image:steer:throttle:brake:)` + `frames = recordEngine.frameCount`

**键码对照**：**与 `ControlEngine` 注入一致：A=0 左 / D=2 右 / W=13 油门 / S=1 刹车 / Space=49 手刹**（macOS virtualKey 体系）。

**`applyCommand(_ cmd: ControlCommand)`（private）**——把 `ControlCommand` 映射到按键注入（**`steer>0` 右转，`<0` 左转；`throttle` 油门；`brake` 刹车/倒车**）：

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
- **油门/刹车互斥**（阈值 0.3）：不能同时按 W 和 S——`throttle` 优先
- **`refreshHeldKeys()` 必须每帧调用**：**持续按住的键按控制周期重发按下事件（等价真实键盘 auto-repeat）。缺了这一步，控制量稳定时整段驾驶只会产生一个 keyDown，游戏收不到任何后续事件——表现为「UI 显示按住、车不动」**

**DriveState 状态主体文档至此完整**（`RecordLabelMapper` → 开关字段 → `isRecording` didSet → 跳帧防堆积 → `startDriving`/`stopDriving` → 一键训练热部署 → `tickEngineMode` → `tick()` 决策管线 → 录制与按键映射）。


## 十、AuroraFlags.swift 全部开关清单（Core/AuroraFlags.swift）

`AuroraFlags` 是环境开关的**唯一事实源**，读取收敛到唯一入口 `raw()`；布尔语义「只有 `"1"` 算开」，反向布尔「只有 `"0"` 算关」。全表 `all`，`--flags-help` 由 `helpText()` 打印。

唯一例外：`egoCheck` **刻意不 static let 化**，每次现读（因 `AuroraDriveApp.swift` 的自检会在运行时 `setenv("AURORA_EGO_CHECK","off",1)` / `unsetenv`；佐证 `EgoMotionModel.swift`）。

> ⚠️ **已发现的源码内不一致（文档如实记录，未改产品代码）**：`all` 表中 `AURORA_QUEST_OCR` 条目仍写 `defaultValue: "0"`、"默认关"，与实际声明 `questOCR = bool("AURORA_QUEST_OCR", default: true)`（2026-10-06 改默认开）**自相矛盾**——`--flags-help` 会打印错误的默认值。

### A. 运行模式 / 进程

| 属性 | env | 默认 |
|---|---|---|
| `uiLocal` | `AURORA_UI_LOCAL` | false |
| `daemonMode` | `AURORA_DAEMON_MODE` | false |
| `observeOnly` | `AURORA_OBSERVE_ONLY` | false |
| `tccTest` | `AURORA_TCC_TEST` | (未设) |
| `apiKey` | `AURORA_API_KEY` | (未设) |

### B. 引擎 / IPC / 网络

| 属性 | env | 默认 |
|---|---|---|
| `engineDiagSkipTCC` | `AURORA_ENGINE_DIAG_SKIP_TCC` | false |
| `engineDiagCaptureOnly` | `AURORA_ENGINE_DIAG_CAPTURE_ONLY` | false |
| `legacyProto` | `AURORA_LEGACY_PROTO` | false |
| `nicTestTarget` | `AURORA_NIC_TEST_TARGET` | "49.232.46.87" |

### C. 推理 / 感知

| 属性 | env | 默认 |
|---|---|---|
| `ayolom` | `AURORA_AYOLOM` | (未设→A-YOLOM) |
| `inferQoS` | `AURORA_INFER_QOS` | (未设) |
| `yolopxIntervalMs` | `AURORA_YOLOPX_INTERVAL_MS` | 0 |
| `yolopxLetterboxMain` | `AURORA_YOLOPX_LETTERBOX_MAIN` | false |
| `skipModelLoad` | `AURORA_SKIP_MODEL_LOAD` | false |
| `ocrDebug` | `AURORA_OCR_DEBUG` | false |
| **`questOCR`** | **`AURORA_QUEST_OCR`** | **true**（2026-10-06 改默认开） |

### D. 光流 / 自车运动

| 属性 | env | 默认 |
|---|---|---|
| `disableOpticalFlow` | `AURORA_DISABLE_OPTICAL_FLOW` | false |
| `egoArea` | `AURORA_EGO_AREA` | 0.04（含 `isFinite`/非负校验） |
| **`egoCheck`** | `AURORA_EGO_CHECK` | (未设=开，**每次现读**) |
| `egoMaxFwd` | `AURORA_EGO_MAX_FWD` | 0.5 |
| `egoMaxFlowPx` | `AURORA_EGO_MAX_FLOW_PX` | 80.0 |
| `egoResidualRatio` | `AURORA_EGO_RESIDUAL_RATIO` | 0.6 |
| `egoMinConf` | `AURORA_EGO_MIN_CONF` | 0.35 |
| `egoDiag` | `AURORA_EGO_DIAG` | false |
| `keyRefreshHz` | `AURORA_KEY_REFRESH_HZ` | 0（有效 (0,60]，越界回 0） |

### E. 驾驶 / 控制

| 属性 | env | 默认 |
|---|---|---|
| `laneKeepTiers` | `AURORA_LANEKEEP_TIERS` | (未设→`rule,yolo`，解析在 `AuroraDriveApp.swift` 中) |
| `releaseAllEveryTick` | `AURORA_RELEASE_ALL_EVERY_TICK` | false |
| `stuckSeconds` | `AURORA_STUCK_SECONDS` | 30 |
| `enableBgDrift` | `AURORA_ENABLE_BG_DRIFT` | false |
| `segStraightenDeg` | `AURORA_SEG_STRAIGHTEN_DEG` | 15.0 |
| `segStraightenDoneDeg` | `AURORA_SEG_STRAIGHTEN_DONE_DEG` | 8.0 |
| `segHandoverM` | `AURORA_SEG_HANDOVER_M` | 15.0 |
| `segHandoverFrames` | `AURORA_SEG_HANDOVER_FRAMES` | 10 |
| `segCorridorM` | `AURORA_SEG_CORRIDOR_M` | 8.0 |
| `segMapTimeoutS` | `AURORA_SEG_MAP_TIMEOUT_S` | 20.0 |

> 口径提醒：`AURORA_STUCK_SECONDS` 的**实际消费者**是 `AuroraDriveApp.swift` 的 `stuckZeroThreshold`（直接下标现读，未走 `AuroraFlags`）；`AuroraFlags.stuckSeconds` 为收敛层声明，两条读取路径并存。

### F. 路网 / 弯道引导（readBy 均为 `Inference/RoadCornerGuide.swift`）

| 属性 | env | 默认 |
|---|---|---|
| `cornerLookaheadM` | `AURORA_CORNER_LOOKAHEAD_M` | 40.0 |
| `cornerHeadingTolDeg` | `AURORA_CORNER_HEADING_TOL_DEG` | 60.0 |
| `cornerDeadbandDeg` | `AURORA_CORNER_DEADBAND_DEG` | 8.0 |
| `cornerSatDeg` | `AURORA_CORNER_SAT_DEG` | 35.0 |
| `cornerPassedM` | `AURORA_CORNER_PASSED_M` | 15.0 |
| `cornerConeDeg` | `AURORA_CORNER_CONE_DEG` | 75.0 |
| `cornerTightRM` | `AURORA_CORNER_TIGHT_R_M` | 80.0 |
| `cornerTightSpeed` | `AURORA_CORNER_TIGHT_SPEED` | 40.0 |
| `juncLookaheadM` | `AURORA_JUNC_LOOKAHEAD_M` | 45.0 |
| `juncApproachM` | `AURORA_JUNC_APPROACH_M` | 25.0 |
| `juncExcludeDeg` | `AURORA_JUNC_EXCLUDE_DEG` | 35.0 |
| `juncForkTolDeg` | `AURORA_JUNC_FORK_TOL_DEG` | 25.0 |
| `juncReachRatio` | `AURORA_JUNC_REACH_RATIO` | 1.2 |

### G. 地图 UI

| 属性 | env | 默认 |
|---|---|---|
| `mapWindow` | `AURORA_MAP_WINDOW` | false |
| `mapTileWindow` | `AURORA_MAP_TILE_WINDOW` | true（boolNotZero） |
| `baseMapGrade` | `AURORA_BASEMAP_GRADE` | true（boolNotZero） |
| `mapSpanM` | `AURORA_MAP_SPAN_M` | (未设) |
| `mapLayers` | `AURORA_MAP_LAYERS` | (未设) |
| `mapLegacyMarkers` | `AURORA_MAP_LEGACY_MARKERS` | false |
| `mapFilterBar` | `AURORA_MAP_FILTER_BAR` | true（boolNotZero） |
| `mapNoMarkers` | `AURORA_MAP_NO_MARKERS` | false |
| `mapMaxLabels` | `AURORA_MAP_MAX_LABELS` | (未设) |
| `mapNoLoadNorm` | `AURORA_MAP_NO_LOADNORM` | false |
| `mapLabelSpanM` | `AURORA_MAP_LABEL_SPAN_M` | (未设) |
| `mapClusterPx` | `AURORA_MAP_CLUSTER_PX` | (未设) |
| `mapClusterPriority` | `AURORA_MAP_CLUSTER_PRIORITY` | (未设) |
| `mapClusterTrace` | `AURORA_MAP_CLUSTER_TRACE` | false |
| `mapDefaultGroups` | `AURORA_MAP_DEFAULT_GROUPS` | (未设) |
| `markerTaxonomy` | `AURORA_MARKER_TAXONOMY` | (未设) |
| `routeGraph` | `AURORA_ROUTE_GRAPH` | (未设) |
| `routeStraight` | `AURORA_ROUTE_STRAIGHT` | false |
| `routeTurnW` | `AURORA_ROUTE_TURN_W` | (未设) |

### H. 性能 / 日志 + I. 缓存

| 属性 | env | 默认 |
|---|---|---|
| `perf` | `AURORA_PERF` | false |
| `perfRounds` | `AURORA_PERF_ROUNDS` | 6 |
| `logSync` | `AURORA_LOG_SYNC` | false |
| `disableHUD` | `AURORA_DISABLE_HUD` | false |
| `benchDrain` | `AURORA_BENCH_DRAIN` | false |
| `benchDragPx` | `AURORA_BENCH_DRAG_PX` | 8 |
| `cacheEnabled` | `AURORA_CACHE` | true（boolNotZero） |

⚠️ 口径说明：上表为 `AuroraFlags` 的 static 属性全集（按分区合计 74 个：A5+B4+C7+D9+E10+F13+G19+H6+I1）。文件头自述「72 个变量」为 2026-10-04 落地时的统计，与当前属性数已不完全一致（差异来源未验证）。另：`AURORA_DISABLE_OPTICAL_FLOW` 在 `AuroraDriveApp.swift` 仍有**独立重复读取**（`Self.opticalFlowDisabled`，未走 `AuroraFlags`）；`AURORA_STUCK_SECONDS` 同样直接下标读。

## 十一、线程 / 队列模型

### 11.1 队列清单

| 队列 label | 定义处 | QoS | 用途 |
|---|---|---|---|
| `aurora.capture`（captureQueue） | `CaptureEngine.swift` | userInteractive | **SCStream sampleHandlerQueue**；每帧拷贝逻辑见注释/实现；串行清理缓冲池 |
| `aurora.quest.ocr`（ocrQueue） | `QuestPanelReader.swift` | utility | Vision OCR 专用。**刻意不复用 captureQueue**：SCStream 队列上同步计算会推迟帧消费引发雪崩（实测 capGap 11ms→2081ms）；OCR `.accurate` p50 33.6ms ≈ 整帧预算 |
| `com.aurora.speedocr` | `SpeedOCRReader.swift` | userInteractive | 速度表 OCR |
| `com.aurora.speedocr.modelload` | `SpeedOCRReader.swift` | serial | 模型加载 |
| `com.aurora.yolo` | `YoloEngine.swift` | userInteractive | YOLO 检测推理（避免与 captureQueue 写竞争） |
| `com.aurora.inference` | `InferenceEngine.swift` | userInteractive | M9/assist E2E 推理 |
| `com.aurora.yolopx` | `YolopxEngine.swift` | env `AURORA_INFER_QOS=interactive` 可覆盖（默认 userInitiated） | YOLOPX/A-YOLOM 推理 |
| `agent.skill`（workQueue） | `AIAgentPanel.swift` | userInteractive | AI 技能工作队列 |
| `aurora.engine.client` | `EngineClient.swift` | userInteractive | UI 侧 socket 读 + 重连定时器 |
| `aurora.engine.socket` | `EngineMain.swift` | userInteractive | 引擎侧 socket 服务 |
| `aurora.engine.tick` | `EngineMain.swift` | userInteractive | 引擎 tick 定时源，**回调再 main.async 进主线程** |
| `aurora.engine.heartbeat` | `EngineMain.swift` | （默认） | 引擎 1Hz 心跳 |
| `aurora.engine.signal` | `EngineMain.swift` | （默认） | SIGTERM/SIGINT 处理，置 `shutdownRequested` 后 main.async 安全停车 |
| `aurora.defender` | `GameModeDefender.swift` | userInteractive | Game Mode 对抗，每 3s 重主张 |
| `aurora.privilege.process` | `PrivilegePill.swift` | utility | 提权脚本执行 |
| `com.aurora.tick` | `MissionConsole.swift` | userInteractive | 地图控制台 tick 驱动（`state.tick()`），回调 main.async |
| `com.aurora.netlocate` | `MissionConsole.swift` | userInteractive | 网络定位轮询 10Hz，回调 main.async |
| `com.aurora.logsink` | `AuroraDriveApp.swift` | utility | 日志缓冲写盘（`LogSink`） |
| `aurora.upscale.ingest` | `AuroraDriveApp.swift` | userInitiated | 插帧 ingest（`UpscaleFrameHost`） |
| `com.aurora.record.write` | `RecordEngine.swift` | （默认/unspecified） | 录制写盘 |
| `com.aurora.confidence.brightness`（brightnessQueue） | `ConfidenceEstimator.swift` | userInitiated | 画面亮度估计 |

### 11.2 主线程 / 后台分工（关键事实）

- **主线程（MainActor）**：`DriveState.tick()` 全部决策；`tick()` 由 `com.aurora.tick` DispatchSource 触发后 `DispatchQueue.main.async` 投递；`EngineGlobals` 全部 @MainActor（`EngineMain.swift`）；`QuestPanelReader` 的投票/匹配/落库回主线程（`onConfirmed` 主线程执行）。
- **captureQueue 特殊性**：它是 SCStream 采样队列，「不是普通后台队列」；回调里只做**覆盖式写 `pendingFrame`**（加锁），SwiftUI 更新由 `tick` 主线程消费。光流曾于 09-27 被移到 captureQueue，09-28 **已回退主线程 tick**。
- **引擎进程**：tick 定时器在 `aurora.engine.tick` 触发但计算 `tickOnce()` 强制回主线程；共享内存 BGRA 双缓冲由引擎写/UI 读；`latestFullFrame` 采集线程写/主线程读 + NSLock。
- **跳帧防堆积模式**（贯穿全项目）：生产者（后台队列）只覆盖「最新一帧」槽位，消费者（主线程 tick）取最新——`pendingFrame` / `pendingYoloFrame` / `pendingNativeFrame` 三处。
- **@Observable 先比后写纪律**：值不变不赋值，省观察者通知（`questName` / `mode` / `confidence` / `locatorFound` 等）。

## 十二、引擎现场判定链：日志「有帧=false 帧数=0 降级=true」怎么读

引擎进程 1Hz 统计日志（`EngineMain.swift`）：

```
[ENGINE] 统计: seq=N 有帧=X det=N driving=X yolopx:加载=X 帧数=N da=N格 ll=N格 降级=X maskSeq=N 耗时=Nms
```

各字段的**代码判定链**：

| 字段 | 判定 | 出处 |
|---|---|---|
| `有帧=false` | `EngineGlobals.state?.currentFrameCG != nil` 为假——引擎的 `DriveState` 还没有消费到任何一帧画面 | `EngineMain.swift` |
| `帧数=0` | `yolopxEngine.inferenceCount == 0`——YOLOPX 一次推理都没跑过 | `EngineMain.swift` / `YolopxEngine.swift` |
| `降级=true` | `yolopxEngine.isDegraded == true`——**初值就是 true**（「模型没跑起来之前一律视为不可信」），只有推理出过有效掩码才会翻 false | `EngineMain.swift` / `YolopxEngine.swift` |
| `det=0` / `driving=false` | YOLO 检测框数 / `state.isDriving` | `EngineMain.swift` |
| `maskSeq` | 掩码世代号（YOLOPX 每次产出新掩码 +1） | `EngineMain.swift` |

**「有帧=false 帧数=0 降级=true」组合的解释链**：

1. **引擎模式下 YOLOPX 根本不跑**（`EngineMain.swift` 头注释明确：`tick()` 在 `EngineClient.shared.isActive` 时 `tickEngineMode(); return` 提前返回，本地推理分支走不到）→ `帧数=0` 与 `降级=true` 是**引擎模式的既定常态**，不是故障（副作用：引擎侧 `isDegraded` 恒 true → `LaneFallback` 不介入）。
2. 该日志的 `降级=` 反映的是**引擎进程内 `yolopxEngine` 的掩码可信度**，与 UI 侧降级状态机（`DegradeStateMachine` 的 e2e/yolo/rule 三档）**不是一回事**：驾驶档位降级由引擎进程自己的 `DriveState.tick → degradeStm.update` 决定，经心跳 `engineMode` 回传 UI。
3. 若 `有帧=false` 持续出现（非刚启动）：先查抓屏权限 / `AURORA_ENGINE_DIAG_CAPTURE_ONLY` 诊断 / `frameHost` 是否从未 push——即**帧管道问题**，与降级状态机无关。
4. UI 侧看到的 `engineMode`/`engineSpeed`/`engineConfidence` 等驾驶状态全部来自引擎心跳字段（`EngineClient.swift`），`speedValid = client.engineSpeedKmh >= 0 && client.engineSpeed > 0.5`（先比后写）。引擎失联（`engineConnected=false`）时 UI 状态面板显示「未连接」，档位显示沿用引擎最后回传值，UI 不自行接管档位。

## 附：Core/ 其余文件一句话职责（详见各专篇文档）

- **AuroraCache.swift**：全 App 统一缓存层（A16），明确弃用 NSCache 的四条理由（单条目覆盖式/TTL 不一/零指标/零统一开关）；`AURORA_CACHE=0` 全直通。详见 代码-18 与 代码-30。
- **AuroraPaths.swift**：项目根多候选解析；`cachedRoot` 曾有数据竞争，改为 static let。详见 代码-02。
- **BPFSetup.swift**：BPF 权限自检——**逐个探测 /dev/bpfN（0..<64，多扫几个防空洞）**，旧版只看 bpf0 的 bug 记录。详见 bpf-daemon.md。
- **DaemonSetup.swift**：引擎拆分后的简化编排器——launchd 拉后台进程拿不到 TCC 权限（ax=false、screen=false），方案已废弃，仅保留 BPF LaunchDaemon。详见 bpf-daemon.md 与 代码-01。
- **EngineClient.swift / EngineMain.swift**：见 代码-07 / 代码-06。
- **GameModeDefender.swift**：对抗 Game Mode 压制——静音音频豁免 App Nap + 每 3s 重主张 nice/-activity，日志 `/tmp/aurora_defender.log`，队列 `aurora.defender`。详见 代码-30。
- **PrioritySetup.swift**：root renice 守护，每 5s 把本进程（含 `--engine` 引擎子进程）renice -20。详见 代码-30。
- **PrivilegePill.swift**：应用内密码提权（`sudo -S` 走 stdin，不进 argv；绝不用系统授权弹窗）；`aurora.privilege.process` 队列 qos .utility。详见 代码-30。
- **WireSelfTest.swift**：引擎配置通道自检（`--wire-selftest`），起因「手切档位静默失效」四处缺陷叠加（①`sendCommand` 静默失败 ②`pushConfig` 日志说谎 ③先记账后发送 ④心跳超时只置 `isConnected` 不动 `isActive`）。详见 代码-33。

---

**规范化说明（2026-11）**：本文原含数百处以行号定位的引用（随源码历史版本多次增长而全部漂移失效），
现全篇改为**符号定位**：`DriveState` 成员（`captureEngine` / `degradeStm` / `recordEngine` / `questPanel` …）、
方法（`tick()` / `runNetworkLocateStep()` / `startDriving()` / `stopDriving()` / `tickEngineMode()` / `pushEngineConfigIfChanged()` /
`recordFrameIfNeeded()` / `readPose()` / `applyCommand(_:)`）、`AuroraFlags` 属性名、队列 label 与 `AURORA_SEG_*` 环境变量。
带「行号」列的两张实测锚点表已改为符号职责表，历史行号漂移记录已删除。

