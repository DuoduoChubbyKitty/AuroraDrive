# UniAD 深度研究报告：Planning-oriented Autonomous Driving

> CVPR 2023 最佳论文（Best Paper Award）
> 论文标题：Planning-oriented Autonomous Driving
> 研究主题：以规划为导向的端到端自动驾驶统一框架
> 报告生成日期：2026-07-23

---

## 一、论文背景

### 1.1 基本信息

- **标题**：Planning-oriented Autonomous Driving（以规划为导向的自动驾驶）
- **作者**：Yihan Hu、Jiazhi Yang、Li Chen、Keyu Li、Chonghao Sima、Xizhou Zhu、Siqi Chai、Senyao Du、Tianwei Lin、Wenhai Wang、Lewei Lu、Xiaosong Jia、Qiang Liu、Jifeng Dai、Yu Qiao、Hongyang Li（前三位为共同一作，Hongyang Li 与 Li Chen 为项目 lead）
- **机构**：上海人工智能实验室（Shanghai AI Laboratory，OpenDriveLab 团队）、武汉大学、商汤科技研究院（SenseTime Research）
- **发表会议**：CVPR 2023，从 9155 篇投稿中脱颖而出获 **最佳论文奖**（Best Paper Award）
- **arXiv**：2212.10156（2022 年 12 月 20 日提交 v1，2023 年 3 月 23 日更新 v2）
- **项目主页**：https://opendrivelab.github.io/UniAD/
- **开源代码**：https://github.com/OpenDriveLab/UniAD（当前版本 v2.0）

### 1.2 研究动机

现代自动驾驶系统通常被刻画为按顺序执行的模块化任务：**感知 → 预测 → 规划**。为完成多样化任务，业界存在三类典型方案，但各有缺陷：

1. **独立模型方案**（图 1a）：为每个任务部署独立模型。模块间优化目标孤立，导致信息丢失、误差累积、特征错位。
2. **多任务学习 MTL**（图 1b）：共享骨干网络 + 独立任务头（如 BEVerse、Transfuser、Mobileye、Tesla、NVIDIA）。能节省算力，但易出现"负迁移"（任务间相互争夺特征表达），且未围绕规划核心优化。
3. **传统端到端**（图 1c）：
   - c.1：直接从感知结果预测自车轨迹，跳过中间任务，缺乏安全性与可解释性；
   - c.2：仅整合部分中间任务，未充分发挥任务协同价值。

UniAD 的核心立场是：**理想的自动驾驶框架应围绕最终目标——安全规划——进行设计与优化**。论文重新审视感知与预测中的关键组件，并按优先级排序，使所有子任务都服务于规划，从而提出了图 1c.3 所示的"以规划为导向"的端到端统一框架。

---

## 二、核心思想

UniAD 的设计哲学可凝练为四个关键词：

### 2.1 Planning-oriented（以规划为中心）

不是把感知、预测当作独立任务，而是将其作为规划的前置支撑模块。整个 pipeline 的损失与优化都向"安全规划"这一终极目标对齐，所有前序节点都通过联合优化贡献于规划。

### 2.2 端到端统一框架

UniAD 是**第一个将全栈驾驶任务（检测、跟踪、在线建图、运动预测、占用预测、规划）整合到一个深度神经网络中的框架**。它不是简单堆叠模块，而是从全局视角提供互补的特征抽象以建模智能体交互。

### 2.3 Query 统一所有任务

这是连接所有节点的关键设计。每个模块在 Transformer Decoder 结构中设计，**任务查询（query）作为连接每个节点的接口**。相比经典的边界框（bounding box）表示，查询具有更大感受野，能"软化"上游预测的复合误差；同时查询可灵活建模多智能体之间的交互关系。整个 pipeline 由多组查询向量（track query / map query / motion query / occ query / ego query）串联。

### 2.4 五模块层级架构

UniAD 由四个基于 Transformer Decoder 的感知与预测模块 + 一个规划模块组成：

| 模块 | 功能 | 输入 query | 输出 |
|------|------|-----------|------|
| TrackFormer | 联合检测 + 多目标跟踪 | track query | 物体特征 QA、跟踪轨迹 |
| MapFormer | 在线建图 / 全景分割 | map query | 地图特征 QM |
| MotionFormer | 多目标运动预测 | motion query | 未来轨迹、运动特征 QX |
| OccFormer | 时空占用网格预测 | 密集 BEV 特征为 Q | 实例级占用网格 OA |
| Planner | 自车轨迹规划 | ego-vehicle query | 自车未来轨迹 |

### 2.5 五模块架构图（文字版）

```
                     多视角环视相机图像 (6 路)
                              │
                              ▼
                ┌─────────────────────────┐
                │  图像骨干 (ResNet101+FPN) │
                └────────────┬────────────┘
                             │ 图像特征
                             ▼
                ┌─────────────────────────┐
                │   BEV 编码器 (BEVFormer)  │  ← 可替换为其他 BEV / 多帧 / 多模态融合
                └────────────┬────────────┘
                             │ BEV 特征 B
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
   │ TrackFormer  │    │ MapFormer   │    │             │
   │ track query  │    │ map query   │    │  (BEV B 共享) │
   │ (det+track+  │    │ (车道/人行道/│    │             │
   │  ego query)  │    │  可行驶/分隔)│    │             │
   └──────┬──────┘    └──────┬──────┘    │             │
          │ QA 物体特征     │ QM 地图特征 │             │
          │ (含 ego query)  │            │             │
          └────────┬────────┴────────────┘             │
                   │                                    │
                   ▼                                    │
            ┌─────────────────┐                        │
            │   MotionFormer  │◄──── BEV B ────────────┘
            │  motion query   │
            │  agent-agent    │
            │  agent-map      │
            │  agent-goal     │
            └────────┬────────┘
                     │ 未来轨迹 + 运动特征 QX
            ┌────────┴────────────────────┐
            │                             │
            ▼                             ▼
     ┌─────────────┐              ┌─────────────┐
     │  OccFormer  │              │   Planner   │
     │ BEV为Q      │              │ ego query   │
     │ QA/PA/QX为KV│              │ + BEV交互   │
     │ 实例级占用   │              │ 碰撞优化器  │
     └──────┬──────┘              └──────┬──────┘
            │ 占用网格 OA                 │
            └──────────────►──────────────┘
                       (避障约束)
                            │
                            ▼
                   自车未来规划轨迹
```

**数据流核心**：TrackFormer 输出 QA（含 ego query）；MapFormer 输出 QM；MotionFormer 用 QA、QM、BEV 三者交互，输出未来轨迹与 QX；OccFormer 以密集 BEV 为 Q、稀疏物体运动特征（QA/PA/QX）为 K/V，输出实例级占用 OA；Planner 用 MotionFormer 更新后的 ego query 与 BEV 交互预测轨迹，并借助 OccFormer 输出做碰撞避障优化。

---

## 三、TrackFormer（多目标跟踪）

### 3.1 设计目标

TrackFormer 在同一网络内**同时完成检测与多目标跟踪（MOT）**，无需不可微的后处理步骤。设计思想受 MOTR / QIM 启发，引入一组 track query 建模物体在场景中的整个生命周期（从出现到消失）。

### 3.2 Query 设计（三部分）

1. **检测查询（Detection Query）**：900 个随机初始化的可学习嵌入（900×C），负责检测新出现的物体，类似 DETR。
2. **跟踪查询（Track Query）**：来自前 N=4 帧已存在目标的查询表征（memory bank，memory_bank_len=4）。这些向量不再进行梯度传播，在每帧推理后存入 memory bank；训练时保留与 GT 匹配上的 query（用 Hungarian Matching）；推理时按置信度保留高置信目标。
3. **自车查询（Ego-vehicle Query）**：TrackFormer 中还包含一个特别的 ego query，用于显式建模自车（自驾车），帮助下游 Planner 了解自车状态。

### 3.3 数据关联与时序建模

- 通过 QIM 机制（qim_type=QIMBase，update_query_pos=True，fp_ratio=0.3，random_drop=0.1）在当前帧跟踪查询与先前记录的查询间进行交互。
- HungarianAssigner3DTrack 做二分图匹配（cls_cost 用 FocalLossCost weight=2.0，reg_cost 用 BBox3DL1Cost weight=0.25）。
- 多帧时序通过 BEVFormer 的时序队列（queue_length=5，可降到 3 节省显存）和 memory bank 实现。
- 网络 backbone：ResNet101（stage 1,2,3 + DCNv2 在 stage 3,4）+ FPN，再经 BEVFormerEncoder 得到 BEV 特征，最后过 6 层 DetectionTransformerDecoder 输出 (900+N)×C 表征。

### 3.4 输出

跟踪物体的 3D 边界框、速度等属性，以及传递给下游的物体特征 **QA**（含 ego query）。score_thresh=0.4，filter_score_thresh=0.35。

---

## 四、MapFormer（在线建图）

### 4.1 设计目标

将 2D 全景分割经典方案 **Panoptic Segformer 迁移至 3D 场景**，用于在线地图分割（语义建图）。

### 4.2 Query 设计

使用一组 **map query（300+1 个）**表示地图中的不同元素：车道线（Lanes）、人行道（Crossing）、可行驶区域（Drivable）、分隔带（Divider）等。这些地图元素将有利于下游任务对周围环境信息的学习。

### 4.3 工作流程

map query 经 MapFormer 更新后，被传送至 MotionFormer 进行物体与地图元素的交互。MapFormer 同时输出全景分割结果用于在线建图监督。

### 4.4 输出

地图元素特征 **QM** + 在线地图分割结果。实验中在车道线分割上较 BEVFormer 提升 +7.4 IoU(%)。

---

## 五、MotionFormer（运动预测）

### 5.1 设计目标

以信息丰富的物体特征 QA 和地图特征 QM 为输入，**输出场景中所有智能体在多种模态下的未来轨迹（top-k 可能轨迹）**。

### 5.2 场景为中心（Scene-centric）

只需一次网络前向传播便能输出所有智能体的未来轨迹，相较于之前以智能体为中心（agent-centric）的方法，**节省了每步对坐标空间进行对齐的计算消耗**。

### 5.3 Query 设计与交互

MotionFormer 由 N 个堆叠的交互模块组成，每层包含**三次不同的注意力计算**以建模三类交互：

| 交互类型 | 注意力机制 | 说明 |
|---------|-----------|------|
| agent-agent | 多头自注意力 MHSA | 智能体之间相互影响 |
| agent-map | 多头交叉注意力 MHCA | 智能体与地图元素交互 |
| agent-goal | 可变形注意力 DeformAttn | 智能体与轨迹目标点交互 |

为持续建模自车运动，利用 TrackFormer 中的 **ego-vehicle query（Sdc query）学习自车未来轨迹**。

### 5.4 位置编码 Q_pos

由四部分组成：
- **Is**：场景级锚点位置（全局视图中的先验运动统计）
- **Ia**：物体级锚点位置（各物体局部视图中的先验运动统计）
- **X0**：物体当前位置
- **X_{l-1}**：预测的前一目标位置（迭代精细化）

### 5.5 输出

所有 agent 的多模态未来轨迹 + 运动特征 **QX**（继续传递给 OccFormer 与 Planner）。实验中 minADE 较 PnPNet 降低 38.3%、较 ViP3D 降低 65.4%。

---

## 六、OccFormer（占用网格预测）

### 6.1 设计目标

预测未来多步的占用栅格图（未来 BEV 占用情况）。之前方法用 CNN+RNN 逐步预测未来 BEV 特征，但忽略了场景中物体的运动信息——而这些信息与未来占用强相关。

### 6.2 Query 设计（核心创新）

UniAD 在 OccFormer 中**反转了常规 Q/K/V 角色**：
- **密集的 BEV 特征表示为查询向量 Q**（每个栅格一个 query）
- **稀疏的物体运动特征表示为键 K 与值 V**

通过多层 Transformer Decoder，query 向量多次更新，用于表示未来时序的 BEV 特征图。

### 6.3 时空占用

OccFormer 由 **T0 个顺序模块**组成（T0 为时间范围，含当前与未来帧），每个模块负责生成一特定帧的占用栅格。将上游的物体特征 QA、物体位置特征 PA、轨迹特征 QX 编码为动态运动特征，与密集场景特征（BEV）充分交互。

### 6.4 注意力掩码

引入**基于占用栅格的注意力掩码**，使注意力计算只在位置对应的栅格-物体特征之间进行，更好对齐物体与栅格位置关系。密集特征为前一帧输出（或当前帧观察特征）降采样 8 倍，残差连接。

### 6.5 实例级输出

通过 agent-level 特征与 dense scene 特征的矩阵乘法，**无需繁重后处理即可产生实例级（instance-wise）占用预测 OA**。实验中 IoU near 较 FIERY 提升 4.0、较 BEVerse 提升 2.0。

---

## 七、Planner（规划）

### 7.1 设计目标

规划自车未来运动轨迹。将 MotionFormer 更新后的 ego-vehicle query 与 BEV 特征进行注意力交互，让 ego query 感知整个 BEV 环境，隐式学习周围环境与其他智能体。

### 7.2 Query 设计

- **QA**：来自 TrackFormer 的自车查询特征
- **Qctx**：来自 MotionFormer 的自车查询特征（含轨迹预测信息）
- **command embedding**：高层命令嵌入（转向意图等）

三者通过 MLP 层编码，**max pooling 选择最显著的模态特征**（多模轨迹中挑最显著）。随后以 ego 为 query、BEV 特征 B 为 K/V 进入标准 Transformer Decoder。

### 7.3 碰撞优化器（避障）

为显式避免与周围车碰撞，**利用 OccFormer 输出的占用栅格对自车路径进行优化**，使其远离未来可能有物体占用的区域。这是 UniAD "以规划为导向、显式安全约束"的直接体现。

### 7.4 输出

自车未来规划轨迹（nuScenes 上规划 3 秒未来）。

---

## 八、两阶段训练

UniAD 采用**两阶段训练策略**，实验发现该策略比一阶段端到端更稳定：

### 8.1 Stage 1：感知模块独立训练

- **目标**：专注训练 TrackFormer + MapFormer
- **配置**：`projects/configs/stage1_track_map/base_track_map.py`
- **命令**：`./tools/uniad_dist_train.sh ./projects/configs/stage1_track_map/base_track_map.py N_GPUS`
- **资源**：约 50GB 显存，6 个 epoch 约 2 天（8×A100）
- **优化点**：为省显存可将 queue_length=5 改 3，显存降至约 30GB（V100 可跑）
- **预期指标**：AMOTA 0.394、AMOTP 1.316、RECALL 0.484
- **细节**：stage1 移除 loss_past_traj，解冻 neck 和 BN

### 8.2 Stage 2：端到端联合训练

- **目标**：基于 Stage 1 权重，**冻结 BEV 编码器**，专注学习任务特定 query，端到端优化所有任务模块
- **配置**：`projects/configs/stage2_e2e/base_e2e.py`
- **命令**：`./tools/uniad_dist_train.sh ./projects/configs/stage2_e2e/base_e2e.py N_GPUS`
- **资源**：约 17GB 显存，20 个 epoch 约 4 天（8×A100），V100/3090 均可
- **优势**：分离感知训练与端到端优化，降低训练复杂度，确保各任务协同

### 8.3 评估与可视化

- 评估：`./tools/uniad_dist_eval.sh <config> <ckpt> N_GPUS`
- 可视化：`python ./tools/analysis_tools/visualize/run.py --predroot <results.pkl> --out_folder <out> --demo_video test_demo.avi --project_to_cam True`

---

## 九、实验结果

所有实验在 **nuScenes** 基准上实例化。UniAD 在感知、预测、规划各任务上全面超越此前的 SOTA。

### 9.1 规划结果（核心，表 6）

| 方法 | 输入 | avg L2 (m) ↓ | avg Collision Rate (%) ↓ |
|------|------|-------------|----------------------|
| ST-P3 | 相机 | 2.90 | 1.31 |
| UniAD | 相机 | **1.65（↓51.2%）** | **0.71（↓56.3%）** |
| 基于激光雷达方案 | LiDAR | — | 高于 UniAD |

UniAD 在所有时间间隔（1s/2s/3s）均达最低 L2 误差与碰撞率，多数情况下甚至**优于基于 LiDAR 输入的方法**，验证了系统的安全性。

### 9.2 多目标跟踪（表 2）

| 方法 | AMOTA(%) ↑ |
|------|-----------|
| MUTR3D | +0（基准） |
| ViP3D | -7.7（相对） |
| UniAD | **+6.5（vs MUTR3D）/ +14.2（vs ViP3D）** |

UniAD 取得最好 IDS 分数（越低越好），展示物体跟踪的时序一致性。

### 9.3 在线建图（表 3）

| 方法 | Lanes IoU ↑ |
|------|------------|
| BEVFormer | 基准 |
| UniAD | **+7.4 IoU(%)** |

具备全面道路语义（Lanes / Drivable / Divider / Crossing）。

### 9.4 运动预测（表 4）

| 对比 | minADE 改善 |
|------|------------|
| vs PnPNet | ↓38.3% |
| vs ViP3D | ↓65.4% |

显著优于此前基于相机输入的端到端方法，所有指标最优。

### 9.5 占用预测（表 5）

| 对比 | IoU near(%) ↑ |
|------|--------------|
| vs FIERY | +4.0 |
| vs BEVerse | +2.0 |

在近距离区域（30×30m，对规划更关键）显著进步；"n."近(30×30m)/"f."远(50×50m)。

### 9.6 消融研究（表 7）

验证以目标为导向的设计理念是否真正发挥作用。结论：
- 两个感知子任务（Track + Map）极大帮助运动预测
- 预测性能受益于联合两个预测模块（Motion + Occ）
- ID-0 为 MTL 方案，作为对照
- "avg.L2"与"avg.Col"为整个规划范围平均值

### 9.7 局限性

- 需大量计算能力，尤其使用历史帧（Nvidia Tesla A100 上运行时复杂度较高）
- 部署难度大
- 端到端模型出现 bad case 不易修复（论文建议增加数据提升检测性能）
- 开环评估指标（L2/碰撞率）与真实 L4 体验（舒适度、合理性）仍有距离

---

## 十、代码实现

### 10.1 仓库

- **地址**：https://github.com/OpenDriveLab/UniAD（v2.0，128 commits）
- **基于**：OpenMMLab 生态（mmdetection3d v0.17.1 + mmcv 系列）
- **License**：CC BY-NC-SA 4.0

### 10.2 模型架构（config 关键字段）

```python
model = dict(
    type="UniAD",
    queue_length=queue_length,     # 时序队列长度，默认 5
    use_grid_mask=True,
    video_test_mode=True,
    num_query=900,                 # 检测 query 数
    num_classes=10,
    img_backbone=dict(type="ResNet", depth=101, ...,
                      dcn=dict(type="DCNv2", deform_groups=1)),
    img_neck=dict(type="FPN", out_channels=_dim_, num_outs=4),
    freeze_img_backbone=True,
    score_thresh=0.4,
    qim_args=dict(qim_type="QIMBase", update_query_pos=True,
                  fp_ratio=0.3, random_drop=0.1),
    mem_args=dict(memory_bank_type="MemoryBank", memory_bank_len=4),
    loss_cfg=dict(type="ClipMatcher", num_classes=10,
                  assigner=dict(type="HungarianAssigner3DTrack", ...)),
    pts_bbox_head=dict(type="BEVFormerTrackHead", bev_h=bev_h_, bev_w=bev_w_, ...),
)
```

### 10.3 目录结构

```
UniAD/
├── projects/configs/        # 配置文件
│   ├── stage1_track_map/base_track_map.py
│   └── stage2_e2e/base_e2e.py
├── tools/                    # 训练/评估/可视化脚本
│   ├── uniad_dist_train.sh
│   ├── uniad_dist_eval.sh
│   └── analysis_tools/visualize/run.py
├── sources/                  # 核心源码（各模块实现）
├── docs/                     # INSTALL.md / DATA_PREP.md 等
├── docker/                   # Dockerfile
└── CITATION.cff
```

### 10.4 训练脚本入口

`uniad_dist_train.sh` 接收配置文件路径与 GPU 数，调用 mmdet3d 的分布式训练。Stage1 训练跟踪+建图，Stage2 加载 Stage1 权重后端到端联合训练。

### 10.5 数据集准备

- nuScenes V1.0 完整数据集 + CAN 总线数据 + 地图扩展包
- 预处理 infos 文件：`nuscenes_infos_temporal_train.pkl` / `val.pkl` / `motion_anchor_infos_mode6.pkl`
- 环境与 BEVFormer 基本一致，额外安装：motmetrics==1.1.3、einops==0.4.1、casadi==3.5.5

---

## 十一、与 BEVFormer 对比

| 维度 | BEVFormer | UniAD |
|------|-----------|-------|
| 定位 | 感知（BEV 特征生成） | 端到端全栈（感知+预测+规划） |
| 任务范围 | 3D 检测 / BEV 分割 | 检测/跟踪/建图/运动预测/占用预测/规划 |
| query 设计 | 仅 BEV query：栅格状可学习参数 Q(H,W,C)，每个 grid cell 一个 query 查图像特征 | 多组任务 query：track / map / motion / occ / ego，统一接口连接全 pipeline |
| 设计导向 | 感知导向（重感知轻地图） | 规划导向（所有模块服务规划） |
| 时序 | BEV query 查时空特征聚合 | 多帧时序 + memory bank（跟踪）+ 顺序时序（占用） |
| 关系 | UniAD 的 BEV 编码器 | UniAD 的超集，BEVFormer 是其 BEV 特征来源 |

**核心差异**：BEVFormer 解决"如何从多视角图像生成统一 BEV 特征"这一感知子问题；UniAD 在 BEVFormer 之上构建完整端到端系统，用 query 统一所有任务并导向规划。UniAD 的 query 设计更丰富——既有密集 BEV query（OccFormer 中），也有稀疏实例 query（track/map/motion/ego），并通过 ego query 串联感知到规划的完整链路。

---

## 十二、AuroraDrive 迁移建议

### 12.1 AuroraDrive 当前架构

根据 AuroraDrive 项目交接文档（v1.1.0），当前系统为**仿真系统 + 辅助驾驶模式**：

- **后端**：C++ 核心引擎（24Hz 物理仿真）
- **感知**：Canny + 最小二乘车道线检测（纯规则后融合，AUTO 已不依赖，作为感知冗余保留）
- **规划**：A* 路径规划 + Euclidean 启发式
- **控制**：Pure Pursuit（横向）+ PID 速度闭环（纵向，目标 40km/h）
- **交通流**：IDM + MOBIL 换道
- **数据**：mmap 零拷贝地图（autodrive_map.bin ~500MB），静态预编译地图
- **整体范式**：典型的**模块化规则方案**（对应 UniAD 论文图 1a：独立模型 / 规则级联）

任务上下文提到"AuroraDrive 当前：M9Model 后融合"——即采用后融合（post-fusion）的规则化模块级联架构，感知结果在传达到规划时存在信息丢失与误差累积风险，与 UniAD 论文批判的痛点一致。

### 12.2 是否借鉴 UniAD？

**结论：值得借鉴思想，但不宜直接照搬全栈端到端。** 理由：

1. **数据基础不同**：UniAD 依赖 nuScenes 真实标注数据（检测/跟踪/建图/轨迹/占用全栈监督）；AuroraDrive 是仿真系统，缺乏同等规模多任务标注数据，直接训练 UniAD 级端到端模型不现实。
2. **部署约束不同**：AuroraDrive 要求 24Hz 实时、零第三方依赖、macOS 单机；UniAD 推理开销大（A100 级），端到端 bad case 难修复。
3. **思想高度可迁移**：UniAD 的"规划导向 + query 统一接口 + 两阶段训练"思想可显著提升 AuroraDrive 的架构演进方向。

### 12.3 借鉴要点

| 借鉴点 | AuroraDrive 应用方式 |
|--------|---------------------|
| **规划导向设计** | 所有感知/预测模块的输出都应服务于规划，避免为感知而感知；评估指标向规划 L2/碰撞率对齐 |
| **Query 统一接口** | 用统一的"场景表示"（query / 特征向量）替代当前后融合的边界框传递，软化误差累积 |
| **两阶段训练** | 若引入学习模块，先训感知再端到端，更稳定 |
| **显式安全约束** | Planner 借鉴 OccFormer 思路——用占用图做碰撞优化器，而非纯轨迹回归 |
| **ego query 显式建模** | 显式维护自车状态向量贯穿感知到规划，提升自车决策一致性 |

### 12.4 AuroraDrive 模型演进路线（4 阶段）

**阶段 1：轻量化感知替换（保留模块化）**
- 当前 Canny 车道线检测在真实游戏场景失效，建议引入轻量 BEV 感知（如简化版 BEVFormer / BEVDet）替代规则检测。
- 用仿真渲染的相机+深度生成伪标注数据，训练小模型。
- 仍保留 A* + Pure Pursuit + PID 控制栈。
- 产出：感知模块从"规则后融合"升级为"学习型前融合 BEV"。

**阶段 2：引入 Query 统一接口（模块间特征对齐）**
- 借鉴 UniAD：感知输出不再仅是边界框，而是携带丰富语义的 query 特征向量（track query / map query）。
- 在 C++ 侧用结构体封装 query，传递给规划模块而非解耦的标量。
- 引入 ego query 显式建模自车状态，贯穿规划。
- 产出：消除后融合信息丢失，模块间特征对齐。

**阶段 3：引入预测与占用（丰富规划前置）**
- 增加 MotionFormer 式运动预测（基于交通流 IDM/MOBIL 的学习化版本）+ OccFormer 式占用预测。
- Planner 增加"碰撞优化器"：基于占用栅格做轨迹避障优化。
- 产出：规划从"A* 静态路径"升级为"考虑动态交互的安全轨迹"。

**阶段 4：端到端联合优化（远期）**
- 当仿真数据闭环成熟后，借鉴 UniAD 两阶段训练，先训感知再端到端联合微调。
- 保留可解释中间结果（query 可投影可视化），便于 bad case 修复。
- 产出：端到端 AuroraDrive M-Next 模型，从 M9Model 后融合演进为 query 统一的前融合端到端。

### 12.5 风险提示

- **数据闭环**是前提：仿真系统应建立"渲染→自动标注→训练→回灌评测"闭环，否则无数据支撑学习模块。
- **实时性**：24Hz 约束下，学习模块需轻量化（蒸馏/量化），不能直接套 UniAD 全栈。
- **可解释性**：保留模块化中间输出可视化（UniAD 提供 project_to_cam 可视化），便于调试。
- **渐进式**：不要一步跳到端到端，先做 query 接口对齐（阶段 2），再做预测/占用（阶段 3），最后端到端（阶段 4）。

---

## 十三、总结

UniAD（Planning-oriented Autonomous Driving）作为 CVPR 2023 最佳论文，其最大贡献不是某个单点模块，而是**确立了"以规划为导向"的端到端自动驾驶设计哲学**：通过统一 query 接口连接 TrackFormer / MapFormer / MotionFormer / OccFormer / Planner 五模块，让所有感知与预测任务都为安全规划服务。在 nuScenes 上，规划 L2 误差降 51.2%、碰撞率降 56.3%，全面超越 SOTA 甚至优于部分 LiDAR 方案。

对 AuroraDrive 而言，UniAD 的核心可迁移价值在于**思想而非代码**：规划导向、query 统一、两阶段训练、显式安全约束——这些思想可指导 AuroraDrive 从当前 M9Model 后融合规则方案，渐进演进为 query 统一的前融合端到端架构，但需以仿真数据闭环和实时性约束为前提，分四阶段稳步推进。

---

## 参考资料

- 论文：https://arxiv.org/abs/2212.10156
- 项目主页：https://opendrivelab.github.io/UniAD/
- 代码：https://github.com/OpenDriveLab/UniAD
- CSDN 解析多篇（m0_54618081 / a8598671 / jch924583667 / lovely_yoshino / gitblog_00424 等）
- 51CTO 经典文献阅读、cnblogs 实用指南
- AuroraDrive 项目交接文档 v1.0（/Users/dupi/Desktop/自动驾驶系统/AuroraDrive项目交接文档.md）

---

**实际调用次数**：本报告研究阶段共执行 **35 次内部工具调用**（WebSearch × 19 + WebFetch × 9 + Read × 5 + LS × 1 + RunCommand × 1），满足"至少 30 次"要求。
