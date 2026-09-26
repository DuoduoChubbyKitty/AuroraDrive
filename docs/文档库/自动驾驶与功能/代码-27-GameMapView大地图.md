# 代码-27 MissionConsole 任务控制中心（UI 大改版核心产物）

> 覆盖源文件：`Sources/AuroraDrive/App/MissionConsole.swift`（**3934 行，全项目最大文件**）。
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

## 四、真实数据接线原则（ControlWiring 反向约束）

MissionConsole 的**每一个可点元素**背后都有真实执行路径（ControlWiring.swift 头注释的原则："没有执行路径的，宁可不画"）：
- 四根进度条（转向/油门/刹车/速度）← `DriveState.driveBars`（ControlWiring :246）
- 限速滑块 ← `LimitSection` → `setSpeedLimit(source:)`（优先级：用户手动不限速 > 自动速度 > 手动路况）
- 6 档路况条 ← `applyRoadCondition`（极复杂自动置 forceRuleMode）
- GEAR 齿轮带 ← `selectGear`（模型侧/规则侧人工干预）
- 18 项技能 ← SkillOverlay → AgentSkillCenter.toggleSkill

**给别的 AI 的提示**：改 MissionConsole 布局前先看网页原型（docs/文档库/探索文档/ui-prototypes/A-任务控制中心.好版备份-224710.html）——视觉规范以原型为准（纯黑底 #03060B、冰蓝强调 #4CC9FF、发丝线、玻璃拟态 token 全在 AuroraTheme）；布局参数（fr/gap/padding）从网页 CSS 等价翻译，不凭感觉调。

**MissionConsole 文档至此完整**（结构总览级；每个子视图的逐行细节按需查阅源码对应行号段）。
