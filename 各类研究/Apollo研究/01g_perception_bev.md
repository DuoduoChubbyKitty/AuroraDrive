# Apollo 9.0 BEV 感知实现深度研究报告

> 研究主题：百度 Apollo 9.0 鸟瞰图（BEV）感知的实现细节、与学术方案对比、以及对 AuroraDrive 后融合架构升级 BEV 的决策建议
> 研究方法：WebSearch + WebFetch，覆盖 Apollo 源码、Paddle3D、BEVFormer/BEVDet/LSS/PETR 论文解读、Apollo 10.0/11.0 演进资料
> 关键结论：**Apollo 9.0 开源版 `camera_detection_bev` 模块实际采用的是旷视 PETR（Position Embedding Transformation）路线，而非 LSS 或 BEVFormer 的 SCA**；Apollo 11.0 已全面升级为 BEV + OCC 架构

---

## 一、Apollo-Lite BEV 架构

### 1.1 纯视觉分支定位

Apollo 的感知体系长期以 LiDAR 为主、相机为辅。Apollo-Lite 是百度推出的**纯视觉（camera-only）高阶辅助驾驶产品线**，对标特斯拉 FSD，其核心思路是用多相机环视系统替代 LiDAR。2023 年 9 月，百度在 Apollo Lite 基础上，用 **4D BEV Transformer** 全新升级第二代纯视觉感知系统，同时配合**占用网络（OCC, Occupancy Network）**技术，对静态环境做端到端实时重建，宣称可获取比激光雷达点云分辨率更高的三维结构信息，实现对激光雷达的替代。这套 "BEV + Transformer + OCC" 组合拳被百度视为减少漏检、误检、弥补视觉空间高度信息缺失的关键。

需要注意的是，**商业产品 Apollo-Lite 的 4D BEV Transformer 与开源 Apollo 仓库中的 `camera_detection_bev` 模块并不完全等同**：前者是百度量产方案的闭源演进，后者是开源给社区的标准实现。本报告以开源仓库为准进行源码级分析。

### 1.2 多相机输入统一到 BEV 坐标系

开源版 `camera_detection_bev` 模块采用 6 路环视相机输入，对应 nuScenes 标准布局：

| 相机通道 | 作用 |
|---|---|
| `/apollo/sensor/camera/CAM_BACK/image` | **主触发相机**，决定 proc 调用时机 |
| `/apollo/sensor/camera/CAM_FRONT/image` | 前视 |
| `/apollo/sensor/camera/CAM_FRONT_RIGHT/image` | 右前 |
| `/apollo/sensor/camera/CAM_BACK_RIGHT/image` | 右后 |
| `/apollo/sensor/camera/CAM_BACK_LEFT/image` | 左后 |
| `/apollo/sensor/camera/CAM_FRONT_LEFT/image` | 左前 |

关键设计：组件 `CameraDetectionBevComponent` 继承自 `cyber::Component<>`（无模板参数的定时/事件混合触发），由 CAM_BACK 的图像到达触发 `OnReceiveImage`，其余 5 路相机通过 `readers_[i]->Observe()` + `GetLatestObserved()` 获取最近一帧。这种"主相机触发 + 其余取最新"的策略本质上是一种**软同步**，避免了硬触发带来的硬件成本，但会引入亚帧级的时间戳偏差。

多相机统一到 BEV 坐标系的方式取决于 View Transformer 算法。Apollo 开源版用的是 **PETR 路线**：它不显式构造 BEV 网格，而是把 3D 空间的位置信息编码成 position embedding 注入到 2D 图像特征中，让 object query 直接在 3D 语义空间中更新。而 Apollo 园区版及 LSS-like 实现则会显式构建 BEV 网格。

### 1.3 View Transformer 实现（基于相机内外参的特征投影）

Apollo 开源版的"View Transformer"是隐式的、由 PETR 的 3D Position Embedding 完成。其核心流程：

1. **图像特征提取**：6 路图像经 backbone（VoVNet 等）提取多尺度 2D 特征。
2. **3D 位置编码生成**：利用相机内参 + 外参（`img2lidar` 矩阵），把 3D 空间离散点云投影回各相机图像平面，得到每个 2D 像素对应的 3D 位置，再经 MLP 编码成 position embedding，与 2D 特征相加，生成 **3D position-aware 特征**。
3. **Object Query 在 3D 空间更新**：DETR-style 的 object query 通过与 3D-aware 特征做全局 attention 直接回归 3D 框，**省去了 BEVFormer 的参考点反投影和特征采样两步**。

这就是 PETR 相对 BEVFormer 的核心简化：**无需显式 BEV 网格、无需 deformable attention 采样**，全部用标准 multi-head attention 完成。

### 1.4 BEV 特征图分辨率与覆盖范围

对于显式构建 BEV 网格的方案（LSS/BEVDet/BEVDepth 路线，Apollo 园区版及部分闭源分支采用），典型参数沿用 nuScenes 习惯：

- **覆盖范围**：x 轴 -50m ~ +50m，y 轴 -50m ~ +50m，z 轴 -10m ~ +10m，即 **100m × 100m** 的水平覆盖
- **BEV 分辨率**：常见 **200 × 200**（单元 0.5m）或 **180 × 320**（适配非正方形 ROI）
- **体素离散**：LSS 把每条相机射线离散为 D=72 段深度，生成 (H, W, D) 的 frustum 特征

而 PETR 路线（Apollo 开源 master 分支）**不显式定义 BEV 分辨率**，其"分辨率"等价于 object query 的数量与 3D position embedding 的采样密度，是一种隐式表达。这也解释了为什么 Apollo 仓库里看不到 200×200 这种硬编码 BEV 尺寸——它是 PETR 的 query 数决定的。

### 1.5 时序融合（TSA 类似机制）

PETR 的原始论文（ECCV 2022）是单帧的；**PETRv2** 引入了时序建模：把上一帧的 3D position-aware 特征按 ego-motion 对齐后，与当前帧特征拼接，通过共享 attention 实现时序融合，显著提升速度估计与遮挡物体检测。

Apollo 开源版的 `bev_obstacle_detector.cc` 中 `Detect()` 是单帧接口，但从 Paddle3D 的 PETRv2-BEV 训练资料看，百度实际部署的模型具备时序能力。这对应 BEVFormer 的 **TSA（Temporal Self-Attention）**思想：用历史 BEV 特征做循环融合，配合 ego-motion 补偿。BEVDet4D 则是另一条路：把前一帧 BEV 特征按 ego-pose 变换到当前帧坐标系后再 concat，再做速度回归。三者在"时序对齐靠 ego-pose"这一点上是相通的。

---

## 二、BEVObstacleDetector 实现细节

### 2.1 源码结构

开源仓库 `modules/perception/camera_detection_bev/` 的目录布局：

```
├── camera_detection_bev/
│   ├── detector/
│   │   └── petr/                      # BEVObstacleDetector 实现
│   │       ├── bev_obstacle_detector.h
│   │       ├── bev_obstacle_detector.cc
│   │       ├── postprocess.h/.cc      # GetObjects 后处理
│   │       └── preprocess.h/.cc       # Resize/Crop/Normalize
│   ├── interface/
│   │   └── base_obstacle_detector.h   # 抽象基类
│   ├── proto/
│   │   └── camera_detection_bev.proto # ModelParam 配置定义
│   ├── camera_frame.h                 # CameraFrame 数据结构
│   ├── camera_detection_bev_component.h/.cc  # Cyber 组件
│   ├── conf/
│   │   ├── camera_detection_bev_config.pb.txt
│   │   └── petr.pb.txt                # 模型参数（resize/crop/normalize/阈值）
│   ├── dag/camera_detection_bev.dag
│   └── README.md
```

### 2.2 类继承关系

`BEVObstacleDetector` 继承自 `BaseObstacleDetector`。基类定义在 `interface/base_obstacle_detector.h`：

```cpp
struct ObstacleDetectorInitOptions : public BaseInitOptions {
  int image_height;
  int image_width;
  Eigen::Matrix3f intrinsic;
};

class BaseObstacleDetector {
 public:
  virtual bool Init(const ObstacleDetectorInitOptions &options) = 0;
  virtual bool Detect(CameraFrame *frame) = 0;
  virtual std::string Name() const = 0;
  virtual bool InitNetwork(const common::ModelInfo &model_info,
                           const std::string &model_root);
 protected:
  int gpu_id_ = 0;
  std::shared_ptr<inference::Inference> net_;
};
PERCEPTION_REGISTER_REGISTERER(BaseObstacleDetector);
#define REGISTER_OBSTACLE_DETECTOR(name) \
  PERCEPTION_REGISTER_CLASS(BaseObstacleDetector, name)
```

通过 `PERCEPTION_REGISTER_REGISTERER` 宏实现插件化注册，`bev_obstacle_detector.cc` 末尾的 `REGISTER_OBSTACLE_DETECTOR(BEVObstacleDetector);` 完成注册，配置文件中 `plugin_param.name: "BEVObstacleDetector"` 即可加载。

### 2.3 Init 网络加载

`BEVObstacleDetector::Init()` 流程：

1. 读取 `petr.pb.txt`（`petr::ModelParam`，含 resize/crop/normalize/score_threshold/class_names 等）
2. `InitTypes()`：把 nuScenes 类别名（car/truck/bus/pedestrian/motorcycle/bicycle/traffic_cone/barrier 等）映射到 Apollo `ObjectSubType` 枚举，存入 `types_`
3. `InitImageSize()`：根据 resize 参数计算网络输入尺寸 `width_`/`height_`
4. `InitNetwork(model_info, model_path)`：调用基类实现，通过 `inference::Inference` 工厂创建推理引擎。**Apollo 默认用 PaddlePaddle（`paddle_net`）**，配置 `--use_trt=true` 后可走 TensorRT；也可经 ONNX 子图拆分后部分走 TRT。

模型权重通过 `GetModelPath(model_info.name())` 解析，预训练权重来自 `apollo-pkg-beta.cdn.bcebos.com/perception_model/petrv1.zip`，即 Paddle3D 训练的 PETRv1 模型。

### 2.4 Detect 函数流程

`Detect(CameraFrame *frame)` 是核心推理入口，流程如下：

```cpp
bool BEVObstacleDetector::Detect(CameraFrame *frame) {
  // 1. 取输入 blob
  auto input_img_blob = net_->get_blob(model_inputs[0].name());        // 图像
  auto input_img2lidar_blob = net_->get_blob(model_inputs[1].name());  // 外参
  // 2. 图像预处理：6 路相机 resize/crop/normalize 拼接
  ImagePreprocess(frame, input_img_blob);
  // 3. 外参填充：img2lidar 矩阵写入第二个输入
  ImageExtrinsicPreprocess(input_img2lidar_blob);
  // 4. 网络前向
  net_->Infer();
  // 5. 取输出 blob：bbox / score / label
  auto output_bbox_blob  = net_->get_blob(model_outputs[0].name());
  auto output_score_blob = net_->get_blob(model_outputs[1].name());
  auto output_label_blob = net_->get_blob(model_outputs[2].name());
  // 6. 后处理：按 score_threshold 过滤，转 Object
  GetObjects(output_bbox_blob, output_label_blob, output_score_blob,
             types_, threshold, &frame->detected_objects);
  // 7. 坐标系转换：nuScenes -> Apollo
  Nuscenes2Apollo(&frame->detected_objects);
  return true;
}
```

**输入**：6 路相机图像（经预处理拼接成 `[6, 3, H, W]`）+ `img2lidar` 外参矩阵（6 组相机到 LiDAR 坐标系的 4×4 变换，约 404 bytes，与 dump 出来的 `input_img2lidars.bin` 大小一致）。注意：Apollo 把 ego pose 在**组件层**通过 `TransformWrapper::GetSensor2worldTrans` 单独查询，而**相机外参**作为网络输入——PETR 只需要相机外参即可生成 3D position embedding，ego pose 用于把检测结果转到世界坐标系。

**输出**：BEV/3D 空间下的障碍物，每个 Object 含 `center(x,y,z)`、`theta`、`length/width/height`、`direction`、`velocity(vx,vy)`、`type/sub_type`、`confidence`，即标准 3D Box（9 自由度：x,y,z,w,l,h,yaw,vx,vy）。

### 2.5 Nuscenes2Apollo 坐标系转换

nuScenes 与 Apollo 的车辆坐标系定义不同（朝向、x/y 轴方向），`Nuscenes2Apollo` 做绕 z 轴逆时针 90 度旋转：

```cpp
obj->theta -= M_PI / 2;
obj->direction[0] = cosf(obj->theta);
obj->direction[1] = sinf(obj->theta);
Eigen::AngleAxisd rotation_vector(-M_PI / 2, Eigen::Vector3d(0, 0, 1));
obj->center = rotation_vector.matrix() * obj->center;
```

这是模型在 nuScenes 上训练、部署到 Apollo 时必须做的对齐步骤。

### 2.6 组件层 OnReceiveImage 流程

`CameraDetectionBevComponent::OnReceiveImage` 完成端到端：

1. 计算 `msg_timestamp = msg->measurement_time() + timestamp_offset_`
2. 遍历 6 路 `readers_`，`Observe()` + `GetLatestObserved()`，`FillImageData` 填入 `frame_ptr_->data_provider[i]`
3. `detector_->Detect(frame_ptr_.get())` 推理
4. `trans_wrapper_->GetSensor2worldTrans(msg_timestamp, &lidar2world_trans)` 查 ego pose
5. `CameraToWorldCoor(lidar2world_trans, &frame_ptr_->detected_objects)` 把检测框从相机/LiDAR 坐标系转到世界坐标系
6. `MakeProtobufMsg` 打包成 `PerceptionObstacles`，通过 `writer_->Write` 发布到 `/apollo/perception/obstacles`

---

## 三、View Transformer 算法

### 3.1 LSS（Lift-Splat-Shoot）思想

LSS（Phil et al., NVIDIA, ECCV 2020）是 BEV 感知的奠基性工作，三步走：

- **Lift**：对每个 2D 像素，预测离散深度分布（D 个 bin，如 D=72），把 2D 特征"抬升"成沿射线的 D 个 3D frustum 点特征（外积：特征 × 深度概率）。
- **Splat**：利用相机外参把 frustum 点变换到 ego 车辆坐标系，再按 BEV 网格做 voxel pooling（sum pooling），得到 `[C, H_bev, W_bev]` 的 BEV 特征图。
- **Shoot**：在 BEV 特征图上接 segmentation/detection head。

LSS 显式估计深度，是**自下而上（bottom-up）**的几何驱动方法。典型配置：x/y ∈ [-50m, 50m]，z ∈ [-10m, 10m]，BEV 200×200，0.5m/格。BEVDet、BEVDepth、BEVDet4D 都基于 LSS 改进。

### 3.2 BEVFormer 的 SCA（Spatial Cross-Attention）

BEVFormer（ECCV 2022, nuScenes NDS 56.9%）走**自上而下（top-down）**的 attention 路线，三大组件：

- **BEV Queries**：可学习的网格状参数 `[H_bev, W_bev, C]`，是 BEV 特征的"占位符"。
- **SCA（Spatial Cross-Attention）**：把每个 BEV query 提升为 3D 柱体，在柱体上采样 4 个 z 高度的 3D 参考点，用相机内外参投影回各相机 2D 图像，在投影点附近做 deformable attention 采样特征，聚合到 BEV query。**不显式估计深度**，靠 attention 自适应学习。
- **TSA（Temporal Self-Attention）**：把上一帧 BEV 特征按 ego-motion 对齐后，与当前帧 BEV query 做 self-attention，实现时序融合。

BEVFormer 不依赖深度估计，但对算力要求高（deformable attention + 多层 encoder）。

### 3.3 BEVDet 的深度估计 + 投影

BEVDet（2021）是 LSS 的工程化封装，4 个模块：image encoder（ResNet/Swin）、view transformer（LSS）、BEV encoder、detection head（CenterPoint）。BEVDepth 在 BEVDet 基础上用 LiDAR 点云监督深度估计，显著提升深度质量，是当前低算力平台落地的主流方案。BEVDet-Tiny 在 nuScenes val 上 mAP 31.2%、NDS 39.2%，仅需 FCOS3D 11% 的算力（215.3 GFLOPs），15.6 FPS。

### 3.4 PETR：Apollo 的实际选择

PETR（旷视, ECCV 2022）的核心洞察：**不必显式构建 BEV 网格，把 3D 位置直接编码进 2D 特征即可**。

- 生成 3D position embedding：在 3D 空间采样点，投影到各相机图像，得到 2D 像素的 3D 坐标，MLP 编码。
- 与 2D 图像特征相加 → **3D position-aware 特征**。
- Object query 直接与 3D-aware 特征做标准 multi-head attention，回归 3D 框。

优点：① 保留 DETR 端到端特性；② 避免 2D→3D 投影和特征采样的复杂工程；③ 全局 attention 天然处理多视图重叠。缺点：全局 attention 计算量大，PETRv1 在 nuScenes val mAP 34.79%、NDS 37.02%（VoVNet backbone, 800×320 输入）。

### 3.5 Apollo 实际方案对比

| 方案 | View Transformer | 深度估计 | 时序 | BEV 网格 | Apollo 是否采用 |
|---|---|---|---|---|---|
| LSS | Lift+Splat（显式） | 显式预测 | 无（BEVDet4D 扩展） | 显式 200×200 | 园区版/LSS-like 分支可能用 |
| BEVDet | LSS 工程化 | 显式预测 | BEVDet4D concat | 显式 | 否 |
| BEVFormer | SCA（attention） | 无（隐式） | TSA | 显式 BEV query | 否 |
| **PETR** | **3D Pos Embedding** | **无** | **PETRv2** | **无（隐式）** | **是（开源 master）** |
| BEVDepth | LSS + LiDAR 监督 | LiDAR 监督 | BEVDet4D | 显式 | 否 |

**结论：Apollo 开源 `camera_detection_bev` 用的是 PETR 路线**，这是最接近的实现。Apollo-Lite 量产的 4D BEV Transformer 可能融合了 BEVFormer/PETRv2 的思想，但未开源。LSS 在 Apollo 中的实现主要体现在园区版和占用网络（OCC）分支的特征投影环节。

---

## 四、多相机融合

### 4.1 时间戳对齐

Apollo 采用**主相机触发 + 其余取最新帧**的软同步策略。`OnReceiveImage` 由 CAM_BACK 图像到达触发，其余 5 路通过 `cyber::Reader::Observe()` 非阻塞拉取最近一帧。不同相机曝光时间差异（通常 < 50ms）通过 `timestamp_offset_` 配置项微调。这种策略的好处是无需硬件同步触发线，缺点是存在亚帧级时间偏差，对高速运动物体可能引入"鬼影"。

PETR 路线对时间偏差相对鲁棒，因为它把每路相机的 3D position embedding 独立计算，重叠区域的物体可在多个视图的 attention 中自然聚合；BEVFormer 的 SCA 由于要采样 3D 参考点投影，对相机间时间一致性更敏感。

### 4.2 ego pose 查表（TransformWrapper::GetSensor2worldTrans）

Apollo 的 ego pose 来自定位模块（`/apollo/localization/pose`），通过 `TransformWrapper` 封装查询。其底层是 `tf2_ros::Buffer`（ROS tf2 的坐标变换缓冲），`TransformWrapper::query_trans` 调用 `tf2_buffer_->lookupTransform` 按时间戳插值查询。

在 `camera_detection_bev` 中：

```cpp
Eigen::Affine3d lidar2world_trans;
if (!trans_wrapper_->GetSensor2worldTrans(msg_timestamp, &lidar2world_trans)) {
  AERROR << "Failed to get camera to world pose";
}
CameraToWorldCoor(lidar2world_trans, &frame_ptr_->detected_objects);
```

注意变量名是 `lidar2world_trans`——因为 Apollo 把 LiDAR 坐标系作为车辆基准坐标系，相机检测结果先在 LiDAR 坐标系（由 img2lidar 外参保证），再用 lidar2world 转世界。`GetSensor2worldTrans` 内部会按 `sensor_name` 解析具体是哪个传感器到 world 的变换。

LiDAR 检测链路中还有 `lidar_query_tf_offset_`（默认几毫秒）用于补偿点云扫描时间与时间戳的差异，BEV 相机链路一般不需要这个偏移。

### 4.3 相机间特征对齐

PETR 的对齐是隐式的：每路相机的 3D position embedding 由其**各自的 img2lidar 外参**生成，6 路特征在 attention 层自然对齐到统一的 LiDAR 坐标系。`bev_obstacle_detector.cc` 的 `ImageExtrinsicPreprocess` 把 `k_data_`（6 组外参，离线计算好）填入网络第二个输入 blob。Apollo 提供了三种外参来源：nuScenes 原始外参、Apollo BEV 模型自带外参、Apollo 园区版 `nuscenes_165` 标定外参，三者需根据部署场景选择。

### 4.4 重叠区域处理

PETR 通过全局 attention 让重叠区域的 object query 同时从多个相机特征聚合信息，天然去重，**无需传统后融合的 IoU-NMS 跨相机去重**。这相比 Apollo 8.0 的多阶段相机检测（每路相机独立检测 → 跨相机后融合关联 → NMS 去重）是显著简化。这也是 BEV 范式被推崇的核心原因之一：**把"多相机融合"从后处理规则变成了网络内的 attention**。

---

## 五、BEV 与 LiDAR 的对比

### 5.1 Apollo 8.0 LiDAR 检测 vs Apollo 9.0 BEV 检测

**Apollo 8.0 LiDAR 检测**（`lidar_detection` 模块）流程：点云输入 → 预处理 → 地面分割 → 聚类/PointPillars-CenterPoint 检测 → 3D 框拟合 → 速度估计（在 `lidar_tracking` 中完成）→ 目标过滤（ROI/策略/背景过滤器）。依赖密集点云，精度高、深度直接测量，但对稀疏远距离、雨雾天气退化。

**Apollo 9.0 BEV 检测**（`camera_detection_bev`，PETR）：6 路相机 → 端到端回归 3D 框 + 速度。无点云依赖，成本低，语义丰富，但深度间接估计、对训练数据依赖重。

### 5.2 精度对比

| 指标 | LiDAR（CenterPoint 基线） | BEV 相机（PETRv1） | BEV 相机（BEVFormer） |
|---|---|---|---|
| nuScenes val mAP | ~40-50% | 34.79% | ~48-56% |
| nuScenes val NDS | ~50-60% | 37.02% | 56.9%（test SOTA） |
| nuScenes mini_val mAP | ~34.2%（基线） | ~29.3%（PETRv2-BEV） | — |
| 深度精度 | 直接测量（cm 级） | 间接估计（米级误差） | 间接估计 |
| 远距离（>50m） | 强 | 弱（深度发散） | 中等 |

实测数据显示：PETRv2-BEV 在 nuScenes mini_val 上 29.3% mAP，与 LiDAR 基线 34.2% 差距约 5 个百分点，**属于工程可接受范围**；BEV 的优势不在绝对精度，而在空间一致性与多任务潜力。BEVFormer 在 nuScenes test 上 NDS 56.9%，号称与 LiDAR 基线相当，但这是在大模型 + 多帧时序 + 充分训练条件下。

### 5.3 计算量对比

Apollo BEV 模型在 Tesla T4 上未优化时 `BEVObstacleDetector::Detect` 单帧 **2067ms**（远超实时），其中 PaddleNet 推理占 1924ms。经 ONNX 子图拆分 + TensorRT 优化后：

| 优化策略 | Tesla T4 延迟 | Jetson Orin 延迟 | 精度（cosine） |
|---|---|---|---|
| 原始 PaddleNet FP32 | 2067 ms | 594 ms | 1.0 |
| TRT FP16（全模型） | 615 ms | — | 0.55（精度异常） |
| **TRT INT8（Backbone 子图）+ Paddle 后处理** | **376 ms** | **123 ms** | 0.996 |

最佳方案是把模型拆成纯 CNN backbone（TRT INT8 加速，93ms）+ 后处理子图（Paddle 推理，283ms），T4 上提速 **5.1 倍**，Orin 上提速 **4.8 倍**。即便如此，123ms 单帧（~8 FPS）距离 10Hz 实时仍有差距，需进一步优化后处理子图（Orin 上后处理数值误差大）。

对比 LiDAR：PointPillars-CenterPoint 在 Orin 上通常 30-50ms（20+ FPS），**BEV 相机算力开销约为 LiDAR 的 3-5 倍**。

### 5.4 极端场景表现

RoboBEV 基准（评估 33 个 BEV 模型）的关键发现：

- **夜晚/黑暗**：所有 BEV 相机方案显著退化，BEVerse(Swin-S)、PETR(VoV) 在黑暗中表现不佳。LiDAR 不受光照影响，优势明显。
- **雨雪**：相机图像质量下降，BEV 性能退化；PETR(VoV) 在雪天相对韧性较好。LiDAR 在大雪中点云被雪花散射，也会退化但程度较轻。
- **逆光/过曝**：相机局部过曝导致特征丢失，BEV 漏检；LiDAR 不受影响。
- **相机故障**：BEVerse(Swin-S) 对单相机崩溃韧性强；多模态模型可降级到 LiDAR。
- **增强策略**：① 预训练（imageNet 自监督）显著提升鲁棒性；② 无需深度的 BEV 转换（如 PETR/BEVFormer）比依赖深度的（LSS）更鲁棒；③ 充分利用时序信息显著提升韧性；④ 基于 CLIP 的特征增强有效。

### 5.5 Apollo 10.0/11.0 是否融合两者

**Apollo 10.0** 感知模块目录包含 `camera_detection_bev`（BEV 目标检测，主流感知范式）、`camera_detection_occupancy`（占用网络，纯视觉）、`camera_detection_single_stage`（YOLOX+YOLO3D）、`camera_detection_multi_stage`、`lidar_detection`、`fusion` 等，**BEV 与 LiDAR 并存**，通过 `fusion` 模块做多传感器融合。

**Apollo 11.0**（2026 年 1 月发布）感知方面**全面升级为 BEV 感知架构 + OCC 占用网络**，显著提升对路缘、挡墙、路面坑洼等不规则静态障碍物的感知能力。同时 Apollo 11.0 聚焦功能型无人车（自动脱困、贴边行驶、回库泊车），端到端作业流程。可以说，Apollo 11.0 已经把 BEV + OCC 作为感知主范式，LiDAR 在某些配置中仍作为补充/冗余，但视觉 BEV 成为主轴。这与百度公开宣传的 "BEV+Transformer+OCC 替代激光雷达" 路线一致。

---

## 六、与 BEVFormer/BEVDet 对比

### 6.1 学术界主流 BEV 方案

- **BEVFormer**（ECCV 2022）：时空 Transformer，SCA + TSA，deformable attention，nuScenes NDS 56.9%。代表 attention 路线巅峰。
- **BEVDet**（2021）：LSS 工程化，CenterPoint head，BEVDet-Tiny mAP 31.2%/NDS 39.2%。代表显式深度路线。
- **BEVDet4D**（2022）：BEVDet + 时序，BEV 特征 ego-motion 对齐后 concat，速度估计大幅提升。
- **BEVDepth**（旷视 2022）：BEVDet + LiDAR 监督深度，低算力落地主流。
- **BEVerse**（2022）：Swin Transformer backbone，多任务（检测+分割+运动预测），对相机故障韧性强。
- **PETR/PETRv2**（旷视 ECCV 2022）：3D position embedding，无显式 BEV 网格，全局 attention，PETRv2 引入时序与多任务。
- **DETR3D**（CoRL 2021）：BEVFormer 前身，object query 反投影采样，开创 query-based 路线。

### 6.2 Apollo-Lite BEV 与学术方案的差异

| 维度 | Apollo 开源（PETR） | Apollo-Lite 量产（4D BEV Transformer） | BEVFormer | BEVDet | LSS |
|---|---|---|---|---|---|
| View Transformer | 3D Pos Embedding | 4D 时空 Transformer（闭源） | SCA | LSS | Lift-Splat |
| 深度估计 | 无 | 隐式 | 无 | 显式预测 | 显式预测 |
| 时序 | PETRv2（可选） | 4D 时序融合 | TSA | BEVDet4D concat | 无 |
| 检测头 | DETR-style query | 闭源 | Deformable DETR | CenterPoint | Seg head |
| 训练框架 | PaddlePaddle/Paddle3D | 闭源 | PyTorch/MMDetection3D | PyTorch | PyTorch |
| 部署 | Paddle Inference + TRT | 自研芯片/Orin | TRT | TRT | TRT |
| 数据集 | nuScenes | 百度自采集大规模 | nuScenes/Waymo | nuScenes | nuScenes |
| 工程化重点 | 坐标系转换、TRT 量化 | 量产优化、OCC 联动 | 学术 SOTA | 低算力落地 | 学术奠基 |

### 6.3 哪个最接近 Apollo 实现

**PETR/PETRv2 最接近 Apollo 开源版实现**——准确说 Apollo 就是用 Paddle3D 的 PETRv1 模型直接部署。Apollo-Lite 量产的 4D BEV Transformer 则更接近 **BEVFormer（SCA+TSA 的时空 Transformer）**，融合了 PETR 的位置编码思想，并加入了 OCC。如果只看开源代码，PETR 是唯一对照；如果看百度公开技术宣传，BEVFormer 是更接近的概念参照。

---

## 七、AuroraDrive 迁移建议

### 7.1 AuroraDrive 当前架构

AuroraDrive 当前是**后融合（late fusion）**架构，核心模型 M9Model：

- **图像分支**：RepVGG backbone 提取 2D 图像特征（RepVGG 通过结构重参数化，训练时多分支提升性能，推理时融合为单路 3×3 卷积，部署高效）
- **点云分支**：PointNet 提取点云特征（逐点 MLP + max pooling，对无序点集不变）
- **FusionHead**：在**检测结果层面**融合——图像分支输出 2D 框 + 类别，点云分支输出 3D 框，FusionHead 做关联（匈牙利匹配/IoU）+ 状态融合（卡尔曼滤波）+ 置信度加权

这是典型的"各传感器独立检测 → 后处理融合"范式，与 Apollo 8.0 的多阶段相机 + LiDAR 后融合思路一致。

### 7.2 升级 BEV 的代价

| 代价项 | 具体内容 | 严重程度 |
|---|---|---|
| 训练数据 | 需大规模多相机 + 3D 标注数据（nuScenes 级，~1000 万帧），AuroraDrive 现有标注可能不够 | 高 |
| 模型训练 | 需训练 BEV 模型（PETR/BEVFormer/BEVDet 选型），Paddle3D/MMDetection3D 工具链，GPU 集群 | 高 |
| ego pose 依赖 | BEV 时序融合 + 坐标系统一强依赖高精度 ego pose，需定位模块（里程计/SLAM）支撑，AuroraDrive 需新增 | 中-高 |
| 算力 | BEV Transformer 单帧 100-400ms（Orin），约为 RepVGG+PointNet 后融合的 3-5 倍，需更强 SOC 或量化 | 高 |
| 工程复杂度 | 多相机同步、外参标定、TRT 量化、坐标系转换（nuScenes→自车坐标系）工程量大 | 中 |
| 调试难度 | 端到端模型可解释性差，badcase 难定位 | 中 |
| 现有资产废弃 | RepVGG/PointNet/FusionHead 的积累部分失效，需重新积累 | 中 |

### 7.3 升级 BEV 的收益

| 收益项 | 具体内容 | 价值 |
|---|---|---|
| 统一坐标系 | 多相机 + LiDAR 在 BEV 空间统一，消除后融合的视角异构性 | 高 |
| 更鲁棒 | 多视图 attention + 时序融合，对遮挡、快速运动更鲁棒 | 高 |
| 多任务扩展 | BEV 特征可同时支撑检测/分割/占用预测/运动预测，复用性强 | 高 |
| 端到端潜力 | BEV 是连接感知-预测-规划的桥梁，为端到端（UniAD 范式）铺路 | 中-高 |
| 跨相机去重简化 | attention 天然处理重叠区，省去后融合 NMS 关联 | 中 |
| 摆脱 LiDAR 依赖（长期） | BEV+OCC 路线可降低对 LiDAR 的硬依赖，降成本 | 中（取决于场景） |
| 业界趋势 | BEV 已成主流，人才/工具链/数据生态成熟，技术债低 | 中 |

### 7.4 决策建议

**结论：AuroraDrive 建议采用"渐进式升级"策略，而非一步到位切换 BEV。** 具体路线：

**阶段一（短期，0-6 个月）：保持后融合，引入特征级中融合**
- 不废弃 M9Model，但在 FusionHead 前增加**特征级融合**：把 RepVGG 的图像特征与 PointNet 的点云特征在 BEV 空间做 feature-level fusion（类似 BEVFusion 思路），保留后融合作为兜底。
- 收益：精度提升、为 BEV 积累工程经验；代价小，无需重训大模型。
- 关键动作：① 给 LiDAR 检测链路加 BEV 特征图输出；② 图像分支加 LSS-like 显式 BEV 投影（可先用预训练深度）。

**阶段二（中期，6-18 个月）：相机分支升级 BEV，保留 LiDAR 兜底**
- 相机分支从 RepVGG 2D 检测升级为 **BEVDet/BEVDepth（LSS 路线，低算力友好）** 或 **PETRv2（与 Apollo 对齐）**，在 BEV 空间输出 3D 框。
- LiDAR 分支保持 PointNet/CenterPoint，与相机 BEV 在 BEV 空间做中融合。
- 收益：统一坐标系、多任务能力、为去 LiDAR 铺路；代价：需训练 BEV 模型、需 ego pose。
- 关键动作：① 数据采集与 3D 标注；② ego pose 链路建设（里程计）；③ 选型：算力紧张选 BEVDet，与 Apollo 对齐选 PETR。

**阶段三（长期，18 个月+）：BEV + OCC 端到端，按需去 LiDAR**
- 引入占用网络 OCC，BEV + OCC 替代部分 LiDAR 功能，向 Apollo 11.0 范式靠拢。
- 探索端到端（感知-预测-规划统一 BEV 特征），对标 UniAD。
- 收益：成本下降、泛化提升；代价：大模型训练、算力、可解释性。

**否决一步到位的理由**：
1. AuroraDrive 当前 ego pose 链路未知，BEV 强依赖 ego pose，缺失则时序融合失效。
2. BEV 模型训练需大数据+大算力，短期内难以达到 LiDAR 精度，存在性能回退风险。
3. 极端场景（夜晚/逆光）BEV 相机显著弱于 LiDAR，AuroraDrive 若用于 L4 场景，安全冗余不足。
4. RepVGG+PointNet 后融合在已知场景已可工作，沉没成本不应轻易废弃。

**触发升级 BEV 的条件（满足任一即可加速）**：
- AuroraDrive 目标场景为 L2/L2+ 辅助驾驶（去 LiDAR 降本是核心诉求）；
- 已具备 ego pose（高精定位/SLAM）能力；
- 算力平台 ≥ Orin 级别且预算允许 TRT INT8 优化；
- 有 ≥ 50 万帧多相机 3D 标注数据；
- 业务需要多任务（检测+分割+占用）统一输出。

**推迟升级 BEV 的信号**：
- L4Robotaxi 场景，LiDAR 是安全冗余刚需；
- 算力受限（< 30 TOPS）；
- 缺乏 ego pose 与大规模标注数据；
- 团队无 Paddle3D/MMDetection3D 经验。

---

## 八、补充：部署工程要点与常见陷阱

在把 Apollo 的 `camera_detection_bev` 真正跑起来时，除了模型本身的算法理解，还有若干工程层面的细节决定了最终能否实时、能否量产，这里集中梳理。

**第一，相机外参的一致性是命门。** PETR 依赖 `img2lidar` 外参生成 3D position embedding，外参标定误差会直接污染位置编码，导致远距离物体深度回归偏移。Apollo 提供了三套外参（nuScenes 原始、模型自带、园区版 `nuscenes_165`），三者不可混用，必须与训练时使用的外参严格一致，否则会出现"近距离检测正常、远距离全部漂移"的诡异现象。实际部署时建议重新标定并在 nuScenes 子集上做回归验证。

**第二，PaddlePaddle 推理引擎的版本耦合很紧。** Apollo 园区版依赖的 `paddle_inference` 版本与模型导出版本必须匹配，否则会出现算子不支持的报错。实测中直接开启 TRT INT8 量化会崩溃，TRT FP16 量化精度异常（cosine 仅 0.55），只有把模型拆成纯 CNN backbone 子图（走 TRT INT8）+ 后处理子图（仍走 Paddle）才能兼顾速度与精度。这种"混合精度 + 双引擎串联"的部署方式是 Apollo BEV 落地的关键经验。

**第三，坐标系转换的易错点。** 模型在 nuScenes 上训练，输出坐标是 nuScenes 车辆坐标系，而 Apollo 用的是另一套车辆坐标系（前向轴不同）。`Nuscenes2Apollo` 做绕 z 轴逆时针 90 度旋转，同时要更新 `theta`、`direction`、`center`、`camera_supplement.local_center` 四个字段，漏掉任何一个都会导致下游预测/规划模块行为异常。这是从 nuScenes 迁移到自研框架时最容易踩的坑。

**第四，时序融合的 ego pose 链路不可缺失。** PETRv2 的时序对齐依赖连续帧之间的 ego-motion，如果定位模块抖动或丢包，时序特征对齐会错位，速度估计会出现"跳变"。Apollo 通过 `TransformWrapper` 的 tf2 缓冲插值缓解，但本质仍要求定位质量达标。AuroraDrive 若要上时序 BEV，必须先把 ego pose 的频率与精度做扎实。

**第五，模型推理延迟与帧率的取舍。** Apollo BEV 在 Orin 上优化后单帧 123ms（约 8 FPS），距离 10Hz 实时仍有差距。常见的折中是降采样输入分辨率（800×320 → 704×256）、减少 object query 数量、或者只在低速园区场景启用 BEV、高速场景回退到传统相机检测。这提示 AuroraDrive 在选型时不能只看论文精度，要结合自车算力预算评估实际帧率。

---

## 九、总结

1. **Apollo 9.0 开源版 `camera_detection_bev` 用的是 PETR（旷视）路线**，而非 LSS 或 BEVFormer。源码位于 `modules/perception/camera_detection_bev/detector/petr/bev_obstacle_detector.cc`，模型用 PaddlePaddle 训练、nuScenes 数据集，6 路相机输入 + img2lidar 外参，输出 3D Box。
2. **BEVObstacleDetector 继承 BaseObstacleDetector**，Init 加载 petr.pb.txt + Paddle 模型，Detect 做"预处理→外参填充→推理→GetObjects→Nuscenes2Apollo 坐标转换"。
3. **View Transformer 在 Apollo 中是隐式的 3D Position Embedding**，不显式构建 BEV 网格；LSS/BEVDet 的显式 200×200 BEV 网格主要出现在园区版与 OCC 分支。
4. **多相机融合靠 PETR 全局 attention + ego pose 查表（TransformWrapper::GetSensor2worldTrans）**，主相机触发 + 其余取最新帧软同步。
5. **BEV 相机 vs LiDAR**：BEV（PETRv2）mAP 落后 LiDAR 约 5 个百分点，算力开销 3-5 倍，夜晚/逆光显著弱于 LiDAR，但空间一致性、多任务、去 LiDAR 潜力是优势。
6. **Apollo 11.0 已全面升级 BEV + OCC**，视觉 BEV 成为主轴，LiDAR 作为补充。
7. **AuroraDrive 建议"渐进式升级"**：先特征级中融合 → 再相机分支 BEV → 最后 BEV+OCC 端到端。不推荐一步到位，核心约束是 ego pose 链路、训练数据、算力平台与安全冗余。

---

## 参考资料

- Apollo 源码：`github.com/ApolloAuto/apollo` `modules/perception/camera_detection_bev/`
- PETR 论文：arxiv.org/abs/2203.05625（ECCV 2022）
- BEVFormer 论文：arxiv.org/abs/2203.17270（ECCV 2022）
- LSS 论文：arxiv.org/abs/2008.05711（ECCV 2020）
- BEVDet/BEVDet4D/BEVDepth：github.com/HuangJunJie2017/BEVDet
- Paddle3D PETR：github.com/PaddlePaddle/Paddle3D
- Apollo 11.0 BEV+OCC：百度 Apollo 开放平台 11.0 文档
- RoboBEV 鲁棒性基准：33 个 BEV 模型极端场景评估

---

**实际工具调用次数：约 59 次**（WebSearch 33 次 + WebFetch 19 次 + Read 6 次 + RunCommand 1 次，其中部分 Read 因临时文件权限失败但调用已发起）
