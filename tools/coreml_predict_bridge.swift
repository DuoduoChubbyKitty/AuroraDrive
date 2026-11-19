#!/usr/bin/env swift
// coreml_predict_bridge.swift — 批量推理 .mlmodelc，输入/输出走二进制文件
//
// 【为什么需要这个桥接，而不是在 Python 里直接 ct.models.MLModel 加载】
//   本项目导出的 .mlmodelc 由 `xcrun coremlc compile` 生成，产物不含
//   Manifest.json（仓库既有的 models/m9_v2.mlmodelc 也是同样结构）。
//   coremltools 的 MLModel() 只认 .mlpackage，打开该产物会直接报
//       RuntimeError: A valid manifest does not exist at path: .../Manifest.json
//   这是**加载方式不兼容**，不是模型损坏。要测「交付物本身的数值行为」
//   就必须用部署端真正使用的 CoreML 原生运行时，即这里这套。
//
// 【二进制格式】（小端，float32）
//   输入文件:  magic 'WMDI'(4B) | uint32 N | N×3×224×384 float32 图像 | N×64 float32 动作块
//   输出文件:  magic 'WMDO'(4B) | uint32 N | N×256 float32 latent_next
//
// 用法:
//   swift tools/coreml_predict_bridge.swift <model.mlmodelc> <in.bin> <out.bin>

import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("用法: swift coreml_predict_bridge.swift <model.mlmodelc> <in.bin> <out.bin>\n".data(using: .utf8)!)
    exit(1)
}
let modelURL = URL(fileURLWithPath: args[1])
let inURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])

let imageDims = [1, 3, 224, 384]
let actionDim = 64
let latentDim = 256

// ── 读输入 ───────────────────────────────────────────────────────────────
let raw = try Data(contentsOf: inURL)
guard raw.count > 8, raw[0] == 0x57, raw[1] == 0x4D, raw[2] == 0x44, raw[3] == 0x49 else {
    FileHandle.standardError.write("输入文件头部非法（期望 magic WMDI）\n".data(using: .utf8)!)
    exit(1)
}
let n = Int(raw.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
var payload = [Float](repeating: 0, count: (raw.count - 8) / 4)
payload.withUnsafeMutableBytes { dst in
    _ = raw.copyBytes(to: dst, from: 8..<raw.count)
}
let imageCount = 3 * 224 * 384
let expect = n * imageCount + n * actionDim
guard payload.count == expect else {
    FileHandle.standardError.write("payload 长度不符: 期望 \(expect) 实得 \(payload.count)\n".data(using: .utf8)!)
    exit(1)
}

// ── 加载模型 ─────────────────────────────────────────────────────────────
let cfg = MLModelConfiguration()
cfg.computeUnits = .all
let model: MLModel
do {
    model = try MLModel(contentsOf: modelURL, configuration: cfg)
} catch {
    FileHandle.standardError.write("加载模型失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// ── 批量推理 ─────────────────────────────────────────────────────────────
var outputs = [Float](repeating: 0, count: n * latentDim)
for i in 0..<n {
    guard let image = try? MLMultiArray(shape: imageDims.map { NSNumber(value: $0) }, dataType: .float32),
          let action = try? MLMultiArray(shape: [1, NSNumber(value: actionDim)], dataType: .float32) else {
        FileHandle.standardError.write("分配 MLMultiArray 失败\n".data(using: .utf8)!)
        exit(1)
    }
    let base = i * imageCount
    for j in 0..<imageCount { image[j] = NSNumber(value: payload[base + j]) }
    let abase = n * imageCount + i * actionDim
    for j in 0..<actionDim { action[j] = NSNumber(value: payload[abase + j]) }

    let provider = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: image),
        "action": MLFeatureValue(multiArray: action),
    ])
    let result = try model.prediction(from: provider)
    guard let out = result.featureValue(for: "latent_next")?.multiArrayValue else {
        FileHandle.standardError.write("输出缺少 latent_next\n".data(using: .utf8)!)
        exit(1)
    }
    for j in 0..<latentDim { outputs[i * latentDim + j] = out[j].floatValue }
}

// ── 写输出 ───────────────────────────────────────────────────────────────
var outData = Data([0x57, 0x4D, 0x44, 0x4F])
var nLE = UInt32(n).littleEndian
withUnsafeBytes(of: &nLE) { outData.append(contentsOf: $0) }
outputs.withUnsafeBytes { outData.append(contentsOf: $0) }
try outData.write(to: outURL)
exit(0)
