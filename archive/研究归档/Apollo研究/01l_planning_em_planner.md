# Apollo EM Planner（Public Road Planner）算法实现深度研究报告

> 研究对象：Baidu Apollo EM Motion Planner 论文及其在 Apollo 5.0→6.0→9.0 中的源码实现（Public Road Planner 场景化 Task 链）
> 研究目的：为 AuroraDrive 仿真系统的规划栈升级提供 EM Planner 算法级参照与简化迁移方案
> 撰写日期：2026-07-23
> 研究方法：WebSearch + WebFetch 对论文原文、CSDN 源码解析系列、Apollo 官方文档进行 50+ 次深度挖掘

---

## 0. 摘要

Apollo EM Motion Planner 是百度面向 L4 开放道路的实时运动规划算法，以"EM 型迭代"为名，核心是 **轻决策（light decision-making）+ DP 粗规划 + QP 平滑**的三段式思想，并在 **Frenet（SL）坐标系下做路径规划、ST 坐标系下做速度规划**的横纵向解耦架构。它通过顶层多车道策略 + 底层单车道 EM 迭代两层级联，在 100ms 周期内输出 8s / 200m 视野的安全舒适轨迹。Apollo 5.0 直接以 `em_planner` 命名；自 3.5 起 Apollo 引入 Scenario/Stage/Task 双层状态机，6.0 之后默认使用 `PublicRoadPlanner`，其 `LANE_FOLLOW_DEFAULT_STAGE` 的 Task 链本质上仍是 EM Planner 的工程化拆分（DP Path → QP Path → DP Speed → QP Speed）。本报告系统梳理 EM Planner 的论文要点、E-step/M-step 数学推导、SL/ST 坐标系、源码 Task 链的输入输出，并针对 AuroraDrive 当前"A* + Pure Pursuit 无 QP 平滑"方案给出"只保留 Path QP + Speed QP"的简化版迁移设计与代价/收益分析。

---

## 1. EM Planner 论文要点

### 1.1 论文出处与定位

原始论文《Baidu Apollo EM Motion Planner》（Haoyang Fan et al., 2018，arXiv:1807.08048）是 Apollo 官方对开放道路（Public Road）规划算法的纲领性描述。其目标是同时满足：

- **安全性**：交通规则硬约束；至少 8s 视野 / 200m 轨迹长度；单周期 < 100ms（人类反应约 300ms）；具备紧急情况处理。
- **乘员体验**：覆盖多车道、复杂动态场景；轨迹平滑；遵循交规。
- **可扩展性**：框架易扩展、易调参，同时处理交通规则、障碍物决策与曲线平滑。

EM 思想源于《Maximum likelihood from incomplete data via the EM algorithm》（Dempster 1977），原用于含缺失数据的概率模型参数估计（E 步求缺失数据期望，M 步极大似然估计参数）。Apollo 借用其"迭代逼近"的形态，但**并非真正的概率 EM**：E-step 指把环境信息投影到 SL/ST 图（建立"期望"中的环境模型），M-step 指用 DP+QP 求解平滑 path/speed profile（"最大化"地逼近最优轨迹），二者在规划周期内迭代 2~3 次收敛。

### 1.2 轻决策（Light Decision-making）思想

EM Planner 与早期"重决策"算法（如 Mobileye RSS 风格的强约束决策）的根本区别：

| 维度 | 重决策（Heavy） | 轻决策（EM Planner） |
|------|-----------------|---------------------|
| 决策时机 | 预先对每个障碍物确定 follow/yield/overtake | 只给一条粗糙可行轨迹表达意图，再迭代细化 |
| 搜索空间 | 决策一旦确定，搜索空间被强约束 | 决策与规划耦合，DP 给粗解开辟凸空间 |
| 失败概率 | 多障碍物时难找到满足所有预决策的轨迹 | 非凸→多凸分解，失败率低 |
| 适用场景 | 简单交互 | 多障碍物复杂场景 |

重决策的两大困难：（1）障碍物与自车交互难以用规则精确描述，跟随运动难建模；（2）多障碍物阻塞时，满足全部预决策的轨迹概率骤降，导致规划失败。EM Planner 通过"先粗后精"的 DP 把非凸空间切成多个凸域，再 QP 在凸域内平滑，规避了上述困难。

### 1.3 多车道分层架构

论文采用"顶层多车道 + 底层单车道"两层级联：

1. **Reference Line Generator** 基于 HD Map + Routing 生成若干车道级候选参考线（本车道、左右相邻车道），每条参考线绑定交通规则与障碍物投影。
2. **车道级 EM 迭代**：每条候选车道独立运行 Path/Speed 迭代，生成一条车道级最优轨迹。
3. **Cross-lane Trajectory Decider / Reference Line Decider**：根据车辆状态、交规、代价函数在所有车道级轨迹中选最优，处理主动变道（Routing 触发）与被动变道（障碍物避让触发）。

### 1.4 Path-Speed 解耦

Frenet 框架下轨迹本质是三维（s, l, t）约束优化问题。两种解法：

- **直接 3D 求解**：trajectory sampling / lattice search，计算量大；为控计算量降低分辨率会得次优解。
- **Path-Speed 解耦**（EM Planner 选择）：路径规划考虑静态/低速障碍物，速度规划考虑动态障碍物。求解效率高，但高速动态障碍物下可能非最优 → Apollo 对高速障碍物倾向变道而非减速 nudge。

### 1.5 决策与交通规则

约束分两类：硬约束（交通规则，如车道边界、限速、停止线）+ 软约束（避让/超车/接近决策）。EM Planner "先决策后规划"：决策明确变道可行性以缩小搜索空间，但决策本身是"轻"的——只用一条粗糙轨迹描述意图并衡量与障碍物距离，再生成凸可行空间供 QP 平滑。

### 1.6 EM 迭代流程图（文字版）

```
┌─────────────────────────────────────────────────────────────────┐
│                  EM Planner 单车道迭代（Lane Level）              │
└─────────────────────────────────────────────────────────────────┘
        每个规划周期内迭代 2~3 次（论文），随周期滚动
 ┌───────────────────────────────────────────────────────────────┐
 │  E-step #1 (SL Mapping)                                       │
 │   ├─ 静态/低速/对向障碍物 → 直接笛卡尔→Frenet 投影到 SL         │
 │   ├─ 动态障碍物 → 预测轨迹 + 自车上一帧轨迹估计重叠 → SL 碰撞区 │
 │   └─ 输出：带障碍物/碰撞区的 SL 图                              │
 ├───────────────────────────────────────────────────────────────┤
 │  M-step #1 (DP Path + QP Path)                                │
 │   ├─ DP Path: Lattice 采样 + 五次多项式连接 + 代价函数 DP 搜索  │
 │   │           → 粗 path + nudge 决策（开辟凸空间）              │
 │   └─ QP Path: 5 次样条 QP 平滑（曲率/曲率变化率 + 边界约束）     │
 │   └─ 输出：平滑 path profile (s, l, dl, ddl)                   │
 ├───────────────────────────────────────────────────────────────┤
 │  E-step #2 (ST Mapping)                                       │
 │   ├─ 所有障碍物（含高速）→ 沿 path profile 投影到 ST 图          │
 │   ├─ 障碍物轨迹与 path 有交点 → ST 碰撞阴影区                   │
 │   └─ 输出：带前后障碍物的 ST 图（可行域为空白区）               │
 ├───────────────────────────────────────────────────────────────┤
 │  M-step #2 (DP Speed + QP Speed)                              │
 │   ├─ DP Speed: ST 图采样 + 代价函数 DP 搜索 → 粗速度曲线 + 决策  │
 │   └─ QP Speed: ST 样条 QP 平滑（jerk/加速度 + ST 边界约束）     │
 │   └─ 输出：平滑 speed profile (t, s, v, a, da)                 │
 └───────────────────────────────────────────────────────────────┘
        ↓
 合并 path profile + speed profile → ADCTrajectory
 多车道时再由 Reference Line Decider 选最优车道级轨迹
```

---

## 2. E-step（DP 粗规划）

E-step 完成两件事：把环境投影到 SL/ST 图（建立"期望"环境模型），并由 M-step 的 DP 给出粗规划与决策。在 Apollo 工程实现里，E-step 的 SL/ST 投影被分散到多个 Decider Task 中（如 `PATH_BOUNDS_DECIDER`、`ST_BOUNDS_DECIDER`、`SPEED_BOUNDS_PRIORI_DECIDER`），DP 则由 `SPEED_HEURISTIC_OPTIMIZER` 等承担。论文为叙述清晰将 E-step/M-step 配对描述。

### 2.1 SL 图与 DP Path

#### 2.1.1 Lattice 采样

在自车前方沿参考线（s 方向）撒若干"行"（row），每行垂直于参考线方向（l 方向）取若干采样点。不同行之间通过**五次多项式**（quintic polynomial）平滑连接，形成分段五次多项式路径。行内采样点间隔（l 方向）与行间距离（s 方向）依速度、道路结构、场景动态调整（换道场景会增大间隔）。出于安全，s 方向覆盖至少 8s 或 200m。

状态向量在 Frenet 下为 `(s, l, dl, ddl, dddl)`，对应笛卡尔 `(x, y, θ, κ, κ̇)`。

#### 2.1.2 代价函数

DP Path 总代价为三项线性叠加：

```
C_total(f(s)) = C_smooth(f) + C_obs(f) + C_guidance(f)
```

**(1) 平滑度代价**：

```
C_smooth(f) = w1·∫(f'(s))² ds + w2·∫(f''(s))² ds + w3·∫(f'''(s))² ds
```

- `f'(s)`：车道与自车航向角之差（侧向速度）
- `f''(s)`：路径曲率 κ = dθ/ds
- `f'''(s)`：曲率变化率（加加速度）

**(2) 障碍物代价**（分段函数，d 为路径到障碍物距离）：

```
C_obs(d) = 0                    ,  d > d_n      (安全阈值外，无代价)
         = C_nudge(d - d_c)     ,  d_c ≤ d ≤ d_n (nudge 区，单调递减)
         = C_collision          ,  d < d_c       (碰撞区，大常数)
```

`d_c` 为安全 buffer，`d_n` 为 nudge 阈值（可随场景变更），`C_nudge` 单调递减。

**(3) 车道/引导代价**：

```
C_guidance(f) = ∫(f(s) - g(s))² ds
```

`g(s)` 为道路中心参考线，使轨迹靠近参考线；道路边界外则设高惩罚。

#### 2.1.3 DP 搜索

遍历 s 序列 `s_0, s_1, ..., s_n`，对每个采样点比较与障碍物距离 d，按上述代价函数用动态规划找最低 cost 路径，同时给出 nudge / 避让决策。DP 的核心价值：把非凸的 SL 空间切成多个凸子域，为后续 QP 开辟凸可行域。

#### 2.1.4 障碍物投影到 Frenet

- **静态障碍物**：位置时不变，直接笛卡尔→Frenet 坐标转换。
- **动态障碍物**：用预测模块给出的预测轨迹，结合自车上一帧规划轨迹，在每个时间点估计自车与障碍物位置，判断重叠 → 映射到 Frenet 形成碰撞区。出于安全，**Path 优化只考虑低速/对向障碍物**，高速障碍物由变道策略 cover。

### 2.2 ST 图与 DP Speed

#### 2.2.1 ST 图采样

路径 profile 确定后，所有障碍物（含高速、低速、对向）沿 path 投影到 ST 图（s 纵向 / t 时间）。若障碍物轨迹与 path 有交点，则在 ST 图对应 (s, t) 处生成碰撞阴影区。剩余空白区为速度可行域。

#### 2.2.2 代价函数 + DP 搜索

ST 图上对 (s, t) 网格采样，代价函数通常包含：速度偏离限速、加速度、加加速度（jerk）、与 ST 边界距离、到达目标速度等。DP 在 ST 网格上搜索最低 cost 路径，得到粗速度曲线，并给出每个障碍物的 overtake / yield / follow / ignore 决策。

注意：DP Speed 输出的粗速度曲线分辨率较低，需 QP 平滑；同时 DP 决策将非凸 ST 问题转化为凸子问题，供 QP 求解。

---

## 3. M-step（QP 平滑）

M-step 在 DP 给出的凸空间内用二次规划（QP）平滑 path 与 speed。Apollo 早期用 **QPOASES** 求解器，6.0+ 改用 **OSQP**（Operator Splitting Quadratic Program）。

### 3.1 Spline Path QP（5 次多项式样条）

#### 3.1.1 目标函数

```
C_s(f) = w1·∫(f'(s))² ds + w2·∫(f''(s))² ds + w3·∫(f'''(s))² ds
       + w4·∫(f(s) - g(s))² ds
```

注意：此处 `g(s)` 是 **DP 规划出的路径**（而非道路中心），因为 DP 路径已含 nudge 决策。QP 目标是在 nudge 贴近与路径平滑之间权衡。

#### 3.1.2 约束

**(1) 边界约束（boundary）**：对 `f(s)`、`f'(s)`、`f''(s)` 施加上下界（来自 DP anchor 偏差与道路边界）。为保证约束凸且线性，自车 bounding box 前后各加一个半圆，用线性化近似：

```
l_left_front_corner = f(s) + sin(θ)·l_f + w/2  ≤  l_left_corner_bound
```

其中 `l_f` 为后轴到车前距离，`w` 为半车宽，`θ` 为车辆航向与道路方位角之差。四个角点同样处理。

**(2) 动态可行性（dynamic feasibility）**：曲率与曲率变化率上限（对应最小转弯半径与转向速率限制）。

**(3) 起点约束**：与当前自车状态连续（位置、速度、加速度匹配）。

#### 3.1.3 求解

构造标准 QP：`min ½xᵀHx + fᵀx`，约束 `LB ≤ x ≤ UB`、`A_eq·x = b_eq`、`A·x ≥ b`。Apollo 代码中 H 称 kernel matrix，等式/不等式约束由 `Spline1dConstraint` 与 `AffineConstraint` 类构造，最终交给 QPOASES/OSQP 求解样条系数。

### 3.2 Spline QP Speed（ST 平滑）

QP Speed 与 QP Path 大同小异，底层同样依托 `Spline1dConstraint` + `AffineConstraint`（`modules/planning/math/smoothing_spline/`）。对目标速度曲线按时间采样 N 段，每段用多项式拟合，整体满足约束后求代价最小的多项式参数。

#### 3.2.1 约束（QpSplineStGraph::AddConstraint）

- `f(0) = 0`（起点 s=0）
- `f'(0) = v0`（起点速度匹配 init_point）
- **单调性不等式**：s(t) 随 t 不减（车不倒退）
- **平滑性等式**：joint points 处 0~3 阶导连续
- **ST 边界**：每个 t 对应 `[lower_s, upper_s]`，即 `lower_s ≤ f(t) ≤ upper_s`
- **速度约束**：`speed_lower ≤ f'(t) ≤ speed_upper`（限速 + ST 边界导出）
- **加速度约束**：`accel_bound`（先 try 严格范围，失败后放宽，再失败用 `QpPiecewiseStGraph` 兜底）

#### 3.2.2 输出

求解后从样条提取 `s(t)`、`v(t)`、`a(t)`、`da(t)`，组装为 `SpeedData`。

---

## 4. 迭代收敛

论文指出 EM 迭代在单周期内 2~3 次即可收敛，且随规划周期滚动持续细化。收敛性来源：

1. **DP→凸化→QP** 的两阶段保证每步都在凸空间内求全局最优，避免非凸局部极小。
2. **Path/Speed 解耦**使每步维度降低，迭代耦合稳定。
3. 上一帧轨迹作为本帧初值（warm start），帧间连续。

**优势**：处理多障碍物复杂场景时，重决策算法易因预决策冲突而失败，EM Planner 通过 DP 把非凸问题分解为多个凸子问题，每个凸子问题 QP 必有解，整体鲁棒性高。代价是单周期计算量略大，但 Apollo 通过 Lattice 稀疏采样 + OSQP 稀疏求解控制在 100ms 内。

> 说明：Apollo 6.0+ 工程实现中，单周期内 Task 链是**串行一次**执行（DP Path→QP Path→DP Speed→QP Speed），并非显式 2~3 次循环；"迭代"更多体现在**帧间**（上一帧轨迹喂给本帧 E-step 做动态障碍物重叠估计）与 **DP/QP 两阶段**上。论文的 2~3 次迭代是早期 `em_planner` 的行为，Public Road Planner 把它展平为 Task 链。

---

## 5. SL 坐标系（Frenet）

### 5.1 定义

Frenet 坐标系以**参考线（reference line，通常为道路中心线）**为基线：

- **s**：沿参考线的弧长（纵向，mileage）
- **l**：垂直参考线方向的横向偏移（横向，lateral，左侧为正）

参考线由离散点列描述，要求二阶导连续（曲率连续），否则 Frenet 投影会产生噪声。Apollo 用 `ReferenceLineProvider` 多线程生成并平滑参考线，平滑方法有 **CosTheta**（余弦航向）与 **FemPos**（有限元位置）两种。

### 5.2 状态向量映射

| 笛卡尔 | Frenet |
|--------|--------|
| (x, y) | (s, l) |
| θ（航向） | dl（侧向速度） |
| κ（曲率） | ddl（侧向加速度） |
| κ̇（曲率变化率） | dddl（侧向加加速度） |

笛卡尔曲率 κ 与 Frenet 量关系复杂（涉及参考线曲率），Apollo 在 `PiecewiseJerkPathOptimizer` 中做简化约束：`|ddl| ≤ lat_acc_bound`，其中 `lat_acc_bound = tan(max_steer/steer_ratio)/wheel_base - κ_ref`，保证笛卡尔下曲率不超车辆最小转弯半径。

### 5.3 障碍物投影

- **静态障碍物**：直接笛卡尔→Frenet，得到 `(s_min, s_max, l_min, l_max)` 的 SL 边界框。
- **动态障碍物**：用预测轨迹，结合自车上一帧轨迹，在每个时间点估计自车与障碍物位置，判断重叠 → 在 SL 上形成"预测碰撞区"（t 时刻的切片）。动态障碍物在 SL 上是随时间变化的，需 ST 图完整描述。

---

## 6. ST 图

### 6.1 定义

ST 图以**路径 profile 的 s 为纵轴、时间 t 为横轴**：

- **s**：沿已规划 path 的弧长（注意：速度规划的 s 沿 path，路径规划的 s 沿参考线，二者在 path 确定后统一）
- **t**：从当前时刻起的时间

自车轨迹在 ST 图上是一条单调不减的曲线 `s(t)`（车不倒退）。

### 6.2 障碍物占据区（ST Boundary）

每个障碍物沿 path 投影，得到其在 ST 图上的占据区（多边形）：

- **静态障碍物**：占据区为竖直矩形（s 固定区间，t 全程）
- **动态障碍物**：占据区为斜多边形（s 随 t 变化），由预测轨迹与 path 交点决定上下界

`STBoundsDecider`（Apollo 6.0）/ `STObstaclesProcessor` 遍历障碍物，调用 `ComputeObstacleSTBoundary()` 计算 `lower_points` / `upper_points`，对不影响纵向规划的障碍物设 `IGNORE`，对其余按设定轨迹给出 `overtake` / `yield` 决策，最终输出 `Drivable_st_boundary`（可行驶 ST 边界）。

### 6.3 ST 边界（上界/下界）

对每个时刻 t，ST 边界给出自车 s 的可行范围 `[lower_s(t), upper_s(t)]`：

- **上界 upper_s**：前方障碍物或 path 终点限制（不能超过）
- **下界 lower_s**：后方障碍物限制（不能落后到碰撞）

QP Speed 在该凸边界内求平滑 `s(t)`。

### 6.4 速度规划在 ST 空间的搜索

- **DP**：在 ST 网格上采样，按代价函数搜索最低 cost 路径（粗速度曲线 + 决策）
- **QP**：在 DP 开辟的凸边界内用样条 QP 平滑 `s(t)`，满足 jerk/加速度/限速约束

---

## 7. Apollo 源码实现

### 7.1 目录结构

Apollo 9.0+ PnC 2.0 插件化后，EM Planner 的算法逻辑分散在 `modules/planning` 下多个子目录：

| 路径 | 职责 |
|------|------|
| `modules/planning/planning_base/scenario_configs/` | 各 Scenario/Stage 的 Task 链配置（`.pb.txt`） |
| `modules/planning/planners/public_road/` | `PublicRoadPlanner` + `ScenarioManager`，默认规划器 |
| `modules/planning/planners/`（旧 `em/`） | Apollo 5.0 的 `EMPlanner` 类（已逐步被 Public Road Planner 取代，但算法思想延续） |
| `modules/planning/tasks/deciders/` | 各 Decider Task（path_bounds_decider、path_decider、speed_bounds_decider、st_bounds_decider 等） |
| `modules/planning/tasks/optimizers/piecewise_jerk_path/` | `PiecewiseJerkPathOptimizer`（QP Path） |
| `modules/planning/tasks/optimizers/piecewise_jerk_speed/` | `PiecewiseJerkSpeedOptimizer`（QP Speed） |
| `modules/planning/tasks/optimizers/qp_spline_st_speed/` | 旧 `QpSplineStSpeedOptimizer`（样条 QP Speed，6.0 后被 piecewise jerk 替代） |
| `modules/planning/tasks/optimizers/dp_st_speed/` | 旧 `DpStSpeedOptimizer`（DP Speed，6.0 后被 `speed_heuristic_optimizer` 替代） |
| `modules/planning/math/smoothing_spline/` | `Spline1dConstraint` / `AffineConstraint`（样条 QP 底层） |
| `modules/planning/math/piecewise_jerk/` | Piecewise Jerk 通用算法（path/speed 共用） |
| `modules/planning/reference_line/` | `ReferenceLineProvider`、`ReferenceLineSmoother`（CosTheta / FemPos） |

### 7.2 LANE_FOLLOW_DEFAULT_STAGE Task 链

`modules/planning/conf/scenario/lane_follow_config.pb.txt` 中 `LANE_FOLLOW_DEFAULT_STAGE` 配置的 Task 顺序（Apollo 6.0+，即 Public Road Planner 下 EM Planner 的工程化展开）：

```
stage_type: LANE_FOLLOW_DEFAULT_STAGE
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
# task_type: PIECEWISE_JERK_NONLINEAR_SPEED_OPTIMIZER
task_type: RSS_DECIDER
```

这与任务描述给出的链 `PATH_LANE_BORROW_DECIDER → PATH_BOUNDS_DECIDER → PIECEWISE_JERK_PATH_OPTIMIZER → ST_BOUNDS_DECIDER → SPEED_BOUNDS_PRIORI_DECIDER → SPEED_HEURISTIC_OPTIMIZER → SPEED_DECIDER → SPEED_BOUNDS_FINAL_DECIDER → PIECEWISE_JERK_SPEED_OPTIMIZER` 基本一致（`ST_BOUNDS_DECIDER` 在 6.0 后并入 `SPEED_BOUNDS_PRIORI_DECIDER` 的 ST 映射逻辑；前后还各有一个 LANE_CHANGE/PATH_REUSE 与 PATH_ASSESSMENT/PATH_DECIDER/RULE_BASED_STOP/RSS 包夹）。

### 7.3 各 Task 输入/输出

| Task | 输入 | 输出 | 算法 |
|------|------|------|------|
| `LANE_CHANGE_DECIDER` | Routing、参考线、障碍物 | `lane_change_status`（是否变道、变道状态） | 规则判断 |
| `PATH_REUSE_DECIDER` | 上一帧 path、自车状态 | `path_reusable` 标志（是否复用上帧 path） | 规则判断 |
| `PATH_LANE_BORROW_DECIDER` | 障碍物、车道 | 是否借道（左/右）标志 | 规则判断（`IsNecessaryToBorrow`） |
| `PATH_BOUNDS_DECIDER` | 借道决策、车道宽度、ADC 位置、障碍物 | 候选 `PathBoundary`（fallback / pull-over / lane-change / regular），每点 `(s, l_min, l_max)`，horizon 100m、resolution 0.5m | 规则 + 障碍物边界收缩 |
| `PIECEWISE_JERK_PATH_OPTIMIZER` | `PathBoundary`、参考线、`init_point`、车辆参数 | `opt_l/opt_dl/opt_ddl`（优化后 path），存入 `candidate_path_data` | OSQP QP（piecewise jerk） |
| `PATH_ASSESSMENT_DECIDER` | 候选 path 列表 | 去除无效 path、加 path info、排序选最优 | 规则 + 代价排序 |
| `PATH_DECIDER` | 最优 path、静态障碍物 | 每个静态障碍物的 `nudge`/`ignore` 决策 | 规则（`MakeStaticObstacleDecision`） |
| `RULE_BASED_STOP_DECIDER` | path、障碍物、交规 | 强制 stop 决策（人行道、停止线等） | 规则 |
| `SPEED_BOUNDS_PRIORI_DECIDER` | path、障碍物、限速 | ST 图（障碍物 ST boundary + 限速 map） | 障碍物→ST 投影 |
| `SPEED_HEURISTIC_OPTIMIZER` | ST 图、init_point | 粗 `SpeedData` + 每障碍物 overtake/yield/follow/ignore 决策 | DP on ST graph |
| `SPEED_DECIDER` | 粗 SpeedData、障碍物 | 细化每障碍物纵向决策（`STBoundsDecider` 思想延续） | 规则 + 决策 |
| `SPEED_BOUNDS_FINAL_DECIDER` | path、决策、障碍物 | 重新计算 ST boundary → 最终速度边界 | 障碍物→ST 投影 |
| `PIECEWISE_JERK_SPEED_OPTIMIZER` | 最终 ST 边界、init_point、限速 | 平滑 `SpeedData`（s, v, a, da） | OSQP QP（piecewise jerk） |
| `RSS_DECIDER` | 轨迹、障碍物 | RSS 安全约束修正（可选） | RSS 模型 |

### 7.4 PiecewiseJerkPathOptimizer 数学细节

**优化变量**：对 s 等间隔采样（`delta_s`），每点 `(l_i, dl_i, ddl_i)`；jerk 在每段内恒定，`jerk_i = (ddl_{i+1} - ddl_i) / delta_s`。

**目标函数**：

```
min  Σ [ w_jerk·jerk_i² + w_ddl·ddl_i² + w_dl·dl_i² + w_l·(l_i - l_ref_i)² ]
   + Σ [ w_boundary·(slack_upper_i² + slack_lower_i²) ]
```

**约束**：

- **边界不等式**：`l_lower_i - slack_lower_i ≤ l_i ≤ l_upper_i + slack_upper_i`（path boundary，松弛变量保可行性）
- **运动学可行性**：`ddl_lower_i ≤ ddl_i ≤ ddl_upper_i`，其中 `ddl_bound = ±(lat_acc_bound - κ_ref_i)`，`lat_acc_bound = tan(max_steer/steer_ratio)/wheel_base`
- **连续性等式**：段间 `l`、`dl`、`ddl` 连续（piecewise jerk 模型保证 jerk 恒定，故三阶导由 ddl 差分得）
- **起点等式**：`l_0, dl_0, ddl_0 = init_frenet_state`（与自车当前状态匹配）

**求解**：构造稀疏 QP 交给 OSQP，返回 `opt_l/opt_dl/opt_ddl`，再通过 `ToPiecewiseJerkPath` 组装为 `FrenetFramePath`。

### 7.5 PiecewiseJerkSpeedOptimizer 数学细节

**优化变量**：对 t 等间隔采样（`delta_t = 0.1s`），每点 `(s_i, v_i, a_i)`；jerk 恒定，`jerk_i = (a_{i+1} - a_i) / delta_t`。

**目标函数**：

```
min  Σ [ w_jerk·jerk_i² + w_a·a_i² + w_v·(v_i - v_ref_i)² + w_s·(s_i - s_ref_i)² ]
   + Σ [ w_boundary·(slack_i²) ]
```

**约束**：

- **ST 边界**：`s_lower_i - slack ≤ s_i ≤ s_upper_i + slack`
- **速度**：`0 ≤ v_i ≤ v_limit_i`（限速 + ST 边界导出）
- **加速度**：`a_lower ≤ a_i ≤ a_upper`（先严格范围，失败放宽）
- **连续性**：段间 `s`、`v`、`a` 连续
- **单调性**：`s_{i+1} ≥ s_i`（不倒退）
- **起点**：`s_0=0, v_0=init_v, a_0=init_a`

**求解**：OSQP 返回 `opt_s/opt_v/opt_a`，组装为 `SpeedData`。

### 7.6 旧 QP Spline Speed（参考）

`QpSplineStSpeedOptimizer`（5.0/6.0 早期）按时间采样 N 段，每段多项式拟合，整体求代价最小多项式参数。`QpSplineStGraph::Search()` 四步：`AddConstraint()` → `AddKernel()` → `Solve()` → extract speed data。约束含 `f(0)=0`、`f'(0)=v0`、单调性、joint 0~3 阶导连续、ST 边界、速度上下界。6.0 后逐步被 piecewise jerk 替代（piecewise jerk 更易处理 ST 边界非凸与离散决策）。

---

## 8. AuroraDrive 迁移建议

### 8.1 AuroraDrive 当前规划现状

根据 `AuroraDrive项目交接文档.md`，AuroraDrive（原 FSD）当前规划栈为：

- **路径规划**：A* 算法 + Euclidean 启发式（`cpp/include/ad/path_planner.h`），全局拓扑路径
- **横向控制**：Pure Pursuit 控制器（`cpp/include/ad/controller.h`），找最近点→前瞻点→曲率→转向角
- **纵向控制**：PID 速度闭环（目标 40km/h）
- **交通流**：IDM（Intelligent Driver Model）+ MOBIL 换道
- **物理模型**：自行车模型（BicycleModel），24Hz 仿真
- **AUTO 接管**：复用 `compute_road_guidance` + PurePursuit 计算转向角 + PID 速度

**关键缺口**：

1. **无 QP 平滑**：A* 路径是离散栅格点，曲率不连续，Pure Pursuit 跟踪会抖动
2. **无速度规划**：固定 40km/h 巡航，不能根据前车/弯道减速
3. **无 Frenet 解耦**：路径在笛卡尔坐标，难以做横向避让（nudge）
4. **无障碍物决策**：交通流 IDM 仅影响他车，自车不主动 overtake/yield

### 8.2 是否需要 EM Planner 全套？

**结论：不需要全套，建议只迁移 Path QP + Speed QP 两段**。

理由：

- EM Planner 全套含多车道策略、Scenario/Stage 双层状态机、15 个 Task、参考线平滑、Frenet 投影、ST 图、DP+QP 双阶段，工程量数千行 C++ + OSQP 依赖 + 大量调参，与 AuroraDrive"最小化实现、零第三方依赖、inline 头文件"的代码风格冲突。
- AuroraDrive 是**仿真系统**，交通流由 IDM 生成，障碍物行为可预测且不复杂；无真实 L4 安全压力；24Hz 实时性要求高。
- 真正能提升 AuroraDrive 平顺性与智能性的，是 **QP 平滑**（消除 A* 折线）与 **速度规划**（弯道/前车减速），这两者正是 EM Planner M-step 的核心收益。

### 8.3 简化版 EM Planner 设计（只保留 Path QP + Speed QP）

```
┌─────────────────────────────────────────────────────────────────┐
│           AuroraDrive 简化版 EM Planner（单周期）                │
└─────────────────────────────────────────────────────────────────┘
 1. 参考线生成（复用现有 compute_road_guidance）
    └─ 输出：道路中心离散点序列 (x_i, y_i, heading_i) 作为 reference line
 ┌────────────────────────────────────────────────────────────────┐
 │ 2. Path QP（Piecewise Jerk Path，简化版）                       │
 │    ├─ 笛卡尔→Frenet：沿 reference line 投影自车与道路边界        │
 │    ├─ Path Boundary：道路宽度 ± lane_offset（简单，无障碍物 nudge）│
 │    ├─ 优化变量：l_i, dl_i, ddl_i（s 等间隔 0.5m）                │
 │    ├─ 目标：min Σ(jerk² + ddl² + dl² + (l-l_ref)²)              │
 │    ├─ 约束：l 边界、ddl 边界（转向角限）、起点连续                │
 │    └─ 输出：平滑 path (s, l, dl, ddl) → 转笛卡尔离散点           │
 ├────────────────────────────────────────────────────────────────┤
 │ 3. Speed QP（Piecewise Jerk Speed，简化版）                      │
 │    ├─ ST 边界：前车 IDM 跟车距离 → upper_s；path 终点 → upper_s  │
 │    ├─ 限速：弯道曲率限速 + 全局 40km/h                           │
 │    ├─ 优化变量：s_i, v_i, a_i（t 等间隔 0.1s，8s 视野）           │
 │    ├─ 目标：min Σ(jerk² + a² + (v-v_ref)²)                      │
 │    ├─ 约束：ST 边界、0≤v≤v_limit、a 边界、单调 s、起点连续       │
 │    └─ 输出：平滑 speed (t, s, v, a)                              │
 └────────────────────────────────────────────────────────────────┘
 4. 轨迹合并：path(s) + speed(t) → (x, y, v, a, t) 轨迹点序列
 5. 控制器：Pure Pursuit 跟踪 path，PID 跟踪 speed（保留现有控制器）
```

**简化点对照 EM Planner**：

| EM Planner 全套 | AuroraDrive 简化版 | 简化理由 |
|-----------------|-------------------|----------|
| 多车道策略 + Cross-lane Decider | ❌ 删除 | 仿真单车道够用，IDM 已处理他车换道 |
| Scenario/Stage 双层状态机 | ❌ 删除 | 仿真无红绿灯/泊车/停止线场景 |
| DP Path（Lattice + 五次多项式） | ❌ 删除 | A* 已给全局路径，无需 Lattice 搜索 |
| DP Speed（ST 图 DP 搜索） | ❌ 删除（用 IDM 跟车模型替代） | IDM 已给前车距离，无需 DP 决策 |
| PATH_BOUNDS_DECIDER 多场景 | ⚠️ 简化为道路宽度固定边界 | 无借道/pull-over |
| PATH_ASSESSMENT_DECIDER | ❌ 删除 | 单候选 path 无需排序 |
| PATH_DECIDER（nudge 决策） | ❌ 删除（或简化为固定偏移） | 仿真障碍物少 |
| ReferenceLineSmoother（CosTheta/FemPos） | ⚠️ 复用 compute_road_guidance 输出 | 道路中心已较平滑 |
| **PiecewiseJerkPathOptimizer** | ✅ **保留（核心）** | 消除 A* 折线，平滑曲率 |
| **PiecewiseJerkSpeedOptimizer** | ✅ **保留（核心）** | 弯道/前车减速，平滑加速度 |
| ST 图生成 | ⚠️ 简化为前车距离 + 限速 | 无复杂动态障碍物 |
| OSQP 求解器 | ✅ 引入（唯一第三方依赖） | QP 必需；OSQP 轻量 header-only 可选 |

### 8.4 代价/收益分析

**收益**：

1. **平顺性大幅提升**：A* 路径曲率不连续导致 Pure Pursuit 转向抖动，QP 平滑后曲率连续可微，乘坐舒适度显著改善。
2. **速度智能性**：弯道前自动减速（曲率限速）、前车跟车（IDM 距离作 ST 上界），不再固定 40km/h，更接近真实驾驶。
3. **架构对齐 Apollo**：为后续真车移植或多障碍物场景扩展铺路，Path QP + Speed QP 是 Apollo 验证过的工业级方案。
4. **Frenet 解耦**：横向（path）与纵向（speed）独立优化，便于后续加 nudge 避让、变道等能力。

**代价**：

1. **新增 OSQP 依赖**：与 AuroraDrive"零第三方依赖"原则冲突。缓解：OSQP 是 header-only 友好的轻量 QP 求解器，可 vendoring 到 `cpp/third_party/osqp/`，或用更简化的主动集法自实现（变量数 <100 时可行）。
2. **新增 Frenet 投影代码**：需实现笛卡尔↔Frenet 转换（`XYToSL` / `SLToXY`），约 200 行 C++。
3. **调参成本**：QP 权重（jerk/ddl/dl/l）需调试，初期可能需 1~2 天仿真调参。
4. **计算量增加**：Path QP 约 200 变量、Speed QP 约 240 变量，OSQP 在 24Hz 下绰绰有余（单次求解 <1ms），但比纯 A* + Pure Pursuit 多 1~2ms。
5. **工程量**：预估 Path QP + Speed QP + Frenet 投影 + 轨迹合并约 800~1200 行 C++（inline 头文件风格），2~3 人日。

**建议路线**：

- **阶段 1（P1）**：先只做 **Path QP**，把 A* 路径投影到 Frenet 后用 piecewise jerk QP 平滑，再转回笛卡尔喂 Pure Pursuit。立即消除转向抖动，最低成本。
- **阶段 2（P2）**：加 **Speed QP**，ST 上界用前车 IDM 距离 + 弯道曲率限速，替换固定 40km/h。实现弯道/前车减速。
- **阶段 3（P3，可选）**：加简单 nudge 决策（前方静态障碍物横向偏移），引入障碍物 SL 投影。
- **不建议**：迁移全套 Scenario/Stage 状态机、多车道策略、DP 搜索——与仿真目标不匹配，过度工程。

### 8.5 与现有代码集成点

| 现有文件 | 集成方式 |
|---------|----------|
| `cpp/include/ad/path_planner.h` | A* 输出作为 reference line 候选，或直接用 `compute_road_guidance` 输出 |
| `cpp/include/ad/controller.h` | Pure Pursuit 输入从 A* 离散点改为 QP 平滑后的笛卡尔点 |
| `cpp/include/ad/simulator.h` | `sim_loop()` 中在 `step(dt)` 前插入 Path QP + Speed QP 调用；纵向 PID 目标从固定 40km/h 改为 Speed QP 输出的 v(t) |
| `cpp/include/ad/traffic.h` | IDM 前车信息（距离、速度）作为 Speed QP 的 ST 上界输入 |
| 新增 `cpp/include/ad/em_planner.h` | 简化版 EM Planner 主入口（inline），含 Frenet 投影 + Path QP + Speed QP |
| 新增 `cpp/third_party/osqp/` | OSQP 求解器（vendoring） |

---

## 9. 关键结论

1. **EM Planner 本质**：轻决策 + DP 粗规划（凸化）+ QP 平滑的三段式，SL 路径 / ST 速度解耦，Frenet 坐标系下迭代 2~3 次收敛。
2. **Apollo 6.0+ Public Road Planner** 是 EM Planner 的工程化拆分，`LANE_FOLLOW_DEFAULT_STAGE` 的 15 个 Task 串行执行 DP Path→QP Path→DP Speed→QP Speed，单周期内完成（帧间迭代）。
3. **核心数学**：Piecewise Jerk 模型（jerk 恒定分段）把 path 优化为 `(l, dl, ddl)` 的稀疏 QP、speed 优化为 `(s, v, a)` 的稀疏 QP，OSQP 求解，约束含边界/运动学/连续性/单调性。
4. **AuroraDrive 迁移**：无需全套，只保留 Path QP + Speed QP 即可消除 A* 折线抖动、实现弯道/前车减速，预估 2~3 人日，收益/代价比高。建议分阶段：先 Path QP（P1），再 Speed QP（P2），nudge 决策可选（P3）。

---

## 10. 参考资料

- 论文：Haoyang Fan et al., "Baidu Apollo EM Motion Planner", arXiv:1807.08048, 2018
- 论文：Apollo, "Optimal Vehicle Path Planning Using Quadratic Optimization for Baidu Apollo Open Platform"（Piecewise Jerk Path 原始论文）
- 源码：`github.com/ApolloAuto/apollo` `modules/planning/`
- CSDN 源码解析系列：IHTY_NUI《Apollo EM Motion Planner》、travis_x《Apollo 6.0 算法解析 EM Planner》、sinat_52032317《Apollo 学习笔记 TASK 系列》（LANE_CHANGE/PATH_REUSE/PATH_LANE_BORROW/PATH_BOUNDS/PIECEWISE_JERK_PATH/PATH_ASSESSMENT/PATH_DECIDER/SPEED_BOUNDS_PRIORI/SPEED_HEURISTIC/SPEED_DECIDER/PIECEWISE_JERK_SPEED）、linxigjs《EM Planner DP/QP Speed Optimizer 代码解析》、xl_courage《StBoundsDecider 流程与代码解析》、weixin_65089713《PiecewiseJerkPathOptimizer》、waingai1999《Apollo 9.0 速度二次规划》
- Apollo 星火计划课程《自动驾驶规划技术原理》

---

> 本报告共进行 **57 次** 内部工具调用（WebSearch + WebFetch + Read/LS），其中 WebSearch 约 32 次、WebFetch 约 13 次、本地 Read/LS 约 12 次，覆盖论文原文、Apollo 源码目录、CSDN 源码解析系列、AuroraDrive 项目交接文档。
