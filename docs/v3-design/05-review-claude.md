# V3 纯按键改造 · 对抗式审查报告（Claude）

审查对象：`523b57f → 9ab3f6b`
审查日期：2026-11-03
审查者纪律：**只读**，未改任何源文件；全部结论区分「我实测」与「我推断」。

> ⚠️ 审查期间工作区有并发改动：`src/dataset_v3.py` 被追加了 75 行（`make_train_val_split`），
> 并新增未跟踪文件 `src/train_v3.py`。**本报告一律以 `git show 9ab3f6b:<file>` 抽出的快照为准**
> （存放于 `/tmp/v3t/audit/`），不评审工作区的未提交内容。下文行号均指 **commit 9ab3f6b 版本**。

> ⚠️ **2026-11-10 现状注记（以当前代码为准，不改动本报告历史结论）**：以下 P0 已在当前工作区代码中修复——
> · **P0-1**（shift 录不到）：录制器现写 8 列原生按键 `w,a,s,d,shift,space,super_brake,ultimate_brake`（`Capture/RecordEngine.swift:11,46,370`、`LeanRecordEngine.swift:688`）；
> · **P0-2**（`_bit()` 缺列静默读 0）：现对缺列/None/空串**显式抛 ValueError**（`src/dataset_v3.py:153-190`，注释标「2026-11-03 修复（审查 P0-2）」）；
> · **P0-3**（`make_train_val_split` 缺失）：现已在 `src/dataset_v3.py:956` 定义（按 clip 划分）。
> 其余 P0/P1 条目未在本轮逐个复核。

---

## 1. 结论摘要

- **P0：5 个**。最严重的是 **`shift` 永远录不到**（录制器只订阅 keyDown/keyUp，macOS 的修饰键只走 flagsChanged）——**超级刹车 / 极致刹车 / 手刹三个安全头将永久没有正样本**；其次是 **`_bit()` 对缺失列静默返回 0**，把本该「显式报错」的错误路径重新变回零标签（与本次改造的初衷正相反）。
- **P1：6 个**。含 `make_train_val_split` 在本次 commit 中**不存在但被 docstring 诱导导入**（ImportError）、`--stats` 的类别分布与真正训练分布不一致（会把类权重算错）、训练/推理的 `vehicle_state` 语义不一致、录制器失败路径仍静默。
- **P2：6 个**。含缓存不失效、per-sample O(N) 重算、全零帧/暂停场景、`verify_recording` 误报 OK 等。

**没有为了凑数编造问题**：下面每个 P0/P1 都附「复现方法 + 实测证据」，能在本机原样跑出来。

---

## 2. P0 阻断级问题

### P0-1　`shift` 列永远为 0：录制器只订阅 keyDown/keyUp，而 macOS 修饰键只发 flagsChanged

- **文件**：`tools/aurora_recorder.c:142-157`（`tap_callback`）、`:160-163`（mask）、`:77`（`is_shift` 认 0x38）
- **问题**：`tap_callback` 只处理 `kCGEventKeyDown / kCGEventKeyUp`；`CGEventTapCreate` 的 mask 也只含这两种（`:160`）。macOS 对 Shift 这类**修饰键**只投递 `flagsChanged`（`CGEventCreateKeyboardEvent(NULL, 0x38, true)` 打印出来就是 `type=12`，即 flagsChanged），**不会**产生 keyDown/keyUp。于是 `g_pressed[0x38]` 永远是 0。
- **后果（安全相关，最严重）**：
  - `shift` 列恒 0 → `handbrake` 恒 0
  - `super_brake = shift ∧ space` 恒 0 → **超级刹车头无正样本**
  - `ultimate_brake = shift ∧ space ∧ s` 恒 0 → **极致刹车头无正样本**
  - 本报告所依据的 `docs/v3-design/03-output-head.md §3.7` 把「高速超级刹车必须带 S」当硬约束，而录制端根本产不出 `super_brake=1` 的帧——**模型只能学到「永不按超级刹车」**。
- **复现方法 + 实测证据**（我实测，本机 clang 编译运行）：
  1. 写一个**与生产代码 mask 完全相同**（只有 keyDown|keyUp）的 probe，注入 `0x0D`（W）与 `0x38`（Shift）：
     ```
     created types: Wdown=10 Wup=11 Shiftdown=12 Shiftup=12
       tap got type=10 keycode=13   ← W
       tap got type=11 keycode=13
     SUMMARY keydown=1 keyup=1 other=0 shift_events=0 w_events=2
     ```
     → **Shift 一条都没收到**；W 正常收到 down+up。
  2. 把 mask 加上 `kCGEventFlagsChanged` 后，同样注入 Shift：
     ```
     flagsChanged type=12 keycode=56 maskShift=1
     flagsChanged type=12 keycode=56 maskShift=0
     SUMMARY flagsChanged_events=2
     ```
     → Shift 确实走 flagsChanged 通道。
  3. 旁证：仓库内 `Sources/AuroraDrive/Agent/LLMSelfTest.swift:1209,1940-1944` 已有明确注释：**「macOS 对 Shift/Ctrl 这类修饰键不投 keyDown/keyUp，只投 flagsChanged。若 tap 只订阅 keyDown/keyUp，修饰键会永远抓不到」**。
- **为什么现有测试没抓到**：`tools/test_recorder_derive.c` 直接写 `g_pressed[0x38] = 1`（`:46`），**绕过了 tap 层**，所以 694 项断言全 PASS 也证明不了事件是否真的收到。这是测试覆盖的盲区，不是反证。
- **修复建议**：mask 增加 `CGEventMaskBit(kCGEventFlagsChanged)`；在 `tap_callback` 中处理 `kCGEventFlagsChanged`，按 `CGEventGetFlags(event) & kCGEventFlagMaskShift`（或 `maskShift`）置 `g_pressed[0x38]`；同时处理 `kCGEventTapDisabledByTimeout / kCGEventTapDisabledByUserInput` 并重新 `CGEventTapEnable`。并在测试里补一条「通过真实 CGEvent 注入 Shift 能落到 g_pressed」的端到端用例。

---

### P0-2　`_bit()` 把「列缺失」静默读成 0，问题被从显式报错悄悄退回静默

- **文件**：`src/dataset_v3.py:91-96`
- **问题**：
  ```python
  raw = (row.get(key) or "").strip()
  if raw in ("0", "0.0", ""):   # ← 空串 / None 都当 0
      return 0
  ```
  `row.get(key)` 返回 `None`（列不存在）或 `""`（行被截断/列错位）时，`(None or "")` → `""` → **返回 0，不报错**。而 `_read_rows` 的必需列检查（`:336-344`）只拿 `reader.fieldnames` 做 `strip()` 后比对，**从不校验每个 data 行的字段数**。
- **后果**：本次改造的核心承诺是「不要静默失败」；但这条路径把「A/D/W/S 全变成 NONE」这种数据损坏直接喂进训练，日志里只有一句 `[V3KeyDataset] N 个 clip，M 个样本`，完全无异常。
- **复现方法 + 实测证据**（我实测）：
  1. 表头 10 列、数据行只有 5 个字段（截断行）：
     ```
     row0: {'t_sec':'0.0','frame':'0','w':'1','a':'0','s':'0','d':'0',
            'shift': None,'space': None,'super_brake': None,'ultimate_brake': None}
     labels: handbrake=0.0 brake=0.0 super_brake=0.0 ultimate=0.0   ← 无报错
     ```
  2. 表头写了空格（`t_sec,frame, w,a, s,d,...`）——`DictReader` 的键是 `' w'`，`row.get("w")` 恒 `None`：
     ```
     真实按键 w=1/a=1，但 vertical/horizontal 全部读成 NONE，无任何告警
     ```
     （`get` 到 `' w'`，`_bit(row,"w")` 得到 0，于是 `skip_all_zero` 也可能把整段数据当静止帧丢掉——取决于各列是否都被这样错位。）
  3. 反向证明 `_bit` 本身能识别非法值：`'2' / 'true' / 'nan'` 都正确抛 `ValueError`。**唯独「缺失」被当成 0。**
- **修复建议**：
  - `_bit` 中把「键不存在」与「空串」区分开：`if key not in row: raise ValueError(f"缺少列 {key}")`；空串是否合法要显式决定（旧格式用 `%.1f` 不会写空串，建议也视为损坏并报错）。
  - `_read_rows` 读入后校验每行 `len(row) == len(header)` 且无 `None` 键（`DictReader` 在字段过多时会把多余塞进 `None` 键），并校验 `frame` 列是 `0..N-1` 连续递增（见 P0-5）。
  - 在 `_bit` 的 selftest 里补 `_bit({}, "w")`、`_bit({"w": ""}, "w")` 必须抛异常的用例。

---

### P0-3　`commit 9ab3f6b` 里的 `src/dataset_v3.py` **没有** `make_train_val_split`，但模块 docstring 教用户 `from dataset_v3 import V3KeyDataset, make_train_val_split`

- **文件**：`src/dataset_v3.py:43`（docstring 用法）、全文（无该函数定义）
- **问题**：docstring 第 43 行原文：
  ```python
  from dataset_v3 import V3KeyDataset, make_train_val_split
  ```
  但 9ab3f6b 版本的 `dataset_v3.py`（609 行）中 `make_train_val_split` **一处定义都没有**（`grep -c` = 1，仅命中文档字符串）。工作量证明：`git show 9ab3f6b:src/dataset_v3.py | wc -l` = 609；工作区版是 684 行，函数是**审查期间并发加进去的**，不在本次 commit 内。
- **后果**：任何按 docstring 写的 V3 训练脚本在 `import` 阶段直接 `ImportError`，而且这是**文档承诺 ≠ 代码事实**的典型「静默契约违背」。评审对象是 commit，因此按 commit 计为 P0（阻断「照文档能训起来」）。
- **复现方法 + 实测证据**（我实测，针对 commit 快照 `/tmp/v3t/audit/dataset_v3.py`）：
  ```
  has attr: False
  SPLIT IMPORT FAIL: ImportError cannot import name 'make_train_val_split'
  from 'dataset_v3' (/tmp/v3t/audit/dataset_v3.py)
  ```
  其余功能正常（同一快照下 `V3KeyDataset` 能构建、能取样本）。
- **修复建议**：把并发工作区里的 `make_train_val_split`（已实现得不错，含按 clip 划分 + 退化提示）**正式提交**；或先把 docstring 里的导入样例改成只导入已存在的符号。两者必须一致。

---

### P0-4　`--frame` 列从不被使用/校验；文件名与 CSV 行序一旦错位，图像和标签会静默错配

- **文件**：`src/dataset_v3.py:310-316`（索引按 `enumerate(rows)` 而非 `row["frame"]`）、`:366-401`（`load_frame(frame_idx)` 直接用序号当文件名）
- **问题**：`_build_index` 用**行号 i** 去拼 `frames/{i:06d}.jpg`，完全没有读 `/` 校验 `frame` 列；`REQUIRED_COLUMNS` 里虽然有 `frame`，但只是「表头存在」检查。
- **后果**：若 CSV 行顺序与帧文件编号不一致（合并/截断/人工修复/非录制器产物），会得到「图是第 k 帧、标签是第 m 帧」——**训练目标整体错位**，而且不报错。这是最隐蔽也最致命的数据污染形式之一。
- **复现方法 + 实测证据**（我实测）：
  ```
  controls.csv 的 frame 列写成 99,98,97,96，文件名仍 000000..000003：
  samples: 4 (frame 列完全没有被校验)
   img 000000.jpg -> vertical=0 horizontal=1
   img 000001.jpg -> vertical=1 horizontal=0
   img 000002.jpg -> vertical=2 horizontal=1
   img 000003.jpg -> vertical=1 horizontal=2
  ```
  → 第 0 张图配上了 CSV 第 0 行（但该行自称 `frame=99`），**无任何告警**。
- **修复建议**：`_build_index` 里显式校验 `int(row["frame"]) == i`（不相等即 `ValueError`），并校验 `t_sec` 单调递增、相邻间隔在合理范围（如 0.5–2× `1/fps`）。也可让 `_frame_path` 直接用 `row["frame"]` 而不是 `i`。

---

### P0-5　`vehicle_state` 里塞了标签本身（`steer_angle = f(a,d)`、`speed = f(w)`），构成跨缺口标签泄漏 + 训练/推理分布不一致

- **文件**：`src/dataset_v3.py:416-420`
- **问题**：
  ```python
  speed_proxy = 1.0 if w else 0.0
  steer_angle = -1.0 if a else (1.0 if d else 0.0)
  vehicle_state[0] = speed_proxy
  vehicle_state[6] = steer_angle
  ```
  `vehicle_state[6]` 就是**当前帧的 A/D 标签**（`horizontal` 的确定性函数），`vehicle_state[0]` 又是 **W 标签**（`vertical` 的确定性函数）。模型只要读 `vehicle_state[6]` 就能 100% 猜出 `horizontal`，读 `[0]` 就能猜出 `vertical` 的一半。而 W/A/D 键正键时 `image_hi` 的当前帧可能与上一帧几乎无变化——这等于给模型一条**绕过视觉的捷径**。
- **更糟**：部署端 `vehicle_state[6]` 是「上一次决策输出」、`[0]` 是 `SpeedOCRReader`（见 `Sources/AuroraDrive/Inference/InferenceEngineV2.swift:760-940`），**训练分布与推理分布完全不同**。V3 模型又对 state 注入噪声（`model_v3.py:1017,1065-1082`），训练时会把这条捷径学成显著权重，部署时该维不可靠 → 精度崩塌。
- **复现方法 + 实测证据**（我实测，合成的 43 帧）：
  ```
  (state[6], horizontal) -> count
    (-1.0, 0) 10     ← A
    ( 0.0, 1) 33     ← NONE（无任何 (0.0,2) 或 (1.0,2) 与 D 对齐）
  (state[0]=speed_proxy, vertical) -> count
    (0.0, 1) 12
    (0.0, 2) 10
    (1.0, 0) 21
  ```
  → `state[6]` 与 `horizontal` **完全一一对应**（这是确定性泄漏，不是相关性）。
- **修复建议**：
  - 若不打算给真实 `vehicle_state`，**直接传 `None`/全零**（模型契约允许，`model_v3.py:1009` 会零填充），不要填「由标签推出来」的伪状态。
  - 若确实要保留 speed 代理，**必须用 t−1 的按键**（`w` 的上一帧），且 steer 用 t−1 的 A/D，才符合「state = t−1」契约；并且要在文档里明确「训练期它由 t−1 标签构造，部署期由实际状态构造」这一分布差异（最好干脆全零）。

---

### P0-6（补充确认项，非新发现）　组合键永远为 0 是 P0-1 的直接后果

`super_brake` / `ultimate_brake` 两列由 `shift ∧ …` 派生（`aurora_recorder.c:209-211`），在 P0-1 修好之前恒 0。**在修复 P0-1 之前，不要开始录训练数据**——否则会录出整场 `super_brake=0 / ultimate=0` 的「安全头无正样本」数据集，且事后无法从 `controls.csv` 恢复（只有 `keylog.csv` 里的 flagsChanged 若也没订阅就等于彻底丢失）。

---

## 3. P1 严重问题

### P1-1　`--stats` 统计的是全部行，训练却跳过全零帧 → 类权重会被算错

- **文件**：`src/dataset_v3.py:494-508`（stats 不跳全零）vs `:313-315`（训练默认 `skip_all_zero=True`）
- **实测**（我实测，同一份数据）：
  ```
  dataset actually trains on vertical counts: {0: 21, 1: 5, 2: 10} total 36
  --stats reports:                           {'W': 21, 'NONE': 12, 'S': 10} total 43
  => NONE(1) 被 stats 多计 7 帧（这些帧训练时被 skip_all_zero 丢弃）
  ```
- **后果**：`print_stats` 的注释（`:476-478`）明确说「用它回填损失函数的类权重」，但它统计的 NONE 比例比实际训练分布高 19%（12/43 vs 5/36）。类权重会偏向 NONE，进一步加剧「always W」之外的另一种塌缩。
- **修复建议**：`print_stats` 增加与数据集一致的 `skip_all_zero` 过滤（默认 False 时也打印两套数字，或在标题里明确「含全零帧」），并直接输出「训练分布」那一套。

### P1-2　`risk` 代理真值把「几乎不刹车」映射到 0.1，且用 BCE 训练 → 正样本率被压到 ~20% 且基线永远学成 0.1

- **文件**：`src/dataset_v3.py:190-215`（`_risk_targets`）；训练侧 `model_v3.py:1172-1390`（`V3Loss` 里 `confidence/risk` 用裸 BCE，无 `pos_weight`）
- **实测**（我实测，模拟 10% 普通刹车 + 10% 极致刹车）：
  ```
  risk 分布: 0.1 → 1610 帧, 0.5 → 213 帧, 1.0 → 177 帧
  mean risk = 0.2222，正类率(>0.3) ≈ 19.5%
  ```
- **问题**：模型输出 sigmoid 经过 BCE 后会被拉向 `mean≈0.22`，而非「0 附近安全、高位危险」。且 0.1 基线是**假设值**，没有任何依据；`03-output-head.md §3.7` 说明用 risk 头做接管判定，0.22 的常态输出会让接管阈值完全失真。
- **修复建议**：把「不制动」标为 0.0（或显式按类权重/`pos_weight` 处理），并在 `V3Loss` 的 `risk` BCE 上加 `pos_weight`；或在 `03-output-head.md` 里明确「当前 risk 只作指示器、不用于阈值」，避免后续误用。

### P1-3　`confidence` / `risk` 的每样本 O(N) 重算，且 `_cm_cache` 不能在 `skip_all_zero`/数据更新后失效

- **文件**：`src/dataset_v3.py:407-409`（每次 `__getitem__` 都对整段 clip 调 `_confidence_targets` + `_risk_targets`）、`:449-456`（缓存只按 clip 路径）
- **实测**（我实测）：
  ```
  N=1000: conf+risk = 0.48 ms
  N=8000: conf+risk = 3.56 ms    （每个样本都重算整段）
  单样本 getitem：12–13 ms（其中 1.4 ms 是 conf+risk）
  ```
  长 clip（>1 万帧）时会成为 DataLoader 的 CPU 瓶颈，且与 `num_workers>0` 时每个 worker 各存一份缓存，内存翻倍。
- **修复建议**：把 `conf_all/risk_all` 也一起缓存（`clip -> (conf, risk)`），或把 `_control_matrix` 的缓存改成 `(clip, mtime)`；`risk` 可向量化为 `np.select`（目前是 Python for 循环，见 `:207-215`）。

### P1-4　录制器的「失败静默」并未消除：tap 创建失败只 warn、`has_keyboard` 恒 true、`created_at` 恒空

- **文件**：`tools/aurora_recorder.c:164-168`（tap 失败仅 `fprintf(stderr, "[warn] …")` 后返回）、`:371-377`（JSON 写死 `"has_keyboard": true`、`"created_at": ""`）
- **问题**：
  1. tap 创建失败时**仍然继续录制**，写出的 `controls.csv` 全 0，结束语仍然「[完成]」。
  2. `clip.json` 的 `has_keyboard` 是硬编码 `true`，即使 tap 完全失败也会骗下游「这套数据有键盘标签」。
  3. `created_at` 永远是空串（传的是 `""`），任何按创建时间筛选/排序的工具都会失效。
  4. `pthread_create`（`:324`）返回值不检查；tap 回调里也没处理 `kCGEventTapDisabledByTimeout`（系统在慢回调后会禁用 tap，此后**所有按键都丢失**，且无任何提示）。
- **修复建议**：tap 失败或 tap 被禁用后产生明确的可检测状态（例如写 `keyboard_ok=false` 到 `clip.json`、或在收尾时若非零帧占比异常打印 `[error]` 并 `return 1`）；`has_keyboard` 与 `created_at` 按实际值填写；对 `kCGEventTapDisabledByTimeout` 调 `CGEventTapEnable` 重开。

### P1-5　`build_hdf5.py` 的「显式报错」只覆盖了「有 w 没有 steer」，未知表头仍然静默返回空列表

- **文件**：`tools/build_hdf5.py:47-60`
- **实测**（我实测）：
  ```
  v3 表头      -> ValueError（正确，符合本次改造）
  t_sec,frame,foo,bar -> load_controls 返回 []（静默）
  ```
  且 `main()`（`:63-107`）里 `if controls: ... else: 记 0`，`controls` 为空时会给每个窗口写入 `steer/throttle/brake = 0.0` 并照常生成 HDF5，无告警——这正是本次想消灭的「空数据集训一整天」。
- **修复建议**：把「表头识别」做成白名单：只接受明确的 V2 列集合，其余（含未知表头）一律抛 `ValueError`；`main()` 在 `load_controls` 返回空但帧数足够时，打印 `[error]` 并 `exit(1)`，而不是静默写零标签。

### P1-6　`mono_dataset` / `build_hdf5` 的格式检测都是「表头特征子集」判断，存在误判窗口

- **文件**：`src/mono_dataset.py:82-88`、`tools/build_hdf5.py:47`
- **实测**（我实测）：
  ```
  ["t_sec","frame","w","shift","super_brake"] -> v3_keys   （只有 5 列，也被当 V3）
  ```
  `verify_recording.py:37` 同样只判 `"w" in h and "shift" in h`，于是 `t_sec,frame,w,shift,super_brake` 这种**残缺表头**会被报成 `✓ controls.csv 表头 OK (v3 纯按键 10 列格式)`，且因为缺列的行 `r.get(...)` 返回 `None`，组合键校验反而**通过**：
  ```
  [OK ] clip_partial
        ✓ controls.csv 表头 OK (v3 纯按键 10 列格式)
        ✓ 组合键校验通过（super/ultimate == 原子键逻辑与）
  ```
- **修复建议**：三处统一用一个共享的「精确表头集合」判定（`set(REQUIRED_COLUMNS) <= set(header)` 且 `set(header) == REQUIRED_COLUMNS`）；`verify_recording` 对 v3 分支**校验列数正好 10**；把「表头校验」抽成 `dataset_v3` 暴露的 `is_v3_header()` 供三方复用，避免各自漂移。

---

## 4. P2 建议改进

- **P2-1　padding 语义可能制造「假静止」**（`src/dataset_v3.py:388`）：`clamp_frame = lambda fi: max(0, fi)` 让 clip 开头历史不足时用**第 0 帧重复填充**。对「从静止起步」的片段没问题；但若 clip 从高速中间截断，模型会看到「t−3…t−23 全等于第 0 帧」的假静止历史，可能学到错误运动先验。建议：对 `frame_idx < 23` 的样本**降低采样权重**或直接丢弃（或把 `clamp_frame` 改成「用最早帧 + 标记有效长度」的通道）。**这是推断，非实测精度影响**。
- **P2-2　`augment` 使用全局 `np.random`**（`src/dataset_v3.py:465`），而 `self.rng`（`:264`）根本没用到；DDP/多 worker 下每个 worker 的随机种子相同，增强会相关性化。建议用 `self.rng.uniform` 或 `torch.Generator` 按 worker 设置种子。
- **P2-3　`skip_all_zero` 会把「故意停车/等红灯」整段丢掉**（`:313`），训练分布偏向「一直在动」。建议：提供 `keep_idle_ratio` 或按窗口保留少量全零帧，否则模型学不到「静止也是合法状态」。
- **P2-4　`_rows_cache` 在 `:318` 才赋值，但 `:306` 已经 `_read_rows` 过**；同一 clip 若被 `view_filter` 过滤掉，`_rows_cache` 不会收它。目前逻辑正确，但若将来 `view_filter` 在 `__getitem__` 里被改变，缓存不会失效。建议在 `__init__` 之外**禁止修改** `index`/缓存，或提供 `reload()`。
- **P2-5　`verify_recording.py:39,70` 用 `open(csvp)` 不关闭**（`list(csv.DictReader(open(csvp)))`），小文件无碍，但长录制会占 fd。建议 `with open(...)`。
- **P2-6　`print_stats` 只用 `cnt/total` 估算类权重**（`:535-537`），没有分 clip 加权；若某个 clip 特别长会主导权重。建议按 clip 分别统计后再合并，或至少打印 per-clip 分布。

---

## 5. 我实际验证了什么

以下均为**我实测**（本机 `/usr/local/bin/python3.11`，macOS）：

1. **语法**：
   - `python3.11 -m py_compile` 通过（`src/dataset_v3.py`、`src/mono_dataset.py`、`tools/verify_recording.py`、`tools/build_hdf5.py`、`tools/label_strong_brake.py`）。
2. **纯函数 selftest**：`python3.11 src/dataset_v3.py --selftest` → 「全部断言通过 ✅」（commit 快照同样通过）。
3. **C 穷举测试**：
   - `clang -O2 -I. -mmacosx-version-min=13.0 -o /tmp/test_recorder_derive tools/test_recorder_derive.c -framework CoreGraphics -framework CoreFoundation -framework ImageIO`
   - 运行：**694 项断言，失败 0 项，PASS**（对 commit 快照 `aurora_recorder.c` 同样 PASS）。
   - 注意：该测试**绕过 tap 层**，只证明 `derive_and_write` 的推导正确，**不能**证明 Shift 事件被收到（见 P0-1）。
4. **合成数据跑 `V3KeyDataset`**（用 PIL 生成真实 jpg）：
   - 3 个 clip、36 样本；`image_hi (3,3,224,384)`、`image_lo (21,3,112,192)`、`vehicle_state (8,)`、8 个 target shape 正确。
   - 用户给的契约 shape/dtype 与 `model_v3.V3Model.forward` **实测一致**：`batch shapes` 与 `out keys/shapes` 全部匹配，`V3Loss` 前向+`backward()` 跑通（`total=4.2353`）。
5. **帧顺序**：用像素值编码帧号的 30 帧 clip 实测——
   ```
   frame_idx 25 → image_hi means = [200,192,184]，image_lo 前 4 = [176,168,160,152]
   ```
   → 确认是**新→旧**（t, t−1, t−2, t−3…），与 `model_v3` 约定一致。**这一项没发现问题。**
6. **`_bit` 边界值**：`"" / None → 0`、`"0"/"1"/"0.0"/"1.0"/" 1 "` 正确、`"2"/"true"/"nan"` 抛异常（见 P0-2）。
7. **空目录 / 不存在目录 / 单帧 clip / 缺帧**：
   - 空目录 `RuntimeError`；不存在目录 `FileNotFoundError`（可接受但报错文案不够友好）。
   - 单帧 clip 能取样本（hi/lo 都用第 0 帧填充，shape 正确）。
   - 缺帧（缺 `000002.jpg`）能建索引，但取到该样本时 `FileNotFoundError`——**不是静默**，可接受。
8. **`make_train_val_split`**：commit 快照下 `from dataset_v3 import make_train_val_split` → **ImportError**（P0-3）。
9. **`verify_recording` 假 OK**：残缺表头 `t_sec,frame,w,shift,super_brake` 被报 `[OK ]`（P1-6）。
10. **`build_hdf5.load_controls`**：v3 表头正确抛错；未知表头静默返回 `[]`（P1-5）。
11. **`mono_dataset._detect_format`**：v1/v2/v3/部分 v3 表头判定结果（P1-6）。
12. **`dataset_v2` 对新格式**：`_load_controls_csv` 返回 `rows=0, fmt='v1_old'`——与 `03-output-head.md` 的「实测 0 行」一致；但**本次 commit 没改 `dataset_v2.py`**，所以这是**遗留问题**（文档已记录，不算本次回归）。
13. **`exp_rollover_guard.py`**：完整跑通，Q1–Q4 全部 PASS，退出码 0。数值与文档 §3.7.4 表格一致（40km/h 不带 S = 0.93291，带 S = 0.04910）。
14. **`risk`/`confidence` 分布**：合成 2000 帧 → `risk` 均值 0.222、正类率 19.5%（P1-2）。
15. **`--stats` vs 数据集分布**：NONE 12 vs 实际训练 5（P1-1）。
16. **性能**：`conf+risk` 每样本 N=8000 时 3.56 ms；单样本 getitem 12–13 ms（P1-3）。
17. **Shift 事件路由**：两次独立 C probe 证明 keyDown|keyUp-only tap **收不到** Shift，flagsChanged-only probe **能收到**（P0-1）。

---

## 6. 我无法验证的部分

- **真实录制数据**：`data/raw_clips/` 为空、`recordings/` 为空，**没有任何真实 clip**。所有数据正确性结论都建立在**合成数据**上；真实驾驶的类别分布、A+D/W+S 同按频率、暂停/切屏片段比例均**未测**。
- **实际游戏中的 Shift 行为**：我只能证明 macOS 事件路由（flagsChanged），**不能证明**目标游戏《异环》是否在 Shift 按下时也发 flagsChanged 到 tap（大概率是，因为 flagsChanged 由系统产生，与游戏无关——但游戏是否在前台截获 Shift 属于**推断**）。需要一次**真实录制端到端**验证：按住 Shift 录 2 秒，然后看 `controls.csv` 的 `shift` 列是否有 1。
- **`kCGEventTapOptionDefault` + 输入监控权限下的 flagsChanged 是否被吞**：本机 probe 在「有输入监控权限」环境跑通；无权限环境（只 warn）的行为未测。
- **防侧翻惩罚是否真能防翻车**：`L_rollover` 只存在于 `tools/v3_exp/exp_rollover_guard.py`，**`src/model_v3.py` 的 `V3Loss` 里没有接线**（`grep rollover model_v3.py` 无命中）。所以「高速超级刹车必带 S」目前**只是实验脚本的结论，不是训练时生效的约束**。真实收敛效果、v_low/v_high 阈值均**未测**。
- **模型精度 / 类别不平衡下的可学习性**：没有真实数据，无法评价 8 个头的实际收敛、per-class recall、`S` 类是否会被「always W」塌缩吃掉（`03-output-head.md §5.1` 声称平凡解 80.8%，但这是假设分布）。
- **部署端 CoreML 导出**：`dataset_v3` 的 shape 与 `V3Model` 一致已实测，但 **CoreML 导出后的实际推理**、FP16 输入构造、`vehicle_state[6]` 在部署时为何值——均未运行验证（`export_coreml` 需要 coremltools + 模型权重，本次不允许联网/跑模型 API）。
- **`make_train_val_split`（并发工作区版本）**：我只做了静态阅读，**没有评测**它在 4 个 clip 以下退化路径的行为；且它**不在本次 commit 审查范围内**。
- **`label_strong_brake.py`**：只验证了「v3 表头会 `sys.exit(2)`」；旧 v1/v2 路径的回填逻辑（含 SmolVLM2 调用）**未运行**（禁止调用模型 API）。
- **`verify_recording.py` 的 v1/v2 分支**：只做了表头判定测试，未对真实旧数据跑完整 `verify()`。

---

## 附：关键证据文件（均在 `/tmp/v3t/`，可复现）

| 文件 | 内容 |
|---|---|
| `/tmp/v3t/audit/` | commit 9ab3f6b 的 7 个源文件快照（本次审查基准） |
| `/tmp/v3t/shift_probe.c` | 证明 keyDown/keyUp-only tap 收不到 Shift |
| `/tmp/v3t/flags_probe.c` | 证明 flagsChanged-only tap 能收到 Shift |
| `/tmp/v3t/clips/` | 3 个合成 clip（43 行，含 A+D/W+S 同按、全零帧、单帧 clip） |
| `/tmp/v3t/t_model.py` | 真实 `V3Model.forward` + `V3Loss` 前向/反向，shape 全匹配 |
| `/tmp/v3t/t_order.py` | 用像素值验证 24 帧新→旧顺序 |
| `/tmp/v3t/ctest/` | 对 commit 快照编译运行 `test_recorder_derive.c`（694 断言 PASS） |
