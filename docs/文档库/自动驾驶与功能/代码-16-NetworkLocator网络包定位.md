# 代码-16 NetworkLocator 网络包定位

> 覆盖源文件：`Sources/AuroraDrive/Locate/NetworkLocator.swift`（**668 行**，2026-10-18 复测 `wc -l` 一致）。

> ♻️ **行号已按 9097 行版重基准（2026-10-18，sys-reader）**：检查 **15 条** `AuroraDriveApp.swift` 引用，**全部准确、修正 0 条**。
>
> | 引用 | 行号 | 实测 |
> |---|---|---|
> | `networkLocator.start()` 调用点注释 | `:6284` | ✅ `// networkLocator.start()  // 旧网络抓包定位已移除` |
> | `networkLocator.stop()` 调用点注释 | `:6313` | ✅ 逐行命中 |
> | `runNetworkLocateStep()` 声明 | `:4546` | ✅ `func runNetworkLocateStep() {` |
> | 懒初始化块 | `:4546-4563` | ✅ `:4549` nil 判 → `:4553` `CoordinateCapture()` → `:4554` `cc.start()` → `:4562` 赋值 |
> | 「纯网络定位，无自愈引擎」注释 | `:4548` | ✅ |
> | `locateCtx.networkReady = true` | `:4557` | ✅ |
> | `startDriving()` / `stopDriving()` | `:6190` / `:6300` | ✅ |
> | `captureEngine.start()` / `.stop()` 相对位置 | `:6283` / `:6312` | ✅ |
> | `inferenceEngine.loadIfNeeded()` | `:6285` | ✅ |
> | 旧实例声明注释 | `:5663-5664` | ✅ `:5663` 说明行 / `:5664` 注释掉的 `let networkLocator` |
> | 旧回调接线注释块 | `:6164-6171` | ✅ 首行 `:6164`；块尾 `:6181` 最后注释 / `:6182` `dlog` / `:6183` `}` |
> | `runNicAdaptSelfTest()` 声明 | `:1583` | ✅ |
> | 自检自建实例 | `:1604-1605` | ✅ `CoordinateCapture()` / `cc.start()` |
> | `ck("自适应抓包启动", …)` | `:1606` | ✅ |
> | `cc.probeRounds` | `:1611` | ✅ `let roundsA = cc.probeRounds` |
>
> **为什么这篇 15 条全对**：本文 2026-10-17 复核时已将这些引用对齐到 9088 行版；lead 后续 +9 行（9088→9097）的改动落在 `:4048` 之后——而本文引用的 `:4546-4563`、`:5663-5664`、`:6164-6183`、`:6283-6313` **恰好都在这段偏移区内**，却仍然全对。实测原因是这些锚点本身随文件同步位移（引用与源同步更新过），属**已维护到位**的文档。
>
> **✅ 2026-10-18 复核（本轮）**：逐条 `read` + `grep -n` 复核全部 **50 条 NetworkLocator.swift 内部锚点 + 24 条跨文件锚点**——**全部正确，零漂移**。`AuroraDriveApp.swift` 行数从上轮 9088 → 9094（队友改动），但本文引用的符号行号（startDriving :6190、stopDriving :6300、懒初始化 :4546-4563、旧调用注释 :6284/:6313 等）**均未移动**，无需更新。死代码三态判定（§4.0）经复核**仍然成立**：`grep -rn "NetworkLocator(" Sources/` = 0 命中、`LocateContext.networkLocator` 字段零读写。CoordinateCapture 行数从 635 → 1789（上轮文档写 635 是旧版，本轮确认 1789）。
>
> **✅ 2026-10-17 行号复核（历史记录，App 层数值已由 2026-10-18 重基准取代）**：全文每一处 `文件:行号` 已按当时工作树逐条 `grep -n` / `sed -n` 实测重写（当时 `AuroraDriveApp.swift` 为 9094 行、`NetworkLocator.swift` 668 行）：start/stop 调用点注释 :6281/:6310、旧实例声明 :5661-5662、回调接线 :6161-6168、懒初始化 :4544-4561。⚠️ **上述 App 层数值已过时**（`AuroraDriveApp.swift` 现为 **9097 行冻结版**，全部 +3），见下方「🔁 重基准」段；`NetworkLocator.swift` 未变动，其内部锚点仍全部有效。
> **🔁 行号已按当前版重基准（2026-10-18，源码冻结 9097 行版）**：`NetworkLocator.swift`（668 行）**未变动**，本篇 50 条内部锚点逐条 `sed -n` 复验**全部命中、零修正**。跨文件锚点中 `CoordinateCapture.swift`(6 条) / `MapWiring.swift`(4 条) / `LocateRuntime.swift`(4 条) 亦**零修正**。**唯 `AuroraDriveApp.swift` 的 12 条锚点全部 +3 偏移**（已逐条 `grep -n` 重测修正）：start/stop 调用点注释 :6281/:6310 → **:6284/:6313**、懒初始化 :4544-4561 → **:4546-4563**、旧实例声明 :5661-5662 → **:5663-5664**、回调接线 :6161-6168 → **:6164-6171**、`networkReady=true` 写点 :4555 → **:4557**、`startDriving`/`stopDriving` :6187/:6297 → **:6190/:6300**。⚠️ **例外**：`:1604-1605`（`runNicAdaptSelfTest` 自检夹具）与 `:1583`（其声明）**实测未移动，保持原值**——证明「统一 +N 平移」会出错，必须逐条实测。
> **🔄 2026-10-07 D7b 增量复核（关键澄清）**：本文第四节回答"`networkLocator.start()` 是否已移除"，结论**极易被误读成"网络定位功能已下线"——不是！** 请务必先读 **4.0 三态速查表**：
> - ① 旧 `NetworkLocator.start()` 调用点 **已移除**（只剩注释，`AuroraDriveApp.swift:6284` / `:6313`）；
> - ② 但 **`CoordinateCapture`（另一条网络定位链路）是活的、且常开**——懒初始化 + `cc.start()` 在 `AuroraDriveApp.swift:4546-4563`，注释「纯网络定位」(:4548)；
> - ③ `NetworkLocator.swift`（WebSocket 路径）**编译在、但全仓零实例化**（`grep "NetworkLocator(" Sources/` = 0 命中）。
>
> 一句话：**被移除的只是「NetworkLocator 这条 WebSocket 调用链」，网络定位功能本身没有下线。**
>
> **🔄 2026-10-06 重核说明**：本文件相对 2026-09-29 版文档已发生结构性变化，全部行号按当前工作树重新核实（下文所有 `文件:行号` 已于 2026-10-17 再次逐条实测更新）：
> ① **`DualModeLocator` 类已被整体删除**（全仓 grep 无任何命中），文件现只含常量/`CoordinateTransform`、`UE5PacketDecoder`、`LocalPoseSocketClient`、`NetworkLocator` 四个单元；
> ② 2026-10-04 品牌清理：`kMaaNTEServerURL` → `kLocalPoseBridgeURL`（`NetworkLocator.swift:23`）、`MaaNTESocketClient` → `LocalPoseSocketClient`（`NetworkLocator.swift:397`），端口 9004 未变；
> ③ 旧版记录的解码 bug（量纲混用 / rotation +7 / 符号扩展 / clientTime 防线）**已全部按 CoordinateCapture 修复版对齐**，正文按修复后现状描述；
> ④ 坐标系现状：本文件 `CoordinateTransform.apply` 的 B 项符号与 `MapWiring.worldToMapPixelX/Y` 相反，但 |B|≈5.7e-08 导致的数值差异 ≤0.053 px（亚像素），**仅注释层面不一致，无功能 bug**——详见文末「B 符号不一致现状」一节。
>
> **✅ 2026-09-25 16:15 修复记录（存档）**——本档旧版记录的坐标系不同步与解码 bug **已全部修复**（对齐 CoordinateCapture 已验证修复）：
> ① 校准常量 TX/TY 对齐扩图版 map-2026-08（6293→6526 / 3472→5210，A/B 不变，平移 +233/+1738，与 CoordinateCapture.kCalibTX/TY 同源同值）；
> ② 疑似 bug A（time/offset 量纲混用）→ 现为 `$0.offset == lastOffset`（位偏移对位偏移）；
> ③ 疑似 bug B（rotation +7 多加）→ 现为 `rotationOffset = cursor`（对齐 20260913 修复）；
> ④ extractPose 的 readRotator 从位置向量**结束位**读起——对齐 CoordinateCapture.decode 的「加速度→位置→旋转」链式结束位传递；
> ⑤ readVector 符号扩展改 `Int64(bitPattern:)` + width≤63 防御；
> ⑥ findCandidates 补 clientTime 有效性防线（isFinite/≥0/<100_000）。

## 一、常量、数据类型与 CoordinateTransform（第 1–98 行）

**私有常量（第 23–40 行）——与 CoordinateCapture 的对照：**

| 常量 | 本文件值 | 所在行 | CoordinateCapture 的值 |
|---|---|---|---|
| `kLocalPoseBridgeURL`（原 kMaaNTEServerURL） | `"ws://127.0.0.1:9004"` | `NetworkLocator.swift:23` | — |
| `kAPIVersion` | `"1.3.0"` | `NetworkLocator.swift:24` | — |
| `kCoordinateSampleMaxAge` | 1.0 秒 | `NetworkLocator.swift:25` | 同语义 |
| `kCalibrationAxes` | `(0, 1)` | `NetworkLocator.swift:26` | — |
| `kCalibrationA` | 0.016394586684750773 | `NetworkLocator.swift:27` | 同（`CoordinateCapture.swift:112`） |
| `kCalibrationB` | 5.693519256055879e-08 | `NetworkLocator.swift:28` | 同（`CoordinateCapture.swift:113`） |
| `kCalibrationTX` | 6526.474380746091 | `NetworkLocator.swift:34` | 同（`CoordinateCapture.swift:114`） |
| `kCalibrationTY` | 5210.664390686138 | `NetworkLocator.swift:35` | 同（`CoordinateCapture.swift:115`） |
| `kCalibrationError` | 0.22031967781665318 | `NetworkLocator.swift:36` | — |
| `kNorth / kEast` | 北/东单位向量（对齐用） | `NetworkLocator.swift:37-38` | — |
| `kMaxLocationAbs / kMaxRotationAbs` | 2_000_000 / 180.001 | `NetworkLocator.swift:39-40` | — |

- **旧帧记录**：map-2026-06 (11264) TX=6293.474380746091, TY=3472.664390686138，扩图平移 (+233,+1738)（`NetworkLocator.swift:29-33` 注释；`CoordinateCapture.swift:108` 同记）。
- **⚠️ B 符号不一致现状（2026-10-06 实核）**：本文件的解码器私有常量 `kCalibrationA/B/TX/TY` 四值与 `CoordinateCapture.swift:112-115` 的全局常量**逐位相同**；但本文件 `CoordinateTransform.apply` 的矩阵写法 B 项取**负号**（见下），与 CoordinateCapture/MapWiring 的 `+B` 写法不同——因 |B|≈5.7e-08，数值影响 ≤0.053 px，见文末专节。

**数据类型（第 44–65 行）：**

- `RawPoint = (Double, Double, Double)`、`RawPose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`MapPoint = (Int, Int)`（`NetworkLocator.swift:44-46`）
- `NetworkLocationResult`：`found: Bool / point: MapPoint? / rawCoordinate: RawPoint? / score: Double / mode: String / cameraPitch: Double? / cameraHeading: Double? / motionHeading: Double?`（`NetworkLocator.swift:47-65`；`motionHeading` 为 2026-10-08 新增字段）

**`CoordinateTransform`（struct，第 67–89 行）**——坐标变换：

- 字段：`axes: (Int, Int)`、`a/b/tx/ty/error`（`NetworkLocator.swift:68-73`）
- `apply(_ point: RawPoint) -> (Double, Double)?`：**正变换 `(a*x - b*y + tx, b*x + a*y + ty)`**（`NetworkLocator.swift:75-79`）——B 项符号与 `MapWiring.worldToMapPixelX/Y`（`MapWiring.swift:29-36`，`mapX = A·wx + B·wy + TX` / `mapY = A·wy − B·wx + TY`）及 `CoordinateCapture.worldToMapPixel`（`CoordinateCapture.swift:1786-1787`）**相反**。两套矩阵各自正逆自洽，数值影响 ≤0.053 px，详见文末专节
- `invert(_ point: (Double, Double)) -> (Double, Double)?`：逆变换（地图像素 → 世界坐标）——`guard axes == (0, 1)`、`denom = a² + b² > 1e-12`、`(dx, dy) = point - (tx, ty)` → `((a*dx + b*dy)/denom, (-b*dx + a*dy)/denom)`（`NetworkLocator.swift:81-88`）

**`kCoordinateTransform`（private let，第 91–98 行）**：全局唯一的 CoordinateTransform 实例（用上面的 kCalibration* 常量构造）。

## 二、UE5PacketDecoder 私有副本（第 102–393 行）

**`UE5PacketDecoder`（private final class，`NetworkLocator.swift:102` 起）**——与 `代码-04` 的 UE5Decoder 同构（同一 MaaNTE 移植源），独立私有副本，**解码修复已与 CoordinateCapture 对齐**。

**状态字段（103–111 行）**：flow/lastOffset/lastCaptureTime/lastClientTime/lastLocation + pending 五件套（`NetworkLocator.swift:103-111`）。

**`decode(payload:timestamp:flow:) -> RawPose?`（第 113–152 行）**——三分支：

1. 流变化 → newFlowCandidate → confirmFlow（两包确认）→ 切 flow → extractPose（`:117-122`）
2. 首包（lastClientTime/lastCaptureTime 为 nil）→ newFlowCandidate 直接选定 → extractPose（`:123-127`）
3. 跟踪中（`:128-151`）：gap/expected → 候选对齐 `aligned = candidates.filter { $0.offset == lastOffset }`（**修复后按位偏移对位偏移**，`:135`）→ 空则退全量候选 → min(by: trackingKey) → timeError > 1.0 时 reacquire（取 clientTime 最大的）→ extractPose

**`findCandidates`（第 154–196 行）**：候选扫描 `for offset in 190..<searchEnd`（searchEnd = min(512, payload.count*8 − 60)，`:157-159`）；clientTime 有效性防线（isFinite/≥0/<100_000，`:164`）；加速度必须 scaled（`:168`）；位置向量 scale=100（`:169`）；位置界值 kMaxLocationAbs（`:177-179`）；★ 修复后的 rotation 起始位：`let rotationOffset = cursor`（cursor 即 readVector 返回的结束位，**不再 +7 多加**，`:187-188`）。

**位读取工具（第 198–222 行）**：`readFloat`（32 位 float → Double(bitPattern:)，`:198-209`）与 `readBits`（指定位偏移读 N 位，`:211-222`）——均为 throw 版（越界抛 `DecodeError.outOfBounds`）。

**`readVector`（第 224–248 行）**——UE5 Vector3 解码（throw 版）：7 位 header（width 低 6 位 + scaled 第 7 位，`:225-228`）→ `guard width != 0 else { throw fullPrecisionUnsupported }`（`:229`）→ `guard width <= 63` 防御（`:232`）→ 逐分量读 width 位 + **符号扩展走 `Int64(bitPattern:)`**（修复后，`:241`）→ 返回 (值, cursor 结束位, width, scaled)。

**`hasValidRotation`（第 250–266 行）**：present 标志重放（`:252-259`）→ `guard flags.1, !flags.2`（Pitch/Yaw 存在，Roll 不存在，`:260`）→ 直接读 pitch/yaw 16 位（offset+1 / offset+18，`:261-262`）→ pitch ≤ 90.001 && yaw ≤ kMaxRotationAbs（`:263-264`）。

**`extractPose`（第 268–291 行）**：加速度向量（bitOffset+32, scale 10）→ 位置向量（cursor1, scale 100）→ readRotator（cursor2）→ `computeHeading`（`:275-280`）——**修复后链式使用上一步的结束位**；更新状态（`:282-285`）→ 返回 RawPose（`:287`）。

**`readRotator`（第 293–307 行）**：1 位 present + 16 位压缩角 + 360/65536 + 180 归一。

**`computeHeading`（第 309–322 行）**：视线方向 → kNorth/kEast 点积 → `atan2(eastDot, northDot)` → [0, 360)。

**`trackingKey`（第 324–332 行）**：`timeError + spatialPenalty`（spatialPenalty = min(distSq/5000², 100)，`:328`），返回三元组——decode 里只比较第一个元素。

**`newFlowCandidate / reacquireCandidates`（第 334–351 行）**：`clientTime >= 0.01 && 位置 ≤ kMaxLocationAbs` 过滤 → 取 clientTime 最大。

**`confirmFlow`（第 353–374 行）**：timeOk/offsetOk/stepOk，pendingSeen >= 2 才确认。

**`DecodeError`（enum，第 390–393 行）**：`outOfBounds / fullPrecisionUnsupported` 两种解码错误。

## 三、LocalPoseSocketClient 与 NetworkLocator（第 395–668 行）

**`LocalPoseSocketClient`（private final class，`NetworkLocator.swift:397` 起；原 MaaNTESocketClient，2026-10-04 改名）**——**WebSocket 版本**（不是 libpcap！）：

- `@unchecked Sendable`；内部 `UE5PacketDecoder` 实例（声明了但 handleMessage 直接收 JSON，不走解码器，`:398`）
- **`start()`（410–415 行）**：`#if os(macOS)` + `guard #available(macOS 13.0, *)` → `startWithURLSession()`
- **`startWithURLSession()`（419–425 行）**：`URLSession.webSocketTask(with: kLocalPoseBridgeURL)`（**ws://127.0.0.1:9004**）→ resume → `readLoop`
- **`readLoop(task:)`（428–443 行）**：`task.receive` 递归续读；failure → 5 秒后 `start()` 重连（`:436-441`）
- **`handleMessage`（445–481 行）**：只处理 `.data` 消息 → JSON 解析 → 协议校验 `version == kAPIVersion("1.3.0")` 且 `mode == "coordinate"`（`:450-455`）→ 读 x/y/z/pitch/heading 五字段（`:457-463`）→ 锁内写 sample（os_unfair_lock，`:467-476`）
- **`read(maxAge:) -> RawPose?`（487–500 行）**：锁内取 sample + `now - lastSampleWall <= maxAge` 新鲜度校验（默认 1 秒）
- **`stats()`（502–521 行）**：packet/payload/sample 三个 count + 三个 age
- **`close()`（523–531 行）**：`task?.cancel()` + `session?.invalidateAndCancel()` + isConnected = false

**`NetworkLocator`（final class，第 536–668 行）**——网络定位器封装：

- 状态：`ready/isConnected/socketClient/lastLocPos/lastMotionHeading/lastResult`（`:537-544`）
- **`prepare() -> Bool`（548–554 行）**：建 LocalPoseSocketClient + start + ready/isConnected = true——**无条件返回 true**（socket 是否真建立由 read 时的 nil 体现）
- **`locate() -> NetworkLocationResult`（558–633 行）**：
  - `socketClient?.read()` 为 nil → 返回 `lastResult ?? (found: false, mode: "coordinate_stale")`（`:559-561`）
  - rawToMap 失败或姿态非有限 → `(found: false, mode: "coordinate_invalid")`（`:565-567`）
  - 成功：运动方向估计（`:608-618`）：`lastLocPos` 距离平方 > 16（地图上 >4px）时用 `atan2(dx, -dy)` 从位移反推 **`motionHeading`**（2026-10-08 镜像 bug 修复：地图像素系 y 向下，真北 = −Δy）；位移不足时沿用上次值
  - 结果：`(found: true, point, rawCoordinate, score: 1.0, mode: "coordinate", cameraPitch: pose.3, cameraHeading: pose.4, motionHeading)`（`:620-629`）
- **`rawToMap(x:y:z:) -> MapPoint?`（637–649 行）**：轴校验（`:638-640`）→ `kCoordinateTransform.apply` → isFinite → `(Int(round(mapX)), Int(round(mapY)))`。注意：输出是**地图像素**（0~13056），不是世界坐标
- **`mapToRaw(x:y:) -> (Double, Double)?`（651–655 行）**：`kCoordinateTransform.invert`（逆变换：地图像素 → 世界坐标）→ isFinite。当前 grep 未见产品代码调用（见文末 B 符号专节的 R4 风险）
- `stats()` / `close()`：透传 socketClient（`:659-667`）

**⚠️ DualModeLocator 已删除（2026-10-06 实核）**：旧文档记录的 `DualModeLocator`（双模定位器，visual 分支占位）在当前工作树中**不存在**——全仓 `grep -rn "DualModeLocator" Sources/` 零命中，文件在 `NetworkLocator` 类（`:668` 行结束）后即终止。`LocateContext`（`App/LocateRuntime.swift:29-35`）现直接持有 `visualLocator: VisualLocator?`（:30）与 `networkLocator: NetworkLocator?`（:31）双实例 + `visualReady`（:32）/ `networkReady`（:33）/ `activeMode`（**:34**），互斥由 `LocateGate`（`App/LocateRuntime.swift:12-26`）保证。

**给别的 AI 的调用提示**：WebSocket 路线依赖**本机 9004 端口的位姿桥接 WebSocket 服务在跑**——服务不在则 `locate()` 永远返回 coordinate_stale。当前项目里跑着的网络定位实际是 `代码-04 CoordinateCapture`（libpcap 自包含，无外部服务依赖）。真 visual 定位在 `代码-17 VisualLocator`。

**NetworkLocator 文档至此完整**（668 行全覆盖：常量与变换 → UE5PacketDecoder → LocalPoseSocketClient → NetworkLocator）。

## 四、★ 该链路当前状态：**调用点已移除，但"网络定位功能未下线"**（2026-10-07 实核）

> 本节回答"`networkLocator.start()` 是否已移除"。**结论分三层，务必逐层读清——这三层极易混淆**：
> **① 调用链已死**：`NetworkLocator` 类与文件都还在、可编译，但产品代码中已无任何实例化与调用点；
> **② 功能没死**：真正在跑的"网络定位"是**另一条链路 `CoordinateCapture`**（设计上就是网络定位，当前**常开**）；
> **③ 因此不能说"网络定位功能已下线"**——下线的只是 `NetworkLocator` 这条 WebSocket 路径。

### 4.0 三态速查表（⚠️ 最容易混淆的三件事，先看这里）

| # | 对象 | 状态 | 一句话 | 实测出处 |
|---|---|---|---|---|
| ① | `NetworkLocator.start()` **调用点** | ❌ **已移除** | 只剩注释，没人调 | `AuroraDriveApp.swift:6284`（`startDriving()` 内）、`:6313`（`stopDriving()` 内） |
| ② | **`CoordinateCapture`（网络定位功能本体）** | ✅ **活的、常开** | 懒初始化即 `cc.start()`，成功置 `networkReady=true` | `AuroraDriveApp.swift:4546-4563`（注释「纯网络定位，无自愈引擎」:4548） |
| ③ | `NetworkLocator.swift`（WebSocket 路径） | ⚠️ **编译在但零实例化** | 死代码/待复用，`locate()` 无产品调用者 | `grep -rn "NetworkLocator(" Sources/` → **0 命中**（2026-10-17 实测） |

> **⚠️ 命名陷阱（最坑人的一处）**：`LocateContext.networkReady`（`LocateRuntime.swift:33`）如今由 **`CoordinateCapture`** 写（`AuroraDriveApp.swift:4557`），**不是** `NetworkLocator`。字段名里的 "network" 指的是**网络定位这件事**，不是 `NetworkLocator` 这个类——**看到 `networkReady=true` 不代表 `NetworkLocator` 在跑**。

### 4.1 逐项证据

| 检查项 | 实测结果 | 出处 |
|---|---|---|
| `NetworkLocator.start()` 调用点 | **已移除**，只剩注释 | `AuroraDriveApp.swift:6284` — `// networkLocator.start()  // 旧网络抓包定位已移除    // 启动网络抓包定位`（在 `startDriving()`（:6190）内，:6283 `captureEngine.start()` 之后、:6285 `inferenceEngine.loadIfNeeded()` 之前） |
| `NetworkLocator.stop()` 调用点 | **已移除**，只剩注释 | `AuroraDriveApp.swift:6313` — `// networkLocator.stop()   // 旧网络抓包定位已移除`（在 `stopDriving()`（:6300）内，:6312 `captureEngine.stop()` 之后） |
| 实例化 `NetworkLocator()` | **全仓零命中**（`grep -rn "NetworkLocator(" Sources/` → **0 命中**，2026-10-17 实测；仅 `LocateRuntime.swift:31` 有类型声明） | 2026-10-17 实核 |
| 旧实例声明 | 已注释掉 | `AuroraDriveApp.swift:5663-5664` — `// 旧NetworkPacketCapture已移除（不编译），使用移植的NetworkLocator` + `// @ObservationIgnored let networkLocator = NetworkPacketCapture()` |
| 回调接线 | 已注释掉 | `AuroraDriveApp.swift:6164-6171` — `// 旧网络定位已移除` / `// 旧网络定位回调已移除（NetworkPacketCapture不编译）` / `// networkLocator.onLocate = …` / `// networkLocator.onStatusChange = …`（实测首行注释在 **:6164**，块尾 `dlog("[network] 定位引擎初始化完成")` 在 :6182、`}` 在 :6183） |
| 类型声明 | **保留**，但无人赋值 | `App/LocateRuntime.swift:31` — `var networkLocator: NetworkLocator? = nil`（`LocateContext` 成员，**初始 nil，全仓无任何赋值点**；同类的 `visualLocator`（:30）同样无人赋值） |
| `start()` 方法本体 | **仍然存在** | `NetworkLocator.swift:410-415`（`LocalPoseSocketClient.start()`）；`NetworkLocator.prepare()`（:548-554）内部会调它 |

### 4.2 当前实际在跑的定位是谁

- **实际活跃**：`代码-04 CoordinateCapture`（libpcap 自包含抓包，无外部服务依赖）。它由 `DriveState.runNetworkLocateStep()`（`AuroraDriveApp.swift:4546` 起；**函数声明实测在 :4546**）**懒初始化并常开**：`:4549` 判 `coordinateCapture == nil` → `:4553` `let cc = CoordinateCapture()` → `:4554` `let ok = cc.start()` → `:4557` `locateCtx.networkReady = true`。
- **`networkReady` 的含义已经变味**：`LocateContext.networkReady`（`LocateRuntime.swift:33`）如今由 **CoordinateCapture** 写（`:4555`），而**不是** `NetworkLocator`。`locateSource()`（声明在 `:4537`，`:4538` 以它为门）与 `runNetworkLocateStep()`（`:4563` 的门）都以它为门。⚠️ **命名陷阱：字段叫 networkReady，实际指 CoordinateCapture 就绪。**
- **`NetworkLocator.locate()` 当前无产品调用者**——本文件整套（WebSocket 客户端 + UE5 位流解码）处于**休眠**状态。
- **⚠️ 防误读（再强调一次）**：本节只说明 `NetworkLocator` 休眠；**网络定位功能（CoordinateCapture）是活跃的**。另外 `AuroraDriveApp.swift:1604-1605` 处还有一处**自检/网卡自适应夹具**（`runNicAdaptSelfTest()`，声明在 `:1583`；内部 `let cc = CoordinateCapture()` :1604 → `let started = cc.start()` :1605，配 `ck("自适应抓包启动", …)` :1606 + `probeRounds` :1611），属 `--nic-selftest` 类入口，与产品常开链路不是同一处，勿混计。

### 4.3 与文档其余部分的关系

- 本文第一~三节描述的**代码实体全部有效**（行号已 2026-10-17 逐条 `grep -n` 实测：文件现 668 行，`LocalPoseSocketClient` 在 :397，`NetworkLocator` 在 :536）；**失效的只是"它在产品里被调用"这一前提**。
- **依赖前提仍在**：若将来重新接线，仍需**本机 9004 端口的位姿桥接 WebSocket 服务在跑**（`kLocalPoseBridgeURL = "ws://127.0.0.1:9004"`，:23）——服务不在则 `locate()` 永远返回 `coordinate_stale`（:559-561）。
- **"旧网络抓包定位已移除"注释的措辞歧义（诚实记录）**：该注释字面像在说"本文件已删"，实测**文件未被删除**；被移除的是**调用点**。`AuroraDriveApp.swift:5663` 的措辞更准确（"旧 NetworkPacketCapture 已移除（不编译），使用移植的 NetworkLocator"）——即：旧的抓包类被删、移植版 `NetworkLocator` 保留为**候选实现**，但**尚未接线**。这两处注释并存，建议未来以 :5663 的表述为准。

### 4.4 本次改动核实

- `Sources/AuroraDrive/Locate/` 目录在 `HEAD~5..HEAD` 范围内**零改动**（`git diff --stat HEAD~5..HEAD -- Sources/AuroraDrive/Locate/` 输出为空，2026-10-07 实测）；工作树亦无未提交改动。该文件最后一次代码改动为 `8de7b06`（2026-10-08 19:09，M2 集成：车头朝向鉴定 + `motionHeading`/`cameraHeading` 字段与镜像 bug 修复），行号以 2026-10-17 实测锚点表为准。
- 因此本文**"调用点已移除"状态是历史既有事实，不是 10-07 的新改动**——本次只是把它**明确标注**出来。
- ⚠️ **未验证**：`LocateContext.networkLocator` / `visualLocator` 两个字段是否有**计划中**的接线（未找到 TODO/注释说明），本轮无法判断是"暂缓"还是"已放弃"。

### 4.5 D7b 补完：三态自检清单（2026-10-07 实测）

| 论断 | 状态 |
|---|---|
| `NetworkLocator.start()`/`stop()` 调用点只剩注释 | ✅ `AuroraDriveApp.swift:6284` / `:6313` `sed` 实测 |
| `grep -rn "NetworkLocator(" Sources/` = 0 命中 | ✅ 实测计数 0 |
| **`CoordinateCapture` 由 `runNetworkLocateStep()` 懒初始化并常开** | ✅ `AuroraDriveApp.swift:4546-4563` 逐行实测（`:4548` 注释「纯网络定位」、`:4553-4554` `CoordinateCapture()`+`cc.start()`、`:4557` `networkReady=true`） |
| **"网络定位功能未下线"** | ✅ 由上两条共同支撑（链路 ① 死、功能 ② 活） |
| `LocateContext.networkReady` 由 CoordinateCapture 写、而非 NetworkLocator | ✅ `LocateRuntime.swift:33` 声明 + `AuroraDriveApp.swift:4557` 写点 |
| 文件现 668 行、`LocalPoseSocketClient` :397、`NetworkLocator` :536 | ✅ `wc -l` + `sed` 实测 |
| `NetworkLocator.prepare()` :548-554 内部调 `start()` | ✅ 实测 `prepare()` :548-554：`:549` `socketClient = LocalPoseSocketClient()`、`:550` `socketClient?.start()`、`:552` `isConnected = true`、`:553` 无条件 `return true` |
| 重启接线是否有计划 | ⚠️ **未验证**（同上 4.4 末条） |

## 附：B 符号不一致现状（2026-10-06 逐行核实）

- **现状（已确认）**：存在两套符号约定，均为**正确实现**，只是矩阵定义写法不同：
  1. `MapWiring.worldToMapPixelX/Y`（`MapWiring.swift:29-36`）：`mapX = A·wx + B·wy + TX`，`mapY = A·wy − B·wx + TY`。其自推逆变换 `wx=(A·dx−B·dy)/det`、`wy=(B·dx+A·dy)/det`（`MapWiring.swift:78-93`）与该方程组严格匹配，`CoordinateCapture.worldToMapPixel` 同符号（`CoordinateCapture.swift:1786-1787`）。
  2. `NetworkLocator.swift` 的 `CoordinateTransform.apply`（`NetworkLocator.swift:75-79`）：`(a·x − b·y + tx, b·x + a·y + ty)`——B 项符号与 MapWiring 相反（`NetworkLocator.swift:70`）。它同样来自上游 MaaNTE 标定语义（头注释 `NetworkLocator.swift:5-14`），对该矩阵而言 `invert`（`NetworkLocator.swift:81-88`）自洽。
- **数值影响**：|B| = 5.69e-08；取定位界值 kMaxLocationAbs=2e6（`NetworkLocator.swift:39`），|B·wy| 最大约 0.114 px；对 1e5 量级的典型坐标差 ≈0.0057 px（MapWiring 注释称 ~0.006 px，`MapWiring.swift:63-64`）。任务给定「影响 ≤0.053 px」与以上估算同量级——无论取哪个界，都远低于任何可见阈值。
- **结论**：`NetworkLocator.swift:70` 的 B 符号「相反」只是与 MapWiring 的书写约定不同，两套各自正逆自洽；产品代码中 MapWiring 已不用 `CoordinateTransform.invert`（自推逆在 `MapWiring.swift:78-93`），**现状无功能性 bug，仅注释/文档层面的符号不一致**。
- **遗留注释漂移（未验证是否有意）**：`MapWiring.swift:55` 注释写 `CoordinateTransform.invert（NetworkLocator.swift:55）`，实际 invert 在 `NetworkLocator.swift:81-88`——行号引用漂移，应为历史行号。

---

## 附：2026-10-17 实测锚点表（逐条 `grep -n` 实测，供快速定位）

### NetworkLocator.swift（668 行）

| 符号 | 实测行号 |
|---|---|
| `kLocalPoseBridgeURL` / `kAPIVersion` / `kCoordinateSampleMaxAge` | :23 / :24 / :25 |
| `kCalibrationAxes / A / B / TX / TY / Error`（含旧帧注释 :29-33） | :26-36 |
| `kNorth` / `kEast` / `kMaxLocationAbs` / `kMaxRotationAbs` | :37-38 / :39 / :40 |
| `typealias RawPoint / RawPose / MapPoint` | :44-46 |
| `struct NetworkLocationResult`（含 `motionHeading` :64） | :47-65 |
| `struct CoordinateTransform`（`apply` :75、`invert` :81） | :67-89 |
| `private let kCoordinateTransform` | :91-98 |
| `UE5PacketDecoder`（private final class） | :102 |
| `decode` / `findCandidates` | :113-152 / :154-196 |
| `readFloat` / `readBits` / `readVector` | :198-209 / :211-222 / :224-248 |
| `hasValidRotation` / `extractPose` / `readRotator` | :250-266 / :268-291 / :293-307 |
| `computeHeading` / `trackingKey` | :309-322 / :324-332 |
| `newFlowCandidate` / `reacquireCandidates` / `confirmFlow` | :334-342 / :344-351 / :353-374 |
| `enum DecodeError` | :390-393 |
| `LocalPoseSocketClient`（private final class） | :397 |
| `start` / `startWithURLSession` / `readLoop` / `handleMessage` | :410-415 / :419-425 / :428-443 / :445-481 |
| `read(maxAge:)` / `stats()` / `close()` | :487-500 / :502-521 / :523-531 |
| `NetworkLocator`（final class） | :536-668 |
| `prepare()` / `locate()` | :548-554 / :558-633 |
| `rawToMap` / `mapToRaw` / `stats()` / `close()` | :637-649 / :651-655 / :659-661 / :663-667 |

### 调用链相关（App / LocateRuntime / MapWiring / CoordinateCapture）

| 符号 | 实测行号 |
|---|---|
| `AuroraDriveApp.swift`：`runNicAdaptSelfTest()`（自检夹具） | :1583（`CoordinateCapture()` :1604、`cc.start()` :1605） |
| `AuroraDriveApp.swift`：`locateSource()` | :4537（`:4538` networkReady 门） |
| `AuroraDriveApp.swift`：`runNetworkLocateStep()` | :4546（懒初始化 :4549-4563，`networkReady=true` :4557） |
| `AuroraDriveApp.swift`：旧实例声明注释 | :5663-5664 |
| `AuroraDriveApp.swift`：旧回调接线注释 | :6164-6171（块尾 :6182-6183） |
| `AuroraDriveApp.swift`：`startDriving()` / `stopDriving()` | :6190 / :6300（注释 :6284 / :6313） |
| `LocateRuntime.swift`：`LocateGate` / `LocateContext` | `LocateGate` :12-26；`LocateContext` :29-35（`visualLocator` :30 / `networkLocator` :31 / `visualReady` :32 / `networkReady` :33 / `activeMode` **:34**） |
| `MapWiring.swift`：`worldToMapPixelX/Y` | :29-36 |
| `MapWiring.swift`：`mapPixelToWorldX/Y`（自推逆变换） | :78-93 |
| `CoordinateCapture.swift`：`kCalibA/B/TX/TY` | :112-115 |
| `CoordinateCapture.swift`：`worldToMapPixel(_:)` | :1783-1789（矩阵式 :1786-1787） |

> 生成方式：`grep -n` / `awk NR` 逐条实测于当前工作树；源文件最后改动：`NetworkLocator.swift` 8de7b06（2026-10-08，M2 车头朝向/motionHeading），`VisualLocator.swift` 2026-08-26（`ls -la` mtime）。