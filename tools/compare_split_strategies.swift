#!/usr/bin/env swift
// 双模型 (enc+ctl) vs 多模型 (9块) 对比实测
import CoreML
import Foundation

struct Spec { let name: String; let path: String; let units: MLComputeUnits }

func load(_ s: Spec) -> MLModel? {
    let cfg = MLModelConfiguration(); cfg.computeUnits = s.units
    return try? MLModel(contentsOf: URL(fileURLWithPath: s.path), configuration: cfg)
}
func provider(_ m: MLModel) -> MLDictionaryFeatureProvider? {
    var d: [String: MLFeatureValue] = [:]
    for (n, desc) in m.modelDescription.inputDescriptionsByName {
        guard let c = desc.multiArrayConstraint,
              let a = try? MLMultiArray(shape: c.shape, dataType: .float32) else { return nil }
        let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
        let cnt = c.shape.reduce(1) { $0 * $1.intValue }
        for i in 0..<cnt { p[i] = Float.random(in: 0...0.5) }
        d[n] = MLFeatureValue(multiArray: a)
    }
    return try? MLDictionaryFeatureProvider(dictionary: d)
}

func bench(_ specs: [Spec], _ label: String) {
    print("\n═══ \(label) ═══")
    var ms: [(String, MLModel, MLDictionaryFeatureProvider)] = []
    for s in specs {
        guard let m = load(s), let p = provider(m) else { print("  ❌ \(s.name)"); return }
        _ = try? m.prediction(from: p)
        ms.append((s.name, m, p))
    }
    var per: [(String, Double, Double)] = []
    for (n, m, p) in ms {
        var t: [Double] = []
        for _ in 0..<60 { let t0 = Date(); _ = try? m.prediction(from: p); t.append(Date().timeIntervalSince(t0)*1000) }
        t.sort(); per.append((n, t[t.count/2], t[Int(Double(t.count)*0.95)]))
    }
    var ser: [Double] = []
    for _ in 0..<60 { let t0 = Date(); for (_, m, p) in ms { _ = try? m.prediction(from: p) }; ser.append(Date().timeIntervalSince(t0)*1000) }
    ser.sort()
    for (n, p50, p95) in per { print(String(format: "    %-6@ p50=%.3f p95=%.3f ms", n as NSString, p50, p95)) }
    print(String(format: "  串联: p50=%.3f p95=%.3f max=%.3f ms",
                 ser[ser.count/2], ser[Int(Double(ser.count)*0.95)], ser[ser.count-1]))
}

let S = "models/split24"
bench([
    Spec(name: "enc", path: "\(S)/m9_v2_enc.mlmodelc", units: .cpuAndNeuralEngine),
    Spec(name: "ctl", path: "\(S)/m9_v2_ctl.mlmodelc", units: .cpuOnly),
], "双模型 (enc ANE + ctl cpuOnly)")

let M = "models/multi_split"
bench([
    Spec(name: "enc", path: "\(S)/m9_v2_enc.mlmodelc", units: .cpuAndNeuralEngine),
    Spec(name: "tf", path: "\(M)/m9_v2_tf.mlmodelc", units: .cpuOnly),
    Spec(name: "c1", path: "\(M)/m9_v2_chunk1.mlmodelc", units: .cpuOnly),
    Spec(name: "c2", path: "\(M)/m9_v2_chunk2.mlmodelc", units: .cpuOnly),
    Spec(name: "c3", path: "\(M)/m9_v2_chunk3.mlmodelc", units: .cpuOnly),
    Spec(name: "c4", path: "\(M)/m9_v2_chunk4.mlmodelc", units: .cpuOnly),
    Spec(name: "c5", path: "\(M)/m9_v2_chunk5.mlmodelc", units: .cpuOnly),
    Spec(name: "c6", path: "\(M)/m9_v2_chunk6.mlmodelc", units: .cpuOnly),
    Spec(name: "head", path: "\(M)/m9_v2_head.mlmodelc", units: .cpuOnly),
], "多模型 (9块串联)")
