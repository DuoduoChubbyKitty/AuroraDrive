# 百度 Apollo 速度规划（Piecewise Jerk Speed Optimizer）深度研究报告

> 研究对象：Apollo 6.0 / 9.0 / 10.0 Planning 模块的速度规划子系统
> 核心算法：ST 图 + DP 速度决策 + Piecewise Jerk QP/NLP 速度优化
> 求解器：OSQP（QP 版）、IPOPT（NLP 版）

---

## 0. 总体架构：DP + QP/NLP 两段式

Apollo 的速度规划采用经典的"**先决策开辟凸空间，再优化平滑**"两段式架构：

1. **DP（Dynamic Programming）阶段**：在 ST 图上以网格搜索得到一条粗略的、非凸问题转化后的 ST 曲线。它的核心目的不是得到最终速度，而是 **开辟一个凸的可行驶走廊（convex drivable corridor）**，并给出对每个障碍物的纵向决策（overtake / yield / follow / stop / ignore）。
2. **QP / NLP 优化阶段**：在凸走廊内，用数值优化方法（OSQP / IPOPT）求解出一条平滑、舒适、满足运动学约束的最终 ST 曲线，再对时间求导得到 v(t)、a(t)、jerk(t)。

> 口诀："DP 给粗解开辟凸空间，OSQP/IPOPT 做优化平滑。"

Apollo 之所以把横纵向解耦（路径规划处理静态环境，速度规划处理动态环境），是因为分开后每一维都可以构造为凸优化问题，求解稳定、实时性好。代价是横纵向耦合（如大曲率处必须减速）需要通过"曲率惩罚项"软约束来近似。

---

## 1. ST 图（S-T Graph）

### 1.1 s-t 图定义

Apollo 的速度规划坐标系是 **ST 坐标系**：

- **s 轴**：沿"路径规划输出的路径"方向的纵向位移（注意：速度规划的 s 是 path 上的 s，而路径规划的 s 是 reference line 上的 s，二者起点/方向可能不同）。
- **t 轴**：时间，从当前规划起点 t=0 向未来延伸（典型规划时域 8s）。

自车在 ST 平面上对应一条 **单调非递减** 的曲线 s(t)：随时间推移只能前进或停滞（不能倒车），曲线上每点 (t, s(t)) 对应一个未来时刻自车在路径上的纵向位置。该曲线的斜率即车速 ṡ = ds/dt。

### 1.2 障碍物在 ST 图的占据区

对每个障碍物，依据其预测轨迹（动态）或静态位置，将其在自车路径上的"碰撞时间窗"投影到 ST 平面，得到一个 **ST 占据区（ST Boundary）**。该占据区由上下两条折线围成：

- **lower_points**：障碍物在 ST 图上"占据区的下边界"（较小的 s）；
- **upper_points**：障碍物在 ST 图上"占据区的上边界"（较大的 s）。

`STObstaclesProcessor::ComputeObstacleSTBoundary()` 完成该映射。其本质是：对障碍物在每一时刻 t 的预测包围盒，求其与自车路径的"碰撞 s 区间"，沿 t 累积即得到一个二维带状区域。

- **静态障碍物**：占据区是垂直矩形带（s 几乎不变，t 跨越整个预测时域），表现为一条竖直条带；
- **动态障碍物**：占据区是斜带（随 t 增大，s 也变化），表现为一条倾斜带状区域。

### 1.3 ST 边界（上界 / 下界）

可行驶走廊被定义为：对每一时刻 t，自车 s 必须落在 [s_min(t), s_max(t)] 区间内。

- **s_max(t)（上界）**：自车不能"冲过头"撞上前方的 yield/follow/stop 障碍物；
- **s_min(t)（下界）**：自车不能"落后太多"被后方 overtake 障碍物追上，也不能低于运动学可达下界。

上界/下界由三类约束融合得到：

1. **车辆运动学约束**（driving_limits）：由当前 v、最大加/减速度推导的物理可达 s 范围：
   ```
   s_max(t) = s0 + v0·t + 0.5·a_max·t²
   s_min(t) = s0 + v0·t + 0.5·a_min·t²   （a_min < 0）
   ```
2. **参考速度引导**（st_guide_line）：以期望速度匀速行驶得到的引导线。
3. **障碍物占据约束**：把障碍物 ST 占据区"挖掉"后剩下的可通行区间。

最终输出的 `Drivable_st_boundary`（可行驶 ST 边界）是后续 DP 与 QP 的共同输入。

### 1.4 速度规划在 ST 空间的搜索

速度规划的本质，就是在 ST 平面内、在可行驶走廊内、在满足运动学（加减速、限速）的前提下，搜索一条 **代价最低** 的 s(t) 曲线。由于障碍物决策（overtake 还是 yield）会让问题变成非凸（走廊可能有多段、有上下分支），因此 Apollo 先用 DP 在离散网格上搜索出一条粗解把非凸转凸，再用 QP/NLP 在凸空间内连续优化。

---

## 2. DP Speed（SPEED_HEURISTIC_OPTIMIZER）

### 2.1 ST 图采样

DP 在 `GriddedPathTimeGraph` 内对 ST 平面离散化：

- **t 方向等间隔**：`unit_t = 1.0` s；
- **s 方向先密后疏**：近处密（`dense_unit_s = 0.1` m，`dense_dimension_s = 101` 个点），远处疏（`sparse_unit_s = 1.0` m）。原因是近处需要更高规划精度，远处可牺牲精度换效率。

离散后形成 `CostTable`（dimension_t 列 × dimension_s 行），每个节点是一个 `StGraphPoint` 状态变量。

### 2.2 状态变量与代价函数

每个 `StGraphPoint` 保存：
- 当前栅格位置 `point_`；
- 前驱节点 `pre_point_`；
- `reference_cost_`（偏离参考速度）、`obstacle_cost_`（与障碍物距离）、`spatial_potential_cost_`（空间推进惩罚）、`total_cost_`（总代价）、`optimal_speed_`。

**状态转移方程**：

```
f(P) = min { f(R) + w(R→P) }
```

其中 R 是上一时刻所有可达节点，P 是当前节点，w(R→P) 是从 R 转移到 P 的边代价。可达性由最大加/减速度限定（`max_acceleration=2.0`、`max_deceleration=-4.0`，即 `GetRowRange`）。

边代价 `w(R→P)` 由 `CalculateEdgeCost` 计算，包含三部分：

1. **C_speed（速度代价）**：偏离参考速度（巡航车速）的惩罚，超速惩罚 `exceed_speed_penalty=1e3`，低速惩罚 `low_speed_penalty=10`；
2. **C_acc（加速度代价）**：`accel_penalty`/`decel_penalty`，鼓励平滑加减速；
3. **C_jerk（加加速度代价）**：`positive_jerk_coeff=1.0`，`negative_jerk_coeff=1.0`（换道时为 300），保证舒适度。

此外节点本身代价包含：
- `GetObstacleCost`：若节点落在障碍物占据区内，赋大值 `default_obstacle_cost=1e4`（实际 1e10）以避开；
- `GetSpatialPotentialCost`：`spatial_potential_penalty=1e2`，鼓励在时间维度上尽量往前推进（min-time traversal）。

### 2.3 粗速度曲线输出

`Search()` 的四步：
1. `InitCostTable()`：构建代价表；
2. `InitSpeedLimitLookUp()`：构建限速查询表；
3. `CalculateTotalCost()`：自底向上逐列计算所有节点总代价（动态规划核心）；
4. `RetrieveSpeedProfile()`：从终点回溯前驱，得到粗略 ST 曲线（speed_profile），并输出 `SpeedData`。

该粗解有两个作用：① 给出每个障碍物的纵向决策标签；② 作为 QP/NLP 的参考曲线 `s_ref(t)` 与 warm start。

> 需注意：若 ST boundary 包含原点 (0,0)（即起步即碰撞），DP 直接输出全零速度曲线（fallback stop）。

---

## 3. Piecewise Jerk Speed Optimizer（Apollo 9.0 核心）

Apollo 把纵向运动建模为 **三阶等 jerk 系统**：每个时间区间 [t_i, t_{i+1}] 内 jerk（加加速度，s 的三阶导）恒定，因此 s(t) 在区间内是 **三次多项式**，从而保证：
- jerk 分段恒定；
- 加速度 s̈ 一阶连续；
- 速度 ṡ 二阶连续；
- 位移 s 三阶连续。

这一建模同时用于 QP 版与 NLP 版，区别仅在于约束是否线性。

### 3.1 QP 版（piecewise_jerk_speed_optimizer，OSQP 求解）

#### 3.1.1 优化变量

对时间 t 等间隔 Δt 采样（典型 Δt=0.1s，n≈80 点），每个时刻取三个状态作为优化变量：

```
x = [s_0, s_1, …, s_{n-1},  ṡ_0, ṡ_1, …, ṡ_{n-1},  s̈_0, s̈_1, …, s̈_{n-1}]^T ∈ R^{3n}
```

由 jerk 恒定可得区间递推关系（连续性等式约束的基础）：

```
jerk_i = (s̈_{i+1} - s̈_i) / Δt
ṡ_{i+1} = ṡ_i + s̈_i·Δt + 0.5·jerk_i·Δt²
s_{i+1} = s_i + ṡ_i·Δt + 0.5·s̈_i·Δt² + (1/6)·jerk_i·Δt³
```

#### 3.1.2 目标函数

设计目标（每项都用平方形式，保证是二次型）：

- 贴合 DP 参考位移：`|s_i - s_{i-ref}|↓`
- 贴合巡航参考速度：`|ṡ_i - v_{i-ref}|↓`
- 降低加速度、jerk：`|s̈_{i+1}|↓`、`|jerk_i|↓`
- 转弯减速（曲率惩罚）：`|p_i·ṡ_i|↓`，其中 p_i 是由路径曲率算出的权重；
- 末端惩罚：末端 s、v、a 趋近期望值。

完整目标函数（去掉常数项后）：

```
cost = Σ_{i=0}^{n-1} [ w_s·(s_i - s_{i-ref})²
                     + (w_v + p_i)·(ṡ_i - v_{i-ref})²
                     + w_a·s̈_i²
                     + w_j·( (s̈_{i+1} - s̈_i)/Δt )² ]
     + w_{s-end}·(s_{n-1} - s_{end-s})²
     + w_{v-end}·(ṡ_{n-1} - ṡ_{end-s})²
     + w_{a-end}·(s̈_{n-1} - s̈_{end-s})²
```

展开并合并同类项（绿色为可丢弃的常数项）：

```
cost = Σ_{i=0}^{n-2} w_s·s_i²  + (w_s + w_{s-end})·s_{n-1}²
     - Σ_{i=0}^{n-1} 2·w_s·s_i·s_{i-ref}  - 2·w_{s-end}·s_{n-1}·s_{end-s}
     + Σ_{i=0}^{n-2} (w_v + p_i)·ṡ_i²  + (w_v + p_{n-1} + w_{v-end})·ṡ_{n-1}²
     - Σ_{i=0}^{n-1} 2·(w_v + p_i)·v_ref·ṡ_i  - 2·w_{v-end}·ṡ_{n-1}·ṡ_{end-s}
     + Σ_{i=0}^{n-2} (w_a + 2·w_j/Δt²)·s̈_i²  + (w_a + w_{a-end} + w_j/Δt²)·s̈_{n-1}²  - (w_j/Δt²)·s̈_0²
     + Σ_{i=0}^{n-2} (-2·w_j/Δt²)·s̈_{i+1}·s̈_i  - 2·w_{a-end}·s̈_{n-1}·s̈_{end-s}
```

#### 3.1.3 约束条件

**不等式约束（边界条件）**：每个时刻 s、v、a、jerk 上下界：

```
s_lower(t_i) ≤ s_i ≤ s_upper(t_i)        // ST boundary（由决策确定的 s 边界）
0 ≤ ṡ_i ≤ v_max(s_i)                      // 速度下限 0，上限为对应 s 处限速
a_min ≤ s̈_i ≤ a_max                       // [-6, 2] m/s²
jerk_min ≤ jerk_i ≤ jerk_max               // [-2, 4] m/s³
```

**等式约束 1（连续性约束）**：相邻时刻满足 jerk 恒定递推：

```
s̈_{i+1} - s̈_i = jerk_i·Δt
ṡ_{i+1} - ṡ_i - 0.5·(s̈_i + s̈_{i+1})·Δt = 0
s_{i+1} - s_i - ṡ_i·Δt - (1/3)·s̈_i·Δt² - (1/6)·s̈_{i+1}·Δt² = 0
```

**等式约束 2（规划起点）**：第一点等于初始状态 (s_0, v_0, a_0)。

#### 3.1.4 OSQP 标准形式与矩阵构造

转化为 OSQP 标准形式：

```
min  ½·x^T·P·x + q^T·x
s.t. l ≤ A·x ≤ u
```

代码中 `PiecewiseJerkSpeedProblem` 通过三个函数构造：
- `CalculateKernel()` → 构造 **P 矩阵**（对称半正定，由上述二次项系数组装，对角块为 w_s / (w_v+p_i) / (w_a+2w_j/Δt²)，相邻 s̈ 间有 -2w_j/Δt² 的耦合项）；
- `CalculateOffset()` → 构造 **q 向量**（由 -2w_s·s_ref 等线性项组装）；
- `CalculateAffineConstraint()` → 构造 **A 矩阵**与 l/u（边界 + 连续性 + 起点）。

`PIECEWISE_JERK_SPEED_OPTIMIZER::Process` 主流程：
1. 以 0.1s 间距创建优化空间；
2. 初始化 a/jerk 边界、参考速度（巡航车速）；
3. 根据决策结果计算每个时刻的 s 边界（ST boundary）；
4. 用 DP 粗解插值出每个时刻的参考 s 位置 `s_ref`；
5. 用参考 s 在 path 上插值出曲率，算出曲率惩罚系数 p_i（实现转弯减速）；
6. 查限速表得到每个 s 处的 v_max；
7. 调用 `piecewise_jerk_problem.Optimize()` → OSQP 求解；
8. 输出 s_i 序列，求导得 v、a。

### 3.2 NLP 版（piecewise_jerk_speed_nonlinear_optimizer，IPOPT 求解）

#### 3.2.1 为什么需要 NLP（QP 的固有缺陷）

QP 版存在两个本质问题：

1. **曲率惩罚 p_i 是 t 的函数，但实际曲率 κ 是 s 的函数**。QP 把"关于 s 的曲率惩罚"借由 DP 粗解近似转化为"关于 t 的惩罚"。当 QP 平滑后的曲线与 DP 粗解接近时惩罚位置正确；当二者偏差较大时，实际惩罚区间（应惩罚 [S1,S2]）与 QP 施加惩罚的区间 [T1,T2] 错位，导致转弯减速不精确。
2. **限速也是 s 的函数**。同样地，QP 只能通过 DP 转化为 t 的约束，使得速度上界不精确。

根本原因：限速/曲率都是 s 的函数，而 s 本身是待求优化量——这正是非凸/非线性来源。为精确表达 v_max(s)、κ(s)，Apollo 引入 NLP。

#### 3.2.2 NLP 问题建模

**优化变量**：除 s、ṡ、s̈ 外，额外引入两组松弛变量（避免求解失败）。

**目标函数**：在 QP 目标基础上，额外加入 **横向加速度惩罚** 与 **松弛变量惩罚**：

```
min  [ QP 各项 + w_lat·(ṡ_i²·κ(s_i))² + w_soft·(Σ slack_i²) ]
```

其中横向加速度 `a_lat = v²·κ = ṡ²·κ(s)`，因 κ 是 s 的函数，使该项成为非线性项。

**约束条件**：
- 优化变量上下界（含松弛变量）；
- **非线性约束函数 g(x)**：限速约束 `ṡ_i ≤ v_max(s_i)`（v_max 是 s 的分段函数，需先平滑成二阶可导）、曲率约束、连续性约束。

要求 f(x)、g(x) 均 **二次连续可微**（IPOPT 内点法要求）。

#### 3.2.3 前期准备（关键三步平滑）

由于 IPOPT 要求二阶可导，而 QP 路径求得的 κ(s)、地图限速 v_max(s) 既不连续也不可导，NLP 流程在 `SetUpStatesAndBounds` 阶段先做三件平滑：

1. **速度点集平滑（OptimizeByQP）**：先用 QP 求解一次，得到速度点集作为 NLP 的 warm start（初值）；
2. **道路曲率平滑**：对 path 采样，用分段多项式拟合 κ(s)，得到 s 关于 κ 的二阶可导关系；
3. **道路限速平滑**：把阶梯式限速曲线平滑成二阶可导曲线；
4. **参考曲线平滑**：对 s_ref 做平滑。

#### 3.2.4 IPOPT 求解接口

`PiecewiseJerkSpeedNonlinearOptimizer::OptimizeByNLP()` 创建 `PiecewiseJerkSpeedNonlinearIpoptInterface` 对象（继承自 Ipopt 的 `TNLP`），该接口需重写：

- `get_nlp_info()`：定义问题规模（变量数 n、约束数 m）；
- `get_bounds_info()`：定义变量与约束的上下界；
- `get_starting_point()`：提供初值（来自 QP warm start）；
- `eval_f()`：目标函数值；
- `eval_grad_f()`：目标函数梯度 ∇f；
- `eval_g()`：约束函数值 g(x)；
- `eval_jac_g()`：约束的雅可比矩阵 ∂g/∂x；
- `eval_h()`：拉格朗日函数的黑塞矩阵 ∇²_{xx}L = ∇²f + Σλ·∇²g（IPOPT 内点法核心）。

设置参数：s 上下界、path_curvature 与 speed_limit、warm_start、s_reference、各权重。求解后从 `x` 取出 s、ṡ、s̈ 序列。

> QP 与 NLP 的选择：配置文件中二选一（`PIECEWISE_JERK_SPEED_OPTIMIZER` 或 `PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER`），NLP 精度更高但耗时更长，Apollo 默认在需要精确曲率/限速约束时启用。

---

## 4. Task 链（以 LANE_FOLLOW 场景为例）

Apollo 的 PublicRoadPlanner 用"Scenario → Stage → Task"三级结构。LaneFollow 场景的 LANE_FOLLOW_DEFAULT_STAGE 按以下顺序串行调用 Task：

```
┌──────────────────────── 路径决策（横向）────────────────────────┐
│ 1. LANE_CHANGE_DECIDER      判断/处理换道                       │
│ 2. PATH_REUSE_DECIDER        路径复用决策                         │
│ 3. PATH_LANE_BORROW_DECIDER  借道决策                             │
│ 4. PATH_BOUNDS_DECIDER       路径边界生成（SL 边界）              │
│ 5. PIECEWISE_JERK_PATH_OPTIMIZER  路径 QP 优化                   │
│ 6. PATH_ASSESSMENT_DECIDER   路径评估                             │
│ 7. PATH_DECIDER              路径决策（选最优 path）              │
│ 8. RULE_BASED_STOP_DECIDER   规则停车决策（红绿灯/停止线）        │
└──────────────────────────────────────────────────────────────────┘
┌──────────────────────── 速度决策（纵向）────────────────────────┐
│ 9.  ST_BOUNDS_DECIDER            生成 ST 边界 + 障碍物初决策       │
│ 10. SPEED_BOUNDS_PRIORI_DECIDER  速度先验边界（DP 前）            │
│ 11. SPEED_HEURISTIC_OPTIMIZER    DP 速度启发式优化（粗速度曲线）   │
│ 12. SPEED_DECIDER                速度决策（overtake/yield/follow）│
│ 13. SPEED_BOUNDS_FINAL_DECIDER   速度最终边界（决策后精修）        │
│ 14. PIECEWISE_JERK_SPEED_OPTIMIZER (QP)  或                       │
│     PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER (NLP)  速度优化      │
│ 15. RSS_DECIDER                  RSS 安全决策兜底                 │
└──────────────────────────────────────────────────────────────────┘
```

**数据流（文字流程图）**：

```
path_data(横向路径)
        │
        ▼
[ST_BOUNDS_DECIDER] ── 障碍物 → ST 占据区 ──► Drivable_st_boundary (粗)
        │                                          │
        ▼                                          ▼
[SPEED_BOUNDS_PRIORI_DECIDER] ── 加载 ST bounds + 限速 ──► st_graph_data
        │                                          (供 DP 使用的速度上下界)
        ▼
[SPEED_HEURISTIC_OPTIMIZER] ── DP 网格搜索 ──► 粗速度曲线 speed_data + s_ref
        │
        ▼
[SPEED_DECIDER] ── 基于粗速度曲线对每个障碍物打纵向标签
        │              (STOP/YIELD/FOLLOW/OVERTAKE/IGNORE)
        ▼
[SPEED_BOUNDS_FINAL_DECIDER] ── 按决策重新计算 ST 占据区 + 精修限速
        │                                          ──► 凸的可行驶 ST 走廊
        ▼
[PIECEWISE_JERK_SPEED_OPTIMIZER (OSQP) / NONLINEAR (IPOPT)]
        │
        ▼
   平滑速度曲线 s(t), v(t), a(t)  →  结合 path → 最终 TrajectoryPoint
```

### 4.1 各速度 Task 职责

- **ST_BOUNDS_DECIDER**：将障碍物映射到 ST 图（`MapObstaclesToSTBoundary`），对不影响纵向规划的设 IGNORE，给每个 boundary 一个粗决策，输出初始 `Drivable_st_boundary`。
- **SPEED_BOUNDS_PRIORI_DECIDER**（先验，DP 之前）：把规划路径上障碍物的 ST bounds 加载到 ST 图，并生成路径限速信息。此时边界较粗，仅服务 DP 搜索。
- **SPEED_HEURISTIC_OPTIMIZER**：DP 速度启发式优化，输出粗速度曲线。
- **SPEED_DECIDER**：基于粗速度曲线对每个障碍物做精细纵向决策。
- **SPEED_BOUNDS_FINAL_DECIDER**（最终，决策之后）：依据 SpeedDecider 给出的决策（如某障碍物判 follow），重新计算 ST 占据区（follow 时自车 s 必须在障碍物后方某距离），并精修限速，输出供 QP/NLP 使用的凸走廊与速度上下界。
- **PIECEWISE_JERK_SPEED_OPTIMIZER**：QP 速度优化。
- **PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER**：NLP 速度优化（精度更高）。

> priori 与 final 的区别：priori 在 DP 之前、边界粗（开辟搜索空间）；final 在决策之后、边界精（按确定决策收紧走廊，保证 QP 在凸可行域内优化）。

---

## 5. 速度决策 SpeedDecider

### 5.1 决策类型与优先级

纵向决策类型（`pnc::ObjectDecisionType`）：`IGNORE / STOP / FOLLOW / YIELD / OVERTAKE`。

**纵向决策优先级**（高 → 低）：

```
stop > yield >= follow > overtake > ignore
```

横向（参考）：`nudge > ignore`。`ignore` 是最不安全的状态，表示未对障碍物采取任何已知行为。

### 5.2 决策算法

`SpeedDecider::Process` 对每个障碍物遍历：

1. 取 `mutable_obstacle->path_st_boundary()`；
2. 按障碍物 ST boundary 的时间/位置分布判断是否可忽略（自身后方动态障碍物忽略）；
3. 虚拟障碍物若不在 reference line 车道上则跳过；
4. 行人 → 强制 STOP（`CheckStopForPedestrian`）；
5. `GetSTLocation()` 判断障碍物在 ST 图上相对自车的位置关系：
   - **BELOW**（障碍物在自车下方/后方）→ OVERTAKE；
   - **ABOVE**（障碍物在自车上方/前方）→ YIELD / FOLLOW；
   - **AROUND / CROSS**（自车正处于障碍物占据区）→ 已晚，回退 STOP；
6. `CheckIsFollow()`：障碍物在前方且自车将长期跟随 → FOLLOW（保持安全时距）；
7. `CheckKeepClearCrossable / CheckKeepClearBlocked`：禁停区是否可穿越；
8. 若无纵向决策结果，置 `IGNORE`。

最终通过 `MakeObjectDecision` 把决策写入 obstacle，供 SPEED_BOUNDS_FINAL_DECIDER 收紧边界。

### 5.3 与 Path 决策的协同

- 路径决策（PATH_DECIDER）先选出最优 path（含横向避让 nudge）；
- ST 图基于该 path 构建——因此 path 决策已隐含"绕到哪条横向通道"；
- SpeedDecider 在 path 固定后，仅决定纵向"何时到、跟多远、让不让"，二者解耦但顺序耦合（path 先、speed 后）。
- 横向 nudge 决策会改变障碍物是否影响纵向（nudge 后该障碍物可能从纵向影响变为可忽略）。

---

## 6. ST 边界生成 StBoundsDecider

### 6.1 主流程

`STBoundsDecider::Process()`：

1. `InitSTBoundsDecider()`：
   - 初始化 `st_obstacles_process_`；
   - `MapObstaclesToSTBoundary()`：基于优化后的 path 构建 ST 图。遍历障碍物，`ComputeObstacleSTBoundary()` 计算 lower/upper points（注：此处分辨率较粗，碰撞校验不精确）；静态障碍物标 `is_caution_obstacle`；动态障碍物与低路权区匹配确定 `obs_caution_end_t`；
   - 用 `STBoundary::CreateInstanceAccurate` 构造 boundary；
   - 找到最近静态障碍物存入 `closest_stop_obstacle`；忽略自车身后动态障碍物；
   - 未加入 ST 图的障碍物纵向/横向决策设为 IGNORE；
   - 用 `IsPathPointAwayFromObstacle`（向量点乘/叉乘）做精细碰撞校验；
   - 初始化启发式 `st_guide_line_`（desired_speed=15.0）与运动学 `st_driving_limits_`（max_acc=2.5, max_dec=5.0, max_v=desired_speed×1.5）。

2. `GenerateRegularSTBound`：生成常规可通行 st_bound 与 vt_bound，逐 t：
   - 用 `st_driving_limits_`（运动学）更新 s_lower/s_upper；
   - 用障碍物 ST boundary 约束更新可通行 s 与决策（`GetBoundsFromDecisions` / `GetSBoundsFromDecisions`）。

3. `GetSBoundsFromDecisions()`（核心）：
   - 维护 `obs_t_edges_`（每个障碍物首尾 t 边，按 t 排序，扫描线 sweep-line）；
   - 对新进入障碍物判断明确/模糊决策：
     - 障碍物下界 ≥ s_max → 明确 YIELD；
     - 障碍物上界 ≤ s_min → 明确 OVERTAKE；
     - 否则模糊，进 `ambiguous_t_edges`；
   - `FindSGaps()` 在模糊障碍物间寻找可通行 s 间隙；
   - `DetermineObstacleDecision()`：按可通行 gap 中点相对障碍物 s 区间的位置，决定每个障碍物 overtake 还是 yield；
   - 输出 `available_s_bounds` 与 `available_obs_decisions`。

4. `RemoveInvalidDecisions()`：依据自车运动学约束剔除不可达决策。

5. `GenerateFallbackSTBound`：常规失败时的兜底边界。

### 6.2 上下界计算与占据区映射

- **上界 s_max(t)**：min(运动学上界, yield/follow/stop 障碍物下界)；
- **下界 s_min(t)**：max(运动学下界, overtake 障碍物上界)；
- 障碍物占据区映射本质：把障碍物在 path 上的"碰撞 s 区间 × 碰撞 t 区间"投影为 ST 平面带状区，按决策 overtake（自车 s 须 > 障碍物 s_max）或 yield（自车 s 须 < 障碍物 s_min）转化为对 s_min/s_max 的约束。

---

## 7. AuroraDrive 迁移建议

### 7.1 AuroraDrive 现状与问题

- **当前速度控制**：PID 单环 + 固定时距安全距离
  ```
  safe_dist = max(5, front_speed/3.6 * 2)   // 单位：m，front_speed 单位 km/h
  ```
- **问题**：跟车时突兀减速 / 加速。根因：
  1. 安全距离仅与前方车速线性相关，未考虑自车车速、相对速度、加减速可行性，导致目标距离阶跃；
  2. PID 单环对阶跃目标距离直接响应，缺乏对未来速度曲线的预判与平滑，造成 jerk 大、体感差；
  3. 无 ST 概念，无法表达"何时到何地"的时空联合决策，遇前车变速时只能被动滞后反应。

### 7.2 简化版 ST-DP 速度规划设计

借鉴 Apollo，但大幅裁剪复杂度，适配 AuroraDrive 算力与场景：

#### (1) ST 图离散化

- s 轴：自车前方 0~80m，近处密（0.5m）远处疏（2m）；
- t 轴：0~6s，等间隔 0.5s（共 13 列）；
- 障碍物占据区：仅对前方主跟车目标 + 1~2 个关键动态障碍物构建 ST 带状区（动态用预测轨迹投影，静态为竖带）。其他障碍物用保守安全距离软约束。

#### (2) 速度上下界（凸走廊）

- s_max(t) = min( 匀速可达上界 , 前车 yield 边界 = 前车预测 s(t) - safe_gap )；
- s_min(t) = 运动学下界（max_decel 限制）；
- v_max(t) = min( 道路限速 , 前车预测速度 + 容忍 )。

#### (3) DP 搜索（轻量）

状态 = (t_i, s_j)；状态转移：
```
f(t_i, s_j) = min_{s_k 可达} { f(t_{i-1}, s_k) + EdgeCost(s_k→s_j) }
```
EdgeCost = `w_v·(v - v_ref)² + w_a·a² + w_j·jerk² + w_obs·ObstacleCost`
- `ObstacleCost`：落在占据区内大值惩罚；
- `v_ref`：巡航车速或前车速度（跟车场景）；
- 可达性：由 max_acc/max_dec 限定 s_k 范围。

回溯得到粗 s(t)，再对时间求导得粗 v(t)。

#### (4) 输出平滑（可选 QP 或简单滤波）

- 轻量版：对粗 v(t) 做 3 点滑动平均 + 限 jerk 滤波，输出平滑速度序列；
- 进阶版：用 Apollo 同款 piecewise jerk QP（OSQP）在凸走廊内优化，变量 [s, v, a]，目标含 (v-v_ref)² + a² + jerk²，约束含 s/v/a 上下界 + 连续性。
- 最终输出 v_cmd(t) → 下发 PID/底层控制。

#### (5) 接口与回退

- 上游输入：自车状态 + 前车相对距离/速度（来自感知）+ 限速；
- 下游输出：平滑目标速度序列（或当前时刻目标速度 + 加速度）；
- 回退：DP 失败时退回现有 `safe_dist` + PID，保证安全。

### 7.3 代价 / 收益分析

| 维度 | 代价 | 收益 |
|------|------|------|
| 算力 | 增加 ST 离散网格 DP（13×~40 点，单帧 <1ms 级）+ 可选 OSQP（~1ms） | 远低于完整 Apollo（80 点 0.1s）|
| 内存 | CostTable ~0.5KB | 可忽略 |
| 工程量 | ST 构图 + DP + 滤波/QP 约 300~600 行 C++；需调权重 | 中等，可分阶段上线 |
| 平顺性 | — | DP 预判前车变速，目标距离连续过渡，消除阶跃；QP 进一步保证 jerk 约束，跟车减速/加速自然 |
| 安全性 | — | s_max 受运动学 + 前车 yield 双重约束，避免"目标距离突变导致急刹" |
| 可解释 | — | ST 图直观可视，便于调参与回归 |
| 风险 | DP 凸化不充分时 QP 可能无解 | 保留现有 safe_dist+PID 作为回退兜底 |

**结论**：AuroraDrive 的"跟车突兀"根因是缺乏时空联合预判与平滑。引入轻量 ST-DP（仅主跟车目标建模 + 小网格 DP + 滤波/QP）即可在毫秒级代价下显著改善体感，且可平滑灰度上线（DP 失败回退 PID）。建议第一步先上"ST 构图 + DP + 滑动平均滤波"，验证体感后再引入 OSQP QP。

---

## 8. 关键结论速览

1. **ST 图** 是 Apollo 速度规划的统一表达：障碍物占据区 → 可行驶走廊 → 在其内搜索 s(t)。
2. **DP（SPEED_HEURISTIC_OPTIMIZER）** 的核心价值是 **非凸→凸的转化**：给出粗解与障碍物纵向决策，开辟凸走廊，而非最终速度。
3. **Piecewise Jerk QP（OSQP）**：变量 [s,v,a]，jerk 分段恒定，目标含 s/v/a/jerk 平方 + 曲率惩罚 + 末端惩罚，约束含边界 + 连续性 + 起点。速度快、工程默认。
4. **Piecewise Jerk NLP（IPOPT）**：解决 QP 中"曲率/限速是 s 的函数却按 t 施加"的不精确问题，引入非线性约束 `a_lat=v²·κ(s)`、`v≤v_max(s)`，需先对 κ(s)、限速、参考做二阶可导平滑，用 QP 解作 warm start。精度更高、耗时更长。
5. **Task 链**：ST_BOUNDS_DECIDER → SPEED_BOUNDS_PRIORI → DP → SPEED_DECIDER → SPEED_BOUNDS_FINAL → QP/NLP，先验边界（粗）与最终边界（精）分别服务 DP 与 QP。
6. **SpeedDecider** 决策优先级 stop > yield >= follow > overtake > ignore，依据障碍物在 ST 图相对自车位置（BELOW/ABOVE/AROUND）判 overtake/yield。
7. **StBoundsDecider** 用扫描线（sweep-line）算法 `GetSBoundsFromDecisions` 在多障碍物间寻找可通行 s 间隙，并用运动学约束剔除不可达决策。
8. **AuroraDrive** 可用"ST 构图 + 轻量 DP + 滤波/QP"以毫秒级代价解决跟车突兀问题，保留现有 PID 作回退。

---

## 参考资料（主要来源）

- Apollo 9.0 速度二次规划算法 – piecewise jerk speed optimizer（WaiNgai1999）
- Apollo 9.0 速度非线性规划算法 – piecewise jerk speed nonlinear optimizer Ⅰ/Ⅱ（WaiNgai1999）
- Apollo6.0 StBoundsDecider 流程与代码解析（xl_courage）
- Apollo Planning 决策规划算法代码详细解析 (15)(19)(20)(22)（自动驾驶Player / nn243823163）
- Apollo 学习笔记 TASK 系列：SPEED_BOUNDS_PRIORI&FINAL / SPEED_HEURISTIC_OPTIMIZER / SPEED_DECIDER / PIECEWISE_JERK_SPEED / PIECEWISE_JERK_NONLINEAR_SPEED（sinat_52032317）
- Apollo 速度规划 DP+QP 综述（51CTO / 自动驾驶之心）
- Baidu Apollo 代码解析之 EM Planner 中的 DP Speed Optimizer（linxigjs）
- Apollo - PIECEWISE_JERK_SPEED_OPTIMIZER 数学原理（Martin248890）
- Piecewise Jerk Speed 论文以及代码解析（hebastast / HE19930303）
- Apollo 10.0 Public Road Planner 详解（ring12345677）
- Apollo 源码：modules/planning/tasks/optimizers/、modules/planning/math/piecewise_jerk/

---

> 本报告实际工具调用次数：56 次（含 WebSearch 20 次 / WebFetch 17 次 / Read 8 次 / RunCommand 2 次 / Write 1 次 / TodoWrite 1 次 / 其他 7 次；含若干超时与受工作区限制的 Read）。文件统计：17995 字符、532 行。
