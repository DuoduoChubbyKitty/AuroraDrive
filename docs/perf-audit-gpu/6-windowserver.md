# 6 · 窗口合成的 GPU 开销审计（WindowServer 45.6% 的构成与真凶隔离）

- 审计时间：2026-10-24 22:32–23:0x
- 审计对象：`/Users/dupi/Desktop/自动驾驶系统`（AuroraDrive，SwiftPM/macOS，M3 MacBook Air）
- 审计方式：**纯只读静态审计 + 仓库内既有实测记录取证**。未改任何源码、未 `swift build`、未 `./run.sh`、**未启动 App**、未跑 powermetrics。
- 用户铁律：不降质量 / 不降频 / 不砍功能 / **GPU 绝对不能占用，允许拿 CPU 换** —— 本报告只清理「纯浪费」（白了多合成、白了多提交）。
- 与其他并行报告的分工：本报告**只覆盖窗口层与合成链路**（窗口数、透明/阴影/材质、每帧驱动重绘的 `@Observable`、浮层提交）。帧内容在 CPU 侧的拷贝成本归 `perf-audit-20261024/2-cpu-hotpath.md`，此处只在「它如何变成 WindowServer 提交」这一步记账。

---

## 1. 一句话结论

**WindowServer 那 45.6% 里，绝大部分不是本 App 窗口造成的，而是「游戏自己在全屏合成」的必然底噪 —— 仓库内已有一组单因子对照实测直接证明：Aurora 关闭时 WindowServer 就是 51.2%，开启后 81.9%，把一处背景漂移动画关掉立刻回到 51.9%（`App/AuroraTheme.swift:609-620`）。**

**本 App 现在真正「白白多占」的窗口合成开销只有一处明确项（外加一处零 GPU 成本的死代码）：**
1. **主窗口预览框每 tick 无条件把整帧画面提交进 `layer.contents`**（`App/AuroraDriveApp.swift:7168-7194` + `:9035-9038`），且这条路径**没有遮挡门控**（对比插帧层 `:9120-9141` 有）。这是唯一「无新内容也照提交」的合成写入点。
2. **一处「只写不读」的 `repeatForever` 死代码**（`BrandMark`，`App/MissionConsole.swift:177/194`）—— 已复核确认变量无人读取，**不产生合成开销**，只是语义误导。
3. **背景漂移动画当前默认关闭**（`AuroraTheme.swift:682-686`），这是本仓历史上唯一被实测出「+30.7 个百分点 WindowServer」的机制；**它现在不花钱，但只要有人设 `AURORA_ENABLE_BG_DRIFT=1` 就会立刻回来。**

**5 个窗口里没有一个是透明/毛玻璃/圆角阴影大户**：主窗口被强制成**不透明、无阴影、圆角 0**（`:3869-3877`），HUD 是 168×46 的小窗且 2Hz 刷新（`GameHUDWindow.swift:55-100`），锚点窗只有 1×1（`:68-92`）。**「透明+模糊合成是 GPU 大户」在本仓不成立 —— 因为生产主界面根本没用毛玻璃**（详见 §4）。

---

## 2. 窗口全清单（问题 1：全仓几个窗口、驾驶态同时可见几个）

### 2.1 全仓窗口创建点（共 5 处生产路径 + 3 处自检夹具）

| # | 窗口 | 创建点 | 尺寸 | 层级 / 特性 | 驾驶态是否同时可见 |
|---|---|---|---|---|---|
| 1 | **主窗口**（`ContentView`） | `App/AuroraDriveApp.swift:1379` `WindowGroup{ContentView()}`，几何由 `:2322`（仅 `--fit-selftest`）与 `:3818-3900` `WindowConfigurator` 改写 | 默认 1200×760，min 880×500（`:3879`） | `.fullSizeContentView`、**强制移除 `.titled`**、`isOpaque=true`、`hasShadow=false`、圆角 0（`:3856-3877`） | **是**（用户开着辅助程序看状态就是它） |
| 2 | **GameHUDWindow**（左上角帧率 HUD） | `App/GameHUDWindow.swift:57-77` | **168×46**（`:55-56`） | `identifier="AuroraAuxHUD"`、`.screenSaver` 层级、**`isOpaque=false`**（`:64`）、`backgroundColor=black@0.28`（`:65`）、`hasShadow=false`（`:66`）、`ignoresMouseEvents`（`:67`）、`.canJoinAllSpaces+.fullScreenAuxiliary`（`:70-73`） | **是**（`DriveState` 创建即 `install()`，`:5631`） |
| 3 | **Game Mode 锚点窗** | `App/AuroraDriveApp.swift:67-99` | **1×1**（`:68`） | `identifier="AuroraAuxAnchor"`、`.floating`、**`isOpaque=false`**（`:74`）、`black@0.02`（`:76`）、`hasShadow=false`（`:77`） | **是**（启动即装，`:92`） |
| 4 | **MapWindow**（三栏大地图） | `App/MapWindow.swift:159-175` | 1280×820 设计值，按屏收缩（`:61-63`、`:93-118`） | `identifier="AuroraAuxMap"`、`.titled+.closable+...`（系统默认阴影/圆角）、`NSHostingView` 根视图（`:171`） | **默认否**（`:1418-1428` 注释：默认绝不自动开；仅 ⌘M / 按钮；`AURORA_MAP_WINDOW=1` 仅供自动化） |
| 5 | 插帧自检窗 | `App/AuroraDriveApp.swift:584` | 320×180 `MTKView` | 仅 `--upscale-selftest` | 否（自检） |

> 另 2 处 `NSWindow` 是自检夹具：`runFitSelfTest`（`:2322`，`--fit-selftest`）、`--upscale-selftest`（`:584`）。**不参与生产运行。**

**结论（问题 1）：生产全仓 = 4 个可存在的窗口（主窗口 / HUD / 锚点 / 大地图）。驾驶态「默认同时可见」= 3 个：主窗口 + HUD(168×46) + 锚点(1×1)。大地图默认关闭；用户手动打开后为第 4 个。**

### 2.2 总面积占比（回答「浮层多大、是否全屏」——问题 5）

| 窗口 | 面积（主屏 1470×956 计） | 占屏比 | 是否全屏覆盖 |
|---|---|---|---|
| 主窗口 | 1200×760 ≈ 912,000 pt² | ≈ **65%** | 否（可控尺寸，可缩到 880×500） |
| HUD | 168×46 = **7,728 pt²** | ≈ **0.55%** | 否 |
| 锚点 | 1×1 = **1 pt²** | ≈ **0.00007%** | 否 |
| 大地图（若开） | ≈ 1152×820 ≈ 944,640 pt² | ≈ **67%** | 否 |

**没有任何一个窗口是全屏覆盖的。** 三个常驻浮层合计占屏 ≈ 0.55%，其中锚点 1×1 在物理上不可见（alpha 0.02）。

> ⚠️ 未测：以上面积是按代码里的 frame 常量算的几何值，**不是**实测合成像素量。WindowServer 的合成开销与「脏区域面积 × 重绘频率」相关，不是简单面积比，故此处只作量级参考。

---

## 3. 关键判断：45.6% 的大头来自游戏，不是本 App（问题 6 的前提）

仓库内已有一组**单因子对照实测**，就在 `App/AuroraTheme.swift:609-620`，原文摘录：

> 实测确认，WindowServer 负载：**Aurora 关 51.2% → 开 81.9%（+30.7%）**。
> 单因子对照（决定性证据）：
> 　背景漂移 **开**（原状）　　　　　　WS = 81.9%
> 　背景漂移 **关**（`AURORA_DISABLE_BG_DRIFT=1`）WS = 51.9% ← 完全回到基线
> ⟹ 这**一处**就是全部原因；抓屏、四模型、HUD、静音音频、nice=-20、event tap 等所有其它因子合计只占 **0.7 个百分点**。

这段记录的三个可推出结论，对本报告至关重要：

1. **基线 51.2% 是在 Aurora 关闭（= 只剩游戏）时测的** ⟹ 用户实测的 45.6% 与之同量级，**属「游戏全屏合成」这一必然项**，不是本 App 的窗口加出来的。
2. **本 App 窗口曾贡献 +30.7 个百分点的 WindowServer 负载，根因是一处 `repeatForever` 背景漂移动画**（`AuroraTheme.swift:682`），当日已通过剥离动画修复。
3. **HUD、抓屏、event tap 等窗口/系统级因子的合计影响只有 0.7 个百分点** ⟹ 这三类即使全砍，也换不回什么；**不该在它们身上找浪费**。

> 该组数据是仓库内既有记录（2026-09-30 前后实测），**本次审计未复测**（纪律要求不启动 App）。数值口径为「WindowServer 负载百分比」，与用户本次 powermetrics 的 45.6% 是否同一算法**未核实**，故只作「量级/归因」用，不作精确对账。

**因此本报告的定位是：45.6% 中的必然项 ≈ 50%（游戏合成），可治理项必须从「本 App 让 WindowServer 多做事」的路径里找，而非从窗口数量/透明度里找。**

---

## 4. 透明 / 模糊 / 阴影 / 圆角盘点（问题 2、3）

### 4.1 `NSVisualEffectView`：全仓**零命中**

```
grep -rn "NSVisualEffectView" --include="*.swift" Sources/  →  0 处
```

### 4.2 SwiftUI 材质（`.ultraThinMaterial` 等）：代码里 2 处，但**生产主界面 0 处**

| 位置 | 内容 | 是否在运行时主界面 |
|---|---|---|
| `App/AuroraTheme.swift:349` | `RoundedRectangle().fill(.ultraThinMaterial).opacity(0.30).blendMode(.overlay)`，位于 `AuroraGlass` 修饰器 | **否** —— 全仓 `auroraGlass` **只有定义、零调用**（`grep "auroraGlass" Sources/AuroraDrive/App/` → 1 命中，即定义本身 `:378`） |
| `Agent/AIAgentPanel.swift:1933` | `AIAgentEdgeTab` 左侧边缘箭头的 `.fill(.ultraThinMaterial.opacity(0.9))` | **否** —— `AIAgentEdgeTab` 仅被 `AIAgentPanel.swift:3173/3190` 引用，而那是 `AIAgentPanelView` 的截图自检夹具；`AIAgentPanelView` 全仓只在夹具内构造（`:3110/3187`）。主界面右栏用的是 `AIChatCard`（`MissionConsole.swift:3602`），**不含材质** |

**判定：生产主界面没有毛玻璃。** 那条「透明+模糊合成是 GPU 大户」的通用经验在本仓**不适用**，因为最贵的那类材质根本没挂上去。

### 4.3 逐项核对（问题 3 要求的四个属性）

| 属性 | 主窗口 | HUD | 锚点 | 大地图 |
|---|---|---|---|---|
| `isOpaque` | **`true`**（`:3870`，显式设） | `false`（`GameHUDWindow.swift:64`） | `false`（`:74`） | 未设（系统默认 true） |
| `backgroundColor` | 不透明深色（`Color.black` 兜底 `:1384`） | `black@0.28`（`:65`） | `black@0.02`（`:76`） | 默认 |
| `hasShadow` | **`false`**（`:3869`） | `false`（`:66`） | `false`（`:77`） | **未设 → 系统默认 true**（`MapWindow.swift:159` 后无 `hasShadow` 赋值） |
| `fullSizeContentView` | **`true`**（`:3858` 强制插入） | 否（borderless 本就无标题栏） | 否 | 否 |
| 圆角 | **`layer.cornerRadius = 0`**（`:3873`） | 无（borderless 直角） | 无 | 系统窗口圆角（未关） |
| `contentView` 是否 `.clear` | 否；且 `cv.wantsLayer=true`（`:3871-3876`） | 否 | 否 | 否 |

**结论：主窗口已经是「最省合成的形态」**（不透明 + 无阴影 + 圆角 0 + 无毛玻璃）。这部分**没有可清理的浪费**。

**唯一残留的可疑项：大地图的系统默认阴影**（`MapWindow.swift:159-175` 未设 `hasShadow=false`）。系统窗口阴影需要 WindowServer 额外做一次投影模糊合成；但该窗**默认不打开**，且属于「用户主动要看地图」的功能窗，不是常驻浪费。清理它对视觉有影响（窗口边缘少一圈投影），**按用户红线默认不动**，仅在「用户手动开大地图时也想省」时作为可选项。

---

## 5. 每帧 `@Observable` 驱动整窗重绘（问题 4 —— 本次重点）

### 5.1 频率前提：现行是 **15Hz**，不是 30Hz

`AuroraDriveApp.swift:7396` 那条注释写的「tick 以 30Hz 运行」**已经过期**。真实频率：

- `Core/EngineMain.swift:771`：`static var engineTickHz: Double = 15.0`
- `App/MissionConsole.swift:6234`：`timer.schedule(deadline: .now(), repeating: 1.0 / 15.0, ...)`
- `AuroraDriveApp.swift:7410-7415` 自述：「2026-10-22 最终定档 15Hz……tick 是 15Hz（见 `EngineMain.engineTickHz`），抓屏两档也都 15fps」

⟹ 下面所有「每 tick」= **每秒 15 次**，不是 30 次。`7396` 的注释建议一并更正（仅注释，不改行为）。

### 5.2 `tick()` 内的 `@Observable` 写入全清单（`tick()` 范围 `:7046-8217`）

| 属性 | 声明 | 写入点 | 是否 `@ObservationIgnored` | 写入是否有「先比后写」 | 谁在读（失效波及） |
|---|---|---|---|---|---|
| `tickGapMs` | `:5558` | `:7049` | **是**（`:5557`） | 无（但无害） | 无 UI 读 |
| `lastTickTime` | `:5555` | `:7050` | **是** | 无 | 无 |
| `frameDeliveryLagMs` | `:5526` | `:7185` | **是**（`:5525`） | 无 | 无（诊断） |
| `currentScreenImage` | `:5192` | `:7187` | **是**（`:5192`） | 无 | 否（已改走 `frameHost` 直绘） |
| `currentFrameCG` | `:5193` | `:7188` | **是**（`:5193`） | 无 | 推理/推屏用，不触发 SwiftUI |
| `screenSize` | `:5198` | `:7190` | **否** | **有**（`if screenSize != latest.size`） | `ObstacleOverlay`/`MaskOverlay` 的 aspect-fill（`MissionConsole.swift:610/622`）→ 尺寸变化极罕见 |
| **`effectiveSpeed`** | `:5150` | `:7695-7699` | **否** | **无**（无条件算 + 无条件写） | `driveBars.speed`（`ControlWiring.swift:309`）→ `ControlRows`（`MissionConsole.swift:3738-3751`）、`DecisionRail` 状态向量（`:5666-5670`） |
| `speedValid` | `:5154` | `:7693` | 否 | **有**（`if speedValid != ocrFresh`） | TopBar「车速」`:130-133` |
| `fps` | `:5160` | `:7701` | 否 | **有**（`if fps != newFPS`） | **TopBar 「游戏帧率」`MissionConsole.swift:128`** |
| `mode` | `:5073` | `:7748` | 否 | **有**（`if mode != decided`） | TopBar/RCBar/GearRing/DecisionRail 多处 |
| `confidence` | `:5076` | `:7761/7773` | 否 | **有** | 决策电路读数 `:5663` |
| `detectedBoxCount` | `:5388` | `:7776` | 否 | **有**（`if detectedBoxCount != boxCount`） | **`RCBar`（`MissionConsole.swift:6182`）** → 整条 RCBar 失效 |
| **`bodyHeadingDeg` / `bodyHeadingConf`** | `:4398/4400` | `:7448-7452` | **否** | **无**（读到就写，读不到就写 nil/0） | 小地图罗盘箭头 `MissionConsole.swift:1858/2050-2055` |
| **`currentCommand`** | `:6017` | `:7989-7995`、`:8003-8009` | **否** | **无**（直接改 `.steer/.throttle` 子字段） | `KeyBar` 真实按键态 `MissionConsole.swift:524` |
| `needsManualIntervention` | `:5419` | `:7726/7732` | 否 | **有**（边沿触发，罕见） | `StuckWarn` `MissionConsole.swift:706` |
| `frames` | `:5186` | `:7375`（字模录制）、`:8283`（录制） | 否 | 无 | `DecisionRail`「累计帧」`:5682` |

**纯 `@ObservationIgnored`（零 SwiftUI 失效）的已优化项：`tickGapMs` / `lastTickTime` / `frameDeliveryLagMs` / `currentScreenImage` / `currentFrameCG`，以及 `:5325-5340` 记录的 `upscaleLive` / `upscaleEngineError`。这说明「先比后写 + ObservationIgnored」这套优化此前已做过一轮。**

### 5.3 仍然每 tick 无条件写的三个（真正的漏网项）

| 属性 | 代码证据 | 每 tick 行为 | 波及的视图树 |
|---|---|---|---|
| **`effectiveSpeed`** | `:7695-7699` 三条分支全部直接赋值（`+=`、`*=`、`= 0`），**无先比后写** | 15Hz 必然写入（OCR 读数每帧都在抖，值几乎必变） | `driveBars` → `ControlRows`（5 行条状图）+ `DecisionRail` 6 分量状态向量。**`MainGrid` 的左栏每 tick 重算 body** |
| **`bodyHeadingDeg`/`bodyHeadingConf`** | `:7448-7452`，`if pointerReader.isAvailable, adaptiveFrameCounter % 3 == 0` → **5Hz**（`:7445-7447` 自述「降到 5Hz」） | 5Hz 写入（不是 15Hz） | 小地图罗盘箭头（`MiniMapCard` 内） |
| **`currentCommand`** | `:7989-7995` 直接改子字段（`currentCommand.steer = ...`）；`:8003-8009` 同 | 15Hz 写入（控制量每帧都在变） | `KeyBar.isActive()`（`MissionConsole.swift:521-534`）→ KeyBar 4 个按键高亮重算 |

**为什么这些是「真浪费」而不是「必要」：**

- `effectiveSpeed` 是**控制量本身**（喂 `RuleController`/决策），**必须每帧更新** —— 这一点不浪费。**浪费的是它同时被当成 UI 数据源**：`ControlRows` 的 5 根条和 `DecisionRail` 的状态向量以 15Hz 跟着抖。用户在驾驶态根本不会盯着这几根条看 15Hz 的细微变化。
- `currentCommand` 同理：**控制必须每帧下发**，但 `KeyBar` 的「哪个键在按」只需人眼可辨的频率（例如 15Hz→2-3Hz 显示刷新不影响任何判断）。
- `fps`/`detectedBoxCount`/`mode`/`confidence`/`speedValid` **已经做了先比后写**，属已优化项。但注意：`fps` 只要游戏帧率有 ±0.1 抖动就会变 → **实际仍是「几乎每 tick 都变」**，因为 `captureEngine.captureFPS` 是真·实测值，不是整数。

### 5.4 关键结论（问题 4）

> **是的，「每帧 `@Observable` 变化驱动整窗重绘」确实存在，但驱动源不是某个周期性脏标记，而是三组真实在变的语义数据：`effectiveSpeed`（15Hz）、`currentCommand`（15Hz）、`fps`（≈15Hz，值是浮点实测帧率）、`bodyHeading*`（5Hz）。**
>
> 它们各自的失效范围都落在**主窗口内部的具体子树**（TopBar / RCBar / KeyBar / LeftColumn），**不是整窗** —— SwiftUI 的观察粒度是「读了这个属性的 view」，不是整个 `ContentView`。但 `TopBar` 是整个 `VStack` 的第一层，其 body 失效会连带**同一 VStack 内的 `RCBar` + `MainGrid` + `KeyBar` 一起重算布局**（`MissionConsole.swift:6176-6197` 的结构：全部平级在同一个 `VStack` 里）。
>
> **这才是那 45.6% 里「本 App 可治理」的主通道**：每 66ms 一次的主窗口布局重算 + 随之而来的脏区域重合成，而不是窗口数量、透明度或毛玻璃。

---

## 6. 每帧重提交的浮层（问题 5）

### 6.1 `FrameHost.push` —— 唯一「无门控的每 tick 合成写入」

```swift
// App/AuroraDriveApp.swift:9035-9038
func push(_ image: CGImage) {
    cachedCGImage = image
    hostView?.layer?.contents = image      // ← 这一步进 WindowServer 合成路径
}
```

- 调用点：`:7168-7194`，`if let cg = latestCGToPush { frameHost.push(cg) }`，`latestCGToPush` 仅在 `if isStreaming` 时非空（`:7189`）。
- `isStreaming` 在抓屏 `.started` 时置 true（`:6201`），`.stopped/.error` 置 false（`:6214`）。
- **无遮挡门控**：`FrameHost` 里没有 `occlusionState` 判断（全仓 `occlusionState` 只出现在 `:9127` 的 `UpscaleFrameHost` 和 `:623` 的自检打印里）。
- 帧尺寸：抓屏 `targetW=1280`，高按屏比算（`Capture/CaptureEngine.swift:604-618`，3:2 → 832）⟹ 每帧约 **1280×832×4 ≈ 4.26 MB**（`config.pixelFormat = 32BGRA`，`:624`）。
- 显示区域：`ViewportPanel` 在左栏，`MainGrid` 里左栏 `maxWidth:.infinity`（`MissionConsole.swift:546-547`），实际可用宽度 ≈ 1200 − 344 − 372 − 内边距 ≈ **450pt 宽**。

**浪费点**：即使预览面板被其它窗口完全遮挡、或用户把主窗口最小化/切到别的 Space，只要 `isStreaming` 仍为 true，`layer.contents` 依然每 tick 被赋一张 4.26 MB 的新图 —— **WindowServer 必须为此重新合成那块区域**。

> 对照：插帧层 `UpscaleFrameHost` **有**遮挡门控（`:9120-9141`，监听 `didChangeOcclusionState` / `didMiniaturize`，`view.isPaused = !visible`），注释自述「MTKView 默认 60fps 常开渲染，即使被完全挡住……GPU/CPU 也在全速空转」。**同一份洞察，只应用到了一半。**

### 6.2 常驻 `repeatForever` 动画复核（逐处确认变量是否真被消费）

| 位置 | 动画 | 触发条件 | 视觉作用 |
|---|---|---|---|
| `AuroraTheme.swift:682`（`AuroraLightField`） | `.easeInOut(duration: 26).repeatForever` 驱动 `drift` | `.onAppear` 读 `AURORA_ENABLE_BG_DRIFT == "1"` 才置 true（`:684-686`），**默认 false** | 三团高斯模糊光斑的缓慢漂移 |
| `MissionConsole.swift:194`（`BrandMark`） | `.linear(duration: 9).repeatForever` 驱动 `spin` | `onAppear` 即启动，**永不停止** | **无**（见下） |

- `AuroraLightField` 的漂移**默认已关闭**，且注释 `:609-620` 记录了它就是当初 +30.7 个百分点的唯一根因。**现状是安全的**，但注意：它是**条件动画**，一旦有人设 `AURORA_ENABLE_BG_DRIFT=1`，那 +30.7 个百分点立刻回来。

**`BrandMark` 的 `spin` 已复核确认：是一个「只写不读」的死变量。**

```
MissionConsole.swift:177   @State private var spin = false
MissionConsole.swift:194   withAnimation(.linear(duration: 9).repeatForever(...)) { spin = true }
```
`grep -n "spin" Sources/AuroraDrive/App/MissionConsole.swift` 全文件仅 5 处命中：`:177`（声明）、`:194`（写入），以及 `:5300/5325/5376`（那是**另一个无关组件**的 `spin: Double`，被 `:5325` 的 `rotationEffect` 正常消费）。**`BrandMark` 的 `body`（`:174-196`）内没有任何地方读 `spin`。**

**⟹ 结论修正（重要）：这个 `repeatForever` 不会造成逐帧 WindowServer 重绘** —— SwiftUI 只对「被 `body` 观察到的 `@State`」建立依赖；无人读取的 `spin` 变化不会让 `BrandMark.body` 失效，也就不产生合成。**它属于「死代码 / 语义误导」级的浪费（白起了一个永不停止的动画事务），不是合成开销。**

> 这一条我先前误判为「可能是最大单点浪费」，复核后**撤回**。保留在此是为了说明「为什么不能看到 `repeatForever` 就断定是合成大户」——必须逐处确认变量是否真的被消费。顺带仍建议清理（见 §8 ②），理由是死代码会误导后来者按「它在转」去估算成本。

### 6.3 条件动画（不在驾驶态常态运行，列出以免误伤）

- `RCWarn` 脉冲（`MissionConsole.swift:1442`）、`StuckWarn`（`:1487`）、`EmergencyBanner`（`:1556`）：均 `.onAppear` 启 `repeatForever`，但仅在「路况极度复杂 / 卡死 / 应急接管」时挂载 —— **不是常态**，且这些恰恰是**最需要视觉注意**的时刻，砍掉有安全风险。**不建议动。**
- 规划中遮罩的转圈（`:5373-5381`）：仅路线规划期间存在，属瞬时。

---

## 7. 判定（问题 6）：45.6% 里哪些必然、哪些白占

### 7.1 必然占用（不该动）

| 项 | 依据 | 占比判断 |
|---|---|---|
| **游戏全屏窗口自身的合成** | `AuroraTheme.swift:609-620` 单因子对照：Aurora 关闭（只剩游戏）时 WS 已是 **51.2%** | **本 App 45.6% 里的绝大部分**（同量级） |
| 主窗口重算布局带来的必要脏区域合成 | 用户在驾驶态确实要看 TopBar / KeyBar / 状态 | 少量，且与「看得见的功能」绑定 |
| 主窗口画面预览的帧提交 | 用户要看实时画面（这是产品核心） | 必要 —— **但「被遮挡时也提交」的部分是白占**，见下 |

### 7.2 白白多占（可清理，按收益排序）

| # | 浪费 | 位置 | 每帧/每秒成本（估算，未实测） | 质量影响 |
|---|---|---|---|---|
| **①** | 预览帧**被遮挡/最小化时仍每 tick 提交** `layer.contents` | `:7168-7194` + `:9035-9038`（无遮挡门控） | 15Hz × 4.26 MB 图层内容提交（**仅在被遮挡期间**） | **零**（看不见时本就不需要出新图；重新可见时下一 tick 立刻补上） |
| **②** | `BrandMark` 的 `repeatForever` 驱动一个**只写不读**的死变量 | `MissionConsole.swift:177/194`（全文件仅此 2 处，body 零读取） | **不产生合成开销**（无人观察的 `@State` 不触发 body 失效）⟹ 只算死代码，**不计入 GPU 账** | **零**（画面逐像素不变） |
| **③** | `effectiveSpeed`（15Hz）连带 `ControlRows` 5 根条 + `DecisionRail` 状态向量重算 | `:7695-7699` 写 + `MissionConsole.swift:3738/5666` 读 | 15Hz × 左栏子树布局（**估算，未测**） | **极低但非零**：条状图会从 15Hz 平滑变 2-3Hz 阶梯 —— **按用户红线，此项不默认执行**，见 §8 |
| **④** | `currentCommand`（15Hz）连带 `KeyBar` 4 键高亮重算 | `:7989-7995` 写 + `MissionConsole.swift:521-534` 读 | 15Hz × KeyBar 子树 | **极低但非零**：按键高亮从 15Hz 变 2-3Hz。同上，**不默认执行** |
| **⑤** | 大地图窗口系统默认阴影 | `MapWindow.swift:159-175`（未设 `hasShadow=false`） | 仅用户手动开地图时；一次投影模糊 | **有**（窗口边缘少一圈投影）→ **不建议动** |
| ⑥ | HUD 半透明底（`isOpaque=false`） | `GameHUDWindow.swift:64-65` | 168×46 @ 2Hz = **每秒 2 次**小区域 | **有**（改不透明会变成一块实心黑，破坏 HUD 悬浮观感）→ **不建议动** |

### 7.3 明确「不该动」的账

- **`isOpaque=false` 的 HUD / 锚点窗**：面积合计 0.55%，刷新 2Hz（锚点无刷新），`AuroraTheme.swift:614-615` 已实测「HUD 等因子合计仅 0.7 个百分点」。**动它是拿视觉换噪声。**
- **毛玻璃**：生产路径根本没有（§4.2）。
- **`fullSizeContentView` / `cornerRadius=0`**：主窗口早已是最省形态（§4.3）。

---

## 8. 建议（每条标注视觉影响，遵守用户红线）

> 总原则：**只清「白了多合成」的部分，不碰任何可见像素的形状/颜色/尺寸/刷新观感**。凡会改变观感的，一律标为「需用户明确同意」。

### ①【建议执行 · 收益最大 · 零视觉影响】给 `FrameHost` 补遮挡门控，与插帧层对齐

- **改什么**：`App/AuroraDriveApp.swift:9022-9058`（`FrameHost`）增加 `NSWindow.didChangeOcclusionStateNotification` / `didMiniaturize` / `didDeminiaturize` 监听（**照抄 `UpscaleFrameHost.installOcclusionGuard` `:9118-9141` 的现成实现**，不引入新模式）；窗口不可见时 `push()` 只更新 `cachedCGImage`、**不写 `layer.contents`**，重新可见时补一次。
- **为什么这是纯浪费**：被完全遮挡的窗口，其内容 WindowServer 不会显示给任何人。此时提交 4.26 MB 新的图层内容，是「为零个观看者准备的画面」。同仓 `UpscaleFrameHost` 注释已把这条道理写清楚（`:9108-9111`：「MTKView 默认 60fps 常开渲染，即使被完全挡住……也在全速空转」）。
- **视觉影响：零。** 不可见期间用户看不到任何东西；重新可见时最多延迟 **1/15 秒（66ms）** 出一帧，且 `cachedCGImage` 已是最新帧，实际感知不到。
- **预期收益（估算，未实测）**：仅在被遮挡/最小化期间免掉 15Hz × 4.26 MB 的合成提交。**驾驶态主窗口可见时收益为 0** —— 所以这条**不是**解决 45.6% 的主力，但它是零风险的纯浪费清理。
- **风险**：极低（同仓已有等价实现可抄）。

### ②【已复核 · 零 GPU 成本 · 零视觉影响】`BrandMark` 的 `repeatForever` 是死代码

- **复核结论（已确认，非推测）**：`MissionConsole.swift:177` 声明 `@State spin`、`:194` 在 `onAppear` 里用 `repeatForever` 驱动它，但 `body`（`:174-196`）**零读取**。全文件 `spin` 的另 3 处命中（`:5300/5325/5376`）属于**另一个组件**的 `spin: Double`，与 `BrandMark` 无关。
- **改什么**：删掉 `:177` 的 `@State spin` 与 `:193-195` 的 `.onAppear {...}`（两处，共 3 行）。
- **视觉影响：零** —— 变量无人消费 ⟹ 删掉后画面逐像素不变。
- **GPU 收益：无。** 必须说清楚：无人观察的 `@State` 不会让 `body` 失效，所以它**本来就没在烧合成**。这条的价值是「清死代码 + 阻止后来者按『它每秒转 6.7 圈』去误估成本」，**不是性能收益**。
- **它为什么仍然值得做**：`AuroraTheme.swift:583-585` 与 `:609-620` 两处记录都指向同一教训 —— 全仓曾因 `repeatForever` 实测出 +30.7 个百分点。把最后一处「开机就起、永不停止」的 `repeatForever` 清掉，能让「全仓没有无主常驻动画」这条约束**可被 grep 验证**，避免下一次真的挂上一处会被消费的常驻动画。

### ③【需用户明确同意 · 不在本次执行范围】把「控制用」与「显示用」的频率解耦

- **对象**：`effectiveSpeed`（→ `ControlRows` 5 根条 + `DecisionRail` 状态向量）与 `currentCommand`（→ `KeyBar` 4 键高亮）。
- **做法**：控制量照旧每帧算（那是驾驶正确性，**一个字不能动**）；只给 UI 读的那份加一层「显示节流」（例如 3Hz），或用独立的 `displaySpeed` 属性承接。
- **视觉影响：低但非零** —— 条状图/按键高亮会从 15Hz 平滑变化变成 3Hz 阶梯。虽然在驾驶态几乎看不出，但**这确实是一处观感变化**，按用户红线「不允许降质量」的精神，**必须用户明确点头才做**。
- **我的建议**：**先不做**。收益（左栏子树布局重算频率）与风险（用户对细节零容忍，`AuroraTheme.swift:355/445` 记录过「哪怕颜色是 `.clear` 也会让 SwiftUI 渲进离屏层」这类细节坑）不匹配。

### ④【不建议执行】大地图阴影 / HUD 半透明底

- 前者仅用户手动开窗时一次性成本且属功能窗；后者 168×46 @ 2Hz，`AuroraTheme.swift:614-615` 实测「HUD 等因子合计 0.7 个百分点」。
- **视觉影响：两者都有**（少一圈投影 / HUD 变实心黑块）。**按红线不动。**

### ⑤【顺带更正，只改注释不改行为】`:7396` 的「30Hz」已过期

- 现行 tick 是 **15Hz**（`EngineMain.swift:771`、`MissionConsole.swift:6234`、`AuroraDriveApp.swift:7410-7415`）。那条注释若不改，会持续误导后来者按 30Hz 估算成本（本报告 §5.1 已按 15Hz 重算）。

---

## 9. 未测 / 无法确认的事项（诚实清单）

1. **那 45.6% 中本 App 份额的精确拆解** —— 本次未启动 App、未跑 powermetrics，无法把 WindowServer 的 CPU 时间按窗口归属。§3 的 51.2%/81.9% 来自仓库内既有实测记录，**与用户本次采样是否同口径未核实**。
2. **`layer.contents` 赋值在 M3 上的单次成本** —— 仓库注释提到过「该调用可能阻塞几十~几百 ms」（`AuroraDriveApp.swift:7159-7166`），但那是**游戏全屏 + WindowServer 饱和时**的极端值，非稳态均值。15Hz 下的真实平均成本未测。
3. **【已复核，移出未测清单】** ~~`BrandMark.spin` 是否被消费~~ —— 已确认**只写不读**（`MissionConsole.swift:177/194`，body 零读取），故不产生合成开销。详见 §6.2。
4. **`ControlRows` / `KeyBar` 子树重算的真实耗时** —— 未采样，§7.2 ③④ 的成本为估算。
5. **`ScreenCaptureKit` 抓屏本身对 WindowServer 的负载** —— 用户前提假设它不占 GPU（ScreenCaptureKit 走独立通道），**本报告未验证**；但 `AuroraTheme.swift:614-615` 的对照实测里「抓屏」被归入「合计仅 0.7 个百分点」的那一组。
6. **GPU 活跃驻留 36.4% 的成分归属** —— 本报告只审计窗口合成链路，**未把 36.4% 归因到任何具体进程**。特别是「GPU 压在 338MHz / 18.9%」这个特征与「高频次小块提交」吻合，但**未证实**这些小块来自 WindowServer 合成还是来自 Aurora 自己的 CoreML/Metal 路径（那是 `3-compute-units.md` 与引擎侧报告的职责）。

---

## 10. 附：本报告引用的关键事实索引

| 结论 | 文件:行 |
|---|---|
| WindowServer 基线 51.2% / 开启 81.9% / 关漂移 51.9% 的单因子对照 | `Sources/AuroraDrive/App/AuroraTheme.swift:609-620` |
| 同一结论的第二次记录（`repeatForever` 让 WS 51.2% → 81.9%） | `Sources/AuroraDrive/App/AuroraTheme.swift:583-585` |
| 漂移默认关闭（`AURORA_ENABLE_BG_DRIFT` 才开） | `Sources/AuroraDrive/App/AuroraTheme.swift:684-686` |
| 现行 tick = 15Hz（引擎侧） | `Sources/AuroraDrive/Core/EngineMain.swift:771` |
| 现行 tick = 15Hz（UI 侧定时器） | `Sources/AuroraDrive/App/MissionConsole.swift:6234` |
| 过期注释「tick 以 30Hz 运行」 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7396` |
| `FrameHost.push` 无门控写 `layer.contents` | `Sources/AuroraDrive/App/AuroraDriveApp.swift:9035-9038` |
| `frameHost.push` 调用点（每 tick） | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7168-7194` |
| `UpscaleFrameHost` **有**遮挡门控（可抄的实现） | `Sources/AuroraDrive/App/AuroraDriveApp.swift:9118-9141` |
| 主窗口强制不透明/无阴影/圆角 0 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:3869-3877` |
| HUD 168×46、半透明、2Hz、无阴影 | `Sources/AuroraDrive/GameHUDWindow.swift`（`App/GameHUDWindow.swift:55-100`） |
| 锚点窗 1×1、alpha 0.02 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:68-92` |
| 大地图窗口（系统默认阴影未关） | `Sources/AuroraDrive/App/MapWindow.swift:159-175` |
| 大地图默认不自动打开 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:1418-1428` |
| `AuroraGlass` 材质零调用 | `Sources/AuroraDrive/App/AuroraTheme.swift:349`（`auroraGlass` 定义 `:378`，调用 0 处） |
| `ultraThinMaterial` 仅在自检夹具 | `Sources/AuroraDrive/Agent/AIAgentPanel.swift:1933` |
| 抓屏 1280×按屏比、32BGRA | `Sources/AuroraDrive/Capture/CaptureEngine.swift:604-624` |
| `effectiveSpeed` 无条件每帧写 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7695-7699` |
| `currentCommand` 每帧改子字段 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7989-7995` |
| `fps` 先比后写 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7700-7701` |
| `detectedBoxCount` 先比后写 | `Sources/AuroraDrive/App/AuroraDriveApp.swift:7775-7776` |
| `driveBars` → `ControlRows` / `DecisionRail` 读取 | `Sources/AuroraDrive/App/ControlWiring.swift:309`、`Sources/AuroraDrive/App/MissionConsole.swift:3738/5666` |
| `KeyBar` 读 `currentCommand` | `Sources/AuroraDrive/App/MissionConsole.swift:521-534` |
| `TopBar` 读 `fps` | `Sources/AuroraDrive/App/MissionConsole.swift:127-129` |
| `RCBar` 读 `detectedBoxCount` | `Sources/AuroraDrive/App/MissionConsole.swift:6182` |
| `BrandMark` 的 `repeatForever` | `Sources/AuroraDrive/App/MissionConsole.swift:194` |
| 主界面 VStack 结构（TopBar/RCBar/MainGrid/KeyBar 平级） | `Sources/AuroraDrive/App/MissionConsole.swift:6176-6197` |
