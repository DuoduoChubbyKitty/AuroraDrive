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

    /// 安装（需要管理员密码）。模式与 BPFSetupManager.install 完全一致。
    static func install(password: String) -> (success: Bool, message: String) {
        // 1. 写 setup 脚本到 /tmp（以 root 身份执行它来完成安装）
        let scriptContent = """
#!/bin/bash
set -e

# 常驻 renice 守护：每 5 秒把 AuroraDriveUI（含 --engine 引擎）拉到 nice -20
cat > /usr/local/bin/aurora-priority.sh << 'SCRIPT_EOF'
#!/bin/bash
while true; do
    # 用 ps comm（可执行文件路径）精确匹配，不用 pgrep -f——
    # 后者会误伤任何命令行含 "AuroraDriveUI" 的无关进程（终端/编辑器/诊断命令）
    for pid in $(ps -axo pid=,comm= | awk '$2 ~ /\\/AuroraDriveUI$/ {print $1}'); do
        renice -n -20 -p "$pid" >/dev/null 2>&1
    done
    sleep 5
done
SCRIPT_EOF
chmod 755 /usr/local/bin/aurora-priority.sh

# LaunchDaemon：开机自启 + 崩溃自动拉起 + Interactive 进程类型
cat > /Library/LaunchDaemons/com.aurora.priority.plist << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aurora.priority</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/aurora-priority.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>Nice</key>
    <integer>-20</integer>
</dict>
</plist>
PLIST_EOF
chown root:wheel /Library/LaunchDaemons/com.aurora.priority.plist
chmod 644 /Library/LaunchDaemons/com.aurora.priority.plist

# 卸旧加载新
launchctl unload /Library/LaunchDaemons/com.aurora.priority.plist 2>/dev/null || true
launchctl load -w /Library/LaunchDaemons/com.aurora.priority.plist
echo PRIORITY_INSTALLED
"""
        let tmpPath = "/tmp/aurora_priority_setup.sh"
        do {
            try scriptContent.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
        } catch {
            return (false, "写脚本失败: \(error.localizedDescription)")
        }

        // 2. AppleScript 管理员权限执行（密码经参数传入，不弹系统弹窗）
        let escapedPwd = password.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"bash \(tmpPath)\" password \"\(escapedPwd)\" with administrator privileges"

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                if isRunning() {
                    return (true, "性能提权已生效：AuroraDrive 全家已锁定 nice -20（重启后自动跟随）")
                }
                return (true, "LaunchDaemon 已安装（重启电脑后自动生效）")
            } else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                if errMsg.contains("Authentication") || errMsg.contains("password") {
                    return (false, "密码错误")
                }
                return (false, "安装失败: \(errMsg)")
            }
        } catch {
            return (false, "执行失败: \(error.localizedDescription)")
        }
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
