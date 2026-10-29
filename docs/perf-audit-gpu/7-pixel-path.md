# 7 · 像素搬运全链路 GPU 审计（抓屏 → 引擎 → 共享内存 → UI → 屏幕）

- 审计时间：2026-10-24 22:32–23:05
- 审计对象：`/Users/dupi/Desktop/自动驾驶系统`（AuroraDrive，SwiftPM，macOS，M3 MacBook Air）
- 审计性质：**纯只读静态审计 + 现有运行日志取证**。未改任何源码、未 `swift build`、未 `./run.sh`、**未启动 App**。
- 用户铁律：**GPU 绝对不能占用，允许拿 CPU 换**。本报告只判「哪一段像素搬运会碰 GPU」，并给 CPU 替代改法。
- 证据口径：每条结论带 `文件:行`；凡未亲手测量的数字一律写「未测」，不估算、不编造。
- 与并行报告分工：本报告**只覆盖像素搬运链路**（抓屏/缩放/共享内存/UI 提交/合成）。CoreML `computeUnits` 归属 `3-compute-units.md`；主循环 CPU 白算归属 `2-cpu-hotpath.md`。重叠处显式标注「不重复记账」。

---

## 1. 结论一句话

**这条链路上真正必然使用 GPU 的只有一处：UI 最后一步把 `CGImage` 交给 `CALayer.contents` 由 WindowServer / CoreAnimation 合成上屏（`AuroraDriveApp.swift:9037`）。这是「必须上屏」的固有成本，不是浪费，且待机 GPU 仅 0.7% 已证明它本身不重。**

**抓屏、缩放、共享内存读写、`CGImage` 重建这四段全部是 CPU**（`vImageScale_ARGB8888` / `memcpy` / `Data(bytes:)`），**没有任何 CoreImage、Metal、IOSurface 回读参与**。

**但审计发现两个真实的 GPU 漏点**（都在非默认配置下才生效，见 §5）：
- **G1**：`SpeedOCRReader` 的 `CIContext` 在**未显式锁 CPU 的回退路径**上仍会走 Metal（`:835` 的 `useSoftwareRenderer` 在 Apple Silicon 上被静默忽略）；其 `lanczosResize`（`:1384`）被 `recognizeCNN`（`:1305`）调用，**15Hz × 3 槽 = 每秒最多 45 次 GPU 提交**——仅当 PP-OCR 推理失败降级到 CNN 时触发。
- **G2**：插帧档（`upscaleEnabled=true`）会启 `MTKView` + `MetalGoose` 渲染链（`AuroraDriveApp.swift:9096` `MTLCreateSystemDefaultDevice()`），**这是整条链上唯一主动跑算子的 GPU 路径**。默认关闭（`:5330` `var upscaleEnabled: Bool = false`），开启即整帧上 GPU。

**你这台机器实测的「驾驶态 GPU 36.4%」中，像素搬运全链路能解释的部分只有「上屏合成」这一段**；其余大头（抓屏系统侧降采样、其余进程）本报告无法凭静态代码归因，标注「未测」。

---

## 2. 完整链路图（逐段标注 CPU / GPU）

```
【游戏窗口 / 屏幕】
        │
        │  ① 系统侧合成 + 降采样
        │     SCStreamConfiguration: width=1280 height=832 pixelFormat=32BGRA
        │     scalesToFit=false（只缩不放）
        │     CaptureEngine.swift:617-625
        ▼
   ┌─────────────────────────────────────────────┐
   │ ① 系统抓屏降采样（ScreenCaptureKit / WindowServer）│
   │    🔴 GPU（系统侧，代码不可控）                  │
   │    证据：待机 0.7% ⟹ 光窗口+地图不吃 GPU          │
   │         驾驶态 36.4% ⟹ 这一段的增量未实测归因      │
   └─────────────────────────────────────────────┘
        │  CVPixelBuffer 1280×832 BGRA（IOSurface-backed，系统池）
        │  像素流 = 1280×832×4×15fps ≈ 64 MB/s（日志实证）
        ▼
   ┌─────────────────────────────────────────────┐
   │ ② UI 缩略帧缩放：vImageScale_ARGB8888        │
   │    🟢 CPU（双线性，捕捉队列内同步）              │
   │    CaptureEngine.swift:1190 maxWidth=480     │
   │    CaptureEngine.swift:1219 vImageScale       │
   │    → 480×312（1280×832 × 480/1280 = 480×312）│
   └─────────────────────────────────────────────┘
        │  池化 CVPixelBuffer（**无 IOSurface**，纯内存）
        │  makeUIBufferPool: CaptureEngine.swift:1289-1307
        ▼
   ┌─────────────────────────────────────────────┐
   │ ③ CGImage 包装（CGDataProvider 零拷贝引用池缓冲）│
   │    🟢 CPU（仅建对象，无像素拷贝）                │
   │    CaptureEngine.swift:1223-1246             │
   │    releaseData 回调 retain uiBuf 保生命周期     │
   └─────────────────────────────────────────────┘
        │  CGImage（480×312，585 KB）
        ▼
   ┌─────────────────────────────────────────────┐
   │ ④ 引擎进程：publish() 写入共享内存            │
   │    🟢 CPU（纯 memcpy，逐行紧凑布局）            │
   │    EngineMain.swift:404-409（fullFrame 路径，memcpy 在 :407）  │
   │    EngineMain.swift:441/444（CGImage 快路径，整块/逐行 memcpy）  │
   │    ⚠️ 双缓冲翻页，无双拷贝                     │
   └─────────────────────────────────────────────┘
        │  POSIX 共享内存 /aurora_frame_v1（mmap）
        │  pixelsOffset=28672，pageSize=585KB，双页
        │  单向流量 ≈ 8.57 MiB/s（15Hz × 585KB）
        ▼
   ┌─────────────────────────────────────────────┐
   │ ⑤ UI 进程 poll()：共享内存 → CGImage          │
   │    🟢 CPU（Data(bytes:) 一次拷贝 + CGImage 建）│
   │    EngineClient.swift:673 Data(bytes:)        │
   │    EngineClient.swift:678 CGImage(width:...)  │
   │    ⚠️ 每帧一次 585KB 分配 + 一次 CGImage 重建  │
   └─────────────────────────────────────────────┘
        │  CGImage（**纯内存，非 IOSurface**）
        ▼
   ┌─────────────────────────────────────────────┐
   │ ⑥ frameHost.push → CALayer.contents          │
   │    🔴 GPU（CoreAnimation 合成，不可避免）       │
   │    AuroraDriveApp.swift:9037                  │
   │    layer.contentsGravity = .resizeAspectFill  │
   └─────────────────────────────────────────────┘
        │
        ▼
   ┌─────────────────────────────────────────────┐
   │ ⑦ WindowServer 合成 → 显示                      │
   │    🔴 GPU（系统，与游戏共享同一 GPU）           │
   │    ⚠️ 实测 WindowServer 另计 45.6% CPU（非 GPU）│
   └─────────────────────────────────────────────┘
```

**叠加层（检测框 / 掩码）走另一条路**：SwiftUI `Canvas` 绘制（`AuroraDriveApp.swift:8948` 检测框、`:8803` 掩码），`🟡 CPU 光栅化 + GPU 合成`。**已做过优化**：注释 `:8956` 记「去掉逐框 `drawLayer` 的高斯模糊（最贵部分）」，现只有描边。

---

## 3. 逐项验收（对应任务「必须查清」6 条）

### 3.1 共享内存布局：**直接映射 + 逐帧 memcpy（但只拷一次，无双拷贝）**

**布局定义**：`EngineMain.swift:182-208`

| 区域 | 偏移 | 大小 | 行号 |
|---|---|---|---|
| 头部 | 0 | 4096 B | `:185` `headerSize` |
| 检测框 | 4096 | 256 × 64 = 16384 B | `:186-189` |
| 掩码 | 20480 | 2 × 3200 = 6400 B | `:198-203` |
| 像素区 | **28672** | `pageMax × 2`（双缓冲） | `:205` |
| 总尺寸 | — | 28672 + 4096×2304×4×2 ≈ **72 MB** | `:220-221` |

**映射方式**：
- 引擎侧创建：`shm_open(O_CREAT|O_RDWR)` + `ftruncate` + `mmap(PROT_READ|PROT_WRITE, MAP_SHARED)`，`EngineMain.swift:222-241`
- UI 侧映射：`shm_open(O_RDONLY)` + `mmap(PROT_READ, MAP_SHARED)`，`EngineClient.swift:529-543`
- **日志实证**：`[UI-CLIENT] 共享内存已映射 72 MB`（`~/Library/Logs/AuroraEngineClient.log`，多次）

**关键判定：写侧是 memcpy，不是零拷贝共享。**

像素写入有两处，都是逐行 `memcpy`：

| 路径 | 证据 | 说明 |
|---|---|---|
| `fullFrame`（CVPixelBuffer，插帧档） | `EngineMain.swift:404-409`（`memcpy` 在 `:407`） | 源可能有行填充 → 逐行拷到紧凑布局 |
| `image`（CGImage，常规档） | `EngineMain.swift:437-447`（`memcpy` 在 `:441` / `:444`） | 源 BPR == 目标时**整块一次 memcpy**，否则逐行。`:428-436` 是解释性注释 |
| 兜底（dataProvider 不可读） | `EngineMain.swift:448-455` | `CGContext.draw` 回退，注释称「理论不发生」 |

**双缓冲翻页**：`EngineMain.swift:401-402`
```swift
let active = base.load(fromByteOffset: 36, as: UInt32.self)
let writePage = active == 0 ? 1 : 0
```
⟹ **引擎不会写 UI 正在读的那一页**。这是必要的（否则撕裂），不是浪费。

**「直接映射还是逐帧拷贝」的准确答案**：
- **映射是直接的**（`mmap`，UI 拿裸指针 `base`，可跨帧复用，不是每帧 `mmap`）。
- **像素是逐帧 memcpy 的**：引擎 `CGImage → shm` 一次（`EngineMain.swift:441`），UI `shm → Data` 一次（`EngineClient.swift:673`）。**共 2 次拷贝/帧，不是 1 次，也不是 3 次。**

**UI 侧曾评估过零拷贝并明确否决**：`EngineClient.swift:662-672` 原文记录——「`CGDataProvider` 直指共享内存页」的零拷贝方案实测折算收益仅 **单核 0.022%**，但会引入「UI 持有 mmap 页指针期间引擎翻页覆写」的撕裂风险，**判断为不值得**。本审计**认可该判断**：这是「收益噪声级 / 风险正确性级」的典型取舍，符合用户「不降质量」红线。

---

### 3.2 `EngineClient.poll()`：**无多余 memcpy / 无 `Data(copy)` 冗余 / 无 `CGImage(source:)`**

`poll()` 位于 `EngineClient.swift:635`，返回 `CGImage?`。

**逐行核查（`:635-700`）**：

| 行 | 语句 | 判定 |
|---|---|---|
| `:636` | `guard isActive else { return nil }` | ✅ 早退 |
| `:638-642` | 心跳 3s 超时 → 断连回落 | ✅ 必要 |
| `:643` | `guard let base = shmBase else { return frameCache }` | ✅ 无 shm 时复用缓存 |
| `:645-647` | `let seq = base.load(...)`；`guard seq != lastFrameSeq else { return frameCache }` | ✅ **无新帧短路，复用缓存，零拷贝** |
| `:650-653` | 读 activePage / w / h / pageSize | ✅ 4 次定长读取，O(1) |
| `:658` | `let off = pixelsOffset + activePage * pageSize` | ✅ 纯算术 |
| `:659` | `if off + pageSize <= shmSize` | ✅ 越界防护 |
| `:673` | `let data = Data(bytes: src, count: pageSize)` | ⚠️ **一次 585KB 分配 + 拷贝（唯一必需拷贝）** |
| `:675-688` | `CGDataProvider(data:)` + `CGImage(width:...)` | ✅ 纯对象构造，`provider` 已持有 `data`，**无额外像素拷贝** |

**结论：`poll()` 路径干净。**唯一开销是 `:673` 的 585KB 分配——这是「从 `mmap` 页到自有生命周期对象」的必需边界（引擎会翻页覆写，UI 不能直接持有裸指针），**不是浪费**。

**注意到 `poll()` 有第二条分支 `:660-661` `copyIntoPixelBuffer`**（插帧档）：
- `:487-518` 实现：`CVPixelBufferPoolCreatePixelBuffer` + 逐行 `memcpy`（`:515`）
- **`:493` 含 `kCVPixelBufferIOSurfacePropertiesKey`** ⟹ **分配的是 IOSurface-backed 缓冲**
- 该路径只在 `wantPixelBuffer == true`（即插帧档）时走，见 §5 G2

**`EngineClient.swift:249` 的 `memcpy` 与像素无关**：那是 `sockaddr_un.sun_path` 的路径字符串拷贝（`tryConnect()`），仅连接时执行一次。

---

### 3.3 全仓 `CGImage(` / `CIContext.createCGImage` / `CVPixelBufferGetBaseAddress` 逐点判定

#### A. `CGImage(` 构造点（生产路径）

| # | 位置 | 触 GPU？ | 判定依据 |
|---|---|---|---|
| A1 | `CaptureEngine.swift:1241` | ❌ **否** | `CGDataProvider(dataInfo:data:size:releaseData:)` 直指 vImage 缩放后的池缓冲（`:1229-1240`），纯内存引用；`shouldInterpolate: true` 仅影响**绘制时**插值，不触发 GPU |
| A2 | `EngineClient.swift:678` | ❌ **否** | `CGDataProvider(data: data as CFData)` + 纯内存 `Data`（`:673`）。**无 IOSurface、无 Metal** |
| A3 | `AuroraDriveApp.swift:9202`（定义），CGImage 构造在 `:9223` | ❌ **否**（但**是死代码**） | `UpscaleFrameHost.cgImage(from:)` 零拷贝包装 CVPixelBuffer（保留 `IOSurface` 语义），但**全仓无调用点**：唯一命中就是 `:9202` 定义行本身；`LoginAssistant.cgImage(from:)` 是另一个同名不同类型的函数。**未测**是否有运行时反射调用——静态看是死代码 |
| A4 | `InferenceEngineV2.swift:3662` | ❌ **否** | 合成测试帧（`pixels` 数组 → `CGDataProvider(data:)`），仅自检用 |
| A5 | `PerfSelfTest.swift:834` | ❌ **否** | `CGContext(data: nil, ...)` + `makeImage()` — **CPU 位图上下文**（`data: nil` 让 CG 自己分配，非 IOSurface），仅 `--tick-bench` 离屏基准用 |
| A6 | `RealShotSelfTest.swift:62` | ❌ **否** | `CGImageSourceCreateImageAtIndex` 解码 JPEG/PNG，CPU 解码，仅自检 |
| A7 | `tools/exp_preprocess_bench.swift:50` | ❌ **否** | 独立实验工具，不参与 App 运行 |
| A8 | `MissionConsole.swift:2440-2443`、`:2699` | ⚠️ **未测** | `cachedCGImage(from: NSImage)` — `NSImage` → `CGImage` 转换。**MapWindow 静态地图**路径（待机即存在），不在驾驶帧链路上。待机 GPU 0.7% 说明它不重，但**该转换是否触 GPU 本审计未实测** |

#### B. `CIContext.createCGImage` 调用点

| # | 位置 | 触 GPU？ | 可达性 / 判定 |
|---|---|---|---|
| B1 | `SpeedOCRReader.swift:814` | 🔴 **是**（设计上否，实际**是**） | `Self.ciContext.createCGImage(cropped, ...)`。`ciContext` 定义在 `:835`，带 `.useSoftwareRenderer: true`，但**同文件 `:959-962` 注释自陈**：「`CIContext.h:184` 明说该选项在无 OpenCL 平台无效」+ Apple Silicon 无 OpenCL ⟹ **静默忽略 ⟹ 走 Metal**。**该文件自己承认这条路不可靠**。可达性：`:814` 在 `recognizePPOCR` 内，属**默认主路径**（`activeEngine = .ppocr`，`:61`）—— 需确认 `:814` 的具体分支条件，见下方「关键澄清」 |
| B2 | `SpeedOCRReader.swift:973` | 🔴 **是**（同上） | **条件分支**：`:969` `if isROISlice \|\| env["AURORA_OCR_CI"] != "1"` → 走 `cgImageFromPixelBuffer`（**纯 CPU**）；**`else` 才走** `ciContext.createCGImage`。默认环境变量未设 ⟹ **默认走 CPU 分支** ⟹ **默认不触 GPU**。仅 `AURORA_OCR_CI=1` 时触 GPU |
| B3 | `SpeedOCRReader.swift:1391` | 🔴 **是** | `lanczosResize` 内，用 `ciContext`（同上，`useSoftwareRenderer` 无效）。**调用点 `:1305` 在 `recognizeCNN` 内**，PID 槽每槽调一次 ⟹ **最多 3 次/次识别**。可达性见「关键澄清」 |
| B4 | `SpeedOCRReader.swift:1492` | 🔴 **是**（但**已节流**） | 调试存图 `debugSaveMinInterval: 10.0`（`:1504`、`:1481`），**每 10 秒最多一次**，仅写 `/tmp/aurora_ocr_dbg_full.png`。生产可忽略，但**确属 GPU 调用**，建议改 CPU 或加 `#if DEBUG` |

**关键澄清（避免误报）：B1 与 B3 的可达性**

- **B1（`:814`）**：需读 `recognizePPOCR` 内部。静态看该文件的主路径（`:970-976`）已改为「优先 `cgImageFromPixelBuffer` 纯 CPU」，`:814` 属另一段（`cropped` 变量路径）。**本审计未逐行确认 `:814` 在默认配置下是否执行**——**标注「未测」，不臆断**。保守起见按「可能触 GPU」对待。
- **B3（`:1391` `lanczosResize`）**：`recognizeCNN` 只在两种情况跑：
  1. `activeEngine == .cnn`（`:467/:470` 按环境变量或模型可用性切换）
  2. **PP-OCR 推理失败自动降级**（`:607-616` `if let err = result.error, let cnn = cnnSnapshot`）
  ⟹ **默认 PP-OCR 正常时不跑**；一旦 PP-OCR 报错降级，就会 **15Hz × 3 槽 = 45 次/秒 GPU 提交**（`inferInterval = 1.0/15.0`，`:93`）。
  **这是本报告发现的最值得修的 GPU 漏点**（见 §6 改法 R1）。

#### C. `CVPixelBufferGetBaseAddress` 调用点（**均为 CPU 直读，不触 GPU**）

| # | 位置 | 判定 |
|---|---|---|
| C1 | `RecordEngine.swift:613-615` | ❌ 否。`CVPixelBufferLockBaseAddress([])` + 裸指针，录制取像素，纯 CPU |
| C2 | `CaptureEngine.swift:1157-1174` | ❌ 否。YOLO 输入 vImage 缩放，CPU（注释 `:1152` 明言「消除 CIContext(GPU) 排队导致的 40ms 卡顿」，正是为绕开 GPU 改的） |
| C3 | `CaptureEngine.swift:1203-1217` | ❌ 否。UI 480 缩略帧 vImage 缩放，CPU |
| C4 | `CaptureEngine.swift:1338-1345` | ❌ 否。速度表 ROI 逐行 memcpy，CPU |
| C5 | `CaptureEngine.swift:1402-1409` | ❌ 否。插帧全分辨率拷贝，CPU（但**目标缓冲无 IOSurface**，注释 `:1433` 明说「故意不加，避免 BaseAddress 不可读」） |
| C6 | `EngineClient.swift:508-515` | ⚠️ **CPU 拷贝到 IOSurface**：`memcpy` 本身是 CPU，但目标 `CVPixelBuffer` **带 IOSurface**（`:493`）⟹ 后续喂 MetalGoose 时**内容会被 GPU 读**。仅插帧档 |

**`CVPixelBufferGetBaseAddress` 本身从不是 GPU 操作**——它只是返回 CPU 可访问的映射地址。**真正决定 GPU 的是「这块缓冲后面被谁消费」**。

#### D. `CIContext` 定义点（全仓共 2 处，均带 `useSoftwareRenderer: true`）

| # | 位置 | 隐患 |
|---|---|---|
| D1 | `SpeedOCRReader.swift:835-838` | 🔴 **`useSoftwareRenderer` 在 Apple Silicon 无效**（`:959-962` 自陈 + `CIContext.h:184`）⟹ **等价于「会走 Metal」**。用了 3 处（B1/B3/B4） |
| D2 | `ConfidenceEstimator.swift:237-240` | 🟢 **安全**：`brightnessContext` 只在 `averageBrightnessViaCoreImage`（`:337`）里用，而后者仅在 `useCoreImagePath == true`（`:274-275`，需 `AURORA_CONF_CI=1`）时可达；默认走 `averageBrightnessViaCPU`（`:279`），纯指针抽样。**默认零 GPU**。注释 `:247` 称「彻底移除 CIContext」与代码不符（对象仍在，只是默认不可达）—— **注释过期，会误导后续排查** |

---

### 3.4 UI 显示帧：**`CALayer.contents`，不是 `Image(nsImage:)`**

**证据：**

```swift
// AuroraDriveApp.swift:9035-9038
func push(_ image: CGImage) {
    cachedCGImage = image
    hostView?.layer?.contents = image      // ← CALayer.contents
}
```

```swift
// AuroraDriveApp.swift:9028-9032  attach()
view.wantsLayer = true
view.layer?.contentsGravity = .resizeAspectFill
view.layer?.masksToBounds = true
if let cg = cachedCGImage { view.layer?.contents = cg }
```

**宿主视图**：`FrameHostView: NSViewRepresentable`（`:9047-9059`），挂在 `MissionConsole.swift:588` 的 `ViewportPanel` 内，`ZStack` 最底层（`:586-589`），上叠检测框 / 掩码 / 光斑。

**`Image(nsImage:)` 只用于静态图，不在画面流上**：
- `MapWindow.swift:324` — 静态地图
- `CategoryPanel.swift:797` — 分类面板图标

**判定**：`CALayer.contents = CGImage` 是**用户判断正确的那条路**——它把整帧作为**一张不变位图**交给 CoreAnimation 合成，**不做逐像素 CPU 重绘**。相比 SwiftUI `Image(nsImage:)`（会触发 SwiftUI 视图 diff + 重绘），这条路更省 CPU，且注释 `:5191` 明说「UI 显示已改走 frameHost 直绘（绕开 SwiftUI diff）」。

**但这正是 GPU 所在**：`layer.contents` 的合成必然由 WindowServer / CoreAnimation 在 GPU 上完成。**这是「像素必须上屏」的固有成本，无法用 CPU 替代**（除非改用 CPU 软件合成整屏，代价远高）。待机 GPU 0.7% 已证明这条路的 GPU 成本很低。

---

### 3.5 两处 `frameHost.push(cg)`：**每 tick 都提交，但其中一条是必要的、另一条可优化**

#### 调用点 1：`AuroraDriveApp.swift:6717`（引擎模式，`tickEngineMode()` 内）

```swift
// :6695-6717
let useUpscale = upscaleEnabled && upscaleSupported
client.wantPixelBuffer = useUpscale
let cg = client.poll()
if useUpscale {
    ...
} else if let cg {
    currentFrameCG = cg
    ...
    if !isStreaming { isStreaming = true }
    frameHost.push(cg)          // ← :6717
}
```

**判定：每 tick 都调用，但多数 tick 提交的是同一张图。**

- `poll()` 在无新帧时 `return frameCache`（`EngineClient.swift:646`），**是上一次同一个 CGImage 对象**
- 所以 `:6717` 在无新帧 tick 上执行的是 **`layer.contents = 同一个 CGImage`** ⟹ **无像素搬运，但触发一次 layer 属性写 + 合成提交**

**这是否必要？——不必要，但没有显著浪费。**

- **不必**：`seq` 未变 ⟹ 内容未变 ⟹ 重设同一个对象是无操作。可以在 `poll()` 返回时区分「新帧 / 缓存帧」，只在**新帧**时 push。
- **但成本极低**：设置同一个对象引用，CoreAnimation 会判等（`contents` 的 `CFEqual` 通常命中同一指针），**几乎不产生新纹理上传**。
- **真正的浪费在别处**：`EngineMain.swift:1486-1492` 的注释已经算准并明说——「UI 每 tick 仍会把 `poll()` 返回的缓存帧 `frameHost.push` 一次……所以 **WindowServer 提交次数不变 —— 那部分不在此次收益内，不能算进来**」。**该注释诚实，本审计认可。**

**建议（低优先，见 §6 R3）**：让 `poll()` 同时返回「是否新帧」，新帧才 push。**收益未测**，理论上是省每秒 15 次 `layer.contents` 属性写（微秒级）。**按「改动必须有可解释收益」纪律，此项可延后。**

#### 调用点 2：`AuroraDriveApp.swift:7194`（UI-local 模式，`tick()` 内）

```swift
// :7177-7194
pendingFrameLock.lock()
if let latest = pendingFrame {
    pendingFrame = nil
    let latestCG = pendingFrameCG
    pendingFrameCG = nil
    ...
    if isStreaming { latestCGToPush = latestCG }
    ...
}
pendingFrameLock.unlock()
// ↓ 锁外推屏：这一步可能等 WindowServer，绝不能在持锁期间做
if let cg = latestCGToPush { frameHost.push(cg) }    // ← :7194
```

**判定：只在「有新的待显示帧」时提交**（`if let latest = pendingFrame` 守卫）。

`pendingFrame` 由 `onFrame` 闭包（`CaptureEngine` 抓屏回调）每帧覆盖（`:6101-6102`），**tick 消费后置 nil** ⟹ **有帧才推，无帧不推**。这比引擎模式的 `:6717` 更精确。

**注意**：该路径只在 **UI-local 模式**（未连引擎）下跑；引擎模式下 `tick()` 在 `:7146` 就 `tickEngineMode(); return` 早退，**不会执行 `:7194`**。

**判定：`:6717`（引擎模式）可以对齐 `:7194`（local 模式）的门控方式** —— 这是 §6 R3 的具体改法。

---

### 3.6 已有「无新帧短路」的覆盖面与缺口

#### 已有短路 A：引擎侧 publish 短路（`EngineMain.swift:1527`）

```swift
if !st.isDriving, !EngineGlobals.wantFullFrame, full == nil,
   pixelsUnchanged, stateUnchanged, !keepAliveDue {
    EngineGlobals.skippedPublishTicks &+= 1      // 日志 skip= 计数
}
```

**判据（`:1512-1521`）**：

| 变量 | 来源 | 作用 |
|---|---|---|
| `pixelsUnchanged` | `curCaptureCount == lastPublishedCaptureCount` | 抓屏帧计数未变 ⟹ 无新像素 |
| `stateUnchanged` | `isDriving` / `isStreaming` / `detections` 三者均未变 | 无状态变化 |
| `keepAliveDue` | 距上次发布 > 1s | **保活兜底** |

**短路的前置条件（`:1527`）**：`!isDriving` && `!wantFullFrame` && `full == nil` ⟹ **只在「非驾驶 + 非插帧 + 无全帧」时短路**。

**判据用「抓屏计数」而非「图像对象身份」的理由（`:1497-1501`）**：`fullFrame` 走 `CVPixelBuffer` 池复用，对象身份恒等 ⟹ 会漏判；`capturedFrameCount` 单调递增、语义唯一。**该设计正确。**

**覆盖了什么**：
- ✅ 待机（不驾驶）且画面静止 ⟹ 引擎不写 shm、不推进 `seq` ⟹ UI `poll()` 的 `seq` 守卫（`EngineClient.swift:646`）命中 ⟹ **UI 不做 `Data` 分配、不重建 `CGImage`**。这是「8.57 MiB/s 单向流量」在待机态本该降为 0 的关键。
- ✅ 保活 1s 兜底，画面最多陈旧 1 秒。

**漏了什么（缺口）**：

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| N1 | **`skip=` 实测仍在涨，但驾驶态短路恒不生效** | 日志 `skip=6950 / 7160 / 7371 / 6529 / 6739`（`~/Library/Logs/AuroraEngine.log`）| 设计使然（`!isDriving` 是前提），**不是缺陷**。但意味着**驾驶态 100% 发布，无任何短路** |
| N2 | **UI 侧 `:6717` 无跳帧门控**（对照 `:7194` 有） | `AuroraDriveApp.swift:6717` vs `:7194` | 引擎模式下每秒 15 次 `layer.contents` 写入（即使同对象）。**微秒级，见 §3.5 判定** |
| N3 | **`seq` 短路依赖引擎侧先短路** | `EngineClient.swift:646` | 若引擎因保活 1s 兜底推进了 `seq`，UI 会跟着做一次完整 `Data`+`CGImage`。**1Hz 量级，可接受** |
| N4 | **掩码指纹短路曾被证实「从未生效」** | `EngineMain.swift:1574-1585` 注释（🔴 2026-10-24 修复）| **已被本轮其他审计修复**，不重复记账（归属 `2-cpu-hotpath.md`） |
| N5 | **插帧档完全绕过所有短路** | `:1527` `!wantFullFrame` 条件 + `:1506` 注释「该模式帧率要求最高」 | 设计使然。但插帧档是**唯一主动上 GPU 的路径**（§5 G2），若用户开启则 GPU 必然被占 |

**结论**：短路逻辑**覆盖正确、设计合理**。唯一可优化的是 N2（引擎模式 `push` 缺门控），**收益微秒级，低优先**。

---

## 4. 实测数据对照（本审计未新增测量，仅核对既有日志）

| 指标 | 值 | 来源 | 是否本审计实测 |
|---|---|---|---|
| 抓屏配置 | **1280×832 @15fps**，`scalesToFit=false`，32BGRA | `~/Library/Logs/AuroraEngine.log` `[capture] 抓屏配置 1280x832 @15fps（aspect=0.650，像素流 64 MB/s）`；代码 `CaptureEngine.swift:617-625` | ❌ 读既有日志 |
| UI 首帧尺寸 | **480×312** | `AuroraEngineClient.log` `收到引擎首帧 480×312（帧管道打通）`；代码推导 `480/1280 × 832 = 312` | ❌ 读既有日志 |
| 共享内存大小 | **72 MB** | `AuroraEngineClient.log` `共享内存已映射 72 MB`；代码 `EngineMain.swift:220-221` | ❌ 读既有日志 |
| 单向帧流量 | **≈ 8.57 MiB/s** | `480×312×4 = 585 KB` × 15Hz = 8775 KB/s ≈ 8.57 MiB/s | ❌ 算术推导（与任务给定值一致）|
| 引擎 tick | **15Hz** | `EngineMain.swift:771` `engineTickHz = 15.0`；`:870-871` 两档均 15 | ❌ 读代码 |
| UI tick | **15Hz**（驾驶/录制），待机 **≈1.9Hz** | `MissionConsole.swift:6232` `repeating: 1.0/15.0`；`:6248-6253` 待机 `idleSkip < 8` | ❌ 读代码 |
| tick 分段实测 | `consumeFrame=0.01/0.02ms`、`nativeROI=0.01/0.02ms`、`total=0.25/0.49ms`（p50/p95） | `AuroraEngine.log` `[PERF] tick分段(p50/p95 ms)` | ❌ 读既有日志 |
| `skip=` 累计 | 632 / 842 / 6529 / 6739 / 6950 / 7160 / 7371 | `AuroraEngine.log` | ❌ 读既有日志 |
| 抓屏实际帧率 | **9.0 fps** | 任务给定 | ❌ **未测**（日志 `capGap=71ms` ≈ 14Hz 请求，实际 9fps 说明掉帧，但本审计未单独测量） |
| 驾驶态 GPU 36.4% / 371mW | — | 任务给定 | ❌ **未测**（本审计不启 App、不跑 GPU 计数） |

**诚实声明**：本审计**没有做任何新的运行时测量**（纪律要求不启动 App）。上表「是否本审计实测」列全部为 ❌。所有数字要么来自既有日志，要么来自代码常量/算术。**GPU 36.4% 的归因，本报告只能做「代码层面哪段会碰 GPU」的静态判定，无法给出各段占比。**

---

## 5. 两个真实 GPU 漏点（详细）

### G1 · `SpeedOCRReader` 的 `CIContext` 实际走 Metal

**问题**：`ciContext`（`:835-838`）带 `.useSoftwareRenderer: true`，但**同文件 `:959-962` 自己写明**：

> `CIContext.h:184` 原文：「Note: This option has no effect if the platform does not support OpenCL.」
> **Apple Silicon 无 OpenCL** → 选项被静默忽略 → 照样走 Metal。
> ⟹ 只要用 CIContext 就无法保证不碰 GPU。**唯一可靠的做法是不用它。**

**该文件已经按这个结论改过主路径**（`:969-976` 改为 `cgImageFromPixelBuffer` 纯 CPU），**但漏了三处**：

| 漏点 | 行 | 触发条件 | 频率 |
|---|---|---|---|
| `lanczosResize` | `:1391` | `recognizeCNN` 被调用（PP-OCR 降级 / `activeEngine=.cnn`） | 15Hz × 3 槽 = **45 次/秒** |
| PP-OCR 内 `createCGImage` | `:814` | **未测**（需确认分支） | 未知 |
| 调试存图 | `:1492` | 每 10 秒（`:1504`） | 0.1 次/秒 |

**为什么这是「真漏点」而不是误报**：
- `lanczosResize` 的调用点 `:1305` 在 `recognizeCNN` 内，**无任何 CPU 替代**
- `recognizeCNN` 的触发路径 `:607-616` 是**自动降级**，用户无感知
- 一旦 PP-OCR 模型缺失/推理 throw，就会**持续 45Hz GPU 提交**

**日志证据（间接）**：`AuroraEngine.log` 中 `ocr[PP-OCRv6]=-1.0/0.00[PP-OCR: 数字串太短(1) raw=0]` —— **这是「业务诊断」，按 `:607` 注释「不算故障，不切换」**，所以当前**未**触发降级。**G1 当前未激活，但一旦 PP-OCR 抛错就激活。**

### G2 · 插帧档：唯一主动跑 GPU 算子的路径

**开启条件**：`upscaleEnabled = true`（`AuroraDriveApp.swift:5330`，**默认 false**）

**链路**：
1. `upscaleHost.prepare()` → `MTLCreateSystemDefaultDevice()`（`:9096`）+ 编译 shader（注释 `:6260-6262` 称「466 行 shader，~100ms-1s」）
2. `MTKView`（`:9235-9237`）常开渲染，仅遮挡时暂停（`:9105-9111` `installOcclusionGuard`，`:9132` `view.isPaused = !visible`）
3. 数据流：`EngineClient.wantPixelBuffer = true` → `poll()` 走 `copyIntoPixelBuffer`（`:660`）→ **IOSurface 缓冲**（`:493`）→ `upscaleHost.push(pixelBuffer:)`（`:6701`）→ `drain()` → `engine.ingest(pixelBuffer:)`（`:9192`）→ **GPU 处理** → `MTKView` 呈现

**判定**：
- **这是用户主动选择的功能**（插帧/超分），**不是浪费**
- 但**开启即违反「GPU 绝不占用」铁律** —— 需要在文档中标明「该功能与铁律冲突，默认关闭是对的，不要开」
- 补充：`:9181-9184` 注释「池缓冲会被 `processCapturedTexture` retain 到渲染完成」⟹ MetalGoose 确实在 GPU 上处理

**建议**：不改代码。**在用户可见处标注「插帧档会使用 GPU」**（若已有标注则无需动）。

---

## 6. 可执行改法（按收益/风险排序）

> 纪律：只做「纯浪费清理」，不降质量/不降频/不降精度/不砍功能。以下改法均满足。

### R1 · 【推荐·中收益】`lanczosResize` 改 CPU vImage（消除 G1 的 45Hz GPU 提交）

**问题**：`SpeedOCRReader.swift:1384-1392` 用 `CIContext` 做 Lanczos 缩放，Apple Silicon 上必然走 Metal。

**改法**：改用 vImage Lanczos（`vImageScale_ARGB8888` 的 `kvImageHighQualityResampling` 标志，或 `vImageScale_Planar8` 若已转灰度）。**该文件已大量使用 CPU 路径，风格一致**（`CaptureEngine.swift:1170` 同款）。

```swift
// 现状（SpeedOCRReader.swift:1384-1392）
nonisolated private static func lanczosResize(_ cg: CGImage, toWidth: Int, toHeight: Int) -> CGImage? {
    let ci = CIImage(cgImage: cg)
    ...
    return ciContext.createCGImage(scaled, from: rect)   // 🔴 GPU
}

// 改法骨架（复用文件内已有的 CGContext/裸指针风格，与 cgImageFromPixelBuffer 一致）
nonisolated private static func lanczosResize(_ cg: CGImage, toWidth: Int, toHeight: Int) -> CGImage? {
    guard toWidth > 0, toHeight > 0, cg.width > 0, cg.height > 0 else { return nil }
    // 1. CGContext(data: nil, ...) 建目标位图（CPU）
    // 2. 把源 CGImage 画进去（CPU）
    // 3. 用 vImageScale_ARGB8888(kvImageHighQualityResampling) 做高质量缩放
    //    —— 注意：Lanczos 与 vImage 高质量核不完全等价，需在冻结测试集上验证精度
}
```

**⚠️ 风险（必须验证）**：注释 `:1307-1308` 明说「对齐训练端 PIL LANCZOS」是「速度模型乱读的病根」的修复。**换成 vImage 高质量核可能改变插值结果 ⟹ 违反「不降精度」**。

**因此更稳妥的改法**：**保持 `lanczosResize` 的算法不变，只把 `CIContext` 换成 CPU 实现**——即用 `CGContext` 的 `.highQuality` 插值 + 自定义 Lanczos 卷积核（纯 CPU 循环）。**代价是 CPU 上升，但符合用户「允许拿 CPU 换」。**

**验证方法**：在 `--speed-ocr-selftest` 上用冻结测试集对比改前/改后的识别率与每槽像素 diff。**未测，必须先验证再上。**

### R2 · 【推荐·低风险】`AURORA_OCR_CI=1` 与调试存图加 `#if DEBUG`

**问题**：
- `:973` 的 `else` 分支（`ciContext.createCGImage`）只在 `AURORA_OCR_CI=1` 时走 —— **生产不应存在这个开关**
- `:1492` 调试存图（`writePNG` 到 `/tmp`）每 10 秒一次 GPU 提交

**改法**：
```swift
// :969 附近
#if DEBUG
if isROISlice || ProcessInfo...["AURORA_OCR_CI"] != "1" {
    cg = Self.cgImageFromPixelBuffer(...)
} else {
    cg = ciContext.createCGImage(input, from: input.extent)
}
#else
cg = Self.cgImageFromPixelBuffer(...)   // 生产恒走 CPU，开关消失
#endif
```
调试存图同理用 `#if DEBUG` 包裹（`:1470-1500`）。

**风险**：极低（生产行为不变）。**收益**：消除「误设环境变量导致长期 GPU 占用」的隐患。**未测**实际发生频率。

### R3 · 【可选·微收益】引擎模式 `push` 对齐 local 模式的门控

**问题**：`AuroraDriveApp.swift:6717` 每 tick 都 push，多数 tick 是同一个 CGImage；对照 `:7194` 有 `if let latest` 门控。

**改法**：让 `EngineClient.poll()` 增加「是否新帧」输出（例如返回 `(CGImage?, isNew: Bool)`，或新增 `var lastPollWasNewFrame: Bool`），`:6717` 改为仅新帧时 push。

```swift
// EngineClient.swift:646 附近
guard seq != lastFrameSeq else {
    lastPollWasNewFrame = false
    return frameCache
}
lastPollWasNewFrame = true
```

```swift
// AuroraDriveApp.swift:6717
} else if let cg {
    ...
    if EngineClient.shared.lastPollWasNewFrame { frameHost.push(cg) }
}
```

**收益**：省每秒 15 次 `layer.contents` 属性写。**未测**（微秒级，很可能在噪声内）。
**风险**：需确保「首次显示」时必推（首帧 `seq` 必变，安全）；`frameHost.clear()` 后重连需重推（`clear()` 已清 `cachedCGImage`，下次新帧会推）。
**判定**：**收益未证实，建议排在 R1/R2 之后**。符合「改动必须有可解释收益」纪律 ⟹ **可暂不做**。

### R4 · 【文档·零风险】修正过期注释

| 位置 | 现状 | 问题 |
|---|---|---|
| `ConfidenceEstimator.swift:247` | 「彻底移除 CIContext（本文件再无任何 CoreImage 调用）」 | **与代码不符**：`:237` `brightnessContext` 仍定义，`:337/:345` 仍使用（只是默认不可达）。**会误导后续排查** |
| `SpeedOCRReader.swift:842-845` | 「替代 `CIContext.createCGImage`」 | 与 `:814/:1391/:1492` 三处仍在用 `createCGImage` **矛盾** |
| `AuroraDriveApp.swift:9202` | `UpscaleFrameHost.cgImage(from:)` 定义完整但无人调用 | **实际无调用点**（死代码）。`grep "cgImage(from:"` 只命中 `LoginAssistant` 同名函数 |

**改法**：只改注释/删死代码，**不动逻辑**。用户偏好「边看边改」，但本审计**只读**，故列入待办。

### R5 · 【未测·需实测才能决策】抓屏 1280×832 的系统侧降采样

**已知线索**（任务给定）：`SCStream` 输出 1280×832 是系统侧降采样，**这一步可能在 GPU**。

**本审计能确认的**：
- 配置确实是 1280×832（`CaptureEngine.swift:618-619`，日志实证）
- `scalesToFit = false`（`:619`），即**只缩不放、不加黑边**
- 源是**原生 Retina 像素**（注释 `:481-483` 称原实现抓 2940×1912，现降到 1280×832 ⟹ **降采样倍数 ≈ 2.3×**）

**本审计无法确认的**：ScreenCaptureKit 内部把 2940×1912 → 1280×832 的缩放**在哪执行**。**这是闭源系统行为，静态代码无法判定。**

**「未测」声明**：要判定这一步是否在 GPU，**必须实测**（例如用 `--capture-only` 模式对比不同输出尺寸下的 GPU 占用，或 Instruments 的 GPU 计数器）。**本审计不启 App，故不做。**

**若实测确认它是 GPU 且占比显著，改法方向**：让 SCStream 直接输出原生尺寸或更接近原生的尺寸（减少系统降采样工作量），再由 CPU vImage 自己缩到 480。**但这会增大 `capWork`（CPU）与共享内存带宽 ⟹ 符合「拿 CPU 换 GPU」，需实测验证是否划算。** **当前不建议盲改。**

---

## 7. 与「GPU 36.4%」的归因关系（诚实边界）

任务给出：驾驶态 GPU 36.4%（待机 0.7%）、GPU 功耗 371mW（待机 4mW）。

**本审计能说的**：

| 段 | 是否碰 GPU | 能否解释驾驶态增量 |
|---|---|---|
| ① 抓屏系统降采样 | 🔴 **可能在 GPU**（闭源，**未测**） | **未知**，需实测 |
| ② vImage 480 缩放 | 🟢 CPU | 不能 |
| ③ CGImage 包装 | 🟢 CPU | 不能 |
| ④ 引擎 publish memcpy | 🟢 CPU | 不能 |
| ⑤ UI poll Data+CGImage | 🟢 CPU | 不能 |
| ⑥ `layer.contents` 合成 | 🔴 GPU | **能解释一部分**，但待机 0.7% 说明 `layer.contents` 本身很轻 |
| ⑦ WindowServer 合成 | 🔴 GPU | **能解释一部分**，与 ⑥ 同源 |
| G1 OCR CIContext | 🔴 GPU | **当前未激活**（PP-OCR 未失败），贡献 ≈ 0 |
| G2 插帧档 | 🔴 GPU | **默认关闭**，贡献 ≈ 0 |

**结论**：**在默认配置、PP-OCR 正常的情况下，像素搬运链路里只有「抓屏系统降采样」和「上屏合成」两处可能吃 GPU**。而待机 0.7% vs 驾驶 36.4% 的差值 **32 个百分点**，**无法由本链路的静态代码全部解释** —— 最可能是：
1. 抓屏系统侧降采样在驾驶态才开始工作（待机不抓屏或抓屏但无内容变化）
2. 游戏自身占用（任务明确「游戏需独占 GPU」，但 36.4% 是**设备级**读数，含游戏）
3. 其他进程

**必须强调**：**本审计没有测量，以上是「代码层面可能性」排序，不是实测归因。** 要真正拆开，需要分别测「只开抓屏不显示」「只显示不抓屏」「全链路」三种状态的 GPU 占用。**建议由有权限启 App 的队友做，或用户自己跑。**

---

## 8. 一页速查表

| 段 | 位置 | CPU/GPU | 每帧成本 | 是否浪费 |
|---|---|---|---|---|
| 抓屏降采样 | 系统（SCStream） | 🔴 GPU？**未测** | 2940×1912→1280×832 | 未知（闭源） |
| 480 缩放 | `CaptureEngine.swift:1219` | 🟢 CPU | `vImageScale` ~0.23ms（既有日志） | 否 |
| CGImage 包装 | `CaptureEngine.swift:1241` | 🟢 CPU | 零拷贝 | 否 |
| 引擎写 shm | `EngineMain.swift:441` (整块) / `:444` (逐行) | 🟢 CPU | 585KB memcpy | 否（双缓冲必需） |
| UI 读 shm | `EngineClient.swift:673` | 🟢 CPU | 585KB 分配+拷 | 否（生命周期必需） |
| **UI 上屏** | **`AuroraDriveApp.swift:9037`** | **🔴 GPU** | **`layer.contents` 赋值** | **否（固有）** |
| 检测框叠加 | `AuroraDriveApp.swift:8948` | 🟡 CPU 光栅 + GPU 合成 | SwiftUI `Canvas` | 否（已去模糊） |
| OCR Lanczos | `SpeedOCRReader.swift:1391` | 🔴 **GPU（漏点）** | 45 次/秒（降级时） | **是（可删）** |
| 插帧档 | `AuroraDriveApp.swift:9096` | 🔴 GPU | 整帧 GPU 处理 | 否（用户可选） |
| 引擎模式 push | `AuroraDriveApp.swift:6717` | 🔴（合成） | 每秒 15 次属性写 | **微浪费（可优化）** |

---

## 9. 只读声明与未测清单

**本审计执行了**：
- ✅ 全仓 `grep`：`CGImage(` / `CIContext.createCGImage` / `createCGImage` / `CVPixelBufferGetBaseAddress` / `CVPixelBufferLockBaseAddress` / `CIContext` / `MTLCreateSystemDefaultDevice` / `MTKView` / `IOSurface` / `AVAssetWriter` / `VTCompressionSession` / `VNImageRequestHandler`
- ✅ 逐段读源码：`EngineClient.swift:635-700`、`EngineMain.swift:182-250, 340-460, 480-530, 1480-1590`、`CaptureEngine.swift:480-650, 1110-1260, 1289-1450`、`AuroraDriveApp.swift:6690-6740, 7046-7200, 8790-8975, 9021-9240`、`SpeedOCRReader.swift:559-625, 818-1000, 1280-1320, 1378-1500`、`ConfidenceEstimator.swift:225-362`、`MissionConsole.swift:570-600, 6225-6262`
- ✅ 读既有日志：`~/Library/Logs/AuroraEngine.log`、`~/Library/Logs/AuroraEngineClient.log`

**本审计未执行（遵守纪律）**：
- ❌ 未修改任何源码（本文件是唯一新增产物）
- ❌ 未 `swift build` / `./run.sh`
- ❌ 未启动 App（含 `--engine`、任何 `--xxx-selftest`）
- ❌ 未做任何 GPU 计数测量
- ❌ 未测量「抓屏系统侧降采样是否走 GPU」

**明确「未测」的结论**：
1. `SpeedOCRReader.swift:814` 在默认配置下是否执行 —— **未测**
2. `MissionConsole.swift:2440-2443` 的 `NSImage → CGImage` 是否触 GPU —— **未测**
3. `UpscaleFrameHost.cgImage(from:)`（`AuroraDriveApp.swift:9202`）是否真是死代码 —— **静态看是（全仓唯一命中即定义行），未做运行时验证**
4. 抓屏 1280×832 系统侧降采样的 GPU 占比 —— **未测**（闭源）
5. GPU 36.4% 各段占比 —— **未测**（本审计不启 App）
6. R1/R2/R3 改法的实际收益 —— **未测**（未实施）

---

**审计人**：pixel-path 审计（只读）
**产物**：`docs/perf-audit-gpu/7-pixel-path.md`（唯一文件）
