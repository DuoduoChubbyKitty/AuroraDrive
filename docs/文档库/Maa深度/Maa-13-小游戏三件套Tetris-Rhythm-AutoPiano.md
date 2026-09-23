# Maa-13 小游戏三件套：Tetris / Rhythm / AutoPiano

> 覆盖源文件：`MaaNTE/agent/custom/action/Tetris/`（704 行）+ `rhythm/`（1486 行）+ `auto_piano/`（802 行）+ `auto_tetris.py`，合计 3883 行。基于当前仓库逐单元编写。

## 一、三模块共性与注册动作

| 模块 | 文件数 | 行数 | 注册动作（pipeline 调用名） |
|---|---|---|---|
| **Tetris** | 6 | 704 | `tetris_reset_context`（auto_tetris.py 22 行）+ AutoTetris |
| **Rhythm** | 10 | 1486 | `auto_rhythm_play` / `auto_rhythm_select_song` / `auto_rhythm_repeat_decision` / `auto_rhythm_vitality_on_results` |
| **AutoPiano** | 5 | 802 | `auto_play_piano`（action.py 35 行） |

**三者的共同架构**：

```
utils/（算法与资源层：模板加载、场景判定、布局计算）      ← 无 MaaFramework 依赖，可独立测试
feats/ 或 action.py（CustomAction 注册层：收参 → 循环 → 报结果）
独立模块 SceneGate / SceneDetector（场景门：确认当前在正确界面才动手）
```

**⚠️ 三模块都实现了自己的 `SceneGate`**（Tetris/utils/scene.py 46 行、rhythm/utils/presence.py 20 行）——**重复实现但接口一致：投喂帧 → 返回当前场景态**；这是"每个子游戏独立可裁剪"的代价。

## 二、Tetris（704 行）——启发式评估 + 场景识别

### 2.1 board.py（412 行）——评分函数族

**7 个几何特征函数**：

| 函数 | 行 | 语义 |
|---|---|---|
| `calculate_column_heights` | 18 | 每列高度（最顶块的行距） |
| `calculate_holes` | 29 | **返回 4 元组：holes / hole_depth / covered_holes / hard_holes** |
| `calculate_transitions` | 53 | **返回 2 元组：行转换 / 列转换**（表面凹凸度的经典度量） |
| `calculate_well_penalty` | 79 | 井（深窄空槽）惩罚 |
| `calculate_open_well_reward` | 90 | **开放井奖励（保留 I 块四消位）** |
| `calculate_edge_height_penalty` | 101 | 边缘高柱惩罚 |
| `calculate_center_stack_penalty` | 107 | 中间堆高惩罚 |
| `calculate_horizontal_balance_penalty` | 119 | **标准差（`sqrt(variance)`）——全平返回 0** |

**`detect_t_spin`（130–192 行）——T-Spin 判定（角块法）**：

- 非 T 块直接返回 False
- **前角偏移表（143–148 行）按 rotation 0–3 取两组对角**（T 块旋转后"正面两角"位置）；**后角偏移表（149–154 行）是互补的两角**
- 逐角判越界或占用 → 计数 `front_corners_blocked` / `back_corners_blocked`
- **判定（182–191 行）**：
  - `was_rotation_move=True`：**`is_t_spin = 前角 ≥ 2 且 总角 ≥ 3`**；`is_mini = 非 t_spin 且 前角 ≥ 2`
  - `was_rotation_move=False`：**非 T-Spin；`is_mini = 总角 ≥ 3`**
- **符合标准 T-Spin 三角规则**（前两角 + 后一角，共三角被占）

**`evaluate_board`（195–285 行）——动态权重评分（本模块核心）**：

**三档高度自适应权重（215–248 行）**：

| 权重项 | avg_height < 8 | 8 ≤ avg < 14 | avg ≥ 14 |
|---|---|---|---|
| **lines_weight（消行）** | **42.0** | 34.18 | 28.0 |
| **holes_weight（空洞）** | 32.0 | 38.99 | **52.0** |
| height_weight | 0.95 | 1.30 | 1.85 |
| bumpiness_weight | 1.4 | 1.84 | 2.2 |
| transitions_weight | 2.5 | 3.21 | 4.0 |
| well_weight | 2.8 | 3.38 | 4.5 |
| open_well_weight | 1.5 | 1.0 | 0.5 |
| center_stack_weight | 0.5 | 1.5 | 3.0 |
| balance_weight | 0.3 | 0.8 | 1.5 |

- **设计意图：低堆时鼓励消行（42 权重），高堆时防空洞（52 权重）**——**同一评估函数在局面不同阶段自动换性格**
- **占用率增益（250–252 行）**：`occupancy > 0.45` → **holes_weight × 1.3 + well_weight × 1.2**（高危时进一步保守）
- **`dynamic_weights=False` 时固定用中档**（253–262 行，**兜底档位，供快速评估/回归**）

**评分公式（264–276 行）**：

```
score = lines_cleared×lines_w
        − aggregate_height×height_w
        − holes×holes_w − hard_holes×(holes_w×0.5)
        − bumpiness×bumpiness_w
        − row_transitions×transitions_w
        − col_transitions×(transitions_w×2.9)      ← 列转换权重是行的 2.9 倍
        − well_penalty×well_w + open_well_reward×open_well_w
        − center_stack_penalty×center_stack_w
        − horizontal_balance_penalty×balance_w
```

**额外奖励**：`combo_count > 1` → **+ combo_count × 25.0**（278–279 行）；`is_t_spin` → **+ lines_cleared × 30.0 + 40.0**（281–283 行）。

**`evaluate_board_fast`（288–311 行）——快速版**：只算 5 项（heights/holes+hard_holes/aggregate/bumpiness/center/balance），**固定权重（消行 35 / 空洞 40 / 硬洞 20 / 高 1.2 / 凹凸 1.5）**——**用于搜索空间剪枝**。

**`simulate_drop`（314 行起）**：`shape` 的宽高由 `max` 推导（315–316 行）→ **列越界返回 None（317–318 行）**——**落点模拟（供 AI 枚举候选）**。

**图像裁剪**：`extract_board_crop`（395 行）/ `extract_queue_crop`（405 行）——**棋面板与 next 队列的固定裁剪**。

### 2.2 pieces.py（64 行）与 scene.py（193 行）

**pieces.py**：

- **`normalize_cells`（38 行）**：方块坐标归一（平移到左上）
- **`match_piece_state(cells)`（45 行）**：**由形状反查方块名 + 旋转态**（识别当前块）
- **`rotation_distance(piece_name, current_rotation, target_rotation)`（60 行）**：**最短旋转步数（考虑顺/逆时针与 4 态循环）**——**AI 决策的代价项**

**scene.py**：

- `_find_image_root()`（13 行）/ `get_image_root()`（30 行）——**图像根定位（向上搜索，与 Navi/rhythm 同模式）**
- `_read_image(name)`（37 行）——模板读入
- **`SceneGate`（46 行起）**：场景门（投喂帧 → 判定是否在俄罗斯方块界面）

**`scene_detector.py`（35 行）**：**`TetrisSceneDetector`（9 行）——轻量场景检测（与 SceneGate 并行存在的另一实现）**

## 三、Rhythm（1486 行）——音游自动演奏

### 3.1 config.py（132 行）——全套可调参数（默认值内嵌）

**`_DEFAULT_CONFIG` 九大段（10–112 行）**：

| 段 | 关键参数 | 默认值 |
|---|---|---|
| **lanes** | center_x_frac（4 轨中心 X 占比） | [0.225, 0.406, 0.596, 0.771] |
| | **top_center_x_frac**（顶部轨心，**透视修正**） | [0.214, 0.406, 0.596, 0.783] |
| | half_width_frac | 0.028 |
| | **judge_line_y_frac / _by_lane** | 0.78（四轨同值） |
| | judge_band_half_height_frac | 0.03 |
| **template_detection** | **thresholds（每轨独立阈值）** | [0.81, 0.80, 0.80, 0.81] |
| | region_extend_up/down_frac | 0.14 / 0.15 |
| | region_width_multiplier | 4.0 |
| | **simultaneous_score_margin / candidate_threshold_margin** | 0.04 / 0.03 |
| | **candidate_nms_distance_px** | 30.0（非极大值抑制距离） |
| | max_candidates_per_lane / enabled_lanes | 4 / [T,T,T,T] |
| **position_trigger** | **trigger_line_offset_frac** | **-0.012（判定线略上移——补偿视觉延迟）** |
| | **min_tap_interval_sec（+ by_lane）** | 0.035（**每轨独立限速**） |
| | **note_speed_px_per_sec** | **900.0（音符下落速度——预测抵线时刻的核心）** |
| | **input_latency_sec** | **0.035（输入延迟补偿）** |
| | schedule_window_sec | 0.22（调度前瞻窗） |
| | **stale_note_sec / duplicate_window_sec / chord_window_sec** | 0.045 / 0.025 / 0.022 |
| | **same_frame_chord_window_sec** | 0.045 |
| **scene** | state_confirm_frames | 1 |
| | 三态匹配阈值（song_select / results / playing） | 全部 0.75 |
| | **song_select_to_playing_lock_sec** | 8.0（**切歌后 8s 内锁定为 playing，防误判回选择界面**） |
| | **template_roi**（三态各自的锚点 ROI） | song_select: logo[0,0,80,80]/level/start；playing: pause/rate/score；results: max_combo/rate/score |
| **song_select** | enabled / song_name | False / ""（**默认关闭自动选歌**） |
| | scroll_area_x/y_frac + scroll_delta(-1) + max_scroll_attempts(50) | 滚动找歌 |
| | click_reverify_threshold(0.70) + max_click_reverify_retries(2) | **点击后二次校验** |
| **auto_repeat** | enabled / count / dismiss_delay_sec | False / 5 / 0.8 |
| **vitality_detect** | **roi [544,622,184,46]** + **cost_pattern "(\d+)"** | 体力消耗 OCR |
| | **min_confirm_reads(2) + confirm_interval_sec(0.3) + vitality_threshold(1)** | 二次确认防误读 |
| **keys** | press_delay_sec（+ by_lane 全 0） | 0.0 |
| | **key_hold_sec** | **0.03（按键保持 30ms）** |
| | chord_reinforce_count / interval_sec | 1 / 0.006 |
| **run** | **target_fps** | **60（主循环目标帧率）** |
| | debug_score_interval_frames | 60 |

**`load_rhythm_config()`（115–131 行）——外部覆盖 + 兜底**：

- **从 `__file__` 起逐级向上（`for i in range(len(here.parents))`）同时试两条路径**：`<root>/resource/base/rhythm_config.json` 与 `<root>/assets/resource/base/rhythm_config.json`
- 首个存在且可解析的即返回 + info 日志
- **解析异常 → warning 继续找下一个；全找不到 → info + 返回 `dict(_DEFAULT_CONFIG)`（浅拷贝默认值）**
- **⚠️ 与 rhythm/utils/lanes.py 的 `build_lane_layout(cfg, frame_w, frame_h)`（17 行）配合：占比参数 × 实际帧尺寸 = 像素布局——分辨率无关**

### 3.2 算法层（4 文件 527 行）

| 文件 | 行 | 关键内容 |
|---|---|---|
| **detector.py** | 189 | **`DrumCandidate`（21 行）数据类 + `DrumDetector`（27 行）**——鼓点/音符候选检测（**多候选 + NMS**） |
| **lanes.py** | 58 | **`LaneLayout`（8 行）**（四轨像素布局）+ **`build_lane_layout`（17 行）**（占比 → 像素） |
| **presence.py** | 100 | **`SceneGate`（20 行）**——场景在场判定（**三态：选歌/演奏/结算**） |
| **assets.py** | 81 | `_get_image_root`（15）+ **`_list_templates(subdir)`（45）** + `list_scene_templates(kind)`（56）+ `list_song_templates`（60）+ `list_drum_templates`（64）+ **`read_image(p)`（76）** |
| **song_selector.py** | 220 | **`SongSelector`（21 行）**——滚动列表找指定歌（**配合 song_select 段参数**） |

### 3.3 feats/ 注册层（3 文件 723 行）

**`play.py`（505 行）——演奏主逻辑**：

- **`_KeyScheduler`（31 行起）**：**按键调度器（核心）**——按 `note_speed_px_per_sec` + `input_latency_sec` 预测每个音符的抵线时刻，用 `schedule_window_sec(0.22)` 前瞻排程，`min_tap_interval_sec(0.035)` 限速
- **`_normalize_same_frame_chords`（192 行）**：**同帧和弦归一**——`same_frame_chord_window_sec(0.045)` 内的多音符视为和弦（**同时按下，而非依次**）
- **`@AgentServer.custom_action("auto_rhythm_play")` → `AutoRhythmPlay`（229–230 行）**：主循环（**target_fps 60**）→ 截帧 → SceneGate 确认 → DrumDetector 找候选 → KeyScheduler 排程 → 发键；**每帧检查 `context.tasker.stopping`**

**`select_song.py`（95 行）**：**`@AgentServer.custom_action("auto_rhythm_select_song")` → `AutoRhythmSelectSong`（24–25 行）**——调 SongSelector（滚动 + 模板匹配 + 点击 + 二次校验）。

**`repeat_decision.py`（203 行）——两项**：

1. **`_detect_cost_vitality(context, frame, cfg)`（30 行）**：**在 vitality roi OCR 匹配 `(\d+)` 取体力消耗数值**
2. **`@AgentServer.custom_action("auto_rhythm_vitality_on_results")` → `AutoRhythmVitalityOnResults`（110–111 行）**：结算界面读体力
3. **`@AgentServer.custom_action("auto_rhythm_repeat_decision")` → `AutoRhythmRepeatDecision`（136–137 行）**：**按 `auto_repeat.count` 与体力阈值决定再开一局**

## 四、AutoPiano（802 行）——MIDI 自动弹奏

### 4.1 key_mapping.py（121 行）——36 键映射（本模块最有价值的资产）

**模块 docstring（1–11 行，逐字）**：

> 异环钢琴键位映射
> 游戏钢琴物理布局（3 个八度 × 12 音阶 = 36 键）：
>   高音：Q W E R T Y U  + Shift/Ctrl 半音
>   中音：A S D F G H J  + Shift/Ctrl 半音
>   低音：Z X C V B N M  + Shift/Ctrl 半音
> 半音规则：
>   **Shift + 白键 = 升半音 (#)**
>   **Ctrl  + 白键 = 降半音 (b)**

**`NOTE_KEY_MAPPING`（18 行起）——低音区样例（60–71）**：

| MIDI | 键 | 音 |
|---|---|---|
| 60 | `z` | C4 |
| 61 | **`shift+z`** | C#4 |
| 62 | `x` | D4 |
| 63 | **`ctrl+c`** | D#4/Eb4（**用 Ctrl+c 而非 Shift+x——避免与相邻键冲突**） |
| 64 | `c` | E4 |
| 65 | `v` | F4 |
| 66 | `shift+v` | F#4 |
| 67 | `b` | G4 |
| 68 | `shift+b` | G#4 |
| 69 | `n` | A4 |
| 70 | **`ctrl+m`** | A#4/Bb4 |
| 71 | `m` | B4 |

**⚠️ 半音键选择不是机械规则**（61 用 shift+z 但 63 用 ctrl+c）——**升号优先 Shift、降号优先 Ctrl 的混合策略，具体取决于游戏内哪个组合可用**。

**三个工具函数**：

| 函数 | 行 | 语义 |
|---|---|---|
| `is_white_key(midi)` | 82 | `midi % 12 in _WHITE_KEY_OFFSETS` |
| **`snap_to_white_key(midi)`** | 87 | **黑键 → 最近白键；等距时优先低音方向（向下取整）** |
| **`get_mapping(key_mode="36")`** | 110 | **`"36"` → 完整 36 键（含半音）；`"21"` → 仅白键 21 键（半音自动吸附最近白键）** |

### 4.2 midi_processor.py（170 行）+ player.py（280 行）

- **`MidiProcessor`（8 行）**：MIDI 文件解析（**mido 库**）→ 音符序列（pitch / 起始时刻 / 时长）
- **`AutoPianoStopped`（player.py 20 行）**：**自定义异常（停止信号）**
- **`AutoPianoSettings`（25 行）**：设置项（键位模式 / 速度 / 保持时长等）
- **`AutoPianoPlayer`（34 行）**：**主播放器**——按 MIDI 时间轴排程 → 发键（**含和弦处理与节奏对齐**）

### 4.3 maa_keyboard.py（144 行）——底层键盘注入

**Win32 常量与 VK 表（7–46 行）**：

```python
WM_KEYDOWN = 0x0100 ; WM_KEYUP = 0x0101
WM_ACTIVATE = 0x0006 ; WA_CLICKACTIVE = 2
WIN32_VK = {"shift": 0xA0, "ctrl": 0xA2, "a"–"z": 0x41–0x5A, ...}
```

**⚠️ 注释（13 行）**："使用游戏专用的左 Shift 和左 Ctrl 防跑调。"——**0xA0 = VK_LSHIFT，0xA2 = VK_LCONTROL（左键专用，不是通用 VK_SHIFT 0x10）**——**游戏只认左键，用通用码会跑调**。

**窗口标题（WINDOW_TITLES，48–51 行）**：**`"NTE  "` / `"异环  "`（注意各带两个尾空格——精确匹配游戏窗体标题）**。

**`get_lparam(vk_code, is_down=True)`（51–57 行）——硬件扫描码构造**：

```python
scan_code = user32.MapVirtualKeyW(vk_code, 0)     # VK → 扫描码
lparam = 1 | (scan_code << 16)                     # 重复计数 1 + 扫描码
if not is_down: lparam |= 0xC0000000               # 抬起标志（bits 30/31）
```

**`MaaKeyboardBridge`（60 行起）**：

- 构造参数：`hold_seconds=0.008`（**默认按键保持 8ms**）+ `mapping`（**默认 NOTE_KEY_MAPPING**）
- **按 WINDOW_TITLES 逐个 FindWindow 找窗口**（61–70 行）→ 存 hwnd
- **`mapping` 里的 `"shift+z"` 形态 → 拆解为修饰键按下 + 主键按下/抬起 + 修饰键抬起**（**播放器按 MIDI 音高查表驱动**）

### 4.4 action.py（64 行）——注册入口

- **`extract_param(argv)`（22 行）**：pipeline 参数提取
- **`@AgentServer.custom_action("auto_play_piano")` → `AutoPlayPiano`（35–36 行）**：收参（**midi 文件路径 / key_mode / 速度**）→ 构造 `AutoPianoPlayer` → 播放循环（**每轮检查停止信号，抛 `AutoPianoStopped` 优雅退出**）

## 五、三模块的横向对比（工程模式）

| 维度 | Tetris | Rhythm | AutoPiano |
|---|---|---|---|
| **核心算法** | 启发式评估（9 特征 + 3 档动态权重 + T-Spin） | 位置预测调度（900px/s + 35ms 延迟补偿） | MIDI 时间轴回放 |
| **输入注入** | 走 pipeline（按键/点击） | 走 pipeline | **自建 Win32 键盘桥（WM_KEYDOWN 直发 + 扫描码）** |
| **配置外置** | 权重内嵌代码 | **全参数外置 rhythm_config.json（132 行默认值）** | 参数走 pipeline |
| **场景判定** | SceneGate + TetrisSceneDetector（**双实现**） | SceneGate（三态 ROI 模板） | 无（由 pipeline 保证） |
| **资源定位** | `_find_image_root`（向上搜索） | `_get_image_root`（向上搜索） | 无（纯 MIDI） |
| **可调性** | 权重改代码 | **改 JSON 即可** | 改 MIDI |

**⚠️ 唯一直接操作 Win32 输入的模块是 AutoPiano**（`maa_keyboard.py`）——原因（见 Maa-12 单元三同理）：**钢琴要求极低延迟按键（hold 8ms）+ 修饰键组合（Shift/Ctrl）+ 精确扫描码，走 pipeline 的 ClickKey 无法满足**；代价是**必须依赖 Windows + 前台窗口**（`WINDOW_TITLES` 硬编码）。

**⚠️ Rhythm 的 `note_speed_px_per_sec = 900.0` 是全模块最关键的标定值**：调度器用它把"音符当前 Y 位置"换算成"还有多少秒到判定线"，再减去 `input_latency_sec = 0.035` 得到实际发键时刻——**这两个值若与被测环境不符，整条调度链全错（表现为持续过早或过晚）**；`trigger_line_offset_frac = -0.012`（判定线上移 1.2%）是第二处补偿。

---

**Maa-13 文档至此完整**（三小游戏 3883 行全解：Tetris 9 特征动态权重评估 + T-Spin 角块法，Rhythm 132 行参数表 + 900px/s 调度模型，AutoPiano 36 键映射表 + 左修饰键 Win32 桥）
