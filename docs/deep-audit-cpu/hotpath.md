# CPU 热路径深挖报告 · AuroraDrive

> 审计员：cpu-hotpath ｜ 机器：Apple M3 8核（E0-3 / P4-7）16GB ｜ 产物日期 2026-11-01

---

## 1. 一句话结论

**两份 sample（真实采样窗 13.332s / 12.953s，非 20s）在窗口内 CPU 占用极低（UI 主线程忙采样仅 850/12953=6.6%，引擎 2637/13332=19.8%）；引擎 tick 分段统计 p50 合计 0.33ms（15Hz 下 5ms/s ≈ 单核 0.5%），真正的 CPU 消耗在分段之外——CoreML/vImage 推理（必要）和 UI 侧 SwiftUI 布局重算（部分可优化）。任务简报中"sizeThatFits 174 采样"是 inclusive（含子调用递归累加）值，不是 self-time；实际 self-time 排行中 SwiftUI 布局函数最高仅 7 采样。**

---

## 2. CPU 消耗归因总表

### 2.1 引擎进程 [PERF] tick 分段（2631 行，AuroraEngine.log）

数据源：`~/Library/Logs/AuroraEngine.log` 全部 2631 条 `[PERF] tick分段` 行（编码 UTF-8 含 44 个非法字节，已用 errors='replace' 解码，不影响 PERF 行解析——首坏字节在 offset 381542 的退出流程文本，远在 PERF 行之前）。

| 阶段 | 样本数 n | p50 (ms) | p95 (ms) | p99 (ms) | max (ms) | 占 total p50 | 15Hz 折算 ms/s | 是否必要 |
|------|---------|----------|----------|----------|----------|-------------|---------------|---------|
| **motion** | 2585 | 0.220 | 0.380 | 0.560 | 1.450 | **66.7%** | 3.30 | 必要（光流+运动预测，legacy 档核心） |
| consumeFrame | 2629 | 0.020 | 0.040 | 0.040 | 0.050 | 6.1% | 0.30 | 必要（取帧） |
| confidence | 2585 | 0.020 | 0.030 | 0.040 | 0.190 | 6.1% | 0.30 | 必要（亮度一致性计算） |
| nativeROI | 2627 | 0.010 | 0.030 | 0.040 | 0.050 | 3.0% | 0.15 | 必要（OCR 帧消费） |
| speed | 2585 | 0.010 | 0.010 | 0.042 | 2.160 | 3.0% | 0.15 | 必要（速度读数） |
| degrade | 2585 | 0.000 | 0.010 | 0.020 | 0.170 | 0% | 0 | 必要（状态机） |
| ruleDecision | 2585 | 0.000 | 0.010 | 0.010 | 0.160 | 0% | 0 | 必要（规则决策） |
| laneFallback | 2585 | 0.000 | 0.010 | 0.102 | 0.450 | 0% | 0 | 必要（车道线回退） |
| inject | 2585 | 0.000 | 0.010 | 0.030 | 0.150 | 0% | 0 | 必要（按键注入） |
| record | 2585 | 0.000 | 0.000 | 0.000 | 0.140 | 0% | 0 | 必要（录制） |
| debugSummary | 2585 | 0.000 | 0.000 | 0.492 | 3.060 | 0% | 0 | **部分浪费**（见 §3.2） |
| **total** | 2613 | **0.330** | **0.620** | 0.849 | 2.670 | 100% | **4.95** | — |

> **关键解读**：分段统计 p50 合计 0.28ms ≈ total 0.33ms（自洽）。但这些分段**只覆盖 `DriveState.tick()` 内部**（`AuroraDriveApp.swift:7088` 的 `PerfBus.stamp()` 到 `defer { PerfBus.mark("tick.total") }`），**不含**：shm publish、publishMasks、pointer socket.send、EmergencyTakeover 检查、字符串拼接、CoreML 推理（推理是 async dispatch 到 `com.aurora.yolopx`/`com.aurora.inference.v2` 队列，不在 tick 主线程计时）。所以分段总计 5ms/s **远小于**引擎实际 CPU 消耗。

### 2.2 引擎进程 sample 非空闲 self-time 排行（baseline_eng_sample.txt，Sort-by-top 段 L4547+）

sample 总采样 13332（13.332s × 1ms），非空闲 self 2637（占单线程窗口 19.8%）。

| 符号 | self 采样 | 占 busy % | 归属线程 | 性质 |
|------|----------|----------|---------|------|
| vConvert_ARGB8888toPlanarF_CV_vec | 557 | 21.1% | com.apple.root.user-initiated (多线程) | **必要**（CoreML 预处理，vImage ARGB→PlanarF） |
| iokit_user_client_trap | 405 | 15.4% | 多线程 | **必要**（ANE/GPU 系统调用，CoreML 推理） |
| ??? (libBNNS.dylib) | 325 | 12.3% | 多线程 | **必要**（BNNS 算子，推理后处理） |
| YolopxEngine.extractMask | 266 | 10.1% | com.aurora.yolopx (780 总) | **必要**（掩码网格提取，但可优化，见 §3.1） |
| start_wqthread | 141 | 5.3% | 多线程 | 系统开销（线程池唤醒） |
| argb32_sample_rectilinear_argb32 | 89 | 3.4% | com.aurora.yolopx | **必要**（CGImage 采样，指针读数） |
| vVertical_Scale_ARGB_8888 | 63 | 2.4% | 多线程 | **必要**（vImage 缩放） |
| InferenceEngineV2.preprocessImage | 21 | 0.8% | com.aurora.inference | **必要**（V2 预处理） |
| YolopxEngine.positiveRatios | 18 | 0.7% | com.apple.main-thread | **必要**（前景格比例计算） |
| YolopxEngine.smoothMask | 16 | 0.6% | com.apple.main-thread | **必要**（掩码平滑） |

> 引擎侧主线程（com.apple.main-thread，123 总采样）的 tickOnce 链路（sample L396-605）：`EngineMain.tickOnce()` 54 采样 → `DriveState.tick()` 分支：`PointerHeadingReader.read` 26 采样（CGContextDrawImage 22）、`InferenceEngineV2.infer` async dispatch 7、`ConfidenceEstimator.update` 3、`YolopxEngine.infer` async dispatch 3、`EngineFrameShm.publish` 8（memmove）、字符串拼接 `String.init(format:)` 4、`_StringGuts.append` 6、`dlog→print→fwrite` 2。

### 2.3 UI 进程 sample 非空闲 self-time 排行（baseline_ui_sample.txt，Sort-by-top 段 L6176+）

sample 总采样 12953（12.953s × 1ms），非空闲 self 1078（占单线程窗口 8.3%）。

| 符号 | self 采样 | 占 busy % | 性质 |
|------|----------|----------|------|
| start_wqthread | 94 | 8.7% | 系统开销 |
| ??? (未知二进制) | 43 | 4.0% | 无法归因 |
| AG::Graph::UpdateStack::update() | 39 | 3.6% | **SwiftUI AttributeGraph 更新**（部分必要） |
| vLookupTable_Planar16WithClipping | 36 | 3.3% | **vImage 颜色转换**（UI 侧图像处理） |
| _platform_memmove | 28 | 2.6% | 内存拷贝 |
| &lt;deduplicated_symbol&gt; (SwiftUICore) | 27 | 2.5% | SwiftUI 内部 |
| AG::Subgraph::update() | 26 | 2.4% | **AttributeGraph 子图更新** |
| vLookupTable_Planar8toPlanar16 | 25 | 2.3% | vImage 颜色转换 |
| vUnpremultiplyData_RGBA8888 | 22 | 2.0% | vImage alpha 处理 |
| AG::Graph::propagate_dirty | 22 | 2.0% | **AttributeGraph 脏标记传播** |
| HALC_ProxyIOContext::IOWorkLoop | 22 | 2.0% | CoreAudio（无关） |
| iokit_user_client_trap | 21 | 1.9% | IOKit 系统调用 |
| ViewLayoutEngine.sizeThatFits | **7** | 0.6% | SwiftUI 布局测量（self-time，非 inclusive） |

> **简报数字校正**：简报称 `LayoutEngineBox.sizeThatFits 174`、`explicitAlignment 163`、`ViewLayoutEngine.sizeThatFits 91`、`UnaryLayoutEngine.sizeThatFits 86`、`StackLayout.placeChildren 83`。这些数字在 sample call graph（L1972-2098）中确实存在，但它们是 **inclusive（含子调用）值在递归布局树各层重复出现的累加**，不是 self-time。Sort-by-top 段（self-time 权威排行）中 `ViewLayoutEngine.sizeThatFits` 仅 7 采样。整棵布局子树（L1955-2098）的根是 `GraphHost.flushTransactions` inclusive 270 采样（占主线程 2.1%），由 `SecondaryLayerGeometryQuery.value.getter`（101 inclusive）驱动测量。

### 2.4 进程整体忙闲比

| 进程 | 总采样 | 非空闲 self | 忙占比 | 主要忙线程 |
|------|-------|-----------|-------|----------|
| UI | 12953/线程 | 1078 | 8.3% | Main Thread (850 busy)、audio IO (80)、coordinate-capture (25) |
| 引擎 | 13332/线程 | 2637 | 19.8% | com.aurora.yolopx (483)、com.aurora.inference.v2 (424)、com.aurora.capture (517)、root.user-initiated 多线程 (合计 ~600) |

> coordinate-capture 线程（UI 进程 Thread_14385346）：10730 采样在 `read()`（libsystem_kernel）、1999 在 `__semwait_signal`——这是 pcap 抓包阻塞读，**几乎纯 idle**（read 阻塞不算 CPU 消耗），不是 CPU 热点。

---

## 3. Top 可优化项表（按「收益÷风险」降序）

| # | 位置 | 当前成本 | 可省多少 | 质量影响 | 风险 | 回退开关 |
|---|------|---------|---------|---------|------|---------|
| **1** | `AuroraDriveApp.swift:7542` `ProcessInfo.processInfo.environment["AURORA_ASSIST_KEEPALIVE"] != "0"` **每帧现读** | sample L484-496：`DriveState.tick()+6604` 有 4 采样在 `_ProcessInfo.environment.getter`，15Hz × 17µs = 0.26ms/s | 0.26ms/s（微小但纯浪费） | 无（语义不变） | 极低 | 已有 `AuroraFlags` 缓存层（`AuroraFlags.swift:91`），迁移即可 |
| **2** | `EngineMain.swift:1656-1661` pointer socket.send **每 3 帧（5Hz）拼接字符串 + JSON 发送** | sample L572-576：`tickOnce+5500` 有 6 采样在 `_StringGuts.append`、`+5424` 有 4 采样在 `String.init(format:)`，合计 ~10 采样 = 0.77% 引擎主线程 | ~5 采样/tickOnce（0.4% 主线程） | 无（5Hz 不变，只省拼接开销） | 低（改字符串构建方式即可） | 无需开关 |
| **3** | `AuroraDriveApp.swift:7046` DriveState.tick `dlog → print → fwrite`（同步 stdout） | sample L539-553：`DriveState.tick()+26184` 有 2 采样在 `print→fwrite→__write_nocancel` | 2 采样（0.15% 主线程），但 fwrite 同步阻塞可能放大尾延迟 | 无（dlog 是诊断日志） | 低（改为异步或移除 hot-path dlog） | `AURORA_DIGEST` 等开关已存在 |
| **4** | `MissionConsole.swift:6233` UI tick 定时器 `leeway: .nanoseconds(0)` | 零 leeway → dispatch 框架无法合并唤醒，每 66.7ms 精确投递 | 间接（允许 leeway 后系统可合并 timer 唤醒，减少上下文切换） | 无（15Hz + 1ms leeway 人眼无感） | 极低 | 改回 `.nanoseconds(0)` |
| **5** | `MissionConsole.swift:6246-6256` 待机 idleSkip 降频已有（15Hz/8≈1.9Hz），但 **驾驶态仍每帧投递 `DispatchQueue.main.async { state.tick() }`** | 驾驶态 15Hz 每帧 tick → 每帧 @Observable 写入 → `GraphHost.flushTransactions`（inclusive 270 采样 = 2.1% 主线程） | 部分可省（见 §3.3 讨论） | 中（需保证驾驶 HUD 实时性） | 中（需要隔离动态数据到子视图） | idleSkip 已是回退路径 |

### 3.1 YolopxEngine.extractMask（266 self 采样，引擎最大单项）

- **位置**：`YolopxEngine.swift`（sample L1195/1226/142/153 均命中 `specialized static YolopxEngine.extractMask(_:grid:stride:metrics:)`）
- **当前成本**：266 self 采样 = 占引擎非空闲 10.1%，集中在 `com.aurora.yolopx` 线程（780 总采样中 211 self）
- **是否必要**：**必要**——这是从 CoreML 输出网格提取可行驶区/车道线掩码的核心步骤
- **可优化方向（未测）**：extractMask 是逐格遍历 0/1 网格，可能可用 vImage 或 SIMD 批处理加速，但**需要单独 profile extractMask 函数体**才能确认热点在哪个循环
- **风险**：中（改动涉及掩码正确性，有 `--mask-selftest` 可验）

### 3.2 debugSummary（PERF 分段 p99=0.492ms / max=3.060ms）

- **位置**：`DriveState.tick()` 内 `PerfBus.lap("tick.debugSummary")` 打点
- **当前成本**：p50=0（多数 tick 不跑），但 p99=0.492ms、max=3.060ms——**偶发尖峰**
- **是否必要**：**部分浪费**——debugSummary 是诊断输出，生产环境不应有 3ms 尖峰
- **可优化**：门控 `AURORA_PERF` 或 `AURORA_DEBUG` 未设时完全跳过（需确认当前是否已有门控；PERF 打点本身注释说"未设时短路"，但 debugSummary 的 3ms max 说明要么没门控、要么门控后仍有开销）
- **风险**：低（只影响诊断输出）

### 3.3 SwiftUI 布局重算（UI 进程，问题 1 详答）

**为什么每帧重算布局？**

UI tick（`MissionConsole.swift:6233-6256`）每 66.7ms 投递 `DispatchQueue.main.async { state.tick() }`。tick 内对 `DriveState`（@Observable）属性赋值，即使"先比后写"，驾驶态下每帧都有属性真变（`effectiveSpeed`、`fps`、`bodyHeadingDeg`、`currentCommand` 等），触发 `ObservationRegistrar.withMutation` → SwiftUI 标记依赖该属性视图节点失效 → `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` → `AG::Subgraph::update` → 重算受影响子树的 `sizeThatFits`/`explicitAlignment`。

sample 证据链（baseline_ui_sample.txt L1955-2098）：
```
_CFRunLoopRunSpecificWithOptions (301)
→ __CFRunLoopDoObservers (301)
→ NSRunLoop.flushObservers (299)
→ NSHostingView.beginTransaction (299)
→ ViewGraphRootValueUpdater.updateGraph (299)
→ GraphHost.flushTransactions (270)
→ AG::Subgraph::update (244)
→ AG::Graph::UpdateStack::update (219)
→ SecondaryLayerGeometryQuery.value.getter (101)  ← 布局测量入口
→ LayoutEngineBox.explicitAlignment (101)
→ ... _ZStackLayout.sizeThatFits (101)
→ StackLayout.placeChildren (99)
→ ... 递归子视图测量
```

**哪些 @Observable / @State 每帧变化？**

- `effectiveSpeed`（`AuroraDriveApp.swift:7696-7699`）：OCR 新鲜时每帧 EMA 追踪，值持续变
- `fps`（`:7703-7704`）：已先比后写，但 captureEngine.captureFPS 每帧可能微变
- `bodyHeadingDeg` / `bodyHeadingConf`（`:7447-7453`）：每 3 帧（5Hz）更新
- `currentCommand`（`:7405` 待机、`:566` 引擎回传）：驾驶态每帧可能变
- `tickGapMs`（`:7049`）：每帧必然变化（两次 Date() 差值）

**能否阻断布局传播？**

1. **`tickGapMs` 不应进视图树**：它是诊断量，如果任何视图读它展示，每帧必然触发重绘。应隔离到独立的诊断子视图或用 `.equatable()` 包裹。
2. **`effectiveSpeed` / `fps` 用固定 frame + `.drawingGroup()`**：HUD 数字显示可用 `Text("\(effectiveSpeed)")` 放在固定尺寸容器里，`.drawingGroup()` 让该子树光栅化，避免布局测量向上传播。
3. **动态数据隔离到子视图**：把读 `state.effectiveSpeed` 的视图提取为 `SpeedHUD(state: state)` 子组件，父视图不直接依赖该属性——这样只有 SpeedHUD 子树失效，不触发整棵 ZStack 重算。
4. **`.equatable()`**：对不依赖高频变化属性的视图加 `.equatable()`，SwiftUI 在依赖未变时跳过 diff。

> **注意**：这些改法**涉及修改 Sources/ 源码**，超出本审计的写入权限（只能写 docs/）。此处仅给出改法建议，实际修改需 Lead 安排。

---

## 4. 明确排除的方向（附证据，避免重复劳动）

| 方向 | 排除理由 | 证据 |
|------|---------|------|
| 引擎 tick 分段内部有大量浪费 | 分段 p50 合计 0.33ms，15Hz 下 5ms/s，占单核 0.5%——分段覆盖的代码已经极轻 | AuroraEngine.log 2631 条 PERF 行统计 |
| CoreML/vImage 推理是浪费 | 557+266+89+63 self 采样全是必要推理/预处理，引擎非空闲 60% 在这 | baseline_eng_sample.txt Sort-by-top 段 |
| coordinate-capture 线程吃 CPU | 10730/12953 在 `read()` 阻塞（libsystem_kernel），是 pcap 阻塞读，不算 CPU 消耗 | baseline_ui_sample.txt Thread_14385346 |
| 已修三项需重报 | publish 无新帧短路（`skippedPublishTicks`）、掩码指纹门控（`EngineMain.swift:1623`）、quest OCR 引擎门控（`AuroraDriveApp.swift:7242`）均已生效，sample 中无相关浪费迹象 | tickOnce 源码 L1527-1642 |
| ANEServices 线程吃 CPU | 4 个 ANEServicesThread 各 12953 全在 `mach_msg2_trap`（idle 等待），零 CPU | baseline_ui_sample.txt Thread_14385151/153 |
| fixed_ui_sample.txt 可用于归因 | **无效产物**：Call graph 段为空（只有 `Total number in stack` 表头 + Binary Images），0 个采样帧 | `/tmp/fixed_ui_sample.txt` L19-24 |

---

## 5. 未测项清单（诚实标注）

| 未测项 | 原因 | 下次怎么测 |
|--------|------|----------|
| extractMask 函数体内部热点（逐格循环 vs SIMD） | sample 只到函数级 self-time，无法拆解函数内部行级耗时 | Instruments Time Profiler 单独挂 `com.aurora.yolopx` 线程，或用 `PerfBus` 在 extractMask 内部加子分段 |
| SwiftUI 布局重算的"每帧属性变更数" | sample 是统计采样，无法确定单帧内哪几个 @Observable 变了 | 在 tick() 末尾加一次性 `print(ObservationRegistrar.accessCount)` 或用 Instruments SwiftUI template |
| UI-local 模式（引擎未连）下的 UI tick 成本 | 本次 sample 采集于引擎已连模式（引擎进程 pid 93564 是 UI pid 93544 的子进程），UI tick 走 `tickEngineMode()` 早退路径 | 单独跑 UI-local 模式 sample（不启动 --engine 子进程） |
| shm publish 的 memmove 实际字节数 | sample 只看到 `_platform_memmove` 8 采样，未测字节数 | 在 `EngineFrameShm.publish` 内加 `print(MemoryLayout.size)` 或用 `malloc_history` |
| 定时器"高频但产物无人消费"的判定 | 静态分析只能看间隔/qos，无法确认产物是否被消费——需要动态追踪消费方 | 对每个 DispatchSourceTimer 的 handler 加 `os_signpost`，用 Instruments 统计 handler 执行次数 vs 产物读取次数 |
| `leeway: .nanoseconds(0)` 的实际调度开销 | sample 无法观测 dispatch 框架内部合并行为 | 用 `os_signpost` 标记 timer handler 入口/出口，对比 leeway=0 vs leeway=1ms 的唤醒抖动分布 |

---

## 附：定时器全清单

| 文件:行 | 类型 | 间隔 | qos/队列 | leeway | 产物消费方 |
|---------|------|------|---------|--------|----------|
| EngineMain.swift:1281 | DispatchSourceTimer | 1/15Hz (66.7ms) | tickQueue (com.aurora.tick) | **未设**（EngineMain.swift:831 有 leeway 参数但 1281 行的 schedule 调用需确认） | EngineMain.tickOnce |
| EngineMain.swift:1302 | DispatchSourceTimer | 1.0s | hbQueue | 50ms | 心跳回传 |
| MissionConsole.swift:6233 | DispatchSourceTimer | 1/15Hz (66.7ms) | com.aurora.tick (.userInteractive) | **0ns** | DriveState.tick() |
| MissionConsole.swift:6309 | DispatchSourceTimer | 1/10Hz (100ms) | netLoc 队列 | **0ns** | 网络定位步进 |
| MissionConsole.swift:5304 | Timer.publish | 110ms | .main/.common | N/A | AI 面板动画 |
| EngineClient.swift:202 | DispatchSourceTimer | 300ms | queue | 50ms | 连接检测 |
| EngineClient.swift:322 | DispatchSourceTimer | 400ms | queue | 50ms | 重启轮询 |
| EngineClient.swift:410 | DispatchSourceTimer | 500ms | queue | 100ms | 心跳监控 |
| EngineClient.swift:614 | DispatchSourceTimer | 500ms | queue | 100ms | 同上 |
| GameModeDefender.swift:155 | DispatchSourceTimer | 3.0s | q (.utility) | 200ms | 游戏模式重主张 |
| AuroraCache.swift:517 | DispatchSourceTimer | 1.0s | .global(.utility) | 200ms | 缓存指标 |
| AIAgentPanel.swift:742 | DispatchSourceTimer | 8.0s | — | 未设 | AI 轮询 |
| AIAgentPanel.swift:810 | DispatchSourceTimer | 600ms | — | 未设 | UI 刷新 |
| AIAgentPanel.swift:849 | DispatchSourceTimer | 3.0s | — | 未设 | — |
| AIAgentPanel.swift:911 | DispatchSourceTimer | 500ms | — | 未设 | — |
| AIAgentPanel.swift:1012 | DispatchSourceTimer | 500ms | — | 未设 | — |
| AIAgentPanel.swift:1055 | DispatchSourceTimer | 2.0s | — | 未设 | — |
| AIAgentPanel.swift:1092 | DispatchSourceTimer | 1.0s | — | 未设 | — |
| AIAgentPanel.swift:1131 | DispatchSourceTimer | 2.0s | — | 未设 | — |
| AIAgentPanel.swift:1169 | DispatchSourceTimer | 2.0s | — | 未设 | — |

> **高频（≤100ms）定时器**：EngineMain tick (66.7ms)、MissionConsole tick (66.7ms)、MissionConsole netLoc (100ms)、MissionConsole AI 动画 (110ms)。其中 MissionConsole tick 的 `leeway: .nanoseconds(0)` 是最紧调度——这是唯一一处零 leeway，改为 1ms 可让 dispatch 框架合并唤醒。AIAgentPanel 有 8 个 DispatchSourceTimer，但间隔最短 500ms，非高频。
