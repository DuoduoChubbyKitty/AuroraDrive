# AuroraDrive 架构文档

> **最后更新**: 2026-08-20  
> **版本**: v2.0 (重构后)  
> **状态**: 活跃开发中

---

## 1. 项目概述

**AuroraDrive** 是 macOS 原生自动驾驶辅助系统，为游戏"异环(NTE)"提供端到端自动驾驶能力。

### 1.1 核心流程

```
游戏画面 → ScreenCaptureKit(30fps) → 三路并行感知 → DegradeStateMachine → CGEvent 按键注入 → 游戏
                 │                       │
                 │               ┌─────────┼─────────┐
                 │               ▼         ▼         ▼
                 │          Inference   YoloEngine  SpeedOCR
                 │          (CoreML)    (障碍检测)  (速度识别)
                 │               │         │         │
                 │               └─────────┴─────────┘
                 │                       │
                 ▼               ConfidenceEstimator
          MetalGoose               (三信号融合)
        (显示路径)                ┌─────────────┐
        ✗ 不进入决策链路          │ 四档降级状态机 │
                                │ e2e→yolo→rec→rule│
                                └──────────────┘
```

### 1.2 技术栈

| 层次 | 技术 | 用途 |
|------|------|------|
| UI | SwiftUI + Swift 5 | 驾驶舱风格界面 |
| 捕获 | ScreenCaptureKit | 30fps 游戏画面截屏 |
| 推理 | CoreML | M9 主模型 + YOLOv26s |
| 控制 | CGEvent | WASD + Space + Shift 注入 |
| 显示 | MetalGoose (MetalFX) | 超分/插帧 (仅显示路径) |
| 定位 | Accelerate/vDSP | NCC 小地图定位 |
| OCR | Accelerate | 模板匹配速度识别 |

### 1.3 关键约束

1. **架构红线**: MetalFX 超分/插帧**只能**作用于显示叠加层，**绝不**进入决策链路
2. **性能目标**: 30fps 决策循环，<100ms 端到端延迟
3. **安全策略**: 四级降级 + 三信号置信度评估

---

## 2. 核心组件

### 2.1 捕获层

**CaptureEngine.swift** (37.8KB)
- ScreenCaptureKit 30fps 循环
- 三路回调: onFrame/UI 预览, onYoloFrame/640×640, onNativeFrame/180×320
- CVPixelBuffer 池管理
- Game Mode Boost: THREAD_TIME_CONSTRAINT_POLICY (20ms 时限)

### 2.2 感知层

**InferenceEngine.swift** (20KB)
- CoreML M9 模型推理
- 输入: image(224×224) + vehicle_state[6]
- 输出: steer[-1,1], throttle[0,1], brake[0,1]
- Generation counter 防止过期结果

**YoloEngine.swift** (36KB)
- CoreML YOLOv26s 障碍物检测
- 输入: 640×640 CVPixelBuffer
- 输出: [x1,y1,x2,y2,conf,class_id]
- IoU 滤波 + 帧间平滑追踪

**SpeedOCRReader.swift** (47KB)
- 固定槽位模板匹配
- 输入: 180×320 图像
- 输出: 0-300 km/h
- 三层验证: 范围检查、跳变检测(60km/h)、多帧确认

**VisualLocator.swift** (32KB)
- NCC 最小地图定位
- 多尺度滑动窗口匹配
- EMA 平滑输出

**ConfidenceEstimator.swift** (12KB)
- 三信号融合: consistency(0.5) + extremity(0.3) + image_quality(0.2)
- 链接健康门控
- 滑动窗口历史分析

### 2.3 决策层

**DegradeStateMachine.swift** (12KB)
- 四级降级状态机
- 状态: `.e2e` → `.yolo` → `.recover` → `.rule`
- 迟滞恢复防止抖动
- 卡住检测: <3km/h 持续 3s

**RuleController.swift** (7.3KB)
- YOLO 检测 → 规则控制
- 危险区域分级: safe/caution/danger/critical
- E2E + 规则融合

**EscapeController.swift** (7.5KB)
- 三阶段脱困策略: REVERSE(1.5s) → TURN(0.8s) → FORWARD(2.0s)
- 随机转向方向避免重复撞墙
- 超时保护 15s

**ControlEngine.swift** (10.5KB)
- CGEvent 键盘注入
- 按键映射: W=13, A=0, S=1, D=2, Space=49, Shift=56
- 自动重复 (100ms 间隔)
- 权限检查: AXIsProcessTrustedWithOptions

### 2.4 UI 层

**AuroraDriveApp.swift** (~176KB, 3480行)
- 主应用入口 + DriveState 状态管理（所有内容内联于单文件）
- 30Hz tick() 循环
- DrivePanel / ModeBadge / ConfidenceBar / KeyboardBar
- SettingsView / DashboardView
- 调试日志 `/tmp/aurora_debug.log` (10MB 轮转)

**GameMapView.swift** (80KB)
- 交互式 NTE 游戏地图 (Tesla 风格)
- 5677 标记点，18 个类别
- 分层渲染 (200/500/1500 由缩放级别决定)

**MinimapLocatorView.swift** (11KB)
- 左上角小地图覆盖 (220pt)
- 8×8 图块缓存
- Tap 手势设置目标点

**AutomationPanel.swift** (11KB)
- 9 项 MaaNTE 自动化功能
- 钓鱼、咖啡、粉爪劫案、家具、奖励、钢琴、节奏、闪避、实时协助

---

## 3. 配置系统

### 3.1 YAML 配置（已删除）

`configs/inference.yaml` 和 `configs/training.yaml` 已于 2026-08-20 审查时删除。两个文件均无调用方：
- Swift 引擎运行时参数全部内联在各 `.swift` 源文件中
- 训练超参由 `src/config.py` 中 Python 常量控制，`train.py` 不读 YAML

如需修改训练超参，编辑 `src/config.py`（如 `TRAIN_EPOCHS_2D=80`, `TRAIN_LR_2D=5e-4`）。

### 3.2 运行时配置（有效）

所有运行时参数内联在各引擎源文件中（Configs.swift 已于 2026-08-16 清理时删除）：
- `CaptureEngine.swift`：帧率、CVPixelBuffer 池大小、ROI 归一化坐标
- `InferenceEngine.swift`：模型路径、预处理尺寸 180×320、车辆状态维度
- `YoloEngine.swift`：输入尺寸 640、置信度阈值、IoU 阈值
- `SpeedOCRReader.swift`：槽位归一化坐标、模板尺寸 25×45、量程 0-400
- `VisualLocator.swift`：大地图路径、多尺度匹配分辨率、EMA 系数
- `DegradeStateMachine.swift`：健康度阈值、脱困超时、卡死判定参数
- `ConfidenceEstimator.swift`：三信号权重、窗口大小、亮度阈值
- `RuleController.swift`：危险区范围、紧迫度阈值、融合系数
- `EscapeController.swift`：三阶段时长、最大超时、退出速度阈值

---

## 4. 已知问题 (来自审计报告)

### P0 级 (必须修复)
1. **降级状态机永久死锁** - UI 滑块≥0.85 时恢复阈值被封到 1.0
2. **档 3"脱困中"未独立显示** - 铁律正面违反
3. **YOLO 输出格式未对拍验证** - 坐标约定可能错误
4. **train_mono 导出随机骨干权重** - 未 reparameterize
5. **速度链路断裂** ✅ 已修复 (2026-08-11) - `effectiveSpeed` 由 OCR 真实车速驱动，`speedValid` 门控状态机/脱困
6. **E2E 输入垂直翻转** ✅ 已证伪 - NCC 匹配已在原坐标下工作，无需翻转
7. **捕获缓冲生命周期竞争** ✅ 已修复 (2026-08-11) - 使用 CVPixelBufferPool 自持拷贝
8. **前台应用无校验** ⚠️ 部分修复 - 有 `frontmostAppBundleId()` 但无 UI 提示

### P1 级
9. 专家模式顶键 ✅ 已实现 (AutomationPanel.swift:229)
10. 脱困超时失效 ✅ 已修复 - `EscapeController.maxDuration` 限制 15s
11. 状态机一致性 ✅ 已修复 - 迟滞机制正常工作
12. 生命周期竞态 ✅ 已修复 - `generation` 防迟到结果

> 完整清单见 `docs/BUGSCAN-20260811.md`。P0 均已闭环，剩余 P1 优先级较低。

---

## 5. 重构规划

### OpenCV 驾驶重构 (进行中)
**目标**: 五信号融合架构

| 信号源 | 技术 | 优先级 |
|--------|------|--------|
| 车道线 | OpenCV + HOG | P0 |
| YOLO | CoreML | P0 |
| HOG | 行人/车辆检测 | P1 |
| 小地图 | NCC + 图层 | P1 |
| 速度 OCR | 模板匹配 | P0 |

**档位设计**:
- 档 1: 纯规则兜底
- 档 2: 五信号融合驾驶
- 档 3: 脱困策略

### 地图系统升级 (进行中)
- 换底图 `bigworldmapSecond.png` (11264×11264)
- 图层开关接活 (原 `filteredMarkers` 被写死返回 [])
- 新增常驻图层浮层

---

## 6. 构建与运行

### 6.1 构建

```bash
# Xcode 16+ / Swift 6.2，macOS 26+
xcodebuild -scheme AuroraDrive -configuration Release build
# 或使用 SwiftPM（需 Xcode 16+）
swift build -c release
```

**依赖**：ScreenCaptureKit（macOS 13+）、CoreML（Apple Silicon）、CGEvent（Input Monitoring 权限）

### 6.2 权限设置

系统设置 > 隐私与安全:
- [x] 屏幕录制
- [x] 辅助功能

### 6.3 命令行自检

```bash
# YOLO 自检
./AuroraDriveUI --yolo-selftest <图片路径>

# 速度 OCR 自检
./AuroraDriveUI --speed-selftest <目录>

# 基准测试
./AuroraDriveUI --yolo-bench <图片路径>
```

---

## 7. 文件索引

| 文件 | 角色 | 大小 | 主线程访问 | 备注 |
|---|---|---|---|---|
| `AuroraDriveApp.swift` | App 入口 / DriveState 全局状态 / Theme UI 组件 | ~176KB | ✓ | 含 AppDelegate、枚举、@Observable DriveState（3480行单文件） |
| `AutomationPanel.swift` | 自动化面板 UI | ~12KB | ✓ | 功能库+开关、多实例支持 |
| `CaptureEngine.swift` | 截屏引擎（ScreenCaptureKit 30fps） | ~37KB | 否 | 线程安全：lock+generation，CVPixelBuffer 池管理 |
| `InferenceEngine.swift` | M9 端到端推理引擎 | ~20KB | 否 | 复用缓冲区、nonisolated 预处理 |
| `YoloEngine.swift` | YOLOv26s 障碍物检测引擎 | ~36KB | 否 | IoU 帧间平滑、手动锁定追踪 |
| `SpeedOCRReader.swift` | 车速 OCR（模板匹配） | ~46KB | 否 | 3 槽固定位置，0-400 km/h 量程 |
| `VisualLocator.swift` | 小地图定位（NCC） | ~31KB | 否 | 积分图 O(1) 查询，EMA 平滑，自检 |
| `DegradeStateMachine.swift` | 四档降级状态机 | ~12KB | 否 | 迟滞 0.65/0.80，Sport 模式覆盖 |
| `ConfidenceEstimator.swift` | 三信号置信度估计 | ~12KB | 是 | consistency(0.5)+extremity(0.3)+image(0.2) |
| `RuleController.swift` | 规则控制器 | ~7KB | 否 | 危险区+紧迫度，fuse E2E+规则 |
| `EscapeController.swift` | 脱困控制器 | ~7KB | 否 | reverse→turn→forward 三阶段 |
| `ControlEngine.swift` | CGEvent 按键注入 | ~10KB | 是 | hold 防游戏忽略，自动 refreshHeldKeys |
| `RecordEngine.swift` | 训练数据录制引擎 | ~19KB | 否 | 环形缓冲+背压+clip 归档 |
| `KeyboardMonitor.swift` | 全局键盘监听 | ~4KB | 是 | NSEvent 全局监控，过滤 autorepeat |
| `GameMapView.swift` | 大地图渲染 | ~78KB | 是 | 11264²像素贴图，HUD标注拖拽 |
| `MinimapLocatorView.swift` | 小地图定位视图 | ~11KB | 是 | 画框选 ROI，实时 NCC 预览 |

> 注：上次清理（2026-08-16）已删除 Configs.swift，所有配置改为各引擎内联常量。

### Python 训练管线 (src/)
| 文件 | 职责 |
|------|------|
| model.py | M9Model + M9MonoModel |
| trainer.py | 训练循环 + EMA |
| dagger.py | DAgger 迭代训练 |
| data_generator.py | 数据生成 |
| expert_controller.py | 专家策略 |
| config.py | 配置管理 |
| train.py | 四阶段训练入口 |
| mono_dataset.py | 单目数据集 |

### Vendor 库
| 文件 | 职责 |
|------|------|
| Vendor/MetalGoose/Engine/GooseEngine.swift | MetalFX 超分/插帧 |
| Vendor/MetalGoose/Engine/CaptureSettings.swift | 捕获配置 |
| Vendor/MetalGoose/Engine/WindowCaptureManager.swift | CGWindowList 捕获 |

---

## 8. 许可

**GNU GPL v3.0**  
Copyright © 2026 DuoduoChubbyKitty

第三方组件:
- MetalGoose (GPL v3.0) - Vendor 于 `Vendor/MetalGoose/`
- MaaNTE 资源 (第三方) - 本地自备
- nteguide 数据 (粉丝采集) - 运行时抓取

---

## 9. 联系方式

- 项目根目录: `/Users/dupi/Desktop/自动驾驶系统/`
- 调试日志: `/tmp/aurora_debug.log`
- 训练数据: `recordings/`
