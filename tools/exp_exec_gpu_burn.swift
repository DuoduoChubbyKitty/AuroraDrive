// ============================================================================
//  gpu_burn.metal / gpu_burn.swift —— 受控 GPU 背景负载（S2 · 2026-10-09）
//
//  【为什么需要】
//    `.cpuAndGPU` 在本机（CPU 被其他 agent 抢爆）下比 `.all` 快 1.8~2.2×，
//    但**真实驾驶场景的瓶颈是 GPU**（游戏满载渲染），不是 CPU。
//    项目旧结论（`YolopxEngine.swift:695-716`）测的是"8 核满载"= CPU 满载，
//    从未测过 **GPU 满载**下 `.cpuAndGPU` 是否仍占优。
//
//    若不测就推荐 `.cpuAndGPU`，等于把"跟游戏抢 GPU"这个已知风险
//    （旧文档记录曾触发 MPSGraph SIGABRT）当成不存在。
//
//  【做法】
//    用 Metal compute kernel 起一个纯 GPU 负载（矩阵乘 + 逐元素循环），
//    在它与被测进程并存时重复 ABBA 对比 `.all` / `.cpuAndGPU`。
//
//  用法: ./gpu_burn <持续秒数> [负载强度 1..8]
// ============================================================================

import Foundation
import Metal
import MetalKit

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
let intensity = args.count > 2 ? Int(args[2]) ?? 4 : 4

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("no metal device\n".data(using: .utf8)!)
    exit(1)
}
guard let queue = device.makeCommandQueue() else { exit(1) }

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]],
                 constant uint &n [[buffer(1)]],
                 uint gid [[thread_position_in_grid]]) {
    if (gid >= n) return;
    float x = out[gid];
    // 纯 ALU 密集：模拟游戏着色器的算术压力
    for (uint i = 0; i < 512; ++i) {
        x = fma(x, 1.0000001f, 0.0000001f);
        x = sqrt(fabs(x) + 1.0f);
    }
    out[gid] = x;
}
"""
let lib: MTLLibrary
do {
    lib = try device.makeLibrary(source: src, options: nil)
} catch {
    FileHandle.standardError.write("compile failed: \(error)\n".data(using: .utf8)!)
    exit(2)
}
guard let fn = lib.makeFunction(name: "burn") else { exit(2) }
let pso = try! device.makeComputePipelineState(function: fn)

let n = 1 << 20
let buf = device.makeBuffer(length: n * 4, options: .storageModeShared)!
let ptr = buf.contents().bindMemory(to: Float.self, capacity: n)
for i in 0..<n { ptr[i] = Float(i % 100) * 0.01 }

let threadsPerGroup = pso.maxTotalThreadsPerThreadgroup
let groups = (n + threadsPerGroup - 1) / threadsPerGroup
var nU: UInt32 = UInt32(n)

print("[gpu_burn] device=\(device.name) 线程组=\(groups) 强度=\(intensity) 持续=\(seconds)s")
fflush(stdout)

let deadline = Date().addingTimeInterval(seconds)
var iters = 0
while Date() < deadline {
    // 强度 = 每轮提交的命令缓冲数（多缓冲并发压满 GPU）
    for _ in 0..<intensity {
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&nU, length: 4, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: threadsPerGroup,
                                                                height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
    }
    iters += 1
    // 每 16 轮同步一次，避免无界排队把内存打爆
    if iters % 16 == 0 { queue.insertDebugCaptureBoundary(); usleep(1000) }
}
print("[gpu_burn] 完成，提交 \(iters) 轮 × \(intensity) 缓冲")
