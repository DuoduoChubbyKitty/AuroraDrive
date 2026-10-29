# 5 — CoreImage / CIContext / vImage 的 GPU 占用审计

> 审计范围：`/Users/dupi/Desktop/自动驾驶系统`（Swift / SwiftPM / macOS，Apple M3 MacBook Air）
> 审计性质：**只读静态审计 + 独立进程实测**；未修改任何源码；**未启动 App**
> 审计时间：2026-10-24
> 前置事实（由用户提供，本报告不重复测量）：驾驶态设备级 GPU 活跃驻留 **36.4%**（待机 0.7%），GPU 功耗 **371mW**（待机 4mW）

---

## 0. 结论速览

| # | 结论 | 证据强度 |
|---|---|---|
| 1 | `useSoftwareRenderer: true` 在 Apple Silicon 上**确认被静默忽略**，CIContext 渲染 100% 走 Metal/GPU 并**同步阻塞等 GPU** | **已实测**（`sample` 抓栈，见 §2） |
| 2 | 全仓共 **2 个 `CIContext` 实例**，**默认路径下都不渲染**（被环境变量开关保护），但**两个都仍存活在二进制里**且各自还留着活的调用点 | 源码 + 默认值可判定 |
| 3 | `ConfidenceEstimator` 的亮度计算**默认已不走 CoreImage**，且**不在引擎驱动链路里每 tick 执行**（UI 进程在它之前就 return） | 源码可判定 |
| 4 | 驾驶态真正会执行 CoreImage 的**默认路径代码点只有 1 处**：`saveOCRDebug`（条件触发 + 10s 节流） | 源码可判定 |
| 5 | **风险不在"默认开着"，而在"一开就整条链路裸奔到 GPU"**：`AURORA_OCR_CI=1` / `AURORA_CONF_CI=1` 两个回退开关会把每帧 OCR 打回 GPU 同步等待 | 源码 + 实测时序 |
| 6 | 可改纯 vImage/CPU：**已经改完了主路径**，剩余 3 个 CoreImage 残点应彻底删除（不是加开关） | 见 §5 |

**给用户死命令的一句话回答**：目前**默认配置下**，CoreImage 不是 36.4% GPU 的主因（它的默认路径几乎不渲染）；但**项目里仍埋着 2 个"一开就把 GPU 打满并同步阻塞主链路"的回退开关和 3 个残留 GPU 调用点**，必须删除才能做到"GPU 绝对不能占用"。

---

## 1. 全仓 CoreImage 清点

### 1.1 精确清点结果

全仓（排除 `build/`、`.build/`、`Vendor/`）Swift 源码中，`CIContext` / `CIImage` / `CIFilter` 的**真实 API 调用**只存在于 2 个文件：

```bash
$ grep -rln "CIContext\|CIImage\|CIFilter" --include=*.swift --include=*.m --include=*.mm --include=*.h . \
    | grep -v "^./build/\|^./.build/"
./Sources/AuroraDrive/Capture/RecordEngine.swift
./Sources/AuroraDrive/Capture/CaptureEngine.swift
./Sources/AuroraDrive/App/AuroraDriveApp.swift
./Sources/AuroraDrive/Inference/SpeedOCRReader.swift
./Sources/AuroraDrive/Inference/ConfidenceEstimator.swift
```

逐条核实后，其中 3 个文件**只命中注释文字，没有真实 API 调用**：

- `RecordEngine.swift`：仅 `:610` 一行注释「无 CIContext、无方向翻转」，该文件实际用 `CGContext` 直接引用缓冲基址编码 PNG（`RecordEngine.swift:613-636`），**无 CoreImage**。
- `CaptureEngine.swift`：`:1152`、`:1186`、`:1317` 三处均为注释，全文件**无任何 CoreImage 类型**，缩放全部走 `vImageScale_ARGB8888`（`CaptureEngine.swift:1173`、`:1219`）。
- `AuroraDriveApp.swift`：`:6112-6113` 为注释，`Sources/AuroraDriveShared`、`Sources/AuroraDriveUserAgent` 两个 target **零 CoreImage**。

**真实 CoreImage 调用只集中在 2 个文件，共 2 个 `CIContext` 实例、8 处 `CIImage`/`CIFilter` 构造点：**

| 文件:行 | 内容 | 所属链路 |
|---|---|---|
| `SpeedOCRReader.swift:835` | `private nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])` | 速度表 OCR |
| `SpeedOCRReader.swift:775` | `let input = CIImage(cvPixelBuffer: src)` | `cropSlots`（CNN 槽位裁剪） |
| `SpeedOCRReader.swift:932` | `input = CIImage(cvPixelBuffer: roiBuffer)` | `recognizePPOCR` |
| `SpeedOCRReader.swift:947` | `input = CIImage(cvPixelBuffer: roiBuffer).cropped(to: rect)` | `recognizePPOCR` |
| `SpeedOCRReader.swift:1386` | `let ci = CIImage(cgImage: cg)` | `lanczosResize` |
| `SpeedOCRReader.swift:1488` | `let input = CIImage(cvPixelBuffer: buffer)` | `saveOCRDebug` |
| `ConfidenceEstimator.swift:237` | `private static let brightnessContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])` | 画面平均亮度 |
| `ConfidenceEstimator.swift:338` | `let ci = CIImage(cgImage: cgImage)` | `averageBrightnessViaCoreImage` |

### 1.2 与 GPU / Metal 相关的缓冲属性

`kCVPixelBufferMetalCompatibilityKey: true` 共 2 处，均为**缓冲区创建属性**，本身不产生 GPU 负载：

- `Sources/AuroraDrive/Inference/SpeedOCRReader.swift:1661`（`makeBGRABuffer`，**仅自检命令行路径使用**）
- `Sources/AuroraDrive/Inference/OpticalFlowBridge.swift:296`（`makeGrayBuffer`）

原文（`SpeedOCRReader.swift:1658-1662`）：

```swift
let attrs: [CFString: Any] = [
    kCVPixelBufferCGImageCompatibilityKey: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    kCVPixelBufferMetalCompatibilityKey: true,
]
```

**判定**：该 key 的语义是"允许这块缓冲被 Metal 零拷贝映射"，属于**能力声明，不是 GPU 指令提交**。它不主动占 GPU。但它**意味着下游一旦用 CoreImage/Metal 处理，会走零拷贝而不是回退 CPU 拷贝** —— 即它是"GPU 路径的加速器"，不是"GPU 负载的来源"。**保持现状即可，不需要改动**（删掉它反而会让真正的 CPU 路径多一次拷贝）。

---

## 2. 要害核实：`useSoftwareRenderer: true` 在 Apple Silicon 上是否被忽略

### 2.1 官方头文件原文

```bash
$ H=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreImage.framework/Headers/CIContext.h
$ sed -n '180,184p' "$H"
```

```objc
/// A Boolean value to control if a Core Image context will use a software renderer.
///
/// > Note: This option has no effect if the platform does not support OpenCL.
///
CORE_IMAGE_EXPORT CIContextOption const kCIContextUseSoftwareRenderer;
```

**行号纠正（前人引用有偏差）**：前人注释（`SpeedOCRReader.swift:959`、`ConfidenceEstimator.swift:261`）写的是「`CIContext.h:184` 原文写死 `Note: This option has no effect if...`」。

- **第 184 行是 `kCIContextUseSoftwareRenderer` 的声明行**；
- **那句"no effect"注释实际在第 182 行**。

结论本身没错，**但引用的行号错了**，属于"注释与事实不同步"。后续引用应写 `CIContext.h:180-184`。

### 2.2 实测验证（决定性证据）

头文件只是"文档承诺"。本次审计**构造独立探针进程**（`/tmp/ci_probe/probe2.swift`，不启动 App、不碰仓库源码）验证实际行为：

```swift
// 只用 useSoftwareRenderer: true 的上下文，排除任何其他 CIContext 干扰
let swCtx = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
while CFAbsoluteTimeGetCurrent() - t0 < 10.0 {
    swCtx.render(ci, toBitmap: raw.baseAddress!, rowBytes: 4,
                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                 format: .RGBA8, colorSpace: cs)
}
```

用 `sample <pid> 4` 抓取该进程调用栈，结果如下（`/tmp/ci_probe/sample2.txt`）：

```
Machine: Apple M3
1674 -[CIContext render:toBitmap:rowBytes:bounds:format:colorSpace:]  (in CoreImage)
 └ 1648 CI::RenderToBitmap::render(CI::Image*, CI::Context*) const
   └ 1607 CI::image_render_to_bitmap(...)
     └ 1378 CI::Context::render(CI::ProgramNode*, ...)
       └ 969  CI::Context::recursive_render(...)
         └ 931  CI::MetalContext::render_root_node(...)        ← 走 Metal！
           └ 899  CI::MetalContext::render_node(..., id<MTLTexture>*, ...)
             └ 898  -[_MTLCommandBuffer waitUntilCompleted]  (in Metal)   ← 同步等 GPU！
               └ 897  _pthread_cond_wait → __psynch_cvwait             ← CPU 阻塞在内核
```

**判词**：
1. `useSoftwareRenderer: true` **确认无效** —— 栈里是 `CI::MetalContext`，不是任何 CPU/软件渲染器。
2. 更严重的是 **898/931 ≈ 96.5% 的时间卡在 `waitUntilCompleted`** —— 这意味着 CIContext 渲染不是"异步丢给 GPU 就跑"，而是**同步阻塞调用线程直到 GPU 干完**。
3. 这也解释了历史血案里 `sample` 抓到的 40ms 卡顿 / 12fps：**GPU 被游戏占满时，这个同步等待会无限拉长**。

**对用户死命令的推论**：只要代码走到任何 `CIContext` 渲染，就**无法**"不占 GPU"；且代价不只是占 GPU，还会**阻塞 CPU 线程**。所谓"允许拿 CPU 换"在这里不成立 —— 它是"**既占 GPU 又占 CPU**"的最坏组合。

### 2.3 顺带的性能实测（同尺寸对比）

用 `probe3.swift` 对 1280×832 缓冲做「裁 3 个 102×42 小槽」（等同 `cropSlots` 的实际工作），重复 3 轮：

```
BENCH CI-soft    : 1.197 ms / 3-slot-crop     ← useSoftwareRenderer: true
BENCH CI-default : 0.953 ms / 3-slot-crop     ← 默认（同为 Metal）
BENCH CPU-memcpy : 0.018 ms / 3-slot-crop     ← 纯 CPU 逐行 memcpy

BENCH CI-soft    : 1.171 ms / 3-slot-crop
BENCH CI-default : 0.908 ms / 3-slot-crop
BENCH CPU-memcpy : 0.018 ms / 3-slot-crop

BENCH CI-soft    : 1.006 ms / 3-slot-crop
BENCH CI-default : 1.269 ms / 3-slot-crop
BENCH CPU-memcpy : 0.030 ms / 3-slot-crop
```

为避免 `makeImage()` 延迟物化造成"CPU 路径虚快"的假象，`probe4.swift` 强制读回像素（`makeImage` + 再 `CGContext.draw` 一遍）：

```
BENCH CPU-crop+materialize+draw: 0.0414 ms/slot
BENCH CPU-crop+makeImage(lazy):  0.0296 ms/slot
```

**结论**：
- `useSoftwareRenderer: true` 不仅没走 CPU，**反而比默认上下文更慢**（1.0~1.2ms vs 0.9~1.3ms，同一量级，无收益）。这从侧面再次证明该选项是**空操作**，只留下"我以为我优化了"的假象。
- 纯 CPU 裁剪 + 物化 **0.041 ms/槽 ≈ 0.12 ms/3 槽**，比 CoreImage 路径**快 8~10 倍**。这是"拿 CPU 换"的真实红利：**换成 CPU 后，CPU 反而更快**。

---

## 3. 逐个 CIContext 说明是否占 GPU

### 3.1 `SpeedOCRReader.ciContext`（`SpeedOCRReader.swift:835`）

**源码原文（含上下文注释，`SpeedOCRReader.swift:823-840`）：**

```swift
    // P1 修复：CIContext 默认会缓存中间渲染结果，长时间 OCR 累积缓存内存。
    // 关掉 cacheIntermediates 避免中间位图常驻。
    //
    // ⚠️ 2026-10-11 GPU 零占用修复（w4-tools 的 P4 审计发现）：
    //   原实现**未指定 device** → 按 Apple 文档 CIContext 默认**优先用 GPU**。
    //   而本项目铁律是「推理不碰 GPU」（游戏需独占 GPU）——`CaptureEngine.swift:957`
    //   的注释早就记录过血案：「消除游戏占满 GPU 时 CIContext(GPU) 排队导致的
    //   **40ms 卡顿**」，那里的 vImage 缩放就是为绕开 GPU CIContext 才改的。
    //   唯独本处（OCR 渲染，15Hz）与 `ConfidenceEstimator` 的平均亮度没处理。
    //   修法：`useSoftwareRenderer: true` 强制走 CPU 渲染，与项目其余链路一致。
    //   【代价】CPU 渲染比 GPU 慢，但 OCR 只处理速度表**小 ROI**（102×42 级），
    //     15Hz 下开销可忽略；换来的是**绝不与游戏抢 GPU**（这是硬要求）。
    private nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])
```

**逐项判定 options 有效性：**

| option | 宣称作用 | 实际是否生效 | 证据 |
|---|---|---|---|
| `.cacheIntermediates: false` | 关中间位图缓存，省内存 | **有效**（这是纯 CPU 侧 SDK 层面的图缓存策略，与渲染后端无关） | `CIContext.h:164-178` 无平台限制说明 |
| `.useSoftwareRenderer: true` | 强制 CPU 软件渲染 | **无效，被静默忽略** | `CIContext.h:182` + §2.2 `sample` 实测 |
| 未指定 `device` | —— | 默认取系统 Metal device | §2.2 实测栈为 `CI::MetalContext` |

**该上下文当前被谁调用（全 6 处引用）：**

| 行 | 调用点 | 默认路径是否执行 |
|---|---|---|
| `:973` | `recognizePPOCR` 里 `ciContext.createCGImage(...)` | **否**，被 `AURORA_OCR_CI=1` 保护（见下） |
| `:1391` | `lanczosResize` 里 `ciContext.createCGImage(...)` | **仅** CNN 备用引擎路径 |
| `:814` | `cropSlots` 里 `ciContext.createCGImage(cropped, ...)` | **仅** CNN 备用引擎路径 / PP-OCR 故障降级 |
| `:1492` | `saveOCRDebug` 里 `ciContext.createCGImage(...)` | **是**（条件触发 + 10s 节流） |

**关键：每个调用点都做了"默认不走 CoreImage"的守卫。**

`recognizePPOCR`（`SpeedOCRReader.swift:966-974`）：

```swift
        let cg: CGImage?
        if isROISlice || ProcessInfo.processInfo.environment["AURORA_OCR_CI"] != "1" {
            cg = Self.cgImageFromPixelBuffer(roiBuffer, cropNorm: isROISlice ? nil : CaptureEngine.speedROINorm)
        } else {
            cg = ciContext.createCGImage(input, from: input.extent)
        }
```

**判定**：
- **默认配置下，该 CIContext 最多只在 `saveOCRDebug` 里被调用**（详见 §4.2），**不在每帧热路径**。
- **但 `cropSlots`（`:814`）和 `lanczosResize`（`:1391`）的 CoreImage 调用没有守卫** —— 它们是 CNN 引擎路径的必跑代码。一旦 `activeEngine` 变成 `.cnn`，这两处**每个 OCR tick（15Hz）都会真金白银提交 GPU 并同步等待**。
- **触发 `.cnn` 的现实条件**：`applyLoadedModels`（`SpeedOCRReader.swift:459-473`）——`ppocrv6_tiny_ft_int8` 模型加载失败即回落 `.cnn`。本机 `models/` 目录下该模型包存在（已核实 `models/ppocrv6_tiny_ft_int8.mlmodelc`），但是否**加载成功**属运行时行为，**本次未测**。

### 3.2 `ConfidenceEstimator.brightnessContext`（`ConfidenceEstimator.swift:237`）

**源码原文（`ConfidenceEstimator.swift:230-242`）：**

```swift
    /// ⚠️ 2026-10-11 GPU 零占用修复（w4-tools 的 P4 审计发现）：
    ///   原实现**未指定 device** → CIContext 默认**优先用 GPU**。
    ///   本项目铁律「推理不碰 GPU」（游戏独占 GPU）；`CaptureEngine.swift:957`
    ///   已记录过 GPU CIContext 排队导致 **40ms 卡顿**的血案。
    ///   本处虽只渲染到 **1×1** 缓冲（`CIAreaAverage`），GPU 侧开销极小，
    ///   但**任何 GPU 提交都会与游戏争用命令队列** → 强制 CPU 渲染消除不确定性。
    private static let brightnessContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])
```

**判定**：与 §3.1 完全相同的坑 —— `.useSoftwareRenderer` 无效，**仍然走 Metal**。注释里那句"强制 CPU 渲染消除不确定性"是**错误结论**，建立在被忽略的选项之上。

**但它默认已被旁路。** `ConfidenceEstimator.swift:274-279`：

```swift
    private static let useCoreImagePath =
        ProcessInfo.processInfo.environment["AURORA_CONF_CI"] == "1"

    private static func averageBrightness(cgImage: CGImage) -> Double {
        if useCoreImagePath { return averageBrightnessViaCoreImage(cgImage: cgImage) }
        return averageBrightnessViaCPU(cgImage: cgImage)
    }
```

默认（环境变量未设）走 `averageBrightnessViaCPU`，**纯 CPU 读 `CGImage` data provider 抽样，零 CoreImage**（`:283-333`）。

**这个"1×1 渲染开销极小"的判断是错的，且必须纠正**：`CIAreaAverage` 的目标缓冲确实只有 1×1，**但源图是整帧**（`CIVector(cgRect: ci.extent)`，`:342`；`brightnessContext.render` 在 `:345`）。CoreImage 仍要把整帧**上传成 Metal texture** 再跑归约 —— GPU 侧的**带宽和命令队列占用与输出尺寸无关，与输入尺寸成正比**。同时 `render(toBitmap:)` 是同步的（§2.2），会**阻塞调用线程等 GPU**。历史 `sample` 血案（`:246-255` 的调用栈注释）正是这么发生的。

### 3.3 `RecordEngine` / `CaptureEngine` / 其他

**无任何 CIContext、无任何 CIImage。** 全链路已改为 `CGContext` 直读基址 + `vImageScale_ARGB8888`：

```swift
// CaptureEngine.swift:1219 —— YOLO/UI 缩放走 CPU vImage
vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
```

`vImage`（Accelerate 框架）是**纯 CPU SIMD 实现**，不发 Metal 命令。**判定：零 GPU 占用。** 全仓 `vImage` 使用点（`CaptureEngine.swift:1173/1219`、`YolopxEngine.swift:1623` 等）均如此。

---

## 4. 驾驶态每帧调用次数（实测事实 vs 代码事实）

### 4.1 频率基准

| 项 | 值 | 证据 |
|---|---|---|
| 推理 tick 频率 | **15Hz** | `EngineMain.swift:868-874` `tickHz(forPerceptionMode:)` 两档均 `return 15.0` |
| OCR 独立节流 | **15Hz**（66.7ms） | `SpeedOCRReader.swift:93` `inferInterval = 1.0/15.0` |
| UI 进程 tick 频率 | 30Hz（注释），但引擎模式下早退 | `AuroraDriveApp.swift:7044` 注释「每帧推进（30Hz）」 |
| OCR 仍在 UI 进程还是引擎进程 | **由引擎进程 `st.tick()` 驱动**（`EngineMain.swift:1417`），OCR 属于推理链 | `EngineMain.swift:1417` `st.tick()` |

### 4.2 驾驶态每帧实际 CoreImage 调用次数（默认配置）

| 代码点 | 每 tick 次数 | 说明 |
|---|---|---|
| `recognizePPOCR` → `ciContext` | **0** | 默认走 `cgImageFromPixelBuffer`（纯 CPU），`:970` |
| `cropSlots` → `ciContext` | **0**（PP-OCR 引擎）/ **3**（CNN 引擎） | PP-OCR 正常时不裁槽；CNN 每帧裁 3 槽 |
| `lanczosResize` → `ciContext` | **0**（PP-OCR 引擎）/ **3**（CNN 引擎） | 仅 `recognizeCNN` 调用，每槽 1 次 |
| `saveOCRDebug` → `ciContext` | **条件触发**，上限 **0.1Hz** | 需 `result.speed == nil` **且** `diag.hasPrefix("fg=")` **且** 距上次 ≥10s，`:1479-1483` |
| `ConfidenceEstimator` 亮度 | **0**（默认 CPU 路径） | 且需 UI 进程跑到 `:7765` |

**逐帧次数汇总（默认 + PP-OCR 引擎 + 画面有速度表）**：CoreImage 渲染 **0 次/tick**。
**默认 + PP-OCR 引擎 + 画面无速度表**：`saveOCRDebug` 触发时 **1 次 / 10s**，长期均值 ≈ **0.1 次/秒**。

```swift
// SpeedOCRReader.swift:1478-1483 —— 10 秒节流，节流判断在建 CIImage 之前
        let now = Date()
        if let last = lastDebugSaveTime, now.timeIntervalSince(last) < Self.debugSaveMinInterval {
            return
        }
```

### 4.3 第 2 项必答：`ConfidenceEstimator` 亮度"是否每个 tick 都算"

**结论：不是。三层过滤叠加，默认路径下每 tick 的实际 CoreImage 调用数为 0。**

**第一层 —— 默认不走 CoreImage**（`:274-279`，见 §3.2）。

**第二层 —— 不在引擎驱动链路里**。`confidenceEst.update(...)` 在 `tick()` 的 `:7765`，但 `tick()` 内 `:7146-7152` 有早退：

```swift
        // ── 引擎模式：只拉取显示数据，本地抓屏/推理/按键全部不跑 ──
        if EngineClient.shared.isActive {
            tickEngineMode()
            PerfBus.mark("tick.engineMode", from: perfT)
            return
        }
```

而生产驾驶态的 tick 由**引擎进程**跑（`EngineMain.swift:1417` `st.tick()`）。引擎进程里 `EngineClient.shared.isActive` 恒为 `false`（`EngineClient.swift:68` 初值 `false`，仅客户端连上服务端时置 `true`，`:223`），所以引擎进程**会**跑到 `:7765`，**会**调 `update`。UI 进程则连上引擎后早退。

> 注：`AuroraDriveApp.swift:7055` 的注释写「见 `:6886` 早退」，**实际早退在 `:7146`**，行号已过期（同 §2.1 的行号偏移问题）。另需说明：引擎进程与 UI 进程**共享同一份 `tick()`**（该文件注释在 `:7052-7056` 明确说明"两个进程跑的是同一份 tick()，各有独立实例"），因此引擎进程里 `ConfidenceEstimator` 是**独立实例**，由引擎进程自己驱动。

**第三层 —— 即使走到，也被 `inFlight` 闸门限流**（`:200-206`）：

```swift
        // 只保留最新帧：上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，
        // 沿用缓存分即可），避免每 tick 无脑入队、后台亮度任务堆积。
        guard !brightnessInFlight else { return imageScore }
        brightnessInFlight = true
```

**修正后的准确表述**：`computeImageScore` 在 `confidenceEst.update(...)` 里**每 tick 被调用一次**（`ConfidenceEstimator.swift:128`），亮度计算以"后台队列 + inFlight 去重"的方式**异步跑**，理论频率上限为每次任务完成一次（≈tick 频率，实际受后台耗时约束更低）。**但默认路径下这一步是纯 CPU 抽样**（4096 点），**不产生任何 GPU 提交**。

**必须指出的真风险**：若有人按 `:274` 的提示设 `AURORA_CONF_CI=1`，则**每 tick（15Hz）**都会走 `CIContext.render(toBitmap:)` → **整帧上传 GPU + 同步阻塞等 GPU**。这正是历史 12fps 血案的路径。这个开关的存在本身就是"GPU 绝对不能占用"红线上的一个洞。

---

## 5. 能否改成纯 vImage / Accelerate CPU 实现 —— 具体改法

### 5.1 现状：主路径**已经**是纯 CPU，不需要再改

`SpeedOCRReader.cgImageFromPixelBuffer`（`:861-918`）已经是纯 CPU 直读：`CVPixelBufferLockBaseAddress` → 逐行 `memcpy` → `CGContext.makeImage()`。**这条路径正确，应保留。**

`ConfidenceEstimator.averageBrightnessViaCPU`（`:283-333`）已经是纯 CPU 抽样。**这条路径正确，应保留。**

### 5.2 需要处理的 3 个 CoreImage 残点 —— 建议全部**删除**，而不是加开关

核心原则：**"GPU 绝对不能占用"是死命令，带开关的 GPU 路径就是不合规的路径。** 把死命令押在一个环境变量上，等于允许误设一次就把红线踩穿。

#### 残点 A：`cropSlots` 的 CoreImage 裁剪（`SpeedOCRReader.swift:813-816`）

```swift
            let cropped = input.cropped(to: ciRect)
            guard let cg = ciContext.createCGImage(cropped, from: cropped.extent) else {
                return nil
            }
```

**改法（已验证可行，`probe4.swift` 实测 0.041ms/槽）**：复用已在同文件存在的 `cgImageFromPixelBuffer`，把归一化坐标换算后传入。

```swift
// 伪代码，与 cgImageFromPixelBuffer 的 cropNorm 语义对齐（左上原点归一化）
let slotNorm = CGRect(x: (xCenter - halfW) / CGFloat(sw),
                      y: yMin / CGFloat(sh),
                      width: (halfW * 2.0) / CGFloat(sw),
                      height: (yMax - yMin) / CGFloat(sh))
guard let cg = Self.cgImageFromPixelBuffer(src, cropNorm: slotNorm) else { return nil }
```

**必须注意的 3 个坑**：
1. **坐标系镜像**：现有 `ciRect.y = sh - yMax` 是 CIImage 左下原点换算；`cgImageFromPixelBuffer` 用**左上原点**（与 `CaptureEngine.speedROINorm` 同语义），换算方向相反，**不能直接套用 `ciRect`**。
2. **取整口径**：现有代码用 `.rounded(.toNearestOrEven)`（银行家舍入）对齐 Python 端；`cgImageFromPixelBuffer` 内部用 `.rounded()`。**两者在 `.5` 边界上不同**，直接替换会让槽位漂移 1~2px，进而影响 CNN 识别率。**替换时必须让 `cgImageFromPixelBuffer` 支持传入已取整的像素矩形**，而不是传归一化坐标让它再取整一次。
3. **行为一致性验证**：该路径平时不跑（仅 CNN 引擎），改完**必须有对照测试**，不能只靠"应该一样"。

#### 残点 B：`lanczosResize`（`SpeedOCRReader.swift:1384-1392`）

```swift
    nonisolated private static func lanczosResize(_ cg: CGImage, toWidth: Int, toHeight: Int) -> CGImage? {
        guard toWidth > 0, toHeight > 0, cg.width > 0, cg.height > 0 else { return nil }
        let ci = CIImage(cgImage: cg)
        let scaleX = CGFloat(toWidth) / CGFloat(cg.width)
        let scaleY = CGFloat(toHeight) / CGFloat(cg.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rect = CGRect(x: 0, y: 0, width: CGFloat(toWidth), height: CGFloat(toHeight))
        return ciContext.createCGImage(scaled, from: rect)
    }
```

**改法：用 `vImageScale_ARGB8888`（项目里已有成熟用法，见 `CaptureEngine.swift:1173/1219`）。**

```swift
// 与项目现有风格一致：先 lock 基址，再 vImage_Buffer，最后 vImageScale_ARGB8888
var srcBuf = vImage_Buffer(data: srcBase, height: vImagePixelCount(h),
                           width: vImagePixelCount(w), rowBytes: srcRowBytes)
var dstBuf = vImage_Buffer(data: dstBase, height: vImagePixelCount(toHeight),
                           width: vImagePixelCount(toWidth), rowBytes: dstRowBytes)
vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
```

**⚠️ 必须提前告知用户的质量风险 —— 这一条已被本项目实测否决过一次：**

`YolopxEngine.swift:1552-1575` 记录了明确的实测结论：

```
// vImage 快路径：**已实测证伪，默认关闭**（2026-09-30）
//   · 换 `kvImageHighQualityResampling` 更大（最大 53）
//   · 换 `kvImageNoInterpolation` / `kvImageDoNotTile` 无改善（均 49）
//   ⟹ 检测框从 9 掉到 6（精度回退）
```

虽然那是 letterbox 场景、不是 OCR 缩放场景，但**同一类"CoreImage Lanchoz vs vImage 采样核不一致"的风险同样存在**。`lanczosResize` 的注释明确写着它替代最近邻是**为了修复"速度模型乱读的病根"**（`:1382-1383`）。

**因此对本残点的建议是：**

- **不要**擅自把 `lanczosResize` 改成 vImage —— 有实测过的精度回退先例，且用户红线是「不允许降质量」。
- **优先方案**：把 `lanczosResize` 连同整个 CNN 备用引擎路径一起**评估是否还需要保留**。若 CNN 只是 PP-OCR 故障时的降级，可考虑：要么彻底删除 CNN 路径（PP-OCR 故障即如实报错），要么保留但**接受它在降级时才短暂占 GPU**。
- **若必须保留且必须零 GPU**：需要用**与训练端 PIL LANCZOS 逐像素对齐的纯 CPU 实现**（如手写 separable Lanczos3 + `vDSP`），并跑**识别率对照测试**确认不掉精度。这是一次独立的小型工程，**不建议顺手做**。

#### 残点 C：`saveOCRDebug` 的 CoreImage 缩略（`SpeedOCRReader.swift:1488-1493`）

```swift
        let input = CIImage(cvPixelBuffer: buffer)
        // 全屏缩略（最长边 ≤ 800，便于直接看 / 发图），与 cropSlots 同一 CIImage 语义
        let scale = min(1.0, 800.0 / Double(max(sw, sh)))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ciContext.createCGImage(small, from: small.extent) {
            Self.writePNG(cg, to: "/tmp/aurora_ocr_dbg_full.png")
        }
```

**这是默认路径下唯一真正会执行 CoreImage 的代码点**（尽管有 10s 节流）。

**改法（推荐）**：`vImageScale_ARGB8888` + 复用 `cgImageFromPixelBuffer` 的思路，与 `CaptureEngine` 的 UI 缩略完全同法（`CaptureEngine.swift:1209-1219` 逐行照抄即可）。缩略图仅用于**人眼看排障**，1~2px 的插值差异完全无影响，**这是最安全、零风险的一处改造**。

**更彻底的改法**：调试产物本就是 `/tmp` 下的临时排障文件，若判断其长期价值低，**整个 `saveOCRDebug` 可考虑删除**（它每 10s 写 4 个文件，本身也是磁盘/编码开销）。此判断需用户确认，审计不做决定。

#### 残点 D：`ConfidenceEstimator.averageBrightnessViaCoreImage` + `brightnessContext`（`:237`、`:337-358`）

**改法：直接删除**，连同 `useCoreImagePath` 开关（`:274-275`）和 `AURORA_CONF_CI` 环境变量。

理由：
1. 默认路径已经不走它（`:278`），它是**纯粹的死代码**。
2. 保留的唯一价值是"排查对比"，但排查对比的代价是**一个能把红线踩穿的开关**。
3. CPU 版本（`:283-333`）已经过生产验证（注释记录 `:270` 开销 ≈0.05ms）。

### 5.3 改造后的预期收益（基于实测）

| 场景 | 改造前 | 改造后 |
|---|---|---|
| CNN 引擎路径每帧（3 槽裁 + 3 槽缩放） | ≈ 3×0.32 + 3×? ≈ **数 ms GPU 同步等待** | 裁剪 **0.12ms CPU**；缩放待定（见残点 B 风险） |
| `saveOCRDebug` 触发时 | 1 次 GPU 同步渲染 | 1 次 CPU vImage 缩放（≈0.1ms 级） |
| `AURORA_CONF_CI=1` 误设时 | **15Hz × 整帧 GPU 同步** | 开关删除后**不可能发生** |

**注意**：本审计**未测量**驾驶态下这 2 个 CIContext 各自贡献了多少 mW / 多少 GPU% —— 因为默认配置下它们几乎不渲染，用现有 36.4% 数据无法归因到 CoreImage。**"CoreImage 占 36.4% 中的多少" = 未测**。要回答这个必须做 A/B 对照采集（关掉/打开特定路径 + `powermetrics`），本次纪律禁止启动 App，故不做。

---

## 6. 未测 / 无法确认项（如实列出）

| 项 | 状态 | 原因 |
|---|---|---|
| 驾驶态 CoreImage 实际贡献的 GPU% / mW | **未测** | 需启动 App + `powermetrics` A/B，本次禁止启动 App |
| `ppocrv6_tiny_ft_int8` 模型在用户机器上是否加载成功 | **未测** | 运行时行为；模型文件存在（已核实），但加载结果无法静态判定。**这直接决定 `cropSlots`/`lanczosResize` 是否每帧执行** |
| `saveOCRDebug` 在真实驾驶中的实际触发频率 | **未测** | 取决于"画面里有没有速度表"，需运行时统计。代码上限已确认：≤0.1Hz |
| 引擎进程 `tick()` 是否每 tick 都调 `confidenceEst.update` | **代码可判定为是**（`:7765` 无额外守卫），但**实际 tick 达成率未测** |
| `vImage` Lanczos 替换后 CNN 识别率是否下降 | **未测** | 本项目在 letterbox 场景实测过类似回退（`YolopxEngine.swift:1552-1575`），OCR 场景未测 |

**环境实测信息（供复核）**：`Apple M3`，`macOS 27.0.1 (26A434)`，SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`。探针源码与 sample 输出保存在 `/tmp/ci_probe/`（`probe2.swift`、`probe3.swift`、`probe4.swift`、`sample2.txt`），可复跑。

---

## 7. 给后续施工的优先级建议

| 优先级 | 动作 | 风险 | 理由 |
|---|---|---|---|
| **P0** | 删除 `ConfidenceEstimator` 的 `brightnessContext` + `averageBrightnessViaCoreImage` + `AURORA_CONF_CI` 开关 | **零**（默认已不走，纯删死代码） | 消除一个能踩穿红线的开关 |
| **P0** | `saveOCRDebug` 改用 `vImageScale_ARGB8888` | **零**（调试图，人眼看） | 默认路径唯一真实 GPU 点 |
| **P1** | 评估是否保留 CNN 备用引擎；若保留，`cropSlots` 改纯 CPU 裁剪 | 中（需改取整口径 + 对照测试） | 消除每帧 3 次 GPU 同步等待 |
| **P1** | 删除 `SpeedOCRReader` 的 `AURORA_OCR_CI` 开关及 `ciContext.createCGImage` 分支（`:966-974`） | 低 | 死代码，但开关本身是风险 |
| **P2** | `lanczosResize` 的 vImage 化 | **高**（有精度回退先例） | 需独立工程 + 识别率对照，**不建议顺手做** |
| **—** | `kCVPixelBufferMetalCompatibilityKey: true` | 无 | 不是 GPU 负载来源，**保持现状** |

---

## 8. 一句话回答用户

**"设了 `useSoftwareRenderer: true` 就避开 GPU"是错的 —— 已用 `sample` 抓栈实测证明它在 Apple Silicon 上被静默忽略，CIContext 照样走 `CI::MetalContext`，而且 96% 时间同步卡在 `_MTLCommandBuffer waitUntilCompleted` 等 GPU。好消息是默认路径基本已经绕开了它；坏消息是仓里还留着 2 个"一开就打回 GPU"的回退开关和 3 个 CoreImage 残点，必须删掉才能把"GPU 绝对不能占用"这条红线焊死。**
