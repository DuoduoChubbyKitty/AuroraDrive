#!/usr/bin/env swift
// ANE 派发检查（MLComputePlan 算子级证据）
//
// 【为什么必须用 Swift】S7 实测：coremltools Python 的 predict() 对 1ms 级小模型
//   完全失真（numpy→MLMultiArray 转换 + 无 specializationStrategy 固定开销主导）。
//   判 ANE 必须看 **算子级设备派发**（preferred + supported + cost），不能看 A/C 比值。
//
// 用法：
//   swift tools/ane_dispatch_check.swift models/m9_v2_enc.mlmodelc
//   swift tools/ane_dispatch_check.swift models/m9_v2_ctl.mlmodelc

import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: swift ane_dispatch_check.swift <model.mlmodelc 路径>")
    exit(1)
}
let modelURL = URL(fileURLWithPath: args[1])
let cfg = MLModelConfiguration()
cfg.computeUnits = .all
let name = (modelURL.path as NSString).lastPathComponent

func devName(_ d: MLComputeDevice?) -> String {
    guard let d = d else { return "nil" }
    switch d {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "ane"
    @unknown default: return "unknown"
    }
}

// ── 延迟测量（min-of-60，抗争抢）──
func measureLatency(_ model: MLModel) -> (Double, Double, Double, Double)? {
    var dict: [String: MLFeatureValue] = [:]
    for (inName, desc) in model.modelDescription.inputDescriptionsByName {
        guard let c = desc.multiArrayConstraint else { continue }
        guard let arr = try? MLMultiArray(shape: c.shape, dataType: .float32) else { return nil }
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        let count = c.shape.reduce(1) { $0 * $1.intValue }
        for i in 0..<count { ptr[i] = Float.random(in: 0...0.5) }
        dict[inName] = MLFeatureValue(multiArray: arr)
    }
    guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict) else { return nil }
    var times: [Double] = []
    for _ in 0..<60 {
        let t0 = Date()
        _ = try? model.prediction(from: provider)
        times.append(Date().timeIntervalSince(t0) * 1000)
    }
    times.sort()
    return (times[0], times[times.count / 2],
            times[Int(Double(times.count) * 0.95)], times[times.count - 1])
}

guard let model = try? MLModel(contentsOf: modelURL, configuration: cfg) else {
    print("❌ 加载失败: \(modelURL.path)")
    exit(1)
}

print("═══ ANE 派发检查: \(name) ═══")

if #available(macOS 14.4, *) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: cfg)
            if case let .program(prog) = plan.modelStructure {
                var deviceCounts: [String: Int] = [:]
                var supportedCounts: [String: Int] = [:]
                var costByDevice: [String: Double] = [:]
                var nonANE: [(String, String, Double)] = []

                func walk(_ b: MLModelStructure.Program.Block) {
                    for op in b.operations {
                        let u = plan.deviceUsage(for: op)
                        let k = devName(u?.preferred)
                        deviceCounts[k, default: 0] += 1
                        for d in (u?.supported ?? []) {
                            supportedCounts[devName(d), default: 0] += 1
                        }
                        var w = 1.0
                        if let c = plan.estimatedCost(of: op) {
                            w = c.weight
                            costByDevice[k, default: 0] += c.weight
                        }
                        if k != "ane" { nonANE.append((op.operatorName, k, w)) }
                        for sub in op.blocks { walk(sub) }
                    }
                }
                for f in prog.functions.values { walk(f.block) }

                let total = deviceCounts.values.reduce(0, +)
                print("算子总数: \(total)")
                print("preferred 设备派发:")
                for (dev, cnt) in deviceCounts.sorted(by: { $0.value > $1.value }) {
                    let pct = total > 0 ? Double(cnt) / Double(total) * 100 : 0
                    print(String(format: "  %-6@ %5d  (%.1f%%)", dev as NSString, cnt, pct))
                }
                let totalCost = costByDevice.values.reduce(0, +)
                let aneCost = costByDevice["ane"] ?? 0
                let aneCostPct = totalCost > 0 ? aneCost / totalCost * 100 : 0
                print(String(format: "ANE cost 占比: %.1f%%  (ANE %.1f / 总 %.1f)",
                             aneCostPct, aneCost, totalCost))
                print("supported 集合统计: \(supportedCounts.sorted { $0.value > $1.value })")

                print("\n非 ANE 算子（按 cost 排序，前 15）:")
                let grouped = Dictionary(grouping: nonANE, by: { "\($0.0) → \($0.1)" })
                    .map { (k: $0.key, cost: $0.value.reduce(0) { $0 + $1.2 }, cnt: $0.value.count) }
                    .sorted { $0.cost > $1.cost }
                for g in grouped.prefix(15) {
                    print(String(format: "  %-42@ ×%-4d cost=%.1f", g.k as NSString, g.cnt, g.cost))
                }
                if grouped.isEmpty { print("  ✅ 无（全部算子 preferred=ANE）") }
            } else {
                print("⚠️ 无 program 结构（非 MLProgram）")
            }
        } catch {
            print("⚠️ MLComputePlan 失败: \(error)")
        }
        sem.signal()
    }
    sem.wait()
}

if let (mn, p50, p95, mx) = measureLatency(model) {
    print(String(format: "\n延迟（min-of-60）: min=%.3fms  p50=%.3fms  p95=%.3fms  max=%.3fms",
                 mn, p50, p95, mx))
}
