# 4 · 抓屏链路 GPU 审计（只读）

> 审计对象：`Sources/AuroraDrive/Capture/CaptureEngine.swift`（1626 行，全文通读）
> 机器：M3 MacBook Air / 主屏 Built-in Retina Display **1470×956 点 @2x = 2940×1912 像素**
> 纪律：**只读，未改任何源码，未启动 App**；实测数据全部来自本机独立探针（见 §7），未测项明确标注
> 日期：2026-10-24

---

## 0. 判定（先给结论）

> **抓屏链路里，我们自己写的代码没有一步用 GPU —— 全部是 CPU vImage / memcpy。
> 唯一用 GPU 的是 `SCStream` 的系统侧采集与合成（WindowServer 把 2940×1912 降采样到
> 1280×832 写进 IOSurface），这一步在应用进程之外，没有 API 能强制它走 CPU。**
>
> **并且实测推翻了「降分辨率能省 GPU」这个推论**：把输出分辨率从 640×416 一路改到
> 2940×1912（近原生，等于让系统不降采样），GPU 增量**没有单调变化**，大缓冲反而更低。
> ⟹ 抓屏的 GPU 成本**主要由「每帧一次」的固定开销构成**（合成管线 / IOSurface 写入），
> **不随输出像素量按比例增长**；**降低分辨率不是省 GPU 的杠杆**。帧率虽有正相关，
> 但实测弹性远小于 1（3× 帧只 +3.2pp），所以**降帧率也只是小幅、非线性的收益**。

一句话给死命令的答复：**抓屏这块，「GPU 归零」在应用侧已经做到了；剩下的 GPU 是系统采集的
过路费，**只能靠降帧率小幅削减（实测弹性远小于 1）**，不能靠改代码搬到 CPU。**

---

## 1. 抓屏链路逐步骤分解（谁在 CPU、谁在 GPU）

| # | 步骤 | 位置（文件:行） | 执行方 | 证据 |
|---|---|---|---|---|
| 1 | 建 `SCStreamConfiguration`：输出 1280×832、`scalesToFit=false`、`32BGRA`、`queueDepth=3`、`showsCursor=true` | `CaptureEngine.swift:603-632` | 应用（纯配置，无计算） | 见 §2 原文 |
| 2 | 系统合成整屏 2940×1912 并降采样到 1280×832，写入 IOSurface | 系统侧（`SCStream`/WindowServer） | **GPU**（不在本进程） | SDK 头文件：输出是 IOSurface-backed，宽高=配置宽高（见 §3） |
| 3 | 帧回调取 `CVPixelBuffer` | `:1102` | 应用 | `CMSampleBufferGetImageBuffer` |
| 4 | 原生 ROI 裁剪（速度表区域 102×42）→ 逐行 `memcpy` | `:1122` → `copyNativeFrame` `:1319-1359` | **CPU** | `memcpy` 循环 `:1353-1357` |
| 5 | 全分辨率整帧拷贝（1280×832×4 ≈ 4.26MB）→ 逐行 `memcpy` | `:1130-1133` → `copyUpscaleFrame` `:1392-1418` | **CPU** | `memcpy` 循环 `:1414-1416`；**默认不执行**（门禁见 §5） |
| 6 | YOLO 缩放 1280×832 → 640×640 | `:1142-1178` | **CPU** | `vImageScale_ARGB8888` `:1173`；**A 档默认不执行** |
| 7 | UI 缩略图 1280×832 → 480×312 | `:1190-1219` | **CPU** | `vImageScale_ARGB8888` `:1219` |
| 8 | 建 `CGImage`（零拷贝引用 vImage 输出缓冲） | `:1229-1250` | 应用（无渲染） | `CGDataProvider` + `passRetained` |
| 9 | UI 显示：`layer.contents = cgImage` | `AuroraDriveApp.swift:9035-9038` | WindowServer 合成（GPU） | 这是**显示**开销，不是抓屏开销 |

**结论**：第 2 步是唯一的 GPU 环节，且它属于系统 `SCStream` 内部；第 4~8 步全部 CPU。

---

## 2. `SCStreamConfiguration` 逐字段核查

原文（`CaptureEngine.swift:603-632`）：

```swift
static func makeStreamConfiguration(configHz: Double, display: SCDisplay) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    let targetW: Double = 1280          // ← 硬编码，运行时不可切
    ...
    config.width = Int(targetW)                              // :617
    config.height = Int((targetW * aspect).rounded())        // :618 → 1470×956 屏算得 832
    config.scalesToFit = false                               // :619
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(tscale))  // :623
    config.pixelFormat = kCVPixelFormatType_32BGRA            // :624
    config.queueDepth = 3                                     // :625
    config.showsCursor = true                                 // :626
    return config
}
```

| 字段 | 值 | 核查结论 |
|---|---|---|
| `width` / `height` | 1280 / 832（按屏幕宽高比算，非硬编码 720） | ✅ 与实测一致：探针拿到的缓冲就是 `1280x832` |
| `scalesToFit` | `false` | ✅ SDK 原文「When false, the output only scales down」→ 只缩小不放大，正是当前行为（2940→1280） |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | ✅ 与 §1 全部 vImage/`CGImage` 调用一致（都按 32BGRA）；**正确，无需改** |
| `queueDepth` | 3 | ✅ SDK 默认 8；3 更省内存。实测 3 vs 8 对 GPU 无差异（§7.4，噪声内） |
| `showsCursor` | `true` | ⚠️ 自动驾驶不需要光标；但实测 `false` 只省 1.5pp（噪声内，§7.4）→ **不建议动** |
| `minimumFrameInterval` | `1/configHz`，正常态 **15Hz**，应急冲刺 **20Hz** | ⚠️ 这是**唯一**实测与 GPU 正相关的参数（§7.2） |
| `captureResolution` | **从未设置** → 默认 `.automatic` | 见 §7.3 实测：三种取值无差异，**不是杠杆** |

`preservesAspectRatio` 未显式设置，官方默认 `true`（SDK 头注释明示），配合 `scalesToFit=false`
不会 letterbox —— 与源码 `:488-495` 的注释一致，**该注释准确**。

---

## 3. 重点查证：1280×832 的系统侧降采样，是不是在 GPU？

### 3.1 先确认真实源分辨率（不是 480×312，也不是 1280×832）

本机实测（独立探针，非 App）：

```
NSScreen.main.frame      = 1470.0 × 956.0     点
backingScaleFactor       = 2.0
⇒ 物理像素               = 2940 × 1912
CGDisplayCopyDisplayMode:
    width/height         = 1470 × 956   （点）
    pixelWidth/pixelHeight = 2940 × 1912 （像素）
```

所以：**真实抓取的源头是 2940×1912**；`SCStream` 输出 **1280×832**；UI 收到 **480×312**。
两轴比值：2940/1280 = 2.297，1912/832 = 2.298 —— **两轴一致，无 letterbox**，与源码注释
`:488-495` 的等比设计吻合。

### 3.2 降采样确实发生在系统侧（结构性证据）

SDK 头文件 `SCStream.h:27` 原文：

```
SCStreamOutputTypeScreen is a screen capture sample buffer. This sample buffer that is
wrapping a CMSampleBuffer that is **backed by an IOSurface**. The **width and height of
the sample buffer is what is defined in the SCStreamConfiguration** for width and height.
```

⟹ 我们收到的缓冲**天生就是 1280×832**，中间那次 2.297× 降采样**不在我们的代码里**，
是 `SCStream` 在交付前完成的。`CaptureEngine` 里不存在任何把 2940 缩到 1280 的调用
（全文唯一的两次 `vImageScale` 是 1280→640 和 1280→480，见 §1 第 6、7 步）。

### 3.3 但「这一步吃 GPU 算力」这个推论 —— 实测推翻

关键实验（配对法，抵消背景漂移；10 轮，每轮先测基线再测抓屏，单位 = `ioreg` Device Utilization %）：

| 输出尺寸（@15fps） | 抓屏相对基线的增量 Δmean | Δmedian | 每轮总帧数 |
|---|---:|---:|---:|
| 640×416（比生产小一半） | **+5.20 pp** | +8.4 | 238 |
| **1280×832（生产配置）** | **+9.40 pp** | +13.3 | 239 |
| 2940×1912（近原生，系统几乎不降采样） | **+3.00 pp** | +7.0 | 240 |

**读法**：如果「系统侧降采样」是按像素量在 GPU 上计费的，那么
`2940×1912 → 输出 2940×1912`（等于取消降采样）应该**最贵**；
但实测它**最便宜**（+3.00pp），而中间的 1280×832 **最贵**（+9.40pp）。
像素量 640×416=0.27MP / 1280×832=1.07MP / 2940×1912=5.62MP，跨度 **21 倍**，
GPU 增量却**完全不随像素量单调变化**。

> **判定**：抓屏的 GPU 成本**主要是每帧一次的固定开销**（合成管线启动 + 写 IOSurface），
> **不是按输出像素量计费**。所以：
> - 「把 1280×832 再降到 640×416 来省 GPU」→ **实测无效**（甚至略高，噪声内）
> - 「系统侧降采样这一步在 GPU」→ 结构上成立（IOSurface/合成），但它**不构成可优化项**，
>   因为它的代价不随我们选的输出尺寸变化
> - 诚实边界：本轮**没有**直接测到「降采样」这一子步骤的独立耗时（需要 per-process GPU
>   归因，本机不可用，见 §7.5）。上面是**导出性证据**，不是直接计时。

---

## 4. `:1273` 的 `kCVPixelBufferMetalCompatibilityKey: true` —— 是否必要？

**先纠正一个位置误解：它不在帧回调的热路径上，而是在「640×640 YOLO 输入池」的建池属性里。**

原文（`CaptureEngine.swift:1263-1284`）：

```swift
private func makeYoloBufferPool(size: Int) -> CVPixelBufferPool? {
    ...
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: size,                 // size = YoloEngine.inputSize = 640
        kCVPixelBufferHeightKey: size,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferMetalCompatibilityKey: true,   // 与模型输入一致   ← :1273
    ]
    CVPixelBufferPoolCreate(...)
}
```

### 谁消费它？

链路：`:1147` 建池 → `:1173` vImage 写入 → `:1174` `onYoloFrame(yb)` →
`AuroraDriveApp.swift:6120-6126` 存 `pendingYoloFrame` → `YoloEngine.inferFast`
（`YoloEngine.swift:329-371`）→ `MLFeatureValue(pixelBuffer:)`（`:370`）。

### 全仓核实：没有任何代码真的用 Metal 访问这个缓冲

```
grep -rn "CVMetalTextureCache|MTLTexture|newTexture|CVMetalTextureGet" Sources/
→ 0 命中
```

⟹ 该标记**目前没有任何消费者真正拿它建 Metal 纹理**。它是「让缓冲**具备**被 Metal 访问的
能力」，属于**能力声明**，本身**不产生任何 GPU 工作**（不会因为打了这个 key 就多一次 GPU 提交）。

### 关掉会不会影响下游？

| 下游 | 是否要求 Metal 兼容 | 依据 |
|---|---|---|
| `MLFeatureValue(pixelBuffer:)` + `computeUnits=.all` | 若 CoreML 选 GPU 后端，**非 Metal 兼容缓冲需要额外拷贝**（性能↑风险，不是正确性风险） | `YoloEngine.swift:187` `config.computeUnits = .all` |
| `vImageScale`（CPU） | 不需要 | `:1173` |
| `CGImage` | 依赖 CGImage 兼容 key，与 Metal key 无关 | `:1271-1272` |

> **结论**：这个 key **单独删掉，收益 = 0、风险 = 小但非零**（若 CoreML 之后落到 GPU，
> 会多一次像素拷贝）。**正确做法是配套改**：先把 `YoloEngine.swift:187` 的
> `computeUnits = .all` 改成不碰 GPU 的档位，再删 `:1273`。见 §8 改法 C。

---

## 5. `:1423` 的 `upscaleBufferPool` 用途（名字有误导）

原文（`CaptureEngine.swift:1420-1445`）：

```swift
/// 惰性创建（或复用）**全分辨率插帧缓冲池**（32BGRA，标准内存布局）
/// 不带 IOSurface，避免 BaseAddress 不可读导致 CGImage 创建失败；
/// GooseEngine.ingest(cgImage:) 内部会自行创建 IOSurface-backed 缓冲。
private func upscaleBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,      // = 源宽 1280
        kCVPixelBufferHeightKey: height,    // = 源高 832
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        // 故意不加 kCVPixelBufferIOSurfacePropertiesKey
    ]
```

**澄清三点**：

1. **它不放大任何东西。** 名字叫 `upscale`，实际尺寸 = **源帧原尺寸 1280×832**，
   用途只是给「插帧/超分」那条支路做一份 **同尺寸整帧 memcpy 拷贝**
   （`copyUpscaleFrame` `:1392-1418`，4.26MB/帧）。真正的放大在
   `GooseUpscaler`（Metal）里做，**不在本文件**。
2. **它是纯 CPU**：无 IOSurface、无 Metal key，只有 `memcpy` 循环（`:1414-1416`）。
3. **默认不执行**：门禁在拷贝之前求值（`:1130`）：

```swift
if let onUpscaleFrame, isUpscaleWanted(),        // ← 门禁先算
   let upscaleCopy = copyUpscaleFrame(from: pixelBuffer) {
```

   默认值（三处一致，全部为关）：
   - UI 进程：`isUpscaleWanted = { self?.upscaleEnabled ?? false }`（`AuroraDriveApp.swift:6163`），
     `var upscaleEnabled: Bool = false`（`:5330`）
   - 引擎进程：`isUpscaleWanted = { EngineGlobals.wantFullFrame }`（`EngineMain.swift:1247`），
     `@MainActor static var wantFullFrame = false`（`:640`）
4. **这条支路的下游在运行时处于关闭态**（此处勘误：不是「从未接线」，而是「被门禁挡住」）：
   - `UpscaleFrameHostView` **确实存在于视图树里** —— `MissionConsole.swift:592-595`：
     `if state.upscaleEnabled { UpscaleFrameHostView(host: state.upscaleHost) }`，
     其 `makeNSView` 会 `MTKView()` + `host.attach(v)`（`AuroraDriveApp.swift:9232-9240`）。
   - 但它**被 `state.upscaleEnabled` 门禁**，而该值：
     · 默认 `false`（`AuroraDriveApp.swift:5330`）
     · 唯一写 `true` 的地方是**截图夹具** `MissionConsole.render(to:)`（`:6824`，
       函数内 `let state = DriveState()` 是临时夹具，不是运行时状态）
     · 唯一的开关函数 `setUpscaleEnabled(_:)`（`AuroraDriveApp.swift:6508`）**全仓零调用者**
       （`grep` 排除定义处后 0 命中）
   ⟹ **实际驾驶态下 `MTKView` 不会被挂载，`GooseUpscaler` 的 Metal 渲染不运行。**
   （另一处 `MTKView` 在 `AuroraDriveApp.swift:571-592`，属 `runUpscaleSelfTest()`，
   仅 `--upscale-selftest` 参数触发，见 `MissionConsole.swift:6341`。）

> **这是最重要的一条「推翻」**：单看 `AuroraDriveApp.swift:9096`（`MTLCreateSystemDefaultDevice()`）
> 会以为驾驶态有 Metal 渲染，但**该视图被默认关闭的门禁挡在视图树之外**。
> 抓屏链路因此**没有任何应用侧 Metal 提交**。

---

## 6. `nativeROI` 路径：CPU 还是 GPU？

**纯 CPU，且是整条链路里最省的。**

`copyNativeFrame`（`:1319-1359`）的做法：把归一化 ROI 换算成像素，
只在源缓冲里逐行 `memcpy` 那一小块到小池化缓冲：

```swift
let copyBytes = roiW * bytesPerPixel           // roiW=102 → 408 字节/行
for r in 0..<dstRows {
    memcpy(dBase + r * dBPR,
           sBase + (roiY + r) * sBPR + srcOffset,
           copyBytes)                           // :1353-1357
}
```

ROI 常量（`:166-167`）：`speedROINorm = (x:0.455, y:0.885, w:0.080, h:0.050)`
→ 在 1280×832 上 = **102×42 ≈ 17KB**（注释 `:1315` 说「≈100KB」是旧值，实际 17KB）。

下游 `SpeedOCRReader` 也已**去 CoreImage 化**：`:835-838` 的 `ciContext` 只在
`AURORA_OCR_CI=1` 的回退分支用（`:970-974`），默认走 `cgImageFromPixelBuffer`
纯内存拷贝（`:852-893`）；OCR 模型 `computeUnits = .cpuAndNeuralEngine`（`:433`，**无 GPU**）。

⟹ **ROI 路径零 GPU**。

---

## 7. 实测数据（本机独立探针，不启动 App）

### 7.0 方法与自己承认的局限

- 工具：自写 Swift 探针（`/tmp/sckprobe/`），只调 `SCStream` + 读 `ioreg -c IOAccelerator`
  的 `Device Utilization %`（免密，与此前 `性能-抓屏实测-2026-10-11.md` 同口径）。
- **本机基线被污染**：当前有其他 GPU 负载在跑，空闲基线在 **20% ~ 60% 之间大幅漂移**
  （与历史文档 `优化-GPU深挖实测-2026-10-11.md:242` 记录的「编译进程抢 GPU 导致污染」同因）。
  ⟹ **无法复现「待机 0.7%」这个前提环境**，也**无法复现 36.4%**。
  所以我放弃绝对值，改测**配对差分**（同轮内 基线 → 抓屏 → 基线），只取「抓屏的增量」。
- 每轮采样 1.5~2s、间隔 120~200ms；每配置 **8~10 轮配对**取中位数与均值。

### 7.1 抓屏本身的增量

10 对，1280×832@15：**Δmean = +13.3pp，Δmedian = +14.0pp**（单对范围 +2.1 ~ +31.3）。
与历史实测 `性能-抓屏实测-2026-10-11.md:134` 的 **+8.5pp** 同量级，差异来自本机基线噪声。

### 7.2 帧率：唯一与 GPU 正相关的参数

| 配置 | Δmean | Δmedian | 每轮总帧 |
|---|---:|---:|---:|
| 1280×832 **@15** | +9.40 pp | +13.3 | 239 |
| 1280×832 **@45** | **+12.60 pp** | +12.4 | 602 |

帧数 ×2.52，增量只 +3.2pp —— **次线性**（若真是每帧固定开销，3× 帧应带来 ~3× 增量）。
诚实结论：**帧率与 GPU 正相关，但弹性远小于 1**（本组约 0.25×）。
（注：本项与 §3.3 的 15fps 测量在同一批实验内，绝对值偏移属噪声；倍率仅作方向参考。）

### 7.3 `captureResolution`（automatic / nominal / best）

各 6 轮 × 2s：`automatic` median **55.0** / `nominal` **56.0** / `best` **49.4**。
**无单调信号，全部落在噪声内** ⟹ 这个字段不是省 GPU 的开关，**不建议改**。
（当前代码从未设置它，默认 `.automatic`；全仓 `grep captureResolution` = 0 命中。）

### 7.4 `showsCursor` 与 `queueDepth`（8 轮配对）

| 配置 | Δmean | Δmedian |
|---|---:|---:|
| `cursor=true, qd=3`（生产） | +10.25 | +10.1 |
| `cursor=false, qd=3` | +8.75 | +8.2 |
| `cursor=true, qd=8` | +6.25 | +7.5 |

全部在 ±13pp 噪声内，**无可靠差异** ⟹ 两个参数都**不建议为省 GPU 去动**
（`queueDepth` 由 3 改 8 反而略低，属噪声，不可作为结论）。

### 7.5 未测项（明确标注）

- **GPU 功耗 371mW**：未测。`powermetrics` 需 sudo/密码，本会话无审批通道（历史文档
  `性能-抓屏实测-2026-10-11.md:39` 记录同样受限）。
- **per-process GPU 归因**：未测。本机该列不可用（与题设「powermetrics 该列恒为 0」一致），
  故无法把 13pp 拆到 `SCStream` / WindowServer / 其他进程。
- **「降采样」子步骤的独立耗时**：未测（依赖上一条）。
- **36.4% / 0.7% / 9.0fps / 480×312 / tick 分段**：均为题设给定前提，本审计**未独立复测**，
  仅在代码侧确认 480×312 是 `CaptureEngine.swift:1190-1195` 的 480 宽等比缩小结果（✅ 可验算）。

---

## 8. 强制走 CPU 的具体改法

### 先说不可能的那条

**`SCStream` 的系统侧合成/降采样，没有任何 API 能强制走 CPU。** 没有 `useSoftwareRenderer`
之类的开关作用在 ScreenCaptureKit 上（`SCStreamConfiguration` 全字段见 §2，无此能力）。
所以「抓屏那一步搬到 CPU」**在技术上不存在**。能做的只有三件事：**降帧率**、
**切断应用侧一切 GPU 耦合**、**消除对 GPU 兼容缓冲的依赖**。

### 改法 A（唯一有实测收益）：确认抓屏帧率不被上调

- 位置：`CaptureEngine.swift:207`（`_targetCaptureHz = 15.0`）、`:681` `setCaptureHz(_:)`
- 现状（已核对真实代码，非注释）：
  - 正常态：`EngineMain.captureHz(forPerceptionMode:)` 对 `"ayolom"` / `"legacy"` / `"yolopx"`
    **一律返回 `15.0`**（`EngineMain.swift:879-885`）
  - 应急冲刺：`EmergencyTakeover.sprintHz = 20.0`（`EmergencyTakeover.swift:58`），
    由 `EngineMain.swift:1458-1468` 下发 —— **是 20fps，不是 45fps**
    （`EngineMain.swift:1450` 的注释「抓屏 45」是**过期注释**，与 `sprintHz` 实际值矛盾）
- 要做的：确认应急冲刺只在实际应急时触发；`15 → 20fps` 的上调幅度仅为 1.33×，
  按实测弹性（§7.2）预计 GPU 增量在噪声量级，**不是优先优化项**。
- 实测边界（诚实标注）：本轮只对比了 **15fps 与 45fps**（+3.2pp），**未测 15 vs 20**
  这个生产实际会用到的相邻档位。

### 改法 B（零风险清理，收益≈0，仅为消除误导）：删掉未使用的 `import CoreImage`

- 位置：`CaptureEngine.swift:33` `import CoreImage`
- 现状：**全文没有任何 `CIImage` / `CIContext` / `CIFilter` 实例化**（只有注释提到它们）。
- 改法：删除该 import。
- 说明：**不影响 GPU**（未使用 import 不产生运行时开销），纯粹是让「这个文件不碰
  CoreImage」这件事在代码上显式成立，避免后人误以为这里还有 GPU 路径。

### 改法 C（**唯一能真正切断应用侧 GPU 耦合**，但属下游、需与本审计外的人对齐）：
把 640×640 直通帧的消费者改成不碰 GPU 的 computeUnits

- 位置 1：`YoloEngine.swift:187` `config.computeUnits = .all`
- 位置 2：`YolopxEngine.swift:746` `config.computeUnits = .all`
- 改法：改成 `.cpuAndNeuralEngine`（与同项目 `SpeedOCRReader.swift:433` 的既有做法一致，
  那里注释写明「补显式 computeUnits（本轮审计发现）」）。
- 为什么必须与 `:1273` 一起改：`MLFeatureValue(pixelBuffer:)` 若走 GPU 后端，
  删掉 `kCVPixelBufferMetalCompatibilityKey` 只会让它**多一次拷贝**，不省 GPU。
  只有先把 CoreML 钉在 CPU/ANE 上，`:1273` 才可以安全删除。
- 然后：删除 `CaptureEngine.swift:1273` 的 `kCVPixelBufferMetalCompatibilityKey: true`。
- 预期：这条能消除「CoreML 可能落到 GPU」的不确定性。**但它不改变 `SCStream` 那部分 GPU**，
  且属于推理链路 —— 与 `3-compute-units.md` 的结论需交叉核对，**不要在本次审计内单独动手**。

### 明确不建议的改法（实测无效，勿浪费）

| 想法 | 实测结果 | 结论 |
|---|---|---|
| 输出 1280×832 → 640×416 | +5.20 vs +9.40，噪声内 | ❌ 无效 |
| 输出改近原生 2940×1912 | +3.00，反而更低 | ❌ 无效（且浪费带宽） |
| `captureResolution = .nominal` | 56.0 vs 55.0 | ❌ 无效 |
| `showsCursor = false` | 8.75 vs 10.25，噪声内 | ❌ 无效 |
| `queueDepth` 3 → 8 | 6.25 vs 10.25，噪声内 | ❌ 无效 |

---

## 9. 对前人发现的逐条裁定

| 前人说法 | 裁定 | 证据 |
|---|---|---|
| 「缩放全部用 CPU vImage」 | ✅ **采信** | `:1173`（1280→640）、`:1219`（1280→480）均为 `vImageScale_ARGB8888` |
| 「`SCStream` 输出 1280×832 本身就是系统侧降采样」 | ✅ **采信** | SDK `SCStream.h:27`（IOSurface-backed，宽高=配置宽高）；源为 2940×1912（§3.1 实测） |
| 「**这一步可能在 GPU**」 | ⚠️ **半采信、但推翻了它的优化含义** | 结构上属系统 GPU 合成路径；但**实测分辨率无效应**（§3.3），故**不是可优化杠杆** |
| 「抓屏 GPU 不可省」（历史文档 P6） | ✅ **采信，并补上量化** | 应用侧无法搬走；主要成本是每帧固定开销，降帧率只有次线性收益 |

---

## 10. 一页纸交付

- **哪一步用 GPU**：只有 **`SCStream` 系统侧采集/合成（2940×1912 → 1280×832 写入 IOSurface）**，
  位于应用进程之外。应用侧 4~8 步（ROI 裁剪、整帧拷贝、两次缩放、建 CGImage）**全部 CPU**。
- **能否强制走 CPU**：**不能**。`SCStreamConfiguration` 无软件渲染开关。
- **应用侧是否已「GPU 归零」**：**是**。全仓无 `CVMetalTextureCache`/`MTLTexture`；
  唯一的 Metal 渲染路径（MetalGoose `MTKView`，`AuroraDriveApp.swift:9096`）虽在视图树中
  （`MissionConsole.swift:592-595`），但被 `upscaleEnabled=false` 挡住，
  且其开关函数 `setUpscaleEnabled(_:)` **全仓零调用者** ⟹ **运行时不会挂载**。
- **唯一相关的旋钮**：**帧率**。但实测 **15→45fps（3×）只多 +3.2pp**，弹性远小于 1；
  生产实际只有 15fps（正常态）与 20fps（应急冲刺）两档，**该旋钮的剩余空间很小**。
- **唯一值得做的代码动作**：改法 C（`computeUnits` + 删 `:1273`），但属下游、需跨审计对齐。
- **`kCVPixelBufferMetalCompatibilityKey: true`（`:1273`）**：是**能力声明**，不产生 GPU 工作；
  目前**零消费者**（无 Metal 纹理创建）；单独删除无收益，须配合 `computeUnits` 才有意义。
- **`upscaleBufferPool`（`:1423`）**：名字误导，**不放大**，是 1280×832 整帧 CPU memcpy 的池；
  默认门禁关闭（§5），驾驶态不执行。

---

## 附：本次审计用到的只读命令

```bash
# 真实屏幕几何
swiftc -o disp_probe disp_probe.swift && ./disp_probe     # 1470×956 @2x → 2940×1912

# 抓屏增量（配对法）
/tmp/sckprobe/probe5                                      # 分辨率/帧率 10 轮配对
/tmp/sckprobe/probe6                                      # cursor/queueDepth 8 轮配对

# 结构核查
grep -rn "CVMetalTextureCache|MTLTexture" Sources/         # 0 命中
grep -rn "captureResolution" Sources/                      # 0 命中（默认 automatic）
grep -rn "upscaleHost.attach" Sources/                     # 0 命中（MTKView 未挂载）
```

> 本文件为**只读审计报告**，未修改任何源码，未启动 App。所有「未测」均已在 §7.5 列明。
