# Maa-14 实时辅助：SoundTrigger 听声辨位 / 排球 / 实时任务调度

> 覆盖源文件：`MaaNTE/agent/custom/action/SoundTrigger/`（571 行：SoundListener 215 + SoundDodgeAction 250 + DodgeCounterTrigger 95 + __init__ 11）+ `auto_volleyball.py`（321）+ `realtime_task.py`（49）+ `auto_f_scroll.py`（43）。基于当前仓库逐单元编写。

## 一、SoundTrigger 三件套：听声 → 判定 → 动作

**数据流（三层解耦）**：

```
声音采集（Ear，soundcard 回环）→ 相关匹配打分 → 阈值判定
                                              ↓ 回调
                        动作队列（Ctx._action_queue，maxsize=1）
                                              ↓ 主线程消费
                        执行器（Dodger，冷却+互斥锁）→ controller.post_click_key
```

**⚠️ 三层各有独立的抗抖动机制**：Ear 有 `_trigger_cd = 0.5`（触发冷却）；Ctx 队列 **maxsize=1（满即丢——丢的是旧动作，不是阻塞）**；Dodger 有 `_dodge_cd=0.5` / `_counter_cd=1.0` + **`_busy` 互斥标志（动作执行期间不重入）**。

### 1.1 SoundListener.py（215 行）——音频监听 `Ear`

**类常量（25–33 行，全部为类属性，可被实例覆盖）**：

| 常量 | 值 | 语义 |
|---|---|---|
| `sr` | **32000** | 采样率 |
| `ch` | 2 | 声道 |
| `chunk` | **1600** | soundcard 每次录制帧数（= 20ms @ 32k） |
| `sample_len` | **0.2** | **匹配窗口 0.2 秒** |
| `interval` | **0.05** | **每 50ms 做一次匹配（20 次/秒）** |
| `log_every` | 40 | 每 40 次打印一次分数（**2 秒一条日志**） |
| `degree` | 4 | 巴特沃斯滤波器阶数 |
| `cut_off` | **1000** | **高通截止 1000Hz（滤掉人声/低频，保留打击音）** |

**构造参数（35–59 行）**：`sample_path`（闪避音样本）+ `counter_path`（反击音样本）+ **`threshold=0.13`** + **`counter_threshold=0.12`** + `stop_check`（停止检查回调）。

**`_load`（61–72 行）——滤波器与样本**：

```python
from scipy.signal import butter
self._b, self._a = butter(degree, cut_off, btype="highpass", output="ba", fs=sr)
```

**⚠️ 采样率写进滤波器设计（`fs=self.sr`）**——归一化截止频率自动按 32000 换算。

**`_cache_load`（74–82 行）——npy 缓存（关键性能优化）**：

```python
cache = f"{path}_{self.sr}_{self.degree}_{self.cut_off}.npy"
if os.path.exists(cache) and os.path.getmtime(cache) > os.path.getmtime(path):
    return np.load(cache)              # 命中缓存直接读
wav, _ = librosa.load(path, sr=self.sr)   # 否则重采样加载
wav = self._filt(wav)
np.save(cache, wav)                    # 存缓存
return wav
```

- **缓存键包含 sr/degree/cut_off 三参数**——**改任一参数自动失效重算**（不会读到错误的旧缓存）
- **mtime 比较**——wav 更新则缓存自动失效
- **`librosa.load(path, sr=32000)`：任意采样率音频自动重采样到 32k**

**`_filt`（84–87 行）**：**`scipy.signal.filtfilt`——零相位滤波（正反各一次）**，避免相位延迟导致触发时刻偏移（**对时序敏感的场景必须用 filtfilt 而非 lfilter**）。

**`match(stream, sample)`（89–101 行）——归一化互相关匹配**：

```python
stream = self._filt(stream)          # 实流也要滤波
s1 = self._norm(stream); s2 = self._norm(sample)     # RMS 归一化
# 长的一段做 correlate 的 "data"，短的一段当 "weights"
corr = correlate(长, 短, mode="same", method="fft") / 长.shape[0]
return np.max(corr)
```

- **`_norm`（103–105 行）**：`rms = sqrt(mean(wf²) + 1e-6)` → `wf / rms`——**加 1e-6 防静音除零**；**RMS 归一化使匹配与音量无关**
- **`method="fft"`：FFT 加速（0.2s@32k = 6400 点，直接卷也不慢，但 FFT 更稳）**
- **除以长度 → 归一化分数（≈ 1.0 满分）**，与阈值 0.13 可直接比

**`start` / `stop`（107–120 行）**：**daemon 线程** + `_running` Event；stop 带 **`join(timeout=3.0)`**。

**`_open_device`（122–125 行）——⚠️ 回环录音（loopback）**：

```python
speaker = sc.default_speaker()
mic = sc.get_microphone(id=str(speaker.name), include_loopback=True)
return mic.recorder(samplerate=self.sr, channels=self.ch)
```

**按"默认扬声器名字"取回环麦克风——录的是系统播放的声音（不是物理麦克风）**：这样不需要外部拾音，直接分析游戏输出音频。**代价：必须有播放设备 + 支持 WASAPI 回环**。

**`_loop`（127–192 行）——采集主循环**：

1. **`ctypes.windll.ole32.CoInitialize(None)`（132 行）——线程内初始化 COM（soundcard 依赖 WASAPI/COM，非主线程必须显式初始化）**
2. `rec.__enter__()` 手动进入上下文（**与 finally 的 `rec.__exit__` 配对**）
3. **环形缓冲设计**：

```python
max_s = int(sr * sample_len)        # 6400 = 0.2s 的样本数
chunks = int(sr * interval / chunk) # 32000*0.05/1600 = 1
new_s = chunks * chunk              # 1600
buf = np.zeros(max_s * 2)           # 双倍窗口（2*6400）
```

4. **每轮**：循环 `chunks` 次 `rec.record(numframes=1600)` → **`librosa.to_mono(data.T)`（转单声道）** → 写入环形缓冲（**跨尾处理：`end > max_s*2` 时拆两段写**）
5. **`written >= max_s` 才开始匹配**（**先攒满 0.2s**）——**从环形缓冲取最近 max_s 个样本（`pos >= max_s` 直接切片，否则 `concatenate([buf[-(max_s-pos):], buf[:pos]])` 拼接跨环窗口）**
6. `match(win, sample)` + `match(win, counter)` → `_check`

**⚠️ 环形缓冲的意义**：record 按 1600 帧（50ms）拿，匹配窗口 200ms —— **必须跨 4 次 record 才能凑满窗口，环形缓冲正好实现"滑动窗口"**。

**`_check(d_score, c_score)`（194–215 行）——双阈值判定（含优先级仲裁）**：

```python
if now - self._last_trigger < self._trigger_cd: return    # 500ms 冷却
dodge_hit = d_score >= threshold          # 0.13
counter_hit = c_score >= counter_threshold  # 0.12
dodge_confidence = d_score / max(threshold, 1e-6)     # 归一化置信度
counter_confidence = c_score / max(counter_threshold, 1e-6)

# 优先级：闪避命中 且 (反击未命中 或 闪避置信度 >= 反击置信度) → 闪避
if dodge_hit and (not counter_hit or dodge_confidence >= counter_confidence):
    self.on_dodge(); return
if counter_hit:
    self.on_counter()
```

**⚠️ 相对置信度比较（`d_score/0.13` vs `c_score/0.12`）**：因为两阈值不同（0.13/0.12），**若直接比原始分数会偏向阈值低的那类**；除以各自阈值即得"超阈值几倍"的公平比较——**这是本文件最细致的一处设计**。

**异常兜底（185–192 行）**：整体 try → `_log().error(exc_info=True)` → finally 释放 recorder。

### 1.2 DodgeCounterTrigger.py（95 行）——动作执行器 `Dodger`

**⚠️ 常量 `VK_SHIFT = 0xA0`（6 行）——左 Shift（与 Maa-13 的钢琴模块同一约定）**

**构造（20–37 行）**：`controller` + **可注入的 `dodge_fn` / `counter_fn`（默认走 `_default_dodge` / `_default_counter`）** + `stop_check`；**两冷却 `_dodge_cd = 0.5` / `_counter_cd = 1.0`** + `_busy` + `_lock`。

**`dodge()` / `counter()`（39–77 行）——双重闸门**：

1. `stop_check()` → 直接返回
2. **时间闸门**：距上次 < 冷却 → 返回
3. **锁内检查 `_busy`（前一动作还没做完 → 丢弃）** → 置 `_busy = True` + 记录时刻
4. try 执行 fn / finally 复位 `_busy`

**⚠️ 时间闸门在锁外、`_busy` 检查在锁内**——**分工明确：快速路径不争锁，慢路径互斥**。

**`_click_key(key)`（79–81 行）**：`if self.controller: self.controller.post_click_key(key)`——**走 MaaFramework 控制器（不直接 Win32）**。

**两个默认动作（83–95 行）**：

| 动作 | 序列 |
|---|---|
| `_default_dodge` | 左Shift 按下 → **`sleep(0.1 + random()*0.1)`（100–200ms 随机）** → 左Shift 释放 |
| `_default_counter` | **`random.choice([0x31,0x32,0x33,0x34])`（数字键 1–4 随机）** → sleep(0.02) → 左Shift |

**⚠️ 随机化的意义**：**输入时序去规律化**（避让检测/更像人类操作）；扫弦式随机（1–4 任意键）应对"反击键位随场景不同"。

### 1.3 SoundDodgeAction.py（250 行）——注册层与生命周期

**4 个参数解析器（18–59 行）**：`_parse_bool(value, default)`（**容错布尔**）/ `_parse_params(value)`（JSON 容错）/ **`_get_config_value(context, node_name, key, default)`（50 行——从 pipeline 节点配置读值，实现"配置优先级：参数 > 节点配置 > 默认"）**。

**`Ctx`（62–149 行）——单例式上下文**：

- 状态：`_stop_event` / **`_action_queue = queue.Queue(maxsize=1)`** / `ear` / `dodger` / `active`
- **`setup(controller, threshold=0.13, counter_threshold=0.12, dodge_all_attacks=True)`（73–105 行）**：
  - **`if self.active: return`（幂等）**
  - **资源路径：`Path(__file__).parents[4] / "assets" / "resource" / "base"`——上溯 4 级**（`SoundTrigger/` → `action/` → `custom/` → `agent/` → **项目根**）；不存在则退 `<root>/resource/base`（dev 布局）
  - **`sounds/dodge.wav` + `sounds/counter.wav`** 两样本
  - 构造 Ear（注入 `stop_check=self._stopped`）+ Dodger（注入 controller 与 stop_check）
  - **⚠️ 关键分支（99–101 行）**：`ear.on_counter = self._on_dodge if dodge_all_attacks else self._on_counter`——**反击音也当闪避处理（"无敌躲"模式）**，否则走真实反击
- `enter()`（107–113 行）：清事件 + **`ear.start()`**（**仅当 active 且 ear 存在**）
- `exit()`（115–122 行）：**置停止事件 → ear.stop() → ear 置 None → active=False**（**完整释放，下次 setup 重建**）
- **`_enqueue_action`（124–130 行）**：
  ```python
  try: self._action_queue.put_nowait(action)
  except queue.Full: logger.debug("Dropping stale sound action: %s", action)
  ```
  **队列满丢新动作 + debug 日志**（配合 maxsize=1：只保留最新待执行动作）
- **`process_next(timeout=0.05)`（138–149 行）——主线程消费**：`get(timeout)` → Empty 返回 False → 否则调 `dodger.dodge()` / `dodger.counter()`

**`SoundDodgeAction.run`（154 行起）——注册动作**：

- 默认参数（157–160 行）：`enable_sound_trigger=True` / `dodge_all_attacks=True` / `threshold=0.13` / `counter_threshold=0.12`
- **参数解析（161–174 行）**：try 解析，**异常 → warning 并完整保留默认值（`else` 分支才赋值）**——**"默认值不可被部分污染"**
- **`@AgentServer.custom_action("SoundDodgeAction")`（152 行）——注意动作名是大驼峰（同类中的唯一例外，其余注册名均为 snake_case）**
- 后续（175–250 行）：主循环 —— **`process_next(timeout=0.05)` + `context.tasker.stopping` 检查**

## 二、auto_volleyball.py（321 行）——排球小游戏五动作

**5 个注册动作**（全部 snake_case）：

| 动作 | 行 | 职责 |
|---|---|---|
| `volleyball_reset` | 158 | 重置状态 |
| `volleyball_select_difficulty` | 177 | **选难度（4 档）** |
| `volleyball_select_teammates` | 195 | **选队友（7 角色 × 2 位）** |
| `volleyball_play` | 251 | **主循环（按键 + 结算检测）** |
| `volleyball_advance_difficulty` | 300 | 难度递进 |

**常量表（13–49 行）**：

| 常量 | 值 | 语义 |
|---|---|---|
| `_K_KEY` | **0x4B** | K 键（击球） |
| `_KEY_PRESS_INTERVAL_SECONDS` | 0.6 | 按键间隔 |
| `_RESULT_CHECK_INTERVAL_SECONDS` | 5.0 | 结算检查间隔 |
| **`_MAX_GAME_SECONDS`** | **600.0** | **单局上限 10 分钟（超时退出）** |
| `_TEAMMATE_SELECTION_TIMEOUT_SECONDS` | 30.0 | 选队友超时 |
| `_TEAMMATE_CONFIRM_TIMEOUT_SECONDS` | 2.0 | 确认超时 |
| `_TEAMMATE_FAILURE_LIMIT` | 5 | 失败上限 |
| `_TEMPLATE_THRESHOLD` | 0.8 | 模板阈值 |

**4 档难度 ROI（22–27 行）**：

```python
_DIFFICULTY_ROIS = {1:(158,254,91,86), 2:(458,337,74,77), 3:(766,264,76,75), 4:(1067,337,69,70)}
```

**三态结算检测（29–33 行）——`_GAME_END_STATES`**：

| 态 | 模板 | ROI |
|---|---|---|
| **skip** | `Volleyball/SkipButton.png` | (1223, 29, 28, 26)（**右上角跳过**） |
| **win** | `Volleyball/Win.png` | (937, 71, 308, 110) |
| **loss** | `Volleyball/Lose.png` | (879, 72, 363, 105) |

**7 角色表（39–47 行）——注释："1-7 与 task 选项中 first/second 的数值一致"**：

| id | 显示名 | 已选中确认 ROI | 头像点击 ROI |
|---|---|---|---|
| 1 | 薄荷 | (323, 94, 103, 76) | (407, 166, **1, 1**) |
| 2 | 零 | (443, 98, 89, 70) | (519, 167, 1, 1) |
| 3 | 娜娜莉 | (554, 98, 89, 70) | (633, 170, 1, 1) |
| 4 | 残虹 | (332, 208, 89, 69) | (407, 276, 1, 1) |
| 5 | 卡厄斯 | (444, 209, 88, 68) | (516, 279, 1, 1) |
| 6 | 真红 | (556, 208, 88, 70) | (630, 278, 1, 1) |
| 7 | 伊洛伊 | (332, 318, 89, 70) | (410, 386, 1, 1) |

**⚠️ 头像点击 ROI 全是 `1×1` 像素**——**表示"点这个单点"（ROI 只作坐标用）**；**确认 ROI 是完整头像框（用于模板/OCR 验证是否已选中）**。

**核心函数**：

- **`_match_state(context, frame)`（65–82 行）**：遍历三态 → `context.run_recognition_direct(JRecognitionType.TemplateMatch, JTemplateMatch(template=[t], roi=..., threshold=[0.8]), frame)` → **命中即返回态名**
- **`_template_hit`（84–97 行）**：单模板命中判定（同机制）
- **`_select_teammate(...)`（99–149 行）**：选人（**带超时 + 失败上限 + 确认检测**）
- **`_resolve_character_id(params, key, default)`（150–157 行）**：角色 id 解析（**非法值回退 default**）
- **`_current_difficulty = 1`（49 行）——模块级全局状态**（对应 AGENTS.md "模块级状态用全局变量 + 独立 `_reset` 动作"约定：即 `volleyball_reset`）

## 三、realtime_task.py（49 行）——实时任务动态调度

**`HOLDER_NODE_NAME = "__RealTimeTaskAction_Holder"`（10 行）——临时容器节点**

**`_parse_nodes(custom_action_param)`（14–31 行）——五重校验**：

1. 空参 → `ValueError("empty custom_action_param")`
2. JSON 解析 → 非 dict → `ValueError("invalid JSON object")`
3. `nodes` 非 list 或空 → `ValueError("'nodes' missing, not an array, or empty")`
4. 逐项非 str → `ValueError("every entry in 'nodes' must be a string")`
5. 返回节点名列表

**`_build_pipeline_override(nodes)`（33–35 行）**：

```python
return {HOLDER_NODE_NAME: {"next": nodes}}
```

**`RealTimeTaskAction.run`（38–49 行）——主循环**：

```python
while not context.tasker.stopping:
    result = context.run_task(HOLDER_NODE_NAME, pipeline_override)
    if result is None:
        logger.debug("RealTimeTaskAction: RunTask returned None, continue loop")
return CustomAction.RunResult(success=True)
```

**⚠️ 设计解读**：**一个空壳节点（无 recognition/action）+ 动态 `next` 列表**——**把"运行哪些节点"从 pipeline 静态定义变成运行时参数**；循环直到 tasker 停止。**这是"实时辅助模式"的核心开关**（RealtimeAssistance preset 用）：pipeline 只需在 `custom_action_param` 里给出待循环的节点名数组。

## 四、auto_f_scroll.py（43 行）——F 键连点（最小动作）

**`@AgentServer.custom_action("auto_f_scroll")`（8 行）** → `AutoFScroll.run`（10 行起）——**F 键滚动（如网页/列表快速翻页）**；43 行的极简实现（**无状态、单动作**）。

## 五、横向工程要点

| 维度 | SoundTrigger | Volleyball | RealTimeTask |
|---|---|---|---|
| **实时性要求** | **最高（50ms 匹配周期）** | 中（0.6s 按键 + 5s 结算检查） | 低（循环调度） |
| **输入通道** | `controller.post_click_key`（走 Maa） | 同（K 键 + 点击） | 无（只调度） |
| **线程模型** | **Ear 独立 daemon 线程 + 主线程消费队列** | 单线程 | 单线程 |
| **抗抖手段** | 三重冷却（触发/队列/动作）+ 相对置信度 | 超时 + 失败上限 + 状态模板确认 | tasker.stopping |
| **资源** | **sounds/dodge.wav + counter.wav + .npy 缓存** | Volleyball/*.png（10 模板） | 无 |
| **平台耦合** | **WASAPI 回环（Windows）+ COM 初始化 + filtfilt** | 无 | 无 |

**⚠️ 三个跨模块共性坑位**：

1. **动作注册名大小写不一致**：`SoundDodgeAction`（大驼峰）vs `RealTimeTaskAction`（大驼峰）vs `auto_rhythm_play` / `volleyball_*` / `map_teleport_to_point`（snake_case）——**pipeline 侧的 `custom_action` 字段必须逐字匹配，无统一规范**（Maa-09 单元五的注册表是唯一权威）
2. **资源根上溯级数不同**：SoundDodgeAction 用 `parents[4]`（硬编码 4 级），Volleyball 用 `Volleyball/...` 相对路径（交由 MaaFramework 的 resource 解析）——**同一项目两种资源定位策略并存**
3. **`_get_config_value`（SoundDodgeAction 50 行）是唯一"从 pipeline 节点配置读参数"的实现**——**参数优先级：custom_action_param > 节点配置 > 代码默认**

---

**Maa-14 文档至此完整**（实时辅助 6 文件 984 行全解：听声三层解耦 + 回环录音 + 相对置信度仲裁 + 排球 7 角色 4 难度表 + 动态节点调度）
