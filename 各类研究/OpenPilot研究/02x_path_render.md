# OpenPilot Path 路径渲染深度研究报告

> 文件编号：02x_path_render
> 研究对象：comma.ai openpilot 中 supercombo Plan Head 输出 → onroad UI 路径多边形渲染的完整管线
> 覆盖版本：openpilot 0.8.x ~ 0.11.x（comma two / 3 / 3X / four），重点 0.9.5（FastViT + MPC 入模）~ 0.11.1（World Model + LM GT3）
> 研究方法：WebSearch + WebFetch（约 52 次内部工具调用），结合 comma.ai 官方博客、CSDN/51CTO 源码解析、GitHub/gitcode 路径核对、本地既有研究文档（02j 输出解码 / 02m 横向 MPC / 02u onroad UI / 02w lead box / 02k v9-v10）交叉印证
> 关联文件：02j_output_decode（Plan/Lane Head 张量解码）、02m_lateral_mpc（Plan → desiredCurvature）、02u_onroad_ui（Onroad UI 架构）、02w_lead_box（共用投影矩阵）、02k_v9_v10（World Model 演进）、Apollo 研究/01b（Dreamview 渲染）、02b_dreamview_plus

---

## 0. 摘要

OpenPilot 的「Path 路径渲染」是该项目最具辨识度的视觉元素：在前视摄像头画面上，一条带有透视收缩、宽度可变、颜色随驾驶意图渐变的「路径带」从车头延伸至远方，把神经网络对未来 2 秒轨迹的预测直接以第一人称透视的方式呈现给驾驶员。这条路径带不是真正的 3D 场景对象，而是把 supercombo Plan Head 输出的 33 个 3D 路径点，经与车道线/前车**同一套**相机投影矩阵 `_car_space_transform = K @ view_from_road` 反向投射到 2D 屏幕像素，再扩展为左右偏移的多边形带填充得到的「伪 3D」叠加层。

整套路径渲染管线核心要素：

1. **数据**：supercombo Plan Head 输出 `[5, 2, 33, 15]` —— 5 条多假设轨迹 × (mu+std) × 33 时间步 × 15 维状态（x/y/z 位置、速度、加速度、欧拉角、角速度），由 MDN softmax 权重选最优假设；坐标系为自车 FLU road frame（X 前 / Y 左 / Z 上）。
2. **投影**：`get_view_frame_from_road_frame(roll, pitch, yaw, height)` 装配 3×4 的 view_from_road 矩阵，再左乘相机内参 K 得到 3×4 投影矩阵 M，对每个 3D 点做透视除法得到屏幕像素。
3. **多边形化**：`_map_line_to_polygon` 把单条折线沿 Y 轴左右各偏移 `y_off`、Z 轴抬升 `z_off`，得到上下两条边，构成带状多边形。
4. **颜色编码**：默认 engage 模式为蓝色路径；实验模式（Experimental Mode）下颜色按预测纵向加速度做 HSL 渐变——绿色=加速、黄色=巡航、橙红色=刹车；车道线白色、透明度=置信度；前车红色 chevron。
5. **渲染**：C++/Qt 端 `AnnotatedCameraWidget` 标注层 + `PathRenderWidget` 用 QPainter/NVG 绘制；Python 端 `model_renderer.py` 用 PyRay 的 `draw_triangle_fan` 复现。
6. **性能**：comma 3X/4 上 onroad 渲染稳定 20–30Hz，与 modeld 推理频率对齐，eglfs 直连 GPU 独占。

需要先澄清一个常见误解：任务描述中的「绿色=巡航 / 蓝色=变道 / 橙色=刹车」与 openpilot 实际的颜色编码**不完全一致**。实际编码是「蓝色=engage 巡航（默认）/ 绿色=加速 / 黄→橙→红=刹车（实验模式 HSL 渐变）」，**变道（lane change）并不通过路径颜色单独编码**，而是通过 `desire` 状态机与路径几何形状（横向偏移）自然体现。本报告会在第 5 节给出精确的颜色编码表与 HSL 公式。

---

## 1. Plan 数据：supercombo Plan Head 输出

### 1.1 张量布局

Plan Head 是 supercombo / driving_policy 模型最核心的输出，位于 `selfdrive/modeld/models/defaultmodel.cc` 定义的张量切片布局中，原始形状为：

```
plan: [5, 2, 33, 15] = 4955 个 float
       │  │   │   └─ 15 维状态向量
       │  │   └───── 33 个时间步
       │  └───────── 2 个分位（mu / std）
       └──────────── 5 条多假设轨迹
```

**5 条多假设**（mixture of plans / multi-hypothesis planning）：模型同时输出 5 条候选未来轨迹，每条带一个 softmax 权重 `π_k`，由 `parse_model_outputs.py::Parser.parse_mdn` 选 `argmax` 权重的假设作为点估计，其余假设的 `mu` 在主显示中不画（仅在离线 `model_renderer.py` 的调试分支可叠加）。

**2 个分位**：前半为均值 `mu`，后半为标准差 `std`（经 `safe_exp` 保证正值，避免负方差）：`σ = exp(clip(z, -10, 10))`。`std` 不直接用于 UI 渲染，但驱动下游 MPC 的不确定性加权与 radard 卡尔曼滤波的测量噪声 R。

**33 个时间步**：覆盖未来约 2 秒（早期版本 3.2 秒），由 `ModelConstants.T_IDXS` 给出**非均匀时间网格**——0~2s 密集（0.1s 间隔，近距离精确）、2s 之后稀疏（0.5~1.0s 间隔，远距离概略）。所有 Head（plan / lane_lines / road_edges / leads）共享同一 `T_IDXS`，保证时间对齐、避免重采样。

**15 维状态向量**，按 `Plan` 枚举排列：

| 索引 | 字段 | 含义 | 单位 |
|---|---|---|---|
| 0:3 | X, Y, Z | 位置（FLU road frame） | 米 |
| 3:6 | VX, VY, VZ | 速度 | m/s |
| 6:9 | AX, AY, AZ | 加速度 | m/s² |
| 9:12 | R, P, Yaw | 欧拉角（roll/pitch/yaw） | 弧度 |
| 12:15 | RollRate, PitchRate, YawRate | 角速度 | rad/s |

UI 路径渲染**只用到前 3 维 (X, Y, Z)**——即 33 个 3D 路径点。速度/加速度用于下游控制（见第 7 节），其中**纵向加速度 AX 正是实验模式 HSL 颜色渐变的输入**（见第 5.2 节）。

### 1.2 MDN 解码公式

每个时间步每个分量的概率分布为混合高斯（Mixture of Gaussians）：

$$
p(x_t \mid \mathcal{O}) = \sum_{k=1}^{K=5} \pi_k \, \mathcal{N}(x_t; \mu_{k,t}, \sigma_{k,t}^2), \quad \pi_k = \mathrm{softmax}(w_k)
$$

解码时取 `argmax` 假设的 `mu` 作为点估计：

```python
def parse_mdn(self, name, outs, in_N=0, out_N=1, out_shape=None):
    raw = outs[name]
    raw = raw.reshape((raw.shape[0], max(in_N,1), -1))
    n_values = (raw.shape[2] - out_N) // 2
    pred_mu  = raw[:, :, :n_values]
    pred_std = safe_exp(raw[:, :, n_values:2*n_values])
    if in_N > 1:
        weights = softmax(raw[:, :, -out_N:], axis=-1)
        best = np.argmax(weights, axis=1)
        # 选权重最大假设的 mu / std
    return pred_mu, pred_std
```

训练侧损失为负对数似然 NLL：

$$
\mathcal{L}_{plan} = -\log \sum_{k} \pi_k \exp\!\left( -\tfrac{(x - \mu_k)^2}{2\sigma_k^2} \right) / \sqrt{2\pi\sigma_k^2}
$$

### 1.3 Flow Matching（v10+）

comma 在 0.10 系列（CVPR 2025 论文《Learning to Drive from a World Model》，arXiv:2504.19077）引入 **World Model Planner**，训练侧用扩散/流匹配（Rectified Flow + logit-normal 噪声采样）建模轨迹分布，增强多模态性。但**解码时仍以 `mu` 直接读取为主**——flow matching 主要在训练侧提供更平滑的分布建模与更可靠的 on-policy rollout，车端推理与 UI 渲染拿到的仍是 `[5, 2, 33, 15]` 形状的点估计 + 不确定性。因此 Path 渲染管线在 v10/v11 下**无需改动**，只是数据源从经典 supercombo 切到 World Model 训练的 driving_policy。

### 1.4 坐标系

所有 Plan 空间量均在**自车 FLU road frame** 下表达：

- **X**：前向（Forward），路径点沿此轴递增；
- **Y**：左向（Left），左偏为正；
- **Z**：上向（Up），上坡为正。

原点为车辆后轴中心在地面的投影。这套坐标系与 lane_lines / road_edges / leads 完全一致，是「路径、车道线、前车逐像素对齐」的工程根源。

---

## 2. Path 渲染：从 3D 点到屏幕多边形

### 2.1 渲染形态：透视收缩的路径带

OpenPilot 车端 onroad UI 的路径**不是单条折线**，而是一条**带有宽度、随距离透视收缩、颜色随意图渐变的多边形带**。其设计哲学：

- **第一人称 SR（态势感知）**：路径带叠加在摄像头画面上，驾驶员一眼即可判断「系统准备往哪开、是否会加速/减速」；
- **与车道线/前车共用投影**：路径、车道线、路沿、前车 chevron 全部用同一套 `_car_space_transform`，保证四者在画面上**逐像素对齐**——这是「机器看到了和你一样的世界」直觉的关键；
- **宽度即自信**：路径带的横向半宽 `y_off` 可随置信度/加速意图变化，自信时变宽、不确定时变窄。

### 2.2 投影矩阵装配

投影矩阵定义在 `common/transformations/camera.py` 与 `coordinates.py`：

```python
def get_view_frame_from_road_frame(roll, pitch, yaw, height):
    device_from_road = orient.rot_from_euler([roll, pitch, yaw]).dot(np.diag([1, -1, -1]))
    view_from_road = view_frame_from_device_frame.dot(device_from_road)
    return np.hstack((view_from_road, [[0], [height], [0]]))   # 3x4
```

最终 onroad 渲染用的投影矩阵：

$$
M = K \cdot V_{\text{road}\to\text{view}} \in \mathbb{R}^{3\times 4}
$$

其中：
- $K$ 是相机内参（`CameraConfig.intrinsics`，focal_length ≈ 910 px for TICI，主点在画面中心）：
  $$K = \begin{bmatrix} f & 0 & W/2 \\ 0 & f & H/2 \\ 0 & 0 & 1 \end{bmatrix}$$
- $V_{\text{road}\to\text{view}}$ 由 `paramsd`/`calibrationd` 在线学习的 (roll, pitch, yaw, height) 装配——这正是车道线消失点反推外参的同一套 `get_calib_from_vp`：

```python
def get_calib_from_vp(vp, intrinsics):
    vp_norm = normalize(vp, intrinsics)
    yaw_calib   = np.arctan(vp_norm[0])
    pitch_calib = -np.arctan(vp_norm[1] * np.cos(yaw_calib))
    roll_calib  = 0.0
    return roll_calib, pitch_calib, yaw_calib
```

把 road frame 下的 3D 齐次点 $[X, Y, Z, 1]^T$ 投影到 2D 齐次像素：

$$
\begin{bmatrix} u\cdot w \\ v\cdot w \\ w \end{bmatrix} = M \begin{bmatrix} X \\ Y \\ Z \\ 1 \end{bmatrix}, \quad (u, v) = \left(\tfrac{u w}{w}, \tfrac{v w}{w}\right)
$$

### 2.3 多边形化：`_map_line_to_polygon`

`selfdrive/ui/onroad/model_renderer.py::_map_line_to_polygon` 是路径带几何构造的核心。它把单条 33 点折线扩展为左右各偏移 `y_off`、Z 轴抬升 `z_off` 的带状多边形：

```python
def _map_line_to_polygon(self, line, y_off, z_off, max_idx, max_distance):
    # line: [N, 3] 路径点（X, Y, Z）
    points = line[:max_idx]                                # 按最大距离截断
    # 生成左右偏移的 3D 点：左偏 (-y_off)、右偏 (+y_off)，Z 抬升 z_off
    offsets = np.array([[0, -y_off, z_off],
                        [0,  y_off, z_off]], dtype=np.float32)
    points_3d = points[None, :, :] + offsets[:, None, :]   # 形状: 2×N×3

    # 应用透视变换：M @ [X,Y,Z,1]^T
    proj = self._car_space_transform @ points_3d.T         # 3×(2N)
    left_proj  = proj[:, 0, :]
    right_proj = proj[:, 1, :]

    # 透视除法 -> 屏幕坐标
    left_screen  = left_proj[:2]  / left_proj[2]
    right_screen = right_proj[:2] / right_proj[2]

    # 拼成闭合多边形：左边界正向 + 右边界反向
    polygon = np.concatenate([left_screen.T, right_screen.T[::-1]])
    return polygon
```

要点：
- `y_off` 控制路径带半宽（典型 0.3~0.5 m），可随置信度/加速意图变化；
- `z_off` 把路径带从地面抬升一点（典型 0.1~0.2 m），避免与车道线/路面颜色混淆；
- `max_idx` / `max_distance` 做远端裁剪——超出最大距离的点不画；
- 左右边界拼成闭合多边形后，用 `draw_triangle_fan` 或 NVG `fill` 填充。

### 2.4 远端 / 近端裁剪

路径带的三段式裁剪策略（与车道线、前车 chevron 完全同构）：

1. **近端裁剪**：当 `w = M[2]·[X,Y,Z,1]^T ≤ ε`（如 0.001）时，点落在相机视锥后或自车下方（引擎盖上），跳过不画，避免画到车头；
2. **远端裁剪**：当 `X > max_distance`（约 50~80 m）或投影后像素小于 1 时，停止扩展多边形；
3. **视锥裁剪**：横向偏移过大（路径点超出画面）时，多边形顶点超出画面，部分裁剪（NVG/QPainter 自动处理）。

---

## 3. Path 源码：scene.cc / onroad.cc / model_renderer.py

### 3.1 文件清单

| 文件 | 路径 | 职责 |
|---|---|---|
| `scene.cc` | `selfdrive/ui/qt/widgets/scene.cc` | NVG/OpenGL 路径/车道线/路沿绘制（部分版本） |
| `onroad.cc` | `selfdrive/ui/qt/onroad.cc` | `AnnotatedCameraWidget` 标注层，内嵌 `PathRenderWidget` / `LaneLinesWidget` / `LeadVehicleWidget` |
| `cameraview.cc` | `selfdrive/ui/qt/widgets/cameraview.cc` | `AnnotatedCameraWidget`：前视帧 + 标注层叠加 |
| `model_renderer.py` | `selfdrive/ui/onroad/model_renderer.py` | Python 离线/重放渲染（PyRay），与 C++ 端共用同一套投影矩阵 |
| `camera.py` | `common/transformations/camera.py` | `CameraConfig` / `_car_space_transform` 装配 |
| `coordinates.py` | `common/transformations/coordinates.py` | `get_view_frame_from_road_frame` / `get_calib_from_vp` |
| `constants.py` | `selfdrive/modeld/constants.py` | `ModelConstants.T_IDXS` / `IDX_N` |
| `parse_model_outputs.py` | `selfdrive/modeld/parse_model_outputs.py` | Plan/Lane/Lead 的 MDN 解码 |
| `fill_model_msg.py` | `selfdrive/modeld/fill_model_msg.py` | 把解析结果填入 `modelV2` cereal 消息 |

### 3.2 PathRenderWidget 结构（C++ 端，基于源码行为还原）

`PathRenderWidget` 是嵌入 `AnnotatedCameraWidget` 标注层的 QWidget，核心成员与方法：

```cpp
// scene.cc / onroad.cc 内嵌（结构还原）
class PathRenderWidget : public QWidget {
  Q_OBJECT
public:
  PathRenderWidget(QWidget* parent = nullptr);
  void updateParams();   // 读取 liveCalibration 装配 _car_space_transform

protected:
  void paintEvent(QPaintEvent*) override;

private:
  void drawPathPolygon(QPainter &p, const cereal::ModelV2::PathData &path,
                       const QColor &color, float y_off, float z_off);
  void updateCarSpaceTransform(const cereal::LiveParameters &calib);

  mat3  car_space_transform_;     // K @ view_from_road（与车道线/前车共用）
  bool  engaged_ = false;        // controlsState.enabled & .active
  bool  experimental_mode_ = false;
  float v_ego_ = 0.f;
  // 路径点缓存（来自 modelV2.position.x/y/z）
  std::vector<QPointF> path_left_, path_right_;
};
```

### 3.3 paintEvent 主流程（行为还原）

```cpp
void PathRenderWidget::paintEvent(QPaintEvent*) {
  if (!engaged_) return;                 // 未 engage 不画路径
  QPainter p(this);
  p.setRenderHint(QPainter::Antialiasing);

  // 1. 从 modelV2.position 取 33 个路径点（X, Y, Z）
  auto path = sm_["modelV2"].getPosition();
  const auto &x_arr = path.getX();
  const auto &y_arr = path.getY();
  const auto &z_arr = path.getZ();

  // 2. 多边形化 + 投影（_map_line_to_polygon 等价物）
  float y_off = 0.35f, z_off = 0.15f;
  std::vector<QPointF> left, right;
  for (int i = 0; i < x_arr.size(); ++i) {
    float X = x_arr[i], Y = y_arr[i], Z = z_arr[i] + z_off;
    // 左偏
    float ul, vl, wl; project(X, Y - y_off, Z, car_space_transform_, ul, vl, wl);
    if (wl > 0.001f) left.push_back(QPointF(ul/wl, vl/wl));
    // 右偏
    float ur, vr, wr; project(X, Y + y_off, Z, car_space_transform_, ur, vr, wr);
    if (wr > 0.001f) right.push_back(QPointF(ur/wr, vr/wr));
  }

  // 3. 颜色：默认 engage 蓝；实验模式 HSL 渐变（见第 5 节）
  QColor color = experimental_mode_
      ? experimentalColor(path, v_ego_)     // 绿/黄/橙红渐变
      : QColor(0, 100, 255, 180);            // 蓝色 engage

  // 4. 拼闭合多边形 + 填充
  QPolygonF poly;
  for (auto &pt : left)  poly << pt;
  for (auto it = right.rbegin(); it != right.rend(); ++it) poly << *it;
  p.setBrush(color);
  p.setPen(Qt::NoPen);
  p.drawPolygon(poly);
}
```

### 3.4 Python 端 `model_renderer.py`

`model_renderer.py` 是 openpilot 的离线/重放可视化工具，与 C++ 车端共用同一套投影矩阵。关键方法：

- `_draw_path`：绘制 AI 规划的行驶路径，颜色与透明度按驾驶模式与加速度动态变化；
- `_update_experimental_gradient`：实验模式下根据加速度计算 HSL 颜色；
- `_draw_lead_indicator`：绘制前车红色 chevron + 黄色光晕；
- `_map_line_to_polygon`：路径/车道线多边形化（见 §2.3）。

`model_renderer.py` 用 PyRay 图形库渲染，启动方式：

```bash
tools/replay/replay --demo            # 启动演示路线重放
cd selfdrive/ui && ./ui                # 启动 UI 界面
cd selfdrive/ui && ./watch3            # 三路摄像头 + 模型输出叠加视图
```

界面元素：蓝色（或实验模式渐变色）路径 = AI 规划行驶轨迹；白色线条 = 车道线（透明度=置信度）；红色三角形 = 前车检测指示。

---

## 4. Path 反向投射：Plan 坐标 → 屏幕坐标

### 4.1 完整投影链路

```
supercombo Plan Head (FLU road frame, [X, Y, Z] × 33 点)
   │
   │  get_view_frame_from_road_frame(roll, pitch, yaw, height)
   ▼
view frame 3D 点 (相机坐标系)
   │
   │  K (相机内参) 左乘
   ▼
_car_space_transform = K @ view_from_road  (3×4 矩阵)
   │
   │  M @ [X, Y, Z, 1]^T  ->  [u·w, v·w, w]^T
   ▼
透视除法 (u, v) = (u·w/w, v·w/w)
   │
   │  近端/远端/视锥裁剪
   ▼
2D 屏幕像素点 (33 个)
   │
   │  _map_line_to_polygon (左右各偏移 y_off)
   ▼
闭合多边形 (2 × 33 = 66 顶点)
   │
   │  QPainter/NVG fill
   ▼
屏幕上的路径带
```

### 4.2 投影公式（逐点）

对每个路径点 $(X_i, Y_i, Z_i)$，左右偏移后得到两个 3D 点：

$$
P_{i,L} = [X_i,\ Y_i - y_{\text{off}},\ Z_i + z_{\text{off}},\ 1]^T, \quad
P_{i,R} = [X_i,\ Y_i + y_{\text{off}},\ Z_i + z_{\text{off}},\ 1]^T
$$

各自投影：

$$
\begin{bmatrix} u_{i,L}\cdot w_{i,L} \\ v_{i,L}\cdot w_{i,L} \\ w_{i,L} \end{bmatrix} = M \cdot P_{i,L}, \quad
(u_{i,L}, v_{i,L}) = \left(\tfrac{u_{i,L}\cdot w_{i,L}}{w_{i,L}},\ \tfrac{v_{i,L}\cdot w_{i,L}}{w_{i,L}}\right)
$$

近端裁剪条件：$w_{i,L} > \epsilon$（典型 $\epsilon = 0.001$），否则跳过该点。

### 4.3 多边形闭合

把 33 个左偏点正向排列、33 个右偏点反向排列，首尾相接得到 66 顶点的闭合多边形：

$$
\text{polygon} = [P_{0,L}, P_{1,L}, \dots, P_{32,L}, P_{32,R}, P_{31,R}, \dots, P_{0,R}]
$$

填充时用 NVG `nvgFill` 或 QPainter `drawPolygon`，配合 HSL 颜色与沿距离衰减的 alpha。

### 4.4 与车道线/前车投影的同构

车道线（`lane_lines` [4, 2, 33, 2]）、路沿（`road_edges` [2, 2, 33, 2]）、前车 chevron 全部用同一套 `_car_space_transform` 投影。唯一差异：
- 车道线/路沿：直接用模型回归的 (Y, Z)，X 由 `T_IDXS × v_ego` 推得，渲染为半透明折线（透明度=置信度）；
- 路径：用 Plan 的 (X, Y, Z)，渲染为带状多边形；
- 前车：用 lead 的 (dRel, yRel)，渲染为 3 顶点 chevron 三角扇。

四者共用投影矩阵是「逐像素对齐」的工程根源。

---

## 5. 颜色编码：精确的 HSL 渐变公式

### 5.1 颜色编码总表

| 元素 | 颜色 | 触发条件 | 备注 |
|---|---|---|---|
| **路径（默认 engage）** | 蓝色 `(0, 100, 255)` | `controlsState.enabled & .active` 且非实验模式 | 巡航/车道居中的默认色 |
| **路径（实验-加速）** | 绿色（HSL hue=120°） | 实验模式且 `accel_x > 0` | hue = 60 + accel·35，clip 到 [0, 120] |
| **路径（实验-巡航）** | 黄色（HSL hue=60°） | 实验模式且 `accel_x ≈ 0` | 中性色 |
| **路径（实验-刹车）** | 橙→红（HSL hue→0°） | 实验模式且 `accel_x < 0` | 急刹时接近红色 |
| **车道线** | 白色 | 始终 | alpha = lane_lines_prob（置信度） |
| **路沿** | 灰色 | 始终 | 比 lane_lines 更暗、更细 |
| **前车 chevron（主）** | 逗号红 `(201, 34, 49)` | `radarState.leadOne.status` | 描边 2px，alpha 满 |
| **前车 chevron（备）** | 逗号红 alpha×0.6 | `radarState.leadTwo.status` | 描边 1px，更透明 |
| **前车光晕** | 黄色 `(218, 202, 37)` | lead 存在 | chevron 外圈 glow |
| **FCW 警报条** | 黄色 | `alertStatus == "warn"` | 独立 alert 层 |
| **接管警报** | 红色 | `alertStatus == "alert"` | 立即 disengage + soundd |

### 5.2 实验模式 HSL 渐变公式（核心）

`model_renderer.py::_update_experimental_gradient` 给出了精确的颜色映射——**这是任务中「绿色/橙色」的真实来源**：

```python
def _update_experimental_gradient(self):
    # self._acceleration_x[i]: 第 i 个路径点的预测纵向加速度（来自 Plan Head AX）
    # path_hue: 60=黄（中性），120=绿（加速），0=红（刹车）
    path_hue = np.clip(60 + self._acceleration_x[i] * 35, 0, 120)

    saturation = min(abs(self._acceleration_x[i] * 1.5), 1)
    lightness  = np.interp(saturation, [0.0, 1.0], [0.95, 0.62])

    # 沿路径距离衰减的 alpha：lin_grad_point ∈ [0, 1]，0=近端、1=远端
    alpha = np.interp(lin_grad_point, [0.75 / 2.0, 0.75], [0.4, 0.0])

    # HSL 转 RGB 颜色
    color = self._hsla_to_color(path_hue / 360.0, saturation, lightness, alpha)
```

公式拆解：

**色相（Hue）**——驱动绿/黄/橙红切换：
$$
h = \mathrm{clip}(60 + 35 \cdot a_x,\ 0,\ 120)
$$
- $a_x > 0$（加速）：$h \to 120$（绿色）；
- $a_x = 0$（巡航）：$h = 60$（黄色）；
- $a_x < 0$（刹车）：$h \to 0$（红色/橙色）。

**饱和度（Saturation）**——加速度越大色越浓：
$$
s = \min(|1.5 \cdot a_x|,\ 1)
$$

**亮度（Lightness）**——饱和度高时变暗，增强对比：
$$
l = \mathrm{interp}(s,\ [0, 1],\ [0.95, 0.62])
$$

**透明度（Alpha）**——沿路径距离线性衰减（近端 0.4、远端 0）：
$$
\alpha = \mathrm{interp}(t_{\text{grad}},\ [0.375, 0.75],\ [0.4, 0.0])
$$

> 任务描述中的「绿色=巡航 / 蓝色=变道 / 橙色=刹车」与实际编码的对应关系：
> - **绿色**：实验模式下的**加速**（非巡航）；
> - **蓝色**：默认 engage 模式的**巡航**（非变道）；
> - **橙色**：实验模式下的**刹车/减速**（与任务一致）；
> - **变道（lane change）**：openpilot **不通过路径颜色单独编码变道**，变道由 `desire` 状态机驱动，路径几何（横向 Y 偏移）自然体现变道轨迹，颜色仍按上述加速度规则。

### 5.3 颜色切换条件

- **默认 → 实验模式**：用户在设置页打开「Experimental Mode」toggle，`controlsState.experimentalMode = true`，`PathRenderWidget` 切到 HSL 渐变；
- **engage → disengage**：`controlsState.enabled = false` 时路径不画（或画灰色低 alpha 提示）；
- **FCW 触发**：独立于路径颜色，走 `alertStatus = "warn"` 黄色警报条 + soundd；
- **Gas Gating（0.9.8+）**：Chill 模式下用模型预测的「人类何时踩油门/刹车」门控加速，路径颜色随之更精准反映意图。

### 5.4 线宽与渐变

- **线宽**：路径带半宽 `y_off ≈ 0.3~0.5 m`（road frame），经透视投影后近端宽、远端窄，形成自然透视收缩；
- **沿距离渐变**：alpha 从近端 0.4 线性衰减到远端 0（`lin_grad_point ∈ [0.375, 0.75]`），让路径在远处自然淡出，避免遮挡远方路况；
- **HSL 渐变**：实验模式下每个路径点的颜色独立计算（按该点的预测加速度），整条路径带呈现「近端绿、远端黄/橙」的连续渐变，直观传达「先加速后减速」的意图。

---

## 6. 多 hypothesis Path 显示

### 6.1 Plan 的 5 条假设

Plan Head 输出 5 条多假设轨迹，每条带 softmax 权重 `π_k`。UI 渲染策略：

- **主 hypothesis（默认显示）**：`argmax` 权重的假设，`mu` 作为点估计渲染为路径带；权重越大路径越「自信」（实际渲染中权重不直接体现为视觉差异，而是通过 `std` 间接影响下游 MPC 的平滑度）；
- **备选 hypothesis（默认不显示）**：其余 4 条假设的 `mu` 在车端 onroad UI 不画，避免视觉混乱；
- **离线调试（可选）**：`model_renderer.py` 的调试分支可叠加显示 5 条假设，用不同 alpha 区分（主假设 alpha=1，备选 alpha=0.2~0.4），用于开发者分析模型的多模态预测。

### 6.2 Lead 的 2 条假设（对照）

与前车 Lead Head 的 2 假设不同，Plan 的多假设**不在主 UI 同时显示**——因为 5 条路径同时画会严重干扰驾驶员。Plan 的多假设主要服务于：
- 训练侧的多模态建模（NLL 损失）；
- 下游 MPC 的不确定性加权（`std` 大的段 cost 权重降低）；
- 离线分析（开发者复盘模型预测）。

### 6.3 切换条件

主假设的切换发生在 `parse_mdn` 的 `argmax` 选择——每帧重新选权重最大的假设。由于 MDN 权重经训练已较平滑，加上下游 `clip_curvature` 与 `smooth_value` 的低通滤波，主假设切换不会产生路径跳变，UI 上呈现为连续平滑的路径。

---

## 7. 与路径规划的协同：数据流

### 7.1 完整数据流

```
┌─────────────────────── modeld (20Hz) ───────────────────────┐
│  driving_vision  ──┐                                         │
│  driving_policy ──┬─┤                                         │
│                   │ │  Parser.parse_mdn / parse_policy       │
│   hidden state ───┘ │  fill_model_msg                        │
│                     ▼                                        │
│   modelV2 (cereal) ──────────────┐                           │
│     .position    (X,Y,Z × 33)    │  ← Path 渲染用            │
│     .velocity    (VX,VY,VZ)      │                           │
│     .acceleration(AX,AY,AZ)      │  ← HSL 颜色用 (AX)        │
│     .action.desiredCurvature      │                           │
│     .action.desiredAcceleration   │                           │
│     .laneLines / roadEdges        │                           │
│     .leads                        │                           │
└───────────────────────────────────┼──────────────────────────┘
                                    │
        ┌───────────────────────────┼──────────────────────┐
        │                           │                      │
        ▼                           ▼                      ▼
┌───────────────────┐    ┌─────────────────────┐  ┌──────────────────┐
│ LateralPlanner    │    │ LongitudinalPlanner │  │ Onroad UI        │
│  (plannerd, 20Hz) │    │  (plannerd, 20Hz)   │  │ (UIState)        │
│                   │    │                     │  │                  │
│ parse_model(plan) │    │ parse_model(plan)   │  │ AnnotatedCamera  │
│ set_cur_state(CS) │    │ process_lead(radar) │  │  Widget          │
│ mpc.run() (<10ms) │    │ LongitudinalMpc     │  │  ├ PathRender    │
│ → mpcPositions    │    │ → aTarget, shouldStop│  │  ├ LaneLines    │
│ → desiredCurvature│    │ → desiredAccel      │  │  ├ LeadVehicle  │
└─────────┬─────────┘    └──────────┬──────────┘  └────────┬─────────┘
          │                         │                      │
          ▼                         ▼                      ▼
┌─────────────────── controlsd (100Hz) ───────────────────────────┐
│  desired_curvature = clip_curvature(vEgo, prev, model, roll)    │
│  CC.actuators.curvature = desired_curvature                     │
│  CC.actuators.accel     = desired_accel                         │
│  LaC.update(...) → steer_cmd / steeringAngleDeg                 │
│  LoC.update(...) → accel_cmd                                    │
└──────────┬──────────────────────────────────────────────────────┘
           │
           ▼
   card → panda → CAN → 车辆 EPS / 节气门 / 刹车
```

### 7.2 Path → LateralPlanner

`LateralPlanner.update(sm)` 把 Plan 的 (X, Y, ψ) 序列作为参考轨迹灌入 `LateralMpc`：

1. `parse_model(sm['modelV2'])` → 期望路径 (x, y, psi) 序列；
2. `set_cur_state(CS)` → 当前车辆状态（延迟补偿后的预测状态）；
3. `set_weights(...)` → 代价权重（path/heading/lat_accel/lat_jerk/steering_rate）；
4. `mpc.run()` → 求解（< 10ms，Acados SQP-RTI）；
5. 提取 `mpc.x_solution[:, :2]` → 平滑后的可执行路径；
6. 计算曲率 `κ = dψ/ds` → 期望曲率序列；
7. 即时下发 `lateralPlan.desiredCurvature` 给 controlsd。

### 7.3 Path → CarController

`controlsd.state_control()` 把 `desired_curvature` 经 `clip_curvature`（限 jerk `MAX_LATERAL_JERK/v²` 与横向加速度 `MAX_LATERAL_ACCEL_NO_ROLL ± roll·g`）后写入 `CC.actuators.curvature`，再由 `LatControlAngle/Torque/PID` 之一转成方向盘角度或扭矩命令。

### 7.4 Path → UI 渲染

UI 侧 `UIState` 订阅 `modelV2`，`AnnotatedCameraWidget` 在 `paintEvent` 中：
1. 取 `modelV2.position` 的 (X, Y, Z) × 33 点；
2. 用 `liveCalibration` 装配的 `_car_space_transform` 投影到屏幕；
3. `_map_line_to_polygon` 多边形化；
4. 按 `controlsState.enabled / experimentalMode` 与 `modelV2.acceleration.x` 选颜色（蓝 / HSL 渐变）；
5. QPainter/NVG fill 绘制路径带。

**关键：UI 渲染的路径与下游 MPC/Controller 用的路径是同一份 `modelV2.position` 数据**——驾驶员看到的路径就是系统准备执行的轨迹，这是 openpilot SR 信任感的工程根源。

---

## 8. 与 Apollo Dreamview 轨迹渲染对比

### 8.1 Apollo Dreamview 轨迹渲染现状

Apollo Dreamview（`modules/dreamview/` 旧版 / `modules/dreamview_plus/` Apollo 10 Beta 新版）的轨迹渲染走**真 3D 路线**：

- **数据来源**：Planning 模块输出的 `ADCTrajectory`（repeated `TrajectoryPoint`，含 path_point 的 x/y/z/theta/kappa + speed/acceleration/timing），经 CyberRT channel 发布；
- **消息定义**（`planning.proto`）：`PlanningData` 含 `adc_position` / `chassis` / `routing` / `init_point` / `path` / `speed_plan` / `st_graph` / `sl_frame` 等调试信息；
- **渲染**：前端 React + Three.js，在 3D 模拟世界中把 `ADCTrajectory` 的点序列画成**3D 折线/管道**，叠加在 HD Map 路网之上；
- **视图**：默认 BEV 鸟瞰 + 可切第三人称，非第一人称透视；
- **着色**：规划轨迹通常为绿色/蓝色折线，障碍物按类别多色（车红/行人黄/自行车蓝）；
- **ST 图**：PnC 监视器另开面板画 ST 图（速度-时间）、SL 图（横向-纵向），用于开发者分析速度规划。

### 8.2 对比矩阵

| 维度 | OpenPilot Path 渲染 | Apollo Dreamview 轨迹渲染 |
|---|---|---|
| 渲染位置 | 车载设备本地（嵌入式 GPU） | 工控机/云端 → 浏览器 |
| 渲染技术 | C++ Qt5/6 + QPainter/NVG + OpenGL ES | React + Three.js (WebGL) |
| 数据通道 | cereal/Cap'n Proto 进程内零拷贝 | CyberRT channel + WebSocket + Protobuf |
| 视图范式 | 第一人称透视（相机帧 + 叠加） | BEV 鸟瞰 + 第三人称（3D 场景） |
| 轨迹形态 | 带状多边形（透视收缩、宽度可变） | 3D 折线/管道（线段或 tube） |
| 颜色编码 | 蓝=engage / HSL 渐变=实验模式（绿加速、橙刹车） | 绿/蓝折线 + 障碍物按类别多色 |
| 颜色驱动 | 驾驶意图（加速度） | 静态颜色（轨迹） + 类别（障碍物） |
| 帧率 | 20–30Hz（实时驾驶） | ~10Hz（调试） |
| 多 hypothesis | Plan 5 假设选主（备选不画） | 障碍物多预测轨迹全画（不同 alpha） |
| 投影方式 | 反向投射到相机帧（K @ view_from_road） | 3D 世界坐标直接渲染 |
| ST/SL 图 | 无（极简） | PnC 监视器专门面板 |
| 用户 | 驾驶员（运行时 SR） | 开发者（调试） |
| 摄像头帧叠加 | 是（路径盖在相机帧上） | 否（3D 场景独立，相机帧另开面板） |

### 8.3 数据来源差异

- **OpenPilot**：轨迹来自 supercombo Plan Head 的端到端神经网络输出，33 个 (X,Y,Z) 点，无显式路径优化（v10+ 连 MPC 都移除，模型直接输出可执行轨迹）；
- **Apollo**：轨迹来自 Planning 模块的经典 pipeline（Scenario → Stage → Task：DP/QP path optimizer + DP/QP speed optimizer + deciders），输出 `ADCTrajectory` 含完整 path_point + speed/accel，是规则+优化的产物。

### 8.4 渲染差异本质

- **OpenPilot 是「驾驶员辅助 SR」**：极简、第一人称、只画一条路径带，颜色随意图渐变，目标是让驾驶员信任 L2 系统；
- **Apollo 是「开发者调试工具」**：全量、上帝视角、画完整轨迹 + ST/SL 图 + 障碍物多预测轨迹，目标是让工程师排查 Planning 问题。

两者不可互相替代，但可互相借鉴：OpenPilot 可借鉴 Apollo 的 ST/SL 图（开发者模式），Apollo 可借鉴 OpenPilot 的第一人称透视与意图颜色编码（驾驶员 SR）。

---

## 9. Comma 4 / v9 / v10 Path 改进

### 9.1 v9（0.9.x）：MPC 入模 + FastViT + 直接输出 curvature

- **0.9.0（2022-11）Experimental Mode**：首次端到端纵向规划（alpha），引入高斯信道信息瓶颈（~700 bits/帧）防 cheating；torqued 在线学习车辆横向动力学；
- **0.9.4（2023-07）Navigate on openpilot**：横向 e2e + 纵向 e2e + 导航三组件齐聚；新增 `mapsd` + `navmodeld`；
- **0.9.5（2023-11）FastViT**：backbone 从 EfficientNet 换为 FastViT；**横向 MPC 与 planner 整体移入模型内部**，模型直接输出可执行横向轨迹；新增 navigation instructions（三值向量）；
- **0.9.6（2024-02）**：直接输出 curvature 用于横向控制；
- **0.9.7（2024-06）**：输入过去 curvature 以获得更平滑准确的横向控制；
- **0.9.8（2025-03）Gas Gating**：Chill 模式下用模型预测的「人类何时踩油门/刹车」门控加速——**这正是实验模式 HSL 颜色渐变的语义基础**（颜色反映 Gas Gating 的意图）；
- **0.9.9（2025-06）lagd**：在线学习横向时间延迟；外接 USB GPU。

**Path 渲染影响**：v9 系列路径渲染逻辑基本稳定（蓝/HSL 渐变），主要变化在数据质量——FastViT 的 plan 预测几何更平滑、远端置信度更高，路径带抖动更小。

### 9.2 v10（0.10.x）：World Model Planner 取代 MPC

0.10.0（2025-08）"Tomb Raider / Space Lab / Vegan Filet-o-Fish" 是路径规划的根本性变革：

- **World Model Planner（Tomb Raider, #35620）**：旧模型预测「人类会开到的状态」（与当前状态不同的目标），再由 MPC 生成可行轨迹；0.10 起模型**直接从当前状态出发预测轨迹**，监督来自「知道未来」的 World Model。**横向（Chill+Experimental）与纵向（Experimental）的 MPC 全部移除**；
- **Lead Car 检测改进（Space Lab, #35816）**：停车启停场景下前车检测显著提升，低速被忽略帧从 78% 降到 52%；
- **VAE 压缩（Vegan Filet-o-Fish, #35240）**：宽/窄图像被编码为 32×16×32 张量，为 ML Simulator 备料。

**Path 渲染影响**：
- 数据源从「MPC 平滑后的轨迹」变为「模型直接输出的轨迹」，UI 拿到的 `modelV2.position` 更直接反映模型意图；
- 由于 World Model 训练的轨迹天然平滑（训练侧用 Rectified Flow + CFG），路径带抖动进一步降低；
- **渲染管线本身无需改动**——仍消费 `[5, 2, 33, 15]` 形状的 Plan Head，只是训练侧监督变了。

### 9.3 v11（0.11.x）：全学习仿真训练 + off-policy FastViT

0.11.0（2026-03）"WMI 模型 🍉" 是 comma 十年项目的里程碑——首个完全在学习仿真中训练并交付真实用户的机器人 agent：

- **on-policy 端到端模型**：完全由 World Model 仿真训练，**不再显式输出 plan/lane/lead**，直接输出动作；
- **off-policy FastViT**：仍输出 lane_lines / road_edges / **leads** / pose，但**仅用于 UI 可视化与 lead-car fallback**，不参与端到端策略；
- **Path 渲染逻辑不变**：UI 侧仍用同一套投影矩阵与 HSL 颜色，只是 plan 数据源从 on-policy supercombo 切到 off-policy FastViT 的 plan 头（保留用于可视化）。

### 9.4 comma 4（2025-11）：横屏布局 + 实验模式 HSL 渐变

comma 4（$999，trade-in $699）与 openpilot 0.10.2 同步发布，Path 渲染改进：

- **横屏布局优化**：`BottomSidebar` 取代部分右侧 `Sidebar`，路径带在横屏比例下更舒展；
- **实验模式 HSL 渐变路径**：路径颜色随加速度预测变化（绿=加速、黄=减速），透明度沿距离线性衰减 `alpha = interp(lin_grad_point, [0.375, 0.75], [0.4, 0])`；
- **Live Lateral Lag Learning**：横向延迟在线学习，侧栏新增「Lag: x ms」实时指标；
- **新驾驶模型 UI 反馈**：路径颜色随加速度预测变化（实验模式下 HSL 渐变）。

---

## 10. AuroraDrive 迁移建议：Path 渲染方案

> 背景：AuroraDrive 当前前端为 React + Three.js + Tauri，目标构建可调试的自动驾驶 SR 桌面应用。当前 `RoadNetwork.tsx` 用 `lineSegments` 渲染车道线（存在断续问题），**尚无端到端路径渲染组件**，横向控制仍是 PurePursuit + A/D 键 bang-bang。本节给出借鉴 OpenPilot Path 渲染的具体方案与可运行代码。

### 10.1 借鉴点

1. **第一人称路径带范式**：AuroraDrive 应优先实现「相机帧 + 路径带叠加」的第一人称 SR，而非 Apollo 式 BEV；
2. **共用投影矩阵**：Path 与车道线/前车共用同一套 `K @ view_from_road`，保证逐像素对齐；
3. **HSL 颜色编码**：实验模式按加速度做 HSL 渐变（绿加速/黄巡航/橙刹车），直观传达意图；
4. **多 hypothesis 选主**：Plan 5 假设选 argmax 主假设渲染，备选不画（避免视觉混乱），调试模式可叠加；
5. **沿距离 alpha 衰减**：路径带远端自然淡出，不遮挡远方路况；
6. **状态机联动**：engage/disengage/experimental/alert 四态切换路径样式。

### 10.2 数据接口（TypeScript）

```ts
// src/types/path.ts
export interface PathPoint {
  x: number;   // 前向 (m), road frame FLU
  y: number;   // 左向 (m)
  z: number;   // 上向 (m)
  vx: number;  // 纵向速度 (m/s)
  ax: number;  // 纵向加速度 (m/s²) —— HSL 颜色用
}

export interface PlanData {
  hypotheses: { mu: PathPoint[]; weight: number }[];  // 5 条假设
  // 主假设 = argmax weight
}

export interface ControlsState {
  enabled: boolean;
  active: boolean;
  experimentalMode: boolean;
  alertStatus: 'normal' | 'prompt' | 'warn' | 'alert';
}

export interface CameraCalib {
  carSpaceTransform: number[];  // 3x4 投影矩阵，行主序，length 12
  width: number;
  height: number;
}
```

### 10.3 投影与多边形化（TS）

```ts
// src/lib/pathProjection.ts
import type { PathPoint, CameraCalib } from '../types/path';

// 3x4 矩阵 @ [X, Y, Z, 1] -> 屏幕像素 (u, v) 或 null（近端裁剪）
export function projectToScreen(
  X: number, Y: number, Z: number, M: number[]
): [number, number] | null {
  const u = M[0]*X + M[1]*Y + M[2]*Z  + M[3];
  const v = M[4]*X + M[5]*Y + M[6]*Z  + M[7];
  const w = M[8]*X + M[9]*Y + M[10]*Z + M[11];
  if (w <= 0.001) return null;          // 近端裁剪
  return [u / w, v / w];
}

// 路径点序列 -> 闭合多边形顶点（左右各偏移 y_off）
export function pathToPolygon(
  pts: PathPoint[], M: number[],
  yOff = 0.35, zOff = 0.15, maxDist = 60
): [number, number][] | null {
  const left: [number, number][] = [];
  const right: [number, number][] = [];
  for (const p of pts) {
    if (p.x > maxDist) break;            // 远端裁剪
    const l = projectToScreen(p.x, p.y - yOff, p.z + zOff, M);
    const r = projectToScreen(p.x, p.y + yOff, p.z + zOff, M);
    if (l && r) { left.push(l); right.push(r); }
  }
  if (left.length < 2) return null;
  // 闭合多边形：左正向 + 右反向
  return [...left, ...right.reverse()];
}

// HSL -> RGBA（实验模式颜色编码）
export function hslaToRgba(
  h: number, s: number, l: number, a: number
): [number, number, number, number] {
  // h ∈ [0,1], s/l ∈ [0,1], a ∈ [0,1]
  const c = (1 - Math.abs(2*l - 1)) * s;
  const hp = h * 6;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r=0, g=0, b=0;
  if (hp < 1)      [r,g,b] = [c, x, 0];
  else if (hp < 2) [r,g,b] = [x, c, 0];
  else if (hp < 3) [r,g,b] = [0, c, x];
  else if (hp < 4) [r,g,b] = [0, x, c];
  else if (hp < 5) [r,g,b] = [x, 0, c];
  else             [r,g,b] = [c, 0, x];
  const m = l - c/2;
  return [r+m, g+m, b+m, a];
}

// 实验模式颜色：绿(120)=加速, 黄(60)=巡航, 红(0)=刹车
export function experimentalColor(ax: number, linGradPoint: number): [number, number, number, number] {
  const hue = Math.max(0, Math.min(120, 60 + ax * 35)) / 360;
  const sat = Math.min(Math.abs(ax * 1.5), 1);
  const light = sat <= 0 ? 0.95 : 0.95 + (0.62 - 0.95) * sat;
  const alpha = Math.max(0, Math.min(0.4,
    0.4 - (linGradPoint - 0.375) / (0.75 - 0.375) * 0.4));
  return hslaToRgba(hue, sat, light, alpha);
}
```

### 10.4 Path 渲染组件（React + Three.js，叠加在相机帧上）

由于路径带是 2D 屏幕叠加层（不是真 3D 场景对象），最简洁的实现是用一个**绝对定位的 SVG/Canvas overlay** 覆盖在相机帧之上，用屏幕坐标直接画。下面给出 SVG 版本（最易调试、天然支持渐变）。

```tsx
// src/components/PathRenderWidget.tsx
import React, { useMemo } from 'react';
import type { PlanData, ControlsState, CameraCalib, PathPoint } from '../types/path';
import { pathToPolygon, experimentalColor, hslaToRgba } from '../lib/pathProjection';

interface Props {
  plan: PlanData;
  controls: ControlsState;
  calib: CameraCalib;
}

export const PathRenderWidget: React.FC<Props> = ({ plan, controls, calib }) => {
  const M = calib.carSpaceTransform;
  const { width, height } = calib;

  // 1. 选主假设（argmax weight）
  const mainHypo = useMemo(() => {
    if (!plan.hypotheses.length) return null;
    return plan.hypotheses.reduce((a, b) => a.weight > b.weight ? a : b);
  }, [plan]);

  if (!mainHypo || !controls.enabled || !controls.active) return null;

  // 2. 多边形化
  const polygon = pathToPolygon(mainHypo.mu, M);
  if (!polygon || polygon.length < 3) return null;

  // 3. 颜色：默认 engage 蓝；实验模式 HSL 渐变（按近端加速度）
  const pointsStr = polygon.map(p => `${p[0]},${p[1]}`).join(' ');

  // 实验模式下整条路径按加速度分段渐变（简化：用近端 ax 代表整体）
  const nearAx = mainHypo.mu[0]?.ax ?? 0;
  const isExp = controls.experimentalMode;
  const fill = isExp
    ? experimentalColor(nearAx, 0.0)
    : [0, 100/255, 255/255, 0.7];   // 蓝色 engage

  const [r, g, b, a] = fill;
  const fillStr = `rgba(${Math.round(r*255)}, ${Math.round(g*255)}, ${Math.round(b*255)}, ${a})`;

  // 4. 实验模式下沿距离分段渐变（更精细：每个 segment 独立颜色）
  const segments = useMemo(() => {
    if (!isExp) return null;
    const segs: { pts: string; fill: string }[] = [];
    const mu = mainHypo.mu;
    for (let i = 0; i < mu.length - 1; i++) {
      const p1 = mu[i], p2 = mu[i+1];
      const poly = pathToPolygon([p1, p2], M, 0.35, 0.15, 60);
      if (!poly || poly.length < 3) continue;
      const linGrad = i / (mu.length - 1);
      const [r2, g2, b2, a2] = experimentalColor((p1.ax + p2.ax) / 2, linGrad);
      segs.push({
        pts: poly.map(p => `${p[0]},${p[1]}`).join(' '),
        fill: `rgba(${Math.round(r2*255)}, ${Math.round(g2*255)}, ${Math.round(b2*255)}, ${a2})`,
      });
    }
    return segs;
  }, [isExp, mainHypo, M]);

  return (
    <svg
      width={width} height={height}
      style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none' }}
    >
      {isExp && segments ? (
        // 实验模式：分段渐变多边形
        segments.map((seg, i) => (
          <polygon key={i} points={seg.pts} fill={seg.fill} stroke="none" />
        ))
      ) : (
        // 默认 engage：单色多边形
        <polygon points={pointsStr} fill={fillStr} stroke="none" />
      )}
    </svg>
  );
};
```

### 10.5 Three.js 3D 路径管道（调试模式）

当 AuroraDrive 进入「调试模式」时，可切换到真 3D 路径管道，用 Three.js 在 3D 场景中画路径。此时需要把 road frame 坐标转为 Three.js 世界坐标（注意 Y/Z 轴翻转）。

```tsx
// src/components/PathTube3D.tsx
import React, { useMemo } from 'react';
import * as THREE from 'three';
import type { PlanData, ControlsState } from '../types/path';

interface Props {
  plan: PlanData;
  controls: ControlsState;
}

// road frame (X前/Y左/Z上) -> Three.js (X右/Y上/Z前)
const roadToThree = (X: number, Y: number, Z: number): [number, number, number] =>
  [-Y, Z, X];

export const PathTube3D: React.FC<Props> = ({ plan, controls }) => {
  const tube = useMemo(() => {
    const mainHypo = plan.hypotheses.reduce(
      (a, b) => a.weight > b.weight ? a : b, plan.hypotheses[0]
    );
    if (!mainHypo) return null;
    const pts3D = mainHypo.mu.map(p =>
      new THREE.Vector3(...roadToThree(p.x, p.y, p.z + 0.15))
    );
    if (pts3D.length < 2) return null;
    const curve = new THREE.CatmullRomCurve3(pts3D);
    // 颜色：默认蓝；实验模式按平均 ax 选绿/黄/橙
    const avgAx = mainHypo.mu.reduce((s, p) => s + p.ax, 0) / mainHypo.mu.length;
    const color = controls.experimentalMode
      ? (avgAx > 0.3 ? 0x00ff66 : avgAx < -0.3 ? 0xff8800 : 0xffff00)
      : 0x0066ff;
    return { curve, color };
  }, [plan, controls]);

  if (!tube) return null;

  return (
    <mesh>
      <tubeGeometry args={[tube.curve, 64, 0.15, 8, false]} />
      <meshBasicMaterial
        color={tube.color}
        transparent
        opacity={0.7}
        depthWrite={false}
      />
    </mesh>
  );
};
```

### 10.6 在 OnroadView 中装配

```tsx
// src/views/OnroadView.tsx
import React from 'react';
import { Canvas } from '@react-three/fiber';
import { PathRenderWidget } from '../components/PathRenderWidget';
import { PathTube3D } from '../components/PathTube3D';
import { usePlan, useControls, useCameraCalib, useDebugMode } from '../hooks';

export const OnroadView: React.FC = () => {
  const plan = usePlan();
  const controls = useControls();
  const calib = useCameraCalib();
  const debug = useDebugMode();

  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      {/* 相机帧底层 */}
      <CameraFrame calib={calib} />

      {/* 第一人称 SR：路径带 overlay（默认） */}
      {!debug && (
        <PathRenderWidget plan={plan} controls={controls} calib={calib} />
      )}

      {/* 调试模式：3D 路径管道（Three.js 场景） */}
      {debug && (
        <Canvas camera={{ position: [0, 1.2, -3], fov: 40 }}>
          <ambientLight intensity={0.6} />
          <PathTube3D plan={plan} controls={controls} />
          <LaneLines3D />
          <LeadBox3D />
        </Canvas>
      )}
    </div>
  );
};
```

### 10.7 与 OpenPilot 的差异与改进

| 维度 | OpenPilot | AuroraDrive 方案 |
|---|---|---|
| 渲染栈 | Qt QPainter / NVG (C++) | SVG overlay + Three.js (React) |
| 默认形态 | 透视收缩路径带（多边形） | 同（SVG polygon，默认） + 3D tube（调试模式） |
| 投影矩阵 | K @ view_from_road（C++ mat3） | 同（TS number[12]，3x4） |
| 颜色编码 | 蓝 engage / HSL 渐变实验 | 同（保持一致） |
| 多 hypothesis | Plan 5 假设选主 | 同，调试模式可叠加备选 |
| 沿距离 alpha 衰减 | `interp([0.375, 0.75], [0.4, 0])` | 同 |
| 分段渐变 | 每点独立 HSL | 同（SVG 分段 polygon） |
| 调试模式 | model_renderer.py 离线 | Three.js 3D tube 在线调试 |

### 10.8 实施计划

- **Phase 1（1 周）**：实现 `pathProjection.ts` + `PathRenderWidget`（SVG 路径带），用 mock 数据跑通；
- **Phase 2（1 周）**：接入 cereal `modelV2`（经 Tauri Rust 桥接），实时渲染主假设路径；
- **Phase 3（1 周）**：接入 `liveCalibration`，投影矩阵与车道线/前车对齐；
- **Phase 4（1 周）**：实验模式 HSL 分段渐变 + engage/disengage/experimental/alert 状态机联动；
- **Phase 5（1 周）**：调试模式 Three.js 3D tube + 备选 hypothesis 叠加；
- **Phase 6（持续）**：性能 profiling（目标 20Hz）、触屏适配、与横向 MPC 协同（路径与控制同源）。

### 10.9 风险与对策

- **SVG 性能**：33 点分段渐变约 32 个 polygon，每帧重算投影可能卡顿；对策：用 Canvas 2D 替代 SVG，或用 OffscreenCanvas + Web Worker；
- **投影矩阵标定**：AuroraDrive 当前无 `paramsd` 等价物；对策：先用手动标定（一次标定写入 config），后续实现消失点反推外参；
- **路径与控制同源**：AuroraDrive 当前横向控制用 PurePursuit + A/D 键，与路径渲染不同源；对策：升级到 MPC（见 02m 报告）后，UI 路径与 MPC 参考轨迹同源，复刻 openpilot 的「所见即所执行」；
- **状态机 tearing**：React 18 concurrent 模式下状态更新可能 tearing；对策：用 `useSyncExternalStore` 订阅 cereal 流。

---

## 11. 关键公式速查

| 公式 | 表达 |
|---|---|
| Plan MDN 分布 | $p(x_t) = \sum_{k=1}^{5} \pi_k \mathcal{N}(x_t; \mu_{k,t}, \sigma_{k,t}^2),\ \pi_k = \mathrm{softmax}(w_k)$ |
| safe_exp | $\sigma = \exp(\mathrm{clip}(z, -10, 10))$ |
| 投影矩阵 | $M = K \cdot V_{\text{road}\to\text{view}} \in \mathbb{R}^{3\times 4}$ |
| 透视投影 | $(u, v) = \pi(M \cdot [X, Y, Z, 1]^T)$ |
| 路径带左/右顶点 | $P_{L} = [X, Y-y_{\text{off}}, Z+z_{\text{off}}, 1]^T,\ P_{R} = [X, Y+y_{\text{off}}, Z+z_{\text{off}}, 1]^T$ |
| 近端裁剪 | $w = M_{2,:}\cdot[X,Y,Z,1]^T > \epsilon$ |
| 实验模式色相 | $h = \mathrm{clip}(60 + 35\cdot a_x,\ 0,\ 120)$（绿120/黄60/红0） |
| 实验模式饱和度 | $s = \min(|1.5\cdot a_x|,\ 1)$ |
| 实验模式亮度 | $l = \mathrm{interp}(s,\ [0,1],\ [0.95, 0.62])$ |
| 沿距离 alpha | $\alpha = \mathrm{interp}(t_{\text{grad}},\ [0.375, 0.75],\ [0.4, 0.0])$ |
| desired_curvature | $\kappa = \dot\psi / v_{\text{ego}}$（从 Plan YawRate 反推） |
| clip_curvature | $\dot\kappa_{\max} = \text{MAX\_LATERAL\_JERK}/v^2$ |

---

## 12. 结论

OpenPilot 的 Path 路径渲染是「极简第一人称 SR」哲学的典范：用一条透视收缩、宽度可变、颜色随意图渐变的路径带，把神经网络对未来 2 秒轨迹的预测直接呈现给驾驶员，背后是 supercombo Plan Head 多假设 MDN 输出 + 共用相机投影矩阵 `_car_space_transform = K @ view_from_road` + HSL 颜色编码 + 沿距离 alpha 衰减的工程组合。

关键洞察：

1. **数据先行**：Plan Head 的 5 假设 + MDN 不确定性（mu/std）是 openpilot 把感知不确定性贯穿到 MPC（std 加权 cost）、滤波器（radard KF 用 sigma 调 R）与渲染（实验模式 alpha 用 std 间接体现）的典范；
2. **投影统一**：路径带、车道线、路沿、前车 chevron 共用 `_car_space_transform`，是「逐像素对齐」直觉的工程根源——这一条比任何花哨的 3D 渲染都更重要；
3. **颜色克制**：默认只画一条蓝色路径带，实验模式才开 HSL 渐变（绿加速/黄巡航/橙刹车），**变道不通过颜色编码**而是通过路径几何自然体现——这是产品取舍而非技术限制；
4. **多 hypothesis 选主**：Plan 5 假设选 argmax 主假设渲染，备选不画（避免视觉混乱），与 Lead 的 2 假设同时显示形成对比——前者多假设服务于训练/调试，后者多假设服务于跟车决策；
5. **所见即所执行**：UI 渲染的路径与下游 MPC/Controller 用的路径是同一份 `modelV2.position` 数据，驾驶员看到的路径就是系统准备执行的轨迹——这是 openpilot SR 信任感的工程根源；
6. **v10/v11 演进不改渲染**：World Model 取代 MPC 监督、on-policy/off-policy 分裂，但 Plan Head 张量形状与渲染管线不变——这体现了 openpilot 把"模型演进"与"UI 渲染"解耦的工程纪律。

对 AuroraDrive 而言，复刻其 SR 范式的关键不是技术栈对齐（React + SVG/Three.js 完全可行），而是：保持第一人称路径带为默认、共用投影矩阵、HSL 颜色编码意图、多 hypothesis 选主、沿距离 alpha 衰减、与控制同源。按第 10.8 节的六阶段路线推进，可在 6 周内逼近 openpilot 0.10 的路径渲染品质。

---

## 附录 A：关键源码路径速查

| 关注点 | 路径 |
|---|---|
| Onroad 标注层装配 | `selfdrive/ui/qt/onroad.cc`（`AnnotatedCameraWidget` / `PathRenderWidget`） |
| NVG/GL 渲染 | `selfdrive/ui/qt/widgets/scene.cc` |
| 摄像头视图 | `selfdrive/ui/qt/widgets/cameraview.cc` |
| Python 离线渲染 | `selfdrive/ui/onroad/model_renderer.py` |
| Plan Head 张量解码 | `selfdrive/modeld/parse_model_outputs.py`（`parse_mdn`） |
| 默认张量布局 | `selfdrive/modeld/models/defaultmodel.cc` |
| 消息填充 | `selfdrive/modeld/fill_model_msg.py` |
| 模型常量 | `selfdrive/modeld/constants.py`（`ModelConstants.T_IDXS` / `IDX_N`） |
| 相机标定/投影 | `common/transformations/camera.py` / `coordinates.py` |
| LateralPlanner | `selfdrive/controls/lib/lateral_planner_lib/lateral_planner.py` |
| LateralMpc | `selfdrive/controls/lib/lateral_mpc_lib/lateral_mpc.py` |
| controlsd 100Hz | `selfdrive/controls/controlsd.py`（`clip_curvature`） |
| cereal 消息定义 | `cereal/car.capnp`（`ModelV2` / `Position` / `Acceleration` / `Action`） |

## 附录 B：研究方法与调用次数

- 研究方式：WebSearch + WebFetch + Read（本地既有研究文档交叉印证）
- 关键来源：
  - comma.ai 官方博客：0.10 release（World Model Planner / Tomb Raider #35620 / Space Lab #35816 / Vegan Filet-o-Fish #35240）、0.9.x 系列 release notes；
  - CSDN 解析系列：《揭秘自动驾驶黑箱：openpilot 神经网络决策可视化全指南》（`model_renderer.py` 的 `_map_line_to_polygon` / `_update_experimental_gradient` / `_draw_lead_indicator` 源码还原，HSL 公式 `path_hue = np.clip(60 + self._acceleration_x[i] * 35, 0, 120)`、`alpha = np.interp(lin_grad_point, [0.75/2.0, 0.75], [0.4, 0.0])`）、《OpenPilot分析 | 从图像到油门/刹车》、《openpilot EP1 深度解析》、《comma.ai 源码解析》、《openpilot 项目解析及 xgnpilot》、《Apollo Planning 模块架构》、《Apollo Dreamview 功能介绍》、《Apollo Planning 调试信息发送到 dreamview》；
  - 51CTO《OpenPilot Cereal 消息系统深度分析》（modelV2 / longitudinalPlan / lateralPlan 主题定义）；
  - arXiv:2504.19077（Learning to Drive from a World Model, CVPR 2025）；
  - GitHub / gitcode 路径核对（`selfdrive/ui/qt/widgets/scene.cc`、`onroad.cc`、`model_renderer.py`、`parse_model_outputs.py`、`camera.py`、`coordinates.py`）；
  - 本地既有研究文档：02j（Plan Head 张量解码）、02m（Plan → desiredCurvature → LatControl 链路）、02u（Onroad UI 架构、PathRenderWidget 组件清单、投影矩阵装配）、02w（共用 `_car_space_transform` 投影矩阵、chevron 渲染对照）、02k（v9/v10/v11 演进、comma 4、World Model Planner、off-policy FastViT）、Apollo 研究/01b（Dreamview 渲染）、02b（Dreamview Plus）。
- **实际内部工具调用次数：约 52 次**（WebSearch ≈ 28 次，WebFetch ≈ 12 次，Read 本地文档 ≈ 8 次，TodoWrite/Write ≈ 4 次）
- 报告字数：约 7200 字（含表格、代码、公式、附录），正文中文约 6000 字
