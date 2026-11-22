// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  NetworkFailoverMonitor.swift — 网络定位故障 → 视觉定位兜底的状态机
// ----------------------------------------------------------------------------
//  用户需求（2026-11-20）：正常自动驾驶时网络定位是主力；哪天被玩炸了
//  （协议变了 / 抓包挂了）→ 视觉定位自动接管；网络恢复 → 切回。
//  **只有真炸了才切**。
//
//  「真炸了」的判据（三条全满足才算）：
//    ① isDriving —— 正在自动驾驶（不是训练等待期/待机）
//    ② framesAdvanced —— 画面在动（游戏明明在跑，不是游戏没开）
//    ③ !networkHealthy —— 网络定位不健康（mode 既非 "network" 也非 "stale"）
//  连续满足 ticksToEngage 个 tick（15Hz 下 150≈10s）才切 —— 单帧抖动不切。
//
//  ⚠️ "stale" 算健康：游戏 15s 才发一个坐标包，包间隙本来就是 stale
//    （历史实测），把 stale 当炸会天天误切。
//
//  「恢复」的判据（兜底期间）：抓包器有流量 且 pose 回到 live，
//  连续 ticksToRecover 个 tick（75≈5s）稳定才切回 —— 防止刚好一个包
//  就切回、结果又断的抖动循环。
//
//  纯值类型状态机：tick 主线程独占调用，无需加锁。真值表见
//  NetworkFailoverMonitorSelfTest.swift。
// ============================================================================

import Foundation

/// 网络定位故障兜底监视器：纯状态机，每 tick 喂一次 step()。
struct NetworkFailoverMonitor {

    enum Action: Equatable {
        case none       /// 本 tick 无切换
        case engage     /// 网络定位真炸了 → 视觉接管（调方调 setVisualPipeline(true)）
        case recover    /// 网络定位已恢复 → 切回网络（setVisualPipeline(false)）
    }

    /// 每 tick 的输入快照（由调用方从 DriveState 现场采）。
    struct TickInput {
        /// 正在自动驾驶（不含训练等待期/待机）。
        let isDriving: Bool
        /// 画面在动（帧序号变了 = 游戏在跑，排除「游戏没开」的常态断流）。
        let framesAdvanced: Bool
        /// 网络定位健康（networkLocateMode 为 "network" 或 "stale"）。
        let networkHealthy: Bool
        /// 抓包器 30031 有流量（恢复检测用）。
        let captureHasTraffic: Bool
        /// 网络坐标包回到 live 档（恢复检测用）。
        let poseLive: Bool
    }

    private(set) var failStreak = 0
    private(set) var okStreak = 0
    private(set) var isFallbackActive = false

    /// 触发接管的连续故障 tick 数（默认 150 ≈ 15Hz 下 10s）。
    private let ticksToEngage: Int
    /// 触发切回的连续恢复 tick 数（默认 75 ≈ 15Hz 下 5s）。
    private let ticksToRecover: Int

    init(ticksToEngage: Int = 150, ticksToRecover: Int = 75) {
        self.ticksToEngage = max(1, ticksToEngage)
        self.ticksToRecover = max(1, ticksToRecover)
    }

    mutating func step(_ input: TickInput) -> Action {
        if input.isDriving && input.framesAdvanced && !input.networkHealthy {
            // 故障累积：任一条件不成立（没在开/画面停了/网络活着）都清零。
            failStreak += 1
            okStreak = 0
            if !isFallbackActive && failStreak >= ticksToEngage {
                isFallbackActive = true
                failStreak = 0
                return .engage
            }
            return .none
        }
        failStreak = 0
        // 兜底期间的恢复检测（未兜底时 okStreak 保持 0，无副作用）。
        if isFallbackActive {
            if input.captureHasTraffic && input.poseLive {
                okStreak += 1
                if okStreak >= ticksToRecover {
                    isFallbackActive = false
                    okStreak = 0
                    return .recover
                }
            } else {
                okStreak = 0
            }
        }
        return .none
    }
}
