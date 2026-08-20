# OpenPilot 纵向规划器（LongitudinalPlanner）与 LongControl 深度研究报告

> 研究对象：comma.ai / openpilot（master 分支，截至 2026-02）
> 核心源码：`selfdrive/controls/lib/longitudinal_planner.py`、`selfdrive/controls/lib/longitudinal_mpc_lib/long_mpc.py`、`selfdrive/controls/lib/longcontrol.py`、`selfdrive/controls/radard.py`、`selfdrive/controls/lib/drive_helpers.py`、`selfdrive/car/cruise.py`
> 报告目的：剖析 OpenPilot 纵向"感知 → 规划 → 控制"全链路，并给出 AuroraDrive 纵向控制的迁移与改进建议。

---

## 一、整体架构：纵向链路全景

OpenPilot 的纵向控制采用经典的**"分层 + 多源融合"**架构，整体可分为四个层级：

```
[camerad] → [modeld(supercombo模型)] → modelV2(leads/plans/action)
                                            ↓
[radard: 雷达track + 视觉lead 融合 + Kalman滤波] → radarState(leadOne/leadTwo)
                                            ↓
[plannerd: LongitudinalPlanner + LongitudinalMpc(MPC)] → longitudinalPlan(aTarget/shouldStop/v·a·j轨迹)
                                            ↓
[controlsd → LongControl(PI状态机)] → actuator.accel → [各车型 carcontroller] → CAN(油门/刹车)
```

要点：
- `modeld` 是"视觉先知"，输出未来约 10s 的自车轨迹（plans，含 33 个轨迹点的位置/速度/加速度/横摆）、前车信息（leadsV3，0s/2s/4s 三个时刻）、自车姿态估计（temporal_pose），以及端到端动作（`modelV2.action.desiredAcceleration`、`shouldStop`）。
- `radard` 把原车 ACC 雷达点与 `modelV2.leadsV3` 融合，做卡尔曼滤波，输出 `radarState.leadOne`（主前车）与 `leadTwo`（次前车）。
- `plannerd`（`LongitudinalPlanner`）以 20Hz（`DT_MDL = 0.05s`）运行，把雷达前车 + 巡航速度 + 模型轨迹喂给 `LongitudinalMpc`（Acados 生成的 C 求解器），求出未来 10s、N=12 步的最优 `v/a/j` 轨迹，再抽取即时指令 `aTarget` 和 `shouldStop`，发布 `longitudinalPlan`。
- `controlsd` 收到 `longitudinalPlan` 后调用 `LongControl`，用一个**带状态机的 PI 控制器**把 `aTarget` 跟踪成执行器加速度，并做执行器延迟补偿与限幅。
- 注意：OpenPilot **不存在独立的 vCurvature 模块**，弯道限速是通过 `limit_accel_in_turns` 在规划层"动态压低最大加速度上限"实现的（详见第五章）。

---

## 二、LongitudinalPlanner 架构详解

### 2.1 类结构与核心字段

`LongitudinalPlanner`（`selfdrive/controls/lib/longitudinal_planner.py`，约 192 行）是纵向规划的编排者。核心字段：

```python
class LongitudinalPlanner:
  def __init__(self, CP, init_v=0.0, init_a=0.0, dt=DT_MDL):
    self.CP = CP
    self.mpc = LongitudinalMpc(dt=dt)          # MPC 求解器
    self.fcw = False                            # 前向碰撞预警标志
    self.allow_throttle = True                  # 是否允许给油
    self.a_desired = init_a                     # 当前期望加速度（积分用）
    self.v_desired_filter = FirstOrderFilter(init_v, 2.0, self.dt)  # 一阶低通速度
    self.prev_accel_clip = [ACCEL_MIN, ACCEL_MAX]
    self.output_a_target = 0.0                  # 输出给控制层的即时目标加速度
    self.output_should_stop = False             # 输出停车标志
    self.v_desired_trajectory = np.zeros(CONTROL_N)   # 17 步速度轨迹
    self.a_desired_trajectory = np.zeros(CONTROL_N)
    self.j_desired_trajectory = np.zeros(CONTROL_N)
```

其中 `CONTROL_N = 17`（控制层使用的轨迹点数，从 MPC 的 12 步插值得到），`DT_MDL = 0.05s`。它同时持有 `LongitudinalMpc` 实例和一个一阶低通滤波器 `v_desired_filter`（τ=2.0s）用于平滑速度初值，防止 MPC 状态跳变。

### 2.2 update() 主循环：从输入到 aTarget

`update(sm)` 是核心，每 0.05s 调用一次。关键步骤如下（基于真实源码）：

**Step 1 — 读取与复位判断**
```python
v_ego = sm['carState'].vEgo
v_cruise_kph = min(sm['carState'].vCruise, V_CRUISE_MAX)   # 上限 145 kph
v_cruise = v_cruise_kph * CV.KPH_TO_MS
v_cruise_initialized = sm['carState'].vCruise != V_CRUISE_UNSET
long_control_off = sm['controlsState'].longControlState == LongCtrlState.off
force_slow_decel = sm['controlsState'].forceDecel
reset_state = long_control_off if CP.openpilotLongitudinalControl else not sm['selfdriveState'].enabled
reset_state = reset_state or not v_cruise_initialized
```
- `reset_state` 决定是否要把 MPC 状态重置到当前 `v_ego`，避免退出后再激活时产生剧烈加速。
- `prev_accel_constraint = not (reset_state or standstill)`：只有正常激活且非静止时，才在 MPC 中启用"与上一帧加速度平滑"的代价项，停车/重置时不约束以保证起步果断。

**Step 2 — 构造加速度上下限（accel_clip）**
```python
accel_clip = [ACCEL_MIN, get_max_accel(v_ego)]   # ACCEL_MIN≈-3.5, 速度相关最大加速
accel_clip = limit_accel_in_turns(v_ego, steer_angle_without_offset, accel_clip, CP)
```
`get_max_accel` 用查表 `A_CRUISE_MAX_BP=[0,10,25,40]` / `A_CRUISE_MAX_VALS=[1.6,1.2,0.8,0.6]` 随车速降低最大加速度——**速度越高，允许的纵向加速度越小**，这是舒适性约束。`limit_accel_in_turns` 再根据横向加速度进一步压低上限（见第五章）。

**Step 3 — 模型解析与油门许可**
```python
_, _, _, _, throttle_prob = self.parse_model(sm['modelV2'])
self.allow_throttle = throttle_prob > ALLOW_THROTTLE_THRESHOLD or v_ego <= MIN_ALLOW_THROTTLE_SPEED
```
`parse_model` 从 `modelV2.meta.disengagePredictions.gasPressProbs[1]` 读取"模型预测驾驶员会踩油门的概率"。若该概率过高（>0.4），说明模型认为这里需要驾驶员主动给油（如陡坡、急加速），OpenPilot **主动禁止给油**，只允许滑行/制动，从而避免与驾驶员意图冲突。低速（≤2.5 m/s）不启用该限制，因为 `throttle_prob` 没考虑蠕行。

**Step 4 — 喂给 MPC 求解**
```python
self.mpc.set_weights(prev_accel_constraint, personality=sm['selfdriveState'].personality)
self.mpc.set_cur_state(self.v_desired_filter.x, self.a_desired)
self.mpc.update(sm['radarState'], v_cruise, personality=...)
self.v_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.v_solution)
self.a_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.a_solution)
self.j_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC[:-1], self.mpc.j_solution)
```
MPC 返回未来 N+1=13 个时刻的 `v_solution / a_solution / j_solution`，插值到 17 步控制时序。

**Step 5 — FCW 与状态推进**
```python
self.fcw = self.mpc.crash_cnt > 2 and not sm['carState'].standstill
a_prev = self.a_desired
self.a_desired = float(np.interp(self.dt, CONTROL_N_T_IDX, self.a_desired_trajectory))
self.v_desired_filter.x += self.dt * (self.a_desired + a_prev) / 2.0   # 梯形积分推进 v
```
FCW（前向碰撞预警）需要 MPC 连续 3 帧判定会碰撞才触发，避免雷达噪声误报。速度用梯形积分推进，作为下一帧 MPC 的初始状态。

**Step 6 — 抽取即时指令 + 端到端融合**
```python
action_t = CP.longitudinalActuatorDelay + DT_MDL
output_a_target_mpc, output_should_stop_mpc = get_accel_from_plan(
    self.v_desired_trajectory, self.a_desired_trajectory, CONTROL_N_T_IDX,
    action_t=action_t, vEgoStopping=CP.vEgoStopping)
output_a_target_e2e = sm['modelV2'].action.desiredAcceleration
output_should_stop_e2e = sm['modelV2'].action.shouldStop
if sm['selfdriveState'].experimentalMode:
    output_a_target = min(output_a_target_e2e, output_a_target_mpc)   # 取更保守者
    self.output_should_stop = output_should_stop_e2e or output_should_stop_mpc
    if output_a_target < output_a_target_mpc:
        self.mpc.source = LongitudinalPlanSource.e2e
else:
    output_a_target = output_a_target_mpc
    self.output_should_stop = output_should_stop_mpc
```
- `get_accel_from_plan`（见 `drive_helpers.py`）按执行器延迟 `action_t` 取未来时刻目标速度，再用 `a_target = 2*(v_target - v_now)/action_t - a_now` 反推加速度，并判 `should_stop = (v_now < vEgoStopping and a_target < 0.1)`。这是**执行器延迟补偿**的核心。
- **实验模式（端到端）**：直接用模型输出的 `desiredAcceleration`，但与 MPC 取 `min`（更保守），`shouldStop` 取或。这是 0.9.0 引入的端到端纵向，能处理弯道减速、红灯停车、绿灯起步等 MPC 难以表达的语义场景。

**Step 7 — 最终限幅与平滑（防跳变）**
```python
for idx in range(2):
    accel_clip[idx] = np.clip(accel_clip[idx], self.prev_accel_clip[idx]-0.05, self.prev_accel_clip[idx]+0.05)
self.output_a_target = np.clip(output_a_target, accel_clip[0], accel_clip[1])
self.prev_accel_clip = accel_clip
```
每帧 accel_clip 的上下限只允许相对上一帧变化 ±0.05 (m/s²)/帧，**这是 jerks 平滑的最后一道闸**，防止 MPC 解在帧间抖动产生顿挫。

### 2.3 publish() 输出
`longitudinalPlan` 消息含：`speeds/accels/jerks`（完整轨迹）、`hasLead`（=leadOne.status）、`longitudinalPlanSource`（lead0/lead1/cruise/e2e）、`fcw`、`aTarget`、`shouldStop`、`allowBrake=True`、`allowThrottle`。控制层据此执行。

---

## 三、从 modeld 到 LongitudinalPlanner：感知链路

### 3.1 modelV2 消息与前车字段
`modeld` 跑 `supercombo` 模型，与纵向相关的输出：
- `modelV2.leadsV3[i]`：3 个时刻（0/2/4s）的前车预测，每个含 `x[]/y[]/v[]/a[]`（时间序列）、`xStd/yStd/vStd`（不确定性）、`prob`（前车存在概率）。
- `modelV2.position/velocity/acceleration`：自车未来轨迹。
- `modelV2.meta.disengagePredictions.gasPressProbs`：驾驶员踩油门/刹车概率，用于 `allow_throttle`。
- `modelV2.action.desiredAcceleration`、`shouldStop`：端到端纵向动作。

### 3.2 leadVehicle 输出（dRel / yRel / vRel）
雷达接口（`selfdrive/car/XXX/radar_interface.py`）把 ACC 雷达 CAN 信号转成 `(dRel, yRel, vRel, measured)`：方位角 azimuth 被换成横向偏移 `yRel`，距离换成纵向 `dRel`。**大部分原车雷达不提供前车加速度 `aRel`**，需要后续用 Kalman 估计。

### 3.3 多 hypothesis 解码
`radard` 只用 `leadsV3[0]` 和 `leadsV3[1]`（即 0s 与 2s 两个前车假设），分别对应"当前主前车"与"可能切入/远处的次前车"。模型给出前车存在的概率 `prob`，`radard` 用一个**非对称一阶滤波**（`lead_prob_filters`）处理它：
```python
if lead_prob > self.lead_prob_filters[i].x:
    self.lead_prob_filters[i].x = lead_prob   # 概率上升立即跟随
else:
    self.lead_prob_filters[i].update(lead_prob) # 概率下降缓慢衰减
```
这种"快上慢下"的非对称滤波保证：**前车一旦出现立即响应，前车消失时延迟一会再确认**，避免短暂遮挡导致目标频繁丢失。

### 3.4 卡尔曼滤波（KF1D）
`Track` 类为每个雷达 track 维护一个 `KF1D`，状态量 `[v, a]`、观测量 `[v]`：
- 状态转移 `A = [[1, dt],[0,1]]`，测量 `C = [1, 0]`。
- 过程噪声 `Q≈[[10,0],[0,100]]`、测量噪声 `R≈1e3`（源码注释给出，实际预计算成 K0/K1 查表，按 dt∈[0.01,0.2] 插值卡尔曼增益）。
- 由于系统线性，用简化的 KF1D 而非 EKF；增益 K 与状态/观测无关，会收敛到稳态，故离线预算好查表。
- `update()` 中 `self.kf.update(self.vLead)` 得到 `vLeadK`、`aLeadK`。
- `aLeadTau` 是前车加速度衰减常数（`FirstOrderFilter(_LEAD_ACCEL_TAU=1.5, 0.45, DT_MDL)`）：当 `|aLeadK|<0.5` 时重置 τ=1.5（认为匀速，加速度衰减慢），否则向 0 衰减（认为加速度是瞬态的，会快速消散）。这影响 MPC 对前车未来行为的预测。

---

## 四、Lead Car 信息融合算法

### 4.1 融合核心：get_lead()
`radard.get_lead()` 是视觉与雷达融合的关键。逻辑：
1. 若 `lead_prob > 0.5` 且雷达 ready，调用 `match_vision_to_track`：用拉普拉斯概率 `laplacian_pdf` 分别在 d/y/v 三个维度计算每个雷达 track 与视觉 lead 的匹配概率，取 `prob = prob_d * prob_y * prob_v` 最大的 track，并做 sanity check（距离差<25%且<5m、速度差<10m/s）。
2. 匹配上 → 用雷达 track 的 `get_RadarState(lead_prob)`（含 KF 滤波后的 vLeadK/aLeadK）。
3. 匹配不上但视觉 prob>0.5 → 用纯视觉 `get_RadarState_from_vision`（aLeadK 直接取 `lead_msg.a[0]`，aLeadTau=0.3）。
4. `low_speed_override`（仅 leadOne）：低速（`v_ego<4`）下，对 `|yRel|<1.0 且 0.75<dRel<25` 的近距 track，即使模型未确认也强制作为前车——这是**低速蠕行/拥堵场景的保底**，防止视觉在低速时漏检导致追尾。

可见优先级：**视觉确认的雷达 track > 纯视觉 lead > 低速雷达保底**；且当 `lead_prob<0.5` 时直接拒绝所有雷达数据输出"无前车"，即视觉对雷达有"否决权"。

### 4.2 leadOne / leadTwo 的差异
- `leadOne`：主前车，`low_speed_override=True`，会用于 FCW 与停车。
- `leadTwo`：次前车（如隔壁车道可能切入的车），`low_speed_override=False`，作为 MPC 的第二个障碍物候选。

### 4.3 MPC 内的 Lead 处理（process_lead / extrapolate_lead）
`LongitudinalMpc.process_lead(lead)` 把单时刻前车外推到 10s 轨迹：
```python
a_lead_traj = a_lead * np.exp(-a_lead_tau * (T_IDXS**2)/2.)   # 加速度按 tau 指数衰减
v_lead_traj = np.clip(v_lead + np.cumsum(T_DIFFS * a_lead_traj), 0, 1e8)
x_lead_traj = x_lead + np.cumsum(T_DIFFS * v_lead_traj)
```
关键技巧：
- **无前车时伪造一辆"快车"**：`x_lead=50, v_lead=v_ego+10, a_lead=0`，让 MPC 仍按"巡航追快车"模式跑，流程统一。
- **防不可制动**：`min_x_lead = MIN_X_LEAD_FACTOR * (v_ego+v_lead)*(v_ego-v_lead)/(-ACCEL_MIN*2)`，把过近的前车距离 clip 到"还能刹住"的范围，否则 MPC 不收敛。
- **障碍物等效**：`lead_obstacle = x_lead_traj + get_stopped_equivalence_factor(v_lead_traj)`，其中 `get_stopped_equivalence_factor(v) = v²/(2*COMFORT_BRAKE)`（COMFORT_BRAKE=2.5）。含义：把"运动中的前车"换算成"距离更远的静止障碍物"——前车速度越快，等效静止障碍物越远，因为本车需要更长距离才能追上。

### 4.4 三障碍物择近机制
MPC 同时构造三个障碍物：`lead_0_obstacle`、`lead_1_obstacle`、`cruise_obstacle`（巡航速度虚拟障碍物）。`cruise_obstacle = cumsum(T_DIFFS*v_cruise_clipped) + get_safe_obstacle_distance(v_cruise, t_follow)`，其中 `get_safe_obstacle_distance(v, t) = v²/(2*COMFORT_BRAKE) + t*v + STOP_DISTANCE`（STOP_DISTANCE=6m）——即"舒适制动距离 + 时距距离 + 安全余量"。
然后 `self.params[:,2] = np.min(x_obstacles, axis=1)`：**每个未来时刻取最近障碍物作为约束**，并 `self.source = MPC_SOURCES[np.argmin(x_obstacles[0])]` 记录主导源（lead0/lead1/cruise）。这样一帧 MPC 同时考虑"前车"和"巡航限速"两个目标，自动在它们之间切换。

### 4.5 v_ego / v_lead / a_lead 的角色
- `v_ego`：来自 `carState.vEgo`（Kalman 融合 IMU/轮速），是 MPC 初始状态 `x0[1]`。
- `v_lead`：`vRel + v_ego`，KF 滤波后得 `vLeadK`。
- `a_lead`：KF 估计的 `aLeadK`，外推衰减后驱动前车未来轨迹。

---

## 五、vCruise、vCurvature 与弯道限速

### 5.1 vCruise（巡航速度）
由 `VCruiseHelper`（`selfdrive/car/cruise.py`）管理，关键常量：
```python
V_CRUISE_MIN = 8        # kph
V_CRUISE_MAX = 145      # kph
V_CRUISE_UNSET = 255
V_CRUISE_INITIAL = 40              # 普通模式初值
V_CRUISE_INITIAL_EXPERIMENTAL_MODE = 105  # 实验模式初值
CRUISE_LONG_PRESS = 50  # 长按阈值（帧）
IMPERIAL_INCREMENT = round(MPH_TO_KPH, 1)
```
- **两种巡航来源**：`CP.pcmCruise=True`（PCM 巡航，速度取原车 `cruiseState.speed`）与 `pcmCruise=False`（OpenPilot 自管理，用按钮逻辑）。
- **按钮调节**：`accelCruise`/`decelCruise` 短按步长 1 kph（公制）/1.6 kph（英制），长按（>50 帧）5 倍步长；长按还会就近取整到步长倍数。
- **安全钳位**：驾驶员踩油门时按 `set`/`decel`，会把设定速度钳到不低于当前 `vEgo`；初始化时若按 resume/accel 用上一值，否则 `clip(vEgo, initial, MAX)`。
- **与 LongControl 的接口**：`v_cruise = min(vCruise, V_CRUISE_MAX) * KPH_TO_MS` 传入 `LongitudinalMpc.update`，构造 `cruise_obstacle` 作为速度上限的"虚拟障碍物"。注意 OpenPilot **不直接把 (v_cruise - v_ego) 作为误差代价**，而是让"追巡航障碍物"自然形成限速，这是设计上的精巧之处。
- `force_slow_decel`（如踩刹车）会把 `v_cruise=0`，强制 MPC 减速。

### 5.2 vCurvature（弯道限速）—— 实为 limit_accel_in_turns
OpenPilot **没有独立的 vCurvature 模块**，弯道限速通过 `limit_accel_in_turns` 动态压低加速度上限实现：
```python
_A_TOTAL_MAX_V = [1.7, 3.2]
_A_TOTAL_MAX_BP = [20., 40.]      # 总加速度上限随车速升高
def limit_accel_in_turns(v_ego, angle_steers, a_target, CP):
    a_total_max = np.interp(v_ego, _A_TOTAL_MAX_BP, _A_TOTAL_MAX_V)
    a_y = v_ego**2 * angle_steers * CV.DEG_TO_RAD / (CP.steerRatio * CP.wheelbase)
    a_x_allowed = math.sqrt(max(a_total_max**2 - a_y**2, 0.))
    return [a_target[0], min(a_target[1], a_x_allowed)]
```
原理：用"圆周运动横向加速度 `a_y = v²·δ/( steerRatio·wheelbase )`"近似，在"总加速度包络 `a_total_max`"下，剩余额度分给纵向 `a_x_allowed = √(a_total_max² − a_y²)`。弯越急（a_y 越大），允许的纵向加速度越小，从而**弯道自动减速/不加速**。这是经典的"加速度圆约束"思想，比单独算 vCurvature 更紧凑。源码注释也承认该横向加速度公式不准确（应用 VehicleModel），但工程上够用。

> 补充：横向链路里 `drive_helpers.clip_curvature` 按 ISO 横向 jerk/加速度限制约束曲率（`MAX_LATERAL_JERK=5`、`MAX_LATERAL_ACCEL_NO_ROLL=3`），与纵向的 `limit_accel_in_turns` 共同保证弯道舒适。

---

## 六、LongControl：PI 控制律与状态机

`LongControl`（`selfdrive/controls/lib/longcontrol.py`，88 行）是把 `aTarget` 落地到执行器加速度的执行层，运行频率 `DT_CTRL`（100Hz）。

### 6.1 状态机 long_control_state_trans
四种状态：`off / stopping / starting / pid`。转移条件：
```python
stopping_condition = should_stop
starting_condition = (not should_stop and not cruise_standstill and not brake_pressed)
started_condition  = v_ego > CP.vEgoStarting
```
- `off`：未激活 → off。
- 从 `off`：若 `starting_condition` 且 `CP.startingState` → `starting`；否则 → `stopping`（除非可直接 starting）。
- `stopping` → `starting`（需 starting_condition+startingState）或 → `pid`（starting_condition 无需 startingState）。
- `starting/pid` → `stopping`（should_stop）或 → `pid`（v_ego>vEgoStarting）。
即：**停车保持→按 resume/解除静止→starting 爬起→超过 vEgoStarting→pid 正常跟踪**。

### 6.2 PI 控制器（PIDController，实际只用 P+I+前馈）
```python
self.pid = PIDController((CP.longitudinalTuning.kpBP, CP.longitudinalTuning.kpV),
                         (CP.longitudinalTuning.kiBP, CP.longitudinalTuning.kiV),
                         rate=1/DT_CTRL)
```
- Kp、Ki 都是**速度分段查表**（kpBP/kpV、kiBP/kiV），随 `v_ego` 变化，低速增益大、高速增益小，适配起步与巡航。
- **注意**：commit `7534b2a`（2025-10）已**移除前馈增益（ff gain）**，当前 `update` 传 `feedforward=a_target` 但实际不再使用 ff 项，纯靠 PI。这是为避免前馈与积分叠加导致超调。
- `neg_limit/pos_limit = accel_limits[0]/[1]`：积分与输出都被钳到当前加速度上下限（来自规划层 accel_clip）。

### 6.3 update() 控制律（按状态分支）
```python
if state == off:
    self.reset(); output_accel = 0.
elif state == stopping:
    output_accel = self.last_output_accel
    if output_accel > CP.stopAccel:
        output_accel = min(output_accel, 0.0)
    output_accel -= CP.stoppingDecelRate * DT_CTRL   # 每帧匀减速
    self.reset()                                      # 停车过程不积分
elif state == starting:
    output_accel = CP.startAccel                      # 固定起步加速度
    self.reset()
else:  # pid
    error = a_target - CS.aEgo
    output_accel = self.pid.update(error, speed=CS.vEgo, feedforward=a_target)
self.last_output_accel = np.clip(output_accel, accel_limits[0], accel_limits[1])
```
要点：
1. **off**：输出 0，复位 PID。
2. **stopping（停车保持/减速到 0）**：从上一帧加速度出发，若大于 `stopAccel`（停车保持加速度，通常为负小值）先钳到 ≤0，再每帧减 `stoppingDecelRate*DT_CTRL`，形成**线性匀减速**到 `stopAccel` 并保持。该状态**不复位误差积分**而是 `reset()`，保证停车平稳不抖。
3. **starting（起步）**：直接给固定 `startAccel`（车型标定的起步加速度），不跑 PID，保证从 0 起步果断且一致。
4. **pid（正常跟车/巡航）**：`error = a_target - aEgo`，PI 跟踪目标加速度。注意**误差是加速度误差**而非速度误差——因为上游 `LongitudinalPlanner` 已经把速度规划成了 `aTarget`，LongControl 只做加速度闭环。`feedforward=a_target` 历史上用作前馈，现已禁用。

### 6.4 输出限制与死区
- 输出统一 `np.clip(output_accel, accel_limits[0], accel_limits[1])`，accel_limits 由 controlsd 根据 `longitudinalPlan.allowThrottle/allowBrake` 和车型能力给出。
- "死区"主要体现在 `stopping` 分支的 `stopAccel` 与 `vEgoStopping`（规划层 `should_stop` 判定 `v_now < vEgoStopping`），低速时切到匀减速保持，避免 PID 在 0 附近抖动。
- 速度→加速度→油门/刹车：`output_accel` 经 `carcontroller` 转成 CAN（多数车型发 ACC 控制器命令，由原车执行油门/刹车；OpenPilot 自管纵向的车型直接算油门/刹车标定表）。

### 6.5 执行器延迟补偿
执行器延迟 `CP.longitudinalActuatorDelay`（0.15~0.5s）在两层处理：
- 规划层：`action_t = longitudinalActuatorDelay + DT_MDL`，`get_accel_from_plan` 取未来 `action_t` 时刻的目标，提前量补偿。
- 这使得 LongControl 拿到的 `aTarget` 已经是"考虑延迟后应该现在发出的值"，PI 只需跟踪，无需自己预测。

---

## 七、启停场景与跟车

### 7.1 启动（0 km/h 起步）
- 进入 `starting` 状态（需 `starting_condition`：非 should_stop、非 cruise_standstill、非 brake_pressed，且车型支持 `CP.startingState`，或直接进 pid）。
- 输出固定 `CP.startAccel`，直到 `v_ego > CP.vEgoStarting` 切到 `pid`。
- 实验模式下，绿灯起步可由 `modelV2.action.desiredAcceleration`（端到端）驱动，识别信号灯语义。

### 7.2 停车（减速到 0）
- `LongitudinalPlanner` 经 `get_accel_from_plan` 判 `should_stop = (v_now < vEgoStopping and a_target < 0.1)`。
- `should_stop=True` → LongControl 进 `stopping`，匀减速到 `stopAccel` 保持。
- 停车距离设计：`get_safe_obstacle_distance` 含 `STOP_DISTANCE=6m` 余量 + 时距项 + 舒适制动项，偏保守。
- `cruise_standstill`（原车巡航静止）下需按 resume 才能解除。

### 7.3 跟车（保持时距）
- 由 MPC 主导：`t_follow`（standard=1.45s，relaxed=1.75s，aggressive=1.25s）决定 `get_safe_obstacle_distance` 中的时距项 `t_follow * v_ego`。
- MPC 代价里主项 `((x_obstacle - x_ego) - desired_dist)/(v_ego+10)`：偏离期望距离的代价，距离归一化避免低速时过激。
- `LEAD_DANGER_FACTOR=0.75` 作为软约束（slack），允许略微突破期望距离但代价陡升（`DANGER_ZONE_COST=100`）。

### 7.4 紧急刹车 / FCW
- MPC 最大减速度受 `ACCEL_MIN≈-3.5 m/s²` 限制，**无法全力制动**——OpenPilot 不替代原车 AEB，只做舒适制动。
- FCW：`crash_cnt > 2`（连续 3 帧 MPC 预测 5s 内车距<`CRASH_DISTANCE=0.25m` 且 `leadOne.modelProb>0.9`）触发声光预警。
- `force_slow_decel`（驾驶员踩刹车等）强制 `v_cruise=0`，快速减速。

---

## 八、港口/起步与停车保持

OpenPilot 原生不针对港口场景，但其启停机制可迁移：

- **起步条件**：`starting_condition = not should_stop and not cruise_standstill and not brake_pressed`，即"规划不要求停 + 巡航未静止 + 未踩刹车"，且需用户按 resume 解除 `cruise_standstill`（`resume_required` 事件）。
- **起步加速度**：`CP.startAccel`（车型标定，典型 0.5~1.0 m/s²），固定值保证一致爬起。
- **停车保持**：`stopping` 状态输出 `stopAccel`（典型 -0.1~-0.3 m/s² 的轻微保持力）维持静止，防止溜车。
- **港口迁移要点**：港口低速高精度跟车需要更小 `STOP_DISTANCE`、更短 `t_follow`、更稳的 `startAccel`，并强化低速雷达保底（`potential_low_speed_lead`）与蠕行逻辑。OpenPilot 的 `vEgoStarting`/`vEgoStopping` 阈值（典型 0.3~0.5 m/s）是启停平滑的关键参数。

---

## 九、与 Apollo 速度控制对比

| 维度 | OpenPilot LongControl | Apollo LonBasedPidController |
|------|----------------------|------------------------------|
| 架构层级 | 规划层 MPC（Acados，10s/12步）+ 控制层 PI 状态机 | 规划层 ST 图速度规划 + 控制层**位置/速度双环 PID** |
| 控制律 | PI（加速度闭环，`error=a_target-aEgo`），近期移除前馈 | 位置外环 PID + 速度内环 PID + 前馈补偿，含数字低通滤波 |
| 跟车决策 | MPC 内三障碍物择近（lead0/lead1/cruise），软约束 + 危险区代价 | 规划层 ST 图投影障碍物，DP/QP 速度规划，控制层只跟踪 |
| 巡航限速 | 虚拟 cruise_obstacle，不直接做 (v_set−v_ego) 误差 | 显式速度跟踪误差 |
| 弯道限速 | `limit_accel_in_turns` 加速度圆约束（动态压 a_max） | 规划层曲率限速（vCurvature 显式计算） |
| 执行器延迟补偿 | 规划层 `action_t` 取未来目标，提前量补偿 | 控制器内 delay 补偿 + 预测 |
| 标定 | 车型 `kpV/kiV` 查表 + `startAccel/stopAccel/stoppingDecelRate` | 油门/刹车标定表（CalibrationTable）+ 增益调度 |
| 频率 | 规划 20Hz / 控制 100Hz | 控制 10Hz（TimerComponent） |
| 前车估计 | 雷达+视觉融合 + KF1D（[v,a]）+ aLeadTau 衰减外推 | 依赖感知/预测模块输出，控制层不做滤波 |
| 端到端 | 实验模式 `modelV2.action` 直接出 aTarget，与 MPC 取 min | 无（纯规则） |
| 安全 | ACCEL_MIN≈-3.5 不替代 AEB，FCW 预警 | estop 字段可急停 |

**控制律差异本质**：
- Apollo 是"规划给轨迹/速度，控制层双环 PID 跟踪位置+速度"，**控制层职责重**，需要标定表把加速度映到油门/刹车。
- OpenPilot 是"规划层 MPC 直接给 `aTarget`（已含跟车/限速/弯道/延迟），控制层只做加速度 PI 闭环 + 启停状态机"，**规划层职责重**，控制层极简（88 行）。
- OpenPilot 的优势：MPC 在约束下自然权衡舒适（jerk 代价 `J_EGO_COST=5`、`A_CHANGE_COST=200`）、安全（危险区/碰撞约束）、目标（距离/巡航），帧间 ±0.05 限幅保证平顺；前车 KF + 衰减外推让跟车更准。
- Apollo 的优势：双环 PID 对轨迹跟踪精度高、标定体系成熟、ST 图速度规划对复杂交通流处理更结构化；但控制层滤波/抗饱和调参复杂。

**性能差异**：OpenPilot 以"舒适性 + 简洁"见长（jerk 小、顿挫少），但最大减速度受限不适合紧急场景；Apollo 跟踪精度与可急停能力更强，但调参与标定成本高。

---

## 十、AuroraDrive LongControl 改进方案

> 假设 AuroraDrive 当前纵向为"PID 单环 + 固定时距"，以下是借鉴 OpenPilot 的渐进式改进。

### 10.1 现状痛点
- 单环 PID 直接跟踪速度/加速度，缺少对前车未来行为的预测，跟车滞后、顿挫。
- 固定时距无法适配驾驶风格与路况，激进/保守不可调。
- 弯道限速若仅靠曲率查表，与纵向加速度耦合差，易在弯中突加/突减。
- 启停靠 PID 在 0 附近硬抗，抖动；执行器延迟未在规划层补偿。

### 10.2 借鉴 Lead Car 信息融合
1. **引入前车 KF 估计**：对前车 `[v, a]` 做卡尔曼滤波（雷达不给出 a 时尤其重要），输出 `vLeadK/aLeadK`。
2. **aLeadTau 衰减外推**：用 `a_lead*exp(-tau*t²/2)` 外推前车未来 10s 速度/位置，把"单时刻前车"变成"未来轨迹前车"，让规划提前响应前车减速。
3. **运动前车→静止障碍物等效**：`stopped_equivalence = v_lead²/(2*COMFORT_BRAKE)`，统一运动/静止前车处理。
4. **多前车（leadOne/leadTwo）**：维护主前车 + 次前车（潜在切入），MPC 同时约束，提升Cut-in 场景表现。
5. **视觉否决权 + 低速雷达保底**：视觉 prob<0.5 拒绝雷达；低速强制近距 track 作前车，防拥堵追尾。

### 10.3 借鉴 vCruise / vCurvature
1. **vCruise 作为虚拟障碍物**：不直接做 (v_set−v_ego) 误差，而是构造"巡航速度障碍物"让 MPC 自然限速，巡航与跟车统一框架。
2. **加速度圆约束替代 vCurvature 查表**：`a_x_allowed = √(a_total_max² − a_y²)`，弯道动态压低纵向 a_max，耦合更紧、更平滑。
3. **personality 分级**：引入 relaxed/standard/aggressive 三档 `t_follow`（1.75/1.45/1.25）与 `jerk_factor`，用户可调。

### 10.4 LongControl 改进（保留 PID，增强状态机）
1. **四态状态机**：off/stopping/starting/pid，停车用 `stoppingDecelRate` 匀减速到 `stopAccel` 保持，起步用固定 `startAccel`，正常用 PI——避免 PID 在 0 附近抖动。
2. **加速度闭环（不是速度闭环）**：让规划层出 `aTarget`，控制层 `error = a_target - aEgo`，PI 只跟踪加速度，职责清晰。
3. **执行器延迟上移**：在规划层用 `action_t = actuatorDelay + dt` 取未来目标（`get_accel_from_plan`），控制层无需预测，简化调参。
4. **Kp/Ki 速度分段查表**：低速大增益、高速小增益，适配全速域。
5. **帧间限幅平滑**：每帧 accel_clip ±0.05 限幅，防 MPC 解抖动传递到执行器。
6. **移除前馈或谨慎使用**：参考 OpenPilot 近期移除 ff gain 的经验，避免 ff+I 叠加超调。

### 10.5 推进路线（由易到难）
- **P0（1~2 周）**：前车 KF + aLeadTau 外推 + 加速度圆约束弯道限速 + 四态状态机启停。纯算法增强，不动框架，立即改善跟车顿挫与弯道突加。
- **P1（3~6 周）**：引入轻量 MPC（如 Acados 或自研 QP），三障碍物择近 + 虚拟巡航障碍物 + personality 分级，替换单环 PID 的规划职责。
- **P2（长期）**：端到端纵向融合（模型出 `desiredAcceleration`，与 MPC 取 min），处理信号灯/让行等语义场景；多前车 + Cut-in 预测。
- **风险**：MPC 求解实时性需保证（OpenPilot 用 SQP_RTI + HPIPM，10 迭代内收敛）；前车 KF 参数需按雷达频率标定；personality 需实车验证安全裕度。

### 10.6 关键参数清单（可直接借用）
| 参数 | OpenPilot 值 | 含义 |
|------|-------------|------|
| `t_follow` | 1.45s(标准) | 跟车时距 |
| `STOP_DISTANCE` | 6.0 m | 停车安全余量 |
| `COMFORT_BRAKE` | 2.5 m/s² | 舒适制动减速度 |
| `ACCEL_MIN` | ≈-3.5 m/s² | 最大减速度（不替代 AEB） |
| `CRASH_DISTANCE` | 0.25 m | FCW 碰撞阈值 |
| `LEAD_DANGER_FACTOR` | 0.75 | 危险区软约束因子 |
| `N / MAX_T` | 12 / 10s | MPC 步数/预测时域 |
| `J_EGO_COST / A_CHANGE_COST` | 5 / 200 | jerk/加速度变化代价 |
| `vEgoStopping / vEgoStarting` | ~0.3 / ~0.5 m/s | 启停切换阈值 |
| `stopAccel / startAccel / stoppingDecelRate` | 车型标定 | 停车保持/起步/减速速率 |

---

## 十一、关键结论

1. **OpenPilot 纵向是"重规划（MPC）+ 轻控制（PI 状态机）"架构**，规划层用 Acados MPC 在 10s/12 步时域内统一权衡跟车、巡航、弯道、舒适、安全，控制层仅 88 行做加速度闭环与启停。
2. **Lead Car 融合**是核心：雷达 track + 视觉 lead 拉普拉斯概率匹配 + KF1D 估计 `[v,a]` + aLeadTau 指数衰减外推 + 运动静等效 + 三障碍物择近，一帧 MPC 同时处理前车与巡航。
3. **弯道限速**不是独立 vCurvature，而是 `limit_accel_in_turns` 的加速度圆约束，动态压低 a_max。
4. **启停**靠四态状态机：starting 固定加速度、stopping 匀减速保持、pid 正常跟踪，避免 0 附近抖动。
5. **端到端**实验模式用模型 `desiredAcceleration` 与 MPC 取 min，处理语义场景。
6. **vs Apollo**：OpenPilot 规划重、控制简、舒适性好但无全力制动；Apollo 控制重（双环 PID+标定表）、跟踪精度高、可急停但调参成本高。
7. **AuroraDrive 改进**：优先借鉴前车 KF+外推、加速度圆约束、四态状态机、执行器延迟上移、Kp/Ki 分段，再渐进引入 MPC 与端到端。

---

## 参考源码与资料

- `selfdrive/controls/lib/longitudinal_planner.py`（LongitudinalPlanner，192 行）
- `selfdrive/controls/lib/longitudinal_mpc_lib/long_mpc.py`（LongitudinalMpc + Acados OCP，393 行）
- `selfdrive/controls/lib/longcontrol.py`（LongControl + 状态机，88 行）
- `selfdrive/controls/lib/drive_helpers.py`（get_accel_from_plan、clip_curvature）
- `selfdrive/controls/radard.py`（Track/KF1D/get_lead 融合，286 行）
- `selfdrive/car/cruise.py`（VCruiseHelper，138 行）
- GitHub: https://github.com/commaai/openpilot
- CSDN 解析：纵向规划器 LongitudinalPlanner、控制守护进程 controlsd、从图像到油门/刹车、紧急制动安全边界、福特Q3纵向优化
- Apollo: lon_based_pid_controller / Control 模块源码解析

---

> 本报告基于对 openpilot master 分支源码（longitudinal_planner.py / long_mpc.py / longcontrol.py / radard.py / cruise.py / drive_helpers.py）的逐行研读，结合 CSDN/51CTO 多篇解析与 Apollo 控制模块资料对比整理而成。所有代码片段均来自真实源码，参数值为源码常量。
>
> 实际工具调用次数：约 54 次（WebSearch 26 次 + WebFetch 18 次 + Read 持久化输出 10 次）。
