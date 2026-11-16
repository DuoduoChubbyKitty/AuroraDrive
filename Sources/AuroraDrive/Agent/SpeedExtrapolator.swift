// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  SpeedExtrapolator.swift — 车速表读数丢失期的短期线性外推（2026-11-13）
// ============================================================================
//
//  【职责】速度表 OCR 在低置信度或短暂遮挡时读不到数，本结构用最近一段
//  有效读数拟合速度斜率，做短期线性外推，给决策层一个合理的估计车速。
//
//  【为什么不再「向 0 一阶衰减」】
//    改前 tick 在 OCR 失效时执行 `effectiveSpeed *= 0.9`，让界面与决策误以为
//    车在减速；但速度表读不到 ≠ 车停了（可能只是被遮挡/HUD 暂隐/菜单切换）。
//    假减速会让限速判断、卡死判据读到错误的速度轨迹。
//
//  【安全边界】
//    · 外推最多持续 `maxExtrapolationSec` 秒；超时后冻结在最后有效值，不再增长。
//    · 外推结果一律 clamp 到 [0, maxSpeedKmh]，防止长外推跑飞。
//    · 样本窗口 `sampleWindowSec` 秒，更早的样本丢弃，避免用陈旧趋势外推。
//
//  【纯逻辑、无 I/O】时间由调用方传入，可在单元测试里用合成时间反复喂样本。
//
//  【与 speedValid 的关系】本结构只负责估计，不负责可信性判定。
//    SpeedTrackingState 将估计值与可信 OCR 平滑值分开；tick 仅把 trustedSpeedKmh
//    交给控制消费者。外推/冻结值留在 effectiveSpeed，供诊断和 IPC 展示使用。
//
// ============================================================================

import Foundation

/// 车速外推器（纯逻辑）
struct SpeedExtrapolator {

    /// 有效样本窗口（秒）：只用最近这段时间内的有效读数拟合斜率。
    /// recordValid 入样时与 estimatedSpeed 求斜率时都按此窗口裁剪，避免用陈旧
    /// 趋势外推（若只在入样时裁剪，稀疏查询仍可能拿窗外旧样本长距离外推）。
    let sampleWindowSec: Double
    /// 最长外推时长（秒）：超过则冻结在最后有效值，不再外推
    let maxExtrapolationSec: Double
    /// 车速上界（km/h），外推结果 clamp 到此值
    let maxSpeedKmh: Double
    /// 至少需要多少个有效样本才敢拟合斜率（1 个样本只能保持，算不出斜率）
    let minSamplesForSlope: Int
    /// 样本数组硬上限（防同刻灌入/时钟异常导致无界增长；正常 2s@30Hz 约 61 个）
    private let maxSamples: Int

    /// 最近的有效 (时刻, 车速) 样本
    private var samples: [(time: Date, speed: Double)] = []
    /// 最后一次有效读数与它的时刻（外推基准）
    private var lastValidSpeed: Double?
    private var lastValidTime: Date?

    init(sampleWindowSec: Double = 2.0,
         maxExtrapolationSec: Double = 2.0,
         maxSpeedKmh: Double = 400.0,
         minSamplesForSlope: Int = 2,
         maxSamples: Int = 256) {
        // 参数合法化：这些值一旦非有限/为负，clamp 上下界会失效（如 maxSpeedKmh=+∞
        // 让 min(·, +∞) 形同虚设、maxExtrapolationSec=+∞ 让 elapsed>maxExtrap 恒假，
        // 再叠加 0×∞ 会产出 NaN）。纯逻辑结构体应自守，不依赖调用方一定传合法值。
        self.sampleWindowSec = (sampleWindowSec.isFinite && sampleWindowSec > 0) ? sampleWindowSec : 2.0
        self.maxExtrapolationSec = (maxExtrapolationSec.isFinite && maxExtrapolationSec > 0) ? maxExtrapolationSec : 2.0
        self.maxSpeedKmh = (maxSpeedKmh.isFinite && maxSpeedKmh > 0) ? maxSpeedKmh : 400.0
        self.minSamplesForSlope = max(1, minSamplesForSlope)
        self.maxSamples = max(self.minSamplesForSlope, maxSamples)
    }

    /// 是否已有至少一次有效读数（供调用方决定能否外推）
    var hasValidReading: Bool { lastValidSpeed != nil }

    /// 喂入一次**有效** OCR 读数（调用方已确认置信度达标且新鲜）。
    mutating func recordValid(speed: Double, at time: Date) {
        guard speed.isFinite, speed >= 0, time.timeIntervalSince1970.isFinite else { return }
        let clamped = min(speed, maxSpeedKmh)
        lastValidSpeed = clamped
        lastValidTime = time
        samples.append((time, clamped))
        pruneSamples(now: time)
        // 硬上限：极端同刻灌入/窗口配置过大时截断最旧样本，保证内存有界
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// 当前时刻应使用的估计车速（km/h）。
    /// - 无任何有效读数 → nil（调用方保持原样 / 显示空）。
    /// - 有斜率且未超外推窗口 → 最后有效值 + 斜率 × 已过时间（clamp 到 [0, maxSpeedKmh]）。
    /// - 样本不足以拟合斜率 → 保持最后有效值。
    /// - 超过外推窗口 → 冻结在最后有效值（不再增长）。
    func estimatedSpeed(at now: Date) -> Double? {
        guard let last = lastValidSpeed, let lastT = lastValidTime else { return nil }
        guard now.timeIntervalSince1970.isFinite else { return last }  // 非法查询时刻→退化为最后值
        let elapsed = max(0, now.timeIntervalSince(lastT))
        // 超外推窗口：冻结在最后有效值（不增长、不清零）
        if elapsed > maxExtrapolationSec {
            return last
        }
        guard let slope = recentSlopeKmhPerSec(at: now) else {
            return last   // 样本不足，退化为保持
        }
        let projected = last + slope * elapsed
        // 防御性有限性守卫：斜率已在 recentSlope 校验有限，但 last+slope*elapsed 在极端
        // 输入下仍可能溢出为 inf（如 slope 极大 × elapsed 极大）→ 退化为最后值。
        guard projected.isFinite else { return last }
        return min(max(projected, 0), maxSpeedKmh)
    }

    /// 清空（停止驾驶 / 重置时调用）
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastValidSpeed = nil
        lastValidTime = nil
    }

    // MARK: - 内部

    private mutating func pruneSamples(now: Date) {
        let cutoff = now.addingTimeInterval(-sampleWindowSec)
        samples.removeAll { $0.time < cutoff }
    }

    /// 最小二乘拟合**查询时刻 now 之前 sampleWindowSec 内**样本的速度斜率
    /// （km/h per 秒）。样本不足或时间不散开时返回 nil。
    /// - 为什么按 now 裁剪：recordValid 时的裁剪只保证「入样那一刻」窗内，若两次
    ///   入样间隔很长，查询时仍会用到过期样本做长距离外推（见边界测试 BUG-3）。
    private func recentSlopeKmhPerSec(at now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-sampleWindowSec)
        // 同时限制上界 $0.time <= now：乱序/时钟回拨时样本可能晚于查询时刻，
        // 若纳入「未来」样本会把斜率算歪（如时间倒退后把未来高速点当历史）。
        let windowed = samples.filter { $0.time >= cutoff && $0.time <= now }
        guard windowed.count >= minSamplesForSlope else { return nil }
        // 以窗口内第一个样本为时间原点（正常单调递增入样时即最早样本；
        // 乱序时仅作相对基准，最小二乘结果与原点选择无关）
        let t0 = windowed[0].time
        var xs: [Double] = []
        var ys: [Double] = []
        for sample in windowed {
            let x = sample.time.timeIntervalSince(t0)
            if let lastX = xs.last, abs(x - lastX) < 1e-6 { continue }  // 同刻去重，防除零
            xs.append(x)
            ys.append(sample.speed)
        }
        guard xs.count >= minSamplesForSlope else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            numerator += dx * (ys[i] - meanY)
            denominator += dx * dx
        }
        guard denominator > 1e-9 else { return nil }
        let slope = numerator / denominator
        guard slope.isFinite else { return nil }
        return slope
    }
}
