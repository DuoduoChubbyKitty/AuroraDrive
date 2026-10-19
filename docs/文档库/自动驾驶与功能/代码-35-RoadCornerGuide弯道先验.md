# 代码-35 RoadCornerGuide 弯道/路口先验
> ♻️ **行号已按 9097 行版重基准（2026-10-18，merge-map）**：`AuroraDriveApp.swift` 9094→**9097**。
> 逐条 `sed -n 'Np'` 核对语义（未统一平移）：检查 **13 项**跨文件引用，修正 **4 项**，未决 **0 项**。
> 修正：`readPose` :8032-8043→**:8033-8041**；`segmentDecisionForRule` :8046-8061→**:8047-8063**；
> `mapSteer` 块 :7655-7668→**:7656-7669**；`applyCommand` :8082→**:8083-8112**。
> 另：`AuroraDriveApp.swift:7651-7652` 的 v2/v3b 注释错误**已由 lead 修正**（现在写的就是 v3b），
> 本文早前登记的该问题已结案。始终有效：tick :6865、laneKeepTiers 门 :7642、AuroraFlags :309/:310/:311/:313/:315、
> RoadCornerGuide 本体 :44/:58/:102/:112/:166/:170/:177-182/:209-229/:216-228/:234/:307/:314-319/:355/:421/:460/:472/
> :503/:534/:562-590/:567/:602/:632/:639/:642-650/:649/:661/:695/:717/:738、DriveSegmentController :157/:158-160/:161-163/:217/:263/:280-284/:310、
> RouteGraph :404-540、MissionConsole :4489-4509/:1201-1208。
>
> ✅ **2026-10-18 复核（merge-map）**：修正 2 处**内容性过期**（不只是行号）：
> ① 第一节补「路口已完整实现并被真实调用」——旧版隐含「路口暂不覆盖」，实际 `junctionAhead`/`chooseExit`/
> `steerForJunction` 自 2026-09-30 起就已接线（`DriveSegmentController.swift:161-163` / `:280-284`）；
> ② 数据源统一为 **`road_corners_v3b.json`**（3135 点 / 1924 弯 / 1211 路口），并新增与 v2 的差异对照表。
> 另：第五·五节 AuroraDriveApp 行号按 **9094** 行版重测（原 9088 版行号全部 +3~+8 漂移）；
> 登记源码注释 1 处错误（`AuroraDriveApp.swift:7651` 写 v2、实际读 v3b）。RoadCornerGuide.swift 757 行未变。
>
> ✅ 2026-10-17 复核（T7）：第五·五节「生效路径」行号曾按 9088 行版修正（tick=6862 / laneKeepTiers 门=7634 /
> readPose=8024-8032 / segmentDecisionForRule=8038-8054 / mapSteer 覆盖块=7647-7661 / applyCommand=8074-8103）
> —— **该组行号已于 2026-10-18 按 9097 行版最终重基准，以本文 §5.5 为准**。

> 覆盖源文件：`Sources/AuroraDrive/Inference/RoadCornerGuide.swift`（**757 行，2026-10-07 `wc -l` 复测，与旧记一致**；2026-10-02 版为 752 行，行号以 757 行版为准，已逐条回读核实）
> 数据源：`models/road_corners_v3b.json`（**1622667 B**，2026-10-07 `ls -l` 复测，与旧记一致）
> 🔁 **2026-10-07 由文档核对代理 E4 复核**：源文件 757 行未变，第二节类型/API 表与第四节参数行号、第五节航向符号链**逐条核对无误**；**仅第五·五节「在驾驶全链路中的位置」的 AuroraDriveApp.swift 行号失效**（App 当时已增至 8456 行；2026-10-17 已按 9088 行版重新实测修正）。数据统计（3135 点/1924 bend/1211 junction）**本次未重测**，沿用 2026-10-02 实测值。
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
  **弯道优先于路口**（弯道打点密集 + 双向，实测与路口 0 重叠，`DriveSegmentController.swift:158-160` 注释）

> ⚠️ **旧文档说「路口暂不覆盖」已过期**：本文 2026-10-02 版写「路口也留了数据但转向决策暂不覆盖」，
> 那对应的是 RoadCornerGuide.swift **v2 时代**的状态。2026-09-30 起路口选路已完整实现
> （`junctionAhead:503` / `chooseExit:534` / `steerForJunction:602` / Y 形主路判据 `:562-590`），
> 并被 `DriveSegmentController.stepFromVision`（`:161-163`）与 `stepJunction`（`:280-284`）**真实调用**。
> `--corner-selftest` 也有专门的路口闭环断言（见第九节）。

## 二、数据结构

| 类型 | 行号 | 说明 |
|---|---|---|
| `struct RoadBranch` | `:44` | 支路：`deg`（出口角度）/ `reachM` / `widthCells` / `reachSaturated` / `widthValid` |
| `struct RoadCorner` | `:58` | 单个打点：`type`(`bend`/`junction`)、`worldX/Y`、`headingIn/Out`、`radiusM`、`turnDeg`、`turnSign`、`grade`、`branches` |
| `struct CornerHit` | `:102` | 命中结果（含距离 `distanceM`、方向夹角 `headingDiffDeg`） |
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

## 四、参数（`AURORA_CORNER_*`；A17 迁移后经 `AuroraFlags` 读取，init :209-229，AuroraFlags 读取 :216-228）

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

## 五·五、★ 在驾驶全链路中的位置（♻️ 行号 2026-10-18 按 AuroraDriveApp.swift **9097** 行版逐条重测）

本文件是**真实操控链的弯道/路口数据源**——不是 RoutePlan（A*）：

- 消费入口：`DriveSegmentController.stepFromVision` → `RoadCornerGuide.shared.cornerAhead`（`Agent/DriveSegmentController.swift:157`）；路口走 `junctionAhead`/`chooseExit`/`steerForJunction`（:161-163/:280-284）；回正/过弯用 `signedHeadingDiff`（:217/:263/:310）。
- 生效路径（全部 2026-10-18 按 **9097** 行版实测；括号内注上一版 9094 行版的值便于追溯）：
  `DriveState.tick()`（AuroraDriveApp.swift **:6865**，与 9094 版相同）→ laneKeepTiers 门（**:7642**，相同）→
  `readPose()`（locatorScore≥0.4，定义 **:8033-8041**，上一版写 :8032-8043）→
  `segmentDecisionForRule`（**:8047-8063**，上一版写 :8046-8061）→
  `mapSteer` 覆盖视觉转向（**:7656-7669**，上一版写 :7655-7668）→
  `applyCommand`（**:8083-8112**，上一版写 :8082）注入按键。
- 对照：`RoutePlan`（A*，`App/RouteGraph.swift:404-540`）的 `points` 只供小地图画折线（`App/MissionConsole.swift:4489-4509`）与任务卡弯道距离显示（数据 :642-650、口径注释 :1201-1208），**不产生按键**（未验证有其它接线）。

> ✅ **源码注释的 v2/v3b 错误已被 lead 修正**：`AuroraDriveApp.swift:7651-7652` 现写作
> 「前方弯道点 ← RoadCornerGuide（**road_corners_v3b.json** 打点集；原写 v2 已过期 —— 源码
> RoadCornerGuide.swift:307 实际加载 v3b）」。本文 2026-10-18 早前登记的「注释写 v2」已不再是问题。
> v2 与 v3b 的差异见第七节对照表（核心：v2 的 branches 是纯角度数组，v3b 是带 reachM/widthCells 的对象数组）。

## 六、空间索引与其等价性证明

- `GridKey{gx, gy}`（`:166`），格边 128 m（`indexCellMeters` `:170`），分桶建索引 `:177-182`
- **对拍**：`cornerAheadLinearReference`（`:661`）是未优化的线性实现
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
| 是否被加载 | ❌ 否（`locateResource` 找 v3b） | ✅ `RoadCornerGuide.swift:307` |

> v3b 的对象式 branches 是 `RoadBranch` 结构（`:44-55`）的直接来源，支撑 `chooseExit` 的
> Y 形主路判据（先比 reachM 再比 widthCells，`:562-590`）。v2 的纯角度数组无法做这个判断。
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

- 数据加载：`:307`（资源名 `road_corners_v3b`）、`:314-319`（**Bundle 根目录 + models/ 子目录 + resourceURL 多路径查找**，2026-09-30 修复：`url(forResource:withExtension:)` 不递归子目录，漏掉 `models/` 子目录会静默 fail-open 回落视觉）
- 来路修正：`let incomingHeading = (headingDeg + 180.0).truncatingRemainder(dividingBy: 360.0)`

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。2026-10-06 由文档更新代理 A8 复核：全文行号按 757 行版回读更新，并补「在驾驶全链路中的位置」一节；数据统计（3135 点/1924 bend/1211 junction）未重测，沿用 2026-10-02 实测值。
**2026-10-07 由文档核对代理 E4 复核**：源文件 757 行、数据文件 1622667 B 均未变；第二节类型/API 表（`RoadBranch:44` / `RoadCorner:58` / `CornerHit:102` / `RoadCornerGuide:112`、`ensureLoaded:234`、`cornerAhead:355`、`steerForCorner:421`、`speedAdviceForCorner:472`、`junctionAhead:503`、`chooseExit:534`、`effReach:567`、`steerForJunction:602`、`headingDiff:632`、`signedHeadingDiff:639`、`debugCornerAt:649`、`cornerAheadLinearReference:661`、`junctionProbeFromOwnData:695`、`probeFromOwnData:717`、`selfTest:738`）与第四节参数行号、第五节航向符号链**全部核对无误**；第五·五节 App 行号按 8456 行版重测；**2026-10-17 已按 9088 行版重新实测修正（T7）**。

**2026-10-18 由 merge-map 复核**（逐条 `sed -n` / `grep -n` / Python 重测）：
- **§1 内容性修正**：补「路口已完整实现并被真实调用」（旧版隐含「路口暂不覆盖」，实际 junction 链路 2026-09-30 起已接线，
  被 `DriveSegmentController.swift:161-163` / `:280-284` 真实调用，`--corner-selftest` 有路口闭环断言）。
- **§5·5 行号重测**：AuroraDriveApp.swift 9088→9094 行，tick 链全部 +3~+8（tick :6862→:6865、laneKeepTiers 门 :7634→:7642、
  readPose :8024-8032→:8032-8043、segmentDecisionForRule :8038-8054→:8046-8061、mapSteer :7647-7661→:7655-7668、
  applyCommand :8074-8103→:8082）。DriveSegmentController.swift 行号全部不变（该文件本次未改）。
- **§7 重测+修正**：数据统计 2026-10-18 Python 重测确认（3135/1924/1211 不变）；修正「`exitSample` 有 1 个 null」
  为「1925 个 null」（旧记数量级错误 1925 倍）；新增 v2 vs v3b 对照表；修正「v2 无 branches」为「v2 有 branches 但
  是纯角度浮点数组、无 reach/width 维度」（旧记措辞不准确）。
- **§9 复跑**：2026-10-18 实跑 `--corner-selftest` PASS，输出与 2026-10-02 逐项一致；补录「选出口必须在支路里」断言
  （旧记漏写 1 条）。
- **登记源码注释 1 处错误（未改源码）**：`AuroraDriveApp.swift:7651` 注释写 `road_corners_v2.json`，实际加载 v3b
  （`RoadCornerGuide.swift:307` 硬编码 v3b）。—— ⚠️ **该问题已于同日由 lead 修正**，现注释写的就是 v3b（:7651-7652），本条结案。
- **RoadCornerGuide.swift 内部全部行号不变**：757 行未改，§2/§3/§4/§6/§10 的 `:44/:58/:102/:112/:234/:355/:421/:472/
  :503/:534/:567/:602/:632/:639/:649/:661/:695/:717/:738/:166/:170/:307/:314-319` 逐条核对全部命中正确行。

**♻️ 2026-10-18 行号重基准（merge-map，源码冻结 9097 行版）** —— 检查 **13** 项，修正 **4** 项，未决 **0** 项：
- `readPose` 定义 :8032-8043 → **:8033-8041**（:8033 `private func readPose` → :8041 `}`）
- `segmentDecisionForRule` :8046-8061 → **:8047-8063**（:8047 声明 → :8063 `}`）
- `mapSteer` 覆盖块 :7655-7668 → **:7656-7669**（:7656 `if segDecision.overridesVision` → :7669 `}`）
- `applyCommand` :8082 → **:8083-8112**（:8083 声明 → :8112 `}`）
- 未变：tick :6865、laneKeepTiers 门 :7642、`AuroraFlags.swift` :309/:310/:311/:313/:315（543 行未变）、
  `RoadCornerGuide.swift` 全部内部行号（757 行未变）、`DriveSegmentController.swift` 全部（:157/:158-160/:161-163/
  :217/:263/:280-284/:310，430 行未变）、`RouteGraph.swift:404-540`、`MissionConsole.swift:4489-4509`/`:1201-1208`。
- **同批结案**：`AuroraDriveApp.swift:7651-7652` 的 v2→v3b 注释错误已由 lead 修正，本文原「登记源码注释错误」一条作废。
