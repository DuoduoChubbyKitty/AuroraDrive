# 代码-06 EngineMain 引擎进程主循环

> 覆盖源文件：`Sources/AuroraDrive/Core/EngineMain.swift`（****1153 行**，**2026-10-02 `wc -l` 实测**（原文写 1082 行）**，2026-09-29 `wc -l` 实测；原文写 876 行）。基于当前仓库逐单元编写。
>
> ---
>
> ## ⚠️ 2026-09-29 复核追加：v3 掩码发布（本文原无记载，+206 行）
>
> **本文按 876 行编写，现将 9-27/9-28 新增的掩码发布链路补上。**
>
> ### 一、新增 shm 区域：掩码区（`EngineFrameShm` 常量）
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
> ⚠️ **`pixelsOffset` 由 20480 后移到 28672 —— 这是 shm 布局变更**，也是 `protocolVersion`
> 升到 3 的直接原因（旧 UI 会把掩码区当像素读 → 花屏）。详见 `代码-07`。
>
> ### 二、`writeMask(_:offset:)`（约 244–264 行）—— 位压缩写入
>
> ```swift
> private func writeMask(_ grid: MaskGrid, offset: Int) {
>     guard grid.width > 0, grid.height > 0 else { return }
>     let rows = min(grid.height, EngineFrameShm.maskGridMax)
>     let bytesPerRow = (min(grid.width, EngineFrameShm.maskGridMax) + 7) / 8
>     let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
>     for i in 0..<(rows * bytesPerRow) { ptr[i] = 0 }          // ★先清零
>     for y in 0..<rows {
>         let rowBase = y * bytesPerRow
>         for x in 0..<min(grid.width, EngineFrameShm.maskGridMax) where grid.at(x, y) {
>             ptr[rowBase + x / 8] |= UInt8(1 << (x % 8))
>         }
>     }
> }
> ```
>
> **两个易忽略的设计点**：
> 1. **写前先清零**——源码注释：「避免上一帧的残留位被读成前景」。若省略，缩小的掩码会留下上一帧的旧位
> 2. **`bytesPerRow = (width + 7) / 8`**——按**每行**独立位对齐，不是整块连续。UI 侧 `readMask` 必须严格对称（`代码-07`）
>
> **为何位压缩**（源码 241–243 行注释）：
> > 160×160 用 UInt8 存是 25600 字节/份，两份 50KB；位压缩后每步 20 字节/行 × 160 行 = 3200 字节，
> > 两份 6.4KB。30Hz 下的差别是 1.5MB/s vs 192KB/s，而掩码本来只有 0/1 信息，一个 bit 就够。
>
> ### 三、`publishMasks(drivable:lane:metrics:isDegraded:laneDegraded:drivableDegraded:seq:)`（约 266–300 行）
>
> 由 `publishTick` 每 tick 调用。**写入的字段**（全部为 v3 新增）：
>
> | 偏移 | 写入 | 说明 |
> |---|---|---|
> | 80 | `seq` | 掩码世代号 |
> | 88/92 | drivable.width/height | 可行驶区网格尺寸 |
> | 96/100 | lane.width/height | 车道线网格尺寸 |
> | 104 | flags | 见下 |
> | 108 | `Float(metrics.ratio)` | letterbox 缩放比 |
> | 112/116 | padX/padY | letterbox 边距 |
> | 120/124 | srcW/srcH | 源图尺寸 |
> | **128/132** | **newW/newH** | letterbox 内容区（2026-09-28 补传，**原为客户端硬填 0**） |
>
> 随后两次 `writeMask`：可行驶区 → `maskOffset`(20480)，车道线 → `maskOffset + maskBytes`(23680)。
>
> ### 四、★掩码 flags 位定义（含 bit2/bit3 的由来）
>
> ```swift
> var flags: UInt32 = 0
> if isDegraded       { flags |= 1 }    // bit0 总降级
> if drivable.width > 0 || lane.width > 0 { flags |= 2 }   // bit1 掩码有效（有数据）
> if laneDegraded     { flags |= 4 }    // bit2 车道线单独塌陷
> if drivableDegraded { flags |= 8 }    // bit3 可行驶区单独塌陷
> ```
>
> **bit2/bit3 是本轮新增的关键修复**（源码注释原文）：
> > bit2/bit3 是 2026-09-27 加的：原先 UI 只有一个总降级位，无法区分"是车道线塌了还是可行驶区塌了"，
> > 于是显示层只能一刀切压暗，造成**车道线塌陷把可行驶区一起带暗**（用户报"什么都看不到"的直接原因）。
>
> 这条与 `pitfalls.md` 第 18 条「单开关管两件事 = 小的把大的拖死」是同一个根因的代码侧修复。
>
> ### 五、位运算的一个细节：`1 << (x % 8)`
>
> `UInt8(1 << (x % 8))` —— 每字节内 **低位在前**（x=0 → bit0）。UI 侧 `readMask` 必须用同样的位序，
> 否则掩码会镜像/错位。**这是跨进程位图协议最容易错的地方，两侧必须严格对称**
> （源码明确写了「与引擎侧 `EngineFrameShm.writeMask` 严格对称」）。
>
> ---
>
> **2026-09-25 深度复核记录**（849→876 行）：① **`publish` 的 CGImage 像素路径已改 memcpy 快路径**（9-24 改动 7：原 CGContext 恒等格式转换占引擎 tick 主线程 ~78.6%，实测 2–6ms→0.2ms；dataProvider 可读时直接 memcpy——srcBPR==copyBytes 一次性整拷、否则逐行；不可读才兜底 CGContext 绘制，功能零损失）；② **引擎侧新增 `isUpscaleWanted` 门禁接线**（run() 第 7 步：`captureEngine.isUpscaleWanted = { EngineGlobals.wantFullFrame }`——UI 经 socket 的 upscale 命令实时控制，关闭时 CaptureEngine 帧回调里连全分辨率拷贝都不做）；其余架构（shm 布局/socket/八步/九命令/看门狗/退出）与上版一致。

## 一、引擎组成概览与 shm/socket 桥接（第 1–63 行）

**定位（4–21 行头注释）**：`EngineMain.swift` 是**后台驾驶引擎（--engine 模式）**——由 `@main AuroraDriveLauncher` 在进程最前端分流进入：**不触碰 SwiftUI、不创建窗口、不跑 NSApp.run()**，在纯后台进程里运行完整驾驶闭环。**TCC 权限经进程链继承**（父进程已授权 → 本进程自动继承，无弹窗）。

**七个组成部分（源注释原文）：**

1. **flock 单例锁**——防双引擎同时注入按键
2. **TCC 自检**——ax + screen 任一 false 立即 fail-fast（`AURORA_ENGINE_DIAG_SKIP_TCC=1` 诊断旁路，仅供无 TCC 环境验证非权限逻辑，正常路径禁用）
3. **beginActivity**——防 App Nap 冻结
4. **Unix domain socket**——命令/心跳（`~/Library/Application Support/AuroraDrive/engine.sock`）
5. **共享内存帧管道**——帧头 + 检测结果 + BGRA 双缓冲（引擎写 / UI 读）
6. **DriveState 闭环**——照搬主程序组装（同一份类代码）+ 30Hz DispatchSource tick
7. **信号处理**——SIGTERM/SIGINT 退出前必先 releaseAll（防游戏内键卡死）

**shm 桥接（第 28–34 行）**：`shm_open` 在 C 是可变参数函数（oflag 含 O_CREAT 时才传 mode），Swift 无法直接导入可变参数 C 函数——桥接为固定 3 参版本：

```swift
@_silgen_name("shm_open")
func swift_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
@_silgen_name("shm_unlink")
func swift_shm_unlink(_ name: UnsafePointer<CChar>) -> Int32
```

声明为 **internal**（不是 private）：`EngineClient`（UI 侧）也要用同一桥接。

**`engineLog(_ msg: String)`（第 39–57 行）**——引擎日志：**同时写 stdout 与 `~/Library/Logs/AuroraEngine.log`**。格式 `[HH:mm:ss.SSS] msg`；日志文件不存在时先 `createFile` 再写（双保险，第 49–56 行）。`SelfTimestamp()`（59–63 行）用 `HH:mm:ss.SSS` 格式器。

**排障入口**：`AuroraEngine.log` 是引擎侧的权威日志（TCC 自检、socket 状态、tick 心跳都写这里）；UI 侧的调试日志是 `/tmp/aurora_debug.log`（DriveState 的 dlog）。两边日志分离是排障"引擎死/界面活"问题的关键。

## 二、EngineFrameShm 共享内存帧管道（第 65–260 行）

**内存布局（字节偏移，67–88 行注释——引擎写 / UI 读的契约）：**

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
| 4096 | 检测结果区 | detCapacity×detStride，每条：labelId u32 / conf f32 / cx f32 / cy f32 / w f32 / h f32 / rawName 16 bytes / 预留 |
| 20480 | 像素页 A | 紧凑 BGRA |
| 20480+pageSize | 像素页 B | 双缓冲另一页 |

**类常量（91–98 行）**：`name = "/aurora_frame_v1"`、`headerSize = 4096`、`detOffset = 4096`、`detCapacity = 256`、`detStride = 64`、`pixelsOffset = 20480`、`maxWidth = 4096`、`maxHeight = 2304`。

**`init?()`（第 110–144 行）**：

- 总大小 = `pixelsOffset + maxWidth×maxHeight×4 × 2`（两页满分辨率上限）
- **引擎是共享内存的唯一创建者**：启动时先 `swift_shm_unlink(name)` 清掉上次残留对象——避免旧对象权限/尺寸异常导致打开失败（**已实测踩坑**）
- `swift_shm_open(name, O_CREAT | O_RDWR, 0o600)` → `ftruncate(fd, size)` → `mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)`；任一步失败 `engineLog` + `close(fd)` + 返回 nil（failable init）
- 写头部常量（137–143 行）：magic/version/headerSize/detOffset/detCapacity/detStride/enginePid

**`deinit`（146–149 行）**：`munmap(base, totalSize)` + `close(fd)`。

**`publish(image:detections:fps:isDriving:isStreaming:fullFrame: CVPixelBuffer? = nil)`（第 160–259 行）**——发布一帧（成品画面 + 检测结果 + 状态）：

1. **检测结果区（164–187 行）**：`n = min(detections.count, detCapacity)` 逐条写——labelId 映射（`.car→1 / .pedestrian→2 / .sign→3 / .obstacle→4`）、conf/x/y/w/h 写 Float、rawName **固定 16 字节 UTF8 截断**（`prefix(15)` + 16 字节先清零）
2. **像素区双缓冲（189–271 行）**：**优先用全分辨率帧（fullFrame，插帧/清晰显示需要），否则用 480 宽缩略帧**
   - CVPixelBuffer 路径：锁 readOnly → **逐行 memcpy 到紧凑布局**（源可能有行填充 `bytesPerRow > w*4`，逐行拷贝 `copyBytes = w*4`）→ `storeU32(36, writePage)` 发布
   - CGImage 路径——**memcpy 快路径（9-24 改动 7，源码 235–251 行）**：源 CGImage 由 CaptureEngine 经 CGDataProvider 零拷贝包装 uiBuf，格式与目标页完全一致（同为 32BGRA premultipliedFirst + byteOrder32Little、色彩空间同 DeviceRGB、目标矩形=源尺寸无缩放）——原路径只做恒等格式转换，却要走完整 CG 绘制管线（**实测占引擎 tick 主线程 ~78.6%**）。现直接 memcpy：`srcBPR == copyBytes`（无行填充）时一次性整拷 `copyBytes * h`，否则逐行拷贝
   - **兜底路径（256–269 行）**：dataProvider 不可读（理论不发生，CaptureEngine 恒有 provider）时回退原 CGContext 绘制路径，功能零损失
   - 分辨率变化处理：`pageSize != currentPageSize` 时 `generation += 1`、写 generation（偏移 32）和 pageSize（偏移 72）——UI 端凭 generation 变化感知分辨率切换
   - **双缓冲写法**：`active = base.load(36)`，`writePage = active == 0 ? 1 : 0`——写非活动页，写完翻转 activePage（写读不冲突）
3. **头部状态（249–258 行）**：`frameSeq += 1` → 写 frameSeq(40)/timestampNs(48)/detectionCount(56)/flags(60)/fpsMilli(64)——`flags |= 1` isDriving、`flags |= 2` isStreaming；fps 用 `max(0, fps) * 1000`

## 三、EngineSocketServer Unix domain socket 服务（第 262–409 行）

**定位（264 行注释）**：命令/心跳通道。**单客户端；新连接自动替换旧连接**（UI 重开重连场景）。

**结构（265–283 行）**：`path`（socket 文件路径）、`queue`（`DispatchQueue("aurora.engine.socket", qos: .userInteractive)`）、`listenFD/clientFD`、`listenSource/clientSource`（DispatchSourceRead）、`lineBuffer: Data`。回调：`onLine: ((String) -> Void)?`、`onClientConnected/onClientDisconnected`。状态：`private(set) var hasClient = false`。

**`start() -> Bool`（第 285–338 行）**：

1. 建目录（`deletingLastPathComponent` + withIntermediateDirectories）→ `unlink(path)` 清掉上次残留的 socket 文件
2. `socket(AF_UNIX, SOCK_STREAM, 0)` → 组 `sockaddr_un`（`sun_family = AF_UNIX`，路径拷贝用 memcpy；**路径过长 guard**（300–304 行）：`pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path)`）
3. `bind` → `listen(fd, 4)` → **`chmod(path, 0o600)`**（确保 UI 端能连，同用户 0600）
4. `DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)` 挂 acceptClient 事件，resume
5. 任一步失败：`engineLog`（errno）+ `close(fd)` + 返回 false

**`acceptClient()`（第 340–364 行）**：

- `accept(listenFD, nil, nil)` → **新连接替换旧连接**：源注释（343–345 行）——旧连接由**它自己的 cancel handler 关闭（只关它自己的 fd）**，**绝不在这里按 clientFD 关**——cancel 是异步的，若按共享变量关会误关新连接。`old.cancel()` 后置 `clientFD = fd`
- `lineBuffer.removeAll(keepingCapacity: true)`、`hasClient = true`
- 新连接建 DispatchSourceRead：`setEventHandler { readClient(fd: fd) }`（**fd 按值捕获**——每个连接闭包持有自己的 fd）、`setCancelHandler { close(fd) }`、resume
- `onClientConnected?()`

**`readClient(fd: Int32)`（第 366–389 行）**：

- `read(fd, &buf, 8192)`；`n > 0` 时 append 到 lineBuffer → **按行切分**（`firstIndex(of: 0x0A)` 循环，subdata/removeSubrange）→ `onLine?(line)` 逐行回调
- `n <= 0`（EOF 或错误）→ 本连接断开：`clientFD == fd` 时置 -1、`clientSource?.cancel()`（fd 由 cancel handler 关）、hasClient = false、`onClientDisconnected?()`

**`send(_ line: String)`（第 391–399 行）**：`queue.async` 内 `guard clientFD >= 0` → `write(self.clientFD, ...)`——发送 `(line + "\n")`（行协议）。无客户端时静默丢弃。

**`stop()`（第 401–408 行）**：两个 source 都 cancel + close(listenFD) + `unlink(path)` 清 socket 文件。

**心跳/命令协议**（EngineClient 侧配合）：UI 每 N 秒发一行命令（如 `start`/`stop`/`want_full_frame`），引擎回发心跳行——具体行语义见 `代码-07-EngineClient` 文档。

## 四、EngineGlobals 与 run() 主入口八步（第 411–605 行）

**`EngineGlobals`（enum，第 413–425 行）**——引擎全局（MainActor 隔离状态）：

| 字段 | 隔离 | 说明 |
|---|---|---|
| `state: DriveState?` | @MainActor | DriveState 闭环实例 |
| `shm: EngineFrameShm?` | @MainActor | 共享内存 |
| `socket: EngineSocketServer?` | @MainActor | socket 服务 |
| `clientSaidBye = false` | @MainActor | UI 是否主动告别（看门狗判定用） |
| `wantFullFrame = false` | @MainActor | UI 是否请求「全分辨率帧」（开了插帧才需要，否则发 480 宽省带宽） |
| `latestFullFrame: CVPixelBuffer?` | nonisolated(unsafe) | 最新全分辨率帧（采集线程写 / 主线程读，覆盖式=天然跳帧） |
| `latestFullFrameLock = NSLock()` | nonisolated(unsafe) | 配套锁 |
| `shutdownRequested` | nonisolated(unsafe) | SIGTERM/SIGINT 置位（由主流 tick 检查后安全停车退出） |

**`EngineMain.run() -> Never`（第 431–605 行）——八步启动：**

1. **单例锁（438–451 行）**：`engine.lock` 文件 + `flock(LOCK_EX | LOCK_NB)` 独占（失败 = 已有引擎实例，`exit(0)`）；进程退出自动释放；ftruncate 清零 + 写入 pid
2. **TCC 自检 fail-fast（453–465 行）**：`AXIsProcessTrusted()` + `CGPreflightScreenCaptureAccess()`；任一 false 且无 `AURORA_ENGINE_DIAG_SKIP_TCC=1` 环境变量 → `exit(2)`（"权限须由父进程链继承"）；诊断旁路生效时继续运行（验证非权限逻辑）
3. **Game Mode 对抗（467–469 行）**：`GameModeDefender.shared.start()`——静音音频 + 每 3s 重新主张（"引擎进程是跑检测的那个，最需要 audible 维度与持续重主张"）
4. **防冻结 + 优先级（471–478 行）**：`beginActivity(options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled], reason: ...)`（**必须持有 napToken，否则 activity 立即释放**）+ `setpriority(PRIO_PROCESS, 0, -20)`（nice=-20）
5. **信号处理（480–497 行）**：先 `signal(SIGTERM/SIGINT, SIG_IGN)` 交给 DispatchSource；SignalSource 事件 → `EngineGlobals.shutdownRequested = true` + `performShutdown(reason:)`（MainActor.assumeIsolated）
6. **socket（499–534 行）**：`EngineSocketServer(path: appSupport/engine.sock)`；`onLine → handleCommand`；**onClientDisconnected 看门狗（505–520 行）**：`clientSaidBye` 时继续运行等待重连，否则 `startReconnectWindow()`（3 秒重连窗口）；**无论哪种断开都启动 `startIdleExitCountdown()`**（30 秒内没有 UI 重连 → 引擎自动安全退出，不再常驻占资源）；`onClientConnected` → cancel 两个倒计时 + `clientSaidBye = false` + 立即心跳。`server.start()` 失败 `exit(4)`
7. **共享内存 + DriveState 闭环（560–589 行）**：`EngineFrameShm()` 失败 `exit(5)`；MainActor 里建 `DriveState()` + 挂 shm/socket；**全分辨率帧接线（574–578 行）**：覆盖 DriveState 默认的"喂本进程 upscaleHost"接线——引擎没有窗口/MTKView，插帧渲染在 UI 进程做，引擎只负责把全分辨率帧送过去（锁保护写入 latestFullFrame）；**isUpscaleWanted 门禁接线（581 行，9-24 改动 10）**：`captureEngine.isUpscaleWanted = { EngineGlobals.wantFullFrame }`——UI 经 socket 的 upscale 命令实时控制，关闭时帧回调里连全分辨率拷贝都不做（isUpscaleWanted 在拷贝前求值）；**`AURORA_ENGINE_DIAG_CAPTURE_ONLY=1` 诊断（585–588 行）**：只启动抓屏不注入按键，端到端验证"采集 → 共享内存 → UI"链路；**30Hz tick（592–603 行）**：`DispatchSource.makeTimerSource` + `schedule(deadline: .now(), repeating: 1.0/30.0, leeway: .nanoseconds(0))` → 每 tick 派发主线程 `tickOnce()`
8. **心跳 1Hz（578–601 行）**：hbTimer（leeway 50ms）→ 检查 shutdownRequested → `sendHeartbeat(reason: "periodic")`；**每 5 秒输出一条管道统计**（seq/有帧/det/driving）便于无人值守验证。最后 `dispatchMain()` 永不返回

## 五、tick / 命令处理 / 心跳 / 看门狗 / 安全退出（第 617–849 行）

**`tickOnce()`（@MainActor，第 618–635 行）**：

1. `guard let st = EngineGlobals.state`，`st.tick()`（DriveState 主循环）
2. `wantFullFrame` 时锁内取 `latestFullFrame` 作为全分辨率帧，否则 nil（发 480 宽缩略帧省带宽）
3. `shm?.publish(image: st.currentFrameCG, detections: st.yoloEngine.detections, fps: st.captureEngine.captureFPS > 0 ? st.captureEngine.captureFPS : st.fps, isDriving: st.isDriving, isStreaming: st.isStreaming, fullFrame: full)`

**`handleCommand(_ line:server:)`（第 639–751 行）**——socket 命令（JSON 行协议，`{"type": ...}`）。九种命令：

| type | 行为 | 源注释要点 |
|---|---|---|
| `start` | `state?.startDriving()` + clientSaidBye=false | |
| `stop` | `state?.stopDriving()`（按键已释放） | |
| `bye` | `clientSaidBye = true` + `pauseDriving("bye")` | UI 主动关闭 |
| `status` | `sendHeartbeat(reason: "status-query")` | 状态查询 |
| `upscale` | `wantFullFrame = on` | UI 开关「插帧/超分」→ 引擎据此决定发全分辨率帧还是 480 宽缩略帧 |
| `record` | 置 `st.glyphMode/expertMode/isRecording` + 立即回执心跳 | **录制必须落在引擎侧**（688–689 行注释：帧只存在于引擎进程——引擎模式下 UI 的 tick 提前 return，recordFrameIfNeeded() 永远不执行 → 目录建了、文件建了、录不进东西）。立即回执防 UI 把开关弹回去（心跳周期 1s，UI 侧也有宽限期，双保险） |
| `reloadmodel` | `inferenceEngine/assistEngine/yoloEngine` 三引擎 `reloadModel()` | **训练完成后热替换**（707–709 行注释：不转发这条命令，引擎会一直用内存里的旧模型 →「训练完了但车还按老模型开」）。置空后下次推理重读磁盘 |
| `config` | 同步 7 个驾驶参数：`sport/controlDisabled/forceRule/expert/glyph/degradeThreshold/speedLimit` | **controlDisabled（禁用控制）与 forceRuleMode（紧急切纯规则）是安全开关**（721–723 行注释：不同步会让人以为车已经停手/已切安全档，实际还在跑模型）；**speedLimit 不是显示项**（740–742 行）：它经 InferenceEngine 变成 `vehicle_state[4] = speed_limit_norm` 直接参与推理，不同步会让 UI 显示 40 而模型仍按 120 决策 |
| `ping` | `server.send("{\"type\":\"pong\"}")` | |
| default | 未知命令类型记日志 | |

**`sendHeartbeat(reason:)`（@MainActor，第 756–764 行）**——心跳 JSON 一行发 UI：

```json
{"type":"heartbeat","proto":<协议版本>,"ts":<unix秒>,"fps":"%.1f","detections":N,
 "isDriving":bool,"isStreaming":bool,"mode":"...","modeRaw":"...","speed":"%.1f",
 "speedKmh":"%.1f","confidence":"%.3f","recording":bool,"frames":N,"pid":N,"reason":"..."}
```

fps 取 `captureFPS > 0 ? captureFPS : st.fps`（采集没起来时回退标称 fps）。

**看门狗与倒计时（第 766–812 行）**：

- `startReconnectWindow()`（769–780 行）：`DispatchWorkItem` + `asyncAfter(.now() + 3.0)`——3 秒后 `hasClient == true`（已重连）则 return，否则 `pauseDriving("watchdog")`（"UI died, parking"）
- `startIdleExitCountdown()`（794–806 行）：30 秒后未重连 → `performShutdown(reason: "idle-exit")`（"先释放全部按键"）。源注释：引擎本身是「常驻」设计（UI 关掉也能继续驾驶），但**没人用还一直占资源不合理，所以加这道兜底**。重连即取消（onClientConnected 里 cancel）
- 两个 cancel 方法（783–786、809–812 行）：cancel + 置 nil

**`pauseDriving(_ reason: String)`（@MainActor，第 817–829 行）**——暂停驾驶（安全侧）：

- `st.isDriving = false` + `st.controlEngine.releaseAll()`（**立即释放全部按键**），但**保持抓屏与推理运行，等待 UI 重连**
- **一并停掉录制（821–827 行）**：源注释——否则引擎会在无人监管下继续录 30 秒「车已停、标签还是上一刻 AI 决策」的垃圾帧，**这些帧会被下次训练当成有效样本 → 污染模仿学习数据集**
- 与 `stop`（显式停止、连抓屏一起停）区分

**`performShutdown(reason:)`（@MainActor，第 834–848 行）**——退出（**任何路径都先 releaseAll**）：

1. `state` 存在：`st.stopDriving()`（内部含 `controlEngine.releaseAll()`）+ **`st.recordEngine.flushSync()`**（838–840 行注释：stop() 里的 meta.json 是 writeQueue.async 写的，紧接着 exit(0) 会在元信息落盘前杀掉进程 → 录制会话缺 meta.json。这里等队列排空）
2. 状态尚未建立：兜底 `ControlEngine().releaseAll()`
3. `EngineGlobals.socket?.stop()` → `engineLog("[ENGINE] 退出完成")` → `exit(0)`

**EngineMain 文档至此完整**（**1082 行**，2026-09-29 实测；原文写"876 行全覆盖"对应 9-25 时点）。
覆盖：概览与桥接 → shm → socket → run() 八步 → 命令/心跳/看门狗/退出 → **v3 掩码发布（见文首复核块）**。