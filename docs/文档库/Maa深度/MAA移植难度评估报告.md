# AuroraDrive × MaaNTE 移植难度深度评估报告

> 基于 AuroraDrive 全部源码（15,520行 Swift）与 MaaNTE 全部源码（95个Python文件 + 26个任务配置 + ~300个Pipeline节点）的逐文件交叉比对评估。
> 
> 评估日期：2026-09-13（原文误写 2025，已更正）
> 评估原则：只看代码，不假设不猜测，每项能力都有代码证据支持。

> **【2026-09-19 现状标注】（下文为评估时点快照，以下结论已被后续实现推翻/更新）**
> - "最大硬缺口是鼠标注入"**已解决**：`MouseController.swift`（`click(at:)` / `scrollWheel(lines:)`，CGEvent mouse 注入）+ `ControlEngine.pressGameKey(typeText:)` 均已落地
> - "任务编排是第二大缺口"**已解决**：`AgentLoop.swift`（LLM tool-calling 规划）+ `AIAgentPanel.swift` 技能循环（15 项技能已移植，13 条验收全过，见 `docs/文档库/探索文档/最终报告.md`；legacy 护栏缺口也已修 adb63ad）
> - 方案 D"复杂功能保持 MaaNTE 独立子进程"**未采用**：MaaNTE 只做工具（ROI/模板/任务定义），不整体接管项目；代码侧以 Swift 原生 + override 为主
> - BidKing（竞价）PR#434 代码已提取到独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并）
> - MaaNTE 模板/ROI 挖掘最终结论：250 个 ROI 节点 override 已生成（181 规则套用 + 32 精确反推，+83 偏移规则）；剩 24 个缺模板节点须实机采集补齐；坐标体系 1470×923 固定（游戏窗口不可改分辨率），运行期 `ScreenshotTargetLongSide=1280` 缩比，OCR 必须 GPU
> - 文中引用的 MaaNTE Python 源码、`build/` 中间产物多数已随 2026-09-19 磁盘清理移至外置硬盘 删除_20260919 目录（评估依据的 MaaNTE/ 框架本体仍在本地）

---

## 一、AuroraDrive 现有能力清单（已核实）

### 1.1 输入层

| 能力 | 文件 | 实现方式 | 覆盖范围 | 缺口 |
|---|---|---|---|---|
| **键盘按下/释放** | `ControlEngine.swift` (241行) | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` → `event.post(tap: .cghidEventTap)` | W/A/S/D/空格/Shift（6个语义动作） | ❌ **没有鼠标点击/滚动/移动**；只有6个固定键位映射 |
| **键盘全局监听** | `KeyboardMonitor.swift` (113行) | `NSEvent.addGlobalMonitorForEvents(matching:.keyDown)` | 物理键盘实时状态捕获 | ✅ 完整 |
| **权限检查** | `ControlEngine.checkPermission()` | `AXIsProcessTrustedWithOptions(nil)` | 辅助功能权限检测 | ✅ 完整 |

**关键发现**：`ControlEngine` 的 `KeyMap` 结构体硬编码了 6 个 CGKeyCode（W=13, A=0, S=1, D=2, 空格=49, Shift=56）。要支持 MaaNTE 的 F/Q/R/E/1-7/Ctrl 等按键，需要扩展 `KeyMap` 并新增 `pressKey(cgKeyCode:duration:)` 方法。**鼠标注入（点击/滚动）完全没有**。

### 1.2 视觉感知层

| 能力 | 文件 | 实现方式 | 覆盖范围 | 缺口 |
|---|---|---|---|---|
| **屏幕捕获** | `CaptureEngine.swift` (639行) | `ScreenCaptureKit` SCStream，30fps持续流 | 全屏画面流，三路回调 | ✅ 完整（但仅返回 NSImage/CGImage/CVPixelBuffer，无内置ROI裁剪） |
| **模板匹配** | `VisualLocator.swift` (491行) | 纯Swift NCC（归一化互相关）多尺度匹配 | 地图定位用，接口 `locate(template:tw:th:scoreThreshold:)` | ✅ 有通用匹配能力，但**只针对大地图场景优化**，没有小图标/UI元素模板库 |
| **OCR** | `SpeedOCRReader.swift` (1244行) | PP-OCRv6 + CNN双模型 CoreML推理 | 车速表数字识别 | ✅ 完整，但**只处理速度表ROI区域**，没有通用OCR能力 |
| **YOLO检测** | `YoloEngine.swift` (807行) | ONNX推理 COCO-80类（车辆/行人/路牌等） | 驾驶场景障碍物检测 | ✅ 完整，**但类别不适合游戏UI识别**（无技能图标/按钮等类别） |
| **网络坐标** | `CoordinateCapture.swift` (635行) | BPF pcap UE5移动包解析 | 世界坐标→地图像素 | ✅ 完整 |

**关键发现**：
- `VisualLocator` 是纯 Swift NCC 实现，**不依赖 OpenCV**，可以复用做 UI 元素模板匹配，但需要从 PNG 提取灰度模板（MaaNTE 用的是 OpenCV imread）
- `SpeedOCRReader` 只处理 180×320 ROI 的车速表区域，**不能直接用于 MaaNTE 的全屏 OCR**（需要重新设计 ROI 和模型输入）
- 没有通用的"在任意位置找模板"工具类，每次用都得自己写裁剪+匹配逻辑

### 1.3 决策/执行层

| 能力 | 文件 | 实现 | 覆盖范围 |
|---|---|---|---|
| **E2E推理** | `InferenceEngine.swift` (432行) | CoreML 异步推理 24Hz | 驾驶模型 |
| **规则控制** | `RuleController.swift` (185行) | YOLO→steer/throttle/brake | 避障规则 |
| **脱困策略** | `EscapeController.swift` (217行) | 倒车→转向→前进状态机 | 卡死恢复 |
| **降级状态机** | `DegradeStateMachine.swift` (250行) | 4档切换（e2e/yolo/recover/rule） | 故障降级 |
| **tick 主循环** | `AuroraDriveApp.swift` tick() (~200行) | 30Hz DispatchSourceTimer | 感知→决策→按键注入全流程 |

**关键发现**：`tick()` 是**纯线性驾驶循环**，每一帧都是：抓帧→推理→选模式→算指令→注入按键。没有任务队列、没有状态机跳转、没有"识别→动作→重新识别"的 Pipeline 概念。MaaNTE 的核心执行模型（Pipeline JSON 状态机）在 AuroraDrive 里**完全不存在对应物**。

### 1.4 进程通信层

| 能力 | 文件 | 实现 |
|---|---|---|
| **Unix socket** | `EngineMain.swift` (849行) | `~/Library/Application Support/AuroraDrive/engine.sock`，JSON命令/心跳 |
| **共享内存** | `EngineMain.swift` + `EngineClient.swift` | `/aurora_frame_v1`，BGRA双缓冲+检测结果区 |
| **协议版本** | `EngineClient.swift` | v2，支持 start/stop/bye/status/upscale/record/reloadmodel/config/ping |

**关键发现**：这套通信系统是 AuroraDrive 特有的，与 MaaNTE 的 MaaHub Socket IPC 完全不兼容。如果要把 MaaNTE 的功能集成进来，要么**重写为 Swift 原生实现**，要么**通过 subprocess 启动 MaaNTE Python Agent 并用 socket 通信**。

---

## 二、MaaNTE 全部功能盘点（按代码复杂度排序）

### 2.1 任务列表（共26个 task + 4个 preset）

```
Daily:                    ClaimRewards, FountainCheckin
CityTycoon:               Furniture, WithdrawMoney
HethereauHobbies:         Fish, BidKing, PinkPawHeist, MakeCoffee, MakeCoffeeLite, 
                          MakeTomatoJuice, Rhythm, Tetris, Volleyball, BagelSpam
RealTimeAssist:           RealTime, OnlineMapNavigation, SoundDodge, AutoFScroll
DatasetCollection:        AutonomousDrivingDataset
UserInfo:                 SyncCharacterAbilityCityAbility
Preset:                   AFK, RealtimeAssistance
```

### 2.2 Python CustomAction 分类（95个文件）

| 类别 | 文件数 | 典型代表 | 代码量 |
|---|---|---|---|
| **简单按钮序列** | ~8个 | `click.py`, `alt_click.py`, `enable_node.py` | 每文件 20-30行 |
| **截图+模板匹配** | ~10个 | `auto_fish.py`, `auto_buy_fish_bait.py`, `auto_sell_fish.py` | 每文件 100-170行 |
| **状态机驱动** | ~5个 | `auto_make_coffee.py`, `furniture_claim.py` | 每文件 100-120行 |
| **复杂AI决策** | ~4个 | `auto_tetris.py` + `Tetris/feats/play.py`(786行), `rhythm/feats/play.py`(505行) | 每文件 500-800行 |
| **网络包解析** | 3个 | `nte_coordinate_api.py`(611行), `coordinate_position.py`(312行) | 每文件 300-600行 |
| **PID控制+寻路** | 6个 | `waypoint_navigator.py`(310行), `route_runner.py`, `map_locator.py`(650行) | 每文件 200-650行 |
| **音频处理** | 3个 | `SoundListener.py`(215行), `DodgeCounterTrigger.py`(95行) | 每文件 100-200行 |
| **三阶段副本** | 4个 | `pinkpaw_core1/2/3.py` + `pinkpaw_common.py` | Core1:613行, Core2:1244行, Core3:2000+行 |
| **MIDI/钢琴** | 5个 | `player.py`, `midi_processor.py`, `key_mapping.py`, `maa_keyboard.py` | 每文件 60-170行 |
| **LLM交互** | 2个 | `bagel_spam_llm.py`(255行) | 255行 |

---

## 三、逐项移植难度评估

### 3.1 🟢 低难度（现有能力覆盖 80%+，额外缺口 <100行）

#### 自动钓鱼（AutoFish）
- **MaaNTE 实现**：`auto_fish.py` (364行) + `auto_buy_fish_bait.py` (169行) + `auto_sell_fish.py` (153行)
- **AuroraDrive 已有**：
  - 键盘注入（WASD+F+ESC）✅
  - 屏幕捕获（截图）✅
  - 模板匹配（VisualLocator 可复用）✅
  - OCR（SpeedOCRReader 需适配）⚠️
- **缺口**：
  - **鼠标点击**：钓鱼小游戏需要点击滑块区域，ControlEngine 无鼠标支持，**需新增 ~50 行** CGEvent mouse injection
  - **模板库**：MaaNTE 有 10 张钓鱼模板图（slider.png, valid_region_left.png 等），需要转换为 Swift 可用的灰度数组
- **预估工作量**：~300 行 Swift
- **预估难度**：⭐⭐

#### 自动咖啡（AutoMakeCoffee / Lite / TomatoJuice）
- **MaaNTE 实现**：`auto_make_coffee.py` (117行) + `auto_make_coffee_lite.py` (129行) + `auto_make_tomato_juice.py` (236行)
- **AuroraDrive 已有**：键盘(WASD+F+ESC)✅，截图✅，模板匹配✅
- **缺口**：鼠标点击（选择关卡/目标顾客）
- **预估工作量**：每个 ~200 行 Swift
- **预估难度**：⭐⭐

#### 家具收取（FurnitureClaim）
- **MaaNTE 实现**：`furniture_claim.py` (47行) + `furniture_choose_property.py` (115行)
- **AuroraDrive 已有**：全部 ✅（模板匹配 + 键盘）
- **缺口**：无
- **预估工作量**：~100 行 Swift
- **预估难度**：⭐

#### 领取奖励（ClaimRewards）
- **MaaNTE 实现**：纯 Pipeline JSON 编排（ClaimRewardsActivity + ClaimRewardsBattlePass 两个开关节点）
- **AuroraDrive 已有**：全部 ✅
- **预估工作量**：~50 行 Swift
- **预估难度**：⭐

#### 提款机（WithdrawMoney）
- **MaaNTE 实现**：`withdraw_money_choose_item.py` (136行) — OCR识别价格 + 排序选品
- **AuroraDrive 已有**：截图✅，模板匹配✅，键盘✅
- **缺口**：鼠标点击（选择商品），OCR需适配到商品区域
- **预估工作量**：~250 行 Swift
- **预估难度**：⭐⭐

#### 自动滚书（AutoFScroll）
- **MaaNTE 实现**：`auto_f_scroll.py` (43行) — 物理F键检测 + 鼠标滚轮
- **AuroraDrive 已有**：键盘F✅
- **缺口**：**鼠标滚轮注入**（`CGEvent.scrollWheelEvent`）
- **预估工作量**：~30 行 Swift（扩展 ControlEngine）
- **预估难度**：⭐

#### 钢琴（AutoPiano）
- **MaaNTE 实现**：`auto_piano/` 5个文件共 ~500 行 — MIDI解析 + 键位映射 + CGEvent PostMessage
- **AuroraDrive 已有**：CGEvent 键盘 ✅，但键位映射只有 WASD+空格+Shift
- **缺口**：扩展 KeyMap 支持 QWERTYUI+ASDFGHJ+ZXCVBNM+Shift/Ctrl（约30个新键位），需重写键盘注入循环
- **预估工作量**：~150 行 Swift（扩展 KeyMap + 新建 PianoPlayer 类）
- **预估难度**：⭐⭐

#### 贝果 Spam（BagelSpam）
- **MaaNTE 实现**：`bagel_spam_llm.py` (255行) + `bagel_spam_text.py` (79行) — 截图→LLM→自动生成标题正文→输入到聊天框
- **AuroraDrive 已有**：截图✅，LLM API调用（可选）✅
- **缺口**：鼠标点击聊天框 + 文字输入（CGEvent Unicode input）
- **预估工作量**：~200 行 Swift
- **预估难度**：⭐⭐

---

### 3.2 🟡 中难度（需要新增子系统或大幅修改现有架构）

#### 在线地图导航（OnlineMapNavigation）
- **MaaNTE 实现**：`Navi/` 14个文件共 ~2700 行 — WebSocket服务 + RouteSession + WaypointNavigator(PID控制器) + AnglePredictor(ONNX) + MapLocator(多尺度NCC)
- **AuroraDrive 已有**：
  - NetworkLocator 坐标获取 ✅（`CoordinateCapture.swift` BPF pcap解码）
  - VisualLocator 模板匹配 ✅（纯 Swift NCC，与 MaaNTE 的 MapLocator 算法相同）
  - Unix socket 通信 ✅（可复用为 WebSocket 替代）
- **缺口**：
  - **PID 控制器**：`AnglePidController` (70行) 完全缺失
  - **Waypoint 序列执行**：`WaypointNavigator.move_to()` (310行) 完全缺失
  - **方向预测 ONNX 模型**：`pointer_model.onnx` 未集成
  - **WebSocket 服务**：AuroraDrive 用 Unix socket，需新增 WebSocket 端点
- **预估工作量**：~800 行 Swift
- **预估难度**：⭐⭐⭐

#### 自动传送 / 实时辅助（RealTime + MapTeleport）
- **MaaNTE 实现**：`MapTeleport/check_teleport_required.py` + `teleport_to_point.py` + `realtime_task.py` + Pipeline 编排
- **AuroraDrive 已有**：键盘(WASD+ESC)✅，模板匹配✅
- **缺口**：鼠标点击地图上的传送点，任务编排状态机
- **预估工作量**：~300 行 Swift + 任务编排框架
- **预估难度**：⭐⭐⭐

#### 粉爪大劫案（PinkPawHeist）
- **MaaNTE 实现**：`pinkpaw/` 6个文件共 ~3500 行 — 三阶段状态机 + ActionHelper + 怪物检测 + 铁门检测 + 撤离检测 + 自适应超时 + Core3 快速识别
- **AuroraDrive 已有**：键盘(AWSD+Space+F+E+1-4+Esc)✅，截图✅，模板匹配✅
- **缺口**：
  - **怪物检测**：需要新的 YOLO 类别或模板匹配库（当前 YOLO 只有 COCO-80）
  - **铁门/撤离点检测**：需要模板匹配
  - **三阶段状态机**：需要新建 TaskRunner
  - **Core3 的 DirectInput**：`CTypes windll.user32` 需替换为 CGEvent（已有基础）
- **预估工作量**：~1500 行 Swift
- **预估难度**：⭐⭐⭐⭐

---

### 3.3 🔴 高难度（需要全新架构或大量新代码）

#### 自动战斗
- **MaaNTE 现状**：**MaaNTE 本身就没有通用自动战斗功能**，只有粉爪副本里有 `fight_until_no_monster()` 这个特例
- **所需能力**：
  1. 怪物血条检测（红色条形模板匹配 或 颜色范围检测）
  2. 技能图标/CD 检测（UI 元素识别）
  3. 距离检测（判断是否在攻击范围内）
  4. 状态机：待命→接近→攻击→闪避→循环
  5. 优先目标选择（距离最近/血量最低/类型优先）
- **AuroraDrive 差距**：以上 5 项全部缺失
- **预估工作量**：~1000-1500 行 Swift + 新模板库
- **预估难度**：⭐⭐⭐⭐⭐

#### 俄罗斯方块 AI（Tetris）
- **MaaNTE 实现**：`Tetris/` 6个文件共 ~1600 行 — SceneGate + TetrisGamePlayer + Board evaluator + PIECES定义 + Beam Search lookahead + T-Spin 检测
- **核心算法**：
  - `evaluate_board()`：7维评估函数（行数/洞穴/高度/过渡/well/边缘/中心堆叠）
  - `_search_best_queue_move()`：Beam Search depth=2-4，权重自适应棋盘占用率
  - T-Spin 检测：front/back corner blocking 判断
- **AuroraDrive 差距**：
  - 棋盘区域裁剪（`extract_board_crop` 40行）需自己实现
  - 方块形状定义（PIECES dict 49行）可复制
  - 评估函数（380行）可直接移植逻辑
  - Beam Search（200行）可直接移植
- **预估工作量**：~800 行 Swift
- **预估难度**：⭐⭐⭐⭐

#### 节奏游戏（Rhythm）
- **MaaNTE 实现**：`rhythm/` 9个文件共 ~1200 行 — DrumDetector(CNN) + LaneLayout + _KeyScheduler + SceneGate + SongSelector
- **核心算法**：
  - 鼓面检测：4轨道 CNN 模板匹配（`detector.py` 189行）
  - 时间补偿：`eta_sec = (trigger_y - center_y) / note_speed_px_per_sec`
  - 按键调度：chord_window_sec + min_tap_interval_sec 约束
- **AuroraDrive 差距**：
  - 没有 CNN 模型加载（只有 CoreML/ONNX）
  - 没有时序按键调度器
- **预估工作量**：~600 行 Swift
- **预估难度**：⭐⭐⭐⭐

#### 音频驱动闪避（SoundDodge）
- **MaaNTE 实现**：`SoundTrigger/` 3个文件共 ~400 行 — Ear(Librosa音频匹配) + Dodger(按键执行)
- **核心算法**：
  - 音频采集：`soundcard` 库，32kHz stereo，环形缓冲区 6.4s
  - 匹配：`scipy.signal.correlate` FFT加速，阈值 0.13（闪避）/ 0.12（反击）
  - 高通滤波：`scipy.signal.butter` 1000Hz cutoff
- **AuroraDrive 差距**：
  - **完全没有音频输入能力**（需新增 AudioCapture 模块，CoreAudio API）
  - 互相关算法需从 scipy 移植到 Swift/Accelerate
- **预估工作量**：~500 行 Swift（含新音频子系统）
- **预估难度**：⭐⭐⭐⭐⭐

---

## 四、架构冲突与整合方案

### 4.1 核心架构差异

```
MaaNTE 执行模型：
  Pipeline JSON → 识别节点(OCR/TemplateMatch/ColorMatch) → 动作节点(Click/Key/Custom) → next跳转
  本质：有限状态机，每步重新识别确认

AuroraDrive 执行模型：
  tick() 30Hz 循环 → Capture → YOLO+OCR+E2E → DriveMode StateMachine → ControlCommand → CGEvent
  本质：连续反馈控制回路
```

这两个模型**本质不同**，强行合并会产生冲突。例如：
- MaaNTE 的钓鱼需要在"等待鱼咬钩"状态下暂停 tick 循环
- AuroraDrive 的 tick 是连续驱动的，每帧都要出控制量

### 4.2 整合方案对比

| 方案 | 描述 | 优点 | 缺点 | 推荐度 |
|---|---|---|---|---|
| **A. 各自独立进程** | AuroraDrive UI 启动 MaaNTE Python Agent 作为子进程，两边通过 socket 通信 | 零改造 AuroraDrive，MaaNTE 原样运行 | UI 和自动化分离，无法统一控制 | ⭐⭐ |
| **B. Swift 重写简单功能** | 钓鱼/咖啡/家具等用 Swift 重写，集成进 AuroraDrive 的 tick 循环 | 统一 UI，统一控制 | 需解决鼠标注入、任务编排问题 | ⭐⭐⭐⭐ |
| **C. Swift 重写全部功能** | 整个 MaaNTE 用 Swift 重写，替换 Python Agent | 最彻底，完全统一 | 工作量巨大，3500+ 行 Python → ~5000 行 Swift | ⭐⭐⭐ |
| **D. 混合模式** | 简单功能集成到 AuroraDrive，复杂功能（战斗/AI游戏）保持 MaaNTE 独立 | 平衡开发效率和代码质量 | 两套系统并存，通信仍需处理 | ⭐⭐⭐⭐⭐ |

**推荐方案 D**：
- 简单功能（钓鱼/咖啡/家具/奖励/提款机/滚书/钢琴/贝果）→ Swift 重写，集成进 AuroraDrive
- 复杂功能（战斗/俄罗斯方块/节奏游戏/音频闪避/粉爪）→ 保持 MaaNTE，通过 AuroraDrive UI 一键启动
- 共同缺口：鼠标注入 + 任务编排框架

### 4.3 必须新增的基础设施

无论选哪个方案，以下基础设施是必须补的：

| 基础设施 | 说明 | 预估工作量 |
|---|---|---|
| **鼠标注入** | `ControlEngine` 新增 `click(x,y)`, `scroll(delta)`, `moveTo(x,y)` 方法 | ~80 行 |
| **任务编排框架** | 类似 MaaNTE Pipeline 的状态机，支持识别→动作→跳转 | ~400 行 |
| **通用模板匹配工具** | 封装 VisualLocator 为通用工具类，支持任意ROI和阈值 | ~100 行 |
| **通用 OCR 接口** | 扩展 SpeedOCRReader 或新建通用 OCR 模块，支持任意 ROI | ~200 行 |
| **MaaNTE 子进程管理** | 启动/停止 MaaNTE Python Agent，同步状态 | ~150 行 |

---

## 五、工作量汇总

### 5.1 分阶段估算

| 阶段 | 功能 | 额外基础设施 | 预估代码量 | 预估工时（人天） |
|---|---|---|---|---|
| **Phase 0** | 鼠标注入 + 任务编排框架 + 通用模板/OCR工具 | 必须 | ~580 行 | 3-4 天 |
| **Phase 1** | 钓鱼/咖啡/家具/奖励/提款机/滚书/钢琴/贝果 | 无额外 | ~1500 行 | 5-7 天 |
| **Phase 2** | 在线导航 + 传送/实时辅助 | WebSocket 服务 | ~1100 行 | 4-5 天 |
| **Phase 3** | 粉爪大劫案（三阶段） | 怪物/铁门模板库 | ~1500 行 | 5-7 天 |
| **Phase 4** | 俄罗斯方块 AI | ONNX Runtime Swift绑定 | ~800 行 | 3-4 天 |
| **Phase 5** | 节奏游戏 | CoreML 鼓面检测模型 | ~600 行 | 3-4 天 |
| **Phase 6** | 音频闪避 | CoreAudio 音频采集 | ~500 行 | 3-4 天 |
| **Phase 7** | 自动战斗 | 怪物检测 + 技能决策 | ~1200 行 | 5-6 天 |

**总计**：~7780 行 Swift 新代码，约 28-36 人天

### 5.2 风险点

1. **鼠标注入稳定性**：CGEvent mouse events 对 Unreal Engine 游戏的兼容性未经测试（keyboard 已验证）
2. **任务编排与驾驶 tick 的冲突**：自动化任务运行时，驾驶 tick 是否继续？需要明确优先级
3. **权限要求**：鼠标注入是否需要额外的 TCC 权限？
4. **MaaNTE 模板图片格式**：MaaNTE 用 OpenCV 读取 PNG，AuroraDrive 需要自己解析图像数据为灰度数组
5. **分辨率适配**：MaaNTE 基于 1280×720，AuroraDrive 需支持任意分辨率，需统一坐标映射

---

## 六、结论

1. **不需要"桥接通信"** — AuroraDrive 自有完整的截屏→推理→按键链路，MaaNTE 的简单功能用 Swift 重写即可集成
2. **最大硬缺口是鼠标注入** — ControlEngine 完全没有鼠标支持，这是所有需要点击功能的先决条件
3. **任务编排是第二大缺口** — AuroraDrive 的 tick 是线性循环，没有状态机/任务队列，需要新建框架
4. **自动战斗在 MaaNTE 本身就没有** — 这是全新的需求，不是移植
5. **音频闪避需要全新音频子系统** — 最困难的单项功能

---

*报告版本：v1.0 | 最后更新：2026-09-13（原文误写 2025）*
