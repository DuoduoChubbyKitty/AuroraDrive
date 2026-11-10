# 给 codex 的提示词（复制下面整段）

---

你是这个 Swift 项目（`/Users/dupi/Desktop/自动驾驶系统`，macOS app，SwiftPM，`Package.swift` 里 executable target 名 `AuroraDrive`）的高级工程师。**只改代码，不要碰模型训练脚本和模型文件**（`src/*.py`、`models/**` 一律不改；模型重训由别人负责）。

## 背景

这是《无限暖暖》（NTE）的自动驾驶辅助。当前主驾是**端到端模型 V3**（`Sources/AuroraDrive/Inference/InferenceEngineV3.swift`），由 24 帧图像窗口 + 车辆状态直接输出按键：
- `vertical` 三分类 W/NONE/S
- `horizontal` 三分类 A/NONE/D
- `handbrake`/`brake` 两个 sigmoid 头（Shift / Space）
- `super_brake`/`ultimate` 由上面两个头**派生**

用户报了两个问题，你的任务是排查并修好（第 3 条由别人负责，你只要不破坏它）：

1. **车永远杀停、不敢给油**：遇到障碍物就停住不动，永远不会绕开。
2. **端到端主驾模式下同时跑太多模型**：既然 V3 是端到端主驾，为什么还要跑车道线等一堆模型？用户要求主驾时"只留一个速度表 + 主驾模型"。
3. （不归你）模型本身要重训，所以**不要把三分类改成连续量、不要改模型输入输出契约**，那会让我这边训出来的模型对不上。

## 已经核实过的事实（别重复查，直接用，但要自己再确认一遍行号）

### A. V3 主驾根本不吃车道线和检测框

`Sources/AuroraDrive/Inference/InferenceEngineV3.swift:1203-1207` 明确写着：`lane` / `dets` / `det_mask` 三路输入**永远零填充**，注释原文「训练时恒为零填充（V3 录制数据无这两路）」。V3 实际只用 `image_hi`（3 帧 224×384）+ `image_lo`（21 帧 112×192）+ `vehicle_state`（8 维，只有 `[6]` 是上一帧 A/D）。

**含义**：车道线模型（yolopx / yolo26s）的输出对 V3 决策**零贡献**。砍它们不影响 V3 开车。

### B. 现在主驾时到底起了哪些模型

启动加载点 `Sources/AuroraDrive/App/AuroraDriveApp.swift:7056-7084`，`startDriving()` 里依次加载：
- `inferenceEngineV3`（主驾，必须）
- `inferenceEngineV2`（旧主驾，仅作降级备份）
- `inferenceEngine`（M9，V2 失败才加载）
- `assistEngine`（第二套驾驶模型，"YOLO 接管档"司机）
- `yoloEngine`（yolo26s 检测网，仅 legacy 档加载）
- `yolopxEngine`（三合一：检测 + 车道线 + 可行驶区，**A 模型档默认会加载**）

每帧 tick 内的推理（同文件 ~8140-8420）：
- V3 每帧都喂（`:8200` 附近 `if inferenceEngineV3.isLoaded { ... infer ... }`）
- `inferenceEngineV2.loadIfNeeded()` 每帧被调用（`:8152`）
- `assistEngine.infer()` 每 5 帧保活一次（`AuroraFlags.assistKeepalive`，搜索 `assistKeepalive`）
- `yoloEngine.infer()` 与 `yolopxEngine.infer()` 偶数/奇数帧错开各跑一次（搜索 `detectGateA` / `detectGateB`）

### C. "永远杀停"的强嫌疑点（按可能性排序，全部要查）

1. **防侧翻兜底在车速未知时强制刹车**
   `Sources/AuroraDrive/Inference/InferenceEngineV3.swift:1052-1078` `applyRolloverGuard()`：当 `superBrakePressed || ultimatePressed` 且车速未知（`speedValid == false` 或 `speedKmh == nil`）时，**按高速处理**，直接 `throttle = 0; brake = 1`。
   调用点 `Sources/AuroraDrive/App/AuroraDriveApp.swift:9038`。
   而 `speedValid` 默认 `false`（`:5622`），只在 OCR 速度新鲜时才置 true（`:8499` `if speedValid != ocrFresh { speedValid = ocrFresh }`）。
   **→ 如果 OCR 速度经常读不到，这条会让每次模型给出 super/ultimate 时都被强制成 S，且没有任何日志说明"是兜底改的"。**

2. **模型自己输出 vertical=S**
   `InferenceEngineV3.swift:959-963`：`verticalForCommand == 2` → `throttle: 0, brake: 1.0`。这个是模型输出直接决定的，代码侧只能观测不能改（重训解决）。你要做的是**加可观测性**：把每帧 `verticalClass` / `superBrakePressed` / `ultimatePressed` / `speedValid` / 兜底是否生效 打到日志（限频），让"是模型想刹"还是"兜底强制刹"能一眼分开。

3. **降级链把车拖到规则档**
   `Sources/AuroraDrive/Agent/DegradeStateMachine.swift:118-135`：`.e2e` 档健康度 < `degradeHealth`（默认 0.65）或 `!m9Live` → 降 `.yolo`；`.yolo` 再降 `.rule`。
   `Sources/AuroraDrive/Agent/RuleController.swift:155-185`：规则档虽然已取消自动踩刹车（`brake` 恒 0），但 `urgency > hardBrakeUrgency` 时 `throttle = 0` —— **不给油**，且只会向障碍反方向打满方向，没有真正的绕障路径。
   **→ 要查清实际运行时是不是经常掉进 `.rule` 档，并把这个状态显示出来。**

4. **V3 本身没有"避险"这个动作维度**
   V3 输出只有 A/NONE/D × W/NONE/S，天然没有"绕障"动作。端到端学的是真人按键，真人录像里如果没有绕障样本，模型不会绕。**这一条属于模型/数据问题，你只需在代码里如实标注，不要自己发明一个规则避障层去补。**

### D. 车道线模型（yolopx / yolo26s）的所有消费者（砍之前必须逐个确认）

- `Sources/AuroraDrive/Core/EngineMain.swift:1517, 1559`（检测框进共享内存/诊断）
- `Sources/AuroraDrive/Core/EngineMain.swift:1597-1598`（`drivableMask` / `laneMask` 进 shm）
- `Sources/AuroraDrive/App/AuroraDriveApp.swift:4345, 4354`（`effectiveDetections` 优先取 yolopx 框）
- `Sources/AuroraDrive/App/AuroraDriveApp.swift:7529-7558`（UI 观察 + `rawLaneMask`）
- `Sources/AuroraDrive/App/AuroraDriveApp.swift:8925`（`drivableMask` 可视化）
- `Sources/AuroraDrive/Inference/InferenceEngineV2.swift:351, 514`（**V2 的 lane 输入正是 `yolopxEngine.laneMask`**）

**关键结论**：V2 依赖 yolopx 的 lane；但 V3 硬切后 V2 只是降级备份（不喂帧）。所以"主驾时砍掉车道线模型"在技术上是成立的，**但必须处理两件事**：① `.rule` / `.yolo` 降级档还要不要它；② EngineMain 共享内存里的 laneMask/drivableMask 字段（UI/诊断在读）。

## 任务

### 任务 1：把"主驾时到底跑了几个模型"做成可验证的事实，然后砍到只剩 V3 + 速度表

要求：
1. 先在主驾档（`.e2e`）加一条**限频（每 60 帧一次）**的日志，打印本帧实际推理了哪些引擎（V3 / V2 / M9 / assist / yolo26s / yolopx），各跑了没有。
2. 实测确认后，在 `.e2e` 档下**停掉与 V3 决策无关的推理**：
   - V2 已不喂帧，确认 `loadIfNeeded()` 每帧调用是不是纯浪费（它是同步加载，已有就 register 检查），能改成"加载一次"就改。
   - `assistEngine` 的保活推理在 `.e2e` 档是否还有必要（降级链 `.yolo` 才消费它）；若没必要，`AuroraFlags.assistKeepalive` 默认值改成主驾不跑。
   - `yoloEngine` / `yolopxEngine` 在 `.e2e` 档是否可以完全不推理（保留加载，供降级档使用）——**注意**：UI 画框也在消费检测框，砍推理前确认 UI 是否还要求显示。如果 UI 需要，就明确告诉用户"UI 显示会消失"，不要偷偷砍。
3. 所有改动加**可回退开关**（照项目现有风格用 `AuroraFlags`，参考 `AuroraFlags.assistKeepalive`、`AuroraFlags.keyRefreshHz` 的写法），环境变量能一键恢复旧行为。

### 任务 2：查清"永远杀停"的真实原因并修掉误刹

要求：
1. 按 C 的顺序逐条验证，**先观测后改动**。每一步给出可复现命令或日志证据。
2. 重点查 `applyRolloverGuard` 在车速未知时强制 S 这条：确认游戏运行时 `speedValid` 的真实占比。如果 OCR 经常失败导致这条频繁误触发，改成**车速未知时不强制 S，而是降级为"不给油但也绝不主动刹车"**（`throttle = 0, brake = 保持模型原值`），并 `dlog` 说明。**这个改动是安全相关，必须在注释里写清理由，并且保留一个开关能恢复"未知即保守刹停"的旧行为。**
3. 给 `.e2e` 档加一条"刹车归因"日志：本帧 `brake=1` 是①模型 vertical=S，②ultimate 强制，③防侧翻兜底，还是④降级到规则档造成的。限频。
4. 查降级链：如果实际驾驶中经常掉到 `.yolo`/`.rule`，把触发原因（健康度数值、`m9Live`、`assistLive`）打到日志并显示在 UI 状态区。

## 硬约束

- **最小 diff**。不重构无关代码、不改格式、不顺手修别的 typos。
- 不许删降级安全链（`.e2e → .yolo → .rule`），那是产品级最后防线；可以加开关，不许直接删除。
- 不许改 V3 的模型输入输出契约（`V3InputContract`、三分类、各 sigmoid 头）。模型要重训，契约必须稳定。
- 不许在代码里新发明"规则避障"去冒充端到端能力。发现问题就如实报告，不要用规则层糊过去。
- 不引入新依赖、新模式、新抽象层。
- 改完必须：
  1. `swift build -c release --disable-sandbox --scratch-path .build/scratch` 编译通过；
  2. `./.build/scratch/release/AuroraDrive --v3-selftest` 通过（当前基线是 **55/55 全过，exit 0**，不许低于这个）；
  3. 跑 `bash scripts/check-package-sources.sh`（若存在）确认没漏登记新文件。
- 提交前自己读一遍 diff，每个改动都要能回答"这行是不是解决本次问题所必需"。

## 交付物

1. 改动清单（文件:行 + 一句话说明为什么改）。
2. 任务 1 的日志证据：改前/改后主驾档每帧实际跑了几个模型。
3. 任务 2 的归因结论：`brake=1` 的主因是哪一个，证据是什么。
4. 自检与编译结果贴原始输出，不要写"应该没问题"。

## 最后一条纪律

如果查下来发现"永远杀停"的主因是**模型输出本身**（vertical 大量预测 S），那就如实写在结论里，明确说"代码侧只能加可观测性和兜底策略，根治要重训模型"，**不要假装用代码修好了模型的行为**。
