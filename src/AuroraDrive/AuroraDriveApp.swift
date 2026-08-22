// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Darwin
import CoreVideo
import Metal
import MetalKit
import MetalGooseEngine
import UniformTypeIdentifiers
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var napToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--yolo-selftest"), i + 1 < args.count {
            YoloEngine().selfTest(imagePath: args[i + 1])
            exit(0)
        }
        if args.contains("--network-locate-selftest") {
            print("[NETWORK-LOCATE] 自检开始，等待 MaaNTE server...")
            let locator = NetworkLocator()
            let ok = locator.prepare()
            print("[NETWORK-LOCATE] prepare=\(ok)")
            var count = 0
            var sampleTimer: Timer? = nil
            sampleTimer = Timer(timeInterval: 1.0, repeats: true) { _ in
                let result = locator.locate()
                count += 1
                print("[NETWORK-LOCATE] sample #\(count) found=\(result.found) mode=\(result.mode) " +
                      "score=\(String(format: "%.2f", result.score))" +
                      (result.point != nil ? " point=\(result.point!.0),\(result.point!.1)" : ""))
                if result.found && count >= 3 {
                    sampleTimer?.invalidate()
                    print("[NETWORK-LOCATE] PASS: 3 samples received")
                    locator.close()
                    exit(0)
                }
            }
            RunLoop.main.add(sampleTimer!, forMode: .common)
            let keepAlive = DispatchSource.makeTimerSource(flags: [], queue: DispatchQueue.global())
            keepAlive.schedule(deadline: .now() + 30)
            keepAlive.setEventHandler { exit(1) }
            keepAlive.resume()
            RunLoop.main.run(until: Date().addingTimeInterval(30))
        }
        if let i = args.firstIndex(of: "--yolo-bench"), i + 1 < args.count {
            YoloEngine().benchmark(imagePath: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--speed-selftest"), i + 1 < args.count {
            let reader = SpeedOCRReader()
            var roiNorm: CGRect? = nil
            if let ri = args.firstIndex(of: "--roi"), ri + 1 < args.count {
                let parts = args[ri + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    roiNorm = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            }
            print(reader.selfTestDirectory(args[i + 1], roiNorm: roiNorm))
            exit(0)
        }
        ProcessInfo.processInfo.disableAutomaticTermination("AuroraDrive 实时游戏辅助：持续截屏 + AI 决策注入")
        ProcessInfo.processInfo.disableSuddenTermination()
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInteractive, .background, .idleSystemSleepDisabled],
            reason: "AuroraDrive 实时游戏辅助：后台需持续 30Hz 决策与注入")
        if setpriority(PRIO_PROCESS, 0, -10) == 0 {
            print("[App] 进程优先级已提高 (nice=-10)")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            // .statusBar = 3，让 macOS 调度器认为这是 UI 类窗口（非普通浮动工具窗），
            // 游戏运行时系统不会降权该窗口的线程优先级
            window.level = .statusBar
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

private func orderWindowsFront() {
    for window in NSApp.windows {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private let projectRootURL: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()

@main
struct AuroraDriveApp: App {
    nonisolated static let inv255d: Double = 1.0 / 255.0
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 880, minHeight: 560)
                .background(Color.black)
                .onAppear {
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        orderWindowsFront()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 760)
    }
}

enum Theme {
    static let bgPure      = Color.black
    static let bgCard      = Color.white.opacity(0.045)
    static let bgCardEdge  = Color.white.opacity(0.08)
    static let cyan        = Color(red: 0.0, green: 0.898, blue: 1.0)
    static let cyanDim     = Color(red: 0.0, green: 0.898, blue: 1.0).opacity(0.55)
    static let orangeRed   = Color(red: 1.0, green: 0.36, blue: 0.22)
    static let danger      = Color(red: 1.0, green: 0.24, blue: 0.28)
    static let keyActive   = Color(red: 0.0, green: 1.0, blue: 0.6)
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.38)
}

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

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.cyan).frame(width: 3, height: 12).shadow(color: Theme.cyan, radius: 4)
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.5).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }
}

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
                .font(FontStyle.semibold)
                .foregroundStyle(isActive() ? activeColor : Theme.textTertiary)
                .shadow(color: shadow && isActive() ? activeColor : .clear, radius: 6)
            VStack(alignment: .leading, spacing: subtitles.count > 1 ? 2 : 1) {
                Text(title).font(FontStyle.semibold)
                    .foregroundStyle(Theme.textPrimary)
                // 直接迭代 range，零中间 Array 分配（UI 渲染路径）
                ForEach(0..<subtitles.count, id: \.self) { i in
                    Text(subtitles[i]).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
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

private let driveAnim = Animation.spring(response: 0.3)
private let driveAnimSlow = Animation.spring(response: 0.35)
private let keyAnim = Animation.easeInOut(duration: 0.08)
private let knobAnim = Animation.easeOut(duration: 0.25)

// MARK: - 字体常量（复用提取）

enum FontStyle {
    static let monoSemibold = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let semibold      = Font.system(size: 13, weight: .semibold)
}

enum DriveMode: String, CaseIterable, Identifiable {
    case e2e     = "端到端主驾"
    case yolo    = "YOLO接管"
    case recover = "脱困中"
    case rule    = "纯规则兜底"
    var id: String { rawValue }
    var uiGroup: DriveModeGroup {
        switch self {
        case .e2e, .yolo:     return .e2eDrive
        case .recover, .rule: return .ruleFallback
        }
    }
}

enum DriveModeGroup: String, CaseIterable, Identifiable {
    case e2eDrive     = "端到端主驾"
    case ruleFallback = "规则"
    var id: String { rawValue }
    var members: [DriveMode] {
        switch self {
        case .e2eDrive:     return [.e2e, .yolo]
        case .ruleFallback: return [.recover, .rule]
        }
    }
    func contains(_ m: DriveMode) -> Bool { members.contains(m) }
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

enum RecordLabelMapper {
    static let fullScaleDuration: TimeInterval = 0.6
    static func holdRatio(_ duration: TimeInterval) -> Double {
        min(1.0, max(0.0, duration / fullScaleDuration))
    }
    static func steer(leftHeld: TimeInterval, rightHeld: TimeInterval) -> Double {
        min(1.0, max(-1.0, holdRatio(rightHeld) - holdRatio(leftHeld)))
    }
    static func throttle(wHeld: TimeInterval) -> Double { holdRatio(wHeld) }
    static func brake(sHeld: TimeInterval, spaceHeld: TimeInterval) -> Double {
        max(holdRatio(sHeld), holdRatio(spaceHeld))
    }
}

@Observable
@MainActor
final class DriveState {

    // 启动参数诊断开关缓存：CommandLine.arguments 每次访问都重新构造
    // [String] 数组（堆分配）+ contains O(n) 扫描；定位热路径 4Hz×10 处
    // 调用会造成 ~40 次/秒无谓分配。启动时算一次，静态常量后续零开销。
    private enum LaunchFlags {
        static let locateLiveDiag   = CommandLine.arguments.contains("--locate-live")
        static let networkLocateDiag = CommandLine.arguments.contains("--network-locate")
    }

    var isDriving       = false
    var sportMode       = false
    var isTraining      = false

    var locatorFound = false
    var locatorX: Double = 0
    var locatorY: Double = 0
    var locatorScore: Double = 0
    var locatorReady = false
    var locatorHeading: Double = 0
    var locatorTarget: (x: Double, y: Double)? = nil
    private var lastLocPos: (x: Double, y: Double)? = nil

    nonisolated(unsafe) static var minimapROI = (centerX: 0.13, centerY: 0.14, sideFraction: 0.16)
    var minimapROIState: CGRect? = nil
    private let locateCtx = LocateContext()
    private let locateGate = LocateGate()
    private let locateQueue = DispatchQueue(label: "aurora.locate", qos: .userInteractive)
    var enableNetworkLocate = false
    var networkLocateScore: Double = 0
    var networkLocateMode: String = ""
    var networkLocateX: Double = 0
    var networkLocateY: Double = 0
    private var lastNetworkLocPos: (x: Double, y: Double)? = nil
    var networkLocateHeading: Double = 0
    private var networkLocator: NetworkLocator?
    private var networkLocatorLock: os_unfair_lock_s = os_unfair_lock_s()

    @ObservationIgnored var drivingRecorder = DrivingFrameRecorder(maxFrames: 5)

    var expertMode      = false
    var glyphMode       = false
    var controlDisabled = false
    var forceRuleMode = false
    var trainingLog     = ""

    @ObservationIgnored
    private var drivingStartTime = Date()
    @ObservationIgnored
    private var lastTickLog = Date.distantPast
    @ObservationIgnored
    private var lastUpscaleLiveLog = Date.distantPast

    private func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)"
        print(line)
        let url = URL(fileURLWithPath: "/tmp/aurora_debug.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
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

    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
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

    var mode: DriveMode = .e2e
    var confidence: Double = 0.92
    // P3优化：缓存格式化字符串，避免 SwiftUI 30Hz 重绘路径中反复 String(format:) 分配。
    // View 只读此属性，值变化时由 tick() 同步更新，重绘时无额外堆分配。
    @ObservationIgnored var confidenceText: String = "92.0%"
    // P6优化：mode 文字显示缓存，避免 render 路径中访问 uiGroup.rawValue 产生 String 分配。
    @ObservationIgnored private var modeDisplayText: String = "端到端主驾"
    // P8优化：mode 颜色缓存，render 路径读缓存字段而非每次计算三元表达式。
    @ObservationIgnored private var modeTextColor: Color = Theme.textTertiary
    private var lastDecided: DriveMode = .e2e

    var effectiveSpeed: Double = 0
    var speedValid: Bool = false
    var speed: Double { effectiveSpeed }
    var fps: Double = 60
    // P3优化：同上，fps 只在值变化时写入（line 1005 值检查），此处保持同步。
    @ObservationIgnored var fpsText: String = "60"
    var speedKmh: Double { speedOCR.speedKmh }
    // P3优化：speedKmh 是 computed property，每次 tick 取最新值，缓存格式化结果。
    @ObservationIgnored var speedKmhText: String = "--"
    var speedConfidence: Double { speedOCR.confidence }

    // P6优化：m9Status 是 computed property，每次 SwiftUI render 都调用 Date() 分配。
    // 改为缓存字段，tick() 中同步更新，render 路径零分配。
    @ObservationIgnored private var m9StatusText: String = "M9未加载"
    @ObservationIgnored private var m9StatusColor: Color = Theme.textTertiary

    var m9Status: (text: String, color: Color) {
        (m9StatusText, m9StatusColor)
    }

    var speedLimit: Double      = 120
    var degradeThreshold: Double = 0.65

    var modelVersion = "v2.4.1-e2e-fsd"
    var frames: Int  = 128_402

    @ObservationIgnored var currentScreenImage: NSImage? = nil
    @ObservationIgnored var currentFrameCG: CGImage? = nil
    @ObservationIgnored var frameHost = FrameHost()
    @ObservationIgnored var upscaleHost = UpscaleFrameHost()
    var upscaleEnabled: Bool = false
    var gameModeBoost: Bool = true
    var hudAnnotationMode = false
    var annotationTarget: HUDAnnotationTarget = .hud
    var hudROI: CGRect? = nil
    var upscaleSupported = false

    var showHistoricFrame: HistoricFrameSlot? = nil
    @ObservationIgnored var historicFrames: [HistoricFrameSlot: CGImage] = [:]
    // historicFrames 脏标记：记录上次刷新时的录制器帧计数，避免 30Hz 无条件重建字典
    @ObservationIgnored private var historicFramesStamp: Int = -1
    var upscaleLive: String? = nil
    var upscaleEngineError: String? = nil
    var screenSize: CGSize? = nil
    var isStreaming = false

    @ObservationIgnored
    nonisolated(unsafe) var frameDeliveryLagMs: Double = 0

    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrame: NSImage?
    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrameCG: CGImage?
    @ObservationIgnored
    private nonisolated(unsafe) var pendingFrameTime: Date?
    @ObservationIgnored
    private var pendingFrameLock: os_unfair_lock_s = os_unfair_lock_s()

    @ObservationIgnored
    private nonisolated(unsafe) var pendingYoloFrame: CVPixelBuffer?
    @ObservationIgnored
    private var pendingYoloLock: os_unfair_lock_s = os_unfair_lock_s()

    @ObservationIgnored
    private nonisolated(unsafe) var pendingNativeFrame: CVPixelBuffer?
    @ObservationIgnored
    private var pendingNativeLock: os_unfair_lock_s = os_unfair_lock_s()

    @ObservationIgnored
    private var lastTickTime = Date()
    @ObservationIgnored
    var tickGapMs: Double = 0

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

    let captureEngine = CaptureEngine()
    var capturePermissionDenied = false
    let controlEngine = ControlEngine()
    var controlPermissionDenied = false
    let keyboardMonitor = KeyboardMonitor()
    let degradeStm = DegradeStateMachine()
    let recordEngine = RecordEngine()
    let escapeController = EscapeController()
    let ruleController = RuleController()
    let confidenceEst = ConfidenceEstimator()
    let inferenceEngine = InferenceEngine()
    let assistEngine = InferenceEngine(modelFileName: "game_assist_control")
    let yoloEngine = YoloEngine()
    let speedOCR = SpeedOCRReader()

    private(set) var currentCommand: ControlCommand = .idle

    @MainActor private var backgroundActivity: NSObjectProtocol?

    init() {
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .background],
            reason: "AuroraDrive 持续实时推理+注入，防止被系统当作后台 App Nap 挂起/降权"
        )
        applyMainThreadBoost(true)
        loadROIPresets()
        try? FileManager.default.removeItem(atPath: "/tmp/aurora_debug.log")
        captureEngine.onFrame = { [weak self] image, cgImage in
            guard let self else { return }
            os_unfair_lock_lock(&self.pendingFrameLock)
            self.pendingFrame = image
            self.pendingFrameCG = cgImage
            self.pendingFrameTime = Date()
            os_unfair_lock_unlock(&self.pendingFrameLock)
            DispatchQueue.main.async { self.frameHost.push(cgImage) }
        }
        captureEngine.onYoloFrame = { [weak self] pb in
            guard let self else { return }
            os_unfair_lock_lock(&self.pendingYoloLock)
            self.pendingYoloFrame = pb
            os_unfair_lock_unlock(&self.pendingYoloLock)
        }
        captureEngine.onNativeFrame = { [weak self] pb in
            guard let self else { return }
            os_unfair_lock_lock(&self.pendingNativeLock)
            self.pendingNativeFrame = pb
            os_unfair_lock_unlock(&self.pendingNativeLock)
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
                    self?.frameHost.clear()
                    guard let self else { return }
                    os_unfair_lock_lock(&self.pendingFrameLock)
                    self.pendingFrame = nil
                    self.pendingFrameCG = nil
                    self.pendingFrameTime = nil
                    os_unfair_lock_unlock(&self.pendingFrameLock)
                    os_unfair_lock_lock(&self.pendingYoloLock)
                    self.pendingYoloFrame = nil
                    os_unfair_lock_unlock(&self.pendingYoloLock)
                    os_unfair_lock_lock(&self.pendingNativeLock)
                    self.pendingNativeFrame = nil
                    os_unfair_lock_unlock(&self.pendingNativeLock)
                }
            }
        }
        captureEngine.didStartCapture = { [weak self] in
            self?.isStreaming = true
            self?.dlog("[capture] 捕获已启动，isStreaming=true")
        }
        upscaleHost.prepare()
        upscaleSupported = upscaleHost.isAvailable
        dlog("[upscale] 引擎初始化: 可用=\(upscaleSupported)")
        captureEngine.onUpscaleFrame = { [weak self] pb in
            self?.upscaleHost.push(pixelBuffer: pb)
        }
    }

    func setUpscaleEnabled(_ on: Bool) {
        upscaleEnabled = on
        captureEngine.upscaleEnabled = on
        dlog("[upscale] 开关=\(on) 引擎可用=\(upscaleSupported)")
    }

    func setGameModeBoost(_ on: Bool) {
        gameModeBoost = on
        captureEngine.gameModeBoostEnabled = on
        applyMainThreadBoost(on)
        dlog("[boost] 游戏模式兼容=\(on)")
    }

    func beginAnnotation(_ target: HUDAnnotationTarget) {
        annotationTarget = target
        if !isStreaming {
            captureEngine.start()
        }
        hudAnnotationMode = true
        dlog("[hud] 进入标注: 目标=\(target == .hud ? "HUD" : "小地图") 流=\(isStreaming)")
    }

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

    func applyMinimapROI(_ rect: CGRect) {
        minimapROIState = rect
        let side = min(rect.width, rect.height)
        Self.minimapROI = (centerX: rect.midX, centerY: rect.midY, sideFraction: side)
        UserDefaults.standard.set([Double(rect.midX), Double(rect.midY), Double(side)],
                                  forKey: "aurora.minimapROI")
        dlog("[hud] 小地图 ROI: 中心=(\(String(format: "%.3f", rect.midX)),\(String(format: "%.3f", rect.midY))) 边长=\(String(format: "%.3f", side))")
    }

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

    static func heading(from: (x: Double, y: Double), to: (x: Double, y: Double)) -> Double {
        let dx = to.x - from.x, dy = to.y - from.y
        return ((atan2(dx, dy) * 180 / .pi) + 360).truncatingRemainder(dividingBy: 360)
    }

    func updateLocator(x: Double, y: Double, score: Double = 0) {
        locatorScore = score
        if let last = lastLocPos {
            let hx = x - last.x, hy = y - last.y
            if hx * hx + hy * hy > 16 {
                locatorHeading = Self.heading(from: last, to: (x: x, y: y))
            }
        }
        lastLocPos = (x, y)
        locatorX = x
        locatorY = y
        locatorFound = true
    }

    func setLocatorTarget(x: Double, y: Double) { locatorTarget = (x, y) }

    func runLocateStep() {
        guard isStreaming || isDriving, let cg = currentFrameCG else { return }
        guard locateGate.tryBegin() else { return }
        let snapshotCG = cg
        let roi = Self.minimapROI

        locateQueue.async { [weak self] in
            guard let self else { return }
            defer { self.locateGate.end() }
            applyLocatePrecedence()
            if self.locateCtx.visualLocator == nil {
                let v = VisualLocator(mapPath: "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png",
                                      workSizes: [1280, 1024, 768])
                let ok = (v.prepare() == nil)
                if LaunchFlags.locateLiveDiag {
                    print("[LOCATELIVE-DIAG] prepare ok=\(ok) scales=\(v.scaleCount)")
                }
                self.locateCtx.visualLocator = v
                self.locateCtx.visualReady = ok
            }
            guard self.locateCtx.visualReady, let loc = self.locateCtx.visualLocator else {
                DispatchQueue.main.async { [weak self] in
                    self?.locatorReady = false
                }
                if LaunchFlags.locateLiveDiag {
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
            if LaunchFlags.locateLiveDiag {
                print("[LOCATELIVE-DIAG] frame=\(Int(W))x\(Int(H)) side=\(Int(side)) rect=\(rect)")
            }
            guard side >= 24,
                  let crop = snapshotCG.cropping(to: rect),
                  let bytes = VisualLocator.minimapBytes(from: crop, side: 150) else {
                if LaunchFlags.locateLiveDiag {
                    print("[LOCATELIVE-DIAG] crop/minimapBytes failed")
                }
                return
            }

            if LaunchFlags.locateLiveDiag {
                let cropStd = bytes.reduce(0.0) { $0 + Double($1) }
                let cropMean = cropStd / Double(max(1, bytes.count))
                var sq = 0.0
                for b in bytes { let d = Double(b) - cropMean; sq += d * d }
                let std = sqrt(sq / Double(max(1, bytes.count)))
                FileHandle.standardError.write("[LOCATELIVE-DIAG] crop bytes mean=\(String(format: "%.1f", cropMean)) std=\(String(format: "%.1f", std))\n".data(using: .utf8)!)
                FileHandle.standardError.write("[LOCATELIVE-DIAG] calling locate bytes=\(bytes.count)\n".data(using: .utf8)!)
            }
            let res = loc.locate(template: bytes, tw: 150, th: 150, scoreThreshold: 0.5)
            if LaunchFlags.locateLiveDiag {
                FileHandle.standardError.write("[LOCATELIVE-DIAG] locate done found=\(res.found) score=\(String(format: "%.3f", res.score))\n".data(using: .utf8)!)
            }
            if res.found {
                if LaunchFlags.locateLiveDiag {
                    print("[LOCATELIVE-DIAG] 命中 x=\(Int(res.x)) y=\(Int(res.y)) score=\(String(format: "%.3f", res.score)) scale#\(res.scaleIndex)")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateLocator(x: res.x, y: res.y, score: res.score)
                }
            } else {
                if LaunchFlags.locateLiveDiag {
                    let fg = bytes.reduce(0) { $0 + Int($1) }
                    let mean = Double(fg) / Double(max(1, bytes.count))
                    print("[LOCATELIVE-DIAG] 未命中: frame=\(Int(W))x\(Int(H)) roi=\(Int(side))px " +
                          "template_fg=\(fg) mean=\(String(format: "%.1f", mean)) " +
                          "score=\(String(format: "%.3f", res.score)) scales=\(loc.scaleCount)")
                }
            }
        }
    }

    func runNetworkLocateStep() {
        if networkLocator == nil {
            os_unfair_lock_lock(&networkLocatorLock)
            defer { os_unfair_lock_unlock(&networkLocatorLock) }
            if networkLocator == nil {
                let nl = NetworkLocator()
                let ok = nl.prepare()
                if LaunchFlags.networkLocateDiag {
                    print("[NETWORK-LOCATE] prepare=\(ok) (启用网络定位)")
                }
                networkLocator = nl
                locateCtx.networkReady = ok
            }
        }
        guard let loc = networkLocator, locateCtx.networkReady else {
            DispatchQueue.main.async { [weak self] in
                self?.networkLocateScore = 0
                self?.networkLocateMode = "not_ready"
            }
            return
        }
        let result = loc.locate()
        if LaunchFlags.networkLocateDiag {
            print("[NETWORK-LOCATE] found=\(result.found) mode=\(result.mode) " +
                  "score=\(String(format: "%.2f", result.score))" +
                  (result.point != nil ? " point=\(result.point!.0),\(result.point!.1)" : ""))
        }
        guard result.found, let point = result.point else {
            DispatchQueue.main.async { [weak self] in
                self?.networkLocateScore = 0
                self?.networkLocateMode = result.mode
            }
            return
        }
        let px = Double(point.0), py = Double(point.1)
        var heading = result.cameraHeading ?? 0
        if let last = lastNetworkLocPos {
            let dx = px - last.x, dy = py - last.y
            if dx * dx + dy * dy > 16 {
                heading = Self.heading(from: last, to: (x: px, y: py))
            }
        }
        lastNetworkLocPos = (x: px, y: py)
        DispatchQueue.main.async { [weak self] in
            self?.networkLocateX = px
            self?.networkLocateY = py
            self?.networkLocateScore = result.score
            self?.networkLocateMode = result.mode
            self?.networkLocateHeading = heading
        }
    }

    @MainActor
    private func navigationRuleCommand(detections: [Detection]) -> ControlCommand {
        let fallback = ruleController.decide(detections: detections)
        if ruleController.dangerLevel != .safe {
            return fallback
        }
        let useNetwork = enableNetworkLocate && networkLocateScore > 0.5
        let found: Bool = useNetwork ? (networkLocateScore > 0.5) : locatorFound
        let locX: Double = useNetwork ? networkLocateX : locatorX
        let locY: Double = useNetwork ? networkLocateY : locatorY
        let locHeading: Double = useNetwork ? networkLocateHeading : locatorHeading
        guard found, let t = locatorTarget else { return fallback }

        let dx = t.x - locX
        let dy = t.y - locY
        let distSq = dx * dx + dy * dy
        guard distSq > 4 else { return fallback }

        let targetBearing = Self.heading(from: (x: locX, y: locY), to: t)
        var err = targetBearing.truncatingRemainder(dividingBy: 360) - locHeading
        if err > 180 { err -= 360 } else if err < -180 { err += 360 }
        let steer = max(-1.0, min(1.0, err / 40.0))
        return ControlCommand(steer: steer, throttle: 0.6, brake: 0, confidence: 0.9)
    }

    func startDriving() {
        guard controlEngine.checkPermission() else {
            controlPermissionDenied = true
            controlEngine.openAccessibilitySettings()
            return
        }
        controlPermissionDenied = false
        controlEngine.releaseAll()
        isDriving = true
        drivingStartTime = Date()
        keyboardMonitor.start()
        captureEngine.start()
        captureEngine.yoloScalingEnabled = true
        inferenceEngine.loadIfNeeded()
        assistEngine.loadIfNeeded()
        yoloEngine.loadIfNeeded()
        dlog("启动开车: 辅助功能权限=\(controlEngine.hasAccessibilityPermission) 专家模式=\(expertMode) 禁用控制=\(controlDisabled)")
        dlog("模型加载: M9=\(inferenceEngine.isLoaded) 第二司机=\(assistEngine.isLoaded) YOLO=\(yoloEngine.isLoaded) M9错误=\(inferenceEngine.errorMessage ?? "-")")
    }

    func stopDriving() {
        isDriving = false
        controlEngine.releaseAll()
        keyboardMonitor.stop()
        captureEngine.stop()
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
        if isRecording { isRecording = false }
    }

    @MainActor
    func startTraining() {
        guard !isTraining else { return }
        isTraining = true
        trainingLog = "启动训练进程…"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3.11")
        proc.arguments = ["src/train_game_assist.py", "--skip_view", "--skip_yolo"]
        proc.currentDirectoryURL = projectRootURL
        let logURL = projectRootURL.appendingPathComponent("train.log")
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

    func tick() {
        let tickNow = Date()
        tickGapMs = tickNow.timeIntervalSince(lastTickTime) * 1000
        lastTickTime = tickNow

        if tickNow.timeIntervalSince(lastUpscaleLiveLog) >= 1.0 {
            lastUpscaleLiveLog = tickNow
            if upscaleEnabled, let err = upscaleHost.pendingError() {
                upscaleEngineError = err
            }
            if upscaleEnabled, let st = upscaleHost.statsSnapshot() {
                upscaleLive = "产出 \(st.interpolatedFrameCount) · 透传 \(st.passthroughFrameCount) · 输入 \(String(format: "%.0f", st.captureFPS))fps → 输出 \(String(format: "%.0f", st.outputFPS))fps"
            } else {
                upscaleLive = nil
            }
        }

        os_unfair_lock_lock(&pendingFrameLock)
        if let latest = pendingFrame {
            pendingFrame = nil
            let latestCG = pendingFrameCG
            pendingFrameCG = nil
            if let t = pendingFrameTime {
                frameDeliveryLagMs = tickNow.timeIntervalSince(t) * 1000
            }
            pendingFrameTime = nil
            currentScreenImage = latest
            currentFrameCG = latestCG
            if screenSize != latest.size { screenSize = latest.size }
        }
        os_unfair_lock_unlock(&pendingFrameLock)

        os_unfair_lock_lock(&pendingYoloLock)
        let yoloFrame = pendingYoloFrame
        pendingYoloFrame = nil
        os_unfair_lock_unlock(&pendingYoloLock)
        if isDriving, let yoloFrame {
            yoloEngine.infer(pixelBuffer: yoloFrame)
        }

        os_unfair_lock_lock(&pendingNativeLock)
        let nativeFrame = pendingNativeFrame
        pendingNativeFrame = nil
        os_unfair_lock_unlock(&pendingNativeLock)
        if let nativeFrame {
            if isDriving || isRecording {
                speedOCR.infer(nativePixelBuffer: nativeFrame)
            }
            if recordEngine.glyphMode && recordEngine.isRecording {
                recordEngine.appendGlyphNative(pixelBuffer: nativeFrame)
                frames = recordEngine.frameCount
            }
        }

        degradeStm.degradeHealth = degradeThreshold

        if isDriving, let cg = currentFrameCG {
            drivingRecorder.tryAppend(cg, now: tickNow)
        }
        // 脏检查：仅当录制器追加了新帧才重建 historicFrames 字典。
        // 每 tick 无条件写字典 = 30Hz 的 hash + CGImage retain/release 浪费。
        if historicFramesStamp != drivingRecorder.frameCount {
            historicFramesStamp = drivingRecorder.frameCount
            for slot in HistoricFrameSlot.allCases {
                historicFrames[slot] = drivingRecorder.frameAt(secondsAgo: slot == .threeSecondsAgo ? 2 : 3)
            }
        }

        guard isDriving else {
            // 非驾驶下这三项会收敛到常量（false / 0 / .idle）后长期不变；
            // @Observable setter 无条件触发 willSet，值检查挡住 30Hz 无效化风暴。
            if speedValid { speedValid = false }
            let decayed = max(0, effectiveSpeed - 6)
            if effectiveSpeed != decayed { effectiveSpeed = decayed }
            if currentCommand != .idle { currentCommand = .idle }
            recordFrameIfNeeded()
            return
        }

        let dt = 1.0 / 30.0

        if let cg = currentFrameCG {
            if !forceRuleMode {
                inferenceEngine.infer(image: cg, speedKmh: effectiveSpeed, speedLimitKmh: speedLimit)
            }
            assistEngine.infer(image: cg, speedKmh: effectiveSpeed, speedLimitKmh: speedLimit)
            if !yoloEngine.fastPathActive {
                yoloEngine.infer(image: cg)
            }
        }

        let m9Command = commandOf(inferenceEngine)
        let assistCommand = commandOf(assistEngine)
        let m9Live = engineAlive(inferenceEngine, now: tickNow)
        let assistLive = engineAlive(assistEngine, now: tickNow)
        // P6优化：m9Status 缓存，避免 SwiftUI render 路径每次调用 Date()。
        // inferenceEngine.isLoaded 只在模型加载/卸载时变化，lastResultTime 每推理完成更新。
        if !inferenceEngine.isLoaded {
            m9StatusText = "M9未加载"; m9StatusColor = Theme.textTertiary
        } else if m9Live {
            m9StatusText = "M9活跃"; m9StatusColor = Theme.cyan
        } else {
            m9StatusText = "M9失联"; m9StatusColor = Theme.danger
        }

        let detections = yoloEngine.detections

        let ocrFresh = speedOCR.speedKmh >= 0
            && speedOCR.confidence > 0.3
            && (speedOCR.lastResultTime.map { tickNow.timeIntervalSince($0) < 0.5 } ?? false)
        if speedValid != ocrFresh { speedValid = ocrFresh }
        if ocrFresh {
            effectiveSpeed += (speedOCR.speedKmh - effectiveSpeed) * 0.7
        } else {
            effectiveSpeed *= 0.9
            if effectiveSpeed < 0.5 { effectiveSpeed = 0 }
        }
        // captureFPS 平稳时恒为 30/60，值检查避免每 tick 触发 UI 无效化
        let liveFps = captureEngine.captureFPS > 0 ? captureEngine.captureFPS : 60
        // P3优化：fps 只在值真正变化时更新缓存字符串，避免每 tick 额外 String(format:) 分配。
        if fps != liveFps { fps = liveFps; fpsText = String(format: "%.0f", fps) }

        let warmingUp = inferenceEngine.lastResult == nil
            && tickNow.timeIntervalSince(drivingStartTime) < 3.0
        let decided = degradeStm.update(m9Live: m9Live,
                                        assistLive: assistLive,
                                        health: confidence,
                                        warmingUp: warmingUp,
                                        speedKmh: effectiveSpeed,
                                        speedValid: speedValid,
                                        dt: dt,
                                        sportMode: sportMode,
                                        forceRule: forceRuleMode,
                                        now: tickNow)
        if mode != decided { mode = decided }
        // P6优化：modeDisplayText 缓存，render 路径读缓存字段而非访问 uiGroup.rawValue。
        modeDisplayText = decided == .recover ? "脱困中" : decided.uiGroup.rawValue
        // P8优化：modeTextColor 缓存，避免 render 路径每次求三元表达式。
        modeTextColor = isDriving && decided == .recover ? Theme.orangeRed : (isDriving ? Theme.cyan : Theme.textTertiary)

        if warmingUp {
            if confidence != 1.0 { confidence = 1.0 }
        } else {
            let healthCommand: ControlCommand = (mode == .e2e) ? m9Command : assistCommand
            let healthLive: Bool = (mode == .e2e) ? m9Live : assistLive
            confidenceEst.update(command: healthCommand,
                                 image: currentFrameCG,
                                 isLive: healthLive)
            confidence = confidenceEst.confidence
            // P5修复：confidenceText 缓存必须在 confidence 赋值后同步更新，
            // 否则 ConfidenceReadout 始终显示初始值 "92.0%"。
            confidenceText = String(format: "%.1f%%", confidence * 100)
        }
        // P4优化：speedKmhText 值检查后赋值，speedKmh 未变化时跳过 String(format:) 和字符串分配。
        let newSpeedKmh = speedKmh
        if (newSpeedKmh >= 0) != (speedKmhText != "--") {
            speedKmhText = newSpeedKmh >= 0 ? String(format: "%.0f", newSpeedKmh) : "--"
        }

        switch decided {
        case .e2e:
            if currentCommand != m9Command { currentCommand = m9Command }
            escapeController.reset()
        case .yolo:
            if currentCommand != assistCommand { currentCommand = assistCommand }
            escapeController.reset()
        case .rule:
            let ruleCmd = navigationRuleCommand(detections: detections)
            if currentCommand != ruleCmd { currentCommand = ruleCmd }
            escapeController.reset()
        case .recover:
            if lastDecided != .recover { escapeController.enter() }
            let (cmd, escaped) = escapeController.update(dt: dt, speedKmh: effectiveSpeed)
            if currentCommand != cmd { currentCommand = cmd }
            if escaped {
                degradeStm.reset()
            }
        }

        lastDecided = decided

        if expertMode || controlDisabled {
            controlEngine.releaseAll()
        } else {
            applyCommand(currentCommand)
        }

        recordFrameIfNeeded()

        if tickNow.timeIntervalSince(lastTickLog) >= 1.0 {
            lastTickLog = tickNow
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
                 + (enableNetworkLocate
                    ? " net=\(networkLocateScore > 0.5 ? "1" : "0"):\(String(format: "%.2f", networkLocateScore))"
                        + "\(networkLocateX > 0 ? " px=(\(Int(networkLocateX)),\(Int(networkLocateY)))" : "")"
                        + " mode=\(networkLocateMode)"
                    : " net=off")
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

    private func recordFrameIfNeeded() {
        guard !recordEngine.glyphMode, isRecording, let image = currentScreenImage else { return }
        let steer: Double
        let throttle: Double
        let brake: Double
        if expertMode {
            steer = RecordLabelMapper.steer(leftHeld: keyboardMonitor.holdDuration(keyCode: 0),
                                            rightHeld: keyboardMonitor.holdDuration(keyCode: 2))
            throttle = RecordLabelMapper.throttle(wHeld: keyboardMonitor.holdDuration(keyCode: 13))
            brake = RecordLabelMapper.brake(sHeld: keyboardMonitor.holdDuration(keyCode: 1),
                                            spaceHeld: keyboardMonitor.holdDuration(keyCode: 49))
        } else {
            steer = currentCommand.steer
            throttle = currentCommand.throttle
            brake = currentCommand.brake
        }
        recordEngine.appendFrame(image: image, steer: steer, throttle: throttle, brake: brake)
        frames = recordEngine.frameCount
    }

    // MARK: - tick 辅助：从 Engine 读指令/存活状态（避免 tick 内联访问 @Published）

    // P1修复：提取为独立方法，避免在 tick() 里写嵌套闭包捕获 tickNow
    private func commandOf(_ engine: InferenceEngine) -> ControlCommand {
        guard let r = engine.lastResult else { return .idle }
        return ControlCommand(steer: r.steer, throttle: r.throttle, brake: r.brake, confidence: r.latencyMs < 500 ? 1 : 0)
    }

    // P1修复：同上，计算"最近1s内有结果即视为活着"，避免每 tick 重算
    private func engineAlive(_ engine: InferenceEngine, now: Date) -> Bool {
        guard let t = engine.lastResultTime else { return false }
        return now.timeIntervalSince(t) < 1.0
    }

    private func applyCommand(_ cmd: ControlCommand) {
        if cmd.steer > 0.1 {
            controlEngine.hold(.steerRight); controlEngine.release(.steerLeft)
        } else if cmd.steer < -0.1 {
            controlEngine.hold(.steerLeft); controlEngine.release(.steerRight)
        } else {
            controlEngine.release(.steerLeft); controlEngine.release(.steerRight)
        }
        if cmd.throttle > 0.3 {
            controlEngine.hold(.throttle); controlEngine.release(.brake)
        } else if cmd.brake > 0.3 {
            controlEngine.hold(.brake); controlEngine.release(.throttle)
        } else {
            controlEngine.release(.throttle); controlEngine.release(.brake)
        }
        controlEngine.refreshHeldKeys()
    }
}

struct ContentView: View {
    @State private var state = DriveState()

    @State private var tickTimer: Timer? = nil
    @State private var locatorTimer: Timer? = nil

    @State private var automationOpen = false

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                GameViewportView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SidebarView(state: state, automationOpen: $automationOpen)
                    .frame(width: 360)
                if automationOpen {
                    AutomationDrawer(open: $automationOpen)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, 44)

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
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { state.tick() }
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
            let locTimer = Timer(timeInterval: 1.0 / 4.0, repeats: true) { _ in
                MainActor.assumeIsolated { state.runLocateStep() }
            }
            locTimer.tolerance = 0
            RunLoop.main.add(locTimer, forMode: .common)
            locatorTimer = locTimer
            if state.enableNetworkLocate {
                let netLocTimer = Timer(timeInterval: 1.0 / 4.0, repeats: true) { _ in
                    MainActor.assumeIsolated { state.runNetworkLocateStep() }
                }
                netLocTimer.tolerance = 0
                RunLoop.main.add(netLocTimer, forMode: .common)
            }
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
            if args.contains("--locate-selftest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let argCV = args
                    let px = argCV.firstIndex(of: "--locate-selftest")
                    let x: Double = px.flatMap { i in argCV.indices.contains(i + 1) ? Double(argCV[i + 1]) : nil } ?? -1
                    let y: Double = px.flatMap { i in argCV.indices.contains(i + 2) ? Double(argCV[i + 2]) : nil } ?? -1
                    runLocateSelfTest(explicitX: x, explicitY: y)
                }
            }
            if args.contains("--locate-live") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runLocateLiveSelfCheck()
                }
            }
            if args.contains("--network-locate") {
                state.enableNetworkLocate = true
                print("[NETWORK-LOCATE] 已启用网络定位模式")
            }
        }
    }
}

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

private func applyLocatePrecedence() {
    var pol = thread_precedence_policy_data_t(importance: 2)
    _ = withUnsafeMutablePointer(to: &pol) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: 1) { ip in
            thread_policy_set(mach_thread_self(), UInt32(THREAD_PRECEDENCE_POLICY), ip, 1)
        }
    }
}

private func runLocateSelfTest(explicitX: Double, explicitY: Double) {    let mapPath = projectRootURL.appendingPathComponent("models/bigworldmapSecond.png").path
    let locator = VisualLocator(mapPath: mapPath, workSizes: [1024, 768])
    guard let err = locator.prepare() else {
        let cx = explicitX > 0 ? explicitX : (Double(locator.originWidth) * 0.55)
        let cy = explicitY > 0 ? explicitY : (Double(locator.originHeight) * 0.45)
        let out = locator.runSelfTest(expectedX: cx, expectedY: cy)
        print("[LOCATESELFTEST] 档数=\(locator.scaleCount) \(out)")
        exit(out.hasPrefix("SELFTEST PASS") ? 0 : 1)
    }
    print("[LOCATESELFTEST] FAIL: \(err)")
    exit(1)
}

@MainActor
private func runLocateLiveSelfCheck() {
    let mapPath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: mapPath) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("[LOCATELIVE] FAIL: 无法读地图"); exit(1)
    }
    let sW = 1920, sH = 1080
    let span = 150.0 / (1280.0 / 11264.0)
    let spanPx = Int(span.rounded())

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
        let vals = bytes.map { Double($0) * AuroraDriveApp.inv255d }
        let mean = vals.reduce(0.0, +) / Double(vals.count)
        var sq = 0.0
        for v in vals { let d = v - mean; sq += d * d }
        let std = sqrt(sq / Double(vals.count))
        if std > bestStd {
            bestStd = std
            expect = (Double(px) + Double(spanPx) / 2, Double(py) + Double(spanPx) / 2)
        }
    }
    guard bestStd >= 0.04 else {
        print("[LOCATELIVE] FAIL 地图候选区均过于平坦 (bestStd=\(String(format: "%.3f", bestStd)))")
        exit(1)
    }
    let expectX = expect.0, expectY = expect.1

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
    let roYTop = sH - roY1
    ctx.draw(block, in: CGRect(x: CGFloat(roX0), y: CGFloat(roYTop),
                               width: CGFloat(roX1 - roX0), height: CGFloat(roY1 - roY0)))
    guard let screenImg = ctx.makeImage() else {
        print("[LOCATELIVE] FAIL: makeImage"); exit(1)
    }

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
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

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

enum HUDAnnotationTarget {
    case hud
    case minimap
}

enum HistoricFrameSlot: String, CaseIterable, Identifiable {
    case threeSecondsAgo = "3s前"
    case sixSecondsAgo = "6s前"
    var id: Self { self }
}

private func toolButton(
    icon: String, label: String, isActive: Bool, activeColor: Color,
    action: @escaping () -> Void, disabled: Bool = false, help: String? = nil
) -> some View {
    Button(action: action) {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isActive ? activeColor : Theme.textSecondary)
        .ph10v5()
        .background(Capsule().fill(Color.white.opacity(isActive ? 0.12 : 0.05)))
        .overlay(Capsule().strokeBorder(isActive ? activeColor.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(help ?? "")
}

struct TopToolbar: View {
    @Bindable var state: DriveState

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "steeringwheel")
                    .font(FontStyle.semibold)
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

            HStack(spacing: 10) {
                toolButton(
                    icon: "scope", label: "标注HUD",
                    isActive: state.hudAnnotationMode && state.annotationTarget == .hud,
                    activeColor: Theme.cyan,
                    action: { state.beginAnnotation(.hud) },
                    help: "框选游戏里的速度表区域，保存为 HUD 预设（记忆）"
                )
                toolButton(
                    icon: "map", label: "标注小地图",
                    isActive: state.hudAnnotationMode && state.annotationTarget == .minimap,
                    activeColor: Theme.cyan,
                    action: { state.beginAnnotation(.minimap) },
                    help: "框选游戏内的小地图，保存为定位预设（记忆）"
                )
                toolButton(
                    icon: "clock.arrow.counterclockwise", label: "3秒前",
                    isActive: state.showHistoricFrame == .threeSecondsAgo,
                    activeColor: Theme.orangeRed,
                    action: { state.showHistoricFrame = .threeSecondsAgo },
                    disabled: state.drivingRecorder.frameCount < 1,
                    help: "回看3秒前的画面（需要至少2帧记录）"
                )
                toolButton(
                    icon: "clock.arrow.counterclockwise", label: "6秒前",
                    isActive: state.showHistoricFrame == .sixSecondsAgo,
                    activeColor: Theme.orangeRed,
                    action: { state.showHistoricFrame = .sixSecondsAgo },
                    disabled: state.drivingRecorder.frameCount < 2
                )

                Circle()
                    .fill(state.isDriving ? Theme.cyan : Theme.textTertiary)
                    .frame(width: 7, height: 7)
                    .shadow(color: state.isDriving ? Theme.cyan : .clear, radius: 5)
                Text(state.isDriving ? state.modeDisplayText : "待机")
                    .font(FontStyle.monoSemibold)
                    .foregroundStyle(state.modeTextColor)
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

struct GameViewportView: View {
    @Bindable var state: DriveState

    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

            if state.isStreaming {
                if state.upscaleEnabled {
                    UpscaleFrameHostView(host: state.upscaleHost)
                        .onChange(of: state.upscaleEnabled) { _, on in
                            if !on { state.upscaleHost.clear() }
                        }
                } else {
                    FrameHostView(host: state.frameHost)
                }
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
                                        .font(FontStyle.monoSemibold)
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
                VStack(spacing: 12) {
                    Image(systemName: "steeringwheel")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Theme.cyan.opacity(0.3))
                        .shadow(color: Theme.cyan.opacity(0.2), radius: 12)

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

            if !state.hudAnnotationMode {
                MinimapLocatorView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(true)
                    .padding(10)
            }

            if !state.hudAnnotationMode {
                ObstacleOverlay(active: state.isDriving,
                                detections: state.yoloEngine.detections,
                                sourceSize: state.screenSize,
                                lockedTarget: state.yoloEngine.lockedTarget,
                                isLocked: state.yoloEngine.isLocked)
            }

            ROIBoxLayer(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(10)

            if state.hudAnnotationMode {
                HUDAnnotationOverlay(state: state)
                    .zIndex(20)
            }

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
                        .ph10v5()
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.orangeRed.opacity(0.5), lineWidth: 1))
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(true)
            }

            VStack {
                Spacer().frame(height: 240)
                Ellipse()
                    .fill(RadialGradient(
                        colors: [Theme.cyan.opacity(state.isDriving ? 0.16 : 0.05), .clear],
                        center: .center, startRadius: 10, endRadius: 260))
                    .frame(width: 700, height: 120)
                    .blur(radius: 20)
                    .allowsHitTesting(false)
                Spacer()
            }

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

            VStack {
                Spacer()
                KeyboardBar(state: state)
                    .padding(.bottom, 8)
            }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard state.isDriving else { return }
                        if dragStart == nil { dragStart = v.startLocation }
                        dragCurrent = v.location
                    }
                    .onEnded { v in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard state.isDriving else { return }
                        let s = dragStart ?? v.startLocation
                        let c = dragCurrent ?? v.location

                        let srcSize = state.frameHost.latestSize
                        let viewSize = geo.size
                        guard let n1 = viewToSourceNorm(s, source: srcSize, view: viewSize),
                              let n2 = viewToSourceNorm(c, source: srcSize, view: viewSize) else { return }

                        let rect = CGRect(x: min(n1.x, n2.x), y: min(n1.y, n2.y),
                                          width: abs(n2.x - n1.x), height: abs(n2.y - n1.y))

                        if rect.width > 0.05 && rect.height > 0.05 {
                            state.yoloEngine.setLock(x: rect.midX, y: rect.midY,
                                                     width: rect.width, height: rect.height)
                        } else {
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
                LinearGradient(colors: [Theme.cyan.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 1)
            }
        }
    }

    private static func normDist(_ d: Detection, _ p: CGPoint) -> Double {
        hypot(d.x - p.x, d.y - p.y)
    }
}

struct KeyboardBar: View {
    let state: DriveState

    var body: some View {
        HStack(spacing: 6) {
            KeyCap(label: "W", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .throttle)))
            KeyCap(label: "A", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .steerLeft)))
            KeyCap(label: "S", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .brake)))
            KeyCap(label: "D", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .steerRight)))
            KeyCap(label: "␣", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .handbrake)), wide: true)
            KeyCap(label: "⇧", active: state.keyboardMonitor.isHeld(state.controlEngine.keyMap.keyCode(for: .boost)))
        }
        .ph10v5()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct KeyCap: View {
    let label: String
    let active: Bool
    var wide: Bool = false

    var body: some View {
        Text(label)
            .font(FontStyle.monoSemibold)
            .foregroundStyle(active ? Color.black : Theme.textTertiary)
            .frame(width: wide ? 60 : 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Theme.keyActive : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Color(red: 0.0, green: 1.0, blue: 0.6) : Theme.cyan.opacity(0.3),
                                  lineWidth: 1)
            )
            .shadow(color: active ? Theme.keyActive.opacity(0.8) : .clear, radius: 6)
            .animation(keyAnim, value: active)
    }
}

// 将源图尺寸以 aspect-fill 方式映射到视图尺寸：等比缩放后取覆盖视图的矩形。
// 返回 {origin: 左上角偏移, size: 视图内实际占据的宽高}，用于归一化坐标 → 像素坐标的转换。
private func aspectFillLayout(source: CGSize?, view: CGSize) -> (origin: CGPoint, size: CGSize) {
    guard let src = source, src.width > 0, src.height > 0 else {
        return (CGPoint(x: 0, y: 0), CGSize(width: view.width, height: view.height))
    }
    let scale = max(view.width / src.width, view.height / src.height)
    let w = src.width * scale
    let h = src.height * scale
    return (CGPoint(x: (view.width - w) / 2, y: (view.height - h) / 2), CGSize(width: w, height: h))
}

struct ObstacleOverlay: View {
    var active: Bool
    var detections: [Detection] = []
    var sourceSize: CGSize? = nil
    var lockedTarget: Detection? = nil
    var isLocked: Bool = false
    // P7优化：缓存检测标签字符串，避免 30Hz Canvas render 路径中每帧 per-detection String(format:) 分配。
    // 仅在 detections 数量变化时重建（dirty-check 代替 @State）。
    @ObservationIgnored private var labelCacheStamp: Int = -1
    @ObservationIgnored private var cachedLabels: [String] = []

    private static func color(for label: CocoLabels.Category) -> Color {
        switch label {
        case .person:      return Theme.danger
        case .car:         return Theme.cyan
        case .stopSign:    return Color(red: 1.0, green: 0.82, blue: 0.25)
        default:           return Theme.orangeRed
        }
    }

    var body: some View {
        // P7优化：detections 数量变化时重建标签缓存，之后 Canvas render 路径零 String(format:) 分配。
        if labelCacheStamp != detections.count {
            labelCacheStamp = detections.count
            cachedLabels = detections.map { "\($0.rawName) \(String(format: "%.2f", $0.confidence))" }
        }
        Canvas { ctx, size in
            guard active else { return }
            let t = aspectFillLayout(source: sourceSize, view: size)
            for (i, d) in detections.enumerated() {
                let c = Self.color(for: d.label)
                let danger = d.isInDangerZone()
                let w = max(d.width * t.size.width, 2)
                let h = max(d.height * t.size.height, 2)
                let cx = t.origin.x + d.x * t.size.width
                let cy = t.origin.y + d.y * t.size.height
                let box = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(c.opacity(danger ? 0.18 : 0.08)))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 4),
                           with: .color(c.opacity(0.9)),
                           style: StrokeStyle(lineWidth: danger ? 2.2 : 1.4))
                let label = cachedLabels[i]
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
            if isLocked, let lt = lockedTarget {
                let w = max(lt.width * t.size.width, 6)
                let h = max(lt.height * t.size.height, 6)
                let cx = t.origin.x + lt.x * t.size.width
                let cy = t.origin.y + lt.y * t.size.height
                let box = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.orangeRed.opacity(0.12)))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.orangeRed), style: StrokeStyle(lineWidth: 3))
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
                        .ph8v3()
                        .background(.black.opacity(0.6), in: Capsule())
                        .position(x: rect.midX, y: max(16, rect.minY - 16))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if current == nil { start = v.startLocation }
                        current = v.location
                    }
                    .onEnded { _ in
                    }
            )
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    Text(state.annotationTarget == .hud ? "标注目标：HUD 速度表" : "标注目标：小地图")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: Capsule())

                    Spacer()

                    Button {
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
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
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

// MARK: - FrameHost
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
        if let cg = cachedCGImage { view.layer?.contents = cg }
    }

    func push(_ image: CGImage) {
        cachedCGImage = image
        hostView?.layer?.contents = image
    }

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

// MARK: - UpscaleFrameHost
final class UpscaleFrameHost {
    private weak var mtkView: MTKView?
    private var engine: GooseUpscaler?

    private(set) var isAvailable = false

    private let ingestQueue = DispatchQueue(label: "aurora.upscale.ingest", qos: .userInitiated)
    private var frameLock: os_unfair_lock_s = os_unfair_lock_s()
    private var latestBuffer: CVPixelBuffer?
    private var isDraining = false

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

    private(set) var lastAttachInfo: String?

    func push(pixelBuffer: CVPixelBuffer) {
        guard engine != nil else { return }
        os_unfair_lock_lock(&frameLock)
        let start: Bool
        latestBuffer = pixelBuffer
        if isDraining {
            start = false
        } else {
            isDraining = true
            start = true
        }
        os_unfair_lock_unlock(&frameLock)
        if start { drain() }
    }

    private func drain() {
        ingestQueue.async { [weak self] in
            guard let self else { return }
            while true {
                os_unfair_lock_lock(&self.frameLock)
                let buf: CVPixelBuffer?
                if self.latestBuffer == nil {
                    self.isDraining = false
                    buf = nil
                } else {
                    buf = self.latestBuffer
                    self.latestBuffer = nil
                }
                os_unfair_lock_unlock(&self.frameLock)
                guard let buf,
                      let engine = self.engine,
                      let cg = Self.cgImage(from: buf) else {
                    os_unfair_lock_lock(&self.frameLock)
                    self.isDraining = false
                    os_unfair_lock_unlock(&self.frameLock)
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
                AutomationCard(open: $automationOpen)
            }
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.55))
        .background(Color.black.opacity(0.55))
    }
}

struct StatusPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "STATUS")

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(DriveModeGroup.allCases) { g in
                        ModeGroupChip(group: g, active: state.isDriving && g.contains(state.mode))
                    }
                }

                // 失效域最小化：confidence / speedKmh 驾驶中每 tick 变化，
                // 拆成独立子视图后 @Observable 失效只重算小块（~4 节点），
                // 而非整个 StatusPanel（~30 节点）每 33ms 全量重建 diff。
                ConfidenceReadout(state: state)

                HStack(alignment: .center, spacing: 10) {
                    SpeedReadout(state: state)
                    Spacer()
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
                        Text(state.fpsText)
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

// 只读 confidence 的高频子视图：失效范围 = 本视图
private struct ConfidenceReadout: View {
    @Bindable var state: DriveState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("置信度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(state.confidenceText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
            }
            ConfidenceBar(value: state.confidence)
        }
    }
}

// 只读 speedKmh 的高频子视图：失效范围 = 本视图
private struct SpeedReadout: View {
    @Bindable var state: DriveState

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(state.speedKmhText)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Theme.cyan.opacity(0.45), radius: 12)
                .contentTransition(.numericText())
            Text("km/h")
                .font(FontStyle.semibold)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

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
        .foregroundStyle(active ? .black : Theme.textSecondary)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Theme.cyan : Color.white.opacity(0.05))
                .shadow(color: active ? Theme.cyan.opacity(0.8) : .clear, radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? .clear : Color.white.opacity(0.09), lineWidth: 1)
        )
        .animation(driveAnim, value: active)
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
        .animation(knobAnim, value: value)
    }
}

struct ControlPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(spacing: 14) {
                SectionHeader(title: "CONTROL")
                Button {
                        withAnimation(driveAnim) {
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

                Button {
                    withAnimation(driveAnimSlow) {
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

                SettingRow(icon: "flame.fill", title: "极速模式", subtitles: ["解除限速,全速冲刺"],
                           isActive: { state.sportMode }, activeColor: Theme.orangeRed,
                           shadow: true, binding: $state.sportMode, disabled: false)
            }
        }
    }
}

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

                SettingRow(icon: "record.circle", title: "行驶录制", subtitles: [],
                           isActive: { state.isRecording }, activeColor: Theme.danger,
                           shadow: false, binding: $state.isRecording, disabled: false)

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

struct TrainingPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        GlowCard {
            VStack(spacing: 12) {
                SectionHeader(title: "TRAINING")

                SettingRow(icon: "person.crop.circle", title: "专家模式（录真人键）", subtitles: [],
                           isActive: { state.expertMode }, activeColor: Theme.cyan,
                           shadow: false, binding: $state.expertMode, disabled: false)

                SettingRow(icon: "number.square", title: "字模模式（录原生速度表）", subtitles: [],
                           isActive: { state.glyphMode }, activeColor: Theme.cyan,
                           shadow: false, binding: $state.glyphMode, disabled: false)
                if !state.trainingLog.isEmpty {
                    Text(state.trainingLog)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    TrainButton(
                        title: state.isRecording ? "录制中" : "录制",
                        icon: "record.circle",
                        tint: Theme.danger,
                        filled: state.isRecording
                    ) { state.isRecording.toggle() }

                    TrainButton(
                        title: state.isTraining ? "训练中…" : "训练",
                        icon: "cpu",
                        tint: Theme.cyan,
                        filled: state.isTraining
                    ) { state.startTraining() }
                }

                HStack {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text("模型版本")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(state.modelVersion)
                        .font(FontStyle.monoSemibold)
                        .foregroundStyle(Theme.textSecondary)
                        .ph8v3()
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
                    .font(FontStyle.semibold)
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

final class DrivingFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [CGImage] = []
    private let maxFrames: Int

    private var lastSaveTime = Date.distantPast

    init(maxFrames: Int = 5) {
        self.maxFrames = maxFrames
    }

    func tryAppend(_ cg: CGImage?, now: Date = Date()) {
        guard let cg else { return }
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastSaveTime) >= 3.0 else { return }
        lastSaveTime = now
        _frames.append(cg)
        if _frames.count > maxFrames {
            _frames.removeFirst(_frames.count - maxFrames)
        }
    }

    func frameAt(secondsAgo: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let index = _frames.count - secondsAgo
        guard index > 0, index <= _frames.count else { return nil }
        return _frames[index - 1]
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frames.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _frames.removeAll()
        lastSaveTime = Date.distantPast
    }
}
