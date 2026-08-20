# ConfidenceEstimator 子系统文档

> **文件**: `src/AuroraDrive/ConfidenceEstimator.swift`  
> **版本**: v2.4.1  
> **最后更新**: 2026-08-21

---

## 🙏 致谢

感谢 [MaaNTE](https://github.com/1bananachicken/MaaNTE) 项目团队（**1bananachicken、EeeMao** 等开发者）为《异环》生态提供的自动化工具与技术启发。
感谢 [OK-NTE](https://github.com/BnanZ0/ok-nte)、[M9A](https://github.com/MAA1999/M9A) 以及所有异环玩家社区成员的技术交流与贡献。
感谢 Apple Silicon 团队提供的 CoreML 优化工具链与 ScreenCaptureKit API。

本项目在 MaaNTE 等同类项目的技术路线上进行了 macOS 原生架构的独立探索，特此致敬。

---

## 1. 职责概述

ConfidenceEstimator 是 AuroraDrive 的**健康度评估器**，融合多路感知信号评估当前驾驶模式的可靠性。输出 0-1 的健康度分数，供 DegradeStateMachine 决定是否降级。

**核心思路**: 不依赖单一信号，而是综合三个维度的证据：
1. **一致性**: 多个信号是否相互印证
2. **极端性**: 控制量是否处于安全边界内
3. **图像质量**: 输入画面是否清晰可用

---

## 2. 三信号融合

### 2.1 信号来源

```
┌─────────────────────────────────────────────────────────┐
│                   三信号输入                            │
├─────────────────┬─────────────────┬─────────────────────┤
│   M9 推理结果   │   YOLO 检测结果 │    车速 OCR         │
│  (steer/thr/br) │  ([Detection])  │   (speedKmh)        │
├─────────────────┼─────────────────┼─────────────────────┤
│   权重: 0.5     │   权重: 0.3     │    权重: 0.2        │
└─────────────────┴─────────────────┴─────────────────────┘
                         │
                         ▼
                ┌────────────────┐
                │  加权平均得分   │
                │   health ∈ [0,1] │
                └────────────────┘
                         │
                         ▼
                DegradeStateMachine
                (决定是否需要降级)
```

### 2.2 权重配置

```swift
private let weights = SignalWeights(
    consistency: 0.5,   // M9 推理一致性
    extremity: 0.3,     // 控制量极端性
    imageQuality: 0.2   // 图像质量
)
```

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable @MainActor
final class ConfidenceEstimator {
    // 历史窗口（滑动平均）
    private var history: [Double] = []
    private let windowSize = 10
    
    // 滑动窗口最小值（检测瞬态故障）
    private var windowMin: Double = 1.0
    
    /// 融合三信号，输出健康度 [0, 1]
    func estimate(m9: InferenceResult?,
                  yolo: [Detection],
                  speed: Double) -> Double {
        
        // 1. 计算各信号分量
        let consistencyScore = estimateConsistency(m9: m9)
        let extremityScore = estimateExtremity(m9: m9, yolo: yolo)
        let imageScore = estimateImageQuality(speed: speed)
        
        // 2. 加权融合
        let rawScore = weights.consistency * consistencyScore
                     + weights.extremity * extremityScore
                     + weights.imageQuality * imageScore
        
        // 3. 滑动窗口平滑
        let smoothed = applySmoothing(rawScore)
        
        // 4. 更新历史记录
        updateHistory(smoothed)
        
        return smoothed
    }
}
```

### 3.2 一致性估计

```swift
/// 基于 M9 推理结果的一致性评估
///
/// 思路：转向/油门/刹车的幅度不应同时极端（应为协调的动作）
private func estimateConsistency(m9: InferenceResult?) -> Double {
    guard let result = m9 else { return 0.0 }
    
    // 1. 检查推理是否新鲜（< 1 秒）
    let freshness = isFresh(result.latencyMs) ? 1.0 : 0.3
    
    // 2. 检查控制量协调性
    // 不应同时满转向 + 满油门 + 满刹车
    let sumAbs = abs(result.steer) + result.throttle + result.brake
    let coordination = sumAbs <= 1.5 ? 1.0 : (3.0 - sumAbs) / 1.5
    
    // 3. 综合得分
    return freshness * coordination
}

private func isFresh(_ latencyMs: Double) -> Bool {
    return latencyMs < 100.0  // 延迟超过 100ms 视为不新鲜
}
```

### 3.3 极端性估计

```swift
/// 基于控制量和检测结果的极端性评估
///
/// 思路：极端控制量（满转向/满刹车）且无对应障碍物 → 可疑
private func estimateExtremity(m9: InferenceResult?,
                                yolo: [Detection]) -> Double {
    guard let result = m9 else { return 0.5 }
    
    var score = 1.0
    
    // 1. 检查满转向
    if abs(result.steer) > 0.9 {
        // 满转向时应有对应障碍物
        let hasObstacle = yolo.contains { $0.isInDangerZone() }
        if !hasObstacle {
            score *= 0.5  // 无依据的满转向 → 降分
        }
    }
    
    // 2. 检查满刹车
    if result.brake > 0.9 {
        let hasObstacle = yolo.contains { $0.label == .car || $0.label == .pedestrian }
        if !hasObstacle {
            score *= 0.6  // 无依据的急刹 → 降分
        }
    }
    
    // 3. 检查油门过度
    if result.throttle > 0.9 && result.steer.abs > 0.5 {
        // 满油门 + 大转向 = 危险操作
        score *= 0.7
    }
    
    return score
}
```

### 3.4 图像质量估计

```swift
/// 基于车速稳定性的图像质量代理评估
///
/// 思路：车速平稳变化通常意味着画面稳定（无剧烈抖动/模糊）
private func estimateImageQuality(speed: Double) -> Double {
    // 使用车速导数作为画面稳定性的代理
    // 实际项目中可接入图像清晰度检测（拉普拉斯方差）
    
    // 简化版：车速在合理范围内且变化平滑 → 高质量
    let speedInRange = speed >= 0 && speed <= 300
    let speedSmooth = speedHistorySmoothness() > 0.8
    
    return (speedInRange ? 1.0 : 0.0) * (speedSmooth ? 1.0 : 0.5)
}

private func speedHistorySmoothness() -> Double {
    guard history.count >= 5 else { return 1.0 }
    
    // 计算最近 5 帧车速的标准差
    let recent = Array(history.suffix(5))
    let mean = recent.reduce(0, +) / Double(recent.count)
    let variance = recent.map { pow($0 - mean, 2) }.reduce(0, +) / Double(recent.count)
    let stddev = sqrt(variance)
    
    // 标准差越小 → 越平滑 → 得分越高
    return max(0.0, 1.0 - stddev / 30.0)
}
```

---

## 4. 滑动窗口平滑

### 4.1 指数移动平均 (EMA)

```swift
/// EMA 平滑，alpha=0.3
private func applySmoothing(_ raw: Double) -> Double {
    let alpha = 0.3
    let lastSmoothed = history.last ?? raw
    
    return lastSmoothed * (1 - alpha) + raw * alpha
}
```

### 4.2 滑动窗口最小值

```swift
/// 更新历史窗口，维护最小值
private func updateHistory(_ score: Double) {
    history.append(score)
    if history.count > windowSize {
        history.removeFirst()
    }
    
    // 更新窗口最小值（用于检测瞬态故障）
    windowMin = history.min() ?? score
}

/// 窗口最小值低于阈值时触发紧急降级
func isCriticalDrop() -> Bool {
    return windowMin < 0.2
}
```

---

## 5. 诊断输出

```swift
/// 生成详细诊断信息（UI 展示用）
func diagnosticDetails(m9: InferenceResult?,
                       yolo: [Detection],
                       speed: Double) -> String {
    let consistency = estimateConsistency(m9: m9)
    let extremity = estimateExtremity(m9: m9, yolo: yolo)
    let imageQ = estimateImageQuality(speed: speed)
    
    return """
    ── 置信度诊断 ──────────────────────────────
    综合健康度: \(String(format: "%.2f", estimate(m9: m9, yolo: yolo, speed: speed)))
    
    一致性分量: \(String(format: "%.2f", consistency)) (权重 0.5)
      - 推理新鲜: \(m9.flatMap { isFresh($0.latencyMs) } ? "✓" : "✗")
      - 控制协调: \(m9.flatMap { isCoordinated($0) } ? "✓" : "✗")
    
    极端性分量: \(String(format: "%.2f", extremity)) (权重 0.3)
      - 满转向无依据: \(m9.map { abs($0.steer) > 0.9 && !hasObstacle($0.steer > 0) } ? "⚠" : "✓")
      - 满刹车无依据: \(m9.map { $0.brake > 0.9 && !hasCloseObstacle() } ? "⚠" : "✓")
    
    图像质量分量: \(String(format: "%.2f", imageQ)) (权重 0.2)
      - 车速范围: \(speed >= 0 && speed <= 300 ? "✓" : "✗")
      - 车速平滑: \(speedHistorySmoothness() > 0.8 ? "✓" : "⚠")
    
    窗口最小值: \(String(format: "%.2f", windowMin)) (最近 \(history.count) 帧)
    ─────────────────────────────────────────────
    """
}
```

---

## 6. 配置参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `weights.consistency` | 0.5 | [0.3, 0.7] | M9 一致性权重 |
| `weights.extremity` | 0.3 | [0.2, 0.5] | 极端性权重 |
| `weights.imageQuality` | 0.2 | [0.1, 0.3] | 图像质量权重 |
| `windowSize` | 10 | [5, 30] | 滑动窗口大小 |
| `criticalThreshold` | 0.2 | [0.1, 0.3] | 紧急降级阈值 |
| `alpha` | 0.3 | [0.1, 0.5] | EMA 平滑系数 |

---

## 7. 常见问题

### Q1: 健康度波动剧烈？

增大平滑窗口：
```swift
estimator.windowSize = 20  // 默认 10
estimator.alpha = 0.2     // 默认 0.3（更小更平滑）
```

### Q2: 健康度始终偏低？

检查各项分量：
```swift
print(diagnosticDetails(m9: m9, yolo: detections, speed: speed))
```

常见问题:
- 推理延迟过高（>100ms）→ 检查设备负载
- 控制量不协调 → 调整模型或重新标定
- 车速波动大 → 检查 OCR 稳定性

### Q3: 误触发降级？

提高降级阈值或增加迟滞：
```swift
degradeStm.degradeHealth = 0.55  // 默认 0.65（降低敏感度）
degradeStm.recoverHysteresis = 0.25  // 默认 0.15
```

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
