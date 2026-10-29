# 2 · 主循环 CPU 热路径审计（每帧/每秒的白做计算）

- 审计时间：2026-10-24 18:26–18:52
- 审计对象：`/Users/dupi/Desktop/自动驾驶系统`（AuroraDrive，Swift Package，UI 进程 + 引擎进程）
- 审计方式：**纯只读静态审计 + 现有运行日志取证**。未改代码、未 `swift build`、未 `./run.sh`、未启停 App。
- 用户铁律：不降质量 / 不降频 / 不降模型精度 / 不砍功能 —— 本报告只清理「纯浪费」（白算、白搬、算了没人用）。
- 与其他并行报告的分工：本报告**只覆盖每帧/每秒主循环内的计算与内存搬运**。空转态定时器/OCR 归属 `4-idle-waste.md`；CoreML `computeUnits` 归属 `3-compute-units.md`。凡与它们重叠处本报告显式标注「不重复记账」。

---

## 1. 一句话结论

**最大的白做不在推理，而在「帧搬运链」：引擎每 tick 无条件把整帧像素 memcpy 进共享内存并自增 `seq`，UI 每 tick 因此 `Data(bytes:)` 再拷一遍 + 重建 `CGImage` 再提交 WindowServer —— 同一张画面在无新帧时被完整搬了 2 次、并且**在空闲态也照跑**（日志实证 15.0Hz 从不降级）。其次是掩码发布的「指纹算了但没用来短路」，每次 tick 仍重写 2×3200 字节 + 重算 2×160×160 个前景位。**

判定依据（硬数据，非推测）：`~/Library/Logs/AuroraEngine.log` 连续 38 条统计行，`seq` 每 15 秒精确 +225 → **15.0 次/秒发布，零抖动**；同期 `yolopx 帧数=5814` **完全冻结不变**、`det=0`、`driving=false` → 发布的内容是**同一张陈帧**，不是新画面。

---

## 2. 浪费清单表

> 「成本估算」列凡未实测均标注 **估算** 并给出算式。实测数据来自 `docs/整合文档/05-性能与优化全史.md`（含 2026-10-11 `sample` 热点榜）与本次日志取证，出处逐条标注。

| # | 位置 (file:line) | 浪费类型 | 每帧/每秒成本估算 | 判定依据 | 修复难度 |
|---|---|---|---|---|---|
| **1** | `Core/EngineMain.swift:1431`（`publish` 调用点）→ `:415-449`（像素区） | **多余拷贝 + 算了没人用**：每 tick 无条件整帧写入，`seq` 无条件 +1（`:469`），即使画面与上一 tick 完全相同 | 480×312 缩略帧 **585.0 KiB/帧**（`480×312×4 = 599,040 B`，由 `CaptureEngine.swift:1190-1195` 的 `maxWidth=480` 对 2940×1912 换算得出）；15Hz → **8.57 MiB/s 写**。引擎侧逐行 `memcpy`（`:441` 整块 / `:444` 逐行） | `tickOnce` 里 `publish` **不受 `isDriving` 门控**（`:1431` 在 `if st.isDriving` 之外，对比 `:1468` 掩码就有门控）；`currentFrameCG` 全仓**只有赋值、没有任何 `= nil`**（声明 `AuroraDriveApp.swift:5193`，写入仅 `:6689` 与 `:7164`；`grep 'currentFrameCG = nil'` 零命中），stop 后仍持最后一帧 → 空闲态每 tick 重发的就是这张陈帧。日志：`driving=false` 时 `seq` 仍 15.0Hz | 低 |
| **2** | `Core/EngineClient.swift:645-647` → `:673-688` | **多余拷贝 ×2**：`seq` 变 → `Data(bytes:)` 全帧拷 1 份 → `CGDataProvider` 包一层 → `CGImage` 重建 → `frameHost.push` 提交 WindowServer | 每帧再拷 **585.0 KiB** → 15Hz **8.57 MiB/s**；叠加 #1 合计 **17.14 MiB/s**。CGImage 对象 **15 个/秒** 新建 | `poll()` 仅以 `seq != lastFrameSeq` 判新（`:646`）。因 #1 让 `seq` 每 tick 必变，这道门**永远放行**，等于没有门。注释 `:664-672` 自述「缩略帧 585KB，memcpy 约 15µs/帧」——**单次不贵，但它是无条件发生的** | 低 |
| **3** | `Core/EngineMain.swift:1473-1483` | **算了没人用 / 白搬**：`fp` 指纹算出来只用于 `maskSeq += 1`，**`publishMasks` 调用在 `if fp != lastFingerprint` 之外**，每 tick 都重写两份掩码 | 每 tick `initialize(repeating:0)` 清零 **6400 B**（`:287`，2×3200）+ 逐行位打包，`positiveCount` 全量扫 **2×25600 个元素**（`YolopxEngine.swift:76-80`）→ 15Hz ≈ **96 KB/s 写 + 76.8 万次/秒元素比较**（估算，按 160×160×2×15） | 注释 `:316-317` 明写「只有在掩码世代号变化时才真正重写数据」——**代码与注释相反**。`sample` 热点榜 `EngineFrameShm.writeMask` 占 **96 采样**（`05-性能与优化全史.md:236`），证明它在真实采集里是可见成本 | 低 |
| **4** | `Inference/YolopxEngine.swift:1504-1506`（`readML`） | **NSNumber 装箱**：每次读单元素都 `index.map { NSNumber(value: $0) }` 新建数组 + N 个 NSNumber | 仅**回退路径**触发（快速路径 `fastRowsStrided` 已覆盖生产 det 与 da/ll）。若回退命中 det：8400 框 × 5 次 × 每 tick | `det` 已改 `fastRowsStrided`（`:1165/1173`），da/ll 走 `isContiguous` 快速路径（`:1294`）。**当前生产路径基本不触发**，仅在 dtype 非 f16/f32 或 stride 异常时兜底 | 低（但优先级低，见 §4） |
| **5** | `Core/EngineMain.swift:378-381` | **每检测框每帧小分配**：`Array(d.rawName.utf8.prefix(15))` 每框建一个数组 | 每 tick × 检测框数（`det` 列实测常见 0；驾驶中按 ≤20 估 → **≤20 次小分配/帧 ≈ 300 次/秒**） | `publish` 在 `for i in 0..<n` 内无条件构造（`:378`）。空转 `det=0` 时无成本，故只算驾驶态 | 低 |
| **6** | `App/AuroraDriveApp.swift:7306`（门控）+ `runOpticalFlow`（`:6802`） | **白算（档位门已修，保留核对项）**：光流每帧转换+解算 | `.legacy` 档 p50 **0.228 ms/帧**（实测 `05-性能与优化全史.md:130`）；`.ayolom` 档 **n=0 已不跑** | 已被 `perceptionMode.needsOpticalFlow` 门控（`AuroraDriveApp.swift:7306`），实测 n=0。**本项已修好，仅作基线记录，不重复记账** | — |

> 说明：#6 与 `4-idle-waste.md`、`3-compute-units.md` 均不重复；列出是为了说明「为什么 A 档很闲、不该再优化光流」。

---

## 3. 按「收益 ÷ 风险」排序的前 5 项

### ① 【收益最大】让 `publish` 在「没有新帧」时不发布 —— 斩断整条 15Hz 空搬链

- **改什么**：`EngineMain.tickOnce`（`EngineMain.swift:1425-1431`）取帧时记录「是否真的换了帧」。判据用现成的幂等事实：`captureEngine.capturedFrameCount`（`CaptureEngine.swift:1092` 每次帧回调自增）未变 → 说明本 tick 没有新画面 → **跳过 `publish`**（连 `seq` 自增一起跳过）。
  - 等价性：`publish` 的语义是「发布一帧**成品画面**」。没有新画面时重复发布同一份内容，对下游是无信息的（UI 侧 `poll()` 拿到的是与上次逐字节相同的图）。
  - 保守做法（推荐先落这个）：保留 `publish` 但仍然只在 `capturedFrameCount` 变化时调用；`isDriving`/`isStreaming`/检测区头部字段仍可在「内容真的变了」时补发（这些字段本身也只在状态变化时才变）。
- **预期省多少**：引擎侧 **-8.57 MiB/s 写 + 15 次/秒整帧 memcpy**；UI 侧连带 **-8.57 MiB/s 读 + 15 次/秒 `Data` 分配 + 15 个/秒 CGImage 重建 + 15 次/秒 WindowServer 提交**（`layer.contents` 赋值是最贵的一环，`05-性能与优化全史.md` 记录过 `layer.contents` 赋值曾让 tick 阻塞数十~几百 ms，`AuroraDriveApp.swift:7136-7146`）。空转/暂停时这部分**接近全免**。
- **质量影响**：**零质量影响**。不降频、不降分辨率、不降模型精度、不砍功能 —— 画面内容一字节不变，只是不再重发同一张图。反而**减少** UI 侧每帧重建 CGImage 的抖动。
- **风险点与护栏**：若某帧 `capturedFrameCount` 不变但 `currentFrameCG` 变了（理论上不发生：两者同源 `onFrame` 回调，`AuroraDriveApp.swift:6100-6105`），会延迟一帧显示。护栏：改为「帧计数不变 **且** `publish` 头部状态字段全未变」才跳过；或加 `AURORA_PUBLISH_DEDUP=0` 一行回退。

### ② 【收益大、改动最小】掩码：指纹变了才重写（让代码回到它自己注释承诺的语义）

- **改什么**：`EngineMain.swift:1473-1483` —— 把 `publishMasks(...)` 整段挪进 `if fp != EngineGlobals.lastMaskFingerprint { ... }` 的**花括号内**。
  - 注意顺序：`storeU64(80, seq)` 等头部字段本来就在 `publishMasks` 里，挪进去后 `maskSeq` 与数据仍是同一次原子更新，UI 侧 `maskSeq` 判据（`EngineClient.swift:751`）语义不变。
- **预期省多少**：每 tick 省 **6400 B 清零 + 2×25600 次比较**（估算：15Hz 下 **96 KB/s 写**、每秒 **76.8 万次**元素比较）。驾驶中 YOLOPX 是 15Hz、tick 也是 15Hz，指纹不变的比例取决于画面；`sample` 里 `writeMask` 有 **96 采样**说明它不是纯噪声。
- **质量影响**：**零质量影响**。掩码内容（0/1 位图）一模一样，只是不重复写相同位。UI 侧本来就只按 `maskSeq` 变化解析（`:751`），不解析时行为不变。
- **风险点**：指纹是「前景格数 + 尺寸」的哈希（`:1471`），理论上存在「格数不变但形状变了」的极窄漏判窗口。该代码注释已自认此局限（`:1462-1464`），且漏判**下一帧必然补上**。**这一点必须如实告知用户：它不是零概率，但被现有设计接受。**

### ③ 【中等收益】`poll()` 增加「内容真没变就不重建 CGImage」的兜底门

- **改什么**：`EngineClient.swift:645-688`。即使 #1 没做，也可在 UI 侧对 `seq` 之外再校验一次：记录已消费的 `(activePage, w, h, publishedSeq)`，若与上次完全一致则直接返回 `frameCache`，不 `Data(bytes:)`、不建 CGImage。这对「引擎是旧版/未升级」的情况也有效（UI 单边升级即可受益）。
- **预期省多少**：每帧 **585.0 KiB 拷贝 + 1 次 `Data` 分配 + 1 个 CGImage 构造**，空转态 **≈100% 免掉**（15Hz × 3 项）。
- **质量影响**：**零质量影响**（返回的就是同一份缓存图，逐字节相同）。
- **风险点**：需确认 `frameHost.push` 不会因为「没被调用」而清空画面 —— 实际不会，`layer.contents` 保持上一份内容（`AuroraDriveApp.swift:8984-8987` 只赋值，不清空）。此项与 #1 有部分重叠，**做完 #1 后本项收益折旧**，建议作为 #1 的过渡方案或 UI 单边兜底。

### ④ 【小收益、顺手】`publish` 检测区：`rawName` 的 16 字节写入不再每框构造数组

- **改什么**：`EngineMain.swift:378-381`。当前先 `Array(d.rawName.utf8.prefix(15))` 建数组，再逐字节写。改为直接对 `d.rawName.utf8` 的临时 buffer 逐字节写（`withContiguousStorageIfAvailable`），或复用一块固定的 16 字节栈缓冲。
- **预期省多少**：每框 **1 次堆分配**（≤15 B）。驾驶中按 20 框/帧 × 15Hz 估 ≈ **300 次/秒小分配**（估算）。属小数点后收益。
- **质量影响**：**零质量影响**（写的字节完全一致）。
- **建议**：收益小，**建议与 #1 一起改时顺手做，不单独立项**。

### ⑤ 【不建议动】`readML` 的 NSNumber 装箱

- **为什么排最后**：它确实符合用户点名的「NSNumber 装箱」形态（`YolopxEngine.swift:1505` 每次 `index.map { NSNumber(value:) }`），但**当前生产路径几乎不触发** —— det 走 `fastRowsStrided`（`:1165`）、da/ll 走 `isContiguous` 快速路径（`:1294`）。只有 dtype 非 f16/f32 或 stride 异常时才落回 `readML`。
- **结论**：**列为「已识别但无需动」**。真正该记的是：**若将来换模型导出导致 dtype 变化，这里会静默退化**（`：1296-1306` 已有同类教训记录）。建议加一个**只在 `AURORA_PERF=1` 下的计数**，而不是改热路径。

---

## 4. 明确排除的方向（附证据）

| 方向 | 排除理由与证据 |
|---|---|
| **CGDataProvider 直指共享内存零拷贝**（`EngineClient.swift:664-672`） | 项目已评估并否决：缩略帧 585KB memcpy ≈ **15µs/帧**，15Hz 折算**单核 0.02%**，属噪声级；却要引入「UI 持 mmap 指针期间引擎翻页覆写」的撕裂风险。**本报告同意该结论，不重提。** 我的 #1/#2 与它不同：那是**让拷贝根本不发生**，不是把拷贝变零拷贝。 |
| **光流降频/砍掉** | `.ayolom` 档已 n=0（实测）；`.legacy` 档光流是核心组件。且已由 `needsOpticalFlow` 门控。**不重复记账**（详见 `4-idle-waste.md` / `3-compute-units.md`）。 |
| **letterbox 从 CGContext 改 vImage** | 已实测否决：10.540 → 2.309ms 虽快 4.57×，但**检测框 9 → 6 个，精度回退**（`05-性能与优化全史.md:404`）。违反用户铁律。 |
| **YOLOPX `computeUnits` 改 `.cpuOnly`** | 已实测否决：62.8% 算子由 CoreML 内部派给 CPU（不受 `computeUnits` 控制），改 `.cpuOnly` 反而 548ms+（`05-性能与优化全史.md:211`）。 |
| **逐像素变化检测省 memcpy** | 已实测否决：全帧比对 **6.81 ms/帧**，为省 CPU 先花三成预算（`05-性能与优化全史.md:421`）。我的 #1 用的是**现成的帧计数**，零比对成本 —— 这是与它关键的区别。 |
| **抓屏分辨率/帧率下调** | 违反用户铁律（不降质量、不降频）。`captureResolution = nominal`、`Preset` 等官方语义均被否决（`:6.2` 表）。 |
| **V2 `preprocessImage` 每帧分配 230KB** | **已修**：改为预分配静态 buffer（`InferenceEngineV2.swift:3069-3071`，省 4.6 MB/s）。 |
| **V2 `historySnapshot` 无条件 5.4MB/帧** | **已修**：移到唯一消费点前（`InferenceEngineV2.swift:2094`、`:2358-2360`）。 |
| **`MLMultiArray(shape:)` 每帧新建** | **已确认复用**：`ensureBuffers()`（`InferenceEngineV2.swift:2533-2567`）懒建 7 块缓冲，`preprocessImage` 也复用（`:3088-3094`）。**不是浪费**。 |
| **`buildStateSnapshot` 的 JSON/NSNumber** | 只在 `status` 命令（按需）与 heartbeat（1Hz）触发，**不在 15Hz tick 热路径**。 |
| **`debugSummary` 每帧拼字符串** | 有 1 秒节流（`AuroraDriveApp.swift:8086 if nowLog.timeIntervalSince(lastTickLog) >= 1.0`），**1Hz 不是每帧**。整段字符串拼接只在该 `if` 内执行。 |
| **V2 输入装配的 `NSNumber(value:)`**（`InferenceEngineV2.swift:2545-2565` 等） | 在 `ensureBuffers()` 内**只执行一次**（`if xxx == nil` 守卫），不是每帧。 |
| **`processMemoryMB()` 的 `task_info` 系统调用** | 仅在 1Hz `debugSummary` 内调用（`AuroraDriveApp.swift:8106`），非 15Hz。 |
| **`extractMask` 的 O(640²) 逐像素** | 是真实成本（`sample` 465 采样，热点 #2），但它是**掩码生成的必要计算**，砍掉=砍功能（违反铁律）。属于「必须花的钱」，不在清理范围。 |
| **`positiveRatios` 平滑后重算占比** | 一度疑为「算了没人用」，查证后**有消费方**：降级判定 `:1107-1110` + 自检/诊断展示。**不是浪费**。 |

---

## 5. 需要但无法在只读条件下测的量（列给 Lead）

> 本会话 `ps`/`sample` 被沙箱拒绝、且审批已禁用，无法提权重试；当前 15 分钟负载 6.02（>4 门限），按纪律不做有负载测量。

| 项 | 为什么没测 | 建议怎么测 |
|---|---|---|
| **#1 让 publish 跳过空 tick 后，引擎/UI 各省多少 CPU** | 需 A/B 运行采样 | `scripts/build-lock.sh acquire "hotpath"` → 单次 ≤10s `sample` 对比两版；关注 engine 与 UI 的 `layer.contents`/`WindowServer` 落点 |
| **#2 掩码短路后 `writeMask` 的真实 CPU 占比** | `sample` 里 96 采样但无毫秒数 | 同上，或开 `AURORA_PERF=1` 在 `writeMask` 加 `PerfBus.measure` 后跑一次 120s `deep_capture.sh` |
| **空转态 `publish` 的真实 CPU 占比** | `4-idle-waste.md` 同样缺这个数（其 §5.4 已列为未测） | 同上；这是判断 #1 收益上限的唯一硬指标 |
| **`poll()` 重建 CGImage 的耗时分布** | 需插桩 | `PerfBus.measure("client.poll")` 包住 `EngineClient.swift:673-688` |
| **生产环境 `fullFrame` 分支是否被走到** | `wantFullFrame` 默认 `false`（`EngineMain.swift:640`），但无法确认用户当次是否开插帧 | 读日志 `[ENGINE] 画面档位切换` 行；若常开则 `publish` 每次搬 **21.4 MB**（2940×1912×4），#1 收益放大 **36×** |

> 补充给 Lead 的量级提醒：若用户**开着插帧**，`publish` 的 `fullFrame` 分支每 tick 逐行 memcpy **21.44 MB**（`:405-409`，`2940×1912×4` 换算），15Hz → **321.7 MB/s**。这会远超 #1 里按缩略帧算的 8.57 MiB/s。**建议 Lead 先确认用户是否开插帧**，再定 #1 的优先级与收益口径（本报告两种口径都给了）。

---

## 6. 给 Lead 的三句话

1. **最大白做**：`publish` 每 tick 无条件发帧（`EngineMain.swift:1431`），UI 每 tick 无条件重建 CGImage（`EngineClient.swift:673-688`）—— 同一张图 15Hz 搬两遍，空转也不停（日志实证 `seq` 15.0Hz / `driving=false` / `yolopx 帧数`冻结）。
2. **最便宜的一刀**：掩码 `publishMasks` 挪进指纹 `if`（`EngineMain.swift:1473-1483`）—— 一行缩进，代码回到它自己注释承诺的行为，零质量影响。
3. **建议顺序**：#1（publish 空帧跳过）→ #2（掩码短路）→ #3（UI 单边兜底）。#1 与 #3 有重叠，做完 #1 后 #3 只保留为「UI 单边升级也能受益」的兜底价值。

---

## 附：本报告引用的实测数据出处

| 数值 | 出处 |
|---|---|
| `seq` 每 15s +225（15.0Hz）、`yolopx 帧数=5814` 冻结 | `~/Library/Logs/AuroraEngine.log`，18:22:00–18:31:30 连续 38 行（本次取证） |
| 480×312 缩略帧尺寸 | `CaptureEngine.swift:1190-1195`（`maxWidth: CGFloat = 480` + 源 2940×1912 缩放换算） |
| `writeMask` 96 采样、`extractMask` 465 采样 | `docs/整合文档/05-性能与优化全史.md:236`（2026-10-11 `sample` 热点榜） |
| 光流 p50 0.228ms、`.ayolom` n=0 | `docs/整合文档/05-性能与优化全史.md:131`（2026-10-20 tick-bench 实测） |
| letterbox 精度回退否决、逐像素比对 6.81ms 否决 | `docs/整合文档/05-性能与优化全史.md:404`、`:421` |
| vImage 缩放 0.218/0.312ms、memcpy 整帧 0.053ms | `docs/整合文档/05-性能与优化全史.md:112-120` |
| `layer.contents` 赋值可能阻塞数十~几百 ms | `App/AuroraDriveApp.swift:7136-7146` 注释（2026-10-22 实测记录） |
