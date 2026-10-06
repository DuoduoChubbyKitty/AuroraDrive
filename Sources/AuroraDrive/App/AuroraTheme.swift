// ============================================================================
// AuroraTheme.swift — 黑灰白设计系统
// ----------------------------------------------------------------------------
// 从 ui-prototypes/A-任务控制中心.html 移植。
//
// 设计原则（用户反复强调过的，不要再改回去）：
//   1. 底色纯黑，面板是「黑透玻璃」——半透明黑 + 模糊，绝不发白
//   2. 白色只出现在 1px 描边高光上，上限 0.10
//   3. 界面主色 = 黑 · 灰 · 白 + 单一冰蓝强调色（ice）；语义色仅 绿/橙/红/紫。
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
    // ── 2026-10-04 可读性修复（WCAG 2.1 AA）──────────────────────────────
    // 旧值 t3=0.36 / t4=0.20 在深色底上分别只有 2.97:1 / 1.65:1，
    // 正文门槛是 4.5:1 —— 即「面板行标签、加载提示」这类必读小字长期不可读。
    // 新值实测（对 void 与最差背景 s4 都达标）：
    //   t3 α0.55 → void 5.68:1 ／ s4 4.98:1   ✓ 正文可用
    //   t4 α0.45 → void 4.12:1 ／ s4 3.80:1   ✓ 仅限非正文：大字(≥15pt)或装饰
    // ⚠️ t4 不是「正文色」：必读小字请一律用 t3。复核脚本见 /tmp/design-audit/contrast.py
    static let t3 = Color(hex: 0xE9F3FF, alpha: 0.55)      // --txt-3
    static let t4 = Color(hex: 0xE9F3FF, alpha: 0.45)      // --txt-4（非正文）
    /// 已关闭/未启用态。语义上等同 t3（原为 t3 的别名，2026-10-04 随 t3 一并提升，
    /// 否则 `.off` 路况色会停在 2.97:1 不达标）。
    static let muted = Color(hex: 0xE9F3FF, alpha: 0.55)

    // ══════════════════════════════════════════════════════════════
    // MARK: 圆角阶梯（5 档，封闭）
    // ══════════════════════════════════════════════════════════════
    //
    // 【为什么要有阶梯】2026-10-04 审计实测：全库圆角用了 **18 种裸值**
    //   （0,1.5,3,4,5,6,7,8,9,10,11,12,13,15,16,18,20,24），而主题只定义了 4 个 ——
    //   于是「同一类控件在不同页面长得不一样」（实测：最新的 CategoryPanel 用 3，
    //   MissionConsole 用 17 种，MapWindow 用 6/8）。
    //
    // 【吸附规则】就近取整；**平局取大**（宁可更圆一点，不要更尖）。
    //   0            → 0     （直角，保留：仅用于满宽分隔条等确实需要直角的地方）
    //   1.5 / 3 / 4 / 5 / 6 → 4     （徽章、键帽、小色块）
    //   7 / 8 / 9 / 10      → 8     （按钮、输入框、小卡片）
    //   11 / 12 / 13        → 12    （卡片、列表块）
    //   15 / 16 / 18        → 16    （面板）
    //   20 / 24             → 20    （窗口、弹窗）
    static let radiusBadge: CGFloat = 4      // 徽章 / 键帽 / 小色块
    static let radiusControl: CGFloat = 8    // 按钮 / 输入框 / 小卡片
    static let radiusCard: CGFloat = 12      // 卡片 / 列表块
    static let radiusPanel: CGFloat = 16     // 面板
    static let radiusWindow: CGFloat = 20    // 窗口 / 弹窗

    // ⚠️ 旧名保留为别名，避免既有调用点（MissionConsole 等）一次性全红。
    //    新代码请用语义名。迁移完成后这四个会删除。
    static let r1: CGFloat = radiusControl   // 8
    static let r2: CGFloat = radiusCard      // 12
    static let r3: CGFloat = radiusPanel     // 16（原 15 —— 吸附到 16 档）
    static let r4: CGFloat = radiusWindow    // 20

    // ══════════════════════════════════════════════════════════════
    // MARK: 间距阶梯（7 档，4pt 网格）
    // ══════════════════════════════════════════════════════════════
    //
    // 【为什么要有阶梯】审计实测：`spacing:` 用了 **19 种**取值
    //   （0,1,2,2.5,3,4,5,6,7,8,9,10,11,12,13,14,16,18,20），
    //   `padding` 用了 **25 种**（含 1.5/3.5/4.5/22/26/30/44/52）。
    //   最常用的 6 / 8 / 5 三个值几乎等量 —— 说明根本没有网格。
    //
    // 【吸附规则】4pt 网格就近取整；**平局取大**（宁可更松，不要更挤）。
    //   0                → 0
    //   1 / 2 / 2.5 / 3  → 4      （图标内衬、极小间隙）
    //   4 / 5 / 6        → 8      ← 注意：5/6 是高频值，升到 8 会让排布变松，
    //                                这是**有意的**（原值偏挤，是「demo 感」来源之一）
    //   7 / 8 / 9 / 10   → 8 或 12（就近）
    //   11 / 12 / 13     → 12
    //   14 / 15 / 16 / 18→ 16
    //   20 / 22          → 24
    //   26 / 30          → 32
    //   44 / 52          → 48
    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 8
    static let sp3: CGFloat = 12
    static let sp4: CGFloat = 16
    static let sp5: CGFloat = 24
    static let sp6: CGFloat = 32
    static let sp7: CGFloat = 48

    // ══════════════════════════════════════════════════════════════
    // MARK: 字号阶梯（8 档，封闭）
    // ══════════════════════════════════════════════════════════════
    //
    // 【为什么要有阶梯】审计实测：全库用了 **20 种**字号
    //   （7,7.5,8,8.5,9,9.5,10,10.5,11,11.5,12,13,14,15,16,17,18,21,24,32），
    //   其中 8.5 / 9 / 9.5 三档各用 39/47/31 次 —— 相差 1pt，**肉眼不可辨**，
    //   只制造噪音。且 7~8.5pt 共 72 处，低于 Apple HIG 的正文下限。
    //
    // 【吸附规则】**只升不降**（用户硬要求：不许降可读性），就近向上取整。
    //   7 / 7.5 / 8 / 8.5 / 9 / 9.5 / 10 → 10   （原 7pt 文字提升 43%）
    //   10.5 / 11 / 11.5                 → 11
    //   12                               → 12
    //   13                               → 13
    //   14 / 15 / 16                     → 15
    //   17 / 18                          → 17   （18→17 是唯一的小幅回落，仍在正文以上）
    //   21 / 24                          → 21
    //   32                               → 32
    static let fsMicro: CGFloat = 10    // 最小可读字号（HIG 下限；不得再小）
    static let fsSmall: CGFloat = 11
    static let fsBody: CGFloat = 12
    static let fsTitle: CGFloat = 13
    static let fsH1: CGFloat = 15
    static let fsNum: CGFloat = 17
    static let fsDisplay: CGFloat = 21
    static let fsHero: CGFloat = 32

    // ══════════════════════════════════════════════════════════════
    // MARK: 阴影阶梯（4 档）
    // ══════════════════════════════════════════════════════════════
    //
    // 【为什么要有阶梯】审计实测：`MissionConsole.swift` 一个文件就有 **51 处**
    //   `.shadow(`，其中 `.black.opacity(0.78), radius: 17, y: 14` 这一组
    //   重复 4 次、`:945` 是近似值 `0.8/14/10` —— 本应是同一个 token。
    //   深色界面里阴影是**唯一的层次手段**，参数漂移会让整体「说不清哪里怪」。
    static let shadowRaisedRadius: CGFloat = 4
    static let shadowRaisedY: CGFloat = 2
    static let shadowRaisedOpacity: Double = 0.30

    static let shadowCardRadius: CGFloat = 10
    static let shadowCardY: CGFloat = 6
    static let shadowCardOpacity: Double = 0.55

    static let shadowPanelRadius: CGFloat = 17
    static let shadowPanelY: CGFloat = 14
    static let shadowPanelOpacity: Double = 0.78

    static let shadowModalRadius: CGFloat = 22
    static let shadowModalY: CGFloat = 20
    static let shadowModalOpacity: Double = 0.95

    // ══════════════════════════════════════════════════════════════
    // MARK: 动效时长（3 档）
    // ══════════════════════════════════════════════════════════════
    //
    // 【约束】用户硬要求「不许瞬变」→ 最短 0.14s（≥120ms）。
    //   ⚠️ **禁止 `repeatForever`** —— 本文件 AuroraLightField 的性能记录已论证：
    //   一处常驻漂移动画就让 WindowServer 负载 51.2% → 81.9%。
    //   需要「持续动」的地方请重新论证，并保证能被系统「减少动态效果」关掉。
    static let durFast: Double = 0.14   // 按钮 hover / pressed
    static let durBase: Double = 0.20   // 面板展开 / 数值过渡
    static let durSlow: Double = 0.32   // 视图切换 / 大块进出

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
    /// 默认字号取 `fsMicro`（10）—— 原为 9，低于 HIG 正文下限。
    static func label(_ size: CGFloat = Aurora.fsMicro) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
    /// 数值读数：**等宽数字**（`monospacedDigit`）—— 避免刷新时左右抖动。
    ///
    /// 审计实测：全库 `monospacedDigit()` 只有 3 处，而 `String(format: "%.1f", …)`
    /// 形式的读数遍布各处 —— 顶栏 FPS、车速、置信度每次刷新都会跳。
    static func metric(_ size: CGFloat = Aurora.fsSmall,
                       _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
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

// MARK: - 按钮五态

/// 按钮五态样式 —— default / hover / pressed / **disabled** / **focus**。
///
/// 【为什么需要】全库 47 个按钮此前一律 `.buttonStyle(.plain)`，而 `.plain` 在
/// macOS 上会**关掉全部系统反馈**：没有 hover 高亮、没有按压变暗、没有焦点环。
/// 结果是「点下去毫无变化」—— 这是 demo 感最强的信号（用户会怀疑是不是没点到）。
///
/// 【设计约束（用户硬要求）】
///   · 过渡 **≥120ms**（不许瞬变）—— 这里用 0.14s；
///   · **绝不使用 `repeatForever`** —— 本文件已论证过常驻动画的代价
///     （背景漂移一处就让 WindowServer 51.2% → 81.9%）；
///   · **形状无关**：提亮用 `brightness`、焦点用 `shadow`，二者都跟随视图
///     自身的 alpha 蒙版 —— 胶囊按钮得到胶囊光晕，圆角矩形得到圆角光晕，
///     不需要样式去猜调用方的 `cornerRadius`（猜错就是视觉 bug）；
///   · **不触发重排**：只改亮度/缩放/阴影，不改 frame —— 按下时相邻元素不跳动；
///   · 按下 `scaleEffect(0.98)` 位移 < 1px，60fps 下无观感抖动。
///
/// 【与 `disabled` 的关系】`.disabled(true)` 时：不再响应 hover/press，
/// 整体 `opacity(0.45)`。这补齐了此前「禁用态无任何视觉提示」的缺口。
struct AuroraButtonStyle: ButtonStyle {
    /// hover 时提亮幅度（0 = 关闭 hover 反馈）。
    var hoverLift: Double = 0.06
    /// pressed 时压暗幅度（按下「沉下去」）。
    var pressedLift: Double = 0.05
    /// pressed 时缩放（1.0 = 不缩放）。
    var pressedScale: CGFloat = 0.98
    /// disabled 时的不透明度。
    var disabledOpacity: Double = 0.45
    /// 是否绘制焦点光晕（键盘导航可见性）。
    var showsFocusGlow: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        AuroraButtonBody(configuration: configuration, style: self)
    }

    private struct AuroraButtonBody: View {
        let configuration: Configuration
        let style: AuroraButtonStyle

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        /// 当前亮度增量：pressed > hover > 0（禁用时恒 0）。
        private var brightness: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return -style.pressedLift }
            return hovering ? style.hoverLift : 0
        }

        private var scale: CGFloat {
            (isEnabled && configuration.isPressed) ? style.pressedScale : 1.0
        }

        /// 是否需要画焦点光晕。
        private var wantsFocusGlow: Bool {
            style.showsFocusGlow && isFocused && isEnabled
        }

        var body: some View {
            // ⚠️ 焦点光晕必须**条件挂载**，不能写成 `.shadow(color: ... ? 色 : .clear)`：
            // 后者即使颜色是 `.clear` 也会让 SwiftUI 把视图渲进离屏层，
            // 静止态像素与 `.plain` 不一致（实测平均亮度 +0.0027），
            // 白白多一次离屏合成。条件挂载后静止态与 `.plain` **逐像素一致**。
            Group {
                if wantsFocusGlow {
                    core.shadow(color: Aurora.ice.opacity(0.55), radius: 3)
                } else {
                    core
                }
            }
        }

        private var core: some View {
            configuration.label
                .brightness(brightness)
                .scaleEffect(scale)
                .opacity(isEnabled ? 1.0 : style.disabledOpacity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .animation(.easeOut(duration: 0.14), value: isEnabled)
                .animation(.easeOut(duration: 0.14), value: isFocused)
        }
    }
}

extension View {
    /// 应用 AuroraDrive 按钮五态样式。
    ///
    /// 用法：把 `Button { ... } label: { ... }.buttonStyle(.plain)`
    /// 换成 `.buttonStyle(AuroraButtonStyle())`（或 `.auroraButton()`）。
    func auroraButton(hoverLift: Double = 0.06,
                      pressedLift: Double = 0.05,
                      pressedScale: CGFloat = 0.98,
                      disabledOpacity: Double = 0.45,
                      showsFocusGlow: Bool = true) -> some View {
        buttonStyle(AuroraButtonStyle(hoverLift: hoverLift,
                                      pressedLift: pressedLift,
                                      pressedScale: pressedScale,
                                      disabledOpacity: disabledOpacity,
                                      showsFocusGlow: showsFocusGlow))
    }
}

// MARK: - 数值读数

/// 数值读数组件 —— **等宽数字**（刷新不抖动）+ **数值平滑过渡**（不硬切）。
///
/// 【为什么需要】
///   2026-10-04 审计实测：全库 `monospacedDigit()` 只有 **3 处**、
///   `contentTransition` 只有 **2 处**，而 `String(format: "%.1f", …)` 形式的
///   读数遍布各处（顶栏 FPS / 车速 / 置信度、驾驶面板的转向·油门·刹车量、
///   速度环 …）。后果有两个，而且**每帧都在发生**：
///     ① **数字宽度不一致 → 每次刷新左右抖动**（「demo 感」最持续的来源）；
///     ② **数值变化硬切**（速度环 120 → 80 直接跳，没有过渡）。
///
/// 【约束（用户硬要求）】
///   · 过渡时长固定 `Aurora.durFast`(0.14s) —— 不许瞬变；
///   · **禁止 `repeatForever`** —— 本文件 AuroraLightField 的性能记录已论证：
///     一处常驻动画就让 WindowServer 负载 51.2% → 81.9%；
///   · 只加 `monospacedDigit` + `contentTransition`，**不改字号/颜色/字重** ——
///     调用方原有的视觉一个像素都不动。
///
/// 【用法】
///   · 纯数字：`AuroraMetric(count: 42)` / `AuroraMetric(number: speed, format: "%.0f")`
///   · 混合文本（「3 组」「12/42」）：保留原 `Text`，加 `.auroraMetric(value:)`
struct AuroraMetric: View {
    private let text: String
    private let size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let color: Color

    /// 直接给已格式化好的文本。
    init(_ text: String,
         size: CGFloat = Aurora.fsSmall,
         weight: Font.Weight = .regular,
         design: Font.Design = .default,
         color: Color = Aurora.t1) {
        self.text = text
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
    }

    /// 浮点读数：自动 `String(format:)`；**非有限值走占位符**（不显示 "nan"/"inf"）。
    init(number: Double,
         format: String = "%.1f",
         placeholder: String = "—",
         size: CGFloat = Aurora.fsSmall,
         weight: Font.Weight = .regular,
         design: Font.Design = .default,
         color: Color = Aurora.t1) {
        self.init(number.isFinite ? String(format: format, number) : placeholder,
                  size: size, weight: weight, design: design, color: color)
    }

    /// 整数读数。
    init(count: Int,
         size: CGFloat = Aurora.fsSmall,
         weight: Font.Weight = .regular,
         design: Font.Design = .default,
         color: Color = Aurora.t1) {
        self.init("\(count)", size: size, weight: weight, design: design, color: color)
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: design))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: Aurora.durFast), value: text)
    }
}

extension View {
    /// 把**已有的** `Text` 接成数值读数（等宽数字 + 数值过渡）。
    ///
    /// 这是给既有调用点的**最小改动**入口：不动字号/颜色/字重，只补
    /// 「不抖动」与「不硬切」两件事。新代码请直接用 `AuroraMetric`。
    ///
    /// - Parameter value: 用于判断「值变了没」的字符串 —— 传**驱动这个 Text 的那个值**，
    ///   否则动画不会触发。
    func auroraMetric(_ value: String, duration: Double = Aurora.durFast) -> some View {
        self.monospacedDigit()
            .contentTransition(.numericText())
            .animation(.easeOut(duration: duration), value: value)
    }
}

// MARK: - 视觉特效（视口光斑）

// ── 2026-10-04 删除 `ViewportRim`（44 行，全库零引用）─────────────────────
// 原实现是「路况色视口描边 + 极度复杂态整圈红色呼吸」，但 grep 全库确认
// 它**从未被任何视图使用**（仅剩定义处自身）。删除同时移除了它内部的
// 2 处 `repeatForever` 常驻动画 —— 与本文件下方 AuroraLightField 的性能
// 记录同源（repeatForever 曾让 WindowServer 负载 51.2% → 81.9%）。
// 若将来确实需要「必须接管」的整圈红边，请用一次性过渡而非 repeatForever，
// 并先确认它真的挂在某个视图上。

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

// ============================================================================
// MARK: - 银白辉光（预览框内「当前任务」卡片专用）
// ============================================================================
//
// 【为什么单开一组 token】上面 Aurora 的色板是**冰蓝**基调（ice 0x4CC9FF），
//   而用户对任务卡片的要求是**银白色**辉光 —— 是白，不是蓝。若直接把 ice
//   拿来用，卡片会发蓝光，与"银白"不符；若就地写裸值，又会绕过主题。
//   故这里补一组银白 token，命名与 ice 系列一一对应，便于日后统一调。
//
// 【为什么辉光不刺眼】银色辉光靠多层叠出来，而不是把描边刷白：
//   ① **深色玻璃底**（见下方 `scrim` 的实测理由）—— 保证文字始终读得清
//   ② 两层 shadow：近处紧（radius 9）＋ 远处散（radius 22），
//      由内到外自然衰减，避免"一圈硬白边"那种廉价感
//   ③ 描边 0.62 而不是 1.0 —— 1px 的银线一旦拉满就变成刺眼的白框
//
// ══════════════════════════════════════════════════════════════════════════
// ⚠️ 2026-10-06 实测修正：卡片底**必须是深色玻璃，不能是白色玻璃**
// ══════════════════════════════════════════════════════════════════════════
// 【怎么发现的】首版按"银白"字面理解，把填充做成白色（0xFFFFFF α0.16 叠加）。
//   在深色测试底上好看，于是又拿**亮色底**（模拟游戏里雪地/白天马路）复渲一次：
//     文本 236,238,242 ／ 卡内背景 188,192,197 → 对比度 **1.57:1**
//   而 WCAG AA 正文门槛是 4.5:1 —— 也就是说**游戏画面一亮，任务名和距离就读不出来**。
//   本卡片是"开车时要瞄一眼"的信息，读不出来等于没做。
//
// 【顺带发现它违反了本文件开头的设计铁律】
//   第 2 条：「白色只出现在 1px 描边高光上，上限 0.10」。白色填充 0.16 直接越线。
//
// 【修法】把"银白"全部放在**卡片外侧**（描边 + 两层辉光），卡片内侧改深色玻璃：
//   · 深色底 → 白字对比度稳定在 15:1 以上，无论游戏画面多亮
//   · 银白辉光在深色底上反而**更明显**（亮晕衬暗底），观感比原来更"银"
//   ⟹ 用户的「银白色辉光」要求一个字没打折，可读性还回来了。
enum AuroraSilver {

    /// 主银白（冷白，略偏中性 —— 纯 0xFFFFFF 会偏冷刺眼）
    static let core = Color(hex: 0xF2F6FF)

    /// 卡片底（**深色玻璃**）：与全 App 的玻璃面板同一族，透出背后的游戏画面。
    /// 不透明度 0.78 是实测折中：再低则亮画面下文字发灰，再高就糊成一块死黑。
    static let scrim = Color(hex: 0x05080F, alpha: 0.78)

    /// 卡片底（顶部略亮，做"玻璃"方向感 —— 注意仍是**暗**色，不是白）
    static let scrimHi = Color(hex: 0x121A26, alpha: 0.72)

    /// 描边（1px 银线；**不要**调到 1.0，会刺眼）
    static let stroke = Color(hex: 0xF2F6FF, alpha: 0.62)

    /// 辉光 —— 近层（紧、亮）。
    /// 取 0xF2F4F8 而非 0xEAF2FF：后者 B 比 R 高 21，出图实测环带会带出一丝蓝调；
    /// 银白要的是"无色"，B−R 控制在个位数才像银。
    static let glowNear = Color(hex: 0xF2F4F8, alpha: 0.50)

    /// 辉光 —— 远层（散、淡）
    static let glowFar = Color(hex: 0xE8ECF2, alpha: 0.26)

    /// 任务名文字（银白，可读性优先）
    static let textName = Color(hex: 0xF6F8FC)

    /// 距离读数（略降一档，与任务名拉开层级）
    static let textDim = Color(hex: 0xE4E9F2, alpha: 0.78)

    /// 分隔线 / 标签（「直线」「弯道」前缀）
    static let hair = Color(hex: 0xE4E9F2, alpha: 0.22)

    /// 卡片圆角（吸附到 radiusCard 档：12 —— 小方框不要用面板级 16）
    static let radius: CGFloat = Aurora.radiusCard
}
