// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// 系统权限服务编排器（引擎拆分后的简化版）。
///
/// 背景：原「用户会话 XPC Agent」方案**已废弃**——
///   实测 launchd 拉起的后台进程拿不到 TCC 权限（ax=false、screen=false），
///   驾驶引擎改为由主程序 spawn 的子进程承担（沿进程链继承权限，
///   见 EngineMain.swift / EngineClient.swift）。
/// 因此本文件只保留与驾驶无关的 BPF 权限服务（root LaunchDaemon），
/// 以及若干兼容旧调用点的空壳入口。
///
/// 边界：
/// - BPF 权限由独立 root LaunchDaemon 负责（抓包定位用，与驾驶引擎无关）；
/// - 不保存密码，也不把密码放入 argv、脚本或日志；管理员授权由 macOS 原生授权对话框完成。
struct DaemonSetupManager {

    /// 旧 UI 兼容：引擎架构已不再有 daemon 模式。
    static func isRunningAsDaemon() -> Bool { false }

    /// 旧 UI 兼容：用户会话 Agent 方案已废弃，永远视为「未安装」。
    static func isDaemonInstalled() -> Bool { false }

    /// 现在只有 BPF 权限需要安装。
    static func needsInstall() -> Bool {
        !BPFSetupManager.isBPFAvailable()
    }

    /// 旧调用点兼容入口。password 参数保留仅为兼容旧 UI，实际不会读取或保存。
    @discardableResult
    static func install(password: String, currentExecutablePath: String) -> (success: Bool, message: String) {
        install(currentExecutablePath: currentExecutablePath)
    }

    /// 只安装 BPF root LaunchDaemon（不再安装任何 launchd Agent）。
    static func install(currentExecutablePath: String) -> (success: Bool, message: String) {
        if BPFSetupManager.isBPFAvailable() {
            return (true, "BPF 权限已可用")
        }
        return installBPFWithSystemAuthorization()
    }

    /// 旧调用点兼容：不再有需要卸载的用户会话 Agent。
    static func uninstall(password: String) -> (success: Bool, message: String) {
        (true, "无需卸载：用户会话 Agent 方案已废弃")
    }

    static func currentExecutablePath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - BPF root LaunchDaemon

    private static func installBPFWithSystemAuthorization() -> (success: Bool, message: String) {
        let script = """
        #!/bin/sh
        set -eu
        umask 022
        BPF_SCRIPT=/usr/local/bin/aurora-bpf-setup.sh
        BPF_PLIST=/Library/LaunchDaemons/com.aurora.bpf-setup.plist
        TMP_SCRIPT=$(mktemp /tmp/aurora-bpf.XXXXXX)
        TMP_PLIST=$(mktemp /tmp/aurora-bpf-plist.XXXXXX)
        trap 'rm -f "$TMP_SCRIPT" "$TMP_PLIST"' EXIT
        cat > "$TMP_SCRIPT" <<'EOF_BPF_SCRIPT'
        #!/bin/sh
        set -eu
        chmod 666 /dev/bpf* 2>/dev/null || true
        EOF_BPF_SCRIPT
        chmod 755 "$TMP_SCRIPT"
        install -o root -g wheel -m 755 "$TMP_SCRIPT" "$BPF_SCRIPT"
        cat > "$TMP_PLIST" <<'EOF_BPF_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.aurora.bpf-setup</string>
          <key>ProgramArguments</key><array><string>/usr/local/bin/aurora-bpf-setup.sh</string></array>
          <key>RunAtLoad</key><true/>
        </dict></plist>
        EOF_BPF_PLIST
        install -o root -g wheel -m 644 "$TMP_PLIST" "$BPF_PLIST"
        /bin/launchctl bootout system/com.aurora.bpf-setup 2>/dev/null || true
        /bin/launchctl bootstrap system "$BPF_PLIST"
        /bin/launchctl kickstart -k system/com.aurora.bpf-setup
        /bin/launchctl print system/com.aurora.bpf-setup >/dev/null
        test -r /dev/bpf0
        test -w /dev/bpf0
        """
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuroraDrive-Install-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let scriptURL = tempDir.appendingPathComponent("install.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 使用 macOS 原生管理员授权，不把密码放入 argv 或脚本。
            let quotedPath = shellQuote(scriptURL.path)
            let appleScript = "do shell script \"/bin/sh \(quotedPath)\" with administrator privileges"
            let result = run("/usr/bin/osascript", ["-e", appleScript], timeout: 30)
            guard result.status == 0 else {
                return (false, "BPF 管理员授权或安装失败：\(result.output)")
            }
            guard BPFSetupManager.isBPFAvailable() else {
                return (false, "授权流程返回成功，但 /dev/bpf0 仍不可读写")
            }
            return (true, "BPF root LaunchDaemon 已安装并验证")
        } catch {
            return (false, "准备 BPF 安装事务失败：\(error.localizedDescription)")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ path: String, _ arguments: [String], allowFailure: Bool = false,
                            timeout: TimeInterval? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    return CommandResult(status: -1, output: "命令超时")
                }
            } else {
                process.waitUntilExit()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if !allowFailure && process.terminationStatus != 0 {
                return CommandResult(status: process.terminationStatus, output: output)
            }
            return CommandResult(status: process.terminationStatus, output: output)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
