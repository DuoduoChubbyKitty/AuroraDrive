// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ═══════════════════════════════════════════════════════════════════════════
// 【出处标注 · 品牌澄清】2026-10-04
//   本文件**整体移植自上游开源项目 MaaNTE 的 `nte_coordinate_api.py`**
//   （AGPL-3.0）。下文注释里的「MaaNTE」一律是**上游项目名**，用于交代
//   协议逆向结论、过滤器口径、标定常量的来源 —— **它不是本产品的品牌**。
//   本产品品牌：`AuroraDrive`（见 `App/AuroraBrand.swift`）。
//   保留出处的理由（这条尤其硬）：
//     · AGPL-3.0 的**署名义务**要求保留出处，抹掉等于违反许可证；
//     · 30031 端口、`tcp port 30031 or udp` 过滤器、kCalibA/B/TX/TY 标定
//       常量全部是"上游实测 + 我们复测"的结论，抹掉出处就没法复核。
//   故：出处保留；品牌层（用户可见字符串 / 标识符）不得出现上游名。
// ═══════════════════════════════════════════════════════════════════════════
// 从 MaaNTE nte_coordinate_api.py 移植（AGPL-3.0）
// 自包含网络定位：libpcap抓包 → UE5移动包解析 → 世界坐标+朝向

import Foundation
import Darwin

// MARK: - libpcap C函数声明（Package.swift已链接pcap库）

struct pcap_pkthdr {
    var ts: timeval
    var caplen: UInt32
    var len: UInt32
}

struct bpf_program {
    var bf_len: UInt32
    var bf_insns: OpaquePointer?
}

typealias pcap_callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void

@_silgen_name("pcap_open_live")
func pcap_open_live(_ device: UnsafePointer<CChar>?, _ snaplen: Int32, _ promisc: Int32, _ to_ms: Int32, _ errbuf: UnsafeMutablePointer<CChar>?) -> OpaquePointer?

@_silgen_name("pcap_compile")
func pcap_compile(_ p: OpaquePointer, _ fp: UnsafeMutablePointer<bpf_program>, _ str: UnsafePointer<CChar>, _ optimize: Int32, _ netmask: UInt32) -> Int32

@_silgen_name("pcap_setfilter")
func pcap_setfilter(_ p: OpaquePointer, _ fp: UnsafeMutablePointer<bpf_program>) -> Int32

@_silgen_name("pcap_loop")
func pcap_loop(_ p: OpaquePointer, _ cnt: Int32, _ callback: pcap_callback?, _ user: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("pcap_breakloop")
func pcap_breakloop(_ p: OpaquePointer)

@_silgen_name("pcap_close")
func pcap_close(_ p: OpaquePointer)

@_silgen_name("pcap_next_ex")
func pcap_next_ex(_ p: OpaquePointer, _ h: UnsafeMutablePointer<UnsafeMutablePointer<pcap_pkthdr>?>, _ d: UnsafeMutablePointer<UnsafePointer<UInt8>?>) -> Int32

// ⚠️ 2026-09-30 新增：链路层类型查询。
//
// 【为什么必须加】本文件旧实现在 `processPacket` 里**硬编码 `offset = 14`**
// 假定「链路层 = 以太网头（14 字节）」。这在本机物理网卡（en0/en8，DLT_EN10MB）
// 上是对的，所以历来没暴露问题。
//
// 但它对**回环 lo0（DLT_NULL，链路层只有 4 字节）**是错的 ——
// 按 14 字节跳会把 IP 头切错位，`ipVersion` 读到垃圾 → 直接 return。
// 表现出来就是「抓包已启动、包数在涨，但一个坐标都解不出」。
//
// 【触发场景】用户开启**系统代理**（Clash / Surge 等）后，游戏高频流量
// 走 `127.0.0.1:<proxy port>` 回环，只有回环上才是明文；
// 物理网卡上看到的是代理转发出去的 **TLS 密文**（`16 03 03` / `17 03 03`），
// 永远解不出坐标。此时若不能正确解析回环包，抓包功能等于失效。
//
// 【修法】用 `pcap_datalink()` 查询每张网卡的实际链路层类型，按类型决定
// 头部长度。**以太网路径行为逐字不变**（仍为 14），仅在非以太网时改用
// 正确的偏移 —— 严格优于原状态。
@_silgen_name("pcap_datalink")
func pcap_datalink(_ p: OpaquePointer) -> Int32

@_silgen_name("pcap_lookupdev")
func pcap_lookupdev(_ errbuf: UnsafeMutablePointer<CChar>?) -> UnsafePointer<CChar>?

@_silgen_name("pcap_findalldevs")
func pcap_findalldevs(_ alldevs: UnsafeMutablePointer<UnsafeMutablePointer<pcap_if_t>?>, _ errbuf: UnsafeMutablePointer<CChar>?) -> Int32

@_silgen_name("pcap_freealldevs")
func pcap_freealldevs(_ alldevs: UnsafeMutablePointer<pcap_if_t>?)

struct pcap_if_t {
    var next: UnsafeMutablePointer<pcap_if_t>?
    var name: UnsafePointer<CChar>?
    var description: UnsafePointer<CChar>?
    var addresses: OpaquePointer?
    var flags: UInt32
}



// MARK: - 常量（与MaaNTE同步）

private let kNorth: (Double, Double, Double) = (-0.013752068070295848, -0.9999054358407049, 0.0)
private let kEast: (Double, Double, Double) = (0.9999054358407049, -0.01375206807029585, 0.0)
private let kMaxLocationAbs: Double = 2_000_000.0
private let kMaxRotationAbs: Double = 180.001

// 坐标变换常量（与NetworkLocator.swift同步）
// 底图坐标系: map-2026-08（MaaNTE-Map 13056×13056 扩图版，2026-09-13 升级，
// 新增区域：旧图左侧+1、顶部+7、右侧+6 瓦片，51×51@512px）。
// 旧帧 map-2026-06 (11264): A/B 相同, TX=6293.474380746091, TY=3472.664390686138。
// 扩图相对旧图整体平移 (+233, +1738)——MaaNTE-Map navi-coordinate-calibration.json
// 三个标定点 delta 完全一致，README 同值——故 TX/TY 直接加偏移，A/B 不变。
// 标定点验证: raw(-134394.56, 199913.53) → map(4323, 8488) ✓
let kCalibA: Double = 0.016394586684750773
let kCalibB: Double = 5.693519256055879e-08
let kCalibTX: Double = 6526.474380746091
let kCalibTY: Double = 5210.664390686138

// MARK: - 类型

typealias Vec3 = (Double, Double, Double)
typealias Pose = (Double, Double, Double, Double, Double)  // x, y, z, pitch, heading
typealias Flow = (String, Int, String, Int, String)  // srcIP, srcPort, dstIP, dstPort, proto

// MARK: - Bit操作（从Python _bits移植）

/// 从字节数组的指定位偏移读取N位
func bits(_ data: [UInt8], offset: Int, count: Int) -> UInt64 {
    if count <= 0 || count > 63 || offset < 0 { return 0 }
    let firstByte = offset / 8
    let lastByte = (offset + count + 7) / 8
    if firstByte < 0 || lastByte > data.count || lastByte <= firstByte { return 0 }
    var value: UInt64 = 0
    for i in stride(from: lastByte - 1, through: firstByte, by: -1) {
        if i < 0 || i >= data.count { return 0 }
        value = (value << 8) | UInt64(data[i])
    }
    return (value >> UInt64(offset % 8)) & ((UInt64(1) << UInt64(count)) - 1)
}

// MARK: - UE5序列化解码（从Python _vector/_rotator移植）

/// UE5 Vector3序列化解码
/// 返回: (x, y, z), 新offset, bitWidth, isScaled
func ue5Vector(_ data: [UInt8], offset: Int, scale: Int) -> (Vec3, Int, Int, Bool)? {
    let header = bits(data, offset: offset, count: 7)
    var cursor = offset + 7
    let width = Int(header & 63)
    let isScaled = (header >> 6) & 1 != 0
    if width == 0 { return nil }

    let sign = UInt64(1) << (width - 1)
    let modulus = UInt64(1) << width
    var values: [Double] = []
    for _ in 0..<3 {
        let v = bits(data, offset: cursor, count: width)
        cursor += width
        // 符号扩展必须走 Int64(bitPattern:)：UInt64 的 &- 会下溢回绕成巨大正数（Python大整数无此问题），
        // 导致所有负坐标 > kMaxLocationAbs 被淘汰 → 永远0候选。
        // 注意 Int64(modulus) 在 width=63 时（modulus=2^63）触发运行时断言（04:04 SIGTRAP 崩溃事故）
        let sv: Int64 = (v & sign) != 0 ? Int64(bitPattern: v &- modulus) : Int64(v)
        values.append(isScaled ? Double(sv) / Double(scale) : Double(sv))
    }
    return ((values[0], values[1], values[2]), cursor, width, isScaled)
}

/// UE5 FRotator序列化解码（Pitch, Yaw, Roll）
func ue5Rotator(_ data: [UInt8], offset: Int) -> (Vec3, Int)? {
    var values: [Double] = []
    var cursor = offset
    for _ in 0..<3 {
        let present = bits(data, offset: cursor, count: 1)
        cursor += 1
        var angle: Double = 0
        if present != 0 {
            let compressed = bits(data, offset: cursor, count: 16)
            cursor += 16
            angle = Double(compressed) * 360.0 / 65536.0
            if angle > 180.0 { angle -= 360.0 }
        }
        values.append(angle)
    }
    return ((values[0], values[1], values[2]), cursor)
}

/// 检查旋转是否有效
func hasValidRotation(_ data: [UInt8], offset: Int) -> Bool {
    var flags: [Bool] = []
    var cursor = offset
    for _ in 0..<3 {
        let present = bits(data, offset: cursor, count: 1) != 0
        flags.append(present)
        cursor += 1 + (present ? 16 : 0)
    }
    guard let (rot, end) = ue5Rotator(data, offset: offset) else { return false }
    if end > data.count * 8 { return false }
    // Pitch和Yaw存在，Roll通常不存在
    return flags[1] && !flags[2]
        && abs(rot.0) <= 90.001
        && abs(rot.0) <= kMaxRotationAbs
        && abs(rot.1) <= kMaxRotationAbs
        && abs(rot.2) <= kMaxRotationAbs
}

// MARK: - 辅助函数

func dot(_ a: Vec3, _ b: Vec3) -> Double {
    return a.0 * b.0 + a.1 * b.1 + a.2 * b.2
}

func distanceSq(_ a: Vec3, _ b: Vec3) -> Double {
    let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
    return dx*dx + dy*dy + dz*dz
}

/// 位置+旋转 → 姿态(x, y, z, pitch, compass_heading)
func toPose(_ location: Vec3, _ rotation: Vec3) -> Pose {
    let pitch = rotation.0
    let pitchRad = pitch * .pi / 180.0
    let yawRad = rotation.1 * .pi / 180.0
    let viewDir: Vec3 = (
        cos(pitchRad) * cos(yawRad),
        cos(pitchRad) * sin(yawRad),
        sin(pitchRad)
    )
    let north = dot(viewDir, kNorth)
    let east = dot(viewDir, kEast)
    var heading = atan2(east, north) * 180.0 / .pi
    if heading < 0 { heading += 360.0 }
    return (location.0, location.1, location.2, pitch, heading)
}

/// 判断IP是否是本地地址
func isLocalishAddress(_ ipStr: String) -> Bool {
    guard let addr = ipStr.split(separator: ".").compactMap({ Int($0) }).count == 4 ? ipStr : nil else {
        return ipStr.hasPrefix("fe80") || ipStr.hasPrefix("::1") || ipStr == "127.0.0.1"
    }
    // 简化：检查是否是私有地址
    let parts = ipStr.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    if parts[0] == 10 { return true }
    if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return true }
    if parts[0] == 192 && parts[1] == 168 { return true }
    if parts[0] == 127 { return true }
    if parts[0] == 169 && parts[1] == 254 { return true }
    return false
}

/// 判断包方向
func packetDirection(src: String, dst: String) -> String {
    if src.isEmpty || dst.isEmpty { return "unknown" }
    let srcLocal = isLocalishAddress(src)
    let dstLocal = isLocalishAddress(dst)
    if srcLocal && !dstLocal { return "c2s" }
    if dstLocal && !srcLocal { return "s2c" }
    return "unknown"
}

// MARK: - 解码器（从Python _Decoder移植）

/// UE5移动包解码器：状态跟踪+候选选择
final class UE5Decoder {
    private var flow: Flow?
    private var lastOffset: Int?
    private var lastCapture: Double?
    private var lastTime: Double?
    private var lastLocation: Vec3?
    private var pendingFlow: Flow?
    private var pendingCandidate: Candidate?
    private var pendingSeen: Int = 0
    private var pendingAt: Double?

    /// 最近一次 decode 找到的候选块数（诊断用）
    private(set) var lastCandCount = 0

    // ── 新协议状态（2026-09-25 逆向，见 decodeProtoMove）──

    /// 上一个新协议世界坐标（用于从相邻采样估计朝向）
    private var lastProtoWorld: Vec3?
    /// 上一次估计出的朝向（度）
    private var lastProtoHeading: Double?
    /// 上一次新协议采样时间
    private var lastProtoAt: Double?
    /// 新协议解码成功计数（诊断：区分「新协议在跑」与「旧路径在跑」）
    private(set) var protoSamples = 0

    /// 旧「新协议」路径（decodeProtoMove）是否启用 —— 默认 **关闭**（2026-09-30 根因修复）。
    ///
    /// 该路径解出的「坐标」实测是 S2C 心跳包里的**微秒时钟**（见 decode() 顶部注释）。
    /// 仅设 `AURORA_LEGACY_PROTO=1` 时启用，用于对照诊断；定位一律走
    /// findCandidates（MaaNTE 上游同款 UE5 位流扫描 + 连续性锁定）。
    static let legacyProtoEnabled: Bool =
        ProcessInfo.processInfo.environment["AURORA_LEGACY_PROTO"] == "1"

    typealias Candidate = (clientTime: Double, offset: Int, acceleration: Vec3, location: Vec3)

    /// 主解码入口
    func decode(payload: [UInt8], timestamp: Double, flow: Flow) -> Pose? {
        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-09-30 根因修复：decodeProtoMove（旧「新协议」路径）默认停用
        // ══════════════════════════════════════════════════════════════════
        //
        // 【被推翻的旧结论】2026-09-25 时认为「30031 S2C 76 字节包是 protobuf
        //   移动包，bit498/509/562/573 是坐标」，用「ΔX=X2−X1=−2145.77 像移动
        //   21.5m」做了物理自洽性论证。**该论证被 2026-09-30 实测推翻**：
        //
        //   1. 该包整段（除 4 字节长度前缀）里**唯一变化**的字节是 56~63 与
        //      68~71；解出 u32 @56 = 每 15 秒恒定 +15,000,000
        //      = **每秒 +1,000,000 的微秒时钟**（1323822037→1338821708→…）。
        //   2. bit498/509 恰好落在这个时钟区（字节 62~66/63~67）：
        //      「X 的微小漂移」= 时钟递增的位模式被当 float 解读；
        //      「Y 恒 31866.77」= 固定字节 `da 1e df 08` 的位模式。
        //      ⟹ 旧判据「ΔX 像移动」其实是**时钟走字**，恰好像匀速移动，纯属巧合。
        //   3. 用户传送 4~5 次该值纹丝不动（时钟当然不随传送变化）。
        //   4. 真实移动包在 **C2S UDP 30212**（8Hz，客户端上报移动 RPC），
        //      MaaNTE 上游方案对 S2C 一律丢弃、只解 C2S；而我们的过滤器
        //      `port 30031` 把 UDP 30212 全部挡在门外。
        //
        // 【处理】decodeProtoMove 函数体保留（铁律：不删既有代码），
        //   仅停用其在本入口的优先权；确需对照旧行为时设
        //   `AURORA_LEGACY_PROTO=1` 重新启用（仅用于诊断，勿用于定位）。
        if Self.legacyProtoEnabled, let mv = decodeProtoMove(payload) {
            let (x, y) = (mv.x, mv.y)
            // 朝向：新协议未逆出 rotator，用同包内两条相邻采样（相距 ≈22m）的
            // 方向差估计运动方向；无位移则沿用上次朝向。
            var heading = lastProtoHeading ?? 0
            let dx = mv.prev.0 - x
            let dy = mv.prev.1 - y
            if dx * dx + dy * dy > 1e-6 {
                heading = atan2(dy, dx) * 180.0 / .pi
            } else if let pw = lastProtoWorld {
                let mx = x - pw.0
                let my = y - pw.1
                if mx * mx + my * my > 1e-6 {
                    heading = atan2(my, mx) * 180.0 / .pi
                }
            }
            lastProtoWorld = (x, y, 0)
            lastProtoHeading = heading
            lastProtoAt = timestamp
            protoSamples += 1
            lastCandCount = 1
            return (x, y, 0, 0, heading)
        }

        guard let candidates = findCandidates(payload), !candidates.isEmpty else {
            lastCandCount = 0
            return nil
        }
        lastCandCount = candidates.count

        var selected: Candidate?
        if let selfFlow = self.flow, flow != selfFlow {
            guard let candidate = newFlowCandidate(candidates) else { return nil }
            selected = confirmFlow(flow, candidate, timestamp)
            if selected == nil { return nil }
            clearPending()
            self.flow = flow
        } else if lastTime == nil || lastCapture == nil {
            guard let candidate = newFlowCandidate(candidates) else { return nil }
            selected = candidate
            clearPending()
            self.flow = flow
        } else {
            let gap = max(0.0, timestamp - (lastCapture ?? timestamp))
            let expected = (lastTime ?? 0) + gap
            let aligned = candidates.filter { $0.offset == lastOffset }
            let tracking = aligned.isEmpty ? candidates : aligned
            selected = tracking.min(by: { trackingKey($0, expected) < trackingKey($1, expected) })
            if let sel = selected {
                let timeError = abs(sel.clientTime - expected)
                if timeError > 1.0 {
                    let plausible = reacquireCandidates(tracking)
                    if plausible.isEmpty { return nil }
                    selected = plausible.max { $0.clientTime < $1.clientTime }
                    clearPending()
                    self.flow = flow
                } else {
                    clearPending()
                }
            }
        }

        guard let sel = selected else { return nil }
        let clientTime = sel.clientTime
        let bitOffset = sel.offset
        let location = sel.location

        // 读取加速度和旋转
        guard let (accel, cursor1, _, _) = ue5Vector(payload, offset: bitOffset + 32, scale: 10) else { return nil }
        guard let (_, cursor2, _, _) = ue5Vector(payload, offset: cursor1, scale: 100) else { return nil }
        guard let (rotation, _) = ue5Rotator(payload, offset: cursor2) else { return nil }

        lastTime = clientTime
        lastOffset = bitOffset
        lastCapture = timestamp
        lastLocation = location
        // 加速度同包取出并留档（2026-09-22 接回）。
        // 说明：这个向量本来就挨在位置前面，findCandidates 已经解析过了，
        // 之前 decode 里用 `_` 丢掉。坐标系（世界系 / 车体系）尚未实测确认，
        // 所以只存不用，等游戏跑起来标定后再决定怎么喂给模型。
        lastAcceleration = accel
        lastAccelerationAt = timestamp
        return toPose(location, rotation)
    }

    /// 最新一帧的加速度（同包解析，scale ÷10）。
    ///
    /// ⚠️ 坐标系未确认：UE5 的移动块里这个字段既可能是世界系速度/加速度，
    /// 也可能是车体系。在没跑游戏实测前**不要**拿它当物理量用，
    /// 只做展示与后续标定。单位推测为 cm/s²（与位置 cm 同源）。
    private(set) var lastAcceleration: Vec3?
    private var lastAccelerationAt: Double?

    /// 对外读取加速度（带新鲜度门，过期返回 nil，避免拿旧值当实时值）
    func acceleration(maxAge: Double = 0.5) -> Vec3? {
        guard let a = lastAcceleration, let t = lastAccelerationAt else { return nil }
        return (Date().timeIntervalSince1970 - t) <= maxAge ? a : nil
    }

    // MARK: - 新协议解码（2026-09-25 逆向，游戏 1.4.x）

    /// 实测出的移动包固定前缀（前 56 字节）。
    /// 新协议把坐标装进 protobuf 封装的 s2c 小包，不再是裸 UE5 位流块，
    /// 旧 `findCandidates` 对这类包恒返回空 → 用本前缀做快速识别。
    private static let protoMovePrefix: [UInt8] = [
        0x48, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x0a, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x00,
        0x0a, 0x00, 0x00, 0x00, 0x62, 0x04, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x04, 0x00,
        0x08, 0x00, 0x10, 0x00, 0x0a, 0x00, 0x00, 0x00,
    ]

    /// 新协议位偏移（实测）：rec1 = (X1, Y1)，rec2 = (X2, Y2)，记录步长 64 位。
    /// **轴序经物理自洽性校正**：见 decodeProtoMove 注释（ΔX≫ΔY ⇒ X=498, Y=509）。
    private static let kProtoBitX1 = 498
    private static let kProtoBitY1 = 509
    private static let kProtoBitX2 = 562
    private static let kProtoBitY2 = 573
    /// 新协议包的合法 payload 长度（实测 72 / 76 字节）
    private static let kProtoLengths: Set<Int> = [72, 76]

    /// 新协议解码：从 protobuf 封装移动包里取出世界坐标。
    ///
    /// 实测依据（2026-09-25，真机连续采样 + 静止对照，样本存
    /// `tools/reverse/samples/`）：
    ///   · 角色移动时 X1/X2 每包同步变化，静止时字段完全不变；
    ///   · **轴序（物理自洽性判据）**：同一包内两条记录的差值是
    ///     ΔX = X2−X1 = −2145.77（≈21.5m，正常移动速度）、
    ///     ΔY = Y2−Y1 = +1.04（≈1cm，几乎静止）——说明角色沿 X 轴移动，
    ///     故 **(X, Y) = (bit498, bit509)**，rec2 是同轨迹的相邻采样
    ///     （两点相距 ≈22m，与 ΔX 换算一致）。地图验证：该点落于密集城区
    ///     十字路口，与游戏内小地图实拍吻合；错配轴序会落到黑暗弯道区。
    ///
    /// - Returns: `(x, y, z, prevX, prevY)`；非移动包或越界返回 nil。
    private func decodeProtoMove(_ payload: [UInt8]) -> (x: Double, y: Double, prev: (Double, Double))? {
        guard Self.kProtoLengths.contains(payload.count) else { return nil }
        let n = Self.protoMovePrefix.count
        guard payload.count > n, Array(payload[0..<n]) == Self.protoMovePrefix else { return nil }
        let x1 = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits(payload, offset: Self.kProtoBitX1, count: 32))))
        let y1 = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits(payload, offset: Self.kProtoBitY1, count: 32))))
        let x2 = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits(payload, offset: Self.kProtoBitX2, count: 32))))
        let y2 = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits(payload, offset: Self.kProtoBitY2, count: 32))))
        // 合理性门：世界坐标实测量级 1e4~1e5，非有限/超范围直接丢
        for v in [x1, y1, x2, y2] {
            guard v.isFinite, abs(v) < kMaxLocationAbs else { return nil }
        }
        // 至少 X 分量要有实际数值（全 0 说明不是数据包）
        guard abs(x1) > 1 || abs(x2) > 1 else { return nil }
        return (x1, y1, (x2, y2))
    }

    /// 扫描包中所有有效的移动块
    private func findCandidates(_ payload: [UInt8]) -> [Candidate]? {        var output: [Candidate] = []
        let searchEnd = min(512, payload.count * 8 - 60)
        guard searchEnd > 190 else { return output }
        for offset in 190..<searchEnd {
            // 读取时间戳（32位float）
            let timeBits = bits(payload, offset: offset, count: 32)
            let clientTime = Float(bitPattern: UInt32(timeBits))
            if !clientTime.isFinite || clientTime < 0 || clientTime >= 100_000 { continue }

            // 读取加速度
            guard let (accel, cursor, accelBits, accelScaled) = ue5Vector(payload, offset: offset + 32, scale: 10) else { continue }
            if !accelScaled { continue }
            if accelBits < 1 || accelBits > 16 { continue }
            if max(abs(accel.0), max(abs(accel.1), abs(accel.2))) >= 50_000 { continue }

            // 读取位置
            guard let (location, locEnd, locBits, locScaled) = ue5Vector(payload, offset: cursor, scale: 100) else { continue }
            if !locScaled { continue }
            if locBits < 20 || locBits > 32 { continue }
            if max(abs(location.0), max(abs(location.1), abs(location.2))) > kMaxLocationAbs { continue }

            // ★ 关键修复(20260913): ue5Vector 返回的 locEnd 已经是"位置向量结束后"的位偏移
            // （= offset + 7位header + 3*width 值位），即 rotation 的起始位。
            // 旧代码 locEnd + 7 多加 7 位 → rotation 解析错位 → hasValidRotation 永远失败 → 0 候选。
            // MaaNTE 原版语义: location_end = location_start + 7 + width*3 == ue5Vector 返回的 cursor。
            let rotationOffset = locEnd
            if !hasValidRotation(payload, offset: rotationOffset) { continue }

            output.append(Candidate(clientTime: Double(clientTime), offset: offset, acceleration: accel, location: location))
        }
        return output
    }

    private func trackingKey(_ item: Candidate, _ expected: Double) -> Double {
        let timeError = abs(item.clientTime - expected)
        if lastLocation == nil { return timeError }
        let dist = distanceSq(item.location, lastLocation!)
        let spatialPenalty = min(dist / (5000.0 * 5000.0), 100.0)
        return timeError + spatialPenalty
    }

    private func reacquireCandidates(_ candidates: [Candidate]) -> [Candidate] {
        return candidates.filter { $0.clientTime >= 0.01 && $0.offset <= 512
            && max(abs($0.acceleration.0), max(abs($0.acceleration.1), abs($0.acceleration.2))) <= 10_000
            && max(abs($0.location.0), max(abs($0.location.1), abs($0.location.2))) <= kMaxLocationAbs
        }
    }

    private func newFlowCandidate(_ candidates: [Candidate]) -> Candidate? {
        let valid = reacquireCandidates(candidates)
        return valid.max { $0.clientTime < $1.clientTime }
    }

    private func confirmFlow(_ flow: Flow, _ candidate: Candidate, _ timestamp: Double) -> Candidate? {
        if pendingFlow == nil || pendingFlow != nil && pendingFlow! != flow || pendingCandidate == nil {
            pendingFlow = flow
            pendingCandidate = candidate
            pendingSeen = 1
            pendingAt = timestamp
            return nil
        }
        guard let previous = pendingCandidate else { return nil }
        let gap = max(0.0, timestamp - (pendingAt ?? timestamp))
        let timeDelta = candidate.clientTime - previous.clientTime
        let timeOk = timeDelta >= 0.001 && abs(timeDelta - gap) <= 0.5
        let offsetOk = candidate.offset == previous.offset
        let stepOk = distanceSq(candidate.location, previous.location) <= 6_400_000_000.0
        pendingSeen = (timeOk && offsetOk && stepOk) ? pendingSeen + 1 : 1
        pendingCandidate = candidate
        pendingAt = timestamp
        return pendingSeen >= 2 ? candidate : nil
    }

    private func clearPending() {
        pendingFlow = nil
        pendingCandidate = nil
        pendingSeen = 0
        pendingAt = nil
    }
}

// MARK: - 坐标抓取器（从Python CoordinateCapture移植，用libpcap替代scapy）

/// 全局回调（避免Apple Silicon PAC签名问题，不用闭包）
nonisolated(unsafe) var coordinateCaptureActive: CoordinateCapture? = nil

/// pcap回调——C函数指针，不通过闭包，避免PAC崩溃
let coordinateCaptureCallback: pcap_callback = { _, headerPtr, packetPtr in
    guard let headerPtr = headerPtr, let packetPtr = packetPtr,
          let capture = coordinateCaptureActive else { return }
    let header = headerPtr.assumingMemoryBound(to: pcap_pkthdr.self).pointee
    let packet = packetPtr.assumingMemoryBound(to: UInt8.self)
    capture.processPacket(header: header, packet: packet)
}

/// 自包含网络坐标抓取：libpcap抓TCP 30031端口 → UE5包解析 → 世界坐标
///
/// ⚠️ 2026-09-30 修复：日志目标按「可写性」动态选择，不再死写 /tmp/aurora_pcap.log。
///
/// **故障实录**：`/tmp/aurora_pcap.log` 历史上曾由 **root 身份**的引擎写过
/// （LaunchDaemon 以 root 拉起时创建），文件落在 `root:wheel -rw-r--r--`。
/// 此后以普通用户（dupi）运行的 UI/引擎 **写不进这个 inode**：
///   · `FileHandle(forWritingTo:)` 抛错 → `try?` 吞掉
///   · 回退分支 `data.write(to:)` 同样抛错 → 也被 `try?` 吞掉
/// 结果：**定位子系统从 2026-09-29 13:23 起全部日志静默丢失**，
/// 「小地图定位偏差」因此完全无法诊断——不是定位坏了，是看不见它有没有工作。
///
/// 现改为：主路径不可写时自动落到用户可写的备用路径（Library/Logs，再退 /tmp 新名）。
/// 只新增文件，不改写、不删除既有的 root 日志。
private let pcapLogCandidates: [String] = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        "/tmp/aurora_pcap.log",                                 // 主路径（与既有习惯一致）
        "\(home)/Library/Logs/aurora_pcap.log",                 // 备用①：用户日志目录，必定可写
        "/tmp/aurora_pcap_ui.log",                              // 备用②：/tmp 下另起新名，规避旧 root inode
    ]
}()

/// 本进程选定并已验证可写的日志路径（首次调用时探测一次并缓存）。
private var pcapLogResolvedPath: String?

// ── 日志上限与轮转（2026-10-04 A4）────────────────────────────────────────
//
// 【为什么必须加】`pcapLog` 原来是**纯追加、无轮转、无上限**：
//   实测 2026-10-04 同日 `/tmp/aurora_pcap.log` 从 240 KB 涨到 632 KB。
//   而用户是 24/7 挂机场景 —— 按此速率长期运行会无限增长；
//   但它是定位子系统的**唯一排障入口**，既不能删、也不能因为怕涨就不写。
//
// 【策略】8 MB 上限 + **单备份**轮转（`<path>.1`，覆盖式）：
//   · 路径一字不改（`/tmp/aurora_pcap.log` 仍是排障入口，`tail -f` 习惯不变）；
//   · 峰值占用 = 8 MB（当前）+ 8 MB（备份）= **16 MB 封顶**，可预测；
//   · 单备份而非多份：排障看的是「最近发生了什么」，两份足够；
//     多份会让磁盘占用不可预测 —— 那正是本改动要消灭的问题本身。
//
// 【为什么节流】轮转检查要 `stat` 一次（约 2~5 µs）。pcapLog 在突发流量下
//   每秒可被调用上百次，逐次 stat 属白烧。故每 64 次写入才检查一次 ——
//   最坏情况文件超出上限 64 条日志（≈6 KB），相对 8 MB 上限可忽略。
private let pcapLogMaxBytes: UInt64 = 8 * 1024 * 1024
private let pcapLogCheckEvery: UInt64 = 64
private var pcapLogWriteCount: UInt64 = 0

/// 超过上限则把当前日志改名为 `<path>.1`（覆盖旧备份）并重建空文件。
/// 返回 true 表示发生了轮转。**只改名、不删日志、不改路径。**
private func pcapLogRotateIfNeeded(path: String) -> Bool {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = attrs[.size] as? UInt64,
          size >= pcapLogMaxBytes else { return false }
    let backup = path + ".1"
    try? fm.removeItem(atPath: backup)               // 单备份：旧 .1 直接覆盖
    try? fm.moveItem(atPath: path, toPath: backup)   // 当前 → .1
    fm.createFile(atPath: path, contents: nil)       // 重建空文件
    return true
}

func pcapLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = ts + " " + msg + "\n"
    guard let data = line.data(using: .utf8) else { return }

    // 轮转检查（节流：每 64 次写入 stat 一次）。**放在写之前**，
    // 这样本轮就落到新文件里，不留「已超限却还在写旧文件」的窗口。
    pcapLogWriteCount &+= 1
    if pcapLogWriteCount % pcapLogCheckEvery == 0, let path = pcapLogResolvedPath {
        _ = pcapLogRotateIfNeeded(path: path)
    }

    // 已有可用路径 → 直接追加（热路径，不重复探测）
    if let path = pcapLogResolvedPath {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            return
        }
        // 原路径失效（文件被删/权限变化）→ 重新探测
        pcapLogResolvedPath = nil
    }

    for path in pcapLogCandidates {
        let url = URL(fileURLWithPath: path)
        // 文件不存在则先创建（createFile 对已存在文件是幂等 no-op）
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { continue }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
        pcapLogResolvedPath = path
        return
    }
    // 全部候选都不可写：不静默，落到 stdout 至少留痕
    FileHandle.standardError.write(data)
}

final class CoordinateCapture {
    static var activeInstance: CoordinateCapture? = nil
    private let decoder = UE5Decoder()
    private var sample: Pose?
    private var sampleAt: Double = 0
    private var lastSampleWall: Double = 0
    private let interval: Double = 1.0 / 30.0
    private var running = false
    private let lock = NSLock()

    // MARK: - 自适应网卡（探测 → 锁定 → 失流重探）

    /// 当前锁定的监听网卡（nil = 正在探测/未锁定）。诊断与自检用。
    /// 存储由 lock 保护（supervisor 写 / UI 与自检读），对外只读。
    private var _activeInterface: String?
    var activeInterface: String? {
        lock.lock(); defer { lock.unlock() }
        return _activeInterface
    }
    /// 上一张成功收到过包的网卡：探测时置顶优先（自适应记忆——网络切换后回切更快）。
    /// 仅 supervisor 线程读写，无需加锁。
    private var lastGoodInterface: String?
    /// 监听/探测主线程（单线程统管，全程只有一个句柄在读取——统计字段沿用无锁假设）。
    private var supervisorThread: Thread?

    /// 探测窗口（秒）——**按优先级分级**（2026-09-25 实测修正）。
    ///
    /// ⚠️ 实测数据（游戏运行中，tcpdump 30 秒采样）：30031 是**突发式**流量——
    /// 一阵连发（1 秒内 5-6 包）后静默 6-9 秒，30 秒共 25 包（均值 ~0.8 包/秒）。
    /// 旧实现用固定 0.3 秒窗口探测，绝大部分时间落空（100 轮探测全失败的根因）。
    /// 故分级：
    ///   · 最高嫌疑（默认路由 / 上次命中的网卡）→ 给足 probeWindowPrimary（覆盖一个突发周期）
    ///   · 其余候选 → 快速筛掉（probeWindowOther，零流量网卡不值得久等）
    private static let probeWindowPrimary: Double = 2.5
    private static let probeWindowOther: Double = 0.5

    // ══════════════════════════════════════════════════════════════════════════
    // ⚠️ 2026-09-30 新增：按「已知坐标周期」加长探测窗口（修「有流量却锁不上」）
    // ══════════════════════════════════════════════════════════════════════════
    //
    // 【症状】现场实测（`~/Library/Logs/aurora_pcap.log`）：游戏**正在运行**、
    //   `lsof` 显示 `30031 ESTABLISHED`、`tcpdump -i en8 port 30031` 也能抓到
    //   76 字节坐标包，但抓包模块却在 10 张网卡之间空转，始终不锁定 en8：
    //
    //       选中网卡: en8 → en0 → llw0 → vmenet0 → ... → lo0
    //       第 5 轮探测：10 张网卡均无 30031 流量（游戏未启动/未进游戏）
    //
    // 【根因】探测窗口与「坐标包的实际周期」严重不匹配：
    //       probeWindowPrimary = 2.5 秒
    //       实测坐标周期        = 15.01 秒      ← 见 poseFreshWindow 的实测记录
    //   2.5 秒窗口落在 15 秒周期的**任一位置**，命中概率仅约 2.5/15.01 ≈ **17%**。
    //   更糟的是：en8 只被给 2.5 秒（primary），错过即被判「无流量」，
    //   下一轮要等整轮 10 张网卡走完（其余 9 张各 0.5~2.5 秒）才回来 ——
    //   而回来后依然只有 2.5 秒。**多次独立小概率事件连败是常态**，
    //   于是表现为「长时间空转、偶尔才锁定」。
    //
    // 【原注释为何过时】上方注释写「突发式：一阵连发 5-6 包后静默 6-9 秒」
    //   —— 那是 2026-09-25 用 30 秒采样得到的旧结论。2026-09-30 用四个独立
    //   样本（idle/move2/move_burst/turn）复测发现：坐标包**严格每 15.00 秒
    //   一个**（74/74 个包间隔完全一致）。故 2.5 秒这个值已不适用。
    //
    // 【修法】对「最高嫌疑网卡」（默认路由接口 / 上次命中的网卡）改用
    //   `probeWindowPrimaryForKnownCadence` = 16 秒 ≥ 实测周期 15.01 秒 + 余量。
    //   这样**单次探测即必中**（只要该网卡确实承载游戏流量）。
    //
    //   代价与权衡：高分网卡每轮多等约 13.5 秒。但「多等一轮」远优于
    //   「永远锁不上」—— 且仅在**探测阶段**（未锁定）付出，锁定后不涉及。
    //   低嫌疑网卡（其余 8 张，绝大多数是零流量的虚拟接口）仍用短窗口，
    //   不影响整体扫描速度：一轮总耗时 ≈ 16s + 9×0.5s ≈ 20.5s。
    // 【2026-09-30 三次修正：3.0 → 16.0 回调】当天曾把本值从 16s 降到 3s，
    // 理由是「定位源 UDP 30212 是 8Hz 持续流，3 秒必中」——**该理由建立在
    // 写死的端口上，而那个端口是错的**（见 openWithFilter 上方 2026-09-30
    // 第二次根因修复：游戏换服后 UDP 端口由 30212 变为 30160，写死的过滤
    // 器把移动包全挡了，该网卡上只剩 TCP 30031 心跳 —— 而 3 秒窗口对
    // 「15 秒一个的心跳」命中率仅 20%）。
    //
    //   结果实测（14:15-14:16 现场日志）：23 轮探测全部「均无 30031 流量」
    //   而游戏正在运行、en8 抓包每秒数 MB —— 双击穿：既抓不到移动包（端口
    //   写死），又因窗口过短错过心跳（探测空转）。
    //
    //   ⟹ 改回 16 秒：≥ 一个完整心跳周期，无论 UDP 移动包是否命中，
    //      只要该网卡上有 30031 心跳就必定锁定（单次探测必中）。
    //      修复过滤器后 UDP 移动包也会大量命中，16s 只会更快锁定。
    //   窗口层级：16s(探测) ≪ 22s(锁定后失流)，语义不同、互不冲突。
    private static let probeWindowPrimaryForKnownCadence: Double = 16.0
    /// 全轮无果后的重探间隔（秒）。用户指定 2 秒：比 5 秒灵敏，又不是高频扫描。
    ///
    /// ⚠️ 2026-09-30：这个值现在是**基准间隔**（退避的下限），不再是恒定间隔。
    ///    连续无果时会按 2 的幂放大到 `probeIdleBackoffCap`，
    ///    一旦某轮命中就立刻复位回本值。理由见 `supervisorLoop` 里
    ///    「空闲指数退避」那段注释。
    private static let probeRetryInterval: Double = 2.0
    /// 空闲退避的上限（秒）。30s 是权衡：游戏从启动到进世界至少几十秒，
    /// 30s 的最坏发现延迟可接受；再大就会让「刚进世界」的定位迟迟不亮。
    private static let probeIdleBackoffCap: Double = 30.0
    /// 失流判定窗口（秒）——锁定监听中超过这么久没有任何 30031 包 → 判失流 → 重新探测。
    ///
    /// ⚠️ 实测依据：突发间隔最长达 9 秒（30 秒采样），旧的 3 秒窗口会把正常
    /// 的静默期误判成停流 → 锁定后反复横跳。取 12 秒 = 最长静默 + 余量。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 复测修正：12.0 → 16.0（9 秒的采样漏掉了周期性长间隙）
    /// ══════════════════════════════════════════════════════════════════════
    /// **现场直击**（`~/Library/Logs/aurora_pcap.log`，修复 pcapLog 可写性后
    /// 才终于能看到这条链路，此前一直是黑盒）：
    ///
    ///     17:49:48  锁定监听 en8
    ///     17:50:01  ⟳ en8 停流（连续 12s 无 30031 包）→ 重新探测     ← 只隔 13 秒
    ///     17:50:03  重新锁定 en8
    ///
    /// 一次**完全正常**的 13 秒突发静默，被判定成「停流」→ 主动放弃已锁定的
    /// 网卡 → 重新走一遍探测（探测本身要遍历 9 张网卡，耗时可观）→ 这期间
    /// **抓包是停的**，坐标自然断流。
    ///
    /// 与 `poseFreshWindow` 同一现象：实机埋点测得**游戏固定每 15.01 秒**下发一个
    /// 坐标包（见 poseFreshWindow 注释里的 `[SAMPLE]` 记录）。取 22 秒 =
    /// 实测周期 15s + 7 秒余量，作为三层窗口里**最宽松**的一层（网卡最后才放弃）。
    /// 不取更大值是因为**本窗口的目的是检测「网卡真的没流量了」**（如游戏关停、
    /// 切网），而游戏真正退出时的间隔是 2300 秒量级 —— 22 秒与它差距两个数量级，
    /// 既不会误判停流，也不会漏掉真实的网卡失效。
    private static let streamLostWindow: Double = 22.0

    /// 「流量新鲜」判定窗口（秒）——UI/DriveState 判「游戏在不在通信」的统一尺子。
    ///
    /// **与 streamLostWindow 同源**（都是"容忍突发静默间隙"的语义）：
    /// 实测游戏同步突发间隔最长 9s，若用旧的 3s 窗口，UI 会在静默期间误报
    /// 「游戏未运行」把小地图打回空白（忽明忽暗）。12s 覆盖最长间隙 + 余量。
    /// 消费方：DriveState.locateSource / runNetworkLocateStep 前置门。
    ///
    /// ⚠️ 2026-09-30 终测：与 `poseFreshWindow` 同步调整（12 → 20）—— 两者必须
    /// **不窄于** `poseFreshWindow`，否则会出现「流量判定为新鲜、但坐标已过期」
    /// 的中间态：前置门放行 → `read()` 却返回 nil → 落到 else 分支报「无数据」，
    /// 而实际原因是过期。那个中间态正是定位诊断此前无法收敛的原因之一。
    /// 取 20 = `poseFreshWindow`(18) + 2s，保持层级：traffic > pose、streamLost > traffic。
    /// 完整实测依据见 `poseFreshWindow` 的注释（实机实测游戏坐标周期 = 15.01s）。
    static let trafficFreshWindow: Double = 20.0

    /// 坐标新鲜窗口（秒）——`read()` 默认值（消费方 DriveState 亦用此值）。
    /// 实测同步包间隔最长 9s，旧默认 1s 会让坐标频繁"过期"（地图不动）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 终测定案：12.0 → 18.0（**游戏的真实坐标周期就是 15 秒**）
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// 上面那条「最长 9s」来自 30 秒短采样，**严重偏低**。本轮在实机上直接
    /// 埋点测量了「坐标真正落地」的时刻（`[SAMPLE] 坐标落地 间隔=...`），
    /// 用 `AURORA_UI_LOCAL=1 --auto-drive` 本地模式连续观察，结果极其稳定：
    ///
    ///     间隔=15.02s   世界=(-76993.2, 31865.4)
    ///     间隔=15.00s   世界=(-76997.6, 31865.4)
    ///     间隔=15.01s   世界=(-77002.1, 31865.4)
    ///     间隔=15.01s   世界=(-77006.6, 31865.4)
    ///     间隔=15.01s   世界=(-77011.1, 31865.4)
    ///
    /// **游戏固定每 15.0 秒下发一个坐标包**（世界坐标每周期推进约 4.5 单位
    /// ≈ 4.5cm，与该场景下角色近乎静止一致）。
    ///
    /// 于是 15 秒窗口是**必然失败**的取值 —— 采样周期恰好等于窗口，`read()`
    /// 的条件 `now - lastSampleWall > maxAge` 会在每个周期末尾长时间为真：
    ///     上一个样本刚到时 age≈0；随着时间推移 age 单调增长到 15.0s；
    ///     而下一个样本要到 15.0s 之后才来 —— **临界窗口下，几乎每个周期
    ///     都有一段「已过期、新样本还没到」的空档**。
    /// 实机证据：`[LOCATE] ... 有样本=true 样本年龄=15.0s 窗口=15s
    ///           ← 有样本但已过期` —— 年龄与窗口分毫不差地撞在一起。
    ///
    /// 取 **18 秒** = 实测周期 15s + 3 秒余量：
    ///   · 覆盖周期抖动（15.00~15.02s 的观测抖动，以及网络/调度造成的偶发延迟）
    ///   · 留出的余量不会造成「幽灵定位」—— 游戏真正退出时靠
    ///     `hasRecentTraffic` 前置门拦截（游戏关闭间隔是 2300 秒量级），
    ///     且 18s 只比 15s 多 3 秒，对"位置陈旧"的观感影响可忽略
    ///     （角色 15 秒才动 4.5cm）
    static let poseFreshWindow: Double = 18.0

    // 15秒窗口统计（仅 supervisor 单线程读写，无并发）
    private var statWindowStart = Date().timeIntervalSince1970
    /// 最近一次收到任意包的时间（用于 hasRecentTraffic）
    ///
    /// ⚠️ 2026-09-30 修复（诊断语义 bug）：初值原为 `Date().timeIntervalSince1970`
    ///    （= 对象构造的那一刻）。这使 `hasRecentTraffic` 在**抓包启动后的头
    ///    20 秒（= trafficFreshWindow）内恒返回 true**，哪怕一个包都没收到 ——
    ///    因为「现在 − 构造时刻」当然小于窗口。
    ///
    ///    直接后果（实机日志里反复出现的自相矛盾行）：
    ///        [LOCATE] 定位中断 —— 累计包=0 有流量=true 有样本=false …
    ///    `累计包=0` 与 `有流量=true` 同时成立，把排查方向误导到
    ///    「网卡选错 / 权限不足」，而真相是**根本还没收到任何包**。
    ///    这条日志是本项目定位问题的主要线索，它的两个字段互相打架会
    ///    严重拖慢诊断（本项目已在定位问题上消耗了多轮）。
    ///
    ///    修法：初值改为 **0**（= 纪元时刻，一个明确的「从未收到过包」哨兵）。
    ///    于是 `hasRecentTraffic` 在收到第一个包之前恒为 false —— 与
    ///    `totalPackets == 0` 语义一致，两个字段不再打架。
    ///
    ///    影响面：`hasRecentTraffic` 的读取方只有两处，都是「判断链路是否活着」：
    ///      · `runNetworkLocateStep` 的前置门（无流量 → 如实置为 game_not_running）
    ///      · `[LOCATE]` 诊断日志
    ///    两处都**期望**「没收到包 = 没流量」，原初值让这个期望在启动后 20 秒
    ///    内失效（表现为「游戏没开也报有流量」）。修后语义正确。
    ///    唯一的可观察变化：**程序启动后的头 20 秒**，若确实无包，现在会如实
    ///    报 `有流量=false`，而不再是误报 true。这正是我们要的。
    private var lastPacketWall: Double = 0

    /// 已被确认为「游戏移动包通道」的 UDP 端口集合（解出真样本时学习，2026-09-30）。
    /// 用途：裸 UDP 过滤器下区分游戏流量与系统 UDP（见 markGameTraffic 长注释）。
    /// 上限 8 个：换服/换区历史上不会积累更多，超限说明判据失效。
    private var gamePorts: Set<Int> = []
    /// 自启动以来的包总数（跨统计窗口不清零）
    private var statPacketsTotal = 0
    private var statPackets = 0

    // ── 链路层类型（2026-09-30 新增，用于系统代理场景）──
    //
    // 记录**当前锁定网卡**的 pcap DLT 类型。`processPacket` 据此决定链路层
    // 头长度：以太网 14 字节、回环 4 字节。
    //
    // 为什么存成成员而非每次查询：`processPacket` 被 pcap 回调高频调用；
    // 且 handle 在「锁定/失流重探」时会更换，故在 openWithFilter 成功后
    // 立即写入，与 handle 生命周期同步。
    //
    // 默认值 `Self.dltEN10MB`（=1，以太网）：**保证既有物理网卡路径行为
    // 与改动前逐字一致** —— 即便该字段因任何原因没被写入，也回退到原行为。
    private var currentDataLinkType: Int32 = CoordinateCapture.dltEN10MB

    /// pcap 链路层类型常量（取自 pcap/dlt.h）。
    static let dltNULL: Int32 = 0        // BSD 回环（lo0 用这个）
    static let dltEN10MB: Int32 = 1      // 以太网
    static let dltLOOP: Int32 = 108      // OpenBSD 回环

    /// 按 pcap DLT 类型返回链路层头字节数。
    ///
    /// - 以太网（DLT_EN10MB=1）→ 14
    /// - 回环（DLT_NULL=0 / DLT_LOOP=108）→ **4**
    ///   （回环头是 4 字节地址族：AF_INET 为 2，本机抓包为小端 `02 00 00 00`）
    /// - 其余未知类型 → 回退 14，与改动前行为一致（不引入新行为）
    static func linkLayerHeaderLength(forDLT dlt: Int32) -> Int {
        switch dlt {
        case dltNULL, dltLOOP: return 4
        default: return 14
        }
    }
    private var statS2C = 0
    private var statC2S = 0
    private var statDecodeCalls = 0
    private var statCandHits = 0
    private var statCandPeak = 0
    private var statSamples = 0
    /// 探测轮数 / 锁定次数（诊断：自适应行为是否在工作）
    private(set) var probeRounds = 0
    private(set) var lockCount = 0
    /// 连续「全轮无 30031 流量」的轮数 —— 空闲指数退避的计数器（2026-09-30）。
    ///
    /// 语义：0 = 上一轮命中了（或从未探测过）；N>0 = 已连续 N 轮什么都没探到。
    /// 每轮失败 +1、命中即清零。退避间隔 = probeRetryInterval × 2^(N-1)，封顶 30s。
    /// 只在 `supervisorLoop`（单一专属线程）里读写，无需加锁 —— 与
    /// `probeRounds` / `lockCount` 同一约定。
    private var probeFailStreak = 0

    /// 解码器新协议采样累计（诊断：新协议解码是否在工作）
    var decoderProtoSamples: Int { decoder.protoSamples }

    // MARK: - 网卡选择（游戏流量在哪个接口上）

    /// 非物理网卡前缀——这些接口不承载游戏流量，默认跳过。
    ///
    /// ⚠️ 为什么加 `ap`（2026-09-25 实测事故）：`ap1` 是 macOS 的
    /// Wi-Fi 热点（Internet Sharing）接口，`status: inactive`、
    /// 累积流量恒 0（实测 Ipkts=0）。它能被 pcap 正常打开，且在
    /// pcap_findalldevs 的枚举里排在很前面 —— 旧逻辑「第一个能打开的
    /// 就用」于是选中它抓空气，表现为「抓包已启动但永远没有 30031 包
    /// → 小地图永远无定位」。热点接口在旧前缀表（lo/pdp/utun/awdl/
    /// bridge/xhc）之外，是这次事故的漏网之鱼。
    ///
    /// ⚠️ 2026-09-30 变更：**`lo` 已从本表移除**，改由下方 `loopbackNames`
    /// 单独处理（不跳过，但排在所有物理网卡之后）。原因见 `loopbackNames` 注释。
    private static let skipPrefixes = ["pdp", "utun", "awdl", "bridge", "xhc",
                                       "ap", "anpi", "gif", "stf"]

    /// 回环接口前缀 —— 不跳过，但**排在所有物理网卡之后**探测（2026-09-30 新增）。
    ///
    /// 【为什么需要】用户开启**系统代理**（Clash/Surge 等）后，游戏流量路径变为：
    ///
    ///     游戏 ──[明文私有协议]──→ 127.0.0.1:12450 ──[TLS 密文]──→ 外网服务器
    ///            ↑ 只有这一段可解                      ↑ 抓了也解不开
    ///
    /// 物理网卡上看到的是代理转发出去的 **TLS 记录**（首字节 `16`/`17` + `03 03`），
    /// 位级/字节级扫描都解不出坐标。此时回环是**唯一的明文链路** ——
    /// 旧实现在 `skipPrefixes` 里含 `"lo"`，等于把它整个放弃。
    ///
    /// 【为什么排在最后而不是直接并进主列表】回环上有大量无关流量（DNS、
    /// 本地 IPC、其它 App），而 BPF 过滤器只放行 30031 —— 回环上通常没有
    /// 30031。若把 `lo` 排前面，会白白占用探测时间且可能误锁。
    /// 故策略为：**物理网卡全部探不到 30031 时，才去回环上找**。
    /// 物理网卡正常（绝大多数情况）时，行为与改动前**完全一致**。
    private static let loopbackNames = ["lo"]

    /// 系统默认路由（接口名 + 网关 IP）。
    ///
    /// ⚠️ 路径实测（2026-09-25）：`route` 在本机位于 **`/sbin/route`**，
    /// 而 `/usr/sbin/route` 不存在——旧实现硬编码后者的结果是**整个优选
    /// 逻辑静默失效**（Process 启动失败 → 返回 nil → 退回枚举顺序）。
    /// 故改为多候选路径 + netstat 兜底，并打日志说明实际用的哪条路径。
    ///
    /// 只做「排序提示」用途：候选正确性由逐张实测 30031 流量保证，
    /// 本函数失败不影响自适应（仅影响探测顺序）。
    static func parseDefaultRoute() -> (interface: String, gateway: String)? {
        let candidates: [(path: String, args: [String], key: String)] = [
            ("/sbin/route", ["-n", "get", "default"], "interface:"),
            ("/usr/sbin/route", ["-n", "get", "default"], "interface:"),
            ("/usr/bin/route", ["-n", "get", "default"], "interface:"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            guard let out = runCapture(c.path, c.args) else { continue }
            if let iface = parseField(out, key: "interface:"), !iface.isEmpty {
                let gw = parseField(out, key: "gateway:") ?? ""
                return (iface, gw)
            }
        }
        // 兜底：netstat -rn 的 IPv4 default 行（最后一段是接口名）。
        // 注意排除 IPv6 default（gateway 含 ":"，如 fe80::%utun0）。
        for path in ["/usr/sbin/netstat", "/usr/bin/netstat", "/sbin/netstat"]
        where FileManager.default.isExecutableFile(atPath: path) {
            guard let out = runCapture(path, ["-rn"]) else { continue }
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("default") else { continue }
                let parts = t.split(separator: " ").map(String.init)
                guard let gw = parts.dropFirst().first, !gw.contains(":") else { continue }
                guard let iface = parts.last, !iface.contains(":") else { continue }
                return (iface, gw)
            }
        }
        return nil
    }

    private static func runCapture(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func parseField(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key) {
                return t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 默认路由接口（带 5 秒缓存：探测轮会反复调用，避免每轮都起子进程）。
    private var cachedDefaultRoute: (interface: String, gateway: String)??
    private var cachedDefaultRouteAt: Double = 0
    private func defaultRouteInterface() -> String? {
        let now = Date().timeIntervalSince1970
        if let cached = cachedDefaultRoute, now - cachedDefaultRouteAt < 5.0 {
            return cached?.interface
        }
        let parsed = Self.parseDefaultRoute()
        cachedDefaultRoute = parsed
        cachedDefaultRouteAt = now
        if let parsed {
            pcapLog("[CoordinateCapture] 默认路由: \(parsed.interface) → 网关 \(parsed.gateway)")
        } else {
            pcapLog("[CoordinateCapture] ⚠️ 默认路由解析失败（route/netstat 均不可用），按枚举顺序探测")
        }
        return parsed?.interface
    }

    /// 打开指定网卡并挂上 30031 过滤器。成功返回 handle（调用方接管），失败返回 nil。
    private func openWithFilter(_ name: String, errbuf: inout [CChar]) -> OpaquePointer? {
        let handle = name.withCString { namePtr in
            pcap_open_live(namePtr, 65535, 0, 100, &errbuf)
        }
        guard let handle else {
            pcapLog("[CoordinateCapture] \(name)打开失败: \(String(cString: errbuf))")
            return nil
        }

        // ── 记录本网卡的链路层类型（2026-09-30 新增）──
        // 必须在这里、且在 handle 被接管前写入：`processPacket` 之后用
        // 它决定链路层头长（以太网 14 / 回环 4）。
        // 旧实现硬编码 14 —— 对回环（系统代理场景，游戏流量经
        // 127.0.0.1:<代理端口> 转发）会切错 IP 头位置，一个坐标都解不出。
        let dlt = pcap_datalink(handle)
        currentDataLinkType = dlt
        if name.hasPrefix("lo") {
            pcapLog("[CoordinateCapture] \(name) 链路层DLT=\(dlt)"
                    + "（回环应为 0，头长 \(Self.linkLayerHeaderLength(forDLT: dlt)) 字节）")
        }

        // 设置过滤器：**只抓游戏 30031 端口**（TCP + UDP 两种承载）。
        //
        // 历史坑：原过滤器是 "tcp port 30031 or udp"，后半句是裸的 ——
        // 它会把机器上**所有 UDP 流量**（DNS、mDNS、系统广播、其它 App）
        // 全部抓进来。解码器又不校验来源，于是任意 ≥32 字节的杂包都会被
        // 硬解成一组坐标，表现就是「游戏都没启动，定位疯狂乱跳」。
        // 现在锁死端口：非 30031 的包在内核 BPF 层就被丢弃，进不来。
        var filterProgram = bpf_program(bf_len: 0, bf_insns: nil)
        // ── 抓包过滤器（2026-09-30 修正：加入 C2S 移动包通道 UDP 30212）──
        //
        // 【根因】玩家实时位置在 **C2S UDP 30212 移动包**（实测 ~8Hz，
        //   客户端持续上报移动 RPC；站立也发，位置恒定）。旧过滤器
        //   `(tcp|udp) port 30031` 把它全部挡在门外 —— 30031 上只有
        //   TCP 心跳（15s 一个，内含微秒时钟）与元数据推送（物品/生成记录），
        //   全都不含玩家实时位置。MaaNTE 上游过滤器为
        //   `tcp port 30031 or udp`（裸 UDP，靠解码器自身的候选验证+连续性
        //   锁定拒绝杂包）。
        //
        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-09-30 第二次根因修复：不再写死 UDP 端口
        // ══════════════════════════════════════════════════════════════════
        //
        // 【错误】上一版写成 `(tcp port 30031) or (udp port 30212)`，把
        //   30212 当成了固定的移动包端口 —— 那只是「上一轮抓包那台服务器」
        //   的端口（58.87.94.42:30212）。**游戏换服后端口变了**：
        //   实测本次（2026-09-30 14:14-14:23）服务器为
        //   **49.232.46.87:30160**，30212 上 0 个包、58.87.94.42 上 0 个包。
        //   ⟹ 移动包被 BPF 挡在内核层 → 定位数据收集不到、探测 23 轮全空。
        //
        // 【修法】改用 MaaNTE 上游同款 `tcp port 30031 or udp`（裸 UDP）：
        //   端口会随服务器变化，**永不写死**；甄别交给解码器 —— findCandidates
        //   的候选验证（时间戳区间/UE 向量头/旋转合法性）+ 时间空间连续性锁定
        //   会拒掉全部杂包（实测：本次抓包 UDP 30160 C2S 6288 包 → 解出
        //   2444 个有效姿态，S2C 8647 包 → 0 姿态，正是甄别生效的证明）。
        //   代价：en8 上的 QUIC/DNS 等 UDP 也会进 processPacket，但它们连
        //   第一道候选验证都过不了，CPU 可忽略。
        let filterExpr = "(tcp port 30031) or udp"
        let compileResult: Int32 = filterExpr.withCString { cStr in
            pcap_compile(handle, &filterProgram, cStr, 0, 0)
        }
        guard compileResult >= 0 else {
            pcapLog("[CoordinateCapture] \(name) pcap_compile失败")
            pcap_close(handle)
            return nil
        }
        guard pcap_setfilter(handle, &filterProgram) >= 0 else {
            pcapLog("[CoordinateCapture] \(name) pcap_setfilter失败")
            pcap_close(handle)
            return nil
        }
        pcapLog("[CoordinateCapture] ✓ 选中网卡: \(name) (过滤器: \(filterExpr))")
        return handle
    }

    // MARK: - 自适应网卡（探测 → 锁定监听 → 失流重探）

    /// 候选网卡列表（按尝试优先级）：
    ///   ① `lastGoodInterface` 置顶 —— 上次真收到过包的网卡（网络切换后回切最快）；
    ///   ② 默认路由接口（游戏流量必然经过它）；
    ///   ③ 其余物理网卡（pcap 枚举顺序，跳过非物理/热点/隧道前缀）。
    ///
    /// ⚠️ 为什么不再「第一个能打开的就用」（2026-09-25 实测事故）：ap1（Wi-Fi
    /// 热点接口）status inactive、累积流量恒 0（Ipkts=0），却能被 pcap 正常
    /// 打开且枚举排最前——选中它 = 抓空气（小地图永远无定位）。而「能打开」
    /// 与「承载游戏流量」完全是两件事，所以本实现改为**探测真实 30031 包**
    /// 才认定，① ② 置顶项即使命中前缀表（VPN 场景的 utun）也保留。
    private func candidateInterfaces() -> [String] {
        var errbuf = [CChar](repeating: 0, count: 256)
        var alldevsPtr: UnsafeMutablePointer<pcap_if_t>? = nil
        guard pcap_findalldevs(&alldevsPtr, &errbuf) >= 0, let head = alldevsPtr else {
            pcapLog("[CoordinateCapture] pcap_findalldevs失败: \(String(cString: errbuf))")
            return []
        }
        var allNames: [String] = []
        var current: UnsafeMutablePointer<pcap_if_t>? = head
        while let dev = current {
            if let namePtr = dev.pointee.name {
                allNames.append(String(cString: namePtr))
            }
            current = dev.pointee.next
        }
        pcap_freealldevs(head)

        let preferred = defaultRouteInterface()
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ n: String) {
            guard allNames.contains(n), !seen.contains(n) else { return }
            seen.insert(n)
            ordered.append(n)
        }
        if let lg = lastGoodInterface { add(lg) }
        if let preferred { add(preferred) }
        for name in allNames where !Self.skipPrefixes.contains(where: { name.hasPrefix($0) })
            && !Self.loopbackNames.contains(where: { name.hasPrefix($0) }) {
            add(name)
        }
        // ⚠️ 2026-09-30 新增：回环排在**所有物理网卡之后**。
        //
        // 仅在物理网卡全部探不到 30031 时才会走到这里 —— 即**系统代理**
        // 把游戏流量转到 `127.0.0.1` 的场景。物理网卡正常时，前面的
        // 探测已命中并 return，本段不会被触及，行为与改动前完全一致。
        //
        // 配套改动：`processPacket` 现按 `pcap_datalink` 决定链路层头长
        // （回环 4 字节 / 以太网 14 字节），否则即便探到也解不出包。
        for name in allNames where Self.loopbackNames.contains(where: { name.hasPrefix($0) }) {
            add(name)
        }
        return ordered
    }

    /// 探测单张网卡：在 `window` 秒内是否真收到 30031 包。
    /// - Parameter window: 探测时长（高嫌疑网卡给足时间覆盖突发周期；其余快速筛掉）
    /// - Returns: `(handle, gotPacket)`；handle 由调用方接管（命中则续用监听、未命中由调用方关闭）。
    ///
    /// 探测即「试读」：pcap_open_live + 30031 过滤器后轮询读取，收到任意
    /// 30031 包（过滤器已保证只可能是 30031）即判定该网卡承载游戏流量。
    /// 收到的包会照常走 processPacket（不浪费、也不丢这一包）。
    private func probe(interface name: String, window: Double, errbuf: inout [CChar]) -> (handle: OpaquePointer, gotPacket: Bool)? {
        // ⚠️ 2026-09-30 根因修复：判据从「收到任意包」改为「**游戏流量**到达」。
        //
        // 【曾经的写法】`got = true` —— 只要窗口内收到一个被过滤器放行的包就算命中。
        //   在旧过滤器（精确端口 30031）下等价于「收到游戏包」，但过滤器已改为
        //   **裸 UDP**（游戏换服后 UDP 端口会变，写死端口会丢移动包 —— 见
        //   openWithFilter 长注释），于是 en8 上的**系统 UDP**（QUIC/443、DNS、
        //   mDNS）让第一张网卡立刻「命中」：实测无游戏运行时阶段 A 直接
        //   锁定 en8（包总数 83），而 en8 上此刻**没有任何 30031/30160 包**。
        //   后果是双重的：① 探测失去筛选网卡的能力；② HUD 误报「已有流量」。
        //
        // 【现判据】与失流判定同一把尺子 —— 看 `lastPacketWall`（只由
        //   markGameTraffic 刷新，即「端口 30031」或「已解出真样本的端口」）。
        //   记录进入本网卡探测前的基准值，窗口内若被刷新即命中。
        //   语义：**这张网卡上真的出现了游戏流量**，而不是「有别的 UDP」。
        guard let handle = openWithFilter(name, errbuf: &errbuf) else { return nil }
        lock.lock()
        let baseline = lastPacketWall
        lock.unlock()
        var got = false
        let deadline = Date().addingTimeInterval(window)
        while running, Date() < deadline {
            var headerPtr: UnsafeMutablePointer<pcap_pkthdr>? = nil
            var packetPtr: UnsafePointer<UInt8>? = nil
            let result = pcap_next_ex(handle, &headerPtr, &packetPtr)
            if result == 1, let h = headerPtr, let p = packetPtr {
                processPacket(header: h.pointee, packet: p)
                lock.lock()
                let now = lastPacketWall
                lock.unlock()
                if now > baseline {       // 窗口内出现了**游戏**流量
                    got = true
                    break
                }
                continue                  // 系统 UDP：继续读，不误判
            }
            if result < 0 { break }
            // result == 0：pcap 超时（to_ms=100）无包。2ms 让出后继续，
            // 保证「刚开测就有包」的灵敏性（包一到立即返回，不等满窗口）。
            usleep(2_000)
        }
        return (handle, got)
    }

    /// 锁定监听：只读命中网卡，收到包即处理；连续 streamLostWindow 秒无包 → 返回（交给主循环重探）。
    private func listenLocked(handle: OpaquePointer, name: String) {
        pcapLog("[CoordinateCapture] 锁定监听 \(name)（过滤器: TCP/UDP 30031）")
        while running {
            var headerPtr: UnsafeMutablePointer<pcap_pkthdr>? = nil
            var packetPtr: UnsafePointer<UInt8>? = nil
            let result = pcap_next_ex(handle, &headerPtr, &packetPtr)
            if result == 1, let h = headerPtr, let p = packetPtr {
                processPacket(header: h.pointee, packet: p)
                continue
            }
            if result < 0 { break }   // 句柄失效（网卡消失等）→ 回主循环重探
            // result == 0：超时无包（pcap 已阻塞 to_ms=100）。失流判定与
            // hasRecentTraffic 同一把尺子（读 lastPacketWall）。
            lock.lock()
            let last = lastPacketWall
            lock.unlock()
            if Date().timeIntervalSince1970 - last >= Self.streamLostWindow { return }
        }
    }

    /// 可中断等待（每 50ms 查一次 running，close() 后能迅速退出，不睡死）。
    private func sleepInterruptible(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while running, Date() < deadline { usleep(50_000) }
    }

    private func setActiveInterface(_ name: String?) {
        lock.lock()
        _activeInterface = name
        lock.unlock()
    }

    /// 自适应主循环（单线程统管）：
    ///   探测（逐张试读，命中即锁定）→ 锁定监听 → 失流则回到探测。
    ///
    /// 全程只有一个 pcap 句柄在读取 —— 统计字段与 decoder 沿用「单线程」假设，
    /// 无并发访问（这也是不做多通道并行的原因：用户要的探测式更省、且无竞态）。
    private func supervisorLoop() {
        pcapLog("[pcap] 自适应网卡主循环启动（探测 高嫌疑\(Int(Self.probeWindowPrimaryForKnownCadence * 1000))ms/其余\(Int(Self.probeWindowOther * 1000))ms / 重探间隔 \(Int(Self.probeRetryInterval))s / 失流窗口 \(Int(Self.streamLostWindow))s）")
        var errbuf = [CChar](repeating: 0, count: 256)
        while running {
            // ── 阶段 1：探测 ──
            let preferred = defaultRouteInterface()
            let candidates = candidateInterfaces()
            probeRounds += 1
            if candidates.isEmpty {
                pcapLog("[CoordinateCapture] ⚠️ 无候选网卡，\(Int(Self.probeRetryInterval))s 后重试")
                sleepInterruptible(Self.probeRetryInterval)
                continue
            }
            var locked: (handle: OpaquePointer, name: String)? = nil
            for name in candidates {
                guard running else { break }
                // 分级窗口：默认路由 / 上次命中 的网卡给足时间覆盖**实测坐标周期**；
                // 其余候选快速筛掉（零流量网卡不值得久等）。
                //
                // ⚠️ 2026-09-30 修正：高嫌疑网卡由 probeWindowPrimary(2.5s) 改为
                //   probeWindowPrimaryForKnownCadence(16s)。原因见该常量的长注释：
                //   实测坐标包严格每 15.01 秒一个，2.5 秒窗口命中率仅约 17%，
                //   导致「游戏明明在跑、en8 明明有流量，却反复探不到、锁不上」。
                //   16 秒 ≥ 一个完整周期，单次探测即必中。
                let w = (name == preferred || name == lastGoodInterface)
                    ? Self.probeWindowPrimaryForKnownCadence : Self.probeWindowOther
                guard let (handle, got) = probe(interface: name, window: w, errbuf: &errbuf) else { continue }
                if got {
                    locked = (handle, name)
                    pcapLog("[CoordinateCapture] ✓ 探测命中：\(name) 有真实 30031 流量 → 锁定监听")
                    break
                }
                pcap_close(handle)   // 这张没流量：关掉，试下一张
            }
            guard let locked else {
                pcapLog("[CoordinateCapture] 第 \(probeRounds) 轮探测：\(candidates.count) 张网卡均无 30031 流量（游戏未启动/未进游戏），\(Int(Self.probeRetryInterval))s 后重探")
                // ⚠️ 2026-09-30 性能修复：空闲指数退避。
                //
                // 【问题】原实现每轮探测结束都固定 `sleepInterruptible(probeRetryInterval)`
                //   （2 秒）后就重来。但**一轮探测本身就要 2.5s（首选网卡）+
                //   0.5s × 其余网卡** —— 本机有多张网卡（en0/lo0/gif0/stf0/utun* 等），
                //   实测单轮数秒。于是「游戏没开」时这个线程几乎**从不休息**：
                //   探完一轮 → 睡 2 秒 → 再探一轮 → …… 每张网卡每轮都要
                //   `pcap_open_live` + 挂过滤器 + 轮询读取 + `pcap_close`。
                //   这是空闲态 CPU 居高的来源之一（实测空闲 17.9% 单核，
                //   而同时刻游戏停在登录页、Aurora 无帧无推理）。
                //
                // 【修法】连续探测失败时把间隔按 2 的幂放大（2s → 4s → 8s → … →
                //   封顶 30s），一旦某轮命中就立刻复位回 2s。
                //
                // 【为什么这不影响功能】探测的目的只是「发现游戏开始发 30031 包」。
                //   用户从启动游戏到进入世界**至少几十秒**（登录 + 加载 + 进场），
                //   30s 的最坏发现延迟相对这个量级完全可接受；而一旦进了世界，
                //   第一次命中就把间隔复位成 2s，之后行为与原实现**逐字一致**。
                //   换言之：只在「明显没戏」的时候才变慢，一有戏立刻恢复灵敏。
                probeFailStreak += 1
                let backoff = min(Self.probeRetryInterval * pow(2.0, Double(probeFailStreak - 1)),
                                  Self.probeIdleBackoffCap)
                if probeFailStreak <= 3 || probeFailStreak % 5 == 0 {
                    // 退避本身也要可观测：否则将来会有人以为「抓包线程死了」。
                    pcapLog("[CoordinateCapture] 空闲退避：连续 \(probeFailStreak) 轮无流量 → 下次探测间隔 \(String(format: "%.0f", backoff))s")
                }
                sleepInterruptible(backoff)
                continue
            }
            // 命中：立刻复位退避，恢复 2s 的灵敏探测
            probeFailStreak = 0

            // ── 阶段 2：锁定监听 ──
            lastGoodInterface = locked.name
            setActiveInterface(locked.name)
            lockCount += 1
            listenLocked(handle: locked.handle, name: locked.name)

            // ── 阶段 3：失流 / 句柄失效 → 回探测 ──
            if running {
                pcapLog("[CoordinateCapture] ⟳ \(locked.name) 停流（连续 \(Int(Self.streamLostWindow))s 无 30031 包）→ 重新探测")
                setActiveInterface(nil)
            }
            pcap_close(locked.handle)
        }
        setActiveInterface(nil)
        pcapLog("[pcap] 自适应网卡主循环退出")
    }

    /// 启动抓包 — 启动自适应主循环（探测 → 锁定 → 失流重探，全程零人工干预）
    func start() -> Bool {
        guard !running else { return true }
        running = true
        supervisorThread = Thread { [weak self] in
            self?.supervisorLoop()
        }
        supervisorThread?.name = "com.aurora.coordinate-capture"
        supervisorThread?.start()
        pcapLog("[CoordinateCapture] 自适应抓包已启动 (过滤器: TCP/UDP 30031)")
        return true
    }

    /// 处理抓到的包（单线程：supervisor 主循环串行调用，统计字段无需加锁）
    func processPacket(header: pcap_pkthdr, packet: UnsafePointer<UInt8>) {
        statPackets += 1
        // ⚠️ 2026-09-30 修正：`lastPacketWall` 不在这里刷新。
        //
        // 【原写法】入口处无条件刷新 —— 语义是「过滤器放行的任意包 = 游戏在跑」。
        //   在旧过滤器（精确端口 30031/30212）下成立，因为放行的包都来自游戏。
        //   但过滤器已改为 **裸 UDP**（`tcp port 30031 or udp` —— 因为游戏换服
        //   后 UDP 端口会变，写死端口会丢掉移动包，见 openWithFilter 长注释），
        //   此时 en8 上还有大量**系统 UDP**（QUIC/443、DNS、mDNS）——
        //   若仍在入口刷新，则「游戏退出」永远不会被判出（测试实测：注入停止
        //   22 秒后仍报有流量），hasRecentTraffic 彻底失效。
        //
        // 【现写法】只有**游戏相关包**才刷新（见本函数末尾的 markGameTraffic）：
        //   ① TCP 30031（游戏心跳/元数据，走 TCP）
        //   ② UDP 里 findCandidates 解出候选的包（真正的移动包）
        //   其余杂包仅计入 statPacketsTotal，不影响「游戏在跑」判定。
        lock.lock()
        statPacketsTotal += 1
        lock.unlock()
        defer { logStats() }
        let timestamp = Double(header.ts.tv_sec) + Double(header.ts.tv_usec) / 1_000_000.0
        let caplen = Int(header.caplen)
        let data = Array(UnsafeBufferPointer(start: packet, count: caplen))
        // ══════════════════════════════════════════════════════════════════
        // ⚠️ 2026-09-30 修复：链路层头长度不再硬编码 14。
        // ══════════════════════════════════════════════════════════════════
        //
        // 【原写法】`guard data.count > 14 else { return }` + `var offset = 14`
        //   —— 把链路层当作以太网头（14 字节）。
        //
        // 【为什么是 bug】链路层类型随网卡而变：
        //     · 物理网卡（en0/en8）：DLT_EN10MB，头 14 字节   ← 原写法正确
        //     · 回环 lo0：DLT_NULL，头 **4 字节**            ← 原写法错位
        //   回环上按 14 跳会切进 IP 头中间，`ipVersion` 读到非 4 → 直接 return，
        //   表现为「包数在涨但零坐标」，静默失效、极难察觉。
        //
        // 【触发场景】用户开启**系统代理**后，游戏高频流量经
        //   `127.0.0.1:<代理端口>` 回环转发；回环上才是明文，物理网卡上
        //   只有代理发出的 TLS 密文。故必须正确解析回环包，否则抓包失效。
        //
        // 【修法】按 `pcap_datalink(handle)` 的实际类型决定头长：
        //     DLT_EN10MB(1) → 14；DLT_NULL(0)/DLT_LOOP(108) → 4；
        //     其余未知类型 → 回退 14（与改动前一致，不引入新行为）。
        //   物理网卡路径行为**逐字不变**。
        let linkOffset = Self.linkLayerHeaderLength(forDLT: currentDataLinkType)
        guard data.count > linkOffset else { return }
        var offset = linkOffset
        guard offset < data.count else { return }
        let ipVersion = (data[offset] >> 4) & 0x0F
        if ipVersion != 4 { return }
        let ipHeaderLen = Int(data[offset] & 0x0F) * 4
        guard offset + ipHeaderLen <= data.count else { return }
        let protocolNum = data[offset + 9]
        let srcIP = "\(data[offset+12]).\(data[offset+13]).\(data[offset+14]).\(data[offset+15])"
        let dstIP = "\(data[offset+16]).\(data[offset+17]).\(data[offset+18]).\(data[offset+19])"
        offset += ipHeaderLen
        // TCP(6) 可变头；UDP(17) 固定8字节头——对齐MaaNTE原版，UE5移动同步可能走UDP
        let transportStart: Int
        if protocolNum == 6 {
            guard offset + 20 <= data.count else { return }
            transportStart = offset
            offset += Int(data[offset+12] >> 4) * 4
        } else if protocolNum == 17 {
            guard offset + 8 <= data.count else { return }
            transportStart = offset
            offset += 8
        } else {
            return
        }
        guard offset < data.count else { return }
        let payload = Array(data[offset...])
        let direction = packetDirection(src: srcIP, dst: dstIP)
        if direction == "s2c" { statS2C += 1 }
        guard transportStart + 4 <= data.count else { return }
        let srcPort = (Int(data[transportStart]) << 8) | Int(data[transportStart+1])
        let dstPort = (Int(data[transportStart+2]) << 8) | Int(data[transportStart+3])
        let flow: Flow = (srcIP, srcPort, dstIP, dstPort, protocolNum == 6 ? "TCP" : "UDP")

        // ── S2C 通道（2026-09-30 根因修正：不再送解码器）──
        // ⚠️ 推翻 2026-09-25 的「移动包全部是 s2c（服务器下发轨迹点）」结论：
        //   实测 S2C 30031 上只有两类内容 ——
        //   ① 76 字节心跳（每 15.00s 一个，内含**微秒时钟**：u32@56 每秒恒 +1,000,000；
        //      decodeProtoMove 曾把 bit498/509 的时钟位模式当成坐标，这是
        //      「传送 4~5 次定位纹丝不动」的直接原因）
        //   ② 物品/生成记录推送（PropBox_Item_*、PrivateSpawnInfoRecord 等明文元数据）
        //   —— 全都不含玩家实时位置。真实移动包在 **C2S UDP 30212**（~8Hz 上报）。
        //   MaaNTE 上游对 S2C 一律丢弃；本实现对齐：S2C 仅保留流量计数
        //   （hasRecentTraffic / 流量新鲜度仍由 :1319 的 statS2C 与 lastPacketWall 支撑），
        //   不进解码器 —— 心跳噪声绝不进入 findCandidates 状态机。
        // ── 游戏流量标记（裸 UDP 下必须区分游戏包与系统 UDP，见 markGameTraffic）──
        // ① 端口 30031：游戏心跳/元数据通道，恒定存在
        // ② 已学习的游戏端口：此前解出过真样本的端口
        if isGamePort(flow.1) || isGamePort(flow.3) {
            markGameTraffic()
        }
        if direction == "s2c" { return }
        if direction != "c2s" { return }
        statC2S += 1
        // findCandidates 需要 searchEnd > 190 位 → payload ≥ 32 字节。
        // 对齐MaaNTE原版"payload非空即试"：旧代码 <70 丢弃把 48 字节的 c2s 移动包全部挡在了 decode 之外。
        guard payload.count >= 32 else { return }
        statDecodeCalls += 1
        if let pose = decoder.decode(payload: payload, timestamp: timestamp, flow: flow) {
            statSamples += 1
            // 解出**真样本** → 记住这条通道的远端端口（裸 UDP 下甄别游戏流量的依据）
            learnGamePort(flow.3)
            let now = Date().timeIntervalSince1970
            lock.lock()
            let gap = now - lastSampleWall
            if gap >= interval {
                sample = pose
                sampleAt = timestamp
                lastSampleWall = now
                lock.unlock()
                // ══════════════════════════════════════════════════════════
                // 样本落地诊断（定位链路的最后一环，2026-09-30 随方向修复迁至 C2S）
                // ══════════════════════════════════════════════════════════
                // `间隔` 直接反映游戏上报周期（C2S 移动包实测 ~8Hz，站立也发、
                // 位置恒定）；朝向一并列出，用于验证 rotator 解码是否随视角变化。
                pcapLog(String(format: "[SAMPLE] 坐标落地 间隔=%.2fs 世界=(%.1f, %.1f) 高度=%.1f 朝向=%.1f",
                               gap, pose.0, pose.1, pose.2, pose.4))
            } else {
                lock.unlock()
            }
        }
        if decoder.lastCandCount > 0 {
            statCandHits += 1
            statCandPeak = max(statCandPeak, decoder.lastCandCount)
        }
    }

    /// 15秒一行统计汇总（代替原先每包2行的刷屏日志）
    private func logStats() {
        let now = Date().timeIntervalSince1970
        guard now - statWindowStart >= 15 else { return }
        let dt = now - statWindowStart
        pcapLog("[STATS] \(Int(dt))s: 包=\(statPackets) s2c=\(statS2C) c2s送解=\(statC2S) 解码调用=\(statDecodeCalls) 候选包=\(statCandHits)/峰=\(statCandPeak) 样本=\(statSamples) 新协议=\(decoderProtoSamples)")
        statWindowStart = now
        statPackets = 0; statS2C = 0; statC2S = 0
        statDecodeCalls = 0; statCandHits = 0; statCandPeak = 0; statSamples = 0
    }

    /// 30031 端口最近一段时间是否真有数据包。
    ///
    /// 这是判断「游戏到底在不在跑」最直接、也最便宜的信号：
    ///   · 直接、可靠 —— 定位数据全部来自这个端口，有包=游戏在通信；
    ///     比查进程名可靠得多（辅助进程 crashpad_handler 也叫「异环」，
    ///     曾被它骗成"游戏在跑"）。
    ///   · 极便宜 —— 只读一个自增计数器，零 IPC、零 sysctl、零遍历。
    ///
    /// 判定窗口：最近 `window` 秒内收到过包。
    ///
    /// ⚠️ 实测修正（2026-09-25，tcpdump 30 秒采样）：游戏同步包**不是持续流**，
    /// 而是突发式——1 秒内 5-6 包，然后静默 6-9 秒。旧注释"几十 Hz 持续"是错的，
    /// 默认窗口已从 3s 改为 `trafficFreshWindow`（12s，覆盖最长间隙）。
    // ══════════════════════════════════════════════════════════════════════
    //  游戏流量标记（2026-09-30，配合裸 UDP 过滤器）
    // ══════════════════════════════════════════════════════════════════════
    //
    // 为什么需要它：过滤器已改为裸 UDP（`tcp port 30031 or udp`），en8 上因此
    // 还有大量**系统 UDP**（QUIC/443、DNS、mDNS）。若 `lastPacketWall` 仍由
    // 「任意包」刷新，则「游戏退出」永远判不出来 —— 实测：nic-autotest 停注入
    // 22 秒后仍报「有流量」，锁定状态再也回不到探测（阶段 C 失败）。
    //
    // 判据（只认游戏自己的流量，两类）：
    //   ① 端口 30031 —— 游戏的 TCP 心跳/元数据通道，恒定存在；
    //   ② **动态学习的游戏端口**：某端口第一次让解码器输出**真样本**
    //      （decode 返回 pose，即通过候选验证 + 连续性锁定）→ 记入 gamePorts。
    //
    // ⚠️ 为何不用「解出候选」作判据（曾经的写法，已废弃）：
    //   实测证明它会被**随机 UDP 误触** —— 无游戏运行时（en8 上无任何 30031 /
    //   30160 流量、游戏进程 %CPU 全 0）阶段 A 仍报「包总数=102 且锁定 en8」。
    //   原因：findCandidates 的候选验证（时间戳区间 + UE 向量头 + rotator 合法）
    //   对加密/随机载荷并非绝对免疫 —— 单个包撞上合法组合的概率不高，但
    //   en8 上系统 UDP 每秒上千包，一段时间内必然命中，于是「无游戏」被判成
    //   「有游戏」，失流永不触发（nic-autotest 阶段 C 失败的真正原因）。
    //   ⟹ 判据改用「解出**真样本**」：decode 返回 pose 要求候选通过验证并被
    //      状态机接受（新 flow 还需双包确认），随机载荷几乎不可能连续满足。
    //   这让「游戏流量」= 「真的解出了玩家坐标的流量」，语义最准确，
    //   且**端口仍然不需要写死**（换服换端口后新端口自然会进 gamePorts）。
    private func markGameTraffic() {
        lock.lock()
        lastPacketWall = Date().timeIntervalSince1970
        lock.unlock()
    }

    /// 记住「这个端口确实是游戏移动包通道」（解出真样本时调用）。
    private func learnGamePort(_ port: Int) {
        lock.lock()
        if gamePorts.count < 8 { gamePorts.insert(port) }
        lock.unlock()
    }

    /// 该端口是否已被确认为游戏端口（30031 恒真）。
    private func isGamePort(_ port: Int) -> Bool {
        if port == 30031 { return true }
        lock.lock()
        defer { lock.unlock() }
        return gamePorts.contains(port)
    }

    func hasRecentTraffic(window: Double = CoordinateCapture.trafficFreshWindow) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // ⚠️ lastPacketWall == 0 是「从未收到过任何包」的哨兵（2026-09-30 起）。
        //    此时 `now - 0` 是纪元以来的秒数（约 1.79e9），必然远大于任何合理
        //    窗口 → 返回 false，语义正确（没收到包就是没流量）。
        //    这行守卫是**显式**表达该意图，避免将来有人把初值改回非 0 时
        //    又悄悄引入「启动后 20 秒内误报有流量」的老问题。
        guard lastPacketWall > 0 else { return false }
        let now = Date().timeIntervalSince1970
        return (now - lastPacketWall) <= window
    }

    /// 自抓包启动以来收到的包总数（含非 30031 的，用于区分
    /// 「端口没流量」与「抓包本身没跑起来」两种不同故障）。
    var totalPackets: Int {
        lock.lock()
        defer { lock.unlock() }
        return statPacketsTotal
    }

    /// 读取最新坐标。默认新鲜窗口按实测突发间隔设为 12s（见 poseFreshWindow）——
    /// 旧默认 1s 会让坐标在静默间隙频繁"过期"，小地图跟着停更。
    ///
    /// ⚠️ 2026-09-30：窗口已按新实测改为 `poseFreshWindow`(=15s)，见其注释。
    func read(maxAge: Double = CoordinateCapture.poseFreshWindow) -> Pose? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = sample else { return nil }
        let now = Date().timeIntervalSince1970
        if now - lastSampleWall > maxAge { return nil }
        return s
    }

    /// 诊断快照：把 `read()` 返回 nil 的**两种原因区分开**。
    ///
    /// 为什么需要它：`read()` 只返回 `Pose?`，调用方无法知道 nil 是
    /// 「从来没收到过样本」还是「有样本但已过期」。这两种情况的修法完全不同：
    ///   · 没样本 → 查抓包/解码/协议
    ///   · 过期   → 查窗口值 / 发包间隔
    ///
    /// 实机证据（2026-09-30，用 AURORA_UI_LOCAL=1 本地模式连续观察）：
    /// `[STATS]` 每 15 秒稳定报 `样本=1`（说明 **decode 一直在成功**），
    /// 但 `[LOCATE]` 持续报「定位中断」——两者矛盾，必须直接读内部状态才能定论。
    /// 本访问器就是为此加的：`ageSeconds` 会直接告诉我们是"过期"还是"没样本"。
    ///
    /// - Returns: `(hasSample, ageSeconds, lastWall)`；`ageSeconds` 为 nil 表示从未有过样本。
    func diagnostics() -> (hasSample: Bool, ageSeconds: Double?, lastWall: Double) {
        lock.lock()
        defer { lock.unlock() }
        let has = (sample != nil)
        let age: Double? = (lastSampleWall > 0)
            ? Date().timeIntervalSince1970 - lastSampleWall
            : nil
        return (has, age, lastSampleWall)
    }

    /// 读取最新加速度（来自同一个 30031 包，与坐标同源）。
    ///
    /// 注意：坐标系尚未实测确认（世界系 vs 车体系），单位推测为 cm/s²。
    /// 目前仅供 UI 展示与后续标定，**不要**直接当作物理加速度喂给控制逻辑。
    func readAcceleration(maxAge: Double = 0.5) -> Vec3? {
        decoder.acceleration(maxAge: maxAge)
    }

    /// 带新鲜度判定的坐标读取 —— 解决「定位闪断」而不引入「幽灵定位」。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 为什么需要它（2026-09-30 实机定论）
    /// ══════════════════════════════════════════════════════════════════════
    /// 实机埋点测得 **游戏固定每 15.01 秒下发一个坐标包**（见 `poseFreshWindow`
    /// 注释里的 `[SAMPLE]` 记录），且约 **6% 的周期整轮不发**（17 个周期 1 次，
    /// 该周期 `s2c=0`、`候选包=0` —— 是游戏行为，客户端改不了）。
    ///
    /// 于是 `read(maxAge:)` 的单一阈值陷入两难：
    ///   · 窗口取 18s（≈1 个周期 + 余量）→ 每遇到一次断档就过期 → **定位闪断**
    ///   · 窗口取 35s（≈扛 2 个周期）    → 不闪了，但游戏关闭后 35 秒仍显示
    ///                                      旧位置 → **幽灵定位**
    /// 蒙特卡洛验证（6% 断档率）：窗口 18/25/30s 的可用率都是 94.6%，
    /// 直到 35s 才跳到 99.7% —— 阈值型判据在这是**断崖式**的，没有中间地带。
    ///
    /// 本方法把「数据陈旧」与「数据不可用」分开表达：
    ///   · 从未有过样本        → `.unavailable`（真没数据，UI 该显示"等待"）
    ///   · 有样本且在窗口内    → `.fresh(pose)`（正常）
    ///   · 有样本但超出窗口    → `.stale(pose, age)`（**仍返回位置**，但如实告知年龄）
    ///
    /// 调用方据此可以：位置照常显示（不闪断），但用不同样式/提示表达"数据陈旧"。
    /// 这样窗口不必为了抗断档而放大，幽灵定位也不复存在 —— 两难被解开。
    enum PoseRead {
        case unavailable                    // 从未收到过坐标
        case fresh(Pose)                    // 新鲜，可正常使用
        case stale(Pose, ageSeconds: Double) // 陈旧（超窗），但位置仍有参考价值
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ★ 2026-09-30 性能优化（第 4 批 G）：定位新鲜度**分级**
    // ══════════════════════════════════════════════════════════════════════
    //
    // 【为什么要再做一层】上面的 `PoseRead` 已把"陈旧 ≠ 不可用"表达出来了，
    //   但**消费者不分级**：UI 显示、决策、控制三者拿到的是同一种"陈旧"，
    //   于是无法各取所需 —— UI 想"位置照显、只是变灰"，决策想"降权"，
    //   控制想"保守"。三级 tier 就是给这三类消费者各自的判据。
    //
    // 【关键：不提高任何频率】
    //   定位更新频率仍由游戏的 15.01s 突发决定（客户端改不了），
    //   本项只是把**同一份数据**按年龄分成四档，让不同消费者用合适的态度对待。
    //   ⟹ 不增加抓包、不增加截图、不增加任何周期任务。
    //
    // 【为什么这样能治 6% 断档】蒙特卡洛显示单一阈值是"断崖式"的
    //   （18/25/30s 可用率全为 94.6%，35s 才跳到 99.7%，没有中间地带）。
    //   分级后：UI 层的 `live+recent` 都正常显示（可用率 ≈ 100%），
    //   只有 `stale/lost` 才降权 —— 于是"闪断"消失，而"幽灵定位"也不会出现
    //   （因为 `lost` 档 UI 明确标"无定位"，且 `hasRecentTraffic` 前置门仍在）。
    enum PoseTier {
        case live      // ≤ liveWindow（默认 18s = 现有 poseFreshWindow）：全功能
        case recent    // ≤ recentWindow（默认 40s ≈ 扛 2~3 个周期）：UI 正常，决策降权
        case stale     // ≤ staleWindow（默认 90s）：UI 标"陈旧"，决策不采信
        case lost      // > staleWindow：UI 标"无定位"
    }

    /// 分级阈值。`.live` **严格等于**现有 `poseFreshWindow`，
    /// 保证既有行为逐字不变（老阈值仍有效），只是多了两档更宽的。
    static let poseRecentWindow: Double = 40.0   // ≈ 2.6 个 15s 周期
    static let poseStaleWindow: Double = 90.0    // ≈ 6 个周期；再久就认定丢了

    /// 带 tier 的读取 —— 消费者按档位决定态度（UI 显示 / 决策权重 / 控制策略）。
    ///
    /// - Returns: `(tier, pose?, ageSeconds)`；`pose` 为 nil 仅当从未有过样本。
    func readWithTier(
        live: Double = CoordinateCapture.poseFreshWindow,
        recent: Double = CoordinateCapture.poseRecentWindow,
        stale: Double = CoordinateCapture.poseStaleWindow
    ) -> (tier: PoseTier, pose: Pose?, ageSeconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard let s = sample else { return (.lost, nil, nil) }
        let age = Date().timeIntervalSince1970 - lastSampleWall
        let tier: PoseTier
        if age <= live { tier = .live }
        else if age <= recent { tier = .recent }
        else if age <= stale { tier = .stale }
        else { tier = .lost }
        // ⚠️ `live` 之外的档位**仍然返回位置**（不闪断）；是否采信由调用方按档位决定。
        return (tier, s, age)
    }

    /// 读取坐标并附带新鲜度。
    ///
    /// - Parameter maxAge: 超过此年龄即视为陈旧（默认 `poseFreshWindow`）。
    ///                     注意陈旧**不再**返回 nil —— 这是与 `read` 的关键差异。
    func readWithFreshness(maxAge: Double = CoordinateCapture.poseFreshWindow) -> PoseRead {
        lock.lock()
        defer { lock.unlock() }
        guard let s = sample else { return .unavailable }
        let age = Date().timeIntervalSince1970 - lastSampleWall
        return age > maxAge ? .stale(s, ageSeconds: age) : .fresh(s)
    }

    /// 停止抓包（自适应主循环 + 当前锁定句柄）——幂等，deinit 兜底。
    func close() {
        let wasRunning = running
        running = false
        supervisorThread?.cancel()
        if wasRunning {
            pcapLog("[CoordinateCapture] 抓包已停止（自适应主循环退出）")
        }
    }

    /// 自适应状态摘要（诊断/自检用，单行）
    var adaptationSummary: String {
        let active = activeInterface ?? "探测中"
        return "锁定=\(active) 探测轮=\(probeRounds) 锁定次数=\(lockCount) 包总数=\(totalPackets) 上次好卡=\(lastGoodInterface ?? "无")"
    }

    deinit { close() }
}

// MARK: - 世界坐标 → 地图像素（与NetworkLocator.swift的校准常量同步）

/// 世界坐标转地图像素
func worldToMapPixel(_ pose: Pose) -> (mapX: Double, mapY: Double, heading: Double) {
    let wx = pose.0, wy = pose.1
    // 线性变换
    let mapX = kCalibA * wx + kCalibB * wy + kCalibTX
    let mapY = kCalibA * wy - kCalibB * wx + kCalibTY
    return (mapX, mapY, pose.4)  // heading已计算好
}
