# 代码-34 DriveSegmentController 驾驶分段控制器

---

## 🧭 定位方式（2026-11 规范化）

> **本文不记录任何行号。** 所有代码位置用源码中真实存在的**符号名**定位（类型 / 函数 / 属性 / 环境变量 / CLI 参数），
> 行号会随源码生长必然漂移；符号不会漂移，且每个符号都能在 `Sources/` 里 grep 到。
> 只改文档，未动 `Sources/`。

### 符号定位表

| 引用项 | 真实符号 |
|---|---|
| 驾驶主循环 | `DriveState.tick()` |
| 车道保持档位门 | `DriveState.tick()` 中的 `if laneAssistAllowed && Self.laneKeepTiers.contains(decided)` |
| 车道保持档位集合 | `DriveState.laneKeepTiers`（默认 `rule,yolo`，`AURORA_LANEKEEP_TIERS` 可覆盖） |
| 分段块 | `DriveState.tick()` 中的 `var segmentUsed = false` 起、到 `if !segmentUsed, let advice = laneFallback.evaluate(...)` 之前 |
| 分段控制器实例 | `DriveState.driveSegment = DriveSegmentController()` |
| 定位位姿 | `DriveState.readPose()` |
| 规则态分段决策 | `DriveState.segmentDecisionForRule(pose:)` |
| 新鲜度→分数映射 | `DriveState.locatorScoreForTier(_:)` |
| 分段日志 | `DriveState.logSegmentIfNeeded(_:before:)` |
| 按键注入 | `DriveState.applyCommand(_:)` |
| 限速执行 | `SpeedLimitGuard`（`DriveState.speedLimitGuard` 实例） |

### 语义勘误（原行号错标已按代码订正）

- 原标注「`handoverOrigin` 赋值」的位置实为 `stepHandover()` 中的 `targetCorner = nil`；
  `handoverOrigin = nil` 在 `reset(to:reason:)` 中，`handoverOrigin = (wx, wy)` 在 `stepStraighten()` 中。
- 原标注「`stepFromVision` 返回处」的位置实为 `stepFromVision()` 中计算 `lim = speedLimitForCorner(...)` 的地方，
  真正的 `return SegmentDecision(...)` 在其后。

---

> 覆盖源文件：`Sources/AuroraDrive/Agent/DriveSegmentController.swift`（按符号引用，不记行数）。
> 本文件**未在 git 跟踪**（untracked），是 2026-09-30 新增的分段控制层。
> 关联：[`代码-24-AuroraDriveApp入口与AppDelegate.md`](代码-24-AuroraDriveApp入口与AppDelegate.md)（消费端）、
> [`代码-35-RoadCornerGuide弯道先验.md`](代码-35-RoadCornerGuide弯道先验.md)（弯道数据源）、
> [`代码-36-RoadMapPrior路网先验.md`](代码-36-RoadMapPrior路网先验.md)（路网数据源）

---

## 一、它解决什么问题

用户 2026-09-30 原话（文件头注释记录）：

> 「正常的、非常微小的弯道……那个是给模型自己拟合，但是一旦出现真正需要路口有急弯的时候直接调地图」
> 「一旦车道线丢失，绝对不会硬开，而是通过可行驶区域加上地图来转弯，反正转向全都用地图，除非有车道线；如果没有车道线就直接用地图」

⟹ 本控制器是**「视觉 ↔ 地图」的交接状态机**：小弯交给视觉，真急弯/路口/车道线丢失时**接管转向**，
转弯完成后再**交还**视觉。

## 二、五个分段（状态机）

`enum DriveSegment: String`（`case vision / mapTurn / junction / straighten / handover`）：

| 分段 | 中文 | 职责 |
|---|---|---|
| `.vision` | 视觉 | 常态。视觉主导，本控制器不干预 |
| `.mapTurn` | 地图转向 | 用地图先验打方向过弯 |
| `.junction` | 路口选路 | 路口多支路选出口。✅ **2026-10-18 复核：已完整投产**——`stepFromVision()` 与 `stepJunction()` 均调用 `RoadCornerGuide.junctionAhead(worldX:worldY:headingDeg:)` + `chooseExit(junction:worldX:worldY:headingDeg:)`，转向由 `steerForJunction` 给出。早期文档「路口暂不覆盖」的说法已过期 |
| `.straighten` | **回正** | 把车头掰回出口航向 |
| `.handover` | 交接确认 | 四条件确认后才交还视觉 |

> **回正是用户的硬要求**：「需要有回正，肯定是需要有」（§6.40.0）。`stepStraighten()` 真的输出转向
> （按 `straightenTriggerDeg` / `straightenDoneDeg` 归一化，最低 `max(0.12, norm * 0.5)`），不是空实现。

## 三、决策输出结构

`struct SegmentDecision`：

```swift
var segment: DriveSegment
var mapSteer: Double?          // nil = 本段不打方向
var speedLimitKmh: Double?     // 限速建议
var overridesVision: Bool { mapSteer != nil }   // ★ 关键（见「已知缺陷」）
var reason: String
```

**安全边界（文件头注释）**：本机**不做最终限幅**，输出仍要经过 `applyLaneAdvice`；
转向是**开关量**（消费端 ±0.1 死区），不是角度。

## 四、参数（全部走 `AURORA_SEG_*`；`init()` 中统一从 `AuroraFlags` 读）

| 参数（AuroraFlags 属性） | 环境变量 | 默认 | 含义 |
|---|---|---|---|
| `AuroraFlags.segStraightenDeg` | `AURORA_SEG_STRAIGHTEN_DEG` | 15.0 | 触发回正的航向偏差 |
| `AuroraFlags.segStraightenDoneDeg` | `AURORA_SEG_STRAIGHTEN_DONE_DEG` | 8.0 | 判定回正完成的偏差 |
| `AuroraFlags.segHandoverM` | `AURORA_SEG_HANDOVER_M` | 15.0 | 交接所需最小行驶距离 |
| `AuroraFlags.segHandoverFrames` | `AURORA_SEG_HANDOVER_FRAMES` | 10 | 交接条件需连续满足帧数 |
| `AuroraFlags.segCorridorM` | `AURORA_SEG_CORRIDOR_M` | 8.0 | 走廊容差 |
| `AuroraFlags.segMapTimeoutS` | `AURORA_SEG_MAP_TIMEOUT_S` | 20.0 | 单段超时 |

> A17 迁移：6 处原读环境变量改为统一走 `AuroraFlags`（原来每次现读，17–32 µs/次），默认值逐字不变。

## 五、交接四条件（`stepHandover(_:_:_:visionConfidence:visionStable:onRoad:)`）

全部满足才交还视觉：

1. **在路上** —— `onRoad` 为真；否则用距离近似 `d < corridorToleranceM + 25.0`
2. **已向前行驶一段距离** —— `travelled >= handoverMinDistanceM`（默认 15 m）
3. **视觉稳定** —— `visionStable`（消费端传 `laneFallback.lastAdvice != nil`）
4. **视觉置信度够** —— `(visionConfidence ?? 0) > 0.25`

连续满足 `handoverMinFrames`（10 帧）→ `consume(t.x, t.y)` + `reset(to: .vision, reason: "交接成功（四条件齐备）→ 视觉段接管")`。

**用户原话的成功判据**：「在那条道路里，而且已经向前行驶一段距离，而且都能拟合在道路里，并且模型已经能正常识别到车道线，才能算成功」——四条与代码一一对应 ✅

## 六、消费端接线（`Sources/AuroraDrive/App/AuroraDriveApp.swift`）

```swift
if laneAssistAllowed && Self.laneKeepTiers.contains(decided) {
    var segmentUsed = false
    if let pose = readPose(),
       let segDecision = segmentDecisionForRule(pose: pose) {
        if segDecision.speedLimitKmh != nil {
            // 分段建议只保留既有油门上限，不因 OCR 丢读额外清零
            currentCommand.throttle = min(currentCommand.throttle, 0.35)
        }
        if segDecision.overridesVision, let ms = segDecision.mapSteer {
            let before = currentCommand
            currentCommand.steer = max(-1.0, min(1.0, ms))   // 地图段/回正段覆盖视觉转向（±1.0 限幅）
            segmentUsed = true
            logSegmentIfNeeded(segDecision, before: before)
        } else {
            logSegmentIfNeeded(segDecision, before: nil)
        }
    }
    if !segmentUsed,
       let advice = laneFallback.evaluate(laneMask: extrapolatedLaneMask, ...) { ... }   // 第三优先
}
```

**readPose 定位门（`readPose()`）**：三道守卫——`guard locatorFound`、`guard wx.isFinite, wy.isFinite, locatorHeading.isFinite`、
**`guard locatorScore >= 0.4`**，任一不过返回 nil → fail-open 回落视觉。速度只在 `speedValid` 为真时传
`trustedSpeedKmh`，否则传 nil（不拿估计值参与控制）。

新鲜度档位→分数映射 `locatorScoreForTier(_:)`：`live`→1.0（唯一过 0.4 门槛）、`recent`→0.3、
`stale`→0.1、`lost`→0（比旧行为更保守：陈旧定位不再驱动驾驶）。

**优先级链**：地图（`overridesVision`）> 视觉（`laneFallback`）> 底层模型；
**避障仍可再覆盖地图**。

**航向符号链已核实正确**：`RoadCornerGuide.compassBearing(fromX:fromY:toX:toY:)` + `signedHeadingDiff`
（`RoadCornerGuide.swift`），`diff > 0 → steerRight`。罗盘 0°=北、90°=东，右转时航向角增大 ✓ 自洽。

---

## 七、⚠️ 已知缺陷（2026-11 按当前代码复核）

### 缺陷 1 · 地图段限速曾经**全线失效**（消费端已改，现为部分生效）

**历史因果链**（每环都以符号标注）：

1. `SegmentDecision.overridesVision` 只看 `mapSteer != nil` → **限速是否生效与 `speedLimitKmh` 无关**
2. `stepFromVision()` 进地图段时 `return SegmentDecision(segment: .mapTurn, mapSteer: nil, speedLimitKmh: lim, ...)`
   → 给了限速，但 `mapSteer` 是 nil ⇒ `overridesVision == false`
3. `stepMapTurn()` 稳态时 `lim = speedLimitForCorner(targetCornerHit, spd)`，而 `speedLimitForCorner` 在
   `hit == nil` 时返回 nil ⇒ **地图段稳态经常没有限速值**
4. `stepHandover()` 也返回 `speedLimitKmh: 30.0` 配 `mapSteer: nil`

**当前代码状态（2026-11 实测）**：消费端已把限速处理**移出** `overridesVision` 块——

```swift
if segDecision.speedLimitKmh != nil {
    currentCommand.throttle = min(currentCommand.throttle, 0.35)
}
if segDecision.overridesVision, let ms = segDecision.mapSteer { ... }
```

⟹ 只要 `speedLimitKmh` 非 nil，油门就被压到 ≤0.35，**不再依赖 `overridesVision`**。
注释亦已同步：「实际设定限速仍由 `SpeedLimitGuard` 执行；这里不新增刹车或给油。」
残余风险转移到第 3 环：`stepMapTurn()` 稳态 `hit == nil` 时仍无限速值 → 该帧不压油门。

> 结论更新：**「限速从未生效」的旧结论已过期**；现状态是「地图段只有在 `speedLimitForCorner` 返回非 nil 时才压油门」。

### 缺陷 2 · `stepHandover` 12 秒兜底可能活锁

⚠️ **静态推演，未实测**

- `stepHandover()` 中若 `Date().timeIntervalSince(segmentSince) > 12.0` → `segment = .straighten`（直接赋值）
- 但清 `handoverOrigin` 的只有 `reset(to:reason:)`
- `.straighten` 一旦达标立刻又回 `.handover`，`handoverOrigin` 被**重新赋值**（`stepStraighten()` 内）
- ⟹ 存在 **straighten ↔ handover 反复横跳、永不收敛**的可能

### 缺陷 3 · **本文件零自检**

本控制器全文件、用户点名的能力，**一条断言都没有**（`grep -rn DriveSegmentController Sources/` 命中仅：
`AuroraFlags.swift` 的 6 个 `AURORA_SEG_*` 的 `readBy` 登记、`AuroraDriveApp.swift` 的实例声明与三处注释、
本文件自身）。**没有任何自检文件引用它**。对比：`PerfSelfTest`、`RealShotSelfTest`、`RoadCornerGuide.selfTest` 均有断言。

---

## 七·五、★ 与 RoutePlan 的关系（2026-10-07 核实，勿混淆）

**本控制器的弯道点来自 `RoadCornerGuide`（`models/road_corners_v3b.json` 打点集，2026-10-18 实测
3,135 条 = 1,924 弯道 + 1,211 路口；入口 `cornerAhead` / `junctionAhead` / `chooseExit`），
与 `RoutePlanner.route()` 的 A* `RoutePlan`（`App/RouteGraph.swift`，含同文件第二个重载）
是两条完全独立的数据链**：

| | RoadCornerGuide（本控制器用） | RoutePlan（A*） |
|---|---|---|
| 数据 | 离线弯道/路口打点库 | 路网图上两点间最短/少拐弯折线 |
| 触发 | 定位位姿（`readPose()`，locatorScore≥0.4） | 用户任务/小地图交互 |
| 消费 | **转向控制**（mapSteer 覆盖视觉） | 小地图画线（`MissionConsole.swift` 路线绘制）+ 弯道距离显示（`routeMeters`） |
| 能否产生按键 | **能**（经 DriveSegmentController → `applyCommand(_:)`） | **不能**（未验证有到控制的任何接线） |

---

## 八、一句话总结

**接线是真的、回正是真的、四条件是真的、航向符号是对的**；
限速链路已在消费端改造（限速不再依赖 `overridesVision`），但地图段稳态缺限速值的残余问题仍在；
**且整条链没有任何自动化验证**。

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。
**2026-11 规范化**：全篇行号引用改为符号引用（`DriveSegment` / `SegmentDecision` / `stepFromVision` /
`stepMapTurn` / `stepJunction` / `stepStraighten` / `stepHandover` / `speedLimitForCorner` /
`locatorScoreForTier` / `segmentDecisionForRule` / `logSegmentIfNeeded` / `SpeedLimitGuard` 等），
缺陷 1 的结论按当前消费端代码改写，缺陷 2/3 维持原判（未修、未实测）。
