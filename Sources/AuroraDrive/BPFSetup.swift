// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// BPF权限自动安装器：首次启动检测BPF权限，通过App内密码输入安装开机自启LaunchDaemon
/// 用户只需输入一次密码，之后每次重启自动chmod 666 /dev/bpf*，永久无需再输
struct BPFSetupManager {
    
    /// 检查BPF是否可读写
    static func isBPFAvailable() -> Bool {
        return "/dev/bpf0".withCString { access($0, Int32(O_RDWR)) } == 0
    }
    
    /// 检查LaunchDaemon是否已安装
    static func isLaunchDaemonInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.aurora.bpf-setup.plist")
    }
    
    /// 检查LaunchDaemon是否已加载（真正运行）
    static func isLaunchDaemonLoaded() -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "launchctl list | grep -q com.aurora.bpf-setup"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// 需要安装吗？（BPF不可用 且 LaunchDaemon未装）
    static func needsInstall() -> Bool {
        return !isBPFAvailable() && !isLaunchDaemonInstalled()
    }
    
    /// 需要启动吗？（已安装但未加载）
    static func needsLoad() -> Bool {
        return isLaunchDaemonInstalled() && !isLaunchDaemonLoaded()
    }
    
    /// 写setup脚本到/tmp，然后用AppleScript以管理员权限运行
    /// - Parameter password: 用户在App内输入的密码
    /// - Returns: 是否安装成功
    static func install(password: String) -> (success: Bool, message: String) {
        // 1. 写setup脚本到/tmp
        let scriptContent = """
#!/bin/bash
# 创建开机自启脚本
cat > /usr/local/bin/aurora-bpf-setup.sh << 'SCRIPT_EOF'
#!/bin/bash
chmod 666 /dev/bpf* 2>/dev/null
SCRIPT_EOF
chmod 755 /usr/local/bin/aurora-bpf-setup.sh

# 创建LaunchDaemon plist
cat > /Library/LaunchDaemons/com.aurora.bpf-setup.plist << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aurora.bpf-setup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>/usr/local/bin/aurora-bpf-setup.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST_EOF
chown root:wheel /Library/LaunchDaemons/com.aurora.bpf-setup.plist
chmod 644 /Library/LaunchDaemons/com.aurora.bpf-setup.plist
launchctl load /Library/LaunchDaemons/com.aurora.bpf-setup.plist

# 立即chmod BPF
chmod 666 /dev/bpf* 2>/dev/null
echo "BPF_SETUP_DONE"
"""
        
        let scriptPath = "/tmp/aurora_bpf_setup.sh"
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // 设置可执行权限
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            return (false, "写脚本失败: \(error.localizedDescription)")
        }
        
        // 2. 用AppleScript以管理员权限运行setup脚本（不弹系统弹窗，密码通过参数传）
        let escapedPwd = password.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"bash \(scriptPath)\" password \"\(escapedPwd)\" with administrator privileges"
        
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
                // 验证BPF是否可用了
                if isBPFAvailable() {
                    return (true, "BPF权限已安装，开机自动生效")
                } else {
                    return (true, "LaunchDaemon已安装，请重启电脑后生效")
                }
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
    
    /// 尝试立即chmod BPF（不需要密码，如果LaunchDaemon已装但BPF还没chmod）
    static func tryImmediateChmod() -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "launchctl start com.aurora.bpf-setup 2>/dev/null; sleep 1; test -r /dev/bpf0"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 && isBPFAvailable()
        } catch {
            return false
        }
    }
    
    /// 启动 LaunchDaemon（如果已安装但未加载）
    static func loadDaemonIfNeeded() -> Bool {
        guard isLaunchDaemonInstalled() else { return false }
        guard !isLaunchDaemonLoaded() else { return true }
        
        // 尝试加载服务
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "launchctl load /Library/LaunchDaemons/com.aurora.bpf-setup.plist 2>/dev/null; launchctl start com.aurora.bpf-setup 2>/dev/null"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 && isLaunchDaemonLoaded()
        } catch {
            return false
        }
    }
}
