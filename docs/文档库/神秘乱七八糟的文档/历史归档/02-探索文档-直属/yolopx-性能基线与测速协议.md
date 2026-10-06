# YOLOPX 性能基线与测速协议（M1）

> 产出：`tools/yolopx/bench_protocol.py`（新建，可复用入口）
> 原始数据：`docs/文档库/探索文档/yolopx-bench-results/*.json`
> 执行时间：2026-09-26 22:30~23:25 · 宿主 Apple M3 / 8 核（4P+4E）/ macOS 26.6.2

---

## 0. 结论先行（给不想读全文的人）

| 问题 | 答案 |
|---|---|
| 「模型跑在 ANE 上，游戏吃满 CPU 时应该不受影响」 | **证伪**。全部 yolopx3 版本在 8 核满载下中位延迟**翻 2.2 倍**（87→200ms） |
| 那 ANE 算力被游戏抢了吗？ | **不是**。自建 100% ANE 对照模型实测同样慢 1.5~1.7× → 拖后腿的是 **CoreML 的 CPU 侧胶水**，不是 ANE 算力 |
| 33ms 预算在重干扰下可达吗（对 yolopx3）？ | **不可达，且差距是数量级**。当前最佳 `pal8_detfp` 在**无负载**下 min 就要 63.6ms（预算的 1.9 倍），满载下 min 132.7ms（4.0 倍） |
| 33ms 预算在重干扰下可达吗（对 yolo26s）？ | **可达**。`yolo26s_int8` 满载中位 12.0ms / P95 27.0ms，仍在预算内 |
| 瓶颈在哪？ | yolopx3 每帧在 CPU 上烧 **63~70ms** CPU 时间（yolo26s 仅 4.7ms）；且在 CPU↔ANE 之间有 **11 处**交替（yolo26s 仅 2 处） |
| 参考标尺「同效率只需 17.7ms」成立吗？ | 标尺本身没错（CPU_ONLY 实测 229~306ms，说明 ANE 确实在干活、有 3~4 倍加速），但**实际只拿到 3~4 倍而非 10+ 倍**，差的正是这段 CPU 税 |

**一句话**：瓶颈不是 ANE 算力不够，是 **yolopx3 的计算图被切碎成 11 段 CPU/ANE 交替，每帧在 CPU 上多付 60ms 的「胶水税」**；这份税在游戏满载时会被放大 2 倍以上。

---

## 1. 为什么必须重建测速协议

### 1.1 本机环境的真实状态（不是"有点吵"，是"不可用"）

实测同一时刻：宿主常驻 `DSH Desktop`（~107% CPU）+ `ego lite` + `WindowServer` + `coreaudiod` + `QQ`，**基线 CPU 占用本身就 43~47%**，load average 在 **5~20** 之间持续漂移。

这不是推测，是两台独立实验都撞上的现象：

| 证据 | 现象 |
|---|---|
| 第一轮"先 quiet 后 loaded"的朴素设计 | **quiet 阶段自己就被饿死了**（calib 从 31ms 飘到 86ms），导致 quiet 比 loaded 还慢，对比完全失效 |
| 同一份 `main-abba` 实验中 | 全实验的 calib 基线（纯 CPU 300k 次迭代的耗时）中位 **50.68ms**，而它在真正安静时只要 ~31ms |

**结论：任何"块状"实验设计（先全测 A 条件，再全测 B 条件）在本机一定失效** —— 块间漂移会整块地污染对比。作战手册里"单次测量一律作废"是对的，但还不够：**块状测量同样作废**。

### 1.2 协议设计（`tools/yolopx/bench_protocol.py`）

| 机制 | 解决什么 | 实现 |
|---|---|---|
| **ABBA 交错** | 环境漂移 | 每个 block 内按 `A(静)→B(载)→B(载)→A(静)` 跑四段；**奇数 block 顺序反转**（ABBA↔BAAB）抵消位置效应。两个条件锁在同一分钟里，漂移对 A/B 同向，做差时抵消 |
| **常驻 busy loop + 标志位开关** | 切换开销 | 8 个 busy loop 进程**只 spawn 一次**，靠 `multiprocessing.Value` 布尔量开关（微秒级）。若每段起停进程要付数秒 spawn/join 开销，交错就退化成新的大块 |
| **拉丁方轮转** | 模型间相互干扰 | 每段内模型起始位 +1、图起始位 +1，避免某个模型固定排在"最热/最冷"的位置 |
| **充分预热** | 首帧 ANE 图编译 | 每模型 8 帧预热全部丢弃（`yolopx3_int8` 预热就要 4.3s，混进统计就全废） |
| **四统计量** | 只报中位数会掩盖尖峰 | min / median / P95 / max，P95 用线性插值 |
| **饥饿度探针（calib）** | 环境不可比 | 每轮开头跑固定 300k 次纯 ALU 迭代，量"本进程此刻能拿到多少 CPU 时间片"。**全部条件共用同一参照**，所以绝对饥饿不污染差值 |
| **wall/CPU 双时钟** | 归因 | 每次 predict 同时记 `perf_counter`（墙钟）与 `process_time`（进程 CPU 时间）。`cpu/wall` 直接告诉你"这帧有多少比例是在 CPU 上烧的" |
| **恢复对照（recovery）** | 漂移 vs 因果 | 撤负载后再跑一遍同协议。若 recovery ≈ quiet，说明期间宿主稳定 |
| **成对逐块差** | 显著性 | 同 block 内 A 与 B 直接相减，输出 14 个配对差值 + `全为正` 标记 |
| **消融子进程隔离** | 崩溃 | `CPU_ONLY` 档位在 yolopx3 上触发 MPSGraph 断言 `MLIR pass manager failed` **直接 SIGABRT**（已实测两次）。故每档位跑在独立子进程，崩了记 error，主实验不受影响 |

### 1.3 测量口径（**务必对齐，否则数字不可比**）

```
predict_ms = MLModel.prediction()  +  输出最小触碰（arr[0,0,0] 强制物化）
```

- **不含** Swift 侧 letterbox 绘制（App 在主线程做）
- **不含** det/da/ll 后处理（App 在推理队列做，`YolopxEngine.swift:415-427`）
- **含** Python 侧 numpy→MLMultiArray 的输入转换开销

单独量出的 Python 侧开销（`input_overhead_ms`，不在上面的 predict_ms 里）：

| 模型 | PIL→provider | 全量读输出 |
|---|---|---|
| yolo26s_int8 | 2.19 ms | 0.04 ms |
| yolopx3_pal8_detfp | 2.10 ms | 0.02 ms |
| yolopx3_fp16 | 3.71 ms | 0.04 ms |

→ 所以本文所有数字是**下界**：实机 Swift 端还要叠加 letterbox + 后处理。
→ **App 侧的权威端到端数字必须由 Swift 侧单独测**，本文不能替代（见 §7 局限）。

---

## 2. 基线数据：全部 5 个候选模型

协议：ABBA 交错 × 7 block × 5 模型 × (2 reps × 4 张真实行车图) = **每模型每条件 112 样本**。输入为 `tools/yolopx/inference/image/*.jpg`（1280×720 真实行车图，非游戏 UI 截图）。

| 模型 | 条件 | min | **median** | P95 | max | CPU 时间 | cpu/wall |
|---|---|---|---|---|---|---|---|
| `yolo26s_int8`（现役基线） | 无负载 | 5.1 | **9.3** | 13.4 | 17.9 | 4.7 | 0.50 |
| | **8 核满载** | 9.0 | **12.0** | 27.0 | 39.6 | 6.1 | 0.52 |
| `yolopx3_pal8_detfp`（精度最佳） | 无负载 | 63.6 | **97.7** | 136.6 | 159.9 | 70.5 | 0.72 |
| | **8 核满载** | 132.7 | **212.7** | 306.2 | 449.6 | 86.1 | 0.41 |
| `yolopx3_w8a16` | 无负载 | 64.5 | **86.7** | 110.7 | 124.9 | 63.0 | 0.73 |
| | **8 核满载** | 133.4 | **199.8** | 323.5 | 447.8 | 86.3 | 0.44 |
| `yolopx3_fp16`（对照） | 无负载 | 71.1 | **92.0** | 124.7 | 135.6 | 64.9 | 0.71 |
| | **8 核满载** | 135.5 | **197.9** | 301.5 | 407.2 | 86.3 | 0.44 |
| `yolopx3_int8`（对照） | 无负载 | 82.4 | **99.8** | 128.7 | 164.7 | 26.1 | 0.26 |
| | **8 核满载** | 89.4 | **123.3** | 209.5 | 264.3 | 30.7 | 0.25 |

### 2.1 与作战手册已测值的交叉核对

| 模型 | 手册记录 | 本次 min | 本次 median | 吻合度 |
|---|---|---|---|---|
| `yolo26s_int8` | 5.3~8.1ms | 5.1 | 9.3 | ✅ 吻合（手册大概是安静时段的最优值） |
| `yolopx3_pal8_detfp` | 63.5ms | 63.6 | 97.7 | ✅ **min 完全吻合**；median 高是因为宿主常驻负载 |
| `yolopx3_fp16` | ~85-91ms | 71.1 | 92.0 | ✅ 吻合 |
| `yolopx3_w8a16` | ~70ms | 64.5 | 86.7 | ✅ 吻合 |

**注意**：手册的 63.5ms 其实是 **min（最优值）**，不是常态。常态（median）是 97.7ms —— 这个区别对预算判定很关键：**拿 min 当预算是危险的乐观**。

### 2.2 模型特征

| 模型 | 包体 | 算子数 | 有效算子 | CPU↔ANE 交替 | CPU 算子数 |
|---|---|---|---|---|---|
| `yolo26s_int8` | 9.8 MB | 1148 | 297 | **2** | 21 |
| `yolopx3_pal8_detfp` | 33.4 MB | 1727 | 427 | **11** | 16 |
| `yolopx3_w8a16` | 33.4 MB | 1727 | 427 | **11** | 16 |
| `yolopx3_fp16` | 66.3 MB | 1727 | 427 | **11** | 16 |
| `yolopx3_int8` | 33.6 MB | 1727 | 1053 | **7** | 12 |

> 「有效算子」= 总算子 − `const`（常量搬运，不参与设备分配）；「交替」= 相邻有效算子的设备发生变化的次数。

落在 CPU 上的算子（ANE 接不住，逐个在 CPU 上跑）：

| 模型 | CPU 算子清单 |
|---|---|
| `yolo26s_int8` | `mul(image__scaled__)`、`cast`、`topk`×2、`gather_along_axis`×2、`gather_nd`、`tile`×2、`reshape`、`floor_div`×2、`stack`、`expand_dims`×3、`sub`、`concat` |
| `yolopx3_pal8_detfp`<br>`w8a16` / `fp16` | `mul(image__scaled__)`、`cast`、**`max_pool`×2**、**`softmax`×4**、**`reduce_sum`×4**、`mul`×4 |

⚠️ **这是本次最有价值的发现**：yolopx3 的 **4 个 `softmax` + 4 个 `reduce_sum`** 全部落在 CPU —— 这是 **PSA 注意力（position self-attention）** 的组成部分。yolo26s 没有这些算子，所以它的 CPU 税只有 4.7ms。

---

## 3. 重干扰对照实验（核心）

### 3.1 成对数据

| 模型 | quiet median | loaded median | **倍率** | Δ | 逐块配对全为正 |
|---|---|---|---|---|---|
| `yolo26s_int8` | 9.3 | 12.0 | **1.29×** | +2.7ms | ✅ (14/14) |
| `yolopx3_pal8_detfp` | 97.7 | 212.7 | **2.18×** | **+115.1ms** | ✅ (14/14) |
| `yolopx3_w8a16` | 86.7 | 199.8 | **2.31×** | **+113.2ms** | ✅ (14/14) |
| `yolopx3_fp16` | 92.0 | 197.9 | **2.15×** | **+105.9ms** | ✅ (14/14) |
| `yolopx3_int8` | 99.8 | 123.3 | **1.24×** | +23.5ms | ❌ (13/14) |

14 个 block 配对差值**全部为正**（`yolopx3_int8` 除外）—— 这不是噪声，是稳定的因果效应。

逐块差值样例（`yolopx3_pal8_detfp`）：
```
+182.1  +173.7  +120.6  +111.8  +84.8  +111.3  +118.2
+115.5  +81.6   +72.0   +117.9  +109.7  +145.8  +121.6   (ms)
```

### 3.2 块内漂移对照（排除"宿主本来就在变慢"）

ABBA 结构自带一个对照：每个 block 内有 **2 个 quiet leg**（一个在块首、一个在块尾），中间夹着 2 个 loaded leg。把块首 quiet 和块尾 quiet 分开统计，就得到**宿主在实验期间自身漂移的大小**：

| 模型 | 块首 quiet 中位 | 块尾 quiet 中位 | 漂移比 |
|---|---|---|---|
| `yolo26s_int8` | 8.05 | 9.36 | 1.163 |
| `yolopx3_pal8_detfp` | 101.09 | 87.79 | 0.868 |
| `yolopx3_w8a16` | 90.02 | 88.02 | 0.978 |
| `yolopx3_fp16` | 84.84 | 97.87 | 1.154 |
| `yolopx3_int8` | 97.16 | 100.11 | 1.030 |

**漂移量在 0.87~1.16（±15%）之间，且方向不一致**（有的偏高有的偏低 → 是随机噪声而非系统性漂移）；
而**负载效应是 2.15~2.31×（+115ms）**，是漂移幅度的 **7 倍以上**，且 14/14 配对全为正。

→ **结论：观测到的劣化不可能由宿主漂移解释。** 这也是为什么必须用 ABBA 而不是"先全测 A 再全测 B"：块状设计下这个 ±15% 会变成 40%+（见 §1.1 第一次实验的失败）。

> 数据来源：上表由 `main-abba.json` 里每个模型的 `phases.quiet.per_round_median` 数组（14 项 = 7 block × 2 leg）
> 按奇偶下标拆分为"块首 leg"与"块尾 leg"后取中位数得到。协议自 `--rounds 3` 起即自动输出该对照
> （见 `drift_check` 字段）。

### 3.3 负载阶梯：什么时候开始退化

| 模型 | 0 核 | 2 核 | 4 核 | 6 核 | 8 核 |
|---|---|---|---|---|---|
| `yolo26s_int8` | 11.7ms | 13.8 (1.18×) | 13.7 (1.17×) | 13.7 (1.17×) | 10.7 (0.92×) |
| `yolopx3_pal8_detfp` | 135.7ms | 140.5 (1.03×) | 179.6 (1.32×) | 195.7 (1.44×) | 220.7 (**1.63×**) |
| `yolopx3_int8` | 112.9ms | 133.4 (1.18×) | 155.0 (1.37×) | 131.2 (1.16×) | 111.4 (0.99×) |

**读法**：
- `yolo26s_int8` 对负载**不敏感**（各档位在噪声内，甚至 8 核时更快 —— 说明它本来就跑在 ANE + 少量 CPU，抢不到它）
- `yolopx3_pal8_detfp` **单调劣化**，2 核就起步、8 核到 1.63×。**意味着哪怕游戏只用 2 个核，yolopx3 也会掉速**
- `yolopx3_int8` 曲线非单调，噪声大 —— 但它本来就已经 ~113ms，更慢也无所谓了

> ⚠️ 阶梯实验的绝对数字比 ABBA 高（135 vs 98），因为阶梯是**串行相位**（不是交错），期间宿主自己的负载在漂。**阶梯只看相对趋势，不看绝对值**。这正是为什么主协议必须是 ABBA。

### 3.4 干扰到底有多"满"（诚实标注）

| 条件 | 整机 CPU 占用（1s 窗口采样中位） |
|---|---|
| quiet（宿主常驻负载） | **43~47%** |
| loaded（+8 busy loop） | **68~88%** |

→ **本实验的"无负载"其实是"宿主常驻负载"，"满载"也只到 85% 左右**。真正游戏满载（接近 100%）只会更糟，不会更好。**本文的 2.2 倍是保守下界。**

---

## 4. 决定性实验：ANE 算力到底怕不怕 CPU 抢？

「模型跑在 ANE 上所以不该受 CPU 负载影响」是用户的核心假设。要判定它，必须先造一个**干净的对照物** —— 因为没有对照就无法区分两种解释：

- (a) ANE 被游戏抢了算力 → 帧率与游戏负载正相关，无解
- (b) ANE 没问题，是框架的 CPU 侧胶水被抢 → 可以从工程上解决

### 4.1 对照模型构造

`bench_protocol.py control` 子命令现场构建：
- 20 层 `64ch 3×3 conv`，320² **tensor 输入**（不是 image 输入！）
- `MLComputePlan` 普查确认：**20/20 算子全部 `NeuralEngine`**，CPU 算子 **0** 个，CPU↔ANE 交替 **0** 次
- `CPU_ONLY` 参照 111~136ms vs ANE 22ms → **5~6 倍加速**，证明 ANE 确实在加速

> ⚠️ **踩坑记录**：第一版对照模型用 **image 输入**，结果 CoreML 自动插入了 `image__scaled__` 之类的 **CPU 侧预处理算子**，导致对照组自己背上 ~8ms CPU 税、`cpu/wall` 高达 0.89 —— 它就不再是"零 CPU 税的纯 ANE 计算"，实验无效。**必须用 tensor 输入。**

### 4.2 结果（3 次独立重复，高度一致）

| 重复 | quiet wall | loaded wall | **倍率** | cpu/wall |
|---|---|---|---|---|
| #1 | 20.4 ms | 33.9 ms | **1.662** | 0.49 → 0.45 |
| #2 | 21.9 ms | 36.2 ms | **1.650** | 0.48 → 0.44 |
| #3 | 22.3 ms | 37.1 ms | **1.668** | 0.48 → 0.44 |

### 4.3 结论（这是本次最重要的判定）

> **ANE 计算本身不是受害者；受害的是 CoreML 每帧都要走的 CPU 侧胶水。**
>
> 证据链：
> 1. 100% ANE 的对照模型（**零 CPU 算子、零交替**）在同样负载下仍然慢 **1.65 倍** → 说明"慢"这件事**不需要** ANE 被抢就能发生
> 2. 它的 `cpu/wall` = 0.48 → 即使全是 conv，**每帧仍有约一半墙钟时间花在 CPU 上**（输入提交、调度、结果同步）
> 3. 负载类型无关：把 busy loop 降到后台 QoS（`nice=20`，主要压能效核）倍率仍是 **1.67** —— 与"压力落在 P 核还是 E 核"无关，**只要整机 CPU 忙，胶水就会被拖**

**对用户问题的直接回答**：不是"ANE 被游戏抢了"，而是 **CoreML 的推理调用路径本身需要 CPU，而这条路径会被游戏抢**。好消息是这是**工程问题**（可以优化），坏消息是它**不会因为"跑在 ANE 上"而自动免疫**。

---

## 5. 根因定位：60ms 的 CPU 税从哪来

### 5.1 关键指标

| 模型 | quiet CPU 时间 | quiet 墙钟 | **cpu/wall** | loaded CPU 时间 | 负载倍率 |
|---|---|---|---|---|---|
| `yolo26s_int8` | 4.7 ms | 9.3 ms | 0.50 | 6.1 ms | 1.29× |
| `yolopx3_pal8_detfp` | **70.5 ms** | 97.7 ms | **0.72** | 86.1 ms | 2.18× |
| `yolopx3_w8a16` | 63.0 ms | 86.7 ms | 0.73 | 86.3 ms | 2.31× |
| `yolopx3_fp16` | 64.9 ms | 92.0 ms | 0.71 | 86.3 ms | 2.15× |
| `yolopx3_int8` | 26.1 ms | 99.8 ms | 0.26 | 30.7 ms | 1.24× |

**相关系数 r(quiet CPU 时间, 负载倍率) = 0.939（n=5）** —— CPU 税越高，越怕 CPU 被占。

### 5.2 机理

同一次 predict 的 CPU 时间从 70ms 只涨到 86ms（+22%），但墙钟从 98ms 涨到 213ms（**+118%**）。

**墙钟涨的远多于 CPU 时间** → 不是"算得更多"，是**"排队等更久"**：进程被 deschedule，submit/sync 的往返延迟被放大。

yolopx3 有 **11 处 CPU↔ANE 交替**（yolo26s 只有 2 处）。每一次交替都是一个同步点：CPU 段算完才能喂给 ANE，ANE 段算完才能回到 CPU。**11 个同步点 × 每次被调度延迟放大 → 100ms 级别的额外墙钟**。

### 5.3 为什么是 softmax？

CPU 算子清单里最可疑的是 `softmax`×4 + `reduce_sum`×4 —— 这是 **PSA（position self-attention）** 的注意力归一化。ANE 对 `softmax` 支持有限，于是这些算子被退到 CPU；而它们位于计算图**纵深中部**，把整张图切成了碎片。

`yolopx3_int8` 是反证：它的 CPU 税只有 26ms（是 pal8 的 37%），**交替只有 7 处**，所以负载倍率只有 1.24× —— **证明"减少 CPU 税/减少交替"确实能换来抗干扰性**，这是一条可走的路。

### 5.4 给下游优化任务的线索（不属于本任务范围，仅记录）

1. **`softmax` 是首要嫌疑**：若能把 PSA 的 `softmax`+`reduce_sum` 改写成 ANE 友好形式（例如用 `matmul` 重写注意力、或用 `exp`/`sum` 的等价分解），有望同时降低 CPU 税与交替数
2. **operator 融合**：把 CPU 侧小算子（`mul`/`cast`/`reshape`）尽量融合进相邻 ANE 段
3. ⚠️ **不要盲目相信 `MLComputePlan` 的 `device_cost_share`**：它对 yolopx3 报 CPU 占比 0.0，但实测 CPU 时间占墙钟 72% —— **静态权重与真实耗时脱钩，只能看算子计数，不能看它报的占比**
4. ⚠️ **`CPU_AND_NE` 会让 `yolopx3_int8` 退化到 617ms**（vs `ALL` 的 71.6ms）—— 该模型依赖 GPU 兜底，不要给它锁 `CPU_AND_NE`

---

## 6. 「33ms 预算在重干扰下是否可达」判定

### 6.1 判定表

| 模型 | 无负载 min | 无负载 median | 满载 min | **满载 median** | 满载 P95 | 33ms 判定 |
|---|---|---|---|---|---|---|
| `yolo26s_int8` | 5.1 ✅ | 9.3 ✅ | 9.0 ✅ | **12.0 ✅** | 27.0 ✅ | **可达** |
| `yolopx3_pal8_detfp` | 63.6 ❌ | 97.7 ❌ | 132.7 ❌ | **212.7 ❌** | 306.2 ❌ | **不可达**（差 6.4 倍） |
| `yolopx3_w8a16` | 64.5 ❌ | 86.7 ❌ | 133.4 ❌ | **199.8 ❌** | 323.5 ❌ | **不可达**（差 6.1 倍） |
| `yolopx3_fp16` | 71.1 ❌ | 92.0 ❌ | 135.5 ❌ | **197.9 ❌** | 301.5 ❌ | **不可达**（差 6.0 倍） |
| `yolopx3_int8` | 82.4 ❌ | 99.8 ❌ | 89.4 ❌ | **123.3 ❌** | 209.5 ❌ | **不可达**（差 3.7 倍） |

### 6.2 判断

1. **对 yolopx3：33ms 预算在当前产物下【不可达】**，而且不是"差一点"。
   - 即使**完全没有干扰**（本机能给的最好条件），最快的 `pal8_detfp` 也要 **63.6ms**——预算的 **1.9 倍**
   - 在 CPU 满载下要 **132.7ms**——预算的 **4.0 倍**（中位 6.4 倍）
   - **"重干扰下是否可达"这个问题对 yolopx3 是次要的**：它在无干扰下就已经不达标

2. **重干扰的代价是实打实的 2.2 倍，不是测量噪声**
   - 14/14 个配对 block 全为正
   - 换负载类型（P 核/后台 QoS）结论不变（1.45~1.67×）

3. **对 yolo26s：33ms 在重干扰下仍然可达**，且余量充裕（满载 P95 27.0ms）
   - 但注意：本实验"满载"只到 85%，真正 100% 满载 + 实机 letterbox/后处理还需实测

4. **"精度与速度冲突时精度优先"的红线含义**
   - 现状是：`pal8_detfp`（精度最佳，det 100%）速度 97.7ms；`yolo26s_int8`（速度达标）没有三头
   - **必须先把 yolopx3 从 98ms 打下来**，否则 33ms 这条线无法通过任何工程手段绕过（除非换算力更大的机器）

### 6.3 需要 60ms→33ms 的量化目标

要让 `pal8_detfp` 在重干扰下过 33ms，需要：

```
当前:  97.7ms (quiet)  →  212.7ms (loaded)
目标:  ≤33ms  在所有条件
```

按 `倍率 2.2` 反推，**quiet 下需要 ≤ 15ms** —— 这比当前最好的 63.6ms 还要快 **4.2 倍**。考虑到 CPU_ONLY 实测 229ms（说明 ANE 已带来 3.4 倍加速），**单纯靠"更好地用 ANE"恐怕不够，需要结构性改造**（减少 11 处交替 + 干掉 60ms CPU 税）。

---

## 7. 可复用入口

### 7.1 命令行

```bash
PY=MPLCONFIGDIR=/tmp/mplcache .venv-yolo26/bin/python3

# 主协议：ABBA 交错 + 成对重干扰 + 设备归因（默认全 5 个模型，7 block）
$PY tools/yolopx/bench_protocol.py bench

# 快速版（约 3 分钟）
$PY tools/yolopx/bench_protocol.py bench --rounds 5 --reps 1 --no-ablation

# 只测指定模型
$PY tools/yolopx/bench_protocol.py bench --models yolo26s_int8 yolopx3_pal8_detfp

# 负载阶梯：找退化临界点
$PY tools/yolopx/bench_protocol.py ladder --levels 0 2 4 6 8

# ANE 免疫性对照：纯 conv 模型，倍率≈1.0 即免疫
$PY tools/yolopx/bench_protocol.py control --rounds 6

# 回归门：改完之后是不是真的更快了？（exit 1 = 有回归）
$PY tools/yolopx/bench_protocol.py compare \
    --baseline docs/文档库/探索文档/yolopx-bench-results/main-abba.json \
    --candidate <新的 bench.json> --tolerance 1.05

# 单独起 CPU 压力（其它脚本可复用）
$PY tools/yolopx/bench_protocol.py busy --procs 8
```

### 7.2 作为库调用

```python
import sys; sys.path.insert(0, "tools/yolopx")
from bench_protocol import LoadController, build_inputs, load_avg

inputs = build_inputs(Path("tools/yolopx/inference/image"))
ctl = LoadController(8, nice=0)     # nice>0 → 后台 QoS（主要压 E 核）
ctl.start()
try:
    ctl.set_active(True)            # 毫秒级开关负载
    ...                             # 你的测量代码
    ctl.set_active(False)
finally:
    ctl.close()                     # 必须：否则 busy loop 泄漏
```

### 7.3 关键参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rounds` | 7 | **必须 ≥5**，否则 P95 不可信 |
| `--reps` | 2 | 每轮每图重复次数（样本数 = rounds×2×reps×图数） |
| `--load-procs` | 8 | busy loop 数（= 核数） |
| `--load-nice` | 0 | >0 → 后台 QoS，用于分离"CPU 满载"与"P 核被占" |
| `--budget-ms` | 33.0 | 红线预算，用于自动判定 |
| `--unsafe-ablation` | off | ⚠️ **别开**：`CPU_ONLY` 档会 SIGABRT 杀掉主进程 |
| `--json` | 自动落盘 | 结果路径 |

### 7.4 原始数据落盘

```
docs/文档库/探索文档/yolopx-bench-results/
├── main-abba.json      # 主协议全量（117KB，含每个样本的原始 ms 数组）
├── ladder.json         # 负载阶梯
└── ane-control.json    # ANE 免疫性对照
```

JSON 内含：模型指纹（`model.mlmodel` 的 SHA256 前 16 位）、每轮 load average、每轮 calib、每个样本的 predict 墙钟与 CPU 时间、逐块配对差值、设备普查、消融结果。

---

## 8. 未验证 / 已知局限（**不许当成"应该没问题"**）

| # | 局限 | 影响 | 怎么补 |
|---|---|---|---|
| 1 | **本文全部是 Python/CoreML 侧数字**，不含 Swift letterbox（主线程绘制像素缓冲）与 det/da/ll 后处理 | 实机端到端只会更慢，本文数字是**下界** | 需要 Swift 侧端到端测速（可复用 `YolopxEngine.swift` 的 `lastLatencyMs` 或加 signpost） |
| 2 | 本实验"满载"只到整机 CPU **68~88%**，未达 100% | 真实游戏场景 **只会更糟**，240ms 是保守值 | 需在真实游戏运行中实测 |
| 3 | Python 侧 numpy→MLMultiArray 输入转换被计入 predict | yolopx3 约 2~4ms/帧的高估 | Swift 侧用 CVPixelBuffer 直喂可省 |
| 4 | **实测过 `yolopx3_int8` 的 `CPU_AND_NE` 档退化到 617ms**（vs ALL 71.6ms） | 该模型被锁 `CPU_AND_NE` 会灾难性变慢 | 已记录，勿锁 |
| 5 | **`CPU_AND_GPU` 档在部分模型触发 MPSGraph 断言 SIGABRT** | 该档位数据缺失（`yolo26s_int8` 的 GPU 消融拿不到） | 子进程隔离已实现，其余档位不受影响 |
| 6 | ANE 免疫性结论基于**自建对照模型**，不是 yolopx3 本身 | 结论是"ANE 计算这类负载不敏感"，不能直接外推到 yolopx3 的每一个算子 | 若要更硬，需逐算子消融（成本高） |
| 7 | 宿主机上持续运行其他进程（DSH/ego lite），"quiet"不是真安静 | 绝对值会随宿主动态变化，**只有相对差值可信** | ABBA 已最大化抵消；跨机比较需重测 |
| 8 | 未测 `YolopxEngine.swift` 的 `isInferencing` 防重叠行为对有效帧率的影响 | 若推理慢于帧间隔，会**跳帧**而非排队，实际"能跑"的定义要重新界定 | 需 App 侧行为验证 |
| 9 | **加载 mlpackage 会触碰该包的 `Manifest.json` mtime**（见下） | 影响 `git status` / 时间戳审计，**不改字节内容** | 已实测定性，见 §8.1 |

### 8.1 关于「模型产物是否被改动」的实测结论（**红线相关，务必看**）

测速必须 `MLModel(path)` 加载模型。实测发现：**macOS 的 CoreML 运行时会重写 mlpackage 里 `Manifest.json` 的 mtime**。已用受控实验判定性质：

```
对未参与本任务的 models/speed_digit_cnn.mlpackage 做一次纯 load（不推理）：
  加载前  sha256 = 761cd43e…23eacd   617 bytes   09-12 22:09:24
  加载后  sha256 = 761cd43e…23eacd   617 bytes   09-26 23:34:40
  → 内容字节完全一致（sha256 不变），只有 mtime 被触碰
```

**三条判定**：

1. **不是本脚本写的**：`bench_protocol.py` 对 `models/` 只有 `MLModel(...)` 加载与 `rglob` 读取，没有任何写操作；触碰 mtime 的是 CoreML 框架本身
2. **不是内容修改**：sha256 逐字节一致，`model.mlmodel` 与 `weights/` **完全未被触碰**（已用 `find -newermt` 全量核对：无任何 `model.mlmodel` / `weights` 文件 mtime 变化）
3. **对任何人都会发生**：包括 Swift App 自己每次 `MLModel(contentsOf:)` 启动（`YolopxEngine.swift:309`）

**影响面**：本次共 6 个模型的 `Manifest.json` mtime 被触碰（`yolo26s` / `yolo26s_int8` / `yolopx3_fp16` / `yolopx3_w8a16` / `yolopx3_int8` / `yolopx3_pal8_detfp`）；未加载过的（`yolopx_fp16` / `yolopx_int8` / `yolopx_w8a16` / `yolopx3_w8a16_detfp` 等）时间戳原样保留 —— 这本身就是"只有加载才会触发"的旁证。

> **若下游需要"模型产物零触碰"的严格证明**：用 `shasum -a 256` 对 `model.mlmodel` 与 `weights/` 做前后比对即可 —— 本次比对结果为**零变化**。
> 若要连 mtime 都不动，只能放弃加载模型，即放弃一切测速 —— 这是物理上无法两全的。

---

## 9. 一句话交接

> **给优化任务**：33ms 的拦路虎是 yolopx3 每帧 **63~70ms 的 CPU 税**（主嫌疑：4 个落在 CPU 的 `softmax` + 4 个 `reduce_sum`，把图切成 11 段）。把它打掉，既降延迟又同时拿到抗干扰性（`yolopx3_int8` 就是低 CPU 税 → 低负载敏感度的活证据）。
>
> **给验收任务**：`bench_protocol.py compare` 可直接当回归门用，但注意——**"改完变快了"必须在 ABBA 协议下测**，单次或块状测量在本机一律作废。
>
> **给用户**：游戏吃满 CPU 时模型**还能跑，但会慢一倍以上**（yolopx3：98ms → 213ms）。不过这件事的根因不在 ANE，而在 CoreML 的 CPU 侧胶水——**ANE 算力本身是扛得住的（对照实验 1.65× 但绝对量只有 12ms 级）**。
