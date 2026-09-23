# 代码-28 GameHUDWindow 与 AutomationPanel

> 覆盖源文件：`Sources/AuroraDrive/App/GameHUDWindow.swift`（120 行）+ `Sources/AuroraDrive/App/AutomationPanel.swift`（251 行）。基于当前仓库逐单元编写。

## 一、GameHUDWindow 帧率 HUD（GameHUDWindow.swift 全文 120 行）

**引用关系（grep 实测）**：唯一安装调用方 = AuroraDriveApp:1359（DriveState.init 里 `if !CommandLine.arguments.contains("--engine") { gameHUD.install() }`）；`fpsProvider` 唯一赋值方 = AuroraDriveApp:1345；`uninstall()` **零调用方**（无卸载路径）；`isInstalled`/`debugState` **零调用方**（诊断属性未被 UI 读）。

**文件头（4–19 行）——用途（双重）**：

```
1) 实用：游戏全屏时实时显示「辅助帧率（AuroraDrive 处理帧率）」与
   「游戏帧率（ScreenCaptureKit 实际捕获到的合成帧率）」两行数据，
   用来判断 Game Mode 是否在压制本进程（掉到个位数 = 被压制）。
2) 对抗 Game Mode：一个持续可见的真实窗口比 1×1 隐形锚点更难被
   gamepolicyd 归入「无可见窗口的纯后台」桶（Game Mode 会压制后台任务）。
```

**关键实现（14–18 行）**：window level = **.screenSaver**——压过游戏全屏窗口；collectionBehavior 含 **.fullScreenAuxiliary**——游戏进全屏 Space 后依然可见；**ignoresMouseEvents = true——绝不拦截游戏操作**；**绿色等宽字 + 半透明黑底——HUD 风格且在任何画面上可读**。

**`GameHUDWindow`（@MainActor final class，第 25 行起）：**

| 成员 | 说明 |
|---|---|
| `window: NSWindow?` / `label: NSTextField?` / `updateTimer: Timer?` | 窗口/标签/刷新定时器 |
| `fpsProvider: (() -> (assist: Double, game: Double))?` | **两行数据的取值闭包（由调用方提供，避免此处依赖具体引擎内部）** |
| `isInstalled` | `window != nil`（HUD 是否已安装） |
| `debugState` | **当前窗口可见性（诊断用）**："未安装" / "visible=… level=… frame=…" |

**`install()`（幂等，第 44–100 行）——安装 HUD（默认左上角）：**

1. **幂等（45 行）**：`if window != nil { return }`——重复调用只更新一次
2. **自我保护（46–52 行）**：`guard NSApp != nil else { print("[HUD] 无 NSApplication 上下文（引擎进程）→ 跳过 HUD 安装") }`——**没有 NSApplication UI 上下文时绝不创建窗口。引擎进程（--engine）会创建 DriveState，若在其内建窗会崩 AppKit（NSViewSetCurrentlyBuildingLayerTreeForDisplay assertion）**（与 DriveState.init 里的 `!CommandLine.arguments.contains("--engine")` 双保险）
3. **窗口（54–73 行）**：168×46（**够放两行等宽字，HUD 小巧，避免遮挡游戏视野**）；isOpaque=false + **`backgroundColor = NSColor.black.withAlphaComponent(0.28)`（半透明黑底，保证绿字可读）** + hasShadow=false + ignoresMouseEvents=true + isMovable=false + **level = .screenSaver（★ 压过全屏游戏）** + collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, **.fullScreenAuxiliary（★ 跟随游戏全屏 Space）**]；**左上角内缩（用 CGDisplay 取主屏全尺寸，不受 app 激活状态影响）**：`(b.minX + 8, b.maxY - h - 8)`
4. **绿色等宽两行（76–87 行）**：`NSTextField(labelWithString: "辅助帧率  --\n游戏帧率  --")`——**monospacedSystemFont 12pt bold** + **荧光绿（0.20, 1.0, 0.35）** + clear 底 + 无边框 + isEditable=false + isSelectable=false + 左对齐 + maximumNumberOfLines=2 + frame(6,4, w-12, h-8)
5. `orderFrontRegardless()` + window/label 持有
6. **2Hz 刷新（93–99 行）**："**HUD 数字不需要更快；低刷新也顺带减少自身唤醒**"——Timer 0.5s（Task @MainActor → refresh）+ RunLoop.main .common + updateTimer 持有 + 立即 refresh 一次

**`uninstall()`（第 103–109 行）——卸载（停止定时器并关窗）**：updateTimer invalidate + nil → orderOut → window/label nil——**当前无调用方（HUD 常驻，进程退出自动回收）**。

**`refresh()`（private，第 112–119 行）——刷新两行文本（等宽对齐：左列标签同宽，右侧数字同宽）**：

- `guard label, provider`；`v = provider()`
- `a/g = v.assist/game >= 0 ? String(format: "%5.1f", …) : "  -- "`——**%5.1f 定宽（右列数字同宽）**；负值显示 "--"
- **`label.stringValue = "辅助帧率 \(a)\n游戏帧率 \(g)"`——两行结构完全一致 → 天然左对齐**

**数据来源（AuroraDriveApp:1344–1353 接线）**：辅助帧率 = **主线程 tick 速率（1000 / tickGapMs）**；游戏帧率 = **ScreenCaptureKit 实际捕获到的合成帧率（captureEngine.captureFPS ≈ 游戏渲染帧率）**。

## 二、AutomationPanel 自动化面板（AutomationPanel.swift 全文 251 行）

**⚠️ 整个文件当前是死代码（grep 实测）**：`AutomationCard`（40 行）与 `AutomationDrawer`（97 行）**全项目零外部调用**——这是曾经的"右侧滑出自动化抽屉"，被 AIAgentPanel（左侧面板 + 技能统一执行通道）替代后遗留；`AutomationLibrary` 只被 AutomationDrawer 内部引用。**文件仍在 Package.swift sources 白名单（第 54 行）参与编译**——删除前需同步移除白名单条目。

**动画常量（第 6–13 行）——六个全局动画：**

| 常量 | 值 | 用途 |
|---|---|---|
| `panelAnim` | spring(0.5, 0.62) | 面板开合 |
| `toggleAnim` | = panelAnim | 开关（复用） |
| `hoverAnim` | easeOut(0.18) | 悬停 |
| `fnAnim` | spring(0.35, 0.7) | 功能行点击 |
| `itemAnim` | spring(0.46, 0.72) | 条目弹入（阶梯延迟） |
| `fadeAnim` | spring(0.42, 0.72) | 头部淡入 |

**`AutomationFunctionItem`（Identifiable，第 17–22 行）**：id（UUID）/emoji/name/**warn（高危/最凶标记，默认 false）**。

**`AutomationLibrary.functions`（static let，第 24–36 行）——MaaNTE 功能一览 9 项**：🎣 自动钓鱼 / 🥤 自动作咖啡 / 🐾 **粉爪大劫案（warn=true）** / 🪑 自动收家具 / 💎 自动领奖励 / 🎹 自动弹钢琴 / 🎵 自动超强音 / ⚔️ 自动闪避 / 🕛 实时辅助——**与 AgentSkillLibrary（代码-23）的 19 技能是两套独立清单**（此清单 9 项是 MaaNTE 原版功能映射，AgentSkillLibrary 是真实度标注后的执行清单）。

**`AutomationCard`（struct: View，第 40–93 行）——侧边栏底部触发卡（AUTOMATION，⚠️ 死代码）**：

- `@Binding open: Bool` + `@State hovering`
- 点击：`open.toggle()`（panelAnim）——**打开右侧抽屉**
- 渲染：🤖（**hover 发光 8**）+ "自动化"（13pt semibold cyan）+ **"9 功能" 胶囊（hover 变亮：cyan 0.12 底 + 0.5 描边）** + chevron.right（**open 时旋转 90°**）
- 背景：14pt 圆角（**hover cyan 0.08 : bgCard**）+ **渐变描边（hover 0.55 : 0.28 → 0.04 对角）** + **双层 shadow（hover 16/0.5 : 6/0.18）**——悬停沉浸光效
- onHover + help（"MaaNTE 自动化功能面板（9 项）"）

**`AutomationDrawer`（struct: View，第 97–179 行）——右侧滑出抽屉（⚠️ 死代码）**：

- `@Binding open` + `@State running = Set<UUID>()`（**运行状态按 UUID 跟踪——与 AgentSkillCenter 的 Set<String> 不同体系**）+ `@State appeared`
- **头部（106–136 行）**：青色竖条（3×12 发光）+ "自动化 · MaaNTE"（11pt bold + **tracking 2**）+ 关闭按钮（xmark，open = false）；**入场动画：opacity + offset x 30→0（fadeAnim.delay 0.02）**
- **功能列表（138–158 行）**：`ForEach(Array(functions.indices), id: \.self)` → AutomationFnButton（item/index/appeared/active: running.contains）——**点击 toggle：running 集合增删（无任何真实动作——纯 UI 占位）**
- 外框：300 宽（trailing 对齐）+ clipped + **黑 0.9 底 + 左侧渐变光带（cyan 0.5→0.08，宽 1）**；onAppear → appeared = true（panelAnim）

**`AutomationFnButton`（private struct，第 183–251 行）——抽屉内单个功能行（悬停沉浸光效 + 阶梯弹入）：**

| 参数 | 说明 |
|---|---|
| `item / index / appeared` | 功能项 / 序号（阶梯延迟用）/ 入场状态 |
| `active: Bool` | running 集合中的状态（运行中 = cyan） |
| `toggle: () -> Void` | 点击回调 |
| `@State hovered` | 悬停状态 |

- **渲染层次（193–240 行）**：emoji（17pt，hover 发光 10）+ name（13.5pt）+ **"最凶"标签（item.warn 时：danger 红字 + 0.12 底 + 0.5 描边）** + 状态点（8pt，active ? cyan 发光 8 : 白 0.18）
- 背景：13pt 圆角（**active cyan 0.10 : hovered cyan 0.08 : 白 0.04**）+ **hovered/active 时 RadialGradient 沉浸光（cyan 0.16，110 半径，clipShape）** + 描边（hovered/active 0.6 : 白 0.08）+ **三层 shadow（hover 15/0.45、active 10/0.22、hover 远层 32/0.22）**
- **阶梯弹入（246–249 行）**：`.offset(x: appeared ? 0 : 46)` + opacity + **`itemAnim.delay(Double(index) × 0.055)`——按序号逐个延迟 55ms 弹入**（九项功能从右侧依次滑入的入场动画）

**诚实标注**：AutomationDrawer 的 running 集合**只有 UI 状态翻转，无任何真实动作执行**（不像 AgentSkillCenter.run 走真实链路）——这正是它被 AIAgentPanel 替代的原因：**旧面板是"假按钮"，新面板是"真实度标注 + 统一执行通道"**。

**AutomationPanel 文档至此完整**（251 行全覆盖：动画常量 → 9 功能清单 → 触发卡 → 抽屉 → 功能行）。