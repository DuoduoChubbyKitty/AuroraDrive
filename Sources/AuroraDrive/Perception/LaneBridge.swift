//
//  LaneBridge.swift
//  AuroraDrive
//
//  E5 任务产出：车道线「外推器 → LaneFallback」接线封装。
//
//  ⚠️ 本文件只提供可被 tick 主循环一行调用的入口方法，**不碰任何现有文件**；
//     真正的接线由 Lead 最后统一做，LaneBridge 在这里只负责把
//     「ll 真值缓存 → 光流外推 → fail-open 回退」这条链路封装成一个纯函数。
//
//  ── 分层与依赖方向（谁调谁）──
//    tick 主循环
//      └─ LaneBridge.updateLane(...)         (本文件)
//           ├─ yolopx 真值帧   → 直接返回 + 缓存快照
//           └─ 降频空档帧      → 调注入的外推器 closure（E2.LaneExtrapolator）
//                                 └─ (E2 内部调 E3.EgoMotionModel.maskShift 挪掩码)
//           └─ 任何失败         → 回退上一帧快照（fail-open：宁旧、不报错）
//
//  之所以 LaneBridge 不直接 `import` / 持有 E2/E3 的类型，是因为 E2( LaneExtrapolator.swift )
//  与 E3 的 maskShift 本周尚未落地。这里用**闭包注入**占位：Lead 接线时把 E2 真实实现
//  包装成一个 closure 塞进 init 即可，LaneBridge 本体无外部依赖、可独立编译与单测。

import Foundation

// MARK: - E2 注入契约

/// 车道线外推器的抽象契约（= E2 `LaneExtrapolator` 的核心方法签名）。
///
/// Lead 接线时，把 E2 的实例包成这个闭包传入构造函数：
/// ```swift
/// let extrapolator = LaneExtrapolator()          // E2 的类（落地后）
/// let bridge = LaneBridge { prev, flow, dt, dets in
///     extrapolator.extrapolate(previous: prev, flow: flow, dt: dt, detections: dets)
/// }
/// ```
///
/// - 参数
///   - previousLaneMask: 上一帧成功的车道线快照（真值优先，空档时是上一次外推结果）
///   - flow: 当前光流读数（已判有效，非 nil 才到这里）
///   - dt: 帧间隔（秒）
///   - detections: MotionPredictor 锁定的检测框（辅助信源，E2 可选使用）
/// - 返回：外推出的中间帧车道线掩码；失败/不可信时返回 nil（落到 fail-open 回退）
typealias LaneExtrapolationFn = (
    _ previousLaneMask: MaskGrid,
    _ flow: OpticalFlowReading,
    _ dt: Double,
    _ detections: [Detection]
) -> MaskGrid?

// MARK: - 车道线桥接器

/// 车道线桥接器：封装「ll 真值缓存 + 光流外推 + fail-open 回退」。
///
/// 设计目标（对齐任务硬性要求）：
///   - 纯值类型，全部可变状态就是下面两个恒加上下文，无全局单例、无 @Observable、
///     无 @MainActor，天然可单测（构造时注入 extrapolator 与时间源 `now`）。
///   - 一行接入 tick：见 `updateLane` 头注。
///
/// 状态语义：
///   - `lastLaneSnapshot`：**上一次成功产出**的车道线掩码。有真值时被真值覆盖
///     （误差清零）；空档外推成功时被外推结果覆盖。它是"上一帧快照"，
///     既喂给 E2 做外推锚点，又充当 fail-open 的回退值。
///   - `lastGroundTruthTime`：上次收到真值帧的时刻，供 Lead 判断真值新鲜度。
struct LaneBridge {

    // MARK: - 状态

    /// 上一帧成功的车道线快照（真值优先 / 外推结果）。初始为空。
    private(set) var lastLaneSnapshot: MaskGrid = .empty

    /// 上次收到真值帧的时刻；从未收到真值为 nil。
    private(set) var lastGroundTruthTime: Date?

    // MARK: - 注入

    /// 外推器实现（E2 注入）。默认实现：永远返回 nil → 永远走回退分支。
    /// 这样 Lead 在 E2 尚未接线时，LaneBridge 也能安全降级为"只回退快照"。
    private let extrapolator: LaneExtrapolationFn

    /// - Parameter extrapolator: E2 `LaneExtrapolator` 的注入实现。
    init(extrapolator: @escaping LaneExtrapolationFn) {
        self.extrapolator = extrapolator
    }

    /// 便捷构造：**直接绑定 E2 真实实现**（LaneExtrapolator）。
    ///
    /// 2026-10-07（Lead 收口）：E2 最终版
    ///   `extrapolate(previous:flow:trajectories:) -> LaneFlowExtrapolation`，
    ///   取 `.mask` 字段得到 MaskGrid。`maxShiftCells` 是实例属性。
    init() {
        let ext = LaneExtrapolator()
        self.extrapolator = { prev, flow, _dt, _dets in
            ext.extrapolate(previous: prev, flow: flow).mask
        }
    }

    // MARK: - 主入口

    /// 更新一帧车道线并返回 30Hz 的中间车道线掩码。
    ///
    /// 一行接入 tick：
    /// ```swift
    /// let lane = laneBridge.updateLane(dt: dt,
    ///                                   rawLaneMask: engine.laneMask,   // yolopx 真值，低频
    ///                                   flow: flowBridge.compute(gray), // 光流；📌 失败返回 nil
    ///                                   detections: predictor.predictorDetections)
    /// ```
    ///
    /// - Parameters:
    ///   - dt: 帧间隔（秒）
    ///   - rawLaneMask: yolopx 刚出的 ll 真值掩码。**降频空档时传 `.empty`（宽/高为 0）**
    ///     表示"本帧无真值"；传几何自洽（宽高为正且 cells 长度够）的掩码表示"有真值帧"。
    ///   - flow: 当前光流读数。⚠️ `OpticalFlowReading` 类型上**没有 `valid` 字段**——
    ///     任务里说的"光流 valid=0"在现有代码里的真实表达是
    ///     `OpticalFlowBridge.compute` 失败时返回 **nil**。故本参数为 Optional，
    ///     nil 即代表光流不可用（非 nil 的隐式包装向上转型，直接传也可）。
    ///   - detections: MotionPredictor 锁定的检测框（辅助信源，透传给外推器）。
    ///   - now: 当前时刻（可注入以单测；默认真实时钟）。
    /// - Returns: 本帧应输出的车道线掩码。宁可旧、不报错。
    mutating func updateLane(dt: Double,
                             rawLaneMask: MaskGrid,
                             flow: OpticalFlowReading?,
                             detections: [Detection],
                             now: Date = Date()) -> MaskGrid {

        // ① 有真值帧：几何自洽就「缓存 + 直接返回」，锚点被真值刷新、误差清零。
        if Self.isUsable(rawLaneMask) {
            lastLaneSnapshot = rawLaneMask
            lastGroundTruthTime = now
            return rawLaneMask
        }

        // ── 以下皆为降频空档：无真值，走外推 / 回退 ──

        // ② 连一个可用的历史锚点都没有 → 无旧可回退，返回空掩码。
        //    空掩码(宽/高=0)会被 LaneFallback 的入口门拒绝 → 返回 nil 建议，
        //    与 fail-open 语义一致（不给出假方向）。
        guard Self.isUsable(lastLaneSnapshot) else {
            return .empty
        }

        // ③ 光流不可用（nil = valid=0；或位移分量非有限）→ 回退上一帧快照。
        guard let flow, flow.dx.isFinite, flow.dy.isFinite else {
            return lastLaneSnapshot
        }

        // ④ 调 E2 外推；未就绪 / 返回 nil / 返回畸形掩码 → 一律回退上一帧快照。
        if let extrapolated = extrapolator(lastLaneSnapshot, flow, dt, detections),
           Self.isUsable(extrapolated) {
            lastLaneSnapshot = extrapolated
            return extrapolated
        }
        return lastLaneSnapshot
    }

    /// 清空历史（停止驾驶 / 切换场景时调用）。
    /// 不清的话，重新开始时空档帧会拿"停车前最后一张车道线"做回退，画面跳变。
    mutating func reset() {
        lastLaneSnapshot = .empty
        lastGroundTruthTime = nil
    }

    /// 距上次真值已经过了多久（秒）；从未收到真值返回 nil。
    func trueValueAge(at now: Date = Date()) -> TimeInterval? {
        guard let t = lastGroundTruthTime else { return nil }
        return now.timeIntervalSince(t)
    }

    // MARK: - 内部校验

    /// 掩码是否几何自洽、可安全用于外推 / 回退。
    ///
    /// ⚠️ 只做「尺寸为正 + cells 长度足够」的**同构校验**，不做 `==160` 的严格门
    ///    （那是 LaneFallback 的职责，见其门②）。这里若 cells 短于 width*height，
    ///    后续 LaneFallback 会 SIGTRAP，故必须提前拦住 —— 与本文件 fail-open 红线一致。
    private static func isUsable(_ mask: MaskGrid) -> Bool {
        mask.width > 0 && mask.height > 0 && mask.cells.count >= mask.width * mask.height
    }
}