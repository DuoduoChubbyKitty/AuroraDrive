# SpeedOCRReader 子系统文档

> **文件**: `src/AuroraDrive/SpeedOCRReader.swift`  
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

SpeedOCRReader 是 AuroraDrive 的**车速识别引擎**，通过固定槽位模板匹配从游戏 HUD 读取车速。它是系统感知层的关键组成部分，为 M9 模型和降级状态机提供真实车速信号。

**为什么不用通用 OCR？**
- 游戏 HUD 使用空心数字（左右竖 + 上下弧 + 中间空洞）
- 通用 Vision OCR 误识别率高，实测 "000" 读成 "NTO0U"
- 模板匹配对空心字天然友好，精度高、速度快

---

## 2. 算法原理

### 2.1 固定槽位设计

```
速度表布局（归一化坐标）:
┌─────────────────────────────────────┐
│                                     │
│                                     │
│                                     │
│           [0][0][0] km/h           │  ← 三个数字槽
│           ↑   ↑   ↑                │
│         槽1  槽2  槽3              │
│         百位 十位 个位              │
└─────────────────────────────────────┘

默认 ROI: CGRect(x: 0.50, y: 0.76, width: 0.32, height: 0.18)
         覆盖右下角 "N 000 km/h" 区域
```

### 2.2 三槽坐标

```swift
// 三个数字槽的归一化中心 X 坐标（与 tools/build_speed_glyphs.py 同源）
static var slotCentersNorm: [Double] = [0.42, 0.50, 0.58]

// 单槽宽度（归一化）
static var slotWidthNorm: Double = 0.04

// 槽高上下界（归一化）
static var slotYMinNorm: Double = 0.82
static var slotYMaxNorm: Double = 0.94
```

### 2.3 整体匹配策略

**为什么是 0-300 三位数整体匹配？**
- 游戏速度表始终显示三位数，前导补 0（0 → "000", 90 → "090"）
- 0-300 共 301 个速度值，每个 = 百/十/个位的固定组合
- 把「三槽残差和最小」作为判据，数学上等价于预拼 301 个 75×45 整体模板

**优势**:
- 避免逐槽匹配的组合爆炸（10×10×10 = 1000 种组合）
- 只需 30 个单数字模板（0-9），查表组合即可

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable @MainActor
final class SpeedOCRReader {
    // 状态
    private(set) var speedKmh: Double = -1  // -1 表示未识别
    private(set) var confidence: Double = 0.0
    private(set) var isLoaded: Bool = false
    
    // 字模库
    private var glyphTemplates: [Int: CGImage]?  // 0-9 的数字模板
    
    // 线程安全
    private var generation = 0
    private let ocrQueue = DispatchQueue(label: "com.auroradrive.ocr")
    
    init() {
        loadGlyphs()
    }
}
```

### 3.2 字模加载

```swift
/// 从 models/speed_glyphs.json 加载字模库
private func loadGlyphs() {
    guard let url = Bundle.main.url(forResource: "speed_glyphs",
                                    withExtension: "json") else {
        print("[OCR] 字模库未找到，将使用默认模板")
        createDefaultGlyphs()
        return
    }
    
    do {
        let data = try Data(contentsOf: url)
        let glyphs = try JSONDecoder().decode([Int: CGImage].self, from: data)
        
        DispatchQueue.global().async { [weak self] in
            self?.glyphTemplates = glyphs
            Task { @MainActor in
                self?.isLoaded = true
            }
        }
    } catch {
        print("[OCR] 字模加载失败: \(error)")
        createDefaultGlyphs()
    }
}

/// 创建默认字模（当 JSON 缺失时）
private func createDefaultGlyphs() {
    // 使用简单的笔画模板（实际项目中应预先生成）
    glyphTemplates = [
        0: createDigitImage(digit: 0),
        1: createDigitImage(digit: 1),
        // ... 2-9
    ]
    isLoaded = true
}
```

### 3.3 主推理入口

```swift
/// 执行 OCR，结果写入 speedKmh + confidence
func infer(_ pixelBuffer: CVPixelBuffer, roi: CGRect?) async {
    // 生成新的 generation，防止过期结果覆盖
    let currentGen = incrementGeneration()
    
    ocrQueue.async { [weak self] in
        guard let self = self else { return }
        
        // 1. ROI 裁切
        let roiRect = roi ?? CaptureEngine.speedROINorm
        guard let roiBuffer = self.cropROI(pixelBuffer, roi: roiRect) else {
            return
        }
        
        // 2. 无效帧检测（前置过滤）
        guard self.isValidFrame(roiBuffer) else {
            Task { @MainActor in
                if self.generation == currentGen {
                    self.speedKmh = -1
                    self.confidence = 0.0
                }
            }
            return
        }
        
        // 3. 三槽裁切
        let slots = (0..<3).map { i in
            self.extractSlot(roiBuffer, slotIndex: i, roi: roiRect)
        }
        
        // 4. 模板匹配
        let (speed, conf) = self.matchTemplates(slots: slots)
        
        // 5. 写结果（仅在 generation 未变时）
        Task { @MainActor in
            if self.generation == currentGen {
                self.speedKmh = speed
                self.confidence = conf
            }
        }
    }
}
```

---

## 4. 模板匹配

### 4.1 单槽匹配

```swift
/// 匹配单个数字槽
private func matchSlot(_ slot: CVPixelBuffer) -> (digit: Int, cost: CGFloat) {
    guard let templates = glyphTemplates else {
        return (0, .greatestFiniteMagnitude)
    }
    
    var bestDigit = 0
    var bestCost: CGFloat = .greatestFiniteMagnitude
    
    // 1. 二值化（Otsu 阈值）
    let binary = binarize(slot)
    
    // 2. 缩放到统一尺寸 (25×45)
    let resized = resize(binary, to: CGSize(width: 25, height: 45))
    
    // 3. 遍历所有模板，计算残差成本
    for (digit, template) in templates {
        // 残差 = 按位不同像素数（对空心字天然友好）
        let cost = calculateResidual(resized, template: template)
        
        if cost < bestCost {
            bestCost = cost
            bestDigit = digit
        }
    }
    
    // 4. 抖动鲁棒性：在 9 个偏移位置取最小
    let robustCost = minCostWithJitter(resized, templates: templates)
    
    return (bestDigit, robustCost)
}

/// 带抖动的匹配（±1 像素偏移）
private func minCostWithJitter(_ image: CGImage,
                                templates: [Int: CGImage]) -> CGFloat {
    var minCost: CGFloat = .greatestFiniteMagnitude
    
    // 9 个偏移位置
    for dy in [-1, 0, 1] {
        for dx in [-1, 0, 1] {
            let shifted = shift(image, dx: dx, dy: dy)
            for (_, template) in templates {
                let cost = calculateResidual(shifted, template: template)
                minCost = min(minCost, cost)
            }
        }
    }
    
    return minCost
}
```

### 4.2 三位数组合

```swift
/// 组合三个槽位，计算最低残差速度
private func matchTemplates(slots: [CVPixelBuffer]) -> (speed: Double, confidence: Double) {
    // 1. 匹配每个槽位
    let digitResults = slots.map { matchSlot($0) }
    
    // 2. 生成 0-300 的所有可能组合
    var bestSpeed = 0.0
    var bestTotalCost: CGFloat = .greatestFiniteMagnitude
    
    for speed in 0...300 {
        let hundreds = speed / 100
        let tens = (speed % 100) / 10
        let ones = speed % 10
        
        let digits = [hundreds, tens, ones]
        var totalCost: CGFloat = 0
        
        for (i, digit) in digits.enumerated() {
            // 查找该数字的模板成本
            if let (_, cost) = digitResults[i],
               let template = glyphTemplates?[digit] {
                // 计算该槽位使用 digit 模板的成本
                let slotCost = calculateResidual(digitResults[i].slot, template: template)
                totalCost += slotCost
            } else {
                totalCost = .greatestFiniteMagnitude
                break
            }
        }
        
        if totalCost < bestTotalCost {
            bestTotalCost = totalCost
            bestSpeed = Double(speed)
        }
    }
    
    // 3. 计算置信度（基于最佳成本和次优成本的差距）
    let confidence = computeConfidence(bestCost: bestTotalCost, allCosts: /* ... */)
    
    return (bestSpeed, confidence)
}
```

---

## 5. 预处理

### 5.1 ROI 裁切

```swift
/// 从原生帧中裁切 ROI 区域
private func cropROI(_ pixelBuffer: CVPixelBuffer, roi: CGRect) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    
    let x = Int(roi.minX * CGFloat(width))
    let y = Int(roi.minY * CGFloat(height))
    let w = Int(roi.width * CGFloat(width))
    let h = Int(roi.height * CGFloat(height))
    
    // 使用 vImage 高效裁切（只拷贝 ROI 区域，约 100KB，替代整帧 22MB）
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, /* pool */, &buffer)
    
    if let dest = buffer {
        vImageBuffer_InitCVPixelBufferWithBytes(
            pixelBuffer, dest,
            srcX: UInt32(x), srcY: UInt32(y),
            width: UInt32(w), height: UInt32(h)
        )
    }
    
    return buffer
}
```

### 5.2 无效帧检测

```swift
/// 前置检测：判断画面是否包含速度表
private func isValidFrame(_ roi: CVPixelBuffer) -> Bool {
    // 1. 二值化
    let binary = binarize(roi)
    
    // 2. 统计前景像素比例
    let foregroundPixels = countForegroundPixels(binary)
    let totalPixels = CVPixelBufferGetWidth(binary) * CVPixelBufferGetHeight(binary)
    let ratio = CGFloat(foregroundPixels) / CGFloat(totalPixels)
    
    // 3. 阈值判断（速度表区域应有足够多的数字笔画）
    return ratio > 0.05  // 至少 5% 的前景像素
}
```

### 5.3 二值化（Otsu 阈值）

```swift
/// Otsu 自动阈值二值化
private func binarize(_ image: CVPixelBuffer) -> CVPixelBuffer {
    // 1. 转换为灰度
    let gray = convertToGray(image)
    
    // 2. 计算直方图
    let histogram = computeHistogram(gray)
    
    // 3. Otsu 算法求最佳阈值
    let threshold = otsuThreshold(histogram)
    
    // 4. 应用阈值
    return applyThreshold(gray, threshold: threshold)
}

private func otsuThreshold(_ histogram: [Int]) -> UInt8 {
    let total = histogram.reduce(0, +)
    var sum = 0
    var maxBetweenVar = 0.0
    var threshold: UInt8 = 0
    
    for t in 0..<256 {
        let wa = histogram[0...t].reduce(0,+)
        let wb = histogram[t+1...255].reduce(0,+)
        guard wa > 0, wb > 0 else { continue }
        
        const a = CGFloat(wa) / CGFloat(total)
        const b = CGFloat(wb) / CGFloat(total)
        
        const ma = histogram[0...t].enumerated().map { i, count in
            CGFloat(i) * CGFloat(count)
        }.reduce(0, +) / CGFloat(wa)
        
        const mb = histogram[t+1...255].enumerated().map { i, count in
            CGFloat(i + t + 1) * CGFloat(count)
        }.reduce(0, +) / CGFloat(wb)
        
        let betweenVar = a * b * (ma - mb) * (ma - mb)
        if betweenVar > maxBetweenVar {
            maxBetweenVar = betweenVar
            threshold = UInt8(t)
        }
    }
    
    return threshold
}
```

---

## 6. 抖动抑制

### 6.1 多帧确认

```swift
/// 多帧确认防止跳变
private var speedHistory: [Double] = []
private let historySize = 5

private func confirmSpeed(_ newSpeed: Double) -> Double {
    speedHistory.append(newSpeed)
    if speedHistory.count > historySize {
        speedHistory.removeFirst()
    }
    
    // 取中位数
    let sorted = speedHistory.sorted()
    return sorted[sorted.count / 2]
}
```

### 6.2 范围检查

```swift
/// 检查速度是否在合理范围内
private func isValidSpeed(_ speed: Double) -> Bool {
    return speed >= 0 && speed <= 400  // 游戏速度上限 300，留余量到 400
}

/// 跳变检测：单次变化不超过 60 km/h
private func isSpeedJump(_ old: Double, _ new: Double) -> Bool {
    return abs(new - old) <= 60.0
}
```

---

## 7. 自检命令

```bash
# 速度 OCR 自检（传入录制的帧目录）
./AuroraDriveUI --speed-selftest /path/to/frames/

# 输出示例:
# [SpeedOCR SelfTest] Processing 50 frames...
# Frame 001: speed=008 km/h, conf=0.92
# Frame 002: speed=012 km/h, conf=0.95
# ...
# [SpeedOCR SelfTest] Summary:
#   Total: 50 frames
#   Success: 47 (94%)
#   Failed: 3 (6%)
#   Avg confidence: 0.89
```

---

## 8. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `slotCentersNorm` | [0.42, 0.50, 0.58] | 三槽中心 X 坐标 |
| `slotWidthNorm` | 0.04 | 单槽宽度 |
| `slotYMinNorm` | 0.82 | 槽上边界 |
| `slotYMaxNorm` | 0.94 | 槽下边界 |
| `templateSize` | (25, 45) | 单数字模板尺寸 |
| `historySize` | 5 | 多帧确认窗口大小 |
| `maxSpeedJump` | 60.0 | 单次最大速度跳变 (km/h) |

---

## 9. 性能分析

| 操作 | 耗时 | 说明 |
|------|------|------|
| ROI 裁切 | ~1ms | vImage 高效拷贝 |
| 二值化 | ~2ms | Otsu 阈值计算 |
| 单槽匹配 | ~3ms | 10 个模板 × 残差计算 |
| 三位组合 | ~5ms | 301 个速度值遍历 |
| **总计** | **~11ms** | 远低于 30Hz 周期（33ms） |

---

## 10. 常见问题

### Q1: 速度显示为 0 或乱跳？

1. 检查 ROI 坐标是否正确（打开 HUD 标注模式手动框选）
2. 确认字模库 `models/speed_glyphs.json` 存在
3. 检查画面中是否有速度表（有些场景可能没有）

### Q2: 识别速度慢？

OCR 在后台队列执行，不应阻塞主线程。如果仍然慢：
- 检查是否开启了调试日志（大量 IO 会拖慢）
- 确认设备性能（老款 Mac 可能吃力）

### Q3: 前导零不显示（如 008 显示为 8）？

这是显示问题，不影响实际车速值。如需修复，检查 UI 格式化代码。

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
