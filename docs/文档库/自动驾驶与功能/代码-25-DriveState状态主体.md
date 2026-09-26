# 代码-25 AuroraDriveApp 之 DriveState 状态主体

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（**3665 行**）之中部：DriveMode/DriveModeGroup/RecordLabelMapper + DriveState（**1304–3079 行**）。基于当前仓库逐单元编写。
>
> **2026-09-25 深度复核块（行号基准已从旧版 851–1300 迁移到 1304–3079）**：
> ① **DriveMode（1304–1331）新增 `uiGroup`**：内部 4 档（e2e/yolo/recover/rule）合并为用户可见 2 档（.e2eDrive 端到端主驾 / .ruleFallback 规则）+ accentColor（recover 橙/rule 红）；
> ② **DriveModeGroup（1336–1367）为 UI 大改版新增**：members/contains/desc/icon——GEAR 齿轮带高亮跟随；
> ③ RecordLabelMapper（1375–1400）**内容未变**（fullScaleDuration 0.6s 语义同旧档）；
> ④ DriveState（1404–3079）核心新增字段/机制：**引擎模式五件套**（remoteDetections/engineModeActive/engineConnected/remoteSpeedKmh + lastDriveCommandTime 1s 宽限期）+ `effectiveDetections` 统一读取点（引擎模式用引擎回传，本地用本地 YoloEngine）+ expertMode/glyphMode/controlDisabled/forceRuleMode（紧急切纯规则）+ **权限状态组**（privilegeReady/privilegeStatusDetail——双条件真绿，防假绿）+ **路况自适应 MARK（1756 起）**：roadCondition/autoSpeedEnabled/unlimitedSource/@ObservationIgnored + e2eLatencyMs（引擎心跳 fps 反推 or tickGapMs）+ effectiveSpeed（OCR EMA 平滑/一阶滤波回退）+ speedValid 新鲜度 + m9Status 三态（未加载/活跃/失联——1s 内有结果才算活跃）+ frameHost 直绘改造（currentScreenImage/currentFrameCG 均 @ObservationIgnored，UI 显示走 FrameHost 绕开 SwiftUI diff）+ screenSize 普通 @Observable（只在变化时写，驱动 ObstacleOverlay 对齐）+ regionLabel（MapDatabase 反查，不写死地名）+ mapMarkerCount/activeModelLabel（模型文件在盘+引擎在跑才算已挂载·ANE，如实报缺失环）；
> ⑤ **一键训练 MARK（2355 起）**：拉起 Python 训练进程；
> ⑥ tick 主体含 9-24 优化：Detection 先比后写（`detections != old` 才写）、refreshHeldKeys 重发、fastPathActive 超时回退（lastFastPathTime + 1s）。
> 旧正文对 RecordLabelMapper 语义与 DriveState 开关字段的描述仍有效；tick 决策链（E2E/Rule/Escape 三段融合）以源码为准。

## 一、RecordLabelMapper 与 DriveState 开关字段（第 851–930 行）

**`RecordLabelMapper`（enum，第 855–880 行）**——专家模式录制标签换算器（**纯函数，便于单测**）。语义（851–854 行注释）：把物理按键的"按住时长"换算成连续控制标签——**与推理端闭环一致：ControlEngine 按 \|steer\|>阈值 决定是否按住键，游戏自身再把按住时长平滑成转角——录制端用按住时长作为监督信号，让模型学到"打得越满 → 按住越久"的连续映射，替代二值标签带来的顿挫**。

| 方法/常量 | 签名 | 说明 |
|---|---|---|
| `fullScaleDuration` | `static let = 0.6` 秒 | **满刻度时长：按住满该时长 → 标签饱和 ±1**；默认 0.6s：30Hz 下约 18 帧，覆盖"轻点 → 满打"的常见手感区间 |
| `holdRatio(_:)` | `TimeInterval -> Double` | 按住时长 → [0,1] 比例（钳制）：`min(1, max(0, duration / 0.6))` |
| `steer(leftHeld:rightHeld:)` | 双时长 → Double | **D 按住比例 − A 按住比例，净差钳制到 [-1,1]（左负右正）** |
| `throttle(wHeld:)` | 时长 → Double | W 按住比例 [0,1] |
| `brake(sHeld:spaceHeld:)` | 双时长 → Double | **S 或 空格(手刹) 任一按住即刹车，取两者按住比例较大者 [0,1]** |

**`DriveState`（@Observable @MainActor final class，第 882–884 行起）**——全局状态 + 驾驶闭环。**开关字段（第 885–940 行）：**

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

**引擎模式字段（第 889–903 行）：**

| 成员 | 说明 |
|---|---|
| `remoteDetections: [Detection]` | **引擎回传的检测结果（引擎模式下每 tick 刷新）** |
| `engineModeActive` | 引擎模式是否激活（镜像自 EngineClient，供 UI 观察刷新） |
| `engineConnected` | 引擎心跳是否正常（false = 失联，UI 显示告警） |
| `remoteSpeedKmh: Double`（默认 -1） | **引擎回传的车速表读数——引擎模式下本地 speedOCR 不跑，用它顶上** |
| `lastDriveCommandTime`（@ObservationIgnored） | **最后一次「开始/停止」命令时间：引擎状态回同步的 1 秒宽限期，防切换瞬间 UI 闪烁** |
| `effectiveDetections`（计算属性） | **UI 统一检测结果读取点：`EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections`**——引擎模式用引擎回传，本地模式用本地 YoloEngine |

**BPF/Daemon 字段（第 925–937 行）**：`bpfAuthorized`（启动时检测 BPF 权限）/ `showBPFPasswordSheet` / `bpfInstallMessage` / `bpfInstalling`；`daemonInstalled` / `showDaemonInstallSheet` / `daemonInstallMessage` / `daemonInstalling` / `isDaemonMode`——**Daemon 系统服务相关字段（安装引导弹窗/结果消息）**。

**网络定位字段（第 942–947 行）**：`networkLocateX/Y/Score/Mode/Pitch/Heading`（六件套，UI 小地图显示用）。

## 二、定位器字段与 runNetworkLocateStep / dlog 10MB 封顶（第 949–1080 行）

**定位器字段（第 949–960 行，从外置盘移植，MinimapLocatorView 需要）**：`locatorFound/X/Y/Score/Heading`（五件套）+ `locatorTarget: (x: Double, y: Double)?`（传送目标）+ `lastNetworkLocPos`（@ObservationIgnored，上次定位位置——朝向反推基线）+ `healerInitLock`（os_unfair_lock，懒初始化锁）+ `coordinateCapture: CoordinateCapture?`（@ObservationIgnored，网络坐标抓取器）+ `locateCtx/locateGate`（LocateContext/LocateGate）。

**`mapPath`（lazy 闭包，第 961–975 行）**——底图路径解析（**用可执行文件所在目录找地图，不用 currentDirectoryPath（那是 Home 目录）**）：

- 四候选：`execDir/models/bigworldmap-13056.jpg`（首选）/ `execDir/models/bigworldmapSecond.png` / 硬编码 `/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg` / 旧图 png
- 全败返回**最后一个候选**（"返回最后一个作为默认，让错误信息有意义"——错误信息里能看到路径）

**`setLocatorTarget(x:y:)`（第 977 行）**：设置传送目标（locatorTarget）。

**`heading(from:to:)`（static，第 979–983 行）**：两点间朝向——`atan2(dy, dx) × 180/π`，负值 +360 归一到 [0, 360)。

**`runNetworkLocateStep()`（第 985–1040 行）**——网络定位步（**懒初始化 CoordinateCapture（纯网络定位，无自愈引擎）**）：

1. **懒初始化（987–1002 行）**：`coordinateCapture == nil` 时——`os_unfair_lock_lock(&healerInitLock)` + `defer` 解锁 + **双检**（锁内再判 nil，防并发重复初始化）→ `cc.start()`（libpcap 起抓包，见 代码-04）→ `pcapLog("[NETWORK-LOCATE] cc.start()返回=…")` 记录成败 → `locateCtx.networkReady = true`
2. `guard let cc, locateCtx.networkReady`——未就绪 → 主线程 `networkLocateScore = 0` + `mode = "not_ready"` → return
3. **`cc.read(maxAge: 1.0)` 有数据（1012–1032 行）**：`worldToMapPixel(pose)` 换算（见 代码-04 单元四）→ `lastNetworkLocPos` 距离平方 > 16（地图 >4px）时**用移动方向计算朝向**（1014–1019 行——注释里写了策略但实现是空的 if 体：**朝向仍用 CoordinateCapture 自报的 hdg，位移反推未实现**）→ 主线程异步更新 networkLocate 六件套 + locator 五件套（**双份字段同步**——MinimapLocatorView 读 locator、大地图读 networkLocate）
4. **无数据（1033–1039 行）**：`networkLocateScore = 0` + `mode = "no_data"`

**`networkLocateLastUpdate`（第 1041 行）**：上次定位更新时间（默认 .distantPast）。

**三个时间戳（第 1043–1054 行）**：`drivingStartTime`（**本次开车会话开始时间——暖机期判定：启动后头几秒还没出推理结果时保持高置信度，避免启动瞬间误降级**）、`lastTickLog`（tick 摘要 1Hz 节流）、`lastUpscaleLiveLog`（插帧状态更新节流 1Hz）。

**`dlog(_ msg: String)`（private，第 1058–1080 行）**——调试日志：**stdout + `/tmp/aurora_debug.log`（App 启动时清空）**；"用户从终端启动可实时看到；事后我读文件定位运行时问题"。

- **P1 修复（1063–1070 行）**：**dlog 每秒追加，7×24 运行日志无限增长。写前检查大小，超 10MB 直接覆盖重写（truncate，atomic 写），只保留最近日志，封顶磁盘占用**
- 追加写：FileHandle seekToEndOfFile + write；文件不存在 createFile 等价路径（data.write）

## 三、isRecording didSet 与引擎模式回声防环（第 1082–1180 行）

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
| `lastDecided`（private，默认 .e2e） | **上一帧状态机决策档位：用于检测"刚切入 .recover"的边沿——让脱困只 enter 一次（避免每帧 phase==.done 就 re-enter 抵消超时）** |
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

## 四、跳帧防堆积与诊断尺子（第 1182–1300 行）

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

## 五、三段胶水、startDriving / stopDriving（第 1301–1535 行）

**旧网络定位已移除（1305–1309 行注释）**：`NetworkPacketCapture` 已移除（不编译），**使用移植的 NetworkLocator**。

**三段胶水代码（第 1311–1336 行，接模型输出 → 状态机 → 按键注入）：**

| 实例 | 说明 |
|---|---|
| `escapeController = EscapeController()` | **.recover 态脱困策略（倒车→转向→前进）** |
| `ruleController = RuleController()` | **.yolo/.rule 态 YOLO 检测→控制量规则** |
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
- **本地模式（1520–1535 行）**：isDriving=false → `controlEngine.releaseAll()`（**1. 释放所有按住的键，避免按键卡住**）→ `keyboardMonitor.stop()` → `captureEngine.stop()` → **4. 重置链**：`degradeStm.reset()` + `escapeController.reset()` + `lastDecided = .e2e` + `confidenceEst.reset()` + `inferenceEngine.reset()` + `assistEngine.reset()` + `yoloEngine.reset()` + `speedOCR.reset()` → `currentCommand = .idle` → **5. `if isRecording { isRecording = false }`（didSet 会触发 recordEngine.stop()，保证 meta.json 落盘）**

## 六、档位开关 / 防冻结禁用 / 一键训练与模型热部署（第 1537–1715 行）

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

## 七、tickEngineMode 回声防环与 pushEngineConfigIfChanged（第 1717–1835 行）

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

## 八、tick() 主循环——完整决策管线（第 1837–2092 行）

**`tick()`（第 1839–2082 行）**——每帧推进（30Hz，由 ContentView 的 Timer 驱动）。**完整决策管线：CoreML 推理 → 置信度估计 → 状态机决策 → 按态输出控制量 → 录制**。

**① 诊断 + 引擎分流（1840–1849 行）**：tickGapMs（实际间隔，>33ms = 主线程掉拍）；**引擎模式 → `tickEngineMode()` + return**（本地抓屏/推理/按键全部不跑）。

**② 消费三组跳帧缓冲（1851–1891 行）**：

- **待显示帧（1855–1869 行）**：锁内取 pendingFrame/CG/Time → `frameDeliveryLagMs`（**入队到执行的延迟**）→ currentScreenImage/currentFrameCG 赋值（SwiftUI 刷新）→ `frameHost.push(cg)`（isStreaming 时）→ screenSize 更新
- **YOLO 直通帧（1871–1878 行）**：取最新 → `yoloEngine.inferFast(pixelBuffer:)`
- **原生 ROI 帧（1880–1891 行）**：取最新 → `speedOCR.infer(nativePixelBuffer:)` + **字模录制**（glyphMode && isRecording 时 `appendGlyphNative` + frames 同步）

**③ 待机分支（1893–1903 行）**：`degradeStm.degradeHealth = degradeThreshold`（阈值同步）；`guard isDriving else { speedValid = false; effectiveSpeed 衰减（-6/tick）；currentCommand = .idle; recordFrameIfNeeded()（**待机也写帧：录制不依赖驾驶状态**）; return }`。

**④ 感知层（1905–1943 行）**：

- `dt = 1.0/30.0`
- **双驾驶模型推理 + YOLO 检测（异步触发，不阻塞 tick）**：`!forceRuleMode` 时 M9 infer（**紧急切纯规则时 M9 停推理（省资源；纯规则决策不依赖 M9 输出）**）；assistEngine 恒 infer；`!yoloEngine.fastPathActive` 时回退 tick 内转换
- **`commandOf(_ engine:)`（1923–1929 行）**：lastResult → ControlCommand（confidence 0.9 占位——置信度估计器会覆盖）；无结果 idle 占位
- **`isAlive(_ engine:)`（1934–1937 行）**：`isLoaded && lastResult != nil && lastResultTime < 1.0`——**模型链路存活：加载成功 && 有结果 && 结果 1s 内新鲜**
- `detections = yoloEngine.detections`——**同一份数据同时供：RuleController 决策 + ObstacleOverlay 画框**

**⑤ 有效车速（1945–1959 行）**——OCR 新鲜 → EMA 追真实读数；否则一阶滤波回退：

- **替代原遥测模拟（指数逼近限速 + 随机抖动）：速度现在来自真实游戏读数（speedOCR），读不到时平滑衰减而非随机抖动；卡死判据由 speedValid 门控避免"读不到→误判卡死"**
- `ocrFresh = speedKmh >= 0 && confidence > 0.3 && lastResultTime < 0.5` → `speedValid = ocrFresh`
- ocrFresh → `effectiveSpeed += (ocr - effectiveSpeed) × 0.7`（**快跟踪**）；否则 `× 0.9` 向 0 衰减（<0.5 归零）
- `fps = captureFPS > 0 ? captureFPS : 60`（**删除模拟遥测随机抖动**）

**⑥ 降级状态机决策（1961–1974 行）**：

- **暖机期**：`warmingUp = lastResult == nil && 开车 < 3.0s`——**开车头几秒还没出推理结果，保持档位不降级**
- `decided = degradeStm.update(九参数)` → `mode = decided`（同步给 UI）

**⑦ 置信度估计（1976–1988 行）**：

- 暖机期 → `confidence = 1.0`
- 否则：`healthCommand/healthLive = (mode == .e2e) ? (m9Command, m9Live) : (assistCommand, assistLive)`——**喂当前档位驾驶模型的输出 + 画面**；`confidenceEst.update(...)` → `confidence = confidenceEst.confidence`

**⑧ 按态输出控制量（1990–2023 行）：**

| 档 | 输出 | 附加 |
|---|---|---|
| `.e2e` 档1 | `currentCommand = m9Command`（**M9 直接开车**） | escapeController.reset() |
| `.yolo` 档2 | `currentCommand = assistCommand`（**第二套神经网开车，YOLO 框仍实时显示**） | escapeController.reset() |
| `.rule` 档4 | `currentCommand = ruleController.decide(detections:)`（**YOLO 检测 → 手写规则，最后防线**） | escapeController.reset() |
| `.recover` 档3 | `escapeController.update(dt:speedKmh:)` → currentCommand = cmd | **P0 修复（2009–2013 行）**：**只在"从其他档切入 .recover 的那一刻" enter 一次**（`if lastDecided != .recover { escapeController.enter() }`）——原实现每帧 phase==.done 就 re-enter，**抵消 EscapeController 的 15s 超时，导致 7×24 永不停歇脱困**；escaped → `degradeStm.reset()`（状态机下一帧因车速恢复自动转出） |

- `lastDecided = decided`（记录本帧决策，供下一帧检测边沿）

**⑨ 按键注入（2025–2033 行）**：

- **`expertMode \|\| controlDisabled` → `controlEngine.releaseAll()`**——专家模式：**不注入 AI 键，让真人物理键独占驾驶；录制的控制量即纯专家演示，画面与标签一致（避免 AI/真人键冲突）**；禁用控制：同理不注入 AI 键，但 YOLO/E2E 照常跑（仅供画面辅助）
- 否则 `applyCommand(currentCommand)`

**⑩ 录制 + 插帧状态 + 调试摘要（2035–2091 行）**：

- `recordFrameIfNeeded()`（见单元九）
- **插帧/超分状态 1Hz 更新（2041–2056 行）**：pendingError → upscaleEngineError（**无错误时清零，防止旧错误常驻 badge**）；statsSnapshot → upscaleLive 字符串
- **调试摘要 1Hz（2058–2081 行）**——诊断"M9 没输出键"：**mode 落在哪档、模型活没活、命令是什么、按键注入有没有被权限拦截**；**front= 记录注入时前台应用是谁：CGEvent 全局注入的事件只发给前台应用，游戏不在前台（被 App 窗口/其他应用挡着）就收不到注入键**——完整一行：mode/m9Live/assistLive/conf/img/cmd(s,t,b)/held/ev/perm/front/native尺寸/ocr[引擎]/eff/vld/lag/mem/capGap/capWork/tickGap + upscaleStatLine（2084–2091 行：up=产出/输出/透传 + fps + view 附件信息 + ERR）

## 九、recordFrameIfNeeded 与 applyCommand 按键映射（第 2093–2161 行）

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