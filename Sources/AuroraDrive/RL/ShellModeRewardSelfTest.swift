// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ShellModeRewardSelfTest.swift — 壳模式「速度三段奖励 / 回环 / 默认关」自检
//  （-rl-shell-selftest / --rl-shell-selftest）
//
//  【为什么单独一个文件、与 ShellModeSelfTest.swift 不同名】
//    仓库里已有一个 `ShellModeSelfTest.swift`，那是「壳模式 controller 的 start/stop
//    编排」自检（类型 `ShellModeControllerSelfTest`，flag `--shell-engine-selftest`，
//    假硬件不碰真引擎）。本文件是**另一件事**：只验证「速度三段奖励口径 + 策略头
//    存盘回环 + 默认关零副作用」这些纯逻辑/合成数据断言，不编排引擎、不碰窗口。
//    为避免与前者同文件并发冲突，本文件独立命名，但对外暴露的类型名仍叫
//    `ShellModeSelfTest`，以匹配启动器里已预留的 `ShellModeSelfTest.run()` 分发钩子。
//
//  【纯合成、不真训练、不真开游戏】
//    所有断言只吃合成输入：数值用公式手算、策略头用随机初始化、运行时默认不 start
//    （不加载 CoreML、不采样）。没有一处会真跑模型、真开游戏或真按键。
//
//  【为什么这些断言不是恒真】
//    · 速度三段：99/100/130/160/161 逐点对拍手算值，且同时校验 frameReward 里
//      「速度项 == config.speed × speedTerm」，并额外比较分界处的符号序；任何一点
//      写错（含边界方向、符号、系数）都会红。
//    · 存盘回环：先证明「两个不同种子的头权重不同」（回环非平凡），再断言存盘→加载
//      后逐元素 isFinite + 容差一致；若 load 是空操作会红。
//    · 默认关：把同一个 CGImage 灌 200 帧，断言 sampledFrames 恒 0、无 PPO 指标；
//      若 isRunning 门控失效（默认就会 collect）会红。
// ============================================================================

import Foundation
import CoreGraphics

enum ShellModeSelfTest {

    /// 启动器分发 `-rl-shell-selftest` 时调用。返回失败项数，0 = 全过。
    @MainActor
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 壳模式奖励/回环/默认关自检（-rl-shell-selftest，纯合成·不训练·不开游戏）═══")

        failures += runSpeedThreeSegmentChecks(check);   print("")
        failures += runTakeoverSealChecks(check);        print("")
        failures += runHeadStateDictRoundtripChecks(check); print("")
        failures += runDefaultOffChecks(check)

        if failures == 0 {
            print("═══ 结果：全部通过 ✅（\(failures) 项失败）═══")
        } else {
            print("═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        }
        return failures
    }

    // ========================================================================
    // MARK: - ① 速度三段奖励：99/100/130/160/161 各值正确 + speedValid=false→0
    // ========================================================================
    private static func runSpeedThreeSegmentChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("① 速度三段奖励（与 tools/v3_rl/reward.py 的 speed_term 同口径）")
        // 分界常数必须与 reward.py 的 SPEED_LOW_KMH / SPEED_HIGH_KMH 一致。
        check("下分界 speedLowKmh == 100（与 reward.py SPEED_LOW_KMH 一致）",
              isFiniteClose(RewardConfig.speedLowKmh, 100.0),
              String(format: "%.3f", RewardConfig.speedLowKmh))
        check("上分界 speedHighKmh == 160（与 reward.py SPEED_HIGH_KMH 一致）",
              isFiniteClose(RewardConfig.speedHighKmh, 160.0),
              String(format: "%.3f", RewardConfig.speedHighKmh))

        struct SpeedCase { let v: Double; let expect: Double; let label: String }
        let cases: [SpeedCase] = [
            SpeedCase(v: 99,  expect: -0.01,        label: "接近0的负"),
            SpeedCase(v: 100, expect: 0.0,          label: "下分界零点"),
            SpeedCase(v: 130, expect: 0.5,          label: "线性递增"),
            SpeedCase(v: 160, expect: 1.0,          label: "上分界最大正"),
            SpeedCase(v: 161, expect: -1.0 / 600.0, label: "越过即轻微扣"),
        ]
        // 用非默认 speed 权重，证明 frameReward 的速度项确实乘了 config.speed。
        let speedWeight = 3.0
        let cfg = RewardConfig(speed: speedWeight)
        for c in cases {
            let direct = OnlineTrainer.speedTerm(c.v, true)
            check("speedTerm(\(Int(c.v))) 值正确（\(c.label)）",
                  isFiniteClose(direct, c.expect),
                  String(format: "实际%.6f 期望%.6f", direct, c.expect))
            // 单帧：无碰撞/无接管/无车道偏置/前帧无效 → frameReward 只剩速度项。
            // v=99..161 均 >=1（不触发 stuck），previousSpeedValid=false 抑制 decel。
            let fr = OnlineTrainer.frameReward(
                signals: OnlineTrainer.RewardSignals(
                    speedKmh: c.v, speedValid: true, laneOffset: 0,
                    collided: false, tookOver: false),
                previousSpeedKmh: 0, previousSpeedValid: false, config: cfg)
            check("frameReward 速度项 == config.speed×speedTerm(\(Int(c.v)))",
                  isFiniteClose(fr, speedWeight * c.expect),
                  String(format: "实际%.6f 期望%.6f", fr, speedWeight * c.expect))
        }
        // speedValid=false → 该项为 0（不伪造），speedTerm 与 frameReward 都断言。
        for v in [99.0, 130.0, 161.0] {
            check("speedTerm(\(Int(v)), valid=false) == 0（不伪造）",
                  isFiniteClose(OnlineTrainer.speedTerm(v, false), 0.0), "")
            let fr = OnlineTrainer.frameReward(
                signals: OnlineTrainer.RewardSignals(
                    speedKmh: v, speedValid: false, laneOffset: 0,
                    collided: false, tookOver: false),
                previousSpeedKmh: 0, previousSpeedValid: false, config: cfg)
            check("frameReward(valid=false) 速度项 == 0（不伪造）", isFiniteClose(fr, 0.0),
                  String(format: "实际%.6f", fr))
        }
        // 符号序自检：防「某点数值对、但整体形状错」（160>130>100>99；161<0 且 161>200）。
        check("口径形状：160(最大正) > 130(半正) > 100(零) > 99(小负)",
              OnlineTrainer.speedTerm(160, true) > OnlineTrainer.speedTerm(130, true)
              && OnlineTrainer.speedTerm(130, true) > OnlineTrainer.speedTerm(100, true)
              && OnlineTrainer.speedTerm(100, true) > OnlineTrainer.speedTerm(99, true), "")
        check("口径形状：161(略负) < 0 且 161 高于 200(更负)",
              OnlineTrainer.speedTerm(161, true) < 0
              && OnlineTrainer.speedTerm(161, true) > OnlineTrainer.speedTerm(200, true), "")
        return 0
    }

    // ========================================================================
    // MARK: - ② 接管帧封口（markInvalid，不产生策略 transition）
    // ========================================================================
    private static func runTakeoverSealChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("② 接管帧封口：markInvalid 封口轨迹、接管动作不建 transition")
        let t2 = OnlineTrainer(policy: SelftestFixedPolicy(), rewardConfig: RewardConfig(),
                               ppoConfig: PPOConfig(), trainEvery: 100_000, metricsCapacity: 16)
        t2.setCaptureBatchesForTest(true)
        func feed(_ trainer: OnlineTrainer, vClass: Int, tookOver: Bool) {
            _ = trainer.collect(stateToken: [1],
                                sample: PolicySample(vClass: vClass, hClass: 1,
                                                     logProbV: 0, logProbH: 0, value: 0),
                                tookOver: tookOver, speedKmh: 100, speedValid: true,
                                collision: false, laneOffset: 0, isTerminal: false)
        }
        feed(t2, vClass: 1, tookOver: false)
        feed(t2, vClass: 1, tookOver: false)
        check("封口前 pending 有 2 条策略 transition",
              t2.pendingTransitionsForTest().count == 2,
              "实际 \(t2.pendingTransitionsForTest().count)")
        t2.markInvalid()   // == sealEpisode：接管/无效帧封口
        check("markInvalid 后 pending 清空（封口帧不产生策略 transition）",
              t2.pendingTransitionsForTest().isEmpty,
              "实际 \(t2.pendingTransitionsForTest().count)")
        // 单独再验一次「接管帧」：人类救援动作不进策略 transition，惩罚归到上一条 AI 帧。
        let t2b = OnlineTrainer(policy: SelftestFixedPolicy(), rewardConfig: RewardConfig(takeover: 10),
                                ppoConfig: PPOConfig(), trainEvery: 100_000, metricsCapacity: 16)
        t2b.setCaptureBatchesForTest(true)
        feed(t2b, vClass: 1, tookOver: false)          // 上一条 AI 动作 vClass=1
        feed(t2b, vClass: 2, tookOver: true)            // 接管帧：人类动作 vClass=2
        t2b.drainTrainingAndWait()
        let tb = t2b.capturedBatchesForTestSnapshot()
        check("接管后收尾训练恰好 1 批", tb.count == 1, "实际 \(tb.count)")
        if let batch = tb.first {
            check("批内只有 AI 动作(vClass=1)，无人类救援动作(vClass=2)",
                  batch.allSatisfy { $0.vClass != 2 } && batch.contains { $0.vClass == 1 }, "")
            check("接管强负惩罚(-takeover=-10)落在末条 AI transition 的 reward 上",
                  isFiniteClose(batch.last?.reward ?? .nan, -10.0),
                  String(format: "实际%.4f", batch.last?.reward ?? .nan))
        }
        check("接管帧不额外产生策略 transition（pending 清空）",
              t2b.pendingTransitionsForTest().isEmpty,
              "实际 \(t2b.pendingTransitionsForTest().count)")
        return 0
    }

    // ========================================================================
    // MARK: - ③ 策略头存盘/加载回环（head_state_dict 存盘再 load，权重一致）
    // ========================================================================
    private static func runHeadStateDictRoundtripChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("③ 策略头存盘/加载回环（head_state_dict 存盘 → load → 权重一致）")
        let head = PolicyHead(randomSeed: 0xBEEF)
        var loadedHead = PolicyHead(randomSeed: 0x1234)   // 不同初值，回环才有意义
        let preDiff = maxAbsDiff(head, loadedHead)
        check("加载前两个头权重不同（回环非恒真）", preDiff.isFinite && preDiff > 1e-6,
              String(format: "max|Δ|=%.3e", preDiff))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora_shell_selftest_head_\(UUID().uuidString).json")
        let saved = saveHeadStateDict(head, to: url)
        check("策略头 head_state_dict 存盘成功", saved, url.lastPathComponent)
        if saved {
            defer { try? FileManager.default.removeItem(at: url) }
            let ok = loadHeadStateDict(&loadedHead, from: url)
            check("策略头从存盘文件加载成功", ok, "")
            let postDiff = maxAbsDiff(head, loadedHead)
            check("存盘→加载后权重逐元素一致（无 NaN，容差 1e-12）",
                  postDiff.isFinite && postDiff < 1e-12,
                  String(format: "max|Δ|=%.3e", postDiff))
        } else {
            check("存盘失败，回环断言无法进行", false, "")
        }
        return 0
    }

    // ========================================================================
    // MARK: - ④ 默认关：isRunning=false 时 onFrame 不产生任何 collect
    // ========================================================================
    @MainActor
    private static func runDefaultOffChecks(_ check: (String, Bool, String) -> Void) -> Int {
        print("④ 默认关安全语义：未 start 时 onFrame 零采样/零 collect")
        let runtime = OnlineTrainingRuntime()   // 构造不加载模型；未 start → running=false
        check("新建运行时默认未运行（running == false）", runtime.running == false, "")
        if let img = makeTinyImage() {
            let before = runtime.sampledFrames
            for _ in 0..<200 {
                runtime.onFrame(img, signals: OnlineTrainingRuntime.FrameSignals(
                    speedKmh: 120, speedValid: true, tookOver: false,
                    collision: false, laneOffset: 0, manualStop: false))
            }
            check("默认关时 onFrame 200 次后 sampledFrames 仍为 0（无 collect）",
                  runtime.sampledFrames == 0 && before == 0,
                  "sampled=\(runtime.sampledFrames) skipped=\(runtime.skippedFrames)")
            check("默认关时无 PPO 训练指标（未触达 collect→train）",
                  runtime.metricsSummary() == nil, "")
        } else {
            check("合成测试帧构造失败", false, "")
        }
        return 0
    }

    // ========================================================================
    // MARK: - 工具
    // ========================================================================

    /// 逐元素有限性 + 容差判定（拒绝 NaN 假绿：任一非有限直接判失败）。
    private static func isFiniteClose(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool {
        a.isFinite && b.isFinite && abs(a - b) <= tol
    }

    // head_state_dict 存/取（复用 PolicyHead/LinearLayer 的 internal 权重字段）。
    // 键名与 Python 侧 head_state_dict 的语义一致（各 Linear 的 weight/bias）；这里额外
    // 含 trunk 两层（它们同样是可训练的一部分），足以证明整头参数的存盘回环自洽。

    private static func headStateDict(_ head: PolicyHead) -> [String: [Double]] {
        [
            "trunk0.weight": head.trunk0.weight, "trunk0.bias": head.trunk0.bias,
            "trunk1.weight": head.trunk1.weight, "trunk1.bias": head.trunk1.bias,
            "vertical.weight": head.vertical.weight, "vertical.bias": head.vertical.bias,
            "horizontal.weight": head.horizontal.weight, "horizontal.bias": head.horizontal.bias,
            "value.weight": head.valueLayer.weight, "value.bias": head.valueLayer.bias,
        ]
    }

    private static func saveHeadStateDict(_ head: PolicyHead, to url: URL) -> Bool {
        let dict = headStateDict(head)
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: url)
            return true
        } catch {
            print("  [存盘异常] \(error)")
            return false
        }
    }

    private static func loadHeadStateDict(_ head: inout PolicyHead, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        func arr(_ key: String, _ expectedCount: Int) -> [Double]? {
            guard let raw = obj[key] as? [Any], raw.count == expectedCount else { return nil }
            return raw.map { ($0 as? NSNumber)?.doubleValue ?? Double.nan }
        }
        guard let w0 = arr("trunk0.weight", head.trunk0.weight.count),
              let b0 = arr("trunk0.bias", head.trunk0.bias.count),
              let w1 = arr("trunk1.weight", head.trunk1.weight.count),
              let b1 = arr("trunk1.bias", head.trunk1.bias.count),
              let wv = arr("vertical.weight", head.vertical.weight.count),
              let bv = arr("vertical.bias", head.vertical.bias.count),
              let wh = arr("horizontal.weight", head.horizontal.weight.count),
              let bh = arr("horizontal.bias", head.horizontal.bias.count),
              let wval = arr("value.weight", head.valueLayer.weight.count),
              let bval = arr("value.bias", head.valueLayer.bias.count)
        else { return false }
        head.trunk0.weight = w0; head.trunk0.bias = b0
        head.trunk1.weight = w1; head.trunk1.bias = b1
        head.vertical.weight = wv; head.vertical.bias = bv
        head.horizontal.weight = wh; head.horizontal.bias = bh
        head.valueLayer.weight = wval; head.valueLayer.bias = bval
        return true
    }

    /// 两个头全参数的最大绝对差。任一维非有限即返回 +∞（拒绝 NaN 假绿）。
    private static func maxAbsDiff(_ a: PolicyHead, _ b: PolicyHead) -> Double {
        let da = headStateDict(a), db = headStateDict(b)
        var m = 0.0
        for (key, va) in da {
            guard let vb = db[key], vb.count == va.count else { return .infinity }
            for i in 0..<va.count {
                guard va[i].isFinite, vb[i].isFinite else { return .infinity }
                m = max(m, abs(va[i] - vb[i]))
            }
        }
        return m
    }

    /// 合成一张最小确定性 RGBA 图（仅供「默认关不采样」路径使用，不会进推理）。
    private static func makeTinyImage() -> CGImage? {
        let w = 4, h = 4, bpr = w * 4
        var data = [UInt8](repeating: 128, count: bpr * h)
        for i in stride(from: 3, to: data.count, by: 4) { data[i] = 255 }  // alpha
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bpr, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// ============================================================================
// MARK: - 自检专用固定策略（只提供固定 logits/value，updatePPO 空操作）
// ============================================================================

/// 语义自检用：与训练算法无关，只让 OnlineTrainer 能跑 collect/flush 语义。
/// 空更新是为了 isolate「collect 存了什么 / 接管怎么归因」，不掺入策略学习噪声。
private struct SelftestFixedPolicy: PolicyUpdatable {
    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float) {
        ([0, 0, 0], [0, 0, 0], 0)
    }
    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        (0, 0, 0, 0)
    }
    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics {
        PPOMetrics()
    }
}
