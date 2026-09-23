// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PrioritySetup.swift — AuroraDrive 性能提权器（root 级 renice 守护）
//
//  背景：游戏开 Game Mode 后同为 userInteractive QoS，同级竞争时系统偏心
//        前台游戏，AuroraDrive 的推理线程被挤到效率核 → 卡顿。用户态 QoS
//        已拉满（userInteractive 是天花板），要再高只能走 root nice -20。
//
//  机制（与 BPFSetup 相同的密码模式）：用户输入一次管理员密码 →
//    1) 安装 /usr/local/bin/aurora-priority.sh（root 常驻循环）
//       每 5 秒把 AuroraDriveUI（含 --engine 引擎子进程）renice 到 -20
//       —— 比游戏（nice 0）高一头，内核调度永远优先喂我们
//    2) 安装 /Library/LaunchDaemons/com.aurora.priority.plist
//       （RunAtLoad + KeepAlive：开机自启、崩溃自动拉起、新进程 5 秒内自动跟随）
//
//  安全性：只 renice 自己名字的进程，不碰其他任何进程。
// ============================================================================

import Foundation

enum PrioritySetupManager {

    static let scriptPath = "/usr/local/bin/aurora-priority.sh"
    static let plistPath = "/Library/LaunchDaemons/com.aurora.priority.plist"
    static let serviceLabel = "com.aurora.priority"

    /// 是否已安装（plist 存在）
    static func isLaunchDaemonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 守护进程是否正在运行
    static func isRunning() -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "pgrep -f aurora-priority.sh >/dev/null 2>&1"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 语义化别名（供 PrivilegePill 判定「权限是否真的可用」）。
    /// 与 isRunning 同义：plist 装过 ≠ 守护在跑，必须实测进程存在。
    static func isDaemonRunning() -> Bool { isRunning() }

    /// ⚠️ 已停用（2026-09-23）：原生授权路径。
    /// 同 BPFSetupManager.install —— 密码硬编码 + 走 macOS 原生授权弹窗，
    /// 两者都是用户明确禁止的。提权统一改走 `PrivilegePill`。
    @available(*, deprecated, message: "已改用 PrivilegePill.shared.install(password:)")
    static func install(password: String) -> (success: Bool, message: String) {
        _ = password
        return (false, "此路径已停用：请使用应用内提权（PrivilegePill），不要调用原生授权")
    }

    /// 当前 AuroraDriveUI 进程的实际 nice 值（诊断用；-20 = 提权生效）
    static func currentNice(pid: pid_t) -> Int32? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = withUnsafeMutablePointer(to: &kinfo) {
            $0.withMemoryRebound(to: Int8.self, capacity: size) {
                sysctl(&mib, 4, $0, &size, nil, 0)
            }
        }
        guard result == 0 else { return nil }
        return Int32(kinfo.kp_proc.p_nice)
    }
}
