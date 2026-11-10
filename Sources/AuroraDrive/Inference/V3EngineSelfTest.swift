// V3 引擎自检（`--v3-selftest`）
//
// ══════════════════════════════════════════════════════════════════════════
// 【为什么必须专门自检】V3 引擎存在两类**静默错误**，编译器和普通冒烟都
//   发现不了——模型照常输出、数值看起来也正常，但语义已经错了：
//
//   ① 帧窗口顺序写反
//      训练侧 `src/dataset_v3.py:551-573` 的注释记录过这个事故：
//      曾把窗口写成「旧→新」，结果「踩油门后车前进」被学成**相反因果**。
//      运行时的等价错误是 `hiWindow()/loWindow()` 取错方向或错位——
//      不会有任何报错，只会让车朝着模型认知的"过去"开。
//
//   ② 输入 dtype / 归一化写错
//      `InferenceEngineV3.swift` 文件头红线 1 记录了实测反例：同一全零输入，
//      float32 与 float16 两种 MLMultiArray 得到**完全不同**的输出
//      （vertical `[1.05,3.61,1.57]` vs `[-0.85,0.76,0.15]`）。CoreML 不报错。
//
// 本自检用**可判定**（有明确期望值、能算出对错）的方式覆盖这两类：
//   T1 锯齿帧号编码 → 精确验证 hi/lo 窗口的帧序与错位
//   T2 未填满窗口   → 精确验证"用最早帧填充"（对应训练侧 clamp_frame）
//   T3 纯色图       → 精确验证 /255 归一化与 RGB 平面顺序
//   T4 真实训练帧   → 端到端链路可用（8 路输出有限、收敛）
//   T5 延迟         → 确认在 15FPS(66.7ms) / 30FPS(33.3ms) 预算内
//   T6 黑/白帧对照  → 证明图像真的进了模型（输出随输入变化，非恒定）
//   T7 源帧新鲜度   → 排队旧帧 / 采集停摆 / 重复帧（环形缓冲零件级）
//   T8 argmax 平局  → 与 PyTorch/NumPy 对齐（取第一个最大值）
//   T9 防侧翻兜底   → 高速 super/ultimate 必须 S，不许给油
//   T10 重复帧接线  → `infer()` 层真的拒绝同序号（不是只测 isDuplicate 零件）
//   T11 执行反馈链  → noteExecutedSteer → vehicle_state[6] 的 −1/0/+1 映射
//   T12 finish 覆写 → finish() 不得用预测覆盖执行反馈（**行为**断言）
//
// 【为什么 T10/T11/T12 必须存在】T1–T9 对这三个 P0 的"接线"只有源码字符串
//   匹配（例如断言 finish() 函数体文本里不出现某赋值）。一旦有人重构代码，
//   文本匹配可能仍全绿而行为早已错误 —— 故补上驱动真实 `infer()` 的行为断言。
//
// 【不改业务代码】本文件只新增自检逻辑，不改引擎实现；`renderNormalized`
//   为在模块内可见（非 private）是为了让 T3 能直接比对渲染结果。
// ══════════════════════════════════════════════════════════════════════════

import Foundation
import CoreGraphics
import ImageIO
import CoreML
import AppKit
import QuartzCore

// MARK: - 自检账本

/// 自检结果账本：统计通过/失败项，失败项数即进程退出码（0 = 全过）。
private struct V3SelfTestLedger {
    private(set) var total = 0
    private(set) var failures = 0

    mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        let suffix = detail.isEmpty ? "" : "  — \(detail)"
        if ok {
            print("  ✓ \(name)\(suffix)")
        } else {
            failures += 1
            print("  ✗ \(name)\(suffix)")
        }
    }

    mutating func section(_ title: String) {
        print("\n\(title)")
    }
}

// MARK: - 工具

private func v3LoadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

/// 生成纯色测试图（用于验证归一化与平面顺序）。
private func v3SolidImage(r: CGFloat, g: CGFloat, b: CGFloat, size: Int = 8) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

/// 从环形缓冲的窗口数组里读第 k 帧的首元素（我们把帧号编码在首元素上）。
private func v3FrameMarker(_ window: [Float16], frameIndex k: Int, frameElements: Int) -> Float16 {
    window[k * frameElements]
}


/// 等待一次推理落地（以 `inferenceCount` 单调递增为唯一判据）。
///
/// 【为什么不用 lastResult 判】`lastResult` 在上一次成功后**一直非 nil**，
///   用它判"本帧是否完成"会把旧结果误当新结果。
/// 【为什么 before 必须在 infer() 之前取】否则异步推理可能已抢先完成并自增，
///   快照取到自增后的值 → 永远等不到"再次递增" → 白等满超时。
@MainActor
private func v3DrainOneInference(_ engine: InferenceEngineV3,
                                 before: Int,
                                 timeout: TimeInterval = 0.5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if engine.inferenceCount > before { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    return false
}

/// 泵主 RunLoop 直到条件成立，或超时（返回最后一次判定）。
///
/// 【为什么不能 `Thread.sleep`】本文件要观测的两个量都由 `Task { @MainActor }`
///   回写：判重拒绝（`noteDuplicateFrameSkipped()`）与推理完成（`finish()`）。
///   只有主队列被推进这些任务才会落地；纯 sleep 会让条件永远看不到 ——
///   那是**假红**，且会让人误以为被测逻辑没生效。
@MainActor
private func v3WaitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

// MARK: - P1-3：六键物理键码 + 「只记录、不注入」的控制后端

/// 六个驾驶物理键的键码（与 `ControlEngine.KeyMap` 默认值逐项一致）。
///
/// 【为什么用物理键码而不是 `ControlEngine.Action` 枚举】
///   `Action` 的**枚举名与物理键是反的**（`ControlEngine.swift:35-66`）：
///   `.handbrake` → 键码 49 = **Space**，`.boost` → 键码 56 = **Shift**。
///   断言若按枚举名写，映射被接反时「期望侧一起反」→ 互相掩盖、永远为真。
///   本夹具要断言的正是**物理键集合**，故一律用键码。
private enum V3SixKey {
    static let throttle: CGKeyCode   = 13   // W
    static let brake: CGKeyCode      = 1    // S
    static let steerLeft: CGKeyCode  = 0    // A
    static let steerRight: CGKeyCode = 2    // D
    static let space: CGKeyCode      = 49   // 训练标签 `brake`（src/dataset_v3.py:684）
    static let shift: CGKeyCode      = 56   // 训练标签 `handbrake`（src/dataset_v3.py:684）

    static let all: Set<CGKeyCode> = [throttle, brake, steerLeft, steerRight, space, shift]

    static func name(_ code: CGKeyCode) -> String {
        switch code {
        case throttle:   return "W(13)"
        case brake:      return "S(1)"
        case steerLeft:  return "A(0)"
        case steerRight: return "D(2)"
        case space:      return "Space(49)"
        case shift:      return "Shift(56)"
        default:         return "?(\(code))"
        }
    }

    /// 稳定顺序的字符串（按键码升序）——保证两次运行的输出可逐字对比。
    static func describe(_ keys: Set<CGKeyCode>) -> String {
        guard !keys.isEmpty else { return "∅（全松）" }
        return keys.sorted().map { name($0) }.joined(separator: " + ")
    }
}

/// 按**契约独立推导**「本帧应当被按住的六键集合」。
///
/// 【为什么不能调 `applyCommand` 来算期望值】它是 `private`（`AuroraDriveApp.swift:9337`），
///   且「用被测代码算期望值」等于自证——映射错了会两边一起错。
///   本函数按三方契约重写，作为**独立判据**：
///     · 连续量 → 四向键：死区 ±0.1、油门/刹车互斥（阈值 >0.3）——`AuroraDriveApp.swift:9337-9360`
///     · 四个刹车头 → 修饰键：`AuroraDriveApp.swift:9378-9394`
///       （handbrake 头→Shift、brake 头→Space、super/ultimate **蕴含**两键）
///     · 训练标签口径：`src/dataset_v3.py:684-687`
///       （handbrake←shift 列、brake←space 列、super=shift∧space、ultimate=上者∧s）
///
/// ★ 关键：`result.throttle/brake` 已由引擎做过 ultimate→S 的纵向覆盖
///   （`InferenceEngineV3.swift:608`），故纵向只认 result。
/// ★【本函数是**纯映射**，不含防侧翻兜底】兜底属于**执行端**行为
///   （见 `v3ExpectedExecutedSixKeys`）。QC 段用它算"模型预测了什么"，
///   若这里掺入兜底，指标会把执行层的安全兜底误记成模型预测，两个口径就混了。
private func v3ExpectedSixKeys(result: InferenceResult?, decision: V3Decision) -> Set<CGKeyCode> {
    guard let result else { return [] }        // 无结果 → 上层 .idle → 全松
    var keys: Set<CGKeyCode> = []
    if result.steer > 0.1 {
        keys.insert(V3SixKey.steerRight)
    } else if result.steer < -0.1 {
        keys.insert(V3SixKey.steerLeft)
    }
    if result.throttle > 0.3 {
        keys.insert(V3SixKey.throttle)
    } else if result.brake > 0.3 {
        keys.insert(V3SixKey.brake)
    }
    // super / ultimate 在训练标签里都蕴含 shift=1 且 space=1，故必须一并按住。
    let needShift = decision.handbrakePressed || decision.superBrakePressed || decision.ultimatePressed
    let needSpace = decision.brakePressed || decision.superBrakePressed || decision.ultimatePressed
    if needShift { keys.insert(V3SixKey.shift) }
    if needSpace { keys.insert(V3SixKey.space) }
    return keys
}

/// 按契约推导「本帧**实际会被注入**的六键集合」= 先过防侧翻兜底，再做纯映射。
///
/// 【为什么要单独一层】（P0-2）生产在 `applyCommand` 之前插入
///   `InferenceEngineV3.applyRolloverGuard(...)`：super/ultimate 且高速（未知速度由回退开关决定）
///   → 纵向被强制成 S。Phase B 断言的"实际注入集合"必须包含这一步，
///   否则逐帧比对会与真实注入不一致而假红。
///   兜底函数直接复用被测实现（纯函数，另有独立单测覆盖其边界）。
private func v3ExpectedExecutedSixKeys(result: InferenceResult?, decision: V3Decision,
                                     speedKmh: Double?, speedValid: Bool) -> Set<CGKeyCode> {
    guard let result else { return [] }
    let guarded = InferenceEngineV3.applyRolloverGuard(
        to: ControlCommand(steer: result.steer, throttle: result.throttle,
                           brake: result.brake, confidence: 0),
        decision: decision, speedKmh: speedKmh, speedValid: speedValid)
    let guardedResult = InferenceResult(steer: guarded.steer, throttle: guarded.throttle,
                                        brake: guarded.brake, latencyMs: result.latencyMs)
    return v3ExpectedSixKeys(result: guardedResult, decision: decision)
}

/// 由训练标签（8 个原子键）推导「真人实际按住的六键集合」。
/// 下标口径 = `keyNames`：w=0 / a=1 / s=2 / d=3 / shift=4 / space=5 / super=6 / ultimate=7。
private func v3TruthSixKeys(_ k: [Int]) -> Set<CGKeyCode> {
    var keys: Set<CGKeyCode> = []
    if k[0] == 1 { keys.insert(V3SixKey.throttle) }
    if k[1] == 1 { keys.insert(V3SixKey.steerLeft) }
    if k[2] == 1 { keys.insert(V3SixKey.brake) }
    if k[3] == 1 { keys.insert(V3SixKey.steerRight) }
    if k[4] == 1 || k[6] == 1 || k[7] == 1 { keys.insert(V3SixKey.shift) }
    if k[5] == 1 || k[6] == 1 || k[7] == 1 { keys.insert(V3SixKey.space) }
    return keys
}

/// 一次 tick **消费到的** V3 状态快照（必须在 `state.tick()` 之前取）。
private struct V3TickInputSnapshot {
    let result: InferenceResult?
    let decision: V3Decision
    let resultTime: Date?
}

/// 推进一帧**真实 tick()**；`frame == nil` 表示本帧不供新画面（用于验证输入新鲜度闸门）。
///
/// 【为什么快照必须在 tick 之前取】tick 的控制段消费的是**此刻**的
///   `lastResult` / `lastDecision` / `lastResultTime`。而 V3 的完成回调是
///   `Task { @MainActor in finish(...) }`，只在主 RunLoop 被推进时才落地 ——
///   本函数恰恰是在 tick **之后**才泵 RunLoop。所以「tick 前的快照」与
///   「tick 实际消费的值」严格是同一份；若改到 tick 之后取，会拿到下一帧
///   才产出的新结果，与本次按键集合错配 → 逐帧断言假红或假绿。
///
/// 【必须无条件泵主 RunLoop】若只在「还有预算余额」时才泵，首帧超时后回调
///   永远执行不到 → `inferenceCount` 恒为 0，会被误判成「接线没生效」
///   （`--v3-integration` 首版已实测踩过这个假阴性）。
@MainActor
@discardableResult
private func v3DriveOneTick(_ state: DriveState, frame: CGImage?) -> V3TickInputSnapshot {
    let snapshot = V3TickInputSnapshot(result: state.inferenceEngineV3.lastResult,
                                       decision: state.inferenceEngineV3.lastDecision,
                                       resultTime: state.inferenceEngineV3.lastResultTime)
    let started = CACurrentMediaTime()
    if let frame {
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        state.pushBenchFrameForTickBench(display: image, displayCG: frame, yolo: nil, native: nil)
    }
    state.tick()
    let spent = CACurrentMediaTime() - started
    let budget = 1.0 / 15.0
    RunLoop.current.run(until: Date().addingTimeInterval(max(budget - spent, 0.005)))
    return snapshot
}

// MARK: - 源码级可判定断言的工具

/// 取源码中 `after` 标记之后、`before` 各标记中最早出现者之前的片段。
///
/// 【为什么必须限定片段】同一个字段（如 `previousHorizontalClass`）在
///   `noteExecutedSteer()` 里**应该**被写、在 `finish()` 里**绝不该**被写。
///   全文搜会把正确写法当成错误写法的证据，断言永远为真 —— 那是假绿。
private func v3SourceSlice(_ src: String,
                           after startMarker: String,
                           before endMarkers: [String]) -> String? {
    guard let startRange = src.range(of: startMarker) else { return nil }
    let tail = src[startRange.upperBound...]
    var end = tail.endIndex
    for marker in endMarkers {
        if let r = tail.range(of: marker), r.lowerBound < end { end = r.lowerBound }
    }
    return String(tail[..<end])
}

/// 折叠空白并**剥离行注释**后匹配：源文件被重新排版或加了行尾注释时不应假红。
///
/// ⚠️ 必须剥注释：`AuroraDriveApp.swift:8954-8955` 的释放行带行尾注释
///   （`controlEngine.release(.boost)      // 物理 Shift`）。只折叠空白的话，
///   注释会插在语句之间，期望串永远匹配不上 —— 那是**假红**。
private func v3SourceContainsNormalized(_ src: String, _ needle: String) -> Bool {
    func stripLineComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }
    func fold(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    return fold(stripLineComments(src)).contains(fold(needle))
}

// MARK: - 入口

/// V3 引擎离线自检。
/// - Returns: **失败项数**（0 = 全部通过）。调用方据此决定进程退出码。
@MainActor
@discardableResult
func runV3EngineSelfTest() -> Int {
    let bar = String(repeating: "=", count: 78)
    print(bar)
    print("V3 引擎自检（INT4 / ANE / 24 帧双分辨率窗口）")
    print(bar)

    var ledger = V3SelfTestLedger()
    let hiLen = V3InputContract.hiFrameElements
    let loLen = V3InputContract.loFrameElements

    // ── T1：帧窗口顺序（精确） ──
    ledger.section("[T1] 帧窗口顺序：hi=[t,t−1,t−2] / lo=[t−3…t−23]（新→旧）")
    do {
        var buf = V3FrameRingBuffer()
        // 推 30 帧，把帧号编进每个元素的数值里（第 i 帧全部元素 = i）
        for i in 0..<30 {
            _ = buf.push(hi: [Float16](repeating: Float16(i), count: hiLen),
                         lo: [Float16](repeating: Float16(i), count: loLen))
        }
        let hiW = buf.hiWindow()
        let loW = buf.loWindow()
        // capacity=24，最后推入的是第 29 帧 → 当前帧 t=29
        let hiExpect: [Int] = [29, 28, 27]
        let hiGot = (0..<V3InputContract.hiFrames).map { Int(v3FrameMarker(hiW, frameIndex: $0, frameElements: hiLen)) }
        ledger.check("hi 窗口 [t, t−1, t−2]", hiGot == hiExpect, "期望 \(hiExpect)，实际 \(hiGot)")

        let loExpect: [Int] = (0..<V3InputContract.loFrames).map { 29 - 3 - $0 }
        let loGot = (0..<V3InputContract.loFrames).map { Int(v3FrameMarker(loW, frameIndex: $0, frameElements: loLen)) }
        ledger.check("lo 窗口 [t−3 … t−23]", loGot == loExpect,
                     loGot == loExpect ? "首 3 帧 \(Array(loGot.prefix(3)))，末 3 帧 \(Array(loGot.suffix(3)))"
                                       : "期望首 \(Array(loExpect.prefix(3)))，实际 \(Array(loGot.prefix(3)))")

        // 反向证明：若把窗口误写成旧→新，上面的检查必然失败。
        // 这里额外显式断言"当前帧不在最后一位"，防止两种错误互相掩盖。
        ledger.check("当前帧位于 hi 首索引（而非末位）", hiGot.first == 29,
                     "首索引=\(hiGot.first ?? -1)")
    }

    // ── T2：未填满窗口用最早帧填充 ──
    ledger.section("[T2] 历史不足：按最早帧填充（对应训练侧 clamp_frame）")
    do {
        var buf = V3FrameRingBuffer()
        _ = buf.push(hi: [Float16](repeating: 0, count: hiLen),
                     lo: [Float16](repeating: 0, count: loLen))
        _ = buf.push(hi: [Float16](repeating: 1, count: hiLen),
                     lo: [Float16](repeating: 1, count: loLen))
        let hiW = buf.hiWindow()
        let got = (0..<V3InputContract.hiFrames).map { Int(v3FrameMarker(hiW, frameIndex: $0, frameElements: hiLen)) }
        // 当前帧=1，t−1=0，t−2 越界 → 钳到最早帧 0
        ledger.check("hi 窗口不足时钳位", got == [1, 0, 0], "期望 [1, 0, 0]，实际 \(got)")

        let loW = buf.loWindow()
        let loGot = Set((0..<V3InputContract.loFrames).map {
            Int(v3FrameMarker(loW, frameIndex: $0, frameElements: loLen))
        })
        ledger.check("lo 窗口全越界 → 全为最早帧", loGot == [0], "实际取值集合 \(loGot.sorted())")

        ledger.check("窗口就绪判定（1 帧即可推理）", buf.filled == 2,
                     "filled=\(buf.filled)")
    }

    // ── T3：归一化与平面顺序（精确） ──
    ledger.section("[T3] 图像预处理：/255 归一化 + RGB 平面顺序")
    do {
        // 纯色 RGB(255,128,0) → 期望 R=1.000 / G=0.502 / B=0.000
        if let img = v3SolidImage(r: 1.0, g: 128.0 / 255.0, b: 0.0),
           let out = InferenceEngineV3.renderNormalized(img, height: 4, width: 8) {
            let plane = 4 * 8
            let rV = Float(out[0])
            let gV = Float(out[plane])
            let bV = Float(out[plane * 2])
            ledger.check("R 通道 = 255/255", abs(rV - 1.0) < 0.01, String(format: "%.4f", rV))
            ledger.check("G 通道 = 128/255", abs(gV - 128.0 / 255.0) < 0.01, String(format: "%.4f", gV))
            ledger.check("B 通道 = 0/255", abs(bV - 0.0) < 0.01, String(format: "%.4f", bV))
            // 范围检查：所有值必须落在 [0,1]
            let mn = out.min().map { Float($0) } ?? -1
            let mx = out.max().map { Float($0) } ?? -1
            ledger.check("全部像素 ∈ [0,1]", mn >= 0 && mx <= 1,
                         String(format: "range=[%.3f, %.3f]", mn, mx))
        } else {
            ledger.check("渲染纯色图", false, "renderNormalized 返回 nil")
        }
    }

    // ── T7：P0-1 源帧新鲜度（不依赖模型：直接测环形缓冲 + 判重语义）──
    //
    // 【为什么放在模型加载之前】这三类缺陷是**纯缓冲/时序语义**问题，
    //   与模型权重无关。放前面保证：即便模型缺失，异常语义仍被判定，
    //   不会因 `guard engine.isLoaded` 提前 return 而"看起来全过"。
    ledger.section("[T7] P0-1 源帧新鲜度：排队旧帧 / 采集停摆 / 重复帧")
    do {
        // 场景一：排队旧帧 —— 采集时刻必须是**源帧**时刻，不能是消费时刻。
        //   构造：按 15Hz 填满 24 帧历史（t0 … t0+23/15），最后再压入一帧
        //   **真实采集于 t0+2.0s** 的画面（它可能因主线程阻塞很晚才被消费）。
        //   窗口跨度必须等于 2.0s（真实采集间隔），而不是"消费节拍"的假象。
        //   ⚠️ 必须填满 capacity：`windowSpanSeconds()` 在未填满时返回 nil
        //     （钳位填充不具时间语义），只压 2 帧会拿到 nil → 假红。
        var buf = V3FrameRingBuffer()
        let capacity = V3InputContract.totalFrames
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(capacity - 1) {
            _ = buf.push(hi: [Float16](repeating: Float16(i), count: hiLen),
                         lo: [Float16](repeating: Float16(i), count: loLen),
                         capturedAt: t0.addingTimeInterval(Double(i) / 15.0),
                         sequence: i + 1)
        }
        // 最新帧：真实采集时刻 t0+2.0s（若错用消费时刻，跨度会算成 ~23/15≈1.53s）
        _ = buf.push(hi: [Float16](repeating: 99, count: hiLen),
                     lo: [Float16](repeating: 99, count: loLen),
                     capturedAt: t0.addingTimeInterval(2.0),
                     sequence: capacity)
        let span = buf.windowSpanSeconds() ?? -1
        ledger.check("排队旧帧：窗口跨度 = 真实采集间隔（2.0s，非消费节拍 1.53s）",
                     abs(span - 2.0) < 0.001,
                     String(format: "span=%.3fs（应为 2.000s）", span))

        // 场景二：采集停摆 —— 同一源帧被重复送入时，`isDuplicate` 必须为真，
        //   从而拒绝入窗（否则窗口被同一帧刷满，伪装成滚动视频）。
        var buf2 = V3FrameRingBuffer()
        _ = buf2.push(hi: [Float16](repeating: 7, count: hiLen),
                      lo: [Float16](repeating: 7, count: loLen),
                      capturedAt: t0, sequence: 42)
        ledger.check("采集停摆：同一源帧序号被判重（拒绝再次入窗）",
                     buf2.isDuplicate(sequence: 42),
                     "sequence=42 已入窗 → 再来必须拒绝")
        ledger.check("采集停摆：新源帧序号不被误判为重",
                     !buf2.isDuplicate(sequence: 43),
                     "sequence=43 是新帧")
        ledger.check("未提供序号（自检压栈）一律不判重", !buf2.isDuplicate(sequence: nil),
                     "nil = 无序号语义 → 不拦")

        // 场景三：重复帧 —— 模拟 24 次重复提交同一帧：只有首次入窗，
        //   其余被 `isDuplicate` 拦下，`filled` 不得增长（窗口不退化）。
        var buf3 = V3FrameRingBuffer()
        var accepted = 0, rejected = 0
        for _ in 0..<24 {
            if buf3.isDuplicate(sequence: 99) { rejected += 1; continue }
            if buf3.push(hi: [Float16](repeating: 3, count: hiLen),
                         lo: [Float16](repeating: 3, count: loLen),
                         capturedAt: t0, sequence: 99) { accepted += 1 }
        }
        ledger.check("重复帧：24 次重复提交只入窗 1 次",
                     accepted == 1 && rejected == 23 && buf3.filled == 1,
                     "accepted=\(accepted) rejected=\(rejected) filled=\(buf3.filled)")

        // 场景三续：重复帧之后换新序号，窗口应恢复滚动（不是永久卡死）。
        //
        // ⚠️【断言口径】`isDuplicate` 的语义是「该序号 == 最近一次**已入窗**的序号」，
        //   所以 push(100) 之后再问 `isDuplicate(100)` 必然是 true（100 已是最新帧）。
        //   要验证"能恢复滚动"，正确判据是：push 成功（filled 增长）+ **下一个**序号
        //   不被判重。写成 `!isDuplicate(100)` 是错的口径（已实测误报失败）。
        _ = buf3.push(hi: [Float16](repeating: 4, count: hiLen),
                      lo: [Float16](repeating: 4, count: loLen),
                      capturedAt: t0.addingTimeInterval(0.066), sequence: 100)
        ledger.check("重复帧后新序号仍能正常入窗（filled 增长且 101 不被判重）",
                     buf3.filled == 2 && !buf3.isDuplicate(sequence: 101),
                     "filled=\(buf3.filled)，isDuplicate(101)=\(buf3.isDuplicate(sequence: 101))")
    }

    // ── T8：P2 argmax 平局规则必须与 PyTorch/NumPy 一致（第一个最大值）──
    ledger.section("[T8] P2 平局 argmax：与 PyTorch/NumPy 对齐（取第一个最大值）")
    do {
        // 这些用例都是 Python `np.argmax` 的确定结果，可逐条对照。
        let cases: [([Float], Int, String)] = [
            ([0, 1, 1], 1, "[0,1,1] → 1（旧实现错返 2）"),
            ([1, 1, 0], 0, "[1,1,0] → 0"),
            ([0, 1, 0], 1, "[0,1,0] → 1（唯一最大）"),
            ([1, 0, 1], 0, "[1,0,1] → 0（首尾相等取首）"),
            ([2, 2, 2], 0, "全相等 → 0"),
            ([0, 0, 1], 2, "[0,0,1] → 2（唯一最大在末位）"),
            ([5, 0, 0], 0, "[5,0,0] → 0"),
        ]
        for (input, expected, desc) in cases {
            let got = InferenceEngineV3.argmax3(input)
            ledger.check("argmax3 \(desc)", got == expected, "期望 \(expected)，实际 \(got)")
        }
        // 关键回归：平局绝不能再返回"最后一个最大"（旧实现 [0,1,1]→2）
        ledger.check("argmax3 平局不取最后一个最大（回归 [0,1,1]≠2）",
                     InferenceEngineV3.argmax3([0, 1, 1]) != 2,
                     "与 Python 离线评估同规则，避免 Swift/Python 解码分叉")
    }

    // ── T9：P0-2 防侧翻兜底（引擎侧纯逻辑，不依赖模型）──
    ledger.section("[T9] P0-2 防侧翻兜底：高速 super/ultimate 必须 S，不许给油")
    do {
        func makeDecision(super sb: Bool, ultimate ul: Bool) -> V3Decision {
            V3Decision(verticalClass: 0, horizontalClass: 1,   // 模型给 W
                       brakePressed: false, handbrakePressed: false,
                       superBrakePressed: sb, ultimatePressed: ul,
                       confidence: 0.9, risk: 0.1)
        }
        // 高速 + super：给油必须被压成 S
        let g1 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: 80, speedValid: true)
        ledger.check("高速 + super_brake：给油→S（throttle=0/brake=1）",
                     g1.throttle == 0 && g1.brake == 1)
        // 高速 + ultimate：同样强制 S
        let g2 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: false, ultimate: true),
            speedKmh: 80, speedValid: true)
        ledger.check("高速 + ultimate：给油→S", g2.throttle == 0 && g2.brake == 1)
        // 车速未知：只松油门，不添加模型未要求的 S。
        let g3 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: nil, speedValid: false, unknownSpeedBrake: false)
        ledger.check("车速未知 + super_brake：松油门、不新增 S",
                     g3.throttle == 0 && g3.brake == 0)
        // speedValid=false 即使有数值也按未知（保守）
        let g3b = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: 5, speedValid: false, unknownSpeedBrake: false)
        ledger.check("speedValid=false：数值不可信 → 松油门、不新增 S", g3b.throttle == 0 && g3b.brake == 0)
        let legacy = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: nil, speedValid: false, unknownSpeedBrake: true)
        ledger.check("未知速度回退开关：恢复强制 S", legacy.throttle == 0 && legacy.brake == 1)
        let modelBrake = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 0, brake: 1, confidence: 0),
            decision: makeDecision(super: false, ultimate: true),
            speedKmh: nil, speedValid: false, unknownSpeedBrake: false)
        ledger.check("未知速度不解除模型/ultimate 已有 S", modelBrake.brake == 1)
        let nonFinite = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: -1, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: .nan, speedValid: true, unknownSpeedBrake: false)
        ledger.check("非有限速度按未知处理并保留横向", nonFinite.throttle == 0 && nonFinite.brake == 0 && nonFinite.steer == -1)
        // 低速：兜底不介入（保留原纵向），避免低速解锁误伤
        let g4 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: 10, speedValid: true)
        ledger.check("低速 + super_brake：兜底不介入（给油保留）",
                     g4.throttle == 1 && g4.brake == 0)
        // 无 super/ultimate：任何车速都不改纵向（其余路径一字不动）
        let g5 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 0, throttle: 1, brake: 0, confidence: 0),
            decision: V3Decision(verticalClass: 0, horizontalClass: 1,
                                 brakePressed: true, handbrakePressed: false,
                                 superBrakePressed: false, ultimatePressed: false,
                                 confidence: 0.9, risk: 0.1),
            speedKmh: 120, speedValid: true)
        ledger.check("无 super/ultimate：不干预纵向（不误伤普通刹车/给油）",
                     g5.throttle == 1 && g5.brake == 0)
        // 横向不被兜底改动
        let g6 = InferenceEngineV3.applyRolloverGuard(
            to: ControlCommand(steer: 1, throttle: 1, brake: 0, confidence: 0),
            decision: makeDecision(super: true, ultimate: false),
            speedKmh: 80, speedValid: true)
        ledger.check("兜底只改纵向，横向 steer 原样保留", g6.steer == 1)
    }

    ledger.section("[T13] 保留降级安全链与恢复")
    do {
        let stm = DegradeStateMachine()
        func step(_ main: Bool, _ assist: Bool, _ health: Double) -> DriveMode {
            stm.update(m9Live: main, assistLive: assist, health: health, warmingUp: false,
                       speedKmh: 0, speedValid: false, dt: 1.0 / 15,
                       sportMode: false, forceRule: false)
        }
        ledger.check("e2e 不要求副驾保活", step(true, false, 0.9) == .e2e)
        ledger.check("主驾失联降 yolo", step(false, false, 0.9) == .yolo)
        ledger.check("副驾未就绪继续降 rule", step(false, false, 0.9) == .rule)
        ledger.check("副驾恢复回 yolo", step(false, true, 0.9) == .yolo)
        ledger.check("主驾恢复回 e2e", step(true, true, 0.9) == .e2e)
        ledger.check("低健康度仍触发降级", step(true, true, 0.4) == .yolo)
    }

    // ── T4/T5/T6：真实模型与真实训练帧 ──
    ledger.section("[T4] 模型加载 + 真实训练帧端到端")
    let engine = InferenceEngineV3()
    engine.loadIfNeeded()
    ledger.check("模型加载", engine.isLoaded, engine.errorMessage ?? "models/\(V3InputContract.modelFileName).mlmodelc")

    guard engine.isLoaded else {
        print("\n模型未加载，跳过 T5/T6。失败项 \(ledger.failures)/\(ledger.total)")
        return ledger.failures
    }

    // 找一段真实的连续帧（与训练同源）
    //
    // ⚠️ 【为什么有两条来源】实测发现 `data/lean_clips` 是指向
    //    `/Volumes/系统/lean_clips` 的**符号链接**（外接卷）。本进程没有该卷的
    //    TCC 读权限 —— `FileManager.fileExists` 返回 true（只 stat 到链接本身），
    //    但 `contentsOfDirectory` 抛 "The file “lean_clips” couldn’t be opened"。
    //    若只用 `try?` 吞掉异常，现象就是"找到 0 帧"，极易误判成数据缺失。
    //    → 先试项目内路径；不可读时回退到 /tmp 下的同源副本（由测试脚本预置，
    //      已用 md5 校验与原帧逐字节一致）。
    let root = AuroraPaths.projectRoot()
    let searchDirs: [URL] = [
        root.appendingPathComponent("data/lean_clips"),
        URL(fileURLWithPath: "/tmp/v3_selftest_frames"),
    ]
    var frameURLs: [URL] = []
    for dir in searchDirs {
        if !frameURLs.isEmpty { break }
        print("    尝试帧来源: \(dir.path)  存在=\(FileManager.default.fileExists(atPath: dir.path))")
        // 情形 A：目录本身就是一帧序列（/tmp 副本，直接含 *.jpg）
        if let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                    includingPropertiesForKeys: nil) {
            let jpgs = files.filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if jpgs.count >= 30 {
                frameURLs = Array(jpgs.prefix(30))
                print("    ✓ 取到 \(jpgs.count) 帧（平铺目录）")
                continue
            }
        }
        // 情形 B：clip 目录（其下有 <clip>/frames/*.jpg）
        do {
            let clips = try FileManager.default.contentsOfDirectory(at: dir,
                                                                    includingPropertiesForKeys: nil)
            for clip in clips.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let framesDir = clip.appendingPathComponent("frames")
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: framesDir, includingPropertiesForKeys: nil) else { continue }
                let jpgs = files.filter { $0.pathExtension.lowercased() == "jpg" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if jpgs.count >= 30 {
                    let start = min(200, max(0, jpgs.count - 30))
                    frameURLs = Array(jpgs[start..<(start + 30)])
                    print("    ✓ 使用 \(clip.lastPathComponent) 的第 \(start)…\(start + 29) 帧")
                    break
                }
            }
        } catch {
            // 如实打印底层原因（权限/沙盒/路径），不再用 try? 静默成"0 帧"
            print("    ✗ 枚举失败: \(error.localizedDescription)")
        }
    }
    ledger.check("找到真实连续帧", frameURLs.count >= 30, "\(frameURLs.count) 帧")

    if frameURLs.count >= 30 {
        // 逐帧喂入（每帧等推理完成，避免 isInferencing 跳过）
        var latencies: [Double] = []
        for url in frameURLs {
            guard let cg = v3LoadCGImage(url) else { continue }
            let before = engine.inferenceCount
            engine.infer(image: cg)
            if v3DrainOneInference(engine, before: before), let r = engine.lastResult {
                latencies.append(r.latencyMs)
            }
        }

        ledger.check("端到端产出结果", engine.inferenceCount > 0,
                     "成功 \(engine.inferenceCount)/\(frameURLs.count) 帧")

        if let last = engine.lastResult {
            let d = engine.lastDecision
            let finite = last.steer.isFinite && last.throttle.isFinite
                && last.brake.isFinite && d.confidence.isFinite && d.risk.isFinite
            ledger.check("输出全部有限（非 NaN/Inf）", finite)
            ledger.check("confidence ∈ [0,1]", d.confidence >= 0 && d.confidence <= 1,
                         String(format: "%.4f", d.confidence))
            ledger.check("risk ∈ [0,1]", d.risk >= 0 && d.risk <= 1,
                         String(format: "%.4f", d.risk))
            ledger.check("分类编号合法", (0...2).contains(d.verticalClass) && (0...2).contains(d.horizontalClass),
                         "v=\(d.verticalClass) h=\(d.horizontalClass)")
            print("    末帧决策: \(d.debugSummary)")
            print(String(format: "    steer=%.2f throttle=%.2f brake=%.2f",
                         last.steer, last.throttle, last.brake))
        } else {
            ledger.check("读取末帧结果", false, "lastResult 为 nil")
        }

        // ── T5：延迟 ──
        ledger.section("[T5] 端到端延迟（预处理 + 推理，串行）")
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            let mean = latencies.reduce(0, +) / Double(latencies.count)
            let p50 = sorted[sorted.count / 2]
            let mx = sorted.last ?? 0
            print(String(format: "    mean=%.2fms  p50=%.2fms  max=%.2fms  n=%d",
                         mean, p50, mx, latencies.count))
            ledger.check("满足 30FPS 预算（≤33.3ms）", p50 <= 33.3, String(format: "p50=%.2fms", p50))
            ledger.check("满足 15FPS 预算（≤66.7ms）", p50 <= 66.7, String(format: "p50=%.2fms", p50))
        } else {
            ledger.check("采集延迟样本", false, "无样本")
        }

        // ── T6：黑 / 白帧对照（证明图像真的进了模型） ──
        ledger.section("[T6] 黑帧 vs 白帧：输出必须随输入变化（非恒定）")
        func runSolid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (Double, Double)? {
            let e = InferenceEngineV3()
            e.loadIfNeeded()
            guard e.isLoaded, let img = v3SolidImage(r: r, g: g, b: b) else { return nil }
            // 喂满 24 帧，确保窗口填满（避免钳位影响）
            for _ in 0..<26 {
                let before = e.inferenceCount
                e.infer(image: img)
                _ = v3DrainOneInference(e, before: before)
            }
            let d = e.lastDecision
            return (d.confidence, d.risk)
        }
        if let black = runSolid(0, 0, 0), let white = runSolid(1, 1, 1) {
            let dConf = abs(black.0 - white.0)
            let dRisk = abs(black.1 - white.1)
            print(String(format: "    黑帧 conf=%.4f risk=%.4f", black.0, black.1))
            print(String(format: "    白帧 conf=%.4f risk=%.4f", white.0, white.1))
            ledger.check("输出随输入变化（图像链路真的接通）", dConf > 0.01 || dRisk > 0.01,
                         String(format: "Δconf=%.4f Δrisk=%.4f", dConf, dRisk))
        } else {
            ledger.check("黑/白对照", false, "推理失败")
        }
    }

    // ── T10：P0-1 重复帧在 infer() 层被真正拒绝 ──
    //
    // 【为什么不能只测 `isDuplicate`】T7 测的是 `V3FrameRingBuffer.isDuplicate`
    //   这个**零件**；而真正决定"这帧要不要算"的是 `infer()` 里那道判重门
    //   （`InferenceEngineV3.swift` 约 :736-739）。零件对、接线错（例如忘了传
    //   `sequence:`、或判重后忘了 return）时，T7 依然全绿而生产仍在重复推理。
    //   故本组必须走**公开的 `infer(image:capturedAt:sequence:)`**，并观测引擎
    //   已有的可观测计数器：`inferenceCount`（成功推理帧数，:394）与
    //   `duplicateFrameCount`（被判重拒绝帧数，:468）—— 均为 `private(set)`，
    //   无需新增任何 API。
    ledger.section("[T10] P0-1 重复帧：infer() 层真正拒绝（不是只测 isDuplicate 零件）")
    do {
        let eng = InferenceEngineV3()
        eng.loadIfNeeded()
        if eng.isLoaded, let img = v3SolidImage(r: 0.2, g: 0.4, b: 0.6, size: 64) {
            // ① 先让一帧真正入窗，建立「最近已入窗序号」基线。
            let base = eng.inferenceCount
            eng.infer(image: img, sequence: 700)
            let firstAccepted = v3WaitUntil { eng.inferenceCount > base }
            ledger.check("T10 首帧（序号 700）正常入窗并推理", firstAccepted,
                         "inferenceCount \(base) → \(eng.inferenceCount)")

            // ② 同一序号再次提交 → 必须被拒绝：**不产生新推理**，且判重计数递增。
            //    若判重门被拆掉/漏传 sequence，第二次会真的再推理一次 → 本项变红。
            let dupBefore = eng.duplicateFrameCount
            let countBeforeDup = eng.inferenceCount
            eng.infer(image: img, sequence: 700)
            let dupSeen = v3WaitUntil(timeout: 0.5) { eng.duplicateFrameCount > dupBefore }
            // 额外静置一会，给"错误实现"足够时间真的跑出一次推理，避免假绿。
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            let countAfterDup = eng.inferenceCount
            ledger.check("T10 同序号重复提交被判重（duplicateFrameCount 递增）", dupSeen,
                         "duplicateFrameCount \(dupBefore) → \(eng.duplicateFrameCount)")
            ledger.check("T10 同序号重复提交不产生新推理（关键：拒绝发生在推理前）",
                         countAfterDup == countBeforeDup,
                         "inferenceCount 应保持 \(countBeforeDup)，实际 \(countAfterDup)")

            // ③ 不同序号 → 必须**真正推理**。
            //    这一例专门防「永远拒绝」的错误实现（例如把 isDuplicate 写成恒真、
            //    或把 sequence 比较写成 `!=`）：那种实现能让 ② 全绿，但 ③ 会红。
            let countBeforeNew = eng.inferenceCount
            eng.infer(image: img, sequence: 701)
            let newAccepted = v3WaitUntil { eng.inferenceCount > countBeforeNew }
            ledger.check("T10 新序号必须真正推理（防『永远拒绝』的错误实现）", newAccepted,
                         "inferenceCount \(countBeforeNew) → \(eng.inferenceCount)")

            // ④ 不传序号（调用方无序号语义，如自检直接喂图）→ 不参与判重，必须接受。
            //    防「把 nil 也当成重复」的错误实现（那会让所有旧调用点静默停算）。
            let countBeforeNil = eng.inferenceCount
            eng.infer(image: img, sequence: nil)
            let nilAccepted = v3WaitUntil { eng.inferenceCount > countBeforeNil }
            ledger.check("T10 未传序号不参与判重（保持旧语义）", nilAccepted,
                         "inferenceCount \(countBeforeNil) → \(eng.inferenceCount)")
        } else {
            ledger.check("T10 模型与合成帧就绪", false,
                         eng.errorMessage ?? "v3SolidImage 返回 nil")
        }
    }

    // ── T11：P0-3 执行反馈真的进入 vehicle_state[6] ──
    //
    // 【这是整条链的核心不变量】训练侧 `vehicle_state[6]` = **上一帧实际按下的
    //   A/D**（A→−1 / D→+1 / 其余 0，`dataset_v3.py:630-638`）。实现分两段：
    //     · `noteExecutedSteer()` 把连续量折算成类别 0/1/2（:652-660）；
    //     · `makeProvider()` 把类别映射成 −1/0/+1 写进 `vehicle_state[6]`（:1190 起）。
    //   若这段映射写反（0↔2 对调）、或写错下标（写成 [0] 而不是 [6]），
    //   模型收到的"上一动作"就与训练分布相反 —— 车会朝反方向修方向。
    //   现有 41 项对此**零覆盖**（全是源码字符串匹配），故必须做行为断言。
    ledger.section("[T11] P0-3 执行反馈：noteExecutedSteer → vehicle_state[6]（−1/0/+1）")
    do {
        let eng = InferenceEngineV3()
        eng.loadIfNeeded()
        if eng.isLoaded, let img = v3SolidImage(r: 0.5, g: 0.5, b: 0.5, size: 64) {
            // (noteExecutedSteer 入参, 期望写进 state[6] 的值, 语义名)
            let cases: [(Double, Float, String)] = [
                (-1.0, -1, "A → −1"),
                (1.0, 1, "D → +1"),
                (0.0, 0, "NONE → 0"),
            ]
            var seq = 800
            for (steer, expect, label) in cases {
                eng.noteExecutedSteer(steer)
                let before = eng.inferenceCount
                eng.infer(image: img, sequence: seq)
                seq += 1
                let finished = v3WaitUntil { eng.inferenceCount > before }
                let state = eng.vehicleStateForTest()
                let got: Float = state.count == V3InputContract.stateDim
                    ? state[V3InputContract.steerStateIndex]
                    : Float.nan
                ledger.check("T11 noteExecutedSteer(\(label)) → vehicle_state[6] == \(expect)",
                             finished && got == expect,
                             "state[6]=\(got)（期望 \(expect)），state 长度=\(state.count)"
                             + (finished ? "" : "，推理未完成"))
            }
            // 其余 7 维必须恒 0（训练口径：只有 [6] 有意义）。
            // 防「把 A/D 写成其他维度」的错误实现 —— 那种实现下 state[6] 可能恰好是 0，
            // 单看上面三例会漏判，故必须显式核对"其余维恒零"。
            let state = eng.vehicleStateForTest()
            let otherDimsZero = state.count == V3InputContract.stateDim
                && (0..<V3InputContract.stateDim)
                    .filter { $0 != V3InputContract.steerStateIndex }
                    .allSatisfy { state[$0] == 0 }
            // 描述串先算成局部变量再插入：三层嵌套插值里写 `\(...)` 容易把转义层数
            // 写错（本次就因此编译失败），拆开后可读且不会踩转义。
            let otherDimsText = state.enumerated()
                .filter { $0.offset != V3InputContract.steerStateIndex }
                .map { "\($0.offset):\($0.element)" }
                .joined(separator: ",")
            ledger.check("T11 vehicle_state 其余 7 维恒 0（训练口径只写 [6]）", otherDimsZero,
                         "其余维=\(otherDimsText)")
        } else {
            ledger.check("T11 模型与合成帧就绪", false, eng.errorMessage ?? "v3SolidImage 返回 nil")
        }
    }

    // ── T12：P0-3 finish() 不得覆写执行反馈状态（行为断言） ──
    //
    // 【为什么源码断言不够】现有实现只断言 finish() 的**函数体文本**里不出现
    //   `previousHorizontalClass =`。重构（例如抽成 `self.previousHorizontalClass
    //   = decision.horizontalClass`、或经属性包装器/辅助方法写入）后文本匹配失效，
    //   断言仍全绿而行为已经退化成"用预测覆盖实际执行"。
    //   本组直接观测状态：先设非零执行反馈 → 走完整 finish() → 断言**值没被改**。
    ledger.section("[T12] P0-3 finish() 不覆写执行反馈（行为断言，非源码文本）")
    do {
        let eng = InferenceEngineV3()
        eng.loadIfNeeded()
        if eng.isLoaded, let img = v3SolidImage(r: 0.3, g: 0.3, b: 0.3, size: 64) {
            // 【为什么必须构造"派发后回填"的竞态，而不是"设好再等 finish"】
            //   `vehicle_state[6]` 本身就是模型输入，喂什么模型就容易预测什么
            //   （`docs/v3-design/05-review-claude.md:136` 记录的正是这条捷径）。
            //   实测（首版 T12 被自己的判别力自检抓住）：设 A(−1) 模型预测 h=0、
            //   设 D(+1) 模型预测 h=2 —— 预测值与我设定的类别**恰好相等**，于是
            //   "覆写"与"没覆写"在结果上完全同值，断言必然假绿，测不出任何东西。
            //   真正的失效序列（见 `InferenceEngineV3.swift` 约 :935-944 注释）是：
            //     tick n 派发推理（快照 state）→ 注入后回填**实际执行**动作 →
            //     finish() 用**预测**覆盖掉刚回填的值
            //   故这里精确复现它：先按"派发时刻"的状态快照发起 infer，再在 finish
            //   落地**之前**回填执行反馈。若 finish() 真的写入预测，该值就被改掉 → 变红。
            //   【时机为什么确定】`infer()` 在 :729 **同步**读取 `previousHorizontalClass`
            //   快照后才派发；而 finish 是 `Task { @MainActor }`，只有泵 RunLoop 才执行。
            //   所以 infer() 返回后回填：必定晚于快照、早于 finish —— 不依赖运气。
            let combos: [(Double, Double, String)] = [
                (0.0, 1.0, "派发时 NONE → finish 前回填 D(+1)"),
                (0.0, -1.0, "派发时 NONE → finish 前回填 A(−1)"),
                (1.0, -1.0, "派发时 D → finish 前回填 A(−1)"),
                (-1.0, 1.0, "派发时 A → finish 前回填 D(+1)"),
            ]
            func className(_ c: Int) -> String { ["A(0)", "NONE(1)", "D(2)"][max(0, min(2, c))] }
            var seq = 900
            var discriminatingCase: String? = nil
            for (dispatchState, backfill, label) in combos {
                eng.noteExecutedSteer(dispatchState)
                let before = eng.inferenceCount
                eng.infer(image: img, sequence: seq)
                seq += 1
                // ★ 关键一步：推断已派发、尚未完成时回填"实际执行"动作。
                eng.noteExecutedSteer(backfill)
                let expectedClass = backfill > 0.1 ? 2 : (backfill < -0.1 ? 0 : 1)
                let finished = v3WaitUntil { eng.inferenceCount > before }
                let after = eng.previousHorizontalClassForTest
                let predicted = eng.lastDecision.horizontalClass
                ledger.check("T12 \(label)：finish() 后执行反馈仍为 \(className(expectedClass))",
                             finished && after == expectedClass,
                             "回填 \(className(expectedClass)) → finish 后 \(className(after))"
                             + "，本帧预测 \(className(predicted))"
                             + (finished ? "" : "，推理未完成"))
                // 判别力：预测类别 ≠ 回填类别时，"覆写"必然改变该值 → 本用例有效。
                if finished && predicted != expectedClass { discriminatingCase = label }
            }
            ledger.check("T12 存在具备判别力的用例（预测类别 ≠ 回填类别）",
                         discriminatingCase != nil,
                         discriminatingCase.map { "有效用例：\($0)" }
                         ?? "全部组合的预测都恰好等于回填值 —— 覆写缺陷无法被发现，需改用其他激励")
        } else {
            ledger.check("T12 模型与合成帧就绪", false, eng.errorMessage ?? "v3SolidImage 返回 nil")
        }
    }

    print("\n" + bar)
    print("V3 引擎自检：\(ledger.total - ledger.failures)/\(ledger.total) 通过"
          + (ledger.failures == 0 ? "  ✓ 全部通过" : "  ✗ 失败 \(ledger.failures) 项"))
    print(bar)
    return ledger.failures
}

// MARK: - 集成夹具：验证 V3 真的在真实 tick() 循环里被驱动

/// 离屏集成夹具（`--v3-integration`）。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 【为什么需要它 —— 这不是重复测试】
///   `--v3-selftest` 是**直接调 `engine.infer()`**，证明的是「引擎本身能算」。
///   但它**证明不了接线**：`--tick-bench` 实测 `tick.total p50=0.014ms`，
///   近乎为零 —— 因为该夹具自己注明 `isDriving=false`（`PerfSelfTest.swift:795`），
///   tick 在 `guard isDriving`（`AuroraDriveApp.swift:7964`）处就早退了，
///   **决策段与 V3 推理段整段都没执行**。
///   也就是说："引擎能算" ≠ "引擎被接进主循环并在驾驶"。本夹具补的正是后者。
///
/// 【安全（不可协商）】两条注入路径都堵死：
///   ① `applyCommand` → 由 `controlDisabled=true` 让 `mayInjectKeys` 为假；
///   ② `releaseAllIfNeeded()` → 由 `benchSuppressAllInjection=true` 硬开关挡住
///      （否则 process 刚起时 `lastFullReleaseAt==0`，首帧必走 `releaseAll()` 真发 keyUp）。
///   并且调用项目既有的 `benchInjectionHazardForTickBench` 断言复核，
///   不通过就**拒绝运行**。
/// ══════════════════════════════════════════════════════════════════════════
@MainActor
@discardableResult
func runV3IntegrationTest(seconds: Double = 6.0, frameDir: String? = nil) -> Int {
    let bar = String(repeating: "=", count: 78)
    print(bar)
    print("V3 集成夹具：真实 tick() 循环是否真的驱动 V3（零按键注入）")
    print(bar)

    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        let s = detail.isEmpty ? "" : "  — \(detail)"
        if ok { print("  ✓ \(name)\(s)") } else { failures += 1; print("  ✗ \(name)\(s)") }
    }

    let state = DriveState()

    // ── 安全断言：两条注入路径必须都堵死 ──
    state.controlDisabled = true
    state.benchSuppressAllInjection = true
    state.isDriving = true            // 让决策段执行（这是本夹具的核心）
    if let hazard = state.benchInjectionHazardForTickBench {
        print("  ✗ 安全断言失败：\(hazard)")
        print("     拒绝继续 —— 集成夹具绝不允许注入真实按键。")
        return 1
    }
    print("  ✅ 安全断言通过（controlDisabled + benchSuppressAllInjection 双重堵死）")

    // ── 等模型加载 ──
    state.inferenceEngineV3.loadIfNeeded()
    check("V3 模型加载", state.inferenceEngineV3.isLoaded,
          state.inferenceEngineV3.errorMessage ?? "models/\(V3InputContract.modelFileName).mlmodelc")
    guard state.inferenceEngineV3.isLoaded else {
        print("\n模型未加载，无法验证集成。失败 1 项")
        return failures
    }

    // ── 预加载所有引擎（否则首帧 tick 里同步加载会吃掉近 2 秒）──
    //
    // 【为什么必须预热】实测首帧 `tick()` 会懒加载 V2 的 enc/ctl、yolopx、
    //   yolo26s 等模型，单帧耗 **1959ms**（日志 tickGap=1959ms）。
    //   而夹具按 1/15s 预算控制 RunLoop 泵，首帧一旦超预算就不会泵 →
    //   V3 的异步完成回调（`Task { @MainActor }`）永远执行不到 →
    //   `inferenceCount` 恒为 0，看起来像"V3 没被驱动"，实为夹具假阴性。
    print("  预加载其余引擎（避免首帧 tick 阻塞）……")
    state.inferenceEngineV2.loadIfNeeded()
    state.yolopxEngine.loadIfNeeded()
    state.yoloEngine.loadIfNeeded()
    state.assistEngine.loadIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    // ── 帧源：**真实训练帧优先**，无则退化成合成渐变图 ──
    //
    // 【为什么必须能用真实帧】合成渐变图只能证明"链路通"，证明不了"开得像不像人"：
    //   24 帧窗口被同一张静态渐变填满 → 模型输出必然恒定 → 看不出时序/语义是否正确。
    //   喂训练集里的**连续真实帧**，才能在同一套生产 tick() 里同时验证
    //   「实时窗口滚动 + V3 推理 + 输出到命令」整条链。
    var realFrames: [CGImage] = []
    if let frameDir {
        let d = URL(fileURLWithPath: frameDir)
        if let files = try? FileManager.default.contentsOfDirectory(at: d,
                                                                  includingPropertiesForKeys: nil) {
            realFrames = files
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { v3LoadCGImage($0) }
        }
        print("  真实帧源：\(frameDir) → \(realFrames.count) 帧")
        if realFrames.isEmpty {
            print("  ✗ 指定了 --dir 但没读到任何 jpg")
            return failures + 1
        }
    }

    let fallbackCG: CGImage
    if let first = realFrames.first {
        fallbackCG = first
    } else {
        let size = 640
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let made = { () -> CGImage? in
                  ctx.setFillColor(red: 0.35, green: 0.45, blue: 0.55, alpha: 1.0)
                  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                  ctx.setFillColor(red: 0.75, green: 0.7, blue: 0.55, alpha: 1.0)
                  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 3))
                  return ctx.makeImage()
              }() else {
            print("  ✗ 合成帧失败")
            return failures + 1
        }
        fallbackCG = made
    }

    // ── 驱动真实 tick() ──
    // 有真实帧时，逐帧推进（每 tick 一张），使 24 帧窗口真正滚动；
    // 否则按秒数反复推同一张合成图。
    let driveFrames = realFrames.isEmpty ? Int.max : realFrames.count
    print("\n  驱动真实 tick()（与生产同构 15Hz）……")
    let before = state.inferenceEngineV3.inferenceCount
    var frames = 0
    var decisions: [V3Decision] = []      // 逐帧收集，末尾统计分布（判断是否退化成单一输出）
    let t0 = CACurrentMediaTime()
    let budget = 1.0 / 15.0
    // 【为什么有真实帧时不受 seconds 限制】实测踩到：给了 160 帧却只跑 44 帧
    //   （3.0s × 14.5Hz ≈ 44），于是只覆盖了**冷启动段**（前 24 帧还是钳位填充），
    //   得到的决策分布是片面的。有真实帧时应以"跑完这些帧"为准，
    //   seconds 只作为无真实帧（合成图）时的时长控制。
    let timeLimit = realFrames.isEmpty ? seconds : .greatestFiniteMagnitude
    while CACurrentMediaTime() - t0 < timeLimit, frames < driveFrames {
        let f0 = CACurrentMediaTime()
        let frameCG = realFrames.isEmpty ? fallbackCG : realFrames[frames]
        let img = NSImage(cgImage: frameCG,
                          size: NSSize(width: frameCG.width, height: frameCG.height))
        state.pushBenchFrameForTickBench(display: img, displayCG: frameCG, yolo: nil, native: nil)
        state.tick()
        frames += 1
        let spent = CACurrentMediaTime() - f0
        // ⚠️ **无论如何都要泵一次 RunLoop**：V3 的完成回调是
        //   `Task { @MainActor in self.finish(...) }`，只有主队列被推进才会执行。
        //   若只在"还有预算余额"时才泵，首帧超时后回调就永远不落地
        //   → inferenceCount 恒 0，误判成"接线没生效"（已实测踩到）。
        if spent < budget {
            RunLoop.current.run(until: Date().addingTimeInterval(budget - spent))
        } else {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        decisions.append(state.inferenceEngineV3.lastDecision)
    }
    let wall = CACurrentMediaTime() - t0
    let after = state.inferenceEngineV3.inferenceCount
    let produced = after - before

    print(String(format: "    tick 帧数=%d  实际 %.1f Hz  V3 推理次数=%d",
                 frames, Double(frames) / wall, produced))
    check("tick() 真的被执行", frames > 0, "\(frames) 帧")
    check("★ V3 在真实 tick 中被驱动（推理次数 > 0）", produced > 0,
          "before=\(before) after=\(after)")
    check("V3 推理次数与 tick 帧数同量级（接线未被门控挡住）",
          produced >= Int(Double(frames) * 0.5),
          "tick=\(frames) v3=\(produced)")

    // ── V3 产出的命令是否真的到达 currentCommand 通道 ──
    if let last = state.inferenceEngineV3.lastResult {
        check("V3 产出了有效结果", true,
              String(format: "steer=%.2f throttle=%.2f brake=%.2f",
                     last.steer, last.throttle, last.brake))
        check("V3 结果是新鲜的", state.inferenceEngineV3.lastResultTime
                .map { Date().timeIntervalSince($0) < 1.0 } ?? false)
    } else {
        check("V3 产出了有效结果", false, "lastResult 为 nil")
    }

    // ── 决策分布：真实帧下模型是否退化成"永远同一个输出" ──
    if !decisions.isEmpty {
        var vCount = [0, 0, 0], hCount = [0, 0, 0]
        var brakeOn = 0
        for d in decisions {
            vCount[max(0, min(2, d.verticalClass))] += 1
            hCount[max(0, min(2, d.horizontalClass))] += 1
            if d.brakePressed { brakeOn += 1 }
        }
        print("    决策分布 vertical(W/NONE/S)=\(vCount)  horizontal(A/NONE/D)=\(hCount)  brake_on=\(brakeOn)/\(decisions.count)")
        // 诊断：末 3 帧决策 vs lastResult，用于核对「分类→连续量」映射是否自洽。
        // 背景：实测 seg_a 的分布是「几乎全 S」，但打印的 lastResult.brake 是 0.00，
        //   两者按映射规则（vertical==2 → brake=1.0）不可能同时成立，必须查清。
        print("    末 3 帧决策: " + decisions.suffix(3).map { $0.debugSummary }.joined(separator: " | "))
        // 只报数、不作硬性断言：真实帧段可能天然单一（如长直道），
        // 强制要求"必须有多种输出"会产生假阴性。
    }

    // ── 关键：确认没有按键被注入（heldKeys 必须为空）──
    check("全程零按键注入（controlEngine.heldKeys 为空）",
          state.controlEngine.heldKeys.isEmpty,
          "held=\(state.controlEngine.heldKeys.isEmpty ? "空" : "非空")")

    // ── P1-3：完整控制路径回归（真实 tick + 只记录后端）──
    failures += runV3ControlPathChecks(state: state, realFrames: realFrames)

    print("\n" + bar)
    print(failures == 0 ? "V3 集成夹具：全部通过 ✓" : "V3 集成夹具：失败 \(failures) 项")
    print(bar)
    return failures
}

// MARK: - P1-3：完整控制路径回归（真实 tick + 可记录事件的控制后端）

/// 一次 tick 的按键快照（`decision`/`result` 均为该 tick **实际消费**的那份）。
private struct V3RecordedTick {
    let index: Int
    let held: Set<CGKeyCode>
    let command: ControlCommand
    let result: InferenceResult?
    let decision: V3Decision
    let isFreshDecision: Bool
    /// 该 tick 的车速（防侧翻兜底判据需要；nil/非有限 = 未知）。
    let speedKmh: Double?
    let speedValid: Bool

    /// 按契约推导的「本帧应被**实际注入**的六键」。
    ///
    /// ⚠️【必须用 `v3ExpectedExecutedSixKeys` 而不是纯映射版】生产在注入前插入了
    ///   防侧翻兜底（P0-2），真实注入集合 ≠ 模型原始输出的直接映射。
    ///   用纯映射版算期望会在「super/ultimate + 给油」帧上假红。
    var expectedKeys: Set<CGKeyCode> {
        guard isFreshDecision else { return [] }
        return v3ExpectedExecutedSixKeys(result: result, decision: decision,
                                         speedKmh: speedKmh, speedValid: speedValid)
    }
}

/// 一条可记录的后端事件（只存在于内存，绝不发往系统）。
private struct V3RecordedEvent: Equatable {
    let step: Int
    let keyCode: CGKeyCode
    let isDown: Bool
    var description: String {
        "\(step):\(isDown ? "+" : "-")\(V3SixKey.name(keyCode))"
    }
}

/// 「可记录事件的控制后端」：把产品既有的 `ControlEngine` 切到**消化模式**，
/// 使 `postKeyEvent` 在 `CGEvent.post` **之前**返回（`ControlEngine.swift:533-538`），
/// 只留下 `heldKeys` 与 `digestedEventCount` 的变化 —— 本类据此记录键集合与顺序。
///
/// 【为什么不新写一个注入协议】`DriveState.controlEngine` 是 `let` 且 `ControlEngine`
///   是 `final`（`AuroraDriveApp.swift:6292`、`ControlEngine.swift:32`），
///   本轮只允许改本文件，无法从外部替换实例。消化模式是项目**已有**的
///   「按键链路照跑、最后一步不真发」机制，语义正是本夹具需要的记录后端；
///   沿用它同时保证被测的是**产品同一条代码路径**（applyCommand /
///   applyV3BrakeHeads / hold / release / refreshHeldKeys 全部真实执行）。
///
/// 【零注入不是口头承诺，是可判定的】`ControlEngine.postedEventCount` 只在
///   `event.post(tap:)` 之后自增（`ControlEngine.swift:538`），
///   故「运行前后 postedEventCount 完全不变」即为「系统事件流零事件」的硬证据。
@MainActor
private final class V3RecordingControlBackend {
    private let engine: ControlEngine
    private(set) var events: [V3RecordedEvent] = []
    private var step = 0
    private var observed: Set<CGKeyCode>

    /// 进入后端时的已注入事件数：整段跑完必须**完全不变**。
    let postedEventCountAtEntry: Int

    init(engine: ControlEngine) {
        self.engine = engine
        self.observed = engine.heldKeys
        self.postedEventCountAtEntry = engine.postedEventCount
        // 硬开关：进入即消化。ControlEngine.digestMode 的 didSet 会同步
        // 进程级 `globalDigest`（鼠标注入器也读它），避免"键盘消化、鼠标真点"。
        engine.digestMode = true
    }

    /// 把引擎收进一个干净的起点：松开全部键（仍在消化模式，不发事件）。
    func resetHeldKeys() {
        engine.releaseAll()
        observed = engine.heldKeys
        step += 1
    }

    /// 记录一次真实 tick 之后的键集合变化（生产路径用：本类只观察，不干预）。
    func sampleAfterTick(input: V3TickInputSnapshot,
                         command: ControlCommand,
                         isFresh: Bool,
                         speedKmh: Double?,
                         speedValid: Bool) -> V3RecordedTick {
        step += 1
        let now = engine.heldKeys
        let added = now.subtracting(observed)
        let removed = observed.subtracting(now)
        for code in added.sorted() {
            events.append(V3RecordedEvent(step: step, keyCode: code, isDown: true))
        }
        for code in removed.sorted() {
            events.append(V3RecordedEvent(step: step, keyCode: code, isDown: false))
        }
        observed = now
        return V3RecordedTick(index: step, held: now,
                              command: command, result: input.result,
                              decision: input.decision, isFreshDecision: isFresh,
                              speedKmh: speedKmh, speedValid: speedValid)
    }

    /// 合成场景用：按**产品调用顺序**驱动 ControlEngine 并记录真实状态变化。
    ///
    /// ⚠️ 这是对 `applyCommand`+`applyV3BrakeHeads` 的**测试镜像**，只用于在
    ///   真实模型不产出的分支上（A/D、ultimate 覆盖 W）做事件顺序断言；
    ///   镜像与产品是否一致，由下面的 Phase B 用「真实 tick 最终集合 == 同一
    ///   推导函数」交叉验证，且有源码级断言守住键位映射本身。
    ///
    /// ⚠️【必须同样套防侧翻兜底】（P0-2）生产在 `applyCommand` **之前**插入
    ///   `InferenceEngineV3.applyRolloverGuard(...)`（`AuroraDriveApp.swift` 注入段）。
    ///   镜像若跳过这一步，「super_brake + 给油」这一类用例的期望键集就与真实
    ///   注入不一致 —— 断言会要求产品改回**不安全**的行为，属反向假红。
    ///   故这里按同一顺序：兜底 → applyCommand → 刹车头。
    ///
    /// - Parameters:
    ///   - speedKmh/speedValid: 兜底的车速判据；默认"未知"（生产松油门并保留模型 brake，可回退强制 S）。
    func applySynthetic(command: ControlCommand, decision: V3Decision,
                        speedKmh: Double? = nil, speedValid: Bool = false) {
        // ① 防侧翻兜底（与生产同一函数、同一顺序）
        let guarded = InferenceEngineV3.applyRolloverGuard(
            to: command, decision: decision,
            speedKmh: speedKmh, speedValid: speedValid)
        applyAction(.steerRight, down: guarded.steer > 0.1)
        applyAction(.steerLeft, down: guarded.steer < -0.1)
        // ⚠️ 纵向必须写成 `if / else if`，与 `applyCommand`（AuroraDriveApp.swift:9351-9360）
        //   **逐字同构**。若拆成两条独立的 `applyAction`，两个量同时 >0.3 时
        //   会同时按住 W 和 S —— 那与产品行为不一致，镜子的期望值就失去意义。
        if guarded.throttle > 0.3 {
            applyAction(.throttle, down: true)
            applyAction(.brake, down: false)
        } else if guarded.brake > 0.3 {
            applyAction(.brake, down: true)
            applyAction(.throttle, down: false)
        } else {
            applyAction(.throttle, down: false)
            applyAction(.brake, down: false)
        }
        refreshHeldKeys()
        applyBrakeHeads(decision)
    }

    /// 与 `applyCommand` 的「油门/刹车互斥」完全等价：两个都过阈值时，生产代码
    /// 先看 throttle>0.3 → 只 hold 油门并 release 刹车；否则才看 brake。
    private func applyAction(_ action: ControlEngine.Action, down: Bool) {
        if down {
            applyHold(action)
        } else {
            applyRelease(action)
        }
    }

    private func applyHold(_ action: ControlEngine.Action) {
        let before = engine.heldKeys
        engine.hold(action)
        recordIfChanged(from: before)
    }

    private func applyRelease(_ action: ControlEngine.Action) {
        let before = engine.heldKeys
        engine.release(action)
        recordIfChanged(from: before)
    }

    private func refreshHeldKeys() {
        let before = engine.heldKeys
        engine.refreshHeldKeys()
        // refresh 只重发 keyDown，不改变集合；若集合变了说明实现有变，如实记录。
        recordIfChanged(from: before)
    }

    private func applyBrakeHeads(_ d: V3Decision) {
        let needShift = d.handbrakePressed || d.superBrakePressed || d.ultimatePressed
        let needSpace = d.brakePressed || d.superBrakePressed || d.ultimatePressed
        applyAction(.boost, down: needShift)        // 物理 Shift（56）
        applyAction(.handbrake, down: needSpace)    // 物理 Space（49）
    }

    private func recordIfChanged(from before: Set<CGKeyCode>) {
        let after = engine.heldKeys
        guard after != before else { return }
        for code in after.subtracting(before).sorted() {
            events.append(V3RecordedEvent(step: step, keyCode: code, isDown: true))
        }
        for code in before.subtracting(after).sorted() {
            events.append(V3RecordedEvent(step: step, keyCode: code, isDown: false))
        }
        observed = after
    }
}

/// P1-3 主入口：用真实 tick 跑完整控制路径 + 合成场景覆盖模型不产出的分支。
/// - Returns: 失败项数。
@MainActor
private func runV3ControlPathChecks(state: DriveState, realFrames: [CGImage]) -> Int {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        let suffix = detail.isEmpty ? "" : "  — \(detail)"
        if ok { print("  ✓ \(name)\(suffix)") } else { failures += 1; print("  ✗ \(name)\(suffix)") }
    }
    /// 前置条件不满足时**明确标记跳过**，不计入失败。
    /// 【为什么不直接判过】`--v3-integration` 不带 `--dir` 时没有真实帧，
    ///   这些项根本无从验证；记「✓」会假装验证过（假绿），记「✗」会假红。
    ///   如实打印「—（跳过）」才是正确语义。
    func skip(_ name: String, _ reason: String) {
        print("  — \(name)  — 跳过：\(reason)")
    }

    let bar = String(repeating: "=", count: 78)
    print("\n" + bar)
    print("P1-3 完整控制路径回归：可记录事件后端（消化模式，零系统注入）")
    print(bar)

    let recorder = V3RecordingControlBackend(engine: state.controlEngine)

    // ── 安全前置：证明「记录后端确实不注入」再放开生产注入分支 ──
    //
    // 顺序不能反：必须先在 controlDisabled/benchSuppress 仍然为真的状态下
    // 做一次 hold+release 探针，确认 postedEventCount 不变、digestedEventCount 增长，
    // 才允许把 mayInjectKeys 打开。否则一旦消化开关失效，下面的 tick 会真按键。
    if !state.controlEngine.checkPermission() {
        check("可记录后端前置：辅助功能权限可查询", false,
              "AXIsProcessTrustedWithOptions(nil)=false —— 无法观测 heldKeys，拒绝运行完整控制路径")
        return failures
    }
    let postedBeforeProbe = state.controlEngine.postedEventCount
    let digestedBeforeProbe = state.controlEngine.digestedEventCount
    state.controlEngine.hold(.throttle)
    let probeHeld = state.controlEngine.heldKeys.contains(V3SixKey.throttle)
    state.controlEngine.release(.throttle)
    let postedDeltaProbe = state.controlEngine.postedEventCount - postedBeforeProbe
    let digestedDeltaProbe = state.controlEngine.digestedEventCount - digestedBeforeProbe
    check("可记录后端前置：hold/release 不产生系统注入", postedDeltaProbe == 0 && probeHeld,
          "postedDelta=\(postedDeltaProbe) digestedDelta=\(digestedDeltaProbe) held=\(probeHeld)")
    guard postedDeltaProbe == 0, probeHeld, digestedDeltaProbe > 0 else {
        print("     拒绝继续 —— 记录后端未生效（若继续，生产注入分支会真按键）。")
        return failures + 1
    }

    // ── Phase B：真实 tick 跑完整控制路径 ──
    //
    // digestMode 必须同时写两处：tick 每帧会把 `DriveState.digestMode` 同步到
    // `controlEngine.digestMode`（`AuroraDriveApp.swift:8014`），只设后者会被首帧覆盖
    // → 变成真实注入。这是本夹具最危险的一个坑，故下面每帧都复核。
    state.digestMode = true
    state.controlEngine.digestMode = true
    state.expertMode = false
    state.controlDisabled = false
    state.benchSuppressAllInjection = false   // 放开：让 applyCommand/applyV3BrakeHeads 真正执行
    state.isDriving = true

    // 清掉 Phase A 留下的窗口与按键，重新按 24 帧口径预热
    state.inferenceEngineV3.reset()
    recorder.resetHeldKeys()

    print("  Phase B：真实 tick（帧源 \(realFrames.count) 帧，digest=ON）……")
    let warmup = V3InputContract.totalFrames + 4
    var index = 0
    var recorded: [V3RecordedTick] = []
    var digestBreaches = 0
    var postedBreaches = 0
    let postedAtPhaseBStart = state.controlEngine.postedEventCount

    func feedOneFrame() {
        guard !realFrames.isEmpty else { return }
        lastInput = v3DriveOneTick(state, frame: realFrames[index % realFrames.count])
        index += 1
    }

    var lastInput: V3TickInputSnapshot?
    for _ in 0..<min(warmup, realFrames.count) { feedOneFrame() }

    let recordCount = min(120, max(0, realFrames.count - index))
    var safetyAborted = false
    for _ in 0..<recordCount {
        feedOneFrame()
        // ⚠️【安全复核必须"立即停手"，不能只计数】
        //   本夹具此刻 `benchSuppressAllInjection=false`（为让 applyCommand 真跑），
        //   安全完全依赖 digestMode 在 `CGEvent.post` 之前截断
        //   （`ControlEngine.swift:533-538`）。一旦某帧把它改回去，
        //   继续跑剩下的帧就是**持续向真实系统注入按键**。
        //   故这里先恢复两道硬抑制（纯内存写、不发事件），再 break。
        let digestLost = !state.controlEngine.digestMode || !state.digestMode
        let postedChanged = state.controlEngine.postedEventCount != postedAtPhaseBStart
        if digestLost || postedChanged {
            if digestLost { digestBreaches += 1 }
            if postedChanged { postedBreaches += 1 }
            state.benchSuppressAllInjection = true
            state.controlDisabled = true
            safetyAborted = true
            break
        }

        guard let input = lastInput else { break }
        let fresh = input.resultTime.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        let tick = recorder.sampleAfterTick(input: input,
                                            command: state.currentCommand,
                                            isFresh: fresh,
                                            // 车速在 tick 前段写入、注入段在其后读取；
                                            // tick 结束后读到的正是注入时刻的真实值。
                                            speedKmh: state.effectiveSpeed,
                                            speedValid: state.speedValid)
        // 限速刹车会提前 return 抢走控制权，此时六键不属于 V3 决策，跳过键集断言。
        if !state.speedLimitBrakeLatched {
            recorded.append(tick)
        }
    }

    check("Phase B：消化开关全程未被改写（每帧复核）", digestBreaches == 0,
          "违规帧数=\(digestBreaches)" + (safetyAborted ? "，已在检测到异常时立即恢复硬抑制并终止" : ""))
    check("Phase B：全程零系统注入（postedEventCount 不变）", postedBreaches == 0,
          "起始=\(postedAtPhaseBStart) 结束=\(state.controlEngine.postedEventCount)"
          + "  digested=\(state.controlEngine.digestedEventCount)"
          + (safetyAborted ? "，安全中止=true" : ""))

    // 逐帧断言：真实 tick 的最终六键集合 == 按契约独立推导的集合
    var setMismatches: [String] = []
    for tick in recorded {
        if tick.held != tick.expectedKeys {
            setMismatches.append("tick\(tick.index) 实际[\(V3SixKey.describe(tick.held))] "
                                 + "期望[\(V3SixKey.describe(tick.expectedKeys))] v=\(tick.decision.verticalClass) h=\(tick.decision.horizontalClass)")
        }
    }
    check("Phase B：每一帧最终六键集合与契约推导一致", setMismatches.isEmpty,
          setMismatches.isEmpty ? "逐帧核对 \(recorded.count) 帧"
                                : "\(setMismatches.count) 帧不符：" + setMismatches.prefix(3).joined(separator: " | "))

    if realFrames.isEmpty {
        skip("Phase B：产生了真实控制动作（非全程空集）", "无真实帧（未传 --dir），Phase B 无从驱动")
    } else {
        check("Phase B：产生了真实控制动作（非全程空集）",
              recorded.contains { !$0.held.isEmpty },
              "非空帧 \(recorded.filter { !$0.held.isEmpty }.count)/\(recorded.count)")
    }

    // 互斥不变量：任何一帧都不能同时出现 W+S / A+D（游戏里会互相抵消或危险）
    let exclusiveViolations = recorded.filter {
        ($0.held.contains(V3SixKey.throttle) && $0.held.contains(V3SixKey.brake))
            || ($0.held.contains(V3SixKey.steerLeft) && $0.held.contains(V3SixKey.steerRight))
    }
    check("Phase B：纵向/横向互斥不变量成立（无 W+S、无 A+D）", exclusiveViolations.isEmpty,
          "违规 \(exclusiveViolations.count) 帧")

    // 修饰键不挥发：只允许在「本帧决策真的要求」时出现
    let modifierViolations = recorded.filter { tick in
        let extras = tick.held.intersection([V3SixKey.space, V3SixKey.shift])
            .subtracting(tick.expectedKeys)
        return !extras.isEmpty
    }
    check("Phase B：Space/Shift 不残留（只在本帧决策要求时按住）", modifierViolations.isEmpty,
          "违规 \(modifierViolations.count) 帧")

    // ── P0-1 / P0-2 运行时反证：画面超龄 → 不推理，且陈旧修饰键必须释放 ──
    print("\n  P0-1/P0-2 运行时反证：停喂画面 >1.0s 后再 tick")
    // 先把在途推理排空：以「连续两次 100ms 泵之间 inferenceCount 不变」为稳定判据
    // （单纯"两次采样相等"可能恰好落在同一次推理的中途，导致排空不彻底）。
    var previousCount = -1
    var stableRounds = 0
    for _ in 0..<60 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let now = state.inferenceEngineV3.inferenceCount
        if now == previousCount {
            stableRounds += 1
            if stableRounds >= 2 { break }
        } else {
            stableRounds = 0
            previousCount = now
        }
    }
    let heldBeforeStale = state.controlEngine.heldKeys
    let countBeforeStale = state.inferenceEngineV3.inferenceCount
    // 超过 v3MaxFrameAge(1.0s)：期间不 pushBenchFrameForTickBench → currentFrameCGAt 不变
    RunLoop.current.run(until: Date().addingTimeInterval(1.15))
    v3DriveOneTick(state, frame: nil)
    let countAfterStale = state.inferenceEngineV3.inferenceCount
    let heldAfterStale = state.controlEngine.heldKeys

    check("P0-1：画面超龄（>1.0s）后不再推理", countAfterStale == countBeforeStale,
          "推理次数 \(countBeforeStale) → \(countAfterStale)")
    check("P0-2：决策过期后六个键全部释放（含 Space/Shift）", heldAfterStale.isEmpty,
          "超龄前[\(V3SixKey.describe(heldBeforeStale))] → 超龄后[\(V3SixKey.describe(heldAfterStale))]")

    // 恢复供帧：必须重新开始推理（证明上面的"不推理"是新鲜度闸门，不是引擎卡死）
    //
    // ⚠️ 需要连续喂多帧：超龄那一次 tick 已让 `lastResultTime` 变旧 →
    //   `v3ReadyForControl=false` → 硬切 idle → 降级状态机降到 `.yolo`。
    //   恢复不是一帧就能回 `.e2e` 的（状态机有迟滞），但**推理**本身只受
    //   「V3 loaded + 画面新鲜」控制，与档位无关 —— 故这里断言的是推理次数，
    //   只需几帧即可；同时记录档位恢复情况，作为诊断信息而非判据。
    let countBeforeResume = state.inferenceEngineV3.inferenceCount
    var resumedFrames = 0
    while resumedFrames < 8 && state.inferenceEngineV3.inferenceCount == countBeforeResume {
        feedOneFrame()
        resumedFrames += 1
    }
    if realFrames.isEmpty {
        skip("P0-1：恢复新帧后立即恢复推理（闸门非卡死）", "无真实帧（未传 --dir），无法恢复供帧")
    } else {
        check("P0-1：恢复新帧后立即恢复推理（闸门非卡死）",
              state.inferenceEngineV3.inferenceCount > countBeforeResume,
              "推理次数 \(countBeforeResume) → \(state.inferenceEngineV3.inferenceCount)"
              + "（恢复供帧 \(resumedFrames) 帧，mode=\(state.mode.rawValue)）")
    }

    // ── Phase C：真实模型不产出的分支（A/D、ultimate 覆盖 W、super）──
    //
    // 真实 seg_a 的横向头几乎恒为 NONE，纵向恒为 S，故 A/D 与「ultimate 覆盖 W」
    // 这两个最容易接反的分支必须用合成决策驱动。用**独立**的 ControlEngine，
    // 避免污染 Phase B 的实例状态；同样切消化模式，零注入。
    print("\n  Phase C：合成决策的事件顺序（A/D、super、ultimate 覆盖）")
    let syntheticEngine = ControlEngine()
    _ = syntheticEngine.checkPermission()
    let synthetic = V3RecordingControlBackend(engine: syntheticEngine)
    let postedAtSyntheticStart = syntheticEngine.postedEventCount

    // 场景一：W+A → D+S。必须先松 A/W（事件里 -A、-W 出现在 +D、+S 之前），
    // 否则会短暂出现 A+D 同按（游戏里相互抵消）或 W+S 同按（油门刹车打架）。
    synthetic.applySynthetic(command: ControlCommand(steer: -1, throttle: 1, brake: 0),
                             decision: .idle)
    let heldWA = syntheticEngine.heldKeys
    let eventsBeforeSwitch = synthetic.events.count
    synthetic.applySynthetic(command: ControlCommand(steer: 1, throttle: 0, brake: 1),
                             decision: .idle)
    let switchEvents = Array(synthetic.events[eventsBeforeSwitch...])
    check("Phase C：W+A 场景按出 W 与 A",
          heldWA == [V3SixKey.throttle, V3SixKey.steerLeft],
          "实际[\(V3SixKey.describe(heldWA))]")
    // 事件顺序必须与产品实现**逐字一致**：`applyCommand` 的横向分支是
    //   `if steer > 0.1 { hold(.steerRight); release(.steerLeft) }`
    // （`AuroraDriveApp.swift:9339-9344`）—— 先按新方向、再松旧方向。
    // 期望侧写反会变成"要求产品改行为"，所以这里按产品真实顺序断言：
    // 新方向 keyDown 在前、旧方向 keyUp 在后，且两者都发生。
    let rightDownIdx = switchEvents.firstIndex { $0.keyCode == V3SixKey.steerRight && $0.isDown }
    let leftUpIdx = switchEvents.firstIndex { $0.keyCode == V3SixKey.steerLeft && !$0.isDown }
    let throttleUpIdx = switchEvents.firstIndex { $0.keyCode == V3SixKey.throttle && !$0.isDown }
    let brakeDownIdx = switchEvents.firstIndex { $0.keyCode == V3SixKey.brake && $0.isDown }
    // ⚠️ 纵向切到「刹车」时走的是 `applyCommand` 的 `else if cmd.brake > 0.3` 分支
    //   （`AuroraDriveApp.swift:9354-9356`），其语句顺序是：
    //       controlEngine.hold(.brake)
    //       controlEngine.release(.throttle)
    //   即**先 +S 后 -W**。上一版我把期望写成「先 -W 后 +S」，
    //   那是在要求产品改行为 —— 已实测被这条断言抓住（假红）。
    //   这里按产品真实分支顺序断言，避免"凭直觉定顺序"。
    check("Phase C：切 D+S 时事件顺序与产品一致（先 +D 后 -A；先 +S 后 -W）",
          syntheticEngine.heldKeys == [V3SixKey.steerRight, V3SixKey.brake]
          && rightDownIdx != nil && leftUpIdx != nil && rightDownIdx! < leftUpIdx!
          && brakeDownIdx != nil && throttleUpIdx != nil && brakeDownIdx! < throttleUpIdx!,
          "事件=\(switchEvents.map(\.description).joined(separator: " "))")

    check("Phase C：合成路径同样零系统注入",
          syntheticEngine.postedEventCount == postedAtSyntheticStart,
          "postedDelta=\(syntheticEngine.postedEventCount - postedAtSyntheticStart)"
          + " digested=\(syntheticEngine.digestedEventCount)")

    // ultimate 覆盖：模型可能同时给 vertical=W 与 ultimate=1。
    // 生产在 `InferenceEngineV3.finish()` 已把纵向强制成 S（:608），
    // 故这里用「覆盖后」的 result 喂控制路径：throttle=0 brake=1。
    let ultimateDecision = V3Decision(verticalClass: 0, horizontalClass: 1,
                                      brakePressed: false, handbrakePressed: false,
                                      superBrakePressed: false, ultimatePressed: true,
                                      confidence: 0.9, risk: 0.1)
    let ultimateResult = InferenceResult(steer: 0, throttle: 0, brake: 1, latencyMs: 0)
    synthetic.resetHeldKeys()
    let beforeUltimate = synthetic.events.count
    synthetic.applySynthetic(command: ControlCommand(steer: ultimateResult.steer,
                                                     throttle: ultimateResult.throttle,
                                                     brake: ultimateResult.brake),
                             decision: ultimateDecision)
    let ultimateEvents = Array(synthetic.events[beforeUltimate...])
    let ultimateFinal = syntheticEngine.heldKeys
    check("Phase C：ultimate 覆盖纵向 → S+Shift+Space（不得有 W）",
          ultimateFinal == [V3SixKey.brake, V3SixKey.shift, V3SixKey.space],
          "最终[\(V3SixKey.describe(ultimateFinal))] 事件=\(ultimateEvents.map(\.description).joined(separator: " "))")

    // super_brake：只给 super 头，也必须同时按住 Shift+Space。
    //
    // ⚠️【必须按车速分两种情况断言】（P0-2 兜底生效后）
    //   生产在注入前对 super/ultimate 套 `applyRolloverGuard`：
    //   高速 → 纵向强制 S；未知默认只松油门。故同一个 super 决策：
    //     · 低速（已知且 ≤ 阈值）→ 兜底不介入，给油保留 → Shift+Space+W
    //     · 高速 → 给油被压掉 → S+Shift+Space
    //   只断言其中一种，另一条真实行为就会被判成"接错了"（假红）。
    let superDecision = V3Decision(verticalClass: 0, horizontalClass: 1,
                                   brakePressed: false, handbrakePressed: false,
                                   superBrakePressed: true, ultimatePressed: false,
                                   confidence: 0.9, risk: 0.1)
    synthetic.resetHeldKeys()
    let beforeSuper = synthetic.events.count
    synthetic.applySynthetic(command: ControlCommand(steer: 0, throttle: 1, brake: 0),
                             decision: superDecision,
                             speedKmh: 10, speedValid: true)     // 低速 → 兜底不介入
    let superEvents = Array(synthetic.events[beforeSuper...])
    check("Phase C：低速 super_brake → Shift+Space+W（兜底不介入）",
          syntheticEngine.heldKeys == [V3SixKey.shift, V3SixKey.space, V3SixKey.throttle],
          "事件=\(superEvents.map(\.description).joined(separator: " "))")

    // 同一决策、高速 → 兜底把给油压成 S（不得出现 W）
    synthetic.resetHeldKeys()
    let beforeSuperHigh = synthetic.events.count
    synthetic.applySynthetic(command: ControlCommand(steer: 0, throttle: 1, brake: 0),
                             decision: superDecision,
                             speedKmh: 80, speedValid: true)
    let superHighEvents = Array(synthetic.events[beforeSuperHigh...])
    check("Phase C：高速 super_brake → Shift+Space+S（兜底压掉给油）",
          syntheticEngine.heldKeys == [V3SixKey.brake, V3SixKey.shift, V3SixKey.space],
          "事件=\(superHighEvents.map(\.description).joined(separator: " "))")

    // 单头映射：handbrake 头→Shift、brake 头→Space（枚举名与物理键相反的回归点）
    let handbrakeOnly = V3Decision(verticalClass: 1, horizontalClass: 1,
                                   brakePressed: false, handbrakePressed: true,
                                   superBrakePressed: false, ultimatePressed: false,
                                   confidence: 0.9, risk: 0.1)
    synthetic.resetHeldKeys()
    synthetic.applySynthetic(command: .idle, decision: handbrakeOnly)
    check("Phase C：handbrake 头 → 物理 Shift(56)（不是 Space）",
          syntheticEngine.heldKeys == [V3SixKey.shift],
          "实际[\(V3SixKey.describe(syntheticEngine.heldKeys))]")
    let brakeOnly = V3Decision(verticalClass: 1, horizontalClass: 1,
                               brakePressed: true, handbrakePressed: false,
                               superBrakePressed: false, ultimatePressed: false,
                               confidence: 0.9, risk: 0.1)
    synthetic.applySynthetic(command: .idle, decision: brakeOnly)
    check("Phase C：brake 头 → 物理 Space(49)（不是 Shift）",
          syntheticEngine.heldKeys == [V3SixKey.space],
          "实际[\(V3SixKey.describe(syntheticEngine.heldKeys))]")

    // 事件顺序：从 {Space} 切到 idle，必须先松 Space 再松 Shift（Shift 本就没按），
    // 最终必须为空集 —— 防止「陈旧修饰键不释放」。
    let beforeRelease = synthetic.events.count
    synthetic.applySynthetic(command: .idle, decision: .idle)
    let releaseEvents = Array(synthetic.events[beforeRelease...])
    check("Phase C：进入 idle 后六键全部释放（事件顺序可回溯）",
          syntheticEngine.heldKeys.isEmpty,
          "事件=\(releaseEvents.map(\.description).joined(separator: " "))")

    // ── Phase D：源码级断言（键位映射与三条 P0 修复的可判定证据）──
    print("\n  Phase D：源码级可判定断言（键位映射 + P0-1/P0-2/P0-3）")
    let appPath = AuroraPaths.projectRoot().appendingPathComponent("Sources/AuroraDrive/App/AuroraDriveApp.swift").path
    let v3Path = AuroraPaths.projectRoot().appendingPathComponent("Sources/AuroraDrive/Inference/InferenceEngineV3.swift").path
    guard let appSrc = try? String(contentsOfFile: appPath, encoding: .utf8),
          let v3Src = try? String(contentsOfFile: v3Path, encoding: .utf8) else {
        check("Phase D：读取 App / V3 源码", false, "读不到 \(appPath)")
        return failures
    }

    if let applySrc = v3SourceSlice(appSrc, after: "private func applyCommand(",
                                    before: ["private func applyV3BrakeHeads("]) {
        check("Phase D：applyCommand 横向右转 → hold(.steerRight)",
              v3SourceContainsNormalized(applySrc, "if cmd.steer > 0.1 { controlEngine.hold(.steerRight) controlEngine.release(.steerLeft) }"),
              "死区 ±0.1 与左右互斥")
        check("Phase D：applyCommand 纵向油门优先于刹车（互斥）",
              v3SourceContainsNormalized(applySrc, "if cmd.throttle > 0.3 { controlEngine.hold(.throttle) controlEngine.release(.brake) }"),
              "阈值 >0.3")
    } else {
        check("Phase D：定位 applyCommand 源码片段", false, "锚点未命中")
    }

    if let brakeSrc = v3SourceSlice(appSrc, after: "private func applyV3BrakeHeads(",
                                    before: ["// ============================================================================"]) {
        check("Phase D：needShift = handbrake∨super∨ultimate",
              v3SourceContainsNormalized(brakeSrc, "let needShift = d.handbrakePressed || d.superBrakePressed || d.ultimatePressed"))
        check("Phase D：needSpace = brake∨super∨ultimate",
              v3SourceContainsNormalized(brakeSrc, "let needSpace = d.brakePressed || d.superBrakePressed || d.ultimatePressed"))
        check("Phase D：Shift 走 .boost（键码 56），不是 .handbrake",
              v3SourceContainsNormalized(brakeSrc, "if needShift { controlEngine.hold(.boost) } else { controlEngine.release(.boost) }"))
        check("Phase D：Space 走 .handbrake（键码 49），不是 .boost",
              v3SourceContainsNormalized(brakeSrc, "if needSpace { controlEngine.hold(.handbrake) } else { controlEngine.release(.handbrake) }"))
    } else {
        check("Phase D：定位 applyV3BrakeHeads 源码片段", false, "锚点未命中")
    }

    // P0-1：输入新鲜度门（阈值 1.0s，超龄不推理）+ 真实采集时刻/序号传入
    if let inferSrc = v3SourceSlice(appSrc, after: "if inferenceEngineV3.isLoaded {",
                                    before: ["} else {", "// ── 重试加载"]) {
        check("P0-1：新鲜度闸门用 currentFrameCGAt 且阈值 1.0s",
              v3SourceContainsNormalized(inferSrc, "let frameAge = currentFrameCGAt.map { Date().timeIntervalSince($0) } ?? .infinity")
              && v3SourceContainsNormalized(inferSrc, "if frameAge <= Self.v3MaxFrameAge {"),
              "超龄分支只打印、不推理")
        check("P0-1：infer 传入真实采集时刻与源帧序号（不再裸调 infer(image: cg)）",
              v3SourceContainsNormalized(inferSrc, "inferenceEngineV3.infer(image: cg, capturedAt: currentFrameCGAt, sequence: currentFrameSeq)"))
    } else {
        check("P0-1：定位推理门片段", false, "锚点未命中")
    }
    check("P0-1：v3MaxFrameAge 常量 = 1.0",
          v3SourceContainsNormalized(appSrc, "private static let v3MaxFrameAge: TimeInterval = 1.0"))
    // P0-1：tick 消费帧时采集时刻必须取**源帧真实时刻**，不能是 Date()
    check("P0-1：currentFrameCGAt 来自 pendingFrameTime（非 Date()）",
          v3SourceContainsNormalized(appSrc, "currentFrameCGAt = captureMoment ?? Date()")
          && v3SourceContainsNormalized(appSrc, "let captureMoment = pendingFrameTime"))
    // P0-1：引擎侧拒绝重复源帧入窗
    check("P0-1：引擎侧按源帧序号判重（isDuplicate）",
          v3SourceContainsNormalized(v3Src, "if self.frameBuffer.isDuplicate(sequence: sequence) {"))
    check("P0-1：环形缓冲携带并比对源帧序号",
          v3SourceContainsNormalized(v3Src, "func isDuplicate(sequence: Int?) -> Bool"))

    // P0-2：刹车头门控必须同时含 decided == .e2e 与 v3DecisionFresh
    check("P0-2：v3DecisionFresh 由 lastResultTime < 1.0 计算",
          v3SourceContainsNormalized(appSrc, "let v3DecisionFresh = inferenceEngineV3.isLoaded && (inferenceEngineV3.lastResultTime.map { Date().timeIntervalSince($0) < 1.0 } ?? false)"))
    check("P0-2：刹车头门控含 v3Active && decided == .e2e && v3DecisionFresh",
          v3SourceContainsNormalized(appSrc, "let brakeHeadsActive = v3Active && decided == .e2e && v3DecisionFresh")
          && v3SourceContainsNormalized(appSrc, "if brakeHeadsActive { applyV3BrakeHeads(inferenceEngineV3.lastDecision) } else { controlEngine.release(.boost) controlEngine.release(.handbrake) }"))
    check("P0-2：注入前对最终命令套防侧翻兜底",
          v3SourceContainsNormalized(appSrc, "injectCommand = InferenceEngineV3.applyRolloverGuard( to: currentCommand, decision: inferenceEngineV3.lastDecision, speedKmh: effectiveSpeed, speedValid: speedValid)")
          && v3SourceContainsNormalized(appSrc, "applyCommand(injectCommand)"))
    check("P0-2：兜底仅在刹车头生效时介入（其他档位不改写纵向）",
          v3SourceContainsNormalized(appSrc, "if brakeHeadsActive { injectCommand = InferenceEngineV3.applyRolloverGuard("))

    // P0-3：finish() 不得写 previousHorizontalClass；回填只由 noteExecutedSteer 承担
    if let finishSrc = v3SourceSlice(v3Src, after: "private func finish(",
                                     before: ["// MARK: 分类 → 连续量映射"]) {
        check("P0-3：finish() 不再覆盖 previousHorizontalClass",
              !v3SourceContainsNormalized(finishSrc, "previousHorizontalClass ="),
              "finish 片段内零赋值")
    } else {
        check("P0-3：定位 finish() 源码片段", false, "锚点未命中")
    }
    if let noteSrc = v3SourceSlice(v3Src, after: "func noteExecutedSteer(",
                                   before: ["/// 重置：清帧缓冲与冷启动状态"]) {
        check("P0-3：noteExecutedSteer() 是唯一回填点",
              v3SourceContainsNormalized(noteSrc, "previousHorizontalClass = 0")
              && v3SourceContainsNormalized(noteSrc, "previousHorizontalClass = 2")
              && v3SourceContainsNormalized(noteSrc, "previousHorizontalClass = 1"))
    } else {
        check("P0-3：定位 noteExecutedSteer() 源码片段", false, "锚点未命中")
    }
    check("P0-3：tick 注入后回填**实际执行**的横向动作（读 heldKeys，非布尔推断）",
          v3SourceContainsNormalized(appSrc, "inferenceEngineV3.noteExecutedSteer(executedSteer)")
          && v3SourceContainsNormalized(appSrc, "} else if controlEngine.heldKeys.contains(controlEngine.keyMap.steerLeft) { executedSteer = -1")
          && v3SourceContainsNormalized(appSrc, "} else if controlEngine.heldKeys.contains(controlEngine.keyMap.steerRight) { executedSteer = 1"))
    check("P0-3：旧写法（由「允许注入」布尔值推断转向）已移除",
          !v3SourceContainsNormalized(appSrc, "noteExecutedSteer(v3InjectedKeys ? currentCommand.steer : 0)"),
          "布尔门控 ≠ 实际按键，已改为读实际状态")
    // P0-3：限速刹车**提前 return** 前必须回填（否则 vehicle_state[6] 带旧转向）
    if let limitSrc = v3SourceSlice(appSrc, after: "if limitBraking {",
                                    before: ["// 刹车 → 松开的边沿"]) {
        check("P0-3：限速早退路径回填转向 0",
              v3SourceContainsNormalized(limitSrc, "inferenceEngineV3.noteExecutedSteer(0)"),
              "该分支在 applySpeedLimitBrake() 后直接 return")
    } else {
        check("P0-3：定位限速早退片段", false, "锚点未命中")
    }

    // 还原安全状态：先恢复硬抑制，再收尾（消化模式保持开启，进程随后 exit）。
    state.benchSuppressAllInjection = true
    state.controlDisabled = true
    recorder.resetHeldKeys()

    print("\n  P1-3 完整控制路径：\(failures == 0 ? "全部通过 ✓" : "失败 \(failures) 项")")
    return failures
}

// MARK: - 模型质检：真实训练图 vs 训练标签（--v3-qc）

/// 用**真实训练帧**质检 V3：把引擎输出与 `controls.csv` 的真人按键标签逐帧比对。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 【为什么要做这一项，而不是只看自检】
///   自检证明"引擎能算、输出有限、随输入变化"；集成夹具证明"V3 在真实 tick 里被驱动"。
///   但两者都**没有回答**"它开得像不像人"。本项直接对真实训练帧算指标。
///
/// 【为什么必须给基线对照 —— 这是最容易自欺的一步】
///   数据里 NONE 占绝对多数（直道巡航）。若模型**永远输出 NONE**，
///   也能拿到很高的"准确率"，看着像成功、实则完全没用。
///   故同时算「多数类基线」= 永远预测 NONE 的一致率，
///   只有**显著高于基线**才说明模型真学到了东西。
///
/// 【口径】标签按 `src/dataset_v3.py` 的定义重建：
///   vertical   : s→2 / w→0 / 否则 1（S 优先，安全偏置）
///   horizontal : a∧¬d→0 / d∧¬a→2 / 否则 1
///   brake←space列，handbrake←shift列，super_brake / ultimate_brake 各有独立列。
/// ══════════════════════════════════════════════════════════════════════════
@MainActor
@discardableResult
func runV3QualityCheck(dir: String, maxFrames: Int = 400) -> Int {
    let bar = String(repeating: "=", count: 78)
    print(bar)
    print("V3 模型质检：真实训练帧 vs 真人按键标签")
    print(bar)

    let dirURL = URL(fileURLWithPath: dir)
    let csvURL = dirURL.appendingPathComponent("labels.csv")
    guard let csv = try? String(contentsOf: csvURL, encoding: .utf8) else {
        print("  ✗ 读不到标签文件：\(csvURL.path)")
        return 1
    }

    // ── 解析 CSV：frame → 8 个原子键 ──
    //
    // ⚠️【必须按表头名取列，不能硬编码下标】（自查发现的真实缺陷）
    //   实际表头 11 列：`t_sec,frame,speed_kmh,w,a,s,d,shift,space,super_brake,ultimate_brake`
    //   我最初写成 `keys = (2..<10)` —— 下标 2 是 **speed_kmh**（可能是 "131"），
    //   会让 8 个键整体错位一列，且 speed 值既非 0 也非 1 会被判成"未知"，
    //   整批样本被静默丢弃或标签全错。这类错误不会崩、只会让质检结论完全失真。
    var labels: [Int: [Int]] = [:]
    let allLines = csv.split(separator: "\n").map(String.init)
    guard let header = allLines.first else { print("  ✗ 标签文件为空"); return 1 }
    let cols = header.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    // 8 个原子键的列序（与 dataset_v3 的 ATOMIC_KEYS 一致）
    let keyNames = ["w", "a", "s", "d", "shift", "space", "super_brake", "ultimate_brake"]
    guard let frameCol = cols.firstIndex(of: "frame") else {
        print("  ✗ 标签表头缺 frame 列：\(header)")
        return 1
    }
    var keyCols: [Int] = []
    for name in keyNames {
        guard let i = cols.firstIndex(of: name) else {
            print("  ✗ 标签表头缺列 '\(name)'：\(header)")
            return 1
        }
        keyCols.append(i)
    }
    print("  表头校验：frame 列=\(frameCol)，键列=\(keyCols)（\(cols.count) 列）")
    for line in allLines.dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count > max(frameCol, keyCols.max() ?? 0),
              let frame = Int(f[frameCol].trimmingCharacters(in: .whitespaces)) else { continue }
        // 空串 / 非数字 / 非 0-1 → -1，后续按"未知"处理（不静默当 0）
        let keys = keyCols.map { i -> Int in
            let sv = f[i].trimmingCharacters(in: .whitespaces)
            guard let v = Int(sv), v == 0 || v == 1 else { return -1 }
            return v
        }
        labels[frame] = keys
    }
    print("  标签文件解析：\(labels.count) 行")

    // ── 收集帧文件（按 frame 号排序）──
    var frames: [(Int, URL)] = []
    if let files = try? FileManager.default.contentsOfDirectory(at: dirURL,
                                                               includingPropertiesForKeys: nil) {
        for u in files where u.pathExtension.lowercased() == "jpg" {
            if let n = Int(u.deletingPathExtension().lastPathComponent) { frames.append((n, u)) }
        }
    }
    frames.sort { $0.0 < $1.0 }
    print("  帧文件：\(frames.count) 张（\(frames.first?.0 ?? -1)…\(frames.last?.0 ?? -1)）")
    guard !frames.isEmpty else { print("  ✗ 无帧文件"); return 1 }

    // ── 加载引擎 ──
    let engine = InferenceEngineV3()
    engine.loadIfNeeded()
    guard engine.isLoaded else {
        print("  ✗ V3 模型未加载：\(engine.errorMessage ?? "-")")
        return 1
    }

    // ── 逐帧推理（连续喂，窗口自然滚动；前 24 帧属冷启动填充，不计入统计）──
    //
    // 【P1-4 缺陷①：必须确认每帧真的算完才计分】
    //   旧实现 `_ = v3DrainOneInference(...)` 直接丢弃返回值：超时/失败时
    //   `lastDecision` 仍是**上一帧**的结果，却被拿来和**当前帧**标签比对 ——
    //   静默地把旧预测记到新图上，指标既可能虚高也可能虚低，且无法察觉。
    //   现在：`v3DrainOneInference == false` → 该帧计入 `failedFrames`，
    //   **不进 mole 统计**；并单独打印失败数，失败率过高本身判失败。
    let warmupFrames = V3InputContract.totalFrames
    var n = 0
    var failedFrames = 0
    var attemptedFrames = 0

    // 混淆矩阵（行=真值，列=预测），下标 0/1/2 = W/NONE/S、A/NONE/D
    var confusionV = [[Int]](repeating: [Int](repeating: 0, count: 3), count: 3)
    var confusionH = [[Int]](repeating: [Int](repeating: 0, count: 3), count: 3)

    // 控制头：命中/真值分布（用于**真多数类基线**）
    var okBrake = 0, okHand = 0, okSuper = 0, okUlt = 0
    var posBrake = 0, posHand = 0, posSuper = 0, posUlt = 0
    // 六键（最终执行）命中 / 真值每键计数
    var okSixKey = 0
    var truthSixKeyCounts: [CGKeyCode: Int] = [:]
    // 真值六键集合直方图 —— 用于「最终六键」的**真多数类基线**（最常出现的那个集合）
    var truthSixSetHistogram: [Set<CGKeyCode>: Int] = [:]
    // ultimate 覆盖后的「执行纵向」命中（生产会把 ultimate 强制成 S）
    var okExecVertical = 0
    var okExecSixKey = 0
    // 每键 TP/FP/FN（六键集合级）
    var keyTP: [CGKeyCode: Int] = [:], keyFP: [CGKeyCode: Int] = [:], keyFN: [CGKeyCode: Int] = [:]

    var idx = 0
    var prevFrameNo: Int? = nil
    for (frameNo, url) in frames {
        // ⚠️【必须按训练口径回填 state[6]】（自查发现的质检夹具缺陷）
        //   训练侧 `dataset_v3.py:630-638`：帧 t 的 `vehicle_state[6]` 取
        //   **帧 t−1 实际按下的 a/d**（人真的按了什么）。
        //   而裸引擎默认把 state[6] 设成"模型自己上一帧的预测"（previousHorizontalClass），
        //   在质检里无人回填 → 形成自我强化闭环：一旦预测 NONE，
        //   state[6] 就恒 0，模型越走越偏，横向头整体塌成 NONE。
        //   实测后果：seg_a 上 Swift 侧 horizontal 81.62% 恰好等于
        //   "全猜 NONE"的基线；而同帧 PIL 参考（喂真值）是 91.24%。
        //   → 差异来自**夹具闭环**，不是预处理、也不是量化。
        //   故此处按训练口径用**上一帧真值**设置，使质检验证的是模型本身。
        if let pn = prevFrameNo, let pk = labels[pn], pk.allSatisfy({ $0 >= 0 }) {
            let pa = pk[1], pd = pk[3]          // keyNames: w,a,s,d → idx 1=a, 3=d
            let truthSteer: Double = (pa == 1 && pd == 0) ? -1.0
                                   : ((pd == 1 && pa == 0) ? 1.0 : 0.0)
            engine.noteExecutedSteer(truthSteer)
        }
        prevFrameNo = frameNo

        guard let cg = v3LoadCGImage(url) else { continue }
        let before = engine.inferenceCount
        engine.infer(image: cg)
        // ★ P1-4①：返回值必须判，失败帧单独统计
        let finished = v3DrainOneInference(engine, before: before, timeout: 1.0)
        idx += 1
        if idx <= warmupFrames { continue }          // 冷启动期不统计
        if n >= maxFrames { break }
        attemptedFrames += 1
        guard finished else { failedFrames += 1; continue }
        guard let k = labels[frameNo], k.allSatisfy({ $0 >= 0 }) else { continue }
        let d = engine.lastDecision
        let result = engine.lastResult

        // k 的下标 = keyNames 顺序：w=0,a=1,s=2,d=3,shift=4,space=5,super=6,ultimate=7
        let tv = k[2] == 1 ? 2 : (k[0] == 1 ? 0 : 1)       // s→2 / w→0 / 否则1（S 优先）
        let th = (k[1] == 1 && k[3] == 0) ? 0 : ((k[3] == 1 && k[1] == 0) ? 2 : 1)
        let tb = k[5], thb = k[4], tsb = k[6], tul = k[7]   // space/shift/super/ultimate

        n += 1
        confusionV[tv][max(0, min(2, d.verticalClass))] += 1
        confusionH[th][max(0, min(2, d.horizontalClass))] += 1

        let pb = d.brakePressed ? 1 : 0
        let phb = d.handbrakePressed ? 1 : 0
        let psb = d.superBrakePressed ? 1 : 0
        let pul = d.ultimatePressed ? 1 : 0
        if pb == tb { okBrake += 1 };      if tb == 1 { posBrake += 1 }
        if phb == thb { okHand += 1 };     if thb == 1 { posHand += 1 }
        if psb == tsb { okSuper += 1 };    if tsb == 1 { posSuper += 1 }
        if pul == tul { okUlt += 1 };      if tul == 1 { posUlt += 1 }

        // ── 最终六键（执行动作）比对 —— P1-4「对最终六键设验收项」──
        let predictedSix = v3ExpectedSixKeys(result: result, decision: d)
        let truthSix = v3TruthSixKeys(k)
        if predictedSix == truthSix { okSixKey += 1 }
        truthSixSetHistogram[truthSix, default: 0] += 1
        for key in V3SixKey.all {
            let p = predictedSix.contains(key), t = truthSix.contains(key)
            if t { truthSixKeyCounts[key, default: 0] += 1 }
            if p && t { keyTP[key, default: 0] += 1 }
            if p && !t { keyFP[key, default: 0] += 1 }
            if !p && t { keyFN[key, default: 0] += 1 }
        }

        // ── ultimate 覆盖后的执行纵向 —— P1-4「未评价 ultimate 覆盖后的执行纵向」──
        //
        // 生产口径（`InferenceEngineV3.swift:608`）：ultimatePressed → verticalForCommand=2(S)。
        // 故「执行纵向」必须按覆盖后的值比：cover 前只看原始头会漏掉
        // 「模型头说 W、但因为 ultimate 实际执行 S」这一类致命组合。
        let execVertical = d.ultimatePressed ? 2 : d.verticalClass
        if execVertical == tv { okExecVertical += 1 }

        // 执行六键（用覆盖后的纵向）也必须与真值六键一致
        let execResult = InferenceResult(steer: result?.steer ?? 0,
                                         throttle: execVertical == 0 ? 1.0 : 0.0,
                                         brake: execVertical == 2 ? 1.0 : 0.0,
                                         latencyMs: result?.latencyMs ?? 0)
        if v3ExpectedSixKeys(result: execResult, decision: d) == truthSix { okExecSixKey += 1 }
    }

    guard n > 0 else { print("  ✗ 无有效统计样本"); return 1 }
    func pct(_ a: Int, _ b: Int) -> Double { b > 0 ? Double(a) / Double(b) * 100 : 0 }
    func majorityBaseline(_ support: [Int]) -> Int {
        // ★ P1-4②：真多数类基线 = 取真值分布里样本最多的那一类，恒猜它。
        //   旧实现写死「恒猜 NONE」——在 W 占多数的路段（seg_a：W 占 85%）
        //   基线会被算成 17.65%，于是把「模型 12.5%」这种灾难性输出
        //   说成只差 5.15%；真基线是 85.29%，实际差 72.79%。
        return support.max() ?? 0
    }

    print("\n  统计样本 n=\(n)（已跳过前 \(warmupFrames) 帧冷启动）"
          + "  尝试 \(attemptedFrames) 帧，推理失败 \(failedFrames) 帧")
    print("  ────────────────────────────────────────────────────────────")
    print(String(format: "  %-12@ %10@ %10@ %10@", "指标" as NSString,
                 "模型一致率" as NSString, "多数类基线" as NSString, "增益" as NSString))

    // 真值分布（用于真多数类基线 + 值支持度判断）
    // ★ 真值分布必须取**行和**（行=真值）。取列和会得到"预测分布"，
    //   进而把「真多数类基线」指到模型最常预测的那一类上 —— 等于用模型的
    //   偏好当基线，增益会系统性虚高。这是本夹具自查发现的真实错误。
    let supportV = (0..<3).map { r in confusionV[r].reduce(0, +) }
    let supportH = (0..<3).map { r in confusionH[r].reduce(0, +) }
    let okV = (0..<3).reduce(0) { $0 + confusionV[$1][$1] }
    let okH = (0..<3).reduce(0) { $0 + confusionH[$1][$1] }
    let baseV = majorityBaseline(supportV)
    let baseH = majorityBaseline(supportH)
    // 控制头基线：真值多数类（正类占比 >50% → 恒猜 1，否则恒猜 0）
    func headBaseline(_ positives: Int) -> Int { positives * 2 > n ? positives : n - positives }
    /// 真值**单类退化**（正类 0 或 =n）：此时「多数类基线」就是 100%，
    /// 任何模型都不可能「优于基线」→ 该头的增益判定在数学上不可判定。
    /// 这类情况下改判「模型是否全对」并在输出里明确标注不可判定，
    /// 而不是用 +0.00% 冒充"达标"（旧实现正是把 0.00 当通过）。
    func headIsDegenerate(_ positives: Int) -> Bool { positives == 0 || positives == n }
    /// 三分类真值**单类退化**（只有一个类有样本）→ 多数类基线 = 100%，
    /// 增益判定同样**在数学上不可满足**（seg_c/seg_d 的真值纵向就是 W 占 100%）。
    /// 不加这个判据会产出永久假红：模型再完美也只能得 0 增益。
    func classIsDegenerate(_ support: [Int]) -> Bool { support.filter { $0 > 0 }.count == 1 }
    /// 真值里样本最多的那一类名字（用于把「真多数类」如实打进输出）。
    func dominantName(_ support: [Int], _ names: [String]) -> String {
        guard let i = support.indices.max(by: { support[$0] < support[$1] }) else { return "?" }
        return names[i]
    }

    func row(_ name: String, _ ok: Int, _ base: Int) {
        let m = pct(ok, n), b = pct(base, n)
        print(String(format: "  %-12@ %9.2f%% %9.2f%% %+9.2f%%",
                     name as NSString, m, b, m - b))
    }
    row("vertical", okV, baseV)
    row("horizontal", okH, baseH)
    row("brake", okBrake, headBaseline(posBrake))
    row("handbrake", okHand, headBaseline(posHand))
    row("super_brake", okSuper, headBaseline(posSuper))
    row("ultimate", okUlt, headBaseline(posUlt))
    // 最终六键的「真基线」= 恒猜**最常出现的那个真值集合**。
    // 不设 0% 之类无依据的靶子：直道段真值长期是同一个集合，恒猜它就能拿到高一致率，
    // 必须与这个基线比才算证明模型有用（同 vertical/horizontal 的判定哲学）。
    let sixBaseline = truthSixSetHistogram.values.max() ?? 0
    row("六键(最终)", okSixKey, sixBaseline)

    print("\n  ultimate 覆盖后的执行纵向：\(okExecVertical)/\(n)"
          + String(format: "（%.2f%%）", pct(okExecVertical, n)))
    print("  ultimate 覆盖后的执行六键：\(okExecSixKey)/\(n)"
          + String(format: "（%.2f%%）", pct(okExecSixKey, n)))

    // ── 混淆矩阵（P1-4 要求）──
    func printConfusion(_ title: String, _ m: [[Int]], _ names: [String]) {
        print("\n  混淆矩阵（\(title)）  行=真值，列=预测")
        // `%8@` 对 NSString 不做宽度填充（实测输出会挤成一团 "WNONES"），
        // 这里改为手动右对齐，保证矩阵可读、列能对上。
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
        }
        print("        " + names.map { pad($0, 8) }.joined())
        for r in 0..<3 {
            let rowTotal = m[r].reduce(0, +)
            print("  " + pad(names[r], 6) + m[r].map { String(format: "%8d", $0) }.joined()
                  + String(format: "   | 召回 %.1f%%", pct(m[r][r], rowTotal)))
        }
    }
    printConfusion("vertical W/NONE/S", confusionV, ["W", "NONE", "S"])
    printConfusion("horizontal A/NONE/D", confusionH, ["A", "NONE", "D"])

    print("\n  逐类召回（vertical W/NONE/S）：")
    for c in 0..<3 {
        print(String(format: "    %-5@ support=%4d  召回=%.1f%%",
                     ["W", "NONE", "S"][c] as NSString, supportV[c], pct(confusionV[c][c], supportV[c])))
    }
    print("  逐类召回（horizontal A/NONE/D）：")
    for c in 0..<3 {
        print(String(format: "    %-5@ support=%4d  召回=%.1f%%",
                     ["A", "NONE", "D"][c] as NSString, supportH[c], pct(confusionH[c][c], supportH[c])))
    }

    // ── 六键逐键精确率/召回率（执行动作级，便于定位"哪个键接反/不释放"）──
    print("\n  六键逐键（最终执行动作）：")
    for key in V3SixKey.all.sorted() {
        let tp = keyTP[key] ?? 0, fp = keyFP[key] ?? 0, fn = keyFN[key] ?? 0
        let truth = truthSixKeyCounts[key] ?? 0
        // 分母为 0 时**不打印 100%**：那会被误读成"完美"。明确标 n/a（不可判定）。
        let precText = tp + fp > 0 ? String(format: "%.1f%%", pct(tp, tp + fp)) : "n/a(无预测)"
        let recText = truth > 0 ? String(format: "%.1f%%", pct(tp, truth)) : "n/a(真值无)"
        print(String(format: "    %-10@ 真值帧=%4d  TP=%4d FP=%4d FN=%4d  精确率=%@ 召回=%@",
                     V3SixKey.name(key) as NSString, truth, tp, fp, fn,
                     precText as NSString, recText as NSString))
    }

    // ── 判定：必须显著优于真多数类基线 ──
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { print("  ✓ \(name)  — \(detail)") }
        else { failures += 1; print("  ✗ \(name)  — \(detail)") }
    }
    print("")
    check("推理完成率（失败帧必须单独统计）",
          failedFrames == 0 || pct(attemptedFrames - failedFrames, attemptedFrames) >= 98.0,
          "尝试 \(attemptedFrames) 帧，失败 \(failedFrames) 帧"
          + String(format: "（完成率 %.2f%%）", pct(attemptedFrames - failedFrames, attemptedFrames)))
    check("vertical 优于真多数类基线（+5% 以上）",
          classIsDegenerate(supportV) ? okV == n : pct(okV, n) - pct(baseV, n) >= 5.0,
          classIsDegenerate(supportV)
            ? String(format: "真值单类退化（仅 %@，基线=100%%）→ 增益不可判定；模型全对=%@（%d/%d）",
                      dominantName(supportV, ["W", "NONE", "S"]) as NSString,
                      okV == n ? "是" : "否", okV, n)
            : String(format: "增益 %+.2f%%（真多数类 %@ 占 %.1f%%）",
                      pct(okV, n) - pct(baseV, n),
                      dominantName(supportV, ["W", "NONE", "S"]) as NSString, pct(baseV, n)))
    check("horizontal 优于真多数类基线（+5% 以上）",
          classIsDegenerate(supportH) ? okH == n : pct(okH, n) - pct(baseH, n) >= 5.0,
          classIsDegenerate(supportH)
            ? String(format: "真值单类退化（仅 %@，基线=100%%）→ 增益不可判定；模型全对=%@（%d/%d）",
                      dominantName(supportH, ["A", "NONE", "D"]) as NSString,
                      okH == n ? "是" : "否", okH, n)
            : String(format: "增益 %+.2f%%（真多数类 %@ 占 %.1f%%）",
                      pct(okH, n) - pct(baseH, n),
                      dominantName(supportH, ["A", "NONE", "D"]) as NSString, pct(baseH, n)))
    check("brake 头优于真多数类基线（必须真正参与判定）",
          headIsDegenerate(posBrake) ? okBrake == n : pct(okBrake, n) - pct(headBaseline(posBrake), n) > 0.0,
          headIsDegenerate(posBrake)
            ? String(format: "真值单类退化（正类 %d/%d 帧），基线=100%% 不可判定；模型 %d/%d 全对=%@",
                      posBrake, n, okBrake, n, okBrake == n ? "是" : "否")
            : String(format: "一致率 %.2f%%，基线 %.2f%%，增益 %+.2f%%",
                      pct(okBrake, n), pct(headBaseline(posBrake), n),
                      pct(okBrake, n) - pct(headBaseline(posBrake), n)))
    check("handbrake 头优于真多数类基线（必须真正参与判定）",
          headIsDegenerate(posHand) ? okHand == n : pct(okHand, n) - pct(headBaseline(posHand), n) > 0.0,
          headIsDegenerate(posHand)
            ? String(format: "真值单类退化（正类 %d/%d 帧），基线=100%% 不可判定；模型 %d/%d 全对=%@",
                      posHand, n, okHand, n, okHand == n ? "是" : "否")
            : String(format: "一致率 %.2f%%，基线 %.2f%%，增益 %+.2f%%",
                      pct(okHand, n), pct(headBaseline(posHand), n),
                      pct(okHand, n) - pct(headBaseline(posHand), n)))
    // ★ P1-4③：super_brake 与 ultimate 过去「只打印、不参与判定」，现在纳入验收。
    check("super_brake 头优于真多数类基线",
          headIsDegenerate(posSuper) ? okSuper == n : pct(okSuper, n) - pct(headBaseline(posSuper), n) > 0.0,
          headIsDegenerate(posSuper)
            ? String(format: "真值单类退化（正类 %d/%d 帧），基线=100%% 不可判定；模型 %d/%d 全对=%@",
                      posSuper, n, okSuper, n, okSuper == n ? "是" : "否")
            : String(format: "一致率 %.2f%%，基线 %.2f%%（正类 %d 帧）",
                      pct(okSuper, n), pct(headBaseline(posSuper), n), posSuper))
    check("ultimate 头优于真多数类基线",
          headIsDegenerate(posUlt) ? okUlt == n : pct(okUlt, n) - pct(headBaseline(posUlt), n) > 0.0,
          headIsDegenerate(posUlt)
            ? String(format: "真值单类退化（正类 %d/%d 帧），基线=100%% 不可判定；模型 %d/%d 全对=%@",
                      posUlt, n, okUlt, n, okUlt == n ? "是" : "否")
            : String(format: "一致率 %.2f%%，基线 %.2f%%（正类 %d 帧）",
                      pct(okUlt, n), pct(headBaseline(posUlt), n), posUlt))

    // ★ P1-4④：ultimate 覆盖后的执行纵向必须被评价
    check("ultimate 覆盖后的执行纵向（执行口径）优于真多数类基线",
          classIsDegenerate(supportV) ? okExecVertical == n
            : pct(okExecVertical, n) - pct(baseV, n) >= 5.0,
          classIsDegenerate(supportV)
            ? String(format: "真值单类退化（基线=100%%）→ 增益不可判定；执行纵向全对=%@（%d/%d）",
                      okExecVertical == n ? "是" : "否", okExecVertical, n)
            : String(format: "执行纵向一致率 %.2f%%，增益 %+.2f%%",
                      pct(okExecVertical, n), pct(okExecVertical, n) - pct(baseV, n)))
    // 最终六键：与「恒猜最常出现的真值集合」这一真基线比较。
    //   不设 40% 这类无依据的绝对值：直道段真值长期是同一集合，
    //   恒猜它就能拿到高一致率 —— 必须超过该基线才算模型真起作用。
    //   若真值集合本身单类退化（所有帧都是同一个集合），基线=100%，
    //   增益不可判定 → 改判「是否全对」，避免永久假红。
    let sixIsDegenerate = sixBaseline == n
    check("最终六键（执行动作）优于真多数类集合基线",
          sixIsDegenerate ? okSixKey == n : okSixKey > sixBaseline,
          sixIsDegenerate
            ? String(format: "真值单类退化（基线=100%%）→ 增益不可判定；六键全对=%@（%d/%d）",
                      okSixKey == n ? "是" : "否", okSixKey, n)
            : String(format: "完全一致 %d/%d（%.2f%%），基线 %d/%d（%.2f%%），增益 %+.2f%%",
                      okSixKey, n, pct(okSixKey, n), sixBaseline, n, pct(sixBaseline, n),
                      pct(okSixKey, n) - pct(sixBaseline, n)))
    check("ultimate 覆盖后的执行六键优于真多数类集合基线",
          sixIsDegenerate ? okExecSixKey == n : okExecSixKey > sixBaseline,
          sixIsDegenerate
            ? String(format: "真值单类退化（基线=100%%）→ 增益不可判定；执行六键全对=%@（%d/%d）",
                      okExecSixKey == n ? "是" : "否", okExecSixKey, n)
            : String(format: "完全一致 %d/%d（%.2f%%），基线 %.2f%%，增益 %+.2f%%",
                      okExecSixKey, n, pct(okExecSixKey, n), pct(sixBaseline, n),
                      pct(okExecSixKey, n) - pct(sixBaseline, n)))

    print("\n" + bar)
    print(failures == 0 ? "V3 质检：通过 ✓（全部控制头 + 最终六键均达标）"
                        : "V3 质检：失败 \(failures) 项")
    print(bar)
    return failures
}
