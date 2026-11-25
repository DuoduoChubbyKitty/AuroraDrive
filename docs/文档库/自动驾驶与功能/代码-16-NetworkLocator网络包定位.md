# 代码-16 NetworkLocator 网络包定位

> 覆盖源文件：`Sources/AuroraDrive/Locate/NetworkLocator.swift`。本档所有代码位置均按**真实符号名**引用，不再使用会漂移的行号。

> **符号级复核**：本文所有代码位置均按真实符号（类名／函数名／常量名）引用，不再保留行号。已逐条 grep 验证：`NetworkLocator.swift` 内常量（`kLocalPoseBridgeURL`、`kAPIVersion`、`kCoordinateSampleMaxAge`、`kCalibrationAxes`、`kCalibrationA/B/TX/TY/Error`、`kNorth`、`kEast`、`kMaxLocationAbs`、`kMaxRotationAbs`）、类型（`NetworkLocationResult`、`CoordinateTransform`、`kCoordinateTransform`、`UE5PacketDecoder`、`LocalPoseSocketClient`、`NetworkLocator`）及方法（`decode`、`findCandidates`、`readFloat`、`readBits`、`readVector`、`hasValidRotation`、`extractPose`、`readRotator`、`computeHeading`、`trackingKey`、`newFlowCandidate`、`reacquireCandidates`、`confirmFlow`、`start`、`startWithURLSession`、`readLoop`、`handleMessage`、`read(maxAge:)`、`stats`、`close`、`prepare`、`locate`、`rawToMap`、`mapToRaw`）全部命中。
>
> **跨文件锚点（已 grep 验证）**：`AuroraDriveApp` 的 `runNicAdaptSelfTest()`／`locateSource()`／`runNetworkLocateStep()`／`startDriving()`／`stopDriving()`；`LocateRuntime` 的 `LocateGate`／`LocateContext`；`MapWiring.worldToMapPixelX/Y`／`mapPixelToWorldX/Y`；`CoordinateCapture` 的 `kCalibA/B/TX/TY`／`worldToMapPixel(_:)`。死代码三态判定（§4.0）仍成立：`NetworkLocator(` 在 Sources/ 零实例化，`LocateContext.networkLocator` 字段零读写。
>
> **2026-11 现状更新**：`AuroraDriveApp.swift` 已大幅增长，旧的 `startDriving()`／`stopDriving()`／`runNetworkLocateStep()` 行号锚点全部失效——本档据此改为符号引用。`LocateRuntime.swift` 新增注释明确 `visualLocator`／`networkLocator`／`visualReady`／`activeMode` 四字段恒 nil 或零读取，**只有 `networkReady` 被真实驱动**（详见 §4）。
>
## 一、常量、数据类型与 CoordinateTransform

**私有常量（`NetworkLocator.swift` 顶部 `private let` 块）——与 CoordinateCapture 的对照：**

| 常量 | 本文件值 | 同源对照（CoordinateCapture） |
|---|---|---|
| `kLocalPoseBridgeURL`（原 kMaaNTEServerURL） | `"ws://127.0.0.1"`（端口 9004） | — |
| `kAPIVersion` | `"1.3.0"` | — |
| `kCoordinateSampleMaxAge` | 1.0 秒 | 同语义 |
| `kCalibrationAxes` | `(0, 1)` | — |
| `kCalibrationA` | 0.016394586684750773 | 同（`CoordinateCapture` 的 `kCalibA`） |
| `kCalibrationB` | 5.693519256055879e-08 | 同（`CoordinateCapture` 的 `kCalibB`） |
| `kCalibrationTX` | 6526.474380746091 | 同（`CoordinateCapture` 的 `kCalibTX`） |
| `kCalibrationTY` | 5210.664390686138 | 同（`CoordinateCapture` 的 `kCalibTY`） |
| `kCalibrationError` | 0.22031967781665318 | — |
| `kNorth / kEast` | 北/东单位向量（对齐用） | — |
| `kMaxLocationAbs / kMaxRotationAbs` | 2_000_000 / 180.001 | — |

- **旧帧记录**：map-2026-06 (11264) TX=6293.474380746091, TY=3472.664390686138，扩图平移 (+233,+1738)（`NetworkLocator.swift` 注释；`CoordinateCapture.swift` 同记）。
- **⚠️ B 符号不一致现状（2026-10-06 实核）**：本文件的解码器私有常量 `kCalibrationA/B/TX/TY` 四值与 `CoordinateCapture.swift` 的全局常量**逐位相同**；但本文件 `CoordinateTransform.apply` 的矩阵写法 B 项取**负号**（见下），与 CoordinateCapture/MapWiring 的 `+B` 写法不同——因 |B|≈5.7e-08，数值影响 ≤0.053 px，见文末专节。

**数据类型：**

- `RawPoint = (Double, Double, Double)`、`RawPose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`MapPoint = (Int, Int)`（`NetworkLocator.swift`）
- `NetworkLocationResult`：`found: Bool / point: MapPoint? / rawCoordinate: RawPoint? / score: Double / mode: String / cameraPitch: Double? / cameraHeading: Double? / motionHeading: Double?`（`motionHeading` 为 2026-10-08 新增字段）

**`CoordinateTransform`（struct）**——坐标变换：

- 字段：`axes: (Int, Int)`、`a/b/tx/ty/error`（`NetworkLocator.swift`）
- `apply(_ point: RawPoint) -> (Double, Double)?`：**正变换 `(a*x - b*y + tx, b*x + a*y + ty)`**（`NetworkLocator.swift`）——B 项符号与 `MapWiring.worldToMapPixelX/Y`（`MapWiring.worldToMapPixelX/Y`：`mapX = A·wx + B·wy + TX` / `mapY = A·wy − B·wx + TY`）及 `CoordinateCapture.worldToMapPixel(_:)` **相反**。两套矩阵各自正逆自洽，数值影响 ≤0.053 px，详见文末专节
- `invert(_ point: (Double, Double)) -> (Double, Double)?`：逆变换（地图像素 → 世界坐标）——`guard axes == (0, 1)`、`denom = a² + b² > 1e-12`、`(dx, dy) = point - (tx, ty)` → `((a*dx + b*dy)/denom, (-b*dx + a*dy)/denom)`（`NetworkLocator.swift`）

**`kCoordinateTransform`（private let）**：全局唯一的 CoordinateTransform 实例（用上面的 kCalibration* 常量构造）。

## 二、UE5PacketDecoder 私有副本

**`UE5PacketDecoder`（private final class）**——与 `代码-04` 的 UE5Decoder 同构（同一 MaaNTE 移植源），独立私有副本，**解码修复已与 CoordinateCapture 对齐**。

**状态字段**：flow/lastOffset/lastCaptureTime/lastClientTime/lastLocation + pending 五件套（`UE5PacketDecoder` 成员）。

**`decode(payload:timestamp:flow:) -> RawPose?`**——三分支：

1. 流变化 → newFlowCandidate → confirmFlow（两包确认）→ 切 flow → `extractPose`
2. 首包（lastClientTime/lastCaptureTime 为 nil）→ newFlowCandidate 直接选定 → `extractPose`
3. 跟踪中（`decode` 的三个分支之一）：gap/expected → 候选对齐 `aligned = candidates.filter { $0.offset == lastOffset }`（**修复后按位偏移对位偏移**，`aligned` 过滤）→ 空则退全量候选 → min(by: trackingKey) → timeError > 1.0 时 reacquire（取 clientTime 最大的）→ extractPose

**`findCandidates`**：候选扫描 `for offset in 190..<searchEnd`（`searchEnd = min(512, payload.count*8 − 60)`）；clientTime 有效性防线（isFinite/≥0/<100_000）；加速度必须 scaled；位置向量 scale=100；位置界值 `kMaxLocationAbs`；★ 修复后的 rotation 起始位：`let rotationOffset = cursor`（cursor 即 readVector 返回的结束位，**不再 +7 多加**）。

**位读取工具**：`readFloat`（32 位 float → Double(bitPattern:)）与 `readBits`（指定位偏移读 N 位）——均为 throw 版（越界抛 `DecodeError.outOfBounds`）。

**`readVector`**——UE5 Vector3 解码（throw 版）：7 位 header（width 低 6 位 + scaled 第 7 位）→ `guard width != 0 else { throw fullPrecisionUnsupported }`→ `guard width <= 63` 防御→ 逐分量读 width 位 + **符号扩展走 `Int64(bitPattern:)`**（修复后）→ 返回 (值, cursor 结束位, width, scaled)。

**`hasValidRotation`**：present 标志重放 → `guard flags.1, !flags.2`（Pitch/Yaw 存在，Roll 不存在）→ 直接读 pitch/yaw 16 位（offset+1 / offset+18）→ pitch ≤ 90.001 && yaw ≤ `kMaxRotationAbs`。

**`extractPose`**：加速度向量（bitOffset+32, scale 10）→ 位置向量（cursor1, scale 100）→ readRotator（cursor2）→ `computeHeading`——**修复后链式使用上一步的结束位**；更新状态 → 返回 RawPose。

**`readRotator`**：1 位 present + 16 位压缩角 + 360/65536 + 180 归一。

**`computeHeading`**：视线方向 → kNorth/kEast 点积 → `atan2(eastDot, northDot)` → [0, 360)。

**`trackingKey`**：`timeError + spatialPenalty`（`spatialPenalty = min(distSq/5000², 100)`），返回三元组——`decode` 里只比较第一个元素。

**`newFlowCandidate` / `reacquireCandidates`**：`clientTime >= 0.01 && 位置 ≤ kMaxLocationAbs` 过滤 → 取 clientTime 最大。

**`confirmFlow`**：timeOk/offsetOk/stepOk，pendingSeen >= 2 才确认。

**`DecodeError`（enum）**：`outOfBounds / fullPrecisionUnsupported` 两种解码错误。

## 三、LocalPoseSocketClient 与 NetworkLocator

**`LocalPoseSocketClient`（private final class；原 MaaNTESocketClient，2026-10-04 改名）**——**WebSocket 版本**（不是 libpcap！）：

- `@unchecked Sendable`；内部 `UE5PacketDecoder` 实例（声明了但 handleMessage 直接收 JSON，不走解码器）
- **`start()`**：`#if os(macOS)` + `guard #available(macOS 13.0, *)` → `startWithURLSession()`
- **`startWithURLSession()`**：`URLSession.webSocketTask(with: kLocalPoseBridgeURL)`（**ws 地址 127.0.0.1，端口 9004**）→ resume → `readLoop`
- **`readLoop(task:)`**：`task.receive` 递归续读；failure → 5 秒后 `start()` 重连
- **`handleMessage`**：只处理 `.data` 消息 → JSON 解析 → 协议校验 `version == kAPIVersion("1.3.0")` 且 `mode == "coordinate"` → 读 x/y/z/pitch/heading 五字段 → 锁内写 sample（os_unfair_lock）
- **`read(maxAge:) -> RawPose?`**：锁内取 sample + `now - lastSampleWall <= maxAge` 新鲜度校验（默认 1 秒）
- **`stats()`**：packet/payload/sample 三个 count + 三个 age
- **`close()`**：`task?.cancel()` + `session?.invalidateAndCancel()` + isConnected = false

**`NetworkLocator`（final class）**——网络定位器封装：

- 状态：`ready/isConnected/socketClient/lastLocPos/lastMotionHeading/lastResult`
- **`prepare() -> Bool`**：建 LocalPoseSocketClient + start + ready/isConnected = true——**无条件返回 true**（socket 是否真建立由 read 时的 nil 体现）
- **`locate() -> NetworkLocationResult`**：
  - `socketClient?.read()` 为 nil → 返回 `lastResult ?? (found: false, mode: "coordinate_stale")`
  - rawToMap 失败或姿态非有限 → `(found: false, mode: "coordinate_invalid")`
  - 成功：运动方向估计（`locate()` 内 `motionHeading` 分支）：`lastLocPos` 距离平方 > 16（地图上 >4px）时用 `atan2(dx, -dy)` 从位移反推 **`motionHeading`**（2026-10-08 镜像 bug 修复：地图像素系 y 向下，真北 = −Δy）；位移不足时沿用上次值
  - 结果：`(found: true, point, rawCoordinate, score: 1.0, mode: "coordinate", cameraPitch: pose.3, cameraHeading: pose.4, motionHeading)`（`locate()` 成功分支返回值）
- **`rawToMap(x:y:z:) -> MapPoint?`**：轴校验（`kCalibrationAxes`）→ `kCoordinateTransform.apply` → isFinite → `(Int(round(mapX)), Int(round(mapY)))`。注意：输出是**地图像素**（0~13056），不是世界坐标
- **`mapToRaw(x:y:) -> (Double, Double)?`**：`kCoordinateTransform.invert`（逆变换：地图像素 → 世界坐标）→ isFinite。当前 grep 未见产品代码调用（见文末 B 符号专节的 R4 风险）
- `stats()` / `close()`：透传 socketClient

**⚠️ DualModeLocator 已删除（2026-10-06 实核）**：旧文档记录的 `DualModeLocator`（双模定位器，visual 分支占位）在当前工作树中**不存在**——全仓 `grep -rn "DualModeLocator" Sources/` 零命中，文件在 `NetworkLocator` 类之后即终止。`LocateContext` 现直接持有 `visualLocator: VisualLocator?` 与 `networkLocator: NetworkLocator?` 双实例 + `visualReady` / `networkReady` / `activeMode`，互斥由 `LocateGate` 保证。（2026-11 更新：`LocateGate` 当前实际未生效，见 `LocateRuntime.swift` 注释。）

**给别的 AI 的调用提示**：WebSocket 路线依赖**本机 9004 端口的位姿桥接 WebSocket 服务在跑**——服务不在则 `locate()` 永远返回 coordinate_stale。当前项目里跑着的网络定位实际是 `代码-04 CoordinateCapture`（libpcap 自包含，无外部服务依赖）。真 visual 定位在 `代码-17 VisualLocator`。

**NetworkLocator 文档至此完整**（常量与变换 → `UE5PacketDecoder` → `LocalPoseSocketClient` → `NetworkLocator`）。

## 四、★ 该链路当前状态：**调用点已移除，但"网络定位功能未下线"**（2026-10-07 实核）

> 本节回答"`networkLocator.start()` 是否已移除"。**结论分三层，务必逐层读清——这三层极易混淆**：
> **① 调用链已死**：`NetworkLocator` 类与文件都还在、可编译，但产品代码中已无任何实例化与调用点；
> **② 功能没死**：真正在跑的"网络定位"是**另一条链路 `CoordinateCapture`**（设计上就是网络定位，当前**常开**）；
> **③ 因此不能说"网络定位功能已下线"**——下线的只是 `NetworkLocator` 这条 WebSocket 路径。

### 4.0 三态速查表（⚠️ 最容易混淆的三件事，先看这里）

| # | 对象 | 状态 | 一句话 | 实测出处 |
|---|---|---|---|---|
| ① | `NetworkLocator.start()` **调用点** | ❌ **已移除** | 只剩注释，没人调 | `AuroraDriveApp` 的 `startDriving()` / `stopDriving()` 内各有一行 `// networkLocator.start()` / `// networkLocator.stop()` 注释 |
| ② | **`CoordinateCapture`（网络定位功能本体）** | ✅ **活的、常开** | 懒初始化即 `cc.start()`，成功置 `networkReady=true` | `AuroraDriveApp` 的 `runNetworkLocateStep()` 懒初始化块（注释「纯网络定位，无自愈引擎」） |
| ③ | `NetworkLocator.swift`（WebSocket 路径） | ⚠️ **编译在但零实例化** | 死代码/待复用，`locate()` 无产品调用者 | 全仓 grep `NetworkLocator(` 零实例化（仅 `LocateRuntime` 的 `networkLocator` 字段声明） |

> **⚠️ 命名陷阱（最坑人的一处）**：`LocateContext.networkReady` 如今由 **`CoordinateCapture`** 写（`runNetworkLocateStep()` 内），**不是** `NetworkLocator`。字段名里的 "network" 指的是**网络定位这件事**，不是 `NetworkLocator` 这个类——**看到 `networkReady=true` 不代表 `NetworkLocator` 在跑**。

### 4.1 逐项证据

| 检查项 | 实测结果 | 出处 |
|---|---|---|
| `NetworkLocator.start()` 调用点 | **已移除**，只剩注释 | `AuroraDriveApp` 的 `startDriving()` 内 — `// networkLocator.start()  // 旧网络抓包定位已移除    // 启动网络抓包定位`（在 `captureEngine.start()` 之后、`inferenceEngine.loadIfNeeded()` 之前） |
| `NetworkLocator.stop()` 调用点 | **已移除**，只剩注释 | `AuroraDriveApp` 的 `stopDriving()` 内 — `// networkLocator.stop()   // 旧网络抓包定位已移除`（在 `captureEngine.stop()` 之后） |
| 实例化 `NetworkLocator()` | **全仓零命中**（全仓 grep 零实例化；仅 `LocateRuntime` 的 `networkLocator` 字段有类型声明） | 2026-10-17 实核 |
| 旧实例声明 | 已注释掉 | `AuroraDriveApp` 内注释块 — `// 旧NetworkPacketCapture已移除（不编译），使用移植的NetworkLocator` + `// @ObservationIgnored let networkLocator = NetworkPacketCapture()` |
| 回调接线 | 已注释掉 | `AuroraDriveApp` 内注释块 — `// 旧网络定位已移除` / `// 旧网络定位回调已移除（NetworkPacketCapture不编译）` / `// networkLocator.onLocate = …` / `// networkLocator.onStatusChange = …`（块尾是注释掉的 `dlog("[network] 定位引擎初始化完成")` 与 `}`） |
| 类型声明 | **保留**，但无人赋值 | `LocateRuntime` 的 `LocateContext` — `var networkLocator: NetworkLocator? = nil`（**初始 nil，全仓无任何赋值点**；同类的 `visualLocator` 同样无人赋值） |
| `start()` 方法本体 | **仍然存在** | `LocalPoseSocketClient.start()`；`NetworkLocator.prepare()` 内部会调它 |

### 4.2 当前实际在跑的定位是谁

- **实际活跃**：`代码-04 CoordinateCapture`（libpcap 自包含抓包，无外部服务依赖）。它由 `DriveState.runNetworkLocateStep()` **懒初始化并常开**：判 `coordinateCapture == nil` → `let cc = CoordinateCapture()` → `let ok = cc.start()` → 成功后 `locateCtx.networkReady = true`。
- **`networkReady` 的含义已经变味**：`LocateContext.networkReady` 如今由 **CoordinateCapture** 写（`runNetworkLocateStep()` 内），而**不是** `NetworkLocator`。`locateSource()` 与 `runNetworkLocateStep()` 都以 `networkReady` 为门。⚠️ **命名陷阱：字段叫 networkReady，实际指 CoordinateCapture 就绪。**
- **`NetworkLocator.locate()` 当前无产品调用者**——本文件整套（WebSocket 客户端 + UE5 位流解码）处于**休眠**状态。
- **⚠️ 防误读（再强调一次）**：本节只说明 `NetworkLocator` 休眠；**网络定位功能（CoordinateCapture）是活跃的**。另外 `AuroraDriveApp` 还有 `runNicAdaptSelfTest()` **自检/网卡自适应夹具**（内部 `let cc = CoordinateCapture()` → `let started = cc.start()`，配 `ck("自适应抓包启动", …)` + `cc.probeRounds`），属 `--nic-selftest` 类入口，与产品常开链路不是同一处，勿混计。

### 4.3 与文档其余部分的关系

- 本文第一~三节描述的**代码实体全部有效**（`LocalPoseSocketClient`、`NetworkLocator` 均仍在文件内，已 grep 实测）；**失效的只是"它在产品里被调用"这一前提**。
- **依赖前提仍在**：若将来重新接线，仍需**本机 9004 端口的位姿桥接 WebSocket 服务在跑**（`kLocalPoseBridgeURL` 指向本机 9004 端口的 ws 地址）——服务不在则 `locate()` 永远返回 `coordinate_stale`。
- **"旧网络抓包定位已移除"注释的措辞歧义（诚实记录）**：该注释字面像在说"本文件已删"，实测**文件未被删除**；被移除的是**调用点**。`AuroraDriveApp` 中「旧NetworkPacketCapture已移除（不编译），使用移植的NetworkLocator」这条注释的措辞更准确——即：旧的抓包类被删、移植版 `NetworkLocator` 保留为**候选实现**，但**尚未接线**。两处注释并存，建议以该条表述为准。

### 4.4 本次改动核实

- `Sources/AuroraDrive/Locate/` 目录在 `HEAD~5..HEAD` 范围内**零改动**（`git diff --stat HEAD~5..HEAD -- Sources/AuroraDrive/Locate/` 输出为空，2026-10-07 实测）；工作树亦无未提交改动。该文件最后一次代码改动为 `8de7b06`（2026-10-08，M2 集成：车头朝向鉴定 + `motionHeading`/`cameraHeading` 字段与镜像 bug 修复）。
- 因此本文**"调用点已移除"状态是历史既有事实，不是 10-07 的新改动**——本次只是把它**明确标注**出来。
- ⚠️ **未验证**：`LocateContext.networkLocator` / `visualLocator` 两个字段是否有**计划中**的接线（未找到 TODO/注释说明），本轮无法判断是"暂缓"还是"已放弃"。

### 4.5 D7b 补完：三态自检清单（2026-10-07 实测）

| 论断 | 状态 |
|---|---|
| `NetworkLocator.start()`/`stop()` 调用点只剩注释 | ✅ `startDriving()` / `stopDriving()` 内注释实测 |
| `grep -rn "NetworkLocator(" Sources/` = 0 命中 | ✅ 实测计数 0 |
| **`CoordinateCapture` 由 `runNetworkLocateStep()` 懒初始化并常开** | ✅ 逐行实测（注释「纯网络定位」、`CoordinateCapture()`+`cc.start()`、`networkReady=true`） |
| **"网络定位功能未下线"** | ✅ 由上两条共同支撑（链路 ① 死、功能 ② 活） |
| `LocateContext.networkReady` 由 CoordinateCapture 写、而非 NetworkLocator | ✅ `LocateRuntime` 声明 + `runNetworkLocateStep()` 写点 |
| `LocalPoseSocketClient`、`NetworkLocator` 均在文件内 | ✅ grep 实测 |
| `NetworkLocator.prepare()` 内部调 `start()` | ✅ 实测 `prepare()`：`socketClient = LocalPoseSocketClient()`、`socketClient?.start()`、`isConnected = true`、无条件 `return true` |
| 重启接线是否有计划 | ⚠️ **未验证**（同上 4.4 末条） |

## 附：B 符号不一致现状（2026-10-06 逐行核实）

- **现状（已确认）**：存在两套符号约定，均为**正确实现**，只是矩阵定义写法不同：
  1. `MapWiring.worldToMapPixelX/Y`：`mapX = A·wx + B·wy + TX`，`mapY = A·wy − B·wx + TY`。其自推逆变换 `wx=(A·dx−B·dy)/det`、`wy=(B·dx+A·dy)/det`（`MapWiring.mapPixelToWorldX/Y`）与该方程组严格匹配，`CoordinateCapture.worldToMapPixel(_:)` 同符号。
  2. `NetworkLocator.swift` 的 `CoordinateTransform.apply`：`(a·x − b·y + tx, b·x + a·y + ty)`——B 项符号与 MapWiring 相反（见 `rawToMap` 内 `kCoordinateTransform.apply` 调用）。它同样来自上游 MaaNTE 标定语义（文件头注释），对该矩阵而言 `CoordinateTransform.invert` 自洽。
- **数值影响**：|B| = 5.69e-08；取定位界值 `kMaxLocationAbs` = 2e6，|B·wy| 最大约 0.114 px；对 1e5 量级的典型坐标差 ≈0.0057 px（`MapWiring` 注释称 ~0.006 px）。任务给定「影响 ≤0.053 px」与以上估算同量级——无论取哪个界，都远低于任何可见阈值。
- **结论**：`NetworkLocator` 的 B 符号「相反」只是与 MapWiring 的书写约定不同，两套各自正逆自洽；产品代码中 MapWiring 已不用 `CoordinateTransform.invert`（自推逆在 `MapWiring.mapPixelToWorldX/Y`），**现状无功能性 bug，仅注释/文档层面的符号不一致**。
- **遗留注释漂移（未验证是否有意）**：`MapWiring.swift` 注释提到 `CoordinateTransform.invert`（在 `NetworkLocator.swift`）——两处符号本身存在，行号引用已过时。

---

## 附：符号索引（按真实名字定位，不再使用行号）

### NetworkLocator.swift 内部单元

| 单元 | 符号 / 说明 |
|---|---|
| 常量组一 | `kLocalPoseBridgeURL` / `kAPIVersion` / `kCoordinateSampleMaxAge` |
| 标定常量 | `kCalibrationAxes` / `kCalibrationA` / `kCalibrationB` / `kCalibrationTX` / `kCalibrationTY` / `kCalibrationError`（含旧帧注释） |
| 基向量与界值 | `kNorth` / `kEast` / `kMaxLocationAbs` / `kMaxRotationAbs` |
| 类型别名 | `typealias RawPoint` / `RawPose` / `MapPoint` |
| 定位结果 | `struct NetworkLocationResult`（含 `motionHeading` 字段） |
| 坐标变换 | `struct CoordinateTransform`（`apply` / `invert`） |
| 全局实例 | `private let kCoordinateTransform` |
| 解码器 | `UE5PacketDecoder`（private final class） |
| 解码方法 | `decode` / `findCandidates` |
| 位读取 | `readFloat` / `readBits` / `readVector` |
| 姿态与旋转 | `hasValidRotation` / `extractPose` / `readRotator` |
| 朝向与打分 | `computeHeading` / `trackingKey` |
| 候选管理 | `newFlowCandidate` / `reacquireCandidates` / `confirmFlow` |
| 错误类型 | `enum DecodeError` |
| WebSocket 客户端 | `LocalPoseSocketClient`（private final class） |
| 客户端方法 | `start` / `startWithURLSession` / `readLoop` / `handleMessage` |
| 客户端其余 | `read(maxAge:)` / `stats()` / `close()` |
| 定位器 | `NetworkLocator`（final class） |
| 定位器方法 | `prepare()` / `locate()` |
| 定位器其余 | `rawToMap` / `mapToRaw` / `stats()` / `close()` |

### 调用链相关（App / LocateRuntime / MapWiring / CoordinateCapture）

| 文件 | 符号 |
|---|---|
| `AuroraDriveApp.swift` | `runNicAdaptSelfTest()`（自检夹具，内部 `CoordinateCapture()` / `cc.start()`） |
| `AuroraDriveApp.swift` | `locateSource()`（以 `networkReady` 为门） |
| `AuroraDriveApp.swift` | `runNetworkLocateStep()`（懒初始化 `CoordinateCapture`，置 `networkReady=true`） |
| `AuroraDriveApp.swift` | 旧实例声明注释（`// @ObservationIgnored let networkLocator = NetworkPacketCapture()`） |
| `AuroraDriveApp.swift` | 旧回调接线注释（`// networkLocator.onLocate` / `.onStatusChange`） |
| `AuroraDriveApp.swift` | `startDriving()` / `stopDriving()`（内含 `// networkLocator.start()` / `.stop()` 注释） |
| `LocateRuntime.swift` | `LocateGate`；`LocateContext`（`visualLocator` / `networkLocator` / `visualReady` / `networkReady` / `activeMode`） |
| `MapWiring.swift` | `worldToMapPixelX/Y` |
| `MapWiring.swift` | `mapPixelToWorldX/Y`（自推逆变换） |
| `CoordinateCapture.swift` | `kCalibA/B/TX/TY` |
| `CoordinateCapture.swift` | `worldToMapPixel(_:)` |

> 生成方式：逐条 grep 符号实测于当前工作树；源文件最后改动：`NetworkLocator.swift` 8de7b06（2026-10-08，M2 车头朝向/motionHeading），`VisualLocator.swift` 2026-08-26（`ls -la` mtime）。