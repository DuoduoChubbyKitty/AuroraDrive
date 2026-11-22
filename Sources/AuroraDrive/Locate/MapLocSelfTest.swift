// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapLocSelfTest.swift — 小地图视觉定位冒烟自检（--maploc-selftest）
// ----------------------------------------------------------------------------
//  用真实资产验证 MapLocBridge（OpenCV C 桥）：
//    · 生产大图 models/bigworldmap-13056.jpg
//    · 桌面截图裁出的小地图模板（Python 验证口径：圆心 302,330，裁 280² → 150²）
//
//  断言（数字来自独立 C++ 桥测试 + Python 验证，2026-11-20）：
//    · global 命中坐标 ≈ (4944, 6900) 全图像素，容差 ±20px
//    · global/track 分数与 0.8452 相差不超过 0.01
//    · track（以 global 为 hint）坐标与 global 一致，且耗时 < 7ms（用户红线）
//
//  这同时能抓 CGContext 原点翻转：若模板被垂直翻转，坐标会明显偏离。
//  纯离屏、不联网、不碰权限；放在单实例锁之前同步 exit。
// ============================================================================

import Foundation
import CoreGraphics
import ImageIO

func runMapLocSelfTest() -> Int32 {
    var pass = 0
    var fail = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { pass += 1; print("  ✅ \(name)  \(detail)") }
        else { fail += 1; print("  ❌ \(name)  \(detail)") }
    }

    print("═══ 小地图视觉定位自检（--maploc-selftest）═══")

    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Locate
        .deletingLastPathComponent()   // AuroraDrive
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 项目根
    let mapPath = projectRoot.appendingPathComponent("models/bigworldmap-13056.jpg").path
    let templatePath = "/tmp/swift_selftest_minimap.png"
    let expectedScore = 0.8452
    let scoreTolerance = 0.01

    guard FileManager.default.fileExists(atPath: mapPath) else {
        print("  ❌ 生产大图不存在：\(mapPath)")
        return 1
    }
    guard let tplImage = CGImageSourceCreateWithURL(URL(fileURLWithPath: templatePath) as CFURL, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
        print("  ❌ 小地图模板不存在或不可解码：\(templatePath)")
        print("     先运行：python3 -c \"from PIL import Image; Image.open('桌面截图').crop((162,190,442,470)).resize((150,150)).save('\(templatePath)')\"")
        return 1
    }
    check("测试资产就位", true, "大图 + 150² 小地图模板")

    guard let locator = MapLocBridge(mapPath: mapPath, downscale: 4) else {
        print("  ❌ MapLocBridge 初始化失败（大图解码或 C 桥 create 失败）")
        return 1
    }
    check("定位器初始化", locator.isReady, "13056² → 3264² CLAHE 预处理完成")

    // ── 全局定位 ──
    let global = locator.globalLocate(minimap: tplImage)
    check("global 命中", global.found,
          "found=\(global.found) score=\(String(format: "%.4f", global.score))")
    check("global 坐标准确",
          global.found && abs(global.x - 4944) <= 20 && abs(global.y - 6900) <= 20,
          "got=(\(Int(global.x)),\(Int(global.y))) expect≈(4944,6900)")
    check("global 分数达标",
          global.found && abs(global.score - expectedScore) <= scoreTolerance,
          "score=\(String(format: "%.4f", global.score)) expect≈\(expectedScore)")

    // ── 局部跟踪（性能红线 + 逐帧断言）──
    if global.found {
        var maxMs = 0.0
        var allFramesOk = true
        var scoresOk = true
        var lastGood = global
        for i in 0..<5 {
            let t0 = DispatchTime.now()
            let r = locator.track(minimap: tplImage, hint: (lastGood.x, lastGood.y), window: 400)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            maxMs = max(maxMs, ms)
            scoresOk = scoresOk && r.found && abs(r.score - expectedScore) <= scoreTolerance
            // 逐帧检查：中间帧错位后末帧恢复也能全绿（审查 2026-11-20）。
            if !r.found || abs(r.x - global.x) > 20 || abs(r.y - global.y) > 20 {
                allFramesOk = false
                print("     第\(i)帧偏移：(\(Int(r.x)),\(Int(r.y))) score=\(String(format: "%.3f", r.score))")
            } else {
                // 只用成功结果更新 hint，失败结果会污染下一帧窗口。
                lastGood = r
            }
        }
        check("track 逐帧坐标一致", allFramesOk,
              "5 帧全部落在 global±20px")
        check("track 逐帧分数达标", scoresOk,
              "5 帧 score=\(expectedScore)±\(scoreTolerance)")
        check("track 性能 <7ms", maxMs < 7.0,
              "5 帧最大 \(String(format: "%.2f", maxMs))ms（红线 7ms）")
    } else {
        check("track 逐帧坐标一致", false, "global 未命中，跳过")
        check("track 逐帧分数达标", false, "global 未命中，跳过")
        check("track 性能 <7ms", false, "global 未命中，跳过")
    }

    // ── 自动标定端到端（圆形检测 → 多帧收敛 → ROI → 定位闭环）──
    if let regionImage = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: "/tmp/swift_selftest_region.png") as CFURL, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        // 圆检测（区域输入路径，与运行时标定同一路径）
        var calibrator = MinimapCalibrator()
        var converged: MinimapCalibrator.Detection?
        var detectOk = false
        for _ in 0..<8 {
            guard let det = MapLocBridge.detectCircle(
                    regionGray: regionImage, isRegion: true, frameW: 2940) else { continue }
            detectOk = true
            converged = calibrator.add(.init(cx: det.cx, cy: det.cy, r: det.r))
        }
        check("自动标定 · 圆检测命中", detectOk,
              detectOk ? "区域帧检测到圆形小地图" : "8 帧全部未检出圆")
        if let conv = converged,
           let roi = MinimapCalibrator.normalizedROI(from: conv, frameW: 2940, frameH: 1912) {
            // 收敛圆心 ≈(304,333) r≈204 → ROI ≈(0.056, 0.091, 0.095, 0.146)
            let cxOk = abs(conv.cx - 304) < 25 && abs(conv.cy - 333) < 25
            check("自动标定 · 收敛圆心", cxOk,
                  "center=(\(Int(conv.cx)),\(Int(conv.cy))) r=\(Int(conv.r)) expect≈(304,333) r≈204")
            // 区域夹具从整帧左上角 1:1 裁出，自动 ROI 仍用整帧像素坐标。
            // 按 CaptureEngine 的取整方式裁剪，避免依赖另一份桌面截图。
            let crop = CGRect(x: (roi.origin.x * 2940).rounded(.toNearestOrEven),
                              y: (roi.origin.y * 1912).rounded(.toNearestOrEven),
                              width: (roi.width * 2940).rounded(.toNearestOrEven),
                              height: (roi.height * 1912).rounded(.toNearestOrEven))
            if CGRect(x: 0, y: 0, width: regionImage.width, height: regionImage.height).contains(crop),
               let autoTpl = regionImage.cropping(to: crop) {
                let autoResult = locator.globalLocate(minimap: autoTpl)
                let span = locator.measureGuideSpan(minimap: autoTpl, at: autoResult)
                // 同一场景的独立地标匹配约 456 个大图像素，给整数尺度和 ROI 取整留 24px。
                let validSpan = span.map { abs($0 - 456) <= 24 } ?? false
                check("自动标定 · 定位闭环",
                      autoResult.found && abs(autoResult.score - expectedScore) <= scoreTolerance
                          && abs(autoResult.x - 4944) <= 20 && abs(autoResult.y - 6900) <= 20 && validSpan,
                      "score=\(String(format: "%.4f", autoResult.score)) " +
                      "pos=(\(Int(autoResult.x)),\(Int(autoResult.y))) expect≈(4944,6900) " +
                      "ROI span=\(span.map { Int($0) } ?? 0)px expect≈456")
            } else {
                check("自动标定 · 定位闭环", false, "自动 ROI 超出原生分辨率区域夹具")
            }
        } else {
            check("自动标定 · 收敛圆心", false, "8 帧未收敛")
            check("自动标定 · 定位闭环", false, "未收敛，跳过")
        }
    } else {
        check("自动标定 · 圆检测命中", false, "区域 fixture /tmp/swift_selftest_region.png 不存在")
        check("自动标定 · 收敛圆心", false, "fixture 缺失，跳过")
        check("自动标定 · 定位闭环", false, "fixture 缺失，跳过")
    }

    print("═══ 结果：\(pass) 通过 / \(fail) 失败 ═══")
    return Int32(fail)
}
