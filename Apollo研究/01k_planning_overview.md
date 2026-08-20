# Apollo 规划模块（Planning）整体架构深度研究报告

> 研究对象：Baidu Apollo 自动驾驶开放平台 Planning 模块（Apollo 6.0 → 9.0 PnC 2.0 → 10.0/11.0）
> 研究目的：为 AuroraDrive 仿真系统的规划栈升级提供架构参照与迁移路线
> 撰写日期：2026-07-23
> 研究方法：WebSearch + WebFetch 对 GitHub `ApolloAuto/apollo` 源码目录、Apollo 官方文档、CSDN 源码解析系列进行深度挖掘

---

## 0. 摘要

Apollo 的规划（Planning）模块是"感知—预测—规划—控制"（PnC）链路中承上启下的核心：它消费预测、Routing、高精地图（HD Map）、定位四路输入，输出一条带 s/t/v/a/θ/κ/jerk 等完整运动学量的 `ADCTrajectory` 轨迹点序列，供控制模块以更高频率跟踪。Apollo 规划历经 RTK Replay → Lattice → EM Planner → 场景化 Public Road Planner → Open Space Planner 的演进，并在 9.0 提出 PnC 2.0 插件化重构，10.0 引入 ADFM 大模型辅助。本报告系统梳理其目录结构、三大规划器、Scenario/Stage/Task 三级架构、参考线平滑、速度规划、关键 Task 链，并对照 AuroraDrive 当前的"A* + Pure Pursuit"极简方案给出升级路线图。

---

## 1. Apollo 规划模块整体架构

### 1.1 modules/planning 目录结构（Apollo 9.0+ / 11.0 master）

通过对 `github.com/ApolloAuto/apollo/tree/master/modules/planning` 的实际抓取，当前 master（已演进到 11.0）的 `modules/planning` 顶层目录为：

| 子目录 | 职责 |
|--------|------|
| `planning_component/` | Cyber RT 组件入口，`PlanningComponent` 类，订阅预测/底盘/定位，发布 `ADCTrajectory` |
| `planning_base/` | 规划基类 `PlanningBase`、`Frame`、`ReferenceLineInfo`、`TrajectoryStitcher`、`common/`、`reference_line/`、`tasks/` 基类等通用骨架 |
| `planners/` | 规划器插件实现，含 `public_road/`（PublicRoadPlanner + ScenarioManager）、`lattice/`、`rtk/`、`navi/` 等 |
| `planning_open_space/` | 开放空间规划（Hybrid A*、OBCA、DL-IAPS）独立模块 |
| `planning_interface_base/` | 插件接口基类（Scenario/Stage/Task/Planner/Rule 的抽象接口） |
| `scenarios/` | 各 Scenario 插件包（lane_follow、pull_over、valet_parking、park_and_go、traffic_light、stop_sign、yield_sign、bare_intersection 等） |
| `tasks/` | 各 Task 插件包（deciders、optimizers、open_space 等） |
| `traffic_rules/` | 交通规则处理插件（红绿灯、人行道、停止线、减速带等，生成 virtual obstacle） |
| `pnc_map/lane_follow_map/` | 规划与控制地图（PncMap），从 HD Map 生成 RouteSegments / 参考线 |
| `park_data_center/` | 泊车数据缓存中心 |

### 1.2 Apollo 9.0 PnC 2.0 重构：planners/ + planning_base/ + planning_component/

PnC 2.0 的核心是**插件化（Plugin）**：把原本耦合在 `modules/planning` 单体里的规划器、场景、阶段、任务、交通规则全部拆成可独立编译、动态加载的插件（`.so`），由 `cyber::plugin_manager::PluginManager` 统一注册与加载。调用层次为：

```
PlanningComponent (planning_component/)        ← Cyber RT 入口，Init()/Proc()
   └─> PlanningBase (planning_base/)           ← 抽象基类
         ├─ OnLanePlanning (结构化道路)         ← 默认，结构化道路
         └─ NaviPlanning (导航模式，基于相对地图)
              └─> Planner (planners/)          ← 规划器插件接口
                    ├─ PublicRoadPlanner       ← 默认，场景驱动
                    ├─ LatticePlanner          ← 采样式
                    ├─ RTKReplayPlanner        ← 回放
                    └─ NaviPlanner
```

关键设计点：

- **DependencyInjector**：`PlanningComponent::Init()` 中 `injector_ = std::make_shared<DependencyInjector>()`，作为依赖注入容器缓存 Frame、参考线、历史轨迹等共享数据，解耦各插件之间的直接依赖。
- **PlanningBase::RunOnce()**：核心调度函数，依次完成「轨迹拼接 → Frame 初始化 → 参考线生成 → 调用 Planner→ 合并输出」。
- **插件注册**：通过 `CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN` 宏 + `plugins.xml` 描述动态库路径，运行时按 `scenario_conf.pb.txt` 配置加载。

### 1.3 输入与输出

**输入**（通过 `PlanningComponent` 模板参数与 Reader 订阅）：

- `prediction::PredictionObstacles`：预测模块给出的障碍物未来轨迹
- `canbus::Chassis`：底盘状态（车速、转向、挡位、驾驶模式）
- `localization::LocalizationEstimate`：定位（位姿、速度、加速度）
- `routing::RoutingResponse`：Routing 模块的全局路由（Lane 序列）
- `perception::TrafficLightDetection`：交通灯
- `relative_map::MapMsg`：相对地图（导航模式）
- `storytelling::Stories`：故事讲述模块（场景提示，如接近路口）
- `PlanningCommand`：外部命令（取代旧版 RoutingRequest 的车道级指令）

**输出**：

- `ADCTrajectory`：规划轨迹。其 `repeated apollo.common.TrajectoryPoint trajectory_point` 是核心字段，每个 `TrajectoryPoint` 包含：
  - `path_point`：`x, y, z, theta, kappa, s, dkappa, ddkappa`（位置、朝向、曲率及其一阶/二阶导、弧长）
  - `v`（速度 m/s）、`a`（加速度 m/s²）、`jerk`（加加速度 m/s³）
  - `relative_time`（相对轨迹起点的时间）、`stereo_vision` 等
- 同时输出 `PlanningLearningData`（用于学习训练）、`CommandStatus`、必要时触发 rerouting。

### 1.4 频率与时间一致性

- **Planning 频率**：默认 10Hz（每 100ms 一个规划周期），单周期预算 < 100ms。
- **Control 频率**：100Hz（每 10ms），跟踪 Planning 下发的轨迹。
- **Trajectory Stitching（轨迹拼接）**：因为规划结果真正送达控制器是 `T + dt` 时刻，Planning 不以车辆当前状态为起点，而是：找到上一周期轨迹中与当前定位匹配的点，比较横纵向偏差——偏差小则截取上一周期 `T→T+dt` 段作为本周期起点（保证平滑）；偏差大则用车辆运动学模型外推 `dt` 后的状态作为 Replan 起点。这种机制让控制器看到的轨迹是一段段 `dt` 长度光滑拼接的，避免相邻帧速度/加速度/曲率突变。

---

## 2. Public Road Planner（EM Planner 思想）

PublicRoadPlanner 是 Apollo 默认的开放道路规划器，其算法内核继承自 **EM Planner**（Expectation-Maximization Planner）。Apollo 3.5 起 EM Planner 被重构为"场景驱动"的 PublicRoadPlanner，但核心的"路径/速度解耦 + DP+QP 迭代"思想保留。

### 2.1 三层架构

```
ReferenceLineProvider  ──>  Scenario (ScenarioManager 动态选择)  ──>  Trajectory Generator (Stage/Task)
   (生成平滑参考线)             (LaneFollow/Change/Junction...)           (DP+QP 路径与速度优化)
```

- **ReferenceLineProvider**：依据 Routing 段 + HD Map 生成车道级平滑参考线。
- **Scenario**：由 `ScenarioManager` 根据环境/地图动态选择当前场景，每个场景定义自己的 Stage 流水线。
- **Trajectory Generator**：在 Stage 内串联 Task，完成路径与速度的 DP 粗规划 + QP 精优化。

### 2.2 EM 迭代优化（E-step / M-step）

EM Planner 借用 EM 算法思想，把"轨迹优化"建模为含隐变量（障碍物决策）的迭代求解：

**第一轮 E-step（SL Mapping）**：把静态与低速障碍物投影到 Frenet 坐标系的 SL 图；动态障碍物用上一帧自车轨迹估计交互位置后也映射到 SL。

**第一轮 M-step（Path）**：
- **DP Path（粗规划）**：在自车前方 SL 空间撒 Lattice 点，行间用五次多项式连接；代价函数 = 平滑代价（f'²/f''²/f'''²）+ 障碍物代价（nudge/collision）+ 引导代价（贴近道路中心）。DP 输出一条粗路径并把非凸决策空间转化为凸空间。
- **QP Spline Path（精优化）**：以 DP 路径为参考，在边界约束（f(s), f'(s), f''(s)）与动力学可行性约束下做二次规划，输出光滑路径。

**第二轮 E-step（ST Mapping）**：把所有障碍物（含高速、对向）投影到已规划路径的 ST 图。

**第二轮 M-step（Speed）**：
- **DP Speed**：在 ST 图上对 (s,t) 采样，DP 搜索粗速度曲线（代价 = 障碍物距离 + 空间推进 + 速度/加速度/jerk）。
- **QP Speed**：以 DP 结果开辟凸可行域，二次规划出平滑速度曲线。

最终 `CombinePathAndSpeedProfile` 将 SL 路径与 ST 速度合成为完整 `ADCTrajectory`。

### 2.3 "轻决策"思想

EM Planner 是**轻决策（light decision）**代表：它**不预先对每个障碍物做出"超车/让行/跟随"的硬决策**，而是用一条粗糙可通行轨迹表达自车意图，再基于该轨迹生成凸空间，由 QP 迭代优化"自然规避"障碍物。这与重决策方法形成对比——重决策试图预先确定如何处理每个障碍物，但（1）障碍物与自车交互难以用规则穷尽描述；（2）多障碍物同时阻塞时，满足所有预定决策的轨迹概率大大降低，易导致规划失败。轻决策的优势正是能处理多障碍物复杂场景。

> 注：Apollo 后续版本中，EM 原始的 Spline QP Path 逐渐被 `PIECEWISE_JERK_PATH_OPTIMIZER`（分段 jerk 路径优化）取代，Spline QP Speed 被 `PIECEWISE_JERK_SPEED_OPTIMIZER` 取代，但"DP 开凸 + QP 精优化"的两段式范式不变。

---

## 3. Lattice Planner

Lattice Planner 是 Apollo 早期基于参考线的采样式规划器，思路与 EM Planner 的"迭代优化"截然不同——**穷举采样 + cost 评估 + 筛选**。

### 3.1 Frenet 坐标系与采样

工作在 Frenet (s, l) 坐标系：将车辆位置投影到光滑参考线，s 为纵向弧长，l 为横向偏移，并把 l 设计为 s 的函数（横向运动由纵向运动诱发）。

- **横向采样**：末状态横向偏移取 {-0.5, 0, 0.5}，纵向位移取 {10, 20, 40, 80}，两层循环 + 五次多项式拟合生成横向轨迹簇。
- **纵向采样**：分巡航/跟车超车/停车三类。巡航用四次多项式（速度从 0 到上限、时间 1~8s 遍历）；跟车/超车借助 ST 图在障碍物阴影区上下方分别采样末状态；停车给定停车点采样到达时间。

### 3.2 五次多项式 / 二次规划

- 横向轨迹用**五次多项式**拟合（满足位置/速度/加速度边界条件）。
- 纵向巡航用四次多项式，跟车/超车/停车用五次多项式。
- 将所有横向 × 纵向轨迹两两配对，二维合成为完整候选轨迹。

### 3.3 cost function

每条候选轨迹的 cost 综合六项：

1. **到达目的 cost**：有停车指令时大速度 cost 高，无停车指令时小速度 cost 高（参考速度曲线）。
2. **横向偏移 cost**：促使车辆沿道路中心行驶。
3. **碰撞 cost**：轨迹在 ST 图与障碍物阴影重叠则 cost 高。
4. **纵向 jerk cost**：加加速度（加速度导数）积分，保证舒适。
5. **横向 jerk cost**：横向加加速度积分。
6. **中心偏离 cost**：与参考线纵向对齐。

选出 cost 最低且通过**物理限制检测**（加减速度上限）与**碰撞检测**的轨迹作为输出，否则考察下一条。

### 3.4 与 EM Planner 的差异

| 维度 | Lattice Planner | EM Planner / Public Road |
|------|----------------|--------------------------|
| 范式 | 采样 + cost 评估 + 筛选 | DP 开凸 + QP 迭代优化 |
| 决策方式 | 隐式（cost 自然偏向） | 轻决策（DP 给粗决策，QP 精化） |
| 路径/速度 | 横纵向同时采样合成 | 路径/速度解耦，分别优化 |
| 计算量 | 候选轨迹多，评估开销大 | DP+QP 分层，可控 |
| 场景适配 | 结构化简单场景 | 复杂多障碍物、多车道场景 |
| 当前地位 | 保留但非默认 | 默认 PublicRoadPlanner |

---

## 4. Open Space Planner

Open Space Planner 专为**非结构化开放空间**（泊车、起步、掉头、U-turn）设计，因这些场景下结构化道路假设失效。

### 4.1 整体流程（4 个 Task）

配置于 `valet_parking_config.pb.txt`：

```
stage_config: VALET_PARKING_PARKING
  task_type: OPEN_SPACE_ROI_DECIDER        // 1. 生成可行驶区域 ROI
  task_type: OPEN_SPACE_TRAJECTORY_PROVIDER // 2. 规划无碰撞粗轨迹 + 平滑
  task_type: OPEN_SPACE_TRAJECTORY_PARTITION // 3. 按前进/倒车分割轨迹
  task_type: OPEN_SPACE_FALLBACK_DECIDER    // 4. 碰撞检测与回退停车
```

### 4.2 Hybrid A*（搜索树 + Reeds-Shepp）

- **Hybrid A\***：在普通 A* 基础上把二维节点 `(x,y)` 扩展为三维节点 `(x,y,θ)`，对前轮转角采样得到不同曲率半径的弧线段，保证路径满足车辆运动学（`tan(δ)=L/R`）。
- **启发函数**：先用 `GridAStarHeuristicGenerator` 基于动态规划求解每个二维节点的代价作为启发。
- **Reeds-Shepp 曲线**：1990 年 Reeds & Shepp 证明，给定起终点可用固定半径圆弧与直线组合连接，最短路径必在 48 种组合之中。Apollo 在每次弹出最小代价节点时调用 `AnalyticExpansion` 尝试用 RS 曲线解析扩展到终点，成功即退出搜索。
- **输出**：`HybridAStartResult {x, y, phi, v, a, steer, accumulated_s}`，作为后续优化的 warm start。

### 4.3 OBCA 优化（Hybrid A* 粗轨迹 → 平滑无碰撞轨迹）

Hybrid A* 轨迹存在曲率突变、不满足运动学问题，需 OBCA 平滑：

- **OBCA（Optimization-Based Collision Avoidance）**：基于 MPC 建模，状态变量 `(x,y,v,φ)`，用**超平面分离条件**将障碍物约束转化为可微约束，实现横纵向联合规划，可加入障碍物约束并产生满足运动学的轨迹。
- **TDR-OBCA**：Apollo 改进版（论文 arXiv:2009.11345），引入 temporal profile 与对偶变量作为 warm start，把原问题分解为对偶变量求解 + 主问题求解，用 **IPOPT** 求解。
- **衍生算法**：`DISTANCE_APPROACH_IPOPT_FIXED_TS`（固定采样时间）、`DISTANCE_APPROACH_IPOPT`（可变采样时间）、`DISTANCE_APPROACH_IPOPT_RELAX_END`（终点松弛）。
- **DL-IAPS**（Dual Loop Iterative Anchoring Path Smoothing）：另一条路径平滑支线，双循环迭代锚定平滑，适用于 OBCA 收敛困难的场景。

### 4.4 应用场景

主要服务于 `PARK_AND_GO`（起步）、`PULL_OVER`（靠边停车）、`VALET_PARKING`（自主泊车）等含泊车/倒车的场景。

---

## 5. Scenario / Stage / Task 三级架构

### 5.1 三级定义

| 层级 | 作用 | 示例 |
|------|------|------|
| **Scenario** | 第一层状态机，处理特定道路场景的完整逻辑，由 `ScenarioManager` 切换 | LaneFollow、ValetParking、PullOver、ParkAndGo、TrafficLightProtected/Unprotected、StopSign、YieldSign、BareIntersection、Emergency、UTurn |
| **Stage** | Scenario 的子步骤（第二层状态机），完成阶段性目标，由 Scenario 切换 | StageApproachingParkingSpot、StageParking、PullOverStageApproach、LaneFollowDefaultStage |
| **Task** | Stage 中的具体算法单元，实现单一功能 | PathBoundsDecider、PiecewiseJerkPathOptimizer、SpeedBoundsDecider、OpenSpaceTrajectoryProvider |

### 5.2 ScenarioManager 动态选择

`ScenarioManager`（`planners/public_road/scenario_manager.cc`）在 `Init()` 中读取配置、加载所有场景插件；每个周期 `Update(planning_start_point, frame)` 通过各 Scenario 的 `IsTransferable()` 判断是否切入新场景。场景切换基于条件判断（是否检测到停车位、是否完成变道、是否接近路口等）。

### 5.3 配置驱动 .pb.txt

场景与阶段流水线完全由 protobuf 配置驱动，例如 `lane_follow_config.pb.txt`：

```
scenario_type: LANE_FOLLOW
stage_type: LANE_FOLLOW_DEFAULT_STAGE
stage_config: {
  stage_type: LANE_FOLLOW_DEFAULT_STAGE
  enabled: true
  // 路径规划
  task_type: LANE_CHANGE_DECIDER
  task_type: PATH_REUSE_DECIDER
  task_type: PATH_LANE_BORROW_DECIDER
  task_type: PATH_BOUNDS_DECIDER
  task_type: PIECEWISE_JERK_PATH_OPTIMIZER
  task_type: PATH_ASSESSMENT_DECIDER
  task_type: PATH_DECIDER
  task_type: RULE_BASED_STOP_DECIDER
  // 速度规划
  task_type: SPEED_BOUNDS_PRIORI_DECIDER
  task_type: SPEED_HEURISTIC_OPTIMIZER
  task_type: SPEED_DECIDER
  task_type: SPEED_BOUNDS_FINAL_DECIDER
  task_type: PIECEWISE_JERK_SPEED_OPTIMIZER
  task_type: RSS_DECIDER
}
```

`_DECIDER` 结尾为决策类 Task，`_OPTIMIZER` 结尾为优化类 Task。新增场景只需注册新 Scenario + 配置文件，无需改核心框架。

### 5.4 Scenario/Stage/Task 流程图（文字）

```
┌───────────────────────────────────────────────────────────────────────┐
│ PlanningComponent::Proc()  (10Hz)                                      │
│   订阅: PredictionObstacles / Chassis / Localization / Routing / TL    │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────────────┐
│ TrajectoryStitcher::ComputeStitchingTrajectory()                       │
│   偏差小→截取上一周期 T+dt 段; 偏差大→运动学外推 Replan 起点            │
└───────────────────────────────┬───────────────────────────────────────┘
                                ▼
┌───────────────────────────────────────────────────────────────────────┐
│ OnLanePlanning::RunOnce()                                              │
│   1. Frame 初始化 (障碍物、交通规则生成 virtual obstacle)               │
│   2. ReferenceLineProvider::GetReferenceLines() (Routing+HDMap→平滑)   │
│   3. PublicRoadPlanner::Plan()                                         │
└───────────────────────────────┬───────────────────────────────────────┘
                                ▼
┌───────────────────────────────────────────────────────────────────────┐
│ ScenarioManager::Update()  ──选择当前 Scenario──>  scenario_           │
│   场景池: LaneFollow / LaneChange / Junction / PullOver / Parking /    │
│           Stop / Yield / ValetParking / ParkAndGo / UTurn / Emergency  │
└───────────────────────────────┬───────────────────────────────────────┘
                                ▼
┌───────────────────────────────────────────────────────────────────────┐
│ Scenario::Process(planning_start_point, frame)                         │
│   ↓ Stage 流水线 (由 .pb.txt 定义顺序)                                  │
│   ┌─────────────────────────────────────────────────────────────┐     │
│   │ Stage_1::Process()  → 依次执行 Task 链                          │     │
│   │   Task 通过 Frame/ReferenceLineInfo 共享上下文                  │     │
│   │   Stage 完成条件满足 → 切换 Stage_2                            │     │
│   └─────────────────────────────────────────────────────────────┘     │
│   ... 所有 Stage 完成 → Scenario 完成 → ScenarioManager 再选择         │
└───────────────────────────────┬───────────────────────────────────────┘
                                ▼
        ┌───────────────────────┴───────────────────────┐
        ▼                                               ▼
【结构化道路 Stage (LaneFollow)】            【开放空间 Stage (ValetParking)】
 Task 链:                                     Task 链:
  PATH_LANE_BORROW_DECIDER                     OPEN_SPACE_ROI_DECIDER
  PATH_BOUNDS_DECIDER                          OPEN_SPACE_TRAJECTORY_PROVIDER
  PIECEWISE_JERK_PATH_OPTIMIZER                 (Hybrid A* + RS + OBCA/DL-IAPS)
  PATH_ASSESSMENT_DECIDER                      OPEN_SPACE_TRAJECTORY_PARTITION
  PATH_DECIDER                                 OPEN_SPACE_FALLBACK_DECIDER
  RULE_BASED_STOP_DECIDER
  SPEED_BOUNDS_PRIORI_DECIDER
  SPEED_HEURISTIC_OPTIMIZER (DP)
  SPEED_DECIDER
  SPEED_BOUNDS_FINAL_DECIDER
  PIECEWISE_JERK_SPEED_OPTIMIZER (QP)
        │                                               │
        └───────────────────────┬───────────────────────┘
                                ▼
┌───────────────────────────────────────────────────────────────────────┐
│ Stage: CombinePathAndSpeedProfile   (SL 路径 + ST 速度 → ADCTrajectory) │
│ PlanningBase 填充 header/调试信息 → planning_writer_->Write()           │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 6. Reference Line Provider

### 6.1 生成流程

`ReferenceLineProvider` 收集 Routing、HD Map、定位信息，整合生成基于车道中心线的平滑参考线：

1. **GetRouteSegments**：从 PncMap 依据车辆位置取短期 RouteSegments（Lane 序列片段）。
2. **SmoothRouteSegments**：`SmoothRouteSegments(segments, reference_line)` 把 RouteSegments 转为 `hdmap::Path` 再平滑。
3. **GetAnchorPoints**：对引导线等距降采样得到锚点（`AnchorPoint{point, helper, enforce}`）。
4. **SmoothReferenceLine**：调用配置的 Smoother 在锚点上做平滑，输出 `ReferenceLine`（含 `map_path` 与 `speed_limit` 等）。

是否新参考线由 `is_new_routing` 标志触发；非新路由时复用上一帧参考线做增量更新以节省算力。

### 6.2 三种 Smoother

`ReferenceLineProvider` 构造函数依据 `smoother_config` 选择 smoother：

| Smoother | 方法 | 特点 |
|----------|------|------|
| **QpSplineReferenceLineSmoother** | 5 次多项式样条 + 二次规划 | Apollo 默认；曲率切向连续，适合 HD Map 车道中心线；对样条节点数敏感 |
| **SpiralReferenceLineSmoother** | 回旋线（Clothoid）样条 | 曲率线性变化，物理意义最贴近真实道路；求解复杂 |
| **DiscretePointsReferenceLineSmoother** | 离散点优化，含两个子方法 | 适合众包/SLAM 带毛刺的引导线 |

`DiscretePointsReferenceLineSmoother` 两个子方法：

- **CosTheta（cos_theta）**：代价 = 参考点距离代价 + (−cosθ 平滑代价，连续三点夹角越小越平滑) + 总长度代价。用 IPOPT 求解 NLP，可加松弛变量。
- **FEM_POS_DEVIATION**：代价 = 参考点距离代价 + (二阶差分²，即 `x_i + x_{i+2} − 2x_{i+1}` 的模平方，衡量三点偏离直线的程度) + 总长度代价 + 松弛变量惩罚。可转为 QP 用 OSQP 高效求解。

两者物理意义都是让连续三点尽量共线（平滑），区别在 CosTheta 用夹角余弦、FEM 用二阶差分；FEM 更易凸化、求解更快。

---

## 7. 速度规划

Apollo 将路径与速度解耦：路径规划面向静态环境（道路、静止/低速障碍物），速度规划面向动态环境（中/高速障碍物）。

### 7.1 ST 图与采样

速度规划在 ST 图（s 沿已规划路径方向，t 为时间）进行。不同场景的 ST 投影：匀速行驶（斜线）、先行驶后停车（斜线接水平）、跟随前车（贴近障碍物阴影下边界）、跟车刹停、后方跟行等。采样在 t 方向固定间隔（`unit_t=1.0s`），s 方向先密后疏（近端 `dense_unit_s=0.1`，远端 `sparse_unit_s=1.0`）。

### 7.2 DP + QP 两段式

- **SPEED_BOUNDS_PRIORI_DECIDER**：产生速度可行驶边界（非凸区域）。
- **SPEED_HEURISTIC_OPTIMIZER（DP）**：状态转移代价 = 速度代价 + 加速度代价 + jerk 代价；节点代价 = 障碍物 cost（安全距离内外分级）+ 距离 cost（推进到目标）+ 状态转移 cost。DP 输出粗糙速度曲线并开辟凸空间。
- **SPEED_DECIDER**：依据粗规划曲线在障碍物上下方做决策（超车/让行/跟随）。
- **SPEED_BOUNDS_FINAL_DECIDER**：在障碍物上方或下方确定最终可行域边界。
- **PIECEWISE_JERK_SPEED_OPTIMIZER（QP） / PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER（NLP）**：二选一，平滑速度曲线。

### 7.3 Piecewise Jerk Speed Optimizer

**QP 版（OSQP）**：

- **优化变量**：每个时间点 `i` 的 `(s_i, v_i, a_i)`， jerk 用相邻加速度差分 `j_i = (a_{i+1} − a_i)/Δt`。
- **目标函数**：`(s_i − s_ref)²`（贴近 DP 参考/巡航速度）+ `w_a·a_i²` + `w_j·j_i²`（加速度、jerk 平滑）+ 起点惩罚。
- **约束**：边界不等式（s/v/a 上下界，来自 ST 可行域与限速）、速度连续性等式（`v_{i+1} = v_i + a_i·Δt`）、位置连续性等式（`s_{i+1} = s_i + v_i·Δt + 0.5·a_i·Δt²`）、起点约束。整体为凸 QP，用 **OSQP** 求解。

**NLP 版（IPOPT）**：当 QP 的线性化约束不足以表达曲率限速、CDC（centripetal/deceleration constraint）等非线性关系时，用非线性规划，把曲率约束 `a_lat = κ·v²` 等显式加入，用 **IPOPT** 求解。两者二选一，NLP 更精细但更慢。

---

## 8. Apollo 9.0 PnC 2.0 与 10.0 演进

### 8.1 PnC 2.0 插件化

9.0 的 PnC 2.0 把 Planning 与 Control 一并插件化：

- **双状态机**：Scenario（Top Layer，ScenarioManager 切换）+ Stage（Bottom Layer，Scenario 切换），Task 为 Stage 内原子单元。
- **插件接口**：`planning_interface_base/` 定义 Scenario/Stage/Task/Planner/TrafficRule 抽象基类，所有实现都是独立 `.so`，通过 `plugins.xml` + `CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN` 注册。
- **DependencyInjector**：取代旧的 Frame 内全局状态，统一注入共享数据。
- **Scenario-free 趋势**：社区讨论指出，学习类规划方法接入 Apollo 时，既可挂为独立 Cyber Component，也可作为 Planning 内部 Planner Plugin；这暗示 PnC 2.0 在为"去场景化"的端到端/学习式规划预留接入位。

### 8.2 神经网络辅助规划与 ADFM

- **Learning Model 接入**：Apollo 支持 planning learning model，将规划数据写入 `PlanningLearningData` 用于离线训练；在线可作为候选轨迹生成器或新增 Planner。
- **ADFM（Autonomous Driving Foundation Model）**：2024 年 5 月发布，全球首个支持 L4 的自动驾驶大模型，可通过全链路模型化综合输出多元环境信息、**直接生成执行轨迹**。10.0 搭载 ADFM，标志 Apollo 从"规则+优化"向"大模型辅助/端到端"演进，但结构化道路仍以 PublicRoadPlanner 为安全兜底。

---

## 9. 关键 Task 链详解（LaneFollow 场景）

| Task | 类型 | 职责 |
|------|------|------|
| **LANE_CHANGE_DECIDER** | 决策 | 依据 Routing 是否需要换道，输出换道状态 |
| **PATH_REUSE_DECIDER** | 决策 | 判断能否复用上一周期路径（省算力） |
| **PATH_LANE_BORROW_DECIDER** | 决策 | 判断是否需要借道绕障（`IsNecessaryToBorrowLane`：前方有静态/低速阻塞且满足借道条件），只判定条件，不决定最终轨迹 |
| **PATH_BOUNDS_DECIDER** | 决策 | 依据借道信息、道路宽度生成路径边界；分 fallback / pull over / lane change / regular 四种场景计算 SL 边界 |
| **PIECEWISE_JERK_PATH_OPTIMIZER** | 优化 | 在路径边界内做分段 jerk QP，输出平滑路径（l(s), l'(s), l''(s)） |
| **PATH_ASSESSMENT_DECIDER** | 决策 | 评估路径安全性（碰撞、边界、曲率），选出最优路径 |
| **PATH_DECIDER** | 决策 | 对每个障碍物给出 nudge/overtake/ignore 决策，写入 path_decider_status |
| **RULE_BASED_STOP_DECIDER** | 决策 | 依据交规（红灯、停止线、人行道）决策停车点 |
| **SPEED_BOUNDS_PRIORI_DECIDER** | 决策 | 生成先验速度可行驶边界（非凸） |
| **SPEED_HEURISTIC_OPTIMIZER** | 优化（DP） | ST 图 DP 搜索粗糙速度曲线，开凸空间 |
| **SPEED_DECIDER** | 决策 | 依据粗规划在障碍物上下方做超车/让行决策 |
| **SPEED_BOUNDS_FINAL_DECIDER** | 决策 | 确定最终速度可行域边界 |
| **PIECEWISE_JERK_SPEED_OPTIMIZER** | 优化（QP） | OSQP 求解平滑速度曲线（也可选 NLP 版） |
| **RSS_DECIDER** | 决策 | RSS 安全模型校验 |

最终 `CombinePathAndSpeedProfile` 合成输出。

---

## 10. 三种规划器对比表

| 维度 | EM Planner / Public Road | Lattice Planner | Open Space Planner |
|------|--------------------------|-----------------|--------------------|
| 适用场景 | 结构化道路，复杂多障碍物 | 结构化道路，简单场景 | 非结构化开放空间（泊车/起步/掉头） |
| 坐标系 | Frenet (SL/ST) | Frenet (s,l) | 笛卡尔 (x,y,θ) |
| 核心范式 | DP 开凸 + QP 迭代优化（E-step/M-step） | 采样 + cost 评估 + 筛选 | Hybrid A* 搜索 + OBCA/DL-IAPS 优化 |
| 路径/速度 | 解耦（先路径后速度） | 横纵向同时采样合成 | 横纵向联合（MPC 式） |
| 决策方式 | 轻决策（迭代自然规避） | 隐式（cost 偏向） | 搜索式（RS 曲线解析扩展） |
| 关键数学工具 | DP、QP（OSQP）、五次多项式 | 五次/四次多项式、cost function | Hybrid A*、Reeds-Shepp、IPOPT、超平面分离 |
| 倒车支持 | 否 | 否 | 是（RS 曲线含方向切换） |
| 计算复杂度 | 中（分层可控） | 高（候选多） | 高（搜索+非线性优化） |
| 当前地位 | 默认 PublicRoadPlanner | 保留，非默认 | 泊车/起步专用 |
| 输出 | ADCTrajectory（s/t/v/a/θ/κ/jerk） | ADCTrajectory | ADCTrajectory（含倒车段） |

---

## 11. AuroraDrive 迁移建议

### 11.1 AuroraDrive 当前规划栈现状

经核查 AuroraDrive 源码（`cpp/include/ad/`），当前规划栈为极简的"A* + Pure Pursuit"方案：

- **路径规划**：`path_planner.h` 的 A* 算法（Euclidean 启发式），在路网图上搜索全局路径，输出 waypoint 序列。
- **道路引导**：`simulator.h::compute_road_guidance()`（约 443–518 行）直接拼接道路中心点：
  - 找最近道路 → 在 `map_.road_center_ptr` 上找最近点（偏好前方点）→ 取该点起 ~100 个中心点 → 道路尽头时在 60m 半径内查询连通道路并循环拼接，直到凑够 200 点。
  - **关键缺陷：无任何平滑处理**，直接把离散道路中心点塞入 `out`（`[x0,y0,x1,y1,...]`），路口拼接处、道路切换处存在折角与不连续。
- **横向控制**：`controller.h::PurePursuit`（48–134 行）在中心点序列上找预瞄点，`δ = atan2(2·L·sin(α), l_d)`；含动态预瞄（`lookahead = k·v`，8–25m）与转圈 bug 修复（|α|>π/2 时返回 ±max_steer）。
- **纵向控制**：`PIDController` 速度闭环（目标 40km/h）+ `curve_safe_speed`（`v=√(μ·g·r)`）弯道限速。
- **频率**：24Hz 单线程主循环（物理 + 渲染 + 广播合一）。
- **决策**：硬编码 if-else（`brake/follow/cruise/hold`），无场景/阶段概念。

### 11.2 与 Apollo 的差距

| 维度 | AuroraDrive 现状 | Apollo |
|------|------------------|--------|
| 参考线 | 原始道路中心点，无平滑 | ReferenceLineProvider + QpSpline/Spiral/DiscretePoints 平滑 |
| 路径规划 | A* 全局 + 中心点跟随 | DP+QP 分层，Frenet 边界内 jerk 优化 |
| 速度规划 | PID 定速 + 弯道限速 | ST 图 DP+QP，考虑动态障碍物 |
| 决策 | 硬编码 if-else | Scenario/Stage/Task 三级 + 双状态机 |
| 障碍物交互 | 简单 front_dist 判断 | 预测轨迹 + nudge/overtake/yield 决策 |
| 轨迹表达 | (x,y) 点序列 | ADCTrajectory（s/t/v/a/θ/κ/jerk） |
| 频率 | 24Hz 单线程 | Planning 10Hz / Control 100Hz 分离 |
| 平滑性 | 拼接折角、突变 | 轨迹拼接 + QP 平滑 + jerk 约束 |

### 11.3 AuroraDrive 规划升级路线图

升级遵循"由易到难、保兜底"原则，分四阶段，每阶段都保持可回退：

**阶段 0（地基，1–2 周）：轨迹表达升级**
- 将 `compute_road_guidance` 的 `(x,y)` 序列升级为带 `s, theta, kappa, v, a, relative_time` 的 `TrajectoryPoint` 序列。
- 引入 Planning/Control 频率分离意识：即便仍 24Hz，也区分"规划帧"与"控制帧"，控制帧在规划帧间做插值。
- 收益：为后续所有优化提供统一数据载体，对齐 Apollo `ADCTrajectory` 语义。

**阶段 1（参考线平滑，1–2 周）：消灭拼接折角**
- 在 `compute_road_guidance` 拼接后增加**离散点平滑**（直接移植 Apollo `DiscretePointsReferenceLineSmoother` 的 FEM_POS_DEVIATION 子方法，因其可凸化为 QP 用 OSQP 求解，C++ 易嵌入 header-only）。
- 代价函数 = 参考点距离 + 二阶差分²（三点共线惩罚）+ 长度，约束为锚点边界。
- 收益：消除路口/换路折角，Pure Pursuit 预瞄不再抖动，舒适度立竿见影提升。这是性价比最高的一步。

**阶段 2（路径优化，2–4 周）：Frenet 化 + Piecewise Jerk Path**
- 引入 Frenet 坐标系（基于平滑后的参考线投影），把 AuroraDrive 已有的 A* 全局路径降级为"Routing"角色。
- 在 `path_planner.h` 之后新增 `PathBoundsDecider`（依据道路宽度 + 障碍物生成 l(s) 边界）+ `PiecewiseJerkPathOptimizer`（QP 求 l(s) 平滑路径）。
- 障碍物可先用 AuroraDrive 已有的 `front_dist`/交通流信息简化建模。
- 收益：路径自带曲率连续与 jerk 约束，告别"中心点直跟"。

**阶段 3（速度规划，3–5 周）：ST 图 + Piecewise Jerk Speed**
- 在规划路径上构建简化 ST 图（AuroraDrive 交通流 IDM/MOBIL 已提供前车预测，可直接映射为 ST 障碍块）。
- 实现 `SpeedBoundsDecider`（ST 可行域）+ `SpeedHeuristicOptimizer`（DP 粗规划）+ `PiecewiseJerkSpeedOptimizer`（QP 平滑，OSQP）。
- 用此取代当前 PID 定速，PID 退化为控制层跟踪器。
- 收益：实现跟车、让行、停车等纵向决策，从"定速巡航"进化到"交通流自适应"。

**阶段 4（架构重构，4–8 周）：轻量 Scenario/Stage/Task**
- 引入精简版三级架构：`ScenarioManager` + 若干 Scenario（LaneFollow / Junction / Parking），每个 Scenario 含 Stage，Stage 串 Task。
- 配置驱动（可用 JSON 替代 .pb.txt，避免引入 protobuf 重依赖）。
- 新增 Open Space 场景（泊车）：移植 Hybrid A* + Reeds-Shepp（AuroraDrive 已有 A* 基础，扩展为 3D 节点即可），OBCA 可选（先用 DL-IAPS 简化版）。
- 收益：架构对齐 Apollo，具备场景扩展能力，为未来接入学习模型留接口。

**阶段 5（远期，可选）：学习辅助 / 端到端**
- 复用 AuroraDrive 已有的 DAgger 在线打标框架（MEMORY.md 记载的"纯规则→学习模型→人机共驾"级联），把规则规划栈输出作为教师信号。
- 可参考 Apollo PnC 2.0 的 Plugin 接入位，把学习模型作为候选 Planner 或轨迹生成器。
- 收益：向 ADFM 式大模型辅助演进，不破坏安全兜底。

### 11.4 迁移优先级建议

1. **先做阶段 0 + 阶段 1**：投入小、收益大，直接解决 `compute_road_guidance` 无平滑的核心痛点，且不改变现有控制链路。
2. **再做阶段 2 + 阶段 3**：逐步用 QP 优化替代几何跟随与定速，是"仿真可信度"跃升的关键。
3. **阶段 4 视需求推进**：若 AuroraDrive 仅作仿真/RL 训练环境，轻量 Scenario 即可；若要演示完整自动驾驶能力，则值得投入。
4. **依赖引入**：OSQP（QP 求解）是阶段 1–3 的共同依赖，建议优先集成；IPOPT 仅在需要 NLP（非线性速度规划或 OBCA）时引入。

---

## 12. 结论

Apollo Planning 的核心设计哲学可归纳为三点：（1）**参考线中心化**——所有规划在平滑参考线的 Frenet 框架下进行；（2）**DP 开凸 + QP 精化**——用 DP 解决非凸决策、用 QP 保证平滑与实时；（3）**场景驱动的插件化**——Scenario/Stage/Task 三级解耦，配置驱动，易于扩展。AuroraDrive 当前"A* + Pure Pursuit + 无平滑中心点"的方案在仿真原型阶段足够，但要在轨迹质量、交通流交互、场景覆盖上接近产品级，应优先补齐"参考线平滑"与"DP+QP 路径/速度优化"两块短板，再逐步引入场景化架构，最终为学习式规划预留接口。

---

## 参考资料（部分）

- ApolloAuto/apollo GitHub `modules/planning` 目录（master / 11.0）
- CSDN《Apollo 10.0 Public Road Planner 详解》系列（qq1240268067）
- CSDN《Apollo星火计划学习笔记——速度规划/开放空间规划》（sinat_52032317）
- CSDN《Baidu Apollo EM Motion Planner 论文笔记》（sinat_52032317）
- CSDN《Apollo 参考线平滑代码解析》（renyushuai900）
- CSDN《Apollo6.0 ReferenceLine Smoother 解析与子方法对比》（xl_courage）
- CSDN《Apollo 9.0 速度二次规划 piecewise jerk speed optimizer》（waingai1999）
- CSDN《Apollo 项目的场景化实现机制详解》（u010632343）
- CSDN《Apollo9.0 Planning2.0 OnLanePlanning 代码解析》（nn243823163）
- chuxin911.com《Apollo Open Space Planner 介绍 1/2》《轨迹拼接模块研读》
- Apollo 官方文档（developer.apollo.auto）
- Apollo ADFM 相关报道（2024 Apollo Day）

---

> **实际工具调用次数**：WebSearch 29 次 + WebFetch 24 次 = **53 次**（WebSearch/WebFetch 内部工具调用）；另辅以本地 SearchCodebase 1 次、Grep 1 次、Read 7 次用于核对 AuroraDrive 源码。本报告字数约 6200 字（不含表格内符号）。
