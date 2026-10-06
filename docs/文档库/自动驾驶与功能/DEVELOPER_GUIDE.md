# AuroraDrive 开发者文档（中文 / Chinese）

> 本文是全部开发文档的**总入口（二级）**。每章对应一个独立的三级文档；要看最深实现细节，进入四级《核心实现原理》。English version: [DEVELOPER_GUIDE.en.md](../英文版/DEVELOPER_GUIDE.en.md)
>
> **真实性约定**：所有文档描述的常量、函数名、流程均直接取自仓库源码（标注 `文件:行号`），与代码零偏差。与注释冲突时以代码为准（已知的注释-实现不一致在文档中如实标注）。

---

## ⚠️ 2026-10-07 复核（D3）：本文多处已过期，先读这一节

> **复核方法**：逐条命令实测（`wc -l` / `find` / 读源码行）。数字口径以
> 《代码-00-源码树与架构总览》文首「2026-10-07 全量复核」为**唯一权威**。

### 0-A 规模：**68 个 `.swift` / 57,127 行**（旧文按 41 文件 / 26,440 行写）

`find Sources -name "*.swift" | wc -l` = **68**；`find Sources -name "*.swift" -exec wc -l {} +` = **57,127**。
`Sources/AuroraDrive/Agent/` 实测 **16 文件 / 15,115 行**（旧文目录表只列到 2 个 Agent 文件）。
**本文下方「目录（三级菜单）」表里的行数全部是 9 月快照，请勿引用。**

### 0-B 8 个新增 AI 文件（旧文完全未列，新人第一天就会撞上）

| 文件 | 实测行数 | 一句话职责 |
|---|---|---|
| `Agent/AgentSettings.swift` | **262** | AI 配置：8 个 `LLMBackendKind` case（7 提供方 + 自定义），**不含任何 API Key**（`:15-18`） |
| `Agent/AgentChatService.swift` | **618** | 聊天粘合 `actor`（`:97`）；候选链最多试 4 个（`:111`）、增量 15Hz 节流（`:118`） |
| `Agent/LLMBackend.swift` | **884** | 渠道描述符 / `makeRequest` / 模型能力表；不发请求、不监控健康（`:8-13`） |
| `Agent/LLMTransport.swift` | **1,580** | SSE 流式解析 + 12 类错误分类 + 图片编码（1568px / JPEG 0.8）；解析是纯函数（`:19-22`） |
| `Agent/LLMHealth.swift` | **1,791** | 健康监控 + 降级候选链（W3）：7 态 `ModelHealth`（`:38`）、`candidates()`（`:840`） |
| `Agent/ToolRegistry.swift` | **1,065** | **30 个工具**唯一清单 + 执行入口（`:151-290`）+ 四道护栏（`:24-34`） |
| `Agent/WebSearch.swift` | **1,463** | 联网搜索/抓取只读工具：DDG Lite → DDG HTML → Wikipedia；失败必抛错不编造（`:36-37`） |
| `Agent/LLMSelfTest.swift` | **2,183** | CLI 自检 W8：7 个自检入口（`:93/961/996/1087/1360/1635/1797`），返回失败项数 |

### 0-C 构建命令已变（**新人最容易踩的一条**）

旧文写「`swift build`」。**现在并发构建会互相打断**（SwiftPM 全模块编译），必须走原子锁：

```bash
bash scripts/build-lock.sh acquire "原因" || exit 3   # 拿不到 → 退出码 3
trap 'bash scripts/build-lock.sh release' EXIT
# …构建/基准/自检…
```

- `scripts/build-lock.sh`（**146 行**，实测）用 `mkdir` 做原子锁（bash 3.2 无 flock，`:30`）
- 基准测量**也必须持锁**：3 个 agent 同时跑会让 loadavg 冲到 5.15/8 核，**任何耗时数字都不可比**（`:14-17`）
- 残留锁**只提示不自动删**（`:32-33`，`STALE_MIN=15` 分钟）
- 一键构建+部署仍用 `./run.sh`（**182 行**，实测）：`swift build -c release --disable-sandbox --scratch-path .build/scratch`（`run.sh:85`）

---

## 目录（三级菜单）

| 章 | 文档 | 覆盖源码（Sources/AuroraDrive/） |
|---|---|---|
| 一 | [系统架构总览](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/01-architecture.md) | `AuroraDriveApp.swift`(**实测 8,456 行**，旧记 4379) `DegradeStateMachine.swift`(**实测 165**，旧记 250) |
| 二 | [网络定位子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md) | `CoordinateCapture.swift`(**实测 1,752**，旧记 635) ~~`NetworkHealer.swift`~~（76e9027 已删，自愈引擎退役） `VisualLocator.swift`(491 ✅) ~~`MinimapLocatorView.swift`~~ ~~`MinimapTileCache.swift`~~<br>⚠️ **2026-10-07 实测：`Locate/` 目录只剩 2 个文件（NetworkLocator + VisualLocator），`MinimapTileCache.swift` 已被删除**——本行旧列的两个文件**均不存在** |
| 三 | [速度识别子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md) | `SpeedOCRReader.swift`(**实测 1,540**，旧记 1243，PP-OCRv6 主 / CNN 备双引擎) |
| 四 | [视觉与推理子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md) | `CaptureEngine.swift`(654 ✅) `InferenceEngine.swift`(522) `YoloEngine.swift`(**实测 843**，旧记 818) `ConfidenceEstimator.swift`(248 ✅) `RecordEngine.swift`(424 ✅) `YolopxEngine.swift`(**实测 1,666**，旧记 1124) `OpticalFlowBridge.swift`(384 ✅) `MotionPredictor.swift`(**实测 569**，旧记 384) `FallbackGuard.swift`(280 ✅)<br>⚠️ 本行**缺 4 个新文件**：`QuestPanelReader.swift`(1,160) `RoadCornerGuide.swift`(757) `RoadMapPrior.swift`(360) `EgoMotionModel.swift`(358) `LaneKeepRealityTest.swift`(228) |
| 五 | [控制与安全子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/05-control-safety.md) | `ControlEngine.swift`(**实测 649**，旧记 373) `KeyboardMonitor.swift`(113 ✅) `RuleController.swift`(**实测 200**，旧记 187) `EscapeController.swift`(**实测 44**，旧记 217——2026-10 已大幅瘦身) |
| 六 | [常见问题 FAQ](#六常见问题-faq) | — |
| 七 | [2026-09-19 磁盘清理说明](#七2026-09-19-磁盘清理说明) | 迁移路径对照 + MaaNTE 侧现状速记 |
| **八** | **🆕 [构建 / 部署 / 自检 / 踩坑](#五点五构建--部署--自检--踩坑2026-10-07-实测补写--新人实操章)（本文 5.5 节）** | `scripts/build-lock.sh`(146) `run.sh`(182) `Package.swift`(212) |

### 四级深入文档（核心实现原理）

| 文档 | 揭示内容 |
|---|---|
| [UE5 移动包位流逐字段解析](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/ue5-bitstream.md) | 位读取原语 / 向量块 / 旋转块 / 扫描定位 |
| [坐标标定常量推导](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/coordinate-calibration.md) | kCalibA/B/TX/TY 仿射变换与东北向量 |
| [BPF 权限与 LaunchDaemon](bpf-daemon.md) | App 内密码 → osascript → 开机自启全链路 |
| [App Nap 对抗机制](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/app-nap.md) | 六重锁：禁终止/beginActivity/-20/EventTap/768MB mlock/实时约束 |
| [踩坑实录](pitfalls.md) | PAC 崩溃 / 无符号下溢 / 网卡抓错 / CoreML 编译 等真实事故 |

---

## 一、系统架构总览 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/01-architecture.md)

进程内四条生命线（**2026-10-07 实测复核，订正如下**）：

1. **主线程**：SwiftUI 渲染 + 状态写回（`@Observable DriveState`）
2. **tick 队列**（`com.aurora.tick`，`qos: .userInteractive`，30Hz `DispatchSource`）：
   `state.tick()` 驱动捕获→推理→按键
   - ⚠️ **实测订正**：`com.aurora.tick` 的创建点其实在
     `App/MissionConsole.swift:5534`（`bootstrap()` 内），**不是** `AuroraDriveApp.swift`
   - ⚠️ **必须是 DispatchSource，不能用 main RunLoop Timer**——后者会被 App Nap 冻结，
     全屏游戏时 tick 掉到 8Hz（`MissionConsole.swift:5532-5534` 注释）
   - ★ **待机降频（旧文完全没写，新人最容易误判「卡了」）**：非开车/非录制时
     `idleSkip` 到 8 才投递一次 → **30Hz / 8 ≈ 3.75Hz**（`MissionConsole.swift:5553-5562`）。
     目的是避免无谓的 SwiftUI 事务重算（曾把 UI 进程常年烧在 25–36%）
3. **网络定位步进**（10Hz）：`runNetworkLocateStep()`（`AuroraDriveApp.swift:4445`）——
   由 10Hz 定时器驱动（`:4754` 注释实测确认）
4. **抓包线程**（`com.aurora.coordinate-capture`）：`pcap_next_ex` 阻塞循环

App Nap 六重对抗（禁自动终止 / beginActivity / nice -20 / CGEventTap / 768MB mlock / 主线程实时约束）保证全屏下 tick 不掉帧。**三档**降级（e2e/yolo/rule）由 `DegradeStateMachine` 驱动 —— ⚠️ 2026-10-07 订正：旧文写「四档（含 recover 脱困档）」，而 `.recover` 已于 2026-09-30 整体删除（`DegradeStateMachine.swift:5-9` 明示）。

> ⚠️ **阈值实测订正**：旧文写「降级 0.65 / 恢复 0.80（滞回 0.15）/ 卡住 3km/h×3s / 脱困超时 30s」。
> 实测 `Agent/DegradeStateMachine.swift`：`degradeHealth` 默认 **0.65**（`:31`）；
> 恢复 = `min(0.99, degradeHealth + recoverHysteresis)`（`:114`，上限 0.99 是为了防「健康度 1.0 时
> 永不恢复」的死锁，P0-1）。**`recoverHysteresis` 的实值未在本次核实 —— 标「未验证」**；
> 其余「卡住 3km/h×3s / 脱困 30s」本次未复验 —— **未验证**。
> ⚠️ 另：本文旧记 `DegradeStateMachine` 250 行，**实测 165 行**。

## 二、网络定位子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md)

- **BPF 权限**：App 内密码弹窗 → osascript → `com.aurora.bpf-setup` LaunchDaemon 开机自动 `chmod 666 /dev/bpf*`
- **抓包**：`pcap_findalldevs` 枚举网卡（跳过 lo/utun 等虚拟网卡）→ 过滤器 `tcp port 30031 or udp`（MaaNTE 对齐，UE5 移动同步可走 UDP）→ `pcap_next_ex` 循环
- **解码**：剥三层头 → 只放行 c2s → UE5 位流扫描 → 世界坐标 + 朝向 → 仿射变换到 13056×13056 地图（map-2026-08，2026-09-13 升级）
- **定位现行**：`runNetworkLocateStep()`（10Hz）内 `CoordinateCapture` 懒初始化 + `read(maxAge:1.0)` 直连，无自愈引擎（原 NetworkHealer 随 76e9027 删除）
- **活/死澄清**：NetworkLocator（WebSocket）编译但零实例化；NetworkPacketCapture 已移 legacy/ 不编译；VisualLocator NCC 引擎已装配未接线

## 三、速度识别子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md)

**双引擎**（2026-09-19 订正）：PP-OCRv6 微调整行模型（`ppocrv6_tiny_ft_int8.mlpackage`，int8，GPU 推理）为主路径 + 逐位 CNN（`speed_digit_cnn_v4*`）为备用引擎；旧字模模板引擎已删除（档案见 dev/03-speed-ocr.md）。

模型加载必须 `MLModel.compileModel(at:)` 先编译（新版 macOS 不再隐式编译 .mlpackage）。三层校验：量程 0~400 → 跳变 ≤60 km/h → 1 秒窗口 3 帧投票（容差 ±2）。

## 四、视觉与推理子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md)

- CaptureEngine（**实测 654 行**）：ScreenCaptureKit 30fps BGRA，每帧直发 4 条回调
  （`CaptureEngine.swift:47` onFrame / `:52` onYoloFrame / `:56` onUpscaleFrame / `:69` onNativeFrame）
- InferenceEngine（**522**）：m9_mono，输入 `image[1,3,180,320]` + `vehicle_state[1,6]`（v2_new 契约），输出 steer/throttle/brake
- YoloEngine（**843**）：yolo26s，inputSize 640，conf 阈值 0.22，inferFast 直通快路径，CocoLabels 80→4 类映射
- ConfidenceEstimator（**248**）：一致性 0.5 + 极端度 0.3 + 亮度 0.2 加权估算 E2E 置信度（isLive 门控归零）
- RecordEngine（**424**）：raw_clips（640×360 + controls.csv）与 glyph_clips（字模 ROI PNG）双模式录制
- MetalFX：只挂显示 overlay（架构红线）
- ~~AutomationPanel：9 自动化按钮纯 UI 占位~~ → **2026-10-07 实测：`AutomationPanel` 已从源码树中删除**
  （`grep -rl AutomationPanel Sources/` 零命中），改由 `MissionConsole` 任务控制中心承接 UI
- 🆕 **本行旧文漏列的推理层文件**（实测行数）：`YolopxEngine.swift` **1,666**（★核心资产）、
  `SpeedOCRReader.swift` **1,540**、`QuestPanelReader.swift` **1,160**、`RoadCornerGuide.swift` **757**、
  `MotionPredictor.swift` **569**、`LaneFallback.swift` **461**、`OpticalFlowBridge.swift` **384**、
  `RoadMapPrior.swift` **360**、`EgoMotionModel.swift` **358**、`LaneKeepRealityTest.swift` **228**

## 五、控制与安全子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/05-control-safety.md)

- ControlEngine（**实测 649 行**）：`CGEventSource(.hidSystemState)`（游戏只读 HID 层）+ `.cghidEventTap` 注入；
  键码 W13/S1/A0/D2/空格49/Shift56（`ControlEngine.swift:46` 注释与 `:52-53` 实测**一致 ✅**）
- KeyboardMonitor（**113**）：全局物理键监听（显示用，**非急停**）
- RuleController（**实测 200 行**）：YOLO 检测 → 决策表（直行 0.8 油门 / urgency>0.55 急刹 / >0.25 减速避让）
- ~~EscapeController：倒车 1.5s → 反打 0.8s → 前进 2.0s 循环，15s 超时，>8km/h 成功~~
  → ⚠️ **2026-10-07 实测：脱困策略已按用户要求整体删除**。`EscapeController.swift` 现仅 **44 行**，
  文件头注释（`:9-13`）明写：「**EscapeController 脱困策略已按用户要求整体删除** —— 脱困档（`.recover`）
  实测压低速且无法退出，自动驾驶最多维持 **~12 秒**。`ControlCommand` 类型保留」。
  ⟹ 上文「倒车/反打/超时/>8km/h」数字**全部作废**；`ControlCommand` 现为 E2E/Rule 两段决策的统一输出
  （`steer[-1,1] + throttle[0,1] + brake[0,1] + confidence[0,1]`）。
- 紧急停车：`stopDriving()` → `releaseAll()` + `forceRule` 一键规则

## 五点五、构建 / 部署 / 自检 / 踩坑（2026-10-07 实测补写 · 新人实操章）

### A. 构建：**必须持锁**（并发 `swift build` 会互相打断）

```bash
# 推荐：锁内跑命令，自动加解锁
bash scripts/build-lock.sh run "我的改动验证" -- swift build -c release --disable-sandbox --scratch-path .build/scratch

# 或手工配对
bash scripts/build-lock.sh acquire "阶段A验收" || exit 3
trap 'bash scripts/build-lock.sh release' EXIT
bash scripts/build-lock.sh status      # 看谁持锁
```

- 典型失败症状：`error: input file '.../AuroraTheme.swift' was modified during the build`
- **基础设施缺陷，不是你的错**（`scripts/build-lock.sh:6-12` 明写）
- ⚠️ **基准 / 自检也必须持锁**：并发时 loadavg 冲到 5.15/8 核 → 耗时数字全部不可比（`:14-17`）
- 锁路径：`$TMPDIR/aurora-build.lock`（可用 `AURORA_BUILD_LOCK` 覆盖，`:37`）
- 残留锁处理：**脚本只提示不自动删**（`:32-33`、`:91-94`）。确认后手动 `rm -rf "$TMPDIR/aurora-build.lock"`
- 改了顶层目录/文件 → 跑 `bash scripts/check-package-sources.sh` 校验 `Package.swift` 完整性
  （`Package.swift:92` 注释指定）。**注意**：`sources:` 已是目录级白名单，新增 `.swift` **自动纳入**，
  但新增**顶层目录**仍需进 `exclude:`。

### B. 部署：原子双写（换 inode，不原地覆盖）

`./run.sh`（**182 行**，实测）的核心是**三次「写临时名 + `mv -f`」**——**不要退回 `cp` 原地覆盖**：

| 产物 | 证据 | 为什么要原子 |
|---|---|---|
| 裸可执行 `AuroraDriveUI` | `run.sh:105` | 原地 `cp` 会让运行中实例读到**新旧混合页** → CDHash 校验失败 → 内核直接 SIGKILL（`run.sh:96-101`，2026-09-12 事故） |
| `.app` 内 `Contents/MacOS/AuroraDriveUI` | `run.sh:111` | 同上 |
| `default.metallib` | `run.sh:124-125` | 预编译 Metal shader；失败**不阻塞部署**（运行时编译兜底，`:116`、`:127-130`） |

**关键事实（新人必读）**：

- `run.sh:77` `rm -rf .build` —— **每次全量重建**。别指望增量，慢是正常的。
- `run.sh:85` 三个必需参数：`-c release` + `--disable-sandbox`（沙盒环境 SwiftPM 自身
  `sandbox_apply` 会 `Operation not permitted`）+ `--scratch-path .build/scratch`。
- `run.sh:32-34` **libpcap 判据**走 `dyld_info`——系统库已进 dyld 共享缓存，磁盘上**没有实体文件**，
  旧写法 `ls /usr/lib/libpcap*` / `brew list libpcap` **恒为假、必然误报未安装**。
- `run.sh:57-64` YOLOPX 检查：`models/yolopx/yolopx3_pal8_detfp.mlmodelc` 是**★核心资产，一个字节都不能换**。
- `run.sh:148` 部署后 `pkill -f AuroraDriveUI` 清旧进程。
- 启动：`open "$ROOT/AuroraDriveUI.app"`（`:175`）；`--auto-login` 开启登录守护（`:171-172`）。
- 首次运行权限：**屏幕录制** + **辅助功能**（`:179-180`）。缺辅助功能时 AI 注入工具会被护栏③拒绝。

### C. 自检：怎么跑、怎么看结果

**约定**：自检返回**失败项数**，`exit(failed == 0 ? 0 : Int32(min(failed, 127)))`
（`LLMSelfTest.swift:13-17`）⟹ **退出码非 0 = 真发现问题**，可直接接 CI。

```bash
./AuroraDriveUI --llm-selftest              # A1 离线：协议/SSE/错误分类/候选排序（不联网也能跑）
./AuroraDriveUI --tool-selftest             # A3：注册表覆盖 + schema + 全工具 dryRun
./AuroraDriveUI --control-selftest          # A2：按键四证据链
./AuroraDriveUI --websearch-selftest "swift actor"   # W5 联网搜索
```

完整 12 项（4 既有 + 8 新增）见《代码-00-源码树与架构总览》2-2-4 节。

⚠️ **登记 ≠ 分发（两个都必须有）**（`AuroraDriveApp.swift:1004-1006`、`:1083-1084`）：
- 只登记不分发 → 走了正常启动路径，**自检等于没跑**
- 只分发不登记 → 被 UI 单实例锁挡掉，**却仍然 `exit 0`** = **假绿**（W5 实测踩过）

⚠️ **自检里禁止 `DispatchSemaphore.wait()` 等 Task**：主线程被占死，而自检内部要 `MainActor.run`
→ **死锁**（`--control-selftest` 实测跑 2 分钟零输出，栈卡 `semaphore_wait_trap`）。
正确做法是**主线程泵 RunLoop**（`runBlockingSelfTest`，`:1017-1025`）。
证据：`verify/evidence-llm/dispatch-deadlock-sample.txt`。

### D. 常见坑（本次复核新增，均在源码注释里有出处）

1. **新增 `.swift` 后「引用断了」/ 符号找不到** → 先查 `Package.swift` 的 `exclude:`
   是否把所在**顶层目录**排除了（`:93-188`，94 项）。目录级 `sources` 不是万能兜底。
2. **改了 `sources:` 块却发现全仓 500+ error** → 多半是把 `swiftSettings: [.swiftLanguageMode(.v5)]`
   一起删了（Swift 6 严格并发下 `static let shared` 全红）。**恢复时连注释一起保留**（`Package.swift:194-201`）。
3. **光流/直通帧「时好时坏」** → 池化缓冲被回收覆写（use-after-recycle）。
   必须在拿到帧的**同一段**里立即转灰度，**不能跨步骤持有引用**（`AuroraDriveApp.swift:6565` 注释块）。
4. **LLM 请求拖慢采集帧率** → 传输层用了独立 `URLSession` configuration（`LLMSessionPool`），
   **不要**复用到 captureQueue / 面板的 session（`LLMTransport.swift:24-30`）。
5. **AI 说「已执行」但游戏没反应** → 看 `ToolResult.postedEvents`：
   `= ControlEngine.postedEventCount 差值 + MouseController.postedEventCount 差值`（`ToolRegistry.swift:36-40`），
   **0 = 一个事件都没发出去**。护栏③（辅助功能未授权）会明确拒绝，不会假装成功。
6. **降级链「假故障」** → 健康状态**按实测记账**，不能凭静态清单假定可用
   （Zen 免费档 14 个模型实测仅 `space-bunny-free` 存活，`LLMHealth.swift:23-24`）；
   限流 ≠ 模型坏了（`:309`）。

---

## 六、常见问题 FAQ

**Q1：启动后提示「CNN模型和字模均未加载」？**
CNN 模型加载失败。检查 `models/speed_digit_cnn_v4.mlpackage` 是否存在；当前代码已用 `MLModel.compileModel(at:)` 先编译再加载，若仍失败请提 issue 附 `/tmp/aurora_pcap.log`。

**Q2：网络定位一直不工作？**
先确认 BPF 权限：`ls -l /dev/bpf0` 应为 `crw-rw-rw-`。不是就跑 App 内 BPF 安装，或手动 `sudo chmod 666 /dev/bpf*`（重启会失效，建议走 App 内安装）。

**Q3：定位显示异常 / 小地图位置不对？**
大堂/加载界面没有移动包是正常的。进入驾驶后自动恢复。位置持续偏差请对照已知地标检查标定（见 internals/coordinate-calibration）。

**Q4：速度数字偶尔跳变？**
单帧误识别会被三层校验拦下：跳变 >60 km/h 置零置信度走降级，1 秒窗口 3 帧投票（容差 ±2）通过才输出。

**Q5：编译报宏错误 "ObservableMacro could not be found"？**
Xcode 宏插件问题（常见于中文路径/外置盘 Xcode）。用完整权限编译，或将 Xcode 装到 `/Applications`。

**Q6：models/ 里的 speed_digit_cnn（无 v4）、speed_templates.json 是什么？**
早期 CNN v1 和旧模板库的遗留文件，当前代码不引用（SpeedOCRReader 只加载 speed_glyphs.json 与 v4.mlpackage），可忽略。

---

## 七、2026-09-19 磁盘清理说明

2026-09-19 已做磁盘清理，以下路径**已从本地移出**，统一迁移至外置硬盘：
`/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/`。

> ### ⚠️ 2026-09-29 路径修正（重要）
>
> **原文写的路径是** `/Volumes/代码项目/删除_20260919/自动驾驶系统清理/` ——
> **该路径不存在**（实测 `ls` 报 `No such file or directory`）。
>
> 真实路径**嵌在「自动驾驶项目半成品版本1.0到10.0」目录内，比原文多了两级**：
> ```
> /Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/
> ```
>
> **实测确认**：该归档目录 **22 GB / 9 个子目录**，与下表迁移项**一一对应**
> （`web_frames` / `template_scratch` / `build_contact` / `ocr_batch` / `ocr_batch2` /
> `gray_cache` / `videos` / `build_cache` / `ppocrv6_finetune_output`）。
>
> **按原路径去找会报 No such file，容易误以为"数据丢了"——实际 22 GB 完好。**
> 英文版 `DEVELOPER_GUIDE.en.md` 同样记错，已同步修正。

文档中出现这些旧路径时一律以上述迁移位置为准：

| 原本地路径 | 内容 |
|---|---|
| `data/web_frames` | 19G，22741 帧 web 视频截帧 |
| `build/vid_*.mp4` | 14 个挖掘用视频 |
| `build/template_scratch` | 模板挖掘工作区 |
| `build/contact` | 接触检测中间产物 |
| `build/ocr_batch(2)` | OCR 批量测试中间产物 |
| `data/_gray_cache` | 263 张 1280×803 灰度缓存（重跑 `tools/audit2.py` 需先重建） |
| `tools/ppocrv6_finetune/output` | PPOCRv6 微调输出 |
| `.build` | 构建缓存 |

本地保留的相关数据：`build/new_templates`（**265 条目 / 264 张 png**，2026-09-29 实测；原记 291/268，⚠️ 数字已变——另有 `_rejected/` 27 项淘汰候选）、`build/dig_*.json`（52 份挖掘证据 ✅ 实测吻合）、`build/maa_pipeline_override.json`（全量 250 节点 override ✅ 实测吻合）、`data/mac_shots`（208 张实机截图 ✅ 实测吻合）。

> ### 📌 2026-09-29 补充：模板挖掘的**两份原始调研报告**（此前未被引用）
>
> `build/` 目录下有两份**高价值调研报告**，此前**未被任何文档引用**：
>
> | 文件 | 规模 | 内容 |
> |---|---|---|
> | `build/route3_template_scene_map.md` | **51 KB** | **MaaNTE 官方模板 → 场景映射 & 缺失场景报告**（模板挖掘的**直接依据**） |
> | `build/route2_web_ui_research.md` | **35 KB** | 《异环》界面文字与布局的**公开网络调研**（为无法验证的 OCR 节点补外部证据） |
>
> **`route3` 的关键结论**（数据本轮实测**仍然准确**）：
> - MaaNTE 自带模板图 **211 张**（21 个目录）——✅ **实测吻合**
>   - 其中被 pipeline 引用 **110 张**，**101 张从未被引用**（遗留/备用资源）
> - pipeline **623 个可识别节点** + 29 个纯流程节点，分属 **24 个场景桶**
> - **101 个无法验证节点**（OCR miss 71 + TemplateMatch both_miss 30），分布 **15 个场景**
> - 其中 **13 个有官方模板支持** → 属官方正常流程，值得优先补截图
> - ⚠️ 该报告还纠正了上一轮的测试缺陷：**漏测了 20 个 TemplateMatch 节点**
>   （前一版解析器不支持扁平写法，`template` 被读成 null）
> - 给出**优先级排序的补图清单**（WitchDivination 15 / Fish 12 / MakeCoffee 11 / Tetris 11 / Volleyball 10 …）
>
> **⟹ 进展对照**：官方 211 张 → 我们已挖掘 **264 张**（超出官方 53 张）
>
> **`route2` 的方法论亮点**（值得沿用）：
> - **证据分级**：A 级（官方原文）/ B 级（大型攻略站带截图）/ C 级（玩家社区，可能 AI 洗稿）
> - **诚实边界**：「公开网络资料几乎不会逐字记录某个弹窗上的按钮是什么字」——
>   能确认的是**功能存在性 + 主要界面文案 + 交互流程**；按钮级文案查不到就写「未查证到」，**不做推测**
> - 已确认的关键文案：`纳库佩达之池` / `虔诚许愿` / `呗果` / `环期赏令` / `维特海默塔` /
>   `粉爪大劫案` / `Tetrominoes` / `魔女之家` / `一咖舍` / `店长特供` / `渔具商店`
> - ⚠️ 且**严格遵守了铁律**：「**未接触任何游戏文件、未使用游戏本体资源、未解包**」

MaaNTE 侧现状速记（详见 `docs/文档库/Maa深度/MaaNTE移植对照表.md`、`docs/文档库/Maa深度/ROI反推规则.md`、`docs/文档库/探索文档/界面采集作业指令.md`）：

- 250 个 ROI 节点 override 已生成（181 规则套用 + 32 精确反推，+83 偏移规则），落地 `build/maa_pipeline_override.json`
- 剩 24 个缺模板节点需实机采集补齐（胜负加载屏、商店页、光标；SceneLoadingType2 的 '%' 与 Sync×6 疑似占位坏定义，可不采）
- 坐标体系 1470×923 固定不可变；运行期长边缩到 1280（截图 1280×803）；OCR 必须 GPU；按键走 ControlEngine CGEvent；游戏启动先点窗口、按 T 开车；Maa 只做工具，不整体接管
- BidKing（拍卖王）PR#434 代码已提取至独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并主线）
