# 代码-29 ControlWiring / MapWiring / LocateRuntime（控制台接线与地图数据层）

> 📌 **文件名失效提示（2026-09-29 复核追加）**：**本文文件名中的 `MinimapLocatorView` 已不存在**
> （UI 大改版删除，纯逻辑类型析出到 `LocateRuntime.swift`，UI 侧由 MissionConsole 的
> MiniMapCard / MiniMapCanvas 承载）。文件名保留不改是为了不破坏既有交叉引用，**内容已正确**。
>
> 覆盖源文件：`Sources/AuroraDrive/App/ControlWiring.swift`（**476 行**，2026-10-02 `wc -l` 实测；原文写 450 行）+ `MapWiring.swift`（**357 行**，2026-10-02 `wc -l` 实测）+ `LocateRuntime.swift`（**35 行**）。
> ⚠️ 2026-09-29 实测：`ControlWiring.swift` 现为 **475 行**（+25），正文行号可能有个位数偏移。
>
> **⚠️ 2026-09-25 重建说明**：本档原覆盖 `App/MinimapLocatorView.swift`（196 行）——该文件已在 UI 大改版中删除，纯逻辑类型（LocateGate/LocateContext）被析出到 `LocateRuntime.swift` 单独留存（源码头注释实录），UI 侧由 MissionConsole 的 MiniMapCard/MiniMapCanvas 承载。本档现按三个新文件的实际内容重写。

## 一、ControlWiring — 任务控制台功能接线层（450 行）

**文件头原则（1–16 行）**："界面（A-任务控制中心.html 的 SwiftUI 版）与真实引擎之间的**唯一通道**。界面上的每一个可点元素，背后都必须有一条真的执行路径。**没有执行路径的，宁可不画**。" 接线清单六项：① 路况自适应 4 态 ② 自动速度开关 ③ 四挡降级链 ④ 限速滑块 ⑤ 18 项技能 ⑥ 引擎 9 命令。

### ① 路况 → 限速映射（extension RoadCondition，24–57 行）

**6 档 autoSpeedLimit（用户 2026-09-22 定义）**：simple→**nil（≤10 框不限速）** / easy→150（21–30 框）/ medium→100（31–50）/ busy→60（51–70）/ extreme→**20（>70 框最保守）** / off→nil（**不干预**）。

**⚠️ .simple 与 .off 语义区分（49–53 行）**：两者 autoSpeedLimit 都是 nil 但完全不同——.simple = 自动速度**在工作**，结论就是不限速；.off = 自动速度**没在工作**。`meansUnlimited`（`self == .simple`）与 `drivesSpeed`（`autoSpeedLimit != nil`）承载该区分。

`color(forDetectionCount:)`：按框数取状态色（与判定阈值同源，UI 上色用）。

### ② SpeedLimitSource 与优先级（59–67 行 + autoSpeedTarget 纯函数）

`enum SpeedLimitSource { user / auto / none }`——**谁把车推到「不限速」的**。DriveState.unlimitedSource 记录归属。

**`autoSpeedTarget(for:currentLimit:unlimitedSource:enabled:) -> Double?`（179–190 行）——纯函数，生产路径与 --limit-selftest 共用同一份实现**（63 次自测全 PASS 的对象）。抽出原因（169–174 行注释）：优先级规则此前分散在 3 处（tick 门禁/applyRoadCondition/setAutoSpeed），任一处漏改就死锁。**优先级（用户明确定义，不可调换）：用户手动不限速 > 自动速度 > 手动路况**——① 用户手动不限速（`currentLimit >= 200 && source == .user`）→ 一切自动逻辑让路返回 nil；② 简单档结论就是不限速（返回 unlimitedThreshold）；③ 其余档位下发各自限速（.off 为 nil 不干预）。**若不区分来源会死锁**：自动设成不限速 → isUnlimited=true → 自动速度被自己的门禁挡住 → 框数涨回来也永远解不开（150–154 行注释）。

`unlimitedLockedByUser`：`isUnlimited && unlimitedSource == .user`——只有用户手动不限速才锁死自动速度。

### ③ DriveState 扩展接线（73–254 行）

- **`applyRoadCondition(_:)`**：落 roadCondition → 极复杂（needsTakeover）**自动置 forceRuleMode 并 pushConfig**（安全优先，不等降级链慢慢降；离开解除）→ 自动速度联动（autoSpeedTarget 判定后 setSpeedLimit）
- **`setAutoSpeed(_:)`**：开关自动速度，开启立刻按当前路况下发一次
- **`setSpeedLimit(_:reason:source:)`**：限速范围 `speedLimitRange = 20...200`，`unlimitedThreshold = 200`（"不限速"用 200 表示）；夹紧 + 变化才下发 + **记录 unlimitedSource 归属**（≥200 时记 source，否则清 .none）+ pushConfig
- **`selectGear(_:)`**（四挡降级链人工干预）：GEAR 1/2（模型侧）→ 解除 forceRuleMode（"人工只能表达我希望走模型，不能伪造 M9 活着"）；GEAR 3/4（规则侧）→ 置 forceRuleMode。界面高亮始终跟随引擎回报的 mode
- **`pushConfig(reason:)`**（config 下发唯一出口）：7 字段（sport/controlDisabled/forceRule/expert/glyph/degradeThreshold/speedLimit）→ `EngineClient.sendCommand("config")`——引擎端对应 EngineMain 的 `case "config"`；**speedLimit 直接进推理**（vehicle_state[4]），不同步=UI 显示 40 模型按 120 决策
- **`driveBars`**：四条控制量归一化快照（steer ±1 / throttle 0-1 / brake 0-1 / speed 相对限速）→ UI 底部四条进度条

### ④ SpeedLimitGuard — 限速闭环执行器（271–400 行，三级刹车）

**设计要点（261–269 行）**：触发源=速度模型真实读数（speedOCR/引擎回传），**纯规则覆盖、不走任何神经网络**（"刹车这件事不允许被模型置信度影响"，用户明确要求"千万不能用模型来实现"）；不限速（≥200）→ **整个闭环彻底停用**（短路，不是把阈值设大）。

**三级刹车（Stage enum，279–293 行）——解决"持续手刹=车辆失控"的根因（276–278 行注释：手刹锁死后轮，高速下后轮失去抓地 → 甩尾 → 车头打转）**：

| 级 | 阶段 | 时间窗 | 行为 |
|---|---|---|---|
| ① liftOnly | 松油门 | 超速 0–0.6s | 只松 W+Shift（风阻+发动机制动，多数情况够用） |
| ② pulse | 点刹 | 0.6–2.5s | **脉冲手刹**：pulseOn=0.18s 按下 / pulseOff=0.22s 松开交替（占空比 ~45%，轮胎周期性恢复抓地） |
| ③ firm | 持续刹 | >2.5s 仍超速 | 持续按空格（最后手段） |

- `update(speedKmh:speedValid:limitKmh:dt:) -> Bool`：四道前置闸——不限速→短路 / **speedValid=false 不动作（不能拿不可信读数踩刹车）** / 未超速（margin=1.0km/h 余量防抖动）→ 退出；超速累计 overspeedSeconds → 分级；返回 true 时调用方跳过 AI 决策键
- **峰值留档（371–379 行）**：reset() 清零前把本轮 lastBrakeSeconds/lastStage/lastOvershoot/lastPulseCount 留档——否则刹车结束后读到的永远是 0/待命，日志无法诊断"刹了多久、到没到持续刹"
- 诊断状态：stage / handbrakeDown（点刹真假交替）/ overspeedSeconds / overshoot / pulseCount

### ⑤ AutoRoadCondition — 路况自动判定（420–450 行）

**用 YOLO 实测检测框数量判定**（不用模型置信度——框数是直接观测可解释可验证，置信度是黑箱，"让模型既当运动员又当裁判"是用户明确禁止的）。阈值（423–427 行，集中一处、UI 说明文字同源）：**>70 极度复杂 / >50 繁忙 / >30 中等 / >20 轻松 / ≤10 简单（不限速）**；**11–20 为滞回带**（保持原状，防反复横跳）；`stabilityFrames = 15`（约 0.5 秒稳定门——同一判定需连续成立 15 帧才切换，防单帧抖动导致限速跳变触发刹车）。`legendText` 读常量生成阈值说明文字。

## 二、MapWiring — 小地图/大地图真实坐标映射（254 行）

**数据链（头注释）**：CoordinateCapture 抓包 → 世界坐标(UE5 厘米) → worldToMapPixel 校准变换 → 地图像素(13056×13056) → 视口归一化 → 渲染。**派生量一律现算不缓存**——定位一变地图立刻动；未锁定时 mapPixelX/Y 返回地图中心，由调用方按 locatorFound 决定显示。

- **worldToMapPixelX/Y（static，24–31 行）**：直接引用 **CoordinateCapture 的全局扩图版校准常量**（kCalibA/B/TX/TY——map-2026-08 13056 版；NetworkLocator 已于 2026-09-25 同步对齐同值，见代码-16 修复记录）；公式与 CoordinateCapture.worldToMapPixel 完全一致
- **mapPixelX/mapPixelY**：自车地图像素；**minimapSpanMeters = 160**（小地图固定展示自车周围 160 米真实地图——9-22 修复的"spanMeters 是 private let 常量、缩放从来没写过"的反面）
- **egoNormX/Y 恒 0.5**：自车恒在视口中心（地图跟着车走，高德/百度标准做法）
- **normMapX/normMapY**：任意世界坐标 → 小地图视口归一化（相对自车偏移换算，夹紧 0.06–0.94）
- **MapDatabase（81–141 行）**：离线地图数据库（models/FINAL_complete_map_database.json，5677 标记）——幂等加载（**projectRoot() 定位，双击 .app 时 cwd 是 "/"**）；数据库 x/y 是**归一化百分比（0~100）**，加载时换算成 13056 地图像素；找不到文件计数如实显示 0
- **markersInView（170–188 行）**：方形视野内标记查询，按距离由近及远排序取 limit 个（近处细节优先绘制）
- **regionName（208–229 行）**：实时坐标反查最近标记的区域——**格缓存（100px 一格）**：同格直接命中，跨格才遍历 5677 标记一次（9-24 优化改动 20：-99% 遍历）
- **PlacedMarker.stableID**：存储属性（init 算一次，"kind#name#x#y"）——ForEach 身份稳定（9-24 优化改动 16）
- **normMapXLarge/normMapYLarge**：大地图归一化（spanPx 参数化，夹紧 0.03–0.97）

## 三、LocateRuntime — 定位运行时支撑（35 行）

**从已删除的 MinimapLocatorView.swift 析出的纯逻辑类型**（头注释实录：原文件里 LocateGate/LocateContext 与视图混在一起，删除旧视图时被一并带走导致编译失败，按职责单独留存）：

- **`LocateGate`（12–26 行）**：定位互斥闸（NSLock 保护 busy 标志）——tryBegin/end/isBusy，保证同一时刻只有一路定位在跑（视觉/网络共用）
- **`LocateContext`（29–35 行）**：定位上下文——visualLocator/networkLocator 两路实例 + visualReady/networkReady 就绪标志 + activeMode（默认 "fallback"）

**ControlWiring/MapWiring/LocateRuntime 文档至此完整**。给别的 AI 的最关键提示：**限速优先级三档不可调换**（用户手动不限速 > 自动速度 > 手动路况），**刹车纯规则不走模型**，**speedLimit 直接进 vehicle_state[4] 参与推理**——这三个约束都是用户明确定义的安全边界。
