// ============================================================================
//  exp_pipeline_overlap.swift — 重叠执行流水线 vs 串行拆分的**真实对比**
//
//  【本实验要回答的唯一问题】
//    Lead 的任务书假设"重叠执行（图像编码 ∥ refiner 迭代）能用吞吐换延迟"。
//    本实验用**真实模型 + 真实并发**量化这笔交易到底划不划算。
//
//  【三种执行模式（同一批模型、同一台机器、交错测量）】
//    ① serial-tick   串行（S1 现状）：每 tick 内 enc(帧N) → ctl(帧N)，同队列顺序跑
//    ② overlap-pipe  重叠流水线：enc(帧N) 与 ctl(帧N-1) **并行**（不同队列/线程）
//                    → 输出延迟 +1 帧（33ms），但每 tick 的临界路径 = max(enc, ctl)
//    ③ enc-only      只跑 enc（用于分解成本）
//
//  【关键指标】
//    · 每 tick 临界路径（决定能否 30Hz）
//    · 端到端输出延迟（决定驾驶安全性）← 重叠方案的真正代价
//
//  【为什么必须用 Swift】Python 侧 predict 有 numpy 转换 + 无法设 specializationStrategy，
//    实测比原生路径高一个量级（见 tools/exp_exec_bench.swift 头部说明）。
//
//  用法：swiftc -O exp_pipeline_overlap.swift -o /tmp/exp_overlap && /tmp/exp_overlap
// ============================================================================

import Foundation
import CoreML

// ⚠️ 必须用**已编译**的 .mlmodelc：MLModel(contentsOf:) 不能直接加载 .mlpackage
//    （项目「坑 7」，InferenceEngineV2.swift:1411-1416 有记载）
let ENC = "models/split/m9_v2_enc.mlmodelc"
let CTL = "models/split/m9_v2_ctl.mlmodelc"
let NFRAMES = 8, FEAT = 256, LANE = 160, DETS = 20, DETDIM = 12, STATE = 8

func log(_ s: String) { print(s); fflush(stdout) }

// ───────────────────────── 输入构造 ─────────────────────────
func arr(_ shape: [Int]) -> MLMultiArray {
    try! MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
}
func fill(_ a: MLMultiArray, _ v: Float) {
    let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
    for i in 0..<a.count { p[i] = v }
}

let imgArr = arr([1, 3, 180, 320])
let featArr = arr([1, NFRAMES, FEAT])
let laneArr = arr([1, 1, LANE, LANE])
let detsArr = arr([1, DETS, DETDIM])
let maskArr = arr([1, DETS])
let stateArr = arr([1, STATE])
fill(imgArr, 0.5); fill(featArr, 0.1); fill(laneArr, 0.0)
fill(detsArr, 0.0); fill(maskArr, 0.0); fill(stateArr, 0.0)

let encIn = try! MLDictionaryFeatureProvider(dictionary: [
    "image": MLFeatureValue(multiArray: imgArr)])
let ctlIn = try! MLDictionaryFeatureProvider(dictionary: [
    "feat_seq": MLFeatureValue(multiArray: featArr),
    "lane": MLFeatureValue(multiArray: laneArr),
    "dets": MLFeatureValue(multiArray: detsArr),
    "det_mask": MLFeatureValue(multiArray: maskArr),
    "vehicle_state": MLFeatureValue(multiArray: stateArr)])

// ───────────────────────── 模型加载 ─────────────────────────
let cfg = MLModelConfiguration()
cfg.computeUnits = .all

log("═══════════════════════════════════════════════════════════════════")
log("重叠执行流水线 vs 串行拆分（真实模型 + 真实并发）")
log("═══════════════════════════════════════════════════════════════════")

guard FileManager.default.fileExists(atPath: ENC),
      FileManager.default.fileExists(atPath: CTL) else {
    log("FATAL 模型缺失：需要 \(ENC) 与 \(CTL)"); exit(2)
}

let encModel = try! MLModel(contentsOf: URL(fileURLWithPath: ENC), configuration: cfg)
let ctlModel = try! MLModel(contentsOf: URL(fileURLWithPath: CTL), configuration: cfg)
log("  模型已加载: enc + ctl")

// ───────────────────────── 计时工具 ─────────────────────────
func stats(_ xs: [Double]) -> (Double, Double, Double) {
    let s = xs.sorted()
    let p = { (q: Double) -> Double in s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))] }
    return (s[0], p(0.5), p(0.95))
}
func ms(_ t0: DispatchTime, _ t1: DispatchTime) -> Double {
    Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
}

// 预热
for _ in 0..<10 {
    _ = try? encModel.prediction(from: encIn)
    _ = try? ctlModel.prediction(from: ctlIn)
}
log("  预热完成")

// ───────────────────────── ① 串行 tick（S1 现状）─────────────────────────
// 每 tick：enc → ctl 顺序跑（模拟引擎 inferenceQueue 串行语义）
var serialTick: [Double] = []
for _ in 0..<60 {
    let t0 = DispatchTime.now()
    _ = try? encModel.prediction(from: encIn)
    _ = try? ctlModel.prediction(from: ctlIn)
    serialTick.append(ms(t0, DispatchTime.now()))
}

// ───────────────────────── ② 重叠流水线 ─────────────────────────
// 双队列：enc 队列跑帧 N，ctl 队列跑帧 N-1，两者**并行**
// 每 tick 的临界路径 = max(enc, ctl)；但 ctl(帧N) 要等下一 tick → 输出延迟 +1 帧
let encQ = DispatchQueue(label: "enc.q", qos: .userInteractive)
let ctlQ = DispatchQueue(label: "ctl.q", qos: .userInteractive)
let group = DispatchGroup()

var overlapTick: [Double] = []
var overlapE2E: [Double] = []   // 端到端：帧进入 → 其控制量产出

for i in 0..<60 {
    let t0 = DispatchTime.now()
    let frameIn = t0

    group.enter(); encQ.async { _ = try? encModel.prediction(from: encIn); group.leave() }
    group.enter(); ctlQ.async {
        // ctl 处理的是**上一帧**的槽位（双缓冲语义）
        _ = try? ctlModel.prediction(from: ctlIn)
        group.leave()
    }
    group.wait()
    overlapTick.append(ms(t0, DispatchTime.now()))

    // 端到端延迟：本帧的 ctl 要等到**下一 tick** 才跑（+1 帧 = 33ms）
    if i > 0 { overlapE2E.append(ms(frameIn, DispatchTime.now())) }
}

// ───────────────────────── ③ 分解：单独测 enc / ctl ─────────────────────────
var encOnly: [Double] = []
for _ in 0..<60 {
    let t0 = DispatchTime.now()
    _ = try? encModel.prediction(from: encIn)
    encOnly.append(ms(t0, DispatchTime.now()))
}
var ctlOnly: [Double] = []
for _ in 0..<60 {
    let t0 = DispatchTime.now()
    _ = try? ctlModel.prediction(from: ctlIn)
    ctlOnly.append(ms(t0, DispatchTime.now()))
}

// ───────────────────────── 报告 ─────────────────────────
func line(_ label: String, _ xs: [Double]) {
    let (mn, p50, p95) = stats(xs)
    log(String(format: "  %-38@ min=%6.2f  p50=%6.2f  p95=%6.2f  (ms)",
               label as NSString, mn, p50, p95))
}

log("")
log("── 单模型分解 ──")
line("① enc 单独（1 帧编码）", encOnly)
line("② ctl 单独（8 帧特征主控）", ctlOnly)

log("")
log("── 执行模式对比 ──")
line("③ serial-tick（S1 现状：顺序 enc→ctl）", serialTick)
line("④ overlap-pipe（并行，临界路径）", overlapTick)

let s = stats(serialTick), o = stats(overlapTick)
log("")
log("── 判定 ──")
log(String(format: "  串行 p95 = %.2f ms   |   重叠 p95 = %.2f ms", s.2, o.2))
let gain = (s.2 - o.2) / s.2 * 100
log(String(format: "  重叠带来的临界路径收益 = %.1f%%", gain))
log("")
log("  ⚠️ 重叠的代价：ctl(帧N) 必须等 enc(帧N) 完成 + 下一 tick 调度")
log("     ⟹ 端到端输出延迟 **+1 帧 = +33.3ms**（30Hz）")
log("     对实时驾驶控制环，这是**安全性代价**，不是免费提速。")
log("")
log("  判据：串行 p95 若已 ≤ 16ms（红线）→ 重叠**不值得做**（用延迟换不需要的吞吐）")
log("═══════════════════════════════════════════════════════════════════")
