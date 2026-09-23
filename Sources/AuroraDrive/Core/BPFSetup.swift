// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// BPF权限自动安装器：首次启动检测BPF权限，通过App内密码输入安装开机自启LaunchDaemon
/// 用户只需输入一次密码，之后每次重启自动chmod 666 /dev/bpf*，永久无需再输
struct BPFSetupManager {

    /// 检查 BPF 是否可读写。
    ///
    /// ⚠️ 2026-09-23 修复（这是「小药丸弹不出来」的根因）：
    /// 旧实现只探测 `/dev/bpf0`，而它长期是 666 → 恒返回 true →
    /// 上层判定「已授权」→ 密码弹窗永远不弹。但真正要用的那个设备
    /// （pcap 按需分配，可能是 bpf4/bpf5…）却可能是 `crw-------`，
    /// 于是「界面显示已授权，实际抓不到包」。
    ///
    /// 正解：**逐个探测所有已存在的 bpf 设备**，只要有一个可读写就算可用；
    /// 且必须与 pcap 的真实分配行为对齐 —— 只看 bpf0 是错的。
    static func isBPFAvailable() -> Bool {
        return firstWritableBPFDevice() != nil
    }

    /// 返回第一个可读写的 /dev/bpfN，全不可用则 nil。
    /// pcap 内核按需创建 bpf 设备，数量不固定，所以必须动态枚举而不是写死 0..3。
    static func firstWritableBPFDevice() -> String? {
        for i in 0..<64 {
            let path = "/dev/bpf\(i)"
            guard FileManager.default.fileExists(atPath: path) else {
                // bpf 设备编号连续创建，遇到第一个不存在的就可以停了；
                // 但仍多扫几个，避免中间被其它进程占用后留下的空洞。
                if i > 8 { break }
                continue
            }
            if path.withCString({ access($0, Int32(O_RDWR)) }) == 0 {
                return path
            }
        }
        return nil
    }

    /// 列出所有不可读写的 bpf 设备（诊断用，让 UI 能如实说明卡在哪）
    static func lockedBPFDevices() -> [String] {
        var out: [String] = []
        for i in 0..<64 {
            let path = "/dev/bpf\(i)"
            guard FileManager.default.fileExists(atPath: path) else {
                if i > 8 { break }
                continue
            }
            if path.withCString({ access($0, Int32(O_RDWR)) }) != 0 {
                out.append(path)
            }
        }
        return out
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
    
    /// ⚠️ 已停用（2026-09-23）：原生授权路径。
    ///
    /// 这里原来是 `do shell script ... password "..." with administrator privileges`，
    /// 有两个致命问题：
    ///   ① 密码硬编码/明文进 argv —— 发布版别人的密码当然不是本机那个，必然失败；
    ///   ② 走 macOS 原生授权弹窗 —— 用户明确要求**不要**用原生授权
    ///      （反复索要系统授权会被 macOS 标记为可疑行为，对开源项目声誉有害）。
    ///
    /// 提权已统一改走 `PrivilegePill`（应用内输密码 + `sudo -S`，密码经 stdin）。
    /// 这个函数保留仅为兼容旧调用点，调用即返回失败，绝不执行任何提权动作。
    @available(*, deprecated, message: "已改用 PrivilegePill.shared.install(password:)")
    static func install(password: String) -> (success: Bool, message: String) {
        _ = password
        return (false, "此路径已停用：请使用应用内提权（PrivilegePill），不要调用原生授权")
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
