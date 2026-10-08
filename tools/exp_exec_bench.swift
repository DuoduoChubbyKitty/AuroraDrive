// ============================================================================
//  exp_exec_bench.swift — 执行路径（computeUnits / MLModelConfiguration / 编译目标）
//                        真机延迟测量台（S2 · 2026-10-09）
//
//  为什么必须用 Swift 而不是 coremltools Python：
//    Python 侧 `MLModel.predict()` 每次都要把 numpy → MLMultiArray 转换，
//    且无法设置 specializationStrategy / allowLowPrecisionAccumulationOnGPU，
//    实测延迟数字比 CoreML 原生路径高一个量级，**不能用来做执行路径对比**。
//
//  用法：
//    exp_exec_bench --model <path> --units all|cpuAndGPU|cpuOnly|cpuAndNE
//                   [--strategy default|fastPrediction]
//                   [--lowprec-accum 0|1] [--reshape frequent|infrequent]
//                   [--rounds 5] [--iters 30] [--warmup 5]
//                   [--plan 0|1] [--label name] [--json out.json]
//
//  输出：单行 `RESULT_JSON {...}` 到 stdout（便于父进程解析），其余为人类可读日志。
//
//  ★ ANE 是否生效的三重判据（缺一不可，见报告 §判定方法）：
//    ① MLComputePlan.deviceUsage 逐算子 preferred 设备统计（静态派发图）
//    ② 延迟量级（ANE 路径 ~2-8ms，CPU 回退 ~15-30ms，差 3-5×）
//    ③ stderr 有无 E5RT/MILCompilerForANE 编译失败日志
// ============================================================================

import Foundation
import CoreML

// ---------------------------------------------------------------- 参数解析
var args = CommandLine.arguments
args.removeFirst()

func argValue(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
let modelPath   = argValue("--model", "")
let unitsName   = argValue("--units", "all")
let strategyName = argValue("--strategy", "default")
let lowPrecAccum = argValue("--lowprec-accum", "0") == "1"
let reshapeName = argValue("--reshape", "frequent")
let rounds      = Int(argValue("--rounds", "5")) ?? 5
let iters       = Int(argValue("--iters", "30")) ?? 30
let warmup      = Int(argValue("--warmup", "5")) ?? 5
let wantPlan    = argValue("--plan", "1") == "1"
let label       = argValue("--label", "")
let jsonOut     = argValue("--json", "")

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("FATAL " + msg + "\n").data(using: .utf8)!)
    exit(2)
}
if modelPath.isEmpty { die("--model 必填") }

func log(_ s: String) { print(s); fflush(stdout) }

// ---------------------------------------------------------------- 配置
let cfg = MLModelConfiguration()
switch unitsName {
case "all":       cfg.computeUnits = .all
case "cpuAndGPU": cfg.computeUnits = .cpuAndGPU
case "cpuOnly":   cfg.computeUnits = .cpuOnly
case "cpuAndNE":  cfg.computeUnits = .cpuAndNeuralEngine
default: die("未知 --units \(unitsName)")
}
if #available(macOS 14.4, *) {
    cfg.optimizationHints.reshapeFrequency =
        (reshapeName == "infrequent") ? .infrequent : .frequent
}
if #available(macOS 15.0, *) {
    cfg.optimizationHints.specializationStrategy =
        (strategyName == "fastPrediction") ? .fastPrediction : .default
}
cfg.allowLowPrecisionAccumulationOnGPU = lowPrecAccum

log("[bench] model=\(modelPath)")
log("[bench] units=\(unitsName) strategy=\(strategyName) lowPrecAccum=\(lowPrecAccum) "
    + "reshape=\(reshapeName) rounds=\(rounds) iters=\(iters) warmup=\(warmup)")

// ---------------------------------------------------------------- 加载 + 编译
var modelURL = URL(fileURLWithPath: modelPath)
let t0 = Date()
if modelPath.hasSuffix(".mlpackage") {
    do {
        let compiled = try MLModel.compileModel(at: modelURL)
        modelURL = compiled
        log("[bench] compileModel(mlpackage) → \(compiled.path)")
    } catch {
        die("compileModel 失败: \(error)")
    }
}
let model: MLModel
do {
    model = try MLModel(contentsOf: modelURL, configuration: cfg)
} catch {
    die("MLModel(contentsOf:) 失败: \(error)")
}
let loadMs = Date().timeIntervalSince(t0) * 1000
log(String(format: "[bench] load+compile = %.1f ms", loadMs))

// ---------------------------------------------------------------- 静态派发图
var deviceCounts: [String: Int] = [:]
var costByDevice: [String: Double] = [:]
var planErr = ""
if wantPlan, #available(macOS 14.4, *) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: cfg)
            if case let .program(prog) = plan.modelStructure {
                func devName(_ d: MLComputeDevice?) -> String {
                    guard let d = d else { return "nil" }
                    switch d {
                    case .cpu: return "cpu"
                    case .gpu: return "gpu"
                    case .neuralEngine: return "ane"
                    @unknown default: return "unknown"
                    }
                }
                func walk(_ b: MLModelStructure.Program.Block) {
                    for op in b.operations {
                        let u = plan.deviceUsage(for: op)
                        let k = devName(u?.preferred)
                        deviceCounts[k, default: 0] += 1
                        if let c = plan.estimatedCost(of: op) {
                            costByDevice[k, default: 0] += c.weight
                        }
                        for sub in op.blocks { walk(sub) }
                    }
                }
                for f in prog.functions.values { walk(f.block) }
            } else {
                planErr = "no_program_structure"
            }
        } catch {
            planErr = "\(error)"
        }
        sem.signal()
    }
    sem.wait()
    log("[bench] plan deviceCounts = \(deviceCounts) planErr=\(planErr.isEmpty ? "-" : planErr)")
    let totalCost = costByDevice.values.reduce(0, +)
    if totalCost > 0 {
        let pct = costByDevice.mapValues { $0 / totalCost * 100 }
        log(String(format: "[bench] plan cost%% = ane %.1f gpu %.1f cpu %.1f",
                   pct["ane"] ?? 0, pct["gpu"] ?? 0, pct["cpu"] ?? 0))
    }
}

// ---------------------------------------------------------------- 输入构造（确定性 LCG，跨变体逐位一致）
final class LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
    }
}

func shapeOf(_ f: MLFeatureDescription) -> [Int] {
    if let ma = f.multiArrayConstraint { return ma.shape.map { $0.intValue } }
    return []
}

// 输入描述按名字排序后固定顺序生成 → 与 python 侧无关，但跨变体绝对一致
let inputDescs = model.modelDescription.inputDescriptionsByName
let inputNames = inputDescs.keys.sorted()
let rng = LCG(20261009)
var inputs: [String: MLMultiArray] = [:]
for name in inputNames {
    let shape = shapeOf(inputDescs[name]!)
    let n = shape.reduce(1, *)
    guard let arr = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
    else { die("MLMultiArray 分配失败 \(name) \(shape)") }
    let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
    for i in 0..<n {
        // lane 用 0/1，其余用 [0,1) —— 避免 NaN/denormal 干扰计时
        if name == "lane" { p[i] = rng.next() > 0.5 ? 1.0 : 0.0 }
        else if name == "det_mask" { p[i] = 1.0 }
        else { p[i] = rng.next() }
    }
    inputs[name] = arr
}
let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
log("[bench] inputs = \(inputNames.map { "\($0)\(shapeOf(inputDescs[$0]!))" }.joined(separator: " "))")

// ---------------------------------------------------------------- 预热
var firstOut = ""
do {
    let out = try model.prediction(from: provider)
    firstOut = out.featureNames.sorted().map { n in
        let v = out.featureValue(for: n)!.multiArrayValue!
        return "\(n)=\(v[0].floatValue)"
    }.joined(separator: " ")
    log("[bench] outputs: \(firstOut)")
} catch {
    die("首次推理失败: \(error)")
}
for _ in 0..<warmup { _ = try? model.prediction(from: provider) }

// ---------------------------------------------------------------- 计时
func uptimeStr() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return "\(tv.tv_sec)"
}

func loadAvg() -> Double {
    var la = [Double](repeating: 0, count: 3)
    getloadavg(&la, 3)
    return la[0]
}

var perIterAll: [[Double]] = []
var roundStats: [[String: Any]] = []
for r in 0..<rounds {
    let upBefore = uptimeStr()
    let laBefore = loadAvg()
    var ts: [Double] = []
    ts.reserveCapacity(iters)
    for _ in 0..<iters {
        let s = DispatchTime.now().uptimeNanoseconds
        _ = try? model.prediction(from: provider)
        let e = DispatchTime.now().uptimeNanoseconds
        ts.append(Double(e - s) / 1e6)
    }
    perIterAll.append(ts)
    let sorted = ts.sorted()
    func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    let mean = ts.reduce(0, +) / Double(ts.count)
    roundStats.append(["round": r, "p50": q(0.50), "p90": q(0.90), "p95": q(0.95),
                       "max": sorted.last ?? 0, "mean": mean, "min": sorted.first ?? 0,
                       "uptime_before": upBefore, "uptime_after": uptimeStr(),
                       "loadavg_before": laBefore, "loadavg_after": loadAvg()])
    log(String(format: "[bench] r%d p50=%.2f p95=%.2f max=%.2f mean=%.2f (uptime=%@ load=%.2f)",
               r, q(0.50), q(0.95), sorted.last ?? 0, mean, upBefore, laBefore))
}

// 全轮合并（R×iters 个样本一起取分位）
let all = perIterAll.flatMap { $0 }.sorted()
func qAll(_ p: Double) -> Double { all[min(all.count - 1, Int(Double(all.count - 1) * p))] }
let p50 = qAll(0.50), p95 = qAll(0.95), p99 = qAll(0.99)
let meanAll = all.reduce(0, +) / Double(all.count)
log(String(format: "[bench] ★ ALL(%d) p50=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f",
           all.count, p50, p95, p99, all.last ?? 0, meanAll))

// ---------------------------------------------------------------- JSON
var result: [String: Any] = [
    "label": label,
    "model": modelPath,
    "units": unitsName,
    "strategy": strategyName,
    "lowprec_accum": lowPrecAccum,
    "reshape": reshapeName,
    "rounds": rounds, "iters": iters, "warmup": warmup,
    "load_ms": loadMs,
    "p50": p50, "p95": p95, "p99": p99, "max": all.last ?? 0, "mean": meanAll,
    "round_stats": roundStats,
    "plan_device_counts": deviceCounts,
    "plan_err": planErr,
    "first_out": firstOut,
    "host_uptime": uptimeStr(),
    "samples": all,
]
if let d = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
    if !jsonOut.isEmpty { try? d.write(to: URL(fileURLWithPath: jsonOut)) }
    print("RESULT_JSON " + String(data: d, encoding: .utf8)!)
    fflush(stdout)
}
