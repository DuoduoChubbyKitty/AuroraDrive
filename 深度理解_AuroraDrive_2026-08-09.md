# AuroraDrive 项目深度理解报告

> 生成时间：2026-08-09 ｜ 方式：主理人逐文件精读 + 跨文件符号检索 + 资产清点（累计工具调用 > 300 次）
> 目标：彻底吃透这个 macOS「异环」游戏自动开车辅助工具

---

## 0. 一句话定位

AuroraDrive 是一个 **SwiftUI + CoreML 的 macOS 实时游戏辅助驾驶 App**：截屏 → 双神经网络驾驶模型 + YOLO 检测 → 四档降级状态机决策 → CGEvent 注入 WASD/空格 → 让 AI 直接开游戏。底层训练用 PyTorch（M9MonoModel 单目变体），通过 CoreML 导出在端侧 ANE/GPU 跑。

---

## 1. 整体架构（四层）

```
┌─────────────────────────────────────────────────────────────────┐
│  UI 层（SwiftUI，Tesla FSD 风格，纯黑+青色发光）                    │
│  AuroraDriveApp.swift(合集) / GameMapView.swift                    │
│  ContentView 用 Timer(1/30s) 驱动 DriveState.tick()                │
└───────────────────────────────┬─────────────────────────────────┘
                                  │ tick() 30Hz
┌───────────────────────────────▼─────────────────────────────────┐
│  决策层（DriveState.tick，8 步管线）                               │
│  感知 → 置信度 → 状态机 → 按态输出 → 注入 → 录制 → 日志           │
│  DegradeStateMachine / ConfidenceEstimator / EscapeController      │
│  RuleController / KeyboardMonitor / RecordEngine                   │
└───────────────────────────────┬─────────────────────────────────┘
                                  │
┌───────────────────────────────▼─────────────────────────────────┐
│  引擎层（@MainActor + 后台串行队列异步推理）                        │
│  CaptureEngine（截屏+352直通）YoloEngine（检测）                   │
│  InferenceEngine ×2（m9_mono / game_assist_control）               │
│  ControlEngine（CGEvent 注入 + auto-repeat 重发）                  │
└───────────────────────────────┬─────────────────────────────────┘
                                  │
┌───────────────────────────────▼─────────────────────────────────┐
│  模型/资产层                                                        │
│  models/*.mlmodelc（CoreML 编译产物）  recordings/（DAgger 数据）   │
│  src/（PyTorch 训练）  checkpoints/  data/raw_clips/  tools/（导出）│
└─────────────────────────────────────────────────────────────────┘
```

**构建**：`Package.swift` 单一可执行 target `AuroraDrive`，12 个 Swift 源文件，`swift build` → `.build/release/AuroraDrive`。

---

## 2. 主循环与数据流（tick() 八步，AuroraDriveApp.swift:520）

`ContentView` 的 `Timer.publish(every: 1/30)` → `state.tick()`（30Hz 主线程）。每帧：

1. **感知**：`currentScreenImage` 非空时触发 `inferenceEngine.infer()`（M9）、`assistEngine.infer()`（第二司机）、YOLO 走 CaptureEngine 直通（`fastPathActive` 时跳过慢路径）。
2. **读结果**：`commandOf(engine)` 把 `InferenceResult` 转 `ControlCommand`；`isAlive()` 判链路存活（加载成功 && 有结果 && <1s 新鲜）。
3. **遥测模拟**：`speed` 按 `sportMode` 朝 `speedLimit*0.72/1.0` 逼近 + 随机抖动（游戏真实状态读取未接入）。
4. **状态机**：`degradeStm.update(m9Live, assistLive, health:confidence, warmingUp, speedKmh, dt, sportMode)` → `mode`。
5. **置信度**：`confidenceEst.update(command, image, isLive)`；暖机期（启动 <3s 无结果）保持 1.0。
6. **按态输出**：`.e2e → m9Command`；`.yolo → assistCommand`；`.rule → ruleController.decide()`；`.recover → escapeController`。
7. **注入**：`expertMode/controlDisabled` 时不注入；否则 `applyCommand()`。
8. **录制 + 1Hz 日志**：`recordEngine.appendFrame()`；`dlog` 写 `/tmp/aurora_debug.log`（含 `ev=postedEventCount`、`front=前台应用` 用于诊断）。

---

## 3. 四档降级梯子（DegradeStateMachine.swift）

驱动原则：**模型存活 + 健康度驱动**，暖机保护 + 滞回（恢复阈值 = `degradeHealth + 0.15`）。

| 档位 | 枚举 | 司机 | 降级触发 | 恢复触发 |
|------|------|------|----------|----------|
| 端到端主驾 | `.e2e` | M9 (m9_mono) | M9 失联 → 掉 YOLO接管 | assistLive 且 health>0.75 |
| YOLO接管 | `.yolo` | 第二神经网 (game_assist_control) | control 死 → 掉纯规则 | — |
| 纯规则兜底 | `.rule` | RuleController 手写规则 | 最底层，无更下档 | 上层恢复 |
| 脱困中 | `.recover` | EscapeController | 卡死(车速<3·3s) | 车速恢复自动转出 |

- **极速模式**：`sportMode` 强制 `.e2e`（不降级）。
- **暖机**：开车头 3s 无推理结果时 `mode` 保持 `.e2e`、置信度 1.0，避免启动瞬间误降级。
- **关键铁律**：输出稳定 ≠ 模型死（直道本应稳定输出）；只有「链路死（未加载/无结果/结果过期>1s）→ 置信度 0 → 自动降级」。

---

## 4. 置信度估计（ConfidenceEstimator.swift）

E2E 模型无置信度头，用启发式：按**当前档位模型**的输出算 health。
- **极端度只判 `|steer|>0.95`**（转向打满）；**油门/刹车贴边不判退化**（巡航全油门是正常驾驶）——这是修过的坑，旧逻辑把「throttle=1 巡航」误判退化 → 置信度恒 0.70 < 恢复阈值 0.75 → 卡死在规则档。
- 链路死 → 置信度 0。
- 设计铁律：不要引入「恒定输出判退化 / 冻结检测」逻辑。

---

## 5. 引擎层要点

### CaptureEngine（截屏）
- `CGDisplayStream` 全屏画面流；`onFrame` 更新 `currentScreenImage`（主线程）；`onYoloFrame` 把源头 GPU 缩放好的 **352×352 缓冲直接喂 YOLO**（直通，跳过 NSImage/CGImage 大图转换，帧率关键）。
- 禁用 App Nap（`disableAutomaticTermination`）保证切到游戏全屏（沦为后台）仍 30Hz 运行。

### YoloEngine（检测，YoloEngine.swift）
- `game_assist_yolo.mlmodelc`，**352×352 输入，colorSpace=BGR（32BGRA 内存序）**。
- 输出 `boxes[1,1815,4] / scores[1,1815] / labels[1,1815]`（Float16，anchor 解码已烘进模型）。Swift 端 `readML` 用**官方下标**读 FLOAT16（直接读 dataPointer 会错位）。
- 阈值过滤 + **类内 NMS** + **帧间 EMA 平滑**（治框乱飘）+ **手动框选/点选锁定追踪**（IoU+中心距，丢失 15 帧自动解除）。
- 命令行 `--yolo-selftest` / `--yolo-bench` 用于与 Python 端对拍通道序。

### InferenceEngine（E2E 推理，InferenceEngine.swift）
- `m9_mono.mlmodelc`，输入 `image[1,3,180,320]CHW [0,1]` + `vehicle_state[1,6]`。
- **MLMultiArray 正确读法**：`output.featureValue(for:name).multiArrayValue[[0,0]].doubleValue`。`featureValue(for:).doubleValue` 对 multiArray 恒返回 0（端到端主驾完全不决策的元凶，已修）。
- **vehicle_state 契约（已修的致命坑）**：`[speed_norm, curvature*5, sin(heading), cos(heading), speed_limit/120, 0]`，全部 [-1,1]/[0,1]。旧版喂 `[speed原始值, rpm, gear, ...]`（超分布 60~8000 倍）→ M9 恒输出 -1/1。无遥测时喂 `[speed/120, 0, 0, 1, speedLimit/120, 0]`。

### ControlEngine（按键注入，ControlEngine.swift）
- 必须用 `.combinedSessionState`（`.privateState` 游戏读不到）。
- **auto-repeat 重发（决定性修复）**：`refreshHeldKeys()` 每个 tick 对 `heldKeys` 重发 `keyDown` 且置 `.keyboardEventAutorepeat=1`。否则按住后不再产生事件，CGEvent 一次性事件流干涸 → 直道稳定输出时整段只发 1 个 keyDown（还被点「开始驾驶」时的前台 App 吃掉）→ 游戏收不到。纯规则档因 YOLO 框闪烁导致输出反复跳变 → 事件流持续 → 反而能开。这就是「纯规则能开、M9 不能开」的真因。
- `releaseAll()` 无条件释放全部映射键（清残留卡键）。`postedEventCount` 诊断字段：每秒应涨约 30，`ev` 不涨 = 事件流干涸。
- **注入只发前台应用**：`CGEvent.post` 全局注入进系统键盘状态（可用 `CGEventSourceKeyState` 验证 W=true），但事件分发只到前台应用 —— 游戏不在前台（如被抖音 Electron 窗口挡着）就收不到；Chromium 内核拒收合成键。排查「M9 不出键」先 `lsappinfo front`。

---

## 6. 训练/导出管线（src/ + tools/）

| 文件 | 作用 |
|------|------|
| `model.py` | `M9Model`（10cam+2lidar 全功能，仅研究）/ `M9MonoModel`（单 cam+6 维 state，游戏部署用）/ `FusionHead` / `M9Loss`（MSE转向+Huber油门刹车）/ 导出 ONNX、TorchScript |
| `mono_dataset.py` | 解析 `data/raw_clips/clip_*`；v2_new 格式从 sidecar 物理量构造 **正确 vehicle_state 契约**；RC 增强；按 clip 划分防泄漏 |
| `train_game_assist.py` | App「训练」按钮入口（`src/train_game_assist.py --skip_view --skip_yolo`）：训练 TPV/FPV 控制模型 + 视角分类器 + YOLO（合成数据） |
| `train_mono.py` | 复用训练框架 + `convert_torch_to_coreml` |
| `trainer.py` / `dagger.py` / `data_generator.py` / `expert_controller.py` | DAgger 自训练、合成数据生成、专家控制器（曲率安全车速等） |
| `config.py` | `ROOT_DIR/MODELS_DIR/LOSS_WEIGHTS/TRAIN_GRAD_CLIP_NORM/...` |
| `tools/convert_e2e_to_coreml.py` 等 | ONNX/CoreML 导出、`verify_yolo_coreml.py` 对拍 |

**模型架构**：`M9MonoModel` = RepVGG-A0（共享主干，推理时重参数化为纯 3×3）+ `FusionHead`（1280+6=1286 维 → 512→256→128 → steer(tanh)/throttle(sigmoid)/brake(sigmoid)）。目标 FP16 ≤ 31MB。

**一键训练闭环**：`DriveState.startTraining()` 拉 `python3.11 src/train_game_assist.py` → 产物 `game_assist_control*.mlmodelc` → `deployTrainedModel()` 复制到 `m9_mono.mlmodelc` 热替换 → `reloadModel()` → 清理 `data/raw_clips`。

**两个模型权重关系**：`inferenceEngine(m9_mono)` 与 `assistEngine(game_assist_control)` 同架构，**当前同权重**（m9_mono 从 game_assist_control checkpoint 导出，实测输出逐位一致）。换权重后档2 才真正不同于档1。

---

## 7. 模型资产清点（models/）

| 模型 | 文件 | 状态 |
|------|------|------|
| M9 端到端主驾 | `m9_mono.mlmodelc` + `.mlpackage` | ✅ 已部署（App 默认加载） |
| 第二驾驶模型（YOLO接管档） | `game_assist_control.mlmodelc` + `.mlpackage` | ✅ 已部署 |
| YOLO 检测 | `game_assist_yolo.mlmodelc` + `.mlpackage`（+ `.onnx`） | ✅ 已部署 |
| M9 神经网络变体 | `m9_mono_nn.mlmodelc` + `.mlpackage` | ⚠️ 存在但未在代码中被引用（用途不明，疑似实验残留） |
| 视角分类器 | `view_classifier.mlmodelc`？（训练脚本会产出） | ⚠️ 训练脚本 `train_view_classifier` 写 `view_classifier.mlmodelc`，但 App 的 `tick()` 已移除视角分类器路由（注释说已移除） |
| 地图底图/数据库 | `enhanced_1366.png`(4K超分)、`FINAL_complete_map_database.json`(5677 标记) | GameMapView 用；但 `filteredMarkers` 强制返回 `[]`（标记数据过旧 2023 立项版，暂不显示） |

`checkpoints/`：`game_assist_control/best_model.pt` + `training_log.json` + `activation_state.json`；`m9_mono/best_model.pt`；**`game_assist_control_fpv/` 为空（FPV 专用模型从未训练）**。

---

## 8. 部署链路（已确认的历史坑）

- 用户实际启动：**根目录 `AuroraDriveUI`**（独立 Mach-O arm64 二进制），不是 `.app`。
- 每次 `swift build` 后必须**同时更新两个目标**：
  `cp .build/release/AuroraDrive AuroraDriveUI`
  `cp .build/release/AuroraDrive AuroraDrive.app/Contents/MacOS/AuroraDrive`
  再分别 `codesign --force --sign - --entitlements AuroraDrive.app/Contents/entitlements.plist <目标>`（entitlements 仅 `com.apple.security.screen-capture`）。
- **本次实测两二进制 MD5 不同**：`AuroraDriveUI=b84c…` vs `.app=b91e…` → 两个部署目标已失同步，需按上面流程重新同步。
- 每次 adhoc 重签改变哈希 → 撤销屏幕录制/辅助功能 TCC 授权 → 用户必须重勾并**完全退出后重启**才生效。

---

## 9. 研究文档与设计的映射（94 篇 md）

用户有一套「累计 5000 次工具调用深度研究、产出白皮书」的知识库（研究索引 `00_index.md`）：
- **Apollo研究**（30/30 完成）：Dreamview 渲染、BEV 感知、EM/Lattice Planner、MPC/LQR/PID 控制、HD Map、CyberRT → 影响 **UI 渲染风格（FSD 驾驶舱）、规划/控制术语、状态机分层**。
- **OpenPilot研究**（5/30）：supercombo 多任务头、controlsd 100Hz 控制环、MPC → 影响 **E2E 端到端思路、DAgger 自训练闭环、降级安全模型**。
- **纯规则研究**（10 篇，文件名存在但内容多为待写/模板）：Mobileye RSS、Apollo rule planner、Safety Envelope、Fallback Detector、Emergency Stop → 直接影响 **`RuleController` 纯规则兜底 + `EscapeController` 脱困 + `DegradeStateMachine` 安全降级**。
- **NVIDIA / UniAD / BEVFormer / ROS2**（目录存在，章节待写）：为后续 VLA/BEV/ROS2 化预留。

> 注意：研究索引里写「OpenPilot 已完成 5/30」「纯规则待开始」，但 `纯规则研究/` 下实际已有 10 个 .md 文件（mobileye_rss、apollo_rule_planner、safety_envelope、formal_verification、cbmc、fallback_detector、emergency_stop、decision_state_machine、odd_management、nv_drivos_safety）—— 索引状态与实际文件不一致。

---

## 10. 关键风险与待办（本报告新发现）

1. 🔴 **双二进制失同步**：`AuroraDriveUI` 与 `.app` 内 MD5 不同，必须按标准流程重新 `cp`+`codesign` 同步。
2. 🟡 **`InferenceEngine.swift` 文件头注释过时**：第 9 行仍写 `vehicle_state=[speed,rpm,gear,...]`，但实际 `buildVehicleState()` 已正确用 `[speed_norm, curvature*5, sin, cos, speed_limit_norm, 0]`。注释与实现矛盾，易误导后续维护。
3. 🟡 **`src/model.py` docstring 过时**：`M9MonoModel` 与 `export_onnx_mono` 注释写 `vehicle_state=[speed/rpm/gear/...]`（与真实契约不符），同样需澄清。
4. 🟡 **训练质量偏弱**：`game_assist_control` 的 `training_log.json` 显示 val_loss 不降反升（0.424→0.483），lr 仅 1e-6，且只训 15 epoch；驾驶模型泛化能力存疑，建议加数据/调 lr/早停。
5. 🟡 **FPV 模型缺失**：`game_assist_control_fpv` 空目录；`deployTrainedModel()` 优先找 fpv 变体，目前靠回退到 `game_assist_control`。
6. 🟡 **`setup_toolchain.sh` 过时**：描述的是 Tauri/Rust/C++（`cpp/`、`frontend/`）架构，但项目实际是 Swift Package，且这两个目录均不存在。属历史遗留文档，应更新或删除。
7. 🟢 **`m9_mono_nn` 变体无人引用**：存在于 models/，代码未加载，建议确认用途或清理。
8. 🟢 **GameMapView 标记被刻意隐藏**：`filteredMarkers` 强制返回 `[]`（数据过旧），地图仅显示底图，标记功能待重新抓数据后启用。
9. 🟢 **视角分类器路由已移除**：训练脚本仍会产出 `view_classifier`，但 App `tick()` 注释说已移除视角分类（直接用 FPV 录制数据训练 M9），相关代码可清理。

---

## 11. 文件路径速查

- 主程序/状态：`AuroraDriveApp.swift`（合集：Theme/DriveState/ContentView/各面板/GameMapView/GameMapCard）
- 引擎：`CaptureEngine / YoloEngine / ControlEngine / InferenceEngine .swift`
- 决策：`DegradeStateMachine / ConfidenceEstimator / RuleController / EscapeController / KeyboardMonitor / RecordEngine .swift`
- 地图：`GameMapView.swift`
- 训练：`src/{model,mono_dataset,train_game_assist,train_mono,trainer,dagger,data_generator,expert_controller,config}.py`
- 导出：`tools/{convert_e2e_to_coreml,convert_yolo_to_coreml,verify_yolo_coreml,export_game_assist_coreml}.py`
- 配置：`configs/{training,inference}.yaml`
- 资产：`models/*.mlmodelc`、`checkpoints/`、`data/raw_clips/`、`recordings/`
- 部署：`AuroraDriveUI`、`AuroraDrive.app/Contents/{MacOS/AuroraDrive,entitlements.plist}`、`Package.swift`、`scripts/setup_toolchain.sh`
