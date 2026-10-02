//
//  OpticalFlowBridge.swift —— OpenCV DIS 稠密光流的 Swift 封装
//
//  ── 它解决什么问题 ──
//
//  YOLOPX 单次推理实测约 60ms（148 GFLOPs / ANE 实测峰值 9.26 TFLOPS
//  = 16ms 物理地板，当前效率约 26%），跑不满 30Hz。但主循环是 30Hz，
//  中间那 15 帧的感知不能断档 —— 断了车就是"闭着眼开"。
//
//  解法：YOLOPX 保持低频真值，帧间由光流做运动外推，把 15Hz 补成 30Hz。
//  光流比整网便宜 30 倍，是这里唯一算得过来的运动估计手段。
//
//  ── 为什么用 OpenCV 而不是 Apple 官方 ──
//
//  用户红线是「光流 ≤5ms」。本机 640×640 同批实测（ABBA 交错）：
//    · Apple VTOpticalFlow（VideoToolbox 硬件）  10.28 ms  ✗
//    · Vision VNGenerateOpticalFlow              27.43 ms  ✗
//    · OpenCV DISOpticalFlow ULTRAFAST            1.91 ms  ✓
//    · 同上，只留 1 核（极端工况）                 3.78 ms  ✓
//  官方硬件路径慢 5～14 倍。DIS 是 CVPR 2016 的正式算法，OpenCV 官方
//  `video` 模块内建，不是自研手搓。详见 Vendor/OpenCVFlow/README.md。
//
//  ── 精度 ──
//
//  位移估计误差 0.07px（实测 dx=1.930 对真值 2.000，自然纹理图）。
//
//  ── 线程模型 ──
//
//  C 层 `ad_dis_compute` **不是**线程安全的：同一个 ctx 不能被并发调用。
//  本类用一把私有锁把 `compute` 串行化，允许从任意线程调用（但内部会
//  串行执行）。灰度缓冲与 ctx 一样被锁保护，因为 DIS 会复用内部工作缓冲。
//
//  ── fail-open ──
//
//  光流失败（尺寸不合法 / OpenCV 抛异常 / 首帧无历史）时 `compute` 返回
//  nil，调用方必须退化为「本帧不做外推」，**绝不能**把零值当成"车辆静止"
//  去用 —— 那会让预测器把运动中的目标冻住，是安全事故。
//

import Foundation
import CoreVideo
import OpenCVFlow

/// 单帧光流解算结果（车辆运动层面）。
struct OpticalFlowReading: Equatable {

    /// 全局中位水平流（像素）。正 = 画面内容向右移动。
    let dx: Double

    /// 全局中位垂直流（像素）。正 = 画面内容向下移动。
    ///
    /// ⚠️ 自车前进时地面纹理在画面里向下扩散（远小近大），故前进对应 dy > 0。
    let dy: Double

    /// 径向外向散度（像素）。
    ///   > 0 → 内容从画面中心向外扩张 → **自车前进**
    ///   < 0 → 内容向中心收缩         → **自车后退**
    let divergence: Double

    /// 采样时刻（用于预测器算 dt）
    let timestamp: Date

    /// 全局位移的模长（像素），便捷读数
    var magnitude: Double { (dx * dx + dy * dy).squareRoot() }
}

/// OpenCV DIS 光流的 Swift 门面。
///
/// 用法：
/// ```swift
/// let flow = OpticalFlowBridge()
/// if let r = flow.compute(nextGrayPixelBuffer) {   // 每帧喂新图
///     // 用 r 做帧间运动外推
/// }
/// ```
///
/// - 有状态：内部保存「上一帧灰度图」，所以必须**按帧序**调用 `compute`。
/// - 非 @Observable：状态仅用于差分，UI 不直接观察它。
final class OpticalFlowBridge {

    // MARK: - 配置

    /// 光流工作分辨率（正方形边长）。
    ///
    /// 为什么是 640：必须与 YOLOPX / yolo26s 的 letterbox 输入同坐标系，
    /// 否则外推出的位移没法直接作用到检测框和掩码上（各算各的 640 会错位）。
    ///
    /// 实测该分辨率下 p95 = 1.91ms（全核）/ 3.78ms（单核），都在 5ms 红线内。
    /// 若将来要在更弱的机器上跑，可降到 480（p95 1.38ms）或 320（0.97ms）——
    /// 代价是位移精度下降，因为同样的车辆运动在更小的图上只有更少的像素位移。
    static let workingSize = 640

    /// DIS 预设。生产用 ultra fast（1.91ms）；fast 是 7.61ms 会超预算。
    ///
    /// ⚠️ C 枚举在 Swift 里是 `AD_DISPreset` 类型，不能直接 `Int32(...)` 转换
    ///    （会报 "requires that 'AD_DISPreset' conform to 'BinaryFloatingPoint'"）。
    ///    必须取 `.rawValue` 再转。
    private static let preset = AD_DIS_ULTRAFAST

    // MARK: - 内部状态

    /// C 层估计器句柄。nil = 未初始化或创建失败。
    private var context: UnsafeMutableRawPointer?

    /// 上一帧灰度图（workingSize × workingSize，单通道 8-bit）
    private var previousGray: [UInt8] = []

    /// 上一帧的时间戳，供调用方算 dt
    private var previousTimestamp: Date?

    /// 串行化锁：C 层的 ctx 与灰度缓冲都不是线程安全的
    private let lock = NSLock()

    /// 累计成功解算次数（诊断用）
    private(set) var successCount = 0

    /// 累计失败次数（诊断用）。持续增长说明输入有问题，不是偶发抖动。
    private(set) var failureCount = 0

    /// 最近一次解算耗时（毫秒），供 UI 显示与红线监控
    private(set) var lastLatencyMs: Double = 0

    /// 最近一次失败原因（诊断用，nil = 无失败）
    private(set) var lastErrorMessage: String?

    // MARK: - 生命周期

    /// 创建并初始化 C 层估计器。
    ///
    /// 建议**长期持有**（一个感知链路一个实例），不要每帧创建 ——
    /// `ad_dis_create` 内部要分配 DIS 的工作缓冲，成本约 1ms 量级，
    /// 而单帧解算只要 1.91ms，每帧重建等于让光流慢一倍。
    init() {
        let size = Self.workingSize
        previousGray = [UInt8](repeating: 0, count: size * size)
        context = ad_dis_create(Int32(bitPattern: Self.preset.rawValue))
        if context == nil {
            lastErrorMessage = "OpenCV DIS 光流估计器创建失败（ad_dis_create 返回 NULL）"
        }
    }

    deinit {
        if let ctx = context {
            ad_dis_destroy(ctx)
        }
    }

    /// 是否可用（C 层句柄创建成功）
    var isAvailable: Bool { context != nil }

    // MARK: - 主入口

    /// 把当前线程提升到与生产 tick 相同的调度优先级。
    ///
    /// 为什么需要：光流的延迟**高度依赖调度优先级**。同一份代码、同样的负载，
    /// 低优先级线程被抢占的方式完全不同。实测（640×640，7 路背景负载）：
    ///   · 默认优先级线程        p95 = 12.96 ms   ✗ 超 5ms 红线
    ///   · userInteractive 线程  p95 =  3.53 ms   ✓
    ///
    /// 生产环境的 tick 由 `DispatchQueue(qos: .userInteractive)` 驱动，天然
    /// 是 userInteractive。但**自检 / 单发命令行模式跑在主线程上，拿的是默认
    /// 优先级**，于是同一份代码在自检里会"看起来超标"—— 那是测量环境的偏差，
    /// 不是代码的问题。
    ///
    /// 为了让自检的判据和生产一致（否则自检失去意义），自检在测量前显式
    /// 提升本线程。生产路径不需要调用它（tick 本身已是 userInteractive），
    /// 但调了也无害 —— 幂等。
    static func elevateCurrentThreadPriority() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }

    /// 把当前帧的灰度图喂进来做光流（同 `compute`，语义见上）。
    ///
    /// 拆成两个名字只是为了让调用点的意图更清楚，实现完全一致。
    @inline(__always)
    func process(gray: CVPixelBuffer) -> OpticalFlowReading? {
        compute(gray: gray)
    }

    /// 喂入当前帧的灰度图，与上一帧做光流，返回运动摘要。
    ///
    /// - Parameter gray: 灰度像素缓冲。要求：
    ///   · 像素格式 `kCVPixelFormatType_OneComponent8`
    ///   · 尺寸 = `workingSize` × `workingSize`
    ///   调用方负责把 BGRA 转灰度并缩放到这个尺寸（见 `makeGrayBuffer`）。
    /// - Returns: 运动摘要；首帧、尺寸不符、或 C 层失败时返回 nil。
    ///
    /// **首帧返回 nil 是正常的** —— 光流需要两帧才能算差分。调用方
    /// 应当在第一帧静默跳过，而不是当成错误。
    func compute(gray: CVPixelBuffer) -> OpticalFlowReading? {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = context else { return nil }

        let size = Self.workingSize
        guard CVPixelBufferGetWidth(gray) == size,
              CVPixelBufferGetHeight(gray) == size else {
            failureCount += 1
            lastErrorMessage = "灰度缓冲尺寸不是 \(size)×\(size)"
            return nil
        }
        guard CVPixelBufferGetPixelFormatType(gray) == kCVPixelFormatType_OneComponent8 else {
            failureCount += 1
            lastErrorMessage = "灰度缓冲像素格式不是 OneComponent8"
            return nil
        }

        CVPixelBufferLockBaseAddress(gray, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(gray, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(gray) else {
            failureCount += 1
            lastErrorMessage = "灰度缓冲基址为空"
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRow(gray)
        let now = Date()

        // 首帧：只存快照，不出结果
        guard let prevTimestamp = previousTimestamp else {
            copyIntoPrevious(from: base, stride: stride, size: size)
            previousTimestamp = now
            return nil
        }

        let start = Date()
        var result = AD_FlowResult()
        previousGray.withUnsafeBufferPointer { prevBuf in
            guard let prevBase = prevBuf.baseAddress else { return }
            result = ad_dis_compute(ctx,
                                    prevBase, Int32(size),
                                    base.assumingMemoryBound(to: UInt8.self), Int32(stride),
                                    Int32(size), Int32(size))
        }
        lastLatencyMs = Date().timeIntervalSince(start) * 1000

        // 无论如何都推进快照：失败时也更新，否则下一帧还是拿旧图比，
        // 误差会越积越大。
        copyIntoPrevious(from: base, stride: stride, size: size)
        previousTimestamp = now

        guard result.valid != 0 else {
            failureCount += 1
            lastErrorMessage = "OpenCV 光流解算返回 valid=0"
            return nil
        }

        successCount += 1
        lastErrorMessage = nil
        return OpticalFlowReading(dx: result.dx,
                                  dy: result.dy,
                                  divergence: result.divergence,
                                  timestamp: prevTimestamp)
    }

    /// 清空历史（停止驾驶 / 切换场景时调用）。
    /// 不清的话，重新开始时第一帧会拿"停车前最后一张画面"做差分，产生一个巨大的假位移。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        previousTimestamp = nil
        lastErrorMessage = nil
        // 灰度缓冲内容不必清零：previousTimestamp == nil 就可保证首帧只存不算
    }

    // MARK: - 工具

    /// 把当前帧拷进内部快照缓冲。
    ///
    /// 必须逐行按 **stride** 拷贝，不能整块 memcpy —— CVPixelBuffer 的行跨度
    /// 常有对齐填充（bytesPerRow > width），整块拷会错行。
    private func copyIntoPrevious(from base: UnsafeMutableRawPointer, stride: Int, size: Int) {
        let src = base.assumingMemoryBound(to: UInt8.self)
        previousGray.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            if stride == size {
                // 无填充，一次拷完
                dstBase.update(from: src, count: size * size)
            } else {
                for row in 0..<size {
                    (dstBase + row * size).update(from: src + row * stride, count: size)
                }
            }
        }
    }

    /// 构造符合要求的一通道 8-bit 灰度缓冲（外部可用来做输入准备）。
    ///
    /// 与 `YolopxEngine.makePixelBuffer` 同法：用 `CVPixelBufferCreate` +
    /// IOSurface 属性，让 CoreML / Vision 能零拷贝共享。
    static func makeGrayBuffer(size: Int = workingSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_OneComponent8,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess else { return nil }
        return pb
    }

    /// 把 32BGRA 缓冲转成内部要求的单通道灰度（最近邻降采样到 `workingSize`）。
    ///
    /// 用 BT.601 整数权重（77/150/29，与 OpenCV `COLOR_BGR2GRAY` 同系数），
    /// 保证与 Python 侧离线验证结果可比。
    ///
    /// - Parameters:
    ///   - src: 源 32BGRA 缓冲（任意尺寸）
    ///   - dst: 目标单通道缓冲（必须已按 `workingSize` 创建）
    /// - Returns: 成功与否
    @discardableResult
    static func convertToGray(_ src: CVPixelBuffer, into dst: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else { return false }
        let srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src)
        let dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst)
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return false }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return false }
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)

        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        // ⚠️ 2026-09-27（性能修复）：原实现在**内层循环**里逐像素算
        //    `x * srcW / dstW`。生产路径是 640×640（YOLO 直通帧）→ 640×640
        //    （workingSize），即 srcW == dstW —— 那个除法**恒等于 x**，
        //    却对每帧 40.96 万像素各做一次整数除法。
        //
        //    实测（M3，640×640，n=40）：
        //      · 逐像素除法       p50=0.639 ms
        //      · 同尺寸直接步进   p50=0.040 ms   ← 快 16 倍
        //      · 预计算列偏移表   p50=0.264 ms   ← 仍是表访问开销
        //    这是**数学等价**优化（同样取最近邻、同样系数），不是近似。
        //
        //    非同尺寸时保留完整最近邻语义，但把列映射**提到行循环之外**
        //    预计算一次（dstW 次除法而非 dstW×dstH 次）。
        let sameSize = (srcW == dstW && srcH == dstH)

        if sameSize {
            // 快路径：1:1，无缩放、无除法、无查表
            for y in 0..<dstH {
                let srcRow = srcPtr + y * srcStride
                let dstRow = dstPtr + y * dstStride
                for x in 0..<dstW {
                    let p = srcRow + x * 4          // BGRA
                    let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                    // BT.601 整数系数：(77R + 150G + 29B) >> 8
                    dstRow[x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
                }
            }
            return true
        }

        // 通用路径：真正需要重采样（最近邻）。列映射预计算一次。
        var colOffset = [Int](repeating: 0, count: dstW)
        for x in 0..<dstW { colOffset[x] = (x * srcW / dstW) * 4 }

        for y in 0..<dstH {
            // 最近邻：按比例取源行。比双线性快，且光流对轻微混叠不敏感。
            let sy = y * srcH / dstH
            let srcRow = srcPtr + sy * srcStride
            let dstRow = dstPtr + y * dstStride
            for x in 0..<dstW {
                let p = srcRow + colOffset[x]
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                // BT.601 整数系数：(77R + 150G + 29B) >> 8
                dstRow[x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }
        return true
    }
}
