// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

struct GuideLineOverlay: Codable, Equatable {
    /// 采集帧上的 ROI（归一化，左上原点）和其中的实际命中点（像素）。
    let roi: CGRect
    let roiSize: CGSize
    let minimap: [[CGPoint]]
    /// 已投影到 13056² 大地图的像素。历史路线每帧更新一次，画布只做视口变换。
    let currentMap: [[[CGPoint]]]
    let traveledMap: [[CGPoint]]
    let egoMap: CGPoint?
}

struct GuideLineSignal: Codable, Equatable {
    var observedAt: TimeInterval? = nil
    var headingDeg: Double? = nil
    var verdict: GuideLineReader.DirectionVerdict = .insufficient
    var offRoute = false
    var overlay: GuideLineOverlay? = nil
}

struct GuideLineMotion {
    // 15Hz 单帧很少走满 8m（432km/h）。保留 judgeDirection 的 8m 抗抖门槛，
    // 优先用相邻帧，再取 1 秒内最近的可判定位移（30km/h 一秒约 8.3m）。
    static let movementWindow: TimeInterval = 1
    // 约五个 15Hz 周期。丢流或积压的旧帧不能延续连续判定。
    static let maxFrameGap: TimeInterval = 0.35
    // 沿用离线判据的 50° 容差。连续 6 次约 0.4s@15Hz，过滤短暂跳变。
    private static let toleranceDeg = 50.0
    private static let framesToJudge = 6

    private var positions: [(world: CGPoint, at: TimeInterval)] = []
    /// 上次计票时的量化位置（评审 A 反例修复：同一格点不许重复计票）。
    /// 原地不动时即使方向判定重复返回 misaligned，streak 也不增长。
    private var lastStreakWorld: CGPoint?
    private static let mapPxPerCm = hypot(kCalibA, kCalibB)
    private(set) var misalignedStreak = 0
    var offRoute: Bool { misalignedStreak >= Self.framesToJudge }

    mutating func update(world: CGPoint?, at: TimeInterval,
                         deviation: GuideLineReader.Deviation?) -> GuideLineReader.DirectionVerdict {
        if let last = positions.last, at <= last.at || at - last.at > Self.maxFrameGap { reset() }
        guard let world else {
            reset()
            return .insufficient
        }
        positions.removeAll { at - $0.at > Self.movementWindow }
        var verdict = GuideLineReader.DirectionVerdict.insufficient
        if let deviation {
            for sample in positions.reversed() {
                let dx = world.x - sample.world.x, dy = world.y - sample.world.y
                // MapWiring 的线性部分把世界轴转到北朝上地图。归一化后仍是厘米，
                // 画面 +Y 朝南，judgeDirection 的第二个分量朝北。
                let scale = Self.mapPxPerCm
                verdict = GuideLineReader.judgeDirection(
                    movedWorldX: (kCalibA * dx + kCalibB * dy) / scale,
                    (kCalibB * dx - kCalibA * dy) / scale,
                    lineHeadingDeg: deviation.lineHeadingDeg,
                    confidence: deviation.headingConfidence,
                    farBearingDeg: deviation.farConfidence >= 0.35 ? deviation.farBearingDeg : nil,
                    farConfidence: deviation.farConfidence,
                    toleranceDeg: Self.toleranceDeg)
                if verdict != .insufficient { break }
            }
        }
        positions.append((world, at))
        if case .misaligned = verdict {
            // ⚠️ 2026-11-21 评审 A 反例修复：定位量化格宽 2.44m，一次格点跳变
            // 会被后续同位置的帧**重复计票 6 次** → 正常跟线被误判 offRoute。
            // 现在要求「位置真的变了」才计票；位置未变则保持 streak（不增不减）。
            let moved = lastStreakWorld.map {
                hypot(world.x - $0.x, world.y - $0.y) >= GuideLineReader.minMoveCm
            } ?? true
            if moved {
                misalignedStreak = min(misalignedStreak + 1, Self.framesToJudge)
                lastStreakWorld = world
            }
        } else {
            misalignedStreak = 0
            lastStreakWorld = nil
        }
        return verdict
    }

    mutating func reset() {
        positions.removeAll(keepingCapacity: true)
        misalignedStreak = 0
        lastStreakWorld = nil
    }
}

struct GuideLineMapHistory {
    private static let frameLimit = 3
    private static let traveledPointLimit = 200 - frameLimit * GuideLineReader.maxPolylinePoints
    private var current: [[[CGPoint]]] = []
    private var traveled: [[CGPoint]] = []
    private var canContinueTrail = false

    mutating func update(minimap: [[CGPoint]], size: CGSize, radius: Double?, mapSpan: Double?,
                         world: CGPoint?, contiguous: Bool) -> (current: [[[CGPoint]]], traveled: [[CGPoint]]) {
        if !contiguous { breakTrail() }
        guard let world, !minimap.isEmpty else {
            breakTrail()
            return ([], traveled)
        }
        let ego = CGPoint(x: DriveState.worldToMapPixelX(world.x, world.y),
                          y: DriveState.worldToMapPixelY(world.x, world.y))

        // 灰线记录实际定位点。只在有引导线时积累，断流或丢定位后从新笔画开始。
        if !canContinueTrail {
            if traveled.last?.count == 1 { traveled.removeLast() }
            traveled.append([ego])
            canContinueTrail = true
        } else if traveled.last?.last != ego {
            traveled[traveled.count - 1].append(ego)
        }
        while traveled.reduce(0, { $0 + $1.count }) > Self.traveledPointLimit {
            traveled[0].removeFirst()
            if traveled[0].count < 2 { traveled.removeFirst() }
        }
        guard let radius, radius > 0, let mapSpan, mapSpan > 0 else {
            current.removeAll(keepingCapacity: true)
            return ([], traveled)
        }
        // 1 大图 px = 1/hypot(A,B) cm = 60.9957 cm（0.609957m）。
        // 280px 桌面 ROI 实测约 448 大图 px，r=204px 对应约 199.1m。
        // 同帧地标拟合约 456 大图 px，给出约 202.7m；两种测量均有误差。
        // 实际逐次取实测的 mapSpan，世界半径 = (r / ROI边长) * mapSpan / hypot(A,B)。
        let mapPxPerCm = hypot(kCalibA, kCalibB)
        let worldRadiusX = radius / size.width * mapSpan / mapPxPerCm
        let worldRadiusY = radius / size.height * mapSpan / mapPxPerCm
        let projected = minimap.map { segment in
            segment.map { point in
                let east = (point.x - size.width / 2) / radius * worldRadiusX
                let south = (point.y - size.height / 2) / radius * worldRadiusY
                let worldX = world.x + (kCalibA * east - kCalibB * south) / mapPxPerCm
                let worldY = world.y + (kCalibB * east + kCalibA * south) / mapPxPerCm
                return CGPoint(x: DriveState.worldToMapPixelX(worldX, worldY),
                               y: DriveState.worldToMapPixelY(worldX, worldY))
            }
        }
        current.append(projected)
        if current.count > Self.frameLimit { current.removeFirst() }
        return (current, traveled)
    }

    mutating func breakTrail() {
        clearCurrent()
        canContinueTrail = false
    }

    mutating func clearCurrent() {
        current.removeAll(keepingCapacity: true)
    }
}
