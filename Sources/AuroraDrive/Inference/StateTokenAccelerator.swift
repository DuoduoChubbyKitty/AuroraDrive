// StateTokenAccelerator — 带 state_token 输出的 V3 CoreML 模型加速器
//
// ══════════════════════════════════════════════════════════════════════════
// 【它解决什么问题】生产用的 `InferenceEngineV3` 只吐 8 路决策头（vertical/
//   horizontal/四个刹车头/confidence/risk），**不暴露内部 256 维 state token**。
//   在线训练需要每一帧都拿到这个 state_token 作为策略头（PolicyHead）的输入，
//   所以这里单独封装一个「额外输出 state_token[256]」的导出模型——它是 A 域
//   `tools/v3_exp/export_state_token_model.py` 的产物，文件名可配。
//
// 【与 InferenceEngineV3 的关系：只读复用，不改它】
//   · 输入契约**完全复用** `V3InputContract`（六个输入的名字/形状/dtype 全取自
//     同一处常量）——不手抄第二份，避免「抄错一个数字导致模型算出垃圾」这类
//     无声错误（CoreML 对形状错误并不总是报错）。
//   · 输入 dtype 必须 `.float16`（V3 文件头红线 1 的实测反例：同一全零输入，
//     float32 与 float16 得到**完全不同**的输出，且 CoreML 不报错）。
//   · 帧窗口用 `V3FrameRingBuffer` 同一套「新→旧」取法，保证与训练口径一致。
//   · 本文件不修改 V3 引擎 / DriveState / App，纯新增适配器。
//
// 【输出读取为什么用 `[i].floatValue`，而不用指针强转】
//   导出的 .mlmodelc 输出 dtype 可能是 float16，也可能是 float32（取决于 A 域
//   导出时的 compute_precision）。若照抄输入的 `assumingMemoryBound(to:
//   Float16.self)` 去读一个 **float32** 输出，会把每 4 字节当 2 个 fp16 解释 →
//   维度翻倍且全是垃圾/NaN。`MLMultiArray[i].floatValue` 会按数组**真实 dtype**
//   自动转换，是唯一与 dtype 无关的正确读法。
//   ⚠️ 方向不同：**输入**仍严格用 float16 指针写（模型吃 fp16，红线 1）；
//      **输出**一律走 `.floatValue`。两者不要混用同一种指针读法。
//
// 【返回值不吞 NaN】本类的 `stateTokenAndLogits` 只校验维度，原样返回模型算出的
//   数值（含可能出现的 NaN）。判定 NaN 是调用方的事：
//     · 自检据此断言「非全 NaN」；
//     · 在线循环/训练端必须**丢弃**含 NaN 的帧（见设计文档安全护栏）。
//   若这里静默把 NaN 帧换 nil，自检就分不清「模型吐了 NaN」与「读取失败」。
//
// 【安全边界】本类纯推理：不按键、不驱动控制、不写 DriveState。它是在线循环里
//   「取 state_token」的一步，真正的按键仍走既有 `ControlEngine`，且默认 digest
//   消化模式不真按键（见 docs/v3-design/07-在线训练接入设计.md）。
//
// 【并发纪律】持有 MLModel 与六个复用输入缓冲，**要求调用方串行使用**
//   （与 V3 的 queue 纪律一致：在线循环只有一个推理线程，自检是同步单线程）。
//   本类**不内建锁**——为「可能存在的并发」加锁属过度设计；调用方若确有多线程，
//   应把它整个放进自己的串行队列。
// ══════════════════════════════════════════════════════════════════════════

import Foundation
import CoreGraphics
@preconcurrency import CoreML

/// 带 state_token 输出的 V3 模型加速器。
///
/// 生命周期：`init` 只解析路径，不加载；首次 `stateTokenAndLogits` / `loadIfNeeded`
/// 时懒加载。加载失败不崩溃——`failureReason` 给出可定位的原因，调用方决定降级。
final class StateTokenAccelerator {

    /// state_token 维度（策略头输入宽度，硬契约）。
    static let stateTokenDim = 256

    /// 默认模型名（A 域导出产物，落在 models/ 下）。
    static let defaultModelName = "v3_state_token"

    /// state_token 的约定输出名（A 域未最终定名，允许环境变量覆盖）。
    static let defaultStateTokenOutputName = "state_token"

    /// 模型路径（可配）：
    ///   1) 环境变量 `AURORA_STATE_TOKEN_MODEL`（绝对路径，便于 A 域产物落在别处）
    ///   2) 缺省 `models/v3_state_token.mlmodelc`
    let modelURL: URL

    /// state_token 输出名（环境变量 `AURORA_STATE_TOKEN_OUTPUT_NAME` 可覆盖）。
    private let stateTokenOutputName: String

    private var model: MLModel?

    /// 最近一次加载/推理失败的原因（nil = 尚未失败）。供上层如实上报，不吞错。
    private(set) var failureReason: String?

    // ── 复用输入缓冲（dtype 必须 float16，见文件头红线 1）──
    private var bufferHi: MLMultiArray?
    private var bufferLo: MLMultiArray?
    private var bufferLane: MLMultiArray?
    private var bufferDets: MLMultiArray?
    private var bufferDetMask: MLMultiArray?
    private var bufferState: MLMultiArray?

    init(modelURL: URL? = nil) {
        if let modelURL {
            self.modelURL = modelURL
        } else if let env = ProcessInfo.processInfo.environment["AURORA_STATE_TOKEN_MODEL"],
                  !env.isEmpty {
            self.modelURL = URL(fileURLWithPath: env)
        } else {
            self.modelURL = AuroraPaths.projectRoot()
                .appendingPathComponent("models")
                .appendingPathComponent("\(Self.defaultModelName).mlmodelc")
        }
        self.stateTokenOutputName =
            ProcessInfo.processInfo.environment["AURORA_STATE_TOKEN_OUTPUT_NAME"]
            ?? Self.defaultStateTokenOutputName
    }

    /// 是否已就绪（模型已加载）。
    var isReady: Bool { model != nil }

    // MARK: - 加载

    /// 懒加载模型。返回是否就绪；失败时 `failureReason` 有明确原因，不崩溃。
    @discardableResult
    func loadIfNeeded() -> Bool {
        if model != nil { return true }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            failureReason = "state_token 模型不存在：\(modelURL.path)"
            return false
        }
        let cfg = MLModelConfiguration()
        // 默认 ANE 优先（与 InferenceEngineV3 一致）；AURORA_COMPUTE_UNITS 可覆盖，
        // 便于复现跨计算单元的数值一致性。
        cfg.computeUnits = Self.computeUnitsFromEnvironment()
        do {
            model = try MLModel(contentsOf: modelURL, configuration: cfg)
            failureReason = nil
            print("[rl-accel] 模型加载成功：\(modelURL.lastPathComponent)")
            return true
        } catch {
            // 如实上报底层原因 + 本层上下文（定位是路径/权限/模型损坏）
            failureReason = "state_token 模型加载失败（\(modelURL.lastPathComponent)）："
                + (error as NSError).localizedDescription
            print("[rl-accel] 加载失败：\(failureReason ?? "-")")
            return false
        }
    }

    // MARK: - 推理

    /// 跑一帧，返回 256 维 state_token 与纵向/横向 logits。
    ///
    /// 输入与 `InferenceEngineV3` 完全同源：`hi` / `lo` 是 `V3FrameRingBuffer`
    /// 产出的新→旧窗口；`prevHorizontalClass` 是上一帧实际执行的横向动作
    /// （0=A / 1=NONE / 2=D），写入 `vehicle_state[6]`（训练口径）。
    ///
    /// - Returns: 模型可用且维度正确时的三元组；模型缺失/加载失败/推理异常/
    ///   维度不符时返回 nil，并置 `failureReason`。返回值**不吞 NaN**（见文件头）。
    func stateTokenAndLogits(hi: [Float16], lo: [Float16],
                             prevHorizontalClass: Int)
        -> (stateToken: [Float], vLogits: [Float], hLogits: [Float])? {
        guard loadIfNeeded(), let model = self.model else { return nil }
        guard let provider = makeProvider(hi: hi, lo: lo,
                                          prevHorizontalClass: prevHorizontalClass) else {
            failureReason = "构造输入 provider 失败（缓冲长度不符或分配失败）"
            return nil
        }
        do {
            let output = try model.prediction(from: provider)
            guard let stateToken = readStateToken(output) else { return nil }
            guard let logits = readLogits(output) else { return nil }
            return (stateToken: stateToken, vLogits: logits.v, hLogits: logits.h)
        } catch {
            failureReason = "state_token 模型推理失败："
                + (error as NSError).localizedDescription
            return nil
        }
    }

    // MARK: - 输入组装（与 InferenceEngineV3.makeProvider 同口径）

    /// 分配/复用六个输入 MLMultiArray（形状固定，dtype 全部 .float16）。
    private func ensureBuffers() -> Bool {
        if bufferHi == nil {
            bufferHi = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.hiFrames), 3,
                        NSNumber(value: V3InputContract.hiHeight),
                        NSNumber(value: V3InputContract.hiWidth)],
                dataType: .float16)
        }
        if bufferLo == nil {
            bufferLo = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.loFrames), 3,
                        NSNumber(value: V3InputContract.loHeight),
                        NSNumber(value: V3InputContract.loWidth)],
                dataType: .float16)
        }
        if bufferLane == nil {
            bufferLane = try? MLMultiArray(
                shape: [1, 1, NSNumber(value: V3InputContract.laneSize),
                        NSNumber(value: V3InputContract.laneSize)],
                dataType: .float16)
        }
        if bufferDets == nil {
            bufferDets = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.maxDetections),
                        NSNumber(value: V3InputContract.detFeatureDim)],
                dataType: .float16)
        }
        if bufferDetMask == nil {
            bufferDetMask = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.maxDetections)],
                dataType: .float16)
        }
        if bufferState == nil {
            bufferState = try? MLMultiArray(
                shape: [1, NSNumber(value: V3InputContract.stateDim)],
                dataType: .float16)
        }
        return bufferHi != nil && bufferLo != nil && bufferLane != nil
            && bufferDets != nil && bufferDetMask != nil && bufferState != nil
    }

    private func makeProvider(hi: [Float16], lo: [Float16],
                              prevHorizontalClass: Int) -> MLFeatureProvider? {
        guard ensureBuffers(),
              let bufHi = bufferHi, let bufLo = bufferLo,
              let bufLane = bufferLane, let bufDets = bufferDets,
              let bufMask = bufferDetMask, let bufState = bufferState else { return nil }

        // ① image_hi / image_lo：整块拷贝（布局已与模型期望的扁平顺序一致）
        guard Self.writeFloat16(bufHi, from: hi),
              Self.writeFloat16(bufLo, from: lo) else { return nil }

        // ② lane / dets / det_mask：训练时恒为零填充（V3 录制数据无这两路）。
        //    缓冲创建即为 0，此后从不写入 → 无需每帧重置。
        //    ⚠️ 若将来接入真实车道线/检测框，必须同时重训模型（训练分布已在零
        //       填充上收敛，直接喂真值会分布偏移）。

        // ③ vehicle_state：按训练口径，仅 [6] = 上一帧 A/D，其余恒 0（红线 3）。
        let statePtr = bufState.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<V3InputContract.stateDim { statePtr[i] = 0 }
        switch prevHorizontalClass {
        case 0: statePtr[V3InputContract.steerStateIndex] = -1   // 上一帧 A
        case 2: statePtr[V3InputContract.steerStateIndex] = 1    // 上一帧 D
        default: statePtr[V3InputContract.steerStateIndex] = 0
        }

        let dict: [String: Any] = [
            V3InputContract.imageHi: MLFeatureValue(multiArray: bufHi),
            V3InputContract.imageLo: MLFeatureValue(multiArray: bufLo),
            V3InputContract.lane: MLFeatureValue(multiArray: bufLane),
            V3InputContract.dets: MLFeatureValue(multiArray: bufDets),
            V3InputContract.detMask: MLFeatureValue(multiArray: bufMask),
            V3InputContract.vehicleState: MLFeatureValue(multiArray: bufState),
        ]
        return try? MLDictionaryFeatureProvider(dictionary: dict)
    }

    /// 把 `[Float16]` 整块写进 MLMultiArray（长度必须严格相等，不静默截断/补零）。
    private static func writeFloat16(_ array: MLMultiArray, from values: [Float16]) -> Bool {
        let n = array.count
        guard values.count == n else {
            print("[rl-accel] 缓冲长度不符：目标 \(n) vs 来源 \(values.count)")
            return false
        }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
        values.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            ptr.update(from: base, count: n)
        }
        return true
    }

    // MARK: - 输出读取（dtype 无关：一律 .floatValue）

    /// 读 state_token：优先约定输出名；否则在模型输出里找**唯一**长度=256 的输出
    /// （适配 A 域导出命名尚未最终定死的情况）。找不到时写清原因并返回 nil。
    private func readStateToken(_ output: MLFeatureProvider) -> [Float]? {
        if let mv = output.featureValue(for: stateTokenOutputName)?.multiArrayValue,
           mv.count == Self.stateTokenDim {
            return Self.floats(from: mv)
        }
        if let mv = Self.firstMultiArray(in: output, count: Self.stateTokenDim) {
            return Self.floats(from: mv)
        }
        failureReason = "输出里找不到 256 维 state_token（约定名 \(stateTokenOutputName) 未命中，"
            + "且无长度=256 的输出）。可用输出：\(output.featureNames.sorted())"
        return nil
    }

    /// 读纵向/横向 logits。标准布局：vertical[3] + horizontal[3]（与 V3 输出名一致）；
    /// 兼容布局：单一 logits[6] = [vertical(3), horizontal(3)]（A 域若合并导出）。
    private func readLogits(_ output: MLFeatureProvider) -> (v: [Float], h: [Float])? {
        if let v = Self.floats(output, "vertical"), v.count == 3,
           let h = Self.floats(output, "horizontal"), h.count == 3 {
            return (v, h)
        }
        if let fused = Self.floats(output, "logits"), fused.count == 6 {
            return (Array(fused[0..<3]), Array(fused[3..<6]))
        }
        failureReason = "输出里找不到 vertical[3]+horizontal[3] 或 logits[6]。"
            + "可用输出：\(output.featureNames.sorted())"
        return nil
    }

    private static func floats(_ output: MLFeatureProvider, _ name: String) -> [Float]? {
        guard let mv = output.featureValue(for: name)?.multiArrayValue else { return nil }
        return floats(from: mv)
    }

    /// MLMultiArray → [Float]，按真实 dtype 逐元素转换（float16/float32 都正确）。
    private static func floats(from mv: MLMultiArray) -> [Float] {
        var out = [Float](repeating: 0, count: mv.count)
        for i in 0..<mv.count { out[i] = mv[i].floatValue }
        return out
    }

    private static func firstMultiArray(in output: MLFeatureProvider,
                                        count: Int) -> MLMultiArray? {
        for name in output.featureNames.sorted() {
            if let mv = output.featureValue(for: name)?.multiArrayValue, mv.count == count {
                return mv
            }
        }
        return nil
    }

    private static func computeUnitsFromEnvironment() -> MLComputeUnits {
        switch ProcessInfo.processInfo.environment["AURORA_COMPUTE_UNITS"] {
        case "cpu": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "all": return .all
        default: return .cpuAndNeuralEngine
        }
    }
}

// MARK: - 自检（-rl-accel-selftest）

extension StateTokenAccelerator {

    /// 自检入口（由启动器分发 `-rl-accel-selftest` 时调用本 `run()`）。
    ///
    /// 模型存在则跑一帧真实预处理输入，断言 stateToken 维度=256 且非全 NaN；
    /// **仅当模型文件不存在**时明确 SKIP（打印原因，不假装通过）；
    /// 文件存在却加载/推理失败或断言不过 → FAIL。
    ///
    /// - Returns: 0 = PASS 或（文件不存在的）SKIP；1 = 加载失败/推理失败/断言失败。
    static func run() -> Int {
        print("[rl-accel] === state_token 加速器自检（-rl-accel-selftest）===")
        let accel = StateTokenAccelerator()
        let modelPath = accel.modelURL.path
        print("[rl-accel] 模型路径：\(modelPath)")

        guard accel.loadIfNeeded() else {
            let reason = accel.failureReason ?? "模型未就绪"
            // 只有「文件不存在」才是 SKIP（A 域产物未导出，属预期状态）；
            // 文件在却加载失败（模型损坏/权限/格式错）必须 FAIL —— 否则坏模型
            // 会被静默当成 SKIP 变绿，是假绿陷阱。
            if !FileManager.default.fileExists(atPath: modelPath) {
                print("[rl-accel] SKIP：\(reason)")
                print("[rl-accel] SKIP 说明：未找到带 state_token 输出的 CoreML 模型。"
                    + "该模型由 A 域 tools/v3_exp/export_state_token_model.py 导出，"
                    + "产物就绪后重跑本自检即可。本次**未做任何断言**，不冒充通过。")
                return 0
            }
            print("[rl-accel] FAIL：模型文件存在但加载失败 —— \(reason)")
            return 1
        }

        // 用真实预处理链路造一帧（renderNormalized 与生产完全同源），
        // 压入 24 帧环形缓冲（单帧钳位填充），取新→旧窗口。
        guard let image = makeTestImage(width: V3InputContract.hiWidth,
                                        height: V3InputContract.hiHeight),
              let hi = InferenceEngineV3.renderNormalized(image,
                            height: V3InputContract.hiHeight, width: V3InputContract.hiWidth),
              let lo = InferenceEngineV3.renderNormalized(image,
                            height: V3InputContract.loHeight, width: V3InputContract.loWidth) else {
            print("[rl-accel] FAIL：测试帧构造失败（renderNormalized 返回 nil）")
            return 1
        }
        var ring = V3FrameRingBuffer()
        ring.push(hi: hi, lo: lo)

        guard let out = accel.stateTokenAndLogits(hi: ring.hiWindow(),
                                                  lo: ring.loWindow(),
                                                  prevHorizontalClass: 1) else {
            print("[rl-accel] FAIL：推理失败 —— \(accel.failureReason ?? "未知原因")")
            return 1
        }

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ✓ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            } else {
                failures += 1
                print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            }
        }

        check("stateToken 维度 == 256", out.stateToken.count == 256,
              "实际 \(out.stateToken.count)")
        let nanCount = out.stateToken.filter { $0.isNaN }.count
        check("stateToken 非全 NaN", nanCount < out.stateToken.count,
              "NaN \(nanCount)/\(out.stateToken.count)")
        check("vLogits 维度 == 3", out.vLogits.count == 3, "实际 \(out.vLogits.count)")
        check("hLogits 维度 == 3", out.hLogits.count == 3, "实际 \(out.hLogits.count)")

        let finite = out.stateToken.filter { $0.isFinite }
        let mn = finite.min() ?? 0
        let mx = finite.max() ?? 0
        print(String(format: "[rl-accel] state_token: dim=%d finite=%d NaN=%d min=%.4f max=%.4f",
                     out.stateToken.count, finite.count, nanCount, mn, mx))
        print("[rl-accel] vLogits=\(out.vLogits) hLogits=\(out.hLogits)")

        if failures == 0 {
            print("[rl-accel] PASS：state_token 加速器可用（维度与 NaN 断言全过）")
            return 0
        }
        print("[rl-accel] FAIL：\(failures) 项断言未通过")
        return 1
    }

    /// 合成一张确定性测试图（渐变 + 固定 alpha），交给生产同款 renderNormalized。
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * bytesPerRow + x * 4
                data[p]     = UInt8(x & 0xFF)          // R 随 x 渐变
                data[p + 1] = UInt8(y & 0xFF)          // G 随 y 渐变
                data[p + 2] = UInt8((x + y) & 0xFF)    // B 随对角线渐变
                data[p + 3] = 255                      // A 不透明
            }
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
