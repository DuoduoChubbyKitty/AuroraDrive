// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainingRuntimeSelfTest.swift — 在线训练运行时自检
//  （-rl-shell-runtime-selftest）
//
//  【为什么单独一个自检】
//    OnlineTrainingRuntime 的关键契约（不阻塞主线程 / 接管先封口先于降频 /
//    ring 复位 / 信号透传 / 丢旧保新 / 动作执行链 / 接管负分归因 / 存盘续训）
//    需要可执行证据。-rl-train-wire-selftest 验「真推理链路」，本自检验
//    「运行时自身的行为契约」——互补，不重复。
//
//  【为什么用假 state_token 源而不是真 CoreML】
//    本自检验的是运行时逻辑，不是推理正确性；假源纯内存合成，不加载模型、
//    不做真推理、不真开游戏。其中「闸门源」可人为卡住消费线程——验证
//    「主线程不被阻塞」与「丢旧保新」的关键手段（真 CoreML 无法可控卡住）。
//
//  【断言纪律】全部断言真实有效，无恒真：
//    · ①-⑤ 段：时序断言用「同步屏障 + 精确计数」或「调度无关不变式」
//      （tokens + dropped == 总推送数）。
//    · ⑥ #5 执行链：记录型假执行方（线程安全）逐次比对调用参数；
//    · ⑦ #6 接管归因：开 OnlineTrainer 批次捕获，断言接管批末条 reward
//      恰比前一条低 takeover(10.0)、isTerminal=true、训练指标非空；
//    · ⑧ #7 存盘：临时文件隔离，70 帧真 PPO 更新 → 权重确实变 → stop 落盘
//      → 逐张量读回一致 → 新 runtime start 续读到相同权重。
//    · ⑨ B5：闸门卡死消费线程时 stop 仍立即送达 releaseAll（独立 actionQueue，
//      不等排空）、stop 如实返回 drained/headSaved、放行后旧帧动作作废；
//    · ⑩ B6：clearActionExecutor 后采样继续但 executor 零新调用、清理时
//      执行方收到最终 releaseAll、重启+重注入后发布恢复。
//    · ⑪ #6 digest 统一核算：userDigest=true 时即使 liveAllowed 执行 digest
//      也为 true（绝不在用户 digest 开时真注入）；三源全关才 live；
//    · ⑫ B5 遗留：超时路径 lastStopReport 如实快照（drained/headSaved/
//      keysReleased）、start() 清空报告、干净停止三元组全 true。
//    · 所有 runtime 构造都传 headCheckpointURL: nil（⑧ 之外），绝不动
//      用户真实存盘；⑧ 用临时文件 + defer 清理。
// ============================================================================
import Foundation
import CoreGraphics

enum OnlineTrainingRuntimeSelfTest {

    // MARK: - 测试替身

    /// 手动闸门：close 后消费线程在 stateToken 内阻塞，open 放行。
    private final class Gate {
        private let cond = NSCondition()
        private var isOpen = true
        func close() {
            cond.lock(); isOpen = false; cond.unlock()
        }
        func open() {
            cond.lock(); isOpen = true; cond.broadcast(); cond.unlock()
        }
        func waitOpen() {
            cond.lock()
            while !isOpen { cond.wait() }
            cond.unlock()
        }
    }

    /// 假 state_token 源：纯内存合成（不加载真模型）；token 值由调用序号
    /// 确定性生成。挂上闸门即可人为卡住消费线程（测试不阻塞/丢旧用）。
    private final class FakeStateTokenSource: StateTokenSource {
        var failureReason: String?
        private let gate: Gate?
        /// stateToken 调用次数（消费完成的帧数；未挂闸门时即处理帧数）。
        private(set) var tokenCount = 0

        init(gate: Gate? = nil) { self.gate = gate }

        func stateToken(hi: [Float16], lo: [Float16],
                        prevHorizontalClass: Int) -> [Float]? {
            gate?.waitOpen()
            tokenCount += 1
            // 确定性合成 token（count 做种子——不同帧不同值，驱动采样/collect）。
            var t = [Float](repeating: 0, count: PolicyHead.stateDimension)
            for i in t.indices { t[i] = Float((tokenCount &+ i) % 97) / 100.0 }
            return t
        }
    }

    /// #5 记录型假执行方：线程安全地记录每次 (action, digest) 调用对
    /// （生产实现在 ShellModeController 侧；这里只需证明契约：参数无损、
    /// digest 标志正确、接管收撤销哨兵）。
    private final class RecordingExecutor {
        struct Call { let v: Int, h: Int, digest: Bool }
        private let lk = NSLock()
        private var calls: [Call] = []
        func record(_ action: RLAction, _ digest: Bool) {
            lk.lock(); calls.append(Call(v: action.vClass, h: action.hClass, digest: digest)); lk.unlock()
        }
        var snapshot: [Call] {
            lk.lock(); defer { lk.unlock() }
            return calls
        }
    }

    /// 合成帧（wire selftest 同款确定性渐变图；尺寸随意——假源不关心内容，
    /// 真实 renderNormalized 仍会跑，这是链路的一部分）。
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                data[i]     = UInt8((x * 255) / max(1, width - 1))
                data[i + 1] = UInt8((y * 255) / max(1, height - 1))
                data[i + 2] = UInt8(((x ^ y) & 0xFF))
                data[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private static func signals(speedKmh: Double = 40,
                                tookOver: Bool = false,
                                manualStop: Bool = false) -> OnlineTrainingRuntime.FrameSignals {
        .init(speedKmh: speedKmh, speedValid: true, tookOver: tookOver,
              collision: false, laneOffset: 0, manualStop: manualStop)
    }

    /// 推一帧并等消费完成（同步屏障，10s 硬超时——与 runtime 约定一致，绝不无限等）。
    /// B1 后 executor 调用走独立串行 actionQueue：帧管线排空后还要等动作队列排空，
    /// 否则 recorder 读数是竞态断言。
    /// 返回 false = 管线卡死（调用方按失败计）。
    @MainActor
    private static func pushAndDrain(_ rt: OnlineTrainingRuntime, _ cg: CGImage,
                                     _ sig: OnlineTrainingRuntime.FrameSignals) -> Bool {
        rt.onFrame(cg, signals: sig)
        let drained = rt.waitForPipelineIdle(timeout: 10)
        rt.waitForActionDispatchIdle()
        return drained
    }

    /// 两组张量逐元素一致（容差 1e-12；JSON roundtrip 理论无损，容差兜底）。
    private static func sameTensor(_ a: [Double]?, _ b: [Double]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 1e-12 }
    }

    /// 两个策略头的全部 10 组张量一致（trunk×2/vertical/horizontal/value 的 W+b）。
    private static func headsEqual(_ a: PolicyHead?, _ b: PolicyHead?) -> Bool {
        guard let a, let b else { return false }
        return sameTensor(a.trunk0.weight, b.trunk0.weight)
            && sameTensor(a.trunk0.bias, b.trunk0.bias)
            && sameTensor(a.trunk1.weight, b.trunk1.weight)
            && sameTensor(a.trunk1.bias, b.trunk1.bias)
            && sameTensor(a.vertical.weight, b.vertical.weight)
            && sameTensor(a.vertical.bias, b.vertical.bias)
            && sameTensor(a.horizontal.weight, b.horizontal.weight)
            && sameTensor(a.horizontal.bias, b.horizontal.bias)
            && sameTensor(a.valueLayer.weight, b.valueLayer.weight)
            && sameTensor(a.valueLayer.bias, b.valueLayer.bias)
    }

    // MARK: - 入口

    /// 入口（由启动器分发 `-rl-shell-runtime-selftest` 时调用）。返回失败项数，0 = 全过。
    @MainActor
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 在线训练运行时自检（-rl-shell-runtime-selftest）═══")
        print("  （假 state_token 源：纯内存合成，不加载模型、不做真推理、不真开游戏）")

        guard let base = makeTestImage(width: 96, height: 64) else {
            print("  ✗ 测试帧构造失败")
            print("═══ 结果：有失败 ❌（1 项失败）═══")
            return 1
        }

        // ── ① 主线程 onFrame 立即返回（不被渲染/推理阻塞）+ ⑤ 丢旧保新 ──
        // 闸门关闭 → 消费线程卡在 stateToken 里；此时主线程连塞 200 帧，
        // 全部只做入槽/覆盖（微秒级）。若 onFrame 同步做渲染+推理，
        // 200 帧（每帧两次 384×224/192×112 渲染 + token + 采样 + collect）
        // 耗时必然远超阈值。
        print("  ── ① onFrame 不阻塞主线程 + ⑤ 有界单槽丢旧保新 ──")
        let gate = Gate()
        let gatedSource = FakeStateTokenSource(gate: gate)
        let rt1 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: gatedSource)
        check("假源模式启动成功（不加载 CoreML）", rt1.start(), rt1.lastError ?? "")
        gate.close()
        let burstCount = 200
        let t0 = Date()
        for i in 1...burstCount {
            // 每帧速度不同：最后处理的帧必为最新帧（speed=200）可被验证。
            rt1.onFrame(base, signals: signals(speedKmh: Double(i)))
        }
        let burstMs = Date().timeIntervalSince(t0) * 1000
        let perFrameMs = burstMs / Double(burstCount)
        check("① 消费线程被卡死时，\(burstCount) 帧入槽仅 \(String(format: "%.1f", burstMs))ms"
              + "（均 \(String(format: "%.3f", perFrameMs))ms/帧 < 1ms，主线程未被阻塞）",
              burstMs.isFinite && perFrameMs < 1.0,
              "总 \(String(format: "%.1f", burstMs))ms，均 \(String(format: "%.3f", perFrameMs))ms/帧")
        // 放行闸门：消费线程完成被卡帧 + 处理槽内最新帧。
        gate.open()
        check("① 放行后管线 10s 内排空", rt1.waitForPipelineIdle(timeout: 10),
              rt1.lastError ?? "")
        // 调度无关不变式：每帧要么被处理（token）要么被丢（dropped），
        // 二者之和恒等于推送数；丢旧保新 → 丢掉绝大多数。
        let tokens1 = gatedSource.tokenCount
        let dropped1 = rt1.droppedFrames
        check("⑤ 丢旧保新不变式：tokens(\(tokens1)) + dropped(\(dropped1)) == 推送数(\(burstCount))",
              tokens1 + dropped1 == burstCount,
              "tokens=\(tokens1) dropped=\(dropped1)")
        check("⑤ 消费卡顿期绝大多数帧被丢（dropped ≥ \(burstCount - 2)，未排队积压）",
              dropped1 >= burstCount - 2,
              "dropped=\(dropped1)")
        check("⑤ 最后处理的帧是最新帧（消费到 speed=\(burstCount) 那帧，非更早帧）",
              rt1.lastFrameSignals?.speedKmh == Double(burstCount),
              "lastSignals.speed=\(rt1.lastFrameSignals?.speedKmh.description ?? "nil")")
        rt1.stop()
        check("① 停止后 running == false", !rt1.running)

        // ── ② 接管/人工介入：先封口不采样（判定先于降频）────────────────
        print("  ── ② 接管先封口（判定先于每 N 帧降频）──")
        let rt2 = OnlineTrainingRuntime(sampleEveryNFrames: 3,   // 降频 3
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        check("② 运行时启动成功", rt2.start(), rt2.lastError ?? "")
        // 帧计数 1（1%3≠0，非采样位）：正常帧入窗不采样。
        check("② 前置帧消费完成", pushAndDrain(rt2, base, signals(speedKmh: 30)))
        let source2 = rt2.lastFrameSignals
        check("② 前置帧不采样（sampledFrames == 0）", rt2.sampledFrames == 0,
              "sampledFrames=\(rt2.sampledFrames)")
        // 帧计数 2（2%3≠0）：旧实现先判 %N 会直接 return、吞掉这次接管；
        // 新实现先判接管 → 封口。
        check("② 接管帧（非采样位）消费完成", pushAndDrain(rt2, base, signals(tookOver: true)))
        check("② 非采样位的接管帧也封口（episodeSealCount ≥ 1）",
              rt2.episodeSealCount >= 1, "episodeSealCount=\(rt2.episodeSealCount)")
        check("② 接管帧不采样（sampledFrames 仍为 0）", rt2.sampledFrames == 0,
              "sampledFrames=\(rt2.sampledFrames)")
        check("② 接管封口后窗口复位（trainingWindowFilled == 0）",
              rt2.trainingWindowFilled == 0,
              "trainingWindowFilled=\(rt2.trainingWindowFilled)")
        // 帧计数 3（3%3==0，采样位）：接管后恢复正常采样。
        check("② 恢复帧消费完成", pushAndDrain(rt2, base, signals(speedKmh: 40)))
        check("② 接管后恢复采样（sampledFrames == 1）", rt2.sampledFrames == 1,
              "sampledFrames=\(rt2.sampledFrames)")
        // manualStop 与 tookOver 同为封口判定（帧计数 4，非采样位）。
        check("② manualStop 帧消费完成", pushAndDrain(rt2, base, signals(manualStop: true)))
        check("② 非采样位的 manualStop 帧也封口（sealCount 再增，不采样）",
              rt2.episodeSealCount >= 2 && rt2.sampledFrames == 1,
              "episodeSealCount=\(rt2.episodeSealCount) sampledFrames=\(rt2.sampledFrames)")
        check("② 前置帧信号透传（消费端收到 speed=30）",
              source2?.speedKmh == 30 && source2?.tookOver == false,
              "speed=\(source2?.speedKmh.description ?? "nil")")
        rt2.stop()

        // ── ③ ring 在 start/stop 复位 ──────────────────────────────
        print("  ── ③ 训练窗口在 start/stop 复位 ──")
        let rt3 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        check("③ 运行时启动成功", rt3.start(), rt3.lastError ?? "")
        for _ in 0..<10 {
            if !pushAndDrain(rt3, base, signals()) {
                check("③ 逐帧消费完成", false, "waitForPipelineIdle 超时")
                break
            }
        }
        check("③ 10 帧后窗口推进（trainingWindowFilled == 10）",
              rt3.trainingWindowFilled == 10,
              "trainingWindowFilled=\(rt3.trainingWindowFilled)")
        check("③ 每帧都采样（sampledFrames == 10）", rt3.sampledFrames == 10,
              "sampledFrames=\(rt3.sampledFrames)")
        rt3.stop()
        check("③ stop 后窗口复位（trainingWindowFilled == 0）",
              rt3.trainingWindowFilled == 0,
              "trainingWindowFilled=\(rt3.trainingWindowFilled)")
        check("③ stop 后 running == false", !rt3.running)
        // stop 后帧不再入槽：既不采样也不丢帧。
        rt3.onFrame(base, signals: signals())
        check("③ stop 后 onFrame 无效果（sampledFrames 仍为 10，无新增）",
              rt3.sampledFrames == 10 && rt3.droppedFrames == 0,
              "sampledFrames=\(rt3.sampledFrames) dropped=\(rt3.droppedFrames)")
        // 重启：新会话从零开始（不跨场景拼帧）。
        check("③ 重启成功", rt3.start(), rt3.lastError ?? "")
        check("③ 重启后计数与窗口复位（sampledFrames == 0 且 trainingWindowFilled == 0）",
              rt3.sampledFrames == 0 && rt3.trainingWindowFilled == 0,
              "sampledFrames=\(rt3.sampledFrames) trainingWindowFilled=\(rt3.trainingWindowFilled)")
        rt3.stop()

        // ── ④ 信号透传正确（六字段全链路不丢语义）────────────────────
        print("  ── ④ 信号透传 ──")
        let rt4 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        check("④ 运行时启动成功", rt4.start(), rt4.lastError ?? "")
        let probe = OnlineTrainingRuntime.FrameSignals(
            speedKmh: 87.5, speedValid: false, tookOver: false,
            collision: true, laneOffset: -2.25, manualStop: false)
        check("④ 探针帧消费完成", pushAndDrain(rt4, base, probe))
        let seen = rt4.lastFrameSignals
        check("④ 消费端收到的六字段与本帧一致（speed/valid/tookOver/collision/lane/manualStop）",
              seen?.speedKmh == 87.5 && seen?.speedValid == false
              && seen?.tookOver == false && seen?.collision == true
              && seen?.laneOffset == -2.25 && seen?.manualStop == false,
              "seen=\(seen.map { "speed=\($0.speedKmh),valid=\($0.speedValid),take=\($0.tookOver),col=\($0.collision),lane=\($0.laneOffset),stop=\($0.manualStop)" } ?? "nil")")
        check("④ 探针帧完成采样（信号进入 collect/奖励路径）",
              rt4.sampledFrames == 1,
              "sampledFrames=\(rt4.sampledFrames)")
        rt4.stop()

        // ── ⑥ #5 动作执行链：采样动作经 executor 发布、digest 隔离、接管撤销 ──
        print("  ── ⑥ #5 动作执行链（采样后发布 / digest 标志 / 接管撤销）──")
        let rt5 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        let recorder = RecordingExecutor()
        rt5.actionExecutor = { recorder.record($0, $1) }
        check("⑥ 运行时启动成功", rt5.start(), rt5.lastError ?? "")
        check("⑥ 默认 digestMode == true（digest 只算不真按）", rt5.digestMode == true)
        for _ in 0..<20 { _ = pushAndDrain(rt5, base, signals()) }
        let calls6 = recorder.snapshot
        check("⑥ 每个采样帧都发布动作（20 帧 20 次 executor 调用）",
              calls6.count == 20 && rt5.sampledFrames == 20,
              "calls=\(calls6.count) sampled=\(rt5.sampledFrames)")
        check("⑥ 发布动作参数合法（全部 v/h ∈ [0,2]，与采样动作空间一致）",
              calls6.allSatisfy { (0...2).contains($0.v) && (0...2).contains($0.h) },
              "异常=\(calls6.filter { !(0...2).contains($0.v) || !(0...2).contains($0.h) }.count)")
        let last6 = calls6.last
        check("⑥ 发布参数无损（executor 收到的末次动作 == runtime.lastDispatchedAction）",
              last6 != nil && rt5.lastDispatchedAction != nil
              && last6!.v == rt5.lastDispatchedAction!.vClass
              && last6!.h == rt5.lastDispatchedAction!.hClass,
              "executor=(v=\(last6?.v.description ?? "nil"),h=\(last6?.h.description ?? "nil")) "
              + "runtime=(v=\(rt5.lastDispatchedAction?.vClass.description ?? "nil"),h=\(rt5.lastDispatchedAction?.hClass.description ?? "nil"))")
        check("⑥ digest 模式下全部调用带 digest=true（执行方不得真注入按键）",
              calls6.allSatisfy { $0.digest },
              "digest=false 次数=\(calls6.filter { !$0.digest }.count)")
        // live 模式（digestMode=false）：digest 标志必须随之翻转。
        // #6 统一核算后 live 需三源全关：基线关 + 用户 provider 关（nil）+ live 许可开
        //（许可默认读 env 未设=false 会强制 digest，须显式开）。
        rt5.digestMode = false
        rt5.liveActuationAllowed = true
        _ = pushAndDrain(rt5, base, signals())
        let callsLive = recorder.snapshot
        check("⑥ digestMode=false 后新调用带 digest=false（标志真透传）",
              callsLive.last?.digest == false,
              "last.digest=\(callsLive.last?.digest.description ?? "nil")")
        rt5.digestMode = true
        // 接管：执行方必须收到撤销哨兵（-1,-1），且不再有新动作。
        check("⑥ 接管帧消费完成", pushAndDrain(rt5, base, signals(tookOver: true)))
        let callsAfterTakeover = recorder.snapshot
        check("⑥ 接管时执行方收到撤销哨兵（v=-1,h=-1，撤销在途动作）",
              callsAfterTakeover.last?.v == -1 && callsAfterTakeover.last?.h == -1,
              "last=(v=\(callsAfterTakeover.last?.v.description ?? "nil"),h=\(callsAfterTakeover.last?.h.description ?? "nil"))")
        check("⑥ 接管后无新采样动作发布（调用总数不变，仍是 20+1+1）",
              callsAfterTakeover.count == 22,
              "calls=\(callsAfterTakeover.count)")
        check("⑥ 撤销哨兵不污染 lastDispatchedAction（仍为最后一次采样动作）",
              rt5.lastDispatchedAction != nil && rt5.lastDispatchedAction!.vClass >= 0,
              "v=\(rt5.lastDispatchedAction?.vClass.description ?? "nil")")
        rt5.stop()
        // stop 也撤销在途动作（防卡键）——releaseAll 走独立 actionQueue，先等它送达。
        rt5.waitForActionDispatchIdle()
        let callsAfterStop = recorder.snapshot
        check("⑥ stop 时执行方也收到撤销哨兵", 
              callsAfterStop.last?.v == -1 && callsAfterStop.last?.h == -1,
              "last=(v=\(callsAfterStop.last?.v.description ?? "nil"),h=\(callsAfterStop.last?.h.description ?? "nil"))")

        // ── ⑦ #6 接管负分归因：上一 AI 帧扣 -takeover + 真实终止 ──────
        print("  ── ⑦ #6 接管负分归因（上一 AI 帧 -takeover + isTerminal）──")
        let rt6 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        check("⑦ 运行时启动成功", rt6.start(), rt6.lastError ?? "")
        rt6.trainerForTest()?.setCaptureBatchesForTest(true)
        // 20 个正常帧（全部采样，20 < trainEvery=64 → 不触发缓冲截断，
        // pendingTransitions 恰好 20 条、逐条 reward 相同——恒定信号）。
        for _ in 0..<20 { _ = pushAndDrain(rt6, base, signals()) }
        check("⑦ 前置 20 帧全部采样（pending 恰 20 条）", rt6.sampledFrames == 20,
              "sampledFrames=\(rt6.sampledFrames)")
        // 接管帧：走 collect(tookOver:true) → 上一 AI 帧扣 -10 + isTerminal
        // + flushTerminated 整批训练（惩罚进 actor 梯度）。
        check("⑦ 接管帧消费完成", pushAndDrain(rt6, base, signals(tookOver: true)))
        rt6.trainerForTest()?.drainTrainingAndWait()
        let batches7 = rt6.trainerForTest()?.capturedBatchesForTestSnapshot() ?? []
        check("⑦ 接管触发了真实训练（批次被捕获，非静默丢弃）",
              !batches7.isEmpty, "batches=\(batches7.count)")
        if let batch = batches7.last {
            check("⑦ 训练批含全部 20 条 AI transition",
                  batch.count == 20, "batch.count=\(batch.count)")
            let lastReward = batch[batch.count - 1].reward
            let prevReward = batch[batch.count - 2].reward
            let diff = lastReward - prevReward
            check("⑦ 上一 AI 帧被扣 -takeover（末条 reward 比前一条恰低 10.0）",
                  abs(diff - (-10.0)) < 1e-9,
                  "diff=\(diff)（last=\(lastReward) prev=\(prevReward)）")
            check("⑦ 末条 isTerminal == true（真实终止语义，非 UNKNOWN 封口）",
                  batch[batch.count - 1].isTerminal)
            check("⑦ 倒数第二条 isTerminal == false（惩罚只归因末条）",
                  !batch[batch.count - 2].isTerminal)
        } else {
            check("⑦ 批次捕获非空（可断言末条惩罚）", false, "batches 为空")
        }
        check("⑦ 惩罚进了策略梯度（训练指标已产生）",
              !(rt6.trainerForTest()?.recentMetrics.isEmpty ?? true),
              "metrics=\(rt6.trainerForTest()?.recentMetrics.count ?? 0)")
        rt6.stop()

        // ── ⑧ #7 stop 存盘 / start 续读 ─────────────────────────────
        print("  ── ⑧ #7 策略头存盘续训（训练→stop→落盘→再 start 读回一致）──")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-rl-runtime-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let rt7 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: tmpURL,
                                         stateTokenSource: FakeStateTokenSource())
        check("⑧ 运行时启动成功", rt7.start(), rt7.lastError ?? "")
        let headInitial = rt7.currentHeadForTest()
        check("⑧ 初始策略头可读", headInitial != nil)
        // 70 帧 ≥ trainEvery=64 → 至少一次缓冲截断 PPO 更新，权重确实会变。
        for _ in 0..<70 { _ = pushAndDrain(rt7, base, signals()) }
        rt7.trainerForTest()?.drainTrainingAndWait()
        check("⑧ 存盘前文件不存在（隔离干净）",
              !FileManager.default.fileExists(atPath: tmpURL.path))
        // stop() 内部：markInvalid 封口会再训练一次前缀（真实时间序），之后才
        // 存盘——终态权重必须在 stop() 之后捕获，才能与盘上内容一致。
        rt7.stop()
        let headTrained = rt7.currentHeadForTest()
        let valueChanged = !sameTensor(headTrained?.valueLayer.weight, headInitial?.valueLayer.weight)
        let trunkChanged = !sameTensor(headTrained?.trunk0.weight, headInitial?.trunk0.weight)
        // Array.first 是 Double?，插值先解包再转字符串。
        let initValueFirst = headInitial?.valueLayer.weight.first.map { "\($0)" } ?? "nil"
        let trainedValueFirst = headTrained?.valueLayer.weight.first.map { "\($0)" } ?? "nil"
        check("⑧ 训练真的改了权重（70 帧 ≥ 64 触发 PPO 更新，value/trunk 任一 ≠ 初始）",
              valueChanged || trunkChanged,
              "valueChanged=\(valueChanged) trunkChanged=\(trunkChanged) "
              + "（value 首元素 init=\(initValueFirst) trained=\(trainedValueFirst)）")
        check("⑧ stop 后存盘文件存在", FileManager.default.fileExists(atPath: tmpURL.path),
              tmpURL.lastPathComponent)
        // 从盘上读回：逐张量与停止前最终权重一致（含 value 头——存盘必须保住它）。
        let reloaded = OnlineTrainingRuntime.loadHead(from: tmpURL)
        check("⑧ 盘上读回与停止前权重逐张量一致（含 value 头）",
              headsEqual(reloaded, headTrained),
              "trunk0=\(sameTensor(reloaded?.trunk0.weight, headTrained?.trunk0.weight)) "
              + "value=\(sameTensor(reloaded?.valueLayer.weight, headTrained?.valueLayer.weight))")
        // 新 runtime 用同一存盘路径 start：必须优先读到存盘权重（而非 swift_head_init.json）。
        let rt8 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: tmpURL,
                                         stateTokenSource: FakeStateTokenSource())
        check("⑧ 续训 runtime 启动成功", rt8.start(), rt8.lastError ?? "")
        check("⑧ 再 start 读回的权重与停止前一致（续训而非从头再来）",
              headsEqual(rt8.currentHeadForTest(), headTrained),
              "trunk0=\(sameTensor(rt8.currentHeadForTest()?.trunk0.weight, headTrained?.trunk0.weight)) "
              + "value=\(sameTensor(rt8.currentHeadForTest()?.valueLayer.weight, headTrained?.valueLayer.weight))")
        rt8.stop()

        // ── ⑨ B5 stop 硬不变量：卡死时立即松键 / 旧帧动作作废 / 如实返回 ──
        print("  ── ⑨ B5 stop 硬不变量（消费线程卡死时 releaseAll 立即送达）──")
        let gate2 = Gate()
        let rtB5 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                          softCutSeconds: 1e9,
                                          drainTimeout: 0.5,   // 卡死路径下 stop 快速超时返回，测试不拖 10s
                                          headCheckpointURL: nil,
                                          stateTokenSource: FakeStateTokenSource(gate: gate2))
        let recB5 = RecordingExecutor()
        rtB5.actionExecutor = { recB5.record($0, $1) }
        check("⑨ 运行时启动成功", rtB5.start(), rtB5.lastError ?? "")
        gate2.close()
        // 消费线程取走本帧后卡死在 stateToken 里（相当于推理中途卡死）。
        rtB5.onFrame(base, signals: signals())
        // stop：帧管线排空必超时，但 releaseAll 必须已送达（走独立 actionQueue）。
        let stopResult = rtB5.stop()
        rtB5.waitForActionDispatchIdle()
        let calls9 = recB5.snapshot
        check("⑨ 消费线程卡死时 stop 仍立即送达 releaseAll（不等排空）",
              calls9.count == 1 && calls9.first?.v == -1 && calls9.first?.h == -1,
              "calls=\(calls9.count) first=(v=\(calls9.first?.v.description ?? "nil"),h=\(calls9.first?.h.description ?? "nil"))")
        check("⑨ stop 如实返回排空失败（drained == false）", stopResult.drained == false,
              "drained=\(stopResult.drained)")
        check("⑨ stop 如实返回未存盘（headSaved == false）", stopResult.headSaved == false,
              "headSaved=\(stopResult.headSaved)")
        // 放行：卡死帧在 stop 之后恢复完成——其采样动作因会话失效必须作废不发布。
        gate2.open()
        _ = rtB5.waitForPipelineIdle(timeout: 10)
        rtB5.waitForActionDispatchIdle()
        let calls9b = recB5.snapshot
        check("⑨ 恢复后的旧帧动作作废（帧完成采样但 executor 无新调用，仍只有 1 次 releaseAll）",
              calls9b.count == 1,
              "calls=\(calls9b.count)（若 >1：stop 后旧帧动作泄漏给了执行方）")

        // ── ⑩ B6 clearActionExecutor：清后零调用 / 最终 releaseAll / 重启恢复 ──
        print("  ── ⑩ B6 executor 清理（清后采样不再调 executor）──")
        let rtB6 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                          softCutSeconds: 1e9,
                                          headCheckpointURL: nil,
                                          stateTokenSource: FakeStateTokenSource())
        let recB6 = RecordingExecutor()
        rtB6.actionExecutor = { recB6.record($0, $1) }
        check("⑩ 运行时启动成功", rtB6.start(), rtB6.lastError ?? "")
        for _ in 0..<3 { _ = pushAndDrain(rtB6, base, signals()) }
        check("⑩ 前置 3 帧发布 3 次动作", recB6.snapshot.count == 3,
              "calls=\(recB6.snapshot.count)")
        // Controller 语义（B6）：退出壳模式/训练启动失败时撤销执行方。
        rtB6.clearActionExecutor()
        rtB6.waitForActionDispatchIdle()
        let calls10 = recB6.snapshot
        check("⑩ 清理时执行方收到最终 releaseAll（第 4 次调用为撤销哨兵）",
              calls10.count == 4 && calls10.last?.v == -1 && calls10.last?.h == -1,
              "calls=\(calls10.count) last=(v=\(calls10.last?.v.description ?? "nil"),h=\(calls10.last?.h.description ?? "nil"))")
        // 训练仍在跑（clearActionExecutor 不停训练）：采样/collect 继续，但不发布动作。
        let sampledBefore10 = rtB6.sampledFrames
        for _ in 0..<5 { _ = pushAndDrain(rtB6, base, signals()) }
        check("⑩ 清理后训练继续（采样 +5，collect 未断）",
              rtB6.sampledFrames == sampledBefore10 + 5,
              "sampled=\(rtB6.sampledFrames)（before=\(sampledBefore10)）")
        check("⑩ 清理后采样不再调 executor（调用数不变，仍为 4）",
              recB6.snapshot.count == 4,
              "calls=\(recB6.snapshot.count)（若 >4：清理后动作泄漏给了执行方）")
        // 重启语义：重新注入 executor + start 激活新会话 → 发布恢复。
        rtB6.stop()
        rtB6.actionExecutor = { recB6.record($0, $1) }
        check("⑩ 重启成功", rtB6.start(), rtB6.lastError ?? "")
        for _ in 0..<2 { _ = pushAndDrain(rtB6, base, signals()) }
        let calls10b = recB6.snapshot
        check("⑩ 重启后新会话恢复发布（+2 次合法采样动作，v/h ∈ [0,2]）",
              calls10b.count == 6
              && calls10b.dropFirst(4).allSatisfy { (0...2).contains($0.v) && (0...2).contains($0.h) },
              "calls=\(calls10b.count)")

        // ── ⑪ #6 digest 统一核算：用户 digest 开 → 强制 digest ──────────
        print("  ── ⑪ #6 digest 统一核算（userDigest || !liveAllowed）──")
        let rt11 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        let rec11 = RecordingExecutor()
        rt11.actionExecutor = { rec11.record($0, $1) }
        check("⑪ 运行时启动成功", rt11.start(), rt11.lastError ?? "")
        // 情形 A（核心安全断言）：用户开了 digest（provider=true），
        // 即使 liveAllowed=true、运行时基线 digestMode=false，
        // 执行方收到的也必须是 digest=true（绝不能真注入）。
        rt11.digestMode = false
        rt11.liveActuationAllowed = true
        rt11.userDigestProvider = { true }
        check("⑪A 用户 digest 开 + live 许可 → 执行 digest=true（不真注入）",
              pushAndDrain(rt11, base, signals()) && rec11.snapshot.last?.digest == true,
              "last.digest=\(rec11.snapshot.last?.digest.description ?? "nil")")
        // 情形 B：三源全关（基线关、用户关、live 许可）→ 唯一 live 路径。
        rt11.userDigestProvider = { false }
        check("⑪B 三源全关 → digest=false（唯一真注入路径）",
              pushAndDrain(rt11, base, signals()) && rec11.snapshot.last?.digest == false,
              "last.digest=\(rec11.snapshot.last?.digest.description ?? "nil")")
        // 情形 C：用户关、基线关，但 live 许可关闭 → 强制 digest。
        rt11.liveActuationAllowed = false
        check("⑪C live 许可关（用户/基线也关）→ 强制 digest=true",
              pushAndDrain(rt11, base, signals()) && rec11.snapshot.last?.digest == true,
              "last.digest=\(rec11.snapshot.last?.digest.description ?? "nil")")
        // 情形 D：运行时基线开（默认）→ 无论用户/许可如何都 digest。
        rt11.digestMode = true
        rt11.liveActuationAllowed = true
        check("⑪D 基线 digestMode 开（用户关+live 许可）→ digest=true",
              pushAndDrain(rt11, base, signals()) && rec11.snapshot.last?.digest == true,
              "last.digest=\(rec11.snapshot.last?.digest.description ?? "nil")")
        rt11.stop()

        // ── ⑫ B5 遗留：lastStopReport 快照 / start 清空 / 干净停止 ──────
        print("  ── ⑫ B5 遗留（stopReport 快照 / start 清空 / 干净停止）──")
        // ⑨ 的 rtB5 停止走的是超时路径：报告必须如实快照 (false, false, keysReleased=true)。
        let report9 = rtB5.lastStopReport
        check("⑫ 超时路径报告如实快照（drained=false headSaved=false）",
              report9?.drained == false && report9?.headSaved == false,
              "report=\(report9.map { "(\($0.drained),\($0.headSaved),\($0.keysReleased))" } ?? "nil")")
        check("⑫ 卡死路径键释放已确认（keysReleased=true：releaseAll 在确认超时内送达）",
              report9?.keysReleased == true,
              "keysReleased=\(report9?.keysReleased.description ?? "nil")")
        // start() 清空：新会话不带着旧会话的停止报告。
        check("⑫ 超时后重启成功（管线已被 ⑨b 放行排空）", rtB5.start(), rtB5.lastError ?? "")
        check("⑫ start() 清空旧停止报告（lastStopReport == nil）",
              rtB5.lastStopReport == nil,
              "report=\(rtB5.lastStopReport.map { "(\($0.drained),\($0.headSaved))" } ?? "nil")")
        rtB5.stop()
        // 干净停止：全部排空 + 存盘（无存盘配置=不适用非失败）→ 三元组全 true。
        let rt12 = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                         softCutSeconds: 1e9,
                                         headCheckpointURL: nil,
                                         stateTokenSource: FakeStateTokenSource())
        check("⑫ 干净停止 runtime 启动成功", rt12.start(), rt12.lastError ?? "")
        for _ in 0..<3 { _ = pushAndDrain(rt12, base, signals()) }
        let r12 = rt12.stop()
        let report12 = rt12.lastStopReport
        check("⑫ 干净停止三元组全 true（drained/headSaved/keysReleased）",
              r12.drained && r12.headSaved
              && report12?.drained == true && report12?.headSaved == true && report12?.keysReleased == true,
              "stop=(\(r12.drained),\(r12.headSaved)) "
              + "report=\(report12.map { "(\($0.drained),\($0.headSaved),\($0.keysReleased))" } ?? "nil")")
        rt12.stop()   // 已停再停：无害（报告重记为全 true）

        print(failures == 0
              ? "═══ 结果：全部通过 ✅（\(failures) 项失败）═══"
              : "═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        return failures
    }
}
