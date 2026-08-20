# 09 · 决策状态机与行为规划（Decision State Machine & Behavior Planning）深度研究

> 研究主题：自动驾驶系统中决策状态机与行为规划的完整工程实现，覆盖 FSM / HSM / 行为树三类范式对比，并对 Apollo Scenario-Stage-Task 双层状态机、Autoware.Universe behavior_path_planner + RTC、OpenPilot StateManager、Mobileye RSS Proper Response、ROS2 Lifecycle Node 进行源码级拆解，结合状态机形式化与模型检查（CBMC / UPPAAL / SPIN）、L3 接管（TOR）与驾驶员监控（DMS），最后给出 AuroraDrive 项目（C++ 原生、ONNX 推理、Rust 监督树、Tauri 前端、24Hz 物理、仿真/游戏/规则验证三模式）的决策状态机升级方案。
> 研究方法：WebSearch + WebFetch 深度调研 Apollo / Autoware / OpenPilot / Mobileye / ROS2 / BehaviorTree.CPP / Nav2 公开资料与 CSDN / 腾讯云源码解析，结合 AuroraDrive 项目 `cpp/include/ad/autonomy.h`、`cpp/include/ad/simulator.h` 现有实现进行对照分析。
> 配套源码：`cpp/include/ad/autonomy.h`（`AutonomyStack` 级联仲裁、`ControlSource`/`Phase` 枚举、`FallbackDetector`）、`cpp/include/ad/simulator.h`（`mode_`/`paused_`/`decision_` 字符串状态、`assist_*` 辅助模式标志）。
> 字数目标：≥ 5000 字（中文字符）。

---

## 1. 决策状态机概述

### 1.1 定义与定位

**决策状态机（Decision State Machine）** 是自动驾驶系统"行为规划"层的核心抽象：它把连续变化的交通环境离散化为有限个**驾驶场景/行为状态**，并用**转移条件**刻画状态间的切换，从而把"此刻该做什么"这一开放问题，收敛为"当前在哪个状态、满足什么条件就跳到下一个状态"的闭式判定。

形式化地，一个确定性有限状态机（DFA）定义为五元组 `M = (S, Σ, δ, s0, F)`：

| 符号 | 含义 | 自动驾驶映射 |
|------|------|--------------|
| `S` | 有限状态集 | {LANE_FOLLOW, LANE_CHANGE, PULL_OVER, EMERGENCY_STOP, ...} |
| `Σ` | 输入事件集 | {前车急刹, 收到 PULL_OVER 命令, 信号灯变红, 驾驶员踩刹车, ...} |
| `δ: S×Σ → S` | 转移函数 | IsTransferable / Update 逻辑 |
| `s0 ∈ S` | 初始状态 | LANE_FOLLOW（默认巡航） |
| `F ⊆ S` | 终止/接受状态 | {EMERGENCY_STOP, HOLD}（安全兜底） |

行为规划在自动驾驶栈中的**三层定位**：

```
┌─────────────────────────────────────────────────────────┐
│ ① 使命规划 Mission Planning  │ 全局路由（A* / Dijkstra） │
├─────────────────────────────────────────────────────────┤
│ ② 行为规划 Behavior Planning │ ★ 决策状态机所在层 ★     │
│    决定"做什么"：跟车/变道/靠边/停/让                     │
├─────────────────────────────────────────────────────────┤
│ ③ 运动规划 Motion Planning   │ 轨迹生成（EM/Lattice/Opt）│
│    决定"怎么做"：具体轨迹点 + 速度                        │
├─────────────────────────────────────────────────────────┤
│ ④ 控制层 Control             │ PID / MPC 轨迹跟踪        │
└─────────────────────────────────────────────────────────┘
```

行为规划不直接输出方向盘/油门，而是输出"行为意图"（如"变道到左车道"），再由运动规划据此生成具体轨迹。它与 Emergency Stop 的关系是：**Emergency Stop 是行为规划失效（或感知/控制失效）时的强制状态注入**，是状态机的一个特殊终止状态（详见 `08_emergency_stop.md`）。

### 1.2 与相邻模块的关系

| 模块 | 给行为规划的输入 | 行为规划的输出 |
|------|-----------------|----------------|
| 感知 Perception | 障碍物列表、车道线、信号灯状态 | — |
| 预测 Prediction | 障碍物未来轨迹 | — |
| 定位 Localization | ego 位姿、车速 | — |
| 路由 Routing | 全局导航线 | — |
| — | 行为意图 + 参考线 / 期望速度 | 运动规划 Motion Planning |
| — | 控制模式（engage/disengage） | 控制 Control |
| Monitor / Guardian | 系统健康、降级触发 | — |

---

## 2. 主流方案对比：FSM / HSM / 行为树 / 状态图

自动驾驶行为规划历史上出现过四种主流建模范式，各有取舍。

### 2.1 四种范式速览

| 范式 | 结构 | 优势 | 劣势 | 代表系统 |
|------|------|------|------|----------|
| **FSM（有限状态机）** | 状态 + 转移边 | 简单、确定性、易实现、易验证 | 状态数爆炸、转移边 O(n²)、难扩展 | 早期 Apollo、AuroraDrive 当前 |
| **HSM（层次状态机）** | 状态嵌套（父-子） | 子状态继承父行为、减少重复、抑制爆炸 | 转移语义复杂（进入/退出历史） | Apollo Scenario-Stage-Task |
| **行为树 BT** | 树形节点（Sequence/Fallback/Decorator） | 反应式、模块化、无状态爆炸、易组合 | 调试不直观、运行时语义非确定 | Nav2、Autoware behavior_path_planner |
| **状态图 Statechart** | HSM + 并行状态 + 历史伪状态 | 表达力最强、支持正交区域 | 工具链重、形式化复杂 | UML、SCXML |

### 2.2 状态爆炸对比（直观）

```
FSM（扁平）：    10 个状态 × 10 个事件 = 最多 100 条转移边
HSM（2 层）：    父 5 × 子 2 = 10 状态，转移边 ~30 条（继承去重）
行为树：         10 个行为节点 + 5 个控制节点，无边数概念，每帧重算
```

### 2.3 FSM vs HSM vs BT 决策表

```
                       FSM          HSM          行为树
─────────────────────────────────────────────────────────
状态数 < 10            ✓ 简单        过度设计      过度设计
状态数 10~50           开始混乱      ✓ 推荐        ✓ 推荐
状态数 > 50            不可维护      ✓ 推荐        ✓ 推荐
需要反应式（每帧重判）  需显式转移    需显式转移    ✓ 天然反应式
需要形式化验证         ✓ 最易        中等          较难
需要并行行为           ✗            ✓ 正交区域    ✓ 多子树
代码可读性             状态多了差    中等          ✓ 树形清晰
```

### 2.4 业界选择趋势

- **Apollo**：早期（≤3.0）用行为树 + ReferenceLine，3.5 起改用 **Scenario-Stage-Task 双层 HSM**（详见第 3 节），原因是行为树难以管理"场景优先级"和"强制切入"。
- **Autoware.Universe**：behavior_path_planner 内部用 **行为树**管理模块激活（PlannerManager 排队），但顶层仍是 HSM（LANE_DRIVING / FREE_SPACE 两大场景）。
- **Nav2（ROS2 导航）**：纯 **BehaviorTree.CPP V4**，`bt_navigator` 加载 XML 行为树，导航行为全部树化。
- **OpenPilot**：极简 **FSM**（disabled / enabled / softDisable / overridden），靠 Events 系统驱动转移。
- **Mobileye RSS**：不是状态机，而是**数学决策规则**（Proper Response），可作为状态机的"安全不变式"嵌入任意范式。

---

## 3. Apollo 决策架构深度剖析（Scenario / Stage / Task）

### 3.1 双层状态机框架

Apollo 自 3.5 起在 `modules/planning` 引入 **Scenario-Stage-Task** 三层、双层状态机架构（源码：`modules/planning/planners/public_road/scenario_manager.cc`）。其核心思想是：**Scenario 是第一层状态机，Stage 是 Scenario 内部的第二层状态机，Task 是 Stage 编排的具体规划运算**。

```
┌──────────────────────────────────────────────────────────┐
│ ScenarioManager（第一层 FSM 调度器）                      │
│   每帧 Update()：遍历 scenario_list_，按优先级查           │
│   IsTransferable()，命中则 Exit 旧 → Enter 新            │
├──────────────────────────────────────────────────────────┤
│ Scenario（场景 = 第一层状态）                              │
│   - LaneFollowScenario（默认）                            │
│   - PullOverScenario / EmergencyPullOverScenario          │
│   - EmergencyStopScenario                                 │
│   - ParkAndGoScenario                                     │
│   - ValetParkingScenario                                  │
│   - TrafficLightProtected / Unprotected                   │
│   - StopSignProtected / Unprotected                       │
│   - BareIntersectionUnprotected                           │
│   - ...（共 11~12 种）                                     │
├──────────────────────────────────────────────────────────┤
│ Stage（阶段 = 第二层状态，Scenario 内部 FSM）              │
│   如 PullOverScenario 内含：                              │
│     ① PullOverStageApproach                              │
│     ② PullOverStageRetryApproachParking                  │
│     ③ PullOverStageRetryParking                          │
│   每个 Stage 有 Process() + FinishStage()                 │
├──────────────────────────────────────────────────────────┤
│ Task（任务 = 具体规划运算，由 Stage 编排）                 │
│   - path_bounds_decider / speed_bounds_decider            │
│   - st_bounds_decider / path_optimizer                    │
│   - piecewise_jerk_speed_optimizer                        │
│   - rule_based_stop_decider                              │
└──────────────────────────────────────────────────────────┘
```

### 3.2 Scenario 基类接口

`Scenario` 基类（`modules/planning/scenarios/scenario.h`）定义了所有场景的标准生命周期：

```cpp
class Scenario {
 public:
  virtual bool Init(...);
  virtual ScenarioContext* GetContext() = 0;
  virtual bool IsTransferable(const Scenario* other, const Frame& frame);  // ★ 切入条件
  virtual ScenarioResult Process(const TrajectoryPoint& planning_init_point, Frame* frame);
  virtual bool Enter(Frame* frame);
  virtual bool Exit(Frame* frame);
  virtual std::shared_ptr<Stage> CreateStage(const StagePipeline& stage_pipeline);
  void Reset();
  const ScenarioStatusType& GetStatus() const;  // STATUS_PROCESSING / STATUS_DONE
};
```

### 3.3 ScenarioManager::Update 切换逻辑

```cpp
void ScenarioManager::Update(const TrajectoryPoint& ego_point, Frame* frame) {
  // ① 当前场景仍在处理中 → 保持，不切换（避免抖动）
  if (current_scenario_->GetStatus() == ScenarioStatusType::STATUS_PROCESSING) {
    return;
  }
  // ② 遍历场景列表（按 planning_config.pb.txt 优先级从高到低排序）
  for (auto& scenario : scenario_list_) {
    if (scenario->IsTransferable(current_scenario_.get(), *frame)) {
      current_scenario_->Exit(frame);
      current_scenario_ = scenario;
      current_scenario_->Reset();
      current_scenario_->Enter(frame);
      return;
    }
  }
}
```

**关键设计**：场景配置在 `modules/planning/planning_component/conf/planning_config.pb.txt`，按优先级从高到低排序，高优先级场景（如 EmergencyStop、EmergencyPullOver）优先检查 `IsTransferable`。

### 3.4 典型场景切入条件（IsTransferable 汇总）

| 场景 | IsTransferable 切入条件 | 触发命令 |
|------|------------------------|----------|
| **LaneFollow** | 默认场景，无其他场景命中时回落 | lane_follow_command |
| **EmergencyStop** | 收到 `PadMessage::STOP` | PadMessage::STOP |
| **EmergencyPullOver** | 参考线非空 + 收到 `PadMessage::PULL_OVER` | PadMessage::PULL_OVER |
| **PullOver** | 接近终点、需靠边停车 | routing 终点 |
| **ParkAndGo** | 有 lane_follow_command + 自车静止 + 距终点 S > min_dist_to_dest（默认 10m）+ 自车不在 city_driving 道路上 | — |
| **ValetParking** | 收到 ValetParkingCommand | ValetParkingCommand |
| **TrafficLightProtected** | 参考线非空 + overlap 含信号灯 + 有路权保护 | — |
| **BareIntersectionUnprotected** | lane_follow_command + overlap 含路口 + 无信号灯 | — |
| **StopSignUnprotected** | lane_follow_command + overlap 含 STOP 标志 | — |

### 3.5 TrafficDecider 与 traffic_rule

在 Scenario/Stage 之外，Apollo 还有一层 **TrafficDecider**（`modules/planning/traffic_rules`），它独立于场景，对参考线施加通用交通规则约束。已实现的 traffic rules：

- `backside_vehicle`：后向车辆处理，决定是否忽略
- `crosswalk`：人行道避让
- `destination`：终点停车
- `routed_traffic_light`：信号灯停车
- `stop_sign`：停止标志
- `yield_sign`：让行标志
- `RULE_BASED_STOP_DECIDER`（独立 Task）：`StopOnSidePass` / `CheckClearDone` / `CheckSidePassStop` / `IsPerceptionBlocked` / `IsClearToChangeLane`

TrafficDecider 与 Scenario 是正交关系：**Scenario 决定"走哪条路、做哪个机动"，TrafficDecider 决定"哪里必须停、哪里必须让"**。

### 3.6 Apollo FSM 状态转移图（文字版）

```
                         ┌──────────────────┐
            启动 ───────▶│  LaneFollow       │◀───── 默认回落
                         │  (默认巡航)        │
                         └────────┬──────────┘
                                  │
            ┌─────────────┬───────┼────────┬────────────┐
            │             │       │        │            │
       overlap=信号灯  overlap=路口  PadMessage  PadMessage   接近终点
            │             │   STOP     PULL_OVER      │
            ▼             ▼       │        │            ▼
   ┌──────────────┐ ┌──────────┐  │        │    ┌──────────┐
   │TrafficLight  │ │BareInter │  │        │    │ PullOver │
   │Protected/    │ │section   │  │        │    │ Scenario │
   │Unprotected   │ │Unprotect │  │        │    └──────────┘
   └──────────────┘ └──────────┘  │        │
                                  ▼        ▼
                          ┌──────────┐  ┌──────────────┐
                          │Emergency │  │EmergencyPull │
                          │Stop      │  │Over          │
                          │(终态)    │  │(靠边终态)    │
                          └──────────┘  └──────────────┘
                                  ▲
                  FallbackDetector│critical / Guardian 触发
                                  │
                         ┌────────┴──────────┐
                         │  任意场景          │
                         └───────────────────┘
```

---

## 4. Autoware.Universe 决策模块剖析

### 4.1 Planning 四子模块

Autoware.Universe（`autoware.universe/planning`）把规划分为 Mission / Behavior / Motion / Validation 四层，行为规划核心是 **behavior_path_planner**（路径行为）与 **behavior_velocity_planner**（速度行为）。

```
Mission Planner ──全局路由──> Behavior Path Planner ──路径──> Motion Planner
                                    │                          (trajectory generation)
                                    ├── lane_following
                                    ├── lane_change
                                    ├── static_obstacle_avoidance
                                    ├── pull_over
                                    ├── pull_out
                                    └── side_shift
                                    │
                              Behavior Velocity Planner
                                    ├── detection_area
                                    ├── blind_spot
                                    ├── cross_walk
                                    ├── stop_line
                                    ├── traffic_light
                                    ├── intersection
                                    ├── no_stopping_area
                                    ├── virtual_traffic_light
                                    ├── occlusion_spot
                                    ├── run_out
                                    └── obstacle_avoidance_planner
```

### 4.2 BehaviorPathPlannerNode 与 PlannerManager

`BehaviorPathPlannerNode::run()` 是主入口，只在 `current_scenario == LANE_DRIVING` 时运行路径行为规划。它把模块（lane_change / avoidance / pull_over ...）交给 **PlannerManager** 排队调度——PlannerManager 内部用**行为树机制**决定哪个模块激活、哪个挂起，确保同一时刻只有一个模块输出路径，避免冲突。

### 4.3 NormalLaneChange 状态机（变道内部 FSM）

变道模块 `NormalLaneChange` 内部维护一个状态机 `updateLaneChangeStatus()`：

```
┌──────────────┐  条件满足   ┌──────────────┐  RTC approved ┌──────────────┐
│  Idle        │────────────▶│  Requesting  │──────────────▶│  Executing   │
│  (不变道)    │             │  (RTC 请求)  │               │  (变道中)    │
└──────────────┘             └──────────────┘               └──────┬───────┘
                                  │ rejected                      │ 完成
                                  ▼                               ▼
                            ┌──────────────┐               ┌──────────────┐
                            │  Canceling   │               │  Finished    │
                            └──────────────┘               └──────────────┘
```

### 4.4 RTC（Request to Complete）接管协议

Autoware 的 **RTC** 是变道/避障等"侵入性机动"的审批协议：模块发起 RTC 请求 → 系统评估安全性 → 批准（approve）/拒绝（reject）/强制（forceLaneChange）。RTC 把"是否允许变道"从模块内部判定提升到**系统级仲裁**，避免多个模块同时变道。这与 Apollo 的"Scenario 优先级"思路异曲同工，但 Autoware 用审批消息解耦，Apollo 用配置优先级。

### 4.5 Autoware 顶层状态机

Autoware 顶层用 `autoware_state_machine` / `state_machine_msgs` 维护驾驶状态，典型状态枚举（`state_machine.h`）：

```cpp
enum class StateList : int32_t {
  MOVE_FORWARD,       // 直行
  TRAFFIC_LIGHT_STOP, // 信号灯停车
  LANE_CHANGE,        // 变道
  EMERGENCY = -1      // 紧急制动（特殊值，任意状态可跳入）
};
```

控制层 `vehicle_cmd_gate` 负责 engage / gate_mode / operation_mode / emergency 的仲裁，是行为规划与执行器之间的最后一道状态闸门。

### 4.6 Autoware vs Apollo 决策架构对比

| 维度 | Apollo | Autoware.Universe |
|------|--------|-------------------|
| 顶层范式 | 双层 HSM（Scenario-Stage） | HSM（LANE_DRIVING / FREE_SPACE）+ 行为树（模块内） |
| 场景数 | 11~12 个 Scenario | 6 个 path 模块 + 11 个 velocity 模块 |
| 切换机制 | IsTransferable + 优先级配置 | PlannerManager 行为树 + RTC 审批 |
| 侵入性机动仲裁 | Scenario 优先级 | RTC approve/reject |
| 通用交规 | TrafficDecider（独立） | behavior_velocity_planner（独立） |
| 实现语言 | C++ + CyberRT | C++ + ROS2 rclcpp |

---

## 5. OpenPilot 状态机剖析

### 5.1 StateManager 四态 FSM

OpenPilot（comma.ai）用极简 FSM 管理辅助驾驶状态（`selfdrive/selfdrived/state.py` 的 `StateManager`）：

```python
class StateManager:
    def __init__(self):
        self.state = State.disabled        # 从禁用开始
        self.soft_disable_timer = 0        # 软禁用倒计时

    def update(self, events):
        if self.state != State.disabled:
            if events.contains(et.user_disable):       # 用户取消
                self.state = State.disabled
            elif events.contains(et.immediate_disable): # 严重异常
                self.state = State.disabled
            # ... 其他转移
```

四态转移图：

```
                 user_disable / immediate_disable
   ┌────────────────────────────────────────────────────┐
   ▼                                                    │
┌──────────┐  enable   ┌──────────┐  softDisable触发   ┌────────────┐
│ disabled │──────────▶│ enabled  │──────────────────▶│ softDisable │
│ (完全退出)│           │ (正常辅助)│                   │ (3s 倒计时) │
└──────────┘           └────┬─────┘                   └─────┬──────┘
                            │                               │ 倒计时结束
                            │ steerUnavailable              ▼
                            │ brakeUnavailable        ┌──────────┐
                            └────────────────────────▶│overridden│
                                                       │ (强制交还)│
                                                       └──────────┘
```

### 5.2 Events 系统驱动转移

转移不由"状态内部判定"驱动，而由 **Events 系统**（`selfdrive/selfdrived/events.py`）驱动。所有异常统一建模为 `Event`，含 `name` / `severity`（alert / warning / critical）/ `type`。典型映射：

| Event | 触发条件 | 目标状态 |
|-------|---------|----------|
| `user_disable` | 驾驶员按取消键 / 踩刹车 | disabled（立即） |
| `canTimeout` / `commIssue` | CAN 通信超时 | disabled（立即） |
| `steerUnavailable` / `brakeUnavailable` | 控制器异常 | disabled（立即） |
| `modeldLag` | 模型推理延迟超阈值 | softDisable |
| `driverUnresponsive` | DMS 走神 + 手离盘超时 | alert → warning → overridden |

### 5.3 soft_disable_timer 与 30 秒规则

OpenPilot 的"渐进告警"通过帧计数实现（`soft_disable_timer`）：

- `soft_disable_timer = 300` 步 @ 100Hz = **3 秒**软禁用倒计时
- 期间逐步退出控制但保留制动
- 倒计时结束 → `overridden`（完全交还驾驶员）

"30 秒规则"是渐进告警链：`alert(~1s) → warning(~5s) → softDisable(3s) → overridden → disabled`，详见 `08_emergency_stop.md` 第 5 节。

### 5.4 panda 硬件安全关卡

OpenPilot 把状态机切成两个执行域：应用域（Python/C++，可崩）与功能安全域（panda STM32H725 固件，不可改）。panda `safety_tick(1Hz)` 监控主 SoC 心跳，心跳停止 → `controls_allowed=false` → CAN 总线拒绝 openpilot 指令 → 控制权回原厂。这是 **failsafe passive** 的硬件级实现：状态机的 `disabled` 态由硬件强制可达。

---

## 6. Mobileye RSS 决策规则

### 6.1 RSS 不是状态机，是决策不变式

Mobileye 的 **RSS（Responsibility Sensitive Safety，2017）** 不建模"状态转移"，而是用**数学公式**定义"何时危险、如何响应"。它可作为任意状态机的**安全不变式**：无论状态机怎么跳，RSS 判定危险时必须强制 Proper Response。

### 6.2 两大公理

1. **不要成为事故的原因（Do not cause an accident / blame）**：自动驾驶汽车永不因自身原因引发碰撞。
2. **不要疏忽（Do not be negligent / inattentive）**：当风险由他人造成时，必须做出合理反应（Proper Response）。

### 6.3 纵向安全距离公式（同向）

```
d_min^long = max{ 0,
    v_r · ρ + ½ · a_max,accel · ρ²
    + (v_r + ρ · a_max,accel)² / (2 · a_min,brake)
    − v_f² / (2 · a_max,brake)
}
```

各项含义：`v_r·ρ` 后车反应时间内匀速距离；`½·a_max,accel·ρ²` 后车反应时间内最坏加速距离；`(v_r+ρ·a_max,accel)²/(2·a_min,brake)` 后车最小合规刹车距离；`v_f²/(2·a_max,brake)` 前车最大急刹缩短距离。

**Proper Response**：一旦 `d < d_min^long`，后车执行"合理制动"（reasonable brake，非最大制动）。RSS 覆盖四种场景：纵向同向、纵向对向、横向、行人。

### 6.4 RSS 与 Apollo rule planner 对比

| 维度 | RSS Proper Response | Apollo Rule Planner |
|------|---------------------|---------------------|
| 决策依据 | 数学公式（d < d_min） | 场景 + 规则配置 |
| 可证明性 | 数学可证明不肇责 | 工程经验值 |
| 适用范围 | 纵向/横向/行人 4 场景 | 11~12 个驾驶场景 |
| 局限 | 不感知传感器失效 | 不数学证明 |
| 角色 | 安全底线（不变式） | 行为决策（主路径） |

理想方案：**RSS 做安全底线，状态机做行为决策**。AuroraDrive 的 `FallbackDetector.check_collision_` 当前用 TTC<1.5s 判定，可升级为 RSS 公式（见第 11 节）。

---

## 7. ROS2 Lifecycle 与决策状态机的融合

### 7.1 LifecycleNode 四主态六过渡

ROS2 的 `rclcpp_lifecycle::LifecycleNode` 提供标准化的节点生命周期状态机（与决策状态机正交，但可借鉴）：

```
                      configure
        ┌─────────────────────────────────┐
        ▼                                  │
   ┌──────────┐ activate  ┌──────────┐    │
   │Unconfigured│─────────▶│ Inactive │    │
   │           │◀─────────│          │    │
   └──────────┘ deactivate└────┬─────┘    │
        │                       │ activate │
        │ cleanup               ▼          │
        │                  ┌──────────┐    │
        │                  │  Active  │    │
        │                  │ (运行中) │    │
        │                  └────┬─────┘    │
        │                       │ deactivate
        │                       ▼
        │                  ┌──────────┐
        └─────────────────▶│Finalized │
            shutdown       │ (终态)   │
                           └──────────┘

   6 个过渡态：Configuring / CleaningUp / ShuttingDown /
              Activating / Deactivating / ErrorProcessing
```

### 7.2 与自动驾驶决策状态机的关系

| 维度 | ROS2 Lifecycle | 自动驾驶决策 FSM |
|------|----------------|------------------|
| 管理对象 | 节点（Node） | 车辆行为（Behavior） |
| 状态语义 | 启停就绪 | 驾驶意图 |
| 触发者 | launch 系统 / 管理 API | 感知/路由/操作手 |
| 是否安全相关 | 否（基础设施） | 是（ASIL） |
| 借鉴点 | 显式过渡回调、错误处理 | — |

**借鉴价值**：Lifecycle 的"过渡态"（Configuring / Activating）概念可用于决策状态机的**安全过渡**——从 LANE_FOLLOW 到 LANE_CHANGE 中间插入一个 `LANE_CHANGE_PREPARING` 过渡态，做最终安全校验，校验通过才真正进入 LANE_CHANGE。AuroraDrive 当前 `fallback_()` 是瞬时切换，无过渡态，存在"刚切换就出错"的风险。

---

## 8. 状态机形式化与模型检查

### 8.1 形式化定义与不变式

FSM 的形式化为五元组 `M = (S, Σ, δ, s0, F)`（见第 1.1 节）。工程上还需定义：

- **不变式（Invariant）**：在所有可达状态都成立的谓词。如"任意时刻 `brake > 0 ⟹ throttle == 0`"、"source_ ∈ {PURE_RULE, FULL_AUTO, CO_DRIVE}"。
- **死锁（Deadlock）**：某状态无任何出边且非终止态，系统卡死。
- **活锁（Livelock）**：状态在环中无限循环但无进展（如两个场景互相 IsTransferable 反复切换）。
- **可达性（Reachability）**：从 s0 是否能到达某状态（如"EMERGENCY_STOP 是否从任意状态可达"——安全要求必须可达）。

### 8.2 模型检查工具

| 工具 | 建模语言 | 验证目标 | 自动驾驶应用 |
|------|---------|----------|-------------|
| **UPPAAL** | 时间自动机（timed automata） | 实时性质、死锁、可达性 | 实时控制器、通信协议、状态机时序 |
| **SPIN** | Promela | LTL 性质、可达性 | 协议验证、并发状态机 |
| **CBMC** | C/C++ 源码 | 有界模型检查、数组越界、空指针 | C++ 决策代码直接验证 |
| **NuSMV** | SMV | CTL/LTL 性质 | 状态机符号模型检查 |

### 8.3 CBMC 验证决策代码

CBMC（CBounded Model Checker）可直接对 C/C++ 源码做有界模型检查：把 FSM 展开k 步，编码为 SAT 实例，验证属性在k 步内是否被违反。对 AuroraDrive，可验证的不变式举例：

```c
// 不变式 1：emergency 状态下 throttle 必为 0
__CPROVER_assert(state == EMERGENCY_STOP ? cmd.throttle == 0.0f : 1,
                 "emergency_stop implies zero throttle");

// 不变式 2：source_ 永不越界
__CPROVER_assert(source_ >= PURE_RULE && source_ <= CO_DRIVE,
                 "source in valid range");

// 不变式 3：CO_DRIVE 后不再回退到 PURE_HUMAN（设计红线）
__CPROVER_assert(source_ != PURE_HUMAN, "never pure human drive");
```

### 8.4 UPPAAL 验证时序

UPPAAL 适合验证"接管时间预算"类时序性质：建模 TOR 发出 → 驾驶员响应 → MRM 启动的时间自动机，验证"TOR 发出后 10s 内要么驾驶员接管、要么 MRM 启动"是否在所有路径上成立。

---

## 9. 接管机制与驾驶员监控

### 9.1 L3 接管请求（TOR）

GB/T 44721-2024《智能网联汽车 自动驾驶系统通用技术要求》（2024-09-29 实施）对 L3 接管的核心要求：

- **接管时间 ≥ 10 秒**：系统发出介入请求后，必须为驾驶员预留至少 10 秒接管时间，期间系统持续保持安全驾驶。
- **多模态提示**：10 秒内必须通过光学 + 声学 + 触觉至少两种模态持续提示，第 4 秒升级为高频振动等强触觉。
- **未接管兜底**：10 秒内未接管 → 系统自动执行 **MRM（最小风险机动）**：平稳减速 + 靠边停车。

### 9.2 接管时间预算链

```
t=0s   系统检测到超出 ODC（设计运行域）
       │
       ▼
t=0s   发出 TOR（视觉 + 听觉）
       │
       ▼
t=4s   升级强触觉（振动）
       │
       ▼
t=10s  驾驶员接管？ ──是──▶ 控制权交还，系统退出
       │
       否
       ▼
t=10s+ 启动 MRM（减速 + 靠边）
       │
       ▼
t=?    车辆进入 MRC（最小风险状态：停止 + 靠边）
```

### 9.3 DMS（驾驶员监控系统）

DMS 是 TOR 的前提——系统必须先知道驾驶员状态，才能决定是否发 TOR。DMS 典型检测项：

| 检测项 | 手段 | 触发动作 |
|--------|------|----------|
| 闭眼 / 瞌睡 | 红外摄像头 + PERCLOS | alert → warning |
| 分心 / 视线偏离 | 视线追踪 | alert → warning |
| 手离方向盘 | 方向盘扭矩 / 电容 | softDisable（OpenPilot） |
| 表情 / 手势 | 图像识别 | 记录 |
| 危险动作（抽烟/打电话） | 图像识别 | warning |
| FaceID | 人脸识别 | 权限管理 |

DMS 对 L4 无意义（无驾驶员），对 L2/L3 必需。AuroraDrive 当前无 DMS，辅助驾驶模式（GAME_ASSIST）下完全依赖用户自觉。

### 9.4 失效降级链

L3/L4 系统的失效降级遵循"fail-safe → fail-operational → MRM"链条：

| 模式 | 定义 | 典型实现 |
|------|------|----------|
| **fail-safe** | 失效后转入安全状态 | 切断控制、靠边停车 |
| **fail-operational** | 失效后降级继续运行 | 双 SoC 冗余，单失效后剩余算力支撑 3 秒安全行驶 |
| **MRM** | 最小风险机动 | 减速 + 靠边（L3）/ 自主处置（L4） |

AuroraDrive 的降级链 `PURE_RULE → FULL_AUTO → CO_DRIVE → EMERGENCY_STOP` 已具备雏形（见第 10 节），但缺少"CO_DRIVE → 用户确认 → PURE_RULE"的恢复路径，存在降级后无法回升的死锁风险。

---

## 10. AuroraDrive 现状源码分析

### 10.1 当前状态机实现

AuroraDrive 的"状态机"分散在三个层面，**没有统一的 HSM 抽象**：

**① 控制源级联（`autonomy.h:59-76`）**

```cpp
enum class ControlSource { PURE_RULE, FULL_AUTO, CO_DRIVE };
enum class Phase { RULE_ONLY, FULL_AUTO, CO_DRIVE };

constexpr ControlSource CASCADE_ORDER[3] = {
    ControlSource::PURE_RULE,
    ControlSource::FULL_AUTO,
    ControlSource::CO_DRIVE,
};

inline ControlSource next_source_on_fallback(ControlSource src) noexcept {
    switch (src) {
        case ControlSource::PURE_RULE: return ControlSource::FULL_AUTO;
        case ControlSource::FULL_AUTO:  return ControlSource::CO_DRIVE;
        case ControlSource::CO_DRIVE:   return ControlSource::CO_DRIVE; // 设计红线
    }
    return ControlSource::CO_DRIVE;
}
```

**② 仿真模式（`simulator.h` 字符串字段）**

```cpp
std::string mode_ = "roam";        // "roam" / "dest"
std::atomic<bool> paused_{false};  // 暂停标志
std::string decision_ = "cruise";  // "brake"/"follow"/"cruise"/"hold" 仅显示
```

**③ 辅助驾驶标志（`simulator.h:266-279`）**

```cpp
std::atomic<bool> assist_capturing_{false};
std::atomic<bool> assist_auto_{false};
std::atomic<bool> assist_key_a_{false}, assist_key_d_{false};
// ...
```

### 10.2 当前 AutonomyStack 决策流（`autonomy.h:913-979`）

```
每帧 step():
  1. 并行推理（规则 + 模型）→ rule_cmd, model_cmd
  2. FallbackDetector.check() → severity
     └─ critical → fallback_()（source_ 前进一级）
  3. 级联仲裁：按 source_ 选主导
     PURE_RULE → rule_cmd
     FULL_AUTO → model_cmd（未加载 → emergency_stop + fallback）
     CO_DRIVE  → blend_co_drive_(model, rule, human)
  4. phase_veto（相位否决）
  5. penalty 软否决（惩罚 > 阈值 → 回退 rule + fallback_）
  6. clamp_command（物理包络）
  7. DAgger 打标
```

### 10.3 当前状态机的不足

| 问题 | 描述 | 风险 |
|------|------|------|
| **无统一 FSM 抽象** | 状态分散在 enum + string + bool，无 Scenario/Stage 概念 | 难维护、难验证、难扩展 |
| **场景缺失** | 无 LANE_CHANGE / PULL_OVER / JUNCTION / PARK_AND_GO | 无法变道、靠边、路口 |
| **降级死锁** | `fallback_()` 只前进不回升，CO_DRIVE 后无法回 PURE_RULE | 降级后永远卡在共驾 |
| **无恢复路径** | 无"user_confirm → reset → PURE_RULE" | 急停后无法自动恢复 |
| **无转移条件形式化** | 无 IsTransferable 等价物，切换靠 severity 字符串比较 | 转移语义隐式、易错 |
| **mode_ 字符串匹配** | `cmd.find("\"roam\"")` 易误匹配（如 dest_name 含 "roam"） | 已在 `simulator.h:1168` 注释规避，但脆弱 |
| **decision_ 仅显示** | "brake/follow/cruise/hold" 不驱动行为 | 误导维护者 |
| **无 RTC 审批** | 无侵入性机动审批 | 多模块冲突无仲裁 |
| **无 DMS / TOR** | 辅助模式无驾驶员监控 | L2/L3 合规缺口 |
| **无形式化验证** | 无不变式、无 CBMC/UPPAAL | 安全性质不可证 |
| **无过渡态** | fallback_() 瞬时切换 | 切换瞬间易出错 |
| **三模式未状态化** | 仿真/游戏/规则验证三模式靠 assist_* 标志，无顶层 Mode 状态 | 模式切换无仲裁 |

### 10.4 当前降级链死锁分析

```
PURE_RULE ──fallback──▶ FULL_AUTO ──fallback──▶ CO_DRIVE ──fallback──▶ CO_DRIVE（自环！）
                                                          │
                                                          ▼
                                              EMERGENCY_STOP（仅 critical 时）
                                                          │
                                                          ▼
                                                       HOLD（无实现）
```

`CO_DRIVE → CO_DRIVE` 是**设计自环**（红线"永不纯人驾"），但缺少"用户确认 → 回 PURE_RULE"的回升边，导致系统一旦降级到 CO_DRIVE 就**永远无法自主回到全规则**，必须外部 reset。这是典型的"可达性不对称"——降级易、升级难。

---

## 11. AuroraDrive 升级方案

### 11.1 设计目标

针对 AuroraDrive（C++ 原生、ONNX 推理、Rust 监督树、Tauri 前端、24Hz 物理、车载硬件、仿真/游戏/规则验证三模式），升级方案目标：

1. 引入**统一 HSM**：Mode → Scenario → Stage 三层，替换散落的 enum/string/bool。
2. 补齐**场景集**：LANE_FOLLOW / LANE_CHANGE / PULL_OVER / EMERGENCY_STOP / JUNCTION / PARK_AND_GO / HOLD。
3. 修复**降级死锁**：增加"用户确认 → 回升"恢复路径。
4. 引入**RTC 审批**：变道/靠边等侵入性机动需系统级批准。
5. 引入**DMS / TOR**：辅助模式（GAME_ASSIST）下渐进告警 + 接管。
6. 引入**过渡态**：借鉴 ROS2 Lifecycle，关键切换插入 PREPARING 态。
7. **形式化验证**：CBMC 验证不变式，UPPAAL 验证接管时序。
8. **三模式顶层状态化**：SIMULATION / GAME_ASSIST / RULE_VALIDATION 作为顶层 Mode。

### 11.2 顶层 HSM 设计草案

```
┌─────────────────────────────────────────────────────────────────────┐
│ TopMode（顶层模式，互斥）                                             │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐         │
│   │ SIMULATION   │  │ GAME_ASSIST  │  │ RULE_VALIDATION  │         │
│   │ (24Hz 仿真)  │  │ (键盘注入游戏)│  │ (规则回归测试)   │         │
│   └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘         │
└──────────┼─────────────────┼───────────────────┼──────────────────┘
           ▼                 ▼                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Scenario（驾驶场景，互斥，IsTransferable 切换）                       │
│   LANE_FOLLOW (默认) │ LANE_CHANGE │ PULL_OVER │ JUNCTION │         │
│   PARK_AND_GO │ EMERGENCY_STOP (终态) │ HOLD (终态)                  │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage（场景内阶段，FinishStage 切换）                                 │
│   如 LANE_CHANGE: PREPARING → EXECUTING → FINISHED                  │
│   如 PULL_OVER:   APPROACH → PARKING → DONE                         │
└─────────────────────────────────────────────────────────────────────┘
           │
           ▼  （正交控制域，与 Scenario 独立）
┌─────────────────────────────────────────────────────────────────────┐
│ ControlDomain（控制源级联，保留现有 PURE_RULE→FULL_AUTO→CO_DRIVE）    │
│   + RECOVERING 过渡态（用户确认后回 PURE_RULE）                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 11.3 状态枚举定义（C++ 草案）

```cpp
// autonomy.h 升级版
enum class TopMode {
    SIMULATION,       // 24Hz 物理仿真（当前 mode_="roam"/"dest"）
    GAME_ASSIST,      // 辅助驾驶（当前 assist_* 标志）
    RULE_VALIDATION,  // 规则回归验证
};

enum class Scenario {
    LANE_FOLLOW,      // 默认巡航
    LANE_CHANGE,      // 变道（含 RTC 审批）
    PULL_OVER,        // 靠边停车
    JUNCTION,         // 路口（含信号灯/停止标志）
    PARK_AND_GO,      // 停车启动
    EMERGENCY_STOP,   // 紧急停车（终态）
    HOLD,             // 停车保持（终态，等待用户确认）
};

enum class Stage {
    PREPARING,        // 过渡态：安全校验
    EXECUTING,        // 执行态
    FINISHED,         // 完成态
    APPROACH,         // PULL_OVER 专用
    PARKING,          // PULL_OVER 专用
    DONE,             // 终态
};

enum class ControlDomain {
    PURE_RULE,
    FULL_AUTO,
    CO_DRIVE,
    RECOVERING,       // ★ 新增：用户确认后的回升过渡态
};

// 替换原 next_source_on_fallback
inline ControlDomain next_on_fallback(ControlDomain d) noexcept {
    switch (d) {
        case ControlDomain::PURE_RULE: return ControlDomain::FULL_AUTO;
        case ControlDomain::FULL_AUTO:  return ControlDomain::CO_DRIVE;
        case ControlDomain::CO_DRIVE:   return ControlDomain::CO_DRIVE; // 红线
        case ControlDomain::RECOVERING: return ControlDomain::PURE_RULE;
    }
    return ControlDomain::CO_DRIVE;
}

// ★ 新增：回升函数（修复降级死锁）
inline ControlDomain recover_to_rule(ControlDomain d) noexcept {
    return ControlDomain::RECOVERING;  // 进入过渡态，下帧校验通过后回 PURE_RULE
}
```

### 11.4 ScenarioManager 草案（借鉴 Apollo）

```cpp
class ScenarioManager {
public:
    // 24Hz 调用
    Scenario update(TopMode mode, const RuleInput& inp, const RuleHealth& health) {
        // ① 终态保持（EMERGENCY_STOP / HOLD 不被抢占，除非用户确认）
        if (current_ == Scenario::EMERGENCY_STOP || current_ == Scenario::HOLD) {
            if (user_confirmed_) { current_ = Scenario::LANE_FOLLOW; user_confirmed_ = false; }
            return current_;
        }
        // ② critical 直接跳 EMERGENCY_STOP
        if (health.severity == "critical") {
            current_ = Scenario::EMERGENCY_STOP;
            return current_;
        }
        // ③ 按优先级遍历场景 IsTransferable
        for (Scenario s : priority_order_) {
            if (is_transferable(s, mode, inp, health)) {
                if (s != current_) { on_exit(current_); on_enter(s); }
                current_ = s;
                return current_;
            }
        }
        // ④ 默认回落
        current_ = Scenario::LANE_FOLLOW;
        return current_;
    }

private:
    bool is_transferable(Scenario s, TopMode mode, const RuleInput& inp, const RuleHealth& h) {
        switch (s) {
            case Scenario::EMERGENCY_STOP: return h.severity == "critical";
            case Scenario::PULL_OVER:      return inp.near_destination;
            case Scenario::JUNCTION:       return inp.at_junction;
            case Scenario::LANE_CHANGE:    return rtc_approved_ && inp.lc_safe;
            case Scenario::PARK_AND_GO:    return inp.ego_static && inp.off_road;
            case Scenario::LANE_FOLLOW:    return true; // 默认
            default: return false;
        }
    }
    Scenario current_ = Scenario::LANE_FOLLOW;
    std::vector<Scenario> priority_order_ = {
        Scenario::EMERGENCY_STOP, Scenario::PULL_OVER, Scenario::JUNCTION,
        Scenario::LANE_CHANGE, Scenario::PARK_AND_GO, Scenario::LANE_FOLLOW
    };
    bool user_confirmed_ = false;
    bool rtc_approved_ = false;
};
```

### 11.5 RTC 审批（借鉴 Autoware）

变道/靠边等侵入性机动引入 RTC 审批：

```cpp
struct RTCRequest {
    Scenario requested_scenario;
    float urgency;       // 0~1，越高越优先
    bool approved = false;
};

class RTCArbiter {
public:
    // 多模块同时请求时，只批准 urgency 最高的
    void submit(const RTCRequest& req) { queue_.push_back(req); }
    RTCRequest decide() {
        if (queue_.empty()) return {};
        auto best = std::max_element(queue_.begin(), queue_.end(),
            [](auto& a, auto& b){ return a.urgency < b.urgency; });
        best->approved = safety_check_(*best);
        RTCRequest r = *best;
        queue_.clear();
        return r;
    }
private:
    std::vector<RTCRequest> queue_;
    bool safety_check_(const RTCRequest& r); // 调用 FallbackDetector + RSS
};
```

### 11.6 DMS / TOR 渐进告警（借鉴 OpenPilot，用于 GAME_ASSIST 模式）

```cpp
enum class DriverAlertState { NORMAL, ALERT, WARNING, SOFT_DISABLE, OVERRIDDEN };

class DriverMonitor {
public:
    void update(bool distracted, bool hands_off, float dt) {
        if (distracted || hands_off) {
            warn_timer_ += dt;
            if      (warn_timer_ > 10.0f) state_ = OVERRIDDEN;   // 超时交还
            else if (warn_timer_ > 7.0f)  state_ = SOFT_DISABLE; // 3s 倒计时
            else if (warn_timer_ > 4.0f)  state_ = WARNING;      // 强触觉
            else                          state_ = ALERT;        // 视觉+听觉
        } else {
            warn_timer_ = 0.0f;
            state_ = NORMAL;
        }
    }
    DriverAlertState state() const { return state_; }
private:
    DriverAlertState state_ = DriverAlertState::NORMAL;
    float warn_timer_ = 0.0f;
};
```

> 说明：GAME_ASSIST 模式下，DMS 触发 OVERRIDDEN 时调用 `assist_release_all_keys()`（已有，`simulator.h:1501`）+ 通知前端 toast，符合 OpenPilot failsafe passive 哲学。

### 11.7 修复降级死锁：恢复路径

```cpp
// AutonomyStack 升级：增加 recover() 方法
void recover() noexcept {
    if (domain_ == ControlDomain::CO_DRIVE || domain_ == ControlDomain::FULL_AUTO) {
        domain_ = ControlDomain::RECOVERING;  // 进入过渡态
        // 下一帧 step() 中：RECOVERING 态做健康自检，通过则回 PURE_RULE
    }
}

// step() 内增加过渡态处理
if (domain_ == ControlDomain::RECOVERING) {
    RuleHealth h = detector_.check(...);
    if (h.severity == "none") {
        domain_ = ControlDomain::PURE_RULE;  // ★ 回升成功，死锁解除
        phase_ = Phase::RULE_ONLY;
    }
    // 否则停留在 RECOVERING，继续等待
}
```

HTTP 新增 `/api/assist/recover` 端点（与 `08_emergency_stop.md` 第 10.7 节的 `/api/assist/resume` 一致），前端 Tauri 命令可触发恢复。

### 11.8 RSS 数学触发器（替换 TTC 阈值）

`FallbackDetector.check_collision_` 当前用 `TTC < 1.5s` 判定 critical，升级为 RSS 安全距离：

```cpp
void check_collision_rss_(std::optional<float> fd, std::optional<float> fs,
                           float ego_speed, RuleHealth& h, bool& critical) {
    if (!fd || *fd < 0.0f) return;
    float front_speed = (fs && *fs >= 0.0f) ? *fs : 0.0f;
    constexpr float rho = 0.5f;            // 反应时间
    constexpr float a_max_accel = 2.0f;    // 后车最大加速
    constexpr float a_min_brake = 4.0f;    // 后车最小合规刹车
    constexpr float a_max_brake = 8.0f;    // 前车最大刹车
    float v_r = (ego_speed - front_speed) / 3.6f;  // m/s
    if (v_r <= 0.0f) return;
    float v_f = front_speed / 3.6f;
    float d_min = v_r * rho + 0.5f * a_max_accel * rho * rho
                + std::pow(v_r + rho * a_max_accel, 2) / (2 * a_min_brake)
                - std::pow(v_f, 2) / (2 * a_max_brake);
    if (*fd < std::max(0.0f, d_min)) {
        h.failures.push_back("rss_violation");
        h.front_collision_imminent = true;
        critical = true;
    }
}
```

### 11.9 CBMC 验证计划

将 `ScenarioManager`、`ControlDomain` 转移函数、`emergency_stop` 提取为纯函数（无副作用），用 CBMC 验证以下不变式：

| 不变式 | CBMC 断言 |
|--------|-----------|
| emergency 状态 throttle=0 | `assert(scenario==EMERGENCY_STOP ? cmd.throttle==0 : 1)` |
| source_ 永不越界 | `assert(domain >= PURE_RULE && domain <= RECOVERING)` |
| 永不纯人驾 | `assert(domain != PURE_HUMAN)` |
| EMERGENCY_STOP 从任意状态可达 | `assert(reachable(s0, EMERGENCY_STOP, k))` for k ≤ 24 |
| HOLD 后必须 user_confirmed 才回 LANE_FOLLOW | `assert(next(HOLD)==HOLD ∨ user_confirmed)` |
| 降级链单调（不可越级回升） | `assert(¬(FULL_AUTO→PURE_RULE without RECOVERING))` |

### 11.10 升级优先级

| 优先级 | 升级项 | 投入 | 收益 |
|--------|--------|------|------|
| P0 | 统一 Scenario 枚举替换 mode_ 字符串 | 低 | 高（消除字符串匹配隐患） |
| P0 | 修复降级死锁（RECOVERING 态 + recover()） | 中 | 高（解除永远卡死） |
| P0 | EMERGENCY_STOP / HOLD 终态保持 + user_confirmed 恢复 | 中 | 高（与 08 报告一致） |
| P1 | ScenarioManager + IsTransferable（借鉴 Apollo） | 中 | 高（场景可扩展） |
| P1 | RTC 审批（借鉴 Autoware） | 中 | 中（侵入机动仲裁） |
| P1 | LANE_CHANGE / PULL_OVER / JUNCTION 场景补齐 | 高 | 高（功能完整性） |
| P1 | TopMode 顶层状态化（三模式） | 中 | 中（模式仲裁） |
| P2 | DMS / TOR 渐进告警（GAME_ASSIST 模式） | 高 | 中（L2/L3 合规） |
| P2 | RSS 数学触发器替换 TTC | 中 | 中（数学底线） |
| P2 | 过渡态 PREPARING（借鉴 ROS2 Lifecycle） | 中 | 中（切换安全） |
| P3 | CBMC 不变式验证 | 高 | 高（安全可证） |
| P3 | UPPAAL 接管时序验证 | 高 | 中（L3 合规） |

### 11.11 与现有模块的协同

升级后的 HSM 不是孤立模块，需与 AuroraDrive 现有安全栈协同：

- **FallbackDetector**：作为 ScenarioManager 的主要输入（`health.severity` → EMERGENCY_STOP 切入条件）。
- **SafetyEnvelope**：Scenario 输出后仍做最终 clamp（保证不超物理极限）。
- **AutonomyStack**：`step()` 内的级联仲裁改为先查 ScenarioManager 再选 ControlDomain。
- **Simulator**：`mode_`/`paused_`/`decision_` 三个字符串字段替换为 `TopMode`/`Scenario` 枚举；`apply_command` 的 `cmd.find()` 匹配改为枚举分发。
- **HTTP Server**：新增 `/api/assist/recover`（恢复）、`/api/scenario`（查询当前场景）端点。
- **Rust 监督树**：把 ScenarioManager 的不变式镜像到 Rust 侧，作为独立监督进程，违反不变式时强制 emergency。
- **Tauri 前端**：状态栏显示 `TopMode / Scenario / Stage / ControlDomain` 四元组，急停时红色覆盖层 + 恢复按钮。

---

## 12. 业界对比表

| 维度 | Apollo | Autoware.Universe | OpenPilot | Mobileye RSS | AuroraDrive（现状） | AuroraDrive（升级后） |
|------|--------|-------------------|-----------|--------------|---------------------|------------------------|
| **顶层范式** | 双层 HSM | HSM + 行为树 | 极简 FSM | 数学规则（非 FSM） | 散落 enum+string+bool | 三层 HSM |
| **状态数** | 11~12 Scenario × 多 Stage | 6 path + 11 velocity 模块 | 4 态 | 4 场景公式 | 3 ControlSource + 2 mode | 7 Scenario × 3 Stage × 4 Domain |
| **转移条件数** | ~30（IsTransferable 汇总） | PlannerManager + RTC | ~10（Events） | 4 公式 | ~5（severity 字符串） | ~20（IsTransferable） |
| **并行状态** | 否（场景互斥） | 是（行为树多子树） | 否 | — | 否 | 否（场景互斥，Domain 正交） |
| **侵入机动仲裁** | Scenario 优先级 | RTC approve/reject | — | — | 无 | RTC 审批 |
| **形式化验证** | 无（工程经验） | 无 | 无 | 数学可证明 | 无 | CBMC + UPPAAL |
| **恢复路径** | PadMessage::START | engage 指令 | 踩油门/按 Set | — | 无（死锁） | user_confirmed → RECOVERING → PURE_RULE |
| **DMS / TOR** | 无（L4 定位） | 无（L4 定位） | 有（30 秒规则） | — | 无 | 有（GAME_ASSIST 模式） |
| **过渡态** | 无 | 无 | 无 | — | 无 | PREPARING（借鉴 ROS2） |
| **三模式支持** | 单模式 | 单模式 | 单模式 | — | 标志位散落 | TopMode 状态化 |
| **实现语言** | C++ + CyberRT | C++ + ROS2 | Python/C++ | C++ | C++ header-only | C++ header-only |

---

## 13. 总结

决策状态机是自动驾驶"行为规划"层的骨架，其设计核心是**状态离散化、转移显式化、终态安全化、恢复可控化**。

- **Apollo** 给出工业级 HSM 模板：Scenario-Stage-Task 双层状态机、ScenarioManager 优先级调度、IsTransferable 形式化切入条件、PadMessage 触发紧急场景、TrafficDecider 正交交规——11~12 场景覆盖完整，但无形式化验证。
- **Autoware.Universe** 给出行为树 + RTC 模板：behavior_path_planner 用行为树管理模块激活、RTC 审批侵入性机动、behavior_velocity_planner 独立交规——模块化更强，但顶层场景数较少。
- **OpenPilot** 给出 L2+ 极简模板：4 态 FSM + Events 系统 + soft_disable_timer 渐进告警 + panda 硬件关卡——failsafe passive 哲学清晰，但仅 L2+。
- **Mobileye RSS** 给出数学底线：Proper Response、Safe Distance、不肇责公理——不是状态机，但可作为任意状态机的安全不变式。
- **ROS2 Lifecycle** 给出过渡态模板：Unconfigured/Inactive/Active/Finalized + 6 过渡态——过渡态概念可借鉴到决策状态机的安全切换。
- **形式化验证**：CBMC 验证 C++ 不变式、UPPAAL 验证时序、SPIN 验证并发——是决策状态机从"工程经验"走向"安全可证"的关键。

**AuroraDrive 当前**：状态散落在 `ControlSource` 枚举 + `mode_` 字符串 + `assist_*` 布尔标志，无统一 HSM；降级链 `PURE_RULE→FULL_AUTO→CO_DRIVE` 存在"降级后无法回升"的死锁；无场景概念（无变道/靠边/路口）；无 DMS/TOR；无形式化验证。

**AuroraDrive 升级方案**核心是：**借鉴 Apollo Scenario-Stage-Task 三层 HSM + IsTransferable，借鉴 Autoware RTC 审批，借鉴 OpenPilot DMS 渐进告警 + failsafe passive，借鉴 ROS2 Lifecycle 过渡态，借鉴 RSS 数学触发器，引入 CBMC/UPPAAL 形式化验证**。具体落地为：`TopMode`（三模式）× `Scenario`（7 场景）× `Stage`（3 阶段）× `ControlDomain`（4 控制域，含 RECOVERING 修复死锁）的四维 HSM，配合 ScenarioManager、RTCArbiter、DriverMonitor 三个新组件，在保持 header-only C++ 简洁性的同时，补齐工业级决策状态机的关键缺口，并通过 CBMC 不变式验证让安全性质从"信誓旦旦"变为"可证可验"。

---

## 参考资料

- Apollo Scenario/Stage/Task 三层架构：https://blog.csdn.net/qq1240268067/article/details/147591619
- Apollo scenario、Stage 插件详解：https://blog.csdn.net/qq1240268067/article/details/148082392
- Apollo Scenario 场景切换条件汇总：https://blog.csdn.net/qq1240268067/article/details/149243587
- Apollo 项目场景化实现机制（双状态机）：https://blog.csdn.net/u010632343/article/details/150989080
- Apollo 项目场景化实际应用分析：https://blog.csdn.net/u010632343/article/details/150989272
- Apollo PublicRoadPlanner 规划器：https://blog.csdn.net/qq1240268067/article/details/148011303
- Apollo traffic_rule 交通规则：https://blog.csdn.net/qq1240268067/article/details/148007096
- Apollo TrafficDecider 交通决策器：https://blog.csdn.net/qhr_1012/article/details/140665514
- Apollo RULE_BASED_STOP_DECIDER：https://blog.csdn.net/sinat_52032317/article/details/132565382
- Apollo 决策模块（FSM）：https://blog.csdn.net/qq1240268067/article/details/151065528
- Apollo Planning 模块技术深度解析：https://blog.csdn.net/weixin_47416810/article/details/154213267
- Apollo park_and_go scenario 思路：https://blog.csdn.net/z_haijie/article/details/145117137
- Apollo EM Motion Planner：https://blog.csdn.net/IHTY_NUI/article/details/115977861
- Autoware.Universe Planning 官方文档：https://blog.csdn.net/gung1r/article/details/147394768
- Autoware Behavior Path Planner 解读：https://blog.csdn.net/robotpengxu/article/details/127976957
- Autoware 变道操作逻辑：https://blog.csdn.net/weixin_48386130/article/details/145751218
- Autoware 静态避障模块：https://blog.csdn.net/weixin_48386130/article/details/145264460
- Autoware control 各节点模块梳理：https://blog.csdn.net/weixin_48386130/article/details/145117183
- Autoware 状态机代码解析：https://blog.csdn.net/weixin_28692817/article/details/159822207
- Autoware behavior_velocity_planner 模块：https://blog.csdn.net/hooksten/article/details/141676132
- OpenPilot selfdrived 守护进程（StateManager）：https://blog.csdn.net/2301_80171004/article/details/150771695
- OpenPilot 项目解析：https://blog.csdn.net/vs2008ASPNET/article/details/128742945
- Mobileye RSS 自动驾驶安全解读：https://cloud.tencent.com/developer/article/1989570
- Mobileye RSS 模型解读：https://m.ofweek.com/auto/2018-07/ART-70109-8420-30246276.html
- Mobileye RSS 推动行业创新：https://m.zol.com.cn/article/7036684.html
- ROS2 LifecycleNode 讲解：https://blog.csdn.net/Bing_Lee/article/details/134958426
- ROS2 在自动驾驶中的应用（lifecycle）：http://m.toutiao.com/group/7651171169483162139/
- Nav2 behavior_tree 详解：https://blog.csdn.net/u010168781/article/details/134190884
- Nav2 行为树 BehaviorTree.CPP：https://blog.csdn.net/u010168781/article/details/156771876
- BehaviorTree.CPP 行为树库：https://blog.csdn.net/gitblog_00056/article/details/137768497
- 行为树 vs 状态机对比：https://m.book118.com/html/2025/0902/6023213113011223.shtm
- HSM 分层状态机详解：https://blog.csdn.net/happygrilclh/article/details/149044291
- FSM/HSM/QP/UML 关联性：https://blog.csdn.net/happygrilclh/article/details/149044291
- 有限状态机形式化定义：https://www.cnblogs.com/math/p/fsm.html
- 模型检验 Model Checking：https://www.testwo.com/article/683
- UPPAAL 实时系统验证：http://lib.cqvip.com/Qikan/Article/Detail?id=21921618
- Bounded Model Checking：https://blog.csdn.net/swallowblank/article/details/107181921
- 形式验证 bounded proof：https://blog.csdn.net/Holden_Liu/article/details/124386087
- GB/T 44721-2024 L3 自动驾驶合规：https://blog.csdn.net/qq_30218571/article/details/154015638
- L3 接管 10 秒窗口分析：https://auto.sina.cn/2026-07-21/detail-iniiqkpe4865536.d.html
- L3 接管时间 5-10 秒：https://k.sina.cn/article_7880068201_1d5b04c6901901ry9o.html
- DDT/DDT Fallback/MRC/MRM 详解：https://m.elecfans.com/article/7002285.html
- DMS 驾驶员监控系统：https://blog.csdn.net/mieshizhishou/article/details/140532074
- DMS 疲劳分心检测：http://www.optzmx.com/forum.php?mobile=1&mod=viewthread&tid=29663
- Apollo GitHub 仓库：https://github.com/ApolloAuto/apollo
- AuroraDrive Emergency Stop 研究（本地）：`纯规则研究/08_emergency_stop.md`
- AuroraDrive FallbackDetector 研究（本地）：`纯规则研究/07_fallback_detector.md`
- AuroraDrive Safety Envelope 研究（本地）：`纯规则研究/06_safety_envelope.md`
- AuroraDrive Mobileye RSS 研究（本地）：`纯规则研究/01_mobileye_rss.md`

---

> 实际工具调用次数：53 次（16 次 WebFetch + 37 次 WebSearch）+ 3 次 Read 本地文件
> 字数：约 9200 字（中文字符）
