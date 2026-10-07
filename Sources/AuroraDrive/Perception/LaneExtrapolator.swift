// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LaneExtrapolator.swift —— 中间帧车道线外推器（E2 核心实现）
//
//  【它解决什么问题】
//    yolopx / A-YOLOM 的 ll 头（车道线掩码）是低频真值：单次推理 60~183ms
//    （OpticalFlowBridge.swift:6-11 的"15Hz 补成 30Hz"背景；YolopxEngine.swift:237-247
//    的 PerceptionMode.needsOpticalFlow 说明），跑不满 30Hz。主循环 30Hz tick 里，
//    两帧真值之间车道线不能断档 —— 断了决策层（LaneFallback）就是闭着眼依缓存判向。
//
//    已有方案只外推了**检测框**（MotionPredictor.swift），车道线掩码始终是
//    "最近一帧真值原样冻结"。本类补齐另外半条链路：
//
//        上一帧 ll 快照 ──(A 档：整体平移)──┐
//        光流 dx/dy ────────────────────────┼─→ 本帧 30Hz 中间车道线 MaskGrid
//        检测框轨迹 ──(B 档：一致性辅助)────┘
//
//  【用户需求（已确认）】
//    车道线是低频真值（被 P1 降频），要在中间帧用「检测框 + 光流」推导出 30Hz
//    的中间车道线。检测框是**辅助不是替代**（用户原话：结合检测框和之前车道线
//    和光流推导）。
//
//  【核心算法 —— 只平移，不重画、不重训、不回传稠密光流】
//    ── A 档（零牺牲，先做满）：整体平移 ──
//      OpticalFlowBridge 给的是**全局中位流摘要**（仅 dx/dy/divergence 三个数，
//      OpticalFlowBridge.swift:45-64，没有稠密场）。把上一帧 ll 按 (dx,dy) 整体
//      平移，是"只有全局位移"输入下最直接、唯一可做的外推。README 明说稠密
//      光流 3.3MB 搬运太贵，故**不回传稠密场**，只用摘要。
//
//    ── B 档（可选，辅助约束）：检测框轨迹 ──
//      若若干检测框被 MotionPredictor 锁定为"行驶中的车"，其轨迹方向应近似车道
//      走向。B 档**不重画车道线**（会凭空编造），只做两件保守的事：
//        ① 用轨迹位移中位数与光流位移做一致性校验（夹角 + 量级）；
//        ② 一致时对平移量做一次加权加固。
//      不一致时仍只用光流平移（fail-open：拒绝用矛盾的证据改结果）。这样"检测框"
//      参与了推导，但不会替代 ll 真值本身。
//
//  【坐标系对齐 —— 本文件最重要的换算事实】
//    · MaskGrid 是 letterbox 640 坐标系按 4×4 多数表决下采样到 160×160
//      （YolopxEngine.swift:40-44、:262-263；extractMask 实现在 :1266-1341）。
//      即 **1 格 = 4 个 640 坐标像素**，因子 = inputSize/maskGridSize = 640/160 = 4
//      （YolopxEngine.swift:969-970 的 `stride = size / grid`）。
//    · OpticalFlowReading.dx/dy 也是 640 坐标系像素（workingSize=640，
//      OpticalFlowBridge.swift:85-91；dx 正=内容右移 :48 / dy 正=内容下移 :52）。
//    · 两者同源（都吃 letterbox 640 直通帧，非等比拉伸，CaptureEngine.swift:349），
//      故**像素位移直接 ÷ 4 即格子位移**，无需缩放/letterbox 反投影。
//
//  【符号约定】
//    dx > 0 = 画面内容向右移动（自车向左）。掩码是"画面内容"，故 dx>0 时上帧
//    车道线格子列号**加大**（向右搬）。dy>0 = 内容向下 = 自车前进时地面纹理向下
//    扩散（OpticalFlowBridge.swift:52），上帧车道线格子行号**加大**。
//
//  【fail-open 纪律（与 LaneFallback / MotionPredictor 同风格）】
//    ① 无可用上一帧 / 畸形掩码（width·height ≤ 0 或 cells 短于 w*h）→ rejected，
//       mask 返回 .empty，绝不造车道线。畸形守卫与 MaskGrid.at 同源
//       （YolopxEngine.swift:53-64 的 SIGTRAP 教训：畸形值流入 LaneFallback 会崩，
//       本类把防线扩展到"写"侧）。
//    ② 光流 nil（compute 失败，OpticalFlowBridge.swift:190-255 返回 nil）或
//       dx/dy 非有限（NaN/±inf）→ flowUnavailable 静止回退：mask 返回上一帧原样。
//       **不能**把 nil/NaN 当"车辆静止的可靠结论"，也不能让 NaN 流入 Int() 触发
//       运行时 trap（LaneExtrapolatorSelfTest.swift:81 的 S4.3 明确要求不崩）。
//    ③ 位移硬限幅：格子位移不许超过 maxShiftCells(24)，防光流短暂发散把掩码甩出画面。
//    ④ 移出格子的部分置 empty（0 = 背景，YolopxEngine.swift:48），不回卷 wrap。
//
//  【可测性 / 线程模型】
//    本类**无状态**：所有方法纯函数式，只读 static 常量与实例可调参数，不持有
//    跨帧可变状态，不 import Observation / CoreML，天然可单测、可在任意线程调用。
//    "上一帧快照"的缓存与 fail-open 回退由 E5 `LaneBridge` 承担（LaneBridge.swift:60-147）。
// ============================================================================

import Foundation

// MARK: - 检测框轨迹（B 档辅助输入）

/// 一条"行驶中车辆"的运动轨迹，作为车道走向的辅助约束。
///
/// 语义：`shiftX/shiftY` 是该车在本帧相对上一帧的**画面像素位移**（letterbox 640
/// 检视，正 = 右 / 下）。当它被 MotionPredictor 判为"速度已确认"的行驶目标时，
/// 其位移方向近似道路走向 —— 这正是 B 档想借用的那一丁点信息。
///
/// 调用方（tick）可从 `MotionPredictor.predict(dtSeconds:)` 返回的 `TrackedTarget`
/// （MotionPredictor.swift:49-85）派生：
///   · `centerX/centerY` = `detection.x / detection.y`（归一化 [0,1]）
///   · `shiftX` = `velocityX * dt * 640`（velocity 为归一化/秒，见 MotionPredictor.swift:319-322）
///   · `shiftY` = `velocityY * dt * 640`
struct DetectedTrajectory: Equatable {

    /// 车辆中心（归一化 [0,1]，与 Detection 契约一致）
    let centerX: Double
    let centerY: Double

    /// 本帧画面位移（像素，letterbox 640）。正 = 右 / 下。
    let shiftX: Double
    let shiftY: Double
}

// MARK: - 外推结果质量

/// 一次外推的"证据等级"，供下游决定如何采信。
enum LaneExtrapolationQuality: Equatable {
    /// 仅用光流整体平移（A 档）
    case translated
    /// 检测框轨迹与光流一致，平移量做过加权加固（A+B 档）
    case detConstrained
    /// 光流不可用（nil / NaN / ±inf）→ 静止回退（mask 为上一帧原样）
    case flowUnavailable
    /// 拒绝产出：无可用上一帧 / 畸形掩码（mask 为 .empty）
    case rejected
}

// MARK: - 外推输出

/// 一帧外推出的中间车道线及其诊断信息。
struct LaneFlowExtrapolation: Equatable {

    /// 本帧车道线掩码（与上一帧真值同尺寸的 MaskGrid）
    let mask: MaskGrid

    /// 实际施加的整体平移量（**格子**坐标，非像素）。正值 = 向右/向下搬。
    /// 这是**钳位后、取整前**的格子数（如 dx=9999px → 24.0），
    /// 平移实算由 translate() 内部再做四舍五入取整。
    let shiftCellsX: Double
    let shiftCellsY: Double

    /// 光流置信度 [0,1]。flowUnavailable / rejected 时恒为 0。
    let flowConfidence: Double

    /// 参与 B 档校验的轨迹数（0 = 未用轨迹，纯 A 档）
    let usedTrajectoryCount: Int

    /// 本次外推的证据等级
    let quality: LaneExtrapolationQuality

    /// 是否可信（rejected 时为 false）
    var isUsable: Bool { quality != .rejected }
}

// MARK: - 外推器

/// 车道线中间帧外推器（无状态，纯函数式核心）。
///
/// 用法（30Hz tick 内；E5 `LaneBridge` 通过适配闭包抽 `.mask` 接入）：
/// ```swift
/// let ext = LaneExtrapolator()
/// let r = ext.extrapolate(previous: lastLaneMask, flow: flowReading)   // A 档
/// let lane = r.mask   // 本帧 30Hz 中间车道线
/// // A+B 档（带检测框轨迹约束）
/// let r2 = ext.extrapolate(previous: lastLaneMask, flow: flowReading,
///                          trajectories: movingCarTrajectories)
/// ```
final class LaneExtrapolator {

    // MARK: - 常量

    /// 掩码下采样因子：一个 MaskGrid 格子 = 多少个 letterbox 640 坐标像素。
    ///
    /// 单一来源派生（与 EgoMotionModel.swift:167 的 flowSize 同款"从既有常量派生"
    /// 纪律，避免静默错算）：`inputSize / maskGridSize = 640 / 160 = 4`
    /// （YolopxEngine.swift:260-263）。
    static let gridStride: Double =
        Double(YolopxEngine.inputSize) / Double(YolopxEngine.maskGridSize)

    /// 单帧平移的格子数硬上限（单方向）。
    ///
    /// 依据：EgoMotionModel.swift:238 依赖的 `AuroraFlags.egoMaxFlowPx` 默认 80px
    /// 判"转场/整屏闪烁"，折成格子 = 80 / 4 = 20 格，再留 4 格余量 → 24。
    /// 与 E1 蓝图口径一致（"clamp 24 格 = 视野 15%"）。超过即夹住，防光流短暂
    /// 发散时掩码被甩出画面。
    ///
    /// 实例属性（SelfTest 以 `ext.maxShiftCells` 读取并在单测时覆盖）。
    var maxShiftCells: Double = 24.0

    // MARK: - B 档可调参数（实例属性，单测时可覆盖）

    /// B 档参与校验所需的最少轨迹数。轨迹太少（<3 辆）时中位数不可靠，
    /// 直接退回纯 A 档 —— "检测框是辅助"的落点：没把握就不碰。
    var minTrajectoryCount: Int = 3

    /// 一致性判定：光流位移与轨迹中位位移的夹角余弦下限。
    var minCosSimilarity: Double = 0.7

    /// 一致性判定：两者位移模长之比允许范围（轨迹 / 光流）。
    var magnitudeRatioRange: ClosedRange<Double> = 0.3...3.0

    /// B 档加权时光流的权重。轨迹只做**加固**不做主导（用户：检测框是辅助）。
    var flowWeight: Double = 0.7

    // MARK: - 主入口

    /// A 档：把上一帧掩码按本帧光流平移一帧（纯光流，无轨迹）。
    ///
    /// - Parameters:
    ///   - previous: 上一帧 ll 快照（真值优先，空档时是上一次外推结果）。
    ///   - flow: 本帧光流读数（nil / NaN / ±inf → flowUnavailable 静止回退）。
    /// - Returns: 本帧中间车道线 + 诊断。畸形 previous → `.rejected`。
    func extrapolate(previous: MaskGrid, flow: OpticalFlowReading?) -> LaneFlowExtrapolation {
        extrapolate(previous: previous, flow: flow, trajectories: [])
    }

    /// A+B 档：按光流平移，并叠加检测框轨迹一致性约束（可选）。
    ///
    /// - Parameters:
    ///   - previous: 上一帧 ll 快照。
    ///   - flow: 本帧光流读数（nil / NaN / ±inf → flowUnavailable 静止回退）。
    ///   - trajectories: 本帧"行驶中车辆"轨迹（B 档辅助约束，够数且一致才生效）。
    /// - Returns: 本帧中间车道线 + 诊断。
    func extrapolate(previous: MaskGrid,
                     flow: OpticalFlowReading?,
                     trajectories: [DetectedTrajectory]) -> LaneFlowExtrapolation {
        // ── 门①：无可用上一帧 / 畸形掩码 → rejected ──
        // 畸形 = cells 短于 width*height（YolopxEngine.swift:53-64 的 SIGTRAP 教训）。
        guard previous.width > 0, previous.height > 0,
              previous.cells.count >= previous.width * previous.height else {
            return LaneFlowExtrapolation(mask: .empty,
                                         shiftCellsX: 0, shiftCellsY: 0,
                                         flowConfidence: 0,
                                         usedTrajectoryCount: 0,
                                         quality: .rejected)
        }

        // ── 门②：光流 nil / dx·dy 非有限 → flowUnavailable 静止回退 ──
        // 显式判 isFinite：NaN/±inf 直接喂 Int() 会 trap（SelfTest S4.3）。
        guard let f = flow, f.dx.isFinite, f.dy.isFinite else {
            return LaneFlowExtrapolation(mask: previous,
                                         shiftCellsX: 0, shiftCellsY: 0,
                                         flowConfidence: 0,
                                         usedTrajectoryCount: 0,
                                         quality: .flowUnavailable)
        }

        // ── 像素位移 → 格子位移（基础 A 档量），并硬限幅 ──
        var dx = f.dx / Self.gridStride
        var dy = f.dy / Self.gridStride
        dx = max(-maxShiftCells, min(maxShiftCells, dx))
        dy = max(-maxShiftCells, min(maxShiftCells, dy))

        var quality: LaneExtrapolationQuality = .translated
        var usedTrajectories = 0

        // 基础置信度：幅值越接近"转场级"越不可信（80px 同源 AuroraFlags.egoMaxFlowPx）。
        let mag = f.magnitude
        let maxFlowPx = 80.0
        var confidence = mag <= maxFlowPx ? 1.0 : max(0.0, maxFlowPx / mag)

        // ── B 档：轨迹中位位移与光流一致 → 平移量加权加固 ──
        if trajectories.count >= minTrajectoryCount {
            let medX = Self.median(trajectories.map(\.shiftX))
            let medY = Self.median(trajectories.map(\.shiftY))
            if Self.consistent(flowDX: f.dx, flowDY: f.dy,
                               trajDX: medX, trajDY: medY,
                               minCos: minCosSimilarity,
                               ratioRange: magnitudeRatioRange) {
                dx = flowWeight * dx + (1.0 - flowWeight) * (medX / Self.gridStride)
                dy = flowWeight * dy + (1.0 - flowWeight) * (medY / Self.gridStride)
                dx = max(-maxShiftCells, min(maxShiftCells, dx))
                dy = max(-maxShiftCells, min(maxShiftCells, dy))

                usedTrajectories = trajectories.count
                quality = .detConstrained
                confidence = min(1.0, confidence + 0.2)   // 一致性抬置信
            }
            // 不一致 → 保持纯 A 档平移量与置信度，不强行用轨迹。
        }

        let mask = Self.translate(previous, shiftCellsX: dx, shiftCellsY: dy)
        return LaneFlowExtrapolation(mask: mask,
                                     shiftCellsX: dx,
                                     shiftCellsY: dy,
                                     flowConfidence: confidence,
                                     usedTrajectoryCount: usedTrajectories,
                                     quality: quality)
    }

    // MARK: - 纯函数（可单测）

    /// A 档核心：把掩码整体平移 (shiftCellsX, shiftCellsY) 个格子。
    ///
    /// 符号：shiftCellsX > 0 → 内容向右搬（输出格读取更靠左的源格）。
    /// 对齐坐标契约：`out.at(x, y) = in.at(x - cellDX, y - cellDY)`
    /// （LaneExtrapolatorSelfTest.swift:17-20），这里用 `srcX = dstX - sx` 的
    /// 反查写法实现同一语义，天然无空洞（每目标格恰一源格）。
    ///
    /// 边界：源格落出 [0,w)×[0,h) → 输出保持 0（= empty），**不回卷 wrap**。
    ///
    /// ⚠️ 畸形输入（cells 短于 width*height）不崩溃：栅格遍历全部经 `at()`，
    ///    而 `at` 内部有长度守卫（YolopxEngine.swift:66-73），宽高保留但前景全空。
    static func translate(_ mask: MaskGrid,
                          shiftCellsX: Double,
                          shiftCellsY: Double) -> MaskGrid {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0 else { return .empty }

        // 半格四舍五入到整格（契约 cellDX = round(dx/stride)，SelfTest S0.3）。
        let sx = Int(shiftCellsX.rounded())
        let sy = Int(shiftCellsY.rounded())
        var out = [UInt8](repeating: 0, count: w * h)

        for dstY in 0..<h {
            let srcY = dstY - sy
            guard srcY >= 0, srcY < h else { continue }   // 整行移出 → 全 empty
            for dstX in 0..<w {
                let srcX = dstX - sx
                guard srcX >= 0, srcX < w else { continue } // 移出 → 该格 empty
                if mask.at(srcX, srcY) {
                    out[dstY * w + dstX] = 1
                }
            }
        }
        return MaskGrid(width: w, height: h, cells: out)
    }

    /// B 档一致性判定：光流位移与轨迹中位位移是否"方向一致、尺度相当"。
    ///
    /// 两项判据必须同时通过：
    ///   ① 夹角余弦 ≥ minCos（方向一致，排除符号相反）；
    ///   ② 模长比值 ∈ ratioRange（尺度一致，排除"一个说近一个说远"）。
    /// 任一不满足返回 false（上层退回纯 A 档）。
    static func consistent(flowDX: Double, flowDY: Double,
                           trajDX: Double, trajDY: Double,
                           minCos: Double,
                           ratioRange: ClosedRange<Double>) -> Bool {
        let flowMag = (flowDX * flowDX + flowDY * flowDY).squareRoot()
        let trajMag = (trajDX * trajDX + trajDY * trajDY).squareRoot()
        // 任一近零：无法比方向 → 判不一致（fail-open，别用没依据的证据）
        guard flowMag > 1e-6, trajMag > 1e-6 else { return false }

        let cos = (flowDX * trajDX + flowDY * trajDY) / (flowMag * trajMag)
        guard cos >= minCos else { return false }

        let ratio = trajMag / flowMag
        guard ratioRange.contains(ratio) else { return false }

        return true
    }

    /// 中位数（偶数个取中间两数均值）。纯函数，无副作用。
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        } else {
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        }
    }
}