// Metal 探针: 验证 Shaders.metal 能否在运行时 makeLibrary(source:) 编译,
// 以及 texture_vertex / texture_fragment 是否存在 (决定 renderPipeline 是否非 nil)。
import Metal
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    print("PROBE FAIL: no Metal device"); exit(1)
}
print("PROBE device:", device.name)

let path = "/Users/dupi/Desktop/自动驾驶系统/Vendor/MetalGoose/Engine/Shaders.metal"
guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("PROBE FAIL: cannot read Shaders.metal"); exit(1)
}
print("PROBE Shaders.metal bytes:", src.utf8.count)

do {
    let lib = try device.makeLibrary(source: src, options: nil)
    print("PROBE makeLibrary(source:) OK")
    let vtx = lib.makeFunction(name: "texture_vertex")
    let frag = lib.makeFunction(name: "texture_fragment")
    print("PROBE texture_vertex:", vtx == nil ? "MISSING" : "found")
    print("PROBE texture_fragment:", frag == nil ? "MISSING" : "found")
    if let vtx, let frag {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vtx
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let ps = try device.makeRenderPipelineState(descriptor: desc)
        print("PROBE renderPipeline OK")
    } else {
        print("PROBE FAIL: renderPipeline would be nil (missing vertex/fragment)")
        exit(1)
    }
} catch {
    print("PROBE FAIL: makeLibrary(source:) error ->", error)
    exit(1)
}
print("PROBE ALL PASS")