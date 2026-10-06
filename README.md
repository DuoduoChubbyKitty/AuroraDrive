<div align="center">

# AuroraDrive

**macOS 第三方《异环》(NTE) 视角自动驾驶系统**

屏幕捕获 → CoreML 推理 → 按键注入，附带网络抓包定位、速度识别（PP-OCRv6 微调 int8）与 MetalFX 显示增强

[English Documentation](README.en.md) · 开发者文档 · [Developer Guide (EN)](docs/文档库/英文版/DEVELOPER_GUIDE.en.md)

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
- **网络抓包定位**：libpcap 捕获 UE5 移动同步包（tcp/30031），位流解码出世界坐标 + 朝向，映射到 13056×13056 大地图像素（map-2026-08，2026-09-13 升级）
- **速度识别**：PP-OCRv6 微调整行模型（`models/ppocrv6_tiny_ft_int8.mlpackage`，int8 量化，GPU 推理）为主路径，逐位 CNN（`speed_digit_cnn_v4*`）为备用，三层校验
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
├─ 定位层 Locate ───────┤   │ 速度OCR(PP-OCRv6) 30Hz  │   ├─ 显示层 Display ───┤
│ libpcap tcp/30031     │   ├─ 决策层 Decide ──────────┤   │ MetalFX 超分+插帧   │
│ UE5位流→世界坐标       │   │ 四档降级状态机             │   │ 全收集交互地图      │
│ →13056px 地图像素     │   │ e2e/yolo/recover/rule     │   │ (仅人眼观看)        │
└───────────────────────┘   └───────────────────────────┘   └────────────────────┘
```

**架构红线**：插帧/超分只作用于显示叠加层，绝不进入决策链路。
*Frame interpolation / upscaling ONLY applies to the display overlay — never to the capture → inference → key-injection decision path.*

### ⚠️ 上图为早期形态（2026-09-29 复核提示）

上方架构图描述的是**单进程早期形态**。项目此后演进出**四大支柱**，本图尚未反映。
**权威文档请以 `docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md` 为准。**

| 支柱 | 说明 | 为何本图未体现 |
|---|---|---|
| **① 双进程 + 共享内存 v3** | UI 与引擎是两个长驻进程，经 `/aurora_frame_v1` 共享内存（72MB）传帧与检测；`EngineClient.protocolVersion = 3` | 写作时还是单进程 |
| **② YOLOPX 三合一感知** | `YolopxEngine`：一个模型同时出 `det`（检测）/ `da`（可行驶区）/ `ll`（车道线），15Hz。**★核心资产，模型一个字节都不能换** | 写作时只有 `yolo26s` |
| **③ 光流 + 运动预测** | OpenCV DIS 光流（`Vendor/OpenCVFlow`，≤5ms 红线）把 15Hz 检测补成 30Hz（α-β 滤波外推） | 写作后新增 |
| **④ 掩码可视化** | 可行驶区/车道线掩码经共享内存传回 UI 叠加显示（bit-pack，160×160 网格） | 写作后新增 |

> 另注：架构图中 `YOLO(yolo26s) 检测` 的表述需留意——`yolo26s` 在项目中**主要用于预测侧**，
> 而游戏内目标检测的主路径是 **YOLOPX 的 `det` 头**。详见 `代码-14` 与 `04-vision-inference` §4.8。

## 🧹 2026-09-19 磁盘清理 / Disk cleanup

为释放本地磁盘，以下路径已迁至外置硬盘（**准确路径（2026-09-29 实测修正，原文少了两级目录）**：

```
/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/
```

实测该归档目录 **22 GB / 9 个子目录**（与下表迁移项一一对应）：
`web_frames` / `template_scratch` / `build_contact` / `ocr_batch` / `ocr_batch2` /
`gray_cache` / `video_*` / `build_cache` / `ppocrv6_finetune_output`。

> 📌 原文写的路径是 `/Volumes/代码项目/删除_20260919/自动驾驶系统清理/`，**该路径不存在**（`ls` 报 No such file）。
> 实际上它嵌在「自动驾驶项目半成品版本1.0到10.0」目录内。**已按实测修正。**

（完整对照表见 `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` §七）：

- `data/web_frames`（19G）、`build/vid_*.mp4`、`build/template_scratch`、`build/contact`、`build/ocr_batch(2)`、`data/_gray_cache`
- `tools/ppocrv6_finetune/output`（可重训再生，内容已迁外置硬盘，本地目录已删）
- `.build`（swift build 自动重建）

✅ **实测确认**：上述 7 项在本地**均已不存在**（迁移已完成，非待办）。

本地保留的相关数据：`build/new_templates`（**265 条目 / 264 张 png**，2026-09-29 实测；原文写 291/268，⚠️ 数字已变——另有 `_rejected/` 27 项淘汰候选）、`build/dig_*.json`（52 份挖掘证据 ✅ 实测吻合）、`build/maa_pipeline_override.json`（250 节点 ROI override ✅ 实测吻合）、`data/mac_shots`（208 张实机截图 ✅ 实测吻合）。

铁律：**不降帧率、不打补丁绕过**。

## 📚 文档 / Documentation

| 层级 | 中文 | English |
|---|---|---|
| 入口 Overview | [README（本页）](README.md) | [README.en](README.en.md) |
| 二级 Developer Guide | [开发者文档](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md) | [Developer Guide](docs/文档库/英文版/DEVELOPER_GUIDE.en.md) |
| 三级 Architecture | [系统架构](docs/文档库/自动驾驶与功能/01-architecture.md) | [Architecture](docs/文档库/英文版/01-architecture.en.md) |
| 三级 Network Locate | [网络定位](docs/文档库/自动驾驶与功能/02-network-locate.md) | [Network Localization](docs/文档库/英文版/02-network-locate.en.md) |
| 三级 Speed OCR | [速度识别](docs/文档库/自动驾驶与功能/03-speed-ocr.md) | [Speed Recognition](docs/文档库/英文版/03-speed-ocr.en.md) |
| 三级 Vision & Inference | [视觉与推理](docs/文档库/自动驾驶与功能/04-vision-inference.md) | [Vision & Inference](docs/文档库/英文版/04-vision-inference.en.md) |
| 三级 Control & Safety | [控制与安全](docs/文档库/自动驾驶与功能/05-control-safety.md) | [Control & Safety](docs/文档库/英文版/05-control-safety.en.md) |
| 四级 Internals | [核心实现原理](docs/文档库/自动驾驶与功能/) | [Internals](docs/文档库/英文版/) |

## 📄 许可证 / License

GPL-3.0 —— 见 [NOTICE](NOTICE)。所有原始源码带 SPDX 头。
*See [NOTICE](NOTICE) for third-party component licenses. Original sources carry SPDX headers:*

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```