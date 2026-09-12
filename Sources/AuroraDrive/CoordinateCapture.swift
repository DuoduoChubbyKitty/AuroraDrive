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
private let kCalibA: Double = 0.016394586684750773
private let kCalibB: Double = 5.693519256055879e-08
private let kCalibTX: Double = 6293.474380746091
private let kCalibTY: Double = 3472.664390686138

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
        // 符号扩展必须走 Int64：UInt64 的 &- 会下溢回绕成巨大正数（Python大整数无此问题），
        // 导致所有负坐标 > kMaxLocationAbs 被淘汰 → 永远0候选
        let sv: Int64 = (v & sign) != 0 ? Int64(v) - Int64(modulus) : Int64(v)
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

    typealias Candidate = (clientTime: Double, offset: Int, acceleration: Vec3, location: Vec3)

    /// 主解码入口
    func decode(payload: [UInt8], timestamp: Double, flow: Flow) -> Pose? {
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
        guard let (_, cursor1, _, _) = ue5Vector(payload, offset: bitOffset + 32, scale: 10) else { return nil }
        guard let (_, cursor2, _, _) = ue5Vector(payload, offset: cursor1, scale: 100) else { return nil }
        guard let (rotation, _) = ue5Rotator(payload, offset: cursor2) else { return nil }

        lastTime = clientTime
        lastOffset = bitOffset
        lastCapture = timestamp
        lastLocation = location
        return toPose(location, rotation)
    }

    /// 扫描包中所有有效的移动块
    private func findCandidates(_ payload: [UInt8]) -> [Candidate]? {
        var output: [Candidate] = []
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

            // 检查旋转有效性（locEnd已含header+3值，只需加7位padding）
            let rotationOffset = locEnd + 7
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
    private var pcapHandle: OpaquePointer?
    private var captureThread: Thread?
    private var running = false
    private let lock = NSLock()

    // 15秒窗口统计（仅 captureLoop 线程读写）
    private var statWindowStart = Date().timeIntervalSince1970
    private var statPackets = 0
    private var statS2C = 0
    private var statC2S = 0
    private var statDecodeCalls = 0
    private var statCandHits = 0
    private var statCandPeak = 0
    private var statSamples = 0

    /// 启动抓包 — 遍历所有网卡，找到有30031端口流量的那个
    func start() -> Bool {
        guard !running else { return true }
        var errbuf = [CChar](repeating: 0, count: 256)

        // 枚举所有网卡
        var alldevsPtr: UnsafeMutablePointer<pcap_if_t>? = nil
        let findResult = pcap_findalldevs(&alldevsPtr, &errbuf)
        if findResult < 0 || alldevsPtr == nil {
            let errMsg = String(cString: errbuf)
            pcapLog("[CoordinateCapture] pcap_findalldevs失败: \(errMsg)")
            return false
        }

        // 遍历所有网卡，逐个尝试打开
        var current = alldevsPtr
        var devName: String? = nil
        while let dev = current {
            let name = String(cString: dev.pointee.name!)
            pcapLog("[CoordinateCapture] 发现网卡: \(name)")
            
            // 跳过lo0/pdp_ip/utun/awdl/xhc20桥接等非物理网卡
            if name.hasPrefix("lo") || name.hasPrefix("pdp") || name.hasPrefix("utun") 
                || name.hasPrefix("awdl") || name.hasPrefix("bridge") || name.hasPrefix("xhc") {
                current = dev.pointee.next
                continue
            }
            
            // 尝试打开这个网卡
            let handle = name.withCString { namePtr in
                pcap_open_live(namePtr, 65535, 0, 20, &errbuf)
            }
            if handle == nil {
                let errMsg = String(cString: errbuf)
                pcapLog("[CoordinateCapture] \(name)打开失败: \(errMsg)")
                current = dev.pointee.next
                continue
            }
            
            // 设置过滤器：TCP 30031 + 全部UDP（对齐MaaNTE原版 "tcp port 30031 or udp"，UE5移动同步可能走UDP）
            var filterProgram = bpf_program(bf_len: 0, bf_insns: nil)
            let compileResult: Int32 = "tcp port 30031 or udp".withCString { cStr in
                pcap_compile(handle!, &filterProgram, cStr, 0, 0)
            }
            if compileResult < 0 {
                pcapLog("[CoordinateCapture] \(name) pcap_compile失败")
                pcap_close(handle!)
                current = dev.pointee.next
                continue
            }
            if pcap_setfilter(handle!, &filterProgram) < 0 {
                pcapLog("[CoordinateCapture] \(name) pcap_setfilter失败")
                pcap_close(handle!)
                current = dev.pointee.next
                continue
            }
            
            // 这个网卡可用！
            devName = name
            pcapHandle = handle
            pcapLog("[CoordinateCapture] ✓ 选中网卡: \(name) (过滤器: tcp port 30031 or udp)")
            break
        }
        
        pcap_freealldevs(alldevsPtr)

        guard let _ = devName, let _ = pcapHandle else {
            pcapLog("[CoordinateCapture] ❌ 没有找到可用网卡!")
            return false
        }

        running = true
        captureThread = Thread { [weak self] in
            self?.captureLoop()
        }
        captureThread?.name = "com.aurora.coordinate-capture"
        captureThread?.start()
        pcapLog("[CoordinateCapture] 抓包已启动 (tcp port 30031 or udp)")
        return true
    }

    /// 抓包循环——用pcap_next_ex不用回调，避免Apple Silicon PAC崩溃
    private func captureLoop() {
        guard let handle = pcapHandle else { return }
        pcapLog("[pcap] captureLoop开始, handle=有")
        while running {
            var headerPtr: UnsafeMutablePointer<pcap_pkthdr>? = nil
            var packetPtr: UnsafePointer<UInt8>? = nil
            let result = pcap_next_ex(handle, &headerPtr, &packetPtr)
            if result == 0 { continue }
            if result < 0 { break }
            guard let h = headerPtr, let p = packetPtr else { continue }
            processPacket(header: h.pointee, packet: p)
        }
    }

    /// 处理抓到的包（单线程：captureLoop 串行调用，统计字段无需加锁）
    func processPacket(header: pcap_pkthdr, packet: UnsafePointer<UInt8>) {
        statPackets += 1
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
        if direction == "s2c" || direction == "unknown" { return }
        statC2S += 1
        // findCandidates 需要 searchEnd > 190 位 → payload ≥ 32 字节。
        // 对齐MaaNTE原版"payload非空即试"：旧代码 <70 丢弃把 48 字节的 c2s 移动包全部挡在了 decode 之外。
        guard payload.count >= 32 else { return }
        guard transportStart + 4 <= data.count else { return }
        let srcPort = (Int(data[transportStart]) << 8) | Int(data[transportStart+1])
        let dstPort = (Int(data[transportStart+2]) << 8) | Int(data[transportStart+3])
        statDecodeCalls += 1
        if let pose = decoder.decode(payload: payload, timestamp: timestamp, flow: (srcIP, srcPort, dstIP, dstPort, protocolNum == 6 ? "TCP" : "UDP")) {
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
        pcapLog("[STATS] \(Int(dt))s: 包=\(statPackets) s2c=\(statS2C) c2s送解=\(statC2S) 解码调用=\(statDecodeCalls) 候选包=\(statCandHits)/峰=\(statCandPeak) 样本=\(statSamples)")
        statWindowStart = now
        statPackets = 0; statS2C = 0; statC2S = 0
        statDecodeCalls = 0; statCandHits = 0; statCandPeak = 0; statSamples = 0
    }

    /// 读取最新坐标
    func read(maxAge: Double = 1.0) -> Pose? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = sample else { return nil }
        let now = Date().timeIntervalSince1970
        if now - lastSampleWall > maxAge { return nil }
        return s
    }

    /// 停止抓包
    func close() {
        running = false
        if let handle = pcapHandle {
            pcap_breakloop(handle)
            captureThread?.cancel()
            pcap_close(handle)
            pcapHandle = nil
        }
        print("[CoordinateCapture] 抓包已停止")
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
