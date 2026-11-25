# 代码-04 CoordinateCapture 网络坐标采集

> 覆盖源文件：`Sources/AuroraDrive/Capture/CoordinateCapture.swift`（2026-10-16 `wc -l` 实测行数 1789）。从 MaaNTE `nte_coordinate_api.py` 移植（AGPL-3.0），自包含网络定位：libpcap 抓包 → UE5 移动包解析 → 世界坐标 + 朝向。基于当前仓库逐单元编写。
>
> **引用约定**：本文旧版以「文件:行号」锚定代码，行号随源码演进而失效。已全面改为**引用真实符号名**（类型 / 函数 / 属性 / 常量 / 环境变量 / CLI 开关），全文不再出现任何行号。
>
> **复核沿革摘要**（2026-09-25 → 2026-10-18 多轮）：早期各节以 1083 / 1752 / 1789 等不同行数版本为基准，行号大面积漂移；期间 `CoordinateCapture` 已从「单线程 `captureLoop`」整体重写为「`supervisorLoop` 主管 + 探测式自适应网卡状态机」。本轮把所有位置引用改为符号引用，并保留各轮复核所得的**行为结论**（见下）。
>
> | 引用 | 结论 |
> |---|---|
> | `runNetworkLocateStep` | 定义在 `AuroraDriveApp.swift`；首次执行时懒初始化 `CoordinateCapture` 并 `cc.start` |
> | 懒初始化块（`cc.start` / 双检锁 `healerInitLock` / `networkReady`） | 双检锁保护，`start` 返回 true 才置 `locateCtx.networkReady = true` |
> | `locateSource` | `coordinateCapture == nil` 或 `!networkReady` → `.packetError`；有流量 → `.ready`；否则 `.noGame` |
> | `readWithTier` 消费点 | `let tierRead = cc.readWithTier`（原引位置落在注释行，已按符号修正） |
> | `--nic-autotest` 自建实例 | `let cc = CoordinateCapture` + `let started = cc.start`，行为未变 |
> | `MissionConsole` 定时器 | `DispatchSourceTimer` 跑在 `com.aurora.netlocate` 队列，事件调 `state.runNetworkLocateStep` |
>
> ⚠️ **行为描述修正（不只是位置）**：原文写「网络定位定时器 **10Hz**」，现役已改为**空闲降频**——开车/录制时 10Hz、空闲约 2Hz（`MissionConsole` 中 `nlIdleSkip < 5` 早退）。
>
> ✅ **未变**：`CoordinateCapture.swift` 自身各符号与常量名全部按名命中（源码未改动）。

> ✅ **区间复核（2026-10-18）**：四个章节起点（libpcap C 声明 / `bits` 位操作 / `UE5Decoder` 解码器 / `CoordinateCapture` 坐标抓取器）逐个对照源码，**全部准确命中**。源文件末行统计口径相差 1（`wc -l` 只数换行符，末行无换行符时少计），不影响任何符号定位。

> ## ✅ 2026-10-06 复核（结论保留，行号已作废）
>
> 本档 2026-09-25~09-29 各节曾以旧版行号为基准并大面积失效；此后 `CoordinateCapture` 已整体重写为「`supervisorLoop` 主管 + 探测式自适应网卡」。以下按**符号**归纳现役实现与历轮实测结论。
>
> **模块与符号对应**
>
> | 模块 | 符号 |
> |---|---|
> | libpcap C 声明 | `pcap_open_live` / `pcap_compile` / `pcap_setfilter` / `pcap_loop` / `pcap_breakloop` / `pcap_close` / `pcap_next_ex` / `pcap_lookupdev` / `pcap_findalldevs` / `pcap_freealldevs` / `pcap_if_t` |
> | 常量 | `kNorth` / `kEast` / `kMaxLocationAbs` / `kMaxRotationAbs` / `kCalibA` / `kCalibB` / `kCalibTX` / `kCalibTY` |
> | 位操作与解码 | `bits` / `ue5Vector` / `ue5Rotator` / `hasValidRotation` / `packetDirection` |
> | `UE5Decoder` | `decode` / `acceleration` / `decodeProtoMove` / `findCandidates` / `trackingKey` / `reacquireCandidates` / `newFlowCandidate` / `confirmFlow` / `clearPending` |
> | 日志 | `pcapLog`（候选路径 / 轮转上限 / 轮转函数 / 主函数） |
> | 抓包器 | `CoordinateCapture`：状态与窗口常量、`skipPrefixes` / `loopbackNames`（网卡选择）、`linkLayerHeaderLength`、`parseDefaultRoute` / `defaultRouteInterface`、`openWithFilter`（BPF 过滤器）、候选网卡、`probe` / `listenLocked` / `sleepInterruptible` / `setActiveInterface` / `supervisorLoop` / `start` / `processPacket` / `logStats` / `markGameTraffic` / `learnGamePort` / `isGamePort` / `hasRecentTraffic` / `read` / `diagnostics` / `readAcceleration` / `PoseRead` / `PoseTier` / `readWithTier` / `readWithFreshness` / `close` / `worldToMapPixel` |
>
> ### ⚠️ 2026-09-30 实测推翻本档 2026-09-25 的「s2c 放开」结论
>
> 本档末尾「2026-09-25 新协议逆向」一节记载的「移动包全部是 s2c、放开 s2c 通道」**已被实测推翻**（见 `processPacket` 内 S2C 通道注释块）：
>
> - S2C 30031 上只有 ①76 字节心跳（每 15.00s 一个，内含微秒时钟——旧 `decodeProtoMove` 把 bit498/509 的时钟位模式当成了坐标，这正是「传送 4~5 次定位纹丝不动」的直接原因）②物品/生成记录明文推送。**全都不含玩家实时位置**。
> - 现役行为：**s2c 仅保留流量计数（`statS2C`），不进解码器**（`processPacket` 内 `if direction == "s2c" { return }`）；真实移动包在 **C2S UDP**（动态端口，实测 30212/30160，~8Hz，站立也发）。
> - `decodeProtoMove` 函数体保留但**默认停用**，仅 `AURORA_LEGACY_PROTO=1` 启用作对照诊断（开关 `legacyProtoEnabled`）。
>
> ### 2026-09-30 / 10-04 关键窗口与常量现状（全部实测校准）
>
> | 常量 | 现值 | 依据 |
> |---|---|---|
> | `probeWindowPrimaryForKnownCadence` | 16.0s | 实测坐标包严格每 15.01s 一个，2.5s 窗口命中率仅 ~17% |
> | `probeWindowOther` | 0.5s | 低嫌疑网卡快速筛掉（`probeWindowPrimary`=2.5s 已被 16s 版取代，仅剩注释价值） |
> | `probeRetryInterval` | 2.0s | 空闲指数退避基准（2^n 放大，封顶 `probeIdleBackoffCap`=30s） |
> | `streamLostWindow` | 22.0s | 实测周期 15s + 7s 余量 |
> | `trafficFreshWindow` | 20.0s | = `poseFreshWindow`(18)+2s，保持 traffic > pose 层级 |
> | `poseFreshWindow` | 18.0s | 实测周期 15s + 3s 余量（15s 窗口与周期临界相撞必然闪断） |
> | `poseRecentWindow` / `poseStaleWindow` | 40s / 90s | 分级新鲜度（live/recent/stale/lost 四档，`PoseTier`） |
> | BPF 过滤器 | `"(tcp port 30031) or udp"` | 09-30 第二次根因修复：UDP 移动包端口随服务器变（30212→30160），**永不写死**；甄别交给解码器 + 游戏流量标记 |
>
> ### 2026-09-30 / 10-04 其它落地项（本档此前完全未覆盖）
>
> - **pcapLog 动态候选路径**：`/tmp/aurora_pcap.log` 曾被 root 写成 `root:wheel`，普通用户静默写不进 → 定位日志 09-29 起全部丢失。现主路径不可写时依次落 `~/Library/Logs/aurora_pcap.log`、`/tmp/aurora_pcap_ui.log`，全部失败落 stderr。
> - **pcapLog 轮转**：8MB 上限 + 单备份 `<path>.1` 覆盖式轮转，每 64 次写入才 stat 一次。
> - **游戏流量标记**（`markGameTraffic`，`processPacket` 内调用）：裸 UDP 下 `lastPacketWall` 只由「端口 30031 或已解出真样本的端口」（`learnGamePort` / `isGamePort`，上限 8 个）刷新；`probe` 的命中判据也改为「窗口内 `lastPacketWall` 被刷新」——系统 UDP（QUIC/DNS/mDNS）不再误判成游戏流量。`lastPacketWall` 初值为 0（「从未收到过包」哨兵；`hasRecentTraffic` 有显式 `guard lastPacketWall > 0`），收到首个包前 `hasRecentTraffic` 恒 false。
> - **链路层头长自适应**（`linkLayerHeaderLength(forDLT:)`，`processPacket` 内使用）：按 `pcap_datalink` 决定链路层头长（以太网 14 / 回环 DLT_NULL·DLT_LOOP 4），修系统代理场景（游戏流量经 127.0.0.1 回环转发时按 14 跳会切错 IP 头，静默零坐标）。候选网卡中回环排在全部物理网卡之后。
> - **空闲指数退避**（`supervisorLoop` 内）：连续无流量轮按 2s→4s→…→30s 放大重探间隔（`probeFailStreak = 0` 复位），命中即复位 2s（修空闲态单核 ~17.9% CPU）。
> - **新读取 API**：`readWithTier`（live≤18s/recent≤40s/stale≤90s/lost 四档，`PoseTier`，消费者按档位决定态度）、`readWithFreshness`（fresh/stale 两级，stale 不再返回 nil）、`diagnostics`（把 `read` 返回 nil 的两种原因——从未有样本 vs 过期——分开）。
>
> ---
>
> ## 2026-09-25 自适应网卡落地（用户方案：探测 → 锁定 → 失流重探，结论保留）
>
> - **探测式自适应**（不做多通道并行）：平时不探测；需要时逐张网卡实读 30031 包，谁有真实流量谁被锁定，其余关闭——零探测开销
> - **分级探测窗口**（实测修正）：高嫌疑卡（默认路由 / 上次命中）**2.5s**、其余 **0.5s**
> - **重探间隔 2s / 失流窗口 12s**（用户指定 2s；12s 由实测突发间隔推出）
> - `route` 路径修复：实测 `route` 在 **`/sbin/route`**（`/usr/sbin/route` 不存在 → 旧实现静默失效），改三候选路径 + netstat 兜底 + 5s 缓存
>
> **⚠️ 实测数据（游戏运行中，tcpdump 30 秒采样，全部为真机数据）**：30031 是**突发式**流量——1 秒内 5-6 包，然后**静默 6-9 秒**，30 秒共 25 包（≈0.8 包/秒）。
> 这个实测推翻了旧代码注释里「游戏同步包几十 Hz 持续」的错误假设，并直接解释了三个既有故障：
> ① 探测窗口 0.3s → 100 轮探测全失败（窗口落在静默期）；
> ② 失流窗口 3s → 锁定后在静默期被误判停流、反复横跳；
> ③ `read(maxAge: 1.0)` / `hasRecentTraffic(window: 3.0)` → 坐标与「游戏在跑」判定在静默期频繁失效（小地图忽明忽暗）。现已统一为 `trafficFreshWindow` / `poseFreshWindow`。
>
> **真机验证（2026-09-25，游戏开着）**：
>
> ```
> [10h20m35s] 自适应网卡主循环启动（探测 高嫌疑2500ms/其余500ms / 重探 2s / 失流 12s）
> [10h21m58s] ✓ 探测命中：en8 有真实 30031 流量 → 锁定监听 ← 自动找到正确网卡
> [10h22m20s] [STATS] 21s: 包=68 ← 锁定后持续抓包
> [10h22m38s] ⟳ en8 停流（连续 12s 无 30031 包）→ 重新探测 ← 失流自动重探
> ```
>
> **自检入口**：`./AuroraDriveUI --nic-autotest`（11 项断言：探测轮推进 / 注入真实 UDP 30031 命中锁定 / 失流重探 / 自愈重锁，实测 PASS）。
>
> **2026-09-25 深度复核记录**（结论保留）：
> ① **BPF 过滤器锁死 30031 端口**（原裸 udp 会把全机 UDP 流量抓进来 → 游戏没启动也乱定位，现 `"(tcp port 30031) or (udp port 30031)"`，非 30031 包在内核层就丢弃）；
> ② **新增 `hasRecentTraffic(window:)`**——「游戏到底在不在跑」的最直接信号（30031 有包=游戏在通信，比查进程名可靠：辅助进程 crashpad_handler 也叫「异环」曾被它骗）；
> ③ **新增 `totalPackets`**——区分「端口没流量」与「抓包本身没跑起来」两种故障；
> ④ **新增加速度留档**（`lastAcceleration` / `acceleration(maxAge:)` / `readAcceleration`）——与坐标同包解析，但**坐标系（世界系 vs 车体系）未实测确认，只存不用**，等游戏跑起来标定后再决定怎么喂模型；
> ⑤ **旧 `captureLoop` 忙等修复**——`pcap_next_ex` 超时（`result == 0`）时 `usleep(5_000)` 让出时间片（无流量时不再白烧一个 CPU 核心）；该函数已在重构中删除，现由 `probe` 的 `usleep(2_000)` 承担；
> ⑥ `pcap_open_live` 的 `to_ms` 实参为 **100**（旧档写 20）；
> ⑦ `lastPacketWall` / `statPacketsTotal` 改为**锁内更新**（与 `hasRecentTraffic` / `totalPackets` 的读同步）。

## 一、libpcap C 声明与同步常量

**libpcap C 函数声明**——Package.swift 已链接 pcap 库，这里用 `@_silgen_name` 直连 C 符号（不经模块映射）：

| C 函数 | Swift 签名要点 | 用途 |
|---|---|---|
| `pcap_open_live` | device/snaplen/promisc/to_ms/errbuf → `OpaquePointer?` | 打开网卡（snaplen 65535 全包） |
| `pcap_compile` | p/fp/str/optimize/netmask → Int32 | 编译 BPF 过滤表达式 |
| `pcap_setfilter` | p/fp → Int32 | 应用过滤器 |
| `pcap_loop` / `pcap_breakloop` / `pcap_close` | 循环/中断/关闭 | 抓包循环控制 |
| `pcap_next_ex` | h/d → Int32（0=超时、<0=错误） | **逐包拉取**（本实现用这个而不是回调） |
| `pcap_lookupdev` / `pcap_findalldevs` / `pcap_freealldevs` | 网卡枚举 | 找可用网卡 |

配套 struct：`pcap_pkthdr`（ts/caplen/len）、`bpf_program`（bf_len/bf_insns）、`pcap_if_t`（next/name/description/addresses/flags）、`pcap_callback`（`@convention(c)` C 函数指针类型）。

**同步常量（与 MaaNTE / NetworkLocator.swift 同步）：**

`swift
private let kNorth: (Double, Double, Double) = (-0.013752068070295848, -0.9999054358407049, 0.0)
private let kEast: (Double, Double, Double) = （0.9999054358407049, -0.01375206807029585, 0.0)
private let kMaxLocationAbs: Double = 2_000_000.0
private let kMaxRotationAbs: Double = 180.001
`

- `kNorth`/`kEast`：游戏世界坐标系里"北/东"方向的单位参考向量（用于把视线方向转成罗盘朝向）
- `kMaxLocationAbs`：位置绝对值上限（候选过滤用，2 百万）
- `kMaxRotationAbs`：旋转绝对值上限（180.001 允许 ±180 整）

**底图坐标变换常量：**

`swift
private let kCalibA: Double = 0.016394586684750773
private let kCalibB: Double = 5.693519256055879e-08
private let kCalibTX: Double = 6526.474380746091
private let kCalibTY: Double = 5210.664390686138
`

- 底图坐标系：**map-2026-08**（MaaNTE-Map 13056×13056 扩图版，2026-09-13 升级，新增区域：旧图左侧+1、顶部+7、右侧+6 瓦片，51×51@512px）
- 旧帧 map-2026-06 (11264)：A/B 相同，TX=6293.474380746091、TY=3472.664390686138
- **扩图相对旧图整体平移 (+233, +1738)**——MaaNTE-Map navi-coordinate-calibration.json 三个标定点 delta 完全一致，README 同值——故 TX/TY 直接加偏移，A/B 不变
- **标定点验证**：raw(-134394.56, 199913.53) → map(4323, 8488) ✓

**类型别名**：`Vec3 = (Double, Double, Double)`、`Pose = (Double, Double, Double, Double, Double)`（x, y, z, pitch, heading）、`Flow = (String, Int, String, Int, String)`（srcIP, srcPort, dstIP, dstPort, proto）。

## 二、位操作与 UE5 序化解码

**`bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64`**——从 Python `_bits` 移植，从字节数组的指定位偏移读取 N 位：

- 防御：`count <= 0 || count > 63 || offset < 0` 返回 0；越界（`lastByte > data.count`）返回 0
- 实现：从最高有效字节往回逐字节拼 `value = (value << 8) | data[i]`，再 `(value >> (offset % 8)) & ((1 << count) - 1)`
- **count 上限 63**：UInt64 移位语义（见下面 ue5Vector 的断言坑）

**`ue5Vector(_ data: [UInt8], offset: Int, scale: Int) -> (Vec3, Int, Int, Bool)?`**——UE5 Vector3 序化解码，返回 `(x, y, z), 新offset, bitWidth, isScaled`：

1. 读 7 位 header：`width = header & 63`（低 6 位）、`isScaled = (header >> 6) & 1 != 0`（第 7 位）；`width == 0` 返回 nil
2. 逐分量读 `width` 位，符号扩展：
 `swift
 let sv: Int64 = (v & sign) != 0 ? Int64(bitPattern: v &- modulus) : Int64(v)
 values.append(isScaled ? Double(sv) / Double(scale) : Double(sv))
 `
 - **两个源注释里的坑**：
 - 符号扩展必须走 `Int64(bitPattern:)`：UInt64 的 `&-` 会下溢回绕成巨大正数（Python 大整数无此问题），导致所有负坐标 > kMaxLocationAbs 被淘汰 → 永远 0 候选
 - `Int64(modulus)` 在 width=63 时（modulus=2^63）触发运行时断言（**04h04m SIGTRAP 崩溃事故**）
 - `isScaled` 时除以 scale（移动包：加速度 scale=10、位置 scale=100）

**`ue5Rotator(_ data: [UInt8], offset: Int) -> (Vec3, Int)?`**——UE5 FRotator 序化解码（Pitch, Yaw, Roll）：

- 逐分量：先读 1 位 present 标志，present 非零才读 16 位压缩角
- 解压：`angle = Double(compressed) * 360.0 / 65536.0`，`angle > 180.0` 时减 360（归一到 [-180, 180]）
- 返回 `(pitch, yaw, roll), 新offset`

**`hasValidRotation(_ data: [UInt8], offset: Int) -> Bool`**——检查旋转是否有效：

- 先重放 present 标志收集 `flags`（cursor 前进 `1 + (present ? 16: 0)`）
- 再调 ue5Rotator 解码，`end > data.count * 8` 返回 false
- **有效性判定**：`flags[1] && !flags[2]`（**Pitch 和 Yaw 存在，Roll 通常不存在**）+ `abs(rot.0) <= 90.001`（pitch 限 ±90）+ 三个分量都 ≤ kMaxRotationAbs

**辅助函数**：`dot(_:_:)`（点积）、`distanceSq(_:_:)`（距离平方，避免开方）、`toPose(_ location: Vec3, _ rotation: Vec3) -> Pose`——位置+旋转 → 姿态：
- `pitch = rotation.0`，yaw 转 rad，算视线方向 `viewDir = (cos(pitchRad)*cos(yawRad), cos(pitchRad)*sin(yawRad), sin(pitchRad))`
- `north = dot(viewDir, kNorth)`、`east = dot(viewDir, kEast)`、`heading = atan2(east, north) * 180 / π`，负值 +360 归一到 [0, 360)

## 三、UE5Decoder 状态跟踪与候选选择

**`UE5Decoder`（final class）**——UE5 移动包解码器：状态跟踪 + 候选选择。从 Python `_Decoder` 移植。

**状态字段**：`flow`（当前流）、`lastOffset/lastCapture/lastTime/lastLocation`（上一包解码结果）、`pendingFlow/pendingCandidate/pendingSeen/pendingAt`（新流确认pending）。诊断：`lastCandCount`（最近一次 decode 找到的候选块数）。

**`decode(payload:timestamp:flow:) -> Pose?`——主解码入口，三条分支：**

1. **流变化**：`flow != self.flow` 时 → `newFlowCandidate` 选候选 → `confirmFlow` 确认（需连续 2 包一致）→ 成功才切换 `self.flow = flow`
2. **首包**：`lastTime == nil || lastCapture == nil` → `newFlowCandidate` 直接选定，切换 flow
3. **跟踪中**：
 - `gap = max(0, timestamp - lastCapture)`、`expected = lastTime + gap`
 - 候选集：优先 `offset == lastOffset` 的对齐候选（`aligned`），空则全部（`tracking`）
 - `selected = tracking.min(by: trackingKey)`——**trackingKey**：`timeError + spatialPenalty`，spatialPenalty = `min(dist / 5000², 100)`（离上一位置太远的大惩罚）
 - **timeError > 1.0 时重取**：`reacquireCandidates` 过滤（clientTime ≥ 0.01、offset ≤ 512、加速度 ≤ 10000、位置 ≤ kMaxLocationAbs）→ 取 clientTime 最大的，清 pending、切换 flow
4. 选定后读解码链：`ue5Vector(offset: bitOffset + 32, scale)`（加速度）→ `ue5Vector(scale)`（位置）→ `ue5Rotator`（旋转）
5. 更新状态：`lastTime/lastOffset/lastCapture/lastLocation`，返回 `toPose(location, rotation)`

**`findCandidates(_ payload: [UInt8]) -> [Candidate]?`**——扫描包中所有有效的移动块：

- 搜索范围：`for offset in 190..<searchEnd`，`searchEnd = min(512, payload.count * 8 - 60)`，`searchEnd > 190` 才继续（**payload ≥ 32 字节**——注释：旧代码 `<70` 丢弃把 48 字节的 c2s 移动包全部挡在了 decode 之外，对齐 MaaNTE 原版"payload 非空即试"）
- 逐 offset 四重过滤：
 1. **时间戳** 位 float，`isFinite && >= 0 && < 100_000`
 2. **加速度**：`ue5Vector(offset+32, scale)`，要求 `accelScaled`、bitWidth 1–16、分量绝对值 < 50000
 3. **位置**：`ue5Vector(cursor, scale)`，要求 `locScaled`、bitWidth 20–32、分量绝对值 ≤ kMaxLocationAbs
 4. **旋转**：`hasValidRotation(payload, offset: rotationOffset)`
- **★ 关键修复（20260913，注释）**：ue5Vector 返回的 `locEnd` 已经是"位置向量结束后"的位偏移（= offset + 7 位 header + 3×width 值位），即 rotation 的起始位。**旧代码 `locEnd + 7` 多加 7 位 → rotation 解析错位 → hasValidRotation 永远失败 → 0 候选**。MaaNTE 原版语义：`location_end = location_start + 7 + width*3 == ue5Vector 返回的 cursor`。故 `rotationOffset = locEnd`。

**`confirmFlow`**——新流两包确认机制：pendingSeen 达到 2（timeOk：`timeDelta >= 0.001 && abs(timeDelta - gap) <= 0.5`；offsetOk：offset 相等；stepOk：位置距离平方 ≤ 6.4e9）才返回候选，防误切到无关流。

**`clearPending`**：四个 pending 字段归零/置 nil。

## 四、CoordinateCapture 抓包器与 worldToMapPixel

> ## 🔴 2026-09-29 重要复核：**本节描述的是旧版单线程抓包器，现役结构已整体重写**
>
> **本节（及其他各节）的行号基准是 2026-09-25 之前的版本**。现役 `CoordinateCapture`
> 已从「**一个 `captureThread` 跑 `captureLoop`**」重构为
> 「**`supervisorLoop` 主管 + 探测式自适应网卡状态机**」。
>
> ### 证据：本节提到的三个成员在代码中已不存在
>
> | 本文提到的符号 | 实测 | 现役对应物 |
> |---|---|---|
> | `captureThread` | ❌ grep 不到 | `supervisorLoop` |
> | `captureLoop` | ❌ grep 不到 | `listenLocked(handle:name:)` + `probe(...)` |
> | `pcapHandle`（作为成员） | ❌ grep 不到 | 本地句柄，经 `openWithFilter` 返回后即传参，不长期持有 |
> | `devName` | ❌ grep 不到 | 改为 `setActiveInterface(_:)` + `candidateInterfaces()` |
>
> ### 结构对比
>
> | 维度 | 本文描述的**旧结构** | **现役结构**（实测） |
> |---|---|---|
> | 网卡选择 | `start` 里**一次性**枚举 + 尝试打开，选中即 `break` | **探测式状态机**：逐卡实读 30031 包，谁有真实流量谁被锁定 |
> | 网卡变更 | 不支持（选错就完了） | **失流自动重探**（重探 2s / 失流窗口 12s） |
> | 主循环 | `Thread { captureLoop }` | `supervisorLoop` 主管 + `DispatchSourceTimer` |
> | 探测窗口 | 无 | **分级**：高嫌疑卡 2.5s / 其余 0.5s |

**PAC 崩溃规避设计**：pcap 回调**用 C 函数指针不用闭包**——"避免 Apple Silicon PAC 签名问题"。全局单例 `nonisolated(unsafe) var coordinateCaptureActive: CoordinateCapture?` 承载回调目标；`coordinateCaptureCallback: pcap_callback` 解引用 header/packet 后转调 `capture.processPacket(header:packet:)`。

**`pcapLog(_ msg: String)`**：日志写到 `/tmp/aurora_pcap.log`（ISO8601 时间戳 + 消息），文件存在则 seekToEnd 追加，否则创建。

**`CoordinateCapture`（final class）**——自包含网络坐标抓取：libpcap 抓 TCP 30031 端口 → UE5 包解析 → 世界坐标。

**状态**：`decoder = UE5Decoder`、`sample: Pose?` + `sampleAt` + `lastSampleWall`、`interval = 1.0/30.0`（30Hz 采样限频）、`running` + `lock`（NSLock，sample 读写跨线程）；15 秒窗口统计字段 `statPackets/statS2C/statC2S/statDecodeCalls/statCandHits/statCandPeak/statSamples`——仅抓包线程读写，无需加锁；**跨线程的例外**：`lastPacketWall`（`hasRecentTraffic` 的唯一依据）与 `statPacketsTotal`（`totalPackets` 的数据源）在 `processPacket` 的**锁内更新**，与二者的锁内读保持同步。旧结构中的成员 `pcapHandle` / `captureThread` 已随重构删除。

**`start -> Bool`**——遍历所有网卡，找到有 30031 端口流量的那个：（注：现役 `start` 仅启动 `supervisorLoop`，网卡遍历逻辑已移至 `probe` / `supervisorLoop`，见上「现役结构」）

1. `guard !running else { return true }`（幂等）
2. `pcap_findalldevs` 枚举网卡（失败记日志返回 false）
3. **网卡选择（2026-09-25 重构，治「小地图永远无定位」）**：
 - **① 枚举全部网卡名 → 立即 freealldevs**（旧实现边遍历边尝试打开，枚举器与尝试耦合）；
 - **② 尝试顺序 = 默认路由接口置顶 + 其余物理网卡按枚举顺序**（`route -n get default` 解析 interface，只在 start 调一次）；跳过前缀从 6 个扩到 10 个：`lo/pdp/utun/awdl/bridge/xhc` + **`ap/anpi/gif/stf`**；
 - **⚠️ 事故根因（实测）**：`ap1` 是 macOS Wi-Fi 热点接口（status inactive、**Ipkts 恒 0**），能被 pcap 打开且枚举排最前——旧逻辑「第一个能打开的就用」选中它抓空气 → 小地图永远无定位；而游戏流量实际走默认路由接口 `en8`（137GB 流量）。**热点前缀 `ap` 是旧跳过表的漏网之鱼**；
 - **③ `openWithFilter` 抽成独立方法**（打开 + 30031 过滤器，任一步失败关句柄返回 nil）；
 - **④ 选中非默认路由接口时打明确告警**（"若定位无数据优先怀疑网卡选错"）；
 - **旧过滤器历史坑保留**：原 `"tcp port 30031 or udp"` 裸 udp 会把全机 UDP 流量抓进来（DNS/mDNS/广播）→ 任意 ≥32 字节杂包被硬解成坐标 →「游戏没启动定位疯狂乱跳」；现锁死 `"(tcp port 30031) or (udp port 30031)"`，非 30031 包在内核 BPF 层丢弃
4. 选中即 break（`devName` + `pcapHandle`），`pcap_freealldevs` 释放枚举
5. `running = true`，起 `Thread { self?.captureLoop }`（名字 `com.aurora.coordinate-capture`），返回 true

**`captureLoop`（旧结构符号，2026-09-25 重构后已从源码删除，见上「🔴 重要复核」证据表）**——现役对应 `listenLocked(handle:name:)` + `probe` 的读包循环：**用 pcap_next_ex 不用回调，避免 PAC 崩溃**：`while running` 循环 `pcap_next_ex(handle, &headerPtr, &packetPtr)`；`result == 1` → `processPacket`；`result < 0` break；**`result == 0`（超时无包）**：listenLocked 内判失流（读 `lastPacketWall`，连续 `streamLostWindow` 秒无包 → 返回交主循环重探）；probe 内 `usleep(2_000)` 让出（**源注释**：pcap 超时 `to_ms=100`，无包让出后继续，包一到立即返回）。

**`processPacket(header:packet:)`**——逐包解析（listenLocked/probe 串行调用，统计字段无需加锁）：

1. `statPackets += 1`，`defer { logStats }`
2. 以太网头 14 字节 → IPv4 校验（`ipVersion != 4` return）→ IP 头长 `* 4` → 协议号（offset+9）→ srcIP/dstIP（offset+12..19 拼点分十进制）
3. 传输层：TCP(6) **可变头**（`offset += Int(data[offset+12] >> 4) * 4`）；UDP(17) 固定 8 字节头——对齐 MaaNTE 原版
4. **方向过滤**：`packetDirection(src:dst:)` → 只处理 `c2s`（本地→服务器）；`s2c` 和 `unknown` return
5. `guard payload.count >= 32`（findCandidates 需 searchEnd > 190 位）→ 读 srcPort/dstPort（transportStart 前两字节大端）
6. `decoder.decode(...)` 成功 → `statSamples += 1` → **限频写入**：`now - lastSampleWall >= interval` 才更新 `sample/sampleAt/lastSampleWall`（锁内）
7. `decoder.lastCandCount > 0` → statCandHits/peak 累计

**`logStats`** 秒一行统计汇总（代替原先每包 的刷屏日志）——`[STATS] Ns: 包=X s2c=N c2s送解=N 解码调用=N 候选包=N/峰=N 样本=N`，然后归零。

**`hasRecentTraffic(window: Double = 3.0) -> Bool`——9-23 新增**1 端口最近 `window` 秒内是否真有数据包。**这是判断「游戏到底在不在跑」最直接、最便宜的信号**（源码注释原文）：定位数据全部来自这个端口，有包=游戏在通信；比查进程名可靠得多（辅助进程 crashpad_handler 也叫「异环」，曾被它骗成"游戏在跑"）；只读一个计数器，零 IPC、零 sysctl、零遍历。游戏运行时同步包是持续的（几十 Hz），3 秒窗口足够灵敏，也不会因短暂卡顿误判掉线。**锁内读**（与 processPacket 的锁内写同步）。

**`totalPackets: Int`——9-23 新增**：自抓包启动以来收到的包总数（锁保护）。用于区分「端口没流量」与「抓包本身没跑起来」两种不同故障——totalPackets=0 说明抓包没跑起来（权限/网卡问题），>0 但 hasRecentTraffic=false 说明抓包正常但 30031 没流量（游戏没开）。

**`read(maxAge: Double = 1.0) -> Pose?`**：锁内取 sample；**过期判定**：`now - lastSampleWall > maxAge`（默认 1 秒）返回 nil——调用方拿到的坐标最多滞后 1 秒，超龄即视为无效（防旧坐标误导导航）。

**`readAcceleration(maxAge: Double = 0.5) -> Vec3?`——2026-09-22 新增**：读取最新加速度（来自同一个 30031 包，与坐标同源，经 `decoder.acceleration(maxAge:)` 带新鲜度门——过期返回 nil，避免拿旧值当实时值）。**⚠️ 坐标系尚未实测确认**（世界系 vs 车体系），单位推测为 cm/s²（与位置 cm 同源）。目前仅供 UI 展示与后续标定，**不要直接当物理加速度喂给控制逻辑**。对应 UE5Decoder 侧：`lastAcceleration` 在 decode 主入口与坐标同包解析留档（注释："这个向量本来就挨在位置前面，findCandidates 已经解析过了，之前 decode 里用 `_` 丢掉"）。

**`close`**：`running = false` → `pcap_breakloop` → `captureThread?.cancel` → `pcap_close` → handle 置 nil；`deinit { close }` 保证析构时停止。

**`worldToMapPixel(_ pose: Pose) -> (mapX: Double, mapY: Double, heading: Double)`**——世界坐标 → 地图像素（与 NetworkLocator.swift 的校准常量同步）：

`swift
let mapX = kCalibA * wx + kCalibB * wy + kCalibTX
let mapY = kCalibA * wy - kCalibB * wx + kCalibTY
`

线性变换（A 是缩放、B 是微量旋转耦合、TX/TY 是平移），heading 直接透传（已在 toPose 算好）。

**CoordinateCapture 文档至此完整**（全覆盖：C 声明与常量 → 位操作与 UE5 解码 → UE5Decoder → 抓包器与坐标变换）。

---

## 🔑 2026-09-25 新协议逆向（重大突破）

### 背景
游戏 1.4.x 更新后，30031 端口的移动包**不再是 MaaNTE 时代的裸 UE5 位流块**，改为
**protobuf 封装 + 位流坐标字段**。MaaNTE 原版 `_Decoder` 对新包恒返回 `None`
（已用原版代码实测 3/3 个大包全 None），生产表现即 `候选包=0 / 样本=0` —— 小地图永远无定位。

### 逆向出的包结构（s2c，服务器→客户端）
- payload 长度：**72 或 76 字节**
- 前 56 字节固定前缀：
 `
 48000000140000000000000000000a000c000400000008000a0000006204
 0000280000001000000000000a0018000400080010000a000000
 `
- 第 56 字节起是**双记录**（每记录 64 位步长），坐标为**位偏移**字段：

| 位偏移 | 含义 | 实测特征 |
|---|---|---|
| bit 498 | 坐标分量 X1 | 移动时每包变化 |
| bit 509 | 高度 Z1 | 近似恒定（31851.9） |
| bit 562 | 坐标分量 X2 | 与 X1 同步变化 |
| bit 573 | 高度 Z2 | 近似恒定（31852.9） |

### 判定依据（真机实测，样本存 `tools/reverse/samples/`）
- **移动时**：X1/X2 每包同步变化（服务器批量下发轨迹点，Δ ≈ -1.12/包）
- **静止时**：字段完全不变（idle 样本仅 1 个值）
- **像素落图**：转 13056² 地图后落在密集城区（与游戏内小地图十字路口吻合）

### 关键代码修正（真正的断点）
`processPacket` 原先在 **s2c 包上直接 `return`**（沿用 MaaNTE「移动包只走 c2s」的旧假设）——
而新协议移动包**全部是 s2c**，导致新解码器永远收不到包。现已放开 s2c 通道
（由 56 字节前缀 + 长度 {72,76} 精确识别，无关流量会被快速拒绝）。

### 新增产物
- `tools/reverse/extract_coord.py` —— 独立坐标提取器（`--live` 实时 / pcap 离线，`--map` 输出地图像素）
- `tools/reverse/samples/*.pcap` —— 固化真机样本（移动 / 静止 / 转向）
- `--proto-selftest` —— 用固化样本验证 Swift 解码器（14 项断言，PASS）

### 验证记录
`
[生产日志] [STATS] 15s: 包=8 s2c=1 解码调用=2 候选包=1/峰=1 样本=1 新协议=10
 ↑ 新协议解码器持续输出坐标
[自检] ✓ 移动样本解出坐标 74/274 ✓ 移动样本坐标在变化 X 跨度 81.74
 ✓ 静止样本为单值（无抖动） ✓ 像素落在地图内 (6127.0, 4776.0)
`

---

## 🆕 运行时归属与启动调用链（含 09-30 结论勘误）

> ⚠️ 上文「2026-09-25 新协议逆向」中的「bit498/509 是坐标、移动包全部是 s2c」结论已被 09-30 实测推翻，保留仅作逆向过程存档。

### 启动调用链（谁调 `start`）

- **生产路径（懒初始化）**：MissionConsole 的**网络定位定时器**——`MissionConsole` 用 `DispatchSourceTimer`（`repeating` 间隔 1.0/10.0 秒）跑在 `com.aurora.netlocate` 队列，事件经 `main.async` 调 `state.runNetworkLocateStep`。`runNetworkLocateStep`（`AuroraDriveApp.swift`）首次执行时创建 `CoordinateCapture` 并 `cc.start`，整个过程由双检锁 `healerInitLock` 保护（锁声明同在该处），`start` 返回 true 才置 `locateCtx.networkReady = true`。
 - ⚠️ **行为描述修正**：原文称「网络定位定时器 **10Hz**」，现役已改为**空闲降频**——`MissionConsole` 注释写明「空闲态降到 2Hz（10Hz / 5），只在开车/录制时才保持 10Hz 实时性」，实现是 `nlIdleSkip < 5` 早退。**即：开车/录制时 10Hz，空闲时约 2Hz**。
- `start`（`CoordinateCapture.swift`）只是置 `running = true` 并起专属线程 `supervisorThread`（名字 `com.aurora.coordinate-capture`）跑 `supervisorLoop`——**抓包线程自成一个 Thread，不在 captureQueue 也不在主线程**，与 CaptureEngine（SCStream / `aurora.capture` 队列）完全独立。
- **自检路径**：`--nic-autotest` 自建实例 `cc.start`（`AuroraDriveApp.swift`）——即 `let cc = CoordinateCapture` 后 `let started = cc.start`。

### 数据状态与消费方

| 成员 | 说明 |
|---|---|
| `sample` / `sampleAt` / `lastSampleWall` | 最新坐标（锁保护，`processPacket` 解出真样本时限频 1/30s 写入） |
| `read(maxAge:)` | 锁内读坐标，超 `poseFreshWindow`（18s）返回 nil |
| `readWithTier` / `readWithFreshness` / `diagnostics` | 分级读取与诊断（把 `read` 返回 nil 的两种原因分开） |
| `hasRecentTraffic(window:)` | `lastPacketWall` 在窗口内即 true；初值 0 哨兵保证首包前恒 false |
| `totalPackets` | 累计包总数（区分「没流量」与「抓包没跑起来」） |
| `locateSource` | 在 `AuroraDriveApp.swift`：`coordinateCapture == nil` 或 `!networkReady` → `.packetError`；有流量 → `.ready`；否则 `.noGame`（10Hz 调用） |
| 定位消费 | 在 `AuroraDriveApp.swift`：`let tierRead = cc.readWithTier` 三档分级（live/recent/stale/lost）→ UI 显示/决策降权分档 |

### 与 CaptureEngine（代码-03）的关系

- **互不依赖、线程完全独立**：CoordinateCapture 跑自己的 `com.aurora.coordinate-capture` 线程 + libpcap（内核 BPF 过滤），CaptureEngine 跑 SCStream + `aurora.capture` 队列。引擎模式（`--engine`）与本地模式的差异只影响 SCStream 帧路径（见代码-03 第八节），**网络定位在两种模式下都在各自进程跑**（UI 进程常开，MissionConsole 定时器不区分模式）。
- **进程归属**：CoordinateCapture 的创建点在 `DriveState`（UI 进程与引擎进程各有 `DriveState` 实例时各自实例化——引擎进程的 `runNetworkLocateStep` 同样会被调用，其 `pcapLog` 写同一路径链）。`/tmp/aurora_pcap.log` 历史上被 root 引擎写过、导致普通用户写不进的事故即源于此（见 `pcapLog` 的候选路径注释）。
- **游戏流量窗口的一致性**：抓包侧 `streamLostWindow`（22s）> `trafficFreshWindow`（20s）> `poseFreshWindow`（18s），三层窗口层级是 09-30 定案的（见各常量注释）——先判「游戏在通信」（traffic），再判「坐标可消费」（pose），最后网卡自己判「停流重探」（streamLost）。