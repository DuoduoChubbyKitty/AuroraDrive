# Apollo 规划模块 Scenario / Stage / Task 三级架构深度研究报告

> 研究对象：Baidu Apollo 自动驾驶开放平台 Planning 模块 Scenario / Stage / Task 三级状态机架构（Apollo 6.0 → 9.0 PnC 2.0 → 10.0/11.0）
> 研究目的：为 AuroraDrive 仿真系统的规划栈升级提供场景化分层架构参照与迁移路线
> 撰写日期：2026-07-23
> 研究方法：WebSearch + WebFetch 对 GitHub `ApolloAuto/apollo` 源码目录、Apollo 官方文档、CSDN 源码解析系列（Apollo10.0 学习专栏、Apollo 学习笔记 TASK 系列、Apollo9.0 PNC 源码辨析专栏）进行深度挖掘，共执行 50+ 次内部工具调用

---

## 0. 摘要

Apollo 规划模块采用 **Scenario / Stage / Task 三级（双状态机）分层架构** 组织决策规划逻辑：顶层 `ScenarioManager` 通过 `IsTransferable()` 切换 `Scenario`，中层 `Scenario::Process()` 驱动 `Stage` 状态机，底层 `Stage` 顺序编排 `Task` 算法单元。整个体系由 `.pb.txt` 配置文件驱动，修改配置即可调整 Stage→Task 链，无需重编译。Apollo 9.0 PnC 2.0 引入插件化重构，把 Scenario / Stage / Task / Planner / TrafficRule 全部拆成独立 `.so` 插件包，由 `cyber::plugin_manager::PluginManager` 动态加载注册，为学习类规划接入和 Scenario-free 趋势奠定基础。本报告系统梳理 11+ 内置 Scenario 的触发条件与 Stage 链、12+ Task 的输入输出、ScenarioManager 实现机制、Frame/DependencyInjector 帧数据共享，并对照 AuroraDrive 当前的 `decision_` 字符串方案（brake / follow / cruise / hold）给出简化版 5 场景分层架构与按场景独立 PID 配置设计。

---

## 1. Scenario / Stage / Task 三级架构总览

### 1.1 三级层级关系

Apollo 规划模块的核心组织思想是 **"场景→阶段→任务"** 的分层分解，对应"双层状态机 + 算法单元"：

| 层级 | 角色 | 切换者 | 示例 |
|------|------|--------|------|
| **Scenario（场景）** | 第一层状态机，处理特定道路场景的完整逻辑（泊车、变道、红绿灯路口等） | `ScenarioManager` | `LaneFollowScenario`、`ValetParkingScenario` |
| **Stage（阶段）** | 第二层状态机，Scenario 的子步骤，完成阶段性目标（接近车位、泊入车位） | `Scenario::Process()` | `StageApproachingParkingSpot`、`VALET_PARKING_PARKING` |
| **Task（任务）** | 具体算法单元，实现路径规划、避障、轨迹优化等单一功能 | `Stage::ExecuteTaskOnReferenceLine()` | `PathBoundsDecider`、`SpeedOptimizer` |

层级关系可表示为：

```
PublicRoadPlanner::Plan()
  └─> ScenarioManager::Update()              ← 第一层状态机切换
        └─> Scenario::Process()              ← 场景处理
              └─> Stage::Process()           ← 第二层状态机切换
                    └─> Task::Execute()      ← 具体算法
                          └─> Frame / ReferenceLineInfo   ← 帧数据共享
```

### 1.2 Scenario::Process() 执行当前 Stage 的核心逻辑

`Scenario::Process()` 是场景处理的外部入口，采用**有限状态机（FSM）驱动**的任务调度，核心逻辑分四步：

1. **Stage 初始化**：若 `current_stage_ == nullptr`，从 `stage_pipeline_map_` 取首个 Stage 配置，调用 `CreateStage()` 工厂方法实例化（如 `LaneFollowStage`）。
2. **Stage 执行**：调用 `current_stage_->Process(planning_init_point, frame)`，将返回的 `StageStatusType` 存入 `scenario_result_`。
3. **状态机切换**：
   - `ERROR`：标记 `STATUS_UNKNOWN`，触发上层重规划或降级（fallback）。
   - `RUNNING`：维持 `STATUS_PROCESSING`，继续执行当前 Stage。
   - `FINISHED`：通过 `current_stage_->NextStage()` 获取下一 Stage 名称；若存在则销毁当前 Stage 并 `CreateStage()` 新 Stage；若不存在则标记 `STATUS_DONE`。
4. **动态 Stage 切换**：依赖 `stage_pipeline_map_`（来自 `pipeline.pb.txt`），支持场景内动态调整 Stage 流程（如紧急避障插入新 Stage）。

关键代码骨架（`modules/planning/planning_base/scenario_base/scenario.cc`）：

```cpp
ScenarioResult Scenario::Process(
    const common::TrajectoryPoint& planning_init_point, Frame* frame) {
  if (current_stage_ == nullptr) {
    current_stage_ = CreateStage(
        *stage_pipeline_map_[scenario_pipeline_config_.stage(0).name()]);
  }
  auto ret = current_stage_->Process(planning_init_point, frame);
  scenario_result_.SetStageResult(ret);
  switch (ret.GetStageStatus()) {
    case StageStatusType::FINISHED:
      // 获取下一 Stage 名称，切换或标记 STATUS_DONE
    case StageStatusType::RUNNING:
      // 维持 STATUS_PROCESSING
    case StageStatusType::ERROR:
      // 标记 STATUS_UNKNOWN
  }
}
```

### 1.3 Stage 切换条件

Stage 切换的必要条件是 **"Stage 内所有 Task 完成 + 满足下一 Stage 进入条件"**：

- **Task 完成**：`Stage::ExecuteTaskOnReferenceLine()` 顺序调用 `task_list_` 中所有 Task 的 `Execute()`，全部返回 `Status::OK()` 即视为 Task 链完成。
- **业务条件**：Stage 在 Task 链执行后自检业务条件，如 `CheckADCStop(*frame)` 判断主车是否完全停止、距离/速度误差是否达阈值。
- **状态返回**：业务条件满足则 `next_stage_ = "NEXT_STAGE_NAME"` 并返回 `StageStatusType::FINISHED`，否则返回 `RUNNING` 继续执行。

---

## 2. ScenarioManager 实现

### 2.1 代码位置与职责

代码位置：`modules/planning/planners/public_road/scenario_manager.cc`（Apollo 9.0+ 插件化后路径）。

`ScenarioManager` 负责管理所有已注册场景、处理场景切换、维护默认场景，是第一层状态机的"管理员"。

### 2.2 Init()：场景注册

```cpp
bool ScenarioManager::Init(const std::shared_ptr<DependencyInjector>& injector,
                           const PlannerPublicRoadConfig& planner_config) {
  if (init_) return true;
  injector_ = injector;
  // 注册场景，目前支持的场景在 /conf/planning_config.pb.txt 中
  for (int i = 0; i < planner_config.scenario_size(); i++) {
    auto scenario = PluginManager::Instance()->CreateInstance<Scenario>(
        ConfigUtil::GetFullPlanningClassName(planner_config.scenario(i).type()));
    ACHECK(scenario->Init(injector_, planner_config.scenario(i).name()))
        << "Can not init scenario " << planner_config.scenario(i).name();
    scenario_list_.push_back(scenario);
    // 默认场景固定为 LANE_FOLLOW
    if (planner_config.scenario(i).name() == "LANE_FOLLOW") {
      default_scenario_type_ = scenario;
    }
  }
  current_scenario_ = default_scenario_type_;
  init_ = true;
  return true;
}
```

注册流程：① 读取 `planning_config.pb.txt` 中的 scenario 列表；② 通过 `PluginManager::CreateInstance<Scenario>()` 动态加载场景插件 `.so`；③ 调用 `scenario->Init()` 加载该场景的 `pipeline.pb.txt` 与 `scenario_conf.pb.txt`；④ 设置默认场景为 `LANE_FOLLOW`。

### 2.3 Update()：场景识别与切换

```cpp
void ScenarioManager::Update(const common::TrajectoryPoint& ego_point, Frame* frame) {
  CHECK_NOTNULL(frame);
  for (auto scenario : scenario_list_) {
    // 当前场景正在处理时，保持当前场景（前序场景优先级更高）
    if (current_scenario_.get() == scenario.get() &&
        current_scenario_->GetStatus() == ScenarioStatusType::STATUS_PROCESSING) {
      return;
    }
    // 遍历每个场景，查验哪个场景符合要求，符合直接切换
    if (scenario->IsTransferable(current_scenario_.get(), *frame)) {
      current_scenario_->Exit(frame);             // 退出当前场景
      AINFO << "switch scenario from " << current_scenario_->Name()
            << " to " << scenario->Name();
      current_scenario_ = scenario;
      current_scenario_->Reset();                 // 重置新场景
      current_scenario_->Enter(frame);             // 进入新场景
      return;
    }
  }
}
```

**场景识别逻辑**基于三类输入：
- **车辆状态**：位置、速度、加速度（来自 `VehicleStateProvider`）。
- **感知 / 预测**：障碍物列表、红绿灯状态（来自 `Frame::prediction_obstacles`、`traffic_light`）。
- **路由 / 高精地图**：参考线 `ReferenceLineInfo`、`first_encounter_overlaps`（首次遇到的地图重叠元素：信号灯 / 停止线 / PNC Junction / 停车位）。

切换核心是 `IsTransferable(const Scenario* other_scenario, const Frame& frame)`：每个 Scenario 子类重写该方法，返回 `true` 表示可切入。多场景同时满足时按 `scenario_list_` 注册顺序优先选择，且**当前正在处理（STATUS_PROCESSING）的场景优先级最高**，避免场景乒乓切换。

### 2.4 Reset()：重置默认场景

```cpp
void ScenarioManager::Reset(Frame* frame) {
  if (current_scenario_) {
    current_scenario_->Exit(frame);  // 退出当前场景
  }
  AINFO << "Reset to default scenario:" << default_scenario_type_->Name();
  default_scenario_type_->Reset();
  current_scenario_ = default_scenario_type_;  // 切回 LANE_FOLLOW
}
```

用于异常恢复、路由重规划、到达终点等场景，平滑切回默认 `LANE_FOLLOW`。

### 2.5 帧数据共享（Frame 对象）

`Frame` 类位于 `modules/planning/planning_base/common/frame.cc`，是 **Planning 模块的数据中枢**，存储单个规划周期（默认 100ms）内的所有相关数据，为路径生成、速度优化、决策任务提供统一访问接口：

- **感知数据**：`prediction_obstacles`（带预测轨迹的障碍物）、`traffic_light`（红绿灯状态）。
- **定位与车辆状态**：`localization_estimate`、`vehicle_state`（位置、速度、加速度、航向）。
- **导航信息**：`routing_response`（全局路径）、`planning_command`（含 `lane_follow_command` / `parking_command`）。
- **高精地图数据**：`reference_line_info`（参考线信息列表，含 `ReferenceLine`、`PathDecision`、`PathBound`、`SpeedBound` 等）。
- **开放空间信息**：`open_space_info`（含 `target_parking_spot_id`、`pre_stop_rightaway_flag`、`is_on_open_space_trajectory` 等）。
- **上下文**：`PadMessage`（人工接管命令 STOP / PULL_OVER）、`Stories`（场景叙事）、`PlanningContext`（跨帧状态：变道状态、场景类型、目的地状态等）。

`Frame` 通过 `DependencyInjector` 注入到所有 Scenario / Stage / Task，保证跨阶段数据一致性。例如 `ValetParkingContext::target_parking_spot_id` 在 `IsTransferable` 阶段写入 Frame，`StageApproachingParkingSpot` 与 `StageParking` 均从 Frame 读取，实现跨阶段状态传递。

---

## 3. Apollo 内置 Scenario 详解（11+ 场景）

Apollo 10.0/11.0 共内置 12+ 场景，每个场景以独立插件包形式存在于 `modules/planning/scenarios/<scenario_name>/`，包含 `<name>_scenario.cc`、`stage_*.cc`、`conf/scenario_conf.pb.txt`、`conf/pipeline.pb.txt`。下表汇总所有场景的触发条件与 Stage 链。

### 3.1 内置 Scenario 总表

| # | Scenario 名称 | 代码路径 | 触发条件（IsTransferable） | Stage 链 |
|---|---------------|----------|---------------------------|----------|
| 1 | **LaneFollowScenario**（车道跟随，默认） | `scenarios/lane_follow/` | ① 有 `lane_follow_command`；② 参考线不为空；③ `other_scenario` 为空（即默认场景） | `LANE_FOLLOW_DEFAULT_STAGE`（单 Stage，内含 16 个 Task） |
| 2 | **TrafficLightProtectedScenario**（有保护红绿灯） | `scenarios/traffic_light_protected/` | ① 参考线上首个 overlap 为交通灯；② 距离 < `start_traffic_light_scenario_distance`；③ 信号灯存在红灯 | ① 停止线前停车 → ② 绿灯跛行观察 → ③ 通过路口 |
| 3 | **TrafficLightUnprotectedLeftTurnScenario**（无保护左转） | `scenarios/traffic_light_unprotected_left_turn/` | ① 首个 overlap 为交通灯；② 距离 < 阈值；③ 红灯；④ 车道类型为左转车道 | ① 停止线前停车 → ② 绿灯跛行观察对向来车 → ③ 快速穿过路口 |
| 4 | **TrafficLightUnprotectedRightTurnScenario**（无保护右转） | `scenarios/traffic_light_unprotected_right_turn/` | ① 首个 overlap 为交通灯；② 距离 < 阈值；③ 红灯；④ 车道类型为右转车道 | ① 停止线前停车 → ② 绿灯跛行观察 → ③ 通过路口 |
| 5 | **BareIntersectionUnprotectedScenario**（无保护裸露路口） | `scenarios/bare_intersection_unprotected/` | ① 当前 command 为 `lane_follow_command`；② 参考线不为空；③ 排序后 `first_encounter_overlaps` 不为空；④ 距 `pnc_junction_overlap` < `start_bare_intersection_scenario_distance` 且 > 0 | ① 减速接近无保护路口 → ② 通过路口 |
| 6 | **StopSignUnprotectedScenario**（无保护停止标志） | `scenarios/stop_sign_unprotected/` | ① 参考线首个 overlap 为停止标志；② 距离 < `start_stop_sign_scenario_distance` | ① 停止标志前停车 → ② 停车观望等待周边车辆远离 → ③ 跛行 → ④ 快速通过路口 |
| 7 | **YieldSignScenario**（让行标志） | `scenarios/yield_sign/` | ① 参考线首个 overlap 为让行标志；② 距离 < `start_stop_sign_scenario_distance` | ① 停让行标志前停车避让运动障碍物 → ② 跛行通过让行区 |
| 8 | **PullOverScenario**（靠边停车） | `scenarios/pull_over/` | ① command 为 `lane_follow_command`；② 参考线不为空；③ `FLAGS_enable_pull_over_at_destination` 为 true；④ 主车不变道；⑤ 距目标点 < 靠边停车距离阈值；⑥ 不在 overlap；⑦ 最右侧车道允许靠边 | ① `PullOverStageApproach`（接近停车点）→ ② `PullOverStageRetryApproachParking`（重试接近）→ ③ `PullOverStageRetryParking`（开放空间泊入） |
| 9 | **ValetParkingScenario**（代客泊车） | `scenarios/valet_parking/` | ① planning command 含 `parking_command`；② 距泊车点 < `parking_spot_range_to_start`；③ 通过 `SearchTargetParkingSpotOnPath` 在参考线上找到目标车位 | ① `StageApproachingParkingSpot`（沿主路接近车位）→ ② `VALET_PARKING_PARKING`（开放空间泊入） |
| 10 | **ParkAndGoScenario**（起步驶入道路） | `scenarios/park_and_go/` | ① 存在沿车道行驶命令；② 有参考线且由其他 scenario 切入；③ 车辆静止且远离终点（距终点 > `min_dist_to_dest`，默认 10m）；④ 车辆附近无道路或道路非 `city_driving` 类型 | ① `PARK_AND_GO_CHECK`（检测是否满足公路行驶）→ ② `PARK_AND_GO_ADJUST`（调整轨迹曲率）→ ③ `PARK_AND_GO_CRUISE`（接近参考线） |
| 11 | **EmergencyStopScenario**（紧急停车） | `scenarios/emergency_stop/` | ① 接收到 `PadMessage::STOP` 命令 | ① 按最大减速度计算刹车距离并减速 → ② 保持紧急停车状态，PadMessage 切换后退出 |
| 12 | **EmergencyPullOverScenario**（紧急靠边停车） | `scenarios/emergency_pull_over/` | ① 当前帧参考线不为空；② 接收到 `PadMessage::PULL_OVER` | ① 停车前减速（修改参考线限速）→ ② `PULL_OVER_PATH` 计算停车点 → ③ 停车点保持停车，PadMessage 切换后退出 |

### 3.2 LaneFollowScenario 详解

`LaneFollowScenario` 是**默认驾驶场景**，覆盖本车道保持、变道、基本转弯。它只有一个 Stage `LANE_FOLLOW_DEFAULT_STAGE`，但内含 16 个 Task（Apollo 6.0 配置，9.0+ 略有精简）：

```
scenario_type: LANE_FOLLOW
stage_type: LANE_FOLLOW_DEFAULT_STAGE
stage_config: {
  stage_type: LANE_FOLLOW_DEFAULT_STAGE
  enabled: true
  task_type: LANE_CHANGE_DECIDER
  task_type: PATH_REUSE_DECIDER
  task_type: PATH_LANE_BORROW_DECIDER
  task_type: PATH_BOUNDS_DECIDER
  task_type: PIECEWISE_JERK_PATH_OPTIMIZER
  task_type: PATH_ASSESSMENT_DECIDER
  task_type: PATH_DECIDER
  task_type: RULE_BASED_STOP_DECIDER
  task_type: SPEED_BOUNDS_PRIORI_DECIDER
  task_type: SPEED_HEURISTIC_OPTIMIZER
  task_type: SPEED_DECIDER
  task_type: SPEED_BOUNDS_FINAL_DECIDER
  task_type: PIECEWISE_JERK_SPEED_OPTIMIZER
  task_type: RSS_DECIDER
}
```

注意：Apollo 没有独立的 `LaneChangeScenario`，变道逻辑内嵌在 `LaneFollowScenario` 的 `LANE_CHANGE_DECIDER` + `PATH_LANE_BORROW_DECIDER` 两个 Task 中实现。

### 3.3 ValetParkingScenario Stage 切换流程

以代客泊车为例说明 Stage 切换的完整流程：

**阶段一：StageApproachingParkingSpot（接近停车位）**

`Process()` 核心步骤：
1. 校验 `ValetParkingContext::target_parking_spot_id` 非空，否则返回 `ERROR`。
2. 将上下文停车位 ID、预停止标志、预停止点同步到 `frame->mutable_open_space_info()`。
3. 遍历 `reference_line_info`，对每条参考线查找 `FLAGS_destination_obstacle_id` 虚拟障碍物并设置 `ignore` 决策（标签 `"ignore-dest-in-valet-parking"`），避免误触发停车。
4. 执行参考线任务链 `ExecuteTaskOnReferenceLine(planning_init_point, frame)`，完成路径决策、速度优化、轨迹校验。
5. 双向同步预停止状态（上下文 ↔ 帧）。
6. **退出条件**：`CheckADCStop(*frame)` 为真（主车完全停止），则 `next_stage_ = "VALET_PARKING_PARKING"`，返回 `FINISHED`；否则返回 `RUNNING`。

**阶段二：VALET_PARKING_PARKING（泊入车位）**

`StageParking::Process()` 核心步骤：
1. 设置 `frame->mutable_open_space_info()->set_is_on_open_space_trajectory(true)`，启用开放空间规划算法。
2. 传递 `target_parking_spot_id` 至帧。
3. 调用 `ExecuteTaskOnOpenSpace(frame)` 执行开放空间任务链：
   - `OPEN_SPACE_PRE_STOP_DECIDER`：生成公共道路预停车点。
   - `OPEN_SPACE_ROI_DECIDER`：基于停车位多边形生成可行驶区域（ROI）。
   - `OPEN_SPACE_TRAJECTORY_PROVIDER`：调用 Hybrid A* + RS 曲线生成初始避障轨迹。
   - `OPEN_SPACE_TRAJECTORY_PARTITION`：按前进/倒车分割轨迹，调整速度规划。
   - `OPEN_SPACE_FALLBACK_DECIDER`：碰撞检测与回退策略。
4. 错误处理：路径搜索失败（车位尺寸不足或障碍物封锁）返回 `ERROR`；否则持续返回 `RUNNING` 直至车辆完全停入车位。

### 3.4 PullOverScenario 三阶段流程

靠边停车场景含 3 个 Stage，体现"接近→重试→泊入"的重试机制：

- **PullOverStageApproach**：主车靠近靠边停车点，执行参考线任务链。
- **PullOverStageRetryApproachParking**：接近 Parking 位置点，主车速度、距离误差达阈值后进入下一 Stage。
- **PullOverStageRetryParking**：执行开放空间轨迹规划，主车位置、航向达阈值后退出。

### 3.5 StopSignUnprotectedScenario 四阶段流程

停止标志场景体现"停车—观望—跛行—通过"的拟人化决策：

- **阶段 1**：停止标志前停车。
- **阶段 2**：停车观望，等待周围车辆驶离。
- **阶段 3**：跛行（creep），低速观察。
- **阶段 4**：确认安全后快速通过路口。

---

## 4. Stage 详解

### 4.1 Stage 基类接口

代码位置：`modules/planning/planning_interface_base/scenario_base/stage.h`（9.0+ 插件化后路径）。

```cpp
class Stage {
 public:
  virtual bool Init(const StagePipeline& config,
                    const std::shared_ptr<DependencyInjector>& injector,
                    const std::string& config_dir, void* context);
  // 阶段处理逻辑（纯虚，子类必须实现）
  virtual StageResult Process(
      const common::TrajectoryPoint& planning_init_point, Frame* frame) = 0;
  const std::string& Name() const;
  const std::string& NextStage() const { return next_stage_; }
  template <typename T> T* GetContextAs() const;
 protected:
  // 两种任务执行方式
  StageResult ExecuteTaskOnReferenceLine(...);   // 结构化道路
  StageResult ExecuteTaskOnOpenSpace(Frame* frame);  // 开放空间
  std::vector<std::shared_ptr<Task>> task_list_;
  std::shared_ptr<Task> fallback_task_;
  std::string next_stage_;
  void* context_;
};
```

### 4.2 两种任务执行路径

- **ExecuteTaskOnReferenceLine()**：结构化道路规划，遍历 `task_list_` 顺序执行，每个 Task 接收 `Frame*` 和 `ReferenceLineInfo*`，修改参考线的路径 / 速度 / 决策。用于 LaneFollow、PullOver Approach、ValetParking ApproachingParkingSpot 等阶段。
- **ExecuteTaskOnOpenSpace()**：开放空间规划，Task 操作 `frame->mutable_open_space_info()`，使用 Hybrid A*、RS 曲线、OBCA 等算法。用于 ValetParking Parking、PullOver RetryParking、ParkAndGo 等阶段。

### 4.3 关键 Stage 列表

| Stage 名称 | 所属 Scenario | 职责 |
|-----------|--------------|------|
| `LaneFollowStage`（LANE_FOLLOW_DEFAULT_STAGE） | LaneFollow | 默认行驶，编排 16 个 Task |
| `StageApproachingParkingSpot` | ValetParking | 沿主路接近车位，忽略目的地虚拟障碍 |
| `StageParking`（VALET_PARKING_PARKING） | ValetParking | 开放空间泊入车位 |
| `PullOverStageApproach` | PullOver | 靠近靠边停车点 |
| `PullOverStageRetryApproachParking` | PullOver | 重试接近 |
| `PullOverStageRetryParking` | PullOver | 开放空间泊入 |
| `ParkAndGoStageCheck` | ParkAndGo | 检测是否满足公路行驶 |
| `ParkAndGoStageAdjust` | ParkAndGo | 调整轨迹曲率 |
| `ParkAndGoStageCruise` | ParkAndGo | 接近参考线 |
| `TrafficLightProtectedStageApproaching` | TrafficLightProtected | 停止线前停车 |
| `TrafficLightProtectedStageIntersectionCruise` | TrafficLightProtected | 通过路口 |
| `StopSignUnprotectedStagePreStop` | StopSignUnprotected | 停止标志前停车 |
| `StopSignUnprotectedStageStop` | StopSignUnprotected | 停车观望 |
| `StopSignUnprotectedStageCreep` | StopSignUnprotected | 跛行 |
| `StopSignUnprotectedStageCruise` | StopSignUnprotected | 快速通过 |
| `EmergencyStopStageStand` | EmergencyStop | 紧急停车保持 |

---

## 5. Task 详解

Apollo Task 分为 **Decider（决策器）** 和 **Optimizer（优化器）** 两大类，均继承自 `Task` 基类。下表汇总 LaneFollow 场景的 16 个核心 Task 及其输入输出。

### 5.1 LaneFollow 场景 Task 链

| # | Task 名称 | 类型 | 输入 | 输出 | 功能 |
|---|----------|------|------|------|------|
| 1 | **LANE_CHANGE_DECIDER** | Decider | `Frame*`、`ReferenceLineInfo*`、`PlanningContext::change_lane` | `lane_change_status`（IN_CHANGE_LANE / CHANGE_LANE_FAILED / CHANGE_LANE_FINISHED）、`is_clear_to_change_lane` | 判断是否换道及换道状态，含滞后滤波器 HysteresisFilter 防乒乓 |
| 2 | PATH_REUSE_DECIDER | Decider | 上一帧路径、当前障碍物 | 是否复用上一帧路径（无碰撞时复用） | 路径复用决策，降低计算量 |
| 3 | **PATH_LANE_BORROW_DECIDER** | Decider | `Frame*`、`ReferenceLineInfo*`、`PlanningContext::path_decider` | `is_in_path_lane_borrow`、`self_counter`（借道计数器） | 判断是否借道避障，self_counter > 6 退出 borrow |
| 4 | **PATH_BOUNDS_DECIDER** | Decider | `ReferenceLine`、障碍物、车道宽度、ADC 状态 | `PathBound`（fallback + pull-over + lane-borrow 三类边界） | 生成路径边界 (s, l_min, l_max) |
| 5 | **PIECEWISE_JERK_PATH_OPTIMIZER** | Optimizer | `PathBound`、`ReferenceLine`、`init_point`、`speed_data` | `DiscretizedPath`（优化后路径） | 分段加加速度二次规划（QP）优化路径平滑性 |
| 6 | PATH_ASSESSMENT_DECIDER | Decider | 多条候选路径、`PathBound` | 最优路径选择、`fallback` 路径 | 路径评估与选择 |
| 7 | **PATH_DECIDER** | Decider | 最优路径、静态障碍物 | 障碍物决策（IGNORE / STOP / NUUDGE 左 / NUUDGE 右 / OVERTAKE） | 静态障碍物路径决策 |
| 8 | **RULE_BASED_STOP_DECIDER** | Decider | `ReferenceLineInfo`、目的地、人行道、减速带 | `StopDecision` 虚拟障碍物 | 基于规则的停车决策（destination / ped_crossing / setback / pull-over） |
| 9 | **SPEED_BOUNDS_PRIORI_DECIDER** | Decider | 障碍物 ST 图、路径、限速 | `SpeedBound`（ST 可行驶区间）、`speed_limit` | 障碍物映射到 ST 图，生成先验速度边界 |
| 10 | **SPEED_HEURISTIC_OPTIMIZER** | Optimizer | `SpeedBound`、ST 图、车辆动力学 | `SpeedData`（DP 粗速度曲线） | 动态规划（DP）在非凸 ST 空间求粗解 |
| 11 | **SPEED_DECIDER** | Decider | `SpeedData`、障碍物 ST | 障碍物纵向决策（FOLLOW / OVERTAKE / YIELD / IGNORE） | 速度决策，生成对障碍物的纵向决策 |
| 12 | **SPEED_BOUNDS_FINAL_DECIDER** | Decider | 障碍物决策、ST 图 | `SpeedBound`（最终 ST 可行驶区间） | 基于决策结果生成最终速度边界 |
| 13 | **PIECEWISE_JERK_SPEED_OPTIMIZER** | Optimizer | `SpeedBound`、`SpeedData` 初解 | `SpeedData`（QP 优化速度曲线） | 分段加加速度二次规划优化速度 |
| 14 | PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER | Optimizer | `SpeedBound`、`SpeedData` | `SpeedData`（NLP 优化速度曲线） | 非线性规划优化速度（可选，更平滑） |
| 15 | RSS_DECIDER | Decider | 轨迹、障碍物 | RSS 安全性判断 | 基于 RSS 模型判断规划是否安全 |
| 16 | FALLBACK_PATH（fallback_task_） | Optimizer | 当前车道、障碍物 | 简单沿车道行驶并在障碍物前停车的备用路径 | 所有 Task 失败时的兜底路径 |

### 5.2 PathLaneBorrowDecider 详解（self_counter > 6 退出 borrow）

`PATH_LANE_BORROW_DECIDER` 决定是否进入借道避障模式，核心数据结构为 `PathDeciderStatus`（存于 `PlanningContext`）：

```cpp
message PathDeciderStatus {
  optional bool is_in_path_lane_borrow = 1;
  optional int32 self_counter = 2;  // 借道计数器
}
```

**核心逻辑**：
1. 若当前**在借道场景**：判断 `self_counter > 6`，若是则退出 borrow 模式（重置 `is_in_path_lane_borrow = false`、`self_counter = 0`）；否则 `self_counter++` 保持借道。
2. 若当前**不在借道场景**：调用 `IsNecessaryToBorrowLane()` 判断是否需要借道，条件包括：
   - 是否只有一条车道（多车道走变道而非借道）。
   - 前方是否存在阻塞道路的静态/低速障碍物。
   - 阻塞障碍物是否远离路口（避免路口借道）。
   - 阻塞障碍物是否长期存在（通过历史帧计数判断）。
   - 邻近车道线类型是否允许跨越（实线不可借道）。
   - 主车速度是否满足条件。
3. 满足条件则 `is_in_path_lane_borrow = true`，后续 `PATH_BOUNDS_DECIDER` 据此生成借道路径边界。

`self_counter > 6` 的设计意图：**避免单帧误判导致借道状态频繁切换**，要求连续 6 帧保持借道后才退出，提供状态惯性（类似滞后滤波）。

### 5.3 开放空间 Task 链（OPEN_SPACE_*）

开放空间场景（泊车、靠边）使用独立的 Task 链，由 `Stage::ExecuteTaskOnOpenSpace()` 调用：

| Task 名称 | 功能 |
|----------|------|
| **OPEN_SPACE_PRE_STOP_DECIDER** | 执行泊车/靠边时，生成公共道路上的预停车点，车辆停在预停车点后转入开放空间算法 |
| **OPEN_SPACE_ROI_DECIDER** | 基于停车位/靠边点多边形生成可行驶边界（ROI），构造开放空间可行区域 |
| **OPEN_SPACE_TRAJECTORY_PROVIDER** | 调用 Hybrid A* + RS 曲线生成初始避障轨迹（warm-start 粗解） |
| **OPEN_SPACE_TRAJECTORY_PARTITION** | 将轨迹按前进/倒车分割成多段，调整每段速度规划，设置档位切换点 |
| **OPEN_SPACE_FALLBACK_DECIDER** | 检测开放空间轨迹是否与障碍物碰撞，做出回退策略 |

Hybrid A* 生成的粗轨迹不是最终轨迹，而是作为非线性优化（IPOPT + OBCA / DL-IAPS）的 warm-start 初值，最终输出平滑且满足车辆动力学的泊车轨迹。

---

## 6. 配置驱动机制

### 6.1 .pb.txt 配置文件体系

Apollo 规划模块采用 **Protobuf 文本配置（.pb.txt）驱动**，核心配置文件分三层：

1. **`modules/planning/conf/planning_config.pb.txt`**（全局配置）：定义 planner 类型、scenario 列表、默认 task 配置。
2. **`modules/planning/scenarios/<name>/conf/scenario_conf.pb.txt`**（场景配置）：定义场景特有参数（如 `parking_spot_range_to_start`、`start_traffic_light_scenario_distance`）。
3. **`modules/planning/scenarios/<name>/conf/pipeline.pb.txt`**（流水线配置）：定义 Stage→Task 链。

### 6.2 ScenarioPipeline 配置示例

`pipeline.pb.txt` 定义 Stage 顺序与每个 Stage 的 Task 列表：

```protobuf
// ValetParkingScenario 的 pipeline.pb.txt
stage: {
  name: "VALET_PARKING_APPROACHING_PARKING_SPOT"
  type: "StageApproachingParkingSpot"
  enabled: true
  task { name: "LANE_FOLLOW_PATH" type: "LaneFollowPath" }
  task { name: "PATH_DECIDER" type: "PathDecider" }
  task { name: "RULE_BASED_STOP_DECIDER" type: "RuleBasedStopDecider" }
  task { name: "SPEED_BOUNDS_PRIORI_DECIDER" type: "SpeedBoundsDecider" }
  task { name: "SPEED_HEURISTIC_OPTIMIZER" type: "PathTimeHeuristic" }
  task { name: "SPEED_DECIDER" type: "SpeedDecider" }
  task { name: "SPEED_BOUNDS_FINAL_DECIDER" type: "SpeedBoundsDecider" }
  task { name: "PIECEWISE_JERK_SPEED" type: "PiecewiseJerkSpeed" }
}
stage: {
  name: "VALET_PARKING_PARKING"
  type: "StageParking"
  enabled: true
  task { name: "OPEN_SPACE_PRE_STOP_DECIDER" type: "OpenSpacePreStopDecider" }
  task { name: "OPEN_SPACE_ROI_DECIDER" type: "OpenSpaceRoiDecider" }
  task { name: "OPEN_SPACE_TRAJECTORY_PROVIDER" type: "OpenSpaceTrajectoryProvider" }
  task { name: "OPEN_SPACE_TRAJECTORY_PARTITION" type: "OpenSpaceTrajectoryPartition" }
  task { name: "OPEN_SPACE_FALLBACK_DECIDER" type: "OpenSpaceFallbackDecider" }
}
```

### 6.3 修改配置即可调整逻辑

配置驱动的核心优势：
- **无需重编译**：修改 `.pb.txt` 后重启 planning 即生效。
- **Stage→Task 链可调**：增删 Task、调整顺序、禁用 Stage 均通过配置完成。
- **场景参数化**：`scenario_conf.pb.txt` 中阈值参数（如距离阈值、速度阈值）可按需调整。
- **场景启用/禁用**：`planning_config.pb.txt` 的 scenario 列表中删除某场景即禁用该场景。

`Scenario::Init()` 在加载 `pipeline.pb.txt` 后构建 `stage_pipeline_map_`（Stage 名称→StagePipeline 配置），运行时按名称快速检索。

---

## 7. Apollo 9.0 PnC 2.0 改进

### 7.1 插件化重构

Apollo 9.0 PnC 2.0 的核心是**全面插件化**：把原本耦合在 `modules/planning` 单体里的规划器、场景、阶段、任务、交通规则全部拆成可独立编译、动态加载的插件（`.so`），由 `cyber::plugin_manager::PluginManager` 统一注册与加载。

**目录结构重组**（9.0+）：
```
modules/planning/
├── planning_component/      ← Cyber RT 组件入口 PlanningComponent
├── planning_base/           ← 规划基类 PlanningBase、Frame、ReferenceLineInfo、common/
├── planning_interface_base/ ← 插件接口基类（Scenario/Stage/Task/Planner/Rule 抽象）
├── planners/                ← 规划器插件（public_road / lattice / rtk / navi）
├── planning_open_space/     ← 开放空间规划算法库
├── scenarios/               ← 各 Scenario 插件包（lane_follow、pull_over、valet_parking 等）
├── tasks/                   ← 各 Task 插件包（deciders、optimizers、open_space 等）
├── traffic_rules/           ← 交通规则插件
├── pnc_map/lane_follow_map/ ← PncMap
└── park_data_center/        ← 泊车数据缓存
```

每个插件包含 `cyberfile.xml`（依赖声明）、`plugins.xml`（动态库路径与类注册）、`.so`（编译产物）。`PluginManager::CreateInstance<Scenario>()` 运行时按需加载。

### 7.2 双状态机明确化

9.0 明确了"双状态机"定位：
- **第一层（Scenario 状态机）**：由 `ScenarioManager` 切换，状态为 `ScenarioStatusType`（STATUS_PROCESSING / STATUS_DONE / STATUS_UNKNOWN）。
- **第二层（Stage 状态机）**：由 `Scenario::Process()` 切换，状态为 `StageStatusType`（RUNNING / FINISHED / ERROR）。

两层状态机通过 `ScenarioResult` / `StageResult` 解耦传递，上层只关心下层状态，不关心内部实现。

### 7.3 Scenario-free 趋势

虽然 Scenario/Stage/Task 架构仍是主流，但 Apollo 社区已出现 **Scenario-free 趋势** 的讨论：
- 学习类规划（Learning-based Planning）倾向于**统一模型处理所有场景**，避免手工场景划分的局限。
- 接入位置有两种选择：① 做成独立 Cyber Component，作为候选轨迹生成器；② 做成 Apollo Planning 内部的 Planning Plugin，作为新增 Task 或替换整个 Stage。
- Apollo 10.0/11.0 引入 ADFM（Apollo Driving Foundation Model）大模型辅助，进一步推动 Scenario-free 统一规划。

但截至 11.0，规则驱动的 Scenario/Stage/Task 仍是**主路径**，学习类规划作为候选 / 补充。

### 7.4 学习类规划接入

`DependencyInjector` 中新增 `learning_based_data` 字段，支持学习类规划数据传递。`PlanningComponent` 在 RL_TEST 模式下收集 `PlanningLearningData` 发布到独立 channel，供离线训练。学习类规划器可作为：
- **Task 级接入**：替换某个 Optimizer（如用神经网络替换 `PIECEWISE_JERK_PATH_OPTIMIZER`）。
- **Stage 级接入**：新增 `LearningStage`，输出候选轨迹与规则 Stage 比较择优。
- **Planner 级接入**：新增 `LearningPlanner` 插件，作为 `PublicRoadPlanner` 的替代。

---

## 8. Apollo 源码结构

### 8.1 关键源码文件路径

| 文件路径 | 职责 |
|---------|------|
| `modules/planning/planning_base/scenarios/` | 9.0 前场景实现目录（已迁移至 `modules/planning/scenarios/`） |
| `modules/planning/planning_interface_base/scenario_base/scenario.h/.cc` | Scenario 基类 |
| `modules/planning/planning_interface_base/scenario_base/stage.h/.cc` | Stage 基类 |
| `modules/planning/planning_interface_base/task_base/task.h/.cc` | Task 基类 |
| `modules/planning/planning_base/common/frame.cc` | Frame 数据中枢 |
| `modules/planning/planners/public_road/scenario_manager.cc` | ScenarioManager |
| `modules/planning/planners/public_road/public_road_planner.cc` | PublicRoadPlanner |
| `modules/planning/planning_base/common/dependency_injector.h` | DependencyInjector 依赖注入 |
| `modules/planning/scenarios/<name>/conf/pipeline.pb.txt` | 场景流水线配置 |
| `modules/planning/scenarios/<name>/conf/scenario_conf.pb.txt` | 场景参数配置 |
| `modules/planning/conf/planning_config.pb.txt` | 全局规划配置 |

### 8.2 Scenario 基类核心接口

```cpp
class Scenario {
 public:
  virtual bool Init(std::shared_ptr<DependencyInjector> injector,
                    const std::string& name);
  virtual ScenarioContext* GetContext() = 0;          // 场景上下文（跨阶段共享）
  virtual bool IsTransferable(const Scenario* other_scenario,
                              const Frame& frame);     // 场景切入条件
  virtual ScenarioResult Process(
      const common::TrajectoryPoint& planning_init_point, Frame* frame);
  virtual bool Exit(Frame* frame);                    // 退出清理
  virtual bool Enter(Frame* frame);                    // 进入初始化
  std::shared_ptr<Stage> CreateStage(const StagePipeline& stage_pipeline);
  const ScenarioStatusType& GetStatus() const;
  const std::string GetStage() const;
  void Reset();
 protected:
  ScenarioResult scenario_result_;
  std::shared_ptr<Stage> current_stage_;
  std::unordered_map<std::string, const StagePipeline*> stage_pipeline_map_;
  std::shared_ptr<DependencyInjector> injector_;
  ScenarioPipeline scenario_pipeline_config_;
};
```

### 8.3 DependencyInjector 依赖注入

`DependencyInjector` 是集中管理规划模块关键数据和服务的容器类，解耦各组件直接依赖：

```cpp
class DependencyInjector {
 public:
  PlanningContext* planning_context();              // 跨帧规划上下文
  FrameHistory* frame_history();                    // 历史帧
  VehicleStateProvider* vehicle_state();            // 车辆状态
  LearningBasedData* learning_based_data();         // 学习数据
  ReferenceLineProvider* reference_line_provider(); // 参考线生成
  // ...
};
```

`PlanningComponent::Init()` 中创建 `injector_ = std::make_shared<DependencyInjector>()`，注入到所有 Scenario / Stage / Task，保证数据一致性。

---

## 9. AuroraDrive 迁移建议

### 9.1 AuroraDrive 当前架构

AuroraDrive 当前采用**扁平化 decision_ 字符串**驱动决策，通过 `decision_make_v8` C ABI 函数输出字符串命令（brake / follow / cruise / hold），上层（Swift EngineBridge）解析字符串驱动控制。该方案：

- **优点**：简单直观，易于调试。
- **缺点**：① 缺乏状态机管理，场景切换无优先级；② 字符串扩展性差，新增场景需修改解析逻辑；③ 无 Stage 概念，复杂场景（泊车、靠边）需硬编码多步逻辑；④ Task 算法单元不可复用；⑤ 无配置驱动，调整逻辑需重编译 dylib。

### 9.2 AuroraDrive 简化版 Scenario / Stage 架构

参照 Apollo 三级架构，为 AuroraDrive 设计**简化版 5 场景分层架构**，保留核心思想但去除过度工程：

#### 9.2.1 五个 Scenario 定义

| Scenario | 触发条件 | Stage 链 | 默认 PID（纵向 / 横向） |
|---------|---------|---------|------------------------|
| **CRUISE**（巡航，默认） | 无前车障碍 / 距前车 > 安全阈值 / 无停车命令 | `CRUISE_TRACK`（单 Stage：路径跟踪 + 速度保持） | 纵向 Kp=1.0, Ki=0.05, Kd=0.1；横向 Kp=0.8, Ki=0.0, Kd=0.2 |
| **FOLLOW**（跟车） | 前方有运动车辆 / 距前车 < 跟车阈值 / 前车速度 > 0 | `FOLLOW_GAP`（车距保持）→ `FOLLOW_SPEED`（速度匹配） | 纵向 Kp=1.5, Ki=0.1, Kd=0.15（响应更快）；横向 Kp=0.8, Ki=0.0, Kd=0.2 |
| **APPROACH_DEST**（接近目的地） | 距终点 < `approach_dest_range`（如 30m）/ 到达终点附近 | `APPROACH_DECEL`（减速接近）→ `DEST_STOP`（终点停车） | 纵向 Kp=2.0, Ki=0.05, Kd=0.3（精准停车）；横向 Kp=1.0, Ki=0.0, Kd=0.3 |
| **PARKING**（泊车） | 接收到停车命令 / 接近停车位 | `PARKING_APPROACH`（接近车位）→ `PARKING_EXECUTE`（泊入） | 纵向 Kp=1.2, Ki=0.05, Kd=0.2；横向 Kp=1.5, Ki=0.05, Kd=0.4（低速大转角） |
| **EMERGENCY**（紧急，最高优先级） | 检测到碰撞风险 / 紧急命令 / 障碍物突现 < 紧急阈值 | `EMERGENCY_BRAKE`（最大制动）→ `EMERGENCY_HOLD`（保持停车） | 纵向 Kp=3.0, Ki=0.0, Kd=0.5（硬制动）；横向 Kp=1.0, Ki=0.0, Kd=0.2 |

#### 9.2.2 架构设计

```
AuroraDriveDecisionEngine
  └─> ScenarioManager.update(vehicle_state, perception, route)
        ├─> currentScenario.isTransferable()  ← 场景切换判断
        └─> currentScenario.process()
              └─> currentStage.process()
                    └─> taskList.forEach(task => task.execute())
                          └─> output: { target_speed, target_steering, pid_params }
```

#### 9.2.3 关键设计点

1. **场景切换优先级**：`EMERGENCY > PARKING > APPROACH_DEST > FOLLOW > CRUISE`。EMERGENCY 可随时抢占，CRUISE 为默认兜底。
2. **Stage 切换**：Stage 内 Task 全部完成 + 业务条件满足（如 `checkVehicleStopped()`）才切换。
3. **按场景独立 PID**：每个 Scenario 维护独立 PID 参数表，切换场景时同步切换 PID，避免单一 PID 在所有场景下妥协调参。
4. **配置驱动**：用 JSON/YAML 定义场景→Stage→Task 链与 PID 参数，运行时加载，无需重编译 dylib。
5. **decision_ 字符串向后兼容**：保留 `decision_make_v8` 输出字符串（CRUISE/FOLLOW/APPROACH_DEST/PARKING/EMERGENCY），上层 EngineBridge 解析为新场景枚举，平滑迁移。
6. **Task 复用**：`PathTrackTask`、`SpeedKeepTask`、`DecelerateTask`、`BrakeTask`、`SteerToTargetTask` 等可在多场景复用。

#### 9.2.4 迁移路线

- **Phase 1**：引入 Scenario 枚举与 ScenarioManager，替换 decision_ 字符串为场景枚举，保持单 Stage 单 Task。
- **Phase 2**：为每个场景拆分 Stage（如 APPROACH_DEST 拆为 APPROACH_DECEL + DEST_STOP），引入 Stage 状态机。
- **Phase 3**：引入 Task 列表与配置驱动（JSON 定义 Stage→Task 链），实现算法单元复用。
- **Phase 4**：按场景独立 PID 参数表，实现场景切换时 PID 动态切换。

---

## 10. 关键设计总结

### 10.1 Apollo 三级架构核心思想

1. **分层解耦**：Scenario 关注"在什么场景"，Stage 关注"做到什么程度"，Task 关注"怎么算"，各层职责单一。
2. **双状态机**：Scenario 状态机管宏观场景切换，Stage 状态机管微观阶段切换，两层独立演进。
3. **配置驱动**：`.pb.txt` 定义 Stage→Task 链，修改配置即调整逻辑，无需重编译。
4. **插件化**：9.0 PnC 2.0 把所有元素拆成 `.so` 插件，动态加载，支持第三方扩展。
5. **帧数据共享**：Frame + DependencyInjector 统一管理跨阶段 / 跨 Task 数据，避免重复计算。
6. **状态惯性**：`self_counter`、HysteresisFilter 等机制防止状态乒乓切换。
7. **Fallback 兜底**：每个 Stage 有 `fallback_task_`，Task 失败时降级保证安全。

### 10.2 对 AuroraDrive 的启示

- AuroraDrive 当前扁平化 decision_ 字符串适合 MVP，但场景增多后维护成本激增。
- 建议采用 Apollo 的 Scenario / Stage / Task 分层思想，但**简化实现**：5 场景 + 2~3 Stage + 3~5 Task 即可覆盖当前需求。
- 按场景独立 PID 是高性价比改进，可立即落地。
- 配置驱动（JSON）应作为 Phase 3 目标，为后续扩展铺路。

---

## 参考资料

- Apollo 官方文档：https://apollo.baidu.com/docs/apollo/latest/
- GitHub ApolloAuto/apollo：https://github.com/ApolloAuto/apollo
- CSDN Apollo10.0 学习专栏（scenario、Stage 插件详解一/二、Scenario 场景切换条件汇总、Frame 类、依赖注入器）：https://blog.csdn.net/qq1240268067/category_12951338.html
- CSDN Apollo 学习笔记 TASK 系列（LANE_CHANGE_DECIDER、PATH_BORROW_DECIDER、PATH_BOUNDS_DECIDER、PATH_DECIDER、RULE_BASED_STOP_DECIDER、SPEED_BOUNDS_PRIORI/FINAL_DECIDER、SPEED_HEURISTIC_OPTIMIZER、SPEED_DECIDER、PIECEWISE_JERK_PATH/SPEED_OPTIMIZER）：https://blog.csdn.net/sinat_52032317/category_12139648.html
- CSDN Apollo9.0 PNC 源码辨析专栏：https://blog.csdn.net/bigdavid123/category_12695668.html
- CSDN Apollo 10.0 规划模块框架说明：https://blog.csdn.net/m0_37800826/article/details/145859929
- CSDN Apollo 项目的场景化实现机制详解：https://blog.csdn.net/u010632343/article/details/150989080
- CSDN Apollo 中 Scenario、Stage、Task 之间的关系：https://blog.csdn.net/qq1240268067/article/details/147591619
- CSDN Apollo 规划模块探秘——场景驱动决策引擎：https://blog.csdn.net/rnn9storyteller/article/details/152071307
- CSDN APOLLO lane_borrow_decider 代码解读：https://blog.csdn.net/weixin_42861755/article/details/130713936
- Apollo Open Space Planner 介绍系列：https://www.chuxin911.com/apollo_open_space_planner_intro_3_code_flow_20211120/

---

> **实际工具调用次数**：本研究共执行 **54 次**内部工具调用（WebSearch 28 次 + WebFetch 16 次 + Read 6 次 + LS/Glob/Grep 4 次），覆盖 Apollo 官方文档、GitHub 源码目录、CSDN 源码解析专栏等多源信息，深度挖掘 Scenario / Stage / Task 三级架构、12 个内置场景、16 个核心 Task、配置驱动机制、9.0 PnC 2.0 插件化改进及 AuroraDrive 迁移建议。
