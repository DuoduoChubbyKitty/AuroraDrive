# AuroraDrive — 异环游戏自动驾驶辅助系统

> **版本**: v2.4.1-e2e-fsd  
> **平台**: macOS 14+ (Apple Silicon)  
> **开源协议**: GNU GPL v3.0  
> **作者**: DuoduoChubbyKitty

---

## 一、项目简介

AuroraDrive 是一款基于 macOS 原生技术的游戏自动驾驶辅助工具，为游戏「异环 (NTE)」提供从截屏到方向盘控制的完整闭环。系统采用四层感知架构：端到端深度学习（CoreML M9 模型）→ 目标检测（YOLOv26s）→ 纯规则控制 → 脱困策略，并配备四级降级状态机保障安全。

本系统仅供学习与研究使用，禁止用于任何商业目的。

**一句话理解**：看屏幕 → 懂路况 → 打方向 → 踩油门 → 控车辆。

---

## 二、快速开始

### 2.1 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | macOS 14.0+ (Apple Silicon) |
| Xcode | 16.0+ / Swift 6.2 |
| 权限 | 屏幕录制 + 辅助功能 |
| 内存 | 最低 8GB（推荐 16GB） |
| 磁盘 | 预留 5GB（含模型文件） |

### 2.2 首次构建

```bash
cd ~/Desktop/自动驾驶系统
swift build -c release
```

构建产物位于 `.build/release/AuroraDrive`。

### 2.3 权限配置

在「系统设置 → 隐私与安全性」中授予：
- [x] **屏幕录制**（CaptureEngine 需要读取游戏画面）
- [x] **辅助功能**（ControlEngine 需要向游戏注入键盘事件）

> ⚠️ 修改权限后需**完全退出并重启应用**。

### 2.4 启动应用

双击 `.app` 或在终端运行：

```bash
.open .build/release/AuroraDrive.app
```

---

## 三、架构概览

### 3.1 数据流

```
┌─────────────────────────────────────────────────────────────────────┐
│                         游戏画面 (ScreenCaptureKit)                  │
│                           30 fps 持续流                             │
└──────────────────┬──────────────────────────────────────────────────┘
                   │
        ┌──────────┼──────────┬──────────────────┐
        ▼          ▼          ▼                  ▼
   ┌─────────┐ ┌────────┐ ┌────────┐      ┌──────────┐
   │Inference│ │YoloEngine│ │SpeedOCR│      │VisualLoc │
   │Engine   │ │(障碍检测)│ │(车速表)│      │(小地图)  │
   │(M9 模型)│ └───┬────┘ └───┬────┘      └────┬─────┘
   └────┬────┘     │        │                │
        │          │        │                │
        └──────────┴────────┴────────────────┘
                   │
              ┌────▼────┐
              │Confidence│
              │Estimator │ ← 三信号融合: consistency + extremity + image
              └────┬────┘
                   │
           ┌───────▼───────────────┐
           │   DegradeStateMachine │
           │  (四档降级状态机)      │
           └───────┬───────────────┘
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   ┌─────────┐ ┌────────┐ ┌────────────┐
   │  E2E    │ │ Rule   │ │  Escape    │
   │ (主驾)  │ │ (规则) │ │  (脱困)    │
   └────┬────┘ └───┬────┘ └─────┬──────┘
        │          │            │
        └──────────┴────────────┘
                   │
            ┌──────▼──────┐
            │ControlEngine│
            │ (CGEvent 键 │
            │  盘注入)    │
            └──────┬──────┘
                   │
            ┌──────▼──────┐
            │  游戏窗口    │
            │  (WASD+Space)│
            └─────────────┘
```

### 3.2 四级降级状态机

| 档位 | 模式 | 触发条件 | 恢复条件 |
|------|------|----------|----------|
| 1 | **E2E** | 初始状态，M9 健康度 > 0.80 | 卡住时下降 |
| 2 | **Yolo** | E2E 健康度 < 0.65 | 健康度回升 > 0.80 |
| 3 | **Recover** | 卡住 3 秒，或 OCR 失效 | 速度恢复 > 3 km/h |
| 4 | **Rule** | 所有 AI 链路失效 | 健康度恢复 > 0.65 |

> **迟滞机制**：降级阈值 0.65，恢复阈值 0.80，防止在临界点抖动。

### 3.3 技术栈

| 层次 | 技术 | 职责 |
|------|------|------|
| UI | SwiftUI + Swift 5 | 驾驶舱风格界面，Tesla 风格中控屏 |
| 捕获 | ScreenCaptureKit | 30 fps 游戏画面截屏 |
| 推理 | CoreML | M9 端到端模型 + YOLOv26s 检测 |
| 控制 | CGEvent | WASD + 空格 + Shift 按键注入 |
| 定位 | Accelerate (NCC) | 小地图模板匹配定位 |
| OCR | Accelerate (模板匹配) | 固定槽位数字识别 |
| 显示 | MetalGoose (MetalFX) | 超分/插帧（仅显示路径，不参与决策） |

---

## 四、使用指南

### 4.1 主界面

启动后界面分为三个区域：

1. **驾驶舱显示屏**（中央）
   - 实时游戏画面（左上角预览）
   - 小地图定位（左下角）
   - 速度表数字显示（右下角）
   - 障碍物检测框（YOLO 模式）

2. **右侧控制面板**
   - 驱动模式芯片（E2E / Yolo / Rule / Recover）
   - 置信度进度条
   - 键盘状态可视化（W/A/S/D/空格/Shift）
   - 启动/停止按钮

3. **底部状态栏**
   - 帧率 (FPS)
   - 推理耗时 (ms)
   - 车速 (km/h)
   - 档位健康度

### 4.2 操作说明

| 操作 | 说明 |
|------|------|
| 点击「启动驾驶」 | 开始自动驾驶，系统接管方向盘 |
| 点击「停止驾驶」 | 停止自动驾驶，交还控制权 |
| 拖拽小地图框选 | 标定速度表 ROI 位置 |
| 长按「专家模式」 | 关闭避障，强制 E2E 走极致路线 |
| 切换录制开关 | 开启/关闭训练数据录制 |

### 4.3 命令行自检

```bash
# YOLO 引擎自检（传入任意截图路径）
./AuroraDriveUI --yolo-selftest /path/to/screenshot.png

# 速度 OCR 自检（传入录制的帧目录）
./AuroraDriveUI --speed-selftest /path/to/frames/

# YOLO 性能基准测试（对比直通路径 vs 慢路径）
./AuroraDriveUI --yolo-bench /path/to/screenshot.png
```

### 4.4 调试日志

应用运行时会写入调试日志到 `/tmp/aurora_debug.log`，最大 10MB 自动轮转。

```bash
# 实时查看日志
tail -f /tmp/aurora_debug.log

# 搜索错误
grep -i "error\|fail" /tmp/aurora_debug.log
```

---

## 五、配置说明

所有运行时参数内联在各引擎源文件中，可通过 UI 滑块实时调整：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `degradeThreshold` | 0.65 | 降级健康度阈值 |
| `recoverHysteresis` | 0.15 | 恢复迟滞量 |
| `stuckSpeedThreshold` | 3.0 km/h | 卡住速度阈值 |
| `stuckTimeThreshold` | 3.0 s | 卡住时间阈值 |
| `confidenceThreshold` | 0.22 | YOLO 置信度阈值 |
| `iouThreshold` | 0.45 | YOLO IoU 阈值 |
| `maxDetections` | 20 | 单帧最多保留框数 |
| `sportMode` | false | 极速模式（关闭避障） |

> 详细配置见 [二级开发者文档](./docs/DEVELOPER.md)。

---

## 六、训练流程

### 6.1 数据录制

在应用内开启录制开关，系统会自动录制：
- 游戏画面帧 (PNG, 180×320)
- 对应人工操作 (steer/throttle/brake)
- 车辆状态 (speed, rpm, gear)

录制文件保存至 `recordings/` 目录。

### 6.2 模型训练

```bash
# 进入 Python 训练环境
cd ~/Desktop/自动驾驶系统

# 查看配置
python -c "from src.config import *; print(f'epochs={TRAIN_EPOCHS_2D}, lr={TRAIN_LR_2D}')"

# 启动训练（四阶段）
python -m src.train --stage all --epochs 80 --batch_size 4

# 导出 CoreML 模型
python tools/export_game_assist_coreml.py --input models/model_final.pt --output models/m9_mono.mlmodelc
```

### 6.3 DAgger 迭代

本项目采用 DAgger (Dataset Aggregation) 算法进行迭代训练：
1. 初始模型由专家演示数据训练
2. 部署到游戏中收集错误轨迹
3. 标注错误轨迹的专家操作
4. 合并数据重新训练
5. 重复步骤 2-4 直到性能达标

---

## 七、常见问题

### Q1: 应用启动后画面是黑的？

检查权限：系统设置 → 隐私与安全性 → 屏幕录制，确保 AuroraDrive 已授权。

### Q2: 按键没有响应（游戏没动）？

检查辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，确保 AuroraDrive 已授权。

### Q3: 速度显示为 0 或乱跳？

1. 打开「HUD 标注」模式，手动框选速度表区域
2. 确认速度表 ROI 坐标正确（默认右下角）
3. 检查字模库 `models/speed_glyphs.json` 是否存在

### Q4: YOLO 检测到框但框不跟随？

1. 确认 YOLO 引擎已启用 (`YoloEngine.enabled = true`)
2. 降低置信度阈值尝试 (`confidenceThreshold = 0.15`)
3. 检查是否开启了锁定追踪 (`lockOnEnabled`)

### Q5: 车辆卡住不动？

1. 查看降级状态机是否进入 Recover 档
2. 检查 `speedValid` 是否为 true（OCR 是否正常）
3. 延长脱困超时时间 (`recoverTimeout = 45.0`)

### Q6: 构建失败提示缺少依赖？

```bash
# 安装 Swift Package Manager 依赖
swift package resolve

# 清理缓存后重试
rm -rf .build && swift build -c release
```

---

## 八、性能约束

| 指标 | 目标值 | 当前实测 |
|------|--------|----------|
| 决策循环频率 | 30 Hz | ~28 Hz |
| 端到端延迟 | <100 ms | ~65 ms |
| M9 推理耗时 | <30 ms | ~22 ms |
| YOLO 推理耗时 | <40 ms | ~35 ms |
| OCR 识别耗时 | <15 ms | ~8 ms |
| 内存占用 | <500 MB | ~380 MB |

> 性能数据基于 Apple M2 Pro @ 30fps 实测。

---

## 九、已知限制

1. **仅支持全屏/窗口模式**：不支持无边框窗口（屏幕录制 API 限制）
2. **仅限 Apple Silicon**：CoreML 优化针对 M 系列芯片，Intel Mac 性能较差
3. **游戏版本依赖**：HUD 布局可能随版本更新变化，需重新标定 ROI
4. **多显示器支持有限**：仅支持主显示器或指定窗口
5. **网络断开影响**：首次启动需要下载模型权重（如有 CDN）

---

## 十、开发路线图

### v2.5 (规划中)
- [ ] 车道线检测（OpenCV + HOG）
- [ ] 五信号融合架构
- [ ] 云端模型更新机制
- [ ] 多游戏适配层

### v3.0 (愿景)
- [ ] BEVFormer 鸟瞰图融合
- [ ] 多车协同感知
- [ ] 真实道路迁移

---

## 十一、开源声明与致谢

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
- 感谢 All-AI-World / 自动驾驶系统社区的技术启发
- 感谢 NTE/异环 游戏开发者 miHoYo 提供测试环境
- 感谢 Apple Silicon 团队提供的 CoreML 优化工具链

---

## 导航链接

| 文档级别 | 文件名 | 内容说明 |
|----------|--------|----------|
| 📘 一级 | [README.md](./README.md)（本文档） | 项目简介与快速开始 |
| 📗 二级 | [DEVELOPER.md](./docs/DEVELOPER.md) | 开发者接口与架构详解 |
| 📙 三级 | [SUBSYSTEMS/](./docs/SUBSYSTEMS/) | 各子系统技术文档 |
| 📕 架构 | [ARCHITECTURE.md](./docs/ARCHITECTURE.md) | 系统架构与设计决策 |
| 📓 快速 | [QUICKSTART.md](./docs/QUICKSTART.md) | 快速上手指南 |
| 📜 许可 | [LICENSE](./docs/LICENSE) | GPL v3.0 许可证全文 |
| 📝 声明 | [NOTICE](./docs/NOTICE) | 第三方组件声明 |

---

*最后更新: 2026-08-21 | 作者: DuoduoChubbyKitty*
