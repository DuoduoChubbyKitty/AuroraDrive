# 代码-07 EngineClient 进程间通信

> 覆盖源文件：`Sources/AuroraDrive/Core/EngineClient.swift`（613 行）。基于当前仓库逐单元编写。

## 一、职责概览与协议版本（第 1–125 行）

**定位（4–16 行头注释）**：`EngineClient.swift` 是 **UI 侧引擎客户端**。职责四条：

1. **启动探测**：`engine.sock` 已有健康引擎 → 直接连接；没有 → spawn 自己（**同二进制 + `--engine`**，输出重定向到引擎日志）
2. **连接成功后进入「引擎模式」**：UI 只做显示与命令转发
3. **每 tick poll()**：从共享内存读最新帧（BGRA → CGImage）与检测结果
4. **心跳接收**：更新引擎状态；心跳超时/进程重启检测

**回退语义**：任何一步失败 → `isActive` 保持 false → **UI 完全走本地模式（原逻辑不动）**。强制本地模式：环境变量 `AURORA_UI_LOCAL=1`。

**`engineClientLog`（第 25–44 行）**：UI 侧客户端日志，同时写 stdout 与 `~/Library/Logs/AuroraEngineClient.log`——"GUI 进程 stdout 常被缓冲，落盘才能在退出后复查"。格式 `[HH:mm:ss.SSS] [UI-CLIENT] msg`。

**类声明与协议版本（第 46–60 行）**：`@MainActor final class EngineClient`，单例 `static let shared`。

**`protocolVersion = 2`（nonisolated static，第 60 行）——⚠️ 任何命令/心跳字段变更都必须 +1**。为什么需要（51–59 行注释）：UI 与引擎是**两个独立长驻进程**。重编译后旧引擎可能还活着，而 UI 启动时只要 socket 有人应答就直接连上（单例设计）——于是「新 UI 对着旧引擎说话」：新命令被旧引擎丢进 `未知命令类型`，**静默失败**（按钮照常翻转，引擎毫无反应）。

- 版本 1 = 原始（start/stop/bye/status/upscale/ping）
- 版本 2 = 新增 record / reloadmodel / config + 心跳 recording/frames/proto 字段

**UI 读取的状态（第 62–99 行）**——引擎模式下 UI 不跑推理，面板显示靠这些（**引擎是权威源**）：

| 成员 | 说明 |
|---|---|
| `isActive` | 引擎模式已激活（连接成功） |
| `isConnected` | 心跳正常 |
| `engineIsDriving / engineIsStreaming` | 引擎自报驾驶/推流状态 |
| `engineFPS: Double` | 引擎帧率 |
| `engineDetections: [Detection]` | 引擎检测结果 |
| `lastHeartbeat` | 最近心跳时间（默认 `.distantPast`） |
| `enginePID: Int32` | 引擎进程 pid |
| `engineProtocol` | **引擎自报的协议版本（0 = 旧引擎，不发 proto 字段）** |
| `sawHeartbeat` | 是否已经历过至少一次「连接激活 → 收到心跳」的完整周期——**只有它成立时才允许判定版本错配**，避免启动瞬间误判 |
| `engineMode: DriveMode`（默认 .e2e） | 降级档位（引擎是权威源） |
| `engineSpeed / engineSpeedKmh / engineConfidence` | 有效车速（km/h）/ OCR 读数（-1 = 未读到）/ 置信度（0~1） |
| `engineRecording / engineRecordFrames` | 引擎录制状态 / 已写盘帧数（帧在引擎进程里，UI 只负责显示与转发开关） |

**内部状态（101–125 行）**：`socketFD/readSource/lineBuffer`（socket）、`shmBase/shmSize`（共享内存映射）、`frameCache: CGImage?` + `lastFrameSeq` + `frameCountSinceConnect`（帧缓存与去重）、`wantPixelBuffer`（UI 要「像素缓冲」形态的帧——开了插帧时为 true，由 UI 每 tick 设置）、`pendingPixelBuffer` + `cvPool/cvPoolW/cvPoolH`（像素缓冲池）、`connectTimer/connectAttempts`（连接轮询）、`relaunchPoll` + `engineRelaunching`（旧引擎重启轮询与防重复触发标记）。

**静态路径（111–118 行）**：`socketPath` = `~/Library/Application Support/AuroraDrive/engine.sock`、`engineLogPath` = `~/Library/Logs/AuroraEngine.log`。`queue` = `DispatchQueue("aurora.engine.client", qos: .userInteractive)`。

## 二、startup / tryConnect / spawnEngine 与旧引擎重启（第 127–314 行）

**`startup()`（第 130–166 行）**——由 AppDelegate 在 `applicationDidFinishLaunching` 调用（**非阻塞**）：

1. `AURORA_UI_LOCAL=1` → 直接 return（本地模式）
2. `tryConnect()` 成功 → `activate()` → return（已有引擎，直连）
3. 否则 `spawnEngine()` 失败 → return（回退本地模式）；成功 → **异步轮询连接**：0.3s 间隔定时器（leeway 50ms），每次主线程 `tryConnect()`，连上即 `activate()` + 取消定时器；**20 次（6 秒）仍未连上 → 回退本地模式**

**`activate()`（第 168–176 行）**：`isActive = true`、`isConnected = true`、`lastHeartbeat = Date()`、`attachShm()`、日志"✅ 引擎模式已激活"、`onActivated?()`——**重连后主动同步一次画面档位**（UI 可能开着插帧）。`onActivated` 回调（179 行）：UI 用它把当前档位/状态同步给引擎。

**`tryConnect() -> Bool`（第 182–218 行）**：

- `guard socketFD < 0 else { return true }`——已连接幂等
- `socket(AF_UNIX, SOCK_STREAM, 0)` → 组 `sockaddr_un`（同 EngineSocketServer 的路径 memcpy 写法 + 路径过长 guard）→ `connect`
- 成功后：`socketFD = fd`、lineBuffer 清空、DispatchSourceRead 挂 `readSocket()`、resume、**`sendCommand("status")` 主动要一次状态**
- 失败：close + false

**`isEngineStale`（第 226–228 行）**——是否已与「协议版本不匹配的旧引擎」建立过连接：

```swift
var isEngineStale: Bool { sawHeartbeat && engineProtocol != Self.protocolVersion }
```

⚠️ **判定前提必须是 `sawHeartbeat`，不能写 `engineProtocol != 0`**（220–225 行注释）：**旧引擎压根不发 `proto` 字段**，它的心跳让 `engineProtocol` 永远停在 0。若把 0 当"未知、不算错配"，守卫会恰好漏掉「新 UI × 旧引擎」这个唯一需要它生效的场合（**2026-09-12 实测踩坑**）。

**`relaunchStaleEngine()`（第 241–288 行）**——终止协议不匹配的旧引擎，并拉起同版本新引擎。⚠️ **2026-09-12 踩坑记录（第一版写错，导致 UI 陷入无限重启）**：

1. **`bye` 不会让引擎退出**——它只做 `pauseDriving()`，然后等 30 秒空闲才退。所以这里**必须真 kill**，不能靠 bye 商量
2. **必须等旧引擎死透再 startup()**——否则 `tryConnect()` 会又连回旧引擎，形成「连上→发现旧→重启→又连上」的死循环。flock 单例还会让新引擎直接 `exit(0)`（锁被旧引擎持有），新引擎根本起不来
3. **必须重置 `sawHeartbeat`**——否则重启后判定前提仍成立，立刻又判错配

**只在非驾驶状态调用**（驾驶中突然失去引擎比版本错配更危险）。流程：

1. 断开本端连接（`readSource?.cancel()` + close socketFD + `detachShm()` + 取消 connectTimer）——不再依赖 bye
2. 清空全部版本/连接状态（isActive/isConnected/engineProtocol=0/sawHeartbeat=false/lastHeartbeat/enginePID=0）——避免重启后立刻误判（坑 3）
3. **真 kill（坑 1）**：`kill(pid, SIGTERM)`，1.2 秒后仍在则 `kill(pid, SIGKILL)`
4. **轮询等旧引擎死透（坑 2）**：0.4s 间隔，`alive = pid > 0 && kill(pid, 0) == 0`；`!alive || waited >= 8.0` 才 `poll.cancel()` + `engineRelaunching = false` + `startup()`——最多等 8 秒，8 秒未退出仍继续尝试拉起

**`spawnEngine() -> Bool`（第 291–314 行）**：

- `exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()`——**同二进制**（解析符号链接）
- `isExecutableFile` 校验 → `Process()` + `arguments = ["--engine"]` → **stdout/stderr 重定向到引擎日志文件**（FileHandle append 模式）
- `try process.run()` → 记 pid；失败记日志返回 false

## 三、心跳解析 / 共享内存读取 / poll() / 命令发送（第 316–613 行）

**`readSocket()`（第 318–344 行）**：`read(socketFD, &buf, 8192)` → lineBuffer 按行切分（同 EngineSocketServer 的 0x0A 循环）→ **逐行派发主线程 `handleHeartbeatLine`**；`n <= 0`（断开）→ cancel readSource + close + 主线程 `isConnected = false` + `tryReconnectSoon()`。

**`tryReconnectSoon()`（第 346–366 行）**：`guard isActive else { return }`（未激活不重连）→ connectAttempts 归零 → connectTimer 为 nil 时建 0.5s 间隔定时器（leeway 100ms）→ 主线程 `tryConnect()`，连上置 `isConnected = true` + 取消定时器。

**`handleHeartbeatLine(_ line: String)`（第 368–400 行）**——心跳 JSON 解析：

- `guard type == "heartbeat"` → `lastHeartbeat = Date()` + `isConnected = true`
- 逐字段回传（全部 `if let` 可选解包，缺字段不覆盖旧值）：isDriving/isStreaming/fps/modeRaw（`DriveMode(rawValue:)`）/**speed/speedKmh/confidence（引擎模式下 UI 不跑推理，面板/状态栏靠这些刷新）**/recording/frames（**真正的写盘在引擎进程，UI 只负责显示**）/proto（旧引擎不发此字段 → 保持 0）
- `if !sawHeartbeat { sawHeartbeat = true }`——标记「已收到过心跳」：版本错配判定以此为前置
- **引擎重启检测（390–399 行）**：只在「已有 pid 且 pid 变了」时重新映射共享内存（`detachShm()` + `attachShm()`）；首次心跳时 enginePID 还是 0，**不能当成重启**（否则白白多映射一次）——else 分支只记录 pid

**`attachShm()`（第 446–467 行）**：

- `guard shmBase == nil`（幂等）→ `swift_shm_open(EngineFrameShm.name, O_RDONLY, 0)`——**只读打开**（引擎是创建者/写者）
- `fstat` 取 size → `mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)` → **close(fd)（mmap 后可关闭 fd，映射保持有效）** → shmBase/shmSize 记录、lastFrameSeq 归零
- 失败路径：日志"共享内存打开失败（引擎可能尚未创建）"——**不阻塞**，下次心跳重试

**`detachShm()`（第 469–477 行）**：`munmap` + shmBase/shmSize 置 nil/0 + frameCache = nil + lastFrameSeq = 0。

**`copyIntoPixelBuffer(base:offset:w:h:) -> CVPixelBuffer?`（第 405–437 行）**——从共享内存拷到 CVPixelBuffer（池化复用；供 MetalGoose 插帧消费）：

- 池惰性创建：32BGRA + **IOSurfaceProperties**（与 CaptureEngine 的 upscale 池相反——这里加 IOSurface，因为消费方是 MetalGoose）
- 逐行 memcpy：**目标可能有行填充，源侧共享内存是紧凑布局**（`bpr >= w*4`，逐行拷 `copyBytes = w*4`）

**`takePixelBuffer() -> CVPixelBuffer?`（第 440–444 行）**：取出 `pendingPixelBuffer` 并置 nil（**消费一次**；插帧模式用）。

**`poll() -> CGImage?`（第 480–572 行）**——每 tick 调用，拉取最新帧与检测结果：

1. `guard isActive` → **心跳超时检测**：`isConnected && Date().timeIntervalSince(lastHeartbeat) > 3.0` → `isConnected = false`（"⚠️ 引擎心跳超时（失联）"）
2. `guard let base = shmBase else { return frameCache }`——未映射时返回缓存
3. **帧去重**：`seq = base.load(40, u64)`，`seq == lastFrameSeq` → 返回缓存（无新帧复用）；否则更新 lastFrameSeq
4. 读头部：activePage(36)/w(24)/h(28)/pageSize(72)
5. **像素读取按 UI 当前档位二选一（498–526 行）**：
   - `wantPixelBuffer`（开插帧）→ 读成 CVPixelBuffer（直接喂 MetalGoose，省一次大图构造）→ 存 `pendingPixelBuffer`
   - 普通显示 → 读成 CGImage：`Data(bytes:src, count:pageSize)` → `CGDataProvider(data:)` → `CGImage(...premultipliedFirst | byteOrder32Little...shouldInterpolate: false)` → 存 `frameCache`；**首帧打日志**："收到引擎首帧 W×H（帧管道打通）"（frameCountSinceConnect == 1）
   - 边界校验：`off + pageSize <= shmSize` 防越界
6. **检测结果（528–562 行）**：`n = base.load(56, u32)`；`n > 0 || !engineDetections.isEmpty` 才重建数组（检测清零也要清 UI 显示）——逐条读 labelId/conf/cx/cy/bw/bh + rawName（**16 字节遇 0 截断**）→ `Detection(...)`；labelId 反查映射 `1→.car / 2→.pedestrian / 3→.sign / default→.obstacle`
7. **状态标志（564–569 行）**：flags bit0/bit1 → engineIsDriving/engineIsStreaming；fpsMilli > 0 → engineFPS = /1000

**`sendCommand(_ type:extra:)`（第 576–590 行）**：JSON 序列化 `["type": type] + extra` → 行协议（+`\n`）→ `queue.async` 内 `write(fd, ...)`——写盘异步（fd 按值捕获）。

**三个便捷命令（592–612 行）**：

| 方法 | 发送 | 说明 |
|---|---|---|
| `setUpscale(_ on: Bool)` | `upscale` + `{"on": on}` | 告知引擎切换画面档位：开插帧/要清晰画面 → 全分辨率帧；否则 480 宽省带宽 |
| `sendBye()` | `bye` | UI 正常关闭前调用（引擎继续运行） |
| `sendByeSync()` | `bye`（**同步 write**） | **UI 正常退出前同步发送**——不走异步队列（进程即将退出，异步写可能来不及）；引擎收到 bye 后不触发看门狗停车，保持抓屏推理等待下次重连 |

**EngineClient 文档至此完整**（613 行全覆盖：概览与协议版本 → startup/spawn/重启 → 心跳/shm/poll/命令）。