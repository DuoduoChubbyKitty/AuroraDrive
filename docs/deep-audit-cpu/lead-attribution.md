# Lead 实测归因：引擎与 UI 两进程的 CPU 到底花在哪

> 2026-11-01，基于 baseline sample（驾驶态）+ AuroraEngine.log（2631 条 PERF 分段）
> 方法：sample 每毫秒对**所有**线程各采一次 → 必须剔除「线程在等待」的样本（`__workq_kernreturn` 等），只统计真正在执行的。
>
> ⚠️ **分母更正**：sample 的真实采样窗口是 **13.332 秒**（引擎 pid 93564，线程头计数 13332）/ **12.953 秒**（UI pid 93544，计数 12953），不是此前误写的 20 秒。本文所有「折合单核」已按正确分母重算。

---

## 1. 一句话结论

**引擎进程 99.3% 的采样是线程在等待，真正在跑的只占 0.72%（1957/270809）。按正确分母（13.332 秒采样窗口）折算，引擎实际 CPU 为 14.7% 单核（本文口径，下界）～18.8% 单核（codex 的 call-graph 叶子自采样口径，上界）；ps 快照读数 11.7% 落在此区间附近（ps 的 %cpu 是进程生命期衰减均值，非该窗口瞬时值）。在这部分忙碌样本里，最大的一项是 CoreML 内部的 ARGB→PlanarF 格式转换（占忙碌样本 28.5%），其次是 IOSurface 锁（20.7%）、YOLOPX 后处理 extractMask（13.6%）。UI 进程更空闲：99.7% 在等待，实际在跑的只占 0.30%，折合 3.3%（下界）～7.6%（上界）单核，最大项是 AttributeGraph 状态更新和 vImage 查表。**

---

## 2. 引擎进程（pid=93564，ps 实测 11.7%）

### 2.1 等待 vs 在跑

```
栈顶样本合计 = 270,809
其中「等待中」 = 268,852  (99.28%)  ← __workq_kernreturn / mach_msg2_trap / __psynch_cvwait
实际在跑     =   1,957  ( 0.72%)  ← 这才是烧 CPU 的
```
折合单核：1,957 / 13,332ms = **14.68%**（本文口径，只统计出现≥5次的折叠栈顶 → 下界）
codex 的 call-graph 叶子自采样口径：2,503 / 13,332ms = **18.77%**（上界）
ps 快照读数 11.7%（进程生命期衰减均值，仅作量级参照）

### 2.2 Top 栈顶函数（已剔除等待样本）

| 样本 | 占忙碌% | 函数 | 库 | 是什么 |
|---:|---:|---|---|---|
| 557 | 28.5% | `vConvert_ARGB8888toPlanarF_CV_vec` | vImage | **CoreML 内部**：把我们喂的 32BGRA 像素转成模型需要的 float tensor |
| 405 | 20.7% | `iokit_user_client_trap` | IOKit | IOSurfaceClientLock（锁 CVPixelBuffer，非纯等待） |
| 266 | 13.6% | `YolopxEngine.extractMask` | 本项目 | O(640²) 逐像素掩码提取 |
| 152 | 7.8% | `???` | libBNNS | BNNS CPU 推理算子（2 个落 CPU 的 mul/cast） |
| 89 | 4.5% | `argb32_sample_rectilinear` | CoreGraphics | 图像重采样 |
| 63+36 | 5.0% | `vVertical/vHorizontal_Scale_ARGB` | vImage | letterbox 缩放（我们代码调的） |
| 39+23 | 3.2% | `resample_horizontal/vertical` | CoreGraphics | 图像重采样 |
| 21 | 1.1% | `InferenceEngineV2.preprocessImage` | 本项目 | V2 输入预处理 |

### 2.3 最重要发现：ARGB→PlanarF 是 CoreML 内部调的，不是我们

调用链（sample 文件第 89-101 行）：

```
MLE5InputPort.copyFeatureValue          ← CoreML 入口
  → MLE5InputPortBinder.copyFeatureValue
    → MLE5BindInputBufferObjectByCopyingPixelBuffer
      → MLE5Copy32BGRA_RGBTensor_CompDtypeFLOAT_CompPackFmt32
        → vImageConvert_ARGB8888toPlanarF   ← 这一步吃 28.5%
```

**根因**：我们的 `inputBuffer` 创建为 `kCVPixelFormatType_32BGRA`（`YolopxEngine.swift:1513`），而模型期望 float tensor，所以每次推理 CoreML 都在 CPU 上做一次格式转换。

**可能的优化方向（需 ane-coreml 队友核实后才能定）**：如果模型能接受 BGRA 直接输入（不需要转 PlanarF），或改为喂 `kCVPixelFormatType_OneComponent8` / 直接 float16 buffer，就能省掉这 28.5%。**但这取决于模型的输入绑定（inputFeatureDescription），不能盲改——改错会精度回退或 SIGABRT。**

---

## 3. UI 进程（pid=93544，ps 实测 6.3%）

### 3.1 等待 vs 在跑

```
栈顶样本合计 = 141,895
其中「等待中」 = 141,471  (99.70%)
实际在跑     =     424  ( 0.30%)
```
折合单核：424 / 12,953ms = **3.27%**（本文口径，下界）
codex 的 call-graph 叶子自采样口径：982 / 12,953ms = **7.58%**（上界）
ps 快照读数 6.3%（进程生命期衰减均值，仅作量级参照）

### 3.2 Top 栈顶函数（已剔除等待样本）

| 样本 | 占忙碌% | 函数 | 库 | 是什么 |
|---:|---:|---|---|---|
| 39 | 9.2% | `AG::Graph::UpdateStack::update()` | AttributeGraph | SwiftUI 状态图更新 |
| 36 | 8.5% | `vLookupTable_Planar16WithClipping` | vImage | 色彩查表（可能是 CIContext 残留？需核实） |
| 28 | 6.6% | `_platform_memmove` | 平台 | 内存拷贝 |
| 26 | 6.1% | `AG::Subgraph::update` | AttributeGraph | SwiftUI 子图更新 |
| 25 | 5.9% | `vLookupTable_Planar8toPlanar16` | vImage | 色彩查表 |
| 22 | 5.2% | `AG::Graph::propagate_dirty` | AttributeGraph | SwiftUI 脏传播 |
| 22 | 5.2% | `HALC_ProxyIOContext::IOWorkLoop` | CoreAudio | 静音音频线程（**必需，不能删**） |
| 22 | 5.2% | `vUnpremultiplyData_RGBA8888` | vImage | 预乘 alpha 还原 |
| 21 | 5.0% | `StereoMultiCoefsSRC_Neon` | AudioToolboxCore | 音频重采样（静音音频的副产物） |

**观察**：UI 进程的 CPU 很分散，没有单项超过 10%。AttributeGraph 占比最高（合计 ~21%），说明 SwiftUI 状态图更新是主要驱动力。vImage 查表也占不少（合计 ~20%），但需要核实这些是否与静音音频线程有关（`StereoMultiCoefsSRC_Neon` 和 `HALC_ProxyIOContext` 都在音频线程上）。

---

## 4. PERF tick 分段（来自 2631 条日志记录）

| 阶段 | 均值p50(ms) | 占tick% | 是否必要 |
|---|---:|---:|---|
| motion | 0.221 | 66.7% | 是（光流/运动检测） |
| consumeFrame | 0.018 | 5.3% | 是 |
| confidence | 0.015 | 4.6% | 是 |
| nativeROI | 0.015 | 4.6% | 是 |
| debugSummary | 0.014 | 4.2% | **部分浪费**（1Hz 但有时 3ms） |
| speed | 0.008 | 2.5% | 是 |
| laneFallback | 0.006 | 1.8% | 是 |
| ruleDecision | 0.002 | 0.7% | 是 |
| inject | 0.001 | 0.4% | 是 |
| degrade | 0.001 | 0.4% | 是 |
| record | 0.000 | 0.0% | 是 |
| **合计** | **0.303** | | tick 本身只占 0.5% 单核 |

**关键**：tick 本身极便宜（0.33ms × 15Hz = 5ms/s ≈ 0.5% 单核）。CPU 大头在 tick **之外**——CoreML 推理（`耗时=` 字段 p50=7.10ms，15Hz 折算 ≈ 10.7% 单核，与实测吻合）。

`耗时=` 字段语义已核实：它来自 `px?.lastLatencyMs`（`EngineMain.swift:1346`），注释写明覆盖「模型推理 + NMS + 掩码提取」，不含主线程 letterbox。

---

## 5. 未测项

- 改输入格式后 CoreML 是否真的不做 ARGB→PlanarF 转换：**未测**（需 MLComputePlan 或真机 A/B）
- UI 进程的 vImage 查表是否与静音音频相关：**未测**（需按线程拆分）
- `iokit_user_client_trap`（20.7%）是纯阻塞还是部分在算：**部分在算**（调用链显示是 IOSurfaceClientLock，但 lock 本身有 CPU 成本）
