// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ConfidenceEstimator.swift — 置信度估计器
//
//  职责：从"模型输出历史 + 当前画面"估计当前驾驶模型的健康度
//  输出：[0,1] 健康度分，供降级状态机决策
//
//  【分层结构：硬门控（fail-closed）+ 软信号（可融合）】
//    · 硬门控——任一不满足直接把健康度置 0，不参与加权：
//        0) 链路存活：模型未加载 / 无推理结果 / 结果过期（由调用方算好传入）
//           （修复退化平衡点：E2E 恒输出 idle/恒定值时旧公式会算出 0.70，
//             高于降级阈值 0.65，导致死模型永远卡在端到端档不降级）
//        0b) 输入新鲜度：画面本身超龄（默认 1.0s，与 App 既有存活判据同源）
//        0c) 输入有效性：画面亮度异常（全黑/全白）→ 输入不可用
//           实测依据：黑图/白图喂 V3 模型，confidence 仍 ≈0.9733 / 0.9977，
//           说明模型 confidence **不能**用来判定输入是否有效（评审 P1-1）。
//    · 软信号——只在门控全部通过后参与融合：
//        1) 输出一致性：最近 N 帧 steer 抖动越小越可信（仅连续输出）
//        2) 转向极端度：steer 长时间打满（|steer|>0.95）视为退化（仅连续输出）
//        3) 画面有效性：亮度在正常范围给满分（硬门控通过后基本恒 1.0）
//        4) 模型 confidence（仅 V3 离散输出）：**辅助信号**，权重 0.3，
//           不能单独决定健康度。训练语义见 `update()` 内注释与
//           `src/dataset_v3.py:203-224`。
//
//  【为什么模型 confidence 不能当健康度】
//    训练侧 `_confidence_targets` 的定义是
//    `conf[t] = exp(-0.15 × 相邻两帧(t-1,t)变化的原子键个数)`（值域 (0,1]）。
//    它来自**控制变化量**，语义是「变化大 → 高动态/转折场景 → 判断更难」，
//    是场景动态度代理，**不是**人工接管标签、不是预测正确率、也不是画面有效性。
//    实测 5 段真实训练标签共 41411 帧：90.9% 的帧 diff=0（conf=1.0），
//    diff=3 仅 19 帧（0.05%，conf≈0.6376 已低于 degradeHealth 0.65）。
//    即：正常驾驶中它几乎恒为 1.0，而"连续变键"这种正常操作反而会击穿降级线
//    ——把它直接当健康度既漏判（黑图高 confidence）又会误判（正常变键）。
//
//  设计：
//    - 滑动窗口存最近 N 帧输出，O(1) 更新
//    - 连续模型保持原三信号加权（0.5/0.3/0.2），行为不变
//    - 离散模型改为「模型 confidence 0.3 + 输入结构分 0.7」
//    - 线程安全：仅主线程调用（与 tick 同步）
// ============================================================================
import AppKit
import CoreImage
import Foundation
import Observation

@Observable
final class ConfidenceEstimator: @unchecked Sendable {

    // MARK: - 可调权重

    /// 输出一致性权重（抖动越小分越高）
    var consistencyWeight: Double = 0.5
    /// 输出极端度权重（贴边越久分越低）
    var extremityWeight: Double = 0.3
    /// 画面有效性权重（亮度异常分越低）
    var imageWeight: Double = 0.2

    /// 滑动窗口大小（最近 N 帧用于算一致性）
    var windowSize: Int = 20

    /// 极端值阈值：|steer|>0.95 视为转向打满（退化）
    var extremeThreshold: Double = 0.95

    /// 极端持续帧数超过此比例 → 判退化
    var extremeRatioThreshold: Double = 0.7

    /// 画面亮度正常范围（归一化 0~1），超出视为异常
    var brightnessMin: Double = 0.08
    var brightnessMax: Double = 0.95

    /// 输入新鲜度阈值：画面采集时刻超过这么久 → 判定输入不可用（硬门控）。
    ///
    /// 为什么取 1.0s（不是随手拍的数）：App 侧对 V3 输入新鲜度用的就是
    /// `v3MaxFrameAge = 1.0`（`AuroraDriveApp.swift:5678`），链路存活判据
    /// `isAliveV3` 也用 1.0s（同文件 `:8384-8387`）。
    /// 本估计器与它们保持同一尺度，否则会出现「链路判活、输入已超龄」
    /// 这类互相矛盾的判定。
    var maxImageAge: TimeInterval = 1.0

    /// 离散模式（V3）下模型 confidence 在健康度里的权重（少数派份额）。
    ///
    /// 【为什么是 0.3 而不是 1.0】
    ///   confidence 的训练语义是**场景动态度代理**
    ///   （`src/dataset_v3.py:203-224`，`exp(-0.15×相邻帧变化键数)`），
    ///   不是可靠性/正确率标签 → 它只配当辅助信号，不能独占健康度。
    ///   取 0.3 的**可检验依据**（不是口味）：
    ///     · 融合式 `health = 结构分×(1−w) + conf×w`，输入通过硬门控后结构分=1.0；
    ///     · V3 confidence 是 sigmoid 输出，理论下限 0；
    ///     · 于是离散模式的健康度**恒有硬下限 `1−w = 0.70`**，
    ///       而默认 `degradeHealth = 0.65` —— 即 confidence 无论多低都**不可能
    ///       单独把健康度压到降级线以下**，这正是「不能单独决定健康度」的可验证形式。
    ///   ⚠️ 边界如实说明：`degradeHealth` 是 UI 可调量（`AuroraDriveApp.swift:5650`
    ///      → `DegradeStateMachine.degradeHealth`）。若用户把阈值收紧到 0.70 以上，
    ///      健康度下限会重新落到阈值之下 —— 那属于用户显式收紧判定，不是本融合引入的缺陷。
    ///   同时保留 confidence 作为「场景变动态」对健康度的有界修正作用。
    var discreteModelConfidenceWeight: Double = 0.3

    // MARK: - 状态输出

    /// 当前健康度估计值 [0,1]（UI 观察；喂降级状态机）
    private(set) var confidence: Double = 1.0

    /// 三路子分（调试/UI 展示用）
    private(set) var consistencyScore: Double = 1.0
    private(set) var extremityScore: Double = 1.0
    private(set) var imageScore: Double = 1.0

    /// 最近一次**参与融合**的模型 confidence（仅离散模式有；诊断用）。
    /// 与 `ControlCommand.confidence` 同源，但这里只存「实际用于打分」的值，
    /// 便于在 UI/日志上区分「模型说的」与「最终健康度」。
    /// ⚠️ 硬门控拦下时**不更新**（保留最后一次实测值）——这正是要保留的对比证据：
    ///    黑图时 `modelConfidenceScore≈0.97` 而 `confidence=0`，说明两者已解耦。
    private(set) var modelConfidenceScore: Double = 1.0

    /// 最近一次被硬门控拦下的原因（空串 = 未拦下）。诊断用：
    /// 健康度归零时必须能分清是链路死、画面超龄、还是画面本身无效，
    /// 否则现场只能看到「莫名降档」。
    private(set) var gateReason: String = ""

    /// 最近一次亮度评估是否判定为**无效画面**（全黑/全白）。
    ///
    /// 为什么单独存一个布尔、而不复用 `imageScore`：`imageScore` 是连续软分，
    /// 而「输入是否有效」是硬门控（0/1 判定）。两者混用正是本次要修的语义扩大问题
    /// —— 让「分数低」和「输入不可用」在代码里保持两个概念。
    /// 初值 false：尚未评估过亮度时不预先拦截，交由链路/无画面门控处理
    /// （避免启动首帧因"还没算完"就误判无效）。
    private(set) var isImageInvalid: Bool = false

    // MARK: - 内部状态

    /// 最近 N 帧的 steer 值（算抖动用）
    private var steerHistory: [Double] = []
    /// 最近 N 帧是否极端（转向打满）的标记
    private var extremeHistory: [Bool] = []
    /// 长窗口极端标记（判"持续打满=贴墙/打转退化"；长度见 longExtremeWindow）
    private var longExtremeHistory: [Bool] = []

    /// 长窗口帧数：持续打满这么久还没松 → 不是过弯，是退化。
    ///
    /// ⚠️ **2026-10-18 审计发现的口径漂移（只标注，未改数值）**：
    ///   本值按「3 秒 @30Hz」定为 90 帧，但 tick 已于 2026-10-12 定档 **20Hz**
    ///   → 90 帧实际是 **4.5 秒**（比设计意图慢 50%），即"方向持续打满"要更久
    ///   才会被判为退化。属 20Hz 迁移的漏改项之一（同批还有
    ///   `YoloEngine.lockLostFrames` / `MotionPredictor.maxPredictionFrames` /
    ///   `maxMissingFrames` / `LaneFallback.stabilityFrames`）。
    ///   改数值会改变降级时序，属产品决策，故此处**只标注不改**；
    ///   若要恢复 3 秒语义，应改为 60（或按 tickHz 换算）。
    var longExtremeWindow: Int = 90
    /// 长窗口打满占比阈值：超过 → 判持续退化
    var longExtremeRatioThreshold: Double = 0.7

    // MARK: - 主入口

    /// 更新健康度估计
    /// - Parameters:
    ///   - command: 本帧模型输出
    ///   - image: 本帧画面 CGImage（用于亮度检测；nil 视为输入不可验证，fail-closed）
    ///   - isLive: 推理链路是否真的活着（模型已加载 && 最近有新鲜结果）。
    ///             链路死（没模型/结果过期）→ 健康度直接置 0，
    ///             强制降级到 YOLO 接管，避免 E2E 空转却卡在 .e2e 档。
    ///   - modelConfidence: 模型自己的 confidence 头（离散模式下的**辅助信号**）。
    ///   - imageAge: 画面采集时刻距今的秒数（nil = 调用方不提供，跳过新鲜度门控）。
    ///             为什么由调用方传：本类只持画面像素，不持有采集时刻
    ///             （采集时刻在 `AuroraDriveApp.currentFrameCGAt`，属 Lead 独占文件）。
    ///
    /// 是否按「离散按键式输出」评估极端度。
    ///
    /// 【为什么需要这个开关】（评审 P0-5，实测确认为真）
    ///   本估计器的极端判据 `|steer| > 0.95` 是给**连续回归**输出设计的：
    ///   连续模型打满方向 16 秒确实意味着贴墙/打转。
    ///   但 V3 是**三分类**（A/NONE/D），映射后 steer 只取 `{-1, 0, +1}`
    ///   （`InferenceEngineV3.steerValue`）——**正常转向本身就是 ±1**。
    ///   若沿用原判据：连续两个 A/D 决策就会让占比冲到 100%，
    ///   长窗口在 90 帧后必然越过 0.7 阈值 → 置信度被压到 0.30
    ///   → 低于 `degradeHealth = 0.65` → **合法转向被误判成退化并强制降档**。
    ///
    ///   同理 `computeConsistency()` 的平滑度曲线也不适用于离散输出
    ///   （"离散本来就不平滑"），故离散模式下**跳过**该判据 —— 这条修复要保留。
    ///   但跳过一致性 ≠ 让模型 confidence 独占健康度：后者只是辅助信号，
    ///   见 `discreteModelConfidenceWeight` 与 `update()` 内 §2 的融合式。
    ///   置 false 时行为与原实现完全一致（保持既有连续模型的语义不变）。
    var usesDiscreteSteering: Bool = false

    func update(command: ControlCommand, image: CGImage?, isLive: Bool,
                modelConfidence: Double? = nil, imageAge: TimeInterval? = nil) {
        // ══════════════════════════════════════════════════════════════
        //  §0 硬门控（fail-closed）：不满足即健康度归零，**不参与加权**
        //  设计原则：门控回答"这份输入/链路还能不能信"（0/1 判定），
        //  加权融合回答"在可用的前提下有多稳"（连续打分）。
        //  把 confidence 塞进加权里、或反过来用它替代门控，都是语义混淆。
        // ══════════════════════════════════════════════════════════════

        // ── §0a 链路存活：E2E 没在真实决策 → 不可信 ──
        // 修复旧逻辑的退化平衡点：当 E2E 输出恒为 idle/恒定值时，
        // 一致性=1.0 + 极端度=0.0 + 画面=1.0 恰好算出 0.70，高于降级阈值
        // 0.65，导致"模型死了却永远卡在端到端档"。这里用链路存活直接归零。
        guard isLive else {
            failClosed(reason: "链路不存活")
            return
        }

        // ── 先刷新画面亮度评估 ──
        // ⚠️ 必须在门控**之前**调用：亮度是后台异步算的，若门控提前 return
        //   就不再刷新，一旦判成"画面无效"就会**永远卡在 0**（画面恢复也无从得知）。
        //   代价是判定有 1 帧滞后（沿用上一帧结果），业界可接受，已在 §0c 注明。
        imageScore = computeImageScore(image)

        // ── §0b 输入新鲜度：画面本身超龄 → 输入不可用 ──
        // 与 App 侧 `v3MaxFrameAge = 1.0`（AuroraDriveApp.swift:5678）同一尺度。
        // 为什么链路存活之外还要单独判：`currentFrameCG` 全文没有置 nil 的地方，
        // 抓屏停摆后旧图会被反复推理并刷新 lastResultTime —— 只看链路存活
        // 会把"抓屏已死"误判成"模型活得很好"。这是独立的一类失效，必须单独门控。
        if let age = imageAge, age.isFinite, age > maxImageAge {
            failClosed(reason: String(format: "输入画面超龄 %.2fs > %.1fs", age, maxImageAge))
            return
        }

        // ── §0c 输入有效性：画面无效 → 输入不可用 ──
        // 【为什么必须独立于模型 confidence】实测喂**纯黑/纯白**图给 V3，
        //   confidence 头仍输出 ≈0.9733 / ≈0.9977（评审 P1-1 实测）。
        //   即模型对无效画面照样"自信" —— 用 confidence 判输入有效性是**反向**的。
        //   这里改用像素亮度硬门控（阈值 0.08/0.95，全黑≈0、纯白≈1）。
        //   无画面（nil）同样 fail-closed：无法验证的输入不当作可用输入。
        if image == nil {
            failClosed(reason: "无画面（输入不可验证）")
            return
        }
        if isImageInvalid {
            // 1 帧滞后：亮度在后台算，本帧沿用上一帧判定（与 imageScore 同源）。
            failClosed(reason: "画面亮度异常（全黑/全白）")
            return
        }

        // ══════════════════════════════════════════════════════════════
        //  §1 更新历史窗口（门控通过后才有意义）
        // ══════════════════════════════════════════════════════════════
        steerHistory.append(command.steer)
        if steerHistory.count > windowSize { steerHistory.removeFirst() }

        // 极端 = 转向打满（|steer|>0.95）。
        // 油门/刹车贴边（0 或 1）是正常驾驶行为，不判极端 ——
        // 旧定义把"巡航全油门"误判为退化，导致置信度恒 0.70、
        // 永远够不到 .rule→.e2e 的 0.75 恢复阈值，卡死在规则档。
        // 离散按键式输出（V3）：±1 是正常转向，不构成「打满」证据 → 恒判非极端。
        let isExtreme = usesDiscreteSteering ? false : (abs(command.steer) > extremeThreshold)
        extremeHistory.append(isExtreme)
        if extremeHistory.count > windowSize { extremeHistory.removeFirst() }
        longExtremeHistory.append(isExtreme)
        if longExtremeHistory.count > longExtremeWindow { longExtremeHistory.removeFirst() }

        // ══════════════════════════════════════════════════════════════
        //  §2 软信号融合
        // ══════════════════════════════════════════════════════════════
        consistencyScore = computeConsistency()   // 离散模式恒 1.0（跳过判据）
        extremityScore = computeExtremity()

        let total = consistencyWeight + extremityWeight + imageWeight
        let structuralScore = (consistencyScore * consistencyWeight
                               + extremityScore * extremityWeight
                               + imageScore * imageWeight) / max(total, 1e-6)

        if usesDiscreteSteering, let mc = modelConfidence, mc.isFinite {
            // 【离散模式：模型 confidence 只占少数份额，不能单独决定健康度】
            //   训练侧语义（src/dataset_v3.py:203-224）：
            //     conf = exp(-0.15 × 相邻两帧变化的原子键个数)，值域 (0,1]
            //   它衡量的是**控制变化量** → 高动态/转弯场景 → "判断更难"，
            //   是场景动态度代理，**不是**可靠性/正确率/接管标签。
            //   实测 5 段真实训练标签 41411 帧：90.9% 的帧 diff=0（conf=1.0），
            //   diff=3 仅 19 帧（0.05%，conf≈0.6376）——
            //   直接当健康度有两个方向的错：
            //     · 漏判：黑图仍给 0.9733（对无效输入毫无区分力）；
            //     · 误判：连续变键（正常超车/避让）会把健康度压到降级线附近。
            //   故改为有界融合：结构分占 (1−w)，confidence 占 w=0.3。
            //   输入通过硬门控后结构分为 1.0 → 健康度恒 ≥ 1−w = 0.70，
            //   高于默认 degradeHealth=0.65 ⇒ confidence 单独不足以触发降级。
            let clampedMC = max(0, min(1, mc))
            modelConfidenceScore = clampedMC
            let w = max(0, min(1, discreteModelConfidenceWeight))
            confidence = structuralScore * (1 - w) + clampedMC * w
        } else {
            // 连续模型（既有语义，保持不变）：三信号加权。
            // 离散模式但未提供 modelConfidence → 同样退回结构分（不臆造信号）。
            modelConfidenceScore = structuralScore
            confidence = structuralScore
        }

        // ── §3 持续转向打满 → 贴墙/打转（退化）──
        // 一致性满分会把"打满恒定输出"洗成 0.70（高于降级阈值 0.65），
        // 导致模型打满 16 秒还卡在端到端档继续注入错误按键。
        // 长窗口（3s）内 |steer|>0.95 占比 >70% → 置信度压到 0.30 强制降级。
        // 注意：只判"转向打满"，不是判"输出恒定"（直道稳定输出是正常的）。
        // 离散模式 isExtreme 恒 false → longRatio 恒 0 → 本段不生效（预期行为）。
        if !longExtremeHistory.isEmpty {
            let longRatio = Double(longExtremeHistory.filter { $0 }.count)
                / Double(longExtremeHistory.count)
            if longRatio > longExtremeRatioThreshold {
                confidence = min(confidence, 0.30)
            }
        }
        gateReason = ""
        confidence = max(0, min(1, confidence))
    }

    /// 硬门控失败：健康度归零并记录原因（fail-closed）。
    ///
    /// ⚠️ 为什么**不**在这里把 `imageScore` 清零（曾踩过，勿改回去）：
    ///   `imageScore` 由**独立的后台亮度任务**测量并回写，它描述的是
    ///   「上一帧实测亮度是否正常」，不是本次门控的结论。若在这里清零：
    ///     1) 语义上等于凭空捏造一个"画面无效"的测量结果（其实没测）；
    ///     2) 会造成真实故障：链路短暂失活 → imageScore 被清 0 →
    ///        链路恢复的下一帧亮度任务还没算完（沿用缓存 0）→
    ///        结构分 = (1.0×0.5 + 1.0×0.3 + 0×0.2)/1.0 = **0.80** →
    ///        离散模式健康度 ≈ 0.80×0.7 + 0.3×conf < 0.65 →
    ///        **一次虚假降级**（DegradeStateMachine 没有去抖，单帧即可降档）。
    ///   故门控只归零「健康度」与「由输出历史算出的两个子分」（它们确实已失效），
    ///   亮度分与模型 confidence 保留最后实测值，供诊断看出
    ///   「模型说 conf=0.97，但输入被门控拦下」这一关键对比（正是 P1-1 的证据）。
    private func failClosed(reason: String) {
        confidence = 0
        consistencyScore = 0
        extremityScore = 0
        gateReason = reason
    }

    /// 重置（停止驾驶时调用）
    func reset() {
        steerHistory.removeAll()
        extremeHistory.removeAll()
        longExtremeHistory.removeAll()
        confidence = 1.0
        consistencyScore = 1.0
        extremityScore = 1.0
        imageScore = 1.0
        modelConfidenceScore = 1.0
        isImageInvalid = false
        gateReason = ""
    }

    // MARK: - 子分计算

    /// 输出一致性：steer 历史的标准差越小，分越高
    /// 标准差 0 → 1.0，标准差 0.5+ → 0.0
    private func computeConsistency() -> Double {
        // ⚠️【离散输出必须跳过一致性判据】（评审 P0-1，已独立复算证实）
        //   本曲线 `std 0→1.0, std 0.5→0.0` 是给**连续回归**的小抖动设计的
        //   （连续模型直道 std≈0.05 → 0.90 分）。
        //   但 V3 的 steer 只取 `{-1, 0, +1}` 三个离散值：
        //     两次反向 → std=0.316 → 0.368 分
        //     三次反向 → std=0.387 → 0.232 分 → 加权后 **0.616 < degradeHealth 0.65**
        //     → 正常变道 / S 弯 / 连续修正就会触发 `.e2e → .yolo` **假降级**。
        //   实测复算（20 帧窗口、usesDiscreteSteering=true）：
        //     直行全0 → 1.000 | 1次打方向 → 0.782 | 2次反向 → 0.684（贴边）
        //     3次反向 → **0.616 触发降档** | 5次反向 → 0.503
        //   故离散模式下不做"平滑度"判断（离散本来就不平滑）。
        //   ⚠️ 但「跳过一致性」只解决"别把正常转向误判成退化"，
        //   **不代表**要让模型 confidence 独占健康度 —— 后者见 update() §2：
        //   confidence 只占 0.3 份额，且输入有效性另有硬门控。
        guard !usesDiscreteSteering else { return 1.0 }
        guard steerHistory.count >= 3 else { return 0.8 }   // 帧数不足给中等分
        let mean = steerHistory.reduce(0, +) / Double(steerHistory.count)
        let variance = steerHistory.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steerHistory.count)
        let std = sqrt(variance)
        // std 0→1.0, std 0.5→0.0 线性映射
        return max(0, min(1, 1.0 - std * 2.0))
    }

    /// 输出极端度：极端帧占比越低，分越高
    private func computeExtremity() -> Double {
        guard !extremeHistory.isEmpty else { return 1.0 }
        let extremeRatio = Double(extremeHistory.filter { $0 }.count) / Double(extremeHistory.count)
        // 占比低于 ratioThreshold → 1.0，高于 → 线性下降到 0
        if extremeRatio <= extremeRatioThreshold {
            return 1.0
        }
        // P2 修复：极端占比阈值滑到 1.0（或异常值/NaN）时分母 (1.0 - threshold) 为 0，
        // 除零会产出 inf/NaN 污染置信度。guard 分母 > 0，异常时极端度直接判 0（保守降级）。
        let denom = 1.0 - extremeRatioThreshold
        guard denom > 0 else { return 0 }
        return max(0, 1.0 - (extremeRatio - extremeRatioThreshold) / denom)
    }

    /// 画面有效性：亮度在正常范围 → 1.0，异常 → 0.1
    /// 亮度计算已移到后台队列（纯 CPU 抽样，主线程零绘制），
    /// 结果异步回写 `imageScore` 与 `isImageInvalid`；本帧沿用上一帧已算好的缓存结果。
    private func computeImageScore(_ image: CGImage?) -> Double {
        guard let image = image else {
            // 无画面：调用方随即会被 §0c fail-closed，这里**不得改写 imageScore**。
            // 为什么：若把它写成 0.5（旧行为），「无画面 → 恢复」的第一帧会沿用
            // 这个假分数算结构分 = 1.0×0.5 + 1.0×0.3 + 0.5×0.2 = 0.90 →
            // 离散模式 health ≈ 0.63 + 0.3×conf，conf 低时 < 0.65 → 一次虚假降级。
            // 亮度分是"实测值"，没有测量就不要伪造测量结果。
            return imageScore
        }
        // 主线程只读一次阈值快照，闭包捕获常量，避免跨线程读可变状态（无数据竞争）
        let minB = brightnessMin
        let maxB = brightnessMax
        // 只保留最新帧：上一帧亮度任务还在后台跑则跳过本次（亮度结果本就滞后 1 帧，
        // 沿用缓存分即可），避免每 tick 无脑入队、后台亮度任务堆积。
        guard !brightnessInFlight else { return imageScore }
        brightnessInFlight = true
        Self.brightnessQueue.async { [weak self] in
            let brightness = Self.averageBrightness(cgImage: image)
            let isValid = !(brightness < minB || brightness > maxB)
            let score: Double = isValid ? 1.0 : 0.1
            // 在后台队列提前解包 weak self，避免将非 Sendable 的 self 引用
            // 传入 @MainActor Task（Swift 6 会检查跨域发送）
            let target: ConfidenceEstimator? = self
            Task { @MainActor [target] in
                target?.brightnessInFlight = false
                target?.imageScore = score
                // 硬门控用的有效性布尔与软分同源更新，保证两者不会长期不一致
                target?.isImageInvalid = !isValid
            }
        }
        // 本帧融合用缓存分（上一帧后台结果），不阻塞主线程等亮度
        return imageScore
    }

    /// 亮度后台任务 in-flight 标志（主线程置位 / 后台回主线程清除，全程主线程访问无锁）
    /// @ObservationIgnored：非 UI 状态，不参与观察
    @ObservationIgnored
    private var brightnessInFlight = false

    /// 后台亮度计算队列（独立于推理队列的 serial queue）
    private static let brightnessQueue = DispatchQueue(
        label: "com.aurora.confidence.brightness", qos: .userInitiated)

    /// 复用的 CoreImage 渲染上下文（线程安全，跨线程共享，避免每帧新建）
    ///
    /// ⚠️ 2026-10-11 GPU 零占用修复（w4-tools 的 P4 审计发现）：
    ///   原实现**未指定 device** → CIContext 默认**优先用 GPU**。
    ///   本项目铁律「推理不碰 GPU」（游戏独占 GPU）；`CaptureEngine.swift:957`
    ///   已记录过 GPU CIContext 排队导致 **40ms 卡顿**的血案。
    ///   本处虽只渲染到 **1×1** 缓冲（`CIAreaAverage`），GPU 侧开销极小，
    ///   但**任何 GPU 提交都会与游戏争用命令队列** → 强制 CPU 渲染消除不确定性。
    private static let brightnessContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])

    /// 计算图像平均亮度 [0,1]（后台执行）
    ///
    /// ⚠️⚠️ 2026-10-11 重大修复：**彻底移除 CIContext**（本文件再无任何 CoreImage 调用）
    ///
    /// 【血案证据 — `sample` 实测，不是推测】
    ///   用户报告"没开游戏、只是打开自动驾驶就卡到 12fps、主驾延迟 100+ms"。
    ///   `sample` 引擎进程 5 秒，抓到的调用栈（679 个采样点全卡在这一条）：
    ///   ```
    ///   Thread: com.aurora.confidence.brightness (serial)   679 samples
    ///     └ ConfidenceEstimator.computeImageScore  :197
    ///       └ averageBrightness(cgImage:)                     646 samples
    ///         └ CIContext.render(toBitmap:)
    ///           └ CI::MetalContext::readback_bitmap             ← 走 Metal（GPU）！
    ///             └ _MTLCommandBuffer waitUntilCompleted       446 samples
    ///               └ __psynch_cvwait                           ← 阻塞等 GPU！
    ///   ```
    ///
    /// 【为什么之前的"CPU 修复"无效 —— 官方头文件铁证】
    ///   本文件曾设 `CIContext(options: [.useSoftwareRenderer: true])`，但
    ///   `CIContext.h:184` 原文写死：
    ///   > Note: This option has no effect if the platform does not support OpenCL.
    ///   **Apple Silicon 没有 OpenCL** → 该选项被系统**静默忽略** → 照样走 Metal。
    ///   ⟹ 只要用 CIContext，就无法保证不碰 GPU。**唯一可靠的做法是不用 CIContext。**
    ///
    /// 【新实现：纯 CPU 直接采样像素，零 GPU】
    ///   直接从 CGImage 的 data provider 读字节，按步长抽样 ~4096 个点求均值。
    ///   · 无 CIContext / 无 CIImage / 无 Metal 提交 → **绝不与游戏或 WindowServer 抢 GPU**
    ///   · 开销：4096 次指针读 + 加法 ≈ **0.05ms**（对比原先等 GPU 的数百 ms）
    ///   · 精度：抽样 0.4%（1280×832）对"平均亮度"足够 —— 该值只用于
    ///     `0.08 / 0.95` 两个粗阈值判断（见 `computeImageScore` 注释）
    ///
    /// 【回退开关】`AURORA_CONF_CI=1` 可临时恢复 CoreImage 路径（仅在排查对比时用）。
    private static let useCoreImagePath =
        ProcessInfo.processInfo.environment["AURORA_CONF_CI"] == "1"

    private static func averageBrightness(cgImage: CGImage) -> Double {
        if useCoreImagePath { return averageBrightnessViaCoreImage(cgImage: cgImage) }
        return averageBrightnessViaCPU(cgImage: cgImage)
    }

    /// 纯 CPU 路径（默认）：直接读像素指针抽样求均值。**零 GPU 提交。**
    private static func averageBrightnessViaCPU(cgImage: CGImage) -> Double {
        // 只支持 8bpc / 32bpp 的常见屏捕格式（32BGRA / 32ARGB）；
        // 其它格式（罕见）直接给中等分，不猜（宁可保守也不引入错误像素解释）。
        guard cgImage.bitsPerComponent == 8,
              cgImage.bitsPerPixel == 32,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let base = CFDataGetBytePtr(data) else {
            return 0.5
        }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return 0.5 }
        let rowBytes = cgImage.bytesPerRow
        let total = w * h
        // 目标抽样点数：约 4096（对 1280×832 是 0.4%），至少每像素 1 步
        let step = max(1, total / 4096)

        // 字节序判定：**屏捕链路恒为 32BGRA little-endian**（CaptureEngine 显式锁
        // kCVPixelFormatType_32BGRA，见 CaptureEngine.swift 的 pixelFormat 注释）。
        // 这里按 bitmapInfo 的 byteOrder 精确判定，避免把 B/G/R 搞反。
        let bi = cgImage.bitmapInfo
        let isLittleEndian = bi.contains(.byteOrder32Little)
        // 小端 + premultipliedFirst = 内存序 B,G,R,A（32BGRA）
        // 大端 + premultipliedFirst = 内存序 A,R,G,B（32ARGB）
        let rIdx = isLittleEndian ? 2 : 1
        let gIdx = 2
        let bIdx = isLittleEndian ? 0 : 3

        var sumR = 0, sumG = 0, sumB = 0, count = 0
        var i = 0
        while i < total {
            let x = i % w
            let y = i / w
            let offset = y * rowBytes + x * 4
            // 防御：data 长度可能小于 (rowBytes*h)（某些 CGImage 的尾部裁剪）
            // 越界读取会崩，故用 CFDataGetLength 做边界检查
            if offset + 3 >= CFDataGetLength(data) { break }
            sumB += Int(base[offset + bIdx])
            sumG += Int(base[offset + gIdx])
            sumR += Int(base[offset + rIdx])
            count += 1
            i += step
        }
        guard count > 0 else { return 0.5 }
        let r = Double(sumR) / Double(count) / 255.0
        let g = Double(sumG) / Double(count) / 255.0
        let b = Double(sumB) / Double(count) / 255.0
        // Rec.601 亮度近似（与旧 DeviceGray 转灰的视觉亮度一致；阈值 0.08/0.95 粗糙，语义等价）
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// CoreImage 路径（**仅排查对比用，默认关闭**）：见上方血案注释——
    /// 在 Apple Silicon 上必然走 Metal 且同步等 GPU，是"没开游戏也卡"的根因。
    private static func averageBrightnessViaCoreImage(cgImage: CGImage) -> Double {
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.5 }
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { raw in
            brightnessContext.render(output,
                                     toBitmap: raw.baseAddress!,
                                     rowBytes: 4,
                                     bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     format: .RGBA8,
                                     colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
