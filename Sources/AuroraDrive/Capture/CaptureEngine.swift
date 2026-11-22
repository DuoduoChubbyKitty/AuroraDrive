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
import CoreGraphics
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
    var ownerPID: pid_t? = nil
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
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

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
    var onFrame: ((NSImage, CGImage, CMTime) -> Void)?

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

    /// 精简录制模式专用：**全分辨率**帧回调（2026-11-03 新增）
    ///
    /// 【为什么必须新开一条通道，而不是复用上面三条】实测三条都拿不到「全屏原生像素」：
    ///
    /// | 既有通道 | 实际交付 | 为什么录制用不了 |
    /// |---|---|---|
    /// | `onFrame` | 已缩到 **480 宽**的 UI 图 | 速度表 ROI 只剩 ≈38×16 px，离线 OCR 读不出数字 |
    /// | `onNativeFrame` | **只有速度表 ROI**（`copyNativeFrame` 只拷 `speedROINorm`） | 不是全屏，画面部分丢失 |
    /// | `onUpscaleFrame` | 确实全分辨率 | 被 `isUpscaleWanted()` 门控（UI 绑 `upscaleEnabled`），且已被插帧消费 |
    ///
    /// 【设计口径（用户 2026-11-04 拍板，取代 2026-11-03 版本）】
    /// 本通道交付的仍是**全分辨率**帧；**缩放到 384×224 由录制器在写盘队列里做**
    /// （`LeanRecordEngine.downscale`，见其 `storeWidth/storeHeight` 注释）。
    /// 缩放没有放在这里，是因为 captureQueue 上做同步重活会拖垮抓屏
    /// （本文件已把 capGap 从 11ms 抬到 2081ms 的先例）。
    ///
    /// 速度 OCR 仍然**全部放到录制结束后的离线后台**做：画面里天然带着速度表，
    /// 离线裁 `speedROINorm` 区域就能识别，因此**不需要**额外存「速度表长条」。
    ///
    /// ⚠️ 2026-11-03 的旧口径是「录制只存全屏原始像素」，目的是保留全部信息以便
    ///   换输入尺寸重训。实测量级 365 KB/帧 = 18.8 GB/小时，而训练端
    ///   `dataset_v3` 第一件事就是 `resize((384, 224))` —— 92% 的像素被直接丢弃。
    ///   用户据此改为「直接存模型尺寸」，代价是放弃大图后路，已确认接受。
    ///
    /// 【零成本保证】回调为 nil（默认）时，下面 sampleHandler 的 `if let` 直接短路，
    /// 连一次全分辨率拷贝都不做 —— 与新增本通道之前逐字等价。
    var onRecordFrame: ((CVPixelBuffer) -> Void)?

    /// 是否需要全分辨率录制帧（每次帧回调时求值；与 `isUpscaleWanted` 完全同款模式）。
    /// 接线方：UI 进程 → `{ leanRecorder.isRecording }`。false 时不做拷贝。
    var isRecordFrameWanted: () -> Bool = { false }

    /// 是否需要 YOLO 直通帧（每次帧回调时求值；与 `isUpscaleWanted` 完全同款模式）。
    ///
    /// ⚠️ 2026-10-22 新增（纯浪费清理）：
    ///   `onYoloFrame` 路径每帧都做一次 **1280×832 → 640×640 的 CPU vImage 双线性缩放**
    ///   （实测 0.312ms/帧，见 docs 归档的性能-帧回调拷贝审计）+ 写 1.6MB 池化缓冲。
    ///   但在 **A 模型档（.ayolom，生产默认）** 下，这个帧的两个消费者**全部被门挡死**：
    ///     · `yoloEngine.inferFast` —— 门是 `detectGateB`，
    ///       而 `(forceYolo26s || perceptionMode == .legacy) && !parityEven` 在 A 档恒 false
    ///     · `runOpticalFlow` —— 门是 `perceptionMode.needsOpticalFlow`，
    ///       而 `.ayolom` 返回 false（光流在 A 档根本不存在）
    ///   ⟹ 帧造出来后一路走到 tick，被 `pendingYoloFrame = nil` 直接丢弃。
    ///   代价：0.312ms/帧 → 15Hz 约 4.7ms CPU/秒 + 24.6MB/s 内存写带宽，
    ///        并且占着 SCStream 的 sampleHandlerQueue（项目自己记录过同类事故：
    ///        在 captureQueue 上做同步计算导致 capGap 从 11ms 飙到 2081ms）。
    ///   收益：这两项都不做之后一切行为逐字不变（本来就没被消费）。
    ///   回退：设 `AURORA_FORCE_YOLO26S=1` 时档位仍按 legacy 语义开放，行为恢复。
    var isYoloWanted: () -> Bool = { true }

    /// 原生帧直通回调（每帧调用，传入速度表 ROI 原生分辨率 CVPixelBuffer，未缩放）
    /// SpeedOCR 等需要"原生分辨率直裁直读（不插值）"的下游用这条，
    /// 绕开 NSImage 缩放链路；与 onFrame / onYoloFrame 互不影响
    var onNativeFrame: ((CVPixelBuffer) -> Void)?

    /// 云游戏小地图 ROI 直通（视觉定位用）。回调在 captureQueue 同步产出，
    /// 内容是按 minimapROINorm 裁出的自持缓冲；仅静态门禁 visionLocWanted 为真时拷贝。
    var onMinimapFrame: ((CVPixelBuffer, UInt64) -> Void)?
    /// 门禁（UI/引擎各自设）：视觉定位未启用时不拷小地图 ROI（省带宽）。
    /// ⚠️ 2026-11-21 修数据竞争（评审抓出）：原为裸 nonisolated(unsafe)，
    /// 采集队列在 streamFrame 无锁读、主线程无锁写 → 真实数据竞争。
    /// 现纳入 minimapROILock 保护，与 ROI/revision 同锁（见 setMinimapROI/activeMinimapROI）。
    nonisolated(unsafe) private static var _visionLocWanted = false
    /// 采集队列读（与 activeMinimapROI 同锁，取一致快照）。
    nonisolated static var visionLocWanted: Bool {
        minimapROILock.lock(); defer { minimapROILock.unlock() }
        return _visionLocWanted
    }
    /// 主线程写（与 ROI 同锁）。
    nonisolated static func setVisionLocWanted(_ wanted: Bool) {
        minimapROILock.lock(); _visionLocWanted = wanted; minimapROILock.unlock()
    }

    /// 速度表 ROI（归一化，左上角原点 y 向下）。字模录制（glyphMode）与 SpeedOCR 共用此 ROI。
    /// 环1：copyNativeFrame 只拷贝该区域（≈100KB，替代整帧 22MB），
    /// SpeedOCRReader 用同一常量把槽位坐标换算到 ROI 相对坐标（与 Python crop_slot(roi=...) 一致）。
    nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885,
                                                 width: 0.080, height: 0.050)

    /// 云端（浏览器窗口）的速度表 ROI。2026-11-19 用 tools/roi_picker.html 在
    /// 网页版截图上实测标定（PP-OCR 实测 conf=1.000），与本地客户端位置不同：
    /// 网页版速度表整体更靠下（y 0.8952 vs 0.885），x 略左。
    nonisolated static let cloudSpeedROINorm = CGRect(x: 0.4548, y: 0.8952,
                                                      width: 0.0800, height: 0.0500)

    /// 云游戏小地图 ROI 默认值（归一化，左上角原点）。手工标定兜底：
    /// 2940×1912 桌面截图圆心(302,330)、边长280。运行时由自动标定
    /// （MinimapCalibrator，圆形检测多帧收敛）覆盖为实测值。
    nonisolated static let minimapROINorm = CGRect(x: (302.0 - 140.0) / 2940.0,
                                                   y: (330.0 - 140.0) / 1912.0,
                                                   width: 280.0 / 2940.0,
                                                   height: 280.0 / 1912.0)

    /// 标定态区域 ROI（左上 30% 宽 × 35% 高，与 C 桥 ad_maploc_detect_circle
    /// 的内部裁剪区一致）。视觉模式启动期先把 minimap 通道切到这块大区域，
    /// 圆形检测收敛后再切回真正的小地图 ROI（用户 2026-11-20 提议的自动标定）。
    nonisolated static let minimapCalibRegionROINorm = CGRect(x: 0, y: 0, width: 0.30, height: 0.35)

    /// 活动 minimap ROI 的存储与读写（锁保护：captureQueue 读 / 主线程标定写）。
    private static let minimapROILock = NSLock()
    nonisolated(unsafe) private static var _activeMinimapROI = (rect: minimapROINorm, revision: UInt64(0))
    /// 当前生效的小地图 ROI：自动标定收敛后覆盖默认值。
    nonisolated static var activeMinimapROI: (rect: CGRect, revision: UInt64) {
        minimapROILock.lock(); defer { minimapROILock.unlock() }
        return _activeMinimapROI
    }
    /// 标定收敛后写入（主线程调；CaptureEngine 建流帧回调读）。
    nonisolated static func setMinimapROI(_ roi: CGRect) -> UInt64 {
        minimapROILock.lock(); defer { minimapROILock.unlock() }
        let revision = _activeMinimapROI.revision &+ 1
        _activeMinimapROI = (roi, revision)
        return revision
    }

    /// 用户当前采集对象是否为云端（浏览器里的云游戏）。录全屏时没有窗口可判归属，
    /// 只能靠这个由 UI 在切换采集源时置好的标志决定用哪套速度表坐标。
    /// 进程内生效：UI 进程与 --engine 进程各自设置（不一致时以建流进程为准）。
    nonisolated(unsafe) static var cloudROIHint: Bool = false

    /// 活动速度表 ROI 的存储（锁保护：startStream 后台写 / captureQueue 读）。
    private static let activeROILock = NSLock()
    nonisolated(unsafe) private static var _activeSpeedROINorm = speedROINorm

    /// 当前生效的速度表 ROI：采集窗口是浏览器（云端云游戏）→ cloudSpeedROINorm；
    /// 否则 → speedROINorm（本地默认，行为与历史版本一致）。
    /// 由 `startStream` 在建流时按窗口归属切换（UI 进程与 --engine 进程各自独立生效）。
    nonisolated static var activeSpeedROINorm: CGRect {
        activeROILock.lock(); defer { activeROILock.unlock() }
        return _activeSpeedROINorm
    }

    nonisolated static func setActiveSpeedROI(_ roi: CGRect) {
        activeROILock.lock(); _activeSpeedROINorm = roi; activeROILock.unlock()
    }

    /// 采集窗口归属是否为云端云游戏所在的浏览器（与 BrowserLauncher 的优先级一致：
    /// Chrome 优先、Safari 兜底）。
    nonisolated static func isCloudBrowserOwner(bundleID: String?, name: String?) -> Bool {
        if let bundleID, ["com.google.Chrome", "com.apple.Safari"].contains(bundleID) { return true }
        if let name, ["Google Chrome", "Safari"].contains(name) { return true }
        return false
    }

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

    private var _stream: SCStream?
    private var stream: SCStream? { stateLock.withLock { _stream } }
    private let captureQueue = DispatchQueue(label: "aurora.capture", qos: .userInteractive)
    private var lastFPSDate: Date = .distantPast
    private var fpsAccumulator: Int = 0

    // ══════════════════════════════════════════════════════════════════════════
    // task-94（W3 · 2026-10-11）：**档位感知动态抓屏帧率**
    // ══════════════════════════════════════════════════════════════════════════
    /// 目标抓屏帧率（Hz）。默认 20（与推理 tick 20Hz 对齐）。
    ///
    /// 【档位映射约定（调用方负责映射，本类只收数值）】
    ///   · `.ayolom` → **20**：与 tick 20Hz 对齐，抓屏不超发（2026-10-12 改，
    ///     原 45 时每 tick 只消费 1 帧、多余 25 帧被跳帧丢弃，纯浪费带宽/CPU）
    ///   · `.legacy` → **20**
    ///   · 应急冲刺（EmergencyTakeover.sprint）→ **45**：由 EngineMain.tickOnce 联动
    ///
    /// 【为什么本类只收数值、不认档位】`PerceptionMode` 定义在
    ///   `YolopxEngine.swift`（非本文件写域）；且档位→Hz 的映射是**策略**，
    ///   应由调用方（EngineMain / AuroraDriveApp）决定。本类只提供能力。
    ///
    /// 【线程安全】`stateLock` 保护（`start()` 的 Task 与 `setCaptureHz`
    ///   可能来自不同线程，与 `_isCapturing` 同因）。
    ///
    /// ⚠️ 2026-10-22：默认 20→15（全链路降频，与 EngineMain.tickHz 对齐）。
    ///   正常由 `setCaptureHz(_:)` 按档位覆盖，这里只是建流前的初值。
    private var _targetCaptureHz: Double = 15.0
    var targetCaptureHz: Double {
        get { stateLock.withLock { _targetCaptureHz } }
        set {
            let v = max(1.0, min(120.0, newValue.isFinite ? newValue : 20.0))
            stateLock.withLock { _targetCaptureHz = v }
        }
    }

    /// **已请求**的抓屏帧率（诊断/UI 显示用）。
    ///
    /// ⚠️ **语义精度说明（诚实标注）**：
    ///   · **建流路径**（`startStream` 成功）→ 这是**真·已生效**值 ✅
    ///   · **热更路径**（`updateConfiguration` 成功）→ 官方头文件未保证
    ///     `minimumFrameInterval` 可热更，故这里可能是**"已请求但未验证生效"** ⚠️
    ///   若需区分二者，可加 `activeCaptureHzVerified: Bool`；当前保持简单，
    ///   但**不要把该值当作"实测帧率"**——实测应用
    ///   `lastFrameGapMs`（帧到达间隔）反推。
    ///
    /// ⚠️ 2026-10-22：初值 20→15，与 `_targetCaptureHz` 保持一致
    ///   （建流成功后会被 `targetCaptureHz` 覆盖，这里只影响建流前的显示）。
    private var _activeCaptureHz: Double = 15.0
    private(set) var activeCaptureHz: Double {
        get { stateLock.withLock { _activeCaptureHz } }
        set { stateLock.withLock { _activeCaptureHz = newValue } }
    }

    /// 由**帧到达间隔**反推的实测抓屏帧率（Hz）。
    ///
    /// 【为什么需要它】`activeCaptureHz` 是"我们请求的值"，而本值是"实际到达的值"。
    ///   验证 `setCaptureHz` 热更是否真生效，**只能看这个**。
    ///   依据 `lastFrameGapMs`（`stream(_:)` 每帧更新，`:918-921`）。
    var measuredCaptureHz: Double {
        let gapMs = stateLock.withLock { _lastFrameGapMs }
        guard gapMs > 0.1 else { return 0 }
        return 1000.0 / gapMs
    }

    // 等待正常停止，ScreenCaptureKit 超时则解除对新流的阻塞。由 stateLock 保护。
    private var pendingStop: (generation: Int, deadline: ContinuousClock.Instant)?
    private var starting = false

    /// `applyMode` 早退时**是否已把 desiredMode 写入但未生效**（诊断/日志用）。
    ///
    /// 语义：`true` = 用户选了新模式但当前没在捕获，等下一次 `start()` 生效。
    /// 用它让"期望 ≠ 已生效"这件事**可观测**，而不是让 UI 误以为已生效。
    private var _modePendingApply = false
    private var modePendingApply: Bool {
        get { stateLock.withLock { _modePendingApply } }
        set { stateLock.withLock { _modePendingApply = newValue } }
    }

    // P0-3 修复：诊断/状态属性写于 captureQueue、读于主线程，跨线程裸读写存在
    // 数据竞争（torn read 可能读出 NaN → 读侧 Int(NaN) trap）。
    // 用 OSAllocatedUnfairLock 保护读写（纳秒级开销，不触碰 30fps 红线）。
    private let stateLock = OSAllocatedUnfairLock()
    private var _currentFrame: NSImage?
    private var _isCapturing = false

    /// 启动代数（复审 B3）：每次 start() 取号、stop() 递增。await 建流成功后若代数已变
    /// （期间发生过 stop），说明这次建流已过期 → 立刻拆掉刚建的流并放弃发布，
    /// 杜绝「stop 后旧 start 的 Task 又把流建起来抢占」的竞态。stateLock 保护。
    private var _startGeneration = 0
    var startGeneration: Int { stateLock.withLock { _startGeneration } }

    /// [cap-deep] 帧到达计数（诊断用：确认 SCStream 回调真的在跑）
    private var _deepFrameCounter = 0
    private var lastOutputGeneration: Int?

    /// 抓屏累计帧数（**公开可读**，供 `state` 查询判断"抓屏是否真的活着"）。
    ///
    /// 【为什么需要它】`recordEngine.frameCount` 是**录制帧数**，不开录制恒为 0 ——
    ///   AI/脚本用 `frames` 断言"抓屏活着"会必然误判（w8-verify task-63 发现 P4）。
    ///   本计数在每次帧回调递增，与是否录制无关。
    private(set) var capturedFrameCount: Int = 0
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
    private var nativePool: NativeBufferPool?
    private var minimapPool: NativeBufferPool?

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

    /// 当前流的**采集内容宽高比**（窗口模式=窗口比例；全屏=nil=按屏幕比例）。
    /// ⚠️ 2026-11-19：窗口捕获必须按窗口比例出帧，否则 SCK letterbox 加黑边 →
    ///   速度表归一化位置偏移 → OCR 裁片全黑。`setCaptureHz` 热更时必须沿用同一比例。
    private var currentWindowAspect: Double? = nil

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

    /// 精简录制缓冲池（全分辨率、标准内存布局；尺寸随源分辨率固定）
    /// 与上面四个池各自独立，理由见 `copyRecordFrame` 的注释。
    private var recordPool: CVPixelBufferPool?
    private var recordPoolWidth = 0
    private var recordPoolHeight = 0

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
    /// 屏幕录制 TCC 预检；未授权时主动发起一次系统授权申请（放到主线程，避免后台线程发起弹窗）。
    /// ⚠️ 已是「被拒绝」状态时 `CGRequestScreenCaptureAccess()` 不会再弹窗、只会返回 false —
    ///   这时唯一出路是用户去「系统设置 → 隐私与安全性 → 屏幕录制」手动勾选并重启 App，
    ///   所以调用方必须同时给出可操作文案，不能只靠这一次申请。
    static func requestScreenRecordingPermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        if Thread.isMainThread {
            _ = CGRequestScreenCaptureAccess()
        } else {
            DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
        }
    }

    func start() {
        print("[cap-deep] start() 被调用 isCapturing=\(isCapturing) desiredMode=\(desiredMode.label) pid=\(getpid())")
        guard let startGen = stateLock.withLock({ () -> Int? in
            guard !_isCapturing, !starting else { return nil }
            _startGeneration &+= 1
            starting = true
            _lastModeError = nil
            return _startGeneration
        }) else { return }

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.withLock {
                    if self._startGeneration == startGen { self.starting = false }
                }
            }
            while self.startGeneration == startGen {
                guard let pending = self.stateLock.withLock({ self.pendingStop }) else { break }
                if ContinuousClock.now >= pending.deadline {
                    print("[cap-deep] 旧流停止超时，继续建立新流")
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard self.startGeneration == startGen else { return }

            print("[cap-deep] Task 进入，开始 SCShareableContent.current …")

            // 1. 获取可共享内容（包含权限检查）
            //    macOS 10.15+ 首次调用会触发系统授权弹窗
            //    无权限时会抛出错误
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.current
                guard self.startGeneration == startGen else { return }
                print("[cap-deep] SCShareableContent OK displays=\(content.displays.count) windows=\(content.windows.count)")
            } catch {
                guard self.startGeneration == startGen else { return }
                print("[cap-deep] ❌ SCShareableContent 失败: \(error)")
                // 屏幕录制 TCC 被拒（SCStreamErrorDomain -3801）时，引擎进程自己主动发起一次
                // 授权申请（已授权则无弹窗、幂等）。引擎是 UI 派生的独立进程，它的 TCC 不会
                // 因为 UI 申请过就自动具备；重建/ad-hoc 重签后旧授权还会失效 —— 必须在此申请。
                if !CGPreflightScreenCaptureAccess() {
                    Self.requestScreenRecordingPermissionIfNeeded()
                }
                let reason = "屏幕录制权限被拒绝：请到「系统设置 → 隐私与安全性 → 屏幕录制」"
                    + "勾选 AuroraDriveUI，然后重启 App（重建后需重新授权）"
                self.lastModeError = reason
                self.onStatusChange?(.error(reason))
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
                print("[cap-deep] ❌ 无可用显示器")
                self.onStatusChange?(.error("未找到可用的显示器"))
                return
            }
            print("[capture] selected displayID=\(display.displayID) main=\(mainDisplayID)")

            // 3. 创建并启动流
            await self.startStream(display: display, content: content, startGen: startGen)
        }
    }

    /// 创建并启动 SCStream（async 版本）
    private func startStream(display: SCDisplay, content: SCShareableContent, startGen: Int) async {
        // 诊断日志：确认显示器输出分辨率（字模模式依赖原生分辨率，实测点/像素语义）
        // SCDisplay.width 按 Apple 文档是像素，但实测需确认；若为点值需 ×backingScaleFactor
        print("[capture] display frame=\(display.frame.size) w=\(display.width) h=\(display.height)")
        // 流配置
        // ⚠️ 2026-10-11 性能修复（用户明确要求"降分辨率、不降帧率"）：
        //   原实现抓**原生 Retina 像素** 2940×1912 @30fps = **675 MB/s** 像素流，
        //   全走 WindowServer 合成器 → 与游戏抢 GPU 带宽 → Air M3 无风扇，
        //   一热就降频 → 游戏掉到 1-2 帧（录制 / 自动驾驶均如此）。
        //   但训练实际只存 **640×360** JPEG、模型只吃 **180×320** —— 白抓 24 倍像素。
        //   【为什么统一改这里】录制与自动驾驶**共用同一个 CaptureEngine** →
        //     改这一处，录制 / 推理 / 控制三条路径全部生效。
        //
        // ⚠️⚠️ 关键：**必须保持屏幕原始宽高比**（不能硬编码 16:9）
        //   SCStreamConfiguration 默认 `preservesAspectRatio = true`（官方头文件
        //   SCStream.h：「By default the aspect ratio is preserved」），
        //   `scalesToFit = false`（默认，只缩小不放大、不拉伸）。
        //   若把 3:2 的屏幕（1470×956 点）硬塞进 16:9 的 1280×720 →
        //   **letterbox 加黑边** → 所有归一化坐标（speedROINorm / 检测框 /
        //   车道线掩码）相对整帧定位会**整体错位**。
        //   故这里按**屏幕宽高比**等比计算输出尺寸，目标宽度 1280（≈720P 级）。
        //
        //   【task-94 重构】配置装配抽到 `Self.makeStreamConfiguration(configHz:display:)`
        //     静态纯函数 —— `start()` 与 `setCaptureHz()` 的**热更路径共用同一份**，
        //     保证"全量 config"逐字段一致（`updateConfiguration` 要求全量传，
        //     见 SCStream.h 签名注释）。
        let requestedHz = targetCaptureHz
        //
        //   像素流：1280×832 @20fps = **85 MB/s**（2026-10-12 定档 20fps，与推理
        //   tick 20Hz 对齐；原 45fps = 192 MB/s，多出的帧每 tick 只消费 1 帧，
        //   全被跳帧丢弃，纯浪费带宽）。
        //   （历史对比：原 2940×1912 @30fps = 675 MB/s → 降到 20fps 后共降 **7.9 倍**。）
        //   ⚠️ 帧率由 `setCaptureHz(_:)` 按档位与应急态动态下发（两档基准都 20fps，
        //      应急冲刺提到 45fps），本条只是**默认基准**下的量级参考。

        // ── 内容过滤器（2026-10-08 双模式）─────────────────────────────
        // 旧实现是 `SCContentFilter(display: display, excludingWindows: [])`：
        // 排除列表为空 = 不排除任何窗口 = 整屏（桌面 + 自家 UI）全录进去。
        // 现在按模式构造：
        //   · .fullScreen → 整显示器，但**排除自家所有窗口**
        //   · .window(id) → 只捕获该窗口（desktopIndependentWindow）
        let desired = self.desiredMode
        let filter: SCContentFilter
        // ⚠️ 2026-11-19：窗口比例缓存 —— 窗口捕获必须按窗口自身宽高比出帧，否则 SCK
        //   会 letterbox 加黑边，速度表归一化位置偏移（导致 OCR 裁片全黑）。
        var windowAspect: Double? = nil
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
            // 记录窗口宽高比 → 在此比例下出帧，杜绝 letterbox（速度表位置才与裁片一致）。
            if target.frame.width > 0, target.frame.height > 0 {
                windowAspect = target.frame.height / target.frame.width
            }
            // 速度表 ROI 按窗口归属切换：云端云游戏跑在浏览器（Chrome/Safari）里，
            // 网页版速度表位置与本地客户端不同（实测 y≈0.8952 vs 0.885）。
            // 全屏模式沿用本地默认（本地客户端才用录全屏）。
            let owner = target.owningApplication
            let useCloudROI = Self.isCloudBrowserOwner(bundleID: owner?.bundleIdentifier,
                                                       name: owner?.applicationName)
            Self.setActiveSpeedROI(useCloudROI ? Self.cloudSpeedROINorm : Self.speedROINorm)
            print("[capture] 速度表ROI=\(useCloudROI ? "云端(浏览器) \(Self.cloudSpeedROINorm)" : "本地 \(Self.speedROINorm)")")
            print("[capture] 模式=只录窗口 #\(windowID) "
                  + "app=\(target.owningApplication?.applicationName ?? "?") "
                  + "title=\(target.title ?? "")")

        case .fullScreen:
            let own = Self.ownWindows(in: content)
            filter = SCContentFilter(display: display, excludingWindows: own)
            self.excludedOwnWindowCount = own.count
            // ⚠️ 2026-11-19 修复（用户实测报障：全屏采集时车速仍读不到）：
            //   上一版在这里把 ROI 打回 `speedROINorm`（本地默认），但用户实际用的是
            //   **录全屏**——于是框选的云端坐标（0.4548,0.8952）从来没生效。
            //   全屏帧是整屏（同一块屏幕游戏显示位置不变），此时应沿用
            //   `desiredMode` 反映的采集对象：若用户是从浏览器云游戏切来的，
            //   就继续用云端 ROI；否则用本地默认。
            //   判据用「当前绑定的窗口是否浏览器」不可行（全屏没有窗口），
            //   故用 UI 侧事先置好的标志（见 `cloudROIHint`）。
            Self.setActiveSpeedROI(Self.cloudROIHint ? Self.cloudSpeedROINorm : Self.speedROINorm)
            print("[capture] 模式=录全屏（排除自家窗口 \(own.count) 个）"
                  + " 速度表ROI=\(Self.cloudROIHint ? "云端" : "本地")")
        }

        // 自动断言：排除列表是否真的生效（防「谁把 excludingWindows 改回空数组」回归）
        auditExclusion(content: content, display: display)

        // ⚠️ 2026-11-19：配置**在 filter 之后**构造，才能用上窗口真实宽高比（windowAspect）。
        //   窗口模式下按窗口比例出帧 → 无 letterbox → 速度表归一化位置与裁片一致。
        //   同比例存实例状态，setCaptureHz 热更时沿用（否则改帧率会把黑边带回来）。
        currentWindowAspect = windowAspect
        let config = Self.makeStreamConfiguration(configHz: requestedHz, display: display,
                                                  contentAspect: windowAspect)

        // 创建 SCStream（非 Optional，直接初始化）
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // 注册帧输出回调
        // type: SCStreamOutputType.screen 表示捕获屏幕画面（区别于 .audio 音频）
        do {
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)
            print("[cap-deep] addStreamOutput OK")
        } catch {
            guard self.startGeneration == startGen else { return }
            print("[cap-deep] ❌ addStreamOutput 失败: \(error)")
            let reason = "注册帧回调失败: \(error.localizedDescription)"
            self.lastModeError = reason
            onStatusChange?(.error(reason))
            return
        }

        // 系统可能在 startCapture 返回前交付首帧。
        let registered = stateLock.withLock {
            guard _startGeneration == startGen else { return false }
            _stream = stream
            return true
        }
        guard registered else { return }
        do {
            print("[cap-deep] 即将 startCapture() filter=\(filter) config=\(config.width)x\(config.height)")
            try await stream.startCapture()
            let committed = stateLock.withLock {
                guard _startGeneration == startGen, _stream === stream else { return false }
                currentDisplay = display
                _activeMode = desired
                _modePendingApply = false
                _activeCaptureHz = requestedHz
                _lastModeError = nil
                _isCapturing = true
                return true
            }
            if !committed {
                // stopCapture 可能在系统真正完成启动前已返回。
                try? await stream.stopCapture()
                return
            }
            guard self.stream === stream else { return }
            resetOwnUIWarning()
            onModeChange?(desired)
            onStatusChange?(.started)
            print("[cap-deep] 建流完成 generation=\(startGen)")
        } catch {
            let reason = "启动捕获失败: \(error.localizedDescription)"
                + "（若为「屏幕录制」权限被拒，请到系统设置授权后重启 App）"
            if invalidateFailedStream(stream, reason: reason) {
                print("[cap-deep] ❌ startCapture 失败: \(error)")
                Self.requestScreenRecordingPermissionIfNeeded()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // task-94（W3 · 2026-10-11）：动态帧率
    // ══════════════════════════════════════════════════════════════════════════

    /// 构造完整的 `SCStreamConfiguration`（**静态纯函数**，无实例状态依赖）。
    ///
    /// 【为什么抽成静态】
    ///   `start()` 的首次建流与 `setCaptureHz` 的热更**共用同一份**配置逻辑，
    ///   保证 `updateConfiguration` 收到的 config **逐字段一致**
    ///   （官方 API 要求全量传，不是增量更新，见 SCStream.h 注释）。
    ///
    /// 【分辨率逻辑】
    ///   targetW=1280，height 按 **采集内容的宽高比** 等比算，`scalesToFit=false`。
    ///   ⚠️ 2026-11-19 修复（用户实测报障：云端窗口速度表 OCR 裁片全黑）：
    ///     原实现**恒用主屏比例**。但窗口捕获（desktopIndependentWindow）的内容是
    ///     **窗口本身**，窗口比例与屏幕比例（3:2=0.650）不一致时，SCK 会 letterbox
    ///     加黑边 → 速度表在帧里的归一化位置整体偏移 → ROI 裁到黑边上（fg=0 全黑）。
    ///     故 height 必须按「实际采集内容的宽高比」算：窗口模式传窗口比例，
    ///     全屏模式传屏幕比例（contentAspect 参数，nil=沿用屏幕比例）。这样任何窗口
    ///     比例下都不会有黑边，归一化坐标才与裁片所见一致。
    static func makeStreamConfiguration(configHz: Double, display: SCDisplay,
                                        contentAspect: Double? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let targetW: Double = 1280
        let aspect: Double
        if let a = contentAspect, a.isFinite, a > 0.05, a < 20 {
            aspect = a
        } else if let screen = NSScreen.screens.filter({
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                == NSNumber(value: display.displayID)
        }).first, screen.frame.height > 0 {
            aspect = screen.frame.height / screen.frame.width
        } else if display.width > 0 {
            aspect = Double(display.height) / Double(display.width)
        } else {
            aspect = 9.0 / 16.0
        }
        config.width = Int(targetW)
        config.height = Int((targetW * aspect).rounded())
        config.scalesToFit = false
        // task-94：帧率从参数读（不再硬编码 45）
        let safeHz = max(1.0, min(120.0, configHz.isFinite ? configHz : 20.0))
        let tscale = max(1, Int(safeHz.rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(tscale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true
        let mbps = Double(config.width * config.height * 4 * tscale) / 1e6
        print("[capture] 抓屏配置 \(config.width)x\(config.height) @\(tscale)fps"
              + "（aspect=\(String(format: "%.3f", aspect))，像素流 "
              + "\(String(format: "%.0f", mbps)) MB/s）")
        return config
    }

    /// 热切换抓屏帧率（**不重启流，避免闪帧**）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【依据 · 官方头文件原文（已读 `SCStream.h:500`）】
    /// ══════════════════════════════════════════════════════════════════════
    /// ```objc
    /// /*!
    ///  @abstract updateConfiguration:completionHandler:
    ///  @param streamConfig the requested content filter to be updated
    ///  @discussion this method will update the stream configuration for a
    ///      content stream. A completion handler will be called when the
    ///      update is complete with an error denoting if the update has failed.
    /// */
    /// - (void)updateConfiguration:(SCStreamConfiguration *)streamConfig
    ///       completionHandler:(nullable void (^)(NSError *_Nullable error))completionHandler
    ///       NS_SWIFT_ASYNC_NAME(updateConfiguration(_:))
    /// ```
    /// · **Swift 签名**：`func updateConfiguration(_ config: SCStreamConfiguration) async throws`
    ///   （由 `NS_SWIFT_ASYNC_NAME` 决定；`completionHandler` 变 `try await`）。
    /// · **availability**：`SCStream` 类级 `API_AVAILABLE(macos(12.3))`，
    ///   `updateConfiguration` **无额外版本限制**（继承 12.3）；
    ///   本项目 `platforms: [.macOS(.v26)]` → **远高于要求，可用** ✅
    ///
    /// ⚠️⚠️ **【未验证】`minimumFrameInterval` 是否真能热更生效**
    ///   头文件只说"update the stream configuration"，**未明示**哪些字段可热更。
    ///   帧率是**采集节流参数**，有可能在建流时固化、热更时被忽略（或静默无效）。
    ///   ⟹ **本实现的弱点**：`updateConfiguration` **不抛错 ≠ 真的生效**。
    ///      成功路径直接置 `activeCaptureHz = newHz` 是**乐观假设**。
    ///
    ///   **实测方案（待批准编译后执行）**：
    ///     ① 启动引擎，看 `[cap-deep] 📥 帧到达 #N` 打印频率（默认每 60 帧一次）
    ///        —— 20fps 下约 3.0s 一次（60/20）
    ///     ② 调 `setCaptureHz(45)` 再看间隔
    ///        —— 生效应约 1.33s 一次（60/45）；不变 → 热更无效
    ///     ③ 更严谨：固定 5s 窗口数帧数（20fps → ~100 帧；45fps → ~225 帧）
    ///     ④ 若确认热更无效 → **回退路径必须成为主路径**（总是 stop+start），
    ///        或改为"先热更、再按实测间隔校验、不符则重启"
    ///
    /// 【回退路径】`updateConfiguration` 抛错 → 停止 + 重启流
    ///   （由 `start()` 等待旧流停止）。
    ///   回退会闪一帧，但**保证帧率最终生效**（比"静默不改"安全）。
    ///
    /// 【不在捕获时】只写 `targetCaptureHz`，下次 `start()` 会自动用上。
    ///
    /// ⚠️ **【接线状态】2026-10-12 已接线**（旧注释说"零外部调用"已过期）：
    ///   `EngineMain.applyPerceptionMode` 两处（:861 切档 / :878 录制结束补切）
    ///   与 `tickOnce` 的应急 sprint 联动（:1244）都在调它。
    func setCaptureHz(_ hz: Double) async {
        let newHz = max(1.0, min(120.0, hz.isFinite ? hz : 20.0))
        let old = targetCaptureHz
        targetCaptureHz = newHz
        print("[cap-deep] setCaptureHz(\(newHz)) 旧值=\(old) isCapturing=\(isCapturing)")
        guard isCapturing, let stream = stream, let display = currentDisplay else {
            print("[cap-deep] setCaptureHz: 未在捕获 → 只记 targetCaptureHz，下次 start() 生效")
            return
        }
        guard newHz != old else {
            print("[cap-deep] setCaptureHz: 频率未变（\(newHz)）→ 不做 updateConfiguration")
            return
        }

        // ① 热更路径（优先）：沿用当前流的**采集内容比例**（窗口模式=窗口比例），
        //    防止热更帧率时配置悄悄退回屏幕比例 → letterbox 黑边回归。
        let newConfig = Self.makeStreamConfiguration(configHz: newHz, display: display,
                                                     contentAspect: currentWindowAspect)
        do {
            try await stream.updateConfiguration(newConfig)
            activeCaptureHz = newHz
            print("[cap-deep] ✅ updateConfiguration 成功 → \(Int(newHz))fps（热切换，无闪帧）")
            return
        } catch {
            print("[cap-deep] ❌ updateConfiguration 失败: \(error) → 回退重启流")
        }

        // ② 回退路径：仅重启本次热更所用的流。
        guard self.stream === stream else { return }
        stop()          // 同步置状态 + 异步 stopCapture/清池
        start()
        // ⚠️ 刻意**不在这里**置 `activeCaptureHz`：它是"已生效"语义，
        //   必须等 `startStream` 真的 startCapture 成功后才由那里设置（:530）。
        //   若在此乐观置值、而 start 失败 → activeCaptureHz 会说谎。
        print("[cap-deep] setCaptureHz 回退完成：已请求重启流，目标 \(Int(newHz))fps"
              + "（activeCaptureHz 待建流成功后更新）")
    }

    /// 立即作废旧流，异步等待系统停止。
    func stop() {
        let old = stateLock.withLock { () -> (SCStream, Int)? in
            _startGeneration &+= 1
            starting = false
            guard let oldStream = _stream else { return nil }
            detachStream()
            pendingStop = (_startGeneration, ContinuousClock.now + .seconds(1))
            return (oldStream, _startGeneration)
        }
        guard let (oldStream, generation) = old else { return }
        onStatusChange?(.stopped)

        Task { [weak self] in
            do {
                try await oldStream.stopCapture()
                print("[cap-deep] 旧流停止完成 generation=\(generation)")
            } catch {
                print("[cap-deep] 旧流停止失败 generation=\(generation): \(error)")
            }
            guard let self else { return }
            self.stateLock.withLock {
                if self.pendingStop?.generation == generation { self.pendingStop = nil }
            }
        }
    }

    /// 持有 stateLock 时调用，将清池排在新流注册之前。
    private func detachStream() {
        _stream = nil
        _isCapturing = false
        _currentFrame = nil
        captureQueue.async { [self] in
            nativePool = nil
            minimapPool = nil
            yoloBufferPool = nil
            yoloBufferPoolSize = 0
            uiBufferPool = nil
            uiPoolWidth = 0
            uiPoolHeight = 0
            upscalePool = nil
            upscalePoolWidth = 0
            upscalePoolHeight = 0
            recordPool = nil
            recordPoolWidth = 0
            recordPoolHeight = 0
        }
    }

    // MARK: - 窗口枚举 / 自家窗口识别 / 运行时切换（2026-10-08 新增）

    @MainActor
    func prepareDrivingSource(_ mode: CaptureMode) async {
        if isCapturing, captureMode == mode { return }
        // Open a new stream so queued samples from the old window cannot be reused.
        stop()
        await applyMode(mode)
    }

    @MainActor
    func confirmPreview(_ mode: CaptureMode) async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let generation = startGeneration
        while startGeneration == generation, !Task.isCancelled {
            if isCapturing, captureMode == mode { return nil }
            if let lastModeError { return lastModeError }
            if ProcessInfo.processInfo.systemUptime >= deadline { return "等待窗口采集超时" }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return "窗口采集已切换"
    }
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
            result.append(CapturableWindow(ownerPID: app?.processID, id: window.windowID,
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
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// task-C 修复（2026-10-10）：**语义修正 —— `captureMode` 只表示"已生效"**
    /// ══════════════════════════════════════════════════════════════════════
    /// 【原缺陷】早退路径（未在捕获时）写 `captureMode = mode`，把"期望模式"
    ///   直接标成"已生效模式"。但此刻**没有任何 filter 被更新** —— 状态说谎了。
    ///   下游（UI 拉条 / `onModeChange` 回调）据此以为切换成功，
    ///   而实际生效的仍是旧模式 → 用户看到"选了没反应/下次打开还是旧的"。
    ///
    /// 【修法】早退路径**只写 `desiredMode`**（期望），不动 `captureMode`（已生效）；
    ///   并置 `modePendingApply = true` 让"待生效"这件事可观测。
    ///   真正生效由两条路径完成：
    ///     · 已在捕获 → 走下面 `updateContentFilter`，成功后写 `captureMode`
    ///     · 未在捕获 → 下一次 `start()` 用 `desiredMode` 建流，
    ///       `startStream` 成功后写 `captureMode = desiredMode`（既有逻辑）
    ///
    /// 【第 4 点：可观测性】每次调用都打日志说明**走了哪条分支 + 结果**。
    func applyMode(_ mode: CaptureMode) async {
        print("[cap-deep] applyMode(\(mode.label)) 进入 isCapturing=\(isCapturing) stream=\(stream != nil ? "有" : "nil") captureMode=\(captureMode.label)")
        // ⚠️ 2026-10-10 修复「非法窗口污染 desiredMode」：
        //   原实现在**校验之前**就无条件 `desiredMode = mode`。若用户/脚本选了一个
        //   不存在的窗口（如 #999999999），后续校验失败 return，但 `desiredMode`
        //   已经指向那个不存在的窗口 —— 下一次 `start()` 会拿它去建 filter，
        //   在 startStream 里 `findWindow` 失败 → **整个抓屏起不来**。
        //   实测残留现场：`desiredMode=只录窗口 #999999999`（w4-tools 独立发现）。
        //   修法：desiredMode 只在**校验通过**后才提交（见下方各成功路径）。
        lastModeError = nil
        let previousDesired = desiredMode

        guard isCapturing, let stream else {
            // ── 分支 A：还没开始捕获 ──
            // 【task-C 修复点】**只记期望，不标已生效**（原来错误地写了 captureMode）
            // 【本处】未捕获时无法校验窗口是否存在，但 desiredMode 必须记下来
            //   （start() 会用它）；窗口若届时不存在，startStream 会如实报错。
            desiredMode = mode
            modePendingApply = true
            print("[cap-deep] applyMode 分支A（未在捕获）：只记 desiredMode=\(mode.label)，"
                  + "captureMode 保持=\(captureMode.label)（**不谎报已生效**）；"
                  + "待下次 start() 应用")
            // ⚠️ 刻意**不写** `captureMode = mode`（原缺陷所在）。
            //    回调仍发 desiredMode：UI 拉条要立刻反映"用户选了这个"，
            //    但 UI 应结合 `modePendingApply` 判断它是否已生效。
            onModeChange?(mode)
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
            print("[cap-deep] applyMode: SCShareableContent OK windows=\(content.windows.count)")
        } catch {
            print("[cap-deep] ❌ applyMode: SCShareableContent 失败: \(error)")
            lastModeError = "切换失败：无法获取窗口列表（\(error.localizedDescription)）"
            onModeChange?(captureMode)
            return
        }

        guard let display = currentDisplay ?? content.displays.first else {
            print("[cap-deep] ❌ applyMode: 找不到显示器")
            lastModeError = "切换失败：找不到显示器"
            onModeChange?(captureMode)
            return
        }

        let newFilter: SCContentFilter
        switch mode {
        case .window(let windowID):
            guard let target = Self.findWindow(id: windowID, in: content) else {
                print("[cap-deep] ❌ applyMode: 窗口 #\(windowID) 不在列表里"
                      + " → desiredMode 保持 \(previousDesired.label)（**不写入非法值**，"
                      + "否则下次 start() 会因找不到该窗口而起不来）")
                lastModeError = "窗口 #\(windowID) 已不存在（可能已关闭），仍保持「\(captureMode.label)」"
                onModeChange?(captureMode)
                return
            }
            newFilter = SCContentFilter(desktopIndependentWindow: target)
            print("[cap-deep] applyMode: 构造新 filter(窗口 #\(windowID)) OK")
        case .fullScreen:
            let own = Self.ownWindows(in: content)
            newFilter = SCContentFilter(display: display, excludingWindows: own)
            excludedOwnWindowCount = own.count
        }

        do {
            print("[cap-deep] 即将 updateContentFilter …")
            try await stream.updateContentFilter(newFilter)
            print("[cap-deep] ✅ applyMode 分支B（已在捕获）成功：updateContentFilter → \(mode.label)"
                  + "；captureMode \(captureMode.label) → \(mode.label)")
            captureMode = mode
            desiredMode = mode          // 校验通过且真正生效 → 提交期望值
            modePendingApply = false   // 已真正生效，清"待应用"标记
            onModeChange?(mode)
            // 切回全屏后同样审一遍排除列表
            auditExclusion(content: content, display: display)
            print("[capture] 切换成功 → \(mode.label)")
        } catch {
            print("[cap-deep] ❌ applyMode 分支B 失败：updateContentFilter 抛错 \(error)")
            lastModeError = "切换失败：\(error.localizedDescription)"
            // 失败时保持"已生效模式"不变（不谎报成功），并标记待应用
            // desiredMode 也保持原值（不写入一个没能生效的模式，避免下次 start 用错）
            modePendingApply = true
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


    @discardableResult
    private func invalidateFailedStream(_ stream: SCStream, reason: String) -> Bool {
        let didStop = stateLock.withLock {
            guard _stream === stream else { return false }
            detachStream()
            _lastModeError = reason
            return true
        }
        if didStop { onStatusChange?(.error(reason)) }
        return didStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        invalidateFailedStream(stream, reason: "画面采集中断：\(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let generation = stateLock.withLock({ _stream === stream ? _startGeneration : nil }) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int,
           raw != SCFrameStatus.complete.rawValue, raw != SCFrameStatus.started.rawValue { return }

        let firstFrame = lastOutputGeneration != generation
        if firstFrame {
            lastOutputGeneration = generation
            lastFrameTime = .distantPast
            lastFPSDate = Date()
            fpsAccumulator = 0
        }

        // [cap-deep] 帧到达探针：前 3 帧必打，之后每 60 帧打一次（~2s@30fps）
        _deepFrameCounter += 1
        // 公开计数：供 `state.captureFrames` 判断抓屏是否活着（与是否录制无关）
        capturedFrameCount = _deepFrameCounter
        if firstFrame || _deepFrameCounter % 60 == 0 {
            print("[cap-deep] 📥 帧到达 #\(_deepFrameCounter) generation=\(generation) first=\(firstFrame)")
        }

        // P1 修复：SCStream delegate 回调不自动包 autoreleasepool，30fps 下每帧
        // 临时对象（NSImage/CGImage/CGDataProvider/vImage 等）若不在帧末释放，
        // 长时间运行会内存缓涨。整个每帧处理逻辑包进 autoreleasepool，帧末统一释放。
        autoreleasepool {
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

        // ── 云游戏小地图 ROI 直通（视觉定位）：仅视觉模式开启时拷贝 ──
        if let onMinimapFrame, Self.visionLocWanted {
            let (roi, revision) = Self.activeMinimapROI
            if let miniCopy = copyNativeFrame(from: pixelBuffer, roi: roi) {
                onMinimapFrame(miniCopy, revision)
            }
        }

        // ── 插帧/超分直通：把全分辨率帧送给 MetalGoose 引擎 ──
        // 必须复制到带 IOSurface 的私有缓冲，否则下游 CGImage 创建会崩（MG-ENG-001）
        // 门禁先于拷贝求值：插帧/清晰画面关闭时连全分辨率拷贝都不做
        //（下游本就没人消费，拷了也是白费带宽与内存带宽）。
        if let onUpscaleFrame, isUpscaleWanted(),
           let upscaleCopy = copyUpscaleFrame(from: pixelBuffer) {
            onUpscaleFrame(upscaleCopy)
        }

        // ── 精简录制直通：全分辨率帧交给录制器（超采样与速度 OCR 都在离线做）──
        // 门禁先于拷贝求值：未录制时连全分辨率拷贝都不做（与上面两路同款）。
        // 拷贝在 captureQueue 上同步完成（≈4MB memcpy，亚毫秒级）；
        // JPEG 编码与写盘由录制器丢到自己的后台队列 —— **绝不可在 captureQueue 上编码**，
        // 本文件已有先例：在该队列做同步重活曾把 capGap 从 11ms 抬到 2081ms。
        if let onRecordFrame, isRecordFrameWanted(),
           let recordCopy = copyRecordFrame(from: pixelBuffer) {
            onRecordFrame(recordCopy)
        }

        // ── YOLO 直通：CPU vImage 缩放到模型输入尺寸（YoloEngine.inputSize，640）──
        // 在源头完成缩放，绕开大图 → NSImage → CGImage → 再缩放的链路
        //
        // ⚠️ 2026-10-22：门禁先于缩放求值（与上面 onUpscaleFrame 同款）。
        //   A 模型档下两个消费者都被档位门挡死（见 `isYoloWanted` 的注释），
        //   这里连 vImageScale 都不做 → 省 0.312ms/帧 + 24.6MB/s 带宽，
        //   并让出 captureQueue（SCStream 的 sampleHandlerQueue）。
        if let onYoloFrame, isYoloWanted() {
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

        let current = stateLock.withLock {
            guard _stream === stream else { return false }
            _currentFrame = nsImage
            return true
        }
        guard current else { return }

        // 通过闭包回调输出（UI 显示和模型推理共用）
        onFrame?(nsImage, cgImage, sampleBuffer.presentationTimeStamp)
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

    /// 同步拷贝原生帧的速度表或小地图 ROI 到自持缓冲（captureQueue 串行调用）。
    /// - Note: 环1 优化 —— 只逐行 memcpy speedROINorm 区域（≈100KB），不再整帧 22MB。
    ///   行序照抄 src 的 bytesPerRow（row 0 = 画面顶部），ROI 顶部行 = src 的 roiY 行，
    ///   逐行 1:1 复制、不翻转、不解释方向；方向语义由下游（SpeedOCRReader CIImage 路径）负责。
    /// - Returns: ROI 自持拷贝缓冲（尺寸 ≈ 速度表区域）；拷贝失败返回 nil（调用方跳过该帧直通）
    private func copyNativeFrame(from src: CVPixelBuffer,
                                 roi: CGRect? = nil) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }

        // 归一化 ROI → 像素（用 .toNearestOrEven 与 cropSlots 的 round() 同源，保证边界量化一致）
        let isMinimap = roi != nil
        let roi = roi ?? Self.activeSpeedROINorm
        let roiX = Int((roi.origin.x * CGFloat(w)).rounded(.toNearestOrEven))
        let roiY = Int((roi.origin.y * CGFloat(h)).rounded(.toNearestOrEven))
        let roiW = Int((roi.width * CGFloat(w)).rounded(.toNearestOrEven))
        let roiH = Int((roi.height * CGFloat(h)).rounded(.toNearestOrEven))
        guard roiX >= 0, roiY >= 0, roiW > 0, roiH > 0,
              roiX + roiW <= w, roiY + roiH <= h,
              let pool = nativeBufferPool(width: roiW, height: roiH, isMinimap: isMinimap) else { return nil }

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

    private struct NativeBufferPool {
        let width: Int
        let height: Int
        let pool: CVPixelBufferPool
    }

    /// 两路 ROI 各自缓存缓冲池，避免尺寸不同时每帧交替重建。
    /// 池深度 ≥4：主线程通常 1-2 帧在途，留足余量避免频繁分配；
    /// 全部在途时 CVPixelBufferPoolCreatePixelBuffer 会自行扩容。
    private func nativeBufferPool(width: Int, height: Int, isMinimap: Bool) -> CVPixelBufferPool? {
        if let cached = isMinimap ? minimapPool : nativePool,
           cached.width == width, cached.height == height {
            return cached.pool
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
        let cached = NativeBufferPool(width: width, height: height, pool: pool)
        if isMinimap {
            minimapPool = cached
        } else {
            nativePool = cached
        }
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

    // MARK: - 精简录制帧自持拷贝（全分辨率，标准内存布局）

    /// 同步拷贝全分辨率帧到自持缓冲（供离线录制落盘用）
    ///
    /// 【为什么单独一个池，不复用 `upscaleBufferPool`】
    /// 两个消费者的生命周期差异极大：插帧/超分在**同一帧内**消费完就还池；
    /// 录制则要把缓冲交给后台编码队列，直到 JPEG 编码结束才释放。
    /// 共用一个池时，录制持有一块缓冲的这段时间会让插帧侧拿不到足够缓冲，
    /// 表现为"开了录制后插帧掉帧"——属于典型的池饥饿，且不会报错。
    ///
    /// 【为什么按源分辨率建池】`sampleHandler` 收到的 `pixelBuffer` 由系统池管理，
    /// 主线程稍慢就会被回收/覆写（use-after-release）。必须逐行 memcpy 一份自持副本，
    /// 行序照抄 src 的 `bytesPerRow`、不解释方向（方向语义由下游负责）。
    private func copyRecordFrame(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }
        guard let pool = recordBufferPool(width: w, height: h) else { return nil }

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

    /// 惰性创建（或复用）全分辨率录制缓冲池（32BGRA，标准内存布局）
    ///
    /// `minimumBufferCount: 6` 比插帧池(4)多留两块：录制端"编码中"持有的缓冲
    /// 通常比插帧端更久，池深不足会导致 `CVPixelBufferPoolCreatePixelBuffer`
    /// 返回非 0 → 该帧被静默丢弃。6 是本机 15Hz + 亚毫秒编码下的经验值。
    private func recordBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = recordPool, recordPoolWidth == width, recordPoolHeight == height {
            return pool
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            // 不加 IOSurface：录制端只需要读基址做 CGImage/编码，IOSurface 反而可能让 BaseAddress 不可读
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
            attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { return nil }
        recordPool = pool
        recordPoolWidth = width
        recordPoolHeight = height
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
    static func run(gameSourcesOnly: Bool = false) -> Int {
        var fail = 0
        func ck(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✅" : "❌") \(name)  \(detail)")
            if !ok { fail += 1 }
        }

        print("═══ 捕获模式自检（--capture-selftest）═══")
        func candidate(_ pid: pid_t, _ bundle: String, _ title: String) -> CapturableWindow {
            CapturableWindow(ownerPID: pid, id: UInt32(pid), applicationName: "", bundleIdentifier: bundle,
                             title: title, width: 1280, height: 720, isGame: true, isOwn: false)
        }
        let candidates = [candidate(100, "com.google.Chrome", "异环"),
                          candidate(200, "com.google.Chrome", "异环云游戏"),
                          candidate(200, "com.google.Chrome", "Google Accounts"),
                          candidate(300, GameLauncher.bundleID, "异环启动器"),
                          candidate(300, GameLauncher.bundleID, "异环")]
        ck("本地游戏排除启动器", GameLauncher.matches(candidates, pid: 300) == [candidates[4]], "")
        let chrome = "com.google.Chrome"
        ck("云游戏排除其他浏览器实例",
           BrowserLauncher.gameWindows(in: candidates, browserBundleID: chrome, browserPID: 200) == [candidates[1]], "")
        ck("普通浏览器窗口不作为回退",
           BrowserLauncher.gameWindows(in: [candidates[2]], browserBundleID: chrome, browserPID: 200).isEmpty, "")
        ck("普通浏览器窗口不能成为驾驶目标", !GameLauncher.isDrivingTarget(candidates[2]), "")
        ck("已有浏览器中的新游戏窗口优先",
           BrowserLauncher.gameWindows(in: candidates, browserBundleID: chrome, browserPID: nil,
                                       excluding: [candidates[0].id]) == [candidates[1]], "")
        ck("云端恢复保留同一实例",
           GameLauncher.replacements(for: candidates[1], in: candidates) == [candidates[1]], "")
        let loading = CapturableWindow(ownerPID: 200, id: 201, applicationName: "Google Chrome",
                                       bundleIdentifier: chrome, title: "", width: 1280, height: 720,
                                       isGame: false, isOwn: false)
        let playing = CapturableWindow(ownerPID: 200, id: 201, applicationName: "Google Chrome",
                                       bundleIdentifier: chrome, title: "会话", width: 1280, height: 720,
                                       isGame: false, isOwn: false)
        ck("云端启动跟随 Chrome 新前台窗口，允许启动进程转交",
           BrowserLauncher.launchedWindow(in: [candidates[0], loading], browserBundleID: chrome,
                                         browserPID: 999, frontWindowID: loading.id,
                                         existing: [candidates[0].id], allowReuse: true) == loading, "")
        ck("多个云端候选时优先本次启动的前台窗口",
           BrowserLauncher.launchedWindow(in: Array(candidates.prefix(2)), browserBundleID: chrome,
                                         browserPID: 100, frontWindowID: candidates[1].id,
                                         existing: [], allowReuse: true) == candidates[1], "")
        ck("重复启动可以复用已在前台的云端窗口",
           BrowserLauncher.launchedWindow(in: [candidates[0]], browserBundleID: chrome,
                                         browserPID: 999, frontWindowID: candidates[0].id,
                                         existing: [candidates[0].id], allowReuse: true) == candidates[0], "")
        ck("窗口标题变化后保持云端绑定",
           BrowserLauncher.isSameWindow(loading, playing)
               && !BrowserLauncher.isSameWindow(playing, candidates[1]), "")
        if gameSourcesOnly {
            let launcher = GameLauncher()
            launcher.discover()
            print("本地应用：\(launcher.localURL?.path ?? "未安装")，图标：\(launcher.icon != nil)")
            return fail
        }

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
        //
        // ⚠️ 2026-10-19 修断言漂移（selftest-runner 归因）：原断言写死 `== 10`，
        //   但默认值早在 2026-10-10（bd74ad1）就改成了 **200**
        //   （RecordEngine.swift:53-58 记录了原因：w4-tools V4 验证发现默认 10
        //   会让用户"录到第 11 段就静默删掉第 1 段"，而 w4 的证据 clip 正是这样
        //   被队友密集录制触发的清理删掉的）。
        //   写死数字的断言在默认值变更时会**静默失效**（报 FAIL 但功能没坏），
        //   长期会训练人忽略自检失败。改为引用 RecordEngine 的默认常量，
        //   以后默认值再变，断言自动跟上、无需人工同步。
        print("\n── 6. 录制保留上限可配 ─")
        let engine = RecordEngine()
        ck("默认上限 \(RecordEngine.defaultMaxClipsPerKind)",
           engine.maxClipsPerKind == RecordEngine.defaultMaxClipsPerKind,
           "默认 \(engine.maxClipsPerKind)")
        engine.maxClipsOverride = 1000
        ck("override 生效", engine.maxClipsPerKind == 1000, "override→\(engine.maxClipsPerKind)")
        engine.maxClipsOverride = 0
        ck("非法 override 回落默认",
           engine.maxClipsPerKind == RecordEngine.defaultMaxClipsPerKind,
           "0→\(engine.maxClipsPerKind)")
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
