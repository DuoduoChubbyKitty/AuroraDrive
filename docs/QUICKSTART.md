# AuroraDrive 快速开始指南

## 环境要求

- macOS 26+ (Apple Silicon)
- Xcode 16+ / Swift 6.2
- 屏幕录制 + 辅助功能权限

## 构建

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"
xcodebuild -scheme AuroraDrive -configuration Release build
# 或使用 SwiftPM
swift build -c release
```

产物: `.build/release/AuroraDrive`（SwiftPM）或 Xcode DerivedData 中的 `.app`

## 首次运行

1. 打开系统设置 > 隐私与安全
2. 授予"屏幕录制"权限
3. 授予"辅助功能"权限
4. 完全退出并重启应用

## 运行时配置

所有运行时参数内联在各引擎源文件中，通过 UI 可调：
- **健康度阈值**：DriveState.degradeThreshold（默认 0.65）
- **YOLO 置信度**：YoloEngine.confidenceThreshold（默认 0.22）
- **OCR 槽位**：SpeedOCRReader.slotCentersNorm（可通过 HUD 标注覆盖）
- **危险区范围**：RuleController.dangerHalfWidth/dangerYMin
- **运动模式**：DriveState.sportMode（关闭避障，强制 E2E）

## 训练配置

```bash
# 训练参数由 src/config.py 中的 Python 常量控制
python -m src.train --stage all --epochs 80 --batch_size 4

# 查看当前默认值
python -c "from src.config import *; print(f'epochs_2d={TRAIN_EPOCHS_2D}, lr={TRAIN_LR_2D}')"
```

## 已知问题

详见 [ARCHITECTURE.md](./ARCHITECTURE.md) 第 4 节

## 调试日志

- 路径: `/tmp/aurora_debug.log`
- 大小限制: 10MB 轮转
- 查看: `tail -f /tmp/aurora_debug.log`
