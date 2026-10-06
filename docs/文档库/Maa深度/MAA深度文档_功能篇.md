# MaaNTE 深度技术文档 — 功能篇

> 本文档深度解析 MaaNTE 所有功能的实现细节，包括自动钓鱼、导航、小游戏、自动化日常等。

> 【2026-09-19 现状标注】描述 MaaNTE 框架本身（本地 `MaaNTE/` 仍保留）。项目侧定位：Maa 只做工具，不整体接管；坐标 1470×923 固定，运行期长边 1280，OCR 必须 GPU。截至 2026-09-19：250 个 ROI 节点 override 已生成（181 规则 + 32 反推，+83 偏移规则），剩 24 个缺模板节点待实机采集；BidKing PR#434 代码已提取至独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并）。文中功能与 `docs/文档库/Maa深度/MAA移植难度评估报告.md`、`docs/文档库/探索文档/最终报告.md` 的移植进展对照阅读。

---

## 目录

1. [自动钓鱼系统](#1-自动钓鱼系统)
2. [导航与移动系统](#2-导航与移动系统)
3. [自动排球](#3-自动排球)
4. [俄罗斯方块 AI](#4-俄罗斯方块-ai)
5. [节奏游戏](#5-节奏游戏)
6. [自动钢琴](#6-自动钢琴)
7. [音频驱动闪避](#7-音频驱动闪避)
8. [粉爪大劫案](#8-粉爪大劫案)
9. [自动咖啡](#9-自动咖啡)
10. [家具收取](#10-家具收取)
11. [实时辅助](#11-实时辅助)
12. [其他功能](#12-其他功能)

---

## 1. 自动钓鱼系统

### 1.1 功能概述

自动钓鱼是 MaaNTE 最复杂的功能之一，包含：
- **自动钓鱼**：抛竿、收线、提竿时机判断
- **自动买鱼饵**：检测到缺饵时自动购买
- **自动卖鱼**：钓鱼结束后自动出售
- **自动导航**：自动移动到钓鱼点

### 1.2 状态机

```
┌─────────────────────────────────────────────────────────────┐
│                      Fish 状态机                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   [Start]                                                    │
│      │                                                       │
│      ▼                                                       │
│   FishEntrance ──→ 检测是否在钓鱼场景                         │
│      │                                                       │
│      ├─→ FishGameStart ──→ AutoFish (核心钓鱼循环)            │
│      │                         │                             │
│      │                         ├─→ 检测到成功钓鱼             │
│      │                         │    └─→ 结算界面检测          │
│      │                         │         └─→ ESC 关闭         │
│      │                         │                             │
│      │                         ├─→ 检测到缺饵                 │
│      │                         │    └─→ FishHandleBaitLack   │
│      │                         │         └─→ 购买鱼饵         │
│      │                         │                             │
│      │                         ├─→ 检测到逃脱                 │
│      │                         │    └─→ 重新抛竿              │
│      │                         │                             │
│      │                         └─→ 完成 count 次              │
│      │                              └─→ FishLoopStart         │
│      │                                                       │
│      └─→ FishNewEntrance (新版钓鱼入口)                       │
│            └─→ FishNewAutoNavi ──→ 导航到钓鱼点               │
│                                  └─→ FishNewStart            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 核心钓鱼逻辑（auto_fish.py）

```python
@AgentServer.custom_action("auto_fish")
class AutoFish(CustomAction):
    # 模板图片
    slider_img = "Fish/slider.png"           # 滑块
    valid_region_left_img = "Fish/valid_region_left.png"  # 有效区左边界
    valid_region_right_img = "Fish/valid_region_right.png" # 有效区右边界
    success_catch_img = "Fish/success_catch.png"   # 成功捕获标志
    escape_img = "Fish/escape.png"           # 逃脱标志
    settlement_img = "Fish/settlement_blank.png"    # 结算界面
    prepare_start_img = "Fish/FishPrepareStartButton.png"  # 准备开始按钮
    fish_game_sign_img = "Fish/FishGameSign3.png"   # 钓鱼游戏标志
    need_bait_img = "Fish/need_bait.png"       # 需要鱼饵提示
    
    def run(self, context, argv):
        # 参数解析
        fishing_count = params.get("count", 10)
        check_freq = params.get("freq", 0.001)
        
        # 区域定义（基于 1280×720）
        success_region = [520, 160, 265, 30]    # 成功捕获检测区
        settlement_region = [566, 642, 150, 23] # 结算界面检测区
        game_region = [401, 39, 481, 24]        # 钓鱼游戏区域
        
        for i in range(fishing_count):
            # 1. 确保在钓鱼游戏界面
            ensure_fish_game()
            
            # 2. 抛竿前摇（连续按 F 5次）
            for _ in range(5):
                controller.post_key_down(KEY_F)
                time.sleep(0.1)
                controller.post_key_up(KEY_F)
            
            # 3. 检测是否需要鱼饵
            check_need_bait()
            
            # 4. 等待鱼咬钩（最多30秒）
            wait_for_hook(timeout=30)
            
            # 5. 钓鱼小游戏（拉条平衡）
            fish_minigame()
            
            # 6. 检测结算界面
            wait_settlement(timeout=15)
```

### 1.4 钓鱼小游戏算法

```python
def fish_minigame():
    """拉条平衡小游戏"""
    deadzone = 15  # 死区像素
    
    while time.time() - start_time < 100:  # 最长100秒
        img = get_image(controller)
        
        # 检测有效区域左右边界
        m_left, _, x_left, _ = match_template(img, game_region, valid_region_left, 0.7)
        m_right, _, x_right, _ = match_template(img, game_region, valid_region_right, 0.7)
        m_slider, _, x_slider, _ = match_template(img, game_region, slider, 0.07)
        
        # 计算目标位置
        if m_left and m_right:
            target = (x_left + x_right) / 2
            bar_width = x_right - x_left
        elif m_left:
            target = x_left + bar_width / 2
        elif m_right:
            target = x_right - bar_width / 2
        else:
            target = last_target
        
        # PID 控制
        offset = x_slider - target
        if offset > deadzone:
            controller.post_key_down(KEY_A)  # 向左
        elif offset < -deadzone:
            controller.post_key_down(KEY_D)  # 向右
        else:
            release_keys()
```

**关键点**：
- 每 10 帧按一次 F 键（模拟拉力）
- 通过 A/D 键控制滑块左右移动
- 死区 15px 避免过度调整
- 滑块丢失时保持最后已知位置 15 帧

### 1.5 钓鱼导航

钓鱼导航使用 FishNavi 路由系统，支持多个钓鱼点：
- 李箱馆、水灵湖、鹦鹉落洞、落渔亭、鹦鹉落西
- 星竹游亭、海礁广场、望角、向阳岛

路由文件：`assets/resource/routes/FishNavigation.json`

---

## 2. 导航与移动系统

### 2.1 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    导航系统架构                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  RouteRunner                                                │
│    │                                                        │
│    ├── WaypointNavigator ( waypoints 序列)                   │
│    │     │                                                   │
│    │     ├── CoordinatePositionProvider                     │
│    │     │     ├── pcap backend (Scapy)                     │
│    │     │     └── pktmon backend (Windows)                 │
│    │     │                                                   │
│    │     ├── MapLocator (视觉定位 fallback)                  │
│    │     │     ├── 多尺度模板匹配                           │
│    │     │     ├── EMA 坐标平滑                             │
│    │     │     └── 传送恢复逻辑                             │
│    │     │                                                   │
│    │     └── AnglePredictor (方向预测)                       │
│    │           └── ONNX 模型 (pointer_model.onnx)           │
│    │                                                         │
│    └── RouteSession (共享状态)                              │
│          ├── waypoints                                      │
│          ├── current_index                                  │
│          └── WebSocket 接口                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 坐标转换链

```
游戏世界坐标 (wx, wy, wz)
    │
    │  raw_coordinate_to_map()
    │  map_x = a * wx - b * wy + tx
    │  map_y = b * wx + a * wy + ty
    ▼
地图像素坐标 (map_x, map_y)  [0~13056]
    │
    │  parse_waypoint()
    │  screen_x = map_x * 1280 / 13056
    │  screen_y = map_y * 720 / 13056
    ▼
屏幕像素坐标 (screen_x, screen_y)  [0~1280, 0~720]
    │
    │  screen.map_point()
    ▼
实际窗口坐标 (win_x, win_y)  [缩放后]
```

### 2.3 WaypointNavigator 控制循环

```python
class WaypointNavigator:
    def move_to(self, target: tuple[int, int]) -> bool:
        while not self.context.tasker.stopping:
            # 1. 获取当前位置和朝向
            location = self.position_provider.locate(...)
            angle = self.predictor.predict(frame)
            
            # 2. 计算目标角度
            dx = target_x - current_x
            dy = target_y - current_y
            desired_angle = atan2(dx, -dy) % 360
            
            # 3. PID 转向
            angle_delta = (desired_angle - angle + 540) % 360 - 180
            turn_degrees = self.turn_pid.update(angle_delta, now)
            turn_pixels = turn_degrees * 10.0
            
            # 4. 执行移动
            self.press_forward()  # 按住 W
            if turn_pixels != 0:
                self.controller.post_relative_move(turn_pixels, 0)
            
            # 5. 到达检测
            if distance <= tolerance:
                return True
```

**关键参数**：
- `frame_interval = 1/60s`（网络坐标模式）或 `0.1s`（视觉模式）
- `tolerance = 80px`（到达阈值）
- `turn_pixels_per_degree = 10.0`
- `max_turn_degrees = 35.0`
- PID: Kp=0.85, Ki=0.04, Kd=0.10

### 2.4 地图传送

```python
class CheckTeleportRequiredAction(CustomAction):
    """检测是否需要传送"""
    def run(self, context, argv):
        # 检查当前场景是否为目标场景
        # 如果不在目标场景，返回 True 触发传送
        pass

class TeleportDecision(CustomAction):
    """执行传送决策"""
    def run(self, context, argv):
        # 打开地图
        # 搜索目标传送点
        # 点击传送
        pass
```

传送点数据：`assets/resource/base/map_teleport/teleport_points.json`

---

## 3. 自动排球

### 3.1 功能概述

自动排球是一个状态机驱动的小游戏自动化：
- 选择难度（1-4 级）
- 选择队友（7 个角色可选）
- 自动击球（每 0.6 秒按 K）
- 检测胜负并晋级

### 3.2 核心实现

```python
@AgentServer.custom_action("volleyball_play")
class VolleyballPlay(CustomAction):
    def run(self, context, argv):
        controller = context.tasker.controller
        started_at = time.monotonic()
        next_key_at = started_at
        next_check_at = started_at + 5.0
        
        while not tasker.stopping:
            now = time.monotonic()
            
            # 定期按键
            if now >= next_key_at:
                controller.post_click_key(0x4B).wait()  # K 键
                next_key_at = now + 0.6
            
            # 定期检查结果
            if now >= next_check_at:
                state = _match_state(context, controller.cached_image)
                if state in ("win", "loss", "skip"):
                    return CustomAction.RunResult(success=True)
                next_check_at = now + 5.0
            
            time.sleep(0.05)
```

### 3.3 角色选择

```python
_CHARACTERS = {
    1: ("薄荷", (323, 94, 103, 76), (407, 166, 1, 1)),
    2: ("零", (443, 98, 89, 70), (519, 167, 1, 1)),
    3: ("娜娜莉", (554, 98, 89, 70), (633, 170, 1, 1)),
    4: ("残虹", (332, 208, 89, 69), (407, 276, 1, 1)),
    5: ("卡厄斯", (444, 209, 88, 68), (516, 279, 1, 1)),
    6: ("真红", (556, 208, 88, 70), (630, 278, 1, 1)),
    7: ("伊洛伊", (332, 318, 89, 70), (410, 386, 1, 1)),
}
```

---

## 4. 俄罗斯方块 AI

### 4.1 AI 架构

```
TetrisGamePlayer
├── SceneGate (场景门控)
│   └── 检测游戏状态（游戏中/结果画面）
├── TetrisSceneDetector (场景检测)
│   └── 检测掉落就绪、结束画面
├── Board (棋盘管理)
│   ├── extract_board_crop()  # 提取棋盘区域
│   ├── simulate_drop()       # 模拟下落
│   └── evaluate_board()      # 评估局面
├── Pieces (方块定义)
│   └── PIECES = {"I": [...], "O": [...], ...}
└── AI 决策
    ├── _choose_best_current_piece_move()  # 当前方块决策
    └── _search_best_queue_move()          # 未来方块 lookahead
```

### 4.2 决策算法

```python
def _choose_best_current_piece_move(self, board, piece_state, planning_queue):
    """
    使用 Beam Search + 前瞻评估选择最佳落点
    
    评估指标：
    - 消除行数
    - 洞穴数
    - 高度差
    - 堆叠平整度
    - T-Spin 检测
    - 执行代价（旋转距离 + 移动距离）
    """
    best_move = None
    for rotation in range(4):
        for target_col in range(BOARD_COLS):
            if not self._is_move_feasible(board, piece, rot, col, rot, target_col):
                continue
            result = simulate_drop(board, shape, target_col)
            score = evaluate_board(result["board"], lines_cleared)
            # 前瞻未来方块
            future_bonus = search_best_queue_move(result["board"], queue)
            total_score = score + future_bonus * weight - execution_penalty
```

**关键技术**：
- **T-Spin 检测**：检测 T 方块四面都被包围的情况
- **自适应深度**：根据棋盘占用率调整 lookahead 深度
- **Beam Search**：保留 top-K 候选分支
- **Combo 奖励**：连续消除获得额外分数

### 4.3 执行策略

```python
def _apply_move_no_feedback(self, controller, target_rotation, target_col):
    """无反馈移动执行"""
    # 1. 旋转到目标角度（选择最短路径）
    clockwise_steps = (target_rot - current_rot) % 4
    counterclockwise_steps = (current_rot - target_rot) % 4
    if clockwise_steps <= counterclockwise_steps:
        for _ in range(clockwise_steps):
            tap_key(controller, VK_K)
    else:
        for _ in range(counterclockwise_steps):
            tap_key(controller, VK_J)
    
    # 2. 移动到目标列
    col_diff = target_col - current_col
    for _ in range(abs(col_diff)):
        tap_key(controller, VK_A if col_diff < 0 else VK_D)
    
    # 3. 快速下落
    if self.fast_drop:
        time.sleep(0.12)
        tap_key(controller, VK_SPACE, hold=0.02)
```

---

## 5. 节奏游戏

### 5.1 系统架构

```
AutoRhythmPlay
├── DrumDetector (鼓面检测)
│   └── CNN 模型检测 4 条轨道的鼓面位置
├── LaneLayout (轨道布局)
│   └── build_lane_layout(cfg, width, height)
├── SceneGate (场景门控)
│   └── 检测是否在游戏进行中
└── _KeyScheduler (按键调度)
    ├── press(lanes)      # 按下按键
    ├── schedule()        # 调度未来按键
    └── fire_due()        # 触发到期的按键
```

### 5.2 按键调度算法

```python
class _KeyScheduler:
    def fire_due(self, now):
        """触发到期的按键，支持 chords"""
        # 1. 按 due_time 排序
        # 2. 找到第一个到期项作为锚点
        # 3. 在 chord_window_sec 内的所有项归为同一 chord
        # 4. 检查最小间隔约束
        # 5. 批量按下 chord 中的所有键
```

### 5.3 时间补偿

```python
# 时间补偿公式
eta_sec = (trigger_y - candidate.center_y) / note_speed_px_per_sec
target_time = now + eta_sec
due_time = max(now, target_time - input_latency_sec)
```

**关键参数**（rhythm_config.json）：
- `note_speed_px_per_sec`: 900.0 px/s
- `input_latency_sec`: 0.035s
- `schedule_window_sec`: 0.22s
- `chord_window_sec`: 0.022s
- `min_tap_interval_sec`: 0.035s

---

## 6. 自动钢琴

### 6.1 功能概述

支持导入任意 MIDI 文件并自动演奏：
- MIDI 解析 → 键盘映射
- 实时音符调度
- 多轨道支持

### 6.2 核心文件

| 文件 | 说明 |
|---|---|
| `auto_piano/action.py` | 主动作实现 |
| `auto_piano/player.py` | MIDI 播放器 |
| `auto_piano/maa_keyboard.py` | MAA 键盘接口 |
| `auto_piano/key_mapping.py` | 音符到按键映射 |
| `auto_piano/midi_processor.py` | MIDI 文件处理 |

---

## 7. 音频驱动闪避

### 7.1 系统架构

```
SoundDodgeAction
├── Ear (音频监听)
│   ├── sample_path: sounds/dodge.wav
│   ├── counter_path: sounds/counter.wav
│   ├── threshold: 0.13
│   └── counter_threshold: 0.12
├── Dodger (闪避执行)
│   ├── dodge()    # 执行闪避
│   └── counter()  # 执行反击
└── 线程模型
    ├── Ear 线程：音频检测
    └── 主线程：按键执行
```

### 7.2 工作流程

```python
class Ctx:
    def setup(self, controller, threshold=0.13, counter_threshold=0.12):
        self.ear = Ear(
            sample_path="sounds/dodge.wav",
            counter_path="sounds/counter.wav",
            threshold=threshold,
            counter_threshold=counter_threshold,
        )
        self.dodger = Dodger(controller=controller)
        self.ear.on_dodge = self._on_dodge
        self.ear.on_counter = self._on_counter  # 或 dodge
    
    def run(self):
        self.ear.start()
        while not stopping:
            self.dodger.process_next(timeout=0.05)
```

---

## 8. 粉爪大劫案

### 8.1 功能概述

粉爪大劫案是一个多阶段潜行动作游戏自动化：
- 多角色切换战斗
- 怪物检测与自动攻击
- 铁门检测和通过
- 撤离点检测和撤离
- 收益统计和日志

### 8.2 三阶段架构

```
pinkpaw_core1.py  →  Core1 阶段（进入、战斗、开门）
pinkpaw_core2.py  →  Core2 阶段（ deeper 探索）
pinkpaw_core3.py  →  Core3 阶段（最终撤离）
```

### 8.3 ActionHelper 工具类

```python
class ActionHelper:
    def __init__(self, ctx):
        self.mx, self.my = 640, 360  # 当前鼠标位置
    
    def click_key(self, key_str):  # 按键
    def key_down(self, key_str):   # 按住
    def key_up(self, key_str):     # 松开
    def move_to(self, x, y):       # 鼠标移动
    def click(self, x, y):        # 点击
    def wait_gate(self, timeout):  # 等待铁门打开
    def wait_evacuate(self, timeout):  # 等待撤离点
    def fight_until_no_monster(self):  # 战斗直到无怪
```

### 8.4 自适应超时

```python
class PinkPawHeistScheme1Action(CustomAction):
    _adaptive_timeout_ms = 120000  # 默认 2 分钟
    _calibrated = False
    
    def _wait_for_xiaozhi_adaptive(self, ah):
        """首轮测算实际耗时，后续使用校准值"""
        if not self._calibrated:
            elapsed = measure_actual_time()
            self._adaptive_timeout_ms = max(20000, elapsed * 1.2)
            self._calibrated = True
```

---

## 9. 自动咖啡

### 9.1 功能概述

自动咖啡机玩法自动化：
- 选择关卡
- 点击目标顾客
- 达成营业额
- 领取奖励

### 9.2 实现

```python
@AgentServer.custom_action("auto_make_coffee")
class AutoMakeCoffee(CustomAction):
    def run(self, context, argv):
        for count in range(make_count):
            # Step 1: 选择关卡
            while True:
                img = get_image(controller)
                start_result = context.run_recognition("MakeCoffeeStart", img)
                if start_result.hit:
                    click_rect(start_result.box)
                    break
            
            # Step 2: 点击目标顾客
            # Step 3: 等待营业额达标
            # Step 4: 领取奖励
            wait_and_claim(context, controller)
```

---

## 10. 家具收取

### 10.1 识别类型

| 家具类型 | 识别节点 | 消息键 |
|---|---|---|
| 仓鼠球 | FurnitureHamsterBall | furniture.claimed.hamster_ball |
| 棉棉 | FurnitureFluff | furniture.claimed.fluff |
| 破损木箱 | FurnitureDamagedCrate | furniture.claimed.damaged_crate |
| 完整木箱 | FurnitureIntactCrate | furniture.claimed.intact_crate |

### 10.2 实现

```python
@AgentServer.custom_action("furniture_claim")
class FurnitureClaim(CustomAction):
    def run(self, context, argv):
        for node_name, name, msg_key in FURNITURE_RECOG_NODES:
            image = controller.post_screencap().wait().get()
            result = context.run_recognition(node_name, image)
            if result and result.box:
                # 动态 ROI 识别领取按钮
                roi = [result.box.x, result.box.y, result.box.w, result.box.h]
                context.run_task("FurnitureClaim", pipeline_override={"roi": roi})
```

---

## 11. 实时辅助

### 11.1 功能概述

实时辅助功能包括：
- 自动传送
- 自动跳剧情
- 自动拾取
- 在线地图导航

### 11.2 路由 WebSocket 服务

```python
class RouteWebSocketService:
    """WebSocket 服务端，接收外部路由请求"""
    
    def __init__(self, host="127.0.0.1", port=8765):
        self.server = websocket_server.WebsocketServer(port)
        self.route = RouteSession()
    
    def _on_message(self, server, client, message):
        msg = json.loads(message)
        result = handle_route_message(msg, self.route, source_size)
        server.send_message(client, json.dumps(result))
```

**消息格式**：
```json
// 设置路线
{"type": "navi-route-set", "waypoints": [...], "start": true}
// 添加航点
{"type": "navi-route-add", "pixelX": 100, "pixelY": 200}
// 清除路线
{"type": "navi-route-clear"}
// 查询状态
{"type": "navi-route-status"}
```

---

## 12. 其他功能

### 12.1 自动滚书（AutoFScroll）

- 检测书籍位置
- 自动滚动页面
- 支持多种书籍类型

### 12.2 提款机（WithdrawMoney）

- 自动取款
- 选择商品
- 金额校验

### 12.3 拍卖王（BidKing）

- 自动出价
- 价格上限控制
- 竞拍策略

### 12.4 女巫占卜（WitchDivination）

- 洗牌检测
- 选牌决策
- 结果解读

### 12.5 数据集采集（DatasetCollection）

- 自动驾驶数据采集
- 帧录制
- 控制记录
- 元数据保存

```python
@AgentServer.custom_action("autonomous_driving_dataset_recorder")
class AutonomousDrivingDatasetRecorder(CustomAction):
    def run(self, context, argv):
        # 录制视频帧
        # 记录控制输入
        # 保存元数据
        pass
```

---

*文档版本：v1.0 | 最后更新：2026-09-13（原文误写 2025）；2026-09-19 加现状标注*
