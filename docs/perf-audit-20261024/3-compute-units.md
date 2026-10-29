# 3 · CoreML 计算设备（ANE / GPU / CPU）全量审计

> 审计日期：2026-10-24
> 审计范围：`Sources/AuroraDrive/` 全部 `MLModelConfiguration` 站点 + `models/*.mlmodelc`
> 纪律：**只读**。未改任何代码、未 build、未启动 App。本文件内所有「实测」均引自仓库内既有记录并标注出处；本次审计**未做任何新的真机测量**。

---

## 1. 一句话结论

**用户的「把小模型挪到 CPU」想法：部分成立 —— 方向对，但落点错了。**

- ✅ **成立的部分**：项目里**确实有一个模型从来没设过 `computeUnits`**（`SpeedOCRReader.loadOneModel`），走 CoreML 默认 `.all`，是全仓唯一的**未受控档位**。给它补上显式档位（`.cpuAndNeuralEngine`，理由见 §4）是**零质量影响 / 极小质量的纯收益**。
- ❌ **不成立的部分**：用户点名的理由「速度表 OCR 一秒才更新几次」**与代码不符**。OCR 实测节流是 **15Hz**（`SpeedOCRReader.swift:93` `inferInterval = 1.0/15.0`，`:541-544` 是闸门），等于**每个 tick 都跑一次**，不是「一秒几次」。它是**高频**调用，不是低频。
- ⚠️ **重要补充**：用户想省的「游戏 GPU 争用」，对**主驾驶模型族**（YOLO / YOLOPX / M9）**已经不成立** —— 项目 2026-10-10/11 的核算审计实测这 6 个组件的 **GPU 算子数 = 0**（`性能-推理GPU占用审计-2026-10-11.md:193`）。真正还在「可能上 GPU」的，恰恰是**从没被那轮审计覆盖过的 OCR 双模型**。

> 另有 1 处**代码注释与实现不符**（`:541` 写「5Hz / 200ms」，实际 15Hz），见 §6。

---

## 2. 全模型表

### 2.1 生产在跑 / 会被加载的模型

| 模型 | 大小 | 调用频率（证据） | 当前 computeUnits | 建议 | 预期收益 | 风险 |
|---|---|---|---|---|---|---|
| `ppocrv6_tiny_ft_int8`（速度表 OCR 主路径） | 1.2M | **15Hz**（`SpeedOCRReader.swift:93` + `:541-544` 闸门；调用点 `AuroraDriveApp.swift:7321`，tick 基准 15Hz 见 `EngineMain.swift:710`） | **未设置 → 默认 `.all`**（`SpeedOCRReader.swift:414`） | **`config.computeUnits = .cpuAndNeuralEngine`**（不是 `.cpuOnly`，见 §3.1） | 未测，需 A/B。收益不在「省算力」，而在**把可能的 GPU 提交移出 GPU 队列**，减少与游戏的队列争用 | 极小：同算子集，ANE/CPU 均非降精度路径；p50 预计变化在 ±20% 内，需实测 |
| `speed_digit_cnn_v4`（OCR 备用路径） | 2.3M | **降级时才跑**（`SpeedOCRReader.swift:579-583` 仅在 PP-OCR 运行时故障时同帧补跑）；正常工况 **0Hz** | **未设置 → 默认 `.all`**（`SpeedOCRReader.swift:414`，与上同一函数） | 同上，随 `loadOneModel` 一起改 | 正常工况无收益；**故障降级时**才有意义（那时 CPU 化反而更稳） | 极小。备用路径本就是兜底，必须保证它一定能跑 |
| `ayolom_n_int8`（A-YOLOM，**默认档三合一**） | 3.8M | **15Hz，每 tick 恒跑**（`AuroraDriveApp.swift:7091` `detectGateA` 对 ayolom 恒真 → `:7541` `yolopxEngine.infer`） | `.all`（`YolopxEngine.swift:746`） | **不动**（见 §4） | — | 动它会踩已实测否决清单 |
| `yolopx3_pal8_detfp`（legacy 档三合一） | 32M | **7.5Hz**（legacy 档偶数帧：`:7091` `parityEven` → 15Hz÷2） | `.all`（`YolopxEngine.swift:746`，与上同一配置对象） | **绝对不动** | — | 已实测：`.cpuOnly` 548ms+、`.cpuAndNE` 慢 3.9~10.6% |
| `yolo26s`（检测网） | 9.4M | **7.5Hz**（legacy 档奇数帧：`AuroraDriveApp.swift:7118` `detectGateB` → `:7216` `inferFast`） | `.all`（`YoloEngine.swift:187`） | **不动**。仅 legacy 档加载，ayolom 档 `unload()`（`:517/:528`，省 9.2MB 常驻） | — | 已实测 fastPrediction 后 p50 8.90ms，改档位无收益 |
| `m9_v2_enc`（V2 双模型编码器） | 2.6M | **15Hz**（每 tick，`AuroraDriveApp.swift:7455` `inferenceEngineV2.infer`） | `.cpuAndNeuralEngine`（`InferenceEngineV2.swift:1818`） | **已最优，不动** | — | ANE 上 0.34ms，改 CPU 只会更慢 |
| `m9_v2_ctl`（V2 双模型控制头） | 6.5M | **15Hz**（同上） | `.cpuOnly`（`InferenceEngineV2.swift:1821`） | **已最优，不动** | — | 已实测：`.all` 下 71.8% preferred=GPU → 3.48ms；`.cpuOnly` → **0.57ms（快 6.1×）且零 GPU**（`:1807-1812`） |
| `m9_mono`（V2 冷启动回退主驾） | 15M | **仅 V2 不可用时**（`AuroraDriveApp.swift:7462` 的 else 分支） | `.all`（`InferenceEngine.swift:164/206`） | **不动** | — | 已实测 ANE 编译失败→落 CPU（`性能-推理GPU占用审计-2026-10-11.md:161-172`），改档位无收益 |
| `game_assist_control`（第二司机） | 7.6M | **3Hz**（e2e 档每 5 帧，`AuroraDriveApp.swift:7492`）；.yolo 档 15Hz | `.all`（`InferenceEngine.swift:164/206`，与 m9_mono 同一加载函数 `loadIfNeeded`/`scheduleBackgroundLoadIfNeeded`） | **候选：可考虑 CPU 化**，但需实测（见 §5-②） | 未测。3Hz 属低频，理论上 CPU 化代价小 | **中等**：`.yolo` 档它是真司机（15Hz 每帧），改档位会污染驾驶行为，必须按档位分别测，不能一刀切 |
| `tiny_arrow_v2`（指针朝向） | 44K | **5Hz**（`AuroraDriveApp.swift:7394` `% 3 == 0`，15Hz÷3） | `.cpuAndNeuralEngine`（`PointerHeadingReader.swift:290`） | **已最优，不动** | — | 已是最好的档位（12k 参数、64×64 输入，ANE 首选） |
| `world_model` | 1.3M | **0Hz —— 永不推理**（`InferenceEngineV2.swift:1704-1712` 记录：三处调用点全被注释；且默认已不加载，`:1711` `Self.worldModelEnabled` 默认 false） | `.cpuOnly`（`InferenceEngineV2.swift:1712`） | **不用管**（默认不加载） | 已经零收益地关掉了 | 无 |

### 2.2 磁盘上存在但不被生产代码加载

| 模型 | 大小 | 说明 |
|---|---|---|
| `pointer_heading` | 2.7M | 全仓 Swift 源码**零引用**（`grep -rn "pointer_heading" Sources/` 仅命中无）。现役是 `tiny_arrow_v2`（`PointerHeadingReader.swift:273` `init(modelFileName: String = "tiny_arrow_v2")`） |
| `speed_digit_cnn`（旧版，无 `_v4`） | 316K | 零引用。现役是 `speed_digit_cnn_v4`（`:337-338`） |
| `exp_*` 系列（42 个，共约 400MB+） | 4.2M~32M | 实验产物，`grep -rn "exp_exec\|exp_quant\|exp_enc" Sources/` **零引用**。不参与运行时，不影响帧率；但占了磁盘 |
| `_backup_*`（3 个） | 44K~11M | 回滚备份，零引用 |

> 这些不产生任何 GPU/CPU 成本，**与用户的问题无关**，列出仅为说明「不是所有 .mlmodelc 都在跑」。

---

## 3. 建议立刻改（≤3 条）

### ① 【唯一强烈建议】给 `SpeedOCRReader.loadOneModel` 补显式 computeUnits

**改哪一行**：`Sources/AuroraDrive/Inference/SpeedOCRReader.swift:405-420`（`loadOneModel`），在第 414 行 `return try MLModel(contentsOf: loadURL)` 之前构造配置：

```swift
// 现状（:406-420）
private static func loadOneModel(candidates: [String]) -> MLModel? {
    for path in candidates {
        ...
        return try MLModel(contentsOf: loadURL)      // ← 默认 .all，含 GPU 子系统
```

```swift
// 建议
private static func loadOneModel(candidates: [String]) -> MLModel? {
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine        // 显式排除 GPU
    for path in candidates {
        ...
        return try MLModel(contentsOf: loadURL, configuration: config)
```

**为什么是 `.cpuAndNeuralEngine` 而不是用户说的 `.cpuOnly`**：
- 这两个模型都极小（1.2M / 2.3M），且都是**卷积为主**的视觉模型 —— 正是 ANE 最擅长的形状。强制 `.cpuOnly` 会**主动放弃 ANE**，在 15Hz 下把 1.2M 模型的计算全压到 CPU，反而是拿 CPU 换 GPU，方向错了。
- `.cpuAndNeuralEngine` 的语义是 **CPU + ANE，明确不含 GPU**（Apple 官方定义：allow the model to use both the CPU and neural engine, but not the GPU，`macOS 13.0+`）。这才是「显式排除 GPU」的正确档位，也和项目里 `PointerHeadingReader.swift:290`、`InferenceEngineV2.swift:1818` 的既有纪律**完全一致**。
- 真正的目标不是「省算力」（1.2M × 15Hz 本来就没多少），而是**消除一个未受控的 GPU 提交源**。这符合用户「反正抢性能是必须的，但不要白抢」的哲学。

**质量影响**：**零**（严格说「极小」）。同精度、同算子、同权重，只换执行设备。CoreML 跨设备执行同一张图，输出差异在 float16/float32 舍入量级，不改变任何解码结果（该模型输出要过 CTC 解码 + 置信度门槛 0.30（`SpeedOCRReader.swift:1125` 的 `guard conf >= ppocrMinConfidence`，常量定义在 `:148`），舍入噪声远小于门槛）。**如需绝对保证，用 §5-① 的 A/B 协议验证「速度读数逐帧一致」。**

**如何 A/B 验证**（可执行，且不动生产代码）：

1. **先测「它到底上不上 GPU」—— 这是决定要不要改的前提，且必须最先做。** 仓库里已有现成工具：
   ```bash
   swift tools/ane_dispatch_check.swift models/ppocrv6_tiny_ft_int8.mlmodelc
   swift tools/ane_dispatch_check.swift models/speed_digit_cnn_v4.mlmodelc
   ```
   看输出的 `preferred 设备派发` 里 **gpu 占比**。
   - 若 **gpu = 0**（和 10-11 审计里那 6 个组件一样）→ **收益为零，本条降级为「一致性整改 + 防御未来」**，不要为了性能改。
   - 若 **gpu > 0** → 本次改动有实际收益，继续第 2 步。
   > 注意：`ane_dispatch_check.swift:23` 写死了 `cfg.computeUnits = .all`，所以它测的**正是生产现状**，无需修改即可用。

2. **延迟 A/B**（同一工具已内建 min-of-60）：
   ```bash
   swift tools/ane_dispatch_check.swift models/ppocrv6_tiny_ft_int8.mlmodelc
   ```
   记录 p50/p95。改完后重跑同一条命令（工具固定 `.all`，故需临时把 `:23` 改成 `.cpuAndNeuralEngine` 再跑一次，或复制一份工具改档位）。**判据：改后 p50 不得 > 改前 p50 的 1.5×**（15Hz 下 p50 若从 2ms 涨到 3ms，每秒多耗 15ms，仍可接受；若从 2ms 涨到 10ms 则否决）。

3. **端到端一致性回归**（改完必做）：
   ```bash
   ./run.sh --ocr-selftest     # 若该自检入口存在，见 SpeedOCRReader.selfTestDirectory:1498
   ```
   对比改前/改后：自检报告里的**识别准确率数字必须逐位相同**。若仓库无此自检 CLI 入口，则用 App 内读数对比：驾驶中同一路段，改前/改后各跑 3 分钟，比较 `[DBG] raw= conf=` 日志（由 `AuroraFlags.ocrDebug` 控制，输出在 `SpeedOCRReader.swift:1130-1131`）的置信度分布。

---

### ② 【可选，需先测】`game_assist_control` 在 e2e 档下的 CPU 化

**不推荐现在改。** 理由：它在 `.yolo` 档是**真司机**（15Hz 每帧，`AuroraDriveApp.swift:7492`），改档位会改变驾驶输出。只有在 e2e 档的 3Hz 保活路径上才有「低频」属性，而这需要**按档位分裂出两套配置**，属于扩大改动面。列入 §5 待测。

---

### ③ 【附带修复】`:541` 的过时注释

`SpeedOCRReader.swift:541` 写「闸 1：5Hz 时间节流（200ms 内不入队新推理）」，但 `:93` 实际是 `1.0/15.0`（15Hz / 66.7ms）。**注释与代码不符**，正是本次审计差点被误导的地方（用户的「一秒几次」印象很可能就来自这类过时注释）。

**改法**：把 `:541` 改为「闸 1：15Hz 时间节流（66.7ms 内不入队新推理）」。**纯注释，零功能影响。** 建议顺手在 `:92`「多帧确认 confirmCount=3 在 15Hz 下窗口 200ms」处保持原样（那句是对的）。

> 这是「文档纪律」问题，不是性能问题，但既然已发现就一并记下。

---

## 4. 绝对不要动（引用项目内已实测的否决记录）

### 4.1 `YolopxEngine` 的 `.all` —— 有完整的两轮 ABBA 交错实测否决书

`Sources/AuroraDrive/Inference/YolopxEngine.swift:705-746` 是一份**教科书级的实测否决记录**，原文要点：

- **`.cpuAndNeuralEngine` 更慢**（当初的假设被证伪）：
  | 场景 | `.all` | `.cpuAndNeuralEngine` | 胜者 |
  |---|---|---|---|
  | 空载 | 183.0 ms | 204.6 ms | `.all` 快 10.6% |
  | 8 核满载 | 191.4 ms | 199.1 ms | `.all` 快 3.9% |
  且**负载下差距收窄而非扩大**，与「负载越高收益越大」的预期正好相反。

- **真瓶颈不在档位**：`sample` 采样 258 个 `ExecuteStreamSync` 样本中，**62.8% 是 `BnnsCpuInferenceOperation`（CPU 后端）**、仅 37.2% 是 ANE。而 `BnnsCpuInferenceOperation` 由 CoreML 内部调度决定，**不受 `computeUnits` 控制**（`:732-733`）。⟹ `.all` 已经是「让它自己挑最优」的结果，人工指定反而更差。

- **`.cpuAndGpu` 更慢**：427 个算子全给 GPU，97~100ms（**慢一倍多**），且文档记录曾触发 MPSGraph 断言 SIGABRT（`:743-744`）。

- **`.cpuOnly` 更慢**：548ms+（`:745`）。

- **还想从图结构上消 CPU 算子的两条路也都实测失败**（`:735-740`）：那 16 个 CPU 算子是 PSA 模块的 `softmax`/`reduce_sum`，其 `supported_compute_devices` **只含 CPU/GPU，ANE 不存在**（硬件能力限制）。拆分 → CPU 10→21；matmul 折叠 → CPU 10→24。**越改越差。**

> 结论：**对 `YolopxEngine` 任何档位改动都是退步**。这条已被两轮独立复测 + `sample` 采样 + 图结构实验三重证伪，不要以任何理由推翻。

### 4.2 V2 双模型已是最优分配，不要「统一成 .all」或「统一成 cpuOnly」

- `enc → .cpuAndNeuralEngine`（ANE，0.34ms）
- `ctl → .cpuOnly`（**`.all` 下 71.8% preferred=GPU → 3.48ms；`.cpuOnly` → 0.57ms，快 6.1× 且零 GPU**，`InferenceEngineV2.swift:1807-1812`）

这是**按模型分配**的范本：同样在 V2 内部，enc 适合 ANE、ctl 适合 CPU。**一刀切「全部挪 CPU」或「全部留 .all」都会变差。** 用户的想法要成立，必须落到**逐个模型判断**，不能整体搬。

### 4.3 `tiny_arrow_v2` 的 `.cpuAndNeuralEngine` —— 已是最优档

44K 模型、64×64 输入、12k 参数（`PointerHeadingReader.swift:286-290`）。ANE 是首选，且已显式排除 GPU。**没有改进空间。**

> ⚠️ 一处**必须澄清的数字**：`PointerHeadingReader.swift:76-79` 自己写明「单帧 p50 **0.087ms 是 CPU_ONLY 口径**（早期测量）。当前实际配置是 `.cpuAndNeuralEngine` —— **ANE 口径未单独测量**，不得把这个数当成当前配置的实测值」。本报告不引用 0.087ms 作为当前配置性能。

### 4.4 `yolo26s` —— 不要动

9.4M，已开 `fastPrediction`（实测 p50 9.98 → 8.90ms，1.12×，输出 bit-exact，`YoloEngine.swift:188-190`）。且 ayolom 档下整个模型 `unload()` 卸载（`:517/:528`，省 9.2MB 常驻）—— **已经是「不需要就不占」的状态**。

---

## 5. 未测清单（必须真机 A/B 才能定，本报告不给结论）

| # | 待测项 | 为什么必须测 | 怎么测（可执行） | 判据 |
|---|---|---|---|---|
| ① | **`ppocrv6_tiny_ft_int8` / `speed_digit_cnn_v4` 在 `.all` 下到底有没有 GPU 算子** | 这是 §3-① 是否值得改的**唯一前提**。仓库 10-11 那轮 GPU 审计只测了 6 个组件（enc/ctl/yolo26s/旧M9/world_model），**OCR 双模型从未被覆盖**（`性能-推理GPU占用审计-2026-10-11.md:150-193` 的清单里没有它们）。**不能假设，必须测。** | `swift tools/ane_dispatch_check.swift models/ppocrv6_tiny_ft_int8.mlmodelc`（现成工具，`:23` 固定 `.all` = 生产现状） | 输出 `preferred 设备派发` 中 gpu 计数。**=0 → 不改；>0 → 改** |
| ② | **OCR 单次推理的真实耗时（p50/p95）** | 报告里所有「15Hz × Xms = Y% 单核」都是**假设**，项目内**无任何 OCR 推理耗时打点**。`tick.nativeROI`（`AuroraDriveApp.swift:7327`）只量**主线程提交那一段**，真正的推理在 `ocrQueue` 异步跑（`SpeedOCRReader.swift:562`）→ **现有埋点测不到它** | 同上工具已内建 min-of-60 延迟测量；或用 `sample <pid>` 抓 `ocrQueue` 栈 | p50。**若 p50 ≤ 3ms → 15Hz 下仅占 4.5% 单核，不值得为它做任何 GPU 侧改动；若 > 8ms → 值得优化（但优化方向是模型而非档位）** |
| ③ | **OCR 改 `.cpuAndNeuralEngine` 后，读数是否逐帧等价** | 质量红线。虽然理论零影响，但用户铁律要求「零质量影响」，必须验 | 见 §3-① 第 3 步（自检 / 日志置信度分布对比） | 识别准确率逐位相同，或置信度分布无统计偏移 |
| ④ | **`game_assist_control` 在 e2e 档（3Hz）CPU 化的收益** | §3-② 的必要前提。3Hz 理论上代价很小，但 `.yolo` 档 15Hz 是真司机，必须**按档位分别测** | 需按档位拆配置后，用 PerfBus 的 `infer.assist` 通道（`InferenceEngine.swift:126-130` 已按模型名分通道）对比 | GPU 提交消失 + 驾驶输出（steer/throttle）无变化 |
| ⑤ | **游戏侧的实际影响（真正的验收标准）** | 用户的目标是「游戏不掉帧」，不是「CoreML 更快」。推理耗时变化 ≠ 游戏体验变化，中间的因果链（GPU 队列争用）未被量化 | 需在真游戏 + 真抓屏下，用 `--tick-bench`（`AuroraDriveApp.swift:1162`）或帧率日志做改前/改后对比 | 游戏帧率/帧时间分布有可测改善，且无人眼可见的卡顿回归 |

> **诚实声明**：本审计**未运行任何测量**（只读纪律）。上表中 ① 是**唯一能决定 §3-① 是否该做**的测量，且用现成工具 1 分钟就能出结果 —— **建议 Lead 优先把它跑掉，再决定要不要动代码**。

---

## 6. 审计中顺带发现的问题（非性能，但影响判断）

1. **`:541` 注释过时**：「5Hz 时间节流（200ms）」实际是 15Hz（`:93` 为 `1.0/15.0`）。已列入 §3-③。
2. **`SpeedOCRReader` 是全仓唯一「裸 `MLModel(contentsOf:)`」的模型加载点**：`grep -n "computeUnits\|MLModelConfiguration" Sources/AuroraDrive/Inference/SpeedOCRReader.swift` 返回**空**。其余 7 处 `.all`、8 处 `.cpuOnly`、3 处 `.cpuAndNeuralEngine` 都有显式档位。这不是「配置错了」，是**从未被配置过** —— 属于审计遗漏，不是 bug。
3. **`QuestPanelReader` 不用 CoreML**：它走 Vision `VNRecognizeTextRequest`（`QuestPanelReader.swift:80` `import Vision`），不在本审计范围，也不会占用 CoreML 计算单元。但它**确实用 Vision/GPU 子系统**，若用户继续追问「还有谁在抢 GPU」，这是下一个排查目标。
4. **历史文档有缺口**：`docs/整合文档/05-性能与优化全史.md:195-211` 与 `性能-GPU约束与CPU化-2026-10-13.md:20-32` 两份文档都有「各推理引擎 computeUnits 现状」全表，**但两张表都漏了 `SpeedOCRReader`**。本次审计确认：它是真实存在的第 8 个 CoreML 加载点，且是唯一未设档位的。

---

## 7. 给 Lead 的决策摘要

| 问题 | 答案 |
|---|---|
| 用户「挪到 CPU」想法成立吗？ | **部分成立**：方向（消除未受控的 GPU 来源）对，但**落点**是「给 OCR 补 `.cpuAndNeuralEngine`」，**不是 `.cpuOnly`**；且用户的前提「OCR 一秒才几次」**错误，实际 15Hz 每 tick 都跑** |
| 该立刻改几条？ | **1 条实质改动**（§3-①）+ 1 条注释修复（§3-③） |
| 改之前必须先做什么？ | 跑 `swift tools/ane_dispatch_check.swift models/ppocrv6_tiny_ft_int8.mlmodelc`，确认 GPU 算子占比 > 0。**=0 就不要改**，收益为零 |
| 哪些绝对别碰？ | `YolopxEngine.swift:746`（三重实测否决）、V2 已分配的 enc/ctl、`tiny_arrow_v2`、`yolo26s` |
| 最大的认知纠正 | 「模型推理抢游戏 GPU」对**主驾驶模型族已不成立**（GPU 算子 = 0，10-11 实测）。真正没查过的是 OCR 双模型 + `CIContext`/Vision 预处理层 |

---

## 附：CoreML `computeUnits` 权威语义（供核对）

| 档位 | 含义 | 是否含 GPU |
|---|---|---|
| `.all`（**默认值**） | 允许使用全部计算单元（ANE / GPU / CPU），由 CoreML 按算子 `supported_compute_devices` 自行调度 | **是** |
| `.cpuOnly` | 仅 CPU | 否 |
| `.cpuAndGPU` | CPU + GPU，不含 ANE | 是 |
| `.cpuAndNeuralEngine` | CPU + ANE，**不含 GPU**（macOS 13.0+） | **否** |

- Apple 官方对 `.cpuOnly` 的说明：「Use `MLComputeUnits.cpuOnly` to restrict the model to the CPU, **if your app might run in the background or runs other GPU intensive tasks**」—— 这与本项目「不抢游戏 GPU」的诉求**同源**，佐证用户的方向感是对的。
- `MLModelConfiguration` 未显式赋值时 `computeUnits` 即为 `.all`。coremltools 文档亦确认 `ComputeUnit.ALL` 是默认设置。
- 来源：
  - [MLComputeUnits | Apple Developer Documentation](https://developer.apple.com/documentation/coreml/mlcomputeunits)
  - [MLComputeUnits.cpuAndNeuralEngine](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine)
  - [MLModelConfiguration](https://developer.apple.com/documentation/coreml/mlmodelconfiguration)
  - [Load and Convert Model Workflow — Core ML Tools](https://apple.github.io/coremltools/docs-guides/source/load-and-convert-model.html)
  - [Optimize your Core ML usage - WWDC22](https://developer.apple.com/videos/play/wwdc2022/10027/)

> ⚠️ `.all` 是默认值这一点很关键：**「没设 computeUnits」不等于「安全」，等于「交给 CoreML 自由调度，可能上 GPU」**。这正是 `SpeedOCRReader` 的问题所在。
