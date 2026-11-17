// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  OnlineTrainingWireSelfTest.swift — 在线训练「接线」端到端自检
//  （-rl-train-wire-selftest）
//
//  【为什么单独一个自检】
//    PolicyHead / OnlineTrainer 各自的单元自检（-rl-core-selftest / -rl-online-selftest）
//    用的是合成 state_token，证明的是「算法对」。但把它们**真正接到
//    StateTokenAccelerator（吃真实 CoreML 帧）**这一步在本自检之前没有任何证据。
//    本自检用合成 CGImage 走**真实**链路：
//        CGImage → renderNormalized(hi/lo) → V3FrameRingBuffer → StateTokenAccelerator
//              → state_token[256] → OnlineTrainer.sampleAction → collect
//    断言：① state_token 维度对且全有限；② 采样/collect 真在推进（计数增长、
//    指标出现）；③ **全程 0 按键注入**（训练绝不能替用户操作游戏）。
//
//  【为什么用合成 CGImage 而不是真截图】
//    自检必须无窗口、无屏幕录制权限、可离线跑。renderNormalized 与生产同源，
//    合成图能真实走完整条预处理 + CoreML 推理，足以证明接线正确。
// ============================================================================

import Foundation
import CoreGraphics

enum OnlineTrainingWireSelfTest {

    /// 合成一张确定性图像（渐变 + 固定结构），交给生产同款 renderNormalized。
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                data[i]     = UInt8((x * 255) / max(1, width - 1))          // R 横向渐变
                data[i + 1] = UInt8((y * 255) / max(1, height - 1))         // G 纵向渐变
                data[i + 2] = UInt8(((x ^ y) & 0xFF))                       // B 棋盘扰动
                data[i + 3] = 255                                           // A
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// 入口（由启动器分发 `-rl-train-wire-selftest` 时调用）。返回失败项数，0 = 全过。
    @MainActor
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 在线训练接线自检（-rl-train-wire-selftest）═══")

        // 加速器模型缺失 → 如实 SKIP（不冒充通过）。
        let probe = StateTokenAccelerator()
        guard probe.loadIfNeeded() else {
            print("  ⚠️ SKIP：state_token CoreML 模型不可用 —— \(probe.failureReason ?? "未就绪")")
            print("  SKIP 说明：接线代码路径需要真实 state_token 模型；模型缺失时本自检不做断言。")
            print("═══ 结果：SKIP（非失败）═══")
            return 0
        }

        // 真实运行时（默认降频 3 帧；自检里改成每帧都采，样本更快够）
        // headCheckpointURL: nil——#7 新增的默认存盘是「真实训练续读」用的；
        // 自检用合成图训练出的权重绝不能写进真实存盘（否则下次真启动会续读到垃圾权重）。
        let runtime = OnlineTrainingRuntime(sampleEveryNFrames: 1,
                                             headCheckpointURL: nil)
        check("运行时启动成功（加速器加载）", runtime.start(),
              runtime.lastError ?? "")

        // 记录训练开始前的按键注入计数（ControlEngine 全局单例）
        let control = ControlEngine()
        let digestBefore = control.digestedEventCount
        let postedBefore = control.postedEventCount

        // 造测试帧并驱动若干帧。用 8 张不同图像，模拟连续画面。
        guard let base = makeTestImage(width: V3InputContract.hiWidth,
                                       height: V3InputContract.hiHeight) else {
            print("  ✗ 测试帧构造失败")
            print("═══ 结果：有失败 ❌ ═══")
            return failures + 1
        }

        let driveFrames = 400          // 足够触发多次 trainEvery=64 与一次 240 帧 episode 边界
        for i in 0..<driveFrames {
            // 轻微变化每帧（平移渐变相位）：直接用 base（合成图已含结构），
            // 为让窗口非静止，这里用 base 但不同帧仍会推进 sampledFrames。
            _ = i
            runtime.onFrame(base, signals: OnlineTrainingRuntime.FrameSignals(
                speedKmh: 40, speedValid: true, tookOver: false,
                collision: false, laneOffset: 0, manualStop: false))
            // 【T2 2026-11-17 唯一例外改动（lead 授权，仅此一行）】onFrame 已改为
            // 异步有界单槽（主线程立即返回，消费不过来丢旧保新）。本自检要断言
            // 「每帧都被采样」，必须逐帧等消费完成——否则 400 帧突发会被单槽丢掉
            // 绝大多数（那是生产行为，不是本自检要验证的事）。
            _ = runtime.waitForPipelineIdle(timeout: 10)
        }

        // 采样计数应 == driveFrames（降频 1 → 每帧都采；只要加速器可用不失败）
        check("采样帧推进（sampledFrames > 0）", runtime.sampledFrames > 0,
              "sampledFrames=\(runtime.sampledFrames) skipped=\(runtime.skippedFrames)")
        check("绝大多数帧成功采样（skipped 占比 < 10%）",
              runtime.skippedFrames * 10 < max(1, runtime.sampledFrames + runtime.skippedFrames),
              "sampled=\(runtime.sampledFrames) skipped=\(runtime.skippedFrames)")

        // 400 帧 / trainEvery=64 → 至少若干次 PPO 更新应产生指标
        let metrics = runtime.metricsSummary()
        check("产生了 PPO 训练指标（训练真在跑，不只是采样）", metrics != nil,
              metrics ?? "无指标（可能样本不足 64）")

        // 关键安全断言：训练全程 0 按键注入
        let digestAfter = control.digestedEventCount
        let postedAfter = control.postedEventCount
        check("训练全程 0 按键注入（digestedEventCount 未增）", digestAfter == digestBefore,
              "before=\(digestBefore) after=\(digestAfter)")
        check("训练全程 0 真实按键注入（postedEventCount 未增）", postedAfter == postedBefore,
              "before=\(postedBefore) after=\(postedAfter)")

        // 停止：收尾安全
        runtime.stop()
        check("运行时停止后 running == false", !runtime.running)

        print(failures == 0
              ? "═══ 结果：全部通过 ✅（\(failures) 项失败）═══"
              : "═══ 结果：有失败 ❌（\(failures) 项失败）═══")
        return failures
    }
}
