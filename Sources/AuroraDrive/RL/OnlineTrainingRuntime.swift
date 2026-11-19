// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainingRuntime.swift — 在线训练运行时（把 PolicyHead/OnlineTrainer
//  真正接到驾驶回路的抓屏帧流上）
//
//  【它解决什么】
//    PolicyHead（可训练策略头）+ OnlineTrainer（采集/GAE/PPO 循环）早已自检
//    全过，但此前没有任何生产代码喂真实帧、也不发布采样动作。本文件把两者
//    接到 `DriveState.tick` 的真实抓屏帧上。消费端对每个到达帧串行执行：
//      ① renderNormalized 渲染 hi/lo 归一化输入（与 V3 生产同源）
//      ② **每个正常帧**压入本地 24 帧环形窗口（按输入帧率入窗）
//      ③ （采样帧）StateTokenSource 算 state_token[256]
//      ④ OnlineTrainer.sampleAction 采样动作
//      ⑤ **发布采样动作**（#5：经 actionExecutor 闭包交给执行方——不发布动作
//         就不是 on-policy，环境变化必须来自该动作；digest 模式只给
//         ControlEngine 消化、live 模式才真注入按键）
//      ⑥ OnlineTrainer.collect 记录 transition（奖励/接管/终止由它内部处理）
//
//  【线程模型（为什么 onFrame 里绝不做推理）】
//    onFrame 在 tick 里被调用时**正持有 pendingFrameLock**（帧交付临界区）：
//    同步渲染/CoreML 推理会阻塞帧交付、抬高主驾 p95。因此主线程只做
//    「拷贝 cg 引用 + 信号快照 → 放进有界单槽（容量 1，丢旧保新）→ 立即
//    返回」；渲染/推理/采样/发布/collect 全部收敛到内部一条串行后台队列消费。
//    消费不过来时**丢旧保新**：训练要的是最新画面，宁可丢帧也不排队积压。
//    OnlineTrainer 的采集态按其注释是单线程口径——现在全部 trainer 调用都
//    发生在这一条消费线程上；start()/stop() 只在管线排空
//    （waitForPipelineIdle）之后访问 trainer，单线程约定不破。
//
//  【降频采样 vs 入窗帧率（24 帧 ≈ 1.53s 的语义）】
//    state_token 的 24 帧窗口在训练侧是 15Hz 等间隔（跨度 23/15 ≈ 1.53s）。
//    若把「降频后的采样帧」塞进窗口，每 3 帧采一次时 24 帧跨度会被拉到
//    ≈4.6s，运动尺度整体失真。因此：**入窗按输入帧率**（消费端对每个到达
//    帧都 push ring），降频（sampleEveryNFrames）只作用于「算 token + 采样
//    + 发布 + collect」这一段。
//
//  【封口时机（Codex 复审 #5/#6/#7 逐条修复）】
//    · 接管/人工介入：判定**先于降频**——无论本帧是否采样位，一律走
//      **接管归因路径**（#6：collect(tookOver:true)——把 -takeover 惩罚加到
//      上一条 AI transition 并置为真实终止，flushTerminated 整批训练，惩罚进
//      actor 梯度；不再当无效观测 markInvalid 丢弃）+ 窗口复位 +
//      **撤销在途动作**（executor 收 releaseAll 哨兵），不采样、不为人类
//      动作建 transition。
//    · 无效观测（渲染失败 / 推理无输出 / token 非 256 维或非有限）：markInvalid
//      封口（丢无可靠后继的末条、用其 value bootstrap 前缀）+ 撤销在途动作。
//    · episode 边界：不用「采样计数 % 240」伪造 terminal；真实终止由接管
//      （flushTerminated）与 stop() 封口承担；超长轨迹按**真实时间**
//      （softCutSeconds）软截断走 sealEpisode 的 tail bootstrap 语义。
//
//  【B1/B5/B6 动作执行会话（Codex 第三轮）】
//    · B1 串行会话化：所有 executor 调用收敛到**独立串行 actionQueue**（与
//      消费线程解耦）——stop 的 releaseAll 不被卡死的推理阻塞，执行方（含
//      ControlEngine 侧）绝不会被两个线程并发调用。入队时快照 (executor箱,
//      会话代数)，执行点只认快照（Codex 七轮 P1：绝不 re-read currentExecutor
//      给旧动作借新会话身份）；代数不一致的旧动作作废，releaseAll 哨兵恒对
//      入队时的旧执行方投递（安全方向）。
//      digest 由 runtime 统一核算（每次调用在临界区读一次 digestMode），执行
//      方不得把 digest 另写进 ControlEngine 每帧覆盖（那是竞态源）。
//    · B5 stop 硬不变量：一进入就**失效动作会话 + 立即 releaseAll**（不等
//      排空——卡死的推理恢复后，在途帧的采样动作因会话失效一律作废不发布）；
//      排空成功后才做封口/存盘等可恢复步骤；停止+存盘是否成功如实返回给 UI。
//    · B6 clearActionExecutor()：Controller 在退出壳模式/启动失败时撤销执行
//      方；独立在线训练复用本 runtime 时不会残留旧 executor（live 时
//      「只读训练」变真注入的事故源）。
//
//  【#7 存盘续训】
//    stop() 在排空训练后把**当前策略头**（trainer 已发布的最终权重，含 value
//    头）序列化到 headCheckpointURL（默认 Application Support/AuroraDrive/
//    shell_head_latest.json，可用环境变量 AURORA_RL_HEAD_CHECKPOINT 覆盖）；
//    start() 优先加载该存盘、缺失/损坏才回退 swift_head_init.json、再回退随机。
//    否则每次重启都从初始权重开始，训练成果全部白扔。
//
//  【安全边界（为什么默认不影响真实驾驶）】
//    · digestMode 默认 true：动作交给执行方「消化」（ControlEngine 状态链），
//      不产生真实按键；live 模式（真 CGEvent 注入）必须由上层显式开启。
//    · 本运行时只读帧 + 只做策略计算 + 经注入的 executor 发布动作；执行方
//      （ShellModeController 侧接线）负责 digest→ControlEngine / live→CGEvent。
//    · 训练消费线程 qos=.utility——训练是后台工作，宁可丢帧也不抢主驾。
// ============================================================================

import Foundation
import CoreGraphics

// MARK: - #5 动作执行链契约（实现由 ShellModeController 侧注入）

/// 撤销哨兵：执行方收到它必须释放全部在途按键（接管/封口/stop 时撤销，
/// 防卡键/防残留）。vClass/hClass 均为 -1，与合法采样动作 [0,2] 无歧义。
extension RLAction {
    static let releaseAll = RLAction(vClass: -1, hClass: -1)
}

// MARK: - #7 默认存盘路径（文件级非隔离函数——init 默认参数不能引用
// @MainActor 类的隔离成员，也不能引用 Self）

/// 默认存盘路径：Application Support/AuroraDrive/shell_head_latest.json
/// （装到非项目树也能用）。环境变量 AURORA_RL_HEAD_CHECKPOINT 可覆盖
/// （自检/诊断隔离用，与 AURORA_RL_HEAD_INIT 同模式）。
private func defaultRLHeadCheckpointURL() -> URL? {
    if let env = ProcessInfo.processInfo.environment["AURORA_RL_HEAD_CHECKPOINT"], !env.isEmpty {
        return URL(fileURLWithPath: env)
    }
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("AuroraDrive", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        return nil          // 建不出目录（只读卷等）：放弃持久化，不崩
    }
    return dir.appendingPathComponent("shell_head_latest.json")
}

// MARK: - state_token 来源

/// state_token 来源抽象：生产 = StateTokenAccelerator（真 CoreML）；
/// 自检注入假源（不加载真模型即可全链路驱动）。仅本文件与自检使用。
protocol StateTokenSource {
    /// 本帧 256 维 state_token；失败返回 nil（调用方封口当前轨迹，不静默续跑）。
    func stateToken(window: V3FrameRingBuffer, prevHorizontalClass: Int) -> [Float]?
    /// 最近一次失败原因（诊断/如实上报，不吞错）。
    var failureReason: String? { get }
}

extension StateTokenAccelerator: StateTokenSource {}

/// 在线训练运行时控制器（@MainActor：只在 tick / 按钮这些主线程上下文调用）。
///
/// `@unchecked Sendable`：唯一跨线程共享的状态都在 stateLock 临界区内
/// （见各 nonisolated(unsafe) 字段注释）；消费线程独占态按「管线排空屏障」
/// 协议与主线程互斥（与 OnlineTrainer 的 @unchecked Sendable 同款约定）。
@MainActor
final class OnlineTrainingRuntime: @unchecked Sendable {

    // MARK: 可调参数

    /// 每多少帧做一次「算 token + 采样 + 发布 + collect」（降频，减小对主推理的抢占）。
    /// 生产默认每张新帧都决策；离线实验可单独降低决策频率。
    private let sampleEveryNFrames: Int
    /// 每 N 秒对当前轨迹做一次「软截断」（真实时间，不按采样计数伪造 terminal）。
    private let softCutSeconds: TimeInterval
    /// B5：stop() 排空帧管线的硬超时上限（默认 10s；自检用小值加速超时路径）。
    private let drainTimeout: TimeInterval
    /// B5②：stop() 排空训练队列的硬超时上限（默认 10s）——drainTrainingAndWait
    /// 是无限 sync，裸调会让 stop 永远卡死（-rl-online 卡死教训）。
    private let trainDrainTimeout: TimeInterval
    /// B5③：stop() 里 releaseAll 送达执行方的确认超时（默认 2s；超时如实
    /// keysReleased=false，不无限等）。
    private let actionConfirmTimeout: TimeInterval
    /// OnlineTrainer 的 PPO 配置（训练超参）。
    private let ppoConfig: PPOConfig

    // MARK: 依赖

    /// 生产 state_token 加速器（也承载 ready/failureReason 诊断）。
    private nonisolated(unsafe) let accelerator: StateTokenAccelerator
    /// 实际推理来源 = 加速器（生产）或注入的假源（自检）。
    private nonisolated(unsafe) let stateTokenSource: StateTokenSource
    private let usingInjectedSource: Bool
    /// 单线程约定：仅消费线程访问；start/stop 在管线排空后（主线程）访问。
    private nonisolated(unsafe) var trainer: OnlineTrainer?

    // MARK: #5 动作执行（lead 钉死契约：可注入闭包属性 + digestMode）

    /// #5 动作执行回调（Controller 注入；nil = 不执行，纯观测场景）。
    /// 调用线程 = runtime 内部**串行 actionQueue**（B1：与消费线程解耦）；
    /// 实现必须快速返回（需要主线程时用 async 跳转，不得 sync 阻塞）。语义：
    ///   · action.vClass/hClass ∈ [0,2]：按下该动作——执行方负责「先释放上一
    ///     动作、再按当前动作」的按键生命周期；
    ///   · action == .releaseAll（vClass/hClass = -1）：撤销全部在途动作。
    /// digest=true（digestMode 开）→ 只给 ControlEngine 消化，**不得产生真实
    /// 按键**；digest=false → CGEvent 真注入（仅限用户明确授权的实机实验）。
    nonisolated var actionExecutor: ((RLAction, _ digest: Bool) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return actionExecutorBoxValue?.execute }
        set {
            stateLock.lock()
            // 每次注入都换新箱（实例身份）——执行点用 === 校验「仍是同一
            // executor 实例」，换装即旧动作作废（Codex 七轮 P1 契约 2/3）。
            actionExecutorBoxValue = newValue.map { ExecutorBox($0) }
            stateLock.unlock()
        }
    }
    private nonisolated(unsafe) var actionExecutorBoxValue: ExecutorBox?

    /// Codex 七轮 P1：executor 身份箱——Swift 闭包无 === 比较，包一层以做
    /// 实例同一性校验。执行点只认入队时快照的 (box, generation)。
    private final class ExecutorBox {
        let execute: (RLAction, _ digest: Bool) -> Void
        init(_ execute: @escaping (RLAction, _ digest: Bool) -> Void) { self.execute = execute }
    }

    /// #5 动作执行模式开关（默认 true = digest 只算不真按）。
    /// B1：digest 由 runtime 统一核算（每调用在临界区读一次），执行方不得
    /// 把 digest 另写进 ControlEngine 每帧覆盖。
    nonisolated var digestMode: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return digestModeValue }
        set { stateLock.lock(); digestModeValue = newValue; stateLock.unlock() }
    }
    private nonisolated(unsafe) var digestModeValue = true

    /// #6 统一核算：用户 digest 开关提供者（Controller 注入，典型实现读
    /// ControlEngine.digestMode）。返回 true = 用户开了 digest → 最终必须
    /// digest（**绝不能在用户 digest 开时真注入**）。nil = 无用户输入。
    ///
    /// #3 契约（2026-11-18）：本闭包的取值只构成传给 executor 的 digest
    /// **建议值**——最终决策在执行点（applyShellAction，主线程）重查为准。
    /// 实现必须线程安全：闭包引用在 stateLock 临界区内读取、**调用发生在串行
    /// actionQueue 的后台线程上**（锁外，避免锁内调外部闭包死锁）——不得
    /// 裸读主线程字段（如直接读 MainActor 状态），须用线程安全读。
    nonisolated var userDigestProvider: (() -> Bool)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return userDigestProviderValue }
        set { stateLock.lock(); userDigestProviderValue = newValue; stateLock.unlock() }
    }
    private nonisolated(unsafe) var userDigestProviderValue: (() -> Bool)?

    /// #6 统一核算：live 真注入许可（默认 true，env AURORA_RL_LIVE_ACTUATION=="0" 才禁用，
    /// Controller/自检可显式覆盖）。传给 executor 的最终有效值：
    /// `effectiveDigest = digestMode(运行时基线) || userDigest(用户开关) || !liveAllowed`。
    nonisolated var liveActuationAllowed: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return liveActuationAllowedValue }
        set { stateLock.lock(); liveActuationAllowedValue = newValue; stateLock.unlock() }
    }
    private nonisolated(unsafe) var liveActuationAllowedValue: Bool

    /// B5①：最近一次 stop 的结果快照（UI/Controller 透传用；start() 清空——
    /// 新会话不带着旧会话的停止报告）。keysReleased=false = releaseAll 在
    /// 确认超时内未送达执行方（执行方可能卡死，如实上报）。
    var lastStopReport: (drained: Bool, headSaved: Bool, keysReleased: Bool)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastStopReportValue
    }
    private nonisolated(unsafe) var lastStopReportValue: (drained: Bool, headSaved: Bool, keysReleased: Bool)?

    /// B1/B5 动作会话有效性（stateLock 保护）：start 置 true、stop 一进入置 false。
    /// 置 false 后，已入队/在途帧的采样动作一律作废不发布（停止后旧帧动作
    /// 不得再操纵按键）；releaseAll 哨兵不受门控（撤销必须总能送达）。
    private nonisolated(unsafe) var actionSessionActiveValue = false

    /// Codex 七轮 P1·动作会话代数（stateLock 保护）：start()/stop()/
    /// clearActionExecutor() 各自增（stop/clear 的自增即「作废本代」）。
    /// dispatchAction 入队时捕获当时代数，执行点校验「代数一致 && 同一
    /// executor 实例」才执行——堵死「投递超时→stop→start→旧普通动作出队
    /// 读到新会话 stillActive/新 executor 借身份执行」的时序洞。
    private nonisolated(unsafe) var actionSessionGenerationValue: UInt64 = 0

    // MARK: #7 存盘

    /// 策略头存盘路径（nil = 不存盘不续读，纯观测/自检隔离场景）。
    private let headCheckpointURL: URL?

    // MARK: 主线程（@MainActor）独占状态

    /// 输入帧计数（每 onFrame +1——降频判定必须按**输入帧率**，不是消费帧率）。
    private var frameCounter: Int = 0
    private var isRunning = false

    // MARK: 消费线程独占状态（start/stop 仅在管线排空屏障后访问）

    /// 本地帧窗口（24 帧 hi/lo 环形缓冲，与 V3 同构；仅训练用，独立于主推理窗口）。
    private nonisolated(unsafe) var ring = V3FrameRingBuffer()
    /// 上一次实际采样时执行的动作（首帧用 NONE=1）。
    private nonisolated(unsafe) var prevHorizontalClass: Int = 1
    /// 当前轨迹段的起始时刻（真实时间软截断的基准；nil = 下个采样帧起算）。
    private nonisolated(unsafe) var episodeSegmentStart: Date?

    // MARK: 跨线程状态（全部在 stateLock 临界区内读写）

    /// 单槽工作项（容量 1，丢旧保新）。
    private enum WorkItem {
        /// 正常帧：消费端渲染 → 入窗 →（shouldSample 时）采样 + 发布 + collect。
        case frame(CGImage, signals: FrameSignals, shouldSample: Bool)
        /// 接管/人工介入封口（判定先于降频；消费端走接管归因 + ring 复位 + 撤销动作）。
        case seal(signals: FrameSignals)
    }

    private let stateLock = NSCondition()
    private nonisolated(unsafe) var slot: WorkItem?
    /// 是否已有 drainLoop 调度在途（避免每帧一个 async 块，有界不堆积）。
    private nonisolated(unsafe) var drainScheduled = false
    /// 已入槽但尚未处理完的项数（waitForPipelineIdle 的判据）。
    private nonisolated(unsafe) var inFlight = 0

    // 诊断计数（供 UI / 日志 / 自检；stateLock 保护）
    private nonisolated(unsafe) var sampledFramesValue = 0
    private nonisolated(unsafe) var skippedFramesValue = 0
    private nonisolated(unsafe) var droppedFramesValue = 0
    private nonisolated(unsafe) var episodeSealCountValue = 0
    private nonisolated(unsafe) var windowFilledValue = 0
    private nonisolated(unsafe) var lastErrorValue: String?
    private nonisolated(unsafe) var lastFrameSignalsValue: FrameSignals?
    /// 最近一次发布的采样动作（#5 诊断/自检「参数无损」断言用）。
    private nonisolated(unsafe) var lastDispatchedActionValue: RLAction?

    /// 帧消费包含实时驾驶决策；PPO 更新独立运行在 utility 队列上。
    private let workerQueue = DispatchQueue(label: "aurora.online-train.frame", qos: .userInteractive)
    private var latencyActivity: NSObjectProtocol?

    /// B1 动作执行串行队列：所有 executor 调用收敛于此——与消费线程解耦
    /// （stop 的 releaseAll 不被卡死的推理阻塞），执行方绝不会被并发调用。
    private let actionQueue = DispatchQueue(label: "aurora.online-train.action", qos: .userInitiated)

    /// B5②：训练队列排空的执行队列（把 drainTrainingAndWait 的无限 sync 包成
    /// 有界等待；串行保证多次 stop 的排空请求有序）。
    private let trainDrainQueue = DispatchQueue(label: "aurora.online-train.traindrain", qos: .utility)

    init(sampleEveryNFrames: Int = 1,
         softCutSeconds: TimeInterval = 48,
         drainTimeout: TimeInterval = 10,
         trainDrainTimeout: TimeInterval = 10,
         actionConfirmTimeout: TimeInterval = 2,
         ppoConfig: PPOConfig = {
             var c = PPOConfig()
             c.lr = 3e-4          // 在线微调用小学习率，避免把预训练头打飞
             c.epochs = 2
             c.batch = 16
             c.vfCoef = 0.5
             c.entCoef = 0.005
             return c
         }(),
         headCheckpointURL: URL? = defaultRLHeadCheckpointURL(),
         stateTokenSource: StateTokenSource? = nil) {
        self.sampleEveryNFrames = max(1, sampleEveryNFrames)
        self.softCutSeconds = max(0.01, softCutSeconds)
        self.drainTimeout = max(0.1, drainTimeout)
        self.trainDrainTimeout = max(0.1, trainDrainTimeout)
        self.actionConfirmTimeout = max(0.05, actionConfirmTimeout)
        self.ppoConfig = ppoConfig
        self.headCheckpointURL = headCheckpointURL
        self.accelerator = StateTokenAccelerator()
        // #6：live 真注入许可默认与 App/Controller 同源（env AURORA_RL_LIVE_ACTUATION）。
        //   默认 true（live 真注入）；env =="0" 才禁用，此时传给 executor 的有效 digest 恒为 true（强制只算不真按）。
        self.liveActuationAllowedValue =
            ProcessInfo.processInfo.environment["AURORA_RL_LIVE_ACTUATION"] != "0"
        if let injected = stateTokenSource {
            self.stateTokenSource = injected
            self.usingInjectedSource = true
        } else {
            self.stateTokenSource = accelerator
            self.usingInjectedSource = false
        }
    }

    // MARK: 状态读出（UI / 诊断）

    /// 训练是否在跑（UI 按钮状态 / tick 门控）。
    var running: Bool { isRunning }

    /// 当前策略头是否真的就绪（加速器模型加载成功）。
    var acceleratorReady: Bool { usingInjectedSource || accelerator.isReady }

    /// 最近一次发布的采样动作（参数是否无损到达执行方，自检断言用）。
    var lastDispatchedAction: RLAction? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastDispatchedActionValue
    }

    var sampledFrames: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return sampledFramesValue
    }
    var skippedFrames: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return skippedFramesValue
    }
    /// 被有界单槽丢弃的帧数（丢旧保新——消费不过来时的设计行为，不是故障）。
    var droppedFrames: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return droppedFramesValue
    }
    /// 封口次数（接管/人工介入、无效观测、软截断、stop 收尾）。
    var episodeSealCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return episodeSealCountValue
    }
    /// 训练窗口已入帧数（0~24；start/stop/接管封口时复位）。
    var trainingWindowFilled: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return windowFilledValue
    }
    var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastErrorValue
    }
    /// 最近一帧到达消费端的信号快照（诊断 / 自检「信号透传」断言用）。
    var lastFrameSignals: FrameSignals? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastFrameSignalsValue
    }

    // MARK: 启停

    /// 启动：加载 state_token 加速器 + 初始化 OnlineTrainer。
    /// 策略头初始权重优先级（#7）：上次训练存盘 > swift_head_init.json > 随机。
    /// - Returns: 是否成功（加速器模型缺失时返回 false，并由 lastError 说明）。
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        // 上一次 stop 若超时未排空（极端：推理卡死），如实拒绝重启——
        // 避免新 trainer 与残留消费并发混流。正常路径下这里是零等待。
        if !waitForPipelineIdle(timeout: 10) {
            setLastError("拒绝启动：上次停止后帧管线仍未排空（推理可能卡死）")
            return false
        }
        guard usingInjectedSource || accelerator.loadIfNeeded() else {
            setLastError("state_token 加速器不可用：" + (accelerator.failureReason ?? "模型未就绪"))
            return false
        }
        let head: PolicyHead
        if let saved = headCheckpointURL, let loaded = Self.loadHead(from: saved) {
            // #7：优先续训——上次 stop 存盘的最终权重（含 value 头）。
            head = loaded
            print("[OnlineTrain] 策略头从上次训练存盘恢复：\(saved.path)")
        } else if let initURL = Self.locateHeadInitJSON(),
                  let loaded = Self.loadHead(from: initURL) {
            // A 域从真 checkpoint 导出的输出头初始权重（BC 预热起步）。
            head = loaded
            print("[OnlineTrain] 策略头从 \(initURL.path) 初始化（真 checkpoint 输出头）")
        } else {
            head = PolicyHead(randomSeed: 0x5EED_2026)
            print("[OnlineTrain] 未找到存盘/初始权重，策略头用随机初始化（seed=0x5EED2026）")
        }
        let t = OnlineTrainer(policy: head,
                              ppoConfig: ppoConfig,
                              trainEvery: 64)
        trainer = t
        latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInteractive, .latencyCritical], reason: "Online driving frame deadlines")
        frameCounter = 0
        // start 复位：不跨场景拼帧。
        ring.reset()
        prevHorizontalClass = 1
        episodeSegmentStart = nil
        stateLock.lock()
        sampledFramesValue = 0
        skippedFramesValue = 0
        droppedFramesValue = 0
        episodeSealCountValue = 0
        windowFilledValue = 0
        lastErrorValue = nil
        lastFrameSignalsValue = nil
        lastStopReportValue = nil       // B5①：新会话不带上次 stop 的报告
        actionSessionActiveValue = true     // B1/B5：新会话激活动作发布
        actionSessionGenerationValue &+= 1 // 七轮 P1：新会话代数，旧队列动作作废
        stateLock.unlock()
        isRunning = true
        return true
    }

    /// 停止：**一进入就失效动作会话 + 立即 releaseAll**（B5 硬不变量，不等
    /// 排空——卡死的推理恢复后，在途帧的采样动作因会话失效一律作废），随后
    /// 排空帧管线并做可恢复步骤（封口/等训练/存盘）。
    ///
    /// **等待次序（#2 契约，2026-11-18 定稿）**：主线程停止入口（App 侧
    /// stopShellMode）**已先行同步撤键**（①快照人键→②主线程同步
    /// releaseAIHeldKeys→③停监听→④才调本方法）。因此本方法的 releaseAll
    /// 哨兵/排空/存盘全部是**后续幂等收尾**，不是松键的第一道——等待推理/
    /// 训练排空期间按住的 AI 键已由入口撤键释放，keysReleased 只确认哨兵
    /// **已投递至最终执行点**（executor 调用返回），**不证明按键已在 CGEvent
    /// 层真实松开**（生产 executor 返回后真实释放可能仍在主队列等待）。
    ///
    /// - Returns: `drained`（帧管线+训练队列是否都在超时内排空；任一超时为
    ///   false，此时不碰 trainer 独占态/不存盘）；`headSaved`（策略头是否成功
    ///   落盘）。结果同时记入 lastStopReport（含 keysReleased：releaseAll
    ///   哨兵是否已在确认超时内投递至最终执行点），供 Controller/UI 透传。
    @discardableResult
    func stop() -> (drained: Bool, headSaved: Bool) {
        guard isRunning else {
            recordStopReport(drained: true, headSaved: true, keysReleased: true)
            return (drained: true, headSaved: true)
        }
        // ① B5 硬不变量（必须成立，先于一切等待）：失效会话 + 立即撤销在途动作。
        //    releaseAll 走独立 actionQueue，即使消费线程卡死也能排队送达。
        stateLock.lock()
        actionSessionActiveValue = false
        actionSessionGenerationValue &+= 1 // 七轮 P1：作废本代（投递超时后重启也不借身份）
        stateLock.unlock()
        isRunning = false          // 关门：onFrame 不再入槽
        if let latencyActivity {
            ProcessInfo.processInfo.endActivity(latencyActivity)
            self.latencyActivity = nil
        }
        dispatchAction(.releaseAll)
        // B5③：键释放完成确认——releaseAll 之前的全部 executor 调用（含它自身）
        // 在 actionConfirmTimeout 内跑完才算送达；执行方卡死则如实 false。
        let keysReleased = awaitActionDelivery(timeout: actionConfirmTimeout)

        // ② 排空帧管线（硬超时）。超时：消费线程可能卡死，绝不碰它独占的
        //    trainer/ring（并发混流更危险）；动作会话已失效，残留帧动作不会发布。
        guard waitForPipelineIdle(timeout: drainTimeout) else {
            setLastError("停止超时：帧管线 \(Int(drainTimeout))s 未排空（推理可能卡死）；本轮轨迹未封口、未存盘")
            recordStopReport(drained: false, headSaved: false, keysReleased: keysReleased)
            return (drained: false, headSaved: false)
        }
        // ③ 可恢复的收尾（排空成功后才做）。
        trainer?.markInvalid()     // 封口（此刻消费线程已停，独占 trainer）
        noteSeal()
        ring.reset()               // stop 复位：不跨场景拼帧
        prevHorizontalClass = 1
        episodeSegmentStart = nil
        frameCounter = 0
        noteWindowFilled()
        // B5②：训练排空有界化——drainTrainingAndWait 是无限 sync，裸调会让
        // stop 卡死（-rl-online 卡死教训）；超时如实 drained=false、不存盘。
        guard drainTrainingBounded() else {
            setLastError("停止超时：训练队列 \(Int(trainDrainTimeout))s 未排空；本轮学习结果未存盘")
            recordStopReport(drained: false, headSaved: false, keysReleased: keysReleased)
            return (drained: false, headSaved: false)
        }
        let saved = saveHeadCheckpoint()  // #7：训练成果落盘，下次 start 续训
        recordStopReport(drained: true, headSaved: saved, keysReleased: keysReleased)
        return (drained: true, headSaved: saved)
    }

    /// B5③（#2 语义修正）：确认 actionQueue 上已入队的 executor 调用（含
    /// releaseAll）**已投递至最终执行点**——DispatchGroup 哨兵排在 releaseAll
    /// 之后（串行 FIFO），哨兵跑完即证明 releaseAll 的 executor 调用已返回。
    /// **不证明按键已真实松开**（生产 executor 返回后 CGEvent 层释放可能仍在
    /// 主队列等待）；真实松键由 App 侧主线程同步撤键先行承担（见 stop 次序注
    /// 释），本哨兵只是幂等清理的投递确认。执行方卡死则超时返回 false，绝不
    /// 无限等。
    private nonisolated func awaitActionDelivery(timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()
        group.enter()
        actionQueue.async { group.leave() }
        return group.wait(timeout: .now() + timeout) == .success
    }

    /// B5②：有界排空训练队列。drainTrainingAndWait 是 trainingQueue.sync（无限
    /// 等），包进独立串行队列 + 超时；超时返回 false（排空请求仍留在队列上，
    /// 卡死的训练若之后恢复仍会跑完，但 stop 必须先返回）。
    private nonisolated func drainTrainingBounded() -> Bool {
        guard trainer != nil else { return true }
        let group = DispatchGroup()
        group.enter()
        // 捕 self（weak）：runtime 是 @unchecked Sendable 且闭包即发即弃，
        // 无循环引用；weak 保证 runtime 早已释放时排空请求随之作废。
        trainDrainQueue.async { [weak self] in
            self?.trainer?.drainTrainingAndWait()
            group.leave()
        }
        return group.wait(timeout: .now() + trainDrainTimeout) == .success
    }

    /// 记录最近一次 stop 结果（B5①：start() 清空；本方法只在 stop 路径调用）。
    private nonisolated func recordStopReport(drained: Bool, headSaved: Bool, keysReleased: Bool) {
        stateLock.lock()
        lastStopReportValue = (drained: drained, headSaved: headSaved, keysReleased: keysReleased)
        stateLock.unlock()
    }

    // MARK: 每帧驱动（主线程 tick 调用——立即返回，绝不做渲染/推理）

    /// 本帧观测信号（真实驾驶信号，用于奖励计算；都由 tick 侧从 DriveState 现成字段传来）。
    struct FrameSignals {
        var speedKmh: Double
        var speedValid: Bool
        var tookOver: Bool
        var collision: Bool
        var laneOffset: Double
        var laneMeasurement: TrainingLaneMeasurement? = nil
        var manualStop: Bool     // 本帧是否处于人工介入/危险（作为 episode 硬终止边界）
    }

    /// 用「本帧画面」驱动一次训练。调用方保证 cg 是本帧鲜活画面。
    ///
    /// 主线程只做：接管判定（先于降频）→ cg 引用 + 信号快照入有界单槽 → 返回。
    /// 渲染/推理/采样/发布/collect 全在消费线程；消费不过来丢旧保新。
    func onFrame(_ cg: CGImage, signals: FrameSignals) {
        guard isRunning else { return }
        frameCounter &+= 1
        let item: WorkItem
        if signals.tookOver || signals.manualStop {
            // 接管/人工介入：先于降频判定，无条件封口（不采样、不 collect）。
            item = .seal(signals: signals)
        } else {
            // 入窗按输入帧率（消费端每个到达帧都 push ring）；
            // 降频只作用于「算 token + 采样 + 发布 + collect」。
            item = .frame(cg, signals: signals,
                          shouldSample: frameCounter % sampleEveryNFrames == 0)
        }
        var needSchedule = false
        stateLock.lock()
        if slot != nil {
            if case .seal? = slot, case .frame = item {
                // 槽里是尚未消费的封口项（episode 边界），普通帧不能覆盖它：本帧丢弃。
                droppedFramesValue += 1
                stateLock.unlock()
                return
            }
            // 覆盖旧项（帧→新帧 / 帧→封口 / 封口→封口）：丢旧保新。
            // inFlight 不变——被覆盖项的名额由新项顶替。
            droppedFramesValue += 1
        } else {
            inFlight += 1
        }
        slot = item
        if !drainScheduled {
            drainScheduled = true
            needSchedule = true
        }
        stateLock.unlock()
        if needSchedule {
            // 强持有 self：runtime 存续到管线排空（自检/停止语义依赖这一点）。
            workerQueue.async { self.drainLoop() }
        }
    }

    /// 等待已入槽的帧全部处理完（自检/停止的同步屏障）。
    /// - Returns: true = 已排空；false = 超时（管线可能卡死，如实上报，绝不无限等）。
    @discardableResult
    func waitForPipelineIdle(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        stateLock.lock()
        defer { stateLock.unlock() }
        while inFlight > 0 || drainScheduled {
            if !stateLock.wait(until: deadline) { return false }
        }
        return true
    }

    // MARK: 消费端（workerQueue 串行执行；OnlineTrainer 单线程约定由此保证）

    /// 消费主循环：一次调度内清空单槽直到槽空再退出（有界并发，不堆积）。
    private nonisolated func drainLoop() {
        while true {
            stateLock.lock()
            guard let item = slot else {
                drainScheduled = false
                stateLock.signal()      // 唤醒 waitForPipelineIdle 等待者复核
                stateLock.unlock()
                return
            }
            slot = nil
            stateLock.unlock()
            process(item)
            stateLock.lock()
            inFlight -= 1
            stateLock.signal()          // 本项处理完：唤醒 idle 等待者
            stateLock.unlock()
        }
    }

    /// 处理一项：渲染 → 入窗 →（采样帧）软截断检查 → state_token → 采样 → 发布 → collect。
    private nonisolated func process(_ item: WorkItem) {
        // 接管/人工介入封口：撤销在途动作 + 走 trainer 接管归因路径 + 窗口复位
        //（不采样、不为人类动作建 transition）。
        if case .seal(let signals) = item {
            noteFrameSignals(signals)
            dispatchAction(.releaseAll)
            recordTakeoverAndSeal(signals)
            ring.reset()                // 接管封口复位：不跨场景拼帧
            prevHorizontalClass = 1
            episodeSegmentStart = nil
            noteWindowFilled()
            noteSeal()
            return
        }
        guard case .frame(let cg, let signals, let shouldSample) = item else { return }
        noteFrameSignals(signals)
        guard let trainer else { return }

        // ① 渲染 hi/lo 两路归一化输入（与 V3 生产同源）。失败 = 无效观测 → 封口。
        guard let hi = InferenceEngineV3.renderNormalized(
                  cg, height: V3InputContract.hiHeight, width: V3InputContract.hiWidth),
              let lo = InferenceEngineV3.renderNormalized(
                  cg, height: V3InputContract.loHeight, width: V3InputContract.loWidth) else {
            skipAndSeal("渲染归一化失败（hi/lo）")
            return
        }
        // ② 每个到达帧都入窗（按输入帧率，不受采样降频影响——24 帧 ≈ 1.53s 语义）。
        ring.push(hi: hi, lo: lo)
        noteWindowFilled()

        // ③ 采样段可降频。
        guard shouldSample else { return }

        // ④ 软截断（真实时间，非采样计数）：封口走 tail bootstrap 语义，
        //    不伪造 terminal。软截断不 reset ring——同场景连续驾驶。
        let now = Date()
        if let start = episodeSegmentStart,
           now.timeIntervalSince(start) >= softCutSeconds {
            trainer.sealEpisode()
            noteSeal()
            episodeSegmentStart = now
        } else if episodeSegmentStart == nil {
            episodeSegmentStart = now
        }

        // ⑤ state_token：失败/维度错/非有限 = 无效观测 → 封口（不静默续旧轨迹）。
        guard let token = stateTokenSource.stateToken(
                  window: ring,
                  prevHorizontalClass: prevHorizontalClass) else {
            skipAndSeal(stateTokenSource.failureReason ?? "state_token 源无输出")
            return
        }
        guard token.count == PolicyHead.stateDimension,
              token.allSatisfy({ $0.isFinite }) else {
            skipAndSeal("state_token 非法（维度=\(token.count) 或含非有限值）")
            return
        }

        // ⑥ 采样 → 发布动作（#5）→ collect。
        //    不发布动作就不是 on-policy：环境对动作的反馈要从下一帧 reward 进来。
        //    isTerminal 恒 false——真实终止由接管路径与 stop()/封口承担。
        let sample = trainer.sampleAction(stateToken: token)
        prevHorizontalClass = sample.hClass
        dispatchAction(sample.action)
        _ = trainer.collect(stateToken: token,
                            sample: sample,
                            tookOver: false,       // 接管帧走 .seal，不会到这里
                            speedKmh: signals.speedKmh,
                            speedValid: signals.speedValid,
                            collision: signals.collision,
                            laneOffset: signals.laneOffset,
                            isTerminal: false, laneMeasurement: signals.laneMeasurement)
        stateLock.lock()
        sampledFramesValue += 1
        stateLock.unlock()
    }

    // MARK: #6 接管归因（走 OnlineTrainer 的 P1-3 路径）

    /// 接管/人工介入帧：把 -takeover 惩罚归因到**上一条 AI transition** 并置为
    /// 真实终止（flushTerminated 整批训练，惩罚进 actor 梯度），而非当无效观测
    /// 丢弃（markInvalid 会让惩罚路径永不触发——#6 修复的核心）。
    ///
    /// 走 `collect(tookOver:true)`：其 P1-3 分支只用本帧信号算原始 reward（进
    /// accumulator、随后随 resetRewardState 丢弃，不进训练），stateToken/sample
    /// 参数在该分支不参与——传占位值并注明，绝不为其伪造 transition。
    private nonisolated func recordTakeoverAndSeal(_ signals: FrameSignals) {
        guard let trainer else { return }
        let placeholderSample = PolicySample(vClass: 0, hClass: 0,
                                             logProbV: 0, logProbH: 0, value: 0)
        _ = trainer.collect(stateToken: [],
                            sample: placeholderSample,   // P1-3 分支不消费，占位
                            tookOver: true,
                            speedKmh: signals.speedKmh,
                            speedValid: signals.speedValid,
                            collision: signals.collision,
                            laneOffset: signals.laneOffset,
                            isTerminal: true)
    }

    // MARK: #5 动作发布（B1：串行会话化）

    /// 发布动作给执行方。B1/B5 语义：
    /// · 采样动作（vClass ≥ 0）受**动作会话**门控——stop/clearActionExecutor
    ///   已失效后，在途帧的旧动作一律作废不发布；
    /// · releaseAll 哨兵**不受会话门控**（撤销必须总能送达，stop 靠它松键）；
    /// · 调用收敛到**独立串行 actionQueue**：与消费线程解耦（stop 的
    ///   releaseAll 不被卡死的推理阻塞），执行方绝不会被并发调用；
    /// · 块内**二次校验**会话/executor/digest（关掉入队到执行之间的竞争窗口）；
    /// · digest 由 runtime 统一核算（临界区读一次 digestMode），实现方不得
    ///   把 digest 另写进 ControlEngine 每帧覆盖。
    private nonisolated func dispatchAction(_ action: RLAction) {
        stateLock.lock()
        let sessionActive = actionSessionActiveValue
        let generation = actionSessionGenerationValue
        let executorBox = actionExecutorBoxValue
        if action.vClass >= 0 {
            lastDispatchedActionValue = action   // 只记采样动作，不记撤销哨兵
        }
        stateLock.unlock()
        // 入队前快速路径：会话已失效且非撤销哨兵 → 旧帧动作作废；executor
        // 未接线 → 无处可发（撤销哨兵也一样静默跳过）。
        guard let executorBox, sessionActive || action.vClass < 0 else { return }
        actionQueue.async { [weak self, action, executorBox, generation] in
            guard let self else { return }
            // Codex 七轮 P1：执行点只认**入队时快照**的 (executorBox, generation)，
            // 绝不 re-read currentExecutor/会话——堵死「投递超时→stop→start→
            // 旧普通动作出队读到新会话新 executor 借身份执行」：
            //   · 代数不一致（期间 stop/clear/start 已换代）→ 采样动作作废；
            //   · executor 已换装（新箱 !== 快照箱）→ 采样动作作废；
            //   · releaseAll 哨兵是安全方向，恒对快照的旧执行方投递。
            self.stateLock.lock()
            let stillSameSession = self.actionSessionGenerationValue == generation
            let stillSameExecutor = self.actionExecutorBoxValue === executorBox
            self.stateLock.unlock()
            guard stillSameSession, stillSameExecutor, action.vClass >= 0 else {
                if action.vClass >= 0 { return }   // 旧会话采样动作：作废，不执行
                // releaseAll 哨兵：仍投递给入队时快照的旧执行方（松键安全方向）。
                self.stateLock.lock()
                let baseDigest = self.digestModeValue
                let provider = self.userDigestProviderValue
                let liveAllowed = self.liveActuationAllowedValue
                self.stateLock.unlock()
                let effectiveDigest = baseDigest || (provider?() ?? false) || !liveAllowed
                executorBox.execute(action, effectiveDigest)
                return
            }
            // 快照校验全过（同一会话 + 同一执行方 + 采样动作）：核算最终 digest。
            self.stateLock.lock()
            let baseDigest = self.digestModeValue
            let provider = self.userDigestProviderValue
            let liveAllowed = self.liveActuationAllowedValue
            self.stateLock.unlock()
            let effectiveDigest = baseDigest || (provider?() ?? false) || !liveAllowed
            executorBox.execute(action, effectiveDigest)
        }
    }

    // MARK: B6 executor 清理

    /// 撤销动作执行方（B6）：Controller 在退出壳模式/训练启动失败时调用，
    /// 防止「独立在线训练」复用本 runtime 时残留壳模式的旧 executor（live
    /// 时「只读训练」变真注入的事故源）。
    ///
    /// 语义：锁内捕获**旧 executor** 并立即置 nil + 失效动作会话（此后采样/
    /// 在途帧的动作一律作废），然后把**最后一次 releaseAll 直接投递到串行
    /// actionQueue** 送给旧执行方松开在途按键。直接持引用投递（不走
    /// dispatchAction 的二次校验）是因为校验会看到 executor 已 nil 而把这次
    /// 最终撤销丢掉；串行队列保证它仍与之前/之后的所有执行方调用严格有序。
    func clearActionExecutor() {
        stateLock.lock()
        let oldExecutor = actionExecutorBoxValue?.execute
        let baseDigest = digestModeValue
        let userDigestProvider = userDigestProviderValue
        let liveAllowed = liveActuationAllowedValue
        actionExecutorBoxValue = nil
        actionSessionActiveValue = false
        actionSessionGenerationValue &+= 1 // 七轮 P1：作废本代（清后旧队列动作不借新会话）
        stateLock.unlock()
        guard let oldExecutor else { return }
        // #6 统一核算（与 dispatchAction 同式；releaseAll 也带最终有效 digest，
        // 语义一致）：基线 || 用户 digest || !live 许可。
        let effectiveDigest = baseDigest || (userDigestProvider?() ?? false) || !liveAllowed
        actionQueue.async { oldExecutor(RLAction.releaseAll, effectiveDigest) }
    }

    // MARK: 内部小工具（跨线程调用；各自持锁）

    /// 无效观测：撤销在途动作 + 封口当前轨迹（markInvalid = tail bootstrap 封口）
    /// + 计数 + 留档原因。
    private nonisolated func skipAndSeal(_ reason: String) {
        dispatchAction(.releaseAll)
        trainer?.markInvalid()
        episodeSegmentStart = nil      // 轨迹已封，软截断时钟随之重来
        stateLock.lock()
        skippedFramesValue += 1
        episodeSealCountValue += 1
        lastErrorValue = reason
        stateLock.unlock()
    }

    private nonisolated func noteSeal() {
        stateLock.lock()
        episodeSealCountValue += 1
        stateLock.unlock()
    }

    private nonisolated func noteWindowFilled() {
        stateLock.lock()
        windowFilledValue = ring.filled
        stateLock.unlock()
    }

    private nonisolated func noteFrameSignals(_ signals: FrameSignals) {
        stateLock.lock()
        lastFrameSignalsValue = signals
        stateLock.unlock()
    }

    /// 记录/清除最近一次错误（nil = 清除；主线程与消费线程都可能调用）。
    private nonisolated func setLastError(_ message: String?) {
        stateLock.lock()
        lastErrorValue = message
        stateLock.unlock()
    }

    // MARK: #7 存盘续训

    /// 把当前策略头（trainer 里已发布的最终权重）原子写入 headCheckpointURL。
    /// 失败如实留错（不崩——存盘失败不该带崩停止流程，但下次启动会退回旧权重）。
    /// - Returns: 存盘是否成功。无存盘配置（headCheckpointURL == nil，纯观测/
    ///   自检隔离场景）或无 trainer 时返回 true（不适用≠失败）；序列化/写盘
    ///   失败返回 false 并留 lastError（B5：如实上报给 UI）。
    @discardableResult
    private func saveHeadCheckpoint() -> Bool {
        guard let url = headCheckpointURL else { return true }
        guard let head = currentHeadForTest() else { return true }
        guard let data = Self.serializeHead(head) else {
            setLastError("策略头存盘失败：序列化 JSON 失败（\(url.lastPathComponent)）")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            print("[OnlineTrain] 策略头已存盘：\(url.path)")
            return true
        } catch {
            setLastError("策略头存盘失败：\(error.localizedDescription)（\(url.path)）")
            return false
        }
    }

    /// 序列化策略头为 init(fromJSON:) 兼容格式，外加 value 头张量
    /// （fromJSON 把 value 头置零——那是 checkpoint 导出时代的约定；在线训练
    /// 的 value 头是可训练的，不补存/恢复它，value 学习就白做）。
    private static func serializeHead(_ head: PolicyHead) -> Data? {
        func tensor(_ name: String, _ shape: [Int], _ data: [Double]) -> [String: Any] {
            ["name": name, "shape": shape, "data": data]
        }
        let tensors: [[String: Any]] = [
            tensor("trunk.0.weight", [PolicyHead.hidden1, PolicyHead.stateDimension], head.trunk0.weight),
            tensor("trunk.0.bias", [PolicyHead.hidden1], head.trunk0.bias),
            tensor("trunk.3.weight", [PolicyHead.hidden2, PolicyHead.hidden1], head.trunk1.weight),
            tensor("trunk.3.bias", [PolicyHead.hidden2], head.trunk1.bias),
            tensor("vertical.weight", [PolicyHead.numV, PolicyHead.hidden2], head.vertical.weight),
            tensor("vertical.bias", [PolicyHead.numV], head.vertical.bias),
            tensor("horizontal.weight", [PolicyHead.numH, PolicyHead.hidden2], head.horizontal.weight),
            tensor("horizontal.bias", [PolicyHead.numH], head.horizontal.bias),
            tensor("value.weight", [1, PolicyHead.stateDimension], head.valueLayer.weight),
            tensor("value.bias", [1], head.valueLayer.bias),
        ]
        let root: [String: Any] = ["dim_state_token": PolicyHead.stateDimension,
                                    "tensors": tensors]
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// 读取策略头：init(fromJSON:) 恢复 trunk/决策头；若文件里带 value 张量
    /// （在线训练存盘），再恢复 value 头（fromJSON 会把它置零）。
    /// 文件缺失/损坏返回 nil（调用方按优先级回退，不崩）。
    /// internal：自检要直接读回存盘文件逐张量校验（#7 断言）。
    static func loadHead(from url: URL) -> PolicyHead? {
        guard var head = try? PolicyHead(fromJSON: url) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensorList = root["tensors"] as? [[String: Any]] else {
            return head          // 无 value 张量（初始权重导出）：value 头置零，与原语义一致
        }
        var values: [String: [Double]] = [:]
        for t in tensorList {
            guard let name = t["name"] as? String, let raw = t["data"] as? [Any] else { continue }
            values[name] = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        if let w = values["value.weight"], w.count == PolicyHead.stateDimension,
           let b = values["value.bias"], b.count == 1,
           w.allSatisfy({ $0.isFinite }), b.allSatisfy({ $0.isFinite }) {
            head.valueLayer = LinearLayer(inDim: PolicyHead.stateDimension, outDim: 1,
                                          weight: w, bias: b)
        }
        return head
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

    // MARK: 自检钩子（internal，同 target 的 OnlineTrainingRuntimeSelfTest 用）

    /// 当前 trainer（自检需要启用批次捕获/读指标，证明接管归因进了梯度）。
    func trainerForTest() -> OnlineTrainer? { trainer }

    /// 等待已入队的动作发布全部执行完（自检同步屏障；仅自检用——自检的假
    /// 执行方即时返回，sync 无死锁面。生产 stop() 不等这里：releaseAll 在
    /// 串行队列上先于一切后续动作，送达顺序已有保证）。
    func waitForActionDispatchIdle() {
        actionQueue.sync { }
    }

    /// 当前已发布的策略头快照（自检证明存盘/读回的权重一致性）。
    /// 借道 OnlineTrainer 的 internal 快照钩子（OnlineTrainer 不在本写域，
    /// 这是唯一拿到「训练后权重」的通道；语义即「当前推理快照」）。
    func currentHeadForTest() -> PolicyHead? {
        trainer?.currentPolicyForTest() as? PolicyHead
    }

    // MARK: 指标读出（UI 显示用）

    /// 最近一次训练指标摘要（一行文本）。没有训练过返回 nil。
    func metricsSummary() -> String? {
        guard let m = trainer?.recentMetrics.last else { return nil }
        return String(format: "更新#%d  policy=%.4f value=%.4f ent=%.4f",
                      m.updateIndex, m.policyLoss, m.valueLoss, m.entropy)
    }

    /// 已完成 episode 的平均回报（OnlineTrainer 提供）。
    var meanEpisodeReward: Double? { trainer?.meanEpisodeReward }

    /// 采样/跳过/丢弃/封口计数（诊断用一行文本）。
    func stats() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return "采样帧=\(sampledFramesValue) 跳过=\(skippedFramesValue)"
            + " 丢弃=\(droppedFramesValue) 封口=\(episodeSealCountValue)"
    }
}
