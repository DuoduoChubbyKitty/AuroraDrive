# InferenceEngine 子系统文档

> **文件**: `src/AuroraDrive/InferenceEngine.swift`  
> **版本**: v2.4.1  
> **最后更新**: 2026-08-21

---

## 🙏 致谢

感谢 [MaaNTE](https://github.com/1bananachicken/MaaNTE) 项目团队的全部 24 位贡献者：[1bananachicken](https://github.com/1bananachicken), [EeeMaoY](https://github.com/EeeMaoY), [Watanabehato](https://github.com/Watanabehato), [Hollow-YK](https://github.com/Hollow-YK), [Abino01](https://github.com/Abino01), [T52T52](https://github.com/T52T52), [HBLADEH](https://github.com/HBLADEH), [CCYellowStar2](https://github.com/CCYellowStar2), [potato1778](https://github.com/potato1778), [jwtggg](https://github.com/jwtggg), [overflow65537](https://github.com/overflow65537), [yororoA](https://github.com/yororoA), [drowning-in-codes](https://github.com/drowning-in-codes), [MrGEFORCE](https://github.com/MrGEFORCE), [sdfsfsk](https://github.com/sdfsfsk), [sudoriaa](https://github.com/sudoriaa), [NightDust981989](https://github.com/NightDust981989), [Mickls](https://github.com/Mickls), [MirrorChyanDesu](https://github.com/MirrorChyanDesu), [XUANHLGG](https://github.com/XUANHLGG), [Wattls](https://github.com/Wattls), [hollinlee](https://github.com/hollinlee), [zeejaytan](https://github.com/zeejaytan), [hot-YUser](https://github.com/hot-YUser)。
其中 **1bananachicken**（175 commits）、**EeeMaoY**（89 commits）、**Watanabehato**（43 commits）等核心开发者为《异环》自动化生态奠定了坚实基础。
感谢 [OK-NTE](https://github.com/BnanZ0/ok-nte)、[M9A](https://github.com/MAA1999/M9A) 项目的技术参考与开源共享。
感谢 Apple Silicon 团队提供的 CoreML 优化工具链与 ScreenCaptureKit API。

本项目在 MaaNTE 等同类项目的技术路线上进行了 macOS 原生架构的独立探索，特此致敬。

---

## 1. 职责概述

InferenceEngine 是 AuroraDrive 的**端到端推理引擎**，负责加载和运行 M9 核心模型。它将截屏画面和车辆状态转换为转向、油门、刹车控制量。

**关键设计目标**:
- 异步推理：不阻塞主线程 tick()
- 结果缓存：多帧共用最新推理结果
- 预热机制：减少首次推理延迟

---

## 2. 模型接口

### 2.1 输入规格

```
输入 image:          [1, 3, 180, 320] Float32 CHW 归一化 [0, 1]
输入 vehicle_state:  [1, 6]           Float32
```

**vehicle_state 维度解释**:
| 索引 | 含义 | 范围 | 归一化方式 |
|------|------|------|------------|
| 0 | speed | 0-300 km/h | 原始值 |
| 1 | rpm | 0-8000 | 原始值 |
| 2 | gear | 1-6 (R=0) | 原始值 |
| 3 | speed_norm | 0-1 | speed / 300 |
| 4 | gear_norm | -0.5~0.5 | (gear-1)/5 |
| 5 | reserved | 0 | 固定 0 |

### 2.2 输出规格

```
输出 steer:    [1] tanh   ∈ [-1, 1]   ← 转向：-1 满左，0 直行，1 满右
输出 throttle: [1] sigmoid ∈ [0, 1]  ← 油门：0 无，1 满油门
输出 brake:    [1] sigmoid ∈ [0, 1]  ← 刹车：0 无，1 急刹
```

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable @MainActor
final class InferenceEngine {
    // 模型常量（nonisolated：后台队列可安全访问）
    nonisolated static let inputHeight = 180
    nonisolated static let inputWidth = 320
    private nonisolated static let stateDim = 6
    
    // 状态
    private(set) var isLoaded = false
    private(set) var isInferencing = false
    private(set) var lastResult: InferenceResult?
    private(set) var lastResultTime: Date?
    
    // CoreML 模型实例
    private var model: MLModel?
    private var modelExecutor: MLModelExecutor?
    
    init(modelFileName: String = "m9_mono") {
        loadModel(named: modelFileName)
    }
}
```

### 3.2 模型加载

```swift
private func loadModel(named fileName: String) {
    // 1. 查找模型文件
    guard let modelURL = Bundle.main.url(forResource: fileName,
                                         withExtension: "mlmodelc") ??
                         Bundle.main.url(forResource: fileName,
                                        withExtension: "mlpackage") else {
        errorMessage = "模型文件未找到: \(fileName)"
        return
    }
    
    // 2. 加载模型（耗时操作，在后台队列执行）
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // 使用所有可用硬件
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            
            // 3. 主线程更新状态
            await MainActor.run {
                self?.model = model
                self?.isLoaded = true
                self?.errorMessage = nil
                
                // 4. 预热推理
                self?.warmUp()
            }
        } catch {
            await MainActor.run {
                self?.errorMessage = "模型加载失败: \(error.localizedDescription)"
            }
        }
    }
}
```

### 3.3 预热机制

```swift
/// 加载模型后立即预热 3 帧，减少首次推理延迟
func warmUp() async {
    let dummyImage = createDummyImage()
    let dummyState = constructVehicleState(speed: 0)
    
    for _ in 0..<3 {
        await infer(dummyImage, speed: 0)
    }
    
    print("[Inference] 模型预热完成，\(inferenceCount) 次推理")
}
```

### 3.4 主推理入口

```swift
/// 执行单次推理，结果写入 lastResult
func infer(_ frame: CGImage, speed: Double) async {
    guard isLoaded, !isInferencing else { return }
    
    isInferencing = true
    let startTime = CFAbsoluteTimeGetCurrent()
    
    // 1. 预处理（后台队列）
    let (inputImage, vehicleState) = await Task {
        (preprocessImage(frame), constructVehicleState(speed: speed))
    }.value
    
    // 2. CoreML 推理
    let output = await Task {
        try model?.multilineTask(input: [inputImage, vehicleState])
    }.value
    
    // 3. 解析结果
    let inferenceTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    
    await MainActor.run {
        self.lastResult = InferenceResult(
            steer: output?.steer ?? 0,
            throttle: output?.throttle ?? 0,
            brake: output?.brake ?? 0,
            latencyMs: inferenceTime
        )
        self.lastResultTime = Date()
        self.inferenceCount += 1
        self.isInferencing = false
    }
}
```

---

## 4. 预处理

### 4.1 图像预处理

```swift
/// CGImage → CHW Float32 归一化
func preprocessImage(_ image: CGImage) -> MLMultiArray {
    let width = image.width
    let height = image.height
    
    // 1. 创建空缓冲区
    var pixelData = [Float](repeating: 0, count: 3 * inputHeight * inputWidth)
    
    // 2. 缩放并转换色彩空间
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: &pixelData,
                           width: inputWidth,
                           height: inputHeight,
                           bitsPerComponent: 8,
                           bytesPerRow: inputWidth * 4,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue)
    
    context?.draw(image, in: CGRect(x: 0, y: 0,
                                     width: inputWidth,
                                     height: inputHeight))
    
    // 3. 转换为 CHW 格式（HWC → CHW）
    var chwData = [Float](repeating: 0, count: 3 * inputHeight * inputWidth)
    for h in 0..<inputHeight {
        for w in 0..<inputWidth {
            let idx = h * inputWidth + w
            let cidx = w * inputHeight + h  // CHW 转置
            chwData[cidx] = Float(pixelData[idx * 3]) / 255.0      // R
            chwData[cidx + 1 * inputHeight * inputWidth] =
                Float(pixelData[idx * 3 + 1]) / 255.0              // G
            chwData[cidx + 2 * inputHeight * inputWidth] =
                Float(pixelData[idx * 3 + 2]) / 255.0              // B
        }
    }
    
    // 4. 包装为 MLMultiArray
    return MLMultiArray(chwData, shape: [1, 3, inputHeight, inputWidth]) as! MLMultiArray
}
```

### 4.2 车辆状态构造

```swift
/// 根据当前速度估算完整车辆状态
func constructVehicleState(speed: Double) -> MLMultiArray {
    let rpm = estimateRPM(speed: speed)
    let gear = estimateGear(speed: speed)
    let speedNorm = min(speed / 300.0, 1.0)
    let gearNorm = Double(gear - 1) / 5.0
    
    return MLMultiArray([1, stateDim], dataType: .float32, values: [
        Float(speed),
        Float(rpm),
        Float(gear),
        Float(speedNorm),
        Float(gearNorm),
        0.0  // reserved
    ]) as! MLMultiArray
}

private func estimateRPM(speed: Double) -> Double {
    // 简单线性映射：0 km/h → 800 RPM, 300 km/h → 7000 RPM
    return 800 + (speed / 300.0) * 6200
}

private func estimateGear(speed: Double) -> Int {
    if speed < 10 { return 1 }
    if speed < 40 { return 2 }
    if speed < 80 { return 3 }
    if speed < 140 { return 4 }
    if speed < 220 { return 5 }
    return 6
}
```

---

## 5. 结果解析

```swift
struct InferenceResult: Sendable {
    let steer: Double        // 转向 [-1, 1]
    let throttle: Double     // 油门 [0, 1]
    let brake: Double        // 刹车 [0, 1]
    let latencyMs: Double    // 推理耗时（毫秒）
}

/// 解析 CoreML 输出张量
func parseOutput(_ output: MLSequence) -> InferenceResult {
    let steer = output[0] as? NSArray as? [Float] ?? [0]
    let throttle = output[1] as? NSArray as? [Float] ?? [0]
    let brake = output[2] as? NSArray as? [Float] ?? [0]
    
    return InferenceResult(
        steer: Double(steer.first ?? 0),
        throttle: Double(throttle.first ?? 0),
        brake: Double(brake.first ?? 0),
        latencyMs: 0
    )
}
```

---

## 6. 性能监控

```swift
// 累计推理次数（性能监控）
private(set) var inferenceCount: Int = 0

// 推理耗时追踪
var averageLatency: Double {
    get { stateLock.withLock { _avgLatency } }
}

private func updateLatency(_ ms: Double) {
    stateLock.withLock {
        // EMA 平滑
        _avgLatency = _avgLatency * 0.9 + ms * 0.1
    }
}
```

---

## 7. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `inputHeight` | 180 | 模型输入高度 |
| `inputWidth` | 320 | 模型输入宽度 |
| `stateDim` | 6 | 车辆状态维度 |
| `computeUnits` | `.all` | CoreML 计算单元（CPU/GPU/Neural Engine） |

---

## 8. 常见问题

### Q1: 推理延迟突然升高？

检查项:
1. 设备温度是否过高（触发降频）
2. 是否有其他高负载任务占用 CPU
3. CoreML 是否切换到 GPU（M 系列芯片 Neural Engine 更快）

### Q2: 模型加载失败？

确保 `m9_mono.mlmodelc` 存在于 App Bundle 的 `Contents/Resources/` 目录。  
可通过 Xcode 的 "Copy Bundle Resources" 构建阶段添加。

### Q3: 车速估算不准？

车辆状态中的 speed 来自 OCR 真实读数（`DriveState.effectiveSpeed`），而非模拟值。  
如果 OCR 失效，speed 会回退到 0，导致模型输出偏保守。

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
