// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  InferenceEngine.swift — CoreML E2E 推理引擎
//
//  职责：加载 m9_mono.mlpackage，把截屏画面 + 车辆状态 → steer/throttle/brake
//
//  模型接口（来自 tools/export_game_assist_coreml.py 与 src/model.py）：
//    输入 image:        [1, 3, 180, 320]  Float32, CHW, 归一化 [0,1]
//    输入 vehicle_state: [1, 6]            Float32
//         6 维 = [speed, rpm, gear, speed_norm, gear_norm, reserved]
//    输出 steer:    [1] tanh   ∈ [-1, 1]
//    输出 throttle: [1] sigmoid ∈ [0, 1]
//    输出 brake:    [1] sigmoid ∈ [0, 1]
//
//  设计要点：
//    1) 异步推理 —— 后台队列跑，不阻塞主线程 tick
//    2) 频率解耦 —— tick 30Hz 调用，推理约 24Hz，结果缓存供 tick 读最新值
//    3) 线程安全 —— 预处理/推理用 nonisolated 静态函数，无 self 捕获，
//       避免跨 actor 边界；MLMultiArray/MLModel 非 Sendable 但单线程访问安全
//    4) 车辆状态 —— 游戏状态读取未接入前，speed 用 DriveState.speed 估算，
//       rpm/gear 用启发式占位（rpm 随速度、gear 随速度分档）
// ============================================================================
import Accelerate
import AppKit
@preconcurrency import CoreML
import Foundation
import Observation

// MARK: - 推理结果

/// 单次推理输出（与 ControlCommand 兼容）
struct InferenceResult: Sendable {
    let steer: Double
    let throttle: Double
    let brake: Double
    /// 推理耗时（毫秒），用于性能监控
    let latencyMs: Double
}

// MARK: - 推理引擎

/// CoreML E2E 推理引擎
/// - @Observable：UI 可观察推理状态、最新结果、推理耗时
/// - @MainActor：所有可变状态主线程访问
/// - 推理流程：infer() 主线程入口 → 后台队列跑 nonisolated 静态函数 → 主线程写结果
@Observable
@MainActor
final class InferenceEngine {

    // MARK: - 模型参数（与训练导出一致）

    /// 输入图像尺寸 H×W（模型训练时的分辨率）
    /// nonisolated：warmUp 的 Sendable 后台闭包要读，且是编译期常量、无 actor 依赖
    nonisolated static let inputHeight = 180
    nonisolated static let inputWidth = 320

    /// vehicle_state 维度（nonisolated：编译期常量，无 actor 依赖）
    private nonisolated static let stateDim = 6
    /// NSNumber 单例：buildVehicleState 每帧分配 3 个零值和 1 个一值，复用避免 heap 分配
    private nonisolated static let nsZero = NSNumber(value: 0.0)
    private nonisolated static let nsOne = NSNumber(value: 1.0)

    // MARK: - 状态

    /// 是否已加载模型（启动时 lazy 加载）
    private(set) var isLoaded = false

    /// 是否正在推理中（防止重叠推理）
    private(set) var isInferencing = false

    /// 最新推理结果（tick 读取此值）
    private(set) var lastResult: InferenceResult?

    /// 最近一次成功推理的时间戳（判结果新鲜度：链路是否真的活着）
    private(set) var lastResultTime: Date?

    /// 累计推理次数（性能监控）
    private(set) var inferenceCount: Int = 0

    /// 加载/推理错误信息（UI 展示用）
    private(set) var errorMessage: String?

    /// P0-4 修复：上次加载尝试时间戳（失败冷却用）
    @ObservationIgnored
    private var lastLoadAttempt: Date = .distantPast

    /// 加载失败冷却时长（秒）
    private let loadRetryCooldown: TimeInterval = 5.0

    /// P1 修复：generation 计数，reloadModel()/reset() 时递增；
    /// 在途推理完成后比对，不匹配则丢弃过期结果，防 reset/reload 后旧在途结果写回 lastResult。
    @ObservationIgnored
    private var generation = 0

    // MARK: - 内部资源

    /// CoreML 模型实例
    /// - @ObservationIgnored：不参与 SwiftUI 观察（UI 不需要看 model 引用）
    /// - nonisolated(unsafe)：MLModel.prediction 内部线程安全，可跨队列调用
    @ObservationIgnored
    private nonisolated(unsafe) var model: MLModel?

    /// 后台推理队列（串行，保证推理不重叠）
    @ObservationIgnored
    private let inferenceQueue = DispatchQueue(label: "com.aurora.inference",
                                               qos: .userInitiated)

    /// P1 修复：可复用的推理输入缓冲（image 1×3×180×320 ≈691KB + state 1×6），
    /// 尺寸不变时复用，避免每帧新建 MLMultiArray。nonisolated(unsafe)：
    /// 只在串行 inferenceQueue 上创建与读写，isInferencing 防重叠保证无并发访问。
    @ObservationIgnored
    private nonisolated(unsafe) var reusableImageBuffer: MLMultiArray?
    @ObservationIgnored
    private nonisolated(unsafe) var reusableStateBuffer: MLMultiArray?

    /// 本引擎加载的模型文件名（不带扩展名）
    private let modelFileName: String

    /// 初始化
    /// - Parameter modelFileName: 模型文件名（默认 "m9_mono" 端到端主驾；
    ///   "game_assist_control" 为第二套驾驶模型，YOLO接管档的司机）
    init(modelFileName: String = "m9_mono") {
        self.modelFileName = modelFileName
    }

    /// 模型文件定位（用 #filePath 定位项目根，models 为同级子目录）
    /// 优先加载训练产出的编译模型 <name>.mlmodelc（.mlmodelc 为 coremlcompiler 编译产物），
    /// 回退到历史未编译的 <name>.mlpackage，保证「训练完一键热替换」生效。
    private var modelURL: URL {
        let modelsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("models")
        let compiled = modelsDir.appendingPathComponent("\(modelFileName).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) {
            return compiled
        }
        return modelsDir.appendingPathComponent("\(modelFileName).mlpackage")
    }

    // MARK: - 模型加载

    /// 加载 CoreML 模型
    /// - 首次推理前调用，lazy 加载避免启动卡顿
    /// - 加载失败 errorMessage 记录原因
    func loadIfNeeded() {
        guard !isLoaded else { return }
        // P0-4 修复：失败后冷却期内不再重试，避免主线程同步 MLModel() 30Hz 重试风暴
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all   // 自动选 ANE/GPU/CPU，优先 ANE
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            model = mlModel
            isLoaded = true
            errorMessage = nil
            // 环3：加载成功后后台跑一次 dummy prediction 预热 ANE（不阻塞主线程）
            Self.warmUp(model: mlModel, label: modelFileName, queue: inferenceQueue)
        } catch {
            errorMessage = "模型加载失败: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    /// 模型预热（环3）：后台队列跑一次 dummy prediction，把 ANE 计算图编译/内存分配
    /// 提前做完，避免首帧真实推理出现冷启动尖峰。全零输入即可（数据内容不影响预热）。
    private nonisolated static func warmUp(model: MLModel,
                                           label: String,
                                           queue: DispatchQueue) {
        queue.async {
            let h = inputHeight
            let w = inputWidth
            guard let image = try? MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)],
                                                dataType: .float32),
                  let state = try? MLMultiArray(shape: [1, NSNumber(value: stateDim)],
                                                dataType: .float32),
                  let provider = try? MLDictionaryFeatureProvider(dictionary: [
                      "image": MLFeatureValue(multiArray: image),
                      "vehicle_state": MLFeatureValue(multiArray: state),
                  ]) else {
                print("[warmup] \(label): 预热输入构造失败")
                return
            }
            let start = Date()
            do {
                _ = try model.prediction(from: provider)
                let ms = Date().timeIntervalSince(start) * 1000
                print("[warmup] \(label) 预热完成: \(String(format: "%.1f", ms))ms  computeUnits=all(自动选 ANE/GPU/CPU)")
            } catch {
                print("[warmup] \(label) 预热失败: \(error.localizedDescription)")
            }
        }
    }

    /// 训练完成后热替换模型
    /// 置空当前模型引用与加载标记，下一次 infer() 会经 loadIfNeeded 自动重读 modelURL
    /// （优先指向新训练的 m9_mono.mlmodelc），实现「点完训练即用新模型」。
    func reloadModel() {
        generation += 1      // 在途推理结果过期
        model = nil
        isLoaded = false
        isInferencing = false
        errorMessage = nil
    }

    // MARK: - 推理入口（主线程）

    /// 异步推理
    /// - Parameters:
    ///   - image: 截屏画面 CGImage（CaptureEngine 直传，内部缩放到 180×320）
    ///   - speedKmh: 当前车速 km/h（用于构造 vehicle_state）
    ///   - speedLimitKmh: 当前限速 km/h（vehicle_state 的 speed_limit_norm 用）
    /// - 注意：在后台队列执行，结果写 lastResult（@MainActor 保证主线程）
    func infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double) {
        guard isLoaded, let modelRef = model else {
            loadIfNeeded()
            return
        }
        guard !isInferencing else { return }   // 防重叠：上一帧还没跑完就跳过

        isInferencing = true

        // CGImage 不可变，可安全跨线程（环2 由 CaptureEngine 直传，省 NSImage→CGImage 转换）
        let h = Self.inputHeight
        let w = Self.inputWidth
        let gen = generation
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()

            // ── 1. 画面预处理 + 车辆状态构造（nonisolated，无 actor 依赖）──
            // P1 修复：复用输入缓冲，尺寸不变时不新建 MLMultiArray（image ≈691KB）。
            if self.reusableImageBuffer == nil {
                self.reusableImageBuffer = try? MLMultiArray(
                    shape: [1, 3, NSNumber(value: h), NSNumber(value: w)],
                    dataType: .float32)
            }
            if self.reusableStateBuffer == nil {
                self.reusableStateBuffer = try? MLMultiArray(
                    shape: [1, NSNumber(value: Self.stateDim)],
                    dataType: .float32)
            }
            guard let imageBuffer = Self.preprocessImage(image, height: h, width: w,
                                                          into: self.reusableImageBuffer),
                  let stateBuffer = Self.buildVehicleState(speedKmh: speedKmh,
                                                           speedLimitKmh: speedLimitKmh,
                                                           into: self.reusableStateBuffer) else {
                Task { @MainActor in self.finishInference(gen, nil, error: "预处理失败") }
                return
            }

            // ── 2. 构造 CoreML 输入 ──
            // MLFeatureValue(multiArray:) 是 non-throwing 初始化器，直接构造即可
            let imageFeature = MLFeatureValue(multiArray: imageBuffer)
            let stateFeature = MLFeatureValue(multiArray: stateBuffer)

            let inputDict: [String: Any] = [
                "image": imageFeature,
                "vehicle_state": stateFeature,
            ]

            // ── 3. 同步推理（已在后台队列，不阻塞主线程）──
            // MLModel.prediction 内部线程安全，可跨队列调用
            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: inputDict)
                let output = try modelRef.prediction(from: provider)

                // ── 4. 解析输出 ──
                // 注意：CoreML 输出是 MLMultiArray(shape [1,1])，必须用
                // multiArrayValue[[0,0]].doubleValue 读取。直接用
                // featureValue(for:)?.doubleValue 对 multiArray 类型会返回 0，
                // 导致 e2eCommand 恒为 idle（端到端主驾完全不决策的元凶）。
                func readScalar(_ name: String) -> Double {
                    guard let fv = output.featureValue(for: name) else { return 0 }
                    if let mv = fv.multiArrayValue {
                        return mv[[0, 0]].doubleValue
                    }
                    return fv.doubleValue
                }
                let steer = readScalar("steer")
                let throttle = readScalar("throttle")
                let brake = readScalar("brake")
                let latency = Date().timeIntervalSince(start) * 1000

                let result = InferenceResult(steer: steer,
                                             throttle: throttle,
                                             brake: brake,
                                             latencyMs: latency)
                Task { @MainActor in self.finishInference(gen, result, error: nil) }
            } catch {
                Task { @MainActor in self.finishInference(gen, nil, error: "推理失败: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 推理完成回调（主线程）

    private func finishInference(_ gen: Int, _ result: InferenceResult?, error: String?) {
        guard gen == generation else { return }   // reset()/reloadModel() 后在途结果过期，丢弃
        isInferencing = false
        if let result = result {
            lastResult = result
            lastResultTime = Date()
            inferenceCount += 1
        }
        if let error = error {
            errorMessage = error
        }
    }

    // MARK: - 车辆状态构造（nonisolated，纯函数）

    /// 构造 vehicle_state 6 维向量
    /// 与训练契约一致（src/mono_dataset.py v2_new 格式）：
    ///   [speed_norm, curvature*5, sin(heading), cos(heading), speed_limit_norm, 0]
    /// 之前喂的是启发式 [speed原始值, rpm(800~8000), gear(1~6), ...]，
    /// 前三维超出训练分布 60~8000 倍 → 模型收到垃圾状态 → 恒输出 steer=-1/throttle=1
    /// （已用真实帧 + 训练权重逐组验证：正确契约 steer≈-0.04/throttle≈0.99）。
    /// 游戏遥测未接入前：
    ///   speed_norm     = speed/120（模拟车速）
    ///   curvature      = 0（无遥测，取训练分布内零值）
    ///   sin/cos(heading)= 0/1（无遥测，等价 heading=0）
    ///   speed_limit_norm = speedLimit/120
    ///   reserved       = 0
    private nonisolated static func buildVehicleState(speedKmh: Double,
                                                     speedLimitKmh: Double,
                                                     into reusable: MLMultiArray?) -> MLMultiArray? {
        let speedNorm = max(0.0, min(1.0, speedKmh / 120.0))
        let limitNorm = max(0.0, min(1.0, speedLimitKmh / 120.0))

        // P1 修复：复用传入的 state 缓冲（尺寸 1×6 不变），避免每帧新建 MLMultiArray。
        let arr: MLMultiArray
        if let reusable = reusable,
           reusable.shape.count == 2,
           reusable.shape[0].intValue == 1,
           reusable.shape[1].intValue == stateDim {
            arr = reusable
        } else if let created = try? MLMultiArray(shape: [1, NSNumber(value: stateDim)],
                                                  dataType: .float32) {
            arr = created
        } else {
            return nil
        }
        arr[0] = NSNumber(value: speedNorm)          // speed_norm [0,1]
        arr[1] = Self.nsZero                         // curvature*5（无遥测→0）
        arr[2] = Self.nsZero                         // sin(heading)（无遥测→0）
        arr[3] = Self.nsOne                          // cos(heading)（无遥测→1）
        arr[4] = NSNumber(value: limitNorm)          // speed_limit_norm [0,1]
        arr[5] = Self.nsZero                         // reserved
        return arr
    }

    // MARK: - 画面预处理（nonisolated，纯函数）

    /// CGImage → MLMultiArray [1, 3, H, W] Float32 CHW 归一化 [0,1]
    /// 流程：缩放绘制 → 读 RGBA 像素 → CHW 重排 + 归一化
    /// nonisolated static：无 self 捕获，无 actor 依赖，可安全在后台队列执行
    private nonisolated static func preprocessImage(_ cgImage: CGImage,
                                                    height: Int, width: Int,
                                                    into reusable: MLMultiArray?) -> MLMultiArray? {
        let pixelsW = width
        let pixelsH = height
        let bytesPerRow = pixelsW * 4
        var pixelData = [UInt8](repeating: 0, count: pixelsW * pixelsH * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: pixelsW,
            height: pixelsH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelsW, height: pixelsH))

        // 构造 MLMultiArray [1, 3, H, W] Float32
        // P1 修复：复用传入的 image 缓冲（尺寸 1×3×180×320 不变），避免每帧新建 ≈691KB。
        let output: MLMultiArray
        if let reusable = reusable,
           reusable.shape.count == 4,
           reusable.shape[0].intValue == 1,
           reusable.shape[1].intValue == 3,
           reusable.shape[2].intValue == height,
           reusable.shape[3].intValue == width {
            output = reusable
        } else if let created = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        ) {
            output = created
        } else {
            return nil
        }

        let outputPtr = output.dataPointer.assumingMemoryBound(to: Float32.self)
        let planeSize = height * width

        // RGBA → CHW Float32（先写原始 0~255 值，保留与旧双循环完全一致的
        //   通道顺序与布局：R/G/B 三平面，[0,c,y,x] = outputPtr[c*planeSize + y*width + x]）
        // CoreML MLMultiArray 是 contiguous，CHW 布局：
        //   [0, c, y, x] = outputPtr[c * planeSize + y * width + x]
        for y in 0..<height {
            for x in 0..<width {
                let pixelIdx = (y * width + x) * 4
                let outIdx = y * width + x
                outputPtr[outIdx]                 = Float32(pixelData[pixelIdx])     // R 通道
                outputPtr[planeSize + outIdx]     = Float32(pixelData[pixelIdx + 1]) // G 通道
                outputPtr[planeSize * 2 + outIdx] = Float32(pixelData[pixelIdx + 2]) // B 通道
            }
        }

        // 一次性向量化归一化：整块 [0,255] 除以 255 → [0,1]
        // vDSP_vsdiv 与逐像素 Float32(x)/255.0 同为 IEEE Float 除法，位级一致；
        // 只把除法移出 CHW 双循环，通道顺序/布局不动，训练契约不变。
        var divisor: Float32 = 255.0
        vDSP_vsdiv(outputPtr, 1, &divisor, outputPtr, 1,
                   vDSP_Length(3 * planeSize))

        return output
    }

    // MARK: - 重置

    /// 重置（停止驾驶时调用）
    func reset() {
        generation += 1      // 在途推理结果过期
        lastResult = nil
        lastResultTime = nil
        isInferencing = false
        errorMessage = nil
    }
}
