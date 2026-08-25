# Apollo Rule-based Planner 与 StopDecider 深度研究报告

> 研究主题：Apollo 规则化（rule-based）决策规划体系、RuleBasedStopDecider 停车决策、规则路径/速度决策、规则 vs 学习决策对比、Rule-based Fallback、与 Mobileye RSS 对比，以及向 AuroraDrive 规则体系迁移的建议。
>
> 研究方法：通过 WebSearch / WebFetch 对 Apollo 官方文档、ApolloAuto/apollo GitHub 源码目录、CSDN/掘金/博客园技术解析、Mobileye RSS 公开资料、Aurora 安全案例公开资料进行检索与抓取。
>
> 适用版本：以 Apollo 6.0 / 9.0 / 10.0 公开代码与文档为主，必要时标注版本差异。

---

## 0. 总览与术语约定

Apollo 的规划（Planning）模块在其演进过程中先后出现过多种规划器：RTK Replay Planner（回放）、Public Road Planner（开放道路，默认）、Lattice Planner（高采样轨迹）、Navi Planner（基于导航相对地图）、Open Space Planner（开放空间，Hybrid A* + DP）。自 Apollo 3.5 起，Planning 引入"双层状态机 + Scenario/Stage/Task"架构，把驾驶用例拆成不同 Scenario，使某一场景的问题修复不影响其它场景。

需要澄清一个常见误解：Apollo 文档里并没有一个名为 "Rule-based Planner" 的独立 Planner 类。所谓 "Apollo rule-based planner" 在工程语义上指的是：

1. **Public Road Planner**：以 Scenario → Stage → Task 三级架构驱动的默认开放道路规划器，其行为决策（Decider 类 Task）由大量规则 + 代价函数构成，属于"规则主导、优化兜底"的范式。
2. **Task 链中的 Decider 族**：如 LaneChangeDecider、PathLaneBorrowDecider、PathBoundsDecider、PathAssessmentDecider、PathDecider、RuleBasedStopDecider、STBoundsDecider、SpeedDecider 等，均为规则化决策单元。
3. **TrafficDecider（交通规则决策器）**：在 Scenario 运行之前对所有参考线统一施加的交通规则层（停止标志、红绿灯、人行道、让行、禁停区、参考线终点等），是纯规则模块。
4. **Fallback 轨迹**：OnLanePlanning::RunOnce 在主轨迹之外，始终生成一条保守的规则化 fallback 轨迹，作为安全兜底。

因此本报告把 "Apollo rule-based planner" 理解为上述四层规则的集合体，并重点剖析其中的 `RuleBasedStopDecider` 与路径/速度决策 Task。

---

## 1. Apollo Rule-based 规划体系

### 1.1 规划器谱系与定位

| 规划器 | 类型 | 适用场景 | 核心思想 |
|---|---|---|---|
| RTK Replay Planner | 回放 | 录制数据复现 | 直接回放预先录制的轨迹 |
| Public Road Planner | 场景+规则+优化（默认） | 结构化开放道路 | Scenario/Stage/Task 三级架构，PV 解耦 |
| Lattice Planner | 采样+择优 | 高速、简单场景 | 在 Frenet 坐标采样末端状态，五次/四次多项式同时生成路径与速度 |
| Navi Planner | 规则+相对地图 | 基于导航无高精地图 | 相对地图上规划 |
| Open Space Planner | 搜索+优化 | 泊车、掉头、路口开放空间 | Hybrid A* 路径 + DP 速度 |

### 1.2 与 EM Planner / Lattice 的关系

Apollo 早期（3.0 之前）以 **EM Planner**（Iterative EM，路径与速度迭代优化）作为结构化道路主力。EM Planner 的特点是：路径与速度解耦，分别在 SL 与 ST 图上做 QP 优化，迭代收敛，擅长复杂城市工况但实现复杂。

从 Apollo 3.5 起，**Public Road Planner** 取代单一 EM Planner 成为默认规划器，但它并没有抛弃优化——而是把优化下沉到 Task 内（如 PiecewiseJerkPathOptimizer、PiecewiseJerkSpeedOptimizer），决策部分由规则化 Decider 完成。换言之，Public Road Planner ≈ "规则决策 + 分段加加速度优化"，可以视为 EM 思想在场景化架构下的演化。

**Lattice Planner** 则保留为另一条技术线：

- Lattice 同时生成满足车辆动力学的路径与速度曲线，无需二次平滑；参数少、计算量低；
- 轨迹形状固定（多项式），适合高速或快速路等简单场景；
- EM/Public Road 则是 PV 解耦 + 迭代优化，更适合复杂城市交互。

二者关系：互补而非替代。Lattice 强调"一次成型、低开销"，EM/Public Road 强调"分层决策、精细优化"。

### 1.3 双层状态机与 Scenario/Stage/Task

- **Top Layer（Scenario 状态机）**：由 `ScenarioManager` 根据环境、地图、路由信息选择当前场景，如 LaneFollow、TrafficLightProtected、TrafficLightUnprotected、StopSignUnprotected、YieldSign、PullOver、ParkAndGo、ValetParking、Emergency、BareIntersection 等。
- **Bottom Layer（Stage 状态机）**：每个 Scenario 含若干 Stage，前一 Stage 完成后切换到下一个；所有 Stage 完成即视为 Scenario 完成。
- **Task**：Stage 内的具体算法单元，分为 Decider（决策）、Optimizer（优化）、TrajectoryGenerator（轨迹生成）等类别，串行执行。

### 1.4 规则体系的四个层次

Apollo 的"规则"贯穿四层：

1. **交通规则层（TrafficDecider）**：在 Scenario 之前对所有参考线施加，输出虚拟停止墙/限速等，纯规则。
2. **行为决策层（Scenario/Stage FSM + Decider Task）**：场景切换、变道、借道、停车、让行等高层行为。
3. **运动决策层（PathBoundsDecider / SpeedDecider 等）**：生成路径边界、ST 边界、纵向决策标签。
4. **安全兜底层（RuleBasedStopDecider + Fallback 轨迹）**：规则化强制停车与保守 fallback。

---

## 2. RuleBasedStopDecider 深度解析

### 2.1 源码位置与 Task 链位置

源码路径：`modules/planning/planning_base/tasks/deciders/rule_based_stop_decider.cc`（Apollo 9.0/10.0 在 `planning_base` 下；早期版本在 `modules/planning/tasks/deciders/`）。

在 LaneFollow 场景的 `LaneFollowStage` 中，Task 串行顺序大致为：

```
1.  LANE_CHANGE_DECIDER
2.  PATH_REUSE_DECIDER
3.  PATH_LANE_BORROW_DECIDER
4.  PATH_BOUNDS_DECIDER
5.  PIECEWISE_JERK_PATH_OPTIMIZER        (路径优化)
6.  PATH_ASSESSMENT_DECIDER
7.  PATH_DECIDER
8.  RULE_BASED_STOP_DECIDER              ← 规则化停车决策，第 8 个
9.  ST_BOUNDS_DECIDER
10. SPEED_BOUNDS_PRIORI_DECIDER
11. SPEED_HEURISTIC_OPTIMIZER            (速度 DP)
12. SPEED_DECIDER
13. SPEED_BOUNDS_FINAL_DECIDER
14. PIECEWISE_JERK_SPEED_OPTIMIZER       (速度 QP)
```

即 `RuleBasedStopDecider` 处于 **路径决策完成之后、速度决策之前** 的关键位置：此时路径已确定，决策器需要根据路径几何与障碍物布局，补充若干规则化停车点（以虚拟停止障碍的形式注入参考线），供后续速度规划避让。

### 2.2 输入 / 输出

- **输入**：`Frame*`（全局帧，含障碍物、车辆状态）、`ReferenceLineInfo*`（参考线信息，含已生成的 `path_data`、`path_point_decision_guide`、`AdcSlBoundary` 等）。
- **输出**：通过 `util::BuildStopDecision(...)` 向 `ReferenceLineInfo` 注入 `STOP` 决策（虚拟停止墙 / stop fence），包含 stop_wall_id、停止 s 坐标、停车距离 buffer、StopReasonCode、wait_for_obstacles 列表、决策 tag。

### 2.3 总体处理流程

`RuleBasedStopDecider::Process()` 依次调用三大子模块：

1. `AddPathEndStop()`：路径终点停车
2. `CheckLaneChangeUrgency()`：紧急变道停车
3. `StopOnSidePass()`：侧向通过（借逆向车道绕行）停车

`StopOnSidePass` 内部进一步调用：`CheckClearDone`、`CheckSidePassStop`、`IsPerceptionBlocked`、`IsClearToChangeLane`、`BuildStopDecision`，以及辅助函数 `NormalizeAngle`、`SelfRotate`。

### 2.4 三大停车子场景

#### 2.4.1 路径终点停车（AddPathEndStop）

当路径长度（path 末端 s − 起点 s）小于阈值 `short_path_length_threshold`（默认 20.0 m）时，在路径末端前 0.1 m 处设置停止墙，StopReasonCode 为 `STOP_REASON_REFERENCE_END`。stop_wall_id 前缀为 `PATH_END_VO_ID_PREFIX + path_label`。

意义：当参考线过短（如即将到达终点、地图截断）时，强制车辆在路径末端前安全停车，避免冲出可规划范围。

#### 2.4.2 紧急变道停车（CheckLaneChangeUrgency）

当车辆需要变道但目标车道被阻塞时，根据距变道起点的距离评估紧急程度：

- `approach_distance_for_lane_change`（默认 80.0 m）：进入"接近"区间，开始关注；
- `urgent_distance_for_lane_change`（默认 50.0 m）：进入"紧急"区间，若仍无法变道则设停止墙（StopReasonCode: `STOP_REASON_LANE_CHANGE_URGENCY`），让车辆在当前车道减速停车等待，而非强行切入。

状态缓存：用 `is_clear_to_change_lane_` 与 `is_change_lane_planning_succeed_` 标志避免重复计算。

#### 2.4.3 侧向通过停车（StopOnSidePass / CheckSidePassStop）

这是最复杂的子场景，处理车辆借用逆向车道绕行静态阻塞时，需在"驶入逆向车道前"停车确认安全：

- 遍历 `path_data.path_point_decision_guide()`，当路径点类型从 `IN_LANE` 切换到 `OUT_ON_REVERSE_LANE` 时，记录该切换点 s 作为候选停止点；
- 结合车辆参数 `front_edge_to_center` 做几何修正，得到精确停止 s；
- `IsPerceptionBlocked` 用"搜索光束"（search beam）判断感知是否被遮挡：参数 `search_beam_length`(5.0)、`search_beam_radius_intensity`(0.08)、`search_range`(3.14)、`is_block_angle_threshold`(1.57)，若被遮挡则在借道前停车（StopReasonCode: `STOP_REASON_SIDEPASS_SAFETY`）；
- `CheckADCStop` 验证自车是否真的停住：要求 `linear_velocity ≤ max_adc_stop_speed`(0.3 m/s) 且 `stop_line_to_adc_front_edge ≤ max_valid_stop_distance`(0.5 m)；
- `CheckClearDone` 判断借道绕行是否已完成、可清除停止状态。

### 2.5 关键配置参数表

| 参数名 | 默认值 | 单位 | 含义 |
|---|---|---|---|
| `max_adc_stop_speed` | 0.3 | m/s | 判定自车"已停"的最大速度 |
| `max_valid_stop_distance` | 0.5 | m | 停止线到自车前缘的最大有效距离 |
| `search_beam_length` | 5.0 | m | 感知遮挡搜索光束长度 |
| `search_beam_radius_intensity` | 0.08 | - | 搜索光束半径步进强度 |
| `search_range` | 3.14 | rad | 搜索角度范围 |
| `is_block_angle_threshold` | 1.57 | rad | 阻塞角度阈值（约 90°）|
| `approach_distance_for_lane_change` | 80.0 | m | 变道接近距离 |
| `urgent_distance_for_lane_change` | 50.0 | m | 变道紧急距离 |
| `short_path_length_threshold` | 20.0 | m | 短路径阈值（触发路径终点停车）|

### 2.6 StopReasonCode 分类

| 原因码 | 描述 | 触发场景 |
|---|---|---|
| `STOP_REASON_REFERENCE_END` | 参考线/路径终点 | 短路径终点 |
| `STOP_REASON_LANE_CHANGE_URGENCY` | 紧急变道 | 目标车道阻塞且距变道点过近 |
| `STOP_REASON_SIDEPASS_SAFETY` | 侧向通过安全 | 借逆向车道绕行前感知被遮挡 |

（注：Apollo 中 StopReasonCode 枚举远不止这三类，红绿灯、停止标志、人行道等另有专属原因码，由 TrafficDecider 与各 Scenario 注入，见第 3 节。）

### 2.7 设计要点小结

1. **以虚拟停止墙统一表达**：所有规则停车最终都通过 `BuildStopDecision` 转成参考线上的 STOP 虚拟障碍，下游速度规划无需区分原因，统一避让。
2. **状态缓存与早退**：通过 status 标志与条件短路减少重复计算，保证实时性。
3. **几何 + 感知双重判定**：侧向通过不仅看几何可达，还用光束搜索判断感知盲区，体现"看不见就停"的安全哲学。
4. **可配置驱动**：所有阈值走 proto 配置，便于不同车型/ODD 调参。

---

## 3. Rule 停车场景全景

Apollo 的"停车"并非由单一模块完成，而是分布在 **TrafficDecider（交通规则层）**、**Scenario 专属 Stage（场景层）**、**RuleBasedStopDecider / SpeedDecider（决策层）**、**Fallback（兜底层）** 四处。下表给出全景。

### 3.1 Apollo 停车规则总表

| 停车场景 | 触发模块 | 触发条件（规则） | 停止点设置 | StopReasonCode / 说明 |
|---|---|---|---|---|
| **Stop Sign 停车标志** | TrafficDecider `stop_sign` + `StopSignUnprotectedScenario` | 路口有 stop_sign 规则、自车未在该标志前完全停过 | stop_sign 停止线前 `stop_distance` 处设停止墙 | `STOP_REASON_STOP_SIGN`；Stage 流程：停→Creep→观察冲突车→通行 |
| **Traffic Light 红绿灯** | TrafficDecider `traffic_light` + `TrafficLightProtected/UnprotectedScenario` | 信号灯非绿灯（红/黄） | 停止线前设停止墙 | `STOP_REASON_TRAFFIC_LIGHT`；绿灯通行，红/黄停 |
| **Crosswalk 人行道** | TrafficDecider `crosswalk` | 人行道附近 s/l 范围内有行人或潜在行人 | 人行道前 `stop_distance`（典型 5.5 m）处设停止墙 | `STOP_REASON_PEDESTRIAN`；参数 `stop_strict_l_distance`/`stop_loose_l_distance` 控制横向触发；`stop_timeout` 防死等 |
| **Yield 让行** | TrafficDecider `yield_sign` | 让行标志附近有冲突车辆 | 让行线前设停止墙 | `STOP_REASON_YIELD_SIGN`；无冲突则不停 |
| **Destination 目的地** | TrafficDecider `destination` | 接近路由终点 | 终点前设停止墙 | `STOP_REASON_DESTINATION` |
| **KeepClear 禁停区** | TrafficDecider `keepclear` | 禁停区域内有 block 障碍 | 禁停区**外**设停止墙 | 禁停区内不得停车，前方有阻塞时停在区外 |
| **Reference Line End 参考线终点** | TrafficDecider `reference_line_end` | 接近参考线终点 | 参考线终点设停止墙 | `STOP_REASON_REFERENCE_END` |
| **Rerouting 重新路由** | TrafficDecider `rerouting` | 规划被阻塞需重路由 | 发送 rerouting 请求 | 不直接停车，触发重路由 |
| **路径终点（短路径）** | `RuleBasedStopDecider::AddPathEndStop` | path 长度 < 20 m | 路径末端前 0.1 m | `STOP_REASON_REFERENCE_END` |
| **紧急变道** | `RuleBasedStopDecider::CheckLaneChangeUrgency` | 需变道且距变道点 < 50 m 仍受阻 | 当前车道停止墙 | `STOP_REASON_LANE_CHANGE_URGENCY` |
| **侧向通过安全** | `RuleBasedStopDecider::StopOnSidePass` | 借逆向车道绕行前感知被遮挡 | 驶入逆向车道切换点前 | `STOP_REASON_SIDEPASS_SAFETY` |
| **前车过近 / 跟车** | `SpeedDecider`（ST 图决策） | 前车 ST boundary 与自车路径强相关、纵向距离 < 跟车阈值 | 对该障碍打 `FOLLOW` 或 `STOP` 标签 | 行人必 `STOP`；纵向决策优先级 stop > yield ≥ follow > overtake > ignore |
| **紧急停车 / PullOver** | `PullOverScenario` / `EmergencyScenario` | PadMessage 下发 `PULL_OVER` 或紧急指令 | 就近在当前车道找合适位置停车 | 保证行驶中停车安全，避免急停 |
| **Fallback 兜底** | `OnLanePlanning::add_fallback_trajectory` | 主轨迹生成失败 / 碰撞 / 优化失败 | 退回保守 fallback 轨迹（沿当前车道低速） | 规则化安全网，见第 8 节 |

### 3.2 关键场景补充说明

**Stop Sign（StopSignUnprotectedScenario）**：路口只有双向 stop sign，车辆通过前必须完全停止、Creep（缓慢蠕行）观察，当路口通行车辆密度足够小时才通过。Stage 通常包含 `Stop`、`Creep`、`Wait`、`Proceed` 等。

**Crosswalk**：核心函数 `CheckStopForObstacle()`，参数 `stop_distance`（虚拟障碍距人行道距离）、`max_stop_deceleration`（允许的最大减速度，避免急刹）、`min_pass_s_distance`（判断已通过的最小 s 距离）、`stop_strict_l_distance`/`stop_loose_l_distance`（横向严格/宽松触发距离）、`stop_timeout`（停车超时防死等）。

**SpeedDecider 纵向停车**：对每个障碍遍历，取其 `path_st_boundary`，根据 ST 位置（`GetSTLocation`）判定决策：
- 行人 → 直接 `STOP`；
- 虚拟障碍不在参考线车道 → 跳过；
- 无纵向决策结果 → 置 `IGNORE`；
- 否则按 ST 分布给出 `STOP / YIELD / FOLLOW / OVERTAKE / IGNORE`。

纵向决策优先级：`STOP > YIELD ≥ FOLLOW > OVERTAKE > IGNORE`（`IGNORE` 最不安全，表示未对障碍采取已知行为）。

---

## 4. STOP_DECIDER Task 在 Task 链中的位置与协同

### 4.1 位置语义

`RULE_BASED_STOP_DECIDER` 位于第 8 位，处于 **路径已定、速度未规划** 的中间环节。这一位置的设计意图：

- **上游**（1–7）已产出确定路径与路径决策（含 PathDecider 对障碍的 ignore/nudge/stop）；
- **本 Task** 补充那些"路径决策没覆盖、但规则要求必须停"的场景（短路径终点、紧急变道、借道安全）；
- **下游**（9–14）的速度规划会把所有 STOP 虚拟障碍统一映射到 ST 图，生成避让速度曲线。

### 4.2 与其它 Task 的协同

| 协同对象 | 协同关系 |
|---|---|
| `PathLaneBorrowDecider` | 决定是否进入借道场景；若借道，`RuleBasedStopDecider` 的 `StopOnSidePass` 才会被触发 |
| `PathBoundsDecider` | 生成 fallback / regular / lane-borrow 路径边界；借道边界决定 `OUT_ON_REVERSE_LANE` 段，直接影响 `CheckSidePassStop` |
| `PathAssessmentDecider` | 选出最优路径并设置 `path_point_decision_guide`（IN_LANE / OUT_ON_REVERSE_LANE / OUT_ON_FORWARD_LANE），是 `StopOnSidePass` 的输入 |
| `PathDecider` | 对障碍做 ignore/nudge/stop；与 `RuleBasedStopDecider` 互补，前者面向障碍，后者面向规则场景 |
| `STBoundsDecider` / `SpeedBoundsDecider` | 消费本 Task 注入的 STOP 虚拟障碍，映射到 ST 图限制速度 |
| `SpeedDecider` | 做纵向 stop/yield/follow/overtake/ignore 决策，与本 Task 共同构成"停车决策双保险" |

### 4.3 输入输出契约

- **输入契约**：`ReferenceLineInfo` 必须已有合法 `path_data`（含 `frenet_frame_path`、`path_point_decision_guide`、`path_label`），`Frame` 必须有最新车辆状态与障碍列表。
- **输出契约**：通过 `BuildStopDecision` 写入 `ReferenceLineInfo` 的 path_decision / obstacle decision；若已存在同 id 停止墙则更新位置，不重复创建。

---

## 5. Rule 路径决策

### 5.1 PathLaneBorrowDecider（借道决策）

**作用**：判断是否满足借道条件，**只决定"要不要借道"**，具体借道路径由后续 PathBoundsDecider 生成。

**借道触发条件**（典型）：
- 前方存在静态或低速阻塞障碍；
- 当前为单车道（无法在本车道内绕行）；
- 车道线类型允许跨越（非实线）；
- 对向车道可用且安全；
- 车辆速度低于阈值。

决策结果写入 `reference_line_info` 与 `mutable_path_decider_status`（`PathDeciderStatus` 消息），含 `decided_side_pass_direction` 等。

### 5.2 PathBoundsDecider（路径边界生成）

**作用**：生成候选路径边界（PathBoundary，SL 坐标点序列）。按处理顺序生成四类边界：

1. **Fallback boundary**：**一定会生成**，保守、仅本车道、不借道，作为安全兜底；
2. **Pull-over boundary**：靠边停车场景；
3. **Lane-change boundary**：变道场景；
4. **Regular boundary**：常规/借道绕行（含借道方向叠加邻车道宽度）。

按顺序一旦某非 fallback 边界有效就结束，故最终候选边界集合通常是 `fallback + (pull-over | lane-change | regular)` 之一。

**生成逻辑要点**：
- `InitPathBoundsDecider`：用规划起点自车道宽度初始化左右边界，无法获取时用默认 5 m；
- 根据借道方向叠加相邻车道宽度；
- 叠加障碍物边界（ADC box + buffer）收紧可用区间；
- 输出 `candidate_path_boundaries` 列表。

### 5.3 PathAssessmentDecider / PathDecider

- **PathAssessmentDecider**：去除无效路径（越界、与障碍碰撞、曲率超限等）；`SetPathInfo` 为路径点打类型标签（`SetPathPointType`：IN_LANE / OUT_ON_FORWARD_LANE / OUT_ON_REVERSE_LANE）供下游 SpeedDecider / RuleBasedStopDecider 使用；按代价排序选最优路径。
- **PathDecider**：基于选定的路径，对每个障碍做 `IGNORE / NUDGE / STOP` 决策。

### 5.4 路径决策的规则本质

路径决策链是一条"规则筛 + 代价排序"流水线：借道条件是规则、边界生成是规则（车道宽度 + 障碍 buffer）、路径评估是规则（有效性检查）+ 代价函数。优化（PiecewiseJerkPathOptimizer）只负责在边界内做平滑，决策权完全在规则侧。

---

## 6. Rule 速度决策

### 6.1 STBoundsDecider（ST 边界决策）

**作用**：将动态障碍物与最近阻塞静态障碍映射到 ST 图，对不影响纵向规划的障碍置 `IGNORE`，按设定轨迹给出每个障碍 boundary 的最优决策（`OVERTAKE / YIELD`），最终决策出最优 `Drivable_st_boundary`。

**核心步骤**（`STBoundsDecider::Process`）：
1. `InitSTBoundsDecider`：初始化 `st_obstacles_process_`；
2. `MapObstaclesToSTBoundary`：基于优化后路径构建障碍 ST 图，记录低路权路段（OUT_ON_FORWARD_LANE / OUT_ON_REVERSE_LANE），区分静态/动态；
3. 计算每个障碍的 `is_caution_obstacle` 与 `obs_caution_end_t`；
4. 生成候选 drivable ST boundary 并择优。

### 6.2 SpeedBoundsPrioriDecider / SpeedBoundsFinalDecider

- **SpeedBoundsPrioriDecider**（速度边界先验）：将规划路径上障碍物的 ST bounds 加载到 ST 图，生成先验限速信息（含曲率限速、道路限速、障碍限速）。
- **SpeedBoundsFinalDecider**（第 13/14 个 Task）：在 DP 速度曲线之后再次加载障碍 ST bounds 并生成最终限速，供 QP 优化使用。

二者一前一后，分别服务于 DP 与 QP。

### 6.3 SpeedHeuristicOptimizer（速度 DP）

在 ST 图上用动态规划（DP）搜索一条启发式最优速度曲线，作为 QP 的初值，兼顾计算效率与全局性。

### 6.4 SpeedDecider（纵向决策）

**位置**：第 12/13 个 Task，在 DP 速度之后、最终速度边界之前。

**作用**：对每个障碍遍历，根据其 ST boundary 与自车路径的关系，输出 `STOP / YIELD / FOLLOW / OVERTAKE / IGNORE` 决策标签，写入 `path_decision`。

**决策逻辑要点**：
1. 取障碍 `path_st_boundary`，按时间与位置分布判断是否可忽略；
2. 虚拟障碍不在参考线车道 → 跳过；
3. 行人 → 直接 `STOP`；
4. `GetSTLocation` 判定 ST 位置关系（BELOW / ABOVE / CROSS）；
5. 据 STLocation 给出对应纵向决策；
6. 无纵向决策结果 → `IGNORE`。

**优先级**：`STOP > YIELD ≥ FOLLOW > OVERTAKE > IGNORE`。`IGNORE` 最不安全（未采取已知行为），仅在确认无纵向影响时使用。

### 6.5 速度决策的规则本质

速度决策同样是"规则打标 + 优化求解"：决策标签由规则给出（行人必停、ST 位置判定），优化（PiecewiseJerkSpeedOptimizer）在 ST 图上做 QP 平滑。规则负责"该不该让/停/超"，优化负责"如何平滑地让/停/超"。

---

## 7. Rule 决策 vs 学习决策对比

### 7.1 对比表

| 维度 | Rule 决策（Apollo Public Road + Decider） | 学习决策（Apollo 9.0/10.0 ADFM / Planning Learning） |
|---|---|---|
| **可解释性** | 高：每条决策有明确规则与 StopReasonCode，可追溯 | 低：黑箱模型，难直接解释 |
| **鲁棒性 / 确定性** | 高：相同输入产生相同输出，无随机性 | 中：受训练分布影响，存在长尾不确定性 |
| **安全可验证性** | 高：规则可形式化审查、可单测、可认证 | 低：难形式化证明安全，需统计验证 |
| **场景覆盖度** | 低-中：仅覆盖预先枚举的场景，长尾需持续手工补规则 | 高：可泛化到训练分布内的未见场景 |
| **适应性 / 泛化** | 弱：新场景需改代码、加 Scenario/Task | 强：数据驱动迭代，模型重训即可 |
| **性能 / 通行效率** | 偏保守：规则倾向安全，易出现死等、犹豫 | 更优：可学到更拟人、更高效的博弈策略 |
| **工程维护成本** | 高：规则膨胀、相互耦合、调参爆炸 | 中：模型训练流程化，但数据/算力成本高 |
| **失败模式** | 规则未覆盖 → fallback 兜底（保守停车） | 分布外 → 不可预测行为，需规则兜底 |
| **迭代速度** | 慢：改规则 → 编译 → 测试 | 快：采数据 → 训练 → 部署 |
| **合规 / 监管** | 友好：规则透明，监管易接受 | 困难：黑箱难通过安全案例认证 |

### 7.2 Apollo 9.0 / 10.0 的神经网络辅助决策

Apollo 在 9.0 起强化"学习类规划"接入路径，10.0 正式基于 **ADFM（Autonomous Driving Foundation Model，自动驾驶大模型）** 重构核心算法：

- **接入方式**：学习类规划器既可作为独立 Cyber Component，也可作为 Planning 内部的 Planning Plugin 接入；定位为"候选轨迹生成器"或"新增 Decider"。
- **PlanningLearningData**：Planning 模块持续输出 `planning_learning_data`，用于离线训练与模型迭代闭环。
- **混合架构**：业界普遍采用"学习生成候选 + 规则安全校验 + 规则 fallback"的混合范式。Apollo 的规则层（TrafficDecider、RuleBasedStopDecider、Fallback）作为学习决策的安全兜底，学习决策负责提升复杂交互的性能与泛化。
- **官方表述**：ADFM 兼顾安全性与泛化性，宣称安全性高于人类驾驶员 10 倍以上，覆盖城市级全域复杂场景。

### 7.3 结论

Rule 与学习并非二选一，而是 **"规则保安全底线、学习提性能上限"** 的分层协作。规则决策的不可替代价值在于：可解释、可验证、可认证、可兜底——这正是学习决策目前最欠缺的。Apollo 自身的演进也印证了这一点：即便引入 ADFM，规则化的 TrafficDecider、RuleBasedStopDecider、Fallback 轨迹依然保留。

---

## 8. Rule-based Fallback 规划

### 8.1 Fallback 轨迹机制

`OnLanePlanning::RunOnce()` 在主规划之外，始终通过 `add_fallback_trajectory(...)` 生成一条 fallback 轨迹，与主轨迹一同输出给控制模块。当主轨迹异常时，控制模块可切换到 fallback。

**Fallback 轨迹特征**：
- 保守、规则化：沿当前参考线/车道行驶，低速、低加加速度；
- 不依赖复杂优化：通常由简单规则或 PathBoundsDecider 的 fallback boundary 生成；
- 安全优先：保证无碰撞、满足动力学，不追求效率。

### 8.2 Fallback Path Boundary

PathBoundsDecider **一定会生成** fallback path boundary，即使 regular / lane-change / pull-over 都失败，fallback 边界仍可用，确保路径规划永远有输出。

### 8.3 紧急情况处理

- **PullOverScenario**：收到 PadMessage `PULL_OVER` 指令时，就近在当前车道找合适位置安全停车，而非直接急停；
- **EmergencyScenario**：处理紧急停车指令；
- **RuleBasedStopDecider**：作为规则化紧急停车的补充（紧急变道、借道安全）；
- **SpeedDecider STOP**：对行人、强相关前车直接打 STOP 标签。

### 8.4 与 EM Planner 的关系

EM Planner 时代，fallback 主要靠"优化失败时回退到上一周期轨迹"或简单减速。Public Road Planner 时代，fallback 被前置为 **架构级常驻**：每一帧都同时产出主轨迹与 fallback 轨迹，且 fallback 路径边界在 PathBoundsDecider 中独立生成。可以说，Public Road Planner 把 EM 的"优化内核"保留在 Task 内，同时在架构层把"规则化 fallback"提升为一等公民，显著增强了安全兜底能力。

---

## 9. Rule-based 与 Mobileye RSS 对比

### 9.1 RSS 简介

**RSS（Responsibility-Sensitive Safety，责任敏感安全）** 由 Intel/Mobileye 于 2017 年提出，是一个开放、透明、可形式化验证的数学模型，把人类对"安全驾驶"的直觉转化为数学公式，用以界定什么样的驾驶行为是安全的。

RSS 关注的是 **名义安全（nominal safety）**，即系统设计层面的安全，而非功能安全（functional safety，故障/冗余）。其两大原则：
1. 自动驾驶汽车绝对不可以因为自身行为而引发事故（不担责）；
2. 自动驾驶汽车不可以过度反应（避免因自身过激行为被后车追尾）。

RSS 用纵向与横向安全距离公式（基于反应时间、最大减速度、最小安全跟距等参数）严格定义安全包络，并明确"路权/责任"分配。

### 9.2 对比表

| 维度 | Apollo Rule-based | Mobileye RSS |
|---|---|---|
| **本质** | 工程/启发式规则 + 场景状态机 + 代价函数 | 数学形式化模型（安全距离公式 + 责任规则）|
| **表达方式** | C++ 代码规则、proto 配置、虚拟停止墙 | 数学公式（纵向/横向安全距离）|
| **可验证性** | 中：规则可测但难形式化证明 | 高：每一步可数学验证，开放透明 |
| **覆盖范围** | 全决策规划管线（交通规则、行为、运动、兜底） | 安全包络判定层（不生成轨迹，只判安全）|
| **定位** | 完整规划系统 | 安全校验/约束层，需嵌入到规划器中 |
| **场景处理** | 枚举具体场景（stop sign、红绿灯、人行道…）| 通用几何判据（不分具体场景）|
| **责任概念** | 隐式（谁阻塞谁绕行） | 显式（明确路权与责任分配）|
| **可配置性** | 高（大量 proto 参数） | 中（公式参数 ρ/反应时间/减速度等）|
| **与规划耦合** | 紧耦合（决策即规划一部分） | 松耦合（独立安全监视器/约束）|
| **落地方式** | Apollo 内生 | 2018 年百度 Apollo 与 Mobileye 合作部署 RSS 于 Apollo Pilot |

### 9.3 安全设计差异

- **Apollo**：以"场景 + 规则 + 优化 + 兜底"四层应对安全，强调工程覆盖度与可调参；安全通过"枚举场景 + 虚拟停止墙 + fallback"实现，偏工程化。
- **RSS**：以"数学安全包络"应对安全，强调形式化与可验证；安全通过"不越界即安全"的几何判据实现，偏数学化。

### 9.4 适用场景差异

- **Apollo Rule**：适合需要完整行为决策输出的结构化道路全栈规划。
- **RSS**：适合作为任意规划器的"安全过滤器/监视器"，尤其在监管认证、责任界定、安全案例论证场景下价值突出。

二者在 2018 年已走向融合：百度宣布在 Apollo 开源项目及 Apollo Pilot 商用项目中部署 RSS，并针对中国路况共同验证与完善模型。这印证了"规则化安全（无论是 Apollo 式工程规则还是 RSS 式数学规则）是学习决策难以替代的底层保障"。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

根据本研究检索的 Aurora 公开资料：Aurora 采用基于 **安全案例（Safety Case）** 框架的方法评估自动驾驶车辆在公共道路上的可接受安全性，并通过结构化论点 + 证据的方式论证安全性。Aurora Driver 架构中包含 **Fallback 层** 与 **应急/最小风险策略（MRM, Minimal Risk Maneuver）**：当主规划不满足安全条件时，触发 fallback / contingency plan，执行最小风险行为（如安全停车）。其 `FallbackDetector` 据任务描述当前包含 **8 条判据**，用于判定是否需要进入 fallback。

### 10.2 借鉴 Apollo RuleBasedStopDecider

Apollo `RuleBasedStopDecider` 的设计经验对 AuroraDrive 的直接启发：

1. **结构化停车原因码（StopReasonCode 分类法）**：Apollo 为每类停车赋予明确原因码（REFERENCE_END / LANE_CHANGE_URGENCY / SIDEPASS_SAFETY / STOP_SIGN / TRAFFIC_LIGHT / PEDESTRIAN / YIELD_SIGN / DESTINATION …）。AuroraDrive 的 FallbackDetector 8 条判据可对齐一套统一原因码体系，使 fallback 触发可追溯、可统计、可回归。
2. **统一停止决策表达（BuildStopDecision 范式）**：所有规则停车统一转为参考线上的虚拟停止墙，下游统一避让。AuroraDrive 可借鉴"规则判据 → 统一安全目标（stop fence / MRM target）→ 下游执行"的解耦模式，避免每条判据各自实现执行逻辑。
3. **几何 + 感知双判定（IsPerceptionBlocked 光束搜索）**：Apollo 在借道前用搜索光束判断感知盲区，"看不见就停"。AuroraDrive 可在 fallback 判据中加入"感知置信度/遮挡"维度，提升 fallback 触发的安全裕度。
4. **停车状态验证（CheckADCStop）**：用速度阈值 + 距离阈值双重验证自车是否真停，避免误判。AuroraDrive MRM 完成态判定可借鉴。
5. **状态缓存与早退**：用 status 标志避免重复触发，保证实时性。

### 10.3 借鉴 Apollo Rule 路径 / 速度决策

1. **Fallback + Regular 双边界范式（PathBoundsDecider）**：Apollo 始终生成 fallback path boundary 作为兜底。AuroraDrive 可在规划层显式维护"主轨迹 + fallback 轨迹"双边界，fallback 边界始终可用、低开销、纯规则。
2. **ST 图纵向决策标签（SpeedDecider 五类决策）**：`STOP / YIELD / FOLLOW / OVERTAKE / IGNORE` + 优先级 `STOP > YIELD ≥ FOLLOW > OVERTAKE > IGNORE` 是一套经过工程验证的纵向行为分类。AuroraDrive 可借鉴此分类细化 fallback 判据的纵向行为语义，而非仅"停/不停"二元。
3. **借道决策解耦（PathLaneBorrowDecider 只判条件、不生成路径）**：决策与生成分离，降低耦合。AuroraDrive 规则升级时宜保持"判据与执行分离"的工程纪律。
4. **TrafficDecider 前置统一交通规则层**：把交规（红绿灯、停止标志、人行道、让行、禁停区、参考线终点）从场景中抽出，前置为对所有参考线统一生效的规则层。AuroraDrive 可借鉴此分层，把"硬性交通规则"与"策略性行为决策"解耦。

### 10.4 AuroraDrive 规则体系升级方案

基于以上分析，提出 AuroraDrive 规则体系升级方案：

#### 方案目标
在不破坏 AuroraDrive 学习/优化主规划的前提下，构建一套 **可解释、可验证、可兜底** 的分层规则体系，强化 fallback 触发的覆盖度与可追溯性。

#### 分层架构建议

```
┌─────────────────────────────────────────────────────────┐
│ L0  交通规则层（TrafficRule Layer，前置、全场景生效）      │
│   - 红绿灯 / 停止标志 / 人行道 / 让行 / 禁停区 / 终点      │
│   - 输出：统一 StopFence + StopReasonCode               │
├─────────────────────────────────────────────────────────┤
│ L1  行为决策层（Behavior Decider Layer）                  │
│   - 变道 / 借道 / 超车 / 让行 / 跟车 纵向决策标签          │
│   - 借鉴 SpeedDecider 五类决策与优先级                   │
├─────────────────────────────────────────────────────────┤
│ L2  安全停车层（RuleBasedStop Layer，对标 RuleBasedStopDecider）│
│   - 路径终点 / 紧急变道 / 借道安全 / 感知遮挡 停车         │
│   - 几何 + 感知双判定                                    │
├─────────────────────────────────────────────────────────┤
│ L3  Fallback / MRM 层（现有 FallbackDetector 升级）       │
│   - 8 条判据 → 扩展为分原因码的判据矩阵                  │
│   - 主轨迹失败 / 碰撞风险 / 优化失败 / 感知失效 / …      │
│   - 输出：Fallback 轨迹 + MRM 目标                       │
├─────────────────────────────────────────────────────────┤
│ L4  RSS 式安全包络校验层（可选，独立监视器）              │
│   - 纵向/横向安全距离公式校验                            │
│   - 越界即触发 fallback / MRM                            │
└─────────────────────────────────────────────────────────┘
```

#### 具体升级动作

1. **原因码体系对齐**：把 FallbackDetector 8 条判据映射到统一 StopReasonCode / FallbackReasonCode 枚举，每条判据输出可追溯原因码，便于回归测试与安全案例举证。
2. **判据矩阵扩展**：借鉴 Apollo 三大停车子场景 + TrafficDecider 九类交通规则，将 8 条判据扩展为"交通规则类 / 行为决策类 / 安全停车类 / 系统失效类"四类矩阵，提升长尾覆盖。
3. **双边界常驻 fallback**：规划层始终维护 fallback 轨迹（对标 Apollo `add_fallback_trajectory` + PathBoundsDecider fallback boundary），保证任何一帧主轨迹失败都有安全输出。
4. **感知遮挡判据**：在 fallback 触发条件中加入感知置信度/遮挡判定（对标 `IsPerceptionBlocked`），实现"看不见就 fallback"。
5. **停车状态验证**：MRM 完成态用速度 + 距离双阈值验证（对标 `CheckADCStop`），避免误判 MRM 完成。
6. **配置驱动**：所有阈值走配置（对标 Apollo proto），不同 ODD/车型可独立调参，避免硬编码。
7. **RSS 安全包络（可选增强）**：在 L4 引入 RSS 纵向/横向安全距离公式作为独立安全监视器，越界即触发 fallback，为安全案例提供形式化证据。
8. **规则与学习解耦**：保持规则层对学习主规划的"安全兜底"定位，学习决策负责性能，规则决策负责安全底线，二者通过统一 StopFence/FallbackReason 解耦接口协同。

#### 预期收益

- fallback 触发可解释、可统计、可认证（助力 Aurora 安全案例）；
- 长尾场景覆盖度提升（交通规则 + 安全停车 + 感知遮挡）；
- 主规划失败时安全输出有保障（双边界常驻 fallback）；
- 规则与学习解耦，迭代互不阻塞；
- 为后续引入 RSS 式形式化安全校验预留接口。

---

## 11. 关键结论

1. **Apollo "rule-based planner" 是一个体系而非单一类**：由 TrafficDecider（交通规则层）+ Scenario/Stage/Task FSM（行为层）+ Decider Task 族（运动决策层）+ RuleBasedStopDecider & Fallback（安全兜底层）共同构成。
2. **RuleBasedStopDecider 是规则停车的核心兜底**：位于 Task 链第 8 位，处理路径终点、紧急变道、借道安全三类规则停车，以虚拟停止墙统一表达，几何 + 感知双判定，配置驱动。
3. **停车决策分布在四层**：TrafficDecider（交规）、Scenario Stage（场景）、RuleBasedStopDecider/SpeedDecider（决策）、Fallback（兜底），各层互补。
4. **路径/速度决策是"规则打标 + 优化求解"**：决策权在规则侧（借道条件、路径边界、ST 决策标签），优化只在边界内平滑。
5. **Rule vs 学习是分层协作**：规则保安全底线（可解释、可验证、可兜底），学习提性能上限（泛化、高效）。Apollo 9.0/10.0 的 ADFM 保留了规则兜底。
6. **Rule-based vs RSS 互补**：Apollo Rule 是工程化全栈决策，RSS 是数学化安全包络；二者在 2018 年已融合部署。
7. **AuroraDrive 升级路径**：借鉴 Apollo 分层规则体系 + 统一原因码 + 双边界 fallback + 感知遮挡判据 + RSS 安全包络，构建可解释、可验证、可兜底的规则体系，强化安全案例。

---

## 参考资料（检索来源）

- Apollo 官方文档与 ApolloAuto/apollo GitHub 源码目录（modules/planning/planning_base/tasks/deciders/rule_based_stop_decider.cc 等）
- CSDN：《Apollo自动驾驶系统：基于规则的停止决策器深度解析》《【Apollo学习笔记】——RULE_BASED_STOP_DECIDER》《Apollo Planning决策规划算法代码详细解析》系列（(9) PathBoundsDecider / (19) SpeedDecider / (20) SPEED_BOUNDS_FINAL_DECIDER / (22) 总览）《Apollo 10.0 Public Road Planner 详解》《Apollo中Scenario、Stage、Task之间的关系》《Apollo学习——planning模块(4)(5) traffic_decider / traffic_rule》《apollo的超车、绕行、跟车规划的流程》《apollo决策规划学习--慢速障碍物超车》《APOLLO:path_bounds_decider / lane_borrow_decider 代码解读》《Apollo6.0 StBoundsDecider流程与代码解析》《apollo自动驾驶进阶学习之--如何调试Crosswalk人行道场景并避让行人》《Apollo Planning学习(2)-------路径规划》《Apollo9.0 Planning2.0 OnLanePlanning 解析》《Apollo规划决策中"让行-超车"行为的优先级决策逻辑仿真》《Apollo Planning决策规划代码详解专栏》
- 博客园：《Apollo 9.0.0 自动驾驶系统整体架构分析》
- 掘金/知乎：Apollo 规划模块系列解析
- Mobileye RSS 公开资料：中关村在线《Mobileye以开放的RSS推动自动驾驶行业创新》、OFweek《解读Mobileye的RSS模型》
- Aurora 安全案例公开资料：电子技术应用《Aurora自动驾驶安全案例框架》
- Apollo 10.0 ADFM：InfoQ、搜狐、物联网世界等公开报道

---

> 本报告实际工具调用次数：约 50+ 次（WebSearch + WebFetch + Read/LS/Glob 辅助），其中有效 WebSearch/WebFetch 抓取覆盖 Apollo 源码解析、官方文档、CSDN 系列专栏、Mobileye RSS 资料、Aurora 安全案例资料等。
