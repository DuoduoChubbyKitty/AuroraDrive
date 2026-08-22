# BEVFormer v1 与 v2 论文深度研究报告

> 研究主题：BEVFormer 系列的时空 Transformer BEV 感知范式，含 SCA/TSA 架构剖析、v1 与 v2 对比、与 Apollo BEV 的差异，以及对 AuroraDrive 后融合架构升级 BEV 的迁移路线建议
> 研究方法：WebSearch + WebFetch，覆盖 arXiv 论文页、GitHub 官方仓库、ECCV/CVPR 解析、CSDN/腾讯云架构详解，并结合本地 `Apollo研究/01g_perception_bev.md` 源码级分析
> 核心结论：**BEVFormer v1 以 SCA+TSA 时空 Transformer 把纯视觉 BEV 检测推到 nuScenes 测试集 56.9% NDS（较 DETR3D +9.0），v2 引入透视监督与两阶段检测器适配现代图像骨干达到 63.4% NDS（CVPR 2023）；Apollo 开源版走的是 PETR 路线而非 BEVFormer；AuroraDrive 应采用"渐进式升级"，借鉴 SCA+TSA 思想分阶段替换后融合**

---

## 一、BEVFormer v1 概述

### 1.1 论文信息

- **标题**：BEVFormer: Learning Bird's-Eye-View Representation from Multi-Camera Images via Spatiotemporal Transformers
- **发表**：ECCV 2022
- **arXiv**：[2203.17270](https://arxiv.org/abs/2203.17270)（2022-03-31 v1，2022-07-13 v2）
- **作者**：Zhiqi Li, Wenhai Wang, Hongyang Li, Enze Xie, Chonghao Sima, Tong Lu, Qiao Yu, Jifeng Dai（OpenDriveLab / 商汤科技 / 南京大学）
- **代码**：[github.com/fundamentalvision/BEVFormer](https://github.com/fundamentalvision/BEVFormer)（Apache-2.0，基于 MMDetection3D）

### 1.2 核心思想

自动驾驶的 3D 视觉感知（3D 检测、地图分割）依赖多相机输入，但传统做法是"每路相机独立检测→后处理融合"，相机间信息不交互、视角异构、笨拙低效。BEVFormer 受特斯拉纯视觉方案启发，提出**用一个统一的时空 Transformer 直接把多视角图像特征映射到鸟瞰图（BEV）空间**，在 BEV 视角下统一支撑多种感知任务。

关键设计取舍是**回避显式深度估计**。此前基于 LSS（Lift-Splat-Shoot）的方法需要预测深度分布把 2D 特征"抬升"成 3D，但从不准确的 2D 深度生成的 BEV 特征位置会漂移，影响性能。BEVFormer 选择第四条路：**不显式估计深度，而是通过 attention 自适应地从多视角图像中聚合 BEV 网格所需的特征**，让网络自己学习"该从哪个相机的哪个像素取什么信息"。

对于时序信息，简单叠加多帧会引入环境变化的干扰且增加计算量，因此 BEVFormer 采用 RNN 式的**循环时序融合**，逐帧迭代地融入历史 BEV 特征。论文的主要贡献是实现了端到端的时空 BEV 生成器，统一支撑 3D 检测与地图分割，并在 nuScenes 测试集达到 **56.9% NDS**，比此前最佳方法（DETR3D 47.9% NDS）高 9.0 个点，号称与 LiDAR 基线相当；同时显著提升速度估计精度与低能见度条件下的目标召回。

---

## 二、BEVFormer v1 架构总览

BEVFormer 整体是一个 encoder-decoder 的时空 Transformer。前置图像 backbone（ResNet/R101-DCN 或 VoVNet）提取多尺度 2D 图像特征，经 FPN 得到多视角特征图；随后进入 BEV 编码器，逐层交替执行 **TSA（Temporal Self-Attention）** 与 **SCA（Spatial Cross-Attention）**，把 BEV Queries 不断更新为携带时空信息的 BEV 特征图；最后接检测头（Deformable DETR 风格的 object query 解码器）做 3D 检测，或接分割头做地图语义分割。编码器默认 6 层。

```
┌─────────────────────────────────────────────────────────────────┐
│                     BEVFormer v1 整体架构                       │
│                                                                 │
│  多视角相机(6路) ──► Image Backbone(ResNet/VoVNet) ──► FPN      │
│                                              │                  │
│                                              ▼ 多尺度图像特征   │
│   ┌──────────────────────── BEV Encoder (×6层) ──────────────┐  │
│   │                                                          │  │
│   │   BEV Queries(H×W×C, 可学习网格)                          │  │
│   │        │                                                 │  │
│   │        ▼                                                 │  │
│   │   ┌─────────────┐      历史帧BEV特征(上一时刻)            │  │
│   │   │   TSA 时序   │ ◄── ego-motion对齐后的历史BEV          │  │
│   │   │  Self-Attn   │ ──► 融合了时序的BEV query              │  │
│   │   └──────┬──────┘                                        │  │
│   │          ▼                                               │  │
│   │   ┌─────────────┐      多视角图像特征                     │  │
│   │   │   SCA 空间   │ ◄── 3D参考点投影采样(deformable)       │  │
│   │   │ Cross-Attn   │ ──► 携带空间特征的BEV query            │  │
│   │   └──────┬──────┘                                        │  │
│   │          ▼                                               │  │
│   │      更新后的 BEV 特征图 ──► 存为下一帧的历史BEV           │  │
│   └──────────────────────────────────────────────────────────┘  │
│                          │                                      │
│          ┌───────────────┼───────────────┐                      │
│          ▼                               ▼                      │
│   3D检测头(Deformable DETR)      地图分割头(Panoptic SegFormer) │
│   object query解码→3D框           BEV特征→语义图                │
└─────────────────────────────────────────────────────────────────┘
```

注意执行顺序：在每个编码器层中**先 TSA 后 SCA**。TSA 让 BEV query 先获得时序先验（"上一帧这里有什么"），再由 SCA 从图像中补充当前帧的空间证据，二者轮番迭代 6 层，最终 BEV 特征图同时具备时序连续性与空间细节。

---

## 三、SCA（Spatial Cross-Attention）详解

SCA 是 BEVFormer 把"多视角 2D 图像特征"聚合到"3D BEV 网格"的核心机制，基于**可变形注意力（Deformable Attention）**改进，避免多相机全局 attention 的巨大算力开销。

### 3.1 设计动机

多视角相机输入若做全局 cross-attention，每个 BEV query 要和所有相机所有像素计算注意力，计算量爆炸。SCA 的思路是**自上而下（top-down）**：为每个 BEV query 生成 3D 参考点，投影回图像，只在这些投影点附近的局部区域做 deformable 采样，从而把全局 attention 降为局部稀疏采样。

### 3.2 3D Reference Points 生成

BEV 网格每个 (x, y) 位置代表真实世界一小块区域。SCA 不只用一个 2D 点，而是把它提升为一根**柱体（pillar）**：在 (x, y) 处沿 z 轴（高度方向）采样 `num_points_in_pillar`（默认 4）个 3D 参考点，覆盖不同高度。这样 BEV query 能从不同高度的图像证据中聚合信息，弥补 BEV 平面丢失的高度维度。

3D 参考点坐标在自车坐标系下定义（典型 BEV 范围 x∈[-51.2, 51.2]m, y∈[-51.2, 51.2]m, z 按高度离散），通过 `torch.linspace` 在归一化的 z 区间均匀生成。

### 3.3 多视角投影与 hit 视图

对每个 BEV query 的每个 3D 参考点，利用**相机内外参**（`img2lidar` 外参 + 相机内参）将其从自车坐标系投影到各相机的 2D 图像平面：

- 投影点落在某相机图像范围内的，称该相机为 **hit 视图**（被击中）；
- 投影到图像范围之外（out of image）的相机，不参与该 query 的采样。

一个 3D 点通常只命中部分相机，因此 SCA 天然实现了"哪个 BEV 网格去哪个相机取特征"的稀疏对应，无需全相机全局注意力。

### 3.4 Deformable 采样与加权聚合

在 hit 视图的投影点附近，deformable attention 会**预测若干偏移量（offsets）**，在投影点周围的局部邻域采样特征，并学习一组**注意力权重**。把同一 BEV query 在多个高度参考点、多个 hit 视图上采到的特征按权重加权求和，聚合回该 BEV query。

整个 SCA 流程可概括为四步：
1. 在 (x, y) 处沿高度采 pillar 的 4 个 3D 参考点；
2. 把 3D 参考点用相机内外参投影到各相机 2D 平面，确定 hit 视图；
3. 在 hit 视图的投影区域用 deformable attention 局部采样特征；
4. 加权融合这些特征，回填到 BEV query。

**不显式估计深度**——网络通过可学习的 offset 与 weight 自适应决定从图像哪个位置取多少信息，深度信息隐含在投影几何与 attention 学习中。这是 BEVFormer 与 LSS 路线（显式预测深度分布）的根本分歧。

---

## 四、TSA（Temporal Self-Attention）详解

TSA 负责**时序融合**，把历史帧的 BEV 特征融入当前帧，提升速度估计精度与遮挡物体检测能力。

### 4.1 历史帧 BEV 特征

BEVFormer 在每个时刻保留上一帧（或前几帧）编码器输出的 BEV 特征图作为"记忆"。由于 BEV 特征已在统一的自车坐标系网格上，时序对齐只需处理自车运动（ego motion）。

### 4.2 Ego Motion 补偿与对齐

不同时刻自车位置不同，同一真实世界位置在两帧 BEV 网格中的网格坐标会偏移。TSA 第一步是用 **ego-motion（帧间运动）** 把历史 BEV 特征变换到当前帧坐标系：根据两帧之间的 ego pose 变换矩阵，对历史 BEV 特征做仿射变换（warp/对齐），使历史特征与当前 BEV 网格在真实世界位置上对齐。若按像素级特征对齐，需指定 x、y 两个方向的偏移量。

### 4.3 Self-Attention 时序采样

对齐后，当前帧 BEV query 与历史 BEV 特征做 self-attention，**同时采样过去帧和当前帧的信息**：query 既关注自身当前位置，也关注历史 BEV 中对应区域，从而把"上一帧这里有什么物体、在怎么动"的先验融入当前特征。

### 4.4 循环迭代

采样完成后通过加权方式把历史特征融合进当前 BEV 视角，得到更鲁棒的特征图。BEVFormer 用 **RNN 式循环**做若干次（默认 4 步）迭代查询，持续地把更长历史的 BEV 信息逐步融入。这种递归结构让时序融合的计算开销可控，避免简单堆叠多帧带来的干扰与算力膨胀。

TSA 是可选模块（论文中 BEVFormer-S 即静态版本，不使用历史 BEV），消融实验表明时序信息能**有效提升速度相关指标（mAVE）**，因为速度本质上需要帧间位移来估计。

---

## 五、BEV Queries 详解

### 5.1 可学习网格

BEV Queries 是一组**可学习的网格状参数**，形状为 `H × W × C`（典型 H=W=200, C=256），是 BEV 特征图的"占位符/容器"。每个位于 (x, y) 的 query 负责表征真实世界中对应的那一小块 BEV 区域。

### 5.2 位置编码

在输入 BEVFormer 编码器前，先把**可学习的位置编码（learnable position embedding）**加到 BEV queries 上，让每个 query 带上其网格坐标的先验位置信息，再开始学习与更新。

### 5.3 数量与分辨率

query 数量 = H × W，对应 BEV 网格分辨率。典型配置沿用 nuScenes 习惯：覆盖范围 x∈[-50m, +50m]、y∈[-50m, +50m]，BEV 网格 200×200，每格 0.5m。这意味着默认 4 万个 BEV query。通过对 Spatial（SCA）和 Temporal（TSA）信息的轮番查询，这些 query 最终演化成携带完整时空特征的 BEV 特征图，供下游检测/分割头使用。

---

## 六、实验

### 6.1 数据集与任务

实验在 **nuScenes** 数据集上进行，覆盖三大任务：
- **3D 目标检测**：nuScenes Detection Task，10 类物体，评价指标 NDS（nuScenes Detection Score，由 mAP 与 mATE/mASE/mAOE/mAVE/mAAE 五项误差加权得到）、mAP；
- **3D 目标跟踪**：nuScenes Tracking Task，评价指标 AMOTA/AMOTP；
- **地图语义分割**：BEV 视角下的 drivable area、pedestrian crossing、walkway、stop line、carpark、lane divider 等类别，评价指标 mIoU。

### 6.2 3D 检测主结果

| 方法（nuScenes test） | Backbone | NDS | mAP |
|---|---|---|---|
| FCOS3D（NeurIPS 2021） | ResNet-101 | 35.8 | 29.8 |
| DETR3D（CoRL 2021） | VoVNet-99 | 47.9 | 41.2 |
| BEVDet（2021, LSS 路线） | Swin-Tiny | 39.2 | 31.2 |
| BEVDepth（旷视, LSS+LiDAR监督） | VoVNet-99 | 47.0 | 41.1 |
| BEVerse（2022, 多任务） | Swin-Small | — | — |
| **BEVFormer（本文）** | R101-DCN | **56.9** | **48.1** |
| BEVFormer++（Waymo 1st） | — | — | — |

在 **val 集**上 BEVFormer 达 51.7% NDS，超过 DETR3D（42.5% NDS）9.2 个点；test 集 56.9% NDS 比 DETR3D（47.9%）高 9.0 个点，号称与 LiDAR 基线性能相当。BEVFormer 显著提升了**速度估计精度（mAVE）**与**低能见度条件下的目标召回**——这正是时序融合（TSA）带来的增益。

GitHub 官方 Model Zoo 给出的可复现配置（val）：

| Backbone | 方法 | 训练 | NDS | mAP | 显存 |
|---|---|---|---|---|---|
| R50 | BEVFormer-tiny | 24ep | 35.4 | 25.2 | 6500M |
| R101-DCN | BEVFormer-small | 24ep | 47.9 | 37.0 | 10500M |
| R101-DCN | BEVFormer-base | 24ep | 51.7 | 41.6 | 28500M |

### 6.3 与 BEVDet / BEVerse 对比

- **BEVDet** 是 LSS 路线的工程化封装，显式预测深度后 splat 到 BEV，检测头用 CenterPoint。BEVDet-Tiny 在 val 上约 31.2% mAP / 39.2% NDS，算力友好（~215 GFLOPs）适合低算力平台落地，但精度上限低于 BEVFormer。BEVDepth 在 BEVDet 基础上用 LiDAR 点云监督深度，是低算力落地主流。
- **BEVerse** 用 Swin Transformer backbone，做多任务（检测+分割+运动预测），对单相机故障韧性强。
- **BEVFormer** 走 attention 路线（SCA+TSA），不依赖深度估计，精度最高（56.9% NDS test），但 deformable attention + 多层 encoder 对算力要求高，部署难度大于 LSS 路线。

**路线分歧的本质**：LSS/BEVDet 是"自下而上"的几何驱动（显式深度→点云→pooling），BEVFormer 是"自上而下"的 attention 驱动（BEV query 反投影采样）。前者工程简单、低算力友好；后者精度高、时序天然、但对算力与工程化要求高。

### 6.4 地图分割结果

BEVFormer 的 BEV 特征同时支撑地图语义分割，在最具挑战性的**车道分割（lane divider）**上比 Lift Splat 高出 5 个多点，达到 SOTA。这验证了统一 BEV 表征的多任务潜力。

### 6.5 消融实验要点

1. 强 backbone 依然是涨点关键；
2. Local（局部）attention 比 global attention 效果更好且更省时；
3. 时序信息（TSA）必要，能有效提升速度指标；
4. 多任务头在 3D 检测上 OK，但 BEV map 语义分割性能仍较差，不建议强行多任务共享。

---

## 七、BEVFormer v2 概述

### 7.1 论文信息

- **标题**：BEVFormer v2: Adapting Modern Image Backbones to Bird's-Eye-View Recognition via Perspective Supervision
- **发表**：**CVPR 2023**（Vancouver, 2023-06-17~24，pp. 17830-17839，DOI: 10.1109/cvpr52729.2023.01710）
- **作者**：Chenyu Yang, Yuntao Chen, Hao Fei Tian, Chenxin Tao, Xizhou Zhu, Zhaoxiang Zhang, Gao Huang, Hongyang Li, Yu Qiao, Lewei Lu, Jie Zhou, Jifeng Dai
- **arXiv**：2022 年发布（标题中的 "Modern Image Backbones" 指 ConvNeXt/InternImage 等现代骨干）

### 7.2 核心问题与改进

v1 及当时 SOTA 的 BEV 检测器都绑定 **VoVNet** 这类需 DDAD-15M 等大规模深度预训练的骨干，阻碍了蓬勃发展的现代图像骨干（ConvNeXt、InternImage 等）与 BEV 检测器的协同。简单换用 ImageNet 预训练的 ConvNeXt-XL，性能仅与 DDAD-15M 预训练的 VoVNet-99 相当，参数却多 3.5 倍。

原因有二：
1. **领域差距**：自然图像预训练骨干对自动驾驶 3D 场景（尤其深度）感知不足；
2. **结构复杂**：BEVFormer 的视图编码器+多层 transformer 把 3D 框/类别监督信号与 backbone 隔离，梯度在 3D→2D 反传中失真，扭曲了通用 2D 骨干的梯度流。

v2 的核心改进是引入**透视监督（Perspective Supervision）**：在 backbone 上直接接一个透视 3D 检测头，把检测损失直接施加在图像特征上，引导骨干学习 2D 任务中缺失的 3D 知识（深度、方向、速度），极大方便模型优化。最终在 nuScenes 测试集达到 **63.4% NDS**，显著超越此前 SOTA。

---

## 八、BEVFormer v2 改进详解

### 8.1 总体架构

v2 是一个**两阶段 BEV 检测器**，由五部分组成：图像骨干、透视 3D 检测头、空间编码器、改进型时间编码器、BEV 检测头。相比 v1，**除空间编码器外所有组件都做了更改**：
- 所有图像骨干**不再用任何自动驾驶/深度估计数据集预训练**；
- 引入透视 3D 检测头，既促进 2D 骨干适应，又为 BEV 头生成对象 proposals；
- 新的时域 BEV 编码器，更好融合长期时序信息；
- BEV 检测头接受**混合对象查询**。

### 8.2 透视监督与透视损失

在 BEVFormer 中，BEV 编码器为每个网格分配 3D 参考点、投影到多视角 2D、用 SCA 聚合，解码器是 Deformable DETR——这是**间接监督**，梯度在 3D-2D 传递中失真，监督信号与 backbone 训练分离。此前未暴露此问题是因为骨干要么规模小、要么用了单目 3D 预训练。

v2 在骨干上构建**透视 3D 检测头**（采用 DD3D 实现，带相机感知深度参数化），以图像特征为输入直接预测 3D 框的中心位置、尺寸、朝向及投影中心度。该头的损失（**透视损失 L_pers**）作为辅助检测损失，与 BEV 头导出的原始损失（**BEV 损失 L_bev**）联合训练，权重 λ_bev = λ_pers = 1。透视损失采用类似 FCOS3D 的形式。

### 8.3 改进型时间编码器（Revamped Temporal Encoder）

v1 的 TSA 用周期性时序自注意力关联历史 BEV 特征，但**缺乏长期时序信息**——简单把重复步数从 4 增到 16 不会带来额外性能增益。v2 改为：先把历史特征通过变换矩阵转换到当前帧，然后**沿通道维度把历史 BEV 特征与当前 BEV 特征 concat**，再用残差块降维。为保持与原设计类似的计算复杂度，使用相同数量的历史 BEV 特征但**增大采样间隔**，从而捕获更长期的时序。新编码器还解锁了在离线 3D 检测中利用未来 BEV 特征的可能性。

### 8.4 两阶段检测与混合对象查询

从不同视角（透视 vs BEV）获得结果有三种思路：丢弃透视头预测只取 BEV 头；用 NMS 启发式组合两组预测；设计两阶段 pipeline。v2 选第三种。

BEV 头是 DETR 解码器，用一组 learned embedding 作 object query，但随机初始化的 embedding 要花很长时间学习可能位置，且 object query 对所有图像固定，障碍物空间分布密集时不准确。v2 把透视头预测结果滤波后编码进解码器 object query，组成两阶段处理：透视头 proposals 的投影框中心（BEV 平面上的 2D 点）作为参考点，与位置编码生成的参考点联合——即**混合对象查询**。这样混合 query 既提供"高概率存在"的候选信息帮助 BEV 头定位，又保留少量原始学习参考点以捕获因遮挡/跨视图边界漏检的物体。

注意：第一阶段建议不一定来自透视检测器（也可来自另一 BEV 检测器），但实验表明**只有透视预测对第二阶段 BEV 头有帮助**。

### 8.5 实验与性能

骨干实验覆盖 ResNet、DLA、VoVNet、InternImage，均用 COCO 2D 检测预训练初始化。透视头用 DD3D，BEV 头用 Deformable DETR（也对比了 Group DETR）。优化器 AdamW，基础学习率 2e-4，逐层学习率衰减。

关键发现：
- **透视监督有效性**：BEV & Perspective 模型比 BEV Only 收敛快得多；即使更长训练，BEV Only 与之差距仍约 72 个 epoch 无法消除，证明仅靠 BEV 监督无法很好适配图像骨干。
- **泛化性**：透视监督可推广到不同架构与模型大小，是无需 3D 预训练适配大规模图像骨干的通用方案。
- **单目 3D 预训练不再必要**：InternImage-B（与 V2-99 参数量相当）配合透视监督即可超越用 DDAD 深度预训练的 VoVNet-99。
- **检测头选择**：透视头 DD3D 优于 DETR3D（密集直接监督对 BEV 模型更有帮助）。
- **最终性能**：nuScenes 测试集 **63.4% NDS**，显著优于 v1。

GitHub Model Zoo 中 v2 可复现配置（R50 backbone）：

| 方法 | 训练 | NDS | mAP |
|---|---|---|---|
| BEVformerV2-t1-base | 24ep | 42.6 | 35.1 |
| BEVformerV2-t1 | 48ep | 46.5 | 39.5 |
| BEVformerV2-t2 | 48ep | 52.6 | 43.1 |
| BEVformerV2-t8 | 24ep | 55.3 | 46.0 |

---

## 九、v1 vs v2 对比

| 维度 | BEVFormer v1 | BEVFormer v2 |
|---|---|---|
| 发表 | ECCV 2022 | CVPR 2023 |
| arXiv | 2203.17270 | 2022 年发布 |
| 核心创新 | SCA + TSA 时空 Transformer | 透视监督 + 两阶段检测器 |
| 监督方式 | 仅 BEV 损失（间接） | BEV 损失 + 透视损失（直接+间接） |
| 图像骨干 | VoVNet/R101-DCN（需深度预训练） | ResNet/DLA/VoVNet/InternImage（COCO 2D 预训练即可） |
| 时序编码器 | TSA 循环（4步，短期） | 改进型：concat+残差，增大采样间隔（长期） |
| 检测头 | Deformable DETR 单阶段 | 两阶段：透视头(DD3D) + BEV头(混合object query) |
| 空间编码器 | SCA（保留） | SCA（保留，唯一未改组件） |
| 深度依赖 | 隐式（无显式深度） | 隐式 + 透视头相机感知深度参数化 |
| 收敛速度 | 慢（需深度预训练补偿） | 快（透视监督加速） |
| nuScenes test NDS | 56.9% | **63.4%** |
| 适用场景 | 学术 SOTA、时序多任务（检测+分割） | 现代骨干适配、追求更高精度、可获取未来帧的离线检测 |
| 工程复杂度 | 高（deformable attn + 多层 encoder） | 更高（两阶段 + 双头），但骨干选择更灵活 |
| 主要贡献 | 确立 attention 路线 BEV 范式 | 打通现代图像骨干与 BEV 检测器的协同 |

**演进逻辑**：v1 解决"如何用 attention 做时空 BEV"，v2 解决"如何让现代图像骨干无需繁琐深度预训练即可适配 BEV"。v2 在保留 v1 空间编码器（SCA）的基础上，通过透视监督打通了骨干的梯度通路，并通过两阶段+混合查询进一步提升检测精度，NDS 从 56.9% 提升到 63.4%。

---

## 十、代码实现

### 10.1 仓库结构

官方仓库 `github.com/fundamentalvision/BEVFormer` 基于 MMDetection3D，Python 99.9%，：

```
BEVFormer/
├── projects/
│   ├── configs/
│   │   ├── bevformer/          # v1 配置（tiny/small/base）
│   │   ├── bevformer_fp16/     # FP16 低显存配置
│   │   └── bevformerv2/        # v2 配置（t1/t2/t8, base）
│   ├── mmdet3d_plugin/         # 核心模型代码
│   │   └── bevformer/
│   │       ├── bevformer.py    # 模型主体（bev_queries 200*200*256）
│   │       ├── spatial_cross_attention.py  # SCA
│   │       ├── temporal_self_attention.py  # TSA
│   │       └── ...
│   └── ...
├── tools/
│   ├── train.py / test.py      # 训练/测试脚本
│   ├── dist_test.sh / dist_train.sh
│   └── create_data.py          # nuScenes 数据预处理（pkl+info）
├── docs/
│   ├── install.md              # 安装（MMCV/MMDet/MMDet3D 版本耦合紧）
│   ├── prepare_dataset.md      # 数据准备
│   └── getting_started.md      # 训练评估
└── README.md                   # Model Zoo + 复现指引
```

### 10.2 训练脚本与流程

- **安装**：依赖 MMCV-full、MMDetection、MMDetection3d，版本耦合严格，需按 docs/install.md 指定版本；还需安装 DCN（Deformable Conv）与 `projects/mmdet3d_plugin/bevformer/ops/bev_pool_v1.py` 的 BEV pool 算子。
- **数据准备**：用 `tools/create_data.py` 生成 nuScenes 的 pkl 与 info（含相机内外参、ego pose、sensor2ego 变换），时序融合强依赖 ego pose 字段。
- **训练**：`tools/dist_train.sh` 多卡训练，如 `bash tools/dist_train.sh <config> <NGPU>`；FP16 配置可降显存（base 默认 28500M 显存）。
- **评估**：`tools/dist_test.sh <config> <ckpt> <NGPU> --eval bbox`。
- **v2 训练**：v2 配置在 `projects/configs/bevformerv2/`，需额外透视头预训练权重（如 R50 在 COCO 上的 FCOS3D/DD3D 权重）。

### 10.3 关键实现要点

- `bev_queries` 形状 `200*200*256`，object_query_embeds `900*512`（检测头用）；
- SCA 中 3D 参考点用 `torch.linspace(0.5, Z-0.5, num_points_in_pillar)` 生成（dim='3d' 分支）；
- 多尺度图像特征通过 FPN 提供，SCA 在多尺度上做 deformable 采样；
- 时序对齐靠 ego pose 变换矩阵对历史 BEV 特征 warp。

---

## 十一、与 Apollo BEV 对比

### 11.1 Apollo 开源版实际走 PETR 路线

值得澄清的是，**Apollo 9.0 开源版 `camera_detection_bev` 模块采用的是旷视 PETR（Position Embedding Transformation）路线，而非 LSS 或 BEVFormer 的 SCA**。源码位于 `modules/perception/camera_detection_bev/detector/petr/bev_obstacle_detector.cc`，模型用 PaddlePaddle 训练（Paddle3D 的 PETRv1），6 路相机输入 + img2lidar 外参，输出 3D Box。

### 11.2 算法差异

| 方案 | View Transformer | 深度估计 | 时序 | BEV 网格 | Apollo 是否采用 |
|---|---|---|---|---|---|
| LSS | Lift+Splat（显式） | 显式预测 | 无（BEVDet4D 扩展） | 显式 200×200 | 园区版/OCC 分支可能用 |
| BEVDet | LSS 工程化 | 显式预测 | BEVDet4D concat | 显式 | 否 |
| **BEVFormer** | **SCA（attention）** | **无（隐式）** | **TSA** | **显式 BEV query** | 否 |
| **PETR** | **3D Pos Embedding** | **无** | **PETRv2** | **无（隐式）** | **是（开源 master）** |
| BEVDepth | LSS + LiDAR 监督 | LiDAR 监督 | BEVDet4D | 显式 | 否 |

**PETR 与 BEVFormer 的核心差异**：PETR 不显式构建 BEV 网格，而是把 3D 空间位置信息编码成 position embedding 注入 2D 图像特征（3D-aware 特征），object query 直接在 3D 语义空间用标准 multi-head attention 回归 3D 框，省去了 BEVFormer 的参考点反投影与 deformable 采样两步。PETR 优点是保留 DETR 端到端特性、工程简单、全局 attention 天然处理多视图重叠；缺点是全局 attention 计算量大、精度上限低于 BEVFormer（PETRv1 val 约 34.79% mAP / 37.02% NDS）。

而 **Apollo-Lite 量产的"4D BEV Transformer + OCC"** 是闭源演进，概念上更接近 BEVFormer（SCA+TSA 时空 Transformer），融合了 PETR 位置编码思想，但未开源。

### 11.3 实现差异

| 维度 | Apollo 开源（PETR） | BEVFormer |
|---|---|---|
| 训练框架 | PaddlePaddle/Paddle3D | PyTorch/MMDetection3D |
| 部署 | Paddle Inference + TensorRT | TensorRT |
| 多相机同步 | 主相机触发+其余取最新帧（软同步） | 数据集级时间戳对齐 |
| ego pose | TransformWrapper + tf2 插值 | 数据预处理写入 pkl |
| 坐标系 | nuScenes→Apollo（绕 z 轴 -90°） | nuScenes 原生 |
| 工程重点 | TRT 量化、坐标系转换 | 学术 SOTA 复现 |

Apollo BEV 在 Orin 上经 TRT INT8（backbone 子图）+ Paddle（后处理）混合优化后单帧约 123ms（~8 FPS），约为 LiDAR（PointPillars-CenterPoint 30-50ms）算力开销的 3-5 倍。

---

## 十二、AuroraDrive 迁移建议

### 12.1 AuroraDrive 当前架构

AuroraDrive 当前是**后融合（late fusion）**架构，核心模型 M9Model：
- **图像分支**：RepVGG backbone 提取 2D 图像特征（RepVGG 训练时多分支、推理时融合为单路 3×3 卷积，部署高效）；
- **点云分支**：PointNet 提取点云特征（逐点 MLP + max pooling）；
- **FusionHead**：在**检测结果层面**融合——图像分支输出 2D 框+类别，点云分支输出 3D 框，FusionHead 做关联（匈牙利匹配/IoU）+ 状态融合（卡尔曼滤波）+ 置信度加权。

这是典型的"各传感器独立检测→后处理融合"范式，与 Apollo 8.0 多阶段相机+LiDAR 后融合思路一致。后融合的局限：模态间信息交互不充分，难以学习跨模态联系，跨相机去重靠后处理 NMS。

### 12.2 是否借鉴 BEVFormer

**结论：应借鉴 BEVFormer 的 SCA + TSA 思想，但不建议一步到位整体替换为 BEVFormer。** 理由：
1. BEVFormer 强依赖 ego pose 做时序对齐（TSA），AuroraDrive 当前 ego pose 链路未知，缺失则时序融合失效；
2. BEVFormer 训练需大规模多相机 3D 标注数据（nuScenes 级），AuroraDrive 现有标注可能不足；
3. BEVFormer 算力开销约为后融合的 3-5 倍，AuroraDrive 算力平台需评估；
4. 极端场景（夜晚/逆光）纯视觉 BEV 显著弱于 LiDAR，若用于 L4 场景安全冗余不足；
5. RepVGG+PointNet 后融合在已知场景已可工作，沉没成本不应轻易废弃。

### 12.3 借鉴 SCA + TSA 思想的具体落点

即便不整体迁移，BEVFormer 的两个核心机制可直接启发 AuroraDrive 改造：
- **SCA 思想**：把"多相机独立 2D 检测→后处理融合"升级为"BEV query 反投影采样多相机特征"，让多相机在特征层交互而非结果层。AuroraDrive 可在图像分支后加一个轻量 SCA-like 模块，用 3D 参考点投影采样多相机特征，统一到 BEV 坐标系，消除后融合的视角异构性。
- **TSA 思想**：用历史 BEV 特征 + ego-motion 对齐做时序融合，提升速度估计与遮挡检测。这要求先建设 ego pose 链路（里程计/SLAM），是 AuroraDrive 升级的前置依赖。

### 12.4 AuroraDrive BEV 升级路线（渐进式）

**阶段一（短期，0-6 个月）：保持后融合，引入特征级中融合**
- 不废弃 M9Model，在 FusionHead 前增加**特征级融合**：把 RepVGG 图像特征与 PointNet 点云特征在 BEV 空间做 feature-level fusion（类似 BEVFusion 思路），保留后融合兜底。
- 关键动作：① 给 LiDAR 检测链路加 BEV 特征图输出；② 图像分支加 LSS-like 显式 BEV 投影（可先用预训练深度）；③ 建设 ego pose 查询链路。
- 收益：精度提升、为 BEV 积累工程经验；代价小。

**阶段二（中期，6-18 个月）：相机分支升级 BEV（SCA+TSA），保留 LiDAR 兜底**
- 相机分支从 RepVGG 2D 检测升级为 **BEVFormer-lite（SCA+TSA，attention 路线）** 或 **BEVDet/BEVDepth（LSS 路线，低算力友好）** 或 **PETRv2（与 Apollo 对齐）**。
- 选型依据：算力紧张选 BEVDet；追求精度与时序多任务选 BEVFormer-lite；与 Apollo 生态对齐选 PETRv2。
- LiDAR 分支保持 PointNet/CenterPoint，与相机 BEV 在 BEV 空间做中融合。
- 关键动作：① 大规模多相机 3D 标注数据采集；② ego pose 链路完善；③ TRT 量化部署。
- 收益：统一坐标系、多任务能力、为去 LiDAR 铺路。

**阶段三（长期，18 个月+）：BEV + OCC 端到端，借鉴 v2 透视监督，按需去 LiDAR**
- 引入占用网络 OCC，BEV+OCC 替代部分 LiDAR 功能，向 Apollo 11.0 范式靠拢；
- 借鉴 **BEVFormer v2 的透视监督**：若引入现代图像骨干（ConvNeXt/InternImage），用透视 3D 头辅助监督加速骨干适配，避免繁琐深度预训练；
- 探索端到端（感知-预测-规划统一 BEV 特征），对标 UniAD。
- 收益：成本下降、泛化提升；代价：大模型训练、算力、可解释性。

### 12.5 触发/推迟升级的信号

**触发加速升级**：目标为 L2/L2+（去 LiDAR 降本）；已具备 ego pose；算力 ≥ Orin 级且支持 TRT INT8；有 ≥50 万帧多相机 3D 标注；需多任务统一输出。

**推迟升级**：L4 Robotaxi（LiDAR 是安全冗余刚需）；算力 <30 TOPS；缺 ego pose 与大规模标注；团队无 MMDetection3D/Paddle3D 经验。

---

## 十三、总结

1. **BEVFormer v1**（ECCV 2022）以 SCA+TSA 时空 Transformer 确立 attention 路线 BEV 范式，回避显式深度，靠 BEV query 反投影采样 + 时序循环融合，达 nuScenes test 56.9% NDS（+9.0 over DETR3D），统一支撑检测/跟踪/分割。
2. **SCA**：BEV query 提升为 pillar（4 个 3D 参考点）→投影到 hit 相机→deformable 局部采样→加权聚合，不显式估计深度。
3. **TSA**：历史 BEV 特征经 ego-motion 对齐→与当前 BEV query 做 self-attention→RNN 式循环迭代（默认 4 步），提升速度估计与低能见度召回。
4. **BEV Queries**：可学习 200×200×256 网格 + 位置编码，轮番被 SCA/TSA 查询演化为时空 BEV 特征图。
5. **BEVFormer v2**（CVPR 2023）引入透视监督（DD3D 透视头 + 透视损失）打通骨干梯度通路，改进型时间编码器（concat+残差，长期时序），两阶段检测（混合 object query），适配现代图像骨干（InternImage/ConvNeXt）无需深度预训练，达 **63.4% NDS**。
6. **v1 vs v2**：v1 解决"如何做 attention BEV"，v2 解决"如何让现代骨干适配 BEV"，NDS 56.9%→63.4%，空间编码器 SCA 是唯一保留组件。
7. **Apollo 开源版用 PETR 而非 BEVFormer**；Apollo-Lite 量产 4D BEV Transformer 概念上更接近 BEVFormer 但闭源。
8. **AuroraDrive 建议"渐进式升级"**：阶段一特征级中融合→阶段二相机分支 BEV（SCA+TSA 思想）+LiDAR 兜底→阶段三 BEV+OCC 端到端（借鉴 v2 透视监督）。核心约束是 ego pose 链路、训练数据、算力平台与安全冗余，不建议一步到位。

---

## 参考资料

- BEVFormer v1 论文：arxiv.org/abs/2203.17270（ECCV 2022）
- BEVFormer v2 论文：CVPR 2023, pp.17830-17839, DOI:10.1109/cvpr52729.2023.01710
- 官方代码：github.com/fundamentalvision/BEVFormer
- BEVFormer v2 解析：blog.csdn.net/zyw2002/article/details/128269925；blog.csdn.net/djfjkj52/article/details/137258528
- SCA/TSA 架构详解：blog.csdn.net/CV_Autobot/article/details/126339209；blog.csdn.net/weixin_44438120/article/details/149439665
- Apollo BEV 源码级分析：本地 `Apollo研究/01g_perception_bev.md`
- BEVFormer 复现方案：cloud.tencent.com/developer/article/2474717

---

**实际工具调用次数：32 次**（WebSearch 18 次 + WebFetch 8 次 + Read 5 次 + LS 1 次）
