# 代码-34 DriveSegmentController 驾驶分段控制器

> 覆盖源文件：`Sources/AuroraDrive/Agent/DriveSegmentController.swift`（**430 行，2026-10-06 `wc -l` 复测**；2026-10-02 版为 429 行，行号以 430 行版为准，关键行号已逐条回读核实）
> ⚠️ 本文件**未在 git 跟踪**（untracked），是 2026-09-30 新增的分段控制层。
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

`enum DriveSegment: String`（`:37–50`）：

| 分段 | 中文 | 职责 |
|---|---|---|
| `.vision` | 视觉 | 常态。视觉主导，本控制器不干预 |
| `.mapTurn` | 地图转向 | 用地图先验打方向过弯 |
| `.junction` | 路口选路 | 路口多支路选出口 |
| `.straighten` | **回正** | 把车头掰回出口航向 |
| `.handover` | 交接确认 | 四条件确认后才交还视觉 |

> **回正是用户的硬要求**：「需要有回正，肯定是需要有」（§6.40.0）。本文件 `stepStraighten` 真的输出转向（`:322–324`），不是空实现。

## 三、决策输出结构

`struct SegmentDecision`（`:53–63`）：

```swift
var segment: DriveSegment
var mapSteer: Double?          // nil = 本段不打方向
var speedLimitKmh: Double?     // 限速建议
var overridesVision: Bool { mapSteer != nil }   // ★ 关键（见「已知缺陷」）
var reason: String
```

**安全边界（文件头注释）**：本机**不做最终限幅**，输出仍要经过 `applyLaneAdvice`；
转向是**开关量**（消费端 `±0.1` 死区），不是角度。

## 四、参数（全部走 `AURORA_SEG_*`；init at `:104-114`，A17 迁移后统一从 `AuroraFlags` 读）

| 参数 | 默认（`Core/AuroraFlags.swift` 行号） | 含义 |
|---|---|---|
| `AURORA_SEG_STRAIGHTEN_DEG` | 15.0（AuroraFlags.swift:292） | 触发回正的航向偏差 |
| `AURORA_SEG_STRAIGHTEN_DONE_DEG` | 8.0（:294） | 判定回正完成的偏差 |
| `AURORA_SEG_HANDOVER_M` | 15.0（:296） | 交接所需最小行驶距离 |
| `AURORA_SEG_HANDOVER_FRAMES` | 10（:298） | 交接条件需连续满足帧数 |
| `AURORA_SEG_CORRIDOR_M` | 8.0（:300） | 走廊容差 |
| `AURORA_SEG_MAP_TIMEOUT_S` | 20.0（:302） | 单段超时 |

## 五、交接四条件（`stepHandover` `:330–383`）

全部满足才交还视觉：

1. **在路上** —— `onRoad` 为真；否则用距离近似 `d < corridorToleranceM + 25.0`
2. **已向前行驶一段距离** —— `travelled >= handoverMinDistanceM`（默认 15 m）
3. **视觉稳定** —— `visionStable`（`laneFallback.lastAdvice != nil`）
4. **视觉置信度够** —— `(visionConfidence ?? 0) > 0.25`

连续满足 `handoverMinFrames`（10 帧）→ `consume` + `reset(to: .vision)`（`:368–372`）。

**用户原话的成功判据**：「在那条道路里，而且已经向前行驶一段距离，而且都能拟合在道路里，并且模型已经能正常识别到车道线，才能算成功」——四条与代码一一对应 ✅

## 六、消费端接线（2026-10-06 复核，行号已更新）

调用链（`Sources/AuroraDrive/App/AuroraDriveApp.swift`，⚠️ 源文件已增至 8335 行，以下行号 2026-10-06 回读核实）：

```
:5426-5428  laneKeepTiers 声明（AURORA_LANEKEEP_TIERS，默认 rule,yolo）
:6917     if Self.laneKeepTiers.contains(decided) {       ← 档位门：rule+yolo 档都跑（2026-10-02 放开）
:6928       if let pose = readPose(),                     ← 定位门：locatorScore>=0.4（readPose :7271-7279）
:6929          let segDecision = segmentDecisionForRule(pose: pose) {   （:7285-7301）
:6930        if segDecision.overridesVision, let ms = segDecision.mapSteer {
:6933        currentCommand.steer = max(-1.0, min(1.0, ms))    ← 覆盖视觉转向（±1.0 限幅）
:6934-6938   // 压油门（限速生效时）
:6939        segmentUsed = true
:6940        logSegmentIfNeeded(segDecision, before: before)
            } else {
:6942        logSegmentIfNeeded(segDecision, before: nil)   ← ★ 限速在此被静默丢弃
            }
:6945-6949  if !segmentUsed, let advice = laneFallback.evaluate(...)  ← 第三优先
```

**readPose 定位门（:7271-7279）**：`guard locatorFound`、坐标非有限值、**`guard locatorScore >= 0.4`** 三道，任一不过返回 nil → fail-open 回落视觉。新鲜度档位→分数映射 `locatorScoreForTier`（:7262-7269）：live≤18s→1.0（唯一过 0.4 门槛）、recent 18~40s→0.3、stale 40~90s→0.1、lost→0（比旧行为更保守：陈旧定位不再驱动驾驶）。

**优先级链**：地图（`overridesVision`）> 视觉（`laneFallback`）> 底层模型；
**避障仍可再覆盖地图**。

**航向符号链已核实正确**：`compassBearing`（`:388-394`）+ `signedHeadingDiff`
（`RoadCornerGuide.swift:639-644`），`diff > 0 → steerRight`。罗盘 0°=北、90°=东，
右转时航向角增大 ✓ 自洽。

---

## 七、⚠️ 已知缺陷（2026-10-02 复核，**未修**）

### 缺陷 1 · 地图段限速**全线失效**

**因果链**（每环都有行号，2026-10-06 按 430 行版核实）：

1. `:61` `var overridesVision: Bool { mapSteer != nil }`
   → **限速是否生效取决于 `mapSteer`，与 `speedLimitKmh` 无关**
2. `:194`（`stepFromVision` 进地图段）→ 返回 `mapSteer: nil, speedLimitKmh: lim`
   → 给了限速，但 `mapSteer` 是 nil ⇒ `overridesVision == false`
3. `:237` `let lim = speedLimitForCorner(nil, spd, radius: nil)`
   → `:406-411` 该函数 `hit == nil` 时返回 nil ⇒ **地图段稳态永远没有限速值**
4. `:383`（`stepHandover`）→ 返回 `mapSteer: nil, speedLimitKmh: 30.0` → **同样被丢**
5. 消费端 `AuroraDriveApp.swift:6930` 的 `if` 进不来 → `:6942` 静默丢弃

**后果**：文件自己的注释写着「路口一律限速 30（保守），并压住油门」「交接未完成期间：保守（不加油、不给转向）」，
**实测「压住油门」从未生效过**。（`stepMapTurn` `:230–235` 的转向是有的，所以「一直没转向」不成立。）

### 缺陷 2 · `stepHandover` 12 秒兜底可能活锁

⚠️ **静态推演，未实测**

- `:377-381` 若交接超 `12.0 s` → `segment = .straighten`（**直接赋值**；12s 兜底在 `:378-381`）
- 但清 `handoverOrigin` 的只有 `reset()`（`:414-423`）
- `.straighten` 一旦达标（`:303-329`）立刻又回 `.handover`，`handoverOrigin` 被**重新赋值**（`:317`）
- ⟹ 存在 **straighten ↔ handover 反复横跳、永不收敛**的可能

### 缺陷 3 · **本文件零自检**

430 行、用户点名的能力，**一条断言都没有**。
全仓 `grep DriveSegmentController` 命中仅：`AuroraDriveApp.swift:4061` 附近（初始化）、
本文件自身（2026-10-06 复核；tick 内消费点见第六节行号）。

对比：`PerfSelfTest` 753 行、`RealShotSelfTest` 257 行、`RoadCornerGuide.selfTest` 均有断言。

---

## 七·五、★ 与 RoutePlan 的关系（2026-10-06 核实，勿混淆）

**本控制器的弯道点来自 `RoadCornerGuide`（`models/road_corners_v3b.json` 打点集，:157/:161/:280），与 `RoutePlanner.route()` 的 A* `RoutePlan`（`App/RouteGraph.swift:404-540`）是两条完全独立的数据链**：

| | RoadCornerGuide（本控制器用） | RoutePlan（A*） |
|---|---|---|
| 数据 | 离线弯道/路口打点库 | 路网图上两点间最短/少拐弯折线 |
| 触发 | 定位位姿（`readPose()`，locatorScore≥0.4） | 用户任务/小地图交互 |
| 消费 | **转向控制**（mapSteer 覆盖视觉） | 小地图画线（MissionConsole.swift:3912-3942）+ 弯道距离显示（:627-635） |
| 能否产生按键 | **能**（经 DriveSegmentController → applyCommand） | **不能**（未验证有到控制的任何接线） |

---

## 八、一句话总结

**接线是真的、回正是真的、四条件是真的、航向符号是对的**；
但**限速是假的**（`overridesVision` 只看 `mapSteer`），**且整条链没有任何自动化验证**。

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。2026-10-06 由文档更新代理 A8 复核：全文行号按 430 行版回读更新、消费端行号按 AuroraDriveApp.swift 8335 行版更新、补「与 RoutePlan 的关系」一节；缺陷 1/2 仍在（未修，未实测）。
