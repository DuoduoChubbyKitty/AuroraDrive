# AuroraDrive

macOS 上的《异环》(NTE) 视角自动驾驶系统。

屏幕捕获 → CoreML 推理 → 按键注入，配合网络抓包定位与视觉小地图定位双路方案，实现游戏内角色的自动驾驶、导航跟随与驾驶质量评分。

> ⚠️ **免责声明**：本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。

---

## 致谢

| 项目 | 用途 | 许可证 |
|---|---|---|
| [MaaNTE](https://github.com/1bananachicken/MaaNTE) | 网络定位算法蓝本（UE5 移动包位流解析与坐标标定常量均取自其实现）；全收集地图图源（13056×13056） | AGPL-3.0 |
| [MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose) | MetalFX 超分 + 插帧引擎（仅作用于显示层） | GPL-3.0 |
| [nteguide.com](https://nteguide.com) | 全收集地图标记数据 | 经作者许可 |

MaaNTE 源码不随本仓库分发（AGPL-3.0 传染性），仅作本地参考。

## 功能

### 自动驾驶

- **端到端驾驶**：V3 单目模型直接从画面输出垂直/水平驾驶决策
- **三档降级**：端到端 → YOLO 接管 → 规则兜底，任一档失效自动下沉
- **控制器**：把决策量转成鼠标/键盘事件注入游戏，支持速度上限、档位锁定、紧急刹停
- **壳模式**：UI 进程内自带 RL 训练引擎，可脱离游戏自跑训练（独立开关，默认关闭）

### 定位

- **网络定位**：libpcap 捕获 UE5 移动同步包（`tcp/30031 or udp`），位流解码出世界坐标与朝向，映射到 13056×13056 大地图。精度高于视觉定位
- **视觉定位**：从小地图截图做模板匹配，在 13056×13056 底图上求位置。云端游戏没有可解的移动包，这是云端唯一可用的定位路径
- **定位决策**：根据游戏源（云端 / 本地 / 未知）自动选择定位模式
- **故障兜底**：网络定位持续失效且画面仍在推进时，自动切视觉定位接管；网络恢复后切回。`stale` 状态不算故障（游戏坐标包本身有间隔）
- **自动标定**：小地图 ROI 通过圆形检测多帧收敛自动标定，无需手填坐标；检测失败超时后回退默认 ROI

### 导航跟随

- **引导线识别**：从游戏小地图提取黄色引导线，输出车到线的最近距离、线的走向、远端延伸方向
- **方向判定**：用世界坐标位移方向与引导线走向比对，夹角过大判为偏离；逆向行驶单独判错
- **像素距离判据**：车到引导线的最近距离作为辅助兜底，判定「完全脱离路线」
- **路线重规划识别**：距离突变的帧视为引导线重画，重置基线，不误判为开错路
- **地图覆盖层**：引导线实时绘制到大地图与自有小地图上，用小地图实测跨度换算世界坐标

### 感知

- **YOLOPX 三合一**：单模型同时输出检测（det）/ 可行驶区（da）/ 车道线（ll）
- **光流外推**：模型未产生新检测的 tick 上用 DIS 光流做帧间补偿
- **车道线处理**：车道线掩码提取、光流外推、车道保持
- **朝向读取**：从小地图指针箭头读取车头朝向与置信度

### 速度与任务

- **速度识别**：PP-OCRv6 微调整行模型为主路径，逐位 CNN 为备用，单帧直读，三层校验（量程 / 跳变 / 多帧）
- **任务面板 OCR**：读游戏左侧任务面板文字，查索引表得到世界坐标目标
- **路网先验**：`models/route_graph.json` 路网图，用于路线规划与转向预判

### 显示与界面

- **MetalFX 显示增强**：超分 + 插帧，只作用于显示层，不进入决策链路
- **全收集地图**：多图层开关（传送点 / 材料 / 宝箱 / 谕石），实时玩家位置与朝向
- **常驻悬浮小地图**：应用启动即显示，独立于主地图视图
- **AI 助手**：接大模型真对话（流式输出），可自主调用工具操作游戏界面

## 快速开始

**环境要求**：macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap（系统自带）

```sh
git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # 编译 + 签名 + 启动
./run.sh --status   # 只检查环境，不启动
```

**系统权限**：屏幕录制 + 辅助功能（系统设置 → 隐私与安全）

**网络定位所需权限**：首次安装时在 App 内输入当前 macOS 管理员密码（无默认密码）。密码只经 `sudo -S` 标准输入传给系统，不写入参数、文件或日志。安装会创建两个 root LaunchDaemon：

- `com.aurora.bpf-setup`：每 3 秒修正 `/dev/bpf*` 权限
- `com.aurora.priority`：每 5 秒对 AuroraDrive 执行 `renice -20`

> ⚠️ **安全边界**：BPF 守护会把 `/dev/bpf*` 设为 `0666`，即本机所有用户进程均可读写抓包设备；性能守护会周期性把 AuroraDrive 提到 `nice -20`。这是功能设计。多用户或高安全要求的机器请先阅读 [`bpf-daemon.md`](docs/文档库/自动驾驶与功能/bpf-daemon.md)。

## 架构

双进程 + 共享内存：

```
┌─ UI 进程 ─────────────┐    共享内存      ┌─ 引擎进程 ──────────────────┐
│ SwiftUI 控制台 / 地图   │ ← /aurora_frame_v1 → │ ScreenCaptureKit 抓屏        │
│ 检测框 / 掩码 / 状态    │   帧、检测、掩码、心跳 │ V3 + YOLOPX + OCR（tick）    │
│ MetalFX 超分 + 插帧     │                    │ 三档降级                     │
└──────────────────────┘                    │ CGEvent 键鼠注入              │
                                             └──────────┬──────────────────┘
                                                        │
                                  libpcap tcp/30031 → 世界坐标 / 朝向
```

**架构红线**：插帧 / 超分只作用于显示叠加层，绝不进入决策链路。

**频率**：正常状态 tick（推理 + 控制 + 录制）15Hz、抓屏 15fps；应急冲刺 20Hz / 20fps。权威值见 `EngineMain.engineTickHz` 与对应的 `tickHz` / `captureHz` 映射。

| 支柱 | 说明 |
|---|---|
| 双进程 + 共享内存 | UI 与引擎为两个长驻进程，经 `/aurora_frame_v1` 共享内存传帧与检测；`EngineClient.protocolVersion = 8` |
| YOLOPX 三合一感知 | 一个模型同时输出检测 / 可行驶区 / 车道线 |
| 光流 + 运动预测 | OpenCV DIS 光流在无新检测的 tick 上做 α-β 滤波外推 |
| 掩码可视化 | 可行驶区 / 车道线掩码经共享内存回到 UI 叠加显示（160×160 网格 bit-pack） |

## 目录结构

```
Sources/AuroraDrive/
├── Agent/         AI 助手、工具注册表、降级状态机
├── App/           应用主体、DriveState、地图与界面
├── Capture/       屏幕捕获、录制、网络坐标采集
├── Control/       按键注入、控制器
├── Core/          进程主体、引擎主循环、进程间通信
├── Inference/     模型推理、速度 OCR、任务 OCR、朝向读取
├── Locate/        视觉定位、网络定位、定位决策与故障兜底
├── Perception/    车道线、光流
└── RL/            在线训练、策略头、壳模式
Vendor/
├── OpenCVFlow/    OpenCV C 桥（光流、地图定位、引导线扫描）
└── opencv/        OpenCV 静态库
```

## 命令行

```sh
./AuroraDriveUI              # 启动 GUI
./AuroraDriveUI --engine     # 以引擎进程身份启动
./run.sh --status            # 环境检查
```

主要自检入口：

```sh
./AuroraDriveUI --maploc-selftest        # 视觉定位
./AuroraDriveUI --guideline-selftest     # 引导线识别与方向判定
./AuroraDriveUI --guideline-replay       # 引导线离线回放（可指定片段）
./AuroraDriveUI --failover-selftest      # 网络定位故障兜底状态机
./AuroraDriveUI --positioning-selftest   # 定位模式决策
./AuroraDriveUI --rl-core-selftest       # RL 核心
./AuroraDriveUI --capture-selftest       # 采集链路
./AuroraDriveUI --llm-selftest           # AI 助手
```

完整参数列表见 [`代码-33-进程模式与CLI参数全解.md`](docs/文档库/自动驾驶与功能/代码-33-进程模式与CLI参数全解.md)。

## 文档

- [开发者文档](docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md)
- [全文索引](docs/文档库/自动驾驶与功能/00-文档索引.md)
- [源码树与架构总览](docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md)
- [人机共驾与 RL 训练管线](docs/v3-design/06-人机共驾与RL训练管线.md)

分模块文档按子系统一一对应源码，含 `文件:行号` 级引用。

## 许可证

GPL-3.0 —— 见 [NOTICE](NOTICE)。第三方组件许可见同文件。

```
SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
SPDX-License-Identifier: GPL-3.0-or-later
```