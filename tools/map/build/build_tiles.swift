// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  tools/map/build/build_tiles.swift — 把 13056² 底图切成无损瓦片
// ============================================================================
//
//  用法：swift tools/map/build/build_tiles.swift
//  产出：models/map_tiles/{x}_{y}.png（544×544，24×24 = 576 张）
//
//  ══════════════════════════════════════════════════════════════════════════
//  【为什么必须用 CoreGraphics 来切，而不是 Python/PIL】
//  ══════════════════════════════════════════════════════════════════════════
//  运行时的验收判据是「瓦片路径与源图直裁路径**逐像素一致**（max|Δ| == 0）」。
//  这条判据成立的前提是：**瓦片里的像素 = CoreGraphics 解码 JPEG 得到的像素**。
//  不同 JPEG 解码器（libjpeg-turbo / Pillow vs CoreGraphics）的 IDCT 与色彩
//  管理实现不同，同一张图会解出 ±1 的差异 —— 那样瓦片路径就永远对不上。
//  所以切片工具**必须复用运行时同一套解码**（`NSImage` + `cgImage(forProposedRect:)`
//  + `ctx.draw` 1:1），而不是换一个语言/库去解。
//
//  ══════════════════════════════════════════════════════════════════════════
//  【为什么是 544 而不是 512】
//  ══════════════════════════════════════════════════════════════════════════
//  13056 / 544 = **24 整**；而 13056 / 512 = 25.5 → 最后一列/行是不满的碎瓦片，
//  拼接时要做边界特判。整除能把这整类边界情况消掉（工程化 > 凑整数）。
//  544² × 4B = 1.18MB/张，运行时只解码视口覆盖到的那几张。
//
//  ══════════════════════════════════════════════════════════════════════════
//  【无损保证】PNG 是无损格式，且这里是 1:1 blit（无插值）——
//  解出来的瓦片与源图对应区域逐像素相同。
//  ══════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation

let tileSide = 544
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let srcPath = root.appendingPathComponent("models/bigworldmap-13056.jpg").path
let outDir = root.appendingPathComponent("models/map_tiles")

guard FileManager.default.fileExists(atPath: srcPath) else {
    print("✗ 找不到源图：\(srcPath)")
    exit(1)
}
guard let img = NSImage(contentsOfFile: srcPath),
      let src = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("✗ 源图无法解码：\(srcPath)")
    exit(1)
}
let mapPixels = src.width
guard src.height == mapPixels else {
    print("✗ 源图不是正方形：\(src.width)×\(src.height)")
    exit(1)
}
let tiles = mapPixels / tileSide
guard tiles * tileSide == mapPixels else {
    print("✗ \(mapPixels) 不能被瓦片边长 \(tileSide) 整除（当前 = \(Double(mapPixels) / Double(tileSide))）")
    exit(1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

print("═══ 切片 \(mapPixels)² → \(tiles)×\(tiles) 张 \(tileSide)² PNG ═══")

// ══════════════════════════════════════════════════════════════════════════
// ⚠️ 为什么**不**先解一张 13056² 的中间位图
// ══════════════════════════════════════════════════════════════════════════
// 第一版为了省时间先 `fullCtx.draw(src, in: 13056²)` 再逐块 `cropping`，
// 实测**会引入误差**：同一张源图，瓦片 `9_9` 与源图直裁差 max|Δ|=4
// （103,162 字节不同），而 `0_0` / `12_5` / `23_23` 完全一致 ——
// 即"经中间位图"这条路**并非逐像素恒等**（大图 draw 的内部实现不保证 1:1 拷贝）。
// 这直接破坏验收判据 `max|Δ| == 0`，所以改为**每块直接从源图裁**。
// 代价：576 次全图解码 ≈ 40 秒（一次性离线成本，可接受）；
// 收益：瓦片与源图**逐字节相同**，运行时才可能与"源图直裁"路径一致。
var written = 0
var bytes = 0
let t1 = DispatchTime.now()
for ty in 0..<tiles {
    for tx in 0..<tiles {
        let rect = CGRect(x: tx * tileSide, y: ty * tileSide,
                          width: tileSide, height: tileSide)
        guard let crop = src.cropping(to: rect),
              let ctx = CGContext(data: nil, width: tileSide, height: tileSide,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, 
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { continue }
        // 1:1 blit —— 无插值、无重采样，逐像素等于源图
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: tileSide, height: tileSide))
        guard let tile = ctx.makeImage() else { continue }

        let rep = NSBitmapImageRep(cgImage: tile)
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        let out = outDir.appendingPathComponent("\(tx)_\(ty).png")
        do {
            try png.write(to: out)
            written += 1
            bytes += png.count
        } catch {
            print("✗ 写盘失败 \(out.path): \(error)")
            exit(1)
        }
    }
}
let writeMs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000_000

print(String(format: "  写出 %d 张 · 共 %.1f MB · 耗时 %.1f s", written,
             Double(bytes) / 1_048_576.0, writeMs / 1000))
print("  目录：\(outDir.path)")
print(written == tiles * tiles ? "✅ 切片完成" : "✗ 只写出 \(written)/\(tiles * tiles) 张")
exit(written == tiles * tiles ? 0 : 1)
