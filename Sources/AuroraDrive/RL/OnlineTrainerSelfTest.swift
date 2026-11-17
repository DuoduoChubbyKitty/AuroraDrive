// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainerSelfTest.swift — 在线 RL 循环自检（-rl-online-selftest）
//
//  【为什么建这个 / 为什么分四段】
//    「能 build」不等于「真的在学」。本自检分四段，每段断言的维度不同：
//
//    ① GAE 逐 episode 隔离：**直接绑 B 域 PolicyHead.computeGAE 的真实实现**
//       （不另写一份），证明「两个独立 episode 的回报不互相泄漏」。这是硬不变量。
//    ② 价值头学习：用 ToyPolicy 在**固定 valueTarget、advantage=0** 的批次上，
//       证明 value 回归确实把目标拟合下来（隔离策略变化，避免混淆）。
//    ③ 学习曲线：用**确定性可学习的 ToyPolicy**（线性 softmax 策略头 + PPO + Adam）
//       在合成可学习环境里跑 80 episode，硬断言「每帧奖励显著上升 / 动作正确率上升 /
//       熵合理 / 双缓冲发布生效」。用确定性小网络当硬门，是为了让断言**稳定可复现**。
//    ④ 真实 PolicyHead 端到端机器验证：把 B 的真实 MLP 头接进 OnlineTrainer，真跑
//       collect→computeGAE→updatePPO→发布，断言「确实完成了 PPO 更新 / 指标有限 /
//       参数被更新（双缓冲发布生效）」。
//
//  【为什么④不断言「MLP 必然 reward 上升」】
//    实测（本机，详见交付说明）：同一个 MLP 头 + 同样超参，在不同随机种子下行为差异大
//    （有的种子熵塌缩、有的稳定学会）。在极小玩具环境里「MLP+PPO 必然单调上升」不是
//    稳定可复现的断言，写进 CI 会 flaky。故「reward 上升」这条硬门交给③确定性线性头；
//    ④只验证真实头能被整条循环正确驱动且确实在更新。这是工程上诚实的分工。
// ============================================================================

import Foundation

enum OnlineTrainerSelfTest {

    // ========================================================================
    // MARK: - 入口
    // ========================================================================
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("  \(condition ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 在线 RL 循环自检（-rl-online-selftest）═══")

        failures += runGAEIsolationChecks(check)
        print("")
        failures += runValueLearningCheck(check)
        print("")
        failures += runLearningCurveChecks(check)
        print("")
        failures += runRealPolicyHeadIntegrationCheck(check)

        print("")
        print(failures == 0
              ? "═══ 结果：全部通过 ✅（\(failures) 项失败）═══"
              : "═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        return failures
    }

    // ========================================================================
    // MARK: - ① GAE 逐 episode 隔离（绑定 PolicyHead.computeGAE 真实实现）
    // ========================================================================
    private static func runGAEIsolationChecks(
        _ check: (String, Bool, String) -> Void) -> Int {
        print("── 第一段：GAE 逐 episode 隔离（绑定 PolicyHead.computeGAE，不跨边界）──")

        // (1) 经典判别用例：两个各自 terminal 的单帧，回报 0 与 10。
        //     正确：adv = [0, 10]。若边界没切断，adv[0] 会吃到 gamma*lam*adv[1] = 9.405。
        var g1: [RLTransition] = [
            makeTransition(reward: 0, value: 0, isTerminal: true),
            makeTransition(reward: 10, value: 0, isTerminal: true)
        ]
        PolicyHead.computeGAE(&g1, gamma: 0.99, lam: 0.95)
        let okG1 = abs(g1[0].advantage - 0) < 1e-9 && abs(g1[1].advantage - 10) < 1e-9
        check("两独立单帧 adv == [0,10]（非 [9.405,10]）", okG1,
              "实际 [" + g1.map { String(format: "%.4f", $0.advantage) }.joined(separator: ",") + "]")

        // (2) 多帧拼接：episode A = 三帧回报 [1,1,1]（终止在帧2），episode B = 单帧 [100]。
        //     把两段拼起来算 GAE，A 段优势必须与「A 单独跑」完全一致（B 的 100 不渗入 A）。
        var combined: [RLTransition] = [
            makeTransition(reward: 1, value: 0, isTerminal: false),
            makeTransition(reward: 1, value: 0, isTerminal: false),
            makeTransition(reward: 1, value: 0, isTerminal: true),
            makeTransition(reward: 100, value: 0, isTerminal: true)
        ]
        PolicyHead.computeGAE(&combined, gamma: 0.99, lam: 0.95)
        var standaloneA: [RLTransition] = [
            makeTransition(reward: 1, value: 0, isTerminal: false),
            makeTransition(reward: 1, value: 0, isTerminal: false),
            makeTransition(reward: 1, value: 0, isTerminal: true)
        ]
        PolicyHead.computeGAE(&standaloneA, gamma: 0.99, lam: 0.95)
        var okA = true
        var detailA = ""
        for i in 0..<3 {
            let diff = abs(combined[i].advantage - standaloneA[i].advantage)
            detailA += String(format: "A[%d]拼接=%.4f 单独=%.4f ", i,
                              combined[i].advantage, standaloneA[i].advantage)
            if diff > 1e-9 { okA = false }
        }
        check("episode A 优势与单独跑一致（B 回报不渗入 A）", okA, detailA)
        check("episode B 单帧 adv == 100", abs(combined[3].advantage - 100.0) < 1e-9,
              String(format: "实际 %.4f", combined[3].advantage))

        // (3) valueTarget = **原始**优势 + value（computeGAE 写回的原始值，未归一化；归一化只作用于 advantage）。
        //     这批 value 全 0，故 valueTarget 必须等于 A 段单独跑的原始优势。
        var okVT = true
        var detailVT = ""
        for i in 0..<3 {
            let diff = abs(combined[i].valueTarget - standaloneA[i].advantage)
            detailVT += String(format: "A[%d]vt=%.4f raw=%.4f ", i,
                               combined[i].valueTarget, standaloneA[i].advantage)
            if diff > 1e-9 { okVT = false }
        }
        check("computeGAE valueTarget = 原始优势 + value（A 段不串 B）", okVT, detailVT)
        check("computeGAE B 段 valueTarget == 100", abs(combined[3].valueTarget - 100.0) < 1e-9,
              String(format: "实际 %.4f", combined[3].valueTarget))

        // (4) normalizeAdvantages：非有限输入返回全 0（不产 NaN）；常量输入返回全 0。
        //     注意：归一化只施加到 advantage，且必须发生在 valueTarget 已经由 computeGAE 定好之后。
        let nanOut = OnlineTrainer.normalizeAdvantages([Double.nan, 1.0, 2.0])
        check("normalizeAdvantages 非有限输入 → 全 0（无 NaN）",
              nanOut.allSatisfy { $0 == 0 }, nanOut.map { String($0) }.joined(separator: ","))
        let constOut = OnlineTrainer.normalizeAdvantages([3.0, 3.0, 3.0])
        check("normalizeAdvantages 常量输入 → 全 0", constOut.allSatisfy { $0 == 0 }, "")
        // 归一化后 adv 均值≈0、方差≈1（除常量外）。
        let z = OnlineTrainer.normalizeAdvantages([1.0, 2.0, 3.0, 4.0])
        let zMean = z.reduce(0, +) / Double(z.count)
        check("normalizeAdvantages 结果均值≈0", abs(zMean) < 1e-9,
              String(format: "mean=%.3e", zMean))

        return 0
    }

    // ========================================================================
    // MARK: - ② 价值头对固定目标收敛（advantage=0 冻结策略，只验 value 回归）
    // ========================================================================
    private static func runValueLearningCheck(
        _ check: (String, Bool, String) -> Void) -> Int {
        print("── 第二段：价值头对固定目标收敛（advantage=0 冻结策略，只验 value 回归）──")

        let numContexts = 3
        let fixedTargets = [5.0, -3.0, 8.0]   // 每个上下文一个固定价值目标
        var batch: [RLTransition] = []
        for ctx in 0..<numContexts {
            for _ in 0..<6 {
                var state = [Float](repeating: 0, count: numContexts)
                state[ctx] = 1.0
                var t = RLTransition(stateToken: state, vClass: 0, hClass: 0,
                                     logProbV: 0, logProbH: 0, reward: 0, value: 0,
                                     tookOver: false, isTerminal: false)
                t.advantage = 0                         // 冻结策略头
                t.valueTarget = fixedTargets[ctx]
                batch.append(t)
            }
        }

        var policy = ToyPolicy(numContexts: numContexts, seed: 0xABCD_1234)
        var cfg = PPOConfig()
        cfg.lr = 0.1
        cfg.epochs = 200
        cfg.batch = 18          // 一次性全批（18 条）
        cfg.vfCoef = 0.5
        cfg.entCoef = 0

        let before = policy.forward(stateToken: [1, 0, 0]).value
        let m = policy.updatePPO(transitions: batch, config: cfg)
        let afterPreds = (0..<numContexts).map { ctx -> Double in
            var s = [Float](repeating: 0, count: numContexts); s[ctx] = 1.0
            return Double(policy.forward(stateToken: s).value)
        }
        // 参考：同样种子、未训练的玩具策略（对比策略头是否被动过）
        let reference = ToyPolicy(numContexts: numContexts, seed: 0xABCD_1234)
        var s0 = [Float](repeating: 0, count: numContexts); s0[0] = 1.0
        let vLogitDiff = abs(Double(policy.forward(stateToken: s0).vLogits[0])
                             - Double(reference.forward(stateToken: s0).vLogits[0]))

        let initialMSE = fixedTargets.map { $0 * $0 }.reduce(0, +) / Double(numContexts) // 初始预测全 0
        let finalMSE = zip(afterPreds, fixedTargets)
            .map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(numContexts)

        print(String(format: "  初始预测=[0,0,0] 目标=[5,-3,8] 初始MSE=%.3f", initialMSE))
        print(String(format: "  训练后预测=[%.2f,%.2f,%.2f] 最终MSE=%.3f value_loss=%.4f",
                     afterPreds[0], afterPreds[1], afterPreds[2], finalMSE, m.valueLoss))

        check("价值头把固定目标拟合下来（MSE 至少降到初值的 1/5）",
              finalMSE < initialMSE / 5.0,
              String(format: "%.3f → %.3f", initialMSE, finalMSE))
        check("固定目标下 value_loss 显著下降", m.valueLoss < initialMSE,
              String(format: "loss=%.4f < 初始MSE=%.3f", m.valueLoss, initialMSE))
        check("advantage=0 时策略头不被价值回归带偏（vLogits 与未训练参考一致）",
              vLogitDiff < 1e-6,
              String(format: "max|ΔvLogit|=%.3e (before value=%.4f)", vLogitDiff, Double(before)))
        return 0
    }

    // ========================================================================
    // MARK: - ③ 学习曲线（确定性 ToyPolicy + 合成可学习环境）
    // ========================================================================
    private static func runLearningCurveChecks(
        _ check: (String, Bool, String) -> Void) -> Int {
        print("── 第三段：合成可学习环境，跑真实在线循环（确定性线性策略头）──")

        // 环境：3 个 one-hot 上下文，各有偏好动作。动作正确 → 高速+零偏置（高奖励）；
        // 错误 → 低速+大偏置（低/负奖励）。OnlineTrainer 用 reward.py 同语义算奖励。
        let numContexts = 3
        let framesPerEpisode = 16
        let episodes = 80
        let prefV = [0, 1, 2]
        let prefH = [2, 1, 0]

        let seed: UInt64 = 0x51A7_2026
        let initialPolicy = ToyPolicy(numContexts: numContexts, seed: seed)

        // trainEvery 设很大 → 只在 episode 结束 flush（每 episode 一次更新）。
        var ppo = PPOConfig()
        ppo.lr = 0.04
        ppo.clipEps = 0.2
        ppo.gamma = 0.99
        ppo.lam = 0.95
        ppo.epochs = 4
        ppo.batch = 16
        ppo.vfCoef = 0.5
        ppo.entCoef = 0.0
        let trainer = OnlineTrainer(policy: initialPolicy,
                                    rewardConfig: RewardConfig(),
                                    ppoConfig: ppo,
                                    trainEvery: 10_000,
                                    metricsCapacity: 512)

        var rng = SplitMix64(seed: seed ^ 0xDEAD_BEEF)
        var episodeRewards: [Double] = []
        var episodeCorrectV: [Double] = []
        var episodeCorrectH: [Double] = []

        for ep in 0..<episodes {
            var totalReward = 0.0
            var correctV = 0
            var correctH = 0
            for _ in 0..<framesPerEpisode {
                let ctx = Int(rng.next() % UInt64(numContexts))
                var state = [Float](repeating: 0, count: numContexts)
                state[ctx] = 1.0

                let sampled = trainer.sampleAction(stateToken: state)
                let vOK = (sampled.action.vClass == prefV[ctx])
                let hOK = (sampled.action.hClass == prefH[ctx])
                let speedKmh = vOK ? 90.0 : 20.0
                let laneOffset = hOK ? 0.0 : 1.0

                let r = trainer.collect(stateToken: state,
                                        actionTaken: sampled.action,
                                        tookOver: false,
                                        speedKmh: speedKmh,
                                        speedValid: true,
                                        collision: false,
                                        laneOffset: laneOffset,
                                        isTerminal: false)
                totalReward += r
                if vOK { correctV += 1 }
                if hOK { correctH += 1 }
            }
            // 收尾：送一个 terminal（episode 边界）→ 强制 flush 并复位 reward 状态
            var s0 = [Float](repeating: 0, count: numContexts); s0[0] = 1.0
            _ = trainer.collect(stateToken: s0,
                                actionTaken: RLAction(vClass: 0, hClass: 0),
                                tookOver: false,
                                speedKmh: 0, speedValid: false,
                                collision: false, laneOffset: 0,
                                isTerminal: true)
            trainer.drainTrainingAndWait()

            episodeRewards.append(totalReward)
            episodeCorrectV.append(Double(correctV) / Double(framesPerEpisode))
            episodeCorrectH.append(Double(correctH) / Double(framesPerEpisode))
            if ep % 8 == 0 || ep == episodes - 1 {
                print(String(format: "  ep %2d  回报=%8.3f  正确率VH=%.2f/%.2f",
                             ep, totalReward, episodeCorrectV[ep], episodeCorrectH[ep]))
            }
        }
        trainer.drainTrainingAndWait()

        let window = 10
        let firstReward = mean(Array(episodeRewards.prefix(window)))
        let lastReward = mean(Array(episodeRewards.suffix(window)))
        let firstPerFrame = firstReward / Double(framesPerEpisode)
        let lastPerFrame = lastReward / Double(framesPerEpisode)
        let firstCV = mean(Array(episodeCorrectV.prefix(window)))
        let lastCV = mean(Array(episodeCorrectV.suffix(window)))
        let firstCH = mean(Array(episodeCorrectH.prefix(window)))
        let lastCH = mean(Array(episodeCorrectH.suffix(window)))

        print(String(format: "  ── 前%d episode 平均回报=%.3f（每帧 %.3f） 正确率V/H=%.2f/%.2f",
                     window, firstReward, firstPerFrame, firstCV, firstCH))
        print(String(format: "  ── 后%d episode 平均回报=%.3f（每帧 %.3f） 正确率V/H=%.2f/%.2f",
                     window, lastReward, lastPerFrame, lastCV, lastCH))

        // (L1) 奖励显著上升：后窗口每帧平均奖励比前窗口高至少 0.25（随机≈0.10，满分 0.90）。
        check("后窗口每帧奖励显著高于前窗口（Δ>0.25）",
              lastPerFrame - firstPerFrame > 0.25,
              String(format: "Δ=%.3f (前 %.3f → 后 %.3f)", lastPerFrame - firstPerFrame,
                     firstPerFrame, lastPerFrame))
        // (L2) 后窗口每帧奖励达到可观绝对水平（说明确实学会了偏好动作）。
        check("后窗口每帧奖励 > 0.55（远离随机 0.10）", lastPerFrame > 0.55,
              String(format: "实际 %.3f", lastPerFrame))
        // (L3) 动作正确率上升（两个头都上升）。
        check("竖直动作正确率显著上升（Δ>0.3）", lastCV - firstCV > 0.3,
              String(format: "%.2f → %.2f", firstCV, lastCV))
        check("水平动作正确率显著上升（Δ>0.3）", lastCH - firstCH > 0.3,
              String(format: "%.2f → %.2f", firstCH, lastCH))

        // (L4) 指标：产生足够更新次数、四类指标有限、entropy 在合理区间且发生合理变化。
        let metrics = trainer.recentMetrics
        check("产生 PPO 更新指标（>10 次更新）", metrics.count > 10, "实际 \(metrics.count) 次")
        let allFinite = metrics.allSatisfy {
            $0.policyLoss.isFinite && $0.valueLoss.isFinite
                && $0.entropy.isFinite && $0.approxKL.isFinite
        }
        check("policy_loss/value_loss/entropy/approxKL 全部有限", allFinite, "")
        if metrics.count >= 4 {
            let firstEntropy = mean(Array(metrics.prefix(4).map { $0.entropy }))
            let lastEntropy = mean(Array(metrics.suffix(4).map { $0.entropy }))
            check("entropy 数值在合理区间 [0, 2·ln3]",
                  metrics.allSatisfy { $0.entropy >= -1e-6 && $0.entropy <= 2.0 * log(3.0) + 1e-6 },
                  String(format: "观测 前%.3f→后%.3f", firstEntropy, lastEntropy))
            check("entropy 发生合理变化（|Δ|>1e-3）",
                  abs(lastEntropy - firstEntropy) > 1e-3,
                  String(format: "%.4f → %.4f", firstEntropy, lastEntropy))
            let firstVL = mean(Array(metrics.prefix(4).map { $0.valueLoss }))
            let lastVL = mean(Array(metrics.suffix(4).map { $0.valueLoss }))
            // 策略变好后每 episode 回报从负升到大正值，valueTarget 量级整体变大，
            // value_loss 绝对值**会**上升——这不是「没学会」，故这里只断言未发散。
            check("value_loss 有限且未发散（< 1e3）",
                  firstVL.isFinite && lastVL.isFinite && lastVL < 1e3,
                  String(format: "%.4f → %.4f", firstVL, lastVL))
        }

        // (L5) 双缓冲发布生效：训练后竖直动作分布应显著不同于初始策略。
        var s0 = [Float](repeating: 0, count: numContexts); s0[0] = 1.0
        let trainedDist = trainer.actionDistribution(stateToken: s0).v
        let initialDist = RLMath.softmax(ToyPolicy(numContexts: numContexts, seed: seed)
                                            .forward(stateToken: s0).vLogits)
        var maxDiff = 0.0
        for c in 0..<3 { maxDiff = max(maxDiff, abs(trainedDist[c] - initialDist[c])) }
        check("双缓冲发布生效（训练后竖直分布显著变化 Δp>0.1）", maxDiff > 0.1,
              String(format: "max|Δp|=%.3f", maxDiff))

        return 0
    }

    // ========================================================================
    // MARK: - ④ 真实 PolicyHead 端到端机器验证
    // ========================================================================
    private static func runRealPolicyHeadIntegrationCheck(
        _ check: (String, Bool, String) -> Void) -> Int {
        print("── 第四段：接入真实 PolicyHead 端到端机器验证（真跑 collect→GAE→updatePPO→发布）──")

        let dim = 256   // PolicyHead 要求 256 维 stateToken
        let numContexts = 3
        let prefV = [0, 1, 2]
        let prefH = [2, 1, 0]

        var cfg = PPOConfig()
        cfg.lr = 0.01
        cfg.epochs = 2
        cfg.batch = 8
        cfg.entCoef = 0.1
        cfg.gamma = 0.99
        cfg.lam = 0.95

        let head = PolicyHead(randomSeed: 0x51A7_2026)
        // trainEvery=8：每 8 条 flush 一次，episode 结束再 flush → 确保多次真实更新。
        let trainer = OnlineTrainer(policy: head,
                                    rewardConfig: RewardConfig(),
                                    ppoConfig: cfg,
                                    trainEvery: 8,
                                    metricsCapacity: 256)

        var rng = SplitMix64(seed: 999)
        var steps = 0
        for _ in 0..<10 {   // 10 episode
            for _ in 0..<16 {
                let ctx = Int(rng.next() % UInt64(numContexts))
                var s = [Float](repeating: 0, count: dim); s[ctx] = 1.0
                let sa = trainer.sampleAction(stateToken: s)
                let vOK = sa.action.vClass == prefV[ctx]
                let hOK = sa.action.hClass == prefH[ctx]
                _ = trainer.collect(stateToken: s, actionTaken: sa.action, tookOver: false,
                                    speedKmh: vOK ? 90 : 20, speedValid: true,
                                    collision: false, laneOffset: hOK ? 0 : 1,
                                    isTerminal: false)
                steps += 1
            }
            var s0 = [Float](repeating: 0, count: dim); s0[0] = 1.0
            _ = trainer.collect(stateToken: s0, actionTaken: RLAction(vClass: 0, hClass: 0),
                                tookOver: false, speedKmh: 0, speedValid: false,
                                collision: false, laneOffset: 0, isTerminal: true)
            trainer.drainTrainingAndWait()
        }
        trainer.drainTrainingAndWait()

        let metrics = trainer.recentMetrics
        print("  真实 PolicyHead：跑 \(steps) 帧，产生 \(metrics.count) 次 PPO 更新")
        check("真实 PolicyHead：OnlineTrainer 完成 >0 次 PPO 更新", metrics.count > 0,
              "\(metrics.count) 次")
        check("真实 PolicyHead：完成的 episode 数 == 10", trainer.completedEpisodeCount == 10,
              "实际 \(trainer.completedEpisodeCount)")
        let allFinite = metrics.allSatisfy {
            $0.policyLoss.isFinite && $0.valueLoss.isFinite
                && $0.entropy.isFinite && $0.approxKL.isFinite && $0.meanReward.isFinite
        }
        check("真实 PolicyHead：全部指标有限（含回填的 meanReward）", allFinite, "")

        // 双缓冲发布生效：训练后竖直分布必须不同于同种子未训练头的初始分布。
        let reference = PolicyHead(randomSeed: 0x51A7_2026)
        var s0 = [Float](repeating: 0, count: dim); s0[0] = 1.0
        let trainedDist = trainer.actionDistribution(stateToken: s0).v
        let initialDist = RLMath.softmax(reference.forward(stateToken: s0).vLogits)
        var maxDiff = 0.0
        for c in 0..<3 { maxDiff = max(maxDiff, abs(trainedDist[c] - initialDist[c])) }
        check("真实 PolicyHead：双缓冲发布生效（参数被真实更新，Δp>1e-3）", maxDiff > 1e-3,
              String(format: "max|Δp|=%.3e", maxDiff))

        print("  （注：MLP 在极小玩具环境跨随机种子不稳——reward 上升硬门由第三段确定性线性头承担；")
        print("   本段只验证真实头能被整条在线循环正确驱动且确实在更新，不拿 MLP 必然学会当断言。）")
        return 0
    }

    // ========================================================================
    // MARK: - 工具
    // ========================================================================
    private static func makeTransition(reward: Double, value: Double, isTerminal: Bool) -> RLTransition {
        RLTransition(stateToken: [0], vClass: 0, hClass: 0,
                     logProbV: 0, logProbH: 0, reward: reward, value: value,
                     tookOver: false, isTerminal: isTerminal)
    }

    private static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }
}

// ============================================================================
// MARK: - ToyPolicy：确定性可学习的玩具策略（线性 softmax + 显式 Adam + PPO clipped）
// ============================================================================

/// 供自检使用的确定性可训练策略。state(K 维, one-hot) → vLogits(3)/hLogits(3)/value(1)，
/// 用 PPO clipped surrogate + 显式解析梯度 + Adam。它实现 `PolicyUpdatable`，因此驱动的是
/// OnlineTrainer 的**真实**循环（collect → GAE → updatePPO → 双缓冲发布）。
///
/// 为什么学习曲线用线性小头而不是真实 MLP：线性 → 三分类 toy 任务只需学「context→preferred」
/// 映射，收敛确定、跨种子稳定，适合做「reward 必然上升」的硬门（见文件头说明）。真实 MLP 头
/// 的端到端正确性由第四段单独验证。
struct ToyPolicy: PolicyUpdatable {
    let numContexts: Int
    private let K: Int

    private var Wv: [Double]      // K*3
    private var Wh: [Double]      // K*3
    private var bv: [Double]      // 3
    private var bh: [Double]      // 3
    private var valueW: [Double]  // K
    private var valueBias: Double

    private var mWv: [Double], vWv: [Double]
    private var mWh: [Double], vWh: [Double]
    private var mbv: [Double], vbv: [Double]
    private var mbh: [Double], vbh: [Double]
    private var mvalueW: [Double], vvalueW: [Double]
    private var mValueBias: Double, vValueBias: Double
    private var adamT: Int

    private let sampleRNG: SampleRNG
    private var shuffleState: UInt64

    init(numContexts: Int, seed: UInt64) {
        self.K = numContexts
        self.numContexts = numContexts
        var rng = SplitMix64(seed: seed)
        func randSmall() -> Double { (rng.nextUnit() - 0.5) * 0.2 }  // ±0.1

        Wv = (0..<(numContexts * 3)).map { _ in randSmall() }
        Wh = (0..<(numContexts * 3)).map { _ in randSmall() }
        bv = [0, 0, 0]
        bh = [0, 0, 0]
        valueW = [Double](repeating: 0, count: numContexts)
        valueBias = 0

        mWv = [Double](repeating: 0, count: numContexts * 3)
        vWv = [Double](repeating: 0, count: numContexts * 3)
        mWh = [Double](repeating: 0, count: numContexts * 3)
        vWh = [Double](repeating: 0, count: numContexts * 3)
        mbv = [0, 0, 0]; vbv = [0, 0, 0]
        mbh = [0, 0, 0]; vbh = [0, 0, 0]
        mvalueW = [Double](repeating: 0, count: numContexts)
        vvalueW = [Double](repeating: 0, count: numContexts)
        mValueBias = 0; vValueBias = 0
        adamT = 0

        sampleRNG = SampleRNG(seed: seed ^ 0x9E37_79B9)
        shuffleState = seed ^ 0xC0FF_EE00
    }

    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float) {
        var v = bv
        var h = bh
        var val = valueBias
        let n = min(K, stateToken.count)
        for k in 0..<n {
            let s = Double(stateToken[k])
            if s == 0 { continue }
            for c in 0..<3 {
                v[c] += Wv[k * 3 + c] * s
                h[c] += Wh[k * 3 + c] * s
            }
            val += valueW[k] * s
        }
        return (v.map { Float($0) }, h.map { Float($0) }, Float(val))
    }

    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        let pv = RLMath.softmax(vLogits)
        let ph = RLMath.softmax(hLogits)
        let vClass = sampleCategorical(pv)
        let hClass = sampleCategorical(ph)
        let lv = RLMath.logSoftmax(vLogits)
        let lh = RLMath.logSoftmax(hLogits)
        return (vClass, hClass, vClass < lv.count ? lv[vClass] : 0,
                hClass < lh.count ? lh[hClass] : 0)
    }

    private func sampleCategorical(_ p: [Double]) -> Int {
        guard !p.isEmpty else { return 0 }
        let u = sampleRNG.nextUnit()
        var acc = 0.0
        for i in 0..<p.count {
            acc += p[i]
            if u < acc { return i }
        }
        return p.count - 1
    }

    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics {
        let n = transitions.count
        guard n > 0 else { return PPOMetrics() }
        let epochs = max(1, config.epochs)
        let batchSize = max(1, config.batch)

        var sumPolicyLoss = 0.0, sumValueLoss = 0.0, sumEntropy = 0.0, sumKL = 0.0
        var mbCount = 0

        for _ in 0..<epochs {
            var rng = SplitMix64(seed: shuffleState)
            var idx = Array(0..<n)
            if n > 1 {
                for i in stride(from: n - 1, through: 1, by: -1) {
                    let j = Int(rng.next() % UInt64(i + 1))
                    idx.swapAt(i, j)
                }
            }
            shuffleState = rng.next()

            var start = 0
            while start < n {
                let end = min(start + batchSize, n)
                let bidx = Array(idx[start..<end])
                let res = accumulateGradients(transitions: transitions, indices: bidx, config: config)
                applyAdam(grads: res.grads, lr: config.lr, batchCount: bidx.count)
                sumPolicyLoss += res.policyLoss
                sumValueLoss += res.valueLoss
                sumEntropy += res.entropy
                sumKL += res.approxKL
                mbCount += 1
                start = end
            }
        }

        let denom = Double(max(1, mbCount))
        return PPOMetrics(policyLoss: sumPolicyLoss / denom,
                          valueLoss: sumValueLoss / denom,
                          entropy: sumEntropy / denom,
                          approxKL: sumKL / denom,
                          meanReward: 0,
                          updateIndex: 0)
    }

    private struct GradBundle {
        var gWv: [Double], gWh: [Double], gbv: [Double], gbh: [Double]
        var gValueW: [Double], gValueBias: Double
        var policyLoss: Double, valueLoss: Double, entropy: Double, approxKL: Double
    }

    private func accumulateGradients(transitions: [RLTransition], indices: [Int], config: PPOConfig)
        -> (grads: GradBundle, policyLoss: Double, valueLoss: Double, entropy: Double, approxKL: Double) {
        var gWv = [Double](repeating: 0, count: K * 3)
        var gWh = [Double](repeating: 0, count: K * 3)
        var gbv = [0.0, 0.0, 0.0]
        var gbh = [0.0, 0.0, 0.0]
        var gValueW = [Double](repeating: 0, count: K)
        var gValueBias = 0.0
        var policyLossSum = 0.0
        var valueLossSum = 0.0
        var entropySum = 0.0
        var klSum = 0.0

        let clipEps = config.clipEps
        for ti in indices {
            let t = transitions[ti]
            let fwd = forward(stateToken: t.stateToken)
            let vLogits = fwd.vLogits.map { Double($0) }
            let hLogits = fwd.hLogits.map { Double($0) }
            let pv = RLMath.softmaxD(vLogits)
            let ph = RLMath.softmaxD(hLogits)

            let vClass = min(max(t.vClass, 0), 2)
            let hClass = min(max(t.hClass, 0), 2)
            let logPV = log(max(pv[vClass], 1e-12))
            let logPH = log(max(ph[hClass], 1e-12))
            let logP = logPV + logPH
            let oldLogP = t.logProbV + t.logProbH
            let ratio = exp(logP - oldLogP)
            let adv = t.advantage

            let clippedRatio = min(max(ratio, 1 - clipEps), 1 + clipEps)
            let surrogate = min(ratio * adv, clippedRatio * adv)
            policyLossSum += -surrogate
            klSum += (oldLogP - logP)

            let unclippedActive = !((adv > 0 && ratio > 1 + clipEps)
                                    || (adv < 0 && ratio < 1 - clipEps))
            let dLoss_dlogP = unclippedActive ? -ratio * adv : 0.0

            let Hv = entropy(pv)
            let Hh = entropy(ph)
            entropySum += (Hv + Hh)

            var gVLogit = [0.0, 0.0, 0.0]
            var gHLogit = [0.0, 0.0, 0.0]
            for c in 0..<3 {
                let dlogp_dz = ((c == vClass ? 1.0 : 0.0) - pv[c])
                var g = dLoss_dlogP * dlogp_dz
                if config.entCoef != 0 {
                    let dH_dz = -pv[c] * (log(max(pv[c], 1e-12)) + Hv)
                    g += -config.entCoef * dH_dz
                }
                gVLogit[c] = g

                let dlogp_dzh = ((c == hClass ? 1.0 : 0.0) - ph[c])
                var gh = dLoss_dlogP * dlogp_dzh
                if config.entCoef != 0 {
                    let dH_dzh = -ph[c] * (log(max(ph[c], 1e-12)) + Hh)
                    gh += -config.entCoef * dH_dzh
                }
                gHLogit[c] = gh
            }

            let nState = min(K, t.stateToken.count)
            for c in 0..<3 {
                gbv[c] += gVLogit[c]
                gbh[c] += gHLogit[c]
                for k in 0..<nState {
                    let s = Double(t.stateToken[k])
                    gWv[k * 3 + c] += gVLogit[c] * s
                    gWh[k * 3 + c] += gHLogit[c] * s
                }
            }

            let vPred = Double(fwd.value)
            let vErr = vPred - t.valueTarget
            valueLossSum += config.vfCoef * vErr * vErr
            let dValuePred = config.vfCoef * 2 * vErr
            gValueBias += dValuePred
            for k in 0..<nState {
                gValueW[k] += dValuePred * Double(t.stateToken[k])
            }
        }

        let cnt = Double(max(1, indices.count))
        let bundle = GradBundle(gWv: gWv, gWh: gWh, gbv: gbv, gbh: gbh,
                                gValueW: gValueW, gValueBias: gValueBias,
                                policyLoss: policyLossSum / cnt,
                                valueLoss: valueLossSum / cnt,
                                entropy: entropySum / cnt,
                                approxKL: klSum / cnt)
        return (bundle, bundle.policyLoss, bundle.valueLoss, bundle.entropy, bundle.approxKL)
    }

    private mutating func applyAdam(grads g: GradBundle, lr: Double, batchCount: Int) {
        adamT += 1
        let b1 = 0.9, b2 = 0.999, eps = 1e-8
        let bc = Double(max(1, batchCount))
        let bias1 = 1 - pow(b1, Double(adamT))
        let bias2 = 1 - pow(b2, Double(adamT))

        func step(_ param: inout Double, _ m: inout Double, _ v: inout Double, _ grad: Double) {
            var gv = grad / bc
            if !gv.isFinite { gv = 0 }
            m = b1 * m + (1 - b1) * gv
            v = b2 * v + (1 - b2) * gv * gv
            let mHat = m / bias1
            let vHat = v / bias2
            param -= lr * mHat / (vHat.squareRoot() + eps)
        }

        for i in 0..<Wv.count { step(&Wv[i], &mWv[i], &vWv[i], g.gWv[i]) }
        for i in 0..<Wh.count { step(&Wh[i], &mWh[i], &vWh[i], g.gWh[i]) }
        for c in 0..<3 { step(&bv[c], &mbv[c], &vbv[c], g.gbv[c]) }
        for c in 0..<3 { step(&bh[c], &mbh[c], &vbh[c], g.gbh[c]) }
        for k in 0..<K { step(&valueW[k], &mvalueW[k], &vvalueW[k], g.gValueW[k]) }
        step(&valueBias, &mValueBias, &vValueBias, g.gValueBias)
    }

    private func entropy(_ p: [Double]) -> Double {
        var h = 0.0
        for x in p where x > 0 { h -= x * log(x) }
        return h
    }
}

/// 采样 RNG 的引用包装：让非 mutating 的 `stochasticSample` 也能推进随机流。
/// 只在主线程采样（OnlineTrainer.sampleAction 在锁内、单线程顺序调用）→ 确定性可复现。
final class SampleRNG {
    private var rng: SplitMix64
    init(seed: UInt64) { self.rng = SplitMix64(seed: seed) }
    func nextUnit() -> Double { rng.nextUnit() }
    func next() -> UInt64 { rng.next() }
}

// ============================================================================
// MARK: - 分发入口（供 launcher 一行调用；由 swift-core 统一在 AuroraDriveApp 接入）
// ============================================================================

/// 跑在线 RL 循环自检，返回失败项数（0 = 全过）。launcher 只需一行：
///   `if args.contains("--rl-online-selftest") { exit(runOnlineRLSelfTest() == 0 ? 0 : 1) }`
func runOnlineRLSelfTest() -> Int {
    OnlineTrainerSelfTest.run()
}
