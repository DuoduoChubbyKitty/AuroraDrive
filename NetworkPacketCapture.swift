// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
// NetworkPacketCapture.swift — 网络抓包定位引擎（NetworkExtension）
// macOS 12+ NetworkExtension 框架，用户态抓包，零拷贝内存
// 解析 UE5 移动包（bit-packed 格式），提取位置/旋转，坐标变换到地图
// ============================================================================

import Foundation
import NetworkExtension
import os

// libpcap C 头桥接
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

// libpcap 常量
private let PCAP_ERRBUF_SIZE = 256
private let PCAP_NETMASK_UNKNOWN = 0xffffffff as UInt32
private let PCAP_ERROR_BREAK = -2

// libpcap 结构体定义 (必须在 @_silgen_name 声明之前)
private struct pcap_pkthdr {
    var ts: timeval
    var caplen: UInt32
    var len: UInt32
}

private struct timeval {
    var tv_sec: time_t
    var tv_usec: suseconds_t
}

// pcap_if_t 结构体 (用于 pcap_findalldevs)
private struct pcap_if_t {
    var next: UnsafeMutablePointer<pcap_if_t>?
    var name: UnsafePointer<Int8>?
    var description: UnsafePointer<Int8>?
    var addresses: UnsafeMutablePointer<pcap_addr_t>?
    var flags: UInt32
}

private struct pcap_addr_t {
    var next: UnsafeMutablePointer<pcap_addr_t>?
    var addr: UnsafeMutablePointer<sockaddr>?
    var netmask: UnsafeMutablePointer<sockaddr>?
    var broadaddr: UnsafeMutablePointer<sockaddr>?
    var dstaddr: UnsafeMutablePointer<sockaddr>?
}

// libpcap C 函数声明 (Swift C 互操作)
@_silgen_name("pcap_findalldevs")
private func pcap_findalldevs(_ alldevsp: UnsafeMutablePointer<UnsafeMutablePointer<pcap_if_t>?>!, _ errbuf: UnsafeMutablePointer<Int8>!) -> Int32

@_silgen_name("pcap_freealldevs")
private func pcap_freealldevs(_ alldevs: UnsafeMutablePointer<pcap_if_t>!) -> Void

@_silgen_name("pcap_open_live")
private func pcap_open_live(_ device: UnsafePointer<Int8>!, _ snaplen: Int32, _ promisc: Int32, _ to_ms: Int32, _ errbuf: UnsafeMutablePointer<Int8>!) -> OpaquePointer?

@_silgen_name("pcap_compile")
private func pcap_compile(_ p: OpaquePointer!, _ fp: UnsafeMutablePointer<bpf_program>!, _ str: UnsafePointer<Int8>!, _ optimize: Int32, _ netmask: UInt32) -> Int32

@_silgen_name("pcap_setfilter")
private func pcap_setfilter(_ p: OpaquePointer!, _ fp: UnsafeMutablePointer<bpf_program>!) -> Int32

@_silgen_name("pcap_freecode")
private func pcap_freecode(_ fp: UnsafeMutablePointer<bpf_program>!) -> Void

@_silgen_name("pcap_next_ex")
private func pcap_next_ex(_ p: OpaquePointer!, _ pkt_header: UnsafeMutablePointer<UnsafePointer<pcap_pkthdr>?>!, _ pkt_data: UnsafeMutablePointer<UnsafePointer<UInt8>?>!) -> Int32

@_silgen_name("pcap_geterr")
private func pcap_geterr(_ p: OpaquePointer!) -> UnsafePointer<Int8>!

@_silgen_name("pcap_close")
private func pcap_close(_ p: OpaquePointer!) -> Void

// MARK: - 常量与配置

/// 抓包错误类型
private enum NetworkCaptureError: Error {
    case pcapInitFailed(String)
    case pcapOpenFailed(String)
    case pcapFilterFailed(String)
    case noSuitableInterface
    case parseError(String)
}

/// UE5 移动包协议端口
private let kGameMovementPort: UInt16 = 30031

/// 地图尺寸（游戏世界坐标系）
private let kGameWorldSize: (x: Double, y: Double) = (11264, 11264)

/// 坐标变换参数（从 MaaNTE 校准数据导入）
/// 世界坐标 (x,y,z) -> 地图像素 (u,v)
/// u = a*x - b*y + tx
/// v = b*x + a*y + ty
private let kCoordTransform = CoordinateTransform(
    axes: (0, 1),
    a: 0.016394586684750773,
    b: 5.693519256055879e-08,
    tx: 6293.474380746091,
    ty: 3472.664390686138,
    error: 0.22031967781665318
)

/// 最大位置绝对值（用于校验）
private let kMaxLocationAbs = 2_000_000.0
private let kMaxRotationAbs = 180.001

/// 北向/东向基准向量（用于航向计算）
private let kNorthVector = SIMD3<Double>(-0.013752068070295848, -0.9999054358407049, 0.0)
private let kEastVector  = SIMD3<Double>(0.9999054358407049, -0.01375206807029585, 0.0)

// MARK: - 数据结构

/// 原始游戏坐标
public struct RawPoint: Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
    
    subscript(index: Int) -> Double {
        switch index {
        case 0: return x
        case 1: return y
        case 2: return z
        default: return 0
        }
    }
}

/// 相机位姿
public struct RawPose: Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var pitch: Double
    public var heading: Double
    
    public init(x: Double, y: Double, z: Double, pitch: Double, heading: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.pitch = pitch
        self.heading = heading
    }
}

/// 地图像素坐标
public struct MapPoint: Sendable {
    public var x: Int
    public var y: Int
    
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// 网络定位结果
public struct NetworkLocateResult: Sendable {
    public let found: Bool
    public let point: MapPoint?
    public let rawCoordinate: RawPoint?
    public let score: Double
    public let mode: String
    public let polygon: [MapPoint]?
    public let rawCoordinate3D: RawPoint?
    public let cameraPitch: Double?
    public let cameraHeading: Double?
    
    public init(
        found: Bool,
        point: MapPoint? = nil,
        rawCoordinate: RawPoint? = nil,
        score: Double = 0.0,
        mode: String = "",
        polygon: [MapPoint]? = nil,
        rawCoordinate3D: RawPoint? = nil,
        cameraPitch: Double? = nil,
        cameraHeading: Double? = nil
    ) {
        self.found = found
        self.point = point
        self.rawCoordinate = rawCoordinate
        self.score = score
        self.mode = mode
        self.polygon = polygon
        self.rawCoordinate3D = rawCoordinate3D
        self.cameraPitch = cameraPitch
        self.cameraHeading = cameraHeading
    }
}

/// 坐标变换结构
private struct CoordinateTransform {
    let axes: (Int, Int)
    let a: Double
    let b: Double
    let tx: Double
    let ty: Double
    let error: Double
    
    func apply(_ point: RawPoint) -> (Double, Double) {
        let x = point[axes.0]
        let y = point[axes.1]
        return (a * x - b * y + tx, b * x + a * y + ty)
    }
    
    func invert(_ point: (Double, Double)) -> (Double, Double)? {
        guard axes == (0, 1) else { return nil }
        let denom = a * a + b * b
        guard denom > 1e-12 else { return nil }
        let dx = point.0 - tx
        let dy = point.1 - ty
        return ((a * dx + b * dy) / denom, (-b * dx + a * dy) / denom)
    }
}

// MARK: - Bit-packed 解析工具

/// 从字节数组按位读取无符号整数
@inline(__always)
private func readBits(_ data: UnsafeRawBufferPointer, offset: Int, count: Int) -> UInt32 {
    guard offset >= 0, count > 0, offset + count <= data.count * 8 else {
        return 0
    }
    let firstByte = offset / 8
    let lastByte = (offset + count + 7) / 8
    let bytes = data.bindMemory(to: UInt8.self)
    var value: UInt32 = 0
    for i in firstByte..<lastByte {
        value = (value << 8) | UInt32(bytes[i])
    }
    return (value >> (offset % 8)) & ((1 << count) - 1)
}

/// 读取 bit-packed 向量 (x, y, z)
/// 格式：7位头部 (1位scaled + 6位width) + 3个分量
private func readVector(_ data: UnsafeRawBufferPointer, offset: inout Int, scale: Int) -> (SIMD3<Double>, Int, Int, Bool)? {
    let header = readBits(data, offset: offset, count: 7)
    offset += 7
    let width = Int(header & 63)
    let scaled = (header >> 6) != 0
    guard width != 0, width <= 32 else { return nil }
    
    var values = SIMD3<Double>(0, 0, 0)
    let signBit = 1 << (width - 1)
    let modulus = 1 << width
    
    for i in 0..<3 {
        let value = readBits(data, offset: offset, count: width)
        offset += width
        var signed = Int32(value)
        if value & UInt32(signBit) != 0 {
            signed -= Int32(modulus)
        }
        values[i] = scaled ? Double(signed) / Double(scale) : Double(signed)
    }
    return (values, offset, width, scaled)
}

/// 读取 FRotator 压缩旋转 (Pitch, Yaw, Roll 各 16-bit)
private func readRotator(_ data: UnsafeRawBufferPointer, offset: inout Int) -> (SIMD3<Double>, Int)? {
    var values = SIMD3<Double>(0, 0, 0)
    for i in 0..<3 {
        let present = readBits(data, offset: offset, count: 1)
        offset += 1
        if present != 0 {
            let compressed = readBits(data, offset: offset, count: 16)
            offset += 16
            var angle = Double(compressed) * 360.0 / 65536.0
            if angle > 180.0 { angle -= 360.0 }
            values[i] = angle
        }
    }
    return (values, offset)
}

/// 检查是否有有效的控制旋转 (用于过滤假阳性)
private func hasValidRotation(_ data: UnsafeRawBufferPointer, offset: Int) -> Bool {
    var cursor = offset
    var flags: [Bool] = []
    for _ in 0..<3 {
        let present = readBits(data, offset: cursor, count: 1)
        flags.append(present != 0)
        cursor += 1 + (present != 0 ? 16 : 0)
    }
    var rotOffset = cursor
    guard let (rot, end) = readRotator(data, offset: &rotOffset) else { return false }
    guard end <= data.count * 8 else { return false }
    // 控制旋转通常只有 pitch 和 yaw，roll 通常省略
    let valid = flags[1] && !flags[2] &&
               abs(rot.x) <= 90.001 &&
               rot.x.isFinite && abs(rot.x) <= kMaxRotationAbs &&
               rot.y.isFinite && abs(rot.y) <= kMaxRotationAbs &&
               rot.z.isFinite && abs(rot.z) <= kMaxRotationAbs
    return valid
}

/// 点积
@inline(__always)
private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    return a.x * b.x + a.y * b.y + a.z * b.z
}

/// 平方距离
@inline(__always)
private func distanceSq(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    let dz = a.z - b.z
    return dx*dx + dy*dy + dz*dz
}

/// 计算航向角 (0=北, 顺时针)
private func headingFromRotation(_ rot: SIMD3<Double>) -> Double {
    let pitch = rot.x
    let yaw = rot.y
    let pitchRad = pitch * .pi / 180.0
    let yawRad = yaw * .pi / 180.0
    let viewDir = SIMD3<Double>(
        cos(pitchRad) * cos(yawRad),
        cos(pitchRad) * sin(yawRad),
        sin(pitchRad)
    )
    let north = dot(viewDir, kNorthVector)
    let east = dot(viewDir, kEastVector)
    var heading = atan2(east, north) * 180.0 / .pi
    if heading < 0 { heading += 360.0 }
    return heading
}

/// 从原始位姿生成完整位姿
private func makePose(location: SIMD3<Double>, rotation: SIMD3<Double>) -> RawPose {
    let heading = headingFromRotation(rotation)
    return RawPose(x: location.x, y: location.y, z: location.z, pitch: rotation.x, heading: heading)
}

// MARK: - 候选解析结果

private typealias Candidate = (clientTime: Double, bitOffset: Int, acceleration: SIMD3<Double>, location: SIMD3<Double>)

// MARK: - 网络定位捕获引擎

/// 网络抓包定位引擎
/// - 使用 NetworkExtension 进行用户态抓包
/// - 解析 UE5 移动包 (TCP 30031)
/// - 输出原始游戏坐标和相机位姿
@available(macOS 12.0, *)
public final class NetworkPacketCapture: @unchecked Sendable {
    
    // MARK: 公共回调
    
    /// 定位结果回调 (主线程)
    public var onLocate: ((NetworkLocateResult) -> Void)?
    
    /// 状态变化回调
    public var onStatusChange: ((CaptureStatus) -> Void)?
    
    /// 统计信息回调 (1Hz)
    public var onStats: ((Stats) -> Void)?
    
    /// 捕获状态
    public enum CaptureStatus {
        case started
        case stopped
        case error(String)
        case permissionDenied
        case interfaceNotFound
    }
    
    /// 运行时统计
    public struct Stats: Sendable {
        public let packetCount: Int
        public let payloadCount: Int
        public let c2sCount: Int
        public let s2cCount: Int
        public let sampleCount: Int
        public let lastPacketAge: Double
        public let lastPayloadAge: Double
        public let lastSampleAge: Double
        public let lastError: String?
    }
    
    // MARK: 私有状态
    
    private let captureQueue = DispatchQueue(label: "aurora.network.capture", qos: .userInteractive)
    private let stateLock = OSAllocatedUnfairLock()
    
    private var _isCapturing = false
    private var _lastError: String?
    private var _stats = Stats(
        packetCount: 0, payloadCount: 0, c2sCount: 0, s2cCount: 0,
        sampleCount: 0, lastPacketAge: -1, lastPayloadAge: -1,
        lastSampleAge: -1, lastError: nil
    )
    
    // NetworkExtension 组件
    private var packetFlow: NEPacketTunnelFlow?
    private var provider: NEPacketTunnelProvider?
    private var observer: Any?
    
    // 解码器状态
    private var decoder = PacketDecoder()
    
    // 统计定时器
    private var statsTimer: Timer?
    
    // 采样控制
    private var lastSampleTime: Date = .distantPast
    private let sampleInterval: TimeInterval = 1.0 / 30.0 // 30Hz
    
    // 最新采样
    private var latestPose: RawPose?
    private var latestPoseTime: Date?
    
    // MARK: 公共属性
    
    public var isCapturing: Bool {
        stateLock.withLock { _isCapturing }
    }
    
    public var lastError: String? {
        stateLock.withLock { _lastError }
    }
    
    public var stats: Stats {
        stateLock.withLock { _stats }
    }
    
    // MARK: 初始化
    
    public init() {}
    
    // MARK: 启动/停止
    
    /// 启动网络抓包
    /// 需要网络扩展权限 (com.apple.developer.networking.networkextension)
    public func start(interfaceName: String? = nil) {
        guard !isCapturing else { return }
        
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.withLock {
                self._isCapturing = true
                self._lastError = nil
                self._stats = Stats(
                    packetCount: 0, payloadCount: 0, c2sCount: 0, s2cCount: 0,
                    sampleCount: 0, lastPacketAge: -1, lastPayloadAge: -1,
                    lastSampleAge: -1, lastError: nil
                )
                self.decoder = PacketDecoder()
                self.latestPose = nil
                self.latestPoseTime = nil
            }
            
            // 检查网络扩展权限
            self.checkNetworkExtensionPermission { [weak self] granted in
                guard let self = self else { return }
                if !granted {
                    self.onStatusChange?(.permissionDenied)
                    return
                }
                
                self.setupPacketCapture(interfaceName: interfaceName)
            }
        }
    }
    
    /// 停止网络抓包
    public func stop() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.teardownPacketCapture()
            self.stateLock.withLock {
                self._isCapturing = false
            }
            self.onStatusChange?(.stopped)
        }
    }
    
    /// 获取最新位姿 (线程安全)
    public func readLatestPose(maxAge: TimeInterval = 1.0) -> RawPose? {
        stateLock.withLock {
            guard let pose = latestPose, let time = latestPoseTime else { return nil }
            if Date().timeIntervalSince(time) > maxAge { return nil }
            return pose
        }
    }
    
    public func readLatestStats() -> Stats {
        stateLock.withLock { _stats }
    }
    
    // MARK: 私有方法 - 权限与初始化
    
    private func checkNetworkExtensionPermission(completion: @escaping (Bool) -> Void) {
        // 检查是否有网络扩展权限
        // 在 macOS 上需要 com.apple.developer.networking.networkextension entitlement
        // 且需要用户在系统设置中授权
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let hasEntitlement = bundleID.contains("networkextension") || 
                             Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.networking.networkextension") != nil
        
        if !hasEntitlement {
            print("[NetworkCapture] ⚠️ Missing networkextension entitlement")
            // 即使没有 entitlement 也尝试启动，可能在开发环境下工作
        }
        completion(true)
    }
    
    // MARK: 私有方法 - 抓包核心
    
    private func setupPacketCapture(interfaceName: String?) {
        // 使用 NWPathMonitor 监听网络状态
        // 实际抓包使用 NEPacketTunnelProvider
        // 这里简化实现：使用 Network.framework 的原始套接字
        
        do {
            // 创建原始套接字监听 TCP 30031
            try startRawSocketCapture()
            onStatusChange?(.started)
            print("[NetworkCapture] ✅ Started on TCP port \(kGameMovementPort)")
        } catch {
            let err = "Failed to start packet capture: \(error.localizedDescription)"
            stateLock.withLock { _lastError = err }
            onStatusChange?(.error(err))
            print("[NetworkCapture] ❌ \(err)")
        }
    }
    
    private func startRawSocketCapture() throws {
        // 真实抓包实现：使用 libpcap (系统自带) 捕获 TCP 30031 端口包
        // 需要在 Package.swift 中链接 libpcap: .linkedLibrary("pcap")
        
        // 启动统计定时器
        startStatsTimer()
        
        // 启动真实 pcap 捕获循环
        try startPcapCaptureLoop()
    }
    
    private func startPcapCaptureLoop() throws {
        // 使用系统 libpcap (macOS 自带) 进行抓包
        // 过滤器：tcp port 30031
        let filter = "tcp port \(kGameMovementPort)"
        
        var errbuf = [Int8](repeating: 0, count: PCAP_ERRBUF_SIZE)
        
        // 查找默认网卡
        var alldevs: UnsafeMutablePointer<pcap_if_t>?
        guard pcap_findalldevs(&alldevs, &errbuf) == 0, let devs = alldevs else {
            let err = "pcap_findalldevs failed: \(String(cString: errbuf))"
            print("[NetworkCapture] ❌ \(err)")
            throw NetworkCaptureError.pcapInitFailed(err)
        }
        defer { pcap_freealldevs(alldevs) }
        
        // 选择第一个非回环、非空设备（实际应按 interfaceName 选择）
        var device: UnsafeMutablePointer<pcap_if_t>? = devs
        var selectedName: String?
        while let d = device {
            guard let namePtr = d.pointee.name else { device = d.pointee.next; continue }
            let name = String(cString: namePtr)
            if !name.hasPrefix("lo") && !name.hasPrefix("utun") {
                selectedName = name
                break
            }
            device = d.pointee.next
        }
        guard let devName = selectedName else {
            throw NetworkCaptureError.noSuitableInterface
        }
        
        print("[NetworkCapture] 📡 Opening device: \(devName)")
        
        // 打开设备
        let snaplen: Int32 = 65535
        let promisc: Int32 = 1
        let timeout: Int32 = 100
        let handle = pcap_open_live(devName, snaplen, promisc, timeout, &errbuf)
        guard let handle = handle else {
            let err = "pcap_open_live failed: \(String(cString: errbuf))"
            print("[NetworkCapture] ❌ \(err)")
            throw NetworkCaptureError.pcapOpenFailed(err)
        }
        
        // 设置过滤器
        var fcode = bpf_program(bf_len: 0, bf_insns: nil)
        let filterCStr = (filter as NSString).utf8String!
        if pcap_compile(handle, &fcode, filterCStr, 1, PCAP_NETMASK_UNKNOWN) != 0 {
            let err = "pcap_compile failed: \(String(cString: pcap_geterr(handle)))"
            pcap_close(handle)
            print("[NetworkCapture] ❌ \(err)")
            throw NetworkCaptureError.pcapFilterFailed(err)
        }
        if pcap_setfilter(handle, &fcode) != 0 {
            let err = "pcap_setfilter failed: \(String(cString: pcap_geterr(handle)))"
            pcap_freecode(&fcode)
            pcap_close(handle)
            print("[NetworkCapture] ❌ \(err)")
            throw NetworkCaptureError.pcapFilterFailed(err)
        }
        pcap_freecode(&fcode)
        
        print("[NetworkCapture] ✅ pcap started on \(devName), filter: \(filter)")
        
        // 在 captureQueue 上跑捕获循环
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.runPcapLoop(handle: handle)
        }
    }
    
    private func runPcapLoop(handle: OpaquePointer) {
        var header: UnsafePointer<pcap_pkthdr>?
        var packet: UnsafePointer<UInt8>?
        
        while self.isCapturing {
            let result = pcap_next_ex(handle, &header, &packet)
            if result == 1, let hdr = header, let pkt = packet {
                // 解析以太网 -> IP -> TCP -> payload
                self.processPcapPacket(header: hdr.pointee, packet: pkt)
                // 更新包计数
                self.stateLock.withLock {
                    self._stats = Stats(
                        packetCount: self._stats.packetCount + 1,
                        payloadCount: self._stats.payloadCount,
                        c2sCount: self._stats.c2sCount,
                        s2cCount: self._stats.s2cCount,
                        sampleCount: self._stats.sampleCount,
                        lastPacketAge: 0,
                        lastPayloadAge: self._stats.lastPayloadAge,
                        lastSampleAge: self._stats.lastSampleAge,
                        lastError: self._stats.lastError
                    )
                }
            } else if result == 0 {
                // 超时，继续循环
                continue
            } else if result == PCAP_ERROR_BREAK {
                // pcap_breakloop 被调用
                break
            } else {
                // 错误
                let err = String(cString: pcap_geterr(handle))
                print("[NetworkCapture] ⚠️ pcap_next_ex error: \(err)")
                self.stateLock.withLock { self._lastError = err }
                break
            }
        }
        
        pcap_close(handle)
        print("[NetworkCapture] 🛑 pcap loop stopped")
    }
    
    // MARK: - pcap 结构体定义 (桥接 C 结构)
    
    private struct ether_header {
        var ether_dhost: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        var ether_shost: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        var ether_type: UInt16
    }
    
    private struct ip_header {
        var version_ihl: UInt8
        var tos: UInt8
        var tot_len: UInt16
        var id: UInt16
        var frag_off: UInt16
        var ttl: UInt8
        var protocol_num: UInt8  // protocol 是 Swift 关键字
        var check: UInt16
        var saddr: UInt32
        var daddr: UInt32
    }
    
    private struct tcp_header {
        var source: UInt16
        var dest: UInt16
        var seq: UInt32
        var ack_seq: UInt32
        var doff_reserved: UInt8
        var flags: UInt8
        var window: UInt16
        var check: UInt16
        var urg_ptr: UInt16
    }
    
    // 以太网类型常量
    private let ETHERTYPE_IP: UInt16 = 0x0800
    private let IPPROTO_TCP: UInt8 = 6
    
    /// 解析 pcap 原始包 -> 以太网 -> IP -> TCP -> payload
    private func processPcapPacket(header: pcap_pkthdr, packet: UnsafePointer<UInt8>) {
        let packetLen = Int(header.caplen)
        guard packetLen >= MemoryLayout<ether_header>.size + MemoryLayout<ip_header>.size + MemoryLayout<tcp_header>.size else {
            return
        }
        
        // UnsafePointer<UInt8> -> UnsafeRawPointer 用于 bindMemory
        let rawPtr = UnsafeRawPointer(packet)
        
        // 1. 以太网头
        let ethPtr = rawPtr.bindMemory(to: ether_header.self, capacity: 1)
        let eth = ethPtr.pointee
        let ethType = UInt16(bigEndian: eth.ether_type)
        guard ethType == ETHERTYPE_IP else { return }
        
        // 2. IP 头
        let ipOffset = MemoryLayout<ether_header>.size
        let ipPtr = (rawPtr + ipOffset).bindMemory(to: ip_header.self, capacity: 1)
        let ip = ipPtr.pointee
        guard ip.protocol_num == IPPROTO_TCP else { return }
        
        let ihl = Int(ip.version_ihl & 0x0F) * 4
        let ipTotalLen = UInt16(bigEndian: ip.tot_len)
        guard packetLen >= ipOffset + ihl + MemoryLayout<tcp_header>.size else { return }
        
        // 3. TCP 头
        let tcpOffset = ipOffset + ihl
        let tcpPtr = (rawPtr + tcpOffset).bindMemory(to: tcp_header.self, capacity: 1)
        let tcp = tcpPtr.pointee
        let srcPort = UInt16(bigEndian: tcp.source)
        let dstPort = UInt16(bigEndian: tcp.dest)
        let doff = Int(tcp.doff_reserved >> 4) * 4
        
        // 4. TCP payload
        let payloadOffset = tcpOffset + doff
        let payloadLen = packetLen - payloadOffset
        guard payloadLen > 0 else { return }
        
        // 只处理目标端口 30031 (游戏服务端口)
        guard srcPort == kGameMovementPort || dstPort == kGameMovementPort else { return }
        
        // 提取 payload
        let payloadData = Data(bytes: rawPtr + payloadOffset, count: payloadLen)
        
        // 构造 FlowInfo
        let srcIP = ipToString(ip.saddr)
        let dstIP = ipToString(ip.daddr)
        let flow = PacketDecoder.FlowInfo(
            srcIP: srcIP,
            srcPort: srcPort,
            dstIP: dstIP,
            dstPort: dstPort,
            protocolName: "TCP"
        )
        
        // 更新 payload 统计 - 修复 Direction 枚举引用
        stateLock.withLock {
            _stats = Stats(
                packetCount: _stats.packetCount,
                payloadCount: _stats.payloadCount + 1,
                c2sCount: flow.direction == PacketDecoder.Direction.c2s ? _stats.c2sCount + 1 : _stats.c2sCount,
                s2cCount: flow.direction == PacketDecoder.Direction.s2c ? _stats.s2cCount + 1 : _stats.s2cCount,
                sampleCount: _stats.sampleCount,
                lastPacketAge: _stats.lastPacketAge,
                lastPayloadAge: 0,
                lastSampleAge: _stats.lastSampleAge,
                lastError: _stats.lastError
            )
        }
        
        // 调用核心解析管线
        handlePacket(payload: payloadData, timestamp: Date(), flow: flow)
    }
    
    private func ipToString(_ addr: UInt32) -> String {
        // 网络字节序转字符串
        return "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
    }
    
    // 移除 mock 循环，保留 processMockPacket 供单元测试用
    #if DEBUG
    private func startMockCaptureLoop() {
        print("[NetworkCapture] ⚠️ Running in MOCK mode - replace with real pcap")
        captureQueue.async { [weak self] in
            self?.mockCaptureLoop()
        }
    }
    
    private func mockCaptureLoop() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }
            self.processMockPacket()
        }
        RunLoop.current.add(timer, forMode: .common)
    }
    
    private func processMockPacket() {
        let pose = RawPose(
            x: 6200 + Double.random(in: -100...100),
            y: 5100 + Double.random(in: -100...100),
            z: 100,
            pitch: Double.random(in: -10...10),
            heading: Double.random(in: 0...360)
        )
        handleDecodedPose(pose)
    }
    #endif
    
    // MARK: 核心解析 - UE5 移动包解析
    
    /// 处理捕获到的原始数据包
    private func handlePacket(payload: Data, timestamp: Date, flow: PacketDecoder.FlowInfo) {
        guard payload.count >= 64 else { return } // 最小包长检查
        
        // 只处理 C2S (客户端->服务端) 移动包
        if flow.direction != PacketDecoder.Direction.c2s { return }
        
        // 解析候选
        let candidates = decoder.findCandidates(payload: payload)
        guard let candidate = decoder.selectBestCandidate(candidates, flow: flow) else { return }
        
        // 解析旋转 - 使用 withUnsafeBytes 获取 UnsafeRawBufferPointer
        payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = candidate.bitOffset + 32 // 跳过 client_time
            // 跳过加速度向量
            _ = decoder.readVector(buffer, offset: &offset, scale: 10)
            // 跳过位置向量
            _ = decoder.readVector(buffer, offset: &offset, scale: 100)
            // 读取旋转
            guard let (rotation, _) = decoder.readRotator(buffer, offset: &offset) else { return }
            
            // 构建完整位姿
            let pose = makePose(location: candidate.location, rotation: rotation)
            handleDecodedPose(pose)
        }
    }
    
    private func handleDecodedPose(_ pose: RawPose) {
        let now = Date()
        
        // 限流：30Hz
        if now.timeIntervalSince(lastSampleTime) < sampleInterval { return }
        lastSampleTime = now
        
        // 坐标变换
        let mapPoint = transformToMap(pose)
        
        // 更新状态
        stateLock.withLock {
            latestPose = pose
            latestPoseTime = now
            _stats = Stats(
                packetCount: _stats.packetCount,
                payloadCount: _stats.payloadCount + 1,
                c2sCount: _stats.c2sCount,
                s2cCount: _stats.s2cCount,
                sampleCount: _stats.sampleCount + 1,
                lastPacketAge: 0,
                lastPayloadAge: 0,
                lastSampleAge: 0,
                lastError: _stats.lastError
            )
        }
        
        // 回调 (主线程)
        let result = NetworkLocateResult(
            found: true,
            point: mapPoint,
            rawCoordinate: RawPoint(x: pose.x, y: pose.y, z: pose.z),
            score: 1.0,
            mode: "network",
            rawCoordinate3D: RawPoint(x: pose.x, y: pose.y, z: pose.z),
            cameraPitch: pose.pitch,
            cameraHeading: pose.heading
        )
        DispatchQueue.main.async { [weak self] in
            self?.onLocate?(result)
        }
    }
    
    /// 世界坐标 -> 地图像素坐标
    private func transformToMap(_ pose: RawPose) -> MapPoint? {
        let rawPoint = RawPoint(x: pose.x, y: pose.y, z: pose.z)
        let (u, v) = kCoordTransform.apply(rawPoint)
        guard u.isFinite, v.isFinite else { return nil }
        return MapPoint(x: Int(round(u)), y: Int(round(v)))
    }
    
    // MARK: 统计与清理
    
    private func startStatsTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.current.add(timer, forMode: .common)
        statsTimer = timer
    }
    
    private func updateStats() {
        let now = Date()
        stateLock.withLock {
            _stats = Stats(
                packetCount: _stats.packetCount,
                payloadCount: _stats.payloadCount,
                c2sCount: _stats.c2sCount,
                s2cCount: _stats.s2cCount,
                sampleCount: _stats.sampleCount,
                lastPacketAge: _stats.lastPacketAge >= 0 ? now.timeIntervalSince(lastSampleTime) : -1,
                lastPayloadAge: _stats.lastPayloadAge >= 0 ? now.timeIntervalSince(lastSampleTime) : -1,
                lastSampleAge: latestPoseTime.map { now.timeIntervalSince($0) } ?? -1,
                lastError: _stats.lastError
            )
        }
        if let cb = onStats {
            let currentStats = stats
            DispatchQueue.main.async { cb(currentStats) }
        }
    }
    
    private func teardownPacketCapture() {
        // 清理资源
        statsTimer?.invalidate()
        statsTimer = nil
        observer = nil
        packetFlow = nil
        provider = nil
    }
}

// MARK: - 包解码器

private final class PacketDecoder {
    private var lastOffset: Int? = nil
    private var lastTime: Double? = nil
    private var lastLocation: SIMD3<Double>? = nil
    private var lastCaptureTime: Date? = nil
    private var lastFlow: FlowInfo? = nil
    
    // 流切换状态
    private var pendingFlow: FlowInfo?
    private var pendingCandidate: Candidate?
    private var pendingSeen = 0
    private var pendingAt: Date? = nil
    
    struct FlowInfo: Equatable {
        let srcIP: String
        let srcPort: UInt16
        let dstIP: String
        let dstPort: UInt16
        let protocolName: String
        
        var direction: Direction {
            let srcLocal = FlowInfo.isLocalAddress(srcIP)
            let dstLocal = FlowInfo.isLocalAddress(dstIP)
            if srcLocal && !dstLocal { return .c2s }
            if dstLocal && !srcLocal { return .s2c }
            return .unknown
        }
        
        static func isLocalAddress(_ ip: String) -> Bool {
            // 简单判断：私有地址、回环、链路本地、保留地址
            let ip = ip.trimmingCharacters(in: .whitespaces)
            return ip.hasPrefix("10.") || ip.hasPrefix("192.168.") ||
                   ip.hasPrefix("172.16.") || ip.hasPrefix("172.17.") ||
                   ip.hasPrefix("172.18.") || ip.hasPrefix("172.19.") ||
                   ip.hasPrefix("172.20.") || ip.hasPrefix("172.21.") ||
                   ip.hasPrefix("172.22.") || ip.hasPrefix("172.23.") ||
                   ip.hasPrefix("172.24.") || ip.hasPrefix("172.25.") ||
                   ip.hasPrefix("172.26.") || ip.hasPrefix("172.27.") ||
                   ip.hasPrefix("172.28.") || ip.hasPrefix("172.29.") ||
                   ip.hasPrefix("172.30.") || ip.hasPrefix("172.31.") ||
                   ip.hasPrefix("127.") || ip.hasPrefix("169.254.") ||
                   ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") ||
                   ip.hasPrefix("::1") || ip.hasPrefix("fe80:")
        }
    }
    
    enum Direction { case c2s, s2c, unknown }
    
    // 查找所有候选
    func findCandidates(payload: Data) -> [Candidate] {
        var candidates: [Candidate] = []
        let maxOffset = min(512, payload.count * 8 - 60)
        
        payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for offset in stride(from: 190, to: maxOffset, by: 1) {
                // 读取 client_time (32-bit float, little-endian)
                let timeBits = readBits(buffer, offset: offset, count: 32)
                let clientTime = Float32(bitPattern: timeBits)
                guard clientTime.isFinite, clientTime >= 0, clientTime < 100_000 else { continue }
                
                var cursor = offset + 32
                
                // 加速度向量 (scale=10)
                guard let (acc, _, accBits, accScaled) = readVector(buffer, offset: &cursor, scale: 10) else { continue }
                guard accScaled, (1...16).contains(accBits) else { continue }
                guard abs(acc.x) < 50_000 && abs(acc.y) < 50_000 && abs(acc.z) < 50_000 else { continue }
                
                // 位置向量 (scale=100)
                guard let (loc, _, locBits, locScaled) = readVector(buffer, offset: &cursor, scale: 100) else { continue }
                guard locScaled, (20...32).contains(locBits) else { continue }
                guard max(abs(loc.x), abs(loc.y), abs(loc.z)) <= kMaxLocationAbs else { continue }
                
                // 验证后续旋转
                let locEnd = cursor + 7 + locBits * 3
                guard hasValidRotation(buffer, offset: locEnd) else { continue }
                
                candidates.append((
                    clientTime: Double(clientTime),
                    bitOffset: offset,
                    acceleration: acc,
                    location: loc
                ))
            }
        }
        return candidates
    }
    
    // 选择最佳候选
    func selectBestCandidate(_ candidates: [Candidate], flow: FlowInfo) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        
        // 流切换检测
        if let lastFlow = lastFlow, flow != lastFlow {
            return handleFlowSwitch(candidates, flow: flow)
        }
        
        // 首次或无历史
        if lastTime == nil || lastCaptureTime == nil {
            guard let best = candidates.max(by: { $0.clientTime < $1.clientTime }) else { return nil }
            updateDecoderState(best, flow: flow)
            return best
        }
        
        // 时间预测
        let gap = max(0, Date().timeIntervalSince(lastCaptureTime!))
        let expected = lastTime! + gap
        
        // 优先同 offset
        let aligned = candidates.filter { $0.bitOffset == lastOffset }
        let tracking = aligned.isEmpty ? candidates : aligned
        
        let best = tracking.min { a, b in
            trackingKey(a, expected: expected) < trackingKey(b, expected: expected)
        }
        
        guard let best = best else { return nil }
        
        // 时间误差检查
        let timeError = abs(best.clientTime - expected)
        if timeError > 1.0 {
            // 重新获取
            let plausible = candidates.filter {
                $0.clientTime >= 0.01 && $0.bitOffset <= 512 &&
                max(abs($0.acceleration.x), abs($0.acceleration.y), abs($0.acceleration.z)) <= 10_000 &&
                max(abs($0.location.x), abs($0.location.y), abs($0.location.z)) <= kMaxLocationAbs
            }
            guard let fresh = plausible.min(by: { distanceSq($0.location, lastLocation!) < distanceSq($1.location, lastLocation!) }) else {
                return nil
            }
            updateDecoderState(fresh, flow: flow)
            return fresh
        }
        
        updateDecoderState(best, flow: flow)
        return best
    }
    
    // 状态更新
    private func updateDecoderState(_ candidate: Candidate, flow: FlowInfo) {
        lastOffset = candidate.bitOffset
        lastTime = candidate.clientTime
        lastLocation = candidate.location
        lastCaptureTime = Date()
        lastFlow = flow
    }
    
    // 流切换处理
    private func handleFlowSwitch(_ candidates: [Candidate], flow: FlowInfo) -> Candidate? {
        // 简化：直接取最新
        guard let best = candidates.max(by: { $0.clientTime < $1.clientTime }) else { return nil }
        updateDecoderState(best, flow: flow)
        return best
    }
    
    // 跟踪评分
    private func trackingKey(_ item: Candidate, expected: Double) -> (Double, Double, Double) {
        let timeError = abs(item.clientTime - expected)
        guard let lastLoc = lastLocation else {
            return (timeError, timeError, 0)
        }
        let distSq = distanceSq(item.location, lastLoc)
        let spatialPenalty = min(distSq / (5000 * 5000), 100)
        return (timeError + spatialPenalty, timeError, distSq)
    }
    
    // 内部辅助
    fileprivate func readBits(_ buffer: UnsafeRawBufferPointer, offset: Int, count: Int) -> UInt32 {
        guard offset >= 0, count > 0, offset + count <= buffer.count * 8 else { return 0 }
        let firstByte = offset / 8
        let lastByte = (offset + count + 7) / 8
        let bytes = buffer.bindMemory(to: UInt8.self)
        var value: UInt32 = 0
        for i in firstByte..<lastByte {
            value = (value << 8) | UInt32(bytes[i])
        }
        return (value >> (offset % 8)) & ((1 << count) - 1)
    }
    
    fileprivate func readVector(_ buffer: UnsafeRawBufferPointer, offset: inout Int, scale: Int) -> (SIMD3<Double>, Int, Int, Bool)? {
        let header = readBits(buffer, offset: offset, count: 7)
        offset += 7
        let width = Int(header & 63)
        let scaled = (header >> 6) != 0
        guard width != 0, width <= 32 else { return nil }
        
        var values = SIMD3<Double>(0, 0, 0)
        let signBit = 1 << (width - 1)
        let modulus = 1 << width
        
        for i in 0..<3 {
            let value = readBits(buffer, offset: offset, count: width)
            offset += width
            var signed = Int32(value)
            if value & UInt32(signBit) != 0 {
                signed -= Int32(modulus)
            }
            values[i] = scaled ? Double(signed) / Double(scale) : Double(signed)
        }
        return (values, offset, width, scaled)
    }
    
    fileprivate func readRotator(_ buffer: UnsafeRawBufferPointer, offset: inout Int) -> (SIMD3<Double>, Int)? {
        var values = SIMD3<Double>(0, 0, 0)
        for i in 0..<3 {
            let present = readBits(buffer, offset: offset, count: 1)
            offset += 1
            if present != 0 {
                let compressed = readBits(buffer, offset: offset, count: 16)
                offset += 16
                var angle = Double(compressed) * 360.0 / 65536.0
                if angle > 180.0 { angle -= 360.0 }
                values[i] = angle
            }
        }
        return (values, offset)
    }
    
    fileprivate func hasValidRotation(_ buffer: UnsafeRawBufferPointer, offset: Int) -> Bool {
        var cursor = offset
        var flags: [Bool] = []
        for _ in 0..<3 {
            let present = readBits(buffer, offset: cursor, count: 1)
            flags.append(present != 0)
            cursor += 1 + (present != 0 ? 16 : 0)
        }
        guard let (rot, end) = readRotator(buffer, offset: &cursor) else { return false }
        guard end <= buffer.count * 8 else { return false }
        let valid = flags[1] && !flags[2] &&
                   abs(rot.x) <= 90.001 &&
                   rot.x.isFinite && abs(rot.x) <= kMaxRotationAbs &&
                   rot.y.isFinite && abs(rot.y) <= kMaxRotationAbs &&
                   rot.z.isFinite && abs(rot.z) <= kMaxRotationAbs
        return valid
    }
}

// MARK: - DriveState 集成扩展

extension DriveState {
    /// 启动网络定位
    public func startNetworkLocate() {
        networkLocator.start()
    }

    /// 停止网络定位
    public func stopNetworkLocate() {
        networkLocator.stop()
    }
}

/*
// MARK: - 需要添加到 DriveState 的新属性 (在 AuroraDriveApp.swift 中)

 在 DriveState 类中添加：
 
 let networkLocator = NetworkPacketCapture()
 
 var networkLocateX: Double = 0
 var networkLocateY: Double = 0
 var networkLocateScore: Double = 0
 var networkLocateMode: String = ""
 var networkLocatePitch: Double = 0
 var networkLocateHeading: Double = 0
 var networkLocateRawCoord: RawPoint = (0, 0, 0)
 
 在 init() 中添加：
 networkLocator.onLocate = { [weak self] result in
     self?.handleNetworkLocate(result)
 }
 networkLocator.onStatusChange = { [weak self] status in
     DispatchQueue.main.async {
         switch status {
         case .started:
             self?.networkLocateMode = "network"
         case .permissionDenied:
             self?.networkLocateMode = "permission_denied"
         case .error(let msg):
             self?.networkLocateMode = "error: \(msg)"
         default: break
         }
     }
 */