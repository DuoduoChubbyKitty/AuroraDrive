// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EgoMotionModel.swift — 自车运动径向模型（光流接线 · 路线2）
//
//  【它解决什么问题】
//    `OpticalFlowBridge` 算了很久的光流，输出 `dx/dy/divergence` 在**全项目
//    零读取方**（2026-09-30 静态核查）。它的设计用途写的是「交叉校验全局运动
//    方向」，但那段校验**从未实现** —— 接口预留了、数据喂进来了、消费端没接线。
//
//    本文件就是那段缺失的消费端：把光流估的**自车运动**变成可用的判据，
//    用来校验 `MotionPredictor` 从**检测框差分**算出的目标速度。
//
//  【为什么是"径向"而不是平移】
//    `MotionPredictor` 的速度来自 α-β 滤波对检测框差分的更新。这个做法有个
//    天生弱点：**目标静止、自车在动**时，它会把"自己的运动"误算成"目标在动"。
//
//    直觉上可以拿光流的 `dx/dy`（全局中位平移）去减，但**那是错的**：
//      · 自车**横移** → 画面内容整体平移 → `dx` 能描述 ✓
//      · 自车**前进** → 画面内容向**消失点径向扩散** → 不是平移 ✗
//    前进时画面中央的目标几乎不动、边缘的目标向外飞，这正是 `divergence`
//    所度量的量。故必须建径向扩张场，而不是简单的平移相减。
//
//  【几何模型】
//    以画面中心为消失点（相机光轴水平时成立）。设某点相对中心的半径向量
//    `r = (px − cx, py − cy)`，自车以速度 v 前进时该点因自车运动产生的位移：
//
//        u_ego(px, py) = forwardRate · r_x
//        v_ego(px, py) = forwardRate · r_y
//
//    其中 `forwardRate` 就是「本帧自车前进导致视野扩张的比例」，
//    与 `OpticalFlowBridge` 的 `divergence` 同量纲（正 = 内容向外扩张 = 前进）。
//
//  【非等比拉伸 —— 本项目的关键几何事实】
//    `CaptureEngine.swift:349` 明确注释：直通帧是「非等比拉伸到 640×640
//    （与训练/慢路径一致，不保持宽高比）」。故：
//      · x/y 两方向的焦距不同（fx ≠ fy），需按屏幕宽高比拆分
//      · 但**消失点恒在画面中心**（拉伸不改变中心）→ 只需 2 个参数即可标定
//    这是本项目比常规标定简单的地方。
//
//  【fail-open —— 本文件最重要的一条纪律】
//    光流失败（首帧 / 尺寸不符 / C 层返回 valid=0）时 `compute` 返回 nil。
//    此时本模型 `estimate` 返回 nil，**上层必须退化为"不拦截"**。
//    绝不能把"没有数据"当成"数据说没问题"，也绝不能当成"自车静止" ——
//    后者会让预测器把运动中的目标冻住，是安全事故。
//
//  【可回退】
//    全部参数走 `AURORA_EGO_*`；关闭校验用 `AURORA_EGO_CHECK=off`。
//    关闭后 `blocksPrediction` 恒为 false，行为与接线前**逐帧一致**。
// ============================================================================

import Foundation

// MARK: - 自车运动估计

/// 光流推算出的自车运动（本帧）。
///
/// 单位说明：
///   · `forwardRate` 无量纲比例（与 `divergence` 同量纲），正 = 前进
///   · `lateralRate` 归一化坐标 / 秒（与 `MotionPredictor` 的 velocity 同单位，
///     便于直接相减）
struct EgoMotionEstimate: Equatable {

    /// 前向运动率（正 = 自车前进）。来源：光流 `divergence`。
    let forwardRate: Double

    /// 横向运动率（归一化坐标 / 秒，正 = 画面内容向右 → 自车向左）。
    /// 来源：光流 `dx`。
    let lateralRate: Double

    /// 本帧间隔（秒），用于把"每帧比例"换算成"每秒率"
    let dt: Double

    /// 置信度 [0,1]。低置信时上层**不应**据此拦截预测。
    ///
    /// 何时低置信：
    ///   · `dt` 异常（≤0 或过大）→ 比率不可信
    ///   · `forwardRate` 超出物理上限（游戏里自车不可能瞬移）
    ///   · 光流幅值过大（通常是画面剧烈变化/转场，不是真实运动）
    let confidence: Double

    /// 是否可用于拦截判断。置信度低于阈值时为 false。
    let isUsable: Bool
}

// MARK: - 校验结论

/// 对单个跟踪目标的「自车运动可解释性」判定。
///
/// 语义：**这个框的位移，有多少能被自车自身运动解释掉？**
///   · `canBeExplainedByEgo = true` → 观测位移与自车运动预测的位移一致，
///     说明「目标很可能其实没动，是我们在动」→ 不应据此外推
///   · `canBeExplainedByEgo = false` → 观测位移显著超出（或不同于）自车运动
///     所能解释的部分 → 目标确实在自己动 → 照常外推
struct EgoVerdict: Equatable {

    /// 观测位移（归一化坐标 / 帧）
    let observedStep: (Double, Double)

    /// 自车运动预测的位移（归一化坐标 / 帧）
    let egoStep: (Double, Double)

    /// 残差 = 观测 − 自车预测（归一化坐标 / 帧）
    let residual: (Double, Double)

    /// 残差模长占观测模长的比例 [0, +∞)。
    ///   ≈0 → 观测完全由自车运动解释（目标静止）
    ///   ≥1 → 观测远超自车运动（目标自己在动）
    let residualRatio: Double

    /// 最终判定：是否应**阻断外推**（降级为只做位置平滑）
    let blocksPrediction: Bool

    /// 判定依据（诊断用，写日志）
    let reason: String

    // 元组不自动 Equatable，手写
    static func == (l: EgoVerdict, r: EgoVerdict) -> Bool {
        l.observedStep == r.observedStep
            && l.egoStep == r.egoStep
            && l.residual == r.residual
            && l.residualRatio == r.residualRatio
            && l.blocksPrediction == r.blocksPrediction
            && l.reason == r.reason
    }
}

// MARK: - 模型

/// 自车运动径向模型。
///
/// 无状态（纯函数式）：所有输入都从参数进来，不持有跨帧状态。
/// 这样它可以在任意线程调用，也不需要在 `reset()` 里清理。
final class EgoMotionModel {

    // MARK: 参数（全部可通过 AURORA_EGO_* 覆盖）

    /// ⚠️ 刻意**不用** `static let env` 缓存环境变量字典。
    ///
    /// 【为什么】初版写的是 `private static let env = ProcessInfo.processInfo.environment`，
    ///   结果 `AURORA_EGO_CHECK=off` 在 `--motion-selftest` 的 ④-8 项验证里**不生效**
    ///   （static let 只在首次访问时初始化一次，之后再 setenv 读到的还是旧值）。
    ///   这会直接破坏「每项优化都必须可一键回退并可验证」的纪律 —— 开关存在但
    ///   验不了，等于没有。
    ///
    /// 【为什么改成每次 init 读一次不影响性能】本类的实例由 `MotionPredictor`
    ///   持有（`private let egoModel = EgoMotionModel()`），**全程只创建一次**，
    ///   故 init 里读环境变量 = 全生命周期读一次，与"缓存"等价。
    ///   这与阶段0修掉的"每帧现读 17µs"是完全不同的场景 ——
    ///   那是热路径每帧读，这里是一次性初始化读。
    ///
    /// 【与 `PerfBus.enabled` 等 `static var` 的差异】那些是"进程级单例配置"，
    ///   本类不是单例（可被测试创建多个实例），故配置应绑在实例上。

    /// 画面中心 x（消失点）。非等比拉伸不改变中心，故恒为半宽。
    let centerX: Double = 320.0

    /// 画面中心 y（消失点）。
    let centerY: Double = 320.0

    /// 光流工作分辨率（与 OpticalFlowBridge.workingSize 一致）。
    let workingSize: Double = 640.0

    /// 前向率上限。超过即认为光流输出不可信（转场/整屏变化）。
    ///
    /// 量级依据：自车 30m/s（108km/h）+ 相机焦距 ~640px + 常见目标深度
    /// 20~200m → 单帧（1/30s）扩张率量级 10^-3~10^-2。
    /// 取 0.5 作为"这绝不可能是真实车辆运动"的粗筛上限，**只用于剔除明显异常**，
    /// 不做精细判据（精细判据交给置信度与残差比）。
    let maxForwardRate: Double

    /// 光流位移模长上限（像素）。超过即认为画面发生剧烈变化而非真实运动。
    let maxFlowPixels: Double

    /// 残差比阈值：`residualRatio` 低于此值 → 判为"自车运动可解释" → 拦截外推。
    ///
    /// 语义：观测位移里 ≥(1−threshold) 的部分都能被自车运动解释掉。
    /// 默认 0.6 = 残差不到观测的 60%，即自车运动解释了 40% 以上。
    /// ⚠️ 这是**可调初值**：太松会误拦真实运动目标，太紧抓不住"目标静止"。
    ///    真机标定时按实测调整。
    let residualRatioThreshold: Double

    /// 判定所需的最低置信度。低于此值一律不拦截（fail-open）。
    let minConfidence: Double

    /// 总开关（`AURORA_EGO_CHECK=off` → 关闭，行为与接线前一致）。
    let enabled: Bool

    init() {
        // ★ 每次 init 读一次（不是 static 缓存）—— 见上方注释：
        //   本类可被测试多次实例化，且开关必须能在运行时验证可回退。
        //   生产路径只有一个实例（MotionPredictor 持有），故无额外开销。
        let e = ProcessInfo.processInfo.environment
        maxForwardRate = e["AURORA_EGO_MAX_FWD"].flatMap(Double.init) ?? 0.5
        maxFlowPixels = e["AURORA_EGO_MAX_FLOW_PX"].flatMap(Double.init) ?? 80.0
        residualRatioThreshold = e["AURORA_EGO_RESIDUAL_RATIO"].flatMap(Double.init) ?? 0.6
        minConfidence = e["AURORA_EGO_MIN_CONF"].flatMap(Double.init) ?? 0.35
        enabled = e["AURORA_EGO_CHECK"] != "off"
    }

    // MARK: 估计

    /// 从一帧光流读数估计自车运动。
    ///
    /// - Parameters:
    ///   - flow: 光流读数（`dx`/`dy` 为 640 图像素，`divergence` 为外向散度）
    ///   - dt: 本帧间隔（秒）
    /// - Returns: 估计值；**数据不可用或不可信时返回 nil**（上层必须 fail-open）
    func estimate(from flow: OpticalFlowReading, dt: Double) -> EgoMotionEstimate? {
        guard enabled else { return nil }

        // ① dt 必须合理：≤0 或 >0.5s（15 帧以上间隔）说明时序异常
        guard dt > 0, dt <= 0.5 else { return nil }

        // ② 光流幅值粗筛：过大通常是转场/整屏闪烁，不是真实运动
        guard flow.magnitude <= maxFlowPixels else { return nil }

        // ③ 前向率来自 divergence（径向扩张量）
        //
        //    为什么直接用它：C 层 `ad_dis_compute` 的散度就是「3×3 分块平均流
        //    的径向外向分量」（见 flow_bridge.cpp 注释），语义与我们要的
        //    "视野扩张比例"完全一致，量纲也是像素。
        //    换算成无量纲比例需除以"典型半径"——这里用工作分辨率的半宽
        //    作为特征尺度（中心到边缘的距离）。
        let featureRadius = workingSize / 2.0
        let forwardRate = flow.divergence / featureRadius

        // ④ 横向率来自全局中位水平流，换算成归一化坐标 / 秒
        //    正 dx = 画面内容向右移动 = 自车向左移动
        let lateralRatePerFrame = flow.dx / workingSize
        let lateralRate = lateralRatePerFrame / dt

        // ⑤ 置信度：三个因子相乘（任一异常都会拉低）
        var conf = 1.0

        // 5a 前向率越界 → 强降置信（不是直接丢弃，因为可能是标定偏差）
        if abs(forwardRate) > maxForwardRate { conf *= 0.2 }

        // 5b 横向率越界（归一化/秒，正常车辆横向远小于 2.0/秒）
        if abs(lateralRate) > 2.0 { conf *= 0.3 }

        // 5c dt 偏离典型值 → 降置信（帧率抖动会让换算不准）
        let typicalDt = 1.0 / 30.0
        let dtDeviation = abs(dt - typicalDt) / typicalDt
        if dtDeviation > 0.5 { conf *= 0.5 }

        conf = max(0, min(1, conf))

        return EgoMotionEstimate(forwardRate: forwardRate,
                                 lateralRate: lateralRate,
                                 dt: dt,
                                 confidence: conf,
                                 isUsable: conf >= minConfidence)
    }

    // MARK: 位移场预测

    /// 预测「纯自车运动」会让**某个框**在画面上产生多大位移。
    ///
    /// 径向模型：位移正比于该点相对消失点的半径向量。
    /// 框用中心点代表（框内各点位移不同，这正是径向模型的含义；
    /// 用中心点是与 α-β 滤波"以框中心为状态量"一致的近似）。
    ///
    /// - Returns: (du, dv) 归一化坐标 / 帧
    func predictedImageShift(for box: Detection, ego: EgoMotionEstimate) -> (Double, Double) {
        // 归一化中心 → 像素坐标
        let px = box.x * workingSize
        let py = box.y * workingSize

        // 相对消失点的半径
        let rx = px - centerX
        let ry = py - centerY

        // 径向扩张：位移 = forwardRate · r
        // （forwardRate 是"每帧"比例，因为 divergence 就是两帧之间的量）
        let duPx = ego.forwardRate * rx
        let dvPx = ego.forwardRate * ry

        // 横向平移叠加（自车横移对全画面是均匀平移）
        let duLateralPx = ego.lateralRate * ego.dt * workingSize

        // 像素 → 归一化
        return ((duPx + duLateralPx) / workingSize, dvPx / workingSize)
    }

    // MARK: 校验

    /// 判定一个跟踪目标的观测位移能否被自车运动解释。
    ///
    /// - Parameters:
    ///   - box: 当前框（校验发生时的位置）
    ///   - observedVelocity: α-β 滤波估计的速度（归一化坐标 / 秒）
    ///   - ego: 自车运动估计
    /// - Returns: 判定结果；`ego` 不可用时返回 nil（上层 fail-open）
    func verdict(for box: Detection,
                 observedVelocity: (Double, Double),
                 ego: EgoMotionEstimate) -> EgoVerdict? {
        guard enabled, ego.isUsable else { return nil }

        // 观测位移（本帧）
        let obsStep = (observedVelocity.0 * ego.dt, observedVelocity.1 * ego.dt)

        // 自车运动预测位移（本帧）
        let egoStep = predictedImageShift(for: box, ego: ego)

        // 残差
        let resX = obsStep.0 - egoStep.0
        let resY = obsStep.1 - egoStep.1

        let obsMag = (obsStep.0 * obsStep.0 + obsStep.1 * obsStep.1).squareRoot()
        let resMag = (resX * resX + resY * resY).squareRoot()

        // ⚠️ 观测位移极小时不做判定：
        //   分母趋 0 会让比例爆炸，且"目标几乎没动"本身就该按静止处理 ——
        //   但那是**框差分**的职责，不是本模型的职责。这里返回 nil 表示
        //   "本模型对这种情况没有意见"，避免用噪声做出拦截决定。
        let minObsMag = 0.0005   // ≈640 图上 0.32 像素/帧
        guard obsMag >= minObsMag else { return nil }

        let ratio = resMag / obsMag

        // 判定：残差占总位移的比例低于阈值 → 自车运动解释了大部分 → 拦截
        let blocks = ratio < residualRatioThreshold

        let reason = String(format: "观测%.4f 自车%.4f 残差比%.2f → %@",
                            obsMag, (egoStep.0 * egoStep.0 + egoStep.1 * egoStep.1).squareRoot(),
                            ratio, blocks ? "自车可解释(不预测)" : "目标自身运动(照常预测)")

        return EgoVerdict(observedStep: obsStep,
                          egoStep: egoStep,
                          residual: (resX, resY),
                          residualRatio: ratio,
                          blocksPrediction: blocks,
                          reason: reason)
    }
}
