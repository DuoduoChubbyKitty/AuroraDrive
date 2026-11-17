// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PolicyHeadSelfTest.swift — 策略头 PPO 自检（-rl-core-selftest）
//
//  【为什么必须建这个】
//    「能编译」不等于「算得对」。本仓历史多次出现「登记了自检却从没真跑」→ 假绿。
//    本文件用**真实断言**（不是 H.check(True) 那种恒真）验证 PolicyHead 的核心：
//      ① softmax 归一（Σp=1，且 logSoftmax=log(softmax)）；
//      ② logProb/采样与 log-softmax 自洽；
//      ③ **解析梯度 == 有限差分梯度**（最大相对误差 < 1e-3）——这是最容易写错、
//         也最能证明反向传播正确的硬指标；
//      ④ PPO 更新后 loss 显著下降（并打印 loss 曲线）；
//      ⑤ Adam 更新后参数确实改变、forward 输出随之改变；
//      ⑥ value 回归能让 critic 拟合合成 target；
//      ⑦ init(fromJSON:) 能真实加载 A 域的 swift_head_init.json；
//      ⑧ GAE / logSoftmax 的语义与 tools/v3_rl/reward.py 对齐。
//
//  【断言风格】沿用本仓自检惯例：`check(name, cond, detail)` 打印 ✓/✗，
//    返回失败项数（0 = 全过）。逐条都是可证伪的真断言。
// ============================================================================

import Foundation

enum PolicyHeadSelfTest {

    /// 自检入口（由启动器分发 `-rl-core-selftest` 时调用）。
    /// - Returns: 失败项数；0 = 全部通过。
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("  \(condition ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 策略头 PPO 核心自检（-rl-core-selftest）═══")

        failures += checkSoftmaxAndLogProb(check)
        print("")
        failures += checkAnalyticGradient(check)
        print("")
        failures += checkReverseNumerical(check)
        print("")
        failures += checkPPOLossDecreases(check)
        print("")
        failures += checkAdamChangesOutput(check)
        print("")
        failures += checkValueRegression(check)
        print("")
        failures += checkJSONLoading(check)
        print("")
        failures += checkGAEAndLogSoftmax(check)

        print("")
        print(failures == 0
              ? "═══ 结果：全部通过 ✅（\(failures) 项失败）═══"
              : "═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        return failures
    }

    // MARK: - 合成数据工具

    /// 生成 256 维状态向量（确定性公式，不用随机 → 有限差分比对可复现、不抖动）。
    private static func makeState(_ idx: Int) -> [Float] {
        var s = [Float](repeating: 0, count: PolicyHead.stateDimension)
        let f1 = 0.11 + Double(idx % 7) * 0.013
        let f2 = 0.073 + Double(idx % 5) * 0.019
        let phase = Double(idx) * 0.41
        for d in 0..<PolicyHead.stateDimension {
            let v = sin(Double(d) * f1 + phase) + 0.5 * cos(Double(d) * f2 - phase)
            s[d] = Float(v)
        }
        return s
    }

    /// 造一批 transition，advantage / valueTarget 用固定规则（梯度校验时保持不变）。
    private static func makeTransitions(_ n: Int) -> [RLTransition] {
        var out: [RLTransition] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let state = makeState(i)
            let vClass = i % PolicyHead.numV
            let hClass = (i / PolicyHead.numV) % PolicyHead.numH
            out.append(RLTransition(
                stateToken: state, vClass: vClass, hClass: hClass,
                logProbV: -1.05 - Double(i % 3) * 0.03,
                logProbH: -1.10 - Double(i % 2) * 0.04,
                reward: Double(i % 5) * 0.1,
                value: 0.0, tookOver: false, isTerminal: false,
                advantage: Double((i % 4) - 2) * 0.3,   // 正负混合，覆盖 PPO 两分支
                valueTarget: Double(i % 3) * 0.2 - 0.5))
        }
        return out
    }

    private static func configureForGradientCheck() -> PPOConfig {
        // entCoef 非零 → 同时校验 entropy 分支梯度；vfCoef 非零 → 同时校验 value 分支。
        var cfg = PPOConfig()
        cfg.entCoef = 0.01
        cfg.vfCoef = 0.5
        return cfg
    }

    // MARK: - ① softmax / logProb

    private static func checkSoftmaxAndLogProb(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ① softmax 归一 / logProb 自洽 ──")

        let logits: [Double] = [2.0, -1.0, 0.5]
        let p = PolicyHead.softmax(logits)
        let sum = p.reduce(0, +)
        c("softmax 各元素 ∈ (0,1)", p.allSatisfy { $0 > 0 && $0 < 1 }, "p=\(fmt(p))")
        c("softmax 归一 Σp == 1（误差 <1e-12）", abs(sum - 1.0) < 1e-12, "Σp=\(fmt(sum))")

        let lp = PolicyHead.logSoftmax(logits)
        // 逐元素：lp 与 log(p) 必须逐元素有限且 |差|<1e-12（不能只取 .max()，NaN 会掩盖）
        let lpRes = finiteAndClose(lp, p.map { log($0) }, tol: 1e-12)
        c("logSoftmax == log(softmax)（逐元素有限 + |差|<1e-12）", lpRes.ok,
          "maxErr=\(fmtSci(lpRes.maxErr)) nf=\(lpRes.nonFinite)")

        // 数值稳定性：大 logits 不溢出
        let big: [Double] = [1000.0, 1001.0, 999.0]
        let pb = PolicyHead.softmax(big)
        c("大 logits softmax 不溢出且归一",
          pb.allSatisfy { $0.isFinite && $0 > 0 } && abs(pb.reduce(0, +) - 1.0) < 1e-12,
          "Σp=\(fmt(pb.reduce(0, +)))")

        // 采样得到的 logProb 与 logSoftmax 对应项一致；且能覆盖到非 0 类别
        let head = PolicyHead(randomSeed: 12345)
        let fwd = head.forward(stateToken: makeState(3))
        var rng = XorShift64(seed: 777)
        var sawNonZero = false
        var sampleOk = true
        let vlp = PolicyHead.logSoftmax(fwd.vLogits.map { Double($0) })
        let hlp = PolicyHead.logSoftmax(fwd.hLogits.map { Double($0) })
        for _ in 0..<64 {
            let s = head.stochasticSample(vLogits: fwd.vLogits, hLogits: fwd.hLogits, rng: &rng)
            let refV = vlp[s.vClass]
            let refH = hlp[s.hClass]
            let dV = s.logProbV - refV
            let dH = s.logProbH - refH
            // 显式有限性：采样值/参考值/差值任一非有限即失败（堵 NaN 比较恒 false 的假绿）
            if !s.logProbV.isFinite || !refV.isFinite || !dV.isFinite || abs(dV) > 1e-9
                || !s.logProbH.isFinite || !refH.isFinite || !dH.isFinite || abs(dH) > 1e-9 {
                sampleOk = false
            }
            if s.vClass > 0 { sawNonZero = true }
        }
        c("采样 logProbV/H == 对应 logSoftmax 项（含有限性）", sampleOk)
        c("采样能覆盖到非 0 类别（非常数输出）", sawNonZero)
        return local
    }

    // MARK: - ② 解析梯度 vs 有限差分（主证据）+ PPO 四象限梯度

    private static func checkAnalyticGradient(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ② 解析梯度 == 有限差分（主证据，容差 1e-3）──")

        let head = PolicyHead(randomSeed: 20260517)
        let cfg = configureForGradientCheck()
        let trans = makeTransitions(12)
        let (_, grads, _) = head.ppoLossAndGradients(trans, config: cfg)

        var maxRel = 0.0
        var checkedCount = 0
        var worst = ""
        // ★ NaN 假绿缺口修复：任何抽样点若解析梯度/数值梯度/相对误差为非有限值，
        //   单独记为失败——不能因为 NaN > maxRel 恒 false 就悄悄放过。
        var nonFiniteCount = 0
        var nonFiniteInfo = ""
        let h = 1e-5
        func relErr(_ a: Double, _ b: Double) -> Double {
            abs(a - b) / max(1e-4, abs(a) + abs(b))
        }

        // 用「拷贝 head → 改一个权重 → 重算 loss」做中心差分，避免 inout 别名问题。
        func fd(_ name: String, _ analytic: [Double], _ idxs: [Int],
                _ readW: (PolicyHead) -> [Double],
                _ writeW: (inout PolicyHead, Int, Double) -> Void) {
            let base = readW(head)
            for idx in idxs where idx < analytic.count && idx < base.count {
                let orig = base[idx]
                var hp = head; writeW(&hp, idx, orig + h)
                let lossP = hp.ppoLossOnly(trans, config: cfg)
                var hm = head; writeW(&hm, idx, orig - h)
                let lossM = hm.ppoLossOnly(trans, config: cfg)
                let numeric = (lossP - lossM) / (2 * h)
                let analyticV = analytic[idx]
                let e = relErr(analyticV, numeric)
                checkedCount += 1
                // 三者之一非有限 → 计入假绿缺口
                if !analyticV.isFinite || !numeric.isFinite || !e.isFinite {
                    nonFiniteCount += 1
                    if nonFiniteInfo.isEmpty {
                        nonFiniteInfo = "\(name)[\(idx)] a=\(analyticV) n=\(numeric) e=\(e)"
                    }
                    continue
                }
                if e > maxRel { maxRel = e; worst = "\(name)[\(idx)]" }
            }
        }

        fd("trunk.0.weight", grads.dW1, [0, 5, 300, 5000, 40000],
           { $0.trunk0.weight }, { hp, i, v in hp.trunk0.weight[i] = v })
        fd("trunk.3.weight", grads.dW2, [0, 7, 100, 5000, 15000],
           { $0.trunk1.weight }, { hp, i, v in hp.trunk1.weight[i] = v })
        fd("vertical.weight", grads.dWv, [0, 33, 95, 150, 287],
           { $0.vertical.weight }, { hp, i, v in hp.vertical.weight[i] = v })
        fd("horizontal.weight", grads.dWh, [1, 40, 96, 200, 286],
           { $0.horizontal.weight }, { hp, i, v in hp.horizontal.weight[i] = v })
        fd("value.weight", grads.dWval, [0, 50, 255],
           { $0.valueLayer.weight }, { hp, i, v in hp.valueLayer.weight[i] = v })
        fd("trunk.0.bias", grads.dB1, [0, 17, 100, 191],
           { $0.trunk0.bias }, { hp, i, v in hp.trunk0.bias[i] = v })
        fd("vertical.bias", grads.dBv, [0, 1, 2],
           { $0.vertical.bias }, { hp, i, v in hp.vertical.bias[i] = v })
        fd("value.bias", grads.dBval, [0],
           { $0.valueLayer.bias }, { hp, i, v in hp.valueLayer.bias[i] = v })

        c("抽样 \(checkedCount) 个参数：解析/数值/误差三者全部有限（无 NaN/Inf 假绿）",
          nonFiniteCount == 0, nonFiniteCount == 0 ? "" : nonFiniteInfo)
        c("抽样 \(checkedCount) 个参数：解析梯度与有限差分一致（最大相对误差 <1e-3）",
          maxRel < 1e-3, "maxRelErr=\(fmtSci(maxRel)) @ \(worst)")

        // ratio 与 old logProb 自洽（单样本）：ratio>0 且有限
        let one = [trans[0]]
        let fwd = head.forward(stateToken: one[0].stateToken)
        let vlp = PolicyHead.logSoftmax(fwd.vLogits.map { Double($0) })
        let hlp = PolicyHead.logSoftmax(fwd.hLogits.map { Double($0) })
        let ratio = exp((vlp[one[0].vClass] - one[0].logProbV) + (hlp[one[0].hClass] - one[0].logProbH))
        c("单样本 ratio 有限且 > 0", ratio.isFinite && ratio > 0, "ratio=\(fmt(ratio))")

        // ── PPO clip 四区域：显式构造 ratio 落入每种区域，断言梯度分支正确 ──
        // 本仓实现（PolicyHead.ppoLossAndGradients）：
        //   surr1 = ratio·A；surr2 = clip(ratio, 1-ε, 1+ε)·A；pgElem = -min(surr1, surr2)；
        //   dpgElem/dratio = -A（min 选中 surr1 → 梯度保留）
        //                 或 0（min 选中 surr2 且 ratio 已越界 → 梯度归零）；G = dpgDRatio·ratio。
        // 用默认 ε=0.2（lower=0.8, upper=1.2），vfCoef=entCoef=0 隔离纯策略梯度，
        // 构造下 4 个个例并**逐区域**核对 dWv（G 经 softmax 传到 h2 的外积）与闭式期望一致——
        // 即真正验证「该区域走保留分支还是归零分支」，而非只看优势符号。
        var cfgR = PPOConfig()
        cfgR.clipEps = 0.2
        cfgR.vfCoef = 0
        cfgR.entCoef = 0
        let epsR = cfgR.clipEps
        let rState = makeState(7)
        let rFwd = head.forward(stateToken: rState)
        let rVlog = rFwd.vLogits.map { Double($0) }
        let rHlog = rFwd.hLogits.map { Double($0) }
        let rLpV = PolicyHead.logSoftmax(rVlog)
        let rLpH = PolicyHead.logSoftmax(rHlog)
        let rPV = PolicyHead.softmax(rVlog)
        // h2 = ReLU(trunk1(ReLU(trunk0(x))))（用于闭式 dWv = dLv ⊗ h2）
        let rx = rState.map { Double($0) }
        let rh1 = head.trunk0.forward(rx, batch: 1).map { $0 > 0 ? $0 : 0 }
        let rh2 = head.trunk1.forward(rh1, batch: 1).map { $0 > 0 ? $0 : 0 }
        let rVC = 0, rHC = 0

        func regionCase(_ name: String, advantage: Double, targetRatio: Double,
                        expectActive: Bool) {
            // 构造精确 ratio：把整个 log 比值放在 vertical 的 oldLogProb 上
            let t = RLTransition(stateToken: rState, vClass: rVC, hClass: rHC,
                                 logProbV: rLpV[rVC] - log(targetRatio),
                                 logProbH: rLpH[rHC],
                                 reward: 0, value: 0, tookOver: false, isTerminal: true,
                                 advantage: advantage, valueTarget: 0)
            let ratio = exp((rLpV[rVC] - t.logProbV) + (rLpH[rHC] - t.logProbH))
            let (_, g, _) = head.ppoLossAndGradients([t], config: cfgR)
            // 闭式期望：active → G = -A·ratio（保留）；clipped → G = 0（归零）
            let G = expectActive ? (-advantage * ratio) : 0.0
            var dLv = [Double](repeating: 0, count: PolicyHead.numV)
            for k in 0..<PolicyHead.numV {
                dLv[k] = G * ((k == rVC ? 1.0 : 0.0) - rPV[k])
            }
            var expDW = [Double](repeating: 0, count: head.vertical.weight.count)
            for o in 0..<PolicyHead.numV { for i in 0..<PolicyHead.hidden2 {
                expDW[o * PolicyHead.hidden2 + i] = dLv[o] * rh2[i]
            }}
            var maxErr = 0.0, nf = 0
            for i in 0..<g.dWv.count {
                let a = g.dWv[i], b = expDW[i]
                if !a.isFinite || !b.isFinite { nf += 1; continue }
                let e = abs(a - b); if e > maxErr { maxErr = e }
            }
            // maxAbs 只在有限元素上取最大值（非有限已在上方 nf 计数，会令 matchOk=false）
            let maxAbs = g.dWv.filter { $0.isFinite }.map { abs($0) }.max() ?? 0
            let ratioOk = abs(ratio - targetRatio) < 1e-9
            // 容差 1e-6（相对）：exp/log 往返 + 96 项外积累加的浮点误差约 1e-9 量级；
            // 若走了错误分支，保留↔归零差值是 0.5 量级，1e-6 容差足以严格区分。
            let matchOk = (nf == 0) && (maxErr < 1e-6 * max(1.0, maxAbs))
            let magOk = expectActive ? (maxAbs > 1e-6) : (maxAbs < 1e-12)
            c("clip 区域[\(name)] A=\(advantage) ratio=\(targetRatio) "
              + "\(expectActive ? "保留梯度" : "归零")：ratio精确 + 闭式dWv吻合 + 幅度\(expectActive ? ">0" : "≈0")",
              ratioOk && matchOk && magOk,
              "ratio=\(fmt(ratio)) maxErr=\(fmtSci(maxErr)) maxAbs=\(fmtSci(maxAbs)) nf=\(nf)")
        }
        // (a) 正优势·未超上限(ratio=1.1∈band) → 保留；(b) 正优势·超上限(1.3>1.2) → 归零
        // (c) 负优势·未破下限(0.9∈band) → 保留；(d) 负优势·破下限(0.7<0.8) → 归零
        regionCase("a 正优势·未超上限", advantage: 0.5, targetRatio: 1.0 + 0.5 * epsR, expectActive: true)
        regionCase("b 正优势·超上限", advantage: 0.5, targetRatio: 1.0 + 1.5 * epsR, expectActive: false)
        regionCase("c 负优势·未破下限", advantage: -0.5, targetRatio: 1.0 - 0.5 * epsR, expectActive: true)
        regionCase("d 负优势·破下限", advantage: -0.5, targetRatio: 1.0 - 1.5 * epsR, expectActive: false)
        return local
    }

    // MARK: - ③ Linear 反向数值自洽（dX/dW 定义）

    private static func checkReverseNumerical(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ③ Linear 反向数值自洽（dW=ΣdY·X, dX=dY·W）──")

        let layer = LinearLayer(inDim: 3, outDim: 2,
                                weight: [0.2, -0.1, 0.4, 0.3, 0.5, -0.2],
                                bias: [0.1, -0.3])
        let X: [Double] = [1.0, 2.0, -1.0, 0.5, -0.5, 1.5]   // batch=2, in=3
        let dY: [Double] = [0.3, -0.7, 0.2, 0.9]              // batch=2, out=2
        let (dX, dW, dB) = layer.backward(X, dY, batch: 2)

        // 逐元素检查：解析值/期望值均须 isFinite 且 |差|<tol；任一非有限或数量不符即失败。
        // （Codex 复审 cc426be：原 `.max()` 在混入 NaN 时行为不可靠，会掩盖假绿。）
        func elemwiseOK(_ got: [Double], _ want: [Double], _ tol: Double) -> (ok: Bool, maxErr: Double, nf: Int) {
            var maxErr = 0.0
            var nf = 0
            if got.count != want.count { nf += 1 }
            for i in 0..<min(got.count, want.count) {
                let a = got[i], b = want[i]
                if !a.isFinite || !b.isFinite { nf += 1; continue }
                let e = abs(a - b)
                if e > maxErr { maxErr = e }
            }
            return (nf == 0 && maxErr < tol, maxErr, nf)
        }

        var dWExpect = [Double](repeating: 0, count: 6)
        for r in 0..<2 { for o in 0..<2 { for i in 0..<3 {
            dWExpect[o * 3 + i] += dY[r * 2 + o] * X[r * 3 + i]
        }}}
        let wRes = elemwiseOK(dW, dWExpect, 1e-12)
        c("dW 手算吻合（逐元素有限 + |差|<1e-12）", wRes.ok,
          "maxErr=\(fmtSci(wRes.maxErr)) nf=\(wRes.nf)")

        var dBExpect = [Double](repeating: 0, count: 2)
        for r in 0..<2 { for o in 0..<2 { dBExpect[o] += dY[r * 2 + o] } }
        let bRes = elemwiseOK(dB, dBExpect, 1e-12)
        c("dB 手算吻合（逐元素有限 + |差|<1e-12）", bRes.ok,
          "maxErr=\(fmtSci(bRes.maxErr)) nf=\(bRes.nf)")

        var dXExpect = [Double](repeating: 0, count: 6)
        for r in 0..<2 { for i in 0..<3 { for o in 0..<2 {
            dXExpect[r * 3 + i] += dY[r * 2 + o] * layer.weight[o * 3 + i]
        }}}
        let xRes = elemwiseOK(dX, dXExpect, 1e-12)
        c("dX 手算吻合（逐元素有限 + |差|<1e-12）", xRes.ok,
          "maxErr=\(fmtSci(xRes.maxErr)) nf=\(xRes.nf)")
        return local
    }

    // MARK: - ④ PPO loss 下降

    private static func checkPPOLossDecreases(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ④ PPO 迭代 loss 显著下降 ──")

        var head = PolicyHead(randomSeed: 424242)
        var cfg = PPOConfig()
        cfg.lr = 5e-3
        cfg.epochs = 1          // 每更新 1 epoch，便于多轮观察曲线
        cfg.batch = 11
        cfg.vfCoef = 0.5
        cfg.entCoef = 0.0
        cfg.maxGradNorm = 1.0

        let trans = makeTransitions(11)
        let initialLoss = head.ppoLossOnly(trans, config: cfg)
        var history: [Double] = [initialLoss]
        for _ in 0..<25 {
            _ = head.updatePPO(transitions: trans, config: cfg)
            history.append(head.ppoLossOnly(trans, config: cfg))
        }
        let finalLoss = history.last!
        let drop = (initialLoss - finalLoss) / max(1e-9, abs(initialLoss))
        c("loss 显著下降（相对降幅 > 30%）", drop > 0.30,
          "initial=\(fmt(initialLoss)) → final=\(fmt(finalLoss))，降幅=\(fmtPct(drop))")
        c("末值 <= 初值（不上升）", finalLoss <= initialLoss, "final<=initial=\(finalLoss <= initialLoss)")
        let q = max(1, history.count / 4)
        let frontAvg = history[0..<q].reduce(0, +) / Double(q)
        let backAvg = history[(history.count - q)..<history.count].reduce(0, +) / Double(q)
        c("曲线整体向下（前段均值 > 后段均值）", frontAvg > backAvg,
          "frontAvg=\(fmt(frontAvg)) > backAvg=\(fmt(backAvg))")
        print("    loss 曲线：" + lossCurve(history))
        return local
    }

    // MARK: - ⑤ Adam 更新后输出改变

    private static func checkAdamChangesOutput(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ⑤ Adam 更新确实改变参数与输出 ──")

        var head = PolicyHead(randomSeed: 987654321)
        var cfg = PPOConfig()
        cfg.lr = 1e-2
        cfg.epochs = 1
        cfg.batch = 8
        cfg.entCoef = 0.0

        let trans = makeTransitions(8)
        let probe = makeState(5)
        let before = head.forward(stateToken: probe)
        let wBefore = head.vertical.weight[0]
        _ = head.updatePPO(transitions: trans, config: cfg)
        let after = head.forward(stateToken: probe)
        let wAfter = head.vertical.weight[0]

        let outChanged = zip(before.vLogits, after.vLogits).contains { abs(Double($0) - Double($1)) > 1e-9 }
            || zip(before.hLogits, after.hLogits).contains { abs(Double($0) - Double($1)) > 1e-9 }
            || abs(before.value - after.value) > 1e-9
        c("updatePPO 后参数改变（vertical.weight[0] 变化）", wBefore != wAfter,
          "\(fmt(wBefore)) → \(fmt(wAfter))")
        c("updatePPO 后 forward 输出改变", outChanged,
          "vBefore=\(fmt(before.vLogits.map { Double($0) })) vAfter=\(fmt(after.vLogits.map { Double($0) }))")
        return local
    }

    // MARK: - ⑥ value 回归

    private static func checkValueRegression(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ⑥ critic 拟合 value target（MSE 下降）──")

        var head = PolicyHead(randomSeed: 555)
        var rng = XorShift64(seed: 42)
        var trans: [RLTransition] = []
        for _ in 0..<64 {
            var s = [Float](repeating: 0, count: PolicyHead.stateDimension)
            var target = 0.0
            for d in 0..<PolicyHead.stateDimension {
                let v = rng.nextGaussian()
                s[d] = Float(v)
                target += v * 0.02   // 线性可分的 target
            }
            trans.append(RLTransition(stateToken: s, vClass: 0, hClass: 0,
                                      logProbV: -1.0, logProbH: -1.0, reward: 0,
                                      value: 0, tookOver: false, isTerminal: false,
                                      advantage: 0, valueTarget: target))
        }
        var cfg = PPOConfig()
        cfg.lr = 5e-3
        cfg.epochs = 3
        cfg.batch = 16
        cfg.vfCoef = 1.0
        cfg.entCoef = 0.0

        func valueMSE() -> Double {
            var sum = 0.0
            for t in trans {
                let v = Double(head.forward(stateToken: t.stateToken).value)
                let d = v - t.valueTarget
                sum += d * d
            }
            return sum / Double(trans.count)
        }
        let mse0 = valueMSE()
        for _ in 0..<60 { _ = head.updatePPO(transitions: trans, config: cfg) }
        let mse1 = valueMSE()
        c("value MSE 显著下降（降幅 > 50%）", mse1 < mse0 * 0.5,
          "MSE \(fmt(mse0)) → \(fmt(mse1))，降幅=\(fmtPct((mse0 - mse1) / max(1e-9, mse0)))")
        return local
    }

    // MARK: - ⑦ init(fromJSON:)

    private static func checkJSONLoading(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ⑦ init(fromJSON:) 真实加载 swift_head_init.json ──")

        let env = ProcessInfo.processInfo.environment["AURORA_HEAD_INIT_JSON"]
        let candidates = candidateJSONPaths(override: env)
        var loadedURL: URL? = nil
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            loadedURL = URL(fileURLWithPath: p); break
        }
        guard let url = loadedURL else {
            // 文件不存在不判失败（A 域尚未产出时），但明确 SKIP 说明，不冒充通过。
            print("  ⚠️ SKIP：未找到 swift_head_init.json（尝试：\(candidates.joined(separator: ", "))）")
            return local
        }
        do {
            let head = try PolicyHead(fromJSON: url)
            c("从 JSON 成功构造 PolicyHead（\(url.lastPathComponent)）", true)
            let fwd = head.forward(stateToken: makeState(1))
            let finite = fwd.vLogits.allSatisfy { $0.isFinite }
                && fwd.hLogits.allSatisfy { $0.isFinite } && fwd.value.isFinite
            c("加载后 forward 输出有限", finite)
            c("加载后 vertical 权重非全零", head.vertical.weight.contains { $0 != 0 })
            c("加载后 value 头按规格从 0 起（bias==0）", head.valueLayer.bias[0] == 0.0)

            // 故意用错误形状的 JSON 触发可定位错误
            let badURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bad_head_\(Int(Date().timeIntervalSince1970)).json")
            let bad: [String: Any] = ["dim_state_token": 256,
                                      "tensors": [["name": "trunk.0.weight", "shape": [1, 1], "data": [0.0]]]]
            if let data = try? JSONSerialization.data(withJSONObject: bad) {
                try? data.write(to: badURL)
                do {
                    _ = try PolicyHead(fromJSON: badURL)
                    c("坏 JSON 应抛错（形状不符）", false)
                } catch {
                    c("坏 JSON 抛可定位错误（形状不符）", true, "\(error)")
                }
                try? FileManager.default.removeItem(at: badURL)
            }
        } catch {
            c("从 JSON 构造 PolicyHead", false, "抛错：\(error)")
        }
        return local
    }

    // MARK: - ⑧ GAE / logSoftmax 语义

    private static func checkGAEAndLogSoftmax(_ check: (String, Bool, String) -> Void) -> Int {
        var local = 0
        func c(_ n: String, _ ok: Bool, _ d: String = "") { if !ok { local += 1 }; check(n, ok, d) }
        print("── ⑧ GAE 逐 episode 隔离 / logSoftmax 语义 ──")

        func mkTransition(_ reward: Double, terminal: Bool) -> RLTransition {
            RLTransition(stateToken: makeState(0), vClass: 0, hClass: 0,
                         logProbV: -1, logProbH: -1, reward: reward, value: 0,
                         tookOver: false, isTerminal: terminal)
        }

        // 两个独立 episode（各自末帧 isTerminal=true），奖励 0 / 10，value 全 0。
        // 期望：ep1 优势=0，ep2 优势=10（不跨边界泄漏，对齐 reward.py 单测语义）。
        var tr = [mkTransition(0.0, terminal: true), mkTransition(10.0, terminal: true)]
        PolicyHead.computeGAE(&tr, gamma: 0.99, lam: 0.95)
        c("逐 episode 隔离：ep1 优势 == 0", abs(tr[0].advantage) < 1e-9, "adv[0]=\(fmt(tr[0].advantage))")
        c("逐 episode 隔离：ep2 优势 == 10（不串入前一 episode）", abs(tr[1].advantage - 10.0) < 1e-9,
          "adv[1]=\(fmt(tr[1].advantage))")
        c("valueTarget == advantage + value（value=0 时相等）",
          abs(tr[1].valueTarget - tr[1].advantage) < 1e-12, "vt[1]=\(fmt(tr[1].valueTarget))")

        // 单 episode 多步：验证递推公式 delta= r+γv'-v; A=delta+γλA_next。
        var tr2 = [mkTransition(1.0, terminal: false), mkTransition(1.0, terminal: true)]
        tr2[0].value = 0.5; tr2[1].value = 0.2
        PolicyHead.computeGAE(&tr2, gamma: 0.9, lam: 0.8)
        // t=1 terminal: delta=1+0-0.2=0.8 → A1=0.8
        // t=0: delta=1+0.9*0.2-0.5=0.68 → A0=0.68+0.9*0.8*0.8=1.256
        c("GAE 递推：A1 == 0.8", abs(tr2[1].advantage - 0.8) < 1e-9, "A1=\(fmt(tr2[1].advantage))")
        c("GAE 递推：A0 == 1.256", abs(tr2[0].advantage - 1.256) < 1e-9, "A0=\(fmt(tr2[0].advantage))")

        // ── (P1-2) 末项 isTerminal=false：tailBootstrapValue 参与 nextV bootstrap ──
        // 单元素批次，value=0.5，r=1.0，γ=0.9，λ=0.8。
        //   tail=0：delta=1+0.9*0-0.5=0.5 → A0=0.5，valueTarget=0.5+0.5=1.0
        //   tail=5：delta=1+0.9*5-0.5=5.0 → A0=5.0，valueTarget=5.0+0.5=5.5
        //   两者差 == γ*tail = 0.9*5 = 4.5
        var tb0 = [mkTransition(1.0, terminal: false)]
        tb0[0].value = 0.5
        var tb5 = [mkTransition(1.0, terminal: false)]
        tb5[0].value = 0.5
        PolicyHead.computeGAE(&tb0, gamma: 0.9, lam: 0.8, tailBootstrapValue: 0)
        PolicyHead.computeGAE(&tb5, gamma: 0.9, lam: 0.8, tailBootstrapValue: 5)
        c("末项非 terminal：tail=0 → A0==0.5（符合公式）", abs(tb0[0].advantage - 0.5) < 1e-9,
          "A0(tail=0)=\(fmt(tb0[0].advantage))")
        c("末项非 terminal：tail=5 → A0==5.0（符合公式）", abs(tb5[0].advantage - 5.0) < 1e-9,
          "A0(tail=5)=\(fmt(tb5[0].advantage))")
        c("tail 影响量 == γ·tail（0.9*5=4.5）", abs((tb5[0].advantage - tb0[0].advantage) - 4.5) < 1e-9,
          "Δ=\(fmt(tb5[0].advantage - tb0[0].advantage))")
        c("末项非 terminal：tail=5 时 valueTarget==A0+value(5.5)",
          abs(tb5[0].valueTarget - 5.5) < 1e-9, "vt=\(fmt(tb5[0].valueTarget))")

        // ── 中间 isTerminal=true：正确切断递推（后半段奖励不泄漏到前半段）──
        // tr5 = [r=1,v=0.1,term=F], [r=2,v=0.2,term=T], [r=3,v=0.3,term=F]，γ=0.9,λ=0.8
        //   t=2(末,F,tail=0): delta=3-0.3=2.7 → A2=2.7
        //   t=1(term=T):      delta=2-0.2=1.8 → A1=1.8（在此切断）
        //   t=0(F): nextV=v1=0.2; delta=1+0.9*0.2-0.1=1.08; A0=1.08+0.72*1.8=2.376
        //   —— A0 与 t=2 的 reward 无关（否则说明没切断）
        var tr5 = [mkTransition(1.0, terminal: false),
                   mkTransition(2.0, terminal: true),
                   mkTransition(3.0, terminal: false)]
        tr5[0].value = 0.1; tr5[1].value = 0.2; tr5[2].value = 0.3
        PolicyHead.computeGAE(&tr5, gamma: 0.9, lam: 0.8)
        c("中途 terminal 切断：A2==2.7", abs(tr5[2].advantage - 2.7) < 1e-9, "A2=\(fmt(tr5[2].advantage))")
        c("中途 terminal 切断：A1==1.8", abs(tr5[1].advantage - 1.8) < 1e-9, "A1=\(fmt(tr5[1].advantage))")
        c("中途 terminal 切断：A0==2.376", abs(tr5[0].advantage - 2.376) < 1e-9, "A0=\(fmt(tr5[0].advantage))")
        var tr5b = tr5
        tr5b[2].reward = 999.0            // 改后半段奖励
        PolicyHead.computeGAE(&tr5b, gamma: 0.9, lam: 0.8)
        c("中途 terminal 切断：改 t=2 奖励不影响 A0（无跨段泄漏）",
          abs(tr5b[0].advantage - tr5[0].advantage) < 1e-12,
          "A0(orig)=\(fmt(tr5[0].advantage)) A0(改t2奖励)=\(fmt(tr5b[0].advantage))")

        // logSoftmax 与 softmax 数值一致
        let z: [Double] = [-0.3, 1.2, 0.0, -2.0]
        let ls = PolicyHead.logSoftmax(z)
        let sm = PolicyHead.softmax(z)
        // 逐元素：ls 与 log(sm) 必须逐元素有限且 |差|<1e-12（不能只取 .max()）
        let lsRes = finiteAndClose(ls, sm.map { log($0) }, tol: 1e-12)
        c("logSoftmax == log(softmax)（4 维，逐元素有限 + |差|<1e-12）", lsRes.ok,
          "maxErr=\(fmtSci(lsRes.maxErr)) nf=\(lsRes.nonFinite)")
        return local
    }

    // MARK: - 辅助：路径候选 / 格式化 / loss 曲线

    private static func candidateJSONPaths(override: String?) -> [String] {
        var out: [String] = []
        if let o = override { out.append(o) }
        // 从可执行文件路径逐级上溯，找到含 tools/v3_rl 的包根。
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<10 {
            out.append(dir.appendingPathComponent("tools/v3_rl/swift_head_init.json").path)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        out.append(FileManager.default.currentDirectoryPath + "/tools/v3_rl/swift_head_init.json")
        return out
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
    private static func fmt(_ v: [Double]) -> String {
        "[" + v.map { String(format: "%.4f", $0) }.joined(separator: ", ") + "]"
    }
    private static func fmtSci(_ v: Double) -> String { String(format: "%.3e", v) }
    private static func fmtPct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    /// 逐元素检查：两数组等长、对应元素全部 isFinite、且 |a−b|<tol。
    /// 任一元素非有限、或长度不符即判失败（返回 nonFinite 计数）——用于堵死
    /// 「.max() 在混入 NaN/Inf 时行为不可靠」造成的假绿（Codex 三轮复审 d78f7cc）。
    private static func finiteAndClose(_ got: [Double], _ want: [Double], tol: Double)
        -> (ok: Bool, maxErr: Double, nonFinite: Int) {
        var maxErr = 0.0
        var nonFinite = 0
        if got.count != want.count { nonFinite += 1 }
        for i in 0..<min(got.count, want.count) {
            let a = got[i], b = want[i]
            if !a.isFinite || !b.isFinite { nonFinite += 1; continue }
            let e = abs(a - b)
            if e > maxErr { maxErr = e }
        }
        return (nonFinite == 0 && maxErr < tol, maxErr, nonFinite)
    }

    private static func lossCurve(_ h: [Double]) -> String {
        guard !h.isEmpty else { return "(empty)" }
        let step = max(1, h.count / 12)
        var parts: [String] = []
        var i = 0
        while i < h.count { parts.append(String(format: "%.4f", h[i])); i += step }
        if (h.count - 1) % step != 0 { parts.append(String(format: "%.4f", h.last!)) }
        return parts.joined(separator: " → ")
    }
}
