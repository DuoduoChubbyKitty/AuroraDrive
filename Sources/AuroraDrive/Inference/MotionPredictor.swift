//
//  MotionPredictor.swift —— 把 15Hz 的感知外推成 30Hz
//
//  ── 它解决什么问题 ──
//
//  YOLOPX 单次推理实测约 60ms（148 GFLOPs 对 ANE 实测峰值 9.26 TFLOPS，
//  物理地板 16ms，当前效率约 26%），跑不到 30Hz。但主循环是 30Hz。
//  如果每帧只读"最近一次检测结果"，那么在两帧推理之间，检测框是**完全静止**的 ——
//  目标在移动，框却钉在原地。车会按过期的位置做决策。
//
//  解法（用户提的方案）：
//    · YOLOPX 出低频真值（约 15Hz）
//    · 光流给出帧间运动矢量（30Hz，实测 p95 3.7ms）
//    · 用 α-β 滤波器维护每个目标的位置 + 速度
//    · 帧间用速度外推，真值到达时用新观测校正
//
//  ── 为什么用 α-β 而不是卡尔曼 ──
//
//  α-β 滤波器是卡尔曼滤波在"匀速运动模型 + 稳态增益"下的解析解。
//  这里不需要卡尔曼的协方差矩阵，因为：
//    · 目标运动模型简单（近匀速，车道场景）
//    · 观测噪声相对稳定（YOLO 框的实际抖动幅度可测）
//    · 30Hz 下每帧都要跑，α-β 只有两个乘加，卡尔曼要做矩阵运算
//  实测参数见下方 `alpha` / `beta` 的注释。
//
//  ── 设计纪律（与 LaneFallback 同风格）──
//
//  ① fail-open：光流不可用 / 真值过期 / 目标丢失超时 → 不做外推，
//     直接返回未预测的原始检测。**绝不编造运动**。
//  ② 预测结果显式标记 `isPredicted = true`，决策层可据此降权 ——
//     外推出来的位置精度一定低于真值，不能和真值等价对待。
//  ③ 速度需连续 N 帧确认才启用外推，防单帧抖动造成"假运动"。
//  ④ 位移上限硬限幅：单帧外推不允许超过视野的合理比例，
//     防止滤波器发散时把框甩到画面外。
//
//  ── 线程模型 ──
//
//  由调用方（tick，主线程）串行调用。内部状态无锁。
//

import Foundation

// MARK: - 预测输出

/// 一个带运动状态的跟踪目标。
///
/// 与 `Detection` 的关系：`Detection` 是"这一帧看到什么"，
/// `TrackedTarget` 是"这个目标现在在哪、往哪走"。
struct TrackedTarget: Equatable {

    /// 稳定 ID（跨帧不变，用于 UI 显示与调试追踪）
    let id: Int

    /// 当前估计的框（已外推到"此刻"）
    let detection: Detection

    /// 估计速度（归一化坐标 / 秒）
    let velocityX: Double
    let velocityY: Double

    /// 是否为外推结果（true = 本帧没有真值观测，位置是预测出来的）
    ///
    /// ⚠️ 决策层**必须**对这个为 true 的目标降权：外推精度低于真值，
    ///    尤其在目标机动（急转/急刹）时误差会累积。
    let isPredicted: Bool

    /// 距上次真值观测的帧数（0 = 本帧刚被观测到）
    let framesSinceObservation: Int

    /// 速度是否已被确认（连续多帧一致）
    /// false 时 velocityX/Y 可能是噪声，调用方不应依赖
    let isVelocityReliable: Bool

    /// ★ 光流接线（2026-10-01）：本目标的「自车运动可解释性」判定。
    ///
    /// `nil` = 无判定（光流不可用 / 校验关闭 / 观测位移过小）。
    /// `blocksPrediction == true` = 本目标的位移被判为"自车运动所致"，
    /// 已阻断外推（本帧位置只做 α 平滑，未叠加 velocity·dt）。
    ///
    /// ⚠️ 该字段**只读、只用于诊断与 UI**；控制决策不应直接读它 ——
    ///    拦截动作已经体现在 `isPredicted` 上（被拦时必为 false 或无外推增量）。
    ///    加它出来是为了让"到底拦了几个、为什么拦"在日志里可见
    ///    （与 §6.44 的教训一致：看不见的机制无法验证）。
    var egoVerdict: EgoVerdict? = nil
}

// MARK: - 预测器

/// 多目标运动预测器。
///
/// 用法（在 30Hz tick 内）：
/// ```swift
/// // 1. 光流出结果时喂给它（用于校验全局运动方向）
/// predictor.updateEgoMotion(flow)
/// // 2. YOLOPX / yolo26s 出新检测时喂真值
/// predictor.ingest(detections: dets)
/// // 3. 每帧取外推后的目标
/// let targets = predictor.predict(dt: dt)
/// ```
final class MotionPredictor {

    // MARK: - 可调参数

    /// 位置平滑系数 α（0~1，越大越信新观测）
    ///
    /// 0.55 的来历：YOLO 框的逐帧抖动实测约 1~2%（IoU 0.95+ 的同目标相邻帧），
    /// α 取 0.55 能把抖动压掉约一半，同时跟踪上真实运动（滞后 < 1 帧）。
    /// 与 `YoloEngine.smooth()` 的既有 α 保持一致，避免两处平滑参数打架。
    var alpha: Double = 0.55

    /// 速度平滑系数 β（0~1）
    ///
    /// α-β 滤波器的标准稳定条件：0 < α < 2, 0 < β ≤ 4 - 2α。
    /// 取 β = 0.25（远小于上界 2.9）→ 速度收敛慢但**不会震荡**。
    /// 速度宁可保守：速度估过头会导致外推把框甩飞。
    var beta: Double = 0.25

    /// 真值观测超过这么多帧没到 → 停止外推（只维持最后位置）
    ///
    /// 30Hz 下 10 帧 ≈ 0.33s。YOLOPX 是 15Hz，正常间隔约 2 帧；
    /// 10 帧意味着推理链已经卡了，此时速度估计早已过期。
    var maxPredictionFrames: Int = 10

    /// 真值观测超过这么多帧没到 → 判定目标消失，移除
    /// 30Hz 下 30 帧 = 1s（比 YoloEngine 的锁定追踪 15 帧更宽松，
    /// 因为这里要容忍 YOLOPX 的低频 + 偶发遮挡）
    var maxMissingFrames: Int = 30

    /// 速度确认所需的连续一致帧数
    /// 未确认前不外推（`isVelocityReliable = false`），只做位置平滑
    var velocityConfirmFrames: Int = 3

    /// 单帧外推位移上限（归一化坐标）
    ///
    /// 0.15 ≈ 视野的 15%。30Hz 下相当于每秒 4.5 倍视野宽 ——
    /// 游戏里不可能有这么快的东西。超过就说明滤波器发散了，必须夹住。
    var maxPredictStep: Double = 0.15

    /// 数据关联的 IoU 门限（低于此视为新目标）
    var associationIoU: Double = 0.25

    // MARK: - 内部状态

    /// 单个跟踪器的状态
    private struct Track {
        var detection: Detection
        var velocityX: Double = 0
        var velocityY: Double = 0
        var missedFrames: Int = 0        // 连续没有真值观测的帧数
        var consistentVelocityFrames: Int = 0
        var lastObservationFrame: Int = 0
        /// 本 tick 内是否收到过真值。**必须用标志位而不是比较帧号** ——
        /// ingest 与 predict 的调用顺序由调用方决定，比较帧号会在
        /// 「先 ingest 后 predict」时把刚落地的真值误记成一次缺席。
        var observedThisTick: Bool = false
    }

    private var tracks: [Int: Track] = [:]
    private var nextID: Int = 1
    private var frameCounter: Int = 0

    /// 最近一次 ingest 的帧间隔（秒）。用于把观测位移换算成 /秒 速度。
    private var lastIngestDt: Double = 1.0 / 30.0

    /// 最近一次自车运动（来自光流），供校验与诊断
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 全项目核查：**本字段目前没有任何读取方**（zero-reader）。
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// 核查方法（对整个 `Sources/` 做全文检索）：
    ///   · `lastEgoMotion` 命中 3 处 —— 本行声明、下方 `updateEgoMotion` 写入、
    ///     `reset()` 里清 nil。**没有一处是读取。**
    ///   · `DriveState.lastOpticalFlow` 同样只有 声明 / 写入，无读取。
    ///   · 兄弟方法 `predict(dtSeconds:)` 用到的成员只有：
    ///     `t.velocityX` / `t.velocityY` / `t.detection` / `t.missedFrames` /
    ///     `t.observedThisTick` / `t.consistentVelocityFrames` —— 不含本字段。
    ///   · 速度的真正来源是 α-β 滤波对**检测框差分**的更新（见 `:248 residualX`
    ///     → `:265 t.velocityX = newVX`），与光流无关。
    ///
    /// 也就是说：上方「用途：交叉校验」描述的校验逻辑**从未实现** ——
    /// 接口预留了、数据喂进来了、消费端没接线。
    ///
    /// **代价是实打实的**（`--opticalflow-selftest` + 独立复现，详见
    /// `AuroraDriveApp.runOpticalFlow(on:)` 调用点的注释）：
    ///   · 光流每帧都在算，实测 p50 1.25ms（空载）/ 2.60ms（与 YOLOPX 并发）
    ///     / 5.4~8.4ms（游戏+引擎满载），p95 最高 50ms
    ///   · 30Hz 下持续占用 0.35~1.6 个核的百分之几十
    ///
    /// **因此本字段保留为诊断用途**：核对「光流估的自车运动」与「滤波器从框
    /// 差分算出的速度」是否一致，是接上那段校验逻辑前的必要前提。
    /// 它不再参与任何控制/预测计算。
    private(set) var lastEgoMotion: OpticalFlowReading?

    /// 本帧的预测统计（诊断用）
    private(set) var lastPredictedCount: Int = 0
    private(set) var lastObservedCount: Int = 0
    private(set) var lastPrunedCount: Int = 0

    // MARK: - ★ 光流接线（2026-10-01 · 路线2）

    /// 自车运动径向模型（无状态，纯函数式）。
    ///
    /// 为什么在这里持有而不是在 tick 里：判定必须在 `applyObservation` 内部完成
    /// （那里同时有「框位置 + 该框速度」），而 `updateEgoMotion` 只负责投递光流。
    private let egoModel = EgoMotionModel()

    /// 最近一次投递的光流（由 `updateEgoMotion` 写入，`applyObservation` 读取）
    private var currentEgoFlow: OpticalFlowReading?

    /// 每个 track 的「自车运动可解释性」判定。
    ///
    /// 生命周期：`applyObservation` 写入 → `predict()` 读取 → track 被 prune 时清理。
    /// 没有真值观测的帧沿用上一次判定（这正是我们要的：判定基于"这个目标相对
    /// 自车的运动性质"，短期内不应因漏检一帧就失效）。
    private var egoVerdicts: [Int: EgoVerdict] = [:]

    /// 本帧因「自车运动可解释」而被阻断外推的目标数（诊断用）。
    private(set) var lastEgoBlockedCount: Int = 0

    /// 查询某个目标的判定结论（供 UI/日志诊断）。
    func egoVerdict(for id: Int) -> EgoVerdict? { egoVerdicts[id] }

    // MARK: - 输入

    /// 喂入光流的自车运动估计。
    ///
    /// ⚠️ 2026-09-30 注释更正：原文写「用途：**交叉校验**……如果滤波器算出的
    ///    速度与光流方向严重矛盾 → 降级为不预测」——**该逻辑并不存在于代码中**。
    ///    本方法当前只做一件事：把值存进 `lastEgoMotion`（诊断字段，无读取方）。
    ///    完整核查见 `lastEgoMotion` 的文档注释。
    ///
    /// 保留此入口的理由：它是那段校验逻辑接线的**唯一插入点**。若将来要真正
    /// 实现「光流方向 × 框速度一致性校验」，在此处扩展即可，调用方无需改动。
    ///
    /// ★ 2026-10-01（光流接线·路线2）：上面那段"尚未实现的校验"**现在实现了**。
    ///    本方法从「只存值」变成「存值 + 供校验使用」：
    ///      · `lastEgoMotion` 仍是诊断字段（原语义与既有读取方不变）
    ///      · 新存的 `currentEgoFlow` 由 `applyObservation` 消费 —— 那里能同时
    ///        拿到「框位置 + 该框速度」，是唯一能做判定的地方
    ///      · 判定结果写入 `egoVerdicts[trackID]`，由 `predict()` 的外推条件消费
    ///    关闭开关：`AURORA_EGO_CHECK=off` → 判定恒为 nil → 行为与接线前逐帧一致。
    ///    调用方（tick）**无需任何改动** —— 正如原文所预期。
    func updateEgoMotion(_ flow: OpticalFlowReading?) {
        lastEgoMotion = flow
        // ★ 刻意**不在本方法里做判定**：判定需要「框位置 + 该框速度」，
        //   那些在 track 里，此处拿不到。此处只做数据中转。
        currentEgoFlow = flow
    }

    /// 喂入一帧真值检测（来自 YOLOPX 或 yolo26s）。
    ///
    /// 关联策略：对每个已有 track，找 IoU 最大的新检测；命中则用 α-β 校正，
    /// 未命中的 track 记一次 missed。剩余的检测作为新目标建立 track。
    ///
    /// ⚠️ **本方法不推进帧计数**。帧的推进由 `predict(dtSeconds:)` 负责
    ///    （见该方法注释）。`ingest` 只做"校正"：把 `lastObservationFrame`
    ///    标成当前帧并清零 `missedFrames`，表示"这一帧有真值"。
    ///
    ///    调用顺序应当是：每个 tick 先 `ingest`（如果有新真值）再 `predict`；
    ///    或先 `predict` 再 `ingest` —— 两者都可，只要**每个 tick 恰好调用
    ///    一次 predict**。
    func ingest(detections: [Detection], dtSeconds: Double = 1.0 / 30.0) {
        lastObservedCount = detections.count
        lastIngestDt = dtSeconds

        guard !detections.isEmpty else {
            // 没有检测：不在这里自增 missed —— 计时统一由 predict 负责，
            // 否则「ingest 空 + predict」会让一个 tick 记两次缺席。
            pruneIfNeeded()
            return
        }

        var available = Array(detections.enumerated())
        var matchedKeys = Set<Int>()

        // 贪心匹配：按 IoU 从高到低配对
        var pairs: [(trackKey: Int, detIdx: Int, iou: Double)] = []
        for (key, track) in tracks {
            for (idx, det) in available {
                let v = Self.iou(track.detection, det)
                if v >= associationIoU {
                    pairs.append((key, idx, v))
                }
            }
        }
        pairs.sort { $0.iou > $1.iou }

        var usedDetIdxs = Set<Int>()
        for p in pairs {
            guard !matchedKeys.contains(p.trackKey), !usedDetIdxs.contains(p.detIdx) else { continue }
            matchedKeys.insert(p.trackKey)
            usedDetIdxs.insert(p.detIdx)
            applyObservation(key: p.trackKey, detection: detections[p.detIdx], dtSeconds: dtSeconds)
        }


        // 剩余检测 → 新目标
        for (idx, det) in available where !usedDetIdxs.contains(idx) {
            tracks[nextID] = Track(detection: det,
                                   lastObservationFrame: frameCounter,
                                   observedThisTick: true)
            nextID += 1
        }

        pruneIfNeeded()
    }

    /// 用一次真值观测校正 track（α-β 更新）。
    private func applyObservation(key: Int, detection: Detection, dtSeconds: Double) {
        guard var t = tracks[key] else { return }

        // 位置：α 平滑
        let newX = t.detection.x + (detection.x - t.detection.x) * alpha
        let newY = t.detection.y + (detection.y - t.detection.y) * alpha

        // 速度：用"观测位移 - 预测位移"的残差更新（标准 α-β 形式）
        //
        // ⚠️ 单位：velocity 存的是**归一化坐标 / 秒**，不是 /帧。
        //    初版把 velocity 当成 /帧 存，却在外推时乘 dtSeconds，导致外推量
        //    小了 30 倍（实测每帧只走 +0.0016 而非 +0.0100）。
        //    统一成 /秒 后，"每帧走多远"由 dtSeconds 决定，换帧率也不用改参数。
        let frameDelta = max(1, frameCounter - t.lastObservationFrame)
        let dtSpan = max(dtSeconds * Double(frameDelta), 1e-4)   // 距上次观测经过的秒数（防 0 除）
        let residualX = (detection.x - t.detection.x) - t.velocityX * dtSpan
        let residualY = (detection.y - t.detection.y) - t.velocityY * dtSpan

        let newVX = t.velocityX + beta * residualX / dtSpan
        let newVY = t.velocityY + beta * residualY / dtSpan

        // 速度一致性判定：与上一帧速度同号且量级接近 → 计数 +1，否则清零重来。
        // 这是"防单帧抖动造出假运动"的门。量级阈值按 /秒 口径给（0.15/秒
        // ≈ 每帧 0.005，约等于 640 图上 3px/帧的加速度上限）。
        let sameDir = (newVX * t.velocityX >= 0) && (newVY * t.velocityY >= 0)
        let magnitudeOK = abs(newVX - t.velocityX) < 4.5 && abs(newVY - t.velocityY) < 4.5
        if sameDir && magnitudeOK {
            t.consistentVelocityFrames = min(t.consistentVelocityFrames + 1, velocityConfirmFrames)
        } else {
            t.consistentVelocityFrames = 0
        }

        t.velocityX = newVX
        t.velocityY = newVY
        // 长宽也平滑（不做速度估计 —— 尺寸变化慢，且容易受遮挡影响）
        t.detection = Detection(x: newX, y: newY,
                                width: t.detection.width + (detection.width - t.detection.width) * alpha,
                                height: t.detection.height + (detection.height - t.detection.height) * alpha,
                                label: detection.label,
                                confidence: detection.confidence,
                                rawName: detection.rawName)
        t.missedFrames = 0
        t.observedThisTick = true
        t.lastObservationFrame = frameCounter
        tracks[key] = t

        // ★ 光流接线（2026-10-01 · 路线2）：自车运动可解释性判定。
        //
        // 【为什么放在这里】这是全项目**唯一**同时握有「光流自车运动」+
        //   「该 track 的框位置」+「该 track 的滤波速度」的地方。
        //   其它位置要么缺光流，要么缺速度。
        //
        // 【为什么不修改任何既有值】本判定只**标记**，不改 `velocityX/Y`、
        //   不改 `consistentVelocityFrames`、不改框位置。理由是那些值已经被
        //   单元自检与真机行为验证过，贸然修改会让"回归对比"失去对照基准。
        //   拦截动作统一由 `predict()` 的外推条件承担 —— 单点生效，好回退。
        //
        // 【fail-open】任一环节不可用（光流 nil / 未收敛 / 置信度低 / 位移过小）
        //   → `verdict` 返回 nil → 本条不清除既有判定也**不新增拦截**。
        //   特别注意：**不能**因为"这帧没数据"就把判定清成 false ——
        //   那会让拦截在漏检帧之间反复抖动。
        if let flow = currentEgoFlow {
            if let ego = egoModel.estimate(from: flow, dt: dtSpan) {
                if let v = egoModel.verdict(for: t.detection,
                                            observedVelocity: (newVX, newVY),
                                            ego: ego) {
                    egoVerdicts[key] = v
                }
                // verdict 为 nil（如观测位移过小）→ 保留上一次判定，不清除
            }
        }
    }

    /// 清理长时间没观测到的目标。
    private func pruneIfNeeded() {
        let before = tracks.count
        tracks = tracks.filter { $0.value.missedFrames <= maxMissingFrames }
        lastPrunedCount = before - tracks.count

        // ★ 光流接线（2026-10-01）：同步清理已消失 track 的判定。
        //   不清理的话 `egoVerdicts` 会随驾驶时长无限增长（每个出现过的目标
        //   留下一份判定），是明确的内存泄漏。清理判据与 track 存活判据一致：
        //   track 表里没有的 key，其判定一并丢弃。
        if before != tracks.count {
            let alive = Set(tracks.keys)
            egoVerdicts = egoVerdicts.filter { alive.contains($0.key) }
        }
    }

    // MARK: - 外推输出

    /// 推进一帧并取出所有目标（已按需外推）。
    ///
    /// - Parameter dtSeconds: 距上一帧的秒数（通常 1/30）
    /// - Returns: 当前时刻的目标列表。`isPredicted = true` 的是外推结果。
    ///
    /// ⚠️ **本方法是"帧驱动器"，不要和 `ingest` 抢着数帧。**
    ///
    ///    初版设计把 `missedFrames` 只在 `ingest` 里 +1，结果 15Hz 真值 +
    ///    30Hz 外推的架构完全失效：真值没来的那一帧走的是 `predict`，
    ///    `missedFrames` 恒为 0，于是 `canPredict` 恒假 —— 外推从不触发。
    ///    实测表现为"预测 x 和真值 x 完全相等"（框根本没被外推）。
    ///
    ///    正确语义：**每个 tick 调用一次 `predict`，它就是"时间前进了一帧"**；
    ///    `ingest` 只在真值到达时调用，它负责"校正"而不负责"计时"。
    ///    所以 `missedFrames` 的自增放在 `predict` 里。
    func predict(dtSeconds: Double) -> [TrackedTarget] {
        frameCounter += 1
        var out: [TrackedTarget] = []
        var predicted = 0

        for (key, var t) in tracks {
            // 时间前进了一帧：本 tick 若无真值落地，就记一次缺席。
            // 用标志位而不是帧号比较，保证 ingest/predict 的调用顺序无关。
            if t.observedThisTick {
                t.missedFrames = 0
                t.observedThisTick = false
            } else {
                t.missedFrames += 1
            }
            let missing = t.missedFrames
            // 外推条件：真值确实缺席（missing > 0）、没超时、且速度已确认
            //
            // ★ 光流接线（2026-10-01 · 路线2）：追加第 4 个条件 ——
            //   「本 target 的位移**不能**被自车运动解释掉」。
            //
            //   语义：若光流显示"这一帧的位移其实就是自车自己在动造成的"，
            //   那么按框差分速度去外推，等于把**自车的运动**当成**目标的运动**
            //   继续放大 —— 那正是这套接线要修的病。
            //   此时 `canPredict = false` → 自动落到下方"位置平滑"路径
            //   （`detection` 保持 α 平滑后的值，不额外叠加 `velocity*dt`）。
            //
            // 【为什么用 verdicts 里的持久判定而不是本帧重算】
            //   漏检帧恰恰是最需要拦截的时候（没有真值可校正，全靠外推）。
            //   判定代表"该目标相对自车的运动性质"，短期稳定，故沿用上次结论。
            //
            // 【回退】`AURORA_EGO_CHECK=off` → `egoModel.estimate` 返回 nil
            //   → `egoVerdicts` 恒为空 → 本条件恒为 true → 行为与接线前**逐帧一致**。
            let egoBlocked = egoVerdicts[key]?.blocksPrediction == true
            let canPredict = missing > 0
                && missing <= maxPredictionFrames
                && t.consistentVelocityFrames >= velocityConfirmFrames
                && !egoBlocked

            var detection = t.detection
            if canPredict {
                // 硬限幅：单帧位移不许超过 maxPredictStep
                var stepX = t.velocityX * dtSeconds
                var stepY = t.velocityY * dtSeconds
                let stepLen = (stepX * stepX + stepY * stepY).squareRoot()
                if stepLen > maxPredictStep {
                    let scale = maxPredictStep / stepLen
                    stepX *= scale
                    stepY *= scale
                }
                detection = Detection(x: t.detection.x + stepX,
                                      y: t.detection.y + stepY,
                                      width: t.detection.width,
                                      height: t.detection.height,
                                      label: t.detection.label,
                                      confidence: t.detection.confidence,
                                      rawName: t.detection.rawName)
                // 把外推结果写回 track，让下一帧在上一次外推基础上继续
                // （否则连续缺席时会一直从旧位置外推，看起来"卡住"）
                t.detection = detection
                predicted += 1
            }

            // 目标越走越远时逐帧衰减置信度 —— 决策层据此自然降低对其的依赖
            let decayedConfidence = missing > 0
                ? t.detection.confidence * pow(0.9, Double(missing))
                : t.detection.confidence
            let finalDetection = Detection(x: detection.x, y: detection.y,
                                           width: detection.width, height: detection.height,
                                           label: detection.label,
                                           confidence: decayedConfidence,
                                           rawName: detection.rawName)

            out.append(TrackedTarget(id: key,
                                     detection: finalDetection,
                                     velocityX: t.velocityX,
                                     velocityY: t.velocityY,
                                     isPredicted: missing > 0,
                                     framesSinceObservation: missing,
                                     isVelocityReliable: t.consistentVelocityFrames >= velocityConfirmFrames,
                                     egoVerdict: egoVerdicts[key]))
            tracks[key] = t
        }

        // 超时目标必须在这里清理，不能只在 ingest 里清 ——
        // 真值链断了（YOLOPX 卡住）时没人调 ingest，目标就永远不会被移除。
        // 这正是"宁可留着僵尸目标"的反面：僵尸框会让决策层误判前方有车。
        pruneIfNeeded()

        lastPredictedCount = predicted
        // ★ 光流接线（2026-10-01）：统计本帧被"自车运动可解释"拦下的目标数。
        //   直接数 verdicts 里 blocksPrediction 为 true 的条目 ——
        //   代表"当前有多少目标的位移被判为自车运动所致"。
        //   刻意**不**在循环内累加：循环内 `canPredict` 还耦合了
        //   "速度未确认/已超时"等其它条件，混在一起会分不清拦截的真实原因。
        lastEgoBlockedCount = egoVerdicts.values.reduce(0) { $0 + ($1.blocksPrediction ? 1 : 0) }
        // 稳定排序（按 id）让输出顺序跨帧可预测，便于调试与 UI 绘制
        out.sort { $0.id < $1.id }
        return out
    }

    /// 只取检测框（丢弃跟踪元信息），供只关心框的调用点使用。
    func predictDetections(dtSeconds: Double) -> [Detection] {
        predict(dtSeconds: dtSeconds).map(\.detection)
    }

    /// 清空全部跟踪状态（停止驾驶时调用）。
    ///
    /// 不清的话，重新开始时会把"停车前最后位置"当成真值，配上一个巨大的
    /// 陈年速度，第一帧外推就把框甩出画面。
    func reset() {
        tracks.removeAll()
        nextID = 1
        frameCounter = 0
        lastEgoMotion = nil
        lastPredictedCount = 0
        lastObservedCount = 0
        lastPrunedCount = 0
        // ★ 光流接线（2026-10-01）：必须一并清 ——
        //   verdicts 是按 track id 索引的，不清的话新会话的第一个 track
        //   可能复用旧 id，继承上一次驾驶的陈旧判定 → 该预测的没预测。
        //   与 `tracks.removeAll()` 同理（"停车前最后位置"不能当新真值）。
        egoVerdicts.removeAll()
        currentEgoFlow = nil
        lastEgoBlockedCount = 0
    }

    // MARK: - 诊断

    /// 当前跟踪目标数
    var trackCount: Int { tracks.count }

    /// 诊断摘要（日志/自检用）
    func diagnostics() -> String {
        let reliable = tracks.values.filter { $0.consistentVelocityFrames >= velocityConfirmFrames }.count
        return "跟踪 \(tracks.count) 个目标（速度已确认 \(reliable) 个）"
            + "，本帧外推 \(lastPredictedCount) 个，观测 \(lastObservedCount) 个"
    }

    // MARK: - 工具

    /// 两框 IoU（归一化坐标，中心点 + 宽高格式）。
    /// 与 `YoloEngine.iou` 同算法，这里独立一份避免跨类型耦合。
    private nonisolated static func iou(_ a: Detection, _ b: Detection) -> Double {
        let ax1 = a.x - a.width / 2, ax2 = a.x + a.width / 2
        let ay1 = a.y - a.height / 2, ay2 = a.y + a.height / 2
        let bx1 = b.x - b.width / 2, bx2 = b.x + b.width / 2
        let by1 = b.y - b.height / 2, by2 = b.y + b.height / 2
        let iw = max(0, min(ax2, bx2) - max(ax1, bx1))
        let ih = max(0, min(ay2, by2) - max(ay1, by1))
        let inter = iw * ih
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
