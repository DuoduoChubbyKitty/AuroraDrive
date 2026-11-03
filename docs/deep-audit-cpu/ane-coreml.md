# ANE/CoreML 推理侧深挖审计

> 审计员：ane-coreml（task-2）  
> 日期：2026-11-01  
> 方法：纯静态分析（读源码 + 读已有 docs 证据）。**未启动 App、未联网、未改任何源码或模型文件。**  
> 机器：Apple M3 / 8 核 / 16GB，macOS 14+（`tools/ane_dispatch_check.swift` 依赖 macOS 14.4+ 的 `MLComputePlan`）。  
> 结论标注口径：凡引用已有 `docs/perf-audit-gpu/` 证据的标「实测」；本审计期间**未重新跑任何探针**，新增判断标「未测（静态推断）」。

---

## 0. 一句话结论

**引擎进程 CPU 最大的单项消耗是 CoreML 内部的 ARGB→PlanarF 格式转换（占忙碌样本 28.5%，Lead sample 实测），根因是 ayolom/yolopx 系列模型用 `ImageType` 声明输入而我们喂 BGRA CVPixelBuffer——改为喂 float32 MLMultiArray 可彻底消除该转换，预估省 **~4.2% 单核上界**（Lead 更正：原写 2.8% 系用错误分母 20s 所算；按真实采样窗 13.332s，该项绝对占用 = 557/13332 = 4.18%，且 Swift 侧仍需自做归一化，实益略低）。这是本次审计发现的最高优先级优化项（§1A）。其余方面：6 处 `.all` 里 2 处不可达、1 处 A 档不加载、其余 3 处实测 GPU=0 且 ANE 占比 95.7%+，没有「漏网 GPU 抢卡」漏洞；后处理 `extractMask` 标量 O(640²) 有 SIMD4 方案（历史实测 2.42×、0 格差异）但未合入；`assistEngine` 保活心跳可尝试从 5 帧放宽到 9 帧。**

---

## 1A. ARGB→PlanarF 格式转换：28.5% CPU 大头（Lead sample 实测）

### 根因链（已闭合）

Lead 的 sample 栈采样（`/tmp/baseline_eng_sample.txt:89-101`）抓到调用链：

```
MLE5InputPort.copyFeatureValue
  → MLE5InputPortBinder.copyFeatureValue
    → MLE5BindInputBufferObjectByCopyingPixelBuffer
      → MLE5Copy32BGRA_RGBTensor_CompDtypeFLOAT_CompPackFmt32
        → vImageConvert_ARGB8888toPlanarF   ← 占 28.5% 忙碌样本
```

**为什么 CoreML 要做这个转换？** 本审计通过独立 Swift 探针（`/tmp/probe_io.swift`，只读模型文件不启动 App）确认了完整因果链：

1. **模型输入声明为 Image 类型**（`MLFeatureType(rawValue: 4)`），不是 MultiArray。探针实测全部模型：
   - `ayolom_n_int8` / `ayolom_n_fp16` / `yolopx3_pal8_detfp` / `yolo26s`：输入 `type=Image`，`imageConstraint size=(640x640)`
   - `m9_mono` / `game_assist_control` / `m9_v2_enc` / `m9_v2_ctl`：输入 `type=MultiArray`，shape `[1,3,180,320]` float32

2. **Swift 侧喂的是 BGRA CVPixelBuffer**（`YolopxEngine.swift:1012`：`MLFeatureValue(pixelBuffer: pb)`；pb 是 `kCVPixelFormatType_32BGRA`，`:1513`）。

3. **模型 MIL 程序实际期望 `tensor<fp32, [1,3,640,640]>`**（`models/ayolom/ayolom_n_int8.mlmodelc/model.mil` 第 3 行：`func main<ios17>(tensor<fp32, [1, 3, 640, 640]> image)`）。

4. **Image 类型只是一个预处理包装层**：coremltools 导出时用 `ct.ImageType(scale=1/255, bias=[0,0,0], color_layout=RGB)`（`tools/ayolom/export_ayolom_coreml.py:183-187`），CoreML 运行时把 CVPixelBuffer 的 ARGB 交错像素拆成 3 个独立平面（PlanarF）+ uint8→float32 + ×1/255 归一化，全部在 CPU 上做。

5. **对比 M9/assist 不受影响**：`InferenceEngine.preprocessImage`（`:445-512`）自己在 Swift 侧用 CGContext draw + 手写 RGBA→CHW + vDSP_vsdiv 归一化，喂 float32 MLMultiArray → 模型声明 MultiArray → **不触发 CoreML 内部转换**。

### Lead 四问逐条回答

**Q1：yolopx 模型的 inputFeatureDescription 到底期望什么格式？**

**实测**：`type=Image`（MLFeatureType rawValue=4），`imageConstraint size=(640x640)`。但 MIL 程序体里实际入口是 `tensor<fp32, [1,3,640,640]>`——Image 是 coremltools 导出时加的预处理包装（`scale=1/255, bias=[0,0,0], RGB`），把 CVPixelBuffer 的 uint8 BGRA 交错像素转成 float32 CHW 平面 + 归一化。

**Q2：如果模型绑定的是 Image(BGRA)，CoreML 不应该做转换——为什么还在转？**

**实测**：模型绑定的不是「Image(BGRA)」而是 `ImageType(color_layout=RGB)`。我们传的 CVPixelBuffer 是 `kCVPixelFormatType_32BGRA`（BGR 交错，不是 RGB 平面）。CoreML 必须做两件事：① BGRA 交错 → RGB 平面（去交错）；② uint8 → float32 + ×1/255。这两步合起来就是 `vImageConvert_ARGB8888toPlanarF`。**不是「传的类型对但还在转」，而是「传的像素格式与模型期望的色彩布局不匹配，必须转」。**

**Q3：能否改为直接喂 float16/float32 MLMultiArray（跳过 CoreML 内部转换）？**

**未测（可行但需改模型导出 + 实测精度）**。具体路径：

- **不能只改 Swift 侧**：模型声明 Image 类型输入，`MLFeatureValue(multiArray:)` 与 Image 类型不匹配，会加载/推理失败。
- **必须改导出脚本**：把 `ct.ImageType(...)` 改回 `ct.TensorType(name="image", shape=(1,3,640,640))`（导出脚本注释 `:22-23` 记录初版就是 TensorType）。代价是归一化（×1/255）要从模型图内移回 Swift 侧——与 M9/assist 的 `preprocessImage` 完全同法。
- **精度风险**：历史教训是 letterbox vImage 精度回退（9→6 框）——但那是**缩放算法**差异（采样核不同），不是格式转换。把 Image→TensorType 改的是**归一化执行位置**（从 CoreML 内部移到 Swift vDSP），数值操作完全相同（uint8→float32 + ÷255），理论上 bit-exact。但**必须实测**：ABBA 交错对比 det/da/ll 三路输出 maxdiff，确认归一化移位不引入精度差异。
- **额外收益**：去掉 Image 包装层后，MIL 程序开头的 `mul(x=image, y=1/255)` 和 `cast(fp16)` 两个算子可能从图中消失（归一化在 Swift 侧做了），这恰好是 §1 中「2 个落 CPU 的 mul/cast 算子」——**可能一并消除**。

**Q4：28.5% 如果消除，相当于引擎 CPU 降多少？（Lead 已更正）**

**实测（Lead sample，已更正）**：28.5% 是「引擎忙碌样本」内的占比。要换算成单核绝对值须用绝对采样数：该函数 **557 采样 / 13,332ms 采样窗 = 4.18% 单核**（这是上界）。原稿写的 2.8% 是 Lead 早期用错误分母（20s）算出的，**已作废**。注意：归一化搬到 Swift 后仍需 CPU 成本，故实际净收益低于 4.18%。

### 具体改法（只写方案，不改源码/模型文件）

| 步骤 | 动作 | 影响范围 |
|------|------|---------|
| 1 | 改 `tools/ayolom/export_ayolom_coreml.py:183`：`ct.ImageType(...)` → `ct.TensorType(name="image", shape=(1,3,640,640))`，删 `scale/bias/color_layout` | 导出脚本 |
| 2 | 重新导出 `ayolom_n_int8.mlmodelc`（放到 `models/ayolom/` 下，**不覆盖现役文件**，用新名如 `ayolom_n_int8_tensor.mlmodelc`） | 新模型文件 |
| 3 | `YolopxEngine.swift` 候选表 `ayolomCandidates`（`:637`）首位加新文件名 | 源码（候选表） |
| 4 | `YolopxEngine.swift` infer 路径（`:1011`）：`MLFeatureValue(pixelBuffer: pb)` → `MLFeatureValue(multiArray:)`，预处理从 `drawLetterbox`（CGContext 填 114 灰 + draw）改为 M9 同款 `preprocessImage`（CGContext draw + RGBA→CHW + vDSP ÷255） | 源码（推理路径） |
| 5 | ABBA 实测：对比 det/da/ll 三路输出 maxdiff + p50 延迟 | 验证 |

**注意**：步骤 4 需要新建一个 `drawLetterboxF32` 函数（在 letterbox 之后把 BGRA 缓冲转成 CHW float32），不能复用 M9 的 `preprocessImage`（M9 不做 letterbox 等比缩放 + 灰边，是直接拉伸）。

**风险**：中。数值操作等价（÷255），但 letterbox 灰边 114/255=0.447 在 TensorType 路径下要由 Swift 侧写入（填 0.447 而非 114），需确保与训练端 letterbox 语义一致。历史教训是缩放核差异，不是灰边值差异，但仍需实测。

---

## 1. 6 处 `.all` 逐个判定表

| # | 位置 | 模型 | 默认加载？ | 调用频率 | 已有派发实测 | 赛道结论 |
|---|------|------|-----------|---------|-------------|---------|
| 1 | `YolopxEngine.swift:746` | `ayolom_n_int8`（A 档默认主力） | **是**（`AuroraDriveApp.swift:6445` 无条件 `loadIfNeeded()`；`family` 默认 `.ayolom`，候选首位 `ayolom_n_int8.mlmodelc`） | **每帧**（`detectGateA` 对 ayolom 恒真，`:7115`；`:7592` 调 infer） | **实测**：`docs/perf-audit-gpu/2-yolopx.md` §2 — `.all` 下 289 preferred=ANE + 2 CPU(cost=0) + **0 GPU**；sample 栈采样 ANE 1731 帧 / CPU 354 / GPU 0；p50 10.42ms | **保持 `.all`，不改。** `.cpuAndNeuralEngine` 经 ABBA 实测空载 183.0 vs 204.6ms（`.all` 快 10.6%），已回退（`:710-726` 详注）。`fastPrediction` 已启用（`:755`，1.11×，bit-exact）。**赛道已封顶**。 |
| 2 | `InferenceEngine.swift:164` | `m9_mono`（旧 M9 主驾）或 `game_assist_control`（assistEngine，`:5796` 指定后者） | **assistEngine 是**：`:6435` 无条件加载。**M9 否**：`:6439` 仅 V2 失败时才加载 | assist：e2e 档每 5 帧 / `.yolo` 档每帧（`:7543`）。M9：仅 V2 不可用时每帧 | **实测**：`docs/perf-audit-gpu/1-compute-units.md:44` — `game_assist_control` `.all` 下 ane=64 / const=176 / **gpu=0**；infer.assist p50=2.118ms | **不改。** 改 `.cpuAndNeuralEngine` 收益=0（本就没上 GPU），且 int8 反量化算子（24 个 `constexpr_affine_dequantize`）在 ANE 上的派发是否劣化**未测**，按零质量红线不动（`1-compute-units.md:155`）。**可改但不值得冒风险。** |
| 3 | `InferenceEngine.swift:206` | 同上（后台兜底加载 `scheduleBackgroundLoadIfNeeded` 的副本） | 同 #2（兜底路径，仅首次未加载时触发一次） | 一次性 | 实测同 #2（同一模型文件） | **不改，理由同 #2。** 这条是后台加载副本，与 `:164` 同源同模型。 |
| 4 | `YoloEngine.swift:187` | `yolo26s`（legacy 三件套检测网） | **否**：A 档下 `:6449` 条件 `forceYolo26s \|\| perceptionMode == .legacy` 为 false → 跳过加载 | A 档：**0 次**（`:7142` detectGateB 恒 false）。legacy 档：奇数帧 | **实测**：`1-compute-units.md` 未单列 yolo26s 的 preferred 分布，但 `1-compute-units.md:294` 探针脚本已包含 `yolo26s.mlmodelc all`。**per-op 派发数据本审计未回读** → **未测** | **A 档不用动**（根本不加载）。legacy 档是否该改 `.cpuAndNeuralEngine` **未测**——yolo26s 在 `.all` 下的 GPU 派发比例无已读证据。**建议：若将来需要优化 legacy 档，先用 `tools/ane_dispatch_check.swift models/yolo26s.mlmodelc` 查 preferred 分布再定。** |
| 5 | `InferenceEngineV2.swift:1733` | `m9_v2`（单模型回退路径的 `cfg`） | **否**：该 `cfg` 只在 `:1851` 单模型分支使用，而 `:1744`（multi_split，默认关）与 `:1813`（双模型，`m9_v2_enc`+`m9_v2_ctl` 磁盘均存在）两条分支都先 `return` → **常态不可达** | 0（常态） | **实测**：`1-compute-units.md:48` — `m9_v2.mlmodelc` `.all` 下 ops=891 / **gpu=0** / cpu=453 / const=438（全落 CPU，不上 GPU 也不上 ANE） | **不用改**（不可达 + gpu=0）。即使走到也不会抢 GPU。 |
| 6 | `InferenceEngineV2.swift:1881` | `m9_v2`（后台兜底加载 `scheduleBackgroundLoadIfNeeded` 的副本） | **否**：同 #5，仅 V2 首次未加载且双模型/拆分都失败时触发一次 | 一次性 | 实测同 #5 | **不用改，理由同 #5。** |

**补充修正**：任务前提称「8 处 `.cpuOnly`」，实际 grep 结果为 **5 处生效赋值**（`InferenceEngineV2.swift:1712` 世界模型 / `:1757` tf / `:1763` chunks / `:1767` head / `:1821` ctl），另 3 处（`:200`/`:1522`/`:1699`）是注释引用而非代码。4 处 `.cpuAndNeuralEngine` 确认无误（`SpeedOCRReader:433`、`V2:1753` multi_split enc、`V2:1818` 双模型 enc、`PointerHeadingReader:290`）。

---

## 2. Top 可优化项表

按「预估收益 ÷ 风险」降序。除特别标注外，**所有项均未在本审计中实测验证**——收益与风险是基于源码结构 + 已有 docs 证据的静态推断，落地前必须各自做 ABBA 实测。

| # | 位置 | 当前状态 | 预估收益 | 质量影响 | 风险 | 回退方式 | 实测/未测 |
|---|------|---------|---------|---------|------|---------|----------|
| **0** | **ARGB→PlanarF 格式转换**（`YolopxEngine.swift:1012` 传 BGRA CVPixelBuffer；模型 `ImageType` 输入；导出脚本 `tools/ayolom/export_ayolom_coreml.py:183`） | CoreML 每帧在 CPU 上做 BGRA 交错→RGB PlanarF + uint8→float32 + ÷255，**占引擎忙碌样本 28.5%** | **省 ~4.2% 单核上界**（Lead 更正；原写 2.8% 用错分母）。绝对占用 557/13,332ms；归一化移至 Swift 后仍有成本，净收益低于此 | **理论零**（数值操作等价：÷255 移位不改精度）。**但 letterbox 灰边 114/255 须由 Swift 正确写入 CHW 缓冲，与训练端语义一致** | **中**：需改导出脚本（Image→TensorType）+ 改 Swift 推理路径（pixelBuffer→multiArray）+ 新建 letterboxF32 预处理。改的不是数值而是「归一化在哪做」。可能一并消除 §3 的 2 个 CPU mul/cast 算子 | 候选表首位改回旧模型名（一行） | **实测（Lead sample 28.5%）**；**未测**（改后精度与延迟需 ABBA） |
| 1 | `assistEngine` 保活心跳间隔（`AuroraDriveApp.swift:7543` `adaptiveFrameCounter % 5 == 0`） | e2e 档每 5 帧（=每 333ms@15Hz）跑一次 ~8ms | 省 ~16ms/s（从每秒 48ms 降到 32ms） | **零**（assist 输出在 e2e 档不被消费，仅维持 `lastResultTime`） | **中**：`isAlive` 判据是 `lastResultTime < 1.0s`（`:7638`）。15Hz 下 5 帧=333ms 安全；若放宽到 **9 帧=600ms** 仍在 1.0s 内，但余量从 667ms 缩到 400ms。**5Hz 让位态**（`EmergencyTakeover.yieldHz`）下 9 帧=1.8s → **超 1.0s 阈值 → assistLive=false → 误降 .rule**。故放宽时必须门控：仅 `mode == .e2e && effectiveTickHz >= 15` 时生效，让位态回退每帧 | 改回 `% 5`（一行） | **未测**（间隔值与让位态交互需实测） |
| 2 | `extractMask` SIMD4 向量化（`YolopxEngine.swift:1280-1490`） | **已完成（2026-11-02，task-5）**：内层「ch1 > ch0」改为 `SIMD4<Float>` 一次比较 4 像素；dtype 分派从「每像素一次」提到「每块一次」 | **本机实测（`swiftc -O`）：2.379 → 0.421 ms/次（5.65×）**，每次省 1.958ms。每帧调 2 次 → 省 **3.92ms/帧**；@15Hz = **58.7ms/s**。⚠️ 与历史 2.42× 不同：历史那次可能只向量化累加，本次整个比较链向量化 → 加速更大。按 Lead 更正的「extractMask 绝对占用 2.00% 单核」折算，实益上界 ≈ 2.00% × 82% ≈ **~1.6% 单核** | **零**（逐位等价有数学保证：Float16→Float 精确无损，NaN 语义一致；13 用例对拍 cells/ratio 完全相等） | **极低**（纯算术等价替换，dtype 分派/valid 统计/多数表决阈值全未改） | `git checkout -- Sources/AuroraDrive/Inference/YolopxEngine.swift` | **实测（本机 5.65× + 13 用例逐位一致 + release 编译通过）** |
| 3 | `InferenceEngine.swift:164`/`:206` 改 `.cpuAndNeuralEngine`（assistEngine） | `.all`，实测 gpu=0 | **0**（本就没上 GPU） | 零 | **低-中**：24 个 `constexpr_affine_dequantize` 在 `.cpuAndNeuralEngine` 下 ANE 派发策略是否变化**未测** | 改回 `.all` | **未测**（收益为 0，仅为防御性，不建议优先） |
| 4 | `YoloEngine.swift:187` legacy 档改 `.cpuAndNeuralEngine` | `.all`，yolo26s preferred 分布**未读** | 未知（需先查派发） | 未知 | 中（无派发数据） | 改回 `.all` | **未测**（A 档不加载，优先级最低） |

**未列入表（已确认无优化空间或属于必须花的钱，见 §4）**：
- `YolopxEngine:746`（ayolom）：`.cpuAndNeuralEngine` 实测更慢，已封顶。
- `V2:1733`/`:1881`（m9_v2 单模型）：不可达。
- letterbox vImage 快路径：精度回退（9→6 框），已否决，不重复提。

---

## 3. 那 2 个落 CPU 的算子（mul/cast）

**已有实测证据**（`docs/perf-audit-gpu/2-yolopx.md:132-165`）：

- `ayolom_n_int8` 在 `.all` 下 291 个计算算子中 **289 preferred=ANE、2 preferred=CPU**。
- 这 2 个 CPU 算子是 **`mul` ×1 + `cast` ×1**（`2-yolopx.md:165` 行：「`mul` 有 1 个落 CPU，cost=0」；cast 同理属形状/类型转换，cost≈0）。
- **cost=0** 意味着它们在 CoreML 的 cost 模型里权重为零——不是计算瓶颈。

**精确定位（本审计新增，基于 model.mil）**：

model.mil 第 3-5 行确认了这两个算子的身份：
```
func main<ios17>(tensor<fp32, [1, 3, 640, 640]> image) {
    image__scaled___y_0 = const(val = 0x1.010102p-8);   // = 1/255
    image__scaled__ = mul(x = image, y = image__scaled___y_0);  // ← mul：÷255 归一化
    image_to_fp16 = cast(dtype = "fp16", x = image__scaled__);  // ← cast：fp32→fp16
    conv(... x = image_to_fp16)
```

**这就是那 2 个 CPU 算子**：`mul` 是 ImageType 包装层注入的 `×1/255` 归一化，`cast` 是 `fp32→fp16` dtype 转换。它们 cost=0 是因为 CoreML 把它们与 ARGB→PlanarF 像素转换合并在一起执行（都是输入预处理的一部分）。

**与 §1A 的交叉引用**：如果执行 §1A 的 TensorType 改造（归一化移回 Swift 侧用 vDSP 做），`mul` 和 `cast` 这两个算子**可能从模型图中消失**——归一化不再由模型图内做，入口直接是 `tensor<fp16, [1,3,640,640]>`（或 `fp32`，取决于导出配置）。**未测**：改 TensorType 后 CoreML 是否仍保留一个 cast（取决于 `compute_precision=FLOAT16` 配置），需用 `ane_dispatch_check` 验证。

**单独消除（不改 TensorType）能否避免？**

| 算子 | 身份 | 能否单独避免 | 理由 |
|------|------|------------|------|
| `mul` | `×1/255` 归一化（ImageType 的 `scale=1/255` 注入） | **不能单独改** | 它是 ImageType 包装的一部分，删 `scale` 等于改导出脚本（=§1A 的 TensorType 改造） |
| `cast` | `fp32→fp16`（`compute_precision=FLOAT16` 要求） | **不能** | cast 是 CoreML 图编译器按 `compute_precision` 插入的 dtype 桥接 |

**结论**：这 2 个 CPU 算子 cost=0，单独不值得动。但它们与 §1A 的 ARGB→PlanarF 转换同源（都是 ImageType 预处理包装），**执行 §1A 改造可望一并消除**。模型内部常量/预处理/后处理的 CPU 执行分工见 §4。

---

## 4. 必须花的钱（明确说明哪些是必要成本，不要浪费时间优化）

> **⚠️ 重要更正**：ARGB→PlanarF 格式转换（28.5% CPU）**不在「必须花的钱」里**——它是 ImageType 包装的代价，可通过 §1A 改造消除。下表只列真正不可省的成本。

| 项 | 位置 | 为什么是必要成本 | 证据 |
|----|------|----------------|------|
| **`extractMask` 的 O(640²) 计算** | `YolopxEngine.swift:1280` | 这是掩码生成的**必要计算**：对 `[1,2,640,640]` 逐像素 argmax（ch1>ch0）再 4×4 多数表决下采样到 160×160。砍掉=砍车道线/可行驶区功能。sample 热点 #2（465 采样）是真实成本但不可省 | `docs/perf-audit-20261024/2-cpu-hotpath.md:93`；降级时不跑（`isInferencing` 门控，`老旧文档/优化-CPU占用审计-2026-10-11.md:107`） |
| **letterbox CGContext 路径** | `YolopxEngine.swift:1584` | vImage 快路径实测精度回退（检测框 9→6），已否决。CGContext 是精度安全的唯一路径，10.5ms/帧是必要代价 | `:1533-1575` 详注；已移出主线程到推理队列（A2 优化） |
| **NMS 逐对 IoU** | `YolopxEngine.swift:1225-1260` | YOLOX 输出未去重，必须自己做 NMS。候选数通常 ≤64（reserveCapacity），最坏 O(n²) 但 n 小。`@inline(__always)` 已加在 `iouXYXY` | 源码 `:1262` |
| **ayolom 的 `.all` 档位** | `YolopxEngine.swift:746` | `.cpuAndNeuralEngine` ABBA 实测更慢（183 vs 204.6ms），`.all` 已是最优 | `:710-726` |
| **V2 双模型 enc(ANE)+ctl(cpuOnly) 分配** | `InferenceEngineV2.swift:1817-1821` | ctl 在 `.all` 下 66.5% 派 GPU 抢卡；`.cpuOnly` 快 6.1× 且零 GPU。enc `.cpuAndNeuralEngine` gpu=0。已是最优分配 | `1-compute-units.md:107-118` |
| **`fastPrediction` specialization** | `YolopxEngine:755` / `YoloEngine:194` | 实测 1.11×，bit-exact，加载期前移 specialization。已启用 | `:755` 详注 |
| **输入缓冲复用** | `YolopxEngine:953` / `InferenceEngine:316` / `V2:2078 ensureBuffers` | CVPixelBuffer / MLMultiArray 尺寸不变时复用，**不每帧新建**。已实现 | 源码已确认（`inputBuffer == nil` 才建；V2 `ensureBuffers` 预建 7 个 reusable buffer，`makeSplitProvider` 全部传入） |
| ~~ARGB→PlanarF 格式转换~~ | ~~`YolopxEngine.swift:1012`~~ | ~~原以为是 CoreML 不可避免的内部代价~~ | **不是必须花的钱**——见 §1A，可通过 TensorType 改造消除 |

---

## 5. 未测项清单 + 下次怎么测

### 5.1 本审计明确「未测」的项

| 项 | 未测原因 | 下次怎么测 |
|----|---------|-----------|
| **§1A TensorType 改造的精度与延迟**（最高优先级） | 改导出脚本 + Swift 路径属代码变更，本次审计只做静态分析 | ① 改 `export_ayolom_coreml.py:183` Image→TensorType，导出新模型文件（不覆盖现役）；② `swift tools/ane_dispatch_check.swift <新模型>` 确认 mul/cast 是否消失 + gpu 仍=0；③ ABBA 交错对比旧/新模型 det/da/ll 三路输出 maxdiff（用 200 帧真游戏画面，与 `ayolomCandidates` 注释里的对拍方法一致）；④ 对比 p50 延迟 |
| **§1A 改造后 ARGB→PlanarF 是否真消失** | 需要在改后模型上跑 sample 才能确认 | 改造完成后 `sample <引擎PID> 6 1`，在调用树里 grep `vImageConvert_ARGB8888toPlanarF`，期望计数从 28.5% 降到 0。**注意单实例锁，须与 Lead 协调时段** |
| **`yolo26s` 在 `.all` 下的 per-op preferred 分布** | A 档不加载，优先级最低；探针脚本已包含但未回读结果 | `swift tools/ane_dispatch_check.swift models/yolo26s.mlmodelc`，读 preferred gpu 计数。若 gpu>0 则 legacy 档可考虑改 `.cpuAndNeuralEngine` |
| **assistEngine 改 `.cpuAndNeuralEngine` 后 p50 是否劣化** | 收益=0（gpu 本就=0），不值得优先测 | ABBA 交错（`tools/yolopx/bench_protocol.py` LoadController 模式），min-of-60，对比 `.all` vs `.cpuAndNE` 的 infer.assist p50。重点看 24 个 `constexpr_affine_dequantize` 是否被重新派发 |
| **assistEngine 保活心跳放宽到 9 帧的安全性** | 需要在真实 5Hz 让位态下验证 `lastResultTime` 不超 1.0s | App 内实测：设 `AURORA_ASSIST_KEEPALIVE` 自定义间隔（需加代码门控 `effectiveTickHz >= 15`），在 EmergencyTakeover 让位态下观察 `assistLive` 是否保持 true。**注意单实例锁，须与 Lead 协调时段** |
| ~~`extractMask` SIMD4 方案为何未合入主路径~~ | **已查清并已实现（task-5）**：git log 全库无任何 SIMD 提交，`git blame` 显示该函数一直来自 c3e1dd37；真实原因见 `性能实测-2026-09-30-卡顿与定位.md` §2.5「实测有效但未采用」——「仅占 prediction 的 3.3%，收益小」，是**优先级判断**而非精度/ABI 问题。已实现 + 13 用例逐位对拍通过 | —（已闭环） |
| **`m9_mono`（旧 M9）的 preferred 分布** | V2 正常时 M9 不推理，但 V2 失败时会兜底。`1-compute-units.md:289` 探针已包含未回读 | `swift tools/ane_dispatch_check.swift models/m9_mono.mlmodelc` |

### 5.2 ANE 利用率的可测手段

**MLComputePlan（macOS 14.4+）——可用，且工具已在仓库内**：

```
tools/ane_dispatch_check.swift
```

该脚本已实现：
1. `MLComputePlan.load(contentsOf:configuration:)` 离线解析 `.mlmodelc`，枚举每个 op 的 `preferred` / `supported` 设备 + cost。
2. min-of-60 延迟测量。
3. **不启动 App、不跑生产代码、只读模型文件**。

`docs/perf-audit-gpu/1-compute-units.md` 已用它测过 8 个模型（ayolom_n_int8 / m9_v2 / m9_v2_enc / m9_v2_ctl / game_assist_control / yolo26s / m9_mono / world_model），覆盖了全部 6 处 `.all` 对应的模型。**结论：工具可用，数据已有，无需重新发明。**

未覆盖的：`yolo26s` 与 `m9_mono` 的 preferred 分布在文档里未展开（探针脚本包含但结果未回读）。下次补这两条即可全闭合。

**coremltools——未安装，离线安装建议**：

```
# 真实退出码已验证：ModuleNotFoundError，exit code=1
# Python 解释器：/opt/homebrew/opt/python@3.14/bin/python3.14 (3.14.6)，无 venv
pip3 install coremltools
```

安装后可用其 `coremltools.models.neural_network.utils` 的 `supported_compute_devices` 做 per-op 级 GPU/ANE/CPU 支持性查询（与 MLComputePlan 互补：coremltools 看「支持什么设备」，MLComputePlan 看「实际选了什么设备」）。

**注意**：`2-yolopx.md:8-10` 记录 coremltools 的 `predict()` 对 1ms 级小模型完全失真（numpy→MLMultiArray 转换主导），**判 ANE 派发必须用 Swift 的 MLComputePlan，不能用 coremltools 跑推理计时**。coremltools 仅用于离线查 supported_compute_devices。

### 5.3 预处理链路总结（每帧成本分工）

| 阶段 | 位置 | 每帧次数 | 分辨率 | 在哪跑 | 能否改 ANE 友好格式 |
|------|------|---------|--------|--------|-------------------|
| letterbox（等比缩放+114灰边） | `YolopxEngine:1584` CGContext | 1 | 源帧→640×640 | 推理队列（后台） | **不能**。vImage 快路径实测精度回退（9→6 框），已否决。640×640 是模型训练口径，不可改 |
| M9/V2 预处理 | `InferenceEngine.preprocessImage` / `V2.preprocessImage` | 1 | 源帧→180×320 | 推理队列 | **未测**。180×320 是模型输入契约，改格式=改模型 |
| 颜色转换/memcpy | `YoloEngine` 直通路径（CaptureEngine GPU 缩放产出） | 1（legacy 档） | 640×640 | 主线程 memcpy 进 `yoloInputBuffer` | A 档不走此路径（yolo26s 不加载） |

### 5.4 后处理总结

| 阶段 | 位置 | 实现 | 向量化空间 |
|------|------|------|-----------|
| det 解码 | `parseDetections:1141` | `fastRowsStrided` 整块拷贝 + 标量循环解码 8400 框 | 已优化（整块拷代替逐下标读）。候选过滤后通常 ≤64，循环量小 |
| NMS | `:1225-1260` | 标量逐对 IoU + suppressed 数组 | n 小（≤64），O(n²) 可接受。`@inline(__always)` 已加 |
| mask 提取 | `extractMask:1280-1490` | ~~标量逐像素~~ **已向量化**：SIMD4<Float> 一次比 4 像素，每帧 2 次 | **已完成**：本机实测 5.65×（2.379→0.421ms/次），13 用例逐位一致。见 §2 #2 |
| sigmoid/阈值 | 无独立 sigmoid（YOLOX 输出已是 obj_conf×cls_conf，`:1135` 注释）；阈值在 `parseDetections` 内联 | 内联在解码循环 | 无独立优化点 |

### 5.5 模型加载与常驻内存

| 模型 | A 档加载？ | 常驻内存 | 是否被消费 |
|------|-----------|---------|-----------|
| `ayolom_n_int8` | 是 | 3.8MB | 每帧 infer，det/da/ll 全消费 |
| `game_assist_control`（assistEngine） | 是 | 7.6MB | e2e 档保活心跳（输出不消费，仅维持 isAlive）；.yolo 档每帧消费 |
| `m9_v2_enc` + `m9_v2_ctl`（V2 双模型） | 是 | 2.6+6.5=9.1MB | 每帧 infer，steer/throttle/brake 全消费 |
| `m9_mono`（旧 M9） | **否**（V2 正常时不加载） | 0 | — |
| `yolo26s` | **否**（A 档跳过） | 0 | — |
| `world_model` | **否**（`worldModelEnabled` 默认 false，推理调用全注释） | 0 | — |

**结论**：A 档下没有「加载了却不用」的模型。`world_model` 的加载已在 2026-10-22 关闭（`V2:1687` 默认 false），`m9_mono` 已改为 V2 失败时才加载（`:6439`），`yolo26s` 已按档位门控（`:6449`）。**这一层已经清理干净。**

### 5.6 推理频率门控总结

| 模型 | 频率 | 可缓存复用？ | 门控是否合理 |
|------|------|------------|------------|
| ayolom | 每帧（15Hz） | 不能（每帧画面不同） | 合理（p50 10.42ms，占 15Hz 预算 15.6%，跑不满无需降频） |
| V2 双模型 | 每帧（15Hz） | 不能（主驾，每帧出控制量） | 合理（R1 红线：每帧出结果） |
| assistEngine | e2e：每 5 帧 / .yolo：每帧 | 输出在 e2e 不消费，仅保活 | **e2e 档可尝试放宽到 9 帧**（见 §2 #1），但须门控让位态 |
| extractMask | 每次 yolopx 推理后 2 次 | 不能（每帧掩码不同） | 合理（降级时不跑，已门控） |

---

## 附录：审计边界声明

1. **本审计未启动 App**（单实例锁约束）。
2. **本审计未联网**（禁 web_search/web_fetch/curl）。
3. **本审计未修改任何源码或模型文件**（`git status --porcelain` 确认仅 `docs/deep-audit-cpu/` 为新增目录，无源码/模型文件变更）。
4. **本审计未创建/覆盖任何窗口**。
5. 「实测」标记来源：① Lead 的 sample 栈采样（ARGB→PlanarF 28.5%）；② `docs/perf-audit-gpu/` 与 `docs/perf-audit-20261024/` 已有证据；③ 本审计用独立 Swift 探针 `/tmp/probe_io.swift` 读模型 input/output description（只读模型文件，不启动 App、不跑推理）。
6. 所有「未测」标记均如实标注，未编造 per-op 派发数据或耗时。
7. 唯一可写文件：`docs/deep-audit-cpu/ane-coreml.md`（本文件）。`/tmp/probe_io.swift` 是临时探针，不写入项目目录。

### 本审计新增的探针

| 探针 | 路径 | 用途 | 是否启动 App |
|------|------|------|------------|
| `probe_io.swift` | `/tmp/probe_io.swift` | 读 `.mlmodelc` 的 `modelDescription`，枚举每个输入/输出的 type（Image/MultiArray）+ shape + dataType | 否（只 `MLModel(contentsOf:)` 读描述，不跑 prediction） |

该探针确认的关键事实：ayolom/yolopx/yolo26s 输入是 `Image` 类型，M9/assist/V2 是 `MultiArray` 类型——这是 ARGB→PlanarF 转换只发生在 yolopx 系列的根因。
