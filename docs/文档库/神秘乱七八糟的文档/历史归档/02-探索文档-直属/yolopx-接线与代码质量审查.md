# YOLOPX 接线与代码质量审查（R1 安全关卡）

- **审查对象**：W3 接线最终化（t28，attempt 3）
- **审查任务**：t30 / attempt `be74b4d6-0431-4128-9da0-c6f751ed9302`
- **审查员**：code-quality-auditor（只读；未修改任何生产源码）
- **审查时间**：2026-09-27 00:30–01:0x
- **裁决**：**needs_revision（2 个 blocker、5 个 high）**

---

## 0. 裁决摘要

| # | 严重级别 | 问题 | 文件:行 |
|---|---|---|---|
| **B1** | 🔴 **blocker** | **兜底转向符号反转**：车道线在画面左侧 → 输出 `steer = +0.25`（向右）。实测让车**朝线的方向偏得更远** | `LaneFallback.swift:205` |
| **B2** | 🔴 **blocker** | **`throttleCap = 1.0` 兜底默认值在任何档位都不压低油门**，`applyCommand` 的 `>0.3` 门限使油门以二进制全速注入；实测 `.recover` 前进阶段 `throttle=1.0` **未被兜底触碰** | `LaneFallback.swift:216` + `AuroraDriveApp.swift:216, 3585` |
| **H1** | 🟠 high | `parseDetections` 的 `fastRows` 快速路径**永不生效**（`isContiguous` 硬编码期望连续 stride，实测 det stride=32≠6），每帧浪费 **约 44.5 ms** | `YolopxEngine.swift:611, 806-818` |
| **H2** | 🟠 high | 兜底采样带 `[360,600)` 对 16:9 输入有 **100/240 行（42%）落在 letterbox 灰边**；`LaneFallback` 是唯一**不排除 valid 区域**的消费者 | `LaneFallback.swift:136-158` |
| **H3** | 🟠 high | 引擎模式下引擎进程跑 YOLOPX 却**只发布 yolo26s 的检测**，掩码/latency 结果**从未到达 UI**；UI 侧掩码叠加在引擎模式恒空 | `EngineMain.swift:657` / `AuroraDriveApp.swift:3094` |
| **H4** | 🟠 high | 33ms 红线实测**不可达**：端到端 **163.5 ms/帧**（纯推理 103.3 + 后处理 49.6 + 掩码 2.4）；兜底有效帧率约 **6.1 Hz** | `YolopxEngine.swift:486-533` |
| **H5** | 🟠 high | **生产二进制自带自检 FAIL**：`--yolopx-selftest` 实测 **2 项未通过**（C3 转向方向、B3 21:9 断言） | `AuroraDriveApp.swift:1258, 1324` |
| **M1** | medium | `drivableAccum` / `laneAccum` 是死状态：`smoothMask` 在 `accum.count != n` 时**直接返回原网格**并重置，从未做过 EMA | `YolopxEngine.swift:769-772` |
| **M2** | medium | `enabled = false` 时 `infer` 直接 return 却**不重置掩码/降级位**，陈旧掩码可继续产出转向建议（当前无写入点，属潜在 fail-open 路径） | `YolopxEngine.swift:186, 455` |
| **M3** | medium | `drawOriginY` 定义正确却**是死代码**；`drawLetterbox` 反而用 `padY` → `padY ≠ padBottom` 时内容整体偏移 1px | `YolopxEngine.swift:114, 884-887` |
| **M4** | medium | 自检断言 `throttleCap <= 1.0` 是**永真式**（`cap=1.0` 也通过），无法守住任何东西 | `AuroraDriveApp.swift:1326` |
| **L1** | low | `MaskGrid.positiveCount` / `LetterboxMetrics.drawOriginY` 死代码 | `YolopxEngine.swift:57, 114` |
| **L2** | low | `finish` 中 `isInferencing = false` 置于 `gen` 守卫**之后**，正确性依赖"所有 bump generation 的路径都自行重置"这一隐式不变量 | `YolopxEngine.swift:546-547` |
| **L3** | low | `print(errorMessage!)` 唯一强制解包 | `YolopxEngine.swift:396` |
| **L4** | low | 3 个开关（`enabled` / `preferYolopxDetections` / `showYolopxMasks`）**均无 UI 写入点**，默认恒开 | `YolopxEngine.swift:186`、`AuroraDriveApp.swift:2430, 2433` |

---

## 1. 证据方法与可信度声明

### 1.1 三条独立证据路径（互证）

| 路径 | 方法 | 用途 |
|---|---|---|
| **A. 生产二进制** | 直接运行 `.build/arm64-apple-macosx/release/AuroraDrive --yolopx-selftest`（构建于 23:37） | 权威：项目自带自检的真实裁决 |
| **B. 逐字复刻** | 从生产源码**逐字抽段**（`MaskGrid`/`LetterboxMetrics`/`parseDetections`/`extractMask`/`LaneFallback`/`applyLaneAdvice` 等），仅去隔离装饰、逻辑零改动，独立编译运行 | 可注入任意边界输入；生产代码无法构造的用例 |
| **C. 真实数据实跑** | `coremltools` 直接加载 `yolopx3_pal8_detfp.mlpackage`，喂 `data/validation_clips/**` 145 张真实行车图与 `models/` 同款 letterbox 预处理 | 测真实分布，不靠推测 |

### 1.2 诚实声明

- 路径 B 是**复刻**，不是直接插桩生产二进制。凡复刻结论我只采纳「可由代码结构直接推出」的部分；涉及运行时行为的（如 dtype、stride、耗时）一律以路径 C / 生产二进制为准。
- 路径 C 的模型是 `.mlpackage`（`coremltools` 无法读 `.mlmodelc`），与运行期加载的 `.mlmodelc` **同源同权重**（t28 已验证 mlmodelc 五件套齐全且加载成功），但严格说是两种容器形态。
- **未做的验证**：未真机端到端驾驶；未加载游戏内真实驾驶画面（现有素材中 `data/raw_clips/*` 经目视核实为 **AuroraDrive 自己的 UI 截图**，非道路画面；`data/mac_shots/*` 多为游戏菜单 UI）。因此「游戏内实际驾驶时掩码占比」**未验证**，相关结论一律标注为推断。
- 耗时数据为**本机单点测量**，未做 ABBA 交错（手册 §140 已警告本机测量噪声大）。故性能项只采用**量级差距悬殊**的结论（如 44.5ms vs 0.08ms），不采用 10% 量级差异。

---

## 2. 九项审查逐条结论

### 审查项 1 — letterbox 几何 ⚠️ 风险（无上下颠倒，但 1px 偏移 + 采样带越界）

| 子项 | 结论 |
|---|---|
| `r = min(size/h, size/w)` | ✅ 与官方 `letterbox_for_img` 一致（`augmentations.py:223`） |
| `newW/newH = round(w*r)` | ✅ 一致（`:229`） |
| `padX = int(round(dw-0.1))`、`padY = int(round(dh-0.1))`、`padBottom = int(round(dh+0.1))` | ✅ 一致（`:247-248`） |
| 四边铺满 640 | ✅ 实测 7 种分辨率全部 `padY + newH + padBottom == 640` |
| **坐标往返** | ✅ 生产自检 B5「坐标往返精度 <1e-6，最大误差 0.00e+00」 |
| **上下颠倒风险** | ✅ **无**（三重证实，见下） |
| 内容实际落位 | ⚠️ `padY ≠ padBottom` 时偏移 1px（M3） |

**上下颠倒的三重否证**（这是本项最需要钉死的疑点）：

1. **CGContext 坐标实测**：`y=0..2` 画黑 → 落在内存**最后两行**，证明 CG y=0 对应内存末行（左下原点，行序倒置）。
2. **letterbox 绘制实测**（上红下蓝源图，读回缓冲）：
   - `1280×720`：内存 `padY+3`=红、`padY+newH-4`=蓝 → 源图**正立**，顶行落在 `padY` 处
   - `1920×1080` / `1180×820` / `1280×640` 同为 ✅
   - **不存在上下颠倒**
3. **模型行为反证**（真实行车图，正立 vs 翻转）：
   - 正立：det = **65 框**；ll 下 1/3 = **3.34%**；da 下 1/3 = **20.96%**
   - 翻转：det = **14 框**；ll 下 1/3 = 2.16%；da 下 1/3 = 50.47%
   - 正立输入的检测数高 4.6×，且画面语义分布（车道线在下、可行驶区在下）正确 → **当前绘制方向正确**

**1px 偏移根因（M3 详述）**：`drawLetterbox` 把内容画在 CG rect `y = padY`，而 CG rect 的 `y` 是**底边**；要让内容顶端落在内存行 `padY`，需要 CG `y = 640 - padY - newH = padBottom`。代码里 `drawOriginY`（`YolopxEngine.swift:114`）**恰好算的就是 `padBottom`**，但它**没有任何调用点**。
- 影响：仅当 `dh - round(dh-0.1)` 的小数部分为 0.5 时出现（如 `1180×820` → `padY=97, padBottom=98`），坐标整体偏移 **1/640 = 0.16%**。
- 实测确认：`1180×820` 内容实测落于内存 `[98, 542]`，而坐标映射假设 `[97, 542)`。

---

### 审查项 2 — det 后处理 ✅ 正确（NaN 防护完整），NMS 无 O(n²) 风险

| 子项 | 结论 |
|---|---|
| `cxcywh → xyxy` | ✅ `x1=cx-w/2 … y2=cy+h/2`（`:635-636`）正确 |
| 灰边剔除 | ✅ 三重剔除（中心点 + x 向不相交 + y 向不相交），逐点实测边界 `cy=159`剔除 / `cy=160`保留 / `cy=480`保留 / `cy=500`剔除，与 `valid=[160,480)` 完全吻合 |
| `Int(NaN)` runtime trap | ✅ **全部防护**。`:630-632` 在**任何**取值前先过 `isFinite`，且 `w > 1, h > 1` 同时挡住 NaN（NaN 比较恒 false）。实测 11 组边界输入（全 NaN / conf=NaN / cx=Inf / w=Inf / w=0.5 / 负宽负高 / 混合）**全部无崩溃、无异常框** |
| 非有限值兜底 | ✅ 最终归一化再做 `min/max` 钳位（`:672-675`） |
| `w=1e9` 巨框 | ✅ 不崩溃，被钳位为全帧框（语义可接受，非 crash） |
| **NMS 抑制循环** | ✅ 内层 `if suppressed[other] { continue }` 在 `where` 之后冗余，但排序循环本身 ≤ `maxDetections` 轮 × k 内层，k 为**已过滤候选数**。实测 k=0→49.0ms、k=500→48.9ms（无增长）；真实道路图候选 conf>0.25 为 35~332、NMS 后 4~52 → **O(k²) 不是瓶颈** |
| `maxDetections=300` | ✅ 与网络输出上限 300 对齐（t23 结论一致）；实测 conf>0.05 候选峰值 448，截断闸门**有实际意义**且未卡住任何真实帧 |

**性能真凶不在 NMS**：`parseDetections` 的 48.9 ms **随候选数完全不变**，说明耗时 100% 来自「8400 行扫描」，与 NMS 无关 → 指向 H1。

---

### 审查项 3 — 掩码提取 ⚠️ 风险（逻辑本身正确，但两条"快路径"一真一假）

| 子项 | 结论 |
|---|---|
| 逐像素 argmax（`b > a` → 前景） | ✅ 二分类 logits 的 argmax 等价写法正确 |
| 4×4 多数表决下采样 | ✅ `positive * 2 >= stride * stride`（≥8/16）与「多数」定义一致 |
| **`isContiguous` 在 `[1,2,640,640]` 上** | ✅ **成立**。实测 `strides = [819200, 409600, 640, 1]`，四项检查全 ✓，`isContiguous = true` |
| **`dataPointer` 强转 Float16 对齐/大小** | ✅ **本次恰好安全**。实测 `da`/`ll` 的 `dataType == .float16(65552)`，代码 `if let f16` 先命中 → **读法正确**（实测同一字节：`asFloat16=0.4329` vs `asFloat32=-7.98e-28`，若 dtype 是 fp32 则掩码全错） |
| `extractMask` 快速路径是否生效 | ✅ 生效（与 det 相反） |
| ⚠️ 双绑定顺序脆弱性 | `f16`/`f32` 两个绑定**无条件同时构造**，再靠 `if let` 顺序 + dtype 巧合保证正确。**只要模型换导出精度（如 fp32 输出）就会静默读错**，且无任何断言保护 |

**额外发现（本次转为性能结论）**：`extractMask` 单个耗时 **1.185 ms**，两个共 2.37 ms —— `stride=4` 的 4×4 块首地址计算与 25,600 次内层循环代价可控，**不是性能问题**。

---

### 审查项 4 — fail-open 安全红线 ✅ **结论：五门全部返回 nil，无路径在输入不可信时给出转向建议**

逐门实测（路径 B 复刻 + 生产自检 C1/C2 双向确认）：

| 门 | 触发条件 | 实测结果 |
|---|---|---|
| ① 降级 | `isDegraded = true` | ✅ `nil`（生产自检 C1「降级时返回 nil（fail-open）」✓） |
| ② 掩码为空 | `laneMask.width == 0` | ✅ `nil`（生产自检 C2 ✓）；`drivableMask` 空同为 nil |
| ②b 单侧为空 | 仅 `ll` 空 | ✅ `nil` |
| ③ 宽度不匹配 | `ll=160` vs `da=80` | ✅ `nil`（见下方重要说明） |
| ③b 宽高不等 | `160×80` | ✅ `nil` |
| ③c metrics 无效 | `metrics = .zero`（`newW=0`） | ✅ `nil` |
| ④ 行数不足 | 全零掩码 | ✅ `nil` |
| ④b 仅 2 行有前景 | `< 3` 行 | ✅ `nil` |
| ⑤ `validCells == 0` | 网格合法但 valid 区为空（`padX=700` 越界） | ✅ `nil`（在 `ratio()` 的 `x1 > x0` 处拦下，`:262`） |
| ⑤b `padX=700` 越界 | 同上 | ✅ `nil` |

**唯一需要点名的正确性说明**：门③ 的实测结果是「**返回了 `nil`，但走的是别的门**」。`LaneFallback.swift:122-124` 检查的是 `laneMask.width == laneMask.height`（自洽性），**并未比较 `laneMask.width == drivableMask.width`**。本次用例返回 nil 是因为 `da` 的 80×80 网格在后续 `ratio()` 里 `validCells` 落到不同分支，**属于巧合而非设计**。

- 实际风险：`laneMask` 与 `drivableMask` 若来自不同尺寸（例如将来 `maskGridSize` 与 `stride` 不再整除、或两路掩码异步错帧），`deviation` 会用 `laneMask.width`、`ratio` 会用 `drivableMask.width`，两套坐标混用。
- 严重度：**low**（当前两者恒同源同尺寸，且 `extractMask` 的 `width % stride == 0` 守卫保证网格一致）。
- 修复建议：门② 补一行 `laneMask.width == drivableMask.width`。

**结论：fail-open 红线成立。** 没有任何路径在 `isDegraded=true` / 掩码为空 / 尺寸不符 / 行数不足 / `validCells=0` 时给出转向建议。

> ⚠️ 唯一的例外路径见 **M2**：`enabled=false` 时引擎跳过推理但保留陈旧掩码与 `isDegraded=false`，此时掩码**不可信却未被标记**。因 `enabled` 无写入点，当前不可触发。

---

### 审查项 5 — 兜底不得越权 🔴 **B1 转向符号反转 + B2 满油门穿透**

#### ✅ 做对的部分（实测通过）

| 断言 | 实测 |
|---|---|
| 转向限幅 `±0.25` | ✅ `adviceSteerLimit = 0.25` 硬限幅（`:3834`），叠加后再 `±1.0` 钳位（`:3835`） |
| 按 confidence 加权 | ✅ `weighted = advice.steer * advice.confidence`（`:3833`） |
| 油门**只压不抬** | ✅ `min(cmd.throttle, advice.throttleCap)`（`:3838`）—— 数学上不可能抬高 |
| 刹车**只加不减** | ✅ `max(cmd.brake, advice.brake)`（`:3841`）—— 数学上不可能松刹 |
| 置信度取较小 | ✅ `min(...)`（`:3844`） |
| 越权反例拦截 | ✅ 生产自检 D 段：`sneaky`（想抬油门+松刹车）被拒（`0.3` 保持 / `0.9` 保持） |
| 线性叠加正确 | ✅ 生产自检「`0.4 + 0.25*0.5 = 0.525`」✓ |

#### 🔴 B2：**「无可能输出满油门」不成立**

`LaneFallback.swift:216` 的默认值是 `var throttleCap = 1.0`，只有 `drivableRatio < drivableFloor(0.05)` 才会被压到 `0.0 / 0.3`。

实测（复刻 `applyLaneAdvice` + 真实档位输出）：

```
.recover 前进阶段 (EscapeController.swift:161 throttle = 1.0) + 兜底无刹车建议
  → throttle = 1.0     ← 兜底完全没有触碰油门
规则档直行 (RuleController.swift:128 throttle = 0.8) + 兜底无刹车建议
  → throttle = 0.8     ← 同上
```

而 `applyCommand`（`AuroraDriveApp.swift:3585`）的门限是**二值**的：

```swift
if cmd.throttle > 0.3 { controlEngine.hold(.throttle) }
```

**只要 `throttle > 0.3` 就按全油门的 W 键**。推演链条：

> 进入 `.recover`（脱困，状态机判定主驾不可信）→ 兜底开始介入 → `EscapeController.forward` 阶段输出 `throttle = 1.0` → 兜底在不触发刹车建议时把 `1.0` 原样放行 → `applyCommand` 按住 **W 全油门**。

**为什么这是 blocker 而非 high**：
1. 兜底的**唯一价值**就是「主驾不可信时保守接管」；在它介入的同一时刻，底层档位正在输出 100% 油门。
2. 兜底同时会注入转向（`steer ≠ 0` 时）。实测 `RuleController.critical` 输出 `steer = ±1.0` —— 兜底那 `±0.25 × confidence` 的修正量**只能把满舵从 1.0 拉到 0.75**（实战路径实测：`已满右舵(1.0) + 兜底请求左修 0.25 → steer = 0.75`）。**兜底没有能力纠正一条错误的满舵**，却有能力在满油门下再叠一次转向。
3. 叠加逻辑本身没错（`min`/`max` 语义严谨），错在**输入侧把 `cap=1.0` 当作"无建议"**，而 `1.0` 在 `> 0.3` 的门限下等价于"允许全油门"。

**修复建议**（三选一，推荐 ①）：
- ① `throttleCap` 默认值改为 **0.3 以下或引入 `nil` 语义**，让"无刹车建议"表达为"不改变油门"而不是"允许到位"。最小改动：`var throttleCap = 1.0` → 加显式 `Optional<Double>`，`applyLaneAdvice` 里 `cap == nil` 时跳过油门项。
- ② 兜底介入期间**硬性封顶** `.recover` / `.rule` 的油门（例如 `min(throttle, 0.5)`），把"兜底在场 ⇒ 保守"变成结构性保证，而不是靠 `drivableRatio` 触发。
- ③ 至少把 `applyCommand` 的 `> 0.3` 门限改成**分级**（按 `throttle` 值映射按键时长/脉冲），消除"0.31 与 1.0 等价"的悬崖。

#### 🔴 B1（详述见 §3）

---

### 审查项 6 — 主驾健康时完全不下场 ✅ 正确

| 子项 | 结论 |
|---|---|
| `.rule` / `.recover` 门控正确 | ✅ `if decided == .rule \|\| decided == .recover`（`AuroraDriveApp.swift:3400`），`.e2e` / `.yolo` 下**不进 evaluate** |
| e2e/yolo 档下只 reset | ✅ `else { laneFallback.reset() }`（`:3423`） |
| `reset()` 清空全部内部状态 | ✅ `lastDeviation / stableCount / stableSign / lastAdvice`（`LaneFallback.swift:243-248`），生产自检 C5「reset 清空建议」✓ |
| 兜底在门控外**无其他调用点** | ✅ 全仓 `laneFallback.` 引用仅 2 处：`:3401`（evaluate）、`:3423`（reset） |
| 兜底不会经 `fuse` 旁路 | ✅ `ruleController.decide`（`:3370`）不传 e2e，`fuse` 在本链路未被调用 |

**结论：门控正确。** `.e2e` / `.yolo` 两个主驾档下 `laneFallback` 完全不参与，只做 reset。

---

### 审查项 7 — 性能红线 🔴 **33ms 不可达；主线程安全但队列饱和**

#### 主线程开销（决定"游戏掉不掉帧"）

| 项 | 实测 | 判定 |
|---|---|---|
| `drawLetterbox`（640 缓冲 + 等比 + fill） | **0.327 ms** | ✅ 可忽略（对照：YoloEngine 全幅拉伸 0.286 ms，**增量仅 0.04 ms**） |
| `MaskOverlay` da 前景格 `Path.addRect` ×4000 | **0.602 ms** | ✅ 可忽略（×25600 全网格才 2.167 ms，代码注释的"全网格一定会掉帧"**结论正确**） |
| `MaskOverlay` ll ×700 | 0.062 ms | ✅ |
| EMA 平滑 | 见 M1：**accum 长度恒不等 → 从未真正做 EMA**，实际每次只是 `map` 一次（25600 元素 ×2） | ✅ 反而更快，但见 M1 |
| **主线程合计新增** | **≈ 1.0 ms** | ✅ **不构成掉帧** |

**结论：MaskOverlay 与 letterbox 都不会掉帧**，代码注释里 2000~4000 / 300~700 Rect 的估算与实际相符。这一点 W3 做对了。

#### 后台队列开销（决定 YOLOPX 自身通不通）

| 项 | 实测 | 对照 |
|---|---|---|
| 纯推理 `prediction()` | **103.339 ms** | — |
| `parseDetections`（走慢路径） | **44.6 ~ 49.6 ms** | 指针快路径：**0.076 ms** → **浪费 ≈ 44.5 ms（H1）** |
| `extractMask` ×2 | 2.371 ms | — |
| letterbox | 0.327 ms | — |
| **端到端** | **163.472 ms/帧** | 红线 **33 ms/帧** |

**结论：**
1. **33ms 红线不可达** —— 与手册 §140「结论三：33ms 对 yolopx3 不可达，且不是差一点」一致，属**已知问题**，非 W3 引入。
2. **H1 是其中最便宜的一块**：44.5 ms 是**纯浪费**（同一份数据、同一次读取，只是走了 `MLMultiArray` 下标而非指针），修好即可白拿 27% 的端到端提速。
3. **兜底有效帧率**：`isInferencing` 防重叠（`:460`）+ tick 30Hz ⇒ YOLOPX 实际约 **6.1 Hz**（1021ms/163ms）。而 `LaneFallback.stabilityFrames = 6` 是**按 30Hz 标定**的（注释「约 0.2s @30Hz」），实际变成 **≈ 1.0 秒**。
   - 影响：兜底响应延迟从设计的 200ms 变成 **1 秒**。对「车偏了要扶一把」而言，1 秒的迟滞是**功能性缺陷**。
   - 严重度：**high**（不是崩溃，但使安全机制达不到设计语义）。
4. `isInferencing` 门控本身**正确**：不会让 tick 阻塞、不会积压帧、结果过期由 `generation` 收口。**主线程不会被拖慢**。

#### H3：引擎模式下的纯浪费

`EngineMain.swift:657` 发布的是 `st.yoloEngine.detections`，**不含 YOLOPX 的任何输出**；而 `EngineMain.swift` 全文 `yolopx` 引用数为 **0**。同时引擎进程的 `DriveState.tick()` 在 `isActive == false`（引擎进程内不调 `connect()`，`EngineClient.swift:169` 的 `isActive=true` 只在 UI 侧发生）下会走完整路径 → **引擎进程照跑 YOLOPX 推理**，结果：
- 引擎进程内：掩码可用于 `.rule/.recover` 兜底（有效）
- UI 进程内：`tickEngineMode()` 早退（`AuroraDriveApp.swift:3094`），本地 `yolopxEngine` **不推理** → `MaskOverlay` 拿到的 `drivableMask` 恒为 `.empty` → **掩码叠加在引擎模式下永不显示**

**结论：引擎模式下「双份代价、零份 UI 收益」** —— 引擎进程白烧 ~163ms/帧的算力，UI 侧掩码显示始终空白。这是接线完整性的真实缺口（与 t28 报告 §2.7.1「接线从死变活」在**引擎模式下并不成立**）。

---

### 审查项 8 — 检测源切换 ✅ 正确（不会变瞎）

```swift
var effectiveDetections: [Detection] {
    let base = EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections
    if preferYolopxDetections, yolopxEngine.isLoaded, !yolopxEngine.detections.isEmpty {
        return yolopxEngine.detections
    }
    return base
}
```

| 场景 | 回落行为 |
|---|---|
| YOLOPX 未加载 | ✅ `isLoaded == false` → 回落 `base` |
| YOLOPX 加载成功但本帧无框 | ✅ `detections.isEmpty` → 回落 `base` |
| 引擎模式 | ✅ `base = remoteDetections`（引擎回传的 yolo26s 框）；UI 侧 `yolopxEngine.detections` 恒空 → 必然回落 |
| YOLOPX 降级（`isDegraded=true`） | ⚠️ **不回落**：判据里**没有** `!isDegraded`。即掩码失效时，**检测框仍会用 YOLOPX 的** |

**关于最后一条**：这是**设计选择**而非缺陷 —— `isDegraded` 的语义是「**掩码**失效，决策层不得采信」（`:218-220` 注释明确写的是掩码），而 det 头的置信度是独立的。且 NC=1 只检车，与 yolo26s 的 COCO-80 是不同口径。
- 但存在**口径混用**隐患：`DetectedBoxCount → AutoRoadCondition` 的路况阈值（>30/>50/>70）是按哪个源的框数标定的？t23 报告显示 YOLOPX 与 yolo26s 的框数量级不同（实测真实道路 YOLOPX NMS 后 4~52 框）。**切换检测源会引起路况档位跳变。**
- 严重度：**medium**（建议：路况判定固定用同一源，或在报告里显式声明阈值基于哪个源）。
- 注：`AutoRoadCondition` 的实际阈值在 `ControlWiring.swift` 中另有说明（该文件属 W2/t23 范围，本审查不深入）。

**结论：不会变瞎。** 四条回落路径全部成立。

---

### 审查项 9 — 模型加载 ⚠️ 风险（冷却正确，但主线程同步编译）

| 子项 | 结论 |
|---|---|
| 冷却期防 30Hz 重试风暴 | ✅ `loadRetryCooldown = 5.0`（`:244`），`guard Date().timeIntervalSince(lastLoadAttempt) >= cooldown else { return }` + **先打时间戳再加载**（`:387-388`）—— 正确防重入，与 `YoloEngine.swift:176` 同法 |
| `loadIfNeeded` 是否只在启动调 | ⚠️ 不是。`startDriving` 调一次（`:2743`），但 `infer` 内也会兜底调用（`:457`）。因冷却期存在，最坏 **每 5s 一次** |
| 逐候选实测加载 | ✅ 修复正确：`:348-379` 逐条 `fileExists` → `.mlpackage` 编译 → `MLModel(contentsOf:)`，失败 `continue`，**存在性 ≠ 可加载性**的教训已落地 |
| 候选表磁盘核验 | ✅ 6 条候选实测 `6/6` 在场（本机 `ls` 复核一致） |
| `warmUp` 正确性 | ✅ `queue.async` 后台预热（`:419-437`），不阻塞主线程；构造失败有日志 |
| ⚠️ **主线程同步开销** | **`.mlpackage` 候选的 `MLModel.compileModel(at:)` 在 `loadIfNeeded`（主线程）内同步执行**。实测：`pal8_detfp` **1.03 s**、`int8` 0.64 s、`fp16` 0.56 s、`w8a16` 0.38 s |
| ⚠️ 最坏情形 | 首位 `.mlmodelc` 若损坏 → 遍历到 4 个 `.mlpackage`，**最坏 ≈ 2.6s 主线程阻塞**；配合 5s 冷却 ⇒ tick 30Hz 下反复卡主线程 |

**但必须平衡说明**：当前首位 `pal8_detfp.mlmodelc` **结构完整、加载成功**（生产二进制实测 `✓ yolopx3_pal8_detfp.mlmodelc — 加载成功`），遍历在**第一步就返回**，`compileModel` 路径**当前永不执行**。故这是**潜在风险**而非当前故障。
- 严重度：**medium**（建议把 `loadFirstUsableModel()` 整体挪到 `inferenceQueue`，或用 `Task.detached`，与 `warmUp` 同样异步化）。
- 另注：`.mlpackage` 编译产物落在 `TMPDIR`（实测 `/var/folders/.../yolopx3_xxx_UUID.mlmodelc`），**每次进程启动都重新编译**，不缓存。

**结论**：冷却期与 warmUp **实现正确**；主要风险是 `.mlpackage` 编译落在主线程（当前路径不经过）。

---

## 3. 🔴 Blocker 详述

### B1 — 兜底转向符号反转（会导致车辆朝偏差方向偏移）

**文件:行**：`Sources/AuroraDrive/Inference/LaneFallback.swift:204-206`

```swift
// 车道中心偏右 → 车偏左 → 往右修正，故取 -deviation
let raw = -deviation * steerGain
steer = max(-maxSteer, min(maxSteer, raw))
```

**根因**：`deviation = median - 0.5`（`:168`）是「**车道线中心相对画面中心**的偏移」，不是「车辆相对车道的偏移」。而代码注释假设了后者。两个量**符号相反**。

**实测（三路互证）**：

| 场景 | 物理含义 | 实测 `steer` | 期望 |
|---|---|---|---|
| 车道线在画面**左半**（x≈30/160 → 中心 0.194） | 车在线**右侧** → 需**向左** | **+0.2500** | ≤ 0 ❌ |
| 车道线在画面**右半**（x≈128/160 → 中心 0.803） | 车在线**左侧** → 需**向右** | **−0.2500** | ≥ 0 ❌ |

**生产二进制自检独立复现**：

```
═══ C. 车道兜底门控 ═══
  ✗ 转向方向正确（线在左→向左修正）  — steer=+0.250
YOLOPX 自检 FAIL —— 2 项未通过
```

**危害链**：兜底生效于 `.rule` / `.recover`（**主驾已被判定不可信**）→ 输出方向与需求**相反** → `steer` 经 `applyLaneAdvice` 加权叠加到 `currentCommand` → `applyCommand` 在 `|steer| > 0.1` 时按 A/D → 车辆**朝偏移方向继续偏**（正反馈）直至偏出车道。这是典型的**发散型错误**，不是"修正量小所以没关系"。

**修复建议**：
```swift
// 车道线中心偏右（deviation > 0）⇒ 车偏左 ⇒ 应向右修正 ⇒ steer > 0
let raw = deviation * steerGain      // 去掉负号
```
并同步修正 `:204` 的注释与自检 C3 的断言文字（当前断言与代码**同为错误**，无法互查）。

**附带要求**：自检 C3（`AuroraDriveApp.swift:1324`）是**唯一**能抓住此 bug 的守卫，请保留它并让它在 CI/交付流程里**必须为绿**。

---

## 4. 🟠 High 详述（择要）

### H1 — `fastRows` 快速路径永不生效（44.5 ms/帧纯浪费）

**文件:行**：`YolopxEngine.swift:611`（调用）、`:806-818`（`isContiguous`）、`:821-834`（`fastRows`）

`isContiguous` 用**固定公式**推导期望 stride：
```swift
let expectW = 1
let expectH = shape[3]
let expectC = shape[2] * shape[3]
let expectN = shape[1] * shape[2] * shape[3]
return strides[3] == expectW && strides[2] == expectH && ...
```
对 `da`/`ll` 的 `[1,2,640,640]` 恰好成立（实测 ✓）。但对 `det` 的 `[1,8400,6]`：脚本期望 `strides = [50400, 6, 1]`，**实测 `strides = [268800, 32, 1]`** —— `strides[1] = 32 ≠ 6`（CoreML 把 8400×6 的末两维按 32 对齐做了行填充）。

→ `isContiguous` 返回 **false** → `fastRows` 返回 nil → **每帧执行 8400 × 5 = 42,000 次 `MLMultiArray` 下标访问**。

**实测对比**：

| 读取路径 | 耗时 |
|---|---|
| 慢路径（当前生产路径，8400×5 下标） | **44.589 ms/帧** |
| 指针整块读（本应走到的快路径） | **0.076 ms/帧** |
| **浪费** | **≈ 44.5 ms/帧** |

**修复建议**：`isContiguous` 改为**按实际 strides 推导**（只要求 `strides[3] == 1` 且数值递增且 `strides[2] >= shape[3]`，并按 `strides[1]` 跨行读取），或对 `det` 单独用「行偏移 = `i * strides[1]`」的指针读取。**不要**假设连续。

**为什么是 high 而非 blocker**：它不产生错误结果（慢路径语义正确），只耗时。但它是 33ms 红线里**最容易回收的一块**（端到端 163ms → 119ms）。

---

### H2 — 兜底采样带 42% 落在灰边（唯一不排除 valid 区域的消费者）

**文件:行**：`LaneFallback.swift:136-158`（采样带遍历无 valid 过滤）vs `:254-272`（`ratio()` **有**过滤）

`sampleTopY = 360` / `sampleBottomY = 600`（`:82-83`）是**写死的 640 坐标系常量**，不随输入比例调整：

| 输入 | valid 内容行 | 采样带 `[360,600)` 与 valid 的交集 |
|---|---|---|
| 1280×640（实测素材） | `[160, 480)` | **120/240 = 50%** |
| 1920×1080 | `[140, 500)` | 140/240 = 58% |
| 1280×800 | `[120, 520)` | 160/240 = 67% |
| 2560×1080 | `[185, 455)` | **95/240 = 39%** |
| 1280×720 | `[140, 500)` | 140/240 = 58% |

**矛盾点**：同一个文件里，`ratio()` 明确写了「灰边不计入 —— 否则固定面积的灰边会稀释占比，让降级线失去意义」（`:253`），而**车道线偏差计算完全没做这件事**。代码自身承认了灰边污染的问题，却在主决策路径上忽略了它。

**实测缓解证据（限制严重度）**：145 张真实道路图上，采样带内灰边行 **3000 行中 0 行出前景**（0.0%），有效行 4200 中 2148 行出前景（51.1%）。即**当前模型的 lane 头对 114 灰边不响应**，灰边不参与中位数。

**为什么仍标 high**：这是**依赖模型行为的隐式不变量**，没有任何断言或注释保护。一旦模型换版（或换 `w8a16`/`int8` 候选 —— 手册记载 `int8` 的 ll recall 仅 3.98%，其响应分布与 `pal8` **不同**），灰边出前景就会直接污染中位数。而且它同时解释了另一个现象：采样带 42~58% 的"有效样本"其实在采样带之外，**近处路面信息被系统性浪费**。

**修复建议**：采样带改为按 `metrics` 动态计算（例如 `valid 下 1/4 ~ 下 9/10` 区间），或在遍历时直接 `guard !metrics.isInPad(...)`。

---

### H3 — 引擎模式下 YOLOPX「双份代价、零份 UI 收益」

**文件:行**：`Core/EngineMain.swift:657`（publish 不含 YOLOPX）、`App/AuroraDriveApp.swift:3094`（UI 侧早退）

- 引擎进程：`EngineGlobals.state?.tick()`（`EngineMain.swift:647`）走**完整路径** → `yolopxEngine.infer()` 真跑（`isActive` 在引擎进程内恒 false）
- 发布通道：`shm?.publish(image:detections:fps:isDriving:isStreaming:fullFrame:)` —— **无掩码、无 latencу、无 isDegraded 字段**
- UI 进程：`tick()` 第一步 `if EngineClient.shared.isActive { tickEngineMode(); return }` → 本地 `yolopxEngine` **不推理** → `MaskOverlay(drivableMask: state.yolopxEngine.drivableMask ...)` 恒为 `.empty`

**后果**：`showYolopxMasks = true`（默认）在引擎模式下是**空开关**；同时引擎进程为 `.rule/.recover` 兜底保留的 YOLOPX 推理，其掩码**没有任何 UI 可视化**。

**修复建议**：把 `da`/`ll` 的降采样网格（160×160×2 = 50KB，或 RLE）加入共享内存协议；或明确决定"引擎模式不跑 YOLOPX"并在 `EngineMain` 里 `yolopxEngine.enabled = false` 以免白烧算力。**两条路必须选一条**，现状是最差组合。

---

### H4 — 33ms 不可达 + 兜底稳定性门实际放大 5 倍

详见 §审查项 7。两个独立结论：
1. 红线不可达属**已知问题**（手册 §140）；但 H1 的 44.5ms 属**可立即回收**。
2. `LaneFallback.stabilityFrames = 6` 的注释写「约 0.2s @30Hz」，实测推理吞吐 6.1 Hz ⇒ 实际 **≈ 1.0 s**。**这是 W3 引入的语义漂移**（W3 把 YOLOPX 从"从未加载"变成"稳定加载"，于是兜底从死代码变成活跃代码，而它的时间常数从未按真实吞吐标定）。

**修复建议**：`stabilityFrames` 改为按**实际推理间隔**动态折算，或直接用时间窗（如 `lastOpinionChange` + `0.2s`）替代帧计数。

---

### H5 — 生产二进制自带自检 FAIL 2 项

```
$ ./.build/arm64-apple-macosx/release/AuroraDrive --yolopx-selftest
  ✗ 21:9 左右补灰边  — padX=0 padY=185
  ✗ 转向方向正确（线在左→向左修正）  — steer=+0.250
YOLOPX 自检 FAIL —— 2 项未通过
[EXIT=0]
```

**注意 `EXIT=0`** —— 自检 FAIL 但**退出码为 0**，任何 CI/脚本都无法据此拦截。

| 失败项 | 定性 |
|---|---|
| `21:9 左右补灰边`（`:1258-1260`） | **自检断言本身错误**：2560×1080 → `r = min(640/1080, 640/2560) = 0.25` → `newW = 640` 恰好铺满 → 正确行为就是**上下**补边（`padY=185, newH=270`）。断言写的"左右补灰边"与几何不符 |
| `转向方向正确`（`:1324`） | **真实产品 bug（B1）**，自检**正确地**抓住了它 |

**修复建议**：① 修 B1；② 把 B3 断言改为「21:9 应以上下补边为主，且 `padX + newW + padRight == 640`」；③ **自检 FAIL 时设置非零退出码**，否则这道关卡在自动化里形同虚设。

---

## 5. 中等与低优先级问题

| ID | 级别 | 文件:行 | 问题 | 修复建议 |
|---|---|---|---|---|
| **M1** | medium | `YolopxEngine.swift:769-772` | `smoothMask` 的 `if accum.count != n { accum = ...; return grid }` 使 `drivableAccum`/`laneAccum` **永远是死状态**：首次调用把 `accum` 设为 255　×160²＝ 25600，`grid.cells.count` 也是 25600 → 此后 `accum.count == n` 成立……**但首次调用的 `return grid` 使该帧未被平滑**，且 `accum` 只被赋为 0/1 而非 Float 累加值；结合 `maskEMA=0.35` 的 EMA 需要**多次调用才收敛**，注释「跨帧去抖」的实际效果**未验证** | 加断言/日志实测 EMA 是否真的在抑制抖动；若未生效则删除该机制（省 25600×2 次浮点运算 + 两个 1MB 数组） |
| **M2** | medium | `YolopxEngine.swift:186, 455` | `enabled=false` → `infer` 直接 return，**不重置** `drivableMask`/`laneMask`/`isDegraded`。陈旧掩码 + `isDegraded=false` 会让 `LaneFallback` 继续基于**过期数据**给建议 | `guard enabled else { reset(); return }` |
| **M3** | medium | `YolopxEngine.swift:114, 884-887` | `drawOriginY`（= `padBottom`）**是正确的目标值**却是死代码；`drawLetterbox` 用 `padY` → `padY ≠ padBottom` 时内容偏移 1px（实测 `1180×820`） | `drawLetterbox` 改用 `metrics.drawOriginY`（并修正 `isInPad` 的对称性） |
| **M4** | medium | `AuroraDriveApp.swift:1326` | 断言 `a.throttleCap <= 1.0` 是**永真式**（`cap` 默认就是 1.0），实测无信息量 | 改为断言**兜底介入期间的等效油门**：`applyLaneAdvice(a, to: ControlCommand(throttle: 1.0, ...)).throttle <= 0.3` |
| **M5** | medium | `AuroraDriveApp.swift:1881-1887` | 检测源切换无**口径声明**：路况阈值（>30/>50/>70）未标明基于哪个源的框数分布 | 在 `AutoRoadCondition` 与 `effectiveDetections` 处注明标定源 |
| **M6** | medium | `YolopxEngine.swift:385-416` | `.mlpackage` 的 `compileModel`（实测 0.38~1.03s）在**主线程**同步执行；最坏遍历 4 个 `.mlpackage` ≈ 2.6s | 挪到 `inferenceQueue` |
| **L1** | low | `YolopxEngine.swift:57, 114` | `MaskGrid.positiveCount`、`LetterboxMetrics.drawOriginY` **无任何调用点**（全仓 grep 证实） | 删除或接入 |
| **L2** | low | `YolopxEngine.swift:546-547` | `guard gen == generation else { return }` **在** `isInferencing = false` 之前；正确性依赖"所有 bump generation 的路径（`reset`/`reloadModel`）都自行重置"这一隐式不变量（当前确实成立） | 把 `isInferencing = false` 提到 guard 之前并加注释 |
| **L3** | low | `YolopxEngine.swift:396` | `print(errorMessage!)` 全文件唯一强制解包（刚赋值故安全） | 用局部常量 |
| **L4** | low | `YolopxEngine.swift:186`、`AuroraDriveApp.swift:2430/2433` | 3 个开关**均无 UI 写入点**，"停用本引擎即完全退出"（`:3181` 注释）与"一键回滚"（`:2548`）当前**做不到** | 接入设置面板，或在报告/注释里改为"改代码常量" |
| **L5** | low | `LaneFallback.swift:122-124` | 门② 未比较 `laneMask.width == drivableMask.width`，两路掩码尺寸失配时不会拦（见审查项 4） | 补一行 |
| **L6** | low | `YolopxEngine.swift:806-818` | `isContiguous` 的命名承诺「布局为 [C,H,W]」，实际检查的是**连续无 padding**；对 `det` 的失败是**正确的**，但函数名会误导调用者以为它检查的是"逻辑布局" | 改名 `hasContiguousLayout` |
| **L7** | low | `AuroraDriveApp.swift:3925-3926` | `MaskOverlay.rect()` 的 `+ 0.5` 魔法增量（防缝？）无注释 | 注释或提取常量 |

---

## 6. 代码质量审查（逐条）

| 维度 | 评价 |
|---|---|
| **命名** | ✅ 良好。`loadFirstUsableModel` / `isUsingFp16Fallback` / `drawOriginY` / `effectiveDetections` 达意。⚠️ `isContiguous` 名不符实（L6） |
| **结构** | ✅ 良好。`nonisolated static` 纯函数与 `@MainActor` 状态分离清晰；`// MARK:` 分段完整；文件头「与 YoloEngine 的三点关键差异」是**高质量防误删文档** |
| **错误处理** | ✅ 良好。`loadFirstUsableModel` 逐候选 try/catch + 日志留痕；`parseDetections` 的 `isFinite` 防护**完整**（实测 11 组边界全过）；无 `try!` / `as!`；唯一 `!` 是 L3 |
| **防御性编程** | ✅ 良好但**不均衡**：`finish` 的 `gen` 守卫、`isInferencing` 防重叠、`extractMask` 的 `width % stride` 守卫、`ratio` 的 `x1 > x0` 守卫都在。⚠️ 缺 `laneMask.width == drivableMask.width`（L5）、缺 `enabled` 路径的状态清理（M2） |
| **重复代码** | ⚠️ 2 处真实重复：① `YolopxEngine.positiveRatios()`（`:786-801`）与 `LaneFallback.ratio()`（`:254-272`）**几乎逐行相同**（同样的 `strideD`/`x0/y0/x1/y1`/双层循环），口径若改会分叉；② `maskCandidates` 与 `candidateURLs` 的分工清晰（不算重复） |
| **魔法数字** | ⚠️ 大部分有注释（`114/255`、`0.35`、`0.5`、`640`、`±0.25` 都有依据）。缺注释的：`drawLetterbox` 的 `+0.5`（L7）、`MaskOverlay` 的 `0.18/0.75` opacity（部分有）、`stabilityFrames = 6` 的「@30Hz」**前提未标注已失效**（H4） |
| **注释质量** | ✅ **优秀**。多处注释直接记录"为什么这么做"与"历史踩坑"（如 `:191-198` 的"存在 ≠ 可加载"、`:300-302` 的候选表核验）。这是本项目最突出的优点。⚠️ 但 `:204` 的转向注释**与代码同错**（B1），说明注释不能替代断言 |
| **可读性工程** | ✅ 良好。`LetterboxMetrics` 把几何参数命名化（`padY`/`padBottom`/`newW`/`newH`）显著降低认知负担；`MaskGrid.at()` 做边界安全访问 |
| **over-engineering** | ⚠️ 轻微：EMA 机制（M1）在当前实现下疑似无效却保留两套 25600 长度数组 |

---

## 7. 最终回答：这套接线能否安全上车？

**不能（当前状态）。**

**可以肯定的部分**（W3 的真实成果）：
1. **模型加载修复是扎实的** —— 「存在 ≠ 可加载」的根因已消除，生产二进制实测 `✓ yolopx3_pal8_detfp.mlmodelc 加载成功`，候选表 6/6 磁盘在场，`pal8_detfp` 五件套齐全。
2. **fail-open 红线成立** —— 五类不可信输入实测全部返回 `nil`，无一条路径在输入不可信时给出转向建议。
3. **叠加语义严谨** —— 油门只压不抬、刹车只加不减，数学上不可抬高/不可松刹；`sneaky` 越权反例被生产自检拦下。
4. **门控正确** —— `.e2e`/`.yolo` 主驾健康时兜底完全不下场，只 reset。
5. **不会变瞎** —— `effectiveDetections` 四条回落路径全部成立。
6. **主线程不掉帧** —— letterbox 0.327ms + MaskOverlay 0.602ms ≈ 1ms，性能估算与实际吻合。
7. **栈安全** —— `Int(NaN)` 类 runtime trap 被完整防护（11 组边界输入实测无崩溃）。

**必须修掉才能上车**：
1. **B1 转向符号** —— 兜底会在主驾已被判定不可信时**朝错误方向**打方向，且是正反馈。生产自检已 FAIL。
2. **B2 满油门穿透** —— 兜底介入期间，`.recover` 前进阶段正在注入 **100% 油门**，而兜底对此不做任何限制，同时叠加转向。
3. **H5 自检退出码恒 0** —— 现有唯一的自动化守卫无法拦截上述两项。

**建议的修复顺序**：B1（1 行）→ H5③（退出码）→ B2（1 处默认值 + 语义）→ H1（44.5ms 白拿）→ H2 / H3 / H4 → M1–M6。

---

## 8. 复现命令

```sh
# ① 权威：生产二进制自带自检（本次 FAIL 2 项的来源）
cd /Users/dupi/Desktop/自动驾驶系统
./.build/arm64-apple-macosx/release/AuroraDrive --yolopx-selftest   # 末尾应见 "YOLOPX 自检 FAIL —— 2 项未通过"

# ② 逐字复刻探针（本报告 §2 各项实测的来源）
#    源码见 /tmp/t30-audit/prod_core.swift（逐字抽取自生产源码，仅去隔离装饰）
cd /tmp/t30-audit
swiftc -O prod_core.swift selftest.swift -o st && ./st        # fail-open 五门 + 复刻自检 C 段
swiftc -O prod_core.swift replay.swift  -o replay && ./replay # det 边界 11 组 + 灰边剔除 + letterbox 方向
swiftc -O prod_core.swift dtype_all.swift -o dtype_probe && ./dtype_probe  # dtype / strides / fastRows 判定
swiftc -O prod_core.swift perf.swift    -o perf && ./perf     # 端到端耗时分解

# ③ 真实数据实跑（掩码占比 / 灰边前景）
/Users/dupi/Desktop/自动驾驶系统/.venv-yolo26/bin/python /tmp/t30-audit/ratio2.py
/Users/dupi/Desktop/自动驾驶系统/.venv-yolo26/bin/python /tmp/t30-audit/gray.py
/Users/dupi/Desktop/自动驾驶系统/.venv-yolo26/bin/python /tmp/t30-audit/orient.py   # 正立 vs 翻转
```

---

## 9. 只读合规声明

- **未修改任何生产源码**（`Sources/**`、`Package.swift`、`models/**`、`tools/yolopx/**` 零改动）。
- 唯一写入 = 本报告文件 + `/tmp/t30-audit/` 下的复刻探针与实测脚本（未污染仓库；`tools/yolopx` 为独立 git 仓库，全程未写入）。
- `/tmp/t30-audit/prod_core.swift` 为**逐字抽取**的生产源码副本，仅去 `private`/`nonisolated`/`@MainActor` 等**隔离装饰**，逻辑零改动 —— 供复算者核对。
