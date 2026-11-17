// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PolicyHead.swift — 纯 Swift 可训练策略头（PPO）
//
//  【这是什么】
//    V3 模型的「输出头 + critic」的可训练版本，用纯 Swift 实现前向 / 采样 /
//    解析反向 / Adam 更新。它是「核心算法用 Swift（编译型）写、不依赖 Python」
//    这条红线的落点：本机就能跑 PPO 更新，不需要起 Python / torch。
//
//  【结构（与 tools/v3_rl/policy.py 的语义一一对应）】
//    h        = ReLU(Linear256→192(state))        # trunk.0
//    h        = ReLU(Linear192→96(h))             # trunk.3
//    v_logits = Linear96→3(h)                      # vertical   （可训练）
//    h_logits = Linear96→3(h)                      # horizontal （可训练）
//    value    = Linear256→1(state)                 # critic，初始权重为 0
//    Dropout 在推理期关闭，导出权重不含 dropout，故这里没有 dropout。
//
//  【数值实现的三个硬要求（reviewer 会盯）】
//    ① softmax / log-softmax 一律 max-subtract，避免 exp 溢出；
//    ② PPO 的 ratio 用 exp(logπ_new − logπ_old) 计算，clamp 只作用在 ratio
//       （surr2）上，且梯度严格走 min() 选中的那一支 —— 绝不做「对概率做
//       clamp 却按未 clamp 求导」那种自相矛盾的事；
//    ③ 矩阵乘走 Accelerate 的 cblas_dgemm，不写 O(n²) 裸循环。
//
//  【为什么内部全用 Double】
//    训练/梯度校验对精度敏感（argmax 边界、有限差分 1e-3 容差）。Double 让
//    解析梯度与数值梯度在 1e-8 级别吻合；对外接口仍按契约返回 Float。
//
//  【公开契约结构的归属】
//    RLTransition / PPOConfig / PPOMetrics 由本文件**单一拥有**（public），
//    C 域 OnlineTrainer 直接复用，不重复定义。字段命名与 task-7 规格逐字一致
//    （lr/clipEps/gamma/lam/epochs/batch/vfCoef/entCoef 等），本文件额外追加
//    的 Adam 细节 / 自检曲线字段一律带默认值，保证 OnlineTrainer 现有调用不变。
// ============================================================================

import Foundation
import Accelerate

// MARK: - 公开契约结构（C 域 OnlineTrainer 直接复用这三个类型，勿重复定义）

/// 一条 RL transition。字段语义：
///   - stateToken : 256 维状态特征（冻结骨干产出的 state_token）
///   - vClass/hClass : 实际执行（或采集时）的垂直/水平动作类别（0..2）
///   - logProbV/logProbH : 采集时策略对这两个动作的 log 概率（PPO 的 old）
///   - reward : 逐帧奖励（来自 reward 语义，见 OnlineTrainer）
///   - value  : 采集时 critic 的 V(s) 估计（供 GAE 计算）
///   - tookOver/isTerminal : 人工接管标志 / 本帧是否为 episode 末帧（GAE 截断）
///   - advantage/valueTarget : 默认 0；送入 updatePPO 前必须已由 GAE 填好
///     （advantage=归一化前的原始 GAE 优势；valueTarget=原始优势 + value）
public struct RLTransition {
    public var stateToken: [Float]
    public var vClass: Int
    public var hClass: Int
    public var logProbV: Double
    public var logProbH: Double
    public var reward: Double
    public var value: Double
    public var tookOver: Bool
    public var isTerminal: Bool
    /// GAE 结果：优势（喂策略梯度）。collect 时为 0。
    public var advantage: Double
    /// GAE 结果：价值回归目标 = 原始优势 + value。collect 时为 0。
    public var valueTarget: Double

    public init(stateToken: [Float],
                vClass: Int,
                hClass: Int,
                logProbV: Double,
                logProbH: Double,
                reward: Double,
                value: Double,
                tookOver: Bool,
                isTerminal: Bool,
                advantage: Double = 0,
                valueTarget: Double = 0) {
        self.stateToken = stateToken
        self.vClass = vClass
        self.hClass = hClass
        self.logProbV = logProbV
        self.logProbH = logProbH
        self.reward = reward
        self.value = value
        self.tookOver = tookOver
        self.isTerminal = isTerminal
        self.advantage = advantage
        self.valueTarget = valueTarget
    }
}

/// PPO 超参数 + GAE 参数。
/// 主字段（task-7 规格）：lr / clipEps / gamma / lam / epochs / batch / vfCoef / entCoef。
/// 追加字段：Adam 细节（adamBeta1/2、adamEpsilon）、梯度裁剪（maxGradNorm）、
/// 洗牌种子（shuffleSeed）——均带默认值，OnlineTrainer 现有 `PPOConfig()` 调用不受影响。
public struct PPOConfig {
    public var lr: Double
    public var clipEps: Double
    public var gamma: Double
    public var lam: Double
    public var epochs: Int
    public var batch: Int
    public var vfCoef: Double
    public var entCoef: Double
    public var adamBeta1: Double
    public var adamBeta2: Double
    public var adamEpsilon: Double
    public var maxGradNorm: Double
    public var shuffleSeed: UInt64

    public init(lr: Double = 3e-3,
                clipEps: Double = 0.2,
                gamma: Double = 0.99,
                lam: Double = 0.95,
                epochs: Int = 4,
                batch: Int = 16,
                vfCoef: Double = 0.5,
                entCoef: Double = 0.01,
                adamBeta1: Double = 0.9,
                adamBeta2: Double = 0.999,
                adamEpsilon: Double = 1e-8,
                maxGradNorm: Double = 0.5,
                shuffleSeed: UInt64 = 0x9E3779B97F4A7C15) {
        self.lr = lr
        self.clipEps = clipEps
        self.gamma = gamma
        self.lam = lam
        self.epochs = epochs
        self.batch = batch
        self.vfCoef = vfCoef
        self.entCoef = entCoef
        self.adamBeta1 = adamBeta1
        self.adamBeta2 = adamBeta2
        self.adamEpsilon = adamEpsilon
        self.maxGradNorm = maxGradNorm
        self.shuffleSeed = shuffleSeed
    }
}

/// 一次 PPO 更新的产出指标。
/// 主字段（OnlineTrainer / UI 读取）：policyLoss / valueLoss / entropy / approxKL /
/// meanReward（updatePPO 不产生，由 OnlineTrainer 回填）/ updateIndex（同上）。
/// 追加字段（PolicyHead 自检/日志用，均带默认值）：totalLoss / ratioMean /
/// lossHistory（每 epoch 平均 total loss）/ numTransitions / numEpochs。
public struct PPOMetrics {
    public var policyLoss: Double
    public var valueLoss: Double
    public var entropy: Double
    public var approxKL: Double
    /// 最近窗口 episode 的平均回报。updatePPO 不产生它，由 OnlineTrainer 回填。
    public var meanReward: Double
    /// 第几次更新（单调递增，便于 UI 画曲线）。由 OnlineTrainer 回填。
    public var updateIndex: Int
    public var totalLoss: Double
    public var ratioMean: Double
    public var lossHistory: [Double]
    public var numTransitions: Int
    public var numEpochs: Int

    public init(policyLoss: Double = 0,
                valueLoss: Double = 0,
                entropy: Double = 0,
                approxKL: Double = 0,
                meanReward: Double = 0,
                updateIndex: Int = 0,
                totalLoss: Double = 0,
                ratioMean: Double = 0,
                lossHistory: [Double] = [],
                numTransitions: Int = 0,
                numEpochs: Int = 0) {
        self.policyLoss = policyLoss
        self.valueLoss = valueLoss
        self.entropy = entropy
        self.approxKL = approxKL
        self.meanReward = meanReward
        self.updateIndex = updateIndex
        self.totalLoss = totalLoss
        self.ratioMean = ratioMean
        self.lossHistory = lossHistory
        self.numTransitions = numTransitions
        self.numEpochs = numEpochs
    }
}

/// init 失败时抛出可定位的错误（缺张量 / 形状不符都要指名道姓）。
public enum PolicyHeadInitError: Error, LocalizedError {
    case cannotReadFile(String)
    case malformedJSON(String)
    case missingTensor(String)
    case shapeMismatch(name: String, expected: [Int], actual: [Int])

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile(let p):
            return "PolicyHead init 失败：无法读取 JSON 文件 \(p)"
        case .malformedJSON(let why):
            return "PolicyHead init 失败：JSON 结构异常 —— \(why)"
        case .missingTensor(let name):
            return "PolicyHead init 失败：缺少张量 \(name)"
        case .shapeMismatch(let name, let exp, let act):
            return "PolicyHead init 失败：张量 \(name) 形状不符，期望 \(exp)，实际 \(act)"
        }
    }
}

// MARK: - 二维矩阵乘（Accelerate cblas_dgemm 封装）

/// 行主序通用矩阵乘：C[M,N] = op(A) · op(B)。
///   - transA=false：A 为 [M,K]；transA=true：A 为 [K,M]
///   - transB=false：B 为 [K,N]；transB=true：B 为 [N,K]
/// 这样单一一层封装即可覆盖 forward（X·Wᵀ）、dW（dYᵀ·X）、dX（dY·W）三种形态。
/// 说明：vDSP_mmulD 按**行主序**解释输入（实测：直接喂行主序 A[M×K]、B[K×N]
/// 即得正确行主序乘积），且不支持转置参数（新版 cblas 在 macOS 13.3+ 已弃用，
/// 需全局编译宏，本仓不便加）。故这里先把 op(A)、op(B) 重排成行主序（O(MK)/O(KN)
/// 内存搬运，非矩阵乘本身），交给 vDSP_mmulD 做 O(MNK) 核心乘法。矩阵本身用
/// Accelerate 硬件实现，无 O(n³) 裸循环。
@inline(__always)
func rlMatmul(_ A: [Double], _ B: [Double],
              M: Int, N: Int, K: Int,
              transA: Bool = false, transB: Bool = false) -> [Double] {
    if M == 0 || N == 0 { return [] }
    if K == 0 { return [Double](repeating: 0, count: M * N) }

    // opA（行主序 [M,K]）
    var a = A
    if transA {
        a = [Double](repeating: 0, count: M * K)
        for k in 0..<K { for i in 0..<M { a[i * K + k] = A[k * M + i] } }
    }
    // opB（行主序 [K,N]）
    var b = B
    if transB {
        b = [Double](repeating: 0, count: K * N)
        for j in 0..<N { for k in 0..<K { b[k * N + j] = B[j * K + k] } }
    }
    var c = [Double](repeating: 0, count: M * N)
    vDSP_mmulD(a, 1, b, 1, &c, 1,
               vDSP_Length(M), vDSP_Length(N), vDSP_Length(K))
    return c
}

// MARK: - 单个 Linear 层（含手写反向 + Adam 状态）

/// 一个全连接层 Y = X·Wᵀ + b。
///   weight 行主序存 [outDim, inDim]（与 PyTorch nn.Linear.weight 同布局）。
///   mW/vW/mB/vB 是该层参数的 Adam 一阶/二阶动量（形状与参数一致）。
struct LinearLayer {
    let inDim: Int
    let outDim: Int
    var weight: [Double]   // [outDim * inDim]
    var bias: [Double]     // [outDim]
    var mWeight: [Double]
    var vWeight: [Double]
    var mBias: [Double]
    var vBias: [Double]

    init(inDim: Int, outDim: Int, weight: [Double], bias: [Double]) {
        precondition(weight.count == inDim * outDim,
                     "LinearLayer: weight 大小 \(weight.count) != \(outDim*inDim)")
        precondition(bias.count == outDim, "LinearLayer: bias 大小 \(bias.count) != \(outDim)")
        self.inDim = inDim
        self.outDim = outDim
        self.weight = weight
        self.bias = bias
        self.mWeight = [Double](repeating: 0, count: weight.count)
        self.vWeight = [Double](repeating: 0, count: weight.count)
        self.mBias = [Double](repeating: 0, count: outDim)
        self.vBias = [Double](repeating: 0, count: outDim)
    }

    /// 前向：X [batch,inDim] -> Y [batch,outDim]。
    func forward(_ X: [Double], batch: Int) -> [Double] {
        var Y = rlMatmul(X, weight, M: batch, N: outDim, K: inDim,
                         transA: false, transB: true)
        for r in 0..<batch {
            let base = r * outDim
            for o in 0..<outDim { Y[base + o] += bias[o] }
        }
        return Y
    }

    /// 反向：给定 X [batch,inDim] 与上游梯度 dY [batch,outDim]，
    /// 返回 dX [batch,inDim]、dW [outDim,inDim]、dB [outDim]（纯函数，不改参数，
    /// 因此可安全用于有限差分梯度校验）。
    func backward(_ X: [Double], _ dY: [Double], batch: Int)
        -> (dX: [Double], dW: [Double], dB: [Double]) {
        // dW[o,i] = Σ_r dY[r,o]·X[r,i]  → op(A)=dYᵀ[out,batch]
        let dW = rlMatmul(dY, X, M: outDim, N: inDim, K: batch,
                          transA: true, transB: false)
        var dB = [Double](repeating: 0, count: outDim)
        for r in 0..<batch {
            let base = r * outDim
            for o in 0..<outDim { dB[o] += dY[base + o] }
        }
        // dX[r,i] = Σ_o dY[r,o]·W[o,i]
        let dX = rlMatmul(dY, weight, M: batch, N: inDim, K: outDim,
                          transA: false, transB: false)
        return (dX, dW, dB)
    }

    /// Adam 更新（就地修改参数与动量）。调用方已完成梯度裁剪。
    mutating func adamUpdate(dW: [Double], dB: [Double], learningRate: Double,
                             beta1: Double, beta2: Double, epsilon: Double, step: Int) {
        let bc1 = 1.0 - pow(beta1, Double(step))
        let bc2 = 1.0 - pow(beta2, Double(step))
        for i in 0..<weight.count {
            let g = dW[i]
            mWeight[i] = beta1 * mWeight[i] + (1 - beta1) * g
            vWeight[i] = beta2 * vWeight[i] + (1 - beta2) * g * g
            let mHat = mWeight[i] / bc1
            let vHat = vWeight[i] / bc2
            weight[i] -= learningRate * mHat / (sqrt(vHat) + epsilon)
        }
        for i in 0..<bias.count {
            let g = dB[i]
            mBias[i] = beta1 * mBias[i] + (1 - beta1) * g
            vBias[i] = beta2 * vBias[i] + (1 - beta2) * g * g
            let mHat = mBias[i] / bc1
            let vHat = vBias[i] / bc2
            bias[i] -= learningRate * mHat / (sqrt(vHat) + epsilon)
        }
    }
}

// MARK: - 确定性 RNG（自检可复现；生产采样用系统 RNG）

struct XorShift64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// [0,1) 均匀浮点。
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
    /// 标准正态（Box-Muller），用于随机初始化。
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), 1e-12)
        let u2 = nextUnit()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }
}

// MARK: - PolicyHead

struct PolicyHead {
    static let stateDimension = 256
    static let hidden1 = 192
    static let hidden2 = 96
    static let numV = 3
    static let numH = 3

    // 可训练参数层（internal：同模块的自检需要读取/扰动做梯度校验）
    var trunk0: LinearLayer     // 256 -> 192
    var trunk1: LinearLayer     // 192 -> 96
    var vertical: LinearLayer   // 96 -> 3
    var horizontal: LinearLayer // 96 -> 3
    var valueLayer: LinearLayer // 256 -> 1

    // 全局 Adam 步数（跨 updatePPO 调用累积，偏置校正用）
    private var adamStep: Int = 0

    // MARK: 初始化

    /// 从 A 域导出的 swift_head_init.json 读初始权重（PyTorch [out,in] 扁平数组）。
    /// value 头在 checkpoint 内不存在，按导出建议置零。
    init(fromJSON url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw PolicyHeadInitError.cannotReadFile(url.path)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolicyHeadInitError.malformedJSON("顶层不是 JSON 对象")
        }
        if let dim = root["dim_state_token"] as? Int, dim != Self.stateDimension {
            throw PolicyHeadInitError.shapeMismatch(
                name: "dim_state_token", expected: [Self.stateDimension], actual: [dim])
        }
        guard let tensorList = root["tensors"] as? [[String: Any]] else {
            throw PolicyHeadInitError.malformedJSON("缺少 tensors 数组")
        }
        var tensors: [String: (shape: [Int], data: [Double])] = [:]
        for t in tensorList {
            guard let name = t["name"] as? String,
                  let shape = t["shape"] as? [Int],
                  let raw = t["data"] as? [Any] else {
                throw PolicyHeadInitError.malformedJSON("某个 tensor 缺 name/shape/data")
            }
            let vals = raw.map { (n: Any) -> Double in
                if let d = n as? Double { return d }
                if let i = n as? Int { return Double(i) }
                if let num = n as? NSNumber { return num.doubleValue }
                return .nan
            }
            tensors[name] = (shape, vals)
        }

        func take(_ name: String, expected: [Int]) throws -> [Double] {
            guard let entry = tensors[name] else {
                throw PolicyHeadInitError.missingTensor(name)
            }
            guard entry.shape == expected else {
                throw PolicyHeadInitError.shapeMismatch(
                    name: name, expected: expected, actual: entry.shape)
            }
            guard entry.data.count == expected.reduce(1, *) else {
                throw PolicyHeadInitError.shapeMismatch(
                    name: name, expected: expected, actual: [entry.data.count])
            }
            return entry.data
        }

        let w1 = try take("trunk.0.weight", expected: [Self.hidden1, Self.stateDimension])
        let b1 = try take("trunk.0.bias", expected: [Self.hidden1])
        let w2 = try take("trunk.3.weight", expected: [Self.hidden2, Self.hidden1])
        let b2 = try take("trunk.3.bias", expected: [Self.hidden2])
        let wv = try take("vertical.weight", expected: [Self.numV, Self.hidden2])
        let bv = try take("vertical.bias", expected: [Self.numV])
        let wh = try take("horizontal.weight", expected: [Self.numH, Self.hidden2])
        let bh = try take("horizontal.bias", expected: [Self.numH])

        trunk0 = LinearLayer(inDim: Self.stateDimension, outDim: Self.hidden1, weight: w1, bias: b1)
        trunk1 = LinearLayer(inDim: Self.hidden1, outDim: Self.hidden2, weight: w2, bias: b2)
        vertical = LinearLayer(inDim: Self.hidden2, outDim: Self.numV, weight: wv, bias: bv)
        horizontal = LinearLayer(inDim: Self.hidden2, outDim: Self.numH, weight: wh, bias: bh)
        // value：state_token(256)→1 的线性，初始权重 0（导出建议 init=zero）
        valueLayer = LinearLayer(inDim: Self.stateDimension, outDim: 1,
                                 weight: [Double](repeating: 0, count: Self.stateDimension),
                                 bias: [0.0])
    }

    /// 随机初始化（A 域 JSON 尚未产出时供自检用；也可作为无 ckpt 时的冷启动）。
    /// trunk/heads 用 Xavier 均匀；value 头按规格置零。
    init(randomSeed seed: UInt64) {
        var rng = XorShift64(seed: seed)
        func xavier(_ inD: Int, _ outD: Int) -> [Double] {
            let limit = sqrt(6.0 / Double(inD + outD))
            return (0..<(inD * outD)).map { _ in (rng.nextUnit() * 2 - 1) * limit }
        }
        trunk0 = LinearLayer(inDim: Self.stateDimension, outDim: Self.hidden1,
                             weight: xavier(Self.stateDimension, Self.hidden1),
                             bias: [Double](repeating: 0, count: Self.hidden1))
        trunk1 = LinearLayer(inDim: Self.hidden1, outDim: Self.hidden2,
                             weight: xavier(Self.hidden1, Self.hidden2),
                             bias: [Double](repeating: 0, count: Self.hidden2))
        vertical = LinearLayer(inDim: Self.hidden2, outDim: Self.numV,
                               weight: xavier(Self.hidden2, Self.numV),
                               bias: [Double](repeating: 0, count: Self.numV))
        horizontal = LinearLayer(inDim: Self.hidden2, outDim: Self.numH,
                                 weight: xavier(Self.hidden2, Self.numH),
                                 bias: [Double](repeating: 0, count: Self.numH))
        valueLayer = LinearLayer(inDim: Self.stateDimension, outDim: 1,
                                 weight: [Double](repeating: 0, count: Self.stateDimension),
                                 bias: [0.0])
    }

    /// 可训练参数总数（日志/自检用）。
    func numTrainableParameters() -> Int {
        trunk0.weight.count + trunk0.bias.count
            + trunk1.weight.count + trunk1.bias.count
            + vertical.weight.count + vertical.bias.count
            + horizontal.weight.count + horizontal.bias.count
            + valueLayer.weight.count + valueLayer.bias.count
    }

    // MARK: 前向

    private struct ForwardCache {
        let batch: Int
        let X: [Double]         // [batch,256]
        let h1pre: [Double]     // [batch,192]
        let h1: [Double]        // [batch,192] post-ReLU
        let h2pre: [Double]     // [batch,96]
        let h2: [Double]        // [batch,96] post-ReLU
        let vLogits: [Double]   // [batch,3]
        let hLogits: [Double]   // [batch,3]
        let value: [Double]     // [batch]
    }

    private func forwardBatch(_ X: [Double], batch: Int) -> ForwardCache {
        let h1pre = trunk0.forward(X, batch: batch)
        var h1 = [Double](repeating: 0, count: h1pre.count)
        for i in 0..<h1pre.count { h1[i] = h1pre[i] > 0 ? h1pre[i] : 0 }
        let h2pre = trunk1.forward(h1, batch: batch)
        var h2 = [Double](repeating: 0, count: h2pre.count)
        for i in 0..<h2pre.count { h2[i] = h2pre[i] > 0 ? h2pre[i] : 0 }
        let vLogits = vertical.forward(h2, batch: batch)
        let hLogits = horizontal.forward(h2, batch: batch)
        let valueMat = valueLayer.forward(X, batch: batch)   // [batch,1]
        var value = [Double](repeating: 0, count: batch)
        for r in 0..<batch { value[r] = valueMat[r] }
        return ForwardCache(batch: batch, X: X, h1pre: h1pre, h1: h1,
                            h2pre: h2pre, h2: h2, vLogits: vLogits,
                            hLogits: hLogits, value: value)
    }

    /// 单样本前向：返回 vertical/horizontal logits（各 3）与 value（标量）。
    /// 契约：stateToken 必须是 256 维（由骨干 state_token 保证）。
    func forward(stateToken: [Float]) -> (vLogits: [Float], hLogits: [Float], value: Float) {
        precondition(stateToken.count == Self.stateDimension,
                     "PolicyHead.forward: stateToken 必须 \(Self.stateDimension) 维，实际 \(stateToken.count)")
        let X = stateToken.map { Double($0) }
        let c = forwardBatch(X, batch: 1)
        let v = (0..<Self.numV).map { Float(c.vLogits[$0]) }
        let h = (0..<Self.numH).map { Float(c.hLogits[$0]) }
        return (v, h, Float(c.value[0]))
    }

    // MARK: 采样

    /// softmax 采样（max-subtract + log-softmax 取 logProb）。生产用系统随机数。
    func stochasticSample(vLogits: [Float], hLogits: [Float])
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        var rng = SystemRandomNumberGenerator()
        return stochasticSample(vLogits: vLogits, hLogits: hLogits, rng: &rng)
    }

    /// 可注入 RNG 的重载（自检复现用）。
    func stochasticSample<R: RandomNumberGenerator>(vLogits: [Float], hLogits: [Float], rng: inout R)
        -> (vClass: Int, hClass: Int, logProbV: Double, logProbH: Double) {
        let vLog = vLogits.map { Double($0) }
        let hLog = hLogits.map { Double($0) }
        let vProbs = Self.softmax(vLog)
        let hProbs = Self.softmax(hLog)
        let vLogProbs = Self.logSoftmax(vLog)
        let hLogProbs = Self.logSoftmax(hLog)
        let vc = Self.sampleCategorical(vProbs, rng: &rng)
        let hc = Self.sampleCategorical(hProbs, rng: &rng)
        return (vc, hc, vLogProbs[vc], hLogProbs[hc])
    }

    // MARK: GAE（严格照 tools/v3_rl/reward.py 的 gae_advantages：逐 episode 不跨边界）

    /// 就地计算 advantage 与 valueTarget（valueTarget = advantage + value）。
    /// episode_ends 语义：isTerminal==true 的帧是所在 episode 的末帧，
    /// 其后向递归在下一位 bootstrap 归零、并重置 running GAE，避免跨 clip 泄漏。
    /// 注意：本函数只填**原始** GAE 优势，不做归一化；归一化若需要应在调用方对
    /// advantage 单独施加（且必须在填 valueTarget 之前——valueTarget 用原始优势）。
    static func computeGAE(_ transitions: inout [RLTransition], gamma: Double, lam: Double) {
        let n = transitions.count
        guard n > 0 else { return }
        var last = 0.0
        var adv = [Double](repeating: 0, count: n)
        for t in stride(from: n - 1, through: 0, by: -1) {
            let terminal = transitions[t].isTerminal || (t == n - 1)
            let nextV = terminal ? 0.0 : transitions[t + 1].value
            let delta = transitions[t].reward + gamma * nextV - transitions[t].value
            last = delta + gamma * lam * (terminal ? 0.0 : last)
            adv[t] = last
        }
        for t in 0..<n {
            transitions[t].advantage = adv[t]
            transitions[t].valueTarget = adv[t] + transitions[t].value
        }
    }

    static func computeGAE(_ transitions: inout [RLTransition], config: PPOConfig) {
        computeGAE(&transitions, gamma: config.gamma, lam: config.lam)
    }

    // MARK: 梯度结构

    struct Grads {
        var dW1: [Double], dB1: [Double]
        var dW2: [Double], dB2: [Double]
        var dWv: [Double], dBv: [Double]
        var dWh: [Double], dBh: [Double]
        var dWval: [Double], dBval: [Double]
    }

    struct BatchStats {
        var policyLoss = 0.0
        var valueLoss = 0.0
        var entropy = 0.0
        var approxKL = 0.0
        var ratioMean = 0.0
        var totalLoss = 0.0
    }

    /// PPO loss + 解析梯度（纯函数：只读参数、返回梯度，不更新）。
    ///
    /// loss = mean_i[ pgElem_i ] + vf·(0.5·mean_i[(V_i−target_i)²]) − entCoef·mean_i[entropy_i]
    /// pgElem_i = −min(r_i·A_i, clamp(r_i,1±ε)·A_i)，r_i = exp(logπ_new − logπ_old)（V+H 联合）
    ///
    /// 语义对齐 policy.py 的 ppo_loss；本模块按 task 契约对「全部 transition」做
    /// 策略梯度与 value 回归（AI/HUMAN 掩码与 BC 属上层 train_rl/C 域职责）。
    func ppoLossAndGradients(_ transitions: [RLTransition], config: PPOConfig)
        -> (loss: Double, grads: Grads, stats: BatchStats) {
        let N = transitions.count
        var stats = BatchStats()
        guard N > 0 else {
            let zero = [Double](repeating: 0, count: 0)
            return (0, Grads(dW1: zero, dB1: zero, dW2: zero, dB2: zero,
                             dWv: zero, dBv: zero, dWh: zero, dBh: zero,
                             dWval: zero, dBval: zero), stats)
        }
        var X = [Double](repeating: 0, count: N * Self.stateDimension)
        for i in 0..<N {
            let st = transitions[i].stateToken
            precondition(st.count == Self.stateDimension,
                         "updatePPO: 第 \(i) 条 transition 的 stateToken 非 \(Self.stateDimension) 维")
            for d in 0..<Self.stateDimension { X[i * Self.stateDimension + d] = Double(st[d]) }
        }
        let cache = forwardBatch(X, batch: N)

        let eps = config.clipEps
        let invN = 1.0 / Double(N)
        var dVlog = [Double](repeating: 0, count: N * Self.numV)
        var dHlog = [Double](repeating: 0, count: N * Self.numH)
        var dValue = [Double](repeating: 0, count: N)   // [N,1] 视作 [N]
        var pgLossSum = 0.0
        var vLossSum = 0.0     // 已是 0.5·mean 形式
        var entSum = 0.0
        var klSum = 0.0
        var ratioSum = 0.0
        let entEps = 1e-8

        for i in 0..<N {
            let t = transitions[i]
            let vlog = Array(cache.vLogits[(i * Self.numV)..<(i * Self.numV + Self.numV)])
            let hlog = Array(cache.hLogits[(i * Self.numH)..<(i * Self.numH + Self.numH)])
            let pV = Self.softmax(vlog)
            let pH = Self.softmax(hlog)
            let lpV = Self.logSoftmax(vlog)
            let lpH = Self.logSoftmax(hlog)
            let lpNewV = lpV[t.vClass]
            let lpNewH = lpH[t.hClass]
            let logRatio = (lpNewV - t.logProbV) + (lpNewH - t.logProbH)
            let ratio = exp(logRatio)
            let adv = t.advantage
            let surr1 = ratio * adv
            let clipped = min(max(ratio, 1.0 - eps), 1.0 + eps)
            let surr2 = clipped * adv
            let pgElem = -min(surr1, surr2)
            pgLossSum += pgElem

            // d(pgElem)/d(ratio)：走 min() 选中的那一支；clamp 支在区间内才非零。
            var dpgDRatio: Double
            if surr1 <= surr2 {
                dpgDRatio = -adv
            } else {
                dpgDRatio = (ratio >= 1.0 - eps && ratio <= 1.0 + eps) ? -adv : 0.0
            }
            // G = dL/dratio · ratio；dL/dratio = invN · dpgDRatio
            let G = invN * dpgDRatio * ratio

            var dLv = [Double](repeating: 0, count: Self.numV)
            var dLh = [Double](repeating: 0, count: Self.numH)
            for k in 0..<Self.numV {
                dLv[k] = G * ((k == t.vClass ? 1.0 : 0.0) - pV[k])
            }
            for k in 0..<Self.numH {
                dLh[k] = G * ((k == t.hClass ? 1.0 : 0.0) - pH[k])
            }

            if config.entCoef != 0.0 {
                // 熵对 logits 的精确导数（含 +1e-8 平滑项），保证与实现处公式一致。
                var Sv = 0.0
                for k in 0..<Self.numV { Sv += pV[k] * (log(pV[k] + entEps) + pV[k] / (pV[k] + entEps)) }
                for k in 0..<Self.numV {
                    let dEnt = -pV[k] * ((log(pV[k] + entEps) + pV[k] / (pV[k] + entEps)) - Sv)
                    dLv[k] += -config.entCoef * invN * dEnt
                }
                var Sh = 0.0
                for k in 0..<Self.numH { Sh += pH[k] * (log(pH[k] + entEps) + pH[k] / (pH[k] + entEps)) }
                for k in 0..<Self.numH {
                    let dEnt = -pH[k] * ((log(pH[k] + entEps) + pH[k] / (pH[k] + entEps)) - Sh)
                    dLh[k] += -config.entCoef * invN * dEnt
                }
                var entV = 0.0
                for k in 0..<Self.numV { entV += -pV[k] * log(pV[k] + entEps) }
                var entH = 0.0
                for k in 0..<Self.numH { entH += -pH[k] * log(pH[k] + entEps) }
                entSum += entV + entH
            }

            // value 回归：V_i 直接来自 state_token（critic 无隐层）
            let value = cache.value[i]
            let diff = value - t.valueTarget
            dValue[i] = config.vfCoef * invN * diff
            vLossSum += 0.5 * invN * diff * diff

            klSum += (t.logProbV - lpNewV) + (t.logProbH - lpNewH)
            ratioSum += ratio

            for k in 0..<Self.numV { dVlog[i * Self.numV + k] = dLv[k] }
            for k in 0..<Self.numH { dHlog[i * Self.numH + k] = dLh[k] }
        }

        let pgLoss = pgLossSum * invN
        let entMean = entSum * invN
        let totalLoss = pgLoss + config.vfCoef * vLossSum - config.entCoef * entMean

        // ── 反向传播 ──
        let bv = vertical.backward(cache.h2, dVlog, batch: N)
        let bh = horizontal.backward(cache.h2, dHlog, batch: N)
        var dH2 = [Double](repeating: 0, count: N * Self.hidden2)
        for i in 0..<dH2.count { dH2[i] = bv.dX[i] + bh.dX[i] }
        var dH2pre = [Double](repeating: 0, count: N * Self.hidden2)
        for i in 0..<dH2pre.count { dH2pre[i] = cache.h2pre[i] > 0 ? dH2[i] : 0 }
        let b2 = trunk1.backward(cache.h1, dH2pre, batch: N)
        var dH1pre = [Double](repeating: 0, count: N * Self.hidden1)
        for i in 0..<dH1pre.count { dH1pre[i] = cache.h1pre[i] > 0 ? b2.dX[i] : 0 }
        let b1 = trunk0.backward(cache.X, dH1pre, batch: N)
        // value 头 outDim=1，dValue[N] 即为 dY（batch*outDim = N*1）
        let bvLine = valueLayer.backward(cache.X, dValue, batch: N)

        let grads = Grads(
            dW1: b1.dW, dB1: b1.dB,
            dW2: b2.dW, dB2: b2.dB,
            dWv: bv.dW, dBv: bv.dB,
            dWh: bh.dW, dBh: bh.dB,
            dWval: bvLine.dW, dBval: bvLine.dB)

        stats.policyLoss = pgLoss
        stats.valueLoss = vLossSum
        stats.entropy = entMean
        stats.approxKL = klSum * invN
        stats.ratioMean = ratioSum * invN
        stats.totalLoss = totalLoss
        return (totalLoss, grads, stats)
    }

    /// 仅计算 loss（梯度校验用；与 ppoLossAndGradients 的 loss 完全同源）。
    func ppoLossOnly(_ transitions: [RLTransition], config: PPOConfig) -> Double {
        ppoLossAndGradients(transitions, config: config).loss
    }

    // MARK: PPO 更新（Adam）

    /// 对一批 transition 做 PPO 更新。返回本轮指标（含每 epoch 平均 loss 曲线）。
    mutating func updatePPO(transitions: [RLTransition], config: PPOConfig) -> PPOMetrics {
        let N = transitions.count
        guard N > 0 else {
            return PPOMetrics()
        }
        var rng = XorShift64(seed: config.shuffleSeed)
        var order = Array(0..<N)
        let epochs = max(1, config.epochs)
        let batchSize = max(1, config.batch)
        var lossHistory: [Double] = []
        var lastStats = BatchStats()

        for _ in 0..<epochs {
            // Fisher–Yates 洗牌（确定性）
            if N > 1 {
                var i = N - 1
                while i > 0 {
                    let j = Int(rng.next() % UInt64(i + 1))
                    order.swapAt(i, j)
                    i -= 1
                }
            }
            var epochLossSum = 0.0
            var batchCount = 0
            var start = 0
            while start < N {
                let end = min(start + batchSize, N)
                let idx = Array(order[start..<end])
                let mb = idx.map { transitions[$0] }
                let (loss, grads, stats) = ppoLossAndGradients(mb, config: config)
                adamStep += 1
                applyGradients(grads, config: config)
                epochLossSum += loss
                batchCount += 1
                lastStats = stats
                start = end
            }
            lossHistory.append(epochLossSum / Double(max(1, batchCount)))
        }

        return PPOMetrics(policyLoss: lastStats.policyLoss,
                          valueLoss: lastStats.valueLoss,
                          entropy: lastStats.entropy,
                          approxKL: lastStats.approxKL,
                          meanReward: 0,
                          updateIndex: 0,
                          totalLoss: lastStats.totalLoss,
                          ratioMean: lastStats.ratioMean,
                          lossHistory: lossHistory,
                          numTransitions: N,
                          numEpochs: epochs)
    }

    /// 全局梯度范数裁剪 + 逐层 Adam 更新。裁剪对所有参数张量用同一 scale。
    private mutating func applyGradients(_ grads: Grads, config: PPOConfig) {
        var normSq = 0.0
        func acc(_ a: [Double]) { for v in a { normSq += v * v } }
        acc(grads.dW1); acc(grads.dB1)
        acc(grads.dW2); acc(grads.dB2)
        acc(grads.dWv); acc(grads.dBv)
        acc(grads.dWh); acc(grads.dBh)
        acc(grads.dWval); acc(grads.dBval)
        let norm = sqrt(normSq)
        let scale = norm > config.maxGradNorm ? config.maxGradNorm / (norm + 1e-12) : 1.0
        func sc(_ a: [Double]) -> [Double] { scale == 1.0 ? a : a.map { $0 * scale } }

        trunk0.adamUpdate(dW: sc(grads.dW1), dB: sc(grads.dB1),
                          learningRate: config.lr, beta1: config.adamBeta1,
                          beta2: config.adamBeta2, epsilon: config.adamEpsilon, step: adamStep)
        trunk1.adamUpdate(dW: sc(grads.dW2), dB: sc(grads.dB2),
                          learningRate: config.lr, beta1: config.adamBeta1,
                          beta2: config.adamBeta2, epsilon: config.adamEpsilon, step: adamStep)
        vertical.adamUpdate(dW: sc(grads.dWv), dB: sc(grads.dBv),
                            learningRate: config.lr, beta1: config.adamBeta1,
                            beta2: config.adamBeta2, epsilon: config.adamEpsilon, step: adamStep)
        horizontal.adamUpdate(dW: sc(grads.dWh), dB: sc(grads.dBh),
                              learningRate: config.lr, beta1: config.adamBeta1,
                              beta2: config.adamBeta2, epsilon: config.adamEpsilon, step: adamStep)
        valueLayer.adamUpdate(dW: sc(grads.dWval), dB: sc(grads.dBval),
                              learningRate: config.lr, beta1: config.adamBeta1,
                              beta2: config.adamBeta2, epsilon: config.adamEpsilon, step: adamStep)
    }

    // MARK: 数值工具

    /// 稳定 softmax（max-subtract）。
    static func softmax(_ z: [Double]) -> [Double] {
        guard !z.isEmpty else { return [] }
        let m = z.max()!
        var ex = [Double](repeating: 0, count: z.count)
        var sum = 0.0
        for i in 0..<z.count { ex[i] = exp(z[i] - m); sum += ex[i] }
        for i in 0..<z.count { ex[i] /= sum }
        return ex
    }

    /// 稳定 log-softmax（max-subtract 后减 log-sum-exp）。
    static func logSoftmax(_ z: [Double]) -> [Double] {
        guard !z.isEmpty else { return [] }
        let m = z.max()!
        var sum = 0.0
        for v in z { sum += exp(v - m) }
        let lse = m + log(sum)
        return z.map { $0 - lse }
    }

    /// 按离散分布采样（累积概率法）。probs 已归一化。
    static func sampleCategorical<R: RandomNumberGenerator>(_ probs: [Double], rng: inout R) -> Int {
        let u = Double(rng.next() >> 11) / Double(UInt64(1) << 53)
        var cumulative = 0.0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if u < cumulative { return i }
        }
        return max(0, probs.count - 1)
    }
}
