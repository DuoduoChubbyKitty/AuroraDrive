# AuroraDrive 极光智行 — 项目深度分析报告

> 生成时间：2025-09-07
> 分析范围：全仓源码 + 文档 + 模型资产
> （2026-09-19 现状订正：本文按"现状"定位维护，已核改模型/速度识别/文件统计等过期处；历史描述如与当前不符，以 `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` 与源码为准。）

---

## 一、项目定位与核心目标

**项目名称**：AuroraDrive（极光智行）
**目标**：macOS 第三方游戏《异环》（NTE，Undiscovered Lands）的**视角自动驾驶系统**
**一句话**：屏幕捕获 → CoreML 推理 → 按键注入，实现游戏中的自动开车

### 技术路线选择
- **主驾**：M9 端到端单目模型（RepVGG-A0 + 6维 vehicle_state → steer/throttle/brake）
- **第二套驾驶**：game_assist_control（YOLO接管档的司机）
- **检测**：YOLOv26s（NMS-free 端到端检测，80→4 类映射）
- **速度读图**：PP-OCRv6 微调 int8 整行模型（主路径，`models/ppocrv6_tiny_ft_int8.mlpackage`，OCR 必须 GPU 推理）+ 逐位 CNN（`speed_digit_cnn_v4*`，备用降级）
- **定位**：libpcap 抓 UE5 移动同步包（tcp/30031）→ 位流解码 → 13056×13056 地图（map-2026-08）
- **显示增强**：MetalGoose MetalFX 超分+插帧（仅显示层，**绝不进入决策链路**）

---

## 二、架构总览（四条生命线）

```
┌─────────────────────────────────────────────────────────────────────┐
│                        主线程 (SwiftUI)                              │
│  @Observable DriveState → ContentView → GameViewportView/SidebarView │
├─────────────────────────────────────────────────────────────────────┤
│  tick 队列 (com.aurora.tick, 30Hz, userInteractive)                  │
│  state.tick() → 感知 → 推理 → 置信度估计 → 状态机决策 → 按键注入     │
├─────────────────────────────────────────────────────────────────────┤
│  网络定位队列 (com.aurora.netlocate, 10Hz)                           │
│  runNetworkLocateStep() → NetworkHealer 自愈诊断                      │
├─────────────────────────────────────────────────────────────────────┤
│  抓包线程 (com.aurora.coordinate-capture, 默认)                       │
│  pcap_next_ex 阻塞循环 → UE5位流解析 → worldToMapPixel              │
├─────────────────────────────────────────────────────────────────────┤
│  推理队列 (com.aurora.inference, userInitiated, ~24Hz)               │
│  M9 / game_assist_control / yolo26s 异步推理，结果缓存供 tick 读      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、核心模块详解

### 3.1 捕获层 — CaptureEngine.swift (639行)

**职责**：ScreenCaptureKit 30fps 全屏捕获

**关键设计**：
- 四条回调链路（各自独立，互不干扰）：
  - `onFrame`: NSImage + CGImage（UI显示 + 通用推理）
  - `onYoloFrame`: CVPixelBuffer 直通（YOLO 检测，GPU缩放省转换）
  - `onNativeFrame`: CVPixelBuffer 原生ROI（SpeedOCR + 字模录制）
  - `onUpscaleFrame`: CVPixelBuffer 全分辨率（MetalGoose 插帧）

- **跳帧防堆积机制**：pendingFrame/pendingYoloFrame/pendingNativeFrame 各用一个 lock 保护"只存最新一帧"，主线程处理不过来时旧帧被覆盖丢弃，永不积压

- **缓冲池设计**：nativePool / yoloBufferPool / uiBufferPool / upscalePool — 避免每帧 malloc/free

- **SpeedOCR ROI常量**：
  ```swift
  nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885, width: 0.080, height: 0.050)
  ```
  这是速度表在原生全屏帧中的归一化位置（左上角原点），与 Python `tools/build_speed_glyphs.py` 同源常量对齐

### 3.2 推理层 — InferenceEngine.swift (432行)

**职责**：CoreML 端到端推理（m9_mono / game_assist_control）

**模型接口**（来自 src/model.py 训练端）：
```
输入 image:        [1, 3, 180, 320] Float32 CHW，归一化 [0,1]
输入 vehicle_state: [1, 6]          Float32
         6维 = [speed, rpm, gear, speed_norm, gear_norm, reserved]
输出 steer:    [1] tanh ∈ [-1, 1]
输出 throttle: [1] sigmoid ∈ [0, 1]
输出 brake:    [1] sigmoid ∈ [0, 1]
```

**关键设计**：
- `nonisolated static func` 做预处理和推理——无 self 捕获，跨队列安全
- 可复用缓冲 `reusableImageBuffer` / `reusableStateBuffer`：尺寸不变时不新建 MLMultiArray（~691KB/次）
- `generation` 计数器：防止 reset/reloadModel 后在途结果写回 `lastResult`
- 加载失败冷却 5 秒：避免主线程 30Hz 重试风暴
- 环3预热：模型加载成功后后台跑一次 dummy prediction，把 ANE 计算图编译提前做完

**陷阱记录**（docs/文档库/自动驾驶与功能/pitfalls.md #8）：
- 新版 macOS CoreML 不再隐式编译 `.mlpackage`，必须 `MLModel.compileModel(at:)` 先编译

### 3.3 检测层 — YoloEngine.swift (807行，2026-09-19 核实)

**职责**：YOLOv26s 障碍物检测

**模型接口**：
```
输入: 640×640 CVPixelBuffer，colorSpace=RGB
输出: [1, maxDet, 6] Float32 → [x1,y1,x2,y2,conf,class_id]
```

**关键设计**：
- NMS-free 端到端：无 anchor，去重已在模型内部完成
- 直通路径（fastPathActive）：CaptureEngine 源头 GPU 缩放好的缓冲直接喂入，跳过 NSImage→CGImage 大图转换
- 锁定目标机制（lockedTarget）：手动框选后 EMA 平滑跟踪，丢失超过阈值自动解除
- 类别映射：COCO 80→4（car/pedestrian/sign/obstacle）

### 3.4 速度识别 — SpeedOCRReader.swift (1243行，2026-09-19 核实)

**双引擎**：
1. **PP-OCRv6 主引擎**：`models/ppocrv6_tiny_ft_int8.mlpackage`（int8 量化 + `ppocrv6_tiny_ft_keys.txt` 字符表），整行识别 + CTC 解码 + 取后 3 位；OCR 必须 GPU 推理
2. **逐位 CNN 备用引擎**：`models/speed_digit_cnn_v4*.mlpackage`（5 层卷积）
   - 输入 `[1,1,90,50]`（单通道 90×50）
   - 三槽位逐位识别；PP-OCR 运行时故障时同帧自动降级

2. **字模模板降级**（当前停用）：字模库 45×25 与 CNN 模板 90×50 尺寸不匹配，加载被拒

**三层校验**：
- Layer 1: 量程 0~400 km/h（超出视为噪声）
- Layer 2: 跳变 ≤60 km/h（超限置信度置 0，走降级路径）
- Layer 3: 1秒窗口 3帧投票（容差 ±2 km/h）

**无效帧前置检测**：
- 三槽二值化前景像素 < 80 → 画面里没有速度表，直接判无效

**槽位常量**（与 `tools/build_speed_glyphs.py` 同步）：
```swift
slotCentersNorm: [0.479, 0.496, 0.512]   // 3个数字槽归一化x中心
slotWidthNorm: 0.014                        // 每个槽归一化宽度
slotYMinNorm: 0.897                         // 跳过仪表台顶部反光带
slotYMaxNorm: 0.932                         // 避免切掉数字下半段
```

### 3.5 状态机 — DegradeStateMachine.swift (250行)

**四档降级**：
```
e2e（端到端主驾）→ yolo（YOLO接管）→ rule（纯规则兜底）
                              ↕
                         recover（脱困中）
```

**核心阈值**：
| 参数 | 值 | 含义 |
|------|-----|------|
| degradeHealth | 0.65 | 健康度低于此降级 |
| recoverHysteresis | 0.15 | 滞回量（防阈值边缘横跳）|
| stuckSpeedThreshold | 3.0 km/h | 低于此算"卡住" |
| stuckTimeThreshold | 3.0 s | 卡住持续时长→进脱困 |
| recoverTimeout | 30.0 s | 脱困总超时 |

**优先级链**：`forceRule` > `sportMode` > `warmingUp` > 卡住检测 > 健康梯子

**P2 修复要点**：
- `recoverElapsed` 和 `stuckSeconds` 改用 `Date` 差值累加，不用 dt=1/30（tick 掉拍时 dt 恒 1/30 导致计时漂移）
- 恢复阈值上限 0.99（防 degradeHealth ≥ 0.85 时 recov=1.0 导致永不能恢复的死锁）

### 3.6 控制层 — ControlEngine.swift (373行，2026-09-19 核实)

**事件源选择是整个子系统的命门**：
- `.hidSystemState` ✅（HID层，游戏必响应）
- `.combinedSessionState` ❌（UI键灯亮但游戏不动）
- `.privateState` ❌（被游戏输入层禁用）

**关键陷阱**（docs/文档库/自动驾驶与功能/pitfalls.md #1/#2/#3）：
- `pcap_loop` 回调在 Apple Silicon 上因 PAC（Pointer Authentication Codes）崩溃 → 改 `pcap_next_ex` 阻塞循环
- 无符号下溢 SIGTRAP：UE5位流解码中 `v -= modulus` → 改 `v = v &- modulus`（回绕减法）
- Range 溢出 SIGTRAP：短包时 `searchEnd < 190` → 加 `guard searchEnd > 190`

**refreshHeldKeys 必要性**：
- CGEvent 注入是"一次性事件"，hold() 只在按下瞬间发一个 keyDown
- 游戏输入层只认"新按下"语义，忽略 autorepeat
- 稳定输出档位（如 E2E 直道恒定 throttle=0.98）必须每 tick（30Hz）重发 keyDown

### 3.7 置信度估计 — ConfidenceEstimator.swift (248行)

**三路信号加权融合**：
| 信号 | 权重 | 含义 |
|------|------|------|
| consistency | 0.5 | steer 历史标准差越小越可信 |
| extremity | 0.3 | 转向打满(|steer|>0.95)占比越高越退化 |
| image | 0.2 | 画面亮度异常 → 低分 |

**关键修复**（原退化平衡点问题）：
- E2E 恒输出 idle/恒定值时旧公式算出 0.70 > 降级阈值 0.65 → 死模型永远卡在 e2e 档
- 现用链路存活门控（isLive）：模型未加载/无推理结果/结果过期 → 置信度直接归 0

**长窗口极端检测**：3秒(90帧)内 |steer|>0.95 占比 >70% → 置信度压到 0.30 强制降级（贴墙/打转退化）

### 3.8 脱困策略 — EscapeController.swift (217行)

**三阶段循环**：倒车 1.5s → 反打方向 0.8s → 前进 2.0s，总超时 15s

- 进入脱困时随机选左/右方向（`Bool.random()`），整个脱困过程保持一致
- 前进阶段车速 > 8 km/h → 脱困成功
- 各阶段 confidence 固定 0.3（提示状态机这是低置信操作）

**P0 修复**：只在"从其他档切入 .recover 的那一刻" enter 一次，避免每帧 phase==.done 就 re-enter 抵消超时

### 3.9 网络定位 — CoordinateCapture.swift (635行，2026-09-19 核实)

**移植自 MaaNTE**（AGPL-3.0，不随仓库分发，本地参考）

**UE5位流解析管线**：
```
以太网帧 → 剥14字节头 → IPv4/TCP → payload → packetDirection(只放行c2s)
  → UE5Decoder.decode → Pose(x,y,z,pitch,heading)
  → worldToMapPixel (仿射变换)
  → 13056×13056 大地图像素坐标（map-2026-08）
```

**坐标标定常量**（internals/coordinate-calibration.md）：
```swift
kCalibA = 0.016394586684750773
kCalibB = 5.693519256055879e-08    // 交叉耦合项（含轻微旋转校正）
kCalibTX = 6526.474380746091   // 2026-09-13 13056 扩图版（map-2026-08）；旧 11264 版值 6293.474380746091
kCalibTY = 5210.664390686138   // 旧 11264 版值 3472.664390686138（+233/+1738 刚性平移）
```

**网卡选择**：`pcap_findalldevs` 枚举全部网卡，跳过虚拟网卡，逐个 open+compile+setfilter

### 3.10 自愈引擎 — NetworkHealer（2026-09-19 核实：独立文件 `NetworkHealer.swift` 已不在仓内，`runNetworkLocateStep` 入口在 `AuroraDriveApp.swift`，诊断逻辑并入位置待核实；以下为 2025-09-07 原记录）

**状态机**：
```
healthy → degraded(网络挂，视觉顶班) → diagnosing → repairing → healed(切回网络)
```

**诊断顺序**：BPF权限 → 网卡是否存在 → 游戏是否运行（端口30031）→ unknownButDead

**修复动作**：BPF权限丢失 → restartCapture()（不弹窗，权限由 BPFSetup 管理）

**注意**：视觉定位引擎（VisualLocator）已实现但未接线——`locate(template:)` 唯一调用点是自身自检，NetworkHealer 的视觉分支目前恒返回 nil

### 3.11 BPF权限管理 — BPFSetup.swift (162行，2026-09-19 核实)

**一键安装流程**：
```
App内密码弹窗 → osascript → /tmp/aurora_bpf_setup.sh
  → 写 /usr/local/bin/aurora-bpf-setup.sh (chmod 666 /dev/bpf*)
  → 写 /Library/LaunchDaemons/com.aurora.bpf-setup.plist (RunAtLoad)
  → launchctl load
  → 立即 chmod 666 /dev/bpf*
```

一次输入，永久生效（重启后 LaunchDaemon 自动恢复权限）

### 3.12 App Nap 对抗 — AppDelegate.applicationDidFinishLaunching

六重锁保证全屏游戏时 tick 不掉帧：
1. `disableAutomaticTermination`
2. `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` → 持有 napToken
3. `setpriority(PRIO_PROCESS, 0, -20)` → nice=-20
4. CGEventTap `.listenOnly` 空 tap → 系统判定进程在实时处理输入
5. 768MB mlock → 让系统不敢冻结（实测经验值，不要改小）
6. 主线程 `THREAD_TIME_CONSTRAINT_POLICY` period≈33.3ms

### 3.13 录制引擎 — RecordEngine.swift (424行，2026-09-19 核实)

**双模式**：
- 训练录制：640×360 JPEG + controls.csv（供 DAgger 自训练）
- 字模录制：原生分辨率速度表 ROI PNG（供字模训练）

**磁盘保护**：启动时清理最旧 clip，maxClipsPerKind=10（防 30fps × 640×360 无上限累积撑爆磁盘）

**背压机制**：pendingWrites > 1 时丢帧（帧号不入队不自增，保持写入帧号连续）

**P1 修复**：stop() 时 writeQueue.sync flush CSV 句柄，防 fd 泄漏

---

## 四、Python 训练侧

### 4.1 核心训练文件

| 文件 | 用途 |
|------|------|
| `src/model.py` | M9 端到端模型定义（RepVGG-A0 + PointNet-Lite + 融合头） |
| `src/config.py` | 全局配置常量（地图/交通/训练参数） |
| `src/mono_dataset.py` | 单目数据集加载器（支持 v1_old / v2_new 两种录制格式） |
| `src/train_mono.py` | M9-Mono 训练脚本（RepVGG-A0 骨干 + 6维 state → 三输出） |
| `src/train_game_assist.py` | 一键训练入口（由 App 调起） |

### 4.2 模型架构（src/model.py）

**M9MonoModel**：
```
输入: image [1, 3, 180, 320] + vehicle_state [1, 6]
  → RepVGG-A0 骨干（共享）
    → Stage0: Conv3×3 stride2, 3→48, 224→112
    → Stage1: 2 blocks, 48→48, 112→56
    → Stage2: 4 blocks, 48→96, 56→28
    → Stage3: 14 blocks, 96→192, 28→14
    → Stage4: 1 block, 192→1280, 14→7
    → Global AvgPool → 1280 维特征
  → FusionHead: 1280 + 6 → [steer, throttle, brake]
```

**训练参数**（config.py）：
- 有效 batch = 4 × 4（梯度累积）= 16
- LR: warmup 5 epochs → cosine annealing，base 3e-4，min 1e-6
- Weight decay: 5e-4（BN/bias 不加 WD）
- Grad clip norm: 1.0
- 数据增强: 亮度±20% / 对比度±15% / 高斯噪声 / 模糊 / 水平翻转(10%)

### 4.3 数据流

```
data/raw_clips/clip_<ts>/
  ├── frames/00000.jpg (640×360 JPEG)
  ├── controls.csv (t_sec,frame,steer,throttle,brake)
  └── view.txt (FPV/TPV)
```

训练时 `MonoClipsDataset` 解析 → `make_train_val_split`(9:1) → DataLoader → 训练 → 导出 ONNX → CoreML `.mlmodelc`

---

## 五、模型资产清单

| 模型 | 路径 | 格式 | 说明 |
|------|------|------|------|
| m9_mono | `models/m9_mono.mlmodelc` | CoreML 编译 | 端到端主驾 |
| m9_mono.onnx | `models/m9_mono.onnx` + .data | ONNX | 训练导出中间产物 |
| game_assist_control | `models/game_assist_control.mlmodelc` | CoreML 编译 | YOLO接管档司机 |
| game_assist_control_int8 | `models/game_assist_control_int8.mlpackage` | CoreML int8 | 量化版（2026-09-12 量化交付，int8 保留） |
| yolo26s | `models/yolo26s.mlmodelc` | CoreML 编译 | YOLOv26s 检测（int8 量化版 `yolo26s_int8.mlpackage` 保留） |
| ppocrv6_tiny_ft_int8 | `models/ppocrv6_tiny_ft_int8.mlpackage` + `ppocrv6_tiny_ft_keys.txt` | CoreML int8 | 速度识别**主路径**（PP-OCRv6 微调，2026-09-12 交付，OCR GPU-only） |
| speed_digit_cnn_v4 | `models/speed_digit_cnn_v4.mlpackage`（int8 版 `speed_digit_cnn_v4_int8.mlpackage`） | CoreML | 速度识别**备用**（5 层卷积，需运行时编译） |
| speed_digit_cnn_v5 | `models/speed_digit_cnn_v5.pth` | PyTorch | 最新 CNN 权重（未导出 CoreML） |
| trocr-base-printed | `models/trocr-base-printed/` | HF 权重（~1.2G） | PPOCR 印刷体参考模型 |
| checkpoints | `checkpoints/`（game_assist_control、game_assist_control_fpv、m9_mono、view_classifier） | PyTorch | 4 个训练 checkpoint 目录 |
| speed_glyphs.json | `models/speed_glyphs.json` | JSON | 字模库（10个数字 0-9） |
| speed_templates.json | `models/speed_templates.json` | JSON | 旧模板库（停用） |

**地图资产**：
- `bigworldmapSecond.png`（6.9MB）— 11264×11264 全收集地图图源（MaaNTE）
- `FINAL_complete_map_database.json`（7.5MB）— nteguide.com 全收集标记数据

### 2026-09-19 磁盘清理说明（本节及上表为清理后现状）

以下路径**已从本地移出**，统一迁至外置硬盘 `/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/（⚠️ 2026-09-29 路径订正：实际在「自动驾驶项目半成品版本1.0到10.0」目录内，原文少两级）`（完整对照表见 `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` §七）：
`data/web_frames`（19G）、`build/vid_*.mp4`、`build/template_scratch`、`build/contact`、`build/ocr_batch(2)`、`data/_gray_cache`、`tools/ppocrv6_finetune/output`（可重训再生，内容已迁外置硬盘，本地目录已删）、`.build`（swift build 自动重建）。

本地保留的相关数据：`build/new_templates`（291 条目 / 268 张 png）、`build/dig_*.json`（52 份）、`build/maa_pipeline_override.json`（250 节点 override）、`data/mac_shots`（208 张）。

**MaaNTE 现状速记（2026-09-19）**：250 个 ROI 节点 override 完成；剩 24 个缺模板节点待实机采集；「重要剧情跳过」实为普通跳过按钮（非独立功能）。坐标体系 1470×923 固定不可变，运行期长边缩到 1280（截图 1280×803），OCR 必须 GPU；铁律：**不降帧率、不打补丁绕过**。

---

## 六、已完成部分

### ✅ 核心驾驶功能
1. **端到端主驾**（M9 模型，30Hz 推理）
2. **四档降级状态机**（e2e → yolo → recover → rule）
3. **YOLO 障碍物检测**（yolo26s，直通路径优化）
4. **规则控制器**（YOLO 检测 → steer/throttle/brake 决策表）
5. **脱困策略**（倒车→转向→前进三阶段循环，15s 超时保护）
6. **置信度估计**（三路信号融合：一致性+极端度+亮度）
7. **速度表 OCR**（CNN v4 主引擎 + 三层校验）
8. **网络定位**（libpcap tcp/30031 → UE5位流 → 世界坐标 → 地图像素）
9. **自愈引擎**（5种诊断 + 修复仲裁，网络挂→视觉顶班）
10. **BPF 权限一键安装**（LaunchDaemon 开机自启）
11. **App Nap 六重对抗**（768MB mlock + CGEventTap + nice=-20 + 实时约束）
12. **跳帧防堆积**（pendingFrame 只存最新，主线程卡时旧帧覆盖丢弃）
13. **行驶录制**（训练数据收集，磁盘上限保护）
14. **一键训练**（App 内拉起 Python 训练进程，训完热替换模型）
15. **MetalFX 超分+插帧**（Vendor/MetalGoose，仅显示层）
16. **全收集交互地图**（64瓦片懒加载缓存，实时玩家位置+朝向）
17. **UI 键盘可视化**（实时显示 AI 注入的按键状态）
18. **调试日志**（1Hz 摘要写 `/tmp/aurora_debug.log`，10MB 封顶自动覆盖）

### ✅ 文档体系
- README.md / README.en.md（中英文入口）
- DEVELOPER_GUIDE.md（二级开发文档）
- 三级文档：架构/网络定位/速度识别/视觉推理/控制安全
- 四级文档：UE5位流解析/坐标标定/BPF/LaunchDaemon/AppNap/踩坑实录

---

## 七、未完成部分与已知问题

### ⚠️ 未完成功能

1. **视觉定位未接线**（VisualLocator 引擎休眠）
   - `locate(template:)` 唯一调用点是自身自检
   - NetworkHealer 的视觉分支目前恒返回 nil
   - 网络挂时不会真正切换到视觉定位

2. **速度 CNN v5 未部署**
   - `models/speed_digit_cnn_v5.pth` 是最新权重，但未导出为 CoreML
   - 当前主路径已切换为 **PP-OCRv6 微调 int8 整行模型**（`models/ppocrv6_tiny_ft_int8.mlpackage`，2026-09 订正）；逐位 CNN（v4 系）降为备用引擎，"v4 INT4量化运行中"为旧表述

3. **Python Sidecar HMI（Web 可视化）**
   - PRD 和 TechArch 已有详细设计（3页面：驾驶舱/导航台/感知调试）
   - 但这是 Route A（Python sidecar）；"Route B 纯 C++ 迁移"也只是历史中间路线——**当前架构为 Swift 原生**（`Sources/AuroraDrive` 31 个 Swift 文件 + `AuroraDriveUserAgent` + `AuroraDriveShared`，0 个 C++/mm；见 `docs/文档库/自动驾驶与功能/01-architecture.md`，2026-09-19 订正）
   - 相关 `.trae/documents` 头注已按此更正（2026-09-19）

4. **车道级路由**（PRD 第六节"本期不包含"）
5. **SR 感知可视化**（BEV 鸟瞰图 + 检测框）
6. **真实 M9 模型推理接入**（当前 expert_controller 作为仿真驾驶源）

### 🐛 已知问题与陷阱

1. **NetworkLocator.swift 是死代码**（626行，WebSocket 客户端，零实例化）
   - 保留作"外接 MaaNTE 助手进程"备用通道
   - 编译但不跑

2. **NetworkPacketCapture.swift 已移 legacy/**
   - 旧抓包实现，不在 Package.swift sources

3. **字模模板尺寸不匹配**（SpeedOCRReader 注释）
   - 字模库 45×25 与 CNN 模板 90×50 尺寸不匹配，字模降级路径加载被拒

4. **CIImage 裁剪 Y 翻转**（踩坑 #5）
   - ScreenCaptureKit/CVImageBuffer 行序与 CGImage 坐标系 y 方向相反
   - 已修复但需注意跨框架坐标语义

5. **CoreML 加载 .mlpackage 必须显式编译**（踩坑 #8）
   - `MLModel.compileModel(at:)` 先编译，再 `MLModel(contentsOf: compiled)` 加载

6. **macOS 每次重启 BPF 设备节点重建**（踩坑 #6）
   - 已用 LaunchDaemon 解决，但首次启动仍需用户输入密码

---

## 八、系统红线（架构铁律）

> **插帧/超分只作用于显示叠加层，绝不进入「捕获→推理→按键」决策链路。**

这是项目最核心的架构约束，任何改动都不能破坏这条红线。

---

## 九、关键设计决策总结

| 决策 | 选择 | 原因 |
|------|------|------|
| 主循环驱动 | DispatchSource Timer | 不受 App Nap 影响（RunLoop Timer 会掉到 8Hz） |
| 按键事件源 | `.hidSystemState` + `.cghidEventTap` | 游戏只认 HID 层，其他层被忽略 |
| 持键维持 | 每 tick 重发 keyDown | 游戏输入层忽略 autorepeat，只认"新按下" |
| 帧积压处理 | pendingFrame 只存最新 | 主线程卡时旧帧被覆盖丢弃，强制跳帧 |
| 计时精度 | Date 差值替代 dt | tick 掉拍时 dt=1/30 导致脱困/卡死计时漂移 |
| 模型热替换 | reloadModel() 递增 generation | 在途推理结果过期后丢弃，防旧结果写回 |
| 速度来源 | 真实 CNN 读数替代遥测模拟 | 卡死判据由 speedValid 门控，避免"读不到→误判卡死" |
| 置信度退化平衡点 | 链路存活门控直接归零 | 旧公式恒算出 0.70 > 降级阈值 0.65 的死锁 |
| 死代码保留 | NetworkLocator/NetworkPacketCapture | 备用通道/历史参考，注释标注清楚 |

---

## 十、文件统计

| 目录 | 文件数 | 总行数（约）|
|------|--------|------------|
| Sources/AuroraDrive/ | 31 .swift | ~19,200（2026-09-19 实测） |
| Sources/AuroraDriveUserAgent/ + AuroraDriveShared/ | 2 .swift | ~70 |
| src/ | 6 个顶层 .py（另有 ml/、assist/ 子包） | ~2,240（2026-09-19 实测） |
| tools/ | 30+ .py | ~5,000 |
| docs/文档库/自动驾驶与功能/ | 5 .md | ~1,500 |
| docs/文档库/自动驾驶与功能/ | 5 .md | ~1,000 |
| **合计** | **~44+（不含 tools）** | **~23,000+** |

---

## 十一、如何快速验证系统状态

```bash
# 环境检查（不启动）
./run.sh --status

# 启动
./run.sh

# 诊断日志
tail -f /tmp/aurora_debug.log

# BPF 权限检查
ls -l /dev/bpf0   # 应为 crw-rw-rw-

# 网络定位检查
lsof -i :30031    # 应有游戏进程

# YOLO 自检
./AuroraDriveUI --yolo-selftest <图片路径>

# 速度 OCR 自检
./AuroraDriveUI --speed-selftest <目录>

# 插帧引擎自检
./AuroraDriveUI --upscale-selftest
```

---

*本报告由 AI Agent 自动生成，基于全仓源码静态分析。*
