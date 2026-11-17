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
//    GAE 也复用 PolicyHead.computeGAE（语义严格照 reward.py，逐 episode 不跨边界）。
//    OnlineTrainer 只面向 `PolicyUpdatable` 协议编程，B 的头用
//    `extension PolicyHead: PolicyUpdatable {}` 接入；自检里的玩具策略也实现它。
//
//  【线程模型（硬要求）】
//    · collect / sampleAction / actionDistribution：**主线程**调用（tick 内）。
//    · 训练：后台**串行** DispatchQueue（qos .utility），串行天然互斥。
//    · 参数双缓冲：训练改 `trainingPolicy`（只在训练队列内碰），改完在锁内把
//      它**整体赋值**给 `inferencePolicy`（值语义 ⇒ 等价于复制一份快照），
//      主线程下一帧读到的就是新快照。struct 值语义是双缓冲能成立的前提。
//    · 所有跨线程共享状态：pendingTransitions/episode 累计只由主线程碰；
//      inferencePolicy 由 `lock` 保护；metrics 环形缓冲由 `metricsLock` 保护。
//
//  【奖励语义对齐 tools/v3_rl/reward.py】
//    speed（限速归一）/ stuck / collision / decel（跨 OCR 缺口用 prev_valid 防
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

/// 奖励权重，默认值与 tools/v3_rl/reward.py 的 RewardWeights 一一对应。
public struct RewardConfig {
    public var speed: Double
    public var stuck: Double
    public var collision: Double
    public var decel: Double
    public var lane: Double
    public var takeover: Double
    /// 速度归一上限（km/h）。与 reward.py 的 SPEED_NORM_KMH 一致。
    public static let speedNormKmh: Double = 100.0
    /// 判定「卡死」的速度阈值（km/h）。与 reward.py 的 STUCK_SPEED_KMH 一致。
    public static let stuckSpeedKmh: Double = 1.0

    public init(speed: Double = 1.0,
                stuck: Double = 0.5,
                collision: Double = 5.0,
                decel: Double = 2.0,
                lane: Double = 0.5,
                takeover: Double = 10.0) {
        self.speed = speed
        self.stuck = stuck
        self.collision = collision
        self.decel = decel
        self.lane = lane
        self.takeover = takeover
    }
}

/// 在线循环自有的「一次更新摘要」，写进环形缓冲供 UI 画曲线。
/// 为什么不直接用 PPOMetrics：那是单次 updatePPO 的产出；而 meanReward 是
/// 在线环境里由 OnlineTrainer 回填的（PPOMetrics 不产生它），updateIndex 也由
/// 环形缓冲维护。所以另建一个轻量封装，不污染 PolicyHead 的对外结构。
public struct TrainingMetrics {
    public var policyLoss: Double
    public var valueLoss: Double
    public var entropy: Double
    public var approxKL: Double
    /// 最近窗口 episode 的平均回报（OnlineTrainer 回填）。
    public var meanReward: Double
    /// 第几次更新（单调递增，便于 UI 画曲线）。
    public var updateIndex: Int

    public init(policyLoss: Double = 0,
                valueLoss: Double = 0,
                entropy: Double = 0,
                approxKL: Double = 0,
                meanReward: Double = 0,
                updateIndex: Int = 0) {
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

/// 数值稳定的 softmax / logSoftmax。全部 max-subtract，杜绝 exp 溢出。
public enum RLMath {
    /// softmax，返回 [Double]（与 logits 同长）。空输入返回空；全非有限退化为均匀。
    public static func softmax(_ logits: [Float]) -> [Double] {
        softmaxD(logits.map { Double($0) })
    }

    /// softmax（Double 入参）。
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

    /// log-softmax，返回 [Double]。数值稳定：log p_i = (z_i - max) - log Σ exp(z_j - max)。
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
    /// 采样一个 [0,1) 均匀数（取高 53 位对齐 double 尾数精度）。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

// ============================================================================
// MARK: - OnlineTrainer 主类
// ============================================================================

/// 在线 RL 训练器。主线程调 collect，后台串行队列训练，双缓冲发布参数。
public final class OnlineTrainer: @unchecked Sendable {
    // ── 策略快照（双缓冲）──
    /// 推理用快照：主线程 sampleAction / collect / actionDistribution 读它，`lock` 保护。
    private var inferencePolicy: any PolicyUpdatable
    /// 训练用副本：只由训练串行队列触碰，改完整体赋值给 inferencePolicy。
    private var trainingPolicy: any PolicyUpdatable
    private let lock = NSLock()

    // ── 训练调度 ──
    /// 后台串行队列：串行 ⇒ 多个 flush 天然互斥，训练不会并发改 trainingPolicy。
    private let trainingQueue: DispatchQueue
    private let rewardConfig: RewardConfig
    public let ppoConfig: PPOConfig
    /// 每积累多少条 transition 触发一次更新（episode 结束也会强制触发）。
    public let trainEvery: Int

    // ── 主线程独占的采集态 ──
    private var pendingTransitions: [RLTransition] = []
    /// 当前 episode 累计回报（主线程）。
    private var episodeRewardAccumulator: Double = 0
    /// 已完成 episode 的回报窗口（主线程），用于 meanReward。
    private var recentEpisodeReturns: [Double] = []
    private let recentEpisodeWindow = 50
    /// decel 项要的上一帧速度（含有效性），跨帧保持 —— 与 reward.py 一致。
    private var previousSpeedKmh: Double = 0
    private var previousSpeedValid: Bool = false

    // ── 指标环形缓冲（跨线程读，metricsLock 保护）──
    private var metricsBuffer: [TrainingMetrics] = []
    private let metricsCapacity: Int
    private let metricsLock = NSLock()
    private var updateCounter = 0

    /// - Parameters:
    ///   - policy: 初始策略（值类型）。会被复制成推理快照 + 训练副本两份。
    ///   - rewardConfig: 奖励权重（默认与 reward.py 对齐）。
    ///   - ppoConfig: PPO 超参（PolicyHead.swift 定义）。
    ///   - trainEvery: 每多少条 transition 触发一次更新（<=0 视为永不按数量触发，
    ///     只在 episode 结束触发）。
    ///   - metricsCapacity: 指标环形缓冲容量。
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
        self.trainingQueue = DispatchQueue(label: "aurora.online-trainer.train",
                                           qos: .utility)
    }

    // ── 公开：采样动作（主线程，动作选择阶段）──────────────────────────────
    /// 用当前推理快照前向 + 采样，返回联合动作与其旧 log 概率、状态价值。
    public func sampleAction(stateToken: [Float])
        -> (action: RLAction, logProbV: Double, logProbH: Double, value: Double) {
        lock.lock()
        let (vLogits, hLogits, value) = inferencePolicy.forward(stateToken: stateToken)
        let sample = inferencePolicy.stochasticSample(vLogits: vLogits, hLogits: hLogits)
        lock.unlock()
        return (RLAction(vClass: sample.vClass, hClass: sample.hClass),
                sample.logProbV, sample.logProbH, Double(value))
    }

    /// 当前推理快照在给定 state 下的动作分布（给自检断言「发布后分布变了」）。
    public func actionDistribution(stateToken: [Float]) -> (v: [Double], h: [Double]) {
        lock.lock()
        let (vLogits, hLogits, _) = inferencePolicy.forward(stateToken: stateToken)
        lock.unlock()
        return (RLMath.softmax(vLogits), RLMath.softmax(hLogits))
    }

    // ── 公开：逐帧采集（主线程）──────────────────────────────────────────
    /// 收集一帧：算奖励、取旧策略的 value/logProb、存 transition；到点触发更新。
    /// - Returns: 这一帧的即时奖励（便于调用方观测/打日志）。
    @discardableResult
    public func collect(stateToken: [Float],
                        actionTaken: RLAction,
                        tookOver: Bool,
                        speedKmh: Double,
                        speedValid: Bool,
                        collision: Bool,
                        laneOffset: Double,
                        isTerminal: Bool) -> Double {
        // ① 逐帧奖励（与 reward.py 完全同语义，prev_speed/prev_valid 跨帧保持）
        let reward = Self.frameReward(signals: RewardSignals(speedKmh: speedKmh,
                                                             speedValid: speedValid,
                                                             laneOffset: laneOffset,
                                                             collided: collision,
                                                             tookOver: tookOver),
                                      previousSpeedKmh: previousSpeedKmh,
                                      previousSpeedValid: previousSpeedValid,
                                      config: rewardConfig)
        // ② 推进上一帧速度状态：有效读数才更新 prev_speed；无效则保持旧值
        //    （与 reward.py 的 `prev_speed = f.speed if valid else prev_speed` 一致）。
        if speedValid && speedKmh.isFinite {
            previousSpeedKmh = speedKmh
        }
        previousSpeedValid = speedValid

        // ③ 取旧策略在「实际动作」上的 value / logProb（PPO 的 old logProb）
        lock.lock()
        let (vLogits, hLogits, value) = inferencePolicy.forward(stateToken: stateToken)
        lock.unlock()
        let logProbsV = RLMath.logSoftmax(vLogits)
        let logProbsH = RLMath.logSoftmax(hLogits)
        let vClass = Self.clampClass(actionTaken.vClass, count: vLogits.count)
        let hClass = Self.clampClass(actionTaken.hClass, count: hLogits.count)
        let logProbV = logProbsV.isEmpty ? 0 : logProbsV[vClass]
        let logProbH = logProbsH.isEmpty ? 0 : logProbsH[hClass]

        // ④ 组 transition 入缓冲
        let transition = RLTransition(stateToken: stateToken,
                                      vClass: vClass,
                                      hClass: hClass,
                                      logProbV: logProbV,
                                      logProbH: logProbH,
                                      reward: reward,
                                      value: Double(value),
                                      tookOver: tookOver,
                                      isTerminal: isTerminal)
        pendingTransitions.append(transition)
        episodeRewardAccumulator += reward

        // ⑤ episode 结束：归档回报、复位 reward 内部状态、强制触发训练
        if isTerminal {
            recentEpisodeReturns.append(episodeRewardAccumulator)
            if recentEpisodeReturns.count > recentEpisodeWindow {
                recentEpisodeReturns.removeFirst(recentEpisodeReturns.count - recentEpisodeWindow)
            }
            episodeRewardAccumulator = 0
            previousSpeedKmh = 0
            previousSpeedValid = false
        }

        // ⑥ 到量 / episode 结束 → flush
        let reachedCount = trainEvery > 0 && pendingTransitions.count >= trainEvery
        if reachedCount || isTerminal {
            flush()
        }
        return reward
    }

    /// 阻塞到当前已排队的训练全部跑完（自检/收尾用）。主线程别在热循环里调。
    public func drainTrainingAndWait() {
        trainingQueue.sync { }
    }

    // ── 公开：指标读出 ────────────────────────────────────────────────────
    /// 最近的指标快照（时间正序，最多 metricsCapacity 条）。
    public var recentMetrics: [TrainingMetrics] {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return metricsBuffer
    }

    /// 最近窗口 episode 的平均回报（主线程读）。
    public var meanEpisodeReward: Double {
        guard !recentEpisodeReturns.isEmpty else { return 0 }
        return recentEpisodeReturns.reduce(0, +) / Double(recentEpisodeReturns.count)
    }

    /// 已完成 episode 数（主线程读）。
    public var completedEpisodeCount: Int { recentEpisodeReturns.count }

    // ── 内部：flush（主线程快照 → 后台训练 → 原子发布 → 记指标）──────────────
    private func flush() {
        guard !pendingTransitions.isEmpty else { return }
        let batch = pendingTransitions
        pendingTransitions.removeAll(keepingCapacity: true)
        // 主线程先算出 meanReward 快照，避免训练队列跨线程读 recentEpisodeReturns。
        let meanRewardSnapshot = meanEpisodeReward
        let cfg = ppoConfig

        trainingQueue.async { [weak self] in
            guard let self else { return }
            // GAE（逐 episode 不跨边界）——复用 PolicyHead 的实现，语义严格照 reward.py
            var withAdvantage = batch
            PolicyHead.computeGAE(&withAdvantage, gamma: cfg.gamma, lam: cfg.lam)
            // 归一化优势（valueTarget 保持 computeGAE 写好的「原始 adv+value」不变）。
            // 与 train_rl 的 normalize_advantages 一致：PPO 策略梯度用归一化优势更稳。
            let rawAdv = withAdvantage.map { $0.advantage }
            let normalized = Self.normalizeAdvantages(rawAdv)
            for i in withAdvantage.indices { withAdvantage[i].advantage = normalized[i] }
            // 训练副本上做 PPO（epochs/batch 由 config 决定，在策略实现内完成）
            let metrics = self.trainingPolicy.updatePPO(transitions: withAdvantage, config: cfg)
            // 双缓冲发布：把训练好的副本整体赋值给推理快照（锁内原子换）
            self.lock.lock()
            self.inferencePolicy = self.trainingPolicy
            self.lock.unlock()
            // 回填 meanReward 后入环形缓冲
            let tm = TrainingMetrics(policyLoss: metrics.policyLoss,
                                     valueLoss: metrics.valueLoss,
                                     entropy: metrics.entropy,
                                     approxKL: metrics.approxKL,
                                     meanReward: meanRewardSnapshot)
            self.appendMetric(tm)
        }
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

    private static func clampClass(_ value: Int, count: Int) -> Int {
        if count <= 0 { return 0 }
        return min(max(value, 0), count - 1)
    }

    // ========================================================================
    // MARK: - 奖励（纯函数，逐项对齐 reward.py）
    // ========================================================================

    /// 一帧的原始信号（与 reward.py 的 FrameSignals 对应；human 项在线下省略）。
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

    /// speed 项：有效且 >0 时 min(speed,100)/100，否则 0。
    public static func speedTerm(_ speedKmh: Double, _ speedValid: Bool) -> Double {
        guard speedValid, speedKmh.isFinite, speedKmh > 0 else { return 0 }
        return min(speedKmh, RewardConfig.speedNormKmh) / RewardConfig.speedNormKmh
    }

    /// 是否卡死：有效且 < 1 km/h。
    public static func isStuck(_ speedKmh: Double, _ speedValid: Bool) -> Bool {
        speedValid && speedKmh.isFinite && speedKmh < RewardConfig.stuckSpeedKmh
    }

    /// 硬减速幅度 [0,1]。要求前后帧都有效（跨 OCR 缺口用 prev_valid 防伪造）。
    public static func decelTerm(previousSpeed: Double, speedKmh: Double,
                                 currentValid: Bool, previousValid: Bool) -> Double {
        guard currentValid, previousValid else { return 0 }
        guard previousSpeed.isFinite, speedKmh.isFinite else { return 0 }
        let drop = previousSpeed - speedKmh
        if drop <= 0 { return 0 }
        return min(drop / 30.0, 1.0)
    }

    /// 车道偏置项 [0,1]（绝对偏置，无世界坐标）。
    public static func laneTerm(_ laneOffset: Double) -> Double {
        guard laneOffset.isFinite else { return 0 }
        return min(abs(laneOffset), 1.0)
    }

    /// 一帧奖励 = dense（speed - stuck - collision - decel - lane）+ takeover 强负。
    /// 与 reward.py 的 dense_reward + takeover_reward 组合完全一致（human=0）。
    public static func frameReward(signals: RewardSignals,
                                   previousSpeedKmh: Double,
                                   previousSpeedValid: Bool,
                                   config: RewardConfig) -> Double {
        var r = 0.0
        r += config.speed * speedTerm(signals.speedKmh, signals.speedValid)
        if isStuck(signals.speedKmh, signals.speedValid) { r -= config.stuck }
        if signals.collided { r -= config.collision }
        r -= config.decel * decelTerm(previousSpeed: previousSpeedKmh,
                                      speedKmh: signals.speedKmh,
                                      currentValid: signals.speedValid,
                                      previousValid: previousSpeedValid)
        r -= config.lane * laneTerm(signals.laneOffset)
        if signals.tookOver { r -= config.takeover }
        return r
    }

    // ========================================================================
    // MARK: - 优势归一化（reward.py 的 normalize_advantages）
    // ========================================================================

    /// 优势归一化：非有限输入返回全 0（不产 NaN）；std 过小也返回全 0。
    /// 与 reward.py 的 normalize_advantages 一致（总体标准差 ddof=0）。
    public static func normalizeAdvantages(_ adv: [Double], eps: Double = 1e-8) -> [Double] {
        let n = adv.count
        guard n > 0 else { return adv }
        for x in adv where !x.isFinite { return [Double](repeating: 0, count: n) }
        let mean = adv.reduce(0, +) / Double(n)
        var variance = 0.0
        for x in adv { let d = x - mean; variance += d * d }
        variance /= Double(n)
        let std = variance.squareRoot()
        if std < eps { return [Double](repeating: 0, count: n) }
        return adv.map { ($0 - mean) / (std + eps) }
    }
}

// ============================================================================
// MARK: - PolicyHead 接入（一行把 B 的真实头接进在线循环）
// ============================================================================

/// 让 B 域 PolicyHead 直接实现 OnlineTrainer 的策略协议。B 的方法签名与协议
/// 逐字一致，故无需包装逻辑——空扩展即可（struct 值语义天然满足双缓冲要求）。
extension PolicyHead: PolicyUpdatable {}
