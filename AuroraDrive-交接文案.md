# AuroraDrive 项目交接文案

> **生成时间**：2026-09-29
> **项目路径**：`/Users/dupi/Desktop/自动驾驶系统`
> **当前二进制**：`AuroraDriveUI`（MD5 `0f4f193a34a4c6bf7527d51964b74625`，2026-09-28 22:19）
> **代码规模**：26,440 行 Swift，**41 个文件**（`Sources/` 下实测 `wc -l`；若含 5 个 Vendor/Engine 文件则 46 个）
> 📌 **订正说明（2026-09-29）**：原文写「49 个文件」。实测 `find Sources -name "*.swift" | wc -l` = **41**。
> 26,440 行是准确的，**只有文件数错**（推测是拿行数或含 vendor/备份文件时凑出的数字）。
> `Package.swift` 的 `sources:` 白名单实测 **44 条**（39 个 `Sources/AuroraDrive/` + 5 个 Vendor/Engine），
> 零遗漏、零幽灵。
> **当前状态**：构建通过、自检 46/46 + 7/7 + 15/15 全绿、无残留进程、0 文件删除

---

## 一、这是什么项目

让 AI 自动玩《异环》（Neverness to Everness，NTE）的端到端驾驶辅助系统。
macOS 原生 Swift 应用，截屏 → 视觉推理 → 决策 → 注入按键，闭环控制游戏角色开车。

**架构是双进程的**，这点是理解一切的前提：

```
┌─────────────────────┐        共享内存 72MB          ┌──────────────────────┐
│  AuroraDriveUI      │◄──── /aurora_frame_v1 ────►│  AuroraDriveUI       │
│  （UI 进程）         │         + Unix socket        │  --engine（引擎进程） │
│  · SwiftUI 界面      │                              │  · 截屏 SCStream      │
│  · 绘制掩码/框        │      心跳 1Hz + 命令          │  · YOLOPX/YOLO 推理   │
│  · 不跑推理           │                              │  · 决策 + 按键注入    │
└─────────────────────┘                              └──────────────────────┘
```

**关键**：UI 进程**不跑任何推理**。它在引擎模式下只是个显示器 + 遥控器，
所有画面/检测框/掩码都从共享内存读。本地模式（引擎起不来时）才自己跑。

---

## 二、🚨 绝对红线（碰了项目就完）

按严重程度排序。前三条是用户的死线，违背后果最严重。

### 1. 模型绝对不能换、不能改一个字节

**用户原话**：
> "必须用 you low 系的优罗披萨，那个模型，千万不能换……如果一旦换了这个模型
> 或者换成别的模型，那么立马原地爆炸，我们整个项目可能会解散。"

YOLOPX 三头模型（det 检测 / da 可行驶区 / ll 车道线）是**甲方出资的核心资产**。
替换它 = 项目解散。

**冻结的模型文件与 MD5**：

| 文件 | MD5 |
|---|---|
| `models/yolopx/yolopx3_pal8_detfp.mlmodelc/weights/weight.bin` | `9df176e15816314dc240de8d7817f43a` |
| `models/yolo26s.mlmodelc/weights/weight.bin` | `eaeeec9fd80e8df77dfb21839c79bc9b` |

**注意分工**：`yolo26s` 是拿来做**预测**的；`yolopx3` 才是主感知模型。

**已实测否决、不许再试的优化**（都是想加速 YOLOPX 的尝试，全部负收益）：

| 尝试 | 结果 |
|---|---|
| w8 量化 | 64.78ms，**无增益** |
| w4 量化 | ll IoU 掉到 0.7808 |
| w8a8 | ll IoU **0.4395**（崩） |
| a8 | 93.58ms **更慢**，ll IoU 0.4183 |
| 改 stem stride | 74.37ms 更慢 |
| 关解码 | 无增益 |
| 归一化烘进 conv | 58.18ms |
| 换 TwinLiteNet | 否决（换模型） |

**结论：YOLOPX 就该是 44~53ms（实测 p50 46.5ms / p95 50.0ms），这是硬件物理极限，别再折腾。**

---

### 2. 严禁删除或覆盖**任何**既有文件

用户曾因 AI "清理" 损失**三万多人民币**。这是不可协商的铁律。

**每次干活后必须自证**：

```bash
git status --porcelain | grep -c '^ D'    # 必须输出 0
```

**已犯过的错**：把备份二进制放进 `AuroraDriveUI.app/Contents/MacOS/` 里，
破坏了 bundle 签名 → `invalid Info.plist`。备份现在放 `_bak_binaries/`。

---

### 3. 光流性能红线：≤5ms，必须 640×640，必须用 OpenCV

**用户原话**：
> "必须给我压到五毫秒以内"
> "可是我们要的是640×640"
> "我让你去找开元的小刘"（开源框架，不许手搓）
> "open CV拉下来试一下"

**当前实现（生产参数，别动）**：

| 项 | 值 | 位置 |
|---|---|---|
| 算法 | OpenCV DIS `PRESET_ULTRAFAST` | `flow_bridge.cpp:101` |
| 工作分辨率 | **640×640** | `OpticalFlowBridge.swift:91` |
| 中值采样步长 | `kMedianSampleStep = 4`（4:1 抽样） | `flow_bridge.cpp:40` |
| OpenCV 线程 | `kOpenCVThreads = 2` | `flow_bridge.cpp:60` |

**⚠️ 线程数为什么是 2 而不是全核**：默认全核在 7 路负载下 p95 飙到 **20.86ms**；
设成 2 稳定在 **3.53ms**。**线程多 ≠ 快**。

**实测成绩**（真实游戏画面，非合成图）：

```
DIS ULTRAFAST, 640×640, setNumThreads(2):
  合成块状图（早期误测） p50=1.061ms  p95=1.689ms
  真实游戏画面          p50=0.957ms  p95=1.251ms
```

**已否决的光流方案（别重试）**：

| 方案 | 实测 | 结论 |
|---|---|---|
| Apple `VTOpticalFlow` | 10.28ms | 慢 10 倍 |
| Vision `VNGenerateOpticalFlow` | 27.43ms | 慢 27 倍 |

---

### 4. 不许降低帧率、不许降分辨率

用户明确要求：**30fps 不能降，分辨率不能降**。
性能优化只能在"不减功能、不减循环、不减逻辑"的前提下做。

### 5. 量化只能用 8bit

> "FP16绝对不行，只能8"

### 6. 光斑（bloom）是功能不是装饰

用户偏好：空间感光斑 + 高对比度 + 纯深色背景 + 极淡网格的**玻璃拟态**，
拒绝低对比度发灰的毛玻璃。**光斑不许删、不许减。**

### 7. 不许说"我觉得没问题"

必须**实测**。用户原话："不许你觉得没问题"。
改完必须跑自检 + （UI 改动）抓真实堆栈验证。

---

## 三、模块地图与文件职责

**41 个 Swift 文件（`Sources/` 实测；含 Vendor/Engine 共 46），26,440 行**。按职责分七层。**改任何东西前先看这张表**。

### 3.1 目录结构与行数（按大小排序）

| 文件 | 行数 | 职责 |
|---|---|---|
| `App/AuroraDriveApp.swift` | **5175** | 主状态机 + 所有 Overlay 视图 + tick 驱动 |
| `App/MissionConsole.swift` | **3952** | 整个 UI 布局（预览框、左右栏、状态面板） |
| `Agent/AIAgentPanel.swift` | 2639 | AI 助手面板 |
| `Inference/SpeedOCRReader.swift` | 1243 | 车速表 OCR（Vision + PP-OCRv6） |
| `Inference/YolopxEngine.swift` | 1124 | **YOLOPX 三头模型封装（核心）** |
| `Capture/CoordinateCapture.swift` | 1083 | 坐标采集 |
| `Core/EngineMain.swift` | 1082 | **引擎进程主循环 + 共享内存写端** |
| `Inference/YoloEngine.swift` | 835 | yolo26s 检测（预测用） |
| `Core/EngineClient.swift` | 747 | **UI 侧共享内存读端 + socket 客户端** |
| `Locate/NetworkLocator.swift` | 656 | 网络定位 |
| `Capture/CaptureEngine.swift` | 654 | **SCStream 截屏（关键：queueDepth=3）** |
| `Locate/VisualLocator.swift` | 491 | 视觉定位 |
| `App/ControlWiring.swift` | 475 | 控制接线 |
| `Inference/InferenceEngine.swift` | 432 | M9 端到端模型 |
| `Inference/MotionPredictor.swift` | 425 | **α-β 滤波 + 光流补帧** |
| `Capture/RecordEngine.swift` | 424 | 录制 |
| `Inference/OpticalFlowBridge.swift` | 384 | **光流 Swift 封装（640×640）** |
| `Control/ControlEngine.swift` | 373 | 按键注入 |
| `App/AuroraTheme.swift` | 373 | **主题 + 光斑 AuroraLightField** |
| `Inference/LaneFallback.swift` | 365 | 车道线兜底 |
| `Agent/AgentLoop.swift` | 325 | Agent 循环 |
| `Core/PrivilegePill.swift` | 308 | 权限提示 |
| `Agent/FallbackGuard.swift` | 280 | **双结构兜底（自车位置 + 碰撞）** |
| `App/MapWiring.swift` | 254 | 地图接线 |
| … | | 其余为辅助模块 |

### 3.2 七层架构

```
① 采集层    CaptureEngine（SCStream 30Hz）
            → 池化 CVPixelBuffer（⚠️ 生命周期只在回调内）
                ├─ onYoloFrame    → 640×640 BGRA（喂 YOLO + 光流）
                ├─ onNativeFrame  → 全屏原生（喂 OCR）
                └─ onFrame        → 480px（喂 UI 显示）

② 推理层    YolopxEngine   640×640 → det/da/ll 三头（46.5ms）
            YoloEngine     640×640 → 检测框（4.6ms，预测用）
            InferenceEngine M9 端到端（决策）
            SpeedOCRReader  ROI → 车速数字

③ 融合层    MotionPredictor  α-β 滤波（α=0.55 β=0.25）+ 光流补帧
            OpticalFlowBridge OpenCV DIS 640×640（0.96ms）
            LaneFallback    车道线延伸兜底

④ 决策层    RuleController  规则控制
            FallbackGuard   双结构兜底
            DegradeStateMachine 降级状态机

⑤ 控制层    ControlEngine → KeyboardMonitor → 按键注入

⑥ 传输层    EngineMain（写端）⇄ EngineClient（读端）
            共享内存 72MB /aurora_frame_v1 + Unix socket 心跳 1Hz

⑦ 显示层    MissionConsole（布局）
            AuroraDriveApp 里的 Overlay：
              ObstacleOverlay  检测框
              MaskOverlay      可行驶区 + 车道线 ← 本会话修的重点
              AuroraLightField 光斑（最贵单项 4.2ms）
```

### 3.3 数据流（引擎模式）

```
游戏画面
   │ SCStream
   ▼
CaptureEngine ──┬─► onYoloFrame(640×640) ──┬─► YolopxEngine.infer → det/da/ll
                │                          └─► OpticalFlowBridge.compute → 运动向量
                └─► onFrame(480px CGImage) ────► EngineMain.publish → 共享内存像素页
                                                      │
YolopxEngine.metrics/drivableMask/laneMask ──────────┤
YoloEngine.detections ───────────────────────────────┤
                                                      ▼
                                          ┌───────────────────────┐
                                          │  共享内存 72MB        │
                                          │  /aurora_frame_v1     │
                                          └───────────────────────┘
                                                      │ EngineClient.poll()
                                                      ▼
                                          ┌───────────────────────┐
                                          │  UI 进程               │
                                          │  displayDrivableMask   │
                                          │  displayLaneMask       │
                                          │  effectiveDetections   │
                                          └───────────────────────┘
                                                      │
                                                      ▼
                                          MaskOverlay / ObstacleOverlay 绘制
```

**⚠️ 关键认知**：UI 进程与引擎进程的数据来源**完全不同**。
`displayXxx` 系列访问器就是干这个的：

```swift
var displayDrivableMask: MaskGrid {
    EngineClient.shared.isActive ? EngineClient.shared.engineDrivableMask
                                 : yolopxEngine.drivableMask
    //                            ↑ 引擎模式读共享内存    ↑ 本地模式读自己的
}
```

**⚠️⚠️ 绝对不能直接写 `yolopxEngine.drivableMask`** —— 引擎模式下 UI 进程
**从不跑 YOLOPX**，那个字段永远是 `.empty`。这正是"预览框里看不到可行驶区"
的根因（2026-09-27 排查确认，见 `AuroraDriveApp.swift:3136` 的注释）。

---

## 四、🚨 24 条历史坑（全部真实发生过）

这些是项目积累的血泪。**新接手的人最该先读这一节**，能省几天时间。

### 崩溃类（1-5）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| **1** | 启动即 SIGBUS，栈指向 libpcap | Apple Silicon PAC 校验函数指针，Swift 闭包转 `@convention(c)` 跨 PAC 边界签名失效 | 弃用 `pcap_loop` 回调，改 `pcap_next_ex` 阻塞循环 |
| **2** | pcap 正常后随机 SIGTRAP | UE5 有符号向量解码 `v -= modulus`，扫到垃圾位时 UInt64 下溢 | `v = v &- modulus`（回绕减法） |
| **3** | 接入真实流量才崩 | 短包时 `payload.count*8-60 < 190`，`for offset in 190..<searchEnd` Range 反转 | `guard searchEnd > 190` + 全套长度防护 |
| **4** | pcap 成功但永远 0 包 | `pcap_lookupdev` 只返回默认路由网卡（en0），游戏流量走 en8 | `pcap_findalldevs` 枚举全部，逐个试 |
| **5** | 速度数字裁剪位置系统性偏移 | SCK/CVImageBuffer 行序与 CGImage y 方向相反 | `ciRect.y = sh - yMax` 显式镜像 |

**共性教训**：**位流扫描器必须在"输入可能是任意位模式"的前提下写**。
所有算术都要防御，Range 字面量是 Swift 最常见的隐藏陷阱。

### 环境/构建类（6-13）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| **6** | BPF 权限重启即失效 | macOS 每次启动重建 `/dev/bpf*`，权限回 root-only | 装 `com.aurora.bpf-setup` LaunchDaemon（RunAtLoad） |
| **7** | SwiftUI App 的 print 不见了 | 裸可执行 SwiftUI 的 stdout 不回终端 | 写文件日志（`FileHandle seekToEnd` 追加，**不要"读全文+append+写回"**，10Hz 下 IO 爆炸且互相覆盖） |
| **8** | CoreML 报 "Compile the model" | 新版 macOS 不再隐式编译 `.mlpackage` | `MLModel.compileModel(at:)` 显式编译；或直接用 `.mlmodelc` |
| **9** | SIGKILL "Code Signature Invalid" | `xattr -cr` 删掉了签名本身；或先签名再 cp（cp 破坏签名） | 固定顺序：`build → cp 到目标 → codesign 目标 → xattr -d com.apple.quarantine` |
| **10** | 宏插件 "malformed response" | `xcode-select` 指向中文路径外置盘的 Xcode | 工具链装到无中文的本地路径 |
| **11** | 链接期一片 undefined symbol | 静态 OpenCV 库非自包含：ARM HAL 在 `libtegra_hal.a`/`libkleidicv*.a`，BLAS 走 `Accelerate` | `linkerSettings` 补 11 个 `.linkedLibrary` + `.linkedFramework("Accelerate")` |
| **12** | `ld: library not found` 但库确实在 | ① `-L` 相对路径在 **link 阶段**按产物目录解析 ② `Vendor/opencv/lib` 曾是自指符号链接 | `-L` 一律用**绝对路径**（`#filePath` 推导包根）；静态库必须是**实体文件** |
| **13** | manifest 里 `String` 没有 `replacingOccurrences` | SwiftPM manifest 在受限沙盒编译，**只有标准库，没有 Foundation** | 改用纯标准库 API（`lastIndex(of:)` + 切片） |

**共性教训**：**签名操作的对象和顺序是强约束**；
构建系统里的路径基准点（cwd vs 产物目录）必须显式确认。

### 并发/性能类（14-16）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| **14** | 光流偶发读到"错帧" | `CaptureEngine` 直通缓冲是**池化私有缓冲**，`inferFast` 拷完就归还池子，下一帧可能拿到同一 IOSurface 被覆写 | 在**帧消费点同步**完成灰度转换（转成自己的私有缓冲即与池子解耦） |
| **15** | 同份光流代码，空载 p95 1.7ms，加负载后 12.96ms | 测的是**主线程默认 QoS**，不是生产的 `.userInteractive` | 自检显式 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)` |
| **16** | DIS 默认全核在 7 路负载下 p95 20.9ms | 线程越多，被抢占方式越杂乱，**尾延迟越差**。空载 nt=4 最快，但生产不是空载 | `cv::setNumThreads(2)` → 3.53ms |

**共性教训**：
- **池化缓冲的生命周期只在当前回调内有效**，跨步骤传递必须显式拷贝
- **性能判据必须对齐生产的调度条件**，否则测出来的数没有意义
- **并行度要按最差工况选，不是按空载最快选**

### 诊断/设计类（17-20）—— 这四条最"哲学"

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| **17** | 用户报"看不到车道线"，自检却打印 `可行驶占比 0.00%`，像"模型没输出" | **那行数字是字段初值，不是测量结果** —— 自检里 `engine.infer()` 一次都没调用过 | 给自检加真实推理（A2 节），实测 `da=3772 ll=1158` → **模型一直是好的，问题在显示层** |
| **18** | 车道线看不见，**连可行驶区也一起看不见** | `isDegraded` 是 da/ll 的**或**关系，却同时控制两层显示。车道线是细目标（占比 1.3~2.6%，贴近下限），一塌陷就把可行驶区压暗到 `0.18 × 0.35 = 0.063` | 拆成 `laneDegraded`/`drivableDegraded` 分别调暗；**决策层继续用合并的 `isDegraded`**（不引入新风险） |
| **19** | `convertToGray` 实测 1.43ms，远超预期 | 内层循环逐像素算 `x * srcW / dstW`，而生产路径 640→640 时**这个除法恒等于 x** | 加 `sameSize` 快路径：0.639ms → **0.040ms（16×）** |
| **20** | 自写 shm 往返脚本报"5 项失败，逐格差异 6500" | **脚本自己写错了**（位序、偏移、清零行为与生产不一致） | 改**单格探针**：9/9 精确命中，证明生产实现逐格无损 |

**这四条的教训（值得单独强调）**：

> **17. 打印一个未被赋值的字段，等于伪造证据。**
> 自检里的每个数字都要能追溯到一次真实调用。
> "看起来在验证"的检查项比没有检查更危险。

> **18. 合并指标适合做决策门控（宁可保守），不适合做显示分层。**
> 显示要如实表达"哪一部分不可信"，而不是"有任意一部分不可信就全体变暗"。
> ⚠️ 协议设计注意：新增 bit 时旧发送方不发该位 → 恒为 0，
> **要确认这个默认值落在安全方向**（这里是"不压暗"= 偏亮，能看见）。

> **19. 把"恒定成立"的条件也当变量算，是缩放类代码最常见的性能坑。**
> 写通用循环时先问一句：生产路径上这个量真的是变的吗？

> **20. 验证工具要先自证。**
> "测试失败"的第一反应应是怀疑测试本身 ——
> 尤其当失败模式呈现"格数对但逐格差"这种**置换特征**时，
> 真实 bug 通常不会这么整齐。单点确定性探针比整体比对更快定位。

### 本会话新增（21-24）—— 全部是我犯的

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| **21** | 开自动驾驶卡到不能动 | `.drawingGroup()` 用在有 `.offset` 动画的子树上 → 离屏纹理每帧重建 | 移除，见 §8.1 |
| **22** | capGap/capWork 雪崩到 2081ms | 把光流放进 `captureQueue`，而那是 SCStream 采样队列（queueDepth=3） | 移回主线程，见 §8.3 |
| **23** | 僵尸引擎跑 18 小时 | `pkill -f "AuroraDrive --engine"` 不匹配 `AuroraDriveUI --engine`，且 `2>/dev/null` 吞了报错 | 杀前先 `pgrep -fl` 确认，不吞报错 |
| **24** | 引擎模式下掩码一个格都不画 | `MaskOverlay` 守卫用 `newW > 0`，而协议从没传过 `newW` | 补进协议 + 去掉守卫依赖，见 §8.2 |

**这四条的共同特征**：**我都有"理论依据"，但都没在真实场景验证。**
21/22 是离线微基准误导，24 是本地自检覆盖不到引擎模式。

---

## 五、核心算法链路

### 5.1 视觉方案（用户亲自定的架构）

**15Hz 检测 + 30Hz 跟踪/光流互补**：

```
YOLOPX 15Hz（46.5ms/帧）
   │
   ├─► 检测框 → α-β 滤波 + 光流补帧 → 30Hz 平滑目标
   │
   └─► 掩码（可行驶区 da + 车道线 ll）
          │
          └─► 延伸车道线 + 可行驶区
                 │
                 └─► 双结构兜底：
                      ① 最大检测框 = 自车位置
                      ② 检测框重叠 = 即将碰撞 → 紧急避让
```

### 5.2 α-β 滤波器参数（`MotionPredictor.swift`）

| 参数 | 值 | 依据 |
|---|---|---|
| `alpha` | **0.55** | 压掉约一半逐帧抖动，滞后 <1 帧 |
| `beta` | **0.25** | 远小于稳定上界 2.9 → 收敛慢但不震荡 |
| `maxPredictionFrames` | 10 | 30Hz 下 0.33s；YOLOPX 15Hz 正常间隔约 2 帧 |
| `maxMissingFrames` | 30 | 30Hz 下 1s（比 `YoloEngine` 的 15 帧更宽松，容忍低频+遮挡） |
| `velocityConfirmFrames` | 3 | 未确认前不外推，只做位置平滑 |

**速度单位 = 归一化坐标/秒**。
`predict(dtSeconds:)` **每 tick 只能调一次**（它是帧驱动器，多调会推进多次帧计数）。

**α 的来历**：YOLO 框逐帧抖动实测约 1~2%（IoU 0.95+），
α=0.55 能把抖动压掉约一半同时保持跟踪。
与 `YoloEngine.smooth()` 的 α 保持一致，避免两处平滑参数打架。

### 5.3 掩码网格参数（`YolopxEngine.swift`）

| 参数 | 值 | 说明 |
|---|---|---|
| `inputSize` | **640** | 模型输入 |
| `maskGridSize` | **160** | 掩码网格（每格 = 4 模型像素） |
| `lanePositiveFloor` | **0.002** | 车道线前景占比下界 |
| `lanePositiveCeil` | **0.25** | 车道线上界 |
| `drivablePositiveFloor` | **0.02** | 可行驶区下界 |
| `drivablePositiveCeil` | **0.70** | 可行驶区上界 |

**已知待核对**：实测 `ll` 占比 8.042%，而代码注释里标定 1.3~2.6%。
`ceil=0.25` 远高于 8%，**不影响判定**，但注释与实测不符。

**降级判定是分开的两层**（§24 坑 18 的修复成果）：
- `laneDegraded`：车道线前景占比触顶/触底
- `drivableDegraded`：可行驶区前景占比触顶/触底
- `isDegraded = laneDegraded || drivableDegraded`（**决策层用这个**）

---

## 六、运动预测流水线详解（15Hz→30Hz 的关键）

> 📌 **编号订正（2026-09-29）**：本节子节原误标为 `7.x`（与第七章重号）。
> 下方已改为 `6.x`，**内容一字未改**。

这是整个感知链路**最精妙的部分**，也是用户亲自设计的方案。

### 6.1 光流读数结构（`OpticalFlowReading`）

```swift
struct OpticalFlowReading: Equatable {
    let dx: Double          // 全局中位水平流（像素）。正 = 画面内容向右移动
    let dy: Double          // 全局中位垂直流（像素）。正 = 内容向下移动
    let divergence: Double  // 径向外向散度（像素）
    let timestamp: Date     // 采样时刻（用于预测器算 dt）
    var magnitude: Double { (dx*dx + dy*dy).squareRoot() }
}
```

**⚠️ `dy` 的符号约定容易搞反**：
自车前进时地面纹理在画面里**向下扩散**（远小近大），故**前进对应 `dy > 0`**。

**`divergence` 是判断前进/后退的关键**：
- `> 0` → 内容从画面中心向外扩张 → **自车前进**
- `< 0` → 内容向中心收缩 → **自车后退**

### 6.2 `OpticalFlowBridge` API

| 成员 | 说明 |
|---|---|
| `workingSize = 640` | 工作分辨率（**红线，不许改**） |
| `preset = AD_DIS_ULTRAFAST` | OpenCV DIS 预设 |
| `elevateCurrentThreadPriority()` | `pthread_set_qos_class_self_np(USER_INTERACTIVE, 0)` |
| `process(gray:)` | 处理一帧灰度 |
| `compute(gray:)` | 同上（主入口） |
| `reset()` | 重置 previousGray |
| `makeGrayBuffer(size:)` | 创建 640×640 单通道缓冲 |
| `convertToGray(_:into:)` | 32BGRA → 灰度（**有 sameSize 快路径**） |

**⚠️ `elevateCurrentThreadPriority()` 只在自检里调用，不在生产路径**
（生产 tick 由 `.userInteractive` 队列驱动，天然是高优先级）。
**别在 SCStream 采样队列里调用它** —— 那会把采集线程永久提到最高 QoS。

### 6.3 `MotionPredictor` 完整参数

```swift
var alpha: Double = 0.55                    // 位置平滑系数
var beta: Double = 0.25                     // 速度平滑系数
var maxPredictionFrames: Int = 10           // 超过这么多帧没真值 → 停止外推
var maxMissingFrames: Int = 30              // 超过这么多帧 → 判定目标消失
var velocityConfirmFrames: Int = 3          // 速度确认所需连续一致帧数
var maxPredictStep: Double = 0.15           // 单帧外推的最大步长（归一化）
var associationIoU: Double = 0.25           // 帧间关联的 IoU 阈值
```

**内部状态**：
```swift
private var tracks: [Int: Track] = [:]
private var nextID: Int = 1
private var frameCounter: Int = 0
private var lastIngestDt: Double = 1.0/30.0
```

### 6.4 α-β 滤波的核心公式（`ingest` 里）

```swift
// 位置更新（α）
let newX = t.detection.x + (detection.x - t.detection.x) * alpha
let newY = t.detection.y + (detection.y - t.detection.y) * alpha

// 时间跨度（距上次观测的秒数，防 0 除）
let frameDelta = max(1, frameCounter - t.lastObservationFrame)
let dtSpan = max(dtSeconds * Double(frameDelta), 1e-4)

// 速度更新（β），残差 = 实际位移 - 预测位移
let residualX = (detection.x - t.detection.x) - t.velocityX * dtSpan
let residualY = (detection.y - t.detection.y) - t.velocityY * dtSpan
let newVX = t.velocityX + beta * residualX / dtSpan
let newVY = t.velocityY + beta * residualY / dtSpan
```

**速度可信性双判据**（防噪声当速度）：
```swift
let sameDir = (newVX * t.velocityX >= 0) && (newVY * t.velocityY >= 0)  // 方向一致
let magnitudeOK = abs(newVX - t.velocityX) < 4.5 && abs(newVY - t.velocityY) < 4.5
```

### 6.5 `TrackedTarget` 输出结构

```swift
struct TrackedTarget: Equatable {
    let id: Int                      // 稳定 ID（跨帧不变）
    let detection: Detection         // 已外推到"此刻"的框
    let velocityX: Double            // 归一化坐标/秒
    let velocityY: Double
    let isPredicted: Bool            // true = 本帧无真值，位置是猜的
    let framesSinceObservation: Int  // 距上次真值观测的帧数
    let isVelocityReliable: Bool     // 速度是否已确认
}
```

**⚠️ 代码注释里的明确警告**：
> 决策层**必须**对 `isPredicted == true` 的目标降权：外推精度低于真值，
> 尤其在目标机动（急转/急刹）时误差会累积。

**（这条目前还没做，见 §12.4）**

### 6.6 外推的硬限幅（防甩飞）

```swift
var stepX = t.velocityX * dtSeconds
var stepY = t.velocityY * dtSeconds
let stepLen = (stepX*stepX + stepY*stepY).squareRoot()
if stepLen > maxPredictStep {                 // 0.15
    let scale = maxPredictStep / stepLen
    // 按比例缩放
}
```

**预测越久，置信度越衰减**：
```swift
let decayedConfidence = missing > 0 ? /* 衰减 */ : /* 原值 */
```

### 6.7 正确调用顺序（30Hz tick 内）

```swift
// 1. 光流出结果时喂给它（用于校验全局运动方向）
predictor.updateEgoMotion(flow)

// 2. YOLOPX / yolo26s 出新检测时喂真值
predictor.ingest(detections: dets)

// 3. 每帧取外推后的目标
let targets = predictor.predict(dt: dt)
```

**⚠️⚠️ `predict(dtSeconds:)` 每 tick 只能调一次** ——
它是**帧驱动器**（内部推进 `frameCounter`），多调会推进多次帧计数，
速度估计直接错乱。

而 `effectiveDetections` 每 tick 会被读多次，所以它读的是
`predictorDetections`（由 `updateMotionPipeline` 每 tick 更新一次），
**绝不在这里调 `predict()`**。

---

## 七、共享内存协议（v3）

> 📌 **编号订正（2026-09-29）**：本节子节原误标为 `6.x`（与第六章重号）。下方已改为 `7.x`，**内容一字未改**。

**名字**：`/aurora_frame_v1`　**大小**：72 MB　**协议版本**：`3`

### 7.1 头部布局（关键偏移）

| 偏移 | 类型 | 字段 |
|---|---|---|
| 0 | u32 | magic `AURF` (0x41555246) |
| 4 | u32 | version (=1) |
| 8 | u32 | headerSize (=4096) |
| 12 / 16 / 20 | u32 | detOffset / detCapacity / detStride |
| 24 / 28 | u32 | frameWidth / frameHeight |
| 32 | u32 | generation（分辨率变化 +1） |
| 36 | u32 | activePage（0/1，翻转即新帧） |
| 40 | u64 | frameSeq |
| 48 | u64 | timestampNs |
| 56 | u32 | detectionCount |
| 60 | u32 | flags（bit0 isDriving / bit1 isStreaming） |
| 64 | u32 | fpsMilli（fps×1000） |
| 68 | u32 | enginePid |
| 72 | u64 | pageSize |
| 80 | u64 | **maskSeq**（掩码世代号） |
| 88 / 92 | u32 | maskW / maskH（可行驶区网格） |
| 96 / 100 | u32 | laneW / laneH |
| 104 | u32 | maskFlags |
| 108 | f32 | maskRatio（letterbox ratio） |
| 112 / 116 | u32 | maskPadX / maskPadY |
| 120 / 124 | u32 | maskSrcW / maskSrcH |
| **128 / 132** | u32 | **maskNewW / maskNewH**（2026-09-28 补传） |

**maskFlags 位定义**：
- bit0 = 总降级（`isDegraded`）
- bit1 = 掩码有效（有数据）
- bit2 = 车道线单独塌陷（`laneDegraded`）
- bit3 = 可行驶区单独塌陷（`drivableDegraded`）

**⚠️ 新增 bit 的安全方向**：旧发送方不发 bit2/bit3 → 恒为 0 → 两层都不会被压暗。
这是**安全的降级方向**（显示偏亮、能看见，而不是偏暗、看不见）。

### 7.2 各区域偏移

```swift
headerSize      = 4096
detOffset       = 4096       detCapacity = 256    detStride = 64
detEnd          = 20480
maskOffset      = 20480      maskGridMax = 160
maskBytes       = 3200       // 160×160 bit-packed = 20 bytes/row × 160
maskRegionBytes = 6400       // da + ll 两份
pixelsOffset    = 28672
maxWidth        = 4096       maxHeight = 2304
总大小           = 72 MB（含双像素页）
```

**检测记录布局**（`detStride = 64` 字节）：

| 偏移 | 类型 | 字段 |
|---|---|---|
| +0 | u32 | labelId（1=car 2=pedestrian 3=sign 4=obstacle） |
| +4 | f32 | confidence |
| +8 / +12 | f32 | x / y（归一化中心点） |
| +16 / +20 | f32 | width / height（归一化） |
| +24 | u8[16] | rawName（遇 0 截断） |

### 7.3 位压缩格式（对称实现，改一边必须改另一边）

```swift
// 写：先清零整区，再置位（LSB-first）
ptr[rowBase + x/8] |= UInt8(1 << (x % 8))

// 读：同样 LSB-first，位从 offset+0 开始（无 header）
```

**⚠️ 踩过的坑（坑 20）**：我自己写的测试脚本用了 MSB-first + 多算 8 字节 header +
忘了清零，报"5 项失败、逐格差异 6500"——**是测试错了，不是生产代码错**。
后来用 9/9 单格探针证明生产读写**逐位无损**。
**别被自己写的错测试带偏。**

### 7.4 版本守卫与物理边界校验

UI 侧读取点做了**双重防护**：

```swift
let maskRegionEnd = EngineFrameShm.maskOffset + EngineFrameShm.maskRegionBytes
let maskReadable = shmSize >= maskRegionEnd       // 物理边界校验
```

**为什么需要**：如果引擎还是旧版（v2，`pixelsOffset=20480`，总长更小），
按 v3 偏移去读掩码会读到 mmap 之外 → **SIGSEGV 直接崩掉 UI 进程**。

心跳里的 proto 版本守卫**存在但位置偏晚** —— 它在 `tickEngineMode` 里，
而掩码读取在 `poll()` 里，**先读后查，来不及拦**。

所以读取点做**物理边界校验**：映射长度不够就整个跳过。
**这比版本号可靠**（版本号是"约定"，长度是"事实"）。

**⚠️ 教训**：跨进程协议里，**不要用"约定"保护内存安全，要用"事实"**。

### 7.5 帧投递机制

- 像素页**双缓冲**（page A / page B），`activePage` 翻转即新帧就绪
- `frameSeq` 每次发布 +1，UI 侧 `guard seq != lastFrameSeq` 跳过重复帧
- **心跳 1Hz**（socket），UI 侧超过 **3.0s** 没收到 → 标记失联

```swift
if isConnected, Date().timeIntervalSince(lastHeartbeat) > 3.0 {
    isConnected = false
    engineClientLog("⚠️ 引擎心跳超时（失联）")
}
```

### 7.6 掩码的指纹短路（引擎侧优化）

YOLOPX 15Hz / tick 30Hz，连续两帧掩码通常一模一样。所以引擎侧做了指纹短路：

```swift
let fp = da.positiveCount &* 1000003 &+ ll.positiveCount &* 31
    &+ da.width &* 7 &+ ll.width
if fp != EngineGlobals.lastMaskFingerprint {
    EngineGlobals.lastMaskFingerprint = fp
    EngineGlobals.maskSeq &+= 1        // 只有变了才 ++
}
```

**指纹 = 前景格数 + 尺寸**。掩码是 0/1 网格，格数不变而形状变的概率极低，
即使漏一次也只影响一帧显示，下一帧必然补上。

**⚠️ 只在驾驶中发**：没开始驾驶时引擎本来就没掩码（模型未加载），
发空网格等于让 UI 侧白跑一遍解析。

**停车时清掩码**：
```swift
} else if EngineGlobals.maskSeq != 0 {
    EngineGlobals.maskSeq = 0
    EngineGlobals.lastMaskFingerprint = 0
    EngineGlobals.shm?.publishMasks(drivable: .empty, lane: .empty,
                                    metrics: .zero, isDegraded: true, ...)
}
```
防 UI 侧留着上一次驾驶的残影。

---

## 八、这个会话修了什么（2026-09-28）

### 8.1 ★ 卡到逆天 —— `.drawingGroup()` 是元凶

**用户报**："一开自动驾驶就卡得离谱，卡到逆天，基本不能动"

**证据**（`sample <pid> 3`，1ms 采样）：

```
1402 / 1402 个主线程样本全在：
  CA::Transaction::commit()
    → CA::Layer::display_if_needed
    → RBLayer displayWithBounds
    → RB::DisplayList::render
    → RenderState::RootTexture::make_texture()   ← 1110 个样本卡死在这
  并出现 FilterStyle<RB::Filter::GaussianBlur>::draw
```

**机理**：我上轮给光斑加了 `.drawingGroup()`，以为能栅格化缓存 blur 结果。
但外层有 `.offset` 动画**每帧移动位置** → 离屏纹理每帧失效重建（`make_texture`
= 重新分配 + 全量重绘）。于是从"一次高斯卷积"变成
"**离屏合成 + 卷积 + 再合成，且纹理每帧重建**"——比不加还慢。

**引擎侧雪崩数据**：
```
capWork:  11ms → 71ms → 301ms → 2081ms    （抓屏处理耗时，189 倍）
tickGap:  33ms → 741ms → 1198ms → 17044ms （17 秒一帧）
系统 load average: 171                      （8 核机器，正常 <8）
内核日志: 每秒唤醒 CPU 409 次
```

**修复**：移除 `.drawingGroup()`，回到 `.blur(radius: 60)` 直绘。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| UI 待机 CPU | 30.5% | **6.9%** |
| `RootTexture::make_texture` | 1110 样本 | **0** |
| `GaussianBlur FilterStyle` | 主因 | **0** |
| `CA::Transaction::commit` | 1402/1402 | 6 |

---

### 8.2 ★ 掩码一个格都不画 —— 守卫用了协议里不存在的字段

**用户报**："看不到可行驶区域和车道线，只能看到检测框"

**引擎侧其实完全正常**：`det=3 da=3353格 ll=900格 降级=false`，`maskSeq` 0→9→14 正常递增。

**根因（我的 bug）**——两处代码对撞：

```swift
// EngineClient.swift —— 我重建 metrics 时硬填 0
engineMaskMetrics = LetterboxMetrics(ratio: ratio, padX: padX, padY: padY,
                                     padBottom: 0, newW: 0, newH: 0,   // ← 硬填
                                     srcW: srcW, srcH: srcH)

// AuroraDriveApp.swift —— 绘制守卫
guard active, metrics.newW > 0, metrics.srcW > 0 else { return }        // ← 恒假
```

**协议头从来没传输 `newW`/`newH`**（引擎只写 ratio/padX/padY/srcW/srcH），
所以客户端只能填 0 → 守卫恒假 → **每帧直接 return**。

**为什么自检永远发现不了**：本地模式走 `yolopxEngine.metrics`，
那是模型真实产出的值（`newW = 640`）→ 守卫通过。
**这个 bug 只在引擎模式暴露**。46/46、7/7、15/15 全绿也没用。

**离线几何验证铁证**（复刻绘制数学，真实掩码规模）：

| 配置 | 可行驶区矩形 | 车道线矩形 | 守卫 |
|---|---|---|---|
| 本地模式 | 99 | 176 | ✓ |
| **引擎模式·修复前** | 99 | 176 | **✗ 失败** |
| 引擎模式·修复后 | 99 | 176 | ✓ |

几何**完全一致** → 证明 `newW` 对绘制数学**毫无作用**，纯粹是错判据。

**修复（两步都必要）**：
1. 把 `newW`/`newH` 真正写进协议（offset **128/132**，原本空闲区，
   `headerSize=4096` 仅用到 125 字节，**不移动任何既有字段 → 向后兼容**）
2. **同时**去掉守卫对 `newW` 的依赖，只留真正被用到的 `srcW > 0`

---

### 8.3 ★ 光流位置错误 —— "后台线程" ≠ "空闲线程"

我上轮把光流从主线程搬到 `captureEngine.onYoloFrame` 回调，理由是
"captureQueue 是后台线程，挪走能省主线程时间"。

**但那条队列不是普通后台队列**，它是 SCStream 的采样队列：

```swift
stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
config.queueDepth = 3
```

在采样队列上做同步计算 = 推迟帧消费 → 3 帧缓冲更快填满 → 系统施压。
日志里 `capGap` 与 `capWork` **同步**暴涨（301 → 2081ms）就是这个特征：
不是"处理慢"，而是"帧来得慢 + 处理路径被自己堵住"。

**已移回主线程**。而且我的"光流 1.7ms"是在**合成块状图**上测的；
真实游戏画面（纹理梯度 8.58 vs 合成 2.51）实测只要 **0.96ms** —— 纹理丰富时
DIS 收敛更快。**错误前提导致了一系列错误决策。**

---

### 8.4 「240ms 延迟」不是推理延迟

UI 上的 `e2eLatencyMs` 实际是：

```swift
var e2eLatencyMs: Double {
    let f = EngineClient.shared.engineFPS
    return f > 0 ? (1000.0 / f) : 0     // ← 1000 ÷ 帧率，是节拍周期
}
```

**实测 YOLOPX 真实推理**：

```
min=44.0  p50=46.5  p90=49.4  p95=50.0  max=52.7 ms   → 21.5 Hz
```

**240ms 的真实含义是"那一秒只跑了约 4 帧"**，是链路没跑满，**不是模型慢**。
两者差一个数量级。已把 UI 文案从「端到端延迟」改为「**链路节拍**」。

---

## 九、本会话保留的有效优化（未回退）

| 项 | 效果 | 验证方式 |
|---|---|---|
| `convertToGray` 消除逐像素除法 | 0.639ms → **0.040ms**（16×） | 数学等价 |
| 掩码行跨度合并 | 1.192ms → **0.375ms** | 7 种形态逐像素面积一致 |
| 分层塌陷解耦（da/ll 独立调暗） | 车道线塌陷不再连坐可行驶区 | 自检 + 协议 bit2/bit3 |
| 光流移到…（已回退） | — | 见 5.3 |

**主线程每帧成本**：3.831ms → **0.675ms（−82%）**，从 11.5% 降到 **2.0%** 预算占比。

**光斑 blur 首个实测**（`CIGaussianBlur` radius 60）：

| 尺寸 | p50 | p95 |
|---|---|---|
| 800×450 | 2.13ms | 143ms |
| 1200×675 | 2.93ms | 5.25ms |
| 1470×956 | 4.20ms | 6.90ms |

**这是预览框里单项最贵的绘制**（12.6% 预算）。但**注意**：
离线夹具测不出 SwiftUI 离屏合成语义 —— 5.1 的教训就是这么来的。

---

## 十、部署流程（必须严格照做）

**canonical 流程在 `run.sh:92-136`**：

```bash
BIN_SRC=".build/scratch/release/AuroraDrive"
BIN_DST="AuroraDriveUI"
BUNDLE_DIR="$PWD/AuroraDriveUI.app"

# 1. 签裸可执行
/usr/bin/codesign --force --deep --sign - "$BIN_SRC"

# 2. 原子替换裸可执行（cp + mv，不直接 cp 覆盖）
cp "$BIN_SRC" "$BIN_DST.tmp.$$" && mv -f "$BIN_DST.tmp.$$" "$BIN_DST"
/usr/bin/xattr -d com.apple.quarantine "$BIN_DST"

# 3. 同步进 bundle
cp "$BIN_SRC" "$BUNDLE_DIR/Contents/MacOS/AuroraDriveUI.tmp.$$" \
  && mv -f "$BUNDLE_DIR/Contents/MacOS/AuroraDriveUI.tmp.$$" \
           "$BUNDLE_DIR/Contents/MacOS/AuroraDriveUI"

# 4. 签 bundle（必须 --deep）
/usr/bin/codesign --force --deep --sign - "$BUNDLE_DIR"
/usr/bin/xattr -d com.apple.quarantine "$BUNDLE_DIR"

# 5. 验证
codesign --verify --deep "$BUNDLE_DIR"     # 必须 "valid on disk" + 满足 DR
```

**⚠️ 三个踩过的签名坑**：
1. **忘了** `--deep` → 标识符被打乱
2. **备份文件放进 bundle 内** → `invalid Info.plist ... In subcomponent`（备份放 `_bak_binaries/`）
3. 用错 `codesign` 参数顺序 → identifier 变了

**必要验证**：`spctl`/`codesign -dvvv` 应显示 identifier = **`com.aurora.driveui`**

---

## 十一、启动方式（TCC 权限是关键）

**⚠️ 必须启动裸可执行文件，不是 .app bundle**：

```bash
cd /Users/dupi/Desktop/自动驾驶系统
nohup ./AuroraDriveUI > /tmp/aurora_ui.log 2>&1 &
```

**为什么不能启动 .app**：TCC 权限（辅助功能 + 屏幕录制）挂在
`/Users/dupi/Desktop/自动驾驶系统/AuroraDriveUI` 这个**裸可执行路径**上。
启动 .app 会因路径不匹配而拿不到权限，卡在权限请求。

**TCC 权限是通过父进程链继承的**，且绑定到具体代码身份（CDHash/identifier）。

**已知现象**：从 AI 的 shell 里启动会失败，报：
```
[ENGINE] TCC 自检 ax=false screen=false
[ENGINE] TCC 权限不足，fail-fast 退出（权限须由父进程链继承）
```
**这不是代码 bug** —— AI 的进程链没有 TCC，必须**用户自己**在终端启动。

**正确的杀进程模式**：
```bash
pkill -f "AuroraDriveUI"        # ✓ 正确
pkill -f "AuroraDrive --engine" # ✗ 永不匹配（真名是 AuroraDriveUI）
```

**已犯的错**：用错模式 + `2>/dev/null` 吞报错 → 僵尸引擎跑了 **18 小时**，
持有 `engine.lock` 和 socket，用户的 UI 反复报"引擎心跳超时（失联）"。

**纪律**：杀进程前先 `pgrep -fl` 确认匹配到谁，**不要吞 pkill 的报错**。

---

## 十二、自检命令与诊断日志

### 12.1 三条自检

```bash
./AuroraDriveUI --yolopx-selftest      # 46/46  模型 + 掩码可见性
./AuroraDriveUI --opticalflow-selftest # 7/7    光流精度 + 耗时
./AuroraDriveUI --motion-selftest      # 15/15  α-β 滤波 + 预测
```

**YOLOPX 自检基准输出**（NTE 真实行车帧 `yt_vJ-SFOrqLWI_maxresdefault.jpg`）：
```
[warmup] yolopx3 预热完成: 83.2ms
✓ 推理产出结果 — 耗时 53.4 ms
检测框 9 个 / 可行驶占比 26.19% / 车道线占比 8.042%
da=3772 ll=1158   降级判定: 否
```

**⚠️⚠️ 自检全绿 ≠ 功能正常**（坑 24 的血泪教训）。
自检覆盖的是**模型层与算法层**；
**传输层 + 显示层的复合 bug 它测不出来** —— 46/46 全绿时用户还什么都看不到。

### 12.2 日志文件位置

| 文件 | 内容 | 查看方式 |
|---|---|---|
| `~/Library/Logs/AuroraEngine.log` | 引擎进程全部日志（含 tick） | `tail -f` |
| `~/Library/Logs/AuroraEngineClient.log` | UI 侧客户端日志（含"✅ 引擎模式已激活"） | `tail -f` |
| `/tmp/aurora_debug.log` | tick 摘要（1Hz） | `grep 'tick:'` |
| `/tmp/aurora_pcap.log` | pcap 相关 | |
| `/tmp/aurora_ui_stdout.log` | UI stdout（推荐重定向到别处） | |

### 12.3 tick 日志字段全解（`/tmp/aurora_debug.log`）

这是排查问题**最重要的一行**。每个字段的含义：

```
tick: mode=端到端主驾 m9Live=true assistLive=true conf=1.00 img=true
      cmd=(s=-0.02 t=0.94 b=0.06) held=1 ev=3593 perm=true
      front=AuroraDriveUI native=235x96 ocr[PP-OCRv6]=-1.0/0.00[CTC 解码为空]
      eff=0.0/vld=false lag=8ms mem=229MB
      capGap=67ms capWork=66ms tickGap=34ms
```

| 字段 | 含义 | 异常时怎么读 |
|---|---|---|
| `mode` | 当前驾驶档位 | 掉到 `纯规则兜底` = 模型链路挂了 |
| `m9Live` | M9 端到端模型是否在出结果 | false = M9 没跑或没加载 |
| `assistLive` | 第二司机（辅助）是否活跃 | |
| `conf` | 决策置信度 | 0.00 持续 = 没拿到有效输入 |
| `img` | 当前帧是否存在 | false = 截屏没进来 |
| `cmd=(s,t,b)` | 转向/油门/刹车（-1~1） | 全 0 持续 = 没出决策 |
| `held` | 当前按住的键数 | |
| `ev` | 累计注入事件数 | 不涨 = 注入被拦 |
| `perm` | 辅助功能权限 | **false = 按不了键** |
| `front` | **注入时的前台应用** | **不含游戏 = 游戏没在前台，收不到键** |
| `native` | 原生帧尺寸 | |
| `ocr[引擎]` | 车速读数/置信度 | `-1.0` = 没读到 |
| `eff/vld` | 有效车速/是否新鲜 | |
| `lag` | **帧投递延迟**（帧到达→消费） | p50 17ms 正常，>200ms 异常 |
| `mem` | 进程内存 | 持续涨 = 泄漏 |
| `capGap` | **帧到达间隔** | p50 34ms（29.4fps）正常 |
| `capWork` | **抓屏回调处理耗时**（含 onYoloFrame） | p50 15ms 正常 |
| `tickGap` | **引擎 tick 间隔** | 33ms 正常（30Hz 预算 33.33ms） |

**⚠️ 关键鉴别技巧**：
- `capGap == capWork`（完全相等）→ **不是"处理慢"，是"帧来得慢"**
  或处理路径被自己堵住（坑 22 就是这个特征）
- `capGap` 与 `capWork` **同步暴涨** → 采样队列被阻塞
- `tickGap` 远大于 33ms → 主线程/tick 被拖慢

### 12.4 常用诊断命令

```bash
# 引擎实时状态（掩码是否正常）
grep -E "统计:" ~/Library/Logs/AuroraEngine.log | tail -5

# 驾驶档位变化
grep -E "tick: mode=" ~/Library/Logs/AuroraEngine.log | tail -20

# 命令历史（start/stop）
grep -E "收到命令|startDriving|stopDriving" ~/Library/Logs/AuroraEngine.log | tail -10

# 延迟分布统计
grep -oE "lag=[0-9]+ms" ~/Library/Logs/AuroraEngine.log | sed 's/lag=//;s/ms//' | \
  sort -n | awk '{a[NR]=$1} END {print "p50="a[int(NR/2)]" p95="a[int(NR*0.95)]" max="a[NR]}'

# 抓真实堆栈（改 UI 后必做）
PID=$(pgrep -f AuroraDriveUI | head -1)
sample $PID 3 -file /tmp/stack.txt
grep -c "CA::Transaction::commit" /tmp/stack.txt   # 渲染热点
grep -c "RootTexture::make_texture" /tmp/stack.txt # 离屏纹理重建（坑 21 的标志）
```

### 12.5 「统计:」行的读法

```
[22:04:15] [ENGINE] 统计: seq=19730 有帧=true det=3 driving=false
           yolopx:加载=true 帧数=821 da=3353格 ll=900格 降级=false maskSeq=0
```

| 字段 | 含义 | 正常值 |
|---|---|---|
| `seq` | 帧序号（30Hz 增长） | 每 5 秒涨约 150 |
| `有帧` | 是否有画面 | true |
| `det` | 检测框数 | 0~10 |
| `driving` | **是否在驾驶中** | 只有 true 时才发掩码 |
| `yolopx:加载` | 模型是否加载 | true |
| `帧数` | **YOLOPX 累计推理帧数** | 驾驶时持续涨；停住 = 推理停了 |
| `da=X格` | 可行驶区前景格数 | 正常 3000+；0 = 有问题 |
| `ll=X格` | 车道线前景格数 | 正常 900±；个位数 = 有问题 |
| `降级` | 是否降级 | false |
| `maskSeq` | **掩码世代号** | driving=true 时递增；0 = 没发 |

**⚠️ 重要**：`driving=false` 时 `maskSeq=0` 是**设计行为**（停车清掩码防残影）。
所以"看不到掩码"要先确认 `driving=true`。

---

## 十三、⚠️ 未完成事项 / 已知问题

> 📌 **编号订正（2026-09-29）**：本节子节原误标为 `14.x`（与第十四章重号，且导致第十八章引用的「10.1-10.5」全部失效）。下方已改为 `13.x`，**内容一字未改**。

### 13.1 端到端掩码可见性验证（**最该补的一条**）

8.2 的 bug 说明：模型层正常 + 引擎层正常，但用户什么也看不到。
**缺一条"引擎→共享内存→UI 绘制"的端到端验证**。
建议：用真实掩码数据跑一遍共享内存往返 + 渲染几何，
断言"必然产出 >0 个矩形且 bbox 落在视口内"。

### 13.2 真实硬件驾驶验证

协议 v3 的掩码传输**尚未在真实硬件上验证过**。
需要在用户自己启动、真机驾驶的情况下确认掩码可见。

### 13.3 `ll` 占比注释与实测不符

实测 `ll` = 8.042%，代码注释标定 1.3~2.6%。
`ceil=0.25` 远高于 8%，**判定不受影响**，但注释该对齐。

### 13.4 预测目标未降权

`isPredicted == true` 的目标在 `effectiveDetections` 里**仍未被降权**。
预测框可信度低于真值框，决策层应当区分。

### 13.5 光流无兜底路径

光流只在 YOLO 快路径活跃时运行；**没有从 `currentFrameCG` 的兜底**。
YOLO 路径停掉时，运动预测会失去输入。

### 13.6 `drawingGroup()` 收益未复测

已确认它是负优化并移除。但如果将来要做类似缓存优化，
**必须**用 `sample <pid> 3` 抓真实堆栈验证，**不能只靠离线夹具**。

---

## 十四、兜底机制详解（两个 Fallback 的设计哲学）

项目里有**两个独立的几何兜底**，风格一致。理解它们的纪律，
就能理解整个项目的容错思路。

### 14.1 `FallbackGuard` —— 双结构几何兜底

**用户亲自提的两个判据**（文件头原文摘录）：

> **结构 A —— 自车位置判定：**
> 「把画面中心点最大的那个检测框，就认为是自己自车的位置」
> 用途：即使感知模型链断了，也能回答"我前方正中央有没有东西"。
>
> **结构 B —— 框叠加碰撞判定：**
> 「中间点那个检测框如果和别的车检测框叠加在一起了，
> 那么肯定就是需要避让或者撞车，所以距离检测框叠加
> 就可以进行紧急避让那种，就可以作为兜底」
> 用途：纯几何的碰撞判据，不依赖任何模型置信度。

**参数表**：

| 参数 | 值 | 含义 |
|---|---|---|
| `egoCenterHalfWidth` | 0.25 | 自车中心带的半宽（归一化） |
| `egoMinCenterY` | 0.40 | 自车框的最低中心 y（在下半屏） |
| `egoMinArea` | 0.008 | 自车候选框的最小面积 |
| `overlapIoU` | **0.15** | 判定"叠加"的 IoU 阈值 |
| `overlapCenterDistance` | 0.06 | 判定"叠加"的中心距阈值（辅助） |
| `confirmFrames` | **3** | 连续确认帧数 |
| `maxSteer` | 0.25 | 转向硬限幅 |

**定位**：这是**兜底，不是主驾**。

### 14.2 `LaneFallback` —— 车道线几何兜底

| 参数 | 值 | 含义 |
|---|---|---|
| `maxSteer` | 0.25 | 转向硬限幅 |
| `drivableFloor` | 0.05 | 可行驶区占比告警线 |
| `drivableCritical` | 0.02 | 危急线 |
| `steerDeadband` | 0.06 | 转向死区（小偏差不动） |
| `steerGain` | 3.0 | 偏差→转向增益 |
| `maxDeviationJump` | 0.15 | 单帧偏差突变上限 |
| `interveningThrottleCap` | **0.3** | 介入时油门上限 |
| `stabilityFrames` | 6 | 稳定性所需帧数 |
| `stabilityWindowSeconds` | 0.2 | 稳定性时间窗 |
| `sampleBandTopFrac` | 0.25 | 采样带上界（画面高度比例） |
| `sampleBandBottomFrac` | 0.90 | 采样带下界 |

### 14.3 ⭐ 四条设计纪律（两个兜底共用）

这是整个项目**最值得学习的设计**：

> **① fail-open**
> 输入不可信（框太少 / 尺寸异常）→ 返回 `nil`，**调用方维持原决策**。
> 宁可不管，也不要基于垃圾输入乱管。

> **② 有界输出**
> 转向/刹车都有**硬限幅**，绝不输出满油门。
> 兜底的作用是"别撞"，不是"开得好"。

> **③ 连续帧确认**
> 同一判定需**连续 N 帧稳定**才采纳（`confirmFrames=3` / `stabilityFrames=6`）。
> 单帧噪声不足以触发介入。

> **④ 突变丢弃**
> 单帧异常**不改变结论**（`maxDeviationJump=0.15`）。
> 防止一帧误检导致方向猛打。

**实现风格**：纯函数式（与 `RuleController` 同风格），**无外部副作用**。
唯一的内部状态是稳定性计数器，由调用方每帧按序喂入。

### 14.4 降级状态机 4 档

```
档1  端到端主驾 (e2e)      M9 端到端模型直接开车        ← 最好
档2  YOLO接管   (yolo)     第二套神经网接管（YOLO 画框）
档3  脱困中     (recover)  卡死脱困（自动倒车/转向）     ← 警告色
档4  纯规则兜底 (rule)     YOLO 检测 + 手写规则          ← 最后防线
```

**UI 展现为 2 档**（`DriveModeGroup`）：
- 「端到端主驾」= e2e + yolo
- 「规则」= recover + rule

**内部逻辑完整保留 4 档**，降级/回升都按 4 档走。

本会话观察到的真实降级链（2026-09-28 卡顿时）：
```
端到端主驾 → YOLO接管 → 纯规则兜底
```

---

## 十五、性能数字速查

| 项 | 数值 | 备注 |
|---|---|---|
| YOLOPX 推理 | **46.5ms** p50 / 50.0ms p95 | 640×640，实测 30 次 |
| YOLOPX 物理极限 | 16.0ms | 148.11 GFLOPs ÷ 9.26 TFLOPS |
| YOLOPX 参数量 | 33.03M params / 148.11 GFLOPs | |
| yolo26s 推理 | **4.46ms** min / 4.64 med / 4.76 p95 | 预测用 |
| 光流 DIS | **0.96ms** p50 / 1.25ms p95 | 真实画面，640×640 |
| 灰度转换 | 0.040ms | same-size 快路径 |
| 主线程每帧 | **0.675ms** | 占预算 2.0% |
| 引擎 tick | 30Hz | 预算 33.33ms |
| 光斑 blur | 4.20ms p50 | 1470×956，预览框最贵单项 |

**硬件**：Apple M3 / Mac15,12 / macOS 26.6.2 / 8 核（4P+4E）

---

## 十六、工作纪律（血泪总结）

### 16.1 不许说"我觉得没问题"

必须实测。用户明令："不许你觉得没问题"。

### 16.2 离线微基准不能替代真实 UI 堆栈采样

`CIGaussianBlur` 夹具里**没有 SwiftUI 的离屏合成语义**，
所以完全测不出 `.drawingGroup()` 的代价，还给了我"有据可依"的错觉。

**改 UI 渲染路径后，必须 `sample <pid> 3` 抓真实堆栈验证。**

### 16.3 `drawingGroup()` 只适合内容与位置都稳定的子树

有动画/位移时，它每帧重建离屏纹理，**比不加还慢**。

### 16.4 "后台线程" ≠ "空闲线程"

挪计算前必须确认那条队列**承载什么**。
屏幕采集/音频采集/网络收包的采样队列上，只应做最少的工作。

### 16.5 性能数据必须在真实输入分布上取

我的"光流 1.7ms"是在合成块状图上测的；真实画面只要 0.96ms。
**错误前提导致一系列错误决策。**

### 16.6 守卫条件必须用"真正参与计算的量"

`newW` 在整个绘制数学里**只出现在守卫那一行**。拿一个不参与计算的量
当"能不能画"的判据，一旦对不上就是全盲。

### 16.7 跨进程协议必须逐字段对照发送/接收两侧

我在协议里发 5 个几何字段，收端却按 7 个去用。

### 16.8 杀进程前先确认匹配

`pgrep -fl` 确认 → 再 kill。不要吞 pkill 报错。

### 16.9 用户偏好速记

- **严禁删除/覆盖任何文件**（损失过三万多）
- **界面要求极高**："非常高级"，要反复抠细节、往死里抠
- **视觉语言**：空间感光斑 + 高对比度 + 纯深色 + 极淡网格的玻璃拟态；
  **拒绝低对比度发灰的毛玻璃**
- **要求完整分析**：只看局部或片面不可接受
- **验证模型加载时**：存在性 ≠ 可加载性，必须确认真正加载成功
- 反感自动启动应用

---

## 十七、可用资源

### 17.1 真实行车测试素材

```
data/nte_test_frames/
  yt_vJ-SFOrqLWI_maxresdefault.jpg   # 1280×720 白天三车（最常用）
  yt_FOV9UhGrT1c_maxresdefault.jpg   # 1280×720
  yt_5km-TC0gw9Y_maxresdefault.jpg
  nte_slide1..6.jpg                  # ⚠️ 非行车，是宣传图
```

桌面 `开车照片/` 里有 5 张带时间戳的真实开车画面（本会话生成）。

### 17.2 关键文档

| 文档 | 内容 |
|---|---|
| `docs/文档库/自动驾驶与功能/pitfalls.md` | **24 条坑**（本会话加了 21~24） |
| `docs/优化改动清单与后果.md` | §13 是本次回退记录 |
| `docs/文档库/自动驾驶与功能/代码-31-构建部署与runsh全解.md` | 部署与 TCC 权限说明 |
| `docs/文档库/探索文档/光流-运动预测-兜底-交付说明.md` | 光流/预测/兜底交付（含附录 C） |
| `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` | 开发者总入口 |
| `docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md` | 架构总览 |

### 17.3 备份二进制

```
_bak_binaries/
  AuroraDriveUI.bak_20260927_125623      # 5.6MB（09-26）
  AuroraDriveUI.bak_v3_20260927_235219   # 9.1MB（09-27 14:07，无 drawingGroup）
```

桌面上还有 3 个旧备份（`AuroraDriveUI.bak*`），**不要动它们**。

### 17.4 环境

| 项 | 值 |
|---|---|
| Python | `.venv-yolo26/bin/python3`（装了 PIL 12.2.0） |
| `MPLCONFIGDIR` | `/tmp/mplcache` |
| **`timeout` 命令** | **不可用**（用后台 PID + `kill -0` 循环替代） |
| `docker` | 不可用 |
| 硬件 | Apple M3 / Mac15,12 / 8 核（4P+4E） |
| 系统 | macOS 26.6.2 (25G83) |

### 17.5 编译命令

```bash
swift build -c release --disable-sandbox --scratch-path .build/scratch
# 产物: .build/scratch/release/AuroraDrive
# 增量约 40s，全量约 60~90s
```

**注意**：`--disable-sandbox` 是必需的（宏插件要写临时缓存）。

---

## 十八、下一步建议（按优先级）

> 📌 **引用订正（2026-09-29）**：本节下面的 `10.1`~`10.5` 原指向「未完成事项」章，
> 但那一章的子节编号历经 `10.x` → `14.x` → **`13.x`** 三次变动，导致这些引用长期失效。
> **现已改为 `13.1`~`13.5`**（对应本文第十三章「⚠️ 未完成事项 / 已知问题」）。

1. **用户重启应用，确认掩码可见**（可行驶区淡绿 + 车道线青色）
   —— 这是 8.2 修复的直接验证
2. **补端到端掩码可见性自检**（13.1）—— 防止同类 bug 再发生
3. 真机驾驶验证协议 v3 掩码传输（13.2）
4. 对齐 `ll` 占比注释（13.3）
5. 预测目标降权（13.4）
6. 光流兜底路径（13.5）
7. **【2026-09-29 新增】修 `LaneFallback.swift:170` 的 `newW` 守卫依赖**（见 `pitfalls.md` §25）
   —— 与 8.2 同形的第二处落点，当前暂不复发但属静默失效隐患

---

## 十九、本会话事故完整复盘（三个 bug 的因果链）

这一节记录**同一个会话里连续犯的三个错**，以及它们如何串成一条链。
新接手的人读这一节，能避免重蹈覆辙。

### 19.1 时间线

| 时刻 | 事件 |
|---|---|
| 09-27 23:52 | 部署 v3（无 `.drawingGroup()`），备份为 `bak_v3` |
| 09-28 白天 | 我用 `CIGaussianBlur` 离线测出 blur 是预览框最贵绘制（p50 2.13~4.20ms） |
| 09-28 | **错误决策 ①**：加 `.drawingGroup()` 想栅格化缓存 |
| 09-28 | **错误决策 ②**：把光流从主线程移到 `captureQueue`（"那边是后台线程"） |
| 09-28 21:02 | 部署含上述两处改动的版本 |
| 09-28 21:23 | **用户点开始驾驶 → 卡到逆天** |
| 09-28 21:25 | 内核日志：`每秒唤醒 CPU 409 次`，load 飙到 **171** |
| 09-28 21:37 | 我 `sample` 抓堆栈 → **1402/1402 主线程样本全在渲染** |
| 09-28 21:40 | 移除 `.drawingGroup()`，CPU 30.5% → **6.9%** |
| 09-28 22:19 | 把光流移回主线程 |
| 09-28 22:2x | 用户报"看不到可行驶区和车道线" |
| 09-28 22:3x | 发现 **错误决策 ③**（`newW` 守卫），修复 + 补进协议 |

### 19.2 错误决策 ① 的完整因果

```
我观察到：blur 是单项最贵的绘制（离线实测 2.13~4.20ms）
   ↓
我推断：栅格化缓存起来就不用每帧重算了
   ↓
我实施：加 .drawingGroup()
   ↓
实际发生：.drawingGroup() 要求渲染进【离屏纹理】
          而外层 .offset 动画【每帧移动位置】
          → 纹理每帧失效并重建（make_texture = 重新分配 + 全量重绘）
   ↓
结果：从"一次高斯卷积"变成"离屏合成 + 卷积 + 再合成，且纹理每帧重建"
   ↓
净效果：比不加还慢好几倍
```

**我漏掉的关键事实**：`.drawingGroup()` 的缓存**只在子树内容与位置都稳定时有效**。
外层有 `.offset` 动画 = 位置每帧变 = 缓存必然失效。

**为什么离线夹具没发现**：`CIGaussianBlur` 夹具里**没有 SwiftUI 的离屏合成语义**。
它只测"一次高斯卷积多久"，完全测不出"纹理重建"这一层。

**⚠️ 这条教训最贵**：离线微基准给了我"有据可依"的错觉，
让我以为自己在做数据驱动的决策，实际上是在**用错误的工具测错误的东西**。

### 19.3 错误决策 ② 的完整因果

```
我观察到：光流要 1~2ms（在【合成块状图】上测的）
   ↓
我推断：主线程 33.33ms 预算紧张，挪到后台线程
   ↓
我看到：captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)
        → "是后台队列，还是 userInteractive，很合适"
   ↓
我实施：把 runOpticalFlow 放进 captureEngine.onYoloFrame 回调
   ↓
实际发生：captureQueue 是 SCStream 的 sampleHandlerQueue
          config.queueDepth = 3（只有 3 帧缓冲！）
          在采样队列上做同步计算 → 推迟帧消费 → 缓冲填满 → 系统施压
   ↓
结果：capGap 与 capWork 【同步】暴涨（301ms → 2081ms）
```

**我漏掉的关键事实**：`captureQueue` 的名字叫 "aurora.capture"，
它的 qos 是 `.userInteractive` —— 这两个线索都在暗示它是**关键路径**，
但我只看到"后台线程"就下了结论。

**另一个错误**：我的"1.7ms"是在**合成块状图**（纹理梯度 2.51）上测的。
真实游戏画面（梯度 8.58）实测只要 **0.96ms** —— **纹理丰富时 DIS 收敛更快**。
我的成本估计本身就偏高，导致"必须挪走"的前提不成立。

**`capGap == capWork` 这个信号我一开始没读懂**：
两个值完全相等意味着"回调本身占满了整个间隔"，
即**不是处理慢，而是帧来得慢**（或处理路径被自己堵住）。

### 19.4 错误决策 ③ 的完整因果

```
我观察到：（用户报）看不到可行驶区和车道线
   ↓
我查引擎日志：det=3 da=3353格 ll=900格 降级=false maskSeq 递增
   ↓
我推断：引擎侧一切都好 → 问题在 UI 侧
   ↓
我查 UI 守卫：guard active, metrics.newW > 0, metrics.srcW > 0
   ↓
我发现：EngineClient 重建 metrics 时硬填 newW: 0
   ↓
根因：协议头从来没传输 newW/newH
```

**这个 bug 是"我的两处代码对撞"**：
- 我写 `EngineClient` 时只按协议有的字段重建 metrics（填 0 占位）
- 我写/改 `MaskOverlay` 守卫时用了 `newW > 0`
- **两边单独看都没问题，合起来就是全盲**

**为什么自检永远测不出**：本地模式走真实 `newW`（640），守卫通过。
**这个 bug 只在引擎模式暴露** —— 46/46 全绿也没用。

**修复时我做了个正确的判断**：不是简单删掉守卫就完事，
而是**同时**补进协议（offset 128/132）+ 去掉守卫依赖。
因为只做前者，旧引擎客户端仍会被卡住。

### 19.5 三个错误的共同模式

| | 错误 ① | 错误 ② | 错误 ③ |
|---|---|---|---|
| 我有理论依据吗 | 有（离线实测） | 有（成本估算） | 有（守卫更严格更安全） |
| 我在真实场景验证了吗 | **没有** | **没有** | **没有** |
| 测出来了吗 | 离线夹具测不出 | 离线数字本身是错的 | 自检覆盖不到 |
| 谁发现的 | 用户报卡顿 | 日志雪崩 | 用户报看不见 |

**共同模式**：

> **① 我都有"数据/理论"支撑，但没有在真实场景端到端验证。**
>
> **② 三种"验证盲区"各不同**：
> - 错误 ①：验证工具测错了东西（离线夹具 vs 真实 UI 合成）
> - 错误 ②：验证数据取自错误分布（合成图 vs 真实画面）
> - 错误 ③：验证覆盖不到目标场景（本地模式 vs 引擎模式）
>
> **③ 都是用户先发现的。** 说明我的验证流程有系统性缺口。

### 19.6 应该怎么做（流程改进）

**改任何性能相关代码后，必做三件事**：

1. **真实负载下测**，不用合成数据
   ```bash
   # 好的测法
   swiftc -O bench.swift && ./bench   # 用真实游戏帧
   ```

2. **改 UI/渲染后抓真实堆栈**
   ```bash
   PID=$(pgrep -f AuroraDriveUI | head -1)
   sample $PID 3 -file /tmp/stack.txt
   grep -c "CA::Transaction::commit" /tmp/stack.txt
   ```

3. **问自己"这个改动在哪个模式下生效"**
   - 本地模式？引擎模式？两者？
   - 如果只在一个模式下生效，**自检（通常跑本地模式）就是盲区**

**⚠️ 最重要的一条**：**当用户报"卡"或"看不见"时，
先抓真实堆栈 / 真实数据，再形成假设。**
本次三个 bug 里，凡是"先抓证据再下结论"的（21:37 抓堆栈、22:3x 读引擎日志）
都很快定位；凡是"先推理再实施"的都翻车了。

---

## 二十、给下一个接手者的操作手册

### 20.1 第一次上手

```bash
# 1. 确认项目状态
cd /Users/dupi/Desktop/自动驾驶系统
git status --porcelain | grep -c '^ D'      # 必须是 0
md5 -q AuroraDriveUI                         # 应匹配交接时的值

# 2. 编译
swift build -c release --disable-sandbox --scratch-path .build/scratch

# 3. 自检（必须全绿）
./AuroraDriveUI --yolopx-selftest       # 46/46
./AuroraDriveUI --opticalflow-selftest  # 7/7
./AuroraDriveUI --motion-selftest       # 15/15

# 4. 读文档（按顺序）
#    docs/文档库/自动驾驶与功能/pitfalls.md          ← 先读这个
#    docs/文档库/自动驾驶与功能/代码-00-源码树与架构总览.md
#    docs/优化改动清单与后果.md
```

### 20.2 改代码的标准流程

```
1. 找改动点的所有调用方
   grep -rn "函数名" Sources/

2. 判断影响模式
   - 本地模式（UI 自己跑推理）
   - 引擎模式（走共享内存）
   - ⚠️ 如果两者行为不同，改动必须两边都验证

3. 改代码（写清"为什么"，不只写"做了什么"）

4. 编译 + 自检

5. 如果是性能/UI 改动 → 抓真实堆栈/真实负载验证

6. 部署（严格按 run.sh 流程）

7. 自证没删文件
   git status --porcelain | grep -c '^ D'   # 必须 0

8. 记录到 pitfalls.md / 优化改动清单
```

### 20.3 排查问题的标准流程

```
用户报问题
   ↓
① 先确认"引擎侧数据对不对"
   grep -E "统计:" ~/Library/Logs/AuroraEngine.log | tail -5
   → 看 driving / det / da格 / ll格 / 降级 / maskSeq
   ↓
② 引擎侧正常 → 问题在传输层或 UI 侧
   引擎侧异常 → 问题在推理层
   ↓
③ 读共享内存原始值（最直接）
   → 见 §12.4 的诊断命令
   ↓
④ 看 UI 侧守卫/门控条件
   grep -n "guard.*active" Sources/AuroraDrive/App/AuroraDriveApp.swift
   ↓
⑤ ⚠️ 最后才形成假设，且假设要能被数据证伪
```

### 20.4 性能问题的标准流程

```
① 先量，不要猜
   → 抓堆栈（CPU 类）/ 读指标（延迟类）
   ↓
② 确认"贵"在哪一层
   - 主线程渲染？（sample 看 CA::Transaction::commit）
   - 推理？（量模型推理耗时）
   - 传输？（看 shm 读写）
   ↓
③ 确认数据分布是对的
   - 用的是真实游戏帧还是合成图？
   - 空载还是带了生产负载？
   ↓
④ 改完必须复测同一口径（否则数字没有可比性）
```

### 20.5 与用户沟通的注意

- **用户会自己启动应用测试**（TCC 权限要求），不要试图替他启动
- **用户重视证据**：说"我认为"会被要求拿出数据
- **用户会亲自看画面**：UI 现象要问他，不要只凭代码推断
- **不要自动启动应用**（用户明确反感）
- **桌面文件不要动**（`开车照片/`、`异环/`、各种 `.app` 替身）

### 20.6 关键命令速查

```bash
# 启动（用户自己执行）
cd /Users/dupi/Desktop/自动驾驶系统
nohup ./AuroraDriveUI > /tmp/aurora_ui.log 2>&1 &

# 杀进程（先确认再杀）
pgrep -fl AuroraDriveUI          # 先看匹配到谁
pkill -f "AuroraDriveUI"         # 再杀（不要 -f "AuroraDrive --engine"）

# 看引擎状态
grep -E "统计:" ~/Library/Logs/AuroraEngine.log | tail -5

# 看驾驶档位
grep -E "tick: mode=" ~/Library/Logs/AuroraEngine.log | tail -10

# 抓堆栈（UI 性能问题）
PID=$(pgrep -f AuroraDriveUI | head -1); sample $PID 3 -file /tmp/stack.txt

# 读共享内存（Python）
#   见 §12.4，已写好脚本模板
```

---

## 二十一、一句话总结（给接手者）

> **这是个双进程 macOS 原生自动驾驶辅助系统，让 AI 自动玩《异环》。**
>
> **三条不能碰的红线**：
> 1. **YOLOPX 模型是甲方核心资产** —— 换模型 = 项目解散
> 2. **光流必须 ≤5ms @ 640×640，必须用 OpenCV**
> 3. **严禁删除任何既有文件**（用户损失过三万多）
>
> **三条工作纪律**：
> 1. **不许说"我觉得没问题"** —— 必须实测
> 2. **离线微基准不能替代真实场景验证** —— 本会话最大教训
> 3. **自检全绿 ≠ 功能正常** —— 传输层+显示层的 bug 测不出来
>
> **本会话修了三个 bug，全都是我自己造成的**：
> - `.drawingGroup()` 用在会动的子树上 → 卡到不能动
> - 光流放进 SCStream 采样队列 → 帧率雪崩
> - 守卫用了协议里不存在的字段 → 掩码全不画
>
> **三个的共同点：我都有"理论依据"，但都没在真实场景验证。**
>
> **下一步最该做的**：用户重启确认掩码可见 + 补端到端掩码可见性自检。

---

*本交接文案基于真实代码、真实日志与实测数据生成，非回忆。*
*所有数字均可在项目内溯源（文件路径 + 行号或日志命令已给出）。*
*生成于 2026-09-29。*

---

## 附录 A：本章会话涉及的完整文件改动清单

| 文件 | 改动 | 原因 |
|---|---|---|
| `App/AuroraTheme.swift` | 移除 `.drawingGroup()` | 修卡顿（§8.1） |
| `App/AuroraDriveApp.swift` | 光流调用移回主线程 tick | 修帧率雪崩（§8.3） |
| `App/AuroraDriveApp.swift` | `MaskOverlay` 守卫去掉 `newW > 0` | 修掩码不可见（§8.2） |
| `App/AuroraDriveApp.swift` | 恢复 `opticalFlowGrayBuffer` 的 MainActor 隔离 | 回退期清理 |
| `App/AuroraDriveApp.swift` | `e2eLatencyMs` 加详细注释 | 澄清语义（§8.4） |
| `App/MissionConsole.swift` | 「端到端延迟」→「链路节拍」 | 澄清语义（§8.4） |
| `Core/EngineMain.swift` | 协议头补 `newW`/`newH`（128/132） | 修掩码不可见（§8.2） |
| `Core/EngineClient.swift` | 读 `newW`/`newH`，不再硬填 0 | 修掩码不可见（§8.2） |
| `docs/文档库/自动驾驶与功能/pitfalls.md` | 新增 21~24 条 | 记录 |
| `docs/优化改动清单与后果.md` | 新增 §13 | 记录回退 |

**保持不变的（未回退的有效优化）**：
- `Inference/OpticalFlowBridge.swift` 的 `convertToGray` sameSize 快路径
- `App/AuroraDriveApp.swift` 的 `spanMergedPath` 行跨度合并
- 分层塌陷解耦（`laneDegraded` / `drivableDegraded`）
- `App/AuroraTheme.swift` 的 `blur(radius: 60)`

## 附录 B：常见误判速查

| 你看到的 | 可能的真实含义 | 怎么确认 |
|---|---|---|
| 「延迟 240ms」 | 节拍周期 = 1000/帧率，**不是推理耗时** | 实测推理只有 46.5ms |
| 「掩码看不到」 | 先看 `driving` 是否为 true | `grep 统计:` |
| 「卡」 | 可能是渲染，也可能是采集，也可能是内存 | `sample` 抓堆栈 |
| `capGap == capWork` | 帧来得慢 / 处理路径被堵，不是处理慢 | 看两者是否同步涨 |
| 自检全绿但功能异常 | 自检覆盖不到该模式 | 问"这改动在哪个模式生效" |
| `frames` 不涨 | 推理停了，或没在驾驶 | 看 `driving` |
| `da=0格` | 掩码真空，或没在驾驶 | 看 `driving` + `降级` |
| 「引擎失联」 | 可能有僵尸引擎占着锁 | `pgrep -fl AuroraDriveUI` |
| `newW` 之类的守卫失败 | 可能是协议没传该字段 | 对照发送/接收字段集 |
| 「光流慢」 | 可能是测量条件不对（QoS/负载） | 对齐生产调度条件重测 |

---

*（交接文案完）*

---

## 附录 C：24 条坑的完整正文（从 pitfalls.md 摘录）

便于离线交接时不必翻文档。格式：**现象 → 根因 → 修复 → 教训**。

### C.1 崩溃类

**坑 1 · pcap_loop 回调在 Apple Silicon 上 SIGBUS（PAC 崩溃）**
- **现象**：App 启动即 SIGBUS，崩溃栈指向 libpcap 内部，随机性出现
- **根因**：`pcap_loop` 的 C 函数指针回调跨调用栈被 libpcap 间接调用。
  Apple Silicon 的 PAC（Pointer Authentication Codes）对函数指针签名验证，
  Swift 闭包经 `@convention(c)` 转换的指针跨 PAC 边界时签名失效 → SIGBUS
- **修复**：弃用 `pcap_loop` 回调，改 `pcap_next_ex` 阻塞循环（`captureLoop`）
- **教训**：Apple Silicon 上向 C 库传函数指针回调要三思；轮询式 API 通常更稳

**坑 2 · 无符号下溢 SIGTRAP**
- **现象**：pcap 正常运行后随机 SIGTRAP 闪退
- **根因**：UE5 有符号向量解码里 `v -= modulus`，扫描垃圾位解出
  `v < modulus` 时 UInt64 下溢——Swift 对无符号下溢默认触发运行时陷阱
- **修复**：`v = v &- modulus`（回绕减法，语义等价补码减法）
- **教训**：位流扫描器在垃圾数据上运行，所有算术都要按
  「输入可能是任意位模式」防御

**坑 3 · findCandidates Range 溢出 SIGTRAP**
- **现象**：接入真实游戏流量后闪退（模拟流量不崩）
- **根因**：扫描窗 `for offset in 190..<searchEnd`，短包时
  `payload.count*8-60 < 190`，Swift Range 要求 lowerBound ≤ upperBound
  → 运行时陷阱
- **修复**：`guard searchEnd > 190` + `bits()` 全套防护
  （count>63、数组越界、data.count>14 前置检查）
- **教训**：真实流量包长分布与想象不同；Range 字面量是 Swift 最常见隐藏陷阱

**坑 4 · pcap_lookupdev 抓错网卡**
- **现象**：pcap 启动成功、循环正常，但永远 0 包
- **根因**：`pcap_lookupdev` 在 macOS 只返回默认路由网卡（en0/WiFi），
  游戏流量可能走 en8（有线/USB）
- **修复**：改用 `pcap_findalldevs` 枚举全部网卡，跳过
  lo0/pdp_ip/utun/awdl/xhc20 桥接等虚拟网卡，逐个 open+compile+setfilter，
  第一个成功的即工作网卡
- **教训**：「API 返回成功」≠「抓到了你要的流量」；网卡选择必须显式化

**坑 5 · CIImage 裁剪 Y 翻转**
- **现象**：速度数字槽位裁剪位置系统性偏移
- **根因**：ScreenCaptureKit/CVImageBuffer 行序与 CGImage 坐标系 y 方向相反，
  直接按归一化坐标裁剪裁的是镜像区域
- **修复**：CIImage 路径裁剪时显式镜像 `ciRect.y = sh - yMax`；
  且 CI 裁剪纯 crop 不插值
- **教训**：跨框架（ScreenCaptureKit↔CoreImage）的坐标语义必须逐项对表

### C.2 环境/构建类

**坑 6 · BPF 权限重启即失效**
- **现象**：`sudo chmod 666 /dev/bpf*` 后正常，重启后 pcap 又 Permission denied
- **根因**：macOS 每次启动重建 `/dev/bpf*` 设备节点，权限回 root-only
- **修复**：App 内密码弹窗 → osascript 安装 `com.aurora.bpf-setup`
  LaunchDaemon（RunAtLoad 每次开机自动 chmod 666）——一次输入永久生效
- **教训**：设备节点权限是易失的，任何依赖 /dev 权限的方案都要考虑重启

**坑 7 · SwiftUI App 的 print 不回终端**
- **现象**：调试 print 消失，终端和 `log show` 都看不到
- **根因**：裸可执行 SwiftUI App 的 stdout 不回终端；并发线程高频 print 有竞争
- **修复**：`pcapLog` 写文件 `/tmp/aurora_pcap.log`（FileHandle seekToEnd 追加；
  早期「读全文+append+写回」在 10Hz 下 IO 爆炸且互相覆盖丢行）
- **教训**：SwiftUI App 的调试输出从一开始就该走文件日志

**坑 8 · CoreML 加载 .mlpackage 报 "Compile the model"**
- **现象**：`MLModel(contentsOf:)` 对 `.mlpackage` 抛
  *"Unable to load model … Compile the model with Xcode or MLModel.compileModel(at:)"*
- **根因**：新版 macOS 的 CoreML 不再隐式编译 `.mlpackage`，必须显式编译
- **修复**：`let compiled = try MLModel.compileModel(at: url)` 先编译，
  再 `MLModel(contentsOf: compiled)` 加载编译产物
- **教训**：分发 CoreML 模型优先用预编译 `.mlmodelc`；用 `.mlpackage` 就必须走 compileModel

**坑 9 · 二进制签名与 xattr**
- **现象**：App SIGKILL「Code Signature Invalid」
- **根因**：`xattr -cr` 删掉代码签名本身；或先签名 `.build` 内产物再 cp（cp 破坏签名）
- **修复**：固定顺序 `swift build → cp 到目标 → codesign 目标文件 →
  xattr -d com.apple.quarantine`（只删隔离属性）。固化在 `run.sh`
- **教训**：签名操作的对象和顺序是强约束

**坑 10 · 宏插件在中文路径 Xcode 下 malformed**
- **现象**：`swift build` 报 *"external macro implementation type
  'ObservationMacros.ObservableMacro' could not be found …
  swift-plugin-server produced malformed response"*
- **根因**：`xcode-select` 指向中文路径外置盘 `/Volumes/项目依赖/Xcode.app`，
  其 `swift-plugin-server`（`@Observable` 宏实现）在受限环境下响应异常
- **缓解**：编译需要完整权限（宏插件要写临时缓存）；
  根治需将 Xcode 装到无中文的本地路径
- **教训**：工具链路径含中文/外置盘会在最深处（编译器插件）咬人

**坑 11 · 静态链接 OpenCV 缺 HAL / BLAS 符号（2026-09-27）**
- **现象**：SPM 主 target 链接期报一片 undefined symbol，两轮：
  ① `carotene_o4t::*` ② `_cblas_sgemm$NEWLAPACK$ILP64` / `_dgels$NEWLAPACK$ILP64`
- **根因**：`libopencv_core.a` 等静态库不是自包含的。
  ① ARM SIMD HAL 在 `3rdparty/libtegra_hal.a` / `libkleidicv*.a`
  ② LAPACK/BLAS 走 Apple `Accelerate` 框架
- **修复**：`linkerSettings` 补 11 个 `.linkedLibrary` + `.linkedFramework("Accelerate")`
- **教训**：静态库的传递依赖不会自动带出，要按 undefined symbol 逐个补齐

**坑 12 · SPM `-L` 相对路径与符号链接陷阱（2026-09-27）**
- **现象**：`ld: library 'opencv_core' not found`，但库文件确实在
- **根因**：两个坑叠加 ——
  ① `-L` 用相对路径时，SwiftPM 在 **link 阶段**按构建产物目录解析，不是按包根
  ② `Vendor/opencv/lib` 曾被做成符号链接，形成嵌套自指
- **修复**：`-L` 一律用**绝对路径**（`#filePath` 推导包根）；
  静态库必须是**实体文件**
- **教训**：构建系统里的路径基准点（cwd vs 产物目录）必须显式确认，不能猜

**坑 13 · SwiftPM manifest 里没有 Foundation（2026-09-27）**
- **现象**：`Package.swift` 里写 `"\(#filePath)".replacingOccurrences(of:...)` 报
  *"value of type 'String' has no member 'replacingOccurrences'"*
- **根因**：manifest 在受限沙盒里编译，**只有标准库，没有 Foundation**
- **修复**：改用纯标准库字符串 API（`lastIndex(of:)` + 切片）推导包根
- **教训**：manifest 是独立执行环境，不能当普通 Swift 源码写

### C.3 并发/性能类

**坑 14 · 池化 CVPixelBuffer 跨步骤持有 → use-after-recycle（2026-09-27）**
- **现象**：光流偶发读到"错帧"或崩溃（隐患，未实际触发即被改掉）
- **根因**：`CaptureEngine` 直通缓冲是**池化私有缓冲**，`inferFast` 拷贝完
  就归还池子，下一帧可能拿到同一 IOSurface 被覆写。若把引用存起来留到
  tick 后半段再用，就是 use-after-recycle
- **修复**：在**帧消费点同步**完成灰度转换（转成自己的私有缓冲就与池子彻底解耦）
- **教训**：池化缓冲的生命周期只在当前回调内有效，跨步骤传递必须显式拷贝

**坑 15 · 光流延迟随调度优先级剧变（2026-09-27）**
- **现象**：同一份光流代码，空载 p95 1.7ms，加背景负载后报 12.96ms「超标」
- **根因**：测的是**主线程默认 QoS**，不是生产的 `.userInteractive`。
  光流延迟高度依赖调度优先级，同优先级硬抢 CPU 会抖到十几毫秒
- **修复**：自检显式 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`；
  并如实记录边界（7 路负载 @ UTILITY → 3.7ms ✓；同优先级占死 8 核 → ~9ms ✗）
- **教训**：性能判据必须对齐**生产的调度条件**，否则测出来的数没有意义

**坑 16 · OpenCV 线程数不是越多越快（2026-09-27）**
- **现象**：DIS 光流默认（用满 8 核）在 7 路负载下 p95 达 20.9ms；
  固定 2 线程只要 3.53ms
- **根因**：线程越多，被抢占的方式越杂乱，**尾延迟越差**。
  空载时 nt=4 最快，但生产环境不是空载
- **修复**：`cv::setNumThreads(2)`（`flow_bridge.cpp` 的 `kOpenCVThreads`）
- **教训**：并行度要按**最差工况**选，不是按空载最快选

### C.4 诊断/设计类（最"哲学"的四条）

**坑 17 · 伪诊断比没有诊断更坏（2026-09-27）**
- **现象**：用户报「看不到车道线」，而 `--yolopx-selftest` 打印
  `可行驶占比: 0.00%  车道线占比: 0.000%`，看起来像"模型没输出"
- **根因**：**那行数字是字段初值，不是测量结果** —— 自检里
  `engine.infer()` 一次都没被调用过。打印的 `drivableRatio`/`laneRatio`
  从未被赋值
- **后果**：一个**看起来在验证**的检查项，实际什么都没验。
  「掩码到底出不出」在全项目里没有任何证据，排查方向被误导到模型侧
- **修复**：给自检加真实推理（A2 节），用真实游戏画面跑完整链路。
  实测 da=3772 格 / ll=1158 格 —— **模型一直是好的，问题在显示层**
- **教训**：**打印一个未被赋值的字段，等于伪造证据。**
  自检里的每个数字都要能追溯到一次真实调用；加了真实推理后，
  "降级判定: 否"这类状态才第一次有了意义

**坑 18 · 单开关管两件事 = 小的把大的拖死（2026-09-27）**
- **现象**：车道线看不见，**连可行驶区也一起看不见**
- **根因**：`isDegraded` 是 da/ll 的**或**关系，却同时控制两层掩码的显示。
  车道线是细目标（前景占比 1.3~2.6%，天然贴近下限），它一塌陷就把
  可行驶区也压暗到 `0.18 × 0.35 = 0.063`（几乎不可见）
- **修复**：拆成 `laneDegraded` / `drivableDegraded` 分别调暗；
  **决策层继续用合并后的 `isDegraded`**（语义不变，不引入新风险）
- **协议设计注意**：新增 bit 时，旧发送方不发该位 → 恒为 0。
  要确认这个默认值落在**安全方向**（这里是"不压暗"= 偏亮，能看见），
  而不是反方向
- **教训**：合并指标适合做**决策门控**（宁可保守），但不适合做**显示分层** ——
  显示要如实表达"哪一部分不可信"，而不是"有任意一部分不可信就全体变暗"

**坑 19 · 内层循环里的除法：40 万次/帧（2026-09-27）**
- **现象**：`convertToGray` 实测 1.43ms，远超预期
- **根因**：内层循环逐像素算 `x * srcW / dstW`。而生产路径 640→640 时
  **srcW == dstW，这个除法恒等于 x** —— 纯浪费
- **实测**（M3，640×640，n=40）：

  | 写法 | p50 |
  |---|---|
  | 逐像素除法 | 0.639 ms |
  | 同尺寸直接步进 | **0.040 ms**（快 16 倍） |
  | 预计算列偏移表 | 0.264 ms |

- **修复**：加 `sameSize` 快路径；非同尺寸时列映射提到行循环外预计算
- **教训**：**把"恒定成立"的条件也当变量算**，是缩放类代码最常见的性能坑。
  写通用循环时先问一句：生产路径上这个量真的是变的吗？

**坑 20 · 验证脚本本身可能骗你（2026-09-27）**
- **现象**：自写的共享内存往返脚本报「5 项失败，逐格差异 6500」，
  看起来像位打包有严重 bug
- **根因**：该脚本复刻生产读写时**自身写错了**（累加器位序、起始偏移、
  清零行为与生产不一致），不是生产代码问题
- **修复**：改用**单格探针**（放一格看回读到哪）做确定性定位 ——
  9/9 精确命中，证明生产实现逐格无损
- **教训**：验证工具要先自证。**"测试失败"的第一反应应是怀疑测试本身**，
  尤其当失败模式呈现出"格数对但逐格差"这种置换特征时 ——
  真实 bug 通常不会这么整齐。用单点确定性探针比整体比对更快定位

### C.5 本会话新增（21-24，全部是我犯的）

**坑 21 · `drawingGroup()` 用在会动的子树上 = 每帧重建离屏纹理（2026-09-28）**
详见 §8.1 与 §19.2。

**坑 22 · "后台线程"不等于"空闲线程"（2026-09-28）**
详见 §8.3 与 §19.3。

**坑 23 · `pkill -f` 子串不匹配会静默失败（2026-09-28）**
- **现象**：收尾时执行 `pkill -f "AuroraDrive --engine" 2>/dev/null || true`，
  以为停掉了测试引擎，实际**没停** —— 它又跑了 18 小时
- **根因**：真实命令行是 `./AuroraDriveUI --engine`，
  而模式 `"AuroraDrive --engine"` 里 `AuroraDrive` 后面紧跟空格，
  **不匹配** `AuroraDriveUI`。`2>/dev/null` 又把 pkill 的报错吞了
- **后果**：僵尸引擎持有 `engine.lock`(flock) 与 socket，用户 UI 连上去后
  心跳超时、反复报"引擎失联"，排查方向被完全带偏
- **修复/纪律**：
  1. 杀进程前先 `pgrep -fl` 确认匹配到了谁，**再**执行 kill
  2. 不要用 `2>/dev/null` 吞掉 pkill 的报错 —— 失败必须可见
  3. 用能唯一匹配的模式（如 `pkill -f "AuroraDriveUI"`），或按 PID 精确杀
- **教训**：**"我以为停掉了"是危险的假设**。测试收尾必须有可验证的确认步骤
  （`pgrep` 返回空、socket 文件消失），而不是发个命令就当成功

**坑 24 · 守卫用了协议里不存在的字段 → 引擎模式下掩码全部不画（2026-09-28）**
详见 §8.2 与 §19.4。

---

---

## 附录 D：性能测量的方法论（下次别再犯）

本会话在性能测量上犯了太多错，总结成可复用的方法论。

### D.1 测量前的三个自问

1. **我测的是生产路径吗？**
   - 合成数据 vs 真实数据（纹理分布差 3.4 倍！）
   - 空载 vs 生产负载（OpenCV 线程数在负载下结论相反）
   - 默认 QoS vs `.userInteractive`（光流差 7 倍）

2. **我测的层级对吗？**
   - 离线夹具（CIGaussianBlur）**没有** SwiftUI 离屏合成语义
   - 模型推理耗时 ≠ 端到端链路耗时
   - 单次调用耗时 ≠ 每帧总成本

3. **这个量在生产路径上真的是变的吗？**
   - `x * srcW / dstW` 在 640→640 时恒等于 x
   - 把恒定当变量算是缩放代码最常见的坑

### D.2 测量的正确姿势

| 场景 | 工具 | 命令 |
|---|---|---|
| CPU 热点 | `sample` | `sample <pid> 3 -file /tmp/s.txt` |
| 延迟分布 | 日志统计 | `grep -oE "lag=[0-9]+ms" ... \| sort -n` |
| 模型耗时 | 离线 benchmark | 用**真实帧**跑 30+ 次取分位 |
| 内存泄漏 | `ps` 监控 | `ps -p <pid> -o rss` 持续观察 |
| GPU/合成 | `sample` 找 RenderBox | `grep -c "make_texture"` |

### D.3 必须报分位数，不能只报平均值

本会话实测的光斑 blur：
```
800×450   p50 2.13ms   p95 143ms     ← p95 是 p50 的 67 倍！
1200×675  p50 2.93ms   p95 5.25ms
1470×956  p50 4.20ms   p95 6.90ms
```

**平均值会掩盖尾延迟**，而尾延迟才是卡顿的来源。
光流、帧率、渲染都必须看 p95/p99。

### D.4 跨批次数字不可比

主机负载随时变化（后台 VM、QQ、WindowServer...），
**跨批次的性能数字必须归一化或同批次重测**。
本会话就有"同一份代码两次测出不同结论"的情况。

### D.5 性能改动的验收清单

改完性能相关代码，逐条打勾：

- [ ] 用的是真实输入分布（不是合成数据）
- [ ] 带的是生产负载（不是空载）
- [ ] 调度条件对齐生产（QoS / 线程数）
- [ ] 报了 p50 与 p95（不只平均值）
- [ ] 同批次有对照组（改前 vs 改后）
- [ ] UI/渲染改动抓了真实堆栈（`sample <pid> 3`）
- [ ] 问过"这个改动在哪个运行模式下生效"
- [ ] 问过"自检跑的是哪个模式，能覆盖吗"

**任何一条打不上勾，结论都不可信。**

---

## 附录 E：本会话的完整数据记录（可溯源）

所有数字均在会话中当场实测，非回忆。

### E.1 YOLOPX 推理耗时（30 次，640×640，真实游戏帧）

```
min=44.0  p50=46.5  p90=49.4  p95=50.0  max=52.7 ms   → 21.5 Hz
```

**测量脚本**：`swiftc -O bench.swift -framework CoreML`，
模型 `models/yolopx/yolopx3_pal8_detfp.mlmodelc`，
输入 `data/nte_test_frames/yt_vJ-SFOrqLWI_maxresdefault.jpg`（缩放 640×640）。

### E.2 DIS 光流耗时（40 次，640×640，setNumThreads(2)）

```
合成块状图（纹理梯度 2.51）  p50=1.061ms  p95=1.689ms  max=1.870ms
真实游戏画面（纹理梯度 8.58） p50=0.957ms  p95=1.251ms  max=1.304ms
```

**⚠️ 真实画面反而更快** —— 纹理丰富时 DIS 收敛更快。

**纹理梯度实测**（640×640 灰度）：
```
真实游戏画面: 均值=136.3  方差=3811  平均梯度=8.58
合成块状图:   均值=124.3            平均梯度=2.51
```

### E.3 光流线程数对比（7 路负载下）

| 配置 | p95 |
|---|---|
| 默认（全核 8） | **20.86 ms** |
| `setNumThreads(2)` | **3.53 ms** |

### E.4 灰度转换三种写法（M3，640×640，n=40）

| 写法 | p50 |
|---|---|
| 逐像素除法 | 0.639 ms |
| 同尺寸直接步进 | **0.040 ms** |
| 预计算列偏移表 | 0.264 ms |

### E.5 掩码绘制优化（Canvas 路径填充）

| 项 | 优化前 | 优化后 |
|---|---|---|
| 可行驶区 12% | 0.908 ms | **0.302 ms** |
| 车道线 2% | 0.192 ms | **0.097 ms** |
| + 描边（新增） | — | 0.159 ms |

**几何等价性验证**：7 种网格形态，alpha 通道逐像素比对，**覆盖率完全一致**。

### E.6 光斑 blur 实测（CIGaussianBlur radius 60）

| 尺寸 | p50 | p95 |
|---|---|---|
| 800×450 | 2.13 ms | **143 ms** |
| 1200×675 | 2.93 ms | 5.25 ms |
| 1470×956 | **4.20 ms** | 6.90 ms |

**⚠️ 这是离线值，不能直接推断真实 UI 成本**（§19.2 的教训）。

### E.7 卡顿事故的引擎侧数据（2026-09-28 21:24~21:26）

```
capWork:  9~14ms → 21ms → 71ms → 301ms → 2081ms → 2081ms
tickGap:  33ms → 38ms → 43ms → 741ms → 1198ms → 17044ms
mode:     端到端主驾 → YOLO接管 → 纯规则兜底
```

**内核日志**：
```
process AuroraDriveUI[61485] caught waking the CPU 45001 times over ~109 seconds,
averaging 409 wakes / second and violating a limit of 45000 wakes over 300 seconds
```

**系统状态**：load average **171.43**（8 核机器），
CPU 44.88% user / 36.16% idle，内存 15G used，
swap 1458M used，`kernel_task` 26.8% / 612 threads，`WindowServer` 47.1%。

### E.8 修复前后对比

| 指标 | 修复前 | 修复后 |
|---|---|---|
| UI 待机 CPU | 30.5% | **6.9%** |
| `CA::Transaction::commit` 样本 | 1402/1402 | 6 |
| `RootTexture::make_texture` 样本 | **1110** | **0** |
| `GaussianBlur FilterStyle` | 主因 | **0** |
| 系统 load | 171 | 3~7 |

### E.9 掩码可见性几何验证（复刻 MaskOverlay 数学）

| 配置 | 可行驶区矩形 | 车道线矩形 | 守卫 |
|---|---|---|---|
| 本地模式 | 99 | 176 | ✓ |
| **引擎模式·修复前** | 99 | 176 | **✗** |
| 引擎模式·修复后 | 99 | 176 | ✓ |

```
可行驶区 bbox = (67,194) 1073×743   占视口 98.4%
车道线   bbox = (67,269) 1073×668   占视口 88.5%
```

**几何完全一致 → 证明 `newW` 对绘制数学毫无作用。**

### E.10 YOLOPX 自检基准

```
[warmup] yolopx3 预热完成: 83.2ms（首次）/ 1975.0ms（冷机首次含编译）
✓ 推理产出结果 — 耗时 53.4 ms
检测框 9 个 / 可行驶占比 26.19% / 车道线占比 8.042%
da=3772 ll=1158   降级判定: 否
```

### E.11 物理极限计算

```
YOLOPX3: 148.11 GFLOPs
Apple M3 GPU: 9.26 TFLOPS
理论下界: 148.11 / 9.26 = 16.0 ms
实测: 46.5 ms（含内存带宽、调度、后处理开销）
```

**28ms 窗口**（保持 30Hz）在理论上可达，但需要更激进的优化（全部已否决）。

---

## 附录 F：术语表

| 术语 | 全称/含义 |
|---|---|
| **YOLOPX** | 三头视觉模型（det 检测 / da 可行驶区 / ll 车道线），甲方核心资产 |
| **da** | drivable area，可行驶区域 |
| **ll** | lane line，车道线 |
| **det** | detection，检测框 |
| **M9** | 端到端驾驶模型（`m9_mono.mlmodelc`） |
| **第二司机/assist** | 辅助驾驶模型（`game_assist_control.mlmodelc`） |
| **yolo26s** | 用于**预测**的检测模型（4.6ms） |
| **DIS** | Dense Inverse Search，OpenCV 的光流算法（CVPR 2016） |
| **letterbox** | 保持宽高比的等比例缩放 + 填充（YOLO 标准预处理） |
| **α-β 滤波** | 位置-速度两态卡尔曼简化版（α 管位置，β 管速度） |
| **ego** | 自车（游戏里玩家控制的角色/车辆） |
| **NTE** | Neverness to Everness，《异环》英文名 |
| **TCC** | Transparency, Consent, and Control（macOS 权限系统） |
| **PAC** | Pointer Authentication Codes（Apple Silicon 指针签名） |
| **capWork** | `CaptureEngine.lastFrameWorkMs`，抓屏回调处理耗时 |
| **capGap** | 帧到达间隔 |
| **tickGap** | 引擎 tick 间隔（30Hz → 33ms） |
| **fail-open** | 输入不可信时返回 nil，让调用方维持原决策 |
| **glassmorphism** | 玻璃拟态（用户要求的视觉风格） |
| **bloom/光斑** | `AuroraLightField`，用户要求的空间感光效（**功能非装饰**） |

---

## 附录 G：代码里的关键注释位置索引

项目注释非常详细（这是优点，请保持）。以下是最该读的注释：

| 位置 | 内容 |
|---|---|
| `AuroraDriveApp.swift:3136` | 为什么不能直接读 `yolopxEngine.drivableMask` |
| `AuroraDriveApp.swift:3690` | 为什么光流必须在调用线程同步执行（池化缓冲约束） |
| `AuroraDriveApp.swift:4714`(约) | `MaskOverlay` 的分层调暗说明 + `newW` 守卫修复记录 |
| `AuroraTheme.swift:330`(约) | `.drawingGroup()` 回退记录 + 离线夹具的局限 |
| `YolopxEngine.swift:74`(约) | `positiveCount` 实现 |
| `YolopxEngine.swift:148` | letterbox 计算（含 padX/padY 的 ±0.1 取整依据） |
| `YolopxEngine.swift:202` | `lanePositiveFloor` 取值依据 |
| `YolopxEngine.swift:250` | `lanePositiveCeil` 取值依据与局限声明 |
| `MotionPredictor.swift:97` | α=0.55 的来历 |
| `MotionPredictor.swift:104` | β=0.25 的稳定性依据 |
| `MotionPredictor.swift:61` | 为什么决策层必须对 `isPredicted` 降权 |
| `EngineMain.swift:96`(约) | 共享内存头部布局全表 |
| `EngineMain.swift:242` | `publishMasks` 的 seq 判据说明 |
| `EngineClient.swift:589` | 掩码区读取 + 物理边界校验的理由 |
| `EngineClient.swift:644`(约) | `newW`/`newH` 补传说明 |
| `FallbackGuard.swift:1` | 双结构兜底的用户原话 + 定位说明 |
| `FallbackGuard.swift:20` | 四条设计纪律 |
| `CaptureEngine.swift:336` | YOLO 直通（vImage 缩放，绕开 GPU 排队） |
| `CaptureEngine.swift:225` | `queueDepth = 3`（坑 22 的关键） |
| `OpticalFlowBridge.swift:125` | 为什么 context 要长期持有 |
| `flow_bridge.cpp:20` | `kOpenCVThreads = 2` 的完整依据 |
| `flow_bridge.cpp:40` | `kMedianSampleStep = 4` 的说明 |

**代码风格要求**（项目既有惯例）：
- 注释写**为什么**，不只写**做了什么**
- 性能数字必须带**测量条件**（尺寸、负载、QoS）
- 被否决的方案要**留记录 + 原因**（避免后人重试）
- 踩过的坑要标注**日期**

---

## 附录 H：如果你是 AI 接手

这几条是给下一个 AI 助手的，血的教训。

### H.1 你会遇到的三个陷阱

**陷阱 1：你会忍不住"优化"**
本项目已有大量优化，且**很多看似可以优化的地方已经试过并被否决**。
改之前先搜：`grep -rn "已否决\|实测\|measure" Sources/`。
**看到"实测"字样就先读注释**，可能你正要试的东西已被否决。

**陷阱 2：你会相信离线基准**
本会话最大的两个 bug 都源于"离线测出 A 很贵 → 优化 A → 更慢"。
**离线夹具缺少真实运行时的语义**（SwiftUI 离屏合成、调度竞争、内存压力）。

**陷阱 3：你会以为自检过了就没事**
46 项自检覆盖模型与算法层。**传输层 + 显示层的复合 bug 它测不到。**
问自己：**"这个改动在哪个运行模式下生效？自检跑的是哪个模式？"**

### H.2 你的工作纪律

1. **先取证，再假设。** 用户报问题 → 抓堆栈/读日志/读共享内存 → 形成假设
2. **不许说"我觉得"。** 用户会要数据
3. **改完必须实测。** UI 改动要 `sample <pid> 3`
4. **严禁删文件。** `git status --porcelain | grep -c '^ D'` 必须为 0
5. **不碰模型文件。** MD5 记在 §2
6. **不碰桌面文件。** 用户的东西一个都别动
7. **不自动启动应用。** 用户反感，且 TCC 权限只有他有

### H.3 遇到卡住时

**别猜。** 本会话所有"猜"都翻车了，所有"抓数据"都定位了。

可用手段：
- `sample <pid> 3` → CPU 热点
- `~/Library/Logs/AuroraEngine.log` → 引擎全量日志
- 直接读共享内存（Python，模板见 §12.4）
- `git diff` → 看最近改了什么

**最有用的一招**：**如果你刚改了代码就出问题，先回退你的改动确认。**
本会话两次都是"我的改动是元凶"。

### H.4 交接的诚实态度

本会话造成的三个 bug 都写进了文档（§19 完整复盘）。
**不掩饰、不甩锅、不轻描淡写。**

原因：**下一个接手者需要知道哪些地方脆弱**。
如果我把"我犯的错"写成"系统固有缺陷"，他会重蹈覆辙。

### H.5 AI 特有的风险（务必自省）

| 风险 | 表现 | 对策 |
|---|---|---|
| **过度自信** | 有"理论依据"就动手，不做端到端验证 | 改完必须实测 |
| **编造状态** | 说"应该已经修好了"但没验证 | 只报实测数据 |
| **静默失败** | `2>/dev/null` 吞掉错误 | 不吞报错，先 `pgrep -fl` |
| **乐观估计** | 用合成数据估成本 | 用真实数据 |
| **遗漏集成** | 只测单个函数，不测集成 | 问"在哪个模式生效" |
| **重复试错** | 重试已否决的方案 | 先 grep 注释找"已否决" |

**用户的原话值得反复读**：

> **"你不要搁这幻想啊。"**

这句话是针对我"以为用户在驾驶"的臆测说的。
**它适用于所有形式的臆测** —— 包括性能臆测、状态臆测、因果臆测。

---

## 附录 I：用户原话摘录（红线的一手依据）

以下是用户在本项目中明确表达过的要求，**一字未改**。
新接手者应当知道这些约束来自用户，不是我的推测。

### I.1 关于模型（最高优先级）

> "必须用 you low 系的优罗披萨，那个模型，千万不能换换……
> 如果一旦换了这个模型或者换成别的模型，那么立马原地爆炸，
> 我们整个项目可能会解散。"

> "26S 是拿来做预测用处的。"

**解读**：YOLOPX（优罗披萨）= 主感知模型，不可替换。
yolo26s = 预测专用，与主模型分工不同。

### I.2 关于光流

> "我让你去找开元的小刘。"
（意为：去找开源框架，不要手搓）

> "open CV 拉下来试一下。"

> "必须给我压到五毫秒以内。"

> "可是我们要的是 640×640。"

**解读**：光流必须用开源框架（最终选了 OpenCV DIS），
≤5ms，640×640。三条都是硬指标。

### I.3 关于可视化与验证

> "你给我可视化验证工具，我有啥用？……
> 最好的可视化就是可以直接在阅览框里看到，
> 而我不想需要工具……直接阅览框你更直观。"

**解读**：**可视化必须在预览框里直接可见**，
不要给 CLI 工具让用户自己跑。这条直接影响了 `MaskOverlay` 的设计。

### I.4 关于视觉风格

> （要求）"非常高级"，要反复抠细节、往死里抠细节。

> （偏好）有空间感光斑、高对比度、纯深色背景加极淡网格的玻璃拟态，
> 拒绝低对比度发灰的毛玻璃效果。

**解读**：光斑（bloom）是**功能需求不是装饰**，不许删不许减。
这条在 `AuroraTheme.swift` 的注释里被明确记录过。

### I.5 关于性能诊断

> "他妈的，你给我解释一下为什么他妈的会出现这个问题，
> 他妈的那个引擎连接不上了，自己测试自己测试，你都自己测试。"

> "现在我已经打开自驾驶，现在基本是不能动的状态，
> 你去检查一下为什么会卡成那样。"

> "不行啊，我看不到可行驶区域和车辆钱，
> 我只能看到那个就是把人物矿泉墙那个东西没有看到啊。"
（"人物矿泉墙" = 检测框的口误/语音输入误差）

**解读**：用户**要求 AI 自己测试**，不要让他来回试。
且用户描述问题时常有语音输入误差，需要结合上下文理解。

### I.6 关于文件安全（铁律）

> （历史）用户曾因 AI"清理"损失**三万多人民币**。

**解读**：严禁删除或覆盖任何既有文件。
这是本项目**最不可协商的一条**。

### I.7 关于工作方式

> "你的计划呢？先列计划，然后继续干活。"

> "不对呀，你思考呢，你思考怎么被吞了？"

> "你不要搁这幻想啊。"

**解读**：
- 用户要**先看到计划**再干活
- 用户会检查 AI 的推理过程是否完整（不能跳过思考）
- **用户会当场纠正 AI 的臆测** —— 所以绝不能编造状态

### I.8 关于测试主动性

> "自己测试自己测试，你都自己测试。"

> "我来测试一下。"（用户主动承担需要 TCC 权限的测试）

**解读**：**能自己测的必须自己测**；
只有需要 TCC 权限（必须用户进程链）的部分才交给用户。

### I.9 从原话提炼的行动准则

| 用户原话要点 | 对应的行动准则 |
|---|---|
| 模型不能换 | 任何涉及换模型的方案直接否决 |
| 让开源框架干活 | 不手搓底层算法 |
| ≤5ms @ 640×640 | 性能红线，不许放宽 |
| 预览框里直接看 | 可视化做进 UI，不做 CLI 工具 |
| 光斑必须有 | 不许为了性能删视觉特性 |
| 你都自己测试 | 主动验证，不推给用户 |
| 不要再幻想 | 只报实测数据，不编状态 |
| 先列计划 | 复杂任务先给计划 |
| 删文件赔三万 | 零删除，每次自证 |

---

## 附录 J：项目发展的关键时刻（历史脉络）

帮助理解"为什么代码长成现在这样"。

### J.1 阶段划分

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| **早期** | 网络抓包（pcap）解析游戏状态 | 坑 1-7 的来源 |
| **中期** | 接入 CoreML 模型 + 视觉链路 | 坑 8-13 |
| **过渡** | 从单进程到双进程（引擎分离） | 共享内存协议 v1→v3 |
| **近中期** | 光流 + 运动预测接入 | 坑 14-16、20 |
| **2026-09-27** | 性能优化第一轮 | 坑 17-19、21 |
| **2026-09-28** | 本会话：三个 bug 修复 | 坑 21-24（更新） |

### J.2 架构演进的驱动力

**为什么分成两个进程？**
- UI 渲染与推理互相抢占（同一个主线程会互相拖累）
- 引擎可以独立重启而不影响 UI
- 但代价是**引入了跨进程协议的所有复杂度**（坑 24 就源于此）

**为什么自己搭共享内存而不用 XPC？**
- 72MB 帧数据，XPC 序列化开销太大
- 需要双缓冲 + 帧序号跳过机制
- 代价：**手动管理内存布局，字段对不齐就是 bug**

**为什么有这么多兜底？**
- 用户明确要求"双结构兜底"
- 模型链路可能断（降级状态机 4 档）
- 兜底的设计纪律（fail-open / 有界输出 / 连续确认 / 突变丢弃）
  是项目里**最成熟的设计**

### J.3 当前技术债

| 债 | 影响 | 优先级 |
|---|---|---|
| 端到端掩码可见性无自检 | 同类 bug 会复发 | **高** |
| 协议字段靠人工对齐 | 已因此出过 bug（坑 24） | 高 |
| 预测目标未降权 | 决策精度略低 | 中 |
| `ll` 占比注释过时 | 误导后来者 | 低 |
| 光流无兜底路径 | YOLO 停时光流也停 | 中 |
| 本地/引擎模式双路径 | 自检只覆盖一半 | **高** |

**最大的一条**：**双运行模式（本地/引擎）导致自检覆盖永远只有一半。**
坑 17 与坑 24 都是这个根源 —— 自检跑本地模式，而生产跑引擎模式。

**建议**：将来应当给关键功能做**双模式自检**，
或者干脆在自检里跑两遍（本地 + 引擎）。

---

## 附录 K：交接检查清单

打印出来，逐条打勾。

### K.1 环境确认

- [ ] 项目路径正确：`/Users/dupi/Desktop/自动驾驶系统`
- [ ] `git status --porcelain | grep -c '^ D'` 输出 **0**
- [ ] 模型 MD5 匹配（§2 的两个值）
- [ ] 桌面文件未被改动
- [ ] 无残留进程：`pgrep -fl AuroraDriveUI` 为空

### K.2 构建与自检

- [ ] `swift build -c release --disable-sandbox --scratch-path .build/scratch` 成功
- [ ] `./AuroraDriveUI --yolopx-selftest` → 46/46
- [ ] `./AuroraDriveUI --opticalflow-selftest` → 7/7
- [ ] `./AuroraDriveUI --motion-selftest` → 15/15
- [ ] `codesign --verify --deep AuroraDriveUI.app` → valid

### K.3 文档阅读

- [ ] 读完本文档 §2（红线）
- [ ] 读完本文档 §4（24 条坑）
- [ ] 读完本文档 §19（事故复盘）
- [ ] 读过 `docs/文档库/自动驾驶与功能/pitfalls.md`
- [ ] 读过 `docs/优化改动清单与后果.md`

### K.4 首次运行验证（需用户配合）

- [ ] 请用户启动：`nohup ./AuroraDriveUI > /tmp/aurora_ui.log 2>&1 &`
- [ ] 确认引擎就绪（`AuroraEngineClient.log` 里"✅ 引擎模式已激活"）
- [ ] 请用户开始驾驶
- [ ] 确认 `grep 统计:` 显示 `driving=true` 且 `maskSeq` 递增
- [ ] **请用户确认预览框里能看到可行驶区（淡绿）与车道线（青色）**

### K.5 交接完成确认

- [ ] 我已理解三条红线
- [ ] 我已理解"不许说我觉得没问题"
- [ ] 我已理解"离线基准不能替代真实场景验证"
- [ ] 我已理解"自检全绿 ≠ 功能正常"
- [ ] 我知道用户会亲自看画面，遇到 UI 现象要问他
- [ ] 我知道不能自动启动应用、不能碰桌面文件

---

## 附录 L：最后的话

这份交接文案写了 32K，但我最想传达的其实只有一句：

> **这个项目里，所有"我以为"都是错的来源，所有"我量过"都是对的起点。**

本会话我犯了三个错，每一个都有"理论依据"：
- 离线测出 blur 贵 → 加 `.drawingGroup()` → **更卡**
- 成本估算 1.7ms → 挪到后台线程 → **雪崩**
- 守卫更严格更安全 → 用 `newW > 0` → **全盲**

而每一次定位问题，都是因为**我去抓了真实数据**：
- `sample` 抓堆栈 → 发现 1402/1402 样本在渲染
- 读引擎日志 → 发现引擎侧一切正常，问题在 UI
- 读共享内存 → 发现协议里根本没有 `newW`

**用户比我想的更懂这个项目。** 他的原话里已经包含了正确答案：
- "最好的可视化就是可以直接在阅览框里看到" → 他不想要工具，想要直接可见
- "你自己测试" → 他要我主动验证，不是让他来回试
- "你不要搁这幻想" → 他在提醒我别编造状态

**下一个接手者：请尊重这份文档里的每一个数字，它们都是量出来的。
也请尊重用户说的每一句话，它们都是需求的原始形态。**

祝顺利。

---

*交接文案完*
*2026-09-29*
*基于真实代码、真实日志、真实测量数据*
*全部数字可溯源（文件路径 + 行号 或 日志命令 已给出）*

> ---
>
> ## ⚠️ 以下为**重复粘贴的残留内容**（2026-09-29 复核标注）
>
> 上文「交接文案完」是本文件的**正式结尾**。其后的全部内容（约 128 行）是
> **附录 H 与附录 D 的正文被误粘一遍**，属编辑事故，**不是新章节**。
>
> | 位置 | 内容 | 原出处 | 判定 |
> |---|---|---|---|
> | 约 2473 行起 | `H.1 你会遇到的三个陷阱` / `H.2 你的工作纪律` | **附录 H**（2159 行） | 重复 |
> | 约 2540 行起 | `D.2 测量的正确姿势` + 场景/工具/命令表 | **附录 D**（1901 行） | 重复 |
>
> **处置**：按「严禁删除既有内容」铁律，**此处原文保留**，仅加本标注。
> **阅读建议**：读到「交接文案完」即可停止；要查 H/D 内容请直接跳到对应附录。
>
> ---
>
> （以下为重复内容原文）


这几条是给下一个 AI 助手的，血的教训：

### H.1 你会遇到的三个陷阱

**陷阱 1：你会忍不住"优化"**
本项目已有大量优化，且**很多看似可以优化的地方已经试过并被否决**。
改之前先搜：`grep -rn "已否决\|实测\|measure" Sources/`。
**看到"实测"字样就先读注释**，可能你正要试的东西已被否决。

**陷阱 2：你会相信离线基准**
本会话最大的两个 bug 都源于"离线测出 A 很贵 → 优化 A → 更慢"。
**离线夹具缺少真实运行时的语义**（SwiftUI 离屏合成、调度竞争、内存压力）。

**陷阱 3：你会以为自检过了就没事**
46 项自检覆盖模型与算法层。**传输层 + 显示层的复合 bug 它测不到。**
问自己：**"这个改动在哪个运行模式下生效？自检跑的是哪个模式？"**

### H.2 你的工作纪律

1. **先取证，再假设。** 用户报问题 → 抓堆栈/读日志/读共享内存 → 形成假设
2. **不许说"我觉得"。** 用户会要数据
3. **改完必须实测。** UI 改动要 `sample <pid> 3`
4. **严禁删文件。** `git status --porcelain | grep -c '^ D'` 必须为 0
5. **不碰模型文件。** MD5 记在 §2
6. **不碰桌面文件。** 用户的东西一个都别动
7. **不自动启动应用。** 用户反感，且 TCC 权限只有他有

### H.3 遇到卡住时

**别猜。** 本会话所有"猜"都翻车了，所有"抓数据"都定位了。

可用手段：
- `sample <pid> 3` → CPU 热点
- `~/Library/Logs/AuroraEngine.log` → 引擎全量日志
- 直接读共享内存（Python，模板见 §12.4）
- `git diff` → 看最近改了什么

**最有用的一招**：**如果你刚改了代码就出问题，先回退你的改动确认。**
本会话两次都是"我的改动是元凶"。

### H.4 交接的诚实态度

本会话造成的三个 bug 都写进了文档（§19 完整复盘）。
**不掩饰、不甩锅、不轻描淡写。**

原因：**下一个接手者需要知道哪些地方脆弱**。
如果我把"我犯的错"写成"系统固有缺陷"，他会重蹈覆辙。

---

本会话在性能测量上犯了太多错，总结成可复用的方法论。

### D.1 测量前的三个自问

1. **我测的是生产路径吗？**
   - 合成数据 vs 真实数据（纹理分布差 3.4 倍！）
   - 空载 vs 生产负载（OpenCV 线程数在负载下结论相反）
   - 默认 QoS vs `.userInteractive`（光流差 7 倍）

2. **我测的层级对吗？**
   - 离线夹具（CIGaussianBlur）**没有** SwiftUI 离屏合成语义
   - 模型推理耗时 ≠ 端到端链路耗时
   - 单次调用耗时 ≠ 每帧总成本

3. **这个量在生产路径上真的是变的吗？**
   - `x * srcW / dstW` 在 640→640 时恒等于 x
   - 把恒定当变量算是缩放代码最常见的坑

### D.2 测量的正确姿势

| 场景 | 工具 | 命令 |
|---|---|---|
| CPU 热点 | `sample` | `sample <pid> 3 -file /tmp/s.txt` |
| 延迟分布 | 日志统计 | `grep -oE "lag=[0-9]+ms" ... \| sort -n` |
| 模型耗时 | 离线 benchmark | 用**真实帧**跑 30+ 次取分位 |
| 内存泄漏 | `ps` 监控 | `ps -p <pid> -o rss` 持续观察 |
| GPU/合成 | `sample` 找 RenderBox | `grep -c "make_texture"` |

### D.3 必须报分位数，不能只报平均值

本会话实测的光斑 blur：
```
800×450   p50 2.13ms   p95 143ms     ← p95 是 p50 的 67 倍！
1200×675  p50 2.93ms   p95 5.25ms
1470×956  p50 4.20ms   p95 6.90ms
```

**平均值会掩盖尾延迟**，而尾延迟才是卡顿的来源。
光流、帧率、渲染都必须看 p95/p99。

### D.4 跨批次数字不可比

主机负载随时变化（后台 VM、QQ、WindowServer...），
**跨批次的性能数字必须归一化或同批次重测**。
本会话就有"同一份代码两次测出不同结论"的情况。

---

| 你看到的 | 可能的真实含义 | 怎么确认 |
|---|---|---|
| 「延迟 240ms」 | 节拍周期 = 1000/帧率，**不是推理耗时** | 实测推理只有 46.5ms |
| 「掩码看不到」 | 先看 `driving` 是否为 true | `grep 统计:` |
| 「卡」 | 可能是渲染，也可能是采集，也可能是内存 | `sample` 抓堆栈 |
| `capGap == capWork` | 帧来得慢 / 处理路径被堵，不是处理慢 | 看两者是否同步涨 |
| 自检全绿但功能异常 | 自检覆盖不到该模式 | 问"这改动在哪个模式生效" |
| `frames` 不涨 | 推理停了，或没在驾驶 | 看 `driving` |
| `da=0格` | 掩码真空，或没在驾驶 | 看 `driving` + `降级` |
| 「引擎失联」 | 可能有僵尸引擎占着锁 | `pgrep -fl AuroraDriveUI` |

---

*（交接文案完）*


**这是个双进程 macOS 原生自动驾驶辅助系统，
YOLOPX 模型是绝对不能碰的甲方核心资产，
光流必须 ≤5ms@640×640 用 OpenCV，
严禁删任何文件，
改完必须实测（UI 改动要抓真实堆栈），
不许说"我觉得没问题"。**

本会话最大的两个教训：
1. **离线微基准不能替代真实 UI 堆栈采样**（`.drawingGroup()` 事故）
2. **自检全绿 ≠ 功能正常**（`newW` 守卫事故 —— 只在引擎模式暴露）

---

*交接文案生成于 2026-09-29，基于真实代码与实测数据，非回忆。*
