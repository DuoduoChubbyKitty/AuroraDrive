# 代码-27 MissionConsole 任务控制中心（UI 大改版核心产物）

> ✅ **2026-10-18 复核（T7b）**：覆盖文件 `MissionConsole.swift` 当前 **7721 行**（`wc -l` 实测；文档原记 7716 行，Lead 今日将 UI tick 从 `1.0/30.0` 改 `1.0/20.0` 并重写注释段，净 +5 行）。
> **行号漂移实测结论**：`:5974`（`ContentView`）之前**全部 65 条锚点 +0 命中**；`:6273` 之后系统性 **+5**。
> **Lead 点名重点段 `:6100–6140` 逐点实测**：`bootstrap()` **:6106**、`com.aurora.tick` 队列 **:6111**、`repeating: 1.0 / 20.0` **:6117**、`DispatchQueue.main.async { state.tick() }` **:6140**、`idleSkip < 8` 待机分频 **:6131–6137**。
> **最重要修正**：正文 §三-F 原写「30Hz `repeating: 1.0/30.0`（:6113）、主线程投递 :6135」——**已按实测改为 20Hz / :6117 / :6140**（原行号对应的实际内容分别是「20Hz 注释」与「idleSkip 语句」，属「行号说的不是那件事」类错误）。
>
> ✅ **文件名已修正（2026-10-17）**：原名 `代码-27-GameMapView大地图.md` 中的 `GameMapView` 类已在 2026-09-21/22 UI 大改版删除，本文已改名为 `代码-27-MissionConsole任务控制中心.md`，与内容一致。正文指向 `MissionConsole.swift`（当前有效）。
>
> 覆盖源文件：`Sources/AuroraDrive/App/MissionConsole.swift`（**7721 行**，2026-10-18 `wc -l` 实测；7716 行为 10-17 旧基准）。
>
> **✅ 2026-10-18 复核（接 T6 之后）**：T6（10-17）已将正文行号按当时 7716 行版逐条实测重写；本次（10-18）因 Lead 改 UI tick 频率段（净 +5 行）重跑 `grep -n` / `sed -n`，修正 `:6273` 起的系统性 +5 漂移，并订正 §三-F 的 30Hz 旧口径。精确锚点见文末「2026-10-18 实测锚点表」。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `App/GameMapView.swift`（1863 行）——该文件已在 **2026-09-21/22 UI 大改版（A-任务控制中心）中整体删除**，其功能被 MissionConsole 的大地图浮层（MapOverlay/LargeMapCanvas）与 MapWiring 的数据层取代。本档现按 MissionConsole.swift 实际结构重写；旧 GameMapView 的分类筛选/索引搜索/标记详情等交互在新大地图中未全部保留（新地图聚焦：拖拽平移 + 缩放 + 归位 + 自车位置 + 标记渲染 + 导航线）。

## 一、这个文件是什么（文件定位）

**MissionConsole = 任务控制中心**——网页原型 `A-任务控制中心.好版备份-224710.html` 的 **SwiftUI 原生一比一翻译**（用户 9-21 拍板方案、9-22 深夜定稿"删掉一切旧 UI、按网页一比一、必须原生"）。它是整个 App 的主界面：**ContentView 本体就住在这个文件里**（`struct ContentView` :5974），顶栏/主栅格三栏/大地图浮层/技能浮层/AI 对话卡全部在此。

**结构总览（按 MARK 顺序，7721 行）**：

| 区段 | 行号 | 内容 |
|---|---|---|
| 卡壳 | 23–89 | `ConsoleCard<Content>`（:29，网页 .card / .card.sm）+ `CardHead`（:69） |
| 顶栏 | 90–255 | `TopBar`（:95，.topbar）/ `BrandMark`（:176）/ `TBStat`（:200）/ `PillStat`（:234） |
| 权限小药丸 | 256–309 | `PermissionPill`（:269，.pill-perm）——绿/黄/红三态胶囊 |
| 路况条 | 310–433 | `RCChip`（:318）/ `RCBar`（:364，.rc-bar）——6 档路况横条 |
| 键盘条 | 434–530 | `KeyBar`（:438，.kb-bar）——WASD/空格/Shift 键帽可视化 |
| 主栅格 | 531–555 | `MainGrid`（:534，网页 .main: **1fr 344px 372px**, gap 13, padding 13） |
| 左栏 | 556–814 | `LeftColumn`（:559）→ `ViewportPanel`（:577）+ `TagChip`（:1132）/ `RCWarn`（:1414）/ `StuckWarn`（:1456）/ `TakeoverWarn`（:1517）+ `GearRing`（:1560，4 档齿轮带）+ `AutoSpeedPill`（:1628）+ `DualGauge`（:1702）/`GaugeDial`（:1733）（双圆表：速度+延迟） |
| 窗口选择拉条 | 815–1161 | `WindowPickerRail`（:831，2026-10-08 新增）——预览框右侧可收起拉条，选录全屏 / 只录某窗口 |
| 预览框内「当前任务」卡片 | 1162–1487 | `QuestCard`（:1213，2026-10-06 新增，详见 §三-A） |
| 应急接管横幅 | 1488–1556 | `TakeoverWarn`（:1517，ET-3 · 2026-10-12） |
| 挡位带 | 1557–1624 | `GearRing`（:1560，网页 .gear-ring: 4 × .gr-item） |
| 自动速度胶囊 | 1625–1696 | `AutoSpeedPill`（:1628，网页 .auto-speed） |
| 双圆表 | 1697–1790 | `DualGauge`（:1702，网页 .speed-hud）+ `GaugeDial`（:1733） |
| 中栏 | 1791–2017 | `MidColumn`（:1794）→ `MiniMapCard`（:1816）/`MiniMapCanvas`（:1911）+ **`MapTileStore`（:2193）/`MapTileCache`（:2290）/`MapTileImage`（:2785）/`MapPin`（:2992）/`MapCorner`（:3014）/`NavLine`（:3029）/`NavGuidance`（:3094）**（真实地图底图 13056）+ `HardwareBank`（:3191）/`BankSwitch`（:3251）+ `PerceptionPickerCard`（:3320）+ `RunLogCard`（:3397） |
| 右栏 | 3481–3921 | `RightColumn`（:3484）→ `AutomationBigButton`（:3511）+ `RunStatusCard`（:3586）+ `ControlRows`（:3622）+ **`LimitSection`（:3678，限速滑块）** + `SystemCard`（:3875） |
| 大地图浮层 | 3922–5733 | `MapOverlay`（:3927，.ov#mapov）+ `MapViewport`（:4027）+ `ClusterCacheStore`（:4115）+ `LargeMapCanvas`（:4166）+ `RoutePlanningOverlay`（:5170）+ `MarkerFilterBar`（:5294）+ `ClusterTooltip`（:5384）+ `MapScrollZoom`（:5456，NSViewRepresentable 拖拽/滚轮/捏合）+ `MapCtrlBtn`（:5503）+ `DecisionRail`（:5526，决策电路栏） |
| 技能浮层 | 5734–5970 | `SkillOverlay`（:5738，.ov#skov，width 572）+ `SkillRow`（:5871）+ `SkillGroup`（:5951） |
| ContentView | 5971–6266 | **主入口**（:5974）：.app 整体布局；`bootstrap()` 主时钟在 :6106 |
| 无头截图 | 6272–7022 | `MissionControlShot`（:6278）——--mc-shot/--mc-map/--mc-quest 离屏渲染（测试用） |
| AI 对话卡 | 7023–7298 | `AIChatCard`（:7031，.ai-card，**LazyVStack 长会话优化**）+ `MessageBubble`（:7230）+ `AIChatStatic`（:7302） |
| 分辨率自适应 | 7299–7498 | `ConsoleMetrics`（:7505，设计尺寸常量）+ **`FitToWindow`（:7515）**（等比缩放自适应核心）+ `WindowSizeReader`（:7579，NSViewRepresentable）+ `AutoDriveSwitch`（:7655） |
| 控制台尺寸常量 / 等比缩放 / 总开关 | 7499–7721 | `enum ConsoleMetrics`（:7505，`designSize` :7510）/ `FitToWindow`（:7515）/ `WindowSizeReader`（:7579）/ `AutoDriveSwitch`（:7655） |

## 二、分辨率自适应核心（FitToWindow，用户铁律「任何窗口尺寸都不能遗漏信息」）

**为什么不用 GeometryReader**（9-22 攻坚结论）：GeometryReader 在窗口首帧拿到 0 尺寸 → 窗口塌成 1200×30、TopBar/KeyBar 被挤出、四周黑边。**唯一可靠来源是 NSWindow**。

- **`WindowSizeReader`（:7579，NSViewRepresentable）**：从 `NSView.window` 拿真实窗口 content 尺寸（跳过 SwiftUI 首帧 0 值），上抛给 FitToWindow
- **`FitToWindow<Content>`（:7515）**：拿到窗口尺寸后按 `ConsoleMetrics.designSize`（:7510）计算**等比缩放系数**（scale = min(w/designW, h/designH)），用 `scaleEffect` + 固定 designSize 布局实现"整个控制台等比缩放"——窗口多大内容整体等比放大/缩小，**任何元素都不会被挤出或裁掉**。--fit-selftest 真窗口逐档改尺寸验证 9/9 档铺满（执行笔记 2026-09-24 验收）
- **黑边真根因**（9-22 修复实录）：不是缩放算法，是**窗口标题栏**——`AuroraDriveApp` 侧 `WindowConfigurator` + `.windowStyle(.hiddenTitleBar)` + titlebarAppearsTransparent 全套隐藏后消除

## 三、大地图浮层（旧 GameMapView 的替代）

- **`MapOverlay`（:3927）**：全屏浮层（网页 .ov#mapov + .map-sheet），小地图右上角小药丸点击展开
- **`MapViewport`（:4027，`final class`）**：视口状态（中心/缩放），支持**拖拽平移、+/− 按钮、滚轮、双指捏合、归位按钮**（旧版"缩放功能从来没写过"的修复，9-22）
- **`LargeMapCanvas`（:4166）**：瓦片渲染（64 瓦片 512px @13056 底图，MapTileCache 池化）+ 标记（MapPin）+ **导航线 NavLine**（真实数据派生，无假值——NavGuidance :3094）
- **`MapScrollZoom`（:5456）**：NSViewRepresentable 承接原生滚轮/手势
- **游戏未启动时的行为**（9-22 拆分修复）：小地图显示"游戏未运行 · 无定位数据源"（**无蓝点无假底图**，蓝点会乱跳是 9-23 抓包判定修复前的现象）；**大地图完全可用**（离线渲染不依赖定位）
- **数据链**：CoordinateCapture 抓包 → worldToMapPixel（MapWiring，扩图版校准常量）→ mapPixelX/Y → 视口归一化 → 渲染

## 三-A、QuestCard 当前任务卡片（v3 终态，2026-10-06）

> 覆盖：`struct QuestCard: View`（MissionConsole.swift:1213）+ 其在 ViewportPanel 内的挂载与辉光。以下行号均为 2026-10-17 逐条打开源码实测。

### 1. 输入字段与常驻「暂无任务」（v3 终态）

- 输入 4 个只读字段：`questName: String?`（:1218）、`egoWorld`（:1220）、`targetWorld`（:1222）、`routeMeters: Double?`（:1224）。
- **卡片常驻，不隐藏**：`questName` 为 nil / trim 后空白（`hasName`，:1260–1263）时**不返回 EmptyView**，而是显示「暂无任务」+ 两距离「--」（暗银字 textDim）；卡片本体永远渲染，只切内容（body 行为注释 :1266–1280，「暂无任务」实现 :1284）。
- ⚠️ 旧注释未清：MissionConsole.swift:1198、:1217、:6917 仍写「nil → 整张卡消失」，与 :1266–1280 常驻实现矛盾，**以实现为准**。

### 2. v3 尺寸与布局

| 项 | 值 | 出处（已核实） |
|---|---|---|
| 卡片定宽 | `static let cardWidth: CGFloat = 260`（:1258），高度由内容撑开（`.frame(width:)` :1331） | MissionConsole.swift:1258 |
| 挂载对齐 | `.overlay(alignment: .topLeading)` 左上角（:645），内层 `.padding(.top, 44).padding(.leading, 14)`（:653–654）——44 = 标签行 padding 14 + 标签高 ~21 + 呼吸 ~9，卡片落在 LIVE 标签排下沿之下、与标签同左基线 | MissionConsole.swift:645、:653–654 |
| 内容布局 | `VStack(spacing: 5)` 三行（:1281）+ `.padding(.horizontal, 12)`（:1329）+ `.padding(.vertical, 9)`（:1330） | MissionConsole.swift:1281、:1329–1330 |
| 圆角 | `AuroraSilver.radius` = `Aurora.radiusCard` = 12（注释「小方框不要用面板级 16」） | MissionConsole.swift:1342/1345/1349；AuroraTheme.swift:771–772 |

### 3. 三行文案与字号

| 行 | 内容 | 字体/颜色 | 出处（已核实） |
|---|---|---|---|
| ① 任务名 | `hasName ? (questName ?? "") : "暂无任务"`（:1284） | **12.5pt** `Aurora.sans(12.5, hasName ? .semibold : .medium)`（:1285）+ tracking 0.3（:1286）；有任务 textName / 无任务 textDim（:1287–1288）；`lineLimit(1)` + `minimumScaleFactor(0.75)` + 尾部截断（:1289–1291） | MissionConsole.swift:1284–1293 |
| ② 「任务直线距离」 | 标签全称独占一行 + 数值米串（:1295–1311，HStack spacing 5） | 标签 `Aurora.label(10.5)` / textDim（:1299–1303）；数值 `Aurora.metric(11.5, .semibold)` / textName（:1304–1309） | MissionConsole.swift:1295–1311 |
| ③ 「任务弯道距离」 | 与②同构（:1313–1327），数值来自 `routeMeters` | 同② | MissionConsole.swift:1313–1327 |

- 米数格式：`String(format: "%.0f 米", m)`，nil / 负 / 非有限一律 `"--"`，绝不编数字 —— `metersText(_:)`（:1241–1244）。
- 直线距离：世界坐标（UE5 厘米）欧氏距离 ÷ 100（`straightMeters`，:1227–1233）。
- 弯道距离：直接用 `RoutePlan.distanceMeters`（RoutePlanner 像素空间算完已乘 metersPerPixel，**已是米，不再 ÷100**）——注释 :1205–1207、挂载点注释 :642–643。
- 单位口径：一律「米」，≥1000m 转公里是首版自作主张、已撤（:1237–1240）。旧「直线｜弯道」单行 `distRow` 已删（:1409–1410）。

### 4. 背景描边与辉光（两层 plusLighter）

- 底：深色玻璃渐变 `LinearGradient(AuroraSilver.scrimHi → AuroraSilver.scrim)` top→bottom（:1332–1340）——不是白玻璃（白色填充亮画面下对比度实测 1.57:1，WCAG AA 要 4.5:1；实测修正注释 AuroraTheme.swift:724–738）。
- 描边：`.strokeBorder(AuroraSilver.stroke, lineWidth: 1)`（MissionConsole.swift:1341–1344）+ `.clipShape(RoundedRectangle(cornerRadius: AuroraSilver.radius))`（MissionConsole.swift:1345）；`.allowsHitTesting(false)`（MissionConsole.swift:1404）。
- **辉光 = 两层加法发光 `.background`**（:1370–1384），不是 `.shadow`：
  1. 近层：圆角矩形（radius+1.5）`fill(glowNear)` → `.blur(radius: 9)` → `.blendMode(.plusLighter)` → `.padding(-1.5)`（:1370–1377）；
  2. 远层：圆角矩形（radius+3）`fill(glowFar)` → `.blur(radius: 20)` → `.blendMode(.plusLighter)` → `.padding(-3)`（:1378–1384）。
- 为什么必须 plusLighter：`.shadow` 是 alpha lerp（`out = bg*(1-a) + C*a`），亮背景（雪地/黄底）上混出 C≈RGB(97,98,95) 反而压暗（实测辉光环带 Δ亮度 min −67.7、变亮 0、变暗 57376 像素）；plusLighter 是加法（`out = bg + C*a` 饱和截断），任何背景只会更亮 —— 根因注释 :1350–1369。
- 任务名文字层还保留一个 `.shadow(color: AuroraSilver.glowFar, radius: 4)`（MissionConsole.swift:1292），仅文字柔光，非卡片辉光。
- **卡片投影已删**（三调，:1385–1404 注释记录）：二调实测卡片正下方 −25.36（变亮 0 / 变暗 11296），三面亮一面暗像「带阴影的卡片」；用户只要辉光不要投影，删除后光晕对称。

### 5. ViewportPanel 挂载层叠与投影修复

- ViewportPanel 定义：MissionConsole.swift:577。ZStack 层叠自底向上：`FrameHostView`（:583）→ `UpscaleFrameHostView` 插帧层（:587–590）→ `AuroraLightField`（:593）→ `ObstacleOverlay`（:603–607）→ `MaskOverlay`（:613–620）→ **QuestCard**（overlay(topLeading)，:645–655）→ 左上 TagChip 排（:658–669）/ 右上 TagChip（:672–679）→ 卡死/接管/路况横幅（:701–724）→ 底部 AutoSpeedPill + DualGauge（:727–749）。顺序注释明写 :637。
- **投影挪进 `.background{}`**（2026-10-06 修复）：`.shadow(color: .black.opacity(0.78), radius: 17, y: 14)` 现在位于 ViewportPanel 的 `.background{}` 内部（MissionConsole.swift:751–786，shadow 语句在 :785）、作用在渐变底图上；随后 `.clipShape(RoundedRectangle(cornerRadius: 16))`（:787）与描边 overlay（:788–794）。
  - 为什么挪：投影原先挂在 ViewportPanel 修饰符链末端，覆盖整个 ZStack，把 `.overlay` 里的任务卡片连带投了 y 偏移黑色投影（卡片下方 5~25px 实测压暗 −27.05，几何与卡片完全吻合）——注释 :759–773。
  - 为什么进 background 就好：`.background{}` 内容不参与外层 `.overlay` 的合成范围，投影只跟随视口底图，overlay 的卡片/标签/检测框不再被投影（:775–778）；左上/右上 TagChip 一并解除压暗（:783–784）。

## 四、真实数据接线原则（ControlWiring 反向约束）

MissionConsole 的**每一个可点元素**背后都有真实执行路径（ControlWiring.swift 头注释的原则："没有执行路径的，宁可不画"）：
- 四根进度条（转向/油门/刹车/速度）← `DriveState.driveBars`（ControlWiring.swift:309）
- 限速滑块 ← `LimitSection`（:3678）→ `setSpeedLimit(source:)`（优先级：用户手动不限速 > 自动速度 > 手动路况）
- 6 档路况条 ← `applyRoadCondition`（极复杂自动置 forceRuleMode）
- GEAR 齿轮带 ← `selectGear`（模型侧/规则侧人工干预）
- 18 项技能 ← SkillOverlay（:5738）→ AgentSkillCenter.toggleSkill

## 三-B、QuestCard 数据链（OCR → 先比后写落库，2026-10-06 新增核实）

- `DriveState`（`@Observable @MainActor final class`，AuroraDriveApp.swift:4150）相关字段（行号 2026-10-18 实测）：`locatorFound / locatorX / locatorY`（:4367–4369）、`locatorScore`（:4370）、`locatorHeading`（:4371）、`locatorTarget: (x: Double, y: Double)?`（:4378，世界坐标 UE5 厘米）、`questName: String? = nil`（:4384，注释 :4380–4383 仍带旧「整张隐藏」说法，与常驻卡片矛盾，以 MissionConsole.swift:1266–1284 为准）、`routePlan: RoutePlan?`（:4394）。
- `setLocatorTarget(x:y:)` 直接赋值，无坐标转换（AuroraDriveApp.swift:4515）；`clearRoute()` 会连带把 `locatorTarget` 置 nil（:4416–4422）。
- **OCR 链**：`DriveState.questPanel = QuestPanelReader()`（`@ObservationIgnored`，AuroraDriveApp.swift:5908；类定义 Inference/QuestPanelReader.swift:416）。`tick()` 每帧 `if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（AuroraDriveApp.swift:6973–6975）。
  - ✅ 开关口径**三处已一致**（2026-10-18 复核）：`AuroraFlags.questOCR = bool("AURORA_QUEST_OCR", default: true)` **默认开**（AuroraFlags.swift:201）；注册表 `AuroraFlags.swift:445` `defaultValue: "1"` + summary「默认开，2026-10-17 修正：原误写默认关」（已改对）；调用点注释 `AuroraDriveApp.swift:5903` / `:6966` 均「2026-10-17 修正」。`--flags-help` 输出 `AURORA_QUEST_OCR=1 …（默认开）`。运行时可用 `AURORA_QUEST_OCR=0` 关闭。
  - `ingest(cgImage:)`（:541）：节流 0.7s（QuestPanelReader.swift:431）、连续 3 次相同文本投票（`voteNeed = 3`，:427）、模糊匹配阈值 0.62（:434）/可信 0.75（:440）、等价目标合并半径 25m（:449）、链消歧（QuestVerdict `.ambiguous` :122、`resolveAmbiguous` :883）；OCR 在专用后台队列跑（`ocrQueue` :483），完成后主线程回调 `onConfirmed?(reading)`（main.async :557，回调 :566）；ROI `questROI = CGRect(0.030, 0.240, 0.370, 0.070)`（:424）。
- **onConfirmed 接线**（AuroraDriveApp.swift:5981–5987，2026-10-18 实测）：
  - `questName`：**先比后写** `if self.questName != reading.questName { self.questName = reading.questName }`（:5983）——避免 @Observable 值不变还赋值导致整树失效重绘（注释 :5976–5978）；
  - `locatorTarget`：`reading.target` 有值就调 `setLocatorTarget(x:y:)`，不做坐标转换（quest_index 的 x/y 与 locatorTarget 同为世界坐标 UE5 厘米）（:5984）。
- 定位回写（直线距离来源）：网络定位主线程写 `locatorX/locatorY`（AuroraDriveApp.swift:4766–4767）+ 10Hz 定位 timer `repeating: 1.0 / 10.0`（MissionConsole.swift:6193，`netLocDispatchSource` 句柄 :6017 / :6207）。

## 三-C、QuestCard 出图夹具 --mc-quest（2026-10-06 新增核实）

- 入口：`MissionControlShot.renderQuestCardNow(canvas: 1470×560)`（MissionConsole.swift:6891，enum 定义 :6278）。
- 三分支（行号 2026-10-18 逐条实测）：① on：`questName = "迎接的熏风"`（:6901，quest_index 真实记录 q110001_0）、ego (−77000, 31865)（:6898–6900）、弯道走真实 RoutePlanner（`questFixtureRoutePlan` 定义 :6960、挂载 :6906）；② off：`questName = nil`（:6929）；③ noroute：有任务但 `routePlan = nil` → 弯道格显示「--」（置 nil 在 :6951，渲染 :6953）。
- 渲染方式：复用**真实** `ViewportPanel`（`renderQuestCard` 定义 :6988；VStack{ RCBar + ViewportPanel } 注释 :6983–6986），`ImageRenderer` scale=2（:7000–7002），写 `/tmp/aurora_mc_quest_card_{tag}.png`（:7003–7010）。
- 为什么只画 ViewportPanel：卡片贴顶定位要靠像素测量，画整台控制台探针无法无歧义找到预览框上边（注释 :6983–6986）。
- ⚠️ 夹具注释滞后：off 分支注释「整张卡必须消失」（:6924–6926）与常驻卡片实现（:1266–1284）矛盾，以实现为准。

## 三-D、地图层 RoadOverlayLayer / MapLayers.swift（2026-10-06 新文件核实）

> `Sources/AuroraDrive/App/MapLayers.swift`（669 行，git 已跟踪）。

- **线宽（RoadOverlayCache.Style，struct :193）**：结构体默认 `roadWidth = 1.6`、`graphWidth = 2.2`、`poiRadius = 2.0`（MapLayers.swift:198–200）；实际生效 `defaultStyle` 闭包（:238–247）：`roadWidth = envWidth("AURORA_MAP_ROAD_W", 2.6)`（:244）、`graphWidth = envWidth("AURORA_MAP_GRAPH_W", 3.6)`（:245）；颜色 roads 0x4CC9FF α0.85 / graph 0x34E5AA α0.90 / POI 0xFFB648 α0.85（:240–242）。`envWidth` 读环境变量，合法 (0, 20] 否则回退默认（:232–236）。加粗原因：路网线中位 3.0 屏幕像素被底图路面淹没；两数一起加粗保持 3.6/2.6 ≈ 1.38 层级比（注释 :204–228）。
- **渲染管线**（`RoadOverlayCache.overlay`，:254 起）：单张 CGImage 缓存，视野不变命中缓存、每帧只画 1 张图（:172–175）；缓存键含量化视口 + flags + 数据世代 gen（`cacheKey` :77–80；gen 防空图缓存事故 :71–76）。绘制顺序（同一位图内）：① 自采路网 roads（flags&1，:322–328）→ ② 路网骨架 graph（flags&2，:331–337）→ ③ POI 圆点（flags&4，:340–351，视口剔除 + `fillEllipse` :348）；线宽除以缩放比保持屏幕恒定 `roadLW = style.roadWidth / s`（:318–319）；Y 轴必须翻转（CoreGraphics 与地图像素 y 反向，:294–315）。
- **视图层** `RoadOverlayLayer`（:423–471）：cover 取 `side = max(w,h)`（:448），用**量化后**视口（:449）与底图对齐，`.allowsHitTesting(false)`（:469）。
- **数据层** `MapLayerStore`（ObservableObject，:478–504）：后台加载后主线程 `apply`（:572–579）→ `generation &+= 1`（:579，gen 声明 :484）→ 缓存键含 gen → RoadOverlayLayer 重渲染；视口变化由 LargeMapCanvas 的 vp 状态驱动。

## 三-E、大地图 LargeMapCanvas 图层顺序（行号已核实）

`struct LargeMapCanvas`（MissionConsole.swift:4166）ZStack 自底向上（所有图层共用同一量化视口 cx/cy/spanPx，量化注释 :4393–4413）：

1. 画布底色 `Color(hex: 0x05080E)`（:4422）
2. `MapTileImage` 底图（:4425–4426）
3. `RoadOverlayLayer` 路网叠加（:4432–4434，必须夹在底图与标记之间）
4. 标记/聚类：legacy ForEach（:4456–4474）或 Canvas（:4476–4483，5677 点 0.81ms/帧）
5. 路线折线（:4489–4542）：外发光 ice 6.0pt（:4504–4506）+ 白实线 2.6pt（:4518–4519）+ 起终点标记（:4521–4541）
6. 直连导航线（AURORA_ROUTE_STRAIGHT=1 legacy，:4544–4580）
7. 滚轮缩放层 `MapScrollZoom`（:4681）
8. 「路径规划中」遮罩 `RoutePlanningOverlay`（:4685–4687）
9. 分类筛选条 `MarkerFilterBar`（:4696–4716）
10. 聚类悬停提示 `ClusterTooltip`（:4718–4726）

## 三-F、QuestCard 的刷新机制：20Hz DispatchSource tick（2026-10-06 核实，2026-10-18 更新频率）

- **主时钟**：`bootstrap()`（MissionConsole.swift:6106）里 DispatchSourceTimer，独立高优队列 `com.aurora.tick`（:6111），**20Hz** `repeating: 1.0 / 20.0`（:6117；⚠️ 原为 `1.0/30.0`，2026-10-12 定档 20Hz 时改，注释 :6113–6116 记录「原为 1.0/30.0，是 20Hz 定档前的遗留值」），每拍 `DispatchQueue.main.async { state.tick() }`（:6140）；待机（非开车/非录制）降频（`idleSkip < 8` 每 8 拍投 1 次 = **20Hz/8 ≈ 2.5Hz**，语句 :6131–6137；⚠️ 原注释「45Hz/8 ≈ 5.6Hz」是 45Hz 时代遗留口径）。App Nap 规避原因 :6108–6110。
- 刷新链：`tick()`（AuroraDriveApp.swift:6865 起）消费 pendingFrame 写 `currentScreenImage/currentFrameCG` 等 @Observable 字段（:6946–6961）；同一 tick 里喂 `questPanel.ingest(cgImage:)`（:6973–6975）。
- QuestCard 数据全部来自 `@Observable DriveState`（AuroraDriveApp.swift:4150）：`questName / locatorFound / locatorX / locatorY / locatorTarget / routePlan` 任一被赋值即触发观察它的视图（挂载处 ViewportPanel body）重算；QuestCard 本身无定时器、无动画、无 onAppear 副作用（MissionConsole.swift:1210–1212），纯读字段。
- QuestCard 未定位时 `egoWorld` 传 nil（MissionConsole.swift:648），直线距离落「--」。

**给别的 AI 的提示**：改 MissionConsole 布局前先看网页原型（docs/文档库/探索文档/ui-prototypes/A-任务控制中心.好版备份-224710.html）——视觉规范以原型为准（纯黑底 #03060B、冰蓝强调 #4CC9FF、发丝线、玻璃拟态 token 全在 AuroraTheme）；布局参数（fr/gap/padding）从网页 CSS 等价翻译，不凭感觉调。

**MissionConsole 文档至此完整**（结构总览级；每个子视图的逐行细节按需查阅源码对应行号段）。

---

## 附：2026-10-18 实测锚点表（`grep -n` 逐条实测，替代正文旧行号）

> 覆盖文件 `Sources/AuroraDrive/App/MissionConsole.swift`（7721 行，`wc -l` 实测）。
> 本次复核结论：**:5974 之前 57 条锚点 +0 命中；:6273 起系统性 +5**（Lead 改 UI tick 频率段净增 5 行所致）。

| 构件 | 行号 |
|---|---|
| `ConsoleCard` / `CardHead` / `TopBar` / `BrandMark` / `TBStat` / `PillStat` | :29 / :69 / :95 / :176 / :200 / :234 |
| `PermissionPill` / `RCChip` / `RCBar` / `KeyBar` | :269 / :318 / :364 / :438 |
| `MainGrid` / `LeftColumn` / `ViewportPanel` / `WindowPickerRail` | :534 / :559 / :577 / :831 |
| `TagChip` / `QuestCard` / `RCWarn` / `StuckWarn` / `TakeoverWarn` | :1132 / :1213 / :1414 / :1456 / :1517 |
| `GearRing` / `AutoSpeedPill` / `DualGauge` / `GaugeDial` | :1560 / :1628 / :1702 / :1733 |
| `MidColumn` / `MiniMapCard` / `MiniMapCanvas` | :1794 / :1816 / :1911 |
| `MapTileStore` / `MapTileCache` / `MapBaseImageProvider` | :2193 / :2290 / :2735 |
| `MapTileImage` / `MapPin` / `MapCorner` / `NavLine` / `NavGuidance` | :2785 / :2992 / :3014 / :3029 / :3094 |
| `HardwareBank` / `BankSwitch` / `PerceptionPickerCard` / `RunLogCard` | :3191 / :3251 / :3320 / :3397 |
| `RightColumn` / `AutomationBigButton` / `RunStatusCard` / `ControlRows` / `LimitSection` / `SystemCard` | :3484 / :3511 / :3586 / :3622 / :3678 / :3875 |
| `MapOverlay` / `MapViewport` / `ClusterCacheStore` / `LargeMapCanvas` | :3927 / :4027 / :4115 / :4166 |
| `RoutePlanningOverlay` / `MarkerFilterBar` / `ClusterTooltip` | :5170 / :5294 / :5384 |
| `MapScrollZoom` / `MapCtrlBtn` / `DecisionRail` | :5456 / :5503 / :5526 |
| `SkillOverlay` / `SkillRow` / `enum SkillGroup` / `SkillGroup.of` | :5738 / :5871 / :5951 / :5958 |
| `struct ContentView` / `bootstrap()` | :5974 / :6106 |
| `enum MissionControlShot` / `renderQuestCardNow` / `renderQuestCard` | :6278 / :6891 / :6988 |
| `AIChatCard` / `MessageBubble` / `AIChatStatic` | :7031 / :7230 / :7302 |
| `enum ConsoleMetrics` / `designSize` / `FitToWindow` / `WindowSizeReader` / `AutoDriveSwitch` | :7505 / :7510 / :7515 / :7579 / :7655 |

跨文件锚点（本文引用到的其他文件）：

| 符号 | 文件:行号 |
|---|---|
| `final class DriveState` / `locatorFound/X/Y/Score/Heading` | AuroraDriveApp.swift:4150 / :4367–4371 |
| `locatorTarget` / `questName` / `routePlan` | AuroraDriveApp.swift:4378 / :4384 / :4394 |
| `clearRoute()` / `setLocatorTarget()` | AuroraDriveApp.swift:4416 / :4515 |
| `questPanel` / `onConfirmed` 接线 / `questPanel.ingest` | AuroraDriveApp.swift:5908 / :5981–5987 / :6973–6975 |
| `tick()` / `locatorX/Y` 写入 | AuroraDriveApp.swift:6865 / :4766–4767 |
| `AuroraFlags.questOCR` | AuroraFlags.swift:201（注释 :192–200；注册表 summary :445） |
| `final class QuestPanelReader` / `ingest(cgImage:)` | QuestPanelReader.swift:416 / :541 |
| `minInterval` / `voteNeed` / `fuzzyThreshold` / `fuzzyConfident` / `equivalentRadiusMeters` / `questROI` / `ocrQueue` | QuestPanelReader.swift:431 / :427 / :434 / :440 / :449 / :424 / :483 |
| `onConfirmed?(reading)` / `main.async` / `resolveAmbiguous` | QuestPanelReader.swift:566 / :557 / :883 |
| `RoadOverlayCache.Style` / `defaultStyle` / `overlay` / `cacheKey` | MapLayers.swift:193 / :238 / :254 / :77 |
| `RoadOverlayLayer` / `MapLayerStore` | MapLayers.swift:423 / :478 |
| `driveBars` | ControlWiring.swift:309 |
| `AuroraSilver.radius` / 白玻璃对比度 1.57:1 注释 | AuroraTheme.swift:771–772 / :724–738 |
