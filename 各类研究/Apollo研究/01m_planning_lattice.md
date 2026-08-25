# Apollo Lattice Planner 算法实现深度研究报告

> 研究对象：Moritz Werling 2010 论文《Optimal Trajectory Generation for Dynamic Street Scenarios in a Frenet Frame》及其在 Baidu Apollo 5.0→6.0→9.0 中的源码实现（`modules/planning/planners/lattice/`）
> 研究目的：为 AuroraDrive 仿真系统从 "A* + Pure Pursuit" 升级到"参考线 + 多项式采样"规划栈提供 Lattice Planner 算法级参照与简化迁移方案
> 撰写日期：2026-07-23
> 研究方法：WebSearch + WebFetch 对 Werling 论文、Apollo 官方仓库源码、CSDN 源码解析系列进行 50+ 次深度挖掘，含直接拉取 `lattice_planner.cc` 真实源码

---

## 0. 摘要

Apollo Lattice Planner 是百度面向**高速结构化道路**的实时运动规划算法，源自 BMW 学者 Moritz Werling 2010 年在 ICRA 发表的 Frenet 帧最优轨迹生成方法。它以"**横纵向同时采样终端状态 + 多项式解析连接 + 代价函数择优**"为核心范式：在 Frenet（s 纵向 / l 横向）坐标系下，对横向目标 l 用**五次多项式**、对纵向巡航用**四次多项式**、对跟车/停车用**五次多项式**解析生成轨迹束，横纵向轨迹两两自由组合后，用统一的代价函数（纵向目标偏离 + 纵向 jerk + 纵向碰撞 + 向心加速度 + 横向偏移 + 横向舒适性）打分并排序，再依次取出做碰撞检测，返回第一条无碰撞且满足运动学约束的轨迹。与 EM Planner 的"横纵向解耦 + DP/QP 交替"相比，Lattice 参数少、流程简单、单周期 < 50ms，但轨迹形状固定、对复杂城市场景适应性弱。Apollo 6.0 后默认采用 PublicRoadPlanner（EM 形态），Lattice 作为备选规划器共存，高速 lane_follow 场景下仍可用。本报告系统梳理 Lattice 的论文要点、Frenet 数学、采样策略、多项式推导、代价函数公式、源码 7 步流程与关键类，并针对 AuroraDrive 当前"A* 输出 waypoint + Pure Pursuit 跟随"方案给出"只保留横向五次多项式 + 纵向巡航"的简化版 Lattice 设计与代价/收益分析。

---

## 1. 论文要点（Werling 2010）

### 1.1 论文出处与定位

原始论文《Optimal Trajectory Generation for Dynamic Street Scenarios in a Frenet Frame》（Moritz Werling, Julius Ziegler, Sören Kammel, Maximilian Werling, ICRA 2010, ResearchGate Publication 224156269）是 Frenet 坐标系下高速场景运动规划的奠基性工作。其目标是**解决高速公路动态场景与市中心交通堵塞下的轨迹生成问题**，提出一种 **semi-reactive 轨迹生成方法**，能与行为决策层（behavioral layer）耦合，长期实现速度保持、汇入车道、跟车、停车、反应式避障等任务。

### 1.2 核心贡献

论文的核心贡献有三：

1. **Frenet 坐标系建模**：将笛卡尔（Cartesian, SE(2)）下的轨迹规划问题投影到以参考线（center line）为基线的 Frenet 坐标系（s, d），其中 s 沿参考线纵向累积里程，d 为横向偏移。在 Frenet 系下，横向和纵向可以独立优化，且具有 SE(2) 上的不变跟踪性能（invariant tracking performance），便于与跟踪控制结合。
2. **jerk 最优的多项式连接**：证明在给定初始状态 [p₀, ṗ₀, p̈₀] 和终端状态 [p₁, ṗ₁, p̈₁] 的边界条件下，最小化 jerk 平方积分 `J_t = ∫ p⃛(t)² dt` 的解恰为**五次多项式**；当终端位置不约束（如巡航只需指定速度）时退化为**四次多项式**。
3. **横纵向同时采样 + 组合择优**：不同于 EM Planner 的横纵向解耦，论文在 Frenet 系下对横向 d 和纵向 s 各自采样终端状态（d_i, T_j）与（Δs_i, T_j），各自生成多项式轨迹束，再两两组合为完整 (s(t), d(t)) 轨迹，用统一代价函数排序选优。

### 1.3 通用代价泛函

论文给出的通用代价泛函形式为：

```
C = k_j · J_t(p(t)) + k_t · g(T) + k_p · h(p₁)
```

其中：
- `J_t = ∫₀ᵀ p⃛(t)² dt` 为 jerk 平方积分（comfort 项，jerk = 加加速度 = 加速度的导数）；
- `g(T)` 是关于终端时间的惩罚函数（一般取 g(T)=T，鼓励短时间到达）；
- `h(p₁)` 是关于终端状态的惩罚函数（横向取 h=d₁² 惩罚偏离 center line，纵向取目标位置偏离）；
- `k_j, k_t, k_p > 0` 为权重。

此泛函在固定边界条件下等价于求五次多项式，故**只需采样终端状态并解 6×6 线性方程组即可解析得轨迹**，无需迭代优化。

### 1.4 横向运动（Lateral Movement）

横向代价泛函（终端期望平行于 center line，故 ḋ₁=d̈₁=0）：

```
C_d = k_j · J_t(d(t)) + k_t · T + k_d · d₁²
```

对偏离 center 的状态加 d₁² 惩罚，使轨迹慢慢收敛回参考线。终端状态采样为 `[d₁, ḋ₁, d̈₁, T]_ij = [d_i, 0, 0, T_j]`，对每个 (d_i, T_j) 求解一条五次多项式，再选 C_d 最小者。

### 1.5 纵向运动（Longitudinal Movement）

纵向以 comfort 和 safety 为评判，引入纵向 jerk 优化。纵向任务分三类（对应 Apollo 的 cruise / follow / stop）：

- **巡航（cruising）**：保持目标速度 v_target，不约束终端位置 s₁，用**四次多项式**；
- **跟车/汇入（following / merging）**：跟踪前车的 s_target(t)，终端状态 `[s₁, ṡ₁, s̈₁, T] = [s_target(T)+Δs, ṡ_target(T), s̈_target(T), T]`，用**五次多项式**；
- **停车（stopping）**：在 s_target 处停，终端 `ṡ₁=0, s̈₁=0`，用**五次多项式**。

### 1.6 高低速区分

论文指出：高速下 d(t) 与 s(t) 近似独立，可直接横纵分离优化；低速下此假设忽略车辆非完整约束（non-holonomic），需在行为层引入速度阈值，横向同时考虑纵向运动。这也是 Apollo Lattice 主要适用高速场景的理论根源。

---

## 2. Frenet 坐标系（s 纵向 / l 横向）

### 2.1 坐标系定义

Frenet 坐标系以参考线（reference line，通常为车道中心线）为基线：
- 参考线上任一点的切向量为 t⃗_r、法向量为 n⃗_r；
- 自车位置 x⃗(s(t), d(t)) = r⃗(s(t)) + d(t)·n⃗_r(s(t))（公式 1）；
- s：从参考线起点到投影点的累积弧长（纵向）；
- l（论文记 d）：自车到参考线的横向偏移（左为正，右为负）。

Apollo 代码中常用 l 代替 d，因为 d 与求导符号混淆；横向信息是关于 s 的导数（dl/ds, ddl/ds²），而非关于 t 的导数，原因是车辆横向运动由纵向运动经转向产生。

### 2.2 Cartesian ↔ Frenet 转换

Apollo 在 `modules/common/math/cartesian_frenet_conversion.{h,cc}` 中实现 `CartesianFrenetConverter::cartesian_to_frenet()`。给定匹配点（matched_point，参考线上最近点）的 (s_r, x_r, y_r, θ_r, κ_r, dκ_r) 与自车笛卡尔状态 (x, y, v, a, θ, κ)，转换公式为：

```
dx = x - x_r;  dy = y - y_r
θ_rsr = θ - θ_r              # 航向差
cos_θ_rsr = cos(θ_rsr)
l  = sign · sqrt(dx² + dy²)  # 横向距离，左右定号
dl = (1 - κ_r·l) · tan(θ_rsr)        # 横向"速度"（对 s 求导）

# 纵向
s  = s_r + 投影增量
ds/dt = v · cos(θ_rsr) / (1 - κ_r·l)   # 即 s'（对 t 求导）
d²s/dt² = ...                          # s'' 略，含 κ, dκ, l, dl, ddl 项

# 横向二阶
l'  = dl/ds = (1 - κ_r·l)·tan(θ_rsr)        # 注意这里对 s 求导
l'' = -dκ_r·l·tan(θ_rsr) + ((1-κ_r·l)/cos²(θ_rsr))·(κ·(1-κ_r·l)/cos(θ_rsr) - κ_r) / (1-κ_r·l)
```

最终得到完整六元状态：`init_s = [s, ṡ, s̈]`，`init_d = [l, ĺ, l̈]`（代码里 init_d 实际存 [l, dl, ddl]，dl/ddl 是对 s 的导数）。这是后续多项式轨迹生成的边界条件。

### 2.3 匹配点求解（PathMatcher）

参考线离散化后（`ToDiscretizedReferenceLine`，逐点累加得 s），需找到自车在参考线上的匹配点。`PathMatcher::MatchToPath` 先遍历找欧氏距离最近的点，再取其前后两点连成向量，将自车点投影到该向量上得到垂直最近点（`FindProjectionPoint`），最后用 `InterpolateUsingLinearApproximation` 线性插值出匹配点的 x, y, θ, κ, dkappa, s。这样避免了参考线离散不密时的法向误差。

---

## 3. 横向五次多项式 + 纵向四次/五次多项式

### 3.1 五次多项式（Quintic Polynomial）

用于**横向 l(s)**、**纵向跟车/停车 s(t)**。一般形式（以时间为自变量，横向时把 t 换成 s）：

```
p(t) = a₀ + a₁·t + a₂·t² + a₃·t³ + a₄·t⁴ + a₅·t⁵
```

边界条件 6 个（起 3 + 终 3），可唯一确定 6 个系数：

```
初始:  p(0)=p₀,  ṗ(0)=ṗ₀,  p̈(0)=p̈₀
终端:  p(T)=p₁,  ṗ(T)=ṗ₁,  p̈(T)=p̈₁
```

求解：令 τ = t/T，可构造 6×6 线性方程组 A·a = b 解出系数。Apollo 在 `quintic_polynomial_curve1d.cc::ComputeCoefficients(x0, dx0, ddx0, x1, dx1, ddx1, p)` 中实现，其中 p 为终端时间（或 s）T。

**性质**：五次多项式是 jerk 平方积分 `∫₀ᵀ p⃛² dt` 的最优解，天然满足 jerk 平滑，曲率连续，是横向轨迹和精确终端位置纵向任务的首选。

### 3.2 四次多项式（Quartic Polynomial）

用于**纵向巡航 s(t)**。巡航只指定终端速度 ṡ₁=v_target（终端位置 s₁ 不约束），边界条件只有 5 个：

```
初始:  s(0)=s₀,  ṡ(0)=ṡ₀,  s̈(0)=s̈₀
终端:  ṡ(T)=ṡ₁,  s̈(T)=0
```

形式：

```
s(t) = a₀ + a₁·t + a₂·t² + a₃·t³ + a₄·t⁴
```

Apollo 在 `quartic_polynomial_curve1d.cc::ComputeCoefficients(x0, dx0, ddx0, dx1, ddx1, p)` 中实现。注意：四次多项式不约束终端位置，故**无法精确停在某个 s 点**，只用于"维持目标速度"的巡航场景。

### 3.3 为什么横纵向分别选 5 次/4 次

| 任务 | 终端约束 | 自由度 | 多项式次数 |
|------|---------|-------|-----------|
| 横向 l(s) | l₁, l'₁=0, l''₁=0 (期望平行) | 6 | 五次 |
| 纵向巡航 s(t) | ṡ₁=v_target, s̈₁=0 | 5 | 四次 |
| 纵向跟车/超车 s(t) | s₁, ṡ₁, s̈₁=0 | 6 | 五次 |
| 纵向停车 s(t) | s₁=stop_s, ṡ₁=0, s̈₁=0 | 6 | 五次 |

Apollo 源码在 `trajectory1d_generator.cc::GenerateLongitudinalTrajectoryBundle` 中：
- `GenerateSpeedProfilesForCruising` 调 `GenerateTrajectory1DBundle<4>`（四次）；
- `GenerateSpeedProfilesForPathTimeObstacles`（跟车/超车）和 `GenerateSpeedProfilesForStopping`（停车）调 `GenerateTrajectory1DBundle<5>`（五次）。

横向则统一 `GenerateTrajectory1DBundle<5>`（五次），另有 OSQP 二次规划路径作为横向 QP 备选（`lateral_osqp_optimizer.cc`、`lateral_qp_optimizer.cc`）。

---

## 4. 采样策略

Lattice 的核心是"采样终端状态"，而非像 EM Planner 那样在 SL/ST 网格上 DP 搜索。Apollo 的采样分横、纵两维。

### 4.1 横向采样（Lateral Sampling）

横向终端状态由 `EndConditionSampler::SampleLatEndConditions()` 生成，典型配置（来自 `planning_config` 的 `lateral_sampling`）：

```
lateral_sampling:
  sample_resolution: 0.5      # 横向采样步长 0.5m
  max_sample_points: 5        # 每个时间点最多 5 个横向采样
```

终端横向偏移 `d_i` 在车道宽度内离散取值（如 -1.0, -0.5, 0, +0.5, +1.0 m，覆盖换道与微调）。终端横向速度/加速度恒置 0（期望平行车道线）。结合横向边界（由 `PathTimeGraph::GetLateralBounds` + `UpdateLateralBoundsByObstacle` 给出，考虑静态障碍物收缩可行域），过滤超界终端点。

### 4.2 纵向采样（Longitudinal Sampling）

纵向终端状态由 `EndConditionSampler` 的三个函数分别生成：

**a. 巡航 `SampleLonEndConditionsForCruising(ref_cruise_speed)`**

只采样终端速度，不约束终端 s。时间采样点 `time_samples = {0.01, 1, 2, 3, 4, 5, 6, 7, 8}`（s，`FLAGS_trajectory_time_length=8`）。对每个时间点，速度在可行域 [VLower(t), VUpper(t)] 内采样：
- VUpper(t) = v₀ + a_max·t，VLower(t) = max(0, v₀ + a_min·t)，由 `FeasibleRegion` 根据纵向加速度上下限算出；
- 取 v_upper = min(VUpper(t), ref_cruise_speed)，v_lower = VLower(t)；
- 在 [v_lower, v_upper] 间均匀插值 `FLAGS_num_velocity_sample` 个点（默认 4），加两端共得若干采样速度；
- 终端状态 `[s, v, a] = [0, v_sample, 0]`（s 不约束，由四次多项式自由）。

**b. 跟车/超车 `SampleLonEndConditionsForPathTimePoints()`**

基于障碍物 ST 图，对每个相关障碍物在 ST 图上采样若干 (t, s) 点作为终端。`QueryFollowPathTimePoints` 在前车 ST 轨迹上取点并加纵向安全距离（车长 + buffer），`QueryOvertakePathTimePoints` 在前车前方取超车点；障碍物速度沿参考线投影（`ProjectVelocityAlongReferenceLine`）作为终端速度 ṡ₁。终端 s、v、a 都给定，用五次多项式。

**c. 停车 `SampleLonEndConditionsForStopping(stop_point)`**

对停止线 s_stop，终端状态 `[s₁, v, a] = [s_stop, 0, 0]`，时间采样同巡航。用五次多项式精确收敛到停止点。

### 4.3 时间采样

时间采样点固定为 `{0.01, 1, 2, 3, 4, 5, 6, 7, 8}` 秒（`FLAGS_trajectory_time_length=8.0`，`FLAGS_polynomial_minimal_param=0.01`），覆盖 3s/4s/5s 等"短中长期"三种时间尺度。短时间偏向保守（小动作），长时间偏向激进（大换道/超车）。

### 4.4 可行域过滤

`FeasibleRegion` 用纵向加速度上下限 (`FLAGS_longitudinal_acceleration_upper_bound/lower_bound`) 计算每个时刻的 s、v 上下限，过滤物理不可达的终端状态，避免生成车辆无法执行的轨迹。关键函数 `SUpper/SLower/VUpper/VLower` 用运动学公式 `s = s₀ + v₀·t + ½·a·t²` 给出边界。

---

## 5. 轨迹生成（Trajectory1dGenerator）

### 5.1 类结构与入口

`Trajectory1dGenerator`（`modules/planning/planners/lattice/trajectory_generation/trajectory1d_generator.{h,cc}`）负责生成横纵向 1D 轨迹束。构造时传入 `init_s, init_d, path_time_graph, prediction_querier`，并在内部计算 `FeasibleRegion`。

入口 `GenerateTrajectoryBundles(planning_target, &lon_bundle, &lat_bundle)` 依次调用：

```cpp
GenerateLongitudinalTrajectoryBundle(planning_target, &lon_bundle);
GenerateLateralTrajectoryBundle(&lat_bundle);
```

### 5.2 纵向轨迹束

`GenerateLongitudinalTrajectoryBundle` 内部三分支：

```cpp
GenerateSpeedProfilesForCruising(planning_target.cruise_speed(), &lon_bundle);   // 四次多项式
GenerateSpeedProfilesForPathTimeObstacles(&lon_bundle);                          // 五次多项式（跟车/超车）
if (planning_target.has_stop_point())
    GenerateSpeedProfilesForStopping(planning_target.stop_point().s(), &lon_bundle); // 五次多项式（停车）
```

每个分支：采样终端状态 → 对每个 (init_state, end_condition) 调 `GenerateTrajectory1DBundle<N>`（N=4 或 5）→ 内部 `QuarticPolynomialCurve1d` / `QuinticPolynomialCurve1d::ComputeCoefficients` 解析求系数 → 封装为 `LatticeTrajectory1d`（包装 `Curve1d` 基类，附加 target_position/velocity/time 信息）。

### 5.3 横向轨迹束

`GenerateLateralTrajectoryBundle` 两套方法：
- **采样法**：`SampleLatEndConditions` 给出 (d_i, T_j)，调 `GenerateTrajectory1DBundle<5>` 用五次多项式生成；
- **QP 法**：`lateral_osqp_optimizer.cc::optimize` 用 OSQP 在横向边界约束下求最小 jerk 的分段样条（`GetLateralBounds` + `UpdateLateralBoundsByObstacle` 给出 s 上的 d 边界）。

横向轨迹以 s 为自变量：`l = l(s)`，组合时再与纵向 s(t) 联立得 `l(t) = l(s(t))`。

### 5.4 横纵向组合（TrajectoryCombiner）

`TrajectoryCombiner::Combine(reference_line, lon_trajectory, lat_trajectory, relative_time)` 把两条 1D 轨迹合成 2D 笛卡尔轨迹：

```
对 t ∈ [0, 8s] 以 FLAGS_trajectory_time_resolution=0.1s 步长：
  s   = lon_trajectory.Evaluate(0, t)   # 0 阶 = 位置
  s'  = lon_trajectory.Evaluate(1, t)   # 1 阶 = 速度
  s'' = lon_trajectory.Evaluate(2, t)
  l   = lat_trajectory.Evaluate(0, s)    # 横向以 s 为自变量
  l'  = lat_trajectory.Evaluate(1, s)
  l'' = lat_trajectory.Evaluate(2, s)
  (x, y, θ, κ) = Frenet→Cartesian(reference_line, s, l, l', l'')
  填入 TrajectoryPoint
```

注意横向自变量是 s 而非 t——这是高速下 d(t)≈d(s(t)) 的简化。合成后交给 `ConstraintChecker::ValidTrajectory` 做运动学约束检查（速度、加速度、jerk、曲率、横向加速度/jerk），再交 `CollisionChecker::InCollision` 做碰撞检测。

---

## 6. 代价函数（TrajectoryEvaluator）

### 6.1 总代价公式

`TrajectoryEvaluator::Evaluate`（`trajectory_evaluator.cc`）对每对 (lon_trajectory, lat_trajectory) 计算 6 项加权代价：

```
cost = w_lon_objective        * LonObjectiveCost(lon_traj, planning_target, ref_s_dot)
     + w_lon_jerk             * LonComfortCost(lon_traj)
     + w_lon_collision        * LonCollisionCost(lon_traj)
     + w_centripetal_accel    * CentripetalAccelerationCost(lon_traj)
     + w_lat_offset           * LatOffsetCost(lat_traj, s_values)
     + w_lat_comfort          * LatComfortCost(lon_traj, lat_traj)
```

对应 Apollo gflags（`planning_gflags.cc`）的权重（典型默认值）：
- `FLAGS_weight_lon_objective`（纵向目标偏离，~1.0）
- `FLAGS_weight_lon_jerk`（纵向 jerk，~1.0）
- `FLAGS_weight_lon_collision`（纵向碰撞，~1.0）
- `FLAGS_weight_centripetal_acceleration`（向心加速度，~1.0）
- `FLAGS_weight_lat_offset`（横向偏移，~2.0）
- `FLAGS_weight_lat_comfort`（横向舒适性，~1.0）

碰撞作为**硬约束**（`CollisionChecker::InCollision` 返回 true 则直接丢弃，而非加无穷大代价），与用户提示的"collision ? infinity : 0"在效果上一致——只是 Apollo 把碰撞检测放在 cost 排序之后、取出每条候选时再做，避免对全部候选都做重碰撞检测。

### 6.2 各代价项含义

**a. LonObjectiveCost（纵向目标代价）**

衡量纵向轨迹偏离指引速度的程度。指引速度 `ref_s_dot` 由 `ComputeLongitudinalGuideVelocity(planning_target)` 生成：若有停车点，用 `PiecewiseBrakingTrajectoryGenerator::Generate` 生成分段刹车指引速度；否则用巡航速度。代价为各时刻实际 ṡ 与 ref ṡ 差的平方和（归一化）：

```
LonObjectiveCost = Σ (s'_actual(t) - s'_ref(t))²  /  N
```

**b. LonComfortCost（纵向 jerk 代价）**

纵向 jerk 平方积分的离散化：

```
LonComfortCost = ∫₀ᵀ s⃛(t)² dt  ≈  Σ s⃛(t_k)² · Δt
```

jerk 越大越不舒适。

**c. LonCollisionCost（纵向碰撞代价）**

基于到障碍物 ST 图的距离 dist，用高斯衰减鼓励远离：

```
LonCollisionCost = Σ exp(-2 · dist_k²)   # 距离越大代价越小（越安全）
```

**d. CentripetalAccelerationCost（向心加速度代价）**

向心加速度 = v²·κ，惩罚高速过弯：

```
CentripetalAccCost = Σ (s'(t)² · κ(s(t)))²  /  N
```

κ 来自参考线在 s 处的曲率。

**e. LatOffsetCost（横向偏移代价）**

横向轨迹对参考线（车道中心）的偏移，沿 s 离散采样：

```
LatOffsetCost = Σ l(s_k)²  /  N,  s_k ∈ [0, evaluation_horizon] step 1.0m
```

偏移越大代价越大，鼓励贴车道中心。

**f. LatComfortCost（横向舒适性代价）**

横向等效加速度（考虑横纵向耦合）：

```
LatComfortCost = Σ (l''(s)·s'² + l'(s)·s'')²  /  N
```

即横向实际加速度 l̈(t) = l''(s)·s'² + l'(s)·s''，惩罚横向加速度突变。

### 6.3 代价排序与择优

`TrajectoryEvaluator` 内部用 `std::priority_queue`（大顶堆，按 cost 从大到小）存所有 (轨迹对, cost)。每轮 `next_top_trajectory_pair()` 取出当前 cost 最小者，交 `TrajectoryCombiner` 合成 2D 轨迹，再做约束检查与碰撞检测：
- 不满足运动学约束 → `continue` 取下一条；
- 碰撞 → `continue`；
- 都满足 → `reference_line_info->SetTrajectory()`，`break`。

这样**按 cost 升序尝试，第一条通过约束与碰撞的即为输出**，避免了对所有候选做重碰撞检测的开销。

### 6.4 失败兜底（BackupTrajectoryGenerator）

若队列耗尽仍无合格轨迹（`num_lattice_traj == 0`），且 `FLAGS_enable_backup_trajectory=true`，则由 `BackupTrajectoryGenerator`（`backup_trajectory_generator.cc`）生成一条保守的备选轨迹（基于分段刹车 + 横向保持），并加 `FLAGS_backup_trajectory_cost` 惩罚。否则置 cost = ∞，返回 `PLANNING_ERROR`。

---

## 7. 算法流程（7 步，源自真实源码）

以下流程直接对照 `lattice_planner.cc::PlanOnReferenceLine` 的注释（1~7）与实现，是 Apollo 9.0 真实运行路径：

```
┌─────────────────────────────────────────────────────────────────┐
│ LatticePlanner::PlanOnReferenceLine（单参考线，每周期 100ms）   │
└─────────────────────────────────────────────────────────────────┘
 1. obtain a reference line and transform it to the PathPoint format.
    ToDiscretizedReferenceLine(): ReferencePoint → PathPoint，累加 s
 2. compute the matched point of the init planning point on ref line.
    PathMatcher::MatchToPath(): 找最近点 → 前后两点 → FindProjectionPoint
 3. according to matched point, compute init state in Frenet frame.
    ComputeInitFrenetState(): CartesianFrenetConverter::cartesian_to_frenet
    → init_s = [s, ṡ, s̈], init_d = [l, l', l'']
 4. parse the decision and get the planning target.
    PathTimeGraph(obstacles, ref_line, s∈[s₀, s₀+200], t∈[0,8s])
    GetSpeedLimitFromS → SetLatticeCruiseSpeed
    planning_target = {stop_point, cruise_speed}
 5. generate 1d trajectory bundle for longitudinal and lateral respectively.
    Trajectory1dGenerator.GenerateTrajectoryBundles()
      ├─ 纵向: cruise(4次) + follow/overtake(5次) + stop(5次)
      └─ 横向: 5次多项式 或 OSQP QP
 6. evaluate feasibility + cost sort.
    TrajectoryEvaluator: 先 ConstraintChecker1d 过滤 v/a/jerk 超限
                       + stop_point 越界过滤
                       + 两两组合算 6 项 cost 进 priority_queue
    CollisionChecker 构造（BuildPredictedEnvironment）
 7. always get best pair to combine; return first collision-free traj.
    while has_more_trajectory_pairs():
      pair = next_top_trajectory_pair()           # 取 cost 最小
      combined = TrajectoryCombiner::Combine(...) # 1D+1D → 2D
      if !ConstraintChecker::ValidTrajectory(combined): continue
      if CollisionChecker::InCollision(combined): continue
      SetTrajectory(combined); break
    若无合格 → BackupTrajectoryGenerator 兜底
```

### 7.1 关键工程细节

- **规划起点 T+dt**：planning_start_point 取上一帧轨迹在 T+dt（≈100ms 后）的点，补偿计算与下发延迟，保证时间一致性（trajectory stitching）。
- **多参考线**：`Plan()` 遍历 frame 内所有 reference_line_info（本车道 + 相邻车道），每条独立跑 Lattice，第一条非优先参考线加 `FLAGS_cost_non_priority_reference_line` 惩罚，从而实现跟车/换道/绕行的多车道决策效果。
- **时间长度 8s / 决策视野 200m**：`FLAGS_trajectory_time_length=8.0`，`FLAGS_speed_lon_decision_horizon=200`。
- **采样分辨率**：时间 `FLAGS_trajectory_time_resolution=0.1s`，空间 `FLAGS_trajectory_space_resolution=1.0m`。

---

## 8. 特点与对比

### 8.1 Lattice vs EM Planner

| 维度 | EM Planner | Lattice Planner |
|------|------------|-----------------|
| 横纵向关系 | 解耦（先 path 后 speed） | 同时求解（横纵采样后组合） |
| 核心思路 | DP 猜 + QP 磨，path/speed 交替 | 采样终端状态 + 多项式连接 + 代价择优 |
| 参数量 | 多（DP/QP 各一套 + Task 链） | 少且统一（采样点数 + 6 个权重） |
| 流程复杂度 | 复杂（Scenario/Stage/Task 双层状态机） | 简单（7 步线性流程） |
| 单周期耗时 | ~100ms（含迭代） | <50ms（解析解 + 堆排序） |
| 轨迹形状 | QP 样条，灵活但需迭代收敛 | 多项式固定形状，天然满足动力学 |
| 适用场景 | 复杂城市多障碍物 | 高速简单结构化道路 |
| Apollo 6.0+ 默认 | 是（PublicRoadPlanner） | 否（备选，lane_follow 可切） |

### 8.2 Lattice 优点

1. **参数少**：主要调 6 个权重 + 采样点数，工程易落地，量产 ACC 方案与其高度相似；
2. **计算快**：多项式系数解析解（一次 6×6 线性求解），无需迭代优化，单周期可压到 <50ms；
3. **轨迹形状天然合理**：五次多项式 jerk 平滑、曲率连续，天然满足车辆动力学约束，控制友好；
4. **横纵向同时优化**：相比 EM 的解耦，理论上能更好地处理横纵向耦合（如换道 + 加减速同时发生）；
5. **流程简单**：7 步线性，无状态机切换，便于移植与调试。

### 8.3 Lattice 缺点

1. **复杂场景适应性弱**：终端状态采样是离散网格，多障碍物密集时易漏掉最优解，且组合爆炸（横纵轨迹束笛卡尔积）导致候选数激增；
2. **轨迹形状固定**：多项式形状有限，无法表达复杂机动（如 S 形绕行需多段拼接）；
3. **低速不适用**：d(t)≈d(s(t)) 的假设在低速失效，需切换到非完整约束方法；
4. **城市路口/无保护左转困难**：无清晰参考线时 Lattice 失效，需 EM/PublicRoadPlanner 的 Scenario 机制；
5. **DP 决策缺失**：无 EM 的 DP 粗规划开辟凸空间，QP 无法直接用，故 Lattice 全靠采样覆盖。

---

## 9. Apollo 源码实现（modules/planning/planners/lattice）

### 9.1 目录结构（Apollo 9.0，2023-12-18 仓库实际结构）

```
modules/planning/planners/lattice/
├── lattice_planner.cc / .h          # LatticePlanner 主类
├── README_cn.md
├── BUILD / cyberfile.xml / plugins.xml
├── behavior/                         # 行为层
│   ├── collision_checker.{h,cc}       # 碰撞检测
│   ├── path_time_graph.{h,cc}         # ST/SL 图构建
│   ├── prediction_querier.{h,cc}     # 障碍物查询
│   └── feasible_region.{h,cc}         # 可行域（V/S 上下限）
└── trajectory_generation/            # 轨迹生成层
    ├── trajectory1d_generator.{h,cc}  # 轨迹束生成器
    ├── end_condition_sampler.{h,cc}    # 终端状态采样器
    ├── trajectory_evaluator.{h,cc}    # 代价评估器
    ├── trajectory_combiner.{h,cc}     # 横纵组合器
    ├── lattice_trajectory1d.{h,cc}    # 1D 轨迹包装类
    ├── backup_trajectory_generator.{h,cc}  # 兜底轨迹
    ├── piecewise_braking_trajectory_generator.{h,cc}  # 分段刹车（指引速度）
    ├── lateral_osqp_optimizer.{h,cc}   # 横向 OSQP QP
    └── lateral_qp_optimizer.{h,cc}    # 横向 QP 输出
```

### 9.2 关键类职责

| 类 | 职责 |
|----|------|
| `LatticePlanner` | 入口 `Plan()` / `PlanOnReferenceLine()`，7 步编排 |
| `PathMatcher` | 参考线匹配点查找（`modules/common/math/`） |
| `CartesianFrenetConverter` | Cartesian↔Frenet 转换（`modules/common/math/`） |
| `PathTimeGraph` | 障碍物 ST/SL 图，`GetPathBlockingIntervals`/`GetLateralBounds` |
| `PredictionQuerier` | 障碍物散列表，`ProjectVelocityAlongReferenceLine` |
| `FeasibleRegion` | 纵向可行域 `SUpper/SLower/VUpper/VLower` |
| `Trajectory1dGenerator` | 生成横纵 1D 轨迹束（cruise/follow/stop/lat） |
| `EndConditionSampler` | 终端状态采样（`SampleLonEndConditionsForCruising/PathTimePoints/Stopping`、`SampleLatEndConditions`） |
| `QuarticPolynomialCurve1d` / `QuinticPolynomialCurve1d` | 4 次/5 次多项式（`modules/planning/planning_base/math/curve1d/`） |
| `TrajectoryEvaluator` | 6 项代价 + 优先队列排序 |
| `TrajectoryCombiner` | 横纵 1D → 2D 笛卡尔轨迹 |
| `ConstraintChecker` / `ConstraintChecker1d` | 运动学约束检查 |
| `CollisionChecker` | OBB 碰撞检测 |
| `BackupTrajectoryGenerator` | 失败兜底 |
| `PiecewiseBrakingTrajectoryGenerator` | 分段刹车指引速度 |

### 9.3 与 EM Planner 共存机制

Apollo 6.0 起，`PlanningComponent` 通过 `planning_config.pb.txt` 的 `planner_type` 字段选择规划器：
- 默认 `PUBLIC_ROAD`（即 PublicRoadPlanner，EM 形态，Scenario/Stage/Task 链）；
- 可切 `LATTICE`（即 LatticePlanner，7 步流程）。

两者继承自 `PlannerWithReferenceLine`，共享 `ReferenceLineInfo`、`Frame`、`Obstacle` 数据结构，但 Lattice 不走 Scenario/Stage 状态机，直接在 `PlanOnReferenceLine` 内完成。高速 lane_follow 简单场景用 Lattice 性能更优；复杂城市路口/无保护左转用 PublicRoadPlanner 的 Scenario 机制。

### 9.4 真实源码片段（lattice_planner.cc 主循环）

以下为从 Apollo 官方仓库 master 分支拉取的 `PlanOnReferenceLine` 核心循环（节选，证实 7 步流程与代价排序+碰撞检测的实际实现）：

```cpp
// 5. generate 1d trajectory bundle for longitudinal and lateral respectively.
Trajectory1dGenerator trajectory1d_generator(
    init_s, init_d, ptr_path_time_graph, ptr_prediction_querier);
std::vector<std::shared_ptr<Curve1d>> lon_trajectory1d_bundle;
std::vector<std::shared_ptr<Curve1d>> lat_trajectory1d_bundle;
trajectory1d_generator.GenerateTrajectoryBundles(
    planning_target, &lon_trajectory1d_bundle, &lat_trajectory1d_bundle);

// 6. evaluate feasibility + sort by cost.
TrajectoryEvaluator trajectory_evaluator(
    init_s, planning_target, lon_trajectory1d_bundle, lat_trajectory1d_bundle,
    ptr_path_time_graph, ptr_reference_line);
CollisionChecker collision_checker(frame->obstacles(), init_s[0], init_d[0],
                                   *ptr_reference_line, reference_line_info,
                                   ptr_path_time_graph);

// 7. always get the best pair; return the first collision-free trajectory.
while (trajectory_evaluator.has_more_trajectory_pairs()) {
  auto trajectory_pair = trajectory_evaluator.next_top_trajectory_pair();  // cost 最小
  auto combined_trajectory = TrajectoryCombiner::Combine(
      *ptr_reference_line, *trajectory_pair.first, *trajectory_pair.second,
      planning_init_point.relative_time());
  if (ConstraintChecker::ValidTrajectory(combined_trajectory) != ConstraintChecker::Result::VALID)
    continue;                              // 运动学约束
  if (collision_checker.InCollision(combined_trajectory)) continue;  // 碰撞
  reference_line_info->SetTrajectory(combined_trajectory);
  reference_line_info->SetCost(reference_line_info->PriorityCost() + trajectory_pair_cost);
  break;
}
// 若无合格 → BackupTrajectoryGenerator 兜底
```

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

AuroraDrive 当前路径规划栈（见 `AuroraDrive项目交接文档.md` 与 `cpp/include/ad/`）：
- **全局规划**：`PathPlanner`（`path_planner.h`）用 A* + Euclidean 启发式在栅格地图上搜出 waypoint 序列；
- **局部控制**：`ExpertController`（`controller.h`）用 Pure Pursuit 跟随 waypoint，计算前轮转向角；纵向用 PID 维持 40km/h 巡航；
- **物理模型**：自行车模型 `BicycleModel::step`，24Hz 物理积分；
- **交通流**：IDM + MOBIL。

**问题**：A* 输出的是离散 waypoint，无速度/加速度/jerk 信息，Pure Pursuit 只能逐点跟踪，轨迹不光滑、转弯抖动、无法处理动态障碍物的预测交互（IDM 车流是反应式，无前瞻轨迹）。AuroraDrive 缺少"参考线 + 多项式平滑 + 代价择优"的局部规划层。

### 10.2 AuroraDrive 是否需要 Lattice？

**结论：需要，但只需简化版**。理由：
1. AuroraDrive 是结构化道路仿真（有车道线/路网），天然有参考线，符合 Lattice 适用条件；
2. 当前 waypoint 抖动问题正是 Lattice 五次多项式平滑能解决的；
3. 仿真场景以巡航 + 跟车 + 偶尔换道为主，无需 EM 的复杂 Scenario 机制；
4. Lattice 参数少、计算快（<50ms），对 24Hz 仿真无压力；
5. 为未来接入动态障碍物预测（IDM 车流的轨迹预测）留接口。

### 10.3 AuroraDrive 简化版 Lattice 设计

**只保留横向五次多项式 + 纵向巡航四次多项式**，砍掉跟车/停车的五次多项式与 OSQP 横向 QP，最小可用版本如下：

#### 10.3.1 数据结构

```cpp
// 参考线：A* waypoint 平滑后的中心线，离散化为 PathPoint[]，含累积 s
struct PathPoint { double x, y, theta, kappa, s; };

// Frenet 初始状态
struct FrenetState {
    std::array<double,3> s;   // [s, s_dot, s_ddot]
    std::array<double,3> d;   // [d, d_prime, d_double_prime]  (对 s 求导)
};
```

#### 10.3.2 横向五次多项式

```cpp
// 终端状态采样：d_i ∈ {-1.0, -0.5, 0, 0.5, 1.0} m，T_j ∈ {3, 4, 5} s
// 终端: [d_i, 0, 0]，求系数 a0..a5
struct QuinticPoly {
    double a0,a1,a2,a3,a4,a5;
    double eval(double s) { return a0+a1*s+a2*s*s+a3*s*s*s+a4*s*s*s*s+a5*s*s*s*s*s; }
    double eval_d(double s){ return a1+2*a2*s+3*a3*s*s+4*a4*s*s*s+5*a5*s*s*s*s; }
    double eval_dd(double s){ return 2*a2+6*a3*s+12*a4*s*s+20*a5*s*s*s; }
};
QuinticPoly fit_quintic(double d0,double d0p,double d0pp,double d1,double d1p,double d1pp,double T){
    // 解 6x6 线性方程组（Eigen 或手写）
}
```

#### 10.3.3 纵向巡航四次多项式

```cpp
// 终端: [s_dot=v_target, s_ddot=0]，不约束 s_1
struct QuarticPoly {
    double a0,a1,a2,a3,a4;
    double eval(double t){ return a0+a1*t+a2*t*t+a3*t*t*t+a4*t*t*t*t; }
    double eval_d(double t){ return a1+2*a2*t+3*a3*t*t+4*a4*t*t*t; }
    double eval_dd(double t){ return 2*a2+6*a3*t+12*a4*t*t; }
};
QuarticPoly fit_quartic(double s0,double v0,double a0,double v1,double a1,double T){
    // 解 5x5 线性方程组
}
```

#### 10.3.4 简化代价函数

```cpp
double cost = 1.0 * LonObjectiveCost(lon, v_target)     // (v - v_target)²
           + 1.0 * LonJerkCost(lon)                     // ∫ s⃛² dt
           + 2.0 * LatOffsetCost(lat, s_values)         // ∫ d² ds
           + 1.0 * LatComfortCost(lon, lat);            // ∫ (d''s'² + d's'')² dt
           + (collision ? 1e9 : 0);                     // 碰撞硬约束
```

#### 10.3.5 流程（5 步）

1. A* 输出 waypoint → 平滑为参考线 → 离散化算 s；
2. 自车 Cartesian → Frenet（init_s, init_d）；
3. 横向采 5 个 d_i × 3 个 T_j = 15 条五次多项式；纵向采 1 条 v_target 巡航四次多项式；
4. 横纵两两组合（15 对），算 cost 排序；
5. 取 cost 最小且不碰撞的，Combine 成笛卡尔轨迹，交 Pure Pursuit 跟踪。

#### 10.3.6 碰撞检测简化

AuroraDrive 无 HD Map 障碍物 box，可用 IDM 车流的预测位置做简易 ST 检查：对每条候选轨迹在每个时刻 t 算自车 (s,d)，与同车道前车预测 (s_front, d_front) 比较，若 |s - s_front| < 安全距离则碰撞。

### 10.4 代价/收益分析

**收益**：
1. 轨迹平滑：五次多项式 jerk 连续，消除 Pure Pursuit 的 waypoint 抖动，转弯更稳；
2. 速度 profile：四次多项式给出 s(t)，可同时输出 v(t)/a(t) 给控制器，不再只靠 PID；
3. 横向决策：5 个 d_i 采样天然支持微调避让与轻量换道，无需另写换道逻辑；
4. 为动态障碍物预测留接口：ST 图框架可直接复用；
5. 算法对齐 Apollo，便于后续接入更多 Apollo 规划能力。

**代价**：
1. 实现成本：需新增 Frenet 转换、多项式拟合、代价评估、组合器约 800~1200 行 C++；
2. 调参成本：6 个权重 + 采样点数需在仿真中调；
3. 参考线质量依赖：A* waypoint 需先平滑（可用样条或移动平均），否则 Frenet 投影误差大；
4. 低速场景需额外处理（AuroraDrive 城市低速多，需加速度阈值切换或改用 piecewise jerk）。

**建议**：作为 AuroraDrive v1.2 的局部规划层增量，与现有 A* + Pure Pursuit 并存（feature flag 切换），先在巡航场景验证，再逐步扩展到跟车/换道。

---

## 11. 参考

- Werling M, Ziegler J, Kammel S, Werling M. *Optimal Trajectory Generation for Dynamic Street Scenarios in a Frenet Frame*. ICRA 2010. ResearchGate 224156269.
- ApolloAuto/apollo 仓库 `modules/planning/planners/lattice/`（master, 2023-12-18, release 9.0.0-rc）。
- Apollo 官方文档与 CSDN 源码解析系列（trajectory1d_generator / trajectory_evaluator / end_condition_sampler / path_time_graph 详解）。

---

> 实际工具调用次数：合计 71 次（WebSearch 26 + WebFetch 24 + Read 19 + LS 2 = 71；其中 WebSearch+WebFetch 共 50 次，含 1 次直接拉取 Apollo 官方仓库 master 分支真实源码 `lattice_planner.cc`、1 次读取 AuroraDrive 项目交接文档、多次拉取 CSDN 源码解析全文并落地到本地缓存后通读）。研究中交叉验证了 Werling 2010 论文推导、Apollo 9.0 真实源码 7 步流程、Trajectory1dGenerator / TrajectoryEvaluator / EndConditionSampler / PathTimeGraph / ConstraintChecker 各类职责、gflags 默认值（`FLAGS_trajectory_time_length=8.0`、`FLAGS_speed_lon_decision_horizon=200`、横向采样 `sample_resolution=0.5 / max_sample_points=5`）、6 项代价函数与权重、ConstraintChecker::Result 枚举（VALID/LON_VELOCITY_OUT_OF_BOUND/LON_ACCELERATION_OUT_OF_BOUND/LON_JERK_OUT_OF_BOUND/CURVATURE_OUT_OF_BOUND/LAT_ACCELERATION_OUT_OF_BOUND/LAT_JERK_OUT_OF_BOUND）、BackupTrajectoryGenerator 兜底机制，以及 Apollo 6.0+ Lattice 与 PublicRoadPlanner(EM) 共存策略。
