// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EmergencyTakeover.swift — 应急接管状态机（ET-1 · 2026-10-12）
// ============================================================================
//
//  【职责】当系统掉拍（tickGap > 80ms 连续 3 帧）或模型降级时，
//  自动把推理 tick 提速到 45Hz（冲刺），并弹「请接管」横幅；
//  用户按下受控键后让位到 5Hz（用户接管），松手回 20Hz（巡航）。
//
//  【状态机】（冻结契约，见 task-105 描述）
//
//    ┌──────────────────────────────────────────────────────────┐
//    │ [巡航] hz=20  takeoverActive=false                       │
//    │   │                                                      │
//    │   │ 连续3帧 tickGap>80ms  或  noteModelDegraded(true)    │
//    │   ▼                                                      │
//    │ [冲刺] hz=45  takeoverActive=true  sprinting=true        │
//    │   │  记录 sprintStart                                    │
//    │   │                                                      │
//    │   ├── noteUserKeyDown ──→ [让位] hz=5  userHoldingKey=true│
//    │   │                        │  (takeoverActive 仍 true)   │
//    │   │                        │                              │
//    │   │                        ├── noteUserKeyUp ──→ [巡航]    │
//    │   │                                                      │
//    │   └── sprintStart 超 35s 无人接管 ──→ [巡航]（保机器）    │
//    └──────────────────────────────────────────────────────────┘
//
//  【接线说明】（ET-4/ET-5 负责，本文件只管状态机本身）
//    · 调用方在 tick 里喂 noteTickGap(实际间隔 ms)
//    · YolopxEngine.isDegraded 变化时喂 noteModelDegraded
//    · KeyboardMonitor 在 takeoverActive=true 时启用监听，收到按键喂 noteUserKeyDown/Up
//    · effectiveTickHz 由 EngineMain 读，用于动态调 engineTickHz
//
//  【双进程注意】@MainActor 隔离；双进程（UI + engine）各有独立实例。
//    接线方需确认状态机放哪个进程（Lead 已标注，本文件不处理）。
//
// ============================================================================

import Foundation
import Observation

@MainActor
@Observable
final class EmergencyTakeover {

    static let shared = EmergencyTakeover()
    private init() {}

    // MARK: - 频率常量（用户拍板）

    /// 正常巡航（当前 engineTickHz 默认值）
    static let normalHz: Double = 20.0
    /// 抗系统冲刺（只提推理 tick，抓屏不动）
    static let sprintHz: Double = 45.0
    /// 用户接管让位
    static let yieldHz: Double = 5.0
    /// 冲刺上限，超时强制降回（保机器不关机）
    static let sprintMaxSeconds: Double = 35.0

    // MARK: - 触发阈值

    /// 单帧 tick 间隔超过此值即算"掉拍"（ms）
    static let takeoverTickGapMs: Double = 80.0
    /// 连续 N 帧掉拍才触发冲刺（防单次抖动误触）
    static let triggerConsecutiveMisses = 3

    // MARK: - 状态（@Observable，UI 横幅读这些）

    /// 「请接管」横幅是否显示
    private(set) var takeoverActive: Bool = false
    /// 45Hz 抗系统冲刺期
    private(set) var sprinting: Bool = false
    /// 用户按住受控键（5Hz 让位）
    private(set) var userHoldingKey: Bool = false
    /// 当前应生效 tick 频率（EngineMain 读此值动态调整）
    private(set) var effectiveTickHz: Double = 20.0 {
        didSet {
            if oldValue != effectiveTickHz {
                print("[EmergencyTakeover] effectiveTickHz: \(oldValue) → \(effectiveTickHz)")
            }
        }
    }

    // MARK: - 内部状态（实现细节，不在冻结接口里）

    /// 连续掉拍计数（巡航态用）
    private var consecutiveMisses: Int = 0
    /// 冲刺起始时间（超时判据）
    private var sprintStart: Date?

    // MARK: - 输入

    /// tick 每帧喂 tickGap（ms）；连续 N 帧 > 80ms 触发冲刺。
    ///
    /// - 巡航态：累计 consecutiveMisses，达阈值 → enterSprint
    /// - 冲刺态：检查超时（> 35s 无人接管 → enterCruise 保机器）
    /// - 让位态：用户在控制，不处理（直接 return）
    func noteTickGap(_ ms: Double) {
        // 让位态：用户在控制，tick 间隔不重要
        if userHoldingKey { return }

        // 冲刺态：检查超时（唯一退出路径之一）
        if sprinting {
            if let start = sprintStart,
               Date().timeIntervalSince(start) >= Self.sprintMaxSeconds {
                // 超过 35 秒仍无人接管 → 放弃冲刺，保机器
                enterCruise()
            }
            // 冲刺期间不累计 miss（已经在冲刺了，不需要再触发）
            return
        }

        // 巡航态：累计连续掉拍
        if ms > Self.takeoverTickGapMs {
            consecutiveMisses += 1
            if consecutiveMisses >= Self.triggerConsecutiveMisses {
                enterSprint()
            }
        } else {
            // 正常帧：重置计数（防"偶发一帧慢"误触）
            consecutiveMisses = 0
        }
    }

    /// isDegraded 变化时喂；true 触发冲刺（仅在巡航态生效）。
    func noteModelDegraded(_ d: Bool) {
        // 只在巡航态、d=true 时触发（冲刺/让位态不再重复触发）
        if d, !sprinting, !userHoldingKey {
            enterSprint()
        }
    }

    /// 用户真实按下受控键（仅在冲刺态生效 → 进入让位）。
    func noteUserKeyDown() {
        // 只在冲刺态响应（巡航态用户按键无意义；让位态已经在按键中）
        if sprinting {
            enterYield()
        }
    }

    /// 用户松开受控键（仅在让位态生效 → 回到巡航）。
    func noteUserKeyUp() {
        // 只在让位态响应
        if userHoldingKey {
            enterCruise()
        }
    }

    // MARK: - 跨进程状态同步（ET-9 · 2026-10-12）

    /// 从引擎进程同步应急状态（**仅供 UI 进程调用**）。
    ///
    /// ⚠️ 为什么需要这个方法（Lead 发现的致命缺陷）：
    ///   状态机在**两个进程各有一个实例**，互不相通：
    ///   · 引擎进程 `isActive=false` → 跑完整 tick → 本实例能触发冲刺
    ///     → `setTickHz(45)` 生效 ✅
    ///   · UI 进程 `isActive=true` → `tickEngineMode(); return` 早退
    ///     → tick 稳定 50ms（永不 >80ms）→ **本实例永不触发** ❌
    ///   而 UI 的「请接管」横幅读的是 **UI 实例** → 横幅永不显示（安全功能失效）。
    ///
    ///   修法：引擎把真实状态经 heartbeat（1Hz）回传，UI 的 `EngineClient`
    ///   解析后调本方法同步。**UI 实例只做"显示镜像"，不自己算状态**
    ///   （避免两进程各自算、结论不一致）。
    ///
    /// - Parameters:
    ///   - takeover: 引擎侧 `takeoverActive`（是否处于「请接管」告警态）
    ///   - userHolding: 引擎侧 `userHoldingKey`（用户是否正接管让位）
    func syncFromEngine(takeover: Bool, userHolding: Bool) {
        // 幂等：值没变就不写（@Observable 写会触发 UI 重绘）
        if takeoverActive != takeover { takeoverActive = takeover }
        if userHoldingKey != userHolding { userHoldingKey = userHolding }
        // 注意：**不改 effectiveTickHz** —— UI 进程不控制频率，那是引擎侧的职责。
        //   改它会让 UI 实例的 didSet 打出误导性日志。
    }

    // MARK: - 状态转换（private，内部调用）

    /// → [冲刺] hz=45  takeoverActive=true  sprinting=true
    private func enterSprint() {
        sprinting = true
        takeoverActive = true
        sprintStart = Date()
        consecutiveMisses = 0       // 重置（回到巡航后不会立即再触发）
        effectiveTickHz = Self.sprintHz
        print("[EmergencyTakeover] → 冲刺（\(Self.sprintHz)Hz）"
              + "takeoverActive=true（请接管）")
    }

    /// → [让位] hz=5  userHoldingKey=true  sprinting=false
    /// takeoverActive 保持 true（横幅可转「已接管」态，UI 用 userHoldingKey 区分）
    private func enterYield() {
        sprinting = false           // 退出 45Hz 冲刺期
        userHoldingKey = true
        effectiveTickHz = Self.yieldHz
        print("[EmergencyTakeover] → 让位（\(Self.yieldHz)Hz）用户已接管")
    }

    /// → [巡航] hz=20  全部状态归零
    private func enterCruise() {
        sprinting = false
        takeoverActive = false
        userHoldingKey = false
        sprintStart = nil
        consecutiveMisses = 0
        effectiveTickHz = Self.normalHz
        print("[EmergencyTakeover] → 巡航（\(Self.normalHz)Hz）")
    }
}
