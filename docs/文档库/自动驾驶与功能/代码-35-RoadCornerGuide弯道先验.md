# 代码-35 RoadCornerGuide 弯道/路口先验

> 覆盖源文件：`Sources/AuroraDrive/Inference/RoadCornerGuide.swift`（**757 行，2026-10-07 `wc -l` 复测，与旧记一致**；2026-10-02 版为 752 行，行号以 757 行版为准，已逐条回读核实）
> 数据源：`models/road_corners_v3b.json`（**1622667 B**，2026-10-07 `ls -l` 复测，与旧记一致）
> 🔁 **2026-10-07 由文档核对代理 E4 复核**：源文件 757 行未变，第二节类型/API 表与第四节参数行号、第五节航向符号链**逐条核对无误**；**仅第五·五节「在驾驶全链路中的位置」的 AuroraDriveApp.swift 行号失效**（App 已增至 8456 行），本次只修该节。数据统计（3135 点/1924 bend/1211 junction）**本次未重测**，沿用 2026-10-02 实测值。
> 关联：[`代码-34-DriveSegmentController驾驶分段控制器.md`](代码-34-DriveSegmentController驾驶分段控制器.md)（消费方）、
> [`代码-36-RoadMapPrior路网先验.md`](代码-36-RoadMapPrior路网先验.md)（姊妹先验）

---

## 一、用途

从离线生成的**弯道/路口打点库**中，按自车位置 + 朝向查出「前方有没有弯、往哪拐、该多快」。
这是**纯视觉做不到的部分**（车道线丢失时仍知道路往哪走）。

## 二、数据结构

| 类型 | 行号 | 说明 |
|---|---|---|
| `struct RoadBranch` | `:44` | 支路：`deg`（出口角度）/ `reachM` / `widthCells` / `reachSaturated` / `widthValid` |
| `struct RoadCorner` | `:58` | 单个打点：`type`(`bend`/`junction`)、`worldX/Y`、`headingIn/Out`、`radiusM`、`turnDeg`、`turnSign`、`grade`、`branches` |
| `struct CornerHit` | `:100` | 命中结果（含距离 `distanceM`、方向夹角 `headingDiffDeg`） |
| `final class RoadCornerGuide` | `:112` | 单例门面 |

## 三、公开 API

| 方法 | 行号 | 用途 |
|---|---|---|
| `ensureLoaded()` | `:234` | 懒加载 `road_corners_v3b.json` |
| `cornerAhead(worldX:worldY:headingDeg:)` | `:355` | 查前方弯道 |
| `steerForCorner(_:headingDeg:...)` | `:421` | 弯道转向量 |
| `speedAdviceForCorner(_:speedKmh:)` | `:472` | 弯道限速建议 |
| `junctionAhead(worldX:worldY:headingDeg:)` | `:503` | 查前方路口 |
| `chooseExit(junction:worldX:worldY:...)` | `:534` | 路口选出口（含 `effReach` 启发 `:567`） |
| `steerForJunction(_:exit:...)` | `:602` | 路口转向量 |
| `headingDiff(_:_:)` / `signedHeadingDiff(from:to:)` | `:632` / `:639` | 航向差（后者带符号，★ 关键） |
| `debugCornerAt(_:)` | `:649` | 调试取点 |
| `cornerAheadLinearReference(...)` | `:661` | **线性实现，供空间索引对拍**（等价性验证用） |
| `junctionProbeFromOwnData()` / `probeFromOwnData()` | `:695` / `:717` | 从自身数据造闭环探针 |
| `selfTest(probes:)` | `:738` | 自检（`--corner-selftest`） |

## 四、参数（`AURORA_CORNER_*`；A17 迁移后经 `AuroraFlags` 读取，init :128-143）

| 参数 | 默认（`Core/AuroraFlags.swift` 行号） |
|---|---|
| `AURORA_CORNER_LOOKAHEAD_M` | **40.0**（AuroraFlags.swift:309） |
| 方向容差 `AURORA_CORNER_HEADING_TOL_DEG` | 60°（:311） |
| 转向死区 `AURORA_CORNER_DEADBAND_DEG` | 8°（:313） |
| 转向饱和 `AURORA_CORNER_SAT_DEG` | 35°（:315） |
| `indexCellMeters`（空间索引格） | **128.0 m**（本文件 `:170`） |

> 索引格 128 m **远大于**提前量 40 m，故 `3×3` 格必然包含全部候选（`cornerAhead` 注释处）。

## 五、★ 航向符号链（**已核实正确**）

```
compassBearing(fromX:fromY:toX:toY:)   :460
    compass = atan2(dx, -dy)
    图像 +X = 东、图像 -Y = 北；世界 +Y = 南
    ⟹ 罗盘 0° = 北、90° = 东

signedHeadingDiff(from:to:)            :639–644
    返回规范化 (to − from) 到 (−180, 180]

消费端：diff > 0 → steerRight            ✓ 正确
```

**方向核验**：罗盘角 0°=北 → 90°=东，**右转时航向角增大** ⟹ `diff > 0` 对应右转 ✓ 链路自洽。

## 五·五、★ 在驾驶全链路中的位置（2026-10-07 由核对代理 E4 按当前 App 重测行号）

本文件是**真实操控链的弯道数据源**——不是 RoutePlan（A*）：

- 消费入口：`DriveSegmentController.stepFromVision` → `RoadCornerGuide.shared.cornerAhead`（`Agent/DriveSegmentController.swift:157`）；路口走 `junctionAhead`/`chooseExit`/`steerForJunction`（:161-163/:280-284）；回正/过弯用 `signedHeadingDiff`（:217/:263/:310）。
- 生效路径：`DriveState.tick()`（AuroraDriveApp.swift:6505）→ laneKeepTiers 门（:7038）→ `readPose()`（locatorScore≥0.4，定义 :7392-7400）→ `segmentDecisionForRule`（:7406-7422）→ `mapSteer` 覆盖视觉转向（:7051-7061）→ `applyCommand`（:7442-7471）注入按键。
- 对照：`RoutePlan`（A*，`App/RouteGraph.swift:404-540`）的 `points` 只供小地图画线（`App/MissionConsole.swift:3912-3942`）与弯道距离显示（:627-635），**不产生按键**（未验证有其它接线）。

> ⚠️ 本节旧行号（App 8335 行版：`tick()` :6384、档位门 :6917、readPose :7271-7279、applyCommand :7321-7350）**已全部失效**——App 主文件现为 **8456 行**，上面行号 2026-10-07 逐条 `grep` 回读核实。

## 六、空间索引与其等价性证明

- `GridKey{gx, gy}`，格边 128 m（`:166-174`）
- **对拍**：`cornerAheadLinearReference`（`:661`）是未优化的线性实现
- **实测等价性**：`索引对拍: 探针命中 91 次，不一致 0 次 ✓`（`--perf-selftest` 输出）
- **性能**：预热后 `cornerAhead` p50 **0.000–0.003 ms**；一帧地图查询合计 p50 **0.004 ms**

> ⚠️ **测量陷阱（已踩过）**：首次测量得 `cornerAhead` **31.4 ms** —— 这是 **`n=1` 撞上懒加载**的假象。
> 预热后真值为 0.000–0.003 ms，**差 10000 倍**。

## 七、数据文件实测（`models/road_corners_v3b.json`）

- **顶层是 JSON 数组**（不是对象），共 **3135 个点**
- 类型分布：`bend` **1924** / `junction` **1211**
- 难度分布：缓 1264 / 路口 1211 / 中 396 / 急 264
- 字段并集：`branchCount, branches, clustered, exitSample, grade, gridX, gridY, headingIn, headingOut, radiusM, turnDeg, turnSign, type, worldX, worldY`
- ⚠️ **`headingIn`/`headingOut` 有 1211 个 `null`** —— 恰好就是全部 `junction` 行。
  **任何遍历都必须先过滤 `type == "bend" and headingIn is not None`**，否则 Python/Swift 侧都会抛类型错误。
- ⚠️ `exitSample` 有 1 个 `null`。

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

## 九、自检实测（`--corner-selftest`，2026-10-02）

**PASS**。输出要点：
- 先验 2048² / 3.89 m 每格
- 弯道 **1924** 条 / 路口 **1211** 条；打点总数 **3135**
- 参数：提前量 40m / 方向容差 60° / 死区 8° / 饱和 35°
- **闭环探针 ✓**：`(x=-265102, y=-236169)` 沿进入方向 90° 退回 35 m
  → 前方 26 m 中弯 `steer=+0.500`；进弯前对准向右 63°（差 63.4°）
- **路口闭环 ✓**：距 29 m 有 4 条支路，选出口 70°（需转 −30°）置信 0.60 `steer=-0.244`；
  来路 280° 不自撞；最近道路点 4 m
- ⚠️ **5 个固定实景探针全部报「无适用弯道点」**（实测1/朝西、实测2/朝北·朝东、实测3/朝南、实测5/朝北）
  → 这 5 个探针的坐标**不在 40 m 提前量内的任何弯道上**，属正常但**降低了实景覆盖度**

## 十、相关代码位置

- 数据加载：`:307`（资源名 `road_corners_v3b`）、`:309-312`（**Bundle 根目录 + models/ 子目录双查找**，2026-09-30 修复：`url(forResource:withExtension:)` 不递归子目录，漏掉 `models/` 子目录会静默 fail-open 回落视觉）
- 来路修正：`let incomingHeading = (headingDeg + 180.0).truncatingRemainder(dividingBy: 360.0)`

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。2026-10-06 由文档更新代理 A8 复核：全文行号按 757 行版回读更新，并补「在驾驶全链路中的位置」一节；数据统计（3135 点/1924 bend/1211 junction）未重测，沿用 2026-10-02 实测值。
**2026-10-07 由文档核对代理 E4 复核**：源文件 757 行、数据文件 1622667 B 均未变；第二节类型/API 表（`RoadBranch:44` / `RoadCorner:58` / `CornerHit:102` / `RoadCornerGuide:112`、`ensureLoaded:234`、`cornerAhead:355`、`steerForCorner:421`、`speedAdviceForCorner:472`、`junctionAhead:503`、`chooseExit:534`、`effReach:567`、`steerForJunction:602`、`headingDiff:632`、`signedHeadingDiff:639`、`debugCornerAt:649`、`cornerAheadLinearReference:661`、`junctionProbeFromOwnData:695`、`probeFromOwnData:717`、`selfTest:738`）与第四节参数行号、第五节航向符号链**全部核对无误**；第五·五节 App 行号按 8456 行版重测。
