<div align="center">

# AuroraDrive

**macOS 第三方《异环》(NTE) 视角自动驾驶系统**

屏幕捕获 → CoreML 推理 → 按键注入，附带网络抓包定位、速度识别（PP-OCRv6 微调 int8）与 MetalFX 显示增强

[English Documentation](README.en.md) · [开发者文档](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md) · [全文索引](docs/文档库/自动驾驶与功能/00-文档索引.md)

</div>

> ⚠️ **免责声明 / Disclaimer**：本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。
> *This project is for research and personal learning only. Automating game input may violate the game's Terms of Service. The author is not responsible for any consequences, including account suspension.*

---

## 🙏 致谢 / Acknowledgements

| 项目 / Resource | 用途 / Purpose | 许可证 / License |
|---|---|---|
| [**MaaNTE**](https://github.com/1bananachicken/MaaNTE) | 网络定位算法蓝本（UE5 移动包位流解析移植自其 `nte_coordinate_api.py`；坐标标定常量取自其 `coordinate_position.py`，与本项目 `kCalibA/B/TX/TY` 逐位一致）；全收集地图图源（MaaNTE-Map 13056×13056 扩图） | AGPL-3.0 |
| [**MetalGoose**](https://github.com/Stallion77RepoOfficial/MetalGoose) | MetalFX 超分 + 插帧引擎（`Vendor/MetalGoose`，仅作用于显示层） | GPL-3.0 |
| [**nteguide.com**](https://nteguide.com) | 全收集地图标记数据 | 经作者许可 |

> 📌 MaaNTE 源码不随本仓库分发（AGPL-3.0 传染性），仅本地参考并在上表致谢。地图资源经群主许可分发。
> *MaaNTE source code is NOT distributed with this repo (AGPL-3.0 is viral); it is credited above and kept as a local reference only.*

## ✨ 核心功能 / Features

- **端到端自动驾驶**：M9 单目模型直接从画面输出操控量，**三档降级**保底（端到端 → YOLO 接管 → 规则兜底）
- **网络抓包定位**：libpcap 捕获 UE5 移动同步包（tcp/30031），位流解码出世界坐标 + 朝向，映射到 13056×13056 大地图像素（map-2026-08，2026-09-13 升级）
- **速度识别**：PP-OCRv6 微调整行模型（`models/ppocrv6_tiny_ft_int8.mlpackage`，int8 量化，GPU 推理）为主路径，逐位 CNN（`speed_digit_cnn_v4*`）为备用，三层校验
- **系统权限安装**：App 内输入当前账户的管理员密码，通过 `sudo -S` 安装两个 root LaunchDaemon：`com.aurora.bpf-setup` 每 3 秒修正 `/dev/bpf*` 权限，`com.aurora.priority` 每 5 秒为 AuroraDrive 进程执行 `renice -20`。密码不硬编码、不落盘；详见下方安全提示
- **AI 助手（真对话 + 自主操作）**：接大模型**真对话**（流式输出，增量按 15Hz 节流；候选链最多尝试 4 个，全链失败才回退本地套话并标注「离线回复」）；助手可**自主调工具**（共 **30 个**）；操作游戏界面走**「ESC → 截图 → 鼠标点击」唯一可靠路径**。会话带**滑动窗口**（上限 200 条 ≈100 轮）
- **任务面板 OCR**：读游戏左侧任务面板文字 → 查 `models/quest_index.json` → 世界坐标目标（**默认开启**，每 0.7s 一次 Vision OCR）
- **全收集交互地图**：多图层开关（传送点/材料/宝箱/谕石），实时玩家位置 + 朝向
- **路网先验**：`models/route_graph.json` 修复版 **664 节点 / 932 边**，断头率 19.3% → 5.4%
- **MetalFX 显示增强**：超分 + 插帧，只作用于显示层，**绝不进入**「捕获→推理→按键」决策链路

<details>
<summary><b>📌 逐条代码依据（2026-10-17 重新核实，点开查看）</b></summary>

| 功能 | 依据（`文件:行号` / 命令） |
|---|---|
| **三档**降级（原写「四档含脱困」**已过期**） | 脱困档 `.recover` 于 2026-09-30 整体删除：`Sources/AuroraDrive/Agent/DegradeStateMachine.swift:5-9`；`EscapeController` 类型已删、仅留 `ControlCommand` 输出格式：`Sources/AuroraDrive/Control/EscapeController.swift:12-14`、`AuroraDriveApp.swift:4053-4055` |
| 网络定位**仍活着**（旧抓包路径已移除） | 旧 `networkLocator.start()` 已注释：`AuroraDriveApp.swift:7133`（原注释「旧网络抓包定位已移除」）；**现行** `CoordinateCapture` 懒初始化 + `cc.start()`：`AuroraDriveApp.swift:4546-4553`（注释「纯网络定位，无自愈引擎」）；libpcap 实调用 `CoordinateCapture.swift:1052`（`pcap_open_live`）；过滤器/端口 `CoordinateCapture.swift:1100`（`tcp port 30031 or udp`） |
| `NetworkLocator` **编译但零实例化** | `grep -rn "NetworkLocator(" Sources/` → **零命中**；仅 `Sources/AuroraDrive/App/LocateRuntime.swift:37` 有一个从未赋值的字段 |
| 三层校验 | `Sources/AuroraDrive/Inference/SpeedOCRReader.swift:638-653`（Layer 1 量程 / Layer 2 跳变 / Layer 3 多帧确认） |
| AI **真对话** | `Sources/AuroraDrive/Agent/AgentChatService.swift:109-115`（候选上限 4、增量 15Hz 节流）；同文件 `:22-26` 记「全链失败不抛错给 UI，回退 `localReply` 并标注『离线回复』」 |
| 自主调工具 **30 个** | `Sources/AuroraDrive/Agent/ToolRegistry.swift:16-23`（18 技能 + 4 键位 + 1 文本 + 3 鼠标 + 2 观察 + 2 搜索）；技能挂载 `:151-160`；四道护栏 `:24-34`。⚠️ **挂载 30 个 ≠ 全部可用**：`isImplemented = skill.ported`（`:158`），18 个技能里 `ported:true` 只有 **15 个**，`pinkpaw` / `rhythm` / `preset_realtime` 三个是 `false`（`AIAgentPanel.swift:104/112/124`），调用会返回 `ok=false` |
| **ESC + 鼠标**路径 | `AgentChatService.swift:340-348`（「这条路（ESC → 截图 → 鼠标点击）是本工具操作界面的**唯一可靠方式**」）；技能内 ESC 实注入 `AIAgentPanel.swift:1245`（`pressGameKey(.esc, duration: 0.05)`）；键位自检探针 `LLMSelfTest.swift:1160` |
| **滑动窗口** | `Sources/AuroraDrive/Agent/AIAgentPanel.swift:197-214`（`static let maxMessages = 200`） |
| 任务面板 **OCR** | `Sources/AuroraDrive/Inference/QuestPanelReader.swift:414-431`（`minInterval = 0.7`）；默认开启：`Sources/AuroraDrive/Core/AuroraFlags.swift:192-201`（`questOCR` 默认 `true`） |
| 路网 **664/932** | `Sources/AuroraDrive/App/AuroraDriveApp.swift:1974`（「断头 118 (19.3%) → 36 (5.4%)，节点 612→664，边 825→932」）+ `:2139-2140` 自检断言；数据文件实测 `models/route_graph.json` → `nodes:664 / edges:932` |
| 三级新鲜度（替代原「自愈式定位」） | `AuroraDriveApp.swift:4620-4626`（live ≤18s / recent ≤40s / stale ≤90s / lost >90s；`recent` 起不参与决策） |
| MetalFX 仅显示层 | `Sources/AuroraDrive/Capture/CaptureEngine.swift:128-130`（「MetalGoose 引擎需要完整帧做时域插帧/空间超分，走独立回调不干扰主路径」）；`AuroraDriveApp.swift:6037-6040`（「插帧/超分直通：全分辨率帧 → MetalGoose 引擎（仅显示路径）」） |

</details>

> ⚠️ **2026-10-07 删除条目说明**：原第 5 条「**自愈式定位**：网络失效 → 视觉模板匹配顶班 → 后台 8 种诊断 + 自动修复 → 自动切回」**已整条删除** ——
> 自愈引擎 `NetworkHealer` 已随 commit 76e9027 退役；`VisualLocator` 类型虽存在（`Sources/AuroraDrive/Locate/VisualLocator.swift:27`）但**从未被实例化**（`grep -rn "VisualLocator(" Sources/` 零命中，`LocateRuntime.swift:30` 的字段始终为 `nil`）；
> 「8 种诊断 + 自动修复」在源码中**无对应实现**。按「不许编造功能」原则，不保留无法核实的宣传。
> **现行做法**：网络定位 + **三级新鲜度**，陈旧只如实标注、不闪断，且 `recent` 起不再参与决策（更保守）。

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

**系统权限（网络定位必需）**：首次安装时在 App 内输入**当前 macOS 管理员密码**（没有默认密码）。密码只经 `sudo -S` 的标准输入传给系统，不写入参数、文件或日志。安装会创建 `com.aurora.bpf-setup` 与 `com.aurora.priority` 两个 root LaunchDaemon；它们会在开机后常驻运行。

> ⚠️ **安全边界**：BPF 守护会把 `/dev/bpf*` 设置为 `0666`，即本机所有用户进程均可读写抓包设备；性能守护会周期性把 AuroraDrive 调整到 `nice -20`。这是功能设计，不是临时测试行为。多用户或高安全要求的机器请先阅读 [`bpf-daemon.md`](docs/文档库/自动驾驶与功能/bpf-daemon.md)，确认风险后再安装。

## 🏗️ 架构 / Architecture

```
┌─ UI 进程 ─────────────┐    共享内存 v3     ┌─ 引擎进程 ──────────────────────┐
│ SwiftUI 控制台/地图    │ ← /aurora_frame_v1 → │ ScreenCaptureKit 15fps          │
│ 检测框/掩码/状态显示   │   帧、检测、掩码、心跳 │ E2E + YOLOPX + OCR（tick 15Hz） │
│ MetalFX 超分+插帧      │                    │ 三档降级 e2e/yolo/rule          │
└───────────────────────┘                    │ CGEvent 键鼠注入                 │
                                             └──────────────┬───────────────────┘
                                                            │
                                      libpcap tcp/30031 → 世界坐标/朝向
```

> 📌 **当前频率口径（2026-11-08 按源码复核）**：正常状态下 tick（推理+控制+录制）为 **15Hz**，抓屏为 **15fps**；应急冲刺为 **20Hz/20fps**。权威值见 `EngineMain.engineTickHz`、`tickHz(forPerceptionMode:)`、`captureHz(forPerceptionMode:)`、`CaptureEngine._targetCaptureHz` 与 `RecordEngine.targetFps`。历史文档中的 20Hz、30Hz、45Hz 若没有明确标成历史，均不代表当前默认值。

**架构红线**：插帧/超分只作用于显示叠加层，绝不进入决策链路。
*Frame interpolation / upscaling ONLY applies to the display overlay — never to the capture → inference → key-injection decision path.*

### 当前架构补充

上图已更新为当前的双进程形态。更细的源码级说明以 `docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md` 为准。

| 支柱 | 说明 | 当前定位 |
|---|---|---|
| **① 双进程 + 共享内存 v3** | UI 与引擎是两个长驻进程，经 `/aurora_frame_v1` 共享内存（约 72MB）传帧与检测；`EngineClient.protocolVersion = 3` | 当前主架构 |
| **② YOLOPX 三合一感知** | `YolopxEngine`：一个模型同时输出 `det`（检测）/ `da`（可行驶区）/ `ll`（车道线）。正常 tick 当前为 15Hz，具体门控以 `EngineMain` 和 `YolopxEngine` 源码为准 | 核心感知资产 |
| **③ 光流 + 运动预测** | OpenCV DIS 光流（`Vendor/OpenCVFlow`，≤5ms 红线）在模型未产生新检测的 tick 上做 α-β 滤波外推；不要再用旧文档的“补成 20/30Hz”固定口径描述 | 帧间补偿 |
| **④ 掩码可视化** | 可行驶区/车道线掩码经共享内存传回 UI 叠加显示（bit-pack，160×160 网格） | 显示与诊断 |

> 目标检测主路径是 **YOLOPX 的 `det` 头**；`yolo26s` 主要用于预测侧。详见 [`代码-14-YoloEngine目标检测.md`](docs/文档库/自动驾驶与功能/代码-14-YoloEngine目标检测.md) 与 [`代码-13-InferenceEngine端到端推理.md`](docs/文档库/自动驾驶与功能/代码-13-InferenceEngine端到端推理.md)。

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

> ⚠️ **2026-10-19 断链修复说明（第二次）**：下方「三级」一栏原指向 `历史归档/05-自动驾驶与功能-早期稿/` 下的 `01-architecture.md`～`05-control-safety.md`，以及 `docs/文档库/英文版/` 下的对应 `.en.md`。**这两处目录已于 2026-10-17/18 的文档清理中整体删除**（`ls` 实测：`docs/文档库/英文版/` → No such file or directory；`find . -name '01-architecture.md'` 全仓 0 命中；`.backups/` 内亦无备份可恢复）。因早期稿与英文版均已无现存文件，**按「删死链 + 留说明」处理**，不再改指新路径。
> **当前权威正文是 `代码-XX` 系列**（`代码-00` 是导航页），英文内容见 [README.en.md](README.en.md)。

| 层级 | 中文 | English |
|---|---|---|
| 入口 Overview | [README（本页）](README.md) | [README.en](README.en.md) |
| 二级 Developer Guide | [开发者文档](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md) | —（英文版已停更，见 [README.en.md](README.en.md)） |
| 三级早期稿（Architecture / Network Locate / Speed OCR / Vision & Inference / Control & Safety） | —（`01-architecture`～`05-control-safety` 早期稿已随 2026-10-17 清理删除；相应内容已并入 `代码-04` / `代码-12` / `代码-13` / `代码-14` / `代码-20`） | —（英文版已随清理删除） |
| 四级 Internals（现行） | [核心实现原理：代码-00 源码树与架构总览](docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md) · [全文索引](docs/文档库/自动驾驶与功能/00-文档索引.md) | —（英文版已停更，见 [README.en.md](README.en.md)） |

**现行分模块文档（`代码-00`~`代码-39`，共 40 篇）**：按子系统一一对应源码，含 `文件:行号` 级引用，**与当前代码同步维护**。常用入口：

| 主题 | 文档 |
|---|---|
| 源码树 / 架构总览 | [代码-00-源码树与架构总览](docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md) |
| 网络坐标采集 | [代码-04-CoordinateCapture网络坐标采集](docs/文档库/自动驾驶与功能/代码-04-CoordinateCapture网络坐标采集.md) |
| 速度 OCR | [代码-12-SpeedOCRReader高速OCR](docs/文档库/自动驾驶与功能/代码-12-SpeedOCRReader高速OCR.md) |
| 降级状态机（三档） | [代码-20-DegradeStateMachine降级状态机](docs/文档库/自动驾驶与功能/代码-20-DegradeStateMachine降级状态机.md) |
| AI 助手面板 | [代码-23-AIAgentPanel与18技能](docs/文档库/自动驾驶与功能/代码-23-AIAgentPanel与17技能.md) |
| 进程间通信 | [代码-07-EngineClient进程间通信](docs/文档库/自动驾驶与功能/代码-07-EngineClient进程间通信.md) |
| 路网先验 | [代码-36-RoadMapPrior路网先验](docs/文档库/自动驾驶与功能/代码-36-RoadMapPrior路网先验.md) |
| BPF 权限与 LaunchDaemon | [bpf-daemon](docs/文档库/自动驾驶与功能/bpf-daemon.md) |

## 📄 许可证 / License

GPL-3.0 —— 见 [NOTICE](NOTICE)。所有原始源码带 SPDX 头。
*See [NOTICE](NOTICE) for third-party component licenses. Original sources carry SPDX headers:*

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```
