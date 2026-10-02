// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LaneFallback.swift — 车道线 / 可行驶区兜底决策
//
//  职责：模型失效或主驾不可信时，用车道线 + 可行驶区给出**保守**行驶建议。
//
//  定位：这是"兜底"，不是"主驾"。设计原则全部服务于一个目标 ——
//        **绝不能让兜底本身成为事故源**：
//    ① fail-open：任何一个输入不可信（degraded / 掩码为空 / 尺寸不符），
//       立即返回 nil，调用方维持原决策，绝不"猜一个方向"。
//    ② 有界输出：转向修正硬限幅（±maxSteer），油门只减不加，
//       永不输出满油门（兜底没有能力判断能不能加速）。
//    ③ 连续帧确认：同一方向的偏差需连续 N 帧稳定才采纳，
//       避免单帧掩码抖动导致方向来回抽。
//    ④ 突变丢弃：帧间偏差跳变超阈值视为异常帧，沿用上一有效值。
//
//  纯函数式（与 RuleController 同风格）：无副作用、可单测。
//  唯一的内部状态是本类型的稳定性计数器，由调用方每帧喂入。
// ============================================================================

import CoreGraphics
import Foundation

// MARK: - 建议输出

/// 兜底建议（nil 表示"无可信建议，别听我的"）
struct LaneAdvice: Equatable {

    /// 转向修正 [-maxSteer, maxSteer]，左负右正（与 ControlCommand 同号）
    let steer: Double

    /// 建议刹车 [0, 1]（0 = 不介入）
    let brake: Double

    /// 建议油门上限 [0, 1]（只用于**压低**，调用方取 min）
    ///
    /// ⚠️ 2026-09-26 改为 **Optional**：`nil` = **对油门不表态**（调用方保持原值）。
    ///    原先用 `1.0` 表示"不改变"，但 `min(cmd.throttle, 1.0)` 恒等于原值，
    ///    "不表态"与"上限恰好是 1.0"两种语义被混为一谈 —— 无法从类型上区分
    ///    「兜底没意见」和「兜底同意全油门」。改 Optional 后语义显式化。
    ///
    /// 结构性保守保证：**只要兜底真的在介入（转向或刹车），throttleCap 一定非 nil
    /// 且 ≤ 0.3**（见 `evaluate` 第 4 节）。即"兜底在场 ⇒ 保守"由类型与赋值共同保证，
    /// 而不是靠调用方自觉。
    let throttleCap: Double?

    /// 置信度 [0, 1]，供上层降低权重
    let confidence: Double

    /// 可读原因（日志/UI）
    let reason: String
}

// MARK: - 兜底控制器

/// 车道线兜底决策器
/// - 有状态（稳定性计数），须由同一调用方按帧顺序喂入
/// - 非 @Observable：状态仅用于内部去抖，UI 读 advice 即可
final class LaneFallback {

    // MARK: - 可调参数

    /// 转向修正上限（硬限幅，绝不放松）
    /// 0.25 的修正量在实测里约等于"轻扶一把方向"，不足以造成甩尾。
    var maxSteer: Double = 0.25

    /// 可行驶区"安全占比"下限：低于此值认为车头前方快没路了
    /// 参考实测：真实行车图 da 正像素 8.4~16.2%；取 5% 作为"道路很窄"的警戒线
    var drivableFloor: Double = 0.05

    /// 可行驶占比低于此值 → 触发刹车建议（比 floor 更紧急）
    var drivableCritical: Double = 0.02

    /// 车道线偏差（归一化横向偏移）达到此值才介入修正
    /// 0.06 ≈ 画面宽度的 6%，约为一个车宽的横向偏移
    var steerDeadband: Double = 0.06

    /// 偏差 → 转向的比例增益（Kp）
    var steerGain: Double = 3.0

    /// 航向偏差 → 转向的微分增益（Kd）。2026-09-30 新增。
    /// 计划约定 Kd = Kp × 1.2 = 3.6；现场若画龙则调小（航向项过冲的典型表现）。
    var headingGain: Double = 3.6

    /// 地图先验的航向增益（Kd_map）：仅在**视觉不可信**时启用（见 evaluate 第 6 节）。
    /// 比视觉 Kd 保守：地图是玩家标注版，只用于"路往哪拐"的米级判断。
    var mapHeadingGain: Double = 2.5

    /// 帧间偏差跳变上限：超过视为异常帧，丢弃
    var maxDeviationJump: Double = 0.15

    /// 兜底**介入期间**的油门上限（结构性保守保证，见 `evaluate` 第 4 节）。
    /// 只要给出了转向修正或刹车，油门必被压到此值以下 —— 兜底不该默许满油门。
    nonisolated static let interveningThrottleCap: Double = 0.3

    /// 连续一致帧数门槛（约 0.2s @30Hz）
    ///
    /// ⚠️ 2026-09-26：**帧计数在变帧率下不等价于固定时长**。
    ///    YOLOPX 实测端到端约 119~163ms（≈6~8Hz），而调用方 tick 是 30Hz，
    ///    且 `infer()` 有"上一帧没跑完就跳过"的防重叠门 —— 因此喂进本函数的
    ///    **不是**每 33ms 一帧，而是每 ~120ms 一帧。此时 6 帧 ≈ 0.72s，
    ///    比注释写的 0.2s 慢 3.6 倍，稳定性门实际比设计意图迟钝得多。
    ///    现在改为**双条件**：帧数达标 **或** 时间窗达标（见 `stabilityWindowSeconds`）。
    var stabilityFrames: Int = 6

    /// 稳定性时间窗（秒）：与 `stabilityFrames` 取"先到者"。
    /// 用**真实经过时间**折算，因此不受推理帧率变化影响 —— 推理变快不会让门变松，
    /// 变慢也不会让门变严。0.2s 保留原注释表达的设计意图。
    var stabilityWindowSeconds: TimeInterval = 0.2

    /// 采样带在**有效内容区**内的相对位置（下 1/4 ~ 下 9/10）。
    /// 用比例而非绝对像素，才能适配不同宽高比（16:9 / 16:10 / 21:9 / 竖屏）。
    /// 见 `evaluate` 第 1 节的动态计算说明。
    nonisolated static let sampleBandTopFrac: Double = 0.25
    nonisolated static let sampleBandBottomFrac: Double = 0.9

    // MARK: - 内部状态

    /// 上一有效偏差
    private var lastDeviation: Double?

    /// 当前方向的连续稳定帧数
    private var stableCount = 0

    /// 本方向首次成立的时刻（用于时间窗判定）
    private var stableSince: Date?

    /// 当前稳定方向符号（-1 左 / +1 右 / 0 居中）
    private var stableSign = 0

    /// 最近一次输出（供 UI 显示）
    private(set) var lastAdvice: LaneAdvice?

    // MARK: - 主入口

    /// 评估一帧。
    /// - Parameters:
    ///   - laneMask: 车道线掩码（letterbox 640 坐标系，下采样网格）
    ///   - drivableMask: 可行驶区掩码（同坐标系）
    ///   - isDegraded: 感知层报告的降级标志 —— **为 true 时一律返回 nil**
    ///   - metrics: letterbox 参数（用于把网格坐标换算回 valid 区域）
    /// - Returns: 建议；不可信时返回 nil
    func evaluate(laneMask: MaskGrid,
                  drivableMask: MaskGrid,
                  isDegraded: Bool,
                  metrics: LetterboxMetrics) -> LaneAdvice? {

        // ── 门①：降级 = 闭嘴 ──
        // 这是最重要的一条。感知层已经说了"我的掩码不可信"，
        // 兜底再基于它给方向就是拿事故赌运气。
        guard !isDegraded else {
            reset()
            return nil
        }

        // ── 门②：掩码有效性 ──
        // ⚠️ 2026-09-26：补 laneMask 与 drivableMask 的**同构**校验。
        //    两者来自同一帧同一 letterbox 坐标系，尺寸不一致说明上游给了错配数据，
        //    此时按任一方的几何去换算都是错的 → 必须拒绝。
        // ⚠️ 2026-09-27（R2-B1 修复）：仅"两者相同"**不够** —— 实测 (ll=80, da=80)
        //    这种"自洽且相等"的组合仍会通过旧门② 并给出 steer=∓0.25 的建议。
        //    根因是 evaluate 里存在**两套坐标系**：偏差用 laneMask.width 归一化
        //    （:205），valid 区却用 drivableMask.width 换算（ratio() 内）——
        //    尺寸只要不是预期的 160，两边算出来的就是"用 A 的尺子量、用 B 的尺子判"。
        //    故必须再与**生产常量** maskGridSize 比对：只有真正预期的 160 才放行。
        //    这是本方法的唯一契约"输入不可信 ⇒ 返回 nil"的核心执行点。
        guard laneMask.width > 0, drivableMask.width > 0,
              laneMask.width == laneMask.height,
              drivableMask.width == drivableMask.height,
              laneMask.width == drivableMask.width,
              laneMask.height == drivableMask.height,
              laneMask.width == YolopxEngine.maskGridSize,
              laneMask.height == YolopxEngine.maskGridSize,
              drivableMask.width == YolopxEngine.maskGridSize,
              drivableMask.height == YolopxEngine.maskGridSize,
              metrics.newW > 0, metrics.newH > 0 else {
            reset()
            return nil
        }

        // 网格坐标 → letterbox 640 坐标的比例
        let scale = Double(YolopxEngine.inputSize) / Double(laneMask.width)

        // ── 1. 车道线横向偏差（只看近处采样带）──
        // 做法：在采样带内逐行找车道线像素的加权中心，取所有行的中位数。
        // 中位数比均值抗离群点（单行误检不会带偏整帧）。
        //
        // ⚠️ 2026-09-26 修：采样带原为**硬编码** 640 坐标 y∈[360,600)，
        //    它假设内容总是铺满整高 —— 但 21:9 这类宽幅输入的内容只有 270 高、
        //    上方还有 185 灰边，硬编码区间会整段落在灰边里（读到的全是 0），
        //    或落在图像之外，于是"看不见车道线"却无法区分是"真没有"还是"取错位置"。
        //    现改为**按 metrics 动态计算**：在**有效内容区** [padY, padY+newH) 内
        //    取下 1/4 ~ 下 9/10 作为近处采样带（近处 = 画面下方）。
        let contentTop = Double(metrics.padY)
        let contentBottom = Double(metrics.padY + metrics.newH)
        let contentH = contentBottom - contentTop
        guard contentH > 0 else {
            reset()
            return nil
        }
        let bandTop = contentTop + contentH * Self.sampleBandTopFrac      // 下 1/4 起
        let bandBottom = contentTop + contentH * Self.sampleBandBottomFrac // 到下 9/10
        let y0 = max(0, Int(bandTop / scale))
        let y1 = min(laneMask.height, Int(bandBottom / scale))
        guard y1 > y0 else {
            reset()
            return nil
        }

        // ══════════════════════════════════════════════════════════════════
        //  拟合升级（2026-09-30）：逐行质心 → 最左/最右**边缘对** + 线性拟合
        // ══════════════════════════════════════════════════════════════════
        //
        // 【为什么必须升级】laneMask 是**单通道二值**（不分左右线），旧实现
        //   逐行取"所有车道线像素的质心"再取中位数：
        //     · 只有**横向**一个自由度（≈ P 控制器）→ **无法提前入弯**，
        //       高速微弯只能等车偏了才修，表现为"画龙"；
        //     · 质心把左右两条线**混在一起**：只看见一条线时，质心落在
        //       那条线上，会被误读成"车道中心"→ 方向直接错半个车道。
        //
        // 【新实现】每行取**最左像素与最右像素**：
        //     · 两者中点 = 本行车道的横向中心（比质心稳，且天然对应"车道"）
        //     · 两者间距 = 本行车道的可见宽度（用于**车道宽度一致性**检查：
        //       宽度突变 >30% 说明这一行混入了别的线/误检 → 丢该行）
        //     · 对 (行中心 vs 行号) 做**一次线性拟合**（最小二乘）：
        //         截距 → 横向偏差 deviation（车偏左/右）
        //         斜率 → **航向偏差 headingError（新增）** ★弯道提前转向的关键
        //
        // 【为什么不用二次拟合（曲率）】实测采样带内有效行仅 ~20 行，
        //   二次项在这种数据量下噪声主导；且转向控制只需要"横向 + 航向"
        //   两个自由度（曲率只影响该不该减速）。故本轮只做一次拟合。
        var rowCenters: [Double] = []
        var rowYs: [Double] = []
        rowCenters.reserveCapacity(y1 - y0)
        rowYs.reserveCapacity(y1 - y0)
        var lastCenter: Double? = nil
        var lastWidth: Double? = nil

        for y in y0..<y1 {
            var leftmost: Int? = nil
            var rightmost: Int? = nil
            for x in 0..<laneMask.width where laneMask.at(x, y) {
                if leftmost == nil { leftmost = x }
                rightmost = x
            }
            // 整行没有车道线 → 跳过（不断链：只丢这一行，不影响其余行）
            guard let lx = leftmost, let rx = rightmost else { continue }
            let center = (Double(lx) + Double(rx)) / 2.0 / Double(laneMask.width)
            let width = Double(rx - lx) / Double(laneMask.width)

            // ── 连续性剔离群 ──
            // 相邻行的中心不该跳变过大（真实车道线是连续曲线）。阈值取 5% 画面宽：
            // 采样带内相邻行（间隔约 1 格 ≈ 2% 画面高）的车道中心不可能横跳 5%。
            if let lc = lastCenter, abs(center - lc) > 0.05 {
                continue                      // 该行是离群（误检/串线），丢弃
            }
            // ── 车道宽度突变检查 ──
            // 同一帧内相邻行的可见宽度应大致一致；突变 >30% 说明该行混入了
            // 另一条线（例如左侧线误检到右侧）→ 丢弃该行。
            if let lw = lastWidth, lw > 1e-6, abs(width - lw) / lw > 0.30 {
                continue
            }
            rowCenters.append(center)
            rowYs.append(Double(y))
            lastCenter = center
            lastWidth = width
        }

        // 有效行太少 → 车道线没看见，不猜（保持原有 fail-open）
        guard rowCenters.count >= 3 else {
            reset()
            return nil
        }

        // ── 线性拟合：center(y) = slope·y + intercept（最小二乘）──
        // 用 y 作自变量（行号越大越靠近车）。y 的跨度决定航向项的灵敏度，
        // 故统一归一化到 [0,1]（行号区间）后再拟合，使增益与采样带高度解耦。
        let yMin: Double = rowYs.min() ?? 0
        let yMax: Double = rowYs.max() ?? 1
        let ySpan: Double = max(1.0, yMax - yMin)
        var sX = 0.0, sY = 0.0, sXX = 0.0, sXY = 0.0
        let n = Double(rowCenters.count)
        for i in 0..<rowCenters.count {
            let x: Double = (rowYs[i] - yMin) / ySpan   // 归一化行位置 [0,1]
            let yy = rowCenters[i]
            sX += x; sY += yy; sXX += x * x; sXY += x * yy
        }
        let denom = n * sXX - sX * sX
        var slope = 0.0
        var intercept = sY / n
        if abs(denom) > 1e-9 {
            slope = (n * sXY - sX * sY) / denom
            intercept = (sY - slope * sX) / n
        }
        // 横向偏差：采样带**近端**（x=1，最靠近车的那一端）的拟合值 - 0.5
        // 用近端而不是均值：驾驶关心的是"车头正前方这段"偏多少，不是整条带的平均。
        let deviation = (slope * 1.0 + intercept) - 0.5

        // 航向偏差 headingError：
        //   slope > 0 表示"越靠近车（y 越大）车道中心越靠右" —— 画面里这意味着
        //   道路**向右前方延伸**？其实相反：近处偏右、远处偏左 = 车道向左拐。
        //   取 slope 的**负值**并乘以采样带纵向跨度（把归一化斜率还原成画面尺度），
        //   得到"车道相对车头的指向偏差"。符号约定与 deviation 一致：
        //   正值 = 需要向右打方向。
        // 纵向跨度按采样带实际像素高度还原（letterbox 坐标 ≈ 画面高度的 65%）。
        let bandPixelHeight = max(1.0, Double(y1 - y0))
        var headingError = -slope * (bandPixelHeight / Double(laneMask.height)) * 2.0
        // 限幅：航向项不该单帧主导（噪声行会产生尖峰斜率）
        headingError = max(-0.5, min(0.5, headingError))

        // ── 门③：突变丢弃 ──
        if let last = lastDeviation, abs(deviation - last) > maxDeviationJump {
            // 异常帧：不更新稳定性，沿用上一有效值（返回 nil 交给调用方保持原决策）
            return nil
        }
        lastDeviation = deviation

        // ── 2. 稳定性确认（帧数 **或** 时间窗，先到者成立）──
        let sign: Int
        if abs(deviation) <= steerDeadband {
            sign = 0
        } else {
            sign = deviation > 0 ? 1 : -1
        }

        // 为什么双条件：帧计数在变帧率下不等于固定时长（推理 ~6-8Hz、tick 30Hz，
        // 见 stabilityFrames 注释）。时间窗给出与帧率无关的"至少稳定多久"保证。
        let now = Date()
        if sign == stableSign {
            stableCount += 1
            // stableSince 在方向切换时已重置；此处保持不变
        } else {
            stableSign = sign
            stableCount = 1
            stableSince = now
        }

        /// 稳定性是否达标：帧数够 **或** 时间够（且方向非居中）
        let framesOK = stableCount >= stabilityFrames
        let timeOK: Bool = {
            guard sign != 0, let since = stableSince else { return false }
            return now.timeIntervalSince(since) >= stabilityWindowSeconds
        }()
        let stableEnough = framesOK || timeOK

        // ── 3. 可行驶区占比（刹车建议）──
        let (drivableRatio, validCells) = Self.ratio(drivableMask, metrics: metrics)
        guard validCells > 0 else {
            reset()
            return nil
        }

        // ── 4. 组装建议 ──
        var steer = 0.0
        var reason: String

        if sign != 0 && stableEnough {
            // 符号约定（务必与 ControlCommand / steerDeadband 一致）：
            //   deviation = 近端拟合中心 - 0.5，**正 = 车道中心在画面右侧**。
            //   steer 正 = 向右打方向（与 ControlCommand.steer 同号）。
            //   车偏左时车道中心出现在右侧 → deviation > 0 → 应**向右**修正 → steer > 0。
            // 故此处取 +deviation，**不能取负**（2026-09-26 曾因取负导致方向反向）。
            //
            // ── PD 控制律（2026-09-30 升级：P → PD）──
            //   steer = Kp·横向偏差 + Kd·航向偏差
            //   航向项的价值：车在**微弯**里方向还没偏时，车道线本身已呈现斜率，
            //   航向项立刻给出"提前打一点"的转向 → 车沿着弯道平滑走，不再
            //   等横向偏了才修（那正是"画龙"的成因）。
            let raw = deviation * steerGain + headingError * headingGain
            steer = max(-maxSteer, min(maxSteer, raw))
            reason = String(format: "车道偏差 %.3f 航向 %.3f 稳定 %d 帧",
                            deviation, headingError, stableCount)
        } else if sign != 0 {
            reason = String(format: "车道偏差 %.3f 稳定中 %d/%d",
                            deviation, stableCount, stabilityFrames)
        } else {
            reason = "车道居中"
        }

        var brake = 0.0
        var throttleCap: Double? = nil      // nil = 对油门不表态

        // 🚨 2026-10-02 修改（用户明确要求）：**车道兜底不再输出任何刹车**。
        //
        // 原因同 RuleController：本游戏里 `brake` 就是 **S 键，兼作倒车**，
        //   输出 brake 等于让 AI 自动倒车，与用户抢控制权。
        //
        // 原行为（已废）：
        //   drivableRatio < drivableCritical → brake = 0.6
        //   drivableRatio < drivableFloor    → brake = 0.25
        //
        // 现行为：可行驶区偏少时**只压油门**（压到 0 或 0.3），不碰刹车。
        //   油门压到 0 已能让车自然滑行减速；真要停车由用户自己踩。
        if drivableRatio < drivableCritical {
            throttleCap = 0.0
            reason += "｜前方可行驶区极少（\(String(format: "%.1f", drivableRatio * 100))%）"
        } else if drivableRatio < drivableFloor {
            throttleCap = 0.3
            reason += "｜前方可行驶区偏少（\(String(format: "%.1f", drivableRatio * 100))%）"
        }

        // ── 结构性保守保证 ──
        // 只要兜底**真的在介入**（给了转向修正或压了油门），就必须同时**压住油门**：
        // 兜底没有能力判断"前方能不能加速"（它只看车道线横向位置与可行驶区占比），
        // 所以它一旦开口，就不该默许满油门。
        // 这样「兜底在场 ⇒ 保守」由赋值保证，而不是靠调用方记得检查。
        // 上限 0.3：与"可行驶区偏少"档同量级，属"轻踩"而非"滑行"。
        let isIntervening = abs(steer) > 0 || brake > 0 || throttleCap != nil
        if isIntervening {
            throttleCap = min(throttleCap ?? 1.0, Self.interveningThrottleCap)
        }

        // 置信度：偏差越稳、可行驶区越充足越高
        let stabilityScore = min(1.0, Double(stableCount) / Double(max(stabilityFrames, 1)))
        let drivableScore = min(1.0, drivableRatio / 0.15)
        let confidence = max(0.0, min(1.0, 0.5 * stabilityScore + 0.5 * drivableScore))

        let advice = LaneAdvice(steer: steer,
                                brake: brake,
                                throttleCap: throttleCap,
                                confidence: confidence,
                                reason: reason)
        lastAdvice = advice
        return advice
    }

    /// 清空内部状态（停止驾驶 / 降级 / 模型重载时调用）
    func reset() {
        lastDeviation = nil
        stableCount = 0
        stableSign = 0
        stableSince = nil
        lastAdvice = nil
    }

    // MARK: - 工具（nonisolated，纯函数）

    /// 掩码在 letterbox valid 区域内的正像素占比。
    /// 灰边不计入 —— 否则固定面积的灰边会稀释占比，让降级线失去意义。
    private static func ratio(_ grid: MaskGrid,
                              metrics: LetterboxMetrics) -> (ratio: Double, validCells: Int) {
        guard grid.width > 0 else { return (0, 0) }
        let scale = Double(YolopxEngine.inputSize) / Double(grid.width)
        let x0 = max(0, Int(Double(metrics.padX) / scale))
        let y0 = max(0, Int(Double(metrics.padY) / scale))
        let x1 = min(grid.width, Int(ceil(Double(metrics.padX + metrics.newW) / scale)))
        let y1 = min(grid.height, Int(ceil(Double(metrics.padY + metrics.newH) / scale)))
        guard x1 > x0, y1 > y0 else { return (0, 0) }

        var total = 0, pos = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                total += 1
                if grid.at(x, y) { pos += 1 }
            }
        }
        return total > 0 ? (Double(pos) / Double(total), total) : (0, 0)
    }
}
