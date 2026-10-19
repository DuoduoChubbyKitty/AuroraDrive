# 11 · MaaNTE 功能模块全解

> 整合自 7 篇：`MAA深度文档_功能篇.md`（735）+ `MAA深度文档_扩展篇.md`（600）+ `Maa-11-Navi导航系统全链.md`（339）+ `Maa-12-MapTeleport地图传送系统.md`（298）+ `Maa-13-小游戏三件套.md`（282）+ `Maa-14-实时辅助SoundTrigger与排球.md`（298）+ `Maa-15-生活任务与长尾模块与任务JSON体系.md`（229）。
> 整合日期：2026-10-18。**只读整合，未删改任何原文档**。
> 所有 `file.py:N` 引用均来自 MaaNTE 源码（本地 `MaaNTE/`，未随本仓库分发），已逐条核对。

---

## 1. 一句话定位

本篇覆盖 MaaNTE 的**全部业务功能与扩展开发范式**：从最复杂的 Navi 导航全链（14 文件 3356 行）到 28 个任务的 JSON 编排体系，再到「新增一个功能要同步改 5 处」的工程纪律。

---

## 2. 功能模块清单表

### 2.1 按代码量排序（本地实测，2026-10-18）

| 模块 | 文件数 | 行数 | 注册动作 |
|---|---|---|---|
| **Navi（导航）** | 14 | **3356** | `local_route_navigation`（+unit_test）/ `online_map_navigation` / `check_teleport_required` / `map_teleport_to_point` |
| **pinkpaw（粉爪大劫案）** | 6 | **6507** | `PinkPawHeistScheme1/2/3Action` / `FindXiaoZhi` / `ReturnToEntrance` / `PinkPawRewardSummary` |
| **MapTeleport（传送）** | 3 | **1405** | 见上（与 Navi 共用） |
| **rhythm（节奏）** | 10 | **1611** | `auto_rhythm_play` / `auto_rhythm_select_song` / `auto_rhythm_repeat_decision` / `auto_rhythm_vitality_on_results` |
| **AutoFish（钓鱼）** | 9 | **1447** | `auto_fish` / `auto_fish_withoutCV` / `auto_buy_fish_bait` / `auto_sell_fish` / `EnterFishPrepare` 等 |
| **Tetris** | 6 | **1490** | `tetris_reset_context` + AutoTetris |
| **SoundTrigger** | 4 | **571** | **`SoundDodgeAction`（大驼峰，同类唯一例外）** |
| **Common（公用）** | 8 | **676** | `click_override` / `EnableNode` / `AltClick` / `ResizeGameWindow` |
| **auto_piano** | 5 | **782** | `auto_play_piano` |
| **BagelSpam（贝果刷屏）** | 3 | **338** | `BagelSpamPickIndex` / `BagelSpamOutputText` / `BagelSpamLLMGenerate` |
| **auto_volleyball** | 1 | **321** | 5 个 `volleyball_*` |
| **DatasetCollection** | 1 | **222** | `autonomous_driving_dataset_recorder` |
| **Furniture** | 2 | **162** | `furniture_claim` / `furniture_choose_property` |
| **Movement** | 2 | **109** | `character_move` / `mouse_move` |
| 零星单文件 | — | — | `auto_f_scroll`(43) / `realtime_task`(49) / `withdraw_money_choose_item`(136) / `SyncCharacterAbilityCityAbility`(427) / `auto_volleyball_weekly`(226) / `lucky_star_round`(116) |

**合计 `agent/` Python 23,233 行**（本地 `find agent -name "*.py" | xargs wc -l` 实测）。

### 2.2 任务 JSON 体系（本地实测，推翻原文）

| 指标 | 原文（Maa-15） | 本地实测 |
|---|---|---|
| 任务 JSON 文件数 | 25 + preset 4 = 29 | **27 + preset 4 = 31** |
| task 定义数 | 28 | **30** |
| option 数 | 78 | **86** |

**实测逐文件**（`assets/resource/tasks/*.json`）：

| 任务 | task | option |
|---|---|---|
| **PinkPawHeist** | 1 | **10** |
| **Fish** | **2** | **9** |
| RealTime | 1 | 9 |
| Furniture | 1 | 6 |
| Rhythm | 1 | 6 |
| BagelSpam | 1 | 5 |
| Volleyball | 1 | 5 |
| OnlineMapNavigation | 1 | 4 |
| SoundDodge | 1 | 4 |
| Tetris | 1 | 4 |
| Touch | 1 | 3 |
| BidKing | 1 | 3 |
| VolleyballWeekly | 1 | 3 |
| **TestMovement** | **3** | 2 |
| PukaLand | 1 | 2 |
| AutoPiano / AutoFScroll / ClaimRewards / WithdrawMoney | 1 各 | 2 / 0 / 2 / 2 |
| FountainCheckin / WitchDivination / LocalRouteNavigationMemoryTest | 1 各 | **0**（纯 pipeline） |
| MakeCoffee / MakeCoffeeLite / MakeTomatoJuice / AutonomousDrivingDataset / SyncCharacterAbilityCityAbility | 1 各 | 1 各 |

**option 类型分布**：原文称 input 27 / switch 39 / select 12 = 78。**本地重算为 86**（未逐类型拆分，标 **未验证**）。

> ⚠️ **上游新增**：`VolleyballWeekly.json`（排球周赛，对应 `auto_volleyball_weekly.py`）、`PukaLand.json`（2 option，对应 `lucky_star_round.py`？**未验证**）。`Maa-15` 的清单完全没有这两个。

---

## 3. Navi 导航系统全链（最复杂模块，14 文件 3356 行）

### 3.1 模块协作总览

```
nte_coordinate_api.py(611)  ── 抓包解析 UE5 移动包 → 原始坐标/朝向 ┐
map_locator.py(650)         ── 视觉：小地图模板匹配 + 多尺度      ┘（二选一）
                    ↓
coordinate_position.py(312) ── 统一出口 CoordinatePositionProvider + 标定矩阵
angle_predictor.py(220)     ── 朝向补正（ONNX 指针模型）
route_model.py(340)         ── RouteSession + 三种 waypoint 解析
waypoint_navigator.py(310)  ── PID 转向 + 前进键
route_runner.py(145)        ── 主循环
navigation_server.py(290)   ── WebSocket :14514 状态广播
route_websocket_service.py(57) ── 桥接
local_route_navigation.py(281) / online_map_navigation_action.py(104) ── CustomAction 入口
```

**双定位后端**：默认 `coordinate`（抓包，精度高）→ 失败自动降级 `map`（视觉）；`position_backend` 只接受 `map`/`auto`/`coordinate`。

### 3.2 nte_coordinate_api.py —— UE5 移动包解码器（本地核对）

- `__all__ = ("API_VERSION", "CoordinateCapture")`（:20）+ **`API_VERSION = "1.3.0"`**（:22）——`coordinate_position.py:68-73` 强校验，不匹配直接 RuntimeError。
- `_bits`（:33-39）：跨字节小端位域提取，**越界即抛 ValueError**。
- `_vector`（:42-63）：7 位头（低 6 位 width + 最高 scaled 标志）→ 三分量 → **符号位在最高位，负数减模**；`width == 0` 抛 "unsupported full-precision vector"。
- `_rotator`（:66-79）：FRotator::SerializeCompressedShort，各 1 位 present + 16 位压缩角；`angle = c×360/65536`，>180 减 360。
- `_has_valid_rotation`（:82-106）—— **误匹配过滤的核心**：要求 Yaw present && Roll absent && |pitch| ≤ 90.001。源注释："ControlRotation serializes pitch and yaw, while roll is normally omitted by the client. This presence pattern removes common random alignments."
- `_pose`（:113-125）：`heading = (degrees(atan2(east, north)) + 360) % 360`；`_NORTH`/`_EAST` 点积 ≈ 1（正交近轴对齐，**存在约 0.79° 世界轴偏角**）。
- `_Decoder`（:183-374）9 个 `__slots__`：扫描区间 `range(190, min(512, len*8-60))`，**七重过滤**（时间有限且 [0,100000) / 两向量都 scaled / acc_bits∈[1,16] / loc_bits∈[20,32] / |acc|<50000 / |loc|≤2e6 / **尾部必须合法 rotation**）。
- `_tracking_key`（:299-309）：`time_error + min(dist_sq/5000², 100)`，**时间为主 + 空间惩罚防大包内错选**。
- `_confirm_flow`（:344-368）：**连续 2 帧一致才切换**（Δt≥0.001 且 |Δt-gap|≤0.5 + 同偏移 + 位移²≤6.4e9）。
- `CoordinateCapture`（:377-611）：默认 `packet_filter = "tcp port 30031 or udp"`、`refresh_rate=30`；`_start_pcap` 校验 `conf.use_pcap`；`_start_pktmon` 12 项调优（truncation_size=9000 等）+ TypeError 时退 3 参数极简构造。

### 3.3 coordinate_position.py —— 统一坐标出口 + 标定矩阵

```python
_CALIBRATION_AXES = (0, 1)
_CALIBRATION_A = 0.016394586684750773
_CALIBRATION_B = 5.693519256055879e-08
_CALIBRATION_TX = 6293.474380746091
_CALIBRATION_TY = 3472.664390686138
_CALIBRATION_ERROR = 0.22031967781665318
COORDINATE_MAP_SIZE = (11264, 11264)     # 上游原生值（本地 :17 核对）
```

- **由 `scripts/update_navi_coordinate_transform.py` 生成**（本地 `scripts/` 确认存在）。
- `b` 近似 0（5.7e-08）→ 两坐标系几乎仅差缩放+平移，无旋转；**缩放系数 `sqrt(a²+b²) ≈ 0.0163946`** 即「世界单位 → 地图像素」比例。
- `_Transform.apply`：`(a·x − b·y + tx, b·x + a·y + ty)`；`invert_xy` 仅 `axes==(0,1)` 可用，分母 ≤1e-12 返回 None。
- `_create_capture`（:42-81）**三重校验**：动态导入失败 → RuntimeError 带全上下文（模块名/包名/Python 版本/解释器路径/异常类型）；无 `CoordinateCapture` 属性 → RuntimeError + 报告实际加载文件路径；**`API_VERSION != "1.3.0"` → RuntimeError**。
- `CoordinatePositionProvider.locate`（:212-304）**四态返回**：视觉路径（`raw_coordinate = _raw_xy_from_map(point)` 反算）/ `coordinate_stale`（沿用上次）/ `coordinate_invalid` / 正常。

> ⚠️ **重要漂移**：**MaaNTE 上游的 `_CALIBRATION_TX/TY` 仍是 6293.474/3472.664（map-2026-06, 11264 图）**，而 AuroraDrive 已升级到 **map-2026-08 13056 图，TX=6526.474 / TY=5210.664**（`Sources/AuroraDrive/Capture/CoordinateCapture.swift:112-115`、`Locate/NetworkLocator.swift:34-35`）。**AuroraDrive 的标定比上游更新一代**——移植时不要照抄上游常量。

### 3.4 route_model.py —— 路线状态与三种坐标解析

三套坐标系常量：`ONLINE_MAP_SIZE`(22528) / `ONLINE_WORLD_ORIGIN_PIXEL`(11264,11264) / `ONLINE_PIXELS_PER_WORLD_UNIT`(44.0)。

`RouteSession`（:17-93）线程安全（`threading.Lock`）：7 个状态值 `waiting/ready/running/arrived/cleared/stopped/empty`；`payload()` 锁内快照；`nearest_index` **欧氏距离平方最小（不开方）**。

**`parse_waypoint`（:96-123）四格式自动识别**：

| 输入键 | 分支 |
|---|---|
| `pixelX`/`pixelY` | 源码尺寸缩放 |
| `target_x`/`target_y` | 同上（别名） |
| `lat`/`lng` | `parse_online_waypoint`（在线地图，**注释：maante-map 把世界坐标命名为 lat/lng，不是地理经纬度**） |
| `x`/`y`（+z） | `parse_raw_coordinate_waypoint`（原始游戏坐标 → 标定矩阵） |

### 3.5 map_locator.py（650 行）+ angle_predictor.py（220 行）—— 视觉后端

**MapLocator 关键常量**（`MAA深度文档_完整版.md:549-564`）：`MAP_SIZE=(13056,13056)`（已扩图，注意与 coordinate_position 的 11264 不同步） / `MINI_MAP_ROI=(28,15,150,150)` / `BUTTON_ROI=(16,656,31,35)` / `MAP_CROP_SIZES=(268,530,660)` / `SEARCH_RADIUS=256` / `GLOBAL_MIN_SCORE=0.85` / `LOCAL_MIN_SCORE=0.75` / `TELEPORT_DISTANCE=320` / `SMOOTHING_ALPHA=0.7` / `MIN_FILTER_PIXELS=120` + 2 个 `GLOBAL_SEARCH_REGIONS`。

**定位 9 步**：裁小地图 ROI → 圆形掩码 → HSV 颜色过滤（`[0,0,0]~[179,66,80]`）→ 结合掩码 → 取 V 通道 → **`template = mini_gray - 3`（大地图灰度对齐）** → 检测是否在大世界（`BUTTON_ROI` 模板，min_similarity=0.2）→ 多尺度匹配 → **传送恢复（跳变 ≥320px 强制全局）** → EMA 平滑（α=0.7）。

**AnglePredictor**：`pointer_roi = [73,60,64,64]`（小地图内方向箭头）；ONNX 推理 → 3 个关键点（tip/left/right）→ `angle = degrees(atan2(dx, -dy)) % 360`。模型在 **`assets/MaaNTEModels/navi/pointer_model.onnx`**（独立 git 仓库，约 15M）。

> 💡 **对本项目的启示**：AuroraDrive 的 `VisualLocator.swift`（491 行）是纯 Swift NCC 多尺度实现，与 `MapLocator` 算法同源；`Locate/NetworkLocator.swift:597-616` 的 `motionHeading = atan2(dx, -dy)` 与 AnglePredictor 公式完全一致。**但注意本地 `VisualLocator` / `NetworkLocator` 全仓零实例化（死代码），实际链路走 `CoordinateCapture`。**

### 3.6 waypoint_navigator.py + route_runner.py + navigation_server.py

**`AnglePidController`**（`架构篇:391-400`）：`kp=0.85` / `ki=0.04` / `kd=0.10` / `output_limit=35.0` / `integral_limit=120.0` / `deadband=4.0` / `max_dt=0.25`；**反向时清积分（anti-windup）**。

**`WaypointNavigator.move_to` 闭环**：定位+朝向 → `desired_angle = degrees(atan2(dx, -dy)) % 360` → `angle_delta = (desired - angle + 540) % 360 - 180` → PID → `turn_pixels = turn_degrees × 10.0` → `press_forward()` + `post_relative_move(turn_dx, 0)` → 到达判定（`tolerance`）。
**关键参数**：`tolerance=80px` / `turn_pixels_per_degree=10.0` / `max_turn_degrees=35.0`；`frame_interval = 1/60s`（坐标模式）或 `0.1s`（视觉模式）。

**`RouteRunner.run_until_stopped`**：`on_tick` 回调 → `payload["active"]` 判定 → 非活跃则 `navigator.update()` + `sleep_remaining`；活跃则取当前 waypoint → `move_to` → 成功 `advance()`。

**`NavigationWebSocketServer`**（290 行）：监听 **`0.0.0.0:14514`**；**启动即静默 websockets 四个 logger**；状态结构 `type:"navi-state"` / `version:1` / position / angle / pitch / **angleConfidence** / route{waypoints,active,currentIndex,status} / timestamp；`start(timeout=5.0)` 幂等 + `_ready_event.wait` 超时抛 TimeoutError；`_handle_message` **同步/异步处理器双兼容**（`inspect.isawaitable`）；异常回 `{"type":"navi-error"}`。

**五类 WebSocket 指令（×双别名）**：`navi-route-set`/`route-set` / `-add` / `-clear` / `-start` / `-stop`；其他 → `{"ok": False, "message": "unknown type"}`。

---

## 4. MapTeleport 地图传送系统（1393 行）

### 4.1 两个注册动作与协作

| 动作名 | 类 | 文件 |
|---|---|---|
| `check_teleport_required` | CheckTeleportRequiredAction | `check_teleport_required.py:343-425` |
| `map_teleport_to_point` | MapTeleportToPointAction | `teleport_to_point.py:924-968` |

**协作**：`check_teleport_required` 判定「离目标太远」→ **直接 `from .teleport_to_point import run_map_teleport_flow`（:414）** 走完整传送。**双入口设计**：pipeline 可只用判定，也可直接调传送。

### 4.2 check_teleport_required.py（425 行）

**默认值（本地 :26-32 核对）**：`DEFAULT_NEAR_DISTANCE=200.0` / `DEFAULT_POSITION_BACKEND="auto"` / `DEFAULT_COORDINATE_TYPE="world"` / `DEFAULT_COORDINATE_TIMEOUT=1.5` / `DEFAULT_COORDINATE_INTERVAL=0.1`；`NEAR_MESSAGE="距离过近，直接使用自动导航。"` / `FAR_MESSAGE="距离较远，使用地图传送"`。

**⚠️ 导入兜底（:16-23）—— 本文件最关键的工程点**：
```python
try:
    from maa.agent.agent_server import AgentServer
    from maa.context import Context
    from maa.custom_action import CustomAction
except ImportError:
    AgentServer = None; Context = Any; CustomAction = None
```
**maa 包缺失时不崩**，只在文件尾 `if AgentServer is not None and CustomAction is not None:`（:343）包住注册块 → **整个模块的核心算法可脱离 MaaFramework 单测/复用**。

**包导入双模式（:70-121）—— 本文件最复杂的一段**：正常模式用相对导入 `importlib.import_module("..Navi.map_locator", __package__)`；**降级模式（无包上下文）**：把 `agent/` 插进 sys.path → **动态造 3 个 ModuleType（根 + `.Navi` + `.Common`）手工设 `__path__`/`__package__` + `sys.modules.setdefault`** → 再 import。**意义：不依赖任何 `__init__.py` 就能把子模块当包内模块导入——单文件可测性的极致实现。**

**`check_teleport_required`（:275-318）主判定**：三态返回（None 未知 / True 传送 / False 不传送）；`distance = math.hypot(dx,dy)`（:310）→ `need_teleport = distance >= threshold`（:315，**闭区间**）；**参数顺序魔法（:287-291）**：`target=None` 时把第一参数当 target，否则当 frame——同一函数支持 `(target)` 与 `(frame, target)` 两种调用。

**`locate_current_position`（:240-272）后端编排**：有抓包 → `deadline` 轮询；超时且 `auto` → `visual_locate` 兜底；超时且 `coordinate` → None。**`time.sleep(max(interval, 0.05))`（:266）——间隔下限 50ms 强制**。

### 4.3 teleport_to_point.py（968 行）—— 十一步传送流程

**9 个 ROI + 1 确认点（本地 :44-53 逐字核对，注释明示「所有 ROI 都基于 1280x720」）**：

| 常量 | 坐标 |
|---|---|
| `MAP_INDEX_ICON_ROI` | [1069, 626, 89, 74] |
| `MAP_INDEX_TITLE_ROI` | [907, 66, 121, 36] |
| `AREA_NAME_ROI` | [958, 127, 235, 40] |
| `AREA_NEXT_BTN_ROI` | [1203, 126, 44, 42] |
| `MAIN_SELECTION_ROI` | [901, 176, 358, 460] |
| `SUB_SELECTION_ROI` | [1190, 180, 55, 461] |
| **`TELEPORT_CONFIRM_POINT`** | **[639, 361]**（屏幕中心附近） |
| `TELEPORT_BUTTON_ROI` | [933, 620, 332, 45] |
| `ZOOM_CONTROL_BTN_ROI` | [47, 258, 34, 242] |

**按键与阈值（:55-67）**：`KEY_ESC=27` / `KEY_M=77`（打开地图）；模板 0.8 / **OCR 0.5（比 AGENTS.md 建议的 0.3 严格）**；最大地区切换 15 次；动作间隔 0.5s；开图等待 1.0s；最终确认 1.0s。**静止检测**：max_wait 8.0 / interval 0.25 / **consecutive 2** / diff_threshold 1.5。

**`TeleportPoint` dataclass**（:70-80）9 字段：id/name/point/coordinate_type/area_name/icon_index/selection_name/icon_path/description。

**三大关键工程点**：

1. **`_press_key_action`（:166-191）—— 按键不走 controller 直发**。源注释（:167）："通过 Pipeline 的 ClickKey 发键，避免 CustomAction 内直接调用 controller 按键时的原生层异常。" → 临时节点 `__MapTeleportPressKey` + override。
2. **`_click_rect_action`（:194-217）—— 点击同样走 Pipeline**。注释："关键确认点击同样交给 Pipeline Click，兼容 SeizeInput 等不同控制器实现"（前台控制器独占输入，只有走 Pipeline 才生效）。
3. **`_wait_screen_still`（:275-319）—— 动效期稳定性守卫**：`_is_stopping` 立即返回 None → 降采样 160×90 → 灰度 → `absdiff` → `np.mean` = diff → **diff ≤1.5 连续 2 次即稳定**；超时返回 `last_frame`（不返回 None）。

**`_find_template_matches`（:331-379）—— 多目标模板匹配**：ROI 与帧尺寸求交 clamp；`TM_CCOEFF_NORMED` + **`np.nan_to_num(nan/posinf/neginf → -1.0)` 防 NaN 污染**；循环取最高分 → **把该点周围 `template_w × template_h` 置 -1.0（非极大值抑制）** → 最多 20 个 → 按 `(y,x)` 排序。

**十一步主流程**（`run_map_teleport_flow`，:795-921）：
`load_teleport_point` → `_ensure_in_world` → **按 M 打开地图** → `_drag_zoom_control` → `_click_map_index` → `_wait_ocr_text("地图索引")` → `_switch_to_area`（≤15 次）→ `_click_main_selection` → `_click_teleport_icon` → **静止(5s)→ESC→点中心 2×2 矩形** → `_click_teleport_button` → `_wait_teleport_loading`。

**⚠️ 三步顺序不可换**（:897 源注释逐字）："选中传送点后先退出地图指引，再点屏幕中央附近打开最终传送确认框。"

**数据资产（本地核对）**：`teleport_points.json` 10 条（字段含 `worldX/worldY/areaName/iconIndex/selectionName/iconPath`）；`check_points.json` 1 条锚点。**喷泉两表坐标不同**：传送点 `(-152904.578, 129793.907)` vs 检查点 `(-151702, 151178)`——**传送落点 ≠ 导航目标**；检查点 `threshold=7000`（非默认 200），7000 世界单位 ≈ 114 像素。

**⚠️ 与 AGENTS.md 的对照**：本模块大面积用 `time.sleep` 硬延迟（0.5/1.0/1.0/0.25）——与「避免硬延迟」通则不同。**原因：地图 UI 是强动画、无稳定识别锚点的场景，静止检测 + 固定延迟是唯一可靠手段——这是有意识的例外，不是遗漏。**

---

## 5. 小游戏三件套（Tetris 1490 + rhythm 1611 + auto_piano 782）

### 5.1 共性架构

```
utils/（算法与资源层：模板加载、场景判定、布局计算）← 无 MaaFramework 依赖，可独立测试
feats/ 或 action.py（CustomAction 注册层：收参 → 循环 → 报结果）
独立 SceneGate / SceneDetector（场景门：确认当前在正确界面才动手）
```

**⚠️ 三模块都实现了自己的 `SceneGate`**（Tetris 46 行 / rhythm 20 行）——**重复实现但接口一致**；这是「每个子游戏独立可裁剪」的代价。

### 5.2 Tetris（6 文件 1490 行）—— 启发式评估 + T-Spin

**`board.py`（412 行）9 个几何特征函数**：`calculate_column_heights` / `calculate_holes`（**返回 4 元组：holes/hole_depth/covered_holes/hard_holes**）/ `calculate_transitions`（**2 元组：行/列转换**）/ `calculate_well_penalty` / `calculate_open_well_reward`（**保留 I 块四消位**）/ `calculate_edge_height_penalty` / `calculate_center_stack_penalty` / `calculate_horizontal_balance_penalty`（**标准差，全平返回 0**）。

**三档高度自适应权重（本地 :220-241 核对，本模块核心）**：

| 权重项 | avg<8 | 8≤avg<14 | avg≥14 |
|---|---|---|---|
| **lines_weight（消行）** | **42.0** | 34.18 | **28.0** |
| **holes_weight（空洞）** | 32.0 | 38.99 | **52.0** |
| height_weight | 0.95 | 1.30 | 1.85 |
| bumpiness_weight | 1.4 | 1.84 | 2.2 |
| transitions_weight | 2.5 | 3.21 | 4.0 |
| well_weight | 2.8 | 3.38 | 4.5 |
| open_well_weight | 1.5 | 1.0 | 0.5 |
| center_stack_weight | 0.5 | 1.5 | 3.0 |
| balance_weight | 0.3 | 0.8 | 1.5 |

**设计意图：低堆鼓励消行（42），高堆防空洞（52）——同一评估函数在不同阶段自动换性格。** 占用率 >0.45 → `holes_weight ×1.3 + well_weight ×1.2`（:251）。
**评分公式**（:271）：`− col_transitions × (transitions_weight × 2.9)`（**列转换权重是行的 2.9 倍**）；`combo>1 → +combo×25`；`is_t_spin → +lines×30 + 40`。

**`detect_t_spin`（:136-192）—— 角块法**：前角偏移表按 rotation 取两组对角，后角互补；`was_rotation_move=True` 时 **`is_t_spin = 前角≥2 且 总角≥3`**，`is_mini = 非 t_spin 且 前角≥2`；否则非 T-Spin，`is_mini = 总角≥3`。**符合标准 T-Spin 三角规则。**

**`evaluate_board_fast`（:288-311）**：只算 5 项、固定权重——**用于搜索空间剪枝**。

### 5.3 rhythm（10 文件 1611 行）—— 音游自动演奏

**`config.py`（132 行）全套默认值（本地 :31-109 逐条核对）**：

| 参数 | 默认 | 参数 | 默认 |
|---|---|---|---|
| **note_speed_px_per_sec** | **900.0** | **input_latency_sec** | **0.035** |
| schedule_window_sec | 0.22 | chord_window_sec | 0.022 |
| **min_tap_interval_sec** | **0.035**（四轨同值） | same_frame_chord_window_sec | 0.045 |
| stale_note_sec | 0.045 | **trigger_line_offset_frac** | **-0.012** |
| **key_hold_sec** | **0.03** | **target_fps** | **60** |
| lanes center_x_frac | [0.225,0.406,0.596,0.771] | thresholds（每轨独立） | [0.81,0.80,0.80,0.81] |
| vitality roi | [544,622,184,46] | min_confirm_reads | 2 |

**⚠️ `note_speed_px_per_sec = 900.0` 是全模块最关键的标定值**：调度器用它把「音符当前 Y」换算成「还有多少秒到判定线」，再减 `input_latency_sec=0.035` 得实际发键时刻。**这两个值若与被测环境不符，整条调度链全错（表现为持续过早/过晚）**；`trigger_line_offset_frac=-0.012`（判定线上移 1.2%）是第二处补偿。

**`load_rhythm_config()`（:115-131）**：从 `__file__` 逐级向上同时试 `<root>/resource/base/rhythm_config.json` 与 `<root>/assets/resource/base/rhythm_config.json`；解析异常 warning 继续找；全找不到返回 `dict(_DEFAULT_CONFIG)`。**配合 `build_lane_layout(cfg, w, h)` 占比 × 实际帧尺寸 = 像素布局——分辨率无关。**

**算法层**：`detector.py`(189) `DrumDetector` 多候选+NMS / `lanes.py`(58) `LaneLayout` / `presence.py`(100) `SceneGate` 三态 / `assets.py`(81) 模板列举 / `song_selector.py`(220) 滚动找歌。
**feats 层**：`play.py`(505) **`_KeyScheduler` 核心调度器** + `_normalize_same_frame_chords`(192) / `select_song.py`(95) / `repeat_decision.py`(203) 体力检测。

### 5.4 AutoPiano（782 行）—— MIDI 自动弹奏

**`key_mapping.py`（121 行）36 键映射——本模块最有价值的资产**：
- 物理布局：3 个八度 × 12 音阶 = 36 键；高音 QWERTYU、中音 ASDFGHJ、低音 ZXCVBNM，各 + Shift/Ctrl 半音。
- **半音规则：`Shift + 白键 = 升半音 (#)`；`Ctrl + 白键 = 降半音 (b)`。**
- **⚠️ 半音键选择不是机械规则**：61 用 `shift+z`（C#4），但 63 用 `ctrl+c`（D#4/Eb4）——**升号优先 Shift、降号优先 Ctrl 的混合策略，取决于游戏内哪个组合可用**（避免与相邻键冲突）。
- `snap_to_white_key(midi)`：黑键 → 最近白键，**等距时优先低音方向（向下取整）**。
- `get_mapping(key_mode)`：`"36"` 完整 36 键；`"21"` 仅白键 21 键（黑键自动吸附）。

**`maa_keyboard.py`（144 行）—— 唯一直接操作 Win32 输入的模块**：
- **⚠️ 注释（:13）："使用游戏专用的左 Shift 和左 Ctrl 防跑调。"** → `VK_SHIFT = 0xA0`（VK_LSHIFT），`VK_CONTROL = 0xA2`（VK_LCONTROL）——**不是通用 VK_SHIFT 0x10**。
- 窗口标题：`"NTE  "` / `"异环  "`（**各带两个尾空格，精确匹配窗体标题**）。
- `get_lparam(vk, is_down)`：`scan = MapVirtualKeyW(vk, 0)` → `lparam = 1 | (scan << 16)` → 抬起时 `|= 0xC0000000`（bits 30/31）。
- **构造默认 `hold_seconds = 0.008`（8ms）**。

**原因**：钢琴要求极低延迟按键（8ms）+ 修饰键组合 + 精确扫描码，走 pipeline 的 ClickKey 无法满足；代价是**必须依赖 Windows + 前台窗口**。

---

## 6. 实时辅助（SoundTrigger 571 + 排球 321 + realtime_task 49 + auto_f_scroll 43）

### 6.1 SoundTrigger 三件套 —— 听声 → 判定 → 动作

**三层解耦数据流**：
```
声音采集（Ear，soundcard 回环）→ 相关匹配打分 → 阈值判定
                                        ↓ 回调
                      动作队列（Ctx._action_queue，maxsize=1）
                                        ↓ 主线程消费
                      执行器（Dodger，冷却+互斥锁）→ controller.post_click_key
```

**⚠️ 三层各有独立抗抖动**：Ear 有 `_trigger_cd = 0.5`（:50 本地核对）；**队列 maxsize=1（满即丢——丢的是旧动作，不是阻塞）**；Dodger 有 `_dodge_cd=0.5` / `_counter_cd=1.0` + **`_busy` 互斥标志（动作执行期间不重入）**。

**SoundListener.py（215 行）`Ear` 类常量（本地 :26-33 逐字核对）**：

| 常量 | 值 | 语义 |
|---|---|---|
| `sr` | **32000** | 采样率 |
| `ch` | 2 | 声道 |
| `chunk` | **1600** | 每次录制帧数（= 20ms @ 32k） |
| `sample_len` | **0.2** | 匹配窗口 0.2 秒 |
| `interval` | **0.05** | 每 50ms 匹配一次（20 次/秒） |
| `log_every` | 40 | 每 40 次打印一次分数（2 秒一条日志） |
| `degree` | 4 | 巴特沃斯阶数 |
| `cut_off` | **1000** | 高通截止 1000Hz（滤人声/低频，保留打击音） |

构造：`threshold=0.13` / `counter_threshold=0.12`（:39-40）。

**四个关键实现**：

1. **`_cache_load`（:74-82）npy 缓存**：缓存键 `{path}_{sr}_{degree}_{cut_off}.npy`——**改任一参数自动失效重算**；mtime 比较让 wav 更新自动失效。
2. **`_filt`（:84-87）零相位滤波**：`scipy.signal.filtfilt`（正反各一次），避免相位延迟导致触发时刻偏移——**对时序敏感场景必须 filtfilt 而非 lfilter**。
3. **`match`（:89-101）归一化互相关**：`_norm` 用 RMS（`rms = sqrt(mean(wf²)+1e-6)` 防静音除零）→ **匹配与音量无关**；`correlate(长, 短, mode="same", method="fft")` → 除长度归一化（≈1.0 满分，与 0.13 阈值可直接比）。
4. **环形缓冲**：`buf = np.zeros(max_s*2)`（双倍窗口）——record 按 1600 帧（50ms）拿、匹配窗口 200ms，**必须跨 4 次 record 才能凑满，环形缓冲实现「滑动窗口」**；跨尾处理（`end > max_s*2` 时拆两段写）。

**回环录音（`_open_device`, :122-125）**：`sc.default_speaker()` → `sc.get_microphone(id=str(speaker.name), include_loopback=True)`——**录的是系统播放的声音，不是物理麦克风**。代价：必须有播放设备 + 支持 WASAPI 回环（**Windows 专属**）。

**`_check`（:194-215）双阈值 + 优先级仲裁 —— 本文件最细致的设计**：
```python
if now - self._last_trigger < self._trigger_cd: return    # 500ms 冷却
dodge_hit    = d_score >= 0.13
counter_hit  = c_score >= 0.12
dodge_confidence    = d_score / max(0.13, 1e-6)     # 相对置信度
counter_confidence  = c_score / max(0.12, 1e-6)
if dodge_hit and (not counter_hit or dodge_confidence >= counter_confidence):
    self.on_dodge(); return
if counter_hit: self.on_counter()
```
**⚠️ 为什么用相对置信度**：两阈值不同（0.13/0.12），**若直接比原始分会偏向阈值低的那类**；除以各自阈值即得「超阈值几倍」的公平比较。

**Dodger（DodgeCounterTrigger.py 95 行）**：`VK_SHIFT = 0xA0`（左 Shift，与钢琴模块同一约定）；**时间闸门在锁外、`_busy` 检查在锁内——快速路径不争锁，慢路径互斥**。两个默认动作：dodge = 左Shift按下 → `sleep(0.1+random()*0.1)`（**100-200ms 随机**）→ 释放；counter = `random.choice([0x31,0x32,0x33,0x34])`（数字键 1-4 随机）→ sleep(0.02) → 左Shift。**随机化意义：输入时序去规律化 + 扫弦式随机应对「反击键位随场景不同」。**

**SoundDodgeAction（250 行）**：4 个参数解析器，其中 `_get_config_value(context, node_name, key, default)`（:50）是**全项目唯一「从 pipeline 节点配置读参数」的实现**——**参数优先级：custom_action_param > 节点配置 > 代码默认**。注册名 **`SoundDodgeAction`（大驼峰，同类唯一例外）**。`Ctx` 用 `queue.Queue(maxsize=1)`，`_enqueue_action` 满则 `logger.debug("Dropping stale sound action: %s")`。**关键分支（:99-101）**：`ear.on_counter = self._on_dodge if dodge_all_attacks else self._on_counter`——**反击音也当闪避处理（"无敌躲"模式）**。

### 6.2 排球（auto_volleyball.py，321 行，本地 :13-40 逐字核对）

**5 个注册动作**：`volleyball_reset`(158) / `volleyball_select_difficulty`(177) / `volleyball_select_teammates`(195) / `volleyball_play`(251) / `volleyball_advance_difficulty`(300)。

**常量表**：`_K_KEY=0x4B` / `_KEY_PRESS_INTERVAL_SECONDS=0.6` / `_RESULT_CHECK_INTERVAL_SECONDS=5.0` / **`_MAX_GAME_SECONDS=600.0`（单局上限 10 分钟）** / `_TEAMMATE_SELECTION_TIMEOUT=30.0` / `_TEAMMATE_CONFIRM_TIMEOUT=2.0` / `_TEAMMATE_FAILURE_LIMIT=5` / `_TEMPLATE_THRESHOLD=0.8`。

**4 档难度 ROI**：`{1:(158,254,91,86), 2:(458,337,74,77), 3:(766,264,76,75), 4:(1067,337,69,70)}`。
**三态结算**：`skip`→SkipButton.png (1223,29,28,26)（右上角跳过）/ `win`→Win.png (937,71,308,110) / `loss`→Lose.png (879,72,363,105)。

**7 角色表**（id / 显示名 / 确认 ROI / 头像点击 ROI）：

| id | 显示名 | 确认 ROI | 头像点击 |
|---|---|---|---|
| 1 | 薄荷 | (323,94,103,76) | (407,166,**1,1**) |
| 2 | 零 | (443,98,89,70) | (519,167,**1,1**) |
| 3 | 娜娜莉 | (554,98,89,70) | (633,170,**1,1**) |
| 4 | 残虹 | (332,208,89,69) | (407,276,**1,1**) |
| 5 | 卡厄斯 | (444,209,88,68) | (516,279,**1,1**) |
| 6 | 真红 | (556,208,88,70) | (630,278,**1,1**) |
| 7 | 伊洛伊 | (332,318,89,70) | (410,386,**1,1**) |

**⚠️ 头像点击 ROI 全是 `1×1` 像素**——**表示"点这个单点"（ROI 只作坐标用）**；确认 ROI 是完整头像框（用于模板验证是否已选中）。`_current_difficulty = 1` 是**模块级全局状态**（对应 AGENTS.md「模块级状态用全局变量 + 独立 `_reset` 动作」约定）。

**`_match_state`（:65-82）**：遍历三态 → `context.run_recognition_direct(JRecognitionType.TemplateMatch, JTemplateMatch(template=[t], roi=..., threshold=[0.8]), frame)` → **命中即返回态名**。

### 6.3 realtime_task.py（49 行）—— 动态节点调度（「实时辅助模式」的核心开关）

```python
HOLDER_NODE_NAME = "__RealTimeTaskAction_Holder"

def _build_pipeline_override(nodes):
    return {HOLDER_NODE_NAME: {"next": nodes}}

def run(self, context, argv):
    while not context.tasker.stopping:
        result = context.run_task(HOLDER_NODE_NAME, pipeline_override)
        ...
```

**设计解读**：**一个空壳节点（无 recognition/action）+ 动态 `next` 列表**——**把「运行哪些节点」从 pipeline 静态定义变成运行时参数**；循环直到 tasker 停止。RealtimeAssistance preset 即靠此实现。

`_parse_nodes`（:14-31）**五重校验**：空参 → `ValueError("empty custom_action_param")`；非 dict → JSON 解析失败报错；`nodes` 非 list 或空 → 报错；逐项非 str → 报错；返回节点名列表。

### 6.4 auto_f_scroll.py（43 行）—— F 键连点（最小动作）

`auto_f_scroll` 注册，**43 行极简实现（无状态、单动作）**：检测物理 F 键状态 → 长按时同时发 MAA 按键 + Windows 滚轮事件（`MOUSEEVENTF_WHEEL`，`-120`）实现极速翻页。**注意它用 `GetAsyncKeyState`（Windows）**，对应 AuroraDrive 的 `KeyboardMonitor`。

---

## 7. 生活任务与长尾模块

### 7.1 Common（676 行）—— 全项目被引用最多的模块

| 文件 | 行 | 内容 |
|---|---|---|
| `CharacterAbility_CityAbility.py` | **370** | 角色/城市能力同步（Common 下最大文件） |
| `resize_game_window.py` | 113 | 窗口尺寸动作（**平台优雅降级范例**） |
| `utils.py` | 90 | **`get_image` / `click_rect` / `match_template_in_region`（三大公用工具）** |
| `click.py` | 31 | `ClickOverride`（`click_override`：支持显式 target 或 reco_detail box） |
| `alt_click.py` | 29 | `AltClick`（Alt+点击） |
| `enable_node.py` | 27 | `EnableNode`（运行时启用/禁用 pipeline 节点） |

**`resize_game_window.py` 降级模式**：`try: from utils.win32_process import ensure_game_window_resolution except ImportError: ensure_game_window_resolution = None` → `if ensure_game_window_resolution is None: return RunResult(success=?)`。**win32 能力缺失时动作变 no-op，任务链不中断——全项目唯一的跨平台降级手段**。

### 7.2 AutoFish（9 文件 1447 行）—— 项目最完整的单功能链

**双实现并存**：`auto_fish.py`(364) CV 版 vs `auto_fish_withoutCV.py`(264) 纯时序/音频版——**注册为不同动作名，由 pipeline 选择**。其余：`auto_buy_fish_bait.py`(169) / `auto_sell_fish.py`(153) / `enter_fishprepare.py`(71) / `auto_choose_fish_store_general_bait.py`(114) / `fish_control.py`(151) / `fish_params.py`(89) / `fish_vision.py`(72)。

**钓鱼小游戏拉条平衡**：`deadzone=15`（像素死区）；A/D 控制滑块左右；每 10 帧按一次 F（模拟拉力）；**滑块丢失时保持最后已知位置 15 帧**；模板阈值 0.7。

### 7.3 pinkpaw（6507 行）—— 全项目最大模块

`pinkpaw_core3.py`(3787) 是全项目单文件最长者。三方案 + `pinkpaw_common.py`(65, 三重 try 导入 win32) + `pinkpaw_entrance_recovery.py`(540) + `pinkpaw_reward_logger.py`(258)。**每次进 pinkpaw 都先强制窗口拉到标准分辨率**（core1/2/3/entrance_recovery 四处调用）。

### 7.4 其余长尾

- **AutoCoffee**（536 行）：`auto_make_coffee.py`(117) / `auto_make_coffee_lite.py`(129) / `auto_make_tomato_juice.py`(236) + `utils.py`(54)。番茄汁 `TOMATO_JUICE_SERVINGS=2` / `SECOND_GUEST_REMAINING_SECONDS=111`。
- **Furniture**（162 行）：6 个 switch option（每房产一个 Yes/No），`controller: ["Win32-Front"]` 是唯一在任务 JSON 里锁定控制器的场景。
- **BagelSpam**（338 行）：`bagel_spam_llm.py`(255) LLM 生成 + `bagel_spam_text.py`(79) 固定文本，5 个 option。
- **DatasetCollection**（222 行）：`autonomous_driving_dataset_recorder` —— **MaaNTE 与 AuroraDrive 的交叉点**（录制面向自动驾驶训练的数据集）。
- **withdraw_money**（136 行）：OCR 识别价格 + 按 value 降序取 top5 点击；支持 `1,234` / `1.5K` 格式。
- **SyncCharacterAbilityCityAbility**（427 行）：遍历角色列表 OCR 识别名字+技能等级；16 角色名映射表；`fresh_record=True` 全新记录模式。
- **auto_volleyball_weekly**（226 行）：排球周赛，4 个注册动作。
- **lucky_star_round**（116 行）：3 个注册动作。

---

## 8. 对本项目的可借鉴点

| # | 借鉴点 | 对应 AuroraDrive 现状 |
|---|---|---|
| 1 | **SoundTrigger 三层解耦 + 三重抗抖** | AuroraDrive 有 EmergencyTakeover 让位但无音频驱动 |
| 2 | **相对置信度仲裁**（除以各自阈值再比） | 可用于多模型置信度对比 |
| 3 | **realtime_task 空壳节点 + 动态 next** | AuroraDrive 的 `RealTimeTaskAction` 是 pipeline 编排范式，tick 是线性回路 |
| 4 | **pinkpaw 自适应超时**（首轮测实际耗时 ×1.2） | 可用于 AuroraDrive 的 E2E 模型推理超时 |
| 5 | **包双模式导入**（正常相对 + 降级 ModuleType） | 可参考做 Swift 的「测试环境独立加载」 |
| 6 | **`_wait_screen_still` 静止守卫**（降采样+absdiff+连续2帧） | AuroraDrive 的画面变化检测可参考 |
| 7 | **Tetris 三档动态权重**（低堆鼓励消行，高堆防空洞） | 可用于自适应驾驶策略（不同路况不同权重） |
| 8 | **rhythm 900px/s + 35ms 延迟补偿** | 时间预测+延迟补偿范式，AuroraDrive 的 EgoMotion 有类似光流时间换算 |

---

## 9. 已过期 / 未验证项

| 项 | 状态 |
|---|---|
| Maa-15 称「28 task / 78 option / 25 文件」 | ⚠️ **已过期** → 实测 30 task / 86 option / 27 文件 |
| Maa-15 未提 VolleyballWeekly.json / PukaLand.json | ⚠️ **遗漏** → 上游新增 |
| Maa-13 称 Tetris「6 文件 704 行」 | ⚠️ **已过期** → 实测 6 文件 1490 行（feats/play.py 786 行未计） |
| Maa-13 称 rhythm「9 文件 ~1200 行」 | ⚠️ **已过期** → 实测 10 文件 1611 行 |
| Maa-13 称 auto_piano「5 文件 ~500 行」 | ⚠️ **已过期** → 实测 782 行 |
| Maa-14 称 SoundTrigger「3 文件 ~400 行」 | ⚠️ **已过期** → 实测 4 文件 571 行 |
| Maa-15 称「48 个注册动作」 | ⚠️ **已过期** → 实测 57 个 |
| `models/ayolom/NOTICE.md:107` 引用 `YolopxEngine.swift:644` | ⚠️ **行号漂移** → 当前候选表在 :625-663 |
| Navi 标定常量 TX/TY | ⚠️ **上游仍 6293/3472**（11264 图），AuroraDrive 已升 6526/5210（13056 图） |
| `lucky_star_round.py` 对应哪个 task JSON | **未验证**（猜测 PukaLand，未确认） |

---

## 10. 原文处置建议

| 原文 | 处置 | 理由 |
|---|---|---|
| `MAA深度文档_功能篇.md`（735） | **保留** | 功能全览仍有准确，但行数统计已漂移 |
| `MAA深度文档_扩展篇.md`（600） | **保留** | 开发规范与调试技巧仍有价值 |
| `Maa-11-Navi导航系统全链.md`（339） | **保留** | 14 文件全链分析质量高，标定常量需标注上游版本 |
| `Maa-12-MapTeleport地图传送系统.md`（298） | **保留** | 十一步流程 + 三大工程点仍是宝贵记录 |
| `Maa-13-小游戏三件套.md`（282） | **保留，需更新行数** | 算法描述准确，但行数全部过期 |
| `Maa-14-实时辅助SoundTrigger与排球.md`（298） | **保留，需更新行数** | 三层解耦分析到位，但文件数/行数过期 |
| `Maa-15-生活任务与长尾.md`（229） | **保留，需更新统计** | task/option/文件数已漂移，需重算 |

**本篇新增核对结论**：①实测 30 task/86 option/27 文件（推翻 28/78/25）；②rhythm 全 10 项默认值逐条本地核对一致；③Tetris 9 权重 × 3 档本地核对一致；④排球 7 角色 4 难度 3 结算态本地核对一致；⑤SoundTrigger 8 常量 + 相对置信度算法本地核对一致；⑥Teleport 9 ROI + 10 步流程 + 3 大工程点本地核对一致。

---

*本篇为整合文档，未删改任何原文件。代码引用均已去本地 `MaaNTE/` 核对。*
