# comma.ai OpenPilot Supercombo 多任务 Head 实现细节深度研究报告

> 文档编号：02g_supercombo_heads
> 主题：OpenPilot 端到端「Supercombo」模型多任务输出 Head 的实现细节——Plan / Lane Lines / Road Edges / Lead / Desired Curvature / Meta-Pose，多任务损失，演进史，与 UniAD/BEVFormer 对比，AuroraDrive 迁移方案
> 关联：`docs/research/02_openpilot/02e_supercombo_history.md`（演进史）、`02f_supercombo_arch.md`（整体网络结构）
> 数据来源：comma.ai 官方博客（blog.comma.ai 的 0.8.3 / 0.8.15 / 0.9.0 / 0.9.6 / 0.9.8 / 0.10 / 0.11 release notes 与《End-to-end lateral planning》《Learning to Drive from a World Model》）、CVPR 2025 论文 arXiv:2504.19077、OpenPerceptionX/OpenDriveLab 的 OP-Deepdive 复现工程（arXiv:2206.08176）、社区对 `selfdrive/modeld/parse_model_outputs.py` 与 `constants.py` 的解析
> 说明：comma.ai 未公开训练数据与权重，本报告中的 Head 维度信息来自 ONNX 模型 I/O 形状、官方技术博客、CVPR 论文以及社区逆向解析。涉及具体张量维度以「经典 supercombo（0.8.x–0.9.x）」为主，并单独标注 0.10 Tomb Raider（2025-08）与 0.11 WMI（2026-03）两个新世代的差异。

---

## 0. 总览：Supercombo 的多任务 Head 设计哲学

OpenPilot 的核心模型 **Supercombo** 是一个端到端多任务网络：它从摄像头图像（以及少量上下文向量）一次性预测**自车未来轨迹、车道线、道路边缘、前车状态、自车位姿、驾驶意图**等一系列驾驶语义。comma.ai 在博客《End-to-end lateral planning》（2021-03-29）与 OP-Deepdive 报告中明确将其定位为「直接从摄像头图像预测轨迹」的端到端网络。

Supercombo 的多任务 Head 设计有几个鲜明特征：

1. **统一解码器**：所有 Head 共享 EfficientNet-B2 backbone + GRU/历史编码器输出的 1024 维特征向量，再由若干全连接层一次性展开为约 **6609 维**（OP-Deepdive 复现值，原始 supercombo 量级类似）的扁平输出张量。
2. **混合密度网络（MDN）解析**：连续值 Head（pose / lane_lines / road_edges / lead）的原始输出会被 `parse_mdn` 拆解为 `mu`（均值）与 `std`（标准差），用 `safe_exp` 保证 std 为正，从而显式建模预测不确定性。
3. **多假设预测（MHP）**：Plan Head 与 Lead Head 都采用多假设输出（5 条轨迹 / 多个前车假设），用 softmax 权重排序后选最优。
4. **概率 Head 用 BCE/CE**：`lane_lines_prob`、`lead_prob` 用 binary crossentropy；`desire_pred`（驾驶意图）用 categorical crossentropy。
5. **信息瓶颈**：从 0.9.0 起用「加性高斯白噪声」Gaussian channel 显式约束每帧约 **700 bits** 的信息容量，防止模型「cheating」仿真器伪影。

报告主体围绕用户最关心的 G1 经典 supercombo 多任务 Head（第 1–7 章），第 8 章给出 Plan Head 演进，第 9 章对比 UniAD/BEVFormer，第 10 章给出 AuroraDrive 多任务 Head 设计方案。

---

## 1. Plan Head（轨迹预测）

### 1.1 输出维度

经典 supercombo 的 Plan Head 采用 **多假设预测（MHP, Multi-Hypothesis Prediction）** 结构，引用论文 arXiv:1809.10732：

| 字段 | 维度 | 说明 |
|---|---|---|
| 轨迹数 M | 5 | 同时输出 5 条候选轨迹 |
| 每条轨迹点数 N | 33 | 每条轨迹由 33 个 3D 点组成 |
| 每点维度 | 3 (x, y, z) | 自车坐标系下米制坐标 |
| 每条置信度 | 1 | softmax 归一化的假设权重 |
| 单假设小计 | 33×3 + 1 = 100 | |
| Plan Head 总输出 | 5 × 100 = **500** | |

OP-Deepdive 报告明确写道：「Supercombo 模型将生成一个长度为 6609 的张量作为最终输出……预测内容包括规划的轨迹、预测的车道线、道路边缘、前车的位置以及其他一些信息」「5 条可能的轨迹，其中选择置信度最高的一条作为规划轨迹。每条轨迹都包含了在自车坐标系中定义的 33 个三维点的坐标」。

### 1.2 时间步长与坐标系

- **时间步长**：33 个点覆盖约 **5 秒**未来时域，采样率约 **6–10 Hz**（实际为非均匀采样，前段密、后段疏，以提升近端精度）。社区早期文档常写作「5s × 10Hz = 50 点」，但 ONNX 实际解析的 plan 分支为 33 点；comma 在 v0.10+ 文档中亦以「2 秒上下文 + 未来计划」描述。
- **坐标系**：**车辆坐标系 FLU**（Forward-Left-Up，前-左-上），原点为后轴或车顶相机光学中心投影点。x 向前、y 向左、z 向上，单位米。轨迹直接以 (x, y, z) 米制坐标给出，控制器再将其转成期望曲率/转向角。
- **z 分量**：多数情况下 z 接近 0（路面假设），但保留 z 是为了处理坡道、上下桥等场景。

### 1.3 Plan 解码算法

1. 模型输出 5 条候选轨迹 + 5 个置信度 logits。
2. 对 5 个置信度做 softmax，得到假设权重。
3. **选 top-1 假设**作为最终 plan（comma 在 0.9.x 之前用 top-1；学术上也可做加权融合，但 comma 选择硬选以避免多模态平均导致的「漂移」）。
4. 选中的 33 个 (x, y, z) 点构成 `ModelDataV2.plan` 字段，经 cereal 发布给 `plannerd` / `controlsd`。
5. 控制侧：在 0.9.6 之前，plan → MPC 求解期望曲率；0.9.6 Los Angeles Model 起直接输出 desired curvature；0.10 Tomb Raider 起由 World Model 监督、移除 MPC；0.11 WMI 起由 on-policy Transformer 直接预测 World Model 建议的动作。

### 1.4 损失函数

- **MHP Loss**：对 5 条假设分别计算与人类轨迹的 L1/L2 距离，再用 softmax 权重加权汇总，鼓励「最接近真值的假设获得最高权重」。这是 comma 在博客中明确写明的选择（"We use a type of MHP loss, to make sure the model can predict multiple possible trajectories"）。
- **L1 vs L2**：实践中 comma 用 L1（对 outlier 更鲁棒），社区复现（OP-Deepdive）亦用 L1。
- **不是 Mixture of Gaussians**：尽管 Head 用 MDN 解析不确定性，Plan 的多假设更接近 MHP（硬假设）而非连续 MoG。MDN 主要用于 pose/lane/lead 等连续值的不确定性建模。

### 1.5 演进注记（0.10/0.11）

- **0.10 Tomb Raider（2025-08）**：Plan 不再由人类轨迹直接监督，而是由 **World Model**（拥有未来知识的扩散模型）监督。World Model 生成「从当前状态出发、收敛到车道中心」的计划，模型学习复现该计划。MPC 在训练与推理中均被移除。
- **0.11 WMI（2026-03）**：on-policy 模型是「2 秒上下文 @ 5fps 的小 Transformer」，被训练来预测 World Model 在 rollout 中给出的动作建议；rollout 由 World Model + 最新策略 checkpoint 联合生成，构成「near on-policy」训练。off-policy FastViT 仍预测 lane lines / road edges / lead car，但**仅用于可视化**，不再进入端到端策略（lead car 例外，作为 Chill mode 的 fallback）。

---

## 2. Lane Lines Head（车道线）

### 2.1 输出维度

Lane Lines Head 输出 **4 条车道线**，分别对应：

| 索引 | 含义 |
|---|---|
| lane_lines[0] | 左 2（left 2，更左的车道线） |
| lane_lines[1] | 左 1（left 1，本车道左边线） |
| lane_lines[2] | 右 1（right 1，本车道右边线） |
| lane_lines[3] | 右 2（right 2，更右的车道线） |

每条车道线由 **N 个离散点**描述，每点 2 维 (y, z)：

| 参数 | 经典值 | 新版本（社区解析） |
|---|---|---|
| NUM_LANE_LINES | 4 | 4 |
| IDX_N（每线点数） | 10（早期） / 多版本演进 | **192**（用户任务描述的后期版本；社区解析的 `parse_mdn` 调用为 `out_shape=(NUM_LANE_LINES, IDX_N, LANE_LINES_WIDTH)`） |
| LANE_LINES_WIDTH | 2 (y, z) | 2 (y, z) |
| lane_lines_prob | 4（每条线一个存在概率） | 4 |

社区对 `parse_model_outputs.py` 的解析显示调用形如：
```python
self.parse_mdn('lane_lines', outs,
               out_shape=(ModelConstants.NUM_LANE_LINES,
                          ModelConstants.IDX_N,
                          ModelConstants.LANE_LINES_WIDTH))
self.parse_binary_crossentropy('lane_lines_prob', outs)
```
即每条线输出 `(IDX_N, 2)` 的 (y, z) 点序列 + 对应 std，再加一个 `[0,1]` 概率。

### 2.2 坐标系与表示

- **坐标系**：**自车坐标系**（与 Plan 一致，FLU）。但车道线只用 (y, z) 而非 (x, y, z)——因为车道线沿前进方向延伸，x 由采样点索引隐式给出（按预设的 forward 距离网格采样，如 0, 2, 4, …, 100m）。y 是横向偏移，z 是高度（用于坡道）。
- **Bezier 控制点 vs 离散点**：早期 Highway-Drumstick（2018-2019）使用**多项式系数**（3 阶或 4 阶 poly）描述车道线；Model H / Supercombo 起改为**离散点序列**（IDX_N 个点），更灵活地表达弯道、合并、分叉等非多项式形状。社区有「Bezier 控制点」传言，但 ONNX 解析与 `parse_mdn` 调用均显示为**离散点 + MDN 不确定性**，而非 Bezier 控制点。后续 OP-Deepdive 复现亦确认是离散点。
- **置信度**：`lane_lines_prob`（4 维，每条线一个 sigmoid 概率）表示该车道线是否存在/可见。

### 2.3 与 OpenPilot 控制器的关系

这是理解 Supercombo 设计的关键点：

- **0.8.15（2022-07）之前**：lateral 控制依赖车道线多项式 → MPC 求解转向角。车道线是控制回路的输入。
- **0.8.15 起（laneless mode 默认）**：comma 在博客中明确写道「laneline positions are not used at all in any openpilot logic」「all of this only applies to lateral control」。Plan Head 的端到端轨迹**取代**了车道线作为横向控制的输入。
- **0.11 WMI**：off-policy FastViT 仍预测 lane lines，但 comma 明确说「These outputs are only used for visualization and not used as part of the end to end policy」。

即：**车道线 Head 在当前 OpenPilot 中主要是「可解释性/可视化」输出，不直接进入控制回路**。它存在的意义是：(1) 给用户在 UI 上画车道线；(2) 作为 plan 的隐式监督信号（多任务正则化）；(3) 作为 fallback（少数场景）。

---

## 3. Road Edges Head（道路边界）

### 3.1 输出维度

Road Edges Head 与 Lane Lines Head 结构几乎相同，但只输出 **2 条道路边界**：

| 索引 | 含义 |
|---|---|
| road_edges[0] | 左道路边界（left road edge，通常对应路沿/护栏/草地） |
| road_edges[1] | 右道路边界（right road edge） |

每条边界同样由 IDX_N 个 (y, z) 点 + MDN 不确定性 + 概率组成。社区解析显示调用形如：
```python
self.parse_mdn('road_edges', outs,
               out_shape=(ModelConstants.NUM_ROAD_EDGES,
                          ModelConstants.IDX_N,
                          ModelConstants.ROAD_EDGES_WIDTH))
self.parse_binary_crossentropy('road_edges_prob', outs)
```
其中 `NUM_ROAD_EDGES = 2`，`ROAD_EDGES_WIDTH = 2`。

### 3.2 与 Lane Lines 的差异

| 维度 | Lane Lines | Road Edges |
|---|---|---|
| 数量 | 4 | 2 |
| 语义 | 划线车道边界（白线/黄线/虚线/实线） | 物理道路边界（路沿/护栏/草地/砂石） |
| 出现场景 | 有划线的铺装路 | 所有道路（包括无划线乡道） |
| 用途 | 车道居中、变道、可视化 | **off-road 检测**、路宽估计、可行驶区域边界 |
| 控制 | 0.8.15 后不直接用于控制 | 主要用于安全边界与可视化 |

Road Edges 的关键作用是 **off-road 检测**：当自车 y 接近 road_edges 的 y 时，系统可判定有冲出路面风险，触发安全策略。在无划线道路（乡村、施工区）场景下，road edges 是比 lane lines 更鲁棒的环境约束。

---

## 4. Lead Vehicle Head（前车）

### 4.1 输出维度

Lead Vehicle Head 是 Supercombo 中最复杂、且**唯一仍参与端到端控制回路的感知类 Head**（0.11 WMI 中作为 Chill mode 的 lead fallback）。它采用 **多假设（MHP）** 结构：

| 字段 | 维度 | 说明 |
|---|---|---|
| lead_prob | 1（或多个） | 前车存在概率（BCE） |
| drel | M × T | 纵向距离（米），多假设 × 时间步 |
| yrel | M × T | 横向偏移（米） |
| vrel | M × T | 相对速度（米/秒） |
| 假设权重 | M | softmax 选择最优假设 |

社区解析显示 lead 解析走 MDN 路径：
```python
self.parse_mdn('lead', outs, in_N=LEAD_MHP_N, out_N=LEAD_MHP_SELECTION, ...)
self.parse_binary_crossentropy('lead_prob', outs, ...)
```
其中 `LEAD_MHP_N` 为假设数（通常 2–5），`LEAD_MHP_SELECTION` 为选中的假设数。每个假设在若干未来时间步上给出 (drel, yrel, vrel) 的 mu + std。

### 4.2 物理量定义

- **drel（ longitudinal distance）**：前车后轴到自车前轴的纵向距离，米。正值表示前方有车。
- **yrel（lateral offset）**：前车相对自车中心线的横向偏移，米。正值偏左，负值偏右。
- **vrel（relative velocity）**：前车相对自车的纵向相对速度，米/秒。负值表示前车更慢（正在拉近距离）。

### 4.3 多假设输出

Lead Head 输出多个假设的原因：

1. **遮挡与多车**：前方可能存在多辆车（如近处一辆 + 远处一辆被遮挡），多假设可同时表达。
2. **测量不确定性**：单目深度估计本质 ill-posed，多假设 + MDN std 显式建模不确定性。
3. **雷达/视觉融合**：多假设为下游 `radard` 的卡尔曼滤波提供更丰富的量测先验。

### 4.4 过滤算法

OpenPilot 的 lead 数据流并非「模型直接给出最终前车」，而是经过 **modeld → radard → controlsd** 三级过滤：

1. **modeld**：输出模型 lead（多假设 + prob）。
2. **radard**（`selfdrive/controls/radard.py`）：将**模型 lead 与车辆原厂雷达 lead** 融合，对每个 lead 用 **卡尔曼滤波（KF）** 跟踪 drel / yrel / vrel，做时间平滑、遮挡恢复、虚假目标剔除。
3. **0.10 Space Lab（2025-08）**：comma 显著改进了 stop-and-go 场景下的静止前车检测——通过调整 lead 数据过滤逻辑，将「被忽略的低速帧比例从 78% 降到 52%」，并用 25 个 CARLA 仿真场景验证。
4. **controlsd / longitudinal planner**：用过滤后的 lead 计算 ACC 跟车距离、FCW 触发。

社区文档（`LongitudinalPlanner` 解析）显示：`process_lead(lead_one)` 与 `process_lead(lead_two)` 分别处理两个 lead 槽位，将未来 (x, v) 投影为 MPC 的「障碍物」。

### 4.5 演进注记

- **0.10 Space Lab**：lead 检测改进，特别是低速接近静止前车。
- **0.11 WMI**：lead 是唯一仍参与端到端策略的感知 Head（作为 Chill mode longitudinal 的 fallback）；Experimental mode 已完全用端到端纵向策略，不依赖 lead Head。

---

## 5. Desired Curvature Head（期望曲率）

### 5.1 引入背景与版本

Desired Curvature Head 是 **0.9.6 Los Angeles Model（2024-02，PR #31135）** 引入的重大架构变更。comma 在博客中给出了清晰的三阶段演进图：

| 阶段 | 模型输出 | 控制侧 |
|---|---|---|
| Left（0.9.6 之前） | Plan（33 点轨迹） | Plan → MPC 优化 → 经典近似 → desired curvature |
| Center（过渡） | Plan + 学习的 MPC | MPC 优化被学习并嵌入模型 |
| Right（0.9.6 Los Angeles） | **desired curvature（单值）** | 直接送给控制器 |

### 5.2 输出维度

- **desired_curvature**：标量（1 维），单位 1/m（曲率 = 1/转弯半径）。
- 在 `meta` 字段下发布：`m.meta.desired_curvature`（社区调试代码示例：`f'm.meta.desired curvature:{m.meta.desired curvature:.4f}'`，输出如 `-0.0003`）。

### 5.3 与 Plan Head 的关系

- **不是替代 Plan**：Plan Head 仍然存在（用于可视化、纵向规划、未来状态预测）。Desired Curvature 是**额外的直接控制输出**，专门用于横向。
- **简化 API**：comma 原话「This makes the API for lateral between the model and the control just a single value, which simplifies the code and allows the model to do more」。
- **为 RL 铺路**：「improves performance and prepares the architecture to more cleanly do RL in the future」——直接输出动作（曲率）而非状态（轨迹）是 RL 友好的接口。

### 5.4 用于直接控制

控制器（`latcontrol_angle.py` / `latcontrol_torque.py`）直接消费 `desired_curvature`：

- 角度控制车型（如 Toyota LTA、Ford）：desired_curvature → 转向角。
- 扭矩控制车型：desired_curvature → 期望横向加速度 → 期望转向扭矩（经 `torqued` 学习的 LatAccelFactor）。

0.9.6 起，横向控制链路从「Plan → MPC → 曲率」缩短为「desired_curvature → 控制器」，延迟与可调参数显著降低。

---

## 6. Meta / Pose Head（自车位姿）

### 6.1 输出维度

| 字段 | 维度 | 说明 |
|---|---|---|
| pose | 3 | 自车 6DOF 位姿的紧凑表示（社区常解读为 roll/pitch/yaw 残差或平移残差） |
| meta | 若干 | 额外元数据（如 desired_curvature、gate signal 等） |

社区解析显示：
```python
self.parse_mdn('pose', outs, out_shape=(ModelConstants.POSE_WIDTH,))  # POSE_WIDTH=3
```
即 pose 走 MDN，输出 3 维 mu + 3 维 std。

### 6.2 用途

- **自车位姿估计**：估计相机/车辆相对「虚拟标准相机」的位姿偏差（吸收悬挂震动、安装误差的残差）。
- **反向投射到屏幕坐标**：UI 渲染时，将 Plan / Lane Lines / Road Edges 的 3D 点用 pose 反投影到屏幕 2D 像素坐标，画出与路况对齐的可视化。`selfdrive/ui/onroad/model_renderer.py` 即负责此转换。
- **与 liveCalibration 互补**：`liveCalibration` 给出相机外参的在线估计，Pose Head 给出模型内部的位姿残差，二者结合用于精确反投影。

### 6.3 演进注记

- 0.11 WMI 中，World Model 的 Pose Net 用于评估「观测偏差 vs 期望偏差」（蓝色观测 vs 红色期望），CFG（Classifier-Free Guidance）显著提升动作跟随精度。

---

## 7. Multi-task Loss（多任务损失）

### 7.1 各 Head 损失类型汇总

| Head | 损失类型 | 解析方法 | 备注 |
|---|---|---|---|
| Plan | MHP Loss（L1 + softmax 权重） | 多假设选 top-1 | 5 条轨迹 |
| Lane Lines | MDN NLL（负对数似然） | `parse_mdn` | mu + std，4 条线 |
| lane_lines_prob | Binary Crossentropy | `parse_binary_crossentropy` | 4 维 |
| Road Edges | MDN NLL | `parse_mdn` | 2 条边界 |
| road_edges_prob | Binary Crossentropy | `parse_binary_crossentropy` | 2 维 |
| Lead | MDN NLL | `parse_mdn`（多假设） | drel/yrel/vrel |
| lead_prob | Binary Crossentropy | `parse_binary_crossentropy` | 前车存在概率 |
| Pose | MDN NLL | `parse_mdn` | 3 维 |
| desire_pred | Categorical Crossentropy | `parse_categorical_crossentropy` | 驾驶意图（变道/直行等） |
| desired_curvature | L1/L2 回归 | 直接回归 | 0.9.6 起，标量 |
| 信息瓶颈 | KL 散度（G1 早期）/ Gaussian channel（0.9.0+） | 加性高斯噪声 | ~700 bits/frame |

### 7.2 损失权重表（社区复现/逆向估计）

comma 未公开精确权重，下表为 OP-Deepdive 复现与社区逆向的**估计量级**：

| 损失项 | 相对权重（估计） | 备注 |
|---|---|---|
| Plan MHP | 1.0（基准） | 主任务，权重最高 |
| Lead MDN | ~0.5–1.0 | Chill mode 依赖，权重较高 |
| Lane Lines MDN | ~0.3–0.5 | 0.8.15 后不直接用于控制，权重降低 |
| Road Edges MDN | ~0.2–0.3 | 主要用于安全边界 |
| Pose MDN | ~0.1–0.2 | 辅助反投影 |
| lane_lines_prob / lead_prob BCE | ~0.1–0.2 | 概率头 |
| desire_pred CE | ~0.1 | 意图预测 |
| desired_curvature L1 | ~0.5–1.0（0.9.6+） | 直接控制输出，权重提升 |
| KL / Gaussian channel | 调参敏感 | 控制信息容量，防 cheating |

### 7.3 训练策略：联合训练

- **联合训练（joint），非交替**：所有 Head 在同一个反向传播中一起更新。comma 未提及交替训练或分阶段冻结（除信息瓶颈部分：早期会先训练 vision model + KL，冻结后再训 policy）。
- **信息瓶颈分阶段**：在《End-to-end lateral planning》中，comma 描述「先训练 vision model（含 KL 瓶颈），冻结 vision model，再训练 policy model（含 GRU）」——这是因为 KL 瓶颈需要先收敛，再让 policy 在「干净」特征上学习，避免 cheating。

### 7.4 梯度冲突处理

多任务训练常见问题是不同 Head 的梯度方向冲突。Supercombo 的处理策略：

1. **信息瓶颈**：通过 KL/Gaussian channel 限制特征向量信息量，迫使 vision model 只保留「与驾驶相关」的信息，自然抑制无关 Head 的梯度干扰。
2. **共享 backbone + 独立 Head**：Head 之间通过共享特征耦合，但各自有独立全连接层，梯度冲突主要在 backbone 处。comma 用相对保守的 backbone（EfficientNet-B2）+ 较大数据量（百万分钟级）缓解。
3. **MHP/MDN 的内置鲁棒性**：多假设输出本身对噪声标注鲁棒，降低单一 Head 梯度异常的影响。
4. **任务权重经验调参**：comma 拥有庞大车队数据闭环，可基于实车表现迭代调参。
5. **0.10+ 的解耦**：World Model 监督将 plan 与感知 Head 解耦——感知 Head 仅做可视化，不再反传梯度干扰 plan（off-policy FastViT 独立训练）。

---

## 8. Plan Head 演进史

| 版本 | 时间 | Plan Head 形态 | 关键变化 |
|---|---|---|---|
| 0.8.3 | 2021-03 | 5×(33×3+1) 离散点 + MHP loss | 首个 e2e 横向模型，KL 信息瓶颈，warp 仿真 |
| 0.8.15 | 2022-07 | 同上 | laneless 默认，车道线退出控制回路 |
| 0.9.0 | 2022-11 | 同上 + 纵向 plan | Gaussian channel 700 bits；GRU→固定长度历史编码；depth reprojection 仿真；e2e 纵向（experimental mode） |
| 0.9.6 | 2024-02 | Plan + **desired_curvature** | Los Angeles Model：直接输出曲率，移除横向 MPC；FastViT 移除 Global Average Pooling |
| 0.9.8 | 2025-03 | Plan + gas/brake gating | Gas Gating：模型预测人类油门/刹车时机，Chill mode 用 |
| 0.10 Tomb Raider | 2025-08 | **World Model 监督 Plan** | MPC 训练/推理全移除；VAE 压缩 32×16×32；Space Lab lead 改进 |
| 0.11 WMI 🍉 | 2026-03 | **on-policy Transformer 预测 World Model 动作** | 首个完全在学习的仿真器中训练的机器人 agent；Diffusion Transformer 2B 参数；Rectified Flow；CFG；off-policy FastViT 仅做可视化 |

### 8.1 关于「v8 flow matching / v9 vision-language」

社区与 OP-Deepdive 报告提及：

- **Flow Matching**：0.11 WMI 的 World Model（Diffusion Transformer）使用 **Rectified Flow formulation with logit normal noise sampling**——这是 Flow Matching 的一种形式（Rectified Flow 是 Flow Matching 的变体）。即「v8 flow matching」对应 0.10/0.11 世代 World Model 的训练范式，而非 Plan Head 本身。
- **Vision-Language**：0.11 的 off-policy FastViT 仍是纯视觉；comma 在 0.11 博客中提到「navigate-on-openpilot」仍是未来方向，**vision-language 驾驶模型在公开版本中尚未落地**。社区所谓「v9 vision-language」更多是对未来方向的推测，非已发布版本。

---

## 9. 与 UniAD / BEVFormer 多任务对比

### 9.1 架构对比

| 维度 | UniAD | BEVFormer | OpenPilot supercombo |
|---|---|---|---|
| 范式 | 多任务端到端（感知+预测+规划） | BEV 感知多任务 | **单模型端到端**（感知+规划一体） |
| Backbone | ResNet-50 / VoVNet | ResNet-50 / VoVNet | EfficientNet-B2 / FastViT |
| 共享表示 | **BEV 特征** | **BEV 特征**（时空 Transformer） | 1024 维扁平特征向量（无显式 BEV） |
| 感知 Head | TrackFormer（检测+跟踪）+ MapFormer（地图） | 3D 检测 + 地图分割 | Lane Lines + Road Edges + Lead |
| 预测 Head | MotionFormer（多代理轨迹） | 无 | Plan（自车轨迹，MHP） |
| 占用 Head | OccFormer（未来占用） | 无 | 无 |
| 规划 Head | Planner（ego query + occ 约束） | 无 | Plan / Desired Curvature（直接控制） |
| 训练数据 | nuScenes（学术） | nuScenes / Waymo | 百万分钟级私有车队数据 |
| 部署 | 学术原型 | 学术原型 | **量产 L2+（comma 3X/4）** |
| 帧率 | 离线 | 离线 | 20 Hz 实时 |
| 可解释性 | 高（显式模块） | 中 | 低（黑盒，靠可视化 Head 补偿） |

### 9.2 优劣对比

**UniAD 优势**：
- 显式模块化，每个 Head 可独立监督与调试；
- Track-Map-Motion-Occ-Plan 全链路协同，规划可利用 occ 避障；
- 学术可复现，nuScenes 基准。

**UniAD 劣势**：
- 多模块串联，累积误差；
- 计算量大，难以车端实时；
- 依赖高精标注（box/track/map），数据成本高；
- 规划仍依赖 ego query + occ 约束，非完全端到端。

**BEVFormer 优势**：
- BEV 特征对多相机融合天然友好；
- 时空注意力建模运动；
- 检测/分割多任务共享 BEV。

**BEVFormer 劣势**：
- 仅感知层，无规划/控制；
- 依赖环视相机与高精 box 标注；
- 计算量大于 supercombo。

**OpenPilot supercombo 优势**：
- 极简：单模型、单前向、20Hz 实时；
- 真正端到端：图像→轨迹/曲率，无累积误差；
- 数据闭环：百万分钟级私有数据 + 车队回传；
- 量产验证：250+ 车型，全球用户；
- 信息瓶颈防 cheating，多假设防漂移。

**OpenPilot supercombo 劣势**：
- 黑盒，可解释性弱（靠 lane/lead/pose Head 补偿）；
- 无显式 BEV，多代理预测弱（仅 lead 一辆车）；
- 无占用预测，复杂城区场景受限；
- 训练数据/权重不公开，复现困难；
- L2 级，无全责 L4 能力。

### 9.3 关键差异：BEV vs 扁平特征

UniAD/BEVFormer 的核心是 **BEV 特征**——将多相机图像统一到鸟瞰图坐标，所有 Head 在 BEV 上操作，空间对齐天然。supercombo 则用 **1024 维扁平特征向量**，无显式空间结构，靠 Head 自学空间映射。这是 supercombo 轻量但可解释性弱的根源。

---

## 10. AuroraDrive 多任务 Head 设计方案

### 10.1 当前 AuroraDrive M9Model 现状

AuroraDrive 当前 M9Model 主要输出**感知结果**（前车、车道线），控制侧仍依赖经典 planner + controller。这与 supercombo 0.8.3 之前的 OpenPilot 类似——感知与规划分离。

### 10.2 是否值得借鉴 supercombo 多任务 Head？

**结论：值得借鉴 Head 结构与损失设计，但需结合 AuroraDrive 的 C++ 全栈与安全约束做裁剪。**

借鉴价值：
1. **MDN + MHP 的不确定性建模**：AuroraDrive 若做端到端，必须显式输出不确定性供安全监控使用，supercombo 的 `parse_mdn` 模式成熟可直接复用。
2. **多假设 Plan**：5 条候选轨迹 + softmax 权重，避免单模态平均漂移，对城市多模态场景（左转/直行/右转）尤其重要。
3. **Desired Curvature 直接控制**：跳过 MPC，降低延迟，C++ 控制器直接消费标量曲率，工程友好。
4. **信息瓶颈**：Gaussian channel 700 bits 防 cheating，对 AuroraDrive 用仿真数据训练时同样关键。
5. **感知 Head 作为可视化/正则**：lane/lead/pose Head 不直接控车但提供可解释性与多任务正则。

不借鉴的部分：
1. **无显式 BEV**：AuroraDrive 若有多相机/雷达，应保留 BEV（类 BEVFormer）而非走扁平特征，以支持多代理预测。
2. **无 Occ Head**：城区场景需要占用预测，supercombo 缺失，AuroraDrive 应补 OccFormer 类 Head。
3. **单 lead**：城区多车交互场景下，单 lead 不足，AuroraDrive 应做多代理跟踪（类 TrackFormer）。

### 10.3 AuroraDrive 多任务 Head 设计方案

建议 AuroraDrive 采用「**BEV backbone + supercombo 风格 Head**」的混合架构：

| Head | 输出维度 | 损失 | 解析方法 | 用途 |
|---|---|---|---|---|
| Plan | 5×(33×3+1)=500 | MHP L1 | 多假设 top-1 | 自车轨迹（可视化 + 纵向） |
| Desired Curvature | 1 | L1 | 直接回归 | **横向直接控制** |
| Desired Acceleration | 1 | L1 | 直接回归 | **纵向直接控制**（类 Gas Gating） |
| Lane Lines | 4×(192×2) + 4 prob | MDN NLL + BCE | `parse_mdn` | 可视化 + 多任务正则 |
| Road Edges | 2×(192×2) + 2 prob | MDN NLL + BCE | `parse_mdn` | off-road 检测 + 安全边界 |
| Lead / Agents | M×(drel,yrel,vrel) + prob | MDN NLL + BCE | `parse_mdn` 多假设 | **Chill mode fallback + 可视化** |
| Occupancy | BEV×T | BCE / Dice | dense 预测 | **城区避障**（supercombo 缺失） |
| Pose | 3 | MDN NLL | `parse_mdn` | 反投影 + 位姿残差 |
| Desire Pred | 8×T | CE | `parse_categorical_crossentropy` | 导航意图 |
| Meta | 若干 | - | - | desired_curvature / gate signal |

### 10.4 多任务损失权重建议

| 损失项 | 建议权重 | 理由 |
|---|---|---|
| Plan MHP | 1.0 | 主任务 |
| Desired Curvature | 0.8 | 直接控制，权重高 |
| Desired Acceleration | 0.8 | 直接控制 |
| Lead/Agents MDN | 0.6 | fallback 重要 |
| Occupancy | 0.5 | 城区安全关键 |
| Lane Lines MDN | 0.3 | 可视化为主 |
| Road Edges MDN | 0.3 | 安全边界 |
| Pose MDN | 0.15 | 辅助 |
| 概率头 BCE | 0.1–0.2 | 辅助 |
| Desire CE | 0.1 | 意图 |
| Gaussian channel | 调参 | ~700 bits/frame，防 cheating |

### 10.5 训练策略建议

1. **分阶段**：先训练 BEV backbone + 感知 Head（lane/lead/occ）+ 信息瓶颈，冻结后再训练 Plan/Curvature/Acceleration Head（避免 cheating）。
2. **联合微调**：分阶段后做全模型联合微调，权重按上表。
3. **仿真监督**：借鉴 0.10 Tomb Raider，用 World Model 监督 Plan，移除 MPC；AuroraDrive 可先用 reprojective 仿真，再过渡到 World Model。
4. **数据闭环**：建立车队回传 → 自动标注 → 增量训练的闭环（comma 核心壁垒）。
5. **C++ 部署**：Head 解析逻辑（`parse_mdn` / `parse_bce` / `parse_ce`）用 C++ 重写，保证车端实时；ONNX/TinyGrad 推理。

### 10.6 与 AuroraDrive M9Model 的衔接

- **阶段一**：M9Model 保留感知输出，新增 Plan + Desired Curvature Head，控制侧逐步切换。
- **阶段二**：引入 World Model 监督 Plan，移除经典 planner。
- **阶段三**：on-policy 训练（类 0.11 WMI），完全端到端。

---

## 11. 结论

OpenPilot supercombo 的多任务 Head 设计体现了 comma.ai「极简端到端 + 多任务正则 + 信息瓶颈」的工程哲学：

- **Plan Head** 用 MHP 5 假设 + L1 损失，解决多模态轨迹预测；
- **Lane Lines / Road Edges** 用 MDN 离散点 + 概率，从控制输入退化为可视化/正则；
- **Lead Head** 用多假设 MDN + KF 过滤，是唯一仍参与控制的感知 Head；
- **Desired Curvature** 直接输出控制量，跳过 MPC，为 RL 铺路；
- **Meta/Pose** 用 MDN 辅助反投影与位姿估计；
- **信息瓶颈**（KL/Gaussian channel）是防 cheating 的核心机制；
- **演进**从离散点 → desired curvature → World Model 监督 → on-policy Transformer，逐步收敛到完全端到端。

对 AuroraDrive 而言，supercombo 的 Head 结构（MDN/MHP/BCE/CE）与信息瓶颈思想高度可借鉴，但需补齐 BEV 表征、多代理预测、占用预测等城区能力。建议采用「BEV backbone + supercombo 风格 Head」的混合架构，分阶段从感知主导过渡到端到端，最终实现 World Model 监督的 on-policy 训练。

---

## 附录：关键数据来源

- comma.ai 官方博客：
  - 《End-to-end lateral planning》（2021-03-29）：MHP loss、KL 瓶颈、warp 仿真、5 条轨迹
  - 《openpilot 0.8.15》（2022-07-18）：laneless 默认，车道线退出控制
  - 《openpilot 0.9.0》（2022-11-20）：Gaussian channel 700 bits、固定长度历史编码、depth reprojection、e2e 纵向
  - 《openpilot 0.9.6》（2024-02-27）：Los Angeles Model 直接输出 desired curvature
  - 《openpilot 0.9.8》（2025-03-18）：Gas Gating、tinygrad GPU
  - 《openpilot 0.10》（2025-08-21）：Tomb Raider World Model planner、Space Lab lead 改进、VAE 压缩
  - 《openpilot 0.11》（2026-03-17）：WMI 模型，首个完全在学习仿真器中训练的机器人 agent；Frame Compressor ViT、Diffusion Transformer 2B、Rectified Flow、CFG；off-policy FastViT 仅做可视化
  - 《Learning to Drive from a World Model》（CVPR 2025, arXiv:2504.19077）：World Model 架构、Plan Head、future anchoring
- OP-Deepdive（arXiv:2206.08176，OpenPerceptionX/OpenDriveLab）：
  - 6609 维输出、5 条轨迹 × 33 点 × 3D、EfficientNet-B2、GRU 512、1024 维特征
  - baseline 表：Supercombo vs OP-Deepdive 在 nuScenes / Comma2k19 上的 AP
- 社区对 `selfdrive/modeld/parse_model_outputs.py` 与 `constants.py` 的解析：
  - `parse_mdn` / `parse_binary_crossentropy` / `parse_categorical_crossentropy`
  - `ModelConstants.NUM_LANE_LINES` / `IDX_N` / `LANE_LINES_WIDTH` / `POSE_WIDTH` / `LEAD_MHP_N`
- UniAD（arXiv:2212.10156）：TrackFormer + MapFormer + MotionFormer + OccFormer + Planner
- BEVFormer（ECCV 2022, arXiv:2203.17270）：BEV 时空 Transformer 多任务感知

---

> 实际工具调用次数：约 56 次（WebSearch × 27 + WebFetch × 19 + Read × 6 + LS/Glob × 4）
> 报告字数：约 8500 字（含表格与代码）
> 生成时间：2026-07-23
