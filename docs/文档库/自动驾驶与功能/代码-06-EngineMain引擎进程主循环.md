# 代码-06 EngineMain 引擎进程主循环
> 覆盖源文件：`Sources/AuroraDrive/Core/EngineMain.swift`（当前版本全文件）。基于当前仓库逐单元编写。
>
> ✅ **2026-11-25 去行号化复核**：全文行号引用已全部替换为源码真实符号名（`EngineFrameShm`、`EngineSocketServer`、`EngineGlobals`、`EngineMain.run()`、`tickOnce()`、`handleCommand(_:server:)`、`sendHeartbeat(reason:)`、`pauseDriving(_:)`、`performShutdown(reason:)` 等）。同时按当前源码修正了多处过期数值：
> 1. **tick 频率为 15Hz**（`static var engineTickHz: Double = 15.0`，且 `tickHz(forPerceptionMode:)` 两档均返回 15Hz）——原文「30Hz DispatchSource tick」是旧口径。应急态由 `EmergencyTakeover.effectiveTickHz` 动态改频（15 巡航 / 20 冲刺 / 5 让位）。
> 2. **管道统计日志为每 15 秒一条**（`heartbeatCount % 15 == 0`，2026-10-22 从 5 秒改 15 秒：统计行曾占 AuroraEngine.log 的 70%）。统计行现含 yolopx 加载/帧数/掩码格数/降级态/单帧耗时/`skippedPublishTicks`/V3 risk 观测值。
> 3. **命令已扩展为 13 种**（`handleCommand` 的 `switch type`）：`start` / `drive_lease` / `stop` / `bye` / `status` / `upscale` / `record` / `reloadmodel` / `config` / `set_capture_mode`（别名 `capture`）/ `state` / `ping` / default——原文「九种」为旧口径。
> 4. **心跳字段扩展**：`sendHeartbeat(reason:)` 现含 `takeover` / `userHolding`（ET-9 应急接管回传）、`driveDiagnostic` / `speedValid` / `needsManualIntervention` / `isCapturing` / `captureFrames` / `hasFrame` / `lastModeError`（抓屏健康回传），并有手写 JSON 解析失败时的最小心跳兜底。
> 5. **引擎日志轮转**：`engineLog(_:)` 新增 `engineLogMaxBytes`（8MB）单备份轮转（`engineLogRotateIfNeeded(path:)`，每 `engineLogCheckEvery = 64` 次写入 stat 一次，超限挪 `.1`）。
> 6. **`writeMask` 已改连续位打包**（2026-10-14 性能优化，16× 加速）：`grid.cells.withUnsafeBufferPointer` 直接打包替代逐格 `grid.at()` RMW。
> 7. **无新帧短路**（2026-10-24）：`tickOnce()` 以 `EngineGlobals.lastPublishedCaptureCount` 等判据跳过重发陈帧，`skippedPublishTicks` 进日志。
> 8. **观测模式**：`AURORA_OBSERVE_ONLY=1`（`AuroraFlags.observeOnly`）下 TCC 判据收窄为仅 screen（该模式不注入按键）。
>
> ---
>
> ## ⚠️ v3 掩码发布（2026-09-27/28 新增，仍有效）
>
> ### 一、shm 掩码区（`EngineFrameShm` 常量）
>
> ```swift
> static let detEnd = detOffset + detCapacity * detStride          // 4096 + 256×64 = 20480
> static let maskOffset = detEnd                                   // 20480
> static let maskGridMax = 160
> static let maskBytes = maskGridMax * ((maskGridMax + 7) / 8)     // 3200
> static let maskRegionBytes = maskBytes * 2                       // 6400（可行驶区 + 车道线）
> static let pixelsOffset = ((maskOffset + maskRegionBytes) + 4095) / 4096 * 4096  // 28672
> ```
>
> ⚠️ **`pixelsOffset` 由 20480 后移到 28672 —— 这是 shm 布局变更**，也是 `protocolVersion` 升到 3 的直接原因（旧 UI 会把掩码区当像素读 → 花屏）。详见 `代码-07`。
>
> ### 二、`writeMask(_ grid: MaskGrid, offset: Int)` —— 位压缩写入
>
> ```swift
> private func writeMask(_ grid: MaskGrid, offset: Int) {
>     guard grid.width > 0, grid.height > 0 else { return }
>     let rows = min(grid.height, EngineFrameShm.maskGridMax)
>     let cols = min(grid.width, EngineFrameShm.maskGridMax)
>     let bytesPerRow = (cols + 7) / 8
>     let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
>     ptr.initialize(repeating: 0, count: rows * bytesPerRow)   // ★先清零
>     grid.cells.withUnsafeBufferPointer { buf in /* 连续位打包 */ }
> }
> ```
>
> **三个设计点**：
> 1. **写前先清零**——源码注释：「避免上一帧的残留位被读成前景」。若省略，缩小的掩码会留下上一帧的旧位
> 2. **`bytesPerRow = (cols + 7) / 8`**——按**每行**独立位对齐。UI 侧 `readMask` 必须严格对称（`代码-07`）
> 3. **连续打包等价性**（2026-10-14 改动的注释）：`MaskGrid` 合成构造器不校验 `cells.count == width*height`，原 `at()` 对越界格返回 false，故逐行按可用长度截断（`rowStart >= avail` 时 break），不能整段 return
>
> **为何位压缩**（`writeMask` 声明注释）：160×160 用 UInt8 存是 25600 字节/份，两份 50KB；位压缩后 3200 字节/份、两份 6.4KB，一个 bit 就够（掩码只有 0/1 信息）。
>
> ### 三、`publishMasks(drivable:lane:metrics:isDegraded:laneDegraded:drivableDegraded:seq:)`
>
> 由 `tickOnce()` 在每 tick 调用（实际有指纹短路，见第五节）。**写入字段（偏移 → 内容）**：80 `seq`；88/92 drivable.width/height；96/100 lane.width/height；104 flags；108 `Float(metrics.ratio)`；112/116 padX/padY；120/124 srcW/srcH；**128/132 newW/newH**（letterbox 内容区，2026-09-28 补传，原为客户端硬填 0 → `MaskOverlay` 守卫恒假、引擎模式下一格不画的 bug）。
>
> 随后两次 `writeMask`：可行驶区 → `maskOffset`，车道线 → `maskOffset + maskBytes`。
>
> ### 四、★掩码 flags 位定义（`publishMasks` 内）
>
> ```swift
> var flags: UInt32 = 0
> if isDegraded       { flags |= 1 }    // bit0 总降级
> if drivable.width > 0 || lane.width > 0 { flags |= 2 }   // bit1 掩码有效（有数据）
> if laneDegraded     { flags |= 4 }    // bit2 车道线单独塌陷
> if drivableDegraded { flags |= 8 }    // bit3 可行驶区单独塌陷
> ```
>
> **bit2/bit3 的由来**（源码注释）：原先 UI 只有一个总降级位，无法区分「是车道线塌了还是可行驶区塌了」，显示层只能一刀切压暗，造成**车道线塌陷把可行驶区一起带暗**（用户报「什么都看不到」的直接原因）。这条与 `pitfalls.md` 「单开关管两件事 = 小的把大的拖死」是同一个根因的代码侧修复。
>
> ### 五、位序细节：`UInt8(1 << (x % 8))`
>
> 每字节内**低位在前**（x=0 → bit0）。UI 侧 `readMask` 必须用同样位序，否则掩码镜像/错位——跨进程位图协议最容易错的地方，两侧严格对称（源码注释明确写了）。

## 一、引擎组成概览与 shm/socket 桥接

**定位（文件头注释）**：`EngineMain.swift` 是**后台驾驶引擎（--engine 模式）**——由 `@main AuroraDriveLauncher` 在进程最前端分流进入：**不触碰 SwiftUI、不创建窗口、不跑 NSApp.run()**，在纯后台进程里运行完整驾驶闭环。**TCC 权限经进程链继承**（父进程已授权 → 本进程自动继承，无弹窗）。

**七个组成部分（文件头注释原文）**：

1. **flock 单例锁**——防双引擎同时注入按键
2. **TCC 自检**——ax + screen 任一 false 立即 fail-fast（`AuroraFlags.engineDiagSkipTCC` 即 `AURORA_ENGINE_DIAG_SKIP_TCC=1` 诊断旁路，仅供无 TCC 环境验证非权限逻辑，正常路径禁用）
2'. **观测模式放宽**——`AuroraFlags.observeOnly`（`AURORA_OBSERVE_ONLY=1`）时判据收窄为仅 screen：该模式强制 `controlDisabled = true`、一行按键都不注入，ax 权限对它毫无用处（源码注释记录了三层安全边界：非观测模式判据逐字不变、注入路径已被 `ControlEngine.hold()` 的 `guard hasAccessibilityPermission` 提前拦截）
3. **beginActivity**——防 App Nap 冻结
4. **Unix domain socket**——命令/心跳（`~/Library/Application Support/AuroraDrive/engine.sock`）
5. **共享内存帧管道**——帧头 + 检测结果 + BGRA 双缓冲（引擎写 / UI 读）
6. **DriveState 闭环**——照搬主程序组装（同一份类代码）+ 15Hz DispatchSource tick
7. **信号处理**——SIGTERM/SIGINT 退出前必先 releaseAll（防游戏内键卡死）

**shm 桥接**：`shm_open` 在 C 是可变参数函数（oflag 含 O_CREAT 时才传 mode），Swift 无法直接导入——桥接为固定 3 参版本：

```swift
@_silgen_name("shm_open")
func swift_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
@_silgen_name("shm_unlink")
func swift_shm_unlink(_ name: UnsafePointer<CChar>) -> Int32
```

声明为 **internal**（不是 private）：`EngineClient`（UI 侧）也要用同一桥接。

**`engineLog(_ msg: String)`**——引擎日志：**同时写 stdout 与 `~/Library/Logs/AuroraEngine.log`**，格式 `[HH:mm:ss.SSS] msg`（`SelfTimestamp()` 生成时间戳）。日志文件不存在时先 `createFile` 再写（双保险）。**轮转**：`engineLogMaxBytes = 8MB` 超限则 `engineLogRotateIfNeeded(path:)` 把当前日志挪 `.1`（单备份，旧 `.1` 覆盖）并重建空文件；大小检查每 `engineLogCheckEvery = 64` 次写入做一次（避免每次写日志都 stat）。另外 `run()` 开头 `setvbuf(stdout, nil, _IOLBF, 0)` 设行缓冲——引擎 stdout 被 UI 重定向到文件时默认块缓冲，print 会全卡在内存缓冲区（2026-10-10 修复的实测踩坑）。

**排障入口**：`AuroraEngine.log` 是引擎侧的权威日志（TCC 自检、socket 状态、tick 心跳、每 15 秒管道统计都写这里）；UI 侧的调试日志是 `/tmp/aurora_debug.log`（DriveState 的 dlog）。两边日志分离是排障「引擎死/界面活」问题的关键。

## 二、EngineFrameShm 共享内存帧管道

**内存布局（字节偏移，`EngineFrameShm` 声明注释——引擎写 / UI 读的契约）：**

| 偏移 | 字段 | 说明 |
|---|---|---|
| 0 | magic u32 | `0x41555246`（"AURF"） |
| 4 | version u32 | =1 |
| 8 | headerSize u32 | =4096 |
| 12 | detOffset u32 | =4096 |
| 16 | detCapacity u32 | =256 |
| 20 | detStride u32 | =64 |
| 24 | frameWidth u32 | 当前帧宽 |
| 28 | frameHeight u32 | 当前帧高 |
| 32 | generation u32 | **分辨率变化 +1** |
| 36 | activePage u32 | 0/1；**翻转即新帧就绪** |
| 40 | frameSeq u64 | 帧序号 |
| 48 | timestampNs u64 | 发布时间戳 |
| 56 | detectionCount u32 | 检测条数 |
| 60 | flags u32 | bit0 isDriving / bit1 isStreaming |
| 64 | fpsMilli u32 | fps×1000 |
| 68 | enginePid u32 | 引擎 pid |
| 72 | pageSize u64 | 当前像素页字节数 |
| 80 | maskSeq u64 | 掩码世代号（变化才重发，UI 据此判断新鲜度） |
| 88–132 | 掩码头 | maskW/H、laneW/H、maskFlags、maskRatio、padX/Y、srcW/H、newW/H（见文首 v3 块） |
| 4096 | 检测结果区 | detCapacity×detStride，每条：labelId u32 / conf f32 / cx f32 / cy f32 / w f32 / h f32 / rawName 16 bytes / 预留 |
| 20480 | 掩码区 | `maskRegionBytes = 6400`（两份 160×160 位图） |
| 28672 | 像素页 A | 紧凑 BGRA（`pixelsOffset`） |
| 28672+pageSize | 像素页 B | 双缓冲另一页 |

**类常量**：`name = "/aurora_frame_v1"`、`headerSize = 4096`、`detOffset = 4096`、`detCapacity = 256`、`detStride = 64`、`detEnd`、`maskOffset = 20480`（= `detEnd`）、`maskGridMax = 160`、`maskBytes = 3200`、`maskRegionBytes = 6400`、**`pixelsOffset = 28672`**（v3 掩码区插入后从 20480 后移）、`maxWidth = 4096`、`maxHeight = 2304`。实例侧另有 `publishedSeq: UInt64 { frameSeq }`（统计/验证用）与私有写入助手 `storeU32/storeU64/storeF32`。

**`init?()`**（failable init）：

- 总大小 = `pixelsOffset + maxWidth×maxHeight×4 × 2`（两页满分辨率上限）
- **引擎是共享内存的唯一创建者**：启动时先 `swift_shm_unlink(name)` 清掉上次残留对象——避免旧对象权限/尺寸异常导致打开失败（**已实测踩坑**）
- `swift_shm_open(name, O_CREAT | O_RDWR, 0o600)` → `ftruncate(fd, size)` → `mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)`；任一步失败 `engineLog` + `close(fd)` + 返回 nil
- 写头部常量：magic/version/headerSize/detOffset/detCapacity/detStride/enginePid（storeU32 系列）

**`deinit`**：`munmap(base, totalSize)` + `close(fd)`。

**`publish(image: CGImage?, detections: [Detection], fps: Double, isDriving: Bool, isStreaming: Bool, fullFrame: CVPixelBuffer? = nil)`**——发布一帧（成品画面 + 检测结果 + 状态）：

1. **检测结果区**：`n = min(detections.count, detCapacity)` 逐条写——labelId 映射（`.car→1 / .pedestrian→2 / .sign→3 / .obstacle→4`）、conf/x/y/w/h 写 Float、rawName **固定 16 字节 UTF8 截断**（`prefix(15)` + 16 字节先清零）
2. **像素区双缓冲**：**优先用全分辨率帧（fullFrame，插帧/清晰显示需要），否则用 480 宽缩略帧**
   - CVPixelBuffer 路径：`CVPixelBufferLockBaseAddress(pb, .readOnly)` + defer 解锁 → **逐行 memcpy 到紧凑布局**（源可能有行填充 `bytesPerRow > w*4`，逐行拷 `copyBytes = w*4`）→ `storeU32(36, writePage)` 发布
   - CGImage 路径——**memcpy 快路径**：源 CGImage 由 CaptureEngine 经 CGDataProvider 零拷贝包装 uiBuf，格式与目标页完全一致（同为 32BGRA premultipliedFirst + byteOrder32Little、色彩空间同 DeviceRGB、目标矩形=源尺寸无缩放）——原路径只做恒等格式转换却要走完整 CG 绘制管线（**实测占引擎 tick 主线程 ~78.6%**，改后 2–6ms→0.2ms）。现直接 memcpy：`dataProvider?.data` 可读时，`srcBPR == copyBytes`（无行填充）一次性整拷 `copyBytes * h`，否则逐行拷贝
   - **兜底路径**：dataProvider 不可读（理论不发生，CaptureEngine 恒有 provider）时回退 CGContext 绘制路径（`ctx.draw(img, in: CGRect(...))`），功能零损失
   - 分辨率变化处理：`pageSize != currentPageSize` 时 `generation += 1`、写 generation（偏移 32）和 pageSize（偏移 72）——UI 端凭 generation 变化感知分辨率切换
   - **双缓冲写法**：`active = base.load(fromByteOffset: 36)`，`writePage = active == 0 ? 1 : 0`——写非活动页，写完翻转 activePage（写读不冲突）
3. **头部状态**：`frameSeq += 1` → 写 frameSeq(40)/timestampNs(48)/detectionCount(56)/flags(60)/fpsMilli(64)——`flags |= 1` isDriving、`flags |= 2` isStreaming；fps 用 `max(0, fps) * 1000`

## 三、EngineSocketServer Unix domain socket 服务

**定位（类注释）**：命令/心跳通道。**单客户端；新连接自动替换旧连接**（UI 重开重连场景）。

**结构**：`path`（socket 文件路径）、`queue`（`DispatchQueue("aurora.engine.socket", qos: .userInteractive)`）、`listenFD/clientFD`、`listenSource/clientSource`（DispatchSourceRead）、`lineBuffer: Data`。回调：`onLine: ((String) -> Void)?`、`onClientConnected/onClientDisconnected`。状态：`private(set) var hasClient = false`。

**`start() -> Bool`**：

1. 建目录（`deletingLastPathComponent` + withIntermediateDirectories）→ `unlink(path)` 清掉上次残留的 socket 文件
2. `socket(AF_UNIX, SOCK_STREAM, 0)` → 组 `sockaddr_un`（`sun_family = AF_UNIX`，路径拷贝用 memcpy；**路径过长 guard**：`pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path)`）
3. `bind` → `listen(fd, 4)` → **`chmod(path, 0o600)`**（确保 UI 端能连，同用户 0600）
4. `DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)` 挂 `acceptClient` 事件，resume
5. 任一步失败：`engineLog`（errno）+ `close(fd)` + 返回 false

**`acceptClient()`**（private）：

- `accept(listenFD, nil, nil)` + `setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ...)` → **新连接替换旧连接**：源注释——旧连接由**它自己的 cancel handler 关闭（只关它自己的 fd）**，**绝不在这里按 clientFD 关**——cancel 是异步的，若按共享变量关会误关新连接。`old.cancel()` 后置 `clientFD = fd`
- `lineBuffer.removeAll(keepingCapacity: true)`、`hasClient = true`
- 新连接建 DispatchSourceRead：`setEventHandler { readClient(fd: fd) }`（**fd 按值捕获**——每个连接闭包持有自己的 fd）、`setCancelHandler { close(fd) }`、resume
- `onClientConnected?()`

**`readClient(fd: Int32)`**（private）：

- `read(fd, &buf, 8192)`；`n > 0` 时 append 到 lineBuffer → **按行切分**（`firstIndex(of: 0x0A)` 循环，subdata/removeSubrange）→ `onLine?(line)` 逐行回调
- `n <= 0`（EOF 或错误）→ 本连接断开：`clientFD == fd` 时置 -1、`clientSource?.cancel()`（fd 由 cancel handler 关）、hasClient = false、`onClientDisconnected?()`

**`send(_ line: String)`**：`queue.async` 内 `guard clientFD >= 0` → `write(self.clientFD, ...)`——发送 `(line + "\n")`（行协议）。无客户端时静默丢弃。

**`stop()`**：两个 source 都 cancel + close(listenFD) + `unlink(path)` 清 socket 文件。

**心跳/命令协议**（EngineClient 侧配合）：UI 每 N 秒发一行命令（如 `start`/`stop`/`want_full_frame`），引擎回发心跳行——具体行语义见 `代码-07-EngineClient` 文档。

## 四、EngineGlobals 与 run() 主入口

**`EngineGlobals`**（enum，MainActor 隔离状态）：

| 字段 | 隔离 | 说明 |
|---|---|---|
| `state: DriveState?` | @MainActor | DriveState 闭环实例 |
| `shm: EngineFrameShm?` | @MainActor | 共享内存 |
| `socket: EngineSocketServer?` | @MainActor | socket 服务 |
| `clientSaidBye = false` | @MainActor | UI 是否主动告别（看门狗判定用） |
| `driveStartGeneration` | @MainActor | 断连/重连代次（防跨代回调误生效） |
| `wantFullFrame = false` | @MainActor | UI 是否请求「全分辨率帧」（开了插帧才需要，否则发 480 宽省带宽） |
| `latestFullFrame: CVPixelBuffer?` | nonisolated(unsafe) | 最新全分辨率帧（采集线程写 / 主线程读，覆盖式=天然跳帧） |
| `latestFullFrameLock` | nonisolated(unsafe) | 配套锁 |
| `shutdownRequested` | nonisolated(unsafe) | SIGTERM/SIGINT 置位（由主流 tick 检查后安全停车退出） |
| `maskSeq: UInt64` | @MainActor | 掩码世代号（YOLOPX 出新掩码时 +1，UI 据此判断新鲜度） |
| `lastMaskFingerprint` | @MainActor | 掩码指纹（格数+几何+降级位，判断「掩码是否真的变了」） |
| `lastPublishedCaptureCount` | @MainActor | 上次发布时的抓屏累计帧数（无新帧短路的判据） |
| `skippedPublishTicks` | @MainActor | 连续跳过的发布次数（进心跳日志 `skip=` 字段） |
| `lastPublishedDriving/Streaming/Detections` | @MainActor | 上次发布的驾驶态/串流态/检测框（与帧计数共同构成重发判据；`Detection` 已 Equatable） |
| `lastPublishNanos` | @MainActor | 上次真正发布像素的单调钟时刻（1 秒保活兜底；用 `DispatchTime.uptimeNanoseconds` 而非 `Date()`，不受系统时间跳变影响） |
| `pointerPhase` | @MainActor | 指针朝向回传的帧相位（每 tick 自增，% 3 == 0 时发 pointer 消息 = 5Hz） |
| `lastGuideLinePublishedAt` | @MainActor | 上次 guideline 信号发布时间（去重） |

**定频组**（`EngineMain` 内）：`static var engineTickHz: Double = 15.0`（全链路唯一真值，推理/控制/录制三路都挂在 `tickOnce()` 上）；`setTickHz(_:)`（0.01 容差防抖，同值不重排）、`currentTickHz`、`noteInitialTickHz(_:)`（记初始已生效频率，必须在 timer resume 后置位）、`tickHz(forPerceptionMode:)`（ayolom/legacy 两档均 15Hz）、`captureHz(forPerceptionMode:)`；`applyPerceptionMode(_:isRecording:)`（应急期间 `guard !EmergencyTakeover.shared.takeoverActive` 从源头拦）、`applyYolo26sForMode(_:)`（开机按档位装/卸 yolo26s，幂等）、`flushPendingTickHz()`（录制结束后补切挂起的频率）、`forceYolo26s`（`AuroraFlags.forceYolo26s`）。

**`EngineMain.run() -> Never`——八步启动：**

0. **stdio 行缓冲**：`setvbuf(stdout/stderr, nil, _IOLBF, 0)`——引擎 stdout 被 UI 重定向到日志文件时默认块缓冲，print 会全卡在缓冲区（2026-10-10 实测踩坑）
1. **单例锁**：`engine.lock` 文件 + `flock(LOCK_EX | LOCK_NB)` 独占（失败 = 已有引擎实例，`exit(0)`；锁文件创建失败 `exit(3)`）；进程退出自动释放；ftruncate 清零 + 写入 pid
2. **TCC 自检 fail-fast**：`AXIsProcessTrusted()` + `CGPreflightScreenCaptureAccess()`；`AuroraFlags.observeOnly`（观测模式）时判据收窄为仅 screen，非观测模式仍要求两项全真；不满足且无 `AuroraFlags.engineDiagSkipTCC` → `exit(2)`（"权限须由父进程链继承"）；诊断旁路生效时继续运行（验证非权限逻辑）
3. **Game Mode 对抗**：`GameModeDefender.shared.start()`——静音音频 + 每 3s 重新主张（"引擎进程是跑检测的那个，最需要 audible 维度与持续重主张"）
4. **防冻结 + 优先级**：`beginActivity(options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled], reason: ...)`（**必须持有 napToken，否则 activity 立即释放**）+ `setpriority(PRIO_PROCESS, 0, -20)`（nice=-20）
5. **信号处理**：先 `signal(SIGTERM/SIGINT, SIG_IGN)` 交给 DispatchSource（`DispatchSource.makeSignalSource`，存 `signalSources`）；事件 → `EngineGlobals.shutdownRequested = true` + `performShutdown(reason: "signal ...")`（MainActor.assumeIsolated）
6. **socket**：`EngineSocketServer(path: appSupport/engine.sock)`；`onLine → handleCommand`；**onClientDisconnected 看门狗**：先 `driveStartGeneration += 1`、若有 `driveRequestID` 则 `stopDriving()`（跨代防误），`clientSaidBye` 时继续运行等待重连，否则 `startReconnectWindow()`（3 秒重连窗口）；**无论哪种断开都启动 `startIdleExitCountdown()`**（30 秒内没有 UI 重连 → 引擎自动安全退出，不再常驻占资源）；`onClientConnected` → 同样跨代停驾 + cancel 两个倒计时 + `clientSaidBye = false` + 立即 `sendHeartbeat(reason: "client-connected")`。`server.start()` 失败 `exit(4)`
7. **共享内存 + DriveState 闭环**：`EngineFrameShm()` 失败 `exit(5)`；MainActor 里建 `DriveState()` + 置 `isEngineHost = true`（本进程无 run loop，录制按键必须用 UI 转发的 remoteKeyMask）+ 挂 shm/socket；**全分辨率帧接线**：`captureEngine.onUpscaleFrame` → 锁保护写入 `EngineGlobals.latestFullFrame`（覆盖 DriveState 默认的「喂本进程 upscaleHost」接线——引擎没有窗口/MTKView，插帧渲染在 UI 进程做）；**小地图 ROI 直通**：`captureEngine.onMinimapFrame` → `offerMinimapFrame(pb, revision:)`（视觉定位，引擎进程自己的 tick 消费）；**isUpscaleWanted 门禁**：`captureEngine.isUpscaleWanted = { EngineGlobals.wantFullFrame }`——UI 经 socket 的 upscale 命令实时控制，关闭时帧回调里连全分辨率拷贝都不做（isUpscaleWanted 在拷贝前求值）；**isYoloWanted 门禁**：`captureEngine.isYoloWanted = { EngineMain.needsYoloThrough }`（YOLO 直通帧只在需要时做）；**`AuroraFlags.engineDiagCaptureOnly` 诊断**：只 `captureEngine.start()` 不注入按键，端到端验证「采集 → 共享内存 → UI」链路；**`applyYolo26sForMode(enginePerceptionMode)`**：开机按档位决定 yolo26s 装不装（幂等，让开机行为在日志可见）；**15Hz tick**：`DispatchSource.makeTimerSource`（queue `aurora.engine.tick`）+ `schedule(deadline: .now(), repeating: 1.0 / EngineMain.engineTickHz, leeway: .nanoseconds(0))` → 每 tick 派发主线程 `tickOnce()`；timer 存 `engineTicker`、resume 后 `noteInitialTickHz(engineTickHz)`（此前回显 0 会让 UI 误判「没在 tick」）
8. **心跳 1Hz**：hbTimer（queue `aurora.engine.heartbeat`，leeway 50ms，存 `engineHeartbeat`）→ 检查 `shutdownRequested` → `performShutdown(reason: "tick-detected")` 或 `sendHeartbeat(reason: "periodic")`；`heartbeatCount % 15 == 0` 时输出一条管道统计（seq/有帧/det/driving/yolopx 加载与帧数/掩码格数/降级/耗时/skip/v3 risk，便于无人值守验证；`PerfBus.enabled` 时附 `[PERF] tick分段(p50/p95 ms)` 并 reset 窗口）。最后 `dispatchMain()` 永不返回。退出前如实打印当前已生效频率（`lastAppliedTickHz`）。

## 五、tickOnce / 命令处理 / 心跳 / 看门狗 / 安全退出

**`tickOnce()`**（@MainActor）：

1. `guard let st = EngineGlobals.state`，`st.tick()`（DriveState 主循环）
2. **应急频率接线（ET-5）**：`EmergencyTakeover.shared.effectiveTickHz`（15 巡航 / 20 冲刺 / 5 让位）与本帧 `currentTickHz` 差超过 0.01 就 `setTickHz`（放 `st.tick()` 之后、publish 之前：ET-4 喂的 noteTickGap/noteModelDegraded 可能此刻改变频率，本帧即切）
3. **应急抓屏联动**：`EmergencyTakeover.shared.sprinting` 时抓屏一起冲 20（`EmergencyTakeover.sprintHz`），否则回 `baseCaptureHz`；值真变才 `Task { setCaptureHz(wantCapHz) }`（记 `lastAppliedCaptureHz`，避免每帧派发）
4. `wantFullFrame` 时锁内取 `latestFullFrame` 作为全分辨率帧，否则 nil（发 480 宽缩略帧省带宽）
5. **无新帧短路**：`curCaptureCount`（=`captureEngine.capturedFrameCount`）与 `lastPublishedCaptureCount` 比、驾驶/串流/检测框与上次发布比、距上次发布是否超 1 秒（`keepAliveDue` 保活兜底）——`!st.isDriving, !wantFullFrame, full == nil, pixelsUnchanged, stateUnchanged, !keepAliveDue` 时 `skippedPublishTicks &+= 1` 跳过像素发布（不 return，掩码/指针等非像素回传仍推进）。安全边界六条全在源注释：驾驶中必发、isStreaming 变化必发、检测框变化必发、插帧档不短路、1 秒保活、连接活性由 socket 心跳独立维护
6. **发布**：`shm?.publish(image: st.currentFrameCG, detections: curDetections, ...)`——**检测框来源 26S 优先、空则回落 yolopx**（与 UI 侧 `preferYolopxDetections` 同一优先级语义；A 档下 yolo26s 不加载、恒空数组，不回落 UI 就没框可画）
7. **掩码回传（协议 v3）**：`st.isDriving` 时算指纹 `fp`（drivable/lane 的 `positiveCount`、`width`、letterbox `metrics` 的 pad/new/src/ratio 量化、`e2ePerceptionPaused` 与三个降级位全部入指纹）→ `fp != lastMaskFingerprint` 时 `maskSeq &+= 1` 并 `publishMasks(...)`。指纹带几何与降级位的原因、以及 2026-10-24 修复的「指纹短路从未生效」血案（原代码把 publishMasks 写在 if 花括号之外），源注释有完整记录。停车时清掩码（`maskSeq = 0` + 空 `publishMasks`，避免 UI 留残影）
8. **指针朝向回传（5Hz）**：`pointerPhase &+= 1`，`% 3 == 0` 时发 `{"type":"pointer",...}`（bodyHeadingDeg/bodyHeadingConf）；`guideLineSignal.observedAt` 变化时顺带发 `{"type":"guideline",...}`。为什么不塞进 1Hz 心跳：心跳提 5Hz 会白带 4 倍状态量，指针只有两个数

**`handleCommand(_ line: String, server: EngineSocketServer)`**——socket 命令（JSON 行协议，`{"type": ...}`）。**13 种命令**：

| type | 行为 | 源注释要点 |
|---|---|---|
| `start` | `state?.startDriving()` + clientSaidBye=false | |
| `drive_lease` | 驾驶租约管理（driveRequestID 体系） | |
| `stop` | `state?.stopDriving()`（按键已释放） | |
| `bye` | `clientSaidBye = true` + `pauseDriving("bye")` | UI 主动关闭 |
| `status` | `sendHeartbeat(reason: "status-query")` | 状态查询 |
| `upscale` | `wantFullFrame = on` | UI 开关「插帧/超分」→ 引擎据此决定发全分辨率帧还是 480 宽缩略帧 |
| `record` | 置 `st.glyphMode/expertMode/recordThirdPerson` + `recordEngine.start/stop` + 立即回执 | **录制必须落在引擎侧**（源注释：帧只存在于引擎进程——引擎模式下 UI 的 tick 提前 return，UI 侧 `recordFrameIfNeeded()` 永远不执行 → 目录建了、文件建了、录不进东西）。视角随命令下发（`RecordEngine.normalizePerspective`，缺省沿用引擎侧当前值，2026-10-10 修复「不带 perspective 就把 TPV 打回 FPV」）；只在 `recOn` 时同步会话级参数（stop 不动它们）；ack 报「实际生效」视角（`recordEngine.sessionPerspective`）；停止时 `flushPendingTickHz()` 补切挂起频率；立即回执防 UI 把开关弹回去（心跳周期 1s，UI 侧也有宽限期，双保险） |
| `reloadmodel` | `inferenceEngine/assistEngine/yoloEngine/inferenceEngineV3` 四引擎 `reloadModel()` + `applyYolo26sForMode` | **训练完成后热替换**（源注释：不转发这条命令，引擎会一直用内存里的旧模型 →「训练完了但车还按老模型开」）。V3 主驾也必须重载（评审 P1-3：原清单漏了它）。`applyYolo26sForMode` 恢复档位门：`reloadModel()` 后 `inferFast` 会自己 `loadIfNeeded()` 把 26S 拉回来，不恢复档位门，「训练完点一下应用」就静默破坏档位。置空后下次推理重读磁盘 |
| `config` | 同步驾驶参数：`sport/controlDisabled/forceRule/modeLock/cloudROIHint/positioningMode/networkX/networkY/networkScore/networkMode/visualFallback/expert/glyph/degradeThreshold/speedLimit/roadCondition/autoSpeedEnabled/unlimitedSource/keyMask/takeover/physicalKeys/digest/perceptionMode` | **controlDisabled 与 forceRuleMode 是安全开关**（源注释：不同步会让人以为车已经停手/已切安全档，实际还在跑模型）；**speedLimit 不是显示项**：它经 InferenceEngine 变成 `vehicle_state[4]` 直接参与推理，不同步会让 UI 显示 40 而模型仍按 120 决策；**keyMask/takeover/physicalKeys 必须经 config 转发**（引擎进程 dispatchMain 无 run loop，KeyboardMonitor 收不到 NSEvent——ET-6 审计实测确认）；modeLock 是 `DriveMode??`（点档位锁死端到端）；positioningMode/networkX 等驱动视觉定位的 seed；perceptionMode 为 task-93 档位感知动态频率 |
| `set_capture_mode`（别名 `capture`） | `performCaptureModeSwitch(modeStr:windowID:)` + `validateWindowExists(windowID:)`（ScreenCaptureKit 枚举可捕获窗口） | 抓屏模式/窗口切换 |
| `state` | `buildStateSnapshot()` 返回状态快照 | |
| `ping` | `server.send("{\"type\":\"pong\"}")` | |
| default | 未知命令类型记日志 | |

命令处理普遍带 `sendAck(id:cmd:ok:detail:data:server:)` 回执（`ackIDString(_:)` 把 Int/Double/Bool/String 的 id 原样转字符串回显，消除「发完命令不知道成没成」）。

**`sendHeartbeat(reason:)`**（@MainActor）——心跳 JSON 一行发 UI：

```json
{"type":"heartbeat","proto":<协议版本>,"ts":<unix秒>,"fps":"%.1f","detections":N,
 "isDriving":bool,"isStreaming":bool,"mode":"...","modeRaw":"...","speed":"%.1f",
 "speedKmh":"%.1f","confidence":"%.3f","recording":bool,"frames":N,"pid":N,
 "takeover":bool,"userHolding":bool,"reason":"..."}
```

fps 取 `captureFPS > 0 ? captureFPS : st.fps`（采集没起来时回退标称 fps）。`takeover/userHolding` 来自 `EmergencyTakeover.shared`（ET-9 修复：应急接管状态机在两进程各有实例，UI 实例永不触发，引擎经心跳回传真实状态，1Hz 延迟可接受——引擎侧冲刺是零延迟生效的）。发送前经 `JSONSerialization` 转 dict **enriched**：补 `driveDiagnostic/speedValid/needsManualIntervention/isCapturing/captureFrames/hasFrame/lastModeError`（抓屏健康回传：UI 侧据此显示「屏幕录制被拒/抓屏未起」）；手写 JSON 解析失败时走**最小心跳兜底**（只带抓屏状态字段，绝不把「屏幕录制被拒」的原因丢掉）。

**看门狗与倒计时**：

- `startReconnectWindow()`：`DispatchWorkItem` + `asyncAfter(.now() + 3.0)`——3 秒后 `hasClient == true`（已重连）则 return，否则 `pauseDriving("watchdog")`（"UI died, parking"）
- `startIdleExitCountdown()`：30 秒后未重连 → `performShutdown(reason: "idle-exit")`（"先释放全部按键"）。源注释：引擎本身是「常驻」设计（UI 关掉也能继续驾驶），但**没人用还一直占资源不合理，所以加这道兜底**。重连即取消（onClientConnected 里 cancel）
- `cancelReconnectWindow()` / `cancelIdleExitCountdown()`：cancel + 置 nil（`reconnectWorkItem` / `idleExitWorkItem`）

**`pauseDriving(_ reason: String)`**（@MainActor）——暂停驾驶（安全侧）：

- `st.isDriving = false` + `st.controlEngine.releaseAll()`（**立即释放全部按键**），但**保持抓屏与推理运行，等待 UI 重连**
- **一并停掉录制**（`if st.isRecording` 置 false）：源注释——否则引擎会在无人监管下继续录 30 秒「车已停、标签还是上一刻 AI 决策」的垃圾帧，**这些帧会被下次训练当成有效样本 → 污染模仿学习数据集**
- 与 `stop`（显式停止、连抓屏一起停）区分

**`performShutdown(reason:)`**（@MainActor）——退出（**任何路径都先 releaseAll**）：

1. `state` 存在：`st.stopDriving()`（内部含 `controlEngine.releaseAll()`）+ **`st.recordEngine.flushSync()`**（源注释：stop() 里的 meta.json 是 writeQueue.async 写的，紧接着 exit(0) 会在元信息落盘前杀掉进程 → 录制会话缺 meta.json。这里等队列排空）
2. 状态尚未建立：兜底 `ControlEngine().releaseAll()`
3. `EngineGlobals.socket?.stop()` → `engineLog("[ENGINE] 退出完成")` → `exit(0)`

**EngineMain 文档至此完整**（全文件覆盖：概览与桥接 → shm → socket → run() 八步 → 命令/心跳/看门狗/退出 → v3 掩码发布（见文首块））。
