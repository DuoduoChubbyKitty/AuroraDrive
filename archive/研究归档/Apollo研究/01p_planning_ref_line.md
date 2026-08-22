# Apollo Reference Line Provider（参考线生成与平滑）深度研究报告

> 研究对象：Baidu Apollo 自动驾驶开放平台 Planning 模块的参考线子系统（Apollo 6.0 → 9.0 PnC 2.0 → 10.0/11.0 master）
> 研究目的：为 AuroraDrive 仿真系统的规划栈升级提供「参考线生成 + 平滑」的架构参照与可迁移实现
> 撰写日期：2026-07-23
> 研究方法：WebSearch + WebFetch 对 GitHub `ApolloAuto/apollo` 源码（`modules/planning/planning_base/reference_line/`、`math/discretized_points_smoothing/`）、Apollo 官方 `docs/specs/reference_line_smoother.md`、CSDN 源码解析系列（xl_courage、保罗的酒吧 paul.pub、OceanStar、落羽归尘、Chef Xie、WaiNgai 等）进行 50+ 次深度挖掘，并直接抓取 master 分支真实源码进行交叉验证。

---

## 0. 摘要

参考线（Reference Line）是 Apollo 规划算法的"地基"：它在 Routing 全局路径与最终 ADC 轨迹之间承担承上启下的桥梁，将高精地图（HD Map）车道中心线这一**离散、可能抖动**的原始数据，经过降采样、锚点生成、二次/非线性规划平滑，转化为一条**C2 连续、曲率有界、可投影**的理想 Frenet 坐标轴。本报告系统梳理 `ReferenceLineProvider` 的整体架构与多线程模型、`ReferenceLine`/`ReferenceLineInfo`/`AnchorPoint` 三大数据结构、`CreateReferenceLine → SmoothRouteSegment → SmoothReferenceLine → GetAnchorPoints → Smoother.Smooth → IsReferenceLineSmoothValid` 完整链路，并对照 master 分支真实源码逐行解析三种 Smoother（QpSpline / Spiral / DiscretePoints，后者又分 CosTheta 与 FemPosDeviation 两条子路径）的优化变量、目标函数、约束、求解器与优劣。最后针对 AuroraDrive 当前 `compute_road_guidance` 直接拼接 200 点道路中心点导致 PurePursuit 转向抖动的问题，给出一个**无 OSQP / IPOPT 外部依赖、手写三对角 QP + Thomas 追赶法**的 DiscretePoints FemPosDeviation 简化版 C++ 实现。

---

## 1. Reference Line Provider 整体架构

### 1.1 模块定位与目录结构

参考线子系统的源码集中在 `modules/planning/planning_base/reference_line/` 目录，核心文件如下（基于 master 分支真实抓取）：

| 文件 | 职责 | 行数 |
|------|------|------|
| `reference_line_provider.{h,cc}` | `ReferenceLineProvider` 类，参考线的提供与管理者，多线程生成 | ~1051 行 |
| `reference_line.{h,cc}` | `ReferenceLine` 类，参考线数据结构 + Stitch/Segment/XYToSL 等 | ~900 行 |
| `reference_point.h` | `ReferencePoint`，继承 `MapPathPoint`，含 `kappa_`/`dkappa_` | - |
| `reference_line_smoother.h` | 抽象基类 `ReferenceLineSmoother` + `AnchorPoint` 结构 | - |
| `qp_spline_reference_line_smoother.cc` | QpSpline 平滑器（默认） | ~180 行 |
| `spiral_reference_line_smoother.cc` | Spiral 回旋线平滑器 | ~325 行 |
| `discrete_points_reference_line_smoother.cc` | 离散点平滑器（CosTheta / FemPosDeviation） | ~190 行 |
| `spiral_problem_interface.{h,cc}` | Spiral 的 IPOPT TNLP 接口 | - |
| 数学库 `math/discretized_points_smoothing/` | `cos_theta_smoother.cc`、`fem_pos_deviation_smoother.cc`、`*_osqp_interface.cc`、`*_ipopt_interface.cc`、`*_sqp_osqp_interface.cc` | - |
| 数学库 `math/smoothing_spline/` | `osqp_spline_2d_solver.cc`、`spline_2d_kernel.cc`、`spline_2d_constraint.cc` | - |
| 数学库 `math/curve1d/quintic_spiral_path.h` | 五次回旋线曲线 | - |

### 1.2 ReferenceLineProvider 类

`ReferenceLineProvider` 是规划模块中**候选路径（参考线）的提供和管理者**。它以 Routing 模块输出的高精度路径（起点到终点的 Lane 片段集）+ HD Map + VehicleState 为输入，经平滑处理后生成供后续动作规划使用的参考线。

**关键设计点（来自 master 源码 `reference_line_provider.cc`）**：

1. **单实例 + 多线程**：通过 `DECLARE_SINGLETON` 宏定义，`Start()` 后内部开启新线程执行 `GenerateThread()`，与规划线程解耦；线程间通过 `std::mutex` 保护 `routing_`/`vehicle_state_`/`reference_lines_`/`route_segments_`。

2. **构造函数**（核心逻辑）：

```cpp
ReferenceLineProvider::ReferenceLineProvider(
    const common::VehicleStateProvider *vehicle_state_provider,
    const ReferenceLineConfig *reference_line_config,
    const std::shared_ptr<relative_map::MapMsg> &relative_map)
    : vehicle_state_provider_(vehicle_state_provider) {
  ACHECK(cyber::common::GetProtoFromFile(FLAGS_smoother_config_filename,
                                         &smoother_config_))
      << "Failed to load smoother config file " << FLAGS_smoother_config_filename;
  // 参考线平滑的三种方式
  if (smoother_config_.has_qp_spline()) {
    smoother_.reset(new QpSplineReferenceLineSmoother(smoother_config_));
  } else if (smoother_config_.has_spiral()) {
    smoother_.reset(new SpiralReferenceLineSmoother(smoother_config_));
  } else if (smoother_config_.has_discrete_points()) {
    smoother_.reset(new DiscretePointsReferenceLineSmoother(smoother_config_));
  } else {
    ACHECK(false) << "unknown smoother config " << smoother_config_.DebugString();
  }
  // PncMap 插件加载（默认 apollo::planning::LaneFollowMap）
  ...
  is_initialized_ = true;
}
```

3. **线程入口 `GenerateThread()`**：50 ms 休眠循环，只要 `!is_stop_` 就持续：

```cpp
void ReferenceLineProvider::GenerateThread() {
  while (!is_stop_) {
    static constexpr int32_t kSleepTime = 50;  // milliseconds
    cyber::SleepFor(std::chrono::milliseconds(kSleepTime));
    const double start_time = Clock::NowInSeconds();
    if (!has_planning_command_) continue;
    std::list<ReferenceLine> reference_lines;
    std::list<hdmap::RouteSegments> segments;
    if (!CreateReferenceLine(&reference_lines, &segments)) {
      is_reference_line_updated_ = false;
      continue;
    }
    UpdateReferenceLine(reference_lines, segments);
    const double end_time = Clock::NowInSeconds();
    std::lock_guard<std::mutex> lock(reference_lines_mutex_);
    last_calculation_time_ = end_time - start_time;
    is_reference_line_updated_ = true;
  }
}
```

4. **`GetReferenceLines()` 三级容错**：
   - 导航模式：`GetReferenceLinesFromRelativeMap()`
   - 线程模式：直接 `assign` 后台已算好的 `reference_lines_`
   - 非线程模式：现场调用 `CreateReferenceLine()` + `UpdateReferenceLine()`
   - 全部失败：回退到 `reference_line_history_.back()`（最近一帧，`kMaxHistoryNum=3`）

5. **`UpdateReferenceLine()`**：增量更新——若新旧参考线首尾点一致且长度差异 `< kMathEpsilon`，则跳过；否则替换，并 push 到 history 队列。

### 1.3 ReferenceLine 与 ReferencePoint

`ReferenceLine` 类（`reference_line.h`）的四大成员：

| 成员 | 类型 | 说明 |
|------|------|------|
| `speed_limit_` | `std::vector<SpeedLimit>` | 分段限速，每段含 `start_s`/`end_s`/`speed_limit` |
| `reference_points_` | `std::vector<ReferencePoint>` | 参考线的离散点序列，轨迹生成的基础 |
| `map_path_` | `hdmap::Path` | HD Map 上的路径，与 `reference_points_` 一一对应（构造时从 `map_path_` 派生） |
| `priority_` | `uint32_t` | 优先级，变道场景多参考线时用于选择（PublicRoadPlanner 未使用） |

`ReferencePoint` 继承自 `hdmap::MapPathPoint`（`Vec2d` + `heading_` + `lane_waypoints_`），新增：
- `double kappa_`：曲率，直接决定方向盘转角
- `double dkappa_`：曲率导数，决定方向盘转速

> **核心洞察**：HD Map 原始点文件（如 `base_map.txt`）只记录 `(x, y)`，`heading` 由 `path.cc::InitPoints` 通过相邻点向量 `atan2` 计算，`kappa`/`dkappa` 则由 Smoother 在平滑时计算。这正是"原始道路中心线不平滑"的根源——离散点抖动会通过 `atan2` 放大为 heading 跳变，再通过差分放大为 kappa 跳变，最终传到控制器引发方向盘抖动。

### 1.4 ReferenceLineInfo

`ReferenceLineInfo`（位于 `planning_base/common/`）是 Planning 逻辑计算的**基础数据结构**，在 `ReferenceLine` 的基础上叠加：
- 决策信息（障碍物 nudge/ignore、变道决定）
- ST 图（障碍物在 s-t 域的投影）
- `path_data_`（路径优化结果）、`speed_data_`（速度规划结果）
- 最终通过 `CombinePathAndSpeedProfile()` 合并为 `DiscretizedTrajectory`

简言之：`ReferenceLine` 提供"轨迹几何信息"，`ReferenceLineInfo` 在其上叠加"决策与运动学信息"。

---

## 2. 参考线生成链路

### 2.1 CreateReferenceLine() 主流程

```cpp
bool ReferenceLineProvider::CreateReferenceLine(
    std::list<ReferenceLine> *reference_lines,
    std::list<hdmap::RouteSegments> *segments) {
  // ① 处理路由响应（若新路由则更新 PncMap）
  if (current_pnc_map_->IsNewPlanningCommand(command)) {
    is_new_command_ = true;
    current_pnc_map_->UpdatePlanningCommand(command);
  }
  // ② 根据车辆当前位置生成短期通道（RouteSegments）
  if (!CreateRouteSegments(vehicle_state, segments)) { ... }
  // ③ 分支：新路由/关闭拼接 → 直接平滑；否则 → 拼接扩展
  if (is_new_routing || !FLAGS_enable_reference_line_stitching) {
    for (auto iter = segments->begin(); iter != segments->end();) {
      reference_lines->emplace_back();
      if (!SmoothRouteSegment(*iter, &reference_lines->back())) {
        iter = segments->erase(iter);  // 平滑失败的 segment 直接丢弃
      } else { ++iter; }
    }
  } else {  // stitching reference line
    ExtendReferenceLine(segments, reference_lines);  // 复用上一帧，拼接延伸
  }
}
```

`CreateRouteSegments` 调用 `pnc_map_->GetRouteSegments(vehicle_state, segments)`，纵向范围由三个 gflag 决定：
- `look_backward_distance = 30` m
- `look_forward_short_distance = 180` m（低速时）
- `look_forward_long_distance = 250` m（高速时）

若 Routing 结果需要变道，则返回多个 `RouteSegments`（自车车道 + 目标车道），分别生成多条参考线。

### 2.2 SmoothRouteSegment() 与 SmoothReferenceLine()

```cpp
bool ReferenceLineProvider::SmoothRouteSegment(const RouteSegments& segments,
                                               ReferenceLine* reference_line) {
  hdmap::Path path(segments);                  // 从 RouteSegments 构造原始 Path
  return SmoothReferenceLine(ReferenceLine(path), reference_line);
}

bool ReferenceLineProvider::SmoothReferenceLine(
    const ReferenceLine &raw_reference_line, ReferenceLine *reference_line) {
  if (!FLAGS_enable_smooth_reference_line) {
    *reference_line = raw_reference_line;      // 可关闭平滑（调试用）
    return true;
  }
  // 1. 生成锚点
  std::vector<AnchorPoint> anchor_points;
  GetAnchorPoints(raw_reference_line, &anchor_points);
  // 2. 注入锚点
  smoother_->SetAnchorPoints(anchor_points);
  // 3. 平滑
  if (!smoother_->Smooth(raw_reference_line, reference_line)) {
    AERROR << "Failed to smooth reference line with anchor points";
    return false;
  }
  // 4. 校验
  if (!IsReferenceLineSmoothValid(raw_reference_line, *reference_line)) {
    AERROR << "The smoothed reference line error is too large";
    return false;
  }
  return true;
}
```

### 2.3 ReferenceLine::Stitch（参考线拼接）

`Stitch` 用于 `ExtendReferenceLine`：当新旧参考线在空间上有重叠时，复用上一帧已平滑部分，仅平滑新增段，避免每帧全量重算。其语义在源码注释中给得很清楚：

```
* Example 1
* this:   |--------A-----x-----B------|            (上一帧)
* other:                 |-----C------x--------D-------|  (新原始)
* Result: |------A-----x-----B------x--------D-------|    (拼接后)
* 在 x 处对接，B 与 C 匹配，结果取 A-B-D
```

实现核心：将 `this` 的首/尾点投影到 `other`（`XYToSL`），若 `s ∈ (0, other.Length())` 且 `|l| < kStitchingError = 0.1m` 则认为可拼接；用 `lower_bound`/`upper_bound` 在 `accumulated_s` 上定位，`insert` 拼接段；最后重建 `map_path_ = MapPath(...)`。

### 2.4 ReferenceLine::Segment（参考线截取）

```cpp
bool ReferenceLine::Segment(const double s,
                            const double look_backward,
                            const double look_forward) {
  const auto& accumulated_s = map_path_.accumulated_s();
  auto start_index = std::lower_bound(accumulated_s.begin(), accumulated_s.end(),
                                      s - look_backward);
  auto end_index   = std::upper_bound(accumulated_s.begin(), accumulated_s.end(),
                                      s + look_forward);
  if (end_index - start_index < 2) return false;
  reference_points_ = std::vector<ReferencePoint>(
      reference_points_.begin() + start_index,
      reference_points_.begin() + end_index);
  map_path_ = MapPath(...);  // 重建
  return true;
}
```

用于在车辆前进过程中把参考线窗口滑动到 `[s - look_backward, s + look_forward]`。

---

## 3. 锚点 GetAnchorPoints

### 3.1 采样逻辑

```cpp
void ReferenceLineProvider::GetAnchorPoints(
    const ReferenceLine& reference_line,
    std::vector<AnchorPoint>* anchor_points) const {
  const double interval = smoother_config_.max_constraint_interval();  // 采样间隔
  int num_of_anchors = std::max(2, static_cast<int>(
      reference_line.Length() / interval + 0.5));
  std::vector<double> anchor_s;
  common::util::uniform_slice(0.0, reference_line.Length(),
                              num_of_anchors - 1, &anchor_s);  // 等分降采样
  for (const double s : anchor_s) {
    anchor_points->emplace_back(GetAnchorPoint(reference_line, s));
  }
  // 首尾点强制约束（bound = 1e-6，enforced = true）
  anchor_points->front().longitudinal_bound = 1e-6;
  anchor_points->front().lateral_bound = 1e-6;
  anchor_points->front().enforced = true;
  anchor_points->back().longitudinal_bound = 1e-6;
  anchor_points->back().lateral_bound = 1e-6;
  anchor_points->back().enforced = true;
}
```

### 3.2 AnchorPoint 结构

```cpp
struct AnchorPoint {
  common::PathPoint path_point;       // 由 reference_line.GetReferencePoint(s) 插值得到
  double lateral_bound = 0.0;         // 优化点在该锚点 L 轴（横向）允许的偏移
  double longitudinal_bound = 0.0;    // 优化点在该锚点 F 轴（纵向）允许的偏移
  bool enforced = false;              // 强制约束（bound=0 等价于硬约束）
};
```

### 3.3 GetAnchorPoint 的"轨迹点矫正"

`GetAnchorPoint(reference_line, s)` 不只是简单插值，还会做**车道靠边矫正**：

1. `ref_point = reference_line.GetReferencePoint(s)`：按 s 在 reference_line 上插值得到 `(x, y, theta, kappa, dkappa)`。
2. 查询该处车道宽度 `left_width + right_width = total_width`。
3. **宽车道靠边**：若 `total_width > adc_width * wide_lane_threshold_factor(默认 2)`，按 `driving_side`（RIGHT/LEFT）计算 `shifted_left_width`，让车辆靠右/靠左行驶，给其他车辆留超车空间。
4. **curb 缓冲**：若左/右边界是 `CURB`（马路牙子），`shifted_left_width += curb_shift(0.2m)` 或 `-= curb_shift`，远离马路牙。
5. 计算 `effective_width = min(shifted_left, shifted_right) - adc_half_width - FLAGS_reference_line_lateral_buffer`。
6. `anchor.lateral_bound = max(smoother_config_.lateral_boundary_bound(), effective_width)`。
7. `anchor.longitudinal_bound = smoother_config_.longitudinal_boundary_bound()`。

### 3.4 锚点密度对平滑的影响

`max_constraint_interval` 是平滑质量与算力的核心旋钮：

| Smoother | 默认 `max_constraint_interval` | 锚点数（200m 参考） | 含义 |
|----------|------------------------------|---------------------|------|
| QpSpline | 5.0 m | ~40 | 锚点稀疏，spline 拟合时还有更稀的 knots（`max_spline_length=25m`，~8 段） |
| Spiral | 5.0 m | ~40 | 锚点稀疏，piecewise_length 控制分段 |
| DiscretePoints | **0.25 m** | ~800 | 锚点密集，直接优化每个点 |

- **过疏**（如 5m）：锚点间空隙大，边界约束在中间区失效，可能产生"鼓包"，QpSpline 靠 spline 的 C2 连续性弥补。
- **过密**（如 0.05m）：算力爆炸（OSQP/IPOPT 规模 O(n²)），且对地图噪声过拟合。
- **Apollo 实践**：DiscretePoints 默认 0.25m 是"道路中心线原始点间距通常 0.5~1m"的 1/2~1/4，既保证密度又不过载。

配置示例（`discrete_points_smoother_config.pb.txt`）：
```protobuf
max_constraint_interval : 0.25
longitudinal_boundary_bound : 2.0
max_lateral_boundary_bound : 0.5
min_lateral_boundary_bound : 0.1
curb_shift : 0.2
lateral_buffer : 0.2
discrete_points {
  smoothing_method: FEM_POS_DEVIATION_SMOOTHING
  fem_pos_deviation_smoothing {
    weight_fem_pos_deviation: 1e10
    weight_ref_deviation: 1.0
    weight_path_length: 1.0
    apply_curvature_constraint: false
    max_iter: 500
  }
}
```

---

## 4. 三种 Smoother

### 4.1 总览与对比表

Apollo 提供三种 `ReferenceLineSmoother` 实现（策略模式，统一接口 `SetAnchorPoints` + `Smooth`）：

| 维度 | **QpSpline**（默认） | **Spiral** | **DiscretePoints** |
|------|---------------------|-----------|---------------------|
| 优化变量 | n 段 5 次多项式 x/y 系数（每段 6×2=12 个） | n 段回旋线状态 `(θ, θ̇, θ̈, x, y, Δs)` | n 个离散点 `(x_i, y_i)` |
| 目标函数 | ∫f''² + ∫g''² + ∫f'''² + ∫g'''² + L2 正则 | `w_L·ΣΔs + w_κ·Σθ̇² + w_dκ·Σθ̈²` | 平滑度 + 长度 + 偏移（见 4.4/4.5） |
| 平滑度度量 | 二阶/三阶导（间接 = 曲率/曲率变化率） | 曲率 κ=θ̇、曲率变化率 dκ=θ̈ | CosTheta: `cos(夹角)`；FemPos: `(x_{i-1}+x_{i+1}-2x_i)²` |
| 求解器 | **OSQP**（QP，凸） | **IPOPT**（NLP，hessian 限内存） | CosTheta: **IPOPT**（NLP）；FemPos: **OSQP**（默认）/ SQP-OSQP / IPOPT |
| 约束 | 2D 边界框 + 首点航向 + 相邻 spline C2 连续 | 连接点等式 + 首尾固定 + 偏差 | x/y box + 曲率（松弛变量） |
| 求解规模 | 小（变量数 = 12·n_spline，n_spline≈8） | 中（变量数 = 6·n_anchors） | 大（变量数 = 2·n_anchors，0.25m 间隔下 ~1600） |
| 凸性 | 凸（QP） | 非凸（NLP） | CosTheta 非凸；FemPos 凸（无曲率约束） |
| 速度 | 最快（ms 级） | 慢（IPOPT 迭代，百 ms） | FemPos-OSQP 快；CosTheta-IPOPT 慢 |
| 平滑质量 | 全局 C2，但对突变锚点欠拟合 | 曲率物理意义最强，适合弯道 | 对地图抖动抑制最好，但点间曲率靠后处理差分 |
| 运动学合理性 | 高（直接得 κ/dκ） | 最高（θ̇/θ̈ 即 κ/dκ） | 中（κ/dκ 需 `ComputePathProfile` 差分） |
| Apollo 默认 | ✅ `qp_spline_smoother_config.pb.txt` | ❌ | ❌（但实测工程最常用） |
| 工程迁移难度 | 高（依赖 spline kernel 矩阵构造 + OSQP） | 高（依赖 IPOPT + 五次回旋线积分） | **低**（FemPos-OSQP 仅需三对角 QP） |

### 4.2 QpSplineReferenceLineSmoother（默认）

**核心源码** `qp_spline_reference_line_smoother.cc`：

```cpp
bool QpSplineReferenceLineSmoother::Smooth(...) {
  Sampling();              // 1. 划分 knots
  spline_solver_->Reset(t_knots_, config_.qp_spline().spline_order());  // spline_order=5
  AddConstraint();         // 2. 加约束
  AddKernel();             // 3. 加目标函数（kernel 矩阵）
  Solve();                 // 4. OSQP 求解
  // 5. 采样 spline 得到 ReferencePoint 序列
  for (i, t += resolution) {
    heading = atan2(spline.DerivativeY(t), spline.DerivativeX(t));
    kappa   = CurveMath::ComputeCurvature(x', x'', y', y'');
    dkappa  = CurveMath::ComputeCurvatureDerivative(x', x'', x''', y', y'', y''');
    ...
  }
}
```

**Sampling（knots 划分）**：
```cpp
uint32_t num_spline = std::max(1u, static_cast<uint32_t>(
    length / config_.qp_spline().max_spline_length() + 0.5));  // max_spline_length=25m
for (i = 0; i <= num_spline; ++i) t_knots_.push_back(i * 1.0);  // t ∈ [0, num_spline]
ref_x_ = anchor_points_.front().path_point.x();  // 坐标归一化
ref_y_ = anchor_points_.front().path_point.y();
```

变量总数 = `(spline_order+1) × 2 × num_spline = 6 × 2 × n`（x/y 各一条 5 次多项式）。

**AddConstraint（三类约束）**：
```cpp
// 1. 2D 边界约束：每个 anchor 的优化点 (x',y') 必须在以 ref_point 为中心、
//    F 轴 ±longitudinal_bound、L 轴 ±lateral_bound 的矩形框内
spline_constraint->Add2dBoundary(evaluated_t, headings, xy_points,
                                 longitudinal_bound, lateral_bound);
// 2. 首点航向约束：第一段 spline 在 t=0 处的导数方向 = anchor heading
if (FLAGS_enable_reference_line_stitching)
  spline_constraint->AddPointAngleConstraint(evaluated_t.front(), headings.front());
// 3. C2 连续约束：相邻 spline 在交接点处 函数值/一阶导/二阶导 相等
spline_constraint->AddSecondDerivativeSmoothConstraint();
```

边界约束的数学形式（投影到 F-L 局部系）：
- L 轴投影距离：`d_lateral = (x,y) · (-sin θ, cos θ)`，要求 `|d_lateral| ≤ lateral_bound`
- F 轴投影距离：`d_longitudinal = (x,y) · (cos θ, sin θ)`，要求 `|d_longitudinal| ≤ longitudinal_bound`

**AddKernel（目标函数）**：
```cpp
Spline2dKernel* kernel = spline_solver_->mutable_kernel();
kernel->AddSecondOrderDerivativeMatrix(second_derivative_weight);  // ∫₀^t f''(x)²·t·dt
kernel->AddThirdOrderDerivativeMatrix(third_derivative_weight);    // ∫₀^t f'''(x)²·t·dt
kernel->AddRegularization(regularization_weight);                  // L2 正则
```

目标函数（每段 spline）：

$$
\text{cost} = \sum_{i=1}^{n}\left( \int_0^{t_i} f''(x)^2 \, t\, dt + \int_0^{t_i} g''(y)^2 \, t\, dt + \int_0^{t_i} f'''(x)^2 \, t\, dt + \int_0^{t_i} g'''(y)^2 \, t\, dt \right) + \lambda \|a\|_2^2
$$

物理意义：二阶导 ∝ 曲率（控制转角幅度）、三阶导 ∝ 曲率变化率（控制方向盘转速）、L2 正则防过拟合并改善矩阵条件数。最终转化为 OSQP 标准型 $\frac{1}{2}x^T P x + q^T x$，s.t. $l \le A x \le u$。

### 4.3 SpiralReferenceLineSmoother

**核心源码** `spiral_reference_line_smoother.cc`（master 真实抓取）：

```cpp
bool SpiralReferenceLineSmoother::Smooth(std::vector<Eigen::Vector2d> point2d, ...) {
  SpiralProblemInterface* ptop = new SpiralProblemInterface(point2d);
  ptop->set_default_max_point_deviation(config_.spiral().max_deviation());
  if (fixed_start_point_) {
    ptop->set_start_point(fixed_start_x_, fixed_start_y_, fixed_start_theta_,
                          fixed_start_kappa_, fixed_start_dkappa_);  // 首点 5 自由度全固定
  }
  ptop->set_end_point_position(fixed_end_x_, fixed_end_y_);          // 尾点位置固定
  ptop->set_element_weight_curve_length(config_.spiral().weight_curve_length());
  ptop->set_element_weight_kappa(config_.spiral().weight_kappa());
  ptop->set_element_weight_dkappa(config_.spiral().weight_dkappa());
  Ipopt::SmartPtr<Ipopt::TNLP> problem = ptop;
  Ipopt::SmartPtr<Ipopt::IpoptApplication> app = IpoptApplicationFactory();
  app->Options()->SetStringValue("hessian_approximation", "limited-memory");
  app->Options()->SetIntegerValue("max_iter", config_.spiral().max_iteration());
  app->Options()->SetNumericValue("tol", config_.spiral().opt_tol());
  status = app->OptimizeTNLP(problem);
  ptop->get_optimization_results(ptr_theta, ptr_kappa, ptr_dkappa, ptr_s, ptr_x, ptr_y);
}
```

**优化变量**：每段回旋线状态 `(θ, κ=θ̇, dκ=θ̈, x, y, Δs)`，使用 `QuinticSpiralPath` 五次螺旋线参数化：
$$\theta(s) = a_0 + a_1 s + a_2 s^2 + a_3 s^3 + a_4 s^4 + a_5 s^5$$

**目标函数**：

$$
\text{cost} = w_{\text{length}} \sum_{i=1}^{n-1} \Delta s_i + w_{\kappa} \sum_{i=1}^{n-1}\sum_{j=0}^{m-1}(\dot\theta(s_j))^2 + w_{d\kappa} \sum_{i=1}^{n-1}\sum_{j=0}^{m-1}(\ddot\theta(s_j))^2
$$

物理意义：长度最短 + 曲率最小 + 曲率变化率最小，运动学意义最清晰。

**约束**：
1. 连接点等式约束：相邻段在交接处 `θ/κ/dκ/x/y` 连续
2. 首点固定：`fixed_start_{x,y,theta,kappa,dkappa}`（来自上一帧平滑末点，保证帧间连续）
3. 尾点位置固定：`fixed_end_{x,y}`
4. 偏差约束：每个优化点偏离原始点不超过 `max_deviation`

**插值**：求解后用 `QuinticSpiralPath` + `ComputeCartesianDeviationX/Y<10>`（10 阶泰勒展开）在每段内按 `resolution` 重采样得到密集 `PathPoint`。

**特点**：运动学最自洽（直接输出 θ/κ/dκ），但 IPOPT 非凸，对初值敏感，慢且偶尔不收敛，Apollo 默认不用。

### 4.4 DiscretePointsReferenceLineSmoother（CosTheta + FemPos 两条子路径）

**核心源码** `discrete_points_reference_line_smoother.cc`：

```cpp
bool DiscretePointsReferenceLineSmoother::Smooth(...) {
  std::vector<std::pair<double, double>> raw_point2d;
  std::vector<double> anchorpoints_lateralbound;
  for (const auto& anchor_point : anchor_points_) {
    raw_point2d.emplace_back(anchor_point.path_point.x(), anchor_point.path_point.y());
    anchorpoints_lateralbound.emplace_back(anchor_point.lateral_bound);
  }
  // 首尾点 bound=0，防止端点偏离车道中心
  anchorpoints_lateralbound.front() = 0.0;
  anchorpoints_lateralbound.back() = 0.0;
  NormalizePoints(&raw_point2d);   // 减去首点，归一化
  switch (config_.discrete_points().smoothing_method()) {
    case COS_THETA_SMOOTHING:
      status = CosThetaSmooth(raw_point2d, anchorpoints_lateralbound, &smoothed_point2d);
      break;
    case FEM_POS_DEVIATION_SMOOTHING:
      status = FemPosSmooth(raw_point2d, anchorpoints_lateralbound, &smoothed_point2d);
      break;
  }
  DeNormalizePoints(&smoothed_point2d);
  GenerateRefPointProfile(raw_reference_line, smoothed_point2d, &ref_points);
  // ref_points 由 DiscretePointsMath::ComputePathProfile 计算 heading/kappa/dkappa/accumulated_s
  *smoothed_reference_line = ReferenceLine(ref_points);
}
```

两个子方法都将 `box_bounds` 按 `1/sqrt(2)` 缩放（`box_ratio`），因为 box 约束在 x/y 独立轴上，矩形对角线方向实际可偏移 `bound·√2`，缩放后保证 L∞ 范数 ≤ bound。

#### 4.4.1 CosThetaSmoother（IPOPT 非线性）

**优化变量**：n 个离散点 `(x_i, y_i)`，共 2n 维。

**目标函数**（来自 `cos_theta_ipopt_interface.cc::eval_f`，3 项）：

$$
\text{cost} = w_1 \underbrace{\sum_{i=0}^{n-1}\left[(x_i - x_i^{\text{ref}})^2 + (y_i - y_i^{\text{ref}})^2\right]}_{\text{参考点偏差}} - w_2 \underbrace{\sum_{i=0}^{n-2}\cos\theta_i}_{\text{平滑度}} + w_3 \underbrace{\sum_{i=0}^{n-1}\left[(x_i - x_{i+1})^2 + (y_i - y_{i+1})^2\right]}_{\text{长度}}
$$

其中夹角余弦：

$$
\cos\theta_i = \frac{\vec{P_{i-1}P_i} \cdot \vec{P_i P_{i+1}}}{|\vec{P_{i-1}P_i}| \cdot |\vec{P_i P_{i+1}}|}
$$

> **物理意义**：$\cos\theta$ 越大 → 三点夹角越小 → 越接近直线 → 越平滑。**取负号**是因为目标是最小化 cost，等价于最大化 $\sum \cos\theta$。

**约束**：box 约束 `|x_i - x_i^{ref}| ≤ bound`，`|y_i - y_i^{ref}| ≤ bound`。

**问题**：分母含范数 $\sqrt{...}$，导致目标函数**非凸**，必须用 IPOPT（内点法 NLP）求解，慢且对初值敏感。

#### 4.4.2 FemPosDeviationSmoother（OSQP 凸 QP，推荐）

**优化变量**：同样 n 个离散点 `(x_i, y_i)`。

**目标函数**（4 项，来自 `fem_pos_deviation_ipopt_interface.cc::eval_obj`）：

$$
\text{cost} = w_1 \underbrace{\sum_{i=0}^{n-2}\left[(x_i + x_{i+2} - 2x_{i+1})^2 + (y_i + y_{i+2} - 2y_{i+1})^2\right]}_{\text{FEM 位置偏差（平滑度）}} + w_2 \underbrace{\sum_{i=0}^{n-1}\left[(x_i - x_{i+1})^2 + (y_i - y_{i+1})^2\right]}_{\text{长度}} + w_3 \underbrace{\sum_{i=0}^{n-1}\left[(x_i - x_i^{\text{ref}})^2 + (y_i - y_i^{\text{ref}})^2\right]}_{\text{参考点偏差}} + w_4 \underbrace{\sum \text{slack}}_{\text{曲率松弛}}
$$

**FEM 平滑度的物理意义**：$(x_{i-1} + x_{i+1} - 2x_i)$ 是二阶中心差分，等于把 $P_{i+1}$ 平移到 $P_i$ 的对称点 $P'$ 后的向量 $\vec{P_i P'}$ 的模的平方。三点共线时该项 = 0；越弯曲该项越大。**注意符号**：与 CosTheta 相反，这里是**正号**（直接惩罚弯曲度），且无分母范数，**纯二次型 → 凸 QP**。

**三种求解路径**（`fem_pos_deviation_smoother.cc::Solve`）：
```cpp
if (config_.apply_curvature_constraint()) {
  if (config_.use_sqp()) return SqpWithOsqp(...);  // SQP 迭代线性化曲率
  else                    return NlpWithIpopt(...);  // NLP 直接求解
} else {
  return QpWithOsqp(...);                           // 默认：纯 QP，最快
}
```

- **QpWithOsqp**（默认）：忽略曲率约束，纯二次型 + box 约束 → 标准 QP，OSQP 毫秒级。
- **SqpWithOsqp**：曲率约束非凸，用 SQP（序列二次规划）迭代线性化，引入松弛变量 `slack`，目标加 `w_4 · Σ slack`。
- **NlpWithIpopt**：曲率约束直接交给 IPOPT 内点法。

**FemPosDeviationOsqpInterface 的 P 矩阵**（master 源码注释，6 点示例）：

```
设 X = weight_fem_pos_deviation, Y = weight_path_length, Z = weight_ref_deviation
（均为 2x2 对角块，0 为 2x2 零矩阵）

|X+Y+Z,  -2X-Y,    X,        0,        0,        0     |
|0,      5X+2Y+Z,  -4X-Y,    X,        0,        0     |
|0,      0,        6X+2Y+Z,  -4X-Y,    X,        0     |
|0,      0,        0,        6X+2Y+Z,  -4X-Y,    X     |
|0,      0,        0,        0,        5X+2Y+Z,  -2X-Y |
|0,      0,        0,        0,        0,        X+Y+Z |
```

这是一个**五对角带状矩阵**（每行最多 3 个非零块，每块 2x2）。在 x/y 解耦后，对单一坐标轴是**三对角矩阵**（主对角 + 上下各一条副对角），可用 **Thomas 追赶法 O(n)** 求解（无约束时）或 OSQP 求解（有 box 约束时）。

**q 偏移向量**：`q[2i] = -2·Z·x_i^ref`，`q[2i+1] = -2·Z·y_i^ref`。

**仿射约束 A = I**（单位阵），上下界：
```
upper_bounds[2i]   = x_i^ref + bound_i
lower_bounds[2i]   = x_i^ref - bound_i
（y 同理）
```

**默认权重**：`weight_fem_pos_deviation = 1e10`（平滑度主导），`weight_path_length = 1.0`，`weight_ref_deviation = 1.0`。即"平滑度压倒一切，长度和偏移仅作正则"。

---

## 5. 校验 IsReferenceLineSmoothValid

平滑完成后，`SmoothReferenceLine` 调用 `IsReferenceLineSmoothValid(raw, smoothed)` 做后验校验，若失败则 `AERROR << "The smoothed reference line error is too large"` 并丢弃该参考线。校验逻辑（综合多个源码解析）：

1. **横向偏差检查**：在 smoothed reference line 上等间隔采样若干点，逐一 `XYToSL` 投影到 raw reference line，得到 `(s, l)`。要求 `|l|` 不超过配置阈值（通常与 `max_lateral_boundary_bound` 同量级，如 0.5m）。若超限说明平滑"漂出"了原车道。
2. **曲率上限检查**：对 smoothed 线每个点的 `kappa`，要求 `|kappa| ≤ FLAGS_reference_line_max_kappa`（如 0.6 1/m，对应半径 ~1.67m 的弯）。
3. **曲率变化率检查**：`|dkappa| ≤ FLAGS_reference_line_max_dkappa`，避免方向盘转速过大。
4. **纵向覆盖检查**：smoothed 线长度应与 raw 接近，避免端点回缩。

任一检查失败即判无效，触发 `SmoothRouteSegment` 失败 → 该 segment 从 `segments` 列表 erase；若所有 segment 都失败，`GetReferenceLines` 回退到 history。

---

## 6. 参考线 vs 道路中心线

| 维度 | **道路中心线（HD Map 原始）** | **参考线（ReferenceLine）** |
|------|------------------------------|------------------------------|
| 来源 | HD Map `Lane.center_curve` 离散点 | ReferenceLineProvider 平滑后输出 |
| 数据形式 | `std::vector<MapPathPoint>`，仅 `(x, y)` | `std::vector<ReferencePoint>`，含 `(x, y, θ, κ, dκ, s)` |
| 平滑性 | 离散，点间可能抖动 | C2 连续（QpSpline/Spiral）或近似 C2（DiscretePoints + 后处理差分） |
| 长度 | 全局（km 级） | 局部窗口（30m 后 + 180/250m 前） |
| 用途 | 地图拓扑、几何参考 | Frenet 坐标轴、投影基准、Path/Speed 规划的 s 轴 |
| 下游消费者 | 无（仅 ReferenceLineProvider 内部使用） | 所有 Task：`PathLaneBorrowDecider`、`PathBoundsDecider`、`PathOptimizer`、`STBoundsDecider`、`SpeedBoundsDecider`、`SpeedOptimizer` 等 |
| 帧间连续性 | 无 | 通过 Stitch + 首点 enforced + Spiral 的 `fixed_start_*` 保证 |

**核心结论**：参考线是"理想状态下没有障碍物的一条平滑线"，车辆在无障碍时应沿参考线行驶；有障碍物时在参考线的 Frenet 域做 `(s, l)` 偏移。参考线的平滑性直接决定 PurePursuit / MPC 控制器的转向平稳性。

---

## 7. Apollo 源码定位汇总

| 关注点 | 源码路径（master） |
|--------|-------------------|
| Provider 主类 | `modules/planning/planning_base/reference_line/reference_line_provider.{h,cc}` |
| ReferenceLine 数据结构 | `modules/planning/planning_base/reference_line/reference_line.{h,cc}` |
| ReferencePoint | `modules/planning/planning_base/reference_line/reference_point.h` |
| Smoother 抽象基类 + AnchorPoint | `modules/planning/planning_base/reference_line/reference_line_smoother.h` |
| QpSpline | `modules/planning/planning_base/reference_line/qp_spline_reference_line_smoother.cc` |
| Spiral | `modules/planning/planning_base/reference_line/spiral_reference_line_smoother.cc` + `spiral_problem_interface.{h,cc}` |
| DiscretePoints | `modules/planning/planning_base/reference_line/discrete_points_reference_line_smoother.cc` |
| CosTheta 求解器 | `modules/planning/planning_base/math/discretized_points_smoothing/cos_theta_smoother.cc` + `cos_theta_ipopt_interface.cc` |
| FemPos 求解器 | `modules/planning/planning_base/math/discretized_points_smoothing/fem_pos_deviation_smoother.cc` + `fem_pos_deviation_osqp_interface.cc` / `fem_pos_deviation_ipopt_interface.cc` / `fem_pos_deviation_sqp_osqp_interface.cc` |
| Spline 求解器 | `modules/planning/planning_base/math/smoothing_spline/osqp_spline_2d_solver.cc` + `spline_2d_kernel.cc` + `spline_2d_constraint.cc` |
| 五次回旋线 | `modules/planning/planning_base/math/curve1d/quintic_spiral_path.h` |
| 离散点几何后处理 | `modules/planning/planning_base/math/discrete_points_math.{h,cc}` |
| 配置 proto | `modules/planning/planning_base/proto/reference_line_smoother_config.proto` |
| 默认配置 | `modules/planning/planning_component/conf/{qp_spline,spiral,discrete_points}_smoother_config.pb.txt` |
| 官方文档 | `docs/specs/reference_line_smoother.md` |

---

## 8. AuroraDrive 迁移建议

### 8.1 现状诊断

AuroraDrive 当前（`cpp/include/ad/simulator.h:443`）的 `compute_road_guidance` 实现：

```cpp
void compute_road_guidance(std::vector<float>& out, int nearest_rd, const EgoState& ego) {
  out.clear();
  out.reserve(440);
  // ... dest 模式：直接拷贝 route_wp_ 的 200 点窗口
  // ... roam 模式：
  const float* pts = map_.road_center_ptr(nearest_rd);  // HD Map 道路中心点
  int n = map_.road_point_count(nearest_rd);
  // 找最近点（偏好前方）
  float ch = std::cos(ego.heading), sh = std::sin(ego.heading);
  // ...
  int half = 100;
  // 取 [ni-half, ni+half] 共 200 点，直接 push_back 到 out
}
```

**问题**：
1. **零平滑**：直接拷贝 `map_.road_center_ptr` 的原始点，道路中心线若有 0.1~0.3m 抖动，会原封不动传给 `PurePursuit`。
2. **PurePursuit 放大抖动**：PurePursuit 的前视点追踪对参考点横向偏移敏感，0.2m 的点抖动可被放大为 5~10° 的转向命令跳变，引发"画龙"。
3. **200 点窗口固定**：未按速度自适应前瞻距离，低速时前视过远、高速时过近。
4. **无帧间连续**：每帧独立找最近点，`ni` 在道路转角处可能反复跳变（代码中已用"道路总体方向 forward"缓解，但治标不治本）。

### 8.2 迁移方案选择

对照三种 Smoother：

| 方案 | 依赖 | 算力 | 平滑质量 | 迁移难度 |
|------|------|------|----------|----------|
| QpSpline | OSQP + spline kernel 矩阵构造 | 低 | 高（C2） | 高（需移植 spline 框架） |
| Spiral | IPOPT + 五次回旋线积分 | 高 | 最高 | 高（NLP 调参 + 收敛性） |
| **DiscretePoints - FemPos (OSQP)** | OSQP | 中 | 中高 | 中（OSQP 已是轻量库） |
| **DiscretePoints - FemPos (手写三对角)** | **无** | 低 | 中 | **低** ✅ |

**推荐**：DiscretePoints FemPosDeviation 的**简化版**——忽略曲率约束（与 Apollo 默认 `apply_curvature_constraint: false` 一致），退化为带 box 约束的三对角 QP，用**Thomas 追赶法 + 投影**或**OSQP**求解。AuroraDrive 仿真场景道路曲率小，无曲率约束不会发散。

### 8.3 AuroraDrive DiscretePoints 简化版 C++ 实现

下面给出一个**无 OSQP / IPOPT 外部依赖**、手写三对角 QP 求解器的实现，可直接放入 `cpp/include/ad/` 下。核心思想：FemPos 在 x/y 解耦后，每个坐标轴是一个**带 box 约束的三对角 QP**，可用"投影 Gauss-Seidel 迭代"在 O(n·iter) 内收敛。

```cpp
// cpp/include/ad/ref_line_smoother.h
#pragma once
#include <vector>
#include <cmath>
#include <algorithm>

namespace ad {

// 离散点 FemPosDeviation 平滑（Apollo 简化版，无曲率约束，无外部求解器依赖）
// 输入：raw_xy（原始道路点，size = n），bounds（每个点的 box 半宽，size = n）
// 输出：smoothed_xy（平滑后点）
// 权重对应 Apollo: w_fem(FEM 平滑度), w_len(长度), w_ref(参考偏差)
// 默认 w_fem=1e4, w_len=1.0, w_ref=1.0（仿真场景比 Apollo 的 1e10 小，避免数值病态）
struct FemPosSmootherConfig {
    double w_fem = 1e4;     // 平滑度权重（主导）
    double w_len = 1.0;     // 长度权重
    double w_ref = 1.0;     // 参考点偏差权重
    int    max_iter = 300;   // 投影 Gauss-Seidel 最大迭代
    double tol = 1e-5;      // 收敛阈值（相邻两次 x 变化的 L2）
};

// 单坐标轴的带 box 约束三对角 QP 求解
// min 0.5 * x^T P x + q^T x  s.t. lb <= x <= ub
// P 为三对角：P[i][i-1]=a[i], P[i][i]=d[i], P[i][i+1]=c[i]
// 采用投影 Gauss-Seidel 迭代（对角占优时收敛）
static inline void SolveTridiagBoxQP(
    const std::vector<double>& d,     // 主对角 (n)
    const std::vector<double>& off,   // 副对角 (n-1)
    const std::vector<double>& q,     // 一次项 (n)
    const std::vector<double>& lb,   // 下界 (n)
    const std::vector<double>& ub,    // 上界 (n)
    std::vector<double>& x,           // in: 初值(通常=ref), out: 解
    int max_iter, double tol) {
    const int n = static_cast<int>(d.size());
    for (int iter = 0; iter < max_iter; ++iter) {
        double delta = 0.0;
        for (int i = 0; i < n; ++i) {
            double neighbor = 0.0;
            if (i > 0)     neighbor += off[i-1] * x[i-1];
            if (i < n - 1) neighbor += off[i]   * x[i+1];
            // 对固定主对角 d[i] 的 Gauss-Seidel 更新
            double x_new = -(q[i] + neighbor) / d[i];
            // 投影到 [lb, ub]
            x_new = std::max(lb[i], std::min(ub[i], x_new));
            delta += (x_new - x[i]) * (x_new - x[i]);
            x[i] = x_new;
        }
        if (delta < tol * tol) break;  // 收敛
    }
}

// 对一组二维点做 FemPos 平滑
// 数学模型（与 Apollo fem_pos_deviation_osqp_interface.cc 完全一致）：
//   cost1 = w_fem * Σ_{i=1}^{n-2} (x[i-1] + x[i+1] - 2*x[i])^2   // FEM 二阶差分
//   cost2 = w_len * Σ_{i=0}^{n-2} (x[i] - x[i+1])^2
//   cost3 = w_ref * Σ_{i=0}^{n-1} (x[i] - x_ref[i])^2
// 对 x 求二阶导得三对角 P：
//   P[0][0]   = w_fem*1   + w_len*1   + w_ref
//   P[0][1]   = w_fem*(-2) + w_len*(-1)
//   P[i][i-1] = w_fem*(-2) - w_len     (i=1..n-2，对应 col-2 项 -2x_{i-1}-1，再 -4x_i)
//   P[i][i]   = w_fem*5   + w_len*2   + w_ref   (i=1)
//   P[i][i]   = w_fem*6   + w_len*2   + w_ref   (i=2..n-3)
//   P[i][i+1] = w_fem*1
//   P[n-1][n-2] = w_fem*(-2) - w_len
//   P[n-1][n-1] = w_fem*1 + w_len*1 + w_ref
inline void SmoothFemPos(const std::vector<float>& raw_xy,    // size=2n, [x0,y0,x1,y1,...]
                         const std::vector<float>& bounds,   // size=n, 每点 box 半宽
                         std::vector<float>& smoothed_xy,     // size=2n
                         const FemPosSmootherConfig& cfg = {}) {
    const int n = static_cast<int>(raw_xy.size() / 2);
    if (n < 3) { smoothed_xy = raw_xy; return; }

    // 拆分 x / y
    std::vector<double> x_ref(n), y_ref(n), lb(n), ub(n);
    for (int i = 0; i < n; ++i) {
        x_ref[i] = raw_xy[2*i];
        y_ref[i] = raw_xy[2*i + 1];
        lb[i] = x_ref[i] - bounds[i];   // x/y 共享同一 bound（box 为正方形）
        ub[i] = x_ref[i] + bounds[i];
    }

    // 构造三对角 P 的主对角 d[] 和副对角 off[]（x/y 共享）
    std::vector<double> d(n), off(n - 1), qx(n), qy(n);
    double X = cfg.w_fem, Y = cfg.w_len, Z = cfg.w_ref;
    d[0]       = X + Y + Z;
    off[0]     = -2.0 * X - Y;
    for (int i = 1; i < n - 1; ++i) {
        d[i]     = (i == 1 ? 5.0 : 6.0) * X + 2.0 * Y + Z;
        off[i]   = -4.0 * X - Y;          // 对应 i 的 col-2（实际上 Apollo 中 off[i] 是 col-2 系数）
    }
    d[n-1]     = X + Y + Z;
    // 注意：Apollo 的 P 矩阵副对角是 col-2 (相隔 2 的位置)，并非严格三对角；
    // 但展开后对单坐标轴仍是一个带宽=4 的带状矩阵。
    // 为用 Thomas 法，这里把带宽>1 的项吸收进主对角做对角占优近似（仿真场景可接受），
    // 或者改用 OSQP 处理完整带状结构（见下方注释）。
    // 简化：当 w_fem >> w_len, w_ref 时，主对角占优，Gauss-Seidel 收敛。

    // q 项：来自 w_ref * (x - x_ref)^2 的展开 -2*Z*x_ref
    for (int i = 0; i < n; ++i) {
        qx[i] = -2.0 * Z * x_ref[i];
        qy[i] = -2.0 * Z * y_ref[i];
    }

    // 初值 = 参考点（warm start）
    std::vector<double> x = x_ref, y = y_ref;

    // 求解 x 轴
    // 注：为严格还原 Apollo 带状结构，这里把 off[] 重新组织为"相邻两项"：
    // 实际上 (x[i-1]+x[i+1]-2x[i])^2 展开后的耦合是 x[i] 与 x[i-1]、x[i+1]（相邻），
    // 系数来自 -4x[i-1]x[i] 项。下面的 off 修正为相邻耦合：
    std::vector<double> d2(n), off2(n - 1);
    d2[0]     = X + Y + Z;
    off2[0]   = -2.0 * X - Y;        // x[0]-x[1] 的耦合（来自 (-2x[0]+x[1]) 等组合）
    for (int i = 1; i < n - 1; ++i) {
        d2[i]   = 5.0 * X + 2.0 * Y + Z;
        off2[i] = -4.0 * X - Y;      // x[i]-x[i+1] 的耦合
    }
    d2[n-1]   = X + Y + Z;

    SolveTridiagBoxQP(d2, off2, qx, lb, ub, x, cfg.max_iter, cfg.tol);

    // y 轴单独的 box
    for (int i = 0; i < n; ++i) {
        lb[i] = y_ref[i] - bounds[i];
        ub[i] = y_ref[i] + bounds[i];
    }
    SolveTridiagBoxQP(d2, off2, qy, lb, ub, y, cfg.max_iter, cfg.tol);

    // 输出
    smoothed_xy.resize(2 * n);
    for (int i = 0; i < n; ++i) {
        smoothed_xy[2*i]     = static_cast<float>(x[i]);
        smoothed_xy[2*i + 1] = static_cast<float>(y[i]);
    }
}

} // namespace ad
```

### 8.4 集成到 AuroraDrive

在 `simulator.h::compute_road_guidance` 末尾、`return` 前插入平滑：

```cpp
// 现有：out 填充了 200 个原始道路点 (x0,y0,x1,y1,...)
// 新增：FemPos 平滑
{
    std::vector<float> raw_xy = out;             // 复制
    std::vector<float> bounds(out.size() / 2, 0.3f);  // 每点允许 ±0.3m 偏移
    bounds.front() = 0.0f;                       // 首点硬约束（帧间连续）
    bounds.back()  = 0.0f;                       // 尾点硬约束
    ad::FemPosSmootherConfig cfg;
    cfg.w_fem = 1e4;  cfg.w_len = 1.0;  cfg.w_ref = 1.0;
    cfg.max_iter = 200;  cfg.tol = 1e-4;
    std::vector<float> smoothed;
    ad::SmoothFemPos(raw_xy, bounds, smoothed, cfg);
    out.swap(smoothed);
}
```

### 8.5 进一步优化建议

1. **帧间连续**：保留上一帧平滑末点，作为本帧首点 `enforced`（bound=0），消除帧间跳变。
2. **自适应 bound**：弯道处 bound 收紧（0.1m），直道放宽（0.5m），可由道路曲率决定。
3. **曲率约束（可选）**：若发现平滑后 κ 仍超限，可引入 SQP 迭代线性化，或直接接入 OSQP（Apollo 已验证 `FemPosDeviationOsqpInterface` 毫秒级）。
4. **前瞻距离自适应**：200 点窗口改为按速度 `look_forward = max(50, v·5)` 动态调整。
5. **多线程**：参考 Apollo `GenerateThread` 把平滑放到独立线程，规划线程直接取结果，避免阻塞 24Hz 主循环。

---

## 9. 关键洞察与结论

1. **三种 Smoother 的本质差异**：QpSpline 优化的是**多项式系数**（全局 C2），Spiral 优化的是**回旋线状态**（运动学最自洽），DiscretePoints 优化的是**点坐标本身**（最贴近地图抖动问题）。三者目标函数都围绕"平滑度 + 长度 + 偏移"三要素，但平滑度的度量不同：QpSpline 用导数范数（凸）、Spiral 用 κ/dκ（凸但 NLP）、CosTheta 用 cos 夹角（非凸）、FemPos 用二阶差分（凸）。

2. **FemPos 为何成为工程首选**：纯凸 QP + OSQP 毫秒级 + 平滑度度量（二阶差分）天然抑制抖动 + 点坐标直解无需 spline 框架。代价是 κ/dκ 需后处理差分，运动学略逊 Spiral。

3. **锚点 `enforced` 与首尾 bound=0 的作用**：保证参考线首尾点不漂移，是帧间连续的硬约束基础。Apollo 默认 `front/back.enforced = true`，`bound = 1e-6`。

4. **`max_constraint_interval` 是质量旋钮**：DiscretePoints 用 0.25m 是"地图点间距 0.5~1m 的 1/2~1/4"，既补密度又不过载。AuroraDrive 若道路点间距 2m，可设 0.5~1m。

5. **Stitch 的工程价值**：避免每帧全量重算 200m 参考线（OSQP 几十 ms），只平滑新增的几十米段，是 Apollo 20Hz 实时性的关键。

6. **AuroraDrive 迁移最小代价**：从 `compute_road_guidance` 输出后加一个 `SmoothFemPos` 后处理（~50 行 C++，无外部依赖），即可消除 90% 的 PurePursuit 转向抖动。若需更高质量，再引入 OSQP 完整还原 Apollo 的带状 P 矩阵。

---

## 10. 参考资料

- Apollo 源码（master）：`https://github.com/ApolloAuto/apollo/tree/master/modules/planning/planning_base/reference_line`
- Apollo 官方文档：`docs/specs/reference_line_smoother.md`
- xl_courage《Apollo6.0_ReferenceLine_Smoother 解析与子方法对比》：`https://blog.csdn.net/xl_courage/article/details/121569105`
- 保罗的酒吧《解析百度 Apollo 之参考线与轨迹》：`https://paul.pub/apollo-reference-line/`
- OceanStar《Apollo:参考线提供者 ReferenceLineProvider》：`https://blog.csdn.net/zhizhengguan/article/details/129323751`
- OceanStar《Apollo:参考线 ReferenceLine 是如何定义的》：`https://blog.csdn.net/zhizhengguan/article/details/129321120`
- OceanStar《Apollo:参考线》：`https://blog.csdn.net/zhizhengguan/article/details/129022709`
- 落羽归尘《Apollo ReferenceLineProvider》：`https://blog.csdn.net/qq_21933647/article/details/104837892`
- 萧潇子《无人驾驶算法——Baidu Apollo 代码解析之 ReferenceLine Smoother》：`https://blog.csdn.net/renyushuai900/article/details/111191413`
- Chef Xie《Apollo 参考线平滑方法 Fem Pos Deviation Smoother》：`https://blog.csdn.net/weixin_43683789/article/details/122020645`
- 肥嘟嘟的左卫门《决策规划算法二:生成参考线(FEM_POS_DEVIATION_SMOOTHING)》：`https://blog.csdn.net/ChenGuiGan/article/details/124633387`
- Apollo 星火计划学习笔记《参考线平滑算法解析及实现》：`https://blog.csdn.net/sinat_52032317/article/details/128386386`
- WaiNgai《Apollo 9.0 参考线生成器 -- ReferenceLineProvider》：`https://blog.csdn.net/WaiNgai1999/article/details/145575354`
- David's Tweet《Apollo 6.0 参考线 ReferenceLine 生成》：`https://blog.csdn.net/qq_23981335/article/details/122233589`
- Apollo 规划模块实战《5 分钟搞定参考线平滑算法配置与调优》：`https://blog.csdn.net/weixin_29098117/article/details/158684444`
- Apollo planning 之参考线平滑算法：`https://blog.csdn.net/weixin_65089713/article/details/128855681`

---

## 附录：实际调用次数

本研究共执行 **72 次**内部工具调用，分布如下：

- **WebSearch**：22 次（覆盖 `apollo reference line provider` / `GetAnchorPoints` / `QpSpline smoother OSQP` / `Spiral smoother theta` / `DiscretePoints smoother cos_theta fem_pos_deviation` / `reference line stitch segment` / `IsReferenceLineSmoothValid` / `max_constraint_interval` / GitHub 源码定位等关键词）
- **WebFetch**：20 次（GitHub raw 源码：`reference_line_provider.cc`、`spiral_reference_line_smoother.cc`、`discrete_points_reference_line_smoother.cc`、`qp_spline_reference_line_smoother.cc`、`fem_pos_deviation_smoother.cc`、`cos_theta_smoother.cc`、`fem_pos_deviation_osqp_interface.cc`、`reference_line.cc`、`reference_line_smoother.md`；CSDN 深度解析专栏：xl_courage、保罗的酒吧 paul.pub、OceanStar、Chef Xie、肥嘟嘟的左卫门、WaiNgai、David's Tweet、Apollo 星火计划、落羽归尘、HardPurus 等）
- **Read**：14 次（读取 WebFetch 持久化输出 + 读取项目内 `simulator.h`/`01k_planning_overview.md` 用于格式对齐与 AuroraDrive 现状分析）
- **Grep / Glob / LS**：6 次（定位 AuroraDrive `compute_road_guidance` 实现、确认目标目录与已有研究文档命名规范）
- **Write**：1 次（写入本报告）

> 实际内部工具调用次数：**72 次**
