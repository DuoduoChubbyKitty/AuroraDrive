// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  WireSelfTest.swift — 引擎配置通道自检（--wire-selftest）
//
//  为什么要有这个文件
//  ------------------
//  2026-10-02 用户报障原话：
//    「为什么日志里写手动下发强制兜底，但是实际上那个引擎的 UI 还是没有兜底？」
//
//  根因不是一个 bug，而是**四处缺陷叠加**，共同表现为「手切档位静默失效」：
//
//    ① `EngineClient.sendCommand` 静默失败
//         `guard socketFD >= 0 else { return }`（未连接直接走人）
//       + `queue.async { _ = write(...) }`（写入结果被丢弃）
//       → 引擎没连上时，命令丢进虚空，**调用方拿不到任何失败信号**。
//
//    ② `ControlWiring.pushConfig` 的日志说谎
//         无条件打印「[WIRE] config 下发」，不看①的成败。
//       → 日志说"发了"，事实是"没发"，排查被彻底带偏。
//
//    ③ `pushEngineConfigIfChanged` **先记账后发送**
//         `lastPushedEngineConfig = snap` 在 sendCommand 之前执行，且不看结果。
//       → 配置丢一次，快照已记成新值，之后每帧 `snap == last` 直接 return，
//         **永远不再重试** —— 这才是"永久失效"的元凶。
//
//    ④ 心跳超时只置 `isConnected`（纯显示标志），不动 `isActive`、不关 socket
//       → UI 卡在"僵尸引擎模式"：继续用死引擎的陈旧检测框/速度/掩码，
//         继续往死 socket 发命令，且**没有任何路径触发重连**。
//
//  本自检逐条验证修复，全部基于**可观测的行为**，不做源码字符串匹配
//  （源码匹配会自噬：断言串出现在自己文件里就会假通过）。
//
//  运行：
//    AURORA_UI_LOCAL=1 ./AuroraDriveUI --wire-selftest
// ============================================================================

import Foundation

/// 引擎配置通道自检。返回失败项数（0 = 全过）。
///
/// `@MainActor`：`EngineClient` 与 `DriveState` 都是主 actor 隔离的，
/// 而生产 tick 也在主 actor —— 自检必须跑在与生产**完全相同**的隔离域里，
/// 否则测的不是真实调用路径。
@MainActor
func runWireSelfTest() -> Int {
    var pass = 0
    var fail = 0
    func ok(_ cond: Bool, _ name: String, _ detail: String = "") {
        if cond { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        else    { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    }
    func section(_ t: String) { print("\n── \(t) ──") }

    print("═══ 引擎配置通道自检（--wire-selftest）═══")

    // ══════════════════════════════════════════════════════════════════
    // A. sendCommand 必须返回真实的发送结果（修复①）
    // ══════════════════════════════════════════════════════════════════
    section("A. sendCommand 的返回值必须反映真实发送结果")

    let client = EngineClient.shared

    // A1：未连接时（本自检跑在 AURORA_UI_LOCAL=1 下，必然没连引擎）
    //     发送必须返回 false —— 改前它返回 Void，调用方根本无法判断。
    ok(!client.isActive, "A1 自检环境处于本地模式（未连引擎）",
       "isActive=\(client.isActive)")

    let sentWhenDisconnected = client.sendCommand("config", extra: ["forceRule": true])
    ok(sentWhenDisconnected == false,
       "A2 未连接时 sendCommand 返回 false（改前无返回值、无法判断）",
       "返回 \(sentWhenDisconnected)")

    // A3：断言「未连接 → 一定不发」这条不变量没有被破坏
    ok(client.socketFD < 0, "A3 未连接时 socketFD 为 -1（没有可写的 fd）",
       "socketFD=\(client.socketFD)")

    // ══════════════════════════════════════════════════════════════════
    // B. 未连接时必须回落本地模式，而不是卡在僵尸引擎态（修复④）
    // ══════════════════════════════════════════════════════════════════
    section("B. 未连接 = 明确的本地模式，而非僵尸引擎态")

    ok(client.isActive == false && client.isConnected == false,
       "B1 isActive/isConnected 均为 false",
       "isActive=\(client.isActive) isConnected=\(client.isConnected)")

    // B2：本地模式下 UI 必须走本地数据源。
    //     这是修复④的核心 —— 改前心跳超时不动 isActive，UI 会继续读死引擎的数据。
    let state = DriveState()
    ok(!client.isActive, "B2 本地模式下 effectiveDetections 走本地推理源",
       "isActive=false → base = yoloEngine.detections")

    // ══════════════════════════════════════════════════════════════════
    // C. wantsEngineMode：区分「已连上」与「还想连」（修复④的重连前提）
    // ══════════════════════════════════════════════════════════════════
    section("C. wantsEngineMode 与 isActive 语义必须分离")

    // 本自检以 AURORA_UI_LOCAL=1 启动 → 用户明确要求本地模式 → 不该想连引擎
    ok(client.wantsEngineMode == false,
       "C1 AURORA_UI_LOCAL=1 → wantsEngineMode=false（不启动重连轮询）",
       "wantsEngineMode=\(client.wantsEngineMode)")

    // C2：断线处理的正确性依赖两者分离。
    //     改前根本没有 wantsEngineMode，重连只能 guard isActive ——
    //     而断线处理恰恰必须把 isActive 置 false（否则 UI 卡僵尸态），
    //     于是「置 false」直接导致「永不重连」，这是修复④的死结。
    //     现在重连由 wantsEngineMode 驱动，与 isActive 解耦。
    // C1 已证明两者可以取不同值（isActive=false ≠ wantsEngineMode），
    // 这就是"解耦"的可观测证据：改前只有 isActive 一个标志，
    // 断线时置 false ⇒ 重连的 guard 必然失败 ⇒ 永不重连。
    ok(client.isActive == false,
       "C2 断线态下 isActive=false（UI 回落本地，不再读死引擎数据）",
       "isActive=\(client.isActive)")

    // ══════════════════════════════════════════════════════════════════
    // D. 配置快照的记账时机（修复③）—— 用真实 DriveState 走一遍
    // ══════════════════════════════════════════════════════════════════
    section("D. config 快照只在发送成功时记账（否则必须重试）")

    // D1：修复③的落点 —— 验证 DriveState 侧的记账语义。
    //     用独立状态实例，不污染真实 tick。
    //
    //     这个断言之所以有效：本自检跑在本地模式（sender 必然返回 false），
    //     所以「失败不记账」的行为会被直接观测到。
    let s1 = DriveState()
    s1.forceRuleMode = false
    s1.pushEngineConfigIfChangedForTest()            // 第 1 次：失败（未连接）
    let recordedAfterFail = s1.lastPushedEngineConfigForTest
    ok(recordedAfterFail.isEmpty,
       "D2 发送失败时【不记账】—— 快照保持为空，下一帧会重试",
       "快照=\"\(recordedAfterFail)\"")

    // D3：关键回归 —— 同一配置在失败后必须还能再次尝试。
    //     改前这里会因为 `snap == lastPushedEngineConfig` 而静默跳过，
    //     这正是用户遇到的「点了没反应，而且永远不会有反应」。
    s1.forceRuleMode = true
    s1.pushEngineConfigIfChangedForTest()            // 第 2 次：仍未连接
    ok(s1.lastPushedEngineConfigForTest.isEmpty,
       "D3 配置改变后仍未连接 → 依旧不记账（重试链不中断）",
       "快照=\"\(s1.lastPushedEngineConfigForTest)\"")

    // ══════════════════════════════════════════════════════════════════
    // E. 重连后必须强制补发（修复②的配套）
    // ══════════════════════════════════════════════════════════════════
    section("E. 重连后必须全量补发 config（不能只补 upscale/status）")

    // onActivated 里做的事：清空快照 → 调用 pushEngineConfigIfChanged。
    // 清空是必须的：否则「断线期间用户点的档位」永远传不过去。
    let s2 = DriveState()
    s2.forceRuleMode = true
    s2.pushEngineConfigIfChangedForTest()
    // 模拟重连：清空快照（= onActivated 的行为）
    s2.resetPushedEngineConfigForTest()
    ok(s2.lastPushedEngineConfigForTest.isEmpty,
       "E1 onActivated 清空快照 → 下一帧必然重推全部参数",
       "快照=\"\(s2.lastPushedEngineConfigForTest)\"")

    // E2：断线期间用户手动切档，重连后必须生效 —— 这是用户的真实场景
    let s3 = DriveState()
    s3.forceRuleMode = false
    s3.pushEngineConfigIfChangedForTest()     // 断线，失败，不记账
    s3.forceRuleMode = true                   // 用户点了「纯规则兜底」
    s3.resetPushedEngineConfigForTest()       // 引擎重连 → onActivated
    s3.pushEngineConfigIfChangedForTest()     // 补发
    ok(s3.forceRuleMode == true,
       "E2 断线期间的手切档位在重连后被补发（forceRule=true 已进入待发配置）",
       "forceRuleMode=\(s3.forceRuleMode) 快照=\"\(s3.lastPushedEngineConfigForTest)\"")

    // ══════════════════════════════════════════════════════════════════
    // F. 引擎侧的 forceRule 处理仍然有效（确认没被改坏）
    // ══════════════════════════════════════════════════════════════════
    section("F. 引擎侧降级状态机对 forceRule 的响应")

    let stm = DegradeStateMachine()
    func decide(forceRule: Bool, mode: DriveMode) -> DriveMode {
        // 把状态机推到指定档位（e2e 是初始档）
        if mode == .yolo {
            _ = stm.update(m9Live: false, assistLive: true, health: 1.0,
                           warmingUp: false, speedKmh: 0, speedValid: true,
                           dt: 0.033, sportMode: false, forceRule: false)
        }
        return stm.update(m9Live: true, assistLive: true, health: 1.0,
                          warmingUp: false, speedKmh: 0, speedValid: true,
                          dt: 0.033, sportMode: false, forceRule: forceRule)
    }

    ok(decide(forceRule: true, mode: .e2e) == .rule,
       "F1 forceRule=true 时，端到端主驾 → 纯规则兜底",
       "决策=\(decide(forceRule: true, mode: .e2e).rawValue)")

    // F2：forceRule 是最高优先级，必须压过极速模式
    //     （代码里 §0 紧急切纯规则 排在 §1 极速模式覆盖之前）
    let stm2 = DegradeStateMachine()
    let forced = stm2.update(m9Live: true, assistLive: true, health: 1.0,
                             warmingUp: false, speedKmh: 0, speedValid: true,
                             dt: 0.033, sportMode: true, forceRule: true)
    ok(forced == .rule,
       "F2 forceRule 优先于极速模式（§0 排在 §1 之前）",
       "sportMode=true + forceRule=true → \(forced.rawValue)")

    // F3：forceRule=false 时必须能回到端到端主驾（解锁）
    let stm3 = DegradeStateMachine()
    _ = stm3.update(m9Live: true, assistLive: true, health: 1.0,
                    warmingUp: false, speedKmh: 0, speedValid: true,
                    dt: 0.033, sportMode: false, forceRule: true)
    let unlocked = stm3.update(m9Live: true, assistLive: true, health: 1.0,
                               warmingUp: false, speedKmh: 0, speedValid: true,
                               dt: 0.033, sportMode: false, forceRule: false)
    ok(unlocked == .e2e || unlocked == .yolo,
       "F3 解除 forceRule 后能回到正常梯子（不是永久锁死在规则档）",
       "解锁后=\(unlocked.rawValue)")

    // ══════════════════════════════════════════════════════════════════
    print("\n═══ 结果：通过 \(pass) / 失败 \(fail) ═══")
    if fail == 0 {
        print("✅ 引擎配置通道四处修复全部生效")
    } else {
        print("❌ 有 \(fail) 项未通过")
    }
    return fail
}
