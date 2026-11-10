// V3 驾驶推理引擎（INT4 4-bit palettize CoreML 模型）
//
// ══════════════════════════════════════════════════════════════════════════
// 【与 InferenceEngineV2 的关系】本引擎是 V3 模型的执行外壳，**不复用 V2 的
//   单帧图像契约**：V2 吃 `image [8,3,180,320]`，V3 吃**双分辨率 24 帧窗口**
//   （3 帧高清 224×384 + 21 帧低清 112×192）。两者的输入形状、帧序、state
//   语义都不同，故独立成类，不塞进 V2 的分支（V2 承载拆分/多模型等既有路径，
//   混改会破坏它的稳定性）。
//
// 【部署形态】模型 `models/v3_int4.mlmodelc`，4-bit 权重（93 个
//   `constexpr_lut_to_dense` LUT 算子），体积 6.08 MiB（fp16 为 23.42 MiB）。
//   计算单元固定 `.cpuAndNeuralEngine`：M3 实测 ANE 4.80ms / CPU 21.75ms /
//   GPU 18.62ms（同一 INT4 模型，1000 样本评估后的持续负载数据）。
//
// ══════════════════════════════════════════════════════════════════════════
// 【红线 1 · 输入 dtype 必须是 float16】
//   模型六个输入全部是 FLOAT16（coremltools 以 compute_precision=FLOAT16 导出）。
//   **实测反例**：同一全零输入，用 float32 MLMultiArray 与 float16 分别推理，
//   输出完全不同（vertical `[1.05,3.61,1.57]` vs `[-0.85,0.76,0.15]`）——
//   这不是误差，而是 dtype 传递错后的静默错误。照抄 V2 的 float32 写法会中招。
//   已用真实样本交叉验证：float16 输入下 Swift 输出与 Python 参考**逐位一致**
//   （8 路输出最大差 0.000000）。
//
// 【红线 2 · 帧序与训练严格一致】（`src/dataset_v3.py:551-573`）
//   image_hi 索引 0 = 当前帧 t，1 = t−1，2 = t−2（**新→旧**）
//   image_lo 索引 0 = t−3，1 = t−4，…，20 = t−23（**新→旧**）
//   即 hi 取窗口最新 3 帧、lo 取紧随其后的 21 帧；两者都按时间倒序排。
//   写反会让模型把旧帧当当前帧 → 时序语义错乱。
//
// 【红线 3 · vehicle_state 必须按训练口径填】（`src/dataset_v3.py:606-638`）
//   8 维中**只有 [6] 有值**：t−1 的 A/D（A→−1，D→+1，其余 0），其余维恒 0。
//   训练侧注释明确记录了为什么不能填速度/车道几何：那会「训练分布 ≠ 推理
//   分布 → 训练指标虚高、上车即崩」。故这里**不复用**
//   `V2FeatureBuilder.buildVehicleState`（它填 speed/accel/heading/curvature/
//   lateral_offset/steer/ego），只按 V3 训练口径写。
//
// ══════════════════════════════════════════════════════════════════════════
// 【输出语义】（`src/dataset_v3.py:136-159`，与模型 8 头一一对应）
//   vertical   [3] 0=W(给油) / 1=NONE / 2=S(刹车·倒挡)   —— S 优先于 W（安全偏置）
//   horizontal [3] 0=A(左) / 1=NONE / 2=D(右)            —— A+D 同按 → NONE
//   handbrake  [1] logit，训练标签 = Shift
//   brake      [1] logit，训练标签 = Space
//   super_brake[1] logit = Shift 且 Space
//   ultimate   [1] logit = Shift 且 Space 且 S
//   confidence [1] logit，正例率 100%（评估集实测）
//   risk       [1] logit，安全相关
//
//   【logit → 触发】决策阈值等价于 logit > 0（sigmoid(x) > 0.5 ⟺ x > 0）。
//   直接比 logit 与 0 可避免一次 sigmoid，且**数学上完全等价**，不是近似。
//
//   【为什么把分类结果映射成连续 steer/throttle/brake】
//   上层控制链路（`applyCommand`）用连续量 + 死区（steer ±0.1、throttle/brake
//   0.3）驱动按键，且所有安全机制（降级链、人工接管、限速刹车、专家模式）都
//   挂在这条链路上。把 V3 的三分类映射成 ±1 / 0 / 1 后，**既有机制全部原样
//   生效**，无需为 V3 单独开一条旁路 —— 这是"所有自动驾驶功能可用"的前提。
//
// ══════════════════════════════════════════════════════════════════════════
// 【并发纪律】`@MainActor` 隔离引擎状态；MLModel 与多帧缓冲标
//   `nonisolated(unsafe)`，**分别只在各自的串行队列上访问**：
//     · `frameBuffer` / `lastFrameAt` → `captureQueue`（采集入窗）
//     · `model` / 输入缓冲 → `queue`（预测）
//   预测侧用 `activePredictionGeneration`（槽位占代数）保证同一时刻只有一个
//   在途预测；它只在 MainActor 上读写，靠 `@MainActor` 隔离即可，无需加锁。
//   这与 V2 的既有做法一致（V2 文件内 `ImageFrameRingBuffer` /
//   `reusableImageSequenceBuffer` 同模式）。
//
// 【超时/失败处理】本帧推理失败或输出含 NaN/Inf → **跳过该帧**，不更新
//   `lastResult`（上层读的是上一次有效结果）；在途预测未完成时的重入调用
//   **仍会入窗**（历史按采集节拍推进，见 infer 的 P0-5 说明），只是不再
//   发起第二次预测、不排队堆积。

import Foundation
@preconcurrency import CoreML
import Observation
import os

// MARK: - 输入契约（形状/dtype 全部来自实测导出的模型 spec）

/// V3 模型的输入输出契约。
///
/// ⚠️ 这些数字必须与 `src/model_v3.py` 的 `V3Config` 及导出产物一致；
///    任何一处手抄错误都会造成「Swift 传得进去、但模型算出来是垃圾」的
///    静默错误（CoreML 对形状错误不总是报错）。
enum V3InputContract {
    // ── 模型文件 ──
    /// `models/v3_int4.mlmodelc`（由 `v3_int4.mlpackage` 经 coremlcompiler 编译）
    static let modelFileName = "v3_int4"

    // ── 输入名（与 spec 完全一致；不可改名）──
    static let imageHi = "image_hi"
    static let imageLo = "image_lo"
    static let lane = "lane"
    static let dets = "dets"
    static let detMask = "det_mask"
    static let vehicleState = "vehicle_state"

    // ── 图像规格 ──
    /// 高清帧数（t, t−1, t−2）
    static let hiFrames = 3
    /// 低清帧数（t−3 … t−23）
    static let loFrames = 21
    /// 窗口总帧数 = 24 帧 @15Hz ≈ 1.6s
    static let totalFrames = 24
    static let hiHeight = 224
    static let hiWidth = 384
    static let loHeight = 112
    static let loWidth = 192

    /// 单帧高清元素数（3 通道 × H × W）
    static let hiFrameElements = 3 * hiHeight * hiWidth
    /// 单帧低清元素数
    static let loFrameElements = 3 * loHeight * loWidth

    // ── 其余输入（V3 训练时恒为零填充，见文件头红线 3）──
    static let laneSize = 160
    static let maxDetections = 20
    static let detFeatureDim = 12
    static let stateDim = 8

    /// `vehicle_state` 里承载「上一帧转向指令」的下标（训练口径：A→−1 / D→+1）
    static let steerStateIndex = 6

    /// 输出名（顺序即模型输出顺序，仅用于诊断打印）
    static let outputNames = [
        "vertical", "horizontal", "handbrake", "brake",
        "super_brake", "ultimate", "confidence", "risk",
    ]

    // ── 窗口时间轴（评审 P0-5）──
    //
    // 【为什么需要这组常量】训练侧 24 帧窗口的语义是「1/15s 等间隔的连续
    //   24 帧」（`src/dataset_v3.py:551-573` + `EXPECTED_FPS = 15`）。
    //   运行时若因为推理在途而丢帧，窗口里的 24 帧就不再是 1.6s 的画面，
    //   而可能是 3.2s —— 模型看到的运动尺度整体错一倍，但它无从察觉。
    //   故这里显式给出名义跨度与容差，供运行时**校验真实采集时刻**，
    //   而不是默认"窗口总是 15Hz"。
    /// 采集帧率（与 `dataset_v3.py:88` 的 `EXPECTED_FPS` 一致）
    static let captureFPS: Double = 15

    /// 名义窗口跨度：首末帧时间差 = 23/15 ≈ 1.533s（24 帧、15Hz）。
    ///
    /// 注意不是 24/15 = 1.6s：跨度是**首末两帧之差**（23 个间隔）。
    /// 文件头「24 帧 ≈ 1.6s」说的是窗口覆盖时长，两者不矛盾，但换算必须用 23。
    static var nominalWindowSpanSeconds: Double {
        Double(totalFrames - 1) / captureFPS
    }

    /// 窗口跨度的**上限**容差（×名义值）。
    ///
    /// 依据：1.5 × 1.533s ≈ 2.30s = 23 帧按 10Hz 排布的跨度。
    /// 即：真实帧率跌到 10Hz 以下时，24 帧已经张得比训练分布长 50%，
    /// 时间尺度失真到不可再用；10Hz 以上（含 20Hz 冲刺）仍在阈值内。
    /// 不取更松的值（如 2×）：7.5Hz 实测跨度 3.07s，2× 边界 3.07s 会正好卡在
    /// 临界线上反复抖动；1.5× 让"隔几帧丢一次"这类轻度过载仍能正常出决策。
    static let maxWindowSpanRatio: Double = 1.5

    static var maxWindowSpanSeconds: Double {
        nominalWindowSpanSeconds * maxWindowSpanRatio
    }
}

// MARK: - 单帧决策（供上层读取）

/// V3 一帧的完整决策。
///
/// 与 `InferenceResult`（steer/throttle/brake/latency）并存：后者喂既有控制
/// 链路，本结构额外携带四个刹车头与 confidence/risk —— 这些量无法塞进
/// `ControlCommand`（它只有 steer/throttle/brake/confidence），需要单独暴露。
struct V3Decision: Sendable, Equatable {
    /// 纵向分类 0=W / 1=NONE / 2=S
    var verticalClass: Int
    /// 横向分类 0=A / 1=NONE / 2=D
    var horizontalClass: Int

    /// Space 键（训练标签 brake）
    var brakePressed: Bool
    /// Shift 键（训练标签 handbrake）
    var handbrakePressed: Bool
    /// Shift + Space
    var superBrakePressed: Bool
    /// Shift + Space + S
    var ultimatePressed: Bool

    /// 决策置信度 ∈ [0,1]（sigmoid 后）
    var confidence: Double
    /// 风险分 ∈ [0,1]（sigmoid 后）。
    ///
    /// ⚠️【当前版本**未**接入生产安全链】（评审 P1-4，已全仓 grep 确认）
    ///   本字段被解析并保存，但 `AuroraDriveApp.swift` 中没有任何 `.risk` 消费点；
    ///   唯一的读取者是 `--v3-selftest` 的范围检查。
    ///   它是训练好的安全头（评估集上决策翻转率 2.10%，四个安全头里最高），
    ///   但"算出来"≠"在起作用"。**不要**因为字段存在就认为风险接管已实现。
    ///   若将来要接（例如 risk > 阈值时压 throttle / 触发人工接管提示），
    ///   必须先与训练侧确认阈值口径（`dataset_v3._conf_risk_targets` 的代理真值定义），
    ///   不能凭直觉取 0.5。
    var risk: Double

    /// 冷启动/模型未就绪时的占位：全部"不动作"，置信度 0。
    static let idle = V3Decision(
        verticalClass: 1, horizontalClass: 1,
        brakePressed: false, handbrakePressed: false,
        superBrakePressed: false, ultimatePressed: false,
        confidence: 0, risk: 0)

    /// 诊断摘要（日志用）。
    var debugSummary: String {
        let v = ["W", "NONE", "S"][max(0, min(2, verticalClass))]
        let h = ["A", "NONE", "D"][max(0, min(2, horizontalClass))]
        return String(format: "v=%@ h=%@ brk=%@ hb=%@ conf=%.3f risk=%.3f",
                      v, h, brakePressed ? "1" : "0", handbrakePressed ? "1" : "0",
                      confidence, risk)
    }
}

// MARK: - 双分辨率帧环形缓冲

/// V3 的 24 帧窗口缓冲：每帧同时存**高清**与**低清**两份（已归一化到 [0,1]）。
///
/// 【为什么存 float16 而不是 uint8】两帧都要参与推理，且模型吃 float16；
///   在写入时就 `/255` 归一化，推理时只需拼接——避免每帧重复做 24 次除法
///   （24 × 32.2 万元素 @15fps ≈ 每秒 1.16 亿次浮点运算，纯属浪费）。
///   代价是内存：24 × (258048 + 64512) × 2B ≈ 15.5 MB，属可接受范围。
///
/// 【为什么帧数不足时用"最早帧填充"】训练侧 `clamp_frame = max(0, fi)`
///   （`dataset_v3.py:555`）——窗口回看越界时钳到第 0 帧。运行时的等价语义
///   是「用缓冲里最早的那一帧重复填充」，与用户在接线前的选择一致。
struct V3FrameRingBuffer {
    let capacity: Int

    private var hiStorage: [[Float16]]
    private var loStorage: [[Float16]]
    /// 每帧的**采集时刻**（与 hi/lo 同一物理槽位）。
    ///
    /// 【为什么缓冲必须自己记时间】（评审 P0-5）
    ///   窗口是不是「1/15s 等间隔」不能靠"我每帧都 push 了"来担保：
    ///   抓屏卡顿、tick 降频、应急接管 20Hz 冲刺都会改变真实间隔。
    ///   只有把入窗时刻一起存下来，才能在**发预测前**校验窗口真实跨度。
    ///   nil = 旧代码路径（自检 T1/T2 这种不关心时间的直接压栈）。
    private var frameTimestamps: [Date?]
    /// 每帧的**源帧序号**（与 hi/lo 同一物理槽位）；nil = 调用方未提供（自检压栈）。
    ///
    /// 【为什么缓冲要记序号】（评审 P0-1：重新打时间戳绕过新鲜度）
    ///   `previousFrameSequence` 存的是"最近一次**真正入窗**的源帧序号"：
    ///   上层每 tick 都会把**同一张** `currentFrameCG` 反复送进来（主线程卡住时
    ///   采集停了，但 tick 照跑）。若不加序号判定，同一张旧画面会被反复当作
    ///   "新采集帧"压入窗口 —— 窗口看似在滚动，实则同一帧重复 24 次，
    ///   伪装成一段静止视频继续参与驾驶。有了序号，`infer` 可先判"这帧是不是
    ///   已经入过窗"，重复帧直接拒绝、不滚动窗口、不刷新任何时间基准。
    private var frameSequences: [Int?]
    private var writeIndex: Int = 0
    /// 已写入帧数（用于判断是否填满 → 决定钳位填充行为）
    private(set) var filled: Int = 0
    /// 最近一次**真正入窗**的源帧序号（nil = 尚无带序号的帧）。
    ///
    /// 仅供 `infer` 判重：与 `frameSequences` 冗余存一份"当前最新"，省去每次
    /// 回查物理槽位；`reset()` 时一并清空。见 `frameSequences` 注释。
    private(set) var previousFrameSequence: Int?

    init(capacity: Int = V3InputContract.totalFrames) {
        self.capacity = max(1, capacity)
        hiStorage = Array(repeating: [Float16](repeating: 0, count: V3InputContract.hiFrameElements),
                          count: self.capacity)
        loStorage = Array(repeating: [Float16](repeating: 0, count: V3InputContract.loFrameElements),
                          count: self.capacity)
        frameTimestamps = Array(repeating: nil, count: self.capacity)
        frameSequences = Array(repeating: nil, count: self.capacity)
    }

    /// 写入一帧（覆盖最老的）。
    ///
    /// - Parameters:
    ///   - hi: 长度必须 == `hiFrameElements`
    ///   - lo: 长度必须 == `loFrameElements`
    ///   - capturedAt: 该帧的**采集时刻**；省略表示不参与时间轴校验
    ///     （自检 T1/T2 直接压栈构造窗口，不需要时间语义）。
    ///   - sequence: 该帧的**源帧序号**；省略表示不参与判重（自检直接压栈）。
    /// - Returns: 是否写入成功。长度不符时**拒绝写入**（不静默截断/补零）。
    @discardableResult
    mutating func push(hi: [Float16], lo: [Float16],
                       capturedAt: Date? = nil, sequence: Int? = nil) -> Bool {
        guard hi.count == V3InputContract.hiFrameElements,
              lo.count == V3InputContract.loFrameElements else { return false }
        hiStorage[writeIndex] = hi
        loStorage[writeIndex] = lo
        frameTimestamps[writeIndex] = capturedAt
        frameSequences[writeIndex] = sequence
        if let sequence { previousFrameSequence = sequence }
        writeIndex = (writeIndex + 1) % capacity
        if filled < capacity { filled += 1 }
        return true
    }

    /// 逻辑帧号（0 = 窗口最老，capacity−1 = 当前帧）→ 物理槽位。
    ///
    /// 未填满时：有效帧**靠尾对齐**（与 V2 的 `ImageFrameRingBuffer.snapshot()`
    /// 同一理由——index capacity−1 必须是当前帧），更早的逻辑帧钳到**最早帧**
    /// （训练侧 `clamp_frame` 语义）。
    private func physicalIndex(_ logical: Int) -> Int {
        if filled >= capacity {
            return (writeIndex + logical) % capacity
        }
        let start = capacity - filled        // 有效帧从这里开始
        guard start < capacity else { return 0 }
        if logical < start { return 0 }      // 越界回看 → 用最早帧
        return logical - start
    }

    /// 高清窗口 `[3, 3, H, W]` 的扁平数据，**新→旧**（索引 0 = 当前帧 t）。
    func hiWindow() -> [Float16] {
        var out = [Float16](repeating: 0, count: V3InputContract.hiFrames * V3InputContract.hiFrameElements)
        guard filled > 0 else { return out }
        for k in 0..<V3InputContract.hiFrames {
            // logical: capacity−1−k → t−k
            let logical = capacity - 1 - k
            let src = hiStorage[physicalIndex(logical)]
            let base = k * V3InputContract.hiFrameElements
            out.replaceSubrange(base..<(base + V3InputContract.hiFrameElements), with: src)
        }
        return out
    }

    /// 低清窗口 `[21, 3, h, w]` 的扁平数据，**新→旧**（索引 0 = t−3）。
    func loWindow() -> [Float16] {
        var out = [Float16](repeating: 0, count: V3InputContract.loFrames * V3InputContract.loFrameElements)
        guard filled > 0 else { return out }
        for k in 0..<V3InputContract.loFrames {
            // logical: capacity−1−3−k → t−3−k
            let logical = capacity - 1 - V3InputContract.hiFrames - k
            let src = loStorage[physicalIndex(logical)]
            let base = k * V3InputContract.loFrameElements
            out.replaceSubrange(base..<(base + V3InputContract.loFrameElements), with: src)
        }
        return out
    }

    /// 当前窗口首末帧的**真实采集时间差**（秒）。
    ///
    /// - Returns: 已填满且首末帧都有采集时刻 → 真实跨度；否则 nil。
    ///   未填满时窗口靠钳位填充（同一帧重复），跨度天然偏小，不具时间语义；
    ///   缺时刻（自检直接压栈）同样返回 nil，表示"无法判定"而不是"跨度合格"。
    ///
    /// 用途：发预测前校验 24 帧是否仍落在 15Hz 时间轴上（评审 P0-5）。
    ///   返回 nil 时调用方**不得**当成"没问题"——冷启动与时间未知是两回事，
    ///   判别交给调用方，比如冷启动阶段本来就允许推理。
    func windowSpanSeconds() -> TimeInterval? {
        guard filled >= capacity else { return nil }
        let newest = frameTimestamps[physicalIndex(capacity - 1)]
        let oldest = frameTimestamps[physicalIndex(0)]
        guard let newest, let oldest else { return nil }
        return newest.timeIntervalSince(oldest)
    }

    /// 清空（换场景/重开局时调用，避免上一局帧污染当前决策）。
    mutating func reset() {
        writeIndex = 0
        filled = 0
        frameTimestamps = Array(repeating: nil, count: capacity)
        frameSequences = Array(repeating: nil, count: capacity)
        previousFrameSequence = nil
    }

    /// 该源帧序号是否**已经入过窗**（判重用）。
    ///
    /// 判据只认"最近一次真正入窗的序号"：上层每 tick 送来的是同一张缓存画面时，
    /// 序号必然相同 → 返回 true → 调用方**不得**再压栈（否则窗口被同一帧刷满）。
    /// nil（调用方未提供序号，如自检直接压栈）一律当"不重复"，保持旧语义。
    func isDuplicate(sequence: Int?) -> Bool {
        guard let sequence, let previous = previousFrameSequence else { return false }
        return sequence == previous
    }
}

// MARK: - 引擎

/// V3 INT4 驾驶推理引擎（CoreML / ANE，15Hz）。
///
/// 用法与 V2 对齐：`loadIfNeeded()` → 每帧 `infer(image:...，vehicleSpeedKmh:)`
/// → 读 `lastResult` / `lastDecision`。上层无需感知模型内部表示。
@Observable
@MainActor
final class InferenceEngineV3 {

    // MARK: 状态（UI/上层可观察）

    private(set) var isLoaded = false
    /// 模型加载/推理错误（如实记录，不静默吞掉）
    private(set) var errorMessage: String?
    /// 最近一次**有效**推理结果（控制链路消费）
    private(set) var lastResult: InferenceResult?
    private(set) var lastResultTime: Date?
    /// 最近一次有效决策（刹车头/置信度/风险）
    private(set) var lastDecision: V3Decision = .idle
    /// 累计成功推理帧数
    private(set) var inferenceCount = 0

    /// 已攒到的有效帧数（冷启动进度，诊断用）
    private(set) var timelineFrames = 0
    /// 窗口是否已有至少一帧可直接推理。
    ///
    /// 与 V2 的 `timelineReady`（≥2 帧）不同：V3 训练侧对历史不足是**钳位到
    /// 最早帧**（`clamp_frame`），故 1 帧即可推理，不需要等攒满。
    var timelineReady: Bool { timelineFrames >= 1 }
    /// 窗口填充比例 ∈ [0,1]
    var timelineFillRatio: Double {
        Double(timelineFrames) / Double(max(1, V3InputContract.totalFrames))
    }

    var timelineDebugSummary: String {
        "V3 窗口 \(timelineFrames)/\(V3InputContract.totalFrames)"
            + (timelineReady ? " 就绪（历史不足按最早帧填充）" : " 冷启动中")
    }

    /// PerfBus 通道名
    nonisolated var perfChannel: String { "infer.\(V3InputContract.modelFileName)" }

    // MARK: 内部状态

    /// 推理队列（串行）：只做「组装 provider → 预测 → 解析」。
    private let queue = DispatchQueue(label: "aurora.infer.v3", qos: .userInitiated)
    /// 采集队列（串行）：只做「预处理 → 入窗 → 攒窗口快照」。
    ///
    /// 【为什么必须与推理队列分开】（评审 P0-5 的核心）
    ///   旧实现里这两件事都在 `queue` 的同一个任务里，且被 `isInferencing`
    ///   这道门整体挡住 —— 于是在途预测一慢，新帧连**预处理和入窗**都不做。
    ///   历史按"预测成功次数"滚动，而不是按采集节拍滚动：
    ///   24 帧名义 1.6s，实际可张到 3.2s，而模型无从察觉。
    ///   拆开之后：入窗永远跟着采集走（受有界背压保护），预测可以跳过。
    private let captureQueue = DispatchQueue(label: "aurora.capture.v3", qos: .userInitiated)

    @ObservationIgnored private nonisolated(unsafe) var model: MLModel?
    /// 帧缓冲：只在 `captureQueue` 上访问
    @ObservationIgnored private nonisolated(unsafe) var frameBuffer = V3FrameRingBuffer()
    /// 复用的输入缓冲（形状固定，一次分配长期复用，避免每帧 3MB 级分配）。
    /// 只在推理队列 `queue` 上访问（`makeProvider` / `ensureBuffers` / `warmUp`）。
    @ObservationIgnored private nonisolated(unsafe) var bufferHi: MLMultiArray?
    @ObservationIgnored private nonisolated(unsafe) var bufferLo: MLMultiArray?
    @ObservationIgnored private nonisolated(unsafe) var bufferLane: MLMultiArray?
    @ObservationIgnored private nonisolated(unsafe) var bufferDets: MLMultiArray?
    @ObservationIgnored private nonisolated(unsafe) var bufferDetMask: MLMultiArray?
    @ObservationIgnored private nonisolated(unsafe) var bufferState: MLMultiArray?

    /// 在途预测所属的代数（nil = 空闲可发起预测）。
    ///
    /// ⚠️【它只负责预测调度，不负责入窗】（评审 P0-5）
    ///   非 nil 时：本帧照常入窗，只是不再发起第二次预测。
    /// 【为什么访问点全在 MainActor、无需锁】发起（`infer` 的
    ///   `Task { @MainActor }` + `beginPrediction`）、释放（`finish`）、
    ///   清空（`invalidateResultsForModelSwap`）三处都在主线程；
    ///   采集队列只**投递**主线程任务，自身不碰这个字段。
    ///   故 `@MainActor` 隔离已足够，额外加锁是无效复杂度。
    /// 【为什么还要记代数】`reset`/`reload` 会强行清空槽位；若旧任务随后
    ///   完成并"释放"，就会把**新任务**刚占到的槽位放掉 → 两个预测并发。
    ///   故释放时只认自己那一代（`activePredictionGeneration == gen`）。
    private var activePredictionGeneration: Int?
    /// 代数：`reset` / `reloadModel` 时自增，用于丢弃过期的异步回调。
    ///
    /// 【统一出口】（评审 P1-2）重置与热重载**共用**这一套机制：
    ///   旧任务的回调用旧代数登记，重载后代数已变 → 结果一律不发布。
    ///   旧任务可以自然跑完（不强行取消 ANE 调用），只是白算一次。
    private var generation = 0
    /// 因过载跳过预测的帧数（画面**已入窗**，只是没算）。诊断用。
    private(set) var skippedPredictionCount = 0
    /// 因「同一源帧被重复提交」而拒绝入窗的次数。诊断用（P0-1）。
    ///
    /// 正常 15Hz 巡航下应恒为 0：每 tick 一张新画面、序号单调递增。
    /// 一旦持续增长，说明上层在拿同一张缓存画面反复推理（采集停了 / 主线程卡顿），
    /// 这正是旧实现"旧图被反复当新帧入窗"的那类故障，现在被如实计数而非静默吸收。
    private(set) var duplicateFrameCount = 0
    /// 窗口重建次数（断层/超跨度触发）。诊断用；正常 15Hz 巡航下应恒为 0。
    private(set) var windowRebuildCount = 0
    /// 上一次加载尝试时间（失败冷却，避免每帧重试刷屏）
    private var lastLoadAttempt = Date(timeIntervalSince1970: 0)
    private let loadRetryCooldown: TimeInterval = 5.0

    /// 真实采集间隔超过该值即判为「断层」（秒）。
    ///
    /// 0.5s ≈ 15Hz 下的 7.5 帧：正常抖动远小于它（同机实测 tickGap 67~70ms），
    /// 而抓屏暂停/切后台会远超它。注意它**只**拦"长暂停"，
    /// "隔帧丢帧"（约 0.133s 间隔）靠窗口真实跨度校验拦截（见 captureFrame）。
    private static let frameGapResetSeconds: TimeInterval = 0.5

    /// 上一帧**入窗**的时刻（只用于检测时间断层；仅 `captureQueue` 上访问）。
    ///
    /// ⚠️【必须加 `@ObservationIgnored`】—— 这是本文件唯一一处实测崩溃点：
    ///   不加该属性时，`@Observable` 宏会把它包成**带观察器**的 `_lastFrameAt`
    ///   （内部是 `_ManagedCriticalState`）。而后台队列 `aurora.infer.v3`
    ///   每帧读写它 → 在观察器状态上访问到坏内存。
    ///   实测现象：`--v3-integration` 稳定 `exit=139`（SIGSEGV，两次复现）。
    ///   lldb 停位：
    ///     thread #10/14, queue='aurora.infer.v3', EXC_BAD_ACCESS
    ///     frame #0 libswiftObservation`_ManagedCriticalState.withCriticalRegion + 44
    ///   编译器当时已给出警告「'nonisolated(unsafe)' has no effect on property
    ///   'lastFrameAt'」，被忽略 —— 那个警告正是本问题的提示。
    ///   本类其余后台访问属性（model / frameBuffer / bufferHi…bufferState）
    ///   都带此标记，此处补齐后与它们一致。
    @ObservationIgnored private nonisolated(unsafe) var lastFrameAt: Date?

    /// 上一帧的横向决策类别（供下一帧 `vehicle_state[6]` = t−1 转向指令）
    private var previousHorizontalClass = 1

    // MARK: 模型路径

    /// `models/v3_int4.mlmodelc`
    private static var modelURL: URL {
        AuroraPaths.projectRoot()
            .appendingPathComponent("models")
            .appendingPathComponent("\(V3InputContract.modelFileName).mlmodelc")
    }

    init() {
        // 预热由 loadIfNeeded 负责（与 V2 一致：延迟到首次 tick，避免启动卡顿）
    }

    // MARK: 加载

    /// 懒加载模型（幂等；失败后按冷却间隔重试）。
    ///
    /// 失败**不静默降级**：只记录 `errorMessage` 并保持 `isLoaded = false`，
    /// 由上层如实报错（用户明确要求硬切 V3、不做自动降级）。
    func loadIfNeeded() {
        guard !isLoaded else { return }
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()

        let url = Self.modelURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "V3 模型未就绪：models/\(V3InputContract.modelFileName).mlmodelc 不存在"
            return
        }

        let cfg = MLModelConfiguration()
        // ANE 优先：同一 INT4 模型实测 ANE 4.80ms vs CPU 21.75ms / GPU 18.62ms
        cfg.computeUnits = .cpuAndNeuralEngine

        do {
            let loaded = try MLModel(contentsOf: url, configuration: cfg)
            self.model = loaded
            self.isLoaded = true
            self.errorMessage = nil
            warmUp(model: loaded, generation: generation)
            print("[v3] 模型加载成功：\(url.lastPathComponent)（INT4 / ANE）")
        } catch {
            // 如实上报底层原因，并补上本层上下文（便于定位是路径/权限/模型损坏）
            errorMessage = "V3 模型加载失败（\(url.lastPathComponent)）："
                + (error as NSError).localizedDescription
            print("[v3] 加载失败：\(errorMessage ?? "-")")
        }
    }

    /// 预热：跑一次全零输入，让 ANE 编译计算图，避免首帧卡顿。
    ///
    /// - Parameter generation: 发起加载时的代数。热重载后旧预热即使失败，
    ///   也不得把"上一代模型"的错误写到当前 `errorMessage` 上（评审 P1-2）。
    private func warmUp(model: MLModel, generation gen: Int) {
        // 先把 model 复制成局部常量再进闭包：MLModel 非 Sendable，
        // 直接捕获 `self.model` 会在 Swift 6 下触发 sendable 捕获警告/竞争。
        let modelRef = model
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureBuffers()
            guard let provider = self.makeZeroProvider() else {
                Task { @MainActor in self.finishWarmUp(gen, error: "V3 预热失败：零输入构造失败") }
                return
            }
            do {
                _ = try modelRef.prediction(from: provider)
                Task { @MainActor in self.finishWarmUp(gen, error: nil) }
            } catch {
                let msg = "V3 预热失败：" + (error as NSError).localizedDescription
                Task { @MainActor in self.finishWarmUp(gen, error: msg) }
            }
        }
    }

    /// 预热结果回写（主线程，带代次校验）。
    ///
    /// 【为什么预热也要校验代数】（评审 P1-2）
    ///   热重载时旧模型的预热可能还在跑；若它失败并把 `errorMessage` 写成
    ///   "旧模型预热失败"，UI 会显示一个与新模型无关的错误，掩盖真实状态。
    private func finishWarmUp(_ gen: Int, error: String?) {
        guard gen == generation else { return }
        if let error {
            errorMessage = error
            print("[v3] \(error)")
        } else {
            print("[v3] 预热完成")
        }
    }

    /// 结果失效：`reset()` 与 `reloadModel()` **共用**的唯一出口（评审 P1-2）。
    ///
    /// 【为什么必须共用】两件事的安全要求完全相同：
    ///   1) 在途任务可能持有**旧模型/旧场景**，其输出一律不得发布；
    ///   2) 上层读到的 `lastResult` / `lastResultTime` / `lastDecision`
    ///      必须立刻作废，不能等下一帧覆盖（否则会拿旧模型的决策继续开车）。
    ///   之前只有 `reset()` 做了代数自增和清理，`reloadModel()` 漏了 ——
    ///   旧任务完成回调只校验 `generation`，于是旧输出被当成新模型的结果发布。
    ///
    /// 【为什么还要清 `lastResultTime`（而不是保留它让上层自然过期）】
    ///   这里与 P0-5 的重建期不同：重建只是**窗口历史**不可用，最后一次决策
    ///   仍来自同一模型，保留时间戳让它在 1s 后自然过期是合理的；
    ///   而重载意味着**模型换了**，旧模型的输出不再有代表性，必须立刻失效
    ///   （清 nil → 上层的 `map { ... } ?? false` 立刻判不新鲜 → 当帧停控）。
    ///
    /// 【为什么仍投递到采集队列清窗】`frameBuffer` 只在 `captureQueue` 上访问；
    ///   排在队尾执行可保证"旧任务跑完 → 再清"，不会与在途 push 竞争。
    private func invalidateResultsForModelSwap() {
        generation += 1
        lastResult = nil
        lastResultTime = nil
        lastDecision = .idle
        timelineFrames = 0
        previousHorizontalClass = 1
        // 释放预测槽位：旧任务即使后续完成，也因代数不符而不会误释放新槽位。
        activePredictionGeneration = nil
        captureQueue.async { [weak self] in
            self?.frameBuffer.reset()
            self?.lastFrameAt = nil
        }
    }

    /// 强制重新加载（热替换模型时调用）。
    ///
    /// 【语义】（评审 P1-2）与 `reset()` 共用 `invalidateResultsForModelSwap()`：
    ///   · 代数自增 → 在途的旧模型任务自然跑完但**不发布**结果；
    ///   · `lastResult/lastResultTime/lastDecision` 立刻清空 → 新模型首个合格
    ///     输出落地之前，上层 `v3CommandOf` / `v3DecisionFresh` 全部判不新鲜
    ///     → 当帧退化为 `.idle`（停控），不会出现"旧模型的决策继续执行"。
    func reloadModel() {
        invalidateResultsForModelSwap()
        isLoaded = false
        model = nil
        lastLoadAttempt = Date(timeIntervalSince1970: 0)
        errorMessage = nil
        loadIfNeeded()
    }

    /// 记录**上一帧实际执行**的横向动作（A→−1 / D→+1 / 其余 0）。
    ///
    /// 【为什么需要这个入口】（评审 P1-1，已确认为真）
    ///   训练侧 `vehicle_state[6]` 取自**上一帧真实按下的 A/D**：
    ///   `src/dataset_v3.py:630-638` 读的是上一帧 `controls.csv` 的 a/d 位
    ///   ——那是**实际执行**的键，不是"模型当时想按什么"。
    ///   而本引擎原先存的是上一帧的**预测**类别（`previousHorizontalClass`），
    ///   两者在下列场景会分叉：
    ///     · 限速刹车：策略会主动 `release(.steerLeft/.steerRight)`（覆盖预测）
    ///     · 人工接管：`releaseAll()` 松掉 AI 键
    ///     · 降档：`.yolo`/`.rule` 用别的驾驶策略产出动作
    ///   → 模型看到的"上一动作"与训练分布不一致，属输入口径漂移。
    ///   由上层（真正知道执行了什么的一方）在注入完成后回填，
    ///   即可与训练口径对齐。传 0 表示"本帧没有横向动作"。
    func noteExecutedSteer(_ steer: Double) {
        if steer < -0.1 {
            previousHorizontalClass = 0        // A
        } else if steer > 0.1 {
            previousHorizontalClass = 2        // D
        } else {
            previousHorizontalClass = 1        // NONE
        }
    }

    // MARK: - 测试专用只读观测入口（仅为测试可观测性，无生产行为）
    //
    // ══════════════════════════════════════════════════════════════════════════
    // 【为什么必须补这两个入口】`previousHorizontalClass → vehicle_state[6]` 这条
    //   链的每一个环节都是私有的：
    //     · 起点 `previousHorizontalClass`（:499）是 `private var`；
    //     · 终点 `statePtr[V3InputContract.steerStateIndex]` 的赋值发生在
    //       `makeProvider()`（:1190）内部，写进 `bufferState`（:440）后直接交给
    //       CoreML，外部无从读取。
    //   后果：若 A/D→0/2 的映射被写反（-1/1 对调），或 `finish()` 用**预测**覆盖
    //   了**实际执行**的值，现有 41 项自检**没有任何一项会报警** —— 它们只做
    //   源码字符串匹配，重构后照样全绿。
    //
    // 【安全性（三条约定的逐条兑现）】
    //   ① **纯读**：两个入口都只读取，不写任何字段、不触发推理、不改判定分支；
    //   ② **不改模型输入构造逻辑**：`makeProvider` 一行未动，`vehicle_state`
    //      的写入仍只有原来那一处 —— 本入口只是把已经写好的缓冲读出来；
    //   ③ **不改生产行为**：生产代码路径不会调用这两个入口（全仓调用点仅
    //      `V3EngineSelfTest.swift`），无副作用、无额外分配。
    //
    // 【为什么用 `queue.sync` 而不是直接读】`bufferState` 只在推理队列 `queue`
    //   上被 `makeProvider` 写（:1190 的注释）。从 MainActor 直接读会与在途
    //   推理构成无同步的读写竞争。`queue.sync` 等价于"等到队列空"，读到的必定
    //   是**已完成**的那一份；`queue` 是独立串行队列、本函数只在主线程被调用，
    //   故不会死锁。
    // ══════════════════════════════════════════════════════════════════════════

    /// 测试专用：读回**最近一次真正送进模型**的 `vehicle_state` 向量（长度 8，FLOAT16→Float）。
    ///
    /// 未推理过（`bufferState == nil`）时返回空数组 —— 由调用方明确判空，
    /// **不要**当成"全零"（那会把"没观测到"误判成"观测到 0"）。
    func vehicleStateForTest() -> [Float] {
        queue.sync {
            guard let buf = bufferState else { return [] }
            return (0..<V3InputContract.stateDim).map { buf[$0].floatValue }
        }
    }

    /// 测试专用：读回执行反馈状态 `previousHorizontalClass`（0=A / 1=NONE / 2=D）。
    ///
    /// 用于行为级断言 `finish()` **不得**用预测值覆盖它（评审 P0-3）。
    var previousHorizontalClassForTest: Int { previousHorizontalClass }

    /// 重置：清帧缓冲与冷启动状态（换场景/重开一局）。
    ///
    /// ⚠️【缓冲清理必须回到串行队列做，不能在这里直接改】（评审 P0-2）
    ///   `frameBuffer` 的 `push` / `filled` / `hiWindow` / `loWindow` 全在
    ///   `captureQueue` 上执行；而 `reset()` 是 MainActor。若在此直接
    ///   `frameBuffer.reset()`，就会与在途采集任务构成**无同步的读写竞争**。
    ///   即使侥幸没撞上，还存在确定的逻辑反例：
    ///     在途任务正预处理 → 主线程清索引 → 在途任务随后 push →
    ///     finish 被 generation 丢弃 → **下次启动却读到上一局写入的帧**。
    ///   改成把 reset 投递到同一串行队列后，FIFO 顺序天然保证：
    ///     在途任务先跑完 → 再清窗 → 之后的新任务才入队。
    ///   MainActor 侧的状态（generation/结果/标志）仍在此同步清理，
    ///   因为 finish() 的代数校验保证过期回调不会再写回。
    ///
    /// 【与 reload 共用失效出口】（评审 P1-2）两者都用
    ///   `invalidateResultsForModelSwap()`，避免"改了一处漏了另一处"。
    func reset() {
        invalidateResultsForModelSwap()
        // 清掉上一局的错误信息：否则 UI 会出现"已经重新开始了，还在报上次的错"。
        // （对照 `InferenceEngineV2.reset()` 也有 errorMessage = nil）
        errorMessage = nil
    }

    // MARK: 主推理入口

    /// 触发一帧（异步，立即返回）：**采集入窗**与**预测调度**在此分道。
    ///
    /// - Parameters:
    ///   - image: 本帧画面（全分辨率截图，内部会缩放出 hi/lo 两种分辨率）
    /// 注：本函数**不接收车速**。V3 的 `vehicle_state` 里速度维按训练口径
    ///   恒为 0（见文件头红线 3），**不要**擅自把车速填进 state —— 那会破坏
    ///   训练分布（`dataset_v3.py:624` 明确记录过这个陷阱）。
    ///
    /// 【P0-5 核心：两条时间轴分离】
    ///   旧实现把"预处理 + 入窗 + 预测"塞进同一个被 `isInferencing` 挡住的任务：
    ///   在途预测一慢，本帧连历史都进不去 → 24 帧窗口按**预测成功次数**滚动，
    ///   实测可低到 7.5Hz（窗口张成 3.2s），而模型无从察觉。
    ///   现在：
    ///     · **入窗**：无条件投递到 `captureQueue`，按采集节拍推进（采集时刻入档）；
    ///     · **预测**：仅当没有在途预测时发起，慢了就跳过本帧（不排队）。
    ///   预测可以跳过，历史不会。
    ///
    /// 【为什么不需要"积压上限/丢帧"机制】`captureQueue` 是串行队列，
    ///   `infer()` 每 tick 最多投递一个采集任务，且入窗本身只做两次缩略图
    ///   绘制（~几 ms）—— 正常 15Hz 下队列恒为空，不存在可积压的对象。
    ///   真正的过载表现为"预测跳过"（有 `skippedPredictionCount` 诊断），
    ///   而不是采集堆积。故按项目纪律不引入额外背压抽象。
    ///
    /// - Parameters:
    ///   - image: 本帧画面。
    ///   - capturedAt: 该帧**真实采集时刻**（不是本函数被调用的时刻）。
    ///     nil = 调用方无采集时刻语义（自检直接喂图），退回"调用即采集"。
    ///     【为什么必须由外部传入】（评审 P0-1）旧实现用 `Date()` 当采集时刻，
    ///     主线程一卡顿，恢复后送进来的**旧画面**会被重新贴上"此刻"的新鲜标签，
    ///     绕过新鲜度门控继续开车。传入真实采集时刻后，画面越旧结果越早过期。
    ///   - sequence: 该帧的**源帧序号**（单调递增）。同一序号重复送入 = 同一张画面
    ///     被再次提交（主线程卡顿时采集停了、tick 照跑）→ 直接拒绝入窗，
    ///     避免"一帧旧画面重复入窗把窗口刷成静止视频"。
    func infer(image: CGImage, capturedAt: Date? = nil, sequence: Int? = nil) {
        guard isLoaded, model != nil else {
            loadIfNeeded()
            return
        }

        let gen = generation
        // 跨线程只传值：previousHorizontalClass 是 MainActor 状态，
        // 必须在派发前快照，否则后台闭包读它会构成数据竞争。
        let prevHorizontal = previousHorizontalClass
        // 【P0-1】采集时刻一律取外部真值；只有调用方没给（自检）才退回调用时刻。
        let captureAt = capturedAt ?? Date()
        captureQueue.async { [weak self] in
            guard let self else { return }
            // ① 判重（P0-1）：同一源帧不得重复当作"新采集帧"入窗。
            //   在预处理之前就拦掉——既省两次缩略图绘制，也保证窗口不被同一帧刷满。
            if self.frameBuffer.isDuplicate(sequence: sequence) {
                Task { @MainActor in self.noteDuplicateFrameSkipped() }
                return
            }
            // ② 预处理两种分辨率（放在采集队列：与预测延迟彻底解耦）
            guard let hi = Self.renderNormalized(image, height: V3InputContract.hiHeight,
                                                 width: V3InputContract.hiWidth),
                  let lo = Self.renderNormalized(image, height: V3InputContract.loHeight,
                                                 width: V3InputContract.loWidth) else {
                Task { @MainActor in self.reportCaptureFailure(gen, error: "V3 图像预处理失败") }
                return
            }
            // ③ 时间断层保护：真实采集间隔超阈值 → 旧窗口作废，本帧作新窗口首帧。
            if let last = self.lastFrameAt,
               captureAt.timeIntervalSince(last) > Self.frameGapResetSeconds {
                self.frameBuffer.reset()
                print("[v3] 帧间隔 \(String(format: "%.2f", captureAt.timeIntervalSince(last)))s"
                      + " 超阈值 \(Self.frameGapResetSeconds)s，已清窗重建")
                Task { @MainActor in self.noteWindowRebuild() }
            }
            self.lastFrameAt = captureAt

            guard self.frameBuffer.push(hi: hi, lo: lo,
                                        capturedAt: captureAt, sequence: sequence) else {
                Task { @MainActor in self.reportCaptureFailure(gen, error: "V3 帧长度不符，拒绝写入") }
                return
            }

            // ③ 窗口时间轴校验（P0-5）：把"24 帧 = 1.533s"从假设变成**验证过的事实**。
            //
            // 三种情况的处理（明确策略，不留隐式行为）：
            //   · nil  → 窗口未填满（冷启动钳位填充）或时间戳缺失 → 冷启动放行。
            //     依据：训练侧 `clamp_frame = max(0, fi)`（`dataset_v3.py:555`）本来就
            //     允许历史不足时用最早帧填充，与 `timelineReady`（≥1 帧）一致；
            //     此处若"等攒满再推理"，冷启动会黑障 1.6s，且掩盖真实的推理故障。
            //   · ≤ 上限 → 正常推理（含 20Hz 冲刺：跨度更小，同样合法）。
            //   · ＞ 上限 → **重建窗口**：清窗、本帧作新窗口首帧，然后**正常推理**。
            //     依据：跨度超限意味着这 24 帧覆盖的时间比训练分布长 50% 以上
            //     （≈10Hz 以下），这批历史的时间尺度已经失真，不能再用；
            //     但清窗后本帧是唯一真实帧，等同于"冷启动第 1 帧"，按上面的
            //     clamp 规则本就允许推理 —— 发布基于单帧的决策，与刚启动时同级。
            //     ⚠️ 不做"重建期停预测"：那会让车辆在 1.6s 内无新决策，
            //     而证据（`--v3-integration` 的 P0-1 反证段）表明这会把
            //     一个 1.36s 的停喂放大成整段推理停摆，得不偿失。
            if let span = self.frameBuffer.windowSpanSeconds(),
               span > V3InputContract.maxWindowSpanSeconds {
                let ratio = span / V3InputContract.nominalWindowSpanSeconds
                self.frameBuffer.reset()
                _ = self.frameBuffer.push(hi: hi, lo: lo,
                                          capturedAt: captureAt, sequence: sequence)
                print(String(format: "[v3] 窗口跨度 %.2fs（名义 %.2fs 的 %.1f 倍）超上限 %.2fs，已重建窗口",
                             span, V3InputContract.nominalWindowSpanSeconds, ratio,
                             V3InputContract.maxWindowSpanSeconds))
                Task { @MainActor in self.noteWindowRebuild() }
            }

            // ④ 预测调度：仅在无在途预测时发起（单飞）。历史已入窗，此处跳过不影响时间轴。
            let capturedFrames = self.frameBuffer.filled
            let windowHi = self.frameBuffer.hiWindow()
            let windowLo = self.frameBuffer.loWindow()
            let captureMoment = captureAt
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard gen == self.generation else { return }
                guard self.beginPrediction(generation: gen) else {
                    self.skippedPredictionCount += 1
                    return
                }
                let modelRef = self.model
                self.queue.async { [weak self] in
                    guard let self else { return }
                    let start = Date()
                    // ⑤ 组装输入 provider（缓冲只在推理队列上访问）
                    guard let provider = self.makeProvider(hi: windowHi, lo: windowLo,
                                                           prevHorizontalClass: prevHorizontal) else {
                        Task { @MainActor in self.finish(gen, decision: nil, error: "V3 输入构造失败") }
                        return
                    }
                    // ⑥ 推理
                    let output: MLFeatureProvider
                    do {
                        guard let modelRef else {
                            Task { @MainActor in self.finish(gen, decision: nil, error: "V3 模型已卸载") }
                            return
                        }
                        output = try modelRef.prediction(from: provider)
                    } catch {
                        let msg = "V3 推理失败：" + (error as NSError).localizedDescription
                        Task { @MainActor in self.finish(gen, decision: nil, error: msg) }
                        return
                    }
                    // ⑦ 解析输出
                    guard let decision = Self.parseDecision(output) else {
                        // 输出缺失/NaN → 跳过该帧（不污染上次有效结果）
                        Task { @MainActor in self.finish(gen, decision: nil, error: "V3 输出非法（缺失或 NaN）") }
                        return
                    }
                    let ms = Date().timeIntervalSince(start) * 1000
                    // ⑧ 回主线程写状态（带代数 + 采集时刻）
                    Task { @MainActor in
                        self.finish(gen, decision: decision, error: nil,
                                    filled: capturedFrames, latencyMs: ms,
                                    capturedAt: captureMoment)
                    }
                }
            }
        }
    }

    /// 尝试占用在途预测槽位（单飞）。
    ///
    /// - Returns: 占用成功为 true；已有预测在飞则为 false（调用方只计数、不排队）。
    private func beginPrediction(generation gen: Int) -> Bool {
        guard activePredictionGeneration == nil else { return false }
        activePredictionGeneration = gen
        return true
    }

    /// 释放在途预测槽位；**只释放自己那一代**。
    ///
    /// 若 `reset`/`reload` 已把槽位清空并由新任务重新占用，旧任务完成时
    /// 代数不符 → 不动槽位，避免"旧任务放掉新任务的锁"导致双飞。
    private func endPrediction(generation gen: Int) {
        if activePredictionGeneration == gen {
            activePredictionGeneration = nil
        }
    }

    /// 采集侧失败回报（预处理失败/长度不符）。**不占用预测槽位**，故只报错。
    private func reportCaptureFailure(_ gen: Int, error: String) {
        guard gen == generation else { return }
        errorMessage = error
        print("[v3] \(error)")
    }

    /// 窗口重建计数（主线程侧，供 UI/诊断；采集队列只做自增的本地计数）。
    ///
    /// 说明：`windowRebuildCount` 声明为 MainActor 属性，采集队列上的自增
    /// 会违反隔离，故统一在主线程累加。
    private func noteWindowRebuild() {
        windowRebuildCount += 1
    }

    /// 重复源帧被跳过（主线程侧累加；与 `noteWindowRebuild` 同一理由——
    /// 属性是 MainActor 的，采集队列只投递主线程任务）。
    ///
    /// 【为什么必须计数而不是静默 return】这是"采集停摆"的**唯一可观测信号**：
    ///   旧画面被反复提交时，推理次数不再增长、`lastResultTime` 不再刷新，
    ///   若没有这个计数，日志上看起来就像"什么都没发生"。有了它才能区分
    ///   「模型慢」与「根本没有新画面」。
    private func noteDuplicateFrameSkipped() {
        duplicateFrameCount += 1
    }

    // MARK: 结果回写（主线程）

    /// - Parameters:
    ///   - capturedAt: 该预测所用窗口**最新帧的采集时刻**（不是完成时刻，见 P0-5）。
    private func finish(_ gen: Int, decision: V3Decision?, error: String?,
                        filled: Int = 0, latencyMs: Double = 0,
                        capturedAt: Date? = nil) {
        endPrediction(generation: gen)
        guard gen == generation else { return }   // 已 reset/reload，丢弃过期结果

        if let decision {
            timelineFrames = filled
            lastDecision = decision
            // 分类 → 连续量：让既有 applyCommand 的死区/互斥逻辑原样生效
            //
            // ⚠️【ultimate 必须强制纵向为 S】（评审 P0-4）
            //   训练标签（`src/dataset_v3.py:686`）：
            //     ultimate = shift ∧ space ∧ s   —— **蕴含 vertical=S**
            //   但 `ultimate` 与 `vertical` 是两个**独立输出头**
            //   （`src/model_v3.py` 各自产生，彼此没有结构约束），
            //   模型完全可能同时给出 `vertical=W` 与 `ultimate=1`。
            //   若照原样映射，就会产生「踩油门 + 手刹 + 空格」这个致命组合 ——
            //   最强制动意图反而保留了加速。
            //   故在此把 ultimate 视为对纵向的强制覆盖：松油门、按 S。
            //   （四个刹车头在 App 侧由 `applyV3BrakeHeads` 负责 Shift/Space，
            //     本函数只负责纵向/横向两路连续量。）
            let verticalForCommand = decision.ultimatePressed ? 2 : decision.verticalClass
            let result = InferenceResult(
                steer: Self.steerValue(for: decision.horizontalClass),
                throttle: verticalForCommand == 0 ? 1.0 : 0.0,
                brake: verticalForCommand == 2 ? 1.0 : 0.0,
                latencyMs: latencyMs)
            lastResult = result
            // ⚠️【结果时效取**采集时刻**，不是完成时刻】（评审 P0-5）
            //   上层用 `Date().timeIntervalSince(lastResultTime) < 1.0` 判新鲜
            //   （`AuroraDriveApp.swift` 的 `v3CommandOf` / `v3DecisionFresh` /
            //   `isAliveV3`）。旧代码写 `Date()`（完成时刻），推理一旦排队或
            //   降频，完成时刻会把"其实已经几秒前的画面"刷成新鲜 —— 等于用
            //   旧图继续开车。改用窗口最新帧的采集时刻后，画面越旧结果越早过期。
            //   方向安全性：采集时刻恒 ≤ 完成时刻 → 门控只会**更严**（更早判过期），
            //   不会把过期结果误判为新鲜。正常 15Hz 下采集→完成仅数十 ms，
            //   相对 1.0s 阈值余量充足，不会误伤。
            //   `capturedAt` 为 nil 时（仅测试钩子直接调 finish 的情形）退回完成时刻。
            lastResultTime = capturedAt ?? Date()
            inferenceCount += 1
            // ⚠️【这里绝不能写 previousHorizontalClass】（评审 P0-3，已逐行确认为真）
            //   该字段是 `vehicle_state[6]` 的来源，训练侧（`dataset_v3.py:630-638`）
            //   要求它等于**上一帧实际按下的 A/D**，由 `noteExecutedSteer()` 在注入后回填。
            //   若在此处再写一次预测值，会产生确定的覆盖序列：
            //     tick n 派发推理 → 读取了当时的执行状态
            //     tick n 注入阶段 → noteExecutedSteer() 回填**实际**动作（正确）
            //     tick n 之后 → 本行用**预测**覆盖掉刚回填的实际动作（错误）
            //     tick n+1 → 读到的是"刚算完、尚未执行的预测"，不是"上一周期实际执行的"
            //   即：正常异步调度下就会漂移，不是并发问题、@ObservationIgnored 也修不了。
            //   预测值只用于输出发布，不得写回执行反馈。
            PerfBus.shared.record(perfChannel, ms: latencyMs)
        }
        if let error {
            // 保留上一次 errorMessage 更利于定位；这里如实覆盖为最新一次失败原因
            errorMessage = error
            print("[v3] \(error)")
        } else {
            errorMessage = nil
        }
    }

    // MARK: 分类 → 连续量映射

    /// 横向类别 → steer（A→−1，NONE→0，D→+1）。
    ///
    /// 取 ±1 而非中间值：`applyCommand` 的死区是 ±0.1，±1 必然越过死区，
    /// 语义与训练标签（A/D 是离散按键）一致。
    nonisolated static func steerValue(for horizontalClass: Int) -> Double {
        switch horizontalClass {
        case 0: return -1.0   // A
        case 2: return 1.0    // D
        default: return 0     // NONE
        }
    }

    // MARK: 防侧翻兜底（引擎侧，P0-2）

    /// 防侧翻触发车速阈值（km/h）。取训练侧 `L_rollover` 权重的**斜坡上界** `v_high`。
    ///
    /// 【为什么是 30 km/h，且取 v_high 而不是 v_low】（评审 P0-2）
    ///   训练侧 `src/model_v3.py:1476-1477` 把侧翻惩罚权重写成
    ///   `w(speed)=clamp((speed−v_low)/(v_high−v_low),0,1)`，默认
    ///   `v_low=20 / v_high=30`：速度 ≥30km/h 时权重才到满值 1.0。
    ///   生产端要做的是"该受约束的区间**不漏**"，故以 `v_high`（满权起点）为硬阈值：
    ///   低于它时训练侧本身也只给部分/零权重，生产端不额外加码，避免低速解锁时误伤。
    ///   若要更保守可调低，但**不得**高于 30（否则 25~30 这段训练的满额约束在线上被放空）。
    static let rolloverGuardSpeedKmh: Double = 30.0

    /// 防侧翻兜底：在**最终物理键集合**上约束「高速按超级刹车必须伴随 S」。
    ///
    /// 【要堵的那个洞】（评审 P0-2，已逐行确认为真）
    ///   训练侧 `L_rollover` 已改成「只在真实减速时生效」（`src/model_v3.py` 的
    ///   `decel_ok` 门）。副作用：「高速准备发 Shift+Space 但**还没有** S」这种
    ///   **首次急刹的起始段**不再受约束。而生产端原先只对 `ultimate` 强制 S
    ///   （`finish()` 里 `verticalForCommand`），`applyV3BrakeHeads` 仍允许
    ///   Shift+Space 与 W/NONE 同时成立 —— 即"高速一脚 Shift+Space、却没踩 S"，
    ///   正是侧翻那一脚。本函数在**执行前**把它兜住。
    ///
    /// 【约束语义】`superBrakePressed || ultimatePressed`（需要 Shift+Space）
    ///   且车速已知且 > 阈值 → 纵向必须是 S（`brake=1, throttle=0`），不许同时给油。
    ///   横向与四个刹车头（Shift/Space）本身不改，只压纵向这一维。
    ///
    /// 速度未知并不等于高速：OCR 丢读时强制 S 会新增模型未要求的刹车/倒车。
    /// 安全折中：只松油门，保留模型原 brake（不解除模型 S/ultimate，也不新增 S）。
    /// 已知高速保护不变；AURORA_ROLLOVER_UNKNOWN_BRAKE=1 恢复旧保守策略。
    /// V3 没有独立绕障动作；绕障能力须由真人样本训练，不能靠本兜底补造。
    ///
    /// - Parameters:
    ///   - command: 即将执行的纵向/横向连续量（会被拷贝，原值不改）。
    ///   - decision: 本帧决策（看 super/ultimate 触发）。
    ///   - speedKmh: 车速；nil 或非有限 = 未知。
    ///   - speedValid: 车速是否可信（false 同样按未知处理）。
    /// - Returns: 兜底后的命令；未触发约束时原样返回（值等价，便于日志判断是否生效）。
    nonisolated static func applyRolloverGuard(to command: ControlCommand,
                                               decision: V3Decision,
                                               speedKmh: Double?,
                                               speedValid: Bool,
                                               unknownSpeedBrake: Bool = AuroraFlags.rolloverUnknownBrake) -> ControlCommand {
        // 只有「需要 Shift+Space」的动作才可能侧翻；其余路径一字不动。
        guard decision.superBrakePressed || decision.ultimatePressed else { return command }

        let isHighSpeed: Bool
        if let speedKmh, speedValid, speedKmh.isFinite {
            isHighSpeed = speedKmh > rolloverGuardSpeedKmh
        } else {
            var guarded = command
            guarded.throttle = 0
            if unknownSpeedBrake { guarded.brake = 1 }
            return guarded
        }
        guard isHighSpeed else { return command }

        var guarded = command
        guarded.throttle = 0
        guarded.brake = 1
        return guarded
    }

    // MARK: 输出解析

    /// 把 CoreML 输出解析成 `V3Decision`；任一关键输出缺失或含 NaN/Inf → nil。
    nonisolated static func parseDecision(_ output: MLFeatureProvider) -> V3Decision? {
        func floats(_ name: String) -> [Float]? {
            guard let mv = output.featureValue(for: name)?.multiArrayValue else { return nil }
            var out = [Float](repeating: 0, count: mv.count)
            for i in 0..<mv.count {
                let v = mv[i].floatValue
                if !v.isFinite { return nil }   // NaN/Inf → 整帧作废
                out[i] = v
            }
            return out
        }

        guard let v = floats("vertical"), v.count == 3,
              let h = floats("horizontal"), h.count == 3,
              let hbRaw = floats("handbrake")?.first,
              let brRaw = floats("brake")?.first,
              let sbRaw = floats("super_brake")?.first,
              let ulRaw = floats("ultimate")?.first,
              let confRaw = floats("confidence")?.first,
              let riskRaw = floats("risk")?.first else { return nil }

        // logit > 0 ⟺ sigmoid(logit) > 0.5（严格等价，不是近似）
        return V3Decision(
            verticalClass: Self.argmax3(v),
            horizontalClass: Self.argmax3(h),
            brakePressed: brRaw > 0,
            handbrakePressed: hbRaw > 0,
            superBrakePressed: sbRaw > 0,
            ultimatePressed: ulRaw > 0,
            confidence: Self.sigmoid(Double(confRaw)),
            risk: Self.sigmoid(Double(riskRaw)))
    }

    /// 三分类 argmax，**平局取第一个最大值**（与 PyTorch / NumPy `argmax` 一致）。
    ///
    /// 【为什么必须与 Python 对齐】（评审 P2，已确认为真）
    ///   旧实现是：
    ///     `if a[1] > a[0] && a[1] > a[2] { return 1 }; return a[0] >= a[2] ? 0 : 2`
    ///   对 `[0, 1, 1]` 返回 **2**（S/D），而 PyTorch/NumPy argmax 返回 **1**（第一个最大）。
    ///   后果：同一组平局 logits，Swift 生产端判 S/D、Python 离线评估判 NONE，
    ///   离线指标无法代表线上解码 —— 评估看着好、线上行为不同，属**静默语义分叉**。
    ///
    /// 【平局策略 = 第一个最大值，无安全偏置】
    ///   不在此处加"平局优先 S/D"之类的安全偏置：那会让 Swift 与 Python 再次分叉，
    ///   且偏置一旦隐藏在此处，Python 评估永远测不到。若将来确实需要安全偏置，
    ///   正确做法是**在训练侧标签口径**统一加（S 优先），并让 Python 评估采用同一规则，
    ///   而不是在部署解码里偷偷改。故这里严格对齐库函数语义。
    ///
    /// 【逐位比较逻辑】严格 `>` 才前移 → 相等时**保留更早的索引**，即取第一个最大值。
    ///   [0,1,1] → 0(i=1 时 1>0 前移→1；i=2 时 1>1 不成立 → 停在 1) = 1 ✓
    ///   [1,1,0] → 停在 0 ✓　[0,1,0] → 1 ✓　[1,0,1] → 0 ✓
    nonisolated static func argmax3(_ a: [Float]) -> Int {
        var bestIndex = 0
        for i in 1..<a.count where a[i] > a[bestIndex] {
            bestIndex = i
        }
        return bestIndex
    }

    nonisolated static func sigmoid(_ x: Double) -> Double {
        1.0 / (1.0 + exp(-x))
    }

    // MARK: 输入缓冲

    /// 分配/复用输入 MLMultiArray（形状固定）。
    ///
    /// ⚠️ dtype 必须 `.float16`（文件头红线 1）。
    nonisolated private func ensureBuffers() {
        if bufferHi == nil {
            bufferHi = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.hiFrames), 3,
                        NSNumber(value: V3InputContract.hiHeight),
                        NSNumber(value: V3InputContract.hiWidth)],
                dataType: .float16)
        }
        if bufferLo == nil {
            bufferLo = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.loFrames), 3,
                        NSNumber(value: V3InputContract.loHeight),
                        NSNumber(value: V3InputContract.loWidth)],
                dataType: .float16)
        }
        if bufferLane == nil {
            bufferLane = try? MLMultiArray(
                shape: [1, 1, NSNumber(value: V3InputContract.laneSize),
                        NSNumber(value: V3InputContract.laneSize)],
                dataType: .float16)
        }
        if bufferDets == nil {
            bufferDets = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.maxDetections),
                        NSNumber(value: V3InputContract.detFeatureDim)],
                dataType: .float16)
        }
        if bufferDetMask == nil {
            bufferDetMask = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.maxDetections)],
                dataType: .float16)
        }
        if bufferState == nil {
            bufferState = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.stateDim)],
                dataType: .float16)
        }
    }

    /// 组装真实输入 provider。
    ///
    /// - Parameters:
    ///   - hi: 高清窗口（`hiFrames × hiFrameElements`，新→旧）
    ///   - lo: 低清窗口（`loFrames × loFrameElements`，新→旧）
    ///   - prevHorizontalClass: 上一帧横向类别（写入 `vehicle_state[6]`）
    nonisolated private func makeProvider(hi: [Float16], lo: [Float16],
                                          prevHorizontalClass: Int) -> MLFeatureProvider? {
        ensureBuffers()
        guard let bufHi = bufferHi, let bufLo = bufferLo,
              let bufLane = bufferLane, let bufDets = bufferDets,
              let bufMask = bufferDetMask, let bufState = bufferState else { return nil }

        // ① image_hi / image_lo：整块拷贝（布局已与模型期望的扁平顺序一致）
        copyInto(bufHi, from: hi)
        copyInto(bufLo, from: lo)

        // ② lane / dets / det_mask：训练时恒为零填充（V3 录制数据无这两路）
        //    缓冲创建即为 0，且此后从不写入 → 无需每帧重置。
        //    ⚠️ 若将来接入真实车道线/检测框，必须同时重训模型（训练分布已在
        //       零填充上收敛，直接喂真值会分布偏移）。

        // ③ vehicle_state：按训练口径，仅 [6] = 上一帧 A/D，其余恒 0
        let statePtr = bufState.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<V3InputContract.stateDim { statePtr[i] = 0 }
        switch prevHorizontalClass {
        case 0: statePtr[V3InputContract.steerStateIndex] = -1   // 上一帧 A
        case 2: statePtr[V3InputContract.steerStateIndex] = 1    // 上一帧 D
        default: statePtr[V3InputContract.steerStateIndex] = 0
        }

        let dict: [String: Any] = [
            V3InputContract.imageHi: MLFeatureValue(multiArray: bufHi),
            V3InputContract.imageLo: MLFeatureValue(multiArray: bufLo),
            V3InputContract.lane: MLFeatureValue(multiArray: bufLane),
            V3InputContract.dets: MLFeatureValue(multiArray: bufDets),
            V3InputContract.detMask: MLFeatureValue(multiArray: bufMask),
            V3InputContract.vehicleState: MLFeatureValue(multiArray: bufState),
        ]
        return try? MLDictionaryFeatureProvider(dictionary: dict)
    }

    /// 零输入 provider（预热用；形状与真实输入完全一致）。
    ///
    /// ⚠️【必须**新建**缓冲并显式清零，不能复用 `bufferHi/bufferLo`】（评审 P1-2）
    ///   旧实现直接返回复用缓冲，注释却写"零输入" —— 热重载时这些缓冲里
    ///   还留着上一代模型的**真实帧数据**，于是"全零预热"实际是拿旧画面预热
    ///   新模型：ANE 编译的计算图是对的，但预热语义是假的，且可能让首帧
    ///   输出受污染。这里改为每次预热新建独立的零缓冲（预热只在加载时跑一次，
    ///   分配成本可忽略），并显式 memset 保证"全零"不依赖分配器行为。
    nonisolated private func makeZeroProvider() -> MLFeatureProvider? {
        func zeroArray(_ shape: [NSNumber]) -> MLMultiArray? {
            guard let arr = try? MLMultiArray(shape: shape, dataType: .float16) else { return nil }
            let count = arr.count
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            ptr.update(repeating: 0, count: count)
            return arr
        }
        guard let zeroHi = zeroArray([1, NSNumber(value: V3InputContract.hiFrames), 3,
                                      NSNumber(value: V3InputContract.hiHeight),
                                      NSNumber(value: V3InputContract.hiWidth)]),
              let zeroLo = zeroArray([1, NSNumber(value: V3InputContract.loFrames), 3,
                                      NSNumber(value: V3InputContract.loHeight),
                                      NSNumber(value: V3InputContract.loWidth)]),
              let zeroLane = zeroArray([1, 1, NSNumber(value: V3InputContract.laneSize),
                                        NSNumber(value: V3InputContract.laneSize)]),
              let zeroDets = zeroArray([1, NSNumber(value: V3InputContract.maxDetections),
                                        NSNumber(value: V3InputContract.detFeatureDim)]),
              let zeroMask = zeroArray([1, NSNumber(value: V3InputContract.maxDetections)]),
              let zeroState = zeroArray([1, NSNumber(value: V3InputContract.stateDim)]) else {
            return nil
        }
        let dict: [String: Any] = [
            V3InputContract.imageHi: MLFeatureValue(multiArray: zeroHi),
            V3InputContract.imageLo: MLFeatureValue(multiArray: zeroLo),
            V3InputContract.lane: MLFeatureValue(multiArray: zeroLane),
            V3InputContract.dets: MLFeatureValue(multiArray: zeroDets),
            V3InputContract.detMask: MLFeatureValue(multiArray: zeroMask),
            V3InputContract.vehicleState: MLFeatureValue(multiArray: zeroState),
        ]
        return try? MLDictionaryFeatureProvider(dictionary: dict)
    }

    /// 把 `[Float16]` 整块写进 MLMultiArray（长度必须严格相等）。
    nonisolated private func copyInto(_ array: MLMultiArray, from values: [Float16]) {
        let n = array.count
        guard values.count == n else {
            print("[v3] 缓冲长度不符：目标 \(n) vs 来源 \(values.count)")
            return
        }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
        values.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            ptr.update(from: base, count: n)
        }
    }

    // MARK: 图像预处理

    /// CGImage → 归一化 float16 平面数据 `[3, H, W]`（RGB 平面顺序）。
    ///
    /// 【归一化口径】与训练一致：`pixel / 255.0`（`dataset_v3.py:571` 的
    /// `image_hi.float().div_(255.0)`）。**不**做 mean/std 归一化。
    ///
    /// 【缩放方式】直接 `CGContext.draw` 拉伸到目标尺寸（不做等比 letterbox）。
    /// 训练数据的录制分辨率就是 384×224，与模型输入一致，故运行时只需缩放
    /// 游戏窗口到同一尺寸。若窗口长宽比不同，画面会有轻微形变——这与训练时
    /// 「录制即目标尺寸」的假设一致，不做额外裁剪。
    ///
    /// 【线程安全】只在串行 `queue` 上调用；scratch 静态复用，避免每帧分配 344KB
    /// （与 V2 `preprocessImage` 同一纪律）。
    ///
    /// 【为什么用 final class 包一层而不是 `static var`】Swift 6 不允许
    /// `nonisolated` 修饰**可变**静态存储属性（编译错误 "'nonisolated' cannot
    /// be applied to mutable stored properties"）。改成 `static let` 持有一个
    /// 引用类型容器后：容器本身是 let（不可变，满足并发规则），其内部的
    /// `bytes` 仍可原地复用 —— 语义与原来的静态数组完全等价。
    private final class RenderScratch: @unchecked Sendable {
        /// 按尺寸缓存的复用缓冲（键 = 字节数）。
        ///
        /// ⚠️【为什么是字典而不是单个数组】（评审 P1-2，已确认为真）
        ///   本函数每帧被调用**两次**：先 hi（384×224×4 = 344064 B），
        ///   再 lo（192×112×4 = 86016 B）。若共用一个 `bytes`，
        ///   两次 `needed` 必然交替不同 → `count != needed` 每帧都成立两次
        ///   → **每帧真分配 2 次**（344KB + 86KB ≈ 6.4MB/s 堆垃圾 @15Hz），
        ///   与"避免每帧分配"的设计意图完全相反（原注释也写错了）。
        ///   改成按尺寸分别缓存后，两种尺寸各自只分配一次。
        var bySize: [Int: [UInt8]] = [:]
        /// 保护 `bySize` 的锁。
        ///
        /// 【为什么必须加】（评审 P1-5，已确认为真）
        ///   本类每个实例有自己的 `queue`，但 `renderScratch` 是 **static 共享**：
        ///   两个实例（如自检里同时构造的两个引擎）会各在自己的队列上
        ///   同时 resize / 写入 / 读取**同一个** `bytes` —— 无锁共享访问。
        ///   队列 label 相同不代表是同一个队列（DispatchQueue 不去重）。
        ///   生产路径通常只有一个实例，但"通常"不是安全证明；
        ///   自检的测试钩子也可能从别处直接调 `renderNormalized`。
        ///   加一把 NSLock 是最小代价的正确做法：每帧仅 2 次加解锁（hi/lo），
        ///   开销约百纳秒级，相对 22ms 的推理可忽略。
        let lock = NSLock()
    }
    nonisolated private static let renderScratch = RenderScratch()

    /// 注：本函数不是 `private` —— `V3EngineSelfTest` 的 T3 会直接调用它。
    /// 这是**测试钩子**，不是扩大公开 API：同 module 内可见，不对外暴露。
    ///
    /// ⚠️【如实说明自检覆盖范围】（评审 P2-2 指出原注释夸大）
    ///   T3 用的是**纯色合成图**，只能验证「/255 归一化」与「RGB 平面顺序」——
    ///   纯色图缩放后仍是同一纯色，所以它**对缩放核完全不敏感**
    ///   （本函数用 `CGContext.interpolationQuality = .high`，训练侧用 PIL `BILINEAR`，
    ///    两者重采样算法不同，但 T3 测不出差异）。
    ///   缩放核的一致性由**另一条独立验证**覆盖：同一批真实训练帧分别走
    ///   「Swift 引擎」与「PIL+INT4 CoreML」全链路，比对 8 路输出
    ///   （实测 seg_a 横向 91.18% vs 91.24%，差 0.06% 属浮点噪声）。
    nonisolated static func renderNormalized(_ cgImage: CGImage,
                                             height: Int, width: Int) -> [Float16]? {
        // 整段（resize + 绘制 + 拆平面）都在锁内：scratch 是共享静态缓冲，
        // 任何一步跑到锁外都会与另一实例的读写重叠。
        renderScratch.lock.lock()
        defer { renderScratch.lock.unlock() }

        let needed = width * height * 4
        if renderScratch.bySize[needed] == nil {
            renderScratch.bySize[needed] = [UInt8](repeating: 0, count: needed)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4

        let drawn: Bool = renderScratch.bySize[needed]!.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            guard let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let planeSize = height * width
        var out = [Float16](repeating: 0, count: 3 * planeSize)
        // 逐像素拆成 3 个平面并除以 255（与训练侧 CHW + /255 完全一致）
        renderScratch.bySize[needed]!.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<planeSize {
                let p = i * 4
                out[i]                = Float16(Float(base[p])     / 255.0)
                out[planeSize + i]    = Float16(Float(base[p + 1]) / 255.0)
                out[planeSize * 2 + i] = Float16(Float(base[p + 2]) / 255.0)
            }
        }
        return out
    }
}
