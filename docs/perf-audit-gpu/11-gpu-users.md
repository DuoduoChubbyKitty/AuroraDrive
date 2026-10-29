# 11. GPU 使用点全清单（2026-10-25 全仓扫描 + 实测）

> 起因：用户问「整个仓库里边还有哪一个是用 GPU 的？」
> 本文只写**扫得到、测得到**的事实。未测的一律标 **未测**。

---

## 0. 结论速览

全仓**确实有 GPU 代码**，共 9 类使用点。按「默认是否真的在提交 GPU 工作」排序：

| # | 位置 | 是什么 | 默认会不会跑 GPU | 实测 GPU | 能否改 CPU |
|---|---|---|---|---|---|
| 1 | `Vendor/MetalGoose/Engine/`（**编进主 target**） | Metal 插帧/超分引擎（`MTLTexture` 85 处 / `MTLDevice` 8 / `MTLCommandQueue` 4） | **启动即建 Metal 设备+命令队列+编译着色器**；但**逐帧渲染默认关**（`upscaleEnabled = false`） | 自检渲染 **4.76%**；默认配置整体 **0.76%** | 关插帧即可（**已是默认**）；彻底删需动 Vendor |
| 2 | `AuroraDriveApp.swift:9096` | `MTLCreateSystemDefaultDevice()`（`UpscaleFrameHost.attach`） | 仅 `upscaleEnabled == true` 才 attach MTKView | 同上 | 同上 |
| 3 | `YolopxEngine.swift:746` | CoreML `.all`（A 模型档主力，三合一） | **是**，默认加载并每帧推理 | 栈采样 **GPU 0**（289 ANE + 2 CPU） | 已试过 `.cpuAndNeuralEngine`，**更慢**（ABBA 实测后退回） |
| 4 | `InferenceEngine.swift:164` / `:206` | CoreML `.all`（`m9_mono` / `game_assist_control`） | `assistEngine` **每次启动必加载**，e2e 档每 5 帧保活推理 | **未测** | 未知，需实测 |
| 5 | `InferenceEngineV2.swift:1733` | CoreML `.all`（V2 单模型路径） | 仅**拆模失败**时才走 | **未测**（默认不走） | 未测 |
| 6 | `InferenceEngineV2.swift:1881` | CoreML `.all`（后台兜底加载） | 仅拆模失败/加载失败时 | **未测** | 未测 |
| 7 | `YoloEngine.swift:187` | CoreML `.all`（`yolo26s`） | 仅 **legacy 档**加载（默认 A 模型档**不加载**） | **未测** | 未测 |
| 8 | `ConfidenceEstimator.swift:237` / `SpeedOCRReader.swift:835` | `CIContext`（默认会走 Metal） | **默认关闭**，两处都有环境变量回退开关 | 默认 **0** | 已是纯 CPU 直读（无需改） |
| 9 | `src/train_*.py`、`tools/train_*.py` 等 8 个脚本 | PyTorch **MPS**（`torch.backends.mps`） | **离线训练工具，不参与运行时** | — | 可 `--device cpu` |

另外还有两个**离线 GPU 压测工具**，不参与运行时：
`tools/exp_exec_gpu_burn.swift`（`MTLCreateSystemDefaultDevice` + `makeCommandQueue` + `makeComputePipelineState`，主动烧 GPU）、
`tools/exp_exec_bench.swift`（只查设备是否可用）。
注意 `tools/` 与 `Tools/` 在本机（大小写不敏感）是**同一个目录**（inode 均为 `27586270`），不是两处重复。

---

## 1. 逐条证据（可复现命令）

### 1.1 MetalGoose 是真的 Metal 代码，且编进了主程序

```bash
# 1) 确实编进主 target（Package.swift 的 sources 白名单只有两个目录）
$ grep -A3 'sources: \[' Package.swift
sources: [
    "Sources/AuroraDrive",
    "Vendor/MetalGoose/Engine",
],

# 2) 里面的 Metal 调用规模
$ for p in MTLTexture MTLDevice MTLCommandQueue MTLCreateSystemDefaultDevice makeComputePipelineState; do
    echo "$p $(rg -c "$p" Vendor/MetalGoose/ | awk -F: '{s+=$2}END{print s+0}')"
  done
MTLTexture 85
MTLDevice 8
MTLCommandQueue 4
MTLCreateSystemDefaultDevice 2
makeComputePipelineState 2
```

`GooseEngine.make()`（`Vendor/MetalGoose/Engine/GooseEngine.swift:420`）：

```swift
guard let dev = MTLCreateSystemDefaultDevice() else { ... }
guard let queue = dev.makeCommandQueue() else { ... }
```

### 1.2 每次 UI 启动都会建 Metal 设备与队列（**关键**）

`AuroraDriveApp.swift:6262`：

```swift
if !CommandLine.arguments.contains("--engine") {
    upscaleHost.prepare()                 // → GooseUpscaler.make() → MTL 设备 + 队列
    upscaleSupported = upscaleHost.isAvailable
    dlog("[upscale] 引擎初始化: 可用=\(upscaleSupported)")
}
```

实测日志（`/tmp/gpuwho.log`，默认配置启动）：

```
10:14:55 [upscale] 引擎初始化: 可用=true
```

⟹ **「不碰 GPU」不是「代码里没有 Metal」**，而是**开关层面的约定**：
设备与队列会建（一次性），但**逐帧渲染默认关闭**。

### 1.3 渲染确实被 `upscaleEnabled` 门控（默认 false）

```bash
$ grep -n 'var upscaleEnabled' Sources/AuroraDrive/App/AuroraDriveApp.swift
5330:    var upscaleEnabled: Bool = false          # 默认关

$ sed -n '586,596p' Sources/AuroraDrive/App/MissionConsole.swift
FrameHostView(host: state.frameHost)          # 原生直绘（不碰 GPU）
if state.upscaleEnabled {                     # ← 门控
    UpscaleFrameHostView(host: state.upscaleHost)
}
```

`MTKView` 只有在 `upscaleEnabled == true` 时才 attach，
`GooseEngine.swift:889` 的 `view.isPaused = false`（60fps 常开渲染）也只在 attach 后生效。

⚠️ 另注：`MissionConsole.swift:6824` 也有 `upscaleEnabled = true`，
但那在 `render(to:)` —— **离屏截图渲染**（`AuroraDriveLauncher` 调用），不是驾驶运行时。

### 1.4 Metal 渲染路径「真的会吃 GPU」—— 实锤

```bash
$ python3 /tmp/gpuwatch.py ./.build/scratch/release/AuroraDrive --upscale-selftest
进程 pid=98014 运行 10.1s  采样 15 次
  该进程 GPU: 累计 0.483s  平均 4.76%
  WindowServer: 累计 4.030s  平均 39.71%

$ cat /tmp/upselftest_result.txt
[UPSELFTEST] PASS 插帧工作 out 0→618 interp 0→329 fps 90
```

⟹ 插帧一旦真开，Metal 侧 **4.76%**（约等于吃掉半核 GPU 时间）。
这就是为什么默认必须关着——用户的硬要求是「游戏独占 GPU」。

### 1.5 默认配置下 Aurora 整体 GPU 占用

```bash
$ # A 模型档、插帧关（默认），跑 15s 采样
  pid=93213  AuroraDrive  0.76%   ← UI 进程
  pid=93256  AuroraDrive  0.00%   ← 引擎进程
  ⟹ Aurora 自身 GPU 合计: 0.76%
  （同期 WindowServer 53.19%、DeepSeek Harness 7.48%、QQ Helper 1.29%）
```

### 1.6 A 模型主力的 `.all` 为什么不算「抢 GPU」

`YolopxEngine.swift:746` 确实是 `config.computeUnits = .all`，
但 `sample` 栈采样证明 Espresso 实际派发是 **289 ANE + 2 CPU、GPU 0**
（详见 `2-yolopx.md` §2 与 §482）。代码里还记录了一次**失败的回退尝试**：
改成 `.cpuAndNeuralEngine` 后空载 204.6ms vs `.all` 183.0ms（**更慢 10.6%**），已回退。

### 1.7 两处 `CIContext` 默认都关

| 文件 | 默认路径 | 回退开关 |
|---|---|---|
| `ConfidenceEstimator.swift:274` | `averageBrightnessViaCPU`（纯 CPU 直读字节） | `AURORA_CONF_CI=1` |
| `SpeedOCRReader.swift:970` | `cgImageFromPixelBuffer`（纯 CPU 内存拷贝） | `AURORA_OCR_CI=1` |

且作者记录了官方头文件铁证：`CIContext.h:184` 写死
「此选项在平台不支持 OpenCL 时无效」，Apple Silicon 无 OpenCL ⟹
`useSoftwareRenderer: true` 会被**静默忽略**，照样走 Metal。
因此这两处的正确修法就是「不用 CIContext」，已经这么做了。

---

## 2. 仍未测（诚实声明）

- `InferenceEngine.swift` 的 `.all`（`m9_mono` / `game_assist_control`）实际派发到哪里：
  **未测**。它每次启动都加载、e2e 档每 5 帧跑一次保活心跳，是目前**最可能存在
  未量化 GPU 占用**的一处。
- `InferenceEngineV2.swift:1733` / `:1881` 两处 `.all`：默认路径不走，**未测**。
- `YoloEngine.swift:187`（legacy 档）：默认档位不加载，**未测**。
- Vision 框架（`QuestPanelReader.swift:649`、`LoginAssistant.swift:47`）
  内部是否用 ANE/GPU：**未测**（Vision 的调度不透明）。
  已知 quest OCR 有 `--engine` 门控（引擎进程不再白跑）。

---

## 2.5 已排除的 GPU 嫌疑（同样是实测，不是猜）

排查「还有谁用 GPU」时，下面几条**看起来像**、实测**都不是**：

| 嫌疑 | 实测结论 | 证据 |
|---|---|---|
| 录制链（UI 显示「录制 READY」） | **不碰 GPU** | `RecordEngine.swift` 只 `import AppKit/Foundation/Observation/CoreVideo`，写盘是 `NSBitmapImageRep.png`（:565/:631），**没有** `AVAssetWriter` / `VTCompressionSession` / 任何视频编码 |
| VideoToolbox 硬件编解码 | **全仓 0 处实际调用** | 唯一命中是 `OpticalFlowBridge.swift:16` 的**注释**：`Apple VTOpticalFlow（VideoToolbox 硬件）10.28ms ✗` —— 是被**否决**的方案（OpenCV DIS 1.91ms 胜出） |
| OpenCV 的 OpenCL/CUDA 路径 | **编译期就关了** | `Vendor/OpenCVFlow/README.md:72`：`-DWITH_OPENCL=OFF -DWITH_FFMPEG=OFF`；`cv::UMat`/`ocl::`/`cuda::` 全仓 **0 处** |
| MPSGraph / MPS 在应用内 | **0 处** | 应用内无 `import MetalPerformanceShaders`（采样里出现的 MPS* 是系统框架被 AppKit 拉进来的） |
| `CVPixelBufferGetIOSurface` 8 处 | 全在 `Vendor/MetalGoose/`，是插帧的 IOSurface↔Metal 互操作 | `Sources/` 里 **0 处** |

### 栈采样归因：UI 进程里的 Metal 活动是谁？

默认配置跑驾驶态，`sample` UI 进程 5 秒，Metal 相关帧全部来自
**AppKit/CoreAnimation 自身绘制窗口**，不是 MetalGoose：

```
RB::DisplayList::render(RB::DisplayList::Contents const&, ... id<MTLTexture>)   ← RenderBox
RB::SurfacePool::alloc(... MTLPixelFormat ...)                                  ← RenderBox
-[AGXG15GFamilyCommandBuffer renderCommandEncoderWithDescriptor:]
-[_MTLCommandQueue submitCommandBuffer:]
IOGPUMetalCommandQueue submitCommandBuffers:count:
```

```
$ grep -cE 'GooseEngine|GooseUpscaler|MetalGoose' /tmp/samp_2138.txt
0
```

⟹ 插帧关着时，**MetalGoose 一行调用栈都采不到**。
（任何 macOS 窗口应用画自己的窗口都会走这条 AppKit 路径，与本项目代码无关。）

### 总量上界（**只覆盖 Aurora 自己的进程**，不含 WindowServer —— 见 §2.6）

⚠️ **口径限制**：下面这个数只统计 `IOUserClientCreator` = Aurora 自己 pid 的 GPU 账户。
它**不含**「把画面合成到屏幕上」那笔账（那笔记在 WindowServer 名下）。
用户问「显示画面不也是 GPU 吗」——是的，那部分在 §2.6，实测 **+12.82pp**，
比本节的 0~1% 大一个数量级。**不要用本节数字回答「显示是否用 GPU」。**

默认配置实测（15s，`ioreg` 按 pid 归因，父子关系已用 `ppid` 核实）：

```
第 1 次：
  UI 进程    pid=93213  AuroraDrive  0.76%
  引擎进程    pid=93256  AuroraDrive  0.00%     （child of 93213）
  ⟹ 合计 0.76%

第 2 次（同配置复测，15s）：
  UI 进程    pid=5627   AuroraDrive  0.01%
  引擎进程    pid=5655   AuroraDrive  0.00%     （child of 5627，argv 含 --engine）
  ⟹ 合计 0.01%
```

两次分别 **0.76% / 0.01%**，说明这个量级本身在抖动（本机测量噪声见 §4）。
诚实的表述是：**Aurora 自身 GPU 占用在 0～1% 量级**，不是精确的 0.76%。

引擎进程的 GPU 恒为 **0.00%**（两次都是），这与 `.cpuOnly`/`.cpuAndNeuralEngine`
的档位设计一致。UI 进程那 0.76%/0.01% 里包含：CoreML 推理（`assistEngine` 等）、
MetalGoose 的一次性设备/着色器准备、以及 AppKit 画窗口（§2.5 已归因）。

⟹ 这也顺带回答了「`m9_mono`/`game_assist_control` 的 `.all` 到底吃多少 GPU」——
它们无论派到哪个设备，都被封在这个 **0～1% 的总量**里（都在 UI 进程内）。

---

## 2.6 「画面显示到屏幕上」这一步的 GPU 代价 —— 实测 +12.82pp

> 这是用户直接问的一点，也是上一版本文的**重大遗漏**：
> `ioreg` 按 pid 归因只能看到「Aurora 自己提交了多少 GPU 工作」，
> 而「把画面合成到屏幕上」发生在 **WindowServer** 进程里，记在它账上。

### 实验设计（同进程 显/隐 交错，只动一个变量）

| 要素 | 做法 |
|---|---|
| 唯一变量 | 窗口**是否被 WindowServer 合成到屏幕**（`vis_toggle2`：`app.hide()` + AX `orderOut`/最小化） |
| 保持不变 | 抓屏、推理、`layer.contents` 写入 **全部照旧**（该路径无遮挡门控，见下） |
| 抗噪 | 同一进程内交错 3 轮（本机 WindowServer 基线漂移可达 ±10pp） |
| **防伪门禁** | 每相位都必须确认**引擎帧数仍在增长** —— 否则测到的是「工作停了」而非「省了 GPU」 |

### 结果（`/tmp/vis_ab3_out.log`，2026-10-25 11:29）

```
  R1 显  WS= 63.33% Aurora=0.02% 帧增=221 在屏=True
  R1 隐  WS= 46.55% Aurora=0.15% 帧增=225 已隐=True
  R2 显  WS= 50.29% Aurora=0.00% 帧增=421 在屏=True
  R2 隐  WS= 37.62% Aurora=0.00% 帧增=225 已隐=True
  R3 显  WS= 50.45% Aurora=0.00% 帧增=225 在屏=True
  R3 隐  WS= 37.64% Aurora=0.00% 帧增=225 已隐=True

显 中位数 = 50.45%
隐 中位数 = 37.64%
每对差值(显−隐) = [+16.78, +12.66, +12.82]   三对同向 ✓
⟹ 合成上屏代价 中位数 = +12.82 pp（记在 WindowServer 账上）
   帧数未增长相位数: 0/6  ✓ 工作未停（排除"隐藏后抓屏/推理停了"的伪结论）
```

### 三条必须分清的事实

1. **「显示画面」确实吃 GPU，量级 ≈ +12.82pp**，比插帧引擎全开（4.76%）还大。
   但这笔账在 **WindowServer**，不在 Aurora 的两个进程里。
2. **Aurora 自己进程的 GPU 始终 0.00~0.15%** —— 与 §1.5 的 0~1% 一致，不矛盾。
3. **隐藏窗口后抓屏与推理照跑**（帧增仍 225，就连隐藏相也一样）。
   这不是 bug：预览推屏路径**没有遮挡门控**
   （`AuroraDriveApp.swift:7189` `if isStreaming { latestCGToPush = latestCG }`，
   对比插帧层 `:9105-9143` 的 `installOcclusionGuard` 是**有**门控的）。
   但这**不是「显示开销」本身**，而是「被完全遮挡时仍在提交合成」——
   属可治理项，前提是不能降低可见时的画质/帧率。

### 与仓库既有记录的关系（不掩盖矛盾）

`docs/perf-audit-gpu/6-windowserver.md` §3 记有一组单因子对照：
`Aurora 关 51.2% → 开 81.9%（+30.7%）`，其中「背景漂移动画」一处就占全部 30pp，
关掉后回到 51.9%。那次测的是**整个 App 开/关**（含背景漂移、窗口数变化等），
本文测的是**同一进程内只切可见性**（动画/窗口数/抓屏全不变）——两者不冲突，
但**都不是**「单独测画面显示」的直接计时；本文的 +12.82pp 更接近该问题，
因为它把「App 存在」与「画面在屏」两个变量分开了。

---

## 3. 一句话回答

**真正用 GPU 的首先是「把画面显示到屏幕上」这一步**（实测 **+12.82pp**，
记在系统 WindowServer 账上、不在 Aurora 进程里）；
其次是 **MetalGoose 插帧引擎**（`Vendor/MetalGoose/Engine`，编进主程序、
启动即建设备与队列），但它**逐帧渲染默认关闭**，开了才会到 4.76%；
其次是 **CoreML 的 6 处 `.all` 档位**（分布在 4 个文件：`InferenceEngine.swift:164`/`:206`、
`YolopxEngine.swift:746`、`YoloEngine.swift:187`、`InferenceEngineV2.swift:1733`/`:1881`），
其中 A 模型主力实测 **GPU 0**，其余**未测**（但整体被封在 UI 进程 0～1% 的总量内）。
对照组：`.cpuOnly` **8 处**、`.cpuAndNeuralEngine` **4 处**。
其余 `CIContext` 与 Python MPS 要么默认关、要么是离线工具。
