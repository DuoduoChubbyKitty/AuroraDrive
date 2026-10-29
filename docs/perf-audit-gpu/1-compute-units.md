# 1 · CoreML `computeUnits` 全量审计（GPU 能不能全部挪走）

- 审计时间：2026-10-24 22:32–23:10
- 审计对象：`/Users/dupi/Desktop/自动驾驶系统`（AuroraDrive，SwiftPM/macOS，M3 MBA 8 核 16GB）
- 用户死命令：**「GPU 绝对不能占用，允许拿 CPU 换」**
- 纪律：**纯只读**。未改任何源码、未 `swift build`、未启动 App（Lead 在串行实测，避免多实例污染 GPU 数据）。
- 本报告新增的客观证据：用 `MLComputePlan` **离线**解析磁盘上的 `.mlmodelc`，按**生产实际档位**逐模型取 `preferred` 设备派发计数。探针只读模型文件、不启动 App、不进生产代码（脚本见 §7）。

---

## 1. 一句话结论（先看这个）

**「把所有 `.all` 改成 `.cpuOnly`」这条指令，在本仓库已经是完成态 —— 剩下的 `.all` 全是空转的，GPU 一个算子也不会被它们派出去。**

更准确地说，本轮离线实测得到一个**推翻直觉的硬事实**：

> 全仓 **11 个模型、按它们运行时真实使用的档位**逐个解析，**GPU 优先算子数全部 = 0**。
> 连最可疑的 `.all`（`game_assist_control` / `m9_mono` / `ayolom_n_int8` / `yolo26s`）也是 **0 个 GPU 算子**。

所以：

| 问题 | 答案 |
|---|---|
| 还有哪些模型可以从 GPU 挪到 CPU/ANE？ | **CoreML 模型侧：一个都没有了。** `.all` 在该机型上并没有把算子派给 GPU |
| 那驾驶态 36.4% 的 GPU 驻留是谁产生的？ | **不是 `computeUnits` 管辖的东西** —— 见 §5（`CIContext` / Vision / 抓屏合成链）。真正能动的杠杆在这里 |
| `game_assist_control` 还在抢 GPU 吗？ | **不会。** 实测 `.all` 下 240 算子中 `ane=64`、`const=176`、**`gpu=0`** |
| `InferenceEngineV2.swift:1733/1881` 的 `.all` 跑得到吗？ | **1733 跑不到**（被双模型拆分路径 `return` 拦截）；**1881 只在兜底时才跑**。两者都**不产生 GPU 算子**（实测 gpu=0） |

**一句话给用户**：模型档位这条路已经走到头了；要继续压 GPU，得去查 `CIContext`/Vision/合成链（§5），而不是继续拧 `computeUnits`。

---

## 2. 主表（全仓 21 处 `computeUnits` 逐条判定）

### 2.1 生产模型加载点（真正决定运行时设备）

> 「GPU 算子实测」列 = 本轮用 `MLComputePlan` 按**该行实际档位**离线解析的结果（§7 探针），非推测。
> 「每行对应模型」= 该配置对象最终喂给 `MLModel(contentsOf:)` 的模型文件。

| # | 文件:行 | 模型 | 当前 computeUnits | 运行时是否真加载 | 是否可能派发 GPU（实测） | 改法与风险 |
|---|---|---|---|---|---|---|
| 1 | `InferenceEngine.swift:164` | `m9_mono`（`loadIfNeeded` 同步路径） | `.all` | **否**。`AuroraDriveApp.swift:6434` 已改为**仅当 V2 加载失败**才调（原无条件加载已被移除）。日志 `M9=false` 印证 | **不会**。实测 `.all` 下 `ops=240 / gpu=0 / ane=64 / const=176` | **不用改**（零收益）。注意：非「已实测否决」，而是「实测 gpu=0，无收益」 |
| 2 | `InferenceEngine.swift:206` | `m9_mono` **或** `game_assist_control`（`scheduleBackgroundLoadIfNeeded` 兜底路径） | `.all` | **会**（对 `game_assist_control` 这条；见 #3） | **不会**。同上实测 `gpu=0` | **不用改** |
| 3 | `InferenceEngine.swift:164` & `:206` **共用** → 实际喂 `game_assist_control` | `game_assist_control`（第二司机） | `.all` | **会，且确认在跑**。`AuroraDriveApp.swift:6435` 无条件 `assistEngine.loadIfNeeded()`；`:7543` 在 e2e 档**每 5 帧**、`.yolo` 档**每帧**调 `infer`。日志 `第二司机=true` | **不会**。实测 `.all` 下 `gpu=0`（`ane=64 / const=176`）。**这是本轮最反直觉的一条**：7.6MB 的纯卷积+linear 网，CoreML 在 M3 上把 64 个可加速算子**全给了 ANE**，一个都没给 GPU | **改 `.cpuAndNeuralEngine` 是安全的**（语义上显式排除 GPU），但**收益 = 0**（本来就没上 GPU）。若为「防御未来 CoreML 调度策略变化」可改，代价：**未测**（需 ABBA 实测 p50 不能劣化，现状 `infer.assist` p50=2.118ms @ `tools/perf/raw/baseline-postA/perf-selftest.log:29`） |
| 4 | `YolopxEngine.swift:746` | `ayolom_n_int8`（默认档）/ `yolopx3_pal8_detfp`（legacy 档） | `.all` | **会**。默认档每 tick 恒跑；日志 `YOLOPX=true` | **不会**。实测 `ayolom_n_int8` 在 `.all` 下 `ops=1189 / gpu=0 / ane=289 / cpu=2 / const=898` | **绝对不动**（用户红线已写：`.cpuOnly` 实测 548ms+；另有两轮 ABBA 实测否决 `.cpuAndNE`，`YolopxEngine.swift:705-746` 原文见 §6）。**但请注意**：它 `.all` 下也是 `gpu=0` —— 那条「19 个 GPU 算子」的旧结论**与本次实测不符**，见 §6.2 |
| 5 | `YoloEngine.swift:187` | `yolo26s` | `.all` | **当前否**。`AuroraDriveApp.swift:6449` 仅 `legacy` 档或 `AURORA_FORCE_YOLO26S=1` 才加载；默认档 `.ayolom`（`:5455`）**不加载**。日志 `YOLO=false` 印证 | **不会**。实测 `.all` 下 `ops=1148 / gpu=0 / ane=276 / cpu=21` | **不用改** |
| 6 | `InferenceEngineV2.swift:1712` | `world_model` | `.cpuOnly` | **否**。默认 `worldModelEnabled=false`（`:1687`，需 `AURORA_WORLD_MODEL=1`） | **不会**（已是 cpuOnly；实测 `gpu=0`） | **不用改**（已最优，且默认不加载） |
| 7 | `InferenceEngineV2.swift:1733` | `m9_v2`（单模型回退路径的 `cfg`） | `.all` | **否 —— 跑不到**。该 `cfg` 只在走到 `:1851` 单模型分支时才被使用，而 `:1744`（multi_split）与 `:1813`（双模型）两条分支**都会先 `return`**。默认 `enableMultiSplit=false`（`:1552`），双模型路径在 `m9_v2_enc.mlmodelc` + `m9_v2_ctl.mlmodelc` **均存在**（已验证磁盘上存在）时必然成功 → `:1843` 的 `guard let url = modelURL` 之前就返回了 | **即使跑到也不会**：实测 `m9_v2.mlmodelc` `.all` 下 `ops=891 / gpu=0 / cpu=453 / const=438`。**注意 `cpu=453`**：它 `.all` 下**全落 CPU**，不上 GPU 也不上 ANE | **不用改**（不可达 + 实测 gpu=0）。**这一条正是任务里点名怀疑的「重大发现」—— 结论是：不成立，不是漏网 GPU 用户** |
| 8 | `InferenceEngineV2.swift:1753` | `m9_v2_enc`（multi_split） | `.cpuAndNeuralEngine` | **否**。`enableMultiSplit=false` 默认关闭 | **不会**（显式排除 GPU；实测 `gpu=0 / ane=30`） | 不用改 |
| 9 | `InferenceEngineV2.swift:1757` | `m9_v2_tf`（multi_split） | `.cpuOnly` | **否**（同上） | **不会** | 不用改 |
| 10 | `InferenceEngineV2.swift:1763` | `m9_v2_chunk1~6`（multi_split） | `.cpuOnly` | **否**（同上） | **不会** | 不用改 |
| 11 | `InferenceEngineV2.swift:1767` | `m9_v2_head`（multi_split） | `.cpuOnly` | **否**（同上） | **不会** | 不用改 |
| 12 | `InferenceEngineV2.swift:1818` | `m9_v2_enc`（**双模型，现役**） | `.cpuAndNeuralEngine` | **会**。日志 `V2拆分=true` | **不会**（实测 `gpu=0 / ane=30`）。**正面样例** | 已最优，不动 |
| 13 | `InferenceEngineV2.swift:1821` | `m9_v2_ctl`（**双模型，现役**） | `.cpuOnly` | **会** | **不会**（显式 cpuOnly）。**这一条是全仓唯一「改对了」的地方**：实测它在 `.all` 下 **`gpu=607 / 913 = 66.5%`** —— 是所有模型里唯一真的会把算子派给 GPU 的 | **已是最优**（用户红线段：`.cpuOnly` 0.57ms 已实测）。**这是全仓唯一一个「若不设档位就会抢 GPU」的模型，且它已经被正确设成 `.cpuOnly`** |
| 14 | `InferenceEngineV2.swift:1881` | `m9_v2`（**后台兜底加载**） | `.all` | **仅在兜底时**。`scheduleBackgroundLoadIfNeeded()` 由 `infer:2007` 在「V2 未加载/拆分未就绪」时调用。正常运行 `isLoaded=true` → 不进该分支 | **即使跑到也不会**：实测 `gpu=0`（`cpu=453 / const=438`） | **不用改**（不可达常态 + 实测 gpu=0）。**任务点名的第二个疑点 → 结论同样是不成立** |
| 15 | `PointerHeadingReader.swift:290` | **`tiny_arrow_v2`**（不是 `pointer_heading`！`init` 默认参数在 `:273`） | `.cpuAndNeuralEngine` | **会**。`AuroraDriveApp.swift:6003` `PointerHeadingReader()` 用默认名；`infer:7445` 每 3 帧调一次（15Hz÷3 = 5Hz） | **不会**（实测 `tiny_arrow_v2` `.cpuAndNE` 下 `gpu=0 / cpu=19 / const=53`） | 已最优，不动。⚠️ **纠正一个前提**：`pointer_heading` 这个模型在全仓 `Sources/` **零引用**（`grep -rn "pointer_heading" Sources/` → 无命中），它**不参与运行时**。任务里写的「`pointer_heading` → `.cpuAndNeuralEngine`」实际指的是 `tiny_arrow_v2` |
| 16 | `SpeedOCRReader.swift:433` | `ppocrv6_tiny_ft_int8` + `speed_digit_cnn_v4`（同一 `loadOneModel` 共用） | `.cpuAndNeuralEngine` | **会**，15Hz | **不会**（实测两者 `.cpuAndNE` 下 `gpu=0`；**对照**：即便用 `.all` 也是 `gpu=0`） | 已最优，不动。**注意**：`docs/perf-audit-20261024/3-compute-units.md` 记录它是「裸加载 → 默认 `.all`」，那是**该文档写作时**的状态；**当前工作区代码 :433 已显式 `.cpuAndNeuralEngine`**，那条建议已经落地。⚠️ **该行是未提交改动**（`git show HEAD:...SpeedOCRReader.swift \| grep -c computeUnits` → **0**），HEAD 版本仍是裸加载。Lead 若按 HEAD 复核会发现「没有这一行」—— 以**工作区**为准 |

> 📌 **行号基准说明**：本表所有行号均取自**当前工作区**（含未提交改动）。`git status` 显示 5 个 Swift 文件处于已修改状态（均为 **2026-10-24 13:40–20:12** 的历史改动，**早于本次审计 22:32 开始**，非本报告产生）。其中只有 `SpeedOCRReader.swift` 的改动涉及 `computeUnits`（新增 :433）；其余 4 个文件与 `computeUnits` 无关。本报告**未修改任何源码**。

### 2.2 非加载点 / 仅字面量

| 文件:行 | 说明 | 判定 |
|---|---|---|
| `InferenceEngine.swift:250` | `print` 里的字符串 `computeUnits=all(...)` | 仅日志文案，非配置。**文案已过时**（若改了档位不会同步），建议顺手改为打印真实档位 |
| `YoloEngine.swift:227` | 同上 | 同上 |
| `InferenceEngineV2.swift:200` / `:1493` / `:1522` / `:1699` / `:1807` | 注释中的 `computeUnits` 说明 | 仅注释 |

### 2.3 工具代码（不在生产路径，不计入运行时）

| 文件:行 | 说明 |
|---|---|
| `tools/ane_dispatch_check.swift:22` | `cfg.computeUnits = .all` —— **审计工具**，固定 `.all` 以便观察默认调度 |
| `tools/gpu_usage_check.swift:206,404` | 实验工具，按参数切档 |
| `tools/exp_exec_bench.swift:61-64` | 实验工具，命令行切档 |
| `tools/compare_split_strategies.swift:9`、`tools/measure_multi_split.swift:44`、`tools/exp_pipeline_overlap.swift:64` | 实验工具 |

> **`.venv-yolo26/` 与 `tools/ayolom/.venv/` 里的 coremltools 源码命中全部是第三方库**，与产品无关，已排除。

---

## 3. 本轮离线实测证据（可复现，未启动 App）

### 3.1 方法

用 `MLComputePlan.load(contentsOf:configuration:)` 直接解析磁盘上的 `.mlmodelc`，按**生产实际档位**取每个算子的 `preferred` 设备。这走的是 CoreML 自己的设备分配器，**不需要加载模型跑推理、不需要启动 App**。

### 3.2 结果总表（`preferred` 设备计数）

| 模型 | 档位（生产实配） | 算子总数 | **GPU** | cpu | ane | const(nil) |
|---|---|---|---|---|---|---|
| `game_assist_control` | `.all` | 240 | **0** | 0 | 64 | 176 |
| `m9_mono` | `.all` | 240 | **0** | 0 | 64 | 176 |
| `m9_v2` | `.all` | 891 | **0** | 453 | 0 | 438 |
| `m9_v2`（兜底，同 #） | `.all` | 891 | **0** | 453 | 0 | 438 |
| `m9_v2_enc` | `.cpuAndNeuralEngine` | 126 | **0** | 0 | 30 | 96 |
| `m9_v2_ctl` | `.cpuOnly` | 913 | **0** | 607 | 0 | 306 |
| `ayolom_n_int8` | `.all` | 1189 | **0** | 2 | 289 | 898 |
| `yolo26s` | `.all` | 1148 | **0** | 21 | 276 | 851 |
| `tiny_arrow_v2` | `.cpuAndNeuralEngine` | 72 | **0** | 19 | 0 | 53 |
| `ppocrv6_tiny_ft_int8` | `.cpuAndNeuralEngine` | 374 | **0** | 0 | 78 | 296 |
| `speed_digit_cnn_v4` | `.cpuAndNeuralEngine` | 82 | **0** | 0 | 20 | 62 |
| `world_model` | `.cpuOnly` | 124 | **0** | 69 | 0 | 55 |

### 3.3 关键对照组：`.cpuOnly` 是不是真的有必要？

唯一会大量派发到 GPU 的模型是 **`m9_v2_ctl`**：

| 模型 | `.all` | `.cpuOnly` |
|---|---|---|
| `m9_v2_ctl` | **gpu = 607 (66.5%)** | gpu = 0（cpu = 607） |
| `m9_v2_enc` | gpu = 0（ane = 30） | — |
| `game_assist_control` | gpu = 0（ane = 64） | — |
| `ayolom_n_int8` | gpu = 0（ane = 289） | — |

**这张表解释了两件事**：

1. **为什么 `m9_v2_ctl` 必须 `.cpuOnly`** —— 它在 `.all` 下真的会把 66.5% 的算子塞给 GPU。这与源码注释 `InferenceEngineV2.swift:1807-1812` 记录的「`.all` 下 preferred=gpu 71.8% → 3.48ms；`.cpuOnly` → 0.57ms，快 6.1×」**方向一致**（比例 66.5% vs 71.8%，差异来自统计口径：本次算的是**全部算子**含 const，注释里算的是**可执行算子**基数）。这条**互相印证，增强可信度**。
2. **为什么其它 `.all` 不值得改** —— 它们本来就没派 GPU，改了不省 GPU、只可能改变延迟。

> ⚠️ **口径说明（避免误读）**：上表 `const(nil)` 是权重常量初始化，不消耗算力。真正「跑起来」的算子是 cpu+ane+gpu 三列之和。即便如此，**GPU 列全为 0** 的结论不受口径影响。

---

## 4. 任务点名的两个疑点 —— 逐条查清

### 疑点 ①：`InferenceEngine.swift:164,206` 共用类，`game_assist_control` 还在用 GPU 吗？

**结论：不用。零 GPU 算子。**

证据链：

1. **共用类属实**：`InferenceEngine.swift:125-129` 注释原文：
   > `/// A20（2026-10-04）：PerfBus 通道名。`
   > `/// 同一份代码承载两套模型（M9 端到端主驾 / game_assist_control 第二司机），`
   > `private var perfChannel: String { modelFileName == "game_assist_control" ? "infer.assist" : "infer.m9" }`

2. **`game_assist_control` 确实在加载、确实在推理**（不是死代码）：
   - 加载：`AuroraDriveApp.swift:6435` `assistEngine.loadIfNeeded()      // 首次启动加载第二套驾驶模型（YOLO接管档）`
   - 推理：`AuroraDriveApp.swift:7543`
     > `if !assistKeepalive || mode == .yolo || adaptiveFrameCounter % 5 == 0 {`
     > `    assistEngine.infer(image: cg, speedKmh: effectiveSpeed, speedLimitKmh: speedLimit)`
   - 运行日志实证：`tools/perf/raw/baseline-postA/perf-selftest.log:16` `[warmup] game_assist_control 预热完成: 1.3ms  computeUnits=all(自动选 ANE/GPU/CPU)`，`:29` `infer.assist n=198 p50=2.118 p95=6.250`

3. **但它在 `.all` 下不派 GPU**：`MLComputePlan` 实测 `gpu=0`，64 个算子 `preferred=ane`。

4. **它的结构与 `m9_mono` 几乎同构**（MIL 算子统计）：
   | 模型 | conv | linear | relu | sigmoid | tanh | constexpr 反量化 |
   |---|---|---|---|---|---|---|
   | `game_assist_control` | 22 | 6 | 25 | 2 | 1 | 24（int8） |
   | `m9_mono` | 22 | 6 | 25 | 2 | 1 | 0（fp16） |

   两者都是「小卷积主干 + 全连接头」的纯 CNN。**这类图在 M3 上 CoreML 会整块塞给 ANE**，这与 `ppocrv6`/`ayolom` 的实测行为一致。

**可选改动（收益 0，仅防御性）**：把 `:164`/`:206` 改 `.cpuAndNeuralEngine`。**风险**：`game_assist_control` 的 int8 反量化算子（24 个 `constexpr_affine_dequantize`）在 ANE 上的派发策略可能与 `.all` 不同，**是否劣化未测**。按用户「零质量影响」红线，**建议不改**，除非有 ABBA 实测证明 p50 不劣化。

### 疑点 ②：`InferenceEngineV2.swift:1733` 和 `:1881` 都是 `.all`，分别对应哪个模型？跑得到吗？

**结论：两处都对应 `m9_v2`（同一个单模型），且都跑不到 / 跑了也不上 GPU。**

| 行 | 模型 | 何时可达 | 实测 GPU |
|---|---|---|---|
| `:1733` `cfg.computeUnits = .all` | `m9_v2`（`models/m9_v2.mlmodelc`，磁盘存在） | **常态不可达**。该 `cfg` 只在 `:1851` 单模型分支使用；而 `:1744` multi_split（需 `enableMultiSplit=true`，默认 `false`）和 `:1813` 双模型（`m9_v2_enc`+`m9_v2_ctl` 都在磁盘上）**两条分支都先 `return`** | **0** |
| `:1881` `mlCfg.computeUnits = .all` | `m9_v2`（同上） | **仅兜底可达**。`scheduleBackgroundLoadIfNeeded()` 由 `:2007` 在 `guard isLoaded, (model != nil \|\| useSplitModels... \|\| multiReady)` **失败时**调用。正常运行 `isLoaded=true` → 不进入 | **0** |

代码原文（`InferenceEngineV2.swift:1731-1733`）：

```swift
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
```

代码原文（`InferenceEngineV2.swift:1879-1882`）：

```swift
            let mlCfg = MLModelConfiguration()
            mlCfg.computeUnits = .all
            let loaded = try? MLModel(contentsOf: url, configuration: mlCfg)
```

**「跑得到就是重大发现」的判定**：**跑得到，但不是重大发现** —— 因为 `m9_v2` 在 `.all` 下实测 **`cpu=453 / gpu=0`**，它压根不上 GPU（ANE 编译失败回退 CPU，与 `性能-推理GPU占用审计-2026-10-11.md` 记录的 `MILCompilerForANE error: ANECCompile() FAILED` 一致）。

---

## 5. 真正的 GPU 来源不在 `computeUnits`（本报告的增量价值）

用户的死命令是「GPU 绝对不能占用」。既然 CoreML 模型侧实测 GPU=0，那 36.4% 的驻留来自别处。**以下是代码级已定位的、不受 `computeUnits` 管辖的 GPU 提交源**：

| # | 位置 | 机制 | 是否生产默认开启 | 是否已实测 |
|---|---|---|---|---|
| A | `SpeedOCRReader.swift:814`（`cropSlots`） | `ciContext.createCGImage` → **Metal**。`useSoftwareRenderer: true` 在 Apple Silicon 上**被静默忽略**（`CIContext.h:184`：该选项在无 OpenCL 平台无效） | **条件开启**：仅 CNN 备用路径（`:610` PP-OCR 故障降级 / `:619` `activeEngine == .cnn`） | **未测**（未打开 App 实测 GPU 增量）。代码证据：`:842-847` 注释已记录「`createCGImage` 在 Apple Silicon 上必然走 Metal 并同步等 GPU」 |
| B | `SpeedOCRReader.swift:973`（`recognizePPOCR`） | 同上 | **默认关闭**：`:970` `if isROISlice \|\| Env["AURORA_OCR_CI"] != "1"` → 走纯 CPU 的 `cgImageFromPixelBuffer`；仅 `AURORA_OCR_CI=1` 才走 CIContext | **未测**（默认路径不走） |
| C | `SpeedOCRReader.swift:1391`（`lanczosResize`） | 同上 | **条件开启**：只被 `recognizeCNN`（`:1305`）调用，即 CNN 备用路径 | **未测** |
| D | `SpeedOCRReader.swift:1492`（`saveOCRDebug`） | 同上 | **条件开启**：`:631-634` 仅当 `result.speed == nil && diag.hasPrefix("fg=")` 即**读不到速度表**时触发（覆盖写 /tmp） | **未测** |
| E | `ConfidenceEstimator.swift:345`（`averageBrightnessViaCoreImage`） | `brightnessContext.render` → Metal | **默认关闭**：`:274` `useCoreImagePath = Env["AURORA_CONF_CI"] == "1"`；`:278` 默认走纯 CPU `averageBrightnessViaCPU` | **未测**（默认不走） |
| F | `QuestPanelReader.swift:649-654` | `VNRecognizeTextRequest` + `VNImageRequestHandler`（**Vision，内部走 GPU/ANE**） | **默认开启**：`AuroraFlags.swift:201` `questOCR = bool("AURORA_QUEST_OCR", default: true)`；`AuroraDriveApp.swift:7243` 每 tick 喂帧，内部节流 `minInterval = 0.7s`（`QuestPanelReader.swift:431`） | **未测**。⚠️ 这是**最值得下一步实测**的目标：默认开、每 0.7s 一次真实 Vision 推理 |
| G | `LoginAssistant.swift:47-52` | `VNRecognizeTextRequest` | 仅登录流程 | **未测** |
| H | 抓屏/缩放/合成链（`CaptureEngine.swift:1152,1186`） | 已刻意绕开 `CIContext(GPU)` 改用 vImage/CPU | 已改好 | 代码证据充分 |

**结论**：模型侧已经「零 GPU」。要继续逼近「GPU 绝对不占用」，**下一步该测的是 F（Vision，默认开启）和 A/C/D（OCR 的 CIContext 分支，条件开启）**，而不是继续动 `computeUnits`。

> 说明：待机时 GPU 仅 0.7%，而 `questOCR` 默认开启且需 `currentFrameCG`（`AuroraDriveApp.swift:7243` 的 `let cg = currentFrameCG`）—— 待机不抓屏 → 不进 Vision。这与「待机 0.7% / 驾驶态 36.4%」的现象**自洽**：Vision 只在有帧时跑。这条推断**未实测**，仅作下一步假设，不得当作结论。

---

## 6. 分类汇总（严格区分「已实测否决」与「从未测过」）

### 6.1 已实测否决（有真机数据，别再试）

| 改动 | 实测结果 | 出处 |
|---|---|---|
| `YolopxEngine` → `.cpuOnly` | **548ms+**，不可用 | `YolopxEngine.swift:745` |
| `YolopxEngine` → `.cpuAndNeuralEngine` | 空载 204.6 vs 183.0ms（慢 10.6%）；8 核满载 199.1 vs 191.4ms（慢 3.9%） | `YolopxEngine.swift:712-720`（两轮 ABBA 交错复测） |
| `YolopxEngine` → `.cpuAndGpu` | 427 算子全给 GPU，97~100ms（慢一倍多），曾触发 MPSGraph 断言 SIGABRT | `YolopxEngine.swift:742-744` |
| `m9_v2_ctl` → `.all`（反向） | preferred=gpu 71.8% → 3.48ms；`.cpuOnly` → **0.57ms（快 6.1×）且零 GPU** | `InferenceEngineV2.swift:1807-1812`；本轮实测 66.5% GPU 独立印证 |
| `m9_v2_ctl` → `.cpuOnly`（现状） | 0.57ms，已最优 | 同上 |

### 6.2 与本次实测不符的旧结论（需修正认知）

| 旧结论 | 出处 | 本次实测 |
|---|---|---|
| 「`YolopxEngine` 的 `.cpuAndNE` 能消除 **19 个 GPU 算子**」 | `YolopxEngine.swift:711` 的历史注释 | **本次实测 `ayolom_n_int8` 在 `.all` 下 GPU=0**（ane=289, cpu=2）。旧注释里的「19 个 GPU 算子」在**当前模型产物**上不成立（模型可能已重新导出/int8 量化）。⚠️ 但**结论不变**：`.cpuAndNE` 更慢这条是 ABBA 实测的，仍然有效 |

> 这条差异**不影响任何决策**（无论 GPU 是不是 0，`.cpuAndNE` 都更慢），但如实记录，避免后续审计被旧数字误导。

### 6.3 从未测过（本次只读，不能给结论）

| 待测项 | 为什么必须测 | 怎么测 | 判据 |
|---|---|---|---|
| `game_assist_control` 改 `.cpuAndNeuralEngine` 的延迟 | 这是「唯一还在 `.all` 且真在跑」的模型 | ABBA 交错、模型常驻、只切档位；看 PerfBus `infer.assist` 通道 | p50 不劣于现状 2.118ms；驾驶输出 steer/throttle 无变化 |
| `m9_mono`/`m9_v2` 改 `.cpuAndNeuralEngine` | 兜底路径，平时不跑 | 需强制 V2 失败才会走到 | 同上（优先级低：不可达） |
| **Vision（`questOCR`）的 GPU 贡献** | **默认开启、不受 `computeUnits` 管** | 关/开 `AURORA_QUEST_OCR=0/1` 对比 `powermetrics` 的 GPU 驻留 | GPU 驻留差值 |
| **OCR 的 CIContext 分支（A/C/D）** | 条件开启，走 Metal | 构造「读不到速度表」场景触发 D；或用 `AURORA_OCR_CI=1` 强制 B | GPU 驻留差值 |
| 全链路「GPU 归零」是否可达 | 用户死命令的最终验收 | 依次关闭 F/E/A~D 后测设备级 GPU | GPU 驻留 → 接近待机的 0.7% |

---

## 7. 复现命令（只读，不启动 App）

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"

# 全仓 computeUnits 穷举（21 处）
grep -rn "computeUnits" --include=*.swift Sources/

# 所有模型加载点（含裸加载检查）
grep -rn "MLModel(contentsOf" --include=*.swift Sources/

# 离线设备派发探针（本报告 §3 的数据来源，不启动 App）
cat > /tmp/gpu_probe2.swift <<'EOF'
import CoreML
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"
let cfg = MLModelConfiguration()
switch mode {
case "cpuOnly":  cfg.computeUnits = .cpuOnly
case "cpuAndNE": cfg.computeUnits = .cpuAndNeuralEngine
default:         cfg.computeUnits = .all
}
let name = (url.path as NSString).lastPathComponent
let sem = DispatchSemaphore(value: 0)
Task {
    let plan = try await MLComputePlan.load(contentsOf: url, configuration: cfg)
    guard case let .program(prog) = plan.modelStructure else { print("非program"); sem.signal(); return }
    var dev: [String: Int] = [:]; var total = 0
    for op in prog.functions["main"]!.block.operations {
        total += 1
        let k: String
        switch plan.deviceUsage(for: op)?.preferred {
        case .some(.cpu): k = "cpu"
        case .some(.gpu): k = "gpu"
        case .some(.neuralEngine): k = "ane"
        default: k = "nil(const)"
        }
        dev[k, default: 0] += 1
    }
    print(String(format: "%-32s [%-10s] ops=%-5d GPU=%-4d %@",
                 (name as NSString).utf8String!, (mode as NSString).utf8String!,
                 total, dev["gpu"] ?? 0,
                 dev.sorted{ $0.value > $1.value }.map{ "\($0.key)=\($0.value)" }.joined(separator: " ")))
    sem.signal()
}
sem.wait()
EOF

# 逐个模型 × 生产档位
swift /tmp/gpu_probe2.swift models/game_assist_control.mlmodelc all
swift /tmp/gpu_probe2.swift models/m9_mono.mlmodelc all
swift /tmp/gpu_probe2.swift models/m9_v2.mlmodelc all
swift /tmp/gpu_probe2.swift models/m9_v2_enc.mlmodelc cpuAndNE
swift /tmp/gpu_probe2.swift models/m9_v2_ctl.mlmodelc cpuOnly
swift /tmp/gpu_probe2.swift models/m9_v2_ctl.mlmodelc all      # 对照组：66.5% GPU
swift /tmp/gpu_probe2.swift models/ayolom/ayolom_n_int8.mlmodelc all
swift /tmp/gpu_probe2.swift models/yolo26s.mlmodelc all
swift /tmp/gpu_probe2.swift models/tiny_arrow_v2.mlmodelc cpuAndNE
swift /tmp/gpu_probe2.swift models/ppocrv6_tiny_ft_int8.mlmodelc cpuAndNE
swift /tmp/gpu_probe2.swift models/speed_digit_cnn_v4.mlmodelc cpuAndNE
swift /tmp/gpu_probe2.swift models/world_model.mlmodelc cpuOnly
```

---

## 8. 给 Lead 的决策摘要

| 问题 | 答案 |
|---|---|
| 还有哪些模型能从 GPU 挪到 CPU/ANE？ | **CoreML 侧：0 个。** 11 个模型按其生产档位实测，GPU 优先算子全为 0 |
| `game_assist_control` 还在抢 GPU 吗？ | **不。** `.all` 下 `gpu=0`（64 算子全 ANE）。可改 `.cpuAndNE` 做防御，但**收益为 0**，且 ANE 上 int8 反量化是否劣化**未测** |
| `InferenceEngineV2.swift:1733/1881` 是重大发现吗？ | **不是。** 两处都指向 `m9_v2`，一个常态不可达、一个仅兜底可达，且实测 `.all` 下 `gpu=0`（`cpu=453`） |
| 全仓唯一「不设档位就会抢 GPU」的是谁？ | **`m9_v2_ctl`**（`.all` 下 **66.5% GPU**），而它**已经被正确设成 `.cpuOnly`** |
| 那 GPU 36.4% 从哪来？ | **不是 `computeUnits` 管辖的**：优先级从高到低 → **F `questOCR`（Vision，默认开）** > A/C/D（OCR 的 CIContext 分支，条件开）> E（默认关）。全部**未测** |
| 现在该改代码吗？ | **不建议改 `computeUnits`**（零收益 + 有劣化风险）。真正该做的是**先测 §5 的 F/A/C/D**，确认 GPU 归属后再动手 |
| 有没有必须顺手修的？ | `InferenceEngine.swift:250` / `YoloEngine.swift:227` 的 warmup 日志**硬编码** `computeUnits=all(...)`，与实际档位脱钩，会误导后续审计（纯文案，零功能影响） |

> **诚实声明**：本报告的「GPU 算子 = 0」全部来自 `MLComputePlan` 离线解析（§7 可复现），这是**静态设备派发计划**，等价于 CoreML 加载时看到的分配结果；但**未做真机 `powermetrics` 对照**（按纪律不启动 App）。若 Lead 后续能串行跑一次「只改一个模型档位 + 采 GPU 驻留」的 ABBA，即可把 §6.3 的「未测」转成实测。
