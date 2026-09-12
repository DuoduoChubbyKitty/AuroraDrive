// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  SpeedOCRReader.swift — 车速表读取引擎（双模型：PP-OCRv6 整行主路径 + CNN 备用）
//
//  架构（2026-09 双模型改造，模板匹配已移除）：
//    主路径  PP-OCRv6 整行推理：ROI 切片整帧 → 灰度 → 双线性 48×136 →
//            复制 3 通道 → CTC 解码 → 取数字串后 3 位 → 置信度门槛
//    备用    per-digit CNN（speed_digit_cnn_v4）：cropSlots 裁 3 槽 →
//            逐槽 90×50 → softmax 取位
//    切换    PP-OCR 运行时系统级故障（推理 throw / 输出缺失）→ 同帧自动
//            降级 CNN 并写 engineNotice（UI 橙色警示 + 车速旁引擎标签变橙）；
//            "读不到"类业务诊断（fg 低 / 置信低 / 数字串短）不算故障不切换。
//            双模型加载失败在 init 即写 errorMessage / engineNotice，绝不静默。
//    历史    早期「字模模板匹配」（speed_glyphs.json + 0~300 枚举残差）已被
//            双模型完全取代并删除；cropSlots 的槽位常量仍被 CNN 路径使用。
//
//  为什么主路径用 PP-OCRv6 微调整行模型：
//    通用 Vision OCR 对游戏 HUD 空心数字误识别率高（"000"→"NTO0U"）；
//    自训 per-digit CNN（99.98%）是分布内成绩，换分辨率/游戏/UI 可能崩。
//    PP-OCRv6 微调模型 = 官方通用预训练表征 + 本项目场景对齐，
//    冻结测试集（整段未见 clip，5077 张）99.9803%，泛化性最强
//    （见 PPOCRV6_FINETUNE_REPORT.md）。
//
//  线程模型：
//    main 入口 infer() → 后台 ocrQueue 推理 → Task @MainActor
//    applyEngineUse()（引擎状态）+ finish() 写最新快照。
//    generation 计数器防 reset() 后在途结果过期。
//
//  无效帧前置检测：
//    载入/视角错位帧画面里没有速度表 → Otsu 前景比例过低直接判无效，
//    不进入推理（防乱报）；PP-OCR 侧另有置信度门槛与数字串长度规则兜底。
// ============================================================================
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Observation

/// 固定槽位模板匹配车速读取引擎
/// - @Observable：UI 可观察 speedKmh / confidence
/// - @MainActor：可变状态主线程访问
/// - 输入：CaptureEngine onNativeFrame 的原生 CVPixelBuffer（环1 后为速度表 ROI 切片，
///   槽位坐标经 speedROINorm 换算到 ROI 相对坐标）
@Observable
@MainActor
final class SpeedOCRReader {

    // MARK: - 双模型引擎

    /// 车速识别引擎：PP-OCRv6 整行（主） / per-digit CNN（备）
    enum SpeedOCREngine: String {
        case ppocr = "PP-OCRv6"
        case cnn = "CNN"
    }

    /// 当前生效引擎（UI 可观察；切换时 UI 实时刷新）
    private(set) var activeEngine: SpeedOCREngine = .ppocr

    /// 引擎切换/加载提示（UI 可观察，非 nil 时面板显示）
    /// - 例："PP-OCR 推理失败(...)，已自动切换 CNN"、"CNN 备用模型未加载，PP-OCR 故障时无降级"
    private(set) var engineNotice: String?

    // MARK: - 槽位常量（CNN 备用路径用；与 tools/build_speed_glyphs.py 同步）

    /// 3 个数字槽的归一化 x 中心（左上角原点，x 向右）
    /// - 2026-08-15 由 clip_20260815_130055 实测校准：ROI 内 digit centers ≈ [71,120,169]px
    nonisolated static let slotCentersNorm: [CGFloat] = [0.479, 0.496, 0.512]

    /// 每个槽的归一化宽度（覆盖数字 + 抖动余量）
    /// - 实测最大数字宽度 ≈ 41px / 2940px = 0.014；旧 0.022 导致相邻槽重叠 17~21px
    nonisolated static let slotWidthNorm: CGFloat = 0.014

    /// 数字本体的归一化 y 上下界（左上角原点，y 向下）
    /// - 注意：y_min 必须跳过仪表台顶部反光带，否则 Otsu 把整张判定为前景
    nonisolated static let slotYMinNorm: CGFloat = 0.897
    /// - y_max 由实测数字底部 0.9319 取 0.932，避免旧 0.924 切掉下半段笔画
    nonisolated static let slotYMaxNorm: CGFloat = 0.932

    /// 模板缩放尺寸（H × W）；与字模库 JSON 里 template_height/template_width 一致
    nonisolated static let templateHeight: Int = 90
    nonisolated static let templateWidth: Int = 50

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

    // MARK: - PP-OCRv6 整行路径常量

    /// PP-OCRv6 微调模型推理输入（NCHW）：高 48 固定，宽 136 = ceil(51×48/18)。
    /// 训练裁片为 51×18（= speedROINorm ROI @640×360 录制帧），高 18→48 放大时
    /// 宽 51×(48/18) = 136，与评测脚本 eval_onnx.py / eval_coreml.py 完全同参。
    nonisolated static let ppocrInputHeight: Int = 48
    nonisolated static let ppocrInputWidth: Int = 136

    /// CTC 解码输出类别数 = blank(1) + keys.txt(6904) + space(1)
    nonisolated static let ppocrNumClasses: Int = 6906

    /// keys.txt 行数校验值（防字典/模型错位；第 617 行是全角空格 U+3000，属合法 token，
    /// 加载时只去换行符、绝不能用 trim——否则行内容漂移 +1，全部索引错位）
    nonisolated static let ppocrKeysLines: Int = 6904

    /// 解码规则 2：数字串长度 < 2 → 判无效（模型输出噪声帧常解成单字符）
    nonisolated static let ppocrMinDigits: Int = 2

    /// 解码规则 3：置信度 < 0.30 → 判无效。
    /// 微调后全测试集最低置信 0.8343（见 PPOCRV6_FINETUNE_REPORT.md §5），
    /// 0.30 极安全；同时下游 speedValid(conf>0.3) 语义保持一致。
    nonisolated static let ppocrMinConfidence: Double = 0.30

    /// 前置无效检测的等比例阈值：旧路径 3 槽 3375 像素上 fg<80 ≈ 2.37%，
    /// 整行路径按比例换算（窗口分辨率随全屏分辨率变化，绝对像素数不可比）
    nonisolated static let ppocrMinForegroundRatio: Double = 80.0 / 3375.0

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

    /// CNN模型（speed_digit_cnn_v4.mlpackage），替代模板匹配
    @ObservationIgnored
    private var cnnModel: MLModel?

    /// PP-OCRv6 微调整行模型（ppocrv6_tiny_ft_int8.mlpackage，1.2 MB）
    /// - 输入 image [1,3,48,136] fp32（灰度复制 3 通道，归一化 (v/255-0.5)/0.5）
    /// - 输出 logits [1,T,6906]（CTC 头）
    /// - 加载成功时为最高优先级路径（详见 recognizePPOCR）
    @ObservationIgnored
    private var ppocrModel: MLModel?

    /// keys.txt 字符表（下标 0..6903 ↔ CTC index 1..6904；0=blank、6905=space 不入表）
    @ObservationIgnored
    private var ppocrKeys: [String] = []

    /// 最近一次 OCR 诊断（为什么没出结果）；成功读出时清空。
    /// 取值示例：字模未加载 / 裁剪失败 / fg=45 过低(画面无速度表) / 残差=1520 超阈值
    @ObservationIgnored
    private(set) var lastOCRDiagnostic: String = ""

    /// 最近一次原生帧尺寸（调试用；0×0 表示尚未收到帧）
    @ObservationIgnored
    private(set) var lastNativeSize: CGSize = .zero

    // MARK: - 内部状态

    @ObservationIgnored
    private let ocrQueue = DispatchQueue(label: "com.aurora.speedocr",
                                         qos: .userInteractive)

    /// generation 计数：reset() 时递增，在途 OCR 完成后比对，丢弃过期结果
    @ObservationIgnored
    private var generation = 0

    /// 5Hz 时间闸：上一次成功入队推理的时间
    @ObservationIgnored
    private var lastInferTime: Date?

    /// 上一帧有效车速（用于跳变过滤）
    @ObservationIgnored
    private var lastValidSpeed: Double?

    /// 多帧确认候选历史：[(speed: Int, time: Date)]，每次成功入队推理追加一项
    @ObservationIgnored
    private var candidates: [(speed: Int, time: Date)] = []

    // MARK: - 初始化

    init() {
        // 加载 CNN 备用模型（先备后主，便于在主模型加载失败时给出准确提示）
        loadCNNModel()
        // 加载 PP-OCRv6 微调整行模型（主路径）
        loadPPOCRModel()
        // 双模型加载状态审计：任一缺失都显式提示，绝不静默
        switch (ppocrModel, cnnModel) {
        case (.some, .some):
            activeEngine = .ppocr
            engineNotice = nil
        case (.some, nil):
            activeEngine = .ppocr
            engineNotice = "CNN 备用模型未加载（speed_digit_cnn_v4 缺失），PP-OCR 故障时无降级"
        case (nil, .some):
            activeEngine = .cnn
            engineNotice = "PP-OCRv6 模型加载失败（\(ppocrLoadFailure)），已切换 CNN 备用引擎"
        case (nil, nil):
            activeEngine = .cnn
            errorMessage = "速度识别模型加载失败：PP-OCRv6（\(ppocrLoadFailure)）与 CNN 均不可用（检查 models/ 目录）"
        }
    }

    /// 从 models/ppocrv6_tiny_ft_int8.mlpackage 加载 PP-OCRv6 微调模型 + keys.txt 字符表
    /// - 加载失败时 ppocrModel 保持 nil，loadPPOCRModel 把原因写入 ppocrLoadFailure
    private var ppocrLoadFailure: String = ""

    private func loadPPOCRModel() {
        let root = AuroraPaths.projectRoot()
        let candidates = [
            root.appendingPathComponent("models/ppocrv6_tiny_ft_int8.mlpackage").path,
            "models/ppocrv6_tiny_ft_int8.mlpackage",
        ]
        // 字符表先于模型加载：缺表则模型无法解码
        let keysCandidates = [
            root.appendingPathComponent("models/ppocrv6_tiny_ft_keys.txt").path,
            "models/ppocrv6_tiny_ft_keys.txt",
        ]
        guard let keysPath = keysCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let raw = try? String(contentsOfFile: keysPath, encoding: .utf8) else {
            ppocrLoadFailure = "keys.txt 缺失"
            return
        }
        // 与训练端 PaddleOCR 加载语义一致：只去换行（\n / \r\n），绝不能 trim——
        // 第 617 行是全角空格 U+3000（合法 token），trim 会把它滤掉导致行数 6903、索引错位
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(arrayLiteral: "\r")) }
        // 文件末尾换行会产生一个尾随空串，去掉（不计入 6904 行）
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        guard lines.count == Self.ppocrKeysLines else {
            ppocrLoadFailure = "keys.txt 行数 \(lines.count) ≠ \(Self.ppocrKeysLines)（防字典/模型错位）"
            return
        }
        ppocrKeys = lines

        guard let modelPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            ppocrKeys = []
            ppocrLoadFailure = "mlpackage 缺失"
            return
        }
        do {
            // 新版 macOS 对 .mlpackage 需先编译再加载
            let compiledURL = try MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
            ppocrModel = try MLModel(contentsOf: compiledURL)
        } catch {
            ppocrKeys = []   // 模型加载失败则表也不留，保持"整组可用"语义
            ppocrLoadFailure = "编译/加载失败: \(error.localizedDescription)"
        }
    }

    /// 从 models/speed_digit_cnn_v4.mlpackage 加载CNN模型
    private func loadCNNModel() {
        let candidates = [
            "models/speed_digit_cnn_v4.mlpackage",
            "/Users/dupi/Desktop/自动驾驶系统/models/speed_digit_cnn_v4.mlpackage",
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            do {
                // 新版 macOS 对 .mlpackage 需先编译再加载
                let compiledURL = try MLModel.compileModel(at: url)
                let model = try MLModel(contentsOf: compiledURL)
                cnnModel = model
                return
            } catch {
                // 加载失败静默（infer 闸门会显示“CNN模型未加载”）
            }
        }
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
        // 闸 3：当前引擎模型必须可用（双模型加载失败时 init 已写 errorMessage 提示）
        guard activeEngine == .ppocr ? ppocrModel != nil : cnnModel != nil else {
            lastOCRDiagnostic = "当前引擎 \(activeEngine.rawValue) 模型不可用"
            return
        }

        // 后台队列：按当前引擎推理；PP-OCR 运行时系统级故障 → 同帧降级 CNN + 提示
        lastInferTime = Date()
        let gen = generation
        let cnnSnapshot = cnnModel
        let ppocrSnapshot = ppocrModel
        let ppocrKeysSnapshot = ppocrKeys
        let roiNorm = CaptureEngine.speedROINorm
        let engineSnapshot = activeEngine
        isInferencing = true
        ocrQueue.async { [weak self] in
            var result: RecognitionResult
            var usedEngine = engineSnapshot
            var switchNotice: String?

            switch engineSnapshot {
            case .ppocr where ppocrSnapshot != nil:
                // ── 主路径：PP-OCRv6 整行推理 ──
                // nativePixelBuffer 已是 speedROINorm ROI 切片，与训练裁片覆盖同一
                // 物理区域 → 直接整帧推理，无需裁槽
                result = Self.recognizePPOCR(roiBuffer: nativePixelBuffer,
                                             model: ppocrSnapshot!,
                                             keys: ppocrKeysSnapshot,
                                             isROISlice: true)
                if let err = result.error, let cnn = cnnSnapshot {
                    // 系统级故障（推理 throw / 输出缺失）→ 自动切换 CNN，同帧补跑不丢帧。
                    // "读不到"类业务诊断（fg 低 / 置信低 / 串短）不算故障，不切换。
                    switchNotice = "PP-OCR 推理失败（\(err)），已自动切换 CNN"
                    usedEngine = .cnn
                    if let slots = Self.cropSlots(from: nativePixelBuffer, roiNorm: roiNorm) {
                        result = Self.recognizeCNN(slotImages: slots, model: cnn)
                    } else {
                        result = RecognitionResult(diag: "CNN 降级帧槽位裁剪失败")
                    }
                }
            case .cnn:
                // ── 备用路径：per-digit CNN（3 槽裁剪）──
                if let cnn = cnnSnapshot,
                   let slots = Self.cropSlots(from: nativePixelBuffer, roiNorm: roiNorm) {
                    result = Self.recognizeCNN(slotImages: slots, model: cnn)
                } else if cnnSnapshot == nil {
                    result = RecognitionResult(error: "CNN 备用模型不可用且 PP-OCR 已故障")
                } else {
                    result = RecognitionResult(diag: "槽位裁剪失败")
                }
            default:
                result = RecognitionResult(error: "无可用速度识别引擎")
            }

            // 死诊断：fg 过低（画面无速度表 / 裁到空）→ ROI 缩略图存盘
            // /tmp/aurora_ocr_dbg_*.png 供定位（覆盖写，不阻塞主线程）
            if result.speed == nil,
               let diag = result.diag, diag.hasPrefix("fg=") {
                Self.saveOCRDebug(buffer: nativePixelBuffer, slots: [], fg: result.fgTotal)
            }
            Task { @MainActor in
                self?.applyEngineUse(usedEngine, notice: switchNotice)
                self?.finish(gen, result)
            }
        }
    }

    /// 主线程应用引擎切换结果（UI 可观察 activeEngine / engineNotice 实时刷新）
    private func applyEngineUse(_ engine: SpeedOCREngine, notice: String?) {
        if engine != activeEngine { activeEngine = engine }
        if let notice { engineNotice = notice }
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

    // MARK: - PP-OCRv6 整行推理（最高优先级路径）

    /// 对 ROI 切片（或全屏帧先裁 ROI）跑 PP-OCRv6 微调模型整行推理
    /// - 几何依据：训练裁片 = speedROINorm ROI @640×360 录制帧 = 51×18px（实测
    ///   数字笔画 bounding box 占比与槽位常量双向吻合，见 PPOCRV6_FINETUNE_REPORT.md），
    ///   运行时 ROI 切片覆盖同一物理区域 → 无需任何槽位裁剪
    /// - 预处理与 eval_onnx.py / eval_coreml.py 完全同参：
    ///   灰度 → 双线性 resize 48×136（对齐 cv2.INTER_LINEAR）→ (v/255-0.5)/0.5
    ///   → 灰度值复制 3 通道 NCHW
    /// - 解码与训练期规则一致：CTC（blank=0、折叠重复）→ 置信 ≥0.30 →
    ///   取数字串**后 3 位**左补零 → <2 位判无效；多帧级决策由上游 finish 三层校验负责
    nonisolated private static func recognizePPOCR(
        roiBuffer: CVPixelBuffer,
        model: MLModel,
        keys: [String],
        isROISlice: Bool
    ) -> RecognitionResult {
        let input: CIImage
        if isROISlice {
            input = CIImage(cvPixelBuffer: roiBuffer)
        } else {
            // 全屏帧（自检路径）：按 speedROINorm 裁出速度表区域。
            // CIImage 原点左下（y 向上），归一化坐标左上原点 → ciRect.y = sh - yMax
            let sw = CGFloat(CVPixelBufferGetWidth(roiBuffer))
            let sh = CGFloat(CVPixelBufferGetHeight(roiBuffer))
            let r = CaptureEngine.speedROINorm
            let rect = CGRect(x: r.origin.x * sw,
                              y: sh - (r.origin.y + r.height) * sh,
                              width: r.width * sw,
                              height: r.height * sh).integral
            guard rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= sw, rect.maxY <= sh else {
                return RecognitionResult(error: "PP-OCR: ROI 越界 \(rect)")
            }
            input = CIImage(cvPixelBuffer: roiBuffer).cropped(to: rect)
        }
        guard let cg = ciContext.createCGImage(input, from: input.extent),
              cg.width > 0, cg.height > 0 else {
            return RecognitionResult(error: "PP-OCR: ROI 渲染失败")
        }
        guard let gray = grayscalePixels(cgImage: cg) else {
            return RecognitionResult(error: "PP-OCR: 灰度转换失败")
        }

        // 前置无效检测（比例版）：Otsu 前景占比过低 = 画面无速度表。
        // 旧路径 3375px 上 fg<80 ≈ 2.37%；整行窗口分辨率随全屏分辨率变化，
        // 绝对像素数不可比，故按比例判定
        let binary = binarizeOtsu(gray: gray)
        let fgTotal = binary.reduce(0) { $0 + Int($1) }
        let fgRatio = Double(fgTotal) / Double(max(1, binary.count))
        if fgRatio < ppocrMinForegroundRatio {
            return RecognitionResult(
                unknownSlots: [0],
                diag: "fg=\(fgTotal) 比例 \(String(format: "%.3f", fgRatio)) 过低(画面无速度表)",
                fgTotal: fgTotal)
        }

        // 双线性 resize 到模型输入 48×136
        let resized = bilinearResizeGray(src: gray, srcH: cg.height, srcW: cg.width,
                                         dstH: ppocrInputHeight, dstW: ppocrInputWidth)
        // 归一化 (v/255-0.5)/0.5 = v/127.5-1，灰度复制 3 通道 → [1,3,48,136] NCHW fp32
        guard let inputArray = try? MLMultiArray(
            shape: [1, 3,
                    NSNumber(value: ppocrInputHeight),
                    NSNumber(value: ppocrInputWidth)],
            dataType: .float32) else {
            return RecognitionResult(error: "PP-OCR: MLMultiArray 创建失败")
        }
        let inPtr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = ppocrInputHeight * ppocrInputWidth
        for i in 0..<plane {
            let v = Float(resized[i]) / 127.5 - 1.0
            inPtr[i] = v              // C0
            inPtr[plane + i] = v      // C1（与 C0 同值：源图即灰度）
            inPtr[2 * plane + i] = v  // C2
        }

        guard let feature = try? MLDictionaryFeatureProvider(dictionary: ["image": inputArray]),
              let output = try? model.prediction(from: feature) else {
            return RecognitionResult(error: "PP-OCR: 推理失败")
        }
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            return RecognitionResult(error: "PP-OCR: 输出 logits 读取失败")
        }

        // CTC 解码 → 置信门槛 → 后 3 位规则
        guard let (text, conf) = ctcDecode(logits: logits, keys: keys) else {
            return RecognitionResult(unknownSlots: [0], diag: "PP-OCR: CTC 解码为空")
        }
        guard conf >= ppocrMinConfidence else {
            return RecognitionResult(
                unknownSlots: [0],
                diag: "PP-OCR: 置信度 \(String(format: "%.3f", conf)) < 0.30 raw=\(text)")
        }
        let digits = text.filter { $0 >= "0" && $0 <= "9" }
        guard digits.count >= ppocrMinDigits else {
            return RecognitionResult(
                unknownSlots: [0],
                diag: "PP-OCR: 数字串太短(\(digits.count)) raw=\(text)")
        }
        // 后 3 位 + 左补零（模型常在前部多读 1~2 个字符：1018→018、14→014）
        let tail = String(digits.suffix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        guard let speed = Int(tail) else {
            return RecognitionResult(unknownSlots: [0], diag: "PP-OCR: 速度解析失败 raw=\(tail)")
        }
        return RecognitionResult(speed: speed, unknownSlots: [], confidence: conf)
    }

    /// CTC 解码：逐时间步 argmax + softmax 概率 → 跳 blank(index 0)、折叠相邻重复
    /// - logits: [1, T, 6906]（行主序展开，stride = 6906）
    /// - index 1..6904 ↔ keys[0..6903]；index 6905 = space（非数字，解码忽略无害）
    /// - Returns: (解码文本, 解码字符的平均 argmax 概率)；无字符输出时 nil
    nonisolated private static func ctcDecode(
        logits: MLMultiArray, keys: [String]
    ) -> (text: String, conf: Double)? {
        let classes = ppocrNumClasses
        let steps = logits.count / classes
        guard steps > 0, keys.count == ppocrKeysLines else { return nil }
        let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
        var chars: [Character] = []
        var confs: [Double] = []
        var prev = -1
        for t in 0..<steps {
            let base = t * classes
            var best = 0
            var bestVal = ptr[base]
            for c in 1..<classes {
                let v = ptr[base + c]
                if v > bestVal { bestVal = v; best = c }
            }
            if best != 0 && best != prev {
                // softmax(best) = exp(0) / Σ exp(v-best) = 1 / Σ（数值稳定减 max）
                var sumExp: Float = 0
                for c in 0..<classes { sumExp += expf(ptr[base + c] - bestVal) }
                if best <= keys.count {
                    chars.append(contentsOf: keys[best - 1])
                } else {
                    chars.append(" ")
                }
                confs.append(Double(1.0 / sumExp))
            }
            prev = best
        }
        guard !chars.isEmpty, !confs.isEmpty else { return nil }
        return (String(chars), confs.reduce(0, +) / Double(confs.count))
    }

    /// 灰度双线性缩放（像素中心对齐 + 边缘 clamp，对齐 OpenCV INTER_LINEAR）
    /// - 训练/评测端预处理为 cv2.resize 默认 INTER_LINEAR，此处必须同插值，
    ///   否则 18→48 放大后的笔画边缘灰度分布不一致（模型对插值敏感）
    nonisolated private static func bilinearResizeGray(
        src: [UInt8], srcH: Int, srcW: Int, dstH: Int, dstW: Int
    ) -> [UInt8] {
        guard srcH > 0, srcW > 0, dstH > 0, dstW > 0, src.count == srcH * srcW else { return [] }
        var out = [UInt8](repeating: 0, count: dstH * dstW)
        let xRatio = Double(srcW) / Double(dstW)
        let yRatio = Double(srcH) / Double(dstH)
        for y in 0..<dstH {
            let sy = (Double(y) + 0.5) * yRatio - 0.5
            let y0 = min(max(Int(sy.rounded(.down)), 0), srcH - 1)
            let y1 = min(y0 + 1, srcH - 1)
            let fy = max(0.0, min(sy - Double(y0), 1.0))
            for x in 0..<dstW {
                let sx = (Double(x) + 0.5) * xRatio - 0.5
                let x0 = min(max(Int(sx.rounded(.down)), 0), srcW - 1)
                let x1 = min(x0 + 1, srcW - 1)
                let fx = max(0.0, min(sx - Double(x0), 1.0))
                let p00 = Double(src[y0 * srcW + x0])
                let p01 = Double(src[y0 * srcW + x1])
                let p10 = Double(src[y1 * srcW + x0])
                let p11 = Double(src[y1 * srcW + x1])
                let top = p00 + (p01 - p00) * fx
                let bot = p10 + (p11 - p10) * fx
                out[y * dstW + x] = UInt8((top + (bot - top) * fy).rounded())
            }
        }
        return out
    }

    // MARK: - CNN推理（替代模板匹配）

    /// 对 3 槽 CGImage 跑CNN推理，返回速度 + 置信度
    /// - 每槽：灰度 → resize 45×25 → 归一化0-1 → CoreML推理 → argmax
    /// - 前置无效检测：3 槽前景像素总数 < minValidForegroundPixels → 判无效
    nonisolated private static func recognizeCNN(
        slotImages: [CGImage],
        model: MLModel
    ) -> RecognitionResult {
        var digits: [Int] = []
        var maxConfidences: [Double] = []
        var fgTotal = 0

        for (idx, cg) in slotImages.enumerated() {
            guard cg.width > 0, cg.height > 0 else {
                return RecognitionResult(error: "invalid slot \(idx)")
            }
            // 对齐训练端 PIL LANCZOS：用 CoreImage 高质量缩放替代最近邻，
            // 消除「训练 LANCZOS vs 推理最近邻」的插值不一致（速度模型乱读的病根）
            guard let resizedCG = Self.lanczosResize(cg, toWidth: templateWidth, toHeight: templateHeight),
                  let gray = grayscalePixels(cgImage: resizedCG) else {
                return RecognitionResult(error: "resize/grayscale failed slot \(idx)")
            }
            // fg检测：Otsu 二值化统计前景像素（gray 已是 90×50）
            let binary = binarizeOtsu(gray: gray)
            fgTotal += binary.reduce(0) { $0 + Int($1) }

            // 归一化到0-1（gray 已是 90×50，无需再缩放）
            var floatPixels = [Float](repeating: 0, count: templateHeight * templateWidth)
            for i in 0..<gray.count {
                floatPixels[i] = Float(gray[i]) / 255.0
            }

            // 构造MLMultiArray (1, 1, 45, 25)
            guard let inputArray = try? MLMultiArray(shape: [1, 1, NSNumber(value: templateHeight), NSNumber(value: templateWidth)], dataType: .float32) else {
                return RecognitionResult(error: "MLMultiArray创建失败")
            }
            let ptr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<floatPixels.count {
                ptr[i] = floatPixels[i]
            }

            // CoreML推理
            let inputProvider: [String: Any] = ["digit_input": inputArray]
            guard let inputFeature = try? MLDictionaryFeatureProvider(dictionary: inputProvider) else {
                return RecognitionResult(error: "MLFeatureProvider创建失败")
            }
            guard let output = try? model.prediction(from: inputFeature) else {
                return RecognitionResult(error: "CNN推理失败 slot \(idx)")
            }

            // 读取输出 (1, 10)
            guard let outputArray = output.featureValue(for: "digit_output")?.multiArrayValue else {
                return RecognitionResult(error: "CNN输出读取失败")
            }
            let outPtr = outputArray.dataPointer.assumingMemoryBound(to: Float.self)
            var bestDigit = 0
            var bestProb: Float = -1
            for d in 0..<10 {
                let prob = outPtr[d]
                if prob > bestProb {
                    bestProb = prob
                    bestDigit = d
                }
            }
            digits.append(bestDigit)
            // softmax置信度
            var sumExp: Float = 0
            var maxVal: Float = outPtr[0]
            for d in 0..<10 { if outPtr[d] > maxVal { maxVal = outPtr[d] } }
            for d in 0..<10 { sumExp += expf(outPtr[d] - maxVal) }
            let conf = expf(maxVal - maxVal) / sumExp  // = 1/sumExp * exp(0) = 1/sumExp
            maxConfidences.append(Double(conf))
        }

        // 前置无效检测
        if fgTotal < minValidForegroundPixels {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "fg=\(fgTotal) 过低(画面无速度表)",
                                     fgTotal: fgTotal)
        }

        // 组合三位数
        guard digits.count == 3 else {
            return RecognitionResult(unknownSlots: Array(slotImages.indices),
                                     diag: "CNN槽位数不足")
        }
        let speed = digits[0] * 100 + digits[1] * 10 + digits[2]
        let avgConf = maxConfidences.reduce(0, +) / Double(maxConfidences.count)
        return RecognitionResult(speed: speed, unknownSlots: [], confidence: avgConf)
    }

    /// CoreImage 高质量缩放（Lanczos 近似）到目标尺寸
    /// 对齐训练端 PIL LANCZOS，替代最近邻消除插值不一致（速度模型乱读的病根）
    nonisolated private static func lanczosResize(_ cg: CGImage, toWidth: Int, toHeight: Int) -> CGImage? {
        guard toWidth > 0, toHeight > 0, cg.width > 0, cg.height > 0 else { return nil }
        let ci = CIImage(cgImage: cg)
        let scaleX = CGFloat(toWidth) / CGFloat(cg.width)
        let scaleY = CGFloat(toHeight) / CGFloat(cg.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rect = CGRect(x: 0, y: 0, width: CGFloat(toWidth), height: CGFloat(toHeight))
        return ciContext.createCGImage(scaled, from: rect)
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
                                                         kUTTypePNG, 1, nil) else { return }
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
        // 双引擎自检：PP-OCR 可用则走主路径，否则 CNN 备用；两者皆无 → 拒绝自检
        let usePPOCR = ppocrModel != nil
        guard usePPOCR || cnnModel != nil else {
            return "✗ PP-OCRv6 与 CNN 模型均未加载（检查 models/ 目录）"
        }

        var lines: [String] = []
        lines.append("== SpeedOCRReader 自检 ==")
        lines.append("目录: \(dirPath)")
        lines.append("引擎: \(usePPOCR ? "PP-OCRv6 整行 (int8)" : "CNN 备用 (3槽)")")
        if usePPOCR {
            lines.append("PP-OCR 输入: [1,3,\(Self.ppocrInputHeight),\(Self.ppocrInputWidth)]  keys=\(ppocrKeys.count)行")
        } else {
            lines.append("槽位: x=\(Self.slotCentersNorm) w=\(Self.slotWidthNorm) y=[\(Self.slotYMinNorm),\(Self.slotYMaxNorm)]")
        }
        lines.append("帧数: \(images.count)")
        lines.append("")

        var passCount = 0
        var failCount = 0
        let cnnSnapshot = cnnModel
        let ppocrSnapshot = ppocrModel
        let ppocrKeysSnapshot = ppocrKeys
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
            let result: RecognitionResult
            if let pp = ppocrSnapshot {
                // PP-OCR 整行路径：roiNorm 非 nil 表示输入已是 ROI 切片 → 整帧即窗口；
                // nil 表示全屏帧 → recognizePPOCR 内部按 speedROINorm 裁剪
                result = Self.recognizePPOCR(roiBuffer: pb, model: pp,
                                             keys: ppocrKeysSnapshot,
                                             isROISlice: roiNorm != nil)
            } else if let cnn = cnnSnapshot {
                guard let slots = Self.cropSlots(from: pb, roiNorm: roiNorm) else {
                    lines.append("  [skip] \(name): 槽位裁剪失败")
                    failCount += 1
                    continue
                }
                result = Self.recognizeCNN(slotImages: slots, model: cnn)
            } else {
                result = RecognitionResult(error: "无可用引擎")
            }
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