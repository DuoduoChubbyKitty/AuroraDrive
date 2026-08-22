# Autoware 规划模块深度研究报告

> 研究对象：Autoware.Universe（基于 ROS 2 的开源自动驾驶栈）的 Planning 模块
> 对比对象：百度 Apollo Planning 模块
> 落地目标：AuroraDrive 规划升级方案
> 数据来源：Autoware 官方文档、autowarefoundation/autoware.universe 源码、CSDN/51CTO 技术解析、Apollo 源码解析等

---

## 一、Autoware 规划总体架构

### 1.1 分层架构概览

Autoware 的 Planning 模块在官方文档（autoware-documentation / design / autoware-architecture / planning）中被划分为四大子模块：

- **Mission Planning（任务规划）**：利用高精地图（Lanelet2）计算从当前位姿到目的地的全局路线（Route），类似汽车导航的路径规划。核心概念是 primitive（原语）→ segment（路段）→ route（路线）。
- **Behavior Planning（行为规划）**：在全局路线之上，结合交通规则与场景决策，计算"安全的、合规的"路径与速度上限。又细分为 **behavior_path_planner**（管横向路径/几何）与 **behavior_velocity_planner**（管纵向速度/规则）。
- **Motion Planning（运动规划）**：在行为规划输出基础上做运动学层面的轨迹细化与速度曲线平滑，包含 obstacle_stop_planner、obstacle_cruise_planner、surround_obstacle_checker、motion_velocity_smoother、path_optimizer 等。
- **Validation（规划校验）**：planning_validator 在轨迹发布给控制模块前，校验轨迹的合理性（曲率、速度、加速度、点间距等），无效则报警并通过 /diagnostics、/validation_status 上报。

### 1.2 场景分层（Scenario）

Planning 顶层由 **scenario_selector** 在 `LANE_DRIVING`（车道行驶）与 `PARKING`（泊车）两大场景间切换。每个场景内部再挂载对应的行为/运动规划链路：

```
Lane Driving 场景：
  Behavior Path Planner  (横向：车道保持/变道/避障/靠边/起步/侧移)
  Behavior Velocity Planner (纵向：交规速度限制)
  Motion Planning         (obstacle_stop / obstacle_cruise / velocity_smoother ...)
Parking 场景：
  Freespace Planner (Hybrid A* + Reeds-Shepp)
  Costmap Generator
```

### 1.3 文字架构图

```
                     ┌──────────────────────────────────────────────┐
   Map(Lanelet2) ───►│             Mission Planner                   │── Route (LaneletPath)
   Goal Pose ──────► │  (mission_planner / route_handler)            │
                     └────────────────────┬─────────────────────────┘
                                          │
                     ┌────────────────────▼─────────────────────────┐
   Perception ─────► │         scenario_selector                     │
   Objects           │   (LaneDriving  vs  Parking)                  │
                     └──────┬───────────────────────────────┬───────┘
                            │ LaneDriving                    │ Parking
              ┌─────────────▼──────────────┐   ┌─────────────▼──────────────┐
              │  behavior_path_planner     │   │  costmap_generator         │
              │  (lane_follow / lane_change│   │  freespace_planner         │
              │   avoidance / pull_over /  │   │  (Hybrid A* + Reeds-Shepp) │
              │   pull_out / side_shift /  │   └─────────────┬──────────────┘
              │   dynamic_avoidance)       │                 │
              └─────────────┬──────────────┘                 │
                            │ Path                          ▼
              ┌─────────────▼──────────────┐        Trajectory(parking)
              │  behavior_velocity_planner │                 │
              │  (stop_line / cross_walk / │                 │
              │   traffic_light / intersec-│                 │
              │   tion / blind_spot /      │                 │
              │   detection_area / no_stop │                 │
              │   / occlusion_spot / run_out)                │
              └─────────────┬──────────────┘                 │
                            │ Path + 速度限制                 │
              ┌─────────────▼──────────────┐                 │
              │  Motion Planning           │                 │
              │  obstacle_stop_planner     │                 │
              │  obstacle_cruise_planner(ACC)                 │
              │  surround_obstacle_checker │                 │
              │  motion_velocity_smoother  │                 │
              │  path_optimizer(MPT) /     │                 │
              │  elastic_band smoother     │                 │
              └─────────────┬──────────────┘                 │
                            │                                │
                     ┌──────▼────────────────────────────────▼──────┐
                     │            planning_validator                │
                     └──────┬───────────────────────────────────────┘
                            │
                            ▼
            /planning/scenario_planning/trajectory  ──►  Control (MPC/PID)
            (轨迹长度≈10s，分辨率 0.1s)
```

### 1.4 与 Apollo 规划架构的总体对比

| 维度 | Autoware.Universe | Apollo |
|------|-------------------|--------|
| 中间件 | ROS 2（DDS），社区生态丰富 | Cyber RT（自研，3.5 起弃用 ROS） |
| 顶层抽象 | scenario_selector 切 LaneDriving/Parking | Scenario → Stage → Task 三层分层状态机 |
| 行为/运动耦合 | 行为（路径+速度规则）与运动（轨迹+速度平滑）节点解耦，各为独立 ROS 节点 | 在一个 Planning 模块内集中式处理，EM/Lattice Planner 耦合更紧 |
| 全局规划 | mission_planner 基于 Lanelet2 图搜索 | routing 模块基于 OpenDRIVE 拓扑 |
| 地图格式 | Lanelet2（.osm） | OpenDRIVE |
| 可扩展性 | 模块化、组件式（composable node），易替换 | 插件化场景/任务，配置驱动 |

---

## 二、Behavior Planner（行为规划）

### 2.1 behavior_path_planner（横向行为）

behavior_path_planner 是 Lane Driving 场景下横向路径生成的核心节点，由一个定时器按固定频率调用 `BehaviorPathPlannerNode::run()`，内部由 **PlannerManager** 统一管理多个子模块。其内部采用"行为树/BT + 模块管理器（ModuleManager）+ 优先级"的机制来决定哪个模块激活并产出候选路径。

主要子模块（每个模块都是一个 Scene + Manager 的模板化实现）：

- **lane_following**：基础车道保持，输出沿参考车道的中心线路径，同时维护可行驶区域（Drivable Area）。
- **lane_change（NormalLaneChange）**：执行变道。判断逻辑 `isLaneChangeRequired()` 依据"目标车道是否为空"与"距变道起点距离"；变道路径生成 `getLaneChangePaths()` 会做碰撞检测与安全距离校验，min_lane_change_length 默认 8.0m，prepare_duration 2.0s。
- **static_obstacle_avoidance**：基于规则的静态避障。通过目标过滤（ObjectData）+ Shift Line Generator 生成横向偏移路径；支持 MANUAL（人工批准）/AUTO 两种模式；不支持动态障碍物。
- **dynamic_obstacle_avoidance**：处理动态障碍物避让，基于预测轨迹（PredictedObjects）做规划。
- **pull_over**：靠边停车，当自车在车道、目标在路肩（shoulder lane）时执行，停在目标位置。
- **pull_out**：路边起步，从路肩汇入车道。
- **side_shift**：车道内小幅横向平移以避让。

### 2.2 behavior_velocity_planner（纵向行为/规则）

behavior_velocity_planner 基于交通规则计算路径上各点的最大速度，采用与 behavior_path 类似的"模板模块（Scene/Manager）"机制，模块包括：

- **stop_line**：处理停止线前停车。
- **cross_walk**：处理行人横道。
- **traffic_light / virtual_traffic_light**：红绿灯信号处理。
- **intersection**：交叉路口处理。
- **blind_spot**：盲区检测。
- **detection_area**：检测区域减速/停车。
- **no_stopping_area**：禁停区域，避免在禁停区停车。
- **occlusion_spot**：视野遮挡点，在碰撞点前减速以防隐藏物体突然冲出。
- **run_out**：跑出场景处理。
- **obstacle_avoidance_planner**：避障相关速度。

### 2.3 状态机与决策逻辑

Autoware 的行为决策并不采用 Apollo 那种显式的"重决策状态机 + Scenario 配置文件"，而是：
- 用 **PlannerManager / ModuleManager** 按优先级（priority）与激活条件（approval、is-executable）来调度各模块；
- 模块之间通过"候选路径 + 碰撞校验 + 安全裕度（safety margin）"协作，最终选出一条 root lanelet 上的输出路径；
- 变道等高风险动作可对接 **rtc_interface（实时控制接口）**，走"申请—批准"流程（approval command），并由转向灯（turn signal）协同输出。

---

## 三、Motion Planner（运动规划）

Autoware 的 Motion Planning 不是单一节点，而是一组节点：

- **obstacle_stop_planner**：检测前方障碍物并决定是否停车，生成安全停车轨迹，含 **ACC（自适应巡航）** 子模块（adaptive_cruise_control.cpp），处理紧急制动。
- **obstacle_cruise_planner**：巡航过程中处理动态障碍物，调整巡航速度、保持安全跟车距离，被 behavior_velocity_planner 调用，与 obstacle_stop_planner 协作。
- **surround_obstacle_checker**：检查车辆周围障碍物，防止刮擦（默认可关闭）。
- **motion_velocity_smoother**：在速度/加速度/加加速度（jerk）约束下平滑速度曲线，可选 jerk filtered / l2 / linf / analytical 等平滑类型，实现乘坐舒适性与速度最大化。
- **motion_velocity_obstacle_velocity_limiter / out_of_lane**：根据障碍物限速、处理偏离车道减速。
- **path_optimizer（autoware_path_optimizer）**：使用 **MPT（Model Predictive Trajectory）** 方法对输入路径做轨迹优化，使其更平滑且满足车辆动力学约束。
- **path_sampler / elastic_band smoother（autoware_path_smoother）**：基于弹性带（Elastic Band）的路径平滑，保持几何连续性、考虑运动学约束与安全性。

### 3.1 代价函数与约束

Autoware 运动规划的代价主要体现为：
- 路径代价：偏离参考线、曲率、碰撞代价、Voronoi 势场（freespace/astar 中）；
- 速度代价：加加速度（jerk）惩罚、与限速的偏差、停车接近速度（stop approach velocity）；
- 约束：最大曲率（最小转弯半径）、最大加速度/减速度、最大 jerk、外部速度限制（external velocity limit）。

---

## 四、路径规划：A* / Hybrid A* / Reeds-Shepp

### 4.1 freespace_planner（自由空间规划器）

autoware_freespace_planner 是 Parking 场景下的核心路径规划器，在有静态/动态障碍物的自由空间中规划轨迹，基于 **Hybrid A\*** 搜索，生成可执行的单向（前进/后退）轨迹，支持实时重规划。

核心流程：
1. 由 **costmap_generator** 生成代价地图（栅格，常用 5cm 分辨率），融合动态对象与车道信息；
2. 设置起点（current_pose）与终点（goal_pose）；
3. 执行 Hybrid A* 搜索 `planner_->makePlan()`。

### 4.2 Hybrid A* 算法要点

Hybrid A* 在经典 A* 基础上引入车辆运动学（自行车模型，前向/后向），状态空间为 (x, y, θ)，相比 2D A* 的栅格搜索，能保证生成的路径可被车辆跟踪。其启发式设计采用"双启发取大值"：
- **约束启发式**：基于 Dubins 或 Reeds-Shepp 路径，考虑运动学但不考虑障碍物；
- **无约束启发式**：基于 2D A* 搜索，考虑障碍物但忽略运动学。

代价 G 综合了移动代价、转向代价、方向变化惩罚、齿轮切换惩罚等；H 取两者最大值以保证 admissible 与搜索效率。当搜索节点接近目标时，尝试用 **Reeds-Shepp Shot** 直接连接，保证得到最优短路径。

### 4.3 Reeds-Shepp 曲线

Reeds-Shepp 曲线假设车辆能以固定半径转向且可前进/后退，是该约束下的最短路径。Hybrid A* + RS 组合的原因：Hybrid A* 保证能找到一条可行路径，RS 曲线保证路径的最优性与平滑性；之后仍需轨迹平滑（消除离散搜索造成的折角）以利于控制跟踪。

### 4.4 与 Apollo Open Space 的对比

| 项目 | Autoware freespace_planner | Apollo Open Space Planner |
|------|----------------------------|---------------------------|
| 搜索算法 | Hybrid A*（含 RS Shot） | Hybrid A*（node3d / grid_search / reeds_shepp） |
| 平滑 | 后处理路径平滑（弹性带/优化） | 基于最优控制的轨迹优化（QP/距离/曲率约束） |
| 地图表达 | costmap（占据栅格） | Hybrid A* 用栅格 + 障碍物边界 |
| 应用场景 | 泊车、自由空间 | 泊车、掉头、靠边 |
| 输出 | 单向可执行轨迹 | 平滑后轨迹，再送控制 |
| 集成方式 | 独立 ROS 2 节点 | 集成在 Planning 模块内 |

两者算法内核高度相似（均 Hybrid A* + Reeds-Shepp），差异主要在工程封装与平滑策略上：Apollo 更强调"搜索 + 最优控制平滑"一体化，Autoware 更模块化、可替换。

---

## 五、速度规划

### 5.1 Autoware 速度规划链路

Autoware 没有像 Apollo 那样的统一 ST 图 + DP/QP 速度优化器，而是分散在多个节点：

- **behavior_velocity_planner**：基于交通规则在各模块计算"最大速度限制点"（在路径上插入 stop/slow_down 速度点）；
- **obstacle_stop_planner**：检测前方障碍物，生成停车轨迹与 ACC 速度，含 stop / slow_down / adaptive_cruise 三类处理；
- **obstacle_cruise_planner**：跟车巡航，保持安全距离；
- **motion_velocity_obstacle_velocity_limiter**：根据障碍物情况计算速度限制并平滑；
- **motion_velocity_smoother**：最终速度曲线平滑，流程为：提取轨迹 → 应用外部速度限制 → 应用停车接近速度 → 在 jerk/加速度约束下平滑，输出舒适且速度最大化的速度曲线。

Autoware 默认最高速度出于安全限制在约 15km/h（可配置），其速度规划更偏"规则驱动 + 平滑"，而非显式 ST 图优化。

### 5.2 与 Apollo 速度规划的对比

| 项目 | Autoware | Apollo |
|------|----------|--------|
| 速度优化形式 | 规则模块 + 节点级平滑 | ST 图 + DP（决策）+ QP（优化） |
| 跟车 | obstacle_cruise_planner（ACC） | DP/QP 在 ST 图中处理 |
| 平滑目标 | jerk/加速度约束下的舒适度 | QP 二次规划，cost 含 jerk、碰撞、偏离参考 |
| 全局一致性 | 各节点局部处理 | EM 迭代中路径/速度耦合优化 |
| 复杂度 | 较低、易调试 | 较高、性能强 |

Apollo 的 EM Planner 把路径（SL 图 DP+QP）与速度（ST 图 DP+QP）在 E-step/M-step 中迭代优化，对多障碍物复杂场景处理更强；Autoware 采用解耦、模块化的方式，工程上更简单、可调试性更好，但多障碍密集场景的联合最优性弱于 Apollo。

---

## 六、Behavior Path Planning 与 Apollo Scenario 对比

### 6.1 Autoware 行为路径模块

如前所述，behavior_path_planner 通过 ModuleManager 管理多个横向行为模块，模块按优先级与激活条件协同，输出路径 + 可行驶区域 + 转向灯命令。其优势是模块独立、易于新增场景（官方提供 Scene/Manager 模板，可快速创建新模块）。

### 6.2 Apollo Scenario 机制

Apollo 采用 **Scenario → Stage → Task** 三层分层架构：
- Scenario：LaneFollowScenario、EmergencyPullOverScenario、EmergencyStopScenario、BareIntersectionUnprotectedScenario、ValetParkingScenario、YieldSignScenario 等；
- Stage：如 ValetParking 的 StageApproachingParkingSpot、StageParking；
- Task：每个 Stage 内挂载一系列 Task（路径/速度优化任务）。

Scenario 之间有显式转换逻辑，由配置文件驱动。

### 6.3 对比

| 项目 | Autoware behavior_path | Apollo Scenario |
|------|------------------------|-----------------|
| 抽象层级 | 模块（Module）+ 优先级调度 | Scenario/Stage/Task 三层 |
| 配置方式 | YAML 参数 + 模块开关 | 场景配置文件 + 注册机制 |
| 变道/避障/靠边 | 独立模块，BT 调度 | 作为特定 Scenario 的 Stage/Task |
| 扩展性 | 模板化，新增模块快 | 新增 Scenario 需注册与转换逻辑 |
| 决策风格 | 偏轻决策、模块协作 | 偏重决策、状态机驱动 |

Autoware 的方式更"轻量、扁平"，Apollo 的方式更"层次化、工程化"。对中小规模场景 Autoware 更易上手，对超大规模量产场景 Apollo 的层次更利于管理与回溯。

---

## 七、Trajectory Planning（轨迹规划）

### 7.1 轨迹生成与转换

Autoware 中存在 Path（含几何，无时间）与 Trajectory（含时间/速度）两种类型，通过 **path_to_trajectory** 等节点做类型转换。最终输出给控制模块的轨迹约定为：**长度约 10 秒、分辨率 0.1 秒**，包含位姿、twist、加速度的平滑序列。

### 7.2 平滑与约束

- **路径平滑**：autoware_path_smoother（弹性带）、autoware_path_optimizer（MPT 轨迹优化）；
- **速度平滑**：motion_velocity_smoother（jerk filtered 等多种模式）；
- **约束**：曲率（最小转弯半径）、加速度/减速度上限、jerk 上限、外部速度限制、停车接近速度、偏离车道减速；
- **校验**：planning_validator 在发布前检查轨迹有效性，无效则上报 /diagnostics，必要时触发安全响应。

---

## 八、Autoware 规划源码梳理

### 8.1 autoware.universe/planning 目录

源码位于 `github.com/autowarefoundation/autoware.universe/planning`，包含数十个功能包，主要可归为：

- 任务规划：mission_planner、route_handler、lanelet2_extension
- 行为路径：behavior_path_planner 及其子模块（lane_change、avoidance、pull_over、pull_out、side_shift、dynamic_obstacle_avoidance 等）
- 行为速度：behavior_velocity_planner 及子模块（stop_line、cross_walk、traffic_light、intersection、blind_spot、detection_area、no_stopping_area、occlusion_spot、run_out、virtual_traffic_light 等）
- 运动规划：obstacle_stop_planner、obstacle_cruise_planner、surround_obstacle_checker、surround_obstacle_checker_based_on_predicted_object、motion_velocity_smoother、out_of_lane、obstacle_velocity_limiter
- 自由空间：freespace_planner、costmap_generator
- 轨迹优化：path_optimizer、path_smoother（elastic_band）、trajectory utils
- 调度与校验：scenario_selector、planning_validator、path_to_trajectory、rtc_interface、turn_signal_operator
- 工具：planning_diagnostics、planning_topic_converter、static_centerline_generator

### 8.2 关键源码节点

- **BehaviorPathPlannerNode::run()**：行为路径主循环，takeData → isDataReady → 仅在 LANE_DRIVING 场景运行 → 调用 planner_manager_ 生成路径。
- **PlannerManager::run()**：管理各子模块激活与优先级，输出 reference path / path / drivable area。
- **NormalLaneChange::updateLaneChangeStatus() / getSafePath() / getLaneChangePaths()**：变道状态机与路径生成。
- **FreespacePlannerNode::planTrajectory()**：Hybrid A* 搜索主入口。
- **MotionVelocitySmoother**：速度曲线平滑流水线。

### 8.3 关于 "surturn" 的说明

研究中针对关键词 "surturn" 进行了多次检索，未在 Autoware 官方源码或主流解析中找到名为 `surturn` 的独立功能包。推测该词为拼写误差，最可能指向以下两者之一：
- **surround_obstacle_checker**：车辆周围障碍物检查器（防刮擦），名字以 "surround-" 开头，易被误写为 "surturn"；
- 与 **turn（转弯）/ intersection（路口转向）** 相关的处理（behavior_velocity_intersection_module）。

若实际指代其它内容，建议以 autoware.universe/planning 实际包名为准。本报告在此明确标注该不确定性，避免误导。

---

## 九、Autoware vs Apollo 规划深度对比

### 9.1 架构差异

- Autoware：ROS 2 节点级解耦，behavior/motion 分明，模块化、composable，地图 Lanelet2；行为偏轻决策、模块协作。
- Apollo：Cyber RT 集中式 Planning，Scenario/Stage/Task 层次化，地图 OpenDRIVE；行为偏重决策、状态机驱动。

### 9.2 算法差异

- 路径：Autoware 车道行驶用规则式偏移+弹性带/MPT 平滑；泊车用 Hybrid A*+RS。Apollo 车道行驶用 EM（SL 图 DP+QP）或 Lattice（Frenet 五次多项式采样）；泊车用 Open Space（Hybrid A*+RS+优化）。
- 速度：Autoware 规则模块+jerk 平滑；Apollo ST 图 DP+QP。
- 跟车：Autoware obstacle_cruise_planner（ACC）；Apollo DP/QP 联合处理。

### 9.3 性能与适用场景差异

| 维度 | Autoware | Apollo |
|------|----------|--------|
| 工程复杂度 | 中低，模块清晰 | 高，层次多 |
| 上手门槛 | 低（ROS 2 生态） | 中高（Cyber RT 生态） |
| 多障碍联合最优性 | 中（解耦） | 高（EM 迭代） |
| 实时性 | ROS 2 DDS，可调 | Cyber RT 针对车规优化 |
| 量产成熟度 | 偏研究/教学/中小规模 | 偏量产/大规模 |
| 地图开放性 | Lanelet2 开放 | 需百度地图服务（部分） |
| 默认最高速 | ~15km/h（安全限制，可配置） | 可配置较高 |

---

## 十、AuroraDrive 规划升级方案

### 10.1 AuroraDrive 现状

AuroraDrive 当前规划方案为 **A\* + Pure Pursuit**：
- A* 提供点到点的几何路径（多为栅格搜索，运动学一致性弱）；
- Pure Pursuit 做轨迹跟踪（横向控制），结构简单但舒适性、大曲率场景鲁棒性不足；
- 缺少显式的行为决策层、缺少纵向速度规划与平滑、缺少场景化与安全校验。

### 10.2 借鉴 Autoware Behavior Planner

1. **引入分层架构**：将"全局路线 → 行为路径 → 行为速度 → 运动规划 → 校验"分层，替代当前"A* 直出路径"的扁平结构。
2. **引入 behavior_path 模块化思想**：参考 ModuleManager + 优先级调度，实现 lane_follow / avoidance / pull_over 等可插拔模块，用 Scene/Manager 模板降低新增场景成本。
3. **引入 behavior_velocity 规则层**：对停止线、路口、盲区、禁停等做显式速度限制点插入，把"交通合规"从控制层上移到规划层。
4. **引入 rtc_interface 的"申请-批准"安全机制**：对变道、靠边等高风险动作增加批准流程与转向灯协同。

### 10.3 借鉴 Autoware Motion Planner

1. **路径层升级**：A* 替换/补强为 **Hybrid A\*（带 RS Shot）**，保证运动学可行性；车道行驶场景引入弹性带 / MPT 路径平滑，消除折角、提升舒适性。
2. **纵向速度规划**：引入 obstacle_stop + obstacle_cruise（ACC）+ motion_velocity_smoother 三段式，在 jerk/加速度约束下生成平滑速度曲线，替代当前"无纵向规划、靠控制端限速"的做法。
3. **运动学约束**：把曲率、加速度、jerk 约束显式纳入规划，而非仅靠 Pure Pursuit 事后跟踪。
4. **规划校验**：引入 planning_validator，发布前校验轨迹合理性，异常时安全降级。

### 10.4 分阶段升级路线

- **阶段一（1–2 月）**：在 A* 输出后增加弹性带/MPT 平滑 + motion_velocity_smoother，纵向速度由规则限速 + jerk 平滑生成；保留 Pure Pursuit 跟踪。收益：舒适性与运动学一致性提升。
- **阶段二（2–3 月）**：将 A* 升级为 Hybrid A* + Reeds-Shepp（泊车/自由空间场景），引入 costmap_generator；车道场景引入 behavior_path 的 avoidance/lane_change 模块化框架。
- **阶段三（3–6 月）**：引入 behavior_velocity 规则模块（停止线/路口/盲区）+ obstacle_cruise ACC + planning_validator + rtc_interface 安全批准机制；横向控制器由 Pure Pursuit 逐步过渡到 MPC，与规划约束对齐。
- **阶段四（长期）**：评估是否引入 Apollo 式 ST 图 DP/QP 联合优化以应对密集动态障碍场景，或在 Autoware 解耦框架内强化 obstacle_cruise 的多障碍处理能力。

### 10.5 关键取舍

- 若 AuroraDrive 定位为中小规模/园区/低速：Autoware 解耦式方案性价比高，建议全面借鉴 Autoware。
- 若需应对城市复杂密集动态场景：在 Autoware 框架基础上，参考 Apollo EM/Lattice 的 ST 图优化补强纵向联合最优性。
- 中间件层面：若已用 ROS 2，则 Autoware 模块可较平滑移植；若追求车规级实时性，可参考 Cyber RT 思路对关键节点做进程内通信优化。

---

## 结论

Autoware 的规划模块以"ROS 2 节点解耦 + 行为/运动分层 + 模块化场景模板"为核心特征，工程清晰、易于扩展与替换，适合作为 AuroraDrive 这类从"A* + Pure Pursuit"起步系统的升级蓝本。其 freespace_planner（Hybrid A* + Reeds-Shepp）、behavior_path/velocity 的模块化场景、motion_velocity_smoother 的 jerk 约束平滑，是最具直接迁移价值的部分。相对 Apollo，Autoware 在多障碍联合优化上偏弱，但其解耦性与可调试性对中小规模系统更友好。AuroraDrive 建议按"平滑+速度规划 → Hybrid A*+场景模块化 → ACC+校验+MPC"三步走完成升级。

---

> 本报告实际工具调用次数：53 次（WebSearch + WebFetch，含若干次大文件持久化输出与超时重试）。
