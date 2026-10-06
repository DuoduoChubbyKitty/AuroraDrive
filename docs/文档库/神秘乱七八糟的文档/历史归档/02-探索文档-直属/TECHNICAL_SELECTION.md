# AuroraDrive 技术选型方案

> 生成时间：2025-09-07 | 基于已读源码分析 + 网络调研
> （2026-09-19 订正：下文"现状"表已按当前代码/模型清单更新；选型建议与里程碑为 2025-09 决策记录，仍有效。车道线检测等 P0 项截至 2026-09-19 未实施。）

---

## 一、当前系统现状（基于源码分析）

### 1.1 现有感知栈

| 模块 | 文件 | 输入 | 输出 | 状态 |
|------|------|------|------|------|
| 画面捕获 | CaptureEngine.swift | ScreenCaptureKit 30fps | NSImage + CGImage + CVPixelBuffer (4条回调) | ✅ 完整 |
| E2E模型 | InferenceEngine.swift | image[1,3,180,320] + state[1,6] | steer/throttle/brake | ✅ M9 + game_assist_control 双模型 |
| YOLO检测 | YoloEngine.swift | CVPixelBuffer 640×640 | [Detection] × 20 | ✅ yolo26s，直通路径已优化 |
| 速度OCR | SpeedOCRReader.swift | 原生ROI CVPixelBuffer | speedKmh + confidence | ✅ PP-OCRv6 微调 int8 整行（主路径，GPU）/ 逐位 CNN v4 系（备用），字模降级停用 |
| 置信度估计 | ConfidenceEstimator.swift | command + image + isLive | confidence[0,1] | ✅ 三路信号融合 |
| 网络定位 | CoordinateCapture.swift | libpcap tcp/30031 | Pose(x,y,z,pitch,heading) → map pixel | ✅ UE5位流解析完整 |

### 1.2 现有决策栈

| 模块 | 文件 | 逻辑 | 状态 |
|------|------|------|------|
| 四档降级 | DegradeStateMachine.swift | e2e→yolo→rule，滞回0.15，卡住检测3km/h×3s | ✅ 完整 |
| 规则控制器 | RuleController.swift | YOLO urgency表：直行0.8油门 / >0.55急刹 / >0.25减速避让 | ✅ 完整 |
| 脱困控制器 | EscapeController.swift | 倒车1.5s→转向0.8s→前进2.0s循环，15s超时 | ✅ 完整 |
| 按键注入 | ControlEngine.swift | CGEvent .hidSystemState + .cghidEventTap | ✅ 完整 |

### 1.3 缺失能力

| 缺失项 | 严重程度 | 说明 |
|--------|----------|------|
| **车道线检测** | 🔴 P0 | 弯道完全依赖Yolo撞上去再刹车，无法主动转向 |
| **路径跟踪** | 🔴 P0 | Pure Pursuit / Stanley 未实现（config.py有参数但未接入） |
| **前车跟随** | 🟡 P1 | YOLO能检测前车但无跟车逻辑（distance/speed gap控制） |
| **多传感器融合** | 🟡 P1 | YOLO + 未来车道线 + 网络定位各自为政，无统一决策层 |

---

## 二、BEV车道线检测方案选型

### 2.1 候选方案对比

| 方案 | 类型 | 输入 | 输出 | FPS | CoreML可用 | 推荐度 | 理由 |
|------|------|------|------|-----|-----------|--------|------|
| **ENet-LaneNet** | Segmentation | 288×800图像 | 语义掩码 | 30-50 | ✅ 可导出 | ⭐⭐⭐⭐⭐ | 最轻量(~15MB)，实时，弯道鲁棒，与当前管线兼容 |
| **LaneATT** | Anchor-free检测 | 任意分辨率 | 车道线坐标点序列 | ~30 | ✅ 可导出 | ⭐⭐⭐⭐ | 单次前向无需迭代，多尺度融合，适合弯道 |
| **MonoBEV** | BEV表征学习 | 单目图像 | BEV特征+检测头 | ~15 | ⚠️ 复杂 | ⭐⭐⭐ | 需要深度估计辅助，训练难度大 |
| **BEVFormer** | 多摄BEV | 4+摄像头 | BEV+多任务 | 10-20 | ❌ 太重 | ⭐⭐ | 需要多摄+大量算力，不适合macOS游戏场景 |
| **LaneNet (原版)** | 两阶段分割 | 640×180 | 实例掩码 | 15-30 | ✅ 可导出 | ⭐⭐⭐ | CLASP后处理复杂，速度慢 |
| **PolyLaneNet** | 多项式参数化 | 图像 | 多项式系数 | - | ⚠️ 需适配 | ⭐⭐ | 输出连续曲线，但需要额外拟合后处理 |

### 2.2 推荐方案：ENet-LaneNet

**选择理由**：
1. **体积最小**（~15MB）→ 不影响当前模型包大小预算
2. **速度最快**（30-50 FPS）→ 远低于30Hz红线
3. **CoreML导出成熟** → PyTorch→ONNX→CoreML链路已有验证（项目已有3个CoreML模型）
4. **弯道鲁棒性** → 语义分割天然处理曲线，不依赖多项式拟合
5. **与YOLO管线兼容** → 同样走CaptureEngine的onFrame回调，同样用CVPixelBuffer直通

**不选LaneATT的原因**：虽然也不错，但需要更多调参，且输出是离散点序列需要后处理拟合曲线；ENet直接出连续掩码更方便后续处理。

**不选BEVFormer的原因**：需要多摄像头，单目前视/追尾视角无法发挥BEV优势；算力和内存开销过大。

---

## 三、融合感知方案：是否需要？

### 3.1 结论：**需要，但分阶段**

当前各感知模块是**独立运行、各自输出**，没有融合层：

```
当前架构（松散耦合）：
  CaptureEngine
    ├──→ InferenceEngine (M9) ──→ steer/throttle/brake
    ├──→ YoloEngine ───────────→ detections
    ├──→ SpeedOCRReader ───────→ speedKmh
    └──→ CoordinateCapture ────→ map position

  DegradeStateMachine（只吃模型存活状态+速度+置信度）
    └──→ 决定哪个档位的输出被采用

  RuleController（只吃YOLO detections）
    └──→ 决定障碍物避让

  问题：
  - 车道线检测未来接入后，与YOLO/置信度之间没有协调
  - 状态机不知道"车道线也失效了"→不会提前降级
  - 没有统一的风险评估层
```

### 3.2 融合方案设计（三阶段）

#### 阶段1：最小融合（1周内可完成）

在现有 `DegradeStateMachine` 中增加**车道线健康度**输入：

```swift
// 新增参数
var laneLineHealth: Double = 1.0  // 0=完全失效，1=完美

// update() 新增 laneLineHealth 参数
degradeStm.update(m9Live: m9Live,
                  assistLive: assistLive,
                  health: confidence,
                  laneLineHealth: laneLineHealth,  // ← 新增
                  warmingUp: warmingUp,
                  ...)
```

逻辑：车道线检测失效 → 自动降低降级阈值（从0.65降到0.55），**提前降级**到规则档，而非等到撞上去再反应。

#### 阶段2：决策融合（2-4周）

新增 **PerceptionFusion 模块**，统一输出 `DrivingContext`：

```swift
struct DrivingContext {
    // 来自 E2E
    let e2eSteer: Double
    let e2eConfidence: Double
    
    // 来自 YOLO
    let nearestObstacle: Detection?
    let obstacleUrgency: Double
    
    // 来自 车道线（新增）
    let laneCenterOffset: Double     // 车道中心相对车身偏移 [m]
    let laneCurvature: Double        // 当前道路曲率 [1/m]
    let laneLineConfidence: Double   // 车道线检测置信度
    
    // 来自 速度OCR
    let speedKmh: Double
    let speedValid: Bool
    
    // 融合决策
    let fusedSteer: Double
    let fusedThrottle: Double
    let fusedBrake: Double
    let decisionMode: DriveMode
}
```

融合策略（加权投票）：
- **直道 + 无障碍**：E2E主导（权重0.7）+ 车道线微调（权重0.3）
- **弯道 + 无障碍**：车道线主导（权重0.6）+ E2E辅助（权重0.4）
- **有障碍**：RuleController完全接管（权重1.0）
- **车道线失效**：回退到纯E2E + YOLO规则

#### 阶段3：统一BEV感知（1-3个月）

如果接入ENet-LaneNet效果满意，可以扩展到：
- YOLO检测框 + 车道线mask 统一映射到BEV空间
- 一个轻量BEV fusion网络同时输出：车道线 + 障碍物 + 可行驶区域
- 替代当前分离的 YoloEngine + 未来 LaneDetector

---

## 四、驾驶模式选型：跟随 vs 激进 vs 跟车

### 4.1 三种模式定义

| 模式 | 行为 | 适用场景 | 风险等级 |
|------|------|----------|----------|
| **跟随模式（Follow）** | 保持与前车安全距离，速度≤前车 | 拥挤路况、新手友好 | 🟢 低 |
| **自主模式（Auto）** | 沿车道中心巡航，限速内自由加速 | 空旷道路、展示用 | 🟡 中 |
| **激进模式（Sport）** | 最大加速度+最小转弯半径，逼近车辆极限 | 赛道、竞技 | 🔴 高 |

### 4.2 AuroraDrive 当前行为分析

查看现有代码：
- `RuleController.decide()` 直行时油门固定0.8（`throttle: 0.8`）→ **偏激进**
- M9模型输出 throttle sigmoid ∈ [0,1] → 取决于训练数据
- `EXPERT_PURE_PURSUIT` 配置：lookahead max=25m → 中等激进
- 无前后车距离控制逻辑 → **无法跟随**
- `sportMode` 标志存在但只是强制e2e档，无速度/加速度上限

**结论：当前是"半激进自主模式"**——有自动转向（E2E/YOLO），但无速度管理，遇到障碍才刹车。

### 4.3 推荐方案：**三模式可选 + 默认自主**

```
┌──────────────────────────────────────────────────────┐
│                    驾驶模式选择                        │
├──────────────┬──────────────┬─────────────────────────┤
│   自主模式    │   跟随模式    │      激进模式           │
│   Auto       │   Follow     │       Sport             │
├──────────────┼──────────────┼─────────────────────────┤
│ 沿车道巡航    │ 保持车间距    │ 全油门+全转向           │
│ 限速内自由加速│ 速度≤前车    │ 逼近车辆极限            │
│ 默认模式     │ 拥堵/新手    │ 赛道/展示               │
│              │              │                         │
│ throttle上限 │ 限速前车-3km/h│ throttle上限1.0         │
│ = 1.0       │ = 0.7       │                         │
│ steer =     │ steer =     │ steer = E2E输出          │
│   E2E+车道线 │   E2E+车道线 │   (不截断)               │
│   (正常)     │   (正常)     │                         │
│ 遇障减速    │ 遇障刹车保持  │ 遇障急刹               │
│ 距>20m继续  │ 距<5m停止    │ 距>10m变道超车           │
└──────────────┴──────────────┴─────────────────────────┘
```

### 4.4 跟车逻辑设计（Follow模式）

核心：用YOLO检测前车 + 简单的PID间距控制

```swift
// 新增 FollowController.swift

struct FollowingContext {
    let leadVehicle: Detection?      // 前车检测框
    let distanceM: Double?           // 估计车间距（m）
    let relativeSpeed: Double        // 相对速度（m/s），正=远离
}

class FollowController {
    // 目标间距（米）
    var targetGap: Double = 15.0
    
    // PID参数
    var kp: Double = 0.5     // 间距误差→刹车修正
    var kd: Double = 0.3     // 相对速度→刹车修正
    
    func decide(egoSpeed: Double, context: FollowingContext) -> ControlCommand {
        guard let dist = context.distanceM, dist > 0 else {
            return .init(throttle: 0.8, brake: 0)  // 无前车=自主巡航
        }
        
        // 间距误差（正=太近，负=太远）
        let gapError = dist - targetGap
        
        // 相对速度（前车更快=正，更慢=负）
        let speedDiff = context.relativeSpeed  // m/s
        
        // PID控制：太近→刹车，太远→加速
        let brakeCorrection = kp * max(0, gapError) + kd * max(0, -speedDiff)
        
        // 安全底线：间距<5m直接急刹
        if dist < 5.0 {
            return ControlCommand(steer: 0, throttle: 0, brake: 1.0)
        }
        
        // 正常跟随：限制最高速度为前车速度-3km/h
        let maxThrottle = min(1.0, max(0, 1.0 - brakeCorrection))
        return ControlCommand(steer: 0, throttle: maxThrottle, brake: brakeCorrection)
    }
}
```

**前车距离估计**（单目视觉）：
```
已知车长约4.5m（config.py EGO_VEHICLE.length）
dist ≈ 车长在图像中的像素宽度 × 标定系数
  标定系数需要从实车/实图标定（约50-100像素=m量级）
```

### 4.5 激进模式设计（Sport模式）

在现有 `sportMode` 基础上增强：

```swift
// 在 DegradeStateMachine 中 sportMode 已存在
// 只需增加：速度上限移除 + 转向响应加快

struct SportConfig {
    var maxSpeedKmh: Double = 999    // 无上限
    var steeringSensitivity: Double = 1.5   // 转向放大50%
    var ignoreObstacleThreshold: Double = 0.9  // 只有极高urgency才刹车
}
```

**⚠️ 注意**：激进模式在游戏里可能导致频繁撞墙/超速罚时，建议默认关闭，仅作为调试/展示功能。

---

## 五、完整技术选型汇总表

### 5.1 感知层选型

| 能力 | 当前状态 | 推荐方案 | 模型体积 | 预计接入时间 |
|------|----------|----------|----------|-------------|
| 画面捕获 | ✅ 已有 | 不变 | - | - |
| E2E驾驶 | ✅ M9+assist双模型 | 不变 | ~30MB | - |
| 障碍物检测 | ✅ YOLOv26s | 不变 | ~10MB | - |
| 速度识别 | ✅ PP-OCRv6 微调 int8（主）/ 逐位 CNN（备） | 不变 | ~1.2MB + 2.3MB | - |
| 网络定位 | ✅ libpcap UE5位流 | 不变 | 0 | - |
| **车道线检测** | ❌ 缺失 | **ENet-LaneNet** | ~15MB | 1周 |
| **前车距离估计** | ❌ 缺失 | YOLO+几何估计 | 0 | 2周 |

### 5.2 决策层选型

| 能力 | 当前状态 | 推荐方案 | 预计接入时间 |
|------|----------|----------|-------------|
| 四档降级 | ✅ 完整 | 增加laneLineHealth输入 | 1周 |
| 规则避让 | ✅ 完整 | 不变 | - |
| 脱困策略 | ✅ 完整 | 不变 | - |
| **车道保持** | ❌ 缺失 | ENet-LaneNet + Pure Pursuit | 2周 |
| **跟车控制** | ❌ 缺失 | FollowController (PID间距) | 3周 |
| **三模式切换** | ⚠️ 部分(sportMode) | Auto/Follow/Sport三模式UI | 3周 |
| **感知融合** | ❌ 缺失 | PerceptionFusion (阶段2) | 4周 |

### 5.3 推荐里程碑

```
Week 1:  车道线检测接入
  ├── 导出 ENet-LaneNet 到 CoreML（~15MB）
  ├── 接入 CaptureEngine onFrame 回调
  ├── 输出 laneMask → 提取中心线
  └── 在 DegradeStateMachine 增加 laneLineHealth 输入

Week 2:  Pure Pursuit 路径跟踪
  ├── 基于车道中心线计算 curvature
  ├── lookahead = min(max(8, 0.3×speed), 25)
  ├── curvature → steer 映射
  └── 新增 laneAssist 档位

Week 3:  三驾驶模式
  ├── Auto模式（默认）：E2E+车道线+规则融合
  ├── Follow模式：YOLO前车检测+PID间距控制
  └── Sport模式：sportMode增强（无限速+高转向灵敏度）

Week 4-6: 感知融合 + 打磨
  ├── PerceptionFusion 统一决策层
  ├── 弯道/直道自适应权重
  └── UI三模式切换按钮
```

---

## 六、关键决策记录

| 决策 | 选项A | 选项B | 选择 | 理由 |
|------|-------|-------|------|------|
| 车道线检测模型 | LaneATT | **ENet-LaneNet** | ENet-LaneNet | 体积更小、速度更快、弯道鲁棒 |
| BEV方案 | 多摄BEVFormer | **单目LaneNet** | 单目LaneNet | 单摄像头现实约束，BEVOverhead收益边际递减 |
| 融合深度 | 阶段3统一BEV | **阶段1-2渐进融合** | 渐进融合 | 风险可控，每阶段可独立验证 |
| 默认驾驶模式 | 跟随 | **自主(Auto)** | 自主 | 符合AuroraDrive"自动驾驶展示"定位 |
| 跟车实现 | 深度学习预测 | **PID几何控制** | PID几何 | 简单可靠，无需额外训练数据 |
| 激进模式 | 始终开启 | **用户手动切换** | 手动切换 | 安全考虑，避免意外 |

---

*方案生成时间：2025-09-07 | AI Agent 基于源码分析+网络调研*
