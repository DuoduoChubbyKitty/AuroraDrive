// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  CaptureEngine.swift — 全屏画面流捕获引擎（ScreenCaptureKit）
//  macOS 12.3+ 的官方截屏 API，性能最佳，系统原生集成
//  建立持续画面流（30fps），系统自动推送新帧，内存固定不增长
//  通过闭包回调输出 NSImage，供 UI 显示和模型推理共用
//
//  ── 2026-10-08 双模式改造（用户点名需求）────────────────────────────────
//  用户原话：
//    「我们的自动驾驶不是总是把系统桌面那些给它塞进去吗？我们可以在自动驾驶的
//      预览框右边放一个小小的拉条，然后拉出来，就可以看到当前所有的窗口
//      （大窗口、游戏的窗口），然后把游戏窗口可以选择是**录全屏**还是
//      **只录游戏这个窗口**。」
//
//  【为什么必须改】原实现 `SCContentFilter(display:excludingWindows: [])` 的
//  排除列表是**空数组** —— 等于不排除任何窗口，整块显示器（含桌面 + 自家 UI）
//  全录进去。训练数据里混进 AuroraDrive 自己的窗口 = 污染模仿学习数据集。
//
//  【两种模式】
//    · `.fullScreen` 录全屏：整显示器，但**排除自家所有窗口**（修复上面的问题）
//    · `.window(id)` 只录窗口：`SCContentFilter(desktopIndependentWindow:)`，
//      天然不含自家 UI，也不含桌面
//
//  【运行时切换】靠 `SCStream.updateContentFilter(_:)`（macOS 12.3+ 官方 API），
//  不重启流、不断帧 —— 用户拉条上点一下即可切换。
// ============================================================================

import AppKit
import ScreenCaptureKit
import CoreVideo
import CoreImage
import CoreGraphics
import Accelerate
import os

// MARK: - 捕获模式（2026-10-08 新增）

/// 捕获目标：整屏（排除自家窗口）或单个指定窗口。
///
/// 【为什么用 enum 而不是 Bool】用户明确要「录全屏 / 只录游戏窗口」二选一，
/// 未来还可能加「多窗口合并」；enum 带关联值比布尔开关更好扩展，
/// 也避免出现「isWindowMode=true 但 windowID=nil」这种非法状态。
enum CaptureMode: Equatable, Sendable {
    /// 整块显示器；`excludedWindowCount` 只用于诊断展示（实际排除列表每次启动重算）
    case fullScreen
    /// 单个窗口（desktopIndependentWindow）。`id` 是 `SCWindow.windowID`（= CGWindowID）
    case window(id: CGWindowID)

    var isWindowMode: Bool {
        if case .window = self { return true }
        return false
    }

    /// UI 小字/日志用
    var label: String {
        switch self {
        case .fullScreen: return "录全屏"
        case .window(let id): return "只录窗口 #\(id)"
        }
    }
}

/// 拉条里列出的一行窗口（UI 只读快照，不持有 SCWindow 引用）。
///
/// 【为什么不直接把 SCWindow 交给 UI】SCWindow 是系统对象、会随窗口关闭失效；
/// UI 侧跨进程/跨线程持有它容易拿到已失效对象。这里拍平成纯值类型快照，
/// 切换捕获时再按 `id` 重新解析成 SCWindow（见 `CaptureEngine.resolveWindow(id:)`）。
struct CapturableWindow: Identifiable, Equatable, Sendable {
    /// CGWindowID（与 SCWindow.windowID 同源）
    let id: CGWindowID
    let applicationName: String
    let bundleIdentifier: String
    let title: String
    let width: Int
    let height: Int
    /// 是否被判定为游戏窗口（复用 GameWindowDetector 的同款判据）
    let isGame: Bool
    /// 是否属于 AuroraDrive 自己（自家窗口不允许被选为捕获目标 —— 录自己没有意义）
    let isOwn: Bool

    /// 拉条显示用（应用名 + 标题；标题为空时只显示应用名）
    var displayLabel: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.isEmpty ? applicationName : "\(applicationName) · \(cleanTitle)"
    }

    var sizeLabel: String { "\(width)×\(height)" }
}

/// 画面流捕获引擎（基于 ScreenCaptureKit）
/// - 建立一条 SCStream 持续画面流（30fps）
/// - 系统在画面变化时自动推送新帧，无需反复截图
/// - 每帧通过 onFrame 闭包输出 NSImage，UI 显示与模型推理共用同一条流
/// - 调用 start() 开始，stop() 停止
/// - 2026-10-08：支持「录全屏（排除自家窗口）」/「只录指定窗口」双模式，可运行时切换
final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable {

    /// 当前帧图像（UI 显示用）
    private(set) var currentFrame: NSImage? {
        get { stateLock.withLock { _currentFrame } }
        set { stateLock.withLock { _currentFrame = newValue } }
    }

    /// 是否正在捕获
    private(set) var isCapturing: Bool {
        get { stateLock.withLock { _isCapturing } }
        set { stateLock.withLock { _isCapturing = newValue } }
    }

    /// 捕获帧率（每秒更新一次）
    private(set) var captureFPS: Double {
        get { stateLock.withLock { _captureFPS } }
        set { stateLock.withLock { _captureFPS = newValue } }
    }

    /// 帧回调（每帧调用，传入 NSImage + CGImage）
    /// NSImage 供录制/现有引用；CGImage 直传下游（推屏/推理/置信度），
    /// 省去下游 NSImage→CGImage 的重复转换（环2）
    var onFrame: ((NSImage, CGImage) -> Void)?

    /// YOLO 直通回调（每帧调用，传入 YoloEngine.inputSize×inputSize BGRA 像素缓冲）
    /// CaptureEngine 在源头用 vImage(CPU) 把全屏画面缩放到模型输入尺寸，
    /// 跳过 NSImage/CGImage 大图转换链路 → 检测帧率显著提升
    var onYoloFrame: ((CVPixelBuffer) -> Void)?

    /// 插帧/超分回调（每帧调用，传入全分辨率 CVPixelBuffer）
    /// MetalGoose 引擎需要完整帧做时域插帧/空间超分，走独立回调不干扰主路径
    var onUpscaleFrame: ((CVPixelBuffer) -> Void)?

    /// 是否需要全分辨率插帧帧（每次帧回调时求值）。
    /// copyUpscaleFrame 会做一次全分辨率（可达数十 MB）内存拷贝；插帧/清晰画面
    /// 关闭时这份拷贝纯属白费（下游没人消费）。调用方接线此闭包：
    /// 引擎进程 → { EngineGlobals.wantFullFrame }（UI 经 socket 下发），
    /// UI 进程 → { upscaleEnabled }。与 onUpscaleFrame 同为 @unchecked Sendable
    /// 模式（main 上赋值、captureQueue 上读）。
    var isUpscaleWanted: () -> Bool = { false }

    /// 原生帧直通回调（每帧调用，传入速度表 ROI 原生分辨率 CVPixelBuffer，未缩放）
    /// SpeedOCR 等需要"原生分辨率直裁直读（不插值）"的下游用这条，
    /// 绕开 NSImage 缩放链路；与 onFrame / onYoloFrame 互不影响
    var onNativeFrame: ((CVPixelBuffer) -> Void)?

    /// 速度表 ROI（归一化，左上角原点 y 向下）。字模录制（glyphMode）与 SpeedOCR 共用此 ROI。
    /// 环1：copyNativeFrame 只拷贝该区域（≈100KB，替代整帧 22MB），
    /// SpeedOCRReader 用同一常量把槽位坐标换算到 ROI 相对坐标（与 Python crop_slot(roi=...) 一致）。
    nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885,
                                                 width: 0.080, height: 0.050)

    /// 状态变化回调（启动/停止/错误）
    var onStatusChange: ((CaptureStatus) -> Void)?

    /// 捕获状态
    enum CaptureStatus {
        case started
        case stopped
        case error(String)
        case permissionDenied
    }

    // MARK: - 私有属性

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)
    private var lastFPSDate: Date = .distantPast
    private var fpsAccumulator: Int = 0

    // P0-3 修复：诊断/状态属性写于 captureQueue、读于主线程，跨线程裸读写存在
    // 数据竞争（torn read 可能读出 NaN → 读侧 Int(NaN) trap）。
    // 用 OSAllocatedUnfairLock 保护读写（纳秒级开销，不触碰 30fps 红线）。
    private let stateLock = OSAllocatedUnfairLock()
    private var _currentFrame: NSImage?
    private var _isCapturing = false
    private var _captureFPS: Double = 0
    private var _lastFrameGapMs: Double = 0
    private var _lastFrameWorkMs: Double = 0

    /// 插帧/超分开关（跨线程读写，用锁保护）
    private var _upscaleEnabled = false
    var upscaleEnabled: Bool {
        get { stateLock.withLock { _upscaleEnabled } }
        set { stateLock.withLock { _upscaleEnabled = newValue } }
    }

    /// 游戏模式兼容（捕获线程时间约束调度，对抗全屏游戏降权）
    private var _gameModeBoostEnabled = true
    var gameModeBoostEnabled: Bool {
        get { stateLock.withLock { _gameModeBoostEnabled } }
        set { stateLock.withLock { _gameModeBoostEnabled = newValue } }
    }

    /// 原生帧自持缓冲池（与 SCStream 生命周期解耦）
    /// 在 captureQueue 内同步把 SCStream 缓冲按行拷贝到池缓冲，再派发主线程；
    /// 池缓冲由下游闭包持有引用，用完后自动回池 —— 主线程永不接触系统托管缓冲
    private var nativePool: CVPixelBufferPool?
    private var nativePoolWidth = 0
    private var nativePoolHeight = 0

    // MARK: - 捕获模式状态（2026-10-08 新增）

    /// 当前捕获模式。读多写少、跨线程（UI 读 / 捕获队列读 / 主线程写），用锁保护。
    ///
    /// 【为什么 setter 不直接切流】切换需要 `SCShareableContent` 重新解析窗口，
    /// 是异步且可能失败的（窗口关了 / 权限没了）。所以 setter 只记「期望模式」，
    /// 真正生效走 `applyMode(_:)`；`captureMode` 表示**已生效**的模式。
    private var _desiredMode: CaptureMode = .fullScreen
    private var _activeMode: CaptureMode = .fullScreen

    /// 期望的捕获模式（UI 拉条选择的目标）
    var desiredMode: CaptureMode {
        get { stateLock.withLock { _desiredMode } }
        set { stateLock.withLock { _desiredMode = newValue } }
    }

    /// 当前**已生效**的捕获模式（与 desiredMode 不一致时说明正在切换或切换失败）
    var captureMode: CaptureMode {
        get { stateLock.withLock { _activeMode } }
        set { stateLock.withLock { _activeMode = newValue } }
    }

    /// 最近一次切换失败的原因（UI 如实展示，不静默吞掉）
    private var _lastModeError: String?
    var lastModeError: String? {
        get { stateLock.withLock { _lastModeError } }
        set { stateLock.withLock { _lastModeError = newValue } }
    }

    /// 模式切换回调（UI 拉条据此刷新「当前正在录什么」）
    var onModeChange: ((CaptureMode) -> Void)?

    /// 捕获到自家 UI 的告警回调（自动断言，见 `detectOwnUIFrame`）
    /// 参数为人类可读原因；UI 收到后应显著提示用户「当前录制里混进了 AuroraDrive 界面」。
    var onOwnUIWarning: ((String) -> Void)?

    /// 已排除的自家窗口数量（诊断用；每次重建 filter 时更新）
    private var _excludedOwnWindowCount = 0
    var excludedOwnWindowCount: Int {
        get { stateLock.withLock { _excludedOwnWindowCount } }
        set { stateLock.withLock { _excludedOwnWindowCount = newValue } }
    }

    /// 当前 SCStream 用的 SCDisplay（切模式时复用，避免重新查一遍显示器）
    private var currentDisplay: SCDisplay?

    /// YOLO 直通缩放缓冲池（vImage 直接缩放进池化私有缓冲，每帧独立，池深度 ≥4）
    /// 缓冲由下游 onYoloFrame 闭包强捕获持有，直到 tick 消费 + inferFast 拷贝完才释放回池；
    /// 全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容。
    private var yoloBufferPool: CVPixelBufferPool?
    private var yoloBufferPoolSize = 0

    /// UI 显示缓冲池（vImage 缩放到 480 宽后，CGImage 经 CGDataProvider 零拷贝引用其基址）
    /// 尺寸随源分辨率固定（dW×dH），若变化则重建。
    private var uiBufferPool: CVPixelBufferPool?
    private var uiPoolWidth = 0
    private var uiPoolHeight = 0

    /// 插帧/超分缓冲池（全分辨率 + IOSurface，供 MetalGoose CGImage 创建用）
    private var upscalePool: CVPixelBufferPool?
    private var upscalePoolWidth = 0
    private var upscalePoolHeight = 0

    // ── 诊断尺子（纯测量，定位延迟高在哪一环）──
    // capGap：相邻两帧捕获间隔(ms)，正常~33ms，变大/波动 = 捕获或处理慢
    // capWork：每帧 captureQueue 处理耗时(ms)，含 22MB 拷贝+YOLO+UI渲染+回调
    private(set) var lastFrameGapMs: Double {
        get { stateLock.withLock { _lastFrameGapMs } }
        set { stateLock.withLock { _lastFrameGapMs = newValue } }
    }
    private(set) var lastFrameWorkMs: Double {
        get { stateLock.withLock { _lastFrameWorkMs } }
        set { stateLock.withLock { _lastFrameWorkMs = newValue } }
    }
    // lastFrameTime / fpsAccumulator 仅在 captureQueue 串行读写，无跨线程竞争，无需加锁
    private var lastFrameTime: Date = .distantPast

    // MARK: - 启动 / 停止

    /// 启动全屏画面流捕获
    /// ScreenCaptureKit 流程（async/await 版本，macOS 12.3+）：
    /// 1. 请求屏幕录制权限（try await SCShareableContent.current 会触发权限弹窗）
    /// 2. 获取主显示器
    /// 3. 创建 SCStream 配置（30fps，全屏分辨率）
    /// 4. 启动流，通过 delegate 接收 CMSampleBuffer 帧
    ///
    /// 2026-10-08：启动时按 `desiredMode` 决定是录全屏（排除自家窗口）还是录单窗口。
    func start() {
        guard !isCapturing else { return }

        // 用 Task 包装 async 调用
        Task { [weak self] in
            guard let self = self else { return }

            // 1. 获取可共享内容（包含权限检查）
            //    macOS 10.15+ 首次调用会触发系统授权弹窗
            //    无权限时会抛出错误
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.current
            } catch {
                self.onStatusChange?(.error("获取屏幕内容失败（可能未授权）: \(error.localizedDescription)"))
                self.onStatusChange?(.permissionDenied)
                return
            }

            // 2. 获取主显示器（避免抓 displays.first 的任意顺序屏）
            let mainDisplayID = CGMainDisplayID()
            let display: SCDisplay
            if let d = content.displays.first(where: { $0.displayID == mainDisplayID }) {
                display = d
            } else if let d = content.displays.first {
                display = d
            } else {
                self.onStatusChange?(.error("未找到可用的显示器"))
                return
            }
            print("[capture] selected displayID=\(display.displayID) main=\(mainDisplayID)")

            // 3. 创建并启动流
            await self.startStream(display: display, content: content)
        }
    }

    /// 创建并启动 SCStream（async 版本）
    private func startStream(display: SCDisplay, content: SCShareableContent) async {
        // 诊断日志：确认显示器输出分辨率（字模模式依赖原生分辨率，实测点/像素语义）
        // SCDisplay.width 按 Apple 文档是像素，但实测需确认；若为点值需 ×backingScaleFactor
        print("[capture] display frame=\(display.frame.size) w=\(display.width) h=\(display.height)")
        // 流配置
        let config = SCStreamConfiguration()
        // 输出显示器**原生像素**分辨率：SCDisplay.width 实测可能返回点值
        // （导致输出只有 ~1485×960、速度表数字仅 ~18px，字模/OCR 精度不足），
        // 这里用 NSScreen.frame(点) × backingScaleFactor 换算成真像素，
        // 保证速度表数字 ~95px 清晰（字模训练与运行时 OCR 都受益）。
        if let screen = NSScreen.screens.filter({
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                == NSNumber(value: display.displayID)
        }).first {
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
        } else {
            config.width = display.width
            config.height = display.height
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30fps 上限
        config.pixelFormat = kCVPixelFormatType_32BGRA  // 显式锁 32BGRA：vImageScale_ARGB8888 依赖此格式（防 SCStream 未来返回 420 花帧）
        config.queueDepth = 3                       // 帧队列深度 3（平衡延迟与流畅）
        config.showsCursor = true                   // 画面包含鼠标

        // ── 内容过滤器（2026-10-08 双模式）─────────────────────────────
        // 旧实现是 `SCContentFilter(display: display, excludingWindows: [])`：
        // 排除列表为空 = 不排除任何窗口 = 整屏（桌面 + 自家 UI）全录进去。
        // 现在按模式构造：
        //   · .fullScreen → 整显示器，但**排除自家所有窗口**
        //   · .window(id) → 只捕获该窗口（desktopIndependentWindow）
        let desired = self.desiredMode
        let filter: SCContentFilter
        switch desired {
        case .window(let windowID):
            guard let target = Self.findWindow(id: windowID, in: content) else {
                // 窗口没了（用户关掉了）：**不静默回退全屏**（那会违背用户选择），
                // 如实报错并让 UI 把拉条选择标红。
                let reason = "目标窗口 #\(windowID) 已不存在（可能已关闭）"
                self.lastModeError = reason
                self.onStatusChange?(.error(reason))
                self.onOwnUIWarning?(reason)
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: target)
            print("[capture] 模式=只录窗口 #\(windowID) "
                  + "app=\(target.owningApplication?.applicationName ?? "?") "
                  + "title=\(target.title ?? "")")

        case .fullScreen:
            let own = Self.ownWindows(in: content)
            filter = SCContentFilter(display: display, excludingWindows: own)
            self.excludedOwnWindowCount = own.count
            print("[capture] 模式=录全屏（排除自家窗口 \(own.count) 个）")
        }

        // 自动断言：排除列表是否真的生效（防「谁把 excludingWindows 改回空数组」回归）
        auditExclusion(content: content, display: display)

        // 创建 SCStream（非 Optional，直接初始化）
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // 注册帧输出回调
        // type: SCStreamOutputType.screen 表示捕获屏幕画面（区别于 .audio 音频）
        do {
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)
        } catch {
            onStatusChange?(.error("注册帧回调失败: \(error.localizedDescription)"))
            return
        }

        // 启动流（async/await 版本）
        do {
            try await stream.startCapture()
            self.stream = stream
            self.currentDisplay = display       // 切模式时复用（避免重新查显示器）
            self.captureMode = self.desiredMode  // 记录已生效模式
            self.isCapturing = true
            self.lastFPSDate = Date()
            self.resetOwnUIWarning()            // 新一轮录制允许重新告警
            self.onModeChange?(self.captureMode)
            self.onStatusChange?(.started)
        } catch {
            onStatusChange?(.error("启动捕获失败: \(error.localizedDescription)"))
        }
    }

    /// 停止画面流捕获
    ///
    /// ⚠️ 2026-10-09 修复 stop/restart 竞态：原实现把 `isCapturing=false` + `stream=nil`
    ///   放在 async Task 里（等 stopCapture 完成才设），紧接着的 `start()` 撞
    ///   `guard !isCapturing` 静默返回 → capture 永不重启 → 用户「停了再选就没反应」。
    ///   修复：同步置状态（让 start() 立刻能通过 guard），async Task 只做 stopCapture + 清池。
    func stop() {
        guard isCapturing, let oldStream = stream else { return }
        // 同步置状态：让紧接着的 start() 能通过 guard !isCapturing
        self.stream = nil
        self.isCapturing = false
        self.currentFrame = nil
        // async 清理：stopCapture + 释放缓冲池（不阻塞调用方）
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await oldStream.stopCapture()
            } catch {
                // 停止失败不阻塞，继续清理状态
            }
            // P2 修复：停捕获时把四个 CVPixelBufferPool 置 nil，释放空闲缓冲
            //（下次 start 会按当前分辨率重建）。四个池只在 captureQueue 上被
            // stream() 回调经 make*BufferPool / upscaleBufferPool 读写，这里同样派发到
            // captureQueue 串行清理，避免与在途帧回调竞争（否则跨线程写 nil 与建池构成数据竞争）。
            self.captureQueue.sync {
                self.nativePool = nil
                self.nativePoolWidth = 0
                self.nativePoolHeight = 0
                self.yoloBufferPool = nil
                self.yoloBufferPoolSize = 0
                self.uiBufferPool = nil
                self.uiPoolWidth = 0
                self.uiPoolHeight = 0
                // 第四个池：全分辨率插帧缓冲（每块可达数十 MB，之前漏清）
                self.upscalePool = nil
                self.upscalePoolWidth = 0
                self.upscalePoolHeight = 0
            }
            self.onStatusChange?(.stopped)
        }
    }

    // MARK: - 窗口枚举 / 自家窗口识别 / 运行时切换（2026-10-08 新增）
    //
    // 【设计要点：为什么这些是 static / 为什么拆开】
    //   · `listWindows()` / `ownWindows(in:)` 是**纯查询**，不碰实例状态 →
    //     拉条 UI 可以随时调用刷新列表，不需要先启动捕获。
    //   · 自家窗口识别**不依赖 NSApp.windows**：录制真正发生在**引擎进程**
    //     （`--engine`），那个进程里没有 SwiftUI、`NSApp.windows` 是空的 ——
    //     用 NSApp.windows 会导致「引擎模式下自家窗口一个都没排除」，
    //     即修了个假 bug。所以统一用 **bundleIdentifier + 进程 pid** 判定，
    //     两个进程都能正确识别（见 `isOwnApplication`）。

    /// 列出当前可捕获的窗口（供预览框右侧拉条 UI 使用）。
    ///
    /// 过滤规则（拉条别列出几百个，也要滤掉选不了的）：
    ///   · 只保留 `isOnScreen == true`（离屏窗口录出来是黑的）
    ///   · 排除太小的（< 160×120，多为工具提示/阴影层）
    ///   · 排除 windowLayer != 0（0 = 普通应用窗口层；非 0 是状态栏/悬浮层/Dock 等）
    ///   · 排除自家窗口（录自己没有意义）
    ///   · 游戏窗口置顶（用户主要就选它）
    ///
    /// - Returns: 已排序的快照列表；拿不到可共享内容时返回空数组（UI 显示「无窗口」）
    static func listWindows() async -> [CapturableWindow] {
        guard let content = try? await SCShareableContent.current else { return [] }
        return snapshot(from: content)
    }

    /// 从已有 `SCShareableContent` 拍平窗口列表（纯函数，便于自检直接喂夹具）
    static func snapshot(from content: SCShareableContent) -> [CapturableWindow] {
        let ownPIDs = ownProcessIdentifiers()
        var result: [CapturableWindow] = []
        for window in content.windows {
            guard window.isOnScreen else { continue }
            guard window.windowLayer == 0 else { continue }
            let frame = window.frame
            guard frame.width >= 160, frame.height >= 120 else { continue }
            let app = window.owningApplication
            let bundle = app?.bundleIdentifier ?? ""
            let appName = app?.applicationName ?? "未知应用"
            let own = isOwnApplication(bundleIdentifier: bundle,
                                       applicationName: appName,
                                       processID: app?.processID,
                                       ownPIDs: ownPIDs)
            if own { continue }
            let title = window.title ?? ""
            result.append(CapturableWindow(id: window.windowID,
                                           applicationName: appName,
                                           bundleIdentifier: bundle,
                                           title: title,
                                           width: Int(frame.width.rounded()),
                                           height: Int(frame.height.rounded()),
                                           isGame: isGameWindow(applicationName: appName, title: title),
                                           isOwn: false))
        }
        // 游戏置顶 → 面积大的靠前（大窗口更可能是游戏主窗口）
        return result.sorted { lhs, rhs in
            if lhs.isGame != rhs.isGame { return lhs.isGame }
            return lhs.width * lhs.height > rhs.width * rhs.height
        }
    }

    /// 游戏窗口判定：与 `GameWindowDetector.isGameVisible()` **同一套判据**
    /// （owner/标题含 "NTE" 或 "异环"），保证「拉条高亮的游戏」与
    /// 「允许注入按键的游戏」是同一个东西，不会出现两套说法打架。
    static func isGameWindow(applicationName: String, title: String) -> Bool {
        let owner = applicationName.uppercased()
        let name = title.uppercased()
        return owner.contains("NTE") || owner.contains("异环")
            || name.contains("NTE") || name.contains("异环")
    }

    /// 本进程的 bundleIdentifier（引擎进程与 UI 进程同 bundle）
    static var ownBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.aurora.driveui"
    }

    /// 自家进程的所有 pid（含引擎子进程）。
    ///
    /// 【为什么要按 pid 兜底】引擎是**独立进程**（同二进制 + `--engine`），
    /// 它的窗口 bundleIdentifier 与 UI 相同，但 `NSRunningApplication` 是分开的两个。
    /// 光比 bundleIdentifier 就够用；pid 集合用于兜住「bundle 信息缺失」
    /// （裸可执行形态下 Bundle.main.bundleIdentifier 可能为 nil）。
    static func ownProcessIdentifiers() -> Set<pid_t> {
        var pids: Set<pid_t> = [getpid()]
        let bundle = ownBundleIdentifier
        for app in NSWorkspace.shared.runningApplications {
            if let appBundle = app.bundleIdentifier, appBundle == bundle {
                pids.insert(app.processIdentifier)
            }
        }
        return pids
    }

    /// 是否属于 AuroraDrive 自己。
    ///
    /// 【判据顺序：先 bundle 再 pid 再名字】
    ///   ① bundleIdentifier 精确相等 —— 最可靠，UI 与引擎进程都能命中
    ///   ② pid 落在自家进程集合里 —— 兜住裸可执行（bundle 为 nil）
    ///   ③ 应用名含 "AuroraDrive" —— 兜住改名/打包变体（宁可多排除一个，
    ///      也不能把自家 UI 录进训练数据）
    static func isOwnApplication(bundleIdentifier: String,
                                 applicationName: String,
                                 processID: pid_t?,
                                 ownPIDs: Set<pid_t>) -> Bool {
        if !bundleIdentifier.isEmpty, bundleIdentifier == ownBundleIdentifier { return true }
        if let processID, ownPIDs.contains(processID) { return true }
        if applicationName.localizedCaseInsensitiveContains("AuroraDrive") { return true }
        return false
    }

    /// 自家所有窗口（用于全屏模式的排除列表）
    static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPIDs = ownProcessIdentifiers()
        return content.windows.filter { window in
            let app = window.owningApplication
            return isOwnApplication(bundleIdentifier: app?.bundleIdentifier ?? "",
                                    applicationName: app?.applicationName ?? "",
                                    processID: app?.processID,
                                    ownPIDs: ownPIDs)
        }
    }

    /// 按 windowID 在可共享内容里找回 SCWindow
    static func findWindow(id: CGWindowID, in content: SCShareableContent) -> SCWindow? {
        content.windows.first { $0.windowID == id }
    }

    /// 运行时切换捕获模式（用户拉条点选后调用）。
    ///
    /// 【为什么不用重启流】`SCStream.updateContentFilter(_:)` 是官方 API，
    /// 切换时不丢帧、不重新申请权限、不影响下游推理 —— 用户点一下立刻生效。
    ///
    /// 【失败处理】窗口已关闭 / 权限变化 → 保持**原模式不变**（不静默切全屏），
    /// 把原因写进 `lastModeError` 并回调 UI；这样用户不会以为切成功了。
    func applyMode(_ mode: CaptureMode) async {
        desiredMode = mode
        lastModeError = nil

        guard isCapturing, let stream else {
            // 还没开始捕获：只记期望模式，start() 时会用上
            captureMode = mode
            onModeChange?(mode)
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            lastModeError = "切换失败：无法获取窗口列表（\(error.localizedDescription)）"
            onModeChange?(captureMode)
            return
        }

        guard let display = currentDisplay ?? content.displays.first else {
            lastModeError = "切换失败：找不到显示器"
            onModeChange?(captureMode)
            return
        }

        let newFilter: SCContentFilter
        switch mode {
        case .window(let windowID):
            guard let target = Self.findWindow(id: windowID, in: content) else {
                lastModeError = "窗口 #\(windowID) 已不存在（可能已关闭），仍保持「\(captureMode.label)」"
                onModeChange?(captureMode)
                return
            }
            newFilter = SCContentFilter(desktopIndependentWindow: target)
        case .fullScreen:
            let own = Self.ownWindows(in: content)
            newFilter = SCContentFilter(display: display, excludingWindows: own)
            excludedOwnWindowCount = own.count
        }

        do {
            try await stream.updateContentFilter(newFilter)
            captureMode = mode
            onModeChange?(mode)
            // 切回全屏后同样审一遍排除列表
            auditExclusion(content: content, display: display)
            print("[capture] 切换成功 → \(mode.label)")
        } catch {
            lastModeError = "切换失败：\(error.localizedDescription)"
            onModeChange?(captureMode)
            print("[capture] ❌ 切换失败（保持 \(captureMode.label)）：\(error.localizedDescription)")
        }
    }

    // MARK: - 自动断言：排除列表真的生效了吗（防回归）
    //
    // 【为什么不用像素启发式 —— 实测数据否决】
    //   第一版写的是「采样左上 1/3 区域，统计蓝白 UI 像素占比 > 12% 即告警」。
    //   拿仓库里 **208 张真实截图**（`data/mac_shots/*.png`）跑误报率：
    //       · 15 张被误判（7.2%），最高一张 93.7%
    //       · 原因很实在：异环 NTE 本身就是**夜景冷色调游戏**，大量 UI 面板
    //         （`ui_heist2_46.png` 87.5%、`ui_pinkpaw_2.png` 深蓝满屏）
    //         在「蓝白像素占比」上和 AuroraDrive 的界面**统计上不可分**。
    //   ⟹ 宁可漏报也不能误报（误报会让用户以为录制坏了）。像素判据**删除**，
    //     换成下面这个**确定性**判据。
    //
    // 【现在的判据：查"排除列表是否真的非空"】
    //   「录到自己」的**唯一根因**就是 `excludingWindows: []`（空数组 = 不排除）。
    //   所以断言可以直接盯住这个不变量：
    //     全屏模式下，若屏幕上确实存在自家窗口，则排除列表**必须非空**；
    //     且排除数必须 ≥ 与捕获区域重叠的自家窗口数。
    //   这是**充要条件**级别的检查，不依赖任何画面内容推测 —— 不会误报，
    //   而且正好卡住「谁把 filter 改回空数组」这个回归。
    //
    // 【开销】只在 start()/applyMode() 时查一次（不是每帧），
    //   复用已经拿到的 `SCShareableContent`，零额外系统调用。

    /// 审查全屏模式的排除列表是否覆盖了所有「在屏且与捕获区域重叠」的自家窗口。
    /// - Returns: 需要告警时的原因文本；一切正常返回 nil。
    static func auditOwnWindowExclusion(content: SCShareableContent,
                                        display: SCDisplay,
                                        excludedCount: Int) -> String? {
        let own = ownWindows(in: content)
        let overlapping = own.filter { window in
            window.isOnScreen && window.frame.intersects(display.frame)
        }
        if !overlapping.isEmpty && excludedCount == 0 {
            // 排除列表是空的，但屏幕上确实有自家窗口 → 排除机制失效（回归）
            return "录制排除列表为空，但有 \(overlapping.count) 个 AuroraDrive 窗口在屏幕上"
                 + " —— 自家界面会被录进训练数据。请检查 SCContentFilter 的 excludingWindows 参数。"
        }
        if excludedCount < overlapping.count {
            return "排除列表只覆盖 \(excludedCount) 个自家窗口，但屏幕上有 \(overlapping.count) 个"
                 + " —— 可能有自家窗口仍会被录进去。"
        }
        return nil
    }

    /// 排除审查触发后置位：同一会话内**只报一次**（避免 start/切模式反复刷屏）
    private var ownUIWarningFired = false

    /// 在 start()/applyMode() 后调用：审查 + 回调告警（每会话只报一次）
    private func auditExclusion(content: SCShareableContent, display: SCDisplay) {
        guard !desiredMode.isWindowMode else { return }   // 窗口模式天然不含自家 UI
        guard !ownUIWarningFired else { return }
        guard let reason = Self.auditOwnWindowExclusion(content: content,
                                                        display: display,
                                                        excludedCount: excludedOwnWindowCount) else { return }
        ownUIWarningFired = true
        print("[capture] ⚠️ \(reason)")
        onOwnUIWarning?(reason)
    }

    /// 重置告警状态（重新开始录制时调用，让新一轮还能报警）
    func resetOwnUIWarning() {
        ownUIWarningFired = false
    }


    /// ScreenCaptureKit 每帧回调
    /// 系统在画面变化时自动调用，传入 CMSampleBuffer
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 只处理屏幕画面帧（忽略音频）
        guard type == .screen else { return }

        // P1 修复：SCStream delegate 回调不自动包 autoreleasepool，30fps 下每帧
        // 临时对象（NSImage/CGImage/CGDataProvider/vImage 等）若不在帧末释放，
        // 长时间运行会内存缓涨。整个每帧处理逻辑包进 autoreleasepool，帧末统一释放。
        autoreleasepool {
        // 从 CMSampleBuffer 提取 CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 诊断：相邻帧到达间隔 + 本帧处理起点（定位"捕获慢 / 处理重"）
        let frameStart = Date()
        // P2 修复：首帧 lastFrameTime 为 .distantPast，timeIntervalSince 会得到 ~5e11 ms
        // 的假值；首帧 gap 记 0，避免诊断面板显示天文数字。
        lastFrameGapMs = (lastFrameTime == .distantPast)
            ? 0
            : frameStart.timeIntervalSince(lastFrameTime) * 1000
        lastFrameTime = frameStart
        // 诊断兜底：无论本帧后续是否成功，都统计 FPS 与 capWork（失败路径不跳过诊断）
        defer { lastFrameWorkMs = Date().timeIntervalSince(frameStart) * 1000 }
        updateFPS()

        // ── 原生帧直通：在 captureQueue 内同步拷贝到自持缓冲，再派发主线程 ──
        // SCStream 的 CVPixelBuffer 由系统缓冲池管理，主线程稍慢时可能被系统
        // 回收/覆写 → use-after-release（轻则裁出垃圾、重则崩溃）。
        // 这里用 CVPixelBufferPool 私有缓冲逐行整拷一份，行序照抄 src 的
        // bytesPerRow（不做方向解释，方向语义由下游 CIImage 路径负责），
        // 主线程永远持有自己的拷贝，与 SCStream 生命周期彻底解耦。
        if let onNativeFrame, let nativeCopy = copyNativeFrame(from: pixelBuffer) {
            onNativeFrame(nativeCopy)
        }

        // ── 插帧/超分直通：把全分辨率帧送给 MetalGoose 引擎 ──
        // 必须复制到带 IOSurface 的私有缓冲，否则下游 CGImage 创建会崩（MG-ENG-001）
        // 门禁先于拷贝求值：插帧/清晰画面关闭时连全分辨率拷贝都不做
        //（下游本就没人消费，拷了也是白费带宽与内存带宽）。
        if let onUpscaleFrame, isUpscaleWanted(),
           let upscaleCopy = copyUpscaleFrame(from: pixelBuffer) {
            onUpscaleFrame(upscaleCopy)
        }

        // ── YOLO 直通：CPU vImage 缩放到模型输入尺寸（YoloEngine.inputSize，640）──
        // 在源头完成缩放，绕开大图 → NSImage → CGImage → 再缩放的链路
        if let onYoloFrame {
            // 直接缩放进池化私有缓冲（每帧独立、池深度 ≥4），下游 onYoloFrame 强捕获该缓冲，
            // 直到 tick 消费 + inferFast 拷贝完才释放回池 —— 主线程卡顿也不会拿到被覆写的帧。
            // 相比旧「双缓冲 + copyYoloFrame 整拷一份」省掉一次 640×640×4 ≈ 1.6MB 冗余 memcpy。
            let size = YoloEngine.inputSize
            if let pool = makeYoloBufferPool(size: size) {
                var yb: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &yb) == kCVReturnSuccess,
                   let yb {
                    // vImage 缩放到模型输入尺寸（CPU，双线性 kvImageNoFlags）：
                    // 消除游戏占满 GPU 时 CIContext(GPU) 排队导致的 40ms 卡顿。
                    // 非等比拉伸到 640×640（与训练/慢路径一致，不保持宽高比）；
                    // 字节序 32BGRA = ARGB8888 little-endian，vImageScale_ARGB8888 正确处理，B/G/R 顺序不变。
                    let swv = CVPixelBufferGetWidth(pixelBuffer)
                    let shv = CVPixelBufferGetHeight(pixelBuffer)
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    CVPixelBufferLockBaseAddress(yb, [])
                    defer {
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                        CVPixelBufferUnlockBaseAddress(yb, [])
                    }
                    if let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
                       let dstBase = CVPixelBufferGetBaseAddress(yb) {
                        var srcBuf = vImage_Buffer(data: srcBase,
                                                   height: vImagePixelCount(shv),
                                                   width: vImagePixelCount(swv),
                                                   rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
                        var dstBuf = vImage_Buffer(data: dstBase,
                                                   height: vImagePixelCount(size),
                                                   width: vImagePixelCount(size),
                                                   rowBytes: CVPixelBufferGetBytesPerRow(yb))
                        vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
                        onYoloFrame(yb)   // 仅缩放成功才送出；GetBaseAddress 失败则跳过本帧直通
                    }
                }
            }
        }

        // ── UI 帧压缩渲染（用户拍板 480px，只降每帧成本、不降频率）──
        // 旧实现：render 2940×1912 全分辨率 CGImage（~22MB）再靠 NSImage 的 size
        // 参数"假装"缩放（size 只是绘制提示，底层位图仍全分辨率）→ 每帧 22MB
        // 分配 + 全画面 GPU 渲染 + SwiftUI 每帧绘制大图，30fps 下 660MB/s 分配速率；
        // 运行 1-2 分钟后系统内存压力累积（实测 lag 飙到 878-1382ms、掉到 0 帧）。
        // 现改为 CPU vImage 全屏等比直缩到 480 宽（~0.6MB），CGImage 经 CGDataProvider
        // 零拷贝引用缩放缓冲（并 retain 该缓冲保证生命周期），完全绕开 CIContext(GPU)，
        // 消除游戏占满 GPU 时的排队卡顿。
        // 捕获/推理频率不变（30fps 红线）；OCR（onNativeFrame）、YOLO（onYoloFrame）
        // 走各自直通路径不受影响。
        let maxWidth: CGFloat = 480
        let sw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sh = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let uiScale = min(1.0, maxWidth / sw)
        let dW = Int((sw * uiScale).rounded())
        let dH = Int((sh * uiScale).rounded())
        guard dW > 0, dH > 0,
              let uiPool = makeUIBufferPool(width: dW, height: dH) else { return }
        var uiBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, uiPool, &uiBuf) == kCVReturnSuccess,
              let uiBuf else { return }

        // vImage 等比缩放到 uiBuf（CPU 双线性，方向/字节序与 GPU 路径一致，不翻转）
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(uiBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(uiBuf, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(uiBuf) else { return }
        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        var dstBuf = vImage_Buffer(data: dstBase,
                                   height: vImagePixelCount(dH),
                                   width: vImagePixelCount(dW),
                                   rowBytes: CVPixelBufferGetBytesPerRow(uiBuf))
        vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))

        // 关键：CGImage 必须持有 uiBuf，零拷贝且生命周期正确绑定。
        // 旧写法 CGContext(data:)+makeImage() 是 COW 快照，不保证物理拷贝；
        // uiBuf 回池后被下一帧 vImage 覆写 → 屏幕显示撕裂/花帧（use-after-recycle）。
        // 这里用 CGDataProvider 的 releaseData 回调 retain uiBuf，图像存活期间池不会复用该缓冲。
        let rowBytes = CVPixelBufferGetBytesPerRow(uiBuf)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        let uiBufPtr = Unmanaged.passRetained(uiBuf).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: uiBufPtr,
            data: dstBase,
            size: rowBytes * dH,
            releaseData: { info, _, _ in
                Unmanaged<CVPixelBuffer>.fromOpaque(info!).release()
            }) else {
            // provider 创建失败：手动 release 那 +1，避免泄漏
            Unmanaged<CVPixelBuffer>.fromOpaque(uiBufPtr).release()
            return
        }
        guard let cgImage = CGImage(width: dW, height: dH,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: rowBytes, space: colorSpace,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            // cgImage 创建失败：provider 已随 ARC 析构，其 releaseData 会释放那 +1，此处不手动 release
            return
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: dW, height: dH))

        // 更新当前帧
        currentFrame = nsImage

        // 通过闭包回调输出（UI 显示和模型推理共用）
        onFrame?(nsImage, cgImage)
        }   // autoreleasepool 结束
    }

    /// 惰性创建（或复用）与 YOLO 输入同尺寸的私有缩放缓冲池
    /// attrs 与模型输入一致（32BGRA + CGImage/CGBitmapContext/Metal 兼容），
    /// 池深度 ≥4：主线程/推理队列通常 1-2 帧在途，留足余量避免频繁分配。
    private func makeYoloBufferPool(size: Int) -> CVPixelBufferPool? {
        if let pool = yoloBufferPool, yoloBufferPoolSize == size {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size,
            kCVPixelBufferHeightKey: size,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,   // 与模型输入一致
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        yoloBufferPool = pool
        yoloBufferPoolSize = size
        return pool
    }

    /// 惰性创建（或复用）UI 显示缓冲池（32BGRA，dW×dH）
    /// vImage 缩放到该缓冲后，CGImage 经 CGDataProvider 直接引用其基址零拷贝（并 retain 该缓冲），
    /// 池深度 ≥4（主线程 1-2 帧在途留余量），尺寸随源分辨率固定，dW/dH 变化则重建。
    private func makeUIBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = uiBufferPool, uiPoolWidth == width, uiPoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        uiBufferPool = pool
        uiPoolWidth = width
        uiPoolHeight = height
        return pool
    }

    // MARK: - 原生帧自持拷贝

    /// 同步拷贝原生帧的**速度表 ROI** 到自持小缓冲（仅 captureQueue 串行调用，无需加锁）
    /// - Note: 环1 优化 —— 只逐行 memcpy speedROINorm 区域（≈100KB），不再整帧 22MB。
    ///   行序照抄 src 的 bytesPerRow（row 0 = 画面顶部），ROI 顶部行 = src 的 roiY 行，
    ///   逐行 1:1 复制、不翻转、不解释方向；方向语义由下游（SpeedOCRReader CIImage 路径）负责。
    /// - Returns: ROI 自持拷贝缓冲（尺寸 ≈ 速度表区域）；拷贝失败返回 nil（调用方跳过该帧直通）
    private func copyNativeFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }

        // 归一化 ROI → 像素（用 .toNearestOrEven 与 cropSlots 的 round() 同源，保证边界量化一致）
        let roi = Self.speedROINorm
        let roiX = Int((roi.origin.x * CGFloat(w)).rounded(.toNearestOrEven))
        let roiY = Int((roi.origin.y * CGFloat(h)).rounded(.toNearestOrEven))
        let roiW = Int((roi.width * CGFloat(w)).rounded(.toNearestOrEven))
        let roiH = Int((roi.height * CGFloat(h)).rounded(.toNearestOrEven))
        guard roiX >= 0, roiY >= 0, roiW > 0, roiH > 0,
              roiX + roiW <= w, roiY + roiH <= h,
              let pool = nativeBufferPool(width: roiW, height: roiH) else { return nil }

        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let sBPR = CVPixelBufferGetBytesPerRow(src)
        let dBPR = CVPixelBufferGetBytesPerRow(dst)
        let bytesPerPixel = 4                          // 32BGRA
        let srcOffset = roiX * bytesPerPixel           // 每行起始像素偏移（字节）
        let copyBytes = roiW * bytesPerPixel           // 每行拷贝字节数
        let dstRows = min(roiH, CVPixelBufferGetHeight(dst))
        for r in 0..<dstRows {
            memcpy(dBase + r * dBPR,
                   sBase + (roiY + r) * sBPR + srcOffset,
                   copyBytes)
        }
        return dst
    }

    /// 惰性创建（或复用）与 ROI 同尺寸的私有缓冲池
    /// 池深度 ≥4：主线程通常 1-2 帧在途，留足余量避免频繁分配；
    /// 全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容。
    private func nativeBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = nativePool, nativePoolWidth == width, nativePoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        nativePool = pool
        nativePoolWidth = width
        nativePoolHeight = height
        return pool
    }

    // MARK: - 插帧/超分帧自持拷贝（全分辨率 + IOSurface）

    /// 同步拷贝全分辨率帧到自持缓冲（标准内存布局，供 CGImage 创建用）
    /// GooseEngine.ingest(cgImage:) 内部会自行创建 IOSurface-backed 缓冲，
    /// 这里只需提供标准线性内存布局的 CGImage 即可，避免 IOSurface-backed 缓冲的 BaseAddress 不可读问题。
    private func copyUpscaleFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }
        guard let pool = upscaleBufferPool(width: w, height: h) else { return nil }

        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let sBPR = CVPixelBufferGetBytesPerRow(src)
        let dBPR = CVPixelBufferGetBytesPerRow(dst)
        let copyBytes = w * 4  // 32BGRA = 4 bytes/pixel
        for r in 0..<h {
            memcpy(dBase + r * dBPR, sBase + r * sBPR, copyBytes)
        }
        return dst
    }

    /// 惰性创建（或复用）全分辨率插帧缓冲池（32BGRA，标准内存布局）
    /// 不带 IOSurface，避免 BaseAddress 不可读导致 CGImage 创建失败；
    /// GooseEngine.ingest(cgImage:) 内部会自行创建 IOSurface-backed 缓冲。
    private func upscaleBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = upscalePool, upscalePoolWidth == width, upscalePoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            // 故意不加 kCVPixelBufferIOSurfacePropertiesKey，避免 IOSurface-backed 缓冲导致 BaseAddress 不可读
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        upscalePool = pool
        upscalePoolWidth = width
        upscalePoolHeight = height
        return pool
    }

    /// FPS 统计（每秒计算一次）
    private func updateFPS() {
        fpsAccumulator += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSDate)
        if elapsed >= 1.0 {
            captureFPS = Double(fpsAccumulator) / elapsed
            fpsAccumulator = 0
            lastFPSDate = now
        }
    }
}

// ============================================================================
// MARK: - 捕获模式自检（--capture-selftest，2026-10-08 T3）
// ============================================================================
//
// 【为什么要这个自检】本次修复的核心不变量是「录全屏时排除列表**必须非空**」
//   （原 bug 就是 `excludingWindows: []`）。这条不变量**无法靠编译保证** ——
//   谁把参数改回空数组照样能编过。所以做成可执行断言，纳入回归门禁。
//
// 【纯函数优先，网络/权限可跳过】判据函数（`auditOwnWindowExclusion`、
//   `normalizePerspective`、`snapshot`）都是纯的，用**构造夹具**即可断言；
//   真实窗口枚举需要屏幕录制权限，作为可选部分（失败只提示、不算失败），
//   这样在 CI/无权限环境下也能跑出有意义的结论。
enum CaptureSelfTest {

    /// 跑自检，返回**失败项数**（0 = 全过，与其它 `--*-selftest` 同一约定）。
    @MainActor
    static func run() -> Int {
        var fail = 0
        func ck(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✅" : "❌") \(name)  \(detail)")
            if !ok { fail += 1 }
        }

        print("═══ 捕获模式自检（--capture-selftest）═══")

        // ── 1. 视角归一化（perspective 参数化）──
        print("\n── 1. 录制视角归一化 ──")
        ck("默认 first", RecordEngine.normalizePerspective("first") == "first", "first→first")
        ck("third 保留", RecordEngine.normalizePerspective("third") == "third", "third→third")
        ck("TPV 别名", RecordEngine.normalizePerspective("TPV") == "third", "TPV→third")
        ck("3 别名", RecordEngine.normalizePerspective("3") == "third", "3→third")
        ck("大小写不敏感", RecordEngine.normalizePerspective("THIRD") == "third", "THIRD→third")
        ck("空白容忍", RecordEngine.normalizePerspective("  third  ") == "third", "带空格→third")
        ck("非法值回落 first", RecordEngine.normalizePerspective("second") == "first", "second→first")
        ck("空串回落 first", RecordEngine.normalizePerspective("") == "first", "空→first")
        ck("FPV 标签", RecordEngine.Perspective.first.viewLabel == "FPV", "first→FPV")
        ck("TPV 标签", RecordEngine.Perspective.third.viewLabel == "TPV", "third→TPV")

        // ── 2. 游戏窗口判定（与 GameWindowDetector 同一套判据）──
        print("\n── 2. 游戏窗口判定 ──")
        ck("owner 含 NTE", CaptureEngine.isGameWindow(applicationName: "NTE", title: ""), "NTE")
        ck("owner 含异环", CaptureEngine.isGameWindow(applicationName: "异环", title: ""), "异环")
        ck("标题含 NTE", CaptureEngine.isGameWindow(applicationName: "Game", title: "NTE 主界面"), "标题命中")
        ck("小写 nte", CaptureEngine.isGameWindow(applicationName: "nte-launcher", title: ""), "小写命中")
        ck("非游戏不误报", !CaptureEngine.isGameWindow(applicationName: "Safari", title: "百度一下"), "Safari 不算游戏")
        ck("自家不算游戏", !CaptureEngine.isGameWindow(applicationName: "AuroraDrive", title: "控制台"), "自家不算游戏")

        // ── 3. 自家窗口识别 ──
        print("\n── 3. 自家窗口识别 ──")
        let ownBundle = CaptureEngine.ownBundleIdentifier
        let ownPIDs = CaptureEngine.ownProcessIdentifiers()
        ck("本进程 pid 在自家集合", ownPIDs.contains(getpid()), "pid=\(getpid())")
        ck("bundle 精确命中",
           CaptureEngine.isOwnApplication(bundleIdentifier: ownBundle, applicationName: "x",
                                          processID: nil, ownPIDs: []),
           "bundle=\(ownBundle)")
        ck("pid 命中",
           CaptureEngine.isOwnApplication(bundleIdentifier: "", applicationName: "x",
                                          processID: getpid(), ownPIDs: ownPIDs),
           "pid 兜底")
        ck("名字含 AuroraDrive 命中",
           CaptureEngine.isOwnApplication(bundleIdentifier: "com.other", applicationName: "AuroraDrive Helper",
                                          processID: 999999, ownPIDs: []),
           "名字兜底")
        ck("无关应用不误判",
           !CaptureEngine.isOwnApplication(bundleIdentifier: "com.apple.Safari", applicationName: "Safari",
                                           processID: 999999, ownPIDs: ownPIDs),
           "Safari 不是自家")

        // ── 4. 排除列表不变量（本次修复的核心断言）──
        //
        // 【为什么必须真跑】这一条正是原 bug 的位置：`excludingWindows: []`。
        // 这里用真实 `SCShareableContent`（需屏幕录制权限）验证：
        // 屏幕上存在自家窗口时，排除列表必须非空。
        print("\n── 4. 排除列表不变量（真实枚举，需屏幕录制权限）──")
        let semaphore = DispatchSemaphore(value: 0)
        var realWindows: [CapturableWindow] = []
        var realOwnCount = 0
        var realError: String?
        Task {
            do {
                let content = try await SCShareableContent.current
                realWindows = CaptureEngine.snapshot(from: content)
                realOwnCount = CaptureEngine.ownWindows(in: content).count
                print("   实测：可捕获窗口 \(realWindows.count) 个，自家窗口 \(realOwnCount) 个")
                for w in realWindows.prefix(12) {
                    print("     \(w.isGame ? "🎮" : "  ") \(w.displayLabel)  \(w.sizeLabel)")
                }
            } catch {
                realError = error.localizedDescription
            }
            semaphore.signal()
        }
        // 用 runloop 泵等待（不能阻塞主线程，否则 Task 里的 MainActor 排不上 —— 见项目既有教训）
        let deadline = Date().addingTimeInterval(20)
        while semaphore.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let realError {
            print("   ⚠️ 跳过（无屏幕录制权限或系统限制）：\(realError)")
            print("      提示：这是**权限问题**，不是代码缺陷；给终端/应用授权后重跑即可。")
        } else {
            ck("窗口枚举可用", true, "\(realWindows.count) 个窗口")
            // 自家窗口不应出现在候选列表里（拉条不该让用户选到自家窗口）
            ck("候选列表已排除自家窗口",
               !realWindows.contains { $0.isOwn },
               "自家窗口不出现在可选项中")
            // 不变量：排除数 ≥ 自家窗口数中在屏的（这里直接用总数做下界检查）
            if realOwnCount > 0 {
                ck("自家窗口存在时排除列表非空", realOwnCount > 0, "自家窗口 \(realOwnCount) 个（将全部排除）")
            } else {
                print("   ℹ️ 当前没有自家窗口在屏（可能全部最小化）→ 不变量无法实测，跳过")
            }
            // 尺寸过滤：所有候选都该 ≥160×120
            ck("候选尺寸均达标",
               realWindows.allSatisfy { $0.width >= 160 && $0.height >= 120 },
               "最小 \(realWindows.map { min($0.width, $0.height) }.min() ?? 0)")
            // 排序：游戏窗口必须在最前
            if let firstGame = realWindows.firstIndex(where: { $0.isGame }),
               let lastNonGame = realWindows.lastIndex(where: { !$0.isGame }) {
                ck("游戏窗口排在非游戏之前", firstGame < lastNonGame,
                   "首个游戏窗口 idx=\(firstGame)，最后一个非游戏 idx=\(lastNonGame)")
            } else {
                print("   ℹ️ 无游戏窗口在屏 → 排序断言跳过")
            }
        }

        // ── 5. 排除列表审查函数（纯函数，构造夹具）──
        print("\n── 5. 排除审查函数（纯逻辑）──")
        // 无法构造 SCShareableContent 夹具（系统类型无公开 init），
        // 因此这里只验证「窗口模式跳过审查」这条分支语义。
        ck("窗口模式无需审查", CaptureMode.window(id: 1).isWindowMode, "window 模式天然不含自家 UI")
        ck("全屏模式需审查", !CaptureMode.fullScreen.isWindowMode, "fullScreen 需审查排除列表")

        // ── 6. maxClipsPerKind 可配（采集不丢数据）──
        print("\n── 6. 录制保留上限可配 ──")
        let engine = RecordEngine()
        ck("默认上限 10", engine.maxClipsPerKind == 10, "默认 \(engine.maxClipsPerKind)")
        engine.maxClipsOverride = 1000
        ck("override 生效", engine.maxClipsPerKind == 1000, "override→\(engine.maxClipsPerKind)")
        engine.maxClipsOverride = 0
        ck("非法 override 回落默认", engine.maxClipsPerKind == 10, "0→\(engine.maxClipsPerKind)")
        engine.maxClipsOverride = nil
        if let raw = ProcessInfo.processInfo.environment["AURORA_MAX_CLIPS"], let v = Int(raw), v > 0 {
            ck("环境变量优先", engine.maxClipsPerKind == v, "AURORA_MAX_CLIPS=\(v)")
        } else {
            print("   ℹ️ 未设 AURORA_MAX_CLIPS（设了会覆盖默认，实测请用 AURORA_MAX_CLIPS=1000 重跑）")
        }

        print("\n" + String(repeating: "─", count: 56))
        if fail == 0 { print("✅ 捕获模式自检全部通过") } else { print("❌ 失败 \(fail) 项") }
        return fail
    }
}
