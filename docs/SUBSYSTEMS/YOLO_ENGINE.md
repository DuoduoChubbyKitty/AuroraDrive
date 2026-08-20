# YoloEngine 子系统文档

> **文件**: `src/AuroraDrive/YoloEngine.swift`  
> **版本**: v2.4.1  
> **最后更新**: 2026-08-21

## 🙏 致谢

感谢 [MaaNTE](https://github.com/1bananachicken/MaaNTE) 项目团队的全部 24 位贡献者：[1bananachicken](https://github.com/1bananachicken), [EeeMaoY](https://github.com/EeeMaoY), [Watanabehato](https://github.com/Watanabehato), [Hollow-YK](https://github.com/Hollow-YK), [Abino01](https://github.com/Abino01), [T52T52](https://github.com/T52T52), [HBLADEH](https://github.com/HBLADEH), [CCYellowStar2](https://github.com/CCYellowStar2), [potato1778](https://github.com/potato1778), [jwtggg](https://github.com/jwtggg), [overflow65537](https://github.com/overflow65537), [yororoA](https://github.com/yororoA), [drowning-in-codes](https://github.com/drowning-in-codes), [MrGEFORCE](https://github.com/MrGEFORCE), [sdfsfsk](https://github.com/sdfsfsk), [sudoriaa](https://github.com/sudoriaa), [NightDust981989](https://github.com/NightDust981989), [Mickls](https://github.com/Mickls), [MirrorChyanDesu](https://github.com/MirrorChyanDesu), [XUANHLGG](https://github.com/XUANHLGG), [Wattls](https://github.com/Wattls), [hollinlee](https://github.com/hollinlee), [zeejaytan](https://github.com/zeejaytan), [hot-YUser](https://github.com/hot-YUser)。
其中 **1bananachicken**（175 commits）、**EeeMaoY**（89 commits）、**Watanabehato**（43 commits）等核心开发者为《异环》自动化生态奠定了坚实基础。
感谢 [OK-NTE](https://github.com/BnanZ0/ok-nte)、[M9A](https://github.com/MAA1999/M9A) 项目的技术参考与开源共享。
感谢 Apple Silicon 团队提供的 CoreML 优化工具链与 ScreenCaptureKit API。

本项目在 MaaNTE 等同类项目的技术路线上进行了 macOS 原生架构的独立探索，特此致敬。

---

## 1. 职责概述

YoloEngine 是 AuroraDrive 的**目标检测引擎**，使用 YOLOv26s 模型检测前方障碍物。它为 RuleController 提供检测结果，用于避障决策。

**关键设计目标**:
- 双路径推理：直通路径（CVPixelBuffer）和慢路径（NSImage→CGImage）
- 帧间平滑：使用 IoU 匹配跟踪检测框，避免抖动
- 手动锁定：支持用户锁定特定目标持续追踪

---

## 2. 模型规格

### 2.1 输入规格

```
输入 image:  640×640 CVPixelBuffer, colorSpace = RGB
```

**通道序说明**:
- App 喂 32BGRA 格式（iOS 标准）
- CoreML 运行时自动抽取 R/G/B 通道，按 RGB 顺序喂入
- Swift 端无需手动转换通道序

### 2.2 输出规格

```
输出:  [1, maxDet, 6] Float32
每行:  [x1, y1, x2, y2, conf, class_id]
```

**坐标约定**:
- 坐标为像素值，相对 640×640 输入
- 原点在左上角，x 向右，y 向下
- Swift parse() 除以 640 转换为归一化坐标 [0, 1]

### 2.3 NMS-Free 特性

YOLOv26s 是 NMS-free 端到端模型，**去重已在模型内部完成**。  
Swift 端只需：
1. 置信度过滤
2. 按置信度降序
3. 截断到 maxDetections

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable @MainActor
final class YoloEngine {
    // 模型常量
    nonisolated static let inputSize = 640
    
    // 可调参数
    var confidenceThreshold: Double = 0.22
    var iouThreshold: Double = 0.45
    var maxDetections: Int = 20
    var enabled: Bool = true
    
    // 状态
    private(set) var isLoaded = false
    private(set) var isInferencing = false
    private(set) var detections: [Detection] = []
    private(set) var lastLatencyMs: Double = 0
    
    // 直通路径标记
    private(set) var fastPathActive = false
    
    private var model: MLModel?
    private var lockOnTarget: Detection?
}
```

### 3.2 模型加载

```swift
init(modelFileName: String = "game_assist_control") {
    loadModel(named: modelFileName)
}

private func loadModel(named fileName: String) {
    guard let url = Bundle.main.url(forResource: fileName,
                                    withExtension: "mlmodelc") else {
        errorMessage = "YOLO 模型未找到"
        return
    }
    
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: config)
            
            await MainActor.run {
                self?.model = model
                self?.isLoaded = true
                self?.errorMessage = nil
            }
        } catch {
            await MainActor.run {
                self?.errorMessage = "YOLO 模型加载失败: \(error)"
            }
        }
    }
}
```

### 3.3 双路径推理

```swift
/// 慢路径：CGImage → 绘制 → CoreML（兼容旧代码）
func infer(_ frame: CGImage) async {
    guard enabled, isLoaded else { return }
    
    // 1. 创建 640×640 画布
    let cgImage = resizeTo640(frame)
    
    // 2. CoreML 推理
    await runInference(image: cgImage)
}

/// 直通路径：CVPixelBuffer → CoreML（性能更优）
func inferDirect(_ pixelBuffer: CVPixelBuffer) async {
    guard enabled, isLoaded else { return }
    
    // 标记直通路径已激活
    fastPathActive = true
    
    // 直接推送给 CoreML，跳过 NSImage→CGImage 转换
    await runInference(pixelBuffer: pixelBuffer)
}

private func runInference(image: CGImage) async {
    // 1. 预处理（非等比拉伸到 640×640，与训练端一致）
    let input = prepareInput(image)
    
    // 2. 执行推理
    let startTime = CFAbsoluteTimeGetCurrent()
    let output = try? await model?.prediction(from: input)
    let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    
    // 3. 解析结果
    await MainActor.run {
        self.detections = self.parse(output, latency: latency)
        self.lastLatencyMs = latency
    }
}
```

---

## 4. 后处理

### 4.1 解析输出

```swift
/// 解析 CoreML 输出张量
private func parse(_ output: MLSequence?, latency: Double) -> [Detection] {
    guard let output = output else { return [] }
    
    // 输出格式: [1, maxDet, 6]
    // 每行: [x1, y1, x2, y2, conf, class_id]
    
    var results: [Detection] = []
    
    // 遍历所有预测框
    for i in 0..<maxDet {
        let box = output[i] as? NSArray as? [Float] ?? []
        guard box.count >= 6 else { continue }
        
        let conf = box[4]
        guard conf >= confidenceThreshold else { continue }  // 置信度过滤
        
        // 归一化坐标
        let x1 = box[0] / 640.0
        let y1 = box[1] / 640.0
        let x2 = box[2] / 640.0
        let y2 = box[3] / 640.0
        
        // 计算中心点
        let x = (x1 + x2) / 2
        let y = (y1 + y2) / 2
        let width = x2 - x1
        let height = y2 - y1
        
        // 类别映射
        let label = mapClassID(Int(box[5]))
        
        results.append(Detection(x: x, y: y, width: width, height: height,
                                 label: label, confidence: conf,
                                 rawName: className(Int(box[5]))))
    }
    
    // 按置信度降序
    results.sort { $0.confidence > $1.confidence }
    
    // 截断到 maxDetections
    return Array(results.prefix(maxDetections))
}
```

### 4.2 类别映射

```swift
/// COCO-80 类名 → 游戏相关标签
enum DetectionLabel: String {
    case car        // 车辆
    case pedestrian // 行人
    case sign       // 交通牌
    case obstacle   // 通用障碍
}

private func mapClassID(_ id: Int) -> DetectionLabel {
    switch id {
    case 2: return .car        // CAR
    case 0, 1, 3, 4, 5, 6, 7: return .pedestrian  // PERSON, BUS, TRAIN, etc.
    case 61, 62, 63, 67: return .sign  // TRAFFIC LIGHT, STOP SIGN, etc.
    default: return .obstacle
    }
}

private func className(_ id: Int) -> String {
    // 返回原始 COCO 类名，用于 UI 显示
    let names = ["PERSON", "BICYCLE", "CAR", "MOTORCYCLE", "AIRPLANE",
                 "BUS", "TRAIN", "TRUCK", " ..."]  // 完整 COCO-80 列表
    return id < names.count ? names[id] : "OBJ"
}
```

---

## 5. 帧间平滑

### 5.1 IoU 匹配

```swift
/// 使用 IoU 匹配将当前帧检测框与上一帧关联
private func smoothDetections(_ newDetections: [Detection],
                               lastDetections: [Detection]) -> [Detection] {
    var matched = Set<Int>()
    var smoothed: [Detection] = []
    
    // 遍历当前帧检测框
    for (i, detection) in newDetections.enumerated() {
        var bestMatch: (index: Int, iou: Double)?
        
        // 寻找最佳匹配（上一帧中 IoU 最高的）
        for (j, last) in lastDetections.enumerated() where !matched.contains(j) {
            let iou = calculateIoU(detection, other: last)
            if let best = bestMatch, iou < best.iou { continue }
            bestMatch = (j, iou)
        }
        
        // IoU 超过阈值则视为同一目标
        if let (j, iou) = bestMatch, iou > iouThreshold {
            matched.insert(j)
            smoothed.append(detection)  // 保持当前帧检测结果
        } else {
            smoothed.append(detection)  // 新增检测
        }
    }
    
    return smoothed
}

private func calculateIoU(_ a: Detection, other b: Detection) -> Double {
    let x1 = max(a.x - a.width/2, b.x - b.width/2)
    let y1 = max(a.y - a.height/2, b.y - b.height/2)
    let x2 = min(a.x + a.width/2, b.x + b.width/2)
    let y2 = min(a.y + a.height/2, b.y + b.height/2)
    
    let intersection = max(0, x2 - x1) * max(0, y2 - y1)
    let areaA = a.width * a.height
    let areaB = b.width * b.height
    
    return intersection / (areaA + areaB - intersection)
}
```

### 5.2 手动锁定追踪

```swift
/// 锁定某个检测框，持续追踪
func lockOn(_ detection: Detection) {
    lockOnTarget = detection
}

/// 解除所有锁定
func unlockAll() {
    lockOnTarget = nil
}

/// 锁定追踪逻辑
private func trackLocked(_ detections: [Detection]) -> [Detection] {
    guard let target = lockOnTarget else { return detections }
    
    // 在当前帧中寻找与锁定目标最接近的框
    let closest = detections.min { d1, d2 in
        distance(d1, to: target) < distance(d2, to: target)
    }
    
    return closest.map { [$0] } ?? []
}

private func distance(_ a: Detection, to b: Detection) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx*dx + dy*dy)
}
```

---

## 6. 自检命令

```bash
# YOLO 自检（打印检测结果后退出）
./AuroraDriveUI --yolo-selftest screenshot.png

# 输出示例:
# [YoloSelfTest] 检测到 5 个障碍物:
#   [CAR] conf=0.85 at (0.45, 0.60)
#   [PERSON] conf=0.72 at (0.62, 0.55)
#   ...
# [YoloSelfTest] 推理耗时: 35.2ms
```

---

## 7. 配置参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `inputSize` | 640 | — | 模型输入正方形边长 |
| `confidenceThreshold` | 0.22 | [0.1, 0.5] | 置信度过滤阈值 |
| `iouThreshold` | 0.45 | [0.3, 0.7] | 帧间匹配 IoU 阈值 |
| `maxDetections` | 20 | [5, 50] | 单帧最大保留框数 |
| `enabled` | true | — | 引擎开关 |

---

## 8. 性能分析

### 8.1 直通路径 vs 慢路径

```
直通路径 (CVPixelBuffer):
  耗时: ~35ms (M2 Pro)
  优势: 跳过 NSImage→CGImage 转换，减少内存分配

慢路径 (NSImage→CGImage):
  耗时: ~45ms (M2 Pro)
  劣势: 额外的颜色空间转换和内存拷贝
```

**切换逻辑**:
```swift
// CaptureEngine.onYoloFrame 激活后，tick() 自动切换到直通路径
if fastPathActive {
    yoloEngine.inferDirect(captureEngine.nativeFrame)
} else {
    yoloEngine.infer(captureEngine.currentCGImage)
}
```

### 8.2 瓶颈定位

```bash
# 基准测试（对比两种路径）
./AuroraDriveUI --yolo-bench screenshot.png

# 输出示例:
# [Benchmark] 直通路径: 33.5ms
# [Benchmark] 慢路径:   46.2ms
# [Benchmark] 加速比: 1.38x
```

---

## 9. 常见问题

### Q1: 检测框抖动严重？

调高 IoU 阈值：
```swift
yoloEngine.iouThreshold = 0.6  // 默认 0.45
```

### Q2: 小目标检测不到？

降低置信度阈值（会增加误检）：
```swift
yoloEngine.confidenceThreshold = 0.15  // 默认 0.22
```

### Q3: 检测框不跟随目标？

检查 `fastPathActive` 是否已激活。如果 CaptureEngine 未推送 onYoloFrame，会走慢路径。

---

## 导航链接

| 方向 | 链接 | 说明 |
|------|------|------|
| ⬆️ 回到上级 | [DEVELOPER.md](../DEVELOPER.md) | 二级开发者文档（引擎总览） |
| ⬆️ 回到首页 | [README.md](../../README.md) | 一级项目简介 |
| 🔙 返回列表 | [SUBSYSTEMS/](./) | 所有子系统文档 |

---

## 开源声明与致谢

**GNU GPL v3.0**  
Copyright © 2026 DuoduoChubbyKitty

依赖组件:
- Apple ScreenCaptureKit (macOS 12.3+)
- CoreML / MetalPerformanceShaders
- Vision (模板匹配)
- CoreGraphics (CGEvent 注入)

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
