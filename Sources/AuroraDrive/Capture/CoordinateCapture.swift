// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later
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

    typealias Candidate = (clientTime: Double, offset: Int, acceleration: Vec3, location: Vec3)

    /// 主解码入口
    func decode(payload: [UInt8], timestamp: Double, flow: Flow) -> Pose? {
        // ── 新协议优先（2026-09-25 逆向）──
        // 游戏 1.4.x 起 30031 的移动包改为 protobuf 封装 + 位流坐标，
        // 旧的 UE5 裸位流扫描器对它恒返回空。先试新路径，不命中再走旧路径
        // （旧路径保留：若游戏回退版本/其他区服仍是裸位流，仍然可用）。
        if let mv = decodeProtoMove(payload) {
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
func pcapLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = ts + " " + msg + "\n"
    let path = "/tmp/aurora_pcap.log"
    let url = URL(fileURLWithPath: path)
    if let handle = try? FileHandle(forWritingTo: url) {
        try? handle.seekToEnd()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
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
    /// 全轮无果后的重探间隔（秒）。用户指定 2 秒：比 5 秒灵敏，又不是高频扫描。
    private static let probeRetryInterval: Double = 2.0
    /// 失流判定窗口（秒）——锁定监听中超过这么久没有任何 30031 包 → 判失流 → 重新探测。
    ///
    /// ⚠️ 实测依据：突发间隔最长达 9 秒（30 秒采样），旧的 3 秒窗口会把正常
    /// 的静默期误判成停流 → 锁定后反复横跳。取 12 秒 = 最长静默 + 余量。
    private static let streamLostWindow: Double = 12.0

    /// 「流量新鲜」判定窗口（秒）——UI/DriveState 判「游戏在不在通信」的统一尺子。
    ///
    /// **与 streamLostWindow 同源**（都是"容忍突发静默间隙"的语义）：
    /// 实测游戏同步突发间隔最长 9s，若用旧的 3s 窗口，UI 会在静默期间误报
    /// 「游戏未运行」把小地图打回空白（忽明忽暗）。12s 覆盖最长间隙 + 余量。
    /// 消费方：DriveState.locateSource / runNetworkLocateStep 前置门。
    static let trafficFreshWindow: Double = 12.0

    /// 坐标新鲜窗口（秒）——`read()` 默认值（消费方 DriveState 亦用此值）。
    /// 实测同步包间隔最长 9s，旧默认 1s 会让坐标频繁"过期"（地图不动）。
    static let poseFreshWindow: Double = 12.0

    // 15秒窗口统计（仅 supervisor 单线程读写，无并发）
    private var statWindowStart = Date().timeIntervalSince1970
    /// 最近一次收到任意包的时间（用于 hasRecentTraffic）
    private var lastPacketWall = Date().timeIntervalSince1970
    /// 自启动以来的包总数（跨统计窗口不清零）
    private var statPacketsTotal = 0
    private var statPackets = 0
    private var statS2C = 0
    private var statC2S = 0
    private var statDecodeCalls = 0
    private var statCandHits = 0
    private var statCandPeak = 0
    private var statSamples = 0
    /// 探测轮数 / 锁定次数（诊断：自适应行为是否在工作）
    private(set) var probeRounds = 0
    private(set) var lockCount = 0

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
    private static let skipPrefixes = ["lo", "pdp", "utun", "awdl", "bridge", "xhc",
                                       "ap", "anpi", "gif", "stf"]

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

        // 设置过滤器：**只抓游戏 30031 端口**（TCP + UDP 两种承载）。
        //
        // 历史坑：原过滤器是 "tcp port 30031 or udp"，后半句是裸的 ——
        // 它会把机器上**所有 UDP 流量**（DNS、mDNS、系统广播、其它 App）
        // 全部抓进来。解码器又不校验来源，于是任意 ≥32 字节的杂包都会被
        // 硬解成一组坐标，表现就是「游戏都没启动，定位疯狂乱跳」。
        // 现在锁死端口：非 30031 的包在内核 BPF 层就被丢弃，进不来。
        var filterProgram = bpf_program(bf_len: 0, bf_insns: nil)
        let filterExpr = "(tcp port 30031) or (udp port 30031)"
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
        for name in allNames where !Self.skipPrefixes.contains(where: { name.hasPrefix($0) }) {
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
        guard let handle = openWithFilter(name, errbuf: &errbuf) else { return nil }
        var got = false
        let deadline = Date().addingTimeInterval(window)
        while running, Date() < deadline {
            var headerPtr: UnsafeMutablePointer<pcap_pkthdr>? = nil
            var packetPtr: UnsafePointer<UInt8>? = nil
            let result = pcap_next_ex(handle, &headerPtr, &packetPtr)
            if result == 1, let h = headerPtr, let p = packetPtr {
                got = true
                processPacket(header: h.pointee, packet: p)
                break
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
        pcapLog("[pcap] 自适应网卡主循环启动（探测 高嫌疑\(Int(Self.probeWindowPrimary * 1000))ms/其余\(Int(Self.probeWindowOther * 1000))ms / 重探间隔 \(Int(Self.probeRetryInterval))s / 失流窗口 \(Int(Self.streamLostWindow))s）")
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
                // 分级窗口：默认路由 / 上次命中 的网卡给足时间覆盖突发周期；
                // 其余候选快速筛掉（零流量网卡不值得久等）。
                let w = (name == preferred || name == lastGoodInterface)
                    ? Self.probeWindowPrimary : Self.probeWindowOther
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
                sleepInterruptible(Self.probeRetryInterval)
                continue
            }

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
        // 记录"刚才有包"的时间戳：这是 hasRecentTraffic 的唯一依据。
        // 注意在锁内更新，与 hasRecentTraffic 的读保持同步。
        lock.lock()
        lastPacketWall = Date().timeIntervalSince1970
        statPacketsTotal += 1
        lock.unlock()
        defer { logStats() }
        let timestamp = Double(header.ts.tv_sec) + Double(header.ts.tv_usec) / 1_000_000.0
        let caplen = Int(header.caplen)
        let data = Array(UnsafeBufferPointer(start: packet, count: caplen))
        guard data.count > 14 else { return }
        var offset = 14
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

        // ── 新协议通道（2026-09-25 逆向）──
        // ⚠️ 关键修正：本方法原先在 s2c 包上直接 return（沿用 MaaNTE 旧假设
        // 「移动包只走 c2s」）。实测发现游戏 1.4.x 的移动包**全部是 s2c**
        // （服务器下发轨迹点），旧写法让新协议解码器永远收不到包 —— 这是
        // 「候选包=0、样本=0」的真正断点。故 s2c 也送解码器（新协议路径由
        // 56 字节固定前缀 + 长度 {72,76} 精确识别，非移动包会被快速拒绝，
        // 不会把无关流量喂进旧路径）。
        if direction == "s2c" {
            statDecodeCalls += 1
            if let pose = decoder.decode(payload: payload, timestamp: timestamp, flow: flow) {
                statSamples += 1
                let now = Date().timeIntervalSince1970
                lock.lock()
                if now - lastSampleWall >= interval {
                    sample = pose
                    sampleAt = timestamp
                    lastSampleWall = now
                }
                lock.unlock()
            }
            if decoder.lastCandCount > 0 {
                statCandHits += 1
                statCandPeak = max(statCandPeak, decoder.lastCandCount)
            }
            return                      // s2c 不走旧路径（旧路径仅针对 c2s 位流块）
        }
        if direction != "c2s" { return }
        statC2S += 1
        // findCandidates 需要 searchEnd > 190 位 → payload ≥ 32 字节。
        // 对齐MaaNTE原版"payload非空即试"：旧代码 <70 丢弃把 48 字节的 c2s 移动包全部挡在了 decode 之外。
        guard payload.count >= 32 else { return }
        statDecodeCalls += 1
        if let pose = decoder.decode(payload: payload, timestamp: timestamp, flow: flow) {
            statSamples += 1
            let now = Date().timeIntervalSince1970
            lock.lock()
            if now - lastSampleWall >= interval {
                sample = pose
                sampleAt = timestamp
                lastSampleWall = now
            }
            lock.unlock()
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
    func hasRecentTraffic(window: Double = CoordinateCapture.trafficFreshWindow) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
    func read(maxAge: Double = CoordinateCapture.poseFreshWindow) -> Pose? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = sample else { return nil }
        let now = Date().timeIntervalSince1970
        if now - lastSampleWall > maxAge { return nil }
        return s
    }

    /// 读取最新加速度（来自同一个 30031 包，与坐标同源）。
    ///
    /// 注意：坐标系尚未实测确认（世界系 vs 车体系），单位推测为 cm/s²。
    /// 目前仅供 UI 展示与后续标定，**不要**直接当作物理加速度喂给控制逻辑。
    func readAcceleration(maxAge: Double = 0.5) -> Vec3? {
        decoder.acceleration(maxAge: maxAge)
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
