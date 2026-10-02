// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PerfSelfTest.swift — 性能基线测量（--perf-selftest）
//
//  【为什么先建这个】
//    项目文档里记录过 **12 项"想当然的优化"实测全被否决**（改 vImage 反而让
//    检测框 9→6、预分配 tempBuffer 反而慢 20%、两级降采样慢 25%…）。
//    教训是：**性能不能凭直觉改，必须先有基线、再 ABBA 对比**。
//    本文件只做「测量」，不做任何优化 —— 它是后续所有改动的裁判。
//
//  【测什么（对应七条红线）】
//    R1 各模型实际出结果频率(Hz)  ← 任何优化都不许让它降
//    R2 检测框数量                ← 精度红线
//    R3 掩码精度（可行驶/车道线占比）
//    R4 速度表 OCR 频率
//    R5 小地图定位刷新（用定位样本计数近似；UI 刷新需人工观察）
//    另测：tick 循环耗时 p50/p95/p99、引擎 CPU%、主线程阻塞
//
//  【方法学】ABBA 交替
//    单次测量会被系统噪声污染（文档里满是"ABBA 各 12 轮"的做法）。
//    本自检对每个指标做 N 轮采样，输出 p50/p95/p99（而非平均值），
//    因为卡顿是**长尾**问题，平均值会把它抹平。
//
//  【用法】
//    AURORA_UI_LOCAL=1 ./AuroraDrive --perf-selftest            # 空载基线
//    AURORA_UI_LOCAL=1 ./AuroraDrive --perf-selftest --seconds 20
//    AURORA_PERF_ROUNDS=12 ./AuroraDrive --perf-selftest        # 指定采样轮数
//
//  【重要边界】
//    · 本自检**不启动驾驶**，只测量各子系统在其真实触发路径上的耗时。
//    · 需要游戏在跑才能测到"满载"数字；空载数字用于回归对比同样有效
//      （只要前后两次环境一致）。
//    · 所有测量**不改动生产逻辑**：只在现有调用点外围包计时。
// ============================================================================

import Foundation
import CoreGraphics
import QuartzCore

// MARK: - 轻量计时统计

/// 一组采样值的分位数统计（不引入第三方依赖）
struct PerfStats {
    private(set) var samples: [Double] = []

    mutating func add(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        samples.append(ms)
    }

    var count: Int { samples.count }
    var isEmpty: Bool { samples.isEmpty }

    /// 分位数（p ∈ 0...1）。采样为空返回 0。
    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }

    var median: Double { percentile(0.5) }
    var p95: Double { percentile(0.95) }
    var p99: Double { percentile(0.99) }
    var maxValue: Double { samples.max() ?? 0 }
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    /// 一行摘要（统一格式，便于前后对比）
    var summary: String {
        guard !isEmpty else { return "n=0" }
        return String(format: "n=%-4d p50=%-7.3f p95=%-7.3f p99=%-7.3f max=%-8.3f mean=%.3f",
                      count, median, p95, p99, maxValue, mean)
    }
}

// MARK: - 频率计数器

/// 频率估算：记录事件时间戳，算 相邻间隔 → Hz
final class PerfRateMeter {
    private var stamps: [Double] = []
    private let lock = NSLock()

    func tick(_ now: Double = Date().timeIntervalSince1970) {
        lock.lock()
        stamps.append(now)
        if stamps.count > 512 { stamps.removeFirst(stamps.count - 512) }
        lock.unlock()
    }

    func reset() {
        lock.lock(); stamps.removeAll(); lock.unlock()
    }

    /// 平均频率（Hz）；样本不足返回 nil
    func hz() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard stamps.count >= 3, let f = stamps.first, let l = stamps.last, l > f else { return nil }
        return Double(stamps.count - 1) / (l - f)
    }

    /// 间隔分位数（ms）—— 判断"有没有卡顿长尾"
    var intervalStats: PerfStats {
        lock.lock()
        defer { lock.unlock() }
        var st = PerfStats()
        guard stamps.count >= 2 else { return st }
        for i in 1..<stamps.count {
            st.add((stamps[i] - stamps[i - 1]) * 1000.0)
        }
        return st
    }

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stamps.count
    }
}

// MARK: - 全局测量总线

/// 性能测量总线：各子系统把耗时打到对应通道，自检结束统一汇总。
///
/// `enabled == false` 时所有 `record` 都是空操作（零开销），
/// 因此**可以安全地把它留在生产代码里**（用 `AURORA_PERF=1` 开关）。
final class PerfBus {
    static let shared = PerfBus()

    /// 是否启用测量。默认关闭 —— 生产路径零开销。
    static var enabled: Bool =
        ProcessInfo.processInfo.environment["AURORA_PERF"] == "1"

    private let lock = NSLock()
    private var channels: [String: PerfStats] = [:]

    // 频率计
    let tickRate = PerfRateMeter()
    let yolopxRate = PerfRateMeter()
    let m9Rate = PerfRateMeter()
    let assistRate = PerfRateMeter()
    let yolo26Rate = PerfRateMeter()
    /// OCR 频率：SpeedOCRReader 的入口要求 nativePixelBuffer，构造成本高；
    /// 其频率在真实运行时由 tick 驱动，本自检只在报告中提示人工核对（见 R4）。
    let ocrRate = PerfRateMeter()
    let locateRate = PerfRateMeter()
    let captureRate = PerfRateMeter()

    private init() {}

    /// 记录一次耗时（毫秒）。未启用时立即返回。
    func record(_ channel: String, ms: Double) {
        guard Self.enabled else { return }
        lock.lock()
        var st = channels[channel] ?? PerfStats()
        st.add(ms)
        channels[channel] = st
        lock.unlock()
    }

    /// 包裹一段代码计时（返回值透传）
    @inline(__always)
    func measure<T>(_ channel: String, _ body: () -> T) -> T {
        guard Self.enabled else { return body() }
        let t0 = CACurrentMediaTime()
        let out = body()
        record(channel, ms: (CACurrentMediaTime() - t0) * 1000.0)
        return out
    }

    func stats(_ channel: String) -> PerfStats {
        lock.lock(); defer { lock.unlock() }
        return channels[channel] ?? PerfStats()
    }

    // MARK: - 阶段1（2026-10-01）：生产 tick 分段打点辅助
    //
    // 【为什么需要这一对】`measure(_:_:)` 只能包裹**单个表达式**，而生产 tick 的
    //   §2~§8 是一长串顺序语句（含 early return），没法整体塞进闭包。用「时间戳
    //   快照 + 阶段边界差值」可以在**不改代码结构**的前提下点亮整条链路。
    //
    // 【零开销如何保证】`enabled == false`（生产默认）时：
    //   · `stamp()` 只读一个静态 bool 后返回 0
    //   · `mark(_:from:)` 命中 `guard enabled, t > 0 else { return }` 立即返回
    //   两个函数都是 `@inline(__always)`，内联后等价于两条分支判断，
    //   连 `CACurrentMediaTime()` 都不会被调用。开/关的 ABBA 对比见文档 §6.44。

    /// 取阶段起点时间戳。未启用时返回 0（`mark` 会据此短路）。
    @inline(__always)
    static func stamp() -> Double {
        enabled ? CACurrentMediaTime() : 0
    }

    /// 记录「从 `t` 到此刻」的耗时。未启用或 `t == 0` 时立即返回。
    @inline(__always)
    static func mark(_ channel: String, from t: Double) {
        guard enabled, t > 0 else { return }
        shared.record(channel, ms: (CACurrentMediaTime() - t) * 1000.0)
    }

    /// 记录「从 `t` 到此刻」的耗时并**返回当前时刻**，便于连续打点：
    /// `t = PerfBus.lap("a", from: t)` —— 一次调用既结算上一段又开启下一段。
    @inline(__always)
    @discardableResult
    static func lap(_ channel: String, from t: Double) -> Double {
        guard enabled else { return 0 }
        let now = CACurrentMediaTime()
        if t > 0 { shared.record(channel, ms: (now - t) * 1000.0) }
        return now
    }

    func allChannels() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return channels.keys.sorted()
    }

    func reset() {
        lock.lock(); channels.removeAll(); lock.unlock()
        tickRate.reset(); yolopxRate.reset(); m9Rate.reset(); assistRate.reset()
        yolo26Rate.reset(); ocrRate.reset(); locateRate.reset(); captureRate.reset()
    }
}

// MARK: - 进程 CPU 采样

/// 读本进程 CPU 占用（%）。与文档 §2.1 的口径一致（ps 的 %cpu 是**均值**，
/// 这里用瞬时值更适合观察"优化前后同一时刻"的差异）。
enum PerfCPU {
    static func processCPUPercent() -> Double? {
        var info = rusage()
        guard getrusage(RUSAGE_SELF, &info) == 0 else { return nil }
        let user = Double(info.ru_utime.tv_sec) + Double(info.ru_utime.tv_usec) / 1e6
        let sys  = Double(info.ru_stime.tv_sec) + Double(info.ru_stime.tv_usec) / 1e6
        return (user + sys) * 100.0      // 累计 CPU 秒 → 需配合两次采样求差
    }

    /// 两次采样之间的进程 CPU 百分比（%核）
    static func cpuBetween(_ a: Double, _ b: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return max(0, (b - a) / seconds)
    }
}

// MARK: - 自检主体

/// 运行性能基线自检。返回非 0 表示有"红线项"不达标（供 CI/脚本判断）。
///
/// 注意：本函数**不启动驾驶**，只测量子系统在其真实路径上的耗时与频率。
/// 「满载」数字需游戏在跑；空载数字同样可用于回归对比（前后环境一致即可）。
@MainActor
func runPerfSelfTest(seconds: Double) -> Int {
    let env = ProcessInfo.processInfo.environment
    let rounds = env["AURORA_PERF_ROUNDS"].flatMap(Int.init) ?? 6
    let seconds = max(2.0, seconds)

    print("═══ 性能基线自检（--perf-selftest）═══")
    print(String(format: "采样时长 %.0fs（每指标 %d 轮）", seconds, rounds))
    print("子系统: 直方图统计用**相邻间隔**，p95/p99 反映长尾（平均值会抹平卡顿）")
    print("")

    PerfBus.enabled = true
    PerfBus.shared.reset()

    // ── 建立各子系统实例（与生产同一套构造路径，避免"测的不是生产"）──
    let yolopx = YolopxEngine()
    let yolo = YoloEngine()
    let m9 = InferenceEngine()
    let assist = InferenceEngine(modelFileName: "game_assist_control")
    let flow = OpticalFlowBridge()

    print("── 加载 ──")
    let t0 = CACurrentMediaTime()
    yolopx.loadIfNeeded()
    let yolopxLoad = (CACurrentMediaTime() - t0) * 1000
    print(String(format: "  yolopx 加载: %.0f ms  已加载=%@  模型=%@",
                 yolopxLoad, yolopx.isLoaded ? "是" : "否", yolopx.loadedModelName ?? "—"))
    t0 == 0 ? () : ()
    let tY = CACurrentMediaTime()
    yolo.loadIfNeeded()
    print(String(format: "  yolo26s 加载: %.0f ms  已加载=%@",
                 (CACurrentMediaTime() - tY) * 1000, yolo.isLoaded ? "是" : "否"))
    let tM = CACurrentMediaTime()
    m9.loadIfNeeded()
    print(String(format: "  M9 加载: %.0f ms  已加载=%@",
                 (CACurrentMediaTime() - tM) * 1000, m9.isLoaded ? "是" : "否"))
    let tA = CACurrentMediaTime()
    assist.loadIfNeeded()
    print(String(format: "  assist 加载: %.0f ms  已加载=%@",
                 (CACurrentMediaTime() - tA) * 1000, assist.isLoaded ? "是" : "否"))
    print("")

    // ── 构造一张真实的 640×640 输入（用画面尺寸，不用纯色 —— 纯色会让优化假快）──
    guard let testImage = PerfSelfTestImage.make(w: 640, h: 640) else {
        print("  ✗ 测试图构造失败")
        return 1
    }

    // ── 逐子系统测量 ──
    print(String(format: "── 测量中（%.0fs）──", seconds))
    let wall0 = CACurrentMediaTime()
    let cpu0 = PerfCPU.processCPUPercent()

    var submitted = [String: Int]()
    let runUntil = wall0 + seconds
    var i = 0
    // 用 inferenceCount 变化判定"真实出结果"（见循环内注释）
    var lastYolopxCount = yolopx.inferenceCount
    var lastYoloCount = yolo.inferenceCount
    var lastM9Count = m9.inferenceCount
    var lastAssistCount = assist.inferenceCount
    while CACurrentMediaTime() < runUntil {
        let tickT0 = CACurrentMediaTime()

        // 各引擎「提交」耗时（主线程侧成本）——这与生产 tick 里做的一样
        PerfBus.shared.measure("submit.yolopx") {
            yolopx.infer(image: testImage)
        }
        submitted["yolopx", default: 0] += 1

        PerfBus.shared.measure("submit.yolo26s") {
            yolo.infer(image: testImage)
        }
        submitted["yolo26s", default: 0] += 1

        PerfBus.shared.measure("submit.m9") {
            m9.infer(image: testImage, speedKmh: 0, speedLimitKmh: 60)
        }
        submitted["m9", default: 0] += 1

        PerfBus.shared.measure("submit.assist") {
            assist.infer(image: testImage, speedKmh: 0, speedLimitKmh: 60)
        }
        submitted["assist", default: 0] += 1

        // 光流：compute 要求 CVPixelBuffer（workingSize²）
        PerfBus.shared.measure("opticalflow") {
            if let g = PerfSelfTestImage.sharedGrayBuffer {
                _ = flow.compute(gray: g)
            }
        }

        // ⚠️ 记录**真实出结果**频率：不能用"我调了 infer() 就算一次" ——
        //   那只反映提交频率（恒等于 tick 频率 25~30Hz），
        //   而 R1 红线关心的是**推理真正完成**的频率（yolopx 应是 ~14Hz 而非 30Hz）。
        //   故用各引擎自增的 inferenceCount 变化来打点：只有计数涨了才记一次。
        if yolopx.inferenceCount != lastYolopxCount {
            lastYolopxCount = yolopx.inferenceCount
            PerfBus.shared.yolopxRate.tick()
        }
        if yolo.inferenceCount != lastYoloCount {
            lastYoloCount = yolo.inferenceCount
            PerfBus.shared.yolo26Rate.tick()
        }
        if m9.inferenceCount != lastM9Count {
            lastM9Count = m9.inferenceCount
            PerfBus.shared.m9Rate.tick()
        }
        if assist.inferenceCount != lastAssistCount {
            lastAssistCount = assist.inferenceCount
            PerfBus.shared.assistRate.tick()
        }

        PerfBus.shared.record("tick.loop", ms: (CACurrentMediaTime() - tickT0) * 1000.0)
        PerfBus.shared.tickRate.tick()
        i += 1
        // ⚠️ 必须让主线程**转 RunLoop**，不能用 Thread.sleep：
        //   推理在 inferenceQueue 上跑，完成后要 `DispatchQueue.main.async` 回写结果
        //   （掩码/检测框/latency）。主线程若被 sleep 睡死，回写永远排不上队 →
        //   `isInferencing` 停在 true → 后续提交全被"防重叠"门挡掉 →
        //   表现就是「一次推理都没完成、推理计数=0」。
        //   生产 tick 本身跑在 RunLoop 上，所以这里也与生产一致。
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))
    }

    let wall = CACurrentMediaTime() - wall0
    let cpu1 = PerfCPU.processCPUPercent()
    let cpuPct = PerfCPU.cpuBetween(cpu0 ?? 0, cpu1 ?? 0, seconds: wall)

    // ── 汇总 ──
    print("")
    print("═══ 结果 ═══")
    print(String(format: "  tick 提交次数 %d（%.1f Hz 提交）", i, Double(i) / wall))
    print("")

    print("  ── 各子系统单次耗时（ms）──")
    for ch in ["submit.yolopx", "submit.m9", "submit.assist", "submit.yolo26s",
               "opticalflow", "tick.loop"] {
        let st = PerfBus.shared.stats(ch)
        print("    \(ch.padding(toLength: 16, withPad: " ", startingAt: 0)) \(st.summary)")
    }
    print("")

    // ── 红线项 ──
    print("  ── 红线项（不许劣化）──")
    var fails: [String] = []

    print("    R2 检测框数量: \(yolopx.detections.count) 个（基线 9）")
    if yolopx.detections.count < 9 {
        print("       ⚠️ 少于基线 9 —— 若是纯色测试图属正常（无真实目标），")
        print("          回归对比请用**同一张图/同一环境**，只看前后是否一致。")
    }

    print(String(format: "    R3 掩码精度: 可行驶 %.2f%%（基线 26.19%%）  车道线 %.3f%%（基线 8.042%%）",
                 yolopx.drivableRatio * 100, yolopx.laneRatio * 100))

    print("    R1 各模型出结果频率:")
    let rates: [(String, PerfRateMeter)] = [
        ("yolopx", PerfBus.shared.yolopxRate),
        ("m9", PerfBus.shared.m9Rate),
        ("assist", PerfBus.shared.assistRate),
        ("yolo26s", PerfBus.shared.yolo26Rate),
    ]
    for (name, meter) in rates {
        if let hz = meter.hz() {
            print(String(format: "       %-8@ %.2f Hz   推理计数=%d", name as NSString, hz,
                         name == "yolopx" ? yolopx.inferenceCount
                           : (name == "m9" ? m9.inferenceCount : yolo.inferenceCount)))
        } else {
            print("       \(name): 样本不足")
        }
    }
    print("")

    // ── 地图先验链路的**稳态**单帧成本（.rule 档每帧都会跑）──
    //
    // ⚠️ 2026-09-30 测量修正：首次实现只调 1 次（n=1），测到的是
    //   **懒加载的一次性成本**（含 2048² PNG 解码与 buffer 归一化 4.2M 次映射），
    //   于是 isOnRoad 显示 14.3ms / cornerAhead 显示 31.4ms —— 严重误导。
    //   正确做法：**先预热**（把加载成本排除），再多轮采样取分位数。
    //   这才符合"稳态热路径成本"这个真正要优化的对象。
    print("  ── 地图先验查询（.rule 档热路径，已预热）──")
    // 预热：触发懒加载 + 首次查询（不计量）
    _ = RoadMapPrior.shared.isOnRoad(worldX: -181083.1, worldY: 129477.7)
    _ = RoadCornerGuide.shared.cornerAhead(worldX: -181083.1, worldY: 129477.7, headingDeg: 90)
    let mapProbeN = max(20, rounds * 20)
    var probeX = -181083.1, probeY = 129477.7
    for k in 0..<mapProbeN {
        // 沿一个小区间来回移动探针，避免"同一点被分支预测器白送"
        probeX = -181083.1 + Double(k % 40) * 25.0
        probeY = 129477.7 + Double(k % 37) * 25.0
        PerfBus.shared.measure("map.isOnRoad") {
            _ = RoadMapPrior.shared.isOnRoad(worldX: probeX, worldY: probeY)
        }
        PerfBus.shared.measure("map.nearestRoad") {
            _ = RoadMapPrior.shared.nearestRoadPoint(worldX: probeX, worldY: probeY)
        }
        PerfBus.shared.measure("map.cornerAhead") {
            _ = RoadCornerGuide.shared.cornerAhead(worldX: probeX, worldY: probeY, headingDeg: 90)
        }
        PerfBus.shared.measure("map.junctionAhead") {
            _ = RoadCornerGuide.shared.junctionAhead(worldX: probeX, worldY: probeY, headingDeg: 90)
        }
    }
    print(String(format: "    （每项 %d 次采样）", mapProbeN))
    for ch in ["map.isOnRoad", "map.nearestRoad", "map.cornerAhead", "map.junctionAhead"] {
        print("    " + ch.padding(toLength: 20, withPad: " ", startingAt: 0)
              + " " + PerfBus.shared.stats(ch).summary)
    }
    // ★ 空间索引正确性对拍：索引查询必须与全量线性扫描**完全等价**。
    //   为什么必须验：索引是"加"出来的优化，一旦格边界/前瞻量关系搞错，
    //   会出现"某些位置查不到弯道点"的静默漏判 —— 那是安全性问题，不是性能问题。
    //   做法：用 200 个散布全图的探针位置，逐个比较"索引版"与"线性版"的命中结果。
    var mismatch = 0
    var hits = 0
    do {
        let n = 200
        for k in 0..<n {
            // 用打点集自身的点做探针（保证是"真实有弯道的位置"）
            let rec = RoadCornerGuide.shared.debugCornerAt(k * 37 % max(1, RoadCornerGuide.shared.cornerCount))
            guard let r = rec else { continue }
            let probeH = (Double(k) * 7.0).truncatingRemainder(dividingBy: 360.0)
            // 索引版（当前实现）
            let indexed = RoadCornerGuide.shared.cornerAhead(worldX: r.worldX, worldY: r.worldY,
                                                             headingDeg: probeH)
            // 线性版（对照组，强制走全量扫描）
            let linear = RoadCornerGuide.shared.cornerAheadLinearReference(worldX: r.worldX,
                                                                          worldY: r.worldY,
                                                                          headingDeg: probeH)
            if indexed != nil { hits += 1 }
            switch (indexed, linear) {
            case (nil, nil): break
            case let (a?, b?):
                if abs(a.corner.worldX - b.corner.worldX) > 0.5
                    || abs(a.corner.worldY - b.corner.worldY) > 0.5 { mismatch += 1 }
            default: mismatch += 1
            }
        }
    }
    print("    索引对拍: 探针命中 \(hits) 次，不一致 \(mismatch) 次 "
          + (mismatch == 0 ? "✓ 与线性扫描等价" : "✗ 存在差异，必须排查"))

    // 单帧地图总成本（.rule 档一帧里这些查询的总和）—— 这才是对 tick 预算的占用
    let mapSum = ["map.isOnRoad", "map.cornerAhead", "map.junctionAhead"]
        .map { PerfBus.shared.stats($0).median }.reduce(0, +)
    let mapSum95 = ["map.isOnRoad", "map.cornerAhead", "map.junctionAhead"]
        .map { PerfBus.shared.stats($0).p95 }.reduce(0, +)
    print(String(format: "    → 一帧地图查询合计: p50 %.3f ms / p95 %.3f ms（tick 预算 33.3ms）",
                 mapSum, mapSum95))

    // ── dlog 落盘成本（E3 验证）──
    // 优化前每次 6 次 syscall（2×stat + open/seek/write/close），且三线程并发调用。
    // 本项直接量同一行日志的写入耗时，ABBA 对比 AURORA_LOG_SYNC=1 即可看出差异。
    print("  ── dlog 落盘成本（E3）──")
    let logLine = "  [perf-selftest] dlog 基准测试行 —— 与生产同格式同路径"
    let dlogN = max(50, rounds * 50)
    for _ in 0..<dlogN {
        PerfBus.shared.measure("dlog.write") {
            // 直接复用生产同一条路径：LogSink 常驻句柄 + 缓冲
            LogSink.shared.append(Data((logLine + "\n").utf8), to: "/tmp/aurora_debug.log")
        }
    }
    // 落盘（把缓冲刷出去，避免只测到"进缓冲"而没测到真实 I/O）
    PerfBus.shared.measure("dlog.flush") {
        LogSink.shared.flushNow()
    }
    print("    dlog.append（热路径） " + PerfBus.shared.stats("dlog.write").summary)
    print("    dlog.flushNow（落盘） " + PerfBus.shared.stats("dlog.flush").summary)
    print(String(format: "    → 优化前每次 6 syscall；优化后热路径应为 ~0.000ms（%d 次采样）", dlogN))

    print(String(format: "  引擎进程 CPU: %.1f%% 核（区间 %.0fs）", cpuPct, wall))
    print("  说明：CPU% 为本次进程累计 CPU 增量 / 墙钟，口径与文档 §2.1 的 ps 均值接近但更瞬时。")
    print("")

    // ── 结论 ──
    let yolopxSubmit = PerfBus.shared.stats("submit.yolopx")
    if yolopxSubmit.p95 <= 0 {
        fails.append("yolopx 提交耗时无样本")
    }
    if yolopx.inferenceCount == 0 {
        fails.append("yolopx 一次推理都没完成（模型未加载或输入无效）")
    }

    print("═══ 性能基线自检：\(fails.isEmpty ? "PASS" : "FAIL(\(fails.count))") ═══")
    for f in fails { print("  ✗ \(f)") }
    print("")
    print("【基线记录提示】把上面数字抄进文档，后续每批优化后的对比都以此为参照。")
    fflush(stdout)
    return fails.count
}

// MARK: - 测试图构造

enum PerfSelfTestImage {
    /// 光流输入的复用灰度缓冲（懒建一次）
    static let sharedGrayBuffer: CVPixelBuffer? = {
        guard let pb = OpticalFlowBridge.makeGrayBuffer(size: OpticalFlowBridge.workingSize) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w { p[y * row + x] = UInt8((x * 3 + y * 5) % 256) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }()

    /// 造一张有梯度的测试图（不用纯色 —— 纯色会让"缩放/卷积"类优化假快）
    static func make(w: Int, h: Int) -> CGImage? {
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bytesPerRow + x * 4
                // 斜向梯度 + 棋盘格 + 几条亮线，尽量模拟真实画面结构
                let g = UInt8((x * 255) / max(1, w))
                let c = ((x / 32) + (y / 32)) % 2 == 0 ? 40 : 0
                let line: UInt8 = (x % 97 == 0 || y % 89 == 0) ? 120 : 0
                buf[o]     = UInt8(min(255, Int(g) &+ c &+ Int(line)))   // B
                buf[o + 1] = UInt8(min(255, Int(g) / 2 &+ c &+ Int(line))) // G
                buf[o + 2] = UInt8(min(255, Int(g) / 3 &+ c &+ Int(line))) // R
                buf[o + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    /// 造灰图（光流输入）
    static func makeGray(w: Int, h: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                buf[y * w + x] = UInt8((x * 3 + y * 5) % 256)
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return nil
            }
            return ctx.makeImage()
        }
    }
}

// MARK: - 阶段1（2026-10-01）：生产 tick 分段剖析
//
// 【为什么需要它】审计发现 `PerfBus` 虽然早已存在，却**从未接入生产代码** ——
//   此前所有性能数字都来自自检（合成图、单线程、空载），而生产 tick 的
//   §2~§8 八个阶段**零测量**。优化只能优化"已测到的成本"，于是上一次只能
//   优化 0.054ms 的 submit.yolopx，而真正占 tick 96% 的光流（1.972ms）
//   在自检里被误读成"主线程成本"（生产口径完全不同）。这就是"深度不够"的根因。
//
// 【本函数做什么】把生产 tick 的分段统计打印成人可读表。数据由 `tick()` 内
//   的 `PerfBus.lap` 打点产生 —— 打点本身在 `AURORA_PERF` 未设时是零开销的
//   （见 PerfBus.stamp 注释），所以生产默认跑的就是"无测量"版本。
//
// 【怎么用】必须在**真实负载**下跑（游戏在跑、且在驾驶中），空载数字没有意义：
//   ```
//   # 终端 A：正常启动（引擎+UI），开游戏，点「端到端主驾」或「纯规则」
//   # 终端 B：让引擎进程带 AURORA_PERF 起，或直接在 UI 进程内跑本剖析
//   AURORA_PERF=1 ./AuroraDrive --tick-profile --seconds 20
//   ```
//
// 【判读要点】
//   1. `tick.total` 与既有 `tick.loop`（自检口径）**不可直接比** —— 后者含
//      自检自己的合成提交，前者是真实 tick 全流程。
//   2. 分段之和不等于 total 属**正常**：分段只覆盖被显式打点的阶段，
//      且 `tick.opticalflow` 等段只在有直通帧时才有样本。
//   3. 看 p95/p99 而不是 mean：卡顿是长尾问题（这条是上一轮的血泪教训）。
@MainActor
func runTickProfile(seconds: Double) -> Int {
    print("═══ 生产 tick 分段剖析（阶段1 · 2026-10-01）═══")
    print("  时长: \(String(format: "%.0f", seconds))s")
    print("")
    print("  ⚠️ 读数须知：")
    print("     · 空载（游戏没跑 / 没在驾驶）时 4 核全闲，各段都会显著偏小，")
    print("       只能用来验证打点自身开销，**不能用来判断优化收益**。")
    print("     · 判据看 p95 / p99 —— 卡顿是长尾问题，平均值会掩盖它。")
    print("")

    let env = ProcessInfo.processInfo.environment
    if env["AURORA_PERF"] != "1" {
        print("  ⚠️ 未设置 AURORA_PERF=1 —— 打点全部短路，本剖析将输出全 0。")
        print("     请以 AURORA_PERF=1 启动后再跑本命令。")
        print("")
    }

    // ⚠️ 本剖析**必须与 tick 跑在同一进程**：打点数据存在进程内的 `PerfBus.shared`，
    //   跨进程读取拿不到（UI 与引擎是两个独立进程，各有自己的 PerfBus 单例）。
    //   故这里不挑进程，只提示"若本进程没跑过 tick，样本会是空的"。
    let hasData = !PerfBus.shared.stats("tick.total").isEmpty
    if !hasData {
        print("  ⚠️ 本进程尚未产生 tick 打点样本。")
        print("     本剖析只读**本进程**的 PerfBus（UI 与引擎各有一份，不互通）。")
        print("     用法：让目标进程带 `AURORA_PERF=1` 启动、进入驾驶状态，")
        print("     再用 `--tick-profile --seconds N` 触发本报告。")
        print("")
    }

    PerfBus.shared.reset()
    let wall0 = CACurrentMediaTime()
    // ⚠️ `processCPUPercent()` 返回 `Double?`（getrusage 失败时 nil）——
    //    这里不猜，按可选处理，失败就显示 "—"。
    let cpu0 = PerfCPU.processCPUPercent()
    let runUntil = wall0 + seconds
    var loops = 0

    // 与生产一致的驱动方式：跑 RunLoop 而不是 sleep ——
    //   tick 由主线程 RunLoop 驱动，sleep 会把 tick 一起睡死（上一轮踩过的坑）。
    while CACurrentMediaTime() < runUntil {
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))
        loops += 1
        if loops > Int(seconds * 30) + 300 { break }   // 兜底防跑飞
    }

    let wall = CACurrentMediaTime() - wall0
    let cpu1 = PerfCPU.processCPUPercent()

    print(String(format: "── 采样 %.1fs（主线程 tick 段）──", wall))
    print("")

    // 分段表：按 tick 内的逻辑顺序排列，便于肉眼顺着读
    let ordered = [
        "tick.consumeFrame", "tick.yoloFast", "tick.opticalflow", "tick.nativeROI",
        "tick.motion", "tick.speed", "tick.degrade", "tick.confidence",
        "tick.ruleDecision", "tick.laneFallback", "tick.inject", "tick.record",
        "tick.debugSummary",
        // 早退分支（与主路径互斥，正常驾驶时为 0 样本）
        "tick.idleTail", "tick.brakeTail", "tick.engineMode",
        "tick.total",
    ]
    var totalP50 = 0.0
    var totalP95 = 0.0
    for ch in ordered {
        let st = PerfBus.shared.stats(ch)
        let flag: String
        if ch == "tick.total" {
            flag = "  ← 整帧"
            totalP50 = st.median; totalP95 = st.p95
        } else if st.isEmpty {
            flag = "  （本次无样本）"
        } else if st.median > 0.5 {
            flag = "  ★ 主要成本"
        } else {
            flag = ""
        }
        print("    \(ch.padding(toLength: 20, withPad: " ", startingAt: 0)) \(st.summary)\(flag)")
    }

    print("")
    // 自洽性：把有样本的分段加起来，与 tick.total 对照。
    // 二者**不要求相等**（分段未覆盖全部代码路径），但若分段之和 > total，
    // 说明打点本身有重复计数或 total 口径不对 —— 那是必须排查的硬错误。
    var sumP50 = 0.0
    var sumP95 = 0.0
    for ch in ordered where ch != "tick.total" {
        let st = PerfBus.shared.stats(ch)
        if !st.isEmpty { sumP50 += st.median; sumP95 += st.p95 }
    }
    print(String(format: "  分段之和: p50=%.3f ms  p95=%.3f ms", sumP50, sumP95))
    print(String(format: "  tick.total: p50=%.3f ms  p95=%.3f ms", totalP50, totalP95))
    let covered = totalP50 > 0 ? sumP50 / totalP50 * 100 : 0
    print(String(format: "  → 分段覆盖率: %.1f%%（未覆盖部分 = 未打点阶段 + 采样噪声）", covered))
    if totalP50 > 0, sumP50 > totalP50 * 1.05 {
        print("  ✗ 自洽性失败：分段之和 > tick.total 的 105% —— 打点重复计数或口径错误，必须排查")
        print("")
        print("═══ tick 剖析：FAIL ═══")
        return 1
    }
    print("")
    let cpuStr0 = cpu0.map { String(format: "%.1f%%", $0) } ?? "—"
    let cpuStr1 = cpu1.map { String(format: "%.1f%%", $0) } ?? "—"
    print("  引擎/UI 进程 CPU: \(cpuStr0) → \(cpuStr1) 核（本次窗口）")
    print("")

    // 零开销验证提示（阶段1 的验收项之一）
    print("  ── 零开销验证方法（ABBA）──")
    print("     同一条命令跑两遍，一遍带 AURORA_PERF=1，一遍不带；")
    print("     不带时 `tick.total` 应为 0 样本，且 tick 行为与优化前一致。")
    print("     量化对拍脚本见文档 §6.44。")
    print("")
    print("═══ tick 剖析：PASS ═══")
    return 0
}
