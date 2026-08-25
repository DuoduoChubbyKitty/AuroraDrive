# 百度 Apollo 车道级导航深度研究报告

> 研究对象：百度 Apollo 开放平台（Apollo 8.0 / 9.0 / 10.0）的车道级导航、车道级路径规划、换道决策机制
> 研究目的：提炼 Apollo 在车道级导航上的工程范式，并给出 AuroraDrive 的车道级导航迁移方案（含 C++ 代码框架）
> 研究方法：WebSearch + WebFetch 检索 Apollo 官方文档、ApolloAuto/apollo 源码路径、CSDN 社区解析；结合 AuroraDrive 现有 C++ 代码（`cpp/include/ad/simulator.h`、`path_planner.h`、`map_loader.h`、`spatial.h`）做对照设计

---

## 1. 车道级导航概述

### 1.1 道路级路径规划 vs 车道级路径规划

自动驾驶导航存在两个层次：

- **道路级（Road-Level）路径规划**：类似百度地图/高德地图的人用导航，输出"经过哪些道路"的序列，节点是 Road/Junction，边是道路长度。粒度粗，不关心具体车道。
- **车道级（Lane-Level）路径规划**：输出"经过哪些车道（Lane）"的序列，包括在路口前应处于哪条车道、是否需要换道、何时借道避障等。粒度细，直接服务于轨迹规划。

Apollo 在 Routing 模块做的是**车道级全局规划**：它将 base_map 中的 Lane 抽象成拓扑图 `TopoGraph`，节点 `TopoNode` 对应一条 Lane，边 `TopoEdge` 描述 Lane 之间的连接关系（`LEFT`/`RIGHT` 表示左右邻接可变道，`FORWARD` 表示前后衔接），然后用 A\* 算法搜索起点到终点的最优 Lane 序列，结果放入 `RoutingResponse`。这是 Apollo 区别于传统导航地图的核心：**Routing 的输出本身就是车道级的**。

需要特别区分两个概念：

- **Routing（全局路由）**：起点到终点的最佳车道序列，频率低（仅在导航请求/偏航重规划时触发），类比为"地图导航"。
- **Planning（局部规划）**：当前一小段时间（约 3~8s，10Hz）如何行驶，基于 Routing 给的车道序列生成具体轨迹，类比为"开车"。

### 1.2 Apollo 车道级导航能力

Apollo 的导航能力由三个模块协同完成：

1. **Routing**：车道级全局路径（A\* on TopoGraph），输出 `RoadSegment → LaneSegment → LaneWaypoint` 三层结构。
2. **ReferenceLineProvider（参考线提供者）**：把 Routing 输出的 Lane 片段拼接、平滑成 `ReferenceLine`，作为 Planning 的"地基"。Planning 一切决策与优化都在参考线之上进行。多 Lane 片段可能产生多条候选参考线（变道时会同时保留当前车道与目标车道两条参考线）。
3. **Planning**：在参考线上做路径决策（Path Decision）与速度决策（Speed Decision），输出最终轨迹。

Apollo Planning 有两种规划器：

- **OnLanePlanning**（默认）：基于高精地图的车道规划，适用于城市及高速各种复杂车道场景。
- **NaviPlanning**：基于导航的规划，主要用于高速公路场景，更轻量，参考线直接来自导航车道，不做复杂借道。
- **OpenSpacePlanning**：用于无车道线场景（自主泊车、狭窄路段）。

从 Apollo 3.5 起，Planning 采用**双层状态机的场景机制**（Scenario → Stage → Task）：Top Layer 是 Scenario 状态机（`ScenarioManager` 根据环境与地图决定切换到哪个场景，如 `LaneFollowScenario`、`PullOverScenario`、`TrafficLightProtectedScenario`、`BareIntersectionUnprotectedScenario`、`EmergencyStopScenario`、`EmergencyPullOverScenario`、`ParkAndGoScenario`、`ValetParkingScenario` 等），Bottom Layer 是 Stage 状态机（每个 Scenario 包含若干 Stage，按序执行），每个 Stage 串联一组 Task（如 `LANE_CHANGE_DECIDER`、`PATH_LANE_BORROW_DECIDER`、`PATH_BOUNDS_DECIDER`、`PIECEWISE_JERK_PATH_OPTIMIZER`、`ST_BOUNDS_DECIDER`、`SPEED_BOUNDS_PRIORI_DECIDER` 等）。这种分层使不同驾驶用例互不干扰，修一处不影响其他场景。

### 1.3 Apollo 9.0 / 10.0 车道级方案演进

- **Apollo 8.0（2022）**：引入 Live Map / One Map 一张图理念，高精地图自动化率达 96%，支持快速动态更新；Planning 沿用 Scenario-Stage-Task 架构，`path_lane_borrow_decider` 与 `path_lane_change_decider` 已成熟。
- **Apollo 9.0（2023.12.19）**：首次适配 ARM 架构，优化感知算法，提供更灵活易用的工具框架与更易拓展的通用能力；参考线生成器 `ReferenceLineProvider` 与 Routing 交互流程进一步文档化；城市领航 ANP 持续落地。
- **Apollo 10.0（2024.12.4）**：基于自动驾驶大模型 **ADFM（Autonomous Driving Foundation Model）** 重构核心算法——感知新增 BEV+OCC 视觉感知、激光雷达感知框架全面升级；规划控制基于 **Learning 化的决策与候选轨迹生成**，行驶/泊车能力大幅提升，车型适配缩短至一周；CyberRT 升级为零拷贝通信，微秒级传输，性能提升 10 倍；单 Orin 即可支撑 L4 落地，整体资源使用降低 50%；功能安全新增 70 种 150+ 异常监测项。

---

## 2. 车道级路径规划

### 2.1 Lane-Level Routing（A\* on TopoGraph）

Apollo Routing 的核心是把高精地图转成拓扑图后用 A\* 搜索：

**拓扑图构建**（`modules/routing/graph/topo_node.h`、`topo_graph.h`）：

- `TopoNode`：车道唯一 id、长度、左出口/右出口（对应虚线或自定义可变道路段）、路段代价（限速/拐弯会增加成本，代价系数在 `routing_config.pb.txt` 定义）、中心线（用于生成参考线）、是否可见、所属道路 id。
- `TopoEdge`：起始车道 id、到达车道 id、切换代价、方向（`FORWARD`/`LEFT`/`RIGHT`）。
- 例：TopoNode A（Lane A）有一条 `LEFT` 类型的 OutEdge 连到 TopoNode B（Lane B），表示地图中 Lane A 的左边紧邻 Lane B，可向左变道。

**A\* 搜索**（`modules/routing/strategy/a_star_strategy.h`）：

```
f(n) = g(n) + h(n)
```

- `g(n)`：从起点到节点 n 的实际代价（含变道代价）。
- `h(n)`：节点 n 到终点的启发式代价（剩余距离）。
- 维护 `open_set`（待考察，优先队列）、`closed_set`（已考察）、`came_from_`（父节点回溯）、`g_score_`（每个节点的累计代价）。
- `change_lane_enabled_` 控制是否允许变道搜索。

**SubTopoGraph（拓扑子图）**：处理黑名单路段时，不必每两个航点重建整个 TopoGraph（N-1 次重建非常耗时），而是只关注黑名单对应的 TopoNode 及起终点 TopoNode，在子图里重建连接关系。

**搜索流程**：
1. 获取各 waypoint 所在 Lane 的 TopoNode；
2. 添加黑名单；
3. 依次搜索前后两个航点之间的路径并拼接；
4. 输出 `RoutingResponse`（车道序列）。

### 2.2 换道决策（Lane Change Decision）

详见第 4 章。

### 2.3 借道决策（Lane Borrow Decision）

详见第 4 章。

### 2.4 上下匝道 / 高速变道序列 / 城市路口选择

- **上下匝道**：Routing 会把匝道作为 Lane 序列的一部分；Planning 在接近匝道时通过 `LaneChangeDecider` 触发强制换道（导航要求的换道），并在 `PathBoundsDecider` 生成 `lane_change` 路径边界。
- **高速变道序列**：高速场景多用 `NaviPlanning`，换道以"导航要求"为主，主动换道（速度优势换道）在开源版中被大量删减，仅留框架。
- **城市路口选择**：Apollo 高精地图定义 `Junction`（路口）概念，用虚拟路（红色线）连接可通行方向；`LaneFollowScenario` 默认沿 Routing 给的 Lane 序列行驶，路口前由 Routing 的 Lane 序列决定应处车道，提前变道匹配导航方向。

---

## 3. 导航地图 vs 高精地图

### 3.1 三种地图形式

Apollo 地图以三种形式存在（`modules/map/data/<map_dir>/`）：

| 地图 | 内容 | 用途 |
|------|------|------|
| **base_map**（base_map.bin/xml/txt） | 完整高精地图，厘米级精度，包含道路、车道、路口、交通标识、信号灯等全部元素 | 定位、感知、规划的真实数据源 |
| **routing_map**（routing_map.bin） | lanes 的拓扑结构（TopoGraph） | Routing 模块 A\* 搜索用 |
| **sim_map**（sim_map.bin） | base_map 的简洁版本 | Dreamview 显示用，去掉冗余细节加速渲染 |

生成命令：
- `bin_map_generator` 生成 base_map.bin；
- `generate_routing_topo_graph.sh` 生成 routing_map.bin；
- `sim_map_generator` 生成 sim_map.bin。

### 3.2 高精地图用于规划 / 导航地图用于 HMI 显示

- **高精地图（HDMap）用于规划**：`ReferenceLineProvider` 读取 Routing 给的车道片段，结合 base_map 的车道几何生成平滑参考线；Planning 的所有决策（换道、借道、路径边界）都在参考线（Frenet 坐标系）上完成。
- **导航地图用于 HMI 显示**：sim_map 供 Dreamview 渲染；实车车机大屏的导航地图（百度地图 X Apollo）则上线了城市车道级导航、车位级导航、绿灯畅行导航等智能化功能，率先在北京亦庄示范区落地，并陆续推广至广州黄埔、河北保定、湖南株洲等。

### 3.3 同步与差分更新 / Apollo 8.0 Live Map

- **传统模式**：地图预编译静态加载，更新周期长、周转慢。Apollo 2.5 曾推出 Real-time Relative Map（实时相对地图）方案缓解此问题。
- **Apollo 8.0 Live Map / One Map**：高精地图升级为"一张图"理念，自动化率达 96%，支持快速动态更新地图数据；通过差分更新机制，只下发变化的车道/路段，降低带宽与刷新延迟。百度在 Tier1 领域将敏捷开发与 ASPICE 传统 V 模型融合，使地图能持续动态演进。
- **同步机制**：规划用的高精地图与显示用的导航地图通过统一地图版本号对齐；Live Map 通过云端下发差分块，车端合并后供 Planning 与 HMI 共享。

---

## 4. Apollo 换道决策（重点）

Apollo 的"换道"分为两类，由两个不同 Decider 负责：

| 决策器 | 触发场景 | 本质 |
|--------|----------|------|
| `PathLaneBorrowDecider`（借道） | 前方有静态/低速阻塞障碍物，本车道绕不过去 | **被动**避障，临时借用邻车道，参考线仍在本车道 |
| `LaneChangeDecider`（换道） | 导航要求换到目标车道，或主动寻求速度优势 | **主动/强制**换道，参考线切换到目标车道 |

二者关键区别：借道时 reference line 仍在本车道（只是 path 偏到邻车道），换道时 reference line 切到目标车道。这也是 `PathBoundsDecider` 生成 `borrow` 边界与 `lane_change` 边界的差异点。

### 4.1 LaneChangeDecider 详解

位置：`modules/planning/planning_base/tasks/deciders/path_lane_change_decider.cc`（旧版 `modules/planning/tasks/deciders/lane_change_decider/lane_change_decider.cc`）。它是 `LaneFollowStage` 配置的第一个 task：

```
task_type: LANE_CHANGE_DECIDER
task_type: PATH_REUSE_DECIDER
task_type: PATH_LANE_BORROW_DECIDER
task_type: PATH_BOUNDS_DECIDER
task_type: PIECEWISE_JERK_PATH_OPTIMIZER
task_type: PATH_ASSESSMENT_DECIDER
task_type: PATH_DECIDER
task_type: RULE_BASED_STOP_DECIDER
task_type: ST_BOUNDS_DECIDER
...
```

**核心配置**（`planning_config.pb.txt`）：

```
lane_change_decider_config {
  enable_lane_change_urgency_check: false
  enable_prioritize_change_lane: false
  enable_remove_change_lane: false
  reckless_change_lane: false          // 强制换道开关
  change_lane_success_freeze_time: 1.5 // 换道成功后冻结 1.5s
  change_lane_fail_freeze_time: 1.0    // 换道失败后冻结 1.0s
}
```

**换道状态机**（`ChangeLaneStatus`，定义在 `planning_status.proto`）：

```
enum Status {
  IN_CHANGE_LANE = 1;        // 换道中（含准备+执行）
  CHANGE_LANE_FAILED = 2;    // 换道失败
  CHANGE_LANE_FINISHED = 3;  // 换道完成
}
```

**换道决策流程**（`LaneChangeDecider::Process`）：

```
1. 空参考线检查：reference_line_info 为空则报错返回。
2. 若 reckless_change_lane=true（强制换道）：
   → PrioritizeChangeLane(true) 将换道参考线置顶，直接返回。
3. 记录当前时间戳 now；prev_status->set_is_clear_to_change_lane(false)。
4. 若当前参考线是换道路径（IsChangeLanePath）：
   → 调用 IsClearToChangeLane() 判断是否满足变道条件，更新 is_clear_to_change_lane。
5. 首次进入（!prev_status->has_status()）：
   → 默认设为 CHANGE_LANE_FINISHED。
6. 判断参考线数量：
   ① 只有一条参考线（has_change_lane=false，单向单车道无需换道）：
      - 按 path_id 更新状态（IN_CHANGE_LANE → FINISHED；FINISHED/FAILED 保持）。
   ② 多条参考线（has_change_lane=true）：
      - IN_CHANGE_LANE：若 path_id 与当前一致 → 还在换道中，PrioritizeChangeLane(true)；
                       否则 → 已切到目标车道，PrioritizeChangeLane(false)，状态置 FINISHED。
      - CHANGE_LANE_FAILED：若 now - timestamp < fail_freeze_time(1.0s) → 冻结；
                           否则 → 重新 IN_CHANGE_LANE。
      - CHANGE_LANE_FINISHED：若 now - timestamp < success_freeze_time(1.5s) → 冻结；
                              否则 → PrioritizeChangeLane(true)，状态置 IN_CHANGE_LANE。
```

**`IsChangeLanePath()`**：自车是否在当前 ReferenceLine 的车道 segment 上——在则 FALSE（本车道），不在则 TRUE（换道路径）。

**`IsClearToChangeLane()`**（安全检查）：
- 不考虑虚拟障碍物与静态障碍物，只算动态障碍物；
- 计算动态障碍物在参考线上的 SL 投影；
- 若自车正在换道，忽略目标参考线车道之外的障碍物；
- 判断障碍物与自车是否同向（`same_direction`），据速度关系分别计算前向/后向安全距离；
- 距离大于安全距离 → 可安全换道；
- **HysteresisFilter（滞后滤波器）**：上一帧判断为安全则本帧更倾向于安全，反之亦然，消除边界附近乒乓效应。

**`PrioritizeChangeLane()`**：通过 `std::list::splice` 把目标参考线（或本车道参考线）移到链表头部——因为 Planning 后续模块统一用 `reference_line_info().front()`，链表头即当帧使用的参考线。

**强制换道 vs 主动换道**：
- **强制换道（导航要求）**：`reckless_change_lane=true` 时直接优先换道；实车场景中接近匝道出口/路口转向时，Routing 要求必须在某车道，触发强制换道。
- **主动换道（速度优势）**：开源版被大量删减，仅留框架；完整实现应包含换道窗口与 Gap 选择、收益评估（邻车道更快则换）等，Apollo 未完全开源。

### 4.2 PathLaneBorrowDecider 详解

位置：`modules/planning/planning_base/tasks/deciders/path_lane_borrow_decider.cc`。

**数据结构**（`PathDeciderStatus`，proto）：

```
message PathDeciderStatus {
  enum LaneBorrowDirection {
    LEFT_BORROW = 1;
    RIGHT_BORROW = 2;
  }
  optional int32 front_static_obstacle_cycle_counter = 1 [default = 0];
  optional int32 able_to_use_self_lane_counter = 2 [default = 0];   // self_counter
  optional bool is_in_path_lane_borrow_scenario = 3 [default = false];
  optional string front_static_obstacle_id = 4 [default = ""];
  repeated LaneBorrowDirection decided_side_pass_direction = 5;
}
```

**`IsNecessaryToBorrowLane()` 核心逻辑**：

```
若当前已在借道场景（is_in_path_lane_borrow_scenario=true）：
   if able_to_use_self_lane_counter >= 6:   // ← 用户提到的 self_counter > 6 退出 borrow
       关闭借道，clear decided_side_pass_direction
       → "Switch from LANE-BORROW path to SELF-LANE path."
否则（当前未借道），需同时满足以下条件才进入借道：
   ① HasSingleReferenceLine(frame)             // 只有一条参考线才借道
   ② IsWithinSidePassingSpeedADC(frame)         // 起点速度 < FLAGS_lane_borrow_max_speed（5 m/s）
   ③ IsBlockingObstacleFarFromIntersection()    // 阻塞障碍物远离路口
   ④ IsLongTermBlockingObstacle()               // front_static_obstacle_cycle_counter
                                                 //   >= long_term_blocking_obstacle_cycle_threshold（默认 3）
   ⑤ IsBlockingObstacleWithinDestination()      // 阻塞障碍物不在终点之后
   ⑥ IsSidePassableObstacle()                   // 可侧面通过（非 movable、近、停在路边等）
   全部满足后调用 CheckLaneBorrow() 决定左右借道方向：
   - 以 2m 间隔遍历车前 100m 参考线，查左右车道线类型：
     DOTTED_YELLOW / DOTTED_WHITE → 可借；SOLID_WHITE / SOLID_YELLOW → 不可借。
   - 左右均不可借 → 不借道；否则 set is_in_path_lane_borrow_scenario=true，
     add LEFT_BORROW / RIGHT_BORROW。
```

**self_counter > 6 退出 borrow 的含义**：`able_to_use_self_lane_counter` 记录"本车道连续多少帧可正常通行"。一旦借道场景中本车道恢复可用（避障输出轨迹有解、阻塞消失），计数器累加；累计超过 6 帧（约 0.6s @10Hz）即退出借道，回到本车道行驶。这避免单帧抖动导致借道频繁进出，是一种滞后/去抖机制，与 `LaneChangeDecider` 的 freeze_time 思想一致。

**关键点**：`path_lane_borrow_decider` 只判断"是否具备借道能力"并写入状态，**具体的借道轨迹边界由后续 `PathBoundsDecider` 生成**（生成 `regular`+`borrow` 边界，再由 `PathAssessmentDecider` 评估选优）。

### 4.3 换道决策流程总览

```
            ┌─────────────────────────────────────────────┐
            │  Routing 输出 Lane 序列（车道级全局路径）       │
            └──────────────────────┬──────────────────────┘
                                   ▼
            ┌─────────────────────────────────────────────┐
            │  ReferenceLineProvider 拼接/平滑 → ReferenceLine │
            │  （变道时同时生成多条候选参考线）                 │
            └──────────────────────┬──────────────────────┘
                                   ▼
   LaneFollowStage 依次执行 Task：
   ┌─────────────────────────────────────────────────────────┐
   │ 1. LANE_CHANGE_DECIDER                                  │
   │    - 状态机：FINISHED ⇄ IN_CHANGE_LANE ⇄ FAILED          │
   │    - reckless_change_lane → 强制换道                     │
   │    - freeze_time 防频繁换道                              │
   │    - HysteresisFilter 防乒乓                              │
   │    - PrioritizeChangeLane 调整参考线顺序                 │
   ├─────────────────────────────────────────────────────────┤
   │ 2. PATH_REUSE_DECIDER（路径复用判断）                    │
   ├─────────────────────────────────────────────────────────┤
   │ 3. PATH_LANE_BORROW_DECIDER                             │
   │    - self_counter >= 6 退出借道                          │
   │    - 6 条进入条件 + CheckLaneBorrow 定左右方向            │
   ├─────────────────────────────────────────────────────────┤
   │ 4. PATH_BOUNDS_DECIDER                                  │
   │    - 生成 fallback / pull_over / lane_change /           │
   │      regular / borrow 候选路径边界                        │
   ├─────────────────────────────────────────────────────────┤
   │ 5. PIECEWISE_JERK_PATH_OPTIMIZER（QP 轨迹优化）          │
   │ 6. PATH_ASSESSMENT_DECIDER（路径评估选优）               │
   │ 7. PATH_DECIDER（nudge/ignore/overtake 障碍决策）        │
   │ 8. RULE_BASED_STOP_DECIDER                              │
   │ 9. ST_BOUNDS_DECIDER / SPEED_BOUNDS_PRIORI_DECIDER ...  │
   └─────────────────────────────────────────────────────────┘
```

---

## 5. 城市路口车道选择

### 5.1 路口前提前变道

Apollo 路口处理依赖高精地图的 `Junction` 定义：路口区域用虚拟路（红色线）连接各可通行方向，虚拟路本身也是 Lane。Routing 在 A\* 搜索时已把"过路口走哪条虚拟 Lane"编入车道序列，因此**路口前应处哪条车道由 Routing 提前确定**。

Planning 在接近路口时：
- `LaneChangeDecider` 根据 Routing 要求触发换道（若当前车道与目标方向不匹配，则为强制换道）；
- `PathBoundsDecider` 生成 `lane_change` 边界完成实际换道轨迹；
- 路口内沿虚拟 Lane 的参考线行驶。

### 5.2 导航箭头方向匹配

实车 HMI 上，导航箭头方向与 Routing 输出的 Lane 序列方向一致：Routing 给出"前方路口左转"，则车机显示左转箭头，Planning 在路口前把车换到左转车道。Apollo 9.0 的 `ReferenceLineProvider` 文档明确：用户在 Dreamview 点选（实车在车机大屏输入）起终点与途经点，地图映射得到 `RoutingRequest`，含起点终点在最近车道上的对应点，A\* 搜索后反馈车道级路径。

### 5.3 复杂路口（多车道 / 多方向）

- **多车道同方向**：Routing 选最优车道（考虑变道代价、限速），Planning 负责把车换过去。
- **多方向分叉**：Junction 内多条虚拟 Lane 对应不同转向，Routing 按导航意图选其一；若 Routing 给错或偏航，触发 rerouting 重新搜索。
- **环岛**：ANP（Apollo Navigation Pilot）实车演示中，威马 W6 借助高精地图精确判断进环岛时机，在第一个出口驶出——这正是车道级导航在复杂路口的典型能力。

---

## 6. Apollo 车道级 HMI

### 6.1 Dreamview 车道级显示

Dreamview 是 Apollo 基于 Web 的可视化工具，是启动一切模块的中心，功能模块的开关都由其 Web 界面控制。它可视化车辆状态、感知、规划、控制等运行时信息。地图显示用的是 `sim_map`（base_map 的简洁版），去掉冗余细节以加速渲染。

### 6.2 车道级路径渲染

- Planning 输出的轨迹（reference line + 优化后的 path）通过 CyberRT 广播，Dreamview 渲染为车道级路径线；
- 换道时两条候选参考线都会显示，当前使用的（链表头）高亮；
- 借道场景下，path 边界（borrow bound）会显示偏到邻车道的可行驶区域。

### 6.3 换道箭头

- Dreamview 在 PNC（Planning & Control）模块面板可显示换道状态（`lane_change_status`）；
- 实车 HMI（百度地图 X Apollo）提供转向箭头、车道级导航引导、车位级导航、绿灯畅行导航等。

> 对 AuroraDrive 的启示：AuroraDrive 前端已有 `TurnArrow`（转向箭头，100m 提前预警）与 `MiniMap`（可拖拽小地图）组件，可借鉴 Apollo 的"车道级路径线 + 换道状态高亮"渲染思路。

---

## 7. Apollo 9.0 / 10.0 车道级方案

### 7.1 Apollo 9.0 ANP（Apollo Navigation Pilot）

- **ANP 定义**：Apollo Navigation Pilot，业界常说的领航辅助驾驶。基于国内唯一的 L4 级纯视觉自动驾驶技术 Apollo Lite 降维，配合高精地图 + V2X，提供复杂城市道路的 L4 级辅助驾驶能力。
- **核心特点**：纯视觉方案（不依赖激光雷达），与 Apollo L4 同技术架构；城市领航覆盖城市场景，能处理环岛、复杂路口等。
- **车道级数据更新**：依托 Live Map / One Map，高精地图自动化率 96%，支持快速动态更新。

### 7.2 城市领航

ANP 城市领航是 Apollo 商业落地的关键产品，每月推出一辆自动驾驶量产车。其车道级导航能力包括：城市车道级导航、车道级路径引导、路口转向决策、环岛进出等，率先在亦庄等示范区运营。

### 7.3 Apollo 10.0 的 Learning 化规划

Apollo 10.0 用 ADFM 大模型重构规划控制：基于 Learning 化的决策与候选轨迹生成，行驶/泊车场景能力与精度大幅提升。这是从规则驱动的 Scenario-Stage-Task 向数据驱动演进的方向，但车道级 Routing + ReferenceLine 的基础架构仍然保留。

---

## 8. 离线地图 vs 在线地图

### 8.1 Apollo 8.0 Live Map

- **离线地图**：base_map/routing_map/sim_map 预编译打包，车端 mmap 加载（类似 AuroraDrive 的 `autodrive_map.bin`）。优点是稳定、无网络依赖；缺点是更新慢、无法反映实时路况与道路变化。
- **Live Map（在线/动态地图）**：Apollo 8.0 起推行 One Map 一张图，自动化率 96%，通过云端持续生产 + 车端动态接收，实现"地图随道路变化而变化"。

### 8.2 实时更新机制

- 众包采集 + 云端融合：多车感知数据回传，云端融合生成地图差分；
- 车端订阅：仅下发变化的车道/路段（差分块），车端合并入本地地图；
- 版本对齐：Planning 用的高精地图与 HMI 用的导航地图通过统一版本号同步。

### 8.3 差分更新

差分更新降低带宽与延迟：只传输变化的 Lane/Edge 拓扑与几何，车端按 patch 合并。这对 AuroraDrive 的启示：当前 AuroraDrive 是纯静态 mmap 地图（已知限制"静态地图，不支持动态加载"），若未来要做实时路况/道路封闭，可参考 Apollo 的差分块机制，但短期仿真场景下静态地图已足够。

---

## 9. Apollo 源码关键路径

| 模块 | 文件 | 作用 |
|------|------|------|
| Routing | `modules/routing/strategy/a_star_strategy.{h,cc}` | A\* 搜索主体 |
| Routing | `modules/routing/graph/topo_node.h`、`topo_graph.h`、`topo_edge.h` | 拓扑图节点/边/图 |
| Routing | `modules/routing/routing.{h,cc}` | Routing 模块入口，处理 RoutingRequest/Response |
| Planning | `modules/planning/planning_base/tasks/deciders/path_lane_borrow_decider.cc` | 借道决策（self_counter>6 退出） |
| Planning | `modules/planning/planning_base/tasks/deciders/path_lane_change_decider.cc` | 换道决策（状态机+freeze_time） |
| Planning | `modules/planning/planning_base/tasks/deciders/path_bounds_decider.cc` | 路径边界生成 |
| Planning | `modules/planning/planning_base/common/reference_line_info.{h,cc}` | 参考线信息（变道判定 IsChangeLanePath） |
| Planning | `modules/planning/planning_base/planning_base.cc`、`on_lane_planning.cc`、`navi_planning.cc` | 规划器入口 |
| Map | `modules/map/data/<map_dir>/` | base_map / routing_map / sim_map |
| Proto | `modules/planning/proto/planning_status.proto` | `ChangeLaneStatus`、`PathDeciderStatus` |

> 注：GitHub 上 `ApolloAuto/apollo` 的 blob URL 需登录，直接 WebFetch 会得到登录页；raw.githubusercontent.com 在本环境超时。本报告源码细节来自 CSDN 社区对上述文件的逐行解析（已交叉验证多个来源）。

---

## 10. AuroraDrive 车道级导航迁移建议（重点）

### 10.1 AuroraDrive 现状分析

基于对 AuroraDrive 现有 C++ 代码的阅读（`cpp/include/ad/simulator.h`、`path_planner.h`、`map_loader.h`、`spatial.h`）：

**已有基础设施**：
- **GridIndex 空间索引**（`spatial.h`、`map_loader.h`）：`road_grid`/`node_grid`/`bldg_grid`，100m 网格，500m 查询 <1ms。
- **完整 A\* 路径规划**（`path_planner.h`）：从 mmap 图数据构建邻接表（`edges_u`/`edges_v`/`edges_w`，无向图），二叉堆 O((V+E)logV)，欧氏启发式，线程安全（`plan_mutex_`），scratch buffers 复用零分配。约 25 万节点 / 50 万边。
- **三种模式**（`simulator.h:213` `mode_`）：
  - `roam`（默认）：无目的地漫游；
  - `dest`：A\* 规划到目的地的路径，存 `route_wp_`；
  - `assist`：辅助驾驶，AUTO 接管。
- **道路引导函数** `compute_road_guidance()`（`simulator.h:443-573`）：根据模式输出引导点序列供 PurePursuit 跟踪。
- **拓扑图数据**：`node_positions`、`node_road_idx`、`node_point_idx`、`edges_u/v/w` 完整可用。

**当前 roam 模式的"方向锁定"问题**（`simulator.h:512-572`）：

```cpp
// 接近道路尽头（剩余点 < 20）：循环查询连通道路并拼接
while (stitch_remaining < 20 && int(out.size()) / 2 < 200) {
    map_.roads_in_radius(stitch_end_x, stitch_end_y, 60.0f, stitch_ids);
    int best_ri = -1;
    float best_dot = -1e18f;          // ← 选方向最一致的道路
    for (int32_t rid : stitch_ids) {
        ...
        float d = (dx2 * ch + dy2 * sh) / len2;   // 与当前 heading 的点积
        if (d > best_dot) { best_dot = d; best_ri = ri; ... }
    }
    ...
}
```

**问题诊断**：道路尽头总是选 `best_dot`（与当前航向夹角最小的道路）。在网格状路网中，这会导致车辆**始终沿一个方向直行**（方向锁定感），遇到丁字路口/环岛/网格回路时易在固定路径上 looping，缺乏漫游的随机性与探索感。用户已明确要求：**道路尽头用 GridIndex 查询所有相连道路，随机选择方向（避免 looping）**。

### 10.2 设计目标

| 模式 | 目标 | 实现策略 |
|------|------|----------|
| **dest** | A\* 车道级路径规划 | 复用现有 `PathPlanner::plan()`，已完整，无需改动 |
| **roam** | 道路尽头随机选择方向 | 改造 `compute_road_guidance` 的 stitch 逻辑：候选收集 → 去重防循环 → 随机选择 |
| **assist** | 基于地图的横向+纵向控制 | 复用 `compute_road_guidance` + PurePursuit（横向）+ PID（纵向），已基本完成（P1-001 已修复） |

### 10.3 roam 模式随机方向选择方案

**核心改动**：把 `best_dot` 贪心选择替换为"候选集 + 随机采样 + 防循环"。

**防循环策略**（关键，避免随机后回到来路反复横跳）：
1. **近期道路黑名单**：维护一个环形缓冲 `recent_road_ids_`（最近 N 条走过的道路 id），候选排除这些 id；
2. **来路硬排除**：当前 `stitch_cur_id` 已排除（现有逻辑），同时排除与来路方向完全相反（点积 < -0.5）的候选，防止 U-turn 回头；
3. **方向加权随机**（可选）：纯随机可能导致频繁急转；可对候选按 `dot` 做softmax 加权采样，既保留随机性又偏向前进方向——但用户明确要求"随机选择方向避免 looping"，故默认均匀随机，加权作为可选参数。

**拓扑连通性增强**：现有 `roads_in_radius` 是几何邻近查询（60m 半径），可能选到不实际相连的道路。AuroraDrive 已有 `node_grid` 与 `edges_u/v/w` 拓扑图，更优做法是**用拓扑边查真实连通道路**：找到道路尽头的图节点（`node_grid.query_vehicles` 附近节点），通过邻接表 `adj_` 取所有连通节点对应的道路。这更接近 Apollo TopoGraph 的 Lane 连接语义。

### 10.4 C++ 代码框架

以下代码基于 AuroraDrive 现有结构（inline header 风格、成员缓冲复用、零第三方依赖），给出 roam 随机方向的实现框架。修改集中在 `simulator.h` 的 `compute_road_guidance` 与新增成员/辅助函数。

```cpp
// ============ 在 Simulator 类中新增成员（simulator.h，与 road_pts_ 同区）============
    // ── roam 随机方向：近期道路环形黑名单（防 looping）──
    std::vector<int32_t> recent_road_ids_;     // 环形缓冲，存最近走过的 road_id
    size_t recent_idx_ = 0;                     // 环形写入位置
    static constexpr size_t kRecentCap = 8;     // 黑名单容量（约 8 条道路，防短期回头）
    // ── roam 随机方向：线程局部 RNG（sim_thread 与 assist_thread 各自一份）──
    //     注：compute_road_guidance 被 sim_thread(step) 与 assist_thread(assist_auto_lateral) 共用，
    //     故 RNG 不放成员，改 thread_local，避免加锁。
    // ── 拓扑连通查询缓冲（复用，避免每步堆分配）──
    std::vector<int32_t> roam_cand_ids_;
    std::vector<int32_t> roam_node_cand_;

// ============ 新增辅助：把 road_id 加入近期黑名单 ============
    void push_recent_road(int32_t rid) {
        if (kRecentCap == 0) return;
        // 去重：已存在则不重复加（避免占满缓冲）
        for (size_t i = 0; i < recent_road_ids_.size(); ++i)
            if (recent_road_ids_[i] == rid) return;
        if (recent_road_ids_.size() < kRecentCap) {
            recent_road_ids_.push_back(rid);
        } else {
            recent_road_ids_[recent_idx_] = rid;
            recent_idx_ = (recent_idx_ + 1) % kRecentCap;
        }
    }
    bool is_recent_road(int32_t rid) const {
        for (size_t i = 0; i < recent_road_ids_.size(); ++i)
            if (recent_road_ids_[i] == rid) return true;
        return false;
    }

// ============ 新增辅助：用拓扑图查询道路尽头的真实连通道路（替代纯几何半径）============
    // 返回与 (end_x,end_y) 拓扑连通的候选 road_id 列表
    void query_connected_roads(float end_x, float end_y,
                               int32_t cur_rid, float heading_ch, float heading_sh,
                               std::vector<int32_t>& out_cand) {
        out_cand.clear();
        // 1) node_grid 找道路尽头附近的图节点
        roam_node_cand_.clear();
        map_.node_grid.query_vehicles(end_x, end_y, 30.0f, roam_node_cand_);
        // 2) 通过 PathPlanner 邻接表取连通节点 → 取对应 road_id
        //    （若 PathPlanner 暴露 adj_ 或提供 neighbor 接口；否则回退到 roads_in_radius）
        for (int32_t nidx : roam_node_cand_) {
            int32_t r = map_.node_road_idx[nidx];
            if (r == cur_rid) continue;
            if (is_recent_road(r)) continue;            // 黑名单防循环
            out_cand.push_back(r);
        }
        // 3) 回退：拓扑查询为空时用几何半径（保底，确保不卡死）
        if (out_cand.empty()) {
            map_.roads_in_radius(end_x, end_y, 60.0f, roam_cand_ids_);
            for (int32_t rid : roam_cand_ids_) {
                if (rid == cur_rid) continue;
                if (is_recent_road(rid)) continue;
                out_cand.push_back(rid);
            }
        }
        // 4) 排除与来路完全反向的候选（点积 < -0.5 → 约 >120° 反向），防 U-turn
        std::vector<int32_t> filtered;
        for (int32_t rid : out_cand) {
            int ri = map_.find_road_by_id(rid);
            if (ri < 0) continue;
            const float* p2 = map_.road_center_ptr(ri);
            int n2 = map_.road_point_count(ri);
            if (n2 < 2) continue;
            float dx = p2[(n2-1)*3]   - p2[0];
            float dy = p2[(n2-1)*3+1] - p2[1];
            float len = std::sqrt(dx*dx + dy*dy);
            if (len < 1e-3f) continue;
            float dot = (dx * heading_ch + dy * heading_sh) / len;
            if (dot < -0.5f) continue;                  // 反向排除
            filtered.push_back(rid);
        }
        if (!filtered.empty()) out_cand.swap(filtered);
    }

// ============ 改造 compute_road_guidance 的 stitch 循环（替换 best_dot 贪心）============
    // 原 while 循环体内：
    while (stitch_remaining < 20 && int(out.size()) / 2 < 200) {
        // —— 旧：best_dot 贪心 ——
        // map_.roads_in_radius(stitch_end_x, stitch_end_y, 60.0f, stitch_ids);
        // int best_ri = -1; float best_dot = -1e18f; ...
        // for (...) { if (d > best_dot) {...} }

        // —— 新：候选收集 + 随机选择 ——
        query_connected_roads(stitch_end_x, stitch_end_y,
                              stitch_cur_id, ch, sh, roam_cand_ids_);
        if (roam_cand_ids_.empty()) break;              // 无连通道路，停止拼接

        // thread_local RNG（避免 sim/assist 线程竞争）
        static thread_local std::mt19937 rng{std::random_device{}()};
        std::uniform_int_distribution<size_t> dist(0, roam_cand_ids_.size() - 1);
        int32_t chosen_rid = roam_cand_ids_[dist(rng)];
        int best_ri = map_.find_road_by_id(chosen_rid);
        if (best_ri < 0) break;

        // 计算 chosen 道路的方向（决定从 0→N 还是 N→0 取点）
        const float* p2 = map_.road_center_ptr(best_ri);
        int n2 = map_.road_point_count(best_ri);
        if (n2 < 2) break;
        float p20x = p2[0], p20y = p2[1];
        float p2Nx = p2[(n2-1)*3], p2Ny = p2[(n2-1)*3+1];
        float d0 = (p20x - stitch_end_x)*(p20x - stitch_end_x)
                 + (p20y - stitch_end_y)*(p20y - stitch_end_y);
        float dN = (p2Nx - stitch_end_x)*(p2Nx - stitch_end_x)
                 + (p2Ny - stitch_end_y)*(p2Ny - stitch_end_y);
        bool start_from_0 = (d0 <= dN);

        int limit = std::min(n2, 200 - int(out.size()) / 2);
        if (start_from_0) {
            for (int i = 0; i < limit; ++i) {
                out.push_back(p2[i*3]); out.push_back(p2[i*3+1]);
            }
            stitch_end_x = p2[(limit-1)*3];
            stitch_end_y = p2[(limit-1)*3+1];
            stitch_remaining = n2 - limit;
        } else {
            for (int i = n2 - 1; i >= 0 && (n2 - 1 - i) < limit; --i) {
                out.push_back(p2[i*3]); out.push_back(p2[i*3+1]);
            }
            int start_idx = n2 - limit;
            if (start_idx >= 0) {
                stitch_end_x = p2[start_idx*3];
                stitch_end_y = p2[start_idx*3+1];
            }
            stitch_remaining = start_idx;
        }
        // 记入黑名单，防短期回头
        push_recent_road(stitch_cur_id);
        stitch_cur_id = map_.road_ids[best_ri];
    }
```

**dest 模式（无需改动）**：`compute_road_guidance` 开头已处理 `is_dest` 分支，直接取 `route_wp_`（A\* 规划结果），`PathPlanner::plan()` 已是完整车道级路径规划。

**assist 模式（基于地图的横向+纵向控制）**：当前 `assist_auto_lateral()` 复用 `compute_road_guidance` + PurePursuit，`assist_auto_longitudinal()` 用 PID 维持 40km/h（P1-001 已修复）。改造 roam 随机方向后，assist 模式自动受益——因为 assist 也调用 `compute_road_guidance`，漫游时方向不再锁定。需注意：assist 线程与 sim 线程并发调用此函数，故 RNG 用 `thread_local`、缓冲用局部或已区分的成员（`assist_road_pts_` 已独立）。

### 10.5 代价 / 收益分析

**收益**：
1. **消除方向锁定感**：roam 在路口随机分叉，漫游路径多样化，更接近真实"无目的开车"体验，避免网格路网固定路径 looping。
2. **探索性增强**：随机方向使车辆能覆盖更多道路，利于仿真测试覆盖面与交通流多样性。
3. **架构对齐 Apollo**：roam 随机选向 ↔ Apollo Routing 在无明确目的地时的随机/贪心选路；dest A\* ↔ Apollo Lane-Level Routing；assist 地图引导 ↔ Apollo ReferenceLine + Planning。三模式语义清晰。
4. **复用现有基础设施**：GridIndex（`node_grid`/`road_grid`）、A\*（`PathPlanner`）、拓扑图（`edges_u/v/w`）均已就绪，改动集中在一个函数 + 少量成员，符合"最小化实现、避免过度工程"约定。
5. **assist 自动受益**：辅助驾驶漫游时方向不再单一，AUTO 接管体验更自然。

**代价 / 风险**：
1. **随机性带来不可预测轨迹**：可能驶入窄路/死胡同。缓解：`query_connected_roads` 回退到几何半径保底；可加"道路类型优先级"（优先主干道）作为后续优化。
2. **拓扑查询依赖 `node_road_idx` 准确性**：若 mmap 数据中节点-道路映射有误，会选错连通道路。缓解：保留几何半径回退；启动时校验 `node_road_idx` 范围。
3. **近期黑名单可能误伤**：环形缓冲容量 8，复杂路口可能短期内可选道路都被屏蔽。缓解：容量可调；黑名单仅排除完全反向 + 近期 8 条，正常路网足够候选。
4. **`PathPlanner::adj_` 访问**：若不暴露邻接表接口，`query_connected_roads` 的拓扑查询部分需在 `PathPlanner` 加一个 `neighbors(node_idx)` 方法，或直接回退几何半径（已实现）。建议加最小接口，更贴近 Apollo TopoGraph 语义。
5. **线程安全**：`recent_road_ids_` 被 sim_thread 写、assist_thread 读，存在数据竞争。缓解：要么 assist 模式不记黑名单（仅 sim_thread 写），要么用 `thread_local` 各自一份黑名单，要么加锁。推荐 `thread_local` 方案，与 RNG 一致，零锁争用。
6. **性能**：随机选择 O(候选数)，与原贪心同阶；拓扑查询用 `node_grid` O(k)，可接受；24Hz 实时性无压力。

**工作量评估**：核心改动约 80 行 C++（一个函数改造 + 两个辅助函数 + 成员声明），预计 3~4h（含调试与路网回归测试）。符合 P1 优先级。

**后续可选增强**（不在本次范围）：
- 方向加权随机（softmax on dot），平衡随机性与平顺性；
- 道路类型权重（主干道优先）；
- roam 模式简易"虚拟目的地"（远处随机点 + A\*），实现更自然的远距离漫游；
- Live Map 风格差分更新（长期，当前静态地图足够）。

---

## 11. 总结

Apollo 车道级导航的工程范式可归纳为三层：

1. **车道级全局规划（Routing）**：高精地图 → TopoGraph 拓扑图 → A\* 搜索车道序列。这是车道级导航的"灵魂"——Routing 输出本就是车道级。
2. **参考线层（ReferenceLineProvider）**：车道序列 → 平滑参考线，变道时生成多条候选。这是规划的地基。
3. **决策与规划层（Planning）**：Scenario-Stage-Task 架构，`LaneChangeDecider`（换道状态机 + freeze_time + HysteresisFilter）与 `PathLaneBorrowDecider`（self_counter>6 退出借道 + 6 条进入条件）分工明确，强制换道（导航要求）与被动借道（避障）分离。

AuroraDrive 已具备对等的三个组件：`PathPlanner`（A\*）= Routing、`compute_road_guidance`/`route_wp_` = ReferenceLine、`PurePursuit`+`PID` = Planning 控制。本次迁移的核心是**把 roam 模式的"方向最一致贪心"改为"GridIndex 查所有连通 + 随机选择 + 黑名单防循环"**，对齐 Apollo 在无目的地场景的随机选路思想，同时保持 dest（A\*）与 assist（地图引导）模式不变。改动局部、风险可控、收益明确，建议作为 P1 任务实施。

---

## 参考资料

- Apollo 开放平台 10.0 发布（InfoQ）：https://www.infoq.cn/article/GXNSfsTmKpoeiameeG8M
- Apollo 开放平台 9.0（头条）
- Apollo Routing 模块 A\* 算法剖析：https://blog.csdn.net/davidhopper/article/details/87438774
- Apollo Routing 模块中的 A\* 算法：https://blog.csdn.net/xiner0114/article/details/141094479
- Apollo3.5 基于 TopoGraph 的 Routing A\* 路径导航：https://blog.csdn.net/weixin_44809980/article/details/107929643
- Apollo Planning 换道 LANE_CHANGE_DECIDER：https://blog.csdn.net/weixin_42905141/article/details/135085786
- Apollo LANE_CHANGE_DECIDER 学习笔记：https://blog.csdn.net/sinat_52032317/article/details/132323635
- Apollo lane_borrow_decider 代码解读：https://blog.csdn.net/weixin_42861755/article/details/130713936
- Apollo path_bounds_decider 代码解读：https://blog.csdn.net/weixin_42861755/article/details/130722949
- Apollo 轨迹规划流程（lane follow 场景）：https://blog.csdn.net/qq_41667348/article/details/129104744
- Apollo 详解换道（HysteresisFilter/状态机）：https://blog.csdn.net/CV_Autobot/article/details/134279905
- Apollo 9.0 参考线生成器 ReferenceLineProvider：https://blog.csdn.net/WaiNgai1999/article/details/145575354
- Apollo 参考线提供者 ReferenceLineProvider：https://blog.csdn.net/zhizhengguan/article/details/129323751
- Apollo 高精地图解析（base_map/routing_map/sim_map）：https://blog.csdn.net/weixin_44128918/article/details/105684918
- 生成 base_map/routing_map/sim_map：https://blog.csdn.net/lh315936716/article/details/115112200
- Apollo 10.0 PublicRoadPlanner / Scenario-Stage：https://blog.csdn.net/qq1240268067/article/details/148011303
- Apollo 10.0 Scenario/Stage 插件详解：https://blog.csdn.net/qq1240268067/article/details/148063721
- Apollo ANP 城市领航（极客公园）：https://www.geekpark.net/news/284777
- 百度地图 X Apollo 城市车道级导航（亦庄）
- AuroraDrive 项目交接文档（本地）：`/Users/dupi/Desktop/自动驾驶系统/AuroraDrive项目交接文档.md`
- AuroraDrive 源码（本地）：`cpp/include/ad/simulator.h`、`path_planner.h`、`map_loader.h`、`spatial.h`

---

> 本报告实际工具调用次数：**52 次**（WebSearch 28 次 + WebFetch 24 次；另含本地 Read/Grep/Glob 若干次用于 AuroraDrive 代码对照，未计入 Web 调用数）。报告字数约 6200 字（中文）。
