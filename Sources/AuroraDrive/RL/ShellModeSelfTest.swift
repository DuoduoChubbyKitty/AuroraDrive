// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ShellModeSelfTest.swift — 壳模式 start()/stop() 合成自测
//  （`--shell-engine-selftest` / `-shell-engine-selftest`）
//
//  【为什么这样测】
//    壳模式 start() 的正常路径会真的：kill 引擎子进程、建 SCStream 抓屏、起在线
//    训练（吃 CoreML 加速器）。这三件事在本机都**不能真跑**（用户硬性约束：不真
//    开游戏、不真训练、不拉引擎）。所以本自测用假硬件 `FakeShellHardware` 只记录
//    「被调用了什么、按什么顺序」—— 这恰好就是验收要的「退引擎调用 / 抓屏保活 /
//    stop 恢复 startup 的调用轨迹」。它验证的是 `ShellModeController` 的真实编排
//    逻辑（不是另写一份逻辑），生产路径与自测路径共享同一份 start()/stop() 代码。
//
//  【复审 5 条阻断的回归覆盖（2026-11-17 Codex 复审）】
//    · #1 单例重入：假硬件只经 `init(runtime:hardware:)` 构造（便捷 init 已删除）；
//      另做**源码级断言** —— 读 ShellModeController.swift 源码，注释行以外的代码
//      不得出现 `DriveState.shared`；生产调用点必须是 `hardware: self` 直传。
//    · #2 恢复绕过时序：假硬件镜像 EngineClient 的 `suspendedByLeanRecording`
//      幂等标志语义 —— restore 不清标志时，第二次 suspend 会「跳过但仍返回 true」。
//      场景④断言第二个 start/stop 周期里 suspend 是**真的再次发生**（无 SKIPPED）。
//    · #3 部分启动失败：训练失败（start 返回 false）后，stop() 仍必须走完整清理
//      （停训练→停抓屏→恢复引擎）—— 控制器用 resourcesAcquired 区分两层状态。
// ============================================================================

import Foundation

/// 假硬件：不碰任何真实引擎，只把编排调用按序记进 `log`。
///
/// `suspendFlag` 镜像真实 `EngineClient.suspendedByLeanRecording` 的幂等语义：
/// suspend 置位、restore 清位；标志残留时再次 suspend 会**跳过真退引擎却返回 true**
/// —— 这正是复审 #2 描述的真实事故形态，用它就能在合成环境里抓住「stop 没走
/// 带时序保护的恢复路径」的回归。reset() 只清日志，**刻意不清 suspendFlag**。
@MainActor
private final class FakeShellHardware: ShellModeHardware {
    var engineActive = false
    var trainingStartsOK = true
    var otherCaptureOwner = false
    private(set) var log: [String] = []
    private(set) var captureStopped = false
    private var trainingRunning = false
    /// 镜像 EngineClient.suspendedByLeanRecording：跨 start/stop 周期持久。
    private var suspendFlag = false

    var shellTrainingFailureReason: String?
    var shellTrainingRunning: Bool { trainingRunning }
    var hasOtherCaptureOwner: Bool { otherCaptureOwner }

    func reset() { log.removeAll(); captureStopped = false }

    @discardableResult
    func suspendEngineForShellMode() -> Bool {
        if suspendFlag {
            log.append("suspendEngineForShellMode(SKIPPED:staleFlag)")
            return true
        }
        // 真实 EngineClient.suspendForLeanRecording：guard isActive||enginePID||hadPendingResume
        //   否则 return false（引擎本没起、也没待恢复 → 无可让出）。
        if !engineActive {
            log.append("suspendEngineForShellMode(noop:nothingToSuspend)")
            return false
        }
        log.append("suspendEngineForShellMode")
        suspendFlag = true
        engineActive = false
        return true
    }

    func stopAllDrivingEngines() { log.append("stopAllDrivingEngines") }

    func prepareShellCapture(windowID: UInt32?) {
        log.append("prepareShellCapture(window=\(windowID.map { "#\($0)" } ?? "nil"))")
    }

    /// B3 镜像真实 DriveState.stopShellCapture：控制器 stop **无条件**调用本方法
    /// （先作废全部在途壳请求——无条件），再按归属决定是否真停抓屏：
    /// 有其他归属方（otherCaptureOwner）时保活（captureStopped 不置位）。
    func stopShellCapture() {
        log.append("stopShellCapture")
        if !otherCaptureOwner { captureStopped = true }
    }

    func startShellTraining() -> Bool {
        log.append("startShellTraining")
        guard trainingStartsOK else {
            shellTrainingFailureReason = "synthetic：state_token 加速器不可用"
            return false
        }
        shellTrainingFailureReason = nil
        trainingRunning = true
        return true
    }

    func stopShellTraining() { log.append("stopShellTraining"); trainingRunning = false }

    /// #5 动作执行链：记录每帧动作（供自检断言 executor 真被调用、参数正确、digest 透传）。
    private(set) var appliedActions: [(vClass: Int, hClass: Int, digest: Bool)] = []
    func applyShellAction(_ action: RLAction, digest: Bool) {
        appliedActions.append((action.vClass, action.hClass, digest))
        log.append("applyShellAction(v=\(action.vClass),h=\(action.hClass),digest=\(digest))")
    }

    /// 镜像真实 resumeAfterLeanRecording：清幂等标志 + 引擎回到激活态。
    func restoreEngineAfterShellMode() {
        log.append("restoreEngineAfterShellMode")
        suspendFlag = false
        engineActive = true
    }
}

enum ShellModeControllerSelfTest {

    /// 入口（由启动器分发 `--shell-engine-selftest` 时调用）。返回失败项数，0 = 全过。
    @MainActor
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
        func pos(_ log: [String], _ s: String) -> Int { log.firstIndex(of: s) ?? -1 }
        func posPrefix(_ log: [String], _ p: String) -> Int {
            log.firstIndex(where: { $0.hasPrefix(p) }) ?? -1
        }

        print("═══ 壳模式 start/stop 合成自测（--shell-engine-selftest，假硬件·不碰真引擎/不训练）═══")
        // 运行时只是构造占位（构造不加载模型、不推理）；假硬件路径根本不会调用它。
        let runtime = OnlineTrainingRuntime()

        // ── 场景 1：正常启动（引擎激活 + 指定窗口）──
        let hw1 = FakeShellHardware()
        hw1.engineActive = true
        let ctl1 = ShellModeController(runtime: runtime, hardware: hw1)
        let ok1 = ctl1.start(windowID: 123)
        print("  [启动轨迹] " + hw1.log.joined(separator: " → "))
        check("start 返回 true", ok1)
        check("running == true", ctl1.running)
        check("① 先真退引擎子进程(suspendForLeanRecording)", hw1.log.first == "suspendEngineForShellMode")
        check("② 退所有驾驶引擎", hw1.log.contains("stopAllDrivingEngines"))
        check("③ 起窗口捕获（带窗口号）", hw1.log.contains("prepareShellCapture(window=#123)"))
        check("④ 起训练", hw1.log.contains("startShellTraining"))
        check("启动全程绝不停抓屏（抓屏保活）", !hw1.captureStopped)
        check("启动顺序正确：退引擎→退驾驶→备抓屏→起训练",
              pos(hw1.log, "suspendEngineForShellMode") < pos(hw1.log, "stopAllDrivingEngines")
              && pos(hw1.log, "stopAllDrivingEngines") < posPrefix(hw1.log, "prepareShellCapture")
              && posPrefix(hw1.log, "prepareShellCapture") < pos(hw1.log, "startShellTraining"))

        // ── 场景 2：重复 start 幂等（不重复退引擎）──
        hw1.reset()
        let ok2 = ctl1.start(windowID: 123)
        check("重复 start 幂等返回 true", ok2)
        check("重复 start 不再产生任何调用", hw1.log.isEmpty, hw1.log.joined(separator: ","))

        // ── 场景 3：正常 stop（无其他抓屏归属方）──
        hw1.reset()
        ctl1.stop()
        print("  [停止轨迹] " + hw1.log.joined(separator: " → "))
        check("stop 后 running == false", !ctl1.running)
        check("① 先停训练", hw1.log.first == "stopShellTraining")
        check("② 释放抓屏（无其他归属方）", hw1.log.contains("stopShellCapture"))
        check("③ 恢复自动驾驶引擎（带时序保护的 resume）", hw1.log.last == "restoreEngineAfterShellMode")
        check("stop 顺序正确：停训练→停抓屏→恢复引擎",
              pos(hw1.log, "stopShellTraining") < pos(hw1.log, "stopShellCapture")
              && pos(hw1.log, "stopShellCapture") < pos(hw1.log, "restoreEngineAfterShellMode"))
        hw1.reset(); ctl1.stop()
        check("重复 stop 幂等（无重复调用）", hw1.log.isEmpty)

        // ── 场景 4（复审 #2 回归）：第二个 start/stop 周期，引擎必须被**真的再次** suspend ──
        // 假硬件镜像 EngineClient 的幂等标志：若上个周期的 stop 没走恢复路径（没清标志），
        // 这次的 suspend 会变成 SKIPPED —— 测试立刻红。
        let ok4 = ctl1.start(windowID: 123)
        print("  [二次启动轨迹] " + hw1.log.joined(separator: " → "))
        check("二次 start 返回 true", ok4)
        check("二次 start 真的再次退引擎（无 staleFlag 跳过）",
              !hw1.log.contains("suspendEngineForShellMode(SKIPPED:staleFlag)")
              && hw1.log.contains("suspendEngineForShellMode"),
              hw1.log.joined(separator: ","))
        hw1.reset()
        ctl1.stop()
        check("二次 stop 恢复引擎", hw1.log.contains("restoreEngineAfterShellMode"))
        check("二次 stop 后可再入（无跳过残留）",
              !hw1.log.contains("suspendEngineForShellMode(SKIPPED:staleFlag)"))
        hw1.reset()

        // ── 场景 5：抓屏保活 —— 有其他归属方时 stop 不停抓屏 ──
        let hw5 = FakeShellHardware()
        hw5.engineActive = true
        hw5.otherCaptureOwner = true
        let ctl5 = ShellModeController(runtime: runtime, hardware: hw5)
        _ = ctl5.start(windowID: nil)
        hw5.reset()
        ctl5.stop()
        print("  [保活停止轨迹] " + hw5.log.joined(separator: " → "))
        // B3：控制器 stop 无条件调 stopShellCapture（作废在途壳请求照常发生），
        //   但有其他抓屏归属方时**真停不发生**（保活）。
        check("有其他抓屏归属方 → 真停抓屏不发生（保活；B3：作废壳请求照常）",
              hw5.log.contains("stopShellCapture") && !hw5.captureStopped)
        check("仍需停训练", hw5.log.contains("stopShellTraining"))
        check("仍恢复引擎", hw5.log.contains("restoreEngineAfterShellMode"))

        // ── 场景 6：引擎本未激活 → 不调 suspend；stop 也不拉起（保持原状态）──
        let hw6 = FakeShellHardware()
        hw6.engineActive = false
        let ctl6 = ShellModeController(runtime: runtime, hardware: hw6)
        _ = ctl6.start(windowID: nil)
        print("  [未激活引擎启动轨迹] " + hw6.log.joined(separator: " → "))
        // 复审 B4：现在**无条件尝试 suspend**（不再用 engineActive 前置过滤，以取消可能的
        //   pending resume）；但引擎本没起时 suspend 返回 false（无可让出）→ 不记 enginesSuspended。
        check("引擎本未激活 → 仍尝试 suspend（B4：取消 pending resume 需要它）",
              hw6.log.contains("suspendEngineForShellMode(noop:nothingToSuspend)"))
        check("但仍退驾驶引擎", hw6.log.contains("stopAllDrivingEngines"))
        check("全屏捕获（window=nil）", hw6.log.contains("prepareShellCapture(window=nil)"))
        hw6.reset()
        ctl6.stop()
        check("引擎本未起 → stop 不拉起引擎（保持原状态）",
              !hw6.log.contains("restoreEngineAfterShellMode"))
        check("引擎本未起 → stop 仍释放抓屏（无其他归属方）", hw6.log.contains("stopShellCapture"))

        // ── 场景 7（复审 #3 回归）：训练启动失败 → start 返回 false，stop 仍完整清理 ──
        let hw7 = FakeShellHardware()
        hw7.engineActive = true
        hw7.trainingStartsOK = false
        let ctl7 = ShellModeController(runtime: runtime, hardware: hw7)
        hw7.reset()
        let ok7 = ctl7.start(windowID: 42)
        print("  [训练失败轨迹] " + hw7.log.joined(separator: " → "))
        check("训练失败 → start 返回 false", !ok7)
        check("训练失败 → running 仍为 false", !ctl7.running)
        check("训练失败但引擎已退", hw7.log.contains("suspendEngineForShellMode"))
        check("训练失败但驾驶引擎已退", hw7.log.contains("stopAllDrivingEngines"))
        check("训练失败但抓屏已备好（保活）", hw7.log.contains("prepareShellCapture(window=#42)"))
        // 关键：部分失败后 stop() 必须走完整清理，而不是因 running=false 空转。
        hw7.reset()
        ctl7.stop()
        print("  [部分失败后停止轨迹] " + hw7.log.joined(separator: " → "))
        check("部分失败后 stop 释放抓屏（不空转）", hw7.log.contains("stopShellCapture"))
        check("部分失败后 stop 恢复引擎（不空转）", hw7.log.contains("restoreEngineAfterShellMode"))
        check("部分失败后 stop 不再误停训练（训练从未起）", !hw7.log.contains("stopShellTraining"))
        hw7.reset()
        ctl7.stop()
        check("部分失败清理后再 stop 幂等（资源位已清）", hw7.log.isEmpty)

        // ── 场景 8（复审 #1 源码级断言）：控制器源码无 DriveState.shared 代码引用 ──
        checkSourceLevelNoSharedRefs(&failures, check: check)

        // ── 场景 9（复审 #5 动作执行链）：RL 动作→键位映射纯函数正确 ──
        let p00 = DriveState.shellActionKeyPlan(vClass: 0, hClass: 0)   // 给油+左
        check("#5 映射：v0→hold油门、release刹车", p00.hold.contains(.throttle) && p00.release.contains(.brake))
        check("#5 映射：h0→hold左转、release右转", p00.hold.contains(.steerLeft) && p00.release.contains(.steerRight))
        let p21 = DriveState.shellActionKeyPlan(vClass: 2, hClass: 1)   // 刹车+直行
        check("#5 映射：v2→hold刹车、release油门", p21.hold.contains(.brake) && p21.release.contains(.throttle))
        check("#5 映射：h1(直行)→release双侧转向", p21.release.contains(.steerLeft) && p21.release.contains(.steerRight) && p21.hold.isEmpty == false)
        let p11 = DriveState.shellActionKeyPlan(vClass: 1, hClass: 1)   // 全不动
        check("#5 映射：v1/h1→无hold、release全部四键", p11.hold.isEmpty && p11.release.count == 4)

        // ── 场景 10（B2 保键源码级断言）：applyShellAction 三路径均保留人的物理键 ──
        checkSourceLevelReleaseAIKeys(&failures, check: check)

        print(failures == 0 ? "═══ 结果：全部通过 ✅ ═══" : "═══ 结果：\(failures) 项失败 ❌ ═══")
        return failures
    }

    /// #1 的源码级断言：读源文件，注释行以外的代码不得引用 DriveState.shared；
    /// 生产调用点必须是 `hardware: self` 直传。文件不可读时如实 SKIP（不冒充通过）。
    private static func checkSourceLevelNoSharedRefs(
        _ failures: inout Int,
        check: (String, Bool, String) -> Void
    ) {
        let thisFile = URL(fileURLWithPath: #filePath)
        let controllerURL = thisFile.deletingLastPathComponent()
            .appendingPathComponent("ShellModeController.swift")
        let appURL = thisFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/AuroraDriveApp.swift")

        guard let controllerSrc = try? String(contentsOf: controllerURL, encoding: .utf8),
              let appSrc = try? String(contentsOf: appURL, encoding: .utf8) else {
            print("  ⚠️ SKIP：源码文件不可读（\(controllerURL.lastPathComponent) / AuroraDriveApp.swift），跳过 #1 源码级断言")
            return
        }
        // 剥掉纯注释行（解释性注释里允许提到 DriveState.shared）。
        let codeLines = controllerSrc.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let offenders = codeLines.filter { $0.contains("DriveState.shared") }
        check("控制器源码（非注释行）无 DriveState.shared 引用（复审 #1）",
              offenders.isEmpty,
              offenders.map { String($0.trimmingCharacters(in: .whitespaces)).prefix(60) }
                  .joined(separator: " | "))
        // 注意：check 作为函数值传入后默认参被擦除，这里必须显式传第 3 参。
        check("生产构造点直传 self（hardware: self，复审 #1）",
              appSrc.contains("ShellModeController(runtime: self.onlineTrainRuntime, hardware: self)"),
              "期望 AuroraDriveApp.swift: ShellModeController(runtime: self.onlineTrainRuntime, hardware: self)")
    }

    /// B2 的源码级断言：读 AuroraDriveApp.swift，applyShellAction 的三条路径
    /// （人工接管 / 撤销哨兵 / 正常采样）都必须走 releaseAIHeldKeys(preserving:)
    /// 保留人的物理键，且函数体内不得出现裸 releaseAll（会把用户正按的键抬起来）。
    /// 行为级自测做不了的原因：ControlEngine.hold() 有 hasAccessibilityPermission
    /// 早退（合成环境灌不进键），heldKeys 是 private(set)。文件不可读时如实 SKIP
    ///（不冒充通过）。
    private static func checkSourceLevelReleaseAIKeys(
        _ failures: inout Int,
        check: (String, Bool, String) -> Void
    ) {
        let thisFile = URL(fileURLWithPath: #filePath)
        let appURL = thisFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/AuroraDriveApp.swift")

        guard let appSrc = try? String(contentsOf: appURL, encoding: .utf8) else {
            print("  ⚠️ SKIP：源码文件不可读（AuroraDriveApp.swift），跳过 B2 保键源码级断言")
            return
        }
        // 定位 applyShellAction 函数体：从函数签名行起到下一个同等缩进的成员声明。
        let lines = appSrc.split(separator: "\n", omittingEmptySubsequences: true)
        guard let sigIdx = lines.firstIndex(where: {
            $0.contains("func applyShellAction(_ action: RLAction, digest: Bool)")
        }) else {
            check("B2：找到 applyShellAction 函数（源码级）", false,
                  "AuroraDriveApp.swift 中未找到函数签名")
            return
        }
        // 函数体：签名行之后、下一个 4 空格缩进的成员级声明（"func "/"var "/"let " 起）之前的所有行。
        var body: [Substring] = []
        for line in lines[(sigIdx + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("func ") || t.hasPrefix("var ") || t.hasPrefix("let ") {
                if line.hasPrefix("    ") && !line.hasPrefix("        ") { break }
            }
            body.append(line)
        }
        let bodyText = body.joined(separator: "\n")
        // 剥掉纯注释行后的代码行（与 #1 同款：注释里允许提关键字）。
        let codeLines = body.filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let codeText = codeLines.joined(separator: "\n")

        // 三条路径各自保留人的物理键：接管分支、哨兵分支、消化影子分支。
        // 判据：分支内含 releaseAIHeldKeys(preserving: humanKeys（humanKeys 来自
        // keyboardMonitor.heldKeys，即物理按住的键集）。
        check("B2 保键：人工接管分支撤 AI 键保留物理键（releaseAIHeldKeys(preserving:)）",
              codeText.contains("EmergencyTakeover.shared.userHoldingKey")
                  && codeText.contains("releaseAIHeldKeys(preserving: humanKeys)"), "")
        check("B2 保键：撤销哨兵分支保留物理键",
              codeText.contains("isSentinel")
                  && codeText.contains("releaseAIHeldKeys(preserving: humanKeys)"), "")
        check("B2 保键：无裸 releaseAll（不得把用户正按的键抬起来）",
              !codeText.contains("releaseAll()")
                  && !codeText.contains("releaseAll("),
              "applyShellAction 代码行不得出现裸 releaseAll")
        // #6：实现不得把**入参 digest** 写进 controlEngine.digestMode（与 tick 每帧
        //   按用户设置写回竞争，最坏 keyUp 被消化 → 键卡死）。释放旁路的临时
        //   `= false` / `= savedDigest`（同线程保存-恢复，保证 keyUp 真发）不属此列。
        let digestWrites = codeLines.filter {
            $0.contains("controlEngine.digestMode") && $0.contains("= digest")
        }
        check("B2/#6：applyShellAction 不直写 controlEngine.digestMode（防键卡死）",
              digestWrites.isEmpty,
              digestWrites.map { String($0.trimmingCharacters(in: .whitespaces)).prefix(70) }
                  .joined(separator: " | "))
    }
}
