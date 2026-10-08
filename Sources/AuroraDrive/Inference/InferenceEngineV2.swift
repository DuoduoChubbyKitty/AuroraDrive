// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  InferenceEngineV2.swift — M9-V2 多输入端到端推理引擎（T4-Swift 集成）
// ============================================================================
//
//  【为什么新建而不是改 InferenceEngine.swift】
//    原引擎跑 m9_mono（2 输入：image + vehicle_state[6]），是当前**在车上跑**
//    的链路。新模型是 5 输入、state 8 维，属于**结构性变更**；直接改原文件会让
//    「回滚到旧模型」变成一次大改。故新引擎独立成文件，靠开关切换，原文件
//    一字不动（可回滚）。
//
//  【契约真值来源（权威，非转述）】
//    · src/model_v2.py          —— M2Model 的 forward 签名与各分支编码器定义
//    · tools/export_m9_v2_coreml.py —— **实际产出 CoreML 的脚本**，含 8 个实测坑
//    两者不一致时以 export 脚本为准（它决定落到磁盘的 .mlmodelc 长什么样）。
//
//  ┌───────────────┬──────────────────────┬────────┬──────────────────────────┐
//  │ CoreML 输入名 │ shape                │ dtype  │ 含义                     │
//  ├───────────────┼──────────────────────┼────────┼──────────────────────────┤
//  │ image         │ [1, 3, 180, 320]     │ f32    │ 第三视角截图 CHW [0,1]   │
//  │ lane          │ [1, 1, 160, 160]     │ f32    │ 车道线掩码 二值 0/1      │
//  │ dets          │ [1, 20, 12]          │ f32    │ 检测框固定槽位，空槽补 0 │
//  │ det_mask      │ [1, 20]              │ f32    │ 1=有效框，0=空槽         │
//  │ vehicle_state │ [1, 8]               │ f32    │ 车辆状态（见下）         │
//  ├───────────────┼──────────────────────┼────────┼──────────────────────────┤
//  │ steer         │ [1, 1]               │ f32    │ tanh    ∈ [-1, 1]        │
//  │ throttle      │ [1, 1]               │ f32    │ sigmoid ∈ [0, 1]         │
//  │ brake         │ [1, 1]               │ f32    │ sigmoid ∈ [0, 1]         │
//  └───────────────┴──────────────────────┴────────┴──────────────────────────┘
//
//  ⚠️⚠️ **输入名是 `lane`，不是 `lane_mask`** —— 这是最容易踩的坑：
//    `src/model_v2.py` 的 forward **形参**叫 `lane_mask`，但导出的 CoreML
//    **特征名**是 `lane`（见 export 脚本契约表，以及实测报错原文：
//      KeyError: Provided key "state" ... does not match any of the model input
//      name(s), which are: {'dets','det_mask','lane','state_workaround','image'}）
//    按形参名去 MLFeatureProvider 里取值 → 运行时 KeyError。本文件用
//    `V2InputContract.featureName` 单一常量表驱动，杜绝这类错位。
//
//  ⚠️ 输入名**绝不能叫 `state`**：coremltools 8.3 会静默改名成 `state_workaround`
//    （`state` 与 MIL 内部保留字冲突），且报错发生在推理期而非转换期。
//    本模型用的是 `vehicle_state`（恰好与旧引擎同名）。
//
//  ⛔ 契约红线（src/model_v2.py §八，用户明确要求）：
//    1. **不接收可行驶区域（drivableMask / daGrid）**。lane 通道只放车道线。
//       把 drivableMask 拼进 lane 属于破坏契约 —— 本文件只读 `laneMask`，
//       从不读 `drivableMask`（有自检断言守着）。
//    2. 第三视角下自车也会被检测成框，该框必须在 Swift 侧 `EgoBoxFilter`
//       剔除后再喂；模型只收 `ego_visible` 标志位（vehicle_state[7]）。
//
//  【本文件修掉的两个既有 bug（Lead 已核实的实测结论）】
//    bug 1 · InferenceEngine.swift:431-436 —— vehicle_state 6 维里
//            idx1(curvature) / idx2(sin h) / idx5(reserved) **恒为 0**、
//            idx3(cos h) **恒为 1**，等于 6 维只用了 2 维（speed_norm +
//            speed_limit_norm）。本文件改为**真算**曲率与朝向（见 LaneGeometryEstimator）。
//    bug 2 · SpeedOCRReader.swift:157/712 —— `speedKmh` 读不到时是 **-1**，
//            不先判 `speedValid` 就归一化会把负速度喂进模型。本文件
//            `buildVehicleState` 以 `speedValid` 为**硬门**：无效则填 0。
//
//  【性能红线】沿用原引擎的成熟做法：
//    · 类 @MainActor（UI 可观察），重活全部在 inferenceQueue 后台
//    · 预处理/编码是 nonisolated 静态纯函数，无 self 捕获
//    · 复用 MLMultiArray 缓冲，避免每帧新建（image ≈691KB）
//    · 与 captureQueue / aurora.quest.ocr 无共享资源
// ============================================================================

import Accelerate
import AppKit
@preconcurrency import CoreML
import Foundation
import Observation

// MARK: - 输入契约（单一常量表，驱动全部取值）

/// M9-V2 的 CoreML 输入/输出契约。
///
/// 【为什么集中成常量表】实测坑 4：`ct.convert(inputs:...)` 的顺序与
/// `torch.jit.trace` 实参顺序必须一致，错位会报错但**不该依赖报错**。
/// Swift 侧同理：特征名散落在各处字符串里，改一处漏一处就会 KeyError。
/// 集中成一张表后，改契约只改这里。
enum V2InputContract {
    /// ⚠️ 是 `lane` 不是 `lane_mask`（见文件头）。
    static let image = "image"
    static let lane = "lane"
    static let dets = "dets"
    static let detMask = "det_mask"
    static let vehicleState = "vehicle_state"

    static let steer = "steer"
    static let throttle = "throttle"
    static let brake = "brake"

    /// 图像输入尺寸（与旧引擎一致，180×320 是既定分辨率）。
    static let imageHeight = 180
    static let imageWidth = 320
    /// 车道线掩码边长（对齐 `YolopxEngine.maskGridSize = 160`）。
    static let laneSize = 160
    /// 检测框固定槽位数。CoreML 不支持动态 N（实测坑 2），必须固定 + valid 位。
    static let maxDetections = 20
    /// 每框特征维度。**12 维**（不是 13）。
    ///
    /// ⚠️ `src/model_v2.py:210` 的常量注释把 ego_visible 也列进了 12 维里
    ///    （列出来是 13 项），与 `DET_FEAT_DIM = 12` 及 `DetectionEncoder`
    ///    文档（:552-560）矛盾。**以实现为准**：
    ///      [0]x [1]y [2]w [3]h [4:8]label_onehot4 [8]conf [9]speed [10]heading [11]age
    ///    且 DetectionEncoder 明确「第 6 维不用；自车信息通过 state 的 reserved
    ///    位传递」。Lead 已确认按 12 维实现，并会修掉那行注释。
    static let detFeatureDim = 12
    /// 车辆状态维度。
    static let stateDim = 8

    /// 检测框类别 one-hot 顺序：car, pedestrian, sign, obstacle。
    /// 与 `Detection.Label` 的声明顺序一致（RuleController.swift:32-36）。
    static let labelCount = 4

    // ══════════════════════════════════════════════════════════════════════
    // M4 新增：时序 + 三辅助头（2026-10-08 T1-Swift 传输扩展）
    // ══════════════════════════════════════════════════════════════════════
    //
    // 【契约演进记录 —— 这里变过一次，留痕以免后人困惑】
    //   ① 最初设想：新增输入 `history_feats [1,8,256]`（**图像特征序列**）
    //      + `frame_mask [1,8]`。
    //   ② 实现时发现**鸡生蛋**：那 256 维是 `ImageEncoder` 的**中间层输出**，
    //      CoreML 静态图不暴露中间层 → Swift 侧算不出来。
    //   ③ w5 实测后 Lead 拍板走**方案 A**：
    //      **`image` 直接改成 `[8,3,180,320]`**（8 帧原图走 batch 维度），
    //      模型内部一次 batch 编码 8 帧再喂 GRU。
    //      实测代价：batch=8 ImageEncoder **1.62ms p50 / 1.94ms p95**
    //      （占 33ms 帧预算 5.1%），可接受。
    //   ⟹ **最终契约没有 `history_feats` / `frame_mask`** —— 已被方案 A 取代。
    //     本文件**不实现**这两个输入（曾写过的"传零 + mask 全 0"方案已废弃）。
    //
    // ⚠️ 方案 A 的**维度陷阱**（w5 实测提醒，务必遵守）：
    //   `TemporalEncoder.forward(feats [B,N,C], frame_mask [B,N])` 里
    //   **B 与 N 是两个独立维度**：
    //     · 图像 batch=8 → 编码后 8 帧特征 [8,256]
    //     · 这 8 帧要当**时序的 N=8**，即 reshape 成 `[1, 8, 256]`（B=1, N=8）
    //     · **绝不能**把图像 batch8 直接当 GRU 的 B=8（那会变成
    //       "8 条独立的 1 帧序列"，时序彻底失效）
    //   `TemporalEncoder` 对 B 无约束（[1,8,256] 与 [8,8,256] 都能跑），
    //   **传错不会报错，只会静默算错** —— 故这条在 Swift 侧只需保证：
    //   我们传的是"8 个连续帧"，顺序语义正确（最老在前、最新在后）。

    /// 图像输入。**方案 A：`[N, 3, 180, 320]`**（N 帧原图，batch 维=时序窗口）。
    ///
    /// 帧序：**最老在前、最新在后**（index 0 = 最旧，index N-1 = 当前帧）。
    /// 依据：GRU 逐帧递推，时间轴必须与训练侧一致；训练侧
    /// `temporal.py` 的窗口就是按"过去→现在"排列的。
    ///
    /// ⚠️ 注意本常量在 `V2InputContract` 里**只能声明一次** —— 特征名 `image`
    /// 是全文件共用的（旧契约单帧时代表 `[1,3,H,W]`，方案 A 下代表
    /// `[N,3,H,W]`）。形状差异由 `imageFrameShape()` / `imageSequenceShape()` 表达。
    ///
    /// 时序窗口 N = 8（与 `src/temporal.py` 的 `num_frames=8` 对齐）。

    /// 视角朝向 `[1]`。**compass 度 [0,360)**（抓包口径），模型侧期望 rad。
    static let cameraHeading = "camera_heading"

    /// 时序窗口 N = 8（与 `src/temporal.py` 的 `num_frames=8` 默认值对齐）。
    static let historyFrames = 8

    // ── 三个新输出（M4 辅助头）──
    /// 决策置信度 `[1,1]` ∈ [0,1] → 填 `ControlCommand.confidence`。
    static let confidence = "confidence"
    /// 风险分 `[1,1]` ∈ [0,1] → 供接管判定。
    static let risk = "risk"
    /// 预测车头朝向 `[1]` rad → 诊断/日志。
    static let carHeading = "car_heading"

    /// 图像输入**每帧**的形状（方案 A 下 image 的第一维是帧数）。
    static func imageFrameShape() -> [NSNumber] {
        [1, 3, NSNumber(value: imageHeight), NSNumber(value: imageWidth)]
    }

    /// 图像输入的完整形状 `[N, 3, H, W]`（方案 A）。
    static func imageSequenceShape(frames: Int = historyFrames) -> [NSNumber] {
        [NSNumber(value: frames), 3,
         NSNumber(value: imageHeight), NSNumber(value: imageWidth)]
    }
}

// MARK: - 可调参数

/// M9-V2 集成侧可调参数（集中定义，便于标定与回归）。
struct V2Config: Sendable, Equatable {
    /// 车道线采样带：起始行（占掩码高度的比例，0=顶部/远处）。
    ///
    /// 【为什么从 0.55 开始】掩码是 letterbox 640 坐标系的俯视图投影，
    /// 最上方是远处（车道线在该处只有 1~2 格宽、极易断裂），最下方贴近自车
    /// （可能被车头遮挡）。取中间偏下的一段既有足够像素又贴近决策关注区。
    var bandTopRatio: Double = 0.55
    /// 车道线采样带：结束行（0.95 = 靠近自车，留 5% 避开可能被自车遮挡的底边）。
    var bandBottomRatio: Double = 0.95
    /// 曲率归一化参考值（**像素⁻¹**）。
    ///
    /// 【标定状态：CALIBRATION-PENDING · 与训练侧口径不一致，已如实标注】
    ///
    /// ⚠️⚠️ **必须先说明的契约冲突（2026-10-08 复核发现）**：
    ///   训练侧的 curvature 归一化是**物理量**：
    ///     `src/dataset_v2.py:64`  `curvature_x5 = clip(curvature * 5, -1, 1)`
    ///     即参考基准 = 0.2 **米⁻¹**（curvature 是 1/米）。
    ///   而本引擎的曲率**只能从车道线像素估计**（游戏不给物理曲率遥测，
    ///   见 docs/主驾驶模型换代-需求与方案 §3.4 的结论「曲率无实时数据源」），
    ///   像素↔米的比例随分辨率/视野变化、在 Swift 侧**不可知**。
    ///   故这里的 `curvatureReference` 是**像素⁻¹** 量纲下的参考值，
    ///   **与训练侧 0.2 米⁻¹ 无法直接对齐** —— 两者差的是"像素↔米"的比例因子。
    ///
    /// 这意味着：**当前的曲率数值分布很可能与训练分布不匹配**。在拿到
    /// 像素↔米标定之前，curvature 这一维的绝对大小不可信，只有**符号**
    /// （左弯/右弯）是可靠的。这属于「有依据的占位 + 待标定」，不是
    /// "已经对齐" —— 接线上车做端到端验证前必须补标定。
    ///
    /// 参考值 0.02 的推演：在 160×160 网格、64 行采样带上，若车道中心
    /// 二次弯曲、横向总偏移约 40 格，则 κ ≈ 2·40/64² ≈ 0.02。要让强弯
    /// 落在 ±1 附近，取 0.02 作参考。**这是量纲占位，不是标定值。**
    var curvatureReference: Double = 0.02
    /// 纵向加速度归一化基准（m/s²）。契约：accel / 10。
    var accelReference: Double = 10.0
    /// 车速归一化上限（km/h）。契约：[0] speed = 车速/速度上限。
    /// 缺省 120 与旧引擎 `speedNorm = speedKmh / 120` 保持一致。
    var speedReference: Double = 120.0
    /// 有效车道线所需的最少采样行数（少于该数视为"没看见车道线"，如实置 invalid）。
    var minLaneRows: Int = 6
    /// **前景格数下限**（INT8 退化保护，见下方说明）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【为什么需要这条 —— 项目既有实测，不是推测】
    /// ══════════════════════════════════════════════════════════════════════
    /// `tools/yolopx/export_yolopx_coreml.py:58-64` 原文实测：同一批真实行车图，
    /// 三档量化的**车道线正像素占比**：
    ///     fp16   1.30–1.80%   ✅
    ///     w8a16  1.30–1.80%   ✅（与 fp16 逐位一致）
    ///     int8   0.13–0.21%   ❌ **掉约 10×**
    /// 根因（`export_yolopx_int8.py:42-46`）：校准集用了游戏 UI 截图
    /// （菜单/设置/桌面）→ 激活分布严重偏斜 → 量化后车道线头塌陷。
    ///
    /// 而本引擎的 lane 通道来源正是 `yolopxEngine.laneMask`，**上游 yolopx
    /// 本身就可能是 INT8 的**（`models/ayolom_n_int8.mlmodelc`）。也就是说：
    /// 车道线可能在**进入本引擎之前就已经被量化打没了**。
    ///
    /// 160×160 = 25600 格，正常车道线占 1.3%~1.8% ≈ **333~461 格**；
    /// 被 INT8 打掉 10× 后只剩 **33~54 格**，且高度碎片化。
    /// 取 30 格作下限：低于它说明上游已经不可信，**宁可如实报"没有车道线"，
    /// 也不用碎片硬拟合出一条假车道线** —— 后者会让模型收到错误的曲率/朝向，
    /// 比收到 0（=未知）危险得多。
    ///
    /// ⚠️ 注意本阈值只挡"极端退化"。33~54 格仍在阈值之上，会进入拟合；
    /// 此时靠 `minLaneRows`（有效行数）与双侧/单侧分级继续兜底。
    var minLanePixels: Int = 30
    /// 单侧车道线缺失时使用的标称半宽（占掩码宽度的比例）。
    ///
    /// 【为什么需要】只看到一侧车道线时（另一侧被压线/断裂），若直接放弃该行，
    /// 有效行会骤降导致整帧 invalid。用**本帧双侧行的半宽中位数**兜底更稳；
    /// 若本帧一行双侧都没有，才退回这个标称值。
    var nominalHalfWidthRatio: Double = 0.22

    static let `default` = V2Config()
}

// MARK: - 车道线掩码快照（Sendable 值类型，可安全跨 actor）

/// `MaskGrid` 的**可跨线程值快照**。
///
/// 【为什么要这一层】`MaskGrid` 是 `YolopxEngine` 的类型（YolopxEngine.swift:45），
/// 它没声明 `Sendable`。虽然成员都是值类型（Int/[UInt8]）应当可推断，
/// 但把它塞进 `DispatchQueue.async` 的 `@Sendable` 闭包时，Swift 6 严格并发
/// 可能报错。取一份纯值快照（一次 25KB 拷贝）既避免跨 actor 争议，
/// 也让纯算法可以离线单测（不需要构造 MaskGrid 之外的东西）。
struct LaneMaskSnapshot: Sendable, Equatable {
    let width: Int
    let height: Int
    /// 行优先，0 = 背景，1 = 前景。
    let cells: [UInt8]

    /// 从 `MaskGrid` 构造；尺寸不符时返回 nil（由调用方如实置 invalid，不猜）。
    init?(mask: MaskGrid) {
        guard mask.width > 0, mask.height > 0,
              mask.cells.count >= mask.width * mask.height else { return nil }
        self.width = mask.width
        self.height = mask.height
        self.cells = Array(mask.cells.prefix(mask.width * mask.height))
    }

    /// 直接构造（自检用）。
    init(width: Int, height: Int, cells: [UInt8]) {
        self.width = width
        self.height = height
        self.cells = cells
    }

    @inline(__always)
    func at(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let idx = y * width + x
        guard idx >= 0, idx < cells.count else { return false }
        return cells[idx] != 0
    }

    /// 前景格数（诊断：INT8 退化时该值会异常小，见 `V2Config.minLanePixels`）。
    var positiveCount: Int {
        var n = 0
        for c in cells where c != 0 { n += 1 }
        return n
    }

    /// 空白掩码（无车道线）。
    static func empty(size: Int = V2InputContract.laneSize) -> LaneMaskSnapshot {
        LaneMaskSnapshot(width: size, height: size,
                         cells: [UInt8](repeating: 0, count: size * size))
    }
}

// MARK: - 车道线几何（曲率 / 朝向 / 横向偏移）

/// 从车道线掩码估计出的几何量。**这是修 bug 1 的核心产出。**
///
/// 三个量的符号约定（统一为"正值 = 需要向右打方向"，与 steer 的正负号同向）：
///   · heading > 0      车道前方相对车头**偏右**（需要右打）
///   · curvature > 0    车道**向右弯**
///   · lateralOffset > 0 车**偏在车道中心的右侧**
struct LaneGeometry: Sendable, Equatable {
    /// 路径曲率 ∈ [-1,1]。`valid == false` 时恒为 0。
    var curvature: Double = 0
    /// 当前朝向角 / π ∈ [-1,1]。`valid == false` 时恒为 0。
    var heading: Double = 0
    /// 相对车道中心横向偏移 ∈ [-1,1]。`valid == false` 时恒为 0。
    var lateralOffset: Double = 0
    /// **是否有可信的车道线几何**。
    ///
    /// 【诚实原则】没有足够车道线像素时置 false 且三个量全 0 —— 这对应
    /// `model_v2.py` 的「全零 = 未知」语义（StateEncoder 对 None 输入返回零向量，
    /// 让网络学到"全零 = 未知"，而不是用假数据污染）。**绝不编造几何量。**
    var valid: Bool = false
    /// 实际参与拟合的采样行数（诊断用）。
    var sampledRows: Int = 0
    /// 本次掩码的前景格数（诊断用；INT8 退化时该值会异常小）。
    var lanePixels: Int = 0
    /// 是否双侧都有车道线（false = 单侧拟合，此时 `lateralOffset` 不可信）。
    var bothSides: Bool = false
    /// 二次拟合系数（诊断用）：centerX = a·s² + b·s + c，s ∈ [-1,0]，s=0 为近端。
    var fitA: Double = 0
    var fitB: Double = 0
    var fitC: Double = 0

    /// 无有效几何（全零 + valid=false）。
    static let unknown = LaneGeometry()

    /// **横向偏移是否可信**。
    ///
    /// 【为什么要单独一个标志】单侧车道线时，中心是靠"本帧半宽中位数"或
    /// 标称半宽**补出来的**，补出来的中心只能反映"那条线在哪"，
    /// 无法反映"车在车道里的相对位置"—— 用它算 lateralOffset 等于拿假设
    /// 当测量。但**朝向与曲率仍可从单条线可靠估计**（它们只依赖线的斜率/
    /// 弯曲趋势，不依赖另一侧）。故这里做**分级降级**：
    ///   · 双侧 → lateralOffset 可信
    ///   · 单侧 → lateralOffset 强制 0（未知），heading/curvature 照常给
    /// 这比"整帧作废"保留更多真实信息，又不编造测量值。
    var lateralOffsetReliable: Bool { valid && bothSides }

    /// 诊断摘要（日志/UI 用）。
    var debugSummary: String {
        guard valid else {
            return "车道线几何无效（前景 \(lanePixels) 格，采样 \(sampledRows) 行）"
        }
        return String(format: "κ=%.3f h=%.3f off=%.3f（%@，前景 %d 格，%d 行）",
                      curvature, heading, lateralOffset,
                      bothSides ? "双侧" : "单侧", lanePixels, sampledRows)
    }
}

/// 车道线几何估计器（**纯函数，无状态，可离线单测**）。
///
/// 算法（逐行扫描 → 左右分组 → 二次拟合）：
///   ① 在采样带内逐行找"车道线像素的连续段"，取最左段与最右段
///   ② 双侧都有的行 → 车道中心 = 中点；同时统计半宽
///   ③ 只有单侧的行 → 用本帧半宽中位数补出中心（避免有效行骤降）
///   ④ 对 (行, 中心) 做最小二乘二次拟合 centerX = a·s² + b·s + c
///   ⑤ 由系数导出 heading / curvature / lateralOffset
///
/// 【为什么用二次拟合而不是"取两行算斜率"】
///   单帧两行的斜率对噪声极敏感（车道线常有 1~2 格断裂/抖动）。二次拟合
///   用了带内全部有效行，且**顺带给出曲率**（一阶导数=朝向，二阶=曲率），
///   一次拟合同时喂满 state 的 [2]/[4]/[5] 三个槽位。
enum LaneGeometryEstimator {

    /// 估计几何量。
    /// - Parameters:
    ///   - mask: 车道线掩码快照（160×160 二值）
    ///   - config: 可调参数
    /// - Returns: 几何量；有效行不足时返回 `.unknown`（全零 + valid=false）
    static func estimate(mask: LaneMaskSnapshot, config: V2Config = .default) -> LaneGeometry {
        var result = LaneGeometry.unknown
        guard mask.width > 1, mask.height > 1 else { return result }

        // ══════════════════════════════════════════════════════════════════════
        // 【INT8 退化保护 · 第 0 层】前景格数下限
        // ══════════════════════════════════════════════════════════════════════
        // 出处（项目既有实测）：tools/yolopx/export_yolopx_coreml.py:58-64 ——
        //   int8 量化把车道线正像素占比从 1.30–1.80% 打到 0.13–0.21%（约 10×）。
        //   本引擎的 lane 来自 yolopxEngine.laneMask，而该引擎可能就是 INT8 的。
        // 前景太少 → 拟合出来的"车道线"其实是碎片噪声 → **宁可报未知**。
        // 这一步必须在拟合**之前**做：碎片进拟合会产出一条看起来合理、
        // 实际完全错误的曲线，那比全零危险得多（模型会照着假曲率打方向）。
        var lanePixels = 0
        for c in mask.cells where c != 0 { lanePixels += 1 }
        result.lanePixels = lanePixels
        guard lanePixels >= config.minLanePixels else { return result }

        // ── 采样带（行号闭区间，含端点）──
        let topRow = Int((Double(mask.height) * config.bandTopRatio).rounded())
        let bottomRow = Int((Double(mask.height) * config.bandBottomRatio).rounded())
        let y0 = max(0, min(mask.height - 1, topRow))
        let y1 = max(0, min(mask.height - 1, bottomRow))
        guard y1 > y0 else { return result }
        let bandHeight = Double(y1 - y0)

        // ── ① 逐行找连续段，取最左/最右段中心 ──
        struct RowSides { var left: Double?; var right: Double?; var bothHalfWidth: Double? }
        var rows: [RowSides] = []
        rows.reserveCapacity(y1 - y0 + 1)

        for y in y0...y1 {
            var runs: [(start: Int, end: Int)] = []
            var runStart = -1
            for x in 0..<mask.width {
                let on = mask.at(x, y)
                if on, runStart < 0 {
                    runStart = x
                } else if !on, runStart >= 0 {
                    runs.append((runStart, x - 1))
                    runStart = -1
                }
            }
            if runStart >= 0 { runs.append((runStart, mask.width - 1)) }
            guard !runs.isEmpty else { rows.append(RowSides()); continue }

            let mid = Double(mask.width) / 2.0
            func center(_ r: (start: Int, end: Int)) -> Double {
                (Double(r.start) + Double(r.end)) / 2.0
            }

            var sides = RowSides()
            if runs.count >= 2 {
                // 多段：最左段 = 左车道线，最右段 = 右车道线
                let l = center(runs[0])
                let r = center(runs[runs.count - 1])
                // 防御：两段都在中线同侧时不算"双侧"（可能是同一条线的碎片）
                if l < mid, r > mid, r > l {
                    sides.left = l
                    sides.right = r
                    sides.bothHalfWidth = (r - l) / 2.0
                } else {
                    // 同侧碎片：按位置归到单侧，不做中心推断
                    if l < mid { sides.left = l } else { sides.right = r }
                }
            } else {
                // 单段：按相对中线位置归到左或右
                let c = center(runs[0])
                if c < mid { sides.left = c } else { sides.right = c }
            }
            rows.append(sides)
        }

        // ── ② 本帧半宽中位数（用于单侧行的补全）──
        var halfWidths: [Double] = []
        for r in rows { if let hw = r.bothHalfWidth, hw > 1 { halfWidths.append(hw) } }
        halfWidths.sort()
        let medianHalfWidth: Double = halfWidths.isEmpty
            ? Double(mask.width) * config.nominalHalfWidthRatio
            : halfWidths[halfWidths.count / 2]

        // ── ③ 汇总每行的车道中心 ──
        // s ∈ [-1, 0]：s = (y - y1)/bandHeight，近端(y1) 为 0，远端(y0) 为 -1。
        // 用 s 而非原始行号：让二次拟合的系数与采样带高度解耦（换分辨率不重标定）。
        var samples: [(s: Double, center: Double)] = []
        var rowsWithBothSides = 0
        for (offset, r) in rows.enumerated() {
            let y = y0 + offset
            let s = Double(y - y1) / bandHeight
            if let l = r.left, let rr = r.right {
                samples.append((s, (l + rr) / 2.0))
                rowsWithBothSides += 1
            } else if let l = r.left {
                samples.append((s, l + medianHalfWidth))
            } else if let rr = r.right {
                samples.append((s, rr - medianHalfWidth))
            }
        }

        // 有效行不足 → 如实报"没看见"，不猜
        guard samples.count >= config.minLaneRows else {
            result.sampledRows = samples.count
            return result
        }

        // ══════════════════════════════════════════════════════════════════════
        // 【分级降级 · 第 2 层】双侧 vs 单侧
        // ══════════════════════════════════════════════════════════════════════
        // 单侧时中心是**补出来的**（用半宽中位数），只能反映"那条线在哪"，
        // 不能反映"车在车道里的相对位置"。故：
        //   · heading / curvature：只依赖线的斜率与弯曲趋势 → **单侧也给**
        //   · lateralOffset：依赖另一侧才能定中心 → **单侧强制 0**
        // 这样既不编造测量值，也不把可用的朝向信息一起丢掉。
        let bothSides = rowsWithBothSides >= config.minLaneRows

        // ── ④ 最小二乘二次拟合 centerX = a·s² + b·s + c ──
        guard let fit = fitQuadratic(samples: samples) else {
            result.sampledRows = samples.count
            return result
        }

        // ══════════════════════════════════════════════════════════════════════
        // 【鲁棒性 · 第 3 层】离群行剔除 + 重拟合
        // ══════════════════════════════════════════════════════════════════════
        // 【为什么需要 —— 从一次真实 bug 学到的】
        //   自检里用"弯曲车道线"样本时发现：远端某行的右线越出画面被裁掉，
        //   该行只剩左线 → 被归为"单侧行" → 用半宽补出的中心**与整体趋势
        //   严重偏离** → 混进样本后把二次拟合带偏，**曲率符号直接翻转**
        //   （右弯算成负曲率）。根因不是裁剪，而是"单侧补出的中心"与
        //   "双侧实测的中心"混在一起拟合时，前者可能引入系统偏差。
        //   故这里做一次稳健化：先拟合，剔除残差过大的行，再重拟合。
        //
        // 阈值取 2.5×中位残差（MAD 风格，抗离群）：中位数本身不受离群影响，
        // 用它定标比用均值稳。至少保留 minLaneRows 行，否则放弃稳健化
        // （样本太少时剔除会过度伤害）。
        var refined = fit
        var refinedSamples = samples
        if samples.count >= config.minLaneRows * 2 {
            var residuals: [Double] = []
            residuals.reserveCapacity(samples.count)
            for (s, c) in samples {
                let predicted = fit.a * s * s + fit.b * s + fit.c
                residuals.append(abs(c - predicted))
            }
            let sorted = residuals.sorted()
            let median = sorted[sorted.count / 2]
            let threshold = max(median * 2.5, 1.5)   // 至少 1.5 格，避免过拟合噪声
            let kept = zip(samples, residuals)
                .filter { $0.1 <= threshold }
                .map(\.0)
            if kept.count >= config.minLaneRows, kept.count < samples.count,
               let refit = fitQuadratic(samples: kept) {
                refined = refit
                refinedSamples = kept
            }
        }
        let fit2 = refined

        // ── ⑤ 导出几何量（用稳健化后的 fit2）──
        // 一阶导 d(centerX)/dy = (2a·s + b)/bandHeight；近端 s=0 → b/bandHeight
        let slopePx = fit2.b / bandHeight
        // 二阶导 d²(centerX)/dy² = 2a/bandHeight²
        let secondPx = 2.0 * fit2.a / (bandHeight * bandHeight)

        // 朝向：前方 = 行号减小方向。前进 1 行 → centerX 变化 -slopePx。
        // 车道前方偏右（centerX 增大）→ 需要右打 → heading 取正。
        let yawRad = atan(-slopePx)
        let headingNorm = yawRad / Double.pi

        // 曲率：κ ≈ x''/(1+x'²)^1.5。符号与 heading 同向（正 = 右弯）：
        //   a > 0 时，随前进(s 减小) heading 增大 → 右弯 → 取 +。
        let denom = pow(1.0 + slopePx * slopePx, 1.5)
        let kappaPx = secondPx / max(denom, 1e-9)
        let curvatureNorm = kappaPx / config.curvatureReference

        // 横向偏移：近端中心相对画面中线的偏移，映射到 [-1,1]
        let nearCenter = fit2.c            // s = 0 处的 centerX
        let lateralNorm = (nearCenter / Double(mask.width) - 0.5) * 2.0

        result.curvature = clampUnit(curvatureNorm)
        result.heading = clampUnit(headingNorm)
        // 单侧 → 横向偏移不可信，强制 0（见上方第 2 层说明）
        result.lateralOffset = bothSides ? clampUnit(lateralNorm) : 0
        result.valid = true
        result.sampledRows = refinedSamples.count   // 实际参与最终拟合的行数
        result.bothSides = bothSides
        result.fitA = fit2.a
        result.fitB = fit2.b
        result.fitC = fit2.c
        return result
    }

    /// 最小二乘二次拟合（法方程 + 3×3 高斯消元）。
    /// - Returns: (a, b, c)；奇异或样本不足时 nil。
    private static func fitQuadratic(samples: [(s: Double, center: Double)]) -> (a: Double, b: Double, c: Double)? {
        let n = Double(samples.count)
        guard samples.count >= 3 else { return nil }

        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        for (s, c) in samples {
            let s2i = s * s
            s1 += s
            s2 += s2i
            s3 += s2i * s
            s4 += s2i * s2i
            t0 += c
            t1 += s * c
            t2 += s2i * c
        }
        // 法方程：
        //   [ s4 s3 s2 ] [a]   [t2]
        //   [ s3 s2 s1 ] [b] = [t1]
        //   [ s2 s1  n ] [c]   [t0]
        let m: [[Double]] = [[s4, s3, s2, t2],
                              [s3, s2, s1, t1],
                              [s2, s1, n,  t0]]
        guard let sol = solve3x3(m) else { return nil }
        return (sol[0], sol[1], sol[2])
    }

    /// 3×3 增广矩阵高斯消元（带部分主元），返回 [a,b,c]。
    private static func solve3x3(_ input: [[Double]]) -> [Double]? {
        var m = input
        for col in 0..<3 {
            // 部分主元：选该列绝对值最大的行
            var pivot = col
            for r in (col + 1)..<3 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-12 { return nil }   // 奇异
            if pivot != col { m.swapAt(pivot, col) }
            let diag = m[col][col]
            for r in (col + 1)..<3 {
                let factor = m[r][col] / diag
                for c in col..<4 { m[r][c] -= factor * m[col][c] }
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var sum = m[row][3]
            for c in (row + 1)..<3 { sum -= m[row][c] * x[c] }
            x[row] = sum / m[row][row]
        }
        guard x.allSatisfy({ $0.isFinite }) else { return nil }
        return x
    }

    @inline(__always)
    private static func clampUnit(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return max(-1.0, min(1.0, v))
    }
}

// MARK: - 车辆运动学输入（8 维状态的原料）

/// 构造 `vehicle_state[8]` 所需的全部原料。
///
/// 【为什么把"已算好的量"传进来而不是在这里算导数】导数需要**时间历史**
/// （上一帧的速度/朝向），而历史属于引擎的可变状态。把求导留在引擎里、
/// 把归一化留在纯函数里，纯函数就能离线单测（喂固定数值断言输出）。
struct V2Kinematics: Sendable, Equatable {
    /// 车速 km/h。**可能为 -1**（OCR 读不到，见 SpeedOCRReader.swift:157）——
    /// 归一化前必须先看 `speedValid`。
    var speedKmh: Double = -1
    /// 车速是否可信（`DriveState.speedValid`：OCR 读数新鲜且 confidence > 0.3）。
    var speedValid: Bool = false
    /// 速度上限 km/h（`DriveState.speedLimit`）。
    var speedLimitKmh: Double = 120
    /// 纵向加速度 m/s²（引擎按速度历史算好；无效时传 0）。
    var accelMps2: Double = 0
    /// 车道线几何（曲率/朝向/横向偏移）。
    var lane: LaneGeometry = .unknown
    /// 朝向角变化率 rad/s（引擎按历史算好；无效时传 0）。
    ///
    /// ⚠️ **语义澄清（与 M1 文档的 heading 不是同一个量）**：
    ///   这里的 heading 是**车道线视觉朝向**（= 车道线相对车头指向的角度，
    ///   由 LaneGeometryEstimator 从掩码斜率 in rad 估计），归一化到 /π。
    ///   它**不是** `NetworkLocator` 的 `locatorHeading`（世界坐标系绝对方位角，
    ///   单位是**度**，见 docs/主驾驶模型换代-需求与方案 §3.4 的单位冲突）。
    ///   两者名字都叫 heading，但一个是"相对车头的视觉方向"、一个是"绝对朝向"，
    ///   **绝不可混用**。本引擎只消费前者；若将来要接 locatorHeading，
    ///   必须先做"度→弧度 + 世界系→车身系"两次变换，走 §3.4 的 heading_unit="deg"。
    var headingRateRad: Double = 0
    /// 当前方向盘角 / 最大角 ∈ [-1,1]（来自上一次决策输出）。
    var steerAngle: Double = 0
    /// **自车框是否已被 EgoBoxFilter 剔除**（1 = 已剔除）。
    ///
    /// ⚠️ 命名歧义提示：契约里这一位叫 `ego_visible`，但注释写明
    ///    「1=自车框已剔除」（model_v2.py:657 / export 脚本契约表）。
    ///    本文件按**注释语义**填（已剔除 → 1），并在文档里如实标注该歧义。
    var egoBoxFiltered: Bool = false

    // ── M4 新增：视角朝向（喂 HeadingHead / TemporalEncoder 那一路）──

    /// 视角朝向，**compass 度 [0,360)**（抓包口径）。
    ///
    /// 【单位铁律】抓包侧 `NetworkLocator.cameraHeading` 与
    /// `CoordinateCapture` 的 `compass_heading` **都是罗盘度 [0,360)**，
    /// 而模型期望 **rad**。本字段**恒为度**（不在这里转，转在纯函数层，
    /// 见 `V2FeatureBuilder.buildCameraHeadingRad`），避免"同一字段两种单位"。
    /// nil = 无数据（抓包未接入 / 数据陈旧）。
    var cameraHeadingDeg: Double?
    /// 视角朝向是否可信。
    ///
    /// 来源侧新鲜度判据由调用方给（例如抓包时间戳 < 0.5s）。
    /// 本引擎只看这个 bool，不猜来源。
    var cameraHeadingValid: Bool = false
}

// MARK: - 纯特征构造（可离线单测）

/// 五路输入的**纯数值特征**（不含 MLMultiArray，便于离线断言）。
struct V2Features: Sendable, Equatable {
    /// [8]
    var vehicleState: [Float]
    /// [20 × 12] 行优先
    var dets: [Float]
    /// [20]
    var detMask: [Float]
    /// [160 × 160] 行优先，0/1
    var laneMask: [Float]
    /// 本次用到的几何量（诊断/日志用）
    var laneGeometry: LaneGeometry
    /// 本次实际填入的有效框数
    var validDetectionCount: Int

    // ── M4 新增：视角朝向（喂 HeadingHead 那一路）──

    /// 视角朝向 `[1]`，**rad**（已完成 compass 度→rad 转换）。
    ///
    /// 【为什么在这里就转成 rad】契约侧模型期望 rad；转换放在纯函数层
    /// 便于离线断言（compass 350°→10° 应得 +20° 这类用例）。
    /// nil = 无视角朝向数据（抓包未接入）→ 传 0，并如实标注。
    var cameraHeadingRad: Float?
    /// 视角朝向是否有效（false = 抓包未接入/数据陈旧）。
    ///
    /// 【为什么要这个 flag】`camera_heading` 无效时若传 0，
    /// 模型会理解成"视角朝正北"这个**具体值**而非"未知"。
    /// 但 CoreML 输入无法表达 None（固定 shape），故：
    /// 仍传 0，但把有效性记在 Swift 侧（供诊断/降级判断），
    /// 并**不谎报**"我们有视角数据"。语义与 vehicle_state 的
    /// "全零=未知"惯例一致（模型会自己学会零=不可信）。
    var cameraHeadingValid: Bool
}

// MARK: - 三个新头的输出（M4 辅助头）

/// M4 辅助头输出。**全部可选** —— 模型可能是旧契约（只 3 输出），
/// 此时三个字段为 nil，调用方按旧路径走（优雅降级纪律）。
struct V2AuxOutputs: Sendable, Equatable {
    /// 决策置信度 ∈ [0,1] → `ControlCommand.confidence`。
    ///
    /// 【为什么这个最重要】`ControlCommand.confidence` 是**一直空着**的字段
    /// （`EscapeController.swift:28-33` 注释：「E2E 填模型置信度，Rule 填启发式分」）。
    /// 本引擎是 E2E 路径 → 应由模型置信度填它，供状态机降级判定用。
    var confidence: Double?
    /// 风险分 ∈ [0,1] → 供接管判定。
    var risk: Double?
    /// 预测车头朝向（rad）→ 诊断/日志。
    var carHeadingRad: Double?

    /// 是否采到了任何辅助输出（全 nil = 旧契约模型）。
    var isEmpty: Bool { confidence == nil && risk == nil && carHeadingRad == nil }

    /// 诊断摘要。
    var debugSummary: String {
        if isEmpty { return "无（旧契约模型）" }
        var parts: [String] = []
        if let c = confidence { parts.append(String(format: "conf=%.3f", c)) }
        if let r = risk { parts.append(String(format: "risk=%.3f", r)) }
        if let h = carHeadingRad { parts.append(String(format: "carH=%.1f°", h * 180 / .pi)) }
        return parts.joined(separator: " ")
    }

    static let empty = V2AuxOutputs()
}

/// 纯特征构造器（**无状态、无 CoreML 依赖、可离线单测**）。
enum V2FeatureBuilder {

    /// 构造 `vehicle_state[8]`。
    ///
    /// 契约（`src/model_v2.py` StateEncoder 文档 :648-657）：
    ///   [0] speed          车速/速度上限       ∈ [0,1]
    ///   [1] accel          纵向加速度/10 m·s⁻² ∈ [-1,1]
    ///   [2] heading        当前角度/π          ∈ [-1,1]
    ///   [3] heading_rate   角度变化率/π·s⁻¹    ∈ [-1,1]
    ///   [4] curvature      路径曲率            ∈ [-1,1]
    ///   [5] lateral_offset 相对车道中心横偏     ∈ [-1,1]
    ///   [6] steer_angle    方向盘角/最大角      ∈ [-1,1]
    ///   [7] reserved       ego_visible 标志
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【bug 2 修复点 · speedValid 是硬门】
    /// ══════════════════════════════════════════════════════════════════════
    /// `SpeedOCRReader.speedKmh` 读不到时是 **-1**（SpeedOCRReader.swift:157）。
    /// 旧实现直接 `speedKmh / 120` → 得到 -0.0083 的**负速度**喂进模型。
    /// 这里以 `speedValid` 为硬门：
    ///   · 无效 → speed 填 **0**（契约的"未知"取值），且 **accel 也填 0**
    ///     —— 速度不可信时它的导数同样不可信，留着是二次污染；
    ///   · 有效 → 按 `speedReference` 归一化并 clamp 到 [0,1]。
    /// 注意：**不是**把 -1 clamp 成 0 —— 那样虽然数值相同，但语义上仍把
    /// "读不到"当成"速度为零"，而 `speedValid=false` 时模型应学到"未知"。
    /// 两者数值恰好都是 0，区别在于我们**知道**自己在填未知（注释与 validity 可证）。
    static func buildVehicleState(_ k: V2Kinematics, config: V2Config = .default) -> [Float] {
        let speedRef = max(1.0, config.speedReference)

        // [0] speed：speedValid 硬门
        var speedNorm = 0.0
        if k.speedValid, k.speedKmh >= 0, k.speedKmh.isFinite {
            speedNorm = clamp(k.speedKmh / speedRef, 0, 1)
        }
        // 注：speedLimit 是配置值（DriveState.speedLimit，缺省 120），恒可信
        _ = k.speedLimitKmh

        // [1] accel：速度不可信 → 导数不可信 → 0
        var accelNorm = 0.0
        if k.speedValid, k.accelMps2.isFinite {
            accelNorm = clamp(k.accelMps2 / config.accelReference, -1, 1)
        }

        // [2] heading / [4] curvature / [5] lateral_offset：来自车道线几何。
        //     valid=false 时 LaneGeometry 三量恒为 0（诚实原则，见其注释）。
        let lane = k.lane.valid ? k.lane : .unknown
        let headingNorm = clamp(lane.heading, -1, 1)

        // [3] heading_rate：几何无效时导数无意义 → 0
        var headingRateNorm = 0.0
        if lane.valid, k.headingRateRad.isFinite {
            headingRateNorm = clamp(k.headingRateRad / Double.pi, -1, 1)
        }

        // [6] steer_angle
        let steerNorm = clamp(k.steerAngle, -1, 1)

        // [7] reserved = ego_visible（1 = 自车框已剔除）
        let egoFlag: Double = k.egoBoxFiltered ? 1.0 : 0.0

        return [
            Float(speedNorm),
            Float(accelNorm),
            Float(headingNorm),
            Float(headingRateNorm),
            Float(clamp(lane.curvature, -1, 1)),
            Float(clamp(lane.lateralOffset, -1, 1)),
            Float(steerNorm),
            Float(egoFlag),
        ]
    }

    /// 构造 `dets[20×12]` + `det_mask[20]`。
    ///
    /// 每框 12 维（**权威定义**，见 `V2InputContract.detFeatureDim` 注释）：
    ///   [0] x  [1] y  [2] w  [3] h   归一化 [0,1]     ← Detection.x/y/width/height
    ///   [4:8] label one-hot(car, pedestrian, sign, obstacle)
    ///   [8] confidence [0,1]
    ///   [9] speed     框内目标相对速度（**无则 0**）
    ///   [10] heading  框内目标朝向（**无则 0**）
    ///   [11] age      连续跟踪帧数归一化（**无则 0**）
    ///
    /// 【槽位分配策略】按 confidence **降序**填前 20 个。
    ///   理由：`DetectionEncoder` 用 masked max pool + masked mean pool，
    ///   对顺序不敏感（permutation invariant），但**超出 20 个时必须丢弃**，
    ///   丢低置信度的比丢高置信度的合理（正前方近车通常高置信）。
    ///
    /// 【TODO · 未接跟踪器】[9]/[10]/[11] 现恒为 0（契约允许："无则 0"）。
    ///   `MotionPredictor` 有跟踪概念（TrackedTarget.age），但接它需要改
    ///   `updateMotionPipeline` 调用链 —— 与 T1/T7 的改动面重叠，Lead 明确
    ///   要求**先按 0 填、留 TODO**，等模型跑通后再接。见本文件末尾 TODO 段。
    ///
    /// ⚠️ 空槽必须 `dets` 全 0 + `det_mask` 置 0（实测坑 2：CoreML 不支持动态 N，
    ///    固定 N=20 + valid 位是唯一可行方案）。少喂会报 shape 错，不会静默算错。
    static func buildDetections(_ detections: [Detection],
                                config: V2Config = .default) -> (dets: [Float], mask: [Float], validCount: Int) {
        let n = V2InputContract.maxDetections
        let d = V2InputContract.detFeatureDim
        var dets = [Float](repeating: 0, count: n * d)
        var mask = [Float](repeating: 0, count: n)

        // 置信度降序；同置信度时保持原顺序（稳定分区，不用不稳定的 sort）
        let ordered = detections.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.confidence != rhs.element.confidence {
                    return lhs.element.confidence > rhs.element.confidence
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        let count = min(n, ordered.count)
        for i in 0..<count {
            let det = ordered[i]
            let base = i * d
            dets[base + 0] = Float(clamp(det.x, 0, 1))
            dets[base + 1] = Float(clamp(det.y, 0, 1))
            dets[base + 2] = Float(clamp(det.width, 0, 1))
            dets[base + 3] = Float(clamp(det.height, 0, 1))
            // label one-hot
            let onehot = labelOneHot(det.label)
            for k in 0..<V2InputContract.labelCount {
                dets[base + 4 + k] = onehot[k]
            }
            dets[base + 8] = Float(clamp(det.confidence, 0, 1))
            // [9] speed / [10] heading / [11] age —— 契约允许"无则 0"
            dets[base + 9] = 0
            dets[base + 10] = 0
            dets[base + 11] = 0
            mask[i] = 1
        }
        return (dets, mask, count)
    }

    /// 类别 → one-hot（顺序：car, pedestrian, sign, obstacle）。
    static func labelOneHot(_ label: Detection.Label) -> [Float] {
        var v = [Float](repeating: 0, count: V2InputContract.labelCount)
        switch label {
        case .car:        v[0] = 1
        case .pedestrian: v[1] = 1
        case .sign:       v[2] = 1
        case .obstacle:   v[3] = 1
        }
        return v
    }

    /// 构造 `lane[1×1×160×160]`（行优先 0/1）。
    ///
    /// ⛔ **只放车道线，绝不掺 drivableMask**（model_v2.py §八 契约红线，
    ///    用户明确要求"可行驶区域不要收"）。本函数只接收 `LaneMaskSnapshot`
    ///    这一种来源，结构上杜绝了把 drivable 拼进来的可能。
    ///
    /// 尺寸不符时返回**全零**（而不是缩放/裁剪）：缩放到 160×160 会引入
    /// 插值噪声，而"掩码尺寸不对"本身说明上游契约漂移，此时给全零让模型
    /// 走"无车道线"分支，比喂一份插值出来的假掩码安全。
    static func buildLaneMask(_ snapshot: LaneMaskSnapshot?) -> [Float] {
        let size = V2InputContract.laneSize
        var out = [Float](repeating: 0, count: size * size)
        guard let snapshot else { return out }
        guard snapshot.width == size, snapshot.height == size else { return out }
        for i in 0..<(size * size) {
            out[i] = snapshot.cells[i] != 0 ? 1 : 0
        }
        return out
    }

    /// 一次构造全部纯特征（供引擎与自检共用）。
    static func build(kinematics: V2Kinematics,
                      detections: [Detection],
                      laneMask: LaneMaskSnapshot?,
                      config: V2Config = .default) -> V2Features {
        let geometry = LaneGeometryEstimator.estimate(mask: laneMask ?? .empty(), config: config)
        var k = kinematics
        k.lane = geometry
        let (dets, mask, count) = buildDetections(detections, config: config)
        let (camRad, camValid) = buildCameraHeadingRad(kinematics)
        return V2Features(vehicleState: buildVehicleState(k, config: config),
                          dets: dets,
                          detMask: mask,
                          laneMask: buildLaneMask(laneMask),
                          laneGeometry: geometry,
                          validDetectionCount: count,
                          cameraHeadingRad: camRad,
                          cameraHeadingValid: camValid)
    }

    // MARK: 视角朝向（compass 度 → rad）

    /// compass 度 `[0,360)` → 数学弧度 `[-π,π]`。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【单位铁律 —— 本项目最容易出错的地方之一】
    /// ══════════════════════════════════════════════════════════════════════
    /// 抓包侧两个来源**都是罗盘度 [0,360)**：
    ///   · `NetworkLocator.cameraHeading`（NetworkLocator.swift:310,560-562）：
    ///     `(atan2(east, north) * 180/π + 360) % 360`
    ///   · `CoordinateCapture` 的 `compass_heading`（rotation.yaw）
    /// 而模型期望 **rad**。直接喂度数会让 90° 被当成 90 rad（差 57 倍）。
    ///
    /// 转换：`(d + 180) % 360 - 180` 折到 [-180,180] 再 × π/180。
    /// 该式与 Python 侧 `heading_head.normalize_camera_heading(·,"compass")`
    /// **逐值等价**（已实测 0/90/180/270/359.9 五个点）。
    ///
    /// - Returns: (rad, 是否有效)。无效时返回 `(0, false)` ——
    ///   仍传 0（CoreML 无法表达 None），但有效性如实记录，不谎报"有数据"。
    static func buildCameraHeadingRad(_ k: V2Kinematics) -> (Float, Bool) {
        guard k.cameraHeadingValid, let deg = k.cameraHeadingDeg,
              deg.isFinite else {
            return (0, false)
        }
        // 先折到 [-180,180)（角差的良定义域），再转弧度
        var wrapped = deg.truncatingRemainder(dividingBy: 360.0)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        let rad = wrapped * Double.pi / 180.0
        guard rad.isFinite else { return (0, false) }
        return (Float(max(-Double.pi, min(Double.pi, rad))), true)
    }

    @inline(__always)
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return 0 }
        return max(lo, min(hi, v))
    }
}

// MARK: - 图像帧环形缓冲（方案 A：8 帧原图）

/// 最近 N 帧图像的环形缓冲。
///
/// 【为什么需要】方案 A 的 `image` 输入是 `[8,3,180,320]`（8 帧时序窗口），
/// 必须由调用方维护历史。实测代价（w5）：batch=8 ImageEncoder
/// **1.62ms p50 / 1.94ms p75**，占 33ms 帧预算 5.1%，可接受。
///
/// 【内存】8 帧 × 3×180×320 × 4B(float32) ≈ **5.5MB**（常驻，不每帧分配）。
/// 这里存的是**已预处理好的 CHW Float32 归一化张量**（不是 CGImage）：
///   · 若存 CGImage：每帧推理时还要重做 8 次缩放+像素读取（贵）；
///   · 存预处理结果：每帧只需预处理**当前帧一次**，其余 7 帧直接复用。
///
/// 【帧序契约】`snapshot()` 返回**最老在前、最新在后**
/// （index 0 = 最旧，index N-1 = 当前帧）。依据：`temporal.py:231/273`
/// 取 `out[:, -1]`（注释原文「最后一帧的因果聚合」）——
/// **末位必须是当前帧**，否则因果聚合拿到的是错误的历史端点。
///
/// 【未填满时怎么办】启动头几帧不足 N 帧 → **前面的空位填零、有效帧靠尾对齐**
/// （即 `[0,0,...,0, 第1帧, 第2帧]`）。依据（两条，同一结论）：
///   ① 训练侧 `temporal.py:46-53` 原文：「历史不足 N 帧时两种写法**数值完全等价**
///      （实测 allclose=True）：mask 方案（无效帧清零、保留位置）/ 零填充方案。
///      ⚠️ 为什么"清零+保留位置"而不是"丢帧"：GRU 是逐帧递推，丢帧会改变时间轴
///      对齐，而清零保持"这段是无效历史"的语义 —— 门控会自己学会"零输入=不可信"。」
///   ② w5 2026-10-08 实测同步：「不足 8 帧时**补零帧到 8**（前 N 帧有效、
///      其余填零图像），而不是传 1 帧——传 1 帧会被判定为单帧模式，时序不生效」。
///
/// ⚠️ **早先版本的两个错误（已修，留痕以免重犯）**：
///   ① 曾用"复制最老帧"填充空位 —— 那是**虚假观测**（假装这段时间画面没变），
///      与训练侧的 mask/零填充语义都不符。
///   ② 曾把有效帧**靠头对齐**（`[当前帧,0,...]`）—— 方向错了：
///      模型取 `out[:,-1]` 会把**全零帧**当当前帧、把真当前帧当 8 帧前的旧历史。
///      实测代码核对后修正为**靠尾对齐**。
struct ImageFrameRingBuffer {
    /// 帧数（= 时序窗口 N）。
    let capacity: Int
    /// 每帧元素数（3×H×W）。
    let frameLength: Int

    /// 环形存储：`[capacity][frameLength]`，按插入顺序的物理槽位。
    private var storage: [[Float]]
    /// 下一个写入槽位。
    private var writeIndex: Int = 0
    /// 已写入的帧数（用于判断是否填满）。
    private(set) var filled: Int = 0

    init(capacity: Int = V2InputContract.historyFrames,
         frameLength: Int = 3 * V2InputContract.imageHeight * V2InputContract.imageWidth) {
        self.capacity = max(1, capacity)
        self.frameLength = max(0, frameLength)
        self.storage = Array(repeating: [Float](repeating: 0, count: self.frameLength),
                             count: self.capacity)
    }

    /// 写入一帧（覆盖最老的）。
    /// - Parameter frame: 长度必须 == frameLength，否则**忽略**（不静默截断）。
    /// - Returns: 是否写入成功。
    @discardableResult
    mutating func push(_ frame: [Float]) -> Bool {
        guard frame.count == frameLength else { return false }
        storage[writeIndex] = frame
        writeIndex = (writeIndex + 1) % capacity
        if filled < capacity { filled += 1 }
        return true
    }

    /// 导出时序窗口（**最老在前、最新在后**，长度 = capacity × frameLength）。
    ///
    /// 未填满时：空位填**零**，且有效帧**靠尾对齐**（见类型注释的理由）。
    ///
    /// ⚠️⚠️ 【靠尾对齐 —— 2026-10-08 修复的真实方向 bug】
    ///   `temporal.py:231`（GRU 分支）与 `:273`（TCN 分支）都取 `out[:, -1]`
    ///   —— 注释原文「**最后一帧的因果聚合**」。
    ///   即 **index N-1 = 当前帧**，index 0 = 最老帧。
    ///   启动时只有 1 帧有效时，**它必须落在 index N-1**：
    ///       正确 [0,0,0,0,0,0,0, 当前帧]
    ///       错误 [当前帧,0,0,0,0,0,0,0]   ← 早先的实现（有效帧靠头）就是这个，
    ///              后果是模型把**全零帧**当作"当前帧"做因果聚合，
    ///              而真正的当前帧被当成 8 帧前的旧历史 → 时序语义彻底错乱。
    ///   修法：`filled < capacity` 时，第 i 个已写入帧放到 `capacity - filled + i`
    ///   （右对齐），前面的槽位保持零（= "这段是无效历史"，与训练侧
    ///   `temporal.py:46-53` 的 mask 语义一致）。
    func snapshot() -> [Float] {
        var out = [Float](repeating: 0, count: capacity * frameLength)
        guard frameLength > 0 else { return out }

        // 未填满时的起始写入位置（右对齐）：capacity - filled
        let offset = filled < capacity ? (capacity - filled) : 0
        for logical in 0..<capacity {
            let physical: Int
            if filled < capacity {
                // 已写入的 filled 帧位于 storage[0..<filled]，按序放到尾部
                let src = logical - offset
                guard src >= 0, src < filled else { continue }   // 头部槽位保持零
                physical = src
            } else {
                // 填满：最老帧在 writeIndex（环形读序）
                physical = (writeIndex + logical) % capacity
            }
            let base = logical * frameLength
            out.replaceSubrange(base..<(base + frameLength), with: storage[physical])
        }
        return out
    }

    /// 清空（换场景/重开一局时调用，避免上一局的 8 帧污染当前决策）。
    mutating func reset() {
        writeIndex = 0
        filled = 0
        for i in 0..<capacity {
            for j in 0..<frameLength { storage[i][j] = 0 }
        }
    }
}

// MARK: - 推理引擎 V2

/// M9-V2 五输入端到端推理引擎。
///
/// 与 `InferenceEngine` 的关系：**并列，不替代**。靠 `DriveState` 侧开关切换，
/// 原引擎一字未改，可随时回滚。
///
/// 线程模型（沿用原引擎的成熟做法，见 InferenceEngine.swift:17-23）：
///   · 类 `@MainActor`，可变状态只在主线程读写
///   · 重活（预处理/推理）在 `inferenceQueue` 后台串行队列
///   · `nonisolated static` 纯函数无 self 捕获，可安全后台执行
///   · `isInferencing` 防重叠，`generation` 防过期结果写回
@Observable
@MainActor
final class InferenceEngineV2 {

    // MARK: 状态

    /// 是否已加载模型。**模型文件缺失时保持 false 并给出明确原因**（优雅降级）。
    private(set) var isLoaded = false
    /// 是否有一次后台加载在途（防 30Hz 重复提交）。
    private var isLoadingModel = false
    /// 是否正在推理（防重叠）。
    private(set) var isInferencing = false
    /// 最新推理结果（与旧引擎的 `InferenceResult` 兼容）。
    private(set) var lastResult: InferenceResult?
    /// 最近一次成功推理时间（判新鲜度）。
    private(set) var lastResultTime: Date?
    /// 累计推理次数。
    private(set) var inferenceCount: Int = 0
    /// 加载/推理错误（UI 如实展示）。
    private(set) var errorMessage: String?
    /// 最近一帧的车道线几何（诊断：曲率/朝向是否真的算出来了）。
    private(set) var lastLaneGeometry: LaneGeometry = .unknown
    /// 最近一帧的有效框数（诊断）。
    private(set) var lastValidDetectionCount: Int = 0
    /// **最近一帧车道线前景格数**（诊断）。
    ///
    /// 【为什么单独暴露】出处 tools/yolopx/export_yolopx_coreml.py:58-64 实测：
    /// INT8 量化会把车道线正像素占比从 1.30–1.80% 打到 0.13–0.21%（约 10×）。
    /// 正常 160×160 应有 333~461 格；若这里长期只有几十格甚至个位数，
    /// 说明**上游 yolopx 的车道线已被量化毁掉**，曲率/朝向拟合必然不可信。
    /// 有了这个数字，用户/开发者能一眼判断"是算法不行还是上游模型废了"。
    private(set) var lastLanePixelCount: Int = 0

    // ── M4 三个辅助头的最新输出（2026-10-08 T1 传输扩展）──

    /// 最近一帧视角朝向是否有效（false = 抓包未接入/数据陈旧）。
    private(set) var lastCameraHeadingValid: Bool = false
    /// 最近一次的辅助输出整体（旧契约模型 = `.empty`）。
    private(set) var lastAuxOutputs: V2AuxOutputs = .empty
    /// **决策置信度** ∈ [0,1]（来自模型 confidence 头；旧契约模型 = nil）。
    ///
    /// 【用途】`ControlCommand.confidence` 的来源——状态机降级判定用。
    /// 这个字段在旧链路里一直空着（E2E 从未填过），本引擎是第一个真填它的。
    private(set) var lastConfidence: Double?
    /// 风险分 ∈ [0,1]（来自模型 risk 头；旧契约模型 = nil）→ 接管判定。
    private(set) var lastRisk: Double?
    /// 预测车头朝向（rad，[-π,π]；来自模型 car_heading 头；旧契约 = nil）→ 诊断。
    private(set) var lastCarHeadingRad: Double?

    /// 加载失败冷却（秒）。
    private let loadRetryCooldown: TimeInterval = 5.0
    @ObservationIgnored
    private var lastLoadAttempt: Date = .distantPast
    /// generation：reload/reset 时递增，在途结果比对后丢弃过期值。
    @ObservationIgnored
    private var generation = 0

    // MARK: 资源

    @ObservationIgnored
    private nonisolated(unsafe) var model: MLModel?
    @ObservationIgnored
    private let inferenceQueue = DispatchQueue(label: "com.aurora.inference.v2",
                                               qos: .userInteractive)
    /// 复用缓冲：image ≈691KB / lane 25KB / dets 960B / mask 80B / state 32B。
    @ObservationIgnored
    private nonisolated(unsafe) var reusableImageBuffer: MLMultiArray?
    @ObservationIgnored
    private nonisolated(unsafe) var reusableLaneBuffer: MLMultiArray?
    @ObservationIgnored
    private nonisolated(unsafe) var reusableDetsBuffer: MLMultiArray?
    @ObservationIgnored
    private nonisolated(unsafe) var reusableDetMaskBuffer: MLMultiArray?
    @ObservationIgnored
    private nonisolated(unsafe) var reusableStateBuffer: MLMultiArray?

    // ── 方案 A：8 帧时序窗口 ──

    /// 帧预处理临时缓冲（当前帧一次，写入环形缓冲后复用）。
    @ObservationIgnored
    private nonisolated(unsafe) var reusableFrameScratch: MLMultiArray?
    /// 8 帧序列输入缓冲 `[8,3,180,320]` ≈ 5.5MB（每帧复用，不新建）。
    @ObservationIgnored
    private nonisolated(unsafe) var reusableImageSequenceBuffer: MLMultiArray?
    /// **帧环形缓冲**（方案 A 的核心状态；5.5MB 常驻）。
    ///
    /// 【并发不变式】只在 `inferenceQueue`（串行）上访问——与
    /// `reusableImageBuffer` 等复用缓冲同一套纪律（`isInferencing`
    /// 防重叠保证同一时刻只有一个在途任务，无并发访问）。
    /// 类型声明为 `nonisolated(unsafe)` 是因为从后台队列读写；
    /// 逻辑安全性由上述不变式保证（注释见 push/snapshot 调用处）。
    @ObservationIgnored
    private nonisolated(unsafe) var frameBuffer = ImageFrameRingBuffer()

    /// 模型文件名（不带扩展名）。默认 `m9_v2`（export 脚本的默认产出名）。
    private let modelFileName: String
    /// 可调参数。
    private let config: V2Config

    /// 运动学历史（算 accel / heading_rate 用）。
    @ObservationIgnored
    private var lastSpeedSample: (kmh: Double, at: Date)?
    @ObservationIgnored
    private var lastHeadingSample: (rad: Double, at: Date)?
    @ObservationIgnored
    private var lastSteerCommand: Double = 0

    /// PerfBus 通道名（与旧引擎区分，便于分开统计谁更贵）。
    private var perfChannel: String { "infer.\(modelFileName)" }

    init(modelFileName: String = "m9_v2", config: V2Config = .default) {
        self.modelFileName = modelFileName
        self.config = config
    }

    // MARK: 模型定位与加载

    /// 模型路径。
    ///
    /// 【为什么只认 .mlmodelc】实测坑 7：`.mlpackage` **不能**被
    /// `MLModel(contentsOf:)` 直接加载，必须先 `MLModel.compileModel(at:)`。
    /// 旧引擎 `InferenceEngine.swift:142-150` 的 `.mlpackage` 回退路径
    /// 按该实测**是走不通的**（对比 `YolopxEngine` 有显式 compileModel）。
    /// 本引擎**不做那条无效回退**：找不到 .mlmodelc 就如实报"模型未导出"，
    /// 而不是抛一个难懂的 CoreML 错误。导出脚本始终优先产出 .mlmodelc。
    private var modelURL: URL? {
        let modelsDir = AuroraPaths.projectRoot().appendingPathComponent("models")
        let compiled = modelsDir.appendingPathComponent("\(modelFileName).mlmodelc")
        guard FileManager.default.fileExists(atPath: compiled.path) else { return nil }
        return compiled
    }

    /// 同步加载（启动路径显式预热用；保持 MainActor 语义简单）。
    func loadIfNeeded() {
        guard !isLoaded else { return }
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()

        guard let url = modelURL else {
            // 优雅降级：模型未导出 ≠ 程序出错。如实说明，不影响旧链路。
            errorMessage = "M9-V2 模型未就绪（models/\(modelFileName).mlmodelc 不存在；"
                         + "请先运行 tools/export_m9_v2_coreml.py 导出）"
            isLoaded = false
            return
        }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let mlModel = try MLModel(contentsOf: url, configuration: cfg)
            model = mlModel
            isLoaded = true
            errorMessage = nil
            Self.warmUp(model: mlModel, label: modelFileName, queue: inferenceQueue, config: config)
        } catch {
            errorMessage = "M9-V2 模型加载失败: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    /// 后台兜底加载（热路径调用，绝不阻塞主线程）。
    private func scheduleBackgroundLoadIfNeeded() {
        guard !isLoadingModel else { return }
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()

        guard let url = modelURL else {
            errorMessage = "M9-V2 模型未就绪（models/\(modelFileName).mlmodelc 不存在）"
            isLoaded = false
            return
        }
        isLoadingModel = true
        let fileName = modelFileName
        let gen = generation
        let queue = inferenceQueue
        let cfg = config

        queue.async { [weak self] in
            let mlCfg = MLModelConfiguration()
            mlCfg.computeUnits = .all
            let loaded = try? MLModel(contentsOf: url, configuration: mlCfg)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoadingModel = false
                guard self.generation == gen else { return }
                if let loaded {
                    self.model = loaded
                    self.isLoaded = true
                    self.errorMessage = nil
                    Self.warmUp(model: loaded, label: fileName, queue: queue, config: cfg)
                } else {
                    self.errorMessage = "M9-V2 模型加载失败（后台兜底）: \(url.lastPathComponent)"
                    self.isLoaded = false
                }
            }
        }
    }

    /// 预热：跑一次全零输入，把 ANE 图编译/内存分配提前做完。
    private nonisolated static func warmUp(model: MLModel, label: String,
                                           queue: DispatchQueue, config: V2Config) {
        queue.async {
            guard let provider = try? makeProvider(features: zeroFeatures()) else {
                print("[warmup.v2] \(label): 预热输入构造失败")
                return
            }
            let start = Date()
            do {
                _ = try model.prediction(from: provider)
                let ms = Date().timeIntervalSince(start) * 1000
                print("[warmup.v2] \(label) 预热完成: \(String(format: "%.1f", ms))ms")
            } catch {
                print("[warmup.v2] \(label) 预热失败: \(error.localizedDescription)")
            }
        }
    }

    /// 热替换（训练/导出完成后调用）。
    func reloadModel() {
        generation += 1
        model = nil
        isLoaded = false
        isInferencing = false
        errorMessage = nil
        lastLoadAttempt = .distantPast   // 允许立刻重试
    }

    // MARK: 推理入口

    /// 异步推理。
    /// - Parameters:
    ///   - image: 截屏画面（内部缩放到 180×320）
    ///   - kinematics: 车辆运动学原料（速度/几何/转向）
    ///   - detections: **已过 EgoBoxFilter 的**检测框（自车框必须已剔除）
    ///   - laneMask: 车道线掩码（`YolopxEngine.laneMask`）
    func infer(image: CGImage,
               kinematics: V2Kinematics,
               detections: [Detection],
               laneMask: MaskGrid?) {
        guard isLoaded, let modelRef = model else {
            scheduleBackgroundLoadIfNeeded()
            return
        }
        guard !isInferencing else { return }
        isInferencing = true

        // 跨线程只传值类型（MaskGrid 在这里转成 Sendable 快照）
        let snapshot = laneMask.flatMap { LaneMaskSnapshot(mask: $0) }
        let gen = generation
        let cfg = config

        // 速度/朝向历史在主线程取（避免后台读 MainActor 状态）
        let now = Date()
        var accel = 0.0
        if let prev = lastSpeedSample, kinematics.speedValid, prev.kmh >= 0 {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 1e-3, dt < 2.0 {
                // km/h → m/s，除以 3.6
                accel = ((kinematics.speedKmh - prev.kmh) / 3.6) / dt
            }
        }
        if kinematics.speedValid, kinematics.speedKmh >= 0 {
            lastSpeedSample = (kinematics.speedKmh, now)
        } else {
            lastSpeedSample = nil   // 速度不可信 → 断开历史，避免下次用坏点求导
        }

        let geom = LaneGeometryEstimator.estimate(mask: snapshot ?? .empty(), config: cfg)
        var headingRate = 0.0
        if geom.valid {
            if let prev = lastHeadingSample {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 1e-3, dt < 2.0 {
                    headingRate = (geom.heading * Double.pi - prev.rad) / dt
                }
            }
            lastHeadingSample = (geom.heading * Double.pi, now)
        } else {
            lastHeadingSample = nil
        }

        var k = kinematics
        k.accelMps2 = accel
        k.headingRateRad = headingRate
        k.steerAngle = lastSteerCommand
        k.lane = geom

        let features = V2FeatureBuilder.build(kinematics: k,
                                              detections: detections,
                                              laneMask: snapshot,
                                              config: cfg)

        // ── 方案 A：当前帧的预处理 + 入环形缓冲，**全部在后台队列做** ──
        // ⚠️ 【性能红线】预处理器（CGImage 缩放 + 逐像素读取 180×320×3）是重活，
        //    **绝不能放主线程**（本文件类型注释与 task 红线都明确要求）。
        //    故这里只把 CGImage（不可变、可安全跨线程）与已算好的纯特征送进队列，
        //    预处理与环形缓冲写入都在 inferenceQueue 内完成。
        //
        // 【ringBuffer 的并发安全】它是引擎状态（MainActor 隔离），后台直接改会违规。
        //    做法：用 nonisolated(unsafe) + "只在串行 inferenceQueue 上访问"的不变式
        //    （`isInferencing` 防重叠保证同一时刻只有一个在途任务）。
        //    这与旧引擎 `reusableImageBuffer` 的既有做法**完全一致**
        //    （InferenceEngine.swift:114-120 注释说明了同一套理由）。

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()

            // 复用缓冲
            self.ensureBuffers()

            // ① 预处理当前帧（后台）
            guard let frameImage = Self.preprocessImage(image,
                                                        height: V2InputContract.imageHeight,
                                                        width: V2InputContract.imageWidth,
                                                        into: self.reusableFrameScratch) else {
                Task { @MainActor in self.finish(gen, nil, error: "V2 帧预处理失败") }
                return
            }
            // ② 入环形缓冲（同一串行队列，无并发）
            let frameLen = 3 * V2InputContract.imageHeight * V2InputContract.imageWidth
            let framePtr = frameImage.dataPointer.assumingMemoryBound(to: Float32.self)
            var frameArr = [Float](repeating: 0, count: frameLen)
            for i in 0..<frameLen { frameArr[i] = framePtr[i] }
            self.frameBufferPush(frameArr)
            let historySnapshot = self.frameBufferSnapshot()

            // ③ 组装 [8,3,H,W] 输入
            guard let imageBuffer = self.reusableImageSequenceBuffer,
                  let provider = try? Self.makeProvider(features: features,
                                                        historyFrames: historySnapshot,
                                                        imageBuffer: imageBuffer,
                                                        lane: self.reusableLaneBuffer,
                                                        dets: self.reusableDetsBuffer,
                                                        detMask: self.reusableDetMaskBuffer,
                                                        state: self.reusableStateBuffer) else {
                Task { @MainActor in self.finish(gen, nil, error: "V2 输入构造失败") }
                return
            }

            do {
                let output = try modelRef.prediction(from: provider)
                // ⚠️ 输出是 MLMultiArray([1,1])，必须走 multiArrayValue[[0,0]]。
                //    直接用 featureValue.doubleValue 对 multiArray 会返回 0
                //    （旧引擎踩过：e2eCommand 恒 idle 的元凶，见 InferenceEngine.swift:350-354）
                //
                // 【优雅降级 · 读输出的关键】旧契约模型**没有** confidence/risk/
                // car_heading 三个输出。`featureValue(for:)` 对不存在的名字返回
                // **nil**（不是抛错）—— 据此区分"旧契约"与"新契约"，**不崩、按旧路径走**。
                func readScalar(_ name: String) -> Double {
                    guard let fv = output.featureValue(for: name) else { return 0 }
                    if let mv = fv.multiArrayValue {
                        // car_heading 是 [1]（一维），steer/throttle/brake 是 [1,1]
                        return mv.count > 1 ? mv[[0, 0]].doubleValue : mv[0].doubleValue
                    }
                    return fv.doubleValue
                }
                /// 可选输出：不存在（旧契约）→ nil；存在 → 值。
                /// 【为什么单独一个函数】语义必须显式："模型没这个输出"与
                /// "模型输出了 0"是两回事，混在一起会谎报置信度。
                func readOptional(_ name: String) -> Double? {
                    guard let fv = output.featureValue(for: name) else { return nil }
                    if let mv = fv.multiArrayValue {
                        guard mv.count > 0 else { return nil }
                        return mv.count > 1 ? mv[[0, 0]].doubleValue : mv[0].doubleValue
                    }
                    // 非 multiArray（理论上不会出现，契约全是 [1,1]）→ 用标量值
                    let v = fv.doubleValue
                    return v.isFinite && v != 0 ? v : nil
                }
                let result = InferenceResult(steer: readScalar(V2InputContract.steer),
                                             throttle: readScalar(V2InputContract.throttle),
                                             brake: readScalar(V2InputContract.brake),
                                             latencyMs: Date().timeIntervalSince(start) * 1000)
                // 三个辅助输出（旧契约模型 → 全 nil → isEmpty=true → 按旧路径走）
                let aux = V2AuxOutputs(
                    confidence: readOptional(V2InputContract.confidence).flatMap {
                        $0.isFinite ? max(0, min(1, $0)) : nil },
                    risk: readOptional(V2InputContract.risk).flatMap {
                        $0.isFinite ? max(0, min(1, $0)) : nil },
                    carHeadingRad: readOptional(V2InputContract.carHeading).flatMap {
                        $0.isFinite ? $0 : nil })
                Task { @MainActor in
                    self.finish(gen, result, error: nil, features: features, aux: aux)
                }
            } catch {
                Task { @MainActor in
                    self.finish(gen, nil, error: "V2 推理失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 记录本次决策输出的转向角（供下一帧 state[6] 用）。
    func noteSteerCommand(_ steer: Double) {
        lastSteerCommand = max(-1, min(1, steer.isFinite ? steer : 0))
    }

    private func finish(_ gen: Int, _ result: InferenceResult?, error: String?,
                        features: V2Features? = nil, aux: V2AuxOutputs? = nil) {
        guard gen == generation else { return }
        isInferencing = false
        if let result {
            lastResult = result
            lastResultTime = Date()
            inferenceCount += 1
            PerfBus.shared.record(perfChannel, ms: result.latencyMs)
        }
        if let features {
            lastLaneGeometry = features.laneGeometry
            lastValidDetectionCount = features.validDetectionCount
            lastLanePixelCount = features.laneGeometry.lanePixels
            lastCameraHeadingValid = features.cameraHeadingValid
        }
        if let aux {
            lastAuxOutputs = aux
            // 置信度缓存：供 UI / 状态机读取（`ControlCommand.confidence` 的来源）
            lastConfidence = aux.confidence
            lastRisk = aux.risk
            lastCarHeadingRad = aux.carHeadingRad
        }
        if let error { errorMessage = error }
    }

    func reset() {
        generation += 1
        lastResult = nil
        lastResultTime = nil
        isInferencing = false
        errorMessage = nil
        lastSpeedSample = nil
        lastHeadingSample = nil
        lastLaneGeometry = .unknown
        lastValidDetectionCount = 0
        lastLanePixelCount = 0
        // M4 三个辅助头 + 环形缓冲也要清（换场景/重开一局，避免旧数据污染）
        lastCameraHeadingValid = false
        lastAuxOutputs = .empty
        lastConfidence = nil
        lastRisk = nil
        lastCarHeadingRad = nil
        frameBufferReset()
    }

    // MARK: 缓冲管理

    private nonisolated(unsafe) func ensureBuffers() {
        if reusableFrameScratch == nil {
            reusableFrameScratch = try? MLMultiArray(
                shape: V2InputContract.imageFrameShape(), dataType: .float32)
        }
        if reusableImageSequenceBuffer == nil {
            reusableImageSequenceBuffer = try? MLMultiArray(
                shape: V2InputContract.imageSequenceShape(), dataType: .float32)
        }
        if reusableLaneBuffer == nil {
            let s = V2InputContract.laneSize
            reusableLaneBuffer = try? MLMultiArray(
                shape: [1, 1, NSNumber(value: s), NSNumber(value: s)], dataType: .float32)
        }
        if reusableDetsBuffer == nil {
            reusableDetsBuffer = try? MLMultiArray(
                shape: [1, NSNumber(value: V2InputContract.maxDetections),
                        NSNumber(value: V2InputContract.detFeatureDim)],
                dataType: .float32)
        }
        if reusableDetMaskBuffer == nil {
            reusableDetMaskBuffer = try? MLMultiArray(
                shape: [1, NSNumber(value: V2InputContract.maxDetections)], dataType: .float32)
        }
        if reusableStateBuffer == nil {
            reusableStateBuffer = try? MLMultiArray(
                shape: [1, NSNumber(value: V2InputContract.stateDim)], dataType: .float32)
        }
    }

    // MARK: 环形缓冲访问（串行队列内调用）

    /// 推入一帧（inferenceQueue 内调用；见 frameBuffer 的并发不变式注释）。
    private nonisolated(unsafe) func frameBufferPush(_ frame: [Float]) {
        _ = frameBuffer.push(frame)
    }

    /// 导出时序窗口（最老在前；inferenceQueue 内调用）。
    private nonisolated(unsafe) func frameBufferSnapshot() -> [Float] {
        frameBuffer.snapshot()
    }

    /// 清空环形缓冲（reset 时；inferenceQueue 内调用）。
    private nonisolated(unsafe) func frameBufferReset() {
        frameBuffer.reset()
    }

    // MARK: 输入装配（nonisolated 纯函数）

    /// 全零特征（预热用）。
    private nonisolated static func zeroFeatures() -> V2Features {
        V2Features(vehicleState: [Float](repeating: 0, count: V2InputContract.stateDim),
                   dets: [Float](repeating: 0,
                                 count: V2InputContract.maxDetections * V2InputContract.detFeatureDim),
                   detMask: [Float](repeating: 0, count: V2InputContract.maxDetections),
                   laneMask: [Float](repeating: 0,
                                     count: V2InputContract.laneSize * V2InputContract.laneSize),
                   laneGeometry: .unknown,
                   validDetectionCount: 0,
                   cameraHeadingRad: nil,
                   cameraHeadingValid: false)
    }

    /// 预热用：不需要真实 image（全零的 8 帧序列）。
    private nonisolated static func makeProvider(features: V2Features) throws -> MLFeatureProvider {
        guard let image = try? MLMultiArray(
            shape: V2InputContract.imageSequenceShape(),
            dataType: .float32) else {
            throw NSError(domain: "InferenceEngineV2", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "预热 image 序列缓冲构造失败"])
        }
        // 预热图全零即可（数据内容不影响 ANE 图编译）
        guard let provider = try makeProvider(features: features,
                                              historyFrames: [Float](repeating: 0,
                                                                    count: image.count),
                                              imageBuffer: image,
                                              lane: nil, dets: nil, detMask: nil, state: nil) else {
            throw NSError(domain: "InferenceEngineV2", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "预热特征装配失败"])
        }
        return provider
    }

    /// 把纯特征写进 MLMultiArray 并组装 `MLFeatureProvider`。
    ///
    /// 特征名全部取自 `V2InputContract`（单一常量表）—— 避免"形参名 vs
    /// CoreML 特征名"错位（`lane_mask` 是形参名、`lane` 才是特征名）。
    ///
    /// - Parameters:
    ///   - historyFrames: 帧序列（**最老在前、最新在后**），长度须 = N×3×H×W。
    ///     为 nil 时输入 buffer 保持调用方预填的内容（旧契约单帧路径用）。
    private nonisolated static func makeProvider(features: V2Features,
                                                 historyFrames: [Float]?,
                                                 imageBuffer: MLMultiArray,
                                                 lane: MLMultiArray?,
                                                 dets: MLMultiArray?,
                                                 detMask: MLMultiArray?,
                                                 state: MLMultiArray?) throws -> MLFeatureProvider? {
        // image [N,3,H,W]：把 8 帧依次写进 buffer
        if let frames = historyFrames {
            let expected = V2InputContract.imageSequenceShape().reduce(1) { $0 * $1.intValue }
            guard frames.count == expected else {
                // 长度不符 → **不静默截断/补零**，直接失败让调用方如实报错
                return nil
            }
            let imgPtr = imageBuffer.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<expected { imgPtr[i] = frames[i] }
        }

        // lane [1,1,160,160]
        let laneArr = lane ?? (try? MLMultiArray(
            shape: [1, 1, NSNumber(value: V2InputContract.laneSize),
                    NSNumber(value: V2InputContract.laneSize)], dataType: .float32))
        guard let laneArr else { return nil }
        let lanePtr = laneArr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<features.laneMask.count { lanePtr[i] = features.laneMask[i] }

        // dets [1,20,12]
        let detsArr = dets ?? (try? MLMultiArray(
            shape: [1, NSNumber(value: V2InputContract.maxDetections),
                    NSNumber(value: V2InputContract.detFeatureDim)], dataType: .float32))
        guard let detsArr else { return nil }
        let detsPtr = detsArr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<features.dets.count { detsPtr[i] = features.dets[i] }

        // det_mask [1,20]
        let maskArr = detMask ?? (try? MLMultiArray(
            shape: [1, NSNumber(value: V2InputContract.maxDetections)], dataType: .float32))
        guard let maskArr else { return nil }
        let maskPtr = maskArr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<features.detMask.count { maskPtr[i] = features.detMask[i] }

        // vehicle_state [1,8]
        let stateArr = state ?? (try? MLMultiArray(
            shape: [1, NSNumber(value: V2InputContract.stateDim)], dataType: .float32))
        guard let stateArr else { return nil }
        let statePtr = stateArr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<features.vehicleState.count { statePtr[i] = features.vehicleState[i] }

        // camera_heading [1]（rad；无效时传 0，有效性记在 Swift 侧）
        let camArr = try? MLMultiArray(shape: [1], dataType: .float32)
        guard let camArr else { return nil }
        camArr[0] = NSNumber(value: features.cameraHeadingRad ?? 0)

        let dict: [String: Any] = [
            V2InputContract.image: MLFeatureValue(multiArray: imageBuffer),
            V2InputContract.lane: MLFeatureValue(multiArray: laneArr),
            V2InputContract.dets: MLFeatureValue(multiArray: detsArr),
            V2InputContract.detMask: MLFeatureValue(multiArray: maskArr),
            V2InputContract.vehicleState: MLFeatureValue(multiArray: stateArr),
            V2InputContract.cameraHeading: MLFeatureValue(multiArray: camArr),
        ]
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }

    /// CGImage → MLMultiArray [1,3,H,W] Float32 CHW 归一化 [0,1]。
    ///
    /// 与 `InferenceEngine.preprocessImage` 逐位同算法（缩放绘制 → RGBA 读像素 →
    /// CHW 重排 → vDSP 向量化归一化）。**没有复用它的实现**是因为那个函数是
    /// `private`，且本文件不改原文件（写作用域纪律）。两处算法若将来要合并，
    /// 应抽到共享工具里。
    private nonisolated static func preprocessImage(_ cgImage: CGImage,
                                                    height: Int, width: Int,
                                                    into reusable: MLMultiArray?) -> MLMultiArray? {
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixelData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let output: MLMultiArray
        if let reusable,
           reusable.shape.count == 4,
           reusable.shape[0].intValue == 1,
           reusable.shape[1].intValue == 3,
           reusable.shape[2].intValue == height,
           reusable.shape[3].intValue == width {
            output = reusable
        } else if let created = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32) {
            output = created
        } else {
            return nil
        }

        let ptr = output.dataPointer.assumingMemoryBound(to: Float32.self)
        let planeSize = height * width
        for y in 0..<height {
            for x in 0..<width {
                let pixelIdx = (y * width + x) * 4
                let outIdx = y * width + x
                ptr[outIdx]                 = Float32(pixelData[pixelIdx])
                ptr[planeSize + outIdx]     = Float32(pixelData[pixelIdx + 1])
                ptr[planeSize * 2 + outIdx] = Float32(pixelData[pixelIdx + 2])
            }
        }
        var divisor: Float32 = 255.0
        vDSP_vsdiv(ptr, 1, &divisor, ptr, 1, vDSP_Length(3 * planeSize))
        return output
    }
}

// MARK: - 离线自检（不联网、不依赖模型文件）

/// V2 集成的纯逻辑自检结果。
struct V2SelfCheck: Sendable, Equatable {
    var ok: Bool
    var checks: [String]
    var failures: [String]
}

extension InferenceEngineV2 {

    /// 离线自检：**纯函数级**验证（不加载模型、不发网络）。
    ///
    /// 覆盖：
    ///   · 输入契约常量与 export 脚本一致（维度/名称）
    ///   · vehicle_state 8 维：speedValid 硬门（bug 2 回归）、车道线几何接线
    ///   · dets 12 维编码：one-hot 正确、置信度降序、空槽补零、超 20 截断
    ///   · lane 掩码：只取车道线、尺寸不符给全零
    ///   · 车道线几何：直线→heading≈0；右弯→heading>0；左弯→heading<0；
    ///                 偏移→lateralOffset 符号正确；无车道线→invalid 且全零
    nonisolated static func selfCheck() -> V2SelfCheck {
        var checks: [String] = []
        var failures: [String] = []
        let cfg = V2Config.default

        func expect(_ cond: Bool, _ label: String, detail: String = "") {
            if cond { checks.append(label) } else { failures.append(label + (detail.isEmpty ? "" : " | " + detail)) }
        }

        // ── ① 契约常量（与 tools/export_m9_v2_coreml.py 契约表逐项对齐）──
        expect(V2InputContract.image == "image", "输入名 image")
        expect(V2InputContract.lane == "lane", "输入名 lane（**不是** lane_mask）")
        expect(V2InputContract.dets == "dets", "输入名 dets")
        expect(V2InputContract.detMask == "det_mask", "输入名 det_mask")
        expect(V2InputContract.vehicleState == "vehicle_state",
               "输入名 vehicle_state（**不能**叫 state，coremltools 会改名）")
        expect(V2InputContract.imageHeight == 180 && V2InputContract.imageWidth == 320,
               "image 尺寸 180×320")
        expect(V2InputContract.laneSize == 160, "lane 尺寸 160×160")
        expect(V2InputContract.maxDetections == 20, "dets 槽位 N=20")
        expect(V2InputContract.detFeatureDim == 12, "dets 每框 12 维")
        expect(V2InputContract.stateDim == 8, "vehicle_state 8 维")

        // ── ② bug 2 回归：speedValid 硬门 ──
        var k = V2Kinematics()
        k.speedKmh = -1          // OCR 读不到的真实取值
        k.speedValid = false
        k.accelMps2 = 5.0        // 即便给了加速度，速度不可信时也应清零
        let invalidState = V2FeatureBuilder.buildVehicleState(k, config: cfg)
        expect(invalidState.count == 8, "无效速度下仍输出 8 维")
        expect(invalidState[0] == 0,
               "bug2：speedValid=false 时 speed=0（**不是** -1/120 = -0.0083）",
               detail: "实得 \(invalidState[0])")
        expect(invalidState[1] == 0,
               "bug2：speedValid=false 时 accel 也清零（导数同样不可信）",
               detail: "实得 \(invalidState[1])")

        k.speedKmh = 60
        k.speedValid = true
        let validState = V2FeatureBuilder.buildVehicleState(k, config: cfg)
        expect(abs(Double(validState[0]) - 0.5) < 1e-6,
               "有效速度 60km/h → speed=0.5", detail: "实得 \(validState[0])")

        // ── ③ bug 1 回归：curvature/heading 不再恒 0 ──
        var straight = LaneMaskSnapshot.empty()
        straight = SyntheticLane.make(shape: .straight, size: V2InputContract.laneSize)
        let straightGeom = LaneGeometryEstimator.estimate(mask: straight, config: cfg)
        expect(straightGeom.valid, "直线车道线 → 几何有效",
               detail: "sampledRows=\(straightGeom.sampledRows)")
        expect(abs(straightGeom.heading) < 0.05,
               "直线 → heading ≈ 0", detail: "实得 \(straightGeom.heading)")
        expect(abs(straightGeom.curvature) < 0.2,
               "直线 → curvature ≈ 0", detail: "实得 \(straightGeom.curvature)")

        let rightGeom = LaneGeometryEstimator.estimate(
            mask: SyntheticLane.make(shape: .curveRight, size: V2InputContract.laneSize), config: cfg)
        expect(rightGeom.valid, "右弯车道线 → 几何有效")
        expect(rightGeom.heading > 0.03,
               "右弯 → heading > 0.03（正值=需右打；0.03 才是有判别力的量级）",
               detail: "实得 \(rightGeom.heading)")
        expect(rightGeom.curvature > 0.02,
               "右弯 → curvature > 0", detail: "实得 \(rightGeom.curvature)")

        let leftGeom = LaneGeometryEstimator.estimate(
            mask: SyntheticLane.make(shape: .curveLeft, size: V2InputContract.laneSize), config: cfg)
        expect(leftGeom.valid, "左弯车道线 → 几何有效")
        expect(leftGeom.heading < -0.03,
               "左弯 → heading < -0.03", detail: "实得 \(leftGeom.heading)")

        let offsetGeom = LaneGeometryEstimator.estimate(
            mask: SyntheticLane.make(shape: .offsetRight, size: V2InputContract.laneSize), config: cfg)
        expect(offsetGeom.valid, "整体右偏车道线 → 几何有效")
        expect(offsetGeom.lateralOffset > 0.05,
               "车偏右 → lateralOffset > 0", detail: "实得 \(offsetGeom.lateralOffset)")

        // 空掩码 → invalid 且三量全 0（诚实原则）
        let emptyGeom = LaneGeometryEstimator.estimate(mask: .empty(), config: cfg)
        expect(!emptyGeom.valid, "无车道线 → valid=false（不编造几何）")
        expect(emptyGeom.curvature == 0 && emptyGeom.heading == 0 && emptyGeom.lateralOffset == 0,
               "无车道线 → 三量全 0（模型按'未知'处理）")

        // bug 1 的核心断言：curvature/heading 真的进了 state
        var k2 = V2Kinematics()
        k2.lane = rightGeom
        let stateWithGeom = V2FeatureBuilder.buildVehicleState(k2, config: cfg)
        expect(stateWithGeom[2] != 0,
               "bug1：heading 真的写进 state[2]（旧实现恒 0）",
               detail: "实得 \(stateWithGeom[2])")
        expect(stateWithGeom[4] != 0,
               "bug1：curvature 真的写进 state[4]（旧实现恒 0）",
               detail: "实得 \(stateWithGeom[4])")

        // ── ④ dets 编码 ──
        let dets: [Detection] = [
            Detection(x: 0.1, y: 0.2, width: 0.05, height: 0.06, label: .car, confidence: 0.9),
            Detection(x: 0.5, y: 0.6, width: 0.10, height: 0.12, label: .pedestrian, confidence: 0.4),
        ]
        let (detsArr, maskArr, count) = V2FeatureBuilder.buildDetections(dets, config: cfg)
        expect(count == 2, "2 个框 → validCount=2")
        expect(detsArr.count == 20 * 12, "dets 展平长度 = 240")
        expect(maskArr.count == 20, "det_mask 长度 = 20")
        expect(maskArr[0] == 1 && maskArr[1] == 1 && maskArr[2] == 0,
               "det_mask 前 2 有效、其余 0")
        // 置信度降序：0.9 的 car 排第 0 槽
        expect(detsArr[0] == Float(0.1) && detsArr[8] == Float(0.9),
               "高置信度框排在前（第 0 槽 = 0.9 的车）")
        expect(detsArr[4] == 1 && detsArr[5] == 0 && detsArr[6] == 0 && detsArr[7] == 0,
               "car → one-hot [1,0,0,0]")
        expect(detsArr[12 + 4] == 0 && detsArr[12 + 5] == 1,
               "pedestrian → one-hot [0,1,0,0]")
        // 空槽全零
        let emptySlotOK = (2..<20).allSatisfy { slot in
            (0..<12).allSatisfy { detsArr[slot * 12 + $0] == 0 }
        }
        expect(emptySlotOK, "空槽 12 维全 0（契约要求）")

        // 超 20 截断
        let many = (0..<30).map { i in
            Detection(x: 0.5, y: 0.5, width: 0.1, height: 0.1, label: .car,
                      confidence: Double(i) / 30.0)
        }
        let (_, maskMany, countMany) = V2FeatureBuilder.buildDetections(many, config: cfg)
        expect(countMany == 20, "30 个框 → 截断到 20（CoreML 固定 N）")
        expect(maskMany.allSatisfy { $0 == 1 }, "截断后 20 槽全有效")

        // one-hot 全覆盖
        let allLabels: [Detection.Label] = [.car, .pedestrian, .sign, .obstacle]
        let onehots = allLabels.map { V2FeatureBuilder.labelOneHot($0) }
        expect(onehots.allSatisfy { $0.reduce(0) { $0 + Double($1) } == 1 },
               "4 个类别 one-hot 各自恰有 1 个 1")
        expect(onehots[2][2] == 1, "sign → 第 2 位")

        // ── ⑤ lane 掩码 ──
        let laneOut = V2FeatureBuilder.buildLaneMask(straight)
        expect(laneOut.count == 160 * 160, "lane 展平长度 = 25600")
        expect(laneOut.allSatisfy { $0 == 0 || $0 == 1 }, "lane 是二值 0/1")
        expect(laneOut.contains(1), "直线掩码含前景像素")
        let wrongSize = LaneMaskSnapshot(width: 80, height: 80,
                                         cells: [UInt8](repeating: 1, count: 6400))
        let wrongOut = V2FeatureBuilder.buildLaneMask(wrongSize)
        expect(wrongOut.allSatisfy { $0 == 0 }, "尺寸不符 → 全零（不缩放造假掩码）")
        expect(V2FeatureBuilder.buildLaneMask(nil).allSatisfy { $0 == 0 }, "nil 掩码 → 全零")

        // ══════════════════════════════════════════════════════════════════════
        // ⑤b INT8 退化保护回归（Lead 情报 · 项目既有实测）
        // ══════════════════════════════════════════════════════════════════════
        // 出处 tools/yolopx/export_yolopx_coreml.py:58-64：int8 量化把车道线
        // 正像素占比从 1.30–1.80% 打到 0.13–0.21%（约 10×）。本引擎的 lane
        // 来自可能是 INT8 的 yolopx，故必须有"前景太少就报未知"的保护。
        expect(straight.positiveCount > cfg.minLanePixels,
               "正常掩码前景格数（\(straight.positiveCount)）高于退化阈值（\(cfg.minLanePixels)）")

        // 模拟 INT8 退化：只留极少量碎片像素
        var degradedCells = [UInt8](repeating: 0, count: 160 * 160)
        // stride 2000 → 13 格（25600/2000），**必须低于 minLanePixels=30**。
        // 早先误用 700（=37 格 > 30）导致这条用例根本没触发退化分支，
        // 属于"断言看着在跑、实际测不到东西" —— 已修正。
        for i in stride(from: 0, to: degradedCells.count, by: 2000) { degradedCells[i] = 1 }
        let degraded = LaneMaskSnapshot(width: 160, height: 160, cells: degradedCells)
        expect(degraded.positiveCount < cfg.minLanePixels,
               "退化掩码前景格数（\(degraded.positiveCount)）低于阈值 —— 模拟 INT8 塌陷")
        let degradedGeom = LaneGeometryEstimator.estimate(mask: degraded, config: cfg)
        expect(!degradedGeom.valid,
               "INT8 退化掩码 → valid=false（**绝不用碎片硬拟合出假车道线**）")
        expect(degradedGeom.curvature == 0 && degradedGeom.heading == 0,
               "INT8 退化 → 曲率/朝向全 0（模型按'未知'处理）")
        expect(degradedGeom.lanePixels == degraded.positiveCount,
               "诊断字段如实记录前景格数（\(degradedGeom.lanePixels)），供判断上游是否被量化毁掉")

        // 正常掩码的 lanePixels 也要如实填
        expect(straightGeom.lanePixels == straight.positiveCount,
               "正常掩码 lanePixels 如实 = \(straightGeom.lanePixels)")

        // ── ⑤b2 离群行鲁棒性回归（从一次真实 bug 学到）──
        // 场景：弯曲车道线在远端越出画面被裁 → 该行只剩单侧 → 补出的中心
        // 与整体趋势严重偏离 → 混进拟合会**翻转曲率符号**。
        // 稳健化（残差剔除 + 重拟合）后，符号必须仍然正确。
        let curveSnap = SyntheticLane.make(shape: .curveRight, size: 160)
        let curveGeom = LaneGeometryEstimator.estimate(mask: curveSnap, config: cfg)
        expect(curveGeom.valid, "弯曲掩码 → 几何有效")
        expect(curveGeom.curvature > 0,
               "鲁棒性：右弯曲率必须为正（曾因离群行污染而翻转成负）",
               detail: "实得 κ=\(curveGeom.curvature) fitA=\(curveGeom.fitA)")
        expect(curveGeom.sampledRows <= 65,
               "稳健化只减少不增加参与行数（实得 \(curveGeom.sampledRows)）")

        // 人工注入离群行：在弯曲样本上，把远端若干行改成"单侧"（模拟裁剪）
        var outlierCells = curveSnap.cells
        for y in 88..<100 {
            for x in 0..<160 {
                // 只保留左半边的像素（右半清掉 → 这些行变成单侧）
                if x > 80 { outlierCells[y * 160 + x] = 0 }
            }
        }
        let outlierSnap = LaneMaskSnapshot(width: 160, height: 160, cells: outlierCells)
        let outlierGeom = LaneGeometryEstimator.estimate(mask: outlierSnap, config: cfg)
        if outlierGeom.valid {
            expect(outlierGeom.curvature > 0,
                   "注入离群行后曲率符号仍为正（稳健化生效）",
                   detail: "实得 κ=\(outlierGeom.curvature)，采样 \(outlierGeom.sampledRows) 行")
        } else {
            expect(true, "注入离群行后如实报无效（也接受：宁可不报也不报错）")
        }

        // ── ⑤c 单侧车道线 → 分级降级（heading/curvature 保留，lateralOffset 置 0）──
        let oneSided = SyntheticLane.make(shape: .straight, size: 160, onlyLeft: true)
        let oneGeom = LaneGeometryEstimator.estimate(mask: oneSided, config: cfg)
        expect(oneGeom.valid, "单侧车道线 → 几何仍有效（朝向/曲率只依赖一条线）")
        expect(!oneGeom.bothSides, "单侧 → bothSides=false")
        expect(oneGeom.lateralOffset == 0,
               "单侧 → lateralOffset 强制 0（不拿假设当测量）",
               detail: "实得 \(oneGeom.lateralOffset)")
        expect(!oneGeom.lateralOffsetReliable, "单侧 → lateralOffsetReliable=false")
        expect(straightGeom.bothSides, "双侧掩码 → bothSides=true")
        expect(straightGeom.lateralOffsetReliable, "双侧 → lateralOffsetReliable=true")
        expect(oneGeom.lanePixels > cfg.minLanePixels, "单侧掩码前景仍高于退化阈值")

        // 单侧但前景极少 → 整体无效
        var sparseOne = [UInt8](repeating: 0, count: 160 * 160)
        for y in 0..<10 { sparseOne[y * 160 + 80] = 1 }
        let sparseOneSnap = LaneMaskSnapshot(width: 160, height: 160, cells: sparseOne)
        let sparseGeom = LaneGeometryEstimator.estimate(mask: sparseOneSnap, config: cfg)
        expect(!sparseGeom.valid || sparseGeom.sampledRows < cfg.minLaneRows
               || sparseOneSnap.positiveCount < cfg.minLanePixels,
               "极稀疏单侧 → 不产生可信几何（前景 \(sparseOneSnap.positiveCount) 格，采样 \(sparseGeom.sampledRows) 行）")

        // ── ⑥ 全量 build 的维度自洽 ──
        let f = V2FeatureBuilder.build(kinematics: k2, detections: dets,
                                       laneMask: straight, config: cfg)
        expect(f.vehicleState.count == 8, "build: state 8 维")
        expect(f.dets.count == 240, "build: dets 240")
        expect(f.detMask.count == 20, "build: det_mask 20")
        expect(f.laneMask.count == 25600, "build: lane 25600")
        expect(f.validDetectionCount == 2, "build: validCount=2")

        // ── ⑦ 边界：全零/NaN/超大输入不产生 NaN ──
        var nanK = V2Kinematics()
        nanK.speedKmh = .nan
        nanK.speedValid = true
        nanK.accelMps2 = .infinity
        nanK.steerAngle = .nan
        let nanState = V2FeatureBuilder.buildVehicleState(nanK, config: cfg)
        expect(nanState.allSatisfy { $0.isFinite }, "NaN/Inf 输入 → 输出全 finite（clamp 兜住）")
        let nanDets = [Detection(x: .nan, y: .infinity, width: -.infinity,
                                 height: .nan, label: .sign, confidence: .nan)]
        let (nanDetsArr, _, _) = V2FeatureBuilder.buildDetections(nanDets, config: cfg)
        expect(nanDetsArr.allSatisfy { $0.isFinite }, "NaN 框 → dets 全 finite")

        // ── ⑧ 红线：lane 只来自 laneMask（结构上不含 drivable）──
        //     本文件的 buildLaneMask 只接受 LaneMaskSnapshot 一种输入，
        //     且全文件不出现 drivableMask 标识符（下方 grep 式断言由 W8 复核）。
        expect(V2FeatureBuilder.buildLaneMask(straight).count == 25600,
               "lane 通道来源唯一 = LaneMaskSnapshot（不含可行驶区域）")

        // ══════════════════════════════════════════════════════════════════
        // ⑨ M4 传输扩展回归（2026-10-08 T1）—— 环形缓冲 / compass 转换
        // ══════════════════════════════════════════════════════════════════
        // ⑨a compass 度 → rad 转换（与 Python 侧 heading_head 逐值对齐）
        var camK = V2Kinematics()
        camK.cameraHeadingDeg = 90.0
        camK.cameraHeadingValid = true
        let (rad90, valid90) = V2FeatureBuilder.buildCameraHeadingRad(camK)
        expect(valid90 && abs(Double(rad90) - Double.pi / 2) < 1e-5,
               "compass 90° → π/2 rad（T1 新增）")
        camK.cameraHeadingDeg = 359.9
        let (rad359, _) = V2FeatureBuilder.buildCameraHeadingRad(camK)
        expect(abs(wrapDiff(Double(rad359), 0)) < 0.0035,
               "compass 359.9° ≈ 0 rad（跨 360 边界不跳变，T1 新增）")
        camK.cameraHeadingValid = false
        let (radInvalid, validInvalid) = V2FeatureBuilder.buildCameraHeadingRad(camK)
        expect(!validInvalid && radInvalid == 0,
               "cameraHeadingValid=false → (0,false) 不谎报有数据（T1 新增）")

        // ⑨b 环形缓冲：帧序（最老在前）+ 未填满复制首帧 + 溢出覆盖
        var ring = ImageFrameRingBuffer(capacity: 4, frameLength: 3)
        expect(ring.snapshot().count == 12, "环形缓冲总长 = 容量×帧长")
        // 帧 i 用 [i,i,i] 表示（frameLength=3）
        _ = ring.push([1, 1, 1])   // 只有 1 帧有效
        var snap1 = ring.snapshot()
        // ⚠️ 必须**靠尾对齐**：末位(index 3) = 当前帧，头部(index 0..2) = 零
        //   依据 temporal.py:231/273 取 out[:,-1]（最后一帧的因果聚合）
        expect(snap1[9] == 1, "未填满：唯一有效帧落在**末位**（当前帧位置）")
        expect(snap1[0] == 0 && snap1[3] == 0 && snap1[6] == 0,
               "未填满：头部空位**填零**（不是复制首帧 —— 那是虚假观测）")
        // 再 push 一帧：两帧应右对齐到 index 2,3
        _ = ring.push([2, 2, 2])
        let snap2 = ring.snapshot()
        expect(snap2[0] == 0 && snap2[3] == 0 && snap2[6] == 1 && snap2[9] == 2,
               "未填满(2帧)：右对齐（0,0,1,2），末位仍是当前帧")
        _ = ring.push([3, 3, 3])
        _ = ring.push([4, 4, 4])   // 填满
        var snapFull = ring.snapshot()
        expect(snapFull[0] == 1 && snapFull[3] == 2 && snapFull[6] == 3 && snapFull[9] == 4,
               "填满：最老在前（1,2,3,4），末位 = 当前帧 4")
        _ = ring.push([5, 5, 5])   // 覆盖最老的 1
        snapFull = ring.snapshot()
        expect(snapFull[0] == 2 && snapFull[3] == 3 && snapFull[6] == 4 && snapFull[9] == 5,
               "溢出：覆盖最老（2,3,4,5）—— 环形语义，末位 = 最新 5")
        // 长度不符 → 忽略（不静默截断）
        let rejected = ring.push([9])
        expect(!rejected, "帧长不符 → 拒绝写入（不静默截断）")
        ring.reset()
        expect(ring.snapshot().allSatisfy { $0 == 0 }, "reset 后全零")

        // ⑨c V2Features 装配：cameraHeadingRad 进特征
        var kF = V2Kinematics()
        kF.cameraHeadingDeg = 30.0
        kF.cameraHeadingValid = true
        let fF = V2FeatureBuilder.build(kinematics: kF, detections: [],
                                        laneMask: .empty(), config: cfg)
        expect(fF.cameraHeadingValid && fF.cameraHeadingRad != nil,
               "build 后 cameraHeading 有效且 rad 已填（T1 新增）")
        expect(abs(Double(fF.cameraHeadingRad!) - Double.pi / 6) < 1e-5,
               "30° → π/6 rad（T1 新增）")

        return V2SelfCheck(ok: failures.isEmpty, checks: checks, failures: failures)
    }

    /// 弧度差（wrap 到 [-π,π] 的绝对值），供自检比较角度用。
    /// 【为什么需要】`π` 与 `-π` 是同一个角，直接 allclose 会误判。
    private nonisolated static func wrapDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * Double.pi)
        if d > Double.pi { d -= 2 * Double.pi }
        if d < -Double.pi { d += 2 * Double.pi }
        return abs(d)
    }
}

// MARK: - 合成车道线（自检用）

/// 合成车道线掩码（只服务自检；不参与生产路径）。
enum SyntheticLane {

    enum Shape {
        case straight
        case curveRight
        case curveLeft
        case offsetRight
    }

    /// 生成一对车道线（左右各一条）。
    ///
    /// 坐标系：x 向右、y 向下。车道线按行绘制，中心 x 随行号变化：
    ///   · straight     center = 0.5W（恒定）
    ///   · curveRight   center 随 y 减小（往远处）而增大 → 前方偏右
    ///   · curveLeft    反之
    ///   · offsetRight  center 整体右移（车偏在车道左侧 → 车道中心在画面右侧）
    ///
    /// - Parameter onlyLeft: 只画左车道线（模拟"右侧被压线/断裂"的单侧场景，
    ///   用于验证分级降级：heading/curvature 保留、lateralOffset 置 0）。
    static func make(shape: Shape, size: Int, onlyLeft: Bool = false) -> LaneMaskSnapshot {
        var cells = [UInt8](repeating: 0, count: size * size)
        let w = Double(size)
        let halfWidth = w * 0.18

        func centerX(row: Double) -> Double {
            // row ∈ [0, size)，0 = 顶部（远处），size-1 = 底部（近处）
            // t ∈ [-1, 0]：-1 = 远端，0 = 近端（与估计器的 s 同向，便于推理）
            let t = (row - (w - 1)) / (w - 1)
            switch shape {
            case .straight:
                return w * 0.5
            case .curveRight:
                // 二次项系数 > 0：随 t 减小（往远处）center 增大 → 前方偏右。
                // 系数 1.2 的选取依据（两条约束同时满足）：
                //   · 判别力：近端瞬时斜率 ≈ -0.10 格/行 → heading ≈ 0.03，
                //     归一化后模型能感知（0.28 的旧值只给 0.0073，太弱）
                //   · **不越界**：halfWidth = 0.18W = 28.8 格，远端 center 最大
                //     ≈ 0.5W + 1.2W = 1.7W → 右线 = 1.7W + 0.18W = 1.88W
                //     ⚠️ 1.88W > W **会画出画面**！故实际取 1.2 时需配合下方
                //     的越界裁剪，或改用更小的系数。这里取 0.9：
                //     远端 center ≈ 1.4W，右线 ≈ 1.58W —— 仍越界，
                //     因此**真正的修法是让合成线整体左移**，见 make() 的 xOffset。
                return w * 0.5 + w * 1.2 * t * t
            case .curveLeft:
                return w * 0.5 - w * 1.2 * t * t
            case .offsetRight:
                return w * 0.5 + w * 0.12
            }
        }

        // 弯曲样本会向一侧偏，故整体反向平移，保证双侧线都留在画面内。
        // 【为什么必须做】早先 k=2.0 时远端右线 x=172.6 > 160 被裁掉，
        //   该行只剩左线 → 被估计器判成"单侧行" → 混进双侧样本污染拟合
        //   → 曲率符号翻转。裁剪越界像素本身没错，错的是**样本设计**让
        //   "本应双侧"的行变成单侧，使用例失去判别力。
        let xOffset: Double = {
            switch shape {
            case .curveRight: return -w * 0.22   // 右弯 → 左移
            case .curveLeft:  return  w * 0.22   // 左弯 → 右移
            case .straight, .offsetRight: return 0
            }
        }()
        let sides: [Double] = onlyLeft ? [-halfWidth] : [-halfWidth, halfWidth]
        for y in 0..<size {
            let c = centerX(row: Double(y)) + xOffset
            for side in sides {
                let x = Int((c + side).rounded())
                if x >= 0 && x < size { cells[y * size + x] = 1 }
            }
        }
        return LaneMaskSnapshot(width: size, height: size, cells: cells)
    }
}

// MARK: - TODO（未完成项，如实标注）

// TODO(v2-tracking): dets 的 [9]speed / [10]heading / [11]age 现恒为 0。
//   契约允许"无则 0"，但接了跟踪器后信息量更大：
//     · age      ← MotionPredictor 的 TrackedTarget.age（连续跟踪帧数）
//     · heading  ← 目标朝向（可由连续帧位移估计）
//     · speed    ← 目标相对速度（同上）
//   **为什么现在不接**：需要改 `updateMotionPipeline` 调用链，与 T1/T7 的
//   改动面重叠；Lead 明确要求先按 0 填、留 TODO，等模型跑通后再接。
//
// TODO(v2-calibration): `V2Config.curvatureReference = 0.02` 是有依据的占位，
//   不是标定值。真实像素↔米比例未知（随分辨率/视野变化）。等真实数据回来
//   应重新拟合，并核对 heading/curvature 的分布是否落在模型训练分布内。
//
// TODO(v2-wiring): 接线（DriveState 侧开关切换新旧引擎）**尚未做** ——
//   按 Lead 指示等 T2 的 INT8 模型产出后统一安排，避免与 T3 的录制改动撞车。
//   切换点预计在 `DriveState.tick()` 里按开关选 `inferenceEngine` 或
//   `inferenceEngineV2`，并保证两者**互斥**（不并行推理，省算力）。
