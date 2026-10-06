# 代码-27 MissionConsole 任务控制中心（UI 大改版核心产物）

> 📌 **文件名失效提示（2026-09-29 复核追加）**：**本文文件名中的 `GameMapView` 已不存在**
> （2026-09-21/22 UI 大改版删除）。文件名保留不改是为了不破坏既有交叉引用，
> **但内容已正确指向 `MissionConsole.swift`**。搜索 GameMapView 时请以本文正文为准。
>
> 覆盖源文件：`Sources/AuroraDrive/App/MissionConsole.swift`（**7101 行**，2026-10-07 `wc -l` 实测；文中"4224 行""3934 行"为 10-02/09-29 旧基准）。
> ⚠️ 2026-09-29 实测：现为 **3952 行**（+18），正文行号可能有小幅偏移。
>
> **🟢 2026-10-07 复核（D7）：本文覆盖的 `MissionConsole.swift` 本次未改动，但正文行号已严重过期。**
> - **git**：`git diff --stat HEAD~5..HEAD -- Sources/AuroraDrive/App/MissionConsole.swift` **输出为空**（零改动）；工作树无未提交改动。最后一次改动为 `faecc6f`（**10-06 18:26**）。
> - ⚠️ **文件名与代码块**：`MissionConsole.swift` 自 10-02 起就是 7101 行（`git show 9c75503:…/MissionConsole.swift | wc -l` 实测，9c75503 = 10-06 复核提交）——**文件没变，是本文档的行号基准停留在 4224/3934 行版**，与代码相差 **+2500~+3000 行**，正文中 :2018-2532 / :2366 / :2772 / :3236 / :3728 / :3792 / :2023 / :2123 / :2169 等锚点**当前均不对应正文所述的构件**。
> - **2026-10-07 实测的当前真实锚点**（逐条 `sed` 核对，替换旧行号使用）：
>
> | 构件 | 旧文档行号 | **当前真实行号** |
> |---|---|---|
> | `ViewportPanel` | :562 | **:562** ✅ 恰好仍对 |
> | `QuestCard` | :856 | **:856** ✅ 仍对 |
> | `MiniMapCanvas` | — | **:1422** |
> | `MapTileCache` / `MapTileImage` | :1704/:2218 区 | **:1780** / **:2218** ✅（MapTileImage 仍在 :2218） |
> | `MapPin` / `MapCorner` / `NavLine` / `NavGuidance` | — | **:2425** / **:2447** / **:2462** / **:2527** |
> | `MapOverlay` | :2023 | **:3350** ❌ 旧值错 1327 行 |
> | `MapViewport` | :2123 | **:3450**（`final class`）❌ |
> | `LargeMapCanvas` | :2169 | **:3589** ❌ |
> | `RoutePlanningOverlay` / `MarkerFilterBar` / `ClusterTooltip` | — | **:4593** / **:4717** / **:4807** |
> | `MapScrollZoom` | :2366 | **:4879** ❌ |
> | `MapCtrlBtn` / `DecisionRail` | — | **:4926** / **:4949** |
> | `SkillOverlay` / `SkillRow` / `SkillGroup` | :2532-2769 | **:5161** / **:5294** / **:5374** |
> | `ContentView` | :2772 | **:5397** ❌ |
> | `MissionControlShot`（无头截图） | :2990-3236 | **:5669** ❌ |
> | `AIChatCard` / `MessageBubble` / `AIChatStatic` | :3236-3712 | **:6411** / **:6610** / **:6682** ❌ |
> | `ConsoleMetrics` / `FitToWindow` / `WindowSizeReader` | :3512-3934 / :3728 / :3792 | **:6885** / **:6895** / **:6959** ❌ |
> | `AutoDriveSwitch` | — | **:7035** |
>
> - **结论**：**语义级描述（结构总览表里的区段内容、"大地图浮层替代 GameMapView"、图层顺序、QuestCard 三行文案、FitToWindow 原理）全部继续有效**；失效的只有行号。**使用时一律以本表替换行号**，或在源码里重新定位。
> - ⚠️ **显著例外（新内容）**：`AIChatCard`（:6411）区段自 :6411 起已扩展到 :6884，比旧表的"3236–3712"长得**多得多**——其中包含 2026-10-07 的 AI 面板改动（见下）。
>
> **📌 2026-10-07 AI 面板改动的落点说明（用户核实项）**：本次 AI 助手改动**主要文件是 `Agent/AIAgentPanel.swift`**（`AgentConversationView` / 后端选择器 / 视觉开关 / 底部小字 / `LLMDiagnosticsSheet` / 配置向导均在那里）；`MissionConsole.swift` 侧只有 **`AIChatCard`（:6411）** 这一层壳，**本次未被修改**（git 零改动）。故本文对本次改动**只作落点标注，不展开**，详见 [代码-23-AIAgentPanel与17技能](代码-23-AIAgentPanel与17技能.md)。
>
> **✅ 2026-10-07 D7b 复核补完（本轮实核，替换上述表中全部行号）**：`MissionConsole.swift` 确为 **7101 行**、`git diff HEAD~5..HEAD` 确为**空**、最后一次改动确为 `faecc6f`（10-06 18:26）、工作树干净——**结论：本次未改动**。上表锚点已用 `grep -n` 逐条实测，**除两项外全部命中**：
> - ✅ 命中：`ViewportPanel` :562、`QuestCard` :856、`MiniMapCanvas` :1422、`MapTileCache` :1780、`MapTileImage` :2218、`MapPin` :2425、`MapCorner` :2447、`NavLine` :2462、`NavGuidance` :2527、`MapOverlay` :3350、`MapViewport` :3450、`LargeMapCanvas` :3589、`RoutePlanningOverlay` :4593、`MarkerFilterBar` :4717、`ClusterTooltip` :4807、`MapScrollZoom` :4879、`MapCtrlBtn` :4926、`DecisionRail` :4949、`SkillOverlay` :5161、`SkillRow` :5294、`ContentView` :5397、`MissionControlShot` :5669、`AIChatCard` :6411、`MessageBubble` :6610、`AIChatStatic` :6682、`ConsoleMetrics` **:6885**、`FitToWindow` :6895、`WindowSizeReader` :6959、`AutoDriveSwitch` :7035。
> - ✅ **勘误 1（结论：无错）**：`SkillGroup` 实测在 **:5374**（`enum SkillGroup: String, CaseIterable`，`SkillGroup.of(_:)` :5381）——上表所记正确；仅需注意 `SkillOverlay` 内的分组计算在 **:5166/:5172**（`private var groups`），勿与 `enum SkillGroup` 混为一处。
> - ❌ **勘误 2（真错，1 处）**：上表「`MapTileCache` / `MapTileImage` | 旧 :1704/:2218 区 | **:1780** / **:2218**」——新值 :1780/:2218 **均正确**，但同格遗留的**旧值 :1704 已失效**（实测该行非 `MapTileCache` 声明）；引用时只用 :1780。
> - ⚠️ **`QuestCard` 各节内联行号（§三-A~§三-F）全部为 10-06 基准，需 `+121`**：实测 `questName` :4283、`locatorTarget` :4277、`routePlan` :4293、`clearRoute()` :4315、`setLocatorTarget` :4414、`questPanel` :5623、`onConfirmed` 接线 :5696-5699、`tick()` :6505、OCR 门 :6556。**§三-A 表内的 MissionConsole 锚点（:861/:901/:924/:927/:941/:957/:972/:974 等）与 §三-E 图层锚点（:3589/:3816/:3845/:3848/:3855/:3879/:3898/:3912/:3942/:3945/:3968/:4103/:4107/:4119/:4142）经 `sed` 实测全部命中，无需换算**（同一文件、未变行）。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `App/GameMapView.swift`（1863 行）——该文件已在 **2026-09-21/22 UI 大改版（A-任务控制中心）中整体删除**，其功能被 MissionConsole 的大地图浮层（MapOverlay/LargeMapCanvas）与 MapWiring 的数据层取代。本档现按 MissionConsole.swift 实际结构重写；旧 GameMapView 的分类筛选/索引搜索/标记详情等交互在新大地图中未全部保留（新地图聚焦：拖拽平移 + 缩放 + 归位 + 自车位置 + 标记渲染 + 导航线）。

## 一、这个文件是什么（文件定位）

**MissionConsole = 任务控制中心**——网页原型 `A-任务控制中心.好版备份-224710.html` 的 **SwiftUI 原生一比一翻译**（用户 9-21 拍板方案、9-22 深夜定稿"删掉一切旧 UI、按网页一比一、必须原生"）。它是整个 App 的主界面：**ContentView 本体就住在这个文件里**（:2772），顶栏/主栅格三栏/大地图浮层/技能浮层/AI 对话卡全部在此。

**结构总览（按 MARK 顺序，3934 行）**：

| 区段 | 行号 | 内容 |
|---|---|---|
| 卡壳 | 23–90 | `ConsoleCard<Content>`（网页 .card / .card.sm）+ `CardHead` |
| 顶栏 | 90–256 | `TopBar`（.topbar）/ `BrandMark` / `TBStat` / `PillStat` |
| 权限小药丸 | 256–310 | `PermissionPill`（.pill-perm）——绿/黄/红三态胶囊 |
| 路况条 | 310–434 | `RCChip` / `RCBar`（.rc-bar）——6 档路况横条 |
| 键盘条 | 434–516 | `KeyBar`（.kb-bar）——WASD/空格/Shift 键帽可视化 |
| 主栅格 | 516–541 | `MainGrid`（网页 .main: **1fr 344px 372px**, gap 13, padding 13） |
| 左栏 | 541–960 | `LeftColumn` → `ViewportPanel`（画面预览）+ `TagChip`/`RCWarn` + `GearRing`（4 档齿轮带）+ `AutoSpeedPill` + `DualGauge`/`GaugeDial`（双圆表：速度+延迟） |
| 中栏 | 960–1577 | `MidColumn` → `MiniMapCard`/`MiniMapCanvas`（小地图）+ **`MapTileCache`/`MapTileImage`/`MapPin`/`MapCorner`/`NavLine`/`NavGuidance`**（真实地图底图 13056）+ `HardwareBank`/`BankSwitch`（4 开关）+ `RunLogCard`（运行日志） |
| 右栏 | 1577–2018 | `RightColumn` → `AutomationBigButton`（自动化大按钮）+ `RunStatusCard` + `ControlRows` + **`LimitSection`**（限速滑块，:1774）+ `SystemCard` |
| 大地图浮层 | 2018–2532 | `MapOverlay`（.ov#mapov）+ `MapViewport` + `LargeMapCanvas` + `MapScrollZoom`（NSViewRepresentable 拖拽/滚轮/捏合）+ `MapCtrlBtn` + `DecisionRail`（决策电路栏） |
| 技能浮层 | 2532–2769 | `SkillOverlay`（.ov#skov，width 572）+ `SkillRow` + `SkillGroup` |
| ContentView | 2769–2990 | **主入口**：.app 整体布局 |
| 无头截图 | 2990–3236 | `MissionControlShot`——--mc-shot/--mc-map 离屏渲染（测试用） |
| AI 对话卡 | 3236–3712 | `AIChatCard`（.ai-card，**LazyVStack 长会话优化**）+ `MessageBubble` + `AIChatStatic` |
| 自适应缩放 | 3512–3934 | `ConsoleMetrics`（设计尺寸常量）+ **`FitToWindow`**（等比缩放自适应核心）+ `WindowSizeReader`（NSViewRepresentable）+ `AutoDriveSwitch` |

## 二、分辨率自适应核心（FitToWindow，用户铁律「任何窗口尺寸都不能遗漏信息」）

**为什么不用 GeometryReader**（9-22 攻坚结论）：GeometryReader 在窗口首帧拿到 0 尺寸 → 窗口塌成 1200×30、TopBar/KeyBar 被挤出、四周黑边。**唯一可靠来源是 NSWindow**。

- **`WindowSizeReader`（:3792，NSViewRepresentable）**：从 `NSView.window` 拿真实窗口 content 尺寸（跳过 SwiftUI 首帧 0 值），上抛给 FitToWindow
- **`FitToWindow<Content>`（:3728）**：拿到窗口尺寸后按 `ConsoleMetrics.designSize` 计算**等比缩放系数**（scale = min(w/designW, h/designH)），用 `scaleEffect` + 固定 designSize 布局实现"整个控制台等比缩放"——窗口多大内容整体等比放大/缩小，**任何元素都不会被挤出或裁掉**。--fit-selftest 真窗口逐档改尺寸验证 9/9 档铺满（执行笔记 2026-09-24 验收）
- **黑边真根因**（9-22 修复实录）：不是缩放算法，是**窗口标题栏**——`AuroraDriveApp` 侧 `WindowConfigurator` + `.windowStyle(.hiddenTitleBar)` + titlebarAppearsTransparent 全套隐藏后消除

## 三、大地图浮层（旧 GameMapView 的替代）

- **`MapOverlay`（:2023）**：全屏浮层（网页 .ov#mapov + .map-sheet），小地图右上角小药丸点击展开
- **`MapViewport`（:2123）**：视口状态（中心/缩放），支持**拖拽平移、+/− 按钮、滚轮、双指捏合、归位按钮**（旧版"缩放功能从来没写过"的修复，9-22）
- **`LargeMapCanvas`（:2169）**：瓦片渲染（64 瓦片 512px @13056 底图，MapTileCache 池化）+ 标记（MapPin）+ **导航线 NavLine**（真实数据派生，无假值——NavGuidance :1336）
- **`MapScrollZoom`（:2366）**：NSViewRepresentable 承接原生滚轮/手势
- **游戏未启动时的行为**（9-22 拆分修复）：小地图显示"游戏未运行 · 无定位数据源"（**无蓝点无假底图**，蓝点会乱跳是 9-23 抓包判定修复前的现象）；**大地图完全可用**（离线渲染不依赖定位）
- **数据链**：CoordinateCapture 抓包 → worldToMapPixel（MapWiring，扩图版校准常量）→ mapPixelX/Y → 视口归一化 → 渲染

## 三-A、QuestCard 当前任务卡片（v3 终态，2026-10-06）

> 覆盖：`struct QuestCard: View`（MissionConsole.swift:856）+ 其在 ViewportPanel 内的挂载与辉光。以下行号均为 2026-10-06 逐条打开源码核实。

### 1. 输入字段与常驻「暂无任务」（v3 终态）

- 输入 4 个只读字段：`questName: String?`（:861）、`egoWorld`（:863）、`targetWorld`（:865）、`routeMeters: Double?`（:867）。
- **卡片常驻，不隐藏**：`questName` 为 nil / trim 后空白（`hasName`，:903-906）时**不返回 EmptyView**，而是显示「暂无任务」+ 两距离「--」（暗银字 textDim）；卡片本体永远渲染，只切内容（body 行为注释 :908-923，「暂无任务」实现 :927）。
- ⚠️ 旧注释未清：MissionConsole.swift:841-842、:6255、:6302 仍写「nil → 整卡消失」，与 :908-923 常驻实现矛盾，**以实现为准**。

### 2. v3 尺寸与布局

| 项 | 值 | 出处（已核实） |
|---|---|---|
| 卡片定宽 | `static let cardWidth: CGFloat = 260`（:901），高度由内容撑开（`.frame(width:)` :974） | MissionConsole.swift:901 |
| 挂载对齐 | `.overlay(alignment: .topLeading)` 左上角（:630），内层 `.padding(.top, 44).padding(.leading, 14)`（:638-639）——44 = 标签行 padding 14 + 标签高 ~21 + 呼吸 ~9，卡片落在 LIVE 标签排下沿之下、与标签同左基线 | MissionConsole.swift:630、:638-639 |
| 内容布局 | `VStack(spacing: 5)` 三行（:924）+ `.padding(.horizontal, 12)`（:972）+ `.padding(.vertical, 9)`（:973） | MissionConsole.swift:924、:972-973 |
| 圆角 | `AuroraSilver.radius` = `Aurora.radiusCard` = 12（注释「小方框不要用面板级 16」） | MissionConsole.swift:976/985/988；AuroraTheme.swift:771-772 |

### 3. 三行文案与字号

| 行 | 内容 | 字体/颜色 | 出处（已核实） |
|---|---|---|---|
| ① 任务名 | `hasName ? questName : "暂无任务"`（:927） | **12.5pt** `Aurora.sans(12.5, hasName ? .semibold : .medium)`（:928）+ tracking 0.3（:929）；有任务 textName / 无任务 textDim（:930-931）；`lineLimit(1)` + `minimumScaleFactor(0.75)` + 尾部截断（:932-934） | MissionConsole.swift:927-936 |
| ② 「任务直线距离」 | 标签全称独占一行 + 数值米串（:941-954，HStack spacing 5） | 标签 `Aurora.label(10.5)` / textDim（:943-944）；数值 `Aurora.metric(11.5, .semibold)` / textName（:947-949） | MissionConsole.swift:941-954 |
| ③ 「任务弯道距离」 | 与②同构（:957-970），数值来自 `routeMeters` | 同② | MissionConsole.swift:957-970 |

- 米数格式：`String(format: "%.0f 米", m)`，nil / 负 / 非有限一律 `"--"`，绝不编数字 —— `metersText(_:)`（:884-887）。
- 直线距离：世界坐标（UE5 厘米）欧氏距离 ÷ 100（`straightMeters`，:869-876）。
- 弯道距离：直接用 `RoutePlan.distanceMeters`（RoutePlanner 像素空间算完已乘 metersPerPixel，**已是米，不再 ÷100**）——注释 :848-850、挂载点注释 :627-628。
- 单位口径：一律「米」，≥1000m 转公里是首版自作主张、已撤（:833-834、:880-883）。旧「直线｜弯道」单行 `distRow` 已删（:1052-1053）。

### 4. 背景描边与辉光（两层 plusLighter）

- 底：深色玻璃渐变 `LinearGradient(AuroraSilver.scrimHi → AuroraSilver.scrim)` top→bottom（:975-983）——不是白玻璃（白色填充亮画面下对比度实测 1.57:1，WCAG AA 要 4.5:1；实测修正注释 AuroraTheme.swift:724-729）。
- 描边：`.strokeBorder(AuroraSilver.stroke, lineWidth: 1)`（:984-987）+ `.clipShape(RoundedRectangle(cornerRadius: AuroraSilver.radius))`（:988）；`.allowsHitTesting(false)`（:1047）。
- **辉光 = 两层加法发光 `.background`**（:1013-1027），不是 `.shadow`：
  1. 近层：圆角矩形（radius+1.5）`fill(glowNear)` → `.blur(radius: 9)` → `.blendMode(.plusLighter)` → `.padding(-1.5)`（:1014-1019）；
  2. 远层：圆角矩形（radius+3）`fill(glowFar)` → `.blur(radius: 20)` → `.blendMode(.plusLighter)` → `.padding(-3)`（:1021-1027）。
- 为什么必须 plusLighter：`.shadow` 是 alpha lerp（`out = bg*(1-a) + C*a`），亮背景（雪地/黄底）上混出 C≈RGB(97,98,95) 反而压暗（实测辉光环带 Δ亮度 min −67.7、变亮 0、变暗 57376 像素）；plusLighter 是加法（`out = bg + C*a` 饱和截断），任何背景只会更亮 —— 根因注释 :993-1012。
- 任务名文字层还保留一个 `.shadow(color: AuroraSilver.glowFar, radius: 4)`（:935），仅文字柔光，非卡片辉光。
- **卡片投影已删**（三调，:1029-1046 注释记录）：二调实测卡片正下方 −25.36（变亮 0 / 变暗 11296），三面亮一面暗像「带阴影的卡片」；用户只要辉光不要投影，删除后光晕对称。

### 5. ViewportPanel 挂载层叠与投影修复

- ViewportPanel 定义：MissionConsole.swift:562。ZStack 层叠自底向上：`FrameHostView`（:568）→ `UpscaleFrameHostView` 插帧层（:572-575）→ `AuroraLightField`（:578-579）→ `ObstacleOverlay`（:588-592）→ `MaskOverlay`（:598-605）→ **QuestCard**（overlay(topLeading)，:630-640）→ 左上 TagChip 排（:643-654）/ 右上 TagChip（:657-664）→ 卡死/路况横幅（:686-700）→ 底部 AutoSpeedPill + DualGauge（:703-725）。顺序注释明写 :622。
- **投影挪进 `.background{}`**（2026-10-06 修复）：`.shadow(color: .black.opacity(0.78), radius: 17, y: 14)` 现在位于 ViewportPanel 的 `.background{}` 内部（MissionConsole.swift:727-761，shadow 语句在 :761）、作用在渐变底图上；随后 `.clipShape(RoundedRectangle(cornerRadius: 16))`（:763）与描边 overlay（:764-770）。
  - 为什么挪：投影原先挂在 ViewportPanel 修饰符链末端，覆盖整个 ZStack，把 `.overlay` 里的任务卡片连带投了 y 偏移黑色投影（卡片下方 5~25px 实测压暗 −27.05，几何与卡片完全吻合）——注释 :737-749。
  - 为什么进 background 就好：`.background{}` 内容不参与外层 `.overlay` 的合成范围，投影只跟随视口底图，overlay 的卡片/标签/检测框不再被投影（:750-754）；左上/右上 TagChip 一并解除压暗（:757-760）。

## 四、真实数据接线原则（ControlWiring 反向约束）

MissionConsole 的**每一个可点元素**背后都有真实执行路径（ControlWiring.swift 头注释的原则："没有执行路径的，宁可不画"）：
- 四根进度条（转向/油门/刹车/速度）← `DriveState.driveBars`（ControlWiring :246）
- 限速滑块 ← `LimitSection` → `setSpeedLimit(source:)`（优先级：用户手动不限速 > 自动速度 > 手动路况）
- 6 档路况条 ← `applyRoadCondition`（极复杂自动置 forceRuleMode）
- GEAR 齿轮带 ← `selectGear`（模型侧/规则侧人工干预）
- 18 项技能 ← SkillOverlay → AgentSkillCenter.toggleSkill

## 三-B、QuestCard 数据链（OCR → 先比后写落库，2026-10-06 新增核实）

- `DriveState`（`@Observable @MainActor final class`，AuroraDriveApp.swift:3979-3981）相关字段（行号已核实）：`locatorFound / locatorX / locatorY`（:4145 起）、`locatorTarget: (x: Double, y: Double)?`（:4156，世界坐标 UE5 厘米）、`questName: String? = nil`（:4162，注释 :4158 仍带旧「整张隐藏」说法，与常驻卡片矛盾，以 MissionConsole.swift:908-927 为准；注释 :4160 明确只存任务名、距离由 UI 现算）、`routePlan: RoutePlan?`（:4172）。
- `setLocatorTarget(x:y:)` 直接赋值，无坐标转换（AuroraDriveApp.swift:4293）；`clearRoute()` 会连带把 `locatorTarget` 置 nil（:4194-4199）。
- **OCR 链**：`DriveState.questPanel = QuestPanelReader()`（`@ObservationIgnored`，AuroraDriveApp.swift:5502；类定义 Inference/QuestPanelReader.swift:416）。`tick()` 每帧 `if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（AuroraDriveApp.swift:6435-6437）。
  - ⚠️ 开关口径不一致（已核实，以 AuroraFlags.swift 为准）：`AuroraFlags.questOCR = bool("AURORA_QUEST_OCR", default: true)` **默认开**（AuroraFlags.swift:201，注释 :192-200 明说 2026-10-06 用户实测后改默认开）；但 AuroraDriveApp.swift:6428 注释写「默认关」、:5497 注释写「默认 false」，且 AuroraFlags.swift:445 注册表 summary 也写「默认关」——**三处注释全部滞后于代码**。运行时可用 `AURORA_QUEST_OCR=0` 关闭。
  - `ingest(cgImage:)`：节流 0.7s（QuestPanelReader.swift:431）、连续 3 次相同文本投票（`voteNeed = 3`，:427）、模糊匹配阈值 0.62（:434）/可信 0.75（:440）、等价目标合并半径 25m（:449）、链消歧（:122）；OCR 在专用后台队列跑，完成后主线程回调 `onConfirmed?(reading)`（main.async :557，回调 :566）；ROI `questROI = CGRect(0.030, 0.240, 0.370, 0.070)`（:424）。
- **onConfirmed 接线**（AuroraDriveApp.swift:5575-5580）：
  - `questName`：**先比后写** `if self.questName != reading.questName { self.questName = reading.questName }`（:5577）——避免 @Observable 值不变还赋值导致整树失效重绘（注释 :5571-5572）；
  - `locatorTarget`：`reading.target` 有值就调 `setLocatorTarget(x:y:)`，不做坐标转换（quest_index 的 x/y 与 locatorTarget 同为世界坐标 UE5 厘米）（:5578，注释 :5573-5574）。
- 定位回写（直线距离来源）：网络定位主线程写 `locatorX/locatorY`（AuroraDriveApp.swift:4544-4548）+ 10Hz 定位 timer `repeating: 1.0/10.0`（MissionConsole.swift:5606，句柄 :5440/:5611）。

## 三-C、QuestCard 出图夹具 --mc-quest（2026-10-06 新增核实）

- 入口：`MissionControlShot.renderQuestCardNow(canvas: 1470×560)`（MissionConsole.swift:6271，enum 定义 :5669）。
- 三分支：① on：`questName = "迎接的熏风"`（:6281，quest_index 真实记录 q110001_0）、ego (−77000, 31865)、target (3920, 272093)（:6283-6285）、弯道走真实 RoutePlanner（`questFixtureRoutePlan` :6340）；② off：`questName = nil`（:6309）；③ noroute：有任务但 `routePlan = nil` → 弯道格显示「--」（:6326-6331）。
- 渲染方式：复用**真实** `ViewportPanel`（VStack{ RCBar + ViewportPanel }，:6369-6374），`ImageRenderer` scale=2（:6379-6380），写 `/tmp/aurora_mc_quest_card_{tag}.png`（:6388）。
- 为什么只画 ViewportPanel：卡片贴顶定位要靠像素测量，画整台控制台探针无法无歧义找到预览框上边（注释 :6362-6366）。
- ⚠️ 夹具注释滞后：off 分支注释「整张卡必须消失」（:6302）与常驻卡片实现（:908-923）矛盾，以实现为准。

## 三-D、地图层 RoadOverlayLayer / MapLayers.swift（2026-10-06 新文件核实）

> `Sources/AuroraDrive/App/MapLayers.swift`（669 行，git 未跟踪新文件）。

- **线宽（RoadOverlayCache.Style，struct :193）**：结构体默认 `roadWidth = 1.6`、`graphWidth = 2.2`、`poiRadius = 2.0`（MapLayers.swift:198-200）；实际生效 `defaultStyle` 闭包（:238-247）：`roadWidth = envWidth("AURORA_MAP_ROAD_W", 2.6)`（:244）、`graphWidth = envWidth("AURORA_MAP_GRAPH_W", 3.6)`（:245）；颜色 roads 0x4CC9FF α0.85 / graph 0x34E5AA α0.90 / POI 0xFFB648 α0.85（:240-242）。`envWidth` 读环境变量，合法 (0, 20] 否则回退默认（:232-236）。加粗原因：路网线中位 3.0 屏幕像素被底图路面淹没；两数一起加粗保持 3.6/2.6 ≈ 1.38 层级比（注释 :219-228）。
- **渲染管线**（`RoadOverlayCache.overlay`，:254-363）：单张 CGImage 缓存，视野不变命中缓存、每帧只画 1 张图（:172-176）；缓存键含量化视口 + flags + 数据世代 gen（`cacheKey` :77-80；gen 防空图缓存事故 :71-76）。绘制顺序（同一位图内）：① 自采路网 roads（flags&1，:322-328）→ ② 路网骨架 graph（flags&2，:331-337）→ ③ POI 圆点（flags&4，:340-351，视口剔除 + `fillEllipse`）；线宽除以缩放比保持屏幕恒定 `roadLW = style.roadWidth / s`（:318-319）；Y 轴必须翻转（CoreGraphics 与地图像素 y 反向，:294-315）。
- **视图层** `RoadOverlayLayer`（:423-471）：cover 取 `side = max(w,h)`（:448），用**量化后**视口（:449）与底图对齐，`.allowsHitTesting(false)`（:469）。
- **数据层** `MapLayerStore`（ObservableObject，:478-504）：后台加载后主线程 `apply` → `generation &+= 1`（:572-579，gen 声明 :484）→ 缓存键含 gen → RoadOverlayLayer 重渲染；视口变化由 LargeMapCanvas 的 vp 状态驱动。

## 三-E、大地图 LargeMapCanvas 图层顺序（行号已核实）

`struct LargeMapCanvas`（MissionConsole.swift:3589）ZStack 自底向上（所有图层共用同一量化视口 cx/cy/spanPx，量化注释 :3816-3836）：

1. 画布底色 `Color(hex: 0x05080E)`（:3845）
2. `MapTileImage` 底图（:3848-3849）
3. `RoadOverlayLayer` 路网叠加（:3855-3857，必须夹在底图与标记之间）
4. 标记/聚类：legacy ForEach（:3879-3897）或 Canvas（:3898 起，5677 点 0.81ms/帧）
5. 路线折线（:3912-3942）：外发光 ice 6.0pt + 白实线 2.6pt + 起终点标记（:3945 起）
6. 直连导航线（AURORA_ROUTE_STRAIGHT=1 legacy，:3968 起）
7. 滚轮缩放层 `MapScrollZoom`（:4103-4105）
8. 「路径规划中」遮罩 `RoutePlanningOverlay`（:4107-4110）
9. 分类筛选条（:4119-4138）
10. 聚类悬停提示（:4142-4148）

## 三-F、QuestCard 的刷新机制：30Hz DispatchSource tick（2026-10-06 核实）

- **主时钟**：`bootstrap()` 里 DispatchSourceTimer，独立高优队列 `com.aurora.tick`（MissionConsole.swift:5534），30Hz `repeating: 1.0/30.0`（:5536），每拍 `DispatchQueue.main.async { state.tick() }`（:5558）；待机（非开车/非录制）降频到 ~3.75Hz（每 8 拍投 1 次，idleSkip :5547-5557）。App Nap 规避原因 :5530-5533。
- 刷新链：`tick()`（AuroraDriveApp.swift:6384 起）消费 pendingFrame 写 `currentScreenImage/currentFrameCG` 等 @Observable 字段（:6416-6423）；同一 tick 里喂 `questPanel.ingest(cgImage:)`（:6435-6437）。
- QuestCard 数据全部来自 `@Observable DriveState`（AuroraDriveApp.swift:3979-3981）：`questName / locatorFound / locatorX / locatorY / locatorTarget / routePlan` 任一被赋值即触发观察它的视图（挂载处 ViewportPanel body）重算；QuestCard 本身无定时器、无动画、无 onAppear 副作用（MissionConsole.swift:853-855），纯读字段。
- QuestCard 未定位时 `egoWorld` 传 nil（MissionConsole.swift:633），直线距离落「--」。

**给别的 AI 的提示**：改 MissionConsole 布局前先看网页原型（docs/文档库/探索文档/ui-prototypes/A-任务控制中心.好版备份-224710.html）——视觉规范以原型为准（纯黑底 #03060B、冰蓝强调 #4CC9FF、发丝线、玻璃拟态 token 全在 AuroraTheme）；布局参数（fr/gap/padding）从网页 CSS 等价翻译，不凭感觉调。

**MissionConsole 文档至此完整**（结构总览级；每个子视图的逐行细节按需查阅源码对应行号段）。
