# 代码-28 GameHUDWindow 帧率浮层 与 AuroraTheme 主题令牌

---

## ♻️ 引用方式已改为符号级（2026-10-18 收尾批次）

> `AuroraDriveApp.swift` 的 HUD 安装逻辑已按当前源码逐条重测：`--engine` 模式不装 HUD 的守卫是 `if !CommandLine.arguments.contains("--engine")`，其内的诊断开关是 `AuroraFlags.disableHUD`（读 `AURORA_DISABLE_HUD`）。原文档把相邻两行混为一处，已按真实符号修正，未决 0。
>
> | 引用项 | 当前源码位置 | 复核 |
> |---|---|---|
> | `let gameHUD = GameHUDWindow()` | `DriveState` 类体内 | ✅ |
> | `DriveState.init()` | `DriveState` 声明处 | ✅ |
> | `gameHUD.fpsProvider` 赋值 | `DriveState` 初始化段 | ✅ |
> | `AURORA_DISABLE_HUD` 块 | `AuroraFlags.disableHUD` / `hudDisabled` 分支 | ✅ |
> | `--engine` 守卫 | `if !CommandLine.arguments.contains("--engine")` | ✅ |
> | `gameHUD.install()` | `DriveState.init()` 的 `else` 分支 | ✅ |
> | `DriveState` 类声明 | `@Observable final class DriveState` | ✅ |
>
> 下方 §A 的旧版漂移史已改为符号级引用；当前结论以本节为准。
>
> `GameHUDWindow.swift` 与 `AuroraTheme.swift` 的符号（类型 / 方法 / 属性 / 枚举 case）均已逐条核实，名称级引用不受源码行数变化影响。

---

## ✅ 2026-10-18 复核（本次改了什么）

> 复核人：infer-reader · 方法：逐条 `read` 源码核对语义（不只查行号存在）· **只改文档，未动 Sources/**

### A. 旧版行号漂移（已改为符号级引用）

上一版用 `AuroraDriveApp.swift` 的行号记录 HUD 安装逻辑，源码增长后多处失真。现已全部改用源码里真实存在的符号：

| 引用项 | 当前源码符号 |
|---|---|
| `gameHUD` 实例声明 | `DriveState` 内的 `let gameHUD = GameHUDWindow()` |
| `DriveState.init()` | `DriveState.init()` |
| `gameHUD.fpsProvider` 赋值 | `gameHUD.fpsProvider` |
| `AURORA_DISABLE_HUD` 块 | `AuroraFlags.disableHUD` / `hudDisabled` |
| `--engine` 守卫 | `if !CommandLine.arguments.contains("--engine")` |
| `gameHUD.install()` | `GameHUDWindow.install()` |

> `DriveState` 的类声明是 `@Observable final class DriveState`；上述符号均可在 `AuroraDriveApp.swift` 中检索到。

### B. 语义错误（不只行号）

| # | 文档原述 | 源码实际 | 处理 |
|---|---|---|---|
| R1 | 「`GameHUDWindow.swift` 头注释；`.screenSaver` 实际赋值」 | `GameHUDWindow.install()` 里的 `win.level = .screenSaver` ✅ 正确 | 无需改 |
| R2 | 「`uninstall()` 零调用（全仓仅 `GameHUDWindow` 有定义）」 | `GameHUDWindow.uninstall()` 定义存在；`grep -rn "uninstall()" Sources/` 确认**零调用点** | 无需改（结论仍成立） |
| R3 | 「`RoadCondition` enum 在 `AuroraTheme.swift`」 | `enum RoadCondition` 定义在 `AuroraTheme` ✅ 正确 | 无需改 |
| R4 | 「`radiusCard` 定义在 `AuroraTheme.swift`」 | `Aurora.radiusCard` 定义在 `enum Aurora` ✅ 正确 | 无需改 |
| R5 | 「`Color.init(hex:alpha:)` 在 `extension Color`」 | `extension Color` 的 `init(hex:alpha:)` 存在 | 无需改 |

### C. 已确认仍然准确（未改动）

- `GameHUDWindow` 与 `AuroraTheme` 的类型 / 方法 / 属性符号均已核实。
- 双重用途（实用 + 对抗 Game Mode）、关键实现四条（`win.level = .screenSaver` / `.fullScreenAuxiliary` / `win.ignoresMouseEvents` / 绿字黑底）—— 与源码头注释逐字吻合。
 - `AuroraSilver` 银白令牌组：`enum AuroraSilver` 定义于 `AuroraTheme`，10 个令牌 `AuroraSilver.core` / `AuroraSilver.scrim` / `AuroraSilver.scrimHi` / `AuroraSilver.stroke` / `AuroraSilver.glowNear` / `AuroraSilver.glowFar` / `AuroraSilver.textName` / `AuroraSilver.textDim` / `AuroraSilver.hair` / `AuroraSilver.radius`——**与正文表格所列逐个吻合，无需订正** ✅
 - 辉光实测修正注释（白底对比度 1.57:1 → 改深色玻璃）在 `enum AuroraSilver` 头注释里 ✅ 语义准确。

### D. ⚠️ 待确认（需产品决策）

> **QuestCard 辉光实现（`QuestCard` 内的 `.fill(AuroraSilver.glowNear)` / `.blendMode(.plusLighter)` / `.fill(AuroraSilver.glowFar)`）本次已按符号核实。**
> 这些名字在 `MissionConsole.swift` 中均可检索到；行号不再作为引用依据。

---

> ✅ 2026-10-17 复核：正文中的 App 侧引用已改为符号级（`DriveState.init()` / `gameHUD.install()` / `--engine` 守卫 / `AuroraFlags.disableHUD` / `gameHUD.fpsProvider` / `let gameHUD = GameHUDWindow()`）；MissionConsole 侧的辉光引用也已改为符号级。覆盖源文件 `GameHUDWindow.swift` / `AuroraTheme.swift` 不变。
> ✅ **文件名已修正（2026-10-17）**：原名中的 `AutomationPanel` 已在 UI 大改版删除（`grep -rn "AutomationPanel" Sources/` 零命中），本文已改名为 `代码-28-GameHUDWindow与AuroraTheme.md`，与内容一致。
>
> 覆盖源文件：`Sources/AuroraDrive/App/GameHUDWindow.swift` + `Sources/AuroraDrive/App/AuroraTheme.swift`。
> 行数会随源码变更漂移，本文已全部改用类型 / 方法 / 属性 / 枚举 case 名称引用，不再以行数或行号作为定位依据。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `GameHUDWindow.swift` + `App/AutomationPanel.swift`——**`AutomationPanel` 已在 UI 大改版中删除（该类型在 `Sources/` 已不存在，属已删除的历史名，仅作留痕）**（其"驾驶开关/状态"职责由 MissionConsole 的 AutomationBigButton + RunStatusCard 承载，自动化技能入口由 SkillOverlay 承载）。本档现补上同为大改版产物的 AuroraTheme（全项目视觉令牌的唯一权威源）。

## 一、GameHUDWindow 帧率 HUD（全文实现）

**双重用途（`GameHUDWindow` 头注释）**：
1. **实用**：游戏全屏时实时显示两行数据——「辅助帧率（AuroraDrive 处理帧率）」+「游戏帧率（ScreenCaptureKit 实际捕获合成帧率）」，**用来判断 Game Mode 是否在压制本进程（掉到个位数 = 被压制）**
2. **对抗 Game Mode**：一个持续可见的真实窗口比 1×1 隐形锚点更难被 gamepolicyd 归入「无可见窗口的纯后台」桶

**关键实现（`GameHUDWindow.install()` 内）**：
- `window.level = .screenSaver`——压过游戏全屏窗口
- `collectionBehavior 含 .fullScreenAuxiliary`——游戏进全屏 Space 后依然可见
- `ignoresMouseEvents = true`——**绝不拦截游戏操作**
- 绿色等宽字 + 半透明黑底——任何画面上可读

**接口**：`fpsProvider: (() -> (assist: Double, game: Double))?`（调用方注入取值闭包，避免依赖具体引擎内部）；`isInstalled`（window != nil）；`debugState`（诊断字符串：visible/level/frame）。

**引用关系（按当前源码核实）**：实例 `let gameHUD = GameHUDWindow()`（在 `DriveState` 类体内）；安装调用方 = `DriveState.init()`，调用 `gameHUD.install()`；**`--engine` 模式下不装**（`if !CommandLine.arguments.contains("--engine")`），另有 `AuroraFlags.disableHUD`（`AURORA_DISABLE_HUD=1`）诊断开关跳过安装；`gameHUD.fpsProvider` 唯一赋值方在 `DriveState`；`GameHUDWindow.uninstall()` 零调用（全仓仅定义，无卸载路径，与旧版一致）。

## 二、AuroraTheme 主题令牌（UI 大改版新增）

**这是什么**：任务控制中心全部视觉规范的**唯一权威源**——从网页原型 CSS 变量逐一等价翻译（`--void`/`--s0..--s3`/`--ice`/`--txt` 等），任何 MissionConsole 子视图取色只准从这里取，**禁止散落硬编码色值**。

**`Color.init(hex:alpha:)`（`AuroraTheme.swift` 的 `extension Color`）**：`0xRRGGBB` 字面量构造（比 Color(red:green:blue:) 好读）。

**`enum Aurora` 令牌总表（AuroraTheme.swift 起）**：

| 组 | 令牌 | 值 | 网页对应 |
|---|---|---|---|
| 底色 | `void` | 0x03060B 不透明 | --void（纯黑阶梯最底） |
| 底色 | `s0/s1/s2/s3/s4` | 0x080F1A@0.55 → 0x1A2A44@0.96 | --s0..--s3（越往上越实） |
| 玻璃 | `glass/glassFill/glassFill2/glassSolid` | 冰蓝调半透 | **黑色不透明玻璃质感**——无奶白/泛白感（用户 9-21 拍板） |
| 发丝线 | `hair1..hair4` | 0x8CBEFF @ 0.10/0.17/0.28/0.42 | --hair 系列（极细描边） |
| 主强调 | `ice/iceLo/iceHi/iceGlow/iceWash` | 0x4CC9FF 系列 | --ice（冰蓝发光） |
| 语义 | `ok`(0x34E5AA) / `amber`(0xFFB648) / `danger`(0xFF5468) / `violet`(0xA98BFF) | 绿/橙/红/紫 | 状态色 |
| 文字 | `t1..t4` | 0xE9F3FF @ 1.0/0.62/0.36/0.20 | --txt 四级对比度（高对比，拒绝发灰） |
| 圆角 | `r1..r4` | 8/12/15/20 | — |
| 字体 | `mono(_:_)` / `sans(_:_)` / `label(_:)` | 等宽/无衬线/全大写小标签 | HUD 数字用 mono |

**`RoadCondition` enum（`AuroraTheme.swift` 内定义）**：路况自适应 6 档状态机（`.simple` / `.easy` / `.medium` / `.busy` / `.extreme` / `.off`），`String/CaseIterable/Identifiable/Sendable`——**定义在 AuroraTheme 是刻意的**：路况的核心用途是"状态色驱动全局"，enum 与视觉档位绑定。判定阈值/自动限速在 `ControlWiring` 的 `AutoRoadCondition`（见代码-29）。

**给别的 AI 的铁律提示（用户原话级约束）**：
1. **视觉要求极高**——"非常高级"、反复抠细节、往死里抠细节
2. 偏好：空间感光斑、高对比度、纯深色背景加极淡网格的玻璃拟态；**拒绝低对比度发灰毛玻璃**
3. 毛玻璃必须**黑色不透明、没有奶白/泛白感**、能感觉到是玻璃质感
4. 改任何视觉先看网页原型（ui-prototypes/A-任务控制中心.好版备份-224710.html），不凭感觉调

## 二-A、AuroraSilver 银白令牌组（2026-10-06 复核块，QuestCard 专用）

> `enum AuroraSilver`（`AuroraTheme.swift` 内定义）——任务卡片（`QuestCard`）的银白配色令牌，与 `Aurora` 冰蓝体系分立。头注释记录设计规则：深色玻璃底 + 两层辉光 + 描边 0.62（不拉满 1.0 免得刺眼）。

| 令牌 | 值 | 出处 | 用途 |
|---|---|---|---|
| `AuroraSilver.core` | 0xF2F6FF 不透明 | 主银白 |
| `AuroraSilver.scrim` | 0x05080F α0.78 | 卡片底（深色玻璃，**不是白玻璃**） |
| `AuroraSilver.scrimHi` | 0x121A26 α0.72 | 卡片底顶部略亮（玻璃方向感，仍是暗色） |
| `AuroraSilver.stroke` | 0xF2F6FF α0.62 | 1px 银线描边（不要调到 1.0） |
| `AuroraSilver.glowNear` | 0xF2F4F8 α0.50 | 辉光近层（取值避开偏蓝的 0xEAF2FF，B−R 控制在个位数） |
| `AuroraSilver.glowFar` | 0xE8ECF2 α0.26 | 辉光远层（兼任务名文字柔光 shadow 色） |
| `AuroraSilver.textName` | 0xF6F8FC | 任务名文字 |
| `AuroraSilver.textDim` | 0xE4E9F2 α0.78 | 距离读数/「暂无任务」暗银字 |
| `AuroraSilver.hair` | 0xE4E9F2 α0.22 | 分隔线/标签 |
| `AuroraSilver.radius` | `Aurora.radiusCard` = 12 | 卡片圆角（注释「小方框不要用面板级 16」） |

- **实测修正注释（AuroraTheme.swift）**：首版把卡片底做成白色（0xFFFFFF α0.16），亮底复测文字对比度仅 1.57:1（WCAG AA 要 4.5:1）→ 改回深色玻璃 `scrimHi → scrim` 渐变；银白只保留在描边与外侧辉光上。
- 辉光的用法（在 `QuestCard` 侧）：`QuestCard` 内两层 `.background` + `.blur` + `.blendMode(.plusLighter)` 加法发光——`.fill(AuroraSilver.glowNear)` 与 `.fill(AuroraSilver.glowFar)` 各一层，混合模型注释「【根因 —— 不是颜色错，是混合模型错】」解释为何 `.shadow` 的 alpha lerp 在亮背景上会压暗，详见 代码-27「三-A」节 4。

**GameHUDWindow 与 AuroraTheme 文档至此完整**。