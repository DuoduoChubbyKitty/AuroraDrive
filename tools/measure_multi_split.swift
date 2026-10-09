#!/usr/bin/env swift
// 多模型串联延迟实测（min-of-60）
// 测两种策略：全 cpuOnly vs enc+chunk5/6 cpuAndNE + 其余 cpuOnly
import CoreML
import Foundation

let dir = "models/multi_split"
let encPath = "models/split24/m9_v2_enc.mlmodelc"

struct ModelSpec {
    let name: String
    let path: String
    let units: MLComputeUnits
}

// 策略1：全 cpuOnly
let allCPU: [ModelSpec] = [
    .init(name: "enc", path: encPath, units: .cpuAndNeuralEngine), // enc 必须走 ANE
    .init(name: "tf", path: "\(dir)/m9_v2_tf.mlmodelc", units: .cpuOnly),
    .init(name: "c1", path: "\(dir)/m9_v2_chunk1.mlmodelc", units: .cpuOnly),
    .init(name: "c2", path: "\(dir)/m9_v2_chunk2.mlmodelc", units: .cpuOnly),
    .init(name: "c3", path: "\(dir)/m9_v2_chunk3.mlmodelc", units: .cpuOnly),
    .init(name: "c4", path: "\(dir)/m9_v2_chunk4.mlmodelc", units: .cpuOnly),
    .init(name: "c5", path: "\(dir)/m9_v2_chunk5.mlmodelc", units: .cpuOnly),
    .init(name: "c6", path: "\(dir)/m9_v2_chunk6.mlmodelc", units: .cpuOnly),
    .init(name: "head", path: "\(dir)/m9_v2_head.mlmodelc", units: .cpuOnly),
]

// 策略2：enc+chunk5/6 走 ANE，其余 cpuOnly
let mixedANECPU: [ModelSpec] = [
    .init(name: "enc", path: encPath, units: .cpuAndNeuralEngine),
    .init(name: "tf", path: "\(dir)/m9_v2_tf.mlmodelc", units: .cpuOnly),
    .init(name: "c1", path: "\(dir)/m9_v2_chunk1.mlmodelc", units: .cpuOnly),
    .init(name: "c2", path: "\(dir)/m9_v2_chunk2.mlmodelc", units: .cpuOnly),
    .init(name: "c3", path: "\(dir)/m9_v2_chunk3.mlmodelc", units: .cpuOnly),
    .init(name: "c4", path: "\(dir)/m9_v2_chunk4.mlmodelc", units: .cpuOnly),
    .init(name: "c5", path: "\(dir)/m9_v2_chunk5.mlmodelc", units: .cpuAndNeuralEngine),
    .init(name: "c6", path: "\(dir)/m9_v2_chunk6.mlmodelc", units: .cpuAndNeuralEngine),
    .init(name: "head", path: "\(dir)/m9_v2_head.mlmodelc", units: .cpuOnly),
]

func loadModel(_ spec: ModelSpec) -> MLModel? {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = spec.units
    return try? MLModel(contentsOf: URL(fileURLWithPath: spec.path), configuration: cfg)
}

func makeProvider(_ model: MLModel) -> MLDictionaryFeatureProvider? {
    var dict: [String: MLFeatureValue] = [:]
    for (inName, desc) in model.modelDescription.inputDescriptionsByName {
        guard let c = desc.multiArrayConstraint else { continue }
        guard let arr = try? MLMultiArray(shape: c.shape, dataType: .float32) else { return nil }
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        let count = c.shape.reduce(1) { $0 * $1.intValue }
        for i in 0..<count { ptr[i] = Float.random(in: 0...0.5) }
        dict[inName] = MLFeatureValue(multiArray: arr)
    }
    return try? MLDictionaryFeatureProvider(dictionary: dict)
}

func benchStrategy(_ specs: [ModelSpec], _ label: String) {
    print("\n═══ \(label) ═══")
    // 预加载
    var models: [(String, MLModel, MLDictionaryFeatureProvider)] = []
    for spec in specs {
        guard let m = loadModel(spec) else {
            print("  ❌ \(spec.name) 加载失败")
            return
        }
        guard let p = makeProvider(m) else {
            print("  ❌ \(spec.name) provider 失败")
            return
        }
        models.append((spec.name, m, p))
        // warmup
        _ = try? m.prediction(from: p)
    }
    print("  全部 \(models.count) 个模型加载完成")

    // 测每个模型
    var perModel: [(String, Double, Double, Double)] = []
    for (name, model, provider) in models {
        var times: [Double] = []
        for _ in 0..<60 {
            let t0 = Date()
            _ = try? model.prediction(from: provider)
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        times.sort()
        perModel.append((name, times[0], times[times.count/2], times[Int(Double(times.count)*0.95)]))
    }

    // 测串联总延迟
    var serialTimes: [Double] = []
    for _ in 0..<60 {
        let t0 = Date()
        for (_, model, provider) in models {
            _ = try? model.prediction(from: provider)
        }
        serialTimes.append(Date().timeIntervalSince(t0) * 1000)
    }
    serialTimes.sort()

    print("  各模型延迟 (min / p50 / p95):")
    for (name, mn, p50, p95) in perModel {
        print(String(format: "    %-6@ %.3f / %.3f / %.3f ms", name as NSString, mn, p50, p95))
    }
    let sum = perModel.reduce(0.0) { $0 + $1.2 } // sum of p50
    print(String(format: "  p50 之和 = %.3f ms", sum))
    print(String(format: "  串联实测: min=%.3f  p50=%.3f  p95=%.3f  max=%.3f ms",
                 serialTimes[0], serialTimes[serialTimes.count/2],
                 serialTimes[Int(Double(serialTimes.count)*0.95)],
                 serialTimes[serialTimes.count-1]))
}

benchStrategy(allCPU, "策略1: enc(ANE) + 其余全 cpuOnly")
benchStrategy(mixedANECPU, "策略2: enc+chunk5/6(ANE) + 其余 cpuOnly")
