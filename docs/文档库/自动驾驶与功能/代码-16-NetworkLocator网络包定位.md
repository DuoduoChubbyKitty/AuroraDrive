# 代码-16 NetworkLocator 网络包定位

> 覆盖源文件：`Sources/AuroraDrive/Locate/NetworkLocator.swift`（626 行）。基于当前仓库逐单元编写。与 `代码-04-CoordinateCapture` 是姊妹实现（同一 MaaNTE 移植源，解码器私有副本 + 定位封装不同）。

## 一、常量、数据类型与 CoordinateTransform（第 1–67 行）

**私有常量（第 7–19 行）——注意与 CoordinateCapture 的差异：**

| 常量 | 本文件值 | CoordinateCapture 的值 | 差异 |
|---|---|---|---|
| `kMaaNTEServerURL` | `"ws://127.0.0.1:9004"` | — | 本文件多了 MaaNTE WebSocket 服务地址（历史遗留，未被本文件代码使用） |
| `kAPIVersion` | `"1.3.0"` | — | 同上 |
| `kCoordinateSampleMaxAge` | 1.0 秒 | read(maxAge: 1.0) | 同语义 |
| `kCalibrationA` | 0.016394586684750773 | 同 | 相同 |
| `kCalibrationB` | 5.693519256055879e-08 | 同 | 相同 |
| **`kCalibrationTX`** | **6293.474380746091** | **6526.474380746091** | **本文件是旧帧 map-2026-06（11264）的 TX/TY，CoordinateCapture 是扩图版（+233, +1738）——两文件不同步！** |
| **`kCalibrationTY`** | **3472.664390686138** | **5210.664390686138** | 同上 |
| `kCalibrationError` | 0.22031967781665318 | — | 本文件多了标定误差记录 |
| `kNorth / kEast` | 同 | 同 | 相同 |
| `kMaxLocationAbs / kMaxRotationAbs` | 同 | 同 | 相同 |

**⚠️ 给别的 AI 的重要提示：本文件用旧图（map-2026-06）标定值，CoordinateCapture 用扩图（map-2026-08）——两份坐标系相差整体平移 (+233, +1738)。混用两个文件的 worldToMapPixel/apply 会得到错位 2000 像素的地图点。**当前权威源是 CoordinateCapture（扩图版，2026-09-13 升级，标定点验证通过）；本文件的 kCalibrationTX/TY 是旧值。

**数据类型（第 23–34 行）：**

- `RawPoint = (Double, Double, Double)`、`RawPose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`MapPoint = (Int, Int)`
- `NetworkLocationResult`：`found: Bool / point: MapPoint? / rawCoordinate: RawPoint? / score: Double / mode: String / cameraPitch: Double? / cameraHeading: Double?`——定位结果（found + 地图像素 + 原始坐标 + 分数 + 模式 + 相机姿态）

**`CoordinateTransform`（struct，第 36–58 行）**——坐标变换：

- 字段：`axes: (Int, Int)`（标定轴）、`a/b/tx/ty/error`
- `apply(_ point: RawPoint) -> (Double, Double)?`：**正变换 `(a*x - b*y + tx, b*x + a*y + ty)`**——注意与 CoordinateCapture.worldToMapPixel 的公式**不同**（那边是 `a*wx + b*wy + tx, a*wy - b*wx + ty`——B 的符号相反，再次印证两文件坐标系不同步）
- `invert(_ point: (Double, Double)) -> (Double, Double)?`：**逆变换**（地图像素 → 世界坐标）——`guard axes == (0, 1)`（只支持轴组合 (0,1)）、`denom = a² + b² > 1e-12`、`(dx, dy) = point - (tx, ty)` → `((a*dx + b*dy)/denom, (-b*dx + a*dy)/denom)`

**`kCoordinateTransform`（private let，第 60–67 行）**：全局唯一的 CoordinateTransform 实例（用上面的 kCalibration* 常量构造）。

## 二、UE5PacketDecoder 私有副本（第 69–321 行）

**`UE5PacketDecoder`（private final class，第 71 行起）**——与 `代码-04` 的 UE5Decoder 同构（同一 MaaNTE 移植源），但是**独立的私有副本，且未同步后续修复**。

**状态字段（72–80 行）**：flow/lastOffset/lastCaptureTime/lastClientTime/lastLocation + pending 四件套。

**`decode(payload: Data, timestamp: TimeInterval, flow:) -> RawPose?`（第 82–117 行）**——三分支（与 CoordinateCapture.decode 同构）：

1. 流变化 → newFlowCandidate → confirmFlow（两包确认）→ 切 flow → extractPose
2. 首包（lastClientTime/lastCaptureTime 为 nil）→ newFlowCandidate 直接选定 → extractPose
3. 跟踪中（97–116 行）：gap/expected → 候选对齐 → min(by: trackingKey) → timeError > 1.0 时 reacquire（取 clientTime 最大的）→ extractPose

**⚠️ 疑似 bug A（第 100 行）**：`let aligned = candidates.filter { $0.time == Double(lastOffset ?? 0) }`——**用候选的 `.time`（元组第 0 元素 = clientTime，秒值浮点）与 `Double(lastOffset)`（位偏移整数）比较**。CoordinateCapture 对应处是 `$0.offset == lastOffset`（位偏移对位偏移）。这边把两个不同量纲的值做等值比较——浮点秒值几乎不可能等于整数位偏移，所以 `aligned` 恒空 → 跟踪分支永远用全部候选（退化但不出错）。这是移植时抄错字段的残留。

**⚠️ 疑似 bug B（第 141 行）**：`let locationEnd = cursor + 7 + locationBits * 3`——**CoordinateCapture 的 ★关键修复(20260913) 修掉的正是这个 +7 多加**（那边修复后 `rotationOffset = locEnd`，注释明确"旧代码 locEnd + 7 多加 7 位 → rotation 解析错位 → hasValidRotation 永远失败 → 0 候选"）。**本文件未同步该修复**——cursor 已是三分量读完的偏移，再 +7 + width*3 会把 rotation 的起始位推后一整个向量宽度。后果：hasValidRotation 大概率恒失败 → findCandidates 恒空 → decode 恒 nil。

**位读取工具（第 152–176 行）**：`readFloat`（32 位 float → Double(bitPattern:)）与 `readBits`（指定位偏移读 N 位）——**throw 版本**（越界抛 `DecodeError.outOfBounds`），与 CoordinateCapture 的返回 0 版本不同；实现同为从高字节往回拼 + 右移掩码。

**`readVector`（第 178–196 行）**——UE5 Vector3 解码（throw 版）：7 位 header（width 低 6 位 + scaled 第 7 位）→ `guard width != 0 else { throw DecodeError.fullPrecisionUnsupported }`（**全精度不支持直接抛**）→ 逐分量读 width 位 + 手工符号扩展（`f & sign != 0 时 f -= modulus`）——**注意这里没有 CoordinateCapture 的 Int64(bitPattern:) 修复**（190 行直接 UInt64 减法，负坐标下溢风险同 bug 坑）。

**`hasValidRotation`（第 198–214 行）**：present 标志重放 → `guard flags.1, !flags.2`（Pitch/Yaw 存在，Roll 不存在）→ **直接读 pitch/yaw 16 位**（offset+1 / offset+18——假定两者都存在时的固定偏移）→ pitch ≤ 90.001 && yaw ≤ kMaxRotationAbs。

**`extractPose`（第 216–235 行）**：加速度向量（offset+32, scale 10）→ 位置向量（cursor, scale 100）→ readRotator → `computeHeading` → 更新状态 → 返回 RawPose。

**`readRotator`（第 237–251 行）**：与 CoordinateCapture 的 ue5Rotator 同构（1 位 present + 16 位压缩角 + 360/65536 + 180 归一）。

**`computeHeading`（第 253–266 行）**：与 CoordinateCapture.toPose 同构（视线方向 → kNorth/kEast 点积 → atan2 → [0, 360)）。

**`trackingKey`（第 268–276 行）**：`timeError + spatialPenalty`（同 CoordinateCapture），返回三元组（综合分, 时间误差, 距离平方）——但 decode 里只比较第一个元素。

**`newFlowCandidate / reacquireCandidates`（第 278–295 行）**：`clientTime >= 0.01 && 位置 ≤ kMaxLocationAbs` 过滤 → 取 clientTime 最大。

**`confirmFlow`（第 297–318 行）**：与 CoordinateCapture 同构（timeOk/offsetOk/stepOk，pendingSeen >= 2 才确认）。

**给别的 AI 的结论**：**这个 UE5PacketDecoder 是"未被修复同步"的副本——疑似 bug B 会让它大概率解析不出候选**。生产路径应优先用 `代码-04 CoordinateCapture`（修复版 + 扩图标定 + 实测统计日志）；本文件保留的定位封装（NetworkLocationResult/CoordinateTransform/主入口封装，见单元三）若要启用，先把 +7 与 time/offset 两处对齐 CoordinateCapture 的修复。

## 三、MaaNTESocketClient 与 NetworkLocator / DualModeLocator（第 321–626 行）

**`DecodeError`（enum，第 334–337 行）**：`outOfBounds / fullPrecisionUnsupported` 两种解码错误。

**`MaaNTESocketClient`（private final class，第 339–474 行）**——**WebSocket 版本**（不是 libpcap！）：

- `@unchecked Sendable`；内部 `UE5PacketDecoder` 实例（**声明了但实际未用**——handleMessage 直接收 JSON，不走解码器）
- **`start()`（352–357 行）**：`#if os(macOS)` + `guard #available(macOS 13.0, *)` → `startWithURLSession()`
- **`startWithURLSession()`（361–367 行）**：`URLSession.webSocketTask(with: kMaaNTEServerURL)`（**ws://127.0.0.1:9004**——本机 MaaNTE WebSocket 服务）→ resume → `readLoop`
- **`readLoop(task:)`（370–385 行）**：`task.receive` 递归续读；**failure → 5 秒后 `start()` 重连**（global queue asyncAfter）
- **`handleMessage`（387–423 行）**：只处理 `.data` 消息 → JSON 解析 → **协议校验**：`version == kAPIVersion("1.3.0")` 且 `mode == "coordinate"` → 读 x/y/z/pitch/heading 五字段 → 锁内写 sample（`os_unfair_lock`）——**注意：这个客户端直接收 MaaNTE 发来的 JSON 坐标，不做 UE5 包解析**（decoder 未接入）
- **`read(maxAge:) -> RawPose?`（429–442 行）**：锁内取 sample + `now - lastSampleWall <= maxAge` 新鲜度校验（默认 1 秒）
- **`stats() -> [String: Any]`（444–463 行）**：packet_count/payload_count/sample_count + 三个 age
- **`close()`（465–473 行）**：`task?.cancel()` + `session?.invalidateAndCancel()` + isConnected = false

**`NetworkLocator`（final class，第 478–564 行）**——网络定位器封装：

- 状态：`ready/isConnected/socketClient/lastLocPos/lastResult`
- **`prepare() -> Bool`（487–493 行）**：建 MaaNTESocketClient + start + ready/isConnected = true——**无条件返回 true**（socket 连接是否真的建立由 read 时的 nil 体现）
- **`locate() -> NetworkLocationResult`（497–529 行）**：
  - `socketClient?.read()` 为 nil → 返回 `lastResult ?? (found: false, mode: "coordinate_stale")`
  - rawToMap 失败或姿态非有限 → `(found: false, mode: "coordinate_invalid")`
  - 成功：**移动幅度判断（508–514 行）**：`lastLocPos` 距离平方 > 16（地图上 >4px）时用 `atan2(dx, dy)` **从位移反推朝向**（覆盖 WebSocket 自报的 heading——位移方向比相机朝向更可靠）；否则沿用
  - 结果：`(found: true, point, rawCoordinate, score: 1.0, mode: "coordinate", cameraPitch: pose.3, cameraHeading: heading)`
- **`rawToMap(x:y:z:) -> MapPoint?`（533–545 行）**：轴校验（axes 含 2 时需要 z）→ `kCoordinateTransform.apply` → isFinite → `(Int(round(mapX)), Int(round(mapY)))`
- **`mapToRaw(x:y:) -> (Double, Double)?`（547–551 行）**：`kCoordinateTransform.invert`（**逆变换：地图像素 → 世界坐标**）→ isFinite
- `stats()` / `close()`：透传 socketClient

**`DualModeLocator`（final class，第 568–626 行）**——双模定位器：

- `init(networkEnabled: Bool = true, visualLocator: VisualLocator? = nil)`：mode 三选一——`"network"`（网络启用）/"visual"（视觉可用）/"fallback"（都无）
- **`locate()`（589–601 行）**：mode 分支——network → `networkLocator.locate()`；**visual → 返回 `(found: false, mode: "visual_arch_skip")` 或 `"visual_missing"`（视觉路径未实现实际定位，只有占位结果）**；default → fallback
- `prepare()`：netOk || visOk；`isReady`：networkLocator.ready || visualLocator != nil；`stats()`：mode + 网络统计合并；`close()`：只关网络

**给别的 AI 的调用提示**：本文件的 WebSocket 路线依赖**本机 9004 端口的 MaaNTE WebSocket 服务在跑**——服务不在则 `locate()` 永远返回 coordinate_stale。当前项目里跑着的网络定位实际是 `代码-04 CoordinateCapture`（libpcap 自包含，无外部服务依赖）。DualModeLocator 的 visual 分支是占位（visual_arch_skip/visual_missing），真正视觉定位在 `代码-17 VisualLocator`（独立类，未被 DualModeLocator 接入）。

**NetworkLocator 文档至此完整**（626 行全覆盖：常量与变换 → UE5PacketDecoder → WebSocket 客户端 → NetworkLocator/DualModeLocator）。