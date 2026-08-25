# Apollo Open Space Planner 深度研究报告（Hybrid A* + Reeds-Shepp + OBCA）

> 文档定位：Apollo 自动驾驶开源栈中"非结构化道路"路径规划模块 Open Space Planner 的算法实现研究，作为 AuroraDrive 简化版泊车能力迁移的参考资料。
> 关联论文：
> - Practical Search Techniques in Path Planning for Autonomous Driving (Dolgov, Thrun, Montemerlo, Diebel, IJRR 2008 / AAAI WS 2007) —— Hybrid A*
> - Optimal paths for a car that goes both forwards and backwards (J. A. Reeds, L. A. Shepp, Pacific J. Math. 145(2): 367–393, 1990) —— RS 曲线
> - Optimization-Based Collision Avoidance (arXiv:1711.03449) —— OBCA 原型
> - TDR-OBCA: A Reliable Planner for Autonomous Driving in Free-Space Environment (arXiv:2009.11345) —— Apollo 改进

---

## 1. Open Space Planner 应用场景与定位

### 1.1 与 Public Road Planner 的差异

Apollo 的 Planning 模块自 3.5 起采用 scenario-based planning 架构，规划器（Planner）层面同时维护两条主线：

| 维度 | Public Road Planner（On Lane Planning） | Open Space Planner |
|---|---|---|
| 工作空间 | 结构化道路（车道线、参考线） | 非结构化开放空间（停车场 / 掉头区 / 起步区） |
| 坐标系 | Frenet (s, l) 沿参考线 | 笛卡尔 (x, y, θ) |
| 参考线 | 必须由 Routing + 车道线生成 | 无参考线，直接在二维 ROI 内搜索 |
| 规划变量 | 路径-速度解耦 (path + ST speed) | 横纵向联合优化 (x, y, φ, v, a, δ) |
| 运动方向 | 仅前向 | 允许前进 + 后退（倒车） |
| 主算法 | EM Planner / Lattice / Public Road Planner（PIECEWISE_JERK 系列 QP） | Hybrid A* + OBCA / DL-IAPS |
| 适用速度 | 中高速 | 低速（典型 ≤ 5 m/s 泊车工况） |

Public Road Planner 强依赖"车道线 + 参考线"，对于倒车入库（valet parking）、sharp U-turn（窄道掉头）、起步驶离（park and go）这类没有清晰车道线参考、需要倒挡和大幅转向的场景，参考线难以构造或失去意义。Open Space Planner 正是为这类"free-space"工况而设计，其流程不依赖参考线，而是直接在由感知边界与障碍物多边形围成的"可行驶区域 (ROI)"内进行三维 (x, y, θ) 搜索 + 非线性优化。

### 1.2 Apollo 中典型 Open Space 场景

Open Space Planner 在 Apollo 中通过 scenario → stage → task 的层级被组织，应用到的 scenario 主要包括：

- **VALET_PARKING**（代客泊车）：典型应用入口。包含两个 stage：
  - `VALET_PARKING_APPROACHING_PARKING_SPOT`（接近车位，仍走 Public Road Planner 的常规 task 流水线）
  - `VALET_PARKING_PARKING`（执行泊入，切入 Open Space 流水线，4 个 task：OPEN_SPACE_ROI_DECIDER / OPEN_SPACE_TRAJECTORY_PROVIDER / OPEN_SPACE_TRAJECTORY_PARTITION / OPEN_SPACE_FALLBACK_DECIDER）
- **PARK_AND_GO**（停车后再起步驶离）：解决"从车位 / 路边起步驶回车道"的初始化姿态规划问题。
- **PULL_OVER**（靠边停车）：紧急 / 主动靠边，需要把车泊入路侧目标位姿。
- **NARROW_STREET_U_TURN**（窄道掉头）：在窄路上执行带倒车的"几把轮"掉头；Apollo 7.0 之后还引入 `deadend_turnaround`（断头路掉头）作为同类 open space 场景的补充。
- **DEADEND**（断头路掉头）: 在 OpenSpaceRoiDecider 中作为独立 `roi_type` 分支处理。

### 1.3 流水线总览

VALET_PARKING_PARKING stage 的标准 task 序列为：

```
OPEN_SPACE_ROI_DECIDER            # 1. 计算可行驶 ROI、车位边界、end pose、把障碍物多边形线性化
OPEN_SPACE_TRAJECTORY_PROVIDER    # 2. 状态机 + 多线程调度，调用 OpenSpaceTrajectoryOptimizer
OPEN_SPACE_TRAJECTORY_PARTITION   # 3. 把整条轨迹按换挡点切成前/后向分段，按车辆位置下发
OPEN_SPACE_FALLBACK_DECIDER       # 4. 碰撞检测兜底，失败则生成"在碰撞点停车"的回退轨迹并触发重规划
```

其中 OPEN_SPACE_TRAJECTORY_PROVIDER 内部又分为四个核心算法模块：
1. **Hybrid A\***（coarse_trajectory_generator）：在 (x, y, θ) 三维空间搜索粗轨迹（无碰、运动学可行，但曲率不连续）。
2. **DualVariableWarmStartProblem**：在 Hybrid A* 给出的 temporal profile 上，求解对偶变量 (λ, μ) 的 QP 问题，作为 OBCA 主优化问题的 warm start。
3. **DistanceApproachProblem**（distance_approach_ipopt_fixed_ts）：TDR-OBCA 主优化，IPOPT 求解横纵向联合非线性规划，输出平滑、运动学连续、避障的轨迹。
4. **IterativeAnchoringSmoother**（DL-IAPS）：当 OBCA 求解失败时的简化平滑通道，分段对 Hybrid A* 路径做离散点平滑 + 碰撞重锚。

最终输出一个 `HybridAStartResult`/`DiscretizedTrajectory`，包含 x, y, φ, v, a, steer, accumulated_s 七个序列，由 PARTITION 切分后下发给 Control 模块。

---

## 2. Hybrid A* 算法

### 2.1 原始论文要点

Hybrid A* 出自斯坦福 Junior 战车（DARPA Urban Challenge 2007 冠军车队）的实践论文《Practical Search Techniques in Path Planning for Autonomous Driving》。论文核心贡献：

1. 把 A* 从二维 (x, y) 栅格推广到三维 (x, y, θ) 连续状态空间，**每个 grid 内保留车辆真实的连续姿态**，从而保证搜索出来的路径运动学可行（满足最大曲率约束）。
2. 设计两类互补启发式：
   - **Non-holonomic without-obstacles heuristic**：考虑车辆运动约束但不考虑障碍物，使用 Reeds-Shepp / Dubins 曲线作为解析启发，避免车辆"贴着障碍物走折线"。
   - **Holonomic with-obstacles heuristic**：把车辆视作点，用 2D A* / DP 反向搜索终点到所有 grid 的代价图（DpMap），考虑障碍物但不考虑运动学。
   - 实际使用取二者的 `max`，兼顾 admissibility 与剪枝效率。
3. **Analytic Expansion（解析扩展）**：每次从 open set 弹出一个节点时，尝试用 RS 曲线直接连到终点，若该 RS 曲线无碰撞则直接结束搜索——这是 Hybrid A* 能在连续状态空间收敛到精确终点姿态的关键。
4. 第二阶段用数值非线性优化（Voronoi 场 + 平滑 + 曲率代价）对搜索路径做平滑，得到局部（往往全局）最优。

Junior 在停车场导航与堵塞道路 U 形转弯上表现完美，全周期重规划时间 50–300 ms。

### 2.2 Apollo 中的类结构

Apollo 把 Hybrid A* 实现在 `modules/planning/planners/open_space/`（早期版本在 `modules/planning/open_space/coarse_trajectory_generator/`），由四个核心类构成：

- **`Node2d`**：二维栅格节点，供 GridSearch 使用。成员：`x_, y_, grid_x_, grid_y_, path_cost_, heuristic_, cost_, index_, pre_node_`。
- **`Node3d`**：三维连续状态节点。成员除 (x_, y_, phi_) 外，还有：
  - `traversed_x_/traversed_y_/traversed_phi_`：本节点连接到父节点之间的一串路径点（一个 grid 内可能包含多个点）。
  - `x_grid_/y_grid_/phi_grid_`：三维栅格索引，组合成字符串作为 `index_`，用于 open_set / close_set 去重。
  - `steering_`：到达本节点所用的方向盘转角。
  - `direction_`：true 前进 / false 后退。
  - `step_size_`：本节点对应的路径点数。
- **`GridSearch`**：负责 2D A* 与 DpMap 生成。
  - `GenerateAStarPath()`：经典 2D A*（实际在 Hybrid A* 主流程中**已弃用**）。
  - `GenerateDpMap(ex, ey, XYbounds, obstacles)`：以终点为源，DP 反向求解到所有可达 grid 的 H-cost，存入 `dp_map_`（`unordered_map<string, shared_ptr<Node2d>>`），Hybrid A* 主循环里通过 `CheckDpMap()` O(1) 查询。
  - `GenerateNextNodes()`：上下左右 + 四对角共 8 个邻接节点。
  - `CheckConstraints()`：通过点到 `LineSegment2d` 的距离 vs `node_radius_` 判断碰撞。
- **`ReedShepp`**：给定起点 / 终点位姿，按 48 种（实际优化为更少）路径组合求最短 RS 曲线。
- **`HybridAStar`**：主类，持有 `open_set_` / `close_set_`（哈希表，空间换时间）+ `open_pq_`（优先队列，管理 cost 排序），持有 `reed_shepp_generator_` 与 `grid_a_star_heuristic_generator_`。

### 2.3 主流程（`HybridAStar::Plan`）

输入：起点 (sx, sy, sphi)、终点 (ex, ey, ephi)、XYbounds（4 元素 [xmin, xmax, ymin, ymax]）、障碍物顶点向量 `obstacles_vertices_vec`。输出：`HybridAStartResult* result`。

```
1. 清空容器；把 obstacles_vertices_vec 转 LineSegment2d 集合。
2. 构造 start_node_ / end_node_，做 ValidityCheck（碰撞 + 边界）。
3. grid_a_star_heuristic_generator_->GenerateDpMap(ex, ey, XYbounds, obstacles)
   —— 反向 DP 计算 H-cost 缓存（2D holonomic with-obstacles 启发）。
4. open_set_.emplace(start); open_pq_.emplace(start, start.cost)
5. while (!open_pq_.empty()):
     current_node = open_set_[open_pq_.top().first]; open_pq_.pop()
     if AnalyticExpansion(current_node):   // RS 曲线直达
         break
     close_set_.emplace(current_node)
     for i in [0, next_node_num_):
         next_node = Next_node_generator(current_node, i)   // 转向采样
         if next_node == nullptr: continue                  // 越界
         if next_node in close_set_: continue
         if not ValidityCheck(next_node): continue          // 碰撞
         if next_node not in open_set_:
             CalculateNodeCost(current_node, next_node)
             open_set_.emplace(next_node); open_pq_.emplace(next_node, next_node.cost)
6. GetResult() 回溯：reverse → pop_back 重叠点 → insert → reverse，得到正序无重叠路径点列。
7. GetTemporalProfile()：按换挡切分 + 五次多项式 S 曲线速度规划。
```

### 2.4 节点扩展（Next_node_generator）—— 关键的转向采样

Apollo 默认 `next_node_num_ = 10`：前 5 个为前进，后 5 个为后退。每个 i 对应一个方向盘转角采样点：

- 前进（i < 5）：`steering = -max_steer + (2·max_steer / (n/2 - 1)) · i`，`traveled_distance = +step_size`
- 后退（i ≥ 5）：`steering` 同公式（用 `i - n/2`），`traveled_distance = -step_size`

得到 (steering, traveled_distance) 后，用**以后轮轴中心为参考的自行车模型**前向积分：

```
arc = √2 · xy_grid_resolution_          # grid 对角线近似为单 grid 最大弧长
for i in [0, arc / step_size):           # step_size 默认 0.5 m
    next_x = last_x + traveled_distance · cos(last_phi)
    next_y = last_y + traveled_distance · sin(last_phi)
    next_phi = NormalizeAngle(last_phi + traveled_distance / L · tan(steering))
```

其中 `L = wheel_base`。运动学方程：

$$
\begin{bmatrix} x' \\ y' \\ \theta' \end{bmatrix} = s \cdot \begin{bmatrix} \cos\theta \\ \sin\theta \\ \dfrac{\tan\phi}{L} \end{bmatrix}
$$

由于 grid 内最多行进 `arc`，而 `step_size_=0.5`，每个 Node3d 实际只含 2 个路径点（当前 grid 一个 + 下一 grid 一个）。

### 2.5 代价函数（CalculateNodeCost）

```
Cost_next = Cost_cur
          + flag_forward · w_forward · step · (step_size - 1)
          + flag_backward · w_backward · step · (step_size - 1)
          + flag_switch · w_gear_switch
          + w_steer · |φ_next|
          + w_steer_change · |φ_next - φ_cur|
```

启发代价 `HoloObstacleHeuristic` 通过 `CheckDpMap()` 查询得到。RS 曲线启发 `ReedSheppHeuristic` 则考虑前进 / 后退、换挡、转角代价。

### 2.6 AnalyticExpansion —— RS 曲线"偷懒"加速

每次弹出节点都尝试：用 RS 曲线连接 current_node → end_node，对曲线离散化后做碰撞与边界检测，若整条 RS 曲线无碰撞则把该 RS 曲线作为剩余路径直接拼到结果中并 `break` 搜索。这是 Hybrid A* 在连续状态空间收敛到精确终点姿态的关键，避免栅格离散带来的"永远到不了精确终点"问题。

### 2.7 速度规划（GetTemporalProfile）

`TrajectoryPartition()`：根据相邻路径点的运动方向与车头朝向夹角判断换挡，按换挡点把整条路径切成多段。
`GenerateSCurveSpeedAcceleration()`：对每段用 QP 求解五次多项式 piecewise quintic polynomial 速度曲线，得到 v, a 序列并填入 `SpeedData`。也可通过 `FLAGS_use_s_curve_speed_smooth` 切换不同平滑方式。

输出结构体：

```cpp
struct HybridAStartResult {
  std::vector<double> x;             // 位置姿态 x_k
  std::vector<double> y;
  std::vector<double> phi;
  std::vector<double> v;             // 速度
  std::vector<double> a;             // 加速度（控制 u_k）
  std::vector<double> steer;         // 方向盘转角（控制 u_k）
  std::vector<double> accumulated_s; // 累计弧长
};
```

这一结果即 TDR-OBCA 论文中的 **temporal profile warm start**（T）。

---

## 3. Reeds-Shepp 曲线

### 3.1 原始论文与定义

1990 年 Reeds 与 Shepp 在 Pacific J. Math. 发表《Optimal paths for a car that goes both forwards and backwards》。考虑一辆**最小转弯半径归一化为 1**、**既可前进也可后退**的汽车（Dubins 车的"可换挡"扩展），证明：任意起点到终点之间存在最短路径，且该最短路径必属于有限种"圆弧 + 直线"的组合之一。

- **C**：单位圆弧（半径 1，即最大曲率弧）
- **S**：直线段
- **|**：运动方向切换（前进↔后退）
- **L / R**：左转 / 右转圆弧（C 的两种方向）
- **上标 +/−**：前进 / 后退

车辆中心轨迹由若干段最大曲率圆弧 + 至多一段直线拼接而成，路径长度为各段弧长 + 直线长之和。

### 3.2 与 Dubins 曲线的差异

Dubins（1957）：车辆**只能前进**，最短路径属于 6 种组合之一：LSL / RSR / RSL / LSR / RLR / LRL。
Reeds-Shepp：车辆**可前进可后退**，最短路径属于 48 种组合（实际后人证明其中 2 种不会最优，搜索范围可缩到 46 种）。RS 是 Dubins 的扩展：Dubins 6 种是 RS 中"无方向切换"的特例。

由于允许方向切换，RS 曲线中**允许尖瓣（cusp）存在**——车辆前进到某点后倒挡原路回退一段，这在泊车（侧方位、垂直泊入）中至关重要。

### 3.3 9 个基础 word 与 3 种对称变换 → 48 种组合

Reeds-Shepp 用紧凑符号列出**基础轨迹类型**：

| 类型 | 表达式 | 说明 |
|---|---|---|
| 1 | C\|C\|C | 三段反向圆弧（每段之间换挡） |
| 2 | C\|CC | 前两段反向 |
| 3 | CC\|C | 后两段反向 |
| 4 | C\|C_β C_β | 中段两段等长圆弧 |
| 5 | CC_β \|C_β C | 中间一对等长 + 末段对偶 |
| 6 | C\|C_β C_β\|C | 中间一对等长，前后两段方向各反 |
| 7 | CSC | 圆-直-圆 |
| 8 | C\|C_{π/2} SC | 第 1 段圆 + π/2 反向圆 + 直 + 圆 |
| 9 | CSC_{π/2}\|C | 圆 + 直 + π/2 反向圆 + 圆 |
| 10 | C\|C_{π/2} SC_{π/2}\|C | 两端各插入 π/2 反向圆 |

把 C 替换为 L 或 R 后，借助三种对称变换可由少量公式覆盖全部 48 种：

- **timeflip（时间翻转）**：把曲线运动方向整体取反。从 (0,0,0) 到 (x,y,θ) 的最短路径与从 (0,0,0) 到 (−x,−y,−θ) 的最短路径关于起点中心对称。
- **reflect（反射）**：把圆周方向 L↔R 整体取反。从 (0,0,0) 到 (x,y,θ) 的路径与从 (0,0,0) 到 (x,−y,−θ) 的路径关于 x 轴对称。
- **backwards（向后变换）**：把 word 逆序排列。从 (0,0,0) 到 (x,y,θ) 的路径与从 (0,0,0) 到 (x·cosθ + y·sinθ, x·sinθ − y·cosθ, θ) 的路径关于终点中心对称。

每个基础 word 通过 (timeflip, reflect, backwards) 三种变换最多可衍生 4 条等价路径，因此 12 类基础公式 × 4 ≈ 48 种字段组合（部分 word 在变换后退化，最终得到论文枚举的 48 种）。Apollo 在 `reeds_shepp.cc` / `reeds_shepp_path.h` 中对每种 word 写了对应的解析求解函数（如 `LRL`, `RSR`, `LSL`, `LSR`, `CCu_Cu_C`, `C_Cu_CuC`, `C_Cpi2_S_C`, `C_SCpi2_C`, `C_Cpi2_S_Cpi2_C` 等），各自返回 (t, u, v) 三段长度与方向，再以 `shortest = min(L)` 选最优。

### 3.4 最短路径求解示例

设起点 (0,0,0)、终点 (x,y,θ)（已先变换到 RS 标准坐标系：起点为原点，半径归一为 1）。`R(·,·)` 表示笛卡尔 → 极坐标变换 `(x,y) → (r, θ)`，`M(·)` 为角度归一化到 [−π, π]。

**C|C|C**（如 L+R−L+）：

$$
\begin{aligned}
(u_1, t_1) &= R(x - \sin\theta,\, y - 1 + \cos\theta) \\
u_1^2 &> 4 \Rightarrow L = \infty \quad (\text{该 word 不可行}) \\
u_1^2 &\le 4 \Rightarrow
\begin{cases}
A = \arcsin(u_1^2 / 4) \\
u = M(A + t_1) \\
t = t_2,\quad v = M(\theta + t - u) \\
L = |t| + |u| + |v|
\end{cases}
\end{aligned}
$$

其中 A ∈ [π/2, π]。t、u、v 即三段圆弧的弧度（也是弧长，因 R=1）。Apollo 中类似的公式在 `reeds_shepp.cc` 的对应函数内逐字实现，并按 (t, u, v, mode) 写回 ` ReedSheppPath` 结构体。

### 3.5 在 Hybrid A* 中的作用

- **作为解析启发**：用 `ReedShepp::ShortestRSP(current, end)` 直接得到无障碍最短 RS 路径长度，作为非完整约束启发 h_RS（不考虑障碍物）。
- **作为 AnalyticExpansion**：每次弹出节点尝试用 RS 曲线直达终点，做碰撞 + 边界检测，无碰撞则直接结束搜索。

值得注意的是：**RS 曲线本身不感知障碍物**，所以必须配合碰撞检测使用。论文已证明：只要存在一条连接起止位姿的无碰撞路径，就一定存在无碰撞的 RS 曲线（虽然理论存在性不等同于高效搜索，Hybrid A* 用启发 + AnalyticExpansion 巧妙规避了这个问题）。

---

## 4. OBCA 算法（Optimization-Based Collision Avoidance）

### 4.1 思想

OBCA 论文（arXiv:1711.03449）的核心思想：把"主车"和"障碍物"都描述为**凸集**（多边形 / 椭球 / 凸多面体），用**拉格朗日对偶**把"两集合不相交"这一难以直接处理的碰撞约束转化为可微、可二阶可微的对偶形式，从而把避障嵌入到一个标准的非线性优化（MPC）框架中。

### 4.2 记号与建模

- **主车 (ego)**：原点处的占地区域 $B := \{y : G y \succeq_{\bar K} g\}$（凸多边形，G、g 由车长 / 车宽 / 后轴偏移确定）。k 时刻主车占地区域为
  $$E(x_k) = R(x_k) B + t(x_k)$$
  其中 R 为旋转矩阵（航向角 φ），t 为平移 (x, y)。
- **障碍物 m**：$O^{(m)} = \{y : A^{(m)} y \preceq_K b^{(m)}\}$（凸多边形，Apollo 中由感知顶点经 `FormulateBoundaryConstraints` 转化为 A、b）。
- **不碰撞**：$E(x_k) \cap O^{(m)} = \varnothing,\ \forall m$。
- **动力学**：$x_{k+1} = f(x_k, u_k)$，Apollo 用二自由度自行车模型。
- **状态约束**：$h(x_k, u_k) \le 0$（转角 / 加速度上下界 → 动力学 + 舒适性）。
- **目标**：$J = \sum_{k=0}^{N} l(x_k, u_k)$，l 二阶可微。

### 4.3 距离函数与对偶变换

定义主车与障碍物 m 的距离：

$$
\mathrm{dist}(E(x), O^{(m)}) = \min_{e, o} \{ \|e - o\| : A^{(m)} o \preceq_K b^{(m)},\ e \in E(x) \}
$$

把 e 替换为 $R(x)e' + t(x)$（$e' \in B$），引入辅助变量 w = R(x)e' + t(x) − o，问题变为：

$$
\min_{e', o, w} \|w\| \quad \text{s.t.}\ A^{(m)} o \le b^{(m)},\ G e' \le g,\ R(x)e' + t(x) - o = w
$$

对其求拉格朗日对偶。由于 $O^{(m)}$ 与 B 都是非空有界闭凸集，**Slater 条件成立 → 强对偶**，对偶问题的最优值等于原问题最优值。对偶函数有下确界的条件给出：

$$
\|z\|_* \le 1,\quad (A^{(m)})^T \lambda = z,\quad G^T \mu = z
$$

下确界为 $-g^T \mu + (A^{(m)} t(x) - b^{(m)})^T \lambda$。最终得到**对偶形式**：

$$
\begin{aligned}
\max_{\mu, \lambda}\ & -g^T \mu + (A^{(m)} t(x) - b^{(m)})^T \lambda \\
\text{s.t.}\ & G^T \mu + R(x)^T (A^{(m)})^T \lambda = 0 \\
& \|(A^{(m)})^T \lambda\|_* \le 1 \\
& \lambda \succeq_{K^*} 0,\ \mu \succeq_{\bar K^*} 0
\end{aligned}
$$

由于 2-范数 + 多边形描述，所有约束均二阶可微，可直接喂给 IPOPT。

### 4.4 Signed Distance（侵入距离）

为了让"优化失败时也尽量少侵入"，论文引入 signed distance：

$$
\mathrm{sd}(E(x), O) := \mathrm{dist}(E(x), O) - \mathrm{pen}(E(x), O)
$$

其中 $\mathrm{pen}$ 是把 E 沿最小范数向量 t 平移直到与 O 不相交所需的最小 |t|（侵入深度）。把硬约束 $\mathrm{dist} > d_{min}$ 改为带松弛变量 s 的软约束：

$$
-g^T \mu_k^{(m)} + (A^{(m)} t(x_k) - b^{(m)})^T \lambda_k^{(m)} \ge -s_k^{(m)},\ s_k^{(m)} \ge 0
$$

### 4.5 OBCA 最终优化模型

$$
\begin{aligned}
\min_{x, u, s, \lambda, \mu}\ & \sum_{k=0}^{N} \big[ l(x_k, u_k) + \kappa \sum_{m=1}^{M} s_k^{(m)} \big] \\
\text{s.t.}\ & x_0 = x_S,\ x_N = x_F \\
& x_{k+1} = f(x_k, u_k) \\
& h(x_k, u_k) \le 0 \\
& -g^T \mu_k^{(m)} + (A^{(m)} t(x_k) - b^{(m)})^T \lambda_k^{(m)} \ge -s_k^{(m)} \\
& G^T \mu_k^{(m)} + R(x_k)^T (A^{(m)})^T \lambda_k^{(m)} = 0 \\
& \|(A^{(m)})^T \lambda_k^{(m)}\|_* = 1 \\
& s_k^{(m)} \ge 0,\ \lambda_k^{(m)} \succeq 0,\ \mu_k^{(m)} \succeq 0 \\
& \text{for } k = 0, \ldots, N,\ m = 1, \ldots, M
\end{aligned}
$$

其中 $\lambda_k^{(m)}, \mu_k^{(m)}$ 是与障碍物 $O^{(m)}$ 在 k 步相关的对偶变量，$s_k^{(m)}$ 是松弛（侵入深度）变量。**对偶变量同时被作为决策变量优化**——这是 OBCA 与传统"距离场 + 软约束"方法的根本区别：它把避障精确化为原问题的对偶形式，避免了距离场梯度在障碍物边界的奇异点。

初始猜测：用 A* / Hybrid A* 搜索结果作为 warm start（OBCA 原论文）。

---

## 5. TDR-OBCA：Apollo 改进与 DualVariableWarmStartProblem

### 5.1 改进点

TDR-OBCA 论文（arXiv:2009.11345，Apollo 工程化依据）在 H-OBCA 基础上做了 3 件事：

- **T**emporal profile warm start：用 Hybrid A* 直接给出 $\tilde{x}^*(k)$（位姿 + 速度）。
- **D**ual variable warm start：构造一个独立的小型优化问题，在 $\tilde{x}^*$ 上预解 (λ, μ)。
- **R**eformulation：把硬约束 $\mathrm{dist} > d_{min}$ 改为带松弛 $d$ 的等式约束，并把末状态误差与 $d$ 一起放进目标函数，提高数值稳定性。

### 5.2 状态 / 控制与动力学

$$
x(k) = [x_x, x_y, x_v, x_\phi]^T \in \mathbb{R}^4,\quad u(k) = [\delta, a]^T \in \mathbb{R}^2
$$

二自由度自行车模型离散化（dt 为采样时间）：

$$
\begin{aligned}
x_x(k+1) &= x_v(k) \cos(x_\phi) \cdot dt + x_x(k) \\
x_y(k+1) &= x_v(k) \sin(x_\phi) \cdot dt + x_y(k) \\
x_\phi(k+1) &= x_v(k) \cdot \tan(\delta(k)) / L \cdot dt + x_\phi(k) \\
x_v(k+1) &= a(k) \cdot dt + x_v(k)
\end{aligned}
$$

### 5.3 DualVariableWarmStartProblem —— 对偶变量 warm start

固定 $\tilde{x}^*(k)$（Hybrid A* 结果），优化 (μ, λ, d)。d 是"主车与障碍物 m 在 k 时刻的安全距离的负值"，因此 d<0 越小（越负）越好，对应 min 问题：

$$
\begin{aligned}
\min_{\mu, \lambda, d}\ & w \sum_{m=1}^{M} \sum_{k=1}^{K} d_m(k) \\
\text{s.t.}\ & \|A_m^T \lambda_m(k)\|_2 \le 1 \\
& G^T \mu_m(k) + R(\tilde{x}^*(k))^T A_m^T \lambda_m(k) = 0 \\
& -g^T \mu_m(k) + (A_m t(\tilde{x}^*(k)) - b_m)^T \lambda_m(k) + d_m(k) = 0 \\
& \lambda_m(k) \succeq 0,\ \mu_m(k) \succeq 0,\ d_m(k) < 0 \\
& \text{for } k = 1, \ldots, K,\ m = 1, \ldots, M
\end{aligned}
$$

该问题含二阶约束 + 二次项，是 **QCQP（二次约束二次规划）**，求解困难。Apollo 把 $\|A_m^T \lambda\|_2 \le 1$ 硬约束软化为目标里的 $\frac{1}{\beta}\|A_m^T \lambda\|_2^2$，转化为 **QP**，由 OSQP 求解（`dual_variable_warm_start_problem.cc`）。

### 5.4 主优化问题（distance_approach_ipopt_fixed_ts）

TDR-OBCA 主问题目标函数：

$$
\begin{aligned}
l(x(k), u(k{-}1)) &= \alpha_x \|x(k)\|_2^2 + \alpha_{x'} \|x(k) - x(k{-}1)\|_2^2 \\
&\quad + \alpha_u \|u(k{-}1)\|_2^2 + \alpha_{\tilde u} \|u(k{-}1) - \tilde u(k{-}1)\|_2^2
\end{aligned}
$$

四项分别为：位置 / 姿态的二阶光滑、控制能量、控制光滑性。再叠加末状态惩罚与松弛惩罚：

$$
\mathcal{J}(x, u, d) = \sum_{k=1}^{K} l(x(k), u(k{-}1)) + \alpha_e \|x(K) - x_F\|_2^2 + \beta \sum_{m=1}^{M} \sum_{k=1}^{K} d_m(k)
$$

约束与 5.3 相同，但 $x, u, d, \lambda, \mu$ 全部作为决策变量联合优化，由 IPOPT 求解（实现类 `DistanceApproachIPOPTInterface` / `distance_approach_problem_wrapper.cc`，Apollo 提供四个变体：

- **DISTANCE_APPROACH_IPOPT_FIXED_TS**：采样时间固定（默认主用版本）。
- **DISTANCE_APPROACH_IPOPT**：采样时间可变，把 dt 也作为变量优化。
- **DISTANCE_APPROACH_IPOPT_RELAX_END**：末状态松弛，放宽终点收敛。
- **DISTANCE_APPROACH_IPOPT_FIXED_DUAL**：固定对偶变量，简化为纯状态优化。

### 5.5 失败回退：IterativeAnchoringSmoother（DL-IAPS）

当 OBCA 求解失败（IPOPT 不收敛或结果不满足约束），Apollo 切换到 `IterativeAnchoringSmoother`（DL-IAPS = Dual Loop Iterative Anchoring Path Smoothing）。流程：

1. `CheckGear()`：根据初始 heading 与行进方向夹角判断前进 / 后退挡（`|NormalizeAngle(init_tracking_angle - init_heading_angle)| < π/2`）。
2. 把 Hybrid A* 路径 `xWS` 转 `DiscretizedPath`，按 `interpolated_delta_s` 线性插值加密。
3. `AdjustStartEndHeading()`：调整首末点 heading，保证 heading 连续。
4. `SetPathProfile()`：用 `ComputePathProfile()` 由离散 (x, y) 反算 θ, κ, dκ, accumulated_s。
5. `GenerateInitialBounds()`：为每个路径点生成避障 bound（默认 uniform `default_bound`，或按到障碍物线段实际距离动态计算）。
6. `CheckCollisionAvoidance()`：自车 Box2d 与障碍物 LineSegment2d `hasOverlap()`，碰撞点入 `input_colliding_point_index_`。
7. `ReAnchoring()`：对碰撞点用**正态分布随机采样**重新摆位直到不碰撞（位置 / 距离方差 `reanchoring_pos_stddev` / `reanchoring_length_stddev`，截断到 ±2σ，尝试 `reanchoring_trails_num` 次）。首两个 / 末两个碰撞点直接判失败。
8. `AdjustPathBounds()`：对碰撞点 bound 乘 `collision_decrease_ratio` 放松。
9. `FemPosDeviationSmoother.Solve()`：调用 Apollo 的离散点平滑库（FEM Position Deviation Smoother，参考 OSQP 实现），输出平滑 (x, y)。
10. `SetPathProfile()` + `CheckCollisionAvoidance()`：再算 κ 与碰撞检测。
11. `SmoothSpeed()`：构造 `PiecewiseJerkSpeedProblem` 做分段 jerk 速度规划；旧版本用 `QuinticPolynomialCurve1d` 拟合到 v_end=0。
12. `CombinePathAndSpeed()` + `AdjustPathAndSpeedByGear()`：按挡位把横纵向合成 `DiscretizedTrajectory`，后退挡下 θ→θ+π、s→−s、κ→−κ、v→−v、a→−a。

DL-IAPS 不解大型 NLP，只做"分段离散点平滑 + 随机重锚"，比 OBCA 鲁棒但精度较差，是工程上的"兜底通道"。可通过 `planning.conf` 的 `use_iterative_anchoring_smoother` 与 `enable_parallel_trajectory_smoothing` 开关选择。

---

## 6. OPEN_SPACE_TRAJECTORY_PARTITION

### 6.1 目的

Hybrid A* + 平滑后输出的轨迹是**整段连续轨迹**，其中可能既含前进段又含后退段（典型泊车一把进不去时多段切换）。Control 模块一次只能执行一个方向（前进挡或后退挡），且需要按车辆当前位置下发对应分段。`OpenSpaceTrajectoryPartition`（`open_space_trajectory_partition.cc`）负责：

1. 按换挡点把整条轨迹切成多段（每段单一方向）。
2. 根据自车当前位置选择当前应下发的分段。
3. 判断是否需要切换到下一段（前一段是否走完）。

### 6.2 关键函数

- `CheckTrajTraversed()`：检测"已走完的路径段"集合，与历史下发编码比对（注意循环条件只比对已完成段，不比对当前正在走的段）。
- 换挡判定：相邻轨迹点用 `tracking_angle`（行进方向）与 `heading_angle`（车头朝向）夹角判断，若 `|NormalizeAngle(tracking - heading)| ≥ π/2` 则换挡。
- 切分时 `partitioned_result->emplace_back()` 添加空容器再填充内容。
- `InsertRotateBackwardPath()` 等辅助函数处理换挡点附近的轨迹衔接。

### 6.3 适配分段执行

把切分后的分段按时间戳 + 弧长重排，下发时只发送"当前段 + 缓冲段"，控制模块按段执行；走完一段切换下一段，避免大段轨迹一次性下发导致的时延 / 失效问题。

---

## 7. OPEN_SPACE_FALLBACK_DECIDER

### 7.1 失败回退逻辑

`OpenSpaceFallbackDecider`（`open_space_fallback_decider.cc`）是 Open Space 流水线的最后一道安全防线。当：

- Hybrid A* 找不到路径（搜索超时 / open_pq 空了仍没到终点），
- OBCA / DL-IAPS 平滑失败，
- 已规划轨迹在执行过程中与障碍物发生碰撞，

`OpenSpaceFallbackDecider::Process(Frame*)` 被触发：

1. `predicted_bounding_rectangles`：基于障碍物预测构建未来时刻的 Box2d 序列。
2. 对每个轨迹点构造自车 Box2d，与预测障碍物 Box 序列做 `hasOverlap()`。
3. 找到 `first_collision_index`——第一个发生碰撞的轨迹点。
4. 用 `QuardraticFormulaLowerSolution(a, b, c, *sol)` 解一元二次 `a·t² + b·t + c = 0`，取较小解作为"在碰撞前停下"的时间。
5. 生成一段"减速到停在 first_collision_index 之前"的 fallback 轨迹下发给 Control。
6. 标记 `FALLBACK` 状态，下一周期触发 OPEN_SPACE_TRAJECTORY_PROVIDER 重新规划。

### 7.2 QuadraticFormulaLowerSolution

```cpp
double tmp = b*b - 4*a*c;
if (tmp < kEpsilon) return false;
double sol1 = (-b + sqrt(tmp)) / (2*a);
double sol2 = (-b - sqrt(tmp)) / (2*a);
*sol = abs(min(sol1, sol2));
```

物理含义：自车以当前速度 / 加速度行驶，要使位移等于到碰撞点的距离，求所需的减速时间，取较小（更早）的解保证安全裕量。

---

## 8. Apollo 源码实现概览

### 8.1 目录结构（Apollo 7.x / 8.x / 10.x）

```
modules/planning/
├── planners/
│   └── open_space/
│       ├── hybrid_a_star.h/.cc              # Hybrid A* 主类
│       ├── node3d.h/.cc                     # 三维节点
│       ├── grid_search.h/.cc                # 2D A* + DpMap
│       ├── reeds_shepp_path.h/.cc           # RS 曲线 48 种 word
│       ├── open_space_trajectory_optimizer.h/.cc
│       ├── distance_approach_problem_wrapper.h/.cc
│       ├── distance_approach_ipopt_interface.h/.cc
│       ├── distance_approach_ipopt_fixed_ts_interface.h/.cc
│       ├── distance_approach_ipopt_relax_end_interface.h/.cc
│       ├── distance_approach_ipopt_fixed_dual_interface.h/.cc
│       ├── dual_variable_warm_start_problem_wrapper.h/.cc
│       ├── dual_variable_warm_start_osqp_interface.h/.cc
│       ├── dual_variable_warm_start_ipopt_interface.h/.cc
│       ├── iterative_anchoring_smoother.h/.cc
│       ├── fem_pose_deviation_smoother.h/.cc
│       ├── planner_open_space_config.proto  # 全部标定参数
│       └── trajectory_smoother/...
├── tasks/
│   └── optimizers/
│       ├── open_space_trajectory_generation/
│       │   └── open_space_trajectory_provider.h/.cc   # 状态机 + 多线程
│       ├── open_space_trajectory_partition/
│       │   └── open_space_trajectory_partition.h/.cc
│       └── ...
├── scenarios/
│   ├── valet_parking/
│   ├── park_and_go/
│   ├── pull_over/
│   └── narrow_street_u_turn/
└── conf/scenario/valet_parking_config.pb.txt
```

### 8.2 OpenSpaceTrajectoryProvider

`OPEN_SPACE_TRAJECTORY_PROVIDER` 的实现类。职责：
- 维护状态机（OK / replan / stop / fallback）。
- 启动独立线程做规划计算（`std::thread` + `std::mutex`），避免阻塞主 Planning 周期。
- 调用 `OpenSpaceTrajectoryOptimizer::Plan()`，把结果存入 `Frame` 的 `open_space_info`。
- 多线程同步通过 `UNIQUE_LOCK_MULTITHREAD` 锁保护 `AppendSpeedPoint` 等共享写入。

### 8.3 OpenSpaceTrajectoryOptimizer::Plan

```
1. 标定参数加载（PlannerOpenSpaceConfig）。
2. HybridAStar::Plan(...) → 得到 xWS (Hybrid A* 结果, k+1 个 HybridAStartResult)。
3. if use_dual_variable_warm_start:
     DualVariableWarmStartProblem::Solve() → 得到 λ, μ warm start。
4. if use_iterative_anchoring_smoother:
     IterativeAnchoringSmoother::Smooth() → 分段 DL-IAPS 平滑。
   else:
     DistanceApproachProblem::Solve() (distance_approach_ipopt_fixed_ts) → OBCA 主优化。
5. 把平滑后的轨迹合成 DiscretizedTrajectory 输出。
```

### 8.4 OpenSpaceRoiDecider

`OPEN_SPACE_ROI_DECIDER` 的实现类。`Process(Frame*)` 根据 `roi_type` 分支：
- **PARKING**：`GetParkingSpot` 找车位四角点 → `SetOrigin` 设原点 → `SetParkingSpotEndPose` 设终点 → `GetParkingBoundary` 取车位边界。
- **DEADEND** / **PULL_OVER** / **PARK_AND_GO**：各自分支处理。
- 最后 `FormulateBoundaryConstraints(roi_boundary, frame)`：把障碍物顶点转为线性方程（A, b），把 ROI 边界也作为虚拟障碍物，输出给后续 OBCA。

### 8.5 关键标定参数（planner_open_space_config.pb.txt）

```
warm_start_config {
  step_size: 0.5            # Hybrid A* 步长 (m)
  next_node_num: 10         # 转向采样数 (前 5 + 后 5)
  max_steer_angle: ...
  xy_grid_resolution: 0.3   # 栅格分辨率 (m)
  delta_t: 0.5              # 速度规划 / OBCA 采样时间
  traj_forward_penalty / traj_back_penalty / traj_gear_switch_penalty
  traj_steer_penalty / traj_steer_change_penalty
  heu_rs_forward_penalty / heu_rs_back_penalty
  heu_rs_gear_switch_penalty / heu_rs_steer_penalty / heu_rs_steer_change_penalty
}
distance_approach_config { ... weight_x / weight_u / weight_steer / ... }
iterative_anchoring_smoother_config { ... reanchoring_pos_stddev / reanchoring_length_stddev / ... }
```

---

## 9. AuroraDrive 简化版 Open Space 迁移建议

### 9.1 现状判断

AuroraDrive（Aurora Driver）面向高速货运卡车场景，其路径规划基于"结构化道路 + 前向 A\*"：
- 现有 A\* 仅考虑前向运动，无倒车能力。
- 无 (x, y, θ) 三维状态空间搜索，无 RS 曲线启发。
- 无 OBCA / DL-IAPS 平滑通道。
- 应用场景以车道保持、跟车、变道为主，不覆盖泊车 / 起步 / 窄道掉头。

若需要为 AuroraDrive 增加"游戏辅助模式下的车位识别 / 起步"等低速泊车能力，建议**只迁移 Hybrid A\* + RS 曲线启发**，不迁移 OBCA / DualVariableWarmStart / DL-IAPS 这一整套 NLP 平滑通道，原因：
- 卡车泊车场景曲率约束宽松（停车场内速度极低，曲率突变可由 Control 模块吸收）。
- OBCA 涉及 IPOPT 大型 NLP，对算力 / 标定 / 调试要求高，移植成本与游戏辅助模式收益不匹配。
- Hybrid A* 输出的"粗但可行"路径已足够支撑车位识别 / 起步这类低动态需求。

### 9.2 简化版 Open Space 设计

**模块边界**：在 AuroraDrive Planning 中新增一个 `OpenSpacePlanner` 子模块，仅在"低速 + 非结构化场景"被 scenario 选择器激活，不参与高速 Public Road 流水线。

**输入接口**：
```
OpenSpacePlanner::Plan(
    start_pose (x, y, theta),
    end_pose   (x, y, theta),
    roi_polygon  (Polygon2d),
    obstacles    (vector<Polygon2d>),
    vehicle_param (wheel_base, max_steer, length, width),
    config       (step_size, xy_grid_resolution, next_node_num, penalties...)
) -> vector<Pose2d>
```

**算法栈（最小可用版）**：

1. **Node3d / Node2d**：直接移植 Apollo 结构（x, y, phi, grid 索引, traversed 路径点）。
2. **GridSearch::GenerateDpMap**：移植 2D DP 启发（holonomic with-obstacles），用 ROI 内反向 DP 求 H-cost 缓存表。
3. **ReedShepp**：移植 `reeds_shepp.cc` 全部 12 个基础公式 + timeflip/reflect/backwards 对称变换，提供 `ShortestRSP(start, end)` 与 `ShortestRSPDistance()`。
4. **HybridAStar::Plan**：移植主循环（open_set / close_set / open_pq + AnalyticExpansion + Next_node_generator + CalculateNodeCost），自行车模型前向积分。
5. **速度规划**：可选移植 `GenerateSCurveSpeedAcceleration` 五次多项式，或简化为"低速恒速 + 末段减速"分段速度。
6. **不迁移**：
   - DualVariableWarmStartProblem（OSQP 对偶 warm start）
   - DistanceApproachIPOPTInterface（OBCA 主 NLP）
   - IterativeAnchoringSmoother（DL-IAPS 分段平滑 + 随机重锚）
   - OPEN_SPACE_FALLBACK_DECIDER 的复杂二次型停车轨迹（简化为"发现碰撞即急停 + 触发重规划"）

**碰撞检测简化**：直接用 Box2d::hasOverlap，不做 Minkowski 膨胀；安全裕量通过把车辆 Box 整体放大一个 `safety_buffer` 实现。

**换挡与分段**：保留 OPEN_SPACE_TRAJECTORY_PARTITION 的核心思想——按行进方向与车头朝向夹角切分前 / 后向分段，按车辆位置选择下发段。

### 9.3 应用场景

- **游戏辅助模式下的车位识别**：用户在停车场内激活"自动泊车辅助"，Perception 给出空车位四角点 + 周边障碍物 → OpenSpacePlanner 一次性规划出"前进 / 倒车"多段轨迹 → 按段下发 Control 执行。
- **起步驶离**：车辆从车位或路边起步，需要先倒一把再前进驶出 → OpenSpacePlanner 处理含倒车的初始姿态规划。
- **窄道掉头（可选）**：在窄路上需要"几把轮"掉头时，OpenSpacePlanner 提供带倒车的拓扑可行路径。

### 9.4 风险与注意事项

1. **Hybrid A* 输出曲率不连续**：相邻圆弧衔接处曲率突变，卡车低速时影响有限但需 Control 模块验证。
2. **RS 曲线 48 种组合的数值稳定性**：部分公式在退化情况（如终点恰在起点圆弧上）需小心处理 `arcsin` 域；建议直接复用 Apollo `reeds_shepp.cc` 的实现，避免重写。
3. **DpMap 内存占用**：与 ROI 面积 / grid 分辨率成正比，卡车场景 ROI 较大时需调大 `xy_grid_resolution`（如 0.5 m）。
4. **多线程**：Hybrid A* 单次规划 50–300 ms，建议像 Apollo 一样在独立线程跑，主 Planning 周期下发生效结果。
5. **未来扩展路径**：若实际验证发现曲率突变导致 Control 跟踪误差大，可再考虑迁移 IterativeAnchoringSmoother（DL-IAPS 比 OBCA 简单得多），最后才考虑迁移完整 OBCA。

---

## 10. 关键源码 / 文献索引

### 10.1 论文

- Dolgov D., Thrun S., Montemerlo M., Diebel J. **Practical Search Techniques in Path Planning for Autonomous Driving**. AAAI Workshop on Intelligent Driving, 2007；扩展版发表于 IJRR 2008.
- Reeds J. A., Shepp L. A. **Optimal paths for a car that goes both forwards and backwards**. Pacific J. Math., 145(2): 367–393, 1990. https://projecteuclid.org/euclid.pjm/1102645450
- Zhang X., Liniger A., Borrelli F. **Optimization-Based Collision Avoidance**. arXiv:1711.03449.
- Zhang X., Liniger A., Sakai A., Borrelli F. **Autonomous Parking using Optimization-Based Collision Avoidance**. IEEE CDC 2019.
- **TDR-OBCA: A Reliable Planner for Autonomous Driving in Free-Space Environment**. arXiv:2009.11345.

### 10.2 Apollo 源码（master 分支）

- `modules/planning/planners/open_space/hybrid_a_star.cc` —— Hybrid A* 主类
- `modules/planning/planners/open_space/node3d.cc` —— 三维节点
- `modules/planning/planners/open_space/grid_search.cc` —— 2D A* + DpMap
- `modules/planning/planners/open_space/reeds_shepp_path.cc` —— RS 48 种 word
- `modules/planning/planners/open_space/open_space_trajectory_optimizer.cc` —— 4 模块总调度
- `modules/planning/planners/open_space/dual_variable_warm_start_problem_wrapper.cc` —— 对偶 warm start
- `modules/planning/planners/open_space/distance_approach_problem_wrapper.cc` —— OBCA 主问题
- `modules/planning/planners/open_space/distance_approach_ipopt_fixed_ts_interface.cc` —— IPOPT 接口
- `modules/planning/planners/open_space/iterative_anchoring_smoother.cc` —— DL-IAPS
- `modules/planning/tasks/optimizers/open_space_trajectory_generation/open_space_trajectory_provider.cc` —— 状态机 + 多线程
- `modules/planning/tasks/optimizers/open_space_trajectory_partition/open_space_trajectory_partition.cc` —— 轨迹分段
- `modules/planning/tasks/deciders/open_space_fallback_decider.cc` —— 回退决策
- `modules/planning/tasks/deciders/open_space_roi_decider.cc` —— ROI 计算
- `modules/planning/conf/scenario/valet_parking_config.pb.txt` —— 场景配置

### 10.3 调试工具

- `modules/tools/open_space_visualization/distance_approach_visualizer.py` —— OBCA 求解过程可视化。

---

## 附：Hybrid A* 算法流程伪代码（Apollo 实现）

```
function HybridAStar::Plan(sx, sy, sphi, ex, ey, ephi, XYbounds, obstacles_vertices):
    # 1. 准备
    obstacles_linesegments = vertices_to_linesegments(obstacles_vertices)
    start_node = Node3d(sx, sy, sphi, XYbounds, config)
    end_node   = Node3d(ex, ey, ephi, XYbounds, config)
    ValidityCheck(start_node); ValidityCheck(end_node)

    # 2. 反向 DP 求 H-cost 缓存（2D holonomic-with-obstacles 启发）
    grid_a_star_heuristic_generator.GenerateDpMap(ex, ey, XYbounds, obstacles_linesegments)

    # 3. 初始化
    open_set = { start_node.index: start_node }
    open_pq  = priority_queue([(start_node.index, start_node.cost)])
    close_set = {}

    # 4. 主循环
    while not open_pq.empty():
        cur_id   = open_pq.top().first;  open_pq.pop()
        cur_node = open_set[cur_id]

        # 4a. RS 解析扩展 —— 命中即结束
        if AnalyticExpansion(cur_node):    # ReedShepp::ShortestRSP + 碰撞检测
            break

        close_set[cur_node.index] = cur_node

        # 4b. 转向采样扩展（前 5 前进 + 后 5 后退）
        for i in range(next_node_num):
            next_node = Next_node_generator(cur_node, i)   # 自行车模型积分
            if next_node is None:                          continue  # 越界
            if next_node.index in close_set:               continue
            if not ValidityCheck(next_node):               continue  # 碰撞
            if next_node.index not in open_set:
                CalculateNodeCost(cur_node, next_node)     # g + h(DpMap) + h(RS)
                open_set[next_node.index] = next_node
                open_pq.push((next_node.index, next_node.cost))

    # 5. 回溯 + 重叠点合并
    GetResult(result)                  # reverse → pop_back → insert → reverse
    # 6. 速度规划（按换挡切分 + 五次多项式 S 曲线）
    GetTemporalProfile(result)
    return result
```

---

**研究调用统计**：本报告通过 WebSearch / WebFetch / Read 工具共发起约 **55 次** 内部调用（含若干失败 / 超时的 GitHub 直链），覆盖 Apollo 源码、原论文、星火计划课程、社区博客（chuxin911、CSDN 多位作者）等多个来源，交叉验证后整合成本文。
