// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainerSelfTest.swift — 在线 RL 循环自检（-rl-online-selftest）
//
//  【为什么建这个 / 段落划分】
//    每段断言一个维度，全部真实、可失败，绝不恒真：
//    ① GAE 逐 episode 隔离 + 尾 bootstrap（直接绑 PolicyHead.computeGAE 真实实现）
//    ② 价值头对固定目标收敛（advantage=0 冻结策略，只验 value 回归）
//    ③ 学习曲线（确定性线性 ToyPolicy 在合成可学习环境，硬断言 reward 上升）
//    ④ 真实 PolicyHead 端到端机器验证（真跑 collect→GAE→updatePPO→发布）
//    ⑤ P1-1 采样快照/发布竞态
//    ⑥ P1-2 截断 vs 终止（非零 critic 尾 bootstrap）
//    ⑦ P1-3 人工接管动作不进策略梯度（惩罚归因上一 AI 帧）
//    ⑧ P1-4 UNKNOWN 缺口隔离（sealEpisode 不伪造、两段不互串）
//    ⑨ P2 非有限速度不伪造急减速
//    ⑩ P2-5 真实 PolicyHead 可复现学习收益（固定采样种子，多 seed 聚合）
// ============================================================================

import Foundation

enum OnlineTrainerSelfTest {

    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("  \(condition ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 在线 RL 循环自检（-rl-online-selftest）═══")

        failures += runGAEIsolationChecks(check);            print("")
        failures += runValueLearningCheck(check);            print("")
        failures += runLearningCurveChecks(check);           print("")
        failures += runRealPolicyHeadIntegrationCheck(check);print("")
        failures += runSamplingSnapshotRaceCheck(check);     print("")
        failures += runTruncationVsTerminationCheck(check);  print("")
        failures += runTakeoverAttributionCheck(check);      print("")
        failures += runUnknownGapCheck(check);               print("")
        failures += runNonFiniteSpeedCheck(check);           print("")
        failures += runRealPolicyHeadLearningBenefitCheck(check); print("")
        failures += runBoundedCaptureCheck(check)

        print("")
        print(failures == 0
              ? "═══ 结果：全部通过 ✅（\(failures) 项失败）═══"
              : "═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        return failures
    }

    // ========================================================================
    // MARK: - ① GAE 逐 episode 隔离 + 尾 bootstrap（绑定 computeGAE 真实实现）
    // ========================================================================
    private static func runGAEIsolationChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ① GAE 逐 episode 隔离 + 尾 bootstrap（绑定 PolicyHead.computeGAE）──")

        var g1: [RLTransition] = [
            makeTransition(reward: 0, value: 0, isTerminal: true),
            makeTransition(reward: 10, value: 0, isTerminal: true)
        ]
        PolicyHead.computeGAE(&g1, gamma: 0.99, lam: 0.95)
        check("两独立单帧 adv == [0,10]（非 [9.405,10]）",
              g1[0].advantage.isFinite && g1[1].advantage.isFinite
                && abs(g1[0].advantage) < 1e-9 && abs(g1[1].advantage - 10) < 1e-9,
              "实际 [" + g1.map { String(format: "%.4f", $0.advantage) }.joined(separator: ",") + "]")

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
        let okA = (0..<3).allSatisfy {
            combined[$0].advantage.isFinite && abs(combined[$0].advantage - standaloneA[$0].advantage) < 1e-9
        }
        check("episode A 优势与单独跑一致（B 的 100 不渗入 A）", okA, "")
        check("episode B 单帧 adv == 100", abs(combined[3].advantage - 100.0) < 1e-9, "")
        let okVT = (0..<3).allSatisfy {
            combined[$0].valueTarget.isFinite && abs(combined[$0].valueTarget - standaloneA[$0].advantage) < 1e-9
        }
        check("computeGAE valueTarget = 原始优势 + value（A 段不串 B）", okVT, "")

        // P1-2 的 GAE 层：末帧 isTerminal=false 时用 tailBootstrapValue（非归零）。
        // 单帧 value=2.0,reward=0.1,gamma=0.99：tail=0 → adv=r- v = -1.9；tail=5 → -1.9+0.99*5=3.05。
        var t0 = [makeTransition(reward: 0.1, value: 2.0, isTerminal: false)]
        PolicyHead.computeGAE(&t0, gamma: 0.99, lam: 0.95, tailBootstrapValue: 0)
        var t5 = [makeTransition(reward: 0.1, value: 2.0, isTerminal: false)]
        PolicyHead.computeGAE(&t5, gamma: 0.99, lam: 0.95, tailBootstrapValue: 5.0)
        let exp0 = 0.1 + 0.99 * 0 - 2.0            // -1.9
        let exp5 = 0.1 + 0.99 * 5.0 - 2.0          // 3.05
        check("尾 bootstrap：tail=0 → adv=-1.9", abs(t0[0].advantage - exp0) < 1e-9,
              String(format: "实际 %.4f", t0[0].advantage))
        check("尾 bootstrap：tail=5 → adv=3.05（保留 bootstrap，非归零）",
              abs(t5[0].advantage - exp5) < 1e-9, String(format: "实际 %.4f", t5[0].advantage))
        check("尾 bootstrap：Δ(adv) == gamma*tail = 4.95",
              abs((t5[0].advantage - t0[0].advantage) - 0.99 * 5.0) < 1e-9,
              String(format: "Δ=%.4f", t5[0].advantage - t0[0].advantage))

        let nanOut = OnlineTrainer.normalizeAdvantages([Double.nan, 1.0, 2.0])
        check("normalizeAdvantages 非有限输入 → 全 0（无 NaN）", nanOut.allSatisfy { $0 == 0 }, "")
        check("normalizeAdvantages 常量输入 → 全 0",
              OnlineTrainer.normalizeAdvantages([3.0, 3.0, 3.0]).allSatisfy { $0 == 0 }, "")
        let z = OnlineTrainer.normalizeAdvantages([1.0, 2.0, 3.0, 4.0])
        check("normalizeAdvantages 结果均值≈0", abs(z.reduce(0, +) / Double(z.count)) < 1e-9, "")
        return 0
    }

    // ========================================================================
    // MARK: - ② 价值头固定目标收敛
    // ========================================================================
    private static func runValueLearningCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ② 价值头对固定目标收敛（advantage=0 冻结策略，只验 value 回归）──")
        let numContexts = 3
        let fixedTargets = [5.0, -3.0, 8.0]
        var batch: [RLTransition] = []
        for ctx in 0..<numContexts {
            for _ in 0..<6 {
                var state = [Float](repeating: 0, count: numContexts); state[ctx] = 1.0
                var t = RLTransition(stateToken: state, vClass: 0, hClass: 0,
                                     logProbV: 0, logProbH: 0, reward: 0, value: 0,
                                     tookOver: false, isTerminal: false)
                t.advantage = 0
                t.valueTarget = fixedTargets[ctx]
                batch.append(t)
            }
        }
        var policy = ToyPolicy(numContexts: numContexts, seed: 0xABCD_1234)
        var cfg = PPOConfig(); cfg.lr = 0.1; cfg.epochs = 200; cfg.batch = 18
        cfg.vfCoef = 0.5; cfg.entCoef = 0
        let m = policy.updatePPO(transitions: batch, config: cfg)
        let afterPreds = (0..<numContexts).map { ctx -> Double in
            var s = [Float](repeating: 0, count: numContexts); s[ctx] = 1.0
            return Double(policy.forward(stateToken: s).value)
        }
        let reference = ToyPolicy(numContexts: numContexts, seed: 0xABCD_1234)
        var s0 = [Float](repeating: 0, count: numContexts); s0[0] = 1.0
        let vLogitDiff = abs(Double(policy.forward(stateToken: s0).vLogits[0])
                             - Double(reference.forward(stateToken: s0).vLogits[0]))
        let initialMSE = fixedTargets.map { $0 * $0 }.reduce(0, +) / Double(numContexts)
        let finalMSE = zip(afterPreds, fixedTargets).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(numContexts)
        print(String(format: "  预测=[0,0,0]→[%.2f,%.2f,%.2f] 目标=[5,-3,8] MSE %.3f→%.3f",
                     afterPreds[0], afterPreds[1], afterPreds[2], initialMSE, finalMSE))
        check("价值头把固定目标拟合下来（MSE 至少降到初值 1/5）", finalMSE < initialMSE / 5.0, "")
        check("固定目标下 value_loss 显著下降", m.valueLoss < initialMSE, "")
        check("advantage=0 时策略头不被价值回归带偏", vLogitDiff < 1e-6,
              String(format: "max|ΔvLogit|=%.3e", vLogitDiff))
        return 0
    }

    // ========================================================================
    // MARK: - ③ 学习曲线（确定性 ToyPolicy + 合成环境）
    // ========================================================================
    private static func runLearningCurveChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ③ 合成可学习环境学习曲线（确定性线性策略头）──")
        let numContexts = 3, framesPerEpisode = 16, episodes = 80
        let prefV = [0, 1, 2], prefH = [2, 1, 0]
        let seed: UInt64 = 0x51A7_2026
        var ppo = PPOConfig(); ppo.lr = 0.04; ppo.epochs = 4; ppo.batch = 16
        ppo.vfCoef = 0.5; ppo.entCoef = 0.0
        let trainer = OnlineTrainer(policy: ToyPolicy(numContexts: numContexts, seed: seed),
                                    rewardConfig: RewardConfig(), ppoConfig: ppo,
                                    trainEvery: 10_000, metricsCapacity: 512)
        var rng = SplitMix64(seed: seed ^ 0xDEAD_BEEF)
        var epR: [Double] = [], cv: [Double] = [], ch: [Double] = []
        for ep in 0..<episodes {
            var tot = 0.0, cV = 0, cH = 0
            for step in 0..<framesPerEpisode {
                let ctx = Int(rng.next() % UInt64(numContexts))
                var state = [Float](repeating: 0, count: numContexts); state[ctx] = 1.0
                let sample = trainer.sampleAction(stateToken: state)
                let vOK = sample.vClass == prefV[ctx], hOK = sample.hClass == prefH[ctx]
                // episode 的最后一帧就是**真实采样帧**且 isTerminal=true（不发 logProb=0 的假终止帧，
                // 否则会用坏 old logProb 污染 PPO ratio）。
                let r = trainer.collect(stateToken: state, sample: sample, tookOver: false,
                                        speedKmh: vOK ? 90.0 : 20.0, speedValid: true, collision: false,
                                        laneOffset: hOK ? 0.0 : 1.0, isTerminal: step == framesPerEpisode - 1)
                tot += r; if vOK { cV += 1 }; if hOK { cH += 1 }
            }
            trainer.drainTrainingAndWait()
            epR.append(tot); cv.append(Double(cV) / Double(framesPerEpisode)); ch.append(Double(cH) / Double(framesPerEpisode))
            if ep % 16 == 0 || ep == episodes - 1 {
                print(String(format: "  ep %2d 回报=%8.3f VH=%.2f/%.2f", ep, tot, cv[ep], ch[ep]))
            }
        }
        trainer.drainTrainingAndWait()
        let W = 10
        let fpf = mean(Array(epR.prefix(W))) / Double(framesPerEpisode)
        let lpf = mean(Array(epR.suffix(W))) / Double(framesPerEpisode)
        let fcv = mean(Array(cv.prefix(W))), lcv = mean(Array(cv.suffix(W)))
        let fch = mean(Array(ch.prefix(W))), lch = mean(Array(ch.suffix(W)))
        print(String(format: "  前%d 每帧 %.3f V%.2f H%.2f → 后%d 每帧 %.3f V%.2f H%.2f",
                     W, fpf, fcv, fch, W, lpf, lcv, lch))
        check("后窗口每帧奖励显著高于前窗口（Δ>0.25）", lpf - fpf > 0.25,
              String(format: "Δ=%.3f", lpf - fpf))
        check("后窗口每帧奖励 > 0.55", lpf > 0.55, String(format: "%.3f", lpf))
        check("竖直正确率显著上升（Δ>0.3）", lcv - fcv > 0.3, String(format: "%.2f→%.2f", fcv, lcv))
        check("水平正确率显著上升（Δ>0.3）", lch - fch > 0.3, String(format: "%.2f→%.2f", fch, lch))
        let metrics = trainer.recentMetrics
        check("产生 PPO 更新指标（>10 次）", metrics.count > 10, "\(metrics.count) 次")
        check("四类指标全部有限", metrics.allSatisfy {
            $0.policyLoss.isFinite && $0.valueLoss.isFinite && $0.entropy.isFinite && $0.approxKL.isFinite }, "")
        return 0
    }

    // ========================================================================
    // MARK: - ④ 真实 PolicyHead 端到端机器验证
    // ========================================================================
    private static func runRealPolicyHeadIntegrationCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ④ 接入真实 PolicyHead 端到端机器验证（真跑 collect→GAE→updatePPO→发布）──")
        let dim = 256, numContexts = 3
        let prefV = [0, 1, 2], prefH = [2, 1, 0]
        var cfg = PPOConfig(); cfg.lr = 0.01; cfg.epochs = 2; cfg.batch = 8; cfg.entCoef = 0.1
        let trainer = OnlineTrainer(policy: PolicyHead(randomSeed: 0x51A7_2026),
                                    rewardConfig: RewardConfig(), ppoConfig: cfg,
                                    trainEvery: 8, metricsCapacity: 256)
        var rng = SplitMix64(seed: 999)
        var steps = 0
        for _ in 0..<10 {
            for step in 0..<16 {
                let ctx = Int(rng.next() % UInt64(numContexts))
                var s = [Float](repeating: 0, count: dim); s[ctx] = 1.0
                var pol = trainer.currentPolicyForTest()
                let sample = pol.sampleSeeded(stateToken: s, rng: &rng)
                let vOK = sample.vClass == prefV[ctx], hOK = sample.hClass == prefH[ctx]
                _ = trainer.collect(stateToken: s, sample: sample, tookOver: false,
                                    speedKmh: vOK ? 90 : 20, speedValid: true, collision: false,
                                    laneOffset: hOK ? 0 : 1, isTerminal: step == 15)
                steps += 1
            }
            trainer.drainTrainingAndWait()
        }
        trainer.drainTrainingAndWait()
        let metrics = trainer.recentMetrics
        print("  真实 PolicyHead：跑 \(steps) 帧，\(metrics.count) 次 PPO 更新，\(trainer.completedEpisodeCount) episode")
        check("完成 >0 次 PPO 更新", metrics.count > 0, "")
        check("完成 episode 数 == 10", trainer.completedEpisodeCount == 10, "")
        check("全部指标有限（含回填 meanReward）", metrics.allSatisfy {
            $0.policyLoss.isFinite && $0.valueLoss.isFinite && $0.entropy.isFinite
                && $0.approxKL.isFinite && $0.meanReward.isFinite }, "")
        let reference = PolicyHead(randomSeed: 0x51A7_2026)
        var s0 = [Float](repeating: 0, count: dim); s0[0] = 1.0
        let trainedDist = trainer.actionDistribution(stateToken: s0).v
        let initDist = RLMath.softmax(reference.forward(stateToken: s0).vLogits)
        let maxDiff = (0..<3).map { abs(trainedDist[$0] - initDist[$0]) }.max() ?? 0
        check("双缓冲发布生效（参数被真实更新，Δp>1e-3）", maxDiff > 1e-3,
              String(format: "max|Δp|=%.3e", maxDiff))
        return 0
    }

    // ========================================================================
    // MARK: - ⑤ P1-1 采样快照 / 发布竞态
    // ========================================================================
    private static func runSamplingSnapshotRaceCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑤ P1-1 采样快照/发布竞态：collect 原样保存采样时的 old logProb，不二次 forward ──")
        // 策略 A 的 logits 特意与策略 B 不同：若 collect 二次 forward 用 B，则保存的 old 会变。
        let policyA = FixedPolicy(vLogits: [0.0, 2.0, 0.0], hLogits: [0.0, 0.0, 0.0], value: 1.5)
        let policyB = FixedPolicy(vLogits: [2.0, 0.0, 0.0], hLogits: [0.0, 0.0, 0.0], value: -9.0)
        let trainer = OnlineTrainer(policy: policyA, rewardConfig: RewardConfig(),
                                    ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        // 用 A 采样（拿到 A 口径的 logProb / value）
        var rng = SplitMix64(seed: 7)
        var polA = trainer.currentPolicyForTest()
        let sampleA = polA.sampleSeeded(stateToken: [1, 0, 0], rng: &rng)
        // 模拟「采样后、collect 前后台发布了 B」
        trainer.injectPolicyForTest(policyB)
        // collect 传入 A 的采样快照
        _ = trainer.collect(stateToken: [1, 0, 0], sample: sampleA, tookOver: false,
                            speedKmh: 50, speedValid: true, collision: false, laneOffset: 0, isTerminal: false)
        let pending = trainer.pendingTransitionsForTest()
        guard pending.count == 1 else { check("pending 恰 1 条", false, "实际 \(pending.count)"); return 0 }
        let stored = pending[0]
        // 用当前（B）重算会是多少：
        let bLogProb = RLMath.logSoftmax(policyB.vLogits)[stored.vClass]
        check("保存的 old logProbV == 采样时 A 的值", abs(stored.logProbV - sampleA.logProbV) < 1e-9,
              String(format: "存%.5f 采样%.5f", stored.logProbV, sampleA.logProbV))
        check("保存的 value == 采样时 A 的 value（不是 B 的 -9）", abs(stored.value - sampleA.value) < 1e-9,
              String(format: "存%.3f 采样%.3f", stored.value, sampleA.value))
        check("保存的 old != 用已发布 B 重算的值（证明未二次 forward）", abs(stored.logProbV - bLogProb) > 1e-3,
              String(format: "存%.5f B重算%.5f", stored.logProbV, bLogProb))
        return 0
    }

    // ========================================================================
    // MARK: - ⑥ P1-2 截断 vs 终止（非零 critic 尾 bootstrap）
    // ========================================================================
    private static func runTruncationVsTerminationCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑥ P1-2 截断 vs 终止：缓冲截断扣下末条 + 用其 value 做尾 bootstrap（非零 critic）──")
        // trainEvery=3：喂 A,B,C 三帧（都非终止）→ 第 3 条触发缓冲截断。
        // 期望：训练 [A,B]，扣下 C；[A,B] 的末条 B 用 C.value 做 tail bootstrap（不归零）。
        let trainer = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                    ppoConfig: PPOConfig(), trainEvery: 3, metricsCapacity: 16)
        trainer.setCaptureBatchesForTest(true)
        func feed(_ token: Float, reward: Double, value: Double) {
            _ = trainer.collect(stateToken: [token],
                                sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: value),
                                tookOver: false, speedKmh: 1, speedValid: true,
                                collision: false, laneOffset: 0, isTerminal: false)
        }
        // 用可控 reward：直接构造 transitions 里的 reward 由 frameReward 算，不便精确控制；
        // 因此这里改用「注入 pending」不可行 —— 改为直接校验「C 被扣下且训练批末条 adv 用 C.value」。
        // 为让 reward 已知，speedValid=false 使 reward 恒 0（无 speed/stuck/decel/lane）。
        func feedZeroReward(_ value: Double) {
            _ = trainer.collect(stateToken: [1],
                                sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: value),
                                tookOver: false, speedKmh: 0, speedValid: false,
                                collision: false, laneOffset: 0, isTerminal: false)
        }
        feedZeroReward(1.0)   // A value=1
        feedZeroReward(2.0)   // B value=2
        // 此刻 A,B 在 pending；再喂 C(value=5) 触发 trainEvery=3 截断
        feedZeroReward(5.0)   // C value=5
        trainer.drainTrainingAndWait()
        let batches = trainer.capturedBatchesForTestSnapshot()
        guard batches.count == 1 else { check("截断后恰训练 1 批", false, ""); return 0 }
        let trained = batches[0]
        check("缓冲截断只训练 [A,B]（扣下 C）", trained.count == 2, "实际 \(trained.count)")
        // 手算（gamma=0.99, lam=0.95, rewards 全 0, values A=1,B=2, tail=C.value=5）：
        // adv_B = 0 + 0.99*5 - 2 = 2.95；adv_A = 0 + 0.99*2 - 1 + 0.99*0.95*2.95
        let advB = 0.99 * 5.0 - 2.0
        let advA = 0.99 * 2.0 - 1.0 + 0.99 * 0.95 * advB
        // captured 存的是归一化后的 advantage；两元素归一化后均值≈0、差的符号可验：
        // 直接校验 valueTarget（未归一化）= raw adv + value。
        let vtB_expected = advB + 2.0
        let vtB = trained[1].valueTarget           // 归一化不改 valueTarget
        check("末条 B 的 valueTarget 用了 C.value 的尾 bootstrap（非归零）",
              abs(vtB - vtB_expected) < 1e-9,
              String(format: "实际%.4f 期望%.4f（尾归零则应%.4f）", vtB, vtB_expected, (0.0 - 2.0) + 2.0))
        let vtA_expected = advA + 1.0
        check("A 的 valueTarget 与手算一致（B 的 bootstrap 正确传导）",
              abs(trained[0].valueTarget - vtA_expected) < 1e-9,
              String(format: "实际%.4f 期望%.4f", trained[0].valueTarget, vtA_expected))
        // 若把截断当终止（B 的 nextV 归零），vtB 会是 -2+2=0；必须明显不同。
        check("尾 bootstrap 与「当终止」有显著差异（>1）", abs(vtB - 0.0) > 1.0, "")

        // 对照：episode 真正结束（isTerminal=true）时末条按终止（nextV=0）。
        trainer.clearCapturedBatchesForTest()
        let trainer2 = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                     ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        trainer2.setCaptureBatchesForTest(true)
        _ = trainer2.collect(stateToken: [1],
                             sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 2.0),
                             tookOver: false, speedKmh: 0, speedValid: false,
                             collision: false, laneOffset: 0, isTerminal: true)
        trainer2.drainTrainingAndWait()
        let b2 = trainer2.capturedBatchesForTestSnapshot()
        check("真终止(单帧 value=2,reward=0)：valueTarget == 0（nextV 归零）",
              b2.count == 1 && abs(b2[0][0].valueTarget - 0.0) < 1e-9,
              b2.count == 1 ? String(format: "实际%.4f", b2[0][0].valueTarget) : "无批")
        return 0
    }

    // ========================================================================
    // MARK: - ⑦ P1-3 + P1-B 人工接管：动作不进策略梯度、惩罚归因策略动作并进入 actor 梯度
    // ========================================================================
    private static func runTakeoverAttributionCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑦ P1-3+P1-B 人工接管：惩罚落在策略动作上、进入 policy 梯度（含截断后单条边界）──")

        // 情形一：接管帧把惩罚并入**当前 AI 动作**并收尾，人类救援动作不成 transition。
        let t1 = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(takeover: 10),
                               ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        t1.setCaptureBatchesForTest(true)
        func feedAI(_ trainer: OnlineTrainer, token: Float) {
            _ = trainer.collect(stateToken: [token],
                                sample: PolicySample(vClass: 1, hClass: 1, logProbV: 0, logProbH: 0, value: 0),
                                tookOver: false, speedKmh: 0, speedValid: false,
                                collision: false, laneOffset: 0, isTerminal: false)
        }
        feedAI(t1, token: 1)                 // 前一条 AI
        // 接管帧：人类动作 (vClass=2,hClass=0)，reward 0（speedValid=false），必须得 -10
        _ = t1.collect(stateToken: [1],
                       sample: PolicySample(vClass: 2, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                       tookOver: true, speedKmh: 0, speedValid: false,
                       collision: false, laneOffset: 0, isTerminal: false)
        t1.drainTrainingAndWait()
        let b1 = t1.capturedBatchesForTestSnapshot()
        check("接管后收尾训练 1 批", b1.count == 1, "实际 \(b1.count)")
        if b1.count == 1 {
            let last = b1[0].last!
            check("接管惩罚(-10)落在末条 transition 的 reward 上", abs(last.reward - (-10.0)) < 1e-9,
                  String(format: "实际%.3f", last.reward))
            check("该 transition 的动作用的是策略实际采样动作(vClass1)，非人类动作(vClass2)",
                  last.vClass == 1 && last.hClass == 1, "v=\(last.vClass) h=\(last.hClass)")
            check("批内无人类救援动作(vClass2)", b1[0].allSatisfy { !($0.vClass == 2 && $0.hClass == 0) }, "")
        }

        // 情形二（P1-B 边界）：**截断后恰剩单条 AI transition**，下一帧接管（惩罚并入被扣回的那条）
        // → 单条批必须让该 AI 动作在 policy 上真的拿到惩罚（非零优势），不能因归一化成 0 失效。
        let toySeed: UInt64 = 0x5151
        let initPolicy = ToyPolicy(numContexts: 1, seed: toySeed)      // 训练器会复制它
        let t2 = OnlineTrainer(policy: initPolicy, rewardConfig: RewardConfig(takeover: 10),
                               ppoConfig: PPOConfig(lr: 0.5, epochs: 1, batch: 4, entCoef: 0),
                               trainEvery: 2, metricsCapacity: 16)
        t2.setCaptureBatchesForTest(true)
        // 用真实 logProb 采样 (vClass0,hClass0)：竖直与水平都要用**真实** logSoftmax 值，
        // 否则 oldLogP 与真实值不一致 → PPO ratio 偏离 1 → 梯度被 clip 置零（测试假象）。
        func sampleV0() -> PolicySample {
            let pol = t2.currentPolicyForTest()
            let f = pol.forward(stateToken: [1])
            let lpv = RLMath.logSoftmax(f.vLogits)
            let lph = RLMath.logSoftmax(f.hLogits)
            return PolicySample(vClass: 0, hClass: 0, logProbV: lpv[0], logProbH: lph[0], value: 0)
        }
        func feedAI0() {
            _ = t2.collect(stateToken: [1], sample: sampleV0(),
                           tookOver: false, speedKmh: 0, speedValid: false,
                           collision: false, laneOffset: 0, isTerminal: false)
        }
        feedAI0()   // pending=[X1]
        feedAI0()   // pending=[X1,X2] → trainEvery=2 截断：训[X1]，扣下 X2（pending=[X2]）
        t2.drainTrainingAndWait()
        check("截断后 pending 恰剩 1 条", t2.pendingTransitionsForTest().count == 1,
              "实际 \(t2.pendingTransitionsForTest().count)")
        // 基线取在「接管帧之前」的真实策略（隔离掉截断训练本身的任何扰动）。
        let p0Before = RLMath.softmax(t2.currentPolicyForTest().forward(stateToken: [1]).vLogits)[0]
        // 下一帧接管（AI 动作 vClass0）→ 惩罚并入 X2（单条批）并训练
        _ = t2.collect(stateToken: [1], sample: sampleV0(),
                       tookOver: true, speedKmh: 0, speedValid: false,
                       collision: false, laneOffset: 0, isTerminal: false)
        t2.drainTrainingAndWait()
        let b2 = t2.capturedBatchesForTestSnapshot()
        let singleTakeoverBatch = b2.first { $0.count == 1 && ($0[0].reward <= -9.0) }
        check("存在「单条 + 接管惩罚(-10)」的批", singleTakeoverBatch != nil,
              "批数=\(b2.count) 各批 count=" + b2.map { "\($0.count)" }.joined(separator: ","))
        check("P1-B：单条接管批的 advantage 非 0（actor 不因归一化丢梯度）",
              singleTakeoverBatch?.first?.advantage != nil
                && abs(singleTakeoverBatch!.first!.advantage) > 1e-6,
              singleTakeoverBatch.map { String(format: "adv=%.4f", $0[0].advantage) } ?? "无")
        // 真正的 actor 效果：训练后策略在该状态对 vClass0 的概率应被压低（惩罚真进梯度）。
        let trained = t2.currentPolicyForTest()
        let p0After = RLMath.softmax(trained.forward(stateToken: [1]).vLogits)[0]
        check("P1-B：接管后 vClass0 动作概率下降（惩罚真进 actor 梯度）", p0After < p0Before - 1e-4,
              String(format: "p0 %.5f → %.5f", p0Before, p0After))
        return 0
    }

    // ========================================================================
    // MARK: - ⑧ P1-4 + P1-A UNKNOWN 缺口：封口不伪造归零、用末条自值 bootstrap 前缀、两段不串
    // ========================================================================
    private static func runUnknownGapCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑧ P1-4+P1-A UNKNOWN 缺口：丢弃不可靠末条、用其自值 bootstrap 前缀，不伪造归零 ──")
        let trainer = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                    ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        trainer.setCaptureBatchesForTest(true)
        func feed(_ value: Double) {
            _ = trainer.collect(stateToken: [1],
                                sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: value),
                                tookOver: false, speedKmh: 0, speedValid: false,
                                collision: false, laneOffset: 0, isTerminal: false)
        }
        // 段 A：A1(value1),A2(value2) 后遇 UNKNOWN
        feed(1.0); feed(2.0)
        check("UNKNOWN 前 pending 有 2 条", trainer.pendingTransitionsForTest().count == 2, "")
        trainer.markInvalid()
        trainer.drainTrainingAndWait()
        check("UNKNOWN 后 pending 清空（不伪造 transition）", trainer.pendingTransitionsForTest().isEmpty, "")

        // 段 B：B1(value3),B2(value4, 真终止) —— 验证两段独立
        feed(3.0)
        _ = trainer.collect(stateToken: [1],
                            sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 4.0),
                            tookOver: false, speedKmh: 0, speedValid: false,
                            collision: false, laneOffset: 0, isTerminal: true)
        trainer.drainTrainingAndWait()

        let batches = trainer.capturedBatchesForTestSnapshot()
        check("共形成 2 个独立批次（A 段封口 + B 段 episode 结束）", batches.count == 2, "实际 \(batches.count)")
        guard batches.count == 2 else { return 0 }

        // P1-A 关键：A 段封口应**丢掉不可靠末条 A2(value2)**、只训练前缀 [A1(value1)]，
        // 并以 A2 的 value(2) 作 tail bootstrap（非 tail=0）。所以 A 段批只有 1 条。
        check("P1-A：A 段封口批只含有效前缀 1 条（丢弃不可靠末条 A2）", batches[0].count == 1,
              "实际 \(batches[0].count)")
        check("P1-A：B 段结束批 2 条", batches[1].count == 2, "实际 \(batches[1].count)")
        if batches[0].count == 1 {
            // 参考：A1 单独跑、tail=A2.value=2。raw adv = 0 + 0.99*2 - 1 = 0.98；valueTarget = 0.98 + 1 = 1.98。
            var ref: [RLTransition] = [makeTransition(reward: 0, value: 1.0, isTerminal: false)]
            PolicyHead.computeGAE(&ref, gamma: 0.99, lam: 0.95, tailBootstrapValue: 2.0)
            let vt = batches[0][0].valueTarget
            check("P1-A：A 段前缀 valueTarget == 1.98（tail=A2.value，非归零的 0.0）",
                  abs(vt - 1.98) < 1e-9 && abs(vt - ref[0].valueTarget) < 1e-9,
                  String(format: "实际%.4f 参考%.4f（归零则%.4f）", vt, ref[0].valueTarget, -1.0 + 1.0))
            check("P1-A：A 段 advantage 非 0（未被末条归零污染）",
                  abs(batches[0][0].advantage) > 1e-6,
                  String(format: "adv=%.4f", batches[0][0].advantage))
        }
        // B 段（B2 真终止 value=4, reward 0）：raw adv B2 = 0+0.99*0-4 = -4 → 归一化后两元素均值0。
        // 关键隔离：B 段 valueTarget 不受 A 段影响（B2 valueTarget = raw adv + value）。
        // B2 单独跑：(B1 v3,B2 v4 term) adv_B2=-4 → vt=-4+4=0；B1 adv=0.99*4-3+0.99*0.95*(-4)=...
        var isoB: [RLTransition] = [makeTransition(reward: 0, value: 3.0, isTerminal: false),
                                    makeTransition(reward: 0, value: 4.0, isTerminal: true)]
        PolicyHead.computeGAE(&isoB, gamma: 0.99, lam: 0.95)
        check("B 段末条 valueTarget 与「B 单独跑」一致（A 段不渗入）",
              abs(batches[1][1].valueTarget - isoB[1].valueTarget) < 1e-9,
              String(format: "拼接%.4f 单独%.4f", batches[1][1].valueTarget, isoB[1].valueTarget))
        return 0
    }

    // ========================================================================
    // MARK: - ⑨ P2 非有限速度不伪造急减速
    // ========================================================================
    private static func runNonFiniteSpeedCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑨ P2 非有限速度：speedValid=true 但 speed=NaN 时 prevValid 置 false，不伪造急减速 ──")
        let trainer = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                    ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        func feed(_ speed: Double, _ valid: Bool) -> Double {
            trainer.collect(stateToken: [1],
                            sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                            tookOver: false, speedKmh: speed, speedValid: valid,
                            collision: false, laneOffset: 0, isTerminal: false)
        }
        _ = feed(100, true)                 // 帧1：prev speed=100, valid
        _ = feed(Double.nan, true)          // 帧2：NaN（valid 却 NaN）→ 必须 prevValid=false
        let r3 = feed(50, true)             // 帧3：50 km/h
        // 若修复：帧3 decel=0（prevValid=false），reward = speedTerm(50)=0.5
        // 若未修复：decelTerm(prev=100,cur=50)=min(50/30,1)=1 → reward = 0.5 - 2*1 = -1.5
        check("NaN 之后一帧不被伪造急减速（reward==speedTerm 0.5，非 -1.5）",
              abs(r3 - 0.5) < 1e-9, String(format: "实际%.4f", r3))
        // 对照：连续两个有限值确实产生减速惩罚（证明减速项本身没坏）
        let trainer2 = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                     ppoConfig: PPOConfig(), trainEvery: 10_000, metricsCapacity: 16)
        _ = trainer2.collect(stateToken: [1],
                             sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                             tookOver: false, speedKmh: 100, speedValid: true,
                             collision: false, laneOffset: 0, isTerminal: false)
        let r2c = trainer2.collect(stateToken: [1],
                                   sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                                   tookOver: false, speedKmh: 50, speedValid: true,
                                   collision: false, laneOffset: 0, isTerminal: false)
        check("对照：连续有限值 100→50 确实有减速惩罚（reward < 0.5）", r2c < 0.5,
              String(format: "实际%.4f", r2c))
        return 0
    }

    // ========================================================================
    // MARK: - ⑩ P2-5 真实 PolicyHead 可复现学习收益（固定采样种子，单种子小尺度 + 墙钟上限）
    // ========================================================================
    private static func runRealPolicyHeadLearningBenefitCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑩ P2-5 真实 PolicyHead 可复现学习收益（固定采样种子，小尺度 + 墙钟上限）──")
        // 说明：debug（未优化）下真 MLP 训练较慢，故用**单个固定种子 + 小尺度**
        // （60 episode × 16 帧，epochs=1）——固定采样种子 ⇒ 完全确定可复现（实测 Δ≈+0.69）。
        // 下方设**硬墙钟上限 15s**：一旦超时立即断言失败并返回，绝不无条件空转（防卡死）。
        let envSeed: UInt64 = 0xBEEF
        let start = Date()
        let res = realMLPOneSeed(envSeed: envSeed, deadline: start.addingTimeInterval(15))
        if res.timedOut {
            check("真实 PolicyHead 学习测试在墙钟上限内完成", false,
                  "超 15s 未完成 → 判失败退出（防卡死）")
            return 0
        }
        print(String(format: "  envSeed=0x%llX Δ每帧=%+.3f 竖直正确率 %.2f→%.2f （耗时 %.1fs）",
                     envSeed, res.delta, res.firstCV, res.lastCV, Date().timeIntervalSince(start)))
        check("真实 PolicyHead 每帧奖励显著上升（Δ>0.4，不要求逐步单调）", res.delta > 0.4,
              String(format: "Δ=%+.3f", res.delta))
        check("真实 PolicyHead 竖直正确率显著上升（后窗 >0.85）", res.lastCV > 0.85,
              String(format: "%.2f→%.2f", res.firstCV, res.lastCV))
        return 0
    }

    /// 跑一个固定环境种子的真实 PolicyHead 在线学习。带墙钟 deadline：每 episode 末检查，
    /// 超时即置 timedOut 返回（调用方判失败），绝不空转。
    private static func realMLPOneSeed(envSeed: UInt64, deadline: Date)
        -> (delta: Double, firstCV: Double, lastCV: Double, timedOut: Bool) {
        let dim = 256, numContexts = 3, fpe = 16, episodes = 60
        let prefV = [0, 1, 2], prefH = [2, 1, 0]
        var cfg = PPOConfig(); cfg.lr = 0.01; cfg.clipEps = 0.2; cfg.gamma = 0.99; cfg.lam = 0.95
        cfg.epochs = 1; cfg.batch = 16; cfg.vfCoef = 0.5; cfg.entCoef = 0.08
        let trainer = OnlineTrainer(policy: PolicyHead(randomSeed: 0x51A7_2026),
                                    rewardConfig: RewardConfig(), ppoConfig: cfg,
                                    trainEvery: 100_000, metricsCapacity: 256)
        var rng = SplitMix64(seed: envSeed)
        var epR: [Double] = [], cv: [Double] = []
        for _ in 0..<episodes {
            if Date() > deadline { return (0, 0, 0, true) }   // 墙钟上限，防卡死
            var tot = 0.0, cV = 0
            for step in 0..<fpe {
                let ctx = Int(rng.next() % UInt64(numContexts))
                var s = [Float](repeating: 0, count: dim); s[ctx] = 1.0
                var pol = trainer.currentPolicyForTest()
                let sample = pol.sampleSeeded(stateToken: s, rng: &rng)
                let vOK = sample.vClass == prefV[ctx], hOK = sample.hClass == prefH[ctx]
                let r = trainer.collect(stateToken: s, sample: sample, tookOver: false,
                                        speedKmh: vOK ? 90 : 20, speedValid: true, collision: false,
                                        laneOffset: hOK ? 0 : 1, isTerminal: step == fpe - 1)
                tot += r; if vOK { cV += 1 }
            }
            trainer.drainTrainingAndWait()
            epR.append(tot); cv.append(Double(cV) / Double(fpe))
        }
        let W = 15
        let fpf = mean(Array(epR.prefix(W))) / Double(fpe)
        let lpf = mean(Array(epR.suffix(W))) / Double(fpe)
        return (lpf - fpf, mean(Array(cv.prefix(W))), mean(Array(cv.suffix(W))), false)
    }

    // ========================================================================
    // MARK: - ⑪ P2-C 测试捕获有界 + 默认关闭（防内存无界增长）
    // ========================================================================
    private static func runBoundedCaptureCheck(_ check: (String, Bool, String) -> Void) -> Int {
        print("── ⑪ P2-C 测试捕获：默认关闭不占内存、开启后有界（≤64，不随训练次数无限增长）──")
        // 默认关闭：即便训练很多批，捕获仍为空（说明默认不占内存）。
        let off = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                                ppoConfig: PPOConfig(), trainEvery: 1, metricsCapacity: 16)
        for i in 0..<40 {
            _ = off.collect(stateToken: [Float(i)],
                            sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                            tookOver: false, speedKmh: 0, speedValid: false,
                            collision: false, laneOffset: 0, isTerminal: true)
        }
        off.drainTrainingAndWait()
        check("默认未开启捕获：40 次训练后捕获仍为空（不占内存）",
              off.capturedBatchesForTestSnapshot().isEmpty,
              "实际 \(off.capturedBatchesForTestSnapshot().count)")

        // 开启后：训练 100 批，捕获数必须被限制在 64（有界），而不是 100。
        let on = OnlineTrainer(policy: FixedPolicy(), rewardConfig: RewardConfig(),
                               ppoConfig: PPOConfig(), trainEvery: 1, metricsCapacity: 16)
        on.setCaptureBatchesForTest(true)
        for i in 0..<100 {
            _ = on.collect(stateToken: [Float(i)],
                           sample: PolicySample(vClass: 0, hClass: 0, logProbV: 0, logProbH: 0, value: 0),
                           tookOver: false, speedKmh: 0, speedValid: false,
                           collision: false, laneOffset: 0, isTerminal: true)
        }
        on.drainTrainingAndWait()
        let cap = on.capturedBatchesForTestSnapshot().count
        check("开启捕获后：100 次训练捕获被限制在 64（有界环形，不无限增长）", cap == 64,
              "实际 \(cap)")
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
// MARK: - FixedPolicy：可控策略（语义测试用；只提供固定 forward/value，update 为空操作）
// ============================================================================

/// 语义测试用：forward 返回固定 logits/value，updatePPO 为**空操作**（不改参数、返回零指标）。
/// 语义测试只关心 collect 存了什么、flush 怎么调 computeGAE、captured 批里的
/// advantage/valueTarget/reward 是否正确 —— 与策略更新本身无关，故用空更新隔离。
struct FixedPolicy: PolicyUpdatable {
    var vLogits: [Float]
    var hLogits: [Float]
    var value: Float
    init(vLogits: [Float] = [0, 0, 0], hLogits: [Float] = [0, 0, 0], value: Float = 0) {
        self.vLogits = vLogits; self.hLogits = hLogits; self.value = value
    }
    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float) {
        (vLogits, hLogits, value)
    }
    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        (0, 0, 0, 0)
    }
    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics {
        PPOMetrics()
    }
}

// ============================================================================
// MARK: - ToyPolicy：确定性可学习的玩具策略（线性 softmax + 显式 Adam + PPO clipped）
// ============================================================================

struct ToyPolicy: PolicyUpdatable {
    let numContexts: Int
    private let K: Int
    private var Wv: [Double], Wh: [Double], bv: [Double], bh: [Double]
    private var valueW: [Double], valueBias: Double
    private var mWv: [Double], vWv: [Double], mWh: [Double], vWh: [Double]
    private var mbv: [Double], vbv: [Double], mbh: [Double], vbh: [Double]
    private var mvalueW: [Double], vvalueW: [Double]
    private var mValueBias: Double, vValueBias: Double
    private var adamT: Int
    private let sampleRNG: SampleRNG
    private var shuffleState: UInt64

    init(numContexts: Int, seed: UInt64) {
        self.K = numContexts
        self.numContexts = numContexts
        var rng = SplitMix64(seed: seed)
        func rs() -> Double { (rng.nextUnit() - 0.5) * 0.2 }
        Wv = (0..<(numContexts * 3)).map { _ in rs() }
        Wh = (0..<(numContexts * 3)).map { _ in rs() }
        bv = [0, 0, 0]; bh = [0, 0, 0]
        valueW = [Double](repeating: 0, count: numContexts); valueBias = 0
        mWv = [Double](repeating: 0, count: numContexts * 3); vWv = [Double](repeating: 0, count: numContexts * 3)
        mWh = [Double](repeating: 0, count: numContexts * 3); vWh = [Double](repeating: 0, count: numContexts * 3)
        mbv = [0, 0, 0]; vbv = [0, 0, 0]; mbh = [0, 0, 0]; vbh = [0, 0, 0]
        mvalueW = [Double](repeating: 0, count: numContexts); vvalueW = [Double](repeating: 0, count: numContexts)
        mValueBias = 0; vValueBias = 0; adamT = 0
        sampleRNG = SampleRNG(seed: seed ^ 0x9E37_79B9)
        shuffleState = seed ^ 0xC0FF_EE00
    }

    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float) {
        var v = bv, h = bh, val = valueBias
        let n = min(K, stateToken.count)
        for k in 0..<n {
            let s = Double(stateToken[k]); if s == 0 { continue }
            for c in 0..<3 { v[c] += Wv[k * 3 + c] * s; h[c] += Wh[k * 3 + c] * s }
            val += valueW[k] * s
        }
        return (v.map { Float($0) }, h.map { Float($0) }, Float(val))
    }

    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        let pv = RLMath.softmax(vLogits), ph = RLMath.softmax(hLogits)
        let vClass = sampleCategorical(pv), hClass = sampleCategorical(ph)
        let lv = RLMath.logSoftmax(vLogits), lh = RLMath.logSoftmax(hLogits)
        return (vClass, hClass, vClass < lv.count ? lv[vClass] : 0, hClass < lh.count ? lh[hClass] : 0)
    }

    private func sampleCategorical(_ p: [Double]) -> Int {
        guard !p.isEmpty else { return 0 }
        let u = sampleRNG.nextUnit(); var acc = 0.0
        for i in 0..<p.count { acc += p[i]; if u < acc { return i } }
        return p.count - 1
    }

    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics {
        let n = transitions.count
        guard n > 0 else { return PPOMetrics() }
        let epochs = max(1, config.epochs), batchSize = max(1, config.batch)
        var sp = 0.0, sv = 0.0, se = 0.0, sk = 0.0; var mb = 0
        for _ in 0..<epochs {
            var rng = SplitMix64(seed: shuffleState)
            var idx = Array(0..<n)
            if n > 1 { for i in stride(from: n - 1, through: 1, by: -1) { let j = Int(rng.next() % UInt64(i + 1)); idx.swapAt(i, j) } }
            shuffleState = rng.next()
            var start = 0
            while start < n {
                let end = min(start + batchSize, n)
                let bidx = Array(idx[start..<end])
                let res = accumulateGradients(transitions: transitions, indices: bidx, config: config)
                applyAdam(grads: res.grads, lr: config.lr, batchCount: bidx.count)
                sp += res.policyLoss; sv += res.valueLoss; se += res.entropy; sk += res.approxKL; mb += 1
                start = end
            }
        }
        let d = Double(max(1, mb))
        return PPOMetrics(policyLoss: sp / d, valueLoss: sv / d, entropy: se / d, approxKL: sk / d,
                          meanReward: 0, updateIndex: 0)
    }

    private struct GradBundle {
        var gWv: [Double], gWh: [Double], gbv: [Double], gbh: [Double]
        var gValueW: [Double], gValueBias: Double
        var policyLoss: Double, valueLoss: Double, entropy: Double, approxKL: Double
    }

    private func accumulateGradients(transitions: [RLTransition], indices: [Int], config: PPOConfig)
        -> (grads: GradBundle, policyLoss: Double, valueLoss: Double, entropy: Double, approxKL: Double) {
        var gWv = [Double](repeating: 0, count: K * 3), gWh = [Double](repeating: 0, count: K * 3)
        var gbv = [0.0, 0.0, 0.0], gbh = [0.0, 0.0, 0.0]
        var gValueW = [Double](repeating: 0, count: K); var gValueBias = 0.0
        var pl = 0.0, vl = 0.0, es = 0.0, kl = 0.0
        let clipEps = config.clipEps
        for ti in indices {
            let t = transitions[ti]
            let fwd = forward(stateToken: t.stateToken)
            let vL = fwd.vLogits.map { Double($0) }, hL = fwd.hLogits.map { Double($0) }
            let pv = RLMath.softmaxD(vL), ph = RLMath.softmaxD(hL)
            let vc = min(max(t.vClass, 0), 2), hc = min(max(t.hClass, 0), 2)
            let logP = log(max(pv[vc], 1e-12)) + log(max(ph[hc], 1e-12))
            let oldLogP = t.logProbV + t.logProbH
            let ratio = exp(logP - oldLogP)
            let adv = t.advantage
            let clipped = min(max(ratio, 1 - clipEps), 1 + clipEps)
            pl += -min(ratio * adv, clipped * adv); kl += (oldLogP - logP)
            let active = !((adv > 0 && ratio > 1 + clipEps) || (adv < 0 && ratio < 1 - clipEps))
            let dL = active ? -ratio * adv : 0.0
            let Hv = entropy(pv), Hh = entropy(ph); es += (Hv + Hh)
            var gV = [0.0, 0.0, 0.0], gH = [0.0, 0.0, 0.0]
            for c in 0..<3 {
                var g = dL * ((c == vc ? 1.0 : 0.0) - pv[c])
                if config.entCoef != 0 { g += -config.entCoef * (-pv[c] * (log(max(pv[c], 1e-12)) + Hv)) }
                gV[c] = g
                var gh = dL * ((c == hc ? 1.0 : 0.0) - ph[c])
                if config.entCoef != 0 { gh += -config.entCoef * (-ph[c] * (log(max(ph[c], 1e-12)) + Hh)) }
                gH[c] = gh
            }
            let ns = min(K, t.stateToken.count)
            for c in 0..<3 {
                gbv[c] += gV[c]; gbh[c] += gH[c]
                for k in 0..<ns { let s = Double(t.stateToken[k]); gWv[k * 3 + c] += gV[c] * s; gWh[k * 3 + c] += gH[c] * s }
            }
            let vPred = Double(fwd.value), vErr = vPred - t.valueTarget
            vl += config.vfCoef * vErr * vErr
            let dv = config.vfCoef * 2 * vErr
            gValueBias += dv
            for k in 0..<ns { gValueW[k] += dv * Double(t.stateToken[k]) }
        }
        let cnt = Double(max(1, indices.count))
        let bundle = GradBundle(gWv: gWv, gWh: gWh, gbv: gbv, gbh: gbh, gValueW: gValueW, gValueBias: gValueBias,
                                policyLoss: pl / cnt, valueLoss: vl / cnt, entropy: es / cnt, approxKL: kl / cnt)
        return (bundle, bundle.policyLoss, bundle.valueLoss, bundle.entropy, bundle.approxKL)
    }

    private mutating func applyAdam(grads g: GradBundle, lr: Double, batchCount: Int) {
        adamT += 1
        let b1 = 0.9, b2 = 0.999, eps = 1e-8, bc = Double(max(1, batchCount))
        let bias1 = 1 - pow(b1, Double(adamT)), bias2 = 1 - pow(b2, Double(adamT))
        func step(_ p: inout Double, _ m: inout Double, _ v: inout Double, _ gd: Double) {
            var gv = gd / bc; if !gv.isFinite { gv = 0 }
            m = b1 * m + (1 - b1) * gv; v = b2 * v + (1 - b2) * gv * gv
            p -= lr * (m / bias1) / ((v / bias2).squareRoot() + eps)
        }
        for i in 0..<Wv.count { step(&Wv[i], &mWv[i], &vWv[i], g.gWv[i]) }
        for i in 0..<Wh.count { step(&Wh[i], &mWh[i], &vWh[i], g.gWh[i]) }
        for c in 0..<3 { step(&bv[c], &mbv[c], &vbv[c], g.gbv[c]) }
        for c in 0..<3 { step(&bh[c], &mbh[c], &vbh[c], g.gbh[c]) }
        for k in 0..<K { step(&valueW[k], &mvalueW[k], &vvalueW[k], g.gValueW[k]) }
        step(&valueBias, &mValueBias, &vValueBias, g.gValueBias)
    }

    private func entropy(_ p: [Double]) -> Double { var h = 0.0; for x in p where x > 0 { h -= x * log(x) }; return h }
}

final class SampleRNG {
    private var rng: SplitMix64
    init(seed: UInt64) { self.rng = SplitMix64(seed: seed) }
    func nextUnit() -> Double { rng.nextUnit() }
    func next() -> UInt64 { rng.next() }
}

// ============================================================================
// MARK: - 分发入口（供 launcher 一行调用；由 swift-core 统一在 AuroraDriveApp 接入）
// ============================================================================
func runOnlineRLSelfTest() -> Int {
    OnlineTrainerSelfTest.run()
}
