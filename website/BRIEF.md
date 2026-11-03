# AuroraDrive 官网内容事实简报（唯一事实来源）

> 铁律：官网所有数字、功能名、技术描述 **只能** 引用本文件。本文件每一条都已在源码核实（含 `文件:行号`）。
> 若本文件没有的表述 = 不可写进官网。

## 一、项目定位（一句话）

AuroraDrive 是一个运行在 macOS 上的**第三方《异环》(NTE) 视角自动驾驶系统**：把游戏画面实时截屏送给端到端神经网络，
推理出转向/油门/刹车，再以真实按键事件注入游戏，外加网络抓包定位、速度 OCR 与 MetalFX 显示增强。

**它不是**：一个通用自动驾驶 SDK、不是一个网页应用、不是一个游戏本体。
**它是**：一个「看得见 → 想得出 → 按得下」的三段式闭环桌面系统。

### 目标用户（三类，官网需分别说服）
1. **《异环》玩家** —— 想让 AI 帮忙跑图/做日常任务，解放双手（这是第一受众，网站要照顾他们的"能不能替我开车"焦虑）。
2. **端到端自动驾驶研究者** —— 想看一套「小模型端到端 + 大模型接管 + 规则兜底」三档梯子的真机实现。
3. **macOS / 视觉工程开发者** —— 想看 CoreML + ScreenCaptureKit + libpcap + MetalFX 如何拼成一个实时系统。

## 二、硬核功能（每条附代码依据）

### 1. 三档降级状态机（最有说服力的架构点）
- 档位：**端到端主驾(E2E / M9 单目模型) → YOLO 接管 → 纯规则兜底**。
- 「脱困档」已于 2026-09-30 整体删除，**不要再宣传第四档**。
  依据：`Sources/AuroraDrive/Agent/DegradeStateMachine.swift:5-9`
- 设计原则（可直接写进官网）：单调降级 + 滞回恢复（`degradeHealth = 0.65`，`recoverHysteresis = 0.15`，防阈值抖动反复横跳）；
  降级阈值 UI 可实时调。
  依据：`DegradeStateMachine.swift:31-38`
- **对普通用户的话术**：模型不靠谱时系统会自己退到更笨但更稳的规则档，而不是直接失控。

### 2. YOLOPX 三合一感知模型（核心资产）
- 一个模型同时输出三个头：`det`(目标检测) / `da`(可行驶区域) / `ll`(车道线)。
- 频率随档位：`ayolom` 档每 tick 都跑；`legacy` 档偶数帧跑。
- ⚠️ 官网表述为「**一个模型、三个任务**」，不要说成三个模型。
- 依据：`Sources/AuroraDrive/Inference/YolopxEngine.swift`

### 3. 双进程 + 共享内存 v3
- UI 进程与引擎进程是两个长驻进程，经 `/aurora_frame_v1` 共享内存传帧与检测数据。
- `EngineClient.protocolVersion = 3`；布局变更（`pixelsOffset` 20480 → 28672）会做协议版本校验，
  不匹配则明确报错而非静默错位。
- 依据：`Sources/AuroraDrive/Core/EngineClient.swift:61-65`、`:281-298`
- **对用户的话术**：UI 卡了不影响引擎干活，反之亦然。

### 4. 光流补帧（把 10Hz 检测补成 20Hz 级的连续性）
- 主力是 **OpenCV DIS 光流**（ULTRAFAST 预设），通过 `Vendor/OpenCVFlow` 的 C++ 桥接入 Swift。
- 本机 640×640 实测（ABBA 交错同批）：
  - OpenCV DISOpticalFlow ULTRAFAST **1.91ms** ✓
  - 同上仅单核（极端工况）3.78ms ✓
  - Apple VTOpticalFlow（VideoToolbox 硬件）10.28ms ✗
  - Vision `VNGenerateOpticalFlow` 27.43ms ✗
- 用户红线「光流 ≤5ms」，当前实现在红线内。
  依据：`Sources/AuroraDrive/Inference/OpticalFlowBridge.swift:6-19`、`:88-93`
- **对用户的话术**：官方硬件光流反而慢 5~14 倍，所以项目自己接了 OpenCV。这是"实测选型"的证据，不是堆料。

### 5. 网络坐标定位（世界坐标 + 朝向）
- libpcap 抓 UE5 移动同步包，过滤器 `tcp port 30031 or udp`，解码位流得到世界坐标与朝向。
- 映射到 **13056×13056** 大地图像素空间。
- 依据：`Sources/AuroraDrive/Capture/CoordinateCapture.swift:1052`、`:1100`；
  `Sources/AuroraDrive/App/MapLayers.swift:18-20`；`AuroraDriveApp.swift:1504`
- ⚠️ 「自愈式定位」（网络失效→视觉模板匹配顶班→自动诊断修复）**已于 2026-10-07 整条删除**，
  `VisualLocator` 类型存在但从未被实例化。**官网不得宣传自愈/视觉模板匹配定位。**
- 现行做法：网络定位 + **三级新鲜度**（live ≤18s / recent ≤40s / stale ≤90s / lost >90s），
  `recent` 起不再参与决策（更保守），陈旧只如实标注、不闪断。
  依据：`AuroraDriveApp.swift:4620-4626`

### 6. 速度识别（三层校验）
- 主路径：**PP-OCRv6 微调整行模型**（`models/ppocrv6_tiny_ft_int8.mlpackage`，int8 量化，GPU 推理）。
- 备用：**逐位 CNN**（`speed_digit_cnn_v4*`）。
- 三层校验：Layer 1 量程 / Layer 2 跳变 / Layer 3 多帧确认。
  依据：`Sources/AuroraDrive/Inference/SpeedOCRReader.swift:638-653`

### 7. AI 助手：真对话 + 自主调工具（30 个）
- 真·大模型流式对话，增量按 **15Hz** 节流；候选链最多尝试 **4** 个，全链失败才回退本地套话并标注「离线回复」。
  依据：`Sources/AuroraDrive/Agent/AgentChatService.swift:109-115`、`:22-26`
- **30 个工具**（18 技能 + 4 键位 + 1 文本 + 3 鼠标 + 2 观察 + 2 搜索），注册表 `ToolRegistry` 是唯一清单与执行入口。
  依据：`Sources/AuroraDrive/Agent/ToolRegistry.swift:16-23`
- ⚠️ 诚实边界：30 个是**挂载数**，其中 18 个技能里 `ported: true` 只有 **15** 个，
  `pinkpaw` / `rhythm` / `preset_realtime` 三个尚未移植，调用会返回 `ok=false`。
  依据：`ToolRegistry.swift:151-160`；`AIAgentPanel.swift:104/112/124`
  → 官网写「30 个工具，15 个技能已实装」，不要写「30 个技能全部可用」。
- 操作游戏界面的**唯一可靠路径**：ESC → 截图 → 鼠标点击。
  依据：`AgentChatService.swift:340-348`
- 会话滑动窗口上限 **200 条**（≈100 轮）。依据：`AIAgentPanel.swift:197-214`
- **四道护栏**（全部「明确报错、不静默」）：观测模式 `AURORA_OBSERVE_ONLY` 拒绝一切注入 / 游戏不可见拒绝 /
  辅助功能未授权拒绝 / dryRun 不注入但返回结构完整结果。
  依据：`ToolRegistry.swift:24-34`

### 8. 全收集交互地图 + 路网先验
- 地图多图层开关（传送点 / 材料 / 宝箱 / 谕石）+ 实时玩家位置与朝向。
- 路网先验 `models/route_graph.json`：**664 节点 / 932 边**，断头率 **19.3% → 5.4%**（612→664 节点，825→932 边）。
  依据：`AuroraDriveApp.swift:2135`、`:2139-2140`；实测 `route_graph.json` → nodes:664 / edges:932

### 9. 任务面板 OCR
- 读游戏左侧任务面板文字 → 查 `models/quest_index.json` → 世界坐标目标；默认开启，每 **0.7s** 一次 Vision OCR。
  依据：`Sources/AuroraDrive/Inference/QuestPanelReader.swift:414-431`；`Sources/AuroraDrive/Core/AuroraFlags.swift:192-201`

### 10. BPF 权限自动安装
- 首次启动 App 内输入一次管理员密码，自动安装 `com.aurora.bpf-setup` LaunchDaemon，之后每次开机自动恢复 `/dev/bpf*` 读写权。
  （README 提到默认密码 `123456` —— **官网不要写默认密码**，只写"一次输入，永久生效"。）

### 11. MetalFX 超分 + 插帧 —— 只作用于显示层（架构红线）
- MetalGoose 引擎（`Vendor/MetalGoose`，GPL-3.0）提供 MetalFX 空间超分 + 时域插帧。
- **铁律：绝不进入「捕获 → 推理 → 按键注入」决策链路**，只做人眼观看的叠加层。
  依据：`Sources/AuroraDrive/Capture/CaptureEngine.swift:128-130`；`AuroraDriveApp.swift:6037-6040`
- **对用户的话术**：为了画面更顺滑而给决策链路加延迟，等于让车反应变慢——所以我们不这么干。
  这是可以正面讲的技术价值观，官网值得单独成段。

### 12. 掩码可视化
- 可行驶区 / 车道线掩码经共享内存传回 UI 叠加显示（bit-pack，160×160 网格）。

## 三、真实性能数字（可用作数据统计区，全部有据）

| 指标 | 数值 | 依据 |
|---|---|---|
| 推理 tick 频率 | **15Hz**（两档一致） | `EngineMain.swift:771`、`tickHz` `:868-878` |
| 抓屏帧率 | **15fps**（两档一致） | `captureHz` `:879-885` |
| 应急冲刺时 | 两者一起提到 **20** | `EngineMain.swift` sprint 联动 |
| OpenCV DIS 光流 | **1.91ms**（p95, 全核） | `OpticalFlowBridge.swift:88` |
| 光流单核退化 | **3.78ms** | 同上 |
| 官方硬件光流对照 | VT 10.28ms / Vision 27.43ms | `OpticalFlowBridge.swift:16-18` |
| YOLOPX 单次推理 | 约 **60ms**（148 GFLOPs，ANE 峰值 9.26 TFLOPS，效率约 26%） | `OpticalFlowBridge.swift:6-7` |
| 路网节点 / 边 | **664 / 932** | `route_graph.json` 实测 |
| 断头率优化 | **19.3% → 5.4%** | `AuroraDriveApp.swift:2135` |
| 地球图分辨率 | **13056×13056** 像素 | `AuroraDriveApp.swift:1504` |
| 共享内存协议版本 | **v3** | `EngineClient.swift:65` |
| AI 工具挂载数 | **30**（15 个技能已实装） | `ToolRegistry.swift:16-23`、`:158` |
| 源码规模 | 74 个 Swift 文件 / **67,720 行** | `wc -l Sources` |
| 架构文档 | `代码-00`~`代码-39` 共 **40 篇**，`文件:行号` 级引用 | `docs/文档库/自动驾驶与功能/` |

> ⚠️ **频率口径纠错**：README 写「20Hz/20fps」，那是 2026-10-18 前的旧值；
> 现行代码已定档 **15Hz/15fps**（2026-10-22 全链路定档），历史沿革 45 → 30 → 20 → 15。
> **官网一律写 15Hz/15fps**，并在 sprint 场景提 20。

## 四、技术栈（真实清单）

- 语言/框架：**Swift 6（语言模式 v5）+ SwiftUI**，macOS 26+，Apple Silicon，Swift Package Manager
- 视觉推理：**CoreML**（端到端 M9 单目模型 / YOLOPX 三合一 / PP-OCRv6 int8 / 逐位 CNN）
- 采集：**ScreenCaptureKit**（CVPixelBuffer 流）
- 注入：**CGEvent**（键位 / 文本 / 鼠标）、**AXIsProcessTrusted** 辅助功能鉴权
- 网络：**libpcap**（tcp/30031）、NetworkExtension
- 光流：**OpenCV DIS**（自建 C++ 桥，`Vendor/OpenCVFlow`）
- 显示增强：**MetalFX**（MetalGoose，Metal 管线）
- 加速：**ANE / Metal**，YOLO 走 GPU 直通
- 权限自动化：**BPF + LaunchDaemon**
- 统计路线图：**664 节点 / 932 边** 有向图 + 大地图像素空间

## 五、第三方依赖与开源合规（官网需单列"致谢"区块）

| 项目 | 用途 | 许可证 |
|---|---|---|
| MaaNTE | 网络定位算法蓝本（UE5 移动包位流解析、坐标标定）+ 全收集地图图源 | **AGPL-3.0** |
| MetalGoose | MetalFX 超分 + 插帧引擎（`Vendor/MetalGoose`） | **GPL-3.0** |
| nteguide.com | 全收集地图标记数据 | 经作者许可 |

- 本项目自身：**GPL-3.0-or-later**，所有原始源码带 SPDX 头。
  `SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty`
- ⚠️ MaaNTE 源码**不随本仓库分发**（AGPL-3.0 传染性），仅本地参考并在致谢中标注。
- 依据：`README.md` 致谢表、`NOTICE`

## 六、免责声明（官网页脚 + Hero 角标必须出现）

> 本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，
> 作者不对封号或其他任何后果负责，请自行评估风险。

## 七、Quick Start（官网代码块内容，逐字照抄）

环境要求：macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap（系统自带）

```sh
git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # 编译 + 签名 + 启动
./run.sh --status   # 只检查环境
```

系统权限：屏幕录制 + 辅助功能（系统设置 → 隐私与安全）

## 八、写作红线

1. **不写空泛套话**（"强大的"、"行业领先"、"赋能"）——每个卖点后面跟一个可验证的数字或机制。
2. **不宣传已删除的功能**：自愈式定位、视觉模板匹配定位、脱困第四档、"规则共驾"档、20Hz/20fps。
3. **不承诺未实装**：18 个技能里只有 15 个已实装；30 是挂载数不是可用数。
4. **不隐藏合规**：GPL-3.0 + AGPL 传染性说明必须写出来，这是专业度的证明而不是减分项。
5. **AI 助手的操作边界**（ESC→截图→鼠标点击）可以写，它是可靠性设计而非缺陷。
6. 数字统一用**千分位**，帧率写 Hz/fps，延迟写 ms。
