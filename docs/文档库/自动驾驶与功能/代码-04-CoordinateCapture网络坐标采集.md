# 代码-04 CoordinateCapture 网络坐标采集

> 覆盖源文件：`Sources/AuroraDrive/Capture/CoordinateCapture.swift`（635 行）。从 MaaNTE `nte_coordinate_api.py` 移植（AGPL-3.0），自包含网络定位：libpcap 抓包 → UE5 移动包解析 → 世界坐标 + 朝向。基于当前仓库逐单元编写。

## 一、libpcap C 声明与同步常量（第 9–82 行）

**libpcap C 函数声明（第 11–60 行）**——Package.swift 已链接 pcap 库，这里用 `@_silgen_name` 直连 C 符号（不经模块映射）：

| C 函数 | Swift 签名要点 | 用途 |
|---|---|---|
| `pcap_open_live` | device/snaplen/promisc/to_ms/errbuf → `OpaquePointer?` | 打开网卡（snaplen 65535 全包） |
| `pcap_compile` | p/fp/str/optimize/netmask → Int32 | 编译 BPF 过滤表达式 |
| `pcap_setfilter` | p/fp → Int32 | 应用过滤器 |
| `pcap_loop` / `pcap_breakloop` / `pcap_close` | 循环/中断/关闭 | 抓包循环控制 |
| `pcap_next_ex` | h/d → Int32（0=超时、<0=错误） | **逐包拉取**（本实现用这个而不是回调） |
| `pcap_lookupdev` / `pcap_findalldevs` / `pcap_freealldevs` | 网卡枚举 | 找可用网卡 |

配套 struct：`pcap_pkthdr`（ts/caplen/len）、`bpf_program`（bf_len/bf_insns）、`pcap_if_t`（next/name/description/addresses/flags）、`pcap_callback`（`@convention(c)` C 函数指针类型）。

**同步常量（第 64–81 行，与 MaaNTE / NetworkLocator.swift 同步）：**

```swift
private let kNorth: (Double, Double, Double) = (-0.013752068070295848, -0.9999054358407049, 0.0)
private let kEast:  (Double, Double, Double) = ( 0.9999054358407049, -0.01375206807029585, 0.0)
private let kMaxLocationAbs: Double = 2_000_000.0
private let kMaxRotationAbs: Double = 180.001
```

- `kNorth`/`kEast`：游戏世界坐标系里"北/东"方向的单位参考向量（用于把视线方向转成罗盘朝向）
- `kMaxLocationAbs`：位置绝对值上限（候选过滤用，2 百万）
- `kMaxRotationAbs`：旋转绝对值上限（180.001 允许 ±180 整）

**底图坐标变换常量（第 78–81 行）：**

```swift
private let kCalibA: Double  = 0.016394586684750773
private let kCalibB: Double  = 5.693519256055879e-08
private let kCalibTX: Double = 6526.474380746091
private let kCalibTY: Double = 5210.664390686138
```

- 底图坐标系：**map-2026-08**（MaaNTE-Map 13056×13056 扩图版，2026-09-13 升级，新增区域：旧图左侧+1、顶部+7、右侧+6 瓦片，51×51@512px）
- 旧帧 map-2026-06 (11264)：A/B 相同，TX=6293.474380746091、TY=3472.664390686138
- **扩图相对旧图整体平移 (+233, +1738)**——MaaNTE-Map navi-coordinate-calibration.json 三个标定点 delta 完全一致，README 同值——故 TX/TY 直接加偏移，A/B 不变
- **标定点验证**：raw(-134394.56, 199913.53) → map(4323, 8488) ✓

**类型别名（第 85–87 行）**：`Vec3 = (Double, Double, Double)`、`Pose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`Flow = (String, Int, String, Int, String)`（srcIP, srcPort, dstIP, dstPort, proto）。

## 二、位操作与 UE5 序化解码（第 92–167 行）

**`bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64`（第 92–103 行）**——从 Python `_bits` 移植，从字节数组的指定位偏移读取 N 位：

- 防御：`count <= 0 || count > 63 || offset < 0` 返回 0；越界（`lastByte > data.count`）返回 0
- 实现：从最高有效字节往回逐字节拼 `value = (value << 8) | data[i]`，再 `(value >> (offset % 8)) & ((1 << count) - 1)`
- **count 上限 63**：UInt64 移位语义（见下面 ue5Vector 的断言坑）

**`ue5Vector(_ data: [UInt8], offset: Int, scale: Int) -> (Vec3, Int, Int, Bool)?`（第 109–129 行）**——UE5 Vector3 序化解码，返回 `(x, y, z), 新offset, bitWidth, isScaled`：

1. 读 7 位 header（110 行）：`width = header & 63`（低 6 位）、`isScaled = (header >> 6) & 1 != 0`（第 7 位）；`width == 0` 返回 nil
2. 逐分量读 `width` 位（119–127 行），符号扩展：
   ```swift
   let sv: Int64 = (v & sign) != 0 ? Int64(bitPattern: v &- modulus) : Int64(v)
   values.append(isScaled ? Double(sv) / Double(scale) : Double(sv))
   ```
   - **两个源注释里的坑（122–124 行）**：
     - 符号扩展必须走 `Int64(bitPattern:)`：UInt64 的 `&-` 会下溢回绕成巨大正数（Python 大整数无此问题），导致所有负坐标 > kMaxLocationAbs 被淘汰 → 永远 0 候选
     - `Int64(modulus)` 在 width=63 时（modulus=2^63）触发运行时断言（**04:04 SIGTRAP 崩溃事故**）
   - `isScaled` 时除以 scale（移动包：加速度 scale=10、位置 scale=100）

**`ue5Rotator(_ data: [UInt8], offset: Int) -> (Vec3, Int)?`（第 132–148 行）**——UE5 FRotator 序化解码（Pitch, Yaw, Roll）：

- 逐分量：先读 1 位 present 标志，present 非零才读 16 位压缩角
- 解压：`angle = Double(compressed) * 360.0 / 65536.0`，`angle > 180.0` 时减 360（归一到 [-180, 180]）
- 返回 `(pitch, yaw, roll), 新offset`

**`hasValidRotation(_ data: [UInt8], offset: Int) -> Bool`（第 151–167 行）**——检查旋转是否有效：

- 先重放 present 标志收集 `flags`（154–158 行，cursor 前进 `1 + (present ? 16 : 0)`）
- 再调 ue5Rotator 解码，`end > data.count * 8` 返回 false
- **有效性判定（161–166 行）**：`flags[1] && !flags[2]`（**Pitch 和 Yaw 存在，Roll 通常不存在**）+ `abs(rot.0) <= 90.001`（pitch 限 ±90）+ 三个分量都 ≤ kMaxRotationAbs

**辅助函数（第 171–195 行）**：`dot(_:_:)`（点积）、`distanceSq(_:_:)`（距离平方，避免开方）、`toPose(_ location: Vec3, _ rotation: Vec3) -> Pose`——位置+旋转 → 姿态：
- `pitch = rotation.0`，yaw 转 rad，算视线方向 `viewDir = (cos(pitchRad)*cos(yawRad), cos(pitchRad)*sin(yawRad), sin(pitchRad))`
- `north = dot(viewDir, kNorth)`、`east = dot(viewDir, kEast)`、`heading = atan2(east, north) * 180 / π`，负值 +360 归一到 [0, 360)

## 三、UE5Decoder 状态跟踪与候选选择（第 223–380 行）

**`UE5Decoder`（final class，第 226–380 行）**——UE5 移动包解码器：状态跟踪 + 候选选择。从 Python `_Decoder` 移植。

**状态字段（227–235 行）**：`flow`（当前流）、`lastOffset/lastCapture/lastTime/lastLocation`（上一包解码结果）、`pendingFlow/pendingCandidate/pendingSeen/pendingAt`（新流确认pending）。诊断：`lastCandCount`（最近一次 decode 找到的候选块数）。

**`decode(payload:timestamp:flow:) -> Pose?`（第 243–297 行）——主解码入口，三条分支：**

1. **流变化**（251–256 行）：`flow != self.flow` 时 → `newFlowCandidate` 选候选 → `confirmFlow` 确认（需连续 2 包一致）→ 成功才切换 `self.flow = flow`
2. **首包**（257–261 行）：`lastTime == nil || lastCapture == nil` → `newFlowCandidate` 直接选定，切换 flow
3. **跟踪中**（262–280 行）：
   - `gap = max(0, timestamp - lastCapture)`、`expected = lastTime + gap`
   - 候选集：优先 `offset == lastOffset` 的对齐候选（`aligned`），空则全部（`tracking`）
   - `selected = tracking.min(by: trackingKey)`——**trackingKey（334–340 行）**：`timeError + spatialPenalty`，spatialPenalty = `min(dist / 5000², 100)`（离上一位置太远的大惩罚）
   - **timeError > 1.0 时重取**（268–278 行）：`reacquireCandidates` 过滤（clientTime ≥ 0.01、offset ≤ 512、加速度 ≤ 10000、位置 ≤ kMaxLocationAbs）→ 取 clientTime 最大的，清 pending、切换 flow
4. 选定后读解码链（288–290 行）：`ue5Vector(offset: bitOffset + 32, scale: 10)`（加速度）→ `ue5Vector(scale: 100)`（位置）→ `ue5Rotator`（旋转）
5. 更新状态（292–295 行）：`lastTime/lastOffset/lastCapture/lastLocation`，返回 `toPose(location, rotation)`

**`findCandidates(_ payload: [UInt8]) -> [Candidate]?`（第 300–332 行）**——扫描包中所有有效的移动块：

- 搜索范围：`for offset in 190..<searchEnd`，`searchEnd = min(512, payload.count * 8 - 60)`，`searchEnd > 190` 才继续（**payload ≥ 32 字节**——566–568 行注释：旧代码 `<70` 丢弃把 48 字节的 c2s 移动包全部挡在了 decode 之外，对齐 MaaNTE 原版"payload 非空即试"）
- 逐 offset 四重过滤：
  1. **时间戳**（306–308 行）：32 位 float，`isFinite && >= 0 && < 100_000`
  2. **加速度**（311–314 行）：`ue5Vector(offset+32, scale: 10)`，要求 `accelScaled`、bitWidth 1–16、分量绝对值 < 50000
  3. **位置**（317–320 行）：`ue5Vector(cursor, scale: 100)`，要求 `locScaled`、bitWidth 20–32、分量绝对值 ≤ kMaxLocationAbs
  4. **旋转**（322–327 行）：`hasValidRotation(payload, offset: rotationOffset)`
- **★ 关键修复（20260913，322–326 行注释）**：ue5Vector 返回的 `locEnd` 已经是"位置向量结束后"的位偏移（= offset + 7 位 header + 3×width 值位），即 rotation 的起始位。**旧代码 `locEnd + 7` 多加 7 位 → rotation 解析错位 → hasValidRotation 永远失败 → 0 候选**。MaaNTE 原版语义：`location_end = location_start + 7 + width*3 == ue5Vector 返回的 cursor`。故 `rotationOffset = locEnd`。

**`confirmFlow`（第 354–372 行）**——新流两包确认机制：pendingSeen 达到 2（timeOk：`timeDelta >= 0.001 && abs(timeDelta - gap) <= 0.5`；offsetOk：offset 相等；stepOk：位置距离平方 ≤ 6.4e9）才返回候选，防误切到无关流。

**`clearPending`（第 374–379 行）**：四个 pending 字段归零/置 nil。

## 四、CoordinateCapture 抓包器与 worldToMapPixel（第 382–635 行）

**PAC 崩溃规避设计（第 384–394 行）**：pcap 回调**用 C 函数指针不用闭包**——"避免 Apple Silicon PAC 签名问题"。全局单例 `nonisolated(unsafe) var coordinateCaptureActive: CoordinateCapture?` 承载回调目标；`coordinateCaptureCallback: pcap_callback` 解引用 header/packet 后转调 `capture.processPacket(header:packet:)`。

**`pcapLog(_ msg: String)`（第 397–409 行）**：日志写到 `/tmp/aurora_pcap.log`（ISO8601 时间戳 + 消息），文件存在则 seekToEnd 追加，否则创建。

**`CoordinateCapture`（final class，第 411–624 行）**——自包含网络坐标抓取：libpcap 抓 TCP 30031 端口 → UE5 包解析 → 世界坐标。

**状态（412–431 行）**：`decoder = UE5Decoder()`、`sample: Pose?` + `sampleAt` + `lastSampleWall`、`interval = 1.0/30.0`（30Hz 采样限频）、`pcapHandle` + `captureThread` + `running` + `lock`（NSLock，sample 读写跨线程）；15 秒窗口统计 7 个字段（statPackets/statS2C/statC2S/statDecodeCalls/statCandHits/statCandPeak/statSamples——**仅 captureLoop 线程读写，无需加锁**）。

**`start() -> Bool`（第 434–512 行）**——遍历所有网卡，找到有 30031 端口流量的那个：

1. `guard !running else { return true }`（幂等）
2. `pcap_findalldevs` 枚举网卡（失败记日志返回 false）
3. 逐网卡尝试：**跳过非物理网卡**（`lo`/`pdp`/`utun`/`awdl`/`bridge`/`xhc` 前缀，454–459 行）→ `pcap_open_live(name, 65535, 0, 20, &errbuf)` → 编译过滤器 **`"tcp port 30031 or udp"`**（对齐 MaaNTE 原版，UE5 移动同步可能走 UDP）→ `pcap_setfilter`；任一步失败关句柄继续下一个
4. 选中即 break（`devName` + `pcapHandle`），`pcap_freealldevs` 释放枚举
5. `running = true`，起 `Thread { self?.captureLoop() }`（名字 `com.aurora.coordinate-capture`），返回 true

**`captureLoop()`（第 514–527 行）**——**用 pcap_next_ex 不用回调，避免 PAC 崩溃**：`while running` 循环 `pcap_next_ex(handle, &headerPtr, &packetPtr)`；`result == 0`（超时）continue、`< 0` break、其余 `processPacket`。

**`processPacket(header:packet:)`（第 530–588 行）**——逐包解析（captureLoop 串行调用，统计字段无需加锁）：

1. `statPackets += 1`，`defer { logStats() }`
2. 以太网头 14 字节 → IPv4 校验（`ipVersion != 4` return）→ IP 头长 `* 4` → 协议号（offset+9）→ srcIP/dstIP（offset+12..19 拼点分十进制）
3. 传输层（547–559 行）：TCP(6) **可变头**（`offset += Int(data[offset+12] >> 4) * 4`）；UDP(17) 固定 8 字节头——对齐 MaaNTE 原版
4. **方向过滤（562–565 行）**：`packetDirection(src:dst:)` → 只处理 `c2s`（本地→服务器）；`s2c` 和 `unknown` return
5. `guard payload.count >= 32`（findCandidates 需 searchEnd > 190 位）→ 读 srcPort/dstPort（transportStart 前两字节大端）
6. `decoder.decode(...)` 成功 → `statSamples += 1` → **限频写入（575–582 行）**：`now - lastSampleWall >= interval` 才更新 `sample/sampleAt/lastSampleWall`（锁内）
7. `decoder.lastCandCount > 0` → statCandHits/peak 累计

**`logStats()`（第 591–599 行）**：15 秒一行统计汇总（代替原先每包 2 行的刷屏日志）——`[STATS] Ns: 包=X s2c=N c2s送解=N 解码调用=N 候选包=N/峰=N 样本=N`，然后归零。

**`read(maxAge: Double = 1.0) -> Pose?`（第 602–609 行）**：锁内取 sample；**过期判定**：`now - lastSampleWall > maxAge`（默认 1 秒）返回 nil——调用方拿到的坐标最多滞后 1 秒，超龄即视为无效（防旧坐标误导导航）。

**`close()`（第 612–623 行）**：`running = false` → `pcap_breakloop` → `captureThread?.cancel()` → `pcap_close` → handle 置 nil；`deinit { close() }` 保证析构时停止。

**`worldToMapPixel(_ pose: Pose) -> (mapX: Double, mapY: Double, heading: Double)`（第 629–635 行）**——世界坐标 → 地图像素（与 NetworkLocator.swift 的校准常量同步）：

```swift
let mapX = kCalibA * wx + kCalibB * wy + kCalibTX
let mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

线性变换（A 是缩放、B 是微量旋转耦合、TX/TY 是平移），heading 直接透传（已在 toPose 算好）。

**CoordinateCapture 文档至此完整**（635 行全覆盖：C 声明与常量 → 位操作与 UE5 解码 → UE5Decoder → 抓包器与坐标变换）。
