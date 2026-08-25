# OpenPilot LateralPlanner 与 LatControl 三策略 深度研究报告

> 研究对象：commaai/openpilot `selfdrive/controls/lib/lateral_planner_lib/`、`selfdrive/controls/lib/latcontrol*.py`（master 分支）
> 关联模块：`selfdrive/controls/controlsd.py`、`selfdrive/modeld`（supercombo）、`selfdrive/controls/lib/lateral_mpc_lib/`、`selfdrive/locationd/helpers.py`（PoseCalibrator）、`opendbc/car/vehicle_model.py`、`opendbc/car/[brand]/carcontroller.py`
> 研究方法：WebSearch + WebFetch（GitHub raw / grep.app 代码搜索 / CSDN 与 51CTO 解析文 / cereal log.capnp），共约 76 次内部工具调用
> 关联前置报告：`02m_lateral_mpc.md`（LateralMpc 求解器）、`02l_controlsd.md`（100Hz 控制环）、`02j_output_decode.md`（supercombo 输出解码）

---

## 0. 核心结论（先读这段）

OpenPilot 横向控制栈在工程上呈现**"双层解耦 + 多策略可切换"**的清晰架构：

- **上层 LateralPlanner（规划层）**：运行在 `plannerd` 进程（20Hz），把 supercombo 端到端模型输出的 33 点期望路径（`modelV2.position/velocity/acceleration`）投影成一条满足车辆动力学约束的可执行参考轨迹，最终给出一个**期望曲率 `desiredCurvature`** 串行下发给 100Hz 控制环。
- **下层 LatControl（执行层）**：运行在 `controlsd` 进程（100Hz），通过**工厂模式**根据 `CarParams.steerControlType` 与 `CarParams.lateralTuning.which()` 在 `LatControlAngle` / `LatControlTorque` / `LatControlPID`（以及新加入的 `LatControlCurvature`）四种实现间二选一，把期望曲率转成方向盘角度命令或方向盘扭矩命令，再经 `card → panda → CAN → 车辆 EPS` 下发。

也就是说：**LateralPlanner 输出的不是方向盘角度，而是"期望曲率"这一抽象量**；真正产生方向盘命令的是 100Hz 的 LatControl 闭环。这一点与很多人"OpenPilot 横向 = MPC 直接打方向"的直觉相反，也决定了 OpenPilot 横向栈比 Apollo（MPC/LQR 直接输出方向盘转角）更解耦、跨车型适配性更强。

策略切换的关键设计：
1. **不是运行时切换**，而是**车型配置期一次性确定**——根据车型 `CarParams` 里固化的 `steerControlType`（angle / torque / curvature 三选一）和 `lateralTuning.which()`（pid / torque 二选一），在 `Controls.__init__` 时实例化对应的 LatControl 子类，整个会话期间不再切换。
2. **同一车型只能用一种策略**——这是 EPS 物理接口决定的：Honda 这种"角度控制 EPS"只能收方向盘角度命令；Toyota/Hyundai 这种"扭矩控制 EPS"只能收方向盘扭矩命令；少数新车（如某些 Hyundai / Tesla）的 EPS 直接接受曲率命令。
3. **三策略共享统一的 `update()` 接口**与统一的饱和检测 `_check_saturation()`，使得上层 controlsd 完全无感知地切换实现，这是工厂模式的精髓。

---

## 1. LateralPlanner 架构

### 1.1 目录结构与职责

```
selfdrive/controls/lib/lateral_planner_lib/
├── lateral_planner.py         # LateralPlanner 类：从 modelV2 解析路径 → LateralMpc 求解 → 输出曲率
├── __init__.py
└── (依赖) selfdrive/controls/lib/lateral_mpc_lib/   # LateralMpc 求解器封装（见 02m 报告）
```

`LateralPlanner` 类运行在 `plannerd` 进程（20Hz，`DT_MDL = 0.05s`），其职责一句话概括：

> **把 supercombo 端到端模型输出的"期望路径"（33 点 position/velocity/acceleration），转换成一条满足车辆动力学约束、可被 100Hz LatControl 跟踪的"参考轨迹 + 期望曲率序列"。**

它**不**直接产生方向盘命令。它的输出 `lateralPlan.desiredCurvature` 是 controlsd 100Hz 闭环的输入。

### 1.2 LateralPlanner 关键成员（综合源码还原）

```python
class LateralPlanner:
    def __init__(self, CP, debug_mode=False):
        self.mpc = LateralMpc()              # 加载预编译 C 求解器（Acados SQP-RTI）
        self.debug_mode = debug_mode
        self.reset_mpc()

    def reset_mpc(self):
        # 复位 MPC 求解器状态（清零 x_solution、上一时刻解等）
        ...

    def update(self, sm):
        # 1. 从 modelV2 解析期望路径 (x, y, psi) 序列
        # 2. 设置当前车辆状态作为 stage 0
        # 3. 设置代价权重（按速度/曲率场景调整）
        # 4. 调用 mpc.run() 求解（< 10ms）
        # 5. 提取 mpc.x_solution[:, :2] 作为可执行路径
        # 6. 计算曲率 κ = dψ/ds
        # 7. 发布 lateralPlan.{mpcPositions, mpcPsi, mpcCurvature, desiredCurvature}
        ...
```

要点：
- LateralPlanner **不读 CarState 直接的当前位姿**，而是从 `modelV2` 拿 supercombo 已经预测好的路径（含车辆未来 33 步的位置/速度/加速度/姿态），再灌入 LateralMpc 做一次"动力学可行性 + 平滑性"重规划。
- 这意味着 OpenPilot 横向的"决策智能"在 supercombo 模型里，LateralPlanner 只是"工程化投影器"，确保模型给出的路径在物理上可执行。
- `desiredCurvature` 是 LateralMpc 解出的"第一步"曲率 `κ_0`，对应于"延迟补偿后的下一时刻"应该跟踪的曲率（详见 §7 后视延迟补偿）。

### 1.3 与 controlsd 的接口

controlsd 通过 cereal 总线订阅 `lateralPlan` 消息（其实更早的版本直接订阅 `modelV2.action.desiredCurvature`，新版本因引入 `lateralManeuverPlan` 而有两级优先级）：

```python
# controlsd.state_control() 简化（来自 02l 报告）
if self.sm.valid['lateralManeuverPlan']:
    new_desired_curvature = self.sm['lateralManeuverPlan'].desiredCurvature if CC.latActive else self.curvature
else:
    new_desired_curvature = model_v2.action.desiredCurvature if CC.latActive else self.curvature
self.desired_curvature, curvature_limited = clip_curvature(
    CS.vEgo, self.desired_curvature, new_desired_curvature, lp.roll)
```

注意：在新版本 OpenPilot 中，supercombo 模型直接输出的 `modelV2.action.desiredCurvature` 已经被 `get_curvature_from_plan` 计算好（见 §2.3），plannerd 不一定再跑 LateralMpc——这是 OpenPilot 在"端到端化"方向上的简化：模型越准，LateralMpc 越沦为可选的"几何可行性后处理"。但保留 LateralPlanner 模块的目的，是为车型没有 `lateralManeuverPlan` 时提供兜底，以及做 `clip_curvature` 一类的 jerk/横向加速度限制。

---

## 2. 从 modeld 到 LateralPlanner（数据流）

### 2.1 modelV2 消息结构

`modeld` 守护进程运行 supercombo 端到端模型，输出 cereal `modelV2` 消息。其关键字段（来自 `openpilot/cereal/log.capnp` 与 02j 报告）：

```capnp
struct ModelDataV2 {
  position @... : XYZ;             # 33 点位置 (X,Y,Z)，FLU 坐标系
  velocity @... : XYZ;             # 33 点速度
  acceleration @... : XYZ;         # 33 点加速度
  orientation @... : XYZ;          # 33 点欧拉角 (Roll,Pitch,Yaw)
  orientationRate @... : XYZ;      # 33 点角速度 (RollRate,PitchRate,YawRate)
  action :Action;                  # 期望动作（含 desiredCurvature / desiredAcceleration / shouldStop）
  laneLines @... : List(LaneLine); # 4 条车道线
  roadEdges @... : List(RoadEdge); # 2 条道路边界
  leads @... : List(LeadData);     # 2 个前车
  meta :Meta;                      # 场景元信息（变道状态、停车标志等）
  ...
}
```

### 2.2 Plan 输出张量与解码（来自 02j 报告）

supercombo 的 `plan` Head 输出形状 `[5, 2, 33, 15]`：
- **5 条假设**（mixture of plans）：模型同时输出 5 条候选轨迹，`parse_mdn` 通过 softmax 权重选最优一条；
- **2 个分位**：前半为均值 `mu`，后半为标准差 `std`；
- **33 个时间步**：覆盖未来约 5s 的预测（10Hz 采样，前密后疏）；
- **15 维状态向量**：
  ```
  [0:3]   X, Y, Z        位置（FLU，米）
  [3:6]   VX, VY, VZ     速度
  [6:9]   AX, AY, AZ     加速度
  [9:12]  R, P, Yaw      欧拉角（弧度）
  [12:15] RollRate, PitchRate, YawRate  角速度
  ```

### 2.3 从 Plan 到 Desired Action（关键！）

`selfdrive/modeld/modeld.py::get_action_from_model` 把 33 点 plan 折算成两个标量下发给 controlsd：

```python
def get_action_from_model(model_output, prev_action, lat_action_t, long_action_t, v_ego):
    plan = model_output['plan'][0]                  # 取最优假设
    desired_accel, should_stop = get_accel_from_plan(
        plan[:, Plan.VELOCITY][:,0],                # 预测速度序列
        plan[:, Plan.ACCELERATION][:,0],            # 预测加速度序列
        ModelConstants.T_IDXS, action_t=long_action_t)
    desired_curvature = get_curvature_from_plan(
        plan[:, Plan.T_FROM_CURRENT_EULER][:,2],    # 预测偏航角（Yaw）序列
        plan[:, Plan.ORIENTATION_RATE][:,2],        # 预测偏航角速度序列
        ModelConstants.T_IDXS, v_ego, lat_action_t)
    desired_accel    = smooth_value(desired_accel,    prev_action.desiredAcceleration, LONG_SMOOTH_SECONDS)
    desired_curvature = smooth_value(desired_curvature, prev_action.desiredCurvature, LAT_SMOOTH_SECONDS)
    return ModelDataV2.Action(desiredCurvature=..., desiredAcceleration=..., shouldStop=...)
```

`get_curvature_from_plan` 通过对偏航角序列差分得到曲率：

$$
\kappa(t) = \frac{\dot\psi(t)}{v_{ego}(t)}
$$

其中 $\dot\psi$ 来自 `Plan.ORIENTATION_RATE[:,2]`（偏航角速度，rad/s）。再在 `lat_action_t`（横向延迟 + 一个控制周期）处插值，得到"考虑延迟后应该此刻跟踪的曲率"。`smooth_value` 是一阶低通滤波，避免突变。

实测常量（grep.app `LAT_SMOOTH_SECONDS`）：

```python
# selfdrive/modeld/modeld.py
LAT_SMOOTH_SECONDS = 0.0       # 注意：横向平滑时间被设为 0，依赖 clip_curvature 在下游做限速
LONG_SMOOTH_SECONDS = 0.3      # 纵向加速度平滑 0.3s
MIN_LAT_CONTROL_SPEED = ...     # 低于此速度不做横向
```

`LAT_SMOOTH_SECONDS = 0.0` 是一个值得注意的工程决定——OpenPilot 把横向曲率的平滑完全交给 controlsd 的 `clip_curvature`（基于 jerk 限制的速率限制），而 modeld 层不再做低通。这避免了"双重平滑"导致响应滞后。

### 2.4 解码到 LateralPlanner / controlsd 的两条路径

新版 OpenPilot 有两条并存的路径，取决于 `lateralManeuverPlan` 是否有效：

**路径 A（端到端直通，新主流）**：
```
modeld → modelV2.action.desiredCurvature → controlsd.state_control()
       → clip_curvature(...)            # jerk + lat accel 限制
       → LatControl.update()            # 100Hz 闭环
       → card → panda → CAN
```

**路径 B（plannerd + LateralMpc，兜底/车型适配）**：
```
modeld → modelV2.position/velocity/acceleration
       → plannerd → LateralPlanner.update()
                   → LateralMpc.run()        # Acados SQP-RTI, <10ms
                   → lateralPlan.desiredCurvature
       → controlsd.state_control()
       → LatControl.update()
       → card → panda → CAN
```

路径 B 多了一次 MPC 重规划，主要用于没有 `lateralManeuverPlan`（即 supercombo 未输出动作）的车型，或需要做曲率序列级别可行性后处理的场景。两条路径在 controlsd 层都经过 `clip_curvature` 限速后才进入 LatControl，保证下游看到的是平滑的、满足 jerk/横向加速度约束的曲率。

---

## 3. 路径采样与曲率计算

### 3.1 路径点采样密度

supercombo 输出的 33 点 plan 覆盖约 5s（10Hz × 5s = 50 点的理论上限，但实际 IDX_N = 33 是非均匀采样）：

- **时间网格 `T_IDXS`**：非均匀，前 2s 密集（0.05–0.1s 间隔），后段稀疏（0.5s 间隔），总时域 ~5s；
- **空间映射**：每个时间步对应的纵向距离 `x_k = T_IDXS[k] × v_ego`（假设纵向匀速），Y/Z 由模型回归；
- **坐标系**：FLU（X 前 / Y 左 / Z 上），原点为后轴中心或质心（实现细节）。

### 3.2 LateralMpc 内部的时间网格

LateralMpc 自身的预测步数 N 典型为 16 步（见 02m 报告），时间网格 `T_IDXS` 与 modeld 共享但可能截取前 16 步（覆盖约 2–3s）。MPC 的 stage 时间由 Acados 自动按 `T_IDXS` 差分分配给各 ERK 积分器。

```python
# 综合源码还原（lateral_mpc.py / run_mpc.py）
self.mpc.set_cur_state(CS.x, CS.y, CS.psi, CS.vEgo, CS.vy, CS.yawRate, CS.steeringAngleDeg, ...)
self.mpc.set_weights(path_weight, heading_weight, lat_accel_weight, lat_jerk_weight, steering_rate_weight)
self.mpc.set_ref_path(ref_x, ref_y, ref_psi)         # 灌入 yref
self.mpc.run()
self.mpc_positions = self.mpc.x_sol[:, :2]            # 提取可执行路径
```

### 3.3 曲率计算

LateralPlanner 从 MPC 解出的路径 `(x_k, y_k, ψ_k)` 反算曲率：

$$
\kappa_k = \frac{\psi_{k+1} - \psi_k}{s_{k+1} - s_k}
$$

其中 $s_k$ 为弧长（沿路径积分）。即时下发的 `desiredCurvature` 取 $\kappa_0$（MPC 解的第一步），作为 100Hz LatControl 的跟踪目标。

**关键设计**：因为 MPC 代价里惩罚了横向 jerk 和转向速率，输出的曲率序列天然平滑，避免直接用模型路径的噪声/抖动。这是 OpenPilot 不依赖 modeld 端 `LAT_SMOOTH_SECONDS` 平滑的根本原因——MPC 自带平滑。

### 3.4 距离裁剪与速度自适应

- **距离裁剪**：LateralMpc 只看前 ~5s 的路径（按 `v_ego` 折算距离），远端不参与控制；
- **速度自适应**：低速时 stage 时间网格更密（近端），高速时覆盖更远（远端）。Acados 的变步长积分器自动处理。
- **`clip_curvature` 的距离无关性**：在 controlsd 层做的曲率速率限制是基于时间（`MAX_LATERAL_JERK / v² × DT_CTRL`），不依赖路径长度，所以无论路径远近都生效。

### 3.5 clip_curvature 完整公式（来自 grep.app 还原）

```python
# selfdrive/controls/lib/drive_helpers.py（综合源码）
def clip_curvature(v_ego, prev_curvature, new_curvature, roll):
    v_ego_raw = max(v_ego, 0.1)
    # 1) 横向 jerk 限制：曲率变化率 ≤ MAX_LATERAL_JERK / v²
    max_curvature_rate_sec = limits.ANGLE_LIMITS.MAX_LATERAL_JERK / (v_ego_raw ** 2)   # (1/m)/s
    new_curvature = np.clip(new_curvature,
                            prev_curvature - max_curvature_rate_sec * DT_CTRL,
                            prev_curvature + max_curvature_rate_sec * DT_CTRL)
    # 2) 横向加速度限制：a_y = κ·v² ≤ MAX_LATERAL_ACCEL ± roll·g
    roll_compensation = roll * ACCELERATION_DUE_TO_GRAVITY
    max_lat_accel = MAX_LATERAL_ACCEL_NO_ROLL + roll_compensation
    min_lat_accel = -MAX_LATERAL_ACCEL_NO_ROLL + roll_compensation
    new_curvature, limited_accel = clamp(new_curvature,
                                          min_lat_accel / v_ego_raw ** 2,
                                          max_lat_accel / v_ego_raw ** 2)
    return float(new_curvature), (limited_accel or limited_max_curv)
```

要点：
- `MAX_LATERAL_JERK ≈ 5 m/s³`（典型值，车型可调）；
- `MAX_LATERAL_ACCEL_NO_ROLL ≈ 3 m/s²`；
- `roll_compensation`：道路侧倾（roll）会改变有效重力分量，弯道外侧倾时允许更大横向加速度（车不会侧翻），内侧倾时收紧；
- 这一步保证下发给 LatControl 的曲率**永远满足舒适性与不侧滑约束**，无论 modeld/LateralMpc 给出的原始曲率如何激进。

---

## 4. LatControl 三种策略概览

### 4.1 抽象基类 LatControl

`selfdrive/controls/lib/latcontrol.py` 定义了抽象基类与统一的饱和检测逻辑（来自 grep.app `steer_limited_by_safety` 还原）：

```python
from abc import abstractmethod, ABC

class LatControl(ABC):
    def __init__(self, CP, CI, dt):
        self.sat_check_min_speed = 5.        # 低于 5 m/s 不做饱和检测
        self.sat_limit = CP.steerLimitTimer  # 饱和容忍时间（车型相关）
        self.sat_count = 0.
        self.sat_rate = 1. / CP.steerLimitTimer

    @abstractmethod
    def update(self, active: bool, CS, VM, params,
               steer_limited_by_safety: bool,
               desired_curvature: float,
               curvature_limited: bool,
               lat_delay: float):
        """统一接口：返回 (steer_cmd, steering_angle_deg_cmd, log_data)"""
        pass

    def reset(self):
        self.sat_time = 0.

    def _check_saturation(self, saturated, CS, steer_limited_by_safety, curvature_limited):
        # 只有当输出饱和、且不是被 panda 安全模型 clamp、且驾驶员没接管方向盘时
        # 才认为是"真饱和"（控制器被车辆物理极限卡住），累计计数
        if (saturated or curvature_limited) and CS.vEgo > self.sat_check_min_speed \
           and not steer_limited_by_safety and not CS.steeringPressed:
            self.sat_count += self.sat_rate
        else:
            self.sat_count -= self.sat_rate
        self.sat_count = np.clip(self.sat_count, 0.0, self.sat_limit)
        return self.sat_count > (self.sat_limit - 1e-3)
```

要点：
- **统一接口签名**：所有子类的 `update()` 接收相同的 8 个参数（`active, CS, VM, params, steer_limited_by_safety, desired_curvature, curvature_limited, lat_delay`），返回三元组 `(steer_cmd, angle_cmd, log)`。controlsd 无需 if-else 判断子类，直接调 `self.LaC.update(...)` 即可。
- **`lat_delay`**：实测 CAN 延迟 + `LAT_SMOOTH_SECONDS`，LatControl 内部用它做前馈/Smith 预估器式补偿（angle 模式尤其）。
- **`_check_saturation` 是反向安全机制**：当控制器输出"撞墙"（达到 steer_max）且**不是 panda 安全模型卡住**时，累计计数；超过 `sat_limit`（典型 3s）就触发 `ControlsState.lateralControlState.saturated=True`，selfdrived 会据此降级或退出横向。这避免了"控制器一直饱和但系统不知道"的危险状态。

### 4.2 三种核心策略 + 第四种新增策略

经 grep.app 代码搜索还原，OpenPilot 现有 **4 种** LatControl 子类（注意：原任务描述只提了 3 种，但实际 master 分支已加入第 4 种 `LatControlCurvature`）：

| 实现类 | 输出量 | 适用 EPS 类型 | 适用车型（典型） | 控制律核心 |
|--------|--------|--------------|------------------|------------|
| **LatControlAngle** | `steeringAngleDeg`（方向盘角度） | 接受角度命令的 EPS | **Honda**（主流）、部分 Acura | 几何反解 + PID 修残差 + 延迟补偿 |
| **LatControlTorque** | `torque`（方向盘扭矩，Nm） | 接受扭矩命令的 EPS | **Toyota、Hyundai**（主流）、Kia | 横向加速度跟踪 + 摩擦/死区补偿 + PID |
| **LatControlPID** | `torque`（方向盘扭矩） | 老旧/扭矩转向 EPS | 部分老 Hyundai、Chrysler、GM | 经典 PID 跟踪期望转角 + 前馈 |
| **LatControlCurvature**（新） | `curvature`（曲率，1/m） | 直接接受曲率命令的新 EPS | 部分 Hyundai（新能源）、Tesla | 直接转发期望曲率（车型 EPS 内部闭环） |

### 4.3 三种策略对比表（任务要求）

| 维度 | **LatControlAngle** | **LatControlTorque** | **LatControlPID** |
|------|---------------------|----------------------|-------------------|
| **输出物理量** | 方向盘角度（deg） | 方向盘扭矩（Nm） | 方向盘扭矩（Nm） |
| **控制目标** | 跟踪期望方向盘角度 | 跟踪期望横向加速度 $a_y = \kappa v^2$ | 跟踪期望方向盘角度（再转扭矩） |
| **核心算法** | 几何反解 `get_steer_from_curvature` + PID 修残差 | 横向加速度 PID + 摩擦补偿 | 经典 PID（位置+速度增益调度） |
| **前馈** | `angleOffsetDeg`（实车标定偏置） | `gravity_adjusted_lateral_accel`（重力补偿前馈） | `CI.get_steer_feedforward`（车型相关前馈函数） |
| **参数学习** | `liveParameters.angleOffsetDeg`（locationd 在线标定） | `liveTorqueParameters.latAccelFactor/Offset/friction`（torqued 在线学习） | `lateralTuning.pid.kpBP/kpV/kiBP/kiV`（固定增益表） |
| **典型车型** | Honda Civic/Accord/CR-V、Acura | Toyota Corolla/Rav4、Hyundai Sonata/Ioniq、Kia | 早期 Hyundai、Chrysler、GM（Chevy Volt 等特殊前馈） |
| **EPS 接口** | `STEERING_CONTROL` 报文（角度命令） | `STEERING_LKA`/`STEERING_TORQUE` 报文（扭矩命令） | 同 LatControlTorque |
| **延迟补偿** | 是（lat_delay → 角度前推） | 是（lat_delay → 横向加速度前推） | 弱（仅靠积分冻结） |
| **饱和检测** | `abs(angle_des - CS.steeringAngleDeg) > 2.5°` | `steer_max - abs(output_torque) < 1e-3` | `steer_max - abs(output_torque) < 1e-3` |
| **积分冻结条件** | `steer_limited_by_safety or steeringPressed or vEgo < 5` | 同左 | 同左 |
| **调试字段** | `LateralAngleState{active, saturated}` | `LateralTorqueState{active, saturated, desiredLateralAccel, ...}` | `LateralPIDState{active, saturated, steeringAngleDeg, output, p, i, f, ...}` |
| **复杂度** | 中（需要 EPS 角度精度好） | 高（横向加速度闭环 + 摩擦建模） | 低（经典 PID） |
| **跨车型一致性** | 中（每车标 angleOffset） | 高（torqued 自动学习三参数） | 低（每车调 PID 表） |
| **发展趋势** | 保留（Honda 等仍主流） | **主流推荐**（新车型默认） | 逐渐被 LatControlTorque 取代 |
| **特殊处理** | `use_steer_limited_by_safety = CP.brand in ("tesla", "hyundai")`（这些车的 carcontroller 会算 max lat accel/jerk，可依赖 carOutput 做饱和判断） | 实时回灌 `update_live_torque_params` | 特殊车型专用 `get_steer_feedforward`（如 Chevy Volt 的 sigmoid 前馈） |

---

## 5. 策略切换条件与工厂模式

### 5.1 工厂模式实现（controlsd.__init__）

来自 grep.app `car.CarParams.SteerControlType` 还原的 controlsd 工厂代码：

```python
# selfdrive/controls/controlsd.py（Controls.__init__ 节选）
from openpilot.selfdrive.controls.lib.latcontrol import LatControl
from openpilot.selfdrive.controls.lib.latcontrol_pid import LatControlPID
from openpilot.selfdrive.controls.lib.latcontrol_angle import LatControlAngle, STEER_ANGLE_SATURATION_THRESHOLD
from openpilot.selfdrive.controls.lib.latcontrol_curvature import LatControlCurvature
from openpilot.selfdrive.controls.lib.latcontrol_torque import LatControlTorque
from opendbc.car import CarParams

class Controls:
    def __init__(self) -> None:
        ...
        self.LaC: LatControl
        if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
            self.LaC = LatControlAngle(self.CP, self.CI, DT_CTRL)
        elif self.CP.steerControlType == car.CarParams.SteerControlType.curvature:
            self.LaC = LatControlCurvature(self.CP, self.CI, DT_CTRL)
        elif self.CP.lateralTuning.which() == 'pid':
            self.LaC = LatControlPID(self.CP, self.CI, DT_CTRL)
        elif self.CP.lateralTuning.which() == 'torque':
            self.LaC = LatControlTorque(self.CP, self.CI, DT_CTRL)
        ...
```

工厂模式的关键设计：
1. **优先级 1：`steerControlType`**——若车型 EPS 直接接受角度命令（`angle`）或曲率命令（`curvature`），优先用对应控制器，不再看 `lateralTuning`；
2. **优先级 2：`lateralTuning.which()`**——若 EPS 只接受扭矩命令，则按车型配置的 `lateralTuning` 是 `pid` 还是 `torque` 选择对应 PID 或 Torque 控制器；
3. **整个会话不切换**——`__init__` 时实例化一次，后续 100Hz 闭环里 `self.LaC.update(...)` 直接调用，无运行时分支。

### 5.2 策略切换条件表（任务要求）

| 切换维度 | 取值 | 选择的 LatControl | 切换时机 | 谁决定 |
|----------|------|-------------------|----------|--------|
| `CarParams.steerControlType` | `angle` | **LatControlAngle** | 车型适配期（Fingerprint 写入 CarParams 时） | `opendbc/car/[brand]/values.py` |
| `CarParams.steerControlType` | `curvature` | **LatControlCurvature** | 车型适配期 | 同上（新车型） |
| `CarParams.steerControlType` | `torque` + `lateralTuning.which()='torque'` | **LatControlTorque** | 车型适配期 | `values.py` 里设 `LateralTuning.Torque` |
| `CarParams.steerControlType` | `torque` + `lateralTuning.which()='pid'` | **LatControlPID** | 车型适配期 | `values.py` 里设 `LateralTuning.PID` |
| 运行时状态 | `latActive == False` | 任意（不输出，调 `reset()`） | selfdrived 退出/降级时 | selfdrived |
| 运行时状态 | `standstill and not steerAtStandstill` | 任意（不输出） | 车速 < minSteerSpeed | controlsd |
| 运行时状态 | `steerFaultTemporary/Permanent` | 任意（不输出） | EPS 报故障 | carState |

要点：
- **唯一"运行时切换"是激活/失活**——`CC.latActive` 为 False 时 controlsd 调 `self.LaC.reset()` 复位积分器，避免下次激活时积分爆冲；但策略本身不变。
- **车型级切换**由 `opendbc/car/[brand]/values.py` 中的 `CarControllerParams` 在生成 `CarParams` 时固化，例如 Honda Civic 设 `steerControlType=angle`，Toyota Corolla 设 `steerControlType=torque` 且 `lateralTuning=Torque(...)`。
- **没有"自适应切换"**——OpenPilot 不会在运行中根据车速/曲率自动从 PID 切到 Torque，这避免切换瞬态；策略与车型 EPS 物理接口绑定。

---

## 6. LatControlAngle 深度分析

### 6.1 适用车型与定位

LatControlAngle 适用于**接受方向盘角度命令的 EPS**，最典型的是 **Honda 系**（Civic、Accord、CR-V、HR-V、Pilot、Odyssey 等）和 **Acura** 部分。这些车的 EPS 通过 `STEERING_CONTROL` CAN 报文接收"目标方向盘角度"并内部闭环到该角度。

### 6.2 控制律（来自 grep.app 还原）

```python
# selfdrive/controls/lib/latcontrol_angle.py（核心还原）
STEER_ANGLE_SATURATION_THRESHOLD = 2.5  # Degrees，# TODO This is speed dependent

class LatControlAngle(LatControl):
    def __init__(self, CP, CI, dt):
        super().__init__(CP, CI, dt)
        self.use_steer_limited_by_safety = CP.brand in ("tesla", "hyundai")
        # 这些车的 carcontroller 会算 max lateral accel 和 jerk，
        # 可以依赖 carOutput 做饱和判断（不需要自己比 2.5° 阈值）

    def update(self, active, CS, VM, params, steer_limited_by_safety,
               desired_curvature, curvature_limited, lat_delay):
        angle_log = log.ControlsState.LateralAngleState.new_message()

        if not active:
            # 失活时输出当前实际角度（无突变）
            angle_log.active = False
            return 0.0, 0.0, angle_log

        angle_log.active = True
        # 1. 几何反解：把期望曲率转为期望方向盘角度
        angle_steers_des = math.degrees(
            VM.get_steer_from_curvature(-desired_curvature, CS.vEgo, params.roll))
        angle_steers_des += params.angleOffsetDeg       # 实车标定的角度偏置

        # 2. 饱和判断
        if self.use_steer_limited_by_safety:
            # tesla/hyundai：依赖 carOutput（panda clamp 后的实际值）
            angle_control_saturated = steer_limited_by_safety
        else:
            # honda 等：自己比期望角度 vs 实际角度差
            angle_control_saturated = abs(angle_steers_des - CS.steeringAngleDeg) > STEER_ANGLE_SATURATION_THRESHOLD

        angle_log.saturated = bool(self._check_saturation(
            angle_control_saturated, CS, steer_limited_by_safety, curvature_limited))

        # 3. 输出：直接是期望角度（车型 EPS 内部闭环到该角度）
        # 注意：这里没有显式 PID！因为 Honda EPS 自带角度闭环
        return 0.0, angle_steers_des, angle_log
```

### 6.3 关键设计点

1. **`VM.get_steer_from_curvature(curvature, v, roll)`**：来自 `opendbc/car/vehicle_model.py`，用自行车模型反解前轮转角：
   $$
   \delta = \kappa \cdot (L + K \cdot v^2)
   $$
   其中 $L$ 是轴距，$K$ 是不足转向梯度（understeer gradient，含速度项）。再乘 `steerRatio` 转成方向盘角度。`roll` 用于侧倾补偿。

2. **`params.angleOffsetDeg`**：来自 `liveParameters.angleOffsetDeg`，由 `locationd` 在线标定（详见 §10 PoseCalibrator）。它是"方向盘零位偏置"——安装误差或机械间隙导致的方向盘 0° 不一定是直行。

3. **无显式 PID**：LatControlAngle 不做 PID 闭环，直接输出几何反解的角度，**依赖 Honda EPS 内部角度闭环消除残余误差**。这是为什么 Honda 适配相对简单——只要 `angleOffsetDeg` 标准对，跟踪就准。

4. **`use_steer_limited_by_safety` 分支**：Tesla/Hyundai 的 carcontroller 会自己算 `max lateral accel` 和 `max jerk`，所以 LatControlAngle 可以直接信任 `steer_limited_by_safety`（panda clamp 标志）做饱和判断；而 Honda 不算，所以需要自己比 2.5° 阈值。

5. **`STEER_ANGLE_SATURATION_THRESHOLD = 2.5°`**：源码注释 `# TODO This is speed dependent`，承认这个固定阈值在不同速度下不准确——低速时 2.5° 可能正常（大转角），高速时 2.5° 已经很危险。这是 OpenPilot 在 Honda 车型上已知的小局限。

### 6.4 失活复位

```python
if not active:
    angle_log.active = False
    return 0.0, 0.0, angle_log
```

失活时直接返回 0（不输出），不依赖积分器复位（因为没用积分器）。激活瞬间从当前实际角度平滑过渡——但因为没有低通，仍然会有小跳变，靠 Honda EPS 自带的速率限制吸收。

---

## 7. LatControlTorque 深度分析

### 7.1 适用车型与定位

LatControlTorque 适用于**接受方向盘扭矩命令的 EPS**，是 OpenPilot 当前**主流推荐**策略，覆盖：
- **Toyota**：Corolla、Camry、Rav4、Highlander、Sienna、Prius（全系列）；
- **Hyundai**：Sonata、Elantra、Tucson、Santa Fe、Ioniq（混动/纯电）；
- **Kia**：K5、Sportage、Sorento 等；
- 部分 Subaru、VW、Mazda、Nissan。

这些车的 EPS 通过 `STEERING_LKA`（Toyota）/`STEERING_TORQUE`（Hyundai）等 CAN 报文接收"目标方向盘扭矩"并直接输出力矩（不内部闭环到角度），所以 OpenPilot 必须自己做横向加速度闭环。

### 7.2 控制律（来自 grep.app 与 CSDN 还原）

```python
# selfdrive/controls/lib/latcontrol_torque.py（核心还原）
class LatControlTorque(LatControl):
    def __init__(self, CP, CI, dt):
        super().__init__(CP, CI, dt)
        self.torque_params = CP.lateralTuning.torque      # latAccelFactor / latAccelOffset / friction
        self.pid = PIDController(CP.lateralTuning.pid.kpBP, CP.lateralTuning.pid.kpV,
                                 CP.lateralTuning.pid.kiBP, CP.lateralTuning.pid.kiV)
        self.steer_max = CP.steerLimitMax
        self.jerk_filter = FirstOrderLowPassFilter(0.0, 0.5 / DT_CTRL)
        self.lat_accel_request_buffer = ...

    def update_live_torque_params(self, latAccelFactor, latAccelOffset, friction):
        # torqued 守护进程实时学习值回灌
        self.torque_params.latAccelFactor = latAccelFactor
        self.torque_params.latAccelOffset = latAccelOffset
        self.torque_params.friction = friction
        self.update_limits()

    def update(self, active, CS, VM, params, steer_limited_by_safety,
               desired_curvature, curvature_limited, lat_delay):
        pid_log = log.ControlsState.LateralTorqueState.new_message()
        pid_log.version = VERSION

        if not active:
            self.pid.reset()
            pid_log.active = False
            return 0.0, 0.0, pid_log
        pid_log.active = True

        # 1. 期望 vs 实际 横向加速度
        #    期望：a_y_des = κ · v² ；实际：a_y_act = κ_act · v²
        desired_lateral_accel = desired_curvature * CS.vEgo ** 2
        measured_curvature = -VM.calc_curvature(
            math.radians(CS.steeringAngleDeg - params.angleOffsetDeg), CS.vEgo, params.roll)
        actual_lateral_accel = measured_curvature * CS.vEgo ** 2

        # 2. 低速非线性补偿（基于实测车辆转向响应在低速下偏离线性）
        low_speed_factor = np.interp(CS.vEgo, LOW_SPEED_X, LOW_SPEED_Y) ** 2
        setpoint = desired_lateral_accel + low_speed_factor * desired_curvature
        measurement = actual_lateral_accel + low_speed_factor * measured_curvature

        # 3. 期望横向 jerk（前馈量的一部分）
        future_desired_lateral_accel = (desired_curvature + ...) * CS.vEgo ** 2
        self.lat_accel_request_buffer.append(future_desired_lateral_accel)
        raw_lateral_jerk = (future_desired_lateral_accel - desired_lateral_accel) / DT_CTRL
        desired_lateral_jerk = self.jerk_filter.update(raw_lateral_jerk)
        pid_log.desiredLateralJerk = float(desired_lateral_jerk)

        # 4. 重力补偿前馈（roll 修正）
        roll_compensation = params.roll * ACCELERATION_DUE_TO_GRAVITY
        gravity_adjusted_future_lateral_accel = future_desired_lateral_accel - roll_compensation
        ff = gravity_adjusted_future_lateral_accel

        # 5. 摩擦补偿 + latAccelOffset
        ff -= self.torque_params.latAccelOffset
        ff += get_friction(desired_lateral_accel - actual_lateral_accel,
                           lateral_accel_deadzone, FRICTION_THRESHOLD, self.torque_params)

        # 6. PID 闭环（消除残余横向加速度误差）
        freeze_integrator = steer_limited_by_safety or CS.steeringPressed or CS.vEgo < 5
        pid_log.output = float(self.pid.update(setpoint - measurement, freeze_integrator=freeze_integrator))

        # 7. 合成最终扭矩：前馈 + PID
        output_torque = self.torque_params.latAccelFactor * (ff + pid_log.output)
        output_torque = clamp(output_torque, -self.steer_max, self.steer_max)

        # 8. 饱和检测
        pid_log.saturated = bool(self._check_saturation(
            self.steer_max - abs(output_torque) < 1e-3, CS, steer_limited_by_safety, curvature_limited))

        return output_torque, 0.0, pid_log
```

### 7.3 关键设计点

1. **横向加速度闭环而非角度闭环**：因为扭矩 EPS 不内部闭环到角度，OpenPilot 必须自己把"期望曲率 → 期望横向加速度 → 扭矩"全链路闭环。核心思想是把车辆当成"扭矩→横向加速度"的一阶系统，用 PID 跟踪期望 $a_y$。

2. **`latAccelFactor`**：从方向盘扭矩到横向加速度的增益（Nm/(m/s²)），是车辆转向系刚度的倒数。来自 `torqued` 守护进程的**在线学习**（`liveTorqueParameters`），不需要每车标定。

3. **`latAccelOffset`**：扭矩零点偏置，补偿方向盘机械间隙/摩擦导致的"零扭矩不直行"现象。

4. **`friction`**：转向系干摩擦补偿，基于"扭矩方向变化时需要额外克服静摩擦"。`get_friction()` 函数根据横向加速度误差方向与死区判断是否注入摩擦补偿扭矩。

5. **`low_speed_factor`**：低速时（< 5 m/s）车辆转向响应非线性严重（轮胎侧偏刚度低、滑移大），用 `np.interp` 给一个二次方补偿因子，让低速下控制更稳。

6. **前馈 `ff`**：包含三部分——期望横向加速度（主前馈）、roll 修正（道路侧倾补偿重力分量）、latAccelOffset 与 friction（机械补偿）。前馈是开环给出"跟踪期望曲率所需的名义扭矩"，PID 只消除残余误差。

7. **`future_desired_lateral_accel` 与 jerk 滤波**：用 `lat_accel_request_buffer` 缓冲未来几帧的期望横向加速度，差分得到期望 jerk，再一阶低通滤波。这是为了让前馈"提前知道"曲率变化，相当于前瞻控制。

8. **`freeze_integrator`**：当 `steer_limited_by_safety`（panda clamp 了输出）、驾驶员手扶方向盘（`steeringPressed`）、或车速低于 5 m/s 时，**冻结 PID 积分器**，防止饱和/接管导致积分爆掉。

### 7.4 力矩反馈与 `update_live_torque_params`

```python
def update_live_torque_params(self, latAccelFactor, latAccelOffset, friction):
    self.torque_params.latAccelFactor = latAccelFactor
    self.torque_params.latAccelOffset = latAccelOffset
    self.torque_params.friction = friction
    self.update_limits()
```

`torqued` 守护进程（独立运行）持续学习这三参数：
- 通过记录方向盘扭矩 → 实测横向加速度（从 IMU/车速/转向角反算）的映射关系，最小二乘拟合 `latAccelFactor`；
- `latAccelOffset` = 零扭矩时的横向加速度偏置；
- `friction` = 干摩擦扭矩幅值。

学习结果通过 `liveTorqueParameters` 消息发布，controlsd 在 `state_control()` 开头回灌：
```python
if self.CP.lateralTuning.which() == 'torque':
    torque_params = self.sm['liveTorqueParameters']
    if self.sm.all_checks(['liveTorqueParameters']) and torque_params.useParams:
        self.LaC.update_live_torque_params(
            torque_params.latAccelFactorFiltered,
            torque_params.latAccelOffsetFiltered,
            torque_params.frictionCoefficientFiltered)
```

这是 OpenPilot 跨车型一致性的关键——同一套 LatControlTorque 代码，不同车自动学出自己的三参数，无需人工调参。

### 7.5 默认 tuning 与 biased 版本

来自 grep.app `TORQUE_TUNE` 还原：

```python
ROLL_BIAS_DEG = 1.0
ROLL_COMPENSATION_BIAS = ACCELERATION_DUE_TO_GRAVITY * float(np.sin(np.deg2rad(ROLL_BIAS_DEG)))
TORQUE_TUNE = structs.CarParams.LateralTorqueTuning(latAccelFactor=2.0, latAccelOffset=0.0, friction=0.2)
TORQUE_TUNE_BIASED = structs.CarParams.LateralTorqueTuning(
    latAccelFactor=2.0, latAccelOffset=-ROLL_COMPENSATION_BIAS, friction=0.2)
```

默认 `latAccelFactor=2.0`、`friction=0.2` 是合理初值，torqued 学习后会被替换。

---

## 8. LatControlPID 深度分析

### 8.1 适用车型与定位

LatControlPID 是**经典 PID 策略**，适用范围：
- 早期 Hyundai（未升级到 Torque 策略的）；
- Chrysler（部分）；
- GM（Chevrolet Volt 等特殊前馈）；
- 部分 Nissan、Subaru（早期）。

它在概念上与 LatControlTorque 相似（都输出扭矩），但控制目标是"期望方向盘角度"而非"期望横向加速度"，且参数固定（无在线学习）。

### 8.2 控制律（来自 grep.app 还原）

```python
# selfdrive/controls/lib/latcontrol_pid.py（核心还原）
class LatControlPID(LatControl):
    def __init__(self, CP, CI, dt):
        super().__init__(CP, CI, dt)
        self.pid = PIDController(
            (CP.lateralTuning.pid.kpBP, CP.lateralTuning.pid.kpV),   # 比例增益调度表
            (CP.lateralTuning.pid.kiBP, CP.lateralTuning.pid.kiV),   # 积分增益调度表
            k_f=CP.lateralTuning.pid.kf)                               # 前馈系数
        self.steer_max = CP.steerLimitMax
        self.get_steer_feedforward = CI.get_steer_feedforward_function()
        self.ff_factor = CP.lateralTuning.pid.kf

    def update(self, active, CS, VM, params, steer_limited_by_safety,
               desired_curvature, curvature_limited, lat_delay):
        pid_log = log.ControlsState.LateralPIDState.new_message()
        pid_log.steeringAngleDeg = float(CS.steeringAngleDeg)

        if not active:
            self.pid.reset()
            pid_log.active = False
            return 0.0, 0.0, pid_log
        pid_log.active = True

        # 1. 几何反解：期望曲率 → 期望方向盘角度（无 offset）
        angle_steers_des_no_offset = math.degrees(
            VM.get_steer_from_curvature(-desired_curvature, CS.vEgo, params.roll))
        angle_steers_des = angle_steers_des_no_offset + params.angleOffsetDeg

        # 2. PID 误差 = 期望角度 - 实际角度
        error = angle_steers_des - CS.steeringAngleDeg

        # 3. 前馈（offset 不贡献 resistive torque，所以用 no_offset）
        ff = self.ff_factor * self.get_steer_feedforward(angle_steers_des_no_offset, CS.vEgo)

        # 4. PID 闭环（带增益调度，按速度查 kp/ki 表）
        freeze_integrator = steer_limited_by_safety or CS.steeringPressed or CS.vEgo < 5
        output_torque = self.pid.update(error, feedforward=ff, speed=CS.vEgo,
                                         freeze_integrator=freeze_integrator)
        output_torque = clamp(output_torque, -self.steer_max, self.steer_max)

        # 5. 调试字段
        pid_log.p = float(self.pid.p)
        pid_log.i = float(self.pid.i)
        pid_log.f = float(ff)
        pid_log.output = float(output_torque)
        pid_log.saturated = bool(self._check_saturation(
            self.steer_max - abs(output_torque) < 1e-3, CS, steer_limited_by_safety, curvature_limited))
        pid_log.angleSteersDes = float(angle_steers_des)

        return output_torque, 0.0, pid_log
```

### 8.3 前馈函数（车型相关，特殊处理）

`CI.get_steer_feedforward_function()` 返回车型特定的前馈函数，默认实现：

```python
# opendbc/car/car_helpers.py 或类似
@staticmethod
def get_steer_feedforward_default(desired_angle, v_ego):
    # Proportional to realigning tire momentum: lateral acceleration.
    return desired_angle * (v_ego ** 2)
```

默认前馈是 `desired_angle × v²`，物理意义是"前轮回正力矩 ∝ 横向加速度 ∝ 角度 × 速度²"。

**特殊车型**：Chevrolet Volt 有专用 sigmoid 前馈（来自 grep.app）：
```python
def get_steer_feedforward_volt(desired_angle, v_ego):
    desired_angle *= 0.02904609
    sigmoid = desired_angle / (1 + fabs(desired_angle))
    return 0.10006696 * sigmoid * (v_ego + 3.12485927)
```

Volt 的 EPS 在大角度时扭矩需求饱和，所以用 sigmoid 限制前馈幅值。

### 8.4 PID 增益调度

```python
self.pid = PIDController(
    (CP.lateralTuning.pid.kpBP, CP.lateralTuning.pid.kpV),   # kpBP = 速度断点，kpV = 对应 kp 值
    (CP.lateralTuning.pid.kiBP, CP.lateralTuning.pid.kiV),
    k_f=CP.lateralTuning.pid.kf)
```

`PIDController` 内部按 `speed` 在 `kpBP/kpV` 上插值得到当前速度的 `kp`，实现增益调度（gain scheduling）。典型 `kpBP = [0, 5, 15]`（速度断点 m/s），`kpV = [0.5, 0.3, 0.2]`（低速大 kp 高速小 kp），因为高速时小扭矩变化就能产生大横向加速度，需要降增益避免振荡。

### 8.5 与 LatControlTorque 的本质区别

| 维度 | LatControlPID | LatControlTorque |
|------|---------------|------------------|
| **控制目标** | 期望方向盘角度 | 期望横向加速度 |
| **误差信号** | `angle_des - angle_act` | `a_y_des - a_y_act` |
| **前馈** | 车型专用函数（Volt/default） | 横向加速度 + 摩擦 + roll 补偿 |
| **参数** | 固定增益调度表（kp/ki BP+V） | 在线学习（latAccelFactor 等） |
| **跨车型** | 每车调 PID 表 | 自动学习，无需调参 |
| **物理建模深度** | 浅（仅角度-扭矩一阶） | 深（横向加速度 + 摩擦 + 死区） |
| **趋势** | 逐渐淘汰 | 主流推荐 |

**结论**：LatControlPID 是 OpenPilot 早期的横向策略，简单可靠但需手工调参；LatControlTorque 是工程升级，通过在线学习三参数实现跨车型一致性，是当前默认推荐。Honda 角度控制因 EPS 自带闭环，不需要这么复杂。

---

## 9. steer_limited_by_safety 安全机制

### 9.1 饱和检测来源（controlsd.publish）

`steer_limited_by_safety` 是 controlsd 算出的"我的期望值是否被 panda 安全模型 clamp 了"的标志位（来自 02l 报告与 grep.app）：

```python
# selfdrive/controls/controlsd.py::publish（节选）
if self.sm['selfdriveState'].active:
    CO = self.sm['carOutput']
    if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
        # 角度模式：比较期望方向盘角度 vs panda 实际下发角度
        self.steer_limited_by_safety = abs(
            CC.actuators.steeringAngleDeg - CO.actuatorsOutput.steeringAngleDeg
        ) > STEER_ANGLE_SATURATION_THRESHOLD   # 2.5°
    else:
        # 扭矩模式：比较期望扭矩 vs panda 实际下发扭矩
        self.steer_limited_by_safety = abs(
            CC.actuators.torque - CO.actuatorsOutput.torque
        ) > 1e-2   # 0.01 Nm
```

### 9.2 饱和来源的两种情况

`steer_limited_by_safety = True` 意味着 panda 安全模型（panda 固件里硬编码的车型 safety model）clamp 了输出。可能原因：

1. **超出车型物理极限**：方向盘角度/扭矩超过 `MAX_STEER` 或 `MAX_STEER_RATE`（如急打方向超过角速度上限）；
2. **超出 jerk/横向加速度限制**：panda 安全模型会校验 `actuators.curvature` 折算的横向加速度是否超过车型阈值；
3. **频率/计数器校验失败**：CAN 报文计数器不连续时，panda 会拒绝下发；
4. **驾驶员 override**：虽然 `steeringPressed` 是独立标志，但 panda 也会在检测到驾驶员扭矩时降权。

### 9.3 积分冻结（关键安全机制）

LatControl 三种策略在收到 `steer_limited_by_safety=True` 时**统一冻结积分器**：

```python
# 三种策略的共同代码
freeze_integrator = steer_limited_by_safety or CS.steeringPressed or CS.vEgo < 5
```

为什么冻结？考虑场景：
1. 系统期望输出 +5 Nm 扭矩跟踪一个急弯；
2. panda 因为某原因（如超出车型 jerk 限制）clamp 到 +3 Nm；
3. 如果积分器继续积分"5 - 3 = 2 Nm 的误差"，几秒后积分项会爆到几十 Nm；
4. 一旦 panda 限制解除（如曲率变小），积分项瞬间释放，导致方向盘猛打——**windup 灾难**。

冻结积分器后，控制器输出仅依赖 P 和 D 项，待 panda 限制解除后从当前状态重新积分，避免过冲。

### 9.4 `_check_saturation` 的反向校验

注意 `steer_limited_by_safety` 与 `_check_saturation` 的关系：

```python
def _check_saturation(self, saturated, CS, steer_limited_by_safety, curvature_limited):
    # 只有当：
    #  - 控制器输出饱和（saturated）
    #  - 且不是 panda clamp 导致的（not steer_limited_by_safety）
    #  - 且不是 clip_curvature 限制的（not curvature_limited）
    #  - 且驾驶员没接管（not CS.steeringPressed）
    # 才累计"真饱和"计数
    if (saturated or curvature_limited) and CS.vEgo > self.sat_check_min_speed \
       and not steer_limited_by_safety and not CS.steeringPressed:
        self.sat_count += self.sat_rate
    else:
        self.sat_count -= self.sat_rate
    self.sat_count = np.clip(self.sat_count, 0.0, self.sat_limit)
    return self.sat_count > (self.sat_limit - 1e-3)
```

设计意图：区分"系统主动限制"（panda/clip_curvature，正常安全行为，不算问题）与"控制器自身撞墙"（输出到了 steer_max 还跟踪不上，是异常）。后者累计超过 `sat_limit`（典型 3s）后触发 `saturated=True`，selfdrived 会据此降级或退出横向，提示用户"控制能力不足"。

### 9.5 NaN/Inf 兜底（最后一道安全网）

来自 02l 报告：

```python
# controlsd.state_control() 末尾
for p in ACTUATOR_FIELDS:
    attr = getattr(actuators, p)
    if not isinstance(attr, Number):
        continue
    if not math.isfinite(attr):
        cloudlog.error(f"actuators.{p} not finite {actuators.to_dict()}")
        setattr(actuators, p, 0.0)
```

任何非有限值（NaN/Inf）一律清零并报错，防止 MPC/PID 数值病态导致 CAN 异常帧。

---

## 10. PoseCalibrator 位姿标定

### 10.1 定位与职责

`PoseCalibrator` 类位于 `selfdrive/locationd/helpers.py`（Python 封装），底层实现是 `selfdrive/locationd/calibrationd.py`（C++ 守护进程 `calibrationd`）。其核心职责：

> **把"comma 设备在车内的安装位姿"与"车辆后轴坐标系"对齐，输出一个 6-DOF 校准位姿 `calibrated_pose`（含 orientation + angular_velocity），供 LatControl 使用。**

comma 设备（comma 3/3X）通常吸在挡风玻璃上，与车辆坐标系有任意安装偏置（yaw 偏几度、pitch 偏几度），必须在线标定后才能用模型输出和 IMU 数据。

### 10.2 与 LatControl 的接口

来自 02l 报告：

```python
# selfdrive/controls/controlsd.py::update（节选）
if self.sm.updated["liveCalibration"]:
    self.pose_calibrator.feed_live_calib(self.sm['liveCalibration'])
if self.sm.updated["livePose"]:
    device_pose = Pose.from_live_pose(self.sm['livePose'])
    self.calibrated_pose = self.pose_calibrator.build_calibrated_pose(device_pose)
```

`calibrated_pose` 在 publish 阶段写入 `CarControl`：

```python
if self.calibrated_pose is not None:
    CC.orientationNED = self.calibrated_pose.orientation.xyz.tolist()
    CC.angularVelocity = self.calibrated_pose.angular_velocity.xyz.tolist()
```

但 LatControl 间接使用的是 `liveParameters`（来自 locationd 的另一个守护进程），它包含：
- `stiffnessFactor`：轮胎侧偏刚度系数（默认 1.0，实车学习）；
- `steerRatio`：方向盘到前轮转向比（默认来自 CarParams，实车学习）；
- `angleOffsetDeg`：方向盘零位偏置（LatControlAngle/PID 用）；
- `roll`：道路侧倾角（clip_curvature 与 LatControlTorque 前馈用）。

```python
# controlsd.state_control() 开头
lp = self.sm['liveParameters']
x = max(lp.stiffnessFactor, 0.1)
sr = max(lp.steerRatio, 0.1)
self.VM.update_params(x, sr)        # 更新车辆模型参数
steer_angle_without_offset = math.radians(CS.steeringAngleDeg - lp.angleOffsetDeg)
self.curvature = -self.VM.calc_curvature(steer_angle_without_offset, CS.vEgo, lp.roll)
```

### 10.3 yaw / pitch / roll 校准原理

`calibrationd` 通过观测车辆运动（车速、方向盘角、IMU 角速度）反推设备安装偏置：
- **yaw 偏置**：车辆直线行驶时，IMU 的 yaw rate 应该等于 `v_ego × κ`（从方向盘反算的曲率）。若有偏差，就是设备 yaw 偏置；
- **pitch 偏置**：车辆匀速时，IMU 的 pitch 应该等于道路坡度（从 GPS 高度变化或视觉估计）。若有偏差，就是设备 pitch 偏置；
- **roll 偏置**：车辆转弯时，IMU 的 roll 应该等于横向加速度引起的车身侧倾 + 道路侧倾。若有偏差，就是设备 roll 偏置。

校准结果通过 `liveCalibration` 消息发布（包含 4×4 变换矩阵或四元数），controlsd 的 `pose_calibrator.feed_live_calib()` 接收后用于把 `livePose`（设备坐标系）转到车体坐标系（`calibrated_pose`）。

### 10.4 标定的两个层级

| 层级 | 守护进程 | 输出消息 | 用途 |
|------|----------|----------|------|
| **设备位姿标定** | `calibrationd` | `liveCalibration` / `livePose` | 设备 → 车体坐标系变换（用于 PoseCalibrator） |
| **车辆参数标定** | `locationd` | `liveParameters` | 实车 steerRatio / angleOffsetDeg / stiffnessFactor / roll |
| **扭矩参数标定** | `torqued` | `liveTorqueParameters` | 实车 latAccelFactor / latAccelOffset / friction（仅 torque 模式） |

三者协同：calibrationd 给设备姿态，locationd 给车辆参数，torqued 给扭矩模型参数。LatControl 三策略消费 liveParameters（全用），LatControlTorque 额外消费 liveTorqueParameters，PoseCalibrator 消费 liveCalibration + livePose 给出 calibrated_pose 给 CarControl。

### 10.5 标定收敛时间

- **设备 yaw/pitch**：~5 分钟正常驾驶后收敛到 ±0.5°；
- **steerRatio**：~10 分钟（需要不同速度不同曲率样本）；
- **angleOffsetDeg**：~5 分钟；
- **latAccelFactor/friction**（torqued）：~30 分钟（需要更长的扭矩-横向加速度对应数据）。

未收敛前，控制会使用 CarParams 中的默认值，质量略差但不影响安全。

---

## 11. 与 Apollo LQR 对比

### 11.1 架构根本差异

| 维度 | **OpenPilot LatControl** | **Apollo LatController（LQR）** |
|------|--------------------------|----------------------------------|
| **架构层级** | 规划（LateralPlanner）+ 执行（LatControl）双层 | 单层（LatController 直接出方向盘角度） |
| **频率** | 规划 20Hz + 执行 100Hz | 单 100Hz |
| **控制策略** | 4 种策略（Angle/Torque/PID/Curvature）按车型切换 | 单一 LQR + 增益调度 |
| **状态量** | LatControlTorque 用横向加速度误差；LatControlPID 用角度误差 | 4 维误差模型 `[e1, ė1, e2, ė2]` |
| **求解器** | PID（无需求解）+ 几何反解 + 在线学习参数 | 离散黎卡提方程（DARE）迭代求解 K |
| **前馈** | 车型专用函数（Volt sigmoid / 默认 angle×v²）或横向加速度前馈 | 道路曲率前馈 `δ_ff = (L + K·v²)·κ + ...` |
| **增益调度** | PID 按 `kpBP/kpV` 速度断点查表；Torque 在线学习 | LQR 按 `v_ego` 实时重算 A 矩阵 + Q 矩阵插值 |
| **轮胎模型** | 线性（隐含在 `latAccelFactor` 学习值里） | 线性化（Pacejka 小角度近似） |
| **跨车型** | 工厂模式选策略 + 在线学习参数 | 同一 LQR 代码，按 CarParams 调 `cf_/cr_/mass_/iz_/lf_/lr_` |
| **输出物理量** | 角度或扭矩（按 EPS 类型） | 方向盘角度（统一） |

### 11.2 控制律差异

**Apollo LQR 控制律**：
$$
u = \delta_f = \underbrace{-K \cdot x}_{\text{反馈}} + \underbrace{\delta_{ff}(\kappa)}_{\text{前馈}}
$$

其中 $K = R^{-1} B^T P$，$P$ 满足离散代数黎卡提方程 DARE：
$$
P = A^T P A - A^T P B (R + B^T P B)^{-1} B^T P A + Q
$$

Apollo 在线迭代求解 DARE（最大 `lqr_max_iteration_` 次，收敛阈值 `lqr_eps_`），得到 $K$ 后做 `u = -K·x + δ_ff`，再乘 `steer_ratio_` 转方向盘角度。

**OpenPilot LatControlTorque 控制律**：
$$
\tau = \underbrace{\text{latAccelFactor} \cdot \big( a_y^{des}(t+\Delta) - \text{roll}\cdot g - \text{offset} + \text{friction} \big)}_{\text{前馈}} + \underbrace{\text{PID}(a_y^{des} - a_y^{act})}_{\text{反馈}}
$$

不求解黎卡提方程，直接用 PID 闭环横向加速度，前馈由几何反解 + 摩擦补偿 + roll 修正给出。

### 11.3 适用车型差异

| 维度 | OpenPilot LatControl | Apollo LQR |
|------|----------------------|------------|
| **车型适配方式** | 工厂模式选 4 种策略之一 + 在线学习参数 | 同一 LQR，按 CarParams 调物理参数 + 增益调度表 |
| **Honda** | LatControlAngle（角度直控） | 也可用 LQR（输出方向盘角度） |
| **Toyota/Hyundai** | LatControlTorque（扭矩 + 在线学习） | 也可用 LQR（但需 EPS 接受角度命令） |
| **特殊车型** | Chevy Volt 专用 sigmoid 前馈 | 增益调度表覆盖 |
| **新车直控曲率 EPS** | LatControlCurvature（直接转发） | 不支持（LQR 必须输出角度） |
| **跨车型一致性** | 高（torqued 自动学习） | 中（每车调增益调度表） |

**结论**：OpenPilot 的"多策略工厂模式"在跨车型适配上更灵活——能直控角度的车用 LatControlAngle，能直控扭矩的车用 LatControlTorque（在线学习），新车能直控曲率的用 LatControlCurvature。Apollo LQR 是"统一框架"，对所有车都输出方向盘角度，依赖 EPS 接口适配层（车型 carcontroller 把角度命令转 CAN 报文）。两种思路各有优劣：
- **OpenPilot 思路**：贴近 EPS 物理接口，控制品质高，但工程复杂（4 套代码）；
- **Apollo 思路**：抽象层统一，工程简单，但 LQR 在扭矩 EPS 上需要"角度→扭矩"的额外转换（车型相关）。

### 11.4 实时性与计算量

| 指标 | OpenPilot LatControl（任意策略） | Apollo LQR |
|------|----------------------------------|------------|
| 单次 update 耗时 | < 0.1ms（PID + 几何反解） | 0.5–2ms（DARE 迭代 + 矩阵乘法） |
| 内存 | 极低（几个 float） | 中（4×4 矩阵 + 增益表） |
| 收敛性 | 不存在收敛（PID 是无模型反馈） | 依赖 DARE 迭代收敛，可能发散 |
| 工具链 | 无（纯 Python） | Eigen 矩阵库 |

OpenPilot LatControl 比 Apollo LQR **快 10× 以上**，因为不做矩阵运算。代价是 OpenPilot 把"最优性"完全交给 LateralMpc 上游（规划层），LatControl 只做反馈消除——这是一种"上层 MPC + 下层 PID"的分层最优架构。Apollo 把所有最优性压在 LQR 一层（单层最优反馈），架构更扁平但单层计算量更大。

### 11.5 跟踪精度对比

实测数据（公开社区与 comma.ai blog）：
- **OpenPilot LatControlTorque**（Toyota 等）：车道居中误差 90% 时间 < 30cm，横向 jerk < 5 m/s³；
- **Apollo LQR**（实测 L4 车型）：横向误差 RMS ~10cm（高精地图场景），但 L2 辅助场景下因模型线性化误差，高速急弯略差。

差异来源：
- OpenPilot 依赖 supercombo 端到端模型给期望曲率，模型本身有学习到的"驾驶风格"（如提前减速入弯），所以即使 LatControl 简单，整体表现也接近人类驾驶；
- Apollo 依赖高精地图 + 规划器给出参考轨迹，LQR 跟踪精度高但缺少"驾驶风格"，更像机器驾驶。

---

## 12. AuroraDrive LatControl 方案（迁移建议）

### 12.1 现状回顾

AuroraDrive 当前横向控制（见 `AuroraDrive项目交接文档.md` 与 `cpp/include/ad/controller.h`）：

```cpp
// AuroraDrive PurePursuit（来自 controller.h）
struct PurePursuit {
    float wheelbase = kWheelbase;          // 2.7m
    float la_min = 8.0f, la_max = 25.0f;
    float k_la = 0.3f;                     // 预瞄距离系数
    float max_steer = kMaxSteer;           // 最大转向角

    float lookahead_dist(float speed_kmh) const noexcept {
        return clamp_val(k_la * speed_kmh, la_min, la_max);
    }

    float compute_steer(float ex, float ey, float heading,
                        float lx, float ly) const noexcept {
        float dx = lx - ex, dy = ly - ey;
        float l_d = std::sqrt(dx * dx + dy * dy);
        if (l_d < 0.01f) return 0.0f;
        float target_h = std::atan2(dy, dx);
        float alpha = norm_angle(target_h - heading);
        if (std::abs(alpha) > kPi * 0.5f) {       // 掉头场景
            return (alpha > 0 ? 1.0f : -1.0f) * max_steer;
        }
        float steer = std::atan2(2.0f * wheelbase * std::sin(alpha), l_d);
        return clamp_val(steer, -max_steer, max_steer);
    }
};
```

特点：
- **纯几何法**：基于 Ackermann 几何反解前轮转角 `δ = atan(2L·sin(α)/l_d)`；
- **无曲率概念**：直接输出转向角，不经过"期望曲率→扭矩/角度"分层；
- **无闭环反馈**：不读实际横向加速度/航向误差，开环跟踪；
- **无 jerk 限制**：转向角变化无速率限制，可能抖动；
- **无延迟补偿**：忽略执行器滞后；
- **AUTO 模式注入 A/D 键**：`assist_auto_lateral()` 把 PurePursuit 输出二值化为左转/右转按键（bang-bang），是更原始的实现。

### 12.2 是否升级到 LatControl？

**强烈建议升级**，理由：

1. **现状品质差**：bang-bang A/D 键注入导致方向盘抖动、不连续，驾驶体验差；
2. **无安全约束**：无 jerk/横向加速度限制，急弯可能失控；
3. **无反馈**：开环跟踪，误差累积无修正；
4. **已有路径序列**：AuroraDrive 有 `compute_road_guidance` 输出 path 点序列，正好可作为 LatControl 的参考轨迹；
5. **OpenPilot 方案成熟**：LatControlTorque 的设计可直接借鉴，工程风险低。

### 12.3 借鉴三策略切换的设计建议

**AuroraDrive 当前没有真实车辆 EPS 接口**（是仿真 + 键盘注入），所以"按 EPS 类型选策略"不直接适用。但可以借鉴**工厂模式**思想，按"执行器抽象层"切换：

```cpp
// 建议的 AuroraDrive LatControl 抽象基类
class LatControl {
public:
    virtual ~LatControl() = default;
    struct Result { float steer_cmd; float angle_cmd; float curvature; };
    virtual Result update(bool active, const VehicleState& vs,
                          float desired_curvature, bool steer_limited) = 0;
    virtual void reset() = 0;
};

// 工厂：按"执行器模式"选策略
std::unique_ptr<LatControl> create_lat_control(ActuatorMode mode) {
    switch (mode) {
        case ActuatorMode::SteerAngle:    return std::make_unique<LatControlAngle>();
        case ActuatorMode::SteerTorque:   return std::make_unique<LatControlTorque>();
        case ActuatorMode::KeyboardAD:    return std::make_unique<LatControlKeyboard>(); // AuroraDrive 现状
        case ActuatorMode::Curvature:     return std::make_unique<LatControlCurvature>();
    }
}
```

### 12.4 AuroraDrive LatControl 方案（分阶段实施）

#### 阶段 1（1 周）：引入"期望曲率"中间层 + clip_curvature

把 PurePursuit 输出的转向角反算为曲率 `κ = tan(δ) / L`，再经过 `clip_curvature` 做 jerk + 横向加速度限制：

```cpp
struct LateralPlanner {
    float prev_curvature = 0.0f;
    static constexpr float MAX_LATERAL_JERK = 5.0f;       // m/s³
    static constexpr float MAX_LATERAL_ACCEL = 3.0f;      // m/s²
    static constexpr float DT_CTRL = 1.0f / 24.0f;        // AuroraDrive 24Hz

    // 输入：PurePursuit 给的原始转向角 + 当前车速 + 道路侧倾（暂设 0）
    // 输出：限速后的期望曲率
    float clip_curvature(float v_ego, float steer_angle_rad, float roll = 0.0f) {
        float raw_curvature = std::tan(steer_angle_rad) / kWheelbase;
        float v = std::max(v_ego, 0.1f);

        // 1) jerk 限制：曲率变化率 ≤ MAX_LATERAL_JERK / v²
        float max_curv_rate = MAX_LATERAL_JERK / (v * v);
        float new_curv = std::clamp(raw_curvature,
                                    prev_curvature - max_curv_rate * DT_CTRL,
                                    prev_curvature + max_curv_rate * DT_CTRL);

        // 2) 横向加速度限制：|κ·v²| ≤ MAX_LATERAL_ACCEL ± roll·g
        float roll_comp = roll * 9.81f;
        float max_lat = MAX_LATERAL_ACCEL + roll_comp;
        float min_lat = -MAX_LATERAL_ACCEL + roll_comp;
        new_curv = std::clamp(new_curv, min_lat / (v * v), max_lat / (v * v));

        prev_curvature = new_curv;
        return new_curv;
    }
};
```

效果：解决 PurePursuit 在急弯时转向角突变导致的抖动，使方向盘输入平滑。

#### 阶段 2（2 周）：LatControlAngle 实现（仿真用）

仿真模式直接用方向盘角度命令（无需 EPS 接口），实现 OpenPilot LatControlAngle 的简化版：

```cpp
class LatControlAngle : public LatControl {
public:
    Result update(bool active, const VehicleState& vs,
                  float desired_curvature, bool steer_limited) override {
        Result r{};
        if (!active) { r.steer_cmd = 0; r.angle_cmd = vs.steer_angle; return r; }

        // 几何反解：κ → δ = atan(κ·L)，再转方向盘角度
        float steer_rad = std::atan(desired_curvature * kWheelbase);
        r.angle_cmd = steer_rad;          // 直接作为目标转向角
        r.curvature = desired_curvature;
        r.steer_cmd = steer_rad / kMaxSteer;   // 归一化 [-1,1] 给仿真
        return r;
    }
    void reset() override {}
};
```

效果：仿真里替换 PurePursuit 的 `compute_steer`，输出连续转向角命令而非 bang-bang。

#### 阶段 3（3 周）：LatControlTorque 实现（带在线学习）

借鉴 OpenPilot LatControlTorque，实现横向加速度闭环 + PID + 摩擦补偿。这一步主要用于辅助驾驶模式（AUTO），把目标转向角转成扭矩（模拟方向盘力反馈）：

```cpp
class LatControlTorque : public LatControl {
    float lat_accel_factor_ = 2.0f;       // 默认值，可学习
    float lat_accel_offset_ = 0.0f;
    float friction_ = 0.2f;
    PIDController pid_;                    // 复用 AuroraDrive 现有 PID

public:
    Result update(bool active, const VehicleState& vs,
                  float desired_curvature, bool steer_limited) override {
        Result r{};
        if (!active) { pid_.reset(); return r; }

        // 期望 vs 实际 横向加速度
        float desired_lat_accel = desired_curvature * vs.v_ego * vs.v_ego;
        float actual_curvature = std::tan(vs.steer_angle) / kWheelbase;
        float actual_lat_accel = actual_curvature * vs.v_ego * vs.v_ego;

        // 前馈
        float ff = desired_lat_accel - lat_accel_offset_;
        // 摩擦补偿（简化）
        float err = desired_lat_accel - actual_lat_accel;
        if (std::abs(err) > 0.1f) ff += (err > 0 ? friction_ : -friction_);

        // PID 闭环
        bool freeze = steer_limited || vs.v_ego < 5.0f;
        float pid_out = pid_.update(desired_lat_accel, actual_lat_accel, 1.0f / 24.0f);
        if (freeze) pid_out = 0;   // 简化冻结

        float torque = lat_accel_factor_ * (ff + pid_out);
        r.steer_cmd = std::clamp(torque, -1.0f, 1.0f);
        r.curvature = desired_curvature;
        return r;
    }
    void reset() override { pid_.reset(); }

    void update_live_torque_params(float f, float o, float fr) {
        lat_accel_factor_ = f;
        lat_accel_offset_ = o;
        friction_ = fr;
    }
};
```

#### 阶段 4（4 周）：steer_limited_by_safety 与 PoseCalibrator 等价物

- **steer_limited_by_safety**：仿真里可简化为"输出是否撞到 max_steer"，触发积分冻结；
- **PoseCalibrator**：仿真里不需要（车辆坐标系已知），但辅助驾驶模式若用真实摄像头，需要做设备-车体标定（参考 OpenPilot calibrationd）。

### 12.5 AuroraDrive LatControl 整体方案图

```
                       AuroraDrive LatControl 方案
                                  │
            ┌─────────────────────┼─────────────────────┐
            │                     │                     │
    仿真模式（24Hz）        辅助驾驶 AUTO          未来真车适配
            │                     │                     │
   [compute_road_guidance]  [compute_road_guidance]  [真实 EPS 接口]
            │                     │                     │
            ▼                     ▼                     ▼
   LateralPlanner           LateralPlanner         LateralPlanner
   (clip_curvature)         (clip_curvature)       (clip_curvature)
            │                     │                     │
            ▼                     ▼                     ▼
   LatControlAngle          LatControlTorque       按车型选 4 种策略
   (几何反解, 仿真直接用)    (横向加速度 PID)       (Angle/Torque/PID/Curvature)
            │                     │                     │
            ▼                     ▼                     ▼
   steer[-1,1] 给物理引擎   torque → A/D 键注入     CAN 报文 → 车辆 EPS
```

### 12.6 风险与对策

| 风险 | 对策 |
|------|------|
| PurePursuit → LatControl 切换瞬态跳变 | 失活时 `reset()` + 平滑过渡 1s |
| 横向加速度学习参数初值不准 | 默认 `latAccelFactor=2.0, friction=0.2`，仿真可调 |
| 仿真 24Hz vs OpenPilot 100Hz | 调整 `DT_CTRL = 1/24`，clip_curvature 的 jerk 限制按 24Hz 重新计算 |
| A/D 键注入延迟（CGEvent ~20ms） | 阶段 3 暂忽略，阶段 4 引入 lat_delay 前馈 |
| 无真实 IMU 反馈 | 仿真里 `actual_curvature` 从转向角反算，辅助驾驶模式可加视觉估计 |

### 12.7 不建议直接搬 OpenPilot 三策略切换

虽然 OpenPilot 的 4 策略工厂模式很优雅，但 AuroraDrive 当前没有真实车辆 EPS 接口多样性需求，**建议先实现 LatControlAngle + LatControlTorque 两种**：
- 仿真模式用 LatControlAngle（直接控转向角，最简单）；
- 辅助驾驶 AUTO 模式用 LatControlTorque（输出"扭矩"概念，为未来真车适配留接口）；
- LatControlPID 与 LatControlCurvature 暂不实现，待真车适配需要时再加。

这样既借鉴了 OpenPilot 的分层架构（LateralPlanner + LatControl），又不引入过度工程。

---

## 13. 关键文件与参考

### 13.1 OpenPilot 源码（GitHub: commaai/openpilot, master）

- `selfdrive/controls/lib/lateral_planner_lib/lateral_planner.py` — LateralPlanner 类
- `selfdrive/controls/lib/lateral_mpc_lib/lateral_mpc.py` — LateralMpc 求解器（见 02m 报告）
- `selfdrive/controls/lib/latcontrol.py` — LatControl 抽象基类 + `_check_saturation`
- `selfdrive/controls/lib/latcontrol_angle.py` — LatControlAngle + `STEER_ANGLE_SATURATION_THRESHOLD = 2.5`
- `selfdrive/controls/lib/latcontrol_torque.py` — LatControlTorque + `update_live_torque_params`
- `selfdrive/controls/lib/latcontrol_pid.py` — LatControlPID
- `selfdrive/controls/lib/latcontrol_curvature.py` — LatControlCurvature（新）
- `selfdrive/controls/lib/drive_helpers.py` — `clip_curvature` 实现
- `selfdrive/controls/controlsd.py` — 100Hz 控制环 + 工厂模式（见 02l 报告）
- `selfdrive/modeld/modeld.py` — `get_action_from_model` / `LAT_SMOOTH_SECONDS = 0.0`
- `selfdrive/modeld/parse_model_outputs.py` — `parse_mdn` MDN 解码（见 02j 报告）
- `selfdrive/locationd/helpers.py` — PoseCalibrator + Pose
- `selfdrive/locationd/calibrationd.py` — 设备位姿标定守护进程
- `selfdrive/locationd/locationd.py` — 实车参数学习守护进程（liveParameters）
- `selfdrive/card/torqued.py` — 扭矩参数学习守护进程（liveTorqueParameters）
- `opendbc/car/vehicle_model.py` — `get_steer_from_curvature` / `calc_curvature` 几何反解
- `opendbc/car/[brand]/values.py` — 各车型 CarParams 配置（steerControlType / lateralTuning）
- `opendbc/car/[brand]/carcontroller.py` — 各车型 CAN 报文打包
- `openpilot/cereal/log.capnp` — `LateralAngleState` / `LateralTorqueState` / `LateralPIDState` / `LateralCurvatureState` 消息定义

### 13.2 关键参数速查

| 参数 | 典型值 | 来源 |
|------|--------|------|
| `DT_MDL`（modeld/plannerd） | 0.05s (20Hz) | `common/realtime.py` |
| `DT_CTRL`（controlsd） | 0.01s (100Hz) | `common/realtime.py` |
| `LAT_SMOOTH_SECONDS` | 0.0（modeld 端不平滑） | `selfdrive/modeld/modeld.py` |
| `LONG_SMOOTH_SECONDS` | 0.3 | 同上 |
| `MAX_LATERAL_JERK` | ~5 m/s³ | `drive_helpers.py` |
| `MAX_LATERAL_ACCEL_NO_ROLL` | ~3 m/s² | `drive_helpers.py` |
| `STEER_ANGLE_SATURATION_THRESHOLD` | 2.5° | `latcontrol_angle.py`（注释 TODO 速度相关） |
| `sat_check_min_speed` | 5.0 m/s | `latcontrol.py` |
| 默认 `latAccelFactor` | 2.0 | `latcontrol_torque.py` |
| 默认 `friction` | 0.2 | 同上 |
| LatControlTorque 默认 tuning | `TORQUE_TUNE = (2.0, 0.0, 0.2)` | 同上 |
| LateralMpc 步数 N | ~16 | `lateral_mpc_lib` |
| LateralMpc 单步求解 | < 10ms（典型 2–5ms） | `solver.get_stats('time_tot')` |
| `steer_limited_by_safety` 角度阈值 | 2.5° | `controlsd.py::publish` |
| `steer_limited_by_safety` 扭矩阈值 | 0.01 Nm | 同上 |

### 13.3 对比参考

- Apollo LQR：`modules/control/controllers/lat/lat_controller.{h,cc}`（见 `Apollo研究/01s_control_lqr.md`）
- Apollo MPC：`modules/control/controllers/lat/mpc_controller.{h,cc}`（见 `Apollo研究/01r_control_mpc.md`）
- Apollo PID：`modules/control/controllers/lat/pid_controller.{h,cc}`（见 `Apollo研究/01t_control_pid.md`）
- AuroraDrive PurePursuit：`cpp/include/ad/controller.h`（见本文 §12.1）

### 13.4 外部参考

- comma.ai openpilot GitHub：https://github.com/commaai/openpilot
- comma.ai blog（driving policy / torqued 介绍）：https://blog.comma.ai
- Acados 官方文档：https://docs.acados.org/
- Rajamani《Vehicle Dynamics and Control》第 3 章（LQR 推导参考）
- CSDN 解析文：`blog.csdn.net/2301_80171004/article/details/150927630`（LatControl 综述）、`150779829`（controlsd）、`150851653`（LongitudinalPlanner）、`gitblog_00894/152101565`（横向算法）
- 51CTO cereal 解析：`blog.51cto.com/u_15941409/14441122`

---

## 14. 总结

OpenPilot 的横向控制栈是**"双层解耦 + 多策略工厂 + 在线学习"**的成熟工程实现，核心价值在于：

1. **架构清晰**：LateralPlanner（20Hz 规划）输出期望曲率，LatControl（100Hz 执行）按车型选 4 种策略之一转为方向盘命令，分层解耦使每层职责单一、可独立优化。

2. **跨车型一致性**：通过"工厂模式选策略 + 在线学习参数（torqued 学习 latAccelFactor/friction，locationd 学习 steerRatio/angleOffsetDeg）"，同一套代码适配 300+ 车型，无需每车手工调参。这是 OpenPilot 区别于 Apollo（每车调增益调度表）的根本工程优势。

3. **三策略对比**：
   - **LatControlAngle**（Honda 等）：几何反解 + 角度直控，简单可靠，依赖 EPS 内部角度闭环；
   - **LatControlTorque**（Toyota/Hyundai 等，主流推荐）：横向加速度 PID + 摩擦补偿 + 在线学习，跨车型一致性最好；
   - **LatControlPID**（早期 Hyundai/Chrysler/GM）：经典 PID 跟踪期望角度，参数固定需手工调，逐渐被 LatControlTorque 取代；
   - **LatControlCurvature**（新）：直接转发曲率给支持的新 EPS，最简化。

4. **安全机制完备**：`steer_limited_by_safety` 反馈 panda clamp + 三策略统一冻结积分器 + `_check_saturation` 区分"系统限制"与"控制器撞墙" + NaN/Inf 兜底，构成多重防护。

5. **位姿标定分层**：PoseCalibrator（设备→车体坐标系）+ liveParameters（车辆参数）+ liveTorqueParameters（扭矩模型参数）三层标定协同，支持运行时持续学习。

对 AuroraDrive 而言，从 PurePursuit/bang-bang 升级到"LatControl 分层架构"是横向品质的质变。建议分 4 阶段实施：先引入 `clip_curvature` 解决 jerk 抖动，再实现 LatControlAngle（仿真用）和 LatControlTorque（辅助驾驶用），最后视真车适配需要再加 PID/Curvature 策略。无论如何，"期望曲率中间层 + 反馈控制器"这一 OpenPilot 架构精髓，比几何法 PurePursuit 能带来本质更好的跟踪精度、平顺性与安全性。

---

> 本报告基于 WebSearch + WebFetch 共约 76 次内部工具调用完成，信息截至 2026-07-23。OpenPilot 代码持续演进（特别是 LatControlCurvature 是较新加入的策略），具体常量/步数/文件名以 master 分支为准。源码访问受 GitHub 登录限制，部分细节通过 grep.app 代码搜索与 CSDN/51CTO 解析文间接还原。
