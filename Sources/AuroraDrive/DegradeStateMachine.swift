// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  DegradeStateMachine.swift — 降级状态机
//  四档梯子：端到端主驾(E2E) → YOLO接管(第二套神经网) → 纯规则兜底 → 脱困中
//  输入：M9 存活 / 控制模型存活 / 当前档位健康度 / 车速 / 卡住时长 / 极速开关 / 暖机标记
//  输出：当前 DriveMode + 转换原因
//  设计原则：
//    1) 单调降级、滞后恢复 —— 防止在阈值附近抖动反复横跳
//    2) 极速模式覆盖一切 —— 速度优先，关闭避障，强制走 E2E
//    3) 卡住检测独立于模型 —— 即便模型很自信，车不动就脱困
//    4) 降级阈值外部可调 —— UI 滑块可实时调
// ============================================================================
import Foundation
import Observation

/// 降级状态机
/// - @Observable：让 SwiftUI 观察当前模式与内部诊断量（卡住时长等）
/// - 纯函数式转移：update(inputs) 根据输入计算下一态，无副作用
/// - 线程：仅主线程访问（与 DriveState.tick 同步调用）
@Observable
final class DegradeStateMachine {

    // MARK: - 可调阈值（与 DriveState 同步，UI 可改）

    /// 触发降级的健康度下限：当前档位驾驶模型健康度低于此值 → 降一级
    /// 典型 0.65（健康巡航 0.9+，正常不会误降；0 表示模型死）
    var degradeHealth: Double = 0.65

    /// 恢复所需的滞回量：健康度 > degradeHealth + 此值 → 回升一档
    var recoverHysteresis: Double = 0.15

    /// 卡住检测：车速低于此值视为"不动"（km/h）
    var stuckSpeedThreshold: Double = 3.0

    /// 卡住检测：持续不动超过此秒数 → 进入 ESCAPE 脱困
    var stuckTimeThreshold: Double = 3.0

    /// 脱困超时兜底（秒）：OCR 不新鲜时 speedValid 恒 false，正常退出路径失效；
    /// 脱困档累计时长超过此值强制转 .rule，避免永久卡死 .recover（不再死等 OCR）。
    /// 可调：过大脱困周期更长，过小可能未脱困即被兜底拉回。
    var recoverTimeout: Double = 30.0

    // MARK: - 状态输出

    /// 当前模式（UI 观察此属性刷新模式芯片高亮）
    private(set) var mode: DriveMode = .e2e

    /// 最近一次状态转换的原因（UI 可展示，调试用）
    private(set) var lastTransitionReason: String = "初始化"

    /// 当前连续低速时长（秒），UI 可展示诊断
    private(set) var stuckSeconds: Double = 0

    /// 极速模式是否激活（由 DriveState.sportMode 同步过来）
    private(set) var sportOverride: Bool = false

    // MARK: - 内部状态

    /// 上一帧的模式，用于检测是否发生转换
    private var previousMode: DriveMode = .e2e

    /// 脱困档累计时长（秒）：进入 .recover 时从 0 累加，离开即清零
    private var recoverElapsed: Double = 0

    /// 上次 update 调用的实际时间戳：用于 recoverElapsed 用真实经过时间累加，
    /// 不受 tick 掉拍导致的 dt=1/30 计时漂移影响（决策逻辑仍用传入 dt）。
    private var lastUpdateTime: Date?

    // MARK: - 主入口

    /// 根据输入更新状态机
    /// - Parameters:
    ///   - m9Live: 端到端模型（M9）推理链路是否存活（加载+新鲜结果）
    ///   - assistLive: 控制模型（YOLO接管档司机）推理链路是否存活
    ///   - health: 当前档位驾驶模型的健康度 [0,1]（置信度估计器输出）
    ///   - warmingUp: 启动暖机期（还没出推理结果）→ 保持档位不降级
    ///   - speedKmh: 当前有效车速 km/h
    ///   - speedValid: 有效车速是否有新鲜来源；false 时不累计卡死时长（防"读不到速度→误判卡死"）
    ///   - dt: 距离上次调用的时间间隔（秒）
    ///   - sportMode: 极速模式开关
    ///   - forceRule: 紧急切纯规则开关；true 时强制停在纯规则兜底档（最高优先，
    ///     压过极速模式；卡死仍临时进脱困，车动起来后回到纯规则）
    /// - Returns: 本次应使用的 DriveMode
    @discardableResult
    func update(m9Live: Bool,
                assistLive: Bool,
                health: Double,
                warmingUp: Bool,
                speedKmh: Double,
                speedValid: Bool,
                dt: Double,
                sportMode: Bool,
                forceRule: Bool) -> DriveMode {

        sportOverride = sportMode

        // P2 修复：recoverElapsed 改用「实际经过时间」（Date 差值）累加，不用 dt=1/30 ——
        // tick 掉拍时 dt 恒 1/30 会让脱困超时计时偏慢，可能永久卡死 .recover。
        // 卡死计时（stuckSeconds）同样改用实际经过时间累加，避免掉拍时漏判卡死；
        // dt=1/30 仅作首次调用回退，不参与后续计时。
        let now = Date()
        let actualDt: Double
        if let last = lastUpdateTime {
            actualDt = now.timeIntervalSince(last)
        } else {
            actualDt = dt   // 首次调用退化为传入 dt
        }
        lastUpdateTime = now

        // 脱困档累计时长：仅 .recover 累加；离开 .recover 即清零（下一帧生效）。
        // 与 speedValid 无关（OCR 死锁也能计时），是脱困退出兜底的时钟。
        if mode == .recover {
            recoverElapsed += actualDt
        } else {
            recoverElapsed = 0
        }

        // ── 0. 紧急切纯规则（最高优先，覆盖极速模式）──────────────
        // 紧急兜底：强制停在纯规则档；卡死仍临时进脱困，车动起来后回纯规则
        if forceRule {
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            if stuckSeconds >= stuckTimeThreshold && mode != .recover {
                transition(to: .recover, reason: "卡住 \(String(format: "%.1f", stuckSeconds))s")
            } else if mode == .recover {
                if speedValid && speedKmh > stuckSpeedThreshold * 2 {
                    stuckSeconds = 0
                    transition(to: .rule, reason: "脱困成功（纯规则）")
                } else if recoverElapsed >= recoverTimeout {
                    // 兜底：OCR 死锁（speedValid 恒 false）时不再死等，超时强制转 .rule
                    stuckSeconds = 0
                    recoverElapsed = 0
                    transition(to: .rule, reason: "脱困超时兜底（纯规则）")
                }
            } else if mode != .rule {
                transition(to: .rule, reason: "紧急切纯规则")
            }
            return mode
        }

        // ── 1. 极速模式覆盖 ──────────────────────────────────────
        // 极速优先：速度至上，关闭避障，强制 E2E 主驾
        if sportMode {
            transition(to: .e2e, reason: "极速模式覆盖")
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            return mode
        }

        // ── 1.5 启动暖机：还没出推理结果，保持当前档位不降级 ──
        // 否则启动瞬间 M9 未出结果会被当成"死了"，瞬间掉到纯规则兜底
        if warmingUp {
            updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
            return mode
        }

        // ── 2. 卡住检测（独立于模型）──────────────────────────
        updateStuckTimer(speedKmh: speedKmh, dt: actualDt, allowEscape: true, speedValid: speedValid)
        if stuckSeconds >= stuckTimeThreshold && mode != .recover {
            transition(to: .recover, reason: "卡住 \(String(format: "%.1f", stuckSeconds))s")
            return mode
        }
        // 已在脱困中：等车动起来才退出（需有新鲜速度来源，避免用衰减值误判成功）
        if mode == .recover {
            if speedValid && speedKmh > stuckSpeedThreshold * 2 {
                stuckSeconds = 0
                transition(to: .e2e, reason: "脱困成功")
            } else if recoverElapsed >= recoverTimeout {
                // 兜底：OCR 死锁（speedValid 恒 false）时不再死等，超时强制转 .rule
                stuckSeconds = 0
                recoverElapsed = 0
                transition(to: .rule, reason: "脱困超时兜底")
            }
            return mode
        }

        // ── 3. 模型存活 + 健康度驱动的四档梯子 ────────────────
        let clampedHealth = max(0.0, min(1.0, health))
        let recov = min(0.99, degradeHealth + recoverHysteresis)   // 恢复阈值（滞回）；0.99 上限保证严格 <1.0，健康度 1.0 时永远能恢复，避免 degradeHealth ≥0.85 时 recov=1.0 → clampedHealth>1.0 永不成立 → 永久卡最低档（P0-1 死锁）
        switch mode {
        case .e2e:
            // 档1 端到端主驾：M9 死了（或 E2E 被禁用）或健康度低 → 掉到档2 YOLO接管
            if !m9Live || clampedHealth < degradeHealth {
                transition(to: .yolo, reason: "M9 不可用（健康 \(pct(clampedHealth))）")
            }

        case .yolo:
            // 档2 YOLO接管：控制模型也死了 → 掉到档4 纯规则兜底
            if !assistLive || clampedHealth < degradeHealth {
                transition(to: .rule, reason: "控制模型不可用（健康 \(pct(clampedHealth))）")
            } else if m9Live && clampedHealth > recov {
                // M9 回来了（且 E2E 未被禁用）→ 回升档1 端到端主驾
                transition(to: .e2e, reason: "M9 恢复（健康 \(pct(clampedHealth))）")
            }

        case .rule:
            // 档4 纯规则兜底：控制模型活过来 → 回升档2 YOLO接管
            if assistLive && clampedHealth > recov {
                transition(to: .yolo, reason: "控制模型恢复（健康 \(pct(clampedHealth))）")
            }

        case .recover:      // 脱困态由卡住检测管理，这里不处理
            break
        }
        return mode
    }

    // MARK: - 卡住计时器

    /// 更新低速持续时长
    /// - allowEscape: 是否允许触发 ESCAPE（极速模式仍允许，因为它只覆盖置信度路径）
    /// - speedValid: 有效车速是否有新鲜来源；false 时既不累计也不清零（速度未知不判定卡死）
    private func updateStuckTimer(speedKmh: Double, dt: Double, allowEscape: Bool, speedValid: Bool) {
        guard speedValid else { return }   // 读不到速度：不计入卡死，避免误判脱困
        if speedKmh < stuckSpeedThreshold {
            stuckSeconds += dt
        } else {
            // 车动了，计时器快速衰减（0.5s 内清零，避免长尾）
            stuckSeconds = max(0, stuckSeconds - dt * 2)
        }
    }

    // MARK: - 状态转换

    /// 执行状态转换并记录原因
    private func transition(to newMode: DriveMode, reason: String) {
        guard newMode != mode else { return }
        previousMode = mode
        mode = newMode
        lastTransitionReason = reason
    }

    /// 重置到初始态（停止自动驾驶时调用）
    func reset() {
        mode = .e2e
        previousMode = .e2e
        stuckSeconds = 0
        recoverElapsed = 0
        lastUpdateTime = nil
        lastTransitionReason = "已重置"
        sportOverride = false
    }

    // MARK: - 格式化辅助

    /// 置信度百分比字符串
    private func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}
