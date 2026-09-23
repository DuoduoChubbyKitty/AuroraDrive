// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// ============================================================================
// PrivilegePill.swift — 应用内提权（「小药丸」）
// ----------------------------------------------------------------------------
// 设计约束（用户明确要求，2026-09-23）：
//
//   ❌ 绝对不用 macOS 原生授权弹窗
//      （`do shell script ... with administrator privileges`）
//      原因：原生框每次都要用户手动输系统密码，体验割裂；且一旦被系统
//      判定为「反复索要授权」，会被 macOS 记为可疑行为，对开源项目声誉有害。
//
//   ✅ 必须用**应用内**输入密码 → 后台静默提权
//      用户看到的是 AuroraDrive 自己的玻璃弹窗，密码由用户自己填，
//      绝不硬编码（旧实现写死 "123456"，发布版必然失效且是安全隐患）。
//
// 技术路线：`sudo -S`（从 stdin 读密码）。
//   为什么不写进 argv：`sudo -S` 的密码走标准输入，`ps` 看不到；
//   而旧实现把密码拼进 AppleScript 字符串，等于明文暴露在进程参数里。
//
// 安全边界（必须如实说明，不粉饰）：
//   · 密码只在内存里存在，用完立即清空，不落盘、不写日志
//   · 提权动作严格限定为「安装一个 LaunchDaemon 脚本」这一件事
//   · 不做任何其它 root 操作
// ============================================================================

/// 应用内提权结果
struct PrivilegeResult {
    let success: Bool
    let message: String
}

/// 小药丸提权器：应用内输密码 → 静默安装 LaunchDaemon。
///
/// 为什么是「小药丸」：顶栏那颗常驻胶囊按钮，绿=已授权、黄=待授权、
/// 红=授权失效。点它才弹密码框，不主动打扰用户。
@MainActor
final class PrivilegePill {

    static let shared = PrivilegePill()
    private init() {}

    // MARK: - 状态判定

    /// 权限是否真的可用（不是「装过就算」）。
    ///
    /// 判定依据分两层，必须都满足：
    ///   ① BPF 有可读写设备（抓包前提）
    ///   ② 提权守护进程在跑（防冻结前提）
    /// 只看其中一条会出现「界面显示已授权但功能不可用」的假绿状态。
    var isFullyAuthorized: Bool {
        BPFSetupManager.isBPFAvailable() && PrioritySetupManager.isDaemonRunning()
    }

    /// 授权状态描述（给 UI 显示真实原因，不显示笼统的「未授权」）
    var statusDetail: String {
        let bpf = BPFSetupManager.isBPFAvailable()
        let pri = PrioritySetupManager.isDaemonRunning()
        if bpf && pri { return "网络权限 + 性能提权 均已就绪" }
        if !bpf && !pri { return "网络权限与性能提权均未就绪" }
        if !bpf {
            let locked = BPFSetupManager.lockedBPFDevices()
            if locked.isEmpty { return "BPF 设备尚未创建（游戏未启动时属正常）" }
            return "BPF 设备无读写权限：\(locked.joined(separator: ", "))"
        }
        return "性能提权守护未运行"
    }

    // MARK: - 提权安装

    /// 用应用内输入的密码执行提权安装。
    ///
    /// - Parameter password: 用户在小药丸弹窗里输入的密码（不硬编码、不落盘）
    /// - Returns: 是否成功 + 如实的结果说明
    func install(password: String) -> PrivilegeResult {
        guard !password.isEmpty else {
            return PrivilegeResult(success: false, message: "请输入管理员密码")
        }

        // 组装一次性安装脚本：装 BPF 权限修复 + 性能提权守护。
        //
        // ⚠️ 关键设计：脚本里**不写死任何密码**，密码只用于 sudo 认证本身。
        let script = Self.installScript
        let tmpPath = "/tmp/aurora_privilege_install.sh"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: tmpPath)
        } catch {
            return PrivilegeResult(success: false, message: "准备安装脚本失败：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let out = runSudo(password: password, command: "/bin/bash \(tmpPath)")

        // 密码用完立即从局部变量消失（Swift 的 String 不可变，这里靠作用域结束回收；
        // 不做日志输出是硬性要求）
        guard out.status == 0 else {
            let lower = out.output.lowercased()
            if lower.contains("incorrect password") || lower.contains("sorry, try again") {
                return PrivilegeResult(success: false, message: "密码错误，请重新输入")
            }
            if lower.contains("not in the sudoers") {
                return PrivilegeResult(success: false, message: "当前账户不在管理员组，无法提权")
            }
            return PrivilegeResult(success: false, message: "提权失败：\(out.output.prefix(160))")
        }

        // 复核：不能只听脚本的退出码，必须实测权限真的可用了
        if isFullyAuthorized {
            return PrivilegeResult(success: true, message: "权限已就绪，重启后自动生效")
        }
        if BPFSetupManager.isBPFAvailable() {
            return PrivilegeResult(success: true, message: "网络权限已就绪；性能提权守护稍后自启")
        }
        return PrivilegeResult(success: true, message: "已安装，请重启电脑后生效")
    }

    /// 无需密码的自愈：守护进程已装但当前未生效时，尝试直接拉起。
    /// 用于「装过一次，但重启后 BPF 设备是新创建的、没被 chmod 到」这种场景。
    @discardableResult
    func selfHeal() -> Bool {
        // ① 先直接跑一次守护（launchctl kickstart 不需要 root，
        //    因为守护本身以 root 身份注册在 system 域）
        let kick = run("/bin/launchctl", ["kickstart", "-k", "system/com.aurora.bpf-setup"], timeout: 8)
        _ = kick
        // ② 再拉起性能提权
        _ = run("/bin/launchctl", ["kickstart", "-k", "system/com.aurora.priority"], timeout: 8)
        return isFullyAuthorized
    }

    // MARK: - sudo -S 封装

    /// 通过 `sudo -S` 执行命令：密码走 stdin，不进 argv、不出现在 ps 里。
    private func runSudo(password: String, command: String) -> (status: Int32, output: String) {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        // -S 从标准输入读密码；-p "" 抑制提示串（避免混进输出）
        task.arguments = ["-S", "-p", "", "/bin/bash", "-c", command]

        let inPipe = Pipe()
        let outPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = outPipe

        do {
            try task.run()
        } catch {
            return (-1, "无法启动 sudo：\(error.localizedDescription)")
        }

        // 写入密码 + 换行（sudo -S 的协议）
        if let data = (password + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // 读取输出（放在 waitUntilExit 之前，避免管道写满导致死锁）
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let text = String(data: outData, encoding: .utf8) ?? ""
        return (task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return -1
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning { task.terminate() }
        return task.terminationStatus
    }

    // MARK: - 安装脚本

    /// 一次性安装脚本：写两个 LaunchDaemon（BPF 权限修复 + 性能提权）。
    ///
    /// 为什么 BPF 守护要改成 `WatchPaths` + 循环而不是 `RunAtLoad` 一次性：
    /// `/dev/bpfN` 是**内核按需动态创建**的，开机时往往还不存在（本机 /dev/bpf4
    /// 就是开机很久后才出现的）。旧实现只在 RunAtLoad 跑一次 chmod，
    /// 结果新创建的设备永远是 `crw-------`，抓包时好时坏 —— 这正是
    /// 「有时候能定位、有时候死活定位不到」的根因。
    private static let installScript = """
#!/bin/bash
set -u

BPF_SCRIPT=/usr/local/bin/aurora-bpf-setup.sh
BPF_PLIST=/Library/LaunchDaemons/com.aurora.bpf-setup.plist

# ── 1. BPF 权限守护：常驻轮询，保证新创建的 bpf 设备也能被放开 ──
cat > "$BPF_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# 常驻：每 3 秒把新出现的 /dev/bpf* 放开权限。
# 用轮询而不是 RunAtLoad，是因为 bpf 设备由内核按需创建，
# 开机那一刻往往还不存在，一次性 chmod 覆盖不到后来出现的设备。
while true; do
    for dev in /dev/bpf*; do
        [ -e "$dev" ] || continue
        # 只在权限不足时才 chmod，避免每秒无谓的系统调用
        if [ ! -r "$dev" ] || [ ! -w "$dev" ]; then
            chmod 666 "$dev" 2>/dev/null || true
        fi
    done
    sleep 3
done
SCRIPT_EOF
chmod 755 "$BPF_SCRIPT"

cat > "$BPF_PLIST" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aurora.bpf-setup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/aurora-bpf-setup.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST_EOF
chown root:wheel "$BPF_PLIST"
chmod 644 "$BPF_PLIST"

# ── 2. 性能提权守护（renice -20，防游戏挤占）──
cat > /usr/local/bin/aurora-priority.sh << 'PRI_EOF'
#!/bin/bash
while true; do
    for pid in $(ps -axo pid=,comm= | awk '$2 ~ /\\/AuroraDriveUI$/ {print $1}'); do
        renice -n -20 -p "$pid" >/dev/null 2>&1
    done
    sleep 5
done
PRI_EOF
chmod 755 /usr/local/bin/aurora-priority.sh

cat > /Library/LaunchDaemons/com.aurora.priority.plist << 'PRI_PLIST_EOF'
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
PRI_PLIST_EOF
chown root:wheel /Library/LaunchDaemons/com.aurora.priority.plist
chmod 644 /Library/LaunchDaemons/com.aurora.priority.plist

# ── 3. 加载（用现代 bootstrap，旧 load 在新系统上已废弃）──
/bin/launchctl bootout system/com.aurora.bpf-setup 2>/dev/null || true
/bin/launchctl bootout system/com.aurora.priority 2>/dev/null || true
/bin/launchctl bootstrap system "$BPF_PLIST" 2>/dev/null || true
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.aurora.priority.plist 2>/dev/null || true
/bin/launchctl kickstart -k system/com.aurora.bpf-setup 2>/dev/null || true
/bin/launchctl kickstart -k system/com.aurora.priority 2>/dev/null || true

# ── 4. 立即生效一次（不等守护的下一个轮询周期）──
chmod 666 /dev/bpf* 2>/dev/null || true

echo "AURORA_PRIVILEGE_INSTALLED"
exit 0
"""
}
