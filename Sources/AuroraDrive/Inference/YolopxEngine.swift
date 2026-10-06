// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  YolopxEngine.swift — CoreML YOLOPX 三合一感知引擎
//
//  职责：截屏画面 → 障碍框 [Detection] + 可行驶区掩码 + 车道线掩码
//
//  模型：models/yolopx/yolopx3_pal8_detfp.mlmodelc（首位候选，8 位调色板，精度 det 100%）
//        候选表见下方 `modelCandidates`，逐个实测加载、失败即换下一个。
//        由 tools/yolopx/export_yolopx_coreml.py 导出，对拍验证见
//        tools/yolopx/verify_yolopx_coreml.py
//
//  三个输出（实测形状）：
//    det  [1, 8400, 6]      cx, cy, w, h, obj_conf, cls_conf（640 输入像素坐标，未过 NMS）
//    da   [1, 2, 640, 640]  可行驶区二分类 logits
//    ll   [1, 2, 640, 640]  车道线二分类 logits
//
//  ⚠️ 与 YoloEngine(yolo26s) 的三点关键差异（接错任何一点都会静默出错）：
//    ① 输入是 **letterbox**（等比缩放 + 114 灰边），**不是**整帧拉伸。
//       模型在 BDD100K 上按 letterbox 训练；喂拉伸图会改变目标长宽比，
//       检测框与掩码都会整体走形。
//    ② det 头是 YOLOX（anchor-free），**输出未过 NMS**，坐标是 (cx,cy,w,h)。
//       yolo26s 是 NMS-free 端到端且直接给 (x1,y1,x2,y2)，故这里必须
//       自己做坐标变换 + NMS + 灰边区的框剔除。
//    ③ nc = 1 —— 只有「车」一类，全部映射到 Detection.Label.car。
//
//  与 YoloEngine 并存：本引擎独立加载、独立缓冲，不触碰现役检测链路，
//  出问题可直接停用本引擎回滚，零影响。
// ============================================================================

@preconcurrency import CoreML
import Accelerate
import CoreVideo
import Foundation
import Observation

// MARK: - 掩码网格

/// 二值掩码网格（letterbox 640 坐标系，按 gridStride 下采样后存储）。
///
/// 为什么下采样：da/ll 原始输出是 640×640×2 的 fp16 张量，逐帧搬 1.6MB
/// 给 UI/决策层既费带宽又费内存。按 4×4 多数表决降到 160×160（25KB/张），
/// 对「车道线在哪、前方可行驶占比多少」这类判断精度足够。
struct MaskGrid: Equatable {
    let width: Int
    let height: Int
    /// 行优先，0 = 背景，1 = 前景
    let cells: [UInt8]

    /// 读取一格是否为前景。
    ///
    /// ⚠️ 2026-09-27（R2-H1 修复）：原实现只守卫 `x/y`，**不守卫 `cells` 长度**。
    ///    `MaskGrid` 是 struct，合成构造器不校验 `cells.count == width*height`，
    ///    因此 `MaskGrid(width:160, height:160, cells:[UInt8](repeating:1, count:100))`
    ///    这类畸形值一旦进入 `LaneFallback.evaluate`，会在主线程 tick 内
    ///    触发 Swift 数组越界陷阱 **SIGTRAP（EXIT=133）→ 整个驾驶进程死亡**，
    ///    连同已按下的按键一起消失（fail-hard，与 fail-open 红线直接对立）。
    ///    崩溃隔离实测（每例独立进程）：cells 短于 width*height 的三个变体
    ///    修前一律 EXIT=133，钉死在 `LaneFallback.swift` 的偏差循环与 `ratio()` 循环。
    ///
    ///    现补长度守卫，且选择**返回 false（= 背景）而非崩溃/断言** ——
    ///    与 fail-open 红线语义一致：数据不可信时给"最保守的答案"，不是让车死掉。
    ///    额外收益：`cells` 长度是**每次调用都可校验**的不变式，因此将来任何
    ///    新增构造点（例如把掩码经共享内存传输后反序列化，见 R1-H3）都被这层兜住。
    @inline(__always)
    func at(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height,
              cells.count >= width * height else { return false }
        let idx = y * width + x
        guard idx >= 0, idx < cells.count else { return false }
        return cells[idx] != 0
    }

    /// 前景像素总数
    var positiveCount: Int {
        var n = 0
        for c in cells where c != 0 { n += 1 }
        return n
    }

    static let empty = MaskGrid(width: 0, height: 0, cells: [])
}

// MARK: - Letterbox 参数

/// 一次 letterbox 的几何参数，用于把 640 模型的坐标反变换回原帧。
///
/// 复刻官方 `lib/utils/augmentations.py::letterbox_for_img`：
///     r  = min(640/h, 640/w)          （scaleup 允许放大）
///     new_unpad = (round(w*r), round(h*r))
///     pad = (640 - new_unpad) / 2     （两侧均分，取整方式见 calculate）
struct LetterboxMetrics: Equatable {
    /// 缩放比
    let ratio: Double
    /// 左侧灰边宽度（640 坐标系）
    let padX: Int
    /// **顶部**灰边高度（640 坐标系，行 0 = 图顶）
    let padY: Int
    /// 底部灰边高度（用于反推绘制矩形；与 padY 最多差 1px）
    let padBottom: Int
    /// 缩放后内容宽（640 坐标系）
    let newW: Int
    /// 缩放后内容高（640 坐标系）
    let newH: Int
    /// 原帧宽（像素）
    let srcW: Int
    /// 原帧高（像素）
    let srcH: Int

    static let zero = LetterboxMetrics(ratio: 1, padX: 0, padY: 0, padBottom: 0,
                                       newW: 0, newH: 0, srcW: 0, srcH: 0)

    /// 640 模型像素坐标 → 原帧归一化坐标 [0,1]
    func toNormalized(x: Double, y: Double) -> (x: Double, y: Double) {
        guard ratio > 0, srcW > 0, srcH > 0 else { return (0, 0) }
        return ((x - Double(padX)) / ratio / Double(srcW),
                (y - Double(padY)) / ratio / Double(srcH))
    }

    /// 点是否落在 letterbox 灰边内（灰边上的检测/掩码均无效）
    ///
    /// ⚠️ 对称性假设（2026-09-26 明确记录）：本判定用 `padY + newH` 作为**下边**，
    ///    隐含假设"顶部灰边 == 底部灰边"（padY == padBottom）。当前 `calculate()`
    ///    用官方 `round(dh ∓ 0.1)` 算法，对 640 尺寸下所有常见宽高比实测均为对称
    ///    （16:9 / 16:10 / 21:9 / 方形 四例 padY 与 padBottom 完全相等）。
    ///    若将来允许非对称 padding，此处须改为显式传 padBottom 判定。
    @inline(__always)
    func isInPad(x: Double, y: Double) -> Bool {
        x < Double(padX) || x > Double(padX + newW)
            || y < Double(padY) || y > Double(padY + newH)
    }

    /// 绘制矩形在 CGContext 坐标系里的 y（CGContext 原点在**左下**，与缓冲区行序相反）。
    ///
    /// 目标：让内容落在缓冲区行 `[padY, padY + newH)`（行 0 = 图顶，与 Python
    /// letterbox 及 CoreML 的读图口径一致）。
    /// CGContext 里 y 从底边量起 → 绘制 y = size - padY - newH ≡ padBottom。
    var drawOriginY: Int { padBottom }

    /// 按官方算法算出 letterbox 参数（与 Python 端逐位一致）
    ///
    /// 官方 `letterbox_for_img`：
    ///     top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    ///     left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    /// 这里 padY 取 **top**（坐标映射用），padBottom 取 bottom（绘制用）。
    static func calculate(srcW: Int, srcH: Int, size: Int) -> LetterboxMetrics {
        guard srcW > 0, srcH > 0 else { return .zero }
        let r = min(Double(size) / Double(srcH), Double(size) / Double(srcW))
        let newW = Int((Double(srcW) * r).rounded())
        let newH = Int((Double(srcH) * r).rounded())
        let dw = Double(size - newW) / 2
        let dh = Double(size - newH) / 2
        // 官方用 int(round(dh - 0.1))：浮点边界上向下取整，避免右侧溢出
        let padX = Int((dw - 0.1).rounded())
        let padY = Int((dh - 0.1).rounded())          // = top
        let padBottom = Int((dh + 0.1).rounded())     // = bottom
        return LetterboxMetrics(ratio: r, padX: padX, padY: padY, padBottom: padBottom,
                                newW: newW, newH: newH, srcW: srcW, srcH: srcH)
    }
}

// MARK: - 引擎

// MARK: - 模型族

/// 感知模型族（2026-10-02 新增）。
///
/// 两个模型的三头输出里 **da / ll 逐位相同**（都是 `[1,2,640,640]` logits），
/// 唯一差别在 det 头：
///   · `.yolopx`  → `det [1, 8400, 6]` = cx, cy, w, h, **obj_conf**, cls_conf
///   · `.ayolom`  → `det [1, 5, 8400]` = cx, cy, w, h, **cls_conf**（无 obj_conf，需转置）
enum PerceptionModelFamily: String {
    case yolopx
    case ayolom

    /// 日志/诊断用的名字
    var display: String {
        switch self {
        case .yolopx: return "YOLOPX"
        case .ayolom: return "A-YOLOM"
        }
    }
}

// MARK: - 感知档位（UI 可选，2026-10-02 新增）

/// 用户可选的感知档位 —— 对应「模型选择」小窗口里的两个按钮。
///
/// 【用户原话 2026-10-02】「运行日志下面加一个小窗口……让他可以选，让用户可以
///   选择模型，就是默认选择这个 A 模型，然后还有一个档位，就是可以选择了
///   26S 加光流加 YOLOPX……然后可以让用户自己选择吧」
///
/// 【两档的实际含义】
///   · `.ayolom`（默认）：**只跑 A-YOLOM(n) int8** 一个三合一模型
///        3.8MB / ANE 上 p50 10.4ms → 95.9Hz / 30Hz 只占 31% 预算
///        检测 + 可行驶区 + 车道线三头全出，换来「一个模型吃掉两个」
///   · `.legacy`：**原来的三件套** —— yolo26s（检测）+ 光流（帧间外推）
///        + YOLOPX（三合一）。三条链路各自独立、各自有历史验证，
///        代价是模型大（41.4MB）且 YOLOPX 单帧约 183ms。
///
/// 【切换是运行时的】选中后立刻 `switchFamily` + `reloadModel()`，不需要重启。
enum PerceptionMode: String, CaseIterable, Identifiable {
    case ayolom = "A 模型"
    case legacy = "26S + 光流 + YOLOPX"

    var id: String { rawValue }

    /// 卡片上的主标题
    var title: String { rawValue }

    /// 副标题（一句话说清代价与收益）
    var subtitle: String {
        switch self {
        case .ayolom: return "单模型三合一 · 3.8MB · ANE 95Hz"
        case .legacy: return "26S 检测 + 光流外推 + YOLOPX 三合一"
        }
    }

    /// 映射到引擎的模型族
    var family: PerceptionModelFamily {
        switch self {
        case .ayolom: return .ayolom
        case .legacy: return .yolopx
        }
    }

    /// 该档位**是否依赖光流做帧间外推** —— 用于 UI 副标题与切换日志的说明文字。
    ///
    /// ⚠️ 诚实标注：本属性**目前只用于显示，不改变任何行为**。
    ///    `motionPredictor` / 光流链路对两个档位**照常运行**，原因是：
    ///      · 游标器（`predictorDetections`）喂的是 `yolopxEngine.detections`，
    ///        而两个档位共用同一个引擎实例，所以它天然对两档都生效；
    ///      · 关掉它会动到「模型输出频率不得下降」这条红线（R1），
    ///        而用户本次只要求「可选模型」，没有要求改光流行为。
    ///
    /// 【为什么标注这个区别】光流存在的原始理由是
    ///    「YOLOPX 单帧 183ms → 跑不到 30Hz → 用光流补中间帧」；
    ///    这个前提在 A-YOLOM 档**不成立**（ANE 上 p50 10.4ms → 95.9Hz，
    ///    30Hz 主循环下每帧都有真值）。将来若要关掉 A-YOLOM 档的光流，
    ///    这个属性就是那个开关的落点。
    var needsOpticalFlow: Bool {
        switch self {
        case .ayolom: return false
        case .legacy: return true
        }
    }
}

/// CoreML YOLOPX 三合一感知引擎
/// - @Observable：UI 可观察检测结果、掩码、耗时、降级状态
/// - @MainActor：可变状态主线程访问（推理在后台队列跑，结果回主线程写）
@Observable
@MainActor
final class YolopxEngine {

    // MARK: - 常量

    /// 模型输入边长（正方形）
    nonisolated static let inputSize = 640

    /// 掩码下采样后的网格边长（640 / 4 = 160）
    nonisolated static let maskGridSize = 160

    /// 模型文件名前缀（对应 models/yolopx/yolopx3_{tag}.mlmodelc）
    nonisolated static let modelBaseName = "yolopx3"

    /// 置信度阈值。官方 demo 默认 conf_thres=0.3；BDD100K 场景比游戏空旷，
    /// 游戏里目标更密集，酌情放宽到 0.25 提升召回。
    var confidenceThreshold: Double = 0.25

    /// NMS 的 IoU 阈值（与官方 demo 默认一致）
    var iouThreshold: Double = 0.45

    /// 单帧最多保留多少个框
    /// ⚠️ 路况六档判定要求「>70 框 → 极度复杂」，上限必须留足余量，
    ///    否则高阈值档位永远不可能触发（现役 YoloEngine 设 20 就踩了这个坑）。
    var maxDetections: Int = 300

    // MARK: - 降级判定阈值
    //
    // 实测依据（tools/yolopx/verify_yolopx_coreml.py ⑥）：
    //   正常 fp16/w8a16 的真实行车图输出 —— da 正像素 8.4~16.2%、ll 1.30~1.80%
    //   int8 全量化塌陷时 —— ll 掉到 0.13~0.21%（约 10×）
    // 取「车道线 < 0.2%」作为塌陷特征；da < 2% 作为整体失效特征。

    /// 车道线正像素占比下限（低于此判为车道线头失效）
    nonisolated static let lanePositiveFloor = 0.002

    /// 可行驶区正像素占比下限
    nonisolated static let drivablePositiveFloor = 0.02

    // ── 上限判据（2026-09-27 R2 反向验证补，t47）──
    //
    // 背景：原判定**只有下限没有上限**。实测（t31 §3.1 前景占比扫描）：
    //   ll 前景占比从 1.70% 一路涨到 38.89%（= 真实上限的 10 倍），
    //   `isDegraded` **全程为 false**，`LaneFallback` 全程照给建议、
    //   `confidence` 可达 1.00。
    //   而「大面积前景」正是 seg 头失效最典型的形态之一（与 int8 塌陷
    //   导致的前景骤减方向相反，但同样不可信）—— 一个"满屏都是车道线"
    //   的掩码会产出看似合法（steer=±0.25、conf=1.00）的建议，下游无从识别。
    //
    // 取值依据（**实测边距法，非分位标定**）：
    //
    // ⚠️ 2026-09-27 自我纠错记录（务必保留）：
    //    v1 稿按 t31 报告转述的「真实 ll 仅 1.3~3.9%」把 ll 上限设为 **0.10**。
    //    随后我用 pal8_detfp + **169 张真实行车图**（data/validation_clips，8 类工况）
    //    实测真实分布，发现该值**会被真实帧触发**：
    //      ll coverage  min=0.0000 P05=0.0002 P50=0.0266 P95=0.0694 **max=0.1072**
    //      da coverage  min=0.0000 P05=0.0102 P50=0.1159 P95=0.3237 **max=0.3812**
    //    即 0.10 的上限会在真实行驶中误判"降级"→ 兜底闭嘴（fail-open 方向安全，
    //    但属于**功能无谓失效**）。故上调 ll 至 0.25、da 至 0.70。
    //    **教训**：t31 报告的 1.3~3.9% 是 t30 时期少量素材的口径；用它的上限
    //    去定阈值等于把"样本上限"当"总体上限"。阈值必须以**当期全量实测**为准。
    //
    // v2 取值（本次）：
    //   ll 上限 0.25 —— 真实 max 0.1072 的 **2.33 倍**，169/169 真实帧全部放行；
    //                   而实测的 seg 大面积塌陷形态可达 **38.89%**（t31 §3.1）
    //                   → 该上限能抓住右侧极端塌陷，且与真实分布留有明显空档。
    //   da 上限 0.70 —— 真实 max 0.3812 的 **1.84 倍**；可行驶区头全屏塌陷时
    //                   占比趋近 1.0，同样留有空档。
    //
    // ⚠️ 诚实局限（务必保留，勿删）：
    //   ① 这是**边距法**（真实上限 × 安全系数），**不是**分布分位标定 ——
    //      与 t23 拒绝"凭感觉定阈值"的理由同源；现有素材不足以定分位数。
    //   ② **未覆盖区间**：ll 的 10.7%~25%、da 的 38.1%~70% 仍会被采纳。
    //      这是已知缺口，不是"已解决"。
    //   ③ 偏离方向有意选保守：上限偏松只漏掉部分塌陷；偏紧会误判降级。
    //      而"误判降级"的后果是兜底闭嘴（不介入），代价可控；反之让兜底
    //      基于崩塌掩码给转向才是危险方向。但**本次 v1 的 0.10 证明"偏紧"
    //      并非无害** —— 它会静默关掉兜底功能，故余量必须给足。
    //   ④ 待有"真实 seg 头崩塌"素材后应按分位数重标（属精度线任务）。

    /// 车道线正像素占比上限（高于此判为车道线头异常膨胀）
    /// 实测依据：169 张真实行车图 ll coverage max = 0.1072 → 取 2.33× 余量。
    nonisolated static let lanePositiveCeil = 0.25

    /// 可行驶区正像素占比上限（高于此判为可行驶区头异常膨胀）
    /// 实测依据：169 张真实行车图 da coverage max = 0.3812 → 取 1.84× 余量。
    nonisolated static let drivablePositiveCeil = 0.70

    // MARK: - 可观察状态

    /// 是否启用本引擎（停用后不推理，供一键回滚）
    /// ⚠️ 运维须知（2026-09-26 核实）：**无设置面板入口**，全仓库无 UI 绑定，
    ///    改动需改此代码常量并重编译（与 DriveState.preferYolopxDetections /
    ///    showYolopxMasks 同属"代码级开关"，注释勿写成像有按钮可点）。
    var enabled = true

    /// 模型是否已加载
    private(set) var isLoaded = false

    /// **实际加载成功**的模型文件名（未加载时为 nil）。
    ///
    /// ⚠️ 必须区别于「候选表里哪个文件存在」——**存在 ≠ 可加载**：
    ///   磁盘上 `yolopx3_w8a16.mlmodelc` 目录存在（fileExists 为真），
    ///   但它只有 `weights/weight.bin`，缺 `model.mil` / `metadata.json` /
    ///   `coremldata.bin`，`MLModel(contentsOf:)` 会直接抛错。
    ///   诊断与 fp16 告警一律读本字段，不要靠文件名猜测。
    private(set) var loadedModelName: String?

    /// 候选逐个尝试的记录（`候选名: 存在性/编译/加载 结果`），失败时也能看清卡在哪。
    private(set) var loadAttemptLog: [String] = []

    /// 错误信息（加载/推理失败）
    private(set) var errorMessage: String?

    /// 本帧检测框（归一化到原帧 [0,1]，与现役 Detection 契约一致）
    private(set) var detections: [Detection] = []

    /// 可行驶区掩码（letterbox 640 坐标系，下采样后）
    private(set) var drivableMask: MaskGrid = .empty

    /// 车道线掩码（letterbox 640 坐标系，下采样后）
    private(set) var laneMask: MaskGrid = .empty

    /// 本帧 letterbox 参数（掩码叠加显示要把 640 坐标映射回画面）
    private(set) var metrics: LetterboxMetrics = .zero

    /// 是否降级（掩码失效，决策层不得采信）
    /// 初始为 true —— 模型没跑起来之前一律视为不可信
    private(set) var isDegraded = true

    /// 车道线单独塌陷（**仅用于显示层**，不参与决策门控）
    ///
    /// ⚠️ 2026-09-27（用户报「只能看到检测框、看不到车道线」时排查确认）：
    ///    车道线是**细目标**，前景占比天然只有 1.3~2.6%，贴近下限阈值；
    ///    而 `isDegraded` 是 da/ll **或**关系的一个总开关。于是出现：
    ///      车道线信号弱 → `isDegraded = true` → 显示层 `dim = 0.35`
    ///      → 可行驶区透明度被压到 `0.18 × 0.35 = 0.063`（几乎不可见）
    ///    即**车道线的问题把可行驶区一起带暗了**，二者本无因果关系。
    ///
    ///    故拆出两个独立标志只给显示层用来分别调暗：
    ///      · `laneDegraded`     → 只压暗车道线
    ///      · `drivableDegraded` → 只压暗可行驶区
    ///    决策层继续用合并后的 `isDegraded`（语义不变，不引入新风险）。
    private(set) var laneDegraded = true

    /// 可行驶区单独塌陷（**仅用于显示层**，不参与决策门控）
    private(set) var drivableDegraded = true

    /// 最近一次推理耗时（毫秒）
    private(set) var lastLatencyMs: Double = 0

    /// 累计推理帧数
    private(set) var inferenceCount = 0

    /// 可行驶区前景占比（本帧，valid 区域内）
    private(set) var drivableRatio: Double = 0

    /// 车道线前景占比（本帧，valid 区域内）
    private(set) var laneRatio: Double = 0

    // MARK: - 内部状态

    @ObservationIgnored
    private var generation = 0

    @ObservationIgnored
    private var lastLoadAttempt = Date.distantPast

    /// 加载失败后的重试冷却（避免 30Hz 反复同步加载模型拖死主线程）
    @ObservationIgnored
    private let loadRetryCooldown: TimeInterval = 5.0

    @ObservationIgnored
    private var isInferencing = false

    @ObservationIgnored
    private nonisolated(unsafe) var model: MLModel?

    /// 推理队列。
    ///
    /// ⚠️ 2026-09-30 性能优化（第 2 批 D 项）：`.userInteractive` → `.userInitiated`。
    ///   理由：`.userInteractive` 是最高优先级，会与**游戏主线程**抢同样 4 个 P 核。
    ///   优先级只影响"谁先被调度"，不影响"算多久" —— 推理是 68.9ms 的批处理式长任务，
    ///   延后几百微秒开始对**出结果频率毫无影响**（基线与优化后都由 68.9ms 决定）。
    ///   注意：进程整体的 `nice=-20`（PrioritySetup 每 5s 维持）**不动** ——
    ///   那是 AuroraDrive 相对游戏的整体提权，与本处线程 QoS 是两个独立层级。
    ///   可用 `AURORA_INFER_QOS=interactive` 一键回退到此前的行为。
    @ObservationIgnored
    private let inferenceQueue: DispatchQueue = {
        let env = ProcessInfo.processInfo.environment["AURORA_INFER_QOS"]
        let qos: DispatchQoS = (env == "interactive") ? .userInteractive : .userInitiated
        return DispatchQueue(label: "com.aurora.yolopx", qos: qos)
    }()

    /// ★ A1：推理节拍（毫秒）。距上次**完成**超过此值才启动下一次。
    ///
    /// 【为什么需要】基线实测：yolopx **提交 241 次 / 完成 120 次** ——
    ///   一半提交被 `isInferencing` 门白扔。单次 68.9ms > tick 预算 33.3ms，
    ///   "每 tick 触发"只是让它在两次结果之间**空转争抢 CPU**。
    ///
    /// 【⚠️ 为什么默认 0 = 关闭 —— 实测教训】
    ///   曾默认设 90ms，ABBA 实测 yolopx **12.75 Hz → 5.02 Hz（掉 61%）**，
    ///   **违反 R1 红线**。根因：节拍是基于"上次完成时刻"的**固定间隔**，
    ///   而空载推理比游戏里快得多 —— 固定间隔反而成了**额外瓶颈**，
    ///   把"能跑多快"硬压到"间隔多大"。
    ///
    ///   ⟹ 正确语义应是「**完成即排下一次**」（自然背靠背，不引入人工间隔），
    ///     节拍只用于**限制过密提交**（如 tick 30Hz 而推理只需 12Hz 时，
    ///     避免每帧都做无用的输入准备）。故：
    ///        · 默认 0 = 关闭（行为与原实现一致）
    ///        · 若启用，值应 **小于典型单次推理耗时**（如 30ms），
    ///          作用只是"别在推理还没完成时白准备输入"
    ///
    /// 【已实现的更优保护】无节拍时也有天然保护：`isInferencing` 门 +
    ///   A2 把 letterbox 移进队列后，**无效提交的成本已从 10.5ms 降到 ~0.04ms**
    ///   （主线程只剩一次 guard 检查）—— 所以"每 tick 提交"现在几乎免费。
    @ObservationIgnored
    private let minInferenceIntervalMs: Double =
        ProcessInfo.processInfo.environment["AURORA_YOLOPX_INTERVAL_MS"]
            .flatMap(Double.init) ?? 0

    /// 上次推理**完成**的时刻（节拍判据用完成时间，不是提交时间）
    @ObservationIgnored
    private nonisolated(unsafe) var lastInferenceDoneAt: CFAbsoluteTime = 0

    /// ★ 阶段0（2026-10-01 审计修复）：letterbox 执行位置开关，**惰性读一次**。
    ///
    /// 【为什么加这个属性】A2 把 letterbox 移出主线程时，开关是**每帧现读**的：
    ///   ```
    ///   let letterboxOnMain = ProcessInfo.processInfo.environment[...] == "1"
    ///   ```
    ///   审计微基准实测 `ProcessInfo.environment[key]` = **17.213 µs/次**
    ///   （对照：已缓存字典取值 0.026 µs，慢 **660.8×**）。
    ///   yolopx 约 12Hz 提交 → **每秒白烧 0.207 ms**；A2 好不容易省下的
    ///   主线程时间（0.117 ms/帧）被这个读取**倒扣回去**。
    ///
    /// 【为什么放在这里就能解决】`let` + 闭包初始化 = 首次访问时读一次并缓存，
    ///   与上方 `inferenceQueue` / 下方 `minInferenceIntervalMs` 完全同款写法。
    ///   环境变量在进程生命周期内不可能变化，故语义与"每帧现读"**完全等价**。
    ///
    /// 【不改什么】变量名、默认值（未设 = false = 在推理队列画）、比较语义
    ///   （`== "1"`）全部逐字不变 —— 只是**读的时机**从每帧一次变成全生命周期一次。
    @ObservationIgnored
    private let letterboxOnMain: Bool = {
        ProcessInfo.processInfo.environment["AURORA_YOLOPX_LETTERBOX_MAIN"] == "1"
    }()

    /// 复用的输入像素缓冲（640×640 BGRA）
    @ObservationIgnored
    private nonisolated(unsafe) var inputBuffer: CVPixelBuffer?

    /// 掩码时序平滑累加器（EMA，跨帧去抖）
    @ObservationIgnored
    private nonisolated(unsafe) var drivableAccum: [Float] = []

    @ObservationIgnored
    private nonisolated(unsafe) var laneAccum: [Float] = []

    /// EMA 系数：新帧权重（越小越稳、越滞后）
    private nonisolated static let maskEMA = 0.35

    /// 平滑后的二值判定阈值
    private nonisolated static let maskThreshold: Float = 0.5

    /// 归一化常量（与导出脚本 IMAGENET_* 对应；归一化已烘进模型，这里仅注释留档）

    // MARK: - 模型定位

    /// 候选模型文件名（按优先级）。
    ///
    /// ⚠️ **本表是"尝试顺序"，不是"命中顺序"** —— 每个候选都会被真正加载一次，
    ///    加载失败（残缺产物/无法编译/无法加载）就继续下一个。详见 `loadFirstUsableModel()`。
    ///    这一点在 2026-09-26 修过一个致命 bug：旧实现只取"第一个**存在**的文件"
    ///    就交给单发 try/catch，于是挑中一个**存在但损坏**的候选即永久加载失败。
    ///
    /// 排序依据（2026-09-26 按精度实测重定）：
    ///   ① **精度优先**：`yolopx3_pal8_detfp` 是唯一精度达标的 8 位产物
    ///      （det 100% / da IoU 0.9930 / ll P 99.28%·R 98.15%），**置首位**。
    ///      注：它的 `storagePrecision` = "Mixed (Float16, Palettized (8 bits))"，
    ///      即**权重 8 位调色板 + 激活/输出 fp16**，与 w8a16 同属"8 位量化"家族，
    ///      不违反用户「禁 fp16、只允许 8 位」的红线（fp16 指权重位宽，不是输出 dtype）。
    ///   ② 其次 `w8a16`：同为 8 位家族，但**精度实测 det 仅 85%**（框数膨胀 7→12、15→29），
    ///      仅作 8 位内部的次选。
    ///   ③ `int8` 原为首选，但实测 **ll recall 仅 3.98%（架构性失败）**，且磁盘上
    ///      只有 `.mlpackage`（无 `.mlmodelc`）→ 降级为靠后候选。
    ///   ④ `.mlmodelc`（编译产物）优先于 `.mlpackage`：前者省去运行时编译。
    ///      对 `.mlpackage` 候选会走 `MLModel.compileModel(at:)`（与 SpeedOCRReader 同法），
    ///      编译成功才加载 —— 因此它们**不再是"假回退"**。
    ///   ⑤ fp16 仅作**最后兜底**：8 位全不可用时宁可跑起来也不让感知链整段缺位，
    ///      但会在日志与 `errorMessage` 里显式告警。
    ///
    /// ⚠️ **本表每一条都必须真实存在于 `models/yolopx/`**（2026-09-26 用 `ls` 逐条核对）。
    ///    原先表内的 `yolopx3_int8.mlmodelc` 与 `yolopx3_fp16.mlmodelc` **磁盘上并不存在**
    ///    （两者只有 `.mlpackage`），已按契约「不许写磁盘上不存在的模型文件名」移除。
    ///
    /// ⚠️ **磁盘上存在但刻意未纳入候选**：`yolopx3_w8a16_detfp.mlpackage`
    ///    （w8a16 权重 + det 头 fp16）。**因精度未记录，不凭推测接入生产回退链**，
    ///    仅在此留档；待有实测数据后再决定是否插入。
    ///
    /// ⚠️ **F1 交付后需二次更新候选首项**：本表首位当前是"已知最优"`pal8_detfp`；
    ///    待 E3→F1 生产产物交付且精度验收通过后，应把 F1 产物提到首位。
    // ══════════════════════════════════════════════════════════════════════
    // 模型族（2026-10-02 新增：A-YOLOM 接入）
    // ══════════════════════════════════════════════════════════════════════
    //
    // 【为什么用开关而不是新建一个引擎类】
    //   本类里 letterbox 绘制（CG/vImage/CGContext 三条路）、像素缓冲池、
    //   fastRowsStrided 快速取数、NMS、掩码 4×4 多数表决下采样、候选逐个实测
    //   加载、降级上下限判据、generation 防重叠 —— 这些**全是被验证过的既有实现**，
    //   且都是 private。新建一个引擎类要么把它们复制约 300 行（两处维护、
    //   两处修 bug），要么把它们的访问级别全部放开（改动面更大）。
    //
    //   而两个模型的**唯一实质差异就是 det 头解码**：
    //       yolopx  det [1, 8400, 6]  cx,cy,w,h, obj_conf, cls_conf
    //       A-YOLOM det [1,  5, 8400] cx,cy,w,h, cls_conf      ← 无 obj_conf + 需转置
    //   da / ll 两头**形状逐位相同**（都是 [1,2,640,640] logits）。
    //
    //   故：加一个模型族开关，只切「候选表 + det 解码」，其余一字不动。
    //   好处：① 零重复 ② 回滚只需翻转环境变量 ③ 两条路径共用同一套已验逻辑。
    //
    // 【默认档位 · 2026-10-02 翻转】用户原话：「把旧模型给我删了，直接用新模型就行」
    //        ⇒ 默认从 **yolopx 翻成 A-YOLOM**。不带任何环境变量启动就是新模型。
    //
    // 【回滚】`AURORA_AYOLOM=0` → 退回 yolopx，行为与此前逐位一致
    //        （候选表、解码、掩码全部不变）。
    //        注意：旧模型文件已按用户要求从 `models/` 清走，
    //        **回滚前必须先把 `_bak_yolopx_*/` 移回 `models/yolopx/`**，
    //        否则候选逐个失败 → 引擎静默不加载。这一点写在 `modelDirName` 注释里。
    /// ★ 当前生效的模型族 —— **运行时可切换**（2026-10-02 改）。
    ///
    /// 【为什么从 `static let` 改成实例属性】
    ///   原来它是 `nonisolated static let`，值在**进程启动时**从环境变量读一次就定死，
    ///   运行期间无法改变。用户要求「加个小窗口让用户自己选模型」——那必须能在
    ///   运行中切换，静态常量做不到。
    ///
    /// 【为什么不是 `static var`】
    ///   `parseDetections` 在**推理队列**上跑（后台线程），而切换发生在主线程。
    ///   `static var` 会让两边竞争同一个值 —— 可能出现「用 A-YOLOM 的候选表加载了
    ///   模型，却按 yolopx 的布局解码」这种静默错配。
    ///   改成实例属性后：`infer()` 在**投递任务之前**把值捕获成局部常量传给
    ///   `parseDetections`，一帧内的候选表与解码布局**必然一致**。
    ///
    /// 【切换语义】赋值本身**不会**立即换模型 —— 必须再调 `reloadModel()`
    ///   （见 `switchFamily(to:)`），否则旧模型还在内存里、候选表却已变。
    var family: PerceptionModelFamily = {
        // 未设（nil）→ A-YOLOM（新默认）
        // 显式给 0/false/no → yolopx（回滚路径）
        // 其它任何值（1/true/yes/乱写）→ A-YOLOM
        guard let raw = ProcessInfo.processInfo.environment["AURORA_AYOLOM"] else {
            return .ayolom
        }
        switch raw.lowercased() {
        case "0", "false", "no": return .yolopx
        default:                 return .ayolom
        }
    }()

    /// A-YOLOM 的候选表（与 yolopx 表同结构：逐个实测加载、失败即换下一个）。
    ///
    /// ⚠️ int8 是**硬要求**（用户 2026-10-02 明确：「我一定要做 INT8 量化」）。
    ///    产物由 `tools/ayolom/export_ayolom_coreml.py --quantize int8` 生成，
    ///    配方 = palette 8 位 kmeans + **det 头跳过保 fp16**（照抄 yolopx 的
    ///    `pal8_detfp` 已量产配方）。实测（200 帧真游戏画面，ANE）：
    ///      · da 掩码 IoU 0.9942（对比旧「线性 int8」的 0.9737 → 明显更好）
    ///      · ll 掩码 IoU 0.9749
    ///      · det 召回 99.1%（以 fp16 为真值）
    ///      · p50 10.42ms → 95.9 Hz（30Hz 只占 31% 预算）
    private nonisolated static let ayolomCandidates: [String] = [
        "ayolom_n_int8.mlmodelc",    // ← 生产首位（编译形态，免运行时编译）
        "ayolom_n_int8.mlpackage",   // ← 同上，包形态（需编译）
        "ayolom_n_fp16.mlmodelc",    // ⚠️ 兜底（7.2MB，非 int8），命中会告警
        "ayolom_n_fp16.mlpackage",
    ]

    /// 生效的候选表（按模型族二选一）
    private var modelCandidates: [String] {
        switch family {
        case .yolopx: return Self.yolopxCandidates
        case .ayolom: return Self.ayolomCandidates
        }
    }

    /// 模型文件所在子目录名（按模型族二选一）
    private var modelDirName: String {
        switch family {
        case .yolopx: return "yolopx"
        case .ayolom: return "ayolom"
        }
    }

    private nonisolated static let yolopxCandidates: [String] = [
        "yolopx3_pal8_detfp.mlmodelc",   // ← 精度冠军（det 100%），首位；结构完整免编译
        "yolopx3_pal8_detfp.mlpackage",  // ← 同上，包形态（需编译）
        // ⚠️ A22（2026-10-04）：`yolopx3_w8a16.mlmodelc` 已从本表**移除**。
        //    实测（`ls -la models/yolopx/yolopx3_w8a16.mlmodelc/`）该目录下
        //    **只有 `weights/`**，缺 `model.mil` / `coremldata.bin` / `metadata.json`
        //    （对比健康的 `yolopx3_pal8_detfp.mlmodelc/` 四个条目齐全），
        //    属半成品。`MLModel(contentsOf:)` 必然抛错 → 每次加载都要白跑一轮
        //    「存在性检查 → 尝试加载 → 失败 → 记日志 → 换下一个」。
        //    注意 `models/` 下的模型文件本轮不许改，故选择"移除"而非"修好"。
        //    若日后重新导出该产物，把下面这行放回 `pal8_detfp` 之后即可：
        //      "yolopx3_w8a16.mlmodelc",     // ← det 85%（结构完整时才可上台）
        "yolopx3_w8a16.mlpackage",       // ← det 85%
        "yolopx3_int8.mlpackage",        // ← ll recall 3.98%（架构性失败），靠后
        "yolopx3_fp16.mlpackage",        // ⚠️ 兜底：违反「只用 8 位」，会告警
    ]

    /// 候选文件的完整路径（按本表的尝试顺序）。
    /// 不再做"取第一个存在者"的筛选 —— 存在性与可加载性由 `loadFirstUsableModel()` 实测判定。
    ///
    /// ⚠️ 目录名随**模型族**走：yolopx → `models/yolopx/`，A-YOLOM → `models/ayolom/`。
    ///    此前这里硬编码 "yolopx"，A-YOLOM 的产物在 `models/ayolom/` 下会**全部找不到**，
    ///    表现为「候选逐个不存在 → 引擎静默不加载」，很难查。
    private var candidateURLs: [URL] {
        let dir = AuroraPaths.modelsDir().appendingPathComponent(modelDirName)
        return modelCandidates.map { dir.appendingPathComponent($0) }
    }

    /// 当前是否在用 fp16 兜底（用于告警：8 位产物全不可用）。
    /// 读**实际加载成功**的文件名，而不是"候选表里挑中的文件名"。
    private var isUsingFp16Fallback: Bool {
        (loadedModelName ?? "").contains("fp16")
    }

    // MARK: - 模型加载

    /// 遍历候选直到**真正加载成功**为止。
    ///
    /// 这是本引擎的核心修复（2026-09-26）：旧实现 `modelURL` 只返回"第一个存在的文件"，
    /// 再由单发 try/catch 加载 —— 一旦那个文件**存在但损坏**（如缺 `model.mil` 的
    /// 半成品 `.mlmodelc`），`isLoaded` 就永久为 false，**整个三头感知静默死亡**。
    /// 现在改为逐候选**实测加载**：失败即记录原因并继续下一个，任一成功即上台。
    ///
    /// 每步失败原因记入 `loadAttemptLog`，失败时 `errorMessage` 汇总全部候选的结局。
    /// - Returns: (成功加载的模型, 实际命中的候选文件名)；全部候选失败则 nil。
    private func loadFirstUsableModel() -> (model: MLModel, name: String)? {
        let config = MLModelConfiguration()
        // ══════════════════════════════════════════════════════════════════
        // 档位结论（2026-09-30 实测，两次独立 ABBA 复测后定案）
        // ══════════════════════════════════════════════════════════════════
        //
        // **保持 `.all`。** 曾经改成 `.cpuAndNeuralEngine`（理由是"消除 19 个 GPU
        // 算子、不与游戏抢 GPU"），**实测证伪，已回退**。
        //
        // 为什么当初的推理站不住：它基于**单次非交错测量**（45.9 vs 42.7ms 等）。
        // 换用项目自己的 ABBA 交错协议（`tools/yolopx/bench_protocol.py` 的
        // LoadController，模型常驻、只切档位标志位）复测两轮，结论相反：
        //
        //   场景           .all        .cpuAndNeuralEngine     胜者
        //   ─────────────────────────────────────────────────────────
        //   空载         183.0 ms        204.6 ms            .all 快 10.6%
        //   8 核满载     191.4 ms        199.1 ms            .all 快  3.9%
        //
        // 两个场景 `.all` 都更快，且**负载下差距收窄而非扩大**——与当初
        // "负载越高收益越大"的预期正好相反，说明那条假设的因果链不成立。
        //
        // 真正的瓶颈（本轮 `sample` 采样，见下方）不在档位选择，而在
        // **Espresso 把部分推理派给了 CPU 后端**：
        //   ExecuteStreamSync 258 样本
        //     ├─ 162 (62.8%) E5RT::Ops::BnnsCpuInferenceOperation   ← CPU
        //     └─  96 (37.2%) AneInferenceOperationImplUsingAnefAPIs ← ANE
        // 而 `BnnsCpuInferenceOperation` 由 CoreML 内部调度决定，
        // **不受 MLModelConfiguration.computeUnits 控制**——`.all` 已经是
        // 让它自己挑最优的结果，人工指定反而更差（上表）。
        //
        // ⚠️ 关于"那 16 个 CPU 算子"（.cpuAndNE 档下）：它们是 PSA 模块的
        //    `softmax`/`reduce_sum`，二者的 `supported_compute_devices` 实测
        //    **只含 CPU/GPU，ANE 不存在**（硬件能力限制，非配置问题）。
        //    两条改写路线均已尝试并**实测失败**（CPU 算子反而变多）：
        //      · 拆成 exp/max/mean 零件       → CPU 10 → 21
        //      · matmul 化折叠除法            → CPU 10 → 24
        //    故不再尝试从图结构上消除它们。
        //
        // ⚠️ 另两个档位同样不可取（实测）：`.cpuAndGpu` 把 427 个算子全给 GPU
        //    （97~100ms，慢一倍多，且文档记录曾触发 MPSGraph 断言 SIGABRT）；
        //    `.cpuOnly` 更慢（548ms+）。
        config.computeUnits = .all
        var log: [String] = []

        for url in candidateURLs {
            let name = url.lastPathComponent

            // ① 存在性
            guard FileManager.default.fileExists(atPath: url.path) else {
                log.append("  ✗ \(name) — 不存在")
                continue
            }

            // ② 取得可加载的 URL：.mlpackage 需先编译；.mlmodelc 直接可用
            var loadURL = url
            if name.hasSuffix(".mlpackage") {
                do {
                    // macOS 对 .mlpackage 必须先编译（与 SpeedOCRReader 同法）
                    loadURL = try MLModel.compileModel(at: url)
                } catch {
                    log.append("  ✗ \(name) — 编译失败: \(error.localizedDescription)")
                    continue
                }
            }

            // ③ 真正加载
            do {
                let m = try MLModel(contentsOf: loadURL, configuration: config)
                log.append("  ✓ \(name) — 加载成功")
                loadAttemptLog = log
                return (m, name)
            } catch {
                log.append("  ✗ \(name) — 加载失败: \(error.localizedDescription)")
                continue
            }
        }

        loadAttemptLog = log
        return nil
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown else { return }
        lastLoadAttempt = Date()

        guard let hit = loadFirstUsableModel() else {
            // 全部候选失败：**fail-open 语义不变** —— 保持未加载、保持降级，
            // 由 LaneFallback 的 isDegraded 门控拒绝采信，绝不引入误转向风险。
            isLoaded = false
            loadedModelName = nil
            errorMessage = "YOLOPX 模型全部候选加载失败：\n" + loadAttemptLog.joined(separator: "\n")
            print(errorMessage!)
            return
        }

        model = hit.model
        isLoaded = true
        loadedModelName = hit.name
        errorMessage = nil

        // 逐候选记录留痕，便于运维确认"到底加载到哪一个"
        print("[yolopx] 模型加载: \(hit.name)")
        for l in loadAttemptLog { print("[yolopx] \(l)") }

        if isUsingFp16Fallback {
            // 用户要求「只做 8 位」；走到这里说明 8 位产物全不可用，必须让人看见
            let warn = "⚠️ YOLOPX: 8 位模型全部不可用，已回退 fp16（违反「只用 8 位」约定）"
            errorMessage = warn
            print(warn)
        }
        // A21：label 传**实际命中的候选文件名**（hit.name），不再硬编码 modelBaseName。
        // 改前日志恒打 "[warmup] yolopx3 预热完成"，而实际加载的可能是
        // ayolom_n_int8.mlmodelc / yolopx3_pal8_detfp.mlmodelc / fp16 兜底 ——
        // 同一标签出现 6.8ms 与 24.3ms 两个数字，性能排查时会被严重误导。
        Self.warmUp(model: hit.model, label: hit.name, queue: inferenceQueue)
    }

    /// 后台预热：把 ANE 计算图编译与内存分配提前做完，避免首帧冷启动尖峰。
    private nonisolated static func warmUp(model: MLModel, label: String, queue: DispatchQueue) {
        queue.async {
            guard let pb = makePixelBuffer(size: inputSize),
                  let provider = try? MLDictionaryFeatureProvider(dictionary: [
                      "image": MLFeatureValue(pixelBuffer: pb)
                  ]) else {
                print("[warmup] \(label): 预热输入构造失败")
                return
            }
            let start = Date()
            do {
                _ = try model.prediction(from: provider)
                let ms = Date().timeIntervalSince(start) * 1000
                print("[warmup] \(label) 预热完成: \(String(format: "%.1f", ms))ms")
            } catch {
                print("[warmup] \(label) 预热失败: \(error.localizedDescription)")
            }
        }
    }

    /// 热替换（重新导出模型后调用）
    func reloadModel() {
        generation += 1
        model = nil
        isLoaded = false
        isInferencing = false
        loadedModelName = nil
        loadAttemptLog = []
        errorMessage = nil
    }

    // MARK: - 模型族切换（2026-10-02 新增，供 UI 的「感知模型」选择器调用）

    /// 切到指定模型族并**立刻重新加载模型**。
    ///
    /// 这是「运行日志下面那个小窗口」的后端入口。
    ///
    /// 【为什么必须重新加载】候选表的目录名与文件名都由 `family` 决定
    ///   （`models/ayolom/ayolom_n_int8.mlmodelc` ↔ `models/yolopx/yolopx3_pal8_detfp.mlmodelc`），
    ///   光改 `family` 而不 reload，内存里还是旧模型、候选表却已指向新目录 ——
    ///   表现为「切了档但检测结果一点没变」，很难查。
    ///
    /// 【顺序】`reset()` → `reloadModel()` → 改 `family` → 强制加载。
    ///   `reset()` 清 per-frame 状态（detections / mask / 降级标志）；
    ///   `reloadModel()` 清模型与加载状态（`generation += 1` 让在途推理结果过期）；
    ///   两者都做，清空与换模型之间没有窗口让决策层读到「旧掩码 + 新族」的错配组合。
    ///
    /// ⚠️ **必须绕过重试冷却**（2026-10-02 实测踩到，自检抓到）：
    ///   `loadIfNeeded()` 开头有一道 5 秒冷却门 ——
    ///       `guard Date().timeIntervalSince(lastLoadAttempt) >= loadRetryCooldown`
    ///   它原本是为了防止「加载失败后 30Hz 疯狂重试」。但**用户点档位是明确的人工
    ///   意图**，紧跟在一次加载之后（必然在 5s 内）就会被这道门静默挡掉 ——
    ///   症状极其隐蔽：`switchFamily` 返回 `true`、`family` 也变了，
    ///   **但模型压根没重新加载**，`loadedModelName` 还是旧的。
    ///   故这里把 `lastLoadAttempt` 归零再加载，冷却门只对"自动重试"生效。
    ///
    /// - Parameter newFamily: 目标模型族
    /// - Returns: 是否真的发生了切换（同族重复调用返回 false，不做无谓的重载）
    @discardableResult
    func switchFamily(to newFamily: PerceptionModelFamily) -> Bool {
        guard newFamily != family else { return false }
        reset()
        reloadModel()                  // ← 清模型状态（原先只置 isLoaded=false，漏了 generation/loadedModelName）
        family = newFamily
        lastLoadAttempt = .distantPast // ← 绕过重试冷却：人工换档不该被冷却挡掉
        loadIfNeeded()
        return true
    }

    // MARK: - 推理入口（主线程）

    /// 异步推理一帧。
    /// - Parameter image: 截屏画面 CGImage。内部做 letterbox（等比 + 114 灰边）。
    func infer(image: CGImage) {
        // ⚠️ 2026-09-26 修：原先只 `return`，不清理内部状态 ——
        //    停用引擎后 drivableMask/laneMask/isDegraded 还停留在停用前的旧值，
        //    决策层若此时读到就会拿**过期掩码**做判断。
        //    改为与 reloadModel()/reset() 同一清理语义：停用即清干净、并置降级。
        guard enabled else {
            reset()
            return
        }
        guard isLoaded, let modelRef = model else {
            loadIfNeeded()
            return
        }
        guard !isInferencing else { return }   // 防重叠：上一帧没跑完就跳过

        let size = Self.inputSize
        let metrics = LetterboxMetrics.calculate(srcW: image.width,
                                                 srcH: image.height,
                                                 size: size)
        guard metrics.ratio > 0 else { return }

        // ★ A2（2026-09-30 性能优化）：letterbox 绘制**从主线程移到推理队列**。
        //
        // 【为什么】基线前该项在主线程执行。`drawLetterbox` 实测 **10.540ms**
        //   （文档 §2.4），yolopx 约 12Hz → **每秒 126ms 全花在主线程上**。
        //   主线程同时还要跑 30Hz tick、SwiftUI 更新、截图回调 —— 这是"卡顿感"
        //   的直接来源之一。而这项计算**完全不依赖主线程**，属纯粹的白工。
        //
        // 【为什么不违反"不降品"】算法**一个字都没改** —— 仍是同一个
        //   `drawLetterbox`（内部仍走 CGContext 快路径，vImage 分支保持关闭）。
        //   文档实测"letterbox 改 vImage"会让检测框 9→6（精度回退，已否决），
        //   故本项只改**在哪执行**，绝不改**怎么算**。
        //
        // 【线程安全】`drawLetterbox` 是 `nonisolated static`，且推理队列是**串行**的，
        //   对 `pb`（inputBuffer）的"先画后读"天然有序，无数据竞争。
        //
        // 【回归护栏】设 `AURORA_YOLOPX_LETTERBOX_MAIN=1` 可回退到主线程绘制。
        //
        // ★ 阶段0（2026-10-01 审计修复）：这里原先是**每帧现读**环境变量
        //   （`ProcessInfo.processInfo.environment[...]`，实测 17.213 µs/次），
        //   12Hz 提交下每秒白烧 0.207ms —— 把 A2 省下的收益倒扣回去。
        //   现已提升为实例属性 `letterboxOnMain`（见其声明处注释），
        //   全生命周期只读一次。**变量名/默认值/比较语义逐字不变**，行为等价。

        if inputBuffer == nil {
            inputBuffer = Self.makePixelBuffer(size: size)
        }
        guard let pb = inputBuffer else {
            errorMessage = "YOLOPX: 输入缓冲构造失败"
            return
        }
        // 若选择保留在主线程（回退路径），此处先画好；否则进队列再画
        if letterboxOnMain, !Self.drawLetterbox(image, into: pb, size: size, metrics: metrics) {
            errorMessage = "YOLOPX: 输入缓冲构造失败"
            return
        }

        // ★ A1：节拍判定 —— 距上次**完成**不足 minInferenceIntervalMs 才拦截。
        //   ⚠️ 默认 0 = 关闭（实测教训见 minInferenceIntervalMs 注释：
        //      固定间隔会变成额外瓶颈，让 yolopx 从 12.75Hz 掉到 5.02Hz）。
        //   即便启用，本判定也只是"省掉一次无用的输入准备"——
        //   A2 之后该准备已不在主线程且只花 ~0.04ms，故收益有限、风险明确。
        if minInferenceIntervalMs > 0 {
            let now = CFAbsoluteTimeGetCurrent()
            let sinceDoneMs = (now - lastInferenceDoneAt) * 1000.0
            // lastInferenceDoneAt == 0 表示还没跑过第一帧，必须放行
            if lastInferenceDoneAt > 0, sinceDoneMs < minInferenceIntervalMs {
                return
            }
        }

        isInferencing = true
        let conf = confidenceThreshold
        let iouT = iouThreshold
        let maxN = maxDetections
        let gen = generation
        let grid = Self.maskGridSize
        let stride = size / grid
        // ★ 2026-10-02：**在投递任务之前**捕获本帧的模型族。
        //   `family` 现在是运行时可切换的实例属性（UI 可选 A-YOLOM / 旧三件套），
        //   而下面这段闭包跑在推理队列上。若在闭包里读 `self.family`，就变成
        //   「后台线程读主线程可变状态」——切换瞬间可能候选表换了解码没换。
        //   捕获成局部常量后，**一帧内的候选表与解码布局必然一致**。
        let fam = family

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()

            // ★ A2：letterbox 在推理队列内绘制（主线程不再承担这 10.5ms）
            //   失败时走与原来一致的错误路径（置 errorMessage + 降级）。
            if !letterboxOnMain,
               !Self.drawLetterbox(image, into: pb, size: size, metrics: metrics) {
                Task { @MainActor in
                    self.finish(gen, [], .empty, .empty, metrics,
                                0, 0, 0, "YOLOPX: 输入缓冲构造失败")
                }
                return
            }

            let provider: MLDictionaryFeatureProvider
            do {
                provider = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: pb)
                ])
                let out = try modelRef.prediction(from: provider)

                guard let detArr = out.featureValue(for: "det")?.multiArrayValue,
                      let daArr = out.featureValue(for: "da")?.multiArrayValue,
                      let llArr = out.featureValue(for: "ll")?.multiArrayValue else {
                    let names = out.featureNames.sorted().joined(separator: ",")
                    Task { @MainActor in
                        self.finish(gen, [], .empty, .empty, metrics,
                                    0, 0, 0, "YOLOPX: 输出缺失（实际输出: \(names)）")
                    }
                    return
                }

                // det → 框（含坐标变换 + 灰边剔除 + NMS）
                let dets = Self.parseDetections(detArr,
                                                family: fam,
                                                metrics: metrics,
                                                confidenceThreshold: conf,
                                                iouThreshold: iouT,
                                                maxDetections: maxN)

                // da / ll → 掩码（argmax + 4×4 多数表决下采样）
                let (daGrid, daRatio) = Self.extractMask(daArr, grid: grid, stride: stride,
                                                         metrics: metrics)
                let (llGrid, llRatio) = Self.extractMask(llArr, grid: grid, stride: stride,
                                                         metrics: metrics)

                let latency = Date().timeIntervalSince(start) * 1000

                Task { @MainActor in
                    self.finish(gen, dets, daGrid, llGrid, metrics,
                                latency, daRatio, llRatio, nil)
                }
            } catch {
                Task { @MainActor in
                    self.finish(gen, [], .empty, .empty, metrics,
                                0, 0, 0, "YOLOPX: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 结果回主线程落状态（含掩码 EMA 平滑与降级判定）
    private func finish(_ gen: Int,
                        _ dets: [Detection],
                        _ daGrid: MaskGrid,
                        _ llGrid: MaskGrid,
                        _ metrics: LetterboxMetrics,
                        _ latency: Double,
                        _ daRatio: Double,
                        _ llRatio: Double,
                        _ error: String?) {
        guard gen == generation else { return }   // reset()/reloadModel() 后在途结果过期
        isInferencing = false
        lastInferenceDoneAt = CFAbsoluteTimeGetCurrent()   // ★ A1 节拍判据基准

        if let error {
            errorMessage = error
            isDegraded = true          // 出错即降级，决策层立刻停止采信
            return
        }

        // ── 掩码 EMA 平滑（跨帧去抖）──
        let smoothedDA = Self.smoothMask(daGrid, accum: &drivableAccum)
        let smoothedLL = Self.smoothMask(llGrid, accum: &laneAccum)

        // 平滑后的占比重新统计（降级判定用平滑值，避免单帧抖动误判）
        let (daSm, llSm) = Self.positiveRatios(da: smoothedDA, ll: smoothedLL,
                                               metrics: metrics)

        detections = dets
        drivableMask = smoothedDA
        laneMask = smoothedLL
        self.metrics = metrics
        lastLatencyMs = latency
        drivableRatio = daSm > 0 ? daSm : daRatio
        laneRatio = llSm > 0 ? llSm : llRatio
        inferenceCount += 1
        // A20（2026-10-04）：真实推理耗时汇进 PerfBus（对照 submit.yolopx
        // 只测 DispatchQueue.async 的提交开销 p50 ≈ 0.026ms）。
        // 这是后续所有 YOLOPX 优化的唯一裁判指标。
        PerfBus.shared.record("infer.yolopx", ms: latency)
        errorMessage = nil

        // ── 降级判定：车道线塌陷优先（细目标最先被量化/异常摧毁）──
        // ⚠️ 2026-09-27（t47）：补**上限**。原实现只有下限 → 前景占比 38.89%
        //    （真实上限的 10 倍）仍判为"健康"并让兜底照给建议（t31 §3.1 实测）。
        //    详见上方 lanePositiveCeil 的取值依据与局限声明。
        //
        // ⚠️ 2026-09-27（第二轮，显示层解耦）：先分别算两路的塌陷状态，
        //    再合并成决策层用的 `isDegraded`。分开算的原因见上方
        //    `laneDegraded`/`drivableDegraded` 的说明 —— 车道线细、天然贴近
        //    下限，它一塌陷就把可行驶区一起压暗是不合理的。
        laneDegraded = (laneRatio < Self.lanePositiveFloor)
            || (laneRatio > Self.lanePositiveCeil)
        drivableDegraded = (drivableRatio < Self.drivablePositiveFloor)
            || (drivableRatio > Self.drivablePositiveCeil)
        isDegraded = laneDegraded || drivableDegraded
    }

    /// 停止驾驶时清空
    func reset() {
        generation += 1
        detections = []
        drivableMask = .empty
        laneMask = .empty
        metrics = .zero
        isInferencing = false
        lastLatencyMs = 0
        drivableRatio = 0
        laneRatio = 0
        isDegraded = true
        errorMessage = nil
        drivableAccum = []
        laneAccum = []
    }

    // MARK: - det 后处理（nonisolated，纯函数）

    /// YOLOX det 输出 [1, 8400, 6] → [Detection]（归一化到原帧）
    ///
    /// 每行 = [cx, cy, w, h, obj_conf, cls_conf]（640 输入像素坐标，**未过 NMS**）
    /// nc == 1，故最终置信度即 obj_conf
    /// （官方 `lib/core/general.py:139`：`if nc == 1: x[:, 5:] = x[:, 4:5]`）
    /// - Parameter family: **本帧捕获**的模型族。必须由调用方在投递推理任务**之前**
    ///   取好并传进来 —— 不能在这里读 `self.family`（那是在后台线程读主线程可变状态，
    ///   会在切换模型的瞬间出现「候选表换了解码没换」的错配）。
    private nonisolated static func parseDetections(_ out: MLMultiArray,
                                                     family: PerceptionModelFamily,
                                                     metrics: LetterboxMetrics,
                                                     confidenceThreshold: Double,
                                                     iouThreshold: Double,
                                                     maxDetections: Int) -> [Detection] {
        // ══════════════════════════════════════════════════════════════════
        //  模型族分叉（2026-10-02）：只有三处不同，其余逐字共用
        // ══════════════════════════════════════════════════════════════════
        //           框数在哪一维      字段间隔      置信度位置
        //  yolopx    shape[1] = 8400   6（行优先）   第 4 个字段
        //  A-YOLOM   shape[2] = 8400   8400（列优先） 第 4 个字段（无 obj_conf）
        //  灰边剔除 / NMS / 归一化 —— 三种布局下完全一致，全部共用。
        let n: Int
        let raw: [Float]?
        switch family {
        case .yolopx:
            n = out.shape.count >= 2 ? out.shape[1].intValue : 0
            // 快速路径：按**真实 strides** 整块拷贝，避免 8400×6 次下标访问（每帧可观开销）。
            // ⚠️ 2026-09-26 修：原用 fastRows()（要求 4 维严格连续），而 det 实测是
            //    3 维 [1,8400,6] 且 strides=[268800, 32, 1]（行跨度 32 ≠ 6，有填充），
            //    导致该快速路径**从未生效**、每帧退化为 8400×5 次 readML 下标读。
            //    现改用 fastRowsStrided()：只要求最内维连续，行偏移按 strides 取。
            guard n > 0 else { return [] }
            raw = fastRowsStrided(out, rows: n, cols: 6)
        case .ayolom:
            // det 实测 [1, 5, 8400]：5 个字段各占一整行（channel-major）。
            // 最内维 8400 连续 → 直接按「5 行 × 8400 列」整块取，等价于转置后逐框读。
            guard out.shape.count >= 3 else { return [] }
            let ch = out.shape[1].intValue          // 期望 5
            n = out.shape[2].intValue               // 期望 8400
            guard ch >= 5, n > 0 else { return [] }
            raw = fastRowsStrided(out, rows: ch, cols: n)
        }

        var candidates: [(box: (Double, Double, Double, Double), conf: Double)] = []
        candidates.reserveCapacity(64)

        for i in 0..<n {
            let cx: Double, cy: Double, w: Double, h: Double, conf: Double
            switch family {
            case .yolopx:
                if let raw {
                    let b = i * 6
                    cx = Double(raw[b]); cy = Double(raw[b + 1])
                    w = Double(raw[b + 2]); h = Double(raw[b + 3])
                    conf = Double(raw[b + 4])
                } else {
                    cx = readML(out, [0, i, 0]); cy = readML(out, [0, i, 1])
                    w = readML(out, [0, i, 2]); h = readML(out, [0, i, 3])
                    conf = readML(out, [0, i, 4])
                }
            case .ayolom:
                if let raw {
                    // 列优先：第 c 行的第 i 个元素 = 第 i 个框的第 c 个字段
                    cx = Double(raw[0 * n + i]); cy = Double(raw[1 * n + i])
                    w = Double(raw[2 * n + i]); h = Double(raw[3 * n + i])
                    conf = Double(raw[4 * n + i])
                } else {
                    cx = readML(out, [0, 0, i]); cy = readML(out, [0, 1, i])
                    w = readML(out, [0, 2, i]); h = readML(out, [0, 3, i])
                    conf = readML(out, [0, 4, i])
                }
            }

            // 非有限值一律跳过（NaN/Inf 进 Int() 会 runtime trap 崩全车）
            guard conf.isFinite, conf > confidenceThreshold,
                  cx.isFinite, cy.isFinite, w.isFinite, h.isFinite,
                  w > 1, h > 1 else { continue }

            // cxcywh → xyxy（640 像素坐标）
            let x1 = cx - w / 2, y1 = cy - h / 2
            let x2 = cx + w / 2, y2 = cy + h / 2

            // 剔除落在 letterbox 灰边内的框：灰边是填充像素，不是真实画面
            if metrics.isInPad(x: cx, y: cy) { continue }
            if x2 <= Double(metrics.padX) || x1 >= Double(metrics.padX + metrics.newW) { continue }
            if y2 <= Double(metrics.padY) || y1 >= Double(metrics.padY + metrics.newH) { continue }

            candidates.append(((x1, y1, x2, y2), conf))
        }

        guard !candidates.isEmpty else { return [] }

        // 按置信度降序 → NMS（YOLOX 输出未去重，必须自己做）
        let order = candidates.indices.sorted { candidates[$0].conf > candidates[$1].conf }

        var kept: [(box: (Double, Double, Double, Double), conf: Double)] = []
        kept.reserveCapacity(min(maxDetections, candidates.count))

        var suppressed = [Bool](repeating: false, count: candidates.count)
        for idx in order {
            if suppressed[idx] { continue }
            let c = candidates[idx]
            kept.append(c)
            if kept.count >= maxDetections { break }
            for other in order where !suppressed[other] && other != idx {
                if suppressed[other] { continue }
                if iouXYXY(c.box, candidates[other].box) > iouThreshold {
                    suppressed[other] = true
                }
            }
        }

        // 640 坐标 → 原帧归一化坐标
        return kept.map { item in
            let (nx1, ny1) = metrics.toNormalized(x: item.box.0, y: item.box.1)
            let (nx2, ny2) = metrics.toNormalized(x: item.box.2, y: item.box.3)
            let x = min(max((nx1 + nx2) / 2, 0), 1)
            let y = min(max((ny1 + ny2) / 2, 0), 1)
            let w = min(max(abs(nx2 - nx1), 0), 1)
            let h = min(max(abs(ny2 - ny1), 0), 1)
            return Detection(x: x, y: y, width: w, height: h,
                             label: .car,          // nc == 1：只有车
                             confidence: item.conf,
                             rawName: "VEHICLE")
        }
    }

    /// 两个 xyxy 框的 IoU
    @inline(__always)
    private nonisolated static func iouXYXY(_ a: (Double, Double, Double, Double),
                                            _ b: (Double, Double, Double, Double)) -> Double {
        let ix1 = max(a.0, b.0), iy1 = max(a.1, b.1)
        let ix2 = min(a.2, b.2), iy2 = min(a.3, b.3)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        let areaA = max(0, a.2 - a.0) * max(0, a.3 - a.1)
        let areaB = max(0, b.2 - b.0) * max(0, b.3 - b.1)
        let union = areaA + areaB - inter
        return union > 0 ? inter / union : 0
    }

    // MARK: - 掩码提取（nonisolated，纯函数）

    /// da / ll 输出 [1, 2, 640, 640] → (MaskGrid, valid 区域正像素占比)
    ///
    /// 逐像素对两个通道做 argmax（>0 即前景），再按 4×4 块多数表决下采样。
    /// 占比只统计 letterbox valid 区域（灰边不算），否则灰边像素会污染降级判定。
    private nonisolated static func extractMask(_ arr: MLMultiArray,
                                                grid: Int,
                                                stride: Int,
                                                metrics: LetterboxMetrics) -> (MaskGrid, Double) {
        let shape = arr.shape.map(\.intValue)
        guard shape.count == 4, shape[1] >= 2 else { return (.empty, 0) }
        let height = shape[2], width = shape[3]
        guard width % stride == 0, height % stride == 0 else { return (.empty, 0) }

        var cells = [UInt8](repeating: 0, count: grid * grid)
        var validTotal = 0
        var validPositive = 0

        let total = shape[1] * height * width
        let contiguous = isContiguous(arr, total: total)

        // ⚠️ 2026-09-27（R2-M2 修复）：原实现在此**无条件双绑定** f16/f32：
        //    先 bindMemory(to: Float16.self) 再 bindMemory(to: Float32.self)，
        //    然后靠 `if let f16` 的**顺序**决定用哪个 —— 完全不看 arr.dataType。
        //    实测（同一语义张量 ch0=0/ch1=1 = 全前景）：
        //      · float16（生产 dtype）→ 16/16 前景（正确）
        //      · float32            →  0/16 前景（**读成全错**，被判全背景）
        //    即"当前生产路径正确"只是**dtype 巧合**：模型恰好输出 fp16。
        //    换任何 fp32 输出的导出形态（或 CoreML 版本改变输出 dtype）即静默失效，
        //    且失效方向是"看不见任何掩码"→ 兜底全程闭嘴，属静默降智。
        //    现改为**按 dtype 显式分派**：类型不匹配时干脆不给快速路径指针，
        //    由下面的 readML 下标读兜底（正确但慢），绝不误读。
        let f16: UnsafeMutablePointer<Float16>?
        let f32: UnsafeMutablePointer<Float32>?
        switch arr.dataType {
        case .float16:
            f16 = contiguous ? arr.dataPointer.bindMemory(to: Float16.self, capacity: total) : nil
            f32 = nil
        case .float32:
            f16 = nil
            f32 = contiguous ? arr.dataPointer.bindMemory(to: Float32.self, capacity: total) : nil
        default:
            // 双精度等其它类型：不猜，走 readML
            f16 = nil
            f32 = nil
        }

        // valid 区域在网格坐标下的范围
        let strideD = Double(stride)
        let vx0 = max(0, Int(Double(metrics.padX) / strideD))
        let vy0 = max(0, Int(Double(metrics.padY) / strideD))
        let vx1 = min(grid, Int(ceil(Double(metrics.padX + metrics.newW) / strideD)))
        let vy1 = min(grid, Int(ceil(Double(metrics.padY + metrics.newH) / strideD)))

        for gy in 0..<grid {
            for gx in 0..<grid {
                var positive = 0
                for dy in 0..<stride {
                    let py = gy * stride + dy
                    for dx in 0..<stride {
                        let px = gx * stride + dx
                        let i0 = py * width + px
                        let i1 = height * width + i0

                        let a: Float, b: Float
                        if let f16 {
                            a = Float(f16[i0]); b = Float(f16[i1])
                        } else if let f32 {
                            a = f32[i0]; b = f32[i1]
                        } else {
                            a = Float(readML(arr, [0, 0, py, px]))
                            b = Float(readML(arr, [0, 1, py, px]))
                        }
                        if b > a { positive += 1 }
                    }
                }
                if positive * 2 >= stride * stride {   // 多数表决
                    cells[gy * grid + gx] = 1
                }
                if gx >= vx0 && gx < vx1 && gy >= vy0 && gy < vy1 {
                    validTotal += 1
                    validPositive += positive * 2 >= stride * stride ? 1 : 0
                }
            }
        }

        let ratio = validTotal > 0 ? Double(validPositive) / Double(validTotal) : 0
        return (MaskGrid(width: grid, height: grid, cells: cells), ratio)
    }

    /// 掩码 EMA 平滑：累加器按 EMA 更新，超过阈值判为前景。
    ///
    /// 实测有效性（2026-09-26，maskEMA=0.35 / threshold=0.5，逐帧模拟）：
    ///   · 单帧孤立冒起 `[1,0,0,0,0,0]` → 输出**全 0**（完全抑制）
    ///   · 交替抖动 `[0,1,0,1,0,1]` → 输出 `[0,0,0,0,0,1]`（6 帧只放行 1 帧）
    ///   · 连续 2 帧才放行 → 确认在抑制抖动，代价约 2 帧额外延迟
    ///   ⇒ 机制**确实在起作用**，保留。
    ///
    /// ⚠️ 初始化语义（2026-09-26 澄清并修正注释）：
    ///    `accum` 是**跨帧持久**的成员（drivableAccum / laneAccum），
    ///    仅在 `reset()`（停用引擎 / 重载模型）时清空 —— **不是每帧重置**。
    ///    因此原先"从 0 起步"的冷启动代价**只发生在会话首帧 / reset 之后那一帧**，
    ///    影响是"reset 后头 2 帧掩码偏保守"，而非持续性延迟。
    ///    仍改为用首帧观测初始化（前景=1/背景=0）：让 reset 后立即恢复真实比例，
    ///    避免"刚重置完那两帧掩码偏空 → 占比偏低 → 误触降级"的边界抖动。
    private nonisolated static func smoothMask(_ grid: MaskGrid,
                                               accum: inout [Float]) -> MaskGrid {
        guard grid.width > 0, !grid.cells.isEmpty else { return grid }
        let n = grid.cells.count
        if accum.count != n {
            // 首帧（或尺寸变化）：用本帧观测直接初始化，避免从 0 起步的偏差
            accum = grid.cells.map { $0 != 0 ? 1 : 0 }
            return grid
        }
        var out = [UInt8](repeating: 0, count: n)
        let a = Float(maskEMA)
        for i in 0..<n {
            let v: Float = grid.cells[i] != 0 ? 1 : 0
            accum[i] = accum[i] * (1 - a) + v * a
            out[i] = accum[i] >= maskThreshold ? 1 : 0
        }
        return MaskGrid(width: grid.width, height: grid.height, cells: out)
    }

    /// 平滑后掩码在 valid 区域内的正像素占比
    private nonisolated static func positiveRatios(da: MaskGrid, ll: MaskGrid,
                                                    metrics: LetterboxMetrics) -> (Double, Double) {
        func ratio(_ g: MaskGrid) -> Double {
            guard g.width > 0, metrics.newW > 0 else { return 0 }
            let strideD = Double(inputSize) / Double(g.width)
            let x0 = max(0, Int(Double(metrics.padX) / strideD))
            let y0 = max(0, Int(Double(metrics.padY) / strideD))
            let x1 = min(g.width, Int(ceil(Double(metrics.padX + metrics.newW) / strideD)))
            let y1 = min(g.height, Int(ceil(Double(metrics.padY + metrics.newH) / strideD)))
            var total = 0, pos = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    total += 1
                    if g.at(x, y) { pos += 1 }
                }
            }
            return total > 0 ? Double(pos) / Double(total) : 0
        }
        return (ratio(da), ratio(ll))
    }

    /// MLMultiArray 是否**逐元素连续**（da/ll 的 4 维 [1,2,H,W] 快速路径前提）。
    ///
    /// ⚠️ 2026-09-26：本函数原先也用于 det，但 **det 实测是 3 维 [1,8400,6]、且并不连续**
    ///    （strides = [268800, 32, 1]，行跨度 32 而非 6 —— CoreML 内部有对齐填充）。
    ///    因此 det 的快速路径**从未生效**，每帧都在走 8400×5 次下标读（`readML`），
    ///    这是端到端延迟偏高的一个来源。det 现改用 `fastRowsStrided()` 按真实 strides 读。
    ///    本函数只保留给 da/ll（它们实测为严格 4 维连续：strides=[819200,409600,640,1]）。
    private nonisolated static func isContiguous(_ arr: MLMultiArray, total: Int) -> Bool {
        guard arr.dataType == .float16 || arr.dataType == .float32 else { return false }
        let strides = arr.strides.map(\.intValue)
        guard strides.count == 4 else { return false }
        let shape = arr.shape.map(\.intValue)
        let expectW = 1
        let expectH = shape[3]
        let expectC = shape[2] * shape[3]
        let expectN = shape[1] * shape[2] * shape[3]
        return strides[3] == expectW && strides[2] == expectH
            && strides[1] == expectC && strides[0] == expectN
            && arr.count == total
    }

    /// 按**已知列数**整块读出 [rows, cols]，允许行间存在填充。
    ///
    /// 用于 det（[1, 8400, 6]，实测 strides=[_, 32, 1]）：只要求**最后一维连续**
    /// （strides[last] == 1），行偏移用 strides[1] 而非假设 == cols。
    /// 这样即使 CoreML 换了对齐策略（如 32→16），也能正确读取、不会错位。
    ///
    /// - Returns: 连续排布的 [rows × cols] 数组；前提不满足时返回 nil（调用方回退下标读）。
    private nonisolated static func fastRowsStrided(_ arr: MLMultiArray,
                                                    rows: Int,
                                                    cols: Int) -> [Float]? {
        guard rows > 0, cols > 0 else { return nil }
        guard arr.dataType == .float16 || arr.dataType == .float32 else { return nil }
        let shape = arr.shape.map(\.intValue)
        let strides = arr.strides.map(\.intValue)
        guard shape.count >= 2, strides.count == shape.count else { return nil }

        // 最后两维是 [rows, cols]；要求最内维逐元素连续，且行跨度足够容纳 cols
        let lastDim = shape[shape.count - 1]
        guard lastDim == cols else { return nil }
        let rowStride = strides[strides.count - 2]
        guard strides[strides.count - 1] == 1, rowStride >= cols else { return nil }

        let total = rows * cols
        var out = [Float](repeating: 0, count: total)
        // capacity 给出**总元素数**（含行间填充）：数据指针至少要覆盖到最后一行的末尾，
        // 即 (rows-1)*rowStride + cols。用实际形状算出的容量，避免越界读。
        let capacity = (rows - 1) * rowStride + cols
        if arr.dataType == .float16 {
            let base = arr.dataPointer.bindMemory(to: Float16.self, capacity: capacity)
            for i in 0..<rows {
                let off = i * rowStride
                let dst = i * cols
                for j in 0..<cols { out[dst + j] = Float(base[off + j]) }
            }
        } else {
            let base = arr.dataPointer.bindMemory(to: Float32.self, capacity: capacity)
            for i in 0..<rows {
                let off = i * rowStride
                let dst = i * cols
                for j in 0..<cols { out[dst + j] = Float(base[off + j]) }
            }
        }
        return out
    }

    /// 把 [n, cols] 的连续张量整块拷成 [Float]（快速路径）
    private nonisolated static func fastRows(_ arr: MLMultiArray,
                                             rows: Int, cols: Int) -> [Float]? {
        let total = rows * cols
        guard isContiguous(arr, total: total) else { return nil }
        var out = [Float](repeating: 0, count: total)
        if arr.dataType == .float16 {
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: total)
            for i in 0..<total { out[i] = Float(p[i]) }
        } else {
            let p = arr.dataPointer.bindMemory(to: Float32.self, capacity: total)
            for i in 0..<total { out[i] = p[i] }
        }
        return out
    }

    /// 安全读取单个元素（dtype / stride / 半精度交给 CoreML 处理）
    private nonisolated static func readML(_ m: MLMultiArray, _ index: [Int]) -> Double {
        m[index.map { NSNumber(value: $0) }].doubleValue
    }

    // MARK: - 输入缓冲（nonisolated，纯函数）

    private nonisolated static func makePixelBuffer(size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    /// letterbox 绘制：整幅填 114 灰 → 等比缩放居中绘制原图。
    ///
    /// ⚠️ 与 YoloEngine.draw 的关键差异：那是 `ctx.draw(in: 全幅)`（非等比拉伸），
    ///    这里是等比缩放 + 灰边，与 YOLOPX 训练端 letterbox 一致。
    ///
    /// ── 2026-09-30 重写：`CGContext.fill+draw` → `memset + vImageScale_ARGB8888` ──
    ///
    /// **为什么换**：本函数在主线程、每次 `infer()` 都走一遍（30Hz tick 调用，
    /// `isInferencing` 只挡推理不挡绘制前的这一帧）。原实现走完整 CoreGraphics
    /// 光栅化管线（fill + 带插值的 drawImage），实测是同等工作量下最慢的路径。
    ///
    /// 实测（M 系列，n=100，源 480×312 → 目标 640×640 letterbox，
    /// newW=640 newH=416 padY=112，与生产参数完全一致）：
    ///   · CGContext fill+draw      10.540 ms
    ///   · memset + vImageScale      2.309 ms   ← **4.57×**
    ///   30Hz 下节省 **247 ms/秒**（≈ 8 核的 3%，全部从主线程让出）
    ///
    /// **几何完全不变**：同样填 114 灰、同样等比缩放到 `newW×newH`、
    /// 同样落在行序 `[padY, padY+newH)`（vImage 的目标缓冲区指针直接偏移到该行，
    /// 语义上等价于原 CGContext 的 `drawOriginY`，因为 CGContext 原点在左下、
    /// 行序缓冲自顶向下写，二者换算后落点一致）。
    ///
    /// **回退保证**：源像素取不到时（provider 不可读 / 格式不符）退回原 CGContext
    /// 路径，功能零损失——见下方 `fallbackToCGContext`。
    @discardableResult
    private nonisolated static func drawLetterbox(_ cgImage: CGImage,
                                                  into pb: CVPixelBuffer,
                                                  size: Int,
                                                  metrics: LetterboxMetrics) -> Bool {
        // ══════════════════════════════════════════════════════════════════
        // vImage 快路径：**已实测证伪，默认关闭**（2026-09-30）
        // ══════════════════════════════════════════════════════════════════
        //
        // 动机：CGContext fill+draw 实测 10.540ms，vImage 版 2.309ms（**4.57×**，
        //       30Hz 下省 247ms/秒）。看起来是纯赚。
        //
        // **但精度回退，不可接受**：切换后同一张测试图、同一模型、连续 3 次
        // 全部稳定输出 `检测框 6 个 / 可行驶 22.53%`，而原实现稳定输出
        // `检测框 9 个 / 可行驶 26.19%`。**框少 3 个**——对驾驶系统这是功能性回退，
        // 不能用性能换。
        //
        // 根因（逐像素实测）：两者重采样核不同，`kCGInterpolationMedium` 与
        // vImageScale 在 1.33× 放大下的边缘处理不一致：
        //   · 内容区最大像素差 **49/255**，平均 1.528，>16 的占 0.99%
        //   · 换 `kvImageHighQualityResampling` 更大（最大 53）
        //   · 换 `kvImageNoInterpolation` / `kvImageDoNotTile` 无改善（均 49）
        // 高频边缘处的这些差异经 640×640 卷积网络放大，直接改变检测结果。
        //
        // **几何本身是正确的**：用红/蓝标记块验证，两种实现的内容落点完全一致
        // （行[112..244] / 行[396..527]、灰边 114）——差异纯粹来自采样核，
        // 不是坐标算错。
        //
        // 保留 `drawLetterboxVImage` 实现备查：若将来 YOLOPX 用该 letterbox
        // **重新训练/量化标定**（让模型适配 vImage 的采样核），即可安全启用。
        // 在那之前，这一行开关**必须保持 false**。
        let useVImageLetterbox = false

        if useVImageLetterbox,
           drawLetterboxVImage(cgImage, into: pb, size: size, metrics: metrics) {
            return true
        }
        // ── 生效路径：原 CGContext 实现（与重写前逐字节一致）──
        return drawLetterboxCGContext(cgImage, into: pb, size: size, metrics: metrics)
    }

    /// vImage 快路径。失败返回 false（调用方回退 CGContext）。
    private nonisolated static func drawLetterboxVImage(_ cgImage: CGImage,
                                                        into pb: CVPixelBuffer,
                                                        size: Int,
                                                        metrics: LetterboxMetrics) -> Bool {
        let newW = metrics.newW, newH = metrics.newH
        guard newW > 0, newH > 0,
              newW <= size, newH <= size,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let srcBase = CFDataGetBytePtr(data) else { return false }

        // 源必须已是 32BGRA（CaptureEngine 的 onFrame 缓冲恒为 32BGRA）。
        // 位深/通道不符时不猜，交给 CGContext 兜底。
        guard cgImage.bitsPerPixel == 32, cgImage.bitsPerComponent == 8 else { return false }

        let srcBPR = cgImage.bytesPerRow
        let srcW = cgImage.width, srcH = cgImage.height
        guard srcW > 0, srcH > 0, srcBPR >= srcW * 4 else { return false }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let dstBPR = CVPixelBufferGetBytesPerRow(pb)

        // ① 整幅填 114 灰（与官方 letterbox 同色）。memset 整行即可，
        //    因为 4 个通道同值 → 直接按字节填，无需逐像素。
        memset(base, 114, dstBPR * size)

        // ② 等比缩放到目标矩形。
        //    vImage 目标区域的起点 = 行 padY、列 padX。
        //    注意行序：vImage 的 data 指针指向「目标区域第一行」，
        //    而 letterbox 的内容行区间是 [padY, padY+newH)（行 0 = 图顶）——
        //    与 CGContext 的 drawOriginY 换算后一致，此处直接用 padY。
        // advanced(by:) 返回非可选指针，无需 guard let。
        let dstRegion = base.advanced(by: metrics.padY * dstBPR + metrics.padX * 4)
        var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: srcBase),
                                   height: vImagePixelCount(srcH),
                                   width: vImagePixelCount(srcW),
                                   rowBytes: srcBPR)
        var dstBuf = vImage_Buffer(data: dstRegion,
                                   height: vImagePixelCount(newH),
                                   width: vImagePixelCount(newW),
                                   rowBytes: dstBPR)
        let err = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError
    }

    /// 原 CGContext 路径（重写前实现，原样保留作兜底）。
    private nonisolated static func drawLetterboxCGContext(_ cgImage: CGImage,
                                                           into pb: CVPixelBuffer,
                                                           size: Int,
                                                           metrics: LetterboxMetrics) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: size, height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return false }

        // 官方 letterbox 的灰边色：114/255
        let gray = CGFloat(114.0 / 255.0)
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // CoreGraphics 原点在**左下**，而 letterbox 的 padY 记的是**顶部**灰边（行序口径）。
        // 由 `drawOriginY` 明确给出"内容在 CGContext 里的下边界 y"（= padBottom），
        // 不再直接拿 padY 充当绘制 y —— 二者在当前算法下数值相同，但语义不同：
        // 一旦将来 padTop/padBottom 不再对称（如非整除尺寸调整），直接用 padY 就会画偏。
        ctx.interpolationQuality = .medium   // letterbox 缩放质量比纯检测拉伸更重要
        ctx.draw(cgImage, in: CGRect(x: CGFloat(metrics.padX),
                                     y: CGFloat(metrics.drawOriginY),
                                     width: CGFloat(metrics.newW),
                                     height: CGFloat(metrics.newH)))
        return true
    }

    // MARK: - 诊断

    /// 引擎自检摘要（供 --yolopx-selftest 打印）
    func diagnosticSummary() -> String {
        var lines: [String] = []
        // 报告**实际加载成功**的模型名；未加载时明示"未加载"而不是误导性的候选名
        lines.append("模型: \(loadedModelName ?? "（未加载成功）")")
        lines.append("加载: \(isLoaded ? "✓" : "✗")\(errorMessage.map { "  \($0)" } ?? "")")
        if !loadAttemptLog.isEmpty {
            lines.append("候选遍历:")
            for l in loadAttemptLog { lines.append(l) }
        }
        lines.append(String(format: "耗时: %.1f ms  推理帧数: %d", lastLatencyMs, inferenceCount))
        lines.append("检测框: \(detections.count) 个（上限 \(maxDetections)）")
        lines.append(String(format: "可行驶占比: %.2f%%  车道线占比: %.3f%%",
                            drivableRatio * 100, laneRatio * 100))
        lines.append("降级: \(isDegraded ? "是（决策层不得采信）" : "否")")
        if metrics.srcW > 0 {
            lines.append(String(format: "letterbox: 源 %d×%d → r=%.4f pad=(%d,%d) 内容 %d×%d",
                                metrics.srcW, metrics.srcH, metrics.ratio,
                                metrics.padX, metrics.padY, metrics.newW, metrics.newH))
        }
        return lines.joined(separator: "\n")
    }
}
