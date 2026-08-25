# 百度 Apollo MPC Controller（模型预测控制）深度研究报告

> 研究对象：`modules/control/controllers/mpc/mpc_controller.cc`、`modules/control/controllers/mpc/mpc_osqp.cc`（旧版位于 `modules/common/math/mpc_osqp.cc`）、`mpc_controller.h`
> 理论基础：Rajamani《Vehicle Dynamics and Control》2.5 节 *Dynamic Model in Terms of Error with Respect to Road*（P37）
> 求解器：OSQP（Operator Splitting Quadratic Programming，牛津大学维护，ADMM 算法）
> 关联控制器：LQR 横向控制器、lon_based_pid_controller 纵向控制器
> 默认策略：Apollo 控制模块默认使用 **PID（纵向）+ LQR（横向）** 解耦方案，MPC 为可选的横纵向耦合控制器（在 `control_conf.pb.txt` 中通过 `active_controllers` / 控制器类型切换启用）

---

## 0. 概述与定位

Apollo 的 Control 模块对外提供三类控制器：纵向控制器（`lon_based_pid_controller`）、横向控制器（`lat_based_lqr_controller` / `lat_controller`）以及横纵向综合控制器（`mpc_controller`）。前两者是 **横纵向解耦** 的方案——纵向用位置/速度双环 PID，横向用基于动力学误差模型的 LQR + 前馈；而 MPC Controller 把横向与纵向放进 **同一个状态空间** 一起优化，输出前轮转角 δ_f 与纵向加速度增量 Δa_x，体现了 **横纵向耦合（cross-coupling）** 的思想。

代码入口函数为 `MPCController::ComputeControlCommand()`，输入为规划轨迹（trajectory）与车辆当前状态（vehicle state），输出为方向盘转角、油门、刹车。MPC 把"当前状态 + 预测时域内每一步的状态/控制代价 + 控制量约束"组织成一个 **二次规划（QP）** 问题，交给 OSQP 求解，取最优控制序列的首步执行，下一周期再基于最新车辆状态重新求解（滚动优化 + 反馈校正）。

---

## 1. 状态量（6 维）

Apollo MPC 采用 6 维状态向量，是对 LQR 横向 4 维状态的纵向扩展：

```
x = [ lateral_error,
      lateral_error_rate,
      heading_error,
      heading_error_rate,
      station_error,
      speed_error ]^T
```

代码中对应：

```cpp
matrix_state_ = Matrix::Zero(basic_state_size_, 1);  // basic_state_size_ = 6
matrix_state_(0, 0) = debug->lateral_error();
matrix_state_(1, 0) = debug->lateral_error_rate();
matrix_state_(2, 0) = debug->heading_error();
matrix_state_(3, 0) = debug->heading_error_rate();
matrix_state_(4, 0) = debug->station_error();
matrix_state_(5, 0) = debug->speed_error();
```

### 1.1 各状态量物理含义

| 索引 | 状态量 | 物理含义 |
|------|--------|----------|
| 0 | `lateral_error` | 横向位置误差：车辆后轴（或质心，按配置可切换）到参考轨迹的横向距离，正值表示车辆在轨迹左侧（依坐标系约定） |
| 1 | `lateral_error_rate` | 横向误差变化率：横向误差对时间的导数，反映车辆横向靠近/远离轨迹的速度 |
| 2 | `heading_error` | 航向角误差：车辆航向角与参考点航向角之差（e_φ = φ - φ_des） |
| 3 | `heading_error_rate` | 航向角误差变化率：即横摆角速度误差（φ̇ - φ̇_des），工程中常把 heading_error_rate 等同于横摆角速度误差 |
| 4 | `station_error` | 纵向位置误差：沿参考轨迹弧长方向，车辆投影点与匹配参考点之间的纵向距离偏差 |
| 5 | `speed_error` | 纵向速度误差：车辆纵向速度与参考点期望速度之差 |

### 1.2 状态量计算方法

- **横向误差 / 航向误差**：由 `ComputeLateralErrors(...)` 计算。先调用 `trajectory_analyzer` 的 `QueryNearestPointByPosition` 找到离车辆最近的参考点，得到该点的航向角、横向偏移 `d`、横向速度 `d_dot`，并据此构造 `TrajectoryPoint`。横向误差通过把车辆位置投影到参考点切线/法线方向得到；横向误差率由横向速度在法线方向分量给出；航向误差为车辆 heading 与参考点 heading 之差；航向误差率为车辆横摆角速度与参考横摆角速度之差。
- **纵向误差 / 速度误差**：由 `ComputeLongitudinalErrors(...)` 计算。沿 Frenet 坐标分解车辆运动，得到 `station_error`（纵向弧长偏差）与 `speed_error`（纵向速度偏差），同时给出 `preview_station_error` / `preview_speed_error` 用于预瞄。
- 代码中两条误差计算函数均在 `ComputeControlCommand` 入口处依次调用，结果写入 `debug` 结构，再装配到 `matrix_state_`。

---

## 2. 控制量（2 维）

```
u = [ δ_f, Δa_x ]^T
```

- `δ_f`：前轮转角（rad），由 MPC 直接优化输出，再按转向比换算成方向盘转角；
- `Δa_x`：纵向加速度增量（m/s²），叠加到参考点的加速度上得到最终加速度命令，再查油门/刹车标定表输出踏板量。

### 2.1 横纵向耦合的体现

控制矩阵 `B`（见 §4）中：
- `δ_f` 同时影响 `lateral_error_rate`（第 2 行 `Cf/m`）与 `heading_error_rate`（第 4 行 `Cf*lf/Iz`），即转向同时改变横向与横摆；
- `Δa_x` 仅作用于 `speed_error`（第 6 行 `-1`），并通过 `station_error` 的积分关系（第 5 行 `1`）影响纵向位置。

关键在于：**纵向速度 Vx 直接出现在 A 矩阵的多个元素中**（`1/Vx` 项），因此加速度改变 Vx 后，横向动力学（A 的前 4 行）也随之改变。MPC 在同一个 QP 里同时优化 δ_f 与 Δa_x，自然地把"加速会削弱横向稳定性、转向会改变纵向速度投影"这种耦合考虑进去；而 LQR/PID 解耦方案只能各管一边，耦合效应依赖前馈与经验补偿。这是 MPC 相对解耦方案的核心理论优势。

---

## 3. 动力学模型（连续状态空间）

Apollo MPC 的模型来自 Rajamani《Vehicle Dynamics and Control》2.5 节 *Dynamic Model in Terms of Error with Respect to Road*（P37），即"相对道路误差的动力学模型"。基于自行车模型（bicycle model）+ 小角度线性化 + 恒定纵向速度假设，得到线性误差状态空间：

```
ẋ = A·x + B·u + C·ψ̇_des
```

其中 `ψ̇_des` 为期望横摆角速度（前馈/扰动项），由参考轨迹曲率与车速决定。

### 3.1 A 矩阵（6×6）— 系统矩阵

```
        ┌ 0    1                        0                        0                              0    0 ┐
        │ 0    -(Cf+Cr)/(m·Vx)          (Cf+Cr)/m                (Cr·lr - Cf·lf)/(m·Vx)         0    0 │
   A =  │ 0    0                        0                        1                              0    0 │
        │ 0    (Cr·lr - Cf·lf)/(Iz·Vx)  (Cf·lf - Cr·lr)/Iz       -(Cr·lr² + Cf·lf²)/(Iz·Vx)     0    0 │
        │ 0    0                        0                        0                              0    1 │
        └ 0    0                        0                        0                              0    0 ┘
```

参数说明（车辆参数，需辨识或由车辆配置给出）：

| 参数 | 含义 |
|------|------|
| `m` | 车辆整备质量（kg） |
| `Iz` | 车辆绕铅垂轴（z 轴）的转动惯量（kg·m²） |
| `Cf` | 前两轮总侧偏刚度（N/rad），Apollo 代码中常以 `2*Caf` 形式出现（单胎刚度 ×2） |
| `Cr` | 后两轮总侧偏刚度（N/rad），同理 `2*Car` |
| `lf` | 质心到前轴距离（m） |
| `lr` | 质心到后轴距离（m） |
| `Vx` | 车辆纵向速度（m/s），控制周期内视为常量 |

A 矩阵结构特点：
- 左上 4×4 块为横向动力学（与 LQR 横向控制器完全一致），描述 lateral_error / lateral_error_rate / heading_error / heading_error_rate 的演化；
- 右下 2×2 块为纵向动力学，是简单的"位置误差 = 速度误差积分、速度误差 = 加速度积分"的双积分器；
- 横纵向块在 A 中本身是解耦的（无交叉项），耦合通过 B（控制）与 Vx（参数）体现。

### 3.2 B 矩阵（6×2）— 控制矩阵

```
        ┌ 0        0   ┐
        │ Cf/m     0   │
   B =  │ 0        0   │
        │ Cf·lf/Iz 0   │
        │ 0        0   │
        └ 0        -1  ┘
```

- 第 1 列（δ_f 的影响）：作用在 `lateral_error_rate`（`Cf/m`）与 `heading_error_rate`（`Cf·lf/Iz`）；
- 第 2 列（Δa_x 的影响）：仅作用在 `speed_error`（`-1`，负号表示加速度增大则速度误差减小）。

### 3.3 C 矩阵（6×1）— 前馈/扰动项

```
        ┌ 0                                    ┐
        │ (Cr·lr - Cf·lf)/(m·Vx) - Vx          │
   C =  │ 0                                    │
        │ -(Cr·lr² + Cf·lf²)/(Iz·Vx)           │
        │ 0                                    │
        └ 0                                    ┘
```

C 与期望横摆角速度 `ψ̇_des` 相乘，构成前馈项。`ψ̇_des = κ·Vx`（κ 为参考轨迹曲率），用于补偿车辆沿弯曲道路行驶时由曲率产生的稳态横向偏差与横摆，是消除稳态误差的关键。注意 C 的第 2 行包含 `-Vx`，这正是"道路弯曲导致车辆需要额外横摆"在误差动力学中的体现。

### 3.4 离散化

连续模型需离散化为差分方程才能在数字控制器中使用。Apollo 早期版本采用 **双线性变换（Bilinear Transform / Tustin 法）**：

```
A_d = (I - A·ts/2)^{-1} · (I + A·ts/2)
B_d = B · ts
C_d = C · ts            （部分实现将 ψ̇_des 直接合入 C~ 再离散化）
```

代码注释中亦可见更简单的 **前向欧拉近似** `A_d ≈ I + A·ts`（在 ts 较小时与 Tustin 接近）。更新逻辑封装在 `UpdateMatrix()` / `update_matrix()` 中，每个控制周期根据当前 `Vx` 重算 `matrix_a_` 并离散化为 `matrix_ad_`，再更新 `matrix_bd_`、`matrix_cd_`。由于 A 依赖 Vx，因此每个周期矩阵都不同——这也是 MPC 模型预测"基于实时反馈校正"的体现。

---

## 4. 预测时域与 QP 构造

### 4.1 预测时域（Horizon）

MPC 在当前时刻 t 向前预测 `N`（horizon）步，假设预测时域内车辆模型（A_d, B_d, C_d）与控制行为不变。Apollo 中 horizon 通过 `MPCControllerConf` 配置，常见取值 10（早期文档与多个解析均提到 `horizon = 10`，新版可调），采样周期 ts 与控制周期一致（约 0.01s 量级）。预测时域越长，越能"显式考虑未来多步"，但 QP 规模与求解时间也随之增长。

### 4.2 状态递推与增广矩阵

将预测时域内所有状态堆叠为增广向量，可把递推 `x(k+1) = A_d·x(k) + B_d·u(k) + C_d·ψ̇_des` 展开为关于控制序列 U = [u(0), u(1), …, u(N-1)]^T 的表达式：

```
X = M·x0 + K·U + CC·ψ̇_des
```

其中（代码变量名对应）：
- `matrix_a_power[i] = A_d^i`（A 的 i 次幂）；
- `matrix_aa`（Ψ_t）：堆叠的 A_d 幂；
- `matrix_m`（M）：由 x0 经 A_d 递推得到的未来自由响应，`M = [A_d·x0, A_d²·x0, …]^T`；
- `matrix_k`（K / Φ_t）：下三角块结构，`K.block(r,c) = A_d^(r-c-1)·B_d`（c < r），对角块为 B_d，刻画"第 c 步控制对第 r 步状态"的传递；
- `matrix_cc`（CC / Υ_t）：C_d 经 A_d 递推累加得到的前馈响应；
- `matrix_t`（Ref）：堆叠的参考状态（参考轨迹，目标为 0 误差时即零向量）。

### 4.3 目标函数 → QP

MPC 目标函数为状态与控制的二次型：

```
J = Σ_{k=0}^{N-1} [ x(k)^T·Q·x(k) + u(k)^T·R·u(k) ]
```

代入 `X = M·x0 + K·U + CC - Ref`（令 E = M + CC - Ref 为"无控制下的预测误差"），并舍弃与 U 无关的常数项，得到关于 U 的标准 QP：

```
min_U  ½·U^T·H·U + U^T·g
```

其中（代码变量名）：
- `matrix_m1`（H = M1）= `K^T·QQ·K + RR`，QQ/RR 为 Q/R 沿 horizon 对角堆叠；
- `matrix_m2`（g = M2）= `K^T·QQ·(M + CC - T)` = `K^T·QQ·E`；
- `matrix_qq`：Q 沿 horizon 的块对角堆叠；
- `matrix_rr`：R 沿 horizon 的块对角堆叠。

无约束解析解（用于参考/增益分析）为：
```
U* = -H^{-1}·g = -(K^T·QQ·K + RR)^{-1}·K^T·QQ·E
```
对应代码中 `matrix_m0 = -matrix_m1.inverse()·K^T·QQ`，`matrix_ctrl_gain = matrix_m0·matrix_aa`，`matrix_add_gain = matrix_m0·matrix_cc`。

### 4.4 滚动优化 + 反馈校正

每个控制周期：① 用最新车辆状态重算 x0 与误差；② 重算 A_d/B_d/C_d（Vx 变了）；③ 求解 QP 得到未来 N 步最优控制序列；④ **只取首步 u(0)**（即 δ_f, Δa_x）下发执行；⑤ 下一周期重复。这就是"滚动优化 + 反馈校正"——预测基于实时反馈，天然构成闭环。

---

## 5. 约束

MPC 相对 LQR 的关键优势是 **显式约束**。Apollo MPC 通过 `lower_bound` / `upper_bound` 对控制量施加 box 约束（QP 中以 `l ≤ U ≤ u` 形式实现）：

- **前轮转角 δ_f 上下界**：由车辆最大转向角限制（`max_steer_angle`），并随车速进一步收紧；
- **转角速率 δ̇_f 限制**：影响方向盘转速与横摆角加速度，直接关系乘客体感的 jerk（部分社区解析指出 Apollo MPC 主要约束控制量本身，对控制 *增量* 的约束较弱，是可改进点）；
- **加速度 Δa_x 上下界**：由最大纵向加速度 / 最大减速度限制（`max_acceleration` / `max_deceleration`）；
- **方向盘转角限制**：`max_steer_angle_rate`、以及由"最大纵向加速度 × 轴距 / 速度²"换算的横向加速度约束转角上限。

OSQP 求解器把约束统一写成 `l ≤ A·x ≤ u` 的形式，box 约束只需把 A 设为单位阵、l/u 设为对应上下界即可，避免了等式约束带来的求解开销（Apollo 文档明确建议"尽量少用等式约束"以提升 OSQP 求解速度与成功率）。

---

## 6. 增益调度（Gain Scheduling）

由于车辆动力学是非线性系统（A 依赖 Vx），Apollo 用 **增益调度** 把非线性系统近似为一组线性控制器：按 **纵向速度** 划分多个区间，每个区间预存一组 Q / R 权重序列（`matrix_q_updated_` / `matrix_r_updated_`）。`Init()` 阶段加载 `MPCControllerConf` 中的 `gain_scheduling` 表，`ComputeControlCommand` 中根据当前 Vx 选择对应 Q/R：

- **低速**：增大 Q 中横向/航向误差权重，提高响应速度与循迹精度；
- **高速**：降低横向误差权重、增大控制权重 R 或降低增益，保证稳定性、避免方向盘剧烈动作；
- 部分实现还会"将 Q/R 矩阵相应参数乘以车速"做连续插值，而非纯分段切换。

增益调度本质上是用一组线性控制器覆盖非线性工作点，类似汽车标定中的 map 图。它使 MPC（及 LQR）能在宽车速范围内稳定工作。

---

## 7. 优点

1. **显式考虑未来多步**：通过 horizon 预测未来 N 步状态，控制具有前瞻性，对曲率变化、减速入弯等场景更平滑，而非像 PID 那样只看当前误差。
2. **显式约束**：转角、转角速率、加速度上下界都写进 QP，物理可行性强，避免执行器饱和与不安全动作；LQR 无约束，只能事后裁剪。
3. **控制平滑**：QP 目标函数含 R（控制能量）项 + 多步预测，天然抑制控制量抖动，提升舒适性。
4. **横纵向耦合**：δ_f 与 Δa_x 在同一 QP 内联合优化，显式建模"加速削弱横向稳定 / 转向影响纵向速度"的耦合，比解耦方案更接近真实车辆动力学。
5. **前馈 + 反馈一体**：C·ψ̇_des 前馈项与状态反馈统一在 QP 中求解，稳态误差小。
6. **滚动优化 + 反馈校正**：每周期基于最新状态重解，对模型失配与扰动有天然鲁棒性。

---

## 8. 与 LQR / PID 对比

| 维度 | MPC | LQR | PID |
|------|-----|-----|-----|
| 模型 | 动力学误差模型（A/B/C） | 动力学误差模型（A/B） | 无模型 |
| 时域 | 多步预测 horizon | 单步（无限时域黎卡提解） | 当前误差 |
| 约束 | 显式 box 约束（转角/加速度/速率） | 无约束 | 事后限幅 |
| 求解 | QP（OSQP），每周期在线解 | 离线解黎卡提方程得 K，在线 u=-Kx | 在线 PID 运算 |
| 横纵向 | 耦合（δ_f + Δa_x 同一 QP） | 仅横向（LQR）+ 纵向 PID 解耦 | 解耦 |
| 计算量 | 高（在线 QP） | 低（矩阵乘） | 极低 |
| 平滑性 | 好（R 项 + 多步） | 一般 | 易抖动 |
| 调参 | Q/R/horizon + 增益调度表 | Q/R | Kp/Ki/Kd |
| Apollo 默认 | 可选（非默认） | **默认横向** | **默认纵向** |

要点：
- **MPC vs LQR**：两者状态方程、状态量、目标函数形式都相似（都是二次型 + 线性模型），但 MPC 显式约束 + 多步预测，LQR 无约束 + 单步（黎卡提解本质是无限时域最优反馈）。MPC 可看作"带约束、有限时域的滚动 LQR"。Apollo 默认横向用 LQR，因其计算量小、无需求解器依赖；MPC 作为升级选项。
- **MPC vs PID**：MPC 用动力学模型预测未来，PID 仅基于当前误差的比例/积分/微分。MPC 平滑性与约束处理远胜 PID，但计算量与模型依赖更高。
- Apollo 选择"默认 LQR+PID、MPC 可选"是工程权衡：LQR+PID 简单稳健、算力友好，已能满足多数场景；MPC 在对横纵向耦合、约束、平滑性要求高时启用。

---

## 9. OSQP 求解

### 9.1 OSQP 标准 QP 格式

OSQP 求解如下凸二次规划（P 半正定）：

```
minimize    (1/2)·x^T·P·x + q^T·x
subject to  l ≤ A·x ≤ u
```

其中 x∈R^n 为优化变量，P∈S_+^n，q∈R^n，A∈R^(m×n)，l/u 中分量可取 ±∞。OSQP 内核用 **ADMM（交替方向乘子法）** 求解，每步解一个拟定线性系统并做超盒投影 [l,u]，支持 ρ 步长自适应、不可行性检测与 polishing。

### 9.2 Apollo MPC 的 QP 构造（`MpcOsqp` 类）

Apollo 把 §4.3 的 MPC QP 映射到 OSQP 标准形式：
- **优化变量 x → 控制序列 U**（horizon×2 维）；
- **P = H = K^T·QQ·K + RR**（Hessian，对应 `matrix_m1`），用 CSC 稀疏格式传入；
- **q = g = K^T·QQ·E**（梯度，对应 `matrix_m2`）；
- **约束 A**：对 box 约束取单位阵（`CalculateEqualityConstraint` / `CalculateKernel` 等函数构造稀疏 CSC），使得 `l ≤ U ≤ u`；
- **l / u**：由 `lower_bound` / `upper_bound` 沿 horizon 堆叠（`setBounds`），分别对应 δ_f 与 Δa_x 的上下界。

构造流程关键函数（`mpc_osqp.cc`）：
1. `MpcOsqp(matrix_ad, matrix_bd, matrix_q, matrix_r, matrix_initial_state, lower_bound, upper_bound, lower_state_bound, upper_state_bound, horizon, max_iter, eps)` 构造；
2. `CalculateKernel()`：算 P = K^T·QQ·K + RR；
3. 计算梯度 q；
4. `CalculateEqualityConstraint()`：构造稀疏约束矩阵 Ac；
5. `setBounds()`：构造 l、u；
6. 转 CSC 格式后调用 OSQP 求解；
7. 取结果首段控制量返回。

求解器选择缘由：Apollo MPC 早期用 **qpOASES**，后替换为 **OSQP**——后者对大规模稀疏 QP 求解更快、接口更简洁（C 语言、可嵌入），且通过减少等式约束、利用 box 约束进一步提速。OSQP 在 Apollo 规划模块（参考线平滑、piecewise jerk 路径/速度优化）中也大量复用。

---

## 10. AuroraDrive 迁移建议

### 10.1 现状

AuroraDrive 当前横向控制采用 **PurePursuit（纯跟踪）** ——一种单点预瞄几何法：选取参考轨迹上前视距离处一个预瞄点，按自行车模型几何关系 `δ = atan(2·L·sin(α)/L_d)` 直接算出前轮转角。优点是实现极简、无模型依赖、低速稳定；缺点是：① 仅看单点、无未来多步预测；② 无显式约束；③ 对曲率突变/高速场景易振荡、稳态误差大；④ 横纵向完全解耦。

### 10.2 MPC 升级路线（建议分两阶段）

**Phase 1：LQR 验证（前置）**
- 先把 Apollo 横向 LQR（4 维误差模型 + 前馈 + 增益调度）在 AuroraDrive 上落地验证，跑通"动力学误差模型 → 离散化 → 黎卡提求解 K → u=-Kx + 前馈"全链路；
- 同步完成车辆参数辨识（见下），因为 MPC 与 LQR 共用同一套 A/B/C 矩阵，LQR 调通了 MPC 就成功一半；
- 此阶段不引入 QP 依赖，风险低、收益明确（已显著优于 PurePursuit）。

**Phase 2：MPC 升级**
1. **车辆参数辨识**：辨识 `m / Iz / Cf / Cr / lf / lr`。可用 Apollo 的车辆动力学云标定流程（`data_collection_table.pb.txt` + chirp 扫频/阶跃测试），或基于 CarSim/仿真 + 最小二乘辨识。Cf/Cr 侧偏刚度最关键也最难，建议从轮胎厂商数据起步再实测修正。
2. **引入 OSQP 依赖**：OSQP 为 C 语言、可嵌入式（header-only 化或静态链接），添加到 AuroraDrive 构建系统；封装 `MpcOsqp` 类（参考 Apollo `mpc_osqp.cc`），实现 P/q/l/u/A 的 CSC 构造。
3. **预测时域**：建议 **10–20 步**，ts 与控制周期一致（0.01–0.02s），即预测 0.1–0.4s。太短退化为 LQR，太长求解慢且远端预测失真。先 10 步起步，再按算力与效果调整。
4. **状态/控制量**：复用 Phase 1 的 6 维状态与 2 维控制（δ_f, Δa_x），横纵向耦合进同一 QP。
5. **约束**：先加 δ_f / Δa_x 的 box 约束（物理上下界），再逐步加转角速率约束（提升舒适性，需引入控制增量约束，Apollo 较弱、可改进）。
6. **增益调度**：按速度分 3–5 档（如 0–5 / 5–15 / 15–25 / >25 m/s）配置 Q/R，低速重循迹、高速重稳定。
7. **前馈**：保留曲率前馈 C·ψ̇_des，消除稳态横向偏差。
8. **安全兜底**：MPC 求解失败时回退到 Phase 1 的 LQR（或 PurePursuit），保证可用性。

### 10.3 代价 / 收益分析

**代价**
- 新增 OSQP 依赖与在线 QP 求解算力（horizon=10、状态 6 维、控制 2 维时 QP 规模约 20 维变量，OSQP 单次求解亚毫秒~毫秒级，可控）；
- 车辆参数辨识工作量（尤其 Cf/Cr）；
- 调参复杂度上升（Q/R/horizon/增益调度表）；
- 模型失配风险（线性化、小角度假设在急弯/低速大转角下偏差大）。

**收益**
- 循迹精度显著提升（多步预测 + 前馈，稳态误差趋零）；
- 控制平滑、乘客舒适（R 项 + 约束抑制抖动与 jerk）；
- 显式约束保证物理可行、安全；
- 横纵向耦合更贴近真实动力学，高速稳定性改善；
- 为后续 NMPC / 学习增强控制打下基础。

**结论**：建议 AuroraDrive **先 LQR 后 MPC** 两步走。PurePursuit → LQR 是高性价比的第一步（低风险、明显收益）；LQR 稳定后再上 MPC，把横纵向耦合、约束、多步预测的收益吃满。MPC 不应作为第一步，因其依赖动力学模型与 QP 求解器，在参数辨识与 LQR 验证未完成前风险过高。

---

## 附：关键代码索引

| 文件 | 关键内容 |
|------|----------|
| `modules/control/controllers/mpc/mpc_controller.cc` | `Init()`（加载 conf、矩阵初始化、增益调度表、滤波器）、`ComputeControlCommand()`（误差计算、矩阵更新、前馈、约束、调 OSQP、输出方向盘/加速度）、`UpdateMatrix()`（A 离散化） |
| `modules/control/controllers/mpc/mpc_osqp.cc` | `MpcOsqp` 类：`CalculateKernel`（P=K^T·QQ·K+RR）、梯度 q、`CalculateEqualityConstraint`（稀疏 Ac）、`setBounds`（l/u）、CSC 转换、OSQP 调用 |
| `modules/control/controllers/mpc/mpc_controller.h` | `MPCController` 类声明、`matrix_a_/matrix_ad_/matrix_b_/matrix_c_/matrix_q_/matrix_r_/matrix_state_` 等成员 |
| `modules/control/conf/control_conf.pb.txt` | `active_controllers` / 控制器类型切换（启用 MPC） |
| `modules/control/proto/MPCControllerConf` | horizon、ts、Q/R、增益调度表、约束上下界等配置 |

---

## 参考资料

- ApolloAuto/apollo 源码 `modules/control/controllers/mpc/`、`modules/common/math/mpc_osqp.cc`
- Rajamani《Vehicle Dynamics and Control》2.5 *Dynamic Model in Terms of Error with Respect to Road*（P37）
- OSQP 官方文档 https://osqp.org/docs/solver/index.html （QP 标准式与 ADMM 算法）
- CSDN 多篇 Apollo MPC 代码解析（mpc_osqp.cc、mpc_controller 解析、MPC OSQP Solver、横纵向耦合控制学习笔记、横向控制 LQR 原理、MPC 与 LQR 比较、Coursera Vehicle Lateral Control 等）

---

> 本报告基于 WebSearch + WebFetch 对 Apollo 源码解析、OSQP 文档、Rajamani 车辆动力学模型及多篇社区技术文章的深度调研整理。
> 实际内部工具调用次数：约 53 次（WebSearch ×31、WebFetch ×20、Read ×2；含少量失败重试）。
