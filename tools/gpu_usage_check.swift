#!/usr/bin/env swift
// gpu_usage_check.swift — 多模型串联 GPU 零占用实测（S3 · 2026-10-09）
//
// 【铁律】推理绝对不能碰 GPU。
//
// 做四件事：
//   ① 把 .mlpackage 编译成 .mlmodelc（若已有则跳过）
//   ② 跑多模型串联 N 次：enc → tf → chunk1..6 → head
//   ③ 每个模型用 MLComputePlan 检查 preferred/supported 设备（算子级派发图）
//   ④ 测量串联总延迟 p50/p95/max，逐模型延迟，确认所有模型零 GPU
//
// 另外支持 --mode per-model：对 9 个模型分别测 .all / .cpuOnly / .cpuAndNE 三种
// computeUnits 的延迟，输出对比表。chunk5/chunk6（MoE 828节点）重点标注。
//
// 用法：
//   swift tools/gpu_usage_check.swift --pipeline
//   swift tools/gpu_usage_check.swift --per-model
//   swift tools/gpu_usage_check.swift --pipeline --per-model
//
// 复用自 ane_dispatch_check.swift（MLComputePlan 派发）+ exp_exec_bench.swift（LCG/计时）

import CoreML
import Foundation

// ---------------------------------------------------------------- 工具
func log(_ s: String) { print(s); fflush(stdout) }
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("FATAL " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

final class LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
    }
}

func devName(_ d: MLComputeDevice?) -> String {
    guard let d = d else { return "nil" }
    switch d {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "ane"
    @unknown default: return "unknown"
    }
}

func shapeOf(_ f: MLFeatureDescription) -> [Int] {
    if let ma = f.multiArrayConstraint { return ma.shape.map { $0.intValue } }
    return []
}

// ---------------------------------------------------------------- 参数
var args = CommandLine.arguments
args.removeFirst()
func argValue(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
let wantPipeline = args.contains("--pipeline")
let wantPerModel = args.contains("--per-model")
let rounds = Int(argValue("--rounds", "8")) ?? 8
let iters = Int(argValue("--iters", "40")) ?? 40
let warmup = Int(argValue("--warmup", "5")) ?? 5
if !wantPipeline && !wantPerModel { die("用法: --pipeline / --per-model 至少给一个") }

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let multiDir = root.appendingPathComponent("models/multi_split")
let encMLC = root.appendingPathComponent("models/split24/m9_v2_enc.mlmodelc")

// 模型清单（串联顺序）
struct ModelEntry { let key: String; let path: URL; let moe: Bool }
let pipelineOrder: [ModelEntry] = [
    ModelEntry(key: "enc",    path: encMLC, moe: false),
    ModelEntry(key: "tf",     path: multiDir.appendingPathComponent("m9_v2_tf.mlmodelc"), moe: false),
    ModelEntry(key: "chunk1", path: multiDir.appendingPathComponent("m9_v2_chunk1.mlmodelc"), moe: false),
    ModelEntry(key: "chunk2", path: multiDir.appendingPathComponent("m9_v2_chunk2.mlmodelc"), moe: false),
    ModelEntry(key: "chunk3", path: multiDir.appendingPathComponent("m9_v2_chunk3.mlmodelc"), moe: false),
    ModelEntry(key: "chunk4", path: multiDir.appendingPathComponent("m9_v2_chunk4.mlmodelc"), moe: false),
    ModelEntry(key: "chunk5", path: multiDir.appendingPathComponent("m9_v2_chunk5.mlmodelc"), moe: true),
    ModelEntry(key: "chunk6", path: multiDir.appendingPathComponent("m9_v2_chunk6.mlmodelc"), moe: true),
    ModelEntry(key: "head",   path: multiDir.appendingPathComponent("m9_v2_head.mlmodelc"), moe: false),
]

// 逐模型 3 档测量的模型集合（包含 enc 之外的 8 个 multi_split + enc 共9个）
let allModels: [ModelEntry] = pipelineOrder

func unitsFor(_ key: String) -> MLComputeUnits {
    // 串联默认派发：enc→cpuAndNE，其余→cpuOnly
    return key == "enc" ? .cpuAndNeuralEngine : .cpuOnly
}

// ---------------------------------------------------------------- ① 编译（mlpackage→mlmodelc）
func ensureCompiled(_ entry: ModelEntry) -> URL {
    if entry.path.pathExtension == "mlmodelc" && FileManager.default.fileExists(atPath: entry.path.path) {
        return entry.path
    }
    // 兜底：若 mlmodelc 不存在，尝试找同名 mlpackage 编译
    let pkg = entry.path.deletingPathExtension().appendingPathExtension("mlpackage")
    guard FileManager.default.fileExists(atPath: pkg.path) else { die("模型不存在: \(entry.path.path)") }
    do {
        let compiled = try MLModel.compileModel(at: pkg)
        log("[编译] \(entry.key): \(pkg.lastPathComponent) → mlmodelc")
        return compiled
    } catch { die("编译失败 \(entry.key): \(error)") }
}

// ---------------------------------------------------------------- ③ MLComputePlan 算子级派发
struct PlanResult {
    var preferred: [String: Int] = [:]
    var supported: [String: Int] = [:]
    var costByDevice: [String: Double] = [:]
    var totalOps = 0
    var gpuOps = 0
    var planErr = ""
}
func computePlan(_ url: URL, _ cfg: MLModelConfiguration) -> PlanResult {
    var r = PlanResult()
    guard #available(macOS 14.4, *) else { r.planErr = "macOS<14.4"; return r }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: cfg)
            if case let .program(prog) = plan.modelStructure {
                func walk(_ b: MLModelStructure.Program.Block) {
                    for op in b.operations {
                        let u = plan.deviceUsage(for: op)
                        let k = devName(u?.preferred)
                        r.preferred[k, default: 0] += 1
                        r.totalOps += 1
                        if k == "gpu" { r.gpuOps += 1 }
                        for d in (u?.supported ?? []) {
                            r.supported[devName(d), default: 0] += 1
                        }
                        if let c = plan.estimatedCost(of: op) {
                            r.costByDevice[k, default: 0] += c.weight
                        }
                        for sub in op.blocks { walk(sub) }
                    }
                }
                for f in prog.functions.values { walk(f.block) }
            } else {
                r.planErr = "no_program_structure"
            }
        } catch { r.planErr = "\(error)" }
        sem.signal()
    }
    sem.wait()
    return r
}

// ---------------------------------------------------------------- 输入构造（确定性）
// 串联需要逐模型手工构造输入并接好数据流
func makeMultiArray(_ shape: [Int], _ rng: LCG, _ kind: String) -> MLMultiArray {
    let n = shape.reduce(1, *)
    guard let arr = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
    else { die("MLMultiArray 分配失败 shape=\(shape)") }
    let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
    for i in 0..<n {
        switch kind {
        case "lane": p[i] = rng.next() > 0.5 ? 1.0 : 0.0
        case "det_mask": p[i] = 1.0
        case "image": p[i] = rng.next() * 0.5   // 图像像素 [0,0.5)
        default: p[i] = rng.next()
        }
    }
    return arr
}

// 单模型输入构造（按 description 自动填充，逐变体一致）
func buildInputs(_ desc: MLModelDescription, _ rng: LCG) -> MLDictionaryFeatureProvider {
    let names = desc.inputDescriptionsByName.keys.sorted()
    var dict: [String: MLMultiArray] = [:]
    for name in names {
        let shape = shapeOf(desc.inputDescriptionsByName[name]!)
        let kind = name
        dict[name] = makeMultiArray(shape, rng, kind)
    }
    return try! MLDictionaryFeatureProvider(dictionary: dict)
}

// ---------------------------------------------------------------- 计时
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

// ════════════════════════════════════════════════════════════════════
// ③+④ 串联实测（enc→tf→chunk1-6→head）
// ════════════════════════════════════════════════════════════════════
func runPipeline() {
    log("\n" + String(repeating: "═", count: 70))
    log(" 串联实测：enc(cpuAndNE) → tf → chunk1-6 → head  （cpuOnly）")
    log(String(repeating: "═", count: 70))

    // 加载 + 派发图
    var models: [String: MLModel] = [:]
    var plans: [String: PlanResult] = [:]
    var totalGPU = 0
    for entry in pipelineOrder {
        let url = ensureCompiled(entry)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = unitsFor(entry.key)
        guard let m = try? MLModel(contentsOf: url, configuration: cfg) else { die("加载失败 \(entry.key)") }
        models[entry.key] = m
        let pr = computePlan(url, cfg)
        plans[entry.key] = pr
        totalGPU += pr.gpuOps
        let unitsStr = entry.key == "enc" ? "cpuAndNE" : "cpuOnly"
        let gpuFlag = pr.gpuOps == 0 ? "✅0GPU" : "❌\(pr.gpuOps)GPU"
        log(String(format: "[plan] %-7@ units=%-9@ ops=%-4d preferred=%@ %@",
                   entry.key as NSString, unitsStr as NSString, pr.totalOps,
                   "\(pr.preferred)", gpuFlag))
    }
    log(String(format: "\n[派发汇总] 9 模型 GPU 算子总数 = %d  %@",
               totalGPU, totalGPU == 0 ? "✅ 全链路零 GPU" : "❌ 有 GPU 派发！"))

    // ── 串联数据流 ──
    // enc: image[1,3,180,320] → feat[1,256]，跑8次拼 feat_seq[1,8,256]
    let rng = LCG(20261009)
    let imageArr = makeMultiArray([1, 3, 180, 320], rng, "image")
    let encProvider = try! MLDictionaryFeatureProvider(dictionary: ["image": imageArr])
    let encModel = models["enc"]!

    // tf 输入
    let laneArr = makeMultiArray([1, 1, 160, 160], LCG(11), "lane")
    let detsArr = makeMultiArray([1, 20, 12], LCG(22), "dets")
    let detMaskArr = makeMultiArray([1, 20], LCG(33), "det_mask")
    let vehicleStateArr = makeMultiArray([1, 8], LCG(44), "vehicle_state")

    // head 额外输入（img_feat/det_feat/det_mask 来自 tf 输出）
    // ── 预热 ──
    log("\n[串联] 预热 \(warmup) 次 ...")
    for _ in 0..<warmup {
        guard let encOut = try? encModel.prediction(from: encProvider),
              let feat0 = encOut.featureValue(for: "feat")?.multiArrayValue else { die("enc 推理失败") }
        // 模拟 8 帧拼接
        guard let featSeq = try? MLMultiArray(shape: [1, 8, 256], dataType: .float32) else { die("featSeq 分配失败") }
        let fsPtr = featSeq.dataPointer.bindMemory(to: Float.self, capacity: 8 * 256)
        let fPtr = feat0.dataPointer.bindMemory(to: Float.self, capacity: 256)
        for f in 0..<8 { for i in 0..<256 { fsPtr[f * 256 + i] = fPtr[i] } }
        let tfProv = try! MLDictionaryFeatureProvider(dictionary: [
            "feat_seq": featSeq, "lane": laneArr, "dets": detsArr,
            "det_mask": detMaskArr, "vehicle_state": vehicleStateArr])
        guard let tfOut = try? models["tf"]!.prediction(from: tfProv),
              var fused = tfOut.featureValue(for: "fused")?.multiArrayValue,
              let imgFeat = tfOut.featureValue(for: "img_feat")?.multiArrayValue,
              let detFeat = tfOut.featureValue(for: "det_feat")?.multiArrayValue
        else { die("tf 推理失败") }
        for ci in 1...6 {
            let ck = "chunk\(ci)"
            let cProv = try! MLDictionaryFeatureProvider(dictionary: ["fused": fused])
            guard let cOut = try? models[ck]!.prediction(from: cProv),
                  let refined = cOut.featureValue(for: "refined")?.multiArrayValue
            else { die("\(ck) 推理失败") }
            fused = refined
        }
        let hProv = try! MLDictionaryFeatureProvider(dictionary: [
            "fused": fused, "img_feat": imgFeat, "det_feat": detFeat, "det_mask": detMaskArr])
        _ = try? models["head"]!.prediction(from: hProv)
    }

    // ── 正式计时：逐模型 + 串联总 ──
    var perModelTimes: [String: [Double]] = [:]
    for e in pipelineOrder { perModelTimes[e.key] = [] }
    var chainTimes: [Double] = []

    log("[串联] \(rounds) 轮 × \(iters) 次 ...")
    for r in 0..<rounds {
        var roundChain: [Double] = []
        for _ in 0..<iters {
            let tStart = DispatchTime.now().uptimeNanoseconds

            // enc
            let e0 = DispatchTime.now().uptimeNanoseconds
            guard let encOut = try? encModel.prediction(from: encProvider),
                  let feat0 = encOut.featureValue(for: "feat")?.multiArrayValue else { die("enc 失败") }
            let e1 = DispatchTime.now().uptimeNanoseconds
            perModelTimes["enc"]!.append(Double(e1 - e0) / 1e6)

            // 拼接 feat_seq
            guard let featSeq = try? MLMultiArray(shape: [1, 8, 256], dataType: .float32) else { die("featSeq 失败") }
            let fsPtr = featSeq.dataPointer.bindMemory(to: Float.self, capacity: 8 * 256)
            let fPtr = feat0.dataPointer.bindMemory(to: Float.self, capacity: 256)
            for f in 0..<8 { for i in 0..<256 { fsPtr[f * 256 + i] = fPtr[i] } }

            // tf
            let tfProv = try! MLDictionaryFeatureProvider(dictionary: [
                "feat_seq": featSeq, "lane": laneArr, "dets": detsArr,
                "det_mask": detMaskArr, "vehicle_state": vehicleStateArr])
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let tfOut = try? models["tf"]!.prediction(from: tfProv),
                  var fused = tfOut.featureValue(for: "fused")?.multiArrayValue,
                  let imgFeat = tfOut.featureValue(for: "img_feat")?.multiArrayValue,
                  let detFeat = tfOut.featureValue(for: "det_feat")?.multiArrayValue
            else { die("tf 失败") }
            let t1 = DispatchTime.now().uptimeNanoseconds
            perModelTimes["tf"]!.append(Double(t1 - t0) / 1e6)

            // chunk1-6
            for ci in 1...6 {
                let ck = "chunk\(ci)"
                let cProv = try! MLDictionaryFeatureProvider(dictionary: ["fused": fused])
                let c0 = DispatchTime.now().uptimeNanoseconds
                guard let cOut = try? models[ck]!.prediction(from: cProv),
                      let refined = cOut.featureValue(for: "refined")?.multiArrayValue
                else { die("\(ck) 失败") }
                let c1 = DispatchTime.now().uptimeNanoseconds
                perModelTimes[ck]!.append(Double(c1 - c0) / 1e6)
                fused = refined
            }

            // head
            let hProv = try! MLDictionaryFeatureProvider(dictionary: [
                "fused": fused, "img_feat": imgFeat, "det_feat": detFeat, "det_mask": detMaskArr])
            let h0 = DispatchTime.now().uptimeNanoseconds
            _ = try? models["head"]!.prediction(from: hProv)
            let h1 = DispatchTime.now().uptimeNanoseconds
            perModelTimes["head"]!.append(Double(h1 - h0) / 1e6)

            let tEnd = DispatchTime.now().uptimeNanoseconds
            roundChain.append(Double(tEnd - tStart) / 1e6)
        }
        chainTimes.append(contentsOf: roundChain)
        let sorted = roundChain.sorted()
        log(String(format: "[串联] r%d  chain p50=%.2f p95=%.2f max=%.2f (n=%d)",
                   r, percentile(sorted, 0.5), percentile(sorted, 0.95),
                   sorted.last ?? 0, sorted.count))
    }

    // ── 汇总 ──
    log("\n" + String(repeating: "─", count: 70))
    log(" 逐模型延迟（串联内，单位 ms）")
    log(String(repeating: "─", count: 70))
    log(String(format: " %-7@ %8@ %8@ %8@ %8@ %5@", "模型", "p50", "p95", "max", "mean", "GPU" as NSString))
    for e in pipelineOrder {
        let ts = perModelTimes[e.key]!.sorted()
        let moe = e.moe ? " (MoE)" : ""
        log(String(format: " %-7@ %8.3f %8.3f %8.3f %8.3f %5@%@",
                   e.key as NSString,
                   percentile(ts, 0.5), percentile(ts, 0.95), ts.last ?? 0,
                   ts.reduce(0, +) / Double(ts.count),
                   (plans[e.key]!.gpuOps == 0 ? "0" : "\(plans[e.key]!.gpuOps)") as NSString,
                   moe as NSString))
    }
    let cs = chainTimes.sorted()
    log("\n" + String(repeating: "─", count: 70))
    log(" 串联总延迟（enc+tf+chunk1-6+head，含 feat_seq 拼接开销）")
    log(String(repeating: "─", count: 70))
    log(String(format: " p50=%.2fms  p95=%.2fms  p99=%.2fms  max=%.2fms  mean=%.2fms  n=%d",
               percentile(cs, 0.5), percentile(cs, 0.95), percentile(cs, 0.99),
               cs.last ?? 0, cs.reduce(0, +) / Double(cs.count), cs.count))
    log(String(format: " 等效频率 = %.1f Hz  |  30Hz 预算余量 = %.2f×",
               1000.0 / percentile(cs, 0.95), 33.0 / percentile(cs, 0.95)))
    log(String(format: " GPU 算子总数 = %d  %@",
               totalGPU, totalGPU == 0 ? "✅ 零 GPU 占用，铁律满足" : "❌ 违反铁律！"))
    log(String(repeating: "─", count: 70))

    // ── 派发图明细 ──
    log("\n" + String(repeating: "─", count: 70))
    log(" MLComputePlan 派发图明细（per-model）")
    log(String(repeating: "─", count: 70))
    for e in pipelineOrder {
        let p = plans[e.key]!
        let tc = p.costByDevice.values.reduce(0, +)
        let anePct = tc > 0 ? (p.costByDevice["ane"] ?? 0) / tc * 100 : 0
        let cpuPct = tc > 0 ? (p.costByDevice["cpu"] ?? 0) / tc * 100 : 0
        let gpuPct = tc > 0 ? (p.costByDevice["gpu"] ?? 0) / tc * 100 : 0
        log(String(format: " %-7@ ops=%-4d preferred=%@ | supported=%@ | cost%% ane=%.0f cpu=%.0f gpu=%.0f %@",
                   e.key as NSString, p.totalOps,
                   "\(p.preferred)", "\(p.supported)", anePct, cpuPct, gpuPct,
                   p.gpuOps == 0 ? "✅" : "❌"))
    }
}

// ════════════════════════════════════════════════════════════════════
// ② 逐模型 3 档 computeUnits 对比（.all / .cpuOnly / .cpuAndNE）
// ════════════════════════════════════════════════════════════════════
func runPerModel() {
    log("\n" + String(repeating: "═", count: 70))
    log(" 逐模型 3 档对比：.all / .cpuOnly / .cpuAndNE  （单位 ms）")
    log(String(repeating: "═", count: 70))

    let unitsList: [(String, MLComputeUnits)] = [
        ("all", .all), ("cpuOnly", .cpuOnly), ("cpuAndNE", .cpuAndNeuralEngine),
    ]

    log(String(format: " %-9@ %18@ %18@ %18@ %6@",
               "模型" as NSString, ".all" as NSString,
               ".cpuOnly" as NSString, ".cpuAndNE" as NSString, "MoE" as NSString))

    var summaryRows: [[String: Any]] = []
    for entry in allModels {
        let url = ensureCompiled(entry)
        var row: [String: Any] = ["key": entry.key, "moe": entry.moe]
        var unitsResults: [String: [String: Any]] = [:]
        var firstPlanGPU = -1

        for (uname, u) in unitsList {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = u
            guard let m = try? MLModel(contentsOf: url, configuration: cfg) else {
                log("[per] \(entry.key) \(uname) 加载失败")
                continue
            }
            let rng = LCG(20261009)
            let provider = buildInputs(m.modelDescription, rng)

            // 派发图（仅 .all 模式打印一次，检查 GPU 派发）
            if uname == "all" {
                let pr = computePlan(url, cfg)
                firstPlanGPU = pr.gpuOps
                row["plan_preferred"] = pr.preferred
                row["plan_supported"] = pr.supported
                row["plan_gpu_ops"] = pr.gpuOps
                row["plan_total_ops"] = pr.totalOps
            }

            // 预热
            for _ in 0..<warmup { _ = try? m.prediction(from: provider) }

            // 计时
            var ts: [Double] = []
            for _ in 0..<(rounds * iters / 4) {
                let s = DispatchTime.now().uptimeNanoseconds
                _ = try? m.prediction(from: provider)
                let e = DispatchTime.now().uptimeNanoseconds
                ts.append(Double(e - s) / 1e6)
            }
            ts.sort()
            let p50 = percentile(ts, 0.5), p95 = percentile(ts, 0.95), mx = ts.last ?? 0
            unitsResults[uname] = ["p50": p50, "p95": p95, "max": mx]
            row[uname] = ["p50": p50, "p95": p95, "max": mx]
        }
        row["units"] = unitsResults
        summaryRows.append(row)

        func fmt(_ u: String) -> String {
            guard let r = unitsResults[u] else { return "      -" }
            let p50 = r["p50"] as! Double, p95 = r["p95"] as! Double
            return String(format: "%6.2f/%6.2f", p50, p95)
        }
        let moeStr = entry.moe ? "✓MoE" : ""
        let gpuStr = firstPlanGPU == 0 ? " ✅" : (firstPlanGPU > 0 ? " ❌\(firstPlanGPU)" : "")
        log(String(format: " %-9@ %18@ %18@ %18@ %6@@@",
                   entry.key as NSString, fmt("all") as NSString,
                   fmt("cpuOnly") as NSString, fmt("cpuAndNE") as NSString,
                   moeStr as NSString, gpuStr as NSString))
    }

    // chunk5/chunk6 重点
    log("\n" + String(repeating: "─", count: 70))
    log(" chunk5/chunk6（828节点 MoE）重点分析")
    log(String(repeating: "─", count: 70))
    for row in summaryRows where (row["moe"] as? Bool) == true {
        let key = row["key"] as! String
        guard let u = row["units"] as? [String: [String: Any]] else { continue }
        log("  \(key):")
        for uname in ["all", "cpuOnly", "cpuAndNE"] {
            guard let r = u[uname] else { continue }
            log(String(format: "    %-10@ p50=%6.3f  p95=%6.3f  max=%6.3f",
                       uname as NSString, r["p50"] as! Double,
                       r["p95"] as! Double, r["max"] as! Double))
        }
        if let gpu = row["plan_gpu_ops"] as? Int {
            log(String(format: "    GPU派发算子=%d %@", gpu, gpu == 0 ? "✅" : "❌"))
        }
    }
}

// ════════════════════════════════════════════════════════════════════
if wantPipeline { runPipeline() }
if wantPerModel { runPerModel() }
log("\n[完成] gpu_usage_check.swift 结束")
