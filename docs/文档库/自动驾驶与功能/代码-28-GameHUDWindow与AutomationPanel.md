# 代码-28 GameHUDWindow 帧率浮层 与 AuroraTheme 主题令牌

> 覆盖源文件：`Sources/AuroraDrive/App/GameHUDWindow.swift`（**123 行**）+ `AuroraTheme.swift`（**345 行**，UI 大改版新增）。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 GameHUDWindow.swift（120 行）+ `App/AutomationPanel.swift`（251 行）——**AutomationPanel 已在 UI 大改版中删除**（其"驾驶开关/状态"职责由 MissionConsole 的 AutomationBigButton + RunStatusCard 承载，自动化技能入口由 SkillOverlay 承载）。本档现补上同为大改版产物的 AuroraTheme（全项目视觉令牌的唯一权威源）。

## 一、GameHUDWindow 帧率 HUD（123 行全文）

**双重用途（头注释 4–14 行）**：
1. **实用**：游戏全屏时实时显示两行数据——「辅助帧率（AuroraDrive 处理帧率）」+「游戏帧率（ScreenCaptureKit 实际捕获合成帧率）」，**用来判断 Game Mode 是否在压制本进程（掉到个位数 = 被压制）**
2. **对抗 Game Mode**：一个持续可见的真实窗口比 1×1 隐形锚点更难被 gamepolicyd 归入"无可见窗口的纯后台"桶

**关键实现（15–19 行）**：
- `window.level = .screenSaver`——压过游戏全屏窗口
- `collectionBehavior 含 .fullScreenAuxiliary`——游戏进全屏 Space 后依然可见
- `ignoresMouseEvents = true`——**绝不拦截游戏操作**
- 绿色等宽字 + 半透明黑底——任何画面上可读

**接口**：`fpsProvider: (() -> (assist: Double, game: Double))?`（调用方注入取值闭包，避免依赖具体引擎内部）；`isInstalled`（window != nil）；`debugState`（诊断字符串：visible/level/frame）。

**引用关系（旧档 grep 记录 + 大改版后）**：安装调用方 = DriveState.init（`--engine` 模式下不装）；fpsProvider 唯一赋值方在 DriveState；`uninstall()` 零调用（无卸载路径，与旧版一致）。

## 二、AuroraTheme 主题令牌（345 行，UI 大改版新增）

**这是什么**：任务控制中心全部视觉规范的**唯一权威源**——从网页原型 CSS 变量逐一等价翻译（`--void`/`--s0..--s3`/`--ice`/`--txt` 等），任何 MissionConsole 子视图取色只准从这里取，**禁止散落硬编码色值**。

**`Color.init(hex:alpha:)`（18–26 行）**：`0xRRGGBB` 字面量构造（比 Color(red:green:blue:) 好读）。

**`enum Aurora` 令牌总表（32 行起）**：

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

**`RoadCondition` enum（约 100 行起，本文件内定义）**：路况自适应 6 档状态机（simple/easy/medium/busy/extreme/off），`String/CaseIterable/Identifiable/Sendable`——**定义在 AuroraTheme 是刻意的**：路况的核心用途是"状态色驱动全局"（DriveState 1756 MARK 注释："黑灰白 UI · 状态色驱动全局"），enum 与视觉档位绑定。判定阈值/自动限速在 ControlWiring 的 AutoRoadCondition（见代码-29）。

**给别的 AI 的铁律提示（用户原话级约束）**：
1. **视觉要求极高**——"非常高级"、反复抠细节、往死里抠细节
2. 偏好：空间感光斑、高对比度、纯深色背景加极淡网格的玻璃拟态；**拒绝低对比度发灰毛玻璃**
3. 毛玻璃必须**黑色不透明、没有奶白/泛白感**、能感觉到是玻璃质感
4. 改任何视觉先看网页原型（ui-prototypes/A-任务控制中心.好版备份-224710.html），不凭感觉调

**GameHUDWindow 与 AuroraTheme 文档至此完整**。
