<div align="center">

# AuroraDrive

**macOS 第三方《异环》(NTE) 视角自动驾驶系统**

屏幕捕获 → CoreML 推理 → 按键注入，附带网络抓包定位、速度表 CNN 识别与 MetalFX 显示增强

[English Documentation](README.en.md) · 开发者文档 · [Developer Guide (EN)](docs/DEVELOPER_GUIDE.en.md)

</div>

> ⚠️ **免责声明 / Disclaimer**：本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。
> *This project is for research and personal learning only. Automating game input may violate the game's Terms of Service. The author is not responsible for any consequences, including account suspension.*

---

## 🙏 致谢 / Acknowledgements

| 项目 / Resource | 用途 / Purpose | 许可证 / License |
|---|---|---|
| [**MaaNTE**](https://github.com/1bananachicken/MaaNTE) | 网络定位算法蓝本（UE5 移动包位流解析、坐标标定，移植自其 `nte_coordinate_api.py`）；全收集地图图源 | AGPL-3.0 |
| [**MetalGoose**](https://github.com/Stallion77RepoOfficial/MetalGoose) | MetalFX 超分 + 插帧引擎（`Vendor/MetalGoose`，仅作用于显示层） | GPL-3.0 |
| [**nteguide.com**](https://nteguide.com) | 全收集地图标记数据 | 经作者许可 |

> 📌 MaaNTE 源码不随本仓库分发（AGPL-3.0 传染性），仅本地参考并在上表致谢。地图资源经群主许可分发。
> *MaaNTE source code is NOT distributed with this repo (AGPL-3.0 is viral); it is credited above and kept as a local reference only.*

## ✨ 核心功能 / Features

- **端到端自动驾驶**：M9 单目模型直接从画面输出操控量，四档降级保底（端到端 → YOLO 接管 → 脱困 → 规则兜底）
- **网络抓包定位**：libpcap 捕获 UE5 移动同步包（tcp/30031），位流解码出世界坐标 + 朝向，映射到 11264×11264 大地图像素
- **速度表 CNN 识别**：5 层卷积网络（`speed_digit_cnn_v4.mlpackage`，INT4 量化），三槽位逐位识别 + 三层校验
- **BPF 权限自动安装**：App 内输入一次管理员密码，自动安装 LaunchDaemon，每次开机自动恢复 `/dev/bpf*` 读写权
- **自愈式定位**：网络失效 → 视觉模板匹配顶班 → 后台 8 种诊断 + 自动修复 → 自动切回
- **全收集交互地图**：多图层开关（传送点/材料/宝箱/谕石），实时玩家位置 + 朝向
- **MetalFX 显示增强**：超分 + 插帧，只作用于显示层，**绝不进入**「捕获→推理→按键」决策链路

## 🚀 快速开始 / Quick Start

**环境要求 / Requirements**：macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap（系统自带）

```sh
git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # 编译 + 签名 + 启动 / build + sign + launch
./run.sh --status   # 只检查环境 / environment check only
```

**系统权限**：屏幕录制 + 辅助功能（系统设置 → 隐私与安全）
*macOS permissions required: Screen Recording + Accessibility.*

**BPF 权限（网络定位必需）**：首次启动会弹出 App 内密码窗（默认 `123456`），输入后自动安装 `com.aurora.bpf-setup` LaunchDaemon——之后每次重启自动恢复权限，永不再输。

## 🏗️ 架构 / Architecture

```
┌─ 捕获层 Capture ──────┐   ┌─ 推理层 Inference ───────┐   ┌─ 执行层 Actuate ───┐
│ ScreenCaptureKit      │ → │ E2E(m9_mono) 30Hz        │ → │ CGEvent 按键注入    │
│ 30Hz CVPixelBuffer    │   │ YOLO(yolo26s) 检测        │   │ (ControlEngine)     │
├─ 定位层 Locate ───────┤   │ 速度CNN(v4) 30Hz          │   ├─ 显示层 Display ───┤
│ libpcap tcp/30031     │   ├─ 决策层 Decide ──────────┤   │ MetalFX 超分+插帧   │
│ UE5位流→世界坐标       │   │ 四档降级状态机             │   │ 全收集交互地图      │
│ →11264px 地图像素      │   │ e2e/yolo/recover/rule     │   │ (仅人眼观看)        │
└───────────────────────┘   └───────────────────────────┘   └────────────────────┘
```

**架构红线**：插帧/超分只作用于显示叠加层，绝不进入决策链路。
*Frame interpolation / upscaling ONLY applies to the display overlay — never to the capture → inference → key-injection decision path.*

## 📚 文档 / Documentation

| 层级 | 中文 | English |
|---|---|---|
| 入口 Overview | [README（本页）](README.md) | [README.en](README.en.md) |
| 二级 Developer Guide | [开发者文档](docs/DEVELOPER_GUIDE.md) | [Developer Guide](docs/DEVELOPER_GUIDE.en.md) |
| 三级 Architecture | [系统架构](docs/dev/01-architecture.md) | [Architecture](docs/dev/en/01-architecture.en.md) |
| 三级 Network Locate | [网络定位](docs/dev/02-network-locate.md) | [Network Localization](docs/dev/en/02-network-locate.en.md) |
| 三级 Speed OCR | [速度识别](docs/dev/03-speed-ocr.md) | [Speed Recognition](docs/dev/en/03-speed-ocr.en.md) |
| 三级 Vision & Inference | [视觉与推理](docs/dev/04-vision-inference.md) | [Vision & Inference](docs/dev/en/04-vision-inference.en.md) |
| 三级 Control & Safety | [控制与安全](docs/dev/05-control-safety.md) | [Control & Safety](docs/dev/en/05-control-safety.en.md) |
| 四级 Internals | [核心实现原理](docs/internals/) | [Internals](docs/internals/en/) |

## 📄 许可证 / License

GPL-3.0 —— 见 [NOTICE](NOTICE)。所有原始源码带 SPDX 头。
*See [NOTICE](NOTICE) for third-party component licenses. Original sources carry SPDX headers:*

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```