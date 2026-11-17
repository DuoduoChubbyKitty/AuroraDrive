// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ShellModeController.swift — 「人机共驾壳模式」主控
//
//  【它解决什么】
//    壳模式 = 用户自己开车，Aurora 只收抓屏帧做「只读训练/观测」，**不注入任何
//    按键**。要进入这个模式，必须把会抢控制权、抢 ANE 的自动驾驶引擎全部让出：
//      · 后台自动驾驶引擎子进程（EngineClient）→ 真 SIGTERM/SIGKILL 退出、不重连；
//      · 进程内的 V3/V2/M9/assist/YOLO/YOLOPX 推理链 + 控制引擎 + 降级状态机 → reset；
//      · 控制引擎按住的键 → releaseAll（防卡键）。
//    但**抓屏和速度表必须留着** —— 壳模式的训练/观测就靠这两路数据。
//
//  【#5 动作执行链（模型真正自己开）】
//    runtime 采样动作 → actionExecutor（本控制器注入）→ 主线程落点 →
//    hardware.applyShellAction（生产实现：ControlEngine hold/release）。
//    默认 digest 影子（不产生任何按键）；AURORA_RL_LIVE_ACTUATION=1 或 UI 置
//    liveActuationEnabled 才允许真注入。
//
//  【为什么单独一个文件、用可注入的实现】
//    本仓纪律「最小侵入」：DriveState 只加几个成员 + 一个 tick 门控，真正的编排收敛
//    在本文件。为了让 start()/stop() 的行为能被 `-shell-engine-selftest` 在**不真开
//    游戏、不真训练、不真拉引擎子进程**的前提下验证，这里把「被编排的对象」抽成一个
//    `ShellModeHardware` 接口：生产实现（DriveState）直接打到真实引擎，自测实现只
//    记录调用轨迹。接口只有一份 —— 它同时服务生产与自测两个真实消费者（不是为抽象
//    而抽象）。控制器本身**全同步**：异步细节（如 CaptureEngine.applyMode 的
//    async 重建流）收在适配器内部（含代数校验），控制器只做确定性编排，便于逐条
//    断言调用顺序。
//
//  【⚠️ 绝不引用 DriveState.shared（复审 #1，P0）】
//    生产构造点在 DriveState.init() 末尾**直接传 self** —— 那里正是
//    `static let shared = DriveState()` 单例初始化的执行现场，本类型任何路径
//    再去读 DriveState.shared 都构成重入（static let 懒初始化不可重入 → 死锁，
//    与壳模式开关无关、正常启动即触发）。
// ============================================================================

import Foundation

// MARK: - 被编排对象的接口

/// 壳模式要编排的全部「硬件/运行时」侧动作。
///
/// 之所以是协议而不是直接打 DriveState：`-shell-engine-selftest` 需要在不碰真实
/// 引擎（不拉子进程、不建 SCStream、不跑训练）的前提下断言「退引擎 / 保抓屏 /
/// 恢复 startup」的调用顺序。生产实现 `DriveState` 是唯一真实消费者。
@MainActor
protocol ShellModeHardware: AnyObject {

    /// 真 SIGTERM→SIGKILL 让引擎子进程退出，且置 wantsEngineMode=false 不重连。
    /// B4：控制器**无条件调用**本方法（不再用 isActive 预过滤）——快速 stop→再
    /// start 之间存在「resume 轮询在飞、isActive 已 false」的窗口，若被前置条件
    /// 挡住，旧轮询到点仍会 startup 把引擎拉回来与壳模式抢流。实现内部自己取消
    /// pending resume 轮询并判定是否真要断连。
    /// - Returns: 是否确实进入/维持了让出态（引擎没起也没轮询在飞时返回 false）。
    @discardableResult
    func suspendEngineForShellMode() -> Bool

    /// 进程内所有自动驾驶推理/降级链 reset，并释放按住的键。
    /// **绝不含 captureEngine / speedOCR** —— 壳模式要留着抓屏与速度表。
    /// B2：实现须同时接管物理键监听并维护应急接管状态（不依赖 isDriving）——
    /// 本调用后 isDriving=false，驾驶路径的监听建立与 syncPhysicalControlState
    /// 守卫都不可达，不在这里接管的话人工接管信号永远失真。
    func stopAllDrivingEngines()

    /// 设定窗口/全屏捕获并确保抓屏在跑（内部处理 applyMode 的异步细节与竞态防护）。
    /// - Parameter windowID: 只捕获该窗口；nil = 全屏。
    func prepareShellCapture(windowID: UInt32?)

    /// 停抓屏 + 作废在途壳抓屏请求（B3：控制器 stop **无条件调用**本方法）。
    /// 实现必须**先**作废全部在途壳请求（generation/cancel —— 这一步绝不能被
    /// 「有其他抓屏归属方」分支拦截），**再**按归属决定是否真停抓屏引擎：
    /// 有驾驶/录制/共驾录制等归属方时保留抓屏（他们要帧流），但壳请求照旧作废。
    func stopShellCapture()

    /// 启/停在线训练运行时（训练需要帧流，只读帧、绝不注入按键）。
    /// #5：executor 接线由控制器统一完成（start 里注入 / stop 里撤销），
    /// 实现只负责启停 runtime 本身。
    func startShellTraining() -> Bool
    func stopShellTraining()
    var shellTrainingRunning: Bool { get }
    /// 训练运行时对本次启动失败原因的说明（start 失败时透传给 UI）。
    var shellTrainingFailureReason: String? { get }

    /// 重新拉起普通自动驾驶引擎（stop 结尾恢复原状态）。
    /// 实现必须走带时序保护的恢复路径（等旧引擎退透再 startup，并清挂起标志），
    /// 绝不能裸 startup() —— 否则挂起标志残留会让下一次 suspend 被跳过（复审 #2）。
    func restoreEngineAfterShellMode()

    /// 执行一帧采样动作（#5 动作执行链：模型采样 → 真实按键）。
    /// - Parameters:
    ///   - action: vClass 0=给油/1=不动/2=刹车，hClass 0=左/1=不动/2=右；
    ///     vClass/hClass 任一为负（`RLAction.releaseAll` 哨兵）→ 撤销在途键。
    ///   - digest: true=影子（**不产生任何按键**，也不碰 ControlEngine 状态）；
    ///     false=真注入（实现须在入口重查**当前** controlEngine.digestMode 并按其
    ///     结果门控：入参 digest 是排队前的快照，执行时用户可能已打开消化，
    ///     仍按快照走 live 会把 keyUp 消化掉造成 OS 层键卡死）。
    /// 协作点 2（runtime-fix）：实现**不得**写 `controlEngine.digestMode`（该字段
    /// 由 tick 从 UI 开关统一同步，每帧覆盖既竞态又盖掉用户开关）——只按入参
    /// 决定发不发真事件。
    /// B2：人工持键期间实现必须让位（只撤 AI 键、保留用户物理按住的键）。
    /// 实现负责帧间互斥（先释放上一帧不再按住的键，再按当前帧），并保证幂等。
    func applyShellAction(_ action: RLAction, digest: Bool)
}

// MARK: - 主控

/// 人机共驾壳模式主控。@MainActor：只在主线程（按钮 / tick）上下文调用。
///
/// 契约（供 T3/UI 对接）：
/// ```
/// init(runtime: OnlineTrainingRuntime, hardware: ShellModeHardware)
/// func start(windowID: UInt32?) -> Bool
/// func stop()
/// var running: Bool
/// var liveActuationEnabled: Bool   // #5：live 真注入开关（默认 false=digest 影子）
/// ```
/// 注意 init **不再有** `init(runtime:)` 便捷形式：它曾隐式访问 DriveState.shared，
/// 与单例初始化构成重入死锁（复审 #1）。生产由 DriveState.init 末尾传 self 构造。
@MainActor
final class ShellModeController {

    private let runtime: OnlineTrainingRuntime
    /// 弱引用：生产实现是 DriveState 单例（进程级长生，弱引用永不失效），
    /// 用 weak 避免「DriveState 持有 shellController、shellController 又强持有
    /// DriveState」的循环引用。自测时由测试用例强持有假硬件，生命周期覆盖控制器。
    private weak var hardware: ShellModeHardware?

    // ── 两层状态（复审 #3：把「资源已取得」与「训练运行中」分开）──
    //   running：训练已就绪的完整壳模式（UI 主状态）。
    //   resourcesAcquired：①②③ 任一步已生效 —— 即使 ④ 训练失败（start 返回
    //     false），stop() 也必须据此走完整清理（停训练→停抓屏→恢复引擎），
    //     否则「引擎已退、抓屏在跑」的半启动状态永远无法收尾。
    //   enginesSuspended：① 真的让出过后台引擎 —— stop 只接回自己让出的，
    //     引擎本来就没起时也不拉起（保持用户原状态）。
    private(set) var running: Bool = false
    private var resourcesAcquired = false
    private var enginesSuspended = false

    /// 会话代数（Codex 第五轮复审 #1）：start 安装 executor 前自增、stop 再自增。
    /// executor 闭包**按值捕获**安装时刻的代数，主线程执行时与当前值比对——
    /// 快速 stop→start 周期里滞留的旧采样动作因代数过期被淘汰，不会把键按回
    /// 新会话。读比较只发生在主线程（start/stop 也是主线程），无跨线程访问。
    private var shellSessionGeneration = 0

    /// 唯一构造入口：生产由 DriveState.init 末尾传 self；自测传假硬件。
    init(runtime: OnlineTrainingRuntime, hardware: ShellModeHardware) {
        self.runtime = runtime
        self.hardware = hardware
    }

    // MARK: #5 动作执行链（live 真注入开关）

    /// 壳模式动作真注入开关：默认 false（digest 影子，**不产生任何按键**）。
    /// 置 true（或环境 `AURORA_RL_LIVE_ACTUATION=1` 启动）才允许 live 真注入。
    /// 双保险：即使 live 开，ControlEngine 自身的消化开关（用户开关，tick 同步）
    /// 仍在 postKeyEvent 内部把最后一道闸 —— 两闸都开才真按键。
    /// 实例属性（非环境常量）：自测与 UI 可按需切换。
    var liveActuationEnabled =
        ProcessInfo.processInfo.environment["AURORA_RL_LIVE_ACTUATION"] == "1"

    /// executor 落点（B1 线程：runtime 在**串行 actionQueue（后台线程）**调 executor；
    /// ControlEngine.hold/release 内部无锁、heldKeys 无保护，绝不能在后台线程碰）。
    /// 已在主线程则同步直发（自测直调 / 主线程投递路径，撤销哨兵绝不停滞）；
    /// 否则 main.async 跳主线程 —— **绝不能 main.sync**（主线程 stop 会等 actionQueue
    /// 排空，sync 反向等待就是死锁）。
    private func handleActionFromRuntime(_ action: RLAction, digest: Bool, sessionGen: Int) {
        let isSentinel = action.vClass < 0 || action.hClass < 0
        if Thread.isMainThread {
            // 主线程同步路径：常规采样动作须「运行中且代数未过期」——stop 之后或
            //   经历过 stop→start 的旧会话动作作废（防把键按回去）；撤销哨兵
            //   无条件放行（撤销是安全方向）。
            guard isSentinel || (running && sessionGen == shellSessionGeneration) else { return }
            hardware?.applyShellAction(action, digest: digest || !liveActuationEnabled)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 二次校验（#1）：running 之外还须代数匹配——入队到执行之间可能经历
            //   完整的 stop→start 周期，旧会话动作不得注入新会话。
            let sentinel = action.vClass < 0 || action.hClass < 0
            guard sentinel || (self.running && sessionGen == self.shellSessionGeneration) else { return }
            self.hardware?.applyShellAction(action, digest: digest || !self.liveActuationEnabled)
        }
    }

    // MARK: 启动

    /// 启动壳模式。
    /// - Parameter windowID: 只捕获该窗口；nil = 全屏。
    /// - Returns: 是否完整成功（训练失败返回 false 并给出清晰原因，但 ①②③ 已
    ///   生效 —— 引擎已退、抓屏已在跑，调 stop() 可完整恢复；绝不崩）。
    @discardableResult
    func start(windowID: UInt32?) -> Bool {
        guard !running else { return true }
        // 硬件是弱引用（防与 DriveState 单例循环）。生产实现是进程级长生单例，
        // 弱引用必不失效；若真拿不到，说明调用方生命周期管理有误，如实失败不崩。
        guard let hardware else {
            print("[ShellMode] ❌ 硬件实现已释放，无法启动壳模式")
            return false
        }

        // ① 让出后台自动驾驶引擎子进程：真 SIGTERM→SIGKILL，且不重连。
        //    复审 B4：**不用 engineActive(isActive) 前置过滤** —— 快速 stop→再 start
        //    时引擎处于「resume 轮询等待中、isActive 已 false 但旧轮询可能 startup」的
        //    窗口，若被挡住就跳过 suspend，旧轮询会把引擎拉起与壳模式抢流。
        //    suspendForLeanRecording 内部已处理「取消 pending resume + 幂等」，
        //    无条件调用让它自己判定。返回 true = 确实进入/维持了让出态。
        if hardware.suspendEngineForShellMode() {
            enginesSuspended = true
        }

        // ② 停进程内全部驾驶引擎（**只停驾驶，绝不停抓屏/速度表**）。
        //    B2：实现同时接管物理键监听 + 应急接管状态（不依赖 isDriving）。
        hardware.stopAllDrivingEngines()

        // ③ 起窗口捕获（窗口/全屏）并确保抓屏在跑（实现内含代数校验竞态防护）。
        hardware.prepareShellCapture(windowID: windowID)

        // ①②③ 已生效：此后即使 ④ 失败，stop() 也能完整清理（见 resourcesAcquired）。
        resourcesAcquired = true

        // ④ #5 动作执行链接线 + 起在线训练运行时。
        //    先注 executor 再 start：保证 runtime 启动后第一个采样动作就有落点。
        //    runtime.digestMode 是发给 executor 的 digest 入参来源；默认影子
        //    （liveActuationEnabled=false 时恒 digest），live 开才可能 false。
        runtime.digestMode = !liveActuationEnabled
        shellSessionGeneration &+= 1
        let sessionGen = shellSessionGeneration
        runtime.actionExecutor = { [weak self] action, digest in
            // sessionGen 按值捕获安装时刻的会话代数（#1）：闭包被 runtime 的后台
            // actionQueue 调用，此处不读任何主线程属性。
            self?.handleActionFromRuntime(action, digest: digest, sessionGen: sessionGen)
        }
        guard hardware.startShellTraining() else {
            let why = hardware.shellTrainingFailureReason ?? "训练运行时未就绪"
            print("[ShellMode] ❌ 训练运行时启动失败：\(why)"
                  + "（引擎已退、抓屏已在跑；点停止可完整恢复）")
            // B6：训练失败也不能让壳 executor 残留 —— 壳模式与独立「在线训练」
            // 共用同一个 runtime，残留 executor 会操纵独立训练的采样动作
            // （live 时会真注入）。digestMode 回安全默认 true。
            runtime.clearActionExecutor()
            runtime.digestMode = true
            return false
        }

        running = true
        print("[ShellMode] ▶ 壳模式已启动（窗口=\(windowID.map { "#\($0)" } ?? "全屏")）"
              + "：驾驶引擎已退、抓屏保活、训练就绪、动作链已接"
              + (liveActuationEnabled ? "（live 真注入）" : "（digest 影子）"))
        return true
    }

    // MARK: 停止

    /// 停止壳模式：收尾训练 → 撤动作链 → 释放抓屏归属 → 重新拉起普通自动驾驶引擎。
    ///
    /// 部分启动失败（训练没起来）也要能完整清理（复审 #3）：判据是
    /// `running || resourcesAcquired`，而不是只有 running。
    func stop() {
        guard running || resourcesAcquired else { return }
        running = false
        shellSessionGeneration &+= 1   // #1：立即作废在途采样动作的会话代数
        guard let hardware else {
            resourcesAcquired = false
            enginesSuspended = false
            runtime.clearActionExecutor()
            runtime.digestMode = true
            return
        }

        // ① 停训练：内部封口当前 episode + 排空训练队列 + 存盘，且一进入就失效
        //    动作会话并给旧 executor 投递 releaseAll 哨兵（runtime 自己的保证）。
        //    训练从未启动时跳过（shellTrainingRunning=false）。
        if hardware.shellTrainingRunning {
            hardware.stopShellTraining()
        }
        // 复审 B6：撤掉壳 executor + digestMode 回安全默认 true —— 壳模式与独立
        // 「在线训练」共用同一个 runtime，不撤的话退出壳后再启动独立训练会沿用
        // 旧 executor 操纵控制引擎（live 时会真注入，「只读训练」变危险）。
        runtime.clearActionExecutor()
        runtime.digestMode = true

        // ② 抓屏归属（B3：**无条件调用**——实现先作废在途壳请求，再按归属决定
        //    是否真停抓屏；有驾驶/录制等归属方时保留抓屏，但壳请求照旧作废）。
        hardware.stopShellCapture()

        // ③ 恢复自动驾驶引擎：只接回我们让出过的（复审 #2：走带时序保护的恢复路径，
        //    实现负责等旧引擎退透再 startup，并清挂起标志）。
        if enginesSuspended {
            hardware.restoreEngineAfterShellMode()
        }

        resourcesAcquired = false
        enginesSuspended = false

        print("[ShellMode] ■ 壳模式已停止：训练已收尾、动作链已撤、抓屏已按需释放、自动驾驶引擎已按需恢复")
    }
}
