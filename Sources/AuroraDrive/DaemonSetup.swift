// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AuroraDriveShared
import Foundation
import Darwin

/// 开发阶段的一键服务编排器。
///
/// 重要边界：
/// - BPF 权限仍由独立的 root LaunchDaemon 负责；
/// - 驾驶核心先以当前登录用户身份运行，避免把 SwiftUI/AppKit/TCC 程序当成 root daemon；
/// - 当前阶段只安装并验证 UserAgent/XPC 基础设施，尚未把现有驾驶引擎迁移到 UserAgent。
/// - 不保存密码，也不把密码放入 argv、脚本或日志；管理员授权由 macOS 原生授权对话框完成。
struct DaemonSetupManager {
    static let userAgentLabel = AuroraDriveServiceIdentity.launchAgentLabel
    static let userAgentMachService = AuroraDriveServiceIdentity.machServiceName
    static let userAgentPlistName = "\(userAgentLabel).plist"
    static let userAgentExecutableName = "AuroraDriveUserAgent"

    /// 兼容旧 UI 的名称；不再代表 root daemon。
    static var daemonLabel: String { userAgentLabel }
    static var daemonPlistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(userAgentPlistName)").path
    }
    static var daemonExecutablePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuroraDrive/\(userAgentExecutableName)").path
    }

    static func isRunningAsDaemon() -> Bool {
        ProcessInfo.processInfo.environment["AURORA_USER_AGENT_MODE"] == "1"
    }

    /// 仅检查用户会话 Agent 是否已安装且被当前 gui/$uid 域加载。
    static func isDaemonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath)
            && FileManager.default.fileExists(atPath: daemonExecutablePath)
            && isUserAgentLoaded()
    }

    /// 一次安装事务需要同时满足 BPF 和用户 Agent。
    static func needsInstall() -> Bool {
        !isDaemonInstalled() || !BPFSetupManager.isBPFAvailable()
    }

    /// 旧调用点兼容入口。password 参数保留仅为兼容旧 UI，实际不会读取或保存。
    /// 管理员授权由 osascript 的原生授权流程完成。
    @discardableResult
    static func install(password: String, currentExecutablePath: String) -> (success: Bool, message: String) {
        install(currentExecutablePath: currentExecutablePath)
    }

    /// 安装 BPF root LaunchDaemon + 当前用户 LaunchAgent。
    /// 成功条件：用户 Agent 已 bootstrap，BPF 权限可用，system job 可被 print 查询。
    static func install(currentExecutablePath: String) -> (success: Bool, message: String) {
        let hadAgent = isDaemonInstalled()
        do {
            try installUserAgent(currentExecutablePath: currentExecutablePath)
        } catch {
            return (false, "用户会话服务安装失败：\(error.localizedDescription)")
        }

        if !BPFSetupManager.isBPFAvailable() {
            let result = installBPFWithSystemAuthorization()
            guard result.success else {
                if !hadAgent { removeUserAgent() }
                return result
            }
        }

        guard isUserAgentLoaded() else {
            if !hadAgent { removeUserAgent() }
            return (false, "用户会话服务文件已写入，但 launchd 未加载 Agent")
        }
        guard pingUserAgent(timeout: 2.0) else {
            if !hadAgent { removeUserAgent() }
            return (false, "用户会话 Agent 已注册，但 XPC 健康检查失败")
        }
        guard BPFSetupManager.isBPFAvailable() else {
            if !hadAgent { removeUserAgent() }
            return (false, "BPF 权限仍不可用，未报告安装成功")
        }
        return (true, "BPF 权限与用户会话 XPC Agent 已配置完成")
    }

    /// 兼容旧卸载入口；仅卸载用户 Agent，不自动删除 BPF 权限服务。
    static func uninstall(password: String) -> (success: Bool, message: String) {
        removeUserAgent()
        return (true, "用户会话 Agent 已卸载；BPF 权限服务未改动")
    }

    static func currentExecutablePath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 通过 launchd 管理的 Mach 服务对用户 Agent 做一次带超时的 XPC ping。
    static func pingUserAgent(timeout: TimeInterval = 2.0) -> Bool {
        final class PingBox: @unchecked Sendable {
            let lock = NSLock()
            var answered = false
            var ok = false
        }
        let box = PingBox()
        let connection = NSXPCConnection(machServiceName: userAgentMachService)
        connection.remoteObjectInterface = NSXPCInterface(with: AuroraDriveUserAgentProtocol.self)
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in
            box.lock.lock()
            box.answered = true
            box.ok = false
            box.lock.unlock()
        } as? AuroraDriveUserAgentProtocol
        remote?.ping { version, status in
            box.lock.lock()
            box.answered = true
            box.ok = version == AuroraDriveServiceIdentity.protocolVersion && status == "ready"
            box.lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            box.lock.lock()
            let done = box.answered
            let ok = box.ok
            box.lock.unlock()
            if done { return ok }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    // MARK: - 用户会话 Agent

    private static func installUserAgent(currentExecutablePath: String) throws {
        guard let source = resolveUserAgentBinary(from: currentExecutablePath) else {
            throw SetupError("找不到 AuroraDriveUserAgent。请先执行 swift build -c debug 或设置 AURORA_USER_AGENT_PATH")
        }

        let fm = FileManager.default
        let executableURL = URL(fileURLWithPath: daemonExecutablePath)
        try fm.createDirectory(at: executableURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: daemonExecutablePath) {
            try fm.removeItem(at: executableURL)
        }
        try fm.copyItem(at: source, to: executableURL)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let plistURL = URL(fileURLWithPath: daemonPlistPath)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let uid = getuid()
        let plist: [String: Any] = [
            "Label": userAgentLabel,
            "ProgramArguments": [daemonExecutablePath, "--user-agent"],
            "EnvironmentVariables": ["AURORA_USER_AGENT_MODE": "1"],
            "MachServices": [userAgentMachService: true],
            "ProcessType": "Interactive",
            "Nice": -20,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AuroraDriveUserAgent.log").path,
            "StandardErrorPath": fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AuroraDriveUserAgent.error.log").path,
            "AURORAUserID": Int(uid)
        ]
        guard PropertyListSerialization.propertyList(plist, isValidFor: .xml) else {
            throw SetupError("用户 Agent plist 内容无效")
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(userAgentLabel)"], allowFailure: true)
        let bootstrap = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        guard bootstrap.status == 0 else {
            throw SetupError("launchctl bootstrap 用户 Agent 失败：\(bootstrap.output)")
        }
        let kickstart = run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(userAgentLabel)"], allowFailure: true)
        guard kickstart.status == 0, isUserAgentLoaded() else {
            throw SetupError("用户 Agent bootstrap 后未能 kickstart")
        }
    }

    private static func isUserAgentLoaded() -> Bool {
        let uid = getuid()
        return run("/bin/launchctl", ["print", "gui/\(uid)/\(userAgentLabel)"], allowFailure: true).status == 0
    }

    private static func removeUserAgent() {
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(userAgentLabel)"], allowFailure: true)
        try? FileManager.default.removeItem(atPath: daemonPlistPath)
        try? FileManager.default.removeItem(atPath: daemonExecutablePath)
    }

    private static func resolveUserAgentBinary(from appExecutable: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["AURORA_USER_AGENT_PATH"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        let appURL = URL(fileURLWithPath: appExecutable).standardizedFileURL.resolvingSymlinksInPath()
        let buildDir = appURL.deletingLastPathComponent()
        candidates.append(buildDir.appendingPathComponent(userAgentExecutableName))
        let root = AuroraPaths.projectRoot()
        candidates.append(root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(userAgentExecutableName)"))
        candidates.append(root.appendingPathComponent(".build/arm64-apple-macosx/release/\(userAgentExecutableName)"))
        return candidates
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .first { fm.isExecutableFile(atPath: $0.path) }
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
