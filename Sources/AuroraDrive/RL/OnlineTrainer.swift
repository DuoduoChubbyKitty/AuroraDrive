// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainer.swift — 纯 Swift 在线 RL 循环（边跑边训）
//
//  【这个文件解决什么】
//    每帧收集 transition（collect，主线程）→ 按 reward.py 语义算逐帧奖励
//    → 每 N 条或 episode 结束调 PolicyHead.computeGAE 算 GAE（逐 episode 不跨边界）
//    → 后台串行队列做 PPO 多 epoch 小批更新 → 训练好的策略原子发布给下一帧推理用
//    （双缓冲）。
//
//  【依赖类型归属（与 B 域 PolicyHead.swift 的协作口径）】
//    RLTransition / PPOConfig / PPOMetrics 由 PolicyHead.swift 单一 public 定义，
//    本文件**只引用不重复定义**，避免同 target "invalid redeclaration"。
//    GAE 复用 PolicyHead.computeGAE（语义严格照 reward.py，逐 episode 不跨边界）；
//    因 P1-2 需保留批次尾 bootstrap，调用带 tailBootstrapValue 参数的重载。
//    OnlineTrainer 只面向 `PolicyUpdatable` 协议编程，B 的头用
//    `extension PolicyHead: PolicyUpdatable {}` 接入；自检里的玩具策略也实现它。
//
//  【线程模型（硬要求）】
//    · collect / sampleAction / actionDistribution：**主线程**调用（tick 内）。
//    · 训练：后台**串行** DispatchQueue（qos .utility），串行天然互斥。
//    · 参数双缓冲：训练改 `trainingPolicy`（只在训练队列内碰），改完在锁内把
//      它**整体赋值**给 `inferencePolicy`（值语义 ⇒ 等价于复制一份快照），
//      主线程下一帧读到的就是新快照。struct 值语义是双缓冲能成立的前提。
//
//  【Codex 复审 788a26b 硬化点（本文件已修，逐条对应）】
//    P1-1 采样快照：collect 直接接收 sampleAction 采样时的 (vClass,hClass,logProbV,
//         logProbH,value) 并原样保存，**不再二次 forward 取 old**。避免「动作来自 π0、
//         old logProb 来自 π1」的竞态把 PPO ratio 人为拉成 ≈1。
//    P1-2 截断 vs 终止：批次按 `isTerminal` 真实边界切；仅因缓冲上限截断时，**扣下
//         最后一条不训**，对被截断子批传入 tailBootstrapValue=扣下那条的 value 估计，
//         保留 bootstrap（不把 nextV 归零）。episode 真正结束才整批训练。
//    P1-3 人工接管：tookOver 帧是真人救援动作，**不为它建策略 transition**；把接管
//         惩罚(-takeover)归因到上一条 AI transition 的 reward 上，并封口该 episode。
//    P1-4 UNKNOWN 缺口：sealEpisode()/markInvalid() 只在无有效状态/非有限帧时封口已有
//         轨迹（不伪造 transition），恢复后重新开始；UNKNOWN 不入训练。
//    P2   非有限速度：speedValid=true 但 speed=NaN 时把 previousValid 置 false（与
//         reward.py 一致：下一帧的有限性检查抑制伪造的急减速惩罚）。
//
//  【奖励语义对齐 tools/v3_rl/reward.py】
//    speed（速度三段：v<100 负/100≤v≤160 线性正/v>160 负，speedValid=false→0）/ stuck /
//    collision / decel（跨 OCR 缺口用 prev_valid 防
//    伪造）/ lane（绝对偏置，无世界坐标）/ takeover（强负）。**无任何绝对位置
//    依赖**，只用速度、碰撞、车道偏置、接管这些云端可得的信号。
//    human 项在在线循环里为 0（在线拿不到人类打分；离线训练才有）。
// ============================================================================

import Foundation

// ============================================================================
// MARK: - 依赖注入协议（B 域 PolicyHead 的抽象）
// ============================================================================

/// OnlineTrainer 对「策略」的全部依赖。B 域的 PolicyHead 只要满足这三件事即可
/// 通过 `extension PolicyHead: PolicyUpdatable {}` 接入，OnlineTrainer 不改一行。
///
/// forward / stochasticSample 是**非 mutating**（推理只读快照）；updatePPO 是
/// **mutating**（训练改策略参数）。要求实现是值语义（struct），双缓冲才成立。
public protocol PolicyUpdatable {
    /// 前向：stateToken(256) → 竖直/水平 logits + 状态价值。
    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float)
    /// 在给定 logits 上做 softmax 采样，返回动作类别与旧策略下的 log 概率。
    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double)
    /// PPO 更新：transitions 里已带 advantage / valueTarget（由本类 GAE 填好）。
    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics
}

extension PolicyUpdatable {
    /// 可复现采样：只依赖 `forward` + 注入的确定性 RNG，返回完整采样快照
    /// （含 old logProb 与 value）。给自检用固定种子拿到可复现的学习收益断言。
    /// 生产热路径仍用 `stochasticSample`（系统随机数）；此实现不改变策略语义。
    public func sampleSeeded(stateToken: [Float], rng: inout SplitMix64) -> PolicySample {
        let (vLogits, hLogits, value) = forward(stateToken: stateToken)
        let pv = RLMath.softmax(vLogits)
        let ph = RLMath.softmax(hLogits)
        let vClass = RLMath.sampleCategorical(pv, rng: &rng)
        let hClass = RLMath.sampleCategorical(ph, rng: &rng)
        let lv = RLMath.logSoftmax(vLogits)
        let lh = RLMath.logSoftmax(hLogits)
        return PolicySample(vClass: vClass, hClass: hClass,
                            logProbV: vClass < lv.count ? lv[vClass] : 0,
                            logProbH: hClass < lh.count ? lh[hClass] : 0,
                            value: Double(value))
    }
}

// ============================================================================
// MARK: - 数据结构
// ============================================================================

/// 采样出来的联合动作（竖直 3 类 × 水平 3 类）。
public struct RLAction {
    public var vClass: Int
    public var hClass: Int
    public init(vClass: Int, hClass: Int) {
        self.vClass = vClass
        self.hClass = hClass
    }
}

/// 一次动作采样的**完整快照**：动作类别 + 采样时旧策略对该动作的 log 概率 + 状态价值。
/// P1-1 的关键：collect 直接用它保存 old logProb/value，绝不再二次 forward（否则后台
/// 已发布新策略会导致 old 与动作口径不一致）。
public struct PolicySample {
    public var vClass: Int
    public var hClass: Int
    public var logProbV: Double
    public var logProbH: Double
    public var value: Double
    public init(vClass: Int, hClass: Int, logProbV: Double, logProbH: Double, value: Double) {
        self.vClass = vClass
        self.hClass = hClass
        self.logProbV = logProbV
        self.logProbH = logProbH
        self.value = value
    }
    public var action: RLAction { RLAction(vClass: vClass, hClass: hClass) }
}

/// 奖励权重。2026-11-20 按极限竞速游戏的驾驶语义重做：
///   · 速度：<100 负分、100~160 加分、>160 轻微扣分（鼓励保持 100+ 的高速走线）
///   · 卡死：<1km/h 罚
///   · 碰撞：由「按油门但速度骤降」推断（见 OnlineTrainingRuntime.runningCollisionDetector）
///   · 倒车：模型按 S 键且速度 30~40 连续 N 帧 → 罚（OCR 读不出倒挡，用动作判）
///   · 接管：人类接管重罚
/// ⚠️ 已删除 lane（车道偏离）与 decel（急减速）两项：
///   本作是极限竞速游戏，走线本就要偏离车道追求速度；过弯掉速由「速度<100 负分」直接覆盖。
public struct RewardConfig {
    public var speed: Double
    public var stuck: Double
    public var collision: Double
    public var reverse: Double
    public var takeover: Double
    /// 速度归一上限（km/h）＝三段奖励的下分界。
    public static let speedNormKmh: Double = 100.0
    /// 速度三段奖励的下分界（km/h）：v<下分界 → 负分（按差距扣）。
    public static let speedLowKmh: Double = speedNormKmh
    /// 速度三段奖励的上分界（km/h）：下分界≤v≤上分界 → 线性递增正分；v>上分界 → 负分（按超出扣）。
    public static let speedHighKmh: Double = 160.0
    /// 判定「卡死」的速度阈值（km/h）。
    public static let stuckSpeedKmh: Double = 1.0
    /// 倒车判定的速度带宽（km/h）：模型按 S 且速度落在此区间 → 视为倒车。
    /// 依据：正常前进时按 S 会瞬间刹停，不会稳定停在 30~40；稳定在 30~40 且按 S = 惯性/坡道倒车。
    public static let reverseSpeedLowKmh: Double = 30.0
    public static let reverseSpeedHighKmh: Double = 40.0
    /// 倒车需连续确认的帧数（防抖）：连续 N 帧满足才罚，避免单帧噪声误判。
    public static let reverseConfirmFrames: Int = 3
    /// 碰撞判定（按油门但速度骤降）：上一帧速度须 ≥ 此值才有意义（低速抖动不算撞）。
    public static let collisionMinPrevSpeedKmh: Double = 100.0
    /// 单帧速度骤降阈值（km/h）：按油门时一帧内掉落超过它 → 视作撞到东西。
    /// 依据：正常松开油门一帧掉速远小于此（20Hz 下一帧约 50ms）；撞墙会瞬间断崖式掉落。
    public static let collisionSpeedDropKmh: Double = 30.0

    public init(speed: Double = 1.0,
                stuck: Double = 0.5,
                collision: Double = 5.0,
                reverse: Double = 1.5,
                takeover: Double = 10.0) {
        self.speed = speed
        self.stuck = stuck
        self.collision = collision
        self.reverse = reverse
        self.takeover = takeover
    }
}

/// 在线循环自有的「一次更新摘要」，写进环形缓冲供 UI 画曲线。
/// 为什么不直接用 PPOMetrics：那是单次 updatePPO 的产出；而 meanReward 是在线环境里
/// 由 OnlineTrainer 回填的（PPOMetrics 不产生它），updateIndex 也由环形缓冲维护。
public struct TrainingMetrics {
    public var policyLoss: Double
    public var valueLoss: Double
    public var entropy: Double
    public var approxKL: Double
    public var meanReward: Double
    public var updateIndex: Int

    public init(policyLoss: Double = 0, valueLoss: Double = 0, entropy: Double = 0,
                approxKL: Double = 0, meanReward: Double = 0, updateIndex: Int = 0) {
        self.policyLoss = policyLoss
        self.valueLoss = valueLoss
        self.entropy = entropy
        self.approxKL = approxKL
        self.meanReward = meanReward
        self.updateIndex = updateIndex
    }
}

// ============================================================================
// MARK: - 数值工具（softmax / logSoftmax / 采样）+ 可复现 RNG
// ============================================================================

public enum RLMath {
    public static func softmax(_ logits: [Float]) -> [Double] {
        softmaxD(logits.map { Double($0) })
    }

    public static func softmaxD(_ logits: [Double]) -> [Double] {
        let n = logits.count
        if n == 0 { return [] }
        var maxLogit = -Double.greatestFiniteMagnitude
        for x in logits where x.isFinite { if x > maxLogit { maxLogit = x } }
        if maxLogit == -Double.greatestFiniteMagnitude { maxLogit = 0 }
        var exps = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let e = logits[i].isFinite ? exp(logits[i] - maxLogit) : 0.0
            exps[i] = e
            sum += e
        }
        if sum <= 0 || !sum.isFinite {
            return [Double](repeating: 1.0 / Double(n), count: n)
        }
        for i in 0..<n { exps[i] /= sum }
        return exps
    }

    public static func logSoftmax(_ logits: [Float]) -> [Double] {
        let z = logits.map { Double($0) }
        let n = z.count
        if n == 0 { return [] }
        var maxLogit = -Double.greatestFiniteMagnitude
        for x in z where x.isFinite { if x > maxLogit { maxLogit = x } }
        if maxLogit == -Double.greatestFiniteMagnitude { maxLogit = 0 }
        var logSum = 0.0
        for x in z {
            let v = x.isFinite ? x - maxLogit : -Double.greatestFiniteMagnitude
            if v > -Double.greatestFiniteMagnitude { logSum += exp(v) }
        }
        let logZ = log(logSum)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let v = z[i].isFinite ? z[i] - maxLogit : -Double.greatestFiniteMagnitude
            out[i] = v - logZ
        }
        return out
    }

    /// 按概率做一次分类采样。空输入返回 0；累计概率法，越界兜底最后一项。
    public static func sampleCategorical(_ p: [Double], rng: inout SplitMix64) -> Int {
        guard !p.isEmpty else { return 0 }
        let u = rng.nextUnit()
        var acc = 0.0
        for i in 0..<p.count {
            acc += p[i]
            if u < acc { return i }
        }
        return p.count - 1
    }
}

/// 可复现的伪随机数发生器（SplitMix64）。自检要确定性，不能用系统熵。
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
    public mutating func nextGaussian() -> Double {
        // Box–Muller（不追求极致性能，够自检用）。
        var u1 = nextUnit()
        if u1 < 1e-12 { u1 = 1e-12 }
        let u2 = nextUnit()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }
}

// ============================================================================
// MARK: - OnlineTrainer 主类
// ============================================================================

public final class OnlineTrainer: @unchecked Sendable {
    // ── 策略快照（双缓冲）──
    private var inferencePolicy: any PolicyUpdatable
    private var trainingPolicy: any PolicyUpdatable
    private let lock = NSLock()

    // ── 训练调度 ──
    private let trainingQueue: DispatchQueue
    private let rewardConfig: RewardConfig
    public let ppoConfig: PPOConfig
    /// 每积累多少条 transition 触发一次「缓冲截断」更新（episode 真正结束也会训练）。
    /// 注意：缓冲截断会扣下最后一条不训（保留 bootstrap），见 flushBufferCap。
    public let trainEvery: Int

    // ── 主线程独占的采集态 ──
    private var pendingTransitions: [RLTransition] = []
    private var episodeRewardAccumulator: Double = 0
    private var recentEpisodeReturns: [Double] = []
    private let recentEpisodeWindow = 50
    private var previousSpeedKmh: Double = 0
    private var previousSpeedValid: Bool = false

    // ── 指标环形缓冲（跨线程读，metricsLock 保护）──
    private var metricsBuffer: [TrainingMetrics] = []
    private let metricsCapacity: Int
    private let metricsLock = NSLock()
    private var updateCounter = 0

    // ── 自检钩子状态（跨线程，metricsLock 保护）──
    /// P2-C：自检捕获默认**关闭**，且有界（最多 64 批），避免持续训练时内存无界增长。
    private var captureBatchesEnabled = false
    private var capturedBatchesForTest: [[RLTransition]] = []
    private let captureBatchesCapacity = 64

    public init(policy: any PolicyUpdatable,
                rewardConfig: RewardConfig = RewardConfig(),
                ppoConfig: PPOConfig = PPOConfig(),
                trainEvery: Int = 64,
                metricsCapacity: Int = 200) {
        self.inferencePolicy = policy
        self.trainingPolicy = policy
        self.rewardConfig = rewardConfig
        self.ppoConfig = ppoConfig
        self.trainEvery = trainEvery
        self.metricsCapacity = max(1, metricsCapacity)
        self.trainingQueue = DispatchQueue(label: "aurora.online-trainer.train", qos: .utility)
    }

    // ── 公开：采样动作（主线程）────────────────────────────────────────────
    /// 用当前推理快照前向 + 采样，返回**完整采样快照**（P1-1：调用方须把整份快照
    /// 原样交给 collect，collect 不再二次 forward）。
    public func sampleAction(stateToken: [Float]) -> PolicySample {
        lock.lock()
        let (vLogits, hLogits, value) = inferencePolicy.forward(stateToken: stateToken)
        let sample = inferencePolicy.stochasticSample(vLogits: vLogits, hLogits: hLogits)
        lock.unlock()
        return PolicySample(vClass: sample.vClass, hClass: sample.hClass,
                            logProbV: sample.logProbV, logProbH: sample.logProbH,
                            value: Double(value))
    }

    /// 当前推理快照在给定 state 下的动作分布（给自检断言「发布后分布变了」）。
    public func actionDistribution(stateToken: [Float]) -> (v: [Double], h: [Double]) {
        lock.lock()
        let (vLogits, hLogits, _) = inferencePolicy.forward(stateToken: stateToken)
        lock.unlock()
        return (RLMath.softmax(vLogits), RLMath.softmax(hLogits))
    }

    // ── 公开：逐帧采集（主线程）────────────────────────────────────────────
    /// 收集一帧。**P1-1**：`sample` 是采样时的完整快照，这里原样保存 logProb/value，
    /// 绝不重新 forward。**P1-3**：tookOver 帧不为人类动作建 transition，而是把接管
    /// 惩罚归因到上一条 AI transition 并封口 episode。
    /// - Returns: 这一帧的原始即时奖励（供调用方观测/打日志，不代表训练口径）。
    @discardableResult
    public func collect(stateToken: [Float],
                        sample: PolicySample,
                        tookOver: Bool,
                        speedKmh: Double,
                        speedValid: Bool,
                        collision: Bool,
                        laneOffset: Double,
                        isTerminal: Bool) -> Double {
        collect(stateToken: stateToken, sample: sample, tookOver: tookOver, speedKmh: speedKmh,
                speedValid: speedValid, collision: collision, laneOffset: laneOffset,
                isTerminal: isTerminal, laneMeasurement: nil, reverseConfirmed: false)
    }

    @discardableResult
    func collect(stateToken: [Float], sample: PolicySample, tookOver: Bool, speedKmh: Double,
                 speedValid: Bool, collision: Bool, laneOffset: Double, isTerminal: Bool,
                 laneMeasurement: TrainingLaneMeasurement?,
                 reverseConfirmed: Bool = false) -> Double {
        // ① 逐帧奖励（与 reward.py 同语义，prev_speed/prev_valid 跨帧保持）
        let frameRewardValue = Self.frameReward(
            signals: RewardSignals(speedKmh: speedKmh, speedValid: speedValid,
                                   laneOffset: laneOffset, collided: collision, tookOver: tookOver),
            previousSpeedKmh: previousSpeedKmh,
            previousSpeedValid: previousSpeedValid,
            config: rewardConfig,
            reverseConfirmed: reverseConfirmed)

        // ② 推进上一帧速度状态（P2：NaN/无效 → previousValid=false，下一帧 decel 被抑制）
        if speedValid && speedKmh.isFinite {
            previousSpeedKmh = speedKmh
            previousSpeedValid = true
        } else {
            // speedValid=false 或 speed 非有限：保留旧 speed 供日志，但标 prev 无效，
            // 与 reward.py 的有限性检查等价 —— 杜绝「stale 有限值 vs 新值」伪造急减速。
            previousSpeedValid = false
        }

        // ③ P1-3 + P1-B：人工接管 —— 人类救援动作不进策略梯度。
        //    把 -takeover 归因到**上一条由策略执行的 AI transition**（作为其额外 reward），并把它
        //    标记为真实终止（接管＝本 episode 由人接管而结束，是**真实终止**，不是 UNKNOWN 那种
        //    "后继不可知"），用 flushTerminated 整批训练。
        //    这样当 pending 恰好只剩 1 条（缓冲截断后）时，该条带上 -10、以终止 semantics 单独成批；
        //    配合 normalizeAdvantages 的 n==1 返回原始优势（P1-B 修复），惩罚能真正进 actor 梯度，
        //    不会像「加罚后又被 P1-A 当 UNKNOWN 丢弃 / 或单样本归一化成 0」那样失效。
        if tookOver {
            let takeoverPenalty = -rewardConfig.takeover
            if let lastIdx = pendingTransitions.indices.last {
                pendingTransitions[lastIdx].reward += takeoverPenalty
                pendingTransitions[lastIdx].isTerminal = true
                episodeRewardAccumulator += frameRewardValue
                flushTerminated()            // 整批（末条已置终止）按真实终止训练
                resetRewardState()
            } else {
                // 没有可归因的策略帧：丢弃惩罚，绝不为人类动作伪造 transition。
                episodeRewardAccumulator += frameRewardValue
                resetRewardState()
            }
            return frameRewardValue
        }

        // ④ 正常策略帧：用采样快照原样保存 old logProb / value（P1-1）
        var transition = RLTransition(stateToken: stateToken,
                                      vClass: sample.vClass,
                                      hClass: sample.hClass,
                                      logProbV: sample.logProbV,
                                      logProbH: sample.logProbH,
                                      reward: frameRewardValue,
                                      value: sample.value,
                                      tookOver: false,
                                      isTerminal: isTerminal)
        transition.laneMeasurement = laneMeasurement
        pendingTransitions.append(transition)
        episodeRewardAccumulator += frameRewardValue

        // ⑤ 真实 episode 结束 → 归档回报 + 整批训练 + 复位 reward 状态
        if isTerminal {
            recentEpisodeReturns.append(episodeRewardAccumulator)
            if recentEpisodeReturns.count > recentEpisodeWindow {
                recentEpisodeReturns.removeFirst(recentEpisodeReturns.count - recentEpisodeWindow)
            }
            flushEpisodeEnd()
            resetRewardState()
        } else if trainEvery > 0 && pendingTransitions.count >= trainEvery {
            // ⑥ 缓冲上限 → 截断训练（扣下最后一条，保留 bootstrap，见 flushBufferCap）
            flushBufferCap()
        }
        return frameRewardValue
    }

    /// P1-4 / P1-A：封口当前轨迹（用于 UNKNOWN 缺口 / 无有效状态 / 非有限帧）——不伪造
    /// transition。实现并非「整段以 tailBootstrapValue=0 训练」，而是：**丢弃没有可靠后继的
    /// 末条**，用它自身已估计的 value 作为「后继状态价值」的代理去 bootstrap 前面的有效前缀
    /// （对前缀 [0..n-2] 传 tail = 末条 value）；整段无有效前缀（n≤1）时直接丢弃、不训练。
    /// 清空后从新轨迹重新开始。不计入「已完成 episode」（它不是自然结束）。
    /// 注意：人工接管走的是 flushTerminated（真实终止），不是本方法。
    public func sealEpisode() { markInvalid() }

    /// sealEpisode 的别名，语义同「当前帧无效 / 状态不可用」。
    public func markInvalid() {
        flushSealed()
        resetRewardState()
    }

    /// 阻塞到当前已排队的训练全部跑完（自检/收尾用）。
    public func drainTrainingAndWait() { trainingQueue.sync { } }

    // ── 公开：指标读出 ────────────────────────────────────────────────────
    public var recentMetrics: [TrainingMetrics] {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return metricsBuffer
    }

    public var meanEpisodeReward: Double {
        guard !recentEpisodeReturns.isEmpty else { return 0 }
        return recentEpisodeReturns.reduce(0, +) / Double(recentEpisodeReturns.count)
    }
    public var completedEpisodeCount: Int { recentEpisodeReturns.count }

    // ========================================================================
    // MARK: - 内部：训练调度（三种 flush，语义严格区分）
    // ========================================================================

    /// 真实 episode 结束：整批训练。末条 isTerminal=true，computeGAE 自然按终止处理。
    private func flushEpisodeEnd() {
        guard !pendingTransitions.isEmpty else { return }
        let batch = pendingTransitions
        pendingTransitions.removeAll(keepingCapacity: true)
        trainAsync(batch, tailBootstrapValue: 0)
    }

    /// 缓冲上限截断：**扣下最后一条不训**，对其余子批训练并把扣下那条的 value 作为
    /// 尾 bootstrap（下一步 q 值估计），避免把「批次截断」错当「episode 终止」丢 bootstrap。
    private func flushBufferCap() {
        guard pendingTransitions.count >= 2 else { return }  // 至少留 1 条续跑
        let heldBack = pendingTransitions.removeLast()
        let batch = pendingTransitions
        pendingTransitions = [heldBack]
        trainAsync(batch, tailBootstrapValue: heldBack.value)
    }

    /// 封口 **UNKNOWN / 无有效状态 / 非有限帧**（「后继状态不可知」）——**不含人工接管**
    /// （接管是真实终止，走 flushTerminated）。**P1-A**：不能拿 tail=0 硬训——tail=0 与「当
    /// terminal」在 GAE 里结果完全相同（末条后继 advantage=0），等于把「观测缺失」当「环境
    /// 终止」，会把末条 valueTarget 退化为即时 reward（reward=0 时即为归零）并向前传播。
    /// 正确做法：丢掉**没有可靠后继的末条**（其后的状态未知，不能当作终止），用它自身已估计
    /// 的 value 作为「后继状态价值」的代理，去 bootstrap 前面的有效前缀 —— 即对前缀 [0..n-2]
    /// 传 tailBootstrapValue = 末条 value。整段无有效前缀（n≤1）时直接丢弃、不训练（不伪造）。
    private func flushSealed() {
        let n = pendingTransitions.count
        guard n >= 2 else {
            pendingTransitions.removeAll(keepingCapacity: true)   // 无有效前缀：丢弃，不伪造
            return
        }
        let droppedLastValue = pendingTransitions[n - 1].value    // 不可靠末条的自价值（代理后继）
        let prefix = Array(pendingTransitions[0..<(n - 1)])       // 丢掉不可靠末条
        pendingTransitions.removeAll(keepingCapacity: true)
        trainAsync(prefix, tailBootstrapValue: droppedLastValue)
    }

    /// 收尾一个「已明确终止」的轨迹（真实终止，**与 UNKNOWN 丢尾语义相反**）：整批训练，
    /// 末条已 isTerminal=true，computeGAE 按真实终止处理（nextV=0）。
    /// 用于人工接管：不追加新 transition，而是把 -takeover 惩罚并入**上一条 AI transition** 并将其
    /// 置为 terminal，然后在此收尾训练该批（惩罚进入 actor 梯度）。
    private func flushTerminated() {
        guard !pendingTransitions.isEmpty else { return }
        let batch = pendingTransitions
        pendingTransitions.removeAll(keepingCapacity: true)
        trainAsync(batch, tailBootstrapValue: 0)
    }

    /// 后台串行执行：GAE（含 tail bootstrap）→ 优势归一化（valueTarget 保留原始）→ PPO → 发布。
    private func trainAsync(_ batch: [RLTransition], tailBootstrapValue: Double) {
        guard !batch.isEmpty else { return }
        let meanRewardSnapshot = meanEpisodeReward
        let cfg = ppoConfig
        trainingQueue.async { [weak self] in
            guard let self else { return }
            var withAdvantage = batch
            // P1-2：只按 isTerminal 判边界；末条若未终止，用 tailBootstrapValue 做 bootstrap。
            PolicyHead.computeGAE(&withAdvantage, gamma: cfg.gamma, lam: cfg.lam,
                                  tailBootstrapValue: tailBootstrapValue)
            // 归一化只作用于 advantage；valueTarget 保留 computeGAE 写好的「原始 adv+value」。
            let normalized = Self.normalizeAdvantages(withAdvantage.map { $0.advantage })
            for i in withAdvantage.indices { withAdvantage[i].advantage = normalized[i] }
            // 自检钩子（P2-C）：仅当显式开启时、且有界环形追加（默认关闭，不占内存）。
            // 读开关与追加/裁剪在同一锁域内完成，避免锁外读开关的条件性数据竞争。
            self.metricsLock.lock()
            if self.captureBatchesEnabled {
                self.capturedBatchesForTest.append(withAdvantage)
                if self.capturedBatchesForTest.count > self.captureBatchesCapacity {
                    self.capturedBatchesForTest.removeFirst(
                        self.capturedBatchesForTest.count - self.captureBatchesCapacity)
                }
            }
            self.metricsLock.unlock()
            let metrics = self.trainingPolicy.updatePPO(transitions: withAdvantage, config: cfg)
            self.lock.lock()
            self.inferencePolicy = self.trainingPolicy
            self.lock.unlock()
            self.appendMetric(TrainingMetrics(policyLoss: metrics.policyLoss,
                                              valueLoss: metrics.valueLoss,
                                              entropy: metrics.entropy,
                                              approxKL: metrics.approxKL,
                                              meanReward: meanRewardSnapshot))
        }
    }

    private func resetRewardState() {
        episodeRewardAccumulator = 0
        previousSpeedKmh = 0
        previousSpeedValid = false
    }

    private func appendMetric(_ metrics: TrainingMetrics) {
        metricsLock.lock()
        updateCounter += 1
        var m = metrics
        m.updateIndex = updateCounter
        metricsBuffer.append(m)
        if metricsBuffer.count > metricsCapacity {
            metricsBuffer.removeFirst(metricsBuffer.count - metricsCapacity)
        }
        metricsLock.unlock()
    }

    // ========================================================================
    // MARK: - 自检钩子（internal，同 target 的 OnlineTrainerSelfTest 可用）
    // ========================================================================

    /// 当前推理快照（自检用固定种子对真实 PolicyHead 采样，需与训练保持同一快照）。
    func currentPolicyForTest() -> any PolicyUpdatable {
        lock.lock(); defer { lock.unlock() }
        return inferencePolicy
    }

    /// 直接注入一份策略（模拟「采样后、collect 前后台发布了新策略」的竞态场景）。
    func injectPolicyForTest(_ policy: any PolicyUpdatable) {
        lock.lock(); inferencePolicy = policy; trainingPolicy = policy; lock.unlock()
    }

    /// 当前待训练缓冲的 transition 快照（只读拷贝）。
    func pendingTransitionsForTest() -> [RLTransition] {
        pendingTransitions
    }

    /// 已被训练过的批次（按训练先后；含归一化后的 advantage 与原始 valueTarget）。
    func capturedBatchesForTestSnapshot() -> [[RLTransition]] {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return capturedBatchesForTest
    }

    func clearCapturedBatchesForTest() {
        metricsLock.lock(); capturedBatchesForTest.removeAll(); metricsLock.unlock()
    }

    /// P2-C：自检显式开启/关闭批次捕获（默认关闭；开启后仍有界 64 批）。
    func setCaptureBatchesForTest(_ on: Bool) {
        metricsLock.lock(); captureBatchesEnabled = on; metricsLock.unlock()
    }

    private static func clampClass(_ value: Int, count: Int) -> Int {
        if count <= 0 { return 0 }
        return min(max(value, 0), count - 1)
    }

    // ========================================================================
    // MARK: - 奖励（纯函数，逐项对齐 reward.py）
    // ========================================================================

    public struct RewardSignals {
        public var speedKmh: Double
        public var speedValid: Bool
        public var laneOffset: Double
        public var collided: Bool
        public var tookOver: Bool
        public init(speedKmh: Double, speedValid: Bool, laneOffset: Double,
                    collided: Bool, tookOver: Bool) {
            self.speedKmh = speedKmh
            self.speedValid = speedValid
            self.laneOffset = laneOffset
            self.collided = collided
            self.tookOver = tookOver
        }
    }

    /// 速度三段奖励（归一化到 [-1, +1]）：
    ///   · v < 100（下分界）：负分，按差距扣 —— -(100 - v)/100，v=0 最负（-1.0）；
    ///   · 100 ≤ v ≤ 160：线性递增正分 —— (v - 100)/60，v=100 为 0，v=160 最大（+1.0）；
    ///   · v > 160（上分界）：**轻微扣分** —— -(v - 160)/600（160→161 仅 -0.0017，扣得很轻）。
    /// speedValid=false 或速度非有限/为负 → 该项为 0（不伪造奖励）。
    public static func speedTerm(_ speedKmh: Double, _ speedValid: Bool) -> Double {
        guard speedValid, speedKmh.isFinite, speedKmh >= 0 else { return 0 }
        if speedKmh < RewardConfig.speedLowKmh {
            return -(RewardConfig.speedLowKmh - speedKmh) / RewardConfig.speedLowKmh
        }
        if speedKmh <= RewardConfig.speedHighKmh {
            return (speedKmh - RewardConfig.speedLowKmh)
                / (RewardConfig.speedHighKmh - RewardConfig.speedLowKmh)
        }
        // v>160：轻微扣分。分母 600 = (160-100)×10 → 扣得只有正向增益的 1/10 量级。
        return -(speedKmh - RewardConfig.speedHighKmh)
            / ((RewardConfig.speedHighKmh - RewardConfig.speedLowKmh) * 10.0)
    }

    public static func isStuck(_ speedKmh: Double, _ speedValid: Bool) -> Bool {
        speedValid && speedKmh.isFinite && speedKmh < RewardConfig.stuckSpeedKmh
    }

    /// 倒车判据（纯函数）：模型本帧选了 S 键（vClass=2）且速度落在 [30,40] → 该帧"疑似倒车"。
    /// 连续确认帧数由调用方（运行时）维护计数器，本函数只判单帧。
    public static func isReverseFrame(vClass: Int, speedKmh: Double, speedValid: Bool) -> Bool {
        guard vClass == 2, speedValid, speedKmh.isFinite else { return false }
        return speedKmh >= RewardConfig.reverseSpeedLowKmh
            && speedKmh <= RewardConfig.reverseSpeedHighKmh
    }

    /// 一帧奖励 = 速度段 − 卡死 − 碰撞 − 倒车 + 接管强负。
    /// ⚠️ lane/decel 已删除（见 RewardConfig 注释）。`reverseConfirmed` 由运行时的
    /// 连续帧计数器产出（连续 N 帧 isReverseFrame 才为 true），避免单帧噪声。
    public static func frameReward(signals: RewardSignals,
                                   previousSpeedKmh: Double,
                                   previousSpeedValid: Bool,
                                   config: RewardConfig,
                                   reverseConfirmed: Bool = false) -> Double {
        var r = 0.0
        r += config.speed * speedTerm(signals.speedKmh, signals.speedValid)
        if isStuck(signals.speedKmh, signals.speedValid) { r -= config.stuck }
        if signals.collided { r -= config.collision }
        if reverseConfirmed { r -= config.reverse }
        if signals.tookOver { r -= config.takeover }
        return r
    }

    // ========================================================================
    // MARK: - 优势归一化（reward.py 的 normalize_advantages）
    // ========================================================================

    public static func normalizeAdvantages(_ adv: [Double], eps: Double = 1e-8) -> [Double] {
        let n = adv.count
        guard n > 0 else { return adv }
        for x in adv where !x.isFinite { return [Double](repeating: 0, count: n) }
        let mean = adv.reduce(0, +) / Double(n)
        var variance = 0.0
        for x in adv { let d = x - mean; variance += d * d }
        variance /= Double(n)
        let std = variance.squareRoot()
        if std < eps {
            // P1-B：单样本批（n==1）不能归一化成 0——否则该动作的策略梯度被清零，接管惩罚等
            // 只会训练 critic、actor 拿不到梯度。单样本直接返回其**原始优势**（PPO ratio 仍正常量级）。
            // 常量多元素批仍返 0（无优势方差 ⇒ 无策略梯度信息）。
            if n == 1 { return [adv[0]] }
            return [Double](repeating: 0, count: n)
        }
        return adv.map { ($0 - mean) / (std + eps) }
    }
}

// ============================================================================
// MARK: - PolicyHead 接入（一行把 B 的真实头接进在线循环）
// ============================================================================

extension PolicyHead: PolicyUpdatable {}
