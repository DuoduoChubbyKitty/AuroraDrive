# 9 · 运行期开关全表（GPU A/B 实验用）

> 目标：把驾驶态 **GPU 活跃驻留 36.4%**（待机 0.7%）拆开，逐个关功能对比。
> 本文只做一件事：**列出项目里已存在的、不改代码就能切的开关**，并明确哪些功能根本没有开关。
>
> 全部条目均为 grep 实测所得，每条带 `文件:行`。**不存在本文未列出的环境变量名。**

---

## 0. 先看这张表：七大 A/B 对象的「最省事关法」

| # | 功能 | 能运行期关吗？ | 最省事的关法 | GPU 相关性（实测配置） |
|---|---|---|---|---|
| 1 | **YOLOPX 检测**（A-YOLOM 三合一） | ⚠️ 半能（换族能关 GPU 大头，但不能真停） | 环境变量 `AURORA_AYOLOM=0`（切 legacy 族）或 `AURORA_YOLOPX_INTERVAL_MS=200`（限频） | **高**：`computeUnits = .all`（`YolopxEngine.swift:746`） |
| 2 | **叠加层 / HUD 绘制** | ✅ 能（但只关掉小 HUD，不是游戏覆盖层） | 环境变量 `AURORA_DISABLE_HUD=1` | 低-中（WindowServer 合成成本） |
| 3 | **小地图 / 地图渲染** | ✅ 能（UI 侧，不点即不画） | 不用开关：**默认就不开**；`AURORA_MAP_NO_MARKERS=1` 单独关标记 | 低（SwiftUI 光栅化，非 Metal 重负载） |
| 4 | **速度 OCR** | ❌ 不能真正关（开关只改加载时机） | 无停用开关；`AURORA_SKIP_MODEL_LOAD=1` **无效于关闭**（见 §5.4） | **零**：`.cpuAndNeuralEngine`（`SpeedOCRReader.swift:433`） |
| 5 | **第二司机**（`game_assist_control`） | ⚠️ 半能（只能降频到 1/5） | 环境变量 `AURORA_ASSIST_KEEPALIVE=0` → **注意这是反的，见 §5.5** | **高**：`computeUnits = .all`（`InferenceEngine.swift:164`） |
| 6 | **指针朝向识别**（`pointer_heading`） | ❌ 不能（无停用开关） | 无运行期开关，需改代码（§5.6） | **零**：`.cpuAndNeuralEngine`（`PointerHeadingReader.swift:290`） |
| 7 | **插帧 / upscale** | ✅ 能（默认就是关的） | **默认关**（`upscaleEnabled = false`）；开关是 App 内 UI 按钮 | **高**：Metal（`GooseUpscaler`），开了才占 |

> **一句话结论**：真正吃 GPU 的是 #1 YOLOPX、#5 第二司机、#7 插帧（Metal）。#4 速度 OCR 和 #6 指针朝向**不碰 GPU**，关它们对 36.4% 没贡献，别浪费一轮实验。

---

## 1. 环境变量读取点全表（58 处表达式 / 23 个文件）

### 1.1 集中式开关表（`AuroraFlags.swift`，74 个，走 `static let` 只读一次）

文件：`Sources/AuroraDrive/Core/AuroraFlags.swift`。**唯一读取入口**在 `:91` 的 `raw(_:)`，所有 `AuroraFlags.xxx` 都经过它。默认值以代码里的 `default:` 参数为准。

| 变量名 | 声明行 | 作用 | 默认值 |
|---|---|---|---|
| `AURORA_UI_LOCAL` | :138 | 强制 UI 本地模式，不连引擎 | 关 |
| `AURORA_DAEMON_MODE` | :141 | Daemon 模式，不激活窗口 | 关 |
| `AURORA_OBSERVE_ONLY` | :145 | 观测模式，强制 `controlDisabled=true` | 关 |
| `AURORA_TCC_TEST` | :148 | 只影响 TCC 自检日志字段 | 未设 |
| `AURORA_API_KEY` | :152 | LLM API Key（仅 CLI） | 未设 |
| `AURORA_ENGINE_DIAG_SKIP_TCC` | :159 | 诊断：跳过引擎 TCC fail-fast | 关 |
| `AURORA_ENGINE_DIAG_CAPTURE_ONLY` | :162 | 诊断：引擎只抓屏不注入按键 | 关 |
| `AURORA_LEGACY_PROTO` | :165 | 抓包走旧协议解码 | 关 |
| `AURORA_NIC_TEST_TARGET` | :168 | 网卡自检目标地址 | `49.232.46.87` |
| `AURORA_AYOLOM` | :175 | 感知模型族选择 | 未设 → A-YOLOM |
| `AURORA_INFER_QOS` | :178 | 推理队列 QoS 覆盖 | 未设 |
| `AURORA_YOLOPX_INTERVAL_MS` | :181 | YOLOPX 最小推理间隔 ms | `0`（不限） |
| `AURORA_YOLOPX_LETTERBOX_MAIN` | :184 | letterbox 放主线程 | 关 |
| `AURORA_SKIP_MODEL_LOAD` | :187 | OCR 模型延迟加载 | 关 |
| `AURORA_OCR_DEBUG` | :190 | OCR 调试打印 | 关 |
| `AURORA_QUEST_OCR` | :201 | 任务面板 OCR（**默认开**） | 开（`=0` 关） |
| `AURORA_DISABLE_OPTICAL_FLOW` | :211 | 关闭光流 | 关 |
| `AURORA_EGO_CHECK` | :235 | 自车运动校验（**唯一每次现读**） | 未设=开，`off` 关 |
| `AURORA_EGO_MAX_FWD` | :238 | 自车校验：最大前向速率 | `0.5` |
| `AURORA_EGO_MAX_FLOW_PX` | :240 | 自车校验：最大光流位移 | `80.0` |
| `AURORA_EGO_RESIDUAL_RATIO` | :242 | 自车校验：残差比阈值 | `0.6` |
| `AURORA_EGO_MIN_CONF` | :244 | 自车校验：最低置信度 | `0.35` |
| `AURORA_EGO_AREA` | :219 | 自车框屏蔽面积阈值（0=关屏蔽） | `0.04` |
| `AURORA_EGO_DIAG` | :258 | 自车运动诊断打印 | 关 |
| `AURORA_KEY_REFRESH_HZ` | :270 | 按住键重发频率 Hz | `0`（不节流） |
| `AURORA_LANEKEEP_TIERS` | :280 | 车道保持生效档位 | `rule,yolo` |
| `AURORA_RELEASE_ALL_EVERY_TICK` | :283 | 恢复每帧无条件 releaseAll | 关 |
| `AURORA_STUCK_SECONDS` | :286 | 零速多少秒拉横幅 | `30` |
| `AURORA_ENABLE_BG_DRIFT` | :289 | 主题背景漂移动画 | 关 |
| `AURORA_SEG_STRAIGHTEN_DEG` | :292 | 分段：触发回正偏角 | `15.0` |
| `AURORA_SEG_STRAIGHTEN_DONE_DEG` | :294 | 分段：回正完成偏角 | `8.0` |
| `AURORA_SEG_HANDOVER_M` | :296 | 分段：交接最小距离 | `15.0` |
| `AURORA_SEG_HANDOVER_FRAMES` | :298 | 分段：交接最小帧数 | `10` |
| `AURORA_SEG_CORRIDOR_M` | :300 | 分段：走廊容差 | `8.0` |
| `AURORA_SEG_MAP_TIMEOUT_S` | :302 | 分段：地图段超时 | `20.0` |
| `AURORA_CORNER_LOOKAHEAD_M` | :309 | 弯道：提前量 | `40.0` |
| `AURORA_CORNER_HEADING_TOL_DEG` | :311 | 弯道：方向匹配容差 | `60.0` |
| `AURORA_CORNER_DEADBAND_DEG` | :313 | 弯道：转向死区 | `8.0` |
| `AURORA_CORNER_SAT_DEG` | :315 | 弯道：转向饱和角 | `35.0` |
| `AURORA_CORNER_PASSED_M` | :317 | 弯道：已过点距离 | `15.0` |
| `AURORA_CORNER_CONE_DEG` | :319 | 弯道：前方锥半角 | `75.0` |
| `AURORA_CORNER_TIGHT_R_M` | :321 | 弯道：急弯半径阈值 | `80.0` |
| `AURORA_CORNER_TIGHT_SPEED` | :323 | 弯道：急弯建议限速 | `40.0` |
| `AURORA_JUNC_LOOKAHEAD_M` | :325 | 路口：提前量 | `45.0` |
| `AURORA_JUNC_APPROACH_M` | :327 | 路口：开始转向距离 | `25.0` |
| `AURORA_JUNC_EXCLUDE_DEG` | :329 | 路口：排除来路容差 | `35.0` |
| `AURORA_JUNC_FORK_TOL_DEG` | :331 | 路口：Y 形岔路容差 | `25.0` |
| `AURORA_JUNC_REACH_RATIO` | :333 | 路口：主路判据长度比 | `1.2` |
| `AURORA_MAP_WINDOW` | :340 | 启动即开独立地图窗口 | 关 |
| `AURORA_MAP_TILE_WINDOW` | :352 | 底图走视野窗口（0=源图直裁） | 开（`=0` 关） |
| `AURORA_BASEMAP_GRADE` | :359 | 底图调色 | 开（`=0` 关） |
| `AURORA_MAP_SPAN_M` | :361 | 地图默认视野（米） | 未设 |
| `AURORA_MAP_LAYERS` | :363 | 图层位（1=路网 2=骨架 4=POI） | 未设（代码默认 1\|2） |
| `AURORA_MAP_LEGACY_MARKERS` | :365 | 走旧 ForEach 标记路径 | 关 |
| `AURORA_MAP_FILTER_BAR` | :367 | 中栏组筛选条 | 开（`=0` 关） |
| `AURORA_MAP_NO_MARKERS` | :369 | 完全跳过标记图层 | 关 |
| `AURORA_MAP_MAX_LABELS` | :371 | 标签显示上限 | 未设 |
| `AURORA_MAP_NO_LOADNORM` | :374 | 关地图自检负载归一化 | 关 |
| `AURORA_MAP_LABEL_SPAN_M` | :376 | 标签距离门槛（米） | 未设 |
| `AURORA_MAP_CLUSTER_PX` | :378 | 聚类格边长 px | 未设 |
| `AURORA_MAP_CLUSTER_PRIORITY` | :380 | 聚类代表点优先级 | 未设 |
| `AURORA_MAP_CLUSTER_TRACE` | :382 | 聚类分段计时打印 | 关 |
| `AURORA_MAP_DEFAULT_GROUPS` | :384 | 默认开启组 | 未设 |
| `AURORA_MARKER_TAXONOMY` | :386 | 标记词表路径覆盖 | 未设 |
| `AURORA_ROUTE_GRAPH` | :388 | 路网图路径覆盖 | 未设 |
| `AURORA_ROUTE_STRAIGHT` | :390 | 路线规划直线优先 | 关 |
| `AURORA_ROUTE_TURN_W` | :392 | 拐弯惩罚权重 | 未设 |
| `AURORA_PERF` | :399 | 打开 PerfBus 打点 | 关 |
| `AURORA_PERF_ROUNDS` | :401 | selftest 每指标轮数 | `6` |
| `AURORA_LOG_SYNC` | :403 | 日志改逐行同步写 | 关 |
| `AURORA_DISABLE_HUD` | :405 | 跳过帧率 HUD 安装 | 关 |
| `AURORA_BENCH_DRAIN` | :407 | `--mc-map-bench` 每轮排空队列 | 关 |
| `AURORA_BENCH_DRAG_PX` | :410 | bench 每轮视口平移 px | `8` |
| `AURORA_CACHE` | :418 | 缓存层总开关 | 开（`=0` 关） |

> ⚠️ `AuroraFlags.swift:426` 的 `all` 表也登记了 74 条，与实际声明数一致（`--flags-help` 可现场打印：`./AuroraDriveUI --flags-help`）。

### 1.2 总表外、直接读环境的开关（17 个 —— 这些不在 `AuroraFlags`，但真实存在）

| 变量名 | 文件:行 | 作用 | 默认值 |
|---|---|---|---|
| `AURORA_DIGEST` | `App/AuroraDriveApp.swift:4297`、`Control/ControlEngine.swift:122`、`:134` | 消化模式：不真注入按键（三处各自读） | 关 |
| `AURORA_ASSIST_KEEPALIVE` | `App/AuroraDriveApp.swift:7542` | 第二司机保活心跳（`=0` 恢复每帧跑） | **开**（`!= "0"`） |
| `AURORA_DETECT_DECIMATE` | `App/AuroraDriveApp.swift:5580` | 检测网降频周期（帧） | `2`（`=1` 恢复每帧） |
| `AURORA_FORCE_YOLO26S` | `App/AuroraDriveApp.swift:5607`、`Core/EngineMain.swift:935` | A 模型档也常驻加载并跑 26S | 关 |
| `AURORA_WORLD_MODEL` | `Inference/InferenceEngineV2.swift:1688` | 恢复无条件加载世界模型 | 关 |
| `AURORA_PTR_DUMP` | `Inference/PointerHeadingReader.swift:958` | 指针自检时 CSV 落盘路径 | 未设 |
| `AURORA_OCR_CI` | `Inference/SpeedOCRReader.swift:970` | OCR 恢复 CoreImage 预处理路径 | 关（非 `1` 走 PixelBuffer） |
| `AURORA_CONF_CI` | `Inference/ConfidenceEstimator.swift:275` | 亮度估计走 CoreImage | 关 |
| `AURORA_YOLO_FASTCOPY` | `Inference/YoloEngine.swift:342` | YOLO 推理用快速拷贝缓冲 | 关 |
| `AURORA_MAX_CLIPS` | `Capture/RecordEngine.swift:69`、`:444`、`Capture/CaptureEngine.swift:1616` | 每类录制片段上限 | 代码默认值 |
| `AURORA_MAP_GRAPH_W` | `App/MapLayers.swift:245` | 骨架线宽覆盖 | `3.6` |
| `AURORA_MAP_ROAD_W` | `App/MapLayers.swift:244` | 路网线宽覆盖 | `2.6` |
| `AURORA_WEBSEARCH_COOLDOWN` | `Agent/WebSearch.swift:163` | 联网搜索冷却秒数 | 代码默认 |
| `AURORA_LLM_PROBE_INTERVAL` | `Agent/LLMHealth.swift:404` | LLM 探活间隔 | `defaultProbeInterval` |
| `AURORA_LLM_HEALTH_CACHE` | `Agent/LLMHealth.swift:1348` | 健康缓存文件路径覆盖 | 默认路径 |
| `AURORA_PYTHON` | `App/AuroraDriveApp.swift:6574` | Python 解释器路径覆盖 | 自动探测 |
| `AURORA_PRIVILEGE_INSTALLED` | `Core/PrivilegePill.swift:469` | **仅 shell 脚本里 `echo` 的字符串，不是读取点** | — |

### 1.3 间接下标（键名由常量/参数持有，直接 grep 字面量会漏）

| 变量名 | 文件:行 | 说明 |
|---|---|---|
| `AURORA_EGO_AREA` | `Agent/EgoBoxFilter.swift:70`（`envKey`）→ `AuroraFlags.swift:219` | 常量持键名 |
| `AURORA_MAP_TILE_WINDOW` | `App/MissionConsole.swift:2197`（`envKey`）→ 读于 `:2201` | 常量持键名 |
| `AURORA_MAP_NO_LOADNORM` | `App/MapSelfTest.swift:145` | 直接读，但在 selftest 文件里 |
| `AURORA_MAP_ROAD_W` / `AURORA_MAP_GRAPH_W` | `App/MapLayers.swift:232`（`envWidth(_ key:)` 形参） | 键名作实参传入 |

---

## 2. 命令行 flag 全表（`CommandLine.arguments`）

> 入口分流在 `App/AuroraDriveApp.swift` 的 `main()` 里，一组 `if let i = args.firstIndex(of: "--xxx")` 串联。
> **绝大多数是 selftest / 一次性渲染入口：命中即执行然后 `exit(0)`，不是运行期开关。** 真正影响长期运行行为的只有下面 5.2 那几条。

### 2.1 真正影响运行的 flag

| flag | 文件:行 | 作用 |
|---|---|---|
| `--engine` | `App/AuroraDriveApp.swift:830`、`:6067`、`:6262`、`:7242`；`Core/EngineClient.swift:354`；`Core/GameModeDefender.swift:60` | 以**引擎进程**身份启动（后台抓屏+推理+注入）。UI 进程用它 spawn 子进程 |
| `--daemon` | `App/AuroraDriveApp.swift:137`、`:929` | Daemon 模式启动（不激活窗口、无 Dock 图标） |
| `--auto-drive` | `App/MissionConsole.swift:6328` | 启动 1.5s 后自动 `startDriving()`（A/B 实验的关键：不用手点开始） |
| `--auto-seconds N` | `App/MissionConsole.swift:6332` | N 秒后自动 `exit(0)`（**定时结束采样用**） |
| `--agent-command` | `App/AuroraDriveApp.swift:333`、`:417`、`:524`、`:537`、`:1388` | AI 指令模式：后台运行、不抢焦点、窗口全部 `orderOut` |

### 2.2 自检 / 一次性入口（命中即跑完退出，不适合 A/B）

| flag | 文件:行 |
|---|---|
| `--flags-help` | `AuroraDriveApp.swift:943`、`:1009` |
| `--tcc-selftest` | `AuroraDriveApp.swift:156`、`:497`、`:927` |
| `--test-xpc` | `AuroraDriveApp.swift:147`、`:927` |
| `--speed-selftest [--image/--roi]` | `AuroraDriveApp.swift:191`、`:194`、`:1183`、`:1186`、`:927` |
| `--yolo-selftest [--dir N]` | `AuroraDriveApp.swift:175`、`:992`、`:928` |
| `--yolo-bench [--dir/--frames/--stride]` | `AuroraDriveApp.swift:182`、`:994`、`:996`、`:928` |
| `--pointer-selftest <dir>` | `AuroraDriveApp.swift:206`、`:981` |
| `--upscale-selftest` | `AuroraDriveApp.swift:928`；`MissionConsole.swift:6340` |
| `--perception-selftest` | `AuroraDriveApp.swift:936`、`:1210` |
| `--lanekeep-selftest` | `AuroraDriveApp.swift:936`、`:1218` |
| `--ayolom-selftest` | `AuroraDriveApp.swift:935`、`:1226` |
| `--yolopx-selftest` | `AuroraDriveApp.swift:931`、`:1232` |
| `--proto-selftest` | `AuroraDriveApp.swift:930`、`:1243` |
| `--nic-autotest` | `AuroraDriveApp.swift:930`、`:1248` |
| `--limit-selftest` | `AuroraDriveApp.swift:930`、`:1254` |
| `--opticalflow-selftest` | `AuroraDriveApp.swift:931`、`:1260` |
| `--motion-selftest` | `AuroraDriveApp.swift:931`、`:1265` |
| `--egobox-selftest` | `AuroraDriveApp.swift:935`、`:1203` |
| `--fit-selftest` | `AuroraDriveApp.swift:929`、`:1271` |
| `--route-selftest` | `AuroraDriveApp.swift:937`、`:1279` |
| `--taxonomy-selftest` | `AuroraDriveApp.swift:938`、`:1285` |
| `--map-selftest` | `AuroraDriveApp.swift:974`、`:1292` |
| `--lane-extrapolator-selftest` | `AuroraDriveApp.swift:975`、`:1298` |
| `--map-window-test` | `AuroraDriveApp.swift:1308` |
| `--corner-selftest` | `AuroraDriveApp.swift:932`、`:1196` |
| `--lanekeep-reality` | `AuroraDriveApp.swift:937`、`:990` |
| `--realshot-selftest` | `AuroraDriveApp.swift:934`、`:1180` |
| `--tick-bench [--seconds]` | `AuroraDriveApp.swift:933`、`:1168`、`:1170` |
| `--tick-profile [--seconds]` | `AuroraDriveApp.swift:932`、`:1155`、`:1157` |
| `--perf-selftest [--seconds]` | `AuroraDriveApp.swift:932`、`:1141`、`:1144` |
| `--llm-selftest` / `--llm-vision-selftest` / `--llm-probe` / `--llm-perf-selftest` | `AuroraDriveApp.swift:959`、`:1064`、`:1072`、`:1079`、`:1119` |
| `--tool-selftest` / `--tool-call-demo` | `AuroraDriveApp.swift:960`、`:1093`、`:1100` |
| `--v2-selftest` | `AuroraDriveApp.swift:966`、`:1112` |
| `--agent-selftest` / `--agent-llm-test` / `--set-llm-config` | `AuroraDriveApp.swift:854`、`:974`；`MissionConsole.swift:6363` |
| `--cache-selftest` | `AuroraDriveApp.swift:943`、`:1016` |
| `--wire-selftest` | `AuroraDriveApp.swift:937`、`:1001` |
| `--capture-selftest` | `AuroraDriveApp.swift:978`、`:1034` |
| `--control-selftest` | `AuroraDriveApp.swift:960`、`:1086` |
| `--quest-selftest` / `--mc-quest` | `AuroraDriveApp.swift:818`、`:820`、`:946`、`:1025` |
| `--websearch-selftest [--network]` | `AuroraDriveApp.swift:961`、`:1135`；`Agent/WebSearch.swift:1454`、`:1459` |
| `--agent-ui-shot` / `--agent-layout-shot` | `MissionConsole.swift:6371`、`:6375` |
| `--mc-map` / `--mc-map-offline` / `--mc-route` / `--mc-route-loading` / `--mc-map-bench` / `--mc-shot` | `AuroraDriveApp.swift:766`、`:771`、`:778`、`:783`、`:790`、`:800`、`:929`、`:939` |
| `--locate-live` | `Locate/VisualLocator.swift:118`、`:185`、`:275` |

---

## 3. 引擎 socket 命令与 `config` 键

### 3.1 socket 位置与协议

- 路径：`~/Library/Application Support/AuroraDrive/engine.sock`（`Core/EngineMain.swift:1190`、`Core/EngineClient.swift:156`）
- 协议：**每行一个 JSON**，必须有 `"type"` 字段（`Core/EngineMain.swift:1859-1865`）
- 可选 `"id"`（任意标量）：带上才回 `ack`（`EngineMain.swift:1869`）
- 客户端写法见 `Core/EngineClient.swift:871`（`["type": type]` + 额外键，`json + "\n"`）

### 3.2 全部命令（`handleCommand`，`Core/EngineMain.swift:1859`）

| 命令 `type` | 行 | 额外字段 | 作用 |
|---|---|---|---|
| `start` | :1871 | — | 开始驾驶（`startDriving()`） |
| `stop` | :1884 | — | 停止驾驶并释放按键 |
| `bye` | :1896 | — | UI 退出：暂停驾驶、释放全部按键 |
| `status` | :1907 | — | 回发心跳 + 完整状态快照 |
| `upscale` | :1918 | `on: Bool` | 切全分辨率帧 / 480 宽缩略帧（插帧数据源） |
| `record` | :1931 | `on`、`glyph`、`expert`、`perspective`("first"/"third") | 行驶录制启停 |
| `reloadmodel` | :2023 | — | 热替换主驾/副驾/YOLO 三引擎模型 |
| `config` | :2057 | 见 §3.3 | 同步驾驶参数（**A/B 的主入口**） |
| `set_capture_mode` / `capture` | :2183 | `mode`("fullscreen"/…)、`windowID: Int` | 切换抓屏目标 |
| `state` | :2244 | — | 取状态 |
| `ping` | :2258 | — | 探活 |

### 3.3 `config` 支持的全部键（`Core/EngineMain.swift:2062-2089`）

| 键 | 类型 | 行 | 作用 | A/B 价值 |
|---|---|---|---|---|
| `controlDisabled` | Bool | :2063 → :2099 | **禁用控制注入**（仍抓屏+推理+渲染） | ★★★ 高，但**nc 会被 UI 覆盖**（见 §4.3 坑 2） |
| `digest` | Bool | :2085 → :2109 | 消化模式：不真发按键（与上者路径不同） | ★★ 中，**nc 注入可保持** |
| `sport` | Bool | :2062 → :2098 | 极速模式 | 低 |
| `forceRule` | Bool | :2064 → :2100 | 紧急切纯规则档（**不动模型推理**） | ★ 低 |
| `expert` | Bool | :2065 → :2101 | 专家模式标记 | 低 |
| `glyph` | Bool | :2066 → :2102 | 字模模式标记 | 低 |
| `degradeThreshold` | Double | :2067 → :2103 | 降级阈值 | 低 |
| `speedLimit` | Double | :2068 → :2119 | 速度上限（参与推理 vehicle_state[4]） | 低 |
| `takeover` | Bool | :2082 → :2124 | 用户接管让位（5Hz ↔ 20Hz） | ★ 低（改 tick 频率） |
| `perceptionMode` | String | :2089 → :2160 | **档位切换**：`"ayolom"` / `"legacy"` / `"yolopx"` | ★★★ 最高，**nc 注入可保持** |

> ⚠️ `config` **没有**关掉 YOLOPX / OCR / 指针朝向 / 第二司机的键。这几个只能靠环境变量或改代码。

---

## 4. 可直接复制的 A/B 实验命令

### 4.1 基线（不设任何开关）

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"
./AuroraDriveUI --auto-drive --auto-seconds 60
```

> `--auto-seconds 60` 到点自动退出（`MissionConsole.swift:6332`），不用手点。GPU 用「活动监视器 → GPU 历史记录」或 `sudo powermetrics --samplers gpu_power -n 30 -i 1000` 采。

### 4.2 逐项关（每次只加一个，跑够 60s）

```bash
# ① 关帧率 HUD（那个 168×46 绿色小窗，level=.screenSaver 压在全屏游戏之上）
AURORA_DISABLE_HUD=1 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ② YOLOPX 限频到 5Hz（0=不限；200ms 间隔）
AURORA_YOLOPX_INTERVAL_MS=200 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ③ 切 legacy 档（会装卸 yolo26s，但 yolopx 大模型接手）—— 对照「族」的差异
AURORA_AYOLOM=0 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ④ 关任务面板 OCR（0.7s/次 Vision .accurate 33.6ms，默认开）
AURORA_QUEST_OCR=0 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ⑤ 关光流（只在 legacy 档才跑，A 档本来就不跑）
AURORA_DISABLE_OPTICAL_FLOW=1 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ⑥ 关缓存层（纯 CPU 侧，用来确认 GPU 数字不是缓存造成的）
AURORA_CACHE=0 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ⑦ 第二司机恢复「每帧跑」（=0 是反的：默认已经降频到 1/5）
AURORA_ASSIST_KEEPALIVE=0 ./AuroraDriveUI --auto-drive --auto-seconds 60

# ⑧ 完全禁用控制注入（仍抓屏+推理+渲染，验证「注入」本身占多少）
#    走 socket，见 4.3
```

### 4.3 用 socket 做运行期切换（不重启进程 —— 最省时间）

```bash
SOCK="$HOME/Library/Application Support/AuroraDrive/engine.sock"

# 禁用控制注入（保留全部感知与渲染）
printf '{"type":"config","id":"ab1","controlDisabled":true}\n' | nc -U "$SOCK"

# 恢复
printf '{"type":"config","id":"ab2","controlDisabled":false}\n' | nc -U "$SOCK"

# 切档（ayolom ↔ legacy，会让引擎装卸 yolo26s）
printf '{"type":"config","id":"ab3","perceptionMode":"legacy"}\n' | nc -U "$SOCK"
printf '{"type":"config","id":"ab4","perceptionMode":"ayolom"}\n' | nc -U "$SOCK"

# 关插帧/全分辨率帧（引擎改发 480 宽缩略帧）
printf '{"type":"upscale","id":"ab5","on":false}\n' | nc -U "$SOCK"

# 查状态（回快照，含 tickHz / yoloLoaded）
printf '{"type":"status","id":"ab6"}\n' | nc -U "$SOCK"
```

#### ⚠️ 用 socket 做 A/B 前必须知道的三个坑（否则实验白做）

**坑 1：新连接会把 UI 挤掉，UI 在 0.5s 内重连。**
`EngineSocketServer` 的 `accept` 处理里明确规定「新连接替换旧连接」（`Core/EngineMain.swift:565-568`：`if let old = clientSource { clientSource = nil; old.cancel() }`）。
UI 侧断线后由 `startReconnectPolling()` 每 **0.5s** 重试（`Core/EngineClient.swift:610-625`），几乎必然在 1 秒内重连成功。
⟹ **`nc -U` 每次都会踢掉 UI 连接，但这不会让 UI 崩溃或退出**，只是短暂闪断。

**坑 2：UI 重连后会把 config 全量重推，但只推 `ControlWiring.pushConfig` 里的 9 个键。**
重连 `activate()` → `onActivated` 回调里显式做了 `lastPushedEngineConfig = ""` 并立刻 `pushEngineConfigIfChanged()`（`App/AuroraDriveApp.swift:6285`）。
两个推送源的字段集**不同**，这决定了哪些键会被覆盖：

| 推送源 | 时机 | 包含字段 | 不含 |
|---|---|---|---|
| `AuroraDriveApp.pushEngineConfigIfChanged` | **每帧**（`:6796`，快照变化才发；快照定义 `:6927`） | `sport` `controlDisabled` `forceRule` `expert` `glyph` `degradeThreshold` `speedLimit` | `digest`、`perceptionMode`、`takeover` |
| `ControlWiring.pushConfig` | 事件驱动（`:5515` 切档、`MissionConsole.swift:1913` 消化按钮等） | 上述 7 个 **+ `digest` + `perceptionMode`** | `takeover` |

**结论（直接决定操作方式）**：
- 用 `nc` 设 `controlDisabled` / `sport` / `forceRule` / `expert` / `glyph` / `degradeThreshold` / `speedLimit` → **会被下一帧的 UI 值覆盖回 UI 的当前状态**（因为它们在每帧快照里，且 UI 重连后立刻重推）。**单靠 nc 改这些键做不了持续 A/B。**
- 用 `nc` 设 `digest` 或 `perceptionMode` → **不会被每帧覆盖**（不在每帧快照里）。只要你不去点 UI 上对应的按钮，值就能保持。**这两个键适合 nc 注入。**

**坑 3：想稳定改 `controlDisabled` 只能双管齐下**：
```bash
# 停掉 UI 每帧重推的唯一稳定办法：让 UI 进程不存在（纯引擎跑）
# 或者用 nc 改完后立刻连续重发（每 200ms 一次），适合短窗口采样
```

**于是推荐的两种 A/B 姿势**：

**姿势 A（推荐）：环境变量 + 重启。** 一切开关都在启动时确定，没有竞态：
```bash
pkill -f AuroraDriveUI                      # 清掉遗留引擎（它会读旧环境）
<变量名>=1 ./AuroraDriveUI --auto-drive --auto-seconds 60   # 变量名取自 §1 的表格
```
这是唯一能保证「设的值 = 生效的值」的方式。代价是每次重启（数秒，不是几分钟重建）。

**姿势 B：纯引擎进程 + nc 全权控制**（UI 不参与，没有覆盖源）：
```bash
pkill -f AuroraDriveUI
./AuroraDriveUI --engine &                  # 只起引擎，不开 UI
sleep 3
SOCK="$HOME/Library/Application Support/AuroraDrive/engine.sock"
printf '{"type":"start","id":"s1"}\n' | nc -U "$SOCK"          # 开始驾驶
printf '{"type":"config","id":"s2","controlDisabled":true}\n' | nc -U "$SOCK"
sleep 60                                                       # 采样
printf '{"type":"stop","id":"s3"}\n' | nc -U "$SOCK"
pkill -f "AuroraDriveUI --engine"
```
> ⚠️ 姿势 B 下**没有 UI 窗口**，所以「叠加层/HUD」这一项天然是关的 —— 别拿它和姿势 A 的基线直接比。

> 引擎进程与 UI 进程**都读各自的环境变量**（`Core/EngineMain.swift:935` 注释明确写了这点）。启动 UI 时设的环境变量会被 `Process` spawn 出的 `--engine` 子进程继承（前提是 `Core/EngineClient.swift:338-347` 的 spawn 未显式覆盖 `environment` —— 已核实未覆盖）。若引擎是**上一次**启动遗留的进程，它读的是**旧环境**，此时环境变量改动无效 —— 先 `pkill -f AuroraDriveUI`。

---

## 5. 七大功能的运行期可关性（重点）

### 5.1 YOLOPX 检测 —— ⚠️ 半能

**事实**：
- 推理调用点唯一：`App/AuroraDriveApp.swift:7592` `yolopxEngine.infer(image: cg)`，门是 `detectGateA`（`:7115`）。
- `detectGateA = decimateFallback || isAyolom || parityEven` → **A-YOLOM 档恒真 = 每帧都跑**（用户 2026-10-07 拍板不降频，见 `:7103-7108`）。
- 引擎有 `var enabled = true`（`Inference/YolopxEngine.swift:360`），**但全仓无任何写入点**（grep `.enabled = ` 只有 `PerfBus.enabled`）。且源码自带警告：*「无设置面板入口，全仓库无 UI 绑定，改动需改此代码常量并重编译」*（`:357-359`）。

**能用的开关**：
| 手段 | 效果 | 是否关掉 GPU |
|---|---|---|
| `AURORA_AYOLOM=0` | 切到 legacy 族（yolopx3 大模型） | ❌ 反而更重 |
| `AURORA_YOLOPX_INTERVAL_MS=200` | 限频到 5Hz（`:484`） | ✅ 按比例降，**最推荐** |
| `AURORA_DETECT_DECIMATE=1` | 恢复每帧跑（**反方向**，会加负载） | ❌ |
| `config: {"perceptionMode":"legacy"}` | 切档 | ❌ 变重 |

**结论**：能关掉但仍保持驾驶 → **没有**。唯一「真停」的路：

> **无运行期开关，需改代码**：`Sources/AuroraDrive/Inference/YolopxEngine.swift:360` 改 `var enabled = true` → `false`，或在 `App/AuroraDriveApp.swift:7115` 给 `detectGateA` 加环境变量门。
> 停掉的代价（源码写明）：`drivableMask` / `laneMask` 变空、检测框降级（`:914-917` 会 `reset()` 并置降级），`LaneFallback` 将接管车道保持。**会降品**。

### 5.2 叠加层 / HUD 绘制 —— ✅ 能（但有坑）

必须先分清三个"浮层"，别搞错对象：

| 窗口 | 代码 | 尺寸/层级 | 开关 |
|---|---|---|---|
| **帧率 HUD** | `App/GameHUDWindow.swift:69` | 168×46，`level = .screenSaver`（**压过全屏游戏**） | ✅ `AURORA_DISABLE_HUD=1` |
| **1×1 锚点窗口** | `App/AuroraDriveApp.swift:67-96` | 1×1 px，`level = .floating` | ❌ **无开关**（且 `installGameModeAnchorWindow` 只在 `:67` 定义，全仓**无调用点** —— 已是死代码，不会生效） |
| **主控制台窗口** | `App/AuroraDriveApp.swift:1379` `WindowGroup { ContentView() }` | 1200×760，普通窗口 | ❌ 无开关（`AURORA_DAEMON_MODE` 只能不激活） |

- `AURORA_DISABLE_HUD=1` 的判定在 `App/AuroraDriveApp.swift:6066`，生效范围只有 `gameHUD.install()`（`:6071`）。
- 源码注释解释了加它的原因：实测「Aurora 打开 → WindowServer 负载 **+29.2 个百分点**」（三组 ABBA，`:6049-6054`）。

**结论**：`AURORA_DISABLE_HUD=1` 关的是**那个压在最上层的小 HUD**，这是唯一"覆盖在游戏上的透明窗口"。若你要关的是**整个控制台窗口**（游戏后面那个 1200×760 大窗）：
> **无运行期开关，需改代码**：`App/AuroraDriveApp.swift:1379-1380`（`WindowGroup { ContentView() }`），或在 `:1386` 的 `onAppear` 里对所有窗口 `orderOut(nil)`（照抄 `--agent-command` 分支 `:1391-1394` 的做法）。
> 更省事的替代：`AURORA_DAEMON_MODE=1`（`:141`）不激活窗口，但窗口仍会渲染。

### 5.3 小地图 / 地图渲染 —— ✅ 能（默认就不开）

两个不同的东西：

| 对象 | 代码 | 默认 | 关法 |
|---|---|---|---|
| **独立大地图窗口** | `App/MapWindow.swift:121` `MapWindowController` | **默认不开**（`:1424` 注释明确：*「默认绝对不自动开」*） | 别按 ⌘M、别点按钮即可 |
| **中栏小地图卡** | `App/MissionConsole.swift:1806` `MiniMapCard` → `:1957` `MiniMapCanvas` | 常驻在主界面中栏 | ❌ 无开关（`AURORA_MAP_FILTER_BAR=0` 只隐藏筛选条，`:367`） |
| **可行驶区/车道线掩码** | `MissionConsole.swift:618` `MaskOverlay` | 驾驶时绘制 | ✅ 代码级：`DriveState.showYolopxMasks`（`AuroraDriveApp.swift:5521`，默认 `true`，**无 UI 绑定**） |
| **检测框** | `MissionConsole.swift:608` `ObstacleOverlay` | 驾驶时绘制 | ❌ 无开关（`active: state.isDriving` 固定） |

**能用的开关**（都是地图粒度，不是整块关）：
```bash
AURORA_MAP_NO_MARKERS=1    # 完全跳过标记图层（:369 / :4414）
AURORA_MAP_MAX_LABELS=0    # 标签上限打到 0（:371 / :4424）
AURORA_MAP_LAYERS=0        # 图层全关（路网/骨架/POI 都不画，:363 / :4355）
AURORA_BASEMAP_GRADE=0     # 关底图调色（:359）
AURORA_MAP_TILE_WINDOW=0   # 底图回退源图直裁（:352）
```
- `AURORA_MAP_WINDOW=1` 是**打开**独立地图窗（`:1421`），A/B 时**注意别误设成 1**。

**结论**：不打开大地图窗就已经省下最大一块；小地图卡本身**无运行期开关**，要关需改 `App/MissionConsole.swift:1806`（把 `MiniMapCard(...)` 移除）或 `:1957` `MiniMapCanvas` 的 `body`。

### 5.4 速度 OCR —— ❌ 不能（且**不占 GPU**）

**事实**：
- 调用点：`App/AuroraDriveApp.swift:7372` `speedOCR.infer(nativePixelBuffer: nativeFrame)`，**无任何门控**（只要 `pendingNativeFrame` 非 nil 就调）。
- 内部只有三道闸：15Hz 时间节流（`SpeedOCRReader.swift:571`）、防重叠（`:575`）、模型可用（`:577`）—— **全是节流，不是停用**。
- `AURORA_SKIP_MODEL_LOAD=1`（`:301`）源码写明：*「该开关不影响功能，只影响加载时机」* —— `ensureModelsLoaded()`（`:323`）会在首次推理时补加载。**不要指望它关掉 OCR。**
- `AURORA_OCR_CI=1`（`:970`）只是预处理路径回退（CoreImage vs PixelBuffer），**不改负载量级**。
- **`config.computeUnits = .cpuAndNeuralEngine`（`SpeedOCRReader.swift:433`）→ 完全不碰 GPU。**

**结论**：无运行期开关。**但它对 GPU 36.4% 没有贡献**，不建议耗一轮实验。
> 若仍要停：**需改代码** `Sources/AuroraDrive/App/AuroraDriveApp.swift:7372`（把 `speedOCR.infer(...)` 包进环境变量判断）。

### 5.5 第二司机（`game_assist_control`）—— ⚠️ 半能，且开关语义是**反的**

**事实**：
- 模型：`App/AuroraDriveApp.swift:5796` `let assistEngine = InferenceEngine(modelFileName: "game_assist_control")`。
- 调用点：`:7543-7545`，门控是**保活心跳**：
  ```swift
  let assistKeepalive = ProcessInfo.processInfo.environment["AURORA_ASSIST_KEEPALIVE"] != "0"
  if !assistKeepalive || mode == .yolo || adaptiveFrameCounter % 5 == 0 {
      assistEngine.infer(...)
  }
  ```
- ⚠️ **语义陷阱**：`!= "0"` 意味着 **默认就是"开着保活"= 每 5 帧跑一次**。设 `AURORA_ASSIST_KEEPALIVE=0` 是**恢复每帧都跑**（源码注释：*「回退开关：`AURORA_ASSIST_KEEPALIVE=0` 恢复每帧跑」*，`:7541`）。**设了会变重，不是变轻。**
- 不能真停：`.yolo` 档降级检查看 `assistLive`（`DegradeStateMachine.swift:124`），完全停跑 → 1s 后 `assistLive=false` → 误降 `.rule`。
- **`computeUnits = .all`（`Inference/InferenceEngine.swift:164`）→ 会用 GPU。**

**结论**：能降到 1/5 已经是现成的**默认行为**（不用设任何变量）。要再低或彻底停：
> **无运行期开关，需改代码**：`Sources/AuroraDrive/App/AuroraDriveApp.swift:7544` 那行 `assistEngine.infer(...)`。
> 若只做短时 A/B（<1s 就会降级），可以直接把 `:7542` 的条件改成 `false`（一行），代价是可能掉到 `.rule` 档 —— **会改变驾驶行为**。

### 5.6 指针朝向识别（`pointer_heading`）—— ❌ 不能（且**不占 GPU**）

**事实**：
- 代码：`Inference/PointerHeadingReader.swift:141`；实例 `App/AuroraDriveApp.swift:6003` `let pointerReader = PointerHeadingReader()`。
- 调用点：`:7445-7447`
  ```swift
  if pointerReader.isAvailable, adaptiveFrameCounter % 3 == 0 {
      if let h = pointerReader.read(frame: cg) { ... }
  }
  ```
- 已有降频：15Hz ÷ 3 = **5Hz**（`:7441-7443` 注释：用户要求「全链路除了地图 5 赫兹之外，其他全部 15 赫兹」）。
- `isAvailable` 只判 `model != nil`（`:251`），**没有开关位**。
- **`config.computeUnits = .cpuAndNeuralEngine`（`:290`）→ 完全不碰 GPU。**

**结论**：无运行期开关。**对 GPU 无贡献**。
> 若要停：**需改代码** `Sources/AuroraDrive/App/AuroraDriveApp.swift:7445`（把 `if` 条件加上环境变量判断）。

### 5.7 插帧 / upscale —— ✅ 能（默认就是关的）

**事实**：
- UI 侧开关：`App/AuroraDriveApp.swift:5330` `var upscaleEnabled: Bool = false` —— **默认关**。
- 开关入口：App 内 UI 按钮（`MissionConsole.swift:3281-3285` `toggle: { state.upscaleEnabled.toggle() }`），**没有环境变量**。
- 设值链路：`setUpscaleEnabled(_:)`（`:6507-6515`）→ `captureEngine.upscaleEnabled` + `EngineClient.shared.setUpscale(on)`（`EngineClient.swift:910` 发 `{"type":"upscale","on":...}`）。
- 引擎侧：`EngineGlobals.wantFullFrame`（`EngineMain.swift:640`），`:1923` 写入；`CaptureEngine.isUpscaleWanted` 读它（`:1247`）。
- 引擎初始化只在 UI 进程做（`:6262`，`--engine` 跳过），因为 `MTLCreateSystemDefaultDevice` + 编译 shader 要 ~100ms-1s。
- **Metal 引擎 `GooseUpscaler`（`App/AuroraDriveApp.swift:9069`）→ 开了才占 GPU。**

**结论**：**默认已关**，A/B 基线天然就是「关」的状态。
- 要确保仍关着：别点 UI 上的「插帧」按钮；或直接发 socket 命令 `{"type":"upscale","on":false}`（§4.3）。
- **无需改代码，无需环境变量。**

---

## 6. 按 GPU 归因排序的 A/B 建议顺序

实测 36.4% 的分解，按「预期贡献 × 关闭成本」排：

| 顺序 | 关什么 | 命令 | 预期 |
|---|---|---|---|
| 1 | **YOLOPX 限频 5Hz** | `AURORA_YOLOPX_INTERVAL_MS=200` + 重启 | YOLOPX `computeUnits=.all`，是 GPU 大头。**环境变量走姿势 A** |
| 2 | **切档 legacy** | `{"type":"config","perceptionMode":"legacy"}` | 对比「小模型 vs 大模型+yolo26s」两套 GPU 负载；nc 注入可保持 |
| 3 | **控制注入** | `{"type":"config","controlDisabled":true}` 连续重发，或姿势 B | 验证"注入"这条路径自身占比（不动感知）|
| 4 | **确认插帧是关的** | `{"type":"upscale","on":false}` | 若意外开着，这一条就能解释掉一大块 |
| 5 | **关帧率 HUD** | `AURORA_DISABLE_HUD=1` + 重启 | 验证 WindowServer 合成成本（注释里实测 +29.2%） |
| 6 | **关任务面板 OCR** | `AURORA_QUEST_OCR=0` + 重启 | 33.6ms/0.7s 的 Vision，属 CPU/ANE 侧 |
| — | ~~速度 OCR~~ | 无开关 | **不占 GPU，跳过** |
| — | ~~指针朝向~~ | 无开关 | **不占 GPU，跳过** |
| — | ~~第二司机~~ | 已是 1/5 降频 | 只能改代码，放最后 |

---

## 7. 纪律与已知坑

1. **`AURORA_DIGEST` 有三处各自读**（`AuroraDriveApp.swift:4297`、`ControlEngine.swift:122`、`:134`），且 `DriveState` 每帧还会用 `st.digestMode` 覆盖 `controlEngine.digestMode`（`EngineMain.swift:2105-2113` 注释记录了这个坑）→ 环境变量与 `config.digest` 同时存在时，以引擎侧 `config` 为准。
2. **`AURORA_EGO_CHECK` 是全表唯一"每次现读"的开关**（`AuroraFlags.swift:235`），因为它依赖运行时 `setenv`。其余都是 `static let`，进程内**只读一次**，改了必须重启进程。
3. **引擎进程与 UI 进程是两个独立进程**，各读各的环境变量。引擎若是上次遗留的进程，这次设的环境变量**对它无效**。改环境变量前先 `pkill -f AuroraDriveUI`。
4. **`AURORA_FORCE_YOLO26S` 与 `AURORA_DETECT_DECIMATE` 是"反方向"开关**（恢复旧的重负载行为），A/B 时别设。
5. **`AURORA_MAP_WINDOW=1` 是打开地图窗**，与 `AURORA_MAP_TILE_WINDOW`（底图渲染路径）**名字撞车过一次**（`AuroraFlags.swift:345-351` 有详细记录），别混。
6. **socket 注入的 `controlDisabled` 会被 UI 每帧重推覆盖**（详见 §4.3 坑 2）。这是本文实测发现的最容易让 A/B 白做的陷阱：`nc` 改完看着 `ack` 回了 ok，1 秒后 UI 重连又把值写回去了。`digest` / `perceptionMode` 不在每帧快照里，可以保持。
7. 本文所有开关均可现场核对：`./AuroraDriveUI --flags-help`（`AuroraDriveApp.swift:1009`）打印 `AuroraFlags` 全表。

---

## 8. 本文核验口径

- 环境变量：`grep -rn "ProcessInfo.processInfo.environment\[" --include=*.swift Sources/` → **58 处表达式、23 个文件**；另按 `"AURORA_*"` 字符串字面量扫得 **91 个唯一变量名**（含注释与脚本字符串）。
- 命令行：`grep -rno '"--[a-zA-Z0-9-]*"' --include=*.swift Sources/` → 全部命中已列入 §2。
- socket 命令与 `config` 键：逐行读 `Sources/AuroraDrive/Core/EngineMain.swift:1859-2382`。
- 本文**未验证**任何一条开关的实际 GPU 效果 —— 那是 A/B 实验要做的事，不是本文的结论。

> 撰写日期锚点：2026-10-24（与 `docs/perf-audit-gpu/` 其余文档同一轮）。
