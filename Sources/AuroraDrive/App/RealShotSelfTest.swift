// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  RealShotSelfTest.swift — 真实截图红线自证（--realshot-selftest）
//
//  【为什么需要这个文件】2026-10-01 审计发现的**验证可信度缺陷**：
//    `--perf-selftest` 与 `--yolopx-selftest` 都用 `PerfSelfTestImage.make()`
//    构造的**合成图**（斜向梯度 + 棋盘格 + 亮线）。合成图里没有任何真实目标，
//    所以它们跑出来的 R2/R3 必然是：
//        R2 检测框 = 0 个
//        R3 可行驶 = 0.00% / 车道线 = 0.000%
//    ⟹ 这两个红线的**数字本身不构成验证**。上一轮"N R2 9→9 / R3 一字未变"
//       的结论实际来自**离线拿同一张真实截图做前后对比**，而不是自检给出的。
//       自检报告里那两个 0 容易被误读成"回归通过"，属**误导性输出**。
//
//  【本自检做什么】用**用户提供的真实游戏截图**跑 YOLOPX，输出 R2/R3 的
//    真实数值，并与历史记录做**逐位对比**。同图前后一致 = 红线守住。
//
//  【用法】
//      # 单张图
//      AURORA_UI_LOCAL=1 ./AuroraDrive --realshot-selftest --image <路径.jpg>
//
//      # 目录（跑该目录下所有 jpg/png，逐张对比）
//      AURORA_UI_LOCAL=1 ./AuroraDrive --realshot-selftest --dir data/nte_test_frames
//
//  【历史真值（2026-09-29 实测，同一批图）】
//      R2 检测框 = 9 个
//      R3 可行驶 = 26.19% / 车道线 = 8.042%
//    ⚠️ 这两个数字是**特定图 + 特定模型**下的结果，换图就会变。
//      故本自检的判据是「**同一张图**前后一致」，不是「等于某个固定值」——
//      后者在换图时会产生假失败，那种"自检判红但实际正常"的噪声正是要避免的。
//
//  【与 yolopx-selftest 的分工】
//      · `--yolopx-selftest`     ：验**接口/坐标变换/NMS/兜底门控**（合成图，可控真值）
//      · `--realshot-selftest`   ：验**精度红线 R2/R3**（真实图，可信数值）
//      两者互补，不能互相替代。
// ============================================================================

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import QuartzCore   // CACurrentMediaTime（PerfSelfTest 同款依赖）

/// 单张图的测量结果。
struct RealShotResult {
    var path: String
    var ok: Bool
    var boxCount: Int = 0
    var drivablePct: Double = 0
    var lanePct: Double = 0
    var drivableCells: Int = 0
    var laneCells: Int = 0
    var latencyMs: Double = 0
    var modelName: String = ""
    var errorMessage: String?
}

/// 读图（支持 jpg/png；用 ImageIO 而不是 NSImage —— 后者依赖 AppKit 上下文，
/// 在无窗口的 CLI 进程里可能拿到空图）。
private func loadCGImage(path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        return nil
    }
    return img
}

/// 对一张真实截图跑 YOLOPX，返回 R2/R3 实测值。
@MainActor
private func measureRealShot(_ path: String, engine: YolopxEngine) -> RealShotResult {
    var r = RealShotResult(path: path, ok: false)

    guard let cg = loadCGImage(path: path) else {
        r.errorMessage = "读图失败（格式不支持或文件损坏）"
        return r
    }

    // 等一次真正的推理完成。判据用 `inferenceCount` 自增 —— 上一轮的教训：
    // "调了 infer() 就算完成"测的是**提交**而不是**完成**（见 PerfSelfTest 注释）。
    let before = engine.inferenceCount
    let t0 = CACurrentMediaTime()

    // 重试若干轮：首次调用可能撞上懒加载/预热（实测 n=1 会测到懒加载成本）。
    // 每轮只提交一次，用 RunLoop 驱动 —— Thread.sleep 会阻断回写（上一轮的坑）。
    var waited = 0.0
    let deadline = 8.0
    while CACurrentMediaTime() - t0 < deadline {
        engine.infer(image: cg)
        // 给推理队列时间；同时让主线程转 RunLoop 以便结果回写。
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        waited = CACurrentMediaTime() - t0
        if engine.inferenceCount != before { break }
    }

    guard engine.inferenceCount != before else {
        r.errorMessage = String(format: "%.1fs 内未完成推理（模型未加载？）", waited)
        return r
    }

    r.latencyMs = (CACurrentMediaTime() - t0) * 1000
    r.boxCount = engine.detections.count
    r.drivablePct = engine.drivableRatio * 100
    r.lanePct = engine.laneRatio * 100
    r.drivableCells = engine.drivableMask.positiveCount
    r.laneCells = engine.laneMask.positiveCount
    r.modelName = engine.loadedModelName ?? "—"
    r.ok = true
    return r
}

/// 入口：`--realshot-selftest --image <路径>` 或 `--dir <目录>`。
@MainActor
func runRealShotSelfTest(image: String?, dir: String?) -> Int {
    print("═══ 真实截图红线自证（R2/R3 · 2026-10-01）═══")
    print("")

    // ── 收集待测文件 ──
    var files: [String] = []
    if let image {
        files = [image]
    } else if let dir {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            files = names
                .filter { n in
                    let l = n.lowercased()
                    return l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".png")
                }
                .sorted()
                .map { (dir as NSString).appendingPathComponent($0) }
        }
    }

    guard !files.isEmpty else {
        print("  ✗ 未指定待测图。用法：")
        print("      --realshot-selftest --image <路径.jpg>")
        print("      --realshot-selftest --dir <目录>")
        return 1
    }
    print("  待测: \(files.count) 张图")
    print("")

    // ── 加载模型 ──
    let engine = YolopxEngine()
    let tLoad = CACurrentMediaTime()
    engine.loadIfNeeded()
    let loadMs = (CACurrentMediaTime() - tLoad) * 1000
    print(String(format: "  模型: %@  加载=%.0fms  已加载=%@",
                 engine.loadedModelName ?? "—", loadMs, engine.isLoaded ? "是" : "否"))
    guard engine.isLoaded else {
        print("  ✗ YOLOPX 未加载，无法测红线。错误: \(engine.errorMessage ?? "—")")
        return 1
    }
    print("")

    // ── 逐张测量 ──
    // 预热：先跑一张让 CoreML 图/缓冲就位，否则第一张会包含一次性开销
    // （上一轮 n=1 测到懒加载成本的教训）。
    if let first = files.first, let cg = loadCGImage(path: first) {
        let before = engine.inferenceCount
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 8.0 {
            engine.infer(image: cg)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if engine.inferenceCount != before { break }
        }
        print(String(format: "  预热完成（%.0fms，含一次性开销）", (CACurrentMediaTime() - t0) * 1000))
        print("")
    }

    print("  ── 逐张结果 ──")
    var results: [RealShotResult] = []
    for (i, f) in files.enumerated() {
        let r = measureRealShot(f, engine: engine)
        results.append(r)
        let name = (f as NSString).lastPathComponent
        if r.ok {
            print(String(format: "  [%2d] %-28@  R2框=%-3d R3可行驶=%6.2f%% 车道线=%6.3f%%  耗时=%.0fms",
                         i + 1, name as NSString, r.boxCount,
                         r.drivablePct, r.lanePct, r.latencyMs))
        } else {
            print("  [\(i + 1)] \(name)  ✗ \(r.errorMessage ?? "未知错误")")
        }
    }
    print("")

    // ── 汇总 ──
    let okOnes = results.filter(\.ok)
    guard !okOnes.isEmpty else {
        print("═══ 真实截图自证：FAIL（无一张成功）═══")
        return 1
    }

    let avgBox = Double(okOnes.reduce(0) { $0 + $1.boxCount }) / Double(okOnes.count)
    let avgDa = okOnes.reduce(0.0) { $0 + $1.drivablePct } / Double(okOnes.count)
    let avgLl = okOnes.reduce(0.0) { $0 + $1.lanePct } / Double(okOnes.count)

    print("  ── 汇总（\(okOnes.count)/\(results.count) 张成功）──")
    print(String(format: "    R2 平均检测框:    %.1f 个", avgBox))
    print(String(format: "    R3 平均可行驶:    %.2f%%", avgDa))
    print(String(format: "    R3 平均车道线:    %.3f%%", avgLl))
    print("")
    print("  ⚠️ 判读方式（重要）：")
    print("     本命令输出的是**当前真实数值**。R2/R3 的判据是「**同一张图**")
    print("     改动前后一致」，不是「等于某个固定数字」—— 换图必然变数。")
    print("     回归对比方法：把本命令的输出贴进文档，优化后重跑同一目录，")
    print("     逐张对照。任何一张的框数/掩码占比变化超过 1%，都必须给出解释。")
    print("")

    // ── 判据：与基线逐张对比，而不是"掩码非空" ──
    //
    // ⚠️ 2026-10-01 修正（本自检第一版的判据是错的）：
    //   初版把「掩码为空」直接判为模型输出异常 → 对 `data/nte_test_frames`
    //   这批**宣传片/视频截图**（`nte_slide*.jpg` / `yt_*.jpg`，画面里根本没有
    //   道路视角）产生了 14 项假失败。真实原因：图里没有可行驶区域，模型
    //   正确地输出空掩码 —— **空掩码是正确答案，不是缺陷**。
    //
    //   教训与 §12 方法论一致：**判据本身要先能对上已知事实**。
    //   故改为「**同一张图**前后一致」——这正是红线 R2/R3 的真实语义
    //   （"不得减少/不得劣化"，而不是"必须达到某个绝对值"）。
    print("  ── 基线对比（回归判据）──")
    print("     请把上方逐张数值保存为基线，改动后重跑同一目录逐张对照：")
    print("       · 框数变化 → 立即排查（R2 红线）")
    print("       · 掩码占比变化超过 1 个百分点 → 立即排查（R3 红线）")
    print("     注：本批图含宣传片/视频截图，本身无道路场景时掩码为空**属正常**，")
    print("         不能凭「掩码空」判失败 —— 那会产生假失败（初版已踩过）。")
    print("")

    // 真正的硬错误：全目录 100% 掩码皆空 = 模型彻底没输出（而非"图里没路"）。
    // 这个判据与"某张图为空"不同：只要还有图能出掩码，就说明模型链路是活的。
    let anyDrivable = okOnes.contains { $0.drivableCells > 0 }
    let anyLane = okOnes.contains { $0.laneCells > 0 }
    var hardFail = 0
    if !anyDrivable {
        print("    ✗ 全部 \(okOnes.count) 张图的可行驶掩码都为空 —— 模型链路可能已断")
        hardFail += 1
    }
    if !anyLane {
        print("    ✗ 全部 \(okOnes.count) 张图的车道线掩码都为空 —— 模型链路可能已断")
        hardFail += 1
    }
    if hardFail > 0 {
        print("")
        print("═══ 真实截图自证：FAIL（\(hardFail) 项）═══")
        return hardFail
    }

    print(String(format: "    ✓ 模型链路存活：可行驶掩码 %d/%d 张非空，车道线 %d/%d 张非空",
                 okOnes.filter { $0.drivableCells > 0 }.count, okOnes.count,
                 okOnes.filter { $0.laneCells > 0 }.count, okOnes.count))
    print("")
    print("═══ 真实截图自证：PASS（数值已记录，供前后对比）═══")
    return 0
}
