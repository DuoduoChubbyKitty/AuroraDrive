// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LaneKeepRealityTest.swift — 车道保持「到底能不能用」的真实素材实测
//                                （--lanekeep-reality）
//
//  为什么要有这个文件
//  ------------------
//  用户 2026-10-02 质问原话：
//    「还有你那烂车道线做了个什么草台班子就给我端上来，那玩意能用吗？」
//
//  这个质问是对的，而且**此前的自检根本回答不了它**：
//  既有的 `--lanekeep-selftest` 只验证了「档位门解析」和「输入不可信就返回
//  nil」这类**契约**，**从来没有量过算法在真实画面上的表现**。
//  也就是说：车道保持能不能用，此前**没有任何数据支撑**，只有代码里的推断。
//  本项目已经有过教训（12 项"想当然的优化"实测全被否决），不能重蹈覆辙。
//
//  本文件做的事：拿玩家真实游戏录像（10000 帧）当输入，让 A-YOLOM(INT8)
//  出车道线掩码，喂给生产同款 `LaneFallback.evaluate`，统计：
//
//    · 出建议率   —— 有多少帧能给出非 nil 建议（沉默率多高）
//    · 方向一致性 —— 相邻帧 steer 的抖动（能不能用 = 稳不稳）
//    · 饱和率     —— steer 打到 ±maxSteer 上限的比例（"一直打死方向"= 不能用）
//    · 置信度分布 —— 置信度实际有多高
//
//  ⚠️ 判据的诚实说明：本测试**没有**车道线真值（GT），因此**不能**直接
//     给出"转向对不对"。它量的是**可用性下限**：一个车道保持如果沉默率极高、
//     或者 steer 疯狂抖动/饱和，那它一定不能用 —— 这类否定结论是可靠的。
//     反过来"抖动小"不等于"方向对"，这一点必须写在报告里，不能含糊。
//
//  运行：
//    ./AuroraDriveUI --lanekeep-reality --dir <帧目录> [--frames N] [--stride N]
// ============================================================================

import Foundation
import CoreGraphics
import ImageIO
import CoreML

/// 车道保持真实素材实测。返回失败项数（0 = 完成，不代表"算法好"）。
@MainActor
func runLaneKeepRealityTest(framesDir: String, maxFrames: Int, stride: Int) -> Int {
    print("═══ 车道保持真实素材实测（--lanekeep-reality）═══")
    print("  素材目录: \(framesDir)")
    print("  取样: 最多 \(maxFrames) 帧, 步长 \(stride)")
    print("")

    // ── 收集帧 ──
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: framesDir) else {
        print("  ✗ 目录不可读: \(framesDir)"); return 1
    }
    let jpgs = names.filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".png") }
                    .sorted()
    guard !jpgs.isEmpty else { print("  ✗ 目录里没有图片"); return 1 }
    print("  目录内图片: \(jpgs.count) 张")

    var picked: [String] = []
    var i = 0
    while i < jpgs.count && picked.count < maxFrames {
        picked.append(jpgs[i]); i += stride
    }
    print("  实际取样: \(picked.count) 帧\n")

    // ── 引擎（与生产同款）──
    let engine = YolopxEngine()
    print("  模型族: \(engine.family.display)")

    let fallback = LaneFallback()
    var advices: [LaneAdvice?] = []
    var laneCoverage: [Double] = []
    var inferMs: [Double] = []
    var processed = 0

    for (idx, name) in picked.enumerated() {
        let path = (framesDir as NSString).appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }

        // 推理是**异步提交**的：`infer()` 只负责投递，完成要等 `inferenceCount` 自增。
        // 判据必须用 inferenceCount 而不是"调用了 infer" —— 本项目已有教训
        // （PerfSelfTest 注释：那样测的是提交而非完成）。
        let before = engine.inferenceCount
        let t0 = Date()
        engine.infer(image: cg)
        var spun = 0
        while engine.inferenceCount == before && spun < 400 {
            usleep(2000)          // 2ms
            spun += 1
        }
        guard engine.inferenceCount != before else { continue }
        inferMs.append(Date().timeIntervalSince(t0) * 1000)

        let ll = engine.laneMask
        let da = engine.drivableMask
        guard ll.width > 0, da.width > 0 else { continue }
        laneCoverage.append(Double(ll.positiveCount) / Double(ll.width * ll.height))

        let adv = fallback.evaluate(laneMask: ll, drivableMask: da,
                                    isDegraded: engine.laneDegraded,
                                    metrics: engine.metrics)
        advices.append(adv)
        processed += 1
        if idx % 200 == 0 && idx > 0 { print("    …已处理 \(idx)/\(picked.count)") }
    }

    guard processed > 0 else { print("  ✗ 没有一帧跑通"); return 1 }

    // ══════════════════════════════════════════════════════════════
    func pct(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return .nan }
        let s = a.sorted(); let k = Int((Double(s.count - 1) * p).rounded())
        return s[max(0, min(s.count - 1, k))]
    }
    func fmt(_ v: Double, _ d: Int = 3) -> String {
        v.isNaN ? "n/a" : String(format: "%.\(d)f", v)
    }

    let nonNil = advices.compactMap { $0 }
    let rate = Double(nonNil.count) / Double(advices.count) * 100

    print("\n── A. 基本可用性 ──")
    print("    跑通帧数        : \(processed)")
    print("    出建议帧数      : \(nonNil.count)  (\(fmt(rate, 1))%)")
    print("    沉默帧数        : \(advices.count - nonNil.count)  (\(fmt(100 - rate, 1))%)")
    print("    车道掩码覆盖率  : p50=\(fmt(pct(laneCoverage, 0.5) * 100, 2))%"
          + "  p95=\(fmt(pct(laneCoverage, 0.95) * 100, 2))%")
    print("    单帧推理        : p50=\(fmt(pct(inferMs, 0.5), 2))ms"
          + "  p95=\(fmt(pct(inferMs, 0.95), 2))ms")

    guard nonNil.count >= 10 else {
        print("\n  ✗ 出建议帧数过少（\(nonNil.count)），无法评估稳定性")
        return 1
    }

    // ══════════════════════════════════════════════════════════════
    print("\n── B. 转向输出分布（能不能用 = 稳不稳）──")
    let steers = nonNil.map(\.steer)
    let absSteers = steers.map { abs($0) }
    print("    |steer|  : p50=\(fmt(pct(absSteers, 0.5)))"
          + "  p95=\(fmt(pct(absSteers, 0.95)))"
          + "  max=\(fmt(absSteers.max() ?? 0))")
    let mean = steers.reduce(0, +) / Double(steers.count)
    print("    steer 均值: \(fmt(mean))  （|均值| 大 = 长期单边偏，可能是系统性偏差）")

    // 饱和率：打到 maxSteer 附近的帧占比
    // 注：maxSteer 是 LaneFallback 的实例属性（不是独立 Config 类型），
    //     这里读的就是生产用的那个 fallback 实例，值与产线完全一致。
    let satThr = fallback.maxSteer * 0.95
    let sat = absSteers.filter { $0 >= satThr }.count
    print("    饱和率    : \(fmt(Double(sat) / Double(steers.count) * 100, 1))%"
          + "  （|steer| ≥ \(fmt(satThr)) 即算饱和）")

    // 抖动：相邻出建议帧的 steer 变化
    var jumps: [Double] = []
    for k in 1..<steers.count { jumps.append(abs(steers[k] - steers[k - 1])) }
    print("    帧间抖动  : p50=\(fmt(pct(jumps, 0.5)))"
          + "  p95=\(fmt(pct(jumps, 0.95)))"
          + "  max=\(fmt(jumps.max() ?? 0))")
    let bigJump = jumps.filter { $0 > 0.1 }.count
    print("    大跳变    : \(bigJump)/\(jumps.count)"
          + "  (\(fmt(Double(bigJump) / Double(max(1, jumps.count)) * 100, 1))% 帧间变化 >0.1)")

    // ══════════════════════════════════════════════════════════════
    print("\n── C. 置信度 ──")
    let confs = nonNil.map(\.confidence)
    print("    confidence: p5=\(fmt(pct(confs, 0.05)))"
          + "  p50=\(fmt(pct(confs, 0.5)))"
          + "  p95=\(fmt(pct(confs, 0.95)))")
    let lowConf = confs.filter { $0 < 0.3 }.count
    print("    低置信(<0.3): \(lowConf)/\(confs.count)"
          + "  (\(fmt(Double(lowConf) / Double(confs.count) * 100, 1))%)")

    // ══════════════════════════════════════════════════════════════
    print("\n── D. 原因分布（它在什么情况下沉默）──")
    var reasons: [String: Int] = [:]
    for a in advices {
        let key: String
        if let a { key = a.reason }
        else { key = "（nil：无建议/被门拦）" }
        reasons[key, default: 0] += 1
    }
    for (r, c) in reasons.sorted(by: { $0.value > $1.value }).prefix(8) {
        print(String(format: "    %5d×  %@", c, r))
    }

    // ══════════════════════════════════════════════════════════════
    print("\n── E. 结论（严格按数据说话）──")
    var verdicts: [String] = []

    // 判据都是**保守的可用性下限**，不做"方向对不对"的越界推断。
    if rate < 30 {
        verdicts.append("❌ 出建议率仅 \(fmt(rate, 1))% —— 大部分时间在沉默，谈不上车道保持")
    } else if rate < 70 {
        verdicts.append("⚠️ 出建议率 \(fmt(rate, 1))% —— 沉默偏多，只能算「偶尔扶一把」")
    } else {
        verdicts.append("✅ 出建议率 \(fmt(rate, 1))% —— 覆盖率可用")
    }

    let jitterP95 = pct(jumps, 0.95)
    if jitterP95 > 0.15 {
        verdicts.append("❌ 帧间抖动 p95=\(fmt(jitterP95)) —— 输出不稳，会画龙")
    } else if jitterP95 > 0.06 {
        verdicts.append("⚠️ 帧间抖动 p95=\(fmt(jitterP95)) —— 偏毛躁")
    } else {
        verdicts.append("✅ 帧间抖动 p95=\(fmt(jitterP95)) —— 输出平稳")
    }

    let satRate = Double(sat) / Double(steers.count) * 100
    if satRate > 20 {
        verdicts.append("❌ 饱和率 \(fmt(satRate, 1))% —— 经常打死方向，危险")
    } else if satRate > 8 {
        verdicts.append("⚠️ 饱和率 \(fmt(satRate, 1))% —— 偶发打死方向")
    } else {
        verdicts.append("✅ 饱和率 \(fmt(satRate, 1))% —— 很少打满")
    }

    for v in verdicts { print("    \(v)") }

    print("\n    ⚠️ 必须说明的局限：本测试**没有车道线真值**，因此")
    print("       上面量的是「可用性下限」（沉默率/抖动/饱和），")
    print("       **不能**据此断言「转向方向是对的」。")
    print("       「抖动小」只是「不画龙」的必要条件，不是充分条件。")

    print("\n═══ 实测完成（跑通 \(processed) 帧）═══")
    return 0
}
