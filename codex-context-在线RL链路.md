# AuroraDrive 项目上下文（给 Codex 的背景说明，不含任何诊断与判断）

## 项目是什么

- 仓库：`/Users/dupi/Desktop/自动驾驶系统`，Swift 6 / SwiftPM 包，macOS 原生 App（`AuroraDriveUI`）。
- 用途：对一块**云串流/远程桌面里的游戏画面**做实时自动驾驶。App 抓屏 → 神经网络推理 → 用 CGEvent 向系统注入 W/A/S/D/空格/Shift 按键控制游戏里的车。
- 构建部署：`swift build -c release` 只产出 `.build/release/AuroraDrive`；实际给用户用的是 `./run.sh`（clean release 构建 → 签名 → 安装 `AuroraDriveUI` → pkill 重启 App）。

## 进程架构

- **UI 进程**（`AuroraDriveApp.swift`，约 11400 行）：SwiftUI 界面、30Hz `tick()` 主循环、抓屏、速度表 OCR、LeanRecorder 录制器、以及本提示重点的「壳模式在线 RL 训练」。
- **engine 子进程**（`--engine` 参数启动，`EngineClient.swift`）：后台自动驾驶引擎进程，经 Unix socket 把推理结果（按键命令）发回 UI 进程执行注入。普通自动驾驶模式下按键由这个进程决策。
- 「壳模式」下 engine 子进程被 SIGTERM/SIGKILL 退出且不重连，只留 UI 进程：抓屏 + 速度 OCR + 在线训练 + 按键注入全部在 UI 进程内完成。

## 普通自动驾驶链路（供参照）

- `CaptureEngine.swift`：ScreenCaptureKit SCStream 抓屏，帧回调把 CGImage 交给 tick。
- `InferenceEngineV3.swift`：V3 CoreML 模型推理，默认 ANE 优先（`AURORA_COMPUTE_UNITS` 可覆盖）。
- `ControlEngine.swift`：把决策落到 CGEvent keyDown/keyUp（`hold/release/releaseAll`），维护 `heldKeys` 账本；`digestMode=true` 时所有 CGEvent.post 被进程内吞掉（消化/影子模式，不发真键）。
- 速度：`SpeedometerOCR` 从 HUD 区域截图读车速。
- 性能打点体系：`PerfBus.lap("tick.xxx", from: t)` 分段计时；环境变量 `AURORA_PERF=1` 开启统计，`--perf-report` 打印人可读表。tick 内已有打点：`tick.consumeFrame / tick.yoloFast / tick.nativeROI / tick.speed / tick.inject / tick.record` 等。

## V3 模型输入契约（`V3InputContract`，InferenceEngineV3.swift :99-118）

- `image_hi`：形状 `[1, 3, 224, 384]` float16（3 帧高清）
- `image_lo`：形状 `[1, 21, 112, 192]` float16（21 帧低清）
- `lane` `[1,1,64,64]`、`dets` [1,maxDetections,featDim]、`det_mask`、`vehicle_state [1,8]`：训练时后四路全零填充
- 合计 24 帧窗口 @15Hz ≈ 1.53 秒；输入为 CHW、逐像素 /255 归一化
- 预处理函数：`InferenceEngineV3.renderNormalized(_ cgImage, height, width) -> [Float16]?`（InferenceEngineV3.swift :1380）——CGContext 高质量缩放绘制 → 逐像素拆 RGB 三个平面并 /255。内部用静态共享 scratch 缓冲 + NSLock 串行化。
- 窗口缓冲：`V3FrameRingBuffer`（hi/lo 各自环形窗口，新帧 push、窗口整体拷出）。
- V3 模型总参数 12,492,387；本仓另有一份带额外输出 `state_token[256]` 的导出模型 `models/v3_state_token.mlmodelc`（`tools/v3_exp/export_state_token_model.py` 产出）。

## 壳模式 + 在线 RL 训练链路（本次关注对象）

数据流（全部在 UI 进程）：

1. 抓屏帧（CGImage）+ 信号（车速、接管、碰撞等）进入 `OnlineTrainingRuntime`（`Sources/AuroraDrive/RL/OnlineTrainingRuntime.swift`，约 990 行）。运行时是**单槽 drop-oldest** 管道：主线程只做一次入槽（塞满即丢旧），消费在**独立后台线程**逐项 `process(_:)`（:640）。
2. `process` 每帧：`renderNormalized` 两次（hi 224×384 与 lo 112×192，InferenceEngineV3.swift :1380）→ `V3FrameRingBuffer.push` 入窗。
3. 默认 `sampleEveryNFrames=1`。后台实际消费且预处理成功的普通帧入窗后均尝试提取 token 并采样动作。过载时单槽会丢帧。
4. 采样帧：`StateTokenAccelerator.stateTokenAndLogits`（`Sources/AuroraDrive/Inference/StateTokenAccelerator.swift` :141）——构造 6 路 MLMultiArray 输入（复用缓冲、`MLDictionaryFeatureProvider`）→ `model.prediction(from:)`（完整 V3 前向，输出含 `state_token[256]`）。
5. `OnlineTrainer.sampleAction` 调用 `PolicyHead.forward`，将 state_token[256] 映射为竖直和横向 logits 及 value。主干和两路动作头有 68,454 个参数，价值头有 257 个，总共训练 68,711 个参数。V3 骨干冻结。
6. 采样动作经 runtime 的串行 `actionQueue` → executor 闭包 → 主线程 `DriveState.applyShellAction`（AuroraDriveApp.swift :11383）→ `DriveState.shellActionKeyPlan`（:11414 纯函数映射 v/h class → W/S/A/D）→ `controlEngine.hold/release`（真发 CGEvent；受 digest 闸门控制）。
7. `trainer.collect(...)` 攒 transition；接管/软截断（48s）/停止时 `sealEpisode`。
8. PPO 更新：`OnlineTrainer`（OnlineTrainer.swift :505-536）在**独立 `trainingQueue` 后台队列**异步做 GAE → advantage 归一化 → `PolicyHead.updatePPO`（PolicyHead.swift :757）→ 更新后把 `trainingPolicy` 拷给 `inferencePolicy`。推理用快照 `inferencePolicy`，训练改 `trainingPolicy`。
9. 在线训练以人工接管作为惩罚性终止。默认接管惩罚为 -10。速度、卡死和减速按 RewardConfig 计算；车道感知启用时每秒最多请求一次同帧测量，PPO 只对已取得可靠双侧车道偏移的样本加罚。当前没有独立的碰撞观测。
10. 独立在线训练和壳模式共用运行时和策略头。默认存档为 `~/Library/Application Support/AuroraDrive/shell_head_latest.json`，两个入口会继续训练同一份权重。可通过 `AURORA_RL_HEAD_CHECKPOINT` 指定实验存档。

## digest / 真注入闸门（AURORA_RL_LIVE_ACTUATION）

- `effectiveDigest = runtime.digestMode || userDigestProvider() || !liveActuationAllowed`（OnlineTrainingRuntime.swift :783/:793/:822）
- `ShellModeController.liveActuationEnabled`（ShellModeController.swift :159）与 runtime 的 `liveActuationAllowed`（:335）：默认 **live 真注入**；环境变量 `AURORA_RL_LIVE_ACTUATION=0` 才退回 digest 影子（不真发键）。
- `applyShellAction` 入口若 digest 则直接 return（零按键）；人工接管（`EmergencyTakeover.userHoldingKey`）时只撤 AI 键、保留人的物理键。
- ControlEngine 自身还有 `digestMode`（env `AURORA_DIGEST`，默认 false=真注入），`postKeyEvent` 内部最后一道闸。

## 关键文件清单

| 文件 | 职责 |
|---|---|
| `Sources/AuroraDrive/App/AuroraDriveApp.swift` | UI 主循环 tick、DriveState 单例、applyShellAction、壳模式启停（:7598-7667） |
| `Sources/AuroraDrive/RL/ShellModeController.swift` | 壳模式编排：退引擎→停驾驶链→保抓屏→接 executor→起训练 |
| `Sources/AuroraDrive/RL/OnlineTrainingRuntime.swift` | 单槽 drop-oldest 训练管道、消费线程、动作发布、会话代数 |
| `Sources/AuroraDrive/RL/OnlineTrainer.swift` | 采样/collect/episode 封口/trainingQueue 里 GAE+PPO 更新 |
| `Sources/AuroraDrive/RL/PolicyHead.swift` | 纯 Swift 策略头（vDSP），forward :502 / updatePPO :757 |
| `Sources/AuroraDrive/Inference/StateTokenAccelerator.swift` | state_token CoreML 加速器（完整 V3 前向） |
| `Sources/AuroraDrive/Inference/InferenceEngineV3.swift` | V3 生产推理 + renderNormalized :1380 |
| `Sources/AuroraDrive/Control/ControlEngine.swift` | CGEvent 注入 + heldKeys + digestMode |
| `Sources/AuroraDrive/Capture/CaptureEngine.swift` | SCStream 抓屏 |
| `Sources/AuroraDrive/App/MissionConsole.swift` | UI 按钮面板（壳模式按钮「人机共驾壳模式」） |

## 自检与验证命令

```bash
cd /Users/dupi/Desktop/自动驾驶系统
swift build -c release

.build/release/AuroraDrive --shell-engine-selftest        # 壳模式编排顺序
.build/release/AuroraDrive --rl-shell-selftest             # 壳模式控制器
.build/release/AuroraDrive --rl-shell-runtime-selftest    # runtime 管道/并发
.build/release/AuroraDrive --rl-shell-reward-selftest     # 奖励三段
.build/release/AuroraDrive --rl-train-wire-selftest       # 真模型接线（无模型时 SKIP）
.build/release/AuroraDrive --rl-accel-selftest            # state_token 加速器（无模型时 SKIP）
.build/release/AuroraDrive --rl-core-selftest              # PPO 核心
.build/release/AuroraDrive --rl-online-selftest            # 在线训练
.build/release/AuroraDrive --codrive-selftest              # 共驾
.build/release/AuroraDrive --perf-report                   # PerfBus 打点统计表
```

- Python 侧工具在 `tools/v3_rl/`（reward.py 等，674 断言 pytest）；`/usr/local/bin/python3.11` 有 torch（MPS 可用），默认 `python3` 是 3.14 无 torch。
- 机器：Apple M3，16 GB，macOS。抓的是云串流窗口（窗口捕获模式）或全屏。
