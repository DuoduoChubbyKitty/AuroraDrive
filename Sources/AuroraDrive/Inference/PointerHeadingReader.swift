// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PointerHeadingReader.swift — 小地图箭头朝向（角色身体朝向）
// ============================================================================
//
//  【这个文件解决什么问题】
//    网络定位（CoordinateCapture / MaaNTE nte_coordinate_api）解出的朝向是 UE5 的
//    **ControlRotation**（相机/视角朝向）。第三人称下相机可独立旋转 →
//    「视角朝向 ≠ 身体朝向」，沿路网跟车会用错方向。
//    本文件读小地图上那个**箭头**，它表示**角色身体朝向**（已用游戏内世界坐标
//    轨迹交叉验证，见下）。
//
//  【模型】
//    models/tiny_arrow_v2.mlmodelc
//      自训。训练数据 = 从真实帧抠出的箭头精灵，程序化旋转 0~360° 贴到真实小地图
//      背景上合成 20000 张（`/tmp` 侧生成器，标签精度 0°，非人工标注）。
//      体积 44 KB / 11962 参数 / 输入 64×64。
//      契约：image [1,3,64,64] Float32（RGB，**归一化到 [-1,1]**）
//            → heading_sincos [1,2] Float32 = (sinθ, cosθ)
//      实测：val 角度误差 p50 0.56° / p95 1.81°；180° 翻转率 0.0%；
//            CPU_ONLY 单帧 p50 0.087ms；CoreML vs PyTorch 差 max 0.272°。
//
//  【θ₀：模型输出 → 绝对罗盘角的固定偏移 = 332.0°】
//    模型学的是「相对精灵原生朝向的旋转量」，不是绝对罗盘角，故
//       真实罗盘角 = 模型输出 + θ₀
//    θ₀ 用**游戏内世界坐标轨迹**客观标定（视频左上角一直显示 XYZ 读数，可逐帧读出）。
//    罗盘角 = atan2(ΔX, −ΔY)（即 +X=东、+Y=南，与 UE5 左手系 X前/Y右 相容）。
//    四个独立测量：
//      · 世界坐标轨迹（单段 120 帧，12 个读数点）       → 338.05°（圆标准差 12.22°）
//      · 世界坐标轨迹（5 个不同朝向路段，16 个读数点）   → 329.4°（圆标准差 5.36°）
//      · 几何法（三角形最短边对面的顶点 = 箭尖）         → 333.6°
//      · 目视判读（旋转扫描图上箭头朝正北的那一格）       → 330.0°
//    四法落在 329.4~338.1 区间，取精度加权圆均值 **332.0°**。
//    （曾出现的候选 113.0 / 216.3 / 141.0 已被全部四法排除，差 >110°。）
//
//    该标定同时**证实了「箭头 = 身体朝向」**：模型输出加常量后正好等于**移动方向**，
//    而直线行进时移动方向 = 身体朝向。若箭头是视角朝向，四法不可能收敛到同一常量。
//
//    ⚠️ 残余不确定度 ±4.4°，来自「精灵从单帧抠出、其自身朝向只能反推」这一构造。
//       若将来发现系统性固定偏差，只需改这一个常量，**不必重训模型**。
//
//  【ROI 契约】
//    ROI 定义在 **1280×720** 基准：`(x=66, y=76, w=118, h=96)`，为项目作者在
//    5 张 640×360 真实跑图帧上手工标注的平均值（×2 换算到 720p）。
//    小地图恒在画面**左上角**。ROI 按 `(frameW/1280, frameH/720)` 等比缩放后取整。
//
//  【两步定位（关键）】
//    模型吃的是**箭头局部裁剪**，不是整块 ROI。故运行时：
//      ① ROI 内按 HSV 找金色连通域 → 用形状判据排除干扰（橙色任务图标、
//         金色圆形图标、圆环）
//      ② 以箭头质心为中心裁 `3.2 × max(bboxW,bboxH)` 的正方形 → 缩放 64×64 → 推理
//
//    选块规则优先「**距小地图圆心最近**」——游戏机制规定角色恒在圆心，箭头必然
//    贴圆心；这是零成本、无质量损失的确定性先验。
//
//    ⚠️ 2026-10-23 修正（独立复核发现）：圆心先验此前用 **ROI 中心**当代理，是错的。
//      实测箭头屏幕位置恒定在 1080p 的 (152.2, 130.4)（120 帧 std 0.39/0.54 px），
//      换算 720p = **(101.5, 86.9)**；而 ROI(66,76,118,96) 的中心是 (125, 124)，
//      **偏 38px**（ROI 半宽才 59px）。原代码用 ROI 中心，多候选时会系统性偏向错误一侧。
//      现改为 `minimapCenterIn720p` 实测常量，按与 ROI 相同的 (frameW/1280, frameH/720)
//      等比缩放。本次 120 帧每帧只有 1 个候选块，所以旧代码**未暴露**该缺陷；
//      这是纯逻辑修正，不降低任何质量。
//
//  【实测命中率（2026-10-23 实测，二进制 /tmp/aurora_fix）】
//    · 1080p 真游戏 120 帧（full1080seq）：**120/120**，置信度 p50=0.768
//    · 640×360 真游戏 120 帧（clip640v）：**37/120**（小目标档受像素化影响，召回明显偏低）
//    · ⚠️ 非游戏画面（clip_20261011_020034，ROI 覆盖桌面/风景）：**436/449 帧仍会选出块**
//        → 形状判据**无法**区分景物金色块与真箭头（实测：把 aspect 2.60→1.80 收紧后
//          非游戏误检 435→417 仅降 4%，而 640 真箭头命中 10→4 掉 60%，故**不收紧**）。
//        → 结论：**必须在调用侧判断「当前是否在游戏画面」，本读取器不具备该能力。**
//          调用方应结合 `EngineClient`/抓屏目标窗口状态做前置门控，否则会输出
//          「看似合理的错误角度」（实测出现过 104°）。
//
//  【性能纪律】
//    · 只做「ROI → 金色掩膜 → 连通域 → 裁剪 → 一次推理」，不碰任何驾驶链路
//    · 单帧 p50 **0.087ms 是 CPU_ONLY 口径**（早期测量）。当前实际配置是
//      `.cpuAndNeuralEngine`（见 `init` 里的 `config.computeUnits`）——
//      **ANE 口径未单独测量**，不得把这个数当成当前配置的实测值。
//    · 整帧级缓冲（RGBA / 金色掩膜 / visited）确实按需扩容复用，**不每帧分配**；
//      但「无每帧堆分配」这个说法**不成立**，实测存在下列小分配：
//        - `locateArrow` 每次调用（每帧）建 `stack` / `pix` 两个 `[Int]`（reserveCapacity 256，
//          块间 `removeAll(keepingCapacity:)` 复用）
//        - `holeFraction` 对**每个候选块**分配 `inBlob` / `outside` / `stack` 三个小数组
//          （各 ≤4096 bool/int；仅当 bbox 面积 ≤4096 才计算，超出直接返回 0）
//      量级都很小（KB 级、每帧数次），但注释不应谎称「无」。
//    · 模型缺失 / 未检出 / 形状不合格 / **输出契约不符** → `read()` 返回 nil
//    · **绝不猜**：形状不合格或输出 shape/dtype/strides 不符就报 nil，不吐假角度
//
//  【线程模型】
//    `read(frame:)` 是同步纯计算，可在任意队列调用；内部无共享可变状态
//    （工作缓冲是本实例属性，由调用方保证串行 —— 与 SpeedOCRReader 同纪律）。
// ============================================================================

import CoreGraphics
import CoreML
import Foundation

// MARK: - 输出

/// 小地图箭头读数（角色**身体朝向**）
struct PointerHeading: Equatable {
    /// 身体朝向（罗盘角，0 = 正北 = 地图上方，顺时针为正，范围 [0,360)）
    ///
    /// 与 `CoordinateCapture.cameraHeading` **同口径**（compass），但**不同源**：
    /// 该值读的是小地图箭头（身体朝向），cameraHeading 是相机/视角朝向。
    /// 第三人称下两者可显著不同 —— 这正是本读数存在的意义。
    let headingDeg: Double

    /// 读数置信度 [0,1]。
    ///
    /// 由两部分合成：模型输出的单位向量模长（越接近 1 越确定）与箭头形状质量
    /// （与判据阈值的余量）。低于调用方阈值应视为不可信。
    let confidence: Double

    /// 箭头三关键点在 64×64 裁剪图内的**归一化**坐标 [0,1]（调试/可视化用）
    ///
    /// 新模型只回归 (sinθ,cosθ)，不输出关键点，故这里用几何量回填：
    /// `tip` = 由角度反推的尖端位置，`left`/`right` = 底边两端。
    /// 三者仅用于调试叠加显示，**不参与角度计算**。
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint

    /// 箭头在整帧中的外接框（用于调试叠加）
    let bboxInFrame: CGRect
}

// MARK: - 读取器

/// 小地图箭头朝向读取器（角色身体朝向）。
///
/// 用法：
/// ```swift
/// let reader = PointerHeadingReader()
/// if reader.isAvailable, let h = reader.read(frame: cgImage) {
///     // h.headingDeg 是身体朝向（罗盘角）
/// }
/// ```
final class PointerHeadingReader {

    // MARK: - 模型契约常量

    /// CoreML 输入特征名（与 `tiny_arrow_v2.mlmodelc/metadata.json` 对齐）
    private static let inputName = "image"
    /// CoreML 输出特征名。导出时已固定，不动态取名（与 YoloEngine 的纪律不同，
    /// 因为这个模型是我们自己导出的，名字受控）。
    private static let outputName = "heading_sincos"
    /// 模型输入边长（正方形）
    private static let modelSide = 64
    /// 模型输出维度：(sinθ, cosθ)
    private static let outputDim = 2
    /// 模型输出 → 绝对罗盘角的固定偏移（见文件头「θ₀」推导，四法加权圆均值）
    private static let headingOffsetDeg: Double = 332.0

    // MARK: - 检测常量（与 Python 参考实现 `runtime_detector.py` 逐项对齐）

    /// 金色 HSV 门限（hue 用 0..360 度）。
    /// 橙色任务图标 hue 13/36/38 被下限 41 排除。
    private static let hueMin = 41.0
    private static let hueMax = 62.0
    private static let satMin = 0.22
    private static let valMin = 0.55

    /// ROI，定义在 1280×720 基准（作者手标平均，见文件头）
    private static let roiIn720p = CGRect(x: 66, y: 76, width: 118, height: 96)
    private static let roiBaseWidth: Double = 1280
    private static let roiBaseHeight: Double = 720

    /// 计算区域相对 ROI 的外扩量（整帧像素）。**不是经验值**，由 `judge()` 的接受域反推。
    ///
    /// 【为什么不能只算 ROI】裁剪窗 `winSide = sideRatio × 最长边` 以箭头**质心**为中心，
    ///   而质心可能就贴在 ROI 边上 → 窗口必然溢出 ROI。只画 ROI 的话，溢出部分读到的是
    ///   未初始化内存 → 模型输入被污染 = 静默降质量（正是不能接受的那种）。
    ///
    /// 【上界推导】能进入推理的块必须满足 `judge()`：
    ///   像素数 ≤ areaMax = `areaRef640Max×(frameW/640)²`、填充率 ≥ fillMin、宽高比 ≤ aspectMax。
    ///   填充率定义 `fill = 像素数 / (bbox 宽×高)` ⇒ bbox 面积 ≤ areaMax/fillMin，
    ///   最长边 L ≤ √(bbox面积 × aspectMax)。窗口以质心为中心 ⇒ 任一侧最多溢出
    ///   `winSide/2 + 0.5`（+0.5 是 `round` 取整）。
    ///
    /// 【为什么不写成常量】判据、`sideRatio` 或分辨率一变，安全边界就变 —— 硬编码的
    ///   数字会悄悄失效。此处每次按当前 frameW 现算，改判据也不用回头改这个数。
    ///
    /// 两个档位分别算后取较松者（小档用 small 阈值，大档到 areaMax 封顶）。
    /// 1280 宽 → 49px；1920 宽 → 73px（1080p 实走大档，见 `judge` 的 isSmall 分支）。
    private static func computeMargin(frameW: Int) -> Int {
        let areaMax = areaRef640Max * pow(Double(frameW) / 640.0, 2)
        let smallMaxSide = (min(areaMax, smallAreaSplit) / smallFillMin * smallAspectMax).squareRoot()
        let normalMaxSide = (areaMax / normalFillMin * normalAspectMax).squareRoot()
        let maxSide = max(smallMaxSide, normalMaxSide)
        return Int(ceil(sideRatio * maxSide / 2)) + 2
    }

    /// 小地图**真实圆心**，定义在 1280×720 基准 —— 选块先验（见文件头「两步定位」）。
    ///
    /// 【实测来源】2026-10-23 在 120 帧 1080p 真游戏帧（`/tmp/nte_vid/full1080seq`）
    ///   上实测箭头金色块质心：1080p 均值 **(152.21, 130.37)**，逐帧
    ///   `x∈[152,153] y∈[129,131]`（std 0.39 / 0.54 px）——
    ///   箭头位置**恒定不动**，即「箭头就在小地图圆心」这条先验本身成立。
    ///   按 1280/1920 = 2/3 换算到 720p → (101.47, 86.91)，取 **(101.5, 86.9)**。
    ///
    /// 【为什么不能用 ROI 中心】ROI 只是「小地图所在矩形」的手标框，其中心
    ///   (125, 124) 与真实圆心 (101.5, 86.9) 相距 **38px**（而 ROI 半宽仅 59px）。
    ///   旧实现拿 ROI 中心当代理：每帧只有一个候选块时看不出问题，但一旦出现
    ///   2 个以上合格金色块，就会系统性偏向 ROI 中心那一侧 —— 而箭头根本不在那儿。
    ///   （独立复核 2026-10-23 §4 实测 ROI 中心 (187.5,186) 与 1080p 真实圆心
    ///    (152.3,130.4) 相差 66px，同一结论。）
    private static let minimapCenterIn720p = CGPoint(x: 101.5, y: 86.9)

    /// 面积门限，以 640 宽为基准，按帧宽**二次**缩放
    private static let areaRef640Min: Double = 10.0
    private static let areaRef640Max: Double = 50.0

    /// 面积分档界（小于此用「小目标档」阈值）
    private static let smallAreaSplit: Double = 80.0

    /// 形状判据：小目标档（640×360 真机箭头 14~28px，受像素化影响放宽）
    private static let smallAspectMax: Double = 2.6
    private static let smallFillMin: Double = 0.38
    private static let smallFillMax: Double = 0.92
    private static let smallSharpenMin: Double = 4.4
    private static let smallHoleFracMax: Double = 0.10

    /// 形状判据：常规档（面积 ≥ smallAreaSplit）
    private static let normalAspectMax: Double = 1.8
    private static let normalFillMin: Double = 0.42
    private static let normalFillMax: Double = 0.78
    private static let normalSharpenMin: Double = 4.8
    private static let normalHoleFracMax: Double = 0.06

    /// ★主判据：边界像素到质心的半径变异系数 `std(r)/mean(r)`。
    /// 两档共用、绝不放宽 —— 实测圆 0.019~0.026、箭头 0.225~0.257（差约 10×），
    /// 金色圆形图标正是靠这一项被排除，且与尺度无关。
    private static let rcvMin: Double = 0.12

    /// 裁剪窗边长 = sideRatio × 箭头外接框最长边。
    /// 3.2 → 64px 窗 ≥ 2×箭头最大半径（实测 12.6px @1080p），留边充足且不浪费分辨率。
    private static let sideRatio: Double = 3.2

    /// 连通域面积下限（预筛，减少簇数；比 areaMin 更松，真正门限在 judge 里）
    private static let componentMinArea = 6

    // MARK: - 状态

    /// 已加载的模型（nil = 不可用）
    private let model: MLModel?

    /// 模型是否可用（文件存在且加载成功）
    var isAvailable: Bool { model != nil }

    /// 不可用原因（供 UI/日志如实说明，不静默）
    private(set) var unavailableReason: String?

    /// 输入 MLMultiArray 缓冲（复用）
    private var inputArray: MLMultiArray?

    /// 工作缓冲：RGB 浮点（整帧级，按需扩容）。存归一化前的 uint8 更省内存，
    /// 但为减少重复转换，这里直接存 RGBA8 的整帧副本。
    private var frameRGBA: [UInt8] = []
    private var frameW = 0
    private var frameH = 0

    /// 工作缓冲：金色掩膜（整帧级，按需扩容）
    private var goldMaskBuf: [Bool] = []
    /// 工作缓冲：连通域访问标记
    private var visitedBuf: [Bool] = []

    // MARK: - 初始化

    /// - Parameter modelFileName: 模型文件名（不带扩展名）
    init(modelFileName: String = "tiny_arrow_v2") {
        let modelsDir = AuroraPaths.modelsDir()
        let compiled = modelsDir.appendingPathComponent("\(modelFileName).mlmodelc")

        guard FileManager.default.fileExists(atPath: compiled.path) else {
            model = nil
            unavailableReason = "模型不存在：\(compiled.path)"
            return
        }

        // 【为什么优先 .mlmodelc】`.mlpackage` 不能直接 MLModel(contentsOf:)，
        //   必须先 compileModel（有运行时编译开销）。本文件只认 .mlmodelc ——
        //   与 InferenceEngineV2 同一纪律。
        let config = MLModelConfiguration()
        // 【为什么 .cpuAndNeuralEngine】输入仅 64×64、12k 参数，图规模极小，
        //   ANE 是首选。显式排除 GPU：本项目铁律是「不抢游戏 GPU」。
        //   实测 CPU_ONLY p50 0.087ms，ANE 不会更慢，故两者都留。
        config.computeUnits = .cpuAndNeuralEngine

        do {
            let loaded = try MLModel(contentsOf: compiled, configuration: config)
            model = loaded
            // 预热：首次 predict 含图加载/算子分发，冷启动可达数十毫秒。
            warmUp()
        } catch {
            model = nil
            unavailableReason = "模型加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 主入口

    /// 从整帧画面读取角色身体朝向。
    ///
    /// - Parameter frame: 抓屏整帧（任意分辨率，内部按 720p 基准等比换算 ROI）
    /// - Returns: 读数；模型不可用 / 未检出箭头 / 形状不合格 / 推理失败时返回 nil
    ///
    /// - Note: 调用方负责频率门控。本方法同步、不做节流。
    ///         **形状不合格时返回 nil 而不是猜角度** —— 宁可报「无指针」也不给假朝向。
    func read(frame: CGImage) -> PointerHeading? { read(frame: frame, dumpInputTo: nil) }

    /// 带调试导出的内部版本：`dumpInputTo` 非空时把送进模型的 `[1,3,64,64]`
    /// 原始浮点张量以二进制写出（供与参考实现对拍）。仅自检用，正常运行传 nil。
    func read(frame: CGImage, dumpInputTo path: String?) -> PointerHeading? {
        guard let model else { return nil }

        // ── 分段耗时打点（仅 AURORA_PERF=1 时生效，关闭时每次只是一次静态 bool 判断）──
        //
        // 【为什么要分段】回答「规则能否替代模型」时，**只有推理段是真能省掉的部分**：
        //   掩膜与连通域是规则也要跑的公共成本。因此必须把这两段与推理段分开计量，
        //   否则「模型总耗时」这个单值会被误读成「换规则能省这么多」。
        // 【通道命名】与现有 tick.pointer 同前缀，自检里按 "pointer." 前缀汇总打印。
        let totalT0 = PerfBus.stamp()
        defer { PerfBus.mark("pointer.total", from: totalT0) }
        var stageT = totalT0

        let frameW = frame.width
        let frameH = frame.height
        guard frameW > 0, frameH > 0 else { return nil }

        // ── ROI 换算：720p 基准 → 当前帧等比缩放 ──
        let sx = Double(frameW) / Self.roiBaseWidth
        let sy = Double(frameH) / Self.roiBaseHeight
        let roi = CGRect(
            x: Self.roiIn720p.minX * sx,
            y: Self.roiIn720p.minY * sy,
            width: Self.roiIn720p.width * sx,
            height: Self.roiIn720p.height * sy
        ).integral

        guard roi.minX >= 0, roi.minY >= 0,
              roi.maxX <= Double(frameW), roi.maxY <= Double(frameH),
              roi.width >= 4, roi.height >= 4 else {
            return nil
        }

        // ── 只绘制/掩膜「真正会用到的小区域」──
        //   区域 = ROI 四边各外扩 computeMargin，再夹到帧内。
        //   外扩量不是经验值：它覆盖「裁剪窗以质心为中心时可能溢出 ROI 的最大距离」，
        //   由 judge() 的接受域反推；质心必在 ROI 内（locateArrow 只扫 ROI），故够用。
        let margin = Self.computeMargin(frameW: frameW)
        let regionX0 = max(0, Int(roi.minX.rounded(.down)) - margin)
        let regionY0 = max(0, Int(roi.minY.rounded(.down)) - margin)
        let regionX1 = min(frameW, Int(roi.maxX.rounded(.up)) + margin)
        let regionY1 = min(frameH, Int(roi.maxY.rounded(.up)) + margin)
        guard regionX1 > regionX0, regionY1 > regionY0 else { return nil }
        let region = Rect4(x: regionX0, y: regionY0,
                           w: regionX1 - regionX0, h: regionY1 - regionY0)
        guard prepareFrameBuffer(frame, region: region) else { return nil }
        // 绘制 + 金色掩膜：规则方案**同样要付**的成本（现已只在该区域上做）
        stageT = PerfBus.lap("pointer.drawMask", from: stageT)
        let bw = frameW
        let rx0 = Int(roi.minX), ry0 = Int(roi.minY)
        let rw = Int(roi.width), rh = Int(roi.height)

        // ── ① ROI 内找箭头 ──
        // 选块先验 = **实测真实圆心**（不是 ROI 中心），按与 ROI 相同的比例缩放。
        let mmCenterX = Self.minimapCenterIn720p.x * sx
        let mmCenterY = Self.minimapCenterIn720p.y * sy
        guard let arrow = locateArrow(inROI: (rx0, ry0, rw, rh), frameW: bw,
                                      centerX: mmCenterX, centerY: mmCenterY) else {
            return nil
        }
        // 连通域 + 形状判据 + 选块：规则方案**同样要付**的成本
        stageT = PerfBus.lap("pointer.locate", from: stageT)

        // ── ② 以箭头为中心裁正方形 → 64×64 ──
        guard let input = makeModelInput(arrow: arrow) else { return nil }
        // 3.2×L 裁剪 + 双线性采样 → 64×64：规则方案可省，但省下的量级需实测
        stageT = PerfBus.lap("pointer.crop", from: stageT)

        // ── 调试导出（仅自检路径）──
        if let path {
            let n = input.count
            let p = input.dataPointer.assumingMemoryBound(to: Float32.self)
            let data = Data(bytes: p, count: n * MemoryLayout<Float32>.size)
            try? data.write(to: URL(fileURLWithPath: path))
        }

        // ── ③ 推理 ──
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
        } catch {
            return nil
        }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            return nil
        }
        // CoreML 实推理：**换规则后唯一真正能省掉的一段**
        stageT = PerfBus.lap("pointer.infer", from: stageT)

        // ── ③ 输出契约校验（**绝不猜**：形状/dtype 不符一律报 nil，不解释字节）──
        //
        // 【为什么必须逐项校验，不能只判 count】独立复核（2026-10-23 §5.2）指出：
        //   原实现只判 `array.count >= 2`，于是 `[2,1]`、`[1,1,2]`、`[2]` 都能通过；
        //   更危险的是 `dataType` 不是 Float32 时 —— `assumingMemoryBound(to: Float32.self)`
        //   会把原始字节当 float32 解释（Float16/Double 数组都会踩），得到
        //   「**有限但毫无意义**」的数，`isFinite` 根本拦不住 → 静默吐假角度。
        //   当前 metadata.json 确实是 `[1,2]` Float32，所以今天不出错；
        //   但**换模型时会静默出错**，违反本项目「绝不猜」红线。
        guard let outputValue = output.featureValue(for: Self.outputName),
              let array = outputValue.multiArrayValue else {
            unavailableReason = "模型输出缺少 `\(Self.outputName)` 或不是 MLMultiArray"
            return nil
        }
        guard array.dataType == .float32 else {
            unavailableReason = "模型输出 dtype=\(array.dataType.rawValue)，契约要求 Float32"
            return nil
        }
        guard array.shape.count == 2,
              array.shape[0].intValue == 1,
              array.shape[1].intValue == Self.outputDim else {
            unavailableReason = "模型输出 shape=\(array.shape.map(\.intValue))，契约要求 [1,\(Self.outputDim)]"
            return nil
        }
        // 连续存储是下面「按 offset 直读」的前提；非连续布局必须显式拒绝，
        // 而不是靠 stride 兜底去猜（原实现在 stride 异常时静默回退 ptr[1]）。
        guard array.strides.count == 2,
              array.strides[0].intValue == Self.outputDim,
              array.strides[1].intValue == 1 else {
            unavailableReason = "模型输出 strides=\(array.strides.map(\.intValue))，非连续 [1,\(Self.outputDim)] 布局"
            return nil
        }

        // ── ④ (sinθ,cosθ) → 角度，加 θ₀ 偏移 ──
        // 【索引铁律】输出 shape 是 [1,2]，故 `strides = [2,1]`：
        //   元素 [0,0] 在 offset 0，元素 [0,1] 在 offset **1**（= strides[1]）。
        //   曾误用 strides[0]（=2）→ 读到越界内存 → 模长 0.03、角度在 242°/62° 乱跳。
        //   strides 已在上方校验为 [2,1]，故这里直接读 ptr[1]（= 第 0 行第 1 列）。
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let s = Double(ptr[0])
        let c = Double(ptr[1])
        guard s.isFinite, c.isFinite else { return nil }
        let norm = (s * s + c * c).squareRoot()
        guard norm > 1e-6 else { return nil }

        let modelDeg = atan2(s, c) * 180 / .pi
        var heading = modelDeg + Self.headingOffsetDeg
        heading = heading.truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }

        // 置信度 = 单位向量模长（模型归一化输出应≈1，偏离说明回归不确定）
        //          × 形状余量（与判据阈值的最小相对余量，0.7~1.0）
        let shapeness = min(1.0, max(0.0, arrow.shapeMargin))
        let confidence = min(1.0, norm) * (0.7 + 0.3 * shapeness)

        // 调试用关键点：由角度反推尖端与底边（不参与角度计算）
        let rad = heading * .pi / 180
        let tipN = CGPoint(x: 0.5 + sin(rad) * 0.35, y: 0.5 - cos(rad) * 0.35)
        let leftN = CGPoint(x: 0.5 + sin(rad + 2.4) * 0.22, y: 0.5 - cos(rad + 2.4) * 0.22)
        let rightN = CGPoint(x: 0.5 + sin(rad - 2.4) * 0.22, y: 0.5 - cos(rad - 2.4) * 0.22)

        return PointerHeading(
            headingDeg: heading,
            confidence: confidence,
            tip: tipN,
            left: leftN,
            right: rightN,
            bboxInFrame: CGRect(x: arrow.x0, y: arrow.y0,
                                width: arrow.w, height: arrow.h))
    }

    // MARK: - 整帧缓冲准备

    /// 把**参与计算的小区域**绘到复用的 RGBA8 缓冲，并只在该区域算金色掩膜。
    ///
    /// 【为什么只画一小块】小地图指针只可能出现在 ROI（+裁剪窗外扩余量）内，
    ///   而旧实现对**整帧**做 CGContext 绘制与逐像素 HSV 掩膜：1280×832 上要算 106 万像素，
    ///   实际只用约 1.4%。实测这两段合计 ≈2.8ms，占指针链路 80%（见交接笔记第 16 节）。
    ///
    /// 【为什么缓冲尺寸与步长仍是整帧】下游 `locateArrow` / `holeFraction` /
    ///   `makeModelInput` 一律按「整帧行步长 = frameW」索引。保持缓冲尺寸与步长不变、
    ///   只缩小**写入范围**，下游代码一行都不用改 —— 这是把改动风险压到最低的做法。
    ///   （区域外像素保持旧值，但没有任何代码会读它们：检测只在 ROI 内，裁剪窗也在区域内。）
    ///
    /// - Parameter region: 需要计算的整帧像素矩形（ROI 外扩后，已夹在帧内）
    private func prepareFrameBuffer(_ frame: CGImage, region: Rect4) -> Bool {
        let w = frame.width
        let h = frame.height
        let need = w * h * 4
        if frameRGBA.count != need {
            frameRGBA = [UInt8](repeating: 0, count: need)
        }
        let gold = w * h
        if goldMaskBuf.count != gold {
            goldMaskBuf = [Bool](repeating: false, count: gold)
            visitedBuf = [Bool](repeating: false, count: gold)
        }
        frameW = w
        frameH = h
        // 细分计时起点：把「绘制」与「金色掩膜」分开，才能判断耗时归谁
        let t0 = PerfBus.stamp()

        // 只缩小**写入范围**，几何与旧实现（整帧绘制）完全一致：
        //   clip 到区域后仍按 `(0,0,w,h)` 原样画整图，区域外像素不动。
        //   于是「区域内像素值 ≡ 整帧绘制」是**构造性保证**，不需要任何 y 翻转推导
        //   —— 实测区域 0/92448 字节差异，暖态耗时 0.211ms → 0.015ms（约 14×）。
        let drawn: Bool = frameRGBA.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            guard let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Self.deviceRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // 【y 换算】位图上下文原点在左下，`region.y` 是自上而下的图像行号，
            //   故裁剪矩形的左下角 = h − (region.y + region.h)。
            ctx.clip(to: CGRect(x: region.x, y: h - region.y - region.h,
                                width: region.w, height: region.h))
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        let t1 = PerfBus.lap("pointer.blit", from: t0)
        // 【为什么只在区域清零】visitedBuf 是连通域 BFS 的标志位，必须**每帧复位**，
        //   否则第二帧起所有像素都被视为「已访问」→ 找不到连通域 → read() 恒 nil。
        //   BFS 只在 ROI 内跑，故只清区域即可（整帧 106 万字节 → 区域 4 万字节）。
        visitedBuf.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                for row in region.y..<(region.y + region.h) {
                    memset(base + row * w + region.x, 0, region.w)
                }
            }
        }
        buildGoldMask(region: region)
        PerfBus.mark("pointer.mask", from: t1)
        return true
    }

    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    /// 在**指定区域**上算金色掩膜（一次遍历，整数/浮点四则，无查表）。
    ///
    /// HSV 判定用等价比较式，避免每像素 3 次除法：
    ///   sat = (max-min)/max ≥ satMin  ⟺  max-min ≥ satMin·max
    ///   val = max ≥ valMin
    ///   hue 落区间需分 max 通道讨论（见下）。
    ///
    /// 区域外的掩膜值保持旧值 —— 但没有任何代码读它们：`locateArrow` 只扫 ROI，
    /// 而 ROI 距区域四边各 ≥ `computeMargin` 像素。
    private func buildGoldMask(region: Rect4) {
        let w = frameW
        frameRGBA.withUnsafeBufferPointer { src in
            goldMaskBuf.withUnsafeMutableBufferPointer { dst in
                guard let sp = src.baseAddress, let dp = dst.baseAddress else { return }
                for y in region.y..<(region.y + region.h) {
                    let rowStart = y * w + region.x
                    for i in rowStart..<(rowStart + region.w) {
                        let p = i * 4
                        let r = Double(sp[p]) / 255.0
                        let g = Double(sp[p + 1]) / 255.0
                        let b = Double(sp[p + 2]) / 255.0
                        let mx = max(r, max(g, b))
                        let mn = min(r, min(g, b))
                        if mx < Self.valMin { dp[i] = false; continue }
                        let d = mx - mn
                        if d < Self.satMin * mx { dp[i] = false; continue }
                        // hue（0..360）。d>0 已由上一行保证（satMin>0 且 mx>0）
                        let hue: Double
                        if mx == r {
                            hue = 60.0 * (((g - b) / d).truncatingRemainder(dividingBy: 6))
                        } else if mx == g {
                            hue = 60.0 * ((b - r) / d + 2)
                        } else {
                            hue = 60.0 * ((r - g) / d + 4)
                        }
                        let hh = hue < 0 ? hue + 360 : hue
                        dp[i] = (hh >= Self.hueMin && hh <= Self.hueMax)
                    }
                }
            }
        }
    }

    // MARK: - 箭头定位

    /// 一个候选连通域的形状特征（全部为尺度无关比值）
    private struct BlobFeatures {
        var area = 0
        var x0 = 0, y0 = 0, w = 0, h = 0
        var cx = 0.0, cy = 0.0
        var aspect = 0.0
        var fill = 0.0
        var sharpen = 0.0
        var rcv = 0.0
        var holeFrac = 0.0
        /// 通过判据后计算的形状余量 [0,1]，用于置信度
        var shapeMargin = 1.0
    }

    /// 选中的箭头
    private struct ArrowHit {
        var x0 = 0, y0 = 0, w = 0, h = 0
        var cx = 0.0, cy = 0.0
        var shapeMargin = 1.0
    }

    private struct Rect4 { let x: Int; let y: Int; let w: Int; let h: Int }

    /// ROI 内定位箭头：连通域 → 形状判据 → 选块（距**小地图真实圆心**最近）。
    ///
    /// - Parameters:
    ///   - centerX/centerY: 小地图真实圆心（整帧坐标，已按帧尺寸缩放）。
    ///     由调用方从 `minimapCenterIn720p` 换算 —— **不是 ROI 中心**（见其文档注释：
    ///     两者在 720p 基准下相差 38px，多候选时会选错块）。
    private func locateArrow(inROI roi: (Int, Int, Int, Int), frameW: Int,
                             centerX: Double, centerY: Double) -> ArrowHit? {
        let (rx0, ry0, rw, rh) = roi
        // 面积门限按帧宽二次缩放
        let k = pow(Double(frameW) / 640.0, 2)
        let areaMin = Self.areaRef640Min * k
        let areaMax = Self.areaRef640Max * k

        var best: (hit: ArrowHit, dist: Double)?
        // 复用一个栈式数组做 BFS
        var stack: [Int] = []
        stack.reserveCapacity(256)
        var pix: [Int] = []
        pix.reserveCapacity(256)

        for y in ry0..<(ry0 + rh) {
            let row = y * frameW
            for x in rx0..<(rx0 + rw) {
                let idx = row + x
                if !goldMaskBuf[idx] || visitedBuf[idx] { continue }
                // ── BFS 收集连通域 ──
                visitedBuf[idx] = true
                stack.removeAll(keepingCapacity: true)
                pix.removeAll(keepingCapacity: true)
                stack.append(idx)
                while let cur = stack.popLast() {
                    pix.append(cur)
                    let cy = cur / frameW
                    let cx = cur - cy * frameW
                    for dy in -1...1 {
                        let ny = cy + dy
                        if ny < ry0 || ny >= ry0 + rh { continue }
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = cx + dx
                            if nx < rx0 || nx >= rx0 + rw { continue }
                            let ni = ny * frameW + nx
                            if goldMaskBuf[ni] && !visitedBuf[ni] {
                                visitedBuf[ni] = true
                                stack.append(ni)
                            }
                        }
                    }
                }
                if pix.count < Self.componentMinArea { continue }

                // ── 特征 ──
                var fx0 = Int.max, fy0 = Int.max, fx1 = Int.min, fy1 = Int.min
                var sx = 0.0, sy = 0.0
                for p in pix {
                    let py = p / frameW
                    let px = p - py * frameW
                    if px < fx0 { fx0 = px }
                    if px > fx1 { fx1 = px }
                    if py < fy0 { fy0 = py }
                    if py > fy1 { fy1 = py }
                    sx += Double(px)
                    sy += Double(py)
                }
                let n = pix.count
                let w = fx1 - fx0 + 1
                let h = fy1 - fy0 + 1
                let cx = sx / Double(n)
                let cy = sy / Double(n)

                var f = BlobFeatures()
                f.area = n
                f.x0 = fx0; f.y0 = fy0; f.w = w; f.h = h
                f.cx = cx; f.cy = cy
                f.aspect = Double(max(w, h)) / Double(max(min(w, h), 1))
                f.fill = Double(n) / Double(max(w * h, 1))

                // 周长：每像素查 4 邻域是否同属本块
                var perim = 0
                for p in pix {
                    let py = p / frameW
                    let px = p - py * frameW
                    if py == 0 || !goldMaskBuf[p - frameW] { perim += 1 }
                    if py == frameH - 1 || !goldMaskBuf[p + frameW] { perim += 1 }
                    if px == 0 || !goldMaskBuf[p - 1] { perim += 1 }
                    if px == frameW - 1 || !goldMaskBuf[p + 1] { perim += 1 }
                }
                f.sharpen = Double(perim) / Double(n).squareRoot()

                // 边界像素半径变异系数（★主判据）
                // 边界 = 属于本块且 4 邻域不全属于本块
                var rSum = 0.0, rSum2 = 0.0
                var rCount = 0
                for p in pix {
                    let py = p / frameW
                    let px = p - py * frameW
                    let allIn = (py > 0 && goldMaskBuf[p - frameW])
                        && (py < frameH - 1 && goldMaskBuf[p + frameW])
                        && (px > 0 && goldMaskBuf[p - 1])
                        && (px < frameW - 1 && goldMaskBuf[p + 1])
                    if allIn { continue }
                    let rr = ((Double(px) - cx) * (Double(px) - cx)
                        + (Double(py) - cy) * (Double(py) - cy)).squareRoot()
                    rSum += rr
                    rSum2 += rr * rr
                    rCount += 1
                }
                if rCount > 0 {
                    let mean = rSum / Double(rCount)
                    let varr = max(0.0, rSum2 / Double(rCount) - mean * mean)
                    f.rcv = varr.squareRoot() / max(mean, 1e-6)
                } else {
                    f.rcv = 0
                }

                // 孔洞占比：bbox 内不被本块填充、且不与 bbox 外连通的部分
                f.holeFrac = holeFraction(pix: pix, bbox: (fx0, fy0, w, h), frameW: frameW)

                // ── 判据 ──
                guard let margin = judge(f, areaMin: areaMin, areaMax: areaMax) else { continue }
                f.shapeMargin = margin

                // ── 选块：距小地图圆心最近（曼哈顿），面积降序作次判据 ──
                let dist = abs(f.cx - centerX) + abs(f.cy - centerY)
                if let b = best {
                    if dist < b.dist - 1e-9 { 
                        best = (ArrowHit(x0: f.x0, y0: f.y0, w: f.w, h: f.h,
                                         cx: f.cx, cy: f.cy, shapeMargin: f.shapeMargin), dist)
                    } else if abs(dist - b.dist) <= 1e-9 && f.area > b.hit.w * b.hit.h {
                        best = (ArrowHit(x0: f.x0, y0: f.y0, w: f.w, h: f.h,
                                         cx: f.cx, cy: f.cy, shapeMargin: f.shapeMargin), dist)
                    }
                } else {
                    best = (ArrowHit(x0: f.x0, y0: f.y0, w: f.w, h: f.h,
                                     cx: f.cx, cy: f.cy, shapeMargin: f.shapeMargin), dist)
                }
            }
        }
        return best?.hit
    }

    /// 判据：通过返回形状余量 [0,1]，不通过返回 nil。
    ///
    /// 全部为比值（尺度无关）；只有「用哪一档阈值」由面积决定。
    private func judge(_ f: BlobFeatures, areaMin: Double, areaMax: Double) -> Double? {
        let area = Double(f.area)
        if area < areaMin || area > areaMax { return nil }

        let isSmall = area < Self.smallAreaSplit
        let aspectMax = isSmall ? Self.smallAspectMax : Self.normalAspectMax
        let fillMin = isSmall ? Self.smallFillMin : Self.normalFillMin
        let fillMax = isSmall ? Self.smallFillMax : Self.normalFillMax
        let sharpenMin = isSmall ? Self.smallSharpenMin : Self.normalSharpenMin
        let holeMax = isSmall ? Self.smallHoleFracMax : Self.normalHoleFracMax

        if f.aspect > aspectMax { return nil }
        if f.fill < fillMin || f.fill > fillMax { return nil }
        if f.holeFrac > holeMax { return nil }          // 圆环 / 齿轮
        if f.sharpen < sharpenMin { return nil }        // 圆钝轮廓 → 圆形图标
        if f.rcv < Self.rcvMin { return nil }           // ★半径均匀 → 圆

        // 形状余量：取各判据「距离阈值边界的相对余量」的最小值
        var margin = 1.0
        margin = min(margin, clamp01((aspectMax - f.aspect) / max(aspectMax, 1e-6) / 0.5))
        let fillRoom = min(f.fill - fillMin, fillMax - f.fill) / max(fillMax - fillMin, 1e-6)
        margin = min(margin, clamp01(fillRoom / 0.5))
        margin = min(margin, clamp01((f.rcv - Self.rcvMin) / max(Self.rcvMin, 1e-6) / 1.0))
        margin = min(margin, clamp01((sharpenMin > 0 ? (f.sharpen / sharpenMin) - 1 : 1) / 0.5))
        margin = min(margin, clamp01((holeMax > 0 ? 1 - f.holeFrac / holeMax : 1) / 0.5))
        return margin
    }

    private func clamp01(_ v: Double) -> Double { min(1.0, max(0.0, v)) }

    /// bbox 内被本块包围的背景占比（孔洞）。
    ///
    /// 做法：在 bbox 内从边界出发，对「非本块」像素做 BFS 标记为外部；
    /// 剩余未标记的非本块像素就是孔洞。用小缓冲（bbox 尺寸）避免整帧扫描。
    private func holeFraction(pix: [Int], bbox: (Int, Int, Int, Int), frameW: Int) -> Double {
        let (bx0, by0, bw, bh) = bbox
        let total = bw * bh
        // 只在 bbox 较大时才算（小目标上的 1~3px 锯齿孔会误杀）
        if total > 4096 { return 0 }
        var inBlob = [Bool](repeating: false, count: total)
        for p in pix {
            let py = p / frameW
            let px = p - py * frameW
            inBlob[(py - by0) * bw + (px - bx0)] = true
        }
        var outside = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        // 从 bbox 四条边灌入
        for x in 0..<bw {
            for yy in [0, bh - 1] {
                let i = yy * bw + x
                if !inBlob[i] && !outside[i] { outside[i] = true; stack.append(i) }
            }
        }
        for y in 0..<bh {
            for xx in [0, bw - 1] {
                let i = y * bw + xx
                if !inBlob[i] && !outside[i] { outside[i] = true; stack.append(i) }
            }
        }
        while let cur = stack.popLast() {
            let cy = cur / bw
            let cx = cur - cy * bw
            for (dy, dx) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let ny = cy + dy, nx = cx + dx
                if ny < 0 || ny >= bh || nx < 0 || nx >= bw { continue }
                let ni = ny * bw + nx
                if !inBlob[ni] && !outside[ni] { outside[ni] = true; stack.append(ni) }
            }
        }
        var hole = 0
        for i in 0..<total where !inBlob[i] && !outside[i] { hole += 1 }
        return Double(hole) / Double(max(total, 1))
    }

    // MARK: - 模型输入构造

    /// 以箭头质心为中心裁 `sideRatio × max(w,h)` 正方形 → 64×64 RGB → [1,3,64,64]
    /// 归一化到 [-1,1]（与训练一致：`x/255 → (x-0.5)/0.5`）。
    ///
    /// 【为什么不走 CGImage 切片】整帧缓冲在手，直接按行双线性采样更快且零分配。
    ///   窗口通常 ≤ 64px，采样点仅 64×64=4096 个，纯算术开销可忽略；
    ///   而构造子 CGImage（makeImage）每帧会分配一次，实测是这里的 10 倍开销。
    private func makeModelInput(arrow: ArrowHit) -> MLMultiArray? {
        let side = Self.modelSide
        let winSide = max(8, Int((Self.sideRatio * Double(max(arrow.w, arrow.h))).rounded()))

        var x0 = Int((arrow.cx - Double(winSide) / 2).rounded())
        var y0 = Int((arrow.cy - Double(winSide) / 2).rounded())
        // 越界则平移到画面内
        x0 = max(0, min(frameW - winSide, x0))
        y0 = max(0, min(frameH - winSide, y0))
        guard x0 >= 0, y0 >= 0, x0 + winSide <= frameW, y0 + winSide <= frameH else {
            return nil
        }

        // RGBA → CHW Float32，归一化 [-1,1]（双线性采样 + 归一化一趟完成）
        let input: MLMultiArray
        if let existing = inputArray,
           existing.shape.count == 4,
           existing.shape[0].intValue == 1,
           existing.shape[1].intValue == 3,
           existing.shape[2].intValue == side,
           existing.shape[3].intValue == side {
            input = existing
        } else if let created = try? MLMultiArray(
            shape: [1, 3, side as NSNumber, side as NSNumber],
            dataType: .float32) {
            inputArray = created
            input = created
        } else {
            return nil
        }

        // 【采样中心必须与 PIL 对齐】PIL `resize` 取 `(i+0.5)*srcW/dstW - 0.5` 作为目标
        //   像素中心的来源坐标。训练数据由 PIL 生成，故此处用同一约定；否则产生半像素
        //   偏移 —— 实测在箭头高对比边缘处差达 1.68、2.5% 像素显著错位，模型读数直接翻转
        //   （参考实现 0.1° vs 本侧 242°）。
        let scale = Double(winSide) / Double(side)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = side * side
        let maxX = winSide - 1
        let maxY = winSide - 1

        frameRGBA.withUnsafeBufferPointer { src in
            guard let sp = src.baseAddress else { return }
            for ty in 0..<side {
                let fyRaw = (Double(ty) + 0.5) * scale - 0.5
                let fy = min(Double(maxY), max(0.0, fyRaw))
                let y1 = Int(fy.rounded(.down))
                let y2 = min(maxY, y1 + 1)
                let wy = fy - Double(y1)
                let rowA = (y0 + y1) * frameW
                let rowB = (y0 + y2) * frameW
                for tx in 0..<side {
                    let fxRaw = (Double(tx) + 0.5) * scale - 0.5
                    let fx = min(Double(maxX), max(0.0, fxRaw))
                    let x1 = Int(fx.rounded(.down))
                    let x2 = min(maxX, x1 + 1)
                    let wx = fx - Double(x1)

                    let pA = (rowA + x0 + x1) * 4
                    let pB = (rowA + x0 + x2) * 4
                    let pC = (rowB + x0 + x1) * 4
                    let pD = (rowB + x0 + x2) * 4

                    let o = ty * side + tx
                    for ch in 0..<3 {
                        let top = Double(sp[pA + ch]) * (1 - wx) + Double(sp[pB + ch]) * wx
                        let bot = Double(sp[pC + ch]) * (1 - wx) + Double(sp[pD + ch]) * wx
                        let v = top * (1 - wy) + bot * wy       // 0..255
                        ptr[plane * ch + o] = Float32(v / 255.0 * 2 - 1)
                    }
                }
            }
        }
        return input
    }

    // MARK: - 自检（离线跑目录下的真实帧，输出逐帧结果供与参考实现对拍）

    /// 跑一个目录下的所有 PNG/JPG 帧，逐帧输出识别结果。
    ///
    /// 用途：与 Python 参考实现 `runtime_detector.py` 对拍，确认 Swift 移植无误。
    /// 输出为机器可解析的一行一帧，便于 diff。
    ///
    /// - Parameter directory: 帧目录
    /// - Returns: 人类可读汇总（同时把逐帧明细打到 stdout）
    func selfTestDirectory(_ directory: String) -> String {
        guard isAvailable else {
            return "❌ 模型不可用：\(unavailableReason ?? "未知原因")"
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            return "❌ 目录不可读：\(directory)"
        }
        let frames = names.filter {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "png" || e == "jpg" || e == "jpeg"
        }.sorted()
        guard !frames.isEmpty else { return "❌ 目录内无 PNG/JPG：\(directory)" }

        var hit = 0
        var miss = 0
        var confs: [Double] = []
        // ── 输出格式（2026-10-23 独立复核 §9 修复）──
        // 【原来两个毛病】
        //   ① stdout 最前面还有引擎启动日志（`[upscale] 引擎初始化…` /
        //      `[network] 定位引擎初始化完成`，由 DriveState.init 打印）——
        //      它们不是 CSV，朴素解析器会把它们当成坏行。
        //   ② 设 `AURORA_PTR_DUMP` 时只打 4 列（无 bbox），不设时 5 列 →
        //      同一份格式两种列数，`DictReader` 读出来字段数不一致。
        // 【现在】先打一条 `#` 引导行说明格式，再打表头；**所有数据行恒为 5 列**。
        //   消费方：`grep -v '^#'` 之后就是标准 CSV。
        print("# AURORA_PTR_CSV v1 — 以下为 CSV（列：frame,hit,heading,confidence,bbox）；跳过所有以 # 开头的行")
        print("frame,hit,heading,confidence,bbox")
        // 无论是否设 AURORA_PTR_DUMP，都走同一条 read 入口 → 列数恒一致。
        let dumpPath = ProcessInfo.processInfo.environment["AURORA_PTR_DUMP"]
        for name in frames {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                print("\(name),load_fail,,,")
                miss += 1
                continue
            }
            if let h = read(frame: img, dumpInputTo: dumpPath) {
                hit += 1
                confs.append(h.confidence)
                let b = h.bboxInFrame
                print(String(format: "%@,1,%.2f,%.4f,%.0f;%.0f;%.0f;%.0f",
                             name, h.headingDeg, h.confidence,
                             b.minX, b.minY, b.width, b.height))
            } else {
                miss += 1
                print("\(name),0,,,")
            }
        }
        // ── 分段耗时汇总（仅 AURORA_PERF=1 时有采样）──
        //
        // 【为什么必须打印】这是唯一能稳定复现「真实运行时模型路径耗时」的入口：
        //   它走生产 read() 全链路（含 CoreML 实推理），不是 Python 复刻。
        //   缺这个数，「用规则替代模型能否压到 3ms」就没有比较基准。
        // 【为什么分段】drawMask / locate 是规则方案**同样要付**的公共成本，
        //   只有 infer 是真能省掉的。只报总量会被误读成「换规则能省这么多」。
        // 【为什么再拆 blit / mask】实测 drawMask 占了总耗时 99%，必须拆清楚是
        //   「整帧 CGContext 绘制」还是「整帧逐像素 HSV 掩膜」吃掉的 —— 两者对策完全不同。
        // 【口径】命中帧才走完整链路；未命中帧只计 total，故各分段 n 可能小于命中数。
        //   pointer.drawMask 覆盖 prepareFrameBuffer 全程，其中含 blit + mask；
        //   但**不要指望两列相加等于第一列**：drawMask 还含缓冲容量检查与 t0 之前的一小段，
        //   且这里每列都是**分位数**——分位数不可相加（实测 p50：13.802 vs 12.146+1.665=13.811）。
        // ⚠️ 【自检里的 blit 不代表生产】自检每帧都是**新从磁盘读的 PNG**，CGImage 的
        //   惰性解码会落进首次 draw → 每帧都按「冷」计（1080p p50 27ms）。
        //   实测同一 CGImage 复绘（暖）只需 0.225ms，而生产喂的是抓屏已解码帧。
        //   **结论：blit 这一列的绝对值不可用于生产决策，只有 mask/locate/crop/infer 可。**
        let pointerChannels = ["pointer.total", "pointer.drawMask",
                               "pointer.blit", "pointer.mask",
                               "pointer.locate", "pointer.crop", "pointer.infer"]
        print("# pointer 分段耗时（ms，n=采样数；未设 AURORA_PERF=1 时全为 n=0）")
        for channel in pointerChannels {
            print(channel.padding(toLength: 18, withPad: " ", startingAt: 0)
                  + PerfBus.shared.stats(channel).summary)
        }
        let rate = Double(hit) / Double(frames.count) * 100
        let confStr = confs.isEmpty ? "n/a"
            : String(format: "p50=%.3f min=%.3f", confs.sorted()[confs.count / 2], confs.min()!)
        return String(format: "共 %d 帧：命中 %d，未检出 %d（%.1f%%）  置信度 %@",
                      frames.count, hit, miss, rate, confStr)
    }

    // MARK: - 预热

    /// 预热一次，让首次真实调用稳定在亚毫秒级。
    private func warmUp() {
        guard let model else { return }
        let side = Self.modelSide
        guard let array = try? MLMultiArray(
            shape: [1, 3, side as NSNumber, side as NSNumber],
            dataType: .float32) else { return }
        // 全零输入即可（只为触发图加载与算子分发）
        if let provider = try? MLDictionaryFeatureProvider(
            dictionary: [Self.inputName: MLFeatureValue(multiArray: array)]) {
            _ = try? model.prediction(from: provider)
        }
    }
}
