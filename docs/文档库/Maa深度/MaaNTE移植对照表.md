# MaaNTE 移植对照表

> 本文件按**当前源码实测**重写（2026-11-10 复核；上一版为 2026-09-14 的「25 项任务快照」，其面板 ID / 任务清单与现行 `AgentSkillLibrary` 已严重脱节，故整篇替换）。
> 项目：AuroraDrive（本产品品牌）。**MaaNTE 是上游开源项目（AGPL-3.0，Windows 专用 Python 实现），是本项目的蓝本/参考来源，不是本产品品牌。**
> 证据原则：只采信源码事实；下列每条均给 `文件:行号`。凡「代码注释说 A、代码实际做 B」的，以代码为准并在末节标注。

## 一、结论先行：MaaNTE 到底被"蓝本"到什么程度

1. **网络坐标采集是真正的整文件移植**：`Sources/AuroraDrive/Capture/CoordinateCapture.swift`（1811 行）文件头明写「本文件**整体移植自上游开源项目 MaaNTE 的 `nte_coordinate_api.py`**（AGPL-3.0）」(`CoordinateCapture.swift:5-16`)。这是本项目与 MaaNTE 最深的一处对应，且是**活代码**（`pcap_open_live` 实调 :1061、过滤器 :1116）。
2. **坐标标定常量与上游逐位相同**：`kCalibA/B/TX/TY = 0.016394586684750773 / 5.693519256055879e-08 / 6526.474380746091 / 5210.664390686138` (`CoordinateCapture.swift:112-115`)，与上游 `coordinate_position.py` 的 `_CALIBRATION_*` 逐位相同（`MissionConsole.swift:3027-3033` 已比对记录）。
3. **技能面板大量技能来自 MaaNTE，但多数是"键序/节奏照抄"，不是视觉管线移植**：`AIAgentPanel.swift` 文件头声明「技能实现大量移植/参考自上游 MaaNTE」(:6-15)。当前技能库共 **18 项**，其中 `ported:true` **15 项**、`ported:false` **3 项**（`AIAgentPanel.swift:90-127`）。
4. **MaaFramework 整体任务框架未被接管**：本项目只借 ROI / 模板 / 任务定义 / 算法结论；执行通道是自有的 Swift `AgentSkillCenter.runSkill`（`AIAgentPanel.swift` 类 `AgentSkillCenter`）。上游 Windows 的 Win32 视觉/控制管线（PrintWindow / PostMessage 等）**不照抄**，用 SCStream / CGEvent 等价替代（见第四节）。
5. **上游源码不随本仓库分发**（AGPL-3.0 传染性），仅本地参考；品牌层（用户可见字符串 / 标识符）不得出现上游名（2026-10-04 品牌清理，见各文件头「品牌澄清」块）。

## 二、已移植 / 真实对应（按代码核实）

### 2.1 网络定位与坐标（核心，活代码）

| 能力 | 对应源码 | 上游蓝本 | 核实依据 |
|---|---|---|---|
| UE5 移动包位流解析 | `Capture/CoordinateCapture.swift` `bits()`(:126)、`UE5Decoder.decode()`(:296)、`findCandidates()`(:472) | `nte_coordinate_api.py` | 文件头 :5-16；位流扫描+连续性锁定注释 :289、:496 |
| libpcap 抓包 | `CoordinateCapture.swift` `pcap_open_live`(:1061) | `nte_coordinate_api.py` | 过滤器 `(tcp port 30031) or udp`(:1116)，注释明言「改用 MaaNTE 上游同款」(:1109) |
| 世界坐标+朝向标定 | `kCalibA/B/TX/TY`(:112-115)；`kNorth`/`kEast` | `coordinate_position.py` `_CALIBRATION_*` | `MissionConsole.swift:3027-3033`「四个常量与上游逐位相同」 |
| 底图坐标系对齐 | map-2026-08（13056×13056 扩图版），相对旧图平移 (+233,+1738) | MaaNTE-Map `navi-coordinate-calibration.json` | `CoordinateCapture.swift:106-110`、`NetworkLocator.swift:29-34` |
| 位姿协议语义 | `Locate/NetworkLocator.swift`（WebSocket 127.0.0.1:9004，API_VERSION 1.3.0） | 上游 `Navi/` 系列 | `NetworkLocator.swift:5-13`、:19-34 |
| 相机朝向语义（ControlRotation） | `Inference/PointerHeadingReader.swift` | `nte_coordinate_api.py`（UE5 ControlRotation） | `PointerHeadingReader.swift:9`：网络定位解出的是**相机朝向**，身体朝向另读小地图箭头 |

> ⚠️ **NetworkLocator 当前"编译但零实例化"**：`grep -rn "NetworkLocator(" Sources/` 零命中；仅 `App/LocateRuntime.swift:31` 有一个从未赋值的 `var networkLocator: NetworkLocator? = nil`。**现行实际网络定位走 CoordinateCapture**（`AuroraDriveApp.swift:4546-4553` 懒初始化 `cc.start()`）。此处不美化：NetworkLocator 是移植资产，但不在主链路上。

### 2.2 地图 / 路网相关

| 能力 | 对应源码 | 上游蓝本 | 核实依据 |
|---|---|---|---|
| 聚类格边长 52 px | `App/MarkerCluster.swift` `clusterPx`=52 | 上游 `maxClusterRadius: 52` | `MarkerCluster.swift:6-13`、:69、:88 |
| 标定点黄金样本 | `App/MapSelfTest.swift` T1 | 上游 `navi-coordinate-calibration.json` 标定点 | `MapSelfTest.swift:47-50`「外部标准答案，证明与上游同一套」 |
| 底图文件 | `models/bigworldmap-13056.jpg`（13056×13056） | MaaNTE-Map 扩图 | `AuroraDriveApp.swift:4988-4991`、`MapSelfTest.swift:649-679` |
| 地图标记视觉语言 | `App/MissionConsole.swift` | 对齐 maante（配色改为极光） | `MissionConsole.swift:5239`、:5320（仅视觉参考，非算法移植） |

> 注：README 致谢里「全收集地图图源」的真实对应就是**底图 + 标定来源为 MaaNTE-Map**；标记数据另经 nteguide.com 许可（见 README 致谢第 3 行）。

### 2.3 AI 技能（18 项，逐项真实状态）

技能库定义：`AIAgentPanel.swift:90-127`（`AgentSkillLibrary.all`）。执行入口：`AgentSkillCenter.run(skillID:source:)` → `switch`(:618-680)。下表「上游」列只填代码注释/文件头**明确点名**的上游文件；未点名者标「上游对应未在代码中点名」。

| # | 技能 id | 名称 | ported | 实现函数(:行) | 代码点名的上游对应 |
|---|---|---|---|---|---|
| 1 | `auto_login` | 自动登录 | ✅ true | `performAutoLogin`:681 | —（本项目自有：CaptureEngine+Vision OCR+MouseController，非 MaaNTE 移植） |
| 2 | `volleyball` | 自动排球 | ✅ true | `startVolleyballLoop`:791 | `auto_volleyball`（0.6s K 键循环直移植，:27/:808） |
| 3 | `fishing` | 自动钓鱼 | ✅ true | `performFishingLoop`:1305 | 上游对应未在代码中点名（F 抛竿/收杆循环） |
| 4 | `coffee` | 自动做咖啡 | ✅ true | `startCoffeeLoop`:1036 | `AutoMakeCoffee`（F 键 ×20 轮） |
| 5 | `coffee_lite` | 轻量做咖啡 | ✅ true | `startCoffeeLiteLoop`:1073 | `AutoMakeCoffeeLite`（make_count=10） |
| 6 | `bagel_spam` | 贝果刷屏 | ✅ true | `startBagelSpamLoop`:1111 | `BagelSpam`（macOS 内置文案简化版，原版 LLM 文案未做） |
| 7 | `pinkpaw` | 粉爪大劫案 | ❌ false | 走 `performSnapshotStub`:1432 | 上游 PinkPawHeist（多阶段 UI，缺状态机） |
| 8 | `furniture` | 自动收家具 | ✅ true | `performUIClickLoop`:1193 | 上游对应未在代码中点名（OCR 点击循环） |
| 9 | `rewards` | 自动领奖励 | ✅ true | `performUIClickLoop`:1193 | 上游对应未在代码中点名（OCR 点击循环） |
| 10 | `piano` | 自动弹钢琴 | ✅ true | `startPianoLoop`:989 | `AutoPiano`（内置曲目，0.4s 节拍） |
| 11 | `rhythm` | 自动超强音 | ❌ false | 走 `performSnapshotStub`:1432 | 上游音游（音符识别，60fps 性能未验证） |
| 12 | `dodge` | 自动闪避 | ✅ true | `performDodgeLoop`:1349 | 上游对应未在代码中点名（Space+Shift 闪避循环） |
| 13 | `auto_scroll` | 自动滚动 | ✅ true | `performAutoScroll`:1389 | 上游对应未在代码中点名（F 连点+滚轮） |
| 14 | `touch` | 自动抚摸 | ✅ true | `startTouchLoop`:828 | `Touch`（F 交互→点击抚摸区→ESC 直移植 :649/:861） |
| 15 | `drive_dataset` | 驾驶数据采集 | ✅ true | `startDriveDatasetLoop`:883 | `AutonomousDrivingDataset`（2Hz WASD 采样+RecordEngine） |
| 16 | `preset_afk` | 挂机预设 | ✅ true | `startPresetAFK`:944 | `preset/AFK.json`（rewards→furniture→fishing） |
| 17 | `preset_realtime` | 实时辅助预设 | ❌ false | 走 `performSnapshotStub`:1432 | 依赖未实现的实时辅助（realtime） |
| 18 | `tomato_juice` | 自动做番茄汁 | ✅ true | `startTomatoJuiceLoop`:1150 | `AutoMakeTomatoJuice`（简化版，倒计时/双份未实现） |

**技能统计（按代码重算，非文档旧值）**：`ported:true` **15 项**；`ported:false` **3 项**（pinkpaw / rhythm / preset_realtime，均走 `performSnapshotStub` 现场快照+状态回报，不做假动作，`AIAgentPanel.swift:1432`）。

> 挂载口径：`ToolRegistry.swift:151-160` 把 18 个技能挂成 `skill__*` 工具，但 `isImplemented = skill.ported`（:158），`ported:false` 调用返回 `ok=false`。故「挂载 18 个」≠「18 个都可用」。

### 2.4 键集合

`Control/ControlEngine.swift` 的 `GameKey` 枚举 = 上游 MaaNTE 实际使用的键集合（`ControlEngine.swift:7`、:543）。macOS 等价：Windows `GetAsyncKeyState` → `CGEventSource.keyState`，`drive_dataset` 已用（`AIAgentPanel.swift:926-929`）。

## 三、未移植 / 已废弃（不美化）

| 项 | 现状 | 依据 |
|---|---|---|
| 上游整个 MaaFramework 任务/控制流 | **未接管**。上游用 Python + MaaFramework 跑 Windows 任务；本项目只借 ROI/模板/任务定义/算法，执行走自有 Swift `AgentSkillCenter.runSkill` | `AIAgentPanel.swift:6-15` 文件头 |
| 上游 Win32 视觉/控制管线（PrintWindow/PostMessage/GetAsyncKeyState 等） | **不照抄**，用 SCStream(CaptureEngine) / CGEvent(ControlEngine) / CGEventSource.keyState 等价 | 见第四节平台映射表 |
| 上游"新协议" `decodeProtoMove` 路径 | **默认停用**（2026-09-30 根因修复：该路径解出的坐标实测是 S2C 心跳包里的微秒时钟）；仅 `AURORA_LEGACY_PROTO=1` 时启用做对照诊断，定位一律走 `findCandidates` | `CoordinateCapture.swift:285-300`、:320 |
| 上游对 S2C 包一律丢弃、只解 C2S | **已对齐**：S2C 仅保留流量计数，不参与解码 | `CoordinateCapture.swift:314`、:1465 |
| 上游在线导航（OnlineMapNavigation）、实时辅助（RealTime）、音游（Rhythm）、俄罗斯方块（Tetris）、粉爪（PinkPawHeist）、喷泉签到（FountainCheckin）、女巫占卜（WitchDivination）、偷钱（WithdrawMoney）、竞拍王（BidKing）、角色能力同步（SyncCharacterAbilityCityAbility） | **均未移植**：不在现行 18 项技能库内，或仅以 `ported:false` 占位（pinkpaw/rhythm/preset_realtime） | `AIAgentPanel.swift:90-127`（技能库全集）；无对应实现 case |
| `VisualLocator` 模板匹配（旧「自愈式定位」） | **类型存在但零实例化**（`grep "VisualLocator(" Sources/` 零命中）；自愈引擎已退役，现行只做网络定位+三级新鲜度 | 见 README「2026-10-07 删除条目说明」 |

## 四、macOS 平台映射表（Windows → macOS，通用）

| Windows API（上游用） | macOS 等价（本项目用） | 现状 / 依据 |
|---|---|---|
| GetAsyncKeyState | `CGEventSource.keyState` | 已用：`AIAgentPanel.swift:926-929`（drive_dataset） |
| PrintWindow | `SCStream`（CaptureEngine） | 已有 |
| PostMessage / KeyBD | `CGEvent`（ControlEngine） | 已有 |
| 模板匹配 | `VisualLocator` | 类型存在但零实例化（未在主链路使用） |
| YOLO 推理 | `YoloEngine` | 已有（`AuroraDriveApp.swift:176/183/6447` 等实例化） |
| OCR | `SpeedOCRReader` | 已有（`AuroraDriveApp.swift:192`、`LeanAnnotator.swift:170`） |

## 五、核实中发现的代码↔注释不一致（如实记录，未改代码）

1. `AIAgentPanel.swift:26-28` 文件头仍写「auto_login、volleyball 全真实，**其余 8 项**依赖 MaaNTE 视觉管线…macOS 原生版为占位」——但现行技能库已是 **18 项**、`ported:true` **15 项**。该「其余 8 项」是按旧的 10 项口径写的，**已过期**（以 `AgentSkillLibrary.all`（:90-127）为准）。
2. `NetworkLocator.swift` 自称位姿协议移植，但主链路实际未实例化它（走 CoordinateCapture）——「编译但零实例化」，见 §2.1 注。
3. 本文件上一版（2026-09-14「25 项全量」）的面板 ID（`rewards`/`fishing`/`bid_king` 等 25 项）与现行 `AgentSkillLibrary` 的 18 项 id 不对应，属历史快照，已整篇替换。

## 六、复核命令（可复现）

```sh
# 技能库真实 ported 状态
grep -n 'ported:' Sources/AuroraDrive/Agent/AIAgentPanel.swift
# 网络定位移植出处
sed -n '1,20p' Sources/AuroraDrive/Capture/CoordinateCapture.swift
# 标定常量与上游一致性
sed -n '3027,3033p' Sources/AuroraDrive/App/MissionConsole.swift
# NetworkLocator 是否被实例化（应为零命中）
grep -rn 'NetworkLocator(' Sources/
```
