# Autoware 控制模块深度研究报告

> 研究对象：Autoware.Universe（基于 ROS2 的开源自动驾驶平台，由 Tier IV 主导维护）的 control 模块
> 对比对象：百度 Apollo、comma.ai OpenPilot
> 目标读者：AuroraDrive 控制研发团队
> 研究方法：WebSearch + WebFetch 多源交叉印证（官方文档 / GitHub / CSDN 源码解析 / 腾讯云社区）

---

## 0. 摘要

本报告围绕 Autoware.Universe 的控制（control）模块展开深度剖析，覆盖控制架构、MPC / Pure Pursuit / PID 三大控制器、横向/纵向控制策略、Vehicle Interface 车辆接口适配，以及与 Apollo、OpenPilot 的横向对比，最终给出 AuroraDrive 控制系统的升级建议。核心结论：Autoware 控制采用"纵向 PID + 横向 MPC（可切 Pure Pursuit）"的解耦架构，以 Ackermann 运动学为通用车辆模型，通过 `vehicle_interface` 适配器实现车型无关；其横向 MPC 在状态空间建模、代价函数权重矩阵、Butterworth 低通滤波与 QP 求解上工程化程度高，是 AuroraDrive 当前"PurePursuit + PID"方案值得借鉴的关键资产。

---

## 1. Autoware 控制架构

### 1.1 control 模块目录结构

Autoware.Universe 的 `control/` 目录下约有 18 个功能包，覆盖了从轨迹跟踪、外部指令切换、安全校验到车辆接口的全部控制职能。主要功能包及职责如下：

| 功能包 | 职责 |
|---|---|
| `autoware_trajectory_follower` | 轨迹跟踪核心节点，调用横向/纵向控制器 |
| `autoware_mpc_lateral_controller` | 横向 MPC 控制器（默认横向控制） |
| `autoware_pure_pursuit` | 横向 Pure Pursuit 控制器（可选横向控制） |
| `autoware_pid_longitudinal_controller` | 纵向 PID 控制器（默认纵向控制，无备选） |
| `autoware_vehicle_cmd_gate` | 控制指令汇总、校验、过滤、发布闸门 |
| `autoware_control_validator` | 控制指令有效性/安全性校验，必要时纠正或拒绝 |
| `autoware_external_cmd_selector` | 外部指令（本地/远程/遥控）选择与优先级仲裁 |
| `autoware_joy_controller` | 手柄/游戏控制器输入转车辆控制指令 |
| `autoware_lane_departure_checker` | 车道偏离检测 |
| `autoware_shift_decider` | 换挡决策 |
| `autoware_collision_detector` | 碰撞风险检测 |
| `autoware_autonomous_emergency_braking` | 自动紧急制动（AEB） |
| `autoware_smart_mpc_trajectory_follower` | 智能 MPC 轨迹跟踪器（增强版） |
| `autoware_rtc_interface` | 实时控制接口 |

### 1.2 控制架构图（文字版）

```
                        ┌─────────────────────────────────────────────┐
   外部输入              │             planning / 定位 / 车辆状态          │
   ┌────────────┐       │   /planning/trajectory  /planning/hazard_cmd  │
   │ 本地/远程    │──┐    └───────────────┬───────────────────────────────┘
   │ 遥控/手柄    │  │                    │
   └────────────┘  ▼                    ▼
            ┌─────────────────┐   ┌──────────────────────────────┐
            │ external_cmd    │   │   trajectory_follower_node     │
            │ _selector       │   │  (controller_node.cpp)        │
            │ (指令仲裁)       │   │   ├─ lateral_controller        │
            └────────┬────────┘   │   │   ├─ MPC (默认)             │
                     │            │   │   └─ Pure Pursuit (可选)    │
                     │            │   ├─ longitudinal_controller    │
                     │            │   │   └─ PID (默认，无备选)      │
                     │            │   └─ latlon_muxer (横纵合成)     │
                     │            └──────────────┬──────────────────┘
                     │                           │ control_cmd (Ackermann)
                     ▼                           ▼
            ┌────────────────────────────────────────────┐
            │            vehicle_cmd_gate                  │
            │  汇总 + 校验(control_validator) + 过滤 + 发布  │
            │  输出: control_cmd / gear_cmd /             │
            │        turn_indicators_cmd / hazard_cmd /   │
            │        emergency_cmd                        │
            └──────────────────────┬─────────────────────┘
                                   │
                 ┌─────────────────┼──────────────────┐
                 ▼                 ▼                  ▼
        ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
        │ shift_decider│  │ AEB / 碰撞检测 │  │ vehicle_interface│
        │ (换挡决策)    │  │ (安全介入)     │  │ (车型适配适配器)  │
        └──────────────┘  └──────────────┘  └────────┬─────────┘
                                                     │
                                                     ▼
                                            ┌──────────────────┐
                                            │   CAN / 车辆底盘   │
                                            └──────────────────┘
```

### 1.3 关键数据流

- **核心控制输出话题**：`/control/command/control_cmd`，消息类型 `autoware_control_msgs::msg::Control`（AckermannControlCommand：含转向角、速度），由 `autoware_trajectory_follower_node` 发布。
- **三大处理模块**：① 路径跟踪 `trajectory_follower`；② 外部指令切换 `external_cmd`；③ 控制指令汇总/校验/发布 `vehicle_cmd_gate`。
- `controller_node.cpp` 持续订阅 planning 给出的目标轨迹、定位给出的车辆位姿、车辆反馈的速度与转角，分发给横/纵向控制器，再由 `latlon_muxer` 合成最终 Ackermann 指令。

### 1.4 与 Apollo 控制的对比（架构层面）

| 维度 | Autoware.Universe | Apollo |
|---|---|---|
| 中间件 | ROS2（DDS） | Cyber RT（自研实时框架） |
| 控制解耦 | 横向/纵向显式解耦，latlon_muxer 合成 | 横向/纵向解耦，ComputeControlCommand 统一调度 |
| 默认横向 | MPC（运动学/动力学自行车模型） | LQR（基于动力学 A/B 矩阵） |
| 默认纵向 | PID | 双 PID（位置-速度双环 + 油门/刹车标定表） |
| 车辆模型 | Ackermann 运动学为主，可扩展动力学 | 动力学单轨模型（自行车模型）为主 |
| 控制输出 | 转向角 + 速度（Ackermann） | 油门 + 刹车 + 方向盘 + 档位 |
| 工程化 | 模块化、可配置、社区协作 | 车规级优化、调度紧密 |

Apollo 偏向"动力学 + LQR + 标定表"的成熟工程路线，Autoware 偏向"运动学 + MPC + 可切换算法"的灵活研究路线。

---

## 2. MPC Controller（autoware_mpc_lateral_controller）

### 2.1 模块结构

`autoware_mpc_lateral_controller` 文件夹包含 6 个 cpp 文件及 3 个子目录，核心包括：
- `mpc_lateral_controller.cpp`：控制器主流程，`run()` 入口，输出 `createCtrlCmdMsg()`（转向角 `steering_tire_angle` 与转向速率 `steering_tire_rotation_rate`）。
- `mpc.cpp`：MPC 求解核心，`calculateMPC()` 函数。
- `vehicle_model/`：车辆模型子目录，含：
  - `vehicle_model_bicycle_kinematics.cpp`（运动学自行车模型）
  - `vehicle_model_bicycle_kinematics_no_delay.cpp`（无延迟运动学）
  - `vehicle_model_bicycle_dynamics.cpp`（动力学自行车模型）
  - `vehicle_model_single_ackermann.hpp`（单阿克曼模型，可扩展）
  - `vehicle_model_interface.cpp`（模型接口基类）
- `lowpass_filter.cpp` / `steering_offset` 等辅助文件。

车辆模型通过参数文件 `mpc.param.yaml` 选择，路径在 `autoware_launch/config/control/trajectory_follower/lateral/` 下，可选项含 `kinematics`、`kinematics_no_delay`、`dynamics`、`single_ackermann`。

### 2.2 状态空间

Autoware MPC 以"误差模型"为核心，状态量围绕参考轨迹的跟踪误差构建。以运动学自行车误差模型为例：

**模型 1：无延迟运动学误差模型**
- 状态量 `x = [e, th]ᵀ`：`e` 横向误差，`th` 航向角误差
- 控制量 `u = δ`：转向角
- 连续状态方程：
  - `ė = v · sin(th)` ≈ `v · th`（小角度）
  - `ṫh = (v/L) · tan(δ) − (v/L) · tan(δ_r)`
  - 经小角度线性化：`ṫh = (v/L)·δ/cos²(δ_r) − (v/L)·δ_r/cos²(δ_r)`
- 矩阵形式：
  ```
  [ė]   [0    v] [e]   [0          ]      [0                 ]
  [ṫh] = [0    0] [th] + [v/L/cos²(δr)] δ + [−v·δr/L/cos²(δr)]
  ```
  其中 `δ_r` 为参考转向角，`v` 车速，`L` 轴距。

**模型 2：考虑转向角变化率的运动学模型**
- 状态量扩展为 `x = [e, th, δ]ᵀ`，新增转向角状态以建模执行器延迟
- 输入为 `δ_d`（目标转向角），`δ̇ = Δδ/t`

**模型 3：动力学自行车模型**
- 引入侧偏刚度、前后轮侧偏角等动力学参数，适用于高速场景。

### 2.3 代价函数与权重矩阵

`calculateMPC()` 中根据车辆模型设置权重矩阵：
- `Q` 矩阵（`dim_y × dim_y`）：对状态/输出误差加权，维度取决于车辆模型的 `getDimY()`。
- `R` 矩阵（`dim_u × dim_u`）：对控制输入加权，维度取决于 `getDimU()`。

典型横向控制权重参数（来自 `mpc.param.yaml`）：
- `mpc_weight_steering_input: 1.0` —— 转向输入误差在矩阵 R 中的权重（限制控制量大小，提升舒适性）
- `mpc_weight_steering_input_squared_vel: 0.25` —— 转向输入误差乘以速度的权重（速度越高，对转向变化越敏感）
- 还包括横向误差、航向误差、横向误差率、航向误差率等权重项。

代价函数典型形式 `J = Σ (xᵀQx + uᵀRu)`，在预测时域 N 内累加，使跟踪误差与控制能耗综合最小。

### 2.4 预测与滤波

- **预测时域**：`N = mpc_param_.prediction_horizon`
- **采样周期**：`DT = mpc_param_.prediction_sampling_time`
- **状态/输入维度**：`DIM_X = vehicle_model_ptr_->getDimX()`，`DIM_U`、`DIM_Y` 同理。
- **最近点插值**：`MPCUtils::calcNearestPoseInterp()` 计算参考轨迹上离车辆最近点、横向误差 `dist_err`、航向误差 `yaw_err`。
- **误差容限检查**：若 `dist_err > admisible_position_error_` 或 `|yaw_err| > admisible_yaw_error_deg_`，则停止 MPC 输出（安全保护）。
- **Butterworth 二阶低通滤波**：`lpf_lateral_error_`、`lpf_yaw_error_` 对横向误差与航向误差滤波后再求导，抑制噪声、平滑控制。
- **转向速率计算**：`calcDesiredSteeringRate(mpc_matrix, x0_delayed, Uex, u_filtered, current_steer, ...)` 输出 `steering_tire_rotation_rate`。

### 2.5 求解器

Autoware MPC 将滚动时域优化问题转化为**二次规划（QP）**问题求解。核心流程：
1. 建立预测方程 `X = A_ex · x0 + B_ex · U`（展开预测时域内的状态）。
2. 构造 QP 标准形式：`min 0.5·UᵀH·U + fᵀ·U`，受约束 `U_min ≤ U ≤ U_max`（转向角/转向速率约束）。
3. 调用 QP 求解器（Autoware 内嵌 QP solver，源码中 `qp_solver` 错误处理："`[MPC] qp solver error`"），求解最优控制序列 `U`。
4. 取首步控制量施加于车辆（滚动时域 Receding Horizon）。

> 注：Apollo MPC 采用 OSQP（Operator Splitting Quadratic Program）求解器，Autoware 早期 mpc_follower 使用 Eigen 自带 QP，新版 universe 中同样以 QP 为主，无显式非线性求解。

### 2.6 与 Apollo MPC 的对比

| 维度 | Autoware MPC | Apollo MPC |
|---|---|---|
| 默认横向算法 | MPC（默认）/ Pure Pursuit（可选） | LQR（默认）/ MPC（可选） |
| 车辆模型 | 运动学/动力学误差模型，多模型可选 | 动力学单轨模型为主 |
| 状态量 | 误差模型 [e, th, δ] | 误差状态 [横向位置误差, 误差率, 航向误差, 航向误差率] |
| 求解器 | QP（凸二次规划） | OSQP |
| 工作时域 | 有限预测时域 N，滚动优化 | 有限时域，滚动优化 |
| 目标函数 | xᵀQx + uᵀRu 二次型 | 二次型，含终端代价 |
| 约束 | 转向角/速率上下限 | 转向角/速率上下限 |
| 滤波 | Butterworth 二阶低通滤波误差 | 频域滤波 + 低通 |
| 适用速度 | 运动学模型偏低速，动力学可提速 | 动力学模型适配中高速 |

MPC 与 LQR 的本质差异：LQR 是无限时域、离线求解 Riccati 方程得状态反馈增益；MPC 是有限时域、在线滚动求解 QP，可显式处理约束但计算量大。Autoware 优先 MPC 体现其"在线优化 + 约束处理"的设计取向。

---

## 3. Pure Pursuit（autoware_pure_pursuit）

### 3.1 算法概述

Pure Pursuit 是基于几何的轨迹跟踪算法：将阿克曼转向车辆抽象为自行车两轮模型，以后轴为切点、车辆纵向车身 为切线，通过前视目标点构建圆弧约束，计算前轮转向角。核心思想简单、计算量小，是经典的横向控制基线。

### 3.2 文件结构

`autoware_pure_pursuit` 主要文件：
- `pure_pursuit_node.cpp`（或 `autoware_pure_pursuit_node.cpp`）：main 入口、ROS 话题收发。
- `pure_pursuit_core.cpp`：话题回调与发布实现。
- `pure_pursuit.cpp`（核心 `autoware_pure_pursuit_lateral_controller.cpp`）：路径点有效性判定、曲率计算，是核心控制模块。
- `pure_pursuit_viz.cpp`：Rviz 可视化。

涉及两个类：`PurePursuitNode`（框架定义）与 `PurePursuit`（算法计算）。

### 3.3 预瞄距离（lookahead distance）

`computeLookaheadDistance()` 动态计算预瞄距离：
```cpp
const double maximum_lookahead_distance = current_linear_velocity_ * 10;  // 上限 = 速度×10
const double ld = current_linear_velocity_ * lookahead_distance_ratio_;   // 基准 = 速度×K
return clamp(ld, minimum_lookahead_distance_, maximum_lookahead_distance_);
```
- 预瞄距离 `ld = v × ratio`，随车速线性增长。
- 受 `minimum_lookahead_distance_` 与 `max = v×10` 双向钳制。
- 实测经验法则：`前视距离 = min(3.5m, 0.3×车速)`（社区总结）。

### 3.4 转向角计算

1. **`getNextWaypoint()`**：遍历规划路径点，找到首个距车辆当前位置超过预瞄距离的点作为目标点。
2. **`calcRelativeCoordinate()`**：将目标点转换到车辆当前位姿坐标系下得相对坐标 `(x, y)`。
3. **`calcCurvature()`**：利用相似三角形几何关系求圆弧曲率：
   ```
   κ = 2·y / (x² + y²)
   ```
4. **`convertCurvatureToSteeringAngle()`**：曲率转转向角：
   ```
   δ = atan(wheel_base · κ)
   ```
   其中 `wheel_base` 为轴距。

### 3.5 线性插值与有效性校验

- `canGetCurvature()` 判断路径点有效性：仅当存在距车辆超过 `minimum_lookahead_distance_` 的点时曲率有效。
- `interpolateNextTarget()`：对下一目标点做线性插值，平滑目标位置，计算角速度。

### 3.6 与 AuroraDrive PurePursuit 的对比

| 维度 | Autoware Pure Pursuit | AuroraDrive（当前） |
|---|---|---|
| 预瞄距离策略 | 速度比例 `ld=v·ratio` + 上下限钳制 | 建议采用相同速度自适应策略 |
| 目标点选取 | 首个超过预瞄距离的点 + 线性插值 | 待确认 |
| 曲率计算 | `κ=2y/(x²+y²)` 相对坐标几何法 | 待确认 |
| 转向角 | `atan(L·κ)` | 建议对齐 |
| 输出 | 转向角 + 预测路径 | 待对接 |

AuroraDrive 若沿用 Pure Pursuit，建议直接借鉴 Autoware 的预瞄距离自适应 + 线性插值平滑 + Butterworth 滤波组合，以改善高速跟踪稳定性。

---

## 4. PID Controller（autoware_pid_longitudinal_controller）

### 4.1 模块结构

`autoware_pid_longitudinal_controller` 文件组成：
- `pid_longitudinal_controller.hpp / .cpp`：纵向控制器主类 `PidLongitudinalController`，入口 `run(trajectory_follower::InputData)`。
- `pid.cpp`：通用 PID 实现。
- `longitudinal_controller_utils.cpp`：纵向控制工具函数。
- `smooth_stop.cpp`：平滑停车逻辑（防止急刹、提升舒适性）。

### 4.2 横向 / 纵向分工

Autoware 中 PID 主要用于**纵向控制**（速度跟踪），横向默认由 MPC 接管。`trajectory_follower_node` 中：
- 纵向控制默认 PID 模块，`PidLongitudinalController::run(input_data)` 输出车辆速度/加速度。
- 横向控制默认 MPC，可选 Pure Pursuit。
- `latlon_muxer` 将横纵向输出合成 Ackermann 控制指令。

### 4.3 纵向 PID 要点

- 输入：目标轨迹（含速度规划）、当前车速、车辆状态。
- 输出：加速度/速度指令。
- `smooth_stop.cpp` 在接近停车点时切换为平滑停车策略，避免末端抖动。
- PID 参数可配置，含 P/I/D 增益及抗饱和（anti-windup）等。

### 4.4 与 Apollo PID 的对比

| 维度 | Autoware 纵向 PID | Apollo 纵向 PID |
|---|---|---|
| 结构 | 单环 PID + 平滑停车 | 双环 PID（位置-速度双环） |
| 标定 | 无显式油门/刹车标定表 | 油门/刹车标定表（calibration table） |
| 输出 | 速度/加速度 | 油门/刹车值（throttle/brake） |
| 控制层级 | 速度环为主 | 位置外环 + 速度内环 |
| 平滑策略 | smooth_stop 模块 | MRAC（模型参考自适应）+ 预瞄 |

Apollo 纵向更"工程化"：双环 + 标定表 + MRAC，直接输出底盘可执行的油门/刹车；Autoware 纵向更"简洁"：PID + smooth_stop，输出加速度/速度，再由 vehicle_interface 转底盘。

---

## 5. Lateral Control（横向控制策略）

### 5.1 横向控制策略

Autoware 横向控制以"误差最小化"为目标，支持两种算法：
1. **MPC（默认）**：基于误差模型预测未来状态，在线 QP 求解最优转向序列，显式处理转向角/速率约束，平滑且抗扰。
2. **Pure Pursuit（可选）**：几何法，预瞄目标点求曲率转转向角，简单高效，适合低速/简单路况。

### 5.2 MPC / Pure Pursuit / PID 切换

- 横向算法通过参数文件 `lateral` 下的 `controller` 选项切换（`mpc` / `pure_pursuit`）。
- 纵向固定 PID，无备选算法。
- **切换并非运行时动态**，而是部署期配置选择；运行期通过 `vehicle_cmd_gate` 做指令级仲裁与安全过滤。
- AEB、碰撞检测、车道偏离检测等安全模块可强制介入/覆盖横向输出。

### 5.3 与 OpenPilot LatControl 的对比

| 维度 | Autoware 横向 | OpenPilot 横向 |
|---|---|---|
| 算法集 | MPC / Pure Pursuit | 多控制器：latcontrol_torque / latcontrol_angle / latcontrol_pid |
| 架构 | 单控制器配置切换 | 抽象基类 + 多控制器继承，运行期可选 |
| 控制对象 | 转向角 + 转向速率 | 方向盘扭矩 / 方向盘角度 |
| 模型 | 误差状态空间 | 基于曲率/横向加速度跟踪 |
| 切换方式 | 配置期 | 运行期按车型/模式 |
| 适用 | L4 全自动驾驶 | L2+ ADAS（车道居中） |

OpenPilot 的多控制器运行期切换更灵活（适配 250+ 车型），Autoware 的 MPC 在约束优化与状态预测上更严谨。OpenPilot 横向核心目标是在保证舒适性下实现厘米级车道居中。

---

## 6. Longitudinal Control（纵向控制策略）

### 6.1 纵向控制策略

Autoware 纵向控制采用 **PID + 速度规划**：
- 规划层输出含速度的轨迹，纵向 PID 跟踪目标速度。
- `smooth_stop` 处理停车段平滑过渡。
- 输出加速度/速度，由 vehicle_interface 转 CAN。
- 纵向无 MPC 备选（与 OpenPilot 不同，OpenPilot 纵向用 LongitudinalMpc）。

### 6.2 与 Apollo PID 的对比

Apollo 纵向：位置-速度双环 PID + 油门刹车标定表 + MRAC 自适应，直接输出底盘 throttle/brake；Autoware 纵向：单环 PID + smooth_stop，输出加速度，抽象层级更高、更车型无关。

---

## 7. Vehicle Interface（车辆接口）

### 7.1 vehicle_interface 设计

Autoware 控制设计哲学：**只处理通用（generic）Ackermann 车辆**，车型差异通过 `vehicle_interface` 适配器隔离。控制输出 `/control/command/control_cmd` 基于 Ackermann 运动学模型（横向：转向角，纵向：速度）。

Ackermann 模型关键：所有轮子轴线交于一点，各轮以不同半径共同圆心描绘圆弧，最小化轮胎滑移。输入为纵向速度 `v` 与转向角 `δ`。

### 7.2 CAN 通信与话题接口

**来自 Autoware 的输入（控制指令）**：
| 话题 | 类型 | 说明 |
|---|---|---|
| `/control/command/control_cmd` | AckermannControlCommand | 转向角、速度 |
| `/control/control_mode_request` | ControlModeCommand | 手/自动切换 |
| `/control/command/gear_cmd` | GearCommand | 档位 |
| `/control/command/hazard_lights_cmd` | HazardLightsCommand | 危险灯 |
| `/control/command/turn_indicators_cmd` | TurnIndicatorsCommand | 转向灯 |

**输出到 Autoware（车辆状态）**：
| 话题 | 说明 |
|---|---|
| `/vehicle/status/actuation_status` | 当前加速度/制动/转向（机械输入车辆可选） |
| `/vehicle/status/control_mode` | 控制模式 |
| `/vehicle/status/gear_status` | 档位 |
| `/vehicle/status/steering_status` | 转向轮胎角度 |
| `/vehicle/status/steering_wheel_status` | 方向盘角度（可选） |
| `/vehicle/status/velocity_status` | 纵/横/航向速率 |
| `/vehicle/status/turn_indicators_status` | 转向灯状态 |
| `/vehicle/status/hazard_lights_status` | 危险灯状态 |
| `/vehicle/status/door_status` | 门状态（可选） |

### 7.3 各车型适配

- 通过 `vehicle_interface.launch.xml` 添加自定义通讯节点。
- 参考实现：`vehicle/external/pacmod_interface`（PACMOD 平台）。
- 适配流程：建立 package 目录 → ROS 节点订阅 Autoware 指令 → 转 CAN → 反馈状态话题。
- 因标准版不提供底盘信号接口，开发者需自行实现车辆通信。
- 官方设计文档将 vehicle interface adapter 作为车辆适配的核心抽象。

### 7.4 与 OpenPilot CarInterface 的对比

| 维度 | Autoware vehicle_interface | OpenPilot CarInterface |
|---|---|---|
| 语言 | C++ / ROS2 | Python |
| 抽象 | 适配器模式（adapter） | 抽象基类 + 子类继承 |
| CAN 硬件 | 由适配节点实现 | panda 接口卡统一 |
| 车型数据库 | 配置文件 + launch | CarParams 标准化结构（品牌/车型/年份/CAN/控制参数） |
| 支持车型 | 数量较少，按项目适配 | 325+ 车型 |
| 分层 | 节点级适配 | 硬件抽象 + 数据解析 + 决策 + 指令转换四层 |
| 新车适配 | 数周（需写节点） | 2-4 周（标准化流程 + cabana 工具） |
| DBC 管理 | 自行处理 | 标准化 CAN 信号解析器 |

OpenPilot 的 CarInterface 标准化程度更高（统一 CarState / CarParams / panda），车型覆盖广；Autoware 的 vehicle_interface 更灵活但需更多定制开发。

---

## 8. Autoware 控制源码（autoware.universe/control）

### 8.1 关键源码模块

- **autoware_trajectory_follower / mpc_trajectory_follower**：`controller_node.cpp` 是核心，订阅 planning 轨迹、定位、车辆反馈，调度横/纵向控制器，经 `latlon_muxer` 合成，发布 `/control/command/control_cmd`。
- **autoware_mpc_lateral_controller**：`mpc.cpp` 的 `calculateMPC()` 是算法核心，含预测时域展开、QP 构造与求解、误差滤波、转向速率计算。
- **autoware_pure_pursuit**：`pure_pursuit.cpp` 的 `canGetCurvature()` + `convertCurvatureToSteeringAngle()` 完成几何跟踪。
- **autoware_pid_longitudinal_controller**：`pid_longitudinal_controller.cpp` 的 `run()` + `smooth_stop.cpp`。
- **autoware_vehicle_interface**：适配器层，转 CAN。
- **autoware_smart_mpc_trajectory_follower**：智能 MPC 增强版，结合 trajectory optimizer。
- **autoware_vehicle_cmd_gate**：最终指令闸门，汇总 control/gear/turn_indicator/hazard/emergency 指令并校验发布。

### 8.2 源码关键流程（MPC 横向）

```
run() 
 → 订阅 trajectory / pose / velocity / steer
 → createCtrlCmdMsg()
    → calculateMPC()
       → calcNearestPoseInterp()  求最近点、横向/航向误差
       → 误差容限检查 (dist_err / yaw_err)
       → 低通滤波误差 (Butterworth)
       → 构造预测方程 X = A_ex·x0 + B_ex·U
       → 构造 QP (Q/R 权重矩阵)
       → QP solver 求解 U*
       → u_filtered 低通滤波控制量
       → calcDesiredSteeringRate() 输出转向角 + 转向速率
 → 发布 control_cmd
```

### 8.3 源码关键流程（Pure Pursuit 横向）

```
PurePursuitNode::run()
 → computeLookaheadDistance()   ld = clamp(v·ratio, min, v·10)
 → getNextWaypoint()            找超预瞄距离的目标点
 → interpolateNextTarget()      线性插值平滑
 → calcCurvature()              κ = 2y/(x²+y²)
 → convertCurvatureToSteeringAngle()  δ = atan(L·κ)
 → publishCtrlCmdStamped()      发布速度/加速度/转角
```

---

## 9. Autoware vs Apollo vs OpenPilot 控制对比

### 9.1 控制算法差异

| 维度 | Autoware.Universe | Apollo | OpenPilot |
|---|---|---|---|
| 定位 | L4 全自动驾驶开源平台 | L4 全自动驾驶开源平台 | L2+ ADAS 消费级 |
| 横向默认 | MPC（误差模型 + QP） | LQR（动力学 + Riccati） | latcontrol_torque / pid 多选 |
| 横向备选 | Pure Pursuit | MPC（OSQP） | latcontrol_angle |
| 纵向默认 | PID + smooth_stop | 双 PID + 标定表 + MRAC | LongitudinalMpc（MPC） |
| 车辆模型 | 运动学/动力学自行车 + 单阿克曼 | 动力学单轨 | 车型参数库 CarParams |
| 求解器 | QP | OSQP（MPC）/ Riccati（LQR） | MPC（纵向） |
| 控制输出 | 转向角 + 速度（Ackermann） | 油门 + 刹车 + 方向盘 + 档位 | 方向盘扭矩/角度 + 油门/刹车 |
| 中间件 | ROS2 | Cyber RT | 自研 daemon（Python/C++） |
| 车型适配 | vehicle_interface 适配器 | canbus 模块 | CarInterface（325+ 车型） |
| 安全模块 | AEB / 碰撞检测 / 车道偏离 / cmd_gate | 决策 + 安全层 | driver monitoring + 事件系统 |

### 9.2 性能差异

- **Autoware MPC**：约束处理强、跟踪平滑、可处理多目标代价；计算量大于 LQR，实时性依赖 QP 求解速度；运动学模型低速精度高，动力学模型可中高速。
- **Apollo LQR**：离线求解增益、在线计算量小、实时性好；无显式约束处理（靠限幅）；动力学模型中高速稳态精度高；纵向双 PID + 标定表工程成熟、底盘直控精度高。
- **OpenPilot**：横向多控制器运行期切换、适配性极强；纵向端到端 + MPC，0.9.0 后引入模仿学习纵向规划；L2+ 场景下舒适性优、厘米级居中。

### 9.3 适用场景差异

- **Autoware**：园区/城市 L4、科研教学、需灵活切换算法的研究型项目、ROS2 生态集成。
- **Apollo**：车规级 L4 落地、需紧密调度与高实时性、成熟工程标定体系。
- **OpenPilot**：消费级 L2+ 后装、多车型快速适配、低成本硬件（comma 3）、海量实车里程验证。

---

## 10. AuroraDrive 控制升级方案

### 10.1 AuroraDrive 当前状态

- 横向：Pure Pursuit
- 纵向：PID
- 架构：横纵向解耦，类似 Autoware 早期形态。

### 10.2 借鉴 Autoware MPC 的建议

**建议 1：引入误差状态空间 MPC 作为横向主控**
- 采用 Autoware 运动学自行车误差模型，状态 `[e, th, δ]`（横向误差、航向误差、转向角）。
- 代价函数 `J = Σ(xᵀQx + uᵀRu)`，权重矩阵参考 Autoware `mpc.param.yaml`：
  - `mpc_weight_steering_input`（控制能耗）
  - `mpc_weight_steering_input_squared_vel`（速度自适应加权）
- QP 求解器选型：轻量场景用 Eigen QP / osqp-eigen；性能敏感用 OSQP。
- 收益：显式约束转向角/速率、预测未来误差、平滑跟踪，优于纯几何 Pure Pursuit。

**建议 2：引入 Butterworth 二阶低通滤波误差求导**
- 对横向误差、航向误差滤波后再求误差率，抑制传感器噪声，提升微分项稳定性。
- 直接移植 Autoware `lowpass_filter.cpp` 的 `butterworth2dfilter`。

**建议 3：移植误差容限安全检查**
- `dist_err > admisible_position_error` 或 `|yaw_err| > admisible_yaw_error` 时停止控制输出，防止发散。

### 10.3 借鉴 Autoware 三策略切换的建议

**建议 4：构建横向多算法可切换架构**
- 抽象横向控制器基类（参考 Autoware `vehicle_model_interface` + OpenPilot 抽象基类）。
- 实现：MPC（主）/ Pure Pursuit（备）/ PID（应急）三策略。
- 切换策略：
  - 低速/简单路况：Pure Pursuit（计算小、鲁棒）
  - 中高速/复杂路况：MPC（约束优化、平滑）
  - MPC 求解失败/降级：PID 兜底
- 配置期默认选 MPC，运行期保留降级路径。

**建议 5：纵向引入 smooth_stop 平滑停车**
- 移植 `smooth_stop.cpp`，停车段切换平滑策略，消除末端抖动。
- 可选：参考 Apollo 双环 PID + 标定表，提升底盘直控精度（若 AuroraDrive 直控油门/刹车）。

### 10.4 借鉴 vehicle_interface 适配器

**建议 6：抽象 vehicle_interface 适配层**
- 参考 Autoware 适配器模式 + OpenPilot CarInterface 标准化。
- 定义统一控制接口（转向角/速度/档位/灯光）与统一状态反馈（速度/转向/档位/控制模式）。
- 各车型实现独立适配节点，AuroraDrive 控制核心保持车型无关。

### 10.5 升级路线图

```
阶段 1（短期）：移植 Autoware Pure Pursuit 预瞄自适应 + 线性插值 + 误差滤波
阶段 2（中期）：实现误差模型 MPC（运动学），QP 求解，对照 Autoware 权重调参
阶段 3（中期）：构建横向控制器基类，实现 MPC/PP/PID 三策略可切换
阶段 4（长期）：引入动力学模型 MPC 提速；纵向 smooth_stop / 双环 PID 评估
阶段 5（长期）：vehicle_interface 适配器抽象，多车型标准化适配
```

### 10.6 风险与权衡

- MPC 计算量大于 Pure Pursuit，需评估车端算力与控制周期（建议 50-100Hz）。
- 运动学模型高速精度下降，需根据 AuroraDrive 速度域决定是否引入动力学模型。
- 多策略切换引入复杂度，需明确切换条件与无扰动（bumpless）过渡。
- QP 求解失败需有兜底（PID/保持上一拍），确保安全。

---

## 11. 结论

Autoware.Universe 控制模块以"误差模型 MPC + PID 纵向 + Ackermann 通用模型 + vehicle_interface 适配器"为核心，工程化程度高、模块化清晰、算法可切换。其横向 MPC 在状态空间建模、代价函数权重、Butterworth 滤波、QP 求解、误差容限安全检查等方面是成熟可借鉴的资产。相较 Apollo 的"LQR + 双 PID 标定表"工程路线与 OpenPilot 的"多控制器运行期切换 + MPC 纵向"消费级路线，Autoware 提供了兼顾研究灵活性与工程严谨性的中间路线。

对 AuroraDrive 而言，短期可低成本借鉴 Pure Pursuit 增强与误差滤波；中期建议引入误差模型 MPC 并构建三策略可切换横向架构；长期可推进 vehicle_interface 标准化与动力学模型升级。整体升级应遵循"先借鉴、再切换、后标准化"的渐进路径，确保安全与可控。

---

## 参考资料

1. Autoware 官方文档 - Control component design
2. GitHub - autowarefoundation/autoware_universe
3. CSDN - Autoware.universe 控制部分源码梳理（一~五）
4. CSDN - Autoware 的 MPC 源码解析（mpc_follower calculateMPC / 车辆模型介绍）
5. 腾讯云 - Autoware mpc_follower 模型预测控制节点
6. CSDN - Autoware pure pursuit 纯跟踪算法代码分析
7. CSDN - Apollo 代码学习 MPC 与 LQR 比较
8. CSDN - Apollo LQR/MPC 侧向控制算法分析
9. CSDN - Apollo Control 纵向控制算法与流程图
10. CSDN - openpilot 车辆接口标准化 / 横向控制算法
11. CSDN - OpenPilot 分析：从图像到油门/刹车
12. Autoware.Auto 控制器设计（火龙果软件翻译）
13. CSDN - autoware 整体架构分析
14. CSDN - autoware.universe 实车实战：适配调试小车

---

> 实际工具调用次数：约 54 次（WebSearch + WebFetch 合计，含部分超时重试与失败重抓）
> 报告字数：约 6200 字（不含代码块与表格的纯字符统计）
