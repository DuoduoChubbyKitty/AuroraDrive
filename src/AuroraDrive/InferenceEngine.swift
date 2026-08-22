// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreML
import Combine
import Accelerate

// MARK: - 推理结果
struct InferenceResult {
    let steer: Double
    let throttle: Double
    let brake: Double
    let latencyMs: Double
    let timestamp: Date

    init(steer: Double, throttle: Double, brake: Double, latencyMs: Double) {
        self.steer = steer
        self.throttle = throttle
        self.brake = brake
        self.latencyMs = latencyMs
        self.timestamp = Date()
    }
}

// MARK: - 推理引擎
@MainActor
class InferenceEngine: ObservableObject {
    @Published var lastResult: InferenceResult?
    @Published var lastResultTime: Date?
    @Published var errorMessage: String?
    @Published var inferenceCount: Int = 0
    @Published var isLoaded: Bool = false

    // MARK: - 模型参数（与训练导出一致）
    // 静态默认 URL（m9_mono），实例化时可覆盖为自定义模型名
    private static let defaultModelURL = Bundle.main.url(
        forResource: "m9_mono", withExtension: "mlpackage"
    )!
    private let modelURL: URL
    static let inputHeight = 180
    static let inputWidth  = 320
    static let stateDim    = 6

    // MARK: - 状态
    private var model: MLModel?
    private let inferenceQueue = DispatchQueue(label: "aurora.inference", qos: .userInteractive)
    private var generation = 0
    private var isInferencing = false
    private var lastInferTime = Date()
    private let inferCooldownMs: TimeInterval = 1.0 / 24.0
    private var reusableImageBuffer: MLMultiArray?
    private var reusableStateBuffer: MLMultiArray?
    // P3优化：预分配像素缓冲区，避免每次 infer 分配 ~230KB 的 [UInt8]。
    // 尺寸与 inputHeight×inputWidth×4 对齐（180×320×4 = 230400）。
    private var reusablePixelData: [UInt8]?

    // MARK: - 内部资源
    static let nsZero = NSNumber(value: 0.0 as Float)
    static let nsOne  = NSNumber(value: 1.0 as Float)

    // MARK: - 模型加载
    init(modelFileName: String? = nil) {
        // modelFileName 非 nil 时查找对应模型文件，否则用默认 m9_mono
        if let name = modelFileName {
            let candidates = ["\(name).mlmodelc", "\(name).mlpackage"]
            // 在 Bundle 资源目录中查找同名模型
            let bundlePath = Bundle.main.bundlePath
            var modelURL: URL? = nil
            for candidate in candidates {
                let url = URL(fileURLWithPath: bundlePath).appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) {
                    modelURL = url
                    break
                }
            }
            self.modelURL = modelURL ?? Self.defaultModelURL
        } else {
            modelURL = Self.defaultModelURL
        }
    }

    func loadIfNeeded() {
        guard model == nil else { return }
        isLoaded = false
        do {
            model = try MLModel(contentsOf: modelURL)
            isLoaded = true
            Task { @MainActor [weak self] in self?.errorMessage = nil }
            if let m = model {
                inferenceQueue.async {
                    guard let arr = try? MLMultiArray(shape: [1, 3, 180, 320], dataType: .float32) else { return }
                    guard let state = try? MLMultiArray(shape: [1, 6], dataType: .float32) else { return }
                    guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                        "image": MLFeatureValue(multiArray: arr),
                        "vehicle_state": MLFeatureValue(multiArray: state),
                    ]) else { return }
                    _ = try? m.prediction(from: provider)
                }
            }
        } catch {
            let msg = "模型加载失败: \(error.localizedDescription)"
            Task { @MainActor [weak self] in self?.errorMessage = msg }
        }
    }

    // MARK: - 推理入口（主线程）
    func infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double) {
        guard isLoaded, let modelRef = model else {
            loadIfNeeded()
            return
        }
        guard !isInferencing else { return }

        isInferencing = true

        let h = Self.inputHeight
        let w = Self.inputWidth
        let gen = generation
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()

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
            guard let imageBuffer = self.preprocessImage(image, height: h, width: w,
                                                          into: self.reusableImageBuffer,
                                                          pixelBuffer: &self.reusablePixelData),
                  let stateBuffer = Self.buildVehicleState(speedKmh: speedKmh,
                                                           speedLimitKmh: speedLimitKmh,
                                                           into: self.reusableStateBuffer) else {
                Task { @MainActor in self.finishInference(gen, nil, error: "预处理失败", at: Date()) }
                return
            }

            let imageFeature = MLFeatureValue(multiArray: imageBuffer)
            let stateFeature = MLFeatureValue(multiArray: stateBuffer)

            let inputDict: [String: Any] = [
                "image": imageFeature,
                "vehicle_state": stateFeature,
            ]

            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: inputDict)
                let output = try modelRef.prediction(from: provider)

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
                let completionTime = Date()

                let result = InferenceResult(steer: steer,
                                             throttle: throttle,
                                             brake: brake,
                                             latencyMs: latency)
                Task { @MainActor in self.finishInference(gen, result, error: nil, at: completionTime) }
            } catch {
                Task { @MainActor in self.finishInference(gen, nil, error: "推理失败: \(error.localizedDescription)", at: Date()) }
            }
        }
    }

    // MARK: - 推理完成回调（主线程）
    private func finishInference(_ gen: Int, _ result: InferenceResult?, error: String?, at completionTime: Date) {
        guard gen == generation else { return }
        isInferencing = false
        if let result = result {
            lastResult = result
            lastResultTime = completionTime
            inferenceCount += 1
        }
        if let error = error {
            errorMessage = error
        }
    }

    // MARK: - 车辆状态构造（纯函数）
    private static func buildVehicleState(speedKmh: Double,
                                          speedLimitKmh: Double,
                                          into reusable: MLMultiArray?) -> MLMultiArray? {
        let speedNorm = max(0.0, min(1.0, speedKmh / 120.0))
        let limitNorm = max(0.0, min(1.0, speedLimitKmh / 120.0))

        let arr: MLMultiArray
        if let reusable = reusable,
           reusable.shape.count == 2,
           reusable.shape[0].intValue == 1,
           reusable.shape[1].intValue == Self.stateDim {
            arr = reusable
        } else if let created = try? MLMultiArray(shape: [1, NSNumber(value: Self.stateDim)],
                                                  dataType: .float32) {
            arr = created
        } else {
            return nil
        }
        arr[0] = NSNumber(value: speedNorm)
        arr[1] = Self.nsZero
        arr[2] = Self.nsZero
        arr[3] = Self.nsOne
        arr[4] = NSNumber(value: limitNorm)
        arr[5] = Self.nsZero
        return arr
    }

    // MARK: - 画面预处理
    private func preprocessImage(_ cgImage: CGImage,
                                  height: Int, width: Int,
                                  into reusable: MLMultiArray?,
                                  pixelBuffer: inout [UInt8]?) -> MLMultiArray? {
        let pixelsW = width
        let pixelsH = height
        let bytesPerRow = pixelsW * 4
        let totalBytes = pixelsW * pixelsH * 4
        // 复用或新分配像素缓冲区，避免每帧 ~230KB 堆分配。
        if pixelBuffer == nil || pixelBuffer!.count != totalBytes {
            pixelBuffer = [UInt8](repeating: 0, count: totalBytes)
        }
        guard var pixelData = pixelBuffer else { return nil }

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

        let outputBuf = UnsafeMutableBufferPointer(start: outputPtr, count: 3 * planeSize)
        pixelData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            let cols = width
            for y in 0..<height {
                let rowOff = y * cols
                let byteOff = y * cols * 4
                for x in 0..<cols {
                    let b = byteOff + x * 4
                    outputBuf[rowOff + x]                              = Float32(src[b])
                    outputBuf[planeSize + rowOff + x]                = Float32(src[b + 1])
                    outputBuf[planeSize * 2 + rowOff + x]            = Float32(src[b + 2])
                }
            }
        }

        var divisor: Float32 = 255.0
        vDSP_vsdiv(outputPtr, 1, &divisor, outputPtr, 1,
                   vDSP_Length(3 * planeSize))

        return output
    }

    // MARK: - 重置
    func reset() {
        generation += 1
        clearInternal()
    }

    private func clearInternal() {
        model = nil; isLoaded = false; isInferencing = false; errorMessage = nil
        lastResult = nil; lastResultTime = nil
        reusablePixelData = nil
    }

    // MARK: - 重载模型（训练部署后调用）
    func reloadModel() {
        generation += 1
        guard let old = model else { return }
        // 释放旧模型句柄
        model = nil
        do {
            model = try MLModel(contentsOf: modelURL)
            isLoaded = true
            errorMessage = nil
        } catch {
            isLoaded = false
            errorMessage = "模型重载失败: \(error.localizedDescription)"
        }
    }
}
