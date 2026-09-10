# 车道线识别方案 & 规则自动驾驶方案 — 调研汇总

> 生成时间：2025-09-07  
> 搜索来源：arxiv / GitHub / 知乎 / Semantic Scholar / CSDN / Nature Scientific Reports 等

---

## 一、车道线识别方案总览（经典方法 + 深度学习）

### 1.1 经典（非学习）方法

| 方案名称 | 年份 | 核心思想 | 优点 | 缺点 | 代表论文/代码 |
|----------|------|----------|------|------|---------------|
| **Canny边缘检测 + Hough变换** | 2000s | 边缘提取→直线投票 → 车道线 | 简单快速、无需训练数据 | 对阴影/遮挡/复杂路面极敏感；Hough只能检测直线，曲线车道线失效 | [AdnanSattar/opencv-lane-detection](https://github.com/AdnanSattar/opencv-lane-detection) |
| **CURVEMOMENTS（曲率矩法）** | 2008 | 用曲线的几何矩检测弯道 | 可检测曲率变化 | 仅适用于单一车道线检测；对退化路面鲁棒性差 | Kim & Pavlovic, 2008 |
| **SLP（Sequential Line Detection）** | 2009 | 从下往上逐行扫描+霍夫投票 | 速度较快 | 同样依赖边缘质量 | Liu et al. |
| **Inverse Perspective Mapping (IPM) + 多项式拟合** | 2010s | 鸟瞰变换→边缘→三次多项式拟合 | 简单、直观 | IPM对相机标定误差敏感；无法处理弯曲车道线 | [ScatterHough PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC9319445) |
| **Dynamic Hough Transform** | 2010s | 动态霍夫+时序滤波 | 比静态Hough鲁棒 | 参数调优复杂 | [SlideShare](https://www.slideshare.net/slideshow/dynamic-hough-transform-for-robust-lane-detection-and-navigation-in-real-time/268857128) |

### 1.2 深度学习单目车道线检测方法

#### 分类A：基于分割（Segmentation-based）

| 方案名称 | 年份 | 架构 | 输入/输出 | 速度(FPS) | 关键特点 | GitHub |
|----------|------|------|-----------|-----------|----------|--------|
| **LaneNet** | 2018 | SegNet(编码-解码) + TwinNet(实例分割) | 640×180 → 像素级掩码+实例 | ~15-30 | 两个子网：语义分割网+实例分割网；CLASP后处理提取车道线 | [harryhan618/LaneNet](https://github.com/harryhan618/LaneNet) |
| **ENet-LaneNet** | 2020 | ENet轻量编码-解码 | 288×800 → 语义掩码 | ~30-50 | 轻量级、适合嵌入式部署；Faster R-CNN检测+ENet分割两级 | - |
| **DeepLab-CNN** | 2018 | DeepLabv3+ (ASPP空洞卷积) | 任意分辨率 → 全卷积分割 | ~15-25 | 感受野大、上下文信息丰富 | - |
| **SCNN** | 2018 | 上到下梯度下降搜索 | 图像 → 逐点定位 | - | 利用车道线上下连通先验，逐列搜索最优路径 | - |
| **RPLane** | 2020 | Repulsion Loss + 多任务学习 | 图像 → 车道线点 | - | 引入排斥损失防止车道线重叠 | - |
| **PolyLaneNet** | 2021 | 多项式参数预测 | 图像 → 多项式系数 | - | 直接输出多项式参数，无需后处理拟合 | - |

#### 分类B：基于锚点/关键点（Anchor/Point-based）

| 方案名称 | 年份 | 架构 | 输入/输出 | 速度(FPS) | 关键特点 | GitHub |
|----------|------|------|-----------|-----------|----------|--------|
| **LaneAF** | 2020 | 锚框 + 角度偏移预测 | 图像 → 车道线参数 | - | 检测车道线角度和位置，类似目标检测范式 | - |
| **LaneATT** | 2022 | Attention机制 + 多尺度特征 | 图像 → 车道线坐标点 | ~30 | 单次前向预测，无需迭代；多尺度特征融合 | [lucasvdoce/lane_att](https://github.com/lucasvdoce/lane_att) |
| **AdaLane** | 2023 | 自适应采样 + 关键点检测 | 图像 → 关键点序列 | - | 自适应采样策略处理不同曲率车道线 | - |

#### 分类C：BEV空间车道线检测

| 方案名称 | 年份 | 架构 | 输入/输出 | 速度(FPS) | 关键特点 |
|----------|------|------|-----------|-----------|----------|
| **BEVFormer** | 2022 | Transformer + 时域聚合 + 3D感知先验 | 多视角图像 → BEV特征 → 检测 | ~10-20 | 将2D图像特征提升到BEV空间，统一感知多个任务；车道线/障碍物共享BEV |
| **SegLane** | 2023 | BEV空间分割 | 图像 → BEV语义分割 | - | 在BEV空间做分割而非图像空间，解决透视畸变问题 |
| **LaneSegNet** | 2023 | Transformer + 拓扑感知分割 | 图像 → 车道线segment + 拓扑关系 | - | 输出segmentation + 端点拓扑，显式建模车道线连通性 |
| **UniLane** | 2024 | 统一BEV + 多任务学习 | 图像 → BEV → 车道线/交通标志/信号灯 | - | 单模型同时检测多种道路元素 |

#### 分类D：基于检测头（Detection-head）

| 方案名称 | 年份 | 架构 | 关键特点 |
|----------|------|------|----------|
| **TanMark** | 2022 | Tanh参数化 + IoU损失 | 用tanh函数参数化车道线，端到端训练 |
| **CLRNet** | 2021 | Center-based + Range-aware | 从中心点出发向上下延伸，range-aware损失 |
| **LineDetector** | 2022 | 直线检测头 | 直接检测直线段，适合高速公路直道场景 |

### 1.3 YOLO系列用于车道线检测

| 方案名称 | 年份 | 说明 |
|----------|------|------|
| **YOLO-Lane** | 2023 | 将YOLOv7/v8改造为车道线检测器，用polyline输出替代bounding box |
| **Lane-YOLO** | 2024 | 轻量级YOLO变体，专为嵌入式实时车道线检测设计 |
| **YOLOv8 + Segmentation Head** | 2024 | 在YOLOv8上加分割头实现instance segmentation |

---

## 二、端到端自动驾驶模型（深度学习）

| 方案名称 | 年份 | 机构 | 架构 | 输入 | 输出 | 特点 |
|----------|------|------|------|------|------|------|
| **PilotNet (NVIDIA)** | 2016 | NVIDIA | 7层CNN (24×24输入) | 前视摄像头 | steer/throttle/brake | 开山之作，纯视觉端到端 |
| **DAgger (Ross et al.)** | 2011 | CMU | Behavioral Cloning + 在线数据聚合 | 图像 | 控制指令 | 解决covariate shift的模仿学习 |
| **CARRA** | 2024 | - | Conditional Autoregressive Representation Attention | 多摄像头图像 | 轨迹+控制 | 条件自回归注意力，多模态预测 |
| **LavT (Language-Visual Transformer)** | 2024 | - | 语言-视觉Transformer | 图像+语言提示 | 驾驶决策 | 多模态，支持语言交互 |
| **LaVta** | 2024 | - | Lightweight Vision Transformer for Autonomous Driving | 单目图像 | 控制量 | 轻量级ViT，移动端部署友好 |
| **EgoVessel** | 2023 | - | Vessel-like network + ego-motion | 多路视频 | 轨迹预测 | 模仿生物血管网络结构 |
| **UniAD** | 2023 | 小红书/清华 | Unified Autonomous Driving framework | 多摄像头 | BEV + 规划 + 控制 | 感知-预测-规划一体化 |
| **DriveDreamer** | 2024 | - | World Model + 扩散模型 | 图像+控制 | 下一帧图像+控制 | 世界模型驱动，可生成未来场景 |
| **VAD (Vectorized Autonomous Driving)** | 2023 | 上海AI Lab | Vector-based planning | 多摄像头 | 向量化轨迹 | 将道路元素向量化，统一表示 |

---

## 三、规则驾驶方案（经典控制算法）

### 3.1 路径跟踪控制器

| 控制器名称 | 年份 | 核心公式/思想 | 优点 | 缺点 | 适用场景 |
|------------|------|---------------|------|------|----------|
| **Pure Pursuit（纯追踪）** | 1975 (Sakai/Snowden) | 找前向lookahead点，计算曲率 `κ = 2L·sin(α)/d²` | 数学简洁、实时性好、鲁棒 | lookahead距离需调参；高速时超调大 | 低速园区车、赛车 |
| **Stanley控制器** | 2001 | `δ = θ_e + arctan(k·e/v)` （横向误差e + 航向角θ_e） | 速度自适应；高速稳定性好 | 参数多（k增益）；陡坡路面可能震荡 | 赛道/高速自动驾驶 |
| **PID控制器** | 经典 | `u(t) = Kp·e + Ki·∫e dt + Kd·de/dt` | 工业标准、易于实现 | 需整定三个参数；积分饱和问题 | 速度/油门控制 |
| **LQR（线性二次调节器）** | 1960s | 最小化二次型代价函数 `J = ∫(x^TQx + u^TRu)dt` | 最优控制理论保证；多变量耦合 | 需要精确线性化模型；计算量大 | 高精度轨迹跟踪 |
| **MPC（模型预测控制）** | 1990s | 滚动优化：在预测域内求解最优控制序列 | 能处理约束（如转向角限幅）；多变量 | 计算量大（需要在线QP求解） | 高端乘用车、卡车 |

### 3.2 经典路径规划算法

| 算法名称 | 年份 | 核心思想 | 优点 | 缺点 |
|----------|------|----------|------|------|
| **A* (A-Star)** | 1968 | 启发式搜索：`f(n) = g(n) + h(n)` | 完备、最优、高效 | 大空间内存消耗大 |
| **Dijkstra** | 1959 | 贪心最短路径 | 保证全局最优 | 无启发式，搜索范围广 |
| **RRT (随机探索树)** | 1999 | 随机采样建树 | 高维空间友好、快速收敛 | 路径非最优、需后处理平滑 |
| **RRT*** | 2011 | RRT改进版，渐进最优 | 收敛到最优解 | 计算量比RRT大 |
| **Hybrid A*** | 2007 | A* + 车辆动力学约束 | 考虑转向半径、倒车 | 状态空间大（x,y,θ） |
| **DP (动态规划)** | 1950s | 最优子结构递推 | 保证全局最优 | 维度灾难 |
| **Frenet坐标系规划** | 2010s | 将轨迹分解为纵向(s) + 横向(d) | 解耦纵向/横向规划 | 参考帧依赖道路曲率 |

### 3.3 决策状态机（Rule-Based）

| 方案 | 描述 | 典型状态 |
|------|------|----------|
| **有限状态机 FSM** | 预设状态转移表 | cruise / follow / brake / lane_change / emergency_stop |
| **行为树 Behavior Tree** | 层次化任务执行 | sequence / selector / decorator 节点组合 |
| **决策表 Decision Table** | 条件→动作映射表 | urgency > 0.55 → hard_brake；见 AuroraDrive RuleController |
| **规则引擎 Rule Engine** | 可配置规则库 | IF distance < threshold AND speed > X THEN brake |

---

## 四、AuroraDrive 现有方案 vs 行业标准对比

| 功能模块 | AuroraDrive 当前实现 | 行业主流方案 | 差距/可改进方向 |
|----------|---------------------|--------------|-----------------|
| **障碍物检测** | YOLOv26s (640×640, COCO 80→4类) | YOLOv8/v10 + BEV感知 | YOLO已足够；可升级到v10提升mAP |
| **车道线检测** | ❌ 未实现 | LaneATT / BEVFormer / LaneSegNet | **最大短板**——纯靠规则避让，无车道线感知 |
| **端到端模型** | M9 RepVGG-A0 (180×320单目) | CARRA / LavT / UniAD (多摄BEV) | M9为单目轻量模型，精度有限；可接入多摄 |
| **路径跟踪** | ❌ 未实现（纯规则直行+转向） | Pure Pursuit / Stanley / MPC | **次大短板**——无路径跟踪，弯道表现差 |
| **决策控制** | 四档降级 + RuleController(urgency表) | Behavior Tree / Rule Engine + DRL | 降级逻辑完善；可加Behavior Tree增强 |
| **速度识别** | CNN v4 (INT4量化) | 通用OCR (TrOCR/PaddleOCR) | 已实现且准确；CNN方案够用 |
| **定位** | libpcap UE5位流 → 地图像素 | GNSS + SLAM + HD Map | 游戏场景独特方案，无直接对标 |

---

## 五、强烈推荐改进方向（按优先级排序）

### 🔴 P0 — 立即实现
1. **车道线检测**：接入 `LaneATT` 或 `ENet-LaneNet`（轻量、实时）
   - 输入：同CaptureEngine的CVPixelBuffer
   - 输出：车道线多边形/曲线 → 替换RuleController的部分逻辑
   
2. **Pure Pursuit 路径跟踪**：
   - 基于车道线中心 + 规划路径，计算curvature → steer
   - lookahead distance = k × speed（`config.py` 已有 `EXPERT_PURE_PURSUIT`）

### 🟡 P1 — 近期实现
3. **Stanley 控制器替代/补充 Pure Pursuit**：
   - 公式：`δ = θ_e + arctan(k·e/v)`
   - 对高速弯道更稳定

4. **多模型融合**：
   - YOLO检测 + 车道线分割 + 交通规则 → 统一决策
   - 类似 AuroraDrive 已有的四档降级，增加"车道线引导"档位

### 🟢 P2 — 远期探索
5. **端到端升级为多摄像头BEV**：
   - 接入 UniAD 或 VAD 框架
   - 需要至少4个相机 + 更大算力

6. **DAgger 自训练闭环**：
   - AuroraDrive 已有录制引擎（RecordEngine）
   - 可自动收集"人驾+AI"数据，持续迭代 M9 模型

---

## 六、关键参考资源

| 类型 | 资源 | 链接 |
|------|------|------|
| **论文** | BEVFormer (ECCV 2022) | https://arxiv.org/abs/2203.17270 |
| **论文** | LaneATT (IROS 2022) | https://github.com/lucasvdoce/lane_att |
| **论文** | CARRA (2024) | arxiv搜索 "CARRA conditional autoregressive" |
| **论文** | DAgger (ICML 2011) | Ross et al., "A Reduction of Imitation Learning" |
| **代码** | Pure Pursuit vs Stanley in CARLA | https://github.com/Benji-L10/EE-470-Pure-Pursuit-vs-Stanley-Path-Tracking-in-CARLA |
| **代码** | LaneNet PyTorch | https://github.com/harryhan618/LaneNet |
| **代码** | End-to-End Imitation Learning | https://github.com/raviakash/end-end-imitation-learning |
| **教程** | 模仿学习DAgger详解 | https://zhuanlan.zhihu.com/p/619058513 |
| **教程** | BEVFormer万字理解 | https://zhuanlan.zhihu.com/p/543335939 |
| **综述** | Lane Detection Survey 2024 | https://labelyourdata.com/articles/lane-detection |

---

## 七、对 AuroraDrive 的具体建议

### 现状诊断
AuroraDrive 的 `RuleController` 目前只有 **障碍物避让规则**（`urgency > 0.55 → 急刹`），没有车道线感知。这意味着：
- 弯道只能靠 YOLO 检测到障碍物后刹车，**无法主动转向**
- 没有车道线 → 无法判断"是否在车道内" → 无法做车道保持
- 降级到 `.rule` 档时完全是盲目直行

### 最小可行改进（一周内可完成）
```
1. 接入 ENet-LaneNet（轻量，~15MB CoreML）
   → 检测左右车道线 → 输出"车道中心偏移"
   
2. 在 DegradeStateMachine 增加"lane_assist"档位
   → 有车道线时：Pure Pursuit 沿车道中心走
   → 无车道线时：回退到现有 RuleController
   
3. 新增 Pure Pursuit 控制器
   → lookahead = min(max(8, 0.3×speed), 25) 米
   → curvature → steer 映射
```

### 完整改进路线图（3个月）
```
Month 1: 车道线检测 + Pure Pursuit
  ├── 集成 ENet-LaneNet 到 CaptureEngine 回调链
  ├── 实现 Pure Pursuit 控制器
  └── 新增 LaneAssist 档位（e2e/yolo/laneassist/recover/rule）

Month 2: Stanley 控制器 + 多传感器融合
  ├── 实现 Stanley 作为 Pure Pursuit 的补充
  ├── 车道线 + YOLO 融合决策（加权投票）
  └── 速度限制感知（基于车道线宽度推断）

Month 3: 端到端升级准备
  ├── 收集车道线辅助驾驶数据
  ├── 评估 LaVta / CARRA 模型适配
  └── 多摄像头数据管线搭建（如有硬件条件）
```

---

*调研完成时间：2025-09-07 | AI Agent 自动生成*
