# 代码-34 DriveSegmentController 驾驶分段控制器

---

## ♻️ 行号已按 9097 行版重基准（2026-10-18，merge-map）

> 方法：逐条 `sed -n 'Np'` 看该行现在是什么 → 判断语义是否匹配 → 不匹配则 `grep -n '符号名'` 找真值。
> **未做统一平移**（同文件内偏移有 +1/+2/+3/+9 分段差异）。**只改文档，未动 Sources/**。

### 权威行号表（`AuroraDriveApp.swift` = **9097 行**，本轮实测）

| 引用项 | 上一版（9095 行） | **本轮实测（9097 行）** | 判定依据 |
|---|---|---|---|
| `tick()` | :6865 | **:6865** ✓ 不变 | `func tick() {` |
| `laneKeepTiers` 声明 | :5832 | **:5832** ✓ 不变 | `private static let laneKeepTiers: Set<DriveMode> =` |
| 档位门 `if Self.laneKeepTiers.contains` | :7641 | **:7642**（+1） | 该行即 `if Self.laneKeepTiers.contains(decided) {` |
| 分段块整体 | :7651-7670 | **:7653-7670** | :7653 `var segmentUsed = false` → :7670 闭合 |
| 实例声明 `let driveSegment` | :5733 | **:5733** ✓ 不变 | `let driveSegment = DriveSegmentController()` |
| `readPose` 定义 | :8031-8039 | **:8033-8041**（+2） | :8033 `private func readPose()` → :8041 `}` |
| `segmentDecisionForRule` 定义 | :8045-8057 | **:8047-8063**（+2） | :8047 声明 → :8063 `}` |
| `locatorScoreForTier` | :8022-8030 | **:8024-8031**（+2/+1） | :8024 声明 → :8031 `}` |
| `applyCommand` | :8074-8103 | **:8083-8112**（+9） | :8083 声明 → :8112 `}` |
| 压油门段（限速） | :7656-7660 | **:7660-7664**（+4） | :7660 `if let lim = segDecision.speedLimitKmh {` → :7664 `}` |

### 本轮修正明细（6 处数字 + 1 处语义错标）

| # | 位置 | 旧 | 新 | 说明 |
|---|---|---|---|---|
| C1 | §六 代码块 / 缺陷1 | :7641 档位门 | **:7642** | 逐行看：:7641 是注释「默认 `rule,yolo`…」，代码在 :7642 |
| C2 | §六 代码块 11 行 | :7652-7673 | **:7654-7675** | 整体 +2/+4 分段，逐行列出见 §六 |
| C3 | §六 / 缺陷1 | `readPose` :8031-8039 | **:8033-8041** | :8033 才是 `private func readPose` |
| C4 | §六 / 缺陷1 | `segmentDecisionForRule` :8045-8057 | **:8047-8063** | :8047 声明、:8063 闭合 |
| C5 | §六 | `locatorScoreForTier` :8022-8030 | **:8024-8031** | :8024 声明、:8031 闭合 |
| C6 | 缺陷1/七·五 | `applyCommand` :8074-8103 | **:8083-8112** | :8083 声明、:8112 闭合 |
| C7 | 缺陷3 grep 清单 | :7638/:7991/:8040/:8048 | **:7646/:8000/:8049** | 原文 4 个行号里有 3 个已不是 `DriveSegmentController` 引用；实测 grep 只命中 5733/7646/8000/8049 |
| C8 | §本文件行号表 | `:417 handoverOrigin 赋值` | **:417 是 `targetCorner = nil`** | :419 才是 `handoverOrigin = nil`；`:317` 是 `handoverOrigin = (wx, wy)`。原文把 417 标成 handoverOrigin 属语义错标 |
| C9 | 缺陷1 第 2 环 | `:194` 返回处 | **:194 算 lim / :197 才 return** | 语义精确化 |

### 未改动（逐条确认命中）

`DriveSegmentController.swift` 本体 **430 行未变**，27 处内部行号全部有效；`AuroraFlags.swift` **543 行未变**，
8 处引用（:280 / :292 / :294 / :296 / :298 / :300 / :302 / :461-466）全部有效（lead 只改了 :445 的
`AURORA_QUEST_OCR`，与本篇无关）。`RoadCornerGuide.swift` 3 处（:307 / :460-466 / :639-644）、
`RouteGraph.swift` 2 处（:404-540 / :543-553）、`MissionConsole.swift` 2 处（:4489-4542 / :1203-1224）全部命中。

---

## ✅ 2026-10-18 复核（上一轮 infer-reader，保留作历史）

> 复核人：infer-reader · 方法：逐条 `read` 源码核对语义（不只查行号存在）· **只改文档，未动 Sources/**

| # | 问题 | 修订内容 |
|---|---|---|
| R1 | **`road_corners_v2.json` 应为 v3b** | 文档 §七·五写「`models/road_corners_v3b.json` 打点集」。源码 `RoadCornerGuide.swift:307` 实际加载 **`road_corners_v3b.json`**（`locateResource()` 的 `name = "road_corners_v3b"`）。已改为 v3b 并补实测条数 |
| R2 | **打点集条数未记录，实测补上** | `models/road_corners_v3b.json` 实测（2026-10-18）：**3,135 条 = 1,924 弯道（bend）+ 1,211 路口（junction）**。已补入 §七·五 |
| R3 | **「路口暂不覆盖」的说法已过期** | 文档 §三/§二把 `.junction` 描述为「路口选路」但未说明其已投产。实际路口**已完整实现并被本文件调用**：`:161` `junctionAhead` + `:163` `chooseExit`（`stepFromVision` 内）、`:280-281` `junctionAhead` + `chooseExit`（`stepJunction` 内）、`:602` `steerForJunction`。已在 §二 补「已投产」标注 |
| R4 | **消费端行号全线漂移（App 9088 → 9095 行）** | `tick()` :6862→**:6865**；档位门 :7634→**:7641**；`laneKeepTiers` 声明 :5830→**:5832**；分段块 :7645-7666→**:7651-7670**；实例声明 :5731→**:5733**；`readPose` :8024-8032→**:8031-8039**；`segmentDecisionForRule` :8038-8054→**:8045-8057**。详见下表 |
| R5 | **`RoadCornerGuide.swift:639-644`（signedHeadingDiff）未核实** | 该引用属 `RoadCornerGuide` 而非本文件，本次已实测：`signedHeadingDiff` 定义在 **`:639-644`** ✅ 准确（`compassBearing` 在 `:460-466`，文档写 `:388-395` ❌ **已订正**） |

### 消费端行号漂移明细（⚠️ **以下为上一轮 9095 行版记录，已被顶部 ♻️ 9097 行版表取代；留作历史对照**）

| 引用项 | 文档旧值 | 上一版本（9095 行）实测 | **当前（9097 行）** |
|---|---|---|---|
| `tick()` | :6862 | :6865 | **:6865**（未再变） |
| `laneKeepTiers` 声明 | :5830-5831 | :5832 | **:5832**（未再变） |
| 档位门 `if Self.laneKeepTiers.contains` | :7634 | :7641 | **:7642** ⬅ 本轮 +1 |
| 分段块整体 | :7645-7666 | :7651-7670 | **:7653-7670** ⬅ 本轮 |
| 实例声明 `let driveSegment` | :5731 | :5733 | **:5733**（未再变） |
| `readPose` 定义 | :8024-8032 | :8031-8039 | **:8033-8041** ⬅ 本轮 +2 |
| `segmentDecisionForRule` 定义 | :8038-8054 | :8045-8057 | **:8047-8063** ⬅ 本轮 +2 |
| `locatorScoreForTier` | :8015-8022 | :8022-8030 | **:8024-8031** ⬅ 本轮 +2 |
| `applyCommand` | —（上一版未列） | :8074-8103 | **:8083-8112** ⬅ 本轮 +9 |

### 本文件行号（`DriveSegmentController.swift` **430 行**，未变）逐条实测

`:37` enum 声明 ✅ / `:53` struct 声明 ✅ / `:61` `overridesVision` ✅ / `:104-113` init ✅ / `:157` `cornerAhead` ✅ / `:161` `junctionAhead` ✅ / `:163` `chooseExit` ✅ / `:194` `stepFromVision` 算 lim（:197 才 return）✅ / `:237` `speedLimitForCorner(nil, …)` ✅ / `:303-329` `stepStraighten` ✅ / `:331` `stepHandover` ✅ / `:378-382` 12s 兜底 ✅ / `:383` 返回 `speedLimitKmh: 30.0` ✅ / `:406-411` `speedLimitForCorner` 函数 ✅ / `:414-423` `reset` ✅ / **`:417` 是 `targetCorner = nil`**（原文标注为「`handoverOrigin` 赋值」❌ 语义错标，已订正）/ `:419` `handoverOrigin = nil` ✅（原文写「:417 handoverOrigin 赋值」把 :419 的 nil 清空和 :317 的赋值混了）—— 除该 1 处标注外，**本文件行号全部准确**。

### 缺陷 1 因果链复核（仍未修，结论升级为「已确认」

逐环实测确认，且**新增一环证据**：

- `:61` `overridesVision { mapSteer != nil }` ✅ —— 只看 `mapSteer`，**与 `speedLimitKmh` 完全无关**
- `:194` 进地图段返回 `mapSteer: nil`（转向由 `stepMapTurn` `:230-235` 在后续帧给出）
- `:237` `speedLimitForCorner(nil, spd, radius: nil)` → `:406-411` `hit == nil` 恒返回 nil ✅
- `:383` `stepHandover` 返回 `mapSteer: nil, speedLimitKmh: 30.0` ✅
- **新证据（上一轮发现，本轮确认行号 +4）**：消费端 `AuroraDriveApp.swift:7660-7664` 那段压油门逻辑写在 `if segDecision.overridesVision, let ms = segDecision.mapSteer {`（**:7656**）**块内**：
  ```swift
  if let lim = segDecision.speedLimitKmh {          // :7660 ← 只有 overridesVision 为真才进来
      let cap = lim / 3.6                           // :7661
      currentCommand.throttle = max(0.0, min(currentCommand.throttle,   // :7662
                                             max(0.0, min(0.35, cap * 0.12))))  // :7663
  }                                                  // :7664
  ```
  ⟹ **即使 `speedLimitKmh` 有值，也因外层 `overridesVision == false` 而整段不执行**。文档原文只说到「`:7659` 静默丢弃」，未点出「压油门代码本身就在 overridesVision 块内」这一层——已补。
  > ♻️ 2026-10-18 行号重基准：本段 :7656-7660 → **:7656（if 行）/ :7660-7664（压油门块）**。
  > `else` 分支（`logSegmentIfNeeded(segDecision, before: nil)`）在 **:7668**。

**结论不变**：地图段限速**全线失效**，注释承诺的「路口一律限速 30」从未生效。

---

> 覆盖源文件：`Sources/AuroraDrive/Agent/DriveSegmentController.swift`（**430 行**，2026-10-17 `wc -l` 实测）。
> 本文件**未在 git 跟踪**（untracked），是 2026-09-30 新增的分段控制层。
> **✅ 2026-10-17 复核（T6）**：全文行号（本文件 + 消费端 `AuroraDriveApp.swift` + `AuroraFlags.swift`）已按当前源码 `grep -n` / `sed -n` 逐条实测——本文件 430 行未变，第一～五节行号核对无误；第六节消费端行号按 App **9095 行版**重测。旧版复核说明不再保留。
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

`enum DriveSegment: String`（`:37–50`，实测 :37 声明 / :50 闭合）：

| 分段 | 中文 | 职责 |
|---|---|---|
| `.vision` | 视觉 | 常态。视觉主导，本控制器不干预 |
| `.mapTurn` | 地图转向 | 用地图先验打方向过弯 |
| `.junction` | 路口选路 | 路口多支路选出口。✅ **2026-10-18 复核：已完整投产**（`stepFromVision` :161/:163 与 `stepJunction` :280-281 均调用 `junctionAhead`+`chooseExit`，转向由 :602 `steerForJunction` 给出）——早期文档「路口暂不覆盖」的说法已过期 |
| `.straighten` | **回正** | 把车头掰回出口航向 |
| `.handover` | 交接确认 | 四条件确认后才交还视觉 |

> **回正是用户的硬要求**：「需要有回正，肯定是需要有」（§6.40.0）。本文件 `stepStraighten` 真的输出转向（`:322–324`），不是空实现。

## 三、决策输出结构

`struct SegmentDecision`（`:53–63`，实测 :53 声明 / :63 闭合）：

```swift
var segment: DriveSegment
var mapSteer: Double?          // nil = 本段不打方向
var speedLimitKmh: Double?     // 限速建议
var overridesVision: Bool { mapSteer != nil }   // ★ 关键（见「已知缺陷」）
var reason: String
```

**安全边界（文件头注释）**：本机**不做最终限幅**，输出仍要经过 `applyLaneAdvice`；
转向是**开关量**（消费端 `±0.1` 死区），不是角度。

## 四、参数（全部走 `AURORA_SEG_*`；`init()` 在 `:104–113`，A17 迁移后统一从 `AuroraFlags` 读）

| 参数 | 默认（`Core/AuroraFlags.swift` 行号） | 含义 |
|---|---|---|
| `AURORA_SEG_STRAIGHTEN_DEG` | 15.0（AuroraFlags.swift:292） | 触发回正的航向偏差 |
| `AURORA_SEG_STRAIGHTEN_DONE_DEG` | 8.0（:294） | 判定回正完成的偏差 |
| `AURORA_SEG_HANDOVER_M` | 15.0（:296） | 交接所需最小行驶距离 |
| `AURORA_SEG_HANDOVER_FRAMES` | 10（:298） | 交接条件需连续满足帧数 |
| `AURORA_SEG_CORRIDOR_M` | 8.0（:300） | 走廊容差 |
| `AURORA_SEG_MAP_TIMEOUT_S` | 20.0（:302） | 单段超时 |

## 五、交接四条件（`stepHandover` `:331–384`）

全部满足才交还视觉：

1. **在路上** —— `onRoad` 为真；否则用距离近似 `d < corridorToleranceM + 25.0`
2. **已向前行驶一段距离** —— `travelled >= handoverMinDistanceM`（默认 15 m）
3. **视觉稳定** —— `visionStable`（`laneFallback.lastAdvice != nil`）
4. **视觉置信度够** —— `(visionConfidence ?? 0) > 0.25`

连续满足 `handoverMinFrames`（10 帧）→ `consume` + `reset(to: .vision)`（`:369–372`）。

**用户原话的成功判据**：「在那条道路里，而且已经向前行驶一段距离，而且都能拟合在道路里，并且模型已经能正常识别到车道线，才能算成功」——四条与代码一一对应 ✅

## 六、消费端接线（♻️ 2026-10-18 按当前 App **9097** 行版逐行重测）

调用链（`Sources/AuroraDrive/App/AuroraDriveApp.swift`，**9097 行**（2026-10-18 `wc -l` 实测）、`tick()` 在 **:6865**；以下每行都 `sed -n 'Np'` 看过语义，非统一平移）：

```
:5832      private static let laneKeepTiers: Set<DriveMode> =   （AuroraFlags.swift:280 定义 / :456 登记默认值 rule,yolo）
:7642      if Self.laneKeepTiers.contains(decided) {              ← 档位门：rule+yolo 档都跑（2026-10-02 放开）
:7653        var segmentUsed = false
:7654        if let pose = readPose(),                           ← 定位门：locatorScore>=0.4（readPose 定义 :8033-8041）
:7655           let segDecision = segmentDecisionForRule(pose: pose) {   （定义 :8047-8063）
:7656           if segDecision.overridesVision, let ms = segDecision.mapSteer {
:7659             currentCommand.steer = max(-1.0, min(1.0, ms))  ← 覆盖视觉转向（±1.0 限幅）
:7660             if let lim = segDecision.speedLimitKmh {          ⚠️ 见缺陷1：这段就在 overridesVision 块内
:7661-7663            // 压油门（限速生效时）
:7664             }
:7665             segmentUsed = true
:7666             logSegmentIfNeeded(segDecision, before: before)
                 } else {
:7668             logSegmentIfNeeded(segDecision, before: nil)    ← ★ 限速在此被静默丢弃
                 }
:7670        }                                                    ← 分段块闭合
:7671-7693   if !segmentUsed, let advice = laneFallback.evaluate(...) { ... }  ← 第三优先
```

> 上一版（9095 行）整块写的是 :7641/:7652-7673，本轮实测为 **:7642 / :7653-7670 / :7671-7693**。
> 注意 :7651-7652 现在是注释（`// 前方弯道点 ← RoadCornerGuide（road_corners_v3b.json…`），代码从 :7653 起。

**readPose 定位门（**:8033-8041**）**：`guard locatorFound`（:8034）、坐标非有限值（:8036）、**`guard locatorScore >= 0.4`**（:8037）三道，任一不过返回 nil → fail-open 回落视觉。新鲜度档位→分数映射 `locatorScoreForTier`（**:8024-8031**）：live≤18s→1.0（唯一过 0.4 门槛）、recent 18~40s→0.3、stale 40~90s→0.1、lost→0（比旧行为更保守：陈旧定位不再驱动驾驶）。

**优先级链**：地图（`overridesVision`）> 视觉（`laneFallback`）> 底层模型；
**避障仍可再覆盖地图**。

**航向符号链已核实正确**：`compassBearing`（`RoadCornerGuide.swift:460-466`）+ `signedHeadingDiff`
（`RoadCornerGuide.swift:639-644`），`diff > 0 → steerRight`。罗盘 0°=北、90°=东，
右转时航向角增大 ✓ 自洽。

---

## 七、⚠️ 已知缺陷（2026-10-02 复核，**未修**）

### 缺陷 1 · 地图段限速**全线失效**

**因果链**（每环都有行号，♻️ 2026-10-18 按 `DriveSegmentController.swift` 430 行版 + `AuroraDriveApp.swift` **9097** 行版复核）：

1. `:61` `var overridesVision: Bool { mapSteer != nil }`
   → **限速是否生效取决于 `mapSteer`，与 `speedLimitKmh` 无关**
2. `:194`（`stepFromVision` 算 lim）→ `:197` 才 `return SegmentDecision(..., mapSteer: nil, speedLimitKmh: lim, ...)`
   → 给了限速，但 `mapSteer` 是 nil ⇒ `overridesVision == false`
3. `:237` `let lim = speedLimitForCorner(nil, spd, radius: nil)`
   → `:406-411` 该函数 `hit == nil` 时返回 nil ⇒ **地图段稳态永远没有限速值**
4. `:383`（`stepHandover`）→ 返回 `mapSteer: nil, speedLimitKmh: 30.0` → **同样被丢**
5. 消费端 `AuroraDriveApp.swift:7656` 的 `if segDecision.overridesVision, let ms = ...` 进不来 → `:7668`（else 分支）静默丢弃

> ♻️ 行号重基准：第 5 环原写 `:7647` 的 if / `:7659` 静默丢弃，实测为 **:7656（if）/ :7668（else 丢弃）**。

**后果**：文件自己的注释写着「路口一律限速 30（保守），并压住油门」「交接未完成期间：保守（不加油、不给转向）」，
**实测「压住油门」从未生效过**。（`stepMapTurn` `:230–235` 的转向是有的，所以「一直没转向」不成立。）

### 缺陷 2 · `stepHandover` 12 秒兜底可能活锁

⚠️ **静态推演，未实测**

- `:378-382` 若交接超 `12.0 s` → `segment = .straighten`（**直接赋值**；12s 兜底在 `:378-382`）
- 但清 `handoverOrigin` 的只有 `reset()`（`:414-423`）
- `.straighten` 一旦达标（`:303-329`）立刻又回 `.handover`，`handoverOrigin` 被**重新赋值**（`:317`）
- ⟹ 存在 **straighten ↔ handover 反复横跳、永不收敛**的可能

### 缺陷 3 · **本文件零自检**

430 行、用户点名的能力，**一条断言都没有**。
全仓 `grep -rn DriveSegmentController Sources/`（♻️ 2026-10-18 实测）命中仅 4 处 App 引用 + 6 处 Flags 登记：
- `AuroraDriveApp.swift:5733`（实例声明 `let driveSegment = DriveSegmentController()`）
- `AuroraDriveApp.swift:7646`（注释「详见 DriveSegmentController」）
- `AuroraDriveApp.swift:8000`（注释「读取自车位姿（供 DriveSegmentController 用）」）
- `AuroraDriveApp.swift:8049`（注释「DriveSegmentController 会用距离近似兜底」）
- `Core/AuroraFlags.swift:461-466`（6 个 `AURORA_SEG_*` 的 `readBy` 登记）
- 本文件自身

> ♻️ 上一版写的是 `:7638`/`:7991`/`:8040`/`:8048` —— 实测这 4 个行号里 **3 个已不是
> `DriveSegmentController` 的字样**（:7638 是 `//`、:7991 是刹车边沿注释、:8040 是 `return (wx, wy, …)`、
> :8048 是 `segmentDecisionForRule` 参数续行）。**真实命中是 :5733 / :7646 / :8000 / :8049**。

**无任何自检文件引用它**。对比：`PerfSelfTest` 984 行、`RealShotSelfTest` 257 行、`RoadCornerGuide.selfTest`（`:738`）均有断言。

---

## 七·五、★ 与 RoutePlan 的关系（2026-10-07 核实，勿混淆）

**本控制器的弯道点来自 `RoadCornerGuide`（`models/road_corners_v3b.json` 打点集，2026-10-18 实测 **3,135 条 = 1,924 弯道 + 1,211 路口**；DriveSegmentController.swift:157/:161/:280），与 `RoutePlanner.route()` 的 A* `RoutePlan`（`App/RouteGraph.swift:404-540`，同文件第二个重载在 :543-553）是两条完全独立的数据链**：

| | RoadCornerGuide（本控制器用） | RoutePlan（A*） |
|---|---|---|
| 数据 | 离线弯道/路口打点库 | 路网图上两点间最短/少拐弯折线 |
| 触发 | 定位位姿（`readPose()`，locatorScore≥0.4） | 用户任务/小地图交互 |
| 消费 | **转向控制**（mapSteer 覆盖视觉） | 小地图画线（MissionConsole.swift:4489-4542）+ 弯道距离显示（:1203-1224） |
| 能否产生按键 | **能**（经 DriveSegmentController → applyCommand，AuroraDriveApp.swift:**:8083-8112**） | **不能**（未验证有到控制的任何接线） |

> ♻️ 2026-10-18：`applyCommand` 由 :8074-8103 改为 **:8083-8112**（+9）。
> `MissionConsole.swift` 两处经复测仍有效（:4489-4542 是路网路线绘制块；:1203-1224 是 QuestCard 距离口径注释与 `routeMeters` 字段）。

---

## 八、一句话总结

**接线是真的、回正是真的、四条件是真的、航向符号是对的**；
但**限速是假的**（`overridesVision` 只看 `mapSteer`），**且整条链没有任何自动化验证**。

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。2026-10-17 复核（T6）：全文行号按当前源码重测——本文件 430 行未变，第一～五节/七·五节锚点核对无误；第六节消费端行号按 `AuroraDriveApp.swift` **9095 行版**整体更新；`PerfSelfTest` 实测 984 行。缺陷 1/2 **仍在（未修、未实测）**。

**♻️ 2026-10-18 行号重基准（merge-map，源码冻结在 9097 行版）**：逐条 `sed -n 'Np'` 核对语义后再改，**未做统一平移**。
检查 **23 项**引用，修正 **9 项**，未决 **0 项**：
- 档位门 :7641→**:7642**；分段块 :7651-7670→**:7653-7670**；压油门段 :7656-7660→**:7660-7664**；
  `readPose` :8031-8039→**:8033-8041**；`segmentDecisionForRule` :8045-8057→**:8047-8063**；
  `locatorScoreForTier` :8022-8030→**:8024-8031**；`applyCommand` :8074-8103→**:8083-8112**；
  缺陷1 第5环 :7647/:7659→**:7656/:7668**；缺陷3 grep 清单 :7638/:7991/:8040/:8048→**:7646/:8000/:8049**。
- 另有 1 处**语义错标**订正：`:417` 是 `targetCorner = nil`（原文标「`handoverOrigin` 赋值」），
  `handoverOrigin = nil` 在 :419、赋值在 :317。
- **未变**：tick :6865、laneKeepTiers :5832、实例 :5733、AuroraFlags 全部 8 处、DriveSegmentController 内部 27 处、
  RoadCornerGuide 3 处、RouteGraph 2 处、MissionConsole 2 处。
- 缺陷 1/2/3 **维持原判（未修）**。
