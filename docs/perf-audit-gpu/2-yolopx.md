# YOLOPX / A-YOLOM 检测网 GPU 占用审计

> 审计对象：`Sources/AuroraDrive/Inference/YolopxEngine.swift`（单文件双模型族）
> 只读审计：**未修改任何源码，未启动 App**
> 环境：M3 MacBook Air / macOS 27.0.1 / Swift 6.3.3；实测时 load average 5.53（偏高，见 §7 口径说明）
> 所有"实测"均为本次新跑，命令见 §8；无法复现的一律标 **未测**。

---

## 0. 结论摘要

| # | 结论 | 证据强度 |
|---|---|---|
| 1 | **那张 ABBA 表测的是 `yolopx3_pal8_detfp`（32M），不是 `ayolom_n_int8`（3.8M）**。ayolom 2026-10-02 才接入，表测于 2026-09-30 | 强（三重独立证据，§1） |
| 2 | **`ayolom_n_int8` 在 `.all` 下根本不往 GPU 派发**：289 个计算算子 preferred 全为 ANE，GPU preferred = **0**；`sample` 栈采样抓到的 GPU 执行帧 = **0** | 强（两种独立方法一致，§2） |
| 3 | ⟹ **把"驾驶态 GPU 36.4%"归因给 YOLOPX/ayolom 推理，不成立**（至少不成立于模型推理这一段）。真凶须转查抓屏/UI 链 | 强（基于 §2），但"真凶是谁"**未测** |
| 4 | `.cpuAndNE` 对 ayolom **可行且质量可证明无损**：三路输出 **逐位完全相同**（maxdiff = 0，n=42000 + 819200×2）；p50 5.4 → 5.5 ms（+1.9%，噪声内） | 强（实测，§4） |
| 5 | **`.cpuOnly` 的 548ms 未复现**。我的口径下是 ayolom 36.9ms / yolopx3 ~140ms。548ms 只存在于注释，无原始数据文件，口径不可比 | 中（复现失败即结论，§3） |
| 6 | `.cpuAndNE` 的真实价值不是省算力，而是**把"GPU 不是候选"写成硬约束**——`.all` 下 GPU 只是没被选中，仍留在 supported 集合里 | 强（§4.3） |
| 7 | 降频 / ROI 裁剪 / 降分辨率三条路**全部触及质量或频率红线**，逐条已标注（§6） | — |

**给 Lead 的一句话**：`.all → .cpuAndNE` 这个改动本身**质量零风险、性能几乎零代价**，但它**大概率治不好 36.4% 的 GPU 占用**，因为 ayolom 本来就没在 GPU 上跑。别把 GPU 账记在它头上。

---

## 1. 关键线索核实：那张 ABBA 表到底测的是谁

### 1.1 源码原文（`YolopxEngine.swift:705-746`，逐行照抄）

```swift
   705:    private func loadFirstUsableModel() -> (model: MLModel, name: String)? {
   706:        let config = MLModelConfiguration()
   707:        // ══════════════════════════════════════════════════════════════════
   708:        // 档位结论（2026-09-30 实测，两次独立 ABBA 复测后定案）
   709:        // ══════════════════════════════════════════════════════════════════
   710:        //
   711:        // **保持 `.all`。** 曾经改成 `.cpuAndNeuralEngine`（理由是"消除 19 个 GPU
   712:        // 算子、不与游戏抢 GPU"），**实测证伪，已回退**。
   713:        //
   714:        // 为什么当初的推理站不住：它基于**单次非交错测量**（45.9 vs 42.7ms 等）。
   715:        // 换用项目自己的 ABBA 交错协议（`tools/yolopx/bench_protocol.py` 的
   716:        // LoadController，模型常驻、只切档位标志位）复测两轮，结论相反：
   717:        //
   718:        //   场景           .all        .cpuAndNeuralEngine     胜者
   719:        //   ─────────────────────────────────────────────────────────
   720:        //   空载         183.0 ms        204.6 ms            .all 快 10.6%
   721:        //   8 核满载     191.4 ms        199.1 ms            .all 快  3.9%
   722:        //
   723:        // 两个场景 `.all` 都更快，且**负载下差距收窄而非扩大**——与当初
   724:        // "负载越高收益越大"的预期正好相反，说明那条假设的因果链不成立。
   725:        //
   726:        // 真正的瓶颈（本轮 `sample` 采样，见下方）不在档位选择，而在
   727:        // **Espresso 把部分推理派给了 CPU 后端**：
   728:        //   ExecuteStreamSync 258 样本
   729:        //     ├─ 162 (62.8%) E5RT::Ops::BnnsCpuInferenceOperation   ← CPU
   730:        //     └─  96 (37.2%) AneInferenceOperationImplUsingAnefAPIs ← ANE
   731:        // 而 `BnnsCpuInferenceOperation` 由 CoreML 内部调度决定，
   732:        // **不受 MLModelConfiguration.computeUnits 控制**——`.all` 已经是
   733:        // 让它自己挑最优的结果，人工指定反而更差（上表）。
   734:        //
   735:        // ⚠️ 关于"那 16 个 CPU 算子"（.cpuAndNE 档下）：它们是 PSA 模块的
   736:        //    `softmax`/`reduce_sum`，二者的 `supported_compute_devices` 实测
   737:        //    **只含 CPU/GPU，ANE 不存在**（硬件能力限制，非配置问题）。
   738:        //    两条改写路线均已尝试并**实测失败**（CPU 算子反而变多）：
   739:        //      · 拆成 exp/max/mean 零件       → CPU 10 → 21
   740:        //      · matmul 化折叠除法            → CPU 10 → 24
   741:        //    故不再尝试从图结构上消除它们。
   742:        //
   743:        // ⚠️ 另两个档位同样不可取（实测）：`.cpuAndGpu` 把 427 个算子全给 GPU
   744:        //    （97~100ms，慢一倍多，且文档记录曾触发 MPSGraph 断言 SIGABRT）；
   745:        //    `.cpuOnly` 更慢（548ms+）。
   746:        config.computeUnits = .all
```

### 1.2 判定：这张表测的是 `yolopx3`，对 `ayolom` 是空白区

**证据 A（时间线）**：表头自述 "2026-09-30 实测"（`:708`）。原始出处 `docs/老旧文档/已整合归档-2026-10-18/性能实测-2026-09-30-卡顿与定位.md:71` 同样记 09-30，且注明"ABBA 交替，各 12 轮"。而 ayolom 的接入时间更晚：

- `models/ayolom/README.md`：`## CoreML 产物（2026-10-02 导出）`
- `models/ayolom/ayolom_n_int8.mlmodelc/metadata.json`：`conversion_date = "2026-10-02"`
- git：`c3e1dd3 feat(感知): 接入 A-YOLOM(n) INT8 三合一...`（同时引入 abba 块与 ayolom 候选表）

⟹ **表测于 09-30，ayolom 09-30 时还不存在。**

**证据 B（"19 个 GPU 算子"对上了 yolopx3，对不上 ayolom）**：注释 `:711` 说动机是"消除 **19 个 GPU 算子**"。我用 MLComputePlan 实测两模型（§8 命令 1）：

| 模型 | 算子总数 | preferred=ANE | preferred=CPU | **preferred=GPU** | supported=GPU |
|---|---|---|---|---|---|
| `ayolom_n_int8` | 1189 | 289 | 2 | **0** | 291 |
| `yolopx3_pal8_detfp` | 1727 | 398 | 10 | **19** | **427** |

**19** 与注释里的"19 个 GPU 算子"精确吻合 yolopx3；ayolom 是 **0**。

**证据 C（"427 个算子"也只对得上 yolopx3）**：注释 `:743` 说 `.cpuAndGpu` 把 **427** 个算子全给 GPU。上表 yolopx3 的 `supported=GPU` 恰为 **427**；ayolom 为 **291**。

**证据 D（PSA softmax/reduce_sum 是 yolopx3 才有的结构）**：`:735-737` 说"16 个 CPU 算子是 PSA 模块的 `softmax`/`reduce_sum`"。mil 算子普查：

| 算子 | ayolom_n_int8 | yolopx3_pal8_detfp |
|---|---|---|
| `softmax` | **1** | **4** |
| `reduce_sum` | **0** | **4** |
| `reduce_mean` | **0** | **2** |

ayolom 根本没有 `reduce_sum`/`reduce_mean`，只有 1 个 softmax —— **`16 个 PSA CPU 算子`这个前提在 ayolom 上不存在**。

### 1.3 有一处需要提醒 Lead 的**推理链错误**

同批审计 `docs/perf-audit-20261024/3-compute-units.md:29` 对 ayolom 的判定是"**不动**（见 §4）／动它会踩已实测否决清单"；其 §4.1 标题写"`YolopxEngine` 的 `.all` —— 有完整的两轮 ABBA 交错实测否决书"。

问题在于 **`YolopxEngine` 这个类名同时装着两个模型族**（`family` 开关，`YolopxEngine.swift:614-625`、候选表 `:637-675`），而那张否决书全部数据来自 **yolopx3 一族**。把 yolopx3 的实测结论当成"`YolopxEngine` 任何档位改动都是退步"，是一次**跨模型族的外推**。对 ayolom 而言，这块是空白区——本节已用 §2/§4 的实测把它填上。

---

## 2. Q1：`.all` 下实际派发去哪

### 2.1 代码层：`.all` 是"让 CoreML 自选"，不是"派给 GPU"

`YolopxEngine.swift:746` 只写 `config.computeUnits = .all`，没有指定任何设备。`.all` 的语义是"CPU/GPU/ANE 都是候选，CoreML 自己挑"。

### 2.2 算子层：ayolom 的计算算子全部落在 ANE

MLComputePlan 实测 `ayolom_n_int8`（`.all` 配置）：

```
算子总数: 1189
preferred 设备派发:
  nil   898  (75.5%)
  ane   289  (24.3%)
  cpu     2  (0.2%)          ← 无 gpu
ANE cost 占比: 95.7%  (ANE 0.9 / 总 1.0)
supported 集合统计: [(gpu, 291), (cpu, 291), (ane, 289)]
非 ANE 算子（按 cost 排序）:
  const → nil ×814
  ios16.constexpr_lut_to_dense → nil ×84
  ios17.mul → cpu ×1    cost=0.0
  ios17.cast → cpu ×1   cost=0.0
```

关键读法，别被 75.5% 的 `nil` 误导：

- **`nil` 的 898 个全是常量**：`814 const + 84 constexpr_lut_to_dense = 898`，算术精确吻合。常量没有"设备"概念，`constexpr_lut_to_dense` 是**图加载时的权重解压**（int8 palette → dense），属编译期常量折叠，**不是每帧运行的 CPU 算子**。
- **真正的计算算子只有 291 个**：`289 ANE + 2 CPU = 291`。GPU preferred = **0**。
- 那 2 个 CPU 算子（`mul`/`cast`）估算 cost = **0.0**，与档位无关（`.all` 和 `.cpuAndNE` 下完全相同）。

### 2.3 执行层：`sample` 栈采样确认 GPU 执行帧 = 0

模型层派发是"打算去哪"，栈采样是"真的去哪"。对独立进程持续推理 22s，`sample 6s`：

| 后端 | ayolom `.all` | ayolom `.cpuAndNE` |
|---|---|---|
| `AneInferenceOperationImplUsingAnefAPIs::ExecuteSync` | **1731** | 有 |
| `BnnsCpuInferenceOperation::ExecuteSync` | **354** | — |
| **GPU/Metal/AGX 执行帧** | **0** | **0** |

（统计范围：`Call graph` 到 `Binary Images` 之间的调用树，共 1145 行，`grep -icE 'gpu|agx|metal'` = 0。注意 `sample` 报告里另有 19 处 Metal 字样，全部位于**已加载库清单**——"库被加载"不等于"GPU 被执行"，不能拿来当 GPU 证据。）

### 2.4 哪些算子 GPU 友好、哪些只能 CPU（ayolom）

| 类别 | 算子 | 设备归属 | 说明 |
|---|---|---|---|
| conv 主干 | `conv` ×110、`conv_transpose` ×2 | **ANE**（GPU 也友好，但没被选中） | 卷积是 ANE 的原生强项 |
| 激活 | `silu` ×95、`sigmoid` ×1 | **ANE** | 逐元素，成本极低 |
| 权重解压 | `constexpr_lut_to_dense` ×84 | 常量折叠（nil） | **不是运行时算子**，是 int8 调色板解压；不占 GPU 也不占每帧 CPU |
| 形状操作 | `split` ×18、`concat` ×33、`reshape` ×5、`transpose` ×1、`upsample_nearest_neighbor` ×8 | **ANE** | 无算术，派发代价≈0 |
| 归约/归一 | `softmax` ×1、`max_pool` ×3、`add` ×8、`mul` ×3、`sub` ×2 | **ANE**（`mul` 有 1 个落 CPU，cost=0） | ayolom 只有 1 个 softmax，远少于 yolopx3 的 4 个 |
| 只能 CPU | `ios17.mul` ×1、`ios17.cast` ×1 | **CPU**，cost = 0.0 | 两个档位下都是这两个，无法/无需迁移 |

**结论**：`ayolom_n_int8` 是一个 **"纯 conv + silu + 形状操作"的 ANE 亲和小模型**，GPU 对它没有任何吸引力。这与 yolopx3 形成鲜明对比（后者有 19 个 pure-GPU preferred 算子，含 softmax/reduce_sum 这类 ANE 不支持的归约）。

---

## 3. Q2：为什么 `.cpuOnly` 慢到 548ms

### 3.1 先说实话：548ms **我没复现**

- 548ms 这个数在仓库里**只出现在注释与文档转述**：`YolopxEngine.swift:745`、`docs/整合文档/05-性能与优化全史.md:211`、`3-compute-units.md:142` 等。**没有任何原始数据文件**（我全库搜 `548` 只命中这些转述）。
- 我的实测（同机、独立进程、模型常驻、ABBA 交错）：

| 模型 | `.all` | `.cpuAndNE` | `.cpuOnly` | cpuOnly/all |
|---|---|---|---|---|
| `ayolom_n_int8` | **p50 5.4 ms** | p50 5.5 ms | **p50 36.9 ms** | **6.8×** |
| `yolopx3_pal8_detfp` | ~47.6 ms* | ~47.3 ms* | **~140 ms\*** | **2.9×** |

\*yolopx3 用 8 秒饱和计数换算（168 / 169 / 57 帧），非分位数。

- **548ms 与我的 36.9ms / 140ms 差 4~15×，不可比**。最可能的差异来源：原测量是**真游戏运行时**（注释 `:745` 上下文与 `性能实测-2026-09-30` 的 62.8% BNNS 采样同批），叠加了争抢；我的是单进程背靠背、无游戏。**该数字的口径已不可考，建议不再引用为定量依据。** 标注：**未测（原口径）**。

### 3.2 慢的机制：不是"量化算子拖累"，是**放弃了 ANE**

一个直觉但**错误**的假设是"`.cpuOnly` 慢是因为那 84 个 `constexpr_lut_to_dense` 量化算子在 CPU 上跑得很慢"。事实（§2.2）：这 84 个是**常量折叠**，`preferred=nil`，连计算算子都算不上。

真实机制，三档 cost 结构对比（实测）：

| 档位 | preferred 分布 | ANE cost 占比 | CPU cost 占比 |
|---|---|---|---|
| `.all` | ane 289 / cpu 2 | **95.7%** | 4.3% |
| `.cpuAndNE` | ane 289 / cpu 2 | **95.7%** | 4.3% |
| `.cpuOnly` | **cpu 291 / ane 0** | **0.0%** | **100.0%** |

⟹ `.cpuOnly` 把**占 95.7% 成本的那 289 个算子从 ANE 强行搬到 CPU**。ayolom 是 conv 密集型，ANE 正是为这种负载设计的；用 BNNS 在 CPU 上跑同样的 conv，慢 6.8× 完全合理。yolopx3 更大更深（32M vs 3.8M），惩罚更重（2.9×，但绝对值 ~140ms）。

### 3.3 对第 3 问的推论

既然 `.cpuOnly` 的病根是"丢掉 ANE"，那么**保留 ANE 的 `.cpuAndNE` 就没有这个病**——它只在 `.all` 的基础上**移除 GPU 候选**，不触碰 ANE。这正是 §4 要验证的。

---

## 4. Q3：`.cpuAndNE`（CPU+ANE，不含 GPU）对 ayolom 是否可行

### 4.1 派发层：没有任何算子被额外挤下 ANE

`.cpuAndNE` 实测（同一模型、同一工具）：

```
▶ .cpuAndNeuralEngine
  算子总数 1189  preferred: nil=898  ane=289  cpu=2
  supported 计数: cpu=291  ane=289          ← gpu 从 supported 里消失了
  cost 占比: ane=95.7%  gpu=0.0%  cpu=4.3%
```

对照 `.all` 的 `supported: gpu=291 cpu=291 ane=289`：

- **preferred 分布完全不变**（ane 289 / cpu 2）⟹ **没有任何算子因为排除 GPU 而回退到 CPU**；
- 唯一变化是 `supported` 里 **gpu 291 → 消失** ⟹ 这才是 `.cpuAndNE` 的真正作用：**让 GPU 连候选都不是**。

### 4.2 质量层：三路输出**逐位完全相同**（这是本次最硬的证据）

同一份确定性输入，三档各跑一次，按 Float16 位模式逐元素比较：

```
── .all  vs  .cpuAndNE ──
  det n=42000   逐位不同 0 (0.000000%)  maxdiff=0.000e+00
  da  n=819200  逐位不同 0 (0.000000%)  maxdiff=0.000e+00
  ll  n=819200  逐位不同 0 (0.000000%)  maxdiff=0.000e+00
```

**maxdiff 精确等于 0，n = 42000 + 819200×2**。这不是"误差很小"，是**逐位同一**。⟹ 改成 `.cpuAndNE` 对检测/可行驶/车道线三路输出**在数学上不可能造成质量变化**。

对照 `.cpuOnly`（说明这个比较器确实能抓到差异，不是失灵）：

```
── .all  vs  .cpuOnly ──
  det n=42000   逐位不同 39411 (93.835714%)  maxdiff=6.242e+02
  da  n=819200  逐位不同 809025 (98.757935%) maxdiff=4.688e-01
  ll  n=819200  逐位不同 799349 (97.576782%) maxdiff=6.016e-01
```

我额外复核了 `.cpuOnly` 的偏离是**真实数值漂移**而非探针 bug：
`det[0..8]` `.all` = `[4.265625, 9.546875, 18.734375, …]`，`.cpuOnly` = `[4.265625, 9.640625, 17.84375, …]`；两者值域相同（min=0, max=637），**NaN/Inf 个数均为 0**。⟹ `.cpuOnly` 走的是不同的计算路径（数值实现不同），而 `.cpuAndNE` 与 `.all` 是同一条路径。

### 4.3 性能层：慢 1.9%，噪声内

ABBA 交错（5 轮 × 8 帧 = 每档 40 帧，模型全程常驻，方向交替）：

| 档位 | p50 | p95 | min | max |
|---|---|---|---|---|
| `.all` | **5.4 ms** | 7.4 ms | 4.8 | 7.5 |
| `.cpuAndNE` | **5.5 ms** | 8.3 ms | 5.0 | 9.2 |
| `.cpuOnly` | 36.9 ms | 79.0 ms | 32.1 | 84.5 |

p50 **+1.9%**，小于本次测量噪声（机器 load 5.53）。**但这是模型层单帧 prediction 的耗时，不等于 App 里的 16.9ms**——16.9ms 还含 letterbox + NMS + 两次掩码提取（`YolopxEngine.swift:996` `start` → `:1041` `latency` 覆盖 prediction + NMS + `extractMask`，见 `:1014`、`:1030-1039`）。端到端等价性需按 §5 在 App 层复验。

### 4.4 一次性的代价：加载慢

| 档位 | 首帧加载 |
|---|---|
| `.all` | 29 ms |
| `.cpuAndNE` | **1099 ms** |
| `.cpuOnly` | 90 ms |

`.cpuAndNE` 首次加载要 1.1s（ANE 编译）。这是**启动一次性成本**，由 `warmUp` 预热机制吸收（`YolopxEngine.swift:756-758` 的 `fastPrediction` 注释亦说明"加载时间的一点点代价是启动一次性成本"）。**未测**：App 内冷启动总时长影响。

### 4.5 判定

| 维度 | 结论 |
|---|---|
| 能否跑通 | ✅ 能，加载/推理/派发全部正常 |
| 有没有算子被挤下 ANE | ❌ 没有，preferred 分布与 `.all` 完全一致 |
| 质量影响 | ✅ **零**（三路逐位相同，maxdiff = 0） |
| 性能影响 | p50 +1.9%（噪声内）；首帧加载 +1.07s（一次性） |
| GPU 保证 | ✅ `supported` 中 GPU 被移除，从"没被选中"升级为"不可能被选中" |

---

## 5. Q4：可串行执行的 A/B 实验方案

> 前提：**先认清预期**。§2 已实测 `.all` 下 ayolom 的 GPU 执行帧为 0，所以本 A/B 的**预期结果是"质量与延迟均无显著差异"**。若实测出现明显差异，说明假设错了，先查环境负载，别急着接受结论。

### 5.0 环境准备（每次测量前）

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"
uptime                 # 记录 load average，必须与两段测量可比
# 关游戏、关录屏；接电源；同一网络状态
```

### 5.1 步骤（严格串行，一次只改一个变量）

**① 基线 A（3 次，交替顺序留待后面配平）**

```bash
for i in 1 2 3; do
  AURORA_UI_LOCAL=1 ./AuroraDriveUI --ayolom-selftest 2>&1 | tee /tmp/ab-A$i.txt
done
```

> `--ayolom-selftest` 的入口：`AuroraDriveApp.swift:1226-1232`；它会**硬性校验当前档位必须是 ayolom**（`:2560-2565`，若不是会直接报错退出，避免"以为测 A-YOLOM 其实测 yolopx"）。
> 默认即 ayolom（`YolopxEngine.swift:614-625`：未设 `AURORA_AYOLOM` → `.ayolom`），**不要**设 `AURORA_AYOLOM=0`。

**② 采什么指标**（自检输出已覆盖，`AuroraDriveApp.swift:2579-2607`、`YolopxEngine.swift:1673-1691`）

| 指标 | 来源 | 用途 |
|---|---|---|
| `检测框 N 个` | `:2590` | 质量：框数不得变化 |
| `可行驶占比 %` | `:2590` | 质量：**主判据** |
| `车道线占比 %` | `:2590` | 质量：**最敏感**（细目标最先被量化摧毁） |
| `延迟 X ms` | `:1672` | 性能 |
| `掩码网格 = 160` | `:2596` | 结构完整性 |
| `未误判降级` | `:2600` | 防"指标漂移被误读成降级" |
| `加载的是 int8 产物` | `:2573` | 防静默落到 fp16 兜底，导致对比失效 |

**③ 改常量（唯一改动点）**

`Sources/AuroraDrive/Inference/YolopxEngine.swift:746`

```swift
-        config.computeUnits = .all
+        config.computeUnits = .cpuAndNeuralEngine
```

> 只想试不改源码？可以临时用环境变量包一层（非本次推荐，会让 A/B 两边二进制不同）：
> ```swift
> config.computeUnits =
>     ProcessInfo.processInfo.environment["AURORA_YOLOPX_UNITS"] == "cpu_ne"
>     ? .cpuAndNeuralEngine : .all
> ```

**④ 重建**（按项目既有路径；我未执行，见 §7）

```bash
./run.sh                     # 或项目惯用的 swift build -c release
```

**⑤ 实验 B（3 次）**

```bash
for i in 1 2 3; do
  AURORA_UI_LOCAL=1 ./AuroraDriveUI --ayolom-selftest 2>&1 | tee /tmp/ab-B$i.txt
done
```

**⑥ 质量判定（硬红线，一票否决）**

```bash
# 三路指标必须逐字一致
diff <(grep -E "检测框|可行驶占比|车道线占比" /tmp/ab-A1.txt) \
     <(grep -E "检测框|可行驶占比|车道线占比" /tmp/ab-B1.txt)
```

| 结果 | 判定 |
|---|---|
| 无差异 | ✅ 通过（与 §4.2 模型层 bit-exact 相互印证） |
| 任一占比变化 | ❌ **否决**，且立刻排查是不是加载到了不同模型（比对 `模型:` 行） |

**⑦ 性能判定**

```bash
grep -E "延迟|理论上限" /tmp/ab-A*.txt /tmp/ab-B*.txt
```

**判据：B 的延迟 p50 不得 > A 的 1.15×**（§4.3 模型层实测 +1.9%，端到端留 15% 余量；超出即说明有别的开销被牵动）。

**⑧ GPU 判定（关键，别只看延迟）**

信号源 `ioreg` 与 `task_gpu_utilisation` 本机**已确认不可用**（见 §7.2/§7.3），故用栈采样：

```bash
PID=$(pgrep -f "AuroraDriveUI" | head -1)
sample "$PID" 10 1 -file /tmp/gpu-A.txt
awk '/Call graph/,/Binary Images/' /tmp/gpu-A.txt | grep -icE 'agx|metal|gpu'
```

**判据：该计数 == 0 为"无 GPU 执行"**。同时对 B 段跑同样采样。两段都应为 0（§2.3 预测）。

**⑨ 回退**

```bash
# 把 :746 改回 config.computeUnits = .all，重新构建
git diff --stat Sources/AuroraDrive/Inference/YolopxEngine.swift   # 应只有 1 行
git checkout -- Sources/AuroraDrive/Inference/YolopxEngine.swift   # 彻底回退
```

### 5.2 如果目标是"消掉 36.4% GPU 占用"

那么 **不要从这一步开始**。按 §2 的实测，ayolom 推理不产生 GPU 帧，改它的档位不会改变设备级 GPU 占用。正确顺序是：

1. 驱动态下 `sample` 整个 App 10s；
2. `awk '/Call graph/,/Binary Images/'` 里找 GPU/AGX 帧，看它们挂在哪个模块（抓屏？UI 上采样？）；
3. 已知线索：`Sources/AuroraDrive/Capture/CaptureEngine.swift` 有 **5 处** `MTLDevice`/`Metal` 引用（`grep -c` 实测），**未测**其 GPU 占比。

---

## 6. Q5：还有没有别的办法把 YOLOPX 的 GPU 占用降到 0 而质量不降

> **先说结论**：按 §2 的实测，**ayolom 的 GPU 占用已经是 0 了**。下面四条是从"还能不能更省/更稳"角度评估，每条都标注对质量的影响。用户红线是**不许降质量**，另据项目决策还有**不许降频**——两条都会卡。

| 方案 | 能否把 GPU 降到 0 | 对质量的影响 | 判定 |
|---|---|---|---|
| **A. 改 `.cpuAndNE`** | ✅ 把 GPU 从 `supported` 移除，硬保证 | **零**（三路逐位相同，§4.2） | ✅ **唯一推荐**，但收益是"保证"不是"省算力" |
| **B. 降低推理频率**（每 2–3 帧 + 跟踪补间） | 无额外收益（本就 0） | ⚠️ 实时性退化：检测框更新 15Hz → 5–7.5Hz；补间是**外推**，不是实测，新出现目标/急横移会滞后 | ❌ **违反红线**。且用户已明确拍板 ayolom 每帧跑（`AuroraDriveApp.swift:7102-7108`：「ayolom 每帧跑…用户拍板」） |
| **C. ROI 裁更小** | 无额外收益 | ⚠️ **改视野即改语义**：letterbox 比例变化（`metrics.ratio/padX/padY` 参与反变换），边缘目标可能出画；除非精确裁掉已被自车框屏蔽的区域 | ❌ 不建议。**未测**（裁自车区理论上无损，但需重验坐标变换，工作量 > 收益） |
| **D. 更小模型 / 更低输入分辨率** | 无额外收益 | ❌ 降分辨率 = 降精度，直接违反红线；模型已是 `n` 档（`v4.pt`，3.64M 参数，`models/ayolom/README.md`），无更小档除非重训 | ❌ **明确违反红线** |

**唯一真正的零质量建议**：§5.2 的方向——**去抓屏/UI 链找那 36.4%**，而不是继续压 YOLOPX。

---

## 7. 方法学、口径与"我测不到的东西"

诚实标注，避免把这些当结论用。

### 7.1 我的测量条件

- 独立 Swift 进程加载**同一份 `.mlmodelc`**，输入 640×640 真实 `CVPixelBuffer`（模型契约要求 Image 类型，见 `models/ayolom/README.md`「输入必须是 ImageType 而不是 TensorType」）。
- 机器 load average **5.53**（测量时）——偏高，故 p50 差异在 ±10% 内一律视为噪声。
- 随机噪声输入 ⟹ §4.2 的 bit-exact 比较**有效**（两侧输入完全相同），但**前景占比 0.0000% 是无意义结果**（噪声图里没有路），不作为质量指标。

### 7.2 未能测：设备级 GPU 利用率归属

`ioreg -r -d 1 -c IOAccelerator` 的 `Device Utilization %` 在本机噪声过大：空闲基线采样为 `69 84 74 71 69 61 52 49 46 57`（受 WindowServer / 双显示器 / Harness 渲染器干扰），推理中读数 `64 77 70 74 71 38 60 47 51 55 57 66 53 49 60 63`，**两者不可区分**。⟹ **无法用它验证或复现"36.4% vs 0.7%"**。标注：**未测**。

### 7.3 未能用：`task_gpu_utilisation`

`TASK_POWER_INFO_V2.task_gpu_utilisation` 在**阳性对照**上就是 0：连明知有 19 个 GPU 算子的 `yolopx3` 也返回 `gpuΔ=0`（6s / 106 帧）。指标失效，**已弃用，不作为任何结论依据**。（ayolom `.all` 同口径也返回 0，但不可采信。）

### 7.4 未能测：App 端到端

- 我**没有启动 App**（纪律要求）。§4.2 的 bit-exact 是**模型层**结论；端到端（含 NMS、掩码提取、EMA 平滑）需按 §5 复验。
- 548ms 的原始测量口径**未恢复**（无原始数据文件）。
- 抓屏链 / UI 上采样链的 GPU 占比**未测**。

### 7.5 一处口径提醒

任务给的前提是"YOLOPX 实测 16.9ms/帧（推理 + NMS + 掩码提取）"。我模型层测到的 prediction 是 **5.4ms p50**，差额 ~11.5ms 应落在 letterbox + NMS + 两次 `extractMask` 上（`YolopxEngine.swift:996-1041` 的计时区间覆盖这些步骤）。**这两组数不矛盾**，但**不可相互引用**——谈"GPU 派发"时用 5.4ms，谈"帧预算/占空比"时用 16.9ms。

---

## 8. 复现命令清单（均只读，不改源码、不启动 App）

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"

# 1) 算子级派发（两模型对照）
swift tools/ane_dispatch_check.swift models/ayolom/ayolom_n_int8.mlmodelc
swift tools/ane_dispatch_check.swift models/yolopx/yolopx3_pal8_detfp.mlmodelc

# 2) 算子普查（独立复核派发结论）
grep -oE "= [a-z_0-9]+\(" models/ayolom/ayolom_n_int8.mlmodelc/model.mil \
  | sed 's/= //;s/(//' | sort | uniq -c | sort -rn | head -20

# 3) 三档 ABBA 计时 + 三档输出逐位等价
swift /tmp/ab_ayolom.swift   models/ayolom/ayolom_n_int8.mlmodelc
swift /tmp/bitexact_ayolom.swift models/ayolom/ayolom_n_int8.mlmodelc

# 4) 执行栈采样（判"到底有没有 GPU 执行帧"）
swiftc -O /tmp/burn_pid.swift -o /tmp/burn_pid
/tmp/burn_pid models/ayolom/ayolom_n_int8.mlmodelc all 22 &
sleep 4; PID=$(grep -o 'PID=[0-9]*' /tmp/burn_pid.log | cut -d= -f2)
sample "$PID" 6 1 -file /tmp/sample.txt
awk '/Call graph/,/Binary Images/' /tmp/sample.txt | grep -icE 'gpu|agx|metal'   # 期望 0

# 5) App 层自检（需构建产物；本轮未跑）
AURORA_UI_LOCAL=1 ./AuroraDriveUI --ayolom-selftest
```

> `/tmp/ab_ayolom.swift`、`/tmp/bitexact_ayolom.swift`、`/tmp/burn_pid.swift` 是本次审计**在 /tmp 下临时写的探针**，未进入仓库。如需长期留存，建议移入 `tools/`（本次因"不改源码"纪律未做）。

---

## 9. 最终回答（对着 5 个问题）

1. **`.all` 派发去哪**：ayolom 的 291 个计算算子中 **289 个 preferred=ANE、2 个 CPU（cost=0）、0 个 GPU**；GPU 虽在 `supported` 里但从未被选中。栈采样验证：ANE 执行帧 1731、CPU 354、**GPU 0**。conv/silu/形状操作 GPU 友好但 ANE 更强；只有 2 个 `mul`/`cast` 落 CPU 且成本为 0。（§2）
2. **`.cpuOnly` 为何慢**：**548ms 未复现**（我实测 36.9ms / 140ms，口径不可比）。病根不是量化算子，而是**放弃了承载 95.7% 成本的 ANE**，把 conv 主干压到 BNNS。倍率 6.8×（ayolom）/ 2.9×（yolopx3）。（§3）
3. **`.cpuAndNE` 是否可行**：**可行，且质量可证明无损**。无算子被挤下 ANE（preferred 分布与 `.all` 相同）；三路输出**逐位相同 maxdiff=0**；p50 +1.9%；首帧加载 +1.07s。`supported` 里 GPU 被彻底移除。（§4）
4. **A/B 方案**：改 `YolopxEngine.swift:746` 一行 → `./run.sh` → 跑 3× `--ayolom-selftest` 与基线 3× 对比；判据 = 三路指标逐字一致 + 延迟 ≤1.15× + 栈采样 GPU 帧 = 0。（§5）
5. **还有别的办法吗**：**改档位是唯一零质量方案**。降频违反频率红线且用户已拍板每帧跑；ROI 裁剪改视野语义、未测；降分辨率/换更小模型明确违反质量红线。**且这四条对"降 GPU"都没有额外收益——因为 ayolom 已是 0 GPU**。（§6）
