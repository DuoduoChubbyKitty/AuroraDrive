# AuroraDrive 开发者文档

> **版本**: v2.4.1  
> **最后更新**: 2026-08-21  
> **适用对象**: 希望二次开发、接入新模型或扩展功能的开发者

---

## 🙏 致谢

感谢 [MaaNTE](https://github.com/1bananachicken/MaaNTE) 项目团队的全部 24 位贡献者：[1bananachicken](https://github.com/1bananachicken), [EeeMaoY](https://github.com/EeeMaoY), [Watanabehato](https://github.com/Watanabehato), [Hollow-YK](https://github.com/Hollow-YK), [Abino01](https://github.com/Abino01), [T52T52](https://github.com/T52T52), [HBLADEH](https://github.com/HBLADEH), [CCYellowStar2](https://github.com/CCYellowStar2), [potato1778](https://github.com/potato1778), [jwtggg](https://github.com/jwtggg), [overflow65537](https://github.com/overflow65537), [yororoA](https://github.com/yororoA), [drowning-in-codes](https://github.com/drowning-in-codes), [MrGEFORCE](https://github.com/MrGEFORCE), [sdfsfsk](https://github.com/sdfsfsk), [sudoriaa](https://github.com/sudoriaa), [NightDust981989](https://github.com/NightDust981989), [Mickls](https://github.com/Mickls), [MirrorChyanDesu](https://github.com/MirrorChyanDesu), [XUANHLGG](https://github.com/XUANHLGG), [Wattls](https://github.com/Wattls), [hollinlee](https://github.com/hollinlee), [zeejaytan](https://github.com/zeejaytan), [hot-YUser](https://github.com/hot-YUser)。
其中 **1bananachicken**（175 commits）、**EeeMaoY**（89 commits）、**Watanabehato**（43 commits）等核心开发者为《异环》自动化生态奠定了坚实基础。
感谢 [OK-NTE](https://github.com/BnanZ0/ok-nte)、[M9A](https://github.com/MAA1999/M9A) 项目的技术参考与开源共享。
感谢 Apple Silicon 团队提供的 CoreML 优化工具链与 ScreenCaptureKit API。

本项目在 MaaNTE 等同类项目的技术路线上进行了 macOS 原生架构的独立探索，特此致敬。

---

## 目录

1. [系统架构详解](#1-系统架构详解)
2. [核心数据流](#2-核心数据流)
3. [类图与接口](#3-类图与接口)
4. [时序图](#4-时序图)
5. [引擎接口文档](#5-引擎接口文档)
6. [配置参数详解](#6-配置参数详解)
7. [扩展开发指南](#7-扩展开发指南)
8. [调试与诊断](#8-调试与诊断)
9. [开源声明与致谢](#9-开源声明与致谢)

---

## 1. 系统架构详解

### 1.1 分层架构

AuroraDrive 采用典型的**感知-决策-控制**三层架构：

```
┌─────────────────────────────────────────────────────┐
│                    UI 层 (SwiftUI)                  │
│  ContentView → DrivePanel → ModeBadge → KeyboardBar │
└─────────────────────────────────────────────────────┘
                          ▲
                          │ DriveState (Observable)
┌─────────────────────────────────────────────────────┐
│                 决策层 (Decision)                    │
│  DegradeStateMachine + ConfidenceEstimator          │
│  RuleController + EscapeController                  │
└─────────────────────────────────────────────────────┘
                          ▲
                          │ InferenceResult / Detection
┌─────────────────────────────────────────────────────┐
│                 感知层 (Perception)                  │
│  InferenceEngine (M9) + YoloEngine + SpeedOCR       │
│  + VisualLocator (NCC 小地图)                       │
└─────────────────────────────────────────────────────┘
                          ▲
                          │ CVPixelBuffer / NSImage
┌─────────────────────────────────────────────────────┐
│                 捕获层 (Capture)                     │
│  CaptureEngine (ScreenCaptureKit, 30fps)            │
└─────────────────────────────────────────────────────┘
                          ▲
                          │ CGEvent
┌─────────────────────────────────────────────────────┐
│                 执行层 (Control)                     │
│  ControlEngine (CGEvent 键盘注入)                    │
└─────────────────────────────────────────────────────┘
```

### 1.2 线程模型

| 线程 | 职责 | 关键类 |
|------|------|--------|
| 主线程 (@MainActor) | UI 渲染、状态管理、tick() 驱动 | DriveState, ControlEngine |
| 后台推理队列 | CoreML 推理、图像预处理 | InferenceEngine, YoloEngine |
| 捕获队列 | ScreenCaptureKit 帧回调处理 | CaptureEngine |
| OCR 队列 | 模板匹配计算（耗时较长） | SpeedOCRReader |

> **原则**: 所有对外可见的状态（`@Observable`）必须通过 `@MainActor` 暴露，内部计算可在后台队列并行执行。

### 1.3 核心常量

```swift
// 频率约束
let TICK_HZ = 30           // 主决策循环 30 Hz
let CAPTURE_HZ = 30        // 画面捕获 30 Hz

// 模型输入尺寸
let M9_INPUT_H = 180       // 端到端模型高度
let M9_INPUT_W = 320       // 端到端模型宽度
let YOLO_INPUT_SIZE = 640  // YOLO 正方形输入边长
let OCR_SLOT_H = 25        // OCR 单数字高度
let OCR_SLOT_W = 45        // OCR 单数字宽度

// 车辆状态维度
let VEHICLE_STATE_DIM = 6  // [speed, rpm, gear, speed_norm, gear_norm, reserved]

// 关键 ROI 归一化坐标（默认值）
let SPEED_ROMARGIN_LEFT  = 0.50  // 速度表 ROI 左边界
let SPEED_ROMARGIN_TOP   = 0.76  // 速度表 ROI 上边界
let SPEED_ROMARGIN_WIDTH = 0.32  // 速度表 ROI 宽度
let SPEED_ROMARGIN_HEIGHT = 0.18 // 速度表 ROI 高度
```

---

## 2. 核心数据流

### 2.1 主循环 tick()

```swift
// AuroraDriveApp.swift:DriveState.tick()
func tick() {
    // 1. 获取最新帧
    guard let frame = captureEngine.latestFrame else { return }
    
    // 2. 三路并行推理
    Task { await inferenceEngine.infer(frame) }   // M9 端到端
    Task { await yoloEngine.infer(frame) }        // YOLO 检测
    Task { await speedOCR.infer(frame) }          // 速度 OCR
    
    // 3. 置信度融合
    let health = confidenceEstimator.estimate(
        m9: inferenceEngine.lastResult,
        yolo: yoloEngine.detections,
        speed: speedOCR.speedKmh
    )
    
    // 4. 状态机决策
    degradeStm.update(
        m9Live: inferenceEngine.isLoaded && inferenceEngine.lastResult != nil,
        assistLive: yoloEngine.isLoaded,
        health: health,
        speedKmh: speedOCR.speedKmh,
        speedValid: speedOCR.confidence > 0.3
    )
    
    // 5. 执行控制
    let command = controlEngine.generateCommand(
        mode: degradeStm.mode,
        e2eResult: inferenceEngine.lastResult,
        detections: yoloEngine.detections,
        speed: speedOCR.speedKmh
    )
    controlEngine.apply(command)
}
```

### 2.2 帧数据处理流程

```
SCStream 回调 (captureQueue)
    │
    ├─→ onFrame(NSImage, CGImage)       // UI 显示路径
    │       └─→ FrameHost ( SwiftUI Image )
    │
    ├─→ onYoloFrame(CVPixelBuffer)      // YOLO 直通路径
    │       └─→ YoloEngine (CVPixelBuffer 直推)
    │
    ├─→ onNativeFrame(CVPixelBuffer)    // OCR 原生路径
    │       └─→ SpeedOCRReader (ROI 裁切)
    │
    └─→ onUpscaleFrame(CVPixelBuffer)   // MetalGoose 显示路径
            └─→ UpscaleFrameHost (MetalFX 超分)
```

---

## 3. 类图与接口

### 3.1 核心类关系

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          DriveState (@Observable @MainActor)             │
│  - captureEngine: CaptureEngine                                          │
│  - inferenceEngine: InferenceEngine                                      │
│  - yoloEngine: YoloEngine                                                │
│  - controlEngine: ControlEngine                                          │
│  - degradeStm: DegradeStateMachine                                       │
│  - speedOCR: SpeedOCRReader                                              │
│  - confidenceEstimator: ConfidenceEstimator                              │
│  + tick(): Void                                                          │
└────┬────────────────────────────────────────────────────────────────────┘
     │ 依赖
     ├────────────────────────────────────────────────────────────────────┐
     ▼                                                                    ▼
┌─────────────────┐                                              ┌─────────────────┐
│  CaptureEngine  │                                              │ControlEngine   │
│  - onFrame      │                                              │  - keyMap       │
│  - onYoloFrame  │                                              │  - heldKeys     │
│  - onNativeFrame│                                              │  - press()      │
│  - onUpscaleFrame│                                             │  - hold()       │
│  + start()      │                                              │  - release()    │
│  + stop()       │                                              └─────────────────┘
└─────────────────┘
     │                ┌─────────────────┐
     ├───────────────►│ InferenceEngine │
     │                │  - lastResult   │
     │                │  - infer(frame) │
     │                └─────────────────┘
     │                ┌─────────────────┐
     ├───────────────►│   YoloEngine    │
     │                │  - detections   │
     │                │  - infer(frame) │
     │                └─────────────────┘
     │                ┌─────────────────┐
     ├───────────────►│  SpeedOCRReader │
     │                │  - speedKmh     │
     │                │  - infer(frame) │
     │                └─────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       DegradeStateMachine                                │
│  + update(m9Live, assistLive, health, speedKmh, speedValid): DriveMode  │
│  - mode: DriveMode                                                      │
│  - lastTransitionReason: String                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 关键数据结构

#### Detection（检测结果）

```swift
struct Detection: Sendable {
    enum Label: String {
        case car        // 车辆
        case pedestrian // 行人
        case sign       // 交通牌
        case obstacle   // 通用障碍
    }
    
    let x: Double       // 中心 x [0,1]
    let y: Double       // 中心 y [0,1]
    let width: Double   // 宽 [0,1]
    let height: Double  // 高 [0,1]
    let label: Label
    let confidence: Double
    var rawName: String = "OBJ"
    
    /// 判断是否在危险区
    func isInDangerZone(dangerHalfWidth: Double = 0.18,
                        dangerYMin: Double = 0.45) -> Bool
}
```

#### InferenceResult（推理结果）

```swift
struct InferenceResult: Sendable {
    let steer: Double        // 转向 [-1, 1]
    let throttle: Double     // 油门 [0, 1]
    let brake: Double        // 刹车 [0, 1]
    let latencyMs: Double    // 推理耗时
}
```

#### DriveMode（驾驶模式）

```swift
enum DriveMode: String, CaseIterable {
    case e2e     // 端到端主驾（M9 模型）
    case yolo    // YOLO 接管（规则控制器）
    case recover // 脱困中（Escape 策略）
    case rule    // 纯规则兜底
}
```

---

## 4. 时序图

### 4.1 正常驾驶流程

```
┌─────────┐     ┌────────────┐     ┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│Capture  │     │Inference   │     │YoloEngine   │     │StateMa-      │     │Control    │
│Engine   │     │Engine      │     │             │     │chine         │     │Engine      │
└────┬────┘     └─────┬──────┘     └──────┬──────┘     └──────┬───────┘     └──────┬──────┘
     │               │                    │                    │                   │
     │ SCStream 帧   │                    │                    │                   │
     ├──────────────►│                    │                    │                   │
     │               │ infer(frame)       │                    │                   │
     │               ├───────────────────►│                    │                   │
     │               │                    │                    │                   │
     │ onFrame       │                    │                    │                   │
     │ onYoloFrame   │                    │                    │                   │
     │ onNativeFrame │                    │                    │                   │
     │               │                    │                    │                   │
     │               │ lastResult ✓       │                    │                   │
     │               │                    │ detections ✓       │                   │
     │               │                    │                    │                   │
     │               │                    │                    │ update(inputs)    │
     │               │                    │                    ├──────────────────►│
     │               │                    │                    │                   │
     │               │                    │                    │ mode = .e2e       │
     │               │                    │                    │                   │
     │               │                    │                    │ generateCommand() │
     │               │                    │                    ├──────────────────►│
     │               │                    │                    │                   │
     │               │                    │                    │ apply(steer,thr,  │
     │               │                    │                    │  brake)           │
     │               │                    │                    │                   │
     │               │                    │                    │                   │ CGEvent 注入
     │               │                    │                    │                  ─┤
     │               │                    │                    │                  ►游戏
```

### 4.2 降级流程

```
┌─────────┐     ┌────────────┐     ┌─────────────┐
│Capture  │     │Confidence  │     │StateMa-     │
│Engine   │     │Estimator   │     │chine         │
└────┬────┘     └─────┬──────┘     └──────┬───────┘
     │               │                    │
     │ 帧            │                    │
     ├──────────────►│                    │
     │               │ estimate()         │
     │               ├───────────────────►│
     │               │                    │
     │               │ health = 0.58      │
     │               │ (< 0.65 阈值)      │
     │               │                    │
     │               │                    │ transition → .yolo
     │               │                    ├──────────────────►
     │               │                    │ mode = .yolo
     │               │                    │ reason = "M9 健康度不足"
```

---

## 5. 引擎接口文档

### 5.1 CaptureEngine

**文件**: `src/AuroraDrive/CaptureEngine.swift`

**职责**: 基于 ScreenCaptureKit 的 30fps 画面捕获引擎。

**初始化**:
```swift
let captureEngine = CaptureEngine()
```

**核心属性**:
| 属性 | 类型 | 说明 |
|------|------|------|
| `isCapturing` | `Bool` | 是否正在捕获 |
| `captureFPS` | `Double` | 当前实际帧率 |
| `currentFrame` | `NSImage?` | 最新 UI 显示帧 |
| `speedROINorm` | `CGRect` (static) | 速度表 ROI 归一化坐标 |

**回调闭包**:
```swift
// UI 显示路径 (480px 缩放)
captureEngine.onFrame = { nsImage, cgImage in
    // 刷新 UI 预览
}

// YOLO 直通路径 (640×640 CVPixelBuffer)
captureEngine.onYoloFrame = { pixelBuffer in
    // 直接推送给 YoloEngine，跳过 NSImage 转换
}

// OCR 原生路径 (原始分辨率 CVPixelBuffer)
captureEngine.onNativeFrame = { pixelBuffer in
    // 推送给 SpeedOCRReader
}

// MetalGoose 超分路径 (仅显示用)
captureEngine.onUpscaleFrame = { pixelBuffer in
    // 推送给 UpscaleFrameHost
}
```

**生命周期**:
```swift
// 启动捕获（需要屏幕录制权限）
try await captureEngine.start(sessionDescription: .init())

// 停止捕获
captureEngine.stop()
```

**关键实现细节**:
- 使用 `CVPixelBufferPool` 避免高频分配
- 三路回调在 `captureQueue` 串行处理，互不阻塞
- `speedROINorm` 为 `nonisolated(unsafe)` static 变量，允许后台线程安全读取

---

### 5.2 InferenceEngine

**文件**: `src/AuroraDrive/InferenceEngine.swift`

**职责**: CoreML M9 端到端模型推理引擎。

**初始化**:
```swift
let inferenceEngine = InferenceEngine(modelFileName: "m9_mono")
```

**核心属性**:
| 属性 | 类型 | 说明 |
|------|------|------|
| `isLoaded` | `Bool` | 模型是否已加载 |
| `isInferencing` | `Bool` | 是否正在推理中 |
| `lastResult` | `InferenceResult?` | 最新推理结果 |
| `lastResultTime` | `Date?` | 最近一次推理时间戳 |
| `inferenceCount` | `Int` | 累计推理次数 |
| `errorMessage` | `String?` | 加载/推理错误信息 |

**常量**:
```swift
// nonisolated static，后台队列可安全访问
InferenceEngine.inputHeight  // 180
InferenceEngine.inputWidth   // 320
InferenceEngine.stateDim     // 6
```

**主入口**:
```swift
/// 执行单次推理，结果写入 lastResult
func infer(_ frame: CGImage, speed: Double) async
```

**内部流程**:
```
1. 检查 isLoaded + 非 isInferencing（防重叠）
2. 预处理: CGImage → CHW Float32 归一化
3. 构造 vehicle_state: [speed, rpm, gear, speed_norm, gear_norm, 0]
4. CoreML multitaskRun(inputs)
5. 解析输出: tanh → steer, sigmoid → throttle/brake
6. 写入 lastResult + lastResultTime
```

**预热机制**:
```swift
// 加载模型后立即预热 3 帧，减少首次推理延迟
func warmUp() async
```

---

### 5.3 YoloEngine

**文件**: `src/AuroraDrive/YoloEngine.swift`

**职责**: CoreML YOLOv26s 目标检测引擎。

**初始化**:
```swift
let yoloEngine = YoloEngine(modelFileName: "game_assist_control")
```

**可调参数**:
```swift
yoloEngine.confidenceThreshold = 0.22  // 默认，可放宽到 0.15
yoloEngine.iouThreshold = 0.45
yoloEngine.maxDetections = 20
yoloEngine.enabled = true
```

**核心属性**:
| 属性 | 类型 | 说明 |
|------|------|------|
| `isLoaded` | `Bool` | 模型是否已加载 |
| `detections` | `[Detection]` | 最新检测结果列表 |
| `lastLatencyMs` | `Double` | 最近一次推理耗时 |
| `fastPathActive` | `Bool` | 直通路径是否已激活 |

**常量**:
```swift
YoloEngine.inputSize  // 640
```

**主入口**:
```swift
/// 执行检测，结果写入 detections
func infer(_ frame: CGImage) async
func inferDirect(_ pixelBuffer: CVPixelBuffer) async
```

**帧间平滑**:
```swift
// 使用 IoU 匹配跟踪上一帧的检测框，避免抖动
private func smoothDetections(_ newDetections: [Detection],
                               lastDetections: [Detection]) -> [Detection]
```

**锁定追踪**:
```swift
/// 手动锁定某个检测框，持续追踪
func lockOn(_ detection: Detection)
func unlockAll()
```

---

### 5.4 SpeedOCRReader

**文件**: `src/AuroraDrive/SpeedOCRReader.swift`

**职责**: 基于固定槽位模板匹配的车速识别引擎。

**初始化**:
```swift
let speedOCR = SpeedOCRReader()
```

**核心属性**:
| 属性 | 类型 | 说明 |
|------|------|------|
| `speedKmh` | `Double` | 当前识别车速 (0-400) |
| `confidence` | `Double` | 识别置信度 (0-1) |
| `isLoaded` | `Bool` | 字模库是否已加载 |

**槽位配置**:
```swift
// 三个数字槽的归一化中心 X 坐标（与 tools/build_speed_glyphs.py 同源）
SpeedOCRReader.slotCentersNorm = [0.42, 0.50, 0.58]

// 槽宽归一化
SpeedOCRReader.slotWidthNorm = 0.04

// 槽高上下界归一化
SpeedOCRReader.slotYMinNorm = 0.82
SpeedOCRReader.slotYMaxNorm = 0.94
```

**主入口**:
```swift
/// 执行 OCR，结果写入 speedKmh + confidence
func infer(_ pixelBuffer: CVPixelBuffer, roi: CGRect?) async
```

**自检命令**:
```bash
# 传入帧目录路径（PNG/JPG 格式）
./AuroraDriveUI --speed-selftest /path/to/frames/
```

---

### 5.5 ControlEngine

**文件**: `src/AuroraDrive/ControlEngine.swift`

**职责**: 基于 CGEvent 的键盘事件注入引擎。

**初始化**:
```swift
let controlEngine = ControlEngine()
```

**核心属性**:
| 属性 | 类型 | 说明 |
|------|------|------|
| `hasAccessibilityPermission` | `Bool` | 是否拥有辅助功能权限 |
| `heldKeys` | `Set<CGKeyCode>` | 当前按住的键集合 |
| `keyMap` | `KeyMap` | 按键映射配置 |

**按键映射**（默认 WASTD + 空格 + Shift）:
```swift
controlEngine.keyMap.throttle    = 13  // W
controlEngine.keyMap.brake       = 1   // S
controlEngine.keyMap.steerLeft   = 0   // A
controlEngine.keyMap.steerRight  = 2   // D
controlEngine.keyMap.handbrake   = 49  // 空格
controlEngine.keyMap.boost       = 56  // Left Shift
```

**控制接口**:
```swift
// 按下并立即释放（单次按键）
func press(_ action: ControlEngine.Action)

// 持续按住（需配合 release 使用）
func hold(_ action: ControlEngine.Action)

// 释放指定键
func release(_ action: ControlEngine.Action)

// 释放所有键
func releaseAll()

// 根据控制量生成按键组合
func apply(_ steer: Double, _ throttle: Double, _ brake: Double)
```

**权限检查**:
```swift
// 启动时自动检查，无权限则引导用户到系统设置
func checkPermissions() -> Bool
```

---

### 5.6 DegradeStateMachine

**文件**: `src/AuroraDrive/DegradeStateMachine.swift`

**职责**: 四级降级状态机，保障系统在各种异常情况下的安全降级。

**可调阈值**:
```swift
degradeStm.degradeHealth = 0.65     // 触发降级健康度下限
degradeStm.recoverHysteresis = 0.15 // 恢复迟滞量
degradeStm.stuckSpeedThreshold = 3.0 // km/h，低于此值视为卡住
degradeStm.stuckTimeThreshold = 3.0  // 秒，持续卡住时长
degradeStm.recoverTimeout = 30.0     // 脱困档最大时长
```

**主入口**:
```swift
/// 根据输入更新状态，返回新模式
func update(m9Live: Bool,
            assistLive: Bool,
            health: Double,
            warmingUp: Bool,
            speedKmh: Double,
            speedValid: Bool,
            sportOverride: Bool) -> DriveMode
```

**状态转移规则**:
```
.e2e ──(health < 0.65)──► .yolo
.yolo ──(assist 失效)────► .rule
.e2e/.yolo ──(stuck 3s)──► .recover
.recover ──(speed > 3 && 30s timeout)──► 原模式
.rule ──(health > 0.65)──► .e2e/.yolo
```

**Sport 模式覆盖**:
```swift
// 极速模式下强制使用 E2E，关闭避障
degradeStm.sportOverride = true
```

---

## 6. 配置参数详解

### 6.1 引擎参数总览

| 参数 | 所属类 | 默认值 | 范围 | 说明 |
|------|--------|--------|------|------|
| `inputHeight` | InferenceEngine | 180 | — | M9 模型输入高度 |
| `inputWidth` | InferenceEngine | 320 | — | M9 模型输入宽度 |
| `stateDim` | InferenceEngine | 6 | — | 车辆状态维度 |
| `inputSize` | YoloEngine | 640 | — | YOLO 输入边长 |
| `confidenceThreshold` | YoloEngine | 0.22 | [0.1, 0.5] | 检测置信度阈值 |
| `iouThreshold` | YoloEngine | 0.45 | [0.3, 0.7] | NMS IoU 阈值 |
| `maxDetections` | YoloEngine | 20 | [5, 50] | 单帧最大检测框数 |
| `slotCentersNorm` | SpeedOCRReader | [0.42, 0.50, 0.58] | — | 三槽中心 X 坐标 |
| `slotWidthNorm` | SpeedOCRReader | 0.04 | — | 单槽宽度 |
| `slotYMinNorm` | SpeedOCRReader | 0.82 | — | 槽上边界 |
| `slotYMaxNorm` | SpeedOCRReader | 0.94 | — | 槽下边界 |
| `speedROINorm` | CaptureEngine | CGRect(0.50, 0.76, 0.32, 0.18) | — | 速度表 ROI |
| `degradeHealth` | DegradeStateMachine | 0.65 | [0.5, 0.8] | 降级阈值 |
| `recoverHysteresis` | DegradeStateMachine | 0.15 | [0.1, 0.3] | 恢复迟滞量 |
| `stuckSpeedThreshold` | DegradeStateMachine | 3.0 | [1.0, 5.0] | 卡住速度阈值 |
| `stuckTimeThreshold` | DegradeStateMachine | 3.0 | [1.0, 10.0] | 卡住时间阈值 |
| `recoverTimeout` | DegradeStateMachine | 30.0 | [15.0, 60.0] | 脱困超时 |
| `dangerHalfWidth` | RuleController | 0.18 | [0.1, 0.3] | 危险区半宽 |
| `dangerYMin` | RuleController | 0.45 | [0.3, 0.6] | 危险区上界 |
| `emergencyBrakeThreshold` | RuleController | 0.8 | [0.5, 1.0] | 紧急刹车阈值 |
| `reverseDuration` | EscapeController | 1.5 | [0.5, 3.0] | 倒车时长 |
| `turnDuration` | EscapeController | 0.8 | [0.5, 2.0] | 转向时长 |
| `forwardDuration` | EscapeController | 2.0 | [1.0, 4.0] | 前进时长 |
| `maxDuration` | EscapeController | 15.0 | [10.0, 30.0] | 最大脱困时长 |

### 6.2 车辆状态构造

```swift
// InferenceEngine.constructVehicleState()
func constructVehicleState(speed: Double) -> MLMultiArray {
    let rpm = estimateRPM(speed: speed)           // 启发式估算
    let gear = estimateGear(speed: speed)         // 速度分档
    let speedNorm = min(speed / 300.0, 1.0)       // 归一化
    let gearNorm = Double(gear - 1) / 5.0         // P/R/D 归一化
    
    return MLMultiArray([1, 6], dataType: .float32, values: [
        Float(speed),
        Float(rpm),
        Float(gear),
        Float(speedNorm),
        Float(gearNorm),
        0.0  // reserved
    ])
}
```

---

## 7. 扩展开发指南

### 7.1 添加新的感知引擎

**步骤 1**: 创建新引擎类（继承 Observable）

```swift
@Observable
final class LaneDetector: NSObject {
    var isEnabled = false
    var lastLanePosition: Double?
    
    func infer(_ frame: CGImage) async -> [LaneLine]? {
        // 实现 Lane Detection 逻辑
    }
}
```

**步骤 2**: 在 DriveState 中集成

```swift
// AuroraDriveApp.swift
let laneDetector = LaneDetector()

// 在 tick() 中添加
if laneDetector.isEnabled {
    Task {
        let lanes = await laneDetector.infer(frame)
        // 融合到决策逻辑
    }
}
```

**步骤 3**: 更新置信度估计器

```swift
// ConfidenceEstimator.swift
func estimate(m9: InferenceResult?, yolo: [Detection],
              speed: Double, lanes: [LaneLine]?) -> Double {
    let m9Score = m9.flatMap { confidenceFromResult($0) } ?? 0.0
    let laneScore = lanes.map { confidenceFromLanes($0) } ?? 0.0
    
    // 新增 Lane 信号权重
    return m9Score * 0.5 + yoloScore * 0.3 + laneScore * 0.2
}
```

### 7.2 修改降级策略

**步骤 1**: 调整阈值

```swift
// 在 UI 设置面板中
degradeStm.degradeHealth = 0.70  // 提高降级敏感度
degradeStm.stuckTimeThreshold = 2.0  // 缩短卡住检测时间
```

**步骤 2**: 添加新的状态转移

```swift
// DegradeStateMachine.swift
private func shouldTransitionToRule(m9Live: Bool, assistLive: Bool) -> Bool {
    // 新增条件：连续 N 次推理失败
    return !m9Live && !assistLive && consecutiveFailures > 5
}
```

### 7.3 添加新的控制动作

**步骤 1**: 扩展 Action 枚举

```swift
// ControlEngine.swift
enum Action {
    case throttle
    case brake
    case steerLeft
    case steerRight
    case handbrake
    case boost
    case horn   // 新增：鸣笛
}
```

**步骤 2**: 映射键码

```swift
struct KeyMap {
    var horn: CGKeyCode = 0x00  // 根据实际键码填充
}
```

**步骤 3**: 在 RuleController 中使用

```swift
// 检测到前方行人时鸣笛
if detection.label == .pedestrian && detection.confidence > 0.8 {
    controlEngine.press(.horn)
}
```

---

## 8. 调试与诊断

### 8.1 自检命令

```bash
# YOLO 引擎自检（打印检测结果后退出）
./AuroraDriveUI --yolo-selftest screenshot.png

# YOLO 性能基准（对比直通 vs 慢路径耗时）
./AuroraDriveUI --yolo-bench screenshot.png

# 速度 OCR 自检（打印每张图的识别结果）
./AuroraDriveUI --speed-selftest ./frames/ --roi 0.50,0.76,0.32,0.18

# 内存诊断（验证积压是否导致内存增长）
./AuroraDriveUI --memory-diag
```

### 8.2 实时日志

```bash
# 查看调试日志（10MB 轮转）
tail -f /tmp/aurora_debug.log

# 搜索错误
grep -i "error\|fail\|exception" /tmp/aurora_debug.log

# 监控推理耗时
grep "inference" /tmp/aurora_debug.log | awk '{print $1, $NF}'
```

### 8.3 性能分析

```bash
# 使用 instruments 采样
instruments -t "Allocations" -p $(pgrep AuroraDrive)

# 或使用 xcodebuild 内置 profiler
xcodebuild build -scheme AuroraDrive -configuration Debug
```

### 8.4 常见问题排查

| 现象 | 可能原因 | 排查步骤 |
|------|----------|----------|
| 画面黑屏 | 权限未授权 | 检查系统设置 → 屏幕录制 |
| 按键无响应 | 辅助功能权限缺失 | 检查系统设置 → 辅助功能 |
| 速度为 0 | OCR 未标定或字模库缺失 | 检查 `models/speed_glyphs.json` |
| YOLO 不检测 | 模型未加载或阈值过高 | 运行 `--yolo-selftest` |
| 频繁降级 | 健康度阈值过低 | 提高 `degradeHealth` 到 0.75 |
| 内存持续增长 | 帧缓冲泄漏 | 检查 `CVPixelBufferPool` 释放 |

---

## 9. 开源声明与致谢

### 开源许可证
本项目采用 **GNU GPL v3.0** 开源协议。  
Copyright © 2026 DuoduoChubbyKitty

### 第三方组件
| 组件 | 许可证 | 用途 |
|------|--------|------|
| MetalGoose | GPL v3.0 | MetalFX 超分/插帧引擎 |
| Ultralytics YOLOv26s | AGPL v3.0 | 目标检测模型 |
| Apple CoreML | — | 端侧推理框架 |
| ScreenCaptureKit | — | macOS 官方截屏 API |
| CGEvent (CoreGraphics) | — | 键盘事件注入 |

### 致谢
- 感谢 [MaaNTE](https://github.com/1bananachicken/MaaNTE) 项目全部 24 位贡献者：[1bananachicken](https://github.com/1bananachicken), [EeeMaoY](https://github.com/EeeMaoY), [Watanabehato](https://github.com/Watanabehato), [Hollow-YK](https://github.com/Hollow-YK), [Abino01](https://github.com/Abino01), [T52T52](https://github.com/T52T52), [HBLADEH](https://github.com/HBLADEH), [CCYellowStar2](https://github.com/CCYellowStar2), [potato1778](https://github.com/potato1778), [jwtggg](https://github.com/jwtggg), [overflow65537](https://github.com/overflow65537), [yororoA](https://github.com/yororoA), [drowning-in-codes](https://github.com/drowning-in-codes), [MrGEFORCE](https://github.com/MrGEFORCE), [sdfsfsk](https://github.com/sdfsfsk), [sudoriaa](https://github.com/sudoriaa), [NightDust981989](https://github.com/NightDust981989), [Mickls](https://github.com/Mickls), [MirrorChyanDesu](https://github.com/MirrorChyanDesu), [XUANHLGG](https://github.com/XUANHLGG), [Wattls](https://github.com/Wattls), [hollinlee](https://github.com/hollinlee), [zeejaytan](https://github.com/zeejaytan), [hot-YUser](https://github.com/hot-YUser)
- 感谢 [OK-NTE](https://github.com/BnanZ0/ok-nte)、[M9A](https://github.com/MAA1999/M9A) 项目的技术参考
- 感谢 Apple Silicon 团队提供的 CoreML 优化工具链与 ScreenCaptureKit API

---

## 导航链接

| 文档级别 | 文件名 | 内容说明 |
|----------|--------|----------|
| 🔼 返回一级 | [README.md](../README.md) | 项目简介与快速开始 |
| 🔽 进入三级 | [SUBSYSTEMS/](./SUBSYSTEMS/) | 各子系统技术文档 |
| 📐 架构文档 | [ARCHITECTURE.md](./ARCHITECTURE.md) | 系统架构与设计决策 |
| ⚡ 快速上手 | [QUICKSTART.md](./QUICKSTART.md) | 快速启动指南 |
| 📜 许可证 | [LICENSE](./LICENSE) | GPL v3.0 全文 |
| 📝 声明 | [NOTICE](./NOTICE) | 第三方组件声明 |

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
