// ============================================================================
// ControlWiring.swift — 任务控制台 · 功能接线层
// ----------------------------------------------------------------------------
// 界面（A-任务控制中心.html 的 SwiftUI 版）与真实引擎之间的唯一通道。
//
// 原则：界面上的每一个可点元素，背后都必须有一条真的执行路径。
//       没有执行路径的，宁可不画。
//
// 接线清单：
//   ① 路况自适应 4 态  → DriveState.roadCondition（+ 自动速度联动 speedLimit）
//   ② 自动速度开关     → 按路况下发 speedLimit 到引擎 config 命令
//   ③ 四挡降级链       → forceRuleMode / degradeThreshold（引擎 config 通道）
//   ④ 限速滑块         → speedLimit（20…不限速）到引擎
//   ⑤ 18 项技能        → AgentSkillCenter.toggleSkill(id:source:.human)
//   ⑥ 引擎 9 命令      → EngineClient.sendCommand
// ============================================================================

import SwiftUI

// ============================================================================
// MARK: - 路况 → 限速 映射（自动速度的核心）
// ============================================================================

extension RoadCondition {

    /// 该路况下自动速度建议的限速值（km/h）。
    /// nil = 不限速（用户 2026-09-22 定义：框数 ≤10 直接拉到不限速）。
    var autoSpeedLimit: Double? {
        switch self {
        case .simple:  return nil   // ≤10 框：不限速
        case .easy:    return 150   // 21–30 框
        case .medium:  return 100   // 31–50 框
        case .busy:    return 60    // 51–70 框
        case .extreme: return 20    // >70 框：压到 20（最保守）
        case .off:     return nil   // 自动速度关闭：不干预
        }
    }

    /// 按检测框数量取状态色（UI 给框数上色用，与判定阈值同源）。
    static func color(forDetectionCount n: Int) -> Color {
        if n > AutoRoadCondition.extremeThreshold { return Aurora.danger }
        if n > AutoRoadCondition.busyThreshold    { return Aurora.amber }
        if n > AutoRoadCondition.mediumThreshold  { return Aurora.ice }
        if n > AutoRoadCondition.easyThreshold    { return Aurora.iceHi }
        return Aurora.ok
    }

    /// 该档是否表示「不限速」。
    /// ⚠️ 必须与 `.off`（自动速度关闭）区分开：
    ///   · .simple → 自动速度**在工作**，结论就是不限速
    ///   · .off    → 自动速度**没在工作**，不干预
    /// 两者 autoSpeedLimit 都是 nil，但语义完全不同。
    var meansUnlimited: Bool { self == .simple }

    /// 路况变化时要不要触发自动降速
    var drivesSpeed: Bool { autoSpeedLimit != nil }
}

/// 限速指令的来源，用于解决「不限速 vs 自动速度」的优先级冲突。
enum SpeedLimitSource {
    /// 用户手动（拖滑块 / 点预设 / 点路况按钮）
    case user
    /// 自动速度按路况判定下发
    case auto
    /// 当前不是不限速
    case none
}

// ============================================================================
// MARK: - 控制台接线（DriveState 的扩展）
// ============================================================================

@MainActor
extension DriveState {

    // ────────────────────────────────────────────────────────────────────
    // ① 路况切换（界面顶部 4 个按钮的真实现）
    // ────────────────────────────────────────────────────────────────────
    /// 切换路况自适应状态。
    /// - 落状态到 roadCondition（界面立即变色 / 出接管横幅）
    /// - 若「自动速度」开着，同时把限速下发引擎
    /// - 极复杂态额外把 forceRuleMode 置位（引擎端立刻切纯规则兜底）
    func applyRoadCondition(_ rc: RoadCondition) {
        guard rc != roadCondition else { return }
        roadCondition = rc

        // 极复杂 / 等待介入 → 引擎侧强制纯规则（安全优先，不等降级链慢慢降）
        // 离开极复杂 → 解除强制，让降级链自己回升
        if rc.needsTakeover {
            if !forceRuleMode {
                forceRuleMode = true
                pushConfig(reason: "路况=\(rc.rawValue)→强制规则")
            }
        } else if forceRuleMode {
            forceRuleMode = false
            pushConfig(reason: "路况=\(rc.rawValue)→解除强制规则")
        }

        // 自动速度联动。
        // ① 用户手动设的不限速优先于一切自动逻辑 —— 直接不干预。
        // ② 简单档（≤10 框）的结论就是「不限速 = 取消速度表」，要主动下发。
        // ③ 其余档位下发各自限速。
        if let target = Self.autoSpeedTarget(for: rc,
                                             currentLimit: speedLimit,
                                             unlimitedSource: unlimitedSource,
                                             enabled: autoSpeedEnabled) {
            setSpeedLimit(target,
                          reason: target >= Self.unlimitedThreshold
                                  ? "路况=\(rc.rawValue)→不限速"
                                  : "路况=\(rc.rawValue)",
                          source: .auto)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // ② 自动速度开关
    // ────────────────────────────────────────────────────────────────────
    /// 开/关自动速度。开启时立刻按当前路况下发一次限速。
    func setAutoSpeed(_ on: Bool) {
        autoSpeedEnabled = on
        // 用户手动设的不限速优先于自动速度，不覆盖
        if let target = Self.autoSpeedTarget(for: roadCondition,
                                             currentLimit: speedLimit,
                                             unlimitedSource: unlimitedSource,
                                             enabled: on) {
            setSpeedLimit(target,
                          reason: target >= Self.unlimitedThreshold
                                  ? "自动速度开启→不限速"
                                  : "自动速度开启",
                          source: .auto)
        }
    }

    /// 自动速度下一档路况（界面上的快捷切换）
    func cycleRoadCondition() {
        applyRoadCondition(roadCondition.next)
    }

    // ────────────────────────────────────────────────────────────────────
    // ③ 限速（滑块 + 预设）
    // ────────────────────────────────────────────────────────────────────
    /// 设置限速并下发。`不限速` 用 200 表示（引擎侧 speedLimit 是 Double 上限）。
    /// 限速可调范围（UI 滑杆与夹紧共用，避免两处漂移）
    static let speedLimitRange: ClosedRange<Double> = 20...200
    /// 超过此值视为「不限速」
    static let unlimitedThreshold: Double = 200

    /// 设置限速并下发。
    /// - Parameter source: 谁下的这次指令。
    ///   ⚠️ 这个参数是必须的：自动速度判到「简单」时会下发不限速，
    ///   而「不限速」本身又要优先于自动速度。若不区分来源，就会出现死锁——
    ///   自动设成不限速 → isUnlimited=true → 自动速度被自己的门禁挡住 →
    ///   框数涨回来也永远解不开。区分来源后：用户设的不限速锁死自动速度（符合
    ///   用户优先级），自动设的不限速可以被下一次自动判定覆盖。
    func setSpeedLimit(_ kmh: Double, reason: String = "手动",
                       source: SpeedLimitSource = .user) {
        let clamped = max(Self.speedLimitRange.lowerBound,
                          min(Self.speedLimitRange.upperBound, kmh))
        guard abs(clamped - speedLimit) > 0.01 else { return }
        speedLimit = clamped
        // 记录是谁把车推到「不限速」的；非不限速时清空归属
        unlimitedSource = (clamped >= Self.unlimitedThreshold) ? source : .none
        pushConfig(reason: "\(reason) 限速=\(Int(clamped))")
    }

    /// 是否处于「不限速」
    var isUnlimited: Bool { speedLimit >= Self.unlimitedThreshold }

    /// 自动速度决策 —— **纯函数**，生产路径与 --limit-selftest 共用同一份实现。
    ///
    /// 之所以抽出来：这段优先级规则此前分散在 3 处（tick 门禁 / applyRoadCondition
    /// / setAutoSpeed），任一处漏改就会出现「用户设了不限速却被打回」或
    /// 「自动设了不限速后永远解不开」的死锁。集中一处后可以直接断言。
    ///
    /// 优先级（用户明确定义，不可调换）：
    ///   用户手动不限速  >  自动速度  >  手动路况
    ///
    /// - Returns: 应当下发的限速值；`nil` = 本次不干预（保持用户现值）
    static func autoSpeedTarget(for rc: RoadCondition,
                                currentLimit: Double,
                                unlimitedSource: SpeedLimitSource,
                                enabled: Bool) -> Double? {
        guard enabled else { return nil }
        // ① 用户手动设的不限速 → 一切自动逻辑让路
        if currentLimit >= unlimitedThreshold, unlimitedSource == .user { return nil }
        // ② 简单档的结论就是「不限速 = 取消速度表」
        if rc.meansUnlimited { return unlimitedThreshold }
        // ③ 其余档位下发各自限速（.off 为 nil = 不干预）
        return rc.autoSpeedLimit
    }

    /// 当前的不限速是不是**用户手动**设的。
    /// 只有这种情况才需要锁死自动速度；自动速度自己设的不限速必须允许它自己改回来。
    var unlimitedLockedByUser: Bool { isUnlimited && unlimitedSource == .user }

    // ────────────────────────────────────────────────────────────────────
    // ④ 四挡降级链（GEAR 1..4 的真实现）
    // ────────────────────────────────────────────────────────────────────
    /// 手动切挡。
    /// 降级链本身是自动的（degradeStm 按健康度走），这里提供的是**人工干预**：
    ///   GEAR 1/2（模型侧） → 解除强制规则，让模型接回
    ///   GEAR 3/4（规则侧） → 置 forceRuleMode，引擎立刻切纯规则
    /// 界面上的高亮始终跟随 `mode`（引擎回报的真实档位），不是本地猜测。
    func selectGear(_ gear: DriveMode) {
        switch gear {
        case .e2e, .yolo:
            if forceRuleMode {
                forceRuleMode = false
                pushConfig(reason: "手切 GEAR=\(gear.rawValue)→解除强制规则")
            }
            // 模型侧两档的实际归属由降级链按模型存活情况决定，
            // 人工只能表达「我希望走模型」，不能伪造「M9 活着」。
        case .recover, .rule:
            if !forceRuleMode {
                forceRuleMode = true
                pushConfig(reason: "手切 GEAR=\(gear.rawValue)→强制规则")
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // ⑤ config 下发（唯一出口）
    // ────────────────────────────────────────────────────────────────────
    /// 把当前驾驶参数推给引擎。
    /// 引擎端对应 EngineMain.swift 的 `case "config"`，读的就是这些字段。
    func pushConfig(reason: String = "") {
        let detail: [String: Any] = [
            "sport":             sportMode,
            "controlDisabled":   controlDisabled,
            "forceRule":         forceRuleMode,
            "expert":            expertMode,
            "glyph":             glyphMode,
            "degradeThreshold":  degradeThreshold,
            "speedLimit":        speedLimit,
        ]
        EngineClient.shared.sendCommand("config", extra: detail)
        print("[WIRE] config 下发（\(reason)）：forceRule=\(forceRuleMode) "
              + "limit=\(Int(speedLimit)) thresh=\(String(format: "%.2f", degradeThreshold))")
    }

    // ────────────────────────────────────────────────────────────────────
    // ⑥ 实时运行状态：给界面底部的四条（转向/油门/刹车/速度）
    // ────────────────────────────────────────────────────────────────────
    /// 当前四条控制量的归一化快照。
    /// 转向 ±1（左负右正）、油门/刹车 0…1、速度 0…1（相对限速）。
    var driveBars: (steer: Double, throttle: Double, brake: Double, speed: Double) {
        let cmd = currentCommand
        let steerNorm = max(-1, min(1, cmd.steer))
        let thr = max(0, min(1, cmd.throttle))
        let brk = max(0, min(1, cmd.brake))
        let spd = speedLimit > 0 ? max(0, min(1, speedKmh / speedLimit)) : 0
        return (steerNorm, thr, brk, spd)
    }
}

// ============================================================================
// MARK: - 限速闭环（速度模型 → 超速 → 刹车）
// ============================================================================

/// 限速执行器：把「测到的速度 > 限速」翻译成真实按键。
///
/// 设计要点（对齐用户要求）：
///   · 触发源 = 速度模型的真实读数（speedOCR / 引擎回传），不是估算、不是编排的假值
///   · 一旦超速 → 注入**空格（手刹）+ Shift**（用户指定的刹车键组合）
///   · **纯规则覆盖**：限速刹车不走任何神经网络决策，是独立于驾驶模型之外的最后一道
///     硬闸 —— 因为「刹车」这件事不允许被模型置信度/档位切换影响。用户明确要求
///     「千万不能用模型来实现」。
///   · 不限速（speedLimit >= 200）→ **整个闭环彻底停用**，一格按键都不注入，
///     等价于「取消速度表」。不是把阈值设很大，而是直接短路。
@MainActor
final class SpeedLimitGuard {

    // ────────────────────────────────────────────────────────────────────
    // 刹车分级
    // ────────────────────────────────────────────────────────────────────
    /// 刹车分三级，逐级加码 —— 直接持续按手刹是「车辆失控」的根因：
    /// 手刹锁死后轮，高速下后轮失去抓地 → 甩尾 → 车头打转。
    /// 因此先靠松油门自然减速，不够再点刹，最后才持续刹。
    enum Stage: String {
        case none        // 未超速
        case liftOnly    // ① 只松油门 + 松极速（最温和，靠发动机制动）
        case pulse       // ② 脉冲手刹（点刹：按下/松开交替，避免后轮持续锁死）
        case firm        // ③ 持续手刹（最后手段，仍超速才用）

        var label: String {
            switch self {
            case .none:     return "待命"
            case .liftOnly: return "松油门"
            case .pulse:    return "点刹"
            case .firm:     return "持续刹"
            }
        }
    }

    // ── 分级阈值（秒）：超速持续多久后升级 ──
    /// 0 → 0.6s：仅松油门。多数情况（松油门后风阻+发动机制动）足够降到限速下
    static let pulseAfter: Double = 0.6
    /// 0.6s → 2.5s：点刹。给足时间让脉冲把速度压下来，避免过早升级成持续刹
    static let firmAfter: Double = 2.5

    // ── 脉冲参数（秒）──
    /// 点刹「按下」时长：够短，不让后轮锁死
    static let pulseOn: Double = 0.18
    /// 点刹「松开」时长：让轮胎恢复抓地
    static let pulseOff: Double = 0.22

    /// 超速多少才开始动作（km/h）。留余量避免在限速线上抖动。
    static let triggerMargin: Double = 1.0

    // ────────────────────────────────────────────────────────────────────
    // 对外状态
    // ────────────────────────────────────────────────────────────────────
    /// 当前刹车级别
    private(set) var stage: Stage = .none
    /// 本帧是否应该真的按住手刹（点刹模式下会真假交替）
    private(set) var handbrakeDown = false
    /// 已持续超速的秒数
    private(set) var overspeedSeconds: Double = 0
    /// 最近一次超速量（km/h）
    private(set) var overshoot = 0.0
    /// 本次刹车累计注入的点刹脉冲数（诊断用）
    private(set) var pulseCount = 0
    /// 是否处于刹车流程中
    var braking: Bool { stage != .none }

    /// 脉冲相位计时器
    private var phaseClock: Double = 0

    /// 每帧调用。返回 true 表示本帧应走「限速刹车」，调用方不要再执行 AI 决策键。
    func update(speedKmh: Double, speedValid: Bool, limitKmh: Double, dt: Double) -> Bool {
        // ① 不限速 = 取消闭环
        guard limitKmh < DriveState.unlimitedThreshold else {
            reset(); return false
        }
        // ② 读数不可信就不动作 —— 不能拿不可信读数去踩刹车
        guard speedValid, speedKmh >= 0 else {
            reset(); return false
        }
        // ③ 未超速 → 退出刹车
        let over = speedKmh - limitKmh
        guard over > Self.triggerMargin else {
            reset(); return false
        }

        overshoot = over
        overspeedSeconds += dt

        // ④ 分级
        if overspeedSeconds < Self.pulseAfter {
            stage = .liftOnly
            handbrakeDown = false
        } else if overspeedSeconds < Self.firmAfter {
            // 点刹：按 pulseOn / 松 pulseOff 交替
            if stage != .pulse { stage = .pulse; phaseClock = 0 }
            let cycle = Self.pulseOn + Self.pulseOff
            phaseClock += dt
            if phaseClock >= cycle { phaseClock -= cycle }
            let wasDown = handbrakeDown
            handbrakeDown = phaseClock < Self.pulseOn
            if handbrakeDown && !wasDown { pulseCount += 1 }   // 记录一次完整脉冲
        } else {
            stage = .firm
            handbrakeDown = true
        }
        return true
    }

    // ────────────────────────────────────────────────────────────────────
    // 上一次刹车过程的峰值（诊断用）
    // ────────────────────────────────────────────────────────────────────
    /// ⚠️ 为什么需要这一组：`update()` 在"已降到限速下"的那一帧会先调用 reset()
    ///    把 overspeedSeconds/stage 清零，所以调用方在刹车结束后再去读这两个字段，
    ///    读到的永远是 0 / 待命 —— 日志会显示「持续=0.0s 最高级别=待命」，
    ///    等于完全没法诊断"这次到底刹了多久、到没到持续刹那一级"。
    ///    因此 reset() 在清零前先把本轮的峰值留档。
    private(set) var lastBrakeSeconds: Double = 0
    private(set) var lastStage: Stage = .none
    private(set) var lastOvershoot: Double = 0
    private(set) var lastPulseCount: Int = 0

    func reset() {
        // 清零前留档：只有真正刹过车（stage != .none）才覆盖，避免把有效记录冲掉
        if stage != .none {
            lastBrakeSeconds = overspeedSeconds
            lastStage = stage
            lastOvershoot = overshoot
            lastPulseCount = pulseCount
        }
        stage = .none
        handbrakeDown = false
        overspeedSeconds = 0
        overshoot = 0
        phaseClock = 0
    }

    /// 一次完整刹车流程结束后清计数（重新开始计时）
    func endSession() {
        pulseCount = 0
    }
}

// ============================================================================
// MARK: - 路况自动判定（YOLO 检测框数量驱动）
// ============================================================================

/// 用 YOLO 实测检测框数量判定路况复杂度。
///
/// 用户给定阈值（2026-09-22 重定义，6 档）：
///   · 框数 > 70        → 极度复杂 → 限速 20
///   · 框数 > 50        → 繁忙     → 限速 60
///   · 框数 > 30        → 中等     → 限速 100
///   · 框数 > 20        → 轻松     → 限速 150
///   · 框数 <= 10       → 简单     → **不限速**
///   · 10 < 框数 <= 20  → 保持当前（滞回带，避免反复横跳）
///
/// 为什么用检测框数量而不是驾驶模型置信度：
///   框数是**直接观测**（YOLO 真的看到了多少个目标），可解释、可验证；
///   模型置信度是黑箱输出，用它调路况等于让模型既当运动员又当裁判 ——
///   用户明确要求「千万不能用模型来实现」。
enum AutoRoadCondition {

    /// 阈值（集中一处，便于调整 —— UI 上的说明文字也读这里，不写死数字）
    static let extremeThreshold = 70   // > 70 → 极度复杂
    static let busyThreshold    = 50   // > 50 → 繁忙
    static let mediumThreshold  = 30   // > 30 → 中等
    static let easyThreshold    = 20   // > 20 → 轻松
    static let simpleThreshold  = 10   // ≤ 10 → 简单（不限速）

    /// 由检测框数量推出路况。
    /// - Parameter current: 当前路况，用于滞回带（11…20 之间保持不动）
    /// - Returns: 建议路况；与 current 相同表示本次无需切换
    static func condition(forDetectionCount n: Int, current: RoadCondition) -> RoadCondition {
        if n > extremeThreshold { return .extreme }
        if n > busyThreshold    { return .busy }
        if n > mediumThreshold  { return .medium }
        if n > easyThreshold    { return .easy }
        if n <= simpleThreshold { return .simple }
        // 滞回带：11…20 保持原状（不满足 simple 也没到 easy）
        return current
    }

    /// 阈值说明文字（UI 直接展示，读常量以保证与判定逻辑一致）
    static var legendText: String {
        "> \(extremeThreshold) 极 · > \(busyThreshold) 繁 · > \(mediumThreshold) 中 · > \(easyThreshold) 轻 · ≤\(simpleThreshold) 不限速"
    }

    /// 稳定性门：同一判定需连续成立 N 次（约 N/30 秒）才真正切换路况。
    /// 避免单帧检测抖动导致路况/限速频繁跳变（限速一跳动就会触发刹车）。
    static let stabilityFrames = 15   // 30Hz 下约 0.5 秒
}
