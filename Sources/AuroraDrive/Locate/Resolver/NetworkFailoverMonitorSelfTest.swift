// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// 网络定位故障兜底状态机真值表自检（--failover-selftest）。纯逻辑、无 IO。

func runNetworkFailoverSelfTest() -> Int32 {
    var pass = 0
    var fail = 0
    func check(_ name: String, _ got: NetworkFailoverMonitor.Action,
               _ want: NetworkFailoverMonitor.Action) {
        if got == want { pass += 1; print("  ✅ \(name) → \(got)") }
        else { fail += 1; print("  ❌ \(name) → \(got)，期望 \(want)") }
    }
    func feed(_ m: inout NetworkFailoverMonitor, n: Int,
              driving: Bool = true, moving: Bool = true,
              healthy: Bool = false, traffic: Bool = false, live: Bool = false)
        -> NetworkFailoverMonitor.Action {
        // 聚合而非取末值：recover/engage 在循环中途触发后，后续 tick 天然返回
        // .none（状态已翻转），取"最后一个动作"会把真切换掩盖掉（实测教训：
        // n:2 的第 1 tick 触发 .recover、第 2 tick .none，末值法报假失败）。
        var fired: NetworkFailoverMonitor.Action = .none
        for _ in 0..<n {
            let a = m.step(.init(isDriving: driving, framesAdvanced: moving,
                                 networkHealthy: healthy,
                                 captureHasTraffic: traffic, poseLive: live))
            if a != .none { fired = a }
        }
        return fired
    }

    print("═══ 网络定位故障兜底自检（--failover-selftest）═══")

    // ── 不能误切的三条边界 ──
    var m1 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    check("网络 stale 不误切", feed(&m1, n: 10, healthy: true), .none)
    var m2 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    check("画面静止（游戏没开）不误切", feed(&m2, n: 10, moving: false), .none)
    var m3 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    check("非驾驶态（等待期）不误切", feed(&m3, n: 10, driving: false), .none)
    var m4 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    check("单帧抖动不切（不足阈值）", feed(&m4, n: 2), .none)
    // 抖动后清零：2 帧故障 + 1 帧健康 + 2 帧故障 → 不应累积到 3
    var m5 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    _ = feed(&m5, n: 2)
    _ = m5.step(.init(isDriving: true, framesAdvanced: true,
                      networkHealthy: true, captureHasTraffic: false, poseLive: false))
    check("故障计数遇健康清零", feed(&m5, n: 2), .none)

    // ── 真炸了才切 ──
    var m6 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    check("持续 3 tick 故障 → 接管", feed(&m6, n: 3), .engage)
    check("接管只发一次", feed(&m6, n: 5), .none)
    check("兜底激活标志", m6.isFallbackActive ? .engage : .none, .engage)

    // ── 恢复要稳定才切回 ──
    var m7 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    _ = feed(&m7, n: 3)   // 先接管
    // 恢复态 = 网络健康（healthy=true）+ 抓包有流量 + pose live。
    check("恢复 1 tick 不切回",
          feed(&m7, n: 1, healthy: true, traffic: true, live: true), .none)
    // 中间断一下（恢复中断）→ okStreak 清零
    _ = m7.step(.init(isDriving: true, framesAdvanced: true, networkHealthy: true,
                      captureHasTraffic: false, poseLive: false))
    check("恢复中断 → 不切回",
          feed(&m7, n: 1, healthy: true, traffic: true, live: true), .none)
    check("连续 2 tick 恢复 → 切回",
          feed(&m7, n: 2, healthy: true, traffic: true, live: true), .recover)
    check("切回后标志清除", m7.isFallbackActive ? .engage : .none, .none)
    check("切回后重复恢复无动作",
          feed(&m7, n: 5, healthy: true, traffic: true, live: true), .none)

    // ── 有流量但 pose 非 live（协议变了）不算恢复 ──
    var m8 = NetworkFailoverMonitor(ticksToEngage: 3, ticksToRecover: 2)
    _ = feed(&m8, n: 3)
    check("有流量但 pose 陈旧 → 不切回",
          feed(&m8, n: 10, healthy: true, traffic: true, live: false), .none)

    print("═══ 结果：\(pass) 通过 / \(fail) 失败 ═══")
    return Int32(fail)
}
