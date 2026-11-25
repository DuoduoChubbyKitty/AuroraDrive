# 代码-29 ControlWiring / MapWiring / LocateRuntime（控制台接线与地图数据层）
> ✅ **文件名已修正（2026-10-17）**：原名中的 `MinimapLocatorView` 已在 UI 大改版删除（纯逻辑类型析出到 `LocateRuntime.swift`），本文已改名为 `代码-29-ControlWiring与MapWiring.md`，与内容一致。
>
> ✅ **2026-10-18 复核（agent-reader）**：逐条 `read` + `grep -n` 核对。本次修订：
> - **修正 `pushConfig` 字段数**（§一③）：原文写「**7 字段**」，实测 **9 字段**（sport/controlDisabled/forceRule/expert/glyph/degradeThreshold/speedLimit + **digest** + **perceptionMode**）。后两个是后续追加的（digest 防误注入、perceptionMode 档位 IPC），原文未同步。
> - **新增 `takeover` 发送路径说明**：`takeover` 字段**不在 `pushConfig` 里**——它由 `AuroraDriveApp` 的 KeyboardMonitor 回调**独立 `sendCommand("config", extra: ["takeover": true/false])`** 发送，经 `EngineMain` 的 `case "config"` 解析。故 config IPC 的完整字段集是 **10 个**（9 在 pushConfig + 1 独立发 takeover），但 pushConfig 本身只有 9 个。
> - **修正 SpeedLimitGuard 与 AutoRoadCondition 的位置描述**（§一④⑤）：以代码为准——`final class SpeedLimitGuard` 之后紧接 `enum AutoRoadCondition`，两者的先后关系与归属不变；本档现按**类型名**定位，不再依赖会漂移的区间数字。
> - **修正 `regionName` 遍历数**（§二）：原文「遍历 **5677** 标记一次」→ **1777**（2026-10-04 换源到 `map_locations.json` 后，`MapDatabase.markers` 只有 1777 个点；源码注释里的 5677 是旧库 `FINAL_complete_map_database.json` 的历史引用）。
> - **确认无误**：`stabilityFrames = 10`（20Hz 下约 0.5 秒）属实；6 档路况阈值（>70/>50/>30/>20/≤10 + 11–20 滞回带）属实；`speedLimitRange = 20...200` / `unlimitedThreshold = 200` 属实；`minimapSpanMeters = 160` 属实；`MapDatabase` 1777 点属实；三级刹车时间窗属实。
>
> **✅ 符号级复核（2026-10-18，merge-tools）**：三文件均未改动，逐条复核全部位置引用，**历史行号已作废**——本档现按类型名/函数名定位：`ControlWiring` 的 `RoadCondition` 扩展、`SpeedLimitSource`、`DriveState.autoSpeedTarget`、`DriveState.unlimitedLockedByUser`、`DriveState.applyRoadCondition`、`DriveState.setAutoSpeed`、`DriveState.setSpeedLimit`、`DriveState.selectGear`、`DriveState.pushConfig`、`DriveState.driveBars`、`SpeedLimitGuard`（含 `enum Stage`）、`AutoRoadCondition`（含 `stabilityFrames`）；`MapWiring` 的 `worldToMapPixelX/Y`、`mapPixelToWorldX/Y`、`minimapSpanMeters`、`normMapX/normMapY`、`normMapXLarge/normMapYLarge`、`MapDatabase`（`ensureLoaded` / `markersInView` / `markersInViewAll` / `regionName`）、`PlacedMarker.stableID`；`LocateRuntime` 的 `LocateGate` / `LocateContext`。均 grep 验证存在。
>
> 覆盖源文件：`Sources/AuroraDrive/App/ControlWiring.swift` + `Sources/AuroraDrive/App/MapWiring.swift` + `Sources/AuroraDrive/App/LocateRuntime.swift`。本档所有代码位置按**真实符号名**引用，不再使用会漂移的行号。
> ✅ **覆盖范围**：三个文件均按类型/函数级符号引用（`ControlWiring` 的 `DriveState` 扩展与 `SpeedLimitGuard`/`AutoRoadCondition`、`MapWiring` 的坐标映射与 `MapDatabase`、`LocateRuntime` 的 `LocateGate`/`LocateContext`）。原文「475 行」等旧的行数统计已作废。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `App/MinimapLocatorView.swift`（196 行）——该文件已在 UI 大改版中删除，纯逻辑类型（LocateGate/LocateContext）被析出到 `LocateRuntime.swift` 单独留存（源码头注释实录），UI 侧由 MissionConsole 的 MiniMapCard/MiniMapCanvas 承载。本档现按三个新文件的实际内容重写。

## 一、ControlWiring — 任务控制台功能接线层

**文件头原则**："界面（A-任务控制中心.html 的 SwiftUI 版）与真实引擎之间的**唯一通道**。界面上的每一个可点元素，背后都必须有一条真的执行路径。**没有执行路径的，宁可不画**。" 接线清单六项：① 路况自适应 4 态 ② 自动速度开关 ③ 四挡降级链 ④ 限速滑块 ⑤ 18 项技能 ⑥ 引擎 9 命令。

### ① 路况 → 限速映射（`extension RoadCondition`）

**6 档 autoSpeedLimit（用户 2026-09-22 定义）**：simple→**nil（≤10 框不限速）** / easy→150（21–30 框）/ medium→100（31–50）/ busy→60（51–70）/ extreme→**20（>70 框最保守）** / off→nil（**不干预**）。

**⚠️ .simple 与 .off 语义区分（`RoadCondition.meansUnlimited` / `drivesSpeed`）**：两者 autoSpeedLimit 都是 nil 但完全不同——.simple = 自动速度**在工作**，结论就是不限速；.off = 自动速度**没在工作**。`meansUnlimited`（`self == .simple`）与 `drivesSpeed`（`autoSpeedLimit != nil`）承载该区分。

`color(forDetectionCount:)`：按框数取状态色（与判定阈值同源，UI 上色用）。

### ② SpeedLimitSource 与优先级（`enum SpeedLimitSource` + `autoSpeedTarget` 纯函数）

`enum SpeedLimitSource { user / auto / none }`——**谁把车推到「不限速」的**。DriveState.unlimitedSource 记录归属。

**`autoSpeedTarget(for:currentLimit:unlimitedSource:enabled:) -> Double?`——纯函数，生产路径与 --limit-selftest 共用同一份实现**（63 次自测全 PASS 的对象）。抽出原因（源码注释）：优先级规则此前分散在 3 处（tick 门禁/applyRoadCondition/setAutoSpeed），任一处漏改就死锁。**优先级（用户明确定义，不可调换）：用户手动不限速 > 自动速度 > 手动路况**——① 用户手动不限速（`currentLimit >= 200 && source == .user`）→ 一切自动逻辑让路返回 nil；② 简单档结论就是不限速（返回 unlimitedThreshold）；③ 其余档位下发各自限速（.off 为 nil 不干预）。**若不区分来源会死锁**：自动设成不限速 → isUnlimited=true → 自动速度被自己的门禁挡住 → 框数涨回来也永远解不开（源码注释）。

`unlimitedLockedByUser`：`isUnlimited && unlimitedSource == .user`——只有用户手动不限速才锁死自动速度。

### ③ DriveState 扩展接线（`extension DriveState`）

- **`applyRoadCondition(_:)`**：落 roadCondition → 极复杂（needsTakeover）**自动置 forceRuleMode 并 pushConfig**（安全优先，不等降级链慢慢降；离开解除）→ 自动速度联动（autoSpeedTarget 判定后 setSpeedLimit）
- **`setAutoSpeed(_:)`**：开关自动速度，开启立刻按当前路况下发一次
- **`setSpeedLimit(_:reason:source:)`**：限速范围 `speedLimitRange = 20...200`，`unlimitedThreshold = 200`（"不限速"用 200 表示）；夹紧 + 变化才下发 + **记录 unlimitedSource 归属**（≥200 时记 source，否则清 .none）+ pushConfig
- **`selectGear(_:)`**（四挡降级链人工干预）：GEAR 1/2（模型侧）→ 解除 forceRuleMode（"人工只能表达我希望走模型，不能伪造 M9 活着"）；GEAR 3/4（规则侧）→ 置 forceRuleMode。界面高亮始终跟随引擎回报的 mode
- **`pushConfig(reason:)`**（config 下发唯一出口）：**9 字段**（✅ 2026-10-18 修正，原文写「7 字段」）——`sport` / `controlDisabled` / `forceRule` / `expert` / `glyph` / `degradeThreshold` / `speedLimit` / **`digest`** / **`perceptionMode`** → `EngineClient.sendCommand("config")`——引擎端对应 `EngineMain` 的 `case "config"`；**speedLimit 直接进推理**（vehicle_state[4]），不同步=UI 显示 40 模型按 120 决策
  - **`digest`**：消化模式（引擎侧唯一注入点截住，`postedEventCount` 不增）——不同步 = UI 开了「不真发按键」但引擎照旧真注入（源码注释记录了真实事故）
  - **`perceptionMode`**：`"ayolom"` / `"legacy"` 字符串 IPC 协议字段，**显式映射**而非用枚举 rawValue（`PerceptionMode.rawValue` 是中文显示名、`PerceptionModelFamily.rawValue` 无 `legacy`），见 task-95 注释
  - ⚠️ **`takeover` 不在本函数内**（config 的第 10 个字段，独立发送）：由 `AuroraDriveApp` 的 KeyboardMonitor 回调直接 `sendCommand("config", extra: ["takeover": true/false])`，引擎侧 `EngineMain` 的 `case "config"` 分支解析 `let cTakeover = obj["takeover"] as? Bool` → `EmergencyTakeover.noteUserKeyDown/Up`。**故 config IPC 全字段集 = 10，而 pushConfig 只发其中 9 个。**
- **`driveBars`**：四条控制量归一化快照（steer ±1 / throttle 0-1 / brake 0-1 / speed 相对限速）→ UI 底部四条进度条

### ④ SpeedLimitGuard — 限速闭环执行器（三级刹车；`final class SpeedLimitGuard` 起始，止于 `enum AutoRoadCondition` 之前）

**设计要点（`SpeedLimitGuard` 类头注释）**：触发源=速度模型真实读数（speedOCR/引擎回传），**纯规则覆盖、不走任何神经网络**（"刹车这件事不允许被模型置信度影响"，用户明确要求"千万不能用模型来实现"）；不限速（≥200）→ **整个闭环彻底停用**（短路，不是把阈值设大）。

**三级刹车（`SpeedLimitGuard.Stage` enum）——解决"持续手刹=车辆失控"的根因（源码注释：手刹锁死后轮，高速下后轮失去抓地 → 甩尾 → 车头打转）**：

| 级 | 阶段 | 时间窗 | 行为 |
|---|---|---|---|
| ① liftOnly | 松油门 | 超速 0–0.6s | 只松 W+Shift（风阻+发动机制动，多数情况够用） |
| ② pulse | 点刹 | 0.6–2.5s | **脉冲手刹**：pulseOn=0.18s 按下 / pulseOff=0.22s 松开交替（占空比 ~45%，轮胎周期性恢复抓地） |
| ③ firm | 持续刹 | >2.5s 仍超速 | 持续按空格（最后手段） |

- `update(speedKmh:speedValid:limitKmh:dt:) -> Bool`：四道前置闸——不限速→短路 / **speedValid=false 不动作（不能拿不可信读数踩刹车）** / 未超速（margin=1.0km/h 余量防抖动）→ 退出；超速累计 overspeedSeconds → 分级；返回 true 时调用方跳过 AI 决策键
- **峰值留档（`reset()` 内的 lastBrakeSeconds/lastStage/lastOvershoot/lastPulseCount 留档）**：reset() 清零前把本轮 lastBrakeSeconds/lastStage/lastOvershoot/lastPulseCount 留档——否则刹车结束后读到的永远是 0/待命，日志无法诊断"刹了多久、到没到持续刹"
- 诊断状态：stage / handbrakeDown（点刹真假交替）/ overspeedSeconds / overshoot / pulseCount

### ⑤ AutoRoadCondition — 路况自动判定（`enum AutoRoadCondition`，`stabilityFrames` 为其静态常量）

**用 YOLO 实测检测框数量判定**（不用模型置信度——框数是直接观测可解释可验证，置信度是黑箱，"让模型既当运动员又当裁判"是用户明确禁止的）。阈值（`AutoRoadCondition` 内集中一处、`legendText` 与 UI 说明文字同源）：**>70 极度复杂 / >50 繁忙 / >30 中等 / >20 轻松 / ≤10 简单（不限速）**；**11–20 为滞回带**（保持原状，防反复横跳）；`stabilityFrames = 10`（20Hz 下约 0.5 秒稳定门——同一判定需连续成立 10 帧才切换，防单帧抖动导致限速跳变触发刹车；源码注释明写「若将来再改帧率，请按 `≈0.5s × 帧率` 重算」）。`legendText` 读常量生成阈值说明文字。

## 二、MapWiring — 小地图/大地图真实坐标映射

**数据链（头注释）**：CoordinateCapture 抓包 → 世界坐标(UE5 厘米) → worldToMapPixel 校准变换 → 地图像素(13056×13056) → 视口归一化 → 渲染。**派生量一律现算不缓存**——定位一变地图立刻动；未锁定时 mapPixelX/Y 返回地图中心，由调用方按 locatorFound 决定显示。

- **`worldToMapPixelX/Y`（static）**：直接引用 **CoordinateCapture 的全局扩图版校准常量**（kCalibA/B/TX/TY——map-2026-08 13056 版；NetworkLocator 已于 2026-09-25 同步对齐同值，见代码-16 修复记录）；公式与 CoordinateCapture.worldToMapPixel 完全一致
- **mapPixelX/mapPixelY**：自车地图像素；**minimapSpanMeters = 160**（小地图固定展示自车周围 160 米真实地图——9-22 修复的"spanMeters 是 private let 常量、缩放从来没写过"的反面）
- **egoNormX/Y 恒 0.5**：自车恒在视口中心（地图跟着车走，高德/百度标准做法）
- **normMapX/normMapY**：任意世界坐标 → 小地图视口归一化（相对自车偏移换算，夹紧 0.06–0.94）
- **`MapDatabase`**：离线地图数据库（`models/map_locations.json`，1777 标记；2026-10-04 换源，原 `FINAL_complete_map_database.json` 的 5677 点因坐标中位差 2463px ≈1500 米已弃用）——`ensureLoaded()` 后台队列幂等加载（**projectRoot() 定位，双击 .app 时 cwd 是 "/"**）；新库 x/y 已是**地图像素坐标**（与 worldToMapPixel 同系），不再做百分比换算；找不到文件计数如实显示 0
- **`markersInView`**：方形视野内标记查询，按距离由近及远排序取 limit 个（近处细节优先绘制）；另有 `markersInViewAll` 供聚类路径用，不截断数量
- **`regionName`**：实时坐标反查最近标记的区域——**格缓存（100px 一格）**：同格直接命中，跨格才遍历标记一次（9-24 优化改动 20：-99% 遍历）。✅ 2026-10-18 修正：原文写「遍历 **5677** 标记」→ 实际遍历 **1777** 个（2026-10-04 换源到 `models/map_locations.json`，`MapDatabase.markers` 现为 1777 点；源码注释里残留的 5677 是对**旧库** `FINAL_complete_map_database.json` 的历史说明，非当前数据量）
- **`PlacedMarker.stableID`**（声明 / `init` 内赋值）：存储属性（init 算一次，直接取数据库 `id`，不再拼 "kind#name#x#y"）——ForEach 身份稳定（9-24 优化改动 16）
- **`normMapXLarge` / `normMapYLarge`**：大地图归一化（spanPx 参数化，夹紧 0.03–0.97）——**注意这两个在 `extension DriveState` 里，而 `enum MapDatabase` 已在它们之前结束**

## 三、LocateRuntime — 定位运行时支撑

**从已删除的 MinimapLocatorView.swift 析出的纯逻辑类型**（头注释实录：原文件里 LocateGate/LocateContext 与视图混在一起，删除旧视图时被一并带走导致编译失败，按职责单独留存）：

- **`LocateGate`**：定位互斥闸（NSLock 保护 busy 标志）——tryBegin/end/isBusy，保证同一时刻只有一路定位在跑（视觉/网络共用）
- **`LocateContext`（含类头说明注释）**：定位上下文——visualLocator/networkLocator 两路实例 + visualReady/networkReady 就绪标志 + activeMode（默认 "fallback"）

**ControlWiring/MapWiring/LocateRuntime 文档至此完整**。给别的 AI 的最关键提示：**限速优先级三档不可调换**（用户手动不限速 > 自动速度 > 手动路况），**刹车纯规则不走模型**，**speedLimit 直接进 vehicle_state[4] 参与推理**——这三个约束都是用户明确定义的安全边界。