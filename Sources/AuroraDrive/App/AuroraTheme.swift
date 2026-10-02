// ============================================================================
// AuroraTheme.swift — 黑灰白设计系统
// ----------------------------------------------------------------------------
// 从 ui-prototypes/A-任务控制中心.html 移植。
//
// 设计原则（用户反复强调过的，不要再改回去）：
//   1. 底色纯黑，面板是「黑透玻璃」——半透明黑 + 模糊，绝不发白
//   2. 白色只出现在 1px 描边高光上，上限 0.10
//   3. 界面主色 = 黑 · 灰 · 白。没有蓝色。
//   4. 唯三保留的颜色是路况状态色：绿(安全) / 橙(注意) / 红(必须接管)
//   5. 玻璃感来自「透出背后的光」，不是靠白色叠加
// ============================================================================

import SwiftUI

// MARK: - 灰阶

extension Color {
    /// 从 0xRRGGBB 字面量构造（比 Color(red:green:blue:) 好读）
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// 全局主题 token
enum Aurora {

    // ══════════════════════════════════════════════════════════════
    // MARK: 底色 —— 纯黑阶梯
    // ══════════════════════════════════════════════════════════════

    static let void   = Color(hex: 0x03060B)              // --void
    static let s0     = Color(hex: 0x080F1A, alpha: 0.55)  // --s0
    static let s1     = Color(hex: 0x0B1422, alpha: 0.72)  // --s1
    static let s2     = Color(hex: 0x0F1A2C, alpha: 0.84)  // --s2
    static let s3     = Color(hex: 0x142238, alpha: 0.92)  // --s3
    static let s4     = Color(hex: 0x1A2A44, alpha: 0.96)  // s3 略亮

    // ══════════════════════════════════════════════════════════════
    // MARK: 玻璃 —— 冰蓝调半透（对齐 --s0..--s3）
    // ══════════════════════════════════════════════════════════════

    static let glass      = Color(hex: 0x0B1422, alpha: 0.72)
    static let glassFill  = Color(hex: 0x0B1422, alpha: 0.72)   // --s1
    static let glassFill2 = Color(hex: 0x080F1A, alpha: 0.55)   // --s0
    static let glassSolid = Color(hex: 0x0F1A2C, alpha: 0.92)   // --s2

    // ══════════════════════════════════════════════════════════════
    // MARK: 发丝线 / 主强调 / 语义 / 文字
    // ══════════════════════════════════════════════════════════════

    static let hair1 = Color(hex: 0x8CBEFF, alpha: 0.10)   // --hair
    static let hair2 = Color(hex: 0x8CBEFF, alpha: 0.17)   // --hair-2
    static let hair3 = Color(hex: 0x8CBEFF, alpha: 0.28)   // --hair-3
    static let hair4 = Color(hex: 0x8CBEFF, alpha: 0.42)

    static let ice     = Color(hex: 0x4CC9FF)              // --ice
    static let iceLo   = Color(hex: 0x4CC9FF, alpha: 0.34) // --ice-lo
    static let iceHi   = Color(hex: 0x8EE0FF)              // --ice-hi
    static let iceGlow = Color(hex: 0x4CC9FF, alpha: 0.14) // --ice-glow
    static let iceWash = Color(hex: 0x4CC9FF, alpha: 0.07) // --ice-wash

    static let ok     = Color(hex: 0x34E5AA)               // --ok
    static let okLo   = Color(hex: 0x34E5AA, alpha: 0.16)  // --ok-lo
    static let amber  = Color(hex: 0xFFB648)               // --amber
    static let danger = Color(hex: 0xFF5468)               // --danger
    static let violet = Color(hex: 0xA98BFF)               // --violet

    static let t1 = Color(hex: 0xE9F3FF)                   // --txt
    static let t2 = Color(hex: 0xE9F3FF, alpha: 0.62)      // --txt-2
    static let t3 = Color(hex: 0xE9F3FF, alpha: 0.36)      // --txt-3
    static let t4 = Color(hex: 0xE9F3FF, alpha: 0.20)      // --txt-4
    static let muted = Color(hex: 0xE9F3FF, alpha: 0.36)

    // MARK: 圆角
    // ══════════════════════════════════════════════════════════════

    static let r1: CGFloat = 8
    static let r2: CGFloat = 12
    static let r3: CGFloat = 15
    static let r4: CGFloat = 20

    // ══════════════════════════════════════════════════════════════
    // MARK: 字体
    // ══════════════════════════════════════════════════════════════

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// 全大写小标签（中文场景少用，用于 GEAR 1 / ASSIST FPS 这类）
    static func label(_ size: CGFloat = 9) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - 路况自适应四态

/// 路况自适应状态机 —— 由 UI 手动切换，未来可接模型输出
enum RoadCondition: String, CaseIterable, Identifiable, Sendable {
    // 6 档，按「由松到紧」排列（用户 2026-09-22 重新定义）。
    // 自动判定阈值见 AutoRoadCondition：>70 极度复杂 / >50 繁忙 / >30 中等
    // / >20 轻松 / 11–20 保持 / ≤10 简单(不限速)
    case simple  = "simple"    //  ≤10 框 · 不限速
    case easy    = "easy"      //  21–30 框 · 150
    case medium  = "medium"    //  31–50 框 · 100
    case busy    = "busy"      //  51–70 框 · 60
    case extreme = "extreme"   //  >70 框 · 20
    case off     = "off"       // 自动速度关闭（手动）

    var id: String { rawValue }

    /// 中文短名
    var name: String {
        switch self {
        case .simple:  return "路况简单 · 不限速"
        case .easy:    return "路况轻松 · 快速通行"
        case .medium:  return "路况中等 · 稳健通行"
        case .busy:    return "路况繁忙 · 谨慎通行"
        case .extreme: return "极度复杂 · 等待介入"
        case .off:     return "自动速度关闭"
        }
    }

    /// 表盘/按钮上的短标签
    var shortName: String {
        switch self {
        case .simple:  return "不限速"
        case .easy:    return "快速通行"
        case .medium:  return "稳健通行"
        case .busy:    return "谨慎通行"
        case .extreme: return "等待介入"
        case .off:     return "已关闭"
        }
    }

    /// 大地图左栏的极短名
    var briefName: String {
        switch self {
        case .simple:  return "简单"
        case .easy:    return "轻松"
        case .medium:  return "中等"
        case .busy:    return "繁忙"
        case .extreme: return "极度复杂"
        case .off:     return "关闭"
        }
    }

    /// 状态色 —— 驱动整个界面的强调色
    /// 色序沿用既有语义：ok(绿)=最宽松 → ice(冰蓝) → amber(琥珀) → danger(红)=最严
    var color: Color {
        switch self {
        case .simple:  return Aurora.ok
        case .easy:    return Aurora.iceHi
        case .medium:  return Aurora.ice
        case .busy:    return Aurora.amber
        case .extreme: return Aurora.danger
        case .off:     return Aurora.muted
        }
    }

    /// 顶栏尾注
    var autoSpeedLabel: String {
        switch self {
        case .off:     return "AUTO SPEED · OFF"
        case .extreme: return "AUTO SPEED · HOLD"
        default:       return "AUTO SPEED · ON"
        }
    }

    /// 是否需要用户立即接管
    var needsTakeover: Bool { self == .extreme }

    /// 自动速度是否在工作
    var autoSpeedActive: Bool { self != .off }

    /// 档位按钮上显示的限速值。
    /// ⚠️ 三种状态必须区分开：
    ///   · 简单档   → "不限速"（自动速度在工作，结论是不限速）
    ///   · 有限速档 → 数字
    ///   · 关闭档   → "—"（自动速度没在工作，不是"不限速"！）
    var limitLabel: String {
        if self == .off { return "—" }
        if let l = autoSpeedLimit { return "\(Int(l))" }
        return "不限速"
    }

    var next: RoadCondition {
        let all = RoadCondition.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

// MARK: - 玻璃面板修饰符

/// 黑透玻璃卡片。层次靠「黑 + 灰描边」，不靠发白。
struct AuroraGlass: ViewModifier {
    var radius: CGFloat = Aurora.r2
    /// 长按/聚焦态：玻璃变厚，透出更多背后的光
    var lifted: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(lifted ? Aurora.s2 : Aurora.s1)
                    // 背后的光透出来 —— 靠系统材质做真实模糊
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.30)
                        .blendMode(.overlay)
                }
            }
            .overlay {
                // 1px 灰阶描边：玻璃的「棱」
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Aurora.ice.opacity(lifted ? 0.34 : 0.20),
                                Aurora.hair2,
                                .clear,
                                Aurora.hair3
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.95), radius: 22, x: 0, y: 20)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// 应用黑透玻璃面板
    func auroraGlass(radius: CGFloat = Aurora.r2, lifted: Bool = false) -> some View {
        modifier(AuroraGlass(radius: radius, lifted: lifted))
    }
}

// MARK: - 视觉特效（视口光斑 / 描边）

/// 路况色视口描边：普通态是白光晕，极度复杂态整圈变红并呼吸
struct ViewportRim: ViewModifier {
    let condition: RoadCondition
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Aurora.r3, style: .continuous)
                    .strokeBorder(
                        condition.needsTakeover
                            ? Aurora.danger.opacity(pulse ? 0.95 : 0.45)
                            : Aurora.hair2,
                        lineWidth: condition.needsTakeover ? 1.5 : 1
                    )
            }
            .shadow(
                color: condition.needsTakeover
                    ? Aurora.danger.opacity(pulse ? 0.70 : 0.35)
                    : Aurora.iceGlow,
                radius: condition.needsTakeover ? 62 : 40
            )
            .shadow(
                color: condition.needsTakeover
                    ? Aurora.danger.opacity(pulse ? 0.40 : 0.18)
                    : Aurora.iceWash,
                radius: condition.needsTakeover ? 150 : 110
            )
            .onAppear {
                guard condition.needsTakeover else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: condition) { _, new in
                if new.needsTakeover {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { pulse = false }
                }
            }
    }
}

/// 视口内漂浮光斑 —— 玻璃「透出来的光」的来源
struct AuroraLightField: View {
    let condition: RoadCondition
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                blob(color: condition.color,
                     size: max(w, h) * 0.78,
                     x: w * 0.02, y: h * 0.04,
                     opacity: condition == .extreme ? 0.34 : 0.26)
                blob(color: .white,
                     size: max(w, h) * 0.60,
                     x: w * 0.92, y: h * 0.86,
                     opacity: 0.17)
                blob(color: .white,
                     size: max(w, h) * 0.48,
                     x: w * 0.56, y: h * 0.46,
                     opacity: 0.12)
            }
            // blur 半径从 92 降到 60：三个 blob 的总面积约为窗口的 1.9 倍，
            // 而 92 半径对应 185×185 的高斯核，且 .offset 每帧都在动 → 模糊结果
            // 无法被 Core Animation 缓存，等于每帧对近两倍窗口面积做一次大核卷积，
            // 是 UI 侧最贵的一处 GPU 开销。60 半径（核 121）在观感上仍是柔和光斑，
            // 但卷积量下降约六成。
            //
            // ═══════════════════════════════════════════════════════════════════
            // ⚠️⚠️ 2026-09-28 回退记录：这里曾加过 `.drawingGroup()`，**已移除**。
            //
            //    起因：用户报"预览框巨卡"，我用 CIGaussianBlur 离线量到 blur 的
            //    p50 是 2.13~4.20ms，于是判断它是主因，加了 `.drawingGroup()`
            //    想把 blur 结果栅格化缓存起来。
            //
            //    结果：**更卡了**。用户报"卡到逆天、基本不能动"。
            //    `sample` 抓真实堆栈（PID 70152，3 秒 1ms 采样）铁证：
            //      1402/1402 个主线程样本全在 CA::Transaction::commit()
            //        → CA::Layer::display_if_needed
            //        → RBLayer displayWithBounds
            //        → RB::DisplayList::render → RenderState::RootTexture::make_texture()
            //        其中 1110 个样本卡在 make_texture()
            //      并出现 RB::DisplayList::FilterStyle<RB::Filter::GaussianBlur>::draw
            //
            //    机理：`.drawingGroup()` 要求 SwiftUI 把子视图树**渲染进一张离屏纹理**。
            //    而外层还有 `.offset` 动画在每帧改变位置 → 每次位置变化都让
            //    "离屏纹理"失效并**重建一张新的**（make_texture 是重分配 + 全量重绘）。
            //    这比原来直接对 blob 做高斯卷积**更贵**：原本只是一次卷积，
            //    现在变成"离屏合成 + 卷积 + 再合成"，且纹理每帧重建。
            //
            //    教训：`drawingGroup()` 只适合**内容稳定、位置也稳定**的子树。
            //    这里位置在动（.offset 动画），正好踩中它最不适用的场景。
            //    离线 CIGaussianBlur 夹具测不出这一层——因为夹具里没有
            //    SwiftUI 的离屏合成语义。**离线微基准不能替代真实 UI 堆栈采样。**
            // ═══════════════════════════════════════════════════════════════════
            .blur(radius: 60)
            // ══════════════════════════════════════════════════════════════════════
            // ⚠️ 2026-09-30 性能修复：**移除背景光斑的无限漂移动画**
            // ══════════════════════════════════════════════════════════════════════
            //
            // 【症状】用户报「一打开那个卡得离谱」。本轮实测确认，
            //   WindowServer 负载：Aurora 关 51.2% → 开 81.9%（**+30.7%**）。
            //
            // 【单因子对照（决定性证据）】
            //     背景漂移 开（原状）                 WS = 81.9%
            //     背景漂移 关（AURORA_DISABLE_BG_DRIFT=1） WS = 51.9%   ← 完全回到基线
            //   ⟹ 这**一处**就是全部原因；抓屏、四模型、HUD、静音音频、
            //     nice=-20、event tap 等所有其它因子合计只占 0.7 个百分点。
            //
            // 【机理】三个 blob 的总面积 ≈ 窗口的 1.9 倍。`.offset` 每帧改变
            //   位置 ⟹ 上方那层 60px 高斯模糊的结果**无法被 Core Animation 缓存**
            //   ⟹ **每一帧都要对近两倍窗口面积重做一次大核卷积**。
            //   而原动画是 `repeatForever` —— 只要 App 开着就永不停止。
            //   WindowServer 负载正比于「重绘面积 × 模糊核 × 频率」，三项全满。
            //
            //   （该机理本段下方原有注释其实早已写明，只是从未量化。
            //     另注：此处曾试过 `.drawingGroup()` 想缓存模糊，结果**更卡** ——
            //     因为 `.offset` 让离屏纹理每帧重建。那段回退记录保留在下方。）
            //
            // 【为什么移除而不只是暂停】实测「26 秒往复移动 44 像素」的位移，
            //   在 60px 模糊半径下**观感几乎无法察觉**（模糊本身已抹平细节），
            //   而收益是**整个 WindowServer 负载回到基线**（-30 个百分点）。
            //   已与用户确认采用此方案（用户明确选择「直接关掉漂移动画」）。
            //
            // 【视觉不变的部分】三个光斑的颜色、尺寸、位置、透明度、
            //   60px 模糊半径全部保持原样 —— 它们仍是原先那个柔和光斑背景，
            //   只是不再缓慢漂移。**不降品**。
            //
            // 【保留开关】`AURORA_DISABLE_BG_DRIFT=1` 仍有效（显式声明静止），
            //   便于日后随时回到「静止」这个已验证的安全状态。
            //
            // 【如何临时恢复漂移复验观感】把下面 `onAppear` 里的
            //   `driftDriftEnabled` 判断改成 `true` 即可（一行改动）。
            .offset(x: drift ? 22 : -22, y: drift ? 18 : -18)
            .animation(.easeInOut(duration: 26).repeatForever(autoreverses: true), value: drift)
            .onAppear {
                // 背景漂移已默认关闭：它是 WindowServer +30 个百分点的唯一根因
                // （见上方长注释与文档 6.34）。`drift` 保持 false → 光斑静止
                // → 60px 模糊结果可被 Core Animation 缓存，不再每帧重算。
                //
                // 显式读一次环境变量仅为保留该开关的语义（设与不设都静止），
                // 将来若要做「开启漂移」的反向开关，改这一行即可。
                let driftEnabled = ProcessInfo.processInfo.environment["AURORA_ENABLE_BG_DRIFT"] == "1"
                if driftEnabled { drift = true }
            }
        }
        .allowsHitTesting(false)
    }

    private func blob(color: Color, size: CGFloat, x: CGFloat, y: CGFloat,
                      opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [color.opacity(opacity), color.opacity(0)],
                center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(x: x, y: y)
    }
}
