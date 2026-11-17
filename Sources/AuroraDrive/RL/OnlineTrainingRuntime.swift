// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainingRuntime.swift — 在线训练运行时（把 PolicyHead/OnlineTrainer
//  真正接到驾驶回路的抓屏帧流上）
//
//  【它解决什么】
//    任务链路里 PolicyHead（可训练策略头）+ OnlineTrainer（采集/GAE/PPO 循环）
//    早已做完并自检全过，但**没有任何生产代码喂真实帧**——等于空转。本文件把
//    两者接到 `DriveState.tick` 的真实抓屏帧（currentFrameCG）上，由一个独立
//    「训练」按钮开关驱动，每帧：
//      ① StateTokenAccelerator 用当前帧的 hi/lo 窗口算 state_token[256]
//      ② OnlineTrainer.sampleAction 采样动作（只做策略计算，**不注入按键**）
//      ③ OnlineTrainer.collect 记录一条 transition（奖励/接管/终止由它内部处理）
//    持续积累、按 trainEvery / episode 边界在后台队列做 PPO 更新。
//
//  【安全边界（为什么默认不影响真实驾驶）】
//    · 本运行时**只读帧 + 只做策略计算**，绝不 touch 任何按键注入路径
//      （controlEngine 一行都不碰）——所以开着它在跑，也不会替你打游戏。
//    · 真要「边开边训」，用户仍需另外打开「自动驾驶」开关；此时本运行时用的是
//      同一份 V3 帧流，训练与驾驶互不干扰（训练读帧、驾驶注入键）。
//    × 但两者都吃 ANE：StateTokenAccelerator 与 V3 主推理是**两个模型**。为不
//      把主驾 p95 抬上去，训练采样默认**降频**（每 N 帧一次，可配），且状态计算
//      放在后台队列，主线程只做「取帧窗口 + 投递」，不阻塞 tick。
//
//  【为什么单独一个文件、不动 DriveState 的大段逻辑】
//    本仓纪律：最小侵入。DriveState 里只加属性 `trainingRuntime` 与 tick 尾部的
//    单个调用 + startRuntime/stopRuntime 两个入口 + 按钮，其余全收敛在本文件。
// ============================================================================

import Foundation
import CoreGraphics

/// 在线训练运行时控制器（@MainActor：只在 tick / 按钮这些主线程上下文调用）。
@MainActor
final class OnlineTrainingRuntime {

    // MARK: 可调参数

    /// 每多少帧算一次 state_token 采样（降频，减小对主推理的抢占）。默认 3 帧一次 ≈ 5Hz。
    private let sampleEveryNFrames: Int
    /// OnlineTrainer 的 PPO 配置（训练超参）。
    private let ppoConfig: PPOConfig

    // MARK: 依赖与状态

    private let accelerator: StateTokenAccelerator
    private var trainer: OnlineTrainer?
    /// 上一次实际采样时执行的动作（写进 vehicle_state，训练口径；首帧用 NONE=1）。
    private var prevHorizontalClass: Int = 1
    private var frameCounter: Int = 0
    private var isRunning = false

    // 诊断计数（供 UI / 日志）
    private(set) var sampledFrames: Int = 0
    private(set) var skippedFrames: Int = 0     // 加速器不可用/推理失败被跳过的帧数
    private(set) var lastError: String?

    init(sampleEveryNFrames: Int = 3,
         ppoConfig: PPOConfig = {
             var c = PPOConfig()
             c.lr = 3e-4          // 在线微调用小学习率，避免把预训练头打飞
             c.epochs = 2
             c.batch = 16
             c.vfCoef = 0.5
             c.entCoef = 0.005
             return c
         }()) {
        self.sampleEveryNFrames = max(1, sampleEveryNFrames)
        self.ppoConfig = ppoConfig
        self.accelerator = StateTokenAccelerator()
    }

    /// 训练是否在跑（UI 按钮状态 / tick 门控）。
    var running: Bool { isRunning }

    /// 当前策略头是否真的就绪（加速器模型加载成功）。用于 UI 如实显示与按钮决策。
    var acceleratorReady: Bool { accelerator.isReady }

    // MARK: 启停

    /// 启动：加载 state_token 加速器 + 初始化 OnlineTrainer（随机初始化策略头）。
    /// - Returns: 是否成功（加速器模型缺失时返回 false，并由 lastError 说明）。
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard accelerator.loadIfNeeded() else {
            lastError = "state_token 加速器不可用：" + (accelerator.failureReason ?? "模型未就绪")
            return false
        }
        // 优先用 A 域从真 checkpoint 导出的输出头初始权重（swift_head_init.json）初始化，
        // 这样策略头从「已训好的 V3 决策头」起步（BC 预热效果），而非纯随机。
        // 找不到/解析失败则回退随机初始化（如实记录，不崩）。
        let head: PolicyHead
        if let initURL = Self.locateHeadInitJSON(),
           let loaded = try? PolicyHead(fromJSON: initURL) {
            head = loaded
            lastError = nil
            print("[OnlineTrain] 策略头从 \(initURL.path) 初始化（真 checkpoint 输出头）")
        } else {
            head = PolicyHead(randomSeed: 0x5EED_2026)
            print("[OnlineTrain] 未找到 swift_head_init.json，策略头用随机初始化（seed="
                  + "0x5EED2026）")
        }
        let t = OnlineTrainer(policy: head,
                              ppoConfig: ppoConfig,
                              trainEvery: 64)
        trainer = t
        frameCounter = 0
        sampledFrames = 0
        skippedFrames = 0
        prevHorizontalClass = 1
        lastError = nil
        isRunning = true
        return true
    }

    /// 停止：把当前在线 episode 收尾（标记无效→丢弃无后继末条，安全），并等后台
    /// 训练队列跑空，保证不停在半次更新上。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        trainer?.markInvalid()          // 封口当前轨迹，不伪造 transition
        trainer?.drainTrainingAndWait() // 阻塞到已排队的训练跑完
    }

    // MARK: 每帧驱动（主线程 tick 调用）

    /// 本帧观测信号（真实驾驶信号，用于奖励计算；都由 tick 侧从 DriveState 现成字段传来）。
    struct FrameSignals {
        var speedKmh: Double
        var speedValid: Bool
        var tookOver: Bool
        var collision: Bool
        var laneOffset: Double
        var manualStop: Bool     // 本帧是否处于人工介入/危险（作为 episode 硬终止边界）
    }

    /// 用「本帧画面」驱动一次训练采样。调用方保证 cg 是本帧鲜活画面。
    /// 内部按 sampleEveryNFrames 降频；state_token 计算与采样在主线程（CoreML
    /// 推理较快，且必须与帧同序），PPO 训练在 OnlineTrainer 的后台队列。
    func onFrame(_ cg: CGImage, signals: FrameSignals) {
        guard isRunning, let trainer else { return }
        frameCounter &+= 1
        guard frameCounter % sampleEveryNFrames == 0 else { return }

        // 接管/人工介入帧：不让 RL 参与采样，封口当前轨迹（安全优先，交还既有降级链）。
        if signals.tookOver || signals.manualStop {
            trainer.markInvalid()
            return
        }

        // ① 渲染 hi/lo 两路归一化输入（与 V3 生产同源）并压入本地环形窗口。
        guard let hi = InferenceEngineV3.renderNormalized(
                  cg, height: V3InputContract.hiHeight, width: V3InputContract.hiWidth),
              let lo = InferenceEngineV3.renderNormalized(
                  cg, height: V3InputContract.loHeight, width: V3InputContract.loWidth) else {
            skippedFrames += 1
            return
        }
        // 单帧钳位填充窗口（训练起步阶段窗口未满也能出 state_token）。
        ring.push(hi: hi, lo: lo)

        // ② 算 state_token（加速器）；不可用则跳过本帧（如实计数，不伪造）。
        guard let out = accelerator.stateTokenAndLogits(
                  hi: ring.hiWindow(), lo: ring.loWindow(),
                  prevHorizontalClass: prevHorizontalClass) else {
            skippedFrames += 1
            lastError = accelerator.failureReason
            return
        }
        let stateToken = out.stateToken
        guard stateToken.count == PolicyHead.stateDimension,
              stateToken.allSatisfy({ $0.isFinite }) else {
            skippedFrames += 1
            return
        }

        // ③ 采样动作（只做策略计算，不注入按键）。
        let sample = trainer.sampleAction(stateToken: stateToken)
        prevHorizontalClass = sample.hClass

        // ④ 记录 transition：用**真实**速度/接管/碰撞信号（tick 侧传入）。
        //    接管帧已在上面封口返回；这里速度无效时 reward.py 语义下 speed/decel 项自然为 0。
        var isTerminal = false
        // 每 240 个采样帧切一个 episode 边界（≈48s@5Hz），让 GAE 有自然分段；属训练口径而非伪造奖励。
        if sampledFrames > 0 && sampledFrames % 240 == 0 { isTerminal = true }

        _ = trainer.collect(stateToken: stateToken,
                            sample: sample,
                            tookOver: signals.tookOver,
                            speedKmh: signals.speedKmh,
                            speedValid: signals.speedValid,
                            collision: signals.collision,
                            laneOffset: signals.laneOffset,
                            isTerminal: isTerminal)
        sampledFrames += 1
    }

    /// 本地帧窗口（24 帧 hi/lo 环形缓冲，与 V3 同构；仅训练用，独立于主推理窗口）。
    private var ring = V3FrameRingBuffer()

    // MARK: 指标读出（UI 显示用）

    /// 最近一次训练指标摘要（一行文本）。没有训练过返回 nil。
    func metricsSummary() -> String? {
        guard let m = trainer?.recentMetrics.last else { return nil }
        return String(format: "更新#%d  policy=%.4f value=%.4f ent=%.4f",
                      m.updateIndex, m.policyLoss, m.valueLoss, m.entropy)
    }

    /// 已完成 episode 的平均回报（OnlineTrainer 提供）。
    var meanEpisodeReward: Double? { trainer?.meanEpisodeReward }

    /// 采样/跳过帧计数（诊断用一行文本）。
    func stats() -> String {
        "采样帧=\(sampledFrames) 跳过=\(skippedFrames)"
    }

    /// 定位 A 域导出的输出头初始权重 JSON（tools/v3_rl/swift_head_init.json）。
    /// 允许用环境变量 AURORA_RL_HEAD_INIT 覆盖；找不到返回 nil（回退随机初始化）。
    static func locateHeadInitJSON() -> URL? {
        if let env = ProcessInfo.processInfo.environment["AURORA_RL_HEAD_INIT"], !env.isEmpty {
            let u = URL(fileURLWithPath: env)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        let u = AuroraPaths.projectRoot()
            .appendingPathComponent("tools")
            .appendingPathComponent("v3_rl")
            .appendingPathComponent("swift_head_init.json")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
