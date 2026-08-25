# Apollo 感知模块深度研究 — LiDAR 3D 检测（CenterPoint / PointPillars / VoxelNet）

> 研究范围：百度 Apollo `modules/perception/lidar_detection` 子系统的算法原理、源码实现、点云预处理、后融合 ProbabilisticFusion 以及对 AuroraDrive 项目的迁移建议。
>
> 关键源码路径：`modules/perception/lidar_detection/`、`modules/perception/fusion/lib/fusion_system/probabilistic_fusion/`、`modules/perception/lidar/lib/pointcloud_preprocessor/`、`modules/perception/lidar/lib/object_builder/`、`modules/perception/onboard/component/`。

---

## 0. 总览：Apollo LiDAR 感知在系统中的位置

Apollo 感知子系统在 CyberRT 中以 Component 形式运行，LiDAR 通道主要包含以下几个 Component，它们通过共享内存 channel 串成一条流水线（参考 `modules/perception/production/dag/dag_streaming_perception_lidar.dag`）：

```
DetectionComponent (LidarDetectionComponent)
   │  输入: /apollo/sensor/lidar128/compensator/PointCloud2
   │  输出: /perception/inner/DetectionObjects  (LidarFrameMessage)
   ▼
RecognitionComponent (lidar_tracking)
   │  输入: /perception/inner/DetectionObjects
   │  输出: /perception/inner/TrackingObjects
   ▼
FusionComponent (ProbabilisticFusion)
   │  输入: /perception/inner/PrefusedObjects (lidar + camera + radar)
   │  输出: /apollo/perception/obstacles  (PerceptionObstacles)
```

`modules/perception/lidar_detection/README.md` 明确列出 Apollo 内置 4 个 LiDAR 检测模型：**centerpoint、maskpillars、pointpillars、cnnseg**。其中 PointPillars 是 Apollo 6.0 起的默认模型，CenterPoint 是 Apollo 7.0+ 在 nuScenes / Waymo 场景下的高性能替代；CNN Segmentation（cnnseg）是早期基于 BEV 网格 + FCN 的分割方案，已逐步被深度学习方法取代；MaskPillars 是带实例分割的 PointPillars 变体。

---

## 1. PointPillars 算法（Apollo 默认 LiDAR 检测模型）

### 1.1 原始论文与核心思想

- **论文**：*PointPillars: Fast Encoders for Object Detection from Point Clouds*（arXiv:1812.05784，CVPR 2019）
- **作者**：Alex H. Lang、Sourabh Vora、Holger Caesar、Lubing Zhou、Jiong Yang、Oscar Beijbom（nuTonomy）
- **核心贡献**：提出一种新的点云编码器，将点云组织为**垂直柱体（Pillar）**而非体素（Voxel），使用 PointNet 学习每个 pillar 的特征，再 scatter 成 2D 伪图像，使整个检测流水线可以用 2D CNN 完成，避免 3D 卷积。
- **性能**：在 KITTI 上达到当时 SOTA，3D 汽车检测 BEV/AP 显著优于 VoxelNet/SECOND，**端到端运行 62 Hz**（最快版本 105 Hz），比此前最佳方法快 2–4 倍。
- **关键洞察**：固定编码（如 BEV 投影）快但精度低，可学习编码（如 VoxelNet 的 3D 卷积）精度高但慢；PointPillars 通过"柱体化 + 2D CNN"同时拿到速度与精度。

### 1.2 算法流程

PointPillars 整体网络由三部分组成：**Pillar Feature Net (PFN) → 2D CNN Backbone (RPN) → Detection Head (SSD)**。

#### 步骤 1：Pillarization（柱体化）

- 在 XY 平面上以固定步长（默认 `0.16×0.16 m`）将点云划分为柱体网格，每个柱体在 Z 方向不切分，是一个"无限高"的柱子（这就是 Pillar 与 Voxel 的根本区别——Voxel 在 Z 上也分桶）。
- 典型配置（KITTI）：X 范围 `[0, 69.12]`，Y 范围 `[-39.68, 39.68]`，得到伪图像 `W=432, H=496`。
- 每个点被编码为 **9 维向量** `D = (x, y, z, r, xc, yc, zc, xp, yp)`：
  - `(x, y, z, r)`：点自身坐标 + 反射强度
  - `(xc, yc, zc)`：点到该 pillar 内所有点算术平均中心的距离
  - `(xp, yp)`：点到该 pillar 中心的 XY 偏移
- 因为点云稀疏，多数 pillar 为空，所以做两点限制：最多保留 `P=12000` 个非空 pillar，每个 pillar 最多保留 `N=100` 个点；多了随机采样，少了零填充，最终形成 `(D, P, N)` 张量。

#### 步骤 2：PointNet 编码（PFN）

- 对每个点的 9 维特征用 `Linear → BatchNorm → ReLU` 升维到 `C=64`，得到 `(C, P, N)`。
- 在每个 pillar 内对 N 维做 **Max Pooling**，得到 `(C, P)` 张量，每个 pillar 对应一个 64 维特征向量。
- PFN 本质是简化版 PointNet，去掉 T-Net，只保留 1×1 卷积+MaxPool。

#### 步骤 3：Scatter to Pseudo-Image（散布回伪图像）

- 用每个点的 pillar 索引 `(x_idx, y_idx)` 把 `(C, P)` 张量写回 `(C, H, W)` 的 2D 伪图像，对应位置即 pillar 在 BEV 网格中的坐标。
- 这一步是纯 index 操作，无参数、O(P)，Apollo 中称为 `PointPillarScatter`。

#### 步骤 4：2D CNN Backbone（与 VoxelNet 一致的 RPN）

- 在伪图像上跑 2D CNN，结构借鉴 VoxelNet 的 RPN：
  - 三个子网络：`Conv2D(stride=2)` 自顶向下提取多尺度特征；
  - `ConvTranspose2D` 上采样到同一分辨率后 concat，输出多尺度 BEV 特征。
- 因为是 2D 卷积，可以用 TensorRT/cuDNN 高度优化，这是速度的根本来源。

#### 步骤 5：Detection Head（SSD）

- 类似 SSD，在 BEV 网格上密集放置 3D anchor（按类别预设尺寸：car/pedestrian/cyclist），每个 anchor 有两个朝向（0°/90°）。
- 输出每个 anchor 的：分类置信度、(Δx, Δy, Δz, Δw, Δl, Δh, Δθ) 7 维回归残差、朝向二分类。
- 损失函数（与 SECOND 一致）：
  - 分类：**Focal Loss**（解决 anchor 与目标极不平衡）
  - 回归：**Smooth L1**（残差 = (g - a^da)，其中 `da = log(g/a)` 用于尺寸）
  - 朝向：**Softmax**（dir cls，区分 ±π 对折问题）
- 后处理：NMS（Apollo 中通过 `GetObjects()` 调用 CUDA NMS 算子）。

### 1.3 Apollo 中的实现：`PointPillarsDetection` 类

源码位置：`modules/perception/lidar_detection/detector/point_pillars_detection/`

文件清单：
- `point_pillars.h` / `point_pillars.cc`：核心模型，包含 PFN、Scatter、Backbone、Head
- `point_pillars_detection.h` / `point_pillars_detection.cc`（约 362 行）：包装类，继承 `BaseLidarDetector`，提供 `Init()` / `Detect()` 接口
- `point_pillars_test.cc`：单元测试，入口 `./bazel-bin/modules/perception/lidar/lib/detector/point_pillars_detection/point_pillars_test`

`PointPillarsDetection::Detect()` 流程（结合源码注释）：

```
1. Preprocess：调用 pointcloud_preprocessor
2. DownSamplePointCloudBeams(scan_line_downsample_factor)
3. DownSampleByVoxelGrid(voxel_size)         // 体素网格下采样
4. Fuse：将 prev_world_clouds_ 中过去 N 帧点云融合到当前帧
   // 超过 FLAGS_fuse_time_interval 的旧帧出队
5. Shuffle
6. inference_engine_->Infer(points, ...)     // TensorRT/LibTorch/ONNX Runtime
7. GetObjects()                              // 解码 + NMS + 朝向修正
```

**关键设计**：
- Apollo 把 PFN、Backbone、Head 三个子图分别导出 ONNX，再用 TensorRT 串成 engine，避免动态 shape 问题（PFN 因为非空 pillar 数量 P 变化，需要 dynamic shape 或固定 P=12000）。
- 推理引擎通过工厂模式 `InferenceEngine` 创建，支持 `TensorRT`（默认）、`ONNX Runtime`、`LibTorch`、`Paddle`，体现 Apollo 的多后端策略。
- 模型文件路径：`modules/perception/data/models/detection/point_pillars/`，包含 `point_pillars.onnx`、`point_pillars.trt`、配置 `params.pt`。

---

## 2. CenterPoint 算法（两阶段 Center-based 检测 + 跟踪）

### 2.1 原始论文与动机

- **论文**：*Center-based 3D Object Detection and Tracking*（arXiv:2006.11275，CVPR 2021）
- **作者**：Tianwei Yin、Xingyi Zhou、Philipp Krähenbühl（UT Austin）
- **动机**：传统 box-based 检测器（VoxelNet/PointPillars）使用 anchor + NMS，存在两个问题：
  1. 3D 目标没有固定方向，轴对齐 anchor 难以枚举所有朝向；
  2. NMS 在旋转框上不优雅，容易漏检。
- **核心思想**：用**点（中心点）**而非框表示目标，避免旋转枚举，同时把检测、跟踪统一到中心点关联框架。

### 2.2 两阶段结构

#### Stage 1：3D Encoder + 2D BEV Backbone + CenterHead

- **3D Encoder**：可直接复用 VoxelNet（带 Z 分桶）或 PointPillars（柱体）作为 backbone_3D，输出 BEV 特征图。
- **2D Backbone**：标准的 2D CNN（如 SECOND 的稀疏卷积 FPN），提取多尺度 BEV 特征。
- **CenterHead**：对每个类别预测：
  - **Heatmap**（关键点检测，类似 CenterNet）：BEV 网格上每个像素是某类目标中心的概率，用高斯核生成 GT（解决点云中目标分布稀疏导致正样本过少的问题，高斯半径 `σ = max(f(wl), τ)`，τ=2 为最小半径）。
  - **属性回归**：从中心位置的特征回归 `(w, l, h, θ, vx, vy)`，即尺寸 + 朝向 + 速度（速度是 CenterPoint 的天然能力）。
- 优点：**无 anchor、无 NMS**，输出直接是目标的中心点 + 属性，端到端可微。

#### Stage 2：Refinement（精修）

- 在 Stage 1 得到的目标框上，取**四个侧面中心点**在 BEV 特征图上的特征（顶/底面在 BEV 上是同一点，故只取 4 个）。
- 用双线性插值从 backbone feature map 提取点特征，送入一个小 MLP，输出：
  - 置信度 `I_t`（训练时用 3D IoU 监督，二值交叉熵损失）；
  - 残差 `(Δx, Δy, Δz, Δw, Δl, Δh, Δθ)` 进一步 refine。
- 推理时最终分数 `Q_t = sqrt(Y_t · I_t)`，其中 `Y_t` 是 Stage 1 中心点的 heatmap 响应，`I_t` 是 Stage 2 的 IoU 预测，几何平均降低 Stage 1 的假阳性。

### 2.3 跟踪天然支持

- CenterPoint 的核心优势：**跟踪简化为贪心最近邻匹配**。
- 每个目标有速度 `(vx, vy)`，可用上一帧中心 + 速度 × Δt 预测当前中心，再做最近邻关联，无需 Kalman 滤波。
- 论文报告跟踪耗时 ~1 ms，在 nuScenes 上 63.8 AMOTA（远超当年 SOTA）。

### 2.4 性能

- **nuScenes**：65.5 NDS（单模型），比 CBGS 高 2.2% NDS / 5.2% mAP。
- **Waymo**：L2 车辆 71.8 mAPH，行人 66.4 mAPH，比此前 SOTA 分别 +7.1% / +10.6%。
- **速度**：Waymo 11 FPS，nuScenes 16 FPS（Titan RTX），实时性弱于 PointPillars，但在边缘端用 TensorRT + FP16 可压到 20+ FPS。

### 2.5 与 PointPillars 的差异

| 维度 | PointPillars | CenterPoint |
|------|--------------|-------------|
| 表示 | anchor + box | center point |
| 检测头 | SSD（多 anchor） | Heatmap + 属性回归 |
| 后处理 | NMS（O(n²)） | top-k 选点（O(n)） |
| 跟踪 | 需外部 tracker（HM/MLF） | 中心点最近邻（~1ms） |
| 速度 | 62–105 Hz | 16 FPS（nuScenes） |
| 速度回归 | 无 | 有（vx, vy） |
| 精度 | 中等 | SOTA |

---

## 3. VoxelNet 算法（3D 检测深度学习的起点）

### 3.1 原始论文

- **论文**：*VoxelNet: End-to-End Learning for Point Cloud Based 3D Object Detection*（arXiv:1711.06396，CVPR 2018）
- **作者**：Yin Zhou、Oncel Tuzel（Apple Inc.）
- **核心贡献**：首个**端到端可训练**的 3D 检测网络，去掉了手工 BEV/前视特征工程，提出 **VFE（Voxel Feature Encoding）层**。

### 3.2 网络结构

VoxelNet 由三部分组成：

#### (1) Feature Learning Network

- **Voxel Partition**：将点云空间 `[D, H, W]` 等分为体素（如 KITTI 配置 `0.4×0.2×0.2 m`）。
- **Grouping**：每个 voxel 内随机采样 T=35 个点（多则采样，少则零填充）。
- **VFE Layer**：每个点的特征 `(x, y, z, r)` → 拼接 voxel 内所有点的 max-pooled 特征 → MLP → 再拼接，逐层堆叠 VFE-1, VFE-2，最终每个 voxel 输出 128 维特征。
- **Sparse Tensor → 4D Tensor**：将非空 voxel 写回稠密 4D 张量 `(C', D, H, W)`。

#### (2) Convolutional Middle Layers

- 3 个 **3D 卷积层**（Conv3D → BN → ReLU），提取局部 3D 空间特征。
- 输出形状 `(64, D', H', W')`。

#### (3) Region Proposal Network (RPN)

- 将 3D 特征 reshape 成 BEV `(C·D', H', W')`，再用 2D 卷积 + 反卷积融合多尺度特征。
- 输出分类 + 回归，类似 Faster R-CNN 的 RPN，配合 anchor。

### 3.3 Apollo 为何选 PointPillars 而非 VoxelNet？

Apollo 6.0+ 默认选 PointPillars 而非 VoxelNet，核心是**计算效率**：

1. **3D 卷积昂贵**：VoxelNet 的 Conv3D 在稀疏体素上仍需稠密计算（即使 SECOND 用稀疏卷积加速），显存与算力消耗大；
2. **PointPillars 去掉 Z 维体素**：把 3D 问题压成 2D 伪图像，后续全部 2D 卷积，可充分利用 cuDNN，62 Hz vs VoxelNet ~4.4 Hz；
3. **嵌入式友好**：Apollo 目标硬件是车规级 GPU/Jetson，2D CNN 易做 INT8 量化、TensorRT engine 序列化；
4. **精度损失可控**：KITTI 上 PointPillars 与 VoxelNet 精度相当，nuScenes/Waymo 上 CenterPoint 又补齐了精度上限。

因此 VoxelNet 在 Apollo 中只作为 CenterPoint 的 backbone_3D 候选（`center_point_detection` 目录里同时支持 voxel 和 pillar 编码），不再作为独立检测器维护。

---

## 4. 三种算法对比表

| 维度 | **VoxelNet** (CVPR'18) | **PointPillars** (CVPR'19) | **CenterPoint** (CVPR'21) |
|------|------------------------|----------------------------|---------------------------|
| 编码单元 | Voxel（3D 体素） | Pillar（垂直柱，无 Z 分桶） | Voxel 或 Pillar（可选） |
| 特征提取 | VFE Layer + 3D Conv | PFN（简化 PointNet） | 同 PointPillars/VoxelNet backbone |
| 伪图像 | 4D→3D reshape | 2D scatter | 2D BEV 特征图 |
| Backbone | 3D Conv + RPN | 2D CNN RPN | 2D CNN（稀疏卷积 FPN） |
| 检测头 | RPN + anchor | SSD + anchor | Heatmap（CenterNet 式） |
| 后处理 | NMS | NMS | Top-K（无 NMS） |
| 朝向处理 | anchor 多方向枚举 | anchor 双向 + dir cls | 直接回归（无枚举） |
| 速度回归 | 无 | 无 | 有（vx, vy） |
| 跟踪 | 外部 tracker | 外部 tracker（HM/MLF） | 中心点最近邻（~1ms） |
| 是否两阶段 | 否 | 否 | 是（Stage 1 检测 + Stage 2 refine） |
| KITTI 速度 | ~4.4 Hz | 62–105 Hz | ~16 FPS (nuScenes) |
| nuScenes NDS | — | ~55（中等） | 65.5 |
| Waymo L2 mAPH | — | 中等 | 71.8（车）/ 66.4（行人） |
| 3D 卷积 | 是 | 否（全 2D） | 仅 backbone_3D（可选） |
| TensorRT 部署 | 难（3D Conv 支持弱） | 易 | 中（含稀疏卷积） |
| Apollo 中的角色 | CenterPoint backbone 候选 | **默认检测器**（6.0+） | 高性能替代（7.0+） |
| 源码路径 | （仅作 backbone 集成） | `lidar_detection/detector/point_pillars_detection/` | `lidar_detection/detector/center_point_detection/` |

---

## 5. Apollo LiDAR 检测源码深度分析

### 5.1 目录结构（Apollo master 分支）

```
modules/perception/lidar_detection/
├── conf/                            // lidar_detection_config.pb.txt 等配置
├── dag/                             // lidar_detection.dag
├── data/                            // 模型配置文件
├── detector/
│   ├── center_point_detection/      // CenterPoint 模型代码
│   ├── cnn_segmentation/            // CNNSeg 老模型
│   ├── mask_pillars_detection/      // MaskPillars 变体
│   └── point_pillars_detection/     // PointPillars 模型代码（默认）
├── interface/                       // BaseLidarDetector 基类
├── proto/                           // 数据结构 protobuf 定义
├── lidar_detection_component.cc     // LidarDetectionComponent 实现
└── lidar_detection_component.h
```

`LidarDetectionComponent`（`apollo::perception::lidar::LidarDetectionComponent`）：
- **输入**：`LidarFrameMessage`，默认 channel `/perception/lidar/pointcloud_ground_detection`（即上游是地面分离后的点云）
- **输出**：`LidarFrameMessage`（`segmented_objects` 已填充），channel `/perception/lidar/detection`
- 配置项：`plugin_param` 指定选用哪种 detector（centerpoint/pointpillars/...）、`use_object_builder`、`sensor_name`

### 5.2 流水线（Pipeline 模式，7 阶段）

Apollo 7.0+ 引入 Pipeline 框架，`modules/perception/pipeline/config/lidar_detection_pipeline.pb.txt` 定义 7 个 stage：

```
POINTCLOUD_PREPROCESSOR            // 点云预处理（去 NaN、自车框、过高点）
POINTCLOUD_DETECTION_PREPROCESSOR  // 检测前预处理（下采样、ROI）
MAP_MANAGER                        // 高精地图管理
POINT_PILLARS_DETECTION            // PointPillars 检测（可换 CenterPoint）
POINTCLOUD_DETECTION_POSTPROCESSOR  // 检测后处理（GetObjects）
OBJECT_BUILDER                     // 边框构建（MinBox）
OBJECT_FILTER_BANK                  // 目标过滤（ROI 边界 / 策略 / 背景）
```

每个 stage 由插件工厂 `PERCEPTION_REGISTER_CLASS` 注册，可热插拔。

### 5.3 PointCloudPreprocessor（点云预处理）

源码：`modules/perception/lidar/lib/pointcloud_preprocessor/pointcloud_preprocessor.cc`

配置项（`POINTCLOUD_PREPROCESSOR` stage）：
```protobuf
filter_naninf_points: false
filter_nearby_box_points: false
box_forward_x: 2.0    box_backward_x: -2.0
box_forward_y: 2.0    box_backward_y: -2.0
filter_high_z_points: false
z_threshold: 5.0
```

处理内容：
1. **NaN/Inf 过滤**：剔除 `x, y, z, intensity` 中的非法值。
2. **自车框过滤**：剔除落在自车 bbox（默认前后 ±2 m）内的点（激光打到自身车体）。
3. **高度过滤**：剔除 `z > z_threshold`（如 5 m）的点，避免高树/天桥干扰。

下游 `POINTCLOUD_DETECTION_PREPROCESSOR` 进一步做：
- **距离过滤**：`x ∈ [-74.88, 74.88]`，`y ∈ [-74.88, 74.88]`，`z ∈ [-2.0, 4.0]`（约 150 m × 150 m ROI）
- **Beam 下采样**：`DownSamplePointCloudBeams` 按激光线 ID 抽稀（128 线降到 64/32 线）
- **Voxel Grid 下采样**：`DownSampleByVoxelGrid` 用 PCL voxel grid 进一步减点

### 5.4 PointPillarsDetection::Detect() 关键流程

```cpp
bool PointPillarsDetection::Detect(const LidarFrame& frame) {
  // 1. 坐标系：frame->cloud 已在 lidar 坐标系
  // 2. 下采样：beam downsample + voxel grid downsample
  // 3. 历史帧融合：FLAGS_fuse_time_interval（默认 0.0625s）内的 prev_world_clouds_ 融合
  //    等效于把 16 Hz LiDAR 累积到 10 Hz 提升密度
  // 4. Shuffle：打乱点顺序避免 GPU 推理 cache 局部性
  // 5. 调用 inference_engine_->Infer(pillar_features)
  //    内部：PFN → Scatter → Backbone → Head，全部在 GPU
  // 6. GetObjects()：
  //    - 解码 anchor + 残差 → 3D box
  //    - 朝向修正（dir cls 的 argmax）
  //    - 置信度阈值过滤
  //    - NMS（按类别 + IoU 0.1 BEV）
  //    - 写回 frame->segmented_objects
}
```

### 5.5 ObjectBuilder（边框构建）

源码：`modules/perception/lidar/lib/object_builder/`

把检测到的 3D box 转换成 Apollo 内部 `Object` 数据结构：
- **MinBox Builder**：基于点云凸包，构造最小外接矩形（2D），再结合高度生成 3D box；
- **polygon**：从内点云构建凸包，作为目标的几何多边形；
- 速度不在此阶段获取（由下游 `lidar_tracking` 中的 Kalman 滤波估计）。

### 5.6 LiDARFrameMessage 数据结构

源码：`modules/perception/common/onboard/inner_component_messages/lidar_inner_component_messages.h`

```cpp
struct LidarFrameMessage {
  double timestamp = 0.0;
  uint64_t seq_num = 0;
  std::string sensor_id;
  std::shared_ptr<apollo::drivers::PointCloud> point_cloud;
  std::shared_ptr<apollo::common::Header> header;
  std::shared_ptr<LidarFrame> lidar_frame;     // 核心数据载体
};

struct LidarFrame {
  PointCloud cloud;                          // 原始点云
  PointCloud non_ground_cloud;               // 非地面点
  std::vector<std::shared_ptr<Object>> segmented_objects;  // ★检测输出
  Eigen::Affine3d lidar2world_pose;
  std::shared_ptr<HdmapStruct> hdmap_struct;
  // ... 还有 roi、ground_service、scene_manager 缓存
};
```

`Object` 数据结构（`modules/perception/base/object.h`）核心字段：
```cpp
struct alignas(16) Object {
  int id = -1;
  PointCloud<PointD> polygon;            // 凸包多边形
  Eigen::Vector3f direction;             // 朝向
  float theta = 0.0f;                    // yaw 角
  Eigen::Vector3d center;                // 中心点
  Eigen::Vector3f size;                  // (l, w, h)
  ObjectType type = UNKNOWN;             // 类别
  std::vector<float> type_probs;         // 类别概率
  float confidence = 1.0f;
  // tracking 字段
  int track_id = -1;
  Eigen::Vector3f velocity;
  float tracking_time, latest_tracked_time;
  // 传感器补充（融合用）
  LidarSupplement lidar_supplement;
  CameraSupplement camera_supplement;
  RadarSupplement radar_supplement;
};
```

### 5.7 推理后端依赖

`modules/perception/inference/` 下提供 4 套推理引擎：

| 后端 | 路径 | 用途 |
|------|------|------|
| **TensorRT** | `inference/lib/inference_worker/tensorrt/` | 默认，FP16/INT8 量化 |
| **LibTorch** | `inference/lib/inference_worker/libtorch/` | PyTorch 模型 |
| **ONNX Runtime** | `inference/lib/inference_worker/onnx/` | 跨平台兜底 |
| **Paddle** | （与 Paddle3D 集成） | Apollo + 飞桨联合训练 |

`PointPillarsDetection::Init()` 通过 `InferenceEngineRegisterer::GetInstanceByName(engine_name)` 工厂创建实例，engine_name 由配置 `params.pt` 中的 `framework` 字段决定，默认 `tensorrt`。模型目录同时存放 `.onnx`（用于转换）和 `.trt`（序列化 engine）。

---

## 6. LiDAR 点云预处理深度

Apollo 把点云预处理拆为多个独立 Component，每个有独立配置，便于调参与替换。

### 6.1 点云过滤链

```
原始 PointCloud2 (128 线)
  │
  ▼  DetectionComponent::InternalProc
坐标变换：lidar → ENU 局部坐标系（lidar2world_trans_）
  │
  ▼  PointCloudPreprocessor
  - filter_naninf_points      // NaN/Inf 剔除
  - filter_nearby_box_points  // 自车框剔除
  - filter_high_z_points      // 高度过滤
  │
  ▼  PointCloudMapBasedRoi（pointcloud_map_based_roi 组件）
  - 提取高精地图 road/junction 多边形
  - 用位图编码（0.25×0.25 m 网格）做 in/out 判定
  - 输出 cloud_roi（ROI 内点云）
  │
  ▼  PointcloudGroundDetection（pointcloud_ground_detection 组件）
  - 80 m 内 256×256 粗分 + 32×32 细分 voxel grid
  - RANSAC 拟合地平面
  - 高度阈值 0.25 m：低 → 地面点，高 → 非地面点
  │
  ▼  cloud_non_ground → lidar_detection 组件
```

### 6.2 地面分离（RANSAC + 平面拟合）

源码：`modules/perception/lidar/lib/ground_detector/spatio_temporal_ground_detector/`

Apollo 的 `spatio_temporal_ground_detector` 是时序版 RANSAC：

1. **粗分/细分双层网格**：256×256 粗分方格，每格内嵌 32×32 细分方格（用 SSE2 指令集并行加速点查询）；
2. **地面候选点过滤**（在细分方格内）：
   - 距离 ≤ 80 m；
   - z 在 [lidar_height - 3 m, lidar_height - 1 m] 区间；
   - 与同方格内点高度差小于阈值；
3. **RANSAC 拟合**（以粗分方格为单位）：
   - 随机抽 3 候选点拟合平面；
   - 统计 inlier（点到平面距离 < 0.1–0.2 m）；
   - 重复 48 次 + 8 邻居平面 = 56 候选，选 inlier 最多的；
   - 同 inlier 数选与邻居夹角最小的；
   - 最小二乘重拟合 + 相邻平面平滑（欧氏↔球坐标变换）；
4. **高度判定**：每个点相对拟合平面的高度 < 0.25 m → 地面点。

### 6.3 点云聚类（DBSCAN / 欧氏聚类）

Apollo 主线检测走 PointPillars/CenterPoint，不再依赖聚类，但早期 cnnseg + MinBox 路径以及一些 fallback 路径仍使用聚类：

- **DBSCAN**（`density-based spatial clustering`）：在 BEV 网格上以 `eps` 半径 + `min_samples` 邻居数聚类，对噪声鲁棒，能处理任意形状簇；
- **欧氏聚类**（PCL `EuclideanClusterExtraction`）：基于 KD-Tree 的连通分量，速度快；
- Apollo 的 `cnn_segmentation` 输出语义分割后，会用聚类把同类点合并成 instance，再交给 ObjectBuilder 构造 box。

### 6.4 预处理与检测的关系

| 预处理 | 作用 | 对 PointPillars 的影响 |
|--------|------|----------------------|
| NaN/自车框过滤 | 防止无效点干扰 PFN 编码 | 必需，否则 PFN 会把自车点当成强反射目标 |
| 高度过滤 | 减少天桥/高树 | 减少 pillar 数量 P，加速推理 |
| ROI 裁剪 | 限定可驾驶区域 | 大幅减少点数（150 m vs 全量 300 m） |
| 地面分离 | 把地面点排除 | 防止 anchor 误检地面为目标（如路面噪声 → 假车） |
| Beam/Voxel 下采样 | 控制点数 | 直接降低 PFN 计算量 |
| 历史帧融合 | 提升 10 Hz 帧密度 | 改善远距离稀疏目标的召回 |

---

## 7. 与相机检测的融合 — ProbabilisticFusion 后融合

### 7.1 后融合架构（Late Fusion）

Apollo 选的是**后融合（Late Fusion）**——决策级融合。每个传感器先各自检测、跟踪，输出障碍物列表，最后在融合模块做匹配 + 合并。优点：
- 模块解耦，单传感器故障可降级；
- 通信开销小（只传 Object 列表，不传图像/点云）；
- 易扩展（新增传感器只需加 Component）。

核心类：`ProbabilisticFusion`（`modules/perception/fusion/lib/fusion_system/probabilistic_fusion/`），通过 `FUSION_REGISTER_FUSIONSYSTEM(ProbabilisticFusion)` 注册到工厂。

### 7.2 配置

`modules/perception/production/conf/perception/fusion/fusion_component_conf.pb.txt`：
```protobuf
fusion_method: "ProbabilisticFusion"
fusion_main_sensor: "velodyne128"     // 主传感器
object_in_roi_check: true
radius_for_roi_object_check: 120
output_obstacles_channel_name: "/apollo/perception/obstacles"
```

`modules/perception/production/data/perception/fusion/probabilistic_fusion.pt`：
```python
use_lidar: true
use_radar: true
use_camera: true
tracker_method: "PbfTracker"
data_association_method: "HMAssociation"
gate_keeper_method: "PbfGatekeeper"
prohibition_sensors: "radar_front"   # radar 不创建新 track
max_lidar_invisible_period: 0.25     # 传感器最大不可见时长
max_radar_invisible_period: 0.50
max_camera_invisible_period: 0.75
max_cached_frame_num: 50
```

### 7.3 ProbabilisticFusion 流程图（文字描述）

```
┌──────────────────────────────────────────────────────────────────────┐
│  FusionComponent::Proc(SensorFrameMessage in)                        │
│   - 配置加载、Init ObstacleMultiSensorFusion                          │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ProbabilisticFusion::Process(frame, fused_objects)                  │
│                                                                      │
│  [1] AddSensorMeasurements(frame)                                    │
│       └─ SensorDataManager.AddSensorFrame(frame)                     │
│            - 按 sensor_id 缓存 SensorFrame（deque，max_cached=50）   │
│            - 包含 lidar/camera/radar 各自的 Object 列表               │
│                                                                      │
│  [2] GetLatestFrames(timestamp)                                      │
│       └─ 从每个 sensor 取最近帧，按 timestamp 排序，选出最早一帧     │
│            作为本次融合的"触发帧"                                     │
│                                                                      │
│  [3] FuseFrame(trigger_frame)                                        │
│       ├─ FuseForeground  → 前景目标（车/人/cyclist）                  │
│       ├─ FuseBackground → 背景目标（植被/护栏）                      │
│       └─ RemoveLostTracks() → 移除超时不可见 track                   │
│                                                                      │
│  [4] CollectFusedObjects(fused_objects)                              │
│       └─ PbfGatekeeper 判断是否发布（置信度、ROI、可见性）           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│  FuseForeground 详细流程（HM 数据关联 + 多滤波器融合）                │
│                                                                      │
│  ┌─────────────────────┐      ┌──────────────────────┐                │
│  │ scenes_.foreground_ │ ◄── │ CreateNewTracks()    │ 新检测 → 新轨迹│
│  │     tracks_          │     │ (跳过 radar_front)   │                │
│  └─────────────────────┘      └──────────────────────┘                │
│              │                                                       │
│              ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐         │
│  │ HMAssociation::Associate(tracks, objects) → match_pairs │         │
│  │  - 构造二分图，匈牙利算法求最优匹配                       │         │
│  │  - 距离 = f(空间距离 + 速度 + 朝向 + 尺寸 + 类别)         │         │
│  │  - 多目标匹配 MultiHmBipartiteGraphMatcher              │         │
│  └─────────────────────────────────────────────────────────┘         │
│              │ matched / unmatched_tracks / unmatched_objects        │
│              ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐         │
│  │ UpdateAssignedTracks (匹配上的)                          │         │
│  │  PbfTracker::UpdateWithMeasurement() 依次调用：         │         │
│  │   ├─ DstExistanceFusion   → DS 证据理论，更新存在性 prob │         │
│  │   ├─ KalmanMotionFusion   → Kalman 滤波，更新位置/速度   │         │
│  │   ├─ PbfShapeFusion       → 形状融合，更新 size/θ/poly   │         │
│  │   └─ DstTypeFusion        → DS 理论，更新类别概率       │         │
│  └─────────────────────────────────────────────────────────┘         │
│  ┌─────────────────────────────────────────────────────────┐         │
│  │ UpdateUnassignedTracks (未匹配的 track)                  │         │
│  │  - 维持状态，更新可见性计数                               │         │
│  │  - 超过 max_*_invisible_period 则丢弃                    │         │
│  └─────────────────────────────────────────────────────────┘         │
│  ┌─────────────────────────────────────────────────────────┐         │
│  │ CreateNewTracks (未匹配的 object)                        │         │
│  │  - 从 TrackPool 取 track，Initialize，加入 scenes_        │         │
│  │  - 创建 PbfTracker 并 InitMethods（构造 motion/shape 等） │         │
│  └─────────────────────────────────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────────┘
```

### 7.4 关键数据结构：SensorObject / SensorFrame / Sensor

| 类 | 角色 | 成员 |
|----|------|------|
| `SensorObject` | 单传感器单目标 | `base::Object` + sensor_id + timestamp |
| `SensorFrame` | 单传感器一帧所有目标 | `vector<SensorObject>` |
| `Sensor` | 单传感器多帧历史 | `deque<SensorFramePtr>`（max_cached_frame_num=50） |
| `SensorDataManager` | 多传感器缓存 | `unordered_map<sensor_id, SensorPtr>` |
| `Track` | 单融合跟踪目标 | `FusedObjectPtr fused_object_` + `lidar_objects_` / `radar_objects_` / `camera_objects_` |
| `Scene` | 全部 track 管理 | `vector<TrackPtr> foreground_tracks_`, `background_tracks_` |
| `PbfTracker` | 融合算法载体 | 持 `Track*`，内含 `motion_fusion_` / `shape_fusion_` / `type_fusion_` / `existence_fusion_` 指针 |

### 7.5 Object 补充字段（传感器专属信息）

```cpp
struct LidarSupplement {
  bool is_in_roi = false;
  PointCloud<PointD> cloud;          // 该目标对应的点云
  ...
};
struct CameraSupplement {
  // 2D bbox、可见性、车道投影等
};
struct RadarSupplement {
  // 多普勒速度、信噪比
};
```

这些 supplement 让融合模块可以拿到每个传感器对该目标的独有测量，做加权融合。

### 7.6 降级机制（单传感器故障）

- **主传感器策略**：`fusion_main_sensor: "velodyne128"`，LiDAR 是主传感器。若 LiDAR 持续不可见（`max_lidar_invisible_period = 0.25s`），track 会被丢弃；
- **radar 不创建新 track**（`prohibition_sensors: "radar_front"`）：radar 假阳性高，只能更新已有 track，不能创建新目标；
- **Gatekeeper**：`PbfGatekeeper` 检查置信度、ROI 内/外、可见时长，决定 track 是否发布；
- **传感器各自独立 Component**：Camera/Radar 检测各自跑在独立 Component，任一崩溃不影响其他通道；
- **超时丢弃**：`max_*_invisible_period` 三档（lidar 0.25s / radar 0.5s / camera 0.75s）保证瞬时遮挡能恢复，长时间丢失能及时清理。

---

## 8. AuroraDrive 迁移建议

### 8.1 AuroraDrive 当前 LiDAR 实现

通过审查 `AuroraDrive项目交接文档.md`、`cpp/include/ad/simulator.h`、`cpp/include/ad/sensors.h`、`src/model.py`、`src/cpp_bridge.py` 确认：

1. **LiDAR 是从 MapData 渲染的，不是真实 LiDAR 检测**：
   - `cpp/include/ad/sensors.h:228` 的 `render_lidar(...)` 从 ego 位置扫描周围道路/建筑点，生成伪点云；
   - `simulator.h:259-260` 的 `lidar_road_ids_` / `bldg_query_buf_` 是 `render_lidar_from_map` 的复用缓冲；
   - `chapters/04_仿真主循环与调度系统.md:1766`：`render_lidar_from_map` 前后各 2048 点，用 `MapData` 实时查附近道路/建筑点，按车头坐标变换到局部极坐标，按角度分流前后向。
   - 这本质是**仿真渲染**，不是检测：点云直接由地图几何生成，没有真正的感知环节。

2. **AuroraDrive 有 PointNetLite 模型处理点云**（`src/model.py:223`）：
   - 参数量 ~108K，结构：`TNet(k=3) → Conv1d(3→64→128→256) → MaxPool → FC(256→128→256)`；
   - 输入 3 维坐标，输出 256 维特征，作为 M9Model 端到端模型的 lidar 分支；
   - 用途是**端到端控制**（输出 steer/throttle/brake），不是显式前车检测；前车检测目前是规则判定（`front_speed_ >= 0` 修复 BUG-001）。

3. **空间索引**：`spatial.h` 的 `GridIndex` 提供 500 m 查询 <1ms 的能力（cell=100 m 网格），用于地图 ROI 与车辆查询。

### 8.2 是否升级 PointPillars / CenterPoint 的决策

**结论：暂不升级为 PointPillars/CenterPoint，原因如下：**

| 维度 | 真实 LiDAR（Apollo 场景） | AuroraDrive 仿真场景 |
|------|---------------------------|----------------------|
| 点云来源 | 128 线机械式 LiDAR，10 Hz，~10 万点/帧 | MapData 渲染，前/后各 2048 点，1 Hz |
| 噪声模型 | 多次回波、雨雾、运动畸变 | 几何精确，无噪声 |
| 算力预算 | 车规 GPU（Jetson Orin / RTX 4090） | 用户笔记本/Mac（Tauri 应用，无 GPU） |
| 目标 | 真实 3D 检测 + 跟踪 + 融合 | 仿真辅助驾驶（前车是否存在、距离估计） |
| 训练数据 | KITTI/Waymo/nuScenes 大规模标注 | 无 LiDAR 标注，仅 expert 轨迹 |
| 部署 | TensorRT engine | Python+PyTorch / C++ sidecar |

- **算力不匹配**：PointPillars 即便 TensorRT INT8 也需 5–10 W GPU，AuroraDrive 是 Tauri 桌面应用，主用户无独立 GPU，强行加 PointPillars 会让帧率从 24 Hz 掉到 < 5 Hz；
- **数据不匹配**：仿真点云没有真实 LiDAR 的稀疏分布、反射强度噪声，PointPillars 在 KITTI 上训练的权重直接迁移到仿真点云会有显著域偏移（domain gap）；
- **任务过载**：AuroraDrive 当前主要任务是端到端控制（M9Model）+ 仿真可视化，前车检测只是辅助。引入完整 3D 检测流水线（预处理 + 推理 + NMS + 跟踪 + 融合）相当于把 Apollo 感知子系统搬过来，违背 AuroraDrive 轻量化原则；
- **PointNetLite 已足够**：当前 PointNetLite 256 维特征已用于 M9Model 的 lidar 分支，端到端隐式学习了前车响应；显式前车检测用规则即可。

### 8.3 简化版方案：DBSCAN / 欧氏聚类做前车检测

若确实需要显式前车检测（用于 HUD 框选、ACC 触发），推荐以下轻量方案，**完全在 C++ sidecar 内运行，无 PyTorch 依赖**：

#### 方案 A：BEV 投影 + DBSCAN（推荐）

```
输入：render_lidar_from_map 输出的前向 2048 点（局部极坐标 → XYZ）
  │
  ▼ 1. 地面分离（简化版 RANSAC）
  - 在 ego 坐标系下，对 z ∈ [-1.5, 0.5] 的点拟合平面
  - 高度阈值 0.3 m（仿真地面理想，阈值可放宽）
  - 输出 non_ground_cloud
  │
  ▼ 2. ROI 裁剪
  - 仅保留 ego 前方 x ∈ [2, 80], y ∈ [-5, 5], z ∈ [0, 3]
  - 输出 front_roi_cloud
  │
  ▼ 3. BEV 投影
  - 投影到 XY 平面，量化到 0.1 m 网格
  - 每个网格累计点数（density map）
  │
  ▼ 4. DBSCAN 聚类（scikit-learn 风格，C++ 实现）
  - eps = 0.5 m, min_samples = 8
  - 复用 GridIndex（spatial.h）做半径查询，O(n log n)
  - 输出 cluster_labels
  │
  ▼ 5. 簇筛选
  - 簇大小 ∈ [20, 5000] 点
  - 簇 bounding box 长宽 ∈ [1.5, 6.0] m × [1.0, 3.0] m（车尺寸约束）
  - 簇中心 x 在前方 5–80 m，|y| < 5 m
  │
  ▼ 6. 前车候选排序
  - 按 |y| 升序（最接近车道中心的优先）
  - 取第一个作为 lead_vehicle
  │
  ▼ 7. 输出
  - lead_vehicle.center, .size, .distance, .relative_speed
  - 写入 SensorFrame.lead，供 React UI 渲染 3D Box
```

**C++ 实现要点**：
- DBSCAN 用 `cpp/include/ad/spatial.h` 的 `GridIndex` 做邻域查询，已验证 500 m 查询 <1 ms；
- 整个流水线纯 CPU，预计 < 2 ms/帧（2048 点规模）；
- 复用 `thread_local` 缓冲避免 24 Hz 广播分配（参考 `http_server.h:110-131` 的优化模式）；
- 新增 `cpp/include/ad/lead_detector.h`，在 `simulator.h` 的 `sensor_loop` 中调用，输出挂到 `SensorFrame`。

#### 方案 B：极简版（最低工作量）

仅做"前方是否有车 + 距离估计"，不做完整 box：
- 把前向 2048 点按 x 距离分桶（每 1 m 一桶）；
- 统计每桶点数 > 阈值（如 30）即认为该距离有障碍；
- 取最近一桶的距离作为 lead_distance；
- 用上一帧 lead_distance 差分估算 relative_speed。

工作量约 100 行 C++，1 天可上线，足以支撑 ACC 触发与 HUD 警示。

#### 方案 C：升级 PointNetLite 为轻量 PointPillars-lite（中长期）

若未来 AuroraDrive 接入真实 LiDAR 数据或迁移到带 GPU 的设备：
- 把 PointNetLite（108K 参数）替换为 PFN-only 版 PointPillars（约 1M 参数）；
- 输入 9 维点特征（同 PointPillars 论文），输出 64 维 BEV 特征；
- 加一个轻量 SSD head 检测前向车辆；
- 用 KITTI 预训练权重 + 仿真点云 fine-tune；
- ONNX Runtime CPU 推理，预计 30–50 ms/帧（满足 10 Hz）。

### 8.4 推荐路线

| 阶段 | 时间 | 方案 | 目标 |
|------|------|------|------|
| 短期 | 1 周 | 方案 B 极简桶统计 | 上线前车距离告警，验证数据流 |
| 中期 | 1 月 | 方案 A DBSCAN + BEV | 完整前车 box + relative_speed + HUD 渲染 |
| 长期 | 视需求 | 方案 C PointPillars-lite | 真实 LiDAR 接入或多类检测 |

**关键原则**：保持 AuroraDrive 的轻量、纯 CPU、无 Python 推理依赖的特性，不要为了"用上 PointPillars"而引入与项目定位不匹配的重型依赖。

---

## 9. 总结

| 主题 | 关键结论 |
|------|---------|
| PointPillars | Apollo 默认检测器，柱体编码 + 2D CNN，62 Hz，TensorRT 友好，工业落地首选 |
| CenterPoint | 两阶段 center-based，nuScenes 65.5 NDS，无 NMS、自带速度、跟踪 ~1 ms，Apollo 7.0+ 高性能替代 |
| VoxelNet | 3D 检测起点，VFE + 3D Conv + RPN，精度高但 4.4 Hz 慢，Apollo 仅作 CenterPoint backbone 候选 |
| Apollo 源码 | `lidar_detection/` 提供 4 个 detector 插件，Pipeline 7 阶段，工厂模式可热插拔 |
| 点云预处理 | 4 步过滤 + HDMap ROI（位图） + RANSAC 地面分离（粗细双层网格 + SSE2） |
| 后融合 | ProbabilisticFusion 后融合，HM 数据关联 + Kalman/DS/Pbf 多滤波器，主传感器 = LiDAR，支持单传感器降级 |
| AuroraDrive 决策 | 暂不升级 PointPillars/CenterPoint（算力/数据/定位不匹配），推荐 DBSCAN + BEV 简化方案 |

**核心启示**：
1. Apollo 的工程价值不仅在算法，更在 Pipeline 工程化——预处理、ROI、地面分离、ObjectBuilder、ObjectFilterBank、Fusion、Tracking 全链路解耦，每一段都可独立替换；
2. PointPillars 之所以成为工业默认，是**速度精度部署三者的最优平衡**，而非单点最优；
3. CenterPoint 代表了**中心点范式**对 anchor 范式的全面胜出，是当前 3D 检测主流；
4. AuroraDrive 这类轻量仿真应用，应遵循"够用即可"原则，用规则/聚类解决 80% 场景，留 20% 给未来模型升级。

---

## 参考资料

### 论文
1. PointPillars: Fast Encoders for Object Detection from Point Clouds — arXiv:1812.05784, CVPR 2019
2. Center-based 3D Object Detection and Tracking — arXiv:2006.11275, CVPR 2021
3. VoxelNet: End-to-End Learning for Point Cloud Based 3D Object Detection — arXiv:1711.06396, CVPR 2018

### Apollo 源码
4. https://github.com/ApolloAuto/apollo/tree/master/modules/perception/lidar_detection
5. https://github.com/ApolloAuto/apollo/blob/master/modules/perception/lidar_detection/detector/point_pillars_detection/point_pillars_detection.cc
6. https://github.com/ApolloAuto/apollo/tree/master/modules/perception/lidar_detection/detector/center_point_detection
7. modules/perception/fusion/lib/fusion_system/probabilistic_fusion/probabilistic_fusion.cc
8. modules/perception/lidar/lib/pointcloud_preprocessor/pointcloud_preprocessor.cc
9. modules/perception/lidar/lib/object_builder/
10. modules/perception/pipeline/config/lidar_detection_pipeline.pb.txt

### 技术解析
11. 自驾 Apollo 源码分析系列（感知篇七/八）— 腾讯云开发者社区
12. apollo 自动驾驶-感知-地图 ROI 过滤：pointcloud_map_based_roi — CSDN
13. apollo 自动驾驶-感知-点云地面检测：pointcloud_ground_detection — CSDN
14. apollo 自动驾驶-感知-激光雷达检测：lidar_detection — CSDN
15. apollo 自动驾驶-感知-激光雷达检测目标过滤：lidar_detection_filter — CSDN
16. Apollo 7.0 perception lidar 源码剖析（万字长文） — CSDN
17. Apollo 感知解析之 MinBox 障碍物边框构建 — CSDN
18. Apollo 融合感知篇 - 公用数据结构 Object and Frame — CSDN
19. Apollo 5.0 源码学习笔记（二）感知模块融合模块 — CSDN
20. CVPR2021 CenterPoint 基于点云数据的 3D 目标检测与跟踪 — 腾讯云
21. 激光点云 3D 目标检测算法之 PointPillars — 火山引擎开发者社区
22. CenterPoint 论文和代码解析 — CSDN
23. 3D 检测：从 PointNet, VoxelNet, PointPillar 到 CenterPoint — CSDN
24. 飞桨携手 Apollo 共建 Paddle3D 自动驾驶感知能力 — CSDN
25. Apollo 7.0 感知模块（3/4）激光雷达感知中的目标跟踪算法 — CSDN

### AuroraDrive 内部文档
26. /Users/dupi/Desktop/自动驾驶系统/AuroraDrive项目交接文档.md
27. /Users/dupi/Desktop/自动驾驶系统/cpp/include/ad/sensors.h (render_lidar)
28. /Users/dupi/Desktop/自动驾驶系统/cpp/include/ad/simulator.h (render_lidar_from_map 复用缓冲)
29. /Users/dupi/Desktop/自动驾驶系统/src/model.py (PointNetLite, M9Model)
30. /Users/dupi/Desktop/自动驾驶系统/src/cpp_bridge.py (make_grid_index)
31. /Users/dupi/Desktop/自动驾驶系统/chapters/04_仿真主循环与调度系统.md

---

> **实际工具调用次数：52 次**（WebSearch 22 次 + WebFetch 18 次 + Read/Grep/Glob/RunCommand/TodoWrite 共 12 次）
>
> **报告字数：约 6800 字**（不含表格与代码块）
