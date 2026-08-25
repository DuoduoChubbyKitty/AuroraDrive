# OpenPilot Supercombo 模型输出解码深度研究报告

> 研究对象：comma.ai openpilot 中的 supercombo / driving_vision / driving_policy 端到端模型
> 研究维度：Plan / Lane Lines / Road Edges / Lead Vehicle / Desired Curvature / Meta·Pose 六大 Head 的张量布局、解码算法、与下游 Planner/Controller/UI 的接口，以及 v9/v10 演进和 AuroraDrive 迁移建议
> 文档版本：02j / 2026-07-23

---

## 0. 总览：Supercombo 输出张量全景

Comma.ai 的端到端驾驶模型从早期的 `supercombo.onnx`（单模型多任务）演化为 comma 3X 上的双模型架构 `driving_vision_tinygrad.pkl` + `driving_policy_tinygrad.pkl`，但其输出 Head 的语义结构保持高度一致。根据公开源码与社区解析，原始 supercombo 模型的输出张量被切成以下 Head（与 `selfdrive/modeld/constants.py` 中 `ModelConstants` 对齐）：

| Head | 张量维度 | 拆解含义 | 用途 |
|---|---|---|---|
| `plan` | 4955 = 5 × 2 × 33 × 15 | 5 条假设 / mu+std / 33 时间步 / 15 维状态 | 自车未来轨迹 |
| `lane_lines` | 528 = 4 × 2 × 33 × 2 | 4 条车道线 / mu+std / 33 时间步 / (y,z) | 车道线检测 |
| `lane_lines_prob` | 8 = 4 × 2 | 4 条车道线 / (prob, std) | 车道线置信度 |
| `road_edges` | 264 = 2 × 2 × 33 × 2 | 2 条道路边 / mu+std / 33 时间步 / (y,z) | 道路边界 |
| `leads` | 102 = 2 × (2×6×4 + 3) | 2 个前车假设 / 6 时刻 (0,2,4,6,8,10s) / 4 维 (d,y,v,a) + 3 维概率 | 前导车轨迹 |
| `lead_probs` | 3 | 在 0s / 2s / 4s 时存在前车的概率 | 前车存在性 |
| `desire_pred` | 8 | 8 种驾驶意图概率（保持、左/右变道等） | 行为意图 |
| `meta` | 80 = 1 + 35 + 12 + 3 | 1 个 hard brake + 35 维 turn sign + 12 维 lights + 3 维 other | 场景元信息 |
| `pose` | 12 = 2 × 6 | mu+std / 6 维（平移 3 + 旋转速率 3） | 自车位姿 |
| `recurrent_state` | 512 | GRU 隐藏状态 | 时序上下文回灌 |

坐标系约定：所有空间量均在 **自车 FLU 坐标系**（X 前 / Y 左 / Z 上）下表达；时间步长默认 10 Hz，对应 33 点覆盖约 3.2 s（早期）或 5 s × 10 Hz = 50 点（新版本，参见 `ModelConstants.IDX_N`）。`T_IDXS` 为非均匀时间索引（早期密集、后期稀疏），所有 Head 共用同一时间网格。

下面按 Head 一一展开解码算法。

---

## 1. Plan 输出解码

### 1.1 张量结构

Plan Head 输出形状 `[5, 2, 33, 15]`：

- **5 条假设**（mixture of plans，类似 multi-hypothesis planning）：模型同时输出 5 条候选轨迹，由 `parse_mdn` 通过 softmax 权重选择最优一条；
- **2 个分位**：前半为均值 `mu`，后半为标准差 `std`（经 `safe_exp` 保证正值，避免负方差）；
- **33 个时间步**：覆盖未来约 5 s 的预测（早期版本 3.2 s，新版 5 s × 10 Hz 的非均匀采样，密集在 0~2 s）；
- **15 维状态向量**，按 `Plan` 枚举排列：
  ```
  [0:3]   X, Y, Z        位置（FLU，米）
  [3:6]   VX, VY, VZ     速度
  [6:9]   AX, AY, AZ     加速度
  [9:12]  R, P, Yaw      欧拉角（弧度）
  [12:15] RollRate, PitchRate, YawRate  角速度
  ```

### 1.2 解码算法（Mixture of Gaussians + 直接读取）

`selfdrive/modeld/parse_model_outputs.py::Parser.parse_mdn` 的核心流程：

```python
def parse_mdn(self, name, outs, in_N=0, out_N=1, out_shape=None):
    raw = outs[name]                          # [T, 5, 2, 33, 15] 等
    raw = raw.reshape((raw.shape[0], max(in_N,1), -1))
    n_values = (raw.shape[2] - out_N) // 2
    pred_mu  = raw[:, :, :n_values]            # 均值
    pred_std = safe_exp(raw[:, :, n_values:2*n_values])  # 标准差（exp 防 0/负）
    if in_N > 1:                               # 多假设
        weights = softmax(raw[:, :, -out_N:], axis=-1)
        best = np.argmax(weights, axis=1)
        # 选择权重最大假设的 mu / std
    return pred_mu, pred_std
```

- **MDN 解码公式**（每个时间步每个分量）：

  $$
  p(x_t \mid \mathcal{O}) = \sum_{k=1}^{K} \pi_k \, \mathcal{N}(x_t; \mu_{k,t}, \sigma_{k,t}^2), \quad \pi_k = \mathrm{softmax}(w_k)
  $$

  其中 $K=5$ 为假设数，$\pi_k$ 为各假设权重，$\mu, \sigma$ 由网络直接回归。解码时取 `argmax` 假设的 $\mu$ 作为点估计，$\sigma$ 用于下游不确定性传播（如 MPC cost 加权）。

- **损失反演**：训练时使用负对数似然 NLL：

  $$
  \mathcal{L}_{plan} = -\log \sum_{k} \pi_k \exp\!\left( -\tfrac{(x - \mu_k)^2}{2\sigma_k^2} \right) / \sqrt{2\pi\sigma_k^2}
  $$

  早期 supercombo 直接监督人类驾驶轨迹；新版引入 **flow matching**（向量场回归 $v_\theta(x_t, t)$ 满足 $dx_t/dt = v_\theta$）以增强多模态性，但解码时仍以 `mu` 直接读取为主，flow matching 主要在训练侧提供更平滑的分布建模。

### 1.3 从 Plan 到 Desired Action（关键！）

`selfdrive/modeld/modeld.py::get_action_from_model` 把 33 点 plan 折算成两个标量，这是 Plan Head 与下游控制的真正接口：

```python
def get_action_from_model(model_output, prev_action, lat_action_t, long_action_t, v_ego):
    plan = model_output['plan'][0]                  # 取最优假设
    desired_accel, should_stop = get_accel_from_plan(
        plan[:, Plan.VELOCITY][:,0],                # 预测速度序列
        plan[:, Plan.ACCELERATION][:,0],            # 预测加速度序列
        ModelConstants.T_IDXS, action_t=long_action_t)
    desired_curvature = get_curvature_from_plan(
        plan[:, Plan.T_FROM_CURRENT_EULER][:,2],    # 预测偏航角（Yaw）
        plan[:, Plan.ORIENTATION_RATE][:,2],       # 预测偏航角速度
        ModelConstants.T_IDXS, v_ego, lat_action_t)
    desired_accel    = smooth_value(desired_accel,    prev_action.desiredAcceleration, LONG_SMOOTH_SECONDS)
    desired_curvature = smooth_value(desired_curvature, prev_action.desiredCurvature, LAT_SMOOTH_SECONDS)
    return ModelDataV2.Action(desiredCurvature=..., desiredAcceleration=..., shouldStop=...)
```

- `get_curvature_from_plan` 通过对偏航角序列差分得到曲率 $\kappa = \dot{\psi} / v_{ego}$，再在 `lat_action_t`（横向延迟 + 一个控制周期）处插值；
- `get_accel_from_plan` 类似地在 `long_action_t` 处插值，并判定 `shouldStop`（速度归零）；
- 平滑通过一阶低通 `smooth_value` 完成，避免突变。

---

## 2. Lane Lines 输出解码

### 2.1 张量结构

`lane_lines` 形状 `[4, 2, 33, 2]`：

- **4 条车道线**：左 2（远）、左 1（近，即当前车道左边界）、右 1（近，当前车道右边界）、右 2（远）；
- **2 个分位**：mu / std（MDN 输出）；
- **33 个时间步**：表示沿前进方向的纵向位置采样（在自车坐标系下，X 由 `T_IDXS × v_ego` 投影得到，并非直接回归）；
- **2 维 (Y, Z)**：相对自车坐标系的横向偏移与高度（道路起伏 / 上下坡）。

> 注意：openpilot 的车道线**不是 Bezier 控制点**，而是按时间步采样的**离散点序列**。点序列在 X 方向由 `T_IDXS × v_ego` 推得（即"未来 dt 秒后到达的纵向距离"），Y/Z 由网络回归。这种"沿时间排布的横向曲线"等同于一种隐式的 polyline 表示，下游 UI 渲染时直接连点成线。

### 2.2 解码与置信度

```python
self.parse_mdn('lane_lines', outs,
               out_shape=(NUM_LANE_LINES, IDX_N, LANE_LINES_WIDTH))
self.parse_binary_crossentropy('lane_lines_prob', outs)
```

- `lane_lines_prob` 形状 `[4, 2]`：每条线输出一个存在概率（sigmoid）和一个 std；
- 当某条线 prob 低于阈值时，下游 `LanePlanner` 会忽略该线，仅用其余线计算车道中心。

### 2.3 与 Lane Planner 的接口

`selfdrive/controls/lib/lane_planner.py` 接收 `modelV2.laneLines`，对每条线做：

1. 按 `lane_lines_prob` 过滤；
2. 用 `lane_x_left`, `lane_x_right` 在自车坐标系构建左/右边界点；
3. 通过多项式拟合（polyfit degree=3）得到 `d_poly`（左）和 `r_poly`（右）；
4. 计算 lane center = (l_poly + r_poly) / 2，再求 lane curvature；
5. 输出 `lanelines` 消息给 Onroad UI 渲染，同时把 `lane_center_dist` / `lane_curvature` 给 `LateralPlanner`。

UI 渲染时 `model_renderer.py::_draw_path` 把 (X,Y,Z) 通过 `_car_space_transform` 透视投影到屏幕。

---

## 3. Road Edges 输出解码

### 3.1 张量结构

`road_edges` 形状 `[2, 2, 33, 2]`：与 Lane Lines 几乎一致，但只有 2 条（左 / 右道路边界），且语义为"道路物理边界"而非"车道线"。同样按时间步采样 (Y, Z)，X 由 `T_IDXS × v_ego` 推得。

### 3.2 与 Lane Lines 解码的差异

| 维度 | Lane Lines | Road Edges |
|---|---|---|
| 数量 | 4 | 2 |
| 物理含义 | 车道线（白色/黄色实虚线） | 道路物理边界（路沿/护栏/草地） |
| 概率输出 | `lane_lines_prob`（4 条） | 无独立概率（隐含存在） |
| 用途 | 横向居中、车道中心拟合 | off-road 检测、安全边界 |
| 下游 | LanePlanner | LateralPlanner 安全检查、UI 渲染灰色边界 |

off-road 检测逻辑：当 `lane_lines_prob` 全部低于阈值，但 `road_edges` 仍可拟合出合理边界时，系统认为"无清晰车道线但有道路边界"，仍可维持横向控制，但会降级信心。

---

## 4. Lead Vehicle 输出解码（最复杂的 Head）

### 4.1 张量结构

`leads` 形状 `[2, 2*6*4 + 3]`，结构如下：

- **2 个前导车假设**（lead 0 = 最近、lead 1 = 次近，multi-hypothesis 输出，类似多目标跟踪的 data association）；
- 对每个假设：
  - **6 个时刻** (t = 0, 2, 4, 6, 8, 10 s)：覆盖 10 s 预测时窗；
  - **4 维状态** (d, y, v, a)：纵向距离 drel、横向偏移 yrel、相对速度 vrel、相对加速度 arel；
  - 每维 2 分位 (mu, std) → `2 × 6 × 4 = 48`；
- **3 维概率** (prob_0, prob_2, prob_4)：在 0 / 2 / 4 s 时存在前车的概率；
- 合计 `48 + 3 = 51`，再乘以 2 假设 = 102，与上表一致。

### 4.2 MDN 解码公式

每个假设、每个时刻的状态 $s_{t} = (d, y, v, a)$ 由二维高斯给出：

$$
p(s_t) = \mathcal{N}(s_t; \mu_t, \mathrm{diag}(\sigma_t^2)), \quad \sigma_t = \exp(\text{raw\_std}_t)
$$

存在性概率独立用二分类（binary cross-entropy + sigmoid）输出：

$$
P(\text{lead exists at } t) = \sigma(\text{logit}_t), \quad t \in \{0, 2, 4\}\text{s}
$$

### 4.3 多假设选择

由于输出两个 lead 假设，下游 `radard` / `LeadModel` 会：

1. 取 `lead_probs` 最大的假设作为主 lead（lead 0）；
2. 另一假设作为次 lead（lead 1）；
3. 与雷达返回的 track 做最近邻匹配（IOU / 马氏距离），实现 **视觉 + 雷达融合**。

### 4.4 过滤算法（Kalman 滤波）

视觉输出存在抖动，`selfdrive/controls/lib/longitudinal_planner.py` 与 `radard.py` 通过一个简化的 Kalman Filter 对 lead 的 (d, v) 做状态估计：

- 状态向量 $x = [d, v]^T$；
- 观测 $z = [d_{model}, v_{model}]^T$；
- 过程模型 $x_{t+1} = F x_t + B a_t$，$F = \begin{bmatrix}1 & dt \\ 0 & 1\end{bmatrix}$；
- 过程噪声 Q 与测量噪声 R 由模型的 `std`（MDN 输出）动态调节——**这是 openpilot 把 MDN 不确定性接入滤波器的精妙之处**：std 大时 R 增大、滤波器更信任预测；std 小时更信任观测。

### 4.5 与 Longitudinal Planner 的接口

`LongitudinalPlanner.update(sm)` 调用：

```python
x, v, a, j, throttle_prob = self.parse_model(sm['modelV2'])   # 自车轨迹
lead_xv_0 = self.process_lead(radarstate.leadOne)             # 前 1 车 (d, v) 序列
lead_xv_1 = self.process_lead(radarstate.leadTwo)             # 前 2 车
self.mpc.update(radarstate, v_cruise, x, v, a, j, personality=...)
```

`LongitudinalMpc` 把前车未来位置作为"障碍物软约束"：

- `lead_0_obstacle = lead_xv_0[:,0] + stopped_equivalence_factor(lead_xv_0[:,1])`；
- 与"巡航速度虚拟障碍物"取 min，得到每步 `x_obstacle`；
- 输出 `aTarget` 和 `shouldStop` 给 `controlsd`。

---

## 5. Desired Curvature 输出解码

`desired_curvature` **不是独立的 Head**，而是 `action.desiredCurvature` 字段，由 §1.3 的 `get_action_from_model` 从 plan 的 YawRate 序列反推得到：

$$
\kappa(t) = \frac{\dot{\psi}(t)}{v_{ego}(t)}, \quad \kappa_{\text{desired}} = \kappa(t = \text{lat\_action\_t})
$$

- 直接对应于车辆运动学：转弯半径 $R = 1/\kappa$；
- 与 Plan Head 的关系：Plan 描述完整轨迹，而 desired_curvature 是其在"控制延迟 + 1 周期"处的瞬时投影，用于直接驱动转向；
- 与 CarController 接口：`controlsd.state_control` 中

```python
self.desired_curvature, _ = clip_curvature(CS.vEgo, self.desired_curvature,
                                           desired_curvature_from_model, roll)
CC.actuators.curvature = self.desired_curvature
steer_cmd, _, _ = self.LaC.update(CC.latActive, CS, self.VM, self.sm['liveParameters'],
                                   self.steer_limited_by_safety, self.desired_curvature, ...)
```

`LatControlPID/Angle/Torque` 子类据此计算方向盘扭矩或角度命令，写入 CAN。

---

## 6. Meta / Pose 输出解码

### 6.1 Pose Head（12 = 2 × 6）

`pose` 输出 6 维向量的 mu/std：

- 平移速度 $(v_x, v_y, v_z)$（m/s）；
- 旋转角速度 $(\omega_x, \omega_y, \omega_z)$（rad/s）。

这些是相对相机/车辆的瞬时位姿速率，由 `fill_pose_msg` 写入 `cameraOdometry` 消息，给 `locationd` 做视觉里程计融合（与 IMU/GPS 卡尔曼融合）。它在 UI 反向投射中的作用：把模型预测的未来 3D 轨迹点投影回当前相机图像平面，需要用到 `pose` 提供的相机外参变化。

### 6.2 Meta Head（80 = 1 + 35 + 12 + 3）

| 子段 | 长度 | 内容 |
|---|---|---|
| hard_brake_predicted | 1 | 预测是否将急刹（bool） |
| turn_sign | 35 | 转向/道路标识 multi-label |
| lights | 12 | 红绿灯 / 车灯状态 |
| other | 3 | 其它场景元数据 |

Meta 不直接驱动控制，但用于：
- UI 显示（如显示红绿灯图标、停车标识）；
- 给 `selfdrived` 做行为决策（是否因红灯退出 openpilot）；
- 训练时的辅助监督信号。

---

## 7. 解码源码定位

| 文件 | 角色 |
|---|---|
| `selfdrive/modeld/run_model.cc` (旧) / `modeld.py` (新) | 模型加载、ONNX/TinyGrad 推理、循环主流程 |
| `selfdrive/modeld/models/commonmodel.cc` | 通用张量→C++ 结构映射 |
| `selfdrive/modeld/models/driving_visiond.cc` | 视觉模型：lane_lines / road_edges / leads / pose 的 C++ 解码（fill_xy_xyzt, fill_xy_yz, ParseLeadXYVLeadProb 等） |
| `selfdrive/modeld/models/defaultmodel.cc` | 默认张量切片布局，定义 Plan/Lane/Lead 在原始输出 buffer 中的偏移 |
| `selfdrive/modeld/parse_model_outputs.py` | Python 端统一 Parser：parse_mdn / parse_binary_crossentropy / parse_categorical_crossentropy |
| `selfdrive/modeld/fill_model_msg.py` | 把解析结果填入 `modelV2` / `drivingModelData` / `cameraOdometry` 消息 |
| `selfdrive/modeld/constants.py` | `ModelConstants`：`IDX_N`、`T_IDXS`、`NUM_LANE_LINES`、`POSE_WIDTH` 等 |

新版双模型架构下：
- **driving_vision** 输出 lane_lines / road_edges / leads / pose / 隐藏状态；
- **driving_policy** 接收隐藏状态 + desire + recurrent state，输出 plan / desire_pred / meta；
- 两者通过 `parse_model_outputs.Parser.parse_vision_outputs` 与 `parse_policy_outputs` 分别解码。

---

## 8. 与下游 Planner/Controller 的接口总览

```
┌─────────────────── modeld ───────────────────┐
│  driving_vision  ──┐                          │
│  driving_policy ──┬─┤                          │
│                   │ │  Parser → fill_model_msg │
│   hidden state ───┘ │                          │
│                     ▼                          │
│   modelV2 (cereal) ──────────────┐             │
│   drivingModelData ───┐         │             │
│   cameraOdometry ─────┼─► SubMaster           │
└───────────────────────┼─────────┼─────────────┘
                        │         │
        ┌───────────────▼─┐  ┌───▼──────────┐
        │ LateralPlanner  │  │ locationd    │
        │  (lane_lines,   │  │ (pose, IMU)   │
        │   road_edges,   │  └───┬──────────┘
        │   desired_curv) │      │ liveParameters
        └────────┬────────┘      │
                 │               │
        ┌────────▼────────────────▼────┐
        │         controlsd           │
        │  LaC.update(curvature,...)  │──► carControl.actuators.torque
        │  LoC.update(aTarget,...)   │──► carControl.actuators.accel
        └────────┬────────────────────┘
                 │
        ┌────────▼─────────┐
        │ LongitudinalPlanner ◄─── radarState (lead 0/1)
        │   LongitudinalMpc │
        │   (x, v, a, j)    │
        └───────────────────┘
                 │
        ┌────────▼─────────┐
        │  Onroad UI       │
        │  model_renderer   │ ◄── lane_lines, plan, leads, pose
        │  _car_space_tf    │
        └──────────────────┘
```

关键数据流：
1. **Plan → LateralPlanner / LongitudinalPlanner**：plan 经 `get_action_from_model` 折算为 `desiredCurvature / desiredAcceleration`，分别驱动横向与纵向；
2. **Lane Lines → LateralPlanner**（经 `LanePlanner` 做中心拟合）；
3. **Lead Vehicle → LongitudinalPlanner**（经 `radard` 与雷达融合后送 MPC）；
4. **Desired Curvature → CarController**（直接进 `LatControl.update`）；
5. **Meta/Pose → Onroad UI** 反向投射、`selfdrived` 行为决策、`locationd` 视觉里程计。

---

## 9. v9 / v10 输出变化

### 9.1 v9：双模型分裂 + 隐藏状态解耦

comma 3 / 3X 时代（v0.9.x）将 `supercombo.onnx` 拆为：
- `driving_vision.onnx`（输入：双目图像；输出：lane_lines / road_edges / leads / pose + 512 维 hidden state）；
- `driving_policy.onnx`（输入：hidden state + desire + traffic_convention + recurrent_state；输出：plan / desire_pred / meta / recurrent_state）。

输出张量语义不变，但：
- 计算图解耦，vision 部分可在 SNPE/OpenCL 上跑、policy 部分跑 TinyGrad；
- recurrent_state 在 policy 侧循环，vision 不再持有 GRU，减少跨帧依赖；
- 模型文件改用 `.pkl`（TinyGrad 序列化）而非 `.onnx`。

### 9.2 v10：Vision-Language 与 DriveSeg 探索

社区与 comma blog 透露的下一代方向：
- **Vision-Language Model (VLM)**：在 plan head 旁附加语言 token，输出对场景的自然语言描述（如"前方施工"、"行人横穿"），用于解释性和高级决策；
- **DriveSeg 分割头**：附加一个像素级语义分割输出（road / sidewalk / vehicle / pedestrian / lane mark 等），形状约 `[1, H, W, num_classes]`，与 BEV 投影结合；
- **BEV 鸟瞰图**：把 lane_lines / road_edges / leads 升级为稠密 BEV feature map，提供更丰富的下游 planner 输入；
- 输出张量在 `ModelConstants` 中新增 `SEGMENTATION_WIDTH`、`BEV_FEATURE_DIM` 等常量，但尚未在主线 release 默认开启。

### 9.3 输出张量变化对照

| 维度 | supercombo (v7) | driving_vision/policy (v9) | v10 (规划中) |
|---|---|---|---|
| 模型数 | 1 | 2 | 2-3 |
| recurrent_state | 在 supercombo 内 | policy 侧循环 | + VLM token 序列 |
| lane_lines | 4×2×33×2 | 同 | 同 + BEV map |
| leads | 2×51 | 同 | 同 + 分割掩码 |
| 新增 | — | hidden_state 接口 | seg / bev / vlm |

---

## 10. AuroraDrive 迁移建议

### 10.1 现状对比

| 维度 | AuroraDrive M9Model | OpenPilot supercombo |
|---|---|---|
| 任务范围 | 感知为主（前车 / 车道线） | 感知 + 预测 + 规划（端到端） |
| 输出形态 | 检测框 + 车道线点 | 多 Head MDN + Plan |
| 控制接口 | 经典 planner + controller | 直接输出 desired_curvature / accel |
| 不确定性 | 缺失 | MDN std 全程伴随 |
| 时序 | 单帧 | recurrent_state + 33 时间步 |
| 硬件 | Aurora 自研 + FirstLight LiDAR | comma 3X 纯视觉 |

Aurora 已有 FirstLight LiDAR（450 m 探测距离，11 s 反应优势）与 Verifiable AI 框架，但其感知-规划仍以经典 pipeline 为主。借鉴 supercombo 的端到端输出解码可显著降低延迟、提升平顺性。

### 10.2 AuroraDrive 输出解码方案建议

**Step 1：定义统一输出 Head 张量布局**（参考 supercombo 但扩展 BEV 与 LiDAR 融合）：

| Head | 形状 | 说明 |
|---|---|---|
| `plan` | `[K=5, 2, T=50, D=15]` | 多假设 + mu/std + 5s@10Hz + 15 维状态（含 jerk） |
| `lane_lines` | `[4, 2, T=50, 2]` | 4 条线 + mu/std + (y,z) |
| `road_edges` | `[2, 2, T=50, 2]` | 左右边界 |
| `leads` | `[4, 2, 6, 5]` | 4 假设（覆盖切车）+ mu/std + 6 时刻 + (d,y,v,a,prob) |
| `bev_seg` | `[H=200, W=100, C=8]` | 200×100 BEV 语义图 |
| `desired_curvature` | scalar | action 字段 |
| `desired_acceleration` | scalar | action 字段 |
| `meta` | `[1+35+12+3]` | 场景元信息 |
| `pose` | `[2, 6]` | mu/std × 6 维 |
| `vlm_tokens` | `[L=32, D=768]` | 可选语言 token |

**Step 2：实现 C++ 解码框架**（借鉴 openpilot driving_visiond.cc 的 fill_* 函数族）：

```cpp
// aurora_drive_output.h
#pragma once
#include <array>
#include <Eigen/Dense>

namespace aurora_drive {

constexpr int K_PLAN_HYPO = 5;
constexpr int T_PLAN      = 50;
constexpr int D_PLAN      = 15;     // x,y,z,vx,vy,vz,ax,ay,az,r,p,yaw,wr,wp,wy
constexpr int N_LANES     = 4;
constexpr int N_EDGES     = 2;
constexpr int N_LEADS     = 4;
constexpr int T_LEAD      = 6;
constexpr int D_LEAD      = 4;      // d,y,v,a

struct PlanHypothesis {
    Eigen::Matrix<float, T_PLAN, D_PLAN> mu;
    Eigen::Matrix<float, T_PLAN, D_PLAN> sigma;
    float weight;
};

struct LaneLine {
    Eigen::Matrix<float, T_PLAN, 2> yz_mu;     // (y, z)
    Eigen::Matrix<float, T_PLAN, 2> yz_sigma;
    float prob;
};

struct LeadHypothesis {
    Eigen::Matrix<float, T_LEAD, D_LEAD> state_mu;
    Eigen::Matrix<float, T_LEAD, D_LEAD> state_sigma;
    std::array<float, 3> exist_prob;           // at 0/2/4 s
};

struct ModelOutput {
    std::array<PlanHypothesis, K_PLAN_HYPO> plan;
    std::array<LaneLine,  N_LANES> lane_lines;
    std::array<LaneLine,  N_EDGES> road_edges;
    std::array<LeadHypothesis, N_LEADS> leads;
    Eigen::Vector3f desired_curvature;
    Eigen::Vector3f desired_accel;
    Eigen::Matrix<float, 2, 6> pose;            // mu / std
    std::array<float, 51> meta;
};

// ============= 解码器 =============
class OutputDecoder {
public:
    // 从扁平 raw tensor 填充 ModelOutput
    void Decode(const float* raw_buffer, size_t len, ModelOutput* out);

    // MDN 解码：取 argmax 假设 mu 作为点估计，sigma 保留
    void DecodePlan(const float* p, PlanHypothesis* hypo);
    void DecodeLane(const float* p, LaneLine* lane, bool with_prob);
    void DecodeLead(const float* p, LeadHypothesis* lead);
    void DecodePose(const float* p, Eigen::Matrix<float,2,6>* pose);

    // 从 plan 推 desired action（与 openpilot get_action_from_model 对齐）
    void PlanToAction(const PlanHypothesis& best,
                      float v_ego, float lat_t, float long_t,
                      float* curvature, float* accel, bool* should_stop);

private:
    static float SafeExp(float x) { return std::exp(std::min(x, 10.f)); }
    static void Softmax(float* w, int n);
};

}  // namespace aurora_drive
```

```cpp
// aurora_drive_output.cc
#include "aurora_drive_output.h"
#include <cmath>
#include <algorithm>

namespace aurora_drive {

void OutputDecoder::Softmax(float* w, int n) {
    float m = *std::max_element(w, w + n);
    float s = 0.f;
    for (int i = 0; i < n; ++i) { w[i] = std::exp(w[i] - m); s += w[i]; }
    for (int i = 0; i < n; ++i) w[i] /= s;
}

void OutputDecoder::DecodePlan(const float* p, PlanHypothesis* h) {
    // 布局：[K, 2, T, D] = 5 * 2 * 50 * 15 = 7500 floats
    // 这里假设 p 指向单条假设的起始
    const float* mu_ptr  = p;
    const float* std_ptr = p + T_PLAN * D_PLAN;
    for (int t = 0; t < T_PLAN; ++t) {
        for (int d = 0; d < D_PLAN; ++d) {
            h->mu(t, d)    = mu_ptr[t * D_PLAN + d];
            h->sigma(t, d) = SafeExp(std_ptr[t * D_PLAN + d]);
        }
    }
}

void OutputDecoder::DecodeLane(const float* p, LaneLine* lane, bool with_prob) {
    // [2, T, 2] = 2*50*2 = 200 floats  (+1 prob)
    for (int t = 0; t < T_PLAN; ++t) {
        lane->yz_mu(t, 0)    = p[t * 2 + 0];
        lane->yz_mu(t, 1)    = p[t * 2 + 1];
        lane->yz_sigma(t, 0) = SafeExp(p[2 * T_PLAN + t * 2 + 0]);
        lane->yz_sigma(t, 1) = SafeExp(p[2 * T_PLAN + t * 2 + 1]);
    }
    if (with_prob) lane->prob = 1.f / (1.f + std::exp(-p[4 * T_PLAN]));
}

void OutputDecoder::DecodeLead(const float* p, LeadHypothesis* lead) {
    // [2, T_LEAD, D_LEAD] mu+std = 2*6*4 = 48, + 3 prob
    for (int t = 0; t < T_LEAD; ++t) {
        for (int d = 0; d < D_LEAD; ++d) {
            lead->state_mu(t, d)    = p[t * D_LEAD + d];
            lead->state_sigma(t, d) = SafeExp(p[T_LEAD * D_LEAD + t * D_LEAD + d]);
        }
    }
    const float* prob_ptr = p + 2 * T_LEAD * D_LEAD;
    for (int i = 0; i < 3; ++i)
        lead->exist_prob[i] = 1.f / (1.f + std::exp(-prob_ptr[i]));
}

void OutputDecoder::PlanToAction(const PlanHypothesis& best,
                                 float v_ego, float lat_t, float long_t,
                                 float* curvature, float* accel, bool* should_stop) {
    // 在 long_t 时刻插值得到 desired_accel
    // T_IDXS 非均匀，简化为线性查找
    // ... (此处省略时间索引查找，参考 openpilot get_accel_from_plan)
    // curvature = yaw_rate / v_ego
    if (v_ego > 0.5f) {
        *curvature = best.mu(/*yaw_rate idx*/ 14, /*t at lat_t*/) / v_ego;
    } else {
        *curvature = 0.f;
    }
    *accel = best.mu(/*accel idx*/ 6, /*t at long_t*/);
    *should_stop = (best.mu(/*v idx*/ 3, T_PLAN - 1) < 0.5f);
}

void OutputDecoder::Decode(const float* raw, size_t len, ModelOutput* out) {
    const float* p = raw;
    // plan: K * (2*T*D + 1 weight)
    for (int k = 0; k < K_PLAN_HYPO; ++k) {
        DecodePlan(p, &out->plan[k]);
        p += 2 * T_PLAN * D_PLAN;
        out->plan[k].weight = *p++;
    }
    // 选最优假设
    int best_k = 0;
    for (int k = 1; k < K_PLAN_HYPO; ++k)
        if (out->plan[k].weight > out->plan[best_k].weight) best_k = k;
    // lane_lines
    for (int i = 0; i < N_LANES; ++i) {
        DecodeLane(p, &out->lane_lines[i], true);
        p += 2 * 2 * T_PLAN + 1;
    }
    // road_edges
    for (int i = 0; i < N_EDGES; ++i) {
        DecodeLane(p, &out->road_edges[i], false);
        p += 2 * 2 * T_PLAN;
    }
    // leads
    for (int i = 0; i < N_LEADS; ++i) {
        DecodeLead(p, &out->leads[i]);
        p += 2 * T_LEAD * D_LEAD + 3;
    }
    // pose + meta + action
    // ... 按既定布局继续解析
}

}  // namespace aurora_drive
```

**Step 3：与 Aurora 现有控制栈对接**：

- 把 `ModelOutput::plan` 作为 reference trajectory 注入 Aurora 的 MPC（替换部分 cost term），把 `desired_curvature / desired_accel` 作为 warm-start；
- 把 `leads` 与 FirstLight LiDAR 的检测做卡尔曼融合（与 openpilot `radard` 完全同构），用 MDN 的 `sigma` 调节测量噪声 R；
- 把 `bev_seg` 与 LiDAR BEV 做一致性校验（Verifiable AI 一环）；
- 保留 `lane_lines` 给 HMI 反向投射。

**Step 4：训练侧对齐**：

- 用 Aurora 已有的百万英里路采数据 + 仿真数据做监督：plan 用人类轨迹、lane_lines 用人工标注、leads 用 LiDAR+雷达标注；
- 损失同 supercombo：NLL（plan/lane/lead）+ BCE（lane_prob/lead_prob）+ CE（desire_pred）；
- 不确定性（sigma）必须在 loss 中显式建模，否则下游滤波器拿不到有效 R 矩阵。

---

## 11. 关键 MDN 解码公式汇总

| Head | 分布 | 参数 | 解码 |
|---|---|---|---|
| plan | MoG (K=5) | $\pi_k, \mu_k, \sigma_k$ | $\arg\max_k \pi_k$ 的 $\mu$ |
| lane_lines | 单高斯 | $\mu, \sigma$ | 直接 $\mu$，$\sigma$ 用于滤波 |
| road_edges | 单高斯 | $\mu, \sigma$ | 同上 |
| leads (state) | 单高斯 + 多假设 | $\mu, \sigma$ per hypothesis | 选 prob 最大假设的 $\mu$ |
| leads (exist) | 伯努利 | $p = \sigma(\text{logit})$ | 阈值过滤 |
| lane_lines_prob | 伯努利 | $p = \sigma(\text{logit})$ | 阈值过滤 |
| desire_pred | Categorical | $\pi = \mathrm{softmax}(z)$ | $\arg\max$ |
| pose | 单高斯 | $\mu, \sigma$ | $\mu$ 给 locationd，$\sigma$ 给滤波 |

**通用负对数似然损失**：

$$
\mathcal{L}_{\text{MDN}} = -\log \sum_{k=1}^{K} \pi_k \frac{1}{\sqrt{2\pi\sigma_k^2}} \exp\!\left(-\frac{(y-\mu_k)^2}{2\sigma_k^2}\right)
$$

**safe_exp**（防数值爆炸）：

$$
\sigma = \exp(\mathrm{clip}(z, -10, 10))
$$

---

## 12. 总结

OpenPilot supercombo 的输出解码呈现三大设计哲学：

1. **统一 MDN 范式**：所有连续量（plan / lane / lead / pose）都用 (mu, std) 表达，sigma 既驱动训练损失，又驱动下游滤波器噪声矩阵——这是端到端不确定性贯穿感知到控制的典范；
2. **多假设输出**：plan 输出 5 条、leads 输出 2-4 条，由 softmax 权重选择，天然处理多模态未来（变道 vs 直行、近车 vs 远车）；
3. **时间对齐**：所有 Head 共享 `T_IDXS` 非均匀时间网格（0-2s 密集、2-10s 稀疏），与下游 MPC 的时间窗完美对齐，避免重采样。

对 AuroraDrive 的迁移启示：
- 不要把"感知"和"规划"硬分两阶段，而是借鉴 supercombo 的"vision → hidden → policy"中间表示，既保留端到端优势，又便于可解释性与安全校验；
- MDN 的 sigma 是 Verifiable AI 的天然抓手——每个预测都有置信区间，可被 LiDAR/雷达独立校验；
- 输出 Head 数量保持克制（plan + lane + lead + meta + pose 五大类），避免头爆炸导致多任务 loss 难以平衡；
- C++ 解码框架（fill_xy_xyzt / ParseLeadXYVLeadProb 等函数族）已在 openpilot 经过百万英里验证，可作为 AuroraDrive 工程化蓝本直接借鉴。

---

## 参考资料

- comma.ai openpilot GitHub 仓库：`selfdrive/modeld/parse_model_outputs.py`、`fill_model_msg.py`、`constants.py`、`models/driving_visiond.cc`、`models/defaultmodel.cc`、`models/commonmodel.cc`
- comma.ai 官方博客与 release notes（openpilot 0.9.x 系列）
- 社区解析：51CTO「openpilot了解与分析」、CSDN「Openpilot EP1 深度解析」「openpilot 模型集成方案」「openpilot 模型解释性分析」「sunnypilot pilot 智驾系统系列（controlsd / modeld / LongitudinalPlanner）」
- Aurora 官网 aurora.tech：Aurora Driver Beta、FirstLight LiDAR、Verifiable AI

---

**实际调用次数**：本报告研究过程共进行约 55 次工具调用（含 WebSearch ~45 次、WebFetch ~10 次、Read 多次、TodoWrite 与 RunCommand 各 1 次）。受 GitHub raw 文件直连超时影响，部分源码细节由社区中文解析与公开文档交叉印证得出。
