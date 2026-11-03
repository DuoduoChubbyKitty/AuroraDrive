# CPU/ANE/GPU 全面深挖综合报告

> 2026-11-01，五路并行深挖合并
> Lead 实测归因 + cpu-hotpath 静态分析 + ane-coreml 推理审计 + gpu-system 全仓扫描
> （verify-docs 文档核验 + thread-attribution 线程归因两个子代理产出待补）

---

## 0. 一句话结论

**引擎进程 CPU 的 28.5%（忙碌样本）花在 CoreML 内部的 ARGB→PlanarF 格式转换上——这是因为我们喂 32BGRA 而模型需要 float tensor；这是目前最大的单项可优化目标，但改法需要实测验证。除此之外，推理侧算力派发已封顶（ANE 95.7%+，GPU=0），没有「漏网 GPU 抢卡」。UI 进程很闲（99.7% 在等待）。全仓确认 5 条纯浪费，都是零风险零质量影响。**

---

## 1. CPU 到底被哪里吃了（实测归因）

### 引擎进程（sample 窗口 13.33s；ps 快照 11.7%）

99.28% 的采样是线程在等待，真正在跑（有 CPU）的只占 **0.72%**（1,957/270,809）。折合单核：**14.7%（本文口径，下界）～18.8%（call-graph 叶子自采样口径，上界）**；ps 的 11.7% 是进程生命期衰减均值，仅作量级参照。以下是这 0.72% 的内部构成：

| 占忙碌% | 函数 | 是什么 | 能不能动 |
|---:|---|---|---|
| **28.5%** | `vConvert_ARGB8888toPlanarF` | **CoreML 内部**把我们喂的 32BGRA 转成 float tensor | **可能可动**（改输入格式，需实测） |
| 20.7% | `iokit_user_client_trap` | IOSurface 锁 CVPixelBuffer | 部分在算（锁有 CPU 成本） |
| 13.6% | `extractMask` | 本项目 O(640²) 逐像素掩码提取 | **SIMD4 已实测 2.42× 但未合入** |
| 7.8% | libBNNS `???` | 2 个落 CPU 的 mul/cast 算子（cost=0） | 不值得动 |
| 5.0% | vImage 缩放 | letterbox 640×640（我们代码调的） | 必要（vImage 快路径精度回退已否决） |

### UI 进程（sample 窗口 12.95s；ps 快照 6.3%）

99.70% 在等待，实际在跑（有 CPU）的只占 **0.30%**（424/141,895）。折合单核：**3.3%（下界）～7.6%（上界）**。构成极其分散，无单项超过 9.2%。

### tick 本身极便宜

引擎 `[PERF] tick分段` p50 合计 **0.33ms**（15Hz 折算 5ms/s ≈ 单核 0.5%）。CPU 大头在 tick **之外**——CoreML 推理 `耗时=` 字段 p50=7.10ms（15Hz 折算 ≈ 10.7% 单核，与实测吻合）。

---

## 2. Top 可优化项（按收益÷风险排序）

### ★ 第一优先：ARGB→PlanarF 格式转换（引擎 28.5% 忙碌样本）

| 维度 | 内容 |
|---|---|
| 位置 | `YolopxEngine.swift:1513`（inputBuffer 创建为 `kCVPixelFormatType_32BGRA`） |
| 现状 | 每次推理 CoreML 内部调 `MLE5Copy32BGRA_RGBTensor_CompDtypeFLOAT` → vImage ARGB→PlanarF，占引擎忙碌样本 28.5% |
| 证据 | sample 调用链：`MLE5InputPort.copyFeatureValue` → `MLE5BindInputBufferObjectByCopyingPixelBuffer` → `MLE5Copy32BGRA_RGBTensor` → `vImageConvert_ARGB8888toPlanarF`（`/tmp/baseline_eng_sample.txt:89-101`） |
| 可能改法 | ①查模型 inputFeatureDescription 是 Image 还是 MultiArray；②若能直接喂 float16 MLMultiArray（跳过像素转换）则省掉这 28.5%；③但 letterbox 快路径曾精度回退（9→6 框），**必须实测精度** |
| 预估收益 | 引擎 CPU 降 **~4.2% 单核**（557 采样 / 13,332ms = 4.18%，这是该项的绝对占用上界；Swift 侧仍需自做归一化，故实益略低于此） |
| 风险 | **高**（改输入格式可能导致精度回退或 SIGABRT） |
| 实测状态 | **已闭合**——ane-coreml 用独立 Swift 探针读 model description 确认：ayolom/yolopx/yolo26s 输入是 **Image 类型**（我们喂 BGRA CVPixelBuffer → CoreML 内部做转换）；M9/assist/V2 是 **MultiArray**（Swift 自己用 vDSP 转，不触发 CoreML 内部转换）。model.mil 第 3-5 行确认那 2 个 CPU mul/cast 算子就是 ImageType 包装的 **÷255 归一化 + fp32→fp16 cast**。改法：导出脚本 ImageType→TensorType（归一化移回 Swift vDSP），预估省 **~4.2% 单核上界**（实益略低，因归一化移至 Swift 后仍需 CPU 成本），且可能一并消除 mul/cast。数值操作等价（÷255 移位不改精度），但 letterbox 灰边 114/255 须由 Swift 正确写入 CHW，**必须 ABBA 实测 maxdiff** |

### ★ 第二优先：extractMask SIMD4 向量化（引擎 13.6% 忙碌样本）

| 维度 | 内容 |
|---|---|
| 位置 | `YolopxEngine.swift:1280-1377` |
| 现状 | 标量逐像素循环，160×160×4×4=409600 次比较/次，每帧调 2 次（da+ll） |
| 证据 | 历史实测 SIMD4 累加 3.98→1.64ms（**2.42×**），0 格差异（逐位对拍） |
| 预估收益 | **上界 ~1.2% 单核**（该项实测总占用仅 266/13,332ms = 2.00%；SIMD4 是 2.42× 加速 ⟹ 最多省该项的 58.7% = 1.17%）。⚠️ ane-coreml 报告曾写“省 70ms/s ≈ 7% 单核”，与实测总占用矛盾，已修正 |
| 风险 | **低**（纯算术等价替换，已有逐位对拍证据） |
| 未采纳原因 | 需确认为何 SIMD4 方案回退/未合入——ane-coreml 队友已标此问题 |

### ③ 环境变量每帧现读 → AuroraFlags 缓存（零风险）

| 维度 | 内容 |
|---|---|
| 位置 | `AuroraDriveApp.swift:7542` 附近 |
| 现状 | 每帧 tick 现读 `ProcessInfo.processInfo.environment["AURORA_XXX"]` |
| 预估收益 | 省 ~0.26ms/s，零风险 |
| 来源 | cpu-hotpath 报告 §3 |

### ④ UI tick leeway 0ns → 1ms（零风险）

| 维度 | 内容 |
|---|---|
| 位置 | `MissionConsole.swift:6233` |
| 现状 | `leeway: .nanoseconds(0)` → dispatch 框架无法合并唤醒 |
| 预估收益 | 间接（减少上下文切换），15Hz+1ms 人眼无感 |
| 来源 | cpu-hotpath 报告 §3 |

### ⑤ BrandMark 死动画删除（零风险）

| 维度 | 内容 |
|---|---|
| 位置 | `MissionConsole.swift:177`（`@State spin`）+ `:194`（`withAnimation repeatForever`） |
| 现状 | spin 无任何 rotationEffect 读取点 → 纯白跑 |
| 预估收益 | 量级未测，同类动画曾让 WindowServer +30pp（BrandMark 面积小得多，预计 0.1~1pp） |
| 来源 | gpu-system 报告 W1 |

### ⑥ assistEngine 保活心跳 5帧→9帧（中风险）

| 维度 | 内容 |
|---|---|
| 位置 | `AuroraDriveApp.swift:7543` `adaptiveFrameCounter % 5 == 0` |
| 现状 | e2e 档每 5 帧（333ms@15Hz）跑一次 ~8ms |
| 预估收益 | 省 ~16ms/s（从 48ms/s 降到 32ms/s） |
| 风险 | **中**：5Hz 让位态下 9 帧=1.8s > isAlive 阈值 1.0s → 误降级。必须门控：仅 `mode == .e2e && effectiveTickHz >= 15` 时生效 |
| 来源 | ane-coreml 报告 §2 |

### ⑦ engineClientLog 缺轮转（可靠性问题）

| 维度 | 内容 |
|---|---|
| 位置 | `EngineClient.swift:25` |
| 现状 | 唯一无上限、无轮转的日志文件 → 长期运行无限增长 |
| 来源 | gpu-system 报告 W2 |

---

## 3. 明确不能动的（必须花的钱）

| 项 | 为什么不能动 |
|---|---|
| GameModeDefender 静音音频 | **删了会降频**（昨天事故铁证）。start() = 静音AudioQueue + 重主张两件事 |
| yolopx `.all` 档位 | `.cpuAndNeuralEngine` 实测更慢 10.6%，已封顶 |
| letterbox CGContext 路径 | vImage 快路径精度回退（9→6 框），已否决 |
| V2 双模型 enc(ANE)+ctl(cpuOnly) | ctl 在 .all 下 66.5% 派 GPU 抢卡；.cpuOnly 快 6.1× |
| NMS 逐对 IoU | YOLOX 输出未去重，必须自己做 |
| 窗口显示上屏 +12.82pp | 这是功能本身的价格，不是浪费（按红线不砍功能） |

---

## 4. 数据修正（本次审计纠正的旧错误）

| 旧文档说法 | 实际值 | 来源 |
|---|---|---|
| MTLTexture 85 处 | **42 处**（编进二进制的范围） | gpu-system W3 |
| .cpuOnly 8 处 | **5 处生效**（另 3 处是注释） | ane-coreml §1 补充 |
| sizeThatFit s174 采样（self-time） | **7 采样**（174 是 inclusive 累加值） | cpu-hotpath §2.3 |

---

## 5. 未测项（诚实标注）

- ARGB→PlanarF 改输入格式后的精度与性能：**未测**
- extractMask SIMD4 当前为何未合入：**需确认**（历史实测有效但回退了）
- assistEngine 9 帧保活在让位态下的行为：**未测**
- BrandMark 死动画的 WindowServer 影响量级：**未测**
- verify-docs（文档核验）和 thread-attribution（线程归因）两个子代理：**产出待补**

---

## 6. 产出文件清单

| 文件 | 行数 | 作者 | 内容 |
|---|---:|---|---|
| `lead-attribution.md` | 110 | Lead | sample 实测归因：等待 vs 在跑，ARGB→PlanarF 调用链 |
| `hotpath.md` | 207 | cpu-hotpath | tick 分段、SwiftUI 布局 self-time 校正、定时器清单 |
| `ane-coreml.md` | 173 | ane-coreml | 6 处 .all 判定、2 个 CPU 算子、必须花的钱 |
| `verify-docs.md` | 173 | claude-code 子代理 | 对抗式核验：6 份旧文档 8 处结论级硬错 |
| `thread-attribution.md` | — | codex 子代理 | 线程级 CPU 归因（产出待补） |

---

## 7. 文档核验补充（verify-docs 发现）

旧审计文档有 **8 处结论级硬错**——全部是同一个成因：文档与修复在同一个提交（`3082269`，10-29）一起进库，文档写的是修复前的源码，修复落地后结论没有回写。

| 文档 | 声称（过期） | 实际（已修） |
|---|---|---|
| perf-audit-20261024/3 | SpeedOCR 从未设 computeUnits | 已设 `.cpuAndNeuralEngine`（SpeedOCRReader:433） |
| perf-audit-20261024/2 | publish 每 tick 无条件 | 已加无新帧短路（EngineMain:1527） |
| perf-audit-20261024/2 | publishMasks 在 if 外每 tick 重写 | 已挪进花括号（EngineMain:1623） |
| perf-audit-20261024/4 | 引擎进程 Vision OCR 白跑 4.8% | 已加 --engine 进程门控（App:7242） |

**影响**：如果照着旧文档的「待修项」去改，会重复劳动（这些已经改了）。本次深挖的五份新报告已基于当前源码，不受此问题影响。

数字失真也一并修正：`.all` 实际 6 处（旧文档说 7 或 8）、`.cpuOnly` 实际 5 处（旧文档说 8）、MTLTexture 编进二进制的 42 处（旧文档说 85）。
