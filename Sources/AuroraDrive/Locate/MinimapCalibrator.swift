// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MinimapCalibrator.swift — 小地图 ROI 自动标定（免手工标定）
// ----------------------------------------------------------------------------
//  思路移植自 game-map-web 的 _CircleCalibrator：视觉模式启动后的头几秒，
//  在整帧上跑 HoughCircles 圆形检测（MapLocBridge.detectCircle，C 桥实现），
//  多帧中位数收敛出小地图圆心/半径 → 换算归一化 ROI 写回 CaptureEngine。
//  标定期正好落在壳模式 RL 训练的 30 秒等待里（用户 2026-11-20 提议）。
//
//  已实测（2026-11-20，2940×1912 桌面截图 + 等比缩到 1280×832 两尺度）：
//    圆心检出 (304,333)/(136,148)，与手工标定 (302,330)/(131,144) 差 <8px；
//    检出参数换算 ROI 后定位 score=0.8452、坐标 (4948,6908)，
//    与手工标定基线 (4944,6900) 一致 —— 自动标定可替代手工。
// ============================================================================

import Foundation
import CoreGraphics

/// 小地图 ROI 运行时标定器：吃圆形检测结果，中位数收敛后产出圆参数。
/// 纯值类型，由 DriveState 主线程独占持有/调用，无需加锁。
struct MinimapCalibrator {

    /// 检出圆（整帧像素坐标，来自 MapLocBridge.detectCircle）。
    struct Detection {
        var cx: Double
        var cy: Double
        var r: Double
    }

    /// 收敛需要的检出数（gmw 同款 8；20fps 下 ≈0.4s，远短于 30s 等待期）。
    private static let framesToConverge = 8
    /// 离群剔除：偏离中位数超过该比例的检出丢弃；剩余不足半数视为场景可疑，重收。
    private static let outlierTolerance = 0.20
    /// 检出半径（外发光环）→ 裁剪边长换算系数（实测 204→280，两尺度一致）。
    static let cropSideFactor = 1.372

    private var detections: [Detection] = []

    /// 喂入一次检出。返回 nil = 尚未收敛（继续喂）；
    /// 返回 Detection = 已收敛（内点中位数），同时内部状态复位（可重新标定）。
    mutating func add(_ d: Detection) -> Detection? {
        detections.append(d)
        guard detections.count >= Self.framesToConverge else { return nil }
        let median = { (vals: [Double]) -> Double in
            let s = vals.sorted(); return s[s.count / 2]
        }
        let mcx = median(detections.map(\.cx))
        let mcy = median(detections.map(\.cy))
        let mr = median(detections.map(\.r))
        let inliers = detections.filter {
            abs($0.cx - mcx) <= Self.outlierTolerance * max(mcx, 1)
                && abs($0.cy - mcy) <= Self.outlierTolerance * max(mcy, 1)
                && abs($0.r - mr) <= Self.outlierTolerance * max(mr, 1)
        }
        detections.removeAll()
        guard inliers.count * 2 >= Self.framesToConverge else { return nil }
        return Detection(cx: median(inliers.map(\.cx)),
                          cy: median(inliers.map(\.cy)),
                          r: median(inliers.map(\.r)))
    }

    /// 收敛圆参数 + 整帧尺寸 → 归一化小地图 ROI（左上原点 y 向下，
    /// 与 CaptureEngine 的 ROI 坐标系一致）。越界/退化返回 nil（调用方继续标定）。
    static func normalizedROI(from d: Detection, frameW: Double, frameH: Double) -> CGRect? {
        guard frameW > 0, frameH > 0, d.r > 0 else { return nil }
        let side = d.r * cropSideFactor
        guard side < frameW, side < frameH else { return nil }
        let x = d.cx - side * 0.5, y = d.cy - side * 0.5
        guard x >= 0, y >= 0, x + side <= frameW, y + side <= frameH else { return nil }
        return CGRect(x: x / frameW, y: y / frameH,
                      width: side / frameW, height: side / frameH)
    }
}
