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

    /// ⚠️ 已停用（2026-09-23）：原生授权路径。
    ///
    /// 这里原来是 `do shell script "/bin/sh ..." with administrator privileges`，
    /// 会弹 macOS 系统授权框 —— 用户明确要求不要用原生授权。
    /// 提权统一改走 `PrivilegePill`（应用内输密码 + sudo -S）。
    private static func installBPFWithSystemAuthorization() -> (success: Bool, message: String) {
        return (false, "此路径已停用：请使用应用内提权（PrivilegePill），不要调用原生授权")
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
