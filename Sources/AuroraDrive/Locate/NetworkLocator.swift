// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ═══════════════════════════════════════════════════════════════════════════
// 【出处标注 · 品牌澄清】2026-10-04
//   本文件的**位姿协议语义**参考/移植自上游开源项目 **MaaNTE**
//   （`agent/custom/action/Navi/` 系列，AGPL-3.0）。下文注释里出现的
//   「MaaNTE」一律是**上游项目名**，用于交代算法来源与对齐依据 ——
//   **它不是本产品的品牌，也不是本产品的名字**。
//   本产品品牌：`AuroraDrive`（见 `App/AuroraBrand.swift`）。
//   保留上游出处的理由：协议逆向结论必须可追溯到原始出处，抹掉出处等于
//   让后人无法复核「这个 30031 端口 / 这组标定常量到底怎么来的」。
//   故：出处保留，品牌层（标识符 / 用户可见字符串）不得出现上游名。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import Network

// ⚠️ 原名 `kMaaNTEServerURL`（品牌层，已按 2026-10-04 品牌清理改名）。
//    这里指向的是**本机回环上的位姿桥接 WebSocket**，不是任何外部服务；
//    名字改为描述"它是什么"，而不是"它从哪来"。
//    端口 9004 一字未改（改端口会直接打断定位链路）。
private let kLocalPoseBridgeURL = "ws://127.0.0.1:9004"
private let kAPIVersion = "1.3.0"
private let kCoordinateSampleMaxAge: Double = 1.0
private let kCalibrationAxes: (Int, Int) = (0, 1)
private let kCalibrationA: Double = 0.016394586684750773
private let kCalibrationB: Double = 5.693519256055879e-08
// 底图坐标系对齐 map-2026-08（MaaNTE-Map 13056×13056 扩图版，与 CoordinateCapture.kCalibTX/TY 同步）。
// 旧帧 map-2026-06 (11264): TX=6293.474380746091, TY=3472.664390686138。
// 扩图相对旧图整体平移 (+233, +1738)——MaaNTE-Map navi-coordinate-calibration.json
// 三个标定点 delta 完全一致，故 TX/TY 直接加偏移，A/B 不变。
// 标定点验证: raw(-134394.56, 199913.53) → map(4323, 8488) ✓（与 CoordinateCapture 同源）
private let kCalibrationTX: Double = 6526.474380746091
private let kCalibrationTY: Double = 5210.664390686138
private let kCalibrationError: Double = 0.22031967781665318
private let kNorth: (Double, Double, Double) = (-0.013752068070295848, -0.9999054358407049, 0.0)
private let kEast: (Double, Double, Double) = (0.9999054358407049, -0.01375206807029585, 0.0)
private let kMaxLocationAbs: Double = 2_000_000.0
private let kMaxRotationAbs: Double = 180.001

// MARK: - 数据类型

typealias RawPoint = (Double, Double, Double)
typealias RawPose = (Double, Double, Double, Double, Double)
typealias MapPoint = (Int, Int)
struct NetworkLocationResult {
    let found: Bool
    let point: MapPoint?
    let rawCoordinate: RawPoint?
    let score: Double
    let mode: String
    /// 相机俯仰（UE5 ControlRotation.pitch，度）。
    let cameraPitch: Double?
    /// 相机/视角朝向（UE5 ControlRotation 的罗盘投影，0-360 度，0=正北顺时针）。
    /// 2026-10-08 鉴定：pose.4 是 ControlRotation（玩家控制器/相机），**不是车体朝向**。
    /// 出处：docs/车头朝向鉴定-2026-10-08.md（6 条证据链）；
    /// 上游消费端自己命名 `camera_heading = pose[4]`（coordinate_position.py:246-247）。
    let cameraHeading: Double?
    /// 运动方向估计（atan2 位移方向的罗盘角，0-360 度）——比 cameraHeading 更接近"车头朝向"。
    /// 静止/抖动（位移²≤16）时保持上次的运动方向；从未移动过则为 nil。
    /// 真车头朝向目前没有数据源（ControlRotation 不是车体），此字段是最接近的近似，
    /// 如实命名不称"车头"，不编造。
    let motionHeading: Double?
}

struct CoordinateTransform {
    let axes: (Int, Int)
    let a: Double
    let b: Double
    let tx: Double
    let ty: Double
    let error: Double

    func apply(_ point: RawPoint) -> (Double, Double)? {
        let x = point.0
        let y = point.1
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

private let kCoordinateTransform = CoordinateTransform(
    axes: kCalibrationAxes,
    a: kCalibrationA,
    b: kCalibrationB,
    tx: kCalibrationTX,
    ty: kCalibrationTY,
    error: kCalibrationError
)

// MARK: - UE5 包解码器

private final class UE5PacketDecoder {
    private var flow: (String, Int, String, Int, String)?
    private var lastOffset: Int?
    private var lastCaptureTime: TimeInterval?
    private var lastClientTime: Double?
    private var lastLocation: RawPoint?
    private var pendingFlow: (String, Int, String, Int, String)?
    private var pendingCandidate: (Double, Int, RawPoint)?
    private var pendingSeen: Int = 0
    private var pendingAt: TimeInterval?

    func decode(payload: Data, timestamp: TimeInterval, flow: (String, Int, String, Int, String)) -> RawPose? {
        let candidates = findCandidates(payload: payload)
        guard !candidates.isEmpty else { return nil }

        if let currentFlow = self.flow, flow != currentFlow {
            guard let candidate = newFlowCandidate(candidates: candidates) else { return nil }
            guard let confirmed = confirmFlow(flow: flow, candidate: candidate, timestamp: timestamp) else { return nil }
            clearPending()
            self.flow = flow
            return extractPose(payload: payload, candidate: confirmed)
        } else if lastClientTime == nil || lastCaptureTime == nil {
            guard let candidate = newFlowCandidate(candidates: candidates) else { return nil }
            clearPending()
            self.flow = flow
            return extractPose(payload: payload, candidate: candidate)
        } else {
            let gap = max(0.0, timestamp - lastCaptureTime!)
            let expected = lastClientTime! + gap
            // 对齐 CoordinateCapture.decode：按位偏移对齐（offset 对 offset）。
            // 旧写法 $0.time == Double(lastOffset) 把「clientTime 浮点秒值」与
            // 「位偏移整数」做等值比较——量纲不同恒 false → aligned 恒空，
            // 跟踪分支永远退化为全量候选（移植时抄错字段）。
            let aligned = candidates.filter { $0.offset == lastOffset }
            let trackingCandidates = aligned.isEmpty ? candidates : aligned
            let selected = trackingCandidates.min(by: { trackingKey($0, expected: expected) < trackingKey($1, expected: expected) }) ?? trackingCandidates[0]
            let timeError = abs(selected.0 - expected)

            if timeError > 1.0 {
                let plausible = reacquireCandidates(candidates: trackingCandidates)
                guard !plausible.isEmpty else { return nil }
                let fresh = plausible.max(by: { $0.0 < $1.0 }) ?? plausible[0]
                clearPending()
                self.flow = flow
                return extractPose(payload: payload, candidate: fresh)
            } else {
                clearPending()
                return extractPose(payload: payload, candidate: selected)
            }
        }
    }

    private func findCandidates(payload: Data) -> [(time: Double, offset: Int, location: RawPoint)] {
        var output: [(Double, Int, RawPoint)] = []
        output.reserveCapacity(10)
        let searchEnd = min(512, payload.count * 8 - 60)

        for offset in 190..<searchEnd {
            do {
                let clientTime = try readFloat(bits: payload, offset: offset, count: 32)
                // 对齐 CoordinateCapture.findCandidates 的时间戳防线：NaN/Inf/负值/超界
                // 一律跳过（NaN 参与 trackingKey 比较恒 false，会污染候选选择）。
                guard clientTime.isFinite, clientTime >= 0, clientTime < 100_000 else { continue }
                let (acceleration, _, accelerationBits, accelerationScaled) = try readVector(bits: payload, offset: offset + 32, scale: 10)
                // 对齐 CoordinateCapture:332 的候选过滤：加速度必须为 scaled 向量
                // （全精度 unscaled 向量不满足移动同步包的编码约定）。
                guard accelerationScaled else { continue }
                let (location, cursor, locationBits, locationScaled) = try readVector(bits: payload, offset: offset + 32 + 32, scale: 100)

                guard !locationScaled else { continue }
                guard (1...16).contains(accelerationBits) else { continue }
                guard (20...32).contains(locationBits) else { continue }
                guard acceleration.0 < 50_000 && acceleration.0 > -50_000 &&
                      acceleration.1 < 50_000 && acceleration.1 > -50_000 &&
                      acceleration.2 < 50_000 && acceleration.2 > -50_000 else { continue }
                guard location.0 <= kMaxLocationAbs && location.0 >= -kMaxLocationAbs &&
                      location.1 <= kMaxLocationAbs && location.1 >= -kMaxLocationAbs &&
                      location.2 <= kMaxLocationAbs && location.2 >= -kMaxLocationAbs else { continue }
                guard (20...32).contains(locationBits) else { continue }

                // ★ 对齐 CoordinateCapture 20260913 关键修复：readVector 返回的 cursor
                // 已经是「位置向量结束后」的位偏移（= offset + 7位header + 3×width 值位），
                // 即 rotation 的起始位。旧代码 cursor + 7 + locationBits * 3 再多加一份
                // header+值位 → rotation 解析错位 → hasValidRotation 永远失败 → 0 候选。
                // MaaNTE 原版语义: location_end == readVector 返回的 endOffset。
                let rotationOffset = cursor
                guard hasValidRotation(bits: payload, offset: rotationOffset) else { continue }

                output.append((clientTime, offset, location))
            } catch {
                continue
            }
        }
        return output
    }

    private func readFloat(bits: Data, offset: Int, count: Int) throws -> Double {
        guard offset >= 0, count >= 0, offset + count <= bits.count * 8 else {
            throw DecodeError.outOfBounds
        }
        let slice = bits[offset/8..<(offset + count + 7)/8]
        var value: UInt32 = 0
        slice.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<slice.count { value = (value << 8) | UInt32(bytes[i]) }
        }
        return Double(bitPattern: UInt64(value))
    }

    private func readBits(bits: Data, offset: Int, count: Int) throws -> UInt64 {
        guard offset >= 0, count >= 0, offset + count <= bits.count * 8 else {
            throw DecodeError.outOfBounds
        }
        let slice = bits[offset/8..<(offset + count + 7)/8]
        var value: UInt64 = 0
        slice.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<slice.count { value = (value << 8) | UInt64(bytes[i]) }
        }
        return (value >> UInt64(offset & 7)) & ((1 << UInt64(count)) - 1)
    }

    private func readVector(bits: Data, offset: Int, scale: Int) throws -> (value: RawPoint, endOffset: Int, bits: Int, scaled: Bool) {
        let header = try readBits(bits: bits, offset: offset, count: 7)
        var cursor = offset + 7
        let width = Int(header & 0x3F)
        let scaled = (header >> 6) != 0
        guard width != 0 else { throw DecodeError.fullPrecisionUnsupported }
        // 对齐 CoordinateCapture.bits() 的 count 上限 63：width=64 时 modulus 溢出
        // UInt64，符号扩展的 &- 会失去意义（header 只有 6 位，width 天然 ≤63，此为防御）。
        guard width <= 63 else { throw DecodeError.outOfBounds }
        var values = (Double.zero, Double.zero, Double.zero)
        let sign = UInt64(1) << (width - 1), modulus = UInt64(1) << UInt64(width)
        for i in 0..<3 {
            let v = try readBits(bits: bits, offset: cursor, count: width)
            cursor += width
            // 对齐 CoordinateCapture.ue5Vector 的符号扩展修复：符号扩展必须走
            // Int64(bitPattern:)——UInt64 的 &- 会下溢回绕成巨大正数（Python 大整数
            // 无此问题），导致所有负坐标 > kMaxLocationAbs 被淘汰 → 永远 0 候选。
            let sv: Int64 = (v & sign) != 0 ? Int64(bitPattern: v &- modulus) : Int64(v)
            let f = Double(sv)
            values.0 = (i == 0) ? (scaled ? f / Double(scale) : f) : values.0
            values.1 = (i == 1) ? (scaled ? f / Double(scale) : f) : values.1
            values.2 = (i == 2) ? (scaled ? f / Double(scale) : f) : values.2
        }
        return (values, cursor, width, scaled)
    }

    private func hasValidRotation(bits: Data, offset: Int) -> Bool {
        do {
            var cursor = offset, flags = (false, false, false)
            for i in 0..<3 {
                let p = try readBits(bits: bits, offset: cursor, count: 1) != 0
                cursor += 1 + (p ? 16 : 0)
                flags.0 = (i == 0) ? p : flags.0
                flags.1 = (i == 1) ? p : flags.1
                flags.2 = (i == 2) ? p : flags.2
            }
            guard flags.1, !flags.2 else { return false }
            let pitch = try readBits(bits: bits, offset: offset + 1, count: 16)
            let yaw = try readBits(bits: bits, offset: offset + 18, count: 16)
            return abs(Double(pitch) * 360.0 / 65536.0) <= 90.001 &&
                   abs(Double(yaw) * 360.0 / 65536.0) <= kMaxRotationAbs
        } catch { return false }
    }

    private func extractPose(payload: Data, candidate: (Double, Int, RawPoint)) -> RawPose? {
        let (_, bitOffset, _) = candidate
        do {
            // 对齐 CoordinateCapture.decode 的解码链：加速度 → 位置 → 旋转，
            // 每一步用上一步返回的结束位。旧代码把位置向量的 endOffset 丢弃（_），
            // readRotator 却从位置的起始 cursor 读——错位一整个位置向量宽度，
            // 与本类 hasValidRotation（从位置结束位起算）自相矛盾。
            let (_, cursor1, _, _) = try readVector(bits: payload, offset: bitOffset + 32, scale: 10)
            let (_, cursor2, _, _) = try readVector(bits: payload, offset: cursor1, scale: 100)
            let (pitch, yaw, _) = try readRotator(bits: payload, offset: cursor2)

            let location = candidate.2
            let heading = computeHeading(location: location, pitch: pitch, yaw: yaw)

            self.lastClientTime = candidate.0
            self.lastOffset = bitOffset
            self.lastCaptureTime = Date().timeIntervalSince1970
            self.lastLocation = location

            return (location.0, location.1, location.2, pitch, heading)
        } catch {
            return nil
        }
    }

    private func readRotator(bits: Data, offset: Int) throws -> (Double, Double, Double) {
        var cursor = offset, result = (Double.zero, Double.zero, Double.zero)
        for i in 0..<3 {
            let p = try readBits(bits: bits, offset: cursor, count: 1)
            cursor += 1
            let c = p != 0 ? try readBits(bits: bits, offset: cursor, count: 16) : 0
            if p != 0 { cursor += 16 }
            var a = Double(c) * 360.0 / 65536.0
            if a > 180.0 { a -= 360.0 }
            result.0 = (i == 0) ? a : result.0
            result.1 = (i == 1) ? a : result.1
            result.2 = (i == 2) ? a : result.2
        }
        return result
    }

    private func computeHeading(location: RawPoint, pitch: Double, yaw: Double) -> Double {
        let pitchRad = pitch * .pi / 180.0
        let yawRad = yaw * .pi / 180.0

        let viewDirX = cos(pitchRad) * cos(yawRad)
        let viewDirY = cos(pitchRad) * sin(yawRad)
        let viewDirZ = sin(pitchRad)

        let northDot = viewDirX * kNorth.0 + viewDirY * kNorth.1 + viewDirZ * kNorth.2
        let eastDot = viewDirX * kEast.0 + viewDirY * kEast.1 + viewDirZ * kEast.2

        let heading = (atan2(eastDot, northDot) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
        return heading
    }

    private func trackingKey(_ candidate: (Double, Int, RawPoint), expected: Double) -> (Double, Double, Double) {
        let timeError = abs(candidate.0 - expected)
        if let lastLocation = lastLocation {
            let distSq = distanceSq(left: candidate.2, right: lastLocation)
            let spatialPenalty = min(distSq / (5000.0 * 5000.0), 100.0)
            return (timeError + spatialPenalty, timeError, distSq)
        }
        return (timeError, timeError, 0.0)
    }

    private func newFlowCandidate(candidates: [(Double, Int, RawPoint)]) -> (Double, Int, RawPoint)? {
        let valid = candidates.filter {
            $0.0 >= 0.01 &&
            abs($0.2.0) <= kMaxLocationAbs &&
            abs($0.2.1) <= kMaxLocationAbs &&
            abs($0.2.2) <= kMaxLocationAbs
        }
        return valid.max(by: { $0.0 < $1.0 })
    }

    private func reacquireCandidates(candidates: [(Double, Int, RawPoint)]) -> [(Double, Int, RawPoint)] {
        return candidates.filter {
            $0.0 >= 0.01 &&
            abs($0.2.0) <= kMaxLocationAbs &&
            abs($0.2.1) <= kMaxLocationAbs &&
            abs($0.2.2) <= kMaxLocationAbs
        }
    }

    private func confirmFlow(flow: (String, Int, String, Int, String), candidate: (Double, Int, RawPoint), timestamp: TimeInterval) -> (Double, Int, RawPoint)? {
        if pendingFlow.map({ $0 == flow }) == false {
            pendingFlow = flow
            pendingCandidate = candidate
            pendingSeen = 1
            pendingAt = timestamp
            return nil
        }

        let previous = pendingCandidate!
        let gap = max(0.0, timestamp - (pendingAt ?? timestamp))
        let timeDelta = candidate.0 - previous.0
        let timeOk = timeDelta >= 0.001 && abs(timeDelta - gap) <= 0.5
        let offsetOk = candidate.1 == previous.1
        let stepOk = distanceSq(left: previous.2, right: candidate.2) <= 6_400_000_000.0

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

    private func distanceSq(left: RawPoint, right: RawPoint) -> Double {
        return (left.0 - right.0) * (left.0 - right.0) +
               (left.1 - right.1) * (left.1 - right.1) +
               (left.2 - right.2) * (left.2 - right.2)
    }
}

enum DecodeError: Error {
    case outOfBounds
    case fullPrecisionUnsupported
}

// ⚠️ 原名 `MaaNTESocketClient`（品牌层，已按 2026-10-04 品牌清理改名）。
//    职责是"连本机位姿桥接 + 解 UE5 位流"，与上游项目名无关。
private final class LocalPoseSocketClient: @unchecked Sendable {
    private let decoder = UE5PacketDecoder()
    private var sampleLock: os_unfair_lock_s = os_unfair_lock_s()
    private var sample: RawPose?
    private var sampleAt: TimeInterval = 0
    private var packetCount: Int = 0
    private var payloadCount: Int = 0
    private var sampleCount: Int = 0
    private var lastPacketWall: TimeInterval = 0
    private var lastPayloadWall: TimeInterval = 0
    private var lastSampleWall: TimeInterval = 0
    private var isConnected = false

    func start() {
        #if os(macOS)
        guard #available(macOS 13.0, *) else { return }
        startWithURLSession()
        #endif
    }

    #if os(macOS)
    @available(macOS 13.0, *)
    private func startWithURLSession() {
        let config = URLSession(configuration: URLSessionConfiguration.default)
        task = config.webSocketTask(with: URL(string: kLocalPoseBridgeURL)!)
        task?.resume()
        isConnected = true
        readLoop(task: task!)
    }

    @available(macOS 13.0, *)
    private func readLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.readLoop(task: task)
            case .failure(let error):
                print("[NetworkLocator] WebSocket 错误: \(error)")
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
                    self.start()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .data(let data) = message else { return }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = json?["version"] as? String,
                  version == kAPIVersion,
                  let mode = json?["mode"] as? String,
                  mode == "coordinate" else {
                return
            }

            guard let x = json?["x"] as? Double,
                  let y = json?["y"] as? Double,
                  let z = json?["z"] as? Double,
                  let pitch = json?["pitch"] as? Double,
                  let heading = json?["heading"] as? Double else {
                return
            }

            let pose: RawPose = (x, y, z, pitch, heading)

            os_unfair_lock_lock(&sampleLock)
            sample = pose
            sampleAt = Date().timeIntervalSince1970
            packetCount += 1
            payloadCount += 1
            sampleCount += 1
            lastPacketWall = Date().timeIntervalSince1970
            lastPayloadWall = lastPacketWall
            lastSampleWall = lastPacketWall
            os_unfair_lock_unlock(&sampleLock)

        } catch {
            print("[NetworkLocator] JSON 解析失败: \(error)")
        }
    }

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    #endif

    func read(maxAge: Double = kCoordinateSampleMaxAge) -> RawPose? {
        os_unfair_lock_lock(&sampleLock)
        let now = Date().timeIntervalSince1970
        guard let sample = sample else {
            os_unfair_lock_unlock(&sampleLock)
            return nil
        }
        guard now - lastSampleWall <= maxAge else {
            os_unfair_lock_unlock(&sampleLock)
            return nil
        }
        os_unfair_lock_unlock(&sampleLock)
        return sample
    }

    func stats() -> [String: Any] {
        os_unfair_lock_lock(&sampleLock)
        let now = Date().timeIntervalSince1970
        let pktCount = packetCount
        let payloadCount = payloadCount
        let sampleCount = sampleCount
        let lastPacketWall = lastPacketWall
        let lastPayloadWall = lastPayloadWall
        let lastSampleWall = lastSampleWall
        os_unfair_lock_unlock(&sampleLock)

        return [
            "packet_count": pktCount,
            "payload_count": payloadCount,
            "sample_count": sampleCount,
            "packet_age": now - lastPacketWall,
            "payload_age": now - lastPayloadWall,
            "sample_age": now - lastSampleWall,
        ] as [String: Any]
    }

    func close() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            task?.cancel()
            session?.invalidateAndCancel()
        }
        #endif
        isConnected = false
    }
}

// MARK: - 网络定位器

final class NetworkLocator {
    var ready: Bool = false
    private var isConnected = false
    private var socketClient: LocalPoseSocketClient?
    private var lastLocPos: (x: Double, y: Double)?
    /// 上次算出的运动方向（罗盘角，0-360 度）。位移不足（≤4px）时复用它，
    /// 避免站立抖动把方向打成噪声。2026-10-08 新增（R2 车头朝向任务）。
    private var lastMotionHeading: Double?
    private var lastResult: NetworkLocationResult?

    // MARK: - 初始化

    func prepare() -> Bool {
        socketClient = LocalPoseSocketClient()
        socketClient?.start()
        ready = true
        isConnected = true
        return true
    }

    // MARK: - 定位

    func locate() -> NetworkLocationResult {
        guard let pose = socketClient?.read() else {
            return lastResult ?? NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0.0, mode: "coordinate_stale", cameraPitch: nil, cameraHeading: nil, motionHeading: nil)
        }

        let raw: RawPoint = (pose.0, pose.1, pose.2)
        let mapPoint = rawToMap(x: raw.0, y: raw.1, z: raw.2)
        guard let point = mapPoint, pose.3.isFinite, pose.4.isFinite else {
            return NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0.0, mode: "coordinate_invalid", cameraPitch: nil, cameraHeading: nil, motionHeading: nil)
        }

        // ─────────────────────────────────────────────────────────────────
        // 【字段语义 · 2026-10-08 鉴定】（出处：docs/车头朝向鉴定-2026-10-08.md）
        //
        //   pose.4 = **相机朝向**（UE5 ControlRotation 的罗盘投影），不是车体朝向。
        //     · 来源：MaaNTE 上游逐字注释 "compressed **control** rotation"
        //       （nte_coordinate_api.py:1-7/:96 —— UE5 ControlRotation =
        //       APawn::GetControlRotation() = 玩家控制器/相机旋转）；
        //     · 上游消费端自己命名 `camera_heading = pose[4]`
        //       （coordinate_position.py:246-247）；
        //     · 仓库既有逆向文档：「计算 compass heading（基于相机朝向）」
        //       （docs/文档库/Maa深度/MAA深度文档_架构篇.md:337）。
        //     · 第三视角下相机挂在车后吊臂（SpringArm）上：转视角而车不动时，
        //       变的是相机不是车 —— 故 pose.4 会"跟着视角走"（用户实测症状）。
        //
        //   两个字段并存，各说各话：
        //     · cameraHeading = pose.4 的罗盘投影（相机/视角朝向），
        //       空闲（位移小）时即 pose.4 原值，移动时仍以相机值为准；
        //     · motionHeading = **运动方向估计**（atan2 位移方向），
        //       车头不会瞬变，这是比 pose.4 更接近"车头朝向"的量。
        //       真车头朝向目前**没有数据源**（ControlRotation 不是车体），
        //       只能靠运动方向近似或另找载具包 —— 如实标注，不编造。
        //
        //   【单位】两字段均为**罗盘方位角 0-360 度**（0=正北，顺时针增加）。
        //   模型契约需要弧度 [-π,π]，**换算必须在使用侧做，不要在这里混**。
        //   另注意（w8 实测）：pose.4 不是 UE5 yaw 本身，而是
        //   `yaw + 90.787960°` 的罗盘投影（90.788° 是 kNorth/kEast 基向量
        //   的地图倾角，纯平移可逆，非 bug）——做训练特征时不能当 yaw 用。
        // ─────────────────────────────────────────────────────────────────
        var cameraHeading = pose.4

        // 运动方向估计：位移超过阈值（4px²）才更新 —— 站立/抖动时保持上次方向。
        //
        // ★ 2026-10-08 镜像 bug 修复：地图像素系 **y 向下**，真北 = −Δy。
        //   旧代码 `atan2(dx, dy)` 第二参取了 +dy → 关于东西轴镜像
        //   （8 方向里 6 个是反的：正北↔正南对调、东北↔东南对调，
        //    正东/正西是镜面不动点恰好不错 —— 用户"朝东西走看着对、
        //    一拐南北就反"的实测症状即由此来）。
        //   权威公式：`MissionConsole.swift:3007`（2026-09-30 已修复并实测）
        //     `atan2(Δx, −Δy)`
        var motionHeading: Double? = lastMotionHeading
        if let last = lastLocPos {
            let dx = Double(point.0) - last.x
            let dy = Double(point.1) - last.y
            if dx * dx + dy * dy > 16 {
                motionHeading = (atan2(dx, -dy) * 180.0 / .pi + 360.0)
                    .truncatingRemainder(dividingBy: 360.0)
            }
        }
        lastLocPos = (Double(point.0), Double(point.1))
        if let mh = motionHeading { lastMotionHeading = mh }

        let result = NetworkLocationResult(
            found: true,
            point: point,
            rawCoordinate: raw,
            score: 1.0,
            mode: "coordinate",
            cameraPitch: pose.3,
            cameraHeading: cameraHeading,
            motionHeading: motionHeading
        )

        lastResult = result
        return result
    }

    // MARK: - 坐标转换

    func rawToMap(x: Double, y: Double, z: Double? = nil) -> MapPoint? {
        guard 2 != kCalibrationAxes.0 && 2 != kCalibrationAxes.1 || z != nil else {
            return nil
        }

        let point = (x, y, z ?? 0.0)
        guard let (mapX, mapY) = kCoordinateTransform.apply(point) else {
            return nil
        }

        guard mapX.isFinite && mapY.isFinite else { return nil }
        return (Int(round(mapX)), Int(round(mapY)))
    }

    func mapToRaw(x: Double, y: Double) -> (Double, Double)? {
        guard let raw = kCoordinateTransform.invert((x, y)) else { return nil }
        guard raw.0.isFinite && raw.1.isFinite else { return nil }
        return raw
    }

    // MARK: - 状态查询

    func stats() -> [String: Any] {
        return socketClient?.stats() ?? [:]
    }

    func close() {
        socketClient?.close()
        socketClient = nil
        isConnected = false
    }
}
