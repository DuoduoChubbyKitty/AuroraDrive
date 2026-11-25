# 代码-27 MissionConsole 任务控制中心（UI 大改版核心产物）

> ⚠️ **当前值（2026-11-08）**：`ContentView.bootstrap()` 的主计时器现为 `repeating: 1.0 / 15.0`，正常 **15Hz**；待机每 8 拍执行一次，约 **1.875Hz**。文中早期 20Hz 记录属 2026-10-18 快照。

> ✅ **2026-11-10 复核（T7b）**：`MissionConsole.swift` 主视图与 `ContentView` / `bootstrap()` 均按当前源码核实；本次去行号化后所有引用改为符号名。
> **引用方式已升级**：原按 `ContentView` / `bootstrap()` 等符号下游行号定位，现已全部改写为符号名 + 语义描述，不再依赖行号。
> **重点段（符号级）**：`ContentView.bootstrap()`、`com.aurora.tick` 队列、`repeating: 1.0 / 15.0`、`DispatchQueue.main.async { state.tick() }`、`idleSkip < 8` 待机分频，均在 `bootstrap()` 内。
> **重要修正**：正文 §三-F 原写「30Hz `repeating: 1.0/30.0`」——现按源码改为 15Hz / `repeating: 1.0 / 15.0` / 每 8 拍 `idleSkip` 投 1 次。旧口径已废弃。
>
> ✅ **文件名已修正（2026-10-17）**：原名 `代码-27-GameMapView大地图.md` 中的 `GameMapView` 类已在 2026-09-21/22 UI 大改版删除，本文已改名为 `代码-27-MissionConsole任务控制中心.md`，与内容一致。正文指向 `MissionConsole.swift`（当前有效）。
>
> 覆盖源文件：`Sources/AuroraDrive/App/MissionConsole.swift`（通过类型 / 函数 / 属性名引用，不依赖文件行数）。
>
> **✅ 2026-10-18 复核（接 T6 之后）**：早期按行号逐条实测，2026-11-25 起已全部改写为符号名；历史漂移记录仅作留痕，正文不再出现任何行号。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `App/GameMapView.swift`——该文件已在 **2026-09-21/22 UI 大改版（A-任务控制中心）中整体删除**，其功能被 MissionConsole 的大地图浮层（MapOverlay/LargeMapCanvas）与 MapWiring 的数据层取代。本档现按 MissionConsole.swift 实际结构重写；旧 GameMapView 的分类筛选/索引搜索/标记详情等交互在新大地图中未全部保留（新地图聚焦：拖拽平移 + 缩放 + 归位 + 自车位置 + 标记渲染 + 导航线）。

## 一、这个文件是什么（文件定位）

**MissionConsole = 任务控制中心**——网页原型 `A-任务控制中心.好版备份-224710.html` 的 **SwiftUI 原生一比一翻译**（用户 9-21 拍板方案、9-22 深夜定稿"删掉一切旧 UI、按网页一比一、必须原生"）。它是整个 App 的主界面：**`ContentView` 本体就住在这个文件里**（`struct ContentView`），顶栏/主栅格三栏/大地图浮层/技能浮层/AI 对话卡全部在此。

**结构总览（按源码中的类型声明与 MARK 顺序）**：

| 区段 | 主要类型 / 符号 | 内容 |
|---|---|---|
| 卡壳 | `ConsoleCard<Content>` / `CardHead` | 网页 .card / .card.sm |
| 顶栏 | `TopBar` / `BrandMark` / `TBStat` / `PillStat` | .topbar |
| 权限小药丸 | `PermissionPill` | .pill-perm——绿/黄/红三态胶囊 |
| 路况条 | `RCChip` / `RCBar` | .rc-bar——6 档路况横条 |
| 键盘条 | `KeyBar` | .kb-bar——WASD/空格/Shift 键帽可视化 |
| 主栅格 | `MainGrid` | 网页 .main: **1fr 344px 372px**, gap 13, padding 13 |
| 左栏 | `LeftColumn` → `ViewportPanel` + `TagChip` / `RCWarn` / `StuckWarn` / `TakeoverWarn` + `GearRing`（4 档齿轮带）+ `AutoSpeedPill` + `DualGauge` / `GaugeDial`（双圆表：速度+延迟） | 主视口区 |
| 窗口选择拉条 | `WindowPickerRail` | 预览框右侧可收起拉条，选录全屏 / 只录某窗口 |
| 预览框内「当前任务」卡片 | `QuestCard` | 常驻任务卡片，详见 §三-A |
| 应急接管横幅 | `TakeoverWarn` | ET-3 |
| 挡位带 | `GearRing` | 网页 .gear-ring: 4 × .gr-item |
| 自动速度胶囊 | `AutoSpeedPill` | 网页 .auto-speed |
| 双圆表 | `DualGauge` / `GaugeDial` | 网页 .speed-hud |
| 中栏 | `MidColumn` → `MiniMapCard` / `MiniMapCanvas` + `MapTileStore` / `MapTileCache` / `MapBaseImageProvider` / `MapTileImage` / `MapPin` / `MapCorner` / `NavLine` / `NavGuidance`（真实地图底图 13056）+ `HardwareBank` / `BankSwitch` + `PerceptionPickerCard` + `RunLogCard` | 小地图与工具栏 |
| 右栏 | `RightColumn` → `AutomationBigButton` + `RunStatusCard` + `ControlRows` + **`LimitSection`（限速滑块）** + `SystemCard` | 控制区 |
| 大地图浮层 | `MapOverlay` / `MapViewport` / `ClusterCacheStore` / `LargeMapCanvas` / `RoutePlanningOverlay` / `MarkerFilterBar` / `ClusterTooltip` / `MapScrollZoom`（NSViewRepresentable 拖拽/滚轮/捏合）/ `MapCtrlBtn` / `DecisionRail`（决策电路栏） | .ov#mapov |
| 技能浮层 | `SkillOverlay` / `SkillRow` / `SkillGroup` | .ov#skov，width 572 |
| ContentView | `ContentView` / `ContentView.bootstrap()` | .app 整体布局；主时钟在 `bootstrap()` 内 |
| 无头截图 | `MissionControlShot` | `--mc-shot` / `--mc-map` / `--mc-quest` 离屏渲染（测试用） |
| AI 对话卡 | `AIChatCard` / `MessageBubble` / `AIChatStatic` | .ai-card，**LazyVStack 长会话优化** |
| 分辨率自适应 | `ConsoleMetrics` / **`FitToWindow`**（等比缩放自适应核心）/ `WindowSizeReader`（NSViewRepresentable）/ `AutoDriveSwitch` | 设计尺寸常量 + 等比缩放 + 总开关 |

## 二、分辨率自适应核心（FitToWindow，用户铁律「任何窗口尺寸都不能遗漏信息」）

**为什么不用 GeometryReader**（9-22 攻坚结论）：GeometryReader 在窗口首帧拿到 0 尺寸 → 窗口塌成 1200×30、TopBar/KeyBar 被挤出、四周黑边。**唯一可靠来源是 NSWindow**。


- **`WindowSizeReader`（NSViewRepresentable）**：从 `NSView.window` 拿真实窗口 content 尺寸（跳过 SwiftUI 首帧 0 值），上抛给 `FitToWindow`
- **`FitToWindow<Content>`**：拿到窗口尺寸后按 `ConsoleMetrics.designSize` 计算**等比缩放系数**（scale = min(w/designW, h/designH)），用 `scaleEffect` + 固定 designSize 布局实现"整个控制台等比缩放"——窗口多大内容整体等比放大/缩小，**任何元素都不会被挤出或裁掉**。`--fit-selftest` 真窗口逐档改尺寸验证 9/9 档铺满（执行笔记 2026-09-24 验收）
- **黑边真根因**（9-22 修复实录）：不是缩放算法，是**窗口标题栏**——`AuroraDriveApp` 侧 `WindowConfigurator` + `.windowStyle(.hiddenTitleBar)` + titlebarAppearsTransparent 全套隐藏后消除

## 三、大地图浮层（旧 GameMapView 的替代）

- **`MapOverlay`**：全屏浮层（网页 .ov#mapov + .map-sheet），小地图右上角小药丸点击展开
- **`MapViewport`（`final class`）**：视口状态（中心/缩放），支持**拖拽平移、+/− 按钮、滚轮、双指捏合、归位按钮**（旧版"缩放功能从来没写过"的修复，9-22）
- **`LargeMapCanvas`**：瓦片渲染（64 瓦片 512px @13056 底图，`MapTileCache` 池化）+ 标记（`MapPin`）+ **导航线 `NavLine`**（真实数据派生，无假值——`NavGuidance`）
- **`MapScrollZoom`**：NSViewRepresentable 承接原生滚轮/手势
- **游戏未启动时的行为**（9-22 拆分修复）：小地图显示"游戏未运行 · 无定位数据源"（**无蓝点无假底图**，蓝点会乱跳是 9-23 抓包判定修复前的现象）；**大地图完全可用**（离线渲染不依赖定位）
- **数据链**：CoordinateCapture 抓包 → worldToMapPixel（MapWiring，扩图版校准常量）→ mapPixelX/Y → 视口归一化 → 渲染

## 三-A、QuestCard 当前任务卡片（v3 终态，2026-10-06）

> 覆盖：`struct QuestCard: View`（MissionConsole.swift）+ 其在 `ViewportPanel` 内的挂载与辉光。以下引用均为源码中的真实符号。

### 1. 输入字段与常驻「暂无任务」（v3 终态）

- 输入 4 个只读字段：`questName: String?`、`egoWorld`、`targetWorld`、`routeMeters: Double?`。
- **卡片常驻，不隐藏**：`questName` 为 nil / trim 后空白（`hasName` 计算属性）时**不返回 EmptyView**，而是显示「暂无任务」+ 两距离「--」（暗银字 `AuroraSilver.textDim`）；卡片本体永远渲染，只切内容（`body` 行为注释 +「暂无任务」实现）。
- ⚠️ 旧注释未清：`QuestCard` 内与出图夹具处仍写「nil → 整张卡消失」，与常驻实现矛盾，**以实现为准**。

### 2. v3 尺寸与布局

| 项 | 值 | 出处（已核实） |
|---|---|---|
| 卡片定宽 | `static let cardWidth: CGFloat = 260`，高度由内容撑开（`.frame(width: Self.cardWidth)`） | `QuestCard.cardWidth` |
| 挂载对齐 | `.overlay(alignment: .topLeading)` 左上角，内层 `.padding(.top, 44).padding(.leading, 14)`——44 = 标签行 padding 14 + 标签高 ~21 + 呼吸 ~9，卡片落在 LIVE 标签排下沿之下、与标签同左基线 | `ViewportPanel` 的 `.overlay(alignment: .topLeading)` |
| 内容布局 | `VStack(spacing: 5)` 三行 + `.padding(.horizontal, 12)` + `.padding(.vertical, 9)` | `QuestCard` body |
| 圆角 | `AuroraSilver.radius` = `Aurora.radiusCard` = 12（注释「小方框不要用面板级 16」） | `AuroraSilver.radius` / `Aurora.radiusCard` |

### 3. 三行文案与字号

| 行 | 内容 | 字体/颜色 | 出处（已核实） |
|---|---|---|---|
| ① 任务名 | `hasName ? (questName ?? "") : "暂无任务"` | **12.5pt** `Aurora.sans(12.5, hasName ? .semibold : .medium)` + tracking 0.3；有任务 `AuroraSilver.textName` / 无任务 `AuroraSilver.textDim`；`lineLimit(1)` + `minimumScaleFactor(0.75)` + 尾部截断 | `QuestCard` 的任务名 `Text` 层 |
| ② 「任务直线距离」 | 标签全称独占一行 + 数值米串（HStack spacing 5） | 标签 `Aurora.label(10.5)` / `AuroraSilver.textDim`；数值 `Aurora.metric(11.5, .semibold)` / `AuroraSilver.textName` | `QuestCard` 的距离行 |
| ③ 「任务弯道距离」 | 与②同构，数值来自 `routeMeters` | 同② | `QuestCard` 的距离行 |

- 米数格式：`String(format: "%.0f 米", m)`，nil / 负 / 非有限一律 `"--"`，绝不编数字 —— `QuestCard.metersText(_:)`。
- 直线距离：世界坐标（UE5 厘米）欧氏距离 ÷ 100（`QuestCard.straightMeters`）。
- 弯道距离：直接用 `RoutePlan.distanceMeters`（RoutePlanner 像素空间算完已乘 metersPerPixel，**已是米，不再 ÷100**）——注释与挂载点注释均已注明。
- 单位口径：一律「米」，≥1000m 转公里是首版自作主张、已撤。旧「直线｜弯道」单行 `distRow` 已删。

### 4. 背景描边与辉光（两层 plusLighter）

- 底：深色玻璃渐变 `LinearGradient(AuroraSilver.scrimHi → AuroraSilver.scrim)` top→bottom——不是白玻璃（白色填充亮画面下对比度实测 1.57:1，WCAG AA 要 4.5:1；实测修正注释在 `AuroraSilver` 头注释）。
- 描边：`.strokeBorder(AuroraSilver.stroke, lineWidth: 1)`（`QuestCard`）+ `.clipShape(RoundedRectangle(cornerRadius: AuroraSilver.radius))`（`QuestCard`）；`.allowsHitTesting(false)`（`QuestCard`）。
- **辉光 = 两层加法发光 `.background`**，不是 `.shadow`：
  1. 近层：圆角矩形（radius+1.5）`fill(AuroraSilver.glowNear)` → `.blur(radius: 9)` → `.blendMode(.plusLighter)` → `.padding(-1.5)`；
  2. 远层：圆角矩形（radius+3）`fill(AuroraSilver.glowFar)` → `.blur(radius: 20)` → `.blendMode(.plusLighter)` → `.padding(-3)`。
- 为什么必须 plusLighter：`.shadow` 是 alpha lerp（`out = bg*(1-a) + C*a`），亮背景（雪地/黄底）上混出 C≈RGB(97,98,95) 反而压暗（实测辉光环带 Δ亮度 min −67.7、变亮 0、变暗 57376 像素）；plusLighter 是加法（`out = bg + C*a` 饱和截断），任何背景只会更亮 —— 根因注释在 `QuestCard` 内。
- 任务名文字层还保留一个 `.shadow(color: AuroraSilver.glowFar, radius: 4)`（`QuestCard`），仅文字柔光，非卡片辉光。
- **卡片投影已删**（三轮调整的注释仍保留）：二调实测卡片正下方 −25.36（变亮 0 / 变暗 11296），三面亮一面暗像「带阴影的卡片」；用户只要辉光不要投影，删除后光晕对称。

### 5. ViewportPanel 挂载层叠与投影修复

- `ViewportPanel`（`MissionConsole.swift` 内 `struct ViewportPanel: View`）。ZStack 层叠自底向上：`FrameHostView` → `UpscaleFrameHostView` 插帧层 → `AuroraLightField` → `ObstacleOverlay` → `MaskOverlay` → **`QuestCard`**（overlay(topLeading)）→ 左上 `TagChip` 排 / 右上 `TagChip` → 卡死/接管/路况横幅（`StuckWarn` / `TakeoverWarn` / `RCWarn`）→ 底部 `AutoSpeedPill` + `DualGauge`。顺序注释明写于 `ViewportPanel` body 内。
- **投影挪进 `.background{}`**（2026-10-06 修复）：`.shadow(color: .black.opacity(0.78), radius: 17, y: 14)` 现在位于 `ViewportPanel` 的 `.background{}` 内部、作用在渐变底图上；随后 `.clipShape(RoundedRectangle(cornerRadius: 16))` 与描边 overlay。
  - 为什么挪：投影原先挂在 `ViewportPanel` 修饰符链末端，覆盖整个 ZStack，把 `.overlay` 里的任务卡片连带投了 y 偏移黑色投影（卡片下方 5~25px 实测压暗 −27.05，几何与卡片完全吻合）——原因注释在 `ViewportPanel` 内。
  - 为什么进 background 就好：`.background{}` 内容不参与外层 `.overlay` 的合成范围，投影只跟随视口底图，overlay 的卡片/标签/检测框不再被投影；左上/右上 `TagChip` 一并解除压暗。

## 四、真实数据接线原则（ControlWiring 反向约束）

MissionConsole 的**每一个可点元素**背后都有真实执行路径（`ControlWiring.swift` 头注释的原则："没有执行路径的，宁可不画"）：
- 四根进度条（转向/油门/刹车/速度）← `DriveState.driveBars`（`ControlWiring`）
- 限速滑块 ← `LimitSection` → `setSpeedLimit(_:reason:)`（优先级：用户手动不限速 > 自动速度 > 手动路况）
- 6 档路况条 ← `applyRoadCondition(_:)`（极复杂自动置 `forceRuleMode`）
- GEAR 齿轮带 ← `selectGear(_:)`（模型侧/规则侧人工干预）
- 18 项技能 ← `SkillOverlay` → `AgentSkillCenter.toggleSkill`

## 三-B、QuestCard 数据链（OCR → 先比后写落库，2026-10-06 新增核实）

- `DriveState`（`@Observable final class`，`AuroraDriveApp.swift`）相关字段：`locatorFound` / `locatorX` / `locatorY`、`locatorScore`、`locatorHeading`、`locatorTarget: (x: Double, y: Double)?`（世界坐标 UE5 厘米）、`questName: String? = nil`（字段注释仍带旧「整张隐藏」说法，与常驻卡片矛盾，以 `MissionConsole.swift` 为准）、`routePlan: RoutePlan?`。
- `setLocatorTarget(x:y:)` 直接赋值，无坐标转换（`AuroraDriveApp.swift`）；`clearRoute()` 会连带把 `locatorTarget` 置 nil。
- **OCR 链**：`DriveState.questPanel = QuestPanelReader()`（`@ObservationIgnored`，`AuroraDriveApp.swift`；类定义 `Inference/QuestPanelReader.swift`）。`tick()` 每帧 `if AuroraFlags.questOCR, let cg = currentFrameCG { questPanel.ingest(cgImage: cg) }`（`AuroraDriveApp.swift`）。
  - ✅ 开关口径**三处已一致**：`AuroraFlags.questOCR = bool("AURORA_QUEST_OCR", default: true)` **默认开**（`AuroraFlags`）；注册表条目 `AURORA_QUEST_OCR` 的 `defaultValue: "1"` + summary「默认开，2026-10-17 修正：原误写默认关」（已改对）；调用点注释均「2026-10-17 修正」。`--flags-help` 输出 `AURORA_QUEST_OCR=1 …（默认开）`。运行时可用 `AURORA_QUEST_OCR=0` 关闭。
  - `ingest(cgImage:)`：节流 `minInterval`（0.7s，`QuestPanelReader`）、连续 3 次相同文本投票（`voteNeed = 3`）、模糊匹配阈值 `fuzzyThreshold`（0.62）/可信 `fuzzyConfident`（0.75）、等价目标合并半径 `equivalentRadiusMeters`（25m）、链消歧（`QuestVerdict.ambiguous` / `resolveAmbiguous(_:)`）；OCR 在专用后台队列跑（`ocrQueue`），完成后主线程回调 `onConfirmed?(reading)`（main.async）；ROI `questROI = CGRect(0.030, 0.240, 0.370, 0.070)`。
- **onConfirmed 接线**（`AuroraDriveApp.swift`）：
  - `questName`：**先比后写** `if self.questName != reading.questName { self.questName = reading.questName }`——避免 `@Observable` 值不变还赋值导致整树失效重绘（注释已注明）；
  - `locatorTarget`：`reading.target` 有值就调 `setLocatorTarget(x:y:)`，不做坐标转换（quest_index 的 x/y 与 `locatorTarget` 同为世界坐标 UE5 厘米）。
- 定位回写（直线距离来源）：网络定位主线程写 `locatorX` / `locatorY`（`AuroraDriveApp.swift`）+ 10Hz 定位 timer `repeating: 1.0 / 10.0`（`MissionConsole.swift`，`netLocDispatchSource` 句柄）。

## 三-C、QuestCard 出图夹具 --mc-quest（2026-10-06 新增核实）

- 入口：`MissionControlShot.renderQuestCardNow(canvas: 1470×560)`（`MissionConsole.swift` 的 `enum MissionControlShot`）。
- 三分支：① on：`questName = "迎接的熏风"`（quest_index 真实记录 q110001_0）、ego (−77000, 31865)、弯道走真实 RoutePlanner（`questFixtureRoutePlan(state:)`）；② off：`questName = nil`；③ noroute：有任务但 `routePlan = nil` → 弯道格显示「--」。
- 渲染方式：复用**真实** `ViewportPanel`（`MissionControlShot.renderQuestCard(state:tag:canvas:)`；VStack{ `RCBar` + `ViewportPanel` } 注释），`ImageRenderer` scale=2，写 `/tmp/aurora_mc_quest_card_{tag}.png`。
- 为什么只画 `ViewportPanel`：卡片贴顶定位要靠像素测量，画整台控制台探针无法无歧义找到预览框上边（注释已注明）。
- ⚠️ 夹具注释滞后：off 分支注释「整张卡必须消失」与常驻卡片实现矛盾，以实现为准。

## 三-D、地图层 RoadOverlayLayer / MapLayers.swift（2026-10-06 新文件核实）

> `Sources/AuroraDrive/App/MapLayers.swift`（git 已跟踪）。

- **线宽（`RoadOverlayCache.Style`，`RoadOverlayCache` 的内嵌 struct）**：结构体默认 `roadWidth = 1.6`、`graphWidth = 2.2`、`poiRadius = 2.0`（`MapLayers.swift`）；实际生效 `RoadOverlayCache.defaultStyle` 闭包：`roadWidth = envWidth("AURORA_MAP_ROAD_W", 2.6)`、`graphWidth = envWidth("AURORA_MAP_GRAPH_W", 3.6)`；颜色 roads 0x4CC9FF α0.85 / graph 0x34E5AA α0.90 / POI 0xFFB648 α0.85。`RoadOverlayCache.envWidth` 读环境变量，合法 (0, 20] 否则回退默认。加粗原因：路网线中位 3.0 屏幕像素被底图路面淹没；两数一起加粗保持 3.6/2.6 ≈ 1.38 层级比（注释已注明）。
- **渲染管线**（`RoadOverlayCache.overlay(roads:...)`）：单张 CGImage 缓存，视野不变命中缓存、每帧只画 1 张图；缓存键含量化视口 + flags + 数据世代 gen（`MapLayerViewport.cacheKey(outSize:flags:gen:)`；gen 防空图缓存事故）。绘制顺序（同一位图内）：① 自采路网 roads（flags&1）→ ② 路网骨架 graph（flags&2）→ ③ POI 圆点（flags&4，视口剔除 + `fillEllipse`）；线宽除以缩放比保持屏幕恒定 `roadLW = style.roadWidth / s`；Y 轴必须翻转（CoreGraphics 与地图像素 y 反向）。
- **视图层** `RoadOverlayLayer`：cover 取 `side = max(w,h)`（`RoadOverlayLayer.diag` 同源），用**量化后**视口与底图对齐，`.allowsHitTesting(false)`。
- **数据层** `MapLayerStore`（ObservableObject）：后台加载后主线程 `apply` → `generation &+= 1` → 缓存键含 gen → `RoadOverlayLayer` 重渲染；视口变化由 `LargeMapCanvas` 的 vp 状态驱动。

## 三-E、大地图 LargeMapCanvas 图层顺序

`struct LargeMapCanvas`（`MissionConsole.swift`）ZStack 自底向上（所有图层共用同一量化视口 cx/cy/spanPx，量化规则注释已注明）：

1. 画布底色 `Color(hex: 0x05080E)`
2. `MapTileImage` 底图
3. `RoadOverlayLayer` 路网叠加（必须夹在底图与标记之间）
4. 标记/聚类：legacy `ForEach` 或 `Canvas`（5677 点 0.81ms/帧）
5. 路线折线：外发光 ice 6.0pt + 白实线 2.6pt + 起终点标记
6. 直连导航线（`AURORA_ROUTE_STRAIGHT=1` legacy）
7. 滚轮缩放层 `MapScrollZoom`
8. 「路径规划中」遮罩 `RoutePlanningOverlay`
9. 分类筛选条 `MarkerFilterBar`
10. 聚类悬停提示 `ClusterTooltip`

## 三-F、QuestCard 的刷新机制：15Hz DispatchSource tick（2026-10-06 核实，频率按当前源码）

- **主时钟**：`ContentView.bootstrap()`（`MissionConsole.swift`）里 `DispatchSourceTimer`，独立高优队列 `com.aurora.tick`，**15Hz** `repeating: 1.0 / 15.0`（注释记录「原为 1.0/30.0」，2026-10-12 定档 20Hz、后调为 15Hz），每拍 `DispatchQueue.main.async { state.tick() }`；待机（非开车/非录制）降频（`idleSkip < 8` 每 8 拍投 1 次 = **15Hz/8 ≈ 1.875Hz**）。App Nap 规避原因也在注释中。
- 刷新链：`DriveState.tick()` 消费 pendingFrame 写 `currentScreenImage` / `currentFrameCG` 等 `@Observable` 字段；同一 tick 里喂 `questPanel.ingest(cgImage:)`。
- QuestCard 数据全部来自 `@Observable DriveState`（`AuroraDriveApp.swift`）：`questName` / `locatorFound` / `locatorX` / `locatorY` / `locatorTarget` / `routePlan` 任一被赋值即触发观察它的视图（挂载处 `ViewportPanel` body）重算；`QuestCard` 本身无定时器、无动画、无 `onAppear` 副作用（`MissionConsole.swift`），纯读字段。
- `QuestCard` 未定位时 `egoWorld` 传 nil（`ViewportPanel` 内的 `QuestCard(...)` 调用），直线距离落「--」。

**给别的 AI 的提示**：改 MissionConsole 布局前先看网页原型（docs/文档库/探索文档/ui-prototypes/A-任务控制中心.好版备份-224710.html）——视觉规范以原型为准（纯黑底 #03060B、冰蓝强调 #4CC9FF、发丝线、玻璃拟态 token 全在 `AuroraTheme`）；布局参数（fr/gap/padding）从网页 CSS 等价翻译，不凭感觉调。

**MissionConsole 文档至此完整**（结构总览级；每个子视图的细节按需查阅源码中对应类型的符号）。

---

## 附：符号索引（替代旧版实测锚点表）

> 旧版按行号记录锚点，已随源码迭代失效；本节改写为源码中真实存在的符号名。

| 构件 | 符号（源码中检索） |
|---|---|
| `ConsoleCard` / `CardHead` / `TopBar` / `BrandMark` / `TBStat` / `PillStat` | `MissionConsole.swift` 同名 struct |
| `PermissionPill` / `RCChip` / `RCBar` / `KeyBar` | 同名 struct |
| `MainGrid` / `LeftColumn` / `ViewportPanel` / `WindowPickerRail` | 同名 struct |
| `TagChip` / `QuestCard` / `RCWarn` / `StuckWarn` / `TakeoverWarn` | 同名 struct |
| `GearRing` / `AutoSpeedPill` / `DualGauge` / `GaugeDial` | 同名 struct |
| `MidColumn` / `MiniMapCard` / `MiniMapCanvas` | 同名 struct |
| `MapTileStore` / `MapTileCache` / `MapBaseImageProvider` | 同名 final class |
| `MapTileImage` / `MapPin` / `MapCorner` / `NavLine` / `NavGuidance` | 同名 struct |
| `HardwareBank` / `BankSwitch` / `PerceptionPickerCard` / `RunLogCard` | 同名 struct |
| `RightColumn` / `AutomationBigButton` / `RunStatusCard` / `ControlRows` / `LimitSection` / `SystemCard` | 同名 struct |
| `MapOverlay` / `MapViewport` / `ClusterCacheStore` / `LargeMapCanvas` | 同名 struct / final class |
| `RoutePlanningOverlay` / `MarkerFilterBar` / `ClusterTooltip` | 同名 struct |
| `MapScrollZoom` / `MapCtrlBtn` / `DecisionRail` | 同名 struct |
| `SkillOverlay` / `SkillRow` / `SkillGroup` / `SkillGroup.of` | 同名 struct / enum / 枚举方法 |
| `ContentView` / `ContentView.bootstrap()` | `struct ContentView` / `bootstrap()` |
| `MissionControlShot` / `renderQuestCardNow` / `renderQuestCard` | `enum MissionControlShot` / 两个静态方法 |
| `AIChatCard` / `MessageBubble` / `AIChatStatic` | 同名 struct |
| `ConsoleMetrics` / `designSize` / `FitToWindow` / `WindowSizeReader` / `AutoDriveSwitch` | 同名 enum / 属性 / struct |

跨文件符号（本文引用到的其他文件）：

| 符号 | 所在文件 |
|---|---|
| `DriveState` / `locatorFound` / `locatorX` / `locatorY` / `locatorScore` / `locatorHeading` | `AuroraDriveApp.swift` |
| `locatorTarget` / `questName` / `routePlan` | `AuroraDriveApp.swift` |
| `clearRoute()` / `setLocatorTarget(x:y:)` | `DriveState` |
| `questPanel` / `onConfirmed` 接线 / `QuestPanelReader.ingest(cgImage:)` | `AuroraDriveApp.swift` / `QuestPanelReader.swift` |
| `tick()` / `locatorX` / `locatorY` 写入 | `DriveState` |
| `AuroraFlags.questOCR` | `AuroraFlags.swift` |
| `QuestPanelReader` / `ingest(cgImage:)` | `QuestPanelReader.swift` |
| `minInterval` / `voteNeed` / `fuzzyThreshold` / `fuzzyConfident` / `equivalentRadiusMeters` / `questROI` / `ocrQueue` | `QuestPanelReader` |
| `onConfirmed?(reading)` / `resolveAmbiguous(_:)` | `QuestPanelReader` |
| `RoadOverlayCache.Style` / `defaultStyle` / `overlay` / `cacheKey` | `MapLayers.swift` |
| `RoadOverlayLayer` / `MapLayerStore` | `MapLayers.swift` |
| `driveBars` | `ControlWiring.swift` |
| `AuroraSilver.radius` / 白玻璃对比度 1.57:1 注释 | `AuroraTheme.swift` |