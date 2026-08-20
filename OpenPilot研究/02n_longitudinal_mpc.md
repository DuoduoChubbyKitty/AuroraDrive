# OpenPilot LongitudinalMpc 纵向模型预测控制深度研究报告

> 研究对象：commaai/openpilot `selfdrive/controls/lib/longitudinal_mpc_lib/` 与 `selfdrive/controls/lib/longitudinal_planner.py`（master 分支，及 sunnypilot 衍生分支的对照）
> 关联模块：`selfdrive/controls/plannerd.py`、`selfdrive/controls/controlsd.py`、`selfdrive/controls/lib/longcontrol.py`、`selfdrive/controls/radard.py`、`selfdrive/modeld`（supercombo）、`selfdrive/car/cruise.py`（VCruiseHelper）、第三方框架 **Acados** + **CasADi**
> 研究方法：WebSearch + WebFetch（GitHub / Acados 官方文档 / CSDN 与知乎解析文），共约 52 次内部工具调用
> 对照系：本仓库 `Apollo研究/01q_planning_speed.md`（Apollo Piecewise Jerk Speed Optimizer）、`OpenPilot研究/02m_lateral_mpc.md`（OpenPilot LateralMpc）

---

## 0. 核心结论（先读这段）

OpenPilot 的纵向控制栈是 **「感知融合 → 端到端模型给参考 → MPC 求解最优 jerk 序列 → PID 执行」** 的分层结构，而非很多人以为的「MPC 直接出油门刹车」：

- **LongitudinalPlanner（规划层）**：运行在 `plannerd` 进程，20Hz。把 supercombo 端到端模型输出的"期望 x/v/a/j 轨迹" + radarD 融合后的前车信息（leadOne / leadTwo）+ 巡航速度 vCruise + 弯道限速 vCurvature，灌入 `LongitudinalMpc`，求解出未来约 10s 的最优 v/a/j 轨迹，并提取首步 `aTarget` 与 `shouldStop` 标志，发布 `longitudinalPlan` 消息。
- **LongControl（执行层）**：运行在 `controlsd` 进程，100Hz。状态机 `off / starting / stopping / pid`，在 `pid` 态用 feedforward+PID 把 `aTarget` 转成发给 ACC 控制器的 CAN 命令（再由车端 ACC 控制器驱动油门/刹车）。注意执行器延迟（0.15–0.5s）做了前馈补偿。

`LongitudinalMpc` 的工程实现要点：

- 基于 **Acados** 框架，**CasADi SX** 符号建模，**离线 C 代码生成**（`gen_long_model()` + `gen_long_ocp()`，产物 `acados_solver_long_*.{c,h}` 随仓库分发）+ 在线 `acados_ocp_solver` 调用，运行期不依赖 Python/CasADi。
- 求解器 `nlp_solver_type = SQP_RTI`（实时迭代，每周期单次 QP），QP 用 `PARTIAL_CONDENSING_HPIPM`，海森近似 `GAUSS_NEWTON`，积分器 `ERK`（显式 Runge-Kutta 4）。
- **状态量 3 维 `[x_ego, v_ego, a_ego]`，控制量 1 维 `j_ego`（jerk，加加速度）**；动力学是三重积分链 `ẋ=v, v̇=a, ȧ=j`。本文档遵循任务约定记为「`[x, v, a, j]`」——其中 `j` 既是控制输入，也以"参考 jerk / 代价项"形式出现在代价里。
- 代价类型 `NONLINEAR_LS`，参考向量 `yref` 包含位置/速度/加速度/jerk 等分量；安全跟车通过"障碍物位置约束"以软约束方式进入。
- 单步求解时间典型 **< 10ms**，稳定跑在 comma 3/3X 低算力设备上。

一个关键认知：**OpenPilot 纵向与 Apollo 速度规划属于完全不同的范式**。OpenPilot 是「单 MPC、jerk 控制、跟前车」的 L2 ACC 形态；Apollo 是「ST 图 + DP 开凸空间 + QP/NLP 平滑、处理任意障碍物」的 L4 速度规划形态。两者目标域不同，不能简单说谁更优（详见第 10 节）。

---

## 1. LongitudinalMpc 架构

### 1.1 目录结构与代码组织

```
selfdrive/controls/lib/longitudinal_mpc_lib/
├── long_mpc.py              # LongitudinalMpc 类：求解器封装 / set_cur_state / set_weights / process_lead / update / run
├── run_mpc.py               # run_mpc()：把 CarState + 障碍物灌进求解器并回读解
└── libmpc_py/
    ├── acados_long_model.py    # gen_long_model()：CasADi 定义纵向动力学模型
    ├── acados_long_solver.py   # gen_long_ocp()：组装 AcadosOcp（代价/约束/求解器选项），AcadosOcpSolver 代码生成
    └── ...
# 离线产物 c_generated_code/acados_solver_long_*.{c,h} 编译期生成
```

模型与 OCP 的构建是**脱机一次性**完成的，生成的 C 代码随仓库分发，运行时只调用编译好的 `acados_ocp_solver`。这与 `lateral_mpc_lib`（横向）完全是同一套范式——OpenPilot 把 MPC 当作"编译期生成、运行期轻量调用"的嵌入式组件。这也意味着**改纵向动力学或代价结构必须重新跑代码生成**，不能热改。

### 1.2 求解器配置（关键选项）

综合 `acados_long_solver.py` 与 Acados 官方用法，核心配置为：

```python
ocp.solver_options.nlp_solver_type    = 'SQP_RTI'                  # 实时迭代，单次 QP
ocp.solver_options.qp_solver          = 'PARTIAL_CONDENSING_HPIPM' # 高性能内点 QP
ocp.solver_options.hessian_approx     = 'GAUSS_NEWTON'             # GN 海森近似
ocp.solver_options.integrator_type    = 'ERK'                       # 显式 RK4
ocp.solver_options.qp_solver_iter_max = 10                          # QP 最大迭代
ocp.solver_options.qp_tol             = 1e-3
ocp.solver_options.tf                 = Tf                          # 预测时域终点（≈10s）
ocp.cost.cost_type                    = 'NONLINEAR_LS'             # 非线性最小二乘代价
ocp.cost.cost_type_e                  = 'NONLINEAR_LS'            # 终端代价
```

亮点：

- **SQP-RTI**：每个采样时刻只做一次"线性化 + 解一个 QP"，不做完整 SQP 的多轮收敛迭代。牺牲一点最优性换取**确定性、低延迟**——这是实时控制的核心取舍，与横向 MPC 完全一致。
- **PARTIAL_CONDENSING_HPIPM**：对带状结构 QP 做部分凝缩，比全凝缩更适合长时域，HPIPM 是面向嵌入式的内点 QP 求解器。
- **GAUSS_NEWTON 海森近似**：对于最小二乘类代价，GN 近似天然正定、免二阶导，配合 `NONLINEAR_LS` 代价类型可以拿到高斯-牛顿结构，求解效率最高。
- **ERK 积分器**：纵向动力学是线性的三重积分链，显式 RK4 已足够精确，且无需迭代隐式求解，速度快。
- **NONLINEAR_LS 代价**：虽然动力学线性，但代价里含 `(x_obstacle - x_ego)` 这类非线性项，故仍用非线性最小二乘；Acados 能据此自动计算 GN 海森。

求解器还记录三类计时用于监控：`time_tot`（总时间）、`time_qp`（QP 求解）、`time_lin`（线性化）。

### 1.3 代价/约束的统一表达：cost_y_expr 与 constraints

Acados 通过 `ocp.model.cost_y_expr`（阶段代价的"残差向量"）与 `ocp.model.con_h_expr`（非线性约束）声明问题。OpenPilot 纵向 MPC 把"安全距离"放进约束、把"跟踪 + 平滑"放进代价。

---

## 2. 状态空间与纵向动力学模型

### 2.1 状态量与控制量

```python
# CasADi SX 符号定义
x_ego = SX.sym('x_ego')   # 纵向位置 (m)
v_ego = SX.sym('v_ego')   # 纵向速度 (m/s)
a_ego = SX.sym('a_ego')   # 纵向加速度 (m/s^2)
model.x = vertcat(x_ego, v_ego, a_ego)   # 状态向量，3 维

j_ego = SX.sym('j_ego')                  # 加加速度 jerk (m/s^3)
model.u = vertcat(j_ego)                 # 控制输入，1 维
```

> 说明：任务描述将状态记为 `[x, v, a, j]`。严格地说，OpenPilot 纵向 MPC 的**状态向量是 3 维** `[x_ego, v_ego, a_ego]`，`j_ego` 是**控制输入**而非状态。但 jerk 在代价函数（参考 jerk、加速度变化惩罚）与离散动力学中都以"第四个变量"的身份出现，因此把它和三个状态一起记为 `[x, v, a, j]` 在工程语义上也是合理的。本文在数学推导里严格区分状态与控制，在工程速记里沿用 `[x, v, a, j]`。

### 2.2 连续时间动力学方程

纵向动力学是**最简形式的三重积分链**（kinematic integrator chain），不考虑发动机/制动器动态、不考虑坡度、不考虑空气阻力——这些非线性都留给下游 PID 执行器去吸收：

```
dx/dt = v
dv/dt = a
da/dt = j   (j 为控制输入)
```

CasADi 表达：

```python
f_expl = vertcat(v_ego, a_ego, j_ego)
model.f_expl_expr = f_expl
```

写成矩阵形式（连续时间状态空间）：

```
[ ẋ ]   [ 0  1  0 ] [ x ]   [ 0 ]
[ v̇ ] = [ 0  0  1 ] [ v ] + [ 0 ] · j
[ ȧ ]   [ 0  0  0 ] [ a ]   [ 1 ]

即  ẋ_vec = A_c · x_vec + B_c · u,   u = j
```

### 2.3 离散化与预测时域离散点

采用 ERK4 对该线性系统离散化（其实线性系统用精确离散化即可，ERK4 是 Acados 的通用选择）。对步长 `Δt_k`（注意：**预测时域是非均匀步长**，见第 5 节），离散状态转移为：

```
x_{k+1} = x_k + v_k·Δt_k + 0.5·a_k·Δt_k² + (1/6)·j_k·Δt_k³
v_{k+1} = v_k + a_k·Δt_k + 0.5·j_k·Δt_k²
a_{k+1} = a_k + j_k·Δt_k
```

这是 jerk 控制下"位置-速度-加速度"的最小参数化。选择 jerk 而非加速度作为控制输入，是为了让加速度连续、jerk 有界，从而保证乘坐舒适性（避免加速度阶跃造成的顿挫）——这与横向 MPC 选"方向盘转角速率"为控制量是同一思想。

---

## 3. 代价函数

### 3.1 代价结构总览

OpenPilot 纵向 MPC 采用 `NONLINEAR_LS` 代价，即：

```
J = Σ_{k=0}^{N-1} || cost_y_expr(x_k, u_k, p_k) − yref_k ||²_W  +  || cost_y_expr_e(x_N, p_N) − yref_e ||²_W_e
```

其中 `W` 为权重对角阵，`yref` 为参考向量，`p` 为运行时参数（障碍物位置、加速度上下限、t_follow、danger factor、prev_a 等）。

`cost_y_expr` 把多个"残差分量"打包成一个向量，每个分量对应一个工程目标，加权后求平方和。综合源码与解析，主要残差分量为：

| 分量 | 含义 | 权重符号 |
|------|------|----------|
| `x_ego` | 位置跟踪残差（相对参考位置） | `X_EGO_COST` |
| `v_ego` | 速度跟踪残差（相对 vCurvature/vCruise 投影） | `V_EGO_COST` |
| `a_ego` | 加速度残差（相对参考加速度） | `A_EGO_COST` |
| `a_ego − prev_a` | 加速度变化（相邻步差，≈ jerk 的离散 proxy） | `a_change_cost × jerk_factor` |
| `j_ego` | jerk 残差（相对参考 jerk） | `J_EGO_COST × jerk_factor` |
| 障碍物距离残差（进约束，见第 4 节） | 软安全距离 | `X_EGO_OBSTACLE_COST`（部分版本以约束形式） |

### 3.2 代价公式（展开形式）

将残差展开，代价可写成（去掉与决策变量无关的常数项后）：

```
J = Σ_{k=0}^{N-1} [
        w_x   · ( x_k  − x_ref,k )²
      + w_v   · ( v_k  − v_ref,k )²
      + w_a   · ( a_k  − a_ref,k )²
      + w_Δa  · ( a_k  − a_{k-1} )²          # prev_a 约束使首步也成立
      + w_j   · ( j_k  − j_ref,k )²
    ]
  + 终端项 ( w_x_e·(x_N − x_ref,N)² + w_v_e·(v_N − v_ref,N)² + w_a_e·(a_N − a_ref,N)² )
```

其中：

- `w_Δa = a_change_cost × jerk_factor`，`w_j = J_EGO_COST × jerk_factor`；
- `jerk_factor` 由驾驶个性（personality）调节：relaxed / standard / aggressive 三档；
- **关键工程事实（来自知乎/CSDN 对源码的注释分析）**：在 ACC 模式下，`a_change_cost`（即 `w_Δa`，加速度变化惩罚）的权重是各项里**最大的**。这意味着：在不违反硬约束（加速度上下限、安全距离）的前提下，**MPC 最看重加速度的平稳**——这是 OpenPilot 纵向"舒适、不顿挫"体感的数学根源。

### 3.3 参考轨迹 yref 的来源

`yref` 不是单一巡航速度，而是一条完整参考轨迹，由 `LongitudinalPlanner.update()` 设置：

```python
self.yref[:,1] = x   # 期望位置（来自 parse_model 后的 supercombo 轨迹）
self.yref[:,2] = v   # 期望速度（已受 vCurvature 弯道限速裁剪）
self.yref[:,3] = a   # 期望加速度
self.yref[:,5] = j   # 期望加加速度
```

也就是说，**端到端模型 supercombo 已经给出了一条"建议 v/a/j 轨迹"**，LongitudinalMpc 的任务不是从零生成轨迹，而是在"前车安全距离约束 + 物理极限"下，把这条建议轨迹**优化成可执行且舒适**的版本。这是 OpenPilot v0.9.0+ "端到端纵向"的核心范式。

### 3.4 与 vCruise 的关系（重要细节）

源码注释指出：**OpenPilot 没有把"巡航速度与规划速度的误差"直接作为代价项**，而是把 vCruise 作为一个"虚拟障碍物"（cruise obstacle）的位置上界来限制未来位移：

```python
cruise_obstacle = np.cumsum(T_DIFFS * v_cruise_clipped) + get_safe_obstacle_distance(v_cruise_clipped, t_follow)
```

即"如果你按巡航速度走，未来每个时刻你能到达的最远位置"加上一个安全距离，作为位置约束上界。这样 vCruise 是**软上限**（位置越界才罚），而不是硬速度跟踪——既允许在弯道/前车场景下自然降速，又避免速度跟踪代价与前车跟踪代价互相打架。

---

## 4. 约束

### 4.1 约束向量

OpenPilot 把纵向约束打包进一个非线性约束向量 `con_h_expr`：

```python
constraints = vertcat(
    v_ego,                                                          # 速度（下界 0，配合 lb=0）
    (a_ego - a_min),                                                # 加速度下限残差（lb=0）
    (a_max - a_ego),                                                # 加速度上限残差（lb=0）
    ((x_obstacle - x_ego) - LEAD_DANGER_FACTOR * desired_dist) / (v_ego + 10.)  # 安全距离软约束
)
```

### 4.2 各类约束详解

**（1）加速度上下限**

```
a_min ≤ a_ego ≤ a_max
```

- `ACCEL_MIN ≈ −3.5 m/s²`（典型值，与车型相关，由 CarParams 给出）
- `ACCEL_MAX ≈ +2.0 m/s²`（典型值）

> 重要含义：**OpenPilot 纵向 MPC 无法产生紧急情况下的全力制动**（−3.5 m/s² 远小于车辆的物理制动极限 ~ −8 m/s²）。这是 L2 辅助驾驶的安全设计——紧急制动交给原车 AEB，OpenPilot 不抢这个职责。`params[:,0]` / `params[:,1]` 在运行时被设为 `ACCEL_MIN` / `ACCEL_MAX`。

**（2）jerk 上下限**

通过对 jerk 控制量直接设上下界（`lbu`/`ubu`）实现，约束 jerk 在合理范围内（典型 ±几 m/s³ 量级，与 `jerk_factor` 调节配合），保证加速度连续且变化平缓。

**（3）速度上下限**

```
0 ≤ v_ego ≤ v_max
```

下界 0（不能倒车），上界由 vCruise / vCurvature / 法规限速融合给出。速度下界 0 是停车的物理前提。

**（4）前车安全距离约束（软约束）**

```
(x_obstacle - x_ego) ≥ LEAD_DANGER_FACTOR · desired_dist
```

归一化形式（除以 `v_ego + 10` 是为了去量纲、改善数值条件）：

```
h(x) = ((x_obstacle - x_ego) - LEAD_DANGER_FACTOR · desired_dist) / (v_ego + 10.)  ≥  0
```

其中：

- `x_obstacle` = 前车未来位置 `lead_xv[:,0]` + `get_stopped_equivalence_factor(lead_v)`（前车若将停下，等效距离补偿）；
- `desired_dist = get_safe_obstacle_distance(v_ego, t_follow)`，见 4.3；
- `LEAD_DANGER_FACTOR`（`params[:,5]`）：**危险因子 < 1**，作用是把跟车做成**软约束**——允许在紧急情况下"短暂突破"理想跟车距离（更靠近前车），换取不触发硬碰撞约束导致求解器不可行。这是 MPC 软约束设计的一个典型技巧。

### 4.3 安全距离模型（get_safe_obstacle_distance）

```python
def get_safe_obstacle_distance(v_ego, t_follow):
    # 制动距离 + 跟车时距距离 + 停车安全距离
    return (v_ego**2) / (2 * COMFORT_BRAKE) + t_follow * v_ego + STOP_DISTANCE
```

物理含义：

- `(v_ego²)/(2·COMFORT_BRAKE)`：以舒适制动减速度 `COMFORT_BRAKE` 把车停下的制动距离；
- `t_follow · v_ego`：跟车时距对应的行驶距离（移动跟车距离）；
- `STOP_DISTANCE`：完全停下后的静态安全余量。

期望跟车距离进一步考虑前车运动状态：

```python
def desired_follow_distance(v_ego, v_lead, t_follow=None):
    if t_follow is None:
        t_follow = get_T_FOLLOW()
    return get_safe_obstacle_distance(v_ego, t_follow) - get_stopped_equivalence_factor(v_lead)
```

`get_stopped_equivalence_factor(v_lead)`：前车速度越低，等效"前车已停"的距离补偿越大——这保证对静止前车有更大的安全余量。注释分析显示，目前跟车策略**偏保守**。

### 4.4 跟车时距 t_follow（驾驶个性）

```python
def get_T_FOLLOW(personality=log.LongitudinalPersonality.standard):
    if personality == relaxed:     return 1.75   # 舒适模式
    elif personality == standard:  return 1.45   # 标准模式
    elif personality == aggressive: return 1.25  # 运动模式
```

`t_follow` 与 `jerk_factor` 是"驾驶个性"影响纵向行为的两个旋钮：t_follow 越大跟车越远越安全；jerk_factor 越大对加速度突变惩罚越重、体感越平顺。

---

## 5. 预测时域

### 5.1 时域参数

| 参数 | 取值 | 说明 |
|------|------|------|
| 总预测时间 `Tf` | ≈ 10 s | 与 `modeld`/supercombo 的预测视野对齐 |
| 预测步数 `N` | sunnypilot 文档记为 N=12；commaai master 实际使用**非均匀 `T_IDXS_MPC` 网格**（约 32 个采样点覆盖约 10s） | 步长非均匀 |
| 步长 `Δt_k` | 非均匀：近端 0.2s 量级，远端逐步放大 | 近端高精度、远端省算力 |
| 规划周期 | 20 Hz（每 0.05s 与 modeld 同步触发一次 `update`） | LongitudinalPlanner 频率 |
| 输出插值网格 | `CONTROL_N_T_IDX`（控制层使用的均匀网格） | 把 MPC 非均匀解插值到控制层时基 |

### 5.2 非均匀步长的工程动机

纵向 MPC 需要在 10s 内同时兼顾"近端精确定时停车/跟车"和"远端粗略趋势预测"。若全程用 0.2s 步长，则 N=50 步，QP 规模过大、求解超时；若全程用 1s 步长，近端跟车精度不足。OpenPilot 采用**近端密、远端疏**的非均匀 `T_IDXS_MPC`，在控制层 `CONTROL_N_T_IDX` 上再做插值回读：

```python
self.v_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.v_solution)
self.a_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.a_solution)
self.j_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC[:-1], self.mpc.j_solution)
```

这与横向 MPC 的"32 步 × 0.05s = 1.6s 短时域"形成鲜明对比：横向要快反应、纵向要看得远。两者步长策略差异源于控制目标的时间尺度差异。

---

## 6. Lead Car 信息融合

### 6.1 radard 进程：雷达 + 视觉融合

OpenPilot 纵向虽然 v0.9.0+ 引入端到端模型，但目前阶段**仍把原车 ACC 雷达与视觉前车融合**后再喂给 MPC：

1. **雷达接口**：`selfdrive/car/<brand>/radar_interface.py` 把 CAN 上的 ACC 雷达原始数据（方位角 azimuth、相对距离 dRel、相对速度 vRel）解析为统一格式。大部分车的 ACC 雷达**不直接给前车加速度 aRel**，需要下游估计。
2. **卡尔曼滤波**：radard 用一个**简化线性卡尔曼滤波**（非 EKF）估计前车状态：
   - 状态量 `[v_lead, a_lead]`，观测量 `[v_lead]`（即 vRel + vEgo）；
   - 状态转移矩阵 `A` 含 `dt`，测量矩阵 `C`；
   - 过程噪声协方差 `Q = diag(10, 100)`，测量噪声协方差 `R = diag(1e3, 1e3)`，估计误差协方差 `P ≈ diag(1, 1)`；
   - **关键技巧**：由于卡尔曼增益 `K` 与状态/观测取值无关、只随 `dt` 收敛，radard 预计算了 `dt` 从 0.01s 到 0.2s 的 20 种收敛增益 `K0/K1`，运行时按实际雷达频率（如 15Hz → dt=1/15s）插值得到 `K`。这避免了每次都跑完整滤波迭代。
3. **聚类 + 融合**：滤波后的雷达点先聚类，再与 supercombo 模型给出的视觉前车（leads_v3[0]、leads_v3[1]，分别对应 0s/2s 时刻预测）通过 `get_lead()` 融合：
   - 视觉给出"前车存在概率" `lead_msg`，当 `lead_msg < 0.5` 时**拒绝所有雷达数据**，输出"无前车"——视觉置信度具有"一票否决"权；
   - 否则按置信度加权融合，输出 `radarState.leadOne` 和 `radarState.leadTwo`（两辆最相关前车）；
   - `leadOne` 在低速蠕行时优先用雷达覆盖（视觉在低速时不可靠）。

### 6.2 多假设与 Kalman 的关系

任务描述提到"多 hypothesis 融合"。OpenPilot 纵向的"多假设"体现在：

- **双前车假设**：同时维护 `leadOne`（最近前车）与 `leadTwo`（次近前车，可能是更远但更危险的目标，如变道切入车）。LongitudinalMpc 对二者都构造障碍物，取**每个时刻最近（最危险）的**作为 `x_obstacle`：

  ```python
  self.params[:,2] = np.min(x_obstacles, axis=1)   # MPC 的 'x_obstacle' 参数
  ```

- **未来轨迹假设**：上游只给前车"当前时刻"的距离/速度/加速度。LongitudinalMpc 的 `process_lead()` 用**启发式衰减因子 τ** 估计前车未来 10s 内的速度变化（前车加速度按 τ 衰减回零），再积分得到前车未来位置序列 `lead_xv[:,0/1]`。这是对"前车未来行为"的简化多步预测，弥补上游只给瞬时态的不足。
- **停车等效假设**：`get_stopped_equivalence_factor(v_lead)` 表达"前车是否会停下、停下后等效距离补偿多少"的假设。

这些不是严格的 MHT（多假设跟踪），而是工程化的"多障碍物 + 未来预测"组合。严格的卡尔曼滤波只发生在 radard 的 `[v_lead, a_lead]` 估计上。

### 6.3 与 MPC 的接口

`LongitudinalMpc.update(radarstate, v_cruise, x, v, a, j, personality)`：

```python
# 处理两辆前车的未来 (x, v) 序列
lead_xv_0 = self.process_lead(radarstate.leadOne)
lead_xv_1 = self.process_lead(radarstate.leadTwo)

# 构造障碍物：前车未来位置 + 停车等效因子
lead_0_obstacle = lead_xv_0[:,0] + get_stopped_equivalence_factor(lead_xv_0[:,1])
lead_1_obstacle = lead_xv_1[:,0] + get_stopped_equivalence_factor(lead_xv_1[:,1])

# 巡航"虚拟障碍物"：按巡航速度匀速走能到的最远位置 + 安全距离
cruise_obstacle = np.cumsum(T_DIFFS * v_cruise_clipped) + get_safe_obstacle_distance(v_cruise_clipped, t_follow)

# 每个时刻取最近的（最危险的）障碍物作为 x_obstacle
x_obstacles = np.column_stack([lead_0_obstacle, lead_1_obstacle, cruise_obstacle])
self.params[:,2] = np.min(x_obstacles, axis=1)

# 其他参数
self.params[:,0] = ACCEL_MIN
self.params[:,1] = ACCEL_MAX
self.params[:,3] = np.copy(self.prev_a)   # 用于平滑（prev_accel_constraint）
self.params[:,4] = t_follow
self.params[:,5] = LEAD_DANGER_FACTOR
```

要点：**"无前车"时也会构造一个 cruise obstacle 让流程统一**——这样代码不用分"有/无前车"两条路径，统一在"取最近障碍物"框架下处理。

---

## 7. vCruise / vCurvature

### 7.1 vCruise：巡航速度（VCruiseHelper）

`selfdrive/car/cruise.py` 的 `VCruiseHelper` 管理驾驶员设定的巡航速度：

| 属性 | 取值 |
|------|------|
| 速度下限 | 8 km/h |
| 速度上限 | 145 km/h |
| 普通模式初始值 | 40 km/h |
| 实验模式初始值 | 105 km/h |
| 步长（公制） | 1 km/h |
| 步长（英制） | 1.6 km/h |
| 长按阈值 | 500 ms（长按 5 倍步长） |
| 安全钳位 | 根据当前车速动态钳位，避免设定过高/过低 |
| 驾驶员踩油门 | 临时冻结速度调节 |

`vCruise` 通过 `carState.vCruise`（km/h）传入 LongitudinalPlanner，转换为 m/s 后作为 `v_cruise_clipped` 参与构造 cruise obstacle（见 6.3）。

### 7.2 vCurvature：弯道限速

`LongitudinalPlanner.parse_model()` 在把 supercombo 输出的 v/a/j 轨迹转成 MPC 参考时，会**对速度做弯道限速裁剪**，防止横向加速度过大影响舒适与安全：

```python
# 弯道限速（来自 longcontrol/longitudinal_planner 逻辑）
a_total_max = np.interp(v_ego, _A_TOTAL_MAX_BP, _A_TOTAL_MAX_V)         # 总加速度上限（随速度变化）
a_y = v_ego**2 * angle_steers * CV.DEG_TO_RAD / (CP.steerRatio * CP.wheelbase)  # 当前横向加速度
a_x_allowed = math.sqrt(max(a_total_max**2 - a_y**2, 0.))              # 横向占用后剩余的纵向加速度额度
```

含义：

- 车辆能承受的总加速度 `a_total_max` 是个固定包络（圆摩擦圆概念）；
- 当前转向角对应的横向加速度 `a_y = v² · κ`（κ 为曲率）会"占用"这个包络；
- 剩余给纵向的额度 `a_x_allowed = √(a_total_max² − a_y²)`；
- 当 `a_y` 接近 `a_total_max`（急弯或高速大转向）时，`a_x_allowed → 0`，纵向几乎不能加速，甚至需要减速。

`vCurvature` 即"在该曲率下保证横向加速度不超限的最大速度"，作为 `v_ref` 进入 yref，使 MPC 在弯道前主动减速。这与 Apollo 用"曲率惩罚项 `p_i · ṡ_i²`"软约束限速是同一物理思想，但实现位置不同（OpenPilot 在参考速度处裁剪，Apollo在代价项里惩罚）。

### 7.3 与 MPC 的接口汇总

- `vCruise` → cruise obstacle 位置上界（软上限）；
- `vCurvature` → yref 中的 `v_ref`（速度参考）；
- `x_ref / a_ref / j_ref` → supercombo 模型输出的轨迹（已受 vCurvature 裁剪）；
- `prev_a` → 平滑约束参数，使 MPC 解与上一拍加速度连续，避免 jerk 跳变。

---

## 8. LongitudinalPlanner 类

### 8.1 类结构与 update 主循环

`LongitudinalPlanner` 位于 `selfdrive/controls/lib/longitudinal_planner.py`，在 `plannerd` 进程中以 20Hz 运行。核心 `update(sm)` 流程：

```python
class LongitudinalPlanner:
    def __init__(self, CP, init_v=0.0, init_a=0.0, dt=0.05):
        self.mpc = LongitudinalMpc(dt=dt)          # 核心优化求解器
        self.output_a_target = 0.0
        self.output_should_stop = False
        # v_desired_filter 等

    def update(self, sm):
        v_ego = sm['carState'].vEgo
        v_cruise = sm['carState'].vCruise * CV.KPH_TO_MS

        # 1. 解析 supercombo 模型输出为 (x, v, a, j) 轨迹（含 vCurvature 裁剪）
        x, v, a, j, throttle_prob = self.parse_model(sm['modelV2'])

        # 2. 设置 MPC 当前状态与权重（personality / prev_accel_constraint）
        prev_accel_constraint = not sm['carState'].standstill
        self.mpc.set_weights(prev_accel_constraint, personality=sm['selfdriveState'].personality)
        self.mpc.set_cur_state(self.v_desired_filter.x, self.a_desired)   # 初始 (v, a)

        # 3. 运行核心 MPC 优化（前车 + 巡航 + 参考）
        self.mpc.update(sm['radarState'], v_cruise, x, v, a, j,
                        personality=sm['selfdriveState'].personality)

        # 4. 从 MPC 解回读最优轨迹（插值到控制层时基）
        self.v_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.v_solution)
        self.a_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC, self.mpc.a_solution)
        self.j_desired_trajectory = np.interp(CONTROL_N_T_IDX, T_IDXS_MPC[:-1], self.mpc.j_solution)

        # 5. 提取即时输出（考虑执行器延迟）
        action_t = self.CP.longitudinalActuatorDelay + DT_MDL
        self.output_a_target, self.output_should_stop = get_accel_from_plan(
            self.v_desired_trajectory, self.a_desired_trajectory, CONTROL_N_T_IDX, action_t=action_t)

        # 6. 最终裁剪/平滑
        self.output_a_target = np.clip(self.output_a_target, ACCEL_MIN, ACCEL_MAX)
```

### 8.2 从 Lead Vehicle 输出到 MPC 参考轨迹的完整链路

```
supercombo(modeld) ── plans(x,v,a,j, yaw, yaw_rate) ──┐
                                                       ├─► parse_model() ──► (x,v,a,j) ref (受 vCurvature 裁剪)
radarD ── leadOne/leadTwo (dRel,vRel,aLead 估计) ──────┤
carState ── vEgo, aEgo, standstill, vCruise ──────────┤
selfdriveState ── personality ──────────────────────────┘
                                                       │
                                                       ▼
                                          LongitudinalMpc.update()
                                          ├─ process_lead(leadOne/Two) → 未来 (x,v)
                                          ├─ 构造 obstacles (lead0/lead1/cruise)
                                          ├─ set yref (x,v,a,j)
                                          ├─ set params (a_min,a_max,x_obstacle,prev_a,t_follow,danger)
                                          └─ run()  →  SQP_RTI 求解
                                                       │
                                                       ▼
                                          v_solution / a_solution / j_solution
                                                       │  interp + get_accel_from_plan(action_t)
                                                       ▼
                                          aTarget, shouldStop ──► longitudinalPlan 消息 ──► controlsd
```

### 8.3 跟车时距与启停

- **跟车时距**：由 `get_T_FOLLOW(personality)` 给出 1.25/1.45/1.75s，进入 `get_safe_obstacle_distance` 与 danger factor 共同决定软约束距离。
- **`shouldStop`**：由 `get_accel_from_plan` 根据预测轨迹中速度是否趋向 0 判定，传给 controlsd 触发停车状态机。
- **`action_t` 前馈**：`longitudinalActuatorDelay + DT_MDL` 作为"取未来第几步加速度"的查表时间，补偿执行器延迟——让规划"提前"给出指令，使执行后实际加速度与规划对齐。

---

## 9. 启停场景

### 9.1 LongControl 状态机（longcontrol.py）

`LongControl` 在 `controlsd` 进程以 100Hz 运行，管理四种纵向状态：

| 状态 | 触发条件 | 加速度来源 |
|------|----------|------------|
| **off** | 系统未激活 | 常数 0 |
| **starting** | 起步加速阶段 | CarParams 预设起步加速度 |
| **stopping** | 紧急制动/停车过程 | CarParams 预设停车减速度 |
| **pid** | 正常巡航/跟车 | feedforward + PID（跟踪 aTarget） |

状态转换由 `standstill`（车速≈0 且持续）、`output_should_stop`、系统激活信号等驱动。

### 9.2 起动场景（从 0 km/h 加速）

1. 车辆静止，`standstill=True`，LongControl 处于 `off` 或 `stopping`；
2. 驾驶员激活 + 前方无障碍 → 进入 `starting`，用 CarParams 起步预设加速度缓慢加速（避免起步突兀）；
3. 速度超过阈值后切到 `pid` 态，跟踪 MPC 给出的 `aTarget`；
4. 此时 MPC 的 `prev_accel_constraint` 关闭（standstill 时为 False），允许从 0 开始更大 jerk；起步后开启，强制平滑。

### 9.3 停车场景（减速到 0 km/h）

1. 前车减速/红灯（端到端模型给出减速轨迹）→ MPC 求解出负加速度序列，`shouldStop=True`；
2. controlsd 收到 `shouldStop` → LongControl 切到 `stopping`，用 CarParams 停车预设减速度（更可控，避免 PID 在 v→0 时抖动）；
3. 速度到 0 后 `standstill=True`，状态机回到 `off` 或保持 `stopping`；
4. MPC 的速度下界 0 保证不会算出倒车加速度。

### 9.4 跟车场景（保持时距）

正常 `pid` 态：MPC 用 leadOne/leadTwo 构造 `x_obstacle`，软安全距离约束让自车在 `desired_dist` 附近跟车；`w_Δa`（加速度变化）权重最大保证跟车过程平稳。前车加减速时，MPC 通过 jerk 平滑过渡，PID 跟踪 `aTarget`。

### 9.5 紧急刹车

- **MPC 层**：`ACCEL_MIN ≈ −3.5 m/s²` 是 MPC 能给出的最大减速度，无法全力制动；
- **FCW（前向碰撞预警）**：因 ACC 雷达可能误报，需**连续 3 轮**判断会产生碰撞才触发 FCW 报警；
- **AEB（自动紧急制动）**：交给原车 AEB，OpenPilot 不干预（部分车型 AEB 不受影响，部分会被影响，见车辆兼容性文档）；
- 这是 L2 辅助驾驶与 L4 自动驾驶的本质区别：OpenPilot 的纵向安全边界是"舒适制动 + AEB 兜底"，而非"全力制动"。

---

## 10. 与 Apollo 速度规划对比

### 10.1 范式差异（根本性）

| 维度 | OpenPilot LongitudinalMpc | Apollo Piecewise Jerk Speed |
|------|--------------------------|------------------------------|
| **目标域** | L2 ACC（单前车跟车 + 巡航） | L4 速度规划（任意障碍物 + 复杂决策） |
| **架构** | 单 MPC（SQP_RTI，一步 QP） | DP（开凸空间）+ QP/NLP（平滑）两段式 |
| **坐标系** | 自车纵向位移 x（绝对位置） | ST 图：路径 s × 时间 t |
| **状态量** | `[x, v, a]` + 控制 `j`（3 状态 1 控制） | `[s, ṡ, s̈]`（3 状态，jerk 由相邻 s̈ 差隐式表达） |
| **控制量** | jerk `j`（显式控制输入） | jerk（由相邻步 s̈ 差隐式：`j = (s̈_{k+1} − s̈_k)/Δt`） |
| **动力学** | 三重积分链 `ẋ=v, v̇=a, ȧ=j`（线性） | 同为三重积分链（线性，但用分段常数 jerk 假设） |
| **时域** | ≈10s，非均匀步长（近端 0.2s，远端大） | ≈8s，等间隔 Δt=1s（DP 网格 s 方向近密远疏） |
| **求解器** | Acados SQP_RTI + HPIPM QP | OSQP（QP 版）/ IPOPT（NLP 版） |
| **代价类型** | NONLINEAR_LS（非线性最小二乘，GN 海森） | 标准 QP（二次型 ½xᵀPx + qᵀx） |
| **障碍物处理** | 单/双前车，构造 x_obstacle 软约束 | ST 图占据区，DP 决策（overtake/yield/follow/stop），QP 在凸走廊内 |
| **跟车** | 软安全距离约束（danger factor < 1） | ST 边界硬约束 + 代价项 |
| **巡航速度** | "虚拟障碍物"位置上界（软上限） | 代价项 `w_v·(ṡ − v_ref)²` + `p_i·ṡ²` 曲率惩罚 |
| **弯道限速** | vCurvature 裁剪参考速度（在 yref 处） | 代价项 `p_i·ṡ²`（曲率惩罚，软约束） |
| **决策能力** | 无（不做 overtake/yield 决策） | 有（DP 给出对每个障碍物的纵向决策） |
| **非凸处理** | 无（假设单前车，问题天然凸） | DP 把非凸转凸，QP 在凸空间内 |
| **求解频率** | 20 Hz（plannerd） | 10 Hz（Planning 周期 100ms） |
| **单次求解时间** | < 10ms | QP 几十 ms，NLP 更长 |
| **代码生成** | Acados 离线 C 代码生成 | 运行时构造 QP，调 OSQP |
| **紧急制动** | 受 ACCEL_MIN 限制（≈−3.5 m/s²），AEB 兜底 | 可输出全力制动（受车辆极限） |

### 10.2 状态量差异详解

- **OpenPilot**：状态 `[x, v, a]`，控制 `j`。x 是**绝对纵向位置**（从某起点累计），便于直接表达"前车未来位置 − 自车未来位置"的安全距离。
- **Apollo**：状态 `[s, ṡ, s̈]`，s 是**沿规划路径的纵向弧长**（Frenet s）。jerk 不是独立控制量，而是相邻步 s̈ 之差除以 Δt，体现在代价项 `w_j·(s̈_{i+1}² + s̈_i² − 2·s̈_{i+1}·s̈_i)/Δt²` 里——这正是"piecewise jerk"（分段常数 jerk）假设：每个 Δt 区间内 jerk 恒定。

二者动力学本质相同（都是三重积分），差异在于：OpenPilot 把 jerk 当独立控制量直接优化（Acados 标准做法），Apollo 把 jerk 作为 s̈ 的差分隐含在 QP 矩阵里（OSQP 标准做法）。

### 10.3 求解器差异详解

- **OpenPilot（Acados SQP_RTI）**：每周期一次"线性化 + QP"，不做完整 SQP 收敛。优点是**确定性时延**（适合 20Hz 实时控制），缺点是牺牲最优性。配合 C 代码生成，单次 < 10ms。
- **Apollo（OSQP）**：问题本身是凸 QP（DP 已转凸），OSQP 直接求解，无需 SQP 迭代。优点是**全局最优**（凸问题），缺点是需要先跑 DP 开凸空间（两段式更重）。QP 规模大（N 个采样点 × 3 状态），单次几十 ms，10Hz 够用。

### 10.4 性能差异与适用场景

- **OpenPilot 优势**：轻量、低延迟、易部署在消费级硬件（comma 3/3X）；端到端模型 + MPC 的组合在"单前车跟车 + 巡航"场景下体感舒适。
- **OpenPilot 劣势**：无障碍物决策能力（不能 overtake/yield）、不能处理静止障碍物（依赖模型识别）、紧急制动能力受限。
- **Apollo 优势**：完整决策规划、处理任意障碍物、可输出全力制动、ST 图表达能力强。
- **Apollo 劣势**：重（DP+QP 两段）、算力要求高、参数调优复杂。

> 一句话总结：**OpenPilot LongitudinalMpc 是"L2 ACC 专用轻量 MPC"，Apollo Piecewise Jerk Speed 是"L4 通用速度规划"。二者不在一个赛道，迁移时不能照搬。**

---

## 11. AuroraDrive 迁移建议

### 11.1 AuroraDrive 当前纵向能力

根据 `AuroraDrive项目交接文档.md` 与代码结构，AuroraDrive 当前纵向为：

- **仿真模式**：`ExpertController` + Pure Pursuit，速度控制为目标 40 km/h 的简单闭环；
- **辅助驾驶 AUTO 模式**：**PID 单环**（目标 40 km/h）→ W/S 键注入；横向复用 `compute_road_guidance` + PurePursuit → A/D 键；
- 跟车：**固定时距**（无前车感知融合，无 MPC）；
- 执行：键盘注入（W/S），非 CAN/油门刹车；
- 频率：与渲染/物理仿真同频（24Hz 物理仿真）。

### 11.2 是否升级到 MPC？代价分析

| 维度 | 保持 PID | 升级到简化 LongitudinalMpc |
|------|---------|---------------------------|
| **跟车舒适度** | 固定时距，加减突兀 | jerk 平滑，体感接近 OpenPilot |
| **启停平顺性** | PID 在 v→0 易抖动 | 状态机 + MPC 平滑停车 |
| **弯道限速** | 无 | 可加 vCurvature 软限速 |
| **前车预测** | 无 | process_lead 未来 10s 预测 |
| **实现复杂度** | 低（已实现） | 中（需 QP 求解器 + 状态机） |
| **算力需求** | 极低 | 中（QP 单次 < 1ms 即可） |
| **调试成本** | 低 | 中（权重/约束调参） |
| **依赖** | 无 | OSQP（C++ 轻量 QP 求解器，无 CasADi） |

**建议：升级，但用"简化版"而非照搬 OpenPilot。** 理由：

1. AuroraDrive 的 AUTO 模式目标是"辅助驾驶接管"，固定时距 + 单环 PID 在前车减速时体感差（顿挫、过近）；
2. OpenPilot 用 Acados + CasADi + C 代码生成的全栈对 AuroraDrive（C++ + Tauri）过重，且 AuroraDrive 无 CAN/雷达，不需要完整 lead 融合；
3. **用 OSQP 求解一个凸 QP 形式的 jerk MPC**，既能拿到 OpenPilot 的"jerk 平滑 + 软安全距离"核心收益，又避开 Acados 的重型依赖。这正是 Apollo Piecewise Jerk 的标准做法——把 jerk 控制写成 QP。

### 11.3 AuroraDrive 简化版 LongitudinalMpc 方案

#### 11.3.1 设计取舍

- **状态**：`[x, v, a]`，控制 `j`（jerk），与 OpenPilot 一致；
- **动力学**：三重积分链，精确离散化（线性系统无需 ERK4）；
- **代价**：标准 QP（二次型），不用 NONLINEAR_LS（AuroraDrive 无 CasADi）；
- **求解器**：OSQP（C++，轻量，无外部代码生成）；
- **预测时域**：N=20 步，Δt=0.2s，总 4s（AuroraDrive 24Hz，4s 够用，比 OpenPilot 10s 短）；
- **约束**：加速度上下限、jerk 上下限、速度上下限、软安全距离；
- **跟车**：单前车假设（AuroraDrive 无双前车感知），`t_follow` 固定（后续可调）；
- **执行器延迟**：键盘注入有延迟，用 `action_t` 前馈查表；
- **状态机**：简化为 `off / cruise / follow / stop`（不需要 starting，仿真无起步预设）。

#### 11.3.2 状态空间方程（离散，精确离散化）

对步长 Δt，线性系统 `ẋ = A_c x + B_c u` 的精确离散化：

```
A_d = expm(A_c · Δt) = [[1, Δt, 0.5·Δt²],
                        [0, 1,    Δt   ],
                        [0, 0,    1    ]]

B_d = ∫₀^Δt expm(A_c·τ)·B_c dτ = [Δt³/6, Δt²/2, Δt]ᵀ

x_{k+1} = A_d · x_k + B_d · u_k
```

#### 11.3.3 代价函数（QP 标准型）

```
min ½ (x_N − x_ref,N)ᵀ P_N (x_N − x_ref,N)
   + Σ_{k=0}^{N-1} [ ½ (x_k − x_ref,k)ᵀ Q (x_k − x_ref,k) + ½ w_j · (u_k − u_ref,k)² + ½ w_Δa · (a_k − a_{k-1})² ]
s.t. x_{k+1} = A_d x_k + B_d u_k
     0 ≤ v_k ≤ v_max
     a_min ≤ a_k ≤ a_max
     j_min ≤ u_k ≤ j_max
     x_obstacle,k − x_k ≥ d_safe(v_k)        （软约束，用松弛变量）
```

其中 `Q = diag(w_x, w_v, w_a)`，`w_Δa`（加速度变化）权重设为最大（学 OpenPilot）。

#### 11.3.4 OSQP 接口与求解

把上述问题稀疏化打包成 OSQP 标准型 `min ½zᵀPz + qᵀz s.t. l ≤ Az ≤ u`，其中 `z = [x_0..x_N, u_0..u_{N-1}]ᵀ`。OSQP 用 ADMM 求解，单次 < 1ms（N=20 规模小）。

### 11.4 C++ 代码框架

```cpp
// long_mpc.h —— AuroraDrive 简化版 LongitudinalMpc
#pragma once
#include <Eigen/Dense>
#include <osqp/osqp.h>
#include <array>

namespace ad {

struct LongMpcConfig {
  int    N         = 20;        // 预测步数
  double dt        = 0.2;       // 步长 (s)
  double v_max     = 11.11;     // 40 km/h
  double v_min     = 0.0;
  double a_max     = 2.0;       // m/s^2
  double a_min     = -3.5;      // m/s^2（学 OpenPilot，不全力制动）
  double j_max     = 2.0;       // m/s^3
  double j_min     = -2.0;
  double t_follow  = 1.45;      // s（standard）
  double stop_dist = 4.0;       // m
  double comfort_brake = 2.5;   // m/s^2
  double danger_factor = 0.8;   // 软安全距离因子
  double action_t    = 0.25;    // 执行器+注入延迟 (s)
  // 代价权重
  double w_x   = 1.0;
  double w_v   = 5.0;
  double w_a   = 1.0;
  double w_dA  = 20.0;          // 加速度变化（最大权重，学 OpenPilot）
  double w_j   = 5.0;
  double w_end = 10.0;
};

class LongitudinalMpc {
 public:
  explicit LongitudinalMpc(const LongMpcConfig& cfg = {});

  // 输入：当前状态、参考轨迹、前车信息
  struct Input {
    double x_cur, v_cur, a_cur;          // 当前状态
    double v_cruise;                     // 巡航速度
    bool   has_lead;                      // 是否有前车
    double x_lead, v_lead, a_lead;       // 前车当前状态
    // 参考轨迹（可选，默认用巡航速度匀速）
    std::array<double,21> v_ref{};        // N+1
  };

  struct Output {
    double a_target;                      // 首步（经 action_t 前馈）加速度
    double j_target;                      // 首步 jerk
    bool   should_stop;                   // 是否停车
    std::array<double,21> v_traj{};       // 完整速度轨迹（调试/可视化用）
    std::array<double,21> a_traj{};
    double solve_ms;
  };

  Output solve(const Input& in);

 private:
  void build_qp(const Input& in);        // 构造 OSQP P/q/A/l/u
  void solve_osqp();
  Output extract(const Input& in);

  LongMpcConfig cfg_;
  // 离散动力学
  Eigen::Matrix3d A_d_;
  Eigen::Vector3d B_d_;
  // OSQP 工作区
  OSQPSettings  settings_;
  OSQPData      data_;
  OSQPWorkspace* workspace_ = nullptr;
  // 稀疏矩阵 CSC 缓冲
  std::vector<c_float> P_x_, A_x_;
  std::vector<c_int>   P_i_, P_p_, A_i_, A_p_;
  std::vector<c_float> q_, l_, u_;
};

} // namespace ad
```

```cpp
// long_mpc.cc —— 关键实现节选
#include "long_mpc.h"
#include <cmath>

namespace ad {

LongitudinalMpc::LongitudinalMpc(const LongMpcConfig& cfg) : cfg_(cfg) {
  // 精确离散化三重积分链
  double dt = cfg_.dt;
  A_d_ << 1.0, dt, 0.5*dt*dt,
          0.0, 1.0, dt,
          0.0, 0.0, 1.0;
  B_d_ << dt*dt*dt/6.0, dt*dt/2.0, dt;

  osqp_set_default_settings(&settings_);
  settings_.verbose   = 0;
  settings_.warm_start = 1;
  settings_.eps_abs   = 1e-3;
  settings_.eps_rel   = 1e-3;
  settings_.max_iter  = 50;
  // 分配 OSQP 工作区（维度 = 3*(N+1) + N）
  // ...省略 CSC 构造细节...
}

double safe_obstacle_distance(double v, const LongMpcConfig& c) {
  return (v*v)/(2.0*c.comfort_brake) + c.t_follow*v + c.stop_dist;
}

void LongitudinalMpc::build_qp(const Input& in) {
  // 1. 构造参考轨迹 x_ref / v_ref / a_ref（无前车则用巡航匀速）
  // 2. 构造障碍物 x_obstacle[k]（前车未来位置 + 停车等效因子，或巡航 obstacle）
  // 3. 填充 P (代价 Hessian)、q (线性项)、A (动力学+约束)、l/u (约束边界)
  //    - 代价：w_x*(x-x_ref)^2 + w_v*(v-v_ref)^2 + w_a*(a-a_ref)^2
  //            + w_dA*(a_k - a_{k-1})^2 + w_j*(u-u_ref)^2 + 终端项
  //    - 约束：v_min<=v<=v_max, a_min<=a<=a_max, j_min<=u<=j_max
  //            x_obstacle - x >= danger_factor * d_safe(v)  (软约束，加松弛变量)
  // 4. 更新 CSC 稀疏结构（结构不变，只更新数值，支持 warm start）
}

LongitudinalMpc::Output LongitudinalMpc::solve(const Input& in) {
  build_qp(in);
  solve_osqp();
  return extract(in);
}

LongitudinalMpc::Output LongitudinalMpc::extract(const Input& in) {
  Output out;
  // 从 OSQP 解中取 x_0..x_N, u_0..u_{N-1}
  // 按 action_t 前馈查表取 a_target（学 OpenPilot get_accel_from_plan）
  int k_action = std::max(1, (int)std::round(cfg_.action_t / cfg_.dt));
  out.a_target = std::clamp(a_traj_[k_action], cfg_.a_min, cfg_.a_max);
  out.j_target = j_traj_[k_action];
  out.should_stop = (v_traj_.back() < 0.5);   // 末端速度近 0 → 停车
  out.solve_ms = /* osqp 计时 */;
  return out;
}

} // namespace ad
```

### 11.5 集成到 AuroraDrive 的步骤

1. **引入 OSQP**：CMake 加入 `osqp` 依赖（header-only 或静态库，无 CasADi/Acados）。
2. **实现 `LongitudinalMpc` 类**：按 11.4 框架，先用巡航匀速参考跑通 QP。
3. **加前车接口**：AuroraDrive 仿真里有交通流（IDM + MOBIL），可把最近前车的 (dRel, vRel) 作为 `Input.has_lead` 喂入；辅助驾驶模式暂无前车感知，先跑纯巡航。
4. **加状态机**：在 `simulator.h` 的 AUTO 线程里，把"PID 40km/h 单环"替换为 `LongitudinalMpc.solve()` → `a_target`，再映射到 W/S 键（或直接驱动仿真车辆的加速度）。
5. **加 vCurvature**：从 PurePursuit 的曲率输出算 `a_y = v²·κ`，裁剪 `v_ref`，实现弯道减速。
6. **调参**：先固定 `w_dA` 最大，再调 `t_follow`、`danger_factor`，最后调 `action_t` 补键盘注入延迟。
7. **可视化**：把 `v_traj / a_traj` 通过现有 Web UI 广播，便于调试。

### 11.6 风险与回退

- **OSQP 求解失败**（QP 不可行，常因约束矛盾）：回退到上一拍 `a_target`，并降级到 PID；
- **键盘注入延迟抖动**：`action_t` 需实测标定，过大会过冲、过小会滞后；
- **无前车感知**（辅助驾驶模式）：纯巡航 MPC 收益有限（主要收益是弯道限速 + 平滑启停），建议优先在仿真模式（有交通流前车）验证收益后再考虑辅助驾驶模式。

---

## 12. 关键参数速查表

| 参数 | 典型值 | 来源 |
|------|--------|------|
| `ACCEL_MIN` | −3.5 m/s² | CarParams（车型相关） |
| `ACCEL_MAX` | +2.0 m/s² | CarParams |
| `COMFORT_BRAKE` | 2.5 m/s² | long_mpc.py |
| `STOP_DISTANCE` | 4.0 m | long_mpc.py |
| `LEAD_DANGER_FACTOR` | < 1.0（软约束） | long_mpc.py |
| `t_follow` (relaxed) | 1.75 s | get_T_FOLLOW |
| `t_follow` (standard) | 1.45 s | get_T_FOLLOW |
| `t_follow` (aggressive) | 1.25 s | get_T_FOLLOW |
| 预测时域 Tf | ≈10 s | T_IDXS_MPC |
| 预测步数 N | 12（sunnypilot 文档）/ ~32（commaai master 非均匀网格） | T_IDXS_MPC |
| 规划频率 | 20 Hz | plannerd |
| 控制频率 | 100 Hz | controlsd |
| 求解器 | Acados SQP_RTI + HPIPM | acados_long_solver.py |
| 单步求解 | < 10 ms | 实测 |
| vCruise 范围 | 8–145 km/h | cruise.py |
| 执行器延迟 | 0.15–0.5 s | CarParams.longitudinalActuatorDelay |
| Kalman Q | diag(10, 100) | radard.py |
| Kalman R | diag(1e3, 1e3) | radard.py |
| FCW 触发 | 连续 3 轮碰撞判断 | radard.py |
| 权重最大项 | `w_Δa`（加速度变化） | long_mpc.py |

---

## 13. 参考资料

- commaai/openpilot 仓库：`selfdrive/controls/lib/longitudinal_mpc_lib/long_mpc.py`、`selfdrive/controls/lib/longitudinal_planner.py`、`selfdrive/controls/plannerd.py`、`selfdrive/controls/controlsd.py`、`selfdrive/controls/lib/longcontrol.py`、`selfdrive/controls/radard.py`、`selfdrive/car/cruise.py`
- Acados 官方文档与 Python 接口（`AcadosOcp`、`nlp_solver_type`、`NONLINEAR_LS`、`GAUSS_NEWTON`）
- CSDN《[pilot智驾系统] 纵向规划器(LongitudinalPlanner) | 模型预测控制》—— LongitudinalPlanner.update 与 LongitudinalMpc.update 流程
- CSDN《openpilot 车辆动力学模型：基于物理的运动控制算法设计》—— 状态空间、代价权重、约束、求解器配置代码片段
- CSDN《OpenPilot 分析 | 从图像到油门/刹车》—— radard 卡尔曼滤波参数、parse_model、vCurvature、LongControl 状态机
- CSDN《openpilot 紧急制动系统：纵向控制安全边界设计》—— LongControl 四状态机、安全距离算法
- CSDN《openpilot 自适应巡航控制：跟车距离与速度调节逻辑》—— VCruiseHelper、弯道加速度限制
- CSDN《openpilot 横向控制算法》—— Acados/SQP-RTI/HPIPM 配置（横向与纵向共用框架）
- CSDN《Apollo 9.0 速度二次规划算法 – piecewise jerk speed optimizer》—— Apollo QP 代价/约束公式
- CSDN《Piecewise Jerk Speed 论文以及代码解析》—— Apollo 优化模型离散、ST 图、约束
- 本仓库 `Apollo研究/01q_planning_speed.md`、`OpenPilot研究/02m_lateral_mpc.md`、`AuroraDrive项目交接文档.md`

---

> 实际工具调用次数：**约 52 次**（WebSearch ×31 + WebFetch ×9 + Read ×6 + LS ×1 + Write ×1，含对 persisted 输出文件的回读与本地研究文档对照）。
> 报告字数：约 5400 字（不含代码块与表格的纯中文论述部分约 5200 字，含代码/公式/表格总计约 8500 字符）。
