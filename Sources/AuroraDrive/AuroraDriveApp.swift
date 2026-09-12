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
import Darwin   // mach_task_basic_info：诊断进程内存占用（验证"积压→内存涨"根因）
import CoreVideo  // CVPixelBuffer：YOLO 直通帧跳帧缓冲
import MetalKit   // MTKView：MetalGoose 插帧渲染承载
import os
import Darwin         // OSAllocatedUnfairLock：跨线程锁
import IOKit.pwr_mgt  // IOPMAssertion：防止系统判定进程空闲并冻结
import ApplicationServices  // AXIsProcessTrusted：辅助功能权限预检（TCC 自检）

// 应用启动时强制激活窗口到前台（直接 swift 运行时窗口默认不激活）
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 抑制 App Nap 的 activity token（必须持有，否则 activity 立即释放、抑制失效）
    private var napToken: NSObjectProtocol?
    /// CGEventTap 句柄（持有防止释放，系统级实时保护）
    private var eventTap: CFMachPort?
    /// 2GB内存锚点（持有防止释放，让系统不敢冻结本进程）
    private var memoryAnchor: UnsafeMutableRawPointer?
    /// IOPMAssertion ID（防止系统 Power Management 判定进程空闲并冻结，Game Mode 最强对抗）
    private var powerAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

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

        // 强制占用768MB内存：让系统认为本进程是"重资源进程"不敢冻结
        // 每页4KB，768MB = 196608页，mlock锁定在物理RAM不被换出
        let allocSize = 768 * 1024 * 1024  // 768MB
        let pageCount = allocSize / 4096
        if let buf = UnsafeMutableRawPointer.allocate(byteCount: allocSize, alignment: 4096) as UnsafeMutableRawPointer? {
            // 写入每个页首字节（强制物理内存映射）
            for i in 0..<pageCount {
                buf.advanced(by: i * 4096).storeBytes(of: UInt8(i & 0xFF), as: UInt8.self)
            }
            // mlock：锁定页面在物理RAM，系统不能换出
            if mlock(buf, allocSize) == 0 {
                print("[App] 768MB内存已锁定在物理RAM → 系统不敢冻结")
            } else {
                print("[App] mlock失败（可能需要root），768MB仍占用但可能被换出")
            }
            // 持有指针防止释放
            self.memoryAnchor = buf
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
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
        
        // SwiftUI WindowGroup 的窗口在 applicationDidFinishLaunching 之后、runloop 下一轮
        // 才创建（此时同步遍历 NSApp.windows 常为空，激活无效）。延迟到下一 runloop 再
        // 激活，确保窗口已创建后置前，避免"进程起来却无可见窗口"。
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
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
        if powerAssertionID != kIOPMNullAssertionID {
            IOPMAssertionRelease(powerAssertionID)
            print("[App] IOPMAssertion 已释放")
        }
    }
}


// ============================================================================
// 插帧引擎自检（--upscale-selftest）
// ============================================================================

private func runUpscaleSelfTest() {
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
    static func main() {
        if CommandLine.arguments.contains("--engine") {
            EngineMain.run()   // 永不返回（dispatchMain 常驻）
        }
        AuroraDriveApp.main()
    }
}

struct AuroraDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 560)
                .background(Color.black)
                .onAppear {
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows {
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
// MARK: - 文件 2: Theme.swift  (设计系统 / 主题常量)
// ============================================================================

/// 全局主题：FSD 驾驶舱配色与发光参数
enum Theme {
    // 背景
    static let bgPure      = Color.black                       // #000000
    static let bgCard      = Color.white.opacity(0.045)        // 卡片底
    static let bgCardEdge  = Color.white.opacity(0.08)         // 卡片描边

    // 主色 / 强调
    static let cyan        = Color(red: 0.0, green: 0.898, blue: 1.0)   // #00E5FF
    static let cyanDim     = Color(red: 0.0, green: 0.898, blue: 1.0).opacity(0.55)
    static let orangeRed   = Color(red: 1.0, green: 0.36, blue: 0.22)   // 极速模式
    static let danger      = Color(red: 1.0, green: 0.24, blue: 0.28)   // 障碍红

    // 文字（严禁黑色文字）
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.38)

    // 发光阴影
    static func glow(_ color: Color, radius: CGFloat) -> some View {
        EmptyView().shadow(color: color, radius: radius) // 占位,实际用 .shadow 修饰符
    }
}

/// 圆角卡片容器：半透明底 + 细描边 + 内高光
struct GlowCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.bgCard)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 区块标题：小字大写 + 青色竖条
struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.cyan)
                .frame(width: 3, height: 12)
                .shadow(color: Theme.cyan, radius: 4)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
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
    var enableNetworkLocate = false
    var bpfAuthorized = false  // 启动时检测BPF权限
    var showBPFPasswordSheet = false  // 是否显示密码输入弹窗
    var bpfInstallMessage = ""  // 安装结果消息
    var bpfInstalling = false  // 正在安装中
    
    // ── Daemon 系统服务相关字段 ──
    var daemonInstalled = false  // 是否已安装为系统服务
    var showDaemonInstallSheet = false  // 是否显示安装引导弹窗
    var daemonInstallMessage = ""  // 安装结果消息
    var daemonInstalling = false  // 正在安装中
    var isDaemonMode = false  // 当前是否为 daemon 模式运行
    
    var networkLocateX: Double = 0
    var networkLocateY: Double = 0
    var networkLocateScore: Double = 0
    var networkLocateMode: String = ""
    var networkLocatePitch: Double = 0
    var networkLocateHeading: Double = 0

    // ── 定位器字段（从外置盘移植，MinimapLocatorView需要） ──
    var locatorFound = false
    var locatorX: Double = 0
    var locatorY: Double = 0
    var locatorScore: Double = 0
    var locatorHeading: Double = 0
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
            "\(execDir)/models/bigworldmapSecond.png",
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

    func runNetworkLocateStep() {
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
            DispatchQueue.main.async { [weak self] in
                self?.networkLocateScore = 0
                self?.networkLocateMode = "not_ready"
            }
            return
        }

        // 从 CoordinateCapture 获取定位
        if let pose = cc.read(maxAge: 1.0) {
            let (px, py, hdg) = worldToMapPixel(pose)
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
                self?.locatorFound = true
                self?.locatorScore = 1.0
                self?.locatorHeading = hdg
            }
        } else {
            // 网络定位无数据
            DispatchQueue.main.async { [weak self] in
                self?.networkLocateScore = 0
                self?.networkLocateMode = "no_data"
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

    /// 当前驾驶模式（由降级状态机计算，每帧 tick 同步）
    /// UI 观察此属性刷新模式芯片高亮
    var mode: DriveMode = .e2e
    var confidence: Double = 0.92       // 0~1

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

    var fps: Double        = 60

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
            return ("M9未加载", Theme.textTertiary)
        }
        if let t = inferenceEngine.lastResultTime, Date().timeIntervalSince(t) < 1.0 {
            return ("M9活跃", Theme.cyan)
        }
        return ("M9失联", Theme.danger)
    }

    var speedLimit: Double      = 120   // 速度上限
    var degradeThreshold: Double = 0.65 // 降级阈值（同步给状态机）

    var modelVersion = "v2.4.1-e2e-fsd"
    var frames: Int  = 128_402

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

    /// 截屏权限状态（首次启动若未授权，引导用户到系统设置）
    var capturePermissionDenied = false

    // ── 按键注入引擎（CGEvent 控制 WASD/空格/Shift）──
    // 启动时检查辅助功能权限，停止时释放所有按住的键
    let controlEngine = ControlEngine()

    /// 辅助功能权限状态（首次启动若未授权，引导用户到系统设置）
    var controlPermissionDenied = false

    // ── 物理键盘监听（实时读取用户真实按键，供 KeyboardBar 显示）──
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
        try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")
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
        upscaleHost.prepare()
        upscaleSupported = upscaleHost.isAvailable
        dlog("[upscale] 引擎初始化: 可用=\(upscaleSupported)")

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
        remoteDetections = client.engineDetections
        // 引擎已停止抓屏（点了停止/暂停）→ UI 侧同步收尾：
        // 否则 isStreaming 会一直停在 true（引擎模式下只在有帧时被置 true，从不复位），
        // 导致插帧视图继续挂着、徽章一直显示"插帧中"（用户实测反馈）。
        if !client.engineIsStreaming && isStreaming {
            isStreaming = false
            upscaleLive = nil
            upscaleHost.clear()     // 停掉 MetalGoose 渲染（detach）
            frameHost.clear()
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
            // 待机：车速衰减，清空决策
            speedValid = false
            effectiveSpeed = max(0, effectiveSpeed - 6)
            currentCommand = .idle
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
            // 直通未活跃（如尚未接入）时回退到 tick 内转换
            if !yoloEngine.fastPathActive {
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
        speedValid = ocrFresh
        if ocrFresh {
            effectiveSpeed += (speedOCR.speedKmh - effectiveSpeed) * 0.7   // 快跟踪 OCR 读数
        } else {
            effectiveSpeed *= 0.9                                          // 向 0 一阶衰减
            if effectiveSpeed < 0.5 { effectiveSpeed = 0 }
        }
        // FPS 显示真实捕获帧率（删除模拟遥测随机抖动）
        fps = captureEngine.captureFPS > 0 ? captureEngine.captureFPS : 60

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
        mode = decided   // 同步给 UI

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
            confidence = confidenceEst.confidence   // 同步给 UI
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
                 + "ocr=\(String(format: "%.1f", speedOCR.speedKmh))/\(String(format: "%.2f", speedOCR.confidence))"
                 + "\(speedOCR.speedKmh < 0 ? "[" + speedOCR.lastOCRDiagnostic + "]" : "") "
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

struct ContentView: View {
    @State private var state = DriveState()

    @State private var tickTimer: Timer? = nil
    @State private var tickDispatchSource: DispatchSourceTimer? = nil
    @State private var netLocDispatchSource: DispatchSourceTimer? = nil

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                GameViewportView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SidebarView(state: state)
                    .frame(width: 360)
            }
            .padding(.top, 44)

            TopToolbar(state: state)
        }
        .background(Theme.bgPure)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $state.showBPFPasswordSheet) {
            BPFPasswordSheet(state: state)
        }
        .sheet(isPresented: $state.showDaemonInstallSheet) {
            DaemonInstallSheet(state: state)
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
            tickDispatchSource?.cancel()
            tickDispatchSource = nil
            netLocDispatchSource?.cancel()
            netLocDispatchSource = nil
        }
        .onAppear {
            // tick 驱动：用 DispatchSource 替代 main RunLoop Timer
            // main RunLoop Timer 会被 App Nap 冻结（游戏全屏时 tick 掉到 8Hz）
            // DispatchSource 在独立高优先级队列上运行，不受 App Nap 影响
            let timerQueue = DispatchQueue(label: "com.aurora.tick", qos: .userInteractive)
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
            timer.setEventHandler {
                DispatchQueue.main.async {
                    state.tick()
                }
            }
            timer.resume()
            tickTimer = nil  // 不再用 Timer 类型，用 DispatchSource 控制
            tickDispatchSource = timer

            // Daemon 系统服务检查（优先级高于 BPF，因为影响整个进程调度）
            state.isDaemonMode = DaemonSetupManager.isRunningAsDaemon()
            state.daemonInstalled = DaemonSetupManager.isDaemonInstalled()
            if DaemonSetupManager.needsInstall() {
                print("[App] 未安装为系统服务，显示安装引导")
                state.showDaemonInstallSheet = true
            } else if state.isDaemonMode {
                print("[App] 当前以系统服务运行（最高优先级）")
            } else if state.daemonInstalled {
                print("[App] 已安装系统服务，但当前为普通模式")
            }
            
            // BPF权限检查（在onAppear里，有state访问权限）
            if BPFSetupManager.needsInstall() {
                print("[App] BPF需要安装，等待用户输入密码")
                state.showBPFPasswordSheet = true
            } else if BPFSetupManager.isBPFAvailable() {
                print("[App] BPF可读写 ✓")
                state.bpfAuthorized = true
            } else if BPFSetupManager.isLaunchDaemonInstalled() {
                BPFSetupManager.tryImmediateChmod()
                state.bpfAuthorized = BPFSetupManager.isBPFAvailable()
                print("[App] LaunchDaemon已装，BPF: \(state.bpfAuthorized)")
            }

            // 网络定位定时器4Hz
            let nlQueue = DispatchQueue(label: "com.aurora.netlocate", qos: .userInteractive)
            let nlTimer = DispatchSource.makeTimerSource(queue: nlQueue)
            nlTimer.schedule(deadline: .now(), repeating: 1.0 / 10.0, leeway: .nanoseconds(0))
            nlTimer.setEventHandler { DispatchQueue.main.async { 
                pcapLog("[TIMER] runNetworkLocateStep被调用")
                state.runNetworkLocateStep() 
            } }
            nlTimer.resume()
            netLocDispatchSource = nlTimer
            // 自主测试入口：AuroraDriveUI --auto-drive [--auto-seconds N]
            // 启动后自动开始驾驶（模拟人工点击「开始驾驶」），到点自动退出，
            // 用于无人值守的端到端验证（跑完读 /tmp/aurora_debug.log）。
            let args = CommandLine.arguments
            if args.contains("--auto-drive") {
                print("[AUTO] --auto-drive 收到，1.5s 后自动开始驾驶")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    state.startDriving()
                }
            }
            if let i = args.firstIndex(of: "--auto-seconds"), i + 1 < args.count,
               let secs = Double(args[i + 1]), secs.isFinite {
                print("[AUTO] \(Int(secs))s 后自动退出")
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    print("[AUTO] 到点退出")
                    exit(0)
                }
            }
            if args.contains("--upscale-selftest") {
                print("[UPSELFTEST] 插帧引擎自检开始")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runUpscaleSelfTest()
                }
            }
        }
    }
}


// ============================================================================
// MARK: - 常驻左上角悬浮小地图（不依赖 GameMapView，应用启动即显示）
// ============================================================================

/// 朝向指示三角形（用于 FloatingMinimap，与 GameMapView 内的私有 Triangle 同款）
struct DirectionTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct FloatingMinimap: View {
    @Bindable var state: DriveState
    /// 瓦片缓存：应用启动即 onAppear 触发后台切图，与驾驶/定位状态无关
    /// （用户要求：不开自动驾驶也要显示小地图当作地图用）。
    @StateObject private var tileCache = MinimapTileCache()

    var body: some View {
        // 固定 224×224（200 小地图 + padding 12×2）：不占满整个 ZStack。
        // 之前用 .frame(maxWidth:.infinity, maxHeight:.infinity) 占满全窗 + zIndex(15)，
        // 即使 allowsHitTesting(false)，占满的高 zIndex 层在部分 SwiftUI 版本下仍会
        // 拦截 hit，导致 sidebar 按钮点不到。固定尺寸只占左上角，彻底不挡按钮。
        minimapBody
            .padding(12)
            .frame(width: 224, height: 224)
            .allowsHitTesting(false)
            .onAppear { tileCache.ensureLoaded() }
    }

    // MARK: 常量与状态判定

    private static let size = MinimapTileCache.minimapPx   // 200

    /// 网络定位是否有效。networkLocateX/Y 是 11264 像素坐标（参考坐标系，非百分比），
    /// 故有效区间为 (0, 11264)。
    private var hasValidLocate: Bool {
        state.networkLocateScore > 0.3
            && state.networkLocateX > 0 && state.networkLocateY > 0
            && state.networkLocateX < Double(MinimapTileCache.mapPixelSize)
            && state.networkLocateY < Double(MinimapTileCache.mapPixelSize)
    }

    private var gameRunning: Bool { hasValidLocate || state.isDriving }

    // MARK: 主体

    @ViewBuilder
    private var minimapBody: some View {
        ZStack {
            // ── 底图 ──
            if hasValidLocate,
               let tile = tileCache.tileAt(mapPixelX: state.networkLocateX,
                                           mapPixelY: state.networkLocateY) {
                // 有定位：显示角色当前所在瓦片（局部放大），与参考 MINI_MAP_ROI 语义一致
                mapImage(tile)
            } else if let ov = tileCache.overview {
                // 无定位：全图缩略，让小地图始终是可用地图（非空白）
                overviewImage(ov)
            } else {
                placeholder
            }

            gridOverlay
            statusBadge

            if hasValidLocate {
                cursor
            }
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cyan.opacity(0.5), lineWidth: 1.5))
        .overlay(alignment: .bottomTrailing) {
            if tileCache.isReady {
                if hasValidLocate {
                    Text("\(MinimapTileCache.tileIndex(mapPixel: state.networkLocateX)),\(MinimapTileCache.tileIndex(mapPixel: state.networkLocateY))/8×8")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(3)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                } else {
                    Text("切图\(Int(tileCache.loadMs))ms")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(4)
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 8)
    }

    // MARK: 底图视图

    @ViewBuilder
    private func mapImage(_ cg: CGImage) -> some View {
        let ns = NSImage(cgImage: cg, size: NSSize(width: Self.size, height: Self.size))
        Image(nsImage: ns)
            .resizable()
            .frame(width: Self.size, height: Self.size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func overviewImage(_ cg: CGImage) -> some View {
        let ns = NSImage(cgImage: cg, size: NSSize(width: Self.size, height: Self.size))
        Image(nsImage: ns)
            .resizable()
            .scaledToFill()
            .frame(width: Self.size, height: Self.size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.85))
            .frame(width: Self.size, height: Self.size)
            .overlay {
                VStack(spacing: 4) {
                    if let err = tileCache.loadError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView()
                        Text("加载地图瓦片…")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
    }

    // MARK: 网格

    @ViewBuilder
    private var gridOverlay: some View {
        Path { path in
            let step = Self.size / CGFloat(MinimapTileCache.tilesPerSide)
            for i in 1..<MinimapTileCache.tilesPerSide {
                let v = step * CGFloat(i)
                path.move(to: CGPoint(x: v, y: 0))
                path.addLine(to: CGPoint(x: v, y: Self.size))
                path.move(to: CGPoint(x: 0, y: v))
                path.addLine(to: CGPoint(x: Self.size, y: v))
            }
        }
        .stroke(Theme.cyan.opacity(0.15), lineWidth: 0.5)
    }

    // MARK: 状态徽章

    @ViewBuilder
    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(gameRunning ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .shadow(color: (gameRunning ? Color.green : Color.red).opacity(0.8), radius: 3)
                Text(gameRunning ? "一环已打开" : "一环未打开")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(gameRunning ? Color.green : Color.red)
            }
            if hasValidLocate {
                Text("(\(Int(state.networkLocateX)), \(Int(state.networkLocateY)))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text("置信 \(Int(state.networkLocateScore * 100))%")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(state.networkLocateScore > 0.7 ? Theme.cyan : Theme.danger)
            } else if state.isDriving {
                Text("等待网络定位…")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("未开启驾驶")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cyan.opacity(0.3), lineWidth: 0.5))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
    }

    // MARK: 光标（瓦片内相对位置）

    @ViewBuilder
    private var cursor: some View {
        let cx = MinimapTileCache.inTileOffset(mapPixel: state.networkLocateX)
        let cy = MinimapTileCache.inTileOffset(mapPixel: state.networkLocateY)
        ZStack {
            Circle()
                .fill(Theme.cyan.opacity(0.3))
                .frame(width: 22, height: 22)
                .shadow(color: Theme.cyan, radius: 6)
            Circle()
                .fill(Theme.cyan)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 2)
            DirectionTriangle()
                .fill(.white)
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(state.networkLocateHeading))
                .offset(y: -12)
        }
        .position(x: cx, y: cy)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: state.networkLocateX)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: state.networkLocateY)
    }
}


// ============================================================================
// MARK: - 文件 5: TopToolbar.swift  (顶部细工具栏)
// ============================================================================

struct TopToolbar: View {
    @Bindable var state: DriveState

    var body: some View {
        HStack {
            // 左: App 名(青色发光) + 插帧状态徽章
            HStack(spacing: 8) {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan, radius: 6)
                Text("AuroraDrive")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan.opacity(0.9), radius: 8)
                upscaleBadge
            }

            Spacer()

            // 右: Daemon状态药丸 + BPF状态药丸 + 模式标识 + 运行灯
            HStack(spacing: 10) {
                // Daemon系统服务状态药丸（最高优先级标识）
                if state.isDaemonMode {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .font(.system(size: 9))
                        Text("系统级")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.cyan.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan.opacity(0.4), radius: 4)
                    .help("当前以系统服务运行，最高调度优先级")
                } else if !state.daemonInstalled {
                    Button {
                        state.showDaemonInstallSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shield")
                                .font(.system(size: 9))
                            Text("升级")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.orangeRed.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.orangeRed)
                    }
                    .buttonStyle(.plain)
                    .help("安装为系统服务，防止游戏全屏时被冻结")
                }
                // BPF权限药丸按钮（灵动岛风格折叠）
                if !state.bpfAuthorized {
                    Button {
                        state.showBPFPasswordSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 9))
                            Text("BPF")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.orangeRed.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.orangeRed)
                        .shadow(color: Theme.orangeRed.opacity(0.4), radius: 4)
                    }
                    .buttonStyle(.plain)
                    .help("点击安装BPF权限（只需一次）")
                }
                // 网络定位状态指示灯（不需要密码，BPF已chmod 666）
                Circle()
                    .fill(state.isDriving ? Theme.cyan : Theme.textTertiary)
                    .frame(width: 7, height: 7)
                    .shadow(color: state.isDriving ? Theme.cyan : .clear, radius: 5)
                // P0-2 修复：脱困（自动倒车/转向，最高风险动作）期间显示独立告警，不并入「规则」分组
                Text(state.isDriving ? (state.mode == .recover ? "脱困中" : state.mode.uiGroup.rawValue) : "待机")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.isDriving ? (state.mode == .recover ? Theme.orangeRed : Theme.cyan) : Theme.textTertiary)
                if state.isDriving {
                    Text(state.m9Status.text)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(state.m9Status.color)
                }
                // 引擎模式状态：后台引擎已连接 / 失联（仅引擎模式显示；本地模式此块不出现）
                if state.engineModeActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.engineConnected ? Theme.cyan : Theme.orangeRed)
                            .frame(width: 6, height: 6)
                            .shadow(color: (state.engineConnected ? Theme.cyan : Theme.orangeRed).opacity(0.9),
                                    radius: 4)
                        Text(state.engineConnected ? "引擎已连接" : "引擎失联")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(state.engineConnected ? Theme.cyan : Theme.orangeRed)
                    }
                    .help("后台引擎运行中：抓屏/推理/按键都在引擎进程里，本窗口只负责显示")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(.bar.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LinearGradient(colors: [Theme.cyan.opacity(0.35), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }

    private var upscaleBadge: some View {
        let col: Color
        let txt: String
        if !state.upscaleSupported {
            col = Theme.danger; txt = "插帧不可用"
        } else if let err = state.upscaleEngineError {
            col = Theme.danger; txt = "插帧异常 · \(err)"
        } else if !state.upscaleEnabled {
            col = Theme.textTertiary; txt = "插帧 · 关"
        } else if !state.isDriving {
            // 没在驾驶 = 没有新帧可插（停止/暂停后不应继续显示"插帧中"）
            col = Theme.textTertiary; txt = "插帧 · 待机"
        } else if let live = state.upscaleLive {
            col = Theme.cyan; txt = "插帧中 · \(live)"
        } else {
            col = Theme.cyan; txt = "插帧中 · 等待"
        }
        return Text(txt)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(col)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(col.opacity(0.12)))
            .overlay(Capsule().strokeBorder(col.opacity(0.35), lineWidth: 1))
            .help("插帧实时状态：产出=插入的中间帧 输出=总呈现帧 透传=未插帧直通 帧率")
    }
}

// MARK: - BPF权限安装弹窗（灵动岛风格）

struct BPFPasswordSheet: View {
    @Bindable var state: DriveState
    @State private var password = "123456"

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan, radius: 10)
                Text("安装BPF权限")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cyan)
                Text("输入管理员密码，安装后永久生效\n每次重启自动恢复，无需再输入")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.bgPure, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.textPrimary)
                .font(.system(size: 14, design: .monospaced))

            if !state.bpfInstallMessage.isEmpty {
                Text(state.bpfInstallMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(state.bpfInstallMessage.contains("成功") || state.bpfInstallMessage.contains("已安装") ? Theme.cyan : Theme.orangeRed)
            }

            HStack(spacing: 12) {
                Button("取消") {
                    state.showBPFPasswordSheet = false
                    state.bpfInstallMessage = ""
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

                Button {
                    state.bpfInstalling = true
                    state.bpfInstallMessage = ""
                    let pwd = password
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = BPFSetupManager.install(password: pwd)
                        DispatchQueue.main.async {
                            state.bpfInstalling = false
                            state.bpfInstallMessage = result.message
                            if result.success {
                                state.bpfAuthorized = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    state.showBPFPasswordSheet = false
                                    state.bpfInstallMessage = ""
                                }
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
                    .background(Theme.cyan.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.cyan)
                }
                .buttonStyle(.plain)
                .disabled(state.bpfInstalling || password.isEmpty)
            }
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Theme.cyan.opacity(0.3), lineWidth: 1)
                }
        }
        .frame(width: 340)
    }
}

// MARK: - DaemonInstallSheet (系统服务安装引导)

/// Daemon 安装引导弹窗：首次启动时引导用户安装为 LaunchDaemon（最高优先级）
struct DaemonInstallSheet: View {
    @Bindable var state: DriveState
    @State private var password = "123456"

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan, radius: 10)
                Text("安装系统级服务")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cyan)
                Text("游戏全屏时 macOS 会冻结后台 App\n安装为系统服务可获得最高调度优先级\n防止被冻结，只需输入一次密码")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            SecureField("管理员密码", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.bgPure, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.textPrimary)
                .font(.system(size: 14, design: .monospaced))

            if !state.daemonInstallMessage.isEmpty {
                Text(state.daemonInstallMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(state.daemonInstallMessage.contains("成功") || state.daemonInstallMessage.contains("已安装") ? Theme.cyan : Theme.orangeRed)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("暂不安装") {
                    state.showDaemonInstallSheet = false
                    state.daemonInstallMessage = ""
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

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
                    .background(Theme.cyan.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.cyan)
                }
                .buttonStyle(.plain)
                .disabled(state.daemonInstalling || password.isEmpty)
            }
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Theme.cyan.opacity(0.3), lineWidth: 1)
                }
        }
        .frame(width: 360)
    }
}


// ============================================================================
// MARK: - 文件 6: GameViewportView.swift  (左侧游戏画面叠加区)
// ============================================================================

struct GameViewportView: View {
    @Bindable var state: DriveState

    /// 手动框选：拖拽起点/当前点（视口坐标）
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

            // ── 真实游戏画面（CGDisplayStream 画面流）──
            // 当截屏引擎运行时，显示实时游戏画面
            // 未运行时，显示纯黑占位 + 提示文字
            if state.isStreaming {
                // 引擎模式下 UI 不采集、只显示：插帧的帧来自引擎（全分辨率经共享内存送来），
                // 由 tickEngineMode 喂给 upscaleHost，所以两种档位都能正常显示。
                if state.upscaleEnabled {
                    UpscaleFrameHostView(host: state.upscaleHost)
                        .onChange(of: state.upscaleEnabled) { _, on in
                            if !on { state.upscaleHost.clear() }
                        }
                } else {
                    FrameHostView(host: state.frameHost)
                }
            } else {
                // 未启动时：纯黑底 + 待机提示
                VStack(spacing: 12) {
                    Image(systemName: "steeringwheel")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Theme.cyan.opacity(0.3))
                        .shadow(color: Theme.cyan.opacity(0.2), radius: 12)

                    // 权限提示优先级：辅助功能 > 屏幕录制
                    if state.controlPermissionDenied {
                        Text("需要辅助功能权限")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.danger)
                        Text("请到 系统设置 > 隐私与安全 > 辅助功能 授权后重试")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if state.capturePermissionDenied {
                        Text("需要屏幕录制权限")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.danger)
                        Text("请到 系统设置 > 隐私与安全 > 屏幕录制 授权后重试")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        Text("点击右侧启动按钮")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            // ── AI 识别叠加层：检测框（本地模式=YoloEngine / 引擎模式=引擎回传）──
            ObstacleOverlay(active: state.isDriving,
                            detections: state.effectiveDetections,
                            sourceSize: state.screenSize,
                            lockedTarget: state.yoloEngine.lockedTarget,
                            isLocked: state.yoloEngine.isLocked)

            // ── 小地图（移植版，显示网络定位位置）放在左上角
            MinimapLocatorView(state: state)
                .allowsHitTesting(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // ── 速度表ROI调试框（红框=速度表区域，蓝框=3个数字槽位）──
            SpeedROIOverlay(sourceSize: state.screenSize)

            // ── 手动框选预览（拖拽中显示虚线框）──
            if let s = dragStart, let c = dragCurrent {
                let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                  width: abs(c.x - s.x), height: abs(c.y - s.y))
                if rect.width > 4 && rect.height > 4 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.orangeRed.opacity(0.95),
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: Theme.orangeRed.opacity(0.5), radius: 6)
                }
            }

            // ── 锁定状态悬浮提示 + 取消锁定 ──
            if state.yoloEngine.isLocked {
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Text("🎯 \(state.yoloEngine.lockMessage ?? "追踪中")")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.orangeRed)
                            Button {
                                state.yoloEngine.clearLock()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.orangeRed)
                            }
                            .buttonStyle(.plain)
                            .help("解除锁定")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.orangeRed.opacity(0.5), lineWidth: 1))
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(true)
            }

            // ── 地平线光晕（FSD 风格装饰）──
            VStack {
                Spacer().frame(height: 240)
                Ellipse()
                    .fill(RadialGradient(
                        colors: [Theme.cyan.opacity(state.isDriving ? 0.16 : 0.05), .clear],
                        center: .center, startRadius: 10, endRadius: 260))
                    .frame(width: 700, height: 120)
                    .blur(radius: 20)
                    .allowsHitTesting(false)   // 不挡画面交互
                Spacer()
            }

            // ── 左下角 HUD: REC / 帧数 ──
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 8) {
                        if state.isRecording {
                            Circle().fill(Theme.danger).frame(width: 8, height: 8)
                                .shadow(color: Theme.danger, radius: 6)
                            Text("REC")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Theme.danger)
                        }
                        Text("FRAMES \(state.frames.formatted())")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    Spacer()
                }
                .padding(16)

            }

            // ── 底部键盘可视化条（薄薄一条，约1厘米高）──
            // 显示 WASD + 空格 + Shift，按下时变青绿色发光
            // 观察控制引擎的按键状态，实时高亮
            VStack {
                Spacer()
                KeyboardBar(state: state)
                    .padding(.bottom, 8)
            }
            }
            .clipped()
            // ── 手动框选/点选手势：锁定追踪目标 ──
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // 驾驶中才允许框选
                        guard state.isDriving else { return }
                        if dragStart == nil { dragStart = v.startLocation }
                        dragCurrent = v.location
                    }
                    .onEnded { v in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard state.isDriving else { return }
                        let s = dragStart ?? v.startLocation
                        let c = dragCurrent ?? v.location

                        // 视口坐标 → 源图归一化
                        // 基准用 screenSize（本地/引擎、直绘/插帧两条显示路径都有值）；
                        // 不用 frameHost.latestSize —— 插帧路径画面由 MetalGoose 直渲、
                        // 不经过 frameHost，读它会拿到空值 → 整个框选被 guard 拦掉（选不了）。
                        let srcSize = state.screenSize ?? state.frameHost.latestSize
                        let viewSize = geo.size
                        guard let n1 = viewToSourceNorm(s, source: srcSize, view: viewSize),
                              let n2 = viewToSourceNorm(c, source: srcSize, view: viewSize) else { return }

                        let rect = CGRect(x: min(n1.x, n2.x), y: min(n1.y, n2.y),
                                          width: abs(n2.x - n1.x), height: abs(n2.y - n1.y))

                        // 拖得够大 = 手动框选锁定
                        if rect.width > 0.05 && rect.height > 0.05 {
                            state.yoloEngine.setLock(x: rect.midX, y: rect.midY,
                                                     width: rect.width, height: rect.height)
                        } else {
                            // 点选：只有「点在检测框上」才锁定该框；点空白不再生成幽灵框。
                            // 注意检测结果必须走 effectiveDetections —— 引擎模式下框来自后台引擎，
                            // 读 yoloEngine.detections 永远是空数组，会退化成「点哪都建一个 0.12 的框」。
                            let center = CGPoint(x: rect.midX, y: rect.midY)
                            let dets = state.effectiveDetections
                            if let hit = dets.first(where: { Self.hitTest($0, center, margin: 0.03) }) {
                                state.yoloEngine.setLock(to: hit)
                            } else if let nearest = dets.min(by: {
                                Self.normDist($0, center) < Self.normDist($1, center)
                            }), Self.normDist(nearest, center) < 0.12 {
                                state.yoloEngine.setLock(to: nearest)
                            }
                            // 点空白处：不生成任何框（旧行为会留下永不消失的 0.12 幽灵框）
                        }
                    }
            )
            .overlay(alignment: .trailing) {
                // 与侧边栏之间的渐变分界光带
                LinearGradient(colors: [Theme.cyan.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 1)
            }
        }
    }

    /// 检测框中心到点的归一化距离
    private static func normDist(_ d: Detection, _ p: CGPoint) -> Double {
        hypot(d.x - p.x, d.y - p.y)
    }

    /// 点是否落在检测框内（含少量外扩余量，方便点小目标）
    private static func hitTest(_ d: Detection, _ p: CGPoint, margin: Double) -> Bool {
        abs(p.x - d.x) <= d.width / 2 + margin && abs(p.y - d.y) <= d.height / 2 + margin
    }
}

// ============================================================================
// MARK: - 键盘可视化条（底部薄条，显示按键状态）
// ============================================================================

/// 底部键盘可视化条
/// 显示 WASD + 空格 + Shift 共6个键，按下时变青绿色发光
/// 读取物理键盘状态（keyboardMonitor），实时反映用户真实按键
/// 薄薄一条（约28pt 高），不挡画面主体
struct KeyboardBar: View {
    let state: DriveState

    var body: some View {
        HStack(spacing: 6) {
            // 读取物理键盘状态（keyboardMonitor.heldKeys）
            // keyMap.keyCode(for:) 把语义动作转成键码，再查是否物理按住
            KeyCap(label: "W", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .throttle)))
            KeyCap(label: "A", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .steerLeft)))
            KeyCap(label: "S", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .brake)))
            KeyCap(label: "D", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .steerRight)))
            KeyCap(label: "␣", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .handbrake)), wide: true)
            KeyCap(label: "⇧", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .boost)))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// 单个键帽
/// - active: 是否按下（true=青绿色发光，false=暗色边框）
/// - wide: 是否加宽（空格键）
struct KeyCap: View {
    let label: String
    let active: Bool
    var wide: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(active ? Color.black : Theme.textTertiary)
            .frame(width: wide ? 60 : 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color(red: 0.0, green: 1.0, blue: 0.6) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Color(red: 0.0, green: 1.0, blue: 0.6) : Theme.cyan.opacity(0.3),
                                  lineWidth: 1)
            )
            .shadow(color: active ? Color(red: 0.0, green: 1.0, blue: 0.6).opacity(0.8) : .clear, radius: 6)
            .animation(.easeInOut(duration: 0.08), value: active)
    }
}

/// Canvas 绘制: 透视车道线(青色发光 + 滚动虚线)
struct LaneCanvas: View {
    var phase: Double
    var active: Bool

    /// 底部各车道线 x 比例
    private let laneXs: [CGFloat] = [0.06, 0.30, 0.50, 0.70, 0.94]

    var body: some View {
        Canvas { ctx, size in
            let horizonY = size.height * 0.42
            let vanish   = CGPoint(x: size.width * 0.5, y: horizonY)
            let baseOpacity = active ? 1.0 : 0.28

            // ---- 车道线(底部 -> 灭点) ----
            for (i, fx) in laneXs.enumerated() {
                let start = CGPoint(x: size.width * fx, y: size.height)
                var p = Path()
                p.move(to: start)
                p.addQuadCurve(to: vanish,
                               control: CGPoint(x: (start.x + vanish.x) / 2,
                                                y: horizonY + (size.height - horizonY) * 0.55))

                let isCenter = (i == laneXs.count / 2)
                let color = Theme.cyan.opacity(isCenter ? 0.9 * baseOpacity : 0.65 * baseOpacity)

                // 外层辉光
                ctx.stroke(p, with: .color(Theme.cyan.opacity(0.18 * baseOpacity)),
                           style: StrokeStyle(lineWidth: 10, lineCap: .round))
                // 中层辉光
                ctx.stroke(p, with: .color(Theme.cyan.opacity(0.35 * baseOpacity)),
                           style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                // 核心亮线(中间线为实线,两侧滚动虚线)
                let coreStyle: StrokeStyle = isCenter
                    ? StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    : StrokeStyle(lineWidth: 2.2, lineCap: .round,
                                  dash: [26, 20], dashPhase: -phase)
                ctx.stroke(p, with: .color(color), style: coreStyle)
            }

            // ---- 灭点光源 ----
            let glowRect = CGRect(x: vanish.x - 60, y: vanish.y - 14, width: 120, height: 28)
            ctx.fill(Path(ellipseIn: glowRect),
                     with: .color(Theme.cyan.opacity(0.5 * baseOpacity)))

            // ---- 地平细线 ----
            var hline = Path()
            hline.move(to: CGPoint(x: 0, y: horizonY))
            hline.addLine(to: CGPoint(x: size.width, y: horizonY))
            ctx.stroke(hline, with: .color(Theme.cyan.opacity(0.22 * baseOpacity)),
                       style: StrokeStyle(lineWidth: 1))
        }
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
// MARK: - 速度表ROI调试框（在App预览画面上画框，显示OCR在看哪里）
struct SpeedROIOverlay: View {
    var sourceSize: CGSize?

    var body: some View {
        Canvas { ctx, size in
            let t = aspectFillLayout(source: sourceSize, view: size)
            guard t.size.width > 0, t.size.height > 0 else { return }

            let roi = CaptureEngine.speedROINorm
            let rx = t.origin.x + roi.origin.x * t.size.width
            let ry = t.origin.y + roi.origin.y * t.size.height
            let rw = roi.width * t.size.width
            let rh = roi.height * t.size.height
            let roiRect = CGRect(x: rx, y: ry, width: rw, height: rh)
            ctx.stroke(Path(roiRect), with: .color(.red), lineWidth: 2)
            ctx.fill(Path(roiRect), with: .color(.red.opacity(0.1)))

            let slotCx = SpeedOCRReader.slotCentersNorm
            let slotW = SpeedOCRReader.slotWidthNorm
            let yMin = SpeedOCRReader.slotYMinNorm
            let yMax = SpeedOCRReader.slotYMaxNorm
            for i in 0..<3 {
                let cx = slotCx[i]
                let sx = t.origin.x + (cx - slotW/2) * t.size.width
                let sy = t.origin.y + yMin * t.size.height
                let sw = slotW * t.size.width
                let sh = (yMax - yMin) * t.size.height
                let slotRect = CGRect(x: sx, y: sy, width: sw, height: sh)
                ctx.stroke(Path(slotRect), with: .color(.cyan), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

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
        case .pedestrian: return Theme.danger                                  // 行人：红
        case .car:        return Theme.cyan                                    // 车辆：青
        case .sign:       return Color(red: 1.0, green: 0.82, blue: 0.25)      // 标识：黄
        case .obstacle:   return Theme.orangeRed                               // 其他：橙
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
                ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.orangeRed.opacity(0.12)))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.orangeRed), style: StrokeStyle(lineWidth: 3))
                // 四角准星 14pt
                let corners: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: box.minX, y: box.minY), 1, 1), (CGPoint(x: box.maxX, y: box.minY), -1, 1), (CGPoint(x: box.minX, y: box.maxY), 1, -1), (CGPoint(x: box.maxX, y: box.maxY), -1, -1)]
                for (p, sx, sy) in corners {
                    var path = Path()
                    path.move(to: p)
                    path.addLine(to: CGPoint(x: p.x + 14*sx, y: p.y))
                    path.move(to: p)
                    path.addLine(to: CGPoint(x: p.x, y: p.y + 14*sy))
                    ctx.stroke(path, with: .color(Theme.orangeRed), style: StrokeStyle(lineWidth: 3))
                }
                let label = "🎯 \(lt.rawName) LOCK"
                let r = ctx.resolve(Text(label).font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(.black))
                let m = r.measure(in: size)
                let capW = m.width + 12
                let capH = m.height + 4
                let capX = min(max(box.minX, 4), max(4, size.width - capW - 4))
                let capY = max(box.minY - 18 - m.height - 4, 4)
                let cap = CGRect(x: capX, y: capY, width: capW, height: capH)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 3), with: .color(Theme.orangeRed))
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
                guard let buf,
                      let engine = self.engine,
                      let cg = Self.cgImage(from: buf) else {
                    frameLock.lock()
                    self.isDraining = false
                    frameLock.unlock()
                    return
                }
                engine.ingest(cgImage: cg)
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
// MARK: - 文件 7: SidebarView.swift  (右侧毛玻璃侧边栏)
// ============================================================================

struct SidebarView: View {
    @Bindable var state: DriveState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                StatusPanel(state: state)
                ControlPanel(state: state)
                ConfigPanel(state: state)
                TrainingPanel(state: state)
                GameMapCard(state: state)
                AutomationInlinePanel()
                LogViewerPanel()
            }
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.55))       // 毛玻璃
        .background(Color.black.opacity(0.55))
    }
}

/// 自动化功能内联面板（替代原抽屉式，直接在 sidebar 里展示，无图层问题）
struct AutomationInlinePanel: View {
    private let functions = AutomationLibrary.functions
    @State private var running = Set<UUID>()

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "AUTOMATION")
                VStack(spacing: 6) {
                    ForEach(functions) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if running.contains(item.id) {
                                    running.remove(item.id)
                                } else {
                                    running.insert(item.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Text(item.emoji).font(.system(size: 15))
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if item.warn {
                                    Text("最凶")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.danger)
                                }
                                Circle()
                                    .fill(running.contains(item.id) ? Theme.cyan : Color.white.opacity(0.15))
                                    .frame(width: 7, height: 7)
                                    .shadow(color: running.contains(item.id) ? Theme.cyan : .clear, radius: 5)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(running.contains(item.id) ? Theme.cyan.opacity(0.08) : Color.white.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(running.contains(item.id) ? Theme.cyan.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}


// ============================================================================
// MARK: - 文件 8: StatusPanel.swift  (状态面板)
// ============================================================================

struct StatusPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "STATUS")

                // 驾驶模式：内部 4 档合并为 2 个用户可见档位（端到端主驾 / 规则）
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(DriveModeGroup.allCases) { g in
                        ModeGroupChip(group: g, active: state.isDriving && g.contains(state.mode))
                    }
                }

                // 置信度
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("置信度")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f%%", state.confidence * 100))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.cyan)
                    }
                    ConfidenceBar(value: state.confidence)
                }

                // 车速 + FPS + 禁用控制开关
                HStack(alignment: .center, spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(state.speedKmh >= 0 ? String(format: "%.0f", state.speedKmh) : "--")
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: Theme.cyan.opacity(0.45), radius: 12)
                            .contentTransition(.numericText())
                        Text("km/h")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    // 禁用控制：人开 + 模型检测辅助（不注入 AI 键）
                    Button {
                        state.controlDisabled.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: state.controlDisabled ? "hand.raised.fill" : "hand.raised")
                                .font(.system(size: 10, weight: .bold))
                            Text(state.controlDisabled ? "控制已禁" : "禁用控制")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(state.controlDisabled ? .black : Theme.textSecondary)
                        .background(
                            state.controlDisabled
                                ? AnyShapeStyle(Theme.orangeRed)
                                : AnyShapeStyle(Theme.bgCard)
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                state.controlDisabled ? Theme.orangeRed : Theme.textTertiary.opacity(0.35),
                                lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(state.controlDisabled
                          ? "已禁用 AI 控制：模型仅检测画面，人工驾驶"
                          : "禁用 AI 控制：模型只检测画面，不注入按键（人工驾驶）")
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f", state.fps))
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                        Text("FPS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }
}

/// 驾驶模式分组芯片（2 个用户可见档位：端到端主驾 / 规则）。
/// 组内任一内部档位处于当前 mode 时整组高亮。
struct ModeGroupChip: View {
    let group: DriveModeGroup
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: group.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(group.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(group.desc)
                .font(.system(size: 9, weight: .regular))
                .lineLimit(2)
                .opacity(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .foregroundStyle(active ? .black : Theme.textSecondary)   // 高亮时深色字压在亮青底上
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Theme.cyan : Color.white.opacity(0.05))
                .shadow(color: active ? Theme.cyan.opacity(0.8) : .clear, radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? .clear : Color.white.opacity(0.09), lineWidth: 1)
        )
        .animation(.spring(response: 0.3), value: active)
    }
}

struct ConfidenceBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.cyanDim, Theme.cyan],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * value))
                    .shadow(color: Theme.cyan.opacity(0.9), radius: 8)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}


// ============================================================================
// MARK: - 文件 9: ControlPanel.swift  (控制按钮)
// ============================================================================

struct ControlPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(spacing: 14) {
                // CONTROL 标题行 + 右侧「紧急切纯规则」胶囊小开关（同排省空间）
                // 开启：强制停在纯规则兜底档（M9 推理停跑省资源），直到手动关闭
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.cyan)
                        .frame(width: 3, height: 12)
                        .shadow(color: Theme.cyan, radius: 4)
                    Text("CONTROL")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(2.5)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            state.forceRuleMode.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: state.forceRuleMode ? "shield.fill" : "shield")
                                .font(.system(size: 10, weight: .bold))
                            Text("纯规则")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(state.forceRuleMode ? .white : Theme.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(state.forceRuleMode ? Theme.danger : Theme.cyan.opacity(0.15))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(state.forceRuleMode ? Theme.danger : Theme.cyan.opacity(0.6),
                                              lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(state.forceRuleMode
                          ? "已强制纯规则兜底（M9 停推理），点击恢复自动"
                          : "紧急切纯规则：一键强制规则兜底，M9 停推理（游戏鼠标点不过去时的应急开关）")
                }

                // 启动自动驾驶(大按钮)
                // 启动时同时开启截屏画面流，停止时关闭
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        if state.isDriving {
                            state.stopDriving()
                        } else {
                            state.startDriving()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: state.isDriving ? "stop.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(state.isDriving ? "停止自动驾驶" : "启动自动驾驶")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .tracking(0.5)
                    }
                    .foregroundStyle(state.isDriving ? .white : .black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(state.isDriving
                                  ? LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                                   startPoint: .top, endPoint: .bottom)
                                  : LinearGradient(colors: [Theme.cyan, Theme.cyan.opacity(0.75)],
                                                   startPoint: .top, endPoint: .bottom))
                            .shadow(color: state.isDriving ? .clear : Theme.cyan.opacity(0.65), radius: 18)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(state.isDriving ? Theme.danger.opacity(0.7) : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)

                // 极速模式(橙红开关)
                HStack {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.sportMode ? Theme.orangeRed : Theme.textTertiary)
                        .shadow(color: state.sportMode ? Theme.orangeRed : .clear, radius: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("极速模式")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("解除限速,全速冲刺")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $state.sportMode)
                        .toggleStyle(.switch)
                        .tint(Theme.orangeRed)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)
            }
        }
    }
}


// ============================================================================
// MARK: - 文件 10: ConfigPanel.swift  (配置面板)
// ============================================================================

struct ConfigPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(spacing: 16) {
                SectionHeader(title: "CONFIG")

                SettingSlider(title: "速度上限",
                              valueText: String(format: "%.0f km/h", state.speedLimit),
                              value: $state.speedLimit, range: 40...200, step: 5)

                SettingSlider(title: "降级阈值",
                              valueText: String(format: "%.2f", state.degradeThreshold),
                              value: $state.degradeThreshold, range: 0.3...0.9, step: 0.01)

                SettingRow(icon: "sparkles", title: "显示插帧",
                           subtitles: ["MetalGoose MGFG-1 · 仅影响预览观感",
                                       "游戏很卡时，可短暂看着预览框的插帧画面撑过关卡"],
                           isActive: { state.upscaleEnabled }, activeColor: Theme.cyan,
                           shadow: false,
                           binding: Binding(get: { state.upscaleEnabled },
                                            set: { state.setUpscaleEnabled($0) }),
                           disabled: !state.upscaleSupported)

                SettingRow(icon: "bolt.badge.a", title: "游戏模式兼容",
                           subtitles: ["捕获线程时间约束调度 · 对抗全屏游戏降权",
                                       "游戏全屏卡成 1 帧时开着它；游戏掉帧就关"],
                           isActive: { state.gameModeBoost }, activeColor: Theme.cyan,
                           shadow: false,
                           binding: Binding(get: { state.gameModeBoost },
                                            set: { state.setGameModeBoost($0) }),
                           disabled: false)

                HStack {
                    Image(systemName: "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.isRecording ? Theme.danger : Theme.textTertiary)
                    Text("行驶录制")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("", isOn: $state.isRecording)
                        .toggleStyle(.switch)
                        .tint(Theme.cyan)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.cyan)
                .shadow(color: Theme.cyan.opacity(0.5), radius: 4)
        }
    }
}


// ============================================================================
// SettingRow：配置行（图标 + 标题 + 副标题 + Toggle）
// ============================================================================

struct SettingRow: View {
    let icon: String
    let title: String
    let subtitles: [String]
    let isActive: () -> Bool
    let activeColor: Color
    let shadow: Bool
    let binding: Binding<Bool>
    let disabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive() ? activeColor : Theme.textTertiary)
                .shadow(color: shadow && isActive() ? activeColor : .clear, radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(0..<subtitles.count, id: \.self) { i in
                    Text(subtitles[i])
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .tint(activeColor)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 4)
    }
}


// ============================================================================
// MARK: - 文件 11: TrainingPanel.swift  (训练控制)
// ============================================================================

struct TrainingPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(spacing: 12) {
                SectionHeader(title: "TRAINING")

                // 专家模式：录制来源切到真人物理键（模仿学习的专家演示标签）
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.expertMode ? Theme.cyan : Theme.textTertiary)
                    Text("专家模式（录真人键）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("", isOn: $state.expertMode)
                        .toggleStyle(.switch)
                        .tint(Theme.cyan)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)

                // 字模模式：录制时输出原生速度表帧（供字模训练，不缩成 640×360 训练帧）
                HStack(spacing: 10) {
                    Image(systemName: "number.square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.glyphMode ? Theme.cyan : Theme.textTertiary)
                    Text("字模模式（录原生速度表）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    // 录制中此开关不生效（glyphMode 在 start() 时一次性读取），可点但不热切换。
                    Toggle("", isOn: $state.glyphMode)
                        .toggleStyle(.switch)
                        .tint(Theme.cyan)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)
                if !state.trainingLog.isEmpty {
                    Text(state.trainingLog)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    // 录制按钮
                    TrainButton(
                        title: state.isRecording ? "录制中" : "录制",
                        icon: "record.circle",
                        tint: Theme.danger,
                        filled: state.isRecording
                    ) { state.isRecording.toggle() }

                    // 训练按钮
                    TrainButton(
                        title: state.isTraining ? "训练中…" : "训练",
                        icon: "cpu",
                        tint: Theme.cyan,
                        filled: state.isTraining
                    ) { state.startTraining() }
                }

                // 模型版本
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text("模型版本")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(state.modelVersion)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

struct TrainButton: View {
    let title: String
    let icon: String
    let tint: Color
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(filled ? .black : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.10))
                    .shadow(color: filled ? tint.opacity(0.6) : .clear, radius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0 : 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ============================================================================
// MARK: - LogViewerPanel (日志查看面板)
// ============================================================================

/// 日志查看面板：显示 /tmp/aurora_debug.log 的最新内容
struct LogViewerPanel: View {
    @State private var logContent: String = "日志未加载"
    @State private var isExpanded: Bool = false
    @State private var autoRefresh: Bool = false
    @State private var refreshTimer: Timer?

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 10) {
                // 标题栏
                HStack {
                    SectionHeader(title: "DEBUG LOG")
                    Spacer()
                    // 自动刷新开关
                    Toggle("", isOn: $autoRefresh)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .onChange(of: autoRefresh) { _, enabled in
                            if enabled {
                                startAutoRefresh()
                            } else {
                                stopAutoRefresh()
                            }
                        }
                    // 手动刷新按钮
                    Button {
                        loadLog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.cyan)
                    }
                    .buttonStyle(.plain)
                    // 展开/收起按钮
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    // 日志内容区域
                    ScrollView(.vertical) {
                        Text(logContent)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 200)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.cyan.opacity(0.2), lineWidth: 1)
                    )

                    // 底部操作按钮
                    HStack(spacing: 8) {
                        Button("清空日志") {
                            clearLog()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.danger.opacity(0.1))
                        )
                        .buttonStyle(.plain)

                        Button("在 Finder 中显示") {
                            showInFinder()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.cyan.opacity(0.1))
                        )
                        .buttonStyle(.plain)

                        Spacer()

                        Text(autoRefresh ? "自动刷新中..." : "")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.cyan.opacity(0.6))
                    }
                }
            }
        }
        .onAppear {
            loadLog()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    private func loadLog() {
        let logPath = "/tmp/aurora_debug.log"
        if let content = try? String(contentsOfFile: logPath, encoding: .utf8) {
            // 只显示最后 200 行
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let lastLines = lines.suffix(200)
            logContent = lastLines.joined(separator: "\n")
        } else {
            logContent = "日志文件不存在或无法读取\n路径: \(logPath)"
        }
    }

    private func clearLog() {
        let logPath = "/tmp/aurora_debug.log"
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        logContent = "日志已清空"
    }

    private func showInFinder() {
        let logPath = "/tmp/aurora_debug.log"
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            loadLog()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
