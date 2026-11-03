# 线程级 CPU 归因 · AuroraDrive

> 结论先行：CPU 主要不是被 15Hz tick 吃掉的。引擎进程约 56.7% 的 CPU 花在「抓屏(com.aurora.capture) + Yolopx + inference.v2」三条流水线上；UI 进程 85.2% 的 CPU 花在主线程（SwiftUI 布局 + CALayer/CG 图像与色彩转换）。两个进程的静音音频循环合计仅约 1.3% 单核，按设计必要。未见实质锁竞争。

> 作者：codex 一次性子代理（2026-11-01）。该会话写盘被沙箱拒绝，报告由 Lead 保存入库，内容未改动。

## 0. 数据与方法

- 数据源（全部静态，未启动程序、未联网）：
  - `/tmp/baseline_ui_sample.txt`（UI pid 93544，20s，sample 1ms，驾驶态）
  - `/tmp/baseline_eng_sample.txt`（引擎 pid 93564，`--engine` 子进程；sample 内 Process 名仍显示 AuroraDriveUI，但日志 `08:35:13.943 [ENGINE] 启动 --engine 模式 pid=93564` 证实身份）
  - `/tmp/fixed_ui_sample.txt`（另一版本，1175 行）
  - `~/Library/Logs/AuroraEngine.log`（2.3MB；836 条 `[ENGINE] 统计`，2631 条 `[PERF] tick分段`）
- 解析口径：
  - 仅解析 `Call graph:` 段（UI 到第 6048 行 `Total number in stack`，引擎到第 4387 行）；排除 `Total number in stack` / `Sort by top of stack` / `Binary Images`。
  - 线程头行 `^    (\d+) Thread_...` 的计数 = 该线程在 1ms 采样窗内的**在线墙钟**，不是 CPU。
  - CPU≈该线程的叶子/自采样，剔除阻塞帧（mach_msg、__workq_kernreturn、__psynch_cvwait、semaphore_wait、__semwait_signal、read、kevent、usleep、__ulock_wait、pthread_mutex/rwlock 等）。
  - 采样窗：UI N=12,953（≈12.95s），引擎 N=13,332（≈13.33s）。
  - 每个线程块自采样求和均与头计数做过分区校验。

## 1. 进程总量

| 进程 | 采样窗N | CPU估计(叶子采样) | 折合单核 |
|---|---:|---:|---:|
| UI (pid 93544) | 12,953 | 982 | **7.58%** |
| Engine (pid 93564) | 13,332 | 2,503 | **18.77%** |
| 合计 | — | 3,485 | **≈26.3%** |

（两者合计约 26% 单核；由于 sample 是统计近似，按 ±个位数百分比看待。）

## 2. 线程归因总表

### 2.1 UI 进程（pid 93544，N=12,953）

| 线程 / 队列 | 采样数(CPU/在线) | 占单核 | 占进程CPU | 在干什么 | 必要? |
|---|---|---:|---:|---|---|
| Main Thread `Thread_14385116` | 837 / 12,953 | 6.46% | 85.2% | SwiftUI 布局/渲染、CALayer 图像转换、UI 轮询 | 必要，但可优化 |
| `com.apple.audio.IOThread.client` `14385203` | 80 / 12,953 | 0.62% | 8.15% | 静音音频（防降频） | 必要（设计） |
| `com.apple.libdispatch-manager` | 18 / 23 | 0.14% | 1.83% | dispatch 定时器管理 | 必要 |
| `com.aurora.coordinate-capture` `14385346` | 13 / 12,953 | 0.10% | 1.33% | BPF 坐标采集，几乎全程阻塞 | 视需求可做生命周期门控 |
| `com.aurora.tick` | 6 / 8 | 0.05% | 0.61% | UI tick | 必要 |
| Pasteboard override 队列 | 6 / 6 | 0.05% | 0.61% | 系统剪贴板 | 必要 |
| 其余短队列(RenderBox/netlocate/CA/Metal) | ~25 | ~0.2% | ~2% | 零散系统任务 | 必要 |
| 7 条平台常驻线程(2×ANEServices、AQConverter、4×workq/未命名) | 0 / ~12.9k | 0% | 0% | 基本全程空闲 | 休眠，非泄漏 |

UI 主线程内部构成（占主线程运行采样）：
- SwiftUI 布局 245（29.3%）
- vImage/CoreGraphics 图像/色彩转换 163（19.5%）
- Swift/ObjC 运行时 153（18.3%）
- 其他 121（14.5%）
- 系统调用/内存操作 50（6.0%）
- 内存/ARC 44（5.3%）
- CoreAnimation 渲染 41（4.9%）
- IOKit/GPU 提交 20（2.4%）

主线程 Top 叶子：`AG::Graph::UpdateStack::update()` 39、`vLookupTable_Planar16WithClipping` 36、`_platform_memmove` 28、`AG::Subgraph::update` 26、`vLookupTable_Planar8toPlanar16` 25、`vUnpremultiplyData_RGBA8888_CV_vec` 22、`AG::Graph::propagate_dirty` 22、`iokit_user_client_trap` 20。

UI 业务侧可见热点（占主线程 CPU）：
- `ObstacleOverlay.body.getter` 25（3.0%）
- `DriveState.pushEngineConfigIfChanged()` 17（2.0%）
- `FrameHost.push(_:)` 9（1.1%）
- `Data.init(bytes:count:)` 6、`EngineClient.poll()` 5、`remoteDetections` setter 5、`EngineClient.handleHeartbeatLine` 4、`RunLogCard.rows` 4

### 2.2 引擎进程（pid 93564，N=13,332）

| 线程 / 队列 | 采样数(CPU/在线) | 占单核 | 占进程CPU | 在干什么 | 必要? |
|---|---|---:|---:|---|---|
| `com.aurora.capture` | 516 / 519 | 3.87% | 20.6% | ScreenCaptureKit 帧处理，活跃时几乎满负荷 | 必要（是瓶颈） |
| `com.aurora.yolopx` | 483 / 780 | 3.62% | 19.3% | Yolopx 推理 + 掩码提取，活跃时 61.9% 忙 | 必要 |
| `com.aurora.inference.v2` | 421 / 662 | 3.16% | 16.8% | V2 预处理/推理，活跃时 63.6% 忙 | 必要 |
| 19 条全局 QoS 工作线程 | 677 / 694 | 5.08% | 27.1% | 短命 `_dispatch_apply` 工作块，多为 vImage 转换 | 多半必要（并行转换） |
| 主线程串行队列 | 119 / 123 | 0.89% | 4.75% | PointerHeadingReader、Yolopx 掩码后处理、tick/publish | 必要 |
| 引擎音频 IO 线程 | 95 / 13,332 | 0.71% | 3.8% | 静音音频（防降频） | 必要（设计） |
| Engine Main Thread `14385168` | 74 / 13,332 | 0.56% | 2.96% | 混杂 capture/Yolopx/V2 工作 | 必要 |
| `com.aurora.speedocr` | 37 / 46 | 0.28% | 1.48% | 速度 OCR | 必要 |
| `com.aurora.inference`（legacy） | 26 / 98 | 0.20% | 1.04% | 旧推理路径/后台 | 存疑（见§4） |
| `com.aurora.confidence.brightness` | 15 / 16 | 0.11% | 0.60% | 亮度置信度 | 必要 |
| `aurora.engine.tick` | 3 / 5 | 0.02% | 0.12% | 15/20Hz tick 本体 | 必要 |
| 20 条近空闲平台线程(AQConverter、5×ANEServices、NSEvent、workq 池) | 0 / ~13k | 0% | 0% | 空闲 | 休眠 |

引擎进程类别构成（占引擎 CPU）：
- vImage/CG 图像转换 **871（34.8%）**
- IOKit/GPU 提交 **407（16.3%）**
- Aurora 推理代码 **349（13.9%）**
- CoreML/BNNS **328（13.1%）**
- Swift/ObjC 运行时 156（6.2%）
- 系统调用/内存操作 128（5.1%）
- 其他 113（4.5%）
- 音频 88（3.5%）
- 内存/ARC 35（1.4%）
- GCD 调度 21（0.8%）
- CA 渲染 7（0.3%）

引擎业务归属（占引擎 CPU）：
- `closure #1 in YolopxEngine.infer` 391（15.6%）
- `CaptureEngine.copyNativeFrame` 390（15.6%）
- `closure #2 in InferenceEngineV2.infer` 290（11.6%）
- `YolopxEngine.extractMask` 267（10.7%）
- `InferenceEngineV2.preprocessImage` 139（5.6%）
- `CaptureEngine.stream` 闭包 118（4.7%）
- `PointerHeadingReader.prepareFrameBuffer` 27、`SpeedOCRReader.grayscalePixels` 21、`YolopxEngine.positiveRatios` 18、`YolopxEngine.smoothMask` 16、`EngineMain.tickOnce` 14
- 未归属系统框架 668（26.7%）

`com.aurora.capture` 细节：
- 375 采样子 `iokit_user_client_trap`，路径 `CaptureEngine.copyNativeFrame → CVPixelBufferLockBaseAddress → IOSurfaceClientLock`。
- 96 采样子 `vImageScale_ARGB8888`（UI 显示帧 480 宽压缩路径）。
- `copyNativeFrame` 只拷 `speedROINorm`（≈100KB），成本不在 ROI memcpy，而在 IOSurface/IOKit 锁基址 + 缩放。

`com.aurora.yolopx` 细节：`extractMask` 254 自采样；`argb32_sample_rectilinear_argb32` 86；BNNS 60；memset 11；IOKit 8。letterbox 仍走 CGContext（源码中 vImage 快路径未启用）。

`com.aurora.inference.v2` 细节：BNNS 125；CoreGraphics 重采样 39+23；`preprocessImage` 21；CFNumber 12；memmove 10。`preprocessImage` 用 CGContext + 逐像素 float 转换。

## 3. 锁竞争分析

**结论：未发现实质锁竞争。**

- UI 主线程：`os_unfair_lock` 9、`pthread_mutex` 2、`__psynch_mutex` 1（≈0.07% 墙钟），非持续争用。
- UI `AQConverterThread`：`__psynch_cvwait` 12,953（整窗）——音频转换器空闲等待，不是锁竞争。
- UI 音频 IO：`semaphore_wait_signal_trap` 12,873——音频握手/节拍，不是锁。
- UI 坐标采集：`read()` 10,731 + `__semwait_signal` 2,197（≈99.9% 墙钟阻塞），CPU 仅 0.10%。
- 引擎 `AQConverter`：`__psynch_cvwait` 13,332（整窗空闲）。
- 引擎音频 IO：`semaphore_wait_signal_trap` 13,237。
- 引擎一条未命名线程：`__sigsuspend_nocancel` 13,332。
- 真实 mutex/rwlock 采样均为个位数：V2 3、SpeedOCR 3、output-port binder 1–2 等。
- `__ulock_wake` 是唤醒不是等待。

**谁能持有锁 / 等多久**：sample 只能看到「线程在等某个内核对象」，**无法给出锁持有者，也无法给出离 CPU 原因**；本窗口内**没有任何线程在应用内互斥锁上阻塞出有意义的时长**。

## 4. 可疑线程清单（跑了但产物无人消费 / 纯空转）

1. `fixed_ui_sample.txt` **Call graph 为空**（0 个线程块）：无法与基线对比，所有「另一版本」结论记为**未测**。
2. UI 7 条、引擎 20 条平台常驻线程：整窗近乎 0 自采样，属 ANE/AQ/NSEvent/workq 池，**休眠而非泄漏**。
3. `com.aurora.coordinate-capture`：常驻轮询，≈99.9% 阻塞在 `read()`/semwait，CPU 仅 0.10%——不是 CPU 浪费，但若坐标采集只在定位时需要，可做**生命周期门控**。
4. `com.aurora.speedocr` 调试图：`SpeedOCRReader.swift:634` 调 `saveOCRDebug`（实现 `:1476`，最短间隔 10s `:1481`）。仅 4 个采样，疑为无生产消费方的诊断输出，**低优先级**。
5. Quest OCR：现有源码已在引擎进程侧加了门禁（`AuroraDriveApp.swift:7242` `isEngineProcess`、`:7243` `!AuroraFlags.questOCR...!EngineClient.shared.isActive`）。旧注释称曾浪费≈4.8% 单核，但当前引擎 sample **未见 Vision/Quest 线程**，记为**未复现/已修**。
6. 两个进程各有一条静音音频循环：UI ≈0.62% + 引擎 ≈0.71% 单核。用户明确其为防降频必需，**不算浪费**；仅把「是否需要双份循环」作为设计问题提出。

> 注：`[ENGINE] 统计` 中的 `det=0` 是 `EngineMain.swift:1338` 的 `yoloEngine.detections.count`（旧 yolo26s 计数），**不是** `yolopxEngine.detections`。不可据此判定 Yolopx/掩码产物无人消费。

## 5. Top 3 最值得优化的线程级问题

1. **引擎「抓屏 + 推理预处理」图像链路**（占引擎 CPU 56.7%）
   - `com.aurora.capture` 20.6%、`yolopx` 19.3%、`inference.v2` 16.8%。
   - `CaptureEngine.copyNativeFrame`（`Sources/AuroraDrive/Capture/CaptureEngine.swift:1319`）：IOKit/IOSurface 锁基址路径；UI 帧 480 压缩在 `:1190`。
   - `YolopxEngine.extractMask`（`Sources/AuroraDrive/Inference/YolopxEngine.swift:1280`）：letterbox 仍走 CGContext（`:1663`）。
   - `InferenceEngineV2.preprocessImage`（`Sources/AuroraDrive/Inference/InferenceEngineV2.swift:3056`）：CGContext 绘制 + 逐像素 float。
   - 产物被控制/显示消费，属必要工作；可优化点是图像格式转换与 IOSurface 锁结构。

2. **UI 主线程**（占 UI 进程 CPU 85.2%，6.46% 单核）
   - `FrameHost.push`（`Sources/AuroraDrive/App/AuroraDriveApp.swift:9035`）赋 `layer.contents` 触发 CoreAnimation `copy_image` 与 vImage 色彩转换。
   - `ObstacleOverlay` Canvas（`:8948`）、`Text.resolve`（`:8967`）；UI tick/轮询在 `:6687`、`:6717`。
   - 主线程 SwiftUI 布局占 29.3%、vImage/CG 转换占 19.5%。

3. **引擎全局 QoS 扇出**（19 条工作线程，占引擎 CPU 27.1%，5.08% 单核）
   - 主导叶子 `vConvert_ARGB8888toPlanarF_CV_vec` 等 vImage 转换；父栈压在 `_dispatch_apply` 下。
   - 多为 CoreML/vImage 内部并行转换，而非独立业务流水线。方向：统一输入格式、复用缓冲、限制并发；具体 Aurora 调用方需 Instruments 复核（sample 无法定位）。

## 6. 未测项与解析方法局限

- `fixed_ui_sample.txt` 无 Call graph，**该版本全部未测**。
- `sample` 是 1ms 统计采样：占比为**近似值**，不代表精确 CPU 时间；线程头计数是**在线墙钟**而非 CPU。
- `iokit_user_client_trap` 计入「活跃 IOKit 工作」，但可能含阻塞内核时间，**可能高估 capture 实际占用 CPU**。
- `sample` **不提供锁持有者与离 CPU 原因**，锁竞争只能从等待帧推断。
- `_dispatch_apply` 折叠栈中的确切 Aurora 调用方无法从 sample 还原，需 Instruments。
- 日志统计：836 条 `[ENGINE] 统计`，`driving=true` 21.4%；`耗时` p50 7.1ms / p95 15.3ms / max 72.7ms / mean 6.23ms（跨多会话全量）。tick `total` p50 0.330ms / p95 0.620ms / max 2.670ms → 15Hz 下 ≈0.5% 单核，证明 **tick 不是主要 CPU 来源**。
- 所有百分比均来自上述静态文件，未启动任何程序、未联网、未改动源码/models。
