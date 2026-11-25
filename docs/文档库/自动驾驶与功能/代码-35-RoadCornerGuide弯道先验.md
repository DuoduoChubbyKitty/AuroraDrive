# 代码-35 RoadCornerGuide 弯道/路口先验
> ♻️ **引用已符号化（2026-10-18，merge-map）**：`AuroraDriveApp.swift` 的 tick 链全部改为符号定位（`DriveState.tick` / `readPose` / `segmentDecisionForRule` / `mapSteer` / `applyCommand`）。
> 逐条 `sed -n 'Np'` 核对语义（未统一平移）：检查 **13 项**跨文件引用，修正 **4 项**，未决 **0 项**。
> 修正：`readPose`、`segmentDecisionForRule` 等 tick 链节点已全部改为符号定位；
> `mapSteer` 覆盖块与 `applyCommand` 注入点同样按符号定位。
> 另：`AuroraDriveApp.swift` 的 v2/v3b 注释错误**已由 lead 修正**（现在写的就是 v3b），
> 本文早前登记的该问题已结案。始终有效：`DriveState.tick()`、`Self.laneKeepTiers` 门、`AuroraFlags` 的 `AURORA_CORNER_*` 系列、
> `RoadCornerGuide` 本体的 `RoadBranch` / `RoadCorner` / `CornerHit` / `GridKey` / `indexCellMeters` / `ensureLoaded()` / 参数 init / `cornerAhead` / `steerForCorner` / `compassBearing` / `speedAdviceForCorner` /
> `junctionAhead` / `chooseExit` / Y 形主路判据 / `effReach` / `steerForJunction` / `headingDiff` / `signedHeadingDiff` / 数据区 / `debugCornerAt` / `cornerAheadLinearReference` / `junctionProbeFromOwnData` / `probeFromOwnData` / `selfTest`，`DriveSegmentController` 的 `stepFromVision` / `stepJunction` 等调用点、
> `RouteGraph` 的 `RoutePlan` 与 `MissionConsole` 的任务卡弯道距离显示。
>
> ✅ **2026-10-18 复核（merge-map）**：修正 2 处**内容性过期**（不只是行号）：
> ① 第一节补「路口已完整实现并被真实调用」——旧版隐含「路口暂不覆盖」，实际 `junctionAhead`/`chooseExit`/
> `steerForJunction` 自 2026-09-30 起就已接线（`DriveSegmentController.stepJunction` 调用）；
> ② 数据源统一为 **`road_corners_v3b.json`**（3135 点 / 1924 弯 / 1211 路口），并新增与 v2 的差异对照表。
> 另：第五·五节 AuroraDriveApp 行号按 **9094** 行版重测（原 9088 版行号全部 +3~+8 漂移）；
> 登记源码注释 1 处错误（`AuroraDriveApp.swift` 写 v2、实际读 v3b）。`RoadCornerGuide.swift` 未变。
>
> ✅ 2026-10-17 复核（T7）：第五·五节「生效路径」的行号曾按旧版 App 修正（tick / laneKeepTiers 门 /
> readPose=8024-8032 / segmentDecisionForRule=8038-8054 / mapSteer 覆盖块=7647-7661 / applyCommand=8074-8103）
> —— **该组引用已于 2026-10-18 全面符号化，以本文 §5.5 为准**。

> 覆盖源文件：`Sources/AuroraDrive/Inference/RoadCornerGuide.swift`（2026-10-07 `wc -l` 复测，与旧记一致）
> 数据源：`models/road_corners_v3b.json`（**1622667 B**，2026-10-07 `ls -l` 复测，与旧记一致）
> 🔁 **2026-10-07 由文档核对代理 E4 复核**：第二节类型/API 表与第四节参数、第五节航向符号链**逐条核对无误**；**仅第五·五节「在驾驶全链路中的位置」的 AuroraDriveApp.swift 行号失效**（已改为符号定位）。数据统计（3135 点/1924 bend/1211 junction）**本次未重测**，沿用 2026-10-02 实测值。
> 关联：[`代码-34-DriveSegmentController驾驶分段控制器.md`](代码-34-DriveSegmentController驾驶分段控制器.md)（消费方）、
> [`代码-36-RoadMapPrior路网先验.md`](代码-36-RoadMapPrior路网先验.md)（姊妹先验）

---

## 一、用途

从离线生成的**弯道/路口打点库**中，按自车位置 + 朝向查出「前方有没有弯、往哪拐、该多快」。
这是**纯视觉做不到的部分**（车道线丢失时仍知道路往哪走）。

**覆盖范围（2026-10-18 复核更正）**：弯道（`bend`）与路口（`junction`）**两者都已实现并被真实调用**。

- 弯道：`cornerAhead` → `steerForCorner`（两阶段：进弯前朝点对准 / 接近后转出弯方向）
- 路口：`junctionAhead` → `chooseExit`（排除来路 + Y 形岔路主路判据）→ `steerForJunction`
- 二者由 `DriveSegmentController` 串成「视觉段 → 地图段/路口段 → 回正段 → 交接确认」状态机，
  **弯道优先于路口**（弯道打点密集 + 双向，实测与路口 0 重叠，`DriveSegmentController.swift` 注释）

> ⚠️ **旧文档说「路口暂不覆盖」已过期**：本文 2026-10-02 版写「路口也留了数据但转向决策暂不覆盖」，
> 那对应的是 RoadCornerGuide.swift **v2 时代**的状态。2026-09-30 起路口选路已完整实现
> （`RoadCornerGuide.junctionAhead(worldX:worldY:headingDeg:)` / `chooseExit(junction:worldX:worldY:...)` / `steerForJunction(_:exit:...)` / Y 形主路判据），
> 并被 `DriveSegmentController.stepFromVision` 与 `stepJunction` **真实调用**。
> `--corner-selftest` 也有专门的路口闭环断言（见第九节）。

## 二、数据结构

| 类型 | 行号 | 说明 |
|---|---|---|
| `struct RoadBranch` | 类型定义 | 支路：`deg`（出口角度）/ `reachM` / `widthCells` / `reachSaturated` / `widthValid` |
| `struct RoadCorner` | 类型定义 | 单个打点：`type`(`bend`/`junction`)、`worldX/Y`、`headingIn/Out`、`radiusM`、`turnDeg`、`turnSign`、`grade`、`branches` |
| `struct CornerHit` | 类型定义 | 命中结果（含距离 `distanceM`、方向夹角 `headingDiffDeg`） |
| `final class RoadCornerGuide` | 类型定义 | 单例门面 |

## 三、公开 API

| 方法 | 行号 | 用途 |
|---|---|---|
| `ensureLoaded()` | 方法 | 懒加载 `road_corners_v3b.json` |
| `cornerAhead(worldX:worldY:headingDeg:)` | 方法 | 查前方弯道 |
| `steerForCorner(_:headingDeg:...)` | 方法 | 弯道转向量 |
| `speedAdviceForCorner(_:speedKmh:)` | 方法 | 弯道限速建议 |
| `junctionAhead(worldX:worldY:headingDeg:)` | 方法 | 查前方路口 |
| `chooseExit(junction:worldX:worldY:...)` | 方法 | 路口选出口（含 `effReach` 启发） |
| `steerForJunction(_:exit:...)` | 方法 | 路口转向量 |
| `headingDiff(_:_:)` / `signedHeadingDiff(from:to:)` | 静态函数 | 航向差（后者带符号，★ 关键） |
| `debugCornerAt(_:)` | 方法 | 调试取点 |
| `cornerAheadLinearReference(...)` | 方法 | **线性实现，供空间索引对拍**（等价性验证用） |
| `junctionProbeFromOwnData()` / `probeFromOwnData()` | 方法 | 从自身数据造闭环探针 |
| `selfTest(probes:)` | 方法（`--corner-selftest`） | 自检（`--corner-selftest`） |

## 四、参数（`AURORA_CORNER_*`；A17 迁移后经 `AuroraFlags` 读取）

| 参数 | 默认（`Core/AuroraFlags.swift` 行号） |
|---|---|
| `AURORA_CORNER_LOOKAHEAD_M` | **40.0** |
| 方向容差 `AURORA_CORNER_HEADING_TOL_DEG` | 60° |
| 转向死区 `AURORA_CORNER_DEADBAND_DEG` | 8° |
| 转向饱和 `AURORA_CORNER_SAT_DEG` | 35° |
| `RoadCornerGuide.indexCellMeters`（空间索引格） | **128.0 m** |

> 索引格 128 m **远大于**提前量 40 m，故 `3×3` 格必然包含全部候选（`cornerAhead` 注释处）。

## 五、★ 航向符号链（**已核实正确**）

```
compassBearing(fromX:fromY:toX:toY:)
    compass = atan2(dx, -dy)
    图像 +X = 东、图像 -Y = 北；世界 +Y = 南
    ⟹ 罗盘 0° = 北、90° = 东

signedHeadingDiff(from:to:)
    返回规范化 (to − from) 到 (−180, 180]

消费端：diff > 0 → steerRight            ✓ 正确
```

**方向核验**：罗盘角 0°=北 → 90°=东，**右转时航向角增大** ⟹ `diff > 0` 对应右转 ✓ 链路自洽。

## 五·五、★ 在驾驶全链路中的位置（♻️ 行号 2026-10-18 按 AuroraDriveApp.swift **9097** 行版逐条重测）

本文件是**真实操控链的弯道/路口数据源**——不是 RoutePlan（A*）：

- 消费入口：`DriveSegmentController.stepFromVision` → `RoadCornerGuide.shared.cornerAhead`；路口走 `junctionAhead`/`chooseExit`/`steerForJunction`（`stepJunction`）；回正/过弯用 `signedHeadingDiff`。
- 生效路径（全部按符号定位；`AuroraDriveApp.swift` 持续膨胀，行号引用已废弃）：
  `DriveState.tick()` → `Self.laneKeepTiers` 门 →
  `readPose()`（locatorScore≥0.4）→
  `segmentDecisionForRule` →
  `mapSteer` 覆盖视觉转向 →
  `applyCommand` 注入按键。
- 对照：`RoutePlan`（A*，位于 `App/RouteGraph.swift`）的 `points` 只供小地图画折线（`App/MissionConsole.swift`）与任务卡弯道距离显示，**不产生按键**（未验证有其它接线）。

> ✅ **源码注释的 v2/v3b 错误已被 lead 修正**：`AuroraDriveApp.swift` 现写作
> 「前方弯道点 ← RoadCornerGuide（**road_corners_v3b.json** 打点集；原写 v2 已过期 —— 源码
> RoadCornerGuide.swift 实际加载 v3b）」。本文 2026-10-18 早前登记的「注释写 v2」已不再是问题。
> v2 与 v3b 的差异见第七节对照表（核心：v2 的 branches 是纯角度数组，v3b 是带 reachM/widthCells 的对象数组）。

## 六、空间索引与其等价性证明

- `GridKey{gx, gy}`，格边 128 m（`indexCellMeters`），分桶建索引（`bendIndex` / `junctionIndex`）
- **对拍**：`cornerAheadLinearReference` 是未优化的线性实现
- **实测等价性**：`索引对拍: 探针命中 91 次，不一致 0 次 ✓`（`--perf-selftest` 输出）
- **性能**：预热后 `cornerAhead` p50 **0.000–0.003 ms**；一帧地图查询合计 p50 **0.004 ms**

> ⚠️ **测量陷阱（已踩过）**：首次测量得 `cornerAhead` **31.4 ms** —— 这是 **`n=1` 撞上懒加载**的假象。
> 预热后真值为 0.000–0.003 ms，**差 10000 倍**。

## 七、数据文件实测（`models/road_corners_v3b.json`，2026-10-18 重测）

- **顶层是 JSON 数组**（不是对象），共 **3135 个点**（2026-10-18 Python 重测，与旧记一致）
- 类型分布：`bend` **1924** / `junction` **1211**（全部 1211 条路口**含 branches 对象数组**）
- 弯道唯一位置数：**962 处**（40 m 并查集聚类，见第八节）
- 难度分布：缓 1264 / 路口 1211 / 中 396 / 急 264
- 字段并集（15 个）：`branchCount, branches, clustered, exitSample, grade, gridX, gridY, headingIn, headingOut, radiusM, turnDeg, turnSign, type, worldX, worldY`
- ⚠️ **`headingIn`/`headingOut` 有 1211 个 `null`** —— 恰好就是全部 `junction` 行。
  **任何遍历都必须先过滤 `type == "bend" and headingIn is not None`**，否则 Python/Swift 侧都会抛类型错误。
- `exitSample`：**1925 个 null**（全部 bend 行 + 1 条 junction）、**1210 个非 null**（其余 junction）。
  > 2026-10-18 修正：旧版写「`exitSample` 有 1 个 `null`」**是错的**——实测 bend 全部为 null、
  > junction 几乎全部有值（仅 1 条 junction 缺）。数量级差 1925 倍。
- `branches` 元素格式（v3b，对象数组）：
  ```json
  {"deg": 330.0, "reachM": 467.0, "widthCells": 14.5, "reachSat": true, "widthValid": true}
  ```
  路口 `branchCount` 分布 3~16（3 个最多 295 条；4 支路 238 条、5 支路 193 条）。

### v2 vs v3b 对照（为什么 v2 已不适用）

| 维度 | `road_corners_v2.json`（旧，**已被 v3b 取代**） | `road_corners_v3b.json`（**当前生产**） |
|---|---|---|
| 总条数 | 4095 | **3135** |
| bend | 1904 | **1924**（+20） |
| junction | 2191 | **1211**（v3b 合并了近距路口） |
| 弯道唯一位置 | 952 | **962** |
| branches 元素 | **纯角度浮点数组** `[90.0, 280.0, …]` | **对象数组** `{deg, reachM, widthCells, reachSat, widthValid}` |
| 能否做主路判据 | ❌ 只有角度，无 reach/width | ✅ 有射线长度 + 宽度 |
| 是否被加载 | ❌ 否（`locateResource` 找 v3b） | ✅ `RoadCornerGuide.ensureLoaded`（`locateResource` 的 name = `road_corners_v3b`） |

> v3b 的对象式 branches 是 `RoadBranch` 结构的直接来源，支撑 `chooseExit` 的
> Y 形主路判据（先比 `RoadBranch.reachM` 再比 `RoadBranch.widthCells`）。v2 的纯角度数组无法做这个判断。
> `--corner-selftest` 输出「其中 1211 条含支路长度宽度」印证的就是 v3b 这条性质。
> 注：v2 的 2191 条 junction **也带 branches 字段**，但元素是纯 float 角度 —— 旧文档说「无 branches」
> 不准确，准确说法是「无长度/宽度维度」。

## 八、★ 已证伪的怀疑：「弯道点只有单向记录」

**起因**：`--corner-selftest` 打印 `· 反向未命中（该处可能只有单向记录）`，
用户也担心「他不从你这个方向开呢」。

**证伪过程**：
- 若用 **20 m 网格**聚类 → 得出误导性的 **29.1% 双向**
- 改用 **40 m 并查集聚类** → **962 处地点**
  - **950 处（98.8%）有 2 个方向族** ✓
  - 仅 **12 处（1.2%）单族**

**结论**：自检那条「反向未命中」是 **1.2% 的尾巴**，不是普遍现象。
**用户最担心的「从另一方向过就瞎了」在数据上不成立。**

## 九、自检实测（`--corner-selftest`，**2026-10-18 复跑**）

**PASS**（`./.build/scratch/release/AuroraDrive --corner-selftest`，exit=0）。输出要点：

```
═══ 弯道打点集 + 路网先验自检 ═══
  ✓ 路网先验位图已加载  — 先验已加载（2048²，3.89 m/格）
  ✓ 先验网格尺寸正确  — grid=2048  3.89 m/格
  ✓ 弯道打点集已加载  — 打点集已加载（弯道 1924 条 / 路口 1211 条，其中 1211 条含支路长度宽度）
     打点总数 = 3135
  ── 前方弯道点试查 ──
    参数: 提前量 40m / 方向容差 60° / 死区 8° / 饱和 35°
      实测2/朝北 世界(-181083,129478) 朝向0° → 无适用弯道点
      实测2/朝东 世界(-181083,129478) 朝向90° → 无适用弯道点
      实测3/朝南 世界(-174798,124811) 朝向180° → 无适用弯道点
      实测1/朝西 世界(-289452,68019) 朝向270° → 无适用弯道点
      实测5/朝北 世界(-148728,136836) 朝向0° → 无适用弯道点
  ── 闭环探针（用打点集自身构造）──
    ✓ 闭环命中：从打点(x=-265102,y=-236169)沿进入方向90°退回35m → 前方26m 中弯，steer=+0.500 | 进弯前对准：向右 63°（距 26m，差 63.4°）
    · 反向未命中（该处可能只有单向记录）
  ── 路口闭环探针 ──
  ✓ 路口闭环：前方命中路口点  — 距 29m，4 条支路
    ✓ 选出口 70°（需转 -30°）置信 0.60 steer=-0.244
      路口前对准：向左（选最贴近车头的支路 70°，29m）
  ✓ 选出口必须在支路里  — 出口 70°
  ✓ 出口不能是来路（不自撞）  — 来路 280° 出口 70°
  ✓ 先验能给出最近道路点  — 距离 4m
═══ 弯道打点集自检：PASS ═══
```

**与 2026-10-02 记录的差异**：本次输出**完全一致**（数字逐项相同），仅多出「选出口必须在支路里」一条断言
（旧记录只写了「选出口 70°」「来路 280° 不自撞」「最近道路点 4m」三条，实际源码里还有一条支路归属断言）。

- ⚠️ **5 个固定实景探针全部报「无适用弯道点」**（实测1/朝西、实测2/朝北·朝东、实测3/朝南、实测5/朝北）
  → 这 5 个探针的坐标**不在 40 m 提前量内的任何弯道上**，属正常但**降低了实景覆盖度**。
  这条 2026-10-18 复跑仍然是同样结果（不是过期问题，是探针坐标选得离弯道远）。

## 十、相关代码位置

- 数据加载：`ensureLoaded()` 内 `locateResource`（资源名 `road_corners_v3b`，**Bundle 根目录 + models/ 子目录 + resourceURL 多路径查找**，2026-09-30 修复：`url(forResource:withExtension:)` 不递归子目录，漏掉 `models/` 子目录会静默 fail-open 回落视觉）
- 来路修正：`let incomingHeading = (headingDeg + 180.0).truncatingRemainder(dividingBy: 360.0)`

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。2026-10-06 由文档更新代理 A8 复核：全文引用按当前源码逐符号回读更新，并补「在驾驶全链路中的位置」一节；数据统计（3135 点/1924 bend/1211 junction）未重测，沿用 2026-10-02 实测值。
**2026-10-07 由文档核对代理 E4 复核**：第二节类型/API 表（`RoadBranch` / `RoadCorner` / `CornerHit` / `RoadCornerGuide`、`ensureLoaded` / `cornerAhead` / `steerForCorner` / `speedAdviceForCorner` / `junctionAhead` / `chooseExit` / `effReach` / `steerForJunction` / `headingDiff` / `signedHeadingDiff` / `debugCornerAt` / `cornerAheadLinearReference` / `junctionProbeFromOwnData` / `probeFromOwnData` / `selfTest`）与第四节参数、第五节航向符号链**全部核对无误**；后续 App 侧调用点也逐符号复核。

**2026-10-18 由 merge-map 复核**（逐条 `sed -n` / `grep -n` / Python 重测）：
- **§1 内容性修正**：补「路口已完整实现并被真实调用」（旧版隐含「路口暂不覆盖」，实际 junction 链路 2026-09-30 起已接线，
  被 `DriveSegmentController.stepJunction` 真实调用，`--corner-selftest` 有路口闭环断言）。
- **§5·5 复核**：AuroraDriveApp.swift 的 tick 链节点已全部改为符号定位（tick → `DriveState.tick()`、laneKeepTiers 门 → `Self.laneKeepTiers`、
  `readPose()`、`segmentDecisionForRule`、`mapSteer`、
  `applyCommand`）均按符号引用。`DriveSegmentController.swift` 未改。
- **§7 重测+修正**：数据统计 2026-10-18 Python 重测确认（3135/1924/1211 不变）；修正「`exitSample` 有 1 个 null」
  为「1925 个 null」（旧记数量级错误 1925 倍）；新增 v2 vs v3b 对照表；修正「v2 无 branches」为「v2 有 branches 但
  是纯角度浮点数组、无 reach/width 维度」（旧记措辞不准确）。
- **§9 复跑**：2026-10-18 实跑 `--corner-selftest` PASS，输出与 2026-10-02 逐项一致；补录「选出口必须在支路里」断言
  （旧记漏写 1 条）。
- **登记源码注释 1 处错误（未改源码）**：`AuroraDriveApp.swift` 注释写 `road_corners_v2.json`，实际加载 v3b
（`RoadCornerGuide.swift` 硬编码 v3b）。—— ⚠️ **该问题已于同日由 lead 修正**，现注释写的就是 v3b，本条结案。
- **RoadCornerGuide.swift 内部全部符号不变**：§2/§3/§4/§6/§10 的 `RoadBranch` / `RoadCorner` / `CornerHit` / `RoadCornerGuide` / `ensureLoaded()` / `cornerAhead` / `steerForCorner` / `speedAdviceForCorner` /
  `junctionAhead` / `chooseExit` / `effReach` / `steerForJunction` / `headingDiff` / `signedHeadingDiff` / `debugCornerAt` / `cornerAheadLinearReference` / `junctionProbeFromOwnData` / `probeFromOwnData` / `selfTest` / `GridKey` / `indexCellMeters` / `ensureLoaded()` 逐条核对全部命中。

**♻️ 2026-10-18 引用符号化（merge-map，源码冻结）** —— 检查 **13** 项，修正 **4** 项，未决 **0** 项：
- `readPose` 定义已按符号 `private func readPose` 定位
- `segmentDecisionForRule` 按函数符号定位
- `mapSteer` 覆盖块按 `if segDecision.overridesVision` 定位
- `applyCommand` 按函数符号定位
- 未变：`DriveState.tick()`、`Self.laneKeepTiers` 门、`AuroraFlags` 读取的 `AURORA_CORNER_*` 系列、
  `RoadCornerGuide.swift` 全部内部符号、`DriveSegmentController.swift` 的 `stepFromVision` /
  `stepJunction`、`RouteGraph.swift`、`MissionConsole.swift`。
- **同批结案**：`AuroraDriveApp.swift` 的 v2→v3b 注释错误已由 lead 修正，本文原「登记源码注释错误」一条作废。