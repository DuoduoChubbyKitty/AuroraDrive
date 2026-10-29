> ⚠️ **重要（2026-10-25 00:30 更新）**：本文引用的诊断开关 `AURORA_DISABLE_LIGHT_FIELD`
> **已在测量结束后撤销**（它是为 A/B 专门临时加的，结论见附录 A）。源码里现在**没有**这个开关，
> 请勿按本文行号去找。若将来还要复测，需按附录 A 的方法重新加入（约 15 行）。
> 同理 `AuroraTheme.swift` / `AuroraFlags.swift` 当前行号已回到加开关之前的位置。

# 10 · 预览框「CPU 合成」设计（只读取证 + 方案）

> 目标（用户原话）：「画面可以剪啊，我们可以剪剪画面，就是我们可不可以让画面变成 CPU 来。」
> 死命令：**GPU 尽量不要占，允许拿 CPU 换。** 红线：**不允许降质量（文字尤其不能糊）、不允许砍功能。**
>
> 本文**只做设计与取证，不改一行源码**。所有结论带 `文件:行`；未经实测的一律标 **【未测】/【估算】**。
>
> **行号基准**：`MissionConsole.swift`(mtime 18:43)、`AuroraDriveApp.swift`(20:12) 为本文取证时的版本；
> `AuroraTheme.swift`(23:41)、`AuroraFlags.swift`(23:41) 在取证过程中被**其它并发工作**改过，本文该两文件的
> 行号已于 23:46 按当时最新版本复核修正（见 §6.2）。若之后再改，请以符号名 grep 为准。
>
> 前提（既有事实，本文不复核、不推翻）：
> - Aurora 自身 GPU 仅 **0.66%**（推理不碰 GPU；`MTLTexture` / `CVMetalTextureCache` / `MTLCommandQueue` 全仓 0 处）
> - WindowServer：Aurora 关 **36.32%** → 驾驶态 **44.37%**（+8pp）
> - 隐藏 Aurora 窗口后 WindowServer 降 **10~18pp**，而 Aurora CPU 不变 ⟹ 系统自动剔除被遮挡窗口
> - 用户用**副屏**看画面时窗口完全可见，遮挡剔除帮不上忙 ⟹ 只能减少「要合成的层数 / 每层要做的活」

---

## 0. 结论摘要（先看这 5 条）

| # | 判断 | 依据 |
|---|---|---|
| 1 | **能合并的只有「几何叠加层」**：`AuroraLightField`（光斑）+ `ObstacleOverlay`（框）+ `MaskOverlay`（掩码）这三层。**画面层 `FrameHost` 不参与第一轮** | 三层都不含文字、不含交互、不含 `repeatForever`；画面层是 `layer.contents` 直绘的 480×312 图像，合并它会让游戏画面走 CPU 放大（质量风险） |
| 2 | **光斑可以烘成静态位图，而且这是风险最低、收益最确定的一步** | 漂移**已默认关闭**（`AuroraTheme.swift:705-706`，`AURORA_ENABLE_BG_DRIFT` 不设即静止）⟹ `.offset` 是常量、内容只随 `roadCondition` 变；原 `drawingGroup` 失败的**唯一**原因就是 `.offset` 每帧变（`:647-651`），现在这个前提消失了。**A/B 开关** `AURORA_DISABLE_LIGHT_FIELD`（临时加、测量后已撤销），已用它量出这层的真实成本 —— **结果≈0，见附录 A** |
| 3 | **`ObstacleOverlay` / `MaskOverlay` 不能整块合并——它们内部有文字** | `ObstacleOverlay` 用 `ctx.draw(Text(...))` 画类别+置信度胶囊（`:8966-8975`）、锁定标签（`:8996-9005`）；`MaskOverlay` 画「掩码降级 · 不参与决策」角标（`:8911-8920`）。**直接合并 = 让这些字进 CPU 位图 = 违反红线**，必须先拆成「几何（可合并）+ 文字（留原生）」 |
| 4 | **代码注释与 ZStack 实际顺序矛盾（需按实际顺序合并）** | `:614` 注释写「掩码画在检测框之下，避免遮挡框线」，但 `MaskOverlay` 在 `:618`，**排在** `:608` 的 `ObstacleOverlay` **之后** ⟹ ZStack 后者在上，实际是**掩码盖住检测框**。合并时若照注释顺序，层序会翻转 |
| 5 | **最大风险不是颜色，是「文字胶囊坐标」与「CPU 光栅阻塞主线程」** | 检测框文字胶囊依赖 `ctx.resolve(Text)` + `measure` 的**运行时排版结果**（`:8967-8972`），离开 Canvas 就得复刻排版；而 15Hz 主线程上做 1.5M 像素光栅，会直接占用 tick 预算 |

**一句话**：先做「光斑静态化」（改 1 层、0 文字、风险最低），把框/掩码的**几何**合并成一张 CPU 位图并**保留文字原生**，画面层这一步不动。三步都能独立 A/B。

---

## 1. 逐层解剖（`ViewportPanel`，`MissionConsole.swift:582-817`）

### 1.0 先把真实层序钉死

`ViewportPanel.body` 是一个 `ZStack`（`:586`），按代码**书写顺序**自下而上：

| 序 | 层 | 行号 | 是否条件显示 |
|---|---|---|---|
| ① | `FrameHostView`（游戏画面） | `:588-589` | 恒在 |
| ② | `UpscaleFrameHostView`（插帧/超分） | `:592-595` | `if state.upscaleEnabled`（**默认关**，见 9 号文档 #7） |
| ③ | `AuroraLightField`（光斑） | `:598-599` | 恒在 |
| ④ | `ObstacleOverlay`（检测框） | `:608-612` | 恒挂载，内部 `guard active`（`:8949`） |
| ⑤ | `MaskOverlay`（可行驶区+车道线） | `:618-625` | 恒挂载，内部 `guard active, metrics.srcW > 0`（`:8822`） |
| ⑥ | `QuestCard`（任务卡，`.overlay(alignment: .topLeading)`） | `:650-660` | 恒挂载，无任务时内部返回 EmptyView |
| ⑦ | 左上 `TagChip` 排（LIVE / THIRD-PERSON / 分辨率） | `:663-674` | 恒在 |
| ⑧ | 右上 `TagChip`（YUYAN / 区域） | `:677-684` | 恒在 |
| ⑨ | 告警横幅（卡死 / 接管 / 路况） | `:706-729` | 三选一 `if / else if` |
| ⑩ | 底部 `AutoSpeedPill` + `DualGauge` | `:732-754` | 恒在 |
| ⑪ | 背景渐变 + 投影 | `:756-791` | 恒在（`.background`） |
| ⑫ | 圆角裁剪 / 描边 / 窗口拉条 | `:792-815` | 恒在 |

> ⚠️ 任务描述里「7 层」是口语口径（指 ①②③④⑤⑥⑦ 这些视觉大层）。实际叠加对象是上表 **12 个**，其中 ⑨ 是条件分支、⑫ 是装饰。合并设计必须按 12 个算，否则会漏掉 ⑨ 的告警层与 ⑫ 的描边。

### 1.1 ①`FrameHostView` — 游戏画面

| 项 | 内容 |
|---|---|
| 怎么画 | `NSViewRepresentable` 包一个裸 `NSView`，`wantsLayer = true`，把 `CGImage` **直接赋给** `layer.contents`（`AuroraDriveApp.swift:9047-9058`、`:9026-9033`），`contentsGravity = .resizeAspectFill`、`masksToBounds = true`（`:9029-9030`） |
| 数据来源 | `state.frameHost`（`:588`）→ 内部 `cachedCGImage`（`:9024`）；`push` 由 tick 调用（`:6717` 本地模式 / `:7194` 主路径） |
| 每帧变吗 | **变，15Hz**（`MissionConsole.swift:6233` `repeating: 1.0/15.0`）。变的是**整张图**：`480×312` 的 CGImage（`CaptureEngine.swift:1190` `maxWidth = 480`；7 号文档实测日志「收到引擎首帧 480×312」） |
| 是不是文字 | **不是**。像素图 |
| 备注 | 该层**无遮挡门控**（6 号文档 §184 实测），被遮挡时仍每 tick 提交 |

### 1.2 ②`UpscaleFrameHostView` — 插帧层

| 项 | 内容 |
|---|---|
| 怎么画 | `MTKView` + `GooseUpscaler`（Metal），`AuroraDriveApp.swift:9232` 起；有遮挡门控（`:9120-9141`） |
| 数据来源 | `state.upscaleHost`（`:593`），`CVPixelBuffer` 入（`:6160`/`:6701`） |
| 每帧变吗 | 开着时是 MTKView **独立 60fps** 渲染，不跟 tick |
| 是不是文字 | 不是 |
| 结论 | **默认关**（9 号文档 #7）。开着时它是**真 GPU**（Metal），与「减少合成层数」无关，**不属于本方案**。合并时它必须原样留在位图**之上**（它是画面本体） |

### 1.3 ③`AuroraLightField` — 光斑（本方案的主目标）

| 项 | 内容 |
|---|---|
| 怎么画 | `GeometryReader` + `ZStack` 里 3 个 `Circle().fill(RadialGradient(...))`，`.frame(size)` + `.position(x:y:)`（`AuroraTheme.swift:712-720`），**整块 ZStack 加一次** `.blur(radius: 60)`（`:658`） |
| 数据来源 | `condition: state.roadCondition`（调用点 `MissionConsole.swift:598`）→ 只影响**第一个** blob 的颜色与不透明度（`AuroraTheme.swift:612-615`）：`extreme ? 0.34 : 0.26`。第 2/3 个是 `.white` 常量（`:616-623`） |
| 每帧变吗 | **不变**。`.offset(x: drift ? 22 : -22, y: drift ? 18 : -18)`（`:696`）中 `drift` 默认 `false`，只有 `AURORA_ENABLE_BG_DRIFT == "1"` 才置 true（`:705-706`）⟹ **常量 offset**。尺寸随视口 `geo.size` 变，仅在窗口 resize 时变 |
| 是不是文字 | **不是** |
| 每帧的活 | 3 个径向渐变 + 1 次 60pt 高斯。面积 = `max(w,h)*0.78/0.60/0.48` 三个圆，注释自述总面积 ≈ 窗口的 **1.9 倍**（`:625`、`:672`） |
| A/B 开关 | 临时加过 `AuroraFlags.disableLightField`，**已撤销**。实测结论见附录 A：本层成本≈0 |
| ⚠️「可被 CA 缓存」这句话 | **【未测】**。出处是 `:701` 注释：「drift 保持 false → 光斑静止 → 60px 模糊结果可被 Core Animation 缓存」。全仓没有任何采样/日志证明它真的被缓存。**唯一相关的反证是 `.drawingGroup()` 失败**（`:632-657`），但那次失败被归因于 `.offset` 动画（`:647-651`），与「CA 自身是否缓存 filter 层」是两个不同问题 |

### 1.4 ④`ObstacleOverlay` — 检测框

| 项 | 内容 |
|---|---|
| 怎么画 | SwiftUI `Canvas`（`AuroraDriveApp.swift:8948`）。每个框：圆角矩形 `fill`（`:8960`）+ `stroke`（`:8962-8964`）+ 文字胶囊 `fill`（`:8974`）+ `ctx.draw(Text)`（`:8975`）。锁定框另有 14pt 四角准星与「🎯 … LOCK」（`:8986-9005`） |
| 数据来源 | `state.isDriving`、`state.displayDetections`（`:608-609`）、`state.screenSize`（`:610`）、`state.yoloEngine.lockedTarget` / `isLocked`（`:611-612`）。`displayDetections` 定义在 `AuroraDriveApp.swift:4228`，可能是 `predictorDetections`（30Hz 外推） |
| 坐标映射 | `aspectFillLayout(source: screenSize, view: size)`（`:8950`），见 §2.3 |
| 每帧变吗 | **变**。框集合每 tick 可能变（含 30Hz 外推值），`Canvas` 闭包随视图重算重跑 |
| 是不是文字 | **部分是**：类别+置信度、LOCK 标签都是 `Text`。**这两处必须留原生** |
| 其它 | `.allowsHitTesting(false)`（`:9008`） |

### 1.5 ⑤`MaskOverlay` — 可行驶区 + 车道线

| 项 | 内容 |
|---|---|
| 怎么画 | `Canvas`（`AuroraDriveApp.swift:8803`）。两层各自 `spanMergedPath` 生成**行内连续段合并**的矩形 `Path`（`:8863-8885`），可行驶区 `fill` 绿 0.18α（`:8890-8892`），车道线 `fill` 青 0.75α + 0.8pt `stroke`（`:8903-8906`），降级时再画角标（`:8910-8921`） |
| 数据来源 | `state.displayDrivableMask` / `displayLaneMask`（`MissionConsole.swift:619-620`）→ `EngineClient.engineDrivableMask` 或 `yolopxEngine.drivableMask`（`AuroraDriveApp.swift:5968-5975`）；`metrics: state.displayMaskMetrics`；`sourceSize: state.screenSize`；三个 `degraded` 标志（`:8832-8850`） |
| 每帧变吗 | **变**。`MaskGrid` 每次模型产物写入（`YolopxEngine.swift:1085-1086`；引擎模式 `EngineClient.swift:789-796`）。**是否每 tick 都变：未测**（取决于模型推理节流 `AURORA_YOLOPX_INTERVAL_MS`，`AuroraFlags.swift:181`） |
| 是不是文字 | **有一个**：降级角标 `"掩码降级 · 不参与决策"`（`:8911`）。通常不显示，但合并时**必须把它留成原生**，否则一旦降级文字就进位图 |
| 网格 → 屏幕 | 见 §2.2（关键正确性） |
| 其它 | `.allowsHitTesting(false)`（`:8923`） |

### 1.6 ⑥`QuestCard` — 任务卡（**文字，保留原生**）

| 项 | 内容 |
|---|---|
| 怎么画 | SwiftUI 原生：`Text` × 4 行（任务名、直线距离、弯道距离 + 标签），`.font(Aurora.label(10.5))` / `.font(Aurora.metric(11.5, .semibold))`，每行 `lineLimit(1)` + `minimumScaleFactor(0.8)` + `fixedSize()`（`MissionConsole.swift:1303-1333`） |
| 装饰 | 深色玻璃底 `LinearGradient`（`:1338-1341`）、1px 银白描边（`:1344-1347`）、**两层加法发光** `.blur(radius: 9)` / `.blur(radius: 20)` + `.blendMode(.plusLighter)`（`:1374-1388`） |
| 尺寸 | 定宽 `260pt`（`:1263`、`:1336`），高自适应 |
| 数据来源 | `state.questName`、`locatorX/Y`、`locatorTarget`、`routePlan?.distanceMeters`（`MissionConsole.swift:651-655`） |
| 每帧变吗 | 任务名几乎不变；两个距离随自车移动每 tick 变（`straightMeters` 是计算属性 `:1232-1238`） |
| 是不是文字 | **是，100% 保留原生** |
| 额外风险 | 内含 `.blur(9)` + `.blur(20)` + `.blendMode(.plusLighter)` —— 这本身是**每帧重算的 GPU filter**（文字每 tick 变 ⟹ 无法缓存）。这是「文字层保留原生」的代价，**不能靠合并解决**，见 §4.3 |

### 1.7 ⑦⑧`TagChip` — 标签（**文字，保留原生**）

| 项 | 内容 |
|---|---|
| 怎么画 | `HStack { Text(text).font(.system(size: 8.5, weight: .medium)).tracking(0.8) }` + 圆角黑底 0.55α + 描边（`MissionConsole.swift:1141-1162`）；`live: true` 时多一个 4pt 绿点带 `.shadow(radius: 4)`（`:1144-1145`） |
| 数据来源 | 常量 "LIVE"、"THIRD-PERSON"、`state.resolutionLabel`（`:668`，定义 `AuroraDriveApp.swift:5201-5204`，由 `screenSize` 派生）、`state.regionLabel`（`:680`） |
| 每帧变吗 | `resolutionLabel` 仅在 `screenSize` 变时变；`regionLabel` 低频（有缓存，`AuroraDriveApp.swift` 区域注释）。**基本不变** |
| 是不是文字 | **是，保留原生** |

### 1.8 ⑨告警横幅 / ⑩底部仪表（**文字 + 交互，保留原生**）

| 层 | 怎么画 | 数据 | 每帧变 | 文字 |
|---|---|---|---|---|
| `StuckWarn` `:1461`、`TakeoverWarn` `:1522`、`RCWarn` `:1419` | SwiftUI 胶囊 + `Text`，**内含 `repeatForever` 脉冲**（`:1442`、`:1487`、`:1556`，0.65~1.1s 描边/透明度往复） | `state.needsManualIntervention`、`EmergencyTakeover.shared`、`state.roadCondition.needsTakeover`（`:706-722`） | 出现期间**每帧**（动画） | **是** |
| `AutoSpeedPill` `:1633` | `Button` + `Capsule` + `Text("自动速度")`（`:1655-1657`） | `state.autoSpeedEnabled`、`state.roadCondition` | 点击/路况变 | **是，且有交互** |
| `DualGauge` `:1707` → `GaugeDial` `:1737` | `Circle().trim(...).stroke` 圆弧 + 中心数字 `Text` | `speedKmh`、`speedValid`、`confidence`、`latency`（`MissionConsole.swift:744-750`） | **每帧**（车速 OCR 更新） | **是** |

> ⑨ 的 `repeatForever` 是**新增发现**：它是常驻动画，`AuroraTheme` 明确禁止该模式（`:203`、`:393`、`:504`、`:583-585`，因 `repeatForever` 曾让 WindowServer 51.2%→81.9%）。但它只在**告警出现时**才存在，不是常开后门；**不在合并范围内**（文字+动画），但可作为独立 A/B 项记录（§5.4）。

### 1.9 ⑪⑫背景 / 裁剪 / 拉条

| 层 | 怎么画 | 每帧变 | 备注 |
|---|---|---|---|
| 背景渐变 `:756-763` | `LinearGradient` 三档 | 不变 | 若光斑烘成位图，可与光斑合成一张静态底图（省 1 层） |
| 投影 `:790` | `.shadow(black 0.78, r17, y14)`，**挂在 background 内部** | 不变 | 历史修复记录 `:764-789`：挪进 background 是为了不误伤 overlay |
| 圆角裁剪 `:792` + 描边 `:793-799` | `RoundedRectangle(16).strokeBorder` | 路况接管时描边变色/加粗 | 建议**保留原生**（1px 边线走位图最易糊） |
| 窗口拉条 `:813-815` → `:836` | `Button` + `Text`(旋转 90°) + 列表 | 展开/收起 | **有交互 + 文字，保留原生** |

---

## 2. 可合并性判定

### 2.1 判定表

| 层 | 判定 | 理由 |
|---|---|---|
| ① `FrameHostView` | **保留原生（第一轮）** | 它是画面本体，走 `layer.contents` 已经是最省的路径（1 层、1 张图、无 filter）。合并它 = 要把 480×312 图**用 CPU 放大**到视口尺寸（702×560pt@2x ≈ 1.5M px），既加 CPU 又让「画面锐度」从 CA `resizeAspectFill`（硬件/高质量采样）变成自己控制 —— **质量风险最大**。第二轮若前三步收益不够再评估 |
| ② `UpscaleFrameHostView` | **保留原生** | Metal 渲染层，默认关；开着时它就是画面本体 |
| ③ `AuroraLightField` | ✅ **合并进位图（静态烘一次）** | 纯几何 + 渐变 + 模糊，无文字、无交互、无动画。内容只随 `roadCondition` 与尺寸变 ⟹ **可缓存跨帧复用**，收益最直接 |
| ④ `ObstacleOverlay` | ⚠️ **拆开：几何合并 / 文字留原生** | 框体+准星可合并（纯路径）；`rawName + conf` 胶囊与 LOCK 标签是 `Text`，必须原生 |
| ⑤ `MaskOverlay` | ⚠️ **拆开：几何合并 / 角标留原生** | 两层矩形填充+描边可合并；`"掩码降级 · 不参与决策"` 是文字，必须原生 |
| ⑥ `QuestCard` | ❌ **保留原生** | 全文字 + `minimumScaleFactor`（非整数倍缩放会让字发糊）+ 加法混合发光 |
| ⑦⑧ `TagChip` | ❌ **保留原生** | 8.5pt 小字 + `tracking(0.8)`，位图最容易糊的就是这种 |
| ⑨ 告警横幅 | ❌ **保留原生** | 文字 + `repeatForever` 动画 |
| ⑩ `AutoSpeedPill` / `DualGauge` | ❌ **保留原生** | 文字 + 按钮交互 + 每帧数字 |
| ⑪ 背景渐变 + 投影 | ⚠️ 可并入 ③ 的静态位图 | 无文字、不变；合并后静态底图 1 层顶 2 层 |
| ⑫ 裁剪圆角 / 描边 / 拉条 | ❌ **保留原生** | 1px `strokeBorder` 走位图必糊；拉条有交互与文字 |

**合并后层数**：`① 画面` + `② 插帧(关)` + `③ 静态底图(光斑+背景)` + `④⑤ 合成位图(几何)` + `文字层若干`。
从「画面 + 光斑(3 blob×blur) + 框 + 掩码 + 4 处文字层」变成「画面 + 底图 + 1 张叠加位图 + 4 处文字层」⟹ **参与合成的 filter/绘制层数减少，CPU 光栅增加**。这是「拿 CPU 换 GPU」的准确形态。

> **收益必须是「层数 × 每层活」的乘积。** 光斑那层之所以值得先动，是因为它一个层里塞了 3 个 60px 高斯且面积 ≈ 1.9 倍窗口（`AuroraTheme.swift:625`）；合并框/掩码省下的是「每 tick 两次 Canvas 重算」，与 WindowServer 关系较小（7 号文档：Canvas = CPU 光栅 + GPU 合成）。

### 2.2 `MaskGrid`（160×160）→ 屏幕坐标（**正确性的核心**）

代码事实（`AuroraDriveApp.swift:8822-8840`）：

```swift
guard active, metrics.srcW > 0 else { return }
let t = aspectFillLayout(source: sourceSize, view: size)

// 网格坐标 → 原帧归一化 → 视口坐标
let sx = t.size.width / Double(metrics.srcW)
let sy = t.size.height / Double(metrics.srcH)
let r = metrics.ratio

func rect(_ gx: Int, _ gy: Int, cell: Double) -> CGRect {
    // 网格单元 → letterbox 640 像素坐标（左上原点）
    let px = Double(gx) * cell - Double(metrics.padX)
    let py = Double(gy) * cell - Double(metrics.padY)
    // → 原帧像素 → 归一化 → 视口
    let x = t.origin.x + px / r * sx
    let y = t.origin.y + py / r * sy
    return CGRect(x: x, y: y,
                  width: cell / r * sx + 0.5,
                  height: cell / r * sy + 0.5)
}
```

关键推论（**照着实现位图版必须逐字保持**）：

1. `cell = inputSize / max(mask.width, 1) = 640 / 160 = 4`（`:8888`、`:8901`；`YolopxEngine.swift:272` `inputSize = 640`）⟹ 每格 = **4 个 640 坐标像素**。
2. `padX / padY` 是 **letterbox 灰边**（`YolopxEngine.swift:96-99`，`padY` = 顶边、行 0 = 图顶）。网格是**含灰边**的完整 160×160，所以必须先减 pad 才是有效内容。**少减这一步 → 掩码整体上/左偏**。
3. `r = metrics.ratio`（`:149` `min(640/h, 640/w)`），`px / r` 把 640 坐标换回**原帧像素**。
4. `sx = t.size.width / srcW`。注意 `aspectFillLayout` 里 `t.size = src * scale`（`:8747-8748`）⟹ `sx == sy == scale`（同一标量）。**所以掩码的等比缩放与画面完全同源**，不存在两套缩放。
5. `+ 0.5` 是**故意**给每格多铺 0.5pt，消除格间缝隙（`:8838-8839`），配合行内合并（`:8857-8859` 注释：几何等价、逐像素一致）。**位图版必须保留 `+0.5`**，否则出现网格裂缝。
6. 网格 `(0,0)` 在**左上**，`y` 向下增 ⟹ 与 SwiftUI/Canvas 的左上原点一致；换到 `CGContext`（左下原点）**必须翻转**（§3.3）。

### 2.3 `ObstacleOverlay` 检测框 → 视图坐标

代码事实（`AuroraDriveApp.swift:8950-8959`）：

```swift
let t = aspectFillLayout(source: sourceSize, view: size)
for d in detections {
    let w = max(d.width * t.size.width, 2)
    let h = max(d.height * t.size.height, 2)
    let cx = t.origin.x + d.x * t.size.width
    let cy = t.origin.y + d.y * t.size.height
    let box = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
```

- `Detection` 是**归一化中心点 + 归一化宽高**（`RuleController.swift:50-54`，`x/y` = 中心 `[0,1]`）。
- `aspectFillLayout`（`:8743-8751`）：`scale = max(view.w/src.w, view.h/src.h)`，`drawn = src*scale`，`origin = (view - drawn)/2`（可为负 ⟹ 画面被裁）。
- **与 `FrameHost` 的 `resizeAspectFill` 几何等价**：两者都是「取较大缩放、居中、溢出裁剪」。这是本方案成立的前提 —— 位图里画的框/掩码与 `layer.contents` 里的画面**同一变换**。✅
- 最小框 2pt（`:8955-8956`）、胶囊夹取 `capX = min(max(box.minX,4), size.width-capW-4)`、`capY = max(box.minY-16-m.height-4, 4)`（`:8971-8972`）—— 这些**依赖 `measure(in: size)` 的排版结果**，拆层后必须复刻会漂移（§4.1 风险 R5）。

---

## 3. 具体实施方案

> 以下为**设计稿**，本文档不含任何源码改动。落地时按 §5 分步、每步独立 A/B。

### 3.1 位图尺寸：按「设备像素」，不是按 pt，也不是写死 @2x

**为什么不能写死 2x**：整台控制台被 `FitToWindow` 做了 `.scaleEffect(scale)`（`MissionConsole.swift:7651`），`scale = 可用宽 / designWidth(1470)`（`:7675`、`:7624`），**通常不是 1、也不是 0.5 的整数倍**（例：副屏 1200 宽窗口 → `scale ≈ 0.816`；`:7691` 日志按 3 位小数打印）。

所以最终设备像素 = `视口pt × consoleScale × backingScaleFactor(2)`。若位图只烘 2x，再由 CA 缩到 `0.816×2 = 1.632x`，**0.8pt 的车道线描边与 1px 框线会被重采样**（观感变柔）——对几何图形影响小，但会与「不降质量」擦边。

推荐做法（保守、可逆）：

```swift
// 设备像素比（每次尺寸/缩放/换屏变化时重算，不要缓存死）
let backing = view.window?.backingScaleFactor ?? 2.0          // M3 内置屏 = 2.0
let consoleScale = 读 ConsoleMetrics 那条链路当前的 scale        // MissionConsole.swift:7675
let deviceScale = backing * consoleScale                       // 例：2×0.816 = 1.632
let pxW = Int((boundsPt.width  * deviceScale).rounded())
let pxH = Int((boundsPt.height * deviceScale).rounded())
// 建上下文：premultipliedFirst + 32Little（与全仓既有写法一致）
guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,   // ← 见 §4.1 R3
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
ctx.scaleBy(x: deviceScale, y: deviceScale)   // 之后一律用 pt 坐标，与 SwiftUI 同口径
```

**尺寸参考（估算，未实测）**：设计坐标系下视口宽 = `1470 − 13×2(外 padding) − 13×2(三栏 spacing) − 344(Mid) − 372(Right) = 702pt`（`:545`、`:551`、`:553`、`:555`、`:7624`）；高由 `designHeight 956 − TopBar 58(:163) − KeyBar 46(:502) − 上下 padding 26 − 两行 RCBar/gearRing` 得 **约 500~560pt**（`GearRing` 高度自适应，未量）。取 `702×560pt`：
- @2x：`1404×1120 = 1,572,480 px = 6.29 MB`（BGRA）
- 副屏 `scale 0.816`：`1146×914 = 1.05M px = 4.19 MB`

> 这些数字**必须**在落地时用实际 `bounds` 打印替换；上表只用于量级估算。

### 3.2 拆层后的目标结构

```
ZStack
 ├─ FrameHostView                 ← 不变（layer.contents 直绘）
 ├─ UpscaleFrameHostView          ← 不变（默认关）
 ├─ StaticBackdropHost            ← 新：光斑(+可选背景渐变) 烘成一张静态 CGImage
 ├─ OverlayGeometryHost           ← 新：框体/准星 + 掩码(+降级前提下的几何) 合成一张透明 CGImage
 ├─ ObstacleLabelsOverlay         ← 新：把类别+置信度胶囊/LOCK 标签做成原生 Text（原 Canvas 里的文字搬出来）
 ├─ MaskDegradedChip              ← 新：降级角标做成原生 Text
 ├─ QuestCard / TagChip / 警告 / 仪表 / 拉条 / 描边   ← 原样不动
```

`StaticBackdropHost` 与 `OverlayGeometryHost` 都照抄 `FrameHost` 的**成熟写法**（`AuroraDriveApp.swift:9020-9058`）：一个 `NSViewRepresentable` 包裸 `NSView`，`wantsLayer = true`、`layer.contentsGravity = .resize`、`masksToBounds = true`，把 `CGImage` 赋给 `layer.contents`，**绕开 SwiftUI 离屏合成**（这是 `.drawingGroup()` 那条路已经证伪、而这个写法在本仓已被验证的部分）。

二者差别：
- `StaticBackdropHost`：内容与 pt 尺寸绑定，**只在 `roadCondition` / 尺寸 / scale 变时重烘**；`layer.contentsGravity = .resize`（尺寸已对齐，不需 aspect-fill）。
- `OverlayGeometryHost`：透明底 `ctx.clear(CGRect(0,0,w,h))`，`layer.contentsGravity = .resize`，`.isOpaque = false`，**只在输入指纹变化时重画**。

### 3.3 绘制顺序与坐标翻转（最容易错的地方）

**CGContext 原点在左下，y 向上；SwiftUI/Canvas 原点在左上，y 向下。** 两条纪律：

1. **只翻转一次，越早越好**：建好上下文后立即
   ```swift
   ctx.translateBy(x: 0, y: CGFloat(pxH))
   ctx.scaleBy(x: deviceScale, y: -deviceScale)   // 一步同时完成 @Nx 与 y 翻转
   ```
   之后**所有绘制都用 SwiftUI 的 pt 坐标**（左上原点、y 向下），掩码/框的数学可以**从 `MaskOverlay`/`ObstacleOverlay` 原样搬**，不需要每处手算 `H - y`。这比「逐处翻转」少一半出错面。
   > 已知代价：翻转后画文字会被**镜像**。所以文字一律不进位图（本方案正是不画文字），此代价为零。
2. **若坚持不翻转**（例如想复用 `CGContext.draw(image:in:)` 画径向渐变之外的东西），则每个 rect 要写 `cgY = H_pt − (y + h)`，且 `CGGradient` 的坐标也要跟着翻 —— 出错面大，不推荐。

**绘制顺序（与 §1.0 的真实 ZStack 层序一致）**：

```
OverlayGeometryHost 内部：
  1. 掩码·可行驶区 fill   (alpha 0.18 × daDim)        ← 原 :8890
  2. 掩码·车道线  fill    (0.75 × llDim) + stroke 0.8 ← 原 :8903-8906
  3. 检测框：每个 detection 圆角矩形 fill + stroke      ← 原 :8952-8964
  4. 锁定框：fill + stroke + 四角准星（不含 LOCK 文字）  ← 原 :8978-8995
StaticBackdropHost 内部：
  1. 背景 LinearGradient（若决定并入）                ← 原 :756-763
  2. blob#1 (condition.color, 0.34/0.26)              ← 原 :597-600
  3. blob#2 (white, 0.17)                             ← 原 :601-604
  4. blob#3 (white, 0.12)                             ← 原 :605-608
  5. 一次高斯模糊（vImage）                            ← 原 :643 的 .blur(radius: 60)
```

> ⚠️ 顺序必须按 **ZStack 实际层序**：掩码在检测框**之上**（`MaskOverlay` 在 `:618` 晚于 `:608`）。代码注释 `:614` 说「画在检测框之下」与实现相反 —— **以实现为准**，否则合并后框线会从「被掩码盖住」变成「盖住掩码」，视觉改变。

### 3.4 光斑烘图：能不能、用什么 API

**能。** 理由（全部来自代码事实）：
- 位置是常量（`drift` 默认 false，`AuroraTheme.swift:705-706`）⟹ **内容只依赖 `roadCondition` 与尺寸**；
- 无文字、无交互（`.allowsHitTesting(false)` `AuroraTheme.swift:709`）；
- `.blur` 施加在**整个 ZStack** 上（`:658`，在 `ZStack` 的闭合 `}` `:624` 之后）⟹ 是「3 个渐变先叠加，再整体模糊一次」，CPU 版可**完全同构**地复刻：先画 3 个 `CGGradient` 径向渐变，再对整张位图模糊一次 —— 注意**不能**对每个 blob 分别模糊再叠加（径向渐变本就无边缘，但分别模糊会改变交叠区的浓度）。

**API 选择**（已在 SDK 头文件核对存在，非记忆）：

| API | 位置 | 用不用 |
|---|---|---|
| `vImageBoxConvolve_ARGB8888` | `MacOSX.sdk/.../vImage.framework/Headers/Convolution.h:3165` | ✅ **首选**。方框模糊，每像素 O(1)（滑动窗口），与核大小无关；做 3 次逼近高斯，视觉上等价于 `blur(60)`。**近似 ⟹ 必须像素 diff 验收** |
| `vImageConvolve_ARGB8888`（可传自定核） | 同头文件 `:692` | ✅ 备选。真高斯核，半径 60pt×2 = 120px 时是 121×121 核 ⟹ 每像素 14641 次乘加，1.5M px 会到秒级，**不可用**。只在「方框近似肉眼可辨」时用较小核折中 |
| `CIGaussianBlur` | CoreImage | ❌ **不用**。默认走 GPU（`CIContext` 默认 Metal），与「降 GPU」目标相反；即便 `useSoftwareRenderer: true` 也是 CPU 上逐 tile 走同一套 CI，开销远高于 vImage 的滑动窗口，且引入 CoreImage 依赖 |
| 自写双重循环 | — | ❌ 不必要，vImage 已在同仓被使用（`CaptureEngine.swift` 多处 `vImageScale_ARGB8888`），不引入新依赖 |

**关键细节（模糊的边界语义）**：
- `.blur` 在 SwiftUI 里**只播撒到视图边界内**，界外视为透明；而 blob 用 `.position` 定位、尺寸可达 `max(w,h)*0.78`，**必然溢出边界**（`:598-608`）。烘焙时要复刻「界外透明」，vImage 需 `kvImageEdgeExtend` 之外的处理：**推荐把位图向四周各扩 `ceil(2×σ)` 像素，画完 3 个 blob 后再模糊，最后裁回视口矩形**。这样边缘衰减与 SwiftUI 一致；直接用 `kvImageEdgeExtend` 会让边缘变亮（光斑"糊边"）。
  - σ 取 `radius/2`（SwiftUI `blur(radius:)` 的常用对应），即 `60pt → σ=30pt → 60px@2x`，外扩 120px。
  - **这条必须像素 diff 验证**：若实测边缘有差异，改用「扩边 + 透明背景填充」而不是 `kvImageEdgeExtend`。
- 缓存键：`(ptSize, deviceScale, condition, blurRadius)`。任一变化才重烘。

### 3.5 几何叠加位图：怎么画、怎么喂

**画**（伪代码，坐标全部用 pt、左上原点 —— 因为 §3.3 已翻转）：

```swift
// 输入快照（值类型，主线程取，整理成不可变结构再进渲染队列）
struct OverlaySnapshot {
    let active: Bool
    let detections: [Detection]      // 已 Equatable（RuleController.swift:38）
    let masks: MaskGrid               // 已 Equatable（YolopxEngine.swift:45）
    let metrics: LetterboxMetrics     // 已 Equatable（:93）
    let sourceSize: CGSize?
    let sizePt: CGSize
    let deviceScale: CGFloat
    let daDim: Double, llDim: Double
}

func renderOverlay(_ s: OverlaySnapshot) -> CGImage? {
    guard s.active, s.metrics.srcW > 0 else { return nil }   // 与原 :8822 守卫一致
    let pxW = Int((s.sizePt.width * s.deviceScale).rounded())
    let pxH = Int((s.sizePt.height * s.deviceScale).rounded())
    guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.setShouldAntialias(true)                    // 默认即 true，显式写便于 A/B 关闭对照
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(pxH))
    ctx.scaleBy(x: s.deviceScale, y: -s.deviceScale)   // 到此为止坐标系 = SwiftUI pt/左上

    let t = aspectFillLayout(source: s.sourceSize, view: s.sizePt)   // 复用既有函数，勿重写
    // …照搬 MaskOverlay 的 spanMergedPath + ObstacleOverlay 的 rect 数学…
    return ctx.makeImage()
}
```

**喂**（两条路，推荐第一条）：

- **路线 A（推荐）：新增 `OverlayGeometryHost`，就照 `FrameHost` 的写法**
  ```swift
  final class OverlayHost {
      private weak var hostView: NSView?
      private var cached: CGImage?
      func attach(_ v: NSView) {
          hostView = v
          v.wantsLayer = true
          v.layer?.contentsGravity = .resize     // 不是 resizeAspectFill：尺寸已 1:1 对齐
          v.layer?.masksToBounds = true
          v.layer?.isOpaque = false
          if let c = cached { v.layer?.contents = c }
      }
      func push(_ image: CGImage) { cached = image; hostView?.layer?.contents = image }
      func clear() { cached = nil; hostView?.layer?.contents = nil }
  }
  ```
  然后在 ZStack 里 `OverlayGeometryHost(host: state.overlayHost).allowsHitTesting(false)`。
  **理由**：不碰 `FrameHost` 的语义（画面本体、`resizeAspectFill`、遮挡门控缺失这些问题都与它无关）；出问题删一行即可回退。

- **路线 B（激进）：直接 `frameHost.push(合成位图)`**（即任务里问的 `AuroraDriveApp.swift:9021` 那条）
  把「画面 + 光斑 + 框 + 掩码」全部画进同一张位图，只留**一个**画面层。收益最大（层数 1），但代价：
  1. 必须用 `CGContext.draw(cgImage, in: rect)` **CPU 放大** `480×312 → 1404×1120`，`interpolationQuality` 若用 `.high` 是双三次/兰契奥近似，**与现在 CA `resizeAspectFill` 的结果不可能逐像素一致** ⟹ 违反「不降质量」的判定门槛（要用像素 diff 证明 Δ 可忽略，**当前无法先验保证**）；
  2. 画面层从此**每 tick 必须重画**（即使框/掩码没变），CPU 成本从 "按需" 变成 "每 tick 1.5M px 全量重绘 + 放大"；
  3. `FrameHost.clear()`（`:9041`）的停止语义、`cachedCGImage`（`:9024`）的复用逻辑都要跟着改，爆炸半径大。
  **结论：第一轮不用路线 B，只在 §5 第三步评估。**

### 3.6 每帧 CPU 成本估算（**估算，未实测**）

估算基准（全部来自代码里的既有实测值或算术）：

| 项 | 依据 | 估算值 |
|---|---|---|
| 位图面积 | `702×560pt`，`deviceScale 2.0` → `1404×1120`（§3.1，设计常量推导） | 1.57M px / 6.29 MB |
| 掩码矩形数 | 注释内置实测：可行驶区前景 8~16%、车道线 1.3~2.6%；行内合并后 da 2000~4000 段、ll 300~700 段（`:8849-8855`、`:8779-8781`） | ≈ 2300~4700 个 rect |
| 掩码 Canvas 现有实测 | 同处注释：da p50 **0.302ms**、ll p50 **0.097ms**（合并后） | ≈ **0.40ms/tick** |
| 检测框 | 按 20 个框（历史注释口径）、每框 2 个圆角路径 + 无文字 | 0.05~0.15ms **【估算】** |
| 清空位图 | memset 6.29MB @ ~15GB/s | 0.2~0.4ms **【估算】** |
| `makeImage()` | COW 快照（`CaptureEngine.swift:1222` 同款语义），非物理拷贝 | 0.03~0.08ms **【估算】** |
| **每 tick 合计（仅数据变化时才画）** | 上述相加 | **0.7~1.5ms/tick 【估算】** |
| 折成 CPU 占用 | ×15Hz = 10.5~22.5ms/s | **≈1~2.3% 单核【估算，未实测】** |
| 光斑烘焙（一次性） | 3 个径向渐变 + 3 次方框模糊 @1.57M px（O(1)/px/次） | 3~10ms，仅在首次/切路况/resize 时 **【估算】** |
| 静态底图内存 | 1.57M px BGRA（可与叠加图共用尺寸） | 6.29 MB 常驻 **【估算】** |

**对照项（说明"省在哪"）**：以上 CPU 增量换掉的是「每 tick 两次 SwiftUI `Canvas` 重评 + 3 个 60px 高斯 filter 层的合成」。**WindowServer 侧能降多少，本文无法先验给出，必须 A/B 实测**（§5 每步都带测量口径）。

---

## 4. 风险清单

### 4.1 视觉变化风险（每项都写"怎么发现"）

| # | 风险 | 具体机制 | 强度 | 怎么发现 |
|---|---|---|---|---|
| R1 | **坐标翻转错**（整块 y 镜像） | `CGContext` 原点左下 vs SwiftUI 左上（§3.3） | 🔴 致命 | 出图后掩码/框整体镜像 → 与基线 PNG 的 `max|Δ|` 巨大，肉眼一眼可见 |
| R2 | **缩放错位（少乘/多乘 `deviceScale`）** | 位图像素尺寸 vs pt 尺寸混用；`ctx.scaleBy` 之后仍按像素算 | 🔴 致命 | 框/掩码整体缩一半或大一倍；用「已知坐标画一个 1px 十字」标定 |
| R3 | **色彩空间双重转换** | 若用 `CGColorSpaceCreateDeviceRGB()` 而非 sRGB：`MissionConsole.swift:2632-2646` 有**实测前科** —— 同一张图在两条路径下 **23.26% 像素不同、max|Δ|=3** | 🟠 中 | 像素 diff（同一夹具，sRGB vs deviceRGB 各出一张） |
| R4 | **抗锯齿 / 0.8pt 细线变糊或变脆** | `MaskOverlay` 车道线 `lineWidth: 0.8`（`:8906`）+ `+0.5` 补缝（`:8838`）；位图路径的 AA 与 Canvas 不同 | 🟠 中 | 掩码区域逐像素 diff + 放大 4× 目视；看车道线边缘灰阶 |
| R5 | **检测框文字胶囊位置漂移** | 胶囊位置依赖 `ctx.resolve(Text) + measure(in: size)`（`:8967-8972`）；文字留原生后，原生层的排版尺寸与 Canvas 内解析结果可能差 0.5~1pt，导致胶囊与框的间距变化（原来是 `box.minY − 16 − height − 4`） | 🟠 中 | 锁定/未锁定两态各出图，量「框顶 → 胶囊底」的像素距离，要求 = 16±1 |
| R6 | **alpha / 混合模型变化** | `QuestCard` 用 `.blendMode(.plusLighter)` 加法发光（`:1380`、`:1387`）；若把它的底色/发光并入位图，普通 alpha 混合会**变暗**而不是发光（这正是 `:1355-1372` 记录过的坑：亮背景上辉光变压暗，实测 Δ 均值 −15.3） | 🔴 致命（若动） | **规避**：QuestCard 整体留原生，不碰它的混合 |
| R7 | **模糊边缘语义不同** | SwiftUI `.blur` 界外透明 vs vImage `kvImageEdgeExtend` 界外延伸 ⟹ 视口四边光斑偏亮 | 🟡 低-中 | 只 diff 视口四边 10px 条带 |
| R8 | **层序翻转（掩码 vs 框）** | §1.0 已发现注释与实现相反（`:614` vs `:618`） | 🟠 中 | 出图时构造「掩码压在框上」的极端样本，对比重叠区域的混色 |
| R9 | **条件渲染分支错** | `guard active`（`:8949`/`:8822`）、`metrics.srcW > 0`（`:8822`）、`newW` 不可用（`:8804-8821` 有引擎模式前科） | 🟡 低 | 4 个状态各出一图：待机 / 驾驶无掩码 / 驾驶有掩码 / 驾驶+降级 |
| R10 | **圆角裁剪变化** | 原 `clipShape(RoundedRectangle(16))`（`:792`）裁的是整个 ZStack；若位图先按矩形烘、再由外层裁剪，圆角处应一致；但若位图自己不再被裁，四角会露出 | 🟡 低 | 四角 20×20 区域 diff |

### 4.2 性能风险（可能反而更差）

| # | 场景 | 为什么可能更差 | 判据 |
|---|---|---|---|
| P1 | **CA 本来就把静态光斑层缓存住了** | 若 `AuroraTheme.swift:701` 那句「可被 CA 缓存」为真，则光斑层的每帧成本≈0；烘成位图只省下「1 个 layer」，收益接近 0，而 CPU 多了 6.29MB 常驻 | **见 §5.0**：先用现成开关 `AURORA_DISABLE_LIGHT_FIELD=1` 量本层真实成本；若 WindowServer 降幅 < 0.5pp ⟹ 判定无效，整条方案停 |
| P2 | **CPU 光栅与推理抢主线程** | 15Hz tick 预算 66.7ms；叠 0.7~1.5ms 光栅不算多，但 `CGContext` 在 WindowServer 受压时（`AuroraDriveApp.swift:7160-7173` 记录过 `push` 可阻塞几十~几百 ms）**可能同步阻塞** | 看 `PerfBus` 的 `tick.consumeFrame`/新增打点的 p95、以及帧率是否掉到 <15Hz |
| P3 | **`layer.contents` 提交更频繁** | 现在每 tick 只提交 1 张画面（`:6717`/`:7194`）；若叠加层也逐帧提交，变成 2 张 ⟹ **每个 layer 一次 contents 变更都是一次 WindowServer 合成提交**（6 号文档 §188 的机理） | 必须做「输入指纹不变则不 push」；A/B 里对比「每次都 push」vs「变了才 push」 |
| P4 | **透明大位图的合成成本高于小层** | 1.57M px 的带 alpha 图层，WindowServer 要做整块 alpha 混合；而原来 Canvas 层可能已被 CA 按需裁剪重绘 | 观察 WindowServer 在「只画 1 个框」时是否仍整块重合成（可尝试让位图只覆盖**变化区域**，但这会破坏「单层」收益，列为后续备选） |
| P5 | **内存带宽与功耗** | 6.29MB × 15Hz = 94MB/s 的读写（若整块重画），叠加现有 8.57MiB/s 帧流（7 号文档 §370） | 看 `powermetrics` 的 CPU 能耗与温度（用户对发烫敏感） |
| P6 | **副屏场景收益可能为负** | 副屏 1200×1920、窗口更小 ⟹ 视口 pt 更小 ⟹ 位图更小（好）；但 `consoleScale ≈ 0.816` 的**非整数缩放**会让位图重采样，画面/线条质量下降 | 副屏单独测一轮 diff |

### 4.3 明确「应该放弃这个方案」的条件

按优先级：

1. **§5 步骤 1（光斑静态化）A/B 测出 WindowServer 降幅 < 1pp** ⟹说明静态模糊层本来就被 CA 缓存，整条 CPU 合成路线的收益前提不成立，**停**（省下后面所有工程）。
2. **文字基线无法保住**：`ObstacleLabelsOverlay` 拆出来后，胶囊与框的相对位置在 4 种状态下都无法稳定在 ±1pt ⟹ 停（红线优先于性能）。
3. **像素 diff 不达标**：掩码/框区域 `max|Δ| > 8` 或「车道线可见性下降」（细线断裂/变淡）⟹ 停。
4. **Aurora CPU 上升 > 5%（或单核 > +3pp）而 WindowServer 降幅 < 3pp** ⟹ 投入产出比不成立，停。
5. **GPU/WindowServer 降了但整体帧率反而掉**（<15Hz 或 `capGap` p95 变差）⟹ 停（用户要的是流畅，不是数字）。
6. **只能靠降低位图分辨率（< deviceScale）才能达标** ⟹ 直接停，因为那就是降清晰度。

---

## 5. 分步落地顺序（每步可独立 A/B）

### 5.0 第 0 步（**零代码改动，先做这个**）：用现成开关量出光斑层的真实成本

**这是本文最重要的执行建议**：在写任何 CPU 合成代码之前，先回答「光斑层到底贵不贵」。

- **怎么做**：`AURORA_DISABLE_LIGHT_FIELD=1` 启动（`AuroraFlags.swift:295` → `AuroraTheme.swift:593-604` `EmptyView()` 整层跳过），与不设该变量对比驾驶态 WindowServer / Aurora GPU+CPU。
- **判据**（**未测，需实测**）：
  - 若 WindowServer 降幅 **≥ 1pp** ⟹ 该层确实在花钱，§5 步骤 1~3 有收益空间，继续；
  - 若降幅 **< 0.5pp** ⟹ 说明 CA 早已缓存该静态模糊层（`:701` 那句注释是对的），**任何 CPU 化都是白做**，按 §4.3 第 1 条**停止整个方案**。
- **为什么必须先做**：这条用 0 行代码就能证伪整个方案的前提，比先写 800 行 CPU 合成再发现「本来就不贵」便宜得多。这与 `:597-598` 注释的自我怀疑完全一致（「若已缓存，则本层无可优化空间，任何 CPU 化都是白做」）。

> 每步都遵循：**默认关**（沿用本仓 `AuroraFlags` 的 `bool(_:default:)` + `== "1"` 约定，`AuroraFlags.swift:99-102`、`:289` 的 `enableBgDrift` 就是范式）⟹ 开/关都在同一份二进制里，A/B 不留分支债。
> 测量口径统一：① WindowServer 与 Aurora 的 GPU/CPU（沿用 6/8 号文档的做法）；② 像素 diff（复用现成夹具，见下）；③ 帧率与 `PerfBus` 打点 p95。

**现成的像素基线工具（已存在，无需新建）**：`MissionConsole.swift:7104-7130` 的 `renderQuestCard(...)` 用 **真实 `ViewportPanel`** + `ImageRenderer(content:)` + `renderer.scale = 2`（`:7115-7116`）出 PNG 到 `/tmp/aurora_mc_quest_card_<tag>.png`，并有 3 个状态（有任务 / 无任务 / 有任务无路线，`:7007-7072`）。**这就是天然的前后对比夹具**：改动前后各跑一次，逐像素 diff。`verify/` 下已有 `ui_pixels.py`/`ui_measure.py`/`coord_check.py` 一类脚本可复用于比对。

### 步骤 1（低风险 · 先做）：光斑静态化

- **做什么**：新增 `StaticBackdropHost`（§3.2），用 CPU 把「3 个径向渐变 + 一次 vImage 方框模糊×3」烘成一张 `CGImage`，替换掉 `:598` 的 `AuroraLightField`（保留 `AURORA_ENABLE_BG_DRIFT` 路径：开启漂移时**必须回退**到原 `AuroraLightField`，因为动画层无法烘）。
- **开关**：`AURORA_CPU_BACKDROP=1`（默认关）。
- **验收**：
  - 视觉：静态对比图（同一 `condition`）`max|Δ| ≤ 3`、`>2Δ` 像素占比 < 0.5%（光斑是柔和渐变，容忍度可略高于地图那种 0 容忍）。四边条带单独看（R7）。
  - 性能：驾驶态 WindowServer 降幅；Aurora CPU 增量。
  - **判定门槛**：WindowServer 降 ≥ 1pp 才进入步骤 2。
- **回退**：删一行视图替换 + 删 Host 文件。

### 步骤 2（中风险 · 收益主要在 CPU/合成层）：几何叠加层合并 + 文字拆除

- **做什么**：
  1. 把 `ObstacleOverlay` 里**文字部分**抽成原生 `ObstacleLabelsOverlay`（类别+置信度胶囊、LOCK 标签；位置用同一套 `aspectFillLayout` + `Detection` 数学，尺寸用 `Text` 的自然尺寸而非 `measure`）；
  2. 把剩余**几何部分**与 `MaskOverlay` 的几何合并进 `OverlayGeometryHost`（§3.5），**层序按 §3.3**（掩码在下、框在上）；
  3. `MaskOverlay` 的降级角标抽成原生 `MaskDegradedChip`；
  4. **输入指纹不变则不重画、不 push**（`MaskGrid`/`LetterboxMetrics` 已 `Equatable`；`[Detection]` 已 `Equatable`，`RuleController.swift:38`）。
- **开关**：`AURORA_CPU_OVERLAY=1`（默认关，且必须能与步骤 1 独立开关）。
- **验收**：
  - 视觉：4 个状态（待机 / 驾驶+掩码 / 驾驶无掩码 / 降级）逐图 diff；掩码区域 `max|Δ| ≤ 6`；车道线**可见性**用「细线连通性」目视 + 像素计数不得低于基线 90%。
  - 文字：胶囊与框间距 16±1pt（R5）；LOCK 标签位置一致。
  - 性能：对比「每次 push」vs「变了才 push」两条；看 `tick` p95 与帧率。
- **回退**：`AURORA_CPU_OVERLAY=0` 即回到两个原生 `Canvas`（旧实现**必须整体保留**在一个 `if` 分支里，不做半套替换）。

### 步骤 3（可选 · 只在 1+2 收益不足时评估）：单层化

- **做什么**：把画面 `FrameHost` 也画进同一张位图（路线 B，§3.5），或把背景渐变并入步骤 1 的底图以再省 1 层。
- **前置门槛**：步骤 1 的 WindowServer 降幅 ≥ 1pp，且步骤 2 之后 WindowServer 仍 > 40%（说明还剩合成成本可挖）。
- **验收**：`480×312 → 视口` 的 CPU 放大结果必须与现 CA `resizeAspectFill` 的**画面区域** diff 达标（`max|Δ| ≤ 4`，且不得出现可见的锐度下降/摩尔纹）；CPU 增量 < 2pp。
- **默认预期：不做**。因为它的质量判定最难通过，且 `push` 语义/停止逻辑改动面最大（§4.2 P3、§3.5 路线 B）。

### 5.4 附带发现（不在本方案内，但值得单独立项）

| 发现 | 证据 | 为什么值得单列 |
|---|---|---|
| 告警横幅用 `repeatForever` 常驻脉冲 | `MissionConsole.swift:1442`、`:1487`、`:1556` | 与 `AuroraTheme` 明令禁止的模式同款（`AuroraTheme.swift:203`/`:393`/`:504`），历史实测该模式让 WindowServer 51.2%→81.9%（`:664`）。但它只在告警出现时存在，**不能砍功能** ⟹ 应改成「一次性过渡」或降频脉冲，属于另一个 A/B 项 |
| `FrameHost` 无遮挡门控 | `AuroraDriveApp.swift:9021-9058`；6 号文档 §184、§253 | 纯浪费（被遮挡时仍 15Hz 提交 6.29MB 层内容），零视觉影响，与本文方案可叠加 |
| `QuestCard` 每帧重算 `blur(9)+blur(20)+plusLighter` | `:1374-1388`，文字每 tick 变 | 文字层无法合并的代价。可用「外层发光单独烘焙成静态 PNG（只随卡片尺寸变），文字层不参与 filter」来拆 —— 但**必须先证明发光层真的每帧重算**（**【未测】**） |

---

## 6. 证据索引

| 主题 | 位置 |
|---|---|
| `ViewportPanel` ZStack 全文 | `Sources/AuroraDrive/App/MissionConsole.swift:582-817` |
| 光斑实现 + 回退记录 + 漂移开关 | `Sources/AuroraDrive/App/AuroraTheme.swift:588-721`（回退 `:632-657`，`drift` `:705-706`，`blur` `:658`，现成开关 `:593-604`） |
| 光斑 blob 形状 | `AuroraTheme.swift:712-720` |
| 检测框 Canvas | `Sources/AuroraDrive/App/AuroraDriveApp.swift:8927-9010` |
| 掩码 Canvas + 网格映射 | `AuroraDriveApp.swift:8782-8925`（映射 `:8822-8840`，合并 `:8863-8885`） |
| `aspectFillLayout` | `AuroraDriveApp.swift:8743-8751` |
| `MaskGrid` / `LetterboxMetrics` | `Sources/AuroraDrive/Inference/YolopxEngine.swift:45-83`、`:93-161`（`inputSize = 640` 在 `:272`） |
| `Detection` 契约 | `Sources/AuroraDrive/Agent/RuleController.swift:38-63` |
| `FrameHost` / `FrameHostView` | `AuroraDriveApp.swift:9020-9058` |
| `FrameHost.push` 调用点 | `AuroraDriveApp.swift:6717`、`:7194`（锁外推屏记录 `:7158-7174`） |
| tick 15Hz | `MissionConsole.swift:6221-6260`（`repeating: 1.0/15.0` 在 `:6233`） |
| 控制台缩放 `scaleEffect` | `MissionConsole.swift:7624-7695`（`scale = width/1470` 在 `:7675`） |
| 色彩空间前科（必须 sRGB） | `MissionConsole.swift:2632-2646` |
| 像素 diff 夹具 | `MissionConsole.swift:7007-7130`（`ImageRenderer` + `scale = 2` 在 `:7115-7116`） |
| `AuroraFlags` 布尔约定 | `Sources/AuroraDrive/Core/AuroraFlags.swift:99-102`（`bool` 只认 `"1"`）、`:289`（`enableBgDrift`）、`:295`（`disableLightField`） |
| vImage 模糊 API | `…/MacOSX.sdk/…/vImage.framework/Headers/Convolution.h:3165`（Box）、`:692`（自定核） |
| 既有 CPU 位图写法（可照抄） | `MissionConsole.swift:2746-2775`（`CGContext` + `makeImage()`）、`Sources/AuroraDrive/Inference/YoloEngine.swift:776-799`（直写 `CVPixelBuffer`） |

### 6.1 本文所有「未测 / 估算」汇总

| 断言 | 状态 |
|---|---|
| 「CA 能缓存静止光斑的 60px 模糊结果」（`AuroraTheme.swift:701`） | **【未测】** 本文不承认也不否认，靠 §5.0 现成开关实测判 |
| 合并后 WindowServer 能降多少 | **【未测】** 只能实测 |
| 每 tick 光栅 0.7~1.5ms、CPU 1~2.3% 单核 | **【估算】** 依据见 §3.6 表 |
| 光斑烘焙 3~10ms | **【估算】** |
| 视口设计尺寸 702×~560pt | **【估算】** 由布局常量推导，高未实测 |
| `MaskGrid` 是否每 tick 变 | **【未测】** 取决于模型节流 |
| `QuestCard` 发光是否每帧重算 | **【未测】** |
| 副屏 `consoleScale ≈ 0.816` 的具体值 | **【估算】** 按窗口宽 1200 / 1470 算，实际窗口宽未测 |

### 6.2 行号复核记录（2026-10-24 23:46）

取证期间发现 `AuroraTheme.swift`（mtime **23:41:05**）与 `AuroraFlags.swift`（**23:41:53**）被**并发工作**改动（新增 `AURORA_DISABLE_LIGHT_FIELD` 开关），导致这两个文件的行号整体下移约 15 行。本文已按当时最新版本逐条复核修正。

关键锚点复核结果（命令：`sed -n '<行>p' <文件>`，输出与断言一致）：

| 断言 | 引用 | 复核输出（节选） |
|---|---|---|
| 漂移默认关 | `AuroraTheme.swift:705-706` | `let driftEnabled = ProcessInfo...["AURORA_ENABLE_BG_DRIFT"] == "1"` / `if driftEnabled { drift = true }` |
| 模糊半径 | `AuroraTheme.swift:658` | `.blur(radius: 60)` |
| 光斑 A/B 开关 | ~~`AuroraTheme.swift:593-604`~~ | **已撤销**（测量完成，见附录 A）；当时内容为 `if AuroraFlags.disableLightField { EmptyView() } else { core }` |
| 开关定义 | ~~`AuroraFlags.swift:295`~~ | **已撤销**；当时内容为 `static let disableLightField = bool("AURORA_DISABLE_LIGHT_FIELD", default: false)` |
| 掩码绘制守卫 | `AuroraDriveApp.swift:8822` | `guard active, metrics.srcW > 0 else { return }` |
| 掩码/框坐标基准 | `AuroraDriveApp.swift:8950` | `let t = aspectFillLayout(source: sourceSize, view: size)` |
| 模型输入尺寸 | `YolopxEngine.swift:272` | `nonisolated static let inputSize = 640` |
| 画面层 | `MissionConsole.swift:588` | `FrameHostView(host: state.frameHost)` |
| 掩码层位置 | `MissionConsole.swift:618` | `MaskOverlay(active: state.isDriving && state.showYolopxMasks,` |
| tick 频率 | `MissionConsole.swift:6233` | `timer.schedule(deadline: .now(), repeating: 1.0 / 15.0, ...)` |
| 控制台缩放 | `MissionConsole.swift:7675` | `let s = size.width / ConsoleMetrics.designWidth` |

> **纪律说明**：本表只记录**实际执行过**的 `sed` 读取。`MissionConsole.swift` / `AuroraDriveApp.swift` 在取证期间 mtime 未变（18:43 / 20:12），可稳定引用；两个被并发改动的文件请以符号名 grep 为准。

---

# 附录 A：光斑层 A/B 实测（2026-10-25 00:00，Lead 串行实测）

> 本文 §4.3 第 1 条要求的「第 0 步先测，别写代码」已执行。**结论是停止**。
> 以下为原始数据与判定，供后人不再重复这一轮。

## A.1 方法

临时给 `AuroraLightField` 加诊断开关（`AURORA_DISABLE_LIGHT_FIELD=1` 整层 `EmptyView`），
默认关闭、行为不变。ABAB 交错 8 轮（A=开光斑，B=关光斑），每轮：

- 全新进程（UI + 引擎各 1 个，等待稳定为 2 个才测）
- 主窗口固定到 (120,140)，1200×760
- `caffeinate -dimsu` 防显示器休眠
- `ioreg AGXDeviceUserClient.accumulatedGPUTime` 差分，窗口 12s
- 每轮记录背景 GPU 客户端（ego Helper / QQ Helper 等，均 <1%）

状态：**未驾驶**（`AURORA_OBSERVE_ONLY=1`，不推新帧），此时光斑是该窗口里唯一的动态合成内容，隔离最干净。

## A.2 数据

| 轮次 | 光斑 | WindowServer GPU | Aurora GPU | Aurora CPU（单核） |
|---|---|---|---|---|
| A1 | 开 | 7.64% | 0.00% | 1.92% |
| B1 | 关 | 7.63% | 0.00% | 2.00% |
| A2 | 开 | 7.41% | 0.00% | 2.17% |
| B2 | 关 | 8.54% | 0.00% | 2.00% |
| A3 | 开 | 7.45% | 0.00% | 2.08% |
| B3 | 关 | 7.76% | 0.00% | 2.00% |
| A4 | 开 | 7.34% | 0.00% | 1.92% |
| B4 | 关 | 7.46% | 0.00% | 2.08% |

- 开光斑中位数 **7.43%**；关光斑中位数 **7.70%**
- 逐对差值（关−开）：−0.01 / +1.13 / +0.32 / +0.13，中位数 **+0.22pp**
- 中位数差 **+0.27pp**

**关键旁证（证明开关真的生效，不是没测到）**：A1 与 B1 的窗口截图比对
`MAE=3.57`、`maxdiff=222`、`>8` 像素占 **15.65%** —— 光斑确实被整层移除了，
画面肉眼可见地变了，**而 GPU 一点没降**。

## A.3 判定

**光斑层合成成本 ≈ 0（0.27pp，远在噪声内）。**

原因印证了源码 `AuroraTheme.swift:697-701` 那句此前从未被验证的注释：
漂移动画默认关闭 ⟹ `.offset` 是常量 ⟹ **静态模糊结果已被 Core Animation 缓存**，
不再每帧重算。当年 `.drawingGroup()` 之所以失败（并让情形更糟），是因为它把
「已缓存的一次卷积」换成了「每帧重建离屏纹理」。

## A.4 推论（重要）

1. **本设计文档的「第 1 步：光斑 CPU 烘焙」作废** —— 零收益，不要做。
2. 光斑是三个叠加层里最容易被误判为「GPU 大户」的一个（`blur(60)`、面积 1.9 倍窗口），
   实测却是 0。**说明「看着重」和「实际重」在 macOS 合成里没有相关性**，
   任何后续合并方案都必须逐层先测、再写代码。
3. 由此推断（**未测，仅作假设**）：合并多层若只省「已缓存的静态层」，
   收益同样会接近 0。真正可能有成本的是**每帧新内容的层**，
   即画面层 `FrameHost` 每帧写 `layer.contents`（480×312 被合成器放大到 1200×760）。
   这才是下一个该测的对象，而不是静态层。

## A.5 未测项（含一处**已撤销的错误纠正**）

- ⚠️ **撤销（2026-10-25 01:20 复核后）**：本节曾写「A.1 把 `fp_ab` 的『12s 内 0 新帧』
  解释为『桌面静止、抓屏不出帧』是错的，真因只是日志 15s 一行」。
  **这个"纠正"本身是错的，现予撤销。** 复核证据：
  - 「15s 日志周期」**确实是**一个真实测量缺陷：`[ENGINE] 统计:` 实测恒为 15.0s 一行，
    采样窗短于 15s 时会读到同一行、`帧数` 显示 +0。所以 `+0` **本身不能证明**「没有帧」。
  - 但 `fp_ab` 的运行记录里 `da=0`（检测格数 0），且引擎日志显示该时段帧数**确实停滞**
    （`00:06:44 帧数=197` → `00:07:15 帧数=196`）。两个原因并存。
  - 正确表述：`fp_ab` 那轮**什么都没测到**，既不能证明「无浪费」，也不能证明「有浪费」，
    不能用来支持任何一方结论。
- **推帧 vs 冻结推帧的成本**：**未测**。两次尝试（`frz_ab` 00:57、`presbench` 01:10）
  都因**屏幕锁定**导致抓屏停帧而作废，实测过程与教训见**附录 C**（该附录无数据，只有失败记录）。
- 驾驶态下 `FrameHost` 每帧换图 + 合成器放大各占多少 GPU —— **未测**。
- 本机 WindowServer 基线随桌面内容剧烈漂移（同一二进制不同时段测到 7.4% / 9.8% / 13.8% / 44%），
  绝对数值不可跨时段比较，只能同会话内交错对照。这一点在解读任何 WS 数据时都必须牢记。

---

# 附录 B：重复推屏实测（2026-10-25 00:45，Lead 串行实测）

## B.1 被检验的假设

读代码发现一条**看起来像纯浪费**的路径：

- `EngineClient.poll()` 在无新帧时**返回缓存的同一个 `CGImage` 对象**
  （`Core/EngineClient.swift:646`：`guard seq != lastFrameSeq else { return frameCache }`）
- 而 `tickEngineMode()` 每 tick **无条件**推屏（`App/AuroraDriveApp.swift:6717`：`frameHost.push(cg)`）

若抓屏偶尔不出帧，那么「把同一个对象反复写进 `layer.contents`」就是零视觉收益的重复合成。
这符合本项目「纯浪费」的定义，值得一试。

## B.2 方法

给 `FrameHost.push` 加**指针同一性**比较（`lastPushedImage === image`；同一对象 ⟹ 像素必然逐字节相同 ⟹ 跳过视觉零变化），
`AURORA_PUSH_TRACE=1` 时每 30 次推屏打一行统计。默认开关关闭时行为逐字不变。

真实应用、引擎模式、`有帧=true`、`driving=true`、`AURORA_DIGEST=1`、caffeinate 在场，跑 25 秒。

## B.3 结果

```
[push] 推屏尝试=720 同一对象=0 重复率=0%
```

引擎侧同期：帧数 **197 → 647**（30 秒，约 15 帧/秒，连续产帧）。

## B.4 判定：**假设证伪，不做**

抓屏在持续出帧（15fps），`poll()` 每次拿到的都是**新建**的 `CGImage`，
不存在「重复推同一帧」。**重复率 0% ⟹ 无浪费可回收。**

代码已按改动前备份精确还原（`git hash-object` 逐字节校验一致），未留任何诊断残留。

## B.5 推论

`push` 确实是「每 tick 换一张**新**图」，不是冗余写入。于是：

- 附录 A 排除了「静态层（光斑）」——CA 本就把静态层缓存住了，成本≈0（有截图 + 8 轮 A/B 双证据）
- 附录 B 排除了「重复写入」——发生率本身就是 0（硬事实：`0/720`）
- 隔离基准 `compbench` 测「CPU 先放大再上屏」：`large−small = +0.43pp`，方向为**更贵**；
  但该差值低于本机 ~5pp 的噪声下限，**只能记作「未测出收益」，不能记作「已排除」**

合起来：**画面层这一环没有「已测出」的可回收纯浪费**。
它每帧做的是「一张新图 → 交给合成器放大上屏」，而合成器在进程之外、无 CPU 替代路径
（这是结构事实，不依赖任何测量）。
**「把画面改由 CPU 跑」在本项目上没有可行路径；能省的部分也已证明不是浪费。**

## B.6 更正

- ⚠️ **撤回一句话**：本节原先论证「即使测出正向数字**也不会产生任何 CPU 方案**，所以不必测」——
  该推理不成立（数字本身有诊断价值）。同时此处曾声称「已用修正门禁在附录 C 重测」，
  但**附录 C 并无任何实测数据**（该轮被锁屏污染作废），故不作「已测」声称。
  推帧成本与画面呈现成本的现状：**未测**。
- 本机 WindowServer 基线漂移极大（同一二进制不同时段 7.4% ~ 44%）；
  `compbench` 同相位两次读数曾差 11.4pp。**任何小于 ~5pp 的差值在本机都不可判定**，
  这也是本轮只认「0% 发生率」这类硬结论、不认小差值 GPU 百分比的原因。

---

# 附录 C：推帧成本 / 画面呈现成本 —— **两次尝试全部作废，未测**

> 本附录**没有任何有效数据**。它存在的唯一目的：把失败原因和我的方法缺陷钉下来，
> 避免以后有人（包括我自己）把「没测出来」误读成「测过了、没问题」。

## C.1 想回答的问题

用户的核心问题是「画面能不能用 CPU 跑」。C.5 的主结论不依赖本附录（那是结构事实）。
本附录只想补一个**量化**：把画面呈现到屏幕上，到底占多少 WindowServer 成本。
两个角度：

- **推帧成本**：`FrameHost.push` 每 tick 写 `layer.contents` 的增量开销
- **呈现成本**：窗口可见（参与合成）vs 不可见的差价

## C.2 尝试一：冻结推帧 A/B（2026-10-25 00:57–01:01）

**做法**：给 `FrameHost.push` 加 `AURORA_FREEZE_PUSH`（**只放行首帧**，之后不写
`layer.contents`，画面冻结）+ `AURORA_PUSH_TRACE`（每 30 次 push 打一行）。
放行首帧是必需的——否则窗口无内容（黑底），A/B 就变成「有画面的窗口 vs 空窗口」，
会把「维持窗口可见的固定成本」误算进「每帧换内容的增量成本」。

**开关有效性已验证**（这一步是真的）：

```
[push] 收到=1   写入=1（首帧放行，此后冻结）
[push] 收到=30  写入=1（已冻结，仅首帧）
...
[push] 收到=210 写入=1（已冻结，仅首帧）
```

**6 轮 ABABAB 结果**（WindowServer GPU 占比）：

| 轮次 | 模式 | WS |
|---|---|---|
| A1 | 正常推帧 | 32.78% |
| B1 | 冻结 | 31.93% |
| A2 | 正常推帧 | 30.32% |
| B2 | 冻结 | 36.59% |
| A3 | 正常推帧 | 30.53% |
| B3 | 冻结 | 32.85% |

中位数：正常 **30.53%**、冻结 **32.85%**，差值（冻结−正常）**+2.31pp**；
逐对 `[-0.85, +6.27, +2.31]`。

**判定：作废。** 理由：**冻结只能减少工作、不可能增加工作**，出现「冻结更贵」
说明数据被环境噪声或其它进程污染，不具备解释力。不采信任何一方。

## C.3 尝试二：画面呈现 A/B（2026-10-25 01:10–01:13）

**做法**：不改源码，只切窗口可见性——A 相正常显示，B 相 `NSRunningApplication.hide()`。

为什么不用 AppleScript：`tell process "AuroraDrive" to count of windows` 返回 **0**
（另一个同名进程直接报 `-1728`），拿不到窗口几何；改用 `CGWindowListCopyWindowInfo`
读窗口（不需要辅助功能授权）+ `hide()` 切可见性。

**6 轮全部被前置门禁拦下**，一条有效数据都没有：

```
[A1] 显示 WS=38.97% 引擎帧 1321→197 (+-1124) 可见=是 窗口=1 168x46
[B1] 隐藏 WS=30.82% 引擎帧 197→196  (+-1)    可见=否 窗口=0
[A2] 显示 WS=34.45% 引擎帧 196→196  (+0)     可见=是 窗口=1 168x46
...
```

## C.4 根因：**屏幕锁定**，抓屏停帧、主窗口不参与合成

两条硬证据：

1. `CGSSessionCopyCurrentDictionary()` → **`CGSSessionScreenIsLocked = 1`**
2. 同一时刻 `screencapture -x` 的结果是**锁屏界面**（显示"使用触控ID或输入密码"，
   而非应用画面）

由此解释了两个自相矛盾的现象：

- **主窗口 `1200x760` 在 CGWindowList 里 `onscreen=N`**，屏上只有 `168x46` 的 HUD
  ⟹ 应用主画面当时根本没有被合成上屏，所以「呈现成本」A/B 测的是 **不存在的东西**
- **引擎 `帧数` 停滞**（`01:11:30 帧数=196`、`01:11:54 帧数=196`、`01:12:17 帧数=196`…）
  ⟹ 锁屏后桌面无变化，ScreenCaptureKit 不出新帧

## C.5 我的方法缺陷（比环境问题更该记住）

**第一版门禁用错了计数器。** 我用 `[push] 收到=N` 的增长当「帧在流入」的证据，
但那个计数器统计的是 **tick 调用次数**，不是**新帧数**——
`EngineClient.poll()` 在无新帧时返回缓存的同一个 `CGImage`
（`Core/EngineClient.swift:646`），tick 照样每帧调用一次。
所以「`收到` 增长」**根本不能证明有新帧**。C.2 那轮的门禁因此形同虚设。

正确判据应该是：一个**只在拿到新 `CGImage` 时**才递增的计数器，且采样窗 > 15s
（`[ENGINE] 统计:` 实测恒为 15.0s 一行，窗口短于 15s 会读到同一行、显示 +0）。

## C.6 结论

**推帧成本、画面呈现成本：未测。无数据。** 不作任何「已测出/已排除」的声称。

这次失败**不改变**主结论——主结论是结构性的，不依赖这两个数字：

- ⚠️ **更正（2026-10-25 11:00）**：本节此前写「全仓零 GPU 编程（`MTLTexture`/`MTLCommandQueue` 各 0 处）」——
  **这句是错的**，现予撤回。实测扫描结果：`Vendor/MetalGoose/Engine` 被编进主 target
  （`Package.swift` 的 `sources` 白名单），其中 `MTLTexture` **85 处**、`MTLDevice` **8 处**、
  `MTLCommandQueue` **4 处**、`MTLCreateSystemDefaultDevice` **2 处**、
  `makeComputePipelineState` **2 处**。另有 **6 处** CoreML `.all` 档位（4 个文件，默认可能派到 GPU；
  对照：`.cpuOnly` 8 处、`.cpuAndNeuralEngine` 4 处）。清单见 `11-gpu-users.md`。
  准确表述：**仓库里有 Metal 代码，且每次 UI 启动都会建 Metal 设备/队列并编译着色器
  （`upscaleHost.prepare()`），但插帧开关默认关（`upscaleEnabled = false`），
  所以默认不提交逐帧渲染。**「不碰 GPU」是**开关层面的约定**，不是「代码里没有 Metal」。
- 合成器（WindowServer）在进程之外，**没有任何 API 能让它改用 CPU**
- 静态层已被 Core Animation 缓存（附录 A 双证据）
- `push` 不是冗余写入（附录 B：`0/720` 重复率）
- 唯一会抢 GPU 的 `m9_v2_ctl` 已改 `.cpuOnly`；`sample` 栈 GPU 占比 **0**

**未来若要补测，前置条件（缺一不可）**：

1. `CGSSessionScreenIsLocked == 0` —— 每次测量前后各查一次
2. 应用主窗口在 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 里存在，
   且尺寸接近 1200×760（不是 168×46 HUD）
3. 用一个**只在新帧到达时递增**的计数器作为帧流门禁，采样窗 ≥ 20s
4. 三对以上同向差异才可下结论（本机 WindowServer 基线漂移 7.4%~44%，<5pp 不可判定）

## C.7 现场状态（收尾核对）

- 源码已按改动前备份精确还原：`AuroraDriveApp.swift` = `f0d386769cfb…`、
  `AuroraFlags.swift` = `bbc98a5a6f2a…`，`git hash-object` 逐字节校验一致
- 诊断开关残留（`freezePush` / `pushTrace`）：**0 处**
- 用户正在用的部署副本未被触碰：sha256 `dfdeb51d6c95…`（未变）
- Aurora / caffeinate / 各基准工具进程：**0 个**残留
