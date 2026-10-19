# 12 · Maa 移植评估与适配

> 整合自 3 篇：`MAA移植难度评估报告.md`（341）+ `MaaNTE-macOS适配验证.md`（173）+ `MaaNTE移植对照表.md`（76）。
> 整合日期：2026-10-18。**只读整合，未删改任何原文档**。
> 评估报告中大量结论已被后续实现推翻，本篇以「⚠️ 已被推翻」逐条标注。

---

## 1. 一句话定位

本篇回答三个问题：**① MaaNTE 的功能移植到 AuroraDrive 有多难？② macOS 上能不能跑 MaaNTE？③ 25 项功能各自移植到哪了？**

---

## 2. 移植难度评估（`MAA移植难度评估报告.md`，2026-09-13 评估）

> ⚠️ **评估时点为 2026-09-13，当时 AuroraDrive 仅 15,520 行 Swift**。此后鼠标注入、任务编排、15 项技能已全部落地（见 §4 对照表）。原文 §六 的 5 条结论里**前 2 条已被推翻**。

### 2.1 评估时 AuroraDrive 现状（原文 §一，已逐项核实）

| 能力 | 评估时状态 | 当前状态（2026-10-18） |
|---|---|---|
| 键盘按下/释放 | ✅ 6 个固定键位（WASD+空格+Shift） | ✅ 扩展到 38 个 GameKey + `typeText` Unicode 注入 |
| **鼠标点击/滚动/移动** | ❌ **完全没有** | ✅ `MouseController.swift`（219 行）`click/doubleClick/scrollWheel/move` |
| 屏幕捕获 | ✅ SCStream 30fps | ✅ 升级到 1280×832 @20fps + 四路回调 |
| 模板匹配 | ✅ `VisualLocator`（纯 Swift NCC，491 行） | ⚠️ **死代码**（全仓零实例化），实际走 `CoordinateCapture` |
| OCR | ✅ `SpeedOCRReader`（只处理速度表 ROI） | ✅ 同（PP-OCRv6 + CNN 双引擎） |
| 网络坐标 | ✅ `CoordinateCapture`（635 行） | ✅ 升级到 1789 行 + 30031 守卫 |
| **任务编排框架** | ❌ **tick 是线性循环，无状态机** | ✅ `AgentLoop.swift`（LLM tool-calling）+ `AIAgentPanel.swift` 15 项技能 |
| 降级状态机 | ✅ `DegradeStateMachine` 4 档 | ✅ 同（+ EmergencyTakeover 应急接管） |
| Unix socket | ✅ v2（start/stop/bye/status...） | ✅ v3（+掩码区 + record + config + ack） |

### 2.2 逐项移植难度（原文 §三，三档分类）

#### 🟢 低难度（现有能力覆盖 80%+，<100 行缺口）

| 功能 | MaaNTE 行数 | 评估缺口 | 评估工时 |
|---|---|---|---|
| 自动钓鱼 | 686 | 鼠标点击 + 模板库 | ~300 行 |
| 自动咖啡（3 种） | 482 | 鼠标点击 | 每个 ~200 行 |
| 家具收取 | 162 | 无 | ~100 行 |
| 领取奖励 | 纯 pipeline | 无 | ~50 行 |
| 提款机 | 136 | 鼠标 + OCR 适配 | ~250 行 |
| 自动滚书 | 43 | 鼠标滚轮 | ~30 行 |
| 钢琴 | ~500 | 扩展 KeyMap 30 个新键位 | ~150 行 |
| 贝果刷屏 | 334 | 鼠标 + 文字输入 | ~200 行 |

#### 🟡 中难度（需新增子系统或大幅修改架构）

| 功能 | MaaNTE 行数 | 缺口 | 评估工时 |
|---|---|---|---|
| 在线地图导航 | ~2700 | PID + Waypoint + ONNX + WebSocket | ~800 行 |
| 传送/实时辅助 | ~1500 | 鼠标 + 任务编排 | ~300 行 |
| 粉爪大劫案 | ~3500 | 怪物检测 + 三阶段状态机 | ~1500 行 |

#### 🔴 高难度（需全新架构或大量新代码）

| 功能 | MaaNTE 行数 | 缺口 | 评估工时 |
|---|---|---|---|
| 自动战斗 | **MaaNTE 本身没有** | 5 项全缺 | ~1200 行 |
| 俄罗斯方块 AI | ~1600 | 棋盘裁剪 + 评估函数 + Beam Search | ~800 行 |
| 节奏游戏 | ~1200 | CNN 模型 + 时序调度器 | ~600 行 |
| 音频闪避 | ~400 | **完全无音频输入** + 互相关移植 | ~500 行 |

### 2.3 架构冲突与整合方案（原文 §四）

**核心差异**：
```
MaaNTE 执行模型 = Pipeline JSON 状态机（识别→动作→重新识别循环，每步重新确认）
AuroraDrive 执行模型 = tick() 连续反馈回路（抓帧→推理→选模式→算指令→注入）
```

**四个方案对比**：

| 方案 | 描述 | 推荐度 |
|---|---|---|
| A. 各自独立进程 | socket 通信 | ⭐⭐ |
| B. Swift 重写简单功能 | 集成进 tick | ⭐⭐⭐⭐ |
| C. Swift 重写全部 | 替换 Python Agent | ⭐⭐⭐ |
| **D. 混合模式** | 简单功能 Swift 重写，复杂功能保持 MaaNTE | ⭐⭐⭐⭐⭐ |

> ⚠️ **实际采用的不是 D**：2026-09-19 现状标注明确「方案 D 未采用，MaaNTE 只做工具（ROI/模板/任务定义参考），不整体接管；代码侧以 Swift 原生 + override 为主」。

### 2.4 必须新增的基础设施（原文 §4.3）

| 基础设施 | 评估工时 | 当前状态 |
|---|---|---|
| 鼠标注入 | ~80 行 | ✅ **已落地** `MouseController.swift` |
| 任务编排框架 | ~400 行 | ✅ **已落地** `AgentLoop.swift` + `AIAgentPanel.swift` |
| 通用模板匹配工具 | ~100 行 | ⚠️ `VisualLocator` 存在但死代码 |
| 通用 OCR 接口 | ~200 行 | ⚠️ `SpeedOCRReader` 只处理速度表 |
| MaaNTE 子进程管理 | ~150 行 | ❌ **未做**（MaaNTE 不作为子进程运行） |

### 2.5 工作量汇总（原文 §五，⚠️ 多数已被实际推翻）

原文估算「~7780 行 Swift 新代码，28-36 人天」，分 8 个 Phase。**实际**：Phase 0（鼠标+任务编排+模板/OCR 工具）已落地；Phase 1（8 项简单功能）14 项已移植（见 §4 对照表）；Phase 2-7（导航/传送/粉爪/方块/节奏/音频/战斗）多数未做。

---

## 3. macOS 适配验证（`MaaNTE-macOS适配验证.md`，2026-09-19）

> 原文标注「正文保留，结论仍有效」。验证对象 `MaaNTE/assets/resource/base/pipeline/`，环境 macOS 游戏窗口 1470×923（retina 2x），`ScreenshotTargetLongSide=1280` → 截图 1280×803。

### 3.1 结论速览

| 项目 | 结果 |
|---|---|
| 场景检测模板（`Common/Scene/*`） | ✅ 零修改可用（实测匹配分 0.97+） |
| `PinkPawHeist_CheckGateOnce`（OCR） | ✅ 零修改可用（实测「强制开启」完全匹配） |
| 底部锚定 UI 模板 | ⚠️ 需 Δy ≈ +83px ROI 偏移 |
| 顶部锚定 UI 模板 | ✅ 无需偏移 |

### 3.2 ROI 偏移规则（核心知识，原文 §3）

**根因（纯几何）**：
```
macOS 窗口 1470×923  --Maa 按长边缩放到 1280-->  1280×803
MaaNTE 基线（Windows）                            1280×720
                                                     高度差 H = 83px
```
Maa 只有等比缩放（`postproc_screenshot()` → `cv::resize`），**不做跨宽高比适配**。窗口比 16:9 高，多出来的 83px **全部加在底部**。

**规则**：
| 方向 | 规则 | 依据 |
|---|---|---|
| **x** | `Δx = 0` | 两空间宽度都是 1280，横向完全对齐 |
| **y** | `Δy ∈ [0, +83]` | 顶部锚定=0；底部锚定=+83；中间线性 |

**安全统一处理**：`新ROI = [x, y, w, h + 83 + 32]`（32 是安全边距），下边界钳到画面底（`y + h ≤ 803`）。

**实测验证**：最大实测位移 = +83（`VolleyballStartButton`），与几何上界完全吻合。反例校正：`BidKingStart` 表面 Δy=+142，其中 59px 是 ROI 自身内边距，真实位移仍是 +83。

**产物**：`build/maa_pipeline_override.json`（**250 个节点 ROI override**，`tools/maa_roi_offset.py` 生成）。181 节点套几何规则 + 32 节点用实测位置反推 + 83 偏移规则。自检 **29/29 覆盖成功，0 失败**。

### 3.3 输入注入契约（macOS 必须保持）

原文 §6 记录的 macOS 输入注入契约（与 AuroraDrive 完全一致）：
```
CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
CGEventPost(kCGHIDEventTap, ...)
kCGKeyboardEventAutorepeat = 0        // 必须每次都是新按下
按住键需以 ~30Hz 重复发送 keyDown
```
**`.combinedSessionState` / `.privateState` 无效**；`cliclick` / `osascript key down` 无法移动角色。

> 💡 **AuroraDrive 已实现**：`ControlEngine.swift:194` 用 `.hidSystemState` + `event.post(tap: .cghidEventTap)`，`refreshHeldKeys` 每 tick 重发 keyDown（`autorepeat=false`）——**与原文契约逐字一致**。

### 3.4 采集工具

| 工具 | 用途 |
|---|---|
| `tools/cgrab.py` | ctypes CoreGraphics 截屏（无 pyobjc 依赖） |
| `tools/watch_collect.py` | 循环采集 + 帧差去重 |
| `tools/hid_key.c` → `hid_key` | HID 层按键注入（唯一能驱动本游戏的方式） |
| `tools/hid_look.c` → `hid_look` | 右键拖拽转视角 |

---

## 4. 移植对照表（`MaaNTE移植对照表.md`，2026-09-14 v3.2）

> 原文 25 项全量。状态图例：✅ 已移植 / ⚠️ 待移植 / ❌ 缺失。2026-09-19 修订了统计与下一步。

### 4.1 全量对照（25 项）

| # | MaaNTE 任务 | 面板 ID | 分类 | 状态 | 实现位置 / 缺什么 |
|---|---|---|---|---|---|
| 1 | ClaimRewards | `rewards` | — | ✅ | `AIAgentPanel` performUIClickLoop（OCR 点击循环） |
| 2 | Furniture | `furniture` | — | ✅ | 同上 |
| 3 | WithdrawMoney | `withdraw_money` | A | ❌ | 需 OCR 定位金额选项 |
| 4 | Fish | `fishing` | — | ✅ | `AIAgentPanel` performFishingLoop（F 抛竿/收杆循环） |
| 5 | BidKing | `bid_king` | C | ❌ | 需识别价格+倒计时；PR#434 已提取至 `BidKing_PR434/` |
| 6 | PinkPawHeist | `pinkpaw` | C | ⚠️ | 多阶段 UI；缺阶段状态机 |
| 7 | MakeCoffee | `coffee` | A | ✅ | F键×20轮（commit 7a7e1e6） |
| 8 | MakeCoffeeLite | `coffee_lite` | A | ✅ | F键×10轮 |
| 9 | MakeTomatoJuice | `tomato_juice` | A | ✅ | F键×20轮（commit 2edce05） |
| 10 | Rhythm | `rhythm` | C | ⚠️ | 音游音符识别；性能未验证 |
| 11 | Tetris | `tetris` | C | ❌ | 棋盘格识别；缺训练数据 |
| 12 | Volleyball | `volleyball` | — | ✅ | K键 0.6s 循环 |
| 13 | BagelSpam | `bagel_spam` | A | ✅ | 内置文案 6 轮刷屏（`typeText` Unicode 注入 f2eb1cd） |
| 14 | RealTime | `realtime` | C | ❌ | 实时战斗辅助；缺专用模型 |
| 15 | OnlineMapNavigation | `online_nav` | C | ❌ | 缺路线生成+自动走 |
| 16 | SoundDodge | `dodge` | — | ✅ | Space+Shift 闪避循环 |
| 17 | AutoFScroll | `auto_scroll` | — | ✅ | F 连点+滚轮 |
| 18 | FountainCheckin | `fountain` | A | ❌ | 复杂多阶段；缺导航+识别 |
| 19 | AutoPiano | `piano` | A | ✅ | 3 首内置曲目，0.4s 节拍循环 |
| 20 | WitchDivination | `witch` | A | ❌ | 固定点击序列+OCR |
| 21 | AutonomousDrivingDataset | `drive_dataset` | B | ✅ | 2Hz WASD 采样 + RecordEngine |
| 22 | SyncCharacterAbilityCityAbility | `sync_ability` | C | ❌ | 多步 UI 操作 |
| 23 | Touch | `touch` | A | ✅ | F→点击→ESC ×10 |
| 24 | preset/AFK | `preset_afk` | D | ✅ | rewards→furniture→fishing |
| 25 | preset/RealtimeAssistance | `preset_realtime` | D | ❌ | 依赖 C 类 realtime 未实现 |

### 4.2 统计（2026-09-19 修订后）

- ✅ 已移植：**14 项**（#1,2,4,7,8,9,12,13,16,17,19,21,23,24）
- ⚠️ 待移植：**2 项**（#6,10）
- ❌ 缺失：**9 项**（#3,5,11,14,15,18,20,22,25）

### 4.3 macOS 平台映射表

| Windows API | macOS 等价 | AuroraDrive 实现 |
|---|---|---|
| GetAsyncKeyState | CGEventSource.keyState | `KeyboardMonitor` ✅ |
| PrintWindow | SCStream（CaptureEngine） | ✅ |
| PostMessage/KeyBD | CGEvent（ControlEngine） | ✅ |
| 模板匹配 | VisualLocator | ⚠️ 死代码 |
| YOLO 推理 | YoloEngine | ✅ |
| OCR | SpeedOCRReader | ✅ |

---

## 5. 对本项目的可借鉴点

| # | 借鉴点 | 说明 |
|---|---|---|
| 1 | **ROI +83px 偏移规则** | macOS 上 MaaNTE 基线 1280×720 → 实机 1280×803 的几何推导，AuroraDrive 已用归一化 float ROI 规避 |
| 2 | **`hid_key` / `hid_look` 采集工具** | macOS 上唯一能驱动本游戏的 HID 层注入方案 |
| 3 | **`cgrab.py` 无 pyobjc 截屏** | 纯 ctypes CoreGraphics，适合 CLI 场景 |
| 4 | **250 节点 override 策略** | 规则套用 + 实测反推 + 安全边距三档——通用的 ROI 适配方法论 |
| 5 | **OCR 正确管线教训** | 缺 det 阶段 + 未外扩 2px + 缩放用 INTER_LINEAR（应 INTER_CUBIC）→ 修正后命中 40/111 |

---

## 6. 已过期 / 未验证项

| 项 | 状态 |
|---|---|
| 评估报告「最大硬缺口是鼠标注入」 | ⚠️ **已推翻** → `MouseController.swift` 已落地 |
| 评估报告「任务编排是第二大缺口」 | ⚠️ **已推翻** → `AgentLoop.swift` + `AIAgentPanel.swift` 已落地 |
| 评估报告推荐方案 D | ⚠️ **未采用** → MaaNTE 只做工具参考，不整体接管 |
| 评估报告「AuroraDrive 15,520 行」 | ⚠️ **已过期** → 当前规模远超（仅 `Sources/AuroraDrive/` 即 68 个 .swift 文件） |
| 评估报告「7780 行 / 28-36 人天」 | ⚠️ **已过期** → 实际只做了 Phase 0 + Phase 1 部分 |
| `CoordinateCapture.swift`（635 行） | ⚠️ **已过期** → 当前 1789 行 |
| 移植对照表未含 `VolleyballWeekly` / `PukaLand` | ⚠️ **遗漏** → 上游新增，对照表未更新 |
| ROI override 250 节点的完整覆盖率 | **未验证**（依赖实机场景覆盖，当前覆盖率 21.1%） |
| 24 个缺模板节点是否已补齐 | **未验证** |

---

## 7. 原文处置建议

| 原文 | 处置 | 理由 |
|---|---|---|
| `MAA移植难度评估报告.md`（341） | **保留，头部加推翻标注** | 逐项难度评估方法论有价值，但 2 条核心结论已推翻 |
| `MaaNTE-macOS适配验证.md`（173） | **保留** | ROI +83px 规则 + 输入注入契约仍是有效知识，结论标注「仍有效」 |
| `MaaNTE移植对照表.md`（76） | **保留，需更新统计** | 25 项对照仍是权威进度表，但缺 VolleyballWeekly / PukaLand |

---

*本篇为整合文档，未删改任何原文件。代码引用均可去本地核对。*
