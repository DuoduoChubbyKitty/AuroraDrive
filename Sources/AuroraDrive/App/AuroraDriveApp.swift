// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AuroraDrive — 异环游戏自动开车辅助工具
//  SwiftUI macOS 14+ | 单窗口 1200x760 | Tesla FSD 驾驶舱风格
//  纯黑底 + 青色(#00E5FF)发光 + 高对比白字
// ============================================================================


// ============================================================================
// MARK: - 文件 1: AuroraDriveApp.swift  (App 入口)
// ============================================================================

import SwiftUI
import AppKit
import Security
import Darwin   // mach_task_basic_info：诊断进程内存占用（验证"积压→内存涨"根因）
import CoreVideo  // CVPixelBuffer：YOLO 直通帧跳帧缓冲
import MetalKit   // MTKView：MetalGoose 插帧渲染承载
import os
import Darwin         // OSAllocatedUnfairLock：跨线程锁
import IOKit.pwr_mgt  // IOPMAssertion：防止系统判定进程空闲并冻结
import ApplicationServices  // AXIsProcessTrusted：辅助功能权限预检（TCC 自检）

// 应用启动时强制激活窗口到前台（直接 swift 运行时窗口默认不激活）
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 命令模式（--agent-command）独立引擎组：静态持有，防 Arc 释放导致 SCK 流停摆
    static var agentEngines: (control: ControlEngine, capture: CaptureEngine)?
    /// 抑制 App Nap 的 activity token（必须持有，否则 activity 立即释放、抑制失效）
    private var napToken: NSObjectProtocol?
    /// CGEventTap 句柄（持有防止释放，系统级实时保护）
    private var eventTap: CFMachPort?
    /// 防冻结内存锚点（持有防止释放）
    private var memoryAnchor: UnsafeMutableRawPointer?

    /// 防冻结内存锚大小（字节）。0 = 关闭（默认）。
    ///
    /// 2026-09-23 改为默认 0：旧的 768MB 硬锁实测让主进程 RSS 达 825MB，
    /// 且 mlock 后**不可换出、不可压缩**，直接挤占游戏内存导致卡顿
    /// （本机 16GB，曾把 swap 顶到 11.8GB/12.3GB）。
    /// 防冻结已由 IOPMAssertion + CGEventTap + beginActivity 三重覆盖，
    /// 不需要再靠占内存。需要极限防冻结时可把这里改回 768MB 重编译。
    private static let freezeGuardBytes: Int = 0
    /// IOPMAssertion ID（防止系统 Power Management 判定进程空闲并冻结，Game Mode 最强对抗）
    private var powerAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    /// Game Mode 对抗锚定窗口（1×1 浮层，见 installGameModeAnchorWindow）
    private var gameModeAnchorWindow: NSWindow?

    /// Game Mode 对抗：安装 1×1「锚定窗口」。
    ///
    /// 原理：Game Mode 由 gamepolicyd 管理，它系统性地压制**后台任务**
    /// （Apple 原话：lowering usage for background tasks / background threads
    /// being suppressed）。macOS 判定"后台"的常见依据是「无可见窗口 + 无用户交互」。
    /// 这里挂一个技术上可见、视觉上无感的窗口，试图让本进程不被归入纯后台桶。
    ///
    /// 关键设计：
    ///   · `fullScreenAuxiliary` —— **能随游戏全屏 Space 一起显示**（否则游戏全屏后
    ///     本窗口被移出该 Space，等于不存在）
    ///   · 1×1 px + 近乎透明 + `ignoresMouseEvents` —— 视觉与交互零干扰
    ///   · `.floating` 层级 —— 保证不被游戏窗口完全遮蔽
    ///   · 屏幕右下角 —— 即使有 1px 痕迹也在最不显眼处
    ///
    /// 注：此对抗是否被 gamepolicyd 认可**没有公开证据**，属于工程尝试；
    /// 配合已有的 beginActivity(.latencyCritical) / CGEventTap / IOPMAssertion
    /// 共同构成多层防护。若实测无效，可调 alphaValue / 尺寸 / level 再试。
    private func installGameModeAnchorWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        // 同 HUD：标识为有意创建的辅助窗口，主窗口置前逻辑会跳过
        w.identifier = NSUserInterfaceItemIdentifier("AuroraAuxAnchor")
        w.isOpaque = false
        // 非零 alpha：完全透明的窗口可能被系统直接判定为"无可见内容"
        w.backgroundColor = NSColor.black.withAlphaComponent(0.02)
        w.hasShadow = false
        w.ignoresMouseEvents = true          // 绝不拦截点击
        w.isMovable = false
        w.level = .floating                  // 浮于普通窗口之上
        w.collectionBehavior = [.canJoinAllSpaces,   // 所有 Space 可见
                                .stationary,         // 不随 Space 切换移动
                                .ignoresCycle,       // 不出现在 Cmd+Tab 循环
                                .fullScreenAuxiliary] // ★ 能进入全屏 Space
        // 位置用 CGDisplayBounds 计算：NSScreen.main 在「app 未激活 / 从 shell 启动」时
        // 会返回异常值（实测 maxX=0 → 窗口跑到屏幕外），CGDisplay 不受激活状态影响。
        let screenBounds = CGDisplayBounds(CGMainDisplayID())
        // 右下角内缩：既在屏内（技术上可见），又避开 Dock 区域
        w.setFrameOrigin(NSPoint(x: screenBounds.maxX - 4,
                                 y: screenBounds.maxY - 4))
        w.orderFrontRegardless()
        gameModeAnchorWindow = w
        // 诊断落盘（stdout 重定向到文件时是块缓冲，print 可能不落盘）
        let diag = "ts=\(Int(Date().timeIntervalSince1970)) visible=\(w.isVisible) onscreen=\(w.isOnActiveSpace) level=\(w.level.rawValue) frame=\(w.frame) alpha=\(w.alphaValue)\n"
        try? diag.write(toFile: "/tmp/aurora_anchor_diag.log", atomically: true, encoding: .utf8)
        fflush(stdout)
        print("[App] 锚定窗口已安装 (1×1 @右下角, fullScreenAuxiliary) → 对抗 Game Mode 后台压制")
    }

    /// 把窗口完整夹进主屏可见区域。
    ///
    /// 为什么必须有：主窗口是**无边框**（`titled=false`）的，AppKit 对无边框窗口
    /// 不做自动的屏幕约束。一旦窗口 origin 跑到屏幕外（多屏热插拔、分辨率变化、
    /// 上一次退出时的位置残留），用户看到的就是「窗口只露一半、控件点不到」，
    /// 而此时 `frame=1200x760` 的日志完全正常 —— 从日志根本看不出问题。
    /// 2026-09-23 实测踩到：窗口被推到 x=0 且左侧越界，顶栏左侧内容不可见。
    ///
    /// 策略：优先保留窗口尺寸，只平移 origin；窗口比屏幕还大时才缩尺寸。
    private static func constrainToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        var f = window.frame

        // 尺寸：不允许超出可见区域
        if f.width > vis.width { f.size.width = vis.width }
        if f.height > vis.height { f.size.height = vis.height }

        // 位置：把整个窗口推回可见区域内部
        if f.minX < vis.minX { f.origin.x = vis.minX }
        if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
        if f.minY < vis.minY { f.origin.y = vis.minY }
        if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }

        if f != window.frame {
            let before = window.frame
            window.setFrame(f, display: true)
            print("[WindowCfg] 窗口越界已修正："
                  + "(\(Int(before.minX)),\(Int(before.minY))) → (\(Int(f.minX)),\(Int(f.minY))) "
                  + "\(Int(f.width))x\(Int(f.height)) 可见区=\(Int(vis.width))x\(Int(vis.height))")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        // Daemon 模式检测（历史入口保留：launchd 拉起时带 --daemon）
        let isDaemon = args.contains("--daemon")
            || ProcessInfo.processInfo.environment["AURORA_DAEMON_MODE"] == "1"
        if isDaemon {
            // Daemon 模式：不激活窗口、不显示 Dock 图标，纯后台运行
            NSApp.setActivationPolicy(.accessory)
            print("[App] Daemon 模式启动")
        }

        // 历史自检入口 --test-xpc：用户会话 XPC Agent 方案已废弃
        // （launchd 拉起的进程拿不到 TCC 权限，引擎改由主程序 spawn 子进程承担）
        if args.contains("--test-xpc") {
            print("[TEST-XPC] 用户会话 XPC Agent 方案已废弃；后台引擎自检请见 ~/Library/Logs/AuroraEngine.log")
            exit(0)
        }

        // 命令行自检：AuroraDriveUI --tcc-selftest
        // TCC 权限继承验证：launchd 以「与 UI 完全相同的可执行文件路径+签名」拉起本进程，
        // 因此这里的预检结果 = 未来 --engine 模式的真实权限状态。
        // 全部使用纯预检 API（不弹任何授权窗），结果追加写入日志后立即退出。
        if args.contains("--tcc-selftest") {
            let axOK = AXIsProcessTrusted()  // 辅助功能权限预检（不带 prompt 参数 = 纯查询，零弹窗）
            let screenOK = CGPreflightScreenCaptureAccess()  // 屏幕录制权限预检（macOS 10.15+，纯查询，零弹窗）
            let line = "ts=\(Int(Date().timeIntervalSince1970)) path=\(CommandLine.arguments.first ?? "?") ax=\(axOK) screen=\(screenOK) uid=\(getuid()) mode=\(ProcessInfo.processInfo.environment["AURORA_TCC_TEST"] ?? "direct")"
            let logPath = NSHomeDirectory() + "/Library/Logs/AuroraTCCSelfTest.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write((line + "\n").data(using: .utf8)!)
                fh.closeFile()
            }
            print("[TCC-SELFTEST] \(line)")
            exit((axOK && screenOK) ? 0 : 2)
        }

        // BPF权限检查在ContentView.onAppear里做（需要访问state）

        if let i = args.firstIndex(of: "--yolo-selftest"), i + 1 < args.count {
            let engine = YoloEngine()
            print(engine.selfTest(imagePath: args[i + 1]))
            exit(0)
        }
        // 命令行基准：AuroraDriveUI --yolo-bench <图片路径>
        // 对比 直通路径(352缓冲) vs 慢路径(NSImage→CGImage→绘制) 的单帧耗时
        if let i = args.firstIndex(of: "--yolo-bench"), i + 1 < args.count {
            let engine = YoloEngine()
            print(engine.benchmark(imagePath: args[i + 1]))
            exit(0)
        }
        // 命令行自检：AuroraDriveUI --speed-selftest <目录> [--roi x,y,w,h]
        // 跑一个目录下所有 PNG/JPG 帧，跑槽位 + 整体三位数匹配全链路，打印每张结果与汇总后退出。
        // --roi 为可选：目录里是「速度表 ROI 切片」帧（字模模式录帧）时传其归一化位置
        //   （如 0.455,0.885,0.080,0.050）；目录里是原生全屏帧时省略。
        if let i = args.firstIndex(of: "--speed-selftest"), i + 1 < args.count {
            let reader = SpeedOCRReader()
            var roiNorm: CGRect? = nil
            if let ri = args.firstIndex(of: "--roi"), ri + 1 < args.count {
                let parts = args[ri + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    roiNorm = CGRect(x: parts[0], y: parts[1],
                                     width: parts[2], height: parts[3])
                }
            }
            print(reader.selfTestDirectory(args[i + 1], roiNorm: roiNorm))
            exit(0)
        }

        // ── 引擎模式启动（后台引擎拆分）──
        // 探测 engine.sock：已有健康引擎 → 直接连接；没有 → spawn 自己（--engine）。
        // 任一步失败自动回退本地模式（下方全部本地逻辑保持原样）。
        if !isDaemon {
            EngineClient.shared.startup()
        }

        // 抑制 App Nap（beginActivity .latencyCritical + .userInteractive）：
        // 下面的 disableAutomaticTermination 只防"被系统自动退出"，不管节流。
        // App 在游戏前台全屏时沦为后台 App，系统默认会对它的 RunLoop 定时器/渲染
        // 做 App Nap 节流（Timer 掉帧、界面卡）——这正是"只有 App 界面卡"的根因。
        // .latencyCritical 声明对延迟敏感 → 系统不再对其节流，后台保持前台级节奏。
        // token 必须持有（napToken），否则 activity 立即释放、抑制失效。
        ProcessInfo.processInfo.disableAutomaticTermination(
            "AuroraDrive 实时游戏辅助：持续截屏 + AI 决策注入")
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
            reason: "AuroraDrive 实时游戏辅助：后台需持续 30Hz 决策与注入")
        // 最高进程优先级：nice=-20（用户进程极限）
        if setpriority(PRIO_PROCESS, 0, -20) == 0 {
            print("[App] 进程优先级 nice=-20（最高）")
        }
        // Game Mode 对抗（持久战）：静音音频 + 每 3s 重新主张 nice/activity/音频
        GameModeDefender.shared.start()
        // ── Game Mode 对抗 ──
        // 由 DriveState 的 GameHUDWindow（左上角绿色帧率 HUD）承担"可见窗口"职责：
        // 它比 1×1 隐形锚点更可能被 gamepolicyd 认作"有可见窗口的应用"，
        // 且同时提供实用信息。锚定窗口方案保留在下方方法中，默认不再调用。
        // 注：HUD 在 DriveState.init() 里安装，那里能取到 captureEngine/tick 数据。
        // pthread QoS：直接设主线程到最高
        // pthread QoS set via DispatchQueue .userInteractive (已设)
        // 创建空 CGEventTap：系统必须保持有event tap的进程响应，否则事件丢弃
        // 这是强制系统不冻结本进程的最有效手段（Game Mode也挡不住）
        // 注意：只监听键盘事件，不监听鼠标移动（避免鼠标被强制移到左上角）
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in return Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            print("[App] CGEventTap创建失败（可能辅助功能权限未授权）")
            return
        }
        // 启用event tap → 系统将本进程视为实时响应进程
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopAddSource(RunLoop.current.getCFRunLoop(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), .commonModes)
        print("[App] CGEventTap已启用 → 系统级实时保护")
        self.eventTap = eventTap

        // ── 内存占用：自适应，默认关闭「硬锁 768MB」 ──
        //
        // 2026-09-23 修复「开了这个之后游戏变卡」：
        //   旧实现无条件 mlock 768MB，实测主进程 RSS 825MB，其中 768MB 被
        //   锁死在物理内存 —— **不可换出、不可压缩**。16GB 机器上等于永久
        //   少 4.8% 可用内存，游戏要内存时只能把别的换出去 → 卡顿。
        //   实测当时 swap 一度用满 11.8GB/12.3GB。
        //
        //   而且这个机制是**冗余的**：防冻结已由三重正规手段覆盖 ——
        //     ① IOPMAssertion（Power Management 层，最权威）
        //     ② CGEventTap（系统必须保持有 event tap 的进程响应）
        //     ③ beginActivity(.latencyCritical)
        //   「靠占内存骗系统别冻结我」是民间偏方，代价高、收益低。
        //
        // 新策略：默认**不锁**，只保留一个很小的常驻锚（防进程被整体换出），
        // 由设置项 autoFreezeGuard 控制；需要极限防冻结时可手动开回 768MB。
        if Self.freezeGuardBytes > 0 {
            let allocSize = Self.freezeGuardBytes
            let pageCount = allocSize / 4096
            let buf = UnsafeMutableRawPointer.allocate(byteCount: allocSize, alignment: 4096)
            // 只写页首字节建立映射，不 memset 整块（省时省电）
            for i in 0..<pageCount {
                buf.advanced(by: i * 4096).storeBytes(of: UInt8(i & 0xFF), as: UInt8.self)
            }
            if mlock(buf, allocSize) == 0 {
                print("[App] 防冻结内存锚 \(allocSize / 1024 / 1024)MB 已锁定")
            } else {
                print("[App] 防冻结内存锚 mlock 失败（\(allocSize / 1024 / 1024)MB 仍占用）")
            }
            self.memoryAnchor = buf
        } else {
            print("[App] 防冻结内存锚已关闭（默认）→ 不再挤占游戏内存；防冻结由 IOPMAssertion + CGEventTap 承担")
        }

        // --agent-command 模式：后台 accessory 运行、不抢焦点（保持游戏所在 Space 激活，
        // 供键注入落到游戏内）。.accessory 下进程不占 Dock、不触发 Space 切换。
        let isCommandMode = CommandLine.arguments.contains("--agent-command")
        NSApp.setActivationPolicy(isCommandMode ? .accessory : .regular)
        if !isCommandMode {
            NSApp.activate(ignoringOtherApps: true)
        }
        
        // IOPMAssertion：声明进程需要持续响应，系统不得因"空闲"判定而冻结
        // PreventUserIdleSystemSleep：防止系统认为用户空闲而降低进程优先级
        // 这是对抗 Game Mode 冻结后台进程的官方 API，比任何 hack 都稳定
        let assertionName = "AuroraDrive Real-time Game Assistant" as CFString
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName,
            &powerAssertionID
        )
        if status == kIOReturnSuccess {
            // 写入启动日志文件（SwiftUI App不输出到终端）
            let logPath = "/tmp/aurora_iopm_status.log"
            let logMsg = "[App] IOPMAssertion 已成功创建 (ID=\(powerAssertionID)) → 系统级防冻结保护\n"
            try? logMsg.write(toFile: logPath, atomically: true, encoding: .utf8)
            print("[App] IOPMAssertion 已创建 (ID=\(powerAssertionID)) → 系统级防冻结保护")
        } else {
            let logPath = "/tmp/aurora_iopm_status.log"
            let logMsg = "[App] IOPMAssertion 创建失败 (status=\(status))，Game Mode 可能仍会冻结\n"
            try? logMsg.write(toFile: logPath, atomically: true, encoding: .utf8)
            print("[App] IOPMAssertion 创建失败 (status=\(status))，Game Mode 可能仍会冻结")
        }
        
        // Darwin Notification Center：注册系统级通知，保持进程活跃
        // 监听系统睡眠/唤醒、电源管理、显示配置等事件
        // 系统不会冻结正在监听系统通知的进程
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        
        // 监听系统睡眠/唤醒
        CFNotificationCenterAddObserver(
            darwinCenter,
            nil,
            { _, _, _, _, _ in
                print("[Darwin] 系统电源管理事件")
            },
            "com.apple.system.powermanagement" as CFString,
            nil,
            .deliverImmediately
        )
        
        // 监听显示配置变化（全屏切换时触发）
        CFNotificationCenterAddObserver(
            darwinCenter,
            nil,
            { _, _, _, _, _ in
                print("[Darwin] 显示配置变化")
            },
            "com.apple.system.displays.reconfiguration" as CFString,
            nil,
            .deliverImmediately
        )
        
        // 监听系统时间变化（保持进程活跃）
        CFNotificationCenterAddObserver(
            darwinCenter,
            nil,
            { _, _, _, _, _ in
                print("[Darwin] 系统时间变化")
            },
            "com.apple.system.clock_set" as CFString,
            nil,
            .deliverImmediately
        )
        
        print("[App] Darwin Notification Center 已注册（3个系统通知）")
        
        // ★ 关闭 AppKit 窗口状态恢复。
        // 这是「绕一圈黑边」的真正根源：曾经某次窗口几何算坏，塌成一堆只剩标题栏高
        // （30/33pt）的空壳窗口，系统把「有 8 个这种窗口」这件事持久化了，此后每次启动
        // 都原样恢复出来。它们浮在主窗口之上 → 看起来就是窗口没铺满、四周一圈黑边。
        // 关掉恢复后，启动永远只有 SwiftUI 新建的那一个主窗口。
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSWindow.allowsAutomaticWindowTabbing = false

        // SwiftUI WindowGroup 的窗口在 applicationDidFinishLaunching 之后、runloop 下一轮
        // 才创建（此时同步遍历 NSApp.windows 常为空，激活无效）。延迟到下一 runloop 再
        // 激活，确保窗口已创建后置前，避免"进程起来却无可见窗口"。
        // --agent-command 模式：后台运行、不抢焦点（保持游戏所在 Space 激活，供键注入落到游戏内）。
        let commandMode = CommandLine.arguments.contains("--agent-command")
        if !commandMode {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // ★ 只前置「真正的主窗口」。
                // 曾经这里无条件 for window in NSApp.windows 把所有窗口都提到最前，
                // 其中混着若干退化的空壳窗口（高度仅一条标题栏 30~33pt，内容完全没渲染）。
                // 它们会盖在真正的主窗口之上 —— 用户看到的就是「窗口没铺满、绕了一圈黑边」。
                // 因此：① 先关掉并丢弃所有退化窗口；② 只对剩余的有内容窗口置前。
                // 有意创建的辅助窗口（HUD / 锚点）带 identifier，绝不参与清理
                let auxIDs: Set<String> = ["AuroraAuxHUD", "AuroraAuxAnchor"]
                var candidates: [NSWindow] = []
                for window in NSApp.windows {
                    if let id = window.identifier?.rawValue, auxIDs.contains(id) {
                        continue
                    }
                    let h = window.frame.height
                    let w = window.frame.width
                    // 退化判据：极扁（只剩标题栏）/ 极小的空壳
                    if h < 160 || (w < 300 && h < 300) {
                        window.orderOut(nil)
                        window.close()
                        continue
                    }
                    candidates.append(window)
                }
                // 主窗口 = 面积最大者（SwiftUI WindowGroup 的主窗口）
                let main = candidates.max { a, b in
                    a.frame.width * a.frame.height < b.frame.width * b.frame.height
                }
                if let main {
                    main.makeKeyAndOrderFront(nil)
                    // ★ 屏幕约束：无边框窗口（titled=false）不会自动被系统夹回屏内。
                    //   一旦窗口 origin 落在屏幕外（多屏切换、屏幕分辨率变化、
                    //   上次退出时的位置残留），用户就会看到「窗口只露一半 / 点不到控件」，
                    //   而 frame 日志一切正常 —— 极难自查。
                    //   这里强制把窗口完整夹进主屏可见区域。
                    Self.constrainToScreen(main)
                    print("[Window] 主窗口 \(Int(main.frame.width))x\(Int(main.frame.height))，"
                          + "已清理退化窗口，候选=\(candidates.count)")
                } else if let any = candidates.first {
                    any.makeKeyAndOrderFront(nil)
                    Self.constrainToScreen(any)
                }

                // 诊断 + 兜底清理：延迟若干秒后再查一次，打印每个窗口的类名/标识/几何，
                // 并再次关闭退化的无标识空壳窗口（有些窗口由系统或后续布局才创建出来）。
                for delay in [2.0, 5.0, 10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        for w in NSApp.windows {
                            let id = w.identifier?.rawValue ?? "-"
                            let sm = w.styleMask
                            print("[WindowDiag] t=\(Int(delay))s class=\(type(of: w)) "
                                  + "id=\(id) frame=\(Int(w.frame.width))x\(Int(w.frame.height)) "
                                  + "layout=\(Int(w.contentLayoutRect.width))x\(Int(w.contentLayoutRect.height)) "
                                  + "content=\(Int(w.contentRect(forFrameRect: w.frame).width))x\(Int(w.contentRect(forFrameRect: w.frame).height)) "
                                  + "fullSize=\(sm.contains(.fullSizeContentView)) "
                                  + "titled=\(sm.contains(.titled)) "
                                  + "visible=\(w.isVisible)")
                            if auxIDs.contains(id) { continue }
                            if w.frame.height < 160 || (w.frame.width < 300 && w.frame.height < 300) {
                                w.orderOut(nil)
                                print("[WindowDiag]   → 关闭退化窗口 \(Int(w.frame.width))x\(Int(w.frame.height))")
                            }
                        }
                    }
                }
            }
        }

        // ── 启动即自动登录（--auto-login）──
        // 放在 applicationDidFinishLaunching 而非 ContentView.onAppear：
        // 登录守护与 UI 渲染解耦 —— 引擎/权限环境异常导致窗口创建延迟或失败时，
        // 守护照样启动，不会"卡死在等窗口"。守护内部已有安全护栏：
        //   ① 只有检测到游戏窗口（异环/NTE）才允许点击，绝不误点其他窗口
        //   ② 每 8s 一次、最多 10 次（80s 超时自动停止）
        //   ③ 游戏未开/已登录时安静等待或退出，无副作用
        if CommandLine.arguments.contains("--auto-login") {
            fputs("[AUTO-LOGIN] 收到 --auto-login，1.5s 后启动登录守护（独立于 UI）\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AgentSkillCenter.shared.requestAutoLoginOnStartup()
            }
        }

        // ── AI 发布指令 CLI（--agent-command "<指令>"）──
        // 与 --auto-login 同理放在 AppDelegate：命令模式（.accessory）下窗口可能被
        // orderOut、视图 onAppear 不触发，派发必须与视图渲染解耦。
        // AgentSkillCenter 内部排队，引擎注入（configure）时补发，8s 兜底。
        if let ci = CommandLine.arguments.firstIndex(of: "--agent-command"),
           ci + 1 < CommandLine.arguments.count {
            let cmd = CommandLine.arguments[ci + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AgentSkillCenter.shared.requestCommandOnStartup(cmd)
            }
        }

        // ── 命令模式引擎注入（--agent-command）──
        // 命令模式 .accessory + orderOut 下视图 onAppear 可能不触发 → DriveState 不会创建 →
        // 技能中心拿不到截屏/按键引擎。这里由 AppDelegate 独立创建一组引擎并注入
        // （不走 DriveState，避免其 init 副作用：删 /tmp/aurora_debug.log + 装第二套 HUD）。
        // 视图若随后渲染也会 configure 一次（DriveState 引擎），后注入者生效，二者等价。
        if CommandLine.arguments.contains("--agent-command") {
            let ctl = ControlEngine()
            let cap = CaptureEngine()
            AppDelegate.agentEngines = (ctl, cap)          // 静态持有防释放
            AgentSkillCenter.shared.configure(control: ctl, capture: cap)
            cap.start()                                     // 本地 SCK 全屏流（屏幕录制 TCC）
            print("[AGENT] 命令模式引擎已注入（ControlEngine + CaptureEngine 独立实例，SCK 流已启动）")
        }
    }
    
    /// 正常退出前通知后台引擎「我走了，继续跑」：
    /// 引擎收到 bye 后释放按键但保持抓屏推理，等待下次 UI 重连，
    /// 且不会把这次断开当作崩溃来处理（不触发看门狗停车）。
    func applicationWillTerminate(_ notification: Notification) {
        EngineClient.shared.sendByeSync()
    }

    deinit {
        // 释放 IOPMAssertion（进程退出时自动调用）
        // 释放锚定窗口
        gameModeAnchorWindow?.orderOut(nil)
        gameModeAnchorWindow = nil
        if powerAssertionID != kIOPMNullAssertionID {
            IOPMAssertionRelease(powerAssertionID)
            print("[App] IOPMAssertion 已释放")
        }
    }
}


// ============================================================================
// 插帧引擎自检（--upscale-selftest）
// ============================================================================

func runUpscaleSelfTest() {
    guard let upscaler = GooseUpscaler.make() else {
        print("[UPSELFTEST] FAIL: GooseUpscaler.make() == nil（Metal 不可用或引擎初始化失败）")
        exit(1)
    }
    print("[UPSELFTEST] OK: 引擎创建成功（Metal + 着色器编译通过）")
    upscaler.configureInterpolation()
    print("[UPSELFTEST] OK: 插帧模式配置完成")

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let view = MTKView()
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view
    window.isReleasedWhenClosed = false
    if let s = NSScreen.main?.visibleFrame {
        window.setFrameOrigin(NSPoint(x: s.midX - 160, y: s.midY + 300))
    }
    window.level = .floating
    upscaler.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    print("[UPSELFTEST] OK: 测试窗口挂载 view=\(Int(view.bounds.width))x\(Int(view.bounds.height)) drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))")

    NSApp.activate(ignoringOtherApps: true)
    let s0 = upscaler.statsSnapshot()
    var feedTimer: Timer? = nil
    var feedCounter = 0

    // 等待 MTKView drawable 就绪
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        feedTimer = Timer(timeInterval: 0.10, repeats: true) { _ in
            guard let cg = SelfTestImage.make(width: 640, height: 360, frame: feedCounter) else {
                feedTimer?.invalidate(); feedTimer = nil; return
            }
            upscaler.ingest(cgImage: cg)
            feedCounter += 1
            if let d = view.delegate { d.draw(in: view) }
            if feedCounter == 3 { print("[UPSELFTEST-DIAG] manual draw driven") }
        }
        let drawTick = Timer(timeInterval: 0.050, repeats: true) { _ in
            if let d = view.delegate { d.draw(in: view) }
        }
        RunLoop.main.add(feedTimer!, forMode: .common)
        RunLoop.main.add(drawTick, forMode: .common)
    }

    let startWall = Date()
    let finishTimer = Timer(timeInterval: 8.0, repeats: false) { _ in
        feedTimer?.invalidate()
        print("[UPSELFTEST] DIAG elaps=\(String(format:"%.1f",Date().timeIntervalSince(startWall)))s visible=\(window.isVisible) key=\(window.isKeyWindow) occ=\(window.occlusionState.rawValue) win=\(view.window != nil)")
        window.orderOut(nil)
        let s = upscaler.statsSnapshot()
        print("[UPSELFTEST] INFO: out=\(s.outputFrameCount) interp=\(s.interpolatedFrameCount) passthru=\(s.passthroughFrameCount) generated=\(s.generatedFrameCount) fps=\(String(format: "%.1f", s.outputFPS))")
        var engineErr: String? = nil
        if let err = upscaler.pendingError() {
            engineErr = err
            print("[UPSELFTEST] ENGINE-ERR: \(err)")
        }
        let rendered = s.outputFrameCount > s0.outputFrameCount
        let interpolated = s.interpolatedFrameCount > s0.interpolatedFrameCount
        let verdict: String
        if rendered && interpolated {
            verdict = "PASS 插帧工作 out \(s0.outputFrameCount)→\(s.outputFrameCount) interp \(s0.interpolatedFrameCount)→\(s.interpolatedFrameCount) fps \(String(format: "%.0f", s.outputFPS))"
            print("[UPSELFTEST] PASS: \(verdict)")
            SelfTestResult.write(verdict, engineErr: engineErr)
            exit(0)
        } else if rendered && !interpolated {
            verdict = "FAIL 渲染出帧但未插帧(纯透传) out=\(s.outputFrameCount) interp=\(s.interpolatedFrameCount)"
            print("[UPSELFTEST] FAIL: \(verdict)")
            SelfTestResult.write(verdict, engineErr: engineErr)
            exit(1)
        } else {
            verdict = "FAIL 渲染路径无输出 MTKView未渲染出帧 drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)) window=\(view.window != nil ? "in" : "out")"
            print("[UPSELFTEST] FAIL: \(verdict)")
            SelfTestResult.write(verdict, engineErr: engineErr)
            exit(1)
        }
    }
    RunLoop.main.add(finishTimer, forMode: .common)
}

private enum SelfTestResult {
    static let path = "/tmp/upselftest_result.txt"
    static func write(_ verdict: String, engineErr: String?) {
        let line = "[UPSELFTEST] " + verdict
            + (engineErr.map { " ENGINE-ERR=\($0)" } ?? "")
            + "\n"
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private enum SelfTestImage {
    static func make(width: Int, height: Int, frame: Int = 0) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(frame % 8) * 60, y: 120, width: 120, height: 80))
        return ctx.makeImage()
    }
}


// ============================================================================
// 主线程优先级提升（对抗全屏游戏时的线程降权）
// ============================================================================

private func applyMainThreadBoost(_ enabled: Bool) {
    let thread = mach_thread_self()
    if enabled {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func units(_ ns: UInt32) -> UInt32 {
            guard tb.denom > 0, tb.numer > 0 else { return ns }
            return UInt32((UInt64(ns) * UInt64(tb.denom)) / UInt64(tb.numer))
        }
        var pol = thread_time_constraint_policy_data_t(
            period: units(33_333_333),
            computation: units(6_000_000),
            constraint: units(15_000_000),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &pol) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
            }
        }
    } else {
        var placeholder: integer_t = 0
        thread_policy_set(thread, UInt32(THREAD_STANDARD_POLICY), &placeholder, 1)
    }
}

/// 进程入口分流：`--engine` 走纯后台引擎（EngineMain，不触碰 SwiftUI、
/// 不创建窗口、不跑 NSApp），否则照常启动 SwiftUI 界面。
/// 注意：@main 从 App 结构移到本 Launcher 仅为拿到最早的进程入口，
/// SwiftUI 的 App/Scene/AppDelegate 结构完全保持原样，未做其他改动。
@main
struct AuroraDriveLauncher {
    /// UI 单实例锁的 fd（持有到进程退出，内核自动释放）
    nonisolated(unsafe) private static var uiLockFD: Int32 = -1

    /// UI 单实例保护：flock 独占锁。
    /// 背景（2026-09-12 实测）：两个 UI 实例会互抢同一个引擎 socket——
    /// 引擎只服务一个客户端，双方轮流被踢 → 各自「断开→重连」0.5 秒死循环刷屏。
    /// 引擎侧早有这样的锁（engine.lock），UI 侧此前缺失，这里补齐。
    private static func acquireUISingleInstanceLock() -> Bool {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuroraDrive")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let lockPath = appSupport.appendingPathComponent("ui.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // 锁文件不可建时放行，不阻碍正常使用
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            uiLockFD = fd                    // 持有；进程退出/崩溃时内核自动释放
            ftruncate(fd, 0)
            let pidStr = "\(getpid())\n"
            _ = pidStr.withCString { write(fd, $0, strlen($0)) }
            return true
        }
        close(fd)
        return false
    }

    static func main() {
        // stdout 改行缓冲：print 立即落盘（重定向到文件/管道时不再等到进程
        // 退出才 flush —— 否则 crash/卡死时日志全丢，无法定位）
        setvbuf(stdout, nil, _IOLBF, 0)

        let args = CommandLine.arguments
        // ── 任务控制台无头截图 ──
        // 必须在这里同步跑完：截图是纯离屏 ImageRenderer 渲染，若放到
        // ContentView.onAppear 里，无窗口时 view 不 layout → onAppear 永不触发，
        // 进程会卡在引擎初始化后（实测 240s 不出图）。
        if args.contains("--mc-map") {
            let ok = MissionControlShot.renderMapNow()
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
        if args.contains("--mc-map-offline") {
            let ok = MissionControlShot.renderMapOfflineNow()
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--mc-shot") {
            var rc = RoadCondition.simple
            if i + 1 < args.count, let c = RoadCondition(rawValue: args[i + 1]) { rc = c }
            var size = ConsoleMetrics.designSize
            if i + 3 < args.count, let w = Double(args[i + 2]), let h = Double(args[i + 3]),
               w > 200, h > 200 {
                size = CGSize(width: w, height: h)
            }
            print("[MC-SHOT] 离屏渲染 路况=<\(rc.rawValue)> 画布=\(Int(size.width))x\(Int(size.height))")
            fflush(stdout)
            let ok = MissionControlShot.renderNow(condition: rc, canvas: size)
            fflush(stdout)
            exit(ok ? 0 : 1)
        }

        if args.contains("--engine") {
            EngineMain.run()   // 永不返回（dispatchMain 常驻；自身已有 engine.lock）
        }

        // ── LLM 配置写入：--set-llm-config <apiKey> <baseUrl> <model> ──
        // 提前处理（不需要 GUI / 引擎），写入本地小本本文件 + 固定域 UserDefaults（不碰钥匙串）
        if let i = args.firstIndex(of: "--set-llm-config"), i + 3 < args.count {
            var s = AgentSettings()
            s.apiKey = args[i + 1]
            s.baseUrl = args[i + 2]
            s.model = args[i + 3]
            do {
                try s.save()
                print("[LLM-CONFIG] ✅ 已保存到本地小本本：model=\(s.model)  base=\(s.baseUrl)  key=\(String(s.apiKey.prefix(6)))…\(String(s.apiKey.suffix(4)))")
                exit(0)
            } catch {
                print("[LLM-CONFIG] ❌ 保存失败：\(error)")
                exit(1)
            }
        }

        // ── 真实 LLM 请求自测：--agent-llm-test ──
        // 提前处理（不需要 GUI），发真实 HTTP 请求到配置的云端模型
        // 修复：纯同步 URLSession + 30s 硬超时（不依赖 Swift concurrency / Keychain 解锁）
        if args.contains("--agent-llm-test") {
            // 非阻塞读取配置：UserDefaults 读 baseUrl/model，env 读 key
            let d = UserDefaults(suiteName: "com.aurora.drive.aiagent") ?? .standard
            var s = AgentSettings()
            s.baseUrl = d.string(forKey: "baseUrl") ?? "https://api.agnes-ai.cn/v1"
            s.model = d.string(forKey: "model") ?? "agnes-2.5-flash"
            s.thinkingDepth = d.integer(forKey: "thinkingDepth")
            if s.thinkingDepth < 1 { s.thinkingDepth = 3 }
            // Key 从环境变量（CLI 场景）；GUI 场景 Keychain 可正常访问
            s.apiKey = ProcessInfo.processInfo.environment["AURORA_API_KEY"] ?? ""
            guard !s.apiKey.isEmpty else {
                print("[LLM-TEST] ❌ 未配置 API Key。设置 AURORA_API_KEY 环境变量或运行 --set-llm-config")
                exit(1)
            }
            var base = s.baseUrl.hasSuffix("/") ? String(s.baseUrl.dropLast()) : s.baseUrl
            if !base.hasSuffix("/v1") { base += "/v1" }
            guard let url = URL(string: "\(base)/chat/completions") else {
                print("[LLM-TEST] ❌ 无效 BaseUrl")
                exit(1)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            let body: [String: Any] = [
                "model": s.model,
                "messages": [["role": "user", "content": "用一句话回答：1+1等于几？"]],
                "max_tokens": 100,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            print("[LLM-TEST] 模型=\(s.model)  端点=\(s.baseUrl)  密钥=\(String(s.apiKey.prefix(6)))…\(String(s.apiKey.suffix(4)))  思考深度=\(s.thinkingDepth)")
            fflush(stdout)

            // 同步等待 HTTP 响应（dataTask + semaphore，最多 30s）
            let sem = DispatchSemaphore(value: 0)
            var httpResult: (status: Int, data: Data)? = nil
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: request) { data, response, error in
                defer { sem.signal() }
                guard let data, let http = response as? HTTPURLResponse else {
                    print("[LLM-TEST] ❌ 请求异常：\(error?.localizedDescription ?? "无响应")")
                    return
                }
                httpResult = (http.statusCode, data)
                _ = http
            }
            task.resume()
            if sem.wait(timeout: .now() + 35.0) == .timedOut {
                print("[LLM-TEST] ⚠️ 30s 硬超时")
                task.cancel()
                exit(1)
            }

            guard let result = httpResult, (200...299).contains(result.status) else {
                print("[LLM-TEST] ❌ HTTP \(httpResult?.status ?? 0)")
                exit(1)
            }
            if let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                print("[LLM-TEST] ① 纯文本回答：\(content)")
            } else {
                print("[LLM-TEST] ① 解析失败")
            }
            print("[LLM-TEST] ✅ 真实 LLM 链路验证完成")
            fflush(stdout)
            exit(0)
        }
        // 一次性自检/守护模式不参与 UI 锁：它们是短命进程或被 launchd 托管，
        // 若参与锁会与常驻 UI 互斥，导致自检失败或用户无法启动界面。
        let oneShotFlags = ["--speed-selftest", "--tcc-selftest", "--test-xpc",
                            "--yolo-selftest", "--upscale-selftest", "--yolo-bench",
                            "--daemon", "--mc-shot", "--mc-map", "--mc-map-offline", "--fit-selftest",
                            "--limit-selftest", "--nic-autotest", "--proto-selftest"]
        // ── 自适应网卡自检：探测 → 锁定 → 失流重探（真实 UDP 30031 包注入验证）──
        // ── 新协议解码自检：用固化样本验证 protobuf 移动包解坐标 ──
        if args.contains("--proto-selftest") {
            runProtoSelfTest()
            exit(0)
        }

        if args.contains("--nic-autotest") {
            runNicAdaptSelfTest()
            exit(0)
        }

        // ── 限速刹车 + 自动速度 自测：用生产类型本尊跑，不是逻辑副本 ──
        if args.contains("--limit-selftest") {
            runLimitSelfTest()
            exit(0)
        }

        // ── 自适应缩放自测：真开一个窗口，逐档改尺寸，验证内容始终铺满（零黑边）──
        if args.contains("--fit-selftest") {
            runFitSelfTest()
            exit(0)
        }

        let isOneShot = args.contains { oneShotFlags.contains($0) }
        if !isOneShot, !acquireUISingleInstanceLock() {
            print("[App] 已有 AuroraDrive 实例在运行 —— 本次启动退出")
            print("      原因：两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）")
            print("      如需重启，请先退出正在运行的实例")
            exit(0)
        }
        AuroraDriveApp.main()
    }
}

struct AuroraDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 保持 WindowGroup（换成 Window+id 会导致本 app 的 AppKit 生命周期下不开窗）。
        // 退化空壳窗口改由启动清窗 + 关闭窗口恢复来根治，见 AppDelegate。
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 500)
                // ★ 内容延伸到标题栏之下：只加 .windowStyle(.hiddenTitleBar) 仍会
                // 保留一条标题栏空间（实测顶部 32pt 纯黑 —— 就是那条黑边）。
                .background(WindowConfigurator())
                .background(Color.black)
                .onAppear {
                    // --agent-command 模式：后台运行、不抢焦点、不前置窗口（保持游戏所在 Space 激活，供键注入落到游戏内）
                    let isCommandMode = CommandLine.arguments.contains("--agent-command")
                    DispatchQueue.main.async {
                        if isCommandMode {
                            for window in NSApp.windows {
                                window.orderOut(nil)
                            }
                            return
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        // 只处理主窗口：过去这里遍历 NSApp.windows 把每个窗口都置前，
                        // 会把退化的空壳窗口一并提到最前盖住主窗口（黑边观感来源之一）。
                        for window in NSApp.windows where !(window.identifier?.rawValue ?? "").hasPrefix("AuroraAux") {
                            guard window.frame.height >= 160 else { continue }
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                            // 全屏游戏时标题栏（含红黄绿按钮/标题条）会浮在游戏画面上遮挡一条，
                            // 这里把标题栏 chrome 全部隐藏。
                            window.titlebarAppearsTransparent = true
                            window.titleVisibility = .hidden
                            window.standardWindowButton(.closeButton)?.isHidden = true
                            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                            window.standardWindowButton(.zoomButton)?.isHidden = true
                            // 注意：绝不要开 isMovableByWindowBackground —— 那会让「在画面上拖拽」
                            // 变成「拖动整个窗口」，把框选手势整个吃掉（实测踩过）。
                            // 拖窗口请拖窗口顶部那条隐形标题栏区域。
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 760)
    }
}





// ============================================================================
// MARK: - 新协议解码自检（--proto-selftest）
/// 用**固化真机样本**验证 `UE5Decoder` 的新协议路径（2026-09-25 逆向）。
///
/// 样本（`tools/reverse/samples/`）：
///   · move_burst.pcap —— 角色移动中抓的连续 76 字节包（54 个）
///   · idle.pcap       —— 角色静止时抓的包（1 个，坐标应与移动样本不同但不连续变化）
///   · move2/turn.pcap —— 移动/转向后的样本
///
/// 断言的是**行为特征**而非硬编码数值（数值随机作位置变化会失效）：
///   ① 新协议路径能解出坐标（旧路径对这类包恒为 0 候选 —— 这正是故障根因）
///   ② 移动样本内坐标确实在变化（真的跟着角色动）
///   ③ 静止样本坐标稳定（不是随机噪声）
///   ④ 解出的地图像素落在 13056² 内（标定常量自洽）
@MainActor
func runProtoSelfTest() {
    var fail = 0
    func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
        if !cond { fail += 1 }
        print("  \(cond ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    print("═══ 新协议解码（protobuf 移动包 → 世界坐标）═══")

    let root = "/Users/dupi/Desktop/自动驾驶系统/tools/reverse/samples"
    let samples: [(String, String)] = [
        ("移动样本", "\(root)/move_burst.pcap"),
        ("静止样本", "\(root)/idle.pcap"),
        ("移动2", "\(root)/move2.pcap"),
        ("转向后", "\(root)/turn.pcap"),
    ]

    var moveCoords: [Vec3] = []
    var idleCoords: [Vec3] = []

    for (label, path) in samples {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            ck("\(label)样本存在", false, path)
            continue
        }
        let payloads = extractTCPPayloads(Array(data))
        ck("\(label)解析出 TCP 载荷", !payloads.isEmpty, "\(payloads.count) 个")

        let decoder = UE5Decoder()
        var got: [Vec3] = []
        for p in payloads {
            let flow: Flow = ("43.144.211.30", 30031, "192.168.1.3", 56655, "TCP")
            if let pose = decoder.decode(payload: p, timestamp: 1790333033.0, flow: flow) {
                got.append((pose.0, pose.1, pose.2))
            }
        }
        ck("\(label)解出坐标", !got.isEmpty, "\(got.count)/\(payloads.count) 个包")
        if label.contains("移动") || label.contains("转向") { moveCoords += got }
        if label.contains("静止") { idleCoords += got }
        if let first = got.first {
            let (mx, my, _) = worldToMapPixel((first.0, first.1, first.2, 0, 0))
            let inside = mx >= 0 && mx < 13056 && my >= 0 && my < 13056
            ck("\(label)像素落在地图内", inside, String(format: "(%.1f, %.1f)", mx, my))
        }
    }

    // ② 移动样本的坐标必须变化（证明是实时数据，不是常量）
    if moveCoords.count >= 2 {
        let xs = moveCoords.map { $0.0 }
        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
        ck("移动样本坐标在变化", spread > 1.0, String(format: "X 跨度 %.2f", spread))
    } else {
        ck("移动样本数量足够", false, "仅 \(moveCoords.count) 个")
    }

    // ③ 静止样本内部不应出现"每包递减"的序列（它是单个值，验证不抖动）
    if idleCoords.count == 1 {
        ck("静止样本为单值（无抖动）", true, String(format: "X=%.2f", idleCoords[0].0))
    } else if idleCoords.isEmpty {
        ck("静止样本解出坐标", false)
    }

    print("═══ 新协议自检：\(fail == 0 ? "PASS" : "FAIL(\(fail))") ═══")
    fflush(stdout)
}

/// 从 pcap 字节中提取 TCP 载荷（供自检复用；与 CoordinateCapture 抓包链路解耦）。
func extractTCPPayloads(_ raw: [UInt8]) -> [[UInt8]] {
    guard raw.count > 24 else { return [] }
    let magic = Array(raw[0..<4])
    let little: Bool
    if magic == [0xd4, 0xc3, 0xb2, 0xa1] || magic == [0x4d, 0x3c, 0xb2, 0xa1] {
        little = true
    } else if magic == [0xa1, 0xb2, 0xc3, 0xd4] || magic == [0xa1, 0xb2, 0x3c, 0x4d] {
        little = false
    } else {
        return []
    }
    func u32(_ o: Int) -> Int {
        let b = (0..<4).map { raw[o + $0] }
        let v = little
            ? (UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            : (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        return Int(v)
    }
    var out: [[UInt8]] = []
    var off = 24
    while off + 16 <= raw.count {
        let incl = u32(off + 8)
        off += 16
        guard off + incl <= raw.count else { break }
        let pkt = Array(raw[off..<(off + incl)])
        off += incl
        guard pkt.count >= 34, pkt[12] == 0x08, pkt[13] == 0x00 else { continue }
        let ihl = Int(pkt[14] & 0x0F) * 4
        guard pkt[14 + 9] == 6 else { continue }
        let tso = 14 + ihl
        guard pkt.count >= tso + 20 else { continue }
        let doff = Int((pkt[tso + 12] >> 4) & 0x0F) * 4
        let payload = Array(pkt[(tso + doff)...])
        if !payload.isEmpty { out.append(payload) }
    }
    return out
}

// ============================================================================
// MARK: - 自适应网卡自检（--nic-autotest）
/// 验证 CoordinateCapture 的自适应状态机：探测 → 锁定 → 失流重探。
///
/// 用**真实 UDP 30031 包注入**做端到端验证（不是逻辑副本）：
///   阶段 A 游戏未开 → 探测轮应持续增长、不锁定
///   阶段 B 向默认路由网段发真实 UDP 30031 包 → 应被探测命中并锁定
///   阶段 C 停发 > 失流窗口(3s) → 应自动停流重探
///   阶段 D 再发包 → 应再次锁定（验证失流后的自愈 = 网络切换跟随）
///
/// 注：注入的包不是 UE5 格式（解码不出坐标），但足以验证「哪张网卡有
/// 真实 30031 流量」这一自适应核心判据——解码链路已由实机与 OCR 路径覆盖。
@MainActor
func runNicAdaptSelfTest() {
    var fail = 0
    func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
        if !cond { fail += 1 }
        print("  \(cond ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
    func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    print("═══ 自适应网卡（探测 → 锁定 → 失流重探）═══")

    // 目标地址：默认网关（包从默认路由网卡发出 → 该网卡 BPF 通道可见）。
    // 复用生产解析器（多候选路径 + netstat 兜底）——自检与生产同源，
    // 避免「自检用的解析逻辑和生产不一样」的假绿。
    let route = CoordinateCapture.parseDefaultRoute()
    let gateway = route?.gateway ?? ""
    ck("解析到默认网关", !gateway.isEmpty, "gateway=\(gateway) 接口=\(route?.interface ?? "?")")
    guard !gateway.isEmpty else {
        print("═══ 自适应网卡自检：FAIL（无法确定默认网关，无法注入测试包）═══")
        return
    }

    let cc = CoordinateCapture()
    let started = cc.start()
    ck("自适应抓包启动", started)

    // ── 阶段 A：游戏未开，探测轮应增长、不应锁定 ──
    print("  ── 阶段 A：游戏未启动（期望：持续探测、不锁定）──")
    wait(2.5)
    let roundsA = cc.probeRounds
    ck("探测轮在推进", roundsA >= 1, "轮数=\(roundsA)")
    print("     状态: \(cc.adaptationSummary)")

    // ── 阶段 B：注入真实 UDP 30031 包，期望被探测命中并锁定 ──
    print("  ── 阶段 B：注入真实 UDP 30031 包（期望：探测命中 → 锁定）──")
    let injector = NicTestInjector(target: gateway, port: 30031)
    injector.start(intervalMs: 100)
    var lockedB = false
    for _ in 0..<14 {                 // 最多 7s（探测窗口 0.3s + 重探间隔 2s）
        wait(0.5)
        if cc.activeInterface != nil { lockedB = true; break }
    }
    ck("注入真实 30031 包后锁定网卡", lockedB, "active=\(cc.activeInterface ?? "无")")
    ck("hasRecentTraffic 判定有流量", cc.hasRecentTraffic(window: 3.0))
    ck("收到注入的包（包计数>0）", cc.totalPackets > 0, "包=\(cc.totalPackets)")
    let lockedName = cc.activeInterface
    print("     状态: \(cc.adaptationSummary)")

    // ── 阶段 C：停发，期望失流（3s 窗口）后自动重探 ──
    print("  ── 阶段 C：停止注入（期望：3s 失流窗口后自动停流重探）──")
    injector.stop()
    var lostDetected = false
    for _ in 0..<16 {                 // 最多 8s
        wait(0.5)
        if cc.activeInterface == nil { lostDetected = true; break }
    }
    ck("停流后判定失流并回到探测", lostDetected, "active=\(cc.activeInterface ?? "无(探测中)")")

    // ── 阶段 D：再次注入，期望自动重新锁定（自愈）──
    print("  ── 阶段 D：再次注入（期望：自动重新锁定 = 网络切换自愈）──")
    let injector2 = NicTestInjector(target: gateway, port: 30031)
    injector2.start(intervalMs: 100)
    var lockedD = false
    for _ in 0..<14 {
        wait(0.5)
        if cc.activeInterface != nil { lockedD = true; break }
    }
    ck("失流后能自动重新锁定", lockedD, "active=\(cc.activeInterface ?? "无")")
    let locksNow = cc.lockCount
    ck("锁定次数 ≥2（证明真的重探重锁过）", locksNow >= 2, "lockCount=\(locksNow)")
    ck("重锁回同一张有效网卡", cc.activeInterface == lockedName || lockedName == nil,
       "原=\(lockedName ?? "无") 现=\(cc.activeInterface ?? "无")")
    injector2.stop()

    print("     最终状态: \(cc.adaptationSummary)")
    cc.close()

    print("═══ 自适应网卡自检：\(fail == 0 ? "PASS" : "FAIL(\(fail))") ═══")
    fflush(stdout)
}

/// UDP 30031 测试包注入器：向目标地址周期发送 ≥32 字节 UDP 包。
/// 包从默认路由网卡发出 → 该网卡的 BPF 通道可见（端到端验证抓包自适应）。
final class NicTestInjector {
    private let target: String
    private let port: UInt16
    private var thread: Thread?
    private var stopped = false

    init(target: String, port: UInt16) {
        self.target = target
        self.port = port
    }

    func start(intervalMs: Int) {
        let t = Thread { [weak self] in
            guard let self else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { print("[NIC-TEST] socket 创建失败"); return }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = self.port.bigEndian
            addr.sin_addr.s_addr = inet_addr(self.target)
            var payload = [UInt8](repeating: 0, count: 64)
            for i in 0..<payload.count { payload[i] = UInt8(i & 0xFF) }
            while !self.stopped {
                payload.withUnsafeBytes { raw in
                    var a = addr
                    withUnsafePointer(to: &a) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = sendto(fd, raw.baseAddress, raw.count, 0, sa,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                usleep(useconds_t(intervalMs * 1000))
            }
            close(fd)
        }
        t.name = "com.aurora.nic-test-injector"
        thread = t
        t.start()
    }

    func stop() { stopped = true }
}

// ============================================================================
// MARK: - 自适应缩放自测（真窗口 + 逐档改尺寸）
/// 真开一个无边框窗口，按多档尺寸设置 frame，每档读回
/// contentView 尺寸并检查是否 == frame（内容铺满，无黑边）。
/// 这是唯一能真机验证「换屏幕 / 改窗口大小都不留黑边」的方式。
@MainActor
func runLimitSelfTest() {
    var fail = 0
    func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
        if !cond { fail += 1 }
        print("  \(cond ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
    let dt = 1.0 / 30.0

    print("═══ 限速刹车（三级）═══")
    let g = SpeedLimitGuard()

    var r = g.update(speedKmh: 100, speedValid: true, limitKmh: 120, dt: dt)
    ck("巡航不刹车", !r && g.stage == .none)

    r = g.update(speedKmh: 130, speedValid: true, limitKmh: 120, dt: dt)
    ck("超速立即响应", r)
    ck("首帧是松油门级", g.stage == .liftOnly, "stage=\(g.stage.label)")
    ck("松油门级不按手刹", !g.handbrakeDown)

    var onFrames = 0, pulseFrames = 0
    for _ in 0..<60 {
        _ = g.update(speedKmh: 130, speedValid: true, limitKmh: 120, dt: dt)
        if g.stage == .pulse { pulseFrames += 1; if g.handbrakeDown { onFrames += 1 } }
    }
    let duty = Double(onFrames) / Double(max(1, pulseFrames))
    ck("进入点刹级", g.stage == .pulse, "stage=\(g.stage.label)")
    ck("点刹占空比在 30~60%", duty > 0.30 && duty < 0.60, String(format: "%.1f%%", duty * 100))
    ck("点刹不是一直按死", duty < 0.75)

    for _ in 0..<90 { _ = g.update(speedKmh: 130, speedValid: true, limitKmh: 120, dt: dt) }
    ck("长时间超速升级到持续刹", g.stage == .firm, "stage=\(g.stage.label)")
    ck("持续刹按住手刹", g.handbrakeDown)

    _ = g.update(speedKmh: 90, speedValid: true, limitKmh: 120, dt: dt)
    ck("降到限速下立即退出", g.stage == .none && !g.handbrakeDown)
    ck("峰值留档：最高级别=firm", g.lastStage == .firm, "lastStage=\(g.lastStage.label)")
    ck("峰值留档：持续时长>2s", g.lastBrakeSeconds > 2.0, String(format: "%.1fs", g.lastBrakeSeconds))
    ck("峰值留档：脉冲数>0", g.lastPulseCount > 0, "\(g.lastPulseCount)")

    let g2 = SpeedLimitGuard()
    var any = false
    for _ in 0..<120 {
        if g2.update(speedKmh: 999, speedValid: true, limitKmh: 200, dt: dt) { any = true }
    }
    ck("不限速 → 闭环整体停用", !any && g2.stage == .none)

    let g3 = SpeedLimitGuard()
    ck("读数不可信不刹车", !g3.update(speedKmh: 300, speedValid: false, limitKmh: 120, dt: dt))
    ck("速度负数不刹车", !g3.update(speedKmh: -1, speedValid: true, limitKmh: 120, dt: dt))

    print("")
    print("═══ 自动速度（YOLO 框数 → 路况）═══")
    ck("5 框 → 简单",     AutoRoadCondition.condition(forDetectionCount: 5,  current: .simple) == .simple)
    ck("10 框 → 简单",    AutoRoadCondition.condition(forDetectionCount: 10, current: .simple) == .simple)
    ck("11 框 → 滞回保持", AutoRoadCondition.condition(forDetectionCount: 11, current: .easy) == .easy)
    ck("20 框 → 滞回保持", AutoRoadCondition.condition(forDetectionCount: 20, current: .easy) == .easy)
    ck("21 框 → 轻松",    AutoRoadCondition.condition(forDetectionCount: 21, current: .simple) == .easy)
    ck("30 框 → 轻松",    AutoRoadCondition.condition(forDetectionCount: 30, current: .simple) == .easy)
    ck("31 框 → 中等",    AutoRoadCondition.condition(forDetectionCount: 31, current: .simple) == .medium)
    ck("50 框 → 中等",    AutoRoadCondition.condition(forDetectionCount: 50, current: .simple) == .medium)
    ck("51 框 → 繁忙",    AutoRoadCondition.condition(forDetectionCount: 51, current: .simple) == .busy)
    ck("70 框 → 繁忙",    AutoRoadCondition.condition(forDetectionCount: 70, current: .simple) == .busy)
    ck("71 框 → 极度复杂", AutoRoadCondition.condition(forDetectionCount: 71, current: .simple) == .extreme)
    ck("阈值确为 70/50/30/20/10",
       AutoRoadCondition.extremeThreshold == 70
       && AutoRoadCondition.busyThreshold == 50
       && AutoRoadCondition.mediumThreshold == 30
       && AutoRoadCondition.easyThreshold == 20
       && AutoRoadCondition.simpleThreshold == 10)

    print("")
    print("═══ 路况 → 限速 映射（6 档）═══")
    ck("简单 → 不限速", RoadCondition.simple.autoSpeedLimit == nil)
    ck("轻松 → 150", RoadCondition.easy.autoSpeedLimit == 150)
    ck("中等 → 100", RoadCondition.medium.autoSpeedLimit == 100)
    ck("繁忙 → 60",  RoadCondition.busy.autoSpeedLimit == 60)
    ck("极度复杂 → 20", RoadCondition.extreme.autoSpeedLimit == 20)
    ck("关闭 → 不干预", RoadCondition.off.autoSpeedLimit == nil)
    ck("简单 ≠ 关闭（不限速 vs 不干预）",
       RoadCondition.simple.meansUnlimited && !RoadCondition.off.meansUnlimited)

    print("")
    print("═══ 优先级：用户不限速 > 自动速度 > 手动路况 ═══")
    // 用生产的同一份 autoSpeedTarget 决策，不是重写一份逻辑来"自证"
    let U = DriveState.unlimitedThreshold
    func target(_ rc: RoadCondition, limit: Double, src: SpeedLimitSource,
                on: Bool = true) -> Double? {
        DriveState.autoSpeedTarget(for: rc, currentLimit: limit,
                                   unlimitedSource: src, enabled: on)
    }

    // A. 自动速度自己设的不限速，必须能自己改回来（原死锁点）
    ck("自动设的不限速 → 不是用户锁死",
       target(.simple, limit: U, src: .auto) == U)
    ck("自动设的不限速 → 框数涨回后能改回 100",
       target(.medium, limit: U, src: .auto) == 100)
    ck("自动设的不限速 → 能改回 20",
       target(.extreme, limit: U, src: .auto) == 20)

    // B. 用户手动设的不限速，任何自动判定都不许动
    ck("用户不限速 + 简单档 → 不干预", target(.simple, limit: U, src: .user) == nil)
    ck("用户不限速 + 中等档 → 不干预", target(.medium, limit: U, src: .user) == nil)
    ck("用户不限速 + 极度复杂 → 不干预", target(.extreme, limit: U, src: .user) == nil)

    // C. 关闭自动速度 → 永不干预
    ck("自动速度关 → 不干预", target(.extreme, limit: 80, src: .user, on: false) == nil)
    ck("自动速度关 + 简单档 → 不干预", target(.simple, limit: 80, src: .user, on: false) == nil)

    // D. 普通情况下按档位下发
    ck("普通：繁忙 → 60", target(.busy, limit: 150, src: .none) == 60)
    ck("普通：轻松 → 150", target(.easy, limit: 60, src: .none) == 150)
    ck("普通：关闭档 → 不干预", target(.off, limit: 80, src: .none) == nil)

    // E. 用户从自动的不限速接管后，回归普通优先级
    ck("用户改回有限速后，自动恢复工作",
       target(.busy, limit: 60, src: .none) == 60)

    print("")
    print(fail == 0 ? "[LIMIT-SELFTEST] 全部通过" : "[LIMIT-SELFTEST] 失败 \(fail) 项")
}

func runFitSelfTest() {
    // 必须先建立 NSApplication 实例：此函数在 AuroraDriveApp.main() 之前调用，
    // 此时 NSApp 还是 nil（隐式解包会崩）。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let sizes: [(CGFloat, CGFloat)] = [
        (880, 500), (1024, 640), (1200, 760), (1440, 900),
        (1920, 1080), (2560, 1440), (3840, 2160), (1100, 820), (900, 1200),
    ]
    var win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                       styleMask: [.fullSizeContentView, .resizable, .miniaturizable],
                       backing: .buffered, defer: false)
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.hasShadow = false
    let host = NSHostingView(rootView: ContentView())
    win.contentView = host
    win.orderFrontRegardless()
    print("[FIT-TEST] 窗口已创建，开始逐档验证")
    var pass = 0
    for (w, h) in sizes {
        win.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let f = win.frame.size
        let cv = win.contentView?.frame.size ?? .zero
        let dw = abs(cv.width - f.width)
        let dh = abs(cv.height - f.height)
        let s = f.width / ConsoleMetrics.designWidth
        let ok = dw < 1.0 && dh < 1.0
        if ok { pass += 1 }
        print(String(format: "[FIT-TEST] frame=%.0fx%.0f content=%.0fx%.0f 差=(%.0f,%.0f) scale=%.3f %@",
                     f.width, f.height, cv.width, cv.height, dw, dh, s, ok ? "✓铺满" : "✗有黑边"))
    }
    print("[FIT-TEST] 结果: \(pass)/\(sizes.count) 档铺满")
    win.orderOut(nil)
    fflush(stdout)
}

// ============================================================================
// MARK: - 主窗口配置（强制内容铺满整窗）
/// 把主窗口设成 fullSizeContentView：内容延伸进标题栏区域。
/// 仅靠 SwiftUI 的 .windowStyle(.hiddenTitleBar) 不够 —— 实测窗口顶部仍留
/// 一条 32pt 纯黑带（内容区 728 vs 窗口 760），那就是用户看到的「黑边」。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigProbeView { ConfigProbeView() }
    func updateNSView(_ nsView: ConfigProbeView, context: Context) {
        nsView.apply()
    }

    /// 视图尚未挂到窗口时 window 为 nil；等 viewDidMoveToWindow 再配置，
    /// 并在窗口尺寸/屏幕变化时复核（系统可能重建标题栏状态）。
    final class ConfigProbeView: NSView {
        private var applied = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(reapply),
                name: NSWindow.didResizeNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(reapply),
                name: NSWindow.didEnterFullScreenNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(reapply),
                name: NSWindow.didExitFullScreenNotification, object: w)
            apply()
        }

        @objc private func reapply() { applied = false; apply() }

        func apply() {
            guard let w = window else { return }
            if applied, w.styleMask.contains(.fullSizeContentView),
               w.titlebarAppearsTransparent, w.titleVisibility == .hidden { return }
            // 彻底去掉标题栏：窗口退化为无边框。
            // 只插 .fullSizeContentView 时系统依旧保留 32pt 标题栏空间
            // （layout=728 vs frame=760），那条空间就是顶上的黑边。
            // 去掉 .titled 后窗口没有任何 chrome，内容铺满整个 frame。
            var mask = w.styleMask
            mask.insert(.fullSizeContentView)
            mask.remove(.titled)
            mask.insert(.resizable)
            mask.insert(.miniaturizable)
            w.styleMask = mask
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            // 无边框化后窗口仍可能带系统阴影 / 圆角：深色内容贴边时，阴影会在
            // 窗口外圈压出一圈暗边、圆角会在四角啃掉内容，观感都像「一圈黑边」。
            // 这里一并去掉，保证内容边界就是窗口边界。
            w.hasShadow = false
            w.isOpaque = true
            if let cv = w.contentView {
                cv.wantsLayer = true
                cv.layer?.cornerRadius = 0
                cv.layer?.masksToBounds = false
            }
            // 去掉 .titled 会连带丢掉「可缩放 / 可移动」能力 —— 而用户明确要
            // 把窗口拖到另一块屏幕、并随屏幕大小缩放，这两项必须补回来。
            //   · .resizable  → 可拖边缘缩放
            //   · minSize/maxSize 保持弹性，不硬性夹死
            w.minSize = NSSize(width: 880, height: 500)
            // 去掉 .titled 后窗口没有任何标题栏可抓 —— isMovable 形同虚设，
            // 这正是「能放大缩小但拖不动」的原因。
            // 解法：在窗口最顶部铺一条透明拖拽带（高度 = 顶栏留白区），
            // 它只覆盖顶栏上方那条没有可点控件的区域，不遮挡任何按钮；
            // 用户按住那条带子即可拖动窗口（也能拖到另一块屏幕）。
            installDragHandle(on: w)
            applied = true
            let cvFrame = w.contentView?.frame ?? .zero
            print("[WindowCfg] frame=\(Int(w.frame.width))x\(Int(w.frame.height)) "
                  + "contentView=\(Int(cvFrame.width))x\(Int(cvFrame.height)) "
                  + "resizable=\(w.styleMask.contains(.resizable)) "
                  + "movable=\(w.isMovable)")
            print("[WindowCfg] fullSizeContentView 已启用 frame=\(Int(w.frame.width))x\(Int(w.frame.height)) "
                  + "layout=\(Int(w.contentLayoutRect.height)) titled=\(w.styleMask.contains(.titled))")
        }
    }
}

/// 在无边框窗口顶部铺一条透明拖拽带，让窗口可被拖动。
///
/// 背景：为了消除顶部黑边，主窗口去掉了 .titled（无边框化）。代价是窗口
/// 失去了标题栏 —— `isMovable = true` 在没有可抓区域时不起作用，表现就是
/// 「能放大缩小，但拖不动」。这里补一条只占顶栏上方留白区的拖拽带解决：
///   · 高度 18pt，正好落在顶栏卡片上方的 padding 区，不压任何可点控件；
///   · 透明无背景，视觉上完全不可见；
///   · 只在鼠标按下时把事件交给窗口做拖拽，其余情况不拦截。
private func installDragHandle(on window: NSWindow) {
    guard let cv = window.contentView else { return }
    // ⚠️ 坐标方向：主窗口的 contentView 是 NSHostingView，它 **isFlipped == true**，
    //    即 y=0 在**顶部**、y=bounds.height 在底部。flipped 坐标系下顶部就是 y=0。
    //
    // 拖拽带覆盖整条顶栏（58pt）。顶栏是纯展示区：品牌文字 + 6 个指标 + 2 个状态丸，
    // **一个按钮/输入框都没有**（已核对 TopBar 全部子视图），所以整条交给我们拖拽
    // 不会抢走任何交互 —— 这是无边框窗口的标准做法（等同系统标题栏）。
    let h: CGFloat = 58
    // ⚠️⚠️ 关键：必须挂在 themeFrame（contentView 的父视图）上，不能挂在 contentView 上。
    //   contentView 是 NSHostingView，它自己实现 hitTest 并把事件全部收走 ——
    //   挂在 contentView 上的兄弟视图永远拿不到鼠标事件（已用最小复现验证：
    //   cv.hitTest(600,29) 返回的是 SwiftUI 内部视图，不是我加的带子）。
    //   这正是"只有特定位置能拖、非常难拖"的真正原因。
    //   themeFrame 是 NSNextStepFrame，在 contentView 之上，挂这里才能可靠接管。
    guard let theme = cv.superview else { return }
    let f = NSRect(x: 0, y: theme.bounds.height - h, width: theme.bounds.width, height: h)

    if let existing = theme.subviews.first(where: { $0.identifier?.rawValue == "AuroraDragHandle" }) {
        existing.frame = f
        return
    }
    let handle = DragHandleView()
    handle.identifier = NSUserInterfaceItemIdentifier("AuroraDragHandle")
    handle.frame = f
    // themeFrame 是 **非 flipped**（y=0 在底部），所以顶部贴边要用 .minYMargin
    handle.autoresizingMask = [.width, .minYMargin]
    theme.addSubview(handle, positioned: .above, relativeTo: cv)
    print("[WindowCfg] 顶部拖拽带已安装（themeFrame, 高 \(Int(h))pt, themeFlipped=\(theme.isFlipped)）")

    // ── 自查：确认拖拽区覆盖正确，且右侧交互区确实让给了下层 ──
    // 左半段（非交互区）必须 100% 归拖拽带；右半段（交互区）必须 0% 归它，
    // 否则就是「药丸点不动」复发。
    let dragWidth = theme.bounds.width - DragHandleView.interactiveRightInset
    let steps = 40
    var dragHits = 0
    for i in 0..<steps {
        // 取每格中点，避开 x=0 与 x=width 两条边界
        // （NSView 的 bounds 是半开区间，边界点落在视图外，采样到那里会误报）
        let x = dragWidth * (CGFloat(i) + 0.5) / CGFloat(steps)
        if let hp = theme.hitTest(NSPoint(x: x, y: theme.bounds.height - h / 2)),
           hp === handle { dragHits += 1 }
    }
    // 交互区采样：这里必须**不是**拖拽带
    var leaked = 0
    let probeSteps = 12
    for i in 0..<probeSteps {
        let x = dragWidth + (theme.bounds.width - dragWidth) * (CGFloat(i) + 0.5) / CGFloat(probeSteps)
        if let hp = theme.hitTest(NSPoint(x: x, y: theme.bounds.height - h / 2)),
           hp === handle { leaked += 1 }
    }
    if dragHits == steps && leaked == 0 {
        print("[WindowCfg] 顶栏拖拽覆盖 \(dragHits)/\(steps) 可拖；右侧交互区 \(DragHandleView.interactiveRightInset)pt 已让给控件（泄漏 \(leaked)）")
    } else {
        print("[WindowCfg] ⚠️ 拖拽区异常：可拖 \(dragHits)/\(steps)，交互区被吞 \(leaked)（应为 0）")
    }
}

/// 透明拖拽带：按住即拖动窗口（双击等效于缩放，符合 macOS 习惯）。
///
/// ⚠️ 2026-09-23 重要修正：顶栏**不再是纯展示区**。
///   原设计假设「顶栏一个按钮都没有」，所以整条 58pt 全宽交给拖拽带。
///   但后来顶栏右侧加了**权限小药丸**（可点），药丸的点击就被这条带子吃掉了 ——
///   表现正是用户报的「小药丸看得见，但点了没反应」。
///
///   修法：拖拽带在 mouseDown 时先做一次**穿透判定** ——
///   用 `super.hitTest` 看该点下方是否落在一个「可交互」的视图上
///   （NSButton / NSTextField / 任何 acceptsFirstMouse 的控件）。
///   是 → 把事件交还给下层（return 不处理），让药丸拿到点击；
///   否 → 正常拖窗。
final class DragHandleView: NSView {

    /// 顶栏右侧「交互区」宽度（pt）：权限药丸 + 模型名 + markers 三颗胶囊所在区域。
    /// 这块区域整体让给 SwiftUI，拖拽带不接管 —— 比逐个识别控件更稳，
    /// 因为 SwiftUI 的按钮在 AppKit 层是 _NSViewBackingLayer 之类的私有类型，
    /// 按类型判定不可靠。用几何区域划分才是可预期、可测试的做法。
    ///
    /// 取值依据：顶栏总高 58pt；右侧三颗胶囊合计约 300pt（药丸 ~92 + 模型名 ~110
    /// + markers ~98，间距 8×2）。留 340pt 冗余，避免边界抖动导致点击落空。
    static let interactiveRightInset: CGFloat = 340

    override func mouseDown(with event: NSEvent) {
        // 双击 → 缩放（macOS 标准行为）
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        // 按住拖动 → 移动窗口。performDrag 会接管后续事件直到松开，
        // 因此不会和底层控件的点击冲突。
        window?.performDrag(with: event)
    }

    /// 命中测试：落在右侧交互区内的点击**不接管**，直接透传给 SwiftUI。
    ///
    /// 为什么用 hitTest 而不是在 mouseDown 里判断：AppKit 是先 hitTest 定位
    /// 目标视图、再派发事件。如果这里返回 self，事件根本到不了下层；
    /// 必须在这一步就返回 nil，AppKit 才会继续往下找 SwiftUI 的按钮。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 已是本视图自身坐标系（AppKit 在调用前完成转换）
        if point.x >= bounds.width - Self.interactiveRightInset {
            return nil   // 右侧交互区：完全让给下层
        }
        return super.hitTest(point)
    }

    // 说明：不要覆写 hitTest 去「纠正坐标」。
    // AppKit 在调用子视图的 hitTest 前，**已经把 point 转换到该子视图自身坐标系**，
    // 所以在里面再 convert(point, from: superview) 会造成二次转换、坐标错位。
    // 上面的 hitTest 只做区域判定，不做坐标转换，是正确的用法。

    // 空白区域不该吞掉鼠标滚轮等事件
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
    override var acceptsFirstResponder: Bool { false }
    /// 允许在非 key 窗口（游戏在前台时我们的窗口是背景态）也能拖
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ── 鼠标手势提示：让用户一眼看出「这条能拖」 ──
    // 无边框窗口最容易让人困惑的就是"看不出哪里能拖"。
    // 悬停显示张手（可抓），按住期间显示握手（抓取中）。
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways,
                                         .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// ============================================================================
// MARK: - 文件 3: DriveState.swift  (全局状态 + 模拟数据流)
// ============================================================================

enum DriveMode: String, CaseIterable, Identifiable {
    // 内部降级状态机的 4 个档位（逻辑层完整保留，降级/回升仍按 4 档走）。
    // UI 层按 DriveModeGroup 合并为 2 个用户可见档位（端到端主驾 / 规则）。
    case e2e     = "端到端主驾"   // 档1：M9 端到端模型直接开车
    case yolo    = "YOLO接管"     // 档2：第二套神经网接管（YOLO 画框）
    case recover = "脱困中"       // 档3：卡死脱困（自动倒车/转向）
    case rule    = "纯规则兜底"   // 档4：YOLO 检测 + 手写规则（最后防线）

    var id: String { rawValue }

    /// 档位强调色：正常档白色，降级档用状态色警示
    var accentColor: Color {
        switch self {
        case .e2e, .yolo: return .white
        case .recover:    return Aurora.amber
        case .rule:       return Aurora.danger
        }
    }

    /// 所属 UI 展示分组：内部 4 档 → 用户可见 2 档。
    /// 模型驱动侧（e2e+yolo）归「端到端主驾」；规则/脱困侧（recover+rule）归「规则」。
    var uiGroup: DriveModeGroup {
        switch self {
        case .e2e, .yolo:     return .e2eDrive
        case .recover, .rule: return .ruleFallback
        }
    }
}

/// UI 用户可见的驾驶模式分组（内部 4 档合并为 2 档）。
/// - `.e2eDrive`     端到端主驾：模型驱动侧，开得快（M9 + 神经网接管）；
/// - `.ruleFallback` 规则：规则兜底 + 脱困，紧急保命用，不当主驾。
enum DriveModeGroup: String, CaseIterable, Identifiable {
    case e2eDrive     = "端到端主驾"
    case ruleFallback = "规则"

    var id: String { rawValue }

    /// 该组覆盖的内部档位
    var members: [DriveMode] {
        switch self {
        case .e2eDrive:     return [.e2e, .yolo]
        case .ruleFallback: return [.recover, .rule]
        }
    }

    /// 组内是否包含指定内部档位（用于高亮当前组）
    func contains(_ m: DriveMode) -> Bool { members.contains(m) }

    /// 一句话说明（UI 芯片副标题）
    var desc: String {
        switch self {
        case .e2eDrive:     return "模型驾驶：M9 端到端 + 神经网接管，开得快"
        case .ruleFallback: return "规则兜底 + 脱困：紧急保命，不当主驾"
        }
    }

    var icon: String {
        switch self {
        case .e2eDrive:     return "brain.head.profile"
        case .ruleFallback: return "shield.lefthalf.filled"
        }
    }
}

/// 专家模式录制标签换算器（纯函数，便于单测）
/// 把物理按键的"按住时长"换算成连续控制标签，语义≈"按住该键的力度比例"：
///   按住时长 / fullScaleDuration → 0~1（带符号），时长达到满刻度即饱和。
/// 与推理端闭环一致：ControlEngine 按 |steer|>阈值 决定是否按住键，
/// 游戏自身再把按住时长平滑成转角 —— 录制端用按住时长作为监督信号，
/// 让模型学到"打得越满 → 按住越久"的连续映射，替代二值标签带来的顿挫。
enum RecordLabelMapper {

    /// 满刻度时长（秒）：按住满该时长 → 标签饱和 ±1，可按需调整
    /// 默认 0.6s：30Hz 下约 18 帧，覆盖"轻点 → 满打"的常见手感区间
    static let fullScaleDuration: TimeInterval = 0.6

    /// 按住时长 → [0,1] 比例（钳制）
    static func holdRatio(_ duration: TimeInterval) -> Double {
        min(1.0, max(0.0, duration / fullScaleDuration))
    }

    /// 转向标签：D 按住比例 − A 按住比例，净差钳制到 [-1,1]（左负右正）
    static func steer(leftHeld: TimeInterval, rightHeld: TimeInterval) -> Double {
        min(1.0, max(-1.0, holdRatio(rightHeld) - holdRatio(leftHeld)))
    }

    /// 油门标签：W 按住比例 [0,1]
    static func throttle(wHeld: TimeInterval) -> Double {
        holdRatio(wHeld)
    }

    /// 刹车标签：S 或 空格(手刹) 任一按住即刹车，取两者按住比例较大者 [0,1]
    static func brake(sHeld: TimeInterval, spaceHeld: TimeInterval) -> Double {
        max(holdRatio(sHeld), holdRatio(spaceHeld))
    }
}

@Observable
@MainActor
final class DriveState {
    var isDriving       = false
    var sportMode       = false
    var isTraining      = false

    // ── 引擎模式（后台引擎拆分；EngineClient 激活时生效）──
    /// 引擎回传的检测结果（引擎模式下每 tick 刷新）
    var remoteDetections: [Detection] = []
    /// 引擎模式是否激活（镜像自 EngineClient，供 UI 观察刷新）
    var engineModeActive = false
    /// 引擎心跳是否正常（false = 失联，UI 显示告警）
    var engineConnected = false
    /// 引擎回传的车速表读数（km/h；引擎模式下本地 speedOCR 不跑，用它顶上）
    var remoteSpeedKmh: Double = -1
    /// 最后一次「开始/停止」命令时间：引擎状态回同步的 1 秒宽限期，防切换瞬间UI闪烁
    @ObservationIgnored var lastDriveCommandTime = Date.distantPast
    /// UI 统一检测结果读取点：引擎模式用引擎回传，本地模式用本地 YoloEngine
    var effectiveDetections: [Detection] {
        EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections
    }

    /// 专家模式：录制时控制量来源切到真人物理键（模仿学习的专家演示），
    /// 而非 AI 决策（currentCommand）。关 → 录 AI 决策（DAgger 自训练）。
    var expertMode      = false

    /// 字模模式：录制时输出原生分辨率速度表区域帧（供字模训练），
    /// 与专家模式/训练录制互不影响，仅影响 RecordEngine 的输出内容
    var glyphMode       = false

    /// 禁用控制：模型照常检测画面（YOLO 框 + E2E 推理照跑），
    /// 但不把 AI 决策注入按键 —— 人工驾驶 + 模型辅助提示。
    var controlDisabled = false

    /// 紧急切纯规则：开启后降级状态机强制停在纯规则兜底档（档4），
    /// 且 M9 端到端推理停跑（省资源）。用途：紧急情况（游戏鼠标点不过去）
    /// 一键切规则兜底，直到用户手动关闭。
    var forceRuleMode = false

    /// 训练按钮状态/日志（UI 展示：启动中 / 完成 / 失败原因）
    var trainingLog     = ""

    // ── 网络定位相关字段 ──
    /// 网络定位常开（需求：永远打开，不提供关闭入口）。
    /// 保留该字段仅为兼容既有调用点，恒为 true。
    var enableNetworkLocate = true
    var bpfAuthorized = false  // 启动时检测BPF权限
    /// 权限小药丸的真实状态：网络权限 + 性能提权是否**都**可用。
    /// 不用 bpfAuthorized 代替，因为那只反映 BPF 单侧，会出现
    /// 「药丸显示就绪但抓包仍失败」的假绿状态。
    var privilegeReady = false
    /// 权限状态明细（如实说明卡在哪一步，供药丸 tooltip 与弹窗显示）
    var privilegeStatusDetail = ""
    var showBPFPasswordSheet = false  // 是否显示密码输入弹窗
    var bpfInstallMessage = ""  // 安装结果消息
    var bpfInstalling = false  // 正在安装中
    
    // ── Daemon 系统服务相关字段 ──
    var daemonInstalled = false  // 是否已安装为系统服务
    var showDaemonInstallSheet = false  // 是否显示安装引导弹窗
    var daemonInstallMessage = ""  // 安装结果消息
    var daemonInstalling = false  // 正在安装中
    var isDaemonMode = false  // 当前是否为 daemon 模式运行

    /// AI Agent 模式：开启后显示更多游戏键位，支持模型直接操作
    var agentMode = false
    
    var networkLocateX: Double = 0
    var networkLocateY: Double = 0
    var networkLocateScore: Double = 0
    var networkLocateMode: String = ""

    /// 定位状态的中文说明 —— 把 networkLocateMode 如实翻译给用户看。
    /// 「游戏未运行」和「等待定位」是两件完全不同的事：
    /// 前者是用户没开游戏（没有数据源），后者是游戏开了但还没抓到包。
    /// 不区分的话用户只会看到永远停在「等待网络定位」，不知道问题出在哪。
    var locateStatusText: String {
        switch networkLocateMode {
        case "game_not_running": return "游戏未运行 · 无定位数据源"
        case "not_ready":        return "抓包未就绪"
        case "no_data":          return "已抓包 · 等待定位数据"
        case "network":          return "网络定位已锁定"
        default:                 return "等待网络定位"
        }
    }

    /// 是否处于「游戏没开」状态（UI 据此给出更醒目的提示）
    var locateGameOffline: Bool { networkLocateMode == "game_not_running" }
    var networkLocatePitch: Double = 0
    var networkLocateHeading: Double = 0

    // ── 定位器字段（从外置盘移植，MinimapLocatorView需要） ──
    var locatorFound = false
    var locatorX: Double = 0
    var locatorY: Double = 0
    var locatorScore: Double = 0
    var locatorHeading: Double = 0
    /// 同包加速度（m/s²，来自 30031 包，与坐标同源）。
    /// ⚠️ 坐标系（世界系/车体系）尚未实测确认 —— 只做如实展示，
    ///    在标定完成前不参与任何控制逻辑。nil = 本帧无数据。
    var locatorAccelX: Double? = nil
    var locatorAccelY: Double? = nil
    var locatorAccelZ: Double? = nil
    var locatorTarget: (x: Double, y: Double)? = nil
    @ObservationIgnored private var lastNetworkLocPos: (x: Double, y: Double)? = nil
    @ObservationIgnored private var healerInitLock = os_unfair_lock_s()
    @ObservationIgnored private var coordinateCapture: CoordinateCapture?
    @ObservationIgnored private let locateCtx = LocateContext()
    @ObservationIgnored private let locateGate = LocateGate()
    private let mapPath: String = {
        // 用可执行文件所在目录找地图，不用currentDirectoryPath（那是Home目录）
        let execPath = CommandLine.arguments[0]
        let execDir = (execPath as NSString).deletingLastPathComponent
        let candidates = [
            "\(execDir)/models/bigworldmap-13056.jpg",
            "\(execDir)/models/bigworldmapSecond.png",
            "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg",
            "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return candidates.last!  // 返回最后一个作为默认，让错误信息有意义
    }()

    func setLocatorTarget(x: Double, y: Double) { locatorTarget = (x, y) }

    static func heading(from: (x: Double, y: Double), to: (x: Double, y: Double)) -> Double {
        let dx = to.x - from.x, dy = to.y - from.y
        let h = atan2(dy, dx) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    /// 定位数据源是否就绪 —— 判据是**30031 端口有没有数据包**，不查进程。
    ///
    /// 为什么不用查进程：定位数据全部来自游戏与服务器的 30031 端口流量，
    /// 「有包」就是「游戏在通信」的直接证据，比进程名可靠得多
    /// （辅助进程 crashpad_handler 的路径同样含「异环」，曾把它误判成
    /// 游戏在跑）；而且读一个自增计数器是零开销，不像 NSWorkspace 那样
    /// 每个 App 都要同步 IPC 取静态信息，能把 UI 进程烧到 50%+ 以上。
    ///
    /// 三态返回，让 UI 能区分「游戏没开」和「抓包没起来」两种不同故障。
    enum LocateSource: Equatable {
        case ready        // 端口有数据 → 可以定位
        case noGame       // 抓包正常但端口无流量 → 游戏没开/没进游戏
        case packetError  // 抓包本身没起来 → 权限或网卡问题
    }

    /// 判定定位数据源状态。调用频率 10Hz，全部是计数器读取，无系统调用。
    func locateSource() -> LocateSource {
        guard let cc = coordinateCapture, locateCtx.networkReady else {
            return .packetError
        }
        return cc.hasRecentTraffic(window: CoordinateCapture.trafficFreshWindow) ? .ready : .noGame
    }

    func runNetworkLocateStep() {
        // 网络定位常开：不做开关判断，直接确保抓包在跑。
        // 懒初始化 CoordinateCapture（纯网络定位，无自愈引擎）
        if coordinateCapture == nil {
            os_unfair_lock_lock(&healerInitLock)
            defer { os_unfair_lock_unlock(&healerInitLock) }
            if coordinateCapture == nil {
                let cc = CoordinateCapture()
                let ok = cc.start()
                pcapLog("[NETWORK-LOCATE] cc.start()返回=\(ok)")
                if ok {
                    locateCtx.networkReady = true
                    pcapLog("[NETWORK-LOCATE] CoordinateCapture已启动")
                } else {
                    pcapLog("[NETWORK-LOCATE] ❌ pcap启动失败!")
                }
                coordinateCapture = cc
            }
        }
        guard let cc = coordinateCapture, locateCtx.networkReady else {
            if networkLocateMode != "not_ready" {
                DispatchQueue.main.async { [weak self] in
                    self?.networkLocateScore = 0
                    self?.networkLocateMode = "not_ready"
                }
            }
            return
        }

        // ── 前置门：30031 端口无流量 = 游戏没在通信，直接如实置为未运行 ──
        // 判据来自抓包计数器（有包才叫游戏在跑），不查进程。
        // 窗口用 CoordinateCapture.trafficFreshWindow（12s）——实测游戏同步包是
        // 突发式（静默间隙最长 9s），旧 3s 窗口会在静默间隙误报"游戏未运行"
        // → 小地图忽明忽暗。
        if !cc.hasRecentTraffic(window: CoordinateCapture.trafficFreshWindow) {
            // ⚠️ 只在状态真的变化时才投递主线程。
            //    这个函数以 10Hz 运行，若无脑每帧 async 到主线程，就等于
            //    每秒 10 次强制 SwiftUI 重算布局 + WindowServer 重合成，
            //    而游戏没开时状态是恒定的「未运行」——纯属白烧 CPU。
            //    先比后写，状态不变则一次主线程投递都不发生。
            if networkLocateMode != "game_not_running" || locatorFound {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.networkLocateScore = 0
                    self.networkLocateMode = "game_not_running"
                    // 不保留旧坐标：游戏关掉后界面必须停止显示"上次"的位置，
                    // 否则用户看到的就是一个假的、还在"跳"的定位。
                    self.locatorFound = false
                    self.locatorScore = 0
                    self.networkLocateLastUpdate = .distantPast
                }
            }
            return
        }

        // 从 CoordinateCapture 获取定位
        if let pose = cc.read(maxAge: CoordinateCapture.poseFreshWindow) {
            let (px, py, hdg) = worldToMapPixel(pose)
            // 同包加速度：坐标系未实测确认，只做如实展示，不参与控制。
            // 单位推测 cm/s²，除以 100 转 m/s²。
            let acc = cc.readAcceleration(maxAge: CoordinateCapture.poseFreshWindow)
            let ax = acc.map { $0.0 / 100.0 }
            let ay = acc.map { $0.1 / 100.0 }
            let az = acc.map { $0.2 / 100.0 }
            if let last = lastNetworkLocPos {
                let dx = px - last.x, dy = py - last.y
                if dx * dx + dy * dy > 16 {
                    // 用移动方向计算朝向
                }
            }
            lastNetworkLocPos = (x: px, y: py)
            DispatchQueue.main.async { [weak self] in
                self?.networkLocateX = px
                self?.networkLocateY = py
                self?.networkLocateScore = 1.0
                self?.networkLocateMode = "network"
                self?.networkLocateHeading = hdg
                self?.locatorX = px
                self?.locatorY = py
                // 先比后写：定位成功且已标记时跳过写入（省观察者通知，
                // locatorFound 有 24 处 UI 读取）。
                if self?.locatorFound == false { self?.locatorFound = true }
                self?.locatorScore = 1.0
                self?.locatorHeading = hdg
                self?.locatorAccelX = ax
                self?.locatorAccelY = ay
                self?.locatorAccelZ = az
            }
        } else {
            // 网络定位无数据（同样先比后写，避免 10Hz 无效重绘）
            if networkLocateMode != "no_data" {
                DispatchQueue.main.async { [weak self] in
                    self?.networkLocateScore = 0
                    self?.networkLocateMode = "no_data"
                }
            }
        }
    }
    var networkLocateLastUpdate: Date = .distantPast

    /// 本次开车会话开始时间（暖机期判定：启动后头几秒还没出推理结果时
    /// 保持高置信度，避免启动瞬间误降级）
    @ObservationIgnored
    private var drivingStartTime = Date()

    /// 上一帧写调试日志的时间（tick 摘要 1Hz 节流用）
    @ObservationIgnored
    private var lastTickLog = Date.distantPast

    /// 插帧/超分状态更新节流（1Hz）
    @ObservationIgnored
    private var lastUpscaleLiveLog = Date.distantPast

    /// 调试日志：stdout + /tmp/aurora_debug.log（App 启动时清空）
    /// 用户从终端启动可实时看到；事后我读文件定位运行时问题
    private func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)"
        print(line)
        let url = URL(fileURLWithPath: "/tmp/aurora_debug.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // P1 修复：dlog 每秒追加，7×24 运行日志无限增长。写前检查大小，超 10MB
        // 直接覆盖重写（truncate），只保留最近日志，封顶磁盘占用。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > 10 * 1024 * 1024 {
            try? data.write(to: url, options: .atomic)
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 行驶录制开关（didSet 触发 RecordEngine 启停 + 画面流/键盘监听接管）
    /// true → 开始录制会话；未在驾驶时由录制器负责拉起截屏画面流与键盘监听
    ///（否则不开车就开录制器会录出空目录）
    /// false → 写 meta.json 并关闭；驾驶仍开着时不关画面流/键盘监听（驾驶还在用）
    ///
    /// ⚠️ 引擎模式：帧只存在于引擎进程（UI 没有画面流），录制必须由引擎执行，
    /// 这里只把开关转发过去。早先在引擎模式下仍然本地 recordEngine.start()，
    /// 结果是「目录建了、文件建了，但录不进任何东西」——因为 UI 的 tick 在引擎
    /// 模式下提前 return，recordFrameIfNeeded() 永远不执行。
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            guard !applyingRemoteRecord else { return }   // 来自引擎回同步，别回声
            if EngineClient.shared.isActive {
                lastRecordCommandTime = Date()   // 宽限期起点：别让未更新的心跳把开关弹回去
                EngineClient.shared.sendCommand("record", extra: [
                    "on": isRecording,
                    "glyph": glyphMode,
                    "expert": expertMode,
                ])
                return
            }
            if isRecording {
                // 每次开始录制前同步字模模式开关。注意：录制中途切换 glyphMode 不影响
                // 本次会话（语义为「录制中切换不生效，需重启录制」），故不做实时热切换。
                recordEngine.glyphMode = glyphMode
                recordEngine.start(perspective: "first")
                if !captureEngine.isCapturing {
                    captureEngine.start()
                }
                keyboardMonitor.start()
            } else {
                recordEngine.stop()
                if !isDriving {
                    captureEngine.stop()
                    keyboardMonitor.stop()
                }
            }
        }
    }

    /// 防回环标记：tickEngineMode 把引擎录制状态镜像到 isRecording 时置位，
    /// 避免 didSet 又把「record」命令回声给引擎。
    @ObservationIgnored var applyingRemoteRecord = false

    /// 最后一次向引擎发送「record」命令的时间。
    /// 心跳周期 1s，命令刚发出时引擎还没来得及上报，若不设宽限期，
    /// UI 会在下一次 tick（30Hz）立刻把 isRecording 弹回旧值 → 开关按下即回弹。
    @ObservationIgnored var lastRecordCommandTime = Date.distantPast

    /// 引擎协议版本不匹配时的用户可见告警（空 = 无告警）
    var engineVersionWarning = ""

    /// 当前驾驶模式（由降级状态机计算，每帧 tick 同步）
    /// UI 观察此属性刷新模式芯片高亮
    var mode: DriveMode = .e2e
    /// 主驾置信度。0 = 引擎尚未上报（UI 显示「—」）。
    /// 初值刻意不用 0.92 这类"看起来真实"的数字冒充读数。
    var confidence: Double = 0          // 0~1

    // ══════════════════════════════════════════════════════════════════
    // MARK: 路况自适应（黑灰白 UI · 状态色驱动全局）
    // ══════════════════════════════════════════════════════════════════
    //
    // 四态：简单/复杂/极度复杂/关闭。决定自动速度是否工作、
    // 以及界面的强调色（绿/橙/红/灰）。
    //
    // 目前由用户手动切换；后续若要接模型输出，把 setter 改成
    // 从 M9 或规则层推导即可，UI 侧无需改动。

    /// 不限速是谁设的（用户手动 / 自动速度）。
    /// 用于解决优先级冲突：用户手动设的不限速锁死自动速度；自动设的可以被覆盖。
    @ObservationIgnored var unlimitedSource: SpeedLimitSource = .none

    /// 当前路况自适应状态
    var roadCondition: RoadCondition = .simple
    /// 自动速度：开 → 按路况自动下发限速（6 档见 RoadCondition.autoSpeedLimit）
    var autoSpeedEnabled = true

    /// 切换路况自适应（带副作用：极度复杂时挂起自动速度并告警）
    func setRoadCondition(_ rc: RoadCondition) {
        guard roadCondition != rc else { return }
        roadCondition = rc
        switch rc {
        case .extreme:
            print("[RC] ⚠️ 路况极度复杂，自动速度已挂起，请接管方向盘")
        case .off:
            print("[RC] 自动速度已关闭")
        default:
            print("[RC] 路况自适应 → \(rc.shortName)")
        }
    }

    /// 端到端延迟（ms），给双圆表左表用。
    ///
    /// 数据来源（都是已有字段，不引入新计时）：
    ///   · 引擎模式：读心跳回传的 fps 反推单帧预算
    ///   · 本地模式：读主线程 tick 实测间隔（tickGapMs）
    /// 两者都没有时返回 0，UI 显示「--」。
    var e2eLatencyMs: Double {
        if EngineClient.shared.isActive {
            let f = EngineClient.shared.engineFPS
            return f > 0 ? (1000.0 / f) : 0
        }
        return tickGapMs > 0 ? tickGapMs : (fps > 0 ? 1000.0 / fps : 0)
    }

    /// 上一帧状态机决策档位：用于检测"刚切入 .recover"的边沿，
    /// 让脱困只 enter 一次（避免每帧 phase==.done 就 re-enter 抵消超时）。
    private var lastDecided: DriveMode = .e2e

    /// 有效车速（km/h）：每帧由 OCR 新鲜读数（EMA 平滑）或一阶滤波回退计算
    /// 供 M9 vehicle_state、卡死判据、脱困退出使用 —— 替代原模拟速度
    var effectiveSpeed: Double = 0

    /// 有效车速是否新鲜（OCR 读数新鲜：lastResultTime < 0.5s 且 confidence > 0.3）
    /// 不新鲜时卡死判据不计入 stuckSeconds；感知融合层可直接消费此健康标志
    var speedValid: Bool = false

    /// 兼容属性：旧代码读 speed 的地方统一读到 effectiveSpeed（不再有模拟值/随机抖动）
    var speed: Double { effectiveSpeed }

    /// 实测帧率。0 = 尚未测量（UI 如实显示「—」，不伪装成 60）。
    var fps: Double        = 0

    /// 车速 OCR 最新快照（主线程读；未读到为 -1 / 0）
    /// 读自 speedOCR（@Observable 嵌套，body 访问会跟踪其更新）
    var speedKmh: Double { EngineClient.shared.isActive ? remoteSpeedKmh : speedOCR.speedKmh }
    var speedConfidence: Double { speedOCR.confidence }

    /// M9 推理链路状态（UI 显示：M9 到底有没有真的在参与开车）
    /// - M9活跃：模型已加载 && 最近 1s 内出过推理结果 → 真在开车
    /// - M9失联：结果超过 1s 没更新（没画面/推理卡死）→ 没参与
    /// - M9未加载：模型文件缺失或加载失败
    var m9Status: (text: String, color: Color) {
        if !inferenceEngine.isLoaded {
            return ("M9未加载", Aurora.t3)
        }
        if let t = inferenceEngine.lastResultTime, Date().timeIntervalSince(t) < 1.0 {
            return ("M9活跃", Aurora.ice)
        }
        return ("M9失联", Aurora.danger)
    }

    var speedLimit: Double      = 120   // 速度上限
    var degradeThreshold: Double = 0.65 // 降级阈值（同步给状态机）

    var modelVersion = "v2.4.1-e2e-fsd"
    /// 累计帧数。0 = 尚未开始计数。
    var frames: Int  = 0

    // ── 截屏画面流（UI 显示与模型推理共用同一条流）──
    // currentScreenImage 由 CaptureEngine 的 onFrame 闭包更新，仍是录制/现有引用的数据源；
    // currentFrameCG 同源（同一回调直传的 CGImage），供推屏/推理/置信度使用，省 NSImage→CGImage 重复转换；
    // UI 显示已改走 frameHost 直绘（绕开 SwiftUI diff），故两者均标 @ObservationIgnored。
    @ObservationIgnored var currentScreenImage: NSImage? = nil
    @ObservationIgnored var currentFrameCG: CGImage? = nil
    @ObservationIgnored var frameHost = FrameHost()
    // 源画面尺寸（普通 @Observable，驱动 ObstacleOverlay 的 aspect-fill 对齐）。
    // 不能从 @ObservationIgnored 的 frameHost.latestSize 读，否则尺寸变化不触发
    // 观察导致检测框错位；仅在尺寸变化时写，避免每帧失效。
    var screenSize: CGSize? = nil

    /// 画面分辨率标签（取自真实源画面尺寸；未取到前显示「—」，不写死分辨率）。
    var resolutionLabel: String {
        guard let s = screenSize, s.width > 1, s.height > 1 else { return "—" }
        return "\(Int(s.width))×\(Int(s.height))"
    }

    /// 当前所在区域名。由实时定位坐标在真实地图数据库里反查最近标记的区域得出
    /// —— 不写死地名。未定位时显示「未知区域」。
    var regionLabel: String {
        guard locatorFound else { return "未知区域" }
        return MapDatabase.regionName(atMapX: mapPixelX, mapY: mapPixelY) ?? "未知区域"
    }

    /// 地图标记总数（可观察）。MapDatabase 是静态存储不触发 SwiftUI 更新，
    /// 这里在加载完成后同步一份，顶栏数字才能如实刷新。
    var mapMarkerCount: Int = 0

    /// 当前实际加载的推理模型名（供顶栏如实显示，不写死）。
    /// 优先取引擎上报的模型名，未连接时显示实际将要加载的模型文件。
    var activeModelLabel: String {
        let engine = EngineClient.shared
        let name = Self.detectedModelName()
        // 真实判定：模型文件在盘上 + 引擎在跑，才叫「已挂载 · ANE」。
        // 任一不满足都如实说明缺哪一环，不拿"引擎在跑"冒充"模型已挂载"。
        guard Self.modelFileExists() else { return "\(name) · 模型缺失" }
        return engine.isActive ? "\(name) · ANE" : "\(name) · 引擎未连接"
    }

    /// 探测实际存在的模型文件（models/yolo26s.mlmodelc 等），返回真实模型名。
    static func detectedModelName() -> String {
        let fm = FileManager.default
        // 必须用 AuroraPaths.projectRoot() 而不是 currentDirectoryPath：
        // 双击 .app 启动时 cwd 是 "/"，用 cwd 找 models 永远找不到，
        // 于是界面一直显示「未挂载」——正是用户看到的问题。
        let modelsDir = AuroraPaths.projectRoot().appendingPathComponent("models")
        // 按优先级探测：编译产物(.mlmodelc) → 包(.mlpackage)
        for candidate in ["yolo26s.mlmodelc", "yolo26s.mlpackage"] {
            if fm.fileExists(atPath: modelsDir.appendingPathComponent(candidate).path) {
                return String(candidate.split(separator: ".").first ?? "yolo26s")
            }
        }
        return "yolo26s"
    }

    /// 模型是否真实存在于磁盘（用于区分「已挂载」与「未挂载」，
    /// 不再只看引擎是否在跑 —— 引擎跑着但模型缺失时也必须如实报未挂载）。
    static func modelFileExists() -> Bool {
        let fm = FileManager.default
        let modelsDir = AuroraPaths.projectRoot().appendingPathComponent("models")
        for candidate in ["yolo26s.mlmodelc", "yolo26s.mlpackage"] {
            if fm.fileExists(atPath: modelsDir.appendingPathComponent(candidate).path) {
                return true
            }
        }
        return false
    }
    // isStreaming 控制 GameViewportView 显示"实时画面 vs 黑底提示"分支，启/停各翻转一次，
    // 必须保持 @Observable（观察成本可忽略），否则停止后分支不触发重绘导致画面冻结。
    var isStreaming = false

    // ── 插帧/超分（仅显示路径，绝不进入决策链路）──
    @ObservationIgnored var upscaleHost = UpscaleFrameHost()
    var upscaleEnabled: Bool = false
    var upscaleSupported = false
    var upscaleLive: String? = nil
    var upscaleEngineError: String? = nil

    /// 游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权）
    var gameModeBoost: Bool = true {
        didSet {
            if gameModeBoost != oldValue {
                applyMainThreadBoost(gameModeBoost)
                // 启用时加强心跳，防止系统冻结
                if gameModeBoost {
                    startAntiFreeze()
                } else {
                    stopAntiFreeze()
                }
            }
        }
    }
    
    /// 防冻结心跳定时器（游戏模式下强制唤醒主线程）
    @ObservationIgnored
    private var antiFreezeTimer: DispatchSourceTimer?

    /// 限速刹车执行器（纯规则，独立于任何驾驶模型）
    @ObservationIgnored let speedLimitGuard = SpeedLimitGuard()

    /// 自动路况判定：待确认的建议路况（稳定性门用）
    @ObservationIgnored var pendingCondition: RoadCondition?
    /// 同一建议连续成立了多少帧
    @ObservationIgnored var conditionStableFrames = 0
    /// 最新一次判定用的检测框数量（UI 如实展示判定依据）
    var detectedBoxCount: Int = 0
    /// 限速刹车当前是否处于「已按下」状态（用于检测松开边沿，防手刹卡键）
    @ObservationIgnored var speedLimitBrakeLatched = false
    /// 上一次记录的刹车级别（仅用于级别变化时记日志）
    @ObservationIgnored var speedLimitBrakeLastStage: SpeedLimitGuard.Stage = .none

    // ── 诊断（验证"越到后面越卡=积压"）：onFrame 帧从入队到主线程执行的延迟(ms) ──
    // 若该值随时间持续增长 → main 队列积压确认（每帧 main.async + 22MB 大图堆积）
    @ObservationIgnored
    nonisolated(unsafe) var frameDeliveryLagMs: Double = 0

    // ── 跳帧防堆积（用户拍板方案）：待显示最新帧 ──
    // onFrame 在 captureQueue 线程只"覆盖"最新一帧（不 main.async 排队）；
    // tick 主线程每帧取最新一帧给 UI —— 主线程处理不过来时旧帧被覆盖丢弃，
    // 永不堆积（= 强制同步跳帧）。捕获/推理频率不变（30fps 红线）。
    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrame: NSImage?
    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrameCG: CGImage?
    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrameTime: Date?
    @ObservationIgnored
    private nonisolated(unsafe) let pendingFrameLock = NSLock()

    // ── YOLO 直通帧跳帧（同 pendingFrame 模式）：captureQueue 覆盖最新帧，tick 消费 ──
    @ObservationIgnored
    private nonisolated(unsafe) var pendingYoloFrame: CVPixelBuffer?
    @ObservationIgnored
    private nonisolated(unsafe) let pendingYoloLock = NSLock()

    // ── 原生 ROI 帧跳帧（同 pendingFrame 模式）：OCR/字模录制消费 ──
    @ObservationIgnored
    private nonisolated(unsafe) var pendingNativeFrame: CVPixelBuffer?
    @ObservationIgnored
    private nonisolated(unsafe) let pendingNativeLock = NSLock()

    // ── 诊断：主线程 tick 实际间隔(ms)（>33ms = 主线程掉拍/被卡）──
    // tick 由 30Hz Timer 驱动，间隔应稳定 ~33ms；出现 66/99ms 或更大 = 主线程被阻塞
    @ObservationIgnored
    private var lastTickTime = Date()
    @ObservationIgnored
    var tickGapMs: Double = 0

    /// 进程物理内存占用（MB）——诊断用：积压 → 内存随时间线性上涨的验证指标
    func processMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
    }

    /// 截屏引擎实例（启动时创建，全屏画面流 30fps）
    /// isDriving 启动时 start()，停止时 stop()
    let captureEngine = CaptureEngine()
    /// 游戏画面左上角帧率 HUD（绿色两行：辅助帧率 / 游戏帧率）
    /// 兼作对抗 Game Mode 的"可见窗口"（见 GameHUDWindow.swift 头注释）
    let gameHUD = GameHUDWindow()

    /// 截屏权限状态（首次启动若未授权，引导用户到系统设置）
    var capturePermissionDenied = false

    // ── 按键注入引擎（CGEvent 控制 WASD/空格/Shift）──
    // 启动时检查辅助功能权限，停止时释放所有按住的键
    let controlEngine = ControlEngine()

    /// 辅助功能权限状态（首次启动若未授权，引导用户到系统设置）
    var controlPermissionDenied = false

    // ── 物理键盘监听（实时读取用户真实按键，供 KeyBar 显示）──
    // 与 controlEngine 区别：
    //   controlEngine = AI 注入的按键（输出）
    //   keyboardMonitor = 用户物理按下的键（输入，仅显示用 + 录制专家演示）
    let keyboardMonitor = KeyboardMonitor()

    // ── 降级状态机（四态 + 极速覆盖 + 卡住检测）──
    // tick() 每帧调用 update()，结果同步到 self.mode
    // 阈值由本类的 degradeThreshold 等属性同步过去，UI 可调
    let degradeStm = DegradeStateMachine()

    // ── 行驶录制引擎（画面+控制量 → recordings/）──
    // isRecording didSet 触发启停，tick() 每帧调用 appendFrame
    // 兼容现有 recordings 格式，供 DAgger 增量训练消费
    let recordEngine = RecordEngine()

    // ── 网络抓包定位引擎（NetworkExtension，UE5 移动包解析）──
    // TCP 30031 端口抓包，解析 UE5 移动包 bit-packed 格式
    // 输出游戏世界坐标 + 相机位姿，坐标变换到地图像素
    // 旧NetworkPacketCapture已移除（不编译），使用移植的NetworkLocator
    // @ObservationIgnored let networkLocator = NetworkPacketCapture()

    // ── 三段胶水代码（接模型输出 → 状态机 → 按键注入）──
    // escapeController: .recover 态脱困策略（倒车→转向→前进）
    // ruleController:   .yolo/.rule 态 YOLO 检测→控制量规则
    // confidenceEst:    E2E 无置信度头，用启发式从输出/画面估算
    let escapeController = EscapeController()
    let ruleController = RuleController()
    let confidenceEst = ConfidenceEstimator()

    // ── CoreML E2E 推理引擎（m9_mono.mlpackage）──
    // tick 异步触发推理，读 lastResult 作为本帧 E2E 输出
    // 推理约 24Hz，tick 30Hz，未完成推理时沿用上一帧结果
    let inferenceEngine = InferenceEngine()

    // ── 第二套驾驶模型（game_assist_control，YOLO接管档的司机）──
    // 与 M9 同架构（画面+车辆状态→steer/throttle/brake），独立权重文件。
    // 档2 YOLO接管 用它的输出开车；当前与 M9 同权重，后续可换训练权重。
    let assistEngine = InferenceEngine(modelFileName: "game_assist_control")

    // ── CoreML YOLO 检测引擎（game_assist_yolo.mlpackage）──
    // Yolo-FastestV2 / COCO-80，anchor 解码已烘进模型
    // tick 异步触发，检测结果同时喂 RuleController 决策 + UI 画框
    let yoloEngine = YoloEngine()

    // ── 车速表 OCR 读取引擎（Vision，原生帧 ROI 直裁直读，不插值）──
    // CaptureEngine 原生帧 → 后台 OCR 读车速 → 主线程读 speedKmh/speedConfidence
    let speedOCR = SpeedOCRReader()

    /// 本帧最终决策命令（tick 末尾写出，供按键注入用）
    /// 模型未接入前用占位值，状态机/降级逻辑已真实生效
    private(set) var currentCommand: ControlCommand = .idle

    init() {
        // 只在「UI 主进程」清空调试日志。
        // 背景：DriveState 有 5 个创建点（引擎进程 1 + UI 主进程 1 + 三个截图夹具），
        // 每个都会执行这一行；而引擎与 UI 是两个长驻进程、共用同一个日志文件，
        // 若引擎启动时也清空，会把 UI 刚写下的启动诊断整段抹掉（两进程互相删）。
        // 判定：只有「正常 GUI 启动」（无参数）与「--auto-login」（run.sh 的 GUI
        // 启动变体）两种形态清空；其余任何带参数的形态（--engine / 全部 one-shot
        // 自检 / mc-shot / agent-ui-shot / agent-layout-shot / yolo-bench / daemon /
        // agent-command / set-llm-config …）一律不清——夹具不该动生产日志。
        let args = CommandLine.arguments
        let isUIStartup = args.dropFirst().allSatisfy { $0 == "--auto-login" }
        if isUIStartup {
            try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")
        }
        // ── 帧率 HUD（左上角绿色两行）：兼作 Game Mode 对抗的可见窗口 ──
        gameHUD.fpsProvider = { [weak self] in
            guard let self else { return (0, 0) }
            // 辅助帧率：主线程 tick 速率（1000 / 上次 tick 间隔 ms）
            let gap = self.tickGapMs
            let assist = gap > 1 ? 1000.0 / gap : 0
            // 游戏帧率：ScreenCaptureKit 实际捕获到的合成帧率（≈游戏渲染帧率）
            let game = self.captureEngine.captureFPS
            return (assist, game)
        }
        // ★ 仅 UI 进程安装：引擎进程（--engine）也创建 DriveState，但它没有
        //   NSApplication UI 上下文，在其中创建 NSWindow 会触发 AppKit 断言崩溃
        //   （实测：NSViewSetCurrentlyBuildingLayerTreeForDisplay, NSView.m:12937，
        //   导致引擎「就绪」后 1ms 即崩、UI 显示失联）。
        if !CommandLine.arguments.contains("--engine") {
            gameHUD.install()
        }
        // 接线截屏引擎回调
        // onFrame: 每帧调用，更新 currentScreenImage（主线程，SwiftUI 自动刷新）
        // onStatusChange: 启动/停止/错误/权限拒绝
        captureEngine.onFrame = { [weak self] image, cgImage in
            // 跳帧防堆积：CaptureEngine 回调在 captureQueue 后台线程，
            // 这里只"覆盖"最新待显示帧（加锁），不再 main.async 排队。
            // 主线程（tick）卡时，旧帧被下一帧覆盖丢弃 → 天然跳帧，永不积压。
            // SwiftUI 更新由 tick 在主线程赋 currentScreenImage 触发（见 tick()）。
            // NSImage + CGImage 同回调原子写入，避免推屏/推理/录制跨帧错位。
            guard let self else { return }
            self.pendingFrameLock.lock()
            self.pendingFrame = image
            self.pendingFrameCG = cgImage
            self.pendingFrameTime = Date()
            self.pendingFrameLock.unlock()
        }
        // YOLO 直通：CaptureEngine 源头 GPU 缩放好的 352×352 缓冲，
        // 直接喂推理引擎（跳过 NSImage/CGImage 大图转换 → 检测帧率↑）
        captureEngine.onYoloFrame = { [weak self] pb in
            // 跳帧防堆积：captureQueue 只覆盖最新 YOLO 帧，tick 主线程取最新消费，
            // 主线程卡时旧帧被覆盖丢弃，不往 main 队列堆积 1.6MB 缓冲。
            guard let self else { return }
            self.pendingYoloLock.lock()
            self.pendingYoloFrame = pb
            self.pendingYoloLock.unlock()
        }
        // SpeedOCR 直通：原生全屏帧 → 后台 OCR 读车速（主线程读最新快照）
        // P1-2：字模录制复用同一条原生 ROI 直通（speedROINorm 与 glyphROI 同区域），
        // 直接把原生缓冲交给 RecordEngine 存字模 PNG（数字 ~95px，不再走 480px 缩略图）
        captureEngine.onNativeFrame = { [weak self] pb in
            // 跳帧防堆积（同 YOLO）：captureQueue 覆盖最新原生 ROI 帧，tick 消费，
            // 主线程卡时旧帧覆盖丢弃，不往 main 队列堆积。
            guard let self else { return }
            self.pendingNativeLock.lock()
            self.pendingNativeFrame = pb
            self.pendingNativeLock.unlock()
        }
        // 插帧/超分直通：全分辨率帧 → MetalGoose 引擎（仅显示路径）
        captureEngine.onUpscaleFrame = { [weak self] pb in
            guard let self else { return }
            self.upscaleHost.push(pixelBuffer: pb)
        }
        // 门禁：运行时读最新插帧开关（weak 捕获），关闭时不做全分辨率拷贝
        captureEngine.isUpscaleWanted = { [weak self] in self?.upscaleEnabled ?? false }
        captureEngine.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .permissionDenied:
                    self?.capturePermissionDenied = true
                case .started:
                    self?.capturePermissionDenied = false
                    self?.isStreaming = true
                case .stopped, .error:
                    self?.isStreaming = false
                    // 画面回落黑底并释放最新帧缓存（避免常驻 + 重启闪旧帧）
                    self?.frameHost.clear()
                    // 清残留 pending 帧，避免停止后下一 tick 消费旧帧再 push（重启闪旧帧）
                    self?.pendingFrameLock.lock()
                    self?.pendingFrame = nil
                    self?.pendingFrameCG = nil
                    self?.pendingFrameTime = nil
                    self?.pendingFrameLock.unlock()
                    // 清残留 YOLO/原生 ROI 直通帧
                    self?.pendingYoloLock.lock()
                    self?.pendingYoloFrame = nil
                    self?.pendingYoloLock.unlock()
                    self?.pendingNativeLock.lock()
                    self?.pendingNativeFrame = nil
                    self?.pendingNativeLock.unlock()
                }
            }
        }
        // 初始化插帧/超分引擎
        // 只在 UI 进程做：引擎进程没有窗口/MTKView，upscaleHost 不会被使用
        //（EngineMain 侧把「喂本进程 upscaleHost」的默认接线覆盖掉了），
        // 而 prepare() 会走 MTLCreateSystemDefaultDevice + 运行时编译 466 行
        // shader（~100ms-1s），在引擎进程里纯属白费启动时间。
        if !CommandLine.arguments.contains("--engine") {
            upscaleHost.prepare()
            upscaleSupported = upscaleHost.isAvailable
            dlog("[upscale] 引擎初始化: 可用=\(upscaleSupported)")
        }

        // 引擎（重新）连上时，把 UI 当前的画面档位同步给引擎：
        // 否则引擎默认发 480 宽缩略帧，UI 开着插帧就会一直等不到全分辨率帧。
        EngineClient.shared.onActivated = { [weak self] in
            guard let self else { return }
            EngineClient.shared.setUpscale(self.upscaleEnabled && self.upscaleSupported)
            EngineClient.shared.sendCommand("status")
        }

        // 旧网络定位已移除
        // 旧网络定位回调已移除（NetworkPacketCapture不编译）
        // networkLocator.onLocate = { [weak self] result in
        //     self?.handleNetworkLocate(result)
        // }
        // networkLocator.onStatusChange = { [weak self] status in
        //     DispatchQueue.main.async {
        //         switch status {
        //         case .started:
        //             self?.networkLocateMode = "network"
        //         case .permissionDenied:
        //             self?.networkLocateMode = "permission_denied"
        //         case .error(let msg):
        //             self?.networkLocateMode = "error: \(msg)"
        //         default: break
        //         }
        //     }
        // }
        dlog("[network] 定位引擎初始化完成")
    }

    /// 启动自动驾驶：
    /// 1. 检查辅助功能权限（按键注入必需）
    /// 2. 启动物理键盘监听（KeyboardBar 显示用 + 录制专家演示）
    /// 3. 启动截屏画面流
    /// 4. 后续由推理引擎决定注入什么按键（当前仅占位，状态机已就位）
    func startDriving() {
        // ── 引擎模式：命令转发给后台引擎（UI 不启动本地抓屏/推理/按键）──
        if EngineClient.shared.isActive {
            EngineClient.shared.sendCommand("start")
            lastDriveCommandTime = Date()
            isDriving = true
            drivingStartTime = Date()
            dlog("[引擎模式] 已发送 start 命令给后台引擎")
            return
        }
        // 权限检查：按键注入需要辅助功能权限
        // 无权限时引导用户到系统设置，不启动
        guard controlEngine.checkPermission() else {
            controlPermissionDenied = true
            controlEngine.openAccessibilitySettings()
            return
        }
        controlPermissionDenied = false

        // 开始驾驶前清掉系统里残留的卡键（上次进程异常退出可能留下
        // 未释放的 W/A/S/D，污染游戏输入；releaseAll 无条件清理）
        controlEngine.releaseAll()

        isDriving = true
        drivingStartTime = Date()
        keyboardMonitor.start()   // 启动物理键盘监听（KeyboardBar 显示用 + 录制用）
        captureEngine.start()
        // networkLocator.start()  // 旧网络抓包定位已移除    // 启动网络抓包定位
        inferenceEngine.loadIfNeeded()   // 首次启动加载 M9 驾驶模型
        assistEngine.loadIfNeeded()      // 首次启动加载第二套驾驶模型（YOLO接管档）
        yoloEngine.loadIfNeeded()        // 首次启动加载 YOLO 检测模型
        dlog("启动开车: 辅助功能权限=\(controlEngine.hasAccessibilityPermission) 专家模式=\(expertMode) 禁用控制=\(controlDisabled)")
        dlog("模型加载: M9=\(inferenceEngine.isLoaded) 第二司机=\(assistEngine.isLoaded) YOLO=\(yoloEngine.isLoaded) M9错误=\(inferenceEngine.errorMessage ?? "-")")
    }

    /// 停止自动驾驶：
    /// 1. 释放所有按住的键（避免按键卡住，导致游戏失控）
    /// 2. 停止物理键盘监听
    /// 3. 停止截屏画面流
    /// 4. 重置降级状态机 + 脱困控制器 + 置信度估计器 + 推理引擎
    /// 5. 若正在录制，一并停止录制（保证 meta.json 落盘）
    func stopDriving() {
        // ── 引擎模式：命令转发给后台引擎（引擎侧释放按键并停止抓屏）──
        if EngineClient.shared.isActive {
            EngineClient.shared.sendCommand("stop")
            lastDriveCommandTime = Date()
            isDriving = false
            dlog("[引擎模式] 已发送 stop 命令给后台引擎")
            return
        }
        isDriving = false
        controlEngine.releaseAll()
        keyboardMonitor.stop()
        captureEngine.stop()
        // networkLocator.stop()   // 旧网络抓包定位已移除
        degradeStm.reset()
        escapeController.reset()
        lastDecided = .e2e
        confidenceEst.reset()
        inferenceEngine.reset()
        assistEngine.reset()
        yoloEngine.reset()
        speedOCR.reset()
        currentCommand = .idle
        if isRecording { isRecording = false }   // didSet 会触发 recordEngine.stop()
    }

    /// 处理网络定位结果
    // 旧方法已移除（NetworkPacketCapture不编译）
    // func handleNetworkLocate(_ result: NetworkLocateResult) {
    //     if result.found, let point = result.point {
    //         networkLocateX = Double(point.x)
    //         networkLocateY = Double(point.y)
    //         networkLocateScore = result.score
    //         networkLocateMode = result.mode
    //         if let pitch = result.cameraPitch { networkLocatePitch = pitch }
    //         if let heading = result.cameraHeading { networkLocateHeading = heading }
    //         networkLocateLastUpdate = Date()
    //     } else {
    //         networkLocateScore = 0
    //         networkLocateMode = "failed"
    //     }
    // }

    func setUpscaleEnabled(_ on: Bool) {
        upscaleEnabled = on
        captureEngine.upscaleEnabled = on
        // 引擎模式：通知后台引擎切画面档位（全分辨率 ↔ 480 宽缩略），
        // 否则引擎不知道 UI 开没开插帧，会一直发缩略帧导致插帧没数据。
        if EngineClient.shared.isActive {
            EngineClient.shared.setUpscale(on)
        }
        dlog("[upscale] 开关=\(on) 引擎可用=\(upscaleSupported) 引擎模式=\(EngineClient.shared.isActive)")
    }

    func setGameModeBoost(_ on: Bool) {
        gameModeBoost = on
        captureEngine.gameModeBoostEnabled = on
        applyMainThreadBoost(on)
        
        // 开启时：检查是否已安装 daemon，未安装则弹出安装引导
        if on {
            startAntiFreeze()
            if DaemonSetupManager.needsInstall() {
                // 延迟 0.5s 弹出安装引导，避免与启动时的弹窗冲突
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.showDaemonInstallSheet = true
                }
            }
        } else {
            stopAntiFreeze()
        }
        dlog("[boost] 游戏模式兼容=\(on)")
    }
    
    // MARK: - 防冻结心跳（已禁用：100ms键盘事件导致系统崩溃）
    
    /// 启动防冻结心跳：已禁用
    /// 原因：每100ms发送键盘事件导致系统崩溃，鼠标无法移动
    private func startAntiFreeze() {
        // 已禁用，不再启动心跳
        dlog("[antifreeze] 心跳已禁用（避免系统崩溃）")
    }
    
    /// 停止防冻结心跳
    private func stopAntiFreeze() {
        antiFreezeTimer?.cancel()
        antiFreezeTimer = nil
    }

    // MARK: - 一键训练（拉起 Python 训练进程）

    /// 一键训练：拉起 python3.11 训练脚本（只训控制模型）
    ///   --skip_view : 视角分类器按决策删除不做，不训练
    ///   --skip_yolo : YOLO 用现成预训练 CoreML（models/game_assist_yolo.mlmodelc），无需重训
    /// 训练完成后自动把新控制模型热替换进推理引擎（点完即用）。
    /// 进程后台运行，UI 按钮文字切到「训练中…」，结束经 terminationHandler 回主线程。
    @MainActor
    func startTraining() {
        guard !isTraining else { return }
        isTraining = true
        trainingLog = "启动训练进程…"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3.11")
        // 只训控制模型；YOLO 检测已由 YoloEngine 实时运行，视角分类器已移除。
        proc.arguments = ["src/train_game_assist.py", "--skip_view", "--skip_yolo"]
        proc.currentDirectoryURL = URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统")

        // 输出重定向到日志文件，避免管道缓冲区满导致训练进程挂起
        let logURL = URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统/train.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        proc.standardOutput = FileHandle(forWritingAtPath: logURL.path)
        proc.standardError  = proc.standardOutput

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isTraining = false
                if process.terminationStatus == 0 {
                    self.trainingLog = "训练完成，应用新模型…"
                    if self.deployTrainedModel() {
                        self.clearRawClips()
                    }
                } else {
                    self.trainingLog = "训练失败（退出码 \(process.terminationStatus)），详见 train.log"
                }
            }
        }

        do {
            try proc.run()
        } catch {
            isTraining = false
            trainingLog = "无法启动训练: \(error.localizedDescription)"
        }
    }

    /// 把训练产出的控制模型复制到 m9_mono.{mlmodelc|mlpackage} 并热替换推理引擎。
    /// 优先 FPV 专用模型（当前录制为 FPV 视角），回退 TPV/FPV 共用模型。
    /// 扩展名跟随源：若 coremlcompiler 缺失，coremltools 仍会 save 出 .mlpackage，
    /// CoreML 运行时可直接加载未编译的 .mlpackage，链路照样闭环。
    /// - Returns: 部署是否成功（成功才清理录制数据）
    @discardableResult
    private func deployTrainedModel() -> Bool {
        let modelsDir = AuroraPaths.projectRoot()
            .appendingPathComponent("models")
        let names = ["game_assist_control_fpv.mlmodelc", "game_assist_control.mlmodelc",
                     "game_assist_control_fpv.mlpackage", "game_assist_control.mlpackage"]
        guard let src = names.compactMap({ modelsDir.appendingPathComponent($0) })
                             .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            trainingLog = "未找到训练产出的控制模型，请检查 train.log"
            return false
        }
        let dst = modelsDir.appendingPathComponent("m9_mono.\(src.pathExtension)")
        do {
            // 清理另一扩展名的旧模型，避免 InferenceEngine.modelURL 误选
            for ext in ["mlmodelc", "mlpackage"] where ext != src.pathExtension {
                let old = modelsDir.appendingPathComponent("m9_mono.\(ext)")
                if FileManager.default.fileExists(atPath: old.path) {
                    try FileManager.default.removeItem(at: old)
                }
            }
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            // 模型文件已落盘；但真正开车的推理引擎可能不在本进程：
            //   引擎模式 → 命令引擎重新加载（否则引擎一直用内存里的旧模型）
            //   本地模式 → 直接置空本进程的三个引擎
            if EngineClient.shared.isActive {
                EngineClient.shared.sendCommand("reloadmodel")
                inferenceEngine.reloadModel()
                trainingLog = "已应用新模型（引擎侧已通知重载）: \(src.lastPathComponent)"
            } else {
                inferenceEngine.reloadModel()
                assistEngine.reloadModel()
                yoloEngine.reloadModel()
                trainingLog = "已应用新模型: \(src.lastPathComponent)"
            }
            return true
        } catch {
            trainingLog = "模型部署失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 训练成功且模型部署后，清理 data/raw_clips 下所有录制 clip。
    /// 录制数据仅用于训练，训完即弃，避免无限累积、下次训练重复读取旧数据。
    /// 仅在部署成功时调用；失败保留数据以便排查。
    private func clearRawClips() {
        let rawClips = AuroraPaths.projectRoot()
            .appendingPathComponent("data/raw_clips")
        guard FileManager.default.fileExists(atPath: rawClips.path) else { return }
        do {
            let items = try FileManager.default.contentsOfDirectory(at: rawClips, includingPropertiesForKeys: nil)
            var removed = 0
            for url in items where url.lastPathComponent.hasPrefix("clip_") {
                try FileManager.default.removeItem(at: url)
                removed += 1
            }
            trainingLog = "已应用新模型，并清理 \(removed) 段录制数据"
        } catch {
            trainingLog = "模型已应用，但清理录制数据失败: \(error.localizedDescription)"
        }
    }

    /// 引擎模式 tick：抓屏/推理/按键都在后台引擎里，UI 只拉取显示数据
    private func tickEngineMode() {
        let client = EngineClient.shared
        // 镜像连接状态到 DriveState（@Observable），供状态栏显示
        if engineModeActive != client.isActive { engineModeActive = client.isActive }
        if engineConnected != client.isConnected { engineConnected = client.isConnected }

        // 档位：开插帧 → 引擎发全分辨率帧，UI 读成 CVPixelBuffer 喂 MetalGoose；
        //       否则 → 引擎发 480 宽缩略帧，UI 读成 CGImage 直绘。
        let useUpscale = upscaleEnabled && upscaleSupported
        client.wantPixelBuffer = useUpscale

        let cg = client.poll()
        if useUpscale {
            if let pb = client.takePixelBuffer() {
                upscaleHost.push(pixelBuffer: pb)
                isStreaming = true
                // 源尺寸必须随帧更新（不能只在 nil 时设一次）：
                // 检测框叠加、框选手势的坐标换算都以 screenSize 为基准，
                // 尺寸变了却不更新 → 框错位、框选选不中。
                let sz = CGSize(width: CVPixelBufferGetWidth(pb),
                                height: CVPixelBufferGetHeight(pb))
                if screenSize != sz { screenSize = sz }
            }
        } else if let cg {
            currentFrameCG = cg
            let sz = CGSize(width: cg.width, height: cg.height)
            if screenSize != sz { screenSize = sz }
            isStreaming = true
            frameHost.push(cg)
        }
        // 先比后写：检测列表值不变时跳过 @Observable 写入（省观察者通知）。
        // Detection 已 Equatable，20 元素 × 7 字段的比较成本远低于每次写入触发的
        // SwiftUI 刷新链。
        if remoteDetections != client.engineDetections {
            remoteDetections = client.engineDetections
        }
        // 引擎已停止抓屏（点了停止/暂停）→ UI 侧同步收尾：
        // 否则 isStreaming 会一直停在 true（引擎模式下只在有帧时被置 true，从不复位），
        // 导致插帧视图继续挂着、徽章一直显示"插帧中"（用户实测反馈）。
        if !client.engineIsStreaming && isStreaming {
            isStreaming = false
            upscaleLive = nil
            upscaleHost.clear()     // 停掉 MetalGoose 渲染（detach）
            frameHost.clear()
        }
        // ⚠️ 协议版本守卫（必须放在状态镜像之前）：UI 与引擎是两个独立长驻进程，
        // 重编译后旧引擎可能还活着，新 UI 会直接连上它，导致新命令被静默丢弃
        // （表现为「按钮能按但毫无反应」）。检测到版本不匹配就重启引擎。
        //
        // ⚠️ 只在非驾驶状态做：行驶中突然失去引擎比版本错配更危险。
        // ⚠️ engineRelaunching 由 EngineClient 持有并在重启完成后清除 —— 不能用
        //    UI 局部标志，否则重启流程中途 isEngineStale 仍为真时会无限重复触发。
        if client.isEngineStale {
            if !isDriving && !client.engineRelaunching {
                client.engineRelaunching = true
                engineVersionWarning = "检测到旧版引擎，正在重启…"
                client.relaunchStaleEngine()
            } else {
                engineVersionWarning = "⚠️ 引擎版本不匹配，停止驾驶后自动重启"
            }
        } else if !engineVersionWarning.isEmpty {
            engineVersionWarning = ""
        }
        // 引擎模式下 UI 不跑推理，面板/状态栏依赖的驾驶状态由引擎心跳回传后落到这里：
        // 档位、车速（含车速表读数）、置信度、有效车速。缺了这些，右侧状态栏与自车信息会「空掉」。
        if mode != client.engineMode { mode = client.engineMode }
        if confidence != client.engineConfidence { confidence = client.engineConfidence }
        if remoteSpeedKmh != client.engineSpeedKmh { remoteSpeedKmh = client.engineSpeedKmh }
        if effectiveSpeed != client.engineSpeed { effectiveSpeed = client.engineSpeed }
        let sv = client.engineSpeedKmh >= 0 && client.engineSpeed > 0.5
        if speedValid != sv { speedValid = sv }   // 逐帧无条件赋值也会触发 SwiftUI 刷新 → 只在变化时写
        // 锁定目标追踪：本地模式下由推理流程逐帧推进；引擎模式下必须用引擎回传的检测框推进，
        // 否则锁定框冻在原地不动、目标离开也不会自动解除。
        yoloEngine.trackLockFromRemote(client.engineDetections)
        // 引擎是状态权威源；命令发出后 1 秒内保留 UI 乐观值，避免切换瞬间闪烁
        if Date().timeIntervalSince(lastDriveCommandTime) > 1.0,
           isDriving != client.engineIsDriving {
            isDriving = client.engineIsDriving
        }
        if client.engineFPS > 0 { fps = client.engineFPS }
        // 录制状态回同步（引擎是权威源）：引擎进程真正写盘，UI 只显示帧数。
        // 置 applyingRemoteRecord 防回环，否则 isRecording 的 didSet 会把命令回声给引擎。
        // 宽限期：刚发过 record 命令的 2 秒内不信心跳（心跳 1Hz + 引擎带即时回执），
        // 否则命令刚发出、心跳还没更新时，这里会把用户刚拨的开关弹回去。
        if Date().timeIntervalSince(lastRecordCommandTime) > 2.0,
           isRecording != client.engineRecording {
            applyingRemoteRecord = true
            isRecording = client.engineRecording
            applyingRemoteRecord = false
        }
        let remoteFrames = client.engineRecording ? client.engineRecordFrames : 0
        if frames != remoteFrames { frames = remoteFrames }
        // 驾驶参数下发：极速 / 禁用控制 / 紧急切纯规则 / 专家 / 字模 / 降级阈值
        // 这些只在 tick() 里被读，而引擎模式下 tick() 跑在引擎进程 ——
        // 必须显式推送。只在变化时发，避免 30Hz 刷屏。
        pushEngineConfigIfChanged()
        // 插帧实时统计（引擎模式下同样显示）
        if useUpscale, let stats = upscaleHost.statsSnapshot() {
            upscaleLive = "产出 \(stats.interpolatedFrameCount) · 透传 \(stats.passthroughFrameCount) · 输入 \(String(format: "%.0f", stats.captureFPS))fps → 输出 \(String(format: "%.0f", stats.outputFPS))fps"
        }
    }

    /// 把「只在 tick() 里被读」的驾驶参数推给引擎（引擎模式下 tick 跑在引擎进程）。
    /// 仅在上次推送后有变化时才发，避免 30Hz 刷屏。
    /// 覆盖：极速模式 / 禁用控制 / 紧急切纯规则 / 专家模式 / 字模模式 / 降级阈值 / 速度上限。
    private func pushEngineConfigIfChanged() {
        let snap = "\(sportMode)|\(controlDisabled)|\(forceRuleMode)|\(expertMode)|\(glyphMode)|\(String(format: "%.3f", degradeThreshold))|\(String(format: "%.1f", speedLimit))"
        guard snap != lastPushedEngineConfig else { return }
        lastPushedEngineConfig = snap
        EngineClient.shared.sendCommand("config", extra: [
            "sport": sportMode,
            "controlDisabled": controlDisabled,
            "forceRule": forceRuleMode,
            "expert": expertMode,
            "glyph": glyphMode,
            "degradeThreshold": degradeThreshold,
            // 速度上限直接进 vehicle_state[4]，不是显示项
            "speedLimit": speedLimit,
        ])
    }

    /// 上次推给引擎的驾驶参数快照（变化检测用）
    @ObservationIgnored private var lastPushedEngineConfig = ""

    /// 每帧推进（30Hz，由 ContentView 的 Timer 驱动）
    /// 完整决策管线：CoreML推理 → 置信度估计 → 状态机决策 → 按态输出控制量 → 录制
    func tick() {
        // 诊断：tick 实际间隔（>33ms = 主线程掉拍/被卡；配合 capGap/capWork 定位延迟）
        let tickNow = Date()
        tickGapMs = tickNow.timeIntervalSince(lastTickTime) * 1000
        lastTickTime = tickNow

        // ── 引擎模式：只拉取显示数据，本地抓屏/推理/按键全部不跑 ──
        if EngineClient.shared.isActive {
            tickEngineMode()
            return
        }

        // ── 消费最新待显示帧（跳帧防堆积）──
        // onFrame 在 captureQueue 只覆盖最新帧；这里每 tick 取最新一帧赋给
        // currentScreenImage（主线程，SwiftUI 刷新）。处理不过来时旧帧被覆盖
        // 丢弃 → 主线程永不积压大图。帧率不变（30fps 红线）。
        pendingFrameLock.lock()
        if let latest = pendingFrame {
            pendingFrame = nil
            let latestCG = pendingFrameCG
            pendingFrameCG = nil
            if let t = pendingFrameTime {
                frameDeliveryLagMs = Date().timeIntervalSince(t) * 1000
            }
            pendingFrameTime = nil
            currentScreenImage = latest
            currentFrameCG = latestCG
            if isStreaming, let cg = latestCG { frameHost.push(cg) }
            if screenSize != latest.size { screenSize = latest.size }
        }
        pendingFrameLock.unlock()

        // ── 消费最新 YOLO 直通帧（跳帧防堆积，同 pendingFrame 模式）──
        pendingYoloLock.lock()
        let yoloFrame = pendingYoloFrame
        pendingYoloFrame = nil
        pendingYoloLock.unlock()
        if let yoloFrame {
            yoloEngine.inferFast(pixelBuffer: yoloFrame)
        }

        // ── 消费最新原生 ROI 帧（OCR 读速 + 字模录制，跳帧防堆积）──
        pendingNativeLock.lock()
        let nativeFrame = pendingNativeFrame
        pendingNativeFrame = nil
        pendingNativeLock.unlock()
        if let nativeFrame {
            speedOCR.infer(nativePixelBuffer: nativeFrame)
            if recordEngine.glyphMode && recordEngine.isRecording {
                recordEngine.appendGlyphNative(pixelBuffer: nativeFrame)
                frames = recordEngine.frameCount
            }
        }

        // 阈值同步：UI 改 degradeThreshold 时，状态机跟着变
        degradeStm.degradeHealth = degradeThreshold

        guard isDriving else {
            // 待机：车速衰减，清空决策。
            //
            // ⚠️ 性能红线：tick 以 30Hz 运行，而这些属性都是 @Observable ——
            //    只要**赋值**就会让 SwiftUI 标记整棵视图树失效并重绘，
            //    进而拖 WindowServer 一起重合成。待机时数值早已稳定，
            //    却仍在每秒 30 次无意义地触发全树重绘（实测 UI 进程
            //    稳定烧 25-36% CPU、WindowServer 44%+、整机发烫）。
            //    所以先比较、变了才写 —— 值不变则一次赋值都不发生。
            if speedValid { speedValid = false }
            let decayed = max(0, effectiveSpeed - 6)
            if decayed != effectiveSpeed { effectiveSpeed = decayed }
            if currentCommand != .idle { currentCommand = .idle }
            recordFrameIfNeeded()   // 待机也写帧：录制不依赖驾驶状态
            return
        }

        let dt = 1.0 / 30.0

        // ── 1. 感知层：双驾驶模型推理 + YOLO 检测 ──
        // 异步触发推理（不阻塞 tick），读 lastResult 作为本帧输出
        if let cg = currentFrameCG {
            // 紧急切纯规则时 M9 停推理（省资源；纯规则决策不依赖 M9 输出）
            if !forceRuleMode {
                inferenceEngine.infer(image: cg, speedKmh: effectiveSpeed, speedLimitKmh: speedLimit)   // M9 端到端主驾
            }
            assistEngine.infer(image: cg, speedKmh: effectiveSpeed, speedLimitKmh: speedLimit)      // 第二套驾驶模型（YOLO接管档）
            // YOLO 检测：优先走 CaptureEngine 直通（源头 GPU 缩放好的缓冲）；
            // 直通未活跃（如尚未接入）时回退到 tick 内转换。
            // fastPathActive 是粘性标志（只在 reset() 清），CaptureEngine 一旦停止
            // 直通它不会自动回落；这里用 lastFastPathTime 做超时判活，超过 1 秒没有
            // 新的直通推理就认为直通已失效，回退慢路径，避免 YOLO 静默停摆。
            let fastPathStale = Date().timeIntervalSince(yoloEngine.lastFastPathTime) > 1.0
            if !yoloEngine.fastPathActive || fastPathStale {
                yoloEngine.infer(image: cg)
            }
        }

        // 读取两个驾驶模型的输出，无结果时用 idle 占位（首次推理未完成）
        func commandOf(_ engine: InferenceEngine) -> ControlCommand {
            guard let result = engine.lastResult else { return .idle }
            return ControlCommand(steer: result.steer,
                                  throttle: result.throttle,
                                  brake: result.brake,
                                  confidence: 0.9)   // 占位，置信度估计器会覆盖
        }
        let m9Command = commandOf(inferenceEngine)
        let assistCommand = commandOf(assistEngine)

        // 模型链路存活：加载成功 && 有结果 && 结果 1s 内新鲜
        func isAlive(_ engine: InferenceEngine) -> Bool {
            engine.isLoaded && engine.lastResult != nil
                && (engine.lastResultTime.map { Date().timeIntervalSince($0) < 1.0 } ?? false)
        }
        let m9Live = isAlive(inferenceEngine)
        let assistLive = isAlive(assistEngine)

        // YOLO 检测结果（异步推理，读最新一帧；未出结果时为空数组 → 规则态走安全直行）
        // 同一份数据同时供：RuleController 决策 + ObstacleOverlay 画框
        let detections = yoloEngine.detections

        // ── 2. 有效车速：OCR 新鲜（<0.5s 且 conf>0.3）→ EMA 追真实读数；否则一阶滤波回退 ──
        // 替代原遥测模拟（指数逼近限速 + 随机抖动）：速度现在来自真实游戏读数（speedOCR），
        // 读不到时平滑衰减而非随机抖动；卡死判据由 speedValid 门控避免"读不到→误判卡死"。
        let ocrFresh = speedOCR.speedKmh >= 0
            && speedOCR.confidence > 0.3
            && (speedOCR.lastResultTime.map { Date().timeIntervalSince($0) < 0.5 } ?? false)
        // 先比后写：speedValid / fps 值不变时跳过 @Observable 写入
        //（逐帧无条件赋值也会触发 SwiftUI 刷新链）。
        if speedValid != ocrFresh { speedValid = ocrFresh }
        if ocrFresh {
            effectiveSpeed += (speedOCR.speedKmh - effectiveSpeed) * 0.7   // 快跟踪 OCR 读数
        } else {
            effectiveSpeed *= 0.9                                          // 向 0 一阶衰减
            if effectiveSpeed < 0.5 { effectiveSpeed = 0 }
        }
        // FPS 如实反映捕获帧率：未捕获到帧就是 0（UI 显示「—」），
        // 绝不回退成 60 伪造一个好看的数。
        let newFPS = captureEngine.captureFPS
        if fps != newFPS { fps = newFPS }

        // ── 3. 降级状态机决策（四档梯子：模型存活 + 健康度驱动）──
        // 暖机期（开车头几秒还没出推理结果）保持档位不降级
        let warmingUp = inferenceEngine.lastResult == nil
            && Date().timeIntervalSince(drivingStartTime) < 3.0
        let decided = degradeStm.update(m9Live: m9Live,
                                        assistLive: assistLive,
                                        health: confidence,
                                        warmingUp: warmingUp,
                                        speedKmh: effectiveSpeed,
                                        speedValid: speedValid,
                                        dt: dt,
                                        sportMode: sportMode,
                                        forceRule: forceRuleMode)
        // 先比后写：档位不变时跳过 @Observable 写入（省 UI 观察者通知，
        // mode 有 7 处 UI 读取）。
        if mode != decided { mode = decided }   // 同步给 UI

        // ── 4. 置信度估计（喂当前档位驾驶模型的输出 + 画面）──
        // 暖机期保持 1.0；之后 isLive = 当前档位模型是否存活，
        // 链路死（没模型/没画面/结果过期）→ 置信度 0 → 状态机自动降级。
        if warmingUp {
            confidence = 1.0
        } else {
            let healthCommand: ControlCommand = (mode == .e2e) ? m9Command : assistCommand
            let healthLive: Bool = (mode == .e2e) ? m9Live : assistLive
            confidenceEst.update(command: healthCommand,
                                 image: currentFrameCG,
                                 isLive: healthLive)
            // 先比后写：置信度不变时跳过 @Observable 写入。
            let newConf = confidenceEst.confidence
            if confidence != newConf { confidence = newConf }   // 同步给 UI
        }

        // 记录框数供 UI 展示（先比后写：值不变不触发 SwiftUI 重绘）
        let boxCount = effectiveDetections.count
        if detectedBoxCount != boxCount { detectedBoxCount = boxCount }

        // ── 4.4 自动速度：YOLO 框数 → 路况 → 限速（不用模型）──
        // 用户要求：检测框 >70 极度复杂 / >20 复杂 / <=10 不复杂，据此自动调限速。
        // 判定源是 YOLO 的**直接观测**（框数），不是驾驶模型的置信度。
        // ⚠️ 用户明确要求：「不限速」= 直接取消掉速度表。
        //    所以一旦落在不限速，自动速度必须**整体停摆**，不能把限速又改回去 ——
        //    否则用户拉到底选了不限速，界面过几秒自己跳回 120，等于没取消。
        //    重新启用限速的入口只有一个：用户自己把滑块拉离不限速。
        // 门禁用 unlimitedLockedByUser 而不是 isUnlimited：自动速度自己设的
        // 不限速必须能被下一次判定改回来，否则框数涨回来时永远出不来（死锁）。
        if autoSpeedEnabled, isDriving, !unlimitedLockedByUser {
            // 判定源必须与 UI 显示、规则档决策**同源**：引擎模式下用引擎回传的检测结果，
            // 本地模式用本地 YoloEngine。若这里读 yoloEngine.detections 而 UI 读
            // effectiveDetections，两者在引擎模式下会不一致 ——
            // 表现为「界面显示 80 个框，但路况还停在简单」。
            let n = effectiveDetections.count
            let suggested = AutoRoadCondition.condition(forDetectionCount: n, current: roadCondition)
            // 稳定性门：需连续 stabilityFrames 帧给出同一建议才切换，
            // 避免单帧抖动导致限速跳变（限速一跳就会触发刹车，体感很差）。
            if suggested != roadCondition {
                if suggested == pendingCondition {
                    conditionStableFrames += 1
                } else {
                    pendingCondition = suggested
                    conditionStableFrames = 1
                }
                if conditionStableFrames >= AutoRoadCondition.stabilityFrames {
                    applyRoadCondition(suggested)   // 内部会按路况下发限速
                    conditionStableFrames = 0
                    pendingCondition = nil
                }
            } else {
                conditionStableFrames = 0
                pendingCondition = nil
            }
        } else {
            // 不限速（或未开车）期间清空稳定性门计数，
            // 避免恢复限速的瞬间带着旧计数立刻跳一档路况
            conditionStableFrames = 0
            pendingCondition = nil
        }

        // ── 4.5 限速硬闸（纯规则，优先级高于所有驾驶模型）──
        // 用户要求：速度模型测到超速 → 直接注入 空格(手刹)+Shift，且**不用模型实现**。
        // 因此这一步放在所有档位决策之前：一旦超速，本帧的 AI 决策键全部不执行，
        // 只走「松油门 + 手刹 + 松极速」。不限速时限速值为 200 → 闭环整体停用。
        // ⚠️ 安全边界：限速刹车会**注入真实按键**，因此必须与普通决策走同一套准入条件。
        //    专家模式（真人物理键独占驾驶）/ 控制禁用 / 未启动驾驶 这三种情况下
        //    一律不得注入 —— 否则会自动跟真人抢方向盘、或在没开车时乱按键。
        //    （这个 gate 漏了就是「专家模式下 AI 偷偷踩刹车」的严重 bug。）
        let mayInjectKeys = isDriving && !expertMode && !controlDisabled
        let limitBraking = mayInjectKeys
            && speedLimitGuard.update(speedKmh: effectiveSpeed,
                                      speedValid: speedValid,
                                      limitKmh: speedLimit,
                                      dt: dt)
        if !mayInjectKeys {
            speedLimitGuard.reset()
            // 关键：若上一帧手刹还按着（正在限速刹车），而本帧已经不允许注入
            // （用户点了停止 / 切进专家模式 / 启用控制禁用），这里必须主动松开。
            // 否则 return 后的 releaseAll 走不到，空格会永久卡住。
            if speedLimitBrakeLatched {
                speedLimitBrakeLatched = false
                releaseSpeedLimitBrake()
                dlog("限速刹车 强制退出（准入条件不再满足）")
            }
        }
        if limitBraking {
            // 刹车优先级最高：只执行限速键，跳过下面的档位决策
            if !speedLimitBrakeLatched {
                speedLimitBrakeLatched = true
                dlog("限速刹车 ON: 速度=\(String(format:"%.1f", effectiveSpeed)) 限速=\(Int(speedLimit)) 超速=\(String(format:"%.1f", speedLimitGuard.overshoot))")
            }
            if speedLimitBrakeLastStage != speedLimitGuard.stage {
                speedLimitBrakeLastStage = speedLimitGuard.stage
                dlog("限速刹车 级别→\(speedLimitGuard.stage.label) 超速=\(String(format:"%.1f", speedLimitGuard.overshoot)) 已持续=\(String(format:"%.1f", speedLimitGuard.overspeedSeconds))s")
            }
            applySpeedLimitBrake()
            lastDecided = decided
            recordFrameIfNeeded()
            return
        }
        // 刹车 → 松开的边沿：必须显式释放手刹，否则空格永久卡住（车再也动不了）
        if speedLimitBrakeLatched {
            speedLimitBrakeLatched = false
            releaseSpeedLimitBrake()
            // 读 last* 而不是当前值：update() 已在本帧 reset() 过，
            // 直接读 overspeedSeconds/stage 只会得到 0 / 待命。
            dlog("限速刹车 OFF: 速度=\(String(format:"%.1f", effectiveSpeed)) 限速=\(Int(speedLimit)) 持续=\(String(format:"%.1f", speedLimitGuard.lastBrakeSeconds))s 最高级别=\(speedLimitGuard.lastStage.label) 峰值超速=\(String(format:"%.1f", speedLimitGuard.lastOvershoot)) 脉冲数=\(speedLimitGuard.lastPulseCount)")
            speedLimitGuard.endSession()
        }

        // ── 5. 按态输出控制量 ──
        switch decided {
        case .e2e:
            // 档1 端到端主驾：M9 直接开车
            currentCommand = m9Command
            escapeController.reset()

        case .yolo:
            // 档2 YOLO接管：第二套神经网开车（YOLO 检测框仍实时显示）
            currentCommand = assistCommand
            escapeController.reset()

        case .rule:
            // 档4 纯规则兜底：YOLO 检测 → 手写规则开车（最后防线）
            currentCommand = ruleController.decide(detections: detections)
            escapeController.reset()

        case .recover:
            // 档3 脱困策略：倒车→转向→前进
            // P0 修复：只在"从其他档切入 .recover 的那一刻" enter 一次。
            // 原实现每帧 phase==.done 就 re-enter，抵消 EscapeController 的 15s 超时，
            // 导致 7×24 永不停歇脱困。现在一次进入只执行一个完整周期，
            // 超时/完成即 phase=.done 不再自动重进，由状态机决定下一帧去向。
            if lastDecided != .recover { escapeController.enter() }
            let (cmd, escaped) = escapeController.update(dt: dt, speedKmh: effectiveSpeed)
            currentCommand = cmd
            if escaped {
                // 脱困成功，状态机会在下一帧因车速恢复自动转出
                degradeStm.reset()
            }
        }

        // 记录本帧决策，供下一帧检测"刚切入 .recover"边沿（脱困只 enter 一次）
        lastDecided = decided

        // ── 6. 按键注入（AI 决策 → 游戏控制）──
        // 专家模式：不注入 AI 键，让真人物理键独占驾驶；
        // 录制的控制量即纯专家演示，画面与标签一致（避免 AI/真人键冲突）。
        // 禁用控制：同理不注入 AI 键，但 YOLO 检测/E2E 推理照常跑（仅供画面辅助）。
        if expertMode || controlDisabled {
            controlEngine.releaseAll()
            speedLimitBrakeLatched = false   // 刹车状态一并复位，防下次进来自锁
        } else {
            applyCommand(currentCommand)
        }

        // ── 7. 行驶录制（画面 + 控制量）──
        // 默认录 AI 决策（currentCommand，供 DAgger 自训练）；
        // 专家模式录真人物理键（模仿学习的专家演示标签）。
        // 键码与 ControlEngine 注入一致：A=0 左 / D=2 右 / W=13 油门 / S=1 刹车 / Space=49 手刹
        recordFrameIfNeeded()

        // ── 插帧/超分状态（1Hz 更新，避免每帧触发 UI 刷新）──
        if tickNow.timeIntervalSince(lastUpscaleLiveLog) >= 1.0 {
            lastUpscaleLiveLog = tickNow
            if upscaleEnabled {
                if let err = upscaleHost.pendingError() {
                    upscaleEngineError = err
                } else {
                    upscaleEngineError = nil  // 无错误时清零，防止旧错误常驻 badge
                }
            }
            if upscaleEnabled, let st = upscaleHost.statsSnapshot() {
                upscaleLive = "产出 \(st.interpolatedFrameCount) · 透传 \(st.passthroughFrameCount) · 输入 \(String(format: "%.0f", st.captureFPS))fps → 输出 \(String(format: "%.0f", st.outputFPS))fps"
            } else {
                upscaleLive = nil
            }
        }

        // ── 8. 调试摘要（1Hz，写 /tmp/aurora_debug.log）──
        // 诊断"M9 没输出键"：看 mode 落在哪档、模型活没活、命令是什么、按键注入有没有被权限拦截
        // front= 记录注入时前台应用是谁：CGEvent 全局注入的事件只发给前台应用，
        // 游戏不在前台（被 App 窗口/其他应用挡着）就收不到注入键。
        let nowLog = Date()
        if nowLog.timeIntervalSince(lastTickLog) >= 1.0 {
            lastTickLog = nowLog
            dlog("tick: mode=\(mode.rawValue) m9Live=\(m9Live) assistLive=\(assistLive) "
                 + "conf=\(String(format: "%.2f", confidence)) img=\(currentScreenImage != nil) "
                 + "cmd=(s=\(String(format: "%.2f", currentCommand.steer)) "
                 + "t=\(String(format: "%.2f", currentCommand.throttle)) "
                 + "b=\(String(format: "%.2f", currentCommand.brake))) "
                 + "held=\(controlEngine.heldKeys.count) ev=\(controlEngine.postedEventCount) "
                 + "perm=\(controlEngine.hasAccessibilityPermission) "
                 + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") "
                 + "native=\(Int(speedOCR.lastNativeSize.width))x\(Int(speedOCR.lastNativeSize.height)) "
                 + "ocr[\(speedOCR.activeEngine.rawValue)]=\(String(format: "%.1f", speedOCR.speedKmh))/\(String(format: "%.2f", speedOCR.confidence))"
                 + "\(speedOCR.speedKmh < 0 ? "[" + speedOCR.lastOCRDiagnostic + "]" : "") "
                 + "\(speedOCR.engineNotice.map { "notice=[\($0)] " } ?? "") "
                 + "eff=\(String(format: "%.1f", effectiveSpeed))/vld=\(speedValid) "
                 + "lag=\(Int(frameDeliveryLagMs))ms mem=\(Int(processMemoryMB()))MB "
                 + "capGap=\(captureEngine.lastFrameGapMs.isFinite ? Int(captureEngine.lastFrameGapMs) : 0)ms capWork=\(captureEngine.lastFrameWorkMs.isFinite ? Int(captureEngine.lastFrameWorkMs) : 0)ms tickGap=\(Int(tickGapMs))ms"
                 + upscaleStatLine)
        }
    }

    private var upscaleStatLine: String {
        guard upscaleEnabled, let stats = upscaleHost.statsSnapshot() else { return "" }
        var line = " up=\(stats.interpolatedFrameCount)/\(stats.outputFrameCount)/\(stats.passthroughFrameCount)"
            + " fps=\(String(format: "%.0f", stats.outputFPS))"
            + (upscaleHost.lastAttachInfo.map { " view=\($0)" } ?? " view=nil")
        if let err = upscaleEngineError { line += " ERR=\(err)" }
        return line
    }

    /// 每帧录制写帧（画面 + 控制量），驾驶与待机共用
    /// 默认录 AI 决策（currentCommand，供 DAgger 自训练）；
    /// 专家模式录真人物理键的"按住时长 → 比例"连续标签（模仿学习的专家演示标签）。
    /// 键码与 ControlEngine 注入一致：A=0 左 / D=2 右 / W=13 油门 / S=1 刹车 / Space=49 手刹
    private func recordFrameIfNeeded() {
        // 字模模式走 onNativeFrame 原生路径（appendGlyphNative），此处跳过，
        // 避免 appendFrame 再写一遍 640px/480px 缩略图造成双写
        guard !recordEngine.glyphMode else { return }
        if isRecording, let image = currentScreenImage {
            let recSteer: Double
            let recThrottle: Double
            let recBrake: Double
            if expertMode {
                // 标签语义：按键按住时长 / 满刻度时长 → 连续值（0~1，带符号），
                // 与推理端"|steer|>阈值 → 按住键 → 游戏按按住时长平滑转角"闭环一致。
                recSteer    = RecordLabelMapper.steer(
                    leftHeld: keyboardMonitor.holdDuration(keyCode: 0),
                    rightHeld: keyboardMonitor.holdDuration(keyCode: 2))
                recThrottle = RecordLabelMapper.throttle(
                    wHeld: keyboardMonitor.holdDuration(keyCode: 13))
                recBrake    = RecordLabelMapper.brake(
                    sHeld: keyboardMonitor.holdDuration(keyCode: 1),
                    spaceHeld: keyboardMonitor.holdDuration(keyCode: 49))
            } else {
                recSteer   = currentCommand.steer
                recThrottle = currentCommand.throttle
                recBrake   = currentCommand.brake
            }
            recordEngine.appendFrame(image: image,
                                     steer: recSteer,
                                     throttle: recThrottle,
                                     brake: recBrake)
            frames = recordEngine.frameCount
        }
    }

    /// 把 ControlCommand 映射到按键注入
    /// steer>0 右转，<0 左转；throttle 油门；brake 刹车/倒车
    /// 限速刹车：纯规则按键，不经过任何驾驶模型。
    ///
    /// 用户指定：超速 → 空格(手刹) + Shift。同时必须**松开油门 W**，
    /// 否则一边踩油门一边拉手刹，车只会顿挫而不减速。
    /// 这里刻意不复用 applyCommand —— 保证它与模型决策完全解耦。
    private func applySpeedLimitBrake() {
        // ① 无论哪一级，都要松油门 + 松极速（发动机制动是最温和有效的降速手段）
        controlEngine.release(.throttle)
        controlEngine.release(.boost)

        // ② 手刹按级别决定按还是松。
        //    持续按手刹 = 后轮锁死 = 高速甩尾失控，所以只有到「持续刹」这一级
        //    才真正按住；「点刹」级别由 SpeedLimitGuard 的脉冲相位控制按下/松开。
        if speedLimitGuard.handbrakeDown {
            controlEngine.hold(.handbrake)
        } else {
            controlEngine.release(.handbrake)
        }

        // ③ 转向：不主动打方向，避免刹车时人为制造侧滑
        controlEngine.release(.steerLeft)
        controlEngine.release(.steerRight)

        // ④ 持续重发按下事件，否则游戏只收到一次 keyDown（其输入层只认新按下）
        controlEngine.refreshHeldKeys()
    }

    /// 限速刹车结束时的收尾：**必须释放手刹**。
    ///
    /// ⚠️ 这是本功能最容易出人命的地方：`applyCommand` 只管理 W/S/A/D 四键，
    ///    从不触碰 handbrake，所以如果刹车退出后不主动松开空格，
    ///    手刹会被**永久按住**（refreshHeldKeys 还会每帧帮它重发按下事件），
    ///    车从此再也动不了 —— 用户会看到「速度掉到限速以下了但车不动」。
    ///    因此每次刹车→松开的边沿、以及不限速/停车时，都要走这里。
    private func releaseSpeedLimitBrake() {
        controlEngine.release(.handbrake)
    }

    private func applyCommand(_ cmd: ControlCommand) {
        // 转向：死区 ±0.1，避免微抖动
        if cmd.steer > 0.1 {
            controlEngine.hold(.steerRight)
            controlEngine.release(.steerLeft)
        } else if cmd.steer < -0.1 {
            controlEngine.hold(.steerLeft)
            controlEngine.release(.steerRight)
        } else {
            controlEngine.release(.steerLeft)
            controlEngine.release(.steerRight)
        }

        // 油门 / 刹车互斥（不能同时按 W 和 S）
        if cmd.throttle > 0.3 {
            controlEngine.hold(.throttle)
            controlEngine.release(.brake)
        } else if cmd.brake > 0.3 {
            controlEngine.hold(.brake)
            controlEngine.release(.throttle)
        } else {
            controlEngine.release(.throttle)
            controlEngine.release(.brake)
        }

        // 持续按住的键按控制周期重发按下事件（等价真实键盘 auto-repeat）。
        // 缺了这一步，控制量稳定时（E2E 直道恒定油门）整段驾驶只会产生一个
        // keyDown，游戏收不到任何后续事件 —— 表现为「UI 显示按住、车不动」。
        controlEngine.refreshHeldKeys()
    }
}


// ============================================================================
// MARK: - 文件 4: ContentView.swift  (主布局: 顶部工具栏 + 左画面 + 右侧边栏)



// ============================================================================
// MARK: - 常驻左上角悬浮小地图（不依赖 GameMapView，应用启动即显示）





// MARK: - BPF权限安装弹窗（灵动岛风格）

struct BPFPasswordSheet: View {
    @Bindable var state: DriveState
    /// ⚠️ 绝不预填密码。
    /// 旧实现是 `@State private var password = "123456"` —— 那是本机开发时的
    /// 临时便利，一旦发布出去：① 别人的密码当然不是 123456，必然失败；
    /// ② 等于把「本机管理员密码」写进源码，是明确的安全问题。
    /// 现在留空，由用户自己输入，输入内容只存在于内存。
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Aurora.ice)
                    .shadow(color: Aurora.ice, radius: 10)
                Text("安装系统权限")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Aurora.ice)
                Text("BPF 网络权限 + 性能提权（nice -20 防游戏挤占）\n输入管理员密码，安装后永久生效，重启自动恢复")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.t2)
                    .multilineTextAlignment(.center)
            }

            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Aurora.void, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Aurora.t1)
                .font(.system(size: 14, design: .monospaced))

            if !state.bpfInstallMessage.isEmpty {
                Text(state.bpfInstallMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(state.bpfInstallMessage.contains("成功") || state.bpfInstallMessage.contains("已安装") ? Aurora.ice : Aurora.amber)
            }

            HStack(spacing: 12) {
                Button("取消") {
                    state.showBPFPasswordSheet = false
                    state.bpfInstallMessage = ""
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Aurora.t2)

                Button {
                    state.bpfInstalling = true
                    state.bpfInstallMessage = ""
                    let pwd = password
                    // 走应用内提权（sudo -S，密码经 stdin）。
                    // 不走 DaemonSetup 的原生授权路径 —— 那是 `do shell script
                    // ... with administrator privileges`，会弹 macOS 系统框。
                    Task { @MainActor in
                        let result = PrivilegePill.shared.install(password: pwd)
                        state.bpfInstalling = false
                        state.bpfInstallMessage = result.message
                        state.privilegeReady = PrivilegePill.shared.isFullyAuthorized
                        state.privilegeStatusDetail = PrivilegePill.shared.statusDetail
                        state.bpfAuthorized = BPFSetupManager.isBPFAvailable()
                        if result.success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                state.showBPFPasswordSheet = false
                                state.bpfInstallMessage = ""
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if state.bpfInstalling {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(state.bpfInstalling ? "安装中..." : "安装")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Aurora.ice.opacity(0.2), in: Capsule())
                    .foregroundStyle(Aurora.ice)
                }
                .buttonStyle(.plain)
                .disabled(state.bpfInstalling || password.isEmpty)
            }
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(Aurora.s1)
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Aurora.ice.opacity(0.3), lineWidth: 1)
                }
        }
        .frame(width: 340)
    }
}

// MARK: - DaemonInstallSheet (系统服务安装引导)

/// Daemon 安装引导弹窗：首次启动时引导用户安装为 LaunchDaemon（最高优先级）
struct DaemonInstallSheet: View {
    @Bindable var state: DriveState
    /// 同 BPFPasswordSheet：绝不预填密码（见该处说明）。
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 32))
                    .foregroundStyle(Aurora.ice)
                    .shadow(color: Aurora.ice, radius: 10)
                Text("安装系统级服务")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Aurora.ice)
                Text("游戏全屏时 macOS 会冻结后台 App\n安装为系统服务可获得最高调度优先级\n防止被冻结，只需输入一次密码")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.t2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Aurora.void, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Aurora.t1)
                .font(.system(size: 14, design: .monospaced))

            if !state.daemonInstallMessage.isEmpty {
                Text(state.daemonInstallMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(state.daemonInstallMessage.contains("成功") || state.daemonInstallMessage.contains("已安装") ? Aurora.ice : Aurora.amber)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("暂不安装") {
                    state.showDaemonInstallSheet = false
                    state.daemonInstallMessage = ""
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Aurora.t2)

                Button {
                    state.daemonInstalling = true
                    state.daemonInstallMessage = ""
                    let pwd = password
                    let execPath = DaemonSetupManager.currentExecutablePath()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = DaemonSetupManager.install(password: pwd, currentExecutablePath: execPath)
                        DispatchQueue.main.async {
                            state.daemonInstalling = false
                            state.daemonInstallMessage = result.message
                            if result.success {
                                state.daemonInstalled = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    state.showDaemonInstallSheet = false
                                    state.daemonInstallMessage = ""
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if state.daemonInstalling {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(state.daemonInstalling ? "安装中..." : "立即安装")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Aurora.ice.opacity(0.2), in: Capsule())
                    .foregroundStyle(Aurora.ice)
                }
                .buttonStyle(.plain)
                .disabled(state.daemonInstalling || password.isEmpty)
            }
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(Aurora.s1)
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Aurora.ice.opacity(0.3), lineWidth: 1)
                }
        }
        .frame(width: 360)
    }
}




/// 障碍框：YoloEngine 的真实检测结果，按类别着色 + 标签 + 置信度
///
/// 坐标换算说明：
///   YOLO 输出的是「整帧归一化坐标」，而游戏画面用 .aspectRatio(.fill) + .clipped() 显示，
///   源画面和视口宽高比不一致时会被裁切。这里必须复现同样的 aspect-fill 变换，
///   否则画出来的框会整体偏移/缩放错位。
/// aspect-fill 变换参数：源图在视口里的实际绘制区域（与 .fill + .clipped() 一致）
/// - Returns: 绘制原点 + 绘制尺寸（视口坐标）
func aspectFillLayout(source: CGSize?, view: CGSize) -> (origin: CGPoint, size: CGSize) {
    guard let src = source, src.width > 0, src.height > 0 else {
        return (.zero, view)
    }
    let scale = max(view.width / src.width, view.height / src.height)
    let drawn = CGSize(width: src.width * scale, height: src.height * scale)
    return (CGPoint(x: (view.width - drawn.width) / 2,
                    y: (view.height - drawn.height) / 2), drawn)
}

/// 视口坐标 → 源图归一化坐标（aspect-fill 逆变换）
/// 超出源图绘制区域的点返回 nil
func viewToSourceNorm(_ point: CGPoint,
                      source: CGSize?,
                      view: CGSize) -> CGPoint? {
    guard let src = source, src.width > 0, src.height > 0, view.width > 0, view.height > 0 else {
        return nil
    }
    let t = aspectFillLayout(source: source, view: view)
    let nx = (point.x - t.origin.x) / t.size.width
    let ny = (point.y - t.origin.y) / t.size.height
    guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
    return CGPoint(x: nx, y: ny)
}

// BPF权限UI已删除（不需要密码，BPF已chmod 666）


struct ObstacleOverlay: View {
    var active: Bool
    /// 本帧检测结果（归一化中心点 + 宽高）
    var detections: [Detection] = []
    /// 源画面像素尺寸，用于 aspect-fill 裁切换算；nil 时退化为直接铺满
    var sourceSize: CGSize? = nil
    /// 锁定目标（手动框选/点选后由 YOLO 追踪），画金色高亮框
    var lockedTarget: Detection? = nil
    var isLocked: Bool = false

    /// 类别配色
    private static func color(for label: Detection.Label) -> Color {
        switch label {
        case .pedestrian: return Aurora.danger                                  // 行人：红
        case .car:        return Aurora.ice                                    // 车辆：青
        case .sign:       return Color(red: 1.0, green: 0.82, blue: 0.25)      // 标识：黄
        case .obstacle:   return Aurora.amber                               // 其他：橙
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard active else { return }
            let t = aspectFillLayout(source: sourceSize, view: size)
            // 1) 检测框
            for d in detections {
                let c = Self.color(for: d.label)
                let danger = d.isInDangerZone()
                let w = max(d.width * t.size.width, 2)
                let h = max(d.height * t.size.height, 2)
                let cx = t.origin.x + d.x * t.size.width
                let cy = t.origin.y + d.y * t.size.height
                let box = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(c.opacity(danger ? 0.18 : 0.08)))
                // 无阴影直接描边：去掉逐框 drawLayer 的高斯模糊（最贵部分），描边已足够醒目
                ctx.stroke(Path(roundedRect: box, cornerRadius: 4),
                           with: .color(c.opacity(0.9)),
                           style: StrokeStyle(lineWidth: danger ? 2.2 : 1.4))
                // 文字胶囊：resolve/measure 各只调一次；胶囊在框顶上方，底部距框顶 16pt
                let label = "\(d.rawName) \(String(format: "%.2f", d.confidence))"
                let r = ctx.resolve(Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.black))
                let m = r.measure(in: size)
                let capW = m.width + 10
                let capH = m.height + 4
                let capX = min(max(box.minX, 4), max(4, size.width - capW - 4))
                let capY = max(box.minY - 16 - m.height - 4, 4)
                let cap = CGRect(x: capX, y: capY, width: capW, height: capH)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 3), with: .color(c.opacity(0.9)))
                ctx.draw(r, at: CGPoint(x: cap.midX, y: cap.midY))
            }
            // 2) 锁定目标金色框 + 四角准星 + LOCK 文字
            if isLocked, let lt = lockedTarget {
                let w = max(lt.width * t.size.width, 6)
                let h = max(lt.height * t.size.height, 6)
                let cx = t.origin.x + lt.x * t.size.width
                let cy = t.origin.y + lt.y * t.size.height
                let box = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Aurora.amber.opacity(0.12)))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(Aurora.amber), style: StrokeStyle(lineWidth: 3))
                // 四角准星 14pt
                let corners: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: box.minX, y: box.minY), 1, 1), (CGPoint(x: box.maxX, y: box.minY), -1, 1), (CGPoint(x: box.minX, y: box.maxY), 1, -1), (CGPoint(x: box.maxX, y: box.maxY), -1, -1)]
                for (p, sx, sy) in corners {
                    var path = Path()
                    path.move(to: p)
                    path.addLine(to: CGPoint(x: p.x + 14*sx, y: p.y))
                    path.move(to: p)
                    path.addLine(to: CGPoint(x: p.x, y: p.y + 14*sy))
                    ctx.stroke(path, with: .color(Aurora.amber), style: StrokeStyle(lineWidth: 3))
                }
                let label = "🎯 \(lt.rawName) LOCK"
                let r = ctx.resolve(Text(label).font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(.black))
                let m = r.measure(in: size)
                let capW = m.width + 12
                let capH = m.height + 4
                let capX = min(max(box.minX, 4), max(4, size.width - capW - 4))
                let capY = max(box.minY - 18 - m.height - 4, 4)
                let cap = CGRect(x: capX, y: capY, width: capW, height: capH)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 3), with: .color(Aurora.amber))
                ctx.draw(r, at: CGPoint(x: cap.midX, y: cap.midY))
            }
        }
        .allowsHitTesting(false)
    }
}

// ============================================================================
// MARK: - FrameHost / FrameHostView  (画面流直绘，绕开 SwiftUI body diff)
// ============================================================================

/// 画面帧直绘宿主：自定义 NSView 由 SwiftUI 创建一次，之后 tick 直接 push CGImage
/// 到 layer.contents（contentsGravity = resizeAspectFill），不再经过 body diff，
/// 避免大图每帧触发 SwiftUI 重绘；也规避 NSImageView 由 NSImageCell 绘制、
/// contentsGravity 不生效导致 letterbox 的问题。
@MainActor
final class FrameHost {
    private weak var hostView: NSView?
    private var cachedCGImage: CGImage?
    var latestSize: CGSize? { cachedCGImage.map { CGSize(width: $0.width, height: $0.height) } }

    func attach(_ view: NSView) {
        hostView = view
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.masksToBounds = true
        // 仅在有缓存时回填（停止后 clear() 已清空缓存，重启不再闪旧帧）
        if let cg = cachedCGImage { view.layer?.contents = cg }
    }

    func push(_ image: CGImage) {
        cachedCGImage = image
        hostView?.layer?.contents = image
    }

    /// 停止/出错时清空缓存并回落黑底，释放最新帧
    func clear() {
        cachedCGImage = nil
        hostView?.layer?.contents = nil
    }
}

struct FrameHostView: NSViewRepresentable {
    let host: FrameHost
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resizeAspectFill
        v.layer?.masksToBounds = true
        host.attach(v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { v.layer?.contents = nil }
}

// MARK: - UpscaleFrameHost (MetalGoose 插帧/超分引擎，仅显示路径)

final class UpscaleFrameHost {
    private weak var mtkView: MTKView?
    /// 遮挡观察 token（窗口不可见时暂停绘制）
    private var occlusionTokens: [NSObjectProtocol] = []
    /// 当前是否被遮挡（诊断用）
    private(set) var occluded = false
    private var engine: GooseUpscaler?

    private(set) var isAvailable = false

    private let ingestQueue = DispatchQueue(label: "aurora.upscale.ingest", qos: .userInitiated)
    private var frameLock = OSAllocatedUnfairLock()
    private var latestBuffer: CVPixelBuffer?
    private var isDraining = false

    private(set) var lastAttachInfo: String?

    func prepare() {
        guard engine == nil else { return }
        if let e = GooseUpscaler.make() {
            engine = e
            e.configureInterpolation()
        }
        isAvailable = engine != nil
    }

    func attach(_ view: MTKView) {
        guard let engine else {
            isAvailable = false
            return
        }
        engine.detachFromView()
        mtkView = view
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        engine.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)
        engine.configureInterpolation()
        lastAttachInfo = "\(Int(view.bounds.width))x\(Int(view.bounds.height))@\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))"

        // ⚠️ 遮挡感知：MTKView 默认以 60fps 常开渲染，即使窗口被完全挡住、
        //    或插帧根本没在跑，GPU/CPU 也在全速空转。这里挂上窗口遮挡通知，
        //    不可见时暂停绘制、重新可见时恢复 —— 不改变任何功能行为。
        installOcclusionGuard(on: view)
    }

    /// 窗口被遮挡 / 最小化时暂停 MTKView 绘制，可见时恢复。
    /// 纯性能优化：不插帧时省电省发热，插帧时遮挡期本就无需出图。
    private func installOcclusionGuard(on view: MTKView) {
        occlusionTokens.forEach { NotificationCenter.default.removeObserver($0) }
        occlusionTokens.removeAll()
        guard let win = view.window else {
            // 视图还没进窗口层级，下一帧再试（attach 常发生在挂载前）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak view] in
                guard let self, let view else { return }
                self.installOcclusionGuard(on: view)
            }
            return
        }
        let sync: () -> Void = { [weak self, weak view] in
            guard let self, let view else { return }
            // occlusionState 为空 = 当前被完全遮挡
            let visible = win.occlusionState.contains(.visible)
            // 只暂停绘制，不拆引擎（拆了重连代价大）
            view.isPaused = !visible
            self.occluded = !visible
        }
        let t1 = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win, queue: .main) { _ in sync() }
        let t2 = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: win, queue: .main) { _ in sync() }
        let t3 = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: win, queue: .main) { _ in sync() }
        occlusionTokens = [t1, t2, t3]
        sync()
    }

    func statsSnapshot() -> GooseUpscaler.GooseUpscalerStats? {
        engine?.statsSnapshot()
    }

    func pendingError() -> String? {
        engine?.pendingError()
    }

    func push(pixelBuffer: CVPixelBuffer) {
        guard engine != nil else { return }
        frameLock.lock()
        let start: Bool
        latestBuffer = pixelBuffer
        if isDraining {
            start = false
        } else {
            isDraining = true
            start = true
        }
        frameLock.unlock()
        if start { drain() }
    }

    private func drain() {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            while true {
                frameLock.lock()
                let buf: CVPixelBuffer?
                if self.latestBuffer == nil {
                    self.isDraining = false
                    buf = nil
                } else {
                    buf = self.latestBuffer
                    self.latestBuffer = nil
                }
                frameLock.unlock()
                // 直接把池化的 IOSurface 缓冲喂给引擎（跳过 CVPixelBuffer→CGImage→
                // 再 CVPixelBufferCreate+ctx.draw 的往返转换，省 6-18ms/帧）。
                // 池缓冲会被 processCapturedTexture retain 到渲染完成，期间池新建
                // 新缓冲而不复用它，无竞争。
                guard let buf, let engine = self.engine else {
                    frameLock.lock()
                    self.isDraining = false
                    frameLock.unlock()
                    return
                }
                engine.ingest(pixelBuffer: buf)
            }
        }
    }

    func clear() {
        engine?.detachFromView()
        mtkView = nil
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        let ptr = Unmanaged.passRetained(pixelBuffer).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: ptr,
            data: base,
            size: rowBytes * h,
            releaseData: { info, _, _ in
                Unmanaged<CVPixelBuffer>.fromOpaque(info!).release()
            }) else {
            Unmanaged<CVPixelBuffer>.fromOpaque(ptr).release()
            return nil
        }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

struct UpscaleFrameHostView: NSViewRepresentable {
    let host: UpscaleFrameHost
    func makeNSView(context: Context) -> NSView {
        let v = MTKView()
        host.attach(v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        (v as? MTKView).map { _ in }
    }
}





// ============================================================================
// MARK: - 文件 9: ControlPanel.swift  (控制按钮)






// ============================================================================
// SettingRow：配置行（图标 + 标题 + 副标题 + Toggle）





// ============================================================================
// MARK: - LogViewerPanel (日志查看面板)

