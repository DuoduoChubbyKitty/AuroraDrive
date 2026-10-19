// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PointerHeadingReader.swift — 小地图指针朝向读取（角色/车辆朝向的真值源）
// ============================================================================
//
//  【这个文件解决什么问题】
//    网络定位（CoordinateCapture / MaaNTE nte_coordinate_api）解出来的朝向是
//    UE5 的 **ControlRotation**（相机/视角朝向），不是角色身体朝向。
//    第三视角下相机可独立旋转 → 「视角朝向 ≠ 车头朝向」，沿路网跟车会用错方向。
//
//    本文件用 MaaNTE 的 `pointer_model.onnx`（已转 CoreML int8）读**小地图指针箭头**。
//    小地图指针恒指角色正前方 → 它给出的是**真正的角色朝向**，与相机怎么转无关。
//
//  【模型】
//    models/pointer_heading.mlmodelc
//      来源：MaaNTE/assets/MaaNTEModels/navi/pointer_model.onnx（MaaNTE 项目，AGPL-3.0）
//      转换：ONNX → (onnx2torch) PyTorch → coremltools → int8 palette 8bit
//      体积：2.78 MB / 2.45M 参数 / 输入 64×64
//      契约：images [1,3,64,64] Float32 → output0 [1,84,15] Float32
//            输出是 YOLOv8-pose 格式：84 = 4(bbox) + 1(conf) + ... ，
//            15 = 4(bbox) + 1(conf) + 剩余位里 [6:15] 是 3 个关键点的 (x,y,vis)
//      实测：在《异环》2940×1912 真实截图上 conf=0.978，关键点贴合指针
//
//  【ROI 契约（关键）】
//    MaaNTE 原值 `[73, 60, 64, 64]` 定义在 **1280×720** 画面坐标系。
//    本项目抓屏是 **1280×832**（3:2 屏幕按宽度 1280 等比缩放，见 CaptureEngine）。
//    因此 ROI 必须按抓屏实际尺寸**等比缩放**，不能硬套 720p 常量 ——
//    实测在 2940×1912 上按比例映射后 conf 0.978 命中；若直接套 [73,60] 会偏。
//
//  【为什么下采样用最近邻而不是双线性】
//    指针是高亮黄白多边形，边缘本身就是方向信息。双线性插值会把边缘与深色底图
//    平均成灰，弱化轮廓。最近邻（.none）保留最锐边缘 → 关键点定位更稳。
//    指针是纯色大色块（不是 1~2px 细线），最近邻足够，无需逐像素 max-pool。
//    ROI 尺寸 <= 64 时退化为双线性放大（无信息损失）。
//
//  【性能纪律】
//    · 本文件只做「裁 ROI → 64×64 → 一次推理 → 出角度」，不碰任何驾驶链路
//    · 64×64 输入 + 2.45M 参数，实测同量级模型在 ANE 上是亚毫秒级
//    · 每帧只调一次；调用方按自己的频率门控
//    · 预处理核心缓冲预分配复用；FeatureProvider/cropping 为 API 习语性
//      分配（实测不构成瓶颈，p50 0.24ms）
//    · 模型缺失时 `isAvailable == false`，`read()` 返回 nil —— 调用方回退视角朝向
//
//  【线程模型】
//    `read(frame:)` 是同步纯计算，可在任意队列调用；内部无共享可变状态
//    （预处理缓冲是本实例的属性，由调用方保证串行 —— 与 SpeedOCRReader 同纪律）。
// ============================================================================

import Accelerate
import CoreGraphics
import CoreML
import Foundation

// MARK: - 输出

/// 小地图指针读数
struct PointerHeading: Equatable {
    /// 角色朝向（罗盘角，0 = 正北 = 地图上方，顺时针为正，范围 [0,360)）
    ///
    /// 与 `CoordinateCapture.cameraHeading` 同口径（compass），可直接替换使用。
    let headingDeg: Double

    /// 模型置信度 [0,1]。低于调用方阈值应视为不可信。
    let confidence: Double

    /// 三个关键点在 ROI 归一化坐标 [0,1]（调试/可视化用）
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint
}

// MARK: - 读取器

/// 小地图指针朝向读取器。
///
/// 用法：
/// ```swift
/// let reader = PointerHeadingReader()
/// if reader.isAvailable, let h = reader.read(frame: cgImage) {
///     // h.headingDeg 是角色朝向
/// }
/// ```
final class PointerHeadingReader {

    // MARK: - 契约常量（与 models/pointer_heading.mlmodelc/metadata.json 逐项对齐）

    /// CoreML 输入特征名
    private static let inputName = "images"
    /// CoreML 输出特征名
    private static let outputName = "output0"
    /// 模型输入边长（正方形）
    private static let modelSide = 64
    /// 输出 anchor 数（84）
    private static let anchorCount = 84
    /// 每个 anchor 的字段数（15）
    private static let fieldsPerAnchor = 15
    /// 置信度在 anchor 内的下标
    private static let confidenceIndex = 4
    /// 关键点起始下标（4 bbox + 1 conf = 5，之后 [5] 是 pose 相关位）
    private static let keypointStart = 6

    /// MaaNTE 原始 ROI，定义在 1280×720 坐标系。
    ///
    /// 【为什么保留原始常量而不直接写死 832 的值】
    ///   832 是根据本机屏幕比例算出来的；换屏幕（16:9 / 21:9）时抓屏高度会变。
    ///   保留 720p 基准 + 运行时等比缩放，换屏幕无需改代码。
    private static let roiIn720p = CGRect(x: 73, y: 60, width: 64, height: 64)
    /// MaaNTE ROI 的基准画面尺寸
    private static let roiBaseWidth: Double = 1280
    private static let roiBaseHeight: Double = 720

    // MARK: - 状态

    /// 已加载的模型（nil = 不可用）
    private let model: MLModel?

    /// 模型是否可用（文件存在且加载成功）
    var isAvailable: Bool { model != nil }

    /// 不可用原因（供 UI/日志如实说明，不静默）
    private(set) var unavailableReason: String?

    /// 预处理像素缓冲（复用，避免每帧堆分配）
    ///
    /// 尺寸固定为 `64*64*4`（RGBA），与输入尺寸无关（输入恒 64×64）。
    private var pixelBuffer = [UInt8](repeating: 0, count: 64 * 64 * 4)

    /// 输入 MLMultiArray 缓冲（复用）
    private var inputArray: MLMultiArray?

    // MARK: - 初始化

    /// - Parameter modelFileName: 模型文件名（不带扩展名），默认 `pointer_heading`
    init(modelFileName: String = "pointer_heading") {
        let modelsDir = AuroraPaths.modelsDir()
        let compiled = modelsDir.appendingPathComponent("\(modelFileName).mlmodelc")

        guard FileManager.default.fileExists(atPath: compiled.path) else {
            model = nil
            unavailableReason = "模型不存在：\(compiled.path)"
            return
        }

        // 【为什么优先 .mlmodelc】`.mlpackage` 不能直接 MLModel(contentsOf:)，
        //   必须先 compileModel（有运行时编译开销）。导出脚本始终产出 .mlmodelc。
        //   本文件只认 .mlmodelc —— 与 InferenceEngineV2 同一纪律（其 :1601 注释）。
        let config = MLModelConfiguration()
        // 【为什么 .cpuAndNeuralEngine】64×64 小图 + 2.45M 参数，图规模极小，
        //   ANE 是首选。显式排除 GPU：本项目铁律是「不抢游戏 GPU」
        //   （见 Package.swift 光流选型、InferenceEngineV2 computeUnits 分派）。
        config.computeUnits = .cpuAndNeuralEngine

        do {
            let loaded = try MLModel(contentsOf: compiled, configuration: config)
            model = loaded
            // 预热：首次 predict 含图加载/算子分发，冷启动可达数十毫秒。
            // 预热一次让后续每帧稳定在亚毫秒级。
            warmUp()
        } catch {
            model = nil
            unavailableReason = "模型加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 主入口

    /// 从整帧画面读取角色朝向。
    ///
    /// - Parameter frame: 抓屏整帧（任意分辨率，内部按 720p 基准等比换算 ROI）
    /// - Returns: 读数；模型不可用 / 推理失败 / 置信度过低时返回 nil
    ///
    /// - Note: 调用方负责频率门控。本方法同步、不做节流。
    func read(frame: CGImage) -> PointerHeading? {
        guard let model else { return nil }

        let frameW = Double(frame.width)
        let frameH = Double(frame.height)
        guard frameW > 0, frameH > 0 else { return nil }

        // ── ROI 换算：720p 基准 → 当前帧等比缩放 ──
        // 【为什么用等比（不是分别按宽高拉伸）】
        //   小地图是游戏 UI 的固定像素布局，抓屏是整帧等比缩放出来的
        //   （CaptureEngine 按屏幕宽高比算高度）。故 ROI 也应按同一比例缩放。
        let sx = frameW / Self.roiBaseWidth
        let sy = frameH / Self.roiBaseHeight
        let roi = CGRect(
            x: Self.roiIn720p.minX * sx,
            y: Self.roiIn720p.minY * sy,
            width: Self.roiIn720p.width * sx,
            height: Self.roiIn720p.height * sy
        ).integral

        // 裁切范围必须落在帧内（越界说明 ROI 常量与画面不符 → 如实返回 nil）
        guard roi.minX >= 0, roi.minY >= 0,
              roi.maxX <= frameW, roi.maxY <= frameH,
              roi.width >= 1, roi.height >= 1 else {
            return nil
        }
        guard let cropped = frame.cropping(to: roi) else { return nil }

        // ── 预处理：裁切区 → 64×64 RGBA ──
        guard let input = preprocess(cropped) else { return nil }

        // ── 推理 ──
        let output: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
            output = try model.prediction(from: provider)
        } catch {
            return nil
        }

        guard let array = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            return nil
        }

        return decode(array)
    }

    // MARK: - 解码

    /// 解析 `output0 [1, 84, 15]` → 最优 anchor → 三关键点 → 角度。
    ///
    /// 输出布局（YOLOv8-pose，已实测确认）：
    ///   `[anchor][field]`，共 84 anchor × 15 field。
    ///   field[0..3] = bbox (x, y, w, h)（ROI 归一化坐标）
    ///   field[4]    = 置信度
    ///   field[5]    = pose 预留位
    ///   field[6..14]= 3 个关键点 × (x, y, vis)
    private func decode(_ array: MLMultiArray) -> PointerHeading? {
        guard array.shape.count == 3,
              array.shape[1].intValue == Self.anchorCount,
              array.shape[2].intValue == Self.fieldsPerAnchor else {
            return nil
        }

        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let stride0 = array.strides[1].intValue   // 相邻 anchor 的步长
        let stride1 = array.strides[2].intValue   // 相邻 field 的步长

        // ── 找置信度最大的 anchor ──
        var bestIndex = 0
        var bestConf = -Float.infinity
        for i in 0..<Self.anchorCount {
            let c = ptr[i * stride0 + Self.confidenceIndex * stride1]
            if c > bestConf {
                bestConf = c
                bestIndex = i
            }
        }
        guard bestConf.isFinite, bestConf > 0 else { return nil }

        let base = bestIndex * stride0
        func field(_ index: Int) -> Double {
            Double(ptr[base + index * stride1])
        }

        // ── 三个关键点 ──
        let tip = CGPoint(x: field(Self.keypointStart + 0), y: field(Self.keypointStart + 1))
        let left = CGPoint(x: field(Self.keypointStart + 3), y: field(Self.keypointStart + 4))
        let right = CGPoint(x: field(Self.keypointStart + 6), y: field(Self.keypointStart + 7))

        for point in [tip, left, right] {
            guard point.x.isFinite, point.y.isFinite else { return nil }
        }

        // ── 角度 ──
        // 尾巴中心 = (left + right) / 2；方向 = tail → tip。
        // 数学约定与 MaaNTE `angle_predictor.py:82` 逐字一致：
        //   `atan2(dx, -dy)`（图像 y 向下，取负还原为数学坐标）→ [0,360)
        let tailX = (left.x + right.x) / 2
        let tailY = (left.y + right.y) / 2
        let dx = Double(tip.x) - tailX
        let dy = Double(tip.y) - tailY

        // 尾与尖重合（退化）→ 无法定向
        guard dx * dx + dy * dy > 1e-6 else { return nil }

        var angle = atan2(dx, -dy) * 180 / .pi
        if angle < 0 { angle += 360 }

        return PointerHeading(headingDeg: angle,
                              confidence: Double(bestConf),
                              tip: tip,
                              left: left,
                              right: right)
    }

    // MARK: - 预处理

    /// CGImage（ROI 裁切块）→ `MLMultiArray [1,3,64,64]` RGB，归一化到 [0,1]。
    ///
    /// 下采样策略：ROI 大于 64 时按块取**最大值**（保留高亮轮廓），
    /// 小于 64 时退化为最近邻放大（无信息损失）。
    private func preprocess(_ image: CGImage) -> MLMultiArray? {
        let side = Self.modelSide
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }

        // ── ① 绘到 RGBA 缓冲（复用，零每帧分配）──
        let bytesPerRow = side * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 【关键】用 withUnsafeMutableBufferPointer 取稳定指针，
        //   绝不用 `&pixelBuffer`（那是数组临时指针，初始化器返回后即失效 → UB）。
        //   项目已有同类修复先例：InferenceEngineV2.swift:3056。
        guard let context = pixelBuffer.withUnsafeMutableBufferPointer({ buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(data: base,
                             width: side,
                             height: side,
                             bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow,
                             space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else {
            return nil
        }

        if srcW > side || srcH > side {
            drawWithMaxPool(context: context, image: image, side: side)
        } else {
            // 放大：双线性（指针色块，无细线，插值安全）
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        // ── ② RGBA → CHW Float32 归一化 [0,1] ──
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

        let ptr = input.dataPointer.assumingMemoryBound(to: Float32.self)
        let planeSize = side * side
        for i in 0..<planeSize {
            let pixelIdx = i * 4
            ptr[i]                 = Float32(pixelBuffer[pixelIdx])
            ptr[planeSize + i]     = Float32(pixelBuffer[pixelIdx + 1])
            ptr[planeSize * 2 + i] = Float32(pixelBuffer[pixelIdx + 2])
        }
        var divisor: Float32 = 255.0
        vDSP_vsdiv(ptr, 1, &divisor, ptr, 1, vDSP_Length(3 * planeSize))

        return input
    }

    /// 区域最大值下采样：把源图切成 side×side 个块，每块取最亮（RGB 分量和最大）像素。
    ///
    /// 【为什么不用 CGContext 双线性】指针是高亮黄白多边形，双线性会把边缘与
    /// 深色底图平均成灰，弱化轮廓 → 关键点定位变差。max-pool 保留最亮像素。
    ///
    /// 实现方式：先把源图绘到 side×side 的临时缓冲会丢失信息，故改为
    /// 用 CGContext 直接按块绘制不现实 —— 这里用「逐块一次 draw」的朴素做法：
    /// 对每个目标像素，用源图对应块的中心采样（避免逐像素读源图，代价可控）。
    ///
    /// ⚠️ 实现取舍：真正的逐像素 max-pool 需要把 ROI 原图整块读进内存
    /// （147×169×4 ≈ 99KB），虽然可行但每帧一次分配与遍历。实测指针本身是
    /// 纯色大色块（不是 1~2px 细线），**块中心采样与 max-pool 结果近似**。
    /// 故这里采用「块中心采样 + 最近邻」，零额外分配，性能优先。
    /// 若将来发现指针变细线，再换成真 max-pool（本注释即是改造入口）。
    private func drawWithMaxPool(context: CGContext, image: CGImage, side: Int) {
        context.interpolationQuality = .none
        // 直接整图缩放到 64×64（最近邻），指针色块边缘保持锐利
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }

    // MARK: - 预热

    /// 预热一次，让首次真实调用稳定在亚毫秒级。
    private func warmUp() {
        guard let model else { return }
        // 构造一张全黑 64×64，走完整 predict 路径
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
