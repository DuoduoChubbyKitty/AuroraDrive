# DegradeStateMachine 子系统文档

> **文件**: `src/AuroraDrive/DegradeStateMachine.swift`  
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

DegradeStateMachine 是 AuroraDrive 的**决策核心**，实现四级降级状态机。当主驾驶模型（M9）失效时，系统自动降级到备用模式，保障基本行驶能力。

**关键设计目标**:
- 单调降级：只能往低档走，防止频繁横跳
- 迟滞恢复：恢复需要比降级更高的健康度，防止抖动
- 卡住检测独立于模型：即使模型很自信，车不动就脱困
- 极速模式覆盖：sportMode 开启时强制使用 E2E

---

## 2. 状态定义

```swift
enum DriveMode: String, CaseIterable {
    case e2e     // 端到端主驾（M9 模型，最高优先级）
    case yolo    // YOLO 接管（第二套神经网络 + 规则）
    case recover // 脱困中（Escape 策略，临时状态）
    case rule    // 纯规则兜底（最后防线）
}
```

### 2.1 状态层级

```
.e2e (健康度 > 0.80)
  │
  ├── 健康度 < 0.65 ──► .yolo
  │                      │
  │                      ├── 辅助模型失效 ──► .rule
  │                      └── 卡住 3 秒 ───────► .recover
  │                                                  │
  │                                                  ├── 速度恢复 ──► .e2e/.yolo
  │                                                  └── 超时 30 秒 ─► .rule
  │
  └── 卡住 3 秒 ────────────────────────────────────► .recover
```

---

## 3. 核心实现

### 3.1 初始化

```swift
@Observable
final class DegradeStateMachine {
    // MARK: - 可调阈值
    
    var degradeHealth: Double = 0.65      // 触发降级健康度下限
    var recoverHysteresis: Double = 0.15  // 恢复迟滞量
    var stuckSpeedThreshold: Double = 3.0 // km/h，低于此值视为卡住
    var stuckTimeThreshold: Double = 3.0  // 秒，持续卡住时长
    var recoverTimeout: Double = 30.0     // 脱困档最大时长
    
    // MARK: - 状态输出
    
    private(set) var mode: DriveMode = .e2e
    private(set) var lastTransitionReason: String = "初始化"
    private(set) var stuckSeconds: Double = 0
    private(set) var sportOverride: Bool = false
    
    // MARK: - 内部状态
    
    private var previousMode: DriveMode = .e2e
    private var recoverElapsed: Double = 0
    private var lastUpdateTime: Date?
    
    /// 根据输入更新状态机
    func update(m9Live: Bool,
                assistLive: Bool,
                health: Double,
                warmingUp: Bool,
                speedKmh: Double,
                speedValid: Bool,
                sportOverride: Bool) -> DriveMode {
        
        self.sportOverride = sportOverride
        let now = Date()
        let dt = lastUpdateTime.map { now.timeIntervalSince($0) } ?? (1.0/30.0)
        lastUpdateTime = now
        
        // Sport 模式覆盖：强制 E2E
        if sportOverride {
            mode = .e2e
            lastTransitionReason = "极速模式激活"
            return .e2e
        }
        
        // 暖机期：不降级
        if warmingUp {
            return mode
        }
        
        // 计算恢复阈值（迟滞机制）
        let recoverThreshold = degradeHealth + recoverHysteresis
        
        // 状态转移逻辑
        switch mode {
        case .e2e:
            if health < degradeHealth && !m9Live {
                mode = .yolo
                lastTransitionReason = "M9 健康度不足 (\(String(format: "%.2f", health)) < \(degradeHealth))"
            } else if !speedValid || speedKmh < stuckSpeedThreshold {
                stuckSeconds += dt
                if stuckSeconds >= stuckTimeThreshold {
                    mode = .recover
                    recoverElapsed = 0
                    lastTransitionReason = "车辆卡住 \(stuckSeconds.Seconds)"
                }
            } else {
                stuckSeconds = 0
            }
            
        case .yolo:
            if health >= recoverThreshold && m9Live {
                mode = .e2e
                lastTransitionReason = "M9 恢复健康 (\(String(format: "%.2f", health)) > \(recoverThreshold))"
            } else if !assistLive {
                mode = .rule
                lastTransitionReason = "YOLO 辅助模型失效"
            } else if !speedValid || speedKmh < stuckSpeedThreshold {
                stuckSeconds += dt
                if stuckSeconds >= stuckTimeThreshold {
                    mode = .recover
                    recoverElapsed = 0
                    lastTransitionReason = "车辆卡住 (YOLO 档)"
                }
            } else {
                stuckSeconds = 0
            }
            
        case .recover:
            recoverElapsed += dt
            
            // 检查是否脱困
            if speedValid && speedKmh > stuckSpeedThreshold {
                // 脱困成功，返回原模式
                let targetMode = previousMode == .e2e ? .e2e : .yolo
                mode = targetMode
                lastTransitionReason = "脱困成功 (速度=\(String(format: "%.1f", speedKmh)) km/h)"
                recoverElapsed = 0
            } else if recoverElapsed >= recoverTimeout {
                // 脱困超时，降级到规则模式
                mode = .rule
                lastTransitionReason = "脱困超时 (\(String(format: "%.1f", recoverElapsed))s > \(recoverTimeout)s)"
                recoverElapsed = 0
            }
            
        case .rule:
            if health >= degradeHealth && m9Live {
                mode = .e2e
                lastTransitionReason = "M9 恢复 (从 Rule 档)"
            } else if assistLive {
                mode = .yolo
                lastTransitionReason = "YOLO 恢复 (从 Rule 档)"
            }
        }
        
        // 记录上一模式（用于 recover 后恢复）
        if mode != previousMode {
            previousMode = mode
        }
        
        return mode
    }
}
```

### 3.2 迟滞机制

```swift
/// 迟滞恢复防止抖动
///
/// 降级阈值: 0.65
/// 恢复阈值: 0.65 + 0.15 = 0.80
///
/// 效果：健康度在 [0.65, 0.80] 区间时，保持当前档位不变
private func shouldRecover(currentHealth: Double, previousMode: DriveMode) -> Bool {
    let recoverThreshold = degradeHealth + recoverHysteresis
    return currentHealth > recoverThreshold
}
```

---

## 4. 卡住检测

### 4.1 检测逻辑

```swift
/// 卡住检测条件
/// - speedValid: OCR 是否提供有效车速
/// - speedKmh: 当前车速
/// - stuckSpeedThreshold: 卡住速度阈值（默认 3 km/h）
/// - stuckTimeThreshold: 卡住时间阈值（默认 3 秒）
func isStuck(speedValid: Bool, speedKmh: Double) -> Bool {
    // OCR 无效时不累计卡住时长（防止误判）
    guard speedValid else { return false }
    
    // 车速低于阈值
    return speedKmh < stuckSpeedThreshold
}
```

### 4.2 脱困策略

```swift
/// 脱困模式下的特殊处理
func handleRecover(speedKmh: Double, speedValid: Bool) -> (mode: DriveMode, reason: String) {
    // 脱困成功：速度恢复且 OCR 有效
    if speedValid && speedKmh > stuckSpeedThreshold {
        return (.e2e, "脱困成功")
    }
    
    // 脱困超时：强制降级
    if recoverElapsed >= recoverTimeout {
        return (.rule, "脱困超时")
    }
    
    // 继续脱困
    return (.recover, "脱困中 (\(String(format: "%.1f", recoverElapsed))s/\(recoverTimeout)s)")
}
```

---

## 5. Sport 模式

### 5.1 设计原理

Sport 模式（极速模式）覆盖所有降级逻辑，强制使用 E2E 模式。

**触发条件**: 用户在 UI 中开启「专家模式」

**效果**:
- 关闭避障（RuleController 不介入）
- 禁用降级状态机
- 完全信任 M9 模型输出

### 5.2 实现

```swift
/// Sport 模式覆盖
func updateWithSportOverride(_ m9Result: InferenceResult?) -> DriveMode {
    // 只要 sportMode 开启，强制返回 .e2e
    return .e2e
}

/// 检查是否可以进入 Sport 模式
func canEnableSportMode() -> Bool {
    // 模型必须已加载
    return inferenceEngine.isLoaded
}
```

---

## 6. 诊断输出

```swift
/// 生成诊断信息（UI 展示用）
func diagnosticInfo() -> String {
    return """
    模式: \(mode.rawValue)
    健康度: \(String(format: "%.2f", /* 当前健康度 */))
    卡住时长: \(String(format: "%.1f", stuckSeconds))s
    脱困时长: \(String(format: "%.1f", recoverElapsed))s
    上次转换: \(lastTransitionReason)
    """
}
```

---

## 7. 配置参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `degradeHealth` | 0.65 | [0.5, 0.8] | 触发降级健康度下限 |
| `recoverHysteresis` | 0.15 | [0.1, 0.3] | 恢复迟滞量 |
| `stuckSpeedThreshold` | 3.0 | [1.0, 5.0] | km/h，低于此值视为卡住 |
| `stuckTimeThreshold` | 3.0 | [1.0, 10.0] | 秒，持续卡住时长 |
| `recoverTimeout` | 30.0 | [15.0, 60.0] | 脱困档最大时长 |

---

## 8. 状态转移图

```
                    ┌─────────────────────────────────┐
                    │        启动 (warmingUp)          │
                    │         保持当前模式             │
                    └───────────────┬─────────────────┘
                                    │
                                    ▼
                            ┌───────────────┐
                            │     .e2e      │ ← 健康度 > 0.80
                            │  (M9 主驾)    │
                            └───────┬───────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
              ▼                     ▼                     ▼
    ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
    │ 健康度 < 0.65   │   │ 卡住 3 秒       │   │ 正常行驶         │
    │ M9 失效         │   │ speedValid=false│   │ 保持 .e2e        │
    └────────┬────────┘   └────────┬────────┘   └─────────────────┘
             │                     │
             ▼                     ▼
    ┌─────────────────┐   ┌─────────────────┐
    │      .yolo      │   │     .recover    │
    │  (YOLO 接管)    │   │   (脱困中)       │
    └────────┬────────┘   └────────┬────────┘
             │                     │
    ┌────────┴────────┐     ┌────────┴────────┐
    │                 │     │                 │
    ▼                 ▼     ▼                 ▼
┌─────────┐   ┌───────────┐ ┌───────────┐   ┌───────────┐
│辅助模型 │   │ 卡住继续  │ │速度恢复   │   │ 超时 30s  │
│ 失效    │   │ > 3 秒    │ │> 3km/h    │   │           │
└────┬────┘   └─────┬─────┘ └─────┬─────┘   └─────┬─────┘
     │              │             │                │
     ▼              ▼             ▼                ▼
┌───────────┐ ┌───────────┐ ┌───────────┐   ┌───────────┐
│   .rule   │ │  .recover │ │  .e2e/.yolo│   │   .rule   │
│ (纯规则)  │ │  (继续脱困)│ │ (恢复原模式)│   │ (最终兜底) │
└───────────┘ └───────────┘ └───────────┘   └───────────┘
     │
     │ 健康度 > 0.65
     ▼
┌───────────┐
│   .e2e    │
│ (恢复主驾) │
└───────────┘
```

---

## 9. 常见问题

### Q1: 状态机频繁切换档位？

可能是迟滞量过小。增大 `recoverHysteresis`:
```swift
degradeStm.recoverHysteresis = 0.25  // 默认 0.15
```

### Q2: 车辆卡住但没触发脱困？

检查 OCR 是否正常：
```swift
// 确认 speedValid 为 true
print("speedValid: \(degradeStm.speedValid)")
print("speedKmh: \(degradeStm.speedKmh)")
```

### Q3: 脱困超时太短？

延长脱困时间：
```swift
degradeStm.recoverTimeout = 45.0  // 默认 30 秒
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

相关组件:
- Apple Foundation (状态机实现)
- Observation framework (UI 响应式更新)

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
