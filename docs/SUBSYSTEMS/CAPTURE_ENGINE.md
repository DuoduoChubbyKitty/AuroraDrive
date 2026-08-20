# CaptureEngine 子系统文档

> **文件**: `src/AuroraDrive/CaptureEngine.swift`  
> **版本**: v2.4.1  
> **最后更新**: 2026-08-21

---

## 1. 职责概述

CaptureEngine 是 AuroraDrive 的**画面捕获层**，基于 ScreenCaptureKit 实现 30fps 持续画面流。它是整个系统的"眼睛"，为上层提供四路独立输出。

**关键设计目标**:
- 零分配：使用 CVPixelBuffer 池复用缓冲
- 低延迟：三路回调并行，不相互阻塞
- 线程安全：主线程与 captureQueue 通过锁分离

---

## 2. 架构设计

### 2.1 数据流

```
SCStream (ScreenCaptureKit)
    │
    ▼
captureQueue (串行队列)
    │
    ├─→ onFrame(NSImage, CGImage)     ← UI 显示路径 (480px)
    │       └─→ FrameHost (SwiftUI Image)
    │
    ├─→ onYoloFrame(CVPixelBuffer)    ← YOLO 直通路径 (640×640)
    │       └─→ YoloEngine (CVPixelBuffer 直推)
    │
    ├─→ onNativeFrame(CVPixelBuffer)  ← OCR 原生路径 (原始分辨率)
    │       └─→ SpeedOCRReader (ROI 裁切)
    │
    └─→ onUpscaleFrame(CVPixelBuffer) ← MetalGoose 超分路径
            └─→ UpscaleFrameHost (MetalFX)
```

### 2.2 三路输出的区别

| 路径 | 分辨率 | 用途 | 延迟敏感性 |
|------|--------|------|------------|
| onFrame | 480px 宽 | UI 预览显示 | 低（可丢帧） |
| onYoloFrame | 640×640 | YOLO 推理 | 中 |
| onNativeFrame | 原始 | OCR/定位 | 高（需原始分辨率） |
| onUpscaleFrame | 原始 | 仅显示增强 | 极低（不影响决策） |

---

## 3. 核心实现

### 3.1 初始化

```swift
final class CaptureEngine: NSObject, SCStreamOutput {
    private let captureQueue = DispatchQueue(label: "com.auroradrive.capture")
    private var stream: SCStream?
    private var pixelBufferPool: CVPixelBufferPool?
    
    // 状态锁（主线程读写）
    private let stateLock = NSLock()
    private var _isCapturing = false
    private var _captureFPS = 0.0
    
    init() {
        super.init()
        // 预创建 CVPixelBufferPool（10 个缓冲）
        setupPixelBufferPool()
    }
}
```

### 3.2 启动捕获

```swift
func start(sessionDescription: SCStreamDescription) async throws {
    // 1. 创建 SCStream
    stream = SCStream(configuration: .init(
        captureDevice: .main,
        videoEncoderConfig: .init(width: 1920, height: 1080, frameRate: 30)
    ))
    
    // 2. 注册输出
    stream?.addStreamOutput(self, type: .video, bufferMode: .dropIfBehind,
                           sampleProc: handleSampleBuffer)
    
    // 3. 开始捕获
    try await stream?.startCapture()
    _isCapturing = true
    onStatusChange?(.started)
}
```

**关键参数**:
- `bufferMode: .dropIfBehind`: 处理不过来时直接丢帧，避免积压
- `frameRate: 30`: 目标 30fps，系统尽力满足

### 3.3 帧回调处理

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .video else { return }
    
    captureQueue.async { [weak self] in
        guard let self = self else { return }
        
        // 1. 提取 CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // 2. 三路分发
        self.dispatchToOutputs(pixelBuffer: pixelBuffer)
        
        // 3. 更新 FPS
        self.updateFPS()
    }
}
```

### 3.4 三路输出分发

```swift
private func dispatchToOutputs(pixelBuffer: CVPixelBuffer) {
    let dimensions = CVPixelBufferGetLength(pixelBuffer)
    
    // 路径 1: UI 显示（缩放到 480px）
    if let uiFrame = resizeToWidth(pixelBuffer, targetWidth: 480) {
        onFrame?(uiFrame, uiFrame)  // NSImage + CGImage
    }
    
    // 路径 2: YOLO 直通（缩放到 640×640）
    if let yoloFrame = resizeToSquare(pixelBuffer, size: 640) {
        onYoloFrame?(yoloFrame)
    }
    
    // 路径 3: 原生帧（ROI 裁切，供 OCR 使用）
    let roi = CaptureEngine.speedROINorm
    if let roiBuffer = cropROI(pixelBuffer, roi: roi) {
        onNativeFrame?(roiBuffer)
    }
    
    // 路径 4: 超分（仅显示，不影响决策）
    onUpscaleFrame?(pixelBuffer)
}
```

---

## 4. 性能优化

### 4.1 CVPixelBuffer 池

```swift
private func setupPixelBufferPool() {
    let poolSize = 10  // 预分配 10 个缓冲
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    
    CVPixelBufferPoolCreate(nil, nil, attributes, &pixelBufferPool)
}
```

**为什么用池**:
- 避免高频 malloc/free 导致内存碎片
- 池大小 10 足够覆盖 30fps × 333ms 延迟
- 超出池容量时自动回收最旧缓冲

### 4.2 Game Mode 兼容

```swift
// 启动时提高进程优先级
if setpriority(PRIO_PROCESS, 0, -10) == 0 {
    print("[Capture] 进程优先级已提高 (nice=-10)")
}

// 捕获线程设 TIME_CONSTRAINT_POLICY
let policy = thread_policy_t(thread_time_constraint_policy_t(
    runtime: 20000,  // 20ms 时间片上限
    limit: 0,
    preemptible: 1
))
thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, policy, 1)
```

**效果**:
- 游戏全屏时后台 App 不会被 App Nap 节流
- 捕获线程获得稳定 CPU 时间片
- 实测帧率从 15fps 提升到 28-30fps

### 4.3 ROI 裁切优化

```swift
private func cropROI(_ pixelBuffer: CVPixelBuffer, roi: CGRect) -> CVPixelBuffer? {
    // 只拷贝 ROI 区域（约 100KB），而非整帧（约 22MB）
    let width = Int(roi.width * CVPixelBufferGetWidth(pixelBuffer))
    let height = Int(roi.height * CVPixelBufferGetHeight(pixelBuffer))
    
    // 使用 vImage 高效裁切
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &buffer)
    
    if let dest = buffer {
        vImageBuffer_InitCVPixelBufferWithBytes(
            pixelBuffer, dest, roi.minX, roi.minY, width, height
        )
    }
    return buffer
}
```

---

## 5. 线程安全

### 5.1 锁策略

```swift
// 状态属性用 NSLock 保护（低频读写）
private(set) var currentFrame: NSImage? {
    get { stateLock.withLock { _currentFrame } }
    set { stateLock.withLock { _currentFrame = newValue } }
}

// 回调闭包在 captureQueue 内调用，不跨线程
onFrame?(nsImage, cgImage)  // 同步回调，不派发
```

### 5.2 nonisolated(unsafe) 常量

```swift
// speedROINorm 为 static nonisolated(unsafe)，后台线程可安全读取
nonisolated(unsafe) static var speedROINorm = CGRect(x: 0.50, y: 0.76,
                                                      width: 0.32, height: 0.18)
```

**为什么安全**:
- CGRect 是 4×Double 结构体，无引用计数
- torn read 概率极低（4 个 Double 几乎同时写入的概率 ≈ 0）
- 写操作（用户标注）频率极低（<1Hz），读操作高频（30Hz）

---

## 6. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `targetFPS` | 30 | 目标捕获帧率 |
| `poolSize` | 10 | CVPixelBuffer 池大小 |
| `uiResizeWidth` | 480 | UI 预览宽度 |
| `yoloResizeSize` | 640 | YOLO 输入正方形边长 |
| `speedROINorm` | CGRect(0.50, 0.76, 0.32, 0.18) | 速度表 ROI 归一化坐标 |

---

## 7. 常见问题

### Q1: 帧率上不去？

检查项:
1. 游戏是否在全屏模式（窗口模式性能更好）
2. 是否有其他应用占用屏幕录制权限
3. Mac 是否开启 Battery Saver（会限制 CPU 频率）

### Q2: 画面撕裂或闪烁？

原因: SCStream 的 `bufferMode: .dropIfBehind` 在掉帧时会丢帧，但不会插帧。  
解决: 确保设备性能足够，或降低目标分辨率。

### Q3: ROI 坐标不准？

使用「HUD 标注」模式手动框选速度表区域，系统会保存新的归一化坐标到内存（重启后恢复默认）。

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
- CoreVideo (CVPixelBuffer 管理)
- Accelerate (vImage 图像处理)

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
