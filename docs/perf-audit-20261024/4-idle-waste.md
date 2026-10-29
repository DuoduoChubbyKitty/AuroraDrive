# 4 · 空转浪费审计（不依赖游戏内容的持续开销）

- 审计时间：2026-10-24 18:26–18:45
- 审计对象：`/Users/dupi/Desktop/自动驾驶系统`（AuroraDrive，Swift Package，UI 进程 + 引擎进程）
- 审计方式：**纯只读静态审计 + 现有运行日志取证**。未改代码、未 build、未启停 App。
- 用户铁律：不降质量 / 不降频 / 不降精度 / 不砍功能，**只清理纯浪费**。

---

## 1. 一句话结论

**不玩游戏时的持续开销，主因不是"定时器空转烧 CPU"（实测两个进程合计仅 0.2 核 / 8 核），而是「流水线在非驾驶态仍在按 15Hz 跑完整个 tick 闭环」——包括抓屏、共享内存发布、以及引擎进程里每 0.7s 一次的 Vision OCR（`.accurate`，单次 p50 33.6ms）。其中 OCR 那条是唯一有明确量化数字、且产物无人消费的纯浪费；其次是 `GameModeDefender` 在两个进程里各跑一份 3s 周期重主张、每次伴随 `getpriority`/`AudioQueueGetProperty` 等系统调用。**

补充关键判据：用户说"不跑游戏也掉帧"——从代码看，App 的 15Hz 流水线**不判断游戏是否在跑**，它只在 `isDriving`/`isRecording` 时降/升频。所以"游戏没开"时 App 仍以 15Hz 抓屏 + 15Hz 发布帧（日志实证见 §5.1）。这解释了为什么"游戏不跑也掉帧"：空转时它自己就在按 15Hz 干活。

---

## 2. 空转开销清单

> 频率列为代码事实；"空转仍执行"以**当前运行实况**（引擎进程 pid 32720 / UI 进程 pid 32689，`ui.lock`/`engine.lock`）为准。
> 成本列凡标「未测」即为本次未做实测，只做静态判断。

| 位置 (file:line) | 类型 | 频率 | 空转时仍执行 | 估算成本 | 修复难度 |
|---|---|---|---|---|---|
| `Core/EngineMain.swift:1242` engineTicker | 定时器 | **15Hz**，`leeway: .nanoseconds(0)`，`.userInteractive` | **是**（日志 seq 每 15s 精确 +225，见 §5.1） | tick 本身含 `st.tick()` + shm `publish`，具体 CPU 未测（既有实测：两进程空转合计 0.9%+0.4%） | 中 |
| `Core/EngineMain.swift:1263` engineHeartbeat | 定时器 | **1Hz**（leeway 50ms） | 是 | 含 socket 发 JSON 心跳；每 15s 额外写一行日志 | 低 |
| **`App/AuroraDriveApp.swift:7193-7194` → `Inference/QuestPanelReader.swift:541`** questPanel.ingest | **Vision OCR** | 逻辑上 **每 0.7s 一次**（`QuestPanelReader.swift:431 minInterval = 0.7`），`.accurate`，单次 **p50 33.6ms / p95 40.7ms**（该项目自带实测，非本次测量） | **是（仅引擎进程；UI 进程被早退挡住）。触发条件 = `currentFrameCG != nil`，即只要抓屏开着就跑，与是否驾驶无关** | 代码注释自述 **≈ 4.8% 单核**（33.6ms ÷ 700ms）。关键：引擎进程 `EngineClient.shared.isActive` **恒 false**，故 `!isActive` 门控**挡不住引擎进程**。⚠️ 引擎发的是 480 宽缩略帧，ROI 裁切后实际单次成本可能低于 33.6ms（未测） | **低** |
| `Core/GameModeDefender.swift:152` startReassertLoop | 定时器 | **3s**（leeway 200ms），`.userInteractive` | **是，两进程各一份**（`EngineMain.swift:1120` + `AuroraDriveApp.swift:236` 无条件 `start()`） | 每 3s 一次 `getpriority()` + `AudioQueueGetProperty()`；稳态只写日志于变化时（已优化过）。CPU 未测 | 低 |
| `App/MissionConsole.swift:6222` tickDispatchSource | 定时器 | 15Hz，**已做 idleSkip 降频 → 约 1.9Hz** | 是（但已降频） | 已优化，非本次重点 | — |
| `App/MissionConsole.swift:6298` netLocDispatchSource | 定时器 | 10Hz，**已做 idleSkip → 约 2Hz** | 是（但已降频） | 已优化 | — |
| `App/AuroraDriveApp.swift:5378` antiFreezeTimer | 定时器 | **不存在**——`startAntiFreeze()` 已改为空实现，仅 `dlog` 一行（`AuroraDriveApp.swift:6519`） | **否** | 0 | — |
| `Core/AuroraCache.swift:238` metricsTimer | 定时器 | 1s | **否**——`installMetricsTimerIfNeeded()` 首行 `guard PerfBus.enabled else { return }`（`AuroraCache.swift:237` 区域），仅 `AURORA_PERF=1` 时安装 | 0（生产） | — |
| `Core/EngineClient.swift:151` connectTimer | 定时器 | 0.3s / 0.5s | 仅在**断线/启动探测**时短时存在，连上即 cancel | 有界（6s/20s 上限） | — |
| `Core/EngineClient.swift:174` relaunchPoll | 定时器 | 0.4s | 仅在重启陈旧引擎时 | 有界 | — |
| `App/AuroraDriveApp.swift:9120` `while true`（Upscale drain） | 循环 | 事件驱动，队列空即退出（`isDraining=false` + return） | 否（无常驻空转） | 0 | — |
| `App/RouteGraph.swift:446` `while true` | 循环 | 堆下沉，单次寻路内 | 否 | 0 | — |
| `Agent/LLMTransport.swift:1501` `while true` | 循环 | SSE 流按字节消费，流结束即 break | 否（只在请求进行中） | 0 | — |
| `Agent/LLMHealth.swift:505` idleProbeTask | Task 循环 | **60s**（`probeInterval`），且需 `startAdaptiveProbing()` 被调用 | **否**——`startAdaptiveProbing()` 在 Sources 内**无任何调用方**（全仓库 grep 仅定义处 `LLMHealth.swift:502`） | 0（当前死代码路径） | — |
| `Agent/AIAgentPanel.swift:248-261` 8 个技能定时器 | 定时器 | 各技能私有周期 | **否**——均需用户点击技能才启动（`volleyballTimer`/`touchTimer`/`pianoTimer`/`coffeeTimer`/`coffeeLiteTimer`/`bagelSpamTimer`/`tomatoTimer`/`driveDatasetTimer`），并有 `runningSkills` 门 | 0（未触发时） | — |
| `Agent/AIAgentPanel.swift:729` loginWatchTimer | 定时器 | 8s | 否——`startLoginWatch` 仅在自动登录技能点不动时启动，80s 上限 | 有界 | — |
| `Agent/WebSearch.swift:495` `Task.sleep` | 循环 | 请求超时兜底 | 否（仅在搜索请求中） | 0 | — |
| `Core/EngineMain.swift:78` engineLog | 日志 | 每次调用 open→seek→write→close；**每次新建 `DateFormatter`**（`:104-107`） | 是（热路径上有调用，如 `:796`、`:1453` 附近） | 单次含 1 次 `DateFormatter` 构造 + 1 次 `FileHandle(forWritingAtPath:)` open/close。**空转时调用点少**，但热路径每次都是完整文件 I/O | 低 |
| `Core/EngineClient.swift:25` engineClientLog | 日志 | 同上，**无节流/无轮转检查**（引擎侧有 `engineLogCheckEvery`，客户端侧没有） | 低（仅连接事件） | 单次 `DateFormatter` + open/close | 低 |
| `Core/GameModeDefender.swift:65` log | 日志 | 状态变化时 | 是（变化时） | 每行含 `attributesOfItem` stat（**每次写前都 stat，无节流**）+ `DateFormatter` | 低 |
| `App/AuroraDriveApp.swift:4909` dlog | 日志 | 事件驱动 | 部分（如 `:6202` 启动一条） | 有 `dlogResolvedPath` 缓存，但仍每次 `Date().formatted` + 写文件 | 低 |
| `App/App/AuroraTheme.swift:643` `AuroraLightField` blur(60) | UI 重绘 | 依赖父视图刷新 | **是，但动画已关**（`:684` 漂移仅在 `AURORA_ENABLE_BG_DRIFT=1` 时开，默认静止） | 静止时 blur 结果可被 CA 缓存；**若父视图每 15Hz 重算则每帧失效**（见 §4） | 中 |
| `App/MissionConsole.swift:194` BrandMark `spin` 无限动画 | UI 重绘 | `repeatForever` | 是（顶栏出现即跑） | **死状态**：`spin` 启动了动画但**没有任何视图读它**（`BrandMark` body 里无 `rotationEffect`/`spin` 引用）。产生动画事务但无视觉输出 | 极低 |

---

## 3. Top 5「收益 ÷ 风险」排序

### ① 引擎进程的 Vision OCR：每 0.7s 一次 `.accurate`，产物无人接收 —— 零风险、收益最大

- **改什么**：`App/AuroraDriveApp.swift:7193`
  ```swift
  if AuroraFlags.questOCR, !EngineClient.shared.isActive, let cg = currentFrameCG {
      questPanel.ingest(cgImage: cg)
  }
  ```
  把门控条件补上"当前是本进程是不是引擎进程"的判据（例如与 `EngineMain` 同源的 `--engine` 参数判断，或直接在引擎侧的 `tickOnce` 里不调用 `st.tick()` 的 UI 专属段）。
- **为什么现在挡不住**：`EngineClient.startup()` 全仓库**只在 `AuroraDriveApp.swift:217` 被调用**（UI 进程启动路径）。引擎进程从不调用它，`isActive` 恒为 `false`（初值 `EngineClient.swift:68`）。所以 `!isActive` 对引擎进程**恒真** → OCR 照跑。
- **产物去哪了**：`questPanel.onConfirmed` 只写**本进程**的 `questName`/`locatorTarget`；而引擎→UI 的 heartbeat（`EngineMain.swift:2144`）字段清单里**不含 quest\***。即引擎算出来的任务文本 UI 永远收不到。
- **预期收益**：代码注释自述约 **4.8% 单核**（33.6ms ÷ 700ms）；且这是**连续 CPU 占用**，会参与 nice=-20 的抢占。⚠️ 该 4.8% 是项目注释里的旧测算，基于全分辨率帧；引擎空闲时走的是 **480 宽缩略帧**（`AuroraEngine.log:18:03:15` "画面档位切换：480 宽缩略"），ROI 裁切后 Vision 输入更小，**真实单人成本可能显著低于 33.6ms（本次未测）**——但"产物无人消费"这一点与成本大小无关，仍属纯浪费。
- **质量影响：零**。UI 进程在引擎模式下本来就走 `tickEngineMode(); return` 早退，不跑这段；引擎进程的 OCR 结果无人消费。两边行为不变。

### ② `GameModeDefender` 在两个进程各跑一份 3s 重主张 —— 低风险

- **改什么**：`Core/GameModeDefender.swift:152`，评估是否只需在**一个**进程保留（UI 侧窗口存在性对 gamepolicyd 更有效，见 `AuroraDriveApp.swift:238-241` 注释），或把 3s 放宽到更长（当前 root 脚本已每 5s 强制 `renice -n -20`，`nice` 重主张实为重复劳动）。
- **预期收益**：每进程少 1/3 Hz 的 `.userInteractive` 唤醒 + 3 次系统调用/次。CPU 量级小但属**常驻连续**唤醒。
- **质量影响：零**。nice 由 root 脚本兜底；activity token 与静音音频在单进程保留即可满足"有可见窗口"语义（需实测复核 gamepolicyd 行为，**这一条建议改前先 A/B**）。

### ③ BrandMark 的无限动画是死状态 —— 几乎零风险

- **改什么**：删掉 `App/MissionConsole.swift:193-195` 的 `.onAppear { withAnimation(...repeatForever...) { spin = true } }`，以及 `:177` 的 `@State private var spin = false`。
- **证据**：`BrandMark` body（`:179-198`）只在 `:194` 写 `spin`，**全文无任何 `.rotationEffect(.degrees(spin))` 或其它读取**。即动画在跑、无任何视图消费。
- **预期收益**：消掉一条常驻的 `repeatForever` 动画事务（顶栏常驻）。量级小，但属纯浪费且修复成本极低。
- **质量影响：零**（视觉输出逐像素不变，因为本来没有输出）。

### ④ `engineLog` / `engineClientLog` 的热路径文件 I/O —— 低风险

- **改什么**：`Core/EngineMain.swift:78-102` 与 `Core/EngineClient.swift:25-40`：
  - `DateFormatter` 每次 new（`:104-107`）→ 提为 `static let`（格式化器线程安全性需注意，但这两种日志都在单一串行上下文）。
  - 每次 `FileHandle(forWritingAtPath:)` open + `seekToEndOfFile` + `write` + `closeFile` → 改为长持有句柄。
- **预期收益**：单次日志成本从"open/close 两次系统调用 + formatter 构造"降到"一次 write"。当前空转时调用点不多（15s 一条统计），**收益主要是流水线跑起来后**（热路径有日志调用点）。
- **质量影响：零**（日志内容一字不变）。
- **注意**：`engineClientLog` **没有** `engineLog` 那种"每 64 次 stat 一次"的轮转节流，也无大小上限——长期运行会无限增长（这是可靠性问题，不是 CPU 问题）。

### ⑤ 15Hz tick 在非驾驶态仍全速跑（抓屏 + shm publish）—— 中风险，建议单独评估

- **改什么**：`Core/EngineMain.swift:1242` 的 tick 与 `tickOnce`（`:1369`）。当前**只在 `isDriving`/`isRecording` 时**调频（`EmergencyTakeover`），没有"非驾驶 → 降频"档。
- **证据**：`AuroraEngine.log` 18:03:15–18:08:15 段（driving=false，有帧=false）`seq` 仍每 15s 精确 +225 = **15Hz 从未降**。
- **预期收益**：潜在最大，但**收益量未测**（需 ABBA 实测空转 tick 的真实 CPU 占比）。既有实测"空转两进程 0.9%+0.4%"暗示单纯 tick 空转并不贵——**贵的可能是抓屏链路与 shm 的 480 宽帧拷贝**。
- **质量影响：需评估**。降频会改变"未驾驶时预览画面的刷新率"，属产品行为。按用户铁律「不降频」，**这一条默认不应做**，除非能证明"非驾驶时根本没有消费者"。建议列入下一轮 ABBA 实测再定，不要盲改。

---

## 4. 特别点名：有没有「SwiftUI 每帧重绘」

**结论：没有找到"未做防护的每帧 @Observable 写"；相反，代码里已有大量「先比后写」防护。但存在一条**结构性风险**尚未排除。**

### 4.1 已确认被防住的部分（不是每帧重绘）

`tickEngineMode()`（`App/AuroraDriveApp.swift:6663`）是 UI 进程在引擎模式下的每 tick 路径，逐项核对：
- `engineModeActive`/`engineConnected`（`:6665-6666`）：先比后写 ✅
- `isStreaming`（`:6680`、`:6692`）：`if !isStreaming` 先比后写 ✅
- `screenSize`（`:6686`、`:6694`）：`if screenSize != sz` ✅
- `remoteDetections`（`:6697`）：值比较 ✅
- `mode`/`confidence`/`remoteSpeedKmh`/`effectiveSpeed`/`speedValid`/`isDriving`/`fps`（`:6737-6762`）：**全部**先比后写，其中 `fps` 处还有 2026-10-22 专门修复注释（`:6747-6760`）说明"原先每秒 14 次写同一 Double" ✅

`DriveState.tick()` 开头（`:7022-7026`）：
- `tickGapMs` 每 tick **无条件写**，但它是 **`@ObservationIgnored`**（`:5558`），不触发 SwiftUI ✅
- `lastTickTime` 同为 `@ObservationIgnored`（`:5556`）✅

`frameHost`/`currentFrameCG`/`currentScreenImage` 均 `@ObservationIgnored`（`:5192-5194`、`:5194`），画面走 `layer.contents` 直绘绕开 body diff ✅

`PerfBus`：`enabled == false`（生产默认）时 `stamp()`/`mark()`/`lap()` 内联后等价于一条 bool 分支（`App/PerfSelfTest.swift:192-212`）✅

### 4.2 结构性风险（需下一轮实测确认）

`AuroraLightField`（`App/AuroraTheme.swift:589`）**直接内嵌在 `ViewportPanel`**（`MissionConsole.swift:598`），而 `ViewportPanel` 持 `@Bindable var state: DriveState`。

一旦 tick 写了**任意**被 `ViewportPanel.body` 读取的 `@Observable` 属性，`ViewportPanel` 的 body 就会重算 → 内部 `AuroraLightField`（3 个 blob + `.blur(radius: 60)`）一并重算。

- **已做的缓解**：背景漂移动画已关闭（`:684-686`，仅 `AURORA_ENABLE_BG_DRIFT=1` 时开）→ 静止时 blur 结果可被 Core Animation 缓存。
- **未排除的点**：缓存是否因父视图 body 重算而失效，取决于 SwiftUI 是否复用同一 `View` identity。静态审计**无法判定**，必须在真实 UI 上采样（`sample <pid>` 看主线程是否落在 `CA::Transaction::commit` / `RenderState::RootTexture::make_texture`，即本项目 2026-09-28 那次事故的同一判据，见 `AuroraTheme.swift:624-631`）。
- **判定方式（建议交给能实测的人）**：空闲态（不驾驶、不开游戏）对 UI 进程做 3s 1ms 采样，统计主线程样本落点。若大量落在 CA/Render server → 确有每帧重绘；若落在 idle/`__psynch_cvwait` → 该风险不成立。

**另外**：`BrandMark`（`:194`）确认存在一条"启动了无限动画但无任何视觉消费"的死代码（见 §3③）——**这是全项目唯一确认的 `repeatForever` 空转**，但因为它不改变任何可观察属性、也没有视觉输出，推测不产生持续重合成（未实测）。

---

## 5. 证据附录

### 5.1 「非驾驶态仍按 15Hz 跑完整 tick」——日志实证

`~/Library/Logs/AuroraEngine.log`（`SelfTimestamp` 每 15s 一条，`heartbeatCount % 15 == 0`，`EngineMain.swift:1284`）：

```
[18:07:00.458] [ENGINE] 统计: seq=3372 有帧=false driving=false ... 帧数=0
[18:07:15.458] [ENGINE] 统计: seq=3597 有帧=false driving=false ... 帧数=0
[18:07:30.458] [ENGINE] 统计: seq=3822 有帧=false driving=false ... 帧数=0
```

- 每 15 秒 `seq` 增量：3597−3372 = **225**，3822−3597 = **225** → **精确 15.0 Hz**。
- 此段 `driving=false`、`有帧=false` → 即"什么都没在跑"时，tick 频率**没有任何下降**。
- 对照：18:08:27 收到 `start` 命令后 `有帧=true driving=true`（日志 `:81`），说明抓屏是"点开始后才开"；但 **tick 从不因空闲而降频**。

**更强的一段（审计期间实时观测，18:32–18:33）：**

```
[18:32:45.445] [ENGINE] 统计: seq=27229 有帧=true det=0 driving=false yolopx:加载=true 帧数=5814 ...
[18:33:00.446] [ENGINE] 统计: seq=27454 有帧=true det=0 driving=false yolopx:加载=true 帧数=5814 ...
[18:33:15.451] [ENGINE] 统计: seq=27679 有帧=true det=0 driving=false yolopx:加载=true 帧数=5814 ...
```

- `driving=false`（没开车）但 `有帧=true` → **抓屏在跑**；
- `帧数=5814` 从 18:18 到 18:33 **十五分钟一动不动** → **推理早就停了**（5814 是它最后一次推理的累计值）。
- ⟹ 空闲态的真实形态：**抓屏 15fps + shm publish 15Hz + 推理 0**。抓屏与发布这两条**不判断游戏是否在跑**，这正是"不玩也卡"的机制层解释。

### 5.2 「OCR 门控挡不住引擎进程」——静态证据

- `EngineClient.startup()` 调用点全仓库仅 **1 处**：`Sources/AuroraDrive/App/AuroraDriveApp.swift:217`（UI 进程 `applicationDidFinishLaunching` 路径）。
- `EngineClient.isActive` 是 `private(set) var isActive = false`（`Core/EngineClient.swift:68`），只在 `activate()`（`:223`）置 true；`activate()` 调用点为 `:208`、`:620`，都在 `EngineClient` 自身内部且由 `startup()`/重连路径触发。
- `Sources/AuroraDrive/Core/EngineMain.swift` 中 **不含** 任何 `EngineClient.shared.startup()` 调用（grep 结果只有注释提及）。
- ⟹ 引擎进程 `isActive == false` 恒成立 ⟹ `AuroraDriveApp.swift:7193` 的 `!EngineClient.shared.isActive` 对引擎进程恒真。
- OCR 单次成本来源（项目自带实测注释）：`Inference/QuestPanelReader.swift:524-526`，`.accurate` p50 **33.6ms**、`.fast` 完全读不出中文（故不能降级 → 只能门控，符合用户"不降精度"铁律）。

### 5.3 本研究**测过但未采用**的项（避免重复劳动）

- `PerfBus` 关闭时成本：已读源码确认 `@inline(__always)` + bool guard（`App/PerfSelfTest.swift:192-212`），**零开销**，不必再测。
- `AuroraCache.metricsTimer`：`guard PerfBus.enabled else { return }` 在安装处，生产不装，**排除**。
- `antiFreezeTimer`：`startAntiFreeze()` 已改为空实现，**排除**。
- `AuroraLightField` 漂移动画：已移除，仅 `AURORA_ENABLE_BG_DRIFT=1` 可开，**排除**。
- `LLMHealth.startAdaptiveProbing()`：**在 Sources 内无调用方**，当前不跑，**排除**（但属死代码，可另行清理）。
- 地图 `MapTileImage`：已做预裁切 + `MapTileCache` + 按视口缓存（`MissionConsole.swift:2935-2948` 有明确注释与量化：像素量从 1.7 亿降到几万），**排除**。区域名反查也已改为低频刷新+缓存（`AuroraDriveApp.swift:5215` 起）。

### 5.4 本次**未测**、无法出结论的项（诚实标注）

| 项 | 为什么没测 | 建议 |
|---|---|---|
| 15Hz tick + shm publish 的真实 CPU 占比 | 需 `sample`/`ps` 进程采样；`ps` 被沙箱拒绝（`/bin/ps: Operation not permitted`），本会话审批已禁用无法提权重试 | 交给有 `ps`/`sample` 权限的人；或按 `scripts/build-lock.sh acquire "idle"` 规则单次 ≤10s 采样（当前 load 3.43 偏低，可测） |
| `AuroraLightField` 是否构成每帧重合成 | 需真实 UI 主线程采样，纯静态无法判定 | 同上，空闲态 `sample UI_PID 3 1` 看主线程落点 |
| 抓屏链路（SCStream @15fps + 480 宽帧拷贝）成本 | 同上 | 同上 |
| `GameModeDefender.reassert` 的系统调用真实耗时 | 未测（3 次 syscall/3s，量级推测极小） | 可忽略，或与 §3② 一起 A/B |

> 说明：`ps` 不可用是本次的硬限制。既有事实「空闲时 GUI 0.4% + 引擎 0.9%（合计 0.2 核/8 核）」已由 Lead 提供，本报告直接引用，未重复测量。

---

## 6. 明确排除的方向（附证据）

| 方向 | 排除理由与证据 |
|---|---|
| **"空转烧 CPU"** | 既有实测：空闲合计 0.2 核 / 8 核（Lead 已测）。本报告不重复。 |
| **定时器自身空转** | 逐个核对 6 个已知定时器 + 8 个 Agent 定时器：`antiFreeze` 空实现、`metricsTimer` 生产不装、`connectTimer`/`relaunchPoll` 有界、7 个技能定时器需点击启动、`loginWatch` 80s 上限、`idleProbeTask` 无调用方。真正无条件下跑满的只有 **engineTicker(15Hz)** 和 **heartbeat(1Hz)**。 |
| **`while true` 死循环** | 共 3 处，全部有限：`AuroraDriveApp.swift:9120` 队列空即 return；`RouteGraph.swift:446` 堆下沉循环；`LLMTransport.swift:1501` SSE 读流到 EOF 即 break。 |
| **JSON 编解码在热路径** | `JSONSerialization` 仅出现在：`EngineMain.swift:1556`（socket 命令发送）、`:1711`（命令解析）、`EngineClient.swift:429`（心跳解析，1Hz）、`:875`（命令发送）。**均不在 15Hz tick 热路径上**。 |
| **`Data(contentsOf:)` / `FileManager` 目录扫描** | `AuroraDriveApp.swift:1484` 一处，非热路径。地图/标记 JSON 均在 `.onAppear` 一次性 `ensureLoaded()`（`MissionConsole.swift:6151-6155`）。热路径无目录枚举。 |
| **Agent/LLM 心跳轮询** | `LLMHealth.startAdaptiveProbing()` 无调用方；`WebSearch`/`LLMTransport` 循环只在请求期内；`AgentLoop` 的 `while` 是步数上限循环（`:218`、`:475`）。**空转不跑**。 |
| **背景光斑无限漂移** | 已于 2026-09-30 移除（`AuroraTheme.swift:645-680` 有完整实测记录：WindowServer 81.9%→51.9%，单因子对照确认）。现仅 `AURORA_ENABLE_BG_DRIFT=1` 可开。 |
| **2048×2048 级图像匹配每帧重算** | 地图瓦片走 `MapTileCache` 预裁切+视野缓存（`MissionConsole.swift:2935`），且**只在 `locatorFound` 为真时绘制**（`:1969`）。非驾驶/未定位时不跑。区域名反查已加格缓存 + 低频刷新（`AuroraDriveApp.swift:5215+`）。 |
| **`gameHUD` 自身刷新** | 0.5s 一次 `Timer`（`GameHUDWindow.swift:97`），只改 `NSTextField.string`，非 SwiftUI 状态；2Hz 频率可接受。 |
| **`tickGapMs` 每帧写导致重绘** | 它是 `@ObservationIgnored`（`AuroraDriveApp.swift:5558`），不参与观察。 |
| **`frames` 每 tick 写** | `frames` 只在心跳/录制路径写（`:6762` 先比后写、`:7324`、`:8232`），非每 tick 无条件下。 |

---

## 7. 交付物与后续

- 本文件：`docs/perf-audit-20261024/4-idle-waste.md`
- 尚未产出：ABBA 实测数据（受 `ps`/`sample` 权限限制，见 §5.4）。
- 建议下一步（按优先级）：
  1. 采信 §3① 的门控缺口，**先做一次性验证**（本审计已给出两条例证，但都只能证"产物无人消费"，不能证"当前确切在跑多少次"）：
     - 最直接：空闲态 `sample <引擎PID> 3 1`，看 `VNRecognizeTextRequest` / Vision 是否出现在主线程或 `aurora.quest.ocr` 队列的堆栈里。
     - 辅助：引擎进程内 `questPanel` 是独立实例（`EngineMain` 里 `DriveState` 也是独立实例），`ocrRuns` 计数**无任何外部读取方**（全仓库 grep 只有 `QuestPanelReader.swift` 自身），所以从现有日志**读不出 OCR 次数** —— 不要指望 `[QUEST-OCR]` 那条 dlog，它**只在"确认到任务"时才打印**（`AuroraDriveApp.swift:6086-6091`），静默运行时不产生日志。这是本次审计确认的一个观测盲区，建议顺手补一个低频计数日志。
  2. 空闲态 `sample` UI 进程 3s，判定 §4.2 的 `AuroraLightField` 结构性风险。
  3. `GameModeDefender` 单进程化需 A/B（涉及 gamepolicyd 行为，不宜凭静态代码结论直接改）。
  4. 空闲态抓屏（`有帧=true driving=false`）是否该停：这是**潜在最大的一项**，但属产品行为变更（不驾驶时预览面板会静止），按用户铁律「不砍功能」**不建议直接做**，需先与用户确认"不驾驶时预览是否需要实时画面"。
