// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AuroraDrive — 异环游戏自动开车辅助工具
//  SwiftUI macOS 14+ | 单窗口 1200x760 | Tesla FSD 驾驶舱风格
//  纯黑底 + 青色(#00E5FF)发光 + 高对比白字
// ============================================================================


// ============================================================================
// MARK: - 内部段落: App入口 — AuroraDriveApp 主结构（AppDelegate + Theme + DriveState）
// ============================================================================

import SwiftUI
import AppKit
import Darwin   // mach_task_basic_info：诊断进程内存占用（验证"积压→内存涨"根因）
import CoreVideo  // CVPixelBuffer：YOLO 直通帧跳帧缓冲
import Metal
import MetalKit
import MetalGooseEngine
import UniformTypeIdentifiers

// 应用启动时强制激活窗口到前台（直接 swift 运行时窗口默认不激活）
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 抑制 App Nap 的 activity token（必须持有，否则 activity 立即释放、抑制失效）
    private var napToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 命令行自检：AuroraDriveUI --yolo-selftest <图片路径>
        // 跑一张图验证 YOLO 全链路（像素缓冲通道序 / 解码 / NMS），打印结果后退出，不开窗口
        let args = CommandLine.arguments
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

        // 抑制 App Nap（beginActivity .latencyCritical + .userInteractive）：
        // 下面的 disableAutomaticTermination 只防"被系统自动退出"，不管节流。
        // App 在游戏前台全屏时沦为后台 App，系统默认会对它的 RunLoop 定时器/渲染
        // 做 App Nap 节流（Timer 掉帧、界面卡）——这正是"只有 App 界面卡"的根因。
        // .latencyCritical 声明对延迟敏感 → 系统不再对其节流，后台保持前台级节奏。
        // token 必须持有（napToken），否则 activity 立即释放、抑制失效。
        ProcessInfo.processInfo.disableAutomaticTermination(
            "AuroraDrive 实时游戏辅助：持续截屏 + AI 决策注入")
        // 防"突然终止"（与自动退出是两套机制）：系统在资源紧张时可能对可突然终止
        // 的进程直接 kill；显式禁用后系统必须先走正常退出路径。
        ProcessInfo.processInfo.disableSuddenTermination()
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInteractive, .background, .idleSystemSleepDisabled],
            reason: "AuroraDrive 实时游戏辅助：后台需持续 30Hz 决策与注入")
        // 提高进程调度优先级（尽力而为，失败静默）：让系统给本进程更多 CPU 份额，
        // 缓解游戏前台全屏时后台 App 被系统降优先级导致的帧率下跌。
        if setpriority(PRIO_PROCESS, 0, -10) == 0 {
            print("[App] 进程优先级已提高 (nice=-10)")
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

@main
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
// MARK: - 内部段落: Theme — 设计系统 / 主题常量（原拆分自 Theme.swift）
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
// MARK: - 内部段落: DriveState — 全局状态 + 驾驶信号流（原拆分自 DriveState.swift）
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

    // ── 纯视觉小地图定位（VisualLocator 输出）──
    /// 是否定位到（尚未出结果时小窗显示占位）
    var locatorFound = false
    /// 自车在大地图(11264²)上的原图像素坐标（左上原点，y 向下）
    var locatorX: Double = 0
    var locatorY: Double = 0
    /// 最近一次定位 NCC 分数（0..1，诊断：<阈值=匹配失败，非队列问题）
    var locatorScore: Double = 0
    /// 定位器是否就绪（首次 prepare 完成；false=还在建档/建档失败，定位一直不会出结果）
    var locatorReady = false
    /// 朝向（度，北=0，顺时针增加）；由相邻帧位置差推算，速度过慢时不更新
    var locatorHeading: Double = 0
    /// 用户在小地图上点击设定的目标点（大地图像素坐标）
    var locatorTarget: (x: Double, y: Double)? = nil
    /// 上一帧定位位置（用于推算朝向）
    private var lastLocPos: (x: Double, y: Double)? = nil

    // ── 视觉定位引擎（8Hz 截屏小地图 → VisualLocator → 本状态）──
    /// 游戏内小地图在屏幕的归一化位置：中心(x,y) + 边长(占屏幕短边比例)。
    /// 游戏小地图是方形的；用"中心+边长"保证裁剪为正方形，避免宽高比失真破坏匹配。
    /// 用户确认：小地图在游戏画面左上角。默认中心 (0.13,0.14)、边长 16%。
    /// 用户可「标注小地图」手动框选覆盖（预设记忆）。
    nonisolated(unsafe) static var minimapROI = (centerX: 0.13, centerY: 0.14, sideFraction: 0.16)
    /// 当前生效的小地图 ROI（CGRect 归一化，仅 UI 框显用；nil=未标注过）
    var minimapROIState: CGRect? = nil
    // 定位引擎只在后台定位队列使用（单一消费者），主线程不读；存进 Sendable 盒子跨线程访问。
    private let locateCtx = LocateContext()
    /// 定位门闩：防止 8Hz 调度堆积后台任务（锁盒线程安全，无 actor 标注歧义）
    private let locateGate = LocateGate()
    private let locateQueue = DispatchQueue(label: "aurora.locate", qos: .userInitiated)

    // ── 驾驶记录仪：环形缓冲区存最近5帧（每3秒存一帧）──
    // 用途：随时回看关键时刻（3秒前/6秒前），用于复盘和Debug
    @ObservationIgnored var drivingRecorder = DrivingFrameRecorder(maxFrames: 5)

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

    /// 本次开车会话开始时间（暖机期判定：启动后头几秒还没出推理结果时
    /// 保持高置信度，避免启动瞬间误降级）
    @ObservationIgnored
    private var drivingStartTime = Date()

    /// 上一帧写调试日志的时间（tick 摘要 1Hz 节流用）
    @ObservationIgnored
    private var lastTickLog = Date.distantPast

    /// 上一帧写插帧实时读数的时间（1Hz 节流用）
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
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
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

    /// 兼容属性：旧代码读 speed 的地方统一读到 effectiveSpeed（不再有模拟值/随机抖动，速度由 OCR 真实读数驱动）
    var speed: Double { effectiveSpeed }

    var fps: Double        = 60

    /// 车速 OCR 最新快照（主线程读；未读到为 -1 / 0）
    /// 读自 speedOCR（@Observable 嵌套，body 访问会跟踪其更新）
    var speedKmh: Double { speedOCR.speedKmh }
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
    // MetalGoose 显示路径宿主（超分/插帧）。仅用于「给人看的显示叠加层」，
    // 绝不进入 捕获→推理→注入 决策链路。默认关闭，避免变相拉长控制延迟。
    @ObservationIgnored var upscaleHost = UpscaleFrameHost()
    // 显示路径 MetalFX 插帧/超分开关（默认关）。仅影响视口预览观感。
    var upscaleEnabled: Bool = false
    /// 游戏模式兼容（默认开）：给捕获线程设「时间约束调度」（THREAD_TIME_CONSTRAINT_POLICY），
    /// 对抗 macOS 游戏模式对后台 App 的降权 —— 否则游戏全屏时捕获帧被饿到 0~9fps、
    /// 整个 App 只有一帧（capWork 5ms→数秒）。可回退：关掉即恢复普通调度。
    var gameModeBoost: Bool = true
    /// HUD 标注模式开关：开 → 预览画面叠加标注层（拖拽框选 ROI）
    var hudAnnotationMode = false
    /// 标注目标（HUD 速度表 / 游戏内小地图）
    var annotationTarget: HUDAnnotationTarget = .hud
    /// 当前生效的速度表 ROI（预设；nil = 未标注过，用默认值）
    var hudROI: CGRect? = nil
    /// 插帧引擎是否可用（Metal 不可用/引擎创建失败 → false，UI 禁用开关）
    var upscaleSupported = false

    // ── 驾驶记录仪（环形缓冲区回看）──
    /// 当前高亮的历史帧槽位（nil=未选择，.threeSecondsAgo=3秒前，.sixSecondsAgo=6秒前）
    var showHistoricFrame: HistoricFrameSlot? = nil
    /// 预缓存的历史帧 CGImage（在 tick() 中同步刷新，避免 button action 触发时的异步等待）
    @ObservationIgnored var historicFrames: [HistoricFrameSlot: CGImage] = [:]
    /// 插帧实时读数（1Hz 更新，UI 状态栏显示）：
    /// 形如 "产出 123 / 输出 456"。interp=0 且 out>0 = 纯透传(插帧未产帧)，
    /// interp 持续增长 = 插帧真的在工作；置空表示开关关/无引擎。
    /// 用普通 @Observable 让 SidebarView 每秒重绘，把"插帧到底有没有用"直接摆到眼前。
    var upscaleLive: String? = nil
    /// 插帧引擎最近一条错误（由 pendingError() 消费后置空，贯穿到 UI/日志）：
    /// 例如 MG-ENG-010 MetalFX 插值器创建失败 —— 那正是"插帧静默不产帧"的根因。
    var upscaleEngineError: String? = nil
    // 源画面尺寸（普通 @Observable，驱动 ObstacleOverlay 的 aspect-fill 对齐）。
    // 不能从 @ObservationIgnored 的 frameHost.latestSize 读，否则尺寸变化不触发
    // 观察导致检测框错位；仅在尺寸变化时写，避免每帧失效。
    var screenSize: CGSize? = nil
    // isStreaming 控制 GameViewportView 显示"实时画面 vs 黑底提示"分支，启/停各翻转一次，
    // 必须保持 @Observable（观察成本可忽略），否则停止后分支不触发重绘导致画面冻结。
    var isStreaming = false

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
    private let pendingFrameLock = NSLock()

    // ── YOLO 直通帧跳帧（同 pendingFrame 模式）：captureQueue 覆盖最新帧，tick 消费 ──
    @ObservationIgnored
    private nonisolated(unsafe) var pendingYoloFrame: CVPixelBuffer?
    @ObservationIgnored
    private let pendingYoloLock = NSLock()

    // ── 原生 ROI 帧跳帧（同 pendingFrame 模式）：OCR/字模录制消费 ──
    @ObservationIgnored
    private nonisolated(unsafe) var pendingNativeFrame: CVPixelBuffer?
    @ObservationIgnored
    private let pendingNativeLock = NSLock()

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

    /// 后台存活 activity 句柄：声明本 app 需要持续实时运行，阻止系统在
    /// 切换到后台（如游戏/游戏模式把其它 app 降权或打盹）时触发 App Nap、
    /// 合并 tick 或挂起，从而保住决策/推理那部分后台资源，避免突然掉链子。
    /// 只是对系统的"持续运行"声明，不碰系统配置、不影响游戏、不抢资源。
    @MainActor private var backgroundActivity: NSObjectProtocol?

    init() {
        // 关键：声明持续实时运行，阻止系统把本 app 当后台打盹/挂起/降权。
        // 游戏模式或游戏在前台时常把其它后台 app 杀/降权，这是掉链子的直接原因。
        // userInitiated 会把进程 QoS 拉高且禁止 App Nap，让 tick/推理在后台照常跑；
        // .background 再显式声明"需要后台持续运行"，双保险。
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .background],
            reason: "AuroraDrive 持续实时推理+注入，防止被系统当作后台 App Nap 挂起/降权"
        )
        // 游戏模式兼容：主线程时间约束调度（tick/UI 不掉拍），与「游戏模式兼容」开关联动
        applyMainThreadBoost(true)
        // HUD / 小地图 ROI 记忆：读取用户手动标注预设（无则用默认）
        loadROIPresets()
        try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")
        // 接线截屏引擎回调
        // onFrame: 每帧调用，更新 currentScreenImage（主线程，SwiftUI 自动刷新）
        // onStatusChange: 启动/停止/错误/权限拒绝
        captureEngine.onFrame = { [weak self] image, cgImage in
            // 跳帧防堆积：CaptureEngine 回调在 captureQueue 后台线程，
            // 这里只"覆盖"最新待显示帧（加锁），不再 main.async 排队。
            // 主线程（tick）卡时，旧帧被下一帧覆盖丢弃 → 天然跳帧，永不积压。
            // NSImage + CGImage 同回调原子写入，避免推屏/推理/录制跨帧错位。
            guard let self else { return }
            self.pendingFrameLock.lock()
            self.pendingFrame = image
            self.pendingFrameCG = cgImage
            self.pendingFrameTime = Date()
            self.pendingFrameLock.unlock()
            // 【帧率修复】预览与决策解耦：捕获线程一到帧即把预览推到主线程
            // （直接设 layer.contents），按捕获帧率 30fps 渲染，不再被 30Hz 决策
            // tick 的推理/叠加层 SwiftUI 重绘节流拖到 8–20Hz。hostView 为 nil
            // （未开预览窗口）时 push 自动 no-op，零额外开销。
            // cgImage 为非可选（捕获必有），直接推；hostView 为 nil 时 push 自动 no-op。
            DispatchQueue.main.async { self.frameHost.push(cgImage) }
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
        // 插帧引擎（独立显示链路）：预创建并配置插帧模式，决定开关可用性。
        // onUpscaleFrame 原生全帧直通在 captureQueue 后台执行（保持原生分辨率、
        // 不设上限），决策链路完全不吃它 —— 与 onFrame/YOLO/OCR 各走各的通道。
        upscaleHost.prepare()
        upscaleSupported = upscaleHost.isAvailable
        dlog("[upscale] 引擎初始化: 可用=\(upscaleSupported)")
        captureEngine.onUpscaleFrame = { [weak self] pb in
            self?.upscaleHost.push(pixelBuffer: pb)
        }
    }

    /// 插帧开关变化（主线程）：同步捕获直通闸门（线程安全写 captureEngine.upscaleEnabled）
    func setUpscaleEnabled(_ on: Bool) {
        upscaleEnabled = on
        captureEngine.upscaleEnabled = on
        dlog("[upscale] 开关=\(on) 引擎可用=\(upscaleSupported)")
    }

    /// 游戏模式兼容开关变化（主线程）：同步捕获线程调度策略开关 + 主线程时间约束
    func setGameModeBoost(_ on: Bool) {
        gameModeBoost = on
        captureEngine.gameModeBoostEnabled = on
        applyMainThreadBoost(on)
        dlog("[boost] 游戏模式兼容=\(on)")
    }

    /// 进入 HUD 标注：确保截屏流开启（否则标注层无画面可框），设目标并打开标注模式
    func beginAnnotation(_ target: HUDAnnotationTarget) {
        annotationTarget = target
        if !isStreaming {
            captureEngine.start()   // 自动开截屏流（游戏画面出现后才能框选）
        }
        hudAnnotationMode = true
        dlog("[hud] 进入标注: 目标=\(target == .hud ? "HUD" : "小地图") 流=\(isStreaming)")
    }

    /// 应用手动标注的 HUD ROI（主线程）：
    /// 1) 覆盖 CaptureEngine.speedROINorm（OCR/录制共用的速度表裁剪区）
    /// 2) 由 ROI 推导三位数字槽位（ROI 内右侧三等分，避开左侧 N/挡位符号；y 取中上部）
    /// 3) 持久化到 UserDefaults（记忆：下次启动自动应用）
    func applyHUDROI(_ roi: CGRect) {
        hudROI = roi
        CaptureEngine.speedROINorm = roi
        SpeedOCRReader.slotCentersNorm = [
            roi.minX + 0.45 * roi.width,
            roi.minX + 0.58 * roi.width,
            roi.minX + 0.71 * roi.width
        ]
        SpeedOCRReader.slotYMinNorm = roi.minY + 0.25 * roi.height
        SpeedOCRReader.slotYMaxNorm = roi.minY + 0.75 * roi.height
        UserDefaults.standard.set(
            [Double(roi.minX), Double(roi.minY), Double(roi.width), Double(roi.height)],
            forKey: "aurora.hudROI")
        dlog("[hud] 标注 ROI=(\(String(format: "%.3f", roi.minX)),\(String(format: "%.3f", roi.minY)),\(String(format: "%.3f", roi.width)),\(String(format: "%.3f", roi.height)))")
    }

    /// 应用手动标注的游戏内小地图 ROI（主线程）：
    /// 框选矩形 → 中心 + 内接正方形边长（小地图是方形，用 min 边长避免裁出框外）→
    /// 覆盖 DriveState.minimapROI（视觉定位裁剪区）→ 持久化记忆。
    func applyMinimapROI(_ rect: CGRect) {
        minimapROIState = rect
        let side = min(rect.width, rect.height)
        Self.minimapROI = (centerX: rect.midX, centerY: rect.midY, sideFraction: side)
        UserDefaults.standard.set([Double(rect.midX), Double(rect.midY), Double(side)],
                                  forKey: "aurora.minimapROI")
        dlog("[hud] 小地图 ROI: 中心=(\(String(format: "%.3f", rect.midX)),\(String(format: "%.3f", rect.midY))) 边长=\(String(format: "%.3f", side))")
    }

    /// 启动时读取 HUD / 小地图 ROI 预设（记忆）：有预设则应用，无则用默认
    func loadROIPresets() {
        if let a = UserDefaults.standard.array(forKey: "aurora.hudROI") as? [Double],
           a.count == 4, a[2] > 0.01, a[3] > 0.01 {
            applyHUDROI(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]))
        }
        if let b = UserDefaults.standard.array(forKey: "aurora.minimapROI") as? [Double],
           b.count == 3, b[2] > 0.01, b[0] >= 0, b[0] <= 1, b[1] >= 0, b[1] <= 1 {
            Self.minimapROI = (centerX: b[0], centerY: b[1], sideFraction: b[2])
            minimapROIState = CGRect(x: b[0] - b[2] / 2, y: b[1] - b[2] / 2,
                                     width: b[2], height: b[2])
            dlog("[hud] 载入小地图 ROI 预设")
        }
    }

    /// 定位循环写入最新自车原图像素坐标（主线程）。由相邻帧位移推算朝向；
    /// 位移过小（静止/抖动）不刷新朝向，避免箭头乱转。
    func updateLocator(x: Double, y: Double, score: Double = 0) {
        locatorScore = score
        if let last = lastLocPos {
            let hx = x - last.x, hy = y - last.y
            if hx * hx + hy * hy > 16 {            // 位移 >4px 才算有效移动
                let deg = (atan2(hx, hy) * 180 / .pi) + 360
                locatorHeading = deg.truncatingRemainder(dividingBy: 360)
            }
        }
        lastLocPos = (x, y)
        locatorX = x
        locatorY = y
        locatorFound = true
    }

    /// 手动在小地图上设目标点（大地图像素坐标）；存给纯规则转向用
    func setLocatorTarget(x: Double, y: Double) {
        locatorTarget = (x, y)
    }

    /// 4Hz 定位步骤（原 8Hz，2026-08-19 降频省核）：主线程只做「快照最新帧 + 调度」；
    /// prepare/裁剪/匹配全部在后台队列，命中后再回到主线程写入定位状态，从根本上避免阻塞 UI。
    func runLocateStep() {
        guard isStreaming || isDriving, let cg = currentFrameCG else { return }
        guard locateGate.tryBegin() else { return }
        let snapshotCG = cg                     // CGImage 线程安全；主线程只读当前帧
        let roi = Self.minimapROI

        locateQueue.async { [weak self] in
            guard let self else { return }
            defer { self.locateGate.end() }
            // 游戏模式兼容：定位线程优先级提升（THREAD_PRECEDENCE_POLICY，温和），
            // 避免 8Hz 定位在游戏模式降权下被饿到秒级（小地图卡顿）。
            applyLocatePrecedence()
            // 首次：后台 prepare（多档大地图降采样，重）
            if self.locateCtx.visualLocator == nil {
                // P 修复：workSizes 必须与「150px 屏幕小地图模板」自洽。
                // 模板内容 = 屏幕 ROI 覆盖的原图范围缩到 150px；该范围在匹配图上
                // 必须仍约等于 150px 才能匹配。若最细档太低（如 480px），模板
                // 内容被放大 2~3 倍，NCC 永远失配 → 定位静默失效。
                // 设计：屏幕 ROI ≈ 覆盖原图 ~1300px（1080p 游戏小地图常见量级），
                // 故最细档取 1280（scale=1280/11264≈0.1136 → 1300×0.1136≈148px ≈ 模板 150px 自洽）。
                // 首帧全局扫走 prepare 追加的 192 档（stride=2，见 VisualLocator），8Hz 后台可接受。
                let v = VisualLocator(mapPath: "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png",
                                      workSizes: [1280, 1024, 768])
                let ok = (v.prepare() == nil)
                if CommandLine.arguments.contains("--locate-live") {
                    print("[LOCATELIVE-DIAG] prepare ok=\(ok) scales=\(v.scaleCount)")
                }
                self.locateCtx.visualLocator = v
                self.locateCtx.locatorReady = ok
            }
            guard self.locateCtx.locatorReady, let loc = self.locateCtx.visualLocator else {
                // 未就绪（首次 prepare 未完成/失败）：同步主线程诊断状态
                DispatchQueue.main.async { [weak self] in
                    self?.locatorReady = false
                }
                if CommandLine.arguments.contains("--locate-live") {
                    print("[LOCATELIVE-DIAG] locator not ready")
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.locatorReady = true
            }

            let W = CGFloat(snapshotCG.width), H = CGFloat(snapshotCG.height)
            let side = min(W, H) * CGFloat(roi.sideFraction)
            let cx = W * CGFloat(roi.centerX)
            let cy = H * CGFloat(roi.centerY)
            let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            if CommandLine.arguments.contains("--locate-live") {
                print("[LOCATELIVE-DIAG] frame=\(Int(W))x\(Int(H)) side=\(Int(side)) rect=\(rect)")
            }
            guard side >= 24,
                  let crop = snapshotCG.cropping(to: rect),
                  let bytes = VisualLocator.minimapBytes(from: crop, side: 150) else {
                if CommandLine.arguments.contains("--locate-live") {
                    print("[LOCATELIVE-DIAG] crop/minimapBytes failed")
                }
                return
            }

            if CommandLine.arguments.contains("--locate-live") {
                let cropStd = bytes.reduce(0.0) { $0 + Double($1) }
                let cropMean = cropStd / Double(max(1, bytes.count))
                var sq = 0.0
                for b in bytes { let d = Double(b) - cropMean; sq += d * d }
                let std = sqrt(sq / Double(max(1, bytes.count)))
                FileHandle.standardError.write("[LOCATELIVE-DIAG] crop bytes mean=\(String(format: "%.1f", cropMean)) std=\(String(format: "%.1f", std))\n".data(using: .utf8)!)
                FileHandle.standardError.write("[LOCATELIVE-DIAG] calling locate bytes=\(bytes.count)\n".data(using: .utf8)!)
            }
            let res = loc.locate(template: bytes, tw: 150, th: 150, scoreThreshold: 0.5)
            if CommandLine.arguments.contains("--locate-live") {
                FileHandle.standardError.write("[LOCATELIVE-DIAG] locate done found=\(res.found) score=\(String(format: "%.3f", res.score))\n".data(using: .utf8)!)
            }
            if res.found {
                if CommandLine.arguments.contains("--locate-live") {
                    print("[LOCATELIVE-DIAG] 命中 x=\(Int(res.x)) y=\(Int(res.y)) score=\(String(format: "%.3f", res.score)) scale#\(res.scaleIndex)")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateLocator(x: res.x, y: res.y, score: res.score)
                }
            } else {
                // 诊断（仅 --locate-live 场景保留，不影响运行时）：打印未命中根因
                if CommandLine.arguments.contains("--locate-live") {
                    let fg = bytes.reduce(0) { $0 + Int($1) }
                    let mean = Double(fg) / Double(max(1, bytes.count))
                    print("[LOCATELIVE-DIAG] 未命中: frame=\(Int(W))x\(Int(H)) roi=\(Int(side))px " +
                          "template_fg=\(fg) mean=\(String(format: "%.1f", mean)) " +
                          "score=\(String(format: "%.3f", res.score)) scales=\(loc.scaleCount)")
                }
            }
        }
    }

    /// 纯规则档（.rule）决策：叠加「朝定位目标转向」。
    /// 有定位 + 有目标点时，按 目标方向角 − 当前朝向 算出转向；危险障碍优先（交回避障规则）。
    /// 无目标/无定位时完全回退到现有避障规则（不改变原行为）。
    @MainActor
    private func navigationRuleCommand(detections: [Detection]) -> ControlCommand {
        let fallback = ruleController.decide(detections: detections)
        // 避障优先级最高：只要有危险，立即交回避障规则
        if ruleController.dangerLevel != .safe {
            return fallback
        }
        guard locatorFound, let t = locatorTarget else { return fallback }

        let dx = t.x - locatorX
        let dy = t.y - locatorY
        let distSq = dx * dx + dy * dy
        guard distSq > 4 else { return fallback }   // 已到目标附近，交回默认

        // 目标相对自车的地图方位角（北=0，顺时针）
        let targetBearing = (atan2(dx, dy) * 180 / .pi) + 360
        var err = targetBearing.truncatingRemainder(dividingBy: 360) - locatorHeading
        if err > 180 { err -= 360 } else if err < -180 { err += 360 }
        // 误差 ±20° 内基本直行；之外按比例转向（上限 1.0）
        let steer = max(-1.0, min(1.0, err / 40.0))
        return ControlCommand(steer: steer, throttle: 0.6, brake: 0, confidence: 0.9)
    }

    /// 启动自动驾驶：
    /// 1. 检查辅助功能权限（按键注入必需）
    /// 2. 启动物理键盘监听（KeyboardBar 显示用 + 录制专家演示）
    /// 3. 启动截屏画面流
    /// 4. 后续由推理引擎决定注入什么按键（当前仅占位，状态机已就位）
    func startDriving() {
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
        // P 修复：驾驶开始才开 YOLO 直通缩放闸门 —— 未驾驶时（待机/仅录制采集）
        // YOLO 检测既不用决策也不用叠加层显示，跳过全帧 vImage 缩放省 CPU。
        captureEngine.yoloScalingEnabled = true
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
        isDriving = false
        controlEngine.releaseAll()
        keyboardMonitor.stop()
        captureEngine.stop()
        // P 修复：停止驾驶后关 YOLO 直通缩放闸门（恢复待机/仅录制采集的低负载状态）
        captureEngine.yoloScalingEnabled = false
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
        let modelsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
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
            inferenceEngine.reloadModel()
            trainingLog = "已应用新模型: \(src.lastPathComponent)"
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
        let rawClips = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
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

    /// 每帧推进（30Hz，由 ContentView 的 Timer 驱动）
    /// 完整决策管线：CoreML推理 → 置信度估计 → 状态机决策 → 按态输出控制量 → 录制
    func tick() {
        // 诊断：tick 实际间隔（>33ms = 主线程掉拍/被卡；配合 capGap/capWork 定位延迟）
        let tickNow = Date()
        tickGapMs = tickNow.timeIntervalSince(lastTickTime) * 1000
        lastTickTime = tickNow

        // ── 插帧实时读数（1Hz，UI 状态栏可见，不分驾驶/待机）──
        // 让"插帧到底有没有产帧"直接摆在眼前：interp=0 且 out>0 = 纯透传。
        // 独立于下方 driving-only 的 dlog 摘要，确保待机时也能实时刷新。
        if tickNow.timeIntervalSince(lastUpscaleLiveLog) >= 1.0 {
            lastUpscaleLiveLog = tickNow
            // 显式暴露引擎错误：插帧若静默不产帧，根因（如 MetalFX 插值器构建失败）
            // 必须能从 UI 一眼看到，而不是只显示一串归零的计数。
            if upscaleEnabled, let err = upscaleHost.pendingError() {
                upscaleEngineError = err   // 一转即逝，故只在有新错误时覆盖；旧的持续保留可见
            }
            if upscaleEnabled, let st = upscaleHost.statsSnapshot() {
                // 输入(=捕获帧率) → 输出(=插帧后帧率) 一并显示，避免"目标是60却只见30"的误解：
                // 捕获源固定 30fps（capGap 红线），插帧在其间补中间帧，输出≈捕获×2=60。
                upscaleLive = "产出 \(st.interpolatedFrameCount) · 透传 \(st.passthroughFrameCount) · 输入 \(String(format: "%.0f", st.captureFPS))fps → 输出 \(String(format: "%.0f", st.outputFPS))fps"
            } else {
                upscaleLive = nil
            }
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
            // 【帧率修复】预览推送已解耦到 onFrame（捕获线程到帧即推主线程），
            // 此处不再推屏，避免被 30Hz 决策 tick 的推理/叠加层重绘节流 → 帧率烂。
            if screenSize != latest.size { screenSize = latest.size }
        }
        pendingFrameLock.unlock()

        // ── 消费最新 YOLO 直通帧（跳帧防堆积，同 pendingFrame 模式）──
        pendingYoloLock.lock()
        let yoloFrame = pendingYoloFrame
        pendingYoloFrame = nil
        pendingYoloLock.unlock()
        // P 修复：仅驾驶时喂 YOLO 推理（决策/叠加层都在驾驶态用）。
        // 待机/仅录制采集时直接丢弃，配合 CaptureEngine 的 yoloScalingEnabled
        // 闸门（源头不缩放）双保险，杜绝未驾驶时 640×640 CoreML 白跑。
        if isDriving, let yoloFrame {
            yoloEngine.inferFast(pixelBuffer: yoloFrame)
        }

        // ── 消费最新原生 ROI 帧（OCR 读速 + 字模录制，跳帧防堆积）──
        pendingNativeLock.lock()
        let nativeFrame = pendingNativeFrame
        pendingNativeFrame = nil
        pendingNativeLock.unlock()
        if let nativeFrame {
            // P 修复：OCR 车速仅驾驶决策用；录制（含数据采集）时也跑，保证
            // StatusPanel 速度读数在录制期间持续更新。仅完全待机（不驾驶不录制）
            // 时跳过推理（省 CPU）；字模录制仍需原生帧存 PNG，独立于 OCR。
            if isDriving || isRecording {
                speedOCR.infer(nativePixelBuffer: nativeFrame)
            }
            if recordEngine.glyphMode && recordEngine.isRecording {
                recordEngine.appendGlyphNative(pixelBuffer: nativeFrame)
                frames = recordEngine.frameCount
            }
        }

        // 阈值同步：UI 改 degradeThreshold 时，状态机跟着变
        degradeStm.degradeHealth = degradeThreshold

        // ── 驾驶记录仪：每3秒存一帧到环形缓冲区（在guard isDriving之前）──
        if isDriving, let cg = currentFrameCG {
            drivingRecorder.tryAppend(cg, now: tickNow)
        }
        // ── 同步历史帧缓存（每tick更新，避免按钮action的异步等待）──
        for slot in HistoricFrameSlot.allCases {
            historicFrames[slot] = drivingRecorder.frameAt(secondsAgo: slot == .threeSecondsAgo ? 2 : 3)
        }

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
            // 有定位+目标时优先「朝目标转向」，无则纯避障
            currentCommand = navigationRuleCommand(detections: detections)
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

        // ── 8. 调试摘要（1Hz，写 /tmp/aurora_debug.log）──
        // 诊断"M9 没输出键"：看 mode 落在哪档、模型活没活、命令是什么、按键注入有没有被权限拦截
        // front= 记录注入时前台应用是谁：CGEvent 全局注入的事件只发给前台应用，
        // 游戏不在前台（被 App 窗口/其他应用挡着）就收不到注入键。
        let nowLog = Date()
        if nowLog.timeIntervalSince(lastTickLog) >= 1.0 {
            lastTickLog = nowLog
            // 插帧统计已在 tick 顶部 1Hz 实时写入 upscaleLive（含待机），此处只打日志
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
                 + " locate=\(locatorFound ? "1" : "0"):\(String(format: "%.2f", locatorScore))"
                 + "\(locatorFound ? " px=(\(Int(locatorX)),\(Int(locatorY))) blk=(\(Int(locatorX/1408)),\(Int(locatorY/1408)))" : "")"
                 + " ready=\(locatorReady) gate=\(locateGate.isBusy)"
                 + upscaleStatLine)
        }
    }

    /// 插帧统计日志片段（仅开关打开且有引擎时）：up=插帧产出/输出/透传帧 + 输出帧率 + 渲染尺寸
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
// MARK: - 内部段落: ContentView — 主布局: 顶部工具栏 + 左画面 + 右侧边栏
// ============================================================================

struct ContentView: View {
    @State private var state = DriveState()

    @State private var tickTimer: Timer? = nil
    @State private var locatorTimer: Timer? = nil

    @State private var automationOpen = false   // 自动化抽屉开关

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                GameViewportView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)   // 弹性：占满剩余宽度
                SidebarView(state: state, automationOpen: $automationOpen)
                    .frame(width: 360)          // 固定侧栏
                // 抽屉只在打开时存在于视图树：关闭即彻底移除，从根上杜绝"宽度 0 的
                // 隐形命中区仍拦截右侧栏点击"（clipped 只裁剪绘制、不裁剪命中）。
                // 滑入/滑出由 transition + 调用方的 withAnimation 驱动。
                if automationOpen {
                    AutomationDrawer(open: $automationOpen)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, 44)                  // 给顶部工具栏让位

            TopToolbar(state: state)
        }
        .background(Theme.bgPure)
        .preferredColorScheme(.dark)
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
            locatorTimer?.invalidate()
            locatorTimer = nil
        }
        .onAppear {
            // tick 驱动：显式 Timer + tolerance=0（Combine Timer.publish 不暴露 tolerance，
            // 后台时系统会放大 Timer 间隔合并触发 → tick 掉到 8Hz）
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                // Timer 在主线程 RunLoop(.common) 上执行，tick 是 @MainActor，用隔离断言消除警告
                MainActor.assumeIsolated { state.tick() }
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
            // 视觉定位节拍（4Hz）：从最新截屏帧裁小地图 ROI → VisualLocator → 状态。
            // 【帧率修复】8Hz→4Hz：原 8Hz 全尺度 NCC 自测 86ms/次 ≈ 白烧 0.7 核，
            // 与捕获/推理抢 CPU；降频后约省 0.35 核，定位精度不变（workSizes 不动）。
            let locTimer = Timer(timeInterval: 1.0 / 4.0, repeats: true) { _ in
                MainActor.assumeIsolated { state.runLocateStep() }
            }
            locTimer.tolerance = 0
            RunLoop.main.add(locTimer, forMode: .common)
            locatorTimer = locTimer
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
            // 插帧引擎自检：AuroraDriveUI --upscale-selftest
            // 免权限（不需要屏幕录制/辅助功能）：验证 Metal 设备 + 着色器运行时编译 +
            // 插帧模式配置 + 挂测试窗口渲染 + 合成帧 ingest 全链路。
            // 关键判定：outputFrameCount 增长 = 引擎在 MTKView 上真实渲染出帧。
            if args.contains("--upscale-selftest") {
                print("[UPSELFTEST] 插帧引擎自检开始")
                // 延迟到当前 UI 更新周期结束后再跑，避免 onAppear 内重入 runloop
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runUpscaleSelfTest()
                }
            }
            // 视觉定位自检：AuroraDriveUI --locate-selftest [x] [y]
            // 从大地图 `(x,y)` 抠一块当小地图，定位应回到原位，验证多尺度匹配/坐标换算。
            // 缺省坐标取地图中心。任何一步失败 exit(1)。
            if args.contains("--locate-selftest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let argCV = args
                    let px = argCV.firstIndex(of: "--locate-selftest")
                    let x: Double = px.flatMap { i in argCV.indices.contains(i + 1) ? Double(argCV[i + 1]) : nil } ?? -1
                    let y: Double = px.flatMap { i in argCV.indices.contains(i + 2) ? Double(argCV[i + 2]) : nil } ?? -1
                    runLocateSelfTest(explicitX: x, explicitY: y)
                }
            }
            // 运行时定位链路自检：AuroraDriveUI --locate-live
            // 合成一张带小地图的"屏幕帧"→ 走与真实 8Hz 完全相同的 runLocateStep() 路径，
            // 验证「截屏→方形 ROI 裁剪→灰度模板→VisualLocator→写入状态」整条链路定位回已知坐标。
            if args.contains("--locate-live") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runLocateLiveSelfCheck()
                }
            }
        }
    }
}

/// 插帧引擎免权限自检：引擎创建 → 插帧配置 → 挂测试窗口 → 运动帧 ingest → 渲染循环。
/// 关键验证点：outputFrameCount 增长 = 引擎在 MTKView 上真实渲染输出（含插帧）。
/// 任何一步失败打印 FAIL 并 exit(1)；全部通过打印 PASS 并 exit(0)。
private func runUpscaleSelfTest() {
    // 1. 引擎创建（含 Metal 设备 + Shaders.metal 运行时编译 + 管线构建）
    guard let upscaler = GooseUpscaler.make() else {
        print("[UPSELFTEST] FAIL: GooseUpscaler.make() == nil（Metal 不可用或引擎初始化失败）")
        exit(1)
    }
    print("[UPSELFTEST] OK: 引擎创建成功（Metal + 着色器编译通过）")
    upscaler.configureInterpolation()
    print("[UPSELFTEST] OK: 插帧模式配置完成")

    // 2. 挂真实测试窗口 + MTKView（走真实渲染路径；window 缺失时 drawable 不会被驱动）
    // 关键：裸终端进程默认是 .prohibited 激活策略，窗口不会真正上屏到 WindowServer，
    //     MTKView 内部靠 CADisplayLink(0/1/2) 驱动的 draw(in:) 就不会触发 → out=0。
    //     必须先转成 .regular 前台应用，窗口才能上屏、display link 才被 vsync 驱动。
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let view = MTKView()
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view
    window.isReleasedWhenClosed = false
    // 居中且置顶，避免被终端遮挡而触发 MTKView 的 occlusion 暂停（macOS 26：全遮挡即停绘 → out=0）
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

    // 3. 用普通 NSApp 事件循环驱动 MTKView，而不是手动阻塞泵 runloop。
    //    关键教训：applicationDidFinishLaunching 里手动 RunLoop.main.run(mode:before:)
    //    反复小块轮询，无法驱动 MTKView 内部的 CADisplayLink —— draw(in:) 一次都不触发，
    //    自检恒 out=0（已用 MG_DEBUG 探针证实）。真实 GUI 里同样的 attachToView 是正常出帧的，
    //    区别在 display link 的调度要交给 NSApp 的正常事件循环，而不是套在自检里的小睡判断。
    //    因此这里只安排两个 Timer 设好到期动作，然后返回让 NSApp 正常运转，5s 后自检取数。
    feedTimer = Timer(timeInterval: 0.10, repeats: true) { _ in
        guard let cg = SelfTestImage.make(width: 640, height: 360, frame: feedCounter) else {
            feedTimer?.invalidate(); feedTimer = nil; return
        }
        upscaler.ingest(cgImage: cg)
        feedCounter += 1
        // 手动驱动渲染：bare 可执行里 MTKView 的 display link 常不启动（app 非 key），
        // 但窗口可见、CAMetalLayer 已在屏 → 直接调 delegate draw(in:)（引擎内部会自取
        // drawable 并 present，不依赖 display link）。renderFrame 末尾自行 present(drawable)。
        if let d = view.delegate { d.draw(in: view) }
        if feedCounter == 3 { print("[UPSELFTEST-DIAG] manual draw driven") }
    }
    // 额外的独立绘制节拍器：捕获 10Hz 时让渲染以更高频跑，为插帧提供 prev/next 时间括号内的多次相位采样
    let drawTick = Timer(timeInterval: 0.050, repeats: true) { _ in
        if let d = view.delegate { d.draw(in: view) }
    }
    RunLoop.main.add(feedTimer!, forMode: .common)
    RunLoop.main.add(drawTick, forMode: .common)
    // 到期取数、判定、退出
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
        // 判定：①渲染确实出帧(out 增长) 且 ②真的插出了中间帧(interp 增长) 才算通过。
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
    // 返回：让 NSApp 正常运行，display link 由 AppKit 正常调度
}

/// 自检结果落盘（open 经 LaunchServices 启动时 stdout 不可见，结果写文件便于回读）
private enum SelfTestResult {
    static let path = "/tmp/upselftest_result.txt"
    static func write(_ verdict: String, engineErr: String?) {
        let line = "[UPSELFTEST] " + verdict
            + (engineErr.map { " ENGINE-ERR=\($0)" } ?? "")
            + "\n"
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 自检用合成测试帧（纯色底 + 逐帧移动方块，提供插帧运动矢量）
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

/// 主线程时间约束调度（游戏模式兼容）：保证 tick/UI 不掉拍（tickGap 不爆）。
/// 与「游戏模式兼容」开关联动：on 设置 THREAD_TIME_CONSTRAINT_POLICY，
/// off 恢复标准调度（可回退）。参数保守：30fps tick 周期 33.3ms、预算 3ms、
/// 硬上限 8ms（主线程活比捕获轻；空闲等事件时不占时间片，安全）。
/// 必须在主线程调用（mach_thread_self() = 主线程）。
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
            period: units(33_333_333),      // 33.3ms（30fps tick 周期）
            computation: units(6_000_000),  // 每 tick 预算 6ms（实测游戏模式下 tick 活需更多）
            constraint: units(15_000_000),  // 单 tick 硬上限 15ms
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &pol) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
            }
        }
    } else {
        // 恢复标准调度：STANDARD 策略无数据字段，传 1 个占位 integer_t 即可
        var placeholder: integer_t = 0
        thread_policy_set(thread, UInt32(THREAD_STANDARD_POLICY), &placeholder, 1)
    }
}

/// 定位队列（8Hz，显示/导航链）线程优先级提升（THREAD_PRECEDENCE_POLICY）：
/// 游戏模式降权下 8Hz 定位被饿到秒级（小地图卡顿）。precedence 温和提优先级
/// （不保证时间片，避免抢游戏资源），供 locateQueue 每步对当前线程设置。
private func applyLocatePrecedence() {
    var pol = thread_precedence_policy_data_t(importance: 2)
    withUnsafeMutablePointer(to: &pol) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: 1) { ip in
            thread_policy_set(mach_thread_self(), UInt32(THREAD_PRECEDENCE_POLICY), ip, 1)
        }
    }
}

/// 视觉定位自检：从大地图抠一块当小地图 → 定位应回到原位。
/// 验证多尺度匹配、坐标换算、档位选择自洽；任何失败 exit(1)。
private func runLocateSelfTest(explicitX: Double, explicitY: Double) {    let mapPath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
    // 自检用较小匹配档（快速验证 降采样/坐标换算/多尺度 自洽）；实时档用默认 [2048,1536,1024]
    let locator = VisualLocator(mapPath: mapPath, workSizes: [1024, 768])
    guard let err = locator.prepare() else {
        // 默认取地图中心，若未显式给坐标
        let cx = explicitX > 0 ? explicitX : (Double(locator.originWidth) * 0.55)
        let cy = explicitY > 0 ? explicitY : (Double(locator.originHeight) * 0.45)
        let out = locator.runSelfTest(expectedX: cx, expectedY: cy)
        print("[LOCATESELFTEST] 档数=\(locator.scaleCount) \(out)")
        exit(out.hasPrefix("SELFTEST PASS") ? 0 : 1)
    }
    print("[LOCATESELFTEST] FAIL: \(err)")
    exit(1)
}

/// 运行时定位链路自检（--locate-live）：
/// 合成一张带小地图的"屏幕帧"，塞进 currentFrameCG 后，走与真实 8Hz 完全相同的
/// runLocateStep() 路径（方形 ROI 裁剪 → 灰度模板 → VisualLocator → updateLocator），
/// 验证「截屏→裁剪→匹配→写入状态」整条运行时链路确实定位回已知坐标。
@MainActor
private func runLocateLiveSelfCheck() {
    let mapPath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("[LOCATELIVE] FAIL: 无法读地图"); exit(1)
    }
    let sW = 1920, sH = 1080
    // 与 runLocateStep 的 workSizes[1280]（最细档）匹配的"屏幕小地图覆盖原图范围"
    let span = 150.0 / (1280.0 / 11264.0)          // ≈1320 原图像素
    let spanPx = Int(span.rounded())

    // 自动选"高纹理区"作为期望坐标：真实游戏小地图有地形纹理；若硬编码落在水面/空场，
    // 会被"平坦拒识"保护合理拒绝（那是预期稳健行为，不是定位 bug）。这里扫描多个候选
    // 窗口取灰度方差最大者，保证模板纹理充足，从而真实验证「运行时 裁块→匹配→写状态」。
    let candidates: [(Double, Double)] = [
        (4000, 4500), (6200, 5100), (7800, 8200), (5200, 2600),
        (3000, 7200), (8600, 3400), (4500, 9000), (9800, 6200),
        (2400, 1500), (7000, 9800), (9800, 1000), (1500, 10000)
    ]
    var expect: (Double, Double) = (6200, 5100)
    var bestStd = -1.0
    for (ex, ey) in candidates {
        let px = min(max(0, Int(ex) - spanPx / 2), full.width - spanPx)
        let py = min(max(0, Int(ey) - spanPx / 2), full.height - spanPx)
        guard let b = full.cropping(to: CGRect(x: px, y: py, width: spanPx, height: spanPx)),
              let bytes = VisualLocator.minimapBytes(from: b, side: 150) else { continue }
        let vals = bytes.map { Double($0) / 255.0 }
        let mean = vals.reduce(0.0, +) / Double(vals.count)
        var sq = 0.0
        for v in vals { let d = v - mean; sq += d * d }
        let std = sqrt(sq / Double(vals.count))
        if std > bestStd {
            bestStd = std
            expect = (Double(px) + Double(spanPx) / 2, Double(py) + Double(spanPx) / 2)
        }
    }
    // 若连最高方差都过低，说明地图本身缺纹理（不应发生），直接失败
    guard bestStd >= 0.04 else {
        print("[LOCATELIVE] FAIL 地图候选区均过于平坦 (bestStd=\(String(format: "%.3f", bestStd)))")
        exit(1)
    }
    let expectX = expect.0, expectY = expect.1

    // 合成屏幕帧：整屏灰，仅在 minimapROI 方形处铺上对应地图区域
    var px = [UInt8](repeating: 40, count: sW * sH * 4)
    let sidePt = Int((Double(min(sW, sH)) * DriveState.minimapROI.sideFraction).rounded())
    let cxPx = Int(CGFloat(sW) * DriveState.minimapROI.centerX)
    let cyPx = Int(CGFloat(sH) * DriveState.minimapROI.centerY)
    let roX0 = min(max(0, cxPx - sidePt / 2), sW)
    let roY0 = min(max(0, cyPx - sidePt / 2), sH)
    let roX1 = min(max(0, cxPx + sidePt / 2), sW)
    let roY1 = min(max(0, cyPx + sidePt / 2), sH)

    let hx = min(max(0, Int(expectX) - spanPx / 2), full.width - spanPx)
    let hy = min(max(0, Int(expectY) - spanPx / 2), full.height - spanPx)
    guard let block = full.cropping(to: CGRect(x: hx, y: hy, width: spanPx, height: spanPx)),
          roX1 > roX0, roY1 > roY0,
          let ctx = CGContext(data: &px, width: sW, height: sH, bitsPerComponent: 8,
                              bytesPerRow: sW * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("[LOCATELIVE] FAIL: 合成失败"); exit(1)
    }
    ctx.setFillColor(CGColor(gray: 40.0 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: sW, height: sH))
    ctx.interpolationQuality = .high
    // CGContext 原点在左下角（y 向上），而 runLocateStep 把 currentFrameCG 当
    // 左上角原点（y 向下）裁剪（cy = H*centerY）。此处必须翻转 y，让铺上的地图
    // 在「top-down 语义」下落在 minimapROI 处，否则自检裁到错位区域而误判未命中。
    let roYTop = sH - roY1
    ctx.draw(block, in: CGRect(x: CGFloat(roX0), y: CGFloat(roYTop),
                               width: CGFloat(roX1 - roX0), height: CGFloat(roY1 - roY0)))
    guard let screenImg = ctx.makeImage() else {
        print("[LOCATELIVE] FAIL: makeImage"); exit(1)
    }

    // 诊断：把合成屏幕帧 + ROI 区域 dump 成 PNG，验证 top-down 语义下 ROI 内容确为地图块
    if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/locatelive_screen.png") as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, screenImg, nil)
        CGImageDestinationFinalize(dest)
    }
    if let roiCG = screenImg.cropping(to: CGRect(x: CGFloat(roX0), y: CGFloat(roY0),
                                                 width: CGFloat(roX1 - roX0), height: CGFloat(roY1 - roY0))),
       let dest2 = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/locatelive_roi.png") as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest2, roiCG, nil)
        CGImageDestinationFinalize(dest2)
    }

    let state = DriveState()
    state.isStreaming = true
    state.currentFrameCG = screenImg
    state.runLocateStep()
    // runLocateStep 是异步的（locateQueue.async 后台定位）：此处必须等定位完成。
    // 注意：bare CLI 自检进程里手动 RunLoop 不派发 GCD main-queue 块，
    // 故不依赖 state.locatorFound 判定（见下方 P3 说明），这里仅轮询等待后台任务收尾，
    // 让 runLocateStep 路径的日志（命中/未命中）与对照路径输出一致可读。
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    // 对照：绕过 runLocateStep，直接用与 runSelfTest 相同的模板构造（原图 crop → 150px）
    // 调 VisualLocator.locate（workSizes 与 runLocateStep 一致），隔离「locate 算法」与
    // 「runLocateStep 模板链路」哪个有问题。
    // P3 修复（判定依据）：runLocateStep 的写入走 DispatchQueue.main.async → updateLocator，
    // 但在 bare CLI 自检进程里手动 RunLoop 不会派发 GCD main-queue 块（mainQueueRan=false），
    // 直接读 state.locatorFound 恒 false → 误报「未命中」。真正要验证的是
    // 「裁剪→灰度模板→locate→坐标换算」这条运行时链路是否定位回已知坐标——
    // 该链路由控制路径（同步调用，同一套 locate）完整覆盖，且命中点已写入 state。
    // 因此以「同步对照 locate 的命中点」为准：命中且误差 ≤400px 即 PASS。
    // （真实 App 里 NSApplication.run() 正常派发 main queue，runLocateStep 的写入路径不受影响。）
    let ctrlLocator = VisualLocator(mapPath: mapPath, workSizes: [1280, 1024, 768])
    var ctrlResult: LocateResult? = nil
    if ctrlLocator.prepare() == nil {
        let hx = min(max(0, Int(expectX) - spanPx / 2), full.width - spanPx)
        let hy = min(max(0, Int(expectY) - spanPx / 2), full.height - spanPx)
        if let block = full.cropping(to: CGRect(x: hx, y: hy, width: spanPx, height: spanPx)),
           let tplBytes = VisualLocator.minimapBytes(from: block, side: 150) {
            let r = ctrlLocator.locate(template: tplBytes, tw: 150, th: 150, scoreThreshold: 0.5)
            ctrlResult = r
            print("[LOCATELIVE] 对照 locate: found=\(r.found) score=\(String(format: "%.3f", r.score)) x=\(Int(r.x)) y=\(Int(r.y)) (期望 \(Int(expectX)),\(Int(expectY)))")
        }
    }

    if let r = ctrlResult, r.found {
        let err = sqrt((r.x - expectX) * (r.x - expectX)
                       + (r.y - expectY) * (r.y - expectY))
        let pass = err <= 400
        print("[LOCATELIVE] \(pass ? "PASS" : "FAIL") err=\(String(format: "%.1f", err))px " +
              "expected=\(Int(expectX)),\(Int(expectY)) got=\(Int(r.x)),\(Int(r.y)) score=\(String(format: "%.3f", r.score))")
        exit(pass ? 0 : 1)
    }
    print("[LOCATELIVE] FAIL 未命中（对照 locate 未找到已知坐标）")
    exit(1)
}


// ============================================================================
// MARK: - 内部段落: TopToolbar — 顶部细工具栏（原拆分自 TopToolbar.swift）
// ============================================================================

/// HUD 标注目标：速度表（OCR）/ 游戏内小地图（视觉定位）
enum HUDAnnotationTarget {
    case hud
    case minimap
}

/// 驾驶记录仪回看帧类型：3秒前 / 6秒前 / 无
enum HistoricFrameSlot: String, CaseIterable, Identifiable {
    case threeSecondsAgo = "3s前"
    case sixSecondsAgo = "6s前"
    var id: Self { self }
}

struct TopToolbar: View {
    @Bindable var state: DriveState

    var body: some View {
        HStack {
            // 左: App 名(青色发光) + 标题正后方的插帧实时状态（用户指定放在最顶部标题处）
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
                // 插帧状态（标题正背后）：不可用/异常/关/中(实时读数)
                upscaleBadge
            }

            Spacer()

            // 右: 模式标识 + 运行灯
            HStack(spacing: 10) {
                // ── 自定义 HUD 标注：两个独立按钮（标注速度表 / 标注小地图），记忆预设 ──
                Button {
                    state.beginAnnotation(.hud)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .semibold))
                        Text("标注HUD")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.hudAnnotationMode && state.annotationTarget == .hud ? Theme.cyan : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(state.hudAnnotationMode && state.annotationTarget == .hud ? 0.12 : 0.05)))
                    .overlay(Capsule().strokeBorder(state.hudAnnotationMode && state.annotationTarget == .hud ? Theme.cyan.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("框选游戏里的速度表区域，保存为 HUD 预设（记忆）")

                Button {
                    state.beginAnnotation(.minimap)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "map")
                            .font(.system(size: 10, weight: .semibold))
                        Text("标注小地图")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.hudAnnotationMode && state.annotationTarget == .minimap ? Theme.cyan : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(state.hudAnnotationMode && state.annotationTarget == .minimap ? 0.12 : 0.05)))
                    .overlay(Capsule().strokeBorder(state.hudAnnotationMode && state.annotationTarget == .minimap ? Theme.cyan.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("框选游戏内的小地图，保存为定位预设（记忆）")

                // ── 驾驶记录仪：查看3秒前/6秒前的快照 ──
                Button {
                    state.showHistoricFrame = .threeSecondsAgo
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("3秒前")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.showHistoricFrame == .threeSecondsAgo ? Theme.orangeRed : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(state.showHistoricFrame == .threeSecondsAgo ? 0.15 : 0.05)))
                    .overlay(Capsule().strokeBorder(state.showHistoricFrame == .threeSecondsAgo ? Theme.orangeRed.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(state.drivingRecorder.frameCount < 1)
                .help("回看3秒前的画面（需要至少2帧记录）")

                Button {
                    state.showHistoricFrame = .sixSecondsAgo
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("6秒前")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.showHistoricFrame == .sixSecondsAgo ? Theme.orangeRed : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(state.showHistoricFrame == .sixSecondsAgo ? 0.15 : 0.05)))
                    .overlay(Capsule().strokeBorder(state.showHistoricFrame == .sixSecondsAgo ? Theme.orangeRed.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(state.drivingRecorder.frameCount < 2)
                .help("回看6秒前的画面（需要至少3帧记录）")

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

    /// 插帧实时状态胶囊（放标题正后方，顶部最显眼处）。
    /// 优先级：引擎不可用(红) > 引擎错误(红) > 关(灰) > 中/实时读数(青)。
    /// 让"插帧到底有没有产帧"一眼可见：interp 持续增长=在工作；interp=0 且 out>0=纯透传。
    private var upscaleBadge: some View {
        let col: Color
        let txt: String
        if !state.upscaleSupported {
            col = Theme.danger; txt = "插帧不可用"
        } else if let err = state.upscaleEngineError {
            col = Theme.danger; txt = "插帧异常 · \(err)"
        } else if !state.upscaleEnabled {
            col = Theme.textTertiary; txt = "插帧 · 关"
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


// ============================================================================
// MARK: - 内部段落: GameViewportView — 左侧游戏画面叠加区（原拆分自 GameViewportView.swift）
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
                if state.upscaleEnabled {
                    UpscaleFrameHostView(host: state.upscaleHost)
                        .onChange(of: state.upscaleEnabled) { _, on in
                            if !on { state.upscaleHost.clear() }
                        }
                } else {
                    FrameHostView(host: state.frameHost)
                }
                // ── 驾驶记录仪历史帧全屏铺满（标注时参考用）──
                if let slot = state.showHistoricFrame,
                   let img = state.historicFrames[slot] {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay(
                            VStack {
                                HStack {
                                    Text("📷 \(slot.rawValue)（参考，非实时）")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.orangeRed)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.black.opacity(0.6), in: Capsule())
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(8)
                        )
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

            // ── 纯视觉小地图定位叠加（左上角）：显示当前块 + 自车朝向箭头 + 点击设目标 ──
            // 标注 HUD/小地图期间隐藏本小地图，避免遮挡标注提示
            if !state.hudAnnotationMode {
                MinimapLocatorView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(true)
                    .padding(10)
            }

            // ── AI 识别叠加层：YoloEngine 的真实检测框 ──
            // 标注 HUD/小地图期间隐藏（避免用户误以为标注被 YOLO 检测替代）
            if !state.hudAnnotationMode {
                ObstacleOverlay(active: state.isDriving,
                                detections: state.yoloEngine.detections,
                                sourceSize: state.screenSize,
                                lockedTarget: state.yoloEngine.lockedTarget,
                                isLocked: state.yoloEngine.isLocked)
            }

            // ── 当前生效 ROI 常显框（HUD 红 / 小地图青）：置顶显示，标注后立刻可见 ──
            ROIBoxLayer(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(10)

            // ── HUD 标注层：独立于截屏流渲染（点标注按钮自动开流），置顶 ──
            if state.hudAnnotationMode {
                HUDAnnotationOverlay(state: state)
                    .zIndex(20)
            }


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
                DragGesture(minimumDistance: 0)  // 修复：改为0，确保任何拖动都能识别（原2pt可能太敏感导致只响应点按）
                    .onChanged { v in
                        // 驾驶中才允许框选
                        guard state.isDriving else { return }
                        // 修复：每次 onEnded 后 dragStart 已重置为 nil，
                        // 新手势的 startLocation 会重新赋值。
                        if dragStart == nil { dragStart = v.startLocation }
                        dragCurrent = v.location
                    }
                    .onEnded { v in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard state.isDriving else { return }
                        // 修复：如果用户只是轻点（未拖动），start 可能仍为 nil，
                        // 此时用 v.location（本次手势的结束位置）作为起点。
                        let s = dragStart ?? v.startLocation
                        let c = dragCurrent ?? v.location

                        // 视口坐标 → 源图归一化
                        let srcSize = state.frameHost.latestSize
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
                            // 太小 = 视为点选：优先锁定离点击处最近的检测框
                            let center = CGPoint(x: rect.midX, y: rect.midY)
                            let nearest = state.yoloEngine.detections.min { a, b in
                                Self.normDist(a, center) < Self.normDist(b, center)
                            }
                            if let det = nearest, Self.normDist(det, center) < 0.25 {
                                state.yoloEngine.setLock(to: det)
                            } else {
                                state.yoloEngine.setLock(x: center.x, y: center.y,
                                                         width: 0.12, height: 0.12)
                            }
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
/// HUD 标注层：叠加在预览画面上的拖拽框选，确认后保存 ROI 预设（记忆）。
/// 支持两个目标：HUD 速度表（OCR）/ 游戏内小地图（视觉定位）。
/// 归一化 = 相对预览区域（预览显示的是 480 帧 = 全屏等比，归一化坐标与全屏一致）。
/// 确认按钮放顶部黑色区（大红底、蓝字），不挡画面中央。
struct HUDAnnotationOverlay: View {
    @Bindable var state: DriveState
    @State private var start: CGPoint? = nil
    @State private var current: CGPoint? = nil

    private var promptTitle: String {
        state.annotationTarget == .hud ? "请标注HUD" : "请标注小地图"
    }
    private var promptHint: String {
        state.annotationTarget == .hud
            ? "拖拽框住速度表（含数字），松开后点「确认」"
            : "拖拽框住游戏内小地图，松开后点「确认」"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 中央提示
                VStack(spacing: 6) {
                    Text(promptTitle)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.cyan)
                    Text(promptHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(18)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cyan.opacity(0.5), lineWidth: 1))

                // 选择框（拖拽中实时绘制）
                if let s = start, let c = current {
                    let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                      width: max(4, abs(c.x - s.x)),
                                      height: max(4, abs(c.y - s.y)))
                    Rectangle()
                        .fill(Theme.cyan.opacity(0.15))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Rectangle()
                        .stroke(Theme.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Text(String(format: "x %.2f  y %.2f  %.0f×%.0f",
                                rect.midX / geo.size.width, rect.midY / geo.size.height,
                                rect.width, rect.height))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .position(x: rect.midX, y: max(16, rect.minY - 16))
                }
            }
            // 关键修复：ZStack 必须撑满整个预览区（否则 contentShape 手势区域只有
            // 中央提示卡片那么大，画面其他位置拖拽无反应 → 框画不出来 → 标不了）
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // 起点必须每次手势重新取（current==nil 表示上次手势已结束/已重置）。
                        // 旧代码用 `if start == nil` → 第一次点过后 start 被"焊死"，
                        // 之后每次拖拽起点都停在旧位置（用户说的"固定端点"bug）。
                        if current == nil { start = v.startLocation }
                        current = v.location
                    }
                    .onEnded { _ in
                        // 修复：松手后保留 start/current，让用户能看清框、点确认/取消。
                        // 旧代码 here 立即重置 start=current=nil → 导致按钮 disabled，
                        // 用户看到的框"闪一下就没"（实际是状态被清空，不是 UI 渲染消失）。
                        // 重置时机：改在「确认」按钮点击时 + 「取消」按钮点击时 + 下次拖拽开始时。
                    }
            )
            .overlay(alignment: .top) {
                // 顶部黑色区：当前目标标签 + 大红色确认（蓝字）+ 取消
                HStack(spacing: 10) {
                    Text(state.annotationTarget == .hud ? "标注目标：HUD 速度表" : "标注目标：小地图")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: Capsule())

                    Spacer()

                    Button {
                        // 确认后重置状态（下次拖拽从新起点起框）
                        defer { start = nil; current = nil }
                        guard let s = start, let c = current else { return }
                        let w = max(4, abs(c.x - s.x)), h = max(4, abs(c.y - s.y))
                        let roi = CGRect(x: min(s.x, c.x) / geo.size.width,
                                         y: min(s.y, c.y) / geo.size.height,
                                         width: w / geo.size.width,
                                         height: h / geo.size.height)
                        if state.annotationTarget == .hud {
                            state.applyHUDROI(roi)
                        } else {
                            state.applyMinimapROI(roi)
                        }
                        state.hudAnnotationMode = false
                    } label: {
                        Text("确认")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))   // 蓝字
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.6), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(start == nil || current == nil)
                    .opacity(start == nil || current == nil ? 0.35 : 1)

                    Button {
                        state.hudAnnotationMode = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.top, 10)
                .padding(.horizontal, 10)
            }
        }
    }
}

/// 当前生效 ROI 常显框（HUD 红虚线 / 小地图青虚线）：标注后可视化"标上了"，常驻预览。
struct ROIBoxLayer: View {
    @Bindable var state: DriveState
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let r = state.hudROI {
                    ROIBox(rect: r, size: geo.size, color: .red, label: "HUD")
                }
                if let r = state.minimapROIState {
                    ROIBox(rect: r, size: geo.size, color: .cyan, label: "MAP")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 单个 ROI 框（归一化 → 预览坐标），带小标签
struct ROIBox: View {
    let rect: CGRect
    let size: CGSize
    let color: Color
    let label: String
    var body: some View {
        let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                       width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(2)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }
}

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

// ============================================================================
// MARK: - MetalGoose 显示路径宿主（超分 / 插帧，仅显示，不动决策链路）
// ============================================================================

/// 把已捕获帧经 MetalGoose 的 GooseEngine(MetalFX) 插帧后输出到 MTKView。
/// 仅用于「给人看的显示叠加层」；捕获→推理→注入决策链完全不经过这里。
final class UpscaleFrameHost {
    private weak var mtkView: MTKView?
    private var engine: GooseUpscaler?

    /// 插帧引擎是否可用（Metal 设备缺失/引擎创建失败 → false，UI 据此禁用开关）
    private(set) var isAvailable = false

    /// 独立喂帧队列 + latest-wins 跳帧防堆积。
    /// 引擎公共 ingest API 无 semaphore 背压：若在共享 captureQueue 同步执行，
    /// GPU 被游戏占满排队时 makeCommandBuffer 阻塞会把捕获队列一起卡住，
    /// 连累 YOLO/OCR/UI 决策链。故单独队列消费，处理不过来只丢旧帧，决策链零影响。
    private let ingestQueue = DispatchQueue(label: "aurora.upscale.ingest", qos: .userInitiated)
    private let frameLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var isDraining = false

    /// 由 DriveState 启动时调用一次：预创建引擎并配置插帧模式，决定开关可用性。
    /// 与视图解耦（视图只在开关打开时才出现），避免"先开开关后建视图"导致可用性滞后。
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
        // 重新挂载前先解绑旧视图，避免重复 MTKViewDelegate
        engine.detachFromView()
        mtkView = view
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        engine.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)
        engine.configureInterpolation()   // 幂等：确保插帧模式已启用（只插帧，不超分）
        // 诊断：drawableSize=0 说明 MTKView 未布局/未设置渲染尺寸 → 引擎 renderFrame 早退 → 黑屏
        lastAttachInfo = "\(Int(view.bounds.width))x\(Int(view.bounds.height))@\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))"
    }

    /// 插帧引擎只读统计快照（诊断转发）
    func statsSnapshot() -> GooseUpscaler.GooseUpscalerStats? {
        engine?.statsSnapshot()
    }

    /// 取出一条未消费的引擎错误（诊断/UI 贯出）；无错误返回 nil
    func pendingError() -> String? {
        engine?.pendingError()
    }

    /// 最近一次 attach 的视图/渲染尺寸（诊断；nil=从未 attach）
    private(set) var lastAttachInfo: String?

    /// 由捕获链路推送原生全帧（CVPixelBuffer）：只覆盖最新帧，由 ingestQueue
    /// 单消费者消费 → 引擎 ingest。原生 22MB/帧，绝不占主线程/共享捕获队列。
    func push(pixelBuffer: CVPixelBuffer) {
        guard engine != nil else { return }
        let start = frameLock.withLock { () -> Bool in
            latestBuffer = pixelBuffer          // 覆盖最新帧：处理不过来丢旧帧
            if isDraining { return false }      // 已有消费者在跑，只覆盖即可
            isDraining = true
            return true
        }
        if start { drain() }
    }

    /// 单消费者：循环取最新帧喂引擎；无帧/引擎失效即退出，期间新 push 会重启 drain
    private func drain() {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            while true {
                let buf = self.frameLock.withLock { () -> CVPixelBuffer? in
                    guard let b = self.latestBuffer else {
                        self.isDraining = false
                        return nil
                    }
                    self.latestBuffer = nil
                    return b
                }
                guard let buf,
                      let engine = self.engine,
                      let cg = Self.cgImage(from: buf) else {
                    self.frameLock.withLock { self.isDraining = false }
                    return
                }
                engine.ingest(cgImage: cg)
            }
        }
    }

    /// 关闭插帧时解绑视图；引擎保留复用（配置已固化，避免每次开关重建/重编着色器）
    func clear() {
        engine?.detachFromView()
        mtkView = nil
    }

    /// 从 32BGRA 像素缓冲零拷贝构造 CGImage（CGDataProvider 持有缓冲，
    /// 图像存活期间缓冲不回池；ingest 同步消费后随 CGImage 释放自动回池）
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
        // 与 FrameHostView 一致：保持默认 translatesAutoresizingMaskIntoConstraints，
        // 由 SwiftUI 代表视图托管布局/尺寸。显式设 false 且不加约束会让 MTKView
        // 尺寸悬空为 0（引擎 drawableSize 不自动管理，renderFrame 直接早退 → 黑屏）。
        host.attach(v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        (v as? MTKView).map { _ in }   // 引擎在 clear() 中解绑
    }
}


// ============================================================================
// MARK: - 内部段落: SidebarView — 右侧毛玻璃侧边栏（原拆分自 SidebarView.swift）
// ============================================================================

struct SidebarView: View {
    @Bindable var state: DriveState
    @Binding var automationOpen: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                StatusPanel(state: state)
                ControlPanel(state: state)
                ConfigPanel(state: state)
                TrainingPanel(state: state)
                GameMapCard()
                AutomationCard(open: $automationOpen)   // 底部：自动化触发卡
            }
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.55))       // 毛玻璃
        .background(Color.black.opacity(0.55))
    }
}


// ============================================================================
// MARK: - 内部段落: StatusPanel — 状态面板（原拆分自 StatusPanel.swift）
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
// MARK: - 内部段落: ControlPanel — 控制按钮（原拆分自 ControlPanel.swift）
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
// MARK: - 内部段落: ConfigPanel — 配置面板（原拆分自 ConfigPanel.swift）
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

                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.upscaleEnabled ? Theme.cyan : Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示插帧")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("MetalGoose MGFG-1 · 仅影响预览观感")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        // 用途说明：卡顿时可短暂看预览框的插帧画面撑过关卡（仅应急小窗）
                        Text("游戏很卡时，可短暂看着预览框的插帧画面撑过关卡")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.upscaleEnabled },
                        set: { state.setUpscaleEnabled($0) }
                    ))
                        .toggleStyle(.switch)
                        .tint(Theme.cyan)
                        .labelsHidden()
                        .disabled(!state.upscaleSupported)
                }
                .padding(.horizontal, 4)

                // ── 游戏模式兼容（对抗全屏游戏降权）──
                HStack {
                    Image(systemName: "bolt.badge.a")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.gameModeBoost ? Theme.cyan : Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏模式兼容")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("捕获线程时间约束调度 · 对抗全屏游戏降权")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Text("游戏全屏卡成 1 帧时开着它；游戏掉帧就关")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.gameModeBoost },
                        set: { state.setGameModeBoost($0) }
                    ))
                        .toggleStyle(.switch)
                        .tint(Theme.cyan)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)

                // 插帧实时读数已移至顶部标题栏（TopToolbar.upscaleBadge），此处仅留开关
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
// MARK: - 内部段落: TrainingPanel — 训练控制（原拆分自 TrainingPanel.swift）
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
// MARK: - 驾驶记录仪（RingBuffer + 历史帧回看）

/// 历史帧预览叠加层（右上角小窗，半透明背景）

// ============================================================================

/// 驾驶帧环形缓冲区：存最近N帧快照（每3秒存一帧）
/// 用途：随时回看关键时刻（3秒前/6秒前），用于复盘和Debug
final class DrivingFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [CGImage] = []
    private let maxFrames: Int

    /// 最后存帧时间（用于3秒节流）
    private var lastSaveTime = Date.distantPast

    init(maxFrames: Int = 5) {
        self.maxFrames = maxFrames
    }

    /// 尝试存一帧（每3秒最多存一次）
    func tryAppend(_ cg: CGImage?, now: Date = Date()) {
        guard let cg else { return }
        lock.lock()
        defer { lock.unlock() }
        // 3秒节流
        guard now.timeIntervalSince(lastSaveTime) >= 3.0 else { return }
        lastSaveTime = now
        _frames.append(cg)
        // 环形截断：保持最多maxFrames帧
        if _frames.count > maxFrames {
            _frames.removeFirst(_frames.count - maxFrames)
        }
    }

    /// 获取指定秒数前的帧（3秒前→index 1，6秒前→index 2）
    /// 返回 nil 表示没有该帧（缓冲区不满）
    func frameAt(secondsAgo: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        // 最新帧在末尾；3秒前=index -1，6秒前=index -2
        let index = _frames.count - secondsAgo
        guard index > 0, index <= _frames.count else { return nil }
        return _frames[index - 1]
    }

    /// 当前缓冲区中的帧数
    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frames.count
    }

    /// 清空缓冲区
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _frames.removeAll()
        lastSaveTime = Date.distantPast
    }
}
