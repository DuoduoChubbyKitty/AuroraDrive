// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// 引导线偏离检测 · 离线回放（--guideline-replay）
//
// 用真实连续训练帧跑生产检测器（GuideLineReader + DeviationTracker），
// 逐帧输出「最近距离 / 线像素数 / 是否判偏离」，并汇总判定率，
// 用于验收「预测是否准」（正常驾驶期不应高频误判）。
//
// 数据：data/lean_clips/<clip>/frames + controls_clean.csv（按键/速度对照）。

import Foundation
import CoreGraphics
import ImageIO

func runGuideLineReplay(clip: String = "clip_20261114_161701",
                        from startFrame: Int = 2010,
                        to endFrame: Int = 2861) -> Int32 {
    let root = "/Users/dupi/Desktop/自动驾驶系统"
    let frameDir = "\(root)/data/lean_clips/\(clip)/frames"

    // 小地图几何（384×224 训练帧实测：圆心 31.6,33.3 半径 33）
    let cx = 31.6, cy = 33.3
    let side = 66

    print("═══ 引导线偏离回放（--guideline-replay）═══")
    print("片段: \(clip) 帧 \(startFrame)~\(endFrame)（\(endFrame - startFrame + 1) 帧）")

    var headings: [Double] = []
    var confidences: [Double] = []
    // 方向判定统计（新判据）
    var alignedCount = 0, misalignedCount = 0, insufficientCount = 0
    var reverseCaught = 0, reverseTotal = 0, reverseMissLog = 0, misalignedLog = 0
    var curveAligned = 0, curveMisaligned = 0, curveInsufficient = 0
    var headingCount = 0
    var scanTimes: [Double] = []
    var tracker = GuideLineReader.DeviationTracker()
    var distances: [Double] = []
    var judgedFrames = 0
    var nilFrames = 0
    var judgedAts: [Int] = []
    var prevDist: Double?
    var jumps: [Double] = []
    var lastUnique: Double? = nil
    var replanResets = 0
    // ── 真实运动方向参考（训练帧无定位真值 → 用「速度积分 + 按键」构造相对位移）──
    let csvPath = "\(root)/data/lean_clips_clean/\(clip)/controls_clean.csv"
    var speeds: [Int: Double] = [:]
    var times: [Int: Double] = [:]
    var steering: [Int: (a: Double, d: Double)] = [:]
    do {
        let csv = try String(contentsOfFile: csvPath, encoding: .utf8)
        // ⚠️ 必须用 components(separatedBy: .newlines)：实测 split(separator: "\n")
        // 在这个 CRLF 文件上只返回 1 行（Swift Character 分割行为），导致解析全空。
        let allLines = csv.components(separatedBy: .newlines)
        for line in allLines.dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 6, let idx = Int(c[1]) else { continue }
            if let spd = Double(c[2]), spd > 0 { speeds[idx] = spd }
            if let t = Double(c[0]) { times[idx] = t }
            steering[idx] = (Double(c[4]) ?? 0, Double(c[5]) ?? 0)   // a=左, d=右
        }
    } catch {
        print("  ❌ CSV 读取失败: \(error)")
    }
    var positions: [(world: CGPoint, at: TimeInterval)] = []

    // 逐帧读（每帧 jpg 解码；只读小地图 66×66）
    for f in startFrame...endFrame {
        let path = String(format: "%@/%06d.jpg", frameDir, f)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            nilFrames += 1
            continue
        }
        let x0 = Int(cx) - side / 2, y0 = Int(cy) - side / 2
        guard let mm = img.cropping(to: CGRect(x: max(0, x0), y: max(0, y0),
                                                width: side, height: side)),
              let dev = GuideLineReader.deviation(minimap: mm) else {
            nilFrames += 1
            continue
        }
        distances.append(dev.distancePx)
        headings.append(dev.lineHeadingDeg)
        confidences.append(dev.headingConfidence)
        if dev.lineHeadingDeg != 0 || dev.headingConfidence > 0 { headingCount += 1 }
        // ── 方向判定：**模拟生产路径**（累积 1 秒窗口找最早采样点）──
        // ⚠️ 2026-11-22 修正：最初只喂单帧位移 → 60~130km/h 下每帧仅 1.1~2.4m
        // < 1 个量化格(2.44m) → 98.7% 判 insufficient。生产 GuideLineMotion 是
        // 从 positions 里**往回找**最早点算位移（movementWindow=1s），回放必须同构。
        let spd = speeds[f] ?? 0
        let tNow = times[f] ?? (Double(f) / 15.0)
        positions.removeAll { tNow - $0.at > GuideLineMotion.movementWindow }
        // 弯道检测：近段走向 vs 远端方位夹角。夹角大=弯道，此时"沿远端走"
        // 不等于真实运动方向（车沿当前切线走），不能用来验证正常驾驶误判率。
        var bendDiff = 0.0
        if dev.farConfidence >= 0.35 {
            bendDiff = abs(dev.lineHeadingDeg - dev.farBearingDeg)
                .truncatingRemainder(dividingBy: 180)
            if bendDiff > 90 { bendDiff = 180 - bendDiff }
        }
        let isStraight = bendDiff < 30
        if spd > 15, dev.farConfidence >= 0.35, let oldest = positions.first {
            let dt = tNow - oldest.at
            if dt > 0, dt < GuideLineMotion.maxFrameGap * 15 {   // 最多约 1 秒
                let dist = spd / 3.6 * dt * 100           // 米 → 厘米
                // 沿线远端方位前进 = 正常沿线驾驶（这是录制数据能给出的最可信真值）
                let fr = dev.farBearingDeg * .pi / 180
                let stepX = sin(fr) * dist, stepY = cos(fr) * dist
                let verdict = GuideLineReader.judgeDirection(
                    movedWorldX: stepX, stepY,
                    lineHeadingDeg: dev.lineHeadingDeg,
                    confidence: dev.headingConfidence,
                    farBearingDeg: dev.farBearingDeg,
                    farConfidence: dev.farConfidence)
                switch verdict {
                case .aligned:
                    if isStraight { alignedCount += 1 } else { curveAligned += 1 }
                case .misaligned(let deg):
                    if isStraight { misalignedCount += 1 } else { curveMisaligned += 1 }
                    if misalignedLog < 6 {
                        misalignedLog += 1
                        print("  [mis] deg=\(String(format:"%.0f",deg)) farConf=\(String(format:"%.2f",dev.farConfidence)) headingConf=\(String(format:"%.2f",dev.headingConfidence)) lineH=\(String(format:"%.1f",dev.lineHeadingDeg)) farB=\(String(format:"%.0f",dev.farBearingDeg))")
                    }
                case .insufficient:
                    if isStraight { insufficientCount += 1 } else { curveInsufficient += 1 }
                }
                // 逆行反例：沿线反方向走，必须判 misaligned
                let revVerdict = GuideLineReader.judgeDirection(
                    movedWorldX: -stepX, -stepY,
                    lineHeadingDeg: dev.lineHeadingDeg,
                    confidence: dev.headingConfidence,
                    farBearingDeg: dev.farBearingDeg,
                    farConfidence: dev.farConfidence)
                if case .misaligned = revVerdict {
                    reverseCaught += 1
                } else if reverseMissLog < 5 {
                    reverseMissLog += 1
                    print("  [miss] farConf=\(String(format:"%.2f",dev.farConfidence)) farBearing=\(String(format:"%.0f",dev.farBearingDeg)) lineHeading=\(String(format:"%.1f",dev.lineHeadingDeg)) verdict=\(revVerdict)")
                }
                reverseTotal += 1
            }
        }
        positions.append((CGPoint(x: 0, y: 0), tNow))
        if let p = prevDist { jumps.append(abs(dev.distancePx - p)) }
        prevDist = dev.distancePx

        // 重规划计数（用于统计稳定性）
        if let last = lastUnique, abs(dev.distancePx - last) > tracker.replanJumpPx {
            replanResets += 1
        }
        lastUnique = dev.distancePx

        if tracker.update(distancePx: dev.distancePx) {
            judgedFrames += 1
            if judgedAts.count < 20 { judgedAts.append(f) }
        }
    }

    guard !distances.isEmpty else {
        print("  ❌ 未读到任何帧")
        return 1
    }
    let sorted = distances.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let p05 = sorted[Int(Double(sorted.count) * 0.05)]
    let js = jumps.sorted()
    let jumpMedian = js.isEmpty ? 0 : js[js.count / 2]

    print("")
    print("── 统计 ──")
    print(String(format: "  有效帧 %d / 总帧 %d（跳过 %d）", distances.count,
                 endFrame - startFrame + 1, nilFrames))
    print(String(format: "  最近距离: 中位 %.1fpx  p05 %.1f  p95 %.1f  min %.1f  max %.1f",
                 median, p05, p95, sorted.first!, sorted.last!))
    print(String(format: "  相邻帧跳变中位: %.2fpx", jumpMedian))
    print(String(format: "  判「偏离」帧: %d / %d = %.1f%%",
                 judgedFrames, distances.count,
                 Double(judgedFrames) / Double(distances.count) * 100))
    print("  重规划突变次数（距离跳变 >15px）: \(replanResets)")
    let dirTotal = alignedCount + misalignedCount + insufficientCount
    print("  [诊断] dirTotal=\(dirTotal) aligned=\(alignedCount) misaligned=\(misalignedCount) insuff=\(insufficientCount)")
    if dirTotal > 0 {
        print(String(format: "  方向判定: aligned %d (%.1f%%) / misaligned %d (%.1f%%) / insufficient %d (%.1f%%)",
                     alignedCount, Double(alignedCount)/Double(dirTotal)*100,
                     misalignedCount, Double(misalignedCount)/Double(dirTotal)*100,
                     insufficientCount, Double(insufficientCount)/Double(dirTotal)*100))
        print(String(format: "  → 沿线正常驾驶误判率(misaligned) = %.1f%%（应 <10%%）",
                     Double(misalignedCount)/Double(dirTotal)*100))
    }
    let curveTotal = curveAligned + curveMisaligned + curveInsufficient
    if curveTotal > 0 {
        print(String(format: "  弯道帧(近远端夹角>30°): aligned %d / misaligned %d / insuff %d 共 %d（弯道不参与正常驾驶误判统计）",
                     curveAligned, curveMisaligned, curveInsufficient, curveTotal))
    }
    if reverseTotal > 0 {
        print(String(format: "  逆行捕获率: %d/%d = %.1f%%（应 100%%）",
                     reverseCaught, reverseTotal, Double(reverseCaught)/Double(reverseTotal)*100))
    }
    // ── 引导线走向（PCA）稳定性 ──
    if headings.count > 10 {
        let hs = headings.sorted()
        let hMedian = hs[hs.count / 2]
        let cs = confidences.sorted()
        let cMedian = cs[cs.count / 2]
        // 走向变化（[0,180) 角度差，最小环绕）
        var hJumps: [Double] = []
        for i in 1..<headings.count {
            var d = abs(headings[i] - headings[i-1]).truncatingRemainder(dividingBy: 180)
            if d > 90 { d = 180 - d }
            hJumps.append(d)
        }
        let hjs = hJumps.sorted()
        print(String(format: "  引导线走向: 中位 %.1f°  相邻帧变化中位 %.1f°  拟合置信度中位 %.2f",
                     hMedian, hjs[hjs.count / 2], cMedian))
    }
    if !judgedAts.isEmpty {
        print("  前 20 个判偏离帧: \(judgedAts.map(String.init).joined(separator: ","))")
    }
    // ── 明确 PASS/FAIL 判据（用户 2026-11-22：抽 5 批各测，全过才部署）──
    let distanceRate = Double(judgedFrames) / Double(distances.count)
    let straightTotal = alignedCount + misalignedCount + insufficientCount
    let straightMisrate = straightTotal > 0
        ? Double(misalignedCount) / Double(straightTotal) : 0
    let reverseRate = reverseTotal > 0 ? Double(reverseCaught) / Double(reverseTotal) : 1
    let headingConfMedian: Double = {
        let cs = confidences.sorted()
        return cs.isEmpty ? 0 : cs[cs.count / 2]
    }()

    print("")
    print("── 验收判据 ──")
    var failures: [String] = []
    // ① 像素距离判据误判率 <10%
    if distanceRate >= 0.10 {
        failures.append(String(format: "距离判据误判率 %.1f%% ≥10%%", distanceRate*100))
    }
    // ② 直路方向误判率 <10%
    if straightMisrate >= 0.10 {
        failures.append(String(format: "直路方向误判率 %.1f%% ≥10%%", straightMisrate*100))
    }
    // ③ 逆行捕获率 ≥95%
    if reverseRate < 0.95 {
        failures.append(String(format: "逆行捕获率 %.1f%% <95%%", reverseRate*100))
    }
    // ④ 走向拟合置信度中位 ≥0.35（判据可用的前提）
    if headingConfMedian < 0.35 {
        failures.append(String(format: "走向置信度中位 %.2f <0.35", headingConfMedian))
    }
    // ⑤ 有效帧覆盖率 ≥90%（数据可读性）
    let coverage = Double(distances.count) / Double(endFrame - startFrame + 1)
    if coverage < 0.90 {
        failures.append(String(format: "有效帧覆盖率 %.1f%% <90%%", coverage*100))
    }

    print(String(format: "  ① 距离判据误判率 %.1f%% (需<10%%)  %@",
                 distanceRate*100, distanceRate < 0.10 ? "✅" : "❌"))
    print(String(format: "  ② 直路方向误判率 %.1f%% (需<10%%)  %@",
                 straightMisrate*100, straightMisrate < 0.10 ? "✅" : "❌"))
    print(String(format: "  ③ 逆行捕获率 %.1f%% (需≥95%%)  %@",
                 reverseRate*100, reverseRate >= 0.95 ? "✅" : "❌"))
    print(String(format: "  ④ 走向置信度中位 %.2f (需≥0.35)  %@",
                 headingConfMedian, headingConfMedian >= 0.35 ? "✅" : "❌"))
    print(String(format: "  ⑤ 有效帧覆盖率 %.1f%% (需≥90%%)  %@",
                 coverage*100, coverage >= 0.90 ? "✅" : "❌"))

    if failures.isEmpty {
        print("  🟢 PASS —— 本批全部通过")
        print("═══ 完成 ═══")
        return 0
    } else {
        print("  🔴 FAIL —— 未通过项: " + failures.joined(separator: "; "))
        print("═══ 完成 ═══")
        return 1
    }
}
