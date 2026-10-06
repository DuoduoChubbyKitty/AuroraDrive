# 代码-16 NetworkLocator 网络包定位

> 覆盖源文件：`Sources/AuroraDrive/Locate/NetworkLocator.swift`（**612 行**，2026-10-06 实测 `wc -l`）。
>
> **🔄 2026-10-06 重核说明**：本文件相对 2026-09-29 版文档已发生结构性变化，全部行号按当前工作树重新核实（下文所有 `文件:行号` 均为 2026-10-06 实测）：
> ① **`DualModeLocator` 类已被整体删除**（全仓 grep 无任何命中），文件现只含常量/`CoordinateTransform`、`UE5PacketDecoder`、`LocalPoseSocketClient`、`NetworkLocator` 四个单元；
> ② 2026-10-04 品牌清理：`kMaaNTEServerURL` → `kLocalPoseBridgeURL`（`NetworkLocator.swift:23`）、`MaaNTESocketClient` → `LocalPoseSocketClient`（`NetworkLocator.swift:387`），端口 9004 未变；
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

## 一、常量、数据类型与 CoordinateTransform（第 1–88 行）

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

**数据类型（第 44–55 行）：**

- `RawPoint = (Double, Double, Double)`、`RawPose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`MapPoint = (Int, Int)`（`NetworkLocator.swift:44-46`）
- `NetworkLocationResult`：`found: Bool / point: MapPoint? / rawCoordinate: RawPoint? / score: Double / mode: String / cameraPitch: Double? / cameraHeading: Double?`（`NetworkLocator.swift:47-55`）

**`CoordinateTransform`（struct，第 57–79 行）**——坐标变换：

- 字段：`axes: (Int, Int)`、`a/b/tx/ty/error`（`NetworkLocator.swift:58-63`）
- `apply(_ point: RawPoint) -> (Double, Double)?`：**正变换 `(a*x - b*y + tx, b*x + a*y + ty)`**（`NetworkLocator.swift:68`）——B 项符号与 `MapWiring.worldToMapPixelX/Y`（`MapWiring.swift:29-36`，`mapX = A·wx + B·wy + TX` / `mapY = A·wy − B·wx + TY`）及 `CoordinateCapture.worldToMapPixel`（`CoordinateCapture.swift:1749-1750`）**相反**。两套矩阵各自正逆自洽，数值影响 ≤0.053 px，详见文末专节
- `invert(_ point: (Double, Double)) -> (Double, Double)?`：逆变换（地图像素 → 世界坐标）——`guard axes == (0, 1)`、`denom = a² + b² > 1e-12`、`(dx, dy) = point - (tx, ty)` → `((a*dx + b*dy)/denom, (-b*dx + a*dy)/denom)`（`NetworkLocator.swift:71-78`）

**`kCoordinateTransform`（private let，第 81–88 行）**：全局唯一的 CoordinateTransform 实例（用上面的 kCalibration* 常量构造）。

## 二、UE5PacketDecoder 私有副本（第 92–383 行）

**`UE5PacketDecoder`（private final class，`NetworkLocator.swift:92` 起）**——与 `代码-04` 的 UE5Decoder 同构（同一 MaaNTE 移植源），独立私有副本，**解码修复已与 CoordinateCapture 对齐**。

**状态字段（93–101 行）**：flow/lastOffset/lastCaptureTime/lastClientTime/lastLocation + pending 五件套（`NetworkLocator.swift:93-101`）。

**`decode(payload:timestamp:flow:) -> RawPose?`（第 103–142 行）**——三分支：

1. 流变化 → newFlowCandidate → confirmFlow（两包确认）→ 切 flow → extractPose（`:107-112`）
2. 首包（lastClientTime/lastCaptureTime 为 nil）→ newFlowCandidate 直接选定 → extractPose（`:113-117`）
3. 跟踪中（`:118-141`）：gap/expected → 候选对齐 `aligned = candidates.filter { $0.offset == lastOffset }`（**修复后按位偏移对位偏移**，`:125`）→ 空则退全量候选 → min(by: trackingKey) → timeError > 1.0 时 reacquire（取 clientTime 最大的）→ extractPose

**`findCandidates`（第 144–186 行）**：候选扫描 `for offset in 190..<searchEnd`（searchEnd = min(512, payload.count*8 − 60)，`:147-149`）；clientTime 有效性防线（isFinite/≥0/<100_000，`:154`）；加速度必须 scaled（`:158`）；位置向量 scale=100（`:159`）；位置界值 kMaxLocationAbs（`:167-169`）；★ 修复后的 rotation 起始位：`let rotationOffset = cursor`（cursor 即 readVector 返回的结束位，**不再 +7 多加**，`:172-177`）。

**位读取工具（第 188–212 行）**：`readFloat`（32 位 float → Double(bitPattern:)，`:188-199`）与 `readBits`（指定位偏移读 N 位，`:201-212`）——均为 throw 版（越界抛 `DecodeError.outOfBounds`）。

**`readVector`（第 214–238 行）**——UE5 Vector3 解码（throw 版）：7 位 header（width 低 6 位 + scaled 第 7 位，`:215-218`）→ `guard width != 0 else { throw fullPrecisionUnsupported }`（`:219`）→ `guard width <= 63` 防御（`:222`）→ 逐分量读 width 位 + **符号扩展走 `Int64(bitPattern:)`**（修复后，`:231`）→ 返回 (值, cursor 结束位, width, scaled)。

**`hasValidRotation`（第 240–256 行）**：present 标志重放（`:242-249`）→ `guard flags.1, !flags.2`（Pitch/Yaw 存在，Roll 不存在，`:250`）→ 直接读 pitch/yaw 16 位（offset+1 / offset+18，`:251-252`）→ pitch ≤ 90.001 && yaw ≤ kMaxRotationAbs（`:253-254`）。

**`extractPose`（第 258–281 行）**：加速度向量（bitOffset+32, scale 10）→ 位置向量（cursor1, scale 100）→ readRotator（cursor2）→ `computeHeading`（`:261-270`）——**修复后链式使用上一步的结束位**；更新状态（`:272-275`）→ 返回 RawPose（`:277`）。

**`readRotator`（第 283–297 行）**：1 位 present + 16 位压缩角 + 360/65536 + 180 归一。

**`computeHeading`（第 299–312 行）**：视线方向 → kNorth/kEast 点积 → `atan2(eastDot, northDot)` → [0, 360)。

**`trackingKey`（第 314–322 行）**：`timeError + spatialPenalty`（spatialPenalty = min(distSq/5000², 100)，`:318`），返回三元组——decode 里只比较第一个元素。

**`newFlowCandidate / reacquireCandidates`（第 324–341 行）**：`clientTime >= 0.01 && 位置 ≤ kMaxLocationAbs` 过滤 → 取 clientTime 最大。

**`confirmFlow`（第 343–364 行）**：timeOk/offsetOk/stepOk，pendingSeen >= 2 才确认。

**`DecodeError`（enum，第 380–383 行）**：`outOfBounds / fullPrecisionUnsupported` 两种解码错误。

## 三、LocalPoseSocketClient 与 NetworkLocator（第 385–612 行）

**`LocalPoseSocketClient`（private final class，`NetworkLocator.swift:387` 起；原 MaaNTESocketClient，2026-10-04 改名）**——**WebSocket 版本**（不是 libpcap！）：

- `@unchecked Sendable`；内部 `UE5PacketDecoder` 实例（声明了但 handleMessage 直接收 JSON，不走解码器，`:388`）
- **`start()`（401–405 行）**：`#if os(macOS)` + `guard #available(macOS 13.0, *)` → `startWithURLSession()`
- **`startWithURLSession()`（409–415 行）**：`URLSession.webSocketTask(with: kLocalPoseBridgeURL)`（**ws://127.0.0.1:9004**）→ resume → `readLoop`
- **`readLoop(task:)`（417–433 行）**：`task.receive` 递归续读；failure → 5 秒后 `start()` 重连（`:428-430`）
- **`handleMessage`（435–471 行）**：只处理 `.data` 消息 → JSON 解析 → 协议校验 `version == kAPIVersion("1.3.0")` 且 `mode == "coordinate"`（`:440-443`）→ 读 x/y/z/pitch/heading 五字段（`:447-453`）→ 锁内写 sample（os_unfair_lock，`:457-466`）
- **`read(maxAge:) -> RawPose?`（477–490 行）**：锁内取 sample + `now - lastSampleWall <= maxAge` 新鲜度校验（默认 1 秒）
- **`stats()`（492–511 行）**：packet/payload/sample 三个 count + 三个 age
- **`close()`（513–521 行）**：`task?.cancel()` + `session?.invalidateAndCancel()` + isConnected = false

**`NetworkLocator`（final class，第 526–612 行）**——网络定位器封装：

- 状态：`ready/isConnected/socketClient/lastLocPos/lastResult`（`:527-531`）
- **`prepare() -> Bool`（535–541 行）**：建 LocalPoseSocketClient + start + ready/isConnected = true——**无条件返回 true**（socket 是否真建立由 read 时的 nil 体现）
- **`locate() -> NetworkLocationResult`（545–577 行）**：
  - `socketClient?.read()` 为 nil → 返回 `lastResult ?? (found: false, mode: "coordinate_stale")`（`:546-548`）
  - rawToMap 失败或姿态非有限 → `(found: false, mode: "coordinate_invalid")`（`:552-554`）
  - 成功：移动幅度判断（`:556-562`）：`lastLocPos` 距离平方 > 16（地图上 >4px）时用 `atan2(dx, dy)` 从位移反推朝向（覆盖 WebSocket 自报的 heading）；否则沿用
  - 结果：`(found: true, point, rawCoordinate, score: 1.0, mode: "coordinate", cameraPitch: pose.3, cameraHeading: heading)`（`:565-573`）
- **`rawToMap(x:y:z:) -> MapPoint?`（581–593 行）**：轴校验（`:582-584`）→ `kCoordinateTransform.apply` → isFinite → `(Int(round(mapX)), Int(round(mapY)))`。注意：输出是**地图像素**（0~13056），不是世界坐标
- **`mapToRaw(x:y:) -> (Double, Double)?`（595–599 行）**：`kCoordinateTransform.invert`（逆变换：地图像素 → 世界坐标）→ isFinite。当前 grep 未见产品代码调用（见文末 B 符号专节的 R4 风险）
- `stats()` / `close()`：透传 socketClient（`:603-611`）

**⚠️ DualModeLocator 已删除（2026-10-06 实核）**：旧文档记录的 `DualModeLocator`（双模定位器，visual 分支占位）在当前工作树中**不存在**——全仓 `grep -rn "DualModeLocator" Sources/` 零命中，文件在 `NetworkLocator` 类（`:612` 行结束）后即终止。`LocateContext`（`App/LocateRuntime.swift:29-35`）现直接持有 `visualLocator: VisualLocator?` 与 `networkLocator: NetworkLocator?` 双实例 + `activeMode`，互斥由 `LocateGate`（`App/LocateRuntime.swift:12-26`）保证。

**给别的 AI 的调用提示**：WebSocket 路线依赖**本机 9004 端口的位姿桥接 WebSocket 服务在跑**——服务不在则 `locate()` 永远返回 coordinate_stale。当前项目里跑着的网络定位实际是 `代码-04 CoordinateCapture`（libpcap 自包含，无外部服务依赖）。真 visual 定位在 `代码-17 VisualLocator`。

**NetworkLocator 文档至此完整**（612 行全覆盖：常量与变换 → UE5PacketDecoder → LocalPoseSocketClient → NetworkLocator）。

## 附：B 符号不一致现状（2026-10-06 逐行核实）

- **现状（已确认）**：存在两套符号约定，均为**正确实现**，只是矩阵定义写法不同：
  1. `MapWiring.worldToMapPixelX/Y`（`MapWiring.swift:29-36`）：`mapX = A·wx + B·wy + TX`，`mapY = A·wy − B·wx + TY`。其自推逆变换 `wx=(A·dx−B·dy)/det`、`wy=(B·dx+A·dy)/det`（`MapWiring.swift:78-93`）与该方程组严格匹配，`CoordinateCapture.worldToMapPixel` 同符号（`CoordinateCapture.swift:1749-1750`）。
  2. `NetworkLocator.swift` 的 `CoordinateTransform.apply`（`NetworkLocator.swift:65-69`）：`(a·x − b·y + tx, b·x + a·y + ty)`——B 项符号与 MapWiring 相反（`NetworkLocator.swift:68`）。它同样来自上游 MaaNTE 标定语义（头注释 `NetworkLocator.swift:5-14`），对该矩阵而言 `invert`（`NetworkLocator.swift:71-78`）自洽。
- **数值影响**：|B| = 5.69e-08；取定位界值 kMaxLocationAbs=2e6（`NetworkLocator.swift:39`），|B·wy| 最大约 0.114 px；对 1e5 量级的典型坐标差 ≈0.0057 px（MapWiring 注释称 ~0.006 px，`MapWiring.swift:63-64`）。任务给定「影响 ≤0.053 px」与以上估算同量级——无论取哪个界，都远低于任何可见阈值。
- **结论**：`NetworkLocator.swift:68` 的 B 符号「相反」只是与 MapWiring 的书写约定不同，两套各自正逆自洽；产品代码中 MapWiring 已不用 `CoordinateTransform.invert`（自推逆在 `MapWiring.swift:78-93`），**现状无功能性 bug，仅注释/文档层面的符号不一致**。
- **遗留注释漂移（未验证是否有意）**：`MapWiring.swift:55` 注释写 `CoordinateTransform.invert（NetworkLocator.swift:55）`，实际 invert 在 `NetworkLocator.swift:71-78`——行号引用漂移，应为历史行号。