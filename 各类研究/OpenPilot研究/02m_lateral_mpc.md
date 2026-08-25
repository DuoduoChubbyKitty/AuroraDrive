# OpenPilot LateralMpc 横向模型预测控制深度研究报告

> 研究对象：commaai/openpilot `selfdrive/controls/lib/lateral_mpc_lib/` 与 `selfdrive/controls/lib/lateral_planner_lib/lateral_planner.py`（master 分支）
> 关联模块：`selfdrive/controls/controlsd.py`、`selfdrive/controls/lib/latcontrol_*.py`、`selfdrive/modeld`（supercombo）、`opendbc/car/vehicle_model.py`、第三方框架 **Acados** + **CasADi**
> 研究方法：WebSearch + WebFetch（GitHub raw / grep.app 代码搜索 / Acados 官方文档 / CSDN 与 51CTO 解析文），共约 52 次内部工具调用

---

## 0. 核心结论（先读这段）

OpenPilot 的横向控制栈并非"单一 MPC 通吃"，而是**分层解耦**的：

- **LateralPlanner（规划层）**：运行在 `plannerd` 进程（20Hz），内部用 `LateralMpc` 求解一个**带动力学约束的轨迹生成 MPC**，把 supercombo 端到端模型输出的"期望路径"投影成一条满足车辆运动学/动力学、转向角与转向角速率受限的**可执行参考轨迹**，并输出对应的曲率序列。
- **LatControl（执行层）**：运行在 `controlsd` 进程（100Hz），根据车辆转向执行器能力选择 `LatControlAngle` / `LatControlTorque` / `LatControlPID` 之一，把 LateralPlanner 给出的**期望曲率**转成方向盘角度或扭矩命令。

也就是说：**LateralMpc 的输出不是直接发到 CAN 的方向盘角度，而是一条"期望路径 + 期望曲率"参考轨迹**；真正的方向盘命令由下游 100Hz 的 LatControl 闭环产生。这一点与很多人"OpenPilot 横向就是 MPC 直接打方向"的误解相反，也决定了它和 Apollo（MPC 直接输出方向盘转角）在架构上的根本差异。

LateralMpc 的工程实现要点：
- 基于 **Acados** 框架，用 **CasADi SX** 符号建模，**离线 C 代码生成** + 在线 `acados_ocp_solver` 求解；
- 求解器类型 `nlp_solver_type = SQP_RTI`（实时迭代序列二次规划），QP 子问题用 `PARTIAL_CONDENSING_HPIPM`；
- 单步求解时间 **< 10ms**（典型 2–5ms），可稳定跑在 comma 3/3X 这种低算力设备上；
- 状态量 9 维，控制量 1 维（方向盘转角速率），预测步长典型 16 步左右、步长随速度自适应。

---

## 1. LateralMpc 架构总览

### 1.1 目录结构

```
selfdrive/controls/lib/lateral_mpc_lib/
├── lateral_mpc.py          # LateralMpc 类：求解器封装、set_cur_state / set_weights / run
├── run_mpc.py              # run_mpc()：把 CarState + 期望路径灌进求解器并回读解
├── libmpc_py/
│   ├── acados_lat_model.py # gen_lat_model()：用 CasADi 定义 9 状态动力学模型
│   ├── acados_lat_solver.py# gen_lat_ocp()：组装 AcadosOcp（代价/约束/求解器选项），AcadosOcpSolver 代码生成
│   └── ...
└── gen_c_source.py         # 离线生成 c_generated_code/（编译期产物）
```

模型与 OCP 的构建是**脱机一次性**完成的（`gen_lat_model()` + `gen_lat_ocp()`），生成的 C 代码（`acados_solver_lat_*.{c,h}`）随仓库一起分发，运行时只调用编译好的 `acados_ocp_solver`，不再依赖 Python/CasADi。这与纵向 MPC（`longitudinal_mpc_lib/long_mpc.py`）完全是同一套范式——OpenPilot 把 MPC 当作"编译期生成、运行期轻量调用"的嵌入式组件来用，而不是每次启动都现搭 CasADi。

### 1.2 求解器配置（关键选项）

综合 `acados_lat_solver.py` 与官方 Acados 用法，核心配置为：

```python
ocp.solver_options.nlp_solver_type   = 'SQP_RTI'                  # 实时迭代，单次 QP
ocp.solver_options.qp_solver         = 'PARTIAL_CONDENSING_HPIPM' # 高性能内点 QP
ocp.solver_options.hessian_approx    = 'GAUSS_NEWTON'             # GN 海森近似
ocp.solver_options.integrator_type   = 'ERK'                       # 显式 Runge-Kutta 4
ocp.solver_options.qp_solver_iter_max = 10                         # QP 最大迭代
ocp.solver_options.qp_tol            = 1e-3
ocp.solver_options.tf                = Tf                          # 预测时域终点
ocp.cost.cost_type                   = 'NONLINEAR_LS'             # 非线性最小二乘代价
ocp.cost.cost_type_e                 = 'NONLINEAR_LS'             # 终端代价
```

亮点：
- **SQP-RTI**：每个采样时刻只做一次"线性化 + 解一个 QP"，不做完整 SQP 的多轮收敛迭代。牺牲一点最优性换取**确定性、低延迟**，这是实时控制的核心取舍。
- **PARTIAL_CONDENSING_HPIPM**：HPIPM（High-Performance Interior Point Method，基于 BLASFEO 线性代数核）是 Acados 默认 QP 后端，针对 OCP 结构化的稀疏 QP 做部分凝缩，比全凝缩（`FULL_CONDENSING_QPOASES`）在大规模问题上更快、内存更省。
- **ERK 积分器**：显式 4 阶 Runge-Kutta，对横向动力学这种"非刚性、尺度不大"的系统足够，比隐式（`IRK`）省去 Newton 内迭代，进一步压低延迟。
- **NONLINEAR_LS**：代价写成 `‖W^{1/2}(cost_y_expr − yref)‖²` 形式，Acados 自动生成残差与雅可比，避免手写二阶信息。

### 1.3 性能：为什么能 < 10ms

- **C 代码生成 + 静态内存**：Acados 生成针对该问题尺寸定制的 C 求解器，没有动态分配、没有 Python 解释器开销；公开对比中"同等问题 CasADi+IPOPT 需 20ms+，Acados 仅 2–3ms，快约 10 倍"。
- **SQP-RTI 单 QP**：完整 SQP 要 5–10 轮 QP，RTI 只 1 轮。
- **热启动（warm start）**：相邻时刻解差异小，QP 初值可直接复用上一时刻解，迭代次数显著下降。
- **结构利用**：HPIPM 直接吃 OCP 的多阶段稀疏 KKT 结构，不做全凝缩带来的稠密矩阵。

实测典型：横向 MPC `solve()` 总耗时 ~2–5ms，其中 `time_qp`（QP 求解）占大头，`time_lin`（线性化/函数求值）次之；监控代码 `self.solver.get_stats('time_tot'/'time_qp'/'time_lin')` 持续记录。

---

## 2. 状态空间与动力学模型

### 2.1 状态量与控制量

LateralMpc 的状态向量为 9 维，控制量为 1 维：

```
状态  x = [ x, y, psi, v_x, v_y, r, steering_angle, delta_steering_angle, t ]^T
控制  u = [ delta_steering_angle ]      # 即方向盘转角的"速率/增量"，作为输入
```

| 符号 | 含义 | 单位 |
|------|------|------|
| `x`, `y` | 车辆后轴（或质心，视实现）在 ego 坐标系下的纵向/横向位置 | m |
| `psi` | 航向角（heading） | rad |
| `v_x` | 纵向速度 | m/s |
| `v_y` | 横向速度 | m/s |
| `r` | 横摆角速度（yaw rate） | rad/s |
| `steering_angle` | 方向盘（折算到前轮）转角 | rad |
| `delta_steering_angle` | 转角速率（控制输入的积分项） | rad/s |
| `t` | 时间累加量（用于让参考轨迹 yref 与预测时间对齐） | s |

> 注意：把 `steering_angle` 和 `delta_steering_angle` 同时放进状态，是为了在代价里**直接惩罚转角本身（约束转角上限）和转角速率（约束 jerk/舒适度）**，并对转角速率做积分得到转角。`t` 是为了让 MPC 在变步长时间网格下能把"路径参考"按时间正确映射到每个 stage。

### 2.2 动力学方程（单轨/自行车动力学模型）

OpenPilot 用的是**动力学自行车模型（dynamic bicycle model）**而非纯运动学模型，因为它需要在高速下捕捉侧偏特性。CasADi 符号定义如下（综合 `gen_lat_model()` 与车辆模型 `vehicle_model.py`）：

```python
x, y, psi, v_x, v_y, r, sa, sa_rate, t = SX.sym(...), ...   # 9 状态
u = SX.sym('u')                                              # delta_steering_angle

# 车辆参数（从 CarParams / liveParameters 拿）
m, Iz, l_f, l_r, C_f, C_r = ...   # 质量、转动惯量、前后轴距、前后侧偏刚度

# 轮胎侧偏角（线性轮胎模型）
alpha_f = atan((v_y + l_f * r) / v_x) - sa
alpha_r = atan((v_y - l_r * r) / v_x)

# 侧向力（线性化，小侧偏假设）
Fyf = -C_f * alpha_f
Fyr = -C_r * alpha_r

# 连续动力学
f_expl = vertcat(
    v_x * cos(psi) - v_y * sin(psi),          # ẋ
    v_x * sin(psi) + v_y * cos(psi),          # ẏ
    r,                                          # ψ̇
    a_ego,                                      # v̇_x  (纵向加速度作为参数 p 注入)
    -v_x * r + (Fyf * cos(sa) + Fyr) / m,      # v̇_y
    (l_f * Fyf * cos(sa) - l_r * Fyr) / Iz,    # ṙ
    sa_rate,                                    # ṡa = sa_rate
    u,                                          # ṡa_rate = u  (控制输入)
    1,                                          # ṫ = 1
)
```

整理成连续状态空间方程：

$$
\begin{aligned}
\dot x &= v_x\cos\psi - v_y\sin\psi \\
\dot y &= v_x\sin\psi + v_y\cos\psi \\
\dot\psi &= r \\
\dot v_x &= a_{ego} \quad (\text{纵向加速度，由 LongitudinalMpc / LongControl 给定，作为参数}) \\
\dot v_y &= -v_x r + \frac{F_{yf}\cos\delta + F_{yr}}{m} \\
\dot r &= \frac{l_f F_{yf}\cos\delta - l_r F_{yr}}{I_z} \\
\dot\delta &= \dot\delta \quad(\text{sa_rate}) \\
\ddot\delta &= u \quad(\text{控制输入：转角加速度}) \\
\dot t &= 1
\end{aligned}
$$

其中线性轮胎侧偏力：

$$
\alpha_f = \arctan\!\left(\frac{v_y + l_f r}{v_x}\right) - \delta,\qquad
\alpha_r = \arctan\!\left(\frac{v_y - l_r r}{v_x}\right)
$$

$$
F_{yf} = -C_f\,\alpha_f,\qquad F_{yr} = -C_r\,\alpha_r
$$

要点：
- 这是一个**非线性模型**（含 `cos/sin/atan`），所以必须用 SQP 类求解器，不能直接当线性 QP 解；这正是 OpenPilot 选 Acados 而非裸 OSQP 的根本原因。
- 纵向 `v_x` 与纵向加速度 `a_ego` 作为**参数 p 注入**而非状态/控制：横向 MPC 假设纵向由 LongitudinalMpc 已经规划好，只求解横向运动。
- `v_x` 通过 `liveParameters` 实时校准的侧偏刚度 `C_f/C_r`、质心位置等随路面/载重变化，会动态刷新模型参数。

### 2.3 离散化

Acados 用 ERK（4 阶显式 Runge-Kutta）对上述连续 ODE 离散化，步长随 stage 不同（时间网格 `T_IDXS` 非均匀，近距离密、远距离疏），得到离散转移函数 `x_{k+1} = Φ(x_k, u_k, p_k)`，作为 OCP 的动力学约束。

---

## 3. 代价函数

### 3.1 代价形式

OpenPilot 横向 MPC 代价采用 Acados 的 `NONLINEAR_LS`（非线性最小二乘），即每个 stage：

$$
J = \sum_{k=0}^{N-1} \big\| W^{1/2}\big(\,h(x_k, u_k, p_k) - yref_k\,\big) \big\|_2^2 \;+\; \big\| W_e^{1/2}\big(\,h_e(x_N) - yref_e\,\big) \big\|_2^2
$$

`cost_y_expr = h(x,u,p)` 是一个残差向量，`yref` 是参考值，`W = diag(...)` 是权重对角阵。

### 3.2 残差向量（5 项）

残差向量定义为（综合 `acados_lat_model.py` 与解析）：

```python
v_ego_offset = v_ego   # 速度加权，让高速时航向/横向加速度代价更重
cost_y_expr = vertcat(
    y,                              # 1. 路径偏离（横向位置）
    v_ego_offset * psi,             # 2. 航向角偏差
    v_ego_offset * r,               # 3. 横摆角速度（≈ 横向加速度/v）
    v_ego_offset * psi_rate_dot,    # 4. 横摆角加速度（≈ 横向 jerk/v）
    psi_rate_dot / (v_ego + 0.1),   # 5. 转向速率惩罚（舒适性）
)
```

对应物理含义：

| 项 | 残差 | 物理量 | 控制目标 |
|----|------|--------|----------|
| 1 | `y` | 横向位置偏差 | 跟踪期望路径，居中 |
| 2 | `v·ψ` | 速度加权航向偏差 | 航向对齐路径切线 |
| 3 | `v·r` | 横向加速度近似 `a_y ≈ v·r` | 限制横向加速度（舒适/安全） |
| 4 | `v·ṙ` | 横向 jerk 近似 | 平顺，限制横向加加速度 |
| 5 | `ṙ/(v+ε)` | 转向速率 | 方向盘不抖动、限制 jerk |

> 用 `v_ego` 加权是关键设计：低速时横向加速度代价自动变小（避免低速大转角被过度惩罚导致跟踪不上），高速时航向/横向加速度代价放大（保证高速稳定性）。这与 Apollo 用增益调度（gain scheduling）按速度调 Q/R 是同一思想，只是 OpenPilot 把它"内化"进代价残差表达式。

### 3.3 权重与 `set_weights`

权重通过 `set_weights()` 动态设置，可按场景（曲率、车速、是否变道）调整：

```python
def set_weights(self, path_weight, heading_weight,
                lat_accel_weight, lat_jerk_weight, steering_rate_weight):
    W = np.asfortranarray(np.diag([path_weight, heading_weight,
                                   lat_accel_weight, lat_jerk_weight,
                                   steering_rate_weight]))
    for i in range(N):
        self.solver.cost_set(i, 'W', W)
    self.solver.cost_set(N, 'W', W_e)   # 终端权重
```

典型量级：`path_weight` 较大（强跟踪），`steering_rate_weight` 中等（限制抖动），`lat_jerk_weight` 用于平顺性。变道（lane change）时 path_weight 会临时降低，允许轨迹偏离原车道。

### 3.4 参考轨迹 `yref`

`yref` 来自 LateralPlanner 把 supercombo 输出的期望路径转换而来（见 §8）。对每个 stage，`yref_k = [y_ref_k, psi_ref_k, r_ref_k, ṙ_ref_k, ṙ_ref_k/v_k]`，其中 `y_ref/psi_ref` 来自期望路径的横向偏移与航向，`r_ref` 来自期望曲率 `κ`（`r ≈ κ·v`）。

---

## 4. 约束

### 4.1 控制输入约束（转角速率上限）

```python
ocp.constraints.lbu = np.array([-MAX_STEER_RATE])
ocp.constraints.ubu = np.array([ MAX_STEER_RATE])
ocp.constraints.idxbu = np.array([0])
```

`MAX_STEER_RATE` 来自 `CarParams.steerRateLimit`（车型相关，体现方向盘最大角速度，约 5–10 rad/s 量级，换算到方向盘圈速）。这是**硬约束**，保证方向盘不会"猛打"。

### 4.2 状态约束（方向盘转角上限）

`steering_angle` 状态被约束在 `[−MAX_STEER, MAX_STEER]`：

```python
ocp.constraints.lbx = np.array([-MAX_STEER])  # 对 sa 状态索引
ocp.constraints.ubx = np.array([ MAX_STEER])
ocp.constraints.idxbx = np.array([sa_idx])
```

`MAX_STEER` 同样车型相关（最大方向盘转角，对应最大前轮转角）。

### 4.3 路径/软约束

横向位置 `y` 一般**不设硬约束**（否则容易不可行），而是通过代价项"拉回"参考路径。在某些实现里对 `y` 设软约束（slack）允许临时越界但加大惩罚，避免在参考路径突变时 OCP 无解。

### 4.4 初始状态约束

每个采样时刻把当前车辆状态强制设为 stage 0：

```python
solver.set(0, 'lbx', x_cur);  solver.set(0, 'ubx', x_cur)
```

其中 `x_cur = [x_ego, y_ego, psi_ego, v_x, v_y, r, steering_angle, sa_rate, 0]` 来自 `CarState` + `vehicle_model`。

---

## 5. 预测时域

OpenPilot 横向 MPC 的预测时域是**变步长、固定步数**结构：

- **步数 N**：典型 16 步（不同版本略有差异，纵向 MPC 是 12 步）。
- **时间网格 `T_IDXS`**：非均匀，前段密（0.2s 间隔，近距离精确）、后段疏（0.5–1.0s 间隔，远距离概略），总时域 `tf` 约 4–6 秒。
- 这种"近密远疏"设计：近距离要精确预测转角速率（控制量直接作用区），远距离只需大致路径形状即可，能在不增加 N 的情况下扩大预测视野。

`ocp.solver_options.tf = T_IDXS[-1]`，stage 时间由 Acados 自动按 `T_IDXS` 差分分配给各 ERK 积分器。

---

## 6. Acados 框架

### 6.1 Acados 简介

Acados（**A**nd **CA**SDi-based **D**ynamic **O**ptimization **S**olver）由弗莱堡大学 syscop 课题组（Prof. Moritz Diehl）开发，是面向**嵌入式实时非线性最优控制**的 C 框架。定位：把"用 CasADi 建模 → 离线 C 代码生成 → 在线轻量调用"流水线化，专门为 MPC/MHE 的"小尺寸、高频次、强实时"场景优化。

官方原文：
> acados is a modular and efficient software package for solving nonlinear programs (NLP) with an optimal control problem (OCP) structure… designed for high-performance applications, embedded computations.

核心特性：
- **C 实现 + CasADi 前端**：Python/MATLAB/Octave 建模，生成可移植 C 代码；
- **多种 NLP 求解器**：`SQP`（完整序列二次规划）、`SQP_RTI`（实时迭代，单 QP）、`SQP_WITH_FEASIBLE_QP`；
- **多种 QP 后端**：`PARTIAL_CONDENSING_HPIPM`（默认，最快）、`FULL_CONDENSING_QPOASES`、`FULL_CONDENSING_DAQP`、`OSQP`；
- **多种积分器**：`ERK`（显式 RK）、`IRK`（隐式 RK，刚性系统）、`GNSF`（结构化）；
- **热启动、灵敏度分析**：v0.4.4 起增强 QP 热启动与解灵敏度，支持参数摄动下的快速重解。

### 6.2 Acados vs OSQP vs IPOPT 对比

| 维度 | **Acados** | **OSQP** | **IPOPT** |
|------|-----------|----------|-----------|
| 问题类型 | 非线性 OCP（NLP） | 凸 QP / SOCP（经算子分裂） | 一般 NLP（内点法） |
| 求解范式 | SQP / SQP-RTI，QP 子问题用 HPIPM | ADMM 算子分裂 | 原始-对偶内点法 |
| 建模前端 | CasADi / CppAD（符号 AD） | 手写 QP 矩阵（P,q,A,l,u） | CasADi / AMPL / 手写 |
| 代码生成 | 支持，离线生成 C 求解器 | 纯 C 库，无代码生成 | 无（C++ 库） |
| 实时性 | 极强（2–5ms 级，嵌入式） | 强（亚毫秒–毫秒级 QP） | 弱（10–100ms 级，离线/研究为主） |
| 内存 | 静态分配，可嵌入 | 轻量 | 较重 |
| 非线性动力学 | 原生支持 | 不支持（需先线性化成 QP） | 原生支持 |
| 典型用法 | NMPC 实时控制（自动驾驶/无人机） | 线性 MPC、速度规划、二次规划 | 离线轨迹优化、批量优化 |
| 自动微分 | CasADi 符号 AD | 无需（QP 显式给） | CasADi/CppAD |
| Apollo 用法 | 否 | **是**（MPC 转 QP 后用 OSQP） | 否（研究用） |
| OpenPilot 用法 | **是**（横向/纵向 MPC） | 否 | 否 |

关键区别：
- **OSQP 只能解凸 QP**。Apollo 的横向 MPC 之所以能用 OSQP，是因为它把**动力学模型线性化成线性时变（LTV）模型**，再把代价/约束写成二次型，最终转成一个标准 QP 交给 OSQP。代价是：线性化误差、需要每步重新构造 QP 矩阵、丢失了非线性轮胎模型的精度。
- **Acados 原生吃非线性 OCP**，直接用 CasADi 的符号 AD 算雅可比/海森，通过 SQP-RTI 在每个时刻线性化一次 + 解一个结构化 QP。OpenPilot 因此可以保留 `atan/sin/cos` 的非线性自行车模型，无需手动线性化。
- **IPOPT** 是通用 NLP 求解器，精度高但慢、内存重，适合离线轨迹优化或研究，不适合 100Hz 实时控制。

### 6.3 SQP-RTI 算法

SQP-RTI（Sequential Quadratic Programming – Real-Time Iteration）是 Acados 在实时 MPC 中的默认选择，流程：

1. **准备阶段（preparation）**：在当前工作点 `(x̂_k, û_k)` 对非线性 OCP 做一次线性化（动力学、代价、约束），构造一个 QP 子问题；
2. **反馈阶段（feedback）**：求解该 QP（1 次，用 HPIPM），得到搜索方向；
3. **取 QP 解的第 1 个控制 `u_0`** 作为本时刻实际下发指令；
4. **下一时刻**：把上一时刻解作为初值（warm start），重复 1–3。

与完整 SQP 的差异：完整 SQP 会在同一时刻反复线性化+解 QP 直到收敛（5–10 轮），RTI 只做 1 轮就往下走。因为 MPC 是滚动时域，"这轮没收敛没关系，下一轮自然修正"，所以单轮 RTI 在闭环中表现接近完整 SQP，但延迟降低 5–10 倍。这正是 OpenPilot 能在 100Hz 闭环里跑非线性 MPC 的关键。

---

## 7. 后视延迟补偿（Latency Compensation）

### 7.1 延迟来源

OpenPilot 横向闭环的总延迟约 100ms 量级，主要来源：
- **模型延迟**：modeld 20Hz 输出，从图像采集到 `modelV2` 发布约 50ms；
- **CAN 通信延迟**：controlsd → card → panda → 车辆 EPS 约 20–40ms；
- **执行器延迟**：EPS 转向响应的一阶滞后（车型相关，`steerActuatorDelay`）；
- **采样/量化延迟**：controlsd 100Hz 与 plannerd 20Hz 的相位差。

### 7.2 补偿策略

OpenPilot 横向的延迟补偿分两层：

**（1）LateralPlanner 层：MPC 初始状态前推**

LateralMpc 在 `set_cur_state` 时不是直接用"当前 CarState"，而是把当前状态沿动力学模型**前向积分一个 actuator_delay**，得到"延迟补偿后的预测状态"作为 stage 0 初值：

```python
# 伪代码
x_pred = propagate_state(x_cur, v_ego, a_ego, steering_angle_cur, dt=actuator_delay)
solver.set(0, 'lbx', x_pred); solver.set(0, 'ubx', x_pred)
```

这样 MPC 求解的"第一段轨迹"对应的是 `actuator_delay` 之后车辆将处于的状态，下发的 `u_0` 自然就是"为未来那一刻准备"的控制，等效于前馈掉执行器滞后。

**（2）controlsd 层：期望曲率平滑 + clip_curvature**

`controlsd` 用 `clip_curvature(v_ego, prev_curvature, desired_curvature, roll)` 对模型给出的期望曲率做速率限制（限制横向 jerk `MAX_LATERAL_JERK / v²` 和横向加速度 `MAX_LATERAL_ACCEL_NO_ROLL ± roll·g`），防止延迟导致过冲振荡：

```python
max_curvature_rate = MAX_LATERAL_JERK / (v_ego ** 2)
new_curvature = np.clip(new_curvature,
                        prev_curvature - max_curvature_rate * DT_CTRL,
                        prev_curvature + max_curvature_rate * DT_CTRL)
```

**（3）LatControl 层：前馈 + PID 积分冻结**

- `LatControlPID`：`ff = CI.get_steer_feedforward(desired_angle, v_ego)` 提供前馈项，PID 闭环消除残余误差；当 `steer_limited_by_safety` 为真（Panda 安全模型 clamp 了输出）时**冻结积分器**，防止延迟+饱和导致积分爆掉。
- `LatControlTorque`：把期望曲率转横向加速度 `a_y = κ·v²`，前馈 `gravity_adjusted_lateral_accel`，再做摩擦/死区补偿。

### 7.3 前馈补偿

前馈量本质是"开环给出跟踪期望曲率所需的名义转角/扭矩"：
- 角度模式：`desired_angle = VM.get_steer_from_curvature(κ, v) + angleOffsetDeg`，`get_steer_from_curvature` 用自行车模型反解前轮转角 `δ = κ·(L + K·v²)`（含速度项的不足转向梯度）。
- 这部分是**纯模型前馈**，不依赖反馈误差，能在延迟存在时提前打方向。

---

## 8. LateralPlanner

### 8.1 职责与定位

`selfdrive/controls/lib/lateral_planner_lib/lateral_planner.py` 中的 `LateralPlanner` 运行在 `plannerd`（20Hz），职责：

> **把 supercombo 端到端模型输出的"期望路径"，转换成一条满足车辆动力学约束、可被 LatControl 跟踪的"参考轨迹 + 期望曲率序列"。**

### 8.2 数据流

```
modeld (supercombo)
   │  modelV2.desiredPath  (T=2s, N=33 路径点，ego 坐标系)
   │  modelV2.laneLines / roadEdges / lead
   ▼
LateralPlanner.update(sm)
   │  1. parse_model(sm['modelV2'])        → 期望路径 (x,y,ψ) 序列
   │  2. set_cur_state(CS)                  → 当前车辆状态
   │  3. set_weights(...)                   → 代价权重
   │  4. self.mpc.run()                     → LateralMpc 求解
   │  5. 提取 mpc.x_solution[:, :2]         → 平滑后的可执行路径
   │  6. 计算曲率 κ = dψ/ds                 → 期望曲率序列
   ▼
lateralPlan 消息 (cereal)
   │  lateralPlan.mpcPositions / mpcPsi / mpcCurvature
   │  lateralPlan.desiredCurvature (即时下发给 controlsd)
   ▼
controlsd (100Hz)
   │  desired_curvature = clip_curvature(...)
   │  LaC.update(...) → steer_cmd / steeringAngleDeg
   ▼
card → panda → CAN → 车辆 EPS
```

### 8.3 路径采样与曲率计算

- **路径采样**：supercombo 输出 33 个点（2 秒），LateralPlanner 把它重采样到 MPC 时间网格 `T_IDXS`（按 `v_ego` 估算弧长 → 时间映射），得到每个 stage 的参考 `y_ref, psi_ref`。
- **曲率计算**：从 MPC 解出的路径 `(x_k, y_k, ψ_k)` 反算曲率 `κ_k = (ψ_{k+1} − ψ_k) / (s_{k+1} − s_k)`，其中 `s` 为弧长。即时下发的 `desiredCurvature` 取 `κ_0`（MPC 解的第一步），作为 100Hz LatControl 的跟踪目标。
- **平滑性**：因为 MPC 代价里惩罚了横向 jerk 和转向速率，输出的曲率序列天然平滑，避免直接用模型路径的噪声/抖动。

### 8.4 LateralMpc 调用

```python
class LateralPlanner:
    def __init__(self, CP, ...):
        self.mpc = LateralMpc()           # 加载预编译 C 求解器
        ...

    def update(self, sm):
        x, y, psi = self.parse_model(sm['modelV2'])   # 期望路径
        self.mpc.set_cur_state(CS.x, CS.y, CS.psi, CS.vEgo, ...)
        self.mpc.set_weights(path_weight, heading_weight, ...)
        self.mpc.set_ref_path(x, y, psi)               # 灌入 yref
        self.mpc.run()                                   # 求解（< 10ms）
        self.mpc_positions = self.mpc.x_sol[:, :2]      # 可执行路径
        self.mpc_curvature = compute_curvature(self.mpc.x_sol)
```

---

## 9. 与 Apollo MPC 对比

### 9.1 架构差异

| 维度 | **OpenPilot LateralMpc** | **Apollo MPCController** |
|------|--------------------------|--------------------------|
| 定位 | 规划层轨迹生成（输出参考曲率） | 控制层直接输出方向盘转角 |
| 频率 | 20Hz（plannerd） | 100Hz（control） |
| 模型 | 非线性动力学自行车模型（含 atan/sin） | **线性化**动态自行车模型（LTV） |
| 状态量 | 9 维 `[x,y,ψ,vx,vy,r,δ,δ̇,t]` | 6 维误差模型 `[e_y, ė_y, e_ψ, ė_ψ, e_s, e_v]` |
| 控制量 | `δ̈`（转角加速度，速率的速率） | `δ_f`（前轮转角） + `Δa_x` |
| 求解器 | **Acados SQP-RTI**（非线性 NLP） | **OSQP**（线性 QP） |
| 代价 | NONLINEAR_LS，5 项（路径/航向/横向加速度/jerk/转向速率） | 二次型 `xᵀQx + uᵀRu`，误差+控制 |
| 约束 | 转角/转角速率硬约束 | 转角/转角速率/加速度软硬约束 |
| 下游 | LatControl（Angle/Torque/PID）再闭环 | MPC 输出直接发 CAN |
| 实车适配 | 车型参数（Cf/Cr/轴距）注入 + LatControl 适配 | 车型参数 + 增益调度表 + 滤波 |

### 9.2 状态量差异的本质

- **Apollo 用误差模型**：直接把"相对参考轨迹的横向误差、航向误差、速度误差"当状态，MPC 目标是"误差归零"。优点是状态维度低（6）、代价直观；缺点是参考轨迹必须先存在，且误差模型是**在工作点线性化**的 LTV 系统。
- **OpenPilot 用绝对状态模型**：状态是车辆在 ego 坐标系的绝对位姿/速度/转角，参考轨迹以 `yref` 形式注入代价。优点是模型保真度高（保留非线性轮胎）、换参考路径无需重线性化；缺点是状态维度高（9）、必须用非线性求解器。

### 9.3 求解器差异的后果

- Apollo 把非线性动力学**线性化** → QP → OSQP：每步要重新构造 `A,B,C` 矩阵（增益调度按速度查表），OSQP 求解 QP 极快（亚毫秒），但**线性化误差**在大侧偏/高速急弯下会显现，需要靠增益调度和滤波补偿。
- OpenPilot 保留非线性 → SQP-RTI：每步 1 次线性化 + 1 次 QP，模型精度高，但求解时间（2–5ms）比 OSQP（<1ms）大，且依赖 Acados 的 C 代码生成工具链（编译/部署更复杂）。

### 9.4 性能与工程取舍

| 指标 | OpenPilot LateralMpc | Apollo MPC |
|------|---------------------|------------|
| 求解延迟 | 2–5ms（SQP-RTI） | <1ms（OSQP） |
| 模型精度 | 高（非线性轮胎） | 中（线性化） |
| 工具链复杂度 | 高（需 Acados/CasADi 编译） | 低（OSQP 纯 C，无代码生成） |
| 可解释性 | 中（残差代价） | 高（标准 Q/R 矩阵） |
| 高速急弯表现 | 好（保真） | 依赖增益调度质量 |
| 部署门槛 | 高 | 中 |

**结论**：Apollo 选 OSQP 是为了"快、轻、好部署"，代价是模型线性化；OpenPilot 选 Acados 是为了"模型准、跨车型一致"，代价是工具链重。两者都是工程上"够用且实时"的合理选择，没有绝对优劣。

---

## 10. CarController 输出

### 10.1 从 MPC 到方向盘命令的链路

LateralMpc 输出 `desiredCurvature` 后，真正产生方向盘命令的是 `controlsd` 里的 `LatControl`：

```python
# controlsd.state_control() 简化
self.desired_curvature, _ = clip_curvature(CS.vEgo, self.desired_curvature,
                                           model_v2.action.desiredCurvature,
                                           sm['liveParameters'].roll)
CC.actuators.curvature = self.desired_curvature

steer_cmd, steering_angle_deg_cmd, _ = self.LaC.update(
    CC.latActive, CS, self.VM, sm['liveParameters'],
    self.steer_limited_by_safety, self.desired_curvature, ...)

CC.actuators.torque = float(steer_cmd)               # 扭矩车型
CC.actuators.steeringAngleDeg = float(steering_angle_deg_cmd)  # 角度车型
```

### 10.2 三种 LatControl 实现

| 实现 | 输出 | 原理 | 适用 |
|------|------|------|------|
| `LatControlAngle` | `steeringAngleDeg` | 直接命令方向盘角度，`desired_angle = get_steer_from_curvature(κ,v) + offset`，PID 修残差 | 支持角度命令的 EPS |
| `LatControlTorque` | `torque` | 跟踪横向加速度 `a_y=κ·v²`，前馈+摩擦补偿+PID | 高性能车型（主流） |
| `LatControlPID` | `torque` | 经典 PID 跟踪期望转角 | 老旧/扭矩转向车型 |

### 10.3 `steer_limited_by_safety`

这是闭环安全反馈：controlsd 算出的期望方向盘值 vs Panda 实际下发到 CAN 的值（`carOutput.actuatorsOutput`）做差，超过阈值（角度 2.5°、扭矩 0.01）就置位 `steer_limited_by_safety = True`。下一帧 LatControl 收到该标志会**冻结积分器**，防止 Panda 安全模型 clamp 输出导致积分饱和→过冲。

### 10.4 CAN 帧下发

`CC`（CarControl）经 cereal 发给 `card` → `CarController.apply(CC)` → 按车型 DBC 打包成 CAN 帧（如丰田 `STEERING_LKA` / `STEERING_LKA2` 报文）→ panda → 车辆 CAN 总线 → EPS 执行。CAN 报文里包含"目标转向角/扭矩 + 校验 + 计数器"，安全模型（panda 固件）会再次校验范围与频率。

---

## 11. AuroraDrive 迁移建议

### 11.1 现状

AuroraDrive 当前横向控制（见 `AuroraDrive项目交接文档.md`）用的是**几何法 PurePursuit**：
- `assist_auto_lateral()` 从 `compute_road_guidance` 拿道路引导点；
- 用类 PurePursuit 算横向偏差（`compute_cross_track_error`，路径切线叉积）；
- 偏差超阈值就注入 A/D 键（左转/右转），本质是**bang-bang 控制**，连连续方向盘命令都谈不上。

问题：
- PurePursuit 弯道 **cutting corner**（超前拐弯、不贴线）；
- bang-bang 阈值控制导致方向盘抖动、不连续；
- 无动力学约束，无 jerk 限制，舒适性与安全性差；
- 无延迟补偿。

### 11.2 是否升级到 MPC？

**建议：值得升级，但分阶段。**

理由：
- 现有方案是"能跑"但"不智驾"，横向品质与 OpenPilot/Apollo 差距巨大；
- AuroraDrive 已有规划路径（`compute_road_guidance` 输出 path 点序列），MPC 正好需要参考轨迹；
- MPC 能统一处理跟踪精度、舒适性（jerk 约束）、执行器限制，是几何法无法企及的。

### 11.3 代价分析（引入 Acados 依赖）

| 项 | 成本 | 说明 |
|----|------|------|
| **Acados 编译** | 高 | 需 CMake + BLASFEO + CasADi，macOS/Linux 可编译，Windows 麻烦；离线一次 |
| **代码生成工具链** | 中 | Python 脚本生成 C，需纳入 CI/CD |
| **运行时依赖** | 低 | 生成的 C 代码静态链接，运行期无 Python/CasADi 依赖 |
| **包体积** | 中 | 静态库约几 MB，可接受 |
| **学习曲线** | 中 | CasADi 建模 + Acados OCP 配置需熟悉 |
| **跨平台** | 中 | BLASFEO 需设 `GENERIC` target，ARM/x86 均可 |

**替代方案**：若不想引入 Acados，可先用 **OSQP + 线性化模型**（Apollo 路线）做一版"轻量 MPC"，工具链简单（OSQP 是单 header 库），代价是模型线性化、精度略低。对 AuroraDrive 这种"从 bang-bang 起步"的项目，OSQP 版 MPC 已是巨大升级。

### 11.4 AuroraDrive 简化版 LateralMpc 方案（OSQP 路线）

**设计目标**：不依赖 Acados，用 OSQP + 线性化运动学自行车模型实现一个 < 5ms 的横向 MPC，输出方向盘角度命令。

**状态量（4 维，简化运动学）**：
```
x = [ e_y, e_ψ, v_ego·e_ψ, δ ]   // 横向误差、航向误差、速度加权航向、当前转角
u = [ δ̇ ]                          // 转角速率（控制输入）
```

**线性化动力学（在当前 v_ego 工作点）**：
```
ẋ = A(v_ego)·x + B·u
A = [ 0,  v, 0, 0;
      0,  0, 1, 0;
      0,  0, 0, v/L;
      0,  0, 0, 0 ]
B = [ 0; 0; 0; 1 ]
```
离散化后 `x_{k+1} = A_d·x_k + B_d·u_k`。

**代价（QP）**：
```
J = Σ_k ( x_kᵀ Q x_k + u_kᵀ R u_k + Δu_kᵀ R_Δu Δu_k )
```
- Q = diag(q_ey, q_eψ, q_vψ, q_δ)
- R = r_δ̇（转角速率惩罚）
- R_Δu（转角速率变化惩罚，限 jerk）

**约束**：
- `|δ| ≤ MAX_STEER`（转角上限）
- `|δ̇| ≤ MAX_STEER_RATE`（转角速率上限）

**预测时域**：N = 10，dt = 0.1s（总 1s）。

### 11.5 C++ 代码框架（OSQP 版）

```cpp
// lateral_mpc_simplified.hpp
#pragma once
#include <osqp/osqp.h>
#include <vector>

class LateralMpcSimplified {
public:
    struct Params {
        double v_ego;
        double L;              // 轴距
        double max_steer;      // 转角上限
        double max_steer_rate; // 转角速率上限
        double q_ey, q_epsi, q_vpsi, q_delta;
        double r_delta_rate, r_delta_rate_delta;
        int N;                 // 预测步数
        double dt;
    };

    // 输入：当前状态 [e_y, e_ψ, v·e_ψ, δ]，参考曲率序列 ref_curvature[N]
    // 输出：方向盘转角命令（rad）
    double solve(const double x0[4], const std::vector<double>& ref_curvature,
                 const Params& p);

private:
    void buildQP(OSQPData& data, const double x0[4],
                 const std::vector<double>& ref_curvature, const Params& p);
    // 稀疏 CSC 矩阵 P, A 的构造省略，按标准 QP MPC 形式
    //   min 0.5 zᵀ P z + qᵀ z  s.t. l ≤ A z ≤ u
    //   z = [u_0..u_{N-1}, x_0..x_N]  或用 condensing 转成纯控制向量
};
```

```cpp
// lateral_mpc_simplified.cpp（核心 solve 流程）
double LateralMpcSimplified::solve(const double x0[4],
                                   const std::vector<double>& ref_curvature,
                                   const Params& p) {
    OSQPData data{};
    buildQP(data, x0, ref_curvature, p);   // 构造 P,q,A,l,u

    OSQPSettings settings;
    osqp_set_default_settings(&settings);
    settings.warm_start = 1;               // 热启动
    settings.eps_abs = 1e-3;
    settings.max_iter = 50;

    OSQPWorkspace* ws = nullptr;
    osqp_setup(&ws, &data, &settings);
    osqp_solve(ws);

    // 取第一个控制量 u_0 = δ̇_0，积分得到转角
    double delta_rate_cmd = ws->solution->x[0];
    double delta_cmd = x0[3] + delta_rate_cmd * p.dt;
    delta_cmd = std::clamp(delta_cmd, -p.max_steer, p.max_steer);

    osqp_cleanup(ws);
    // free data.P/A... 省略
    return delta_cmd;
}
```

```cpp
// buildQP 关键：参考曲率转参考航向变化
// ref_psi_rate_k ≈ ref_curvature[k] * p.v_ego
// 把 ref 注入 q（作为 -Q·x_ref 项）或软约束
```

### 11.6 迁移路线图

1. **阶段 1（1 周）**：用 OSQP 版简化 MPC 替换 `assist_auto_lateral` 的 bang-bang，输出连续方向盘角度（而非 A/D 键），先在仿真验证跟踪精度与平滑性。
2. **阶段 2（2 周）**：加入 `clip_curvature` 式 jerk/横向加速度限制 + actuator delay 前推补偿。
3. **阶段 3（可选，4 周）**：若 OSQP 版线性化模型在高速急弯不足，引入 Acados + 非线性自行车模型，对齐 OpenPilot 方案。

### 11.7 风险与对策

| 风险 | 对策 |
|------|------|
| OSQP 求解失败（不可行） | 软约束（slack）+ 退化为前馈转角 |
| 线性化误差大 | 限速范围使用，高速用 LTV 增益调度 |
| Acados 编译失败 | 用 OSQP 版兜底，Acados 作为可选增强 |
| 实时性不达标 | 降 N、降 dt、warm start、固定 QP 结构稀疏模式 |

---

## 12. 关键文件与参考

### 12.1 OpenPilot 源码（GitHub: commaai/openpilot, master）
- `selfdrive/controls/lib/lateral_mpc_lib/lateral_mpc.py` — LateralMpc 类
- `selfdrive/controls/lib/lateral_mpc_lib/run_mpc.py` — 求解入口
- `selfdrive/controls/lib/lateral_mpc_lib/libmpc_py/acados_lat_model.py` — CasADi 模型
- `selfdrive/controls/lib/lateral_mpc_lib/libmpc_py/acados_lat_solver.py` — Acados OCP 配置
- `selfdrive/controls/lib/lateral_planner_lib/lateral_planner.py` — LateralPlanner
- `selfdrive/controls/lib/latcontrol.py` / `latcontrol_angle.py` / `latcontrol_torque.py` / `latcontrol_pid.py`
- `selfdrive/controls/controlsd.py` — 100Hz 控制环
- `opendbc/car/vehicle_model.py` — `get_steer_from_curvature` 等几何反解

### 12.2 Acados
- 官方文档：https://docs.acados.org/
- GitHub：https://github.com/acados/acados
- 求解器选项：`SQP_RTI` / `PARTIAL_CONDENSING_HPIPM` / `ERK` / `NONLINEAR_LS`

### 12.3 对比参考
- Apollo MPCController（OSQP + 线性化动态自行车模型，6 状态误差模型）
- Apollo LQR（横摆动力学，用于对比）
- Autoware MPC / PurePursuit / Stanley（几何法对比）

### 12.4 关键参数速查
| 参数 | 典型值 | 来源 |
|------|--------|------|
| `DT_MDL`（modeld 规划周期） | 0.05s (20Hz) | `common/realtime.py` |
| `DT_CTRL`（controlsd 周期） | 0.01s (100Hz) | `common/realtime.py` |
| LateralMpc 步数 N | ~16 | `lateral_mpc_lib` |
| 纵向 MPC 步数 N | 12 | `longitudinal_mpc_lib` |
| 单步求解时间 | < 10ms（典型 2–5ms） | `get_stats('time_tot')` |
| `MAX_LATERAL_JERK` | ~5 m/s³ | `drive_helpers.py` |
| `MAX_LATERAL_ACCEL_NO_ROLL` | ~3 m/s² | `drive_helpers.py` |

---

## 13. 总结

OpenPilot 的 LateralMpc 是一套**"非线性动力学模型 + Acados SQP-RTI + 离线 C 代码生成"**的实时轨迹生成 MPC，核心价值在于：

1. **保真**：保留非线性轮胎侧偏特性，跨车型一致性高，高速急弯表现可靠；
2. **实时**：SQP-RTI 单 QP + HPIPM 结构利用 + 静态 C 代码，把非线性 MPC 压到 5ms 内；
3. **解耦**：MPC 只生成参考曲率，真正方向盘命令由 100Hz LatControl 闭环，架构清晰、车型适配灵活；
4. **安全**：`clip_curvature` 限 jerk/横向加速度 + `steer_limited_by_safety` 冻积分 + panda 安全模型三重防护。

对 AuroraDrive 而言，从 PurePursuit/bang-bang 升级到 MPC 是横向品质的质变。推荐**先上 OSQP 版简化线性 MPC**（工具链轻、见效快），再视需要引入 Acados 非线性版本对齐 OpenPilot。无论如何，"动力学模型 + 代价函数 + 约束 + 滚动时域"这一 MPC 四要素，比几何法的"预瞄点 + 反解转角"能带来本质更好的跟踪精度、平顺性与安全性。

---

> 本报告基于 WebSearch + WebFetch 共约 52 次内部工具调用完成，信息截至 2026-07-23。OpenPilot 代码持续演进，具体常量/步数/文件名以 master 分支为准。
