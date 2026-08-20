// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  YoloEngine.swift — CoreML YOLO 目标检测引擎
//
//  职责：把截屏画面 → 障碍物检测框 [Detection]，供 RuleController 决策 + UI 画框
//
//  模型：models/yolo26s.mlmodelc（YOLOv26s，NMS-free 端到端）
//        由 Ultralytics 导出（format="coreml"），自动标 colorSpace=RGB
//
//  模型接口：
//    输入 image:  640×640 CVPixelBuffer，colorSpace = RGB
//                 （App 喂 32BGRA，CoreML 运行时自动抽 R/G/B 按 RGB 喂入，无需手动转通道序）
//    输出:        [1, maxDet, 6] Float32，每行 [x1, y1, x2, y2, conf, class_id]
//                 （坐标为像素，相对 640 输入；Swift parse() 除以 640 转归一化）
//
//  说明：YOLOv26s 为 NMS-free 端到端，无 anchor 概念，去重已在模型内部完成，
//        Swift 端只需要「置信度过滤 + 降序 + 截断 + 类别映射」。
//
//  预处理约定：整帧非等比拉伸到 640×640（不做 letterbox），与训练端一致，
//        因此像素坐标除以 640 即得整帧归一化坐标。
// ============================================================================
import AppKit
@preconcurrency import CoreML
import Foundation
import Observation

// MARK: - 检测引擎

/// CoreML YOLO 检测引擎
/// - @Observable：UI 可观察检测结果、耗时、加载状态
/// - @MainActor：可变状态主线程访问
/// - 推理流程：infer() 主线程入口 → 后台队列跑 nonisolated 静态函数 → 主线程写结果
@Observable
@MainActor
final class YoloEngine {

    // MARK: - 模型常量

    /// 模型输入边长（正方形）
    /// YOLOv26s 官方输入 640（旧 FastestV2 是 352）。
    /// nonisolated：后台推理队列要读，且是编译期常量、无 actor 依赖
    nonisolated static let inputSize = 640

    // 注：YOLOv26s 为 NMS-free 端到端，无 anchor 概念，输出为单张量 [1, maxDet, 6]，
    //     每行 [x1, y1, x2, y2, conf, class_id]（像素坐标，相对 640 输入）。
    //     因此不再需要旧 FastestV2 的 numAnchors=1815 常量。

    // MARK: - 可调参数

    /// 置信度阈值：低于此值的框直接丢弃。
    /// YOLOv26s 比 FastestV2 强，阈值可放宽到 0.22 提升召回（小目标/远处障碍）。
    var confidenceThreshold: Double = 0.22

    /// NMS 的 IoU 阈值
    var iouThreshold: Double = 0.45

    /// 单帧最多保留多少个框（防止 UI 被刷屏）
    var maxDetections: Int = 20

    /// 是否启用（关掉可省算力）
    var enabled: Bool = true

    /// 直通路径是否已活跃（CaptureEngine onYoloFrame 已产出过帧）。
    /// 活跃后 tick() 不再走 NSImage→CGImage 慢路径，避免双重推理。
    private(set) var fastPathActive = false

    // MARK: - 状态输出

    private(set) var isLoaded = false
    private(set) var isInferencing = false

    /// 最新一帧检测结果（tick 与 UI 都读这里）
    private(set) var detections: [Detection] = []

    /// 最近一次推理耗时（毫秒）
    private(set) var lastLatencyMs: Double = 0

    /// 累计推理帧数
    private(set) var inferenceCount: Int = 0

    private(set) var errorMessage: String?

    /// P0-4 修复：上次加载尝试时间戳（失败冷却用）
    @ObservationIgnored
    private var lastLoadAttempt: Date = .distantPast

    /// 加载失败冷却时长（秒）
    private let loadRetryCooldown: TimeInterval = 5.0

    /// P1 修复：generation 计数，reloadModel()/reset() 时递增；
    /// 在途检测完成后比对，不匹配则丢弃过期结果，防 reset/reload 后旧在途结果写回 detections。
    @ObservationIgnored
    private var generation = 0

    // MARK: - 锁定追踪（手动框选 → 对焦式跟踪）

    /// 是否锁定目标
    private(set) var isLocked = false

    /// 锁定目标（归一化框，每帧经检测匹配 + EMA 平滑）
    /// UI 画"对焦"高亮框用这个
    private(set) var lockedTarget: Detection?

    /// 连续丢失帧数（超过阈值自动解除锁定）
    private(set) var lockLostFrames = 0

    /// 锁定相关提示（丢失解除 / 手动锁定）
    private(set) var lockMessage: String?

    /// 上一帧平滑结果（用于全局乱飘抑制 + 锁定匹配基线）
    @ObservationIgnored
    private var lastFrame: [Detection] = []

    // MARK: - 内部资源

    @ObservationIgnored
    private nonisolated(unsafe) var model: MLModel?

    @ObservationIgnored
    private let inferenceQueue = DispatchQueue(label: "com.aurora.yolo",
                                               qos: .userInitiated)

    /// 复用的像素缓冲，避免每帧重新分配
    /// nonisolated(unsafe)：只在串行的 inferenceQueue 上创建与读写，
    /// 且 isInferencing 保证同一时刻只有一帧在跑，无并发访问
    @ObservationIgnored
    private nonisolated(unsafe) var pixelBuffer: CVPixelBuffer?

    /// 直通路径（CaptureEngine GPU 缩放产出）的私有缓冲：
    /// 主线程把输入 memcpy 进来后交给推理队列，避免与捕获队列的写竞争
    @ObservationIgnored
    private nonisolated(unsafe) var yoloInputBuffer: CVPixelBuffer?

    /// 模型定位：优先编译产物 .mlmodelc，回退 .mlpackage。
    /// YOLOv26s 替换后模型名从 game_assist_yolo 改为 yolo26s（旧文件保留作回滚）。
    private var modelURL: URL {
        let modelsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("models")
        let compiled = modelsDir.appendingPathComponent("yolo26s.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) {
            return compiled
        }
        return modelsDir.appendingPathComponent("yolo26s.mlpackage")
    }

    // MARK: - 模型加载

    func loadIfNeeded() {
        guard !isLoaded else { return }
        // P0-4 修复：失败后冷却期内不再重试，避免主线程同步 MLModel() 30Hz 重试风暴
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            model = mlModel
            isLoaded = true
            errorMessage = nil
            // 环3：加载成功后后台跑一次 dummy prediction 预热 ANE（不阻塞主线程）
            Self.warmUp(model: mlModel, queue: inferenceQueue)
        } catch {
            errorMessage = "YOLO 模型加载失败: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    /// 模型预热（环3）：后台队列跑一次 dummy prediction（640×640 零缓冲），
    /// 把 ANE 计算图编译/内存分配提前做完，避免首帧真实检测冷启动尖峰。
    private nonisolated static func warmUp(model: MLModel, queue: DispatchQueue) {
        queue.async {
            let size = inputSize
            guard let pb = makePixelBuffer(size: size),
                  let provider = try? MLDictionaryFeatureProvider(dictionary: [
                      "image": MLFeatureValue(pixelBuffer: pb)
                  ]) else {
                print("[warmup] yolo26s: 预热输入构造失败")
                return
            }
            let start = Date()
            do {
                _ = try model.prediction(from: provider)
                let ms = Date().timeIntervalSince(start) * 1000
                print("[warmup] yolo26s 预热完成: \(String(format: "%.1f", ms))ms  computeUnits=all(自动选 ANE/GPU/CPU)")
            } catch {
                print("[warmup] yolo26s 预热失败: \(error.localizedDescription)")
            }
        }
    }

    /// 热替换（重训 YOLO 后调用）
    func reloadModel() {
        generation += 1      // 在途检测结果过期
        model = nil
        isLoaded = false
        isInferencing = false
        errorMessage = nil
    }

    // MARK: - 推理入口（主线程）

    /// 异步检测
    /// - Parameter image: 截屏画面 CGImage（CaptureEngine 直传，内部拉伸到 352×352）
    func infer(image: CGImage) {
        guard enabled else { return }
        guard isLoaded, let modelRef = model else {
            loadIfNeeded()
            return
        }
        guard !isInferencing else { return }   // 防重叠：上一帧还没跑完就跳过

        isInferencing = true

        let conf = confidenceThreshold
        let maxN = maxDetections
        let size = Self.inputSize
        let gen = generation

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()

            // ── 1. 整帧拉伸绘制进 BGRA 像素缓冲（缓冲首帧创建后复用）──
            if self.pixelBuffer == nil {
                self.pixelBuffer = Self.makePixelBuffer(size: size)
            }
            guard let pb = self.pixelBuffer else {
                Task { @MainActor in self.finish(gen, [], 0, "YOLO: CVPixelBuffer 创建失败") }
                return
            }
            Self.draw(image, into: pb, size: size)

            // ── 2. 推理 ──
            do {
                let input = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
                let out = try modelRef.prediction(from: input)

                // YOLOv26 e2e：单张量输出，名称由导出时自动生成（如 var_1442，不稳定），
                // 因此动态取第一个 featureName，不能硬编码。
                guard let name = out.featureNames.first,
                      let arr = out.featureValue(for: name)?.multiArrayValue else {
                    Task { @MainActor in self.finish(gen, [], 0, "YOLO: 输出缺失") }
                    return
                }

                // ── 3. 阈值过滤 + 截断（e2e 已内置 NMS/Top-K，无需再 NMS）──
                let kept = Self.parse(arr, confidenceThreshold: conf, maxDetections: maxN)
                let latency = Date().timeIntervalSince(start) * 1000

                Task { @MainActor in self.finish(gen, kept, latency, nil) }
            } catch {
                Task { @MainActor in
                    self.finish(gen, [], 0, "YOLO 推理失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 直通路径：CaptureEngine 已在源头把全屏画面 GPU 缩放到 352×352，
    /// 这里直接推理，跳过 NSImage/CGImage 大图转换链路（帧率瓶颈所在）。
    func inferFast(pixelBuffer: CVPixelBuffer) {
        guard enabled else { return }
        fastPathActive = true
        guard isLoaded, let modelRef = model else {
            loadIfNeeded()
            return
        }
        guard !isInferencing else { return }   // 防重叠

        // 拷贝到私有缓冲（主线程，640×640×4 ≈ 1.6MB，memcpy 极快），
        // 避免与 captureQueue 对共享缓冲的写竞争
        if yoloInputBuffer == nil {
            yoloInputBuffer = Self.makePixelBuffer(size: Self.inputSize)
        }
        guard let dst = yoloInputBuffer,
              Self.copyPixelBuffer(pixelBuffer, to: dst) else {
            errorMessage = "YOLO: 直通缓冲拷贝失败"
            return
        }

        isInferencing = true
        let conf = confidenceThreshold
        let maxN = maxDetections
        let gen = generation

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            // 闭包内取缓冲（yoloInputBuffer 在主线程写、本队列读，
            // isInferencing 防重叠保证安全）
            // P0-2 修复：该 guard 失败路径必须复位 isInferencing，否则永久卡死、YOLO 停摆
            guard let dst = self.yoloInputBuffer else {
                Task { @MainActor in self.finish(gen, [], 0, "YOLO: 直通缓冲缺失") }
                return
            }
            let start = Date()

            // ── 1. 推理（输入已是 YoloEngine.inputSize×inputSize BGRA）──
            do {
                let input = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: dst)])
                let out = try modelRef.prediction(from: input)

                // YOLOv26 e2e：单张量输出，名称不稳定，动态取第一个 featureName。
                guard let name = out.featureNames.first,
                      let arr = out.featureValue(for: name)?.multiArrayValue else {
                    Task { @MainActor in self.finish(gen, [], 0, "YOLO: 输出缺失") }
                    return
                }

                // ── 2. 阈值过滤 + 截断（e2e 已内置 NMS/Top-K，无需再 NMS）──
                let kept = Self.parse(arr, confidenceThreshold: conf, maxDetections: maxN)
                let latency = Date().timeIntervalSince(start) * 1000

                Task { @MainActor in self.finish(gen, kept, latency, nil) }
            } catch {
                Task { @MainActor in
                    self.finish(gen, [], 0, "YOLO 推理失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 像素缓冲整块拷贝（352×352 BGRA，约 0.5MB）
    private nonisolated static func copyPixelBuffer(_ src: CVPixelBuffer,
                                                    to dst: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(src, [])
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, [])
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return false }
        let sbpr = CVPixelBufferGetBytesPerRow(src)
        let dbpr = CVPixelBufferGetBytesPerRow(dst)
        let h = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        for y in 0..<h {
            memcpy(d + y * dbpr, s + y * sbpr, min(sbpr, dbpr))
        }
        return true
    }

    private func finish(_ gen: Int, _ dets: [Detection], _ latency: Double, _ error: String?) {
        guard gen == generation else { return }   // reset()/reloadModel() 后在途结果过期，丢弃
        isInferencing = false
        if let error = error {
            errorMessage = error
        } else {
            // 全局帧间平滑：与上一帧做 IoU 匹配，命中目标用 EMA 稳住，
            // 治"框乱飘"（单帧检测框跳来跳去）。新出现的目标直接采用。
            let smoothed = Self.smooth(dets, against: lastFrame)
            lastFrame = smoothed
            detections = smoothed
            lastLatencyMs = latency
            inferenceCount += 1
            errorMessage = nil

            // 锁定追踪：用平滑后的检测喂给锁定匹配
            trackLock(with: smoothed)
        }
    }

    /// 帧间平滑：对每个检测框，找上一帧里 IoU 最大的框；
    /// 命中 → 位置 EMA 平滑；未命中（新目标）→ 原样保留。
    /// - Returns: 平滑后的检测列表（顺序与 dets 一致）
    private nonisolated static func smooth(_ dets: [Detection],
                                           against last: [Detection],
                                           alpha: Double = 0.55) -> [Detection] {
        guard !last.isEmpty, !dets.isEmpty else { return dets }
        var used = Array(repeating: false, count: last.count)
        var out: [Detection] = []
        out.reserveCapacity(dets.count)

        for d in dets {
            // 找上一帧中未使用且 IoU 最大的框
            var bestIdx = -1
            var bestIoU = 0.25   // 低于此视为新目标
            for (i, l) in last.enumerated() where !used[i] {
                let v = iou(d, l)
                if v > bestIoU {
                    bestIoU = v
                    bestIdx = i
                }
            }
            if bestIdx >= 0 {
                used[bestIdx] = true
                let l = last[bestIdx]
                out.append(Detection(x: l.x + (d.x - l.x) * alpha,
                                     y: l.y + (d.y - l.y) * alpha,
                                     width: l.width + (d.width - l.width) * alpha,
                                     height: l.height + (d.height - l.height) * alpha,
                                     label: d.label,
                                     confidence: d.confidence,
                                     rawName: d.rawName))
            } else {
                out.append(d)
            }
        }
        return out
    }

    /// 停止驾驶时清空
    func reset() {
        generation += 1      // 在途检测结果过期
        detections = []
        isInferencing = false
        lastLatencyMs = 0
        errorMessage = nil
        lastFrame = []
        lockedTarget = nil
        isLocked = false
        lockLostFrames = 0
        lockMessage = nil
        fastPathActive = false
    }

    // MARK: - 锁定追踪控制（主线程调用）

    /// 手动框选锁定：直接用用户框的归一化坐标
    func setLock(x: Double, y: Double, width: Double, height: Double) {
        lockedTarget = Detection(x: x, y: y, width: width, height: height,
                                 label: .obstacle, confidence: 0,
                                 rawName: "LOCK")
        isLocked = true
        lockLostFrames = 0
        lockMessage = "已锁定手动选框"
    }

    /// 点选检测框锁定：锁定某个真实检测目标
    func setLock(to det: Detection) {
        lockedTarget = det
        isLocked = true
        lockLostFrames = 0
        lockMessage = "已锁定 \(det.rawName)"
    }

    /// 解除锁定
    func clearLock() {
        lockedTarget = nil
        isLocked = false
        lockLostFrames = 0
        lockMessage = nil
    }

    /// 锁定后每帧追踪：从本帧检测结果里找与锁定框最匹配的目标，
    /// 匹配成功 → EMA 平滑更新锁定框（稳如对焦）；失败 → 丢失计数，超限自动解除。
    /// 必须在主线程调用（finish() 内）。
    private func trackLock(with dets: [Detection]) {
        guard isLocked, let target = lockedTarget else { return }

        // 匹配策略：IoU 优先 + 中心距离辅助。
        // 锁定框可以比检测框略大（用户框可能画大），所以 IoU 要求放宽，
        // 并加入中心距离惩罚，避免锁定目标在多个检测框间跳来跳去。
        var best: Detection? = nil
        var bestScore = -0.35
        for d in dets {
            let iou = Self.iou(d, target)
            let dist = Self.centerDistance(d, target)
            // 得分：IoU 占主导，中心距离作惩罚
            let score = iou - dist * 0.4
            if score > bestScore {
                bestScore = score
                best = d
            }
        }

        if let m = best, bestScore > -0.25 {
            // 匹配成功：EMA 平滑（α=0.5，兼顾响应速度与稳定性）
            let alpha = 0.5
            let nx = target.x + (m.x - target.x) * alpha
            let ny = target.y + (m.y - target.y) * alpha
            let nw = target.width + (m.width - target.width) * alpha
            let nh = target.height + (m.height - target.height) * alpha
            lockedTarget = Detection(x: nx, y: ny, width: nw, height: nh,
                                     label: m.label,
                                     confidence: m.confidence,
                                     rawName: m.rawName)
            lockLostFrames = 0
        } else {
            lockLostFrames += 1
            // 连续约 0.5s（15 帧）没匹配到 → 目标可能离开画面，自动解除
            if lockLostFrames > 15 {
                lockedTarget = nil
                isLocked = false
                lockLostFrames = 0
                lockMessage = "目标丢失，锁定已解除"
            }
        }
    }

    /// 两框中心距离（归一化）
    private nonisolated static func centerDistance(_ a: Detection,
                                                   _ b: Detection) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - 自检（命令行 --yolo-selftest <图片路径>）

    /// 原始输出对拍：打印单张量前 12 行 (x1,y1,x2,y2,conf,class_id)，与 Python 端核对
    private func rawDump(_ out: MLMultiArray) -> String {
        let n = out.shape.count >= 2 ? out.shape[1].intValue : 0
        var rr = ["原始输出行[0..12] (x1,y1,x2,y2,conf,class_id):"]
        for k in 0..<min(12, n) {
            let vals = (0..<6).map { Self.readML(out, [0, k, $0]) }
            rr.append(String(format: "  %2ld (%.3f,%.3f,%.3f,%.3f) conf=%.4f cls=%.0f",
                             k, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]))
        }
        return rr.joined(separator: "\n")
    }

    /// 同步跑一张图，返回可读报告。
    /// 用途：验证 Swift 侧的 BGRA 像素缓冲路径与 Python 端（tools/verify_yolo_coreml.py）
    ///       结果一致 —— 通道序如果搞反，模型不会报错，只会默默给出错误的框。
    func selfTest(imagePath: String) -> String {
        loadIfNeeded()
        guard let modelRef = model else {
            return "✗ 模型加载失败: \(errorMessage ?? "未知")"
        }
        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "✗ 读图失败: \(imagePath)"
        }
        guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
            return "✗ CVPixelBuffer 创建失败"
        }
        Self.draw(cgImage, into: pb, size: Self.inputSize)
        Self.dumpPNG(pb, to: "/tmp/yolo_swift_input.png")   // 调试图：导出缓冲内容

        do {
            let start = Date()
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
            let out = try modelRef.prediction(from: input)
            guard let name = out.featureNames.first,
                  let arr = out.featureValue(for: name)?.multiArrayValue else {
                return "✗ 输出缺失"
            }
            let kept = Self.parse(arr, confidenceThreshold: confidenceThreshold,
                                  maxDetections: maxDetections)
            let ms = Date().timeIntervalSince(start) * 1000

            var lines = ["图片: \(imagePath)  (\(Int(nsImage.size.width))×\(Int(nsImage.size.height)))",
                         "模型: \(modelURL.lastPathComponent)",
                         String(format: "耗时: %.1f ms  阈值: %.2f", ms, confidenceThreshold),
                         "输出dtype: \(arr.dataType.rawValue)  shape=\(arr.shape.map(\.intValue))"]

            // 原始输出对拍（前 12 行），与 Python 端逐项核对
            lines.append(self.rawDump(arr))

            lines.append("过阈值 \(kept.count) 个:")
            for d in kept {
                let flag = d.isInDangerZone() ? "[危险区]" : ""
                lines.append(String(format: "  %-14@ %.3f  中心(%.3f,%.3f) 宽高(%.3f,%.3f) %@",
                                    d.rawName as NSString, d.confidence, d.x, d.y,
                                    d.width, d.height, flag as NSString))
            }
            return lines.joined(separator: "\n")
        } catch {
            return "✗ 推理失败: \(error.localizedDescription)"
        }
    }

    /// 帧率基准：对比 直通路径(352 缓冲直接推理) vs 慢路径(NSImage→CGImage→绘制→推理)
    /// 各跑 N 次取平均，量化 CaptureEngine 直通改造的收益
    func benchmark(imagePath: String, iterations: Int = 30) -> String {
        loadIfNeeded()
        guard let modelRef = model else {
            return "✗ 模型加载失败: \(errorMessage ?? "未知")"
        }
        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "✗ 读图失败: \(imagePath)"
        }

        var lines = ["图片: \(imagePath)  (\(Int(nsImage.size.width))×\(Int(nsImage.size.height)))",
                     "迭代: \(iterations) 次/路径  模型: \(modelURL.lastPathComponent)"]

        // ── 慢路径：CGContext 绘制到 352 缓冲 + 推理 ──
        do {
            guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
                return "✗ CVPixelBuffer 创建失败"
            }
            var total = 0.0
            for _ in 0..<iterations {
                let start = Date()
                Self.draw(cgImage, into: pb, size: Self.inputSize)
                let input = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
                _ = try modelRef.prediction(from: input)
                total += Date().timeIntervalSince(start) * 1000
            }
            let avg = total / Double(iterations)
            lines.append(String(format: "慢路径(NSImage→CGImage→绘制→推理): %.1f ms/帧  ≈ %.0f FPS",
                                avg, 1000 / avg))
        } catch {
            lines.append("✗ 慢路径失败: \(error.localizedDescription)")
        }

        // ── 直通路径：352 缓冲直接推理（含 memcpy 拷贝）──
        do {
            guard let pb = Self.makePixelBuffer(size: Self.inputSize) else {
                return "✗ CVPixelBuffer 创建失败"
            }
            Self.draw(cgImage, into: pb, size: Self.inputSize)   // 模拟 CaptureEngine 源头缩放
            var total = 0.0
            for _ in 0..<iterations {
                let start = Date()
                // 模拟 inferFast：memcpy 到私有缓冲 + 推理
                if let dst = Self.makePixelBuffer(size: Self.inputSize) {
                    _ = Self.copyPixelBuffer(pb, to: dst)
                    let input = try MLDictionaryFeatureProvider(
                        dictionary: ["image": MLFeatureValue(pixelBuffer: dst)])
                    _ = try modelRef.prediction(from: input)
                }
                total += Date().timeIntervalSince(start) * 1000
            }
            let avg = total / Double(iterations)
            lines.append(String(format: "直通路径(352缓冲+memcpy+推理): %.1f ms/帧  ≈ %.0f FPS",
                                avg, 1000 / avg))
        } catch {
            lines.append("✗ 直通路径失败: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 像素缓冲（nonisolated，纯函数）

    private nonisolated static func makePixelBuffer(size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    /// 把像素缓冲导出为 PNG（调试用，验证 Swift 喂给模型的内容与 Python 端是否一致）
    private nonisolated static func dumpPNG(_ pb: CVPixelBuffer, to path: String) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        guard let cg = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// 把整帧拉伸绘制进像素缓冲（不 letterbox，与训练/官方 demo 的 resize 行为一致）
    private nonisolated static func draw(_ cgImage: CGImage,
                                         into pb: CVPixelBuffer,
                                         size: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        // 32BGRA + premultipliedFirst + littleEndian32 == BGRA 内存序；
        // 模型实际声明 colorSpace=RGB，CoreML 运行时自动从 BGRA 抽 R/G/B 按 RGB 喂入（无需手动转）
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: size, height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return }
        ctx.interpolationQuality = .low   // 检测对插值质量不敏感，选快的
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // MARK: - 输出解析（nonisolated，纯函数）

    /// 安全读取 MLMultiArray 元素（让 CoreML 自己处理 dtype / stride / 半精度）
    /// 直接读 dataPointer 在 FLOAT16 + 非连续 stride 下会错位，这里用官方下标
    private nonisolated static func readML(_ m: MLMultiArray, _ index: [Int]) -> Double {
        m[index.map { NSNumber(value: $0) }].doubleValue
    }

    /// 单张量 [1, maxDet, 6] → [Detection]。
    /// 每行 = [x1, y1, x2, y2, conf, class_id]，坐标为**像素**（相对 inputSize 输入，
    /// 实测 YOLOv26s 输出为像素，此处统一除以 inputSize 转归一化 [0,1]，与
    /// Detection 契约及全链路（RuleController/overlay）一致）。
    /// e2e 模型已内置 NMS + Top-K，此处只需置信度过滤 + 降序 + 截断。
    private nonisolated static func parse(_ out: MLMultiArray,
                                          confidenceThreshold: Double,
                                          maxDetections: Int) -> [Detection] {
        // 动态读取候选数（shape 第二维），不依赖硬编码常量
        let n = out.shape.count >= 2 ? out.shape[1].intValue : 0
        let size = Double(inputSize)
        var dets: [Detection] = []
        dets.reserveCapacity(min(maxDetections, n))

        for i in 0..<n {
            let conf = Self.readML(out, [0, i, 4])
            // P0-1 修复：YOLO 单帧可能输出 NaN/Inf，任何非有限值都跳过该框，
            // 绝不进入 Int()（Int(NaN) 会 runtime trap 崩全车）
            guard conf.isFinite, conf > confidenceThreshold else { continue }

            // 像素坐标 → 归一化坐标（除以输入边长 640）
            let x1 = Self.readML(out, [0, i, 0]) / size
            let y1 = Self.readML(out, [0, i, 1]) / size
            let x2 = Self.readML(out, [0, i, 2]) / size
            let y2 = Self.readML(out, [0, i, 3]) / size
            guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { continue }
            let w = x2 - x1, h = y2 - y1
            guard w > 0.001, h > 0.001 else { continue }   // 过滤退化框

            let clsRaw = Self.readML(out, [0, i, 5])
            guard clsRaw.isFinite else { continue }
            // 加固：有限但超范围的大值（如 1e20）转 Int 会 overflow trap；越界索引也会异常。
            // 先 clamp 到 [0, 类别数-1] 再转 Int，双保险。
            let clsIdx = Int(min(max(clsRaw.rounded(), 0), Double(CocoLabels.names.count - 1)))
            let (label, name) = CocoLabels.map(clsIdx)

            dets.append(Detection(x: (x1 + x2) / 2,
                                  y: (y1 + y2) / 2,
                                  width: w,
                                  height: h,
                                  label: label,
                                  confidence: conf,
                                  rawName: name))
        }
        // e2e 输出已按置信度降序，这里兜底排序 + 截断（替代原 nms 的 limit 语义）
        return Array(dets.sorted { $0.confidence > $1.confidence }.prefix(maxDetections))
    }

    // 注：原 FastestV2 需要单独 NMS（nms() 已删除）。YOLOv26 为 NMS-free 端到端，
    // 去重已在模型内部完成，Swift 端只做置信度过滤 + 降序截断（见 parse()）。

    private nonisolated static func iou(_ a: Detection, _ b: Detection) -> Double {
        let ax1 = a.x - a.width / 2, ax2 = a.x + a.width / 2
        let ay1 = a.y - a.height / 2, ay2 = a.y + a.height / 2
        let bx1 = b.x - b.width / 2, bx2 = b.x + b.width / 2
        let by1 = b.y - b.height / 2, by2 = b.y + b.height / 2

        let iw = max(0, min(ax2, bx2) - max(ax1, bx1))
        let ih = max(0, min(ay2, by2) - max(ay1, by1))
        let inter = iw * ih
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}

// MARK: - COCO 类别映射

/// COCO-80 类名 + 到 Detection.Label 的映射
enum CocoLabels {

    /// Yolo-FastestV2 用的 COCO 80 类顺序（data/coco.names）
    static let names: [String] = [
        "person", "bicycle", "car", "motorbike", "aeroplane", "bus", "train", "truck",
        "boat", "traffic light", "fire hydrant", "stop sign", "parking meter", "bench",
        "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra",
        "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove",
        "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup",
        "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
        "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "sofa",
        "pottedplant", "bed", "diningtable", "toilet", "tvmonitor", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
        "hair drier", "toothbrush",
    ]

    /// 车辆类（含两轮/轨道/船机，游戏里都当"会动的大件"处理）
    private static let vehicleIdx: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8]

    /// 人
    private static let personIdx: Set<Int> = [0]

    /// 交通标识类（红绿灯 / 停车标志 / 计时器）
    private static let signIdx: Set<Int> = [9, 11, 12]

    /// COCO 类索引 → (规则用的 Label, UI 显示名)
    static func map(_ idx: Int) -> (Detection.Label, String) {
        guard idx >= 0, idx < names.count else { return (.obstacle, "OBJ") }
        let name = names[idx].uppercased()
        if personIdx.contains(idx)  { return (.pedestrian, name) }
        if vehicleIdx.contains(idx) { return (.car, name) }
        if signIdx.contains(idx)    { return (.sign, name) }
        return (.obstacle, name)
    }
}
