// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  GameModeDefender.swift — 对抗 Game Mode 压制的「持久战」组件
//
//  背景（2026-09-13 实测）：游戏全屏进入 Game Mode 后，AuroraDrive 的辅助帧率
//    能维持 30fps 约 40 秒，随后被 gamepolicyd 压过去（掉到个位数）。
//    → 教训：一次性设防（启动时设 nice / 拿 activity）不够，会被逐步压制。
//
//  两条互补措施（本组件）：
//   1) 静音音频（audible 维度）
//      · Apple 文档：App Nap 判定条件之一是「it isn't audible」→ 播音频是
//        独立豁免项；Game Mode 很可能沿用同类评估维度。
//      · CoreAudio 的音频线程是**实时优先级且不需要 root** —— 这绕过了我们
//        此前卡住的「设实时线程要 root」那道门。
//      · 用 AudioQueue 输出零采样循环，不需要 NSApplication（引擎进程也可用）。
//   2) 持续重新主张（打持久战）
//      · 每 3 秒复查：本进程 nice 是否仍是 -20、activity token 是否仍持有，
//        被改动就立刻设回去并落盘日志。
//      · 对「40 秒后被压过去」这类渐进压制，这是最对症的手段。
//
//  日志：/tmp/aurora_defender.log（便于 A/B 对比与事后取证）
// ============================================================================

import Foundation
import AudioToolbox
import Darwin

final class GameModeDefender {

    static let shared = GameModeDefender()
    private init() {}

    // MARK: - 状态

    private let logPath = "/tmp/aurora_defender.log"
    private var audioQueue: AudioQueueRef?
    private var audioBuffers: [AudioQueueBufferRef] = []
    private var timer: DispatchSourceTimer?
    private var napToken: NSObjectProtocol?
    private var reassertCount = 0
    private var audioActive = false

    /// 本进程角色（日志用）
    private var role: String {
        CommandLine.arguments.contains("--engine") ? "ENGINE" : "UI"
    }

    private func log(_ msg: String) {
        let line = "[\(role)] [\(Self.ts())] \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // MARK: - 启动

    /// 启动全部对抗措施（幂等）
    func start() {
        guard timer == nil else { return }
        log("─ 持久战启动：静音音频 + 每 3s 重新主张 ─")
        startSilentAudio()
        startReassertLoop()
    }

    // MARK: - 措施 1：静音音频（AudioQueue，不依赖 NSApplication）

    /// 回调：buffer 播完再次入队，形成无限静音循环。
    /// 用全局函数指针（C 回调不能捕获上下文），通过 inUserData 拿回自身。
    private static let audioCallback: AudioQueueOutputCallback = { userData, queue, buffer in
        // 重新入队同一块已清零的 buffer → 持续「正在播放」状态
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        _ = userData
    }

    private func startSilentAudio() {
        var format = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,          // 2ch × 16bit
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0)

        var queue: AudioQueueRef?
        let st = AudioQueueNewOutput(&format, Self.audioCallback, nil, nil, nil, 0, &queue)
        guard st == noErr, let q = queue else {
            log("✗ 静音音频启动失败（AudioQueueNewOutput status=\(st)）")
            return
        }

        // 两块 0.25 秒的静音 buffer（零填充 = 绝对无声）
        let framesPerBuffer: UInt32 = 11025          // 44100/4
        let bytes = Int(framesPerBuffer) * Int(format.mBytesPerFrame)
        for _ in 0..<2 {
            var buf: AudioQueueBufferRef?
            var bst = AudioQueueAllocateBuffer(q, UInt32(bytes), &buf)
            guard bst == noErr, let b = buf else { continue }
            memset(b.pointee.mAudioData, 0, Int(b.pointee.mAudioDataBytesCapacity))  // 静音
            b.pointee.mAudioDataByteSize = UInt32(bytes)
            bst = AudioQueueEnqueueBuffer(q, b, 0, nil)
            if bst == noErr { audioBuffers.append(b) }
        }
        let startSt = AudioQueueStart(q, nil)
        if startSt == noErr {
            audioQueue = q
            audioActive = true
            log("✓ 静音音频已启动（AudioQueue 2×11025 帧零采样循环；audible=活跃 + CoreAudio 实时线程）")
        } else {
            log("✗ 静音音频启动失败（AudioQueueStart status=\(startSt)）")
        }
    }

    // MARK: - 措施 2：持续重新主张

    private func startReassertLoop() {
        let q = DispatchQueue(label: "aurora.defender", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 3, repeating: 3.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.reassert() }
        t.resume()
        timer = t
    }

    /// 复查并重新主张所有可被系统改动的防护项
    private func reassert() {
        var fixes: [String] = []

        // ① nice：被改回就立刻设回 -20
        let current = getpriority(PRIO_PROCESS, 0)
        if current != -20 {
            if setpriority(PRIO_PROCESS, 0, -20) == 0 {
                fixes.append("nice \(current) → -20")
            }
        }

        // ② activity token：被释放就重新拿
        if napToken == nil {
            napToken = ProcessInfo.processInfo.beginActivity(
                options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
                reason: "AuroraDrive Game Mode 对抗：重新主张防冻结")
            if napToken != nil { fixes.append("重新取得 activity token") }
        }

        // ③ 静音音频：若队列被系统停掉则重启
        if let q = audioQueue, audioActive {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioQueueGetProperty(q, kAudioQueueProperty_IsRunning, &running, &size) == noErr, running == 0 {
                if AudioQueueStart(q, nil) == noErr { fixes.append("静音音频被停 → 已重启") }
            }
        } else if !audioActive {
            startSilentAudio()
            if audioActive { fixes.append("静音音频补启") }
        }

        reassertCount += 1
        if !fixes.isEmpty {
            log("⚔ 重新主张：\(fixes.joined(separator: " / "))（第 \(reassertCount) 次复查）")
        } else if reassertCount % 20 == 1 {   // 每分钟记一次"稳态"
            log("稳态：nice=\(current) audio=\(audioActive) 复查第 \(reassertCount) 次")
        }
    }
}
