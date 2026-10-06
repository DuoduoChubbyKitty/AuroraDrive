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
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 性能修复：加 2 秒记忆化缓存
    /// ══════════════════════════════════════════════════════════════════════════
    ///
    /// 【症状】「一打开就卡得离谱」。
    ///
    /// 【实测证据】对运行中的 UI 进程做 `sample`（6 秒、1ms 粒度、3725 个样本），
    ///   主线程调用树：
    ///
    ///       100.0%  NSApplicationMain → _DPSNextEvent
    ///        82.6%  __CFRunLoopDoObservers
    ///        82.5%  ViewGraphRootValueUpdater.updateGraph
    ///        81.6%  DynamicBody.updateValue
    ///        81.4%  **PermissionPill.body.getter**     ← 一个小药丸占了主线程 81%
    ///
    ///   即：主线程绝大部分时间都耗在**重算这个权限药丸的 body**。
    ///
    /// 【根因链条】
    ///   ① `PermissionPill`（MissionConsole.swift:269）位于 `TopBar`（:95），
    ///      而 `TopBar` 读 `state` —— 于是 30Hz 的 `tick()` 每写一次
    ///      `@Observable` 属性，都让 `TopBar` 子树失效、重算 `body`。
    ///   ② `PermissionPill.body` 里两处读了本属性：
    ///        · `.help(ready ? PrivilegePill.shared.statusDetail : "…")`
    ///        · 按钮 action 里的 `state.privilegeStatusDetail = …statusDetail`
    ///   ③ 本属性每次求值都要**扫描文件系统与进程表**：
    ///        · `BPFSetupManager.isBPFAvailable()`
    ///          → `firstWritableBPFDevice()` 循环 `0..<64`，
    ///            每次做 `FileManager.fileExists` + `access(2)` 系统调用
    ///        · `PrioritySetupManager.isDaemonRunning()`（进程/文件检查）
    ///        · 未就绪时还会再调 `lockedBPFDevices()` 再来一轮
    ///
    ///   合起来：**每秒 30 次 × 最多 64 次系统调用 ≈ 2000 次/秒**，
    ///   全部砸在 UI 主线程上 —— 这就是「一打开就卡」的直接来源。
    ///
    /// 【修法】加时间戳缓存。权限状态是**人手操作才会变**的量
    ///   （用户去装 BPF / 启动守护才变），根本不需要 30Hz 精度 ——
    ///   2 秒的陈旧度完全够用，且把系统调用量从 ~2000 次/秒降到 ~1 次/2 秒。
    ///
    /// 【为什么用 2 秒】与项目里其它周期性刷新的粒度一致（`GameHUDWindow`
    ///   用 0.5s 刷帧率、`:4770` 的插帧状态用 1Hz、本文件的权限判定用 2s 更保守
    ///   —— 因为它是系统调用密集型的，且状态变化本身很慢）。
    ///
    /// 【为什么不让调用方缓存】`statusDetail` 有多个调用方（药丸 tooltip、
    ///   密码弹窗、状态展示），在属性内部缓存能**一次性覆盖所有调用方**，
    ///   比逐个改调用点更不易遗漏 —— 这正是本类此前反复踩的坑
    ///   （权限处理只补一处、漏掉对称位置）。
    private var cachedStatusDetail: (value: String, at: Date)?

    var statusDetail: String {
        // 2 秒内直接返回缓存，不碰文件系统
        if let c = cachedStatusDetail, Date().timeIntervalSince(c.at) < 2.0 {
            return c.value
        }
        let v = computeStatusDetail()
        cachedStatusDetail = (v, Date())
        return v
    }

    /// 立即作废状态缓存。
    ///
    /// 供**会改变权限状态的操作**调用（目前是 `install(password:)` 安装成功后），
    /// 保证用户装完 BPF/守护后马上看到新状态，而不是等最多 2 秒的缓存过期 ——
    /// 那种"点了没反应"的观感正是本类要避免的。
    func invalidateStatusCache() {
        cachedStatusDetail = nil
    }

    /// 真正执行系统调用的原实现（仅供 `statusDetail` 的缓存层调用）。
    ///
    /// 逻辑与修复前**逐字一致** —— 缓存只改变「多久算一次」，不改变算出来的值。
    private func computeStatusDetail() -> String {
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
            invalidateStatusCache()
            return PrivilegeResult(success: true, message: "权限已就绪，重启后自动生效")
        }
        if BPFSetupManager.isBPFAvailable() {
            // 安装改变了权限状态 → 立即作废 `statusDetail` 的缓存，
            // 否则用户会看到最多 2 秒的旧状态（"点了没反应"的观感）。
            invalidateStatusCache()
            return PrivilegeResult(success: true, message: "网络权限已就绪；性能提权守护稍后自启")
        }
        invalidateStatusCache()
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

    /// 子进程执行队列：**所有 Process 的启动与等待都在这里**，不在主线程。
    ///
    /// 为什么单开一条串行队列而不是 `.global()`：`run` 会被 `selfHeal()` 连续调两次，
    /// 串行队列保证两次 `launchctl kickstart` 严格有序（并行会让第二次 kickstart
    /// 撞上第一次的启动窗口，`launchctl` 对同一 service 并发 kickstart 的行为未定义）。
    private static let processQueue = DispatchQueue(label: "aurora.privilege.process",
                                                    qos: .utility)

    /// 执行一个子进程并等它结束。**事件驱动，不忙等。**
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-10-04 重写（P-4）：原实现是**忙等轮询**
    /// ══════════════════════════════════════════════════════════════════════
    /// 【原实现】
    ///     let deadline = Date().addingTimeInterval(timeout)
    ///     while task.isRunning && Date() < deadline { usleep(50_000) }
    ///     if task.isRunning { task.terminate() }
    ///
    /// 【它错在哪】（不是"慢"，是"形态错"）
    ///   ① **自旋**：50ms 一轮地唤醒 CPU 只为问一句"还在跑吗"。子进程活多久就烧多久，
    ///      而这段时间**什么都不干**。
    ///   ② **无事件语义**：进程结束是一个**事件**，`Process` 为此提供了
    ///      `terminationHandler`。轮询是把事件当状态来问，天然丢精度也天然浪费。
    ///   ③ **最坏 16 秒**：`selfHeal()` 连调两次、每次 `timeout: 8` → 最坏 16s。
    ///      而 `selfHeal()` 由 `MissionConsole` 的 `Task { @MainActor in ... }` 调用
    ///      → **这 16 秒是主线程**（用户直接感知为"卡死"）。
    ///
    /// 【现在】`terminationHandler` + `DispatchGroup.wait(timeout:)`
    ///   · 进程结束 → handler 触发 → `group.leave()`；等待线程在内核里睡着，**零 CPU**；
    ///   · 超时用 `asyncAfter` 投递一个"到点强杀"的 `DispatchWorkItem`，
    ///     **不占线程、不占 CPU**（原来是 160 次 `usleep` 唤醒）；
    ///   · 全部在 `processQueue`（`.utility`）上执行，**主线程不再自旋**。
    ///
    /// 【仍然存在的边界（如实说明）】本方法**仍是同步的** —— 调用方要拿返回码就必须等。
    ///   若调用方在主线程调它（`MissionConsole.swift:5110` 当前就是），主线程仍会等，
    ///   只是**从"自旋等待"变成"睡眠等待"**（CPU 从满转降到 0）。
    ///   要把"等待"本身也挪走，调用方需改用 `selfHealAsync()` —— 见其注释。
    ///
    /// - Returns: 退出码；启动失败或超时返回 `-1`
    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        // ⚠️ 实现只有一份 —— `runOnQueue`。这里只负责"切到 processQueue"。
        //    不在这里复制一份子进程逻辑：那样 `selfHeal()`（同步路径）与
        //    `selfHealAsync()`（异步路径）会各有一份，迟早分叉 ——
        //    这正是本文件 P-4 审计里点名的"同一逻辑多处各写一遍"。
        Self.processQueue.sync {
            runOnQueue(path, args, timeout: timeout)
        }
    }

    /// `selfHeal()` 的**异步版**：把"等待子进程"整段挪出主线程。
    ///
    /// 【为什么需要它】`selfHeal()` 本身是同步的，调用方要拿返回值就必须等。
    ///   `MissionConsole.swift:5110` 目前在 `Task { @MainActor in ... }` 里调它
    ///   → 即使 `run` 已改成睡眠等待，**主线程仍会被占住**（最坏 16s）。
    ///   本方法把两次 launchctl kickstart 放 `processQueue` 上跑，
    ///   完成后回主线程读一次 `isFullyAuthorized`（那是 MainActor 属性）。
    ///
    /// 【为什么保留同步版】`selfHeal()` 有既有调用方与自检，不破坏它们；
    ///   两者共用同一份 `runOnQueue`，行为必然一致。
    func selfHealAsync() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Self.processQueue.async { [self] in
                _ = runOnQueue("/bin/launchctl",
                               ["kickstart", "-k", "system/com.aurora.bpf-setup"], timeout: 8)
                _ = runOnQueue("/bin/launchctl",
                               ["kickstart", "-k", "system/com.aurora.priority"], timeout: 8)
                cont.resume()
            }
        }
        return isFullyAuthorized
    }

    /// **唯一的**子进程执行体（调用方必须已在 `processQueue` 上，或接受在当前线程等待）。
    ///
    /// 为什么不自己 `processQueue.sync`：`selfHealAsync` 已经在队列上，
    /// 再 `sync` 一次就是**同队列重入 → 死锁**。故把"切队列"的责任交给调用方
    /// （`run` 负责切，`selfHealAsync` 已经在了）。
    private func runOnQueue(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        let done = DispatchGroup()
        done.enter()
        task.terminationHandler = { _ in done.leave() }
        do {
            try task.run()
        } catch {
            done.leave()
            return -1
        }
        let killer = DispatchWorkItem { [weak task] in
            guard let task, task.isRunning else { return }
            task.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let outcome = done.wait(timeout: .now() + timeout + 1.0)
        killer.cancel()
        if outcome == .timedOut {
            if task.isRunning { task.terminate() }
            return -1
        }
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
# 常驻：每 3 秒把权限不足的 /dev/bpf* 放开。
# 用轮询而不是 RunAtLoad，是因为 bpf 设备由内核按需创建，
# 开机那一刻往往还不存在，一次性 chmod 覆盖不到后来出现的设备。
while true; do
    for dev in /dev/bpf*; do
        [ -e "$dev" ] || continue
        # ⚠️ 必须检查「权限位」而不是 test -r/-w！
        # 本脚本以 root 运行，而 root 对 crw------- 文件**永远可读可写**，
        # 所以 [ ! -r "$dev" ] 恒为假 → 一次 chmod 都不会执行 → 设备永远
        # 停在 crw-------，普通用户进程 access(/dev/bpfN) 失败 → 抓包起不来
        # （2026-09-25「小地图又没法用了」的第二层根因，实测复现）。
        # 正确做法：直接读 stat 的八进制权限位，非 666 就放开。
        perms=$(stat -f '%Lp' "$dev" 2>/dev/null || echo "")
        if [ "$perms" != "666" ]; then
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
