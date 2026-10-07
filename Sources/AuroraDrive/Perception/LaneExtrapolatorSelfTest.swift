// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LaneExtrapolatorSelfTest.swift — 车道线光流外推自检（--lane-extrapolator-selftest）
//
//  对齐 E2 最终版接口（Perception/LaneExtrapolator.swift）：
//   · `extrapolate(previous:flow:) -> MaskGrid`（直接返回掩码，非诊断对象）
//   · `extrapolate(previous:flow:trajectories:) -> MaskGrid`（A+B 档重载）
//   · `gridStride`（static var = 640/160 = 4）、`maxShiftCells`（static let = 24）
//   · `static translate` / `consistent` / `median` 纯函数
// ============================================================================

import Foundation

enum LaneExtrapolatorSelfTest {

    static func makeMask(_ w: Int, _ h: Int, fg: [(Int, Int)]) -> MaskGrid {
        var cells = [UInt8](repeating: 0, count: w * h)
        for (x, y) in fg where x >= 0 && x < w && y >= 0 && y < h {
            cells[y * w + x] = 1
        }
        return MaskGrid(width: w, height: h, cells: cells)
    }

    static func flow(_ dx: Double, _ dy: Double) -> OpticalFlowReading {
        OpticalFlowReading(dx: dx, dy: dy, divergence: 0, timestamp: Date())
    }

    static func run(ledger: SelfTestLedger) -> Int {
        print("═══ 车道线光流外推自检（--lane-extrapolator-selftest）═══")

        let W = 40, H = 40
        let ext = LaneExtrapolator()

        // ── S0 · 常量契约 ──
        ledger.section("S0 · 常量契约")
        ledger.equals("S0.1 gridStride = 4", LaneExtrapolator.gridStride, 4.0)
        ledger.equals("S0.2 maxShiftCells = 24", ext.maxShiftCells, 24.0)
        ledger.equals("S0.3 8px → 2 格", Int((8.0 / LaneExtrapolator.gridStride).rounded()), 2)

        // ── S1 · 静止无位移 ──
        ledger.section("S1 · 静止无位移")
        let base1 = makeMask(W, H, fg: (0..<H).map { (20, $0) })
        let r1 = ext.extrapolate(previous: base1, flow: flow(0, 0))
        ledger.check("S1.1 无位移返回原掩码", r1.mask == base1, "前景=\(r1.mask.positiveCount)")
        ledger.equals("S1.2 前景格数不变(40)", r1.mask.positiveCount, 40)

        // ── S2 · 纯平移 dx=8px → 右移 2 格 ──
        ledger.section("S2 · 纯平移（dx=8px → 右移 2 格）")
        let base2 = makeMask(W, H, fg: [(0, 0), (5, 15), (37, 10)])
        let r2 = ext.extrapolate(previous: base2, flow: flow(8.0, 0.0))
        ledger.equals("S2.1 前景格数不变(3)", r2.mask.positiveCount, 3)
        ledger.check("S2.2 原(0,0)→(2,0)", r2.mask.at(2, 0), "得到=\(r2.mask.at(2, 0))")
        ledger.check("S2.3 原(5,15)→(7,15)", r2.mask.at(7, 15), "得到=\(r2.mask.at(7, 15))")
        ledger.check("S2.4 原(37,10)→(39,10)", r2.mask.at(39, 10), "得到=\(r2.mask.at(39, 10))")
        ledger.check("S2.5 原位(0,0)腾空", !r2.mask.at(0, 0), "得到=\(r2.mask.at(0, 0))")
        ledger.check("S2.6 边界不回卷", !r2.mask.at(0, 15) && !r2.mask.at(1, 15), "左边界 empty")

        // ── S3 · 平移出界 ──
        ledger.section("S3 · 平移出界（fail-open 不回卷）")
        let base3 = makeMask(W, H, fg: [(0, 10), (39, 10)])
        let r3 = ext.extrapolate(previous: base3, flow: flow(9999.0, 0.0))
        ledger.check("S3.1 极端 dx 钳位到 24 格", r3.mask.at(24, 10), "得到=\(r3.mask.at(24, 10))")
        ledger.check("S3.2 原(39,10)出界丢弃", !r3.mask.at(23, 10), "不回卷")
        ledger.equals("S3.3 钳位后前景仅剩1格", r3.mask.positiveCount, 1)

        let small = makeMask(10, 10, fg: [(0, 0), (5, 5), (9, 9)])
        let oob = ext.extrapolate(previous: small, flow: flow(100.0, 0.0))
        ledger.equals("S3.4 出界全 empty", oob.mask.positiveCount, 0)
        ledger.equals("S3.5 出界尺寸保留", oob.mask.width, 10)

        // ── S4 · 无光流回退（LaneBridge）──
        ledger.section("S4 · 无光流回退（LaneBridge）")
        var bridge = LaneBridge()
        let m0 = makeMask(W, H, fg: [(20, 20)])
        let rTruth = bridge.updateLane(dt: 0.033, rawLaneMask: m0, flow: nil, detections: [])
        ledger.check("S4.1 真值帧直通+缓存", rTruth == m0, "前景=\(rTruth.positiveCount)")
        let fbNil = bridge.updateLane(dt: 0.033, rawLaneMask: .empty, flow: nil, detections: [])
        ledger.check("S4.2 flow=nil 回退快照", fbNil == m0, "前景=\(fbNil.positiveCount)")
        let fbNaN = bridge.updateLane(dt: 0.033, rawLaneMask: .empty, flow: flow(.nan, 0), detections: [])
        ledger.check("S4.3 dx=NaN 回退快照", fbNaN == m0, "前景=\(fbNaN.positiveCount)")
        let fbExt = bridge.updateLane(dt: 0.033, rawLaneMask: .empty, flow: flow(8.0, 0), detections: [])
        ledger.check("S4.4 有光流正常外推 (20,20)→(22,20)", fbExt.at(22, 20), "得到=\(fbExt.at(22, 20))")

        // ── S5 · 畸形掩码防线 ──
        ledger.section("S5 · 畸形掩码防线")
        let bad = MaskGrid(width: 10, height: 10, cells: [UInt8](repeating: 1, count: 5))
        let rBad = ext.extrapolate(previous: bad, flow: flow(8.0, 0.0))
        ledger.check("S5.1 畸形掩码不崩、返回 empty", rBad.mask == .empty && rBad.mask.width == 0,
                     "得到 width=\(rBad.mask.width) 期望=0")

        return ledger.summary("车道线光流外推自检")
    }
}