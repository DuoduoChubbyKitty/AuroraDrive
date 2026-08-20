// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  SpeedOCRReader.swift — 车速表读取引擎（固定槽位 + 0~300 三位数整体模板匹配）
//
//  职责：从全屏原生 CVPixelBuffer（ScreenCaptureKit 推帧）按 3 个固定
//        槽位（归一化 x 中心 / 槽宽 / y 上下界，同源常量于
//        tools/build_speed_glyphs.py）裁出每位数字 → 灰度 + Otsu →
//        缩放到统一尺寸 (25×45) → 与 0-9 字模算残差成本 → 组合成
//        0~300 的三位数整体匹配（取三槽残差和最小的速度值）→ 三层校验
//        → 输出 speedKmh。
//
//  为什么放弃通用 Vision OCR：
//    旧方案用 VNRecognizeTextRequest，对游戏 HUD 空心数字（左右竖 + 上下弧
//    + 中间空洞）误识别率高，实测 "000" 读成 "NTO0U"。空心字笔画稀疏、
//    灰度非纯白且上下半部亮度不均，通用 OCR 不擅长。
//    新方案用模板匹配：针对速度表固定字体预先建库，匹配代价是「按位不同
//    像素数」（对空心字天然友好）。
//
//  为什么是「0~300 三位数整体匹配」而不是「逐槽匹配再组合」：
//    游戏速度表始终显示三位数、前导补 0（0→"000"，90→"090"，已用
//    clip_20260815_130055 逐帧确认），因此 0~300 每个速度值 = 百/十/个
//    三位的固定组合，共 301 个。把「三槽残差和最小」作为判据，数学上
//    等价于预拼 301 个 75×45 整体模板逐一对比（残差可加），但实现上
//    用查表组合，避免 301 个模板的加载与逐帧全量对比开销。
//
//  线程模型：
//    main 入口 infer() → 后台 ocrQueue 跑 3 槽裁剪 + 匹配 → Task @MainActor
//    finish() 写最新快照。generation 计数器防 reset() 后在途结果过期。
//
//  抖动抑制：
//    模板匹配不做 5×5 腐蚀（缩放后笔画太细，腐蚀会抹光字模）；改用
//    matchSpeed(...) 里「±1 像素三位置投票」—— 把模板在 (-1,0,+1)×(-1,0,+1)
//    的 9 个偏移上各算一次残差，取最小，相当于 1 像素抖动鲁棒但不破坏笔画。
//
//  无效帧前置检测：
//    载入/视角错位帧（如 f000 管道特写、f063 烟囱）画面里根本没有速度表，
//    三槽二值化后前景像素极少 → 直接判无效，不进入模板匹配（防乱报）。
//
//  字模库加载：
//    字模文件 models/speed_glyphs.json（同源常量由 tools/build_speed_glyphs.py
//    训练生成）。缺模板的数字位在组合里视为残差无穷大，该速度值不会被选中；
//    字模全缺时保持 Swift 路径仍能运行、不崩溃。
// ============================================================================
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// 固定槽位模板匹配车速读取引擎
/// - @Observable：UI 可观察 speedKmh / confidence
/// - @MainActor：可变状态主线程访问
/// - 输入：CaptureEngine onNativeFrame 的原生 CVPixelBuffer（环1 后为速度表 ROI 切片，
///   槽位坐标经 speedROINorm 换算到 ROI 相对坐标）
@Observable
@MainActor
final class SpeedOCRReader {

    // MARK: - 槽位常量（运行时可由「标注HUD」预设动态设置；json 同步值仅作初始默认）

    /// 3 个数字槽的归一化 x 中心（左上角原点，x 向右）
    /// - 2026-08-15 由 clip_20260815_130055 实测校准：ROI 内 digit centers ≈ [71,120,169]px
    /// - 2026-08-20：改为运行时可变——用户「标注HUD」框选后由 DriveState.applyHUDROI 按
    ///   ROI 内右侧三等分推导并覆盖；读侧（ocrQueue）/写侧（主线程标注）低频竞争可忽略。
    nonisolated(unsafe) static var slotCentersNorm: [CGFloat] = [0.600, 0.660, 0.720]

    /// 每个槽的归一化宽度（覆盖数字 + 抖动余量；数字物理宽度不随 ROI 变，保持默认）
    nonisolated(unsafe) static var slotWidthNorm: CGFloat = 0.020

    /// 数字本体的归一化 y 上下界（左上角原点，y 向下）
    nonisolated(unsafe) static var slotYMinNorm: CGFloat = 0.800
    nonisolated(unsafe) static var slotYMaxNorm: CGFloat = 0.880

    /// 模板缩放尺寸（H × W）；与字模库 JSON 里 template_height/template_width 一致
    nonisolated static let templateHeight: Int = 45
    nonisolated static let templateWidth: Int = 25

    // MARK: - 节流 / 范围 / 校验常量

    /// OCR 推理时间闸（秒）：30Hz 每帧读速度表（原 0.2s=5Hz，UI 速度数字刷新慢）。
    /// OCR 单次模板匹配 <1ms CPU，30Hz 约 30ms/s 可忽略；多帧确认在更高帧率下投票更稳。
    /// 升频不违反 30fps 红线（红线是不降频）。
    nonisolated static let inferInterval: TimeInterval = 1.0 / 30.0

    /// 车速合理范围（km/h），超出视为识别噪声
    nonisolated static let speedRange: ClosedRange<Double> = 0.0...400.0

    /// 速度匹配范围：0~300（用户要求；游戏速度表量程 0~400，>300 由量程校验拦截）
    /// - 匹配时枚举 [minSpeed, maxSpeed] 共 301 个三位数组合
    nonisolated static let minSpeed: Int = 0
    nonisolated static let maxSpeed: Int = 300

    /// 三位数整体模板宽度 = 3 槽 × 25（百/十/个）
    nonisolated static var tripletWidth: Int { templateWidth * 3 }

    /// 无效帧前置检测：3 槽二值化前景像素总数 < 此值 = 画面里没有速度表
    /// - 有效帧（速度表在画面中）前景 ~450+ 像素；载入/视角错位帧 < 50
    nonisolated static let minValidForegroundPixels: Int = 80

    /// 跳变阈值：与上一帧有效读数差值上限（km/h）
    /// 跨阈值视为噪声帧，置信度置 0（speedValid 判 false，走降级路径），不更新 speedKmh
    nonisolated static let maxJumpKmh: Double = 60.0

    /// 多帧确认：最近 N 帧参与投票（N = confirmCount）
    /// - 注意：整数速度在单调加减速时逐帧 ±1~2 km/h，靠 confirmToleranceKmh 容差
    ///   把相邻读数归为"同读数"，否则平台值之外永无确认（见 finish Layer 3）。
    nonisolated static let confirmCount: Int = 3

    /// 多帧确认窗口：仅在最近 confirmWindowSec 秒内的样本参与投票
    nonisolated static let confirmWindowSec: TimeInterval = 1.0

    /// 多帧确认的读数容差（km/h）：|a-b| <= 此值视为"同读数"
    /// - 大跳变已由 Layer 2 maxJumpKmh=60 挡住，此容差只针对逐帧微扰，不冲突
    nonisolated static let confirmToleranceKmh: Int = 2

    /// 多帧确认最少一致帧数（严格多数：> confirmCount/2，由 confirmCount 派生）
    /// - confirmCount=3 → 2；confirmCount=5 → 3
    nonisolated static var minConfirmAgreement: Int { confirmCount / 2 + 1 }

    /// 单槽最大允许残差比例（占模板像素数）
    /// - 残差 = 按位不同像素数；模板 H×W = 1125 像素
    /// - 0.30 = 允许 30% 像素不同；三位数整体匹配时按 3 槽总像素（3375）同比例判定
    nonisolated static let maxSlotResidualRatio: Double = 0.30

    // MARK: - 状态输出（主线程读）

    /// 最新读取到的车速（km/h）；无结果时为 -1
    private(set) var speedKmh: Double = -1

    /// 最新读取的置信度（0~1）；失败为 0
    private(set) var confidence: Double = 0

    /// 是否正在 OCR（防重叠）
    private(set) var isInferencing = false

    /// 最近一次错误描述（预留字段，暂未接入 UI，调试/日志用）
    /// - 仅记录系统级错误（如灰度转换失败）与校验拒绝原因；"缺模板/残差过高"属
    ///   正常情况，不写入此字段（见 finish 的 unknownSlots 分支）
    private(set) var errorMessage: String?

    /// 最近一次成功读取时间（主线程读，判断快照新鲜度）
    private(set) var lastResultTime: Date?

    /// 当前已加载的字模表（"0"~"9"），缺模板的位不出现在字典里
    private(set) var loadedGlyphs: [String: [UInt8]] = [:]

    /// 最近一次 OCR 诊断（为什么没出结果）；成功读出时清空。
    /// 取值示例：字模未加载 / 裁剪失败 / fg=45 过低(画面无速度表) / 残差=1520 超阈值
    @ObservationIgnored
    private(set) var lastOCRDiagnostic: String = ""

    /// 最近一次原生帧尺寸（调试用；0×0 表示尚未收到帧）
    @ObservationIgnored
    private(set) var lastNativeSize: CGSize = .zero

    // MARK: - 内部状态

    /// 原生帧跨队列只读传递包装（@unchecked Sendable）。
    /// onNativeFrame 送来的 CVPixelBuffer 是 CaptureEngine 私有池的整拷贝：
    /// 闭包强持有 → 池不会复用覆写，且 ocrQueue 串行内只读（cropSlots/saveOCRDebug
    /// 均为读操作）→ 生命周期与写竞争均由工程约定保证，手动声明 Sendable。
    private final class NativeFrameBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }

    @ObservationIgnored
    private let ocrQueue = DispatchQueue(label: "com.aurora.speedocr",
                                         qos: .userInitiated)

    /// generation 计数：reset() 时递增，在途 OCR 完成后比对，丢弃过期结果
    @ObservationIgnored
    private var generation = 0

    /// 5Hz 时间闸：上一次成功入队推理的时间
    @ObservationIgnored
    private var lastInferTime: Date?

    /// 死诊断节流：fg 过低（画面无速度表）时 30Hz 每帧触发写盘会打爆磁盘
    /// （每帧写 4 个 PNG）。限制为最快每 1 秒写一次，覆盖写，仍能定位根因。
    /// 只在 ocrQueue 后台线程读写，无跨线程竞争 → nonisolated(unsafe)（同 YoloEngine.pixelBuffer）。
    @ObservationIgnored
    nonisolated(unsafe) private var lastDebugWriteTime: Date?

    /// 上一帧有效车速（用于跳变过滤）
    @ObservationIgnored
    private var lastValidSpeed: Double?

    /// 多帧确认候选历史：[(speed: Int, time: Date)]，每次成功入队推理追加一项
    @ObservationIgnored
    private var candidates: [(speed: Int, time: Date)] = []

    // MARK: - 初始化

    init() {
        // 字模加载失败不致命：空字模下所有位判"未知"，UI 仍能正常跑
        loadGlyphsSync()
    }

    /// 从 models/speed_glyphs.json 同步加载字模库（init 时调用，结果存 loadedGlyphs）
    /// - 文件不存在 / 格式错 / 尺寸不匹配 / 槽位常量不匹配 / version 不匹配 → 静默失败
    ///   （保持空字模，UI 仍可运行，只是 speedKmh 读不到）
    /// - 用 #filePath 定位项目根，models 为同级子目录（与 InferenceEngine 一致）
    private func loadGlyphsSync() {
        let modelsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("models")
        let url = modelsDir.appendingPathComponent("speed_glyphs.json")
        guard let data = try? Data(contentsOf: url) else { return }
        guard let lib = try? JSONDecoder().decode(SpeedGlyphLibrary.self, from: data) else {
            return
        }
        // version 校验：仅接受 v1 格式（未来升级格式需同步改这里）
        guard lib.version == 1 else { return }
        // 模板尺寸校验（防御性）
        guard lib.templateHeight == Self.templateHeight,
              lib.templateWidth == Self.templateWidth else { return }
        // 槽位常量不再与 json 硬校验：2026-08-20 起槽位由「标注HUD」预设运行时动态设置
        // （UserDefaults aurora.hudROI），json 里的 slot_* 字段仅作初始默认，不参与校验。
        var out: [String: [UInt8]] = [:]
        for (k, rows) in lib.templates {
            // rows: [[Int]] 展平成 [UInt8]，长度应为 H*W
            var flat = [UInt8]()
            flat.reserveCapacity(Self.templateHeight * Self.templateWidth)
            for row in rows {
                for v in row {
                    flat.append(v == 0 ? 0 : 1)
                }
            }
            if flat.count == Self.templateHeight * Self.templateWidth {
                out[k] = flat
            }
        }
        loadedGlyphs = out
    }

    /// 显式重新加载字模（训练完新字模后调用；非热路径，按需触发）
    func reloadGlyphs() {
        loadGlyphsSync()
    }

    // MARK: - 推理入口（主线程）

    /// 喂入一帧原生速度表 ROI 缓冲：CIImage 路径裁 3 槽（不插值）→ 后台 OCR → 主线程写快照
    /// - Parameter nativePixelBuffer: CaptureEngine onNativeFrame 的原生 ROI 帧（环1 后为速度表切片）
    func infer(nativePixelBuffer: CVPixelBuffer) {
        // 调试用：记录原生帧尺寸（环1 后为 ROI 尺寸，无论后续是否被节流都更新）
        let sw = CVPixelBufferGetWidth(nativePixelBuffer)
        let sh = CVPixelBufferGetHeight(nativePixelBuffer)
        lastNativeSize = CGSize(width: sw, height: sh)

        // 闸 1：5Hz 时间节流（200ms 内不入队新推理）——正常现象，不记诊断
        guard lastInferTime == nil
                || Date().timeIntervalSince(lastInferTime!) >= Self.inferInterval
        else { return }
        // 闸 2：防重叠（上一帧 OCR 还没跑完）
        guard !isInferencing else { return }
        // 字模完全没加载也直接放弃（避免无效运算）
        guard !loadedGlyphs.isEmpty else {
            lastOCRDiagnostic = "字模未加载"
            return
        }

        // 后台队列：裁 3 槽 + 模板匹配（cropSlots 已挪进 ocrQueue，主线程零 createCGImage）
        lastInferTime = Date()
        let gen = generation
        let glyphsSnapshot = loadedGlyphs
        let roiNorm = CaptureEngine.speedROINorm
        let frame = NativeFrameBox(nativePixelBuffer)   // Sendable 包装，跨队列只读传递
        isInferencing = true
        ocrQueue.async { [weak self] in
            guard let self else { return }
            // 1. CIImage 路径裁 3 个槽位（pure crop，无插值无放大）
            //    环1 后输入是 ROI 切片，槽位坐标按 speedROINorm 换算到 ROI 相对坐标
            guard let slotImages = Self.cropSlots(from: frame.buffer,
                                                  roiNorm: roiNorm) else {
                // 诊断：槽位裁剪失败（ROI 与槽位坐标不匹配）→ 存 ROI 快照供精调
                let now = Date()
                if self.lastDebugWriteTime == nil
                    || now.timeIntervalSince(self.lastDebugWriteTime!) >= 1.0 {
                    self.lastDebugWriteTime = now
                    Self.saveOCRDebug(buffer: frame.buffer, slots: [], fg: 0)
                }
                Task { @MainActor in
                    self.finish(gen, RecognitionResult(diag: "槽位裁剪失败"))
                }
                return
            }

            // 2. 后台跑模板匹配（闭包捕获不可变 CGImage，关闭跨线程共享缓冲竞态）
            let result = Self.recognize(slotImages: slotImages,
                                        glyphs: glyphsSnapshot)
            // 死诊断：识别失败（任何原因）→ 把 App 实际截到的 ROI 快照 + 三槽裁图存盘到
            // /tmp/aurora_ocr_dbg_*.png，供部署后一锤定音定位（截错位置？坐标/朝向错位？
            // 分辨率被压？）。覆盖写，不阻塞主线程。节流 1s/次，避免打爆磁盘。
            if result.speed == nil {
                let now = Date()
                if self.lastDebugWriteTime == nil
                    || now.timeIntervalSince(self.lastDebugWriteTime!) >= 1.0 {
                    self.lastDebugWriteTime = now
                    Self.saveOCRDebug(buffer: frame.buffer,
                                      slots: slotImages, fg: result.fgTotal)
                }
            }
            Task { @MainActor in
                self.finish(gen, result)
            }
        }
    }

    // MARK: - 主线程写快照

    /// 主线程写最新快照（仿 YoloEngine.finish）
    /// - Parameter gen: 入队时捕获的 generation；reset() 后 gen 不匹配则丢弃过期结果
    private func finish(_ gen: Int, _ result: RecognitionResult) {
        guard gen == generation else { return }   // reset() 后在途结果过期，直接丢弃
        isInferencing = false
        if let error = result.error {
            errorMessage = error                    // 仅系统级错误（如灰度转换失败）
            return
        }
        // 无法识别 → 记录诊断并静默丢弃（正常情况：画面无速度表 / 整体残差过高）
        guard let speed = result.speed, result.unknownSlots.isEmpty else {
            lastOCRDiagnostic = result.diag ?? "无法识别"
            return
        }
        lastOCRDiagnostic = ""   // 成功读出，清空诊断

        // ── 三层校验（任一不通过则保留旧值）──
        // Layer 1: 量程过滤
        guard Self.speedRange.contains(Double(speed)) else {
            errorMessage = "out of range \(speed)"
            return
        }
        // Layer 2: 跳变过滤
        // 跨阈值视为噪声帧：不再静默沿用旧值假装新鲜读数，而是把本帧置信度置 0，
        // 让下游 speedValid（conf>0.3）判 false，走正规的"读不到→降级"路径。
        // speedKmh 保留旧值仅供显示；lastValidSpeed 不更新，避免错误读数污染下一帧基准。
        if let last = lastValidSpeed, abs(Double(speed) - last) > Self.maxJumpKmh {
            errorMessage = "jump too large \(last)→\(speed)"
            confidence = 0
            return
        }
        // Layer 3: 多帧确认（容差内同读数 ≥ minConfirmAgreement 才输出）
        let now = Date()
        candidates.append((speed, now))
        // 截断超出时间窗的旧候选
        let windowStart = now.addingTimeInterval(-Self.confirmWindowSec)
        candidates.removeAll { $0.time < windowStart }
        let recent = Array(candidates.suffix(Self.confirmCount))
        guard let confirmed = Self.confirmedSpeed(
            in: recent,
            tolerance: Self.confirmToleranceKmh,
            minAgreement: Self.minConfirmAgreement
        ) else {
            // 候选不足或不一致，暂不输出（保留上一帧有效值）
            return
        }

        speedKmh = Double(confirmed)
        confidence = result.confidence
        lastValidSpeed = Double(confirmed)
        lastResultTime = now
        errorMessage = nil
    }

    /// 多帧确认：在容差范围内分组投票，返回通过确认的速度（或 nil）
    /// - 对每个候选，统计列表内与它差值 <= tolerance 的"同读数"个数；
    ///   个数 >= minAgreement 才算确认，取同读数最多者
    /// - 平票时直接比较候选自身 `item.time`，取组内**最新**成员（不能用组内
    ///   最大时间 latest 作平票键：同一连通组所有成员 latest 相同，永远平票，
    ///   会错误返回最旧候选）
    /// - 容差解决"整数速度单调加减速时逐帧 ±1~2 km/h、永远凑不齐严格相等"的问题
    /// - O(n²)，但 n = confirmCount（默认 3），开销可忽略
    private static func confirmedSpeed(
        in list: [(speed: Int, time: Date)],
        tolerance: Int,
        minAgreement: Int
    ) -> Int? {
        guard !list.isEmpty else { return nil }
        var bestSpeed: Int = list[list.count - 1].speed
        var bestCount: Int = 0
        var bestTime: Date = .distantPast
        for item in list {
            var count = 0
            for other in list where abs(other.speed - item.speed) <= tolerance {
                count += 1
            }
            // 平票取最新：用 item.time（候选自身时间戳）直接比较
            if count > bestCount || (count == bestCount && item.time > bestTime) {
                bestCount = count
                bestSpeed = item.speed
                bestTime = item.time
            }
        }
        guard bestCount >= minAgreement else { return nil }
        return bestSpeed
    }

    /// 停止驾驶时清空：递增 generation 让所有在途 OCR 写回失败
    func reset() {
        generation += 1
        speedKmh = -1
        confidence = 0
        isInferencing = false
        errorMessage = nil
        lastResultTime = nil
        lastInferTime = nil
        lastValidSpeed = nil
        lastOCRDiagnostic = ""
        candidates.removeAll(keepingCapacity: true)
    }

    // MARK: - 槽位裁剪（nonisolated 纯函数）

    /// 从原生 CVPixelBuffer 裁出 3 个槽位，返回 [CGImage; 3]（按 slot 顺序）。
    /// **CIImage 路径**（替代裸 memcpy 按行拷贝）：零拷贝区域裁剪，无插值无放大，
    /// 由 Core Image 自动处理 ScreenCaptureKit 行序/方向问题，根治行序不一致 bug。
    /// - CIImage 坐标系原点在**左下角**（y 向上），而归一化坐标是**左上角**原点 y 向下，
    ///   所以对 y 做镜像：ciRect.y = H - yMax（顶部 yMin 对应 CIImage 的 H-yMax）。
    /// - **量化与 Python 端 crop_slot 完全一致**：xCenter / halfW / yMin / yMax 都用
    ///   round() 取整，宽度 = 2·round(halfW)，高度 = round(yMax)-round(yMin)。
    ///   这样训练窗与运行时裁剪窗像素级一致（round 而非 floor/ceil，避免 1~2px 错位）。
    /// - **roiNorm 参数**（归一化 CGRect，可选）：传非 nil 表示输入帧是「速度表 ROI
    ///   切片」（字模模式录帧 / 自检目录），把全屏归一化槽位坐标换算为 ROI 相对坐标
    ///   再裁剪——与 Python 端 crop_slot(roi=...) 的换算逻辑完全一致，保证训练窗
    ///   与运行时裁剪窗像素级一致。运行时 CaptureEngine 喂全屏帧时保持 nil。
    /// - 返回 [CGImage?]，任一槽位裁剪失败则整组返回 nil（防御性，避免部分槽位静默错位）
    nonisolated static func cropSlots(from src: CVPixelBuffer, roiNorm: CGRect? = nil) -> [CGImage]? {
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }

        let input = CIImage(cvPixelBuffer: src)
        var out: [CGImage] = []
        out.reserveCapacity(slotCentersNorm.count)

        for ci in 0..<slotCentersNorm.count {
            // 与 Python 端一致的 round() 量化：
            //   cx      = round(slotCentersNorm[ci] * sw)
            //   halfW   = round(slotWidthNorm * sw / 2)
            //   yMin    = round(slotYMinNorm * sh)   (顶部)
            //   yMax    = round(slotYMaxNorm * sh)   (底部)
            // 注意：Python 内建 round() 是「银行家舍入」（.5 取偶），故这里用
            //   .rounded(.toNearestOrEven) 完全等价，避免 .5 边界上的同源漂移
            var cxNorm = slotCentersNorm[ci]
            var halfWNorm = slotWidthNorm / 2.0
            var yMinNorm = slotYMinNorm
            var yMaxNorm = slotYMaxNorm
            if let roi = roiNorm {
                // ROI 切片模式：全屏归一化坐标 → ROI 相对坐标（与 Python crop_slot 一致）
                cxNorm = (cxNorm - roi.origin.x) / roi.width
                halfWNorm = halfWNorm / roi.width
                yMinNorm = (yMinNorm - roi.origin.y) / roi.height
                yMaxNorm = (yMaxNorm - roi.origin.y) / roi.height
            }
            let xCenter = (cxNorm * CGFloat(sw)).rounded(.toNearestOrEven)
            let halfW = (halfWNorm * CGFloat(sw)).rounded(.toNearestOrEven)
            let yMin = (yMinNorm * CGFloat(sh)).rounded(.toNearestOrEven)
            let yMax = (yMaxNorm * CGFloat(sh)).rounded(.toNearestOrEven)

            // CIImage 坐标系 y 向上：ciRect.y = sh - yMax（底部镜像到左下角原点）
            // width/height 均为整数（round 结果），无需再 integral
            let ciRect = CGRect(x: xCenter - halfW,
                                y: CGFloat(sh) - yMax,
                                width: halfW * 2.0,
                                height: yMax - yMin)
            guard ciRect.minX >= 0, ciRect.minY >= 0,
                  ciRect.maxX <= CGFloat(sw), ciRect.maxY <= CGFloat(sh),
                  ciRect.width > 0, ciRect.height > 0 else { return nil }

            let cropped = input.cropped(to: ciRect)
            guard let cg = ciContext.createCGImage(cropped, from: cropped.extent) else {
                return nil
            }
            out.append(cg)
        }
        return out
    }

    /// 复用的 CoreImage 渲染上下文（线程安全，可跨线程共享）
    // P1 修复：CIContext 默认会缓存中间渲染结果，长时间 OCR 累积缓存内存。
    // 关掉 cacheIntermediates 避免中间位图常驻。
    private nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - 模板匹配（nonisolated 纯函数）

    /// 单次识别结果
    private struct RecognitionResult {
        /// 识别出的三位数速度（0~300）；无法识别时为 nil
        var speed: Int?
        /// 无法识别的原因（日志用；nil speed 时的补充信息）
        var unknownSlots: [Int] = []
        /// 置信度（基于整体残差比，1 - dist / 总像素数）
        var confidence: Double = 0
        /// 诊断信息（为什么没识别出来，如 fg 过低 / 残差超阈值）
        var diag: String?
        /// 三槽二值化前景像素总数（调试用，fg 过低时随 diag 透出）
        var fgTotal: Int = 0
        /// 错误信息（OCR 系统级失败，如 CGImage 渲染异常）
        var error: String?
    }

    /// 对 3 槽 CGImage 跑整体三位数匹配，返回速度（0~300）+ 置信度
    /// - 每槽：灰度 + Otsu → 缩放到模板尺寸 → 参与三位数组合匹配
    /// - 前置无效检测：3 槽前景像素总数 < minValidForegroundPixels → 判无效
    ///   （载入/视角错位帧画面里根本没有速度表，防乱报）
    /// - "无法识别"判定：整体残差 > 阈值，或任一槽缺模板导致组合残差无穷大；
    ///   不置 error（属正常情况），unknownSlots 供日志使用
    nonisolated private static func recognize(
        slotImages: [CGImage],
        glyphs: [String: [UInt8]]
    ) -> RecognitionResult {
        var slotBinaries: [[UInt8]] = []
        slotBinaries.reserveCapacity(slotImages.count)
        var fgTotal = 0

        for (idx, cg) in slotImages.enumerated() {
            let w = cg.width
            let h = cg.height
            guard w > 0, h > 0,
                  let gray = grayscalePixels(cgImage: cg) else {
                // 系统级错误：灰度转换失败
                return RecognitionResult(error: "grayscale failed slot \(idx)")
            }
            let binary = binarizeOtsu(gray: gray)
            let binaryResized = resizeNearest(src: binary,
                                              srcH: h, srcW: w,
                                              dstH: templateHeight,
                                              dstW: templateWidth)
            fgTotal += binaryResized.reduce(0) { $0 + Int($1) }
            slotBinaries.append(binaryResized)
        }

        // 前置无效检测：速度表不在画面中
        if fgTotal < minValidForegroundPixels {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "fg=\(fgTotal) 过低(画面无速度表)",
                                     fgTotal: fgTotal)
        }

        // 整体三位数匹配（0~300）
        guard let (speed, dist) = matchSpeed(slotBinaries: slotBinaries, glyphs: glyphs) else {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "残差超阈值(3槽前景=\(fgTotal))")
        }

        let area = Double(templateHeight * templateWidth * slotImages.count)
        let confidence = 1.0 - dist / area
        return RecognitionResult(speed: speed,
                                 unknownSlots: [],
                                 confidence: max(0, min(1, confidence)))
    }

    /// 0~300 三位数整体匹配：三槽残差和最小的速度值即为识别结果
    /// - 对每槽 × 每数字（0-9）先算「±1 像素三位置投票」的最小残差 → cost[3][10]，
    ///   再把每位独立的最小残差相加得到该速度值的整体残差（残差可加，数学上
    ///   等价于预拼 301 个 75×45 整体模板逐一对比，但省去模板加载与全量对比）
    /// - ±1 像素三位置投票：模板在 (-1,0,+1)×(-1,0,+1) 共 9 个偏移各算一次，
    ///   取最小残差——给 1 像素级位置抖动留余量，但不会像 5×5 腐蚀那样抹掉笔画
    /// - 缺模板的数字位 → 该槽残差无穷大，包含它的速度值永远不会被选中
    /// - 整体阈值：3 槽 × 25×45 × 30%（与 maxSlotResidualRatio 同源）
    /// - 返回 nil 表示所有速度值都超阈值（视为"无法识别"）
    nonisolated private static func matchSpeed(
        slotBinaries: [[UInt8]],
        glyphs: [String: [UInt8]]
    ) -> (speed: Int, dist: Double)? {
        let h = templateHeight
        let w = templateWidth

        // 1. cost[slot][digit] = 该槽与该数字的最小（±1 抖动）残差
        var cost: [[Double]] = []
        cost.reserveCapacity(slotBinaries.count)
        for slotBinary in slotBinaries {
            var row: [Double] = []
            row.reserveCapacity(10)
            for d in 0...9 {
                guard let tmpl = glyphs[String(d)] else {
                    row.append(.infinity)  // 缺模板：永远不选
                    continue
                }
                var localMin = Double.infinity
                for dy in -1...1 {
                    for dx in -1...1 {
                        let r = residualShifted(binary: slotBinary,
                                                tmpl: tmpl,
                                                h: h, w: w,
                                                dy: dy, dx: dx)
                        if Double(r) < localMin { localMin = Double(r) }
                    }
                }
                row.append(localMin)
            }
            cost.append(row)
        }

        // 2. 枚举 0~300：三槽残差和最小者
        var bestSpeed = minSpeed
        var bestDist = Double.infinity
        for v in minSpeed...maxSpeed {
            let d0 = v / 100          // 百位
            let d1 = (v / 10) % 10    // 十位
            let d2 = v % 10           // 个位
            guard cost.count == 3 else { return nil }  // 防御：理论恒为 3 槽
            let dist = cost[0][d0] + cost[1][d1] + cost[2][d2]
            if dist < bestDist {
                bestDist = dist
                bestSpeed = v
            }
        }

        // 3. 整体阈值
        let area = Double(h * w * slotBinaries.count)
        let limit = maxSlotResidualRatio * area
        guard bestDist <= limit else { return nil }
        return (bestSpeed, bestDist)
    }

    /// 残差计算：模板 (dy, dx) 偏移后与 binary 求按位不同像素数
    /// - binary 与 tmpl 同尺寸 H×W
    /// - 偏移后只在两者都有像素的交集区域内计算（越界部分视为 0）
    /// - 二值取 0/1 直接比较，最快实现
    nonisolated private static func residualShifted(
        binary: [UInt8], tmpl: [UInt8],
        h: Int, w: Int, dy: Int, dx: Int
    ) -> Int {
        // 有效行范围：[max(0,-dy), min(h, h-dy))
        let r0 = max(0, -dy)
        let r1 = min(h, h - dy)
        // 有效列范围
        let c0 = max(0, -dx)
        let c1 = min(w, w - dx)
        guard r1 > r0, c1 > c0 else { return h * w }  // 完全错位 = 最差
        var diff = 0
        // 行主序逐行扫描；br/tr 指向「当前行 + 当前有效列起始」的索引
        let colCount = c1 - c0
        for r in r0..<r1 {
            let br = r * w + c0                // binary 行 + 有效列起点
            let tr = (r + dy) * w + c0 + dx    // tmpl 偏移后对应位置
            for k in 0..<colCount {
                if binary[br + k] != tmpl[tr + k] { diff += 1 }
            }
        }
        return diff
    }

    // MARK: - 图像处理（nonisolated 纯函数）

    /// CGImage → 灰度像素 [UInt8]，长度 = width*height，0~255
    /// - 复用 CGContext 把 CGImage 画到灰度 buffer（最稳的跨版本做法）
    /// - 失败返回 nil（极端情况下 CGImage 数据不可读）
    nonisolated private static func grayscalePixels(cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w
        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    /// Otsu 自适应二值化（输入灰度 → 输出 0/1 的 [UInt8]，长度 = width*height）
    /// - 灰度直方图分两类的类间方差最大化对应的阈值即为 Otsu 阈值
    /// - 单色退化情形（非零灰度级 < 2，如全白帧/全黑帧）直接返回全 0（视为无前景），
    ///   避免 thr=0 时 `gray>0` 全成立 → 输出全 1 的语义错误
    nonisolated private static func binarizeOtsu(gray: [UInt8]) -> [UInt8] {
        var hist = [Int](repeating: 0, count: 256)
        for v in gray { hist[Int(v)] += 1 }
        let total = gray.count
        guard total > 0 else { return [] }
        // 非零灰度级 < 2 → 无法分两类，返回全 0（无前景）
        let distinctLevels = hist.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        guard distinctLevels >= 2 else {
            return [UInt8](repeating: 0, count: total)
        }
        // 总均值
        var sumAll: Double = 0
        for i in 0..<256 { sumAll += Double(i) * Double(hist[i]) }
        var sumB: Double = 0
        var wB: Int = 0
        var varMax: Double = -1
        var thr: Int = 0
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t) * Double(hist[t])
            let mB = sumB / Double(wB)
            let mF = (sumAll - sumB) / Double(wF)
            let v = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if v > varMax { varMax = v; thr = t }
        }
        // 应用阈值：gray > thr 视为前景（数字笔画）
        var out = [UInt8](repeating: 0, count: total)
        for i in 0..<total {
            out[i] = gray[i] > thr ? 1 : 0
        }
        return out
    }

    /// 最近邻缩放（输入任意大小二值图 → 输出 H×W 的 0/1 图）
    /// - **与 Python 端 resize_nn 同源同形**：源下标 = linspace(0, srcN-1, dstN) 取整，
    ///   二值图最近邻避免引入中间灰度；训练字模与运行时匹配必须同一种缩放，
    ///   否则残差系统性抬高
    /// - src: row-major [UInt8]，长度 srcH*srcW；元素视为 0/1 数值
    nonisolated private static func resizeNearest(
        src: [UInt8], srcH: Int, srcW: Int,
        dstH: Int, dstW: Int
    ) -> [UInt8] {
        guard srcH > 0, srcW > 0, dstH > 0, dstW > 0 else { return [] }
        guard src.count == srcH * srcW else { return [] }
        var out = [UInt8](repeating: 0, count: dstH * dstW)
        for y in 0..<dstH {
            let srcY = Self.nearestSourceIndex(y, srcN: srcH, dstN: dstH)
            for x in 0..<dstW {
                let srcX = Self.nearestSourceIndex(x, srcN: srcW, dstN: dstW)
                out[y * dstW + x] = src[srcY * srcW + srcX]
            }
        }
        return out
    }

    /// 最近邻源下标：复刻 numpy `linspace(0, srcN-1, dstN).astype(int64)` 的语义
    /// - numpy linspace 保证首尾端点为 start/stop，中间点 = i*step（step=(srcN-1)/(dstN-1)）
    /// - astype(int64) 对正数向下取整（truncate toward zero），与 Swift `Int()` 一致
    /// - dstN == 1 时退化为取 0（避免除零）
    private nonisolated static func nearestSourceIndex(_ i: Int, srcN: Int, dstN: Int) -> Int {
        guard dstN > 1, srcN > 1 else { return 0 }
        if i == 0 { return 0 }
        if i == dstN - 1 { return srcN - 1 }
        let step = Double(srcN - 1) / Double(dstN - 1)
        return Int(Double(i) * step)
    }

    // MARK: - 死诊断：存盘 App 实际截到的画面

    /// fg 过低时把「App 实际截到的画面 + 三槽裁图」存盘，供一锤定音定位读不到速度表的根因。
    /// - buffer：原生 CVPixelBuffer（与 cropSlots 同一份，走同一 CIImage 路径，忠实反映 OCR 所见；
    ///   环1 后为速度表 ROI 切片，故"全屏"缩略实为 ROI 缩略）
    /// - slots：cropSlots 已裁出的 3 张 CGImage（即 OCR 实际喂给匹配的画面）
    /// - 输出：/tmp/aurora_ocr_dbg_full.png（ROI 缩略）、/tmp/aurora_ocr_dbg_slot{0,1,2}.png、
    ///         /tmp/aurora_ocr_dbg.txt（fg + 原生 ROI 分辨率）。覆盖写。
    /// - 若 ROI 缩略里能看到速度表数字 → 不是截错区域；若三槽裁图全空 → 坐标/朝向错位。
    nonisolated private static func saveOCRDebug(
        buffer: CVPixelBuffer, slots: [CGImage], fg: Int
    ) {
        let sw = CVPixelBufferGetWidth(buffer)
        let sh = CVPixelBufferGetHeight(buffer)
        let input = CIImage(cvPixelBuffer: buffer)
        // 全屏缩略（最长边 ≤ 800，便于直接看 / 发图），与 cropSlots 同一 CIImage 语义
        let scale = min(1.0, 800.0 / Double(max(sw, sh)))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ciContext.createCGImage(small, from: small.extent) {
            Self.writePNG(cg, to: "/tmp/aurora_ocr_dbg_full.png")
        }
        for (i, cg) in slots.enumerated() {
            Self.writePNG(cg, to: "/tmp/aurora_ocr_dbg_slot\(i).png")
        }
        let txt = "fg=\(fg)  native=\(sw)x\(sh)\n"
        try? txt.write(to: URL(fileURLWithPath: "/tmp/aurora_ocr_dbg.txt"),
                       atomically: true, encoding: .utf8)
    }

    /// CGImage → PNG 文件（调试写盘用）
    nonisolated private static func writePNG(_ cg: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - 自检（命令行 --speed-selftest <目录>）

    /// 同步跑一个目录下所有 PNG/JPG 原生分辨率帧：
    /// 加载 → CVPixelBuffer → cropSlots → 整体三位数匹配 → 打印每张的速度。
    /// 期望：能识别出 0~300 内的速度值（画面无速度表的帧判无效属正常）。
    /// 用途：验证 Swift 侧的 CIImage 裁剪路径 + Otsu + 模板匹配与 Python 端
    ///       字模库生成结果一致；任何不一致都会在残差里暴露。
    /// - Parameter roiNorm: 输入帧为「速度表 ROI 切片」时传其归一化位置
    ///   （如字模模式录帧 0.455,0.885,0.080,0.050）；全屏帧传 nil
    /// - Returns: 可读报告（含每张的 speed / confidence / 全局 pass/fail 汇总）
    @MainActor
    func selfTestDirectory(_ dirPath: String, roiNorm: CGRect? = nil) -> String {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: dirPath)
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: nil) else {
            return "✗ 无法列目录: \(dirPath)"
        }
        // 按文件名排序，结果可复现
        let images = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "png" || ext == "jpg" || ext == "jpeg"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if images.isEmpty {
            return "✗ 目录里没有 PNG/JPG: \(dirPath)"
        }
        if loadedGlyphs.isEmpty {
            return "✗ 字模库为空：未找到 models/speed_glyphs.json 或模板尺寸不匹配"
        }

        var lines: [String] = []
        lines.append("== SpeedOCRReader 自检 ==")
        lines.append("目录: \(dirPath)")
        lines.append("字模: \(loadedGlyphs.keys.sorted().joined(separator: ", "))")
        lines.append("槽位: x=\(Self.slotCentersNorm) w=\(Self.slotWidthNorm) y=[\(Self.slotYMinNorm),\(Self.slotYMaxNorm)]")
        lines.append("帧数: \(images.count)")
        lines.append("")

        var passCount = 0
        var failCount = 0
        let glyphsSnapshot = loadedGlyphs
        for url in images {
            let name = url.lastPathComponent
            guard let cg = Self.loadCGImage(from: url) else {
                lines.append("  [skip] \(name): 读图失败")
                failCount += 1
                continue
            }
            guard let pb = Self.makeBGRABuffer(from: cg) else {
                lines.append("  [skip] \(name): 像素缓冲创建失败")
                failCount += 1
                continue
            }
            guard let slots = Self.cropSlots(from: pb, roiNorm: roiNorm) else {
                lines.append("  [skip] \(name): 槽位裁剪失败")
                failCount += 1
                continue
            }
            let result = Self.recognize(slotImages: slots, glyphs: glyphsSnapshot)
            if let err = result.error {
                lines.append("  [FAIL] \(name): \(err)")
                failCount += 1
                continue
            }
            guard let speed = result.speed else {
                lines.append("  [FAIL] \(name): 无法识别 \(result.unknownSlots)")
                failCount += 1
                continue
            }
            let speedStr = String(format: "%03ld", speed)
            let isExpected = (Self.minSpeed...Self.maxSpeed).contains(speed)
            let mark = isExpected ? "✓" : "✗"
            lines.append(String(format: "  [\(mark)] %@: speed=%@ conf=%.3f",
                               name, speedStr, result.confidence))
            if isExpected { passCount += 1 } else { failCount += 1 }
        }

        lines.append("")
        lines.append("汇总: \(passCount)/\(images.count) 通过, \(failCount) 失败")
        return lines.joined(separator: "\n")
    }

    /// 加载 PNG/JPG 文件为 CGImage（自检用）
    private nonisolated static func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return cg
    }

    /// 把任意 CGImage 打包成全屏原生 BGRA CVPixelBuffer（自检用）。
    /// - 注意：自检需要**未缩放**的原始像素缓冲，与 CaptureEngine 原生帧路径一致
    /// - 用 CGContext.draw 1:1 写入，保持 BGRA 通道序
    /// - bytesPerRow = width*4，避免 padding 干扰后续 CIImage 路径
    private nonisolated static func makeBGRABuffer(from cg: CGImage) -> CVPixelBuffer? {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         w, h,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}

// MARK: - 字模库 JSON 解码模型

/// 与 models/speed_glyphs.json 对应的解码结构
/// - templates: { "0": [[0,1,1,...], ...], "1": [...], ... }
/// - 顶层字段（version / template_* / slot_*）用于加载时的完整性校验
private struct SpeedGlyphLibrary: Decodable {
    let version: Int
    let templateWidth: Int
    let templateHeight: Int
    /// 槽位常量（JSON 里带的值，用于和 Swift 端 `Self` 常量比对，防两侧漂移）
    let slotCentersNorm: [Double]
    let slotWidthNorm: Double
    let slotYMinNorm: Double
    let slotYMaxNorm: Double
    let templates: [String: [[Int]]]

    private enum CodingKeys: String, CodingKey {
        case version, templates
        case templateWidth = "template_width"
        case templateHeight = "template_height"
        case slotCentersNorm = "slot_centers_norm"
        case slotWidthNorm = "slot_width_norm"
        case slotYMinNorm = "slot_y_min_norm"
        case slotYMaxNorm = "slot_y_max_norm"
    }
}