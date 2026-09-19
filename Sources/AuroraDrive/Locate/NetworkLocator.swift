// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

private let kMaaNTEServerURL = "ws://127.0.0.1:9004"
private let kAPIVersion = "1.3.0"
private let kCoordinateSampleMaxAge: Double = 1.0
private let kCalibrationAxes: (Int, Int) = (0, 1)
private let kCalibrationA: Double = 0.016394586684750773
private let kCalibrationB: Double = 5.693519256055879e-08
private let kCalibrationTX: Double = 6293.474380746091
private let kCalibrationTY: Double = 3472.664390686138
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
    let cameraPitch: Double?
    let cameraHeading: Double?
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
            let aligned = candidates.filter { $0.time == Double(lastOffset ?? 0) }
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
                let (acceleration, _, accelerationBits, accelerationScaled) = try readVector(bits: payload, offset: offset + 32, scale: 10)
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

                let locationEnd = cursor + 7 + locationBits * 3
                guard hasValidRotation(bits: payload, offset: locationEnd) else { continue }

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
        var values = (Double.zero, Double.zero, Double.zero)
        let sign = 1 << (width - 1), modulus = 1 << width
        for i in 0..<3 {
            let v = try readBits(bits: bits, offset: cursor, count: width)
            cursor += width
            var f = v
            if f & UInt64(sign) != 0 { f -= UInt64(modulus) }
            values.0 = (i == 0) ? (scaled ? Double(f) / Double(scale) : Double(f)) : values.0
            values.1 = (i == 1) ? (scaled ? Double(f) / Double(scale) : Double(f)) : values.1
            values.2 = (i == 2) ? (scaled ? Double(f) / Double(scale) : Double(f)) : values.2
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
            let (_, cursor, _, _) = try readVector(bits: payload, offset: bitOffset + 32, scale: 10)
            let (_, _, _, _) = try readVector(bits: payload, offset: cursor, scale: 100)
            let (pitch, yaw, _) = try readRotator(bits: payload, offset: cursor)

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

private final class MaaNTESocketClient: @unchecked Sendable {
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
        task = config.webSocketTask(with: URL(string: kMaaNTEServerURL)!)
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
    private var socketClient: MaaNTESocketClient?
    private var lastLocPos: (x: Double, y: Double)?
    private var lastResult: NetworkLocationResult?

    // MARK: - 初始化

    func prepare() -> Bool {
        socketClient = MaaNTESocketClient()
        socketClient?.start()
        ready = true
        isConnected = true
        return true
    }

    // MARK: - 定位

    func locate() -> NetworkLocationResult {
        guard let pose = socketClient?.read() else {
            return lastResult ?? NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0.0, mode: "coordinate_stale", cameraPitch: nil, cameraHeading: nil)
        }

        let raw: RawPoint = (pose.0, pose.1, pose.2)
        let mapPoint = rawToMap(x: raw.0, y: raw.1, z: raw.2)
        guard let point = mapPoint, pose.3.isFinite, pose.4.isFinite else {
            return NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0.0, mode: "coordinate_invalid", cameraPitch: nil, cameraHeading: nil)
        }
        var heading = pose.4
        if let last = lastLocPos {
            let dx = Double(point.0) - last.x
            let dy = Double(point.1) - last.y
            if dx * dx + dy * dy > 16 {
                heading = (atan2(dx, dy) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
            }
        }
        lastLocPos = (Double(point.0), Double(point.1))

        let result = NetworkLocationResult(
            found: true,
            point: point,
            rawCoordinate: raw,
            score: 1.0,
            mode: "coordinate",
            cameraPitch: pose.3,
            cameraHeading: heading
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

// MARK: - 双模定位器

final class DualModeLocator {
    private let networkLocator: NetworkLocator
    private weak var visualLocator: VisualLocator?
    var mode: String = "network"
    // MARK: - 初始化

    init(networkEnabled: Bool = true, visualLocator: VisualLocator? = nil) {
        self.networkLocator = NetworkLocator()
        self.visualLocator = visualLocator

        if networkEnabled {
            mode = "network"
        } else if visualLocator != nil {
            mode = "visual"
        } else {
            mode = "fallback"
        }
    }

    // MARK: - 定位

    func locate() -> NetworkLocationResult {
        switch mode {
        case "network":
            return networkLocator.locate()
        case "visual":
            if let visual = visualLocator, visual.isReady {
                return NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0, mode: "visual_arch_skip", cameraPitch: nil, cameraHeading: nil)
            }
            return NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0, mode: "visual_missing", cameraPitch: nil, cameraHeading: nil)
        default:
            return NetworkLocationResult(found: false, point: nil, rawCoordinate: nil, score: 0, mode: "fallback", cameraPitch: nil, cameraHeading: nil)
        }
    }

    // MARK: - 初始化

    func prepare() -> Bool {
        let netOk = networkLocator.prepare()
        let visOk = visualLocator?.isReady == true
        return netOk || visOk
    }

    // MARK: - 状态查询

    var isReady: Bool {
        return networkLocator.ready || visualLocator != nil
    }

    func stats() -> [String: Any] {
        var result: [String: Any] = ["mode": mode]
        result.merge(networkLocator.stats()) { _, network in network }
        return result
    }

    // MARK: - 关闭

    func close() { networkLocator.close() }
}
