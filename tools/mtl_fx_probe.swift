// MetalFX 探针: 直接验证 MTLFXFrameInterpolator 能否创建(MetalFX 插帧器)。
// 若失败 -> interpolateFrame 恒为 nil -> 插帧全部透传 -> 症状 = "插帧没用"。
import Metal
import MetalFX
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    print("FX PROBE FAIL: no Metal device"); exit(1)
}
print("FX PROBE device:", device.name)
print("FX PROBE supportsFamily (Metal 3 / m3):",
      device.supportsFamily(.apple3) || device.supportsFamily(.common3))

// 让 OS 知道我们需要 MetalFX GPU 加速(生产代码通常不需要,这里是纯创建测试)
// 用与 GooseEngine.ensureFrameInterpolator 一致的参数构造
let desc = MTLFXFrameInterpolationDescriptor()
desc.inputWidth = 640
desc.inputHeight = 360
desc.outputWidth = 640
desc.outputHeight = 360

do {
    let interpolator = try device.makeFrameInterpolator(descriptor: desc)
    print("FX PROBE makeFrameInterpolator OK -> input=\(interpolator.inputWidth)x\(interpolator.inputHeight) output=\(interpolator.outputWidth)x\(interpolator.outputHeight)")
    print("FX PROBE interpolator.colorTexture type:", "\(interpolator.colorTexture)")
} catch {
    print("FX PROBE FAIL: makeFrameInterpolator error ->", error)
    exit(1)
}
print("FX PROBE ALL PASS")