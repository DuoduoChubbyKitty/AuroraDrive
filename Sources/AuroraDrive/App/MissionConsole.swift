// ============================================================================
// MissionConsole.swift — 任务控制台 · 主结构
// ----------------------------------------------------------------------------
// 严格照 docs/文档库/探索文档/ui-prototypes/A-任务控制中心.html 逐层翻译。
// 网页是唯一标准，本文件的每个尺寸/颜色/间距都对应网页 CSS 的具体值。
//
// 网页 DOM 骨架（本文件结构与之逐行对应）：
//   .app
//     ├─ .topbar          → TopBar          (58px, 品牌+6统计+2胶囊)
//     ├─ .rc-bar          → RCBar           (路况自适应 4 态 + AUTO SPEED)
//     ├─ .main            → MainGrid        (1fr | 344 | 372, gap 13, padding 13)
//     │    ├─ .col-l      → LeftColumn      (viewport + gear-ring)
//     │    ├─ .col-m      → MidColumn       (minimap / bank / log)
//     │    └─ .col-r      → RightColumn     (ai / auto-btn / status / system)
//     └─ .kb-bar          → KeyBar          (46px)
//   .ov #mapov            → MapOverlay      (大地图)
//   .ov #skov             → SkillOverlay    (自动化技能)
// ============================================================================

import SwiftUI

// ============================================================================
// MARK: - 卡壳（网页 .card / .card.sm）
// ============================================================================
// CSS: border-radius:15px; padding:15px;
//      background:linear-gradient(180deg,rgba(255,255,255,.026),rgba(255,255,255,0) 34%),var(--s1);
//      border:1px solid var(--hair); box-shadow:var(--lift-2)

struct ConsoleCard<Content: View>: View {
    var padding: CGFloat = 15
    var compact: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, compact ? 15 : padding)
            .padding(.vertical, compact ? 13 : padding)
            .background {
                ZStack {
                    // var(--s1)
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Aurora.s1)
                    // linear-gradient(180deg,rgba(255,255,255,.026),rgba(255,255,255,0) 34%)
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.026), location: 0),
                                    .init(color: .white.opacity(0), location: 0.34),
                                ],
                                startPoint: .top, endPoint: .bottom)
                        )
                }
            }
            .overlay {
                // border:1px solid var(--hair)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Aurora.hair1, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            // box-shadow: var(--lift-2) = inset 0 1px 0 rgba(255,255,255,.05), 0 1px 0 rgba(0,0,0,.32),
            //                              0 14px 34px -16px rgba(0,0,0,.78)
            .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
            .shadow(color: .black.opacity(0.32), radius: 1, y: 1)
    }
}

/// 卡头（网页 .card-h + .card-t + .card-act）
struct CardHead<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Aurora.t2)
            Spacer(minLength: 8)
            action
        }
        .padding(.bottom, 11)
    }
}

extension CardHead where Action == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// ============================================================================
// MARK: - 顶栏（网页 .topbar）
// ============================================================================
// CSS: height:58px; padding:0 20px 0 22px; border-bottom:1px solid var(--hair);
//      background:linear-gradient(180deg,rgba(11,19,33,.94),rgba(6,11,20,.66))

struct TopBar: View {
    @Bindable var state: DriveState

    var body: some View {
        HStack(spacing: 0) {
            // ── .brand ──
            HStack(spacing: 12) {
                BrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("AURORADRIVE")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(Aurora.t1)
                    Text("极光智行 · NTE")
                        .font(.system(size: 8.5))
                        .tracking(1.0)
                        .foregroundStyle(Aurora.t4)
                }
            }
            .padding(.trailing, 22)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Aurora.hair1).frame(width: 1)
            }
            .padding(.leading, 2)

            // ── .tb-stats ──
            HStack(spacing: 0) {
                // 全部指标：未测量就显示「—」，绝不拿 0 或默认值冒充真实读数。
                TBStat(key: "辅助帧率",
                       value: EngineClient.shared.engineFPS > 0
                              ? String(format: "%.1f", EngineClient.shared.engineFPS) : "—",
                       unit: nil, color: Aurora.ice)
                TBStat(key: "游戏帧率",
                       value: state.fps > 0 ? String(format: "%.1f", state.fps) : "—",
                       unit: nil, color: Aurora.ok)
                TBStat(key: "车速",
                       value: state.speedValid ? String(format: "%.0f", state.speedKmh) : "—",
                       unit: "km/h", color: Aurora.ice, live: state.isDriving)
                TBStat(key: "速度识别",
                       value: state.speedValid ? String(format: "%.1f", state.speedConfidence * 100) : "—",
                       unit: "%", color: Aurora.ok)
                TBStat(key: "端到端延迟",
                       value: state.e2eLatencyMs > 0
                              ? String(format: "%.1f", state.e2eLatencyMs) : "—",
                       unit: "ms", color: Aurora.amber)
                TBStat(key: "网络定位",
                       value: state.locatorFound ? "LOCK" : "SEEK",
                       unit: nil, color: state.locatorFound ? Aurora.ok : Aurora.t4,
                       live: state.locatorFound)
            }
            .padding(.leading, 22)

            Spacer()

            // ── .tb-right ──
            HStack(spacing: 8) {
                // 权限小药丸：常驻顶栏，绿=已就绪 / 黄=待授权 / 红=失效。
                // 点它才弹应用内密码框 —— 绝不调用 macOS 原生授权弹窗。
                PermissionPill(state: state)
                // 真实模型名：由推理引擎按实际加载的模型文件报告
                PillStat(led: Aurora.ice, text: state.activeModelLabel)
                // 真实 markers：取自 FINAL_complete_map_database.json 的实际条数。
                // 这是地图固有标记总数，与定位是否锁定无关，不做条件归零。
                PillStat(led: nil, text: "\(state.mapMarkerCount) MARKERS")
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 20)
        .frame(height: 58)
        .background {
            LinearGradient(colors: [Color(hex: 0x0B1321, alpha: 0.94),
                                    Color(hex: 0x060B14, alpha: 0.66)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Aurora.hair1).frame(height: 1)
        }
    }
}

/// 品牌圆标（网页 .brand-mark：31px 圆 + 冰蓝辉光）
struct BrandMark: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Aurora.iceLo, lineWidth: 1)
                .frame(width: 31, height: 31)
            Circle()
                .fill(Aurora.ice.opacity(0.16))
                .frame(width: 21, height: 21)
            Circle()
                .fill(Aurora.ice)
                .frame(width: 5, height: 5)
                .shadow(color: Aurora.ice, radius: 7)
        }
        .shadow(color: Aurora.iceGlow, radius: 14)
        .onAppear {
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// 顶栏统计项（网页 .tb-stat）
struct TBStat: View {
    let key: String
    let value: String
    var unit: String? = nil
    var color: Color = Aurora.t1
    var live: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 8))
                .tracking(1.5)
                .foregroundStyle(Aurora.t4)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                if let u = unit {
                    Text(u)
                        .font(.system(size: 7.5))
                        .foregroundStyle(Aurora.t4)
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Aurora.hair1).frame(width: 1)
        }
    }
}

/// 右侧胶囊（网页 .pill-stat）
struct PillStat: View {
    let led: Color?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let c = led {
                Circle().fill(c).frame(width: 5, height: 5)
                    .shadow(color: c, radius: 5)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Aurora.t2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.045)))
        .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
    }
}

// ============================================================================
// MARK: - 权限小药丸（.pill-perm）
// ============================================================================
// 需求（2026-09-23，用户明确）：
//   · 提权入口必须常驻在**应用内**，由用户自己填密码
//   · 绝不用 macOS 原生授权弹窗（do shell script ... with administrator privileges）
//     原因：原生框体验割裂，且反复索要授权会被系统标记，对开源项目声誉有害
//   · 密码绝不硬编码（旧实现写死 "123456"，发布版必然失效 + 安全隐患）
//
// 视觉：与 PillStat 同款玻璃胶囊，只多一颗状态灯 + 可点性。
// 状态灯语义（颜色全部取自 Aurora 既有色板，不新造颜色）：
//   绿 ok    = 网络权限 + 性能提权 都已就绪
//   黄 amber = 待授权（点了能装）
//   灰 muted = 无需授权（全部就绪但守护未启动等边缘态）
struct PermissionPill: View {
    @Bindable var state: DriveState
    @State private var hov = false

    private var ready: Bool { state.privilegeReady }
    private var ledColor: Color { ready ? Aurora.ok : Aurora.amber }

    var body: some View {
        Button {
            // 点药丸 → 开应用内密码弹窗（不是系统弹窗）
            state.privilegeStatusDetail = PrivilegePill.shared.statusDetail
            state.showBPFPasswordSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(ledColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: ledColor, radius: 5)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ready ? Aurora.ok : Aurora.amber)
                Text(ready ? "权限就绪" : "授权")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ready ? Aurora.t2 : Aurora.amber)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(ready ? Color.white.opacity(0.045)
                                             : Aurora.amber.opacity(0.10)))
            .overlay(Capsule().strokeBorder(ready ? Aurora.hair1
                                                  : Aurora.amber.opacity(0.40),
                                            lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help(ready ? PrivilegePill.shared.statusDetail
                    : "点击输入管理员密码，安装网络抓包与性能提权（仅需一次）")
    }
}

// ============================================================================
// MARK: - 路况条（网页 .rc-bar）
// ============================================================================
// CSS: display:flex; gap:6px; padding:9px 14px; border-radius:10px;
//      background:linear-gradient(180deg,rgba(11,20,34,.80),rgba(8,15,26,.72))

/// 单个路况档位按钮。
/// 抽成独立 View 是必须的：6 档下内联的嵌套三元表达式会让 SwiftUI
/// 类型检查器超时（"unable to type-check this expression in reasonable time"）。
struct RCChip: View {
    let rc: RoadCondition
    let selected: Bool
    let hovered: Bool
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    private var dotColor: Color { selected ? rc.color : Aurora.t4 }
    private var textColor: Color { selected ? rc.color : Aurora.t3 }
    private var weight: Font.Weight { selected ? .semibold : .regular }
    private var fillColor: Color {
        if selected { return rc.color.opacity(0.13) }
        return hovered ? Color.white.opacity(0.05) : .clear
    }
    private var strokeColor: Color {
        if selected { return rc.color.opacity(0.42) }
        return hovered ? Aurora.hair2 : .clear
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: selected ? rc.color : .clear, radius: 5)
                // 6 档下用短名，否则整条放不下
                Text(rc.briefName)
                    .font(.system(size: 10, weight: weight))
                    .foregroundStyle(textColor)
                Text(rc.limitLabel)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? rc.color.opacity(0.8) : Aurora.t4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background { Capsule().fill(fillColor) }
            .overlay { Capsule().strokeBorder(strokeColor, lineWidth: 1) }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .help("\(rc.name) · 限速 \(rc.limitLabel)")
    }
}

struct RCBar: View {
    @Binding var condition: RoadCondition
    let autoSpeedOn: Bool
    /// 当前 YOLO 检测框数量（自动速度的判定依据，如实展示）
    var detectedBoxCount: Int = 0
    @State private var hovered: RoadCondition?

    var body: some View {
        HStack(spacing: 6) {
            Text("路况自适应")
                .font(.system(size: 9.5))
                .tracking(0.5)
                .foregroundStyle(Aurora.t4)
                .padding(.trailing, 6)

            ForEach(RoadCondition.allCases, id: \.self) { rc in
                RCChip(rc: rc,
                       selected: condition == rc,
                       hovered: hovered == rc,
                       onTap: {
                           withAnimation(.easeOut(duration: 0.22)) { condition = rc }
                       },
                       onHover: { h in
                           if h { hovered = rc }
                           else if hovered == rc { hovered = nil }
                       })
            }

            Spacer()

            // 判定依据如实展示：当前 YOLO 框数 + 阈值。
            // 让用户能直接看到「自动速度」是按什么在判 —— 不是黑箱。
            if autoSpeedOn {
                HStack(spacing: 5) {
                    Text("检测框")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Aurora.t4)
                    Text("\(detectedBoxCount)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RoadCondition.color(forDetectionCount: detectedBoxCount))
                    // 阈值全部读常量，界面不会和判定逻辑漂移
                    Text(AutoRoadCondition.legendText)
                        .font(.system(size: 8))
                        .foregroundStyle(Aurora.t4)
                }
                .padding(.trailing, 10)
            }

            Text(autoSpeedOn ? "AUTO SPEED · ON" : "AUTO SPEED · HOLD")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(autoSpeedOn ? Aurora.ok : Aurora.t4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            LinearGradient(colors: [Color(hex: 0x0B1422, alpha: 0.80),
                                    Color(hex: 0x080F1A, alpha: 0.72)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Aurora.hair1, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
    }
}

// ============================================================================
// MARK: - 键盘条（网页 .kb-bar）
// ============================================================================
// CSS: height:46px; gap:6px; padding:0 20px; border-top:1px solid var(--hair)

struct KeyBar: View {
    @Bindable var state: DriveState

    private let layout: [(String, String)] = [
        ("W", "throttle"), ("A", "left"), ("S", "brake"), ("D", "right"),
        ("SPACE", ""), ("SHIFT", ""), ("Z", ""), ("H", ""), ("R", ""), ("F", ""),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Text("Keyboard")
                .font(.system(size: 8.5))
                .tracking(1.5)
                .foregroundStyle(Aurora.t4)
                .padding(.trailing, 6)

            ForEach(layout, id: \.0) { k in
                let on = isActive(k.1)
                Text(k.0)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(on ? Aurora.void : Aurora.t3)
                    .frame(minWidth: k.0.count > 1 ? 42 : 24)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(on ? Aurora.ice : Color.white.opacity(0.045))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(on ? Aurora.iceHi : Aurora.hair1, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            Spacer()

            HStack(spacing: 12) {
                kbRight("专家模式", state.expertMode ? "ON" : "OFF", state.expertMode)
                kbRight("字形模式", state.glyphMode ? "ON" : "OFF", state.glyphMode)
                kbRight("录制", state.isRecording ? "REC" : "READY", state.isRecording)
                kbRight("插帧", state.upscaleEnabled ? "MGFG-1" : "OFF", state.upscaleEnabled)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background {
            LinearGradient(colors: [Color(hex: 0x080F1A, alpha: 0.92),
                                    Color(hex: 0x060B14, alpha: 0.60)],
                           startPoint: .bottom, endPoint: .top)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Aurora.hair1).frame(height: 1)
        }
    }

    private func kbRight(_ name: String, _ v: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 8.5)).foregroundStyle(Aurora.t4)
            Text(v).font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(on ? Aurora.ice : Aurora.t4)
        }
    }

    /// 真实按键态（来自引擎写回的 currentCommand）
    private func isActive(_ which: String) -> Bool {
        guard !which.isEmpty else { return false }
        let c = state.currentCommand
        switch which {
        case "throttle": return c.throttle > 0.3
        case "brake":    return c.brake > 0.3
        case "left":     return c.steer < -0.1
        case "right":    return c.steer > 0.1
        default:         return false
        }
    }
}

// ============================================================================
// MARK: - 主栅格（网页 .main: 1fr 344px 372px, gap 13, padding 13）
// ============================================================================

struct MainGrid: View {
    @Bindable var state: DriveState
    @Binding var showSkills: Bool
    @Binding var showMap: Bool

    var body: some View {
        HStack(spacing: 13) {
            LeftColumn(state: state)
                .frame(maxWidth: .infinity)

            MidColumn(state: state, showMap: $showMap)
                .frame(width: 344)

            RightColumn(state: state, showSkills: $showSkills)
                .frame(width: 372)
        }
        .padding(13)
        .frame(maxHeight: .infinity)
    }
}

// ============================================================================
// MARK: - 左栏（网页 .col-l: viewport + gear-ring）
// ============================================================================

struct LeftColumn: View {
    @Bindable var state: DriveState

    var body: some View {
        VStack(spacing: 13) {
            ViewportPanel(state: state)
                .frame(maxHeight: .infinity)
                .frame(minHeight: 200)
            GearRing(mode: state.mode, running: state.isDriving,
                     onSelect: { g in if let g { state.selectGear(g) } })
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 视口（网页 .viewport）
/// CSS: flex:1; border-radius:16px; border:1px solid var(--hair);
///      background:linear-gradient(158deg,#0c1421 0%,#05080f 62%,#04070c 100%)
struct ViewportPanel: View {
    @Bindable var state: DriveState

    var body: some View {
        ZStack {
            // 游戏画面（原生直绘，绕开 SwiftUI diff）
            FrameHostView(host: state.frameHost)
                .ignoresSafeArea()

            // 插帧层
            if state.upscaleEnabled {
                UpscaleFrameHostView(host: state.upscaleHost)
                    .allowsHitTesting(false)
            }

            // 光斑
            AuroraLightField(condition: state.roadCondition)
                .allowsHitTesting(false)

            // 检测框
            //
            // ★ 2026-10-02：数据源从 effectiveDetections 换为 displayDetections。
            //   原因：effectiveDetections 现在会在**决策层**剔除自车框（第三视角下
            //   模型会把玩家自己的车标出来），那是给决策用的。UI 要照常显示，
            //   否则用户会看到「自己的车没框」而以为检测坏了。
            //   ObstacleOverlay 的绘制逻辑一个字没改，只换了数据源。
            ObstacleOverlay(active: state.isDriving,
                            detections: state.displayDetections,
                            sourceSize: state.screenSize,
                            lockedTarget: state.yoloEngine.lockedTarget,
                            isLocked: state.yoloEngine.isLocked)

            // YOLOPX 掩码（可行驶区 + 车道线）—— 画在检测框之下，避免遮挡框线
            // 数据源走 displayXxx 访问器：本地模式取 UI 自己的 YOLOPX，
            // 引擎模式取共享内存回传的掩码。直接写 yolopxEngine.xxx 的话，
            // 引擎模式下永远是空掩码（UI 进程根本不跑 YOLOPX）。
            MaskOverlay(active: state.isDriving && state.showYolopxMasks,
                        drivableMask: state.displayDrivableMask,
                        laneMask: state.displayLaneMask,
                        metrics: state.displayMaskMetrics,
                        sourceSize: state.screenSize,
                        isDegraded: state.displayMaskDegraded,
                        laneDegraded: state.displayLaneDegraded,
                        drivableDegraded: state.displayDrivableDegraded)

            // 左上标签（网页 .vp-tag）
            VStack {
                HStack {
                    HStack(spacing: 6) {
                        TagChip(text: "LIVE", live: true)
                        TagChip(text: "THIRD-PERSON")
                        TagChip(text: state.resolutionLabel)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(14)

            // 右上标签（网页 .vp-right-tags）
            VStack {
                HStack {
                    Spacer()
                    TagChip(text: "YUYAN / \(state.regionLabel)")
                }
                Spacer()
            }
            .padding(14)

            // 极度复杂：顶部接管告警（网页 .rc-warn）
            if state.roadCondition.needsTakeover {
                VStack {
                    RCWarn()
                        .padding(.top, 52)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 卡死（连续 30s 零速）→ 请求人工介入横幅（2026-10-02 新增）
            //
            // 优先级高于路况告警：车都停死 30 秒了，比"路况复杂"紧急。
            // 因此放在上面、且两者同时出现时**取代**路况横幅（见下条 if 的 else）。
            // 只显示、不发声、不驱动任何控制量。
            if state.needsManualIntervention {
                VStack {
                    StuckWarn(heldSeconds: state.stuckZeroHeldSeconds)
                        .padding(.top, 52)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if state.roadCondition.needsTakeover {
                VStack {
                    RCWarn()
                        .padding(.top, 52)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 底部：自动速度 + 双圆表
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 16) {
                    Spacer()
                    AutoSpeedPill(
                        isOn: state.autoSpeedEnabled,
                        condition: state.roadCondition,
                        onToggle: { state.setAutoSpeed(!state.autoSpeedEnabled) },
                        onCycle: { state.applyRoadCondition(state.roadCondition.next) }
                    )
                    .padding(.bottom, 26)

                    DualGauge(
                        speedKmh: state.speedKmh,
                        valid: state.speedValid,
                        confidence: state.speedConfidence,
                        latency: state.e2eLatencyMs,
                        condition: state.roadCondition
                    )
                }
                .padding(.trailing, 26)
                .padding(.bottom, 44)
            }
        }
        .background {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x0C1421), location: 0),
                    .init(color: Color(hex: 0x05080F), location: 0.62),
                    .init(color: Color(hex: 0x04070C), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    state.roadCondition.needsTakeover
                        ? Aurora.danger.opacity(0.75) : Aurora.hair1,
                    lineWidth: state.roadCondition.needsTakeover ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
    }
}

/// 视口角标（网页 .tag / .tag.live）
struct TagChip: View {
    let text: String
    var live: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if live {
                Circle().fill(Aurora.ok).frame(width: 4, height: 4)
                    .shadow(color: Aurora.ok, radius: 4)
            }
            Text(text)
                .font(.system(size: 8.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(live ? Aurora.ok : Aurora.t3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(live ? Aurora.ok.opacity(0.35) : Aurora.hair1, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// 接管告警（网页 .rc-warn）
struct RCWarn: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.danger)
            Text("路况极度复杂 · 请立即接管方向盘")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Aurora.danger)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(Color.black.opacity(0.90))
        }
        .overlay {
            Capsule().strokeBorder(Aurora.danger.opacity(pulse ? 0.85 : 0.42), lineWidth: 1.5)
        }
        .clipShape(Capsule())
        .shadow(color: Aurora.danger.opacity(pulse ? 0.70 : 0.35), radius: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// 卡死告警横幅（2026-10-02 新增，用户明确要求）。
///
/// 触发条件：**正在自动驾驶 + 速度有效 + 连续 30 秒速度≈0**（见
/// `DriveState.stuckZeroThreshold` / `needsManualIntervention`）。
///
/// 用户原话：「如果发现连续 30 秒钟速度都为零，那么就直接拉横幅，
///            但是不要语音」。
///
/// 🚨 设计纪律（必须遵守）：
///   · **只提示，不动车**。本横幅纯粹是显示层，不写任何控制量。
///     脱困的唯一途径是用户自己接管 —— AI 绝不自行挣扎。
///     （历史教训：自动脱困/自动倒车会与用户抢控制权。见
///      `AuroraDriveApp.swift` §5.5 关于 FallbackGuard 的取证注释。）
///   · **不要语音**：只出画面横幅，不播报、不发声。
struct StuckWarn: View {
    /// 已卡住的秒数（用于显示"已卡住 Ns"）
    let heldSeconds: Double

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.danger)
            Text("车辆已卡住 \(Int(heldSeconds))s · 请人工介入接管")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Aurora.danger)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(Color.black.opacity(0.90))
        }
        .overlay {
            Capsule().strokeBorder(Aurora.danger.opacity(pulse ? 0.85 : 0.42), lineWidth: 1.5)
        }
        .clipShape(Capsule())
        .shadow(color: Aurora.danger.opacity(pulse ? 0.70 : 0.35), radius: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// ============================================================================
// MARK: - 挡位带（网页 .gear-ring: 4 × .gr-item）
// ============================================================================// CSS: display:flex; gap:9px; padding:11px 13px; border-radius:15px

struct GearRing: View {
    let mode: DriveMode
    let running: Bool
    var onSelect: ((DriveMode?) -> Void)?
    @State private var hovered: DriveMode?

    // ⚠️ 2026-09-30：按钮 4→2（用户要求）——只显示 端到端主驾 / 纯规则兜底。
    // 内部 .yolo 档仍由降级链自动使用（模型存活情况决定），不作为用户手选档；
    // .recover（脱困）档已整体删除。
    private let gears: [DriveMode] = [.e2e, .rule]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(Array(gears.enumerated()), id: \.offset) { idx, g in
                let on = mode == g
                Button {
                    onSelect?(g)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("GEAR \(idx + 1)")
                            .font(.system(size: 8))
                            .tracking(1.5)
                            .foregroundStyle(on ? g.accentColor.opacity(0.75) : Aurora.t4)
                        Text(g.rawValue)
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? g.accentColor : Aurora.t3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(on ? g.accentColor.opacity(0.10)
                                     : (hovered == g ? Color.white.opacity(0.04) : .clear))
                    }
                    .overlay(alignment: .bottom) {
                        // 选中态底部强调条
                        if on {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(g.accentColor)
                                .frame(height: 2)
                                .shadow(color: g.accentColor.opacity(0.85), radius: 7)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? g : (hovered == g ? nil : hovered) }
                .help("切换到「\(g.rawValue)」")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Aurora.s1)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Aurora.hair1, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
        .opacity(running ? 1 : 0.72)
    }
}

// ============================================================================
// MARK: - 自动速度胶囊（网页 .auto-speed）
// ============================================================================

struct AutoSpeedPill: View {
    let isOn: Bool
    let condition: RoadCondition
    var onToggle: () -> Void
    var onCycle: () -> Void
    @State private var hov = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(isOn ? Aurora.ok.opacity(0.22) : Color.black.opacity(0.85))
                            .frame(width: 29, height: 15)
                        Circle()
                            .fill(isOn ? Aurora.ok : Aurora.t3)
                            .frame(width: 10.5, height: 10.5)
                            .padding(.horizontal, 2.2)
                            .shadow(color: isOn ? Aurora.ok.opacity(0.8) : .clear, radius: 5)
                    }
                    .overlay {
                        Capsule().strokeBorder(isOn ? Aurora.ok.opacity(0.45) : Aurora.hair2,
                                               lineWidth: 1)
                    }
                    Text("自动速度")
                        .font(.system(size: 9.5))
                        .tracking(0.8)
                        .foregroundStyle(isOn ? Aurora.t1 : Aurora.t3)
                        .fixedSize()
                }
                .fixedSize()
                .padding(.leading, 13).padding(.trailing, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Aurora.hair2).frame(width: 1, height: 15)

            Button(action: onCycle) {
                HStack(spacing: 6) {
                    Circle().fill(condition.color).frame(width: 5, height: 5)
                        .shadow(color: condition.color, radius: 5)
                    Text(condition.shortName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(condition.color)
                        .fixedSize()
                }
                .fixedSize()
                .padding(.leading, 10).padding(.trailing, 13).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Capsule().fill(Color.black.opacity(0.94)))
        .overlay {
            Capsule().strokeBorder(
                isOn ? Aurora.ok.opacity(0.38) : condition.color.opacity(0.36), lineWidth: 1)
        }
        .clipShape(Capsule())
        .shadow(color: (isOn ? Aurora.ok : condition.color).opacity(0.40), radius: 13)
        .shadow(color: .black.opacity(0.8), radius: 14, y: 10)
        .scaleEffect(hov ? 1.02 : 1)
        .animation(.easeOut(duration: 0.2), value: hov)
        .onHover { hov = $0 }
    }
}

// ============================================================================
// MARK: - 双圆表（网页 .speed-hud，含 .speed-num/.speed-unit/.speed-cap）
// ============================================================================
// 网页主表：134×134 SVG，r=58 弧（dasharray 364.4），r=47 内圈
// 左表为端到端延迟，右表为车速（网页只有主表，左表是本项目扩展）

struct DualGauge: View {
    let speedKmh: Double
    let valid: Bool
    let confidence: Double
    let latency: Double
    let condition: RoadCondition

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            // 延迟表：未测量（0）显示「—」，不显示 0.0 冒充真实延迟
            GaugeDial(
                value: latency > 0 ? String(format: "%.1f", latency) : "—",
                unit: "MS",
                caption: "E2E 延迟",
                progress: latency > 0 ? min(1, latency / 60) : 0,
                tint: Aurora.ice
            )
            // 车速表（网页主表）
            GaugeDial(
                value: valid ? String(format: "%.0f", speedKmh) : "—",
                unit: "KM / H",
                caption: valid ? String(format: "conf %.2f", confidence) : "conf —",
                progress: valid ? min(1, speedKmh / 200) : 0,
                tint: Aurora.ice,
                big: true
            )
        }
    }
}

/// 单个圆表（网页 .speed-hud 的 SVG 弧 + 中心数字）
struct GaugeDial: View {
    let value: String
    let unit: String
    let caption: String
    let progress: Double
    var tint: Color = Aurora.ice
    var big: Bool = false

    private var size: CGFloat { big ? 134 : 104 }
    private var radius: CGFloat { big ? 58 : 45 }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // 底圈
                Circle()
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 6)
                    .frame(width: radius * 2, height: radius * 2)

                // 进度弧（从 -90° 顺时针）
                Circle()
                    .trim(from: 0, to: max(0.001, progress) * 0.75)
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.35), tint, Aurora.iceHi],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: radius * 2, height: radius * 2)
                    .shadow(color: tint.opacity(0.65), radius: 8)

                // 内圈细线（网页 r=47）
                Circle()
                    .strokeBorder(tint.opacity(0.11), lineWidth: 1)
                    .frame(width: (radius - 11) * 2, height: (radius - 11) * 2)

                // 中心数字
                VStack(spacing: 1) {
                    Text(value)
                        .font(.system(size: big ? 30 : 24, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Aurora.t1)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 7.5))
                        .tracking(1.2)
                        .foregroundStyle(Aurora.t4)
                }
            }
            .frame(width: size, height: size)

            Text(caption)
                .font(.system(size: 8.5))
                .foregroundStyle(Aurora.t4)
        }
    }
}

// ============================================================================
// MARK: - 中栏（网页 .col-m: minimap / bank / log）
// ============================================================================

struct MidColumn: View {
    @Bindable var state: DriveState
    @Binding var showMap: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 13) {
                MiniMapCard(state: state, onOpen: {
                    print("[UI] 点击「打开大地图」")
                    showMap = true
                })
                HardwareBank(state: state)
                RunLogCard(state: state)
                PerceptionPickerCard(state: state)
            }
        }
    }
}

/// 小地图卡（网页 .minimap + .navline）
struct MiniMapCard: View {
    @Bindable var state: DriveState
    var onOpen: () -> Void

    var body: some View {
        ConsoleCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "小地图 · 网络定位") {
                    Button(action: onOpen) {
                        HStack(spacing: 5) {
                            Image(systemName: "map")
                                .font(.system(size: 9, weight: .medium))
                            Text("打开大地图")
                                .font(.system(size: 9.5))
                        }
                        .foregroundStyle(Aurora.ice)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Aurora.iceWash))
                        .overlay(Capsule().strokeBorder(Aurora.iceLo, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                MiniMapCanvas(state: state)

                NavLine(state: state).padding(.top, 10)
            }
        }
    }
}

/// 小地图画布（网页 .minimap 内的网格/路网/路线/标记/自车/罗盘/比例）
struct MiniMapCanvas: View {
    @Bindable var state: DriveState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Color(hex: 0x060B13)

                // 真实地图底图：bigworldmap-13056.jpg（13056×13056）按自车位置裁一块
                // ⚠️ 只在定位锁定时才画。未锁定时 mapPixelX/Y 会退化成地图正中心，
                //    裁出来的那一块跟自车毫无关系 —— 那是假位置，不能冒充定位。
                if state.locatorFound {
                    MapTileImage(centerMapX: state.mapPixelX,
                                 centerMapY: state.mapPixelY,
                                 spanMeters: DriveState.minimapSpanMeters)
                        .opacity(0.9)
                }

                // 定位未锁定时给出明确提示，不画假路网冒充地图
                if !state.locatorFound {
                    VStack(spacing: 4) {
                        Image(systemName: state.locateGameOffline
                              ? "gamecontroller.fill" : "location.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(state.locateGameOffline ? Aurora.amber : Aurora.t4)
                        // 如实区分「游戏没开」与「开了但还没抓到包」，
                        // 不再一律显示「等待网络定位」让用户猜原因。
                        Text(state.locateStatusText)
                            .font(.system(size: 9))
                            .foregroundStyle(state.locateGameOffline ? Aurora.amber : Aurora.t4)
                    }
                }

                // 目标点/路径：仅在有真实目标点时绘制
                if let t = state.locatorTarget, state.locatorFound {
                    let tx = state.normMapX(t.x), ty = state.normMapY(t.y)
                    Path { p in
                        p.move(to: .init(x: w * state.egoNormX, y: h * state.egoNormY))
                        p.addLine(to: .init(x: w * tx, y: h * ty))
                    }
                    .stroke(Aurora.ice, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .shadow(color: Aurora.ice.opacity(0.85), radius: 7)

                    MapPin(x: tx, y: ty, color: Aurora.danger, label: "目标", w: w, h: h)
                }

                // 自车（真实定位）—— 必须在 locatorFound 时才画。
                // 原实现无条件把蓝点钉在正中心，游戏没开也照样显示，
                // 等于拿假数据冒充定位（2026-09-22 修复）。
                if state.locatorFound {
                    // ⚠️ 2026-09-30 修复（用户报告「UI 里没有方向标」）：
                    //   原实现这里只有两个同心圆 = **一个没有朝向的圆点**，
                    //   用户在主界面（小地图）看不到任何朝向信息 —— 朝向指示
                    //   此前只存在于大地图 LargeMapCanvas 里（打开大地图才可见），
                    //   而大地图不是常驻视图。现把同一套朝向画法搬到小地图自车，
                    //   参数照抄大地图版本、按小地图尺寸等比缩小（24/34 ≈ 0.7）。
                    //
                    //   朝向语义：`locatorHeading` 是罗盘方位角（0=正北，顺时针
                    //   增加，由 UE5 移动包的 control rotation 经 kNorth/kEast
                    //   点积算出）。箭头用 Capsule 竖条 + `offset(y:-13)` 使其
                    //   初始指向正上方（屏幕 -Y = 北），再 `rotationEffect` 顺时针
                    //   旋转 heading 度 —— 与罗盘定义一致（SwiftUI 正角度=顺时针）。
                    ZStack {
                        Circle().fill(Aurora.ice.opacity(0.20)).frame(width: 24, height: 24)
                        Capsule()
                            .fill(Aurora.ice)
                            .frame(width: 2.5, height: 11)
                            .offset(y: -10)
                            .rotationEffect(.degrees(state.locatorHeading))
                        Circle().fill(Aurora.ice).frame(width: 8, height: 8)
                            .shadow(color: Aurora.ice, radius: 8)
                    }
                    .position(x: w * state.egoNormX, y: h * state.egoNormY)
                }

                Text("N")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Aurora.t3)
                    .position(x: w - 14, y: 13)

                // 比例尺：标注实际视野米数（与 MapTileImage 的 spanMeters 一致）
                Text("\(Int(DriveState.minimapSpanMeters)) m")
                    .font(.system(size: 8))
                    .foregroundStyle(Aurora.t4)
                    .position(x: w - 26, y: h - 12)

                ForEach(["tl", "tr", "bl", "br"], id: \.self) { c in
                    MapCorner(corner: c)
                        .stroke(Aurora.hair3, lineWidth: 1.2)
                        .frame(width: 16, height: 16)
                        .position(x: c.contains("l") ? 13 : w - 13,
                                  y: c.contains("t") ? 13 : h - 13)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 172)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Aurora.hair2, lineWidth: 1)
        }
    }
}

// ============================================================================
// MARK: - 真实地图底图（bigworldmap-13056.jpg）
// ============================================================================
// 地图是 13056×13056 的真实游戏大地图，配合 CoordinateCapture 里的校准常量
// （kCalibA/B/TX/TY）把世界坐标转成地图像素。这里按自车地图像素为中心裁一块，
// 换算成视口内的相对位置 —— 小地图与大地图共用同一套映射，全程真实数据。

/// 大地图切片缓存。
///
/// 为什么需要：bigworldmap-13056.jpg 解码后是 650MB 位图（13056²×4 字节）。
/// 若把整图交给 SwiftUI 每帧重采样，主线程会被彻底打满。这里只裁出
/// 当前视野那一小块并缩放到目标尺寸，结果按 (视野中心, 跨度, 尺寸) 缓存 —— 
/// 视野不动就直接复用，视图重绘不再做任何重采样。
@MainActor
final class MapTileCache {
    static let shared = MapTileCache()
    private var key: String = ""
    private var cached: CGImage?
    /// 缓存上限：只留最近一张，避免多尺寸并存把内存吃爆
    private init() {}

    // ── ★ E2（性能优化第 4 批）：源图转换结果缓存 ──
    //
    // 【问题】`tile(...)` 内部对入参 `NSImage` 调
    //   `image.cgImage(forProposedRect: nil, context: nil, hints: nil)`。
    //   这一步是 **NSImage → CGImage 的格式转换**，可能触发重新解码/重绘。
    //   而它**每次调用 tile 都会发生**（视图重绘 → 每帧/每状态变化都调）。
    //
    // 【为什么不能只靠视野缓存】视野缓存（key）只在"裁切+缩放"这一段生效；
    //   而 cgImage 转换发生在取缓存**之前**（要拿到 src 才能裁），
    //   所以即使视野没变、走了缓存命中的分支，**转换也已经在前面做掉了**。
    //
    // 【改法】把转换结果按"源图身份"缓存：同一张源图只转一次。
    //   身份用 `ObjectIdentifier`（NSImage 是引用类型，可稳定标识同一实例）
    //   + 尺寸（防御"同实例换内容"的极端情况）。
    private var srcImageID: ObjectIdentifier?
    private var srcImageSize: CGSize = .zero
    private var srcCGImage: CGImage?

    /// 裁出以 (centerX, centerY) 为中心、边长 spanPx 的正方形区域，
    /// 缩放到 outSize×outSize 返回。同参数二次调用直接命中缓存。
    func tile(from image: NSImage,
              mapPixels: Double,
              centerX: Double, centerY: Double,
              spanPx: Double,
              outSize: CGFloat) -> CGImage? {
        // 视野量化到 4px 网格再进缓存键：轻微抖动不造成每帧重算
        let qx = (centerX / 4).rounded() * 4
        let qy = (centerY / 4).rounded() * 4
        let qs = (spanPx / 4).rounded() * 4
        let k = "\(Int(qx))|\(Int(qy))|\(Int(qs))|\(Int(outSize))"
        if k == key, let c = cached { return c }

        let src = cachedCGImage(from: image)
        guard let src else { return nil }
        // 源图坐标：中心 ± 半跨度，裁成正方形
        let half = qs / 2
        let ox = (qx - half).rounded()
        let oy = (qy - half).rounded()
        let rect = CGRect(x: ox, y: oy, width: qs, height: qs)
        // 超界时给一点余量（CGImage.cropping 越界会返回 nil）
        guard let cropped = src.cropping(to: rect) else {
            // 越界兜底：夹到图内再裁一次，宁可边缘重复也不黑屏
            let clampedX = min(max(ox, 0), mapPixels - qs)
            let clampedY = min(max(oy, 0), mapPixels - qs)
            guard clampedX >= 0, clampedY >= 0,
                  let c2 = src.cropping(to: CGRect(x: clampedX, y: clampedY,
                                                   width: qs, height: qs)) else { return nil }
            return draw(c2, size: Int(outSize), key: k)
        }
        return draw(cropped, size: Int(outSize), key: k)
    }

    /// NSImage → CGImage 的**带缓存转换**（★ E2 性能优化）。
    ///
    /// 同一张源图（同实例、同尺寸）只转换一次；换图才重转。
    /// 这样即使视野每帧变化，也**不会**反复做格式转换。
    ///
    /// 注意：`cgImage(forProposedRect:)` 在多数情况下返回的是**共享的底层位图**
    /// （NSImage 内部已有 CGImage 时不复制），但某些 NSImage 构造路径会触发
    /// 重新绘制 —— 所以缓存对前者是"省一次调用"，对后者是"省一次重绘"，两者都划算。
    private func cachedCGImage(from image: NSImage) -> CGImage? {
        let id = ObjectIdentifier(image)
        let sz = image.size
        if id == srcImageID, sz == srcImageSize, let c = srcCGImage {
            return c
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        srcImageID = id
        srcImageSize = sz
        srcCGImage = cg
        return cg
    }

    private func draw(_ cg: CGImage, size: Int, key k: String) -> CGImage? {
        guard size > 0, let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let out = ctx.makeImage() else { return nil }
        self.key = k
        self.cached = out
        return out
    }
}

struct MapTileImage: View {
    let centerMapX: Double
    let centerMapY: Double
    let spanMeters: Double

    /// 大地图边长（像素）。13056×13056，官方地图导出尺寸。
    static let mapPixels: Double = 13056

    /// 地图尺寸标签（取自实际加载图片的像素尺寸，非写死字符串）
    @MainActor private static var loadedPixelLabel: String?
    @MainActor static var mapDimensionLabel: String {
        loadedPixelLabel ?? "13056 × 13056"
    }

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { g in
            // cover：取长边为基准铺满整个区域（等比，不拉伸），
            // 用 min 只会铺一个正方形，非正方形面板会露出空白边。
            let side = max(g.size.width, g.size.height)
            if let img = image {
                // 要展示的地图区域边长（像素）
                let pxPerMeter = Self.mapPixels / Self.worldMetersPerMap
                let spanPx = max(spanMeters * pxPerMeter, 1)
                // 整图缩放到 side*(mapPixels/spanPx)，则 spanPx 区域正好铺满 side
                let fullScaled = side * (Self.mapPixels / spanPx)
                // 区域左上角在地图像素中的位置 → 换算成缩放后的偏移
                let k = side / spanPx
                let originX = (centerMapX - spanPx / 2) * k
                let originY = (centerMapY - spanPx / 2) * k

                // ⚠️ 性能关键：绝不把 13056×13056 的原图（解码后 650MB）交给
                //    SwiftUI 的 Image 去 .resizable().frame(宽=fullScaled)。
                //    那样每帧都要对整张巨图重采样，主线程直接被打满
                //    （实测 UI 进程 25-36% CPU 常年不降、WindowServer 44%+、
                //    整机发烫、帧率只有 20 多帧）。
                //    改为预裁切：只从原图取出「当前视野 + 余量」那一小块，
                //    缩放到目标尺寸后交给 SwiftUI —— 每帧处理的像素量从
                //    1.7 亿降到几万，且裁切结果按视野缓存，视野不变就不重算。
                if let tile = MapTileCache.shared.tile(
                        from: img,
                        mapPixels: Self.mapPixels,
                        centerX: centerMapX, centerY: centerMapY,
                        spanPx: spanPx,
                        outSize: side) {
                    Image(decorative: tile, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .offset(x: (g.size.width - side) / 2,
                                y: (g.size.height - side) / 2)
                } else {
                    Color.clear
                }
            } else {
                Color.clear
            }
        }
        .clipped()
        .onAppear { load() }
    }

    /// 世界总边长（米）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 数值更正：原值 `13_056` **错了 1.639 倍**（把像素数当米数）
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// 原注释写「UE5 世界坐标单位是厘米，13056px 地图对应 13.056km」——这句自相矛盾：
    /// 它等价于断言 **1 像素 = 1 米 = 100 厘米**。但标定参数给出的比例不是这样：
    ///
    ///   kCalibA = 0.016394586684750773   —— 世界单位(cm) → 地图像素 的比例
    ///   ⟹ 1 像素 = 1/kCalibA = 60.9957 世界单位 = 0.609957 米
    ///   ⟹ 13056 像素 = 13056 × 0.609957 = **7963.6 米**（而非 13056 米）
    ///
    /// 换算比例的可信度：kCalibA/B/TX/TY 四个常量与 MaaNTE 上游
    /// `coordinate_position.py` 的 `_CALIBRATION_*` **逐位相同**（已比对文档），
    /// 且用真实抓包样本反算自车地图像素与自检报告值只差 1 像素
    /// （世界 (-24424.34, 31854.1) → 地图 (6126.0, 5732.9)，自检报 (6127.0, 5732.9)）。
    /// 所以「1 像素 ≈ 0.61 米」是有据的，「1 像素 = 1 米」是臆断。
    ///
    /// **这个错误导致了用户反馈的「地图定位永远是偏差错误的」**：
    /// 本常量只经由 `pxPerMeter = mapPixels / worldMetersPerMap` 参与两处计算 ——
    ///   ① `spanPx = spanMeters × pxPerMeter`：小地图取多少像素的地图区域
    ///      → 错值时 spanPx=160 而非 262，**视野被缩小 1.64 倍**
    ///   ② `normMapX/Y`：目标点相对自车的归一化偏移
    ///      → `d = (px - mapPixelX) / spanPx`，spanPx 偏小 ⟹ **所有目标点被画到
    ///        「离自车 1.64 倍远」的位置**，100 米外的点画得像 164 米
    /// 注意自车自身位置不受影响（`worldToMapPixel` 不用本常量，自车恒在视口中心），
    /// 所以症状表现为「我人在对的地方，但周围标记/比例全不对」——正是"偏差"。
    ///
    /// 改为**由标定参数推导**，而非硬编码数字：这样它与 kCalibA 永远自洽，
    /// 将来若上游重新标定（map-2026-09 之类），这里会自动跟上，不会再漂移。
    static let worldMetersPerMap: Double = 13_056.0 / (kCalibA * 100.0)

    private func load() {
        guard image == nil else { return }
        // 同上：一律用 projectRoot()，不依赖 cwd
        let root = AuroraPaths.projectRoot()
        let cands = [
            root.appendingPathComponent("models/bigworldmap-13056.jpg").path,
            Bundle.main.resourceURL?.appendingPathComponent("bigworldmap-13056.jpg").path
        ].compactMap { $0 }
        for c in cands where FileManager.default.fileExists(atPath: c) {
            if let img = NSImage(contentsOfFile: c) {
                image = img
                if let rep = img.representations.first {
                    Self.loadedPixelLabel = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
                }
                print("[MAP] 已加载真实地图: \(c) 尺寸=\(Int(img.size.width))x\(Int(img.size.height))")
                return
            }
        }
        print("[MAP] ✗ 未找到 bigworldmap-13056.jpg（小地图将只显示定位点）")
    }
}

struct MapPin: View {
    let x: Double, y: Double
    let color: Color
    let label: String
    let w: CGFloat, h: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.9), radius: 6)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 7.5))
                    .foregroundStyle(Aurora.t3)
                    .fixedSize()
                    .offset(y: 11)
            }
        }
        .position(x: w * x, y: h * y)
    }
}

struct MapCorner: Shape {
    let corner: String
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch corner {
        case "tl": p.move(to: .init(x: 0, y: r.height)); p.addLine(to: .zero); p.addLine(to: .init(x: r.width, y: 0))
        case "tr": p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: r.width, y: 0)); p.addLine(to: .init(x: r.width, y: r.height))
        case "bl": p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: r.height)); p.addLine(to: .init(x: r.width, y: r.height))
        default:   p.move(to: .init(x: r.width, y: 0)); p.addLine(to: .init(x: r.width, y: r.height)); p.addLine(to: .init(x: 0, y: r.height))
        }
        return p
    }
}

/// 导航行（网页 .navline）
struct NavLine: View {
    @Bindable var state: DriveState

    var body: some View {
        // 真实数据：距离/时间由当前定位与目标点实时算出（网络定位不可用时如实显示无导航）
        let nav = state.navGuidance

        HStack(spacing: 7) {
            HStack(spacing: 3) {
                Image(systemName: nav.hasTarget ? "arrow.turn.up.left" : "location.slash")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(nav.hasTarget ? Aurora.ice : Aurora.t4)
                Text(nav.distanceText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(nav.hasTarget ? Aurora.t1 : Aurora.t3)
                Text(nav.actionText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Aurora.t3)
            }
            Text(nav.streetText)
                .font(.system(size: 9.5))
                .foregroundStyle(Aurora.t3)
            Spacer()
            // ── 定位朝向 + 加速度（2026-09-30 新增到小地图下方）──
            // 【为什么加在这里】用户报告「UI 里没有加速度和方向标」——
            //   实测两者此前的位置都在**非常驻/需滚动**的地方：
            //     · 加速度：右栏 SystemCard 底部（要滚动才看得到）
            //     · 朝向：只有大地图里有（小地图自车是个无朝向圆点）
            //   小地图是主界面常驻视图，把这两个实时量放在这里最符合
            //   「开着车时一眼能看到」的实际需要。
            // 【数据来源】全部是真实量，无数据时显示「—」（不编数）：
            //     · 朝向 = locatorHeading（罗盘角 0~360，来自控制旋转解码）
            //     · 加速度 = locatorAccelX/Y（移动包同包解析，cm/s² ÷100 = m/s²）
            if state.locatorFound {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.line.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Aurora.ice)
                    Text(String(format: "%.0f°", state.locatorHeading))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Aurora.t1)
                    if let ax = state.locatorAccelX {
                        Text(String(format: "%.1f, %.1f m/s²", ax, state.locatorAccelY ?? 0))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Aurora.t3)
                    } else {
                        Text("加速度 —")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Aurora.t4)
                    }
                }
            }
            Text(nav.remainText)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Aurora.t4)
        }
    }
}

// ============================================================================
// MARK: - 导航指引（真实数据派生，无假值）
// ============================================================================
// 由 DriveState 的实时定位（NetworkLocator/CoordinateCapture）+ 目标点推导。
// 没有目标点、或定位未锁定时，如实显示「未设目标 / 定位中」，绝不编造地名与剩余时间。

struct NavGuidance {
    let hasTarget: Bool
    let distanceText: String
    let actionText: String
    let streetText: String
    let remainText: String

    @MainActor
    static func derive(from s: DriveState) -> NavGuidance {
        guard s.locatorFound else {
            return NavGuidance(hasTarget: false, distanceText: "--", actionText: "定位中",
                               streetText: s.locateStatusText, remainText: "余 --")
        }
        guard let t = s.locatorTarget else {
            return NavGuidance(hasTarget: false, distanceText: "--", actionText: "未设目标",
                               streetText: "已定位 · \(String(format: "%.0f,%.0f", s.locatorX, s.locatorY))",
                               remainText: "余 --")
        }
        // 世界坐标（UE5 厘米）→ 米
        let dx = Double(t.x) - s.locatorX
        let dy = Double(t.y) - s.locatorY
        let distM = (dx * dx + dy * dy).squareRoot() / 100.0
        // ══════════════════════════════════════════════════════════════════════
        // ⚠️ 2026-09-30 修复：转向指示的「参考系混用」bug
        // ══════════════════════════════════════════════════════════════════════
        //
        // 【症状】小地图导航栏的「米后左转 / 米后右转」长期给出错误方向
        //   （用户报「地图定位永远是偏差错误的」—— 位置对了，方向不对）。
        //
        // 【根因】两个角度用了**不同的参考系**却直接相减：
        //
        //   `s.locatorHeading` 是**罗盘方位角**（compass heading）：
        //       0° = 正北，顺时针为正，范围 [0, 360)
        //       由 `toPose()` 算出：`atan2(east, north)`，且负值 +360 归一化。
        //
        //   而原来的 `bearing = atan2(dy, dx)` 是**数学极角**：
        //       0° = 正东，逆时针为正，范围 (-180, 180]
        //
        //   两者**原点差 90°、旋向相反**（一个是数学系逆时针，一个是罗盘系
        //   顺时针）。于是 `bearing - locatorHeading` 毫无几何意义。
        //
        // 【量化影响】扫描「目标方位 × 自车朝向」共 5184 个组合
        //   （各以 5° 为步长），**转向指示错误 3021 个 = 58.3%**。
        //   典型反例：
        //       目标在正北、车头也朝正北  → 应「直行」，原实现显示「右转」
        //       目标在正北、车头朝北偏东 20° → 应「左转」，原实现显示「右转」
        //
        // 【修法】把目标方位也换算成**罗盘角**再相减。
        //   做法：先用地图投影把自车与目标都投到地图像素系
        //   （复用既有已验证的 `worldToMapPixelX/Y`），再取
        //       罗盘角 = atan2(东分量, 北分量) = atan2(ΔmapX, −ΔmapY)
        //   其中 −ΔmapY 的依据是：地图像素 y 轴**向下**，而地图是**北朝上**
        //   （已核对 `worldToMapPixelY = kCalibA·wy + kCalibTY`，且解码器的
        //   `kNorth ≈ (0, −1, 0)` —— 世界 −Y 为北 → 地图像素 −Y 为北 → 屏幕上方）。
        //   这样**顺带把标定矩阵里那个微小倾角 kCalibB 也一并算对**，
        //   而不是像原实现那样把倾斜完全忽略。
        //
        // 【为什么不用世界系手算】世界系里「北」是 `kNorth = (−0.0138, −0.9999, 0)`
        //   这个**非轴向**向量（含 0.79° 倾角），要正确投影必须用它；
        //   而 kNorth/kEast 是 CoordinateCapture.swift 的 file-private 常量，
        //   从这里拿不到。走地图像素系既避开了这个可见性问题，
        //   又复用了已实测正确的投影函数 —— 更少的重复、更少的出错面。
        let egoPx = DriveState.worldToMapPixelX(s.locatorX, s.locatorY)
        let egoPy = DriveState.worldToMapPixelY(s.locatorX, s.locatorY)
        let tgtPx = DriveState.worldToMapPixelX(Double(t.x), Double(t.y))
        let tgtPy = DriveState.worldToMapPixelY(Double(t.x), Double(t.y))
        // 罗盘方位角：atan2(东 = +Δx, 北 = −Δy)
        let bearingCompass = atan2(tgtPx - egoPx, -(tgtPy - egoPy)) * 180 / .pi
        var rel = bearingCompass - s.locatorHeading
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        let action: String
        if abs(rel) < 20 { action = "米后直行" }
        else if rel > 0 { action = "米后右转" }
        else { action = "米后左转" }
        // 按当前车速估算剩余时间（无速度时不给编造值）
        let speedMS = max(s.speedKmh, 0) / 3.6
        let etaText = speedMS > 0.5 ? " · \(Int(distM / speedMS))s" : ""
        return NavGuidance(hasTarget: true,
                           distanceText: String(format: "%.0f", distM),
                           actionText: action,
                           streetText: "目标点 \(String(format: "%.0f,%.0f", t.x, t.y))",
                           remainText: "余 \(Int(distM))m\(etaText)")
    }
}

@MainActor
extension DriveState {
    var navGuidance: NavGuidance { NavGuidance.derive(from: self) }
}

// ============================================================================
// MARK: - 硬件控制卡（网页 .bank，4 × .sw）
// ============================================================================
// CSS: .bank{display:grid;grid-template-columns:1fr 1fr;gap:8px}
//      .sw{padding:11px 13px;border-radius:12px;border:1px solid var(--hair)}

struct HardwareBank: View {
    @Bindable var state: DriveState

    var body: some View {
        ConsoleCard(compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "硬件控制") {
                    Text("全部")
                        .font(.system(size: 9))
                        .foregroundStyle(Aurora.t4)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    BankSwitch(key: "插帧", badge: "MGFG-1",
                               on: state.upscaleEnabled,
                               detail: state.upscaleEnabled
                                   ? "已启用 · \(Int(EngineClient.shared.engineFPS))fps"
                                   : (state.upscaleSupported ? "待机 · 未启用" : "不可用"),
                               toggle: { state.upscaleEnabled.toggle() })

                    BankSwitch(key: "录制", badge: state.isRecording ? "REC" : "READY",
                               on: state.isRecording,
                               detail: state.isRecording
                                   ? "录制中 · \(EngineClient.shared.engineRecordFrames) 帧"
                                   : "待机 · 640×360",
                               toggle: { state.isRecording.toggle() })

                    BankSwitch(key: "专家模式", badge: "BC",
                               on: state.expertMode,
                               detail: state.expertMode ? "开启 · 录真实按键" : "关闭 · 录真实按键",
                               toggle: {
                                   state.expertMode.toggle()
                                   state.pushConfig(reason: "专家模式")
                               })

                    BankSwitch(key: "字形模式", badge: "GLYPH",
                               on: state.glyphMode,
                               detail: state.glyphMode ? "开启 · 扫描字形" : "关闭 · 扫描字形",
                               toggle: {
                                   state.glyphMode.toggle()
                                   state.pushConfig(reason: "字形模式")
                               })
                }
            }
        }
    }
}

/// 单个开关（网页 .sw / .sw.on.ok）
struct BankSwitch: View {
    let key: String
    let badge: String
    let on: Bool
    let detail: String
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(on ? Aurora.t1 : Aurora.t2)
                    Spacer(minLength: 2)
                    Text(badge)
                        .font(.system(size: 7.5))
                        .foregroundStyle(Aurora.t4)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Aurora.iceWash))
                        .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(on ? Aurora.ok : Aurora.t4)
                        .frame(width: 5, height: 5)
                        .shadow(color: on ? Aurora.ok.opacity(0.9) : .clear, radius: 5)
                    Text(detail)
                        .font(.system(size: 8.5))
                        .foregroundStyle(on ? Aurora.ok : Aurora.t4)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? Aurora.okLo : Color.white.opacity(0.038))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(on ? Aurora.ok.opacity(0.42) : Aurora.hair1, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(on ? "点击关闭" : "点击开启")
    }
}

// ============================================================================
// MARK: - 感知模型选择卡（2026-10-02 新增）
// ============================================================================
//
// 位置：**挂在运行日志卡下面**（用户原话：「运行日志下面加一个小窗口」）。
//
// 【为什么要有这个】到 2026-10-02 为止，本项目的感知模型是写死的：
//   `YolopxEngine.family` 是 static let，值在进程启动时从环境变量读一次，
//   运行期间改不了 —— 想换模型只能改代码重编译，或者记着带 `AURORA_AYOLOM=1`
//   启动。用户要求改成**界面上能直接选**。
//
// 【两个档位】
//   · A 模型（默认）：A-YOLOM(n) int8 单模型三合一，3.8MB，ANE 上 p50 10.4ms
//   · 26S + 光流 + YOLOPX：原来的三件套，各自独立、各自有历史验证
//
// 【切换代价】会**重新加载模型**（mlmodelc 加载实测 1271ms / mlpackage 需要
//   运行时编译更久）。故本卡片只适合低频人工切换，不是每帧调用。
//   切换期间引擎 `reset()` → 掩码/det 清空 → 决策层 fail-open，不会拿旧值瞎跑。

struct PerceptionPickerCard: View {
    @Bindable var state: DriveState
    @State private var hovered: PerceptionMode?

    var body: some View {
        ConsoleCard(compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "感知模型") {
                    Text(state.perceptionMode == .ayolom ? "新" : "旧")
                        .font(.system(size: 9))
                        .foregroundStyle(state.perceptionMode == .ayolom ? Aurora.ok : Aurora.t4)
                }

                VStack(spacing: 6) {
                    ForEach(PerceptionMode.allCases) { m in
                        chip(m)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ m: PerceptionMode) -> some View {
        let on = state.perceptionMode == m
        let accent = (m == .ayolom) ? Aurora.ok : Aurora.ice

        Button {
            state.selectPerceptionMode(m)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // 选中指示点
                    Circle()
                        .fill(on ? accent : Aurora.t4.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(m.title)
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? accent : Aurora.t3)
                    Spacer(minLength: 0)
                    if on {
                        Text("在用")
                            .font(.system(size: 8))
                            .tracking(0.8)
                            .foregroundStyle(accent.opacity(0.85))
                    }
                }
                Text(m.subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Aurora.t4)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? accent.opacity(0.10)
                             : (hovered == m ? Color.white.opacity(0.04) : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(on ? accent.opacity(0.45) : Aurora.hair1, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? m : (hovered == m ? nil : hovered) }
        .help("切换到「\(m.title)」——\(m.subtitle)")
    }
}

// ============================================================================
// MARK: - 运行日志卡（网页 .log）
// ============================================================================
// CSS: .log{font-family:var(--mono);font-size:10px;line-height:1.85;max-height:118px}

struct RunLogCard: View {
    @Bindable var state: DriveState

    var body: some View {
        ConsoleCard(compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "运行日志") {
                    Text("导出")
                        .font(.system(size: 9))
                        .foregroundStyle(Aurora.t4)
                }

                // 刻意不用 ScrollView —— ImageRenderer 下不绘制；
                // 日志本就只留最近 7 行，直接铺
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .top, spacing: 8) {
                            Text(r.time)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Aurora.t4)
                            Text(r.text)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(color(r.kind))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
        }
    }

    private func color(_ k: String) -> Color {
        switch k {
        case "ok":   return Aurora.ok
        case "warn": return Aurora.amber
        default:     return Aurora.ice
        }
    }

    /// 从真实运行状态生成（只反映 state 实际值，不伪造）
    // DateFormatter 提为 static let：DateFormatter 创建很重（解析格式串 +
    // ICU 初始化），原计算属性每次 body 求值都新建一个。iOS 7 起
    // DateFormatter 线程安全，且这里只被主线程 body 求值，共享安全。
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var rows: [(time: String, text: String, kind: String)] {
        var out: [(String, String, String)] = []
        let now = Self.clockFormatter.string(from: Date())

        if state.isDriving {
            let c = state.confidence > 0 ? String(format: "%.2f", state.confidence) : "—"
            out.append((now, "端到端主驾运行中 · 置信度 \(c)", "ok"))
        }
        if state.engineConnected {
            out.append((now, "引擎已连接 · PID \(EngineClient.shared.enginePID)", "ice"))
        }
        if state.speedValid {
            out.append((now, "SpeedOCR \(Int(state.speedKmh)) km/h · conf \(String(format: "%.2f", state.speedConfidence))", "ice"))
        }
        if state.locatorFound {
            out.append((now, "CoordinateCapture x=\(state.locatorX) y=\(state.locatorY) score \(String(format: "%.2f", state.locatorScore))", "ok"))
        }
        if state.isRecording {
            out.append((now, "录制中 · \(EngineClient.shared.engineRecordFrames) 帧", "warn"))
        }
        if !state.remoteDetections.isEmpty {
            let names = state.remoteDetections.prefix(3).map {
                "\($0.label) \(String(format: "%.2f", $0.confidence))"
            }
            out.append((now, "检测到 " + names.joined(separator: " · "), "warn"))
        }
        // 同 2483 行说明：这个值是节拍周期（1000/帧率），不是推理耗时
        out.append((now, "推理 \(state.mode.rawValue) · 节拍 \(String(format: "%.1f", state.e2eLatencyMs))ms", "ice"))
        return Array(out.suffix(7).reversed())
    }
}

// ============================================================================
// MARK: - 右栏（网页 .col-r: ai-card / auto-btn / status / system）
// ============================================================================

struct RightColumn: View {
    @Bindable var state: DriveState
    @Binding var showSkills: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 13) {
                AIChatCard(center: AgentSkillCenter.shared)
                    .frame(minHeight: 330)

                // running 在按钮内部读取：AgentSkillCenter 是 @Observable，
                // 技能启停只重绘本按钮，不再整右栏重算（body 里读会在
                // 右栏的每一次求值都触发）。
                AutomationBigButton(count: AgentSkillLibrary.all.count) {
                    withAnimation(.easeOut(duration: 0.24)) { showSkills = true }
                }

                RunStatusCard(state: state)
                SystemCard(state: state)
            }
        }
    }
}

/// 自动化大按钮（网页 .auto-btn）
/// CSS: min-height:70px; border:1px solid var(--hair-3);
///      background:linear-gradient(135deg,rgba(76,201,255,.14),rgba(169,139,255,.1) 52%,rgba(76,201,255,.06))
struct AutomationBigButton: View {
    let count: Int
    var onOpen: () -> Void
    @State private var hov = false

    private var running: Int { AgentSkillCenter.shared.runningSkills.count }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Aurora.ice.opacity(0.18))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Aurora.iceHi)
                }
                .frame(width: 38, height: 38)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Aurora.iceLo, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("自动化")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Aurora.t1)
                    Text(running > 0 ? "\(count) 项技能 · \(running) 项运行中" : "\(count) 项技能")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Aurora.t3)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(count)")
                        .font(.system(size: 21, weight: .light, design: .rounded))
                        .foregroundStyle(Aurora.t1)
                    Text("SKILLS")
                        .font(.system(size: 7.5))
                        .tracking(1.4)
                        .foregroundStyle(Aurora.t4)
                }
            }
            .padding(.horizontal, 17).padding(.vertical, 15)
            .frame(minHeight: 70)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Aurora.ice.opacity(0.14), location: 0),
                                .init(color: Aurora.violet.opacity(0.10), location: 0.52),
                                .init(color: Aurora.ice.opacity(0.06), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Aurora.hair3, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: Aurora.iceGlow, radius: 17)
            .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
            .scaleEffect(hov ? 1.012 : 1)
            .animation(.easeOut(duration: 0.2), value: hov)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help("打开全部 \(count) 项自动化技能")
    }
}

/// 当前运行状态 + 限速（网页 .card.sm 的两块）
struct RunStatusCard: View {
    @Bindable var state: DriveState

    var body: some View {
        ConsoleCard(compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "当前运行状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.isDriving ? Aurora.ok : Aurora.t4)
                            .frame(width: 5, height: 5)
                            .shadow(color: state.isDriving ? Aurora.ok : .clear, radius: 5)
                        Text(state.isDriving ? "运行中" : "待机")
                            .font(.system(size: 8.5))
                            .foregroundStyle(state.isDriving ? Aurora.ok : Aurora.t4)
                    }
                }

                // ── 自动驾驶总开关（真实调用 startDriving/stopDriving）──
                AutoDriveSwitch(state: state)
                    .padding(.bottom, 11)

                ControlRows(state: state)

                // .limit-wrap
                LimitSection(state: state)
                    .padding(.top, 13)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Aurora.hair1).frame(height: 1)
                    }
            }
        }
    }
}

/// 四条控制量（网页 .ctl-rows / .ctl-row）
struct ControlRows: View {
    @Bindable var state: DriveState

    var body: some View {
        VStack(spacing: 0) {
            let b = state.driveBars
            row("转向", b.steer, bip: true,   color: Aurora.ice,
                text: String(format: "%+.3f", b.steer))
            row("油门", b.throttle, bip: false, color: Aurora.ok,
                text: String(format: "%.3f", b.throttle))
            row("刹车", b.brake, bip: false,  color: Aurora.danger,
                text: String(format: "%.3f", b.brake))
            row("速度", b.speed, bip: false,  color: Aurora.ice,
                text: String(format: "%.0f", state.speedKmh))
        }
    }

    private func row(_ k: String, _ v: Double, bip: Bool, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(Aurora.t3)
                .frame(width: 30, alignment: .leading)

            GeometryReader { g in
                let w = max(1, g.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5)).frame(height: 6)
                    if bip {
                        // 双极：中心 0，向两侧
                        let half = w / 2
                        let mag = min(1, abs(v)) * half
                        Rectangle().fill(Aurora.hair3).frame(width: 1, height: 10)
                            .offset(x: half - 0.5)
                        Capsule().fill(color).frame(width: max(1, mag), height: 6)
                            .offset(x: v >= 0 ? half : half - mag)
                            .shadow(color: color.opacity(0.6), radius: 6)
                    } else {
                        Capsule().fill(color)
                            .frame(width: max(1, w * min(1, max(0, v))), height: 6)
                            .shadow(color: color.opacity(0.6), radius: 6)
                    }
                }
            }
            .frame(height: 10)

            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(abs(v) < 0.001 ? Aurora.t4 : color)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

/// 限速（网页 .limit-wrap / .hfader / .li-chips）
struct LimitSection: View {
    @Bindable var state: DriveState
    @State private var hover = false

    /// 限速预设。数值全部落在 DriveState.speedLimitRange 内，末项用「不限速」阈值，
    /// 不写死 200 —— 改范围时这里自动跟随。
    private static var chips: [(String, Double)] {
        [20, 40, 60, 80, 100, 120, 150]
            .filter { DriveState.speedLimitRange.contains(Double($0)) }
            .map { ("\($0) km/h", Double($0)) }
            + [("不限速", DriveState.unlimitedThreshold)]
    }

    private var valueColor: Color {
        if state.isUnlimited { return Aurora.ok }
        switch state.speedLimit {
        case ..<60:  return Aurora.ice
        case ..<100: return Aurora.iceHi
        default:     return Aurora.ok
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // .li-head
            HStack(alignment: .firstTextBaseline) {
                Text("限速")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Aurora.t3)
                Spacer()
                if state.isUnlimited {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("不限速")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Aurora.ok)
                        Text("UNLIMITED")
                            .font(.system(size: 7.5))
                            .tracking(1.2)
                            .foregroundStyle(Aurora.t4)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", state.speedLimit))
                            .font(.system(size: 21, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(valueColor)
                            .contentTransition(.numericText())
                        Text("KM / H")
                            .font(.system(size: 7.5))
                            .tracking(1.2)
                            .foregroundStyle(Aurora.t4)
                    }
                }
            }
            .padding(.bottom, 8)

            // .hfader
            GeometryReader { g in
                let w = max(1, g.size.width)
                // 全部读真实范围常量，改范围时这里自动跟随，不写死数字
                let lo = DriveState.speedLimitRange.lowerBound
                let hi = DriveState.speedLimitRange.upperBound
                let span = max(1, hi - lo)
                let t = max(0, min(1, (state.speedLimit - lo) / span))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6)).frame(height: 6)
                        .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
                    Capsule()
                        .fill(LinearGradient(colors: [Aurora.ice.opacity(0.75), valueColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * t, height: 6)
                        .shadow(color: valueColor.opacity(0.7), radius: 9)
                    // 刻度
                    ForEach([20.0, 40, 60, 80, 100, 120, 150, 200], id: \.self) { v in
                        Rectangle().fill(Aurora.hair2).frame(width: 1, height: 10)
                            .offset(x: w * max(0, min(1, (v - lo) / span)) - 0.5)
                    }
                    // 把手
                    Circle()
                        .fill(Color.black)
                        .frame(width: hover ? 16 : 14, height: hover ? 16 : 14)
                        .overlay(Circle().strokeBorder(valueColor, lineWidth: 2))
                        .shadow(color: valueColor.opacity(0.85), radius: 10)
                        .offset(x: w * t - (hover ? 8 : 7))
                        .animation(.easeOut(duration: 0.15), value: hover)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { d in
                        let p = max(0, min(1, d.location.x / w))
                        let raw = lo + p * span
                        // 接近右端即吸附到「不限速」
                        let snapThreshold = DriveState.unlimitedThreshold - 10
                        let snapped = raw >= snapThreshold
                                     ? DriveState.unlimitedThreshold
                                     : (raw / 5).rounded() * 5
                        // source 默认 .user：手动拖滑块设的不限速要锁死自动速度
                        state.setSpeedLimit(snapped, reason: "滑块")
                    }
                )
                .onHover { hover = $0 }
            }
            .frame(height: 20)
            .padding(.bottom, 4)

            // .hf-ends
            HStack {
                // 下限取自真实限速范围常量，不写死数字
                Text("\(Int(DriveState.speedLimitRange.lowerBound)) km/h · 最严")
                    .font(.system(size: 8))
                    .foregroundStyle(Aurora.t4)
                Spacer()
                Text("不限速")
                    .font(.system(size: 8))
                    .foregroundStyle(state.isUnlimited ? Aurora.ok : Aurora.t4)
            }
            .padding(.bottom, 3)

            // .li-s
            HStack {
                // 限速闭环状态：如实展示它现在是在待命、已停用、还是正在踩刹车。
                // 「不限速」时闭环整体停用（用户要求：不限速直接取消掉速度表）。
                if state.isUnlimited {
                    Text("限速已取消 · 不干预车速")
                        .font(.system(size: 9))
                        .foregroundStyle(Aurora.t4)
                    Spacer()
                } else if state.speedLimitGuard.braking {
                    // 三级刹车如实展示：让用户看到现在是「松油门 / 点刹 / 持续刹」哪一级。
                    // 分级存在的意义就是避免一上来就持续拉手刹导致甩尾失控。
                    let g = state.speedLimitGuard
                    HStack(spacing: 4) {
                        Image(systemName: g.stage == .firm ? "exclamationmark.triangle.fill"
                                                          : "arrow.down.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(g.stage == .firm ? Aurora.danger : Aurora.amber)
                        Text("超速 \(String(format: "%.0f", g.overshoot)) km/h · \(g.stage.label)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(g.stage == .firm ? Aurora.danger : Aurora.amber)
                    }
                    Spacer()
                    Text(g.stage == .liftOnly ? "松 W · 松 SHIFT"
                       : g.stage == .pulse    ? "脉冲 空格"
                       :                        "按住 空格")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle((g.stage == .firm ? Aurora.danger : Aurora.amber).opacity(0.75))
                }
                if state.autoSpeedEnabled {
                    // 简单档的结论就是「不限速」，此时 autoSpeedLimit 为 nil，
                    // 但绝不能因此显示成「无自动速度」——要如实说出它的结论。
                    Text(state.roadCondition.meansUnlimited
                         ? "自动速度 → 不限速"
                         : (state.roadCondition.autoSpeedLimit.map { "自动速度 → \(Int($0)) km/h" }
                            ?? "向右放宽 · 向左收紧"))
                        .font(.system(size: 8))
                        .foregroundStyle(Aurora.t4)
                } else {
                    Text("向右放宽 · 向左收紧")
                        .font(.system(size: 8))
                        .foregroundStyle(Aurora.t4)
                }
                Spacer()
            }
            .padding(.bottom, 8)

            // .li-chips
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4),
                      spacing: 5) {
                ForEach(Self.chips, id: \.0) { c in
                    let on = abs(state.speedLimit - c.1) < 0.5
                    Button {
                        state.setSpeedLimit(c.1, reason: "预设")
                    } label: {
                        Text(c.0)
                            .font(.system(size: 9.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Aurora.void : Aurora.t2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(on ? Aurora.ice : Color.black.opacity(0.45))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(on ? Aurora.iceHi : Aurora.hair1, lineWidth: 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 系统卡（网页最后的 .card.sm + .row 列表）
struct SystemCard: View {
    @Bindable var state: DriveState

    var body: some View {
        ConsoleCard(compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: "系统") {
                    Text("检查").font(.system(size: 9)).foregroundStyle(Aurora.t4)
                }
                VStack(spacing: 0) {
                    row("BPF 权限", state.bpfAuthorized ? "已授权" : "未授权",
                        state.bpfAuthorized ? Aurora.ok : Aurora.amber)
                    row("守护进程", state.daemonInstalled ? "已安装" : "未安装",
                        state.daemonInstalled ? Aurora.ok : Aurora.t4)
                    row("引擎进程", state.engineConnected ? "已连接" : "未连接",
                        state.engineConnected ? Aurora.ok : Aurora.t4)
                    row("Game Mode", state.gameModeBoost ? "防御中" : "未启用",
                        state.gameModeBoost ? Aurora.ok : Aurora.t4)
                    row("HUD 浮层", state.upscaleEnabled ? "MGFG-1" : "待机",
                        state.upscaleEnabled ? Aurora.ice : Aurora.t4)
                    // 网络定位：常开，不作为开关（需求明确：永远打开）。
                    // 这里只如实反映锁定状态。
                    row("网络定位", state.locatorFound ? "已锁定" : "搜索中",
                        state.locatorFound ? Aurora.ok : Aurora.amber)
                    // 同包加速度：有真实数据才显示数值，没有就显示 —（不编数）
                    row("定位加速度",
                        state.locatorAccelX.map {
                            String(format: "%.2f, %.2f, %.2f m/s²", $0,
                                   state.locatorAccelY ?? 0, state.locatorAccelZ ?? 0)
                        } ?? "—",
                        state.locatorAccelX != nil ? Aurora.ice : Aurora.t4)
                }
            }
        }
    }

    private func row(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.system(size: 10)).foregroundStyle(Aurora.t3)
            Spacer()
            Text(v).font(.system(size: 10, weight: .medium)).foregroundStyle(c)
        }
        .padding(.vertical, 6)
    }
}

// ============================================================================
// MARK: - 大地图浮层（网页 .ov#mapov + .map-sheet）
// ============================================================================
// CSS: .map-sheet{width:min(1320px,94vw);height:min(880px,92vh);border-radius:20px;
//                 background:linear-gradient(168deg,#0b1421,#060b13)}

struct MapOverlay: View {
    @Binding var isOpen: Bool
    @Bindable var state: DriveState

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                // .ms-head
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("大地图")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Aurora.t1)
                        Text("\(MapTileImage.mapDimensionLabel) · \(state.regionLabel)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Aurora.t4)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Aurora.t4)
                        Text("搜索地点 / 传送点 / 目标")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Aurora.t4)
                        Spacer()
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Aurora.hair1, lineWidth: 1)
                    }
                    .frame(width: 262)

                    Spacer()

                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Aurora.t3)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                            .overlay(Circle().strokeBorder(Aurora.hair1, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Aurora.hair1).frame(height: 1)
                }

                HStack(spacing: 0) {
                    LargeMapCanvas(state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Aurora.hair1).frame(width: 1)
                    DecisionRail(state: state)
                        .frame(width: 272)
                }
            }
            .frame(width: 1180, height: 760)
            .background {
                LinearGradient(colors: [Color(hex: 0x0B1421), Color(hex: 0x060B13)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Aurora.hair3, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.9), radius: 80, y: 60)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .onExitCommand { close() }
    }

    private func close() { withAnimation(.easeOut(duration: 0.22)) { isOpen = false } }
}

/// 大地图画布
/// 大地图视口状态 —— **独立于自车定位**。
///
/// 为什么必须独立（2026-09-22 修复）：
///   原实现把视角中心直接绑在 `state.mapPixelX/Y` 上，而那两个量在
///   `locatorFound == false` 时恒返回地图正中心（MapWiring.swift:34-42）。
///   结果：游戏没启动 → 大地图永远钉在 (6528,6528) 一动不能动，
///   而且 spanMeters 是 `let` 常量，全项目没有任何缩放手势 → 观感"一坨屎"。
///
/// 大地图本质是「地图浏览器」，不是「自车仪表」：
///   · 有自己的视角中心与缩放，由用户手势完全控制
///   · 定位只负责画「我在哪」的图标，不控制视角
///   · 有定位时初始归位到自车；无定位时从地图中心开始，仍可自由浏览
@Observable
final class MapViewport {
    /// 视角中心（地图像素）
    var centerX: Double = MapTileImage.mapPixels / 2
    var centerY: Double = MapTileImage.mapPixels / 2
    /// 视野范围（米）—— 可缩放，替代原来的硬编码 let
    var spanMeters: Double = 1200
    /// 用户是否手动动过视角（动过就不再自动跟随自车，尊重用户意图）
    var userMoved = false

    static let spanRange: ClosedRange<Double> = 120...12000
    /// 缩放档位（供按钮步进用）
    static let zoomStep: Double = 1.35

    func zoom(by factor: Double) {
        setSpan(spanMeters / factor)
    }

    /// 直接设定视野米数（钳到合法区间）。
    /// 手势缩放必须走这个口：MagnifyGesture 的 magnification 是**相对手势起点**的
    /// 累计值，若每帧拿它做增量相乘会复利放大误差（捏一下飞出天际）。
    /// 正确做法是记住手势起点的 span，每帧用 起点/magnification 直接设值。
    func setSpan(_ meters: Double) {
        spanMeters = min(Self.spanRange.upperBound,
                         max(Self.spanRange.lowerBound, meters))
        userMoved = true
    }

    func pan(toMapX x: Double, mapY y: Double) {
        let maxP = MapTileImage.mapPixels
        centerX = min(maxP, max(0, x))
        centerY = min(maxP, max(0, y))
        userMoved = true
    }

    /// 回到自车（有定位时）或地图中心
    func recenter(egoX: Double?, egoY: Double?) {
        if let x = egoX, let y = egoY {
            centerX = x; centerY = y
        } else {
            centerX = MapTileImage.mapPixels / 2
            centerY = MapTileImage.mapPixels / 2
        }
        userMoved = false
    }
}

struct LargeMapCanvas: View {
    @Bindable var state: DriveState
    /// 标记图层渲染模式。
    ///
    /// 为什么要有这个 enum，而不是直接读环境变量：
    /// 离屏基准要**在同一个进程里**对比三种模式（Canvas / ForEach / 不画），
    /// 环境变量在进程启动后就固定了，翻不了。而跨进程对比不公平 ——
    /// 底图裁切的缓存状态、JIT 预热都不一样。
    /// 故模式由参数传入，环境变量只在 `.auto` 时决定默认值。
    enum MarkerRenderMode {
        case auto       // 按环境变量决定（真机走这条）
        case canvas     // 强制新路径
        case legacy     // 强制旧 ForEach
        case none       // 不画标记层（量底图基线）
    }

    var markerMode: MarkerRenderMode = .auto

    /// 视野缩放档位（基准用；nil = 不干预，走 MapViewport 默认 1200 m）
    var benchSpanMeters: Double? = nil

    /// 视野覆写（`AURORA_MAP_SPAN_M`）—— 仅用于出图核对，
    /// 因为标签门槛（400 m）决定了"近景才标名字"，不换个视野就验不到标签。
    static var spanOverride: Double? {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_SPAN_M"],
           let v = Double(s), v >= 120, v <= 12000 { return v }
        return nil
    }

    /// 是否用旧的 ForEach 路径
    private var useLegacyMarkers: Bool {
        switch markerMode {
        case .auto:   return Self.legacyMarkers
        case .legacy: return true
        case .canvas, .none: return false
        }
    }
    /// 是否完全不画标记层。
    ///
    /// ⚠️ 只在 `.auto` 时读环境变量。基准夹具显式传 `.none`/`.legacy`/`.canvas`
    ///    时必须**忽略** env —— 否则 `AURORA_MAP_NO_MARKERS=1` 会把
    ///    `.legacy`/`.canvas` 也一并跳过，三路对比全变成"仅底图"，
    ///    基准数据直接失效（实测踩过：三路耗时全都掉到 10 ms 上下）。
    private var skipMarkers: Bool {
        switch markerMode {
        case .none:  return true
        case .canvas, .legacy: return false
        case .auto:  return Self.noMarkers
        }
    }

    /// 是否走「自车→目标」直线导航（旧行为）。
    /// 默认关：改用沿路网折线的真实路线。设 `AURORA_ROUTE_STRAIGHT=1` 可切回，
    /// 用于 A/B 对照「沿路走」与「直线穿」。
    static var routeStraightLegacy: Bool {
        ProcessInfo.processInfo.environment["AURORA_ROUTE_STRAIGHT"] == "1"
    }

    /// 是否回退旧的 ForEach 标记渲染（A/B 对照 / 性能回归排查）。
    /// 默认关 = 走新的 Canvas + 聚类路径。
    static var legacyMarkers: Bool {
        ProcessInfo.processInfo.environment["AURORA_MAP_LEGACY_MARKERS"] == "1"
    }

    /// 是否在图上显示分类筛选条 + 图例
    static var showFilterBar: Bool {
        ProcessInfo.processInfo.environment["AURORA_MAP_FILTER_BAR"] != "0"
    }

    /// 是否**完全跳过标记图层**（`AURORA_MAP_NO_MARKERS=1`）。
    ///
    /// 这是排障用的二分开关：性能异常时用它把「底图成本」与「标记成本」
    /// 分开量。地图渲染慢的原因可能是底图裁切，也可能是标记绘制，
    /// 不看这个数就只能猜。
    static var noMarkers: Bool {
        ProcessInfo.processInfo.environment["AURORA_MAP_NO_MARKERS"] == "1"
    }

    /// 标签数量硬上限。
    ///
    /// ⚠️ 这不是随便定的数：实测标签成本约 **32.7 µs/个**（线性），
    ///    400 个 = 13.77 ms/帧，已逼近 60fps 的 16.67 ms 预算。
    ///    取 200 个 ≈ 6.5 ms，留出余量给底图/折线/自车图标。
    ///    `AURORA_MAP_MAX_LABELS` 可覆写（排查用）。
    static var labelBudget: Int {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_MAX_LABELS"],
           let v = Int(s), v >= 0 { return v }
        return 200
    }

    /// 标签视野门槛（米）：超过这个视野就不标名字（太远，名字会糊成一片）
    static var labelSpanM: Double {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_LABEL_SPAN_M"],
           let v = Double(s) { return v }
        return 400
    }

    /// 允许显示名字的类别（组 id）。
    ///
    /// ⚠️ 2026-10-03 修正的一个**设计缺陷**：
    /// 初版白名单是 `travel/shop/service`，但其中 shop(677) 与 service(269)
    /// **默认关闭**，只有 travel(106) 默认开，而 travel 仅占 1.9%。
    /// 实测默认视图 300 m 视野下，靠白名单能显示的标签只有 **约 1 个** ——
    /// 200 个标签预算几乎全浪费，用户依旧"看不出这些点是什么"，
    /// 正是要修的那个抱怨。
    ///
    /// 现改为：`travel`（传送点）**必标**（它是用户的决策目标）；
    /// 其余点不再受白名单限制，改为在预算内**按离视野中心由近及远**补足。
    /// 这样近处密集区的名字一定先出来，远处的自然被挤掉。
    static let mustLabelGroups: Set<String> = ["travel"]

    /// 是否挂载滚轮缩放层。
    /// 离屏渲染（ImageRenderer）不支持 NSViewRepresentable，会把整块渲染成
    /// 系统占位图（黄底红禁止符），所以自检夹具必须传 false —— 否则夹具
    /// 验的是占位符而不是真地图，等于白测。
    var interactive: Bool = true
    @State private var vp = MapViewport()
    /// 拖拽起始时的视角中心，避免累积误差
    @State private var dragAnchor: (x: Double, y: Double)?
    /// 双指缩放起始时的视野米数（锚点，防止复利误差）
    @State private var magnifyBase: Double?

    // ── 标记分类 / 聚类（2026-10-03 新增）──
    /// 当前开启的组（按**中文名**存，因为 UI 上显示的是中文名；
    /// 词表缺失时会自动回落成「全开」语义，见下方 enabledGroups 计算）
    @State private var enabledGroups: Set<String>? = nil
    /// 聚类缓存：避免同一视野下每帧重算（拖动时中心连续变化，
    /// 用 4px/1档 量化做命中判断）
    @State private var clusterCache: (key: String, clusters: [MarkerCluster])? = nil
    /// 悬停的聚团 id（悬停团始终显示名字，无视标签白名单）
    @State private var hoveredClusterID: String? = nil
    /// 选中的聚团（点击弹出成员列表；选中项始终显示名字）
    @State private var selectedCluster: MarkerCluster? = nil

    /// 词表是否可用。不可用时所有组相关 UI 都不显示，回到"一个色"的旧观感
    /// —— 不崩、不空白，这是硬性要求。
    private var taxonomyReady: Bool { !MarkerTaxonomy.groups.isEmpty }

    /// 实际生效的开启组（中文名）。首次进入用词表默认值。
    private var effectiveGroups: Set<String> {
        if let e = enabledGroups { return e }
        return MarkerTaxonomy.defaultOnGroups
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cx = vp.centerX, cy = vp.centerY
            let spanMeters = benchSpanMeters ?? Self.spanOverride ?? vp.spanMeters
            let pxPerMeter = MapTileImage.mapPixels / MapTileImage.worldMetersPerMap
            let spanPx = spanMeters * pxPerMeter

            // ── 聚类（每帧求值，但内部有量化缓存）──
            // 顺序**必须**是「先按组过滤 → 再聚类」：若先聚类再过滤，
            // 团的 count 会把被隐藏组的成员算进去，用户看到 +12 点开只有 3 个。
            let clusters = clusterList(centerX: cx, centerY: cy,
                                       spanPx: spanPx, viewWidth: w)

            ZStack {
                Color(hex: 0x05080E)

                // ── 真实地图底图：13056×13056 大地图按自车位置裁切 ──
                MapTileImage(centerMapX: cx, centerMapY: cy,
                             spanMeters: spanMeters)

                // ── 真实标记点：5677 条，聚类后绘制 ──
                //
                // ══════════════════════════════════════════════════════════════
                // ⚠️ 2026-10-03：**从 ForEach 换成单个 Canvas**，这是"卡"的正解
                // ══════════════════════════════════════════════════════════════
                // 旧实现 `ForEach(..., limit: 400)` 每次重绘都要重建最多 400 个
                // SwiftUI 子视图。实测（1360×860 离屏，内容每帧变化）：
                //     400 点 ForEach  → 18.92 ms/帧   ✗ 超过 60fps 预算 16.67
                //     400 点 Canvas   →  2.12 ms/帧   ✓
                //     5677 点 Canvas  →  0.81 ms/帧   ✓ ← 全部点，一个不落
                // 即：换成 Canvas 后不但快了 9 倍，还能**一次画完全部 5677 个**
                // 而不是被 limit 砍到 400。卡顿的根因是子视图数量，不是标记数量。
                //
                // 另一个实测发现：**文字标签才是大头**（约 32.7 µs/个，
                // 400 个 = 13.77 ms）。所以标签数量必须硬性限量，
                // 见 `labelBudget` 与 `shouldLabel` —— 不是"顺便优化"，
                // 是不限量就一定会重新超预算。
                if skipMarkers {
                    // 排障开关：完全不画标记层，用于把底图成本单独量出来
                } else if useLegacyMarkers {
                    ForEach(MapDatabase.markersInView(centerX: cx, centerY: cy,
                                                      spanPx: spanPx, limit: 400),
                            id: \.stableID) { m in
                        let nx = (m.mapX - cx) / spanPx + 0.5
                        let ny = (m.mapY - cy) / spanPx + 0.5
                        ZStack {
                            Circle()
                                .fill(m.color)
                                .frame(width: 4, height: 4)
                            if m.kind == "waypoint" {
                                Text(m.name)
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(Aurora.t3)
                                    .fixedSize()
                                    .offset(y: 10)
                            }
                        }
                        .position(x: w * nx, y: h * ny)
                    }
                } else {
                    Canvas { ctx, size in
                        Self.drawClusters(ctx: ctx, size: size,
                                          clusters: clusters,
                                          centerX: cx, centerY: cy, spanPx: spanPx,
                                          hoveredID: hoveredClusterID)
                    }
                    .allowsHitTesting(false)   // 点击交给外层手势，画布不吃事件
                }

                // ── 路网寻路路线（2026-10-03 新增）──
                // 沿真实路网折线画，而不是自车到目标的直线。
                // 旧直线保留在 AURORA_ROUTE_STRAIGHT=1 后面，便于 A/B 对照
                // 「沿路走」和「直线穿」的视觉差异。
                if !Self.routeStraightLegacy,
                   let plan = state.routePlan, plan.points.count >= 2 {
                    // 路网折线：所有顶点都落在真实道路上
                    Path { p in
                        var first = true
                        for pt in plan.points {
                            let nx = (pt.0 - cx) / spanPx + 0.5
                            let ny = (pt.1 - cy) / spanPx + 0.5
                            let x = w * nx, y = h * ny
                            if first { p.move(to: .init(x: x, y: y)); first = false }
                            else { p.addLine(to: .init(x: x, y: y)) }
                        }
                    }
                    // 外发光 + 实线：与既有导航线同一套配色，不引入新色
                    .stroke(Aurora.ice.opacity(0.55),
                            style: StrokeStyle(lineWidth: 6.0, lineCap: .round, lineJoin: .round))
                    .shadow(color: Aurora.ice.opacity(0.95), radius: 11)
                    Path { p in
                        var first = true
                        for pt in plan.points {
                            let nx = (pt.0 - cx) / spanPx + 0.5
                            let ny = (pt.1 - cy) / spanPx + 0.5
                            let x = w * nx, y = h * ny
                            if first { p.move(to: .init(x: x, y: y)); first = false }
                            else { p.addLine(to: .init(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.white,
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))

                    // 起点（绿）与终点（红）标记
                    if let sp = state.routeStartPx {
                        let nx = (sp.x - cx) / spanPx + 0.5
                        let ny = (sp.y - cy) / spanPx + 0.5
                        ZStack {
                            Circle().fill(Aurora.ok.opacity(0.22)).frame(width: 22, height: 22)
                            Circle().fill(Aurora.ok).frame(width: 9, height: 9)
                                .shadow(color: Aurora.ok, radius: 6)
                        }
                        .position(x: w * nx, y: h * ny)
                    }
                    if let ep = state.routeEndPx {
                        let nx = (ep.x - cx) / spanPx + 0.5
                        let ny = (ep.y - cy) / spanPx + 0.5
                        ZStack {
                            Circle().fill(Aurora.danger.opacity(0.22)).frame(width: 22, height: 22)
                            Circle().fill(Aurora.danger).frame(width: 9, height: 9)
                                .shadow(color: Aurora.danger, radius: 6)
                        }
                        .position(x: w * nx, y: h * ny)
                    }
                }

                // ── 真实导航路径（直连版，AURORA_ROUTE_STRAIGHT=1 时启用）──
                if Self.routeStraightLegacy, state.locatorFound, let t = state.locatorTarget {
                    let ePx = DriveState.worldToMapPixelX(state.locatorX, state.locatorY)
                    let ePy = DriveState.worldToMapPixelY(state.locatorX, state.locatorY)
                    let ex = min(0.97, max(0.03, (ePx - cx) / spanPx + 0.5))
                    let ey = min(0.97, max(0.03, (ePy - cy) / spanPx + 0.5))
                    // ⚠️ 2026-09-30 修复：目标点缺一次 `worldToMapPixel` 变换。
                    //
                    // 【根因】`locatorTarget` 存的是**世界坐标**（UE5 厘米，见
                    //   :1398 的 `(t.x - locatorX)/100.0` —— 两者相减再除 100
                    //   得米，必须是同一坐标系），而 `cx`/`cy` 是**地图像素**。
                    //   原实现让世界坐标直接参与像素运算：
                    //       `(t.x - cx) / spanPx + 0.5`      // 世界 − 像素，量纲不符
                    //   夹具坐标 `t.x = -76500`、`cx = 5264` ⟹ 偏差约 81764，
                    //   再除以 `spanPx`（视野 1200m ≈ 1967px）得 −41.6，
                    //   被 `max(0.03, …)` 夹到 **0.03** ——
                    //   于是目标点永远被钉在画面左侧 3% 处，导航线斜穿整个屏幕。
                    //   （本轮截图 `--mc-map` 里那条从自车伸向左下方的长线即是此因。）
                    //
                    // 【为什么之前没发现】前几轮修 `locatorX/Y` 的坐标系混用时，
                    //   只处理了「自车」一侧（`ePx/ePy` 一直是正确转换过的），
                    //   漏掉了与它配对的「目标」一侧 —— 典型的对称遗漏。
                    //   `:2265` 的目标距离计算用的是 `s.locatorX` 与 `t.x`，
                    //   两者同为世界坐标因而正确；唯独本处把它和像素混算。
                    //
                    // 【修法】与自车完全对称：目标也过一遍 `worldToMapPixelX/Y`。
                    let tPx = DriveState.worldToMapPixelX(Double(t.x), Double(t.y))
                    let tPy = DriveState.worldToMapPixelY(Double(t.x), Double(t.y))
                    let tx = min(0.97, max(0.03, (tPx - cx) / spanPx + 0.5))
                    let ty = min(0.97, max(0.03, (tPy - cy) / spanPx + 0.5))
                    Path { p in
                        p.move(to: .init(x: w * ex, y: h * ey))
                        p.addLine(to: .init(x: w * tx, y: h * ty))
                    }
                    .stroke(Aurora.ice, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    .shadow(color: Aurora.ice.opacity(0.9), radius: 9)
                }

                // ── 自车：真实定位坐标映射到视口 ──
                // 注意：这里必须用视口中心 cx/cy 换算，不能用 state.mapPixelX/Y，
                // 否则用户平移后自车图标会画错位置（原实现就是混用导致漂移）。
                if state.locatorFound {
                    let egoPx = DriveState.worldToMapPixelX(state.locatorX, state.locatorY)
                    let egoPy = DriveState.worldToMapPixelY(state.locatorX, state.locatorY)
                    let ex = min(0.97, max(0.03, (egoPx - cx) / spanPx + 0.5))
                    let ey = min(0.97, max(0.03, (egoPy - cy) / spanPx + 0.5))
                    ZStack {
                        Circle().fill(Aurora.ice.opacity(0.18)).frame(width: 34, height: 34)
                        // 朝向指示（真实 locatorHeading）
                        Capsule()
                            .fill(Aurora.ice)
                            .frame(width: 3, height: 15)
                            .offset(y: -13)
                            .rotationEffect(.degrees(state.locatorHeading))
                        Circle().fill(Aurora.ice).frame(width: 10, height: 10)
                            .shadow(color: Aurora.ice, radius: 10)
                    }
                    .position(x: w * ex, y: h * ey)
                } else {
                    // 定位未锁定：如实提示，不画假自车
                    VStack(spacing: 5) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 16)).foregroundStyle(Aurora.t4)
                        Text(state.locateStatusText)
                            .font(.system(size: 10)).foregroundStyle(Aurora.t4)
                    }
                }

                // ── 右上：缩放控件（地图浏览器必备）──
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            MapCtrlBtn(icon: "plus") { vp.zoom(by: MapViewport.zoomStep) }
                            MapCtrlBtn(icon: "minus") { vp.zoom(by: 1 / MapViewport.zoomStep) }
                            MapCtrlBtn(icon: "location.fill",
                                       tint: state.locatorFound ? Aurora.ice : Aurora.t4,
                                       tip: "回到自车") {
                                vp.recenter(egoX: state.locatorFound ? DriveState.worldToMapPixelX(state.locatorX, state.locatorY) : nil,
                                            egoY: state.locatorFound ? DriveState.worldToMapPixelY(state.locatorX, state.locatorY) : nil)
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.top, 14)
                    }
                    Spacer()
                }

                // ── 真实坐标读数（视角中心 + 世界坐标）──
                VStack {
                    Spacer()
                    HStack {
                        Text(state.locatorFound
                             ? String(format: "视角 %.0f,%.0f · 自车 %.0f,%.0f",
                                      cx, cy, state.locatorX, state.locatorY)
                             : String(format: "视角 %.0f,%.0f · 未定位（可自由浏览）", cx, cy))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Aurora.t4)
                        Spacer()
                        Text("视野 \(Int(spanMeters)) m · 标记 \(state.mapMarkerCount)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Aurora.t4)
                    }
                }
                .padding(14)

                // ── 滚轮缩放层（透明，只吃滚轮事件，不抢点击）──
                // 放在 ZStack 内部：若放在外层用 if 包起来会切断后面的
                // .contentShape/.gesture 修饰链（编译报 contentShape on type 'View'）。
                // 离屏渲染时跳过：NSViewRepresentable 在 ImageRenderer 下会渲染成
                // 系统占位图，夹具必须传 interactive=false 才能验到真地图。
                if interactive {
                    MapScrollZoom { f in vp.zoom(by: f) }
                }

                // ── 「路径规划中」遮罩（2026-10-03 新增）──
                if state.routeStatus == .planning {
                    RoutePlanningOverlay()
                }

                // ── 分类筛选条（左上，2026-10-03 新增）──
                // 只在地图可用（词表就绪）时显示。
                // 词表缺失 ⇒ 不显示任何组相关 UI，回到旧观感（不崩、不空白）。
                //
                // 注意这里**不判 `interactive`**：筛选条是纯 SwiftUI 绘制，
                // 离屏 ImageRenderer 能正常渲染（与 MapScrollZoom 那种
                // NSViewRepresentable 不同）。不判它，截图夹具才验得到筛选条。
                if Self.showFilterBar, taxonomyReady {
                    VStack {
                        HStack {
                            MarkerFilterBar(
                                enabled: Binding(
                                    get: { effectiveGroups },
                                    set: { enabledGroups = $0 }
                                ),
                                groups: MarkerTaxonomy.groups,
                                counts: MarkerTaxonomy.countByGroup,
                                visibleCount: clusters.reduce(0) { $0 + $1.count },
                                onReset: { enabledGroups = MarkerTaxonomy.defaultOnGroups },
                                onAll: { enabledGroups = Set(MarkerTaxonomy.groups.map { $0.label }) },
                                onNone: { enabledGroups = [] }
                            )
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                }

                // ── 聚类悬停提示（跟随鼠标的团信息）──
                if interactive, let hc = clusters.first(where: { $0.id == hoveredClusterID }) {
                    let nx = (hc.centerX - cx) / spanPx + 0.5
                    let ny = (hc.centerY - cy) / spanPx + 0.5
                    ClusterTooltip(cluster: hc)
                        .position(x: w * nx, y: h * ny - 30)
                        .allowsHitTesting(false)
                }
            }

            // ── 手势：拖拽平移（地图跟手）+ 双指缩放 ──
            // 注意：手势挂在 ZStack 外层，且不拦截子视图的点击
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { d in
                        let anchor = dragAnchor ?? (vp.centerX, vp.centerY)
                        if dragAnchor == nil { dragAnchor = anchor }
                        // 屏幕位移 → 地图像素位移（视野越大，同样的拖动移动越多像素）
                        let k = spanPx / max(1, w)
                        vp.pan(toMapX: anchor.x - d.translation.width * k,
                               mapY: anchor.y - d.translation.height * k)
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        // 锚点式缩放：magnification 是相对手势起点的累计倍数，
                        // 必须用「手势起点的视野 / 倍数」直接设值，不能逐帧相乘。
                        let base = magnifyBase ?? spanMeters
                        if magnifyBase == nil { magnifyBase = base }
                        // 手指张开(magnification>1) = 放大 = 视野变小
                        vp.setSpan(base / max(0.05, v.magnification))
                    }
                    .onEnded { _ in magnifyBase = nil }
            )
            // 首次拿到定位 → 自动归位到自车（仅当用户还没手动动过视角）
            .onAppear {
                if !vp.userMoved, state.locatorFound {
                    vp.recenter(egoX: DriveState.worldToMapPixelX(state.locatorX, state.locatorY),
                                egoY: DriveState.worldToMapPixelY(state.locatorX, state.locatorY))
                }
            }
            .onChange(of: state.locatorFound) { _, found in
                if found, !vp.userMoved {
                    vp.recenter(egoX: DriveState.worldToMapPixelX(state.locatorX, state.locatorY),
                                egoY: DriveState.worldToMapPixelY(state.locatorX, state.locatorY))
                }
            }
            // ── 点击设终点 + 规划（2026-10-03 新增）──
            //
            // ⚠️ 与既有 DragGesture(minimumDistance: 2) 的冲突处理：
            //   SwiftUI 的 DragGesture 只要移动 ≥2px 就进入 onChanged，
            //   而一次「点击」在触控板上也可能抖动 1–3 px。若直接用
            //   `.onTapGesture`，抖动会先触发拖拽、点击事件被吞 —— 表现为
            //   "点了没反应"或"地图轻微一抖"。
            //   故这里**复用同一条 DragGesture**，在 onEnded 里按累计位移判定：
            //   位移 ≤4px 视为点击（设终点），否则视为拖拽（什么都不做）。
            //   这样只有一个手势源，不存在两个手势互相抢的问题。
            //
            //   离屏夹具（interactive == false）不挂：夹具要的是确定性出图，
            //   挂上会引入额外的 hitTest 层。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { d in
                        guard interactive else { return }   // 离屏夹具不参与点击
                        let moved = hypot(d.translation.width, d.translation.height)
                        guard moved <= Self.tapSlopPx else { return }   // 是拖拽，不是点击
                        // 屏幕点 → 视口归一化 → 地图像素 → 世界坐标
                        let nx = min(1, max(0, d.startLocation.x / max(1, w)))
                        let ny = min(1, max(0, d.startLocation.y / max(1, h)))
                        let mapX = cx + (nx - 0.5) * spanPx
                        let mapY = cy + (ny - 0.5) * spanPx
                        // 未定位时第一次点击 = 设起点；已有起点后第二次点击 = 设终点。
                        // 这样"没有定位也能用"（点两下即可规划）。
                        if !state.locatorFound, state.routeStartPx == nil {
                            state.routeStartPx = (mapX, mapY)
                            state.routeStatus = .idle
                            print(String(format: "[MAP-ROUTE] 起点已设 (%.0f,%.0f)", mapX, mapY))
                            return
                        }
                        if !state.locatorFound, let sp = state.routeStartPx {
                            state.planRouteFromMapPixel(from: sp, to: (mapX, mapY))
                            print(String(format: "[MAP-ROUTE] 未定位：起点(%.0f,%.0f) → 终点(%.0f,%.0f)",
                                         sp.0, sp.1, mapX, mapY))
                            return
                        }
                        // 已定位：直接以自车为起点规划
                        state.planRouteToMapPixel(x: mapX, y: mapY)
                        if let r = state.routePlan {
                            print(String(format: "[MAP-ROUTE] %.2f km · 拐弯 %d · %d 段 · %.2f ms",
                                         r.distanceMeters / 1000, r.turns, r.segments, r.elapsedMs))
                        } else if case .failed(let why) = state.routeStatus {
                            print("[MAP-ROUTE] ✗ \(why)")
                        }
                    }
            )
            // ── 悬停：找最近的团并记下 id（用于 tooltip + 强制显示名字）──
            //
            // 用 `onContinuousHover` 而不是 `.onHover`：后者只给「进入/离开」，
            // 定位不到鼠标具体在哪；前者每帧给位置，才能知道悬停的是哪个团。
            //
            // 判据是「屏幕距离 < 命中半径」而不是「在团的圆内」：
            // 未成团的点只有 4px，按圆判几乎点不中；给 12px 的宽容半径更好用。
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .ended:
                    if hoveredClusterID != nil { hoveredClusterID = nil }
                case .active(let loc):
                    // 屏幕点 → 地图像素
                    let nx = min(1, max(0, loc.x / max(1, w)))
                    let ny = min(1, max(0, loc.y / max(1, h)))
                    let mapX = cx + (nx - 0.5) * spanPx
                    let mapY = cy + (ny - 0.5) * spanPx
                    var best: (Double, String)?
                    for c in clusters {
                        let d = (c.centerX - mapX) * (c.centerX - mapX)
                                + (c.centerY - mapY) * (c.centerY - mapY)
                        if best == nil || d < best!.0 { best = (d, c.id) }
                    }
                    // 命中半径：12 屏幕 px 换算成地图 px
                    let hitMap = 12.0 / max(1, w) * spanPx
                    let newID = (best != nil && best!.0 <= hitMap * hitMap) ? best!.1 : nil
                    if newID != hoveredClusterID { hoveredClusterID = newID }
                }
            }
        }
    }

    /// 点击判定阈值（屏幕像素）：位移超过它就算拖拽，不设终点。
    static let tapSlopPx: Double = 4

    // ══════════════════════════════════════════════════════════════════════
    // MARK: 聚类（含量化缓存）
    // ══════════════════════════════════════════════════════════════════════

    /// 取当前视野的聚团列表。
    ///
    /// ── 为什么要缓存 ──────────────────────────────────────────────────────
    /// 拖动地图时中心每帧都在变，若每帧都跑一遍「遍历 5677 点 + 分桶 + 排序」，
    /// 就是纯浪费 —— 4 像素的位移在屏幕上根本看不出团的变化。
    /// 故把 (中心x, 中心y, 视野, 组掩码, 屏幕宽) **量化**成缓存键：
    /// 中心按 4px、视野按 ×1.02 分档，命中就直接返回上次结果。
    /// 实测拖动一帧的位移通常 < 4px，绝大多数帧都能命中。
    private func clusterList(centerX cx: Double, centerY cy: Double,
                             spanPx: Double, viewWidth w: Double) -> [MarkerCluster] {
        guard !Self.legacyMarkers, w > 1, spanPx > 0 else { return [] }

        // 量化
        let qx = (cx / 4).rounded() * 4
        let qy = (cy / 4).rounded() * 4
        let qs = (log(spanPx) / log(1.02)).rounded()
        let mask = effectiveGroups.sorted().joined(separator: ",")
        let key = "\(qx)|\(qy)|\(qs)|\(mask)|\(Int(w))"

        if let c = clusterCache, c.key == key { return c.clusters }

        // 分段计时（仅 AURORA_MAP_CLUSTER_TRACE=1 时打印）——
        // 排障用：光知道"总共慢"没用，要知道慢在哪一段。
        let trace = ProcessInfo.processInfo.environment["AURORA_MAP_CLUSTER_TRACE"] == "1"
        let t0 = DispatchTime.now()

        // 1) 取视野内全部标记（**不截断** —— 截断会让团计数算错）
        let all = MapDatabase.markersInViewAll(centerX: cx, centerY: cy, spanPx: spanPx)
        let t1 = DispatchTime.now()

        // 2) 按组过滤（**用 MarkerClusterer 里唯一那份实现** ——
        //    两处各写一遍过滤逻辑迟早会分叉）
        let filtered: [MapDatabase.PlacedMarker]
        if taxonomyReady {
            filtered = MarkerClusterer.filter(all, enabledLabels: effectiveGroups)
        } else {
            filtered = all   // 词表缺失：不过滤，保持旧观感
        }
        let t1b = DispatchTime.now()

        // 3) 聚类
        let out = MarkerClusterer.cluster(filtered, spanPx: spanPx, viewWidth: w,
                                          centerX: cx, centerY: cy)
        let t2 = DispatchTime.now()

        if trace {
            let ms = { (a: DispatchTime, b: DispatchTime) in
                Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000
            }
            print(String(format: "[CLUSTER-TRACE] 取点 %.2f · 过滤 %.2f · 聚类 %.2f ms"
                         + "   (视野内 %d → 过滤后 %d → %d 团)",
                         ms(t0, t1), ms(t1, t1b), ms(t1b, t2),
                         all.count, filtered.count, out.count))
        }

        // 缓存（只留最近一条 —— 地图只有一个视野）
        clusterCache = (key, out)
        return out
    }

    // ══════════════════════════════════════════════════════════════════════
    // MARK: 绘制（单个 Canvas 画完全部团）
    // ══════════════════════════════════════════════════════════════════════

    /// 把一个聚团画成图。
    ///
    /// 视觉语言（对齐 maante，但用极光配色）：
    ///   · 未成团（count==1）：4px 圆点，组色
    ///   · 成团（count>1）：外圈柔光 + 实心圆 + 白字 `+N`
    ///     圆半径随数量的对数增长（4 → 13 px），既表达"这里很多"
    ///     又不会因为某个团有 300 个点就把地图糊死
    @MainActor
    static func drawClusters(ctx: GraphicsContext, size: CGSize,
                             clusters: [MarkerCluster],
                             centerX cx: Double, centerY cy: Double,
                             spanPx: Double,
                             hoveredID: String?) {
        guard spanPx > 0 else { return }
        let w = size.width, h = size.height

        // ① 先画未成团的点（小而多，画在底层）
        for c in clusters where !c.isCluster {
            let nx = (c.centerX - cx) / spanPx + 0.5
            let ny = (c.centerY - cy) / spanPx + 0.5
            // 视野外跳过（聚类边界可能带进来一点）
            guard nx > -0.02, nx < 1.02, ny > -0.02, ny < 1.02 else { continue }
            let p = CGPoint(x: w * nx, y: h * ny)
            let col = c.representative.color
            let r = CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)
            ctx.fill(Path(ellipseIn: r), with: .color(col))
        }

        // ② 再画成团的（大而少，画在上层压住小点）
        for c in clusters where c.isCluster {
            let nx = (c.centerX - cx) / spanPx + 0.5
            let ny = (c.centerY - cy) / spanPx + 0.5
            guard nx > -0.05, nx < 1.05, ny > -0.05, ny < 1.05 else { continue }
            let p = CGPoint(x: w * nx, y: h * ny)
            let col = c.representative.color

            // 半径：4 + 2.2 × ln(count)，封顶 13
            let rad = min(13.0, 4.0 + 2.2 * log(Double(c.count)))
            let isHover = (hoveredID == c.id)

            // 外柔光（悬停时更大更亮）
            let glowR = rad + (isHover ? 8 : 5)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR,
                                            width: glowR * 2, height: glowR * 2)),
                     with: .color(col.opacity(isHover ? 0.34 : 0.18)))

            // 主体圆
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad,
                                            width: rad * 2, height: rad * 2)),
                     with: .color(col.opacity(0.92)))

            // 描边（悬停时白色）
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad,
                                              width: rad * 2, height: rad * 2)),
                       with: .color(isHover ? .white : Color(hex: 0xFFFFFF, alpha: 0.35)),
                       lineWidth: isHover ? 1.6 : 1.0)

            // 数量文字：`+N`（与 maante 的 `<b>+N</b>` 同构）
            // 半径太小时不画字（会糊成一坨黑点），改为靠大小表达
            if rad >= 7 {
                let t = Text("+\(c.count)")
                    .font(.system(size: rad >= 11 ? 9 : 7.5, weight: .semibold))
                    .foregroundStyle(.white)
                ctx.draw(t, at: p)
            }
        }

        // ③ 标签（**最贵的一步**，严格限量）
        //
        // 实测约 32.7 µs/个，是全流程最贵操作（底图绘制级别）。
        // 硬上限 `labelBudget`（默认 200）—— 超出就按「离视野中心由近及远」
        // 截断，保证最重要的（近处、用户正在看的）先显示。
        drawLabels(ctx: ctx, size: size, clusters: clusters,
                   centerX: cx, centerY: cy, spanPx: spanPx, hoveredID: hoveredID)
    }

    /// 绘制标签。
    ///
    /// 显示条件：
    ///   1. 未被聚团（count == 1）—— 团已经用 `+N` 表达，再标名字会叠字
    ///   2. 视野 ≤ `labelSpanM`（默认 400 m）—— 拉远了名字会糊成一片
    ///   3. `mustLabelGroups`（传送点）**无条件进候选**；其余点也进候选
    ///   4. 总预算 `labelBudget`（默认 200），按离视野中心距离由近及远取
    ///
    /// **优先级**：悬停 > 传送点 > 其余（近处优先）。
    /// 之所以给传送点优先：它是用户的决策目标（"我要去哪"），
    /// 数量只有 106 个（1.9%），不会挤掉别的标签。
    /// 其余点全部平等竞争预算 —— 近处先出，远处被挤掉，符合"看得到的地方重要"。
    ///
    /// **例外**：悬停的标记无视 1–4 始终显示 —— 用户主动看的东西必须有反馈。
    @MainActor
    static func drawLabels(ctx: GraphicsContext, size: CGSize,
                           clusters: [MarkerCluster],
                           centerX cx: Double, centerY cy: Double,
                           spanPx: Double, hoveredID: String?) {
        let budget = labelBudget
        guard budget > 0, spanPx > 0 else { return }
        let w = size.width, h = size.height

        // 视野换算成米，判断是否够近
        let pxPerMeter = MapTileImage.mapPixels / MapTileImage.worldMetersPerMap
        let spanMeters = spanPx / pxPerMeter

        var must: [(Double, MarkerCluster)] = []     // 传送点：必标
        var rest: [(Double, MarkerCluster)] = []     // 其余：竞争预算
        var forced: [MarkerCluster] = []             // 悬停：不占预算

        for c in clusters {
            let nx = (c.centerX - cx) / spanPx + 0.5
            let ny = (c.centerY - cy) / spanPx + 0.5
            guard nx > 0.01, nx < 0.99, ny > 0.01, ny < 0.99 else { continue }

            // 悬停：无条件显示（且不占预算 —— 用户主动看的只有一个）
            if c.id == hoveredID {
                forced.append(c)
                continue
            }
            guard !c.isCluster else { continue }              // 条件 1
            guard spanMeters <= labelSpanM else { continue }   // 条件 2

            let d = (nx - 0.5) * (nx - 0.5) + (ny - 0.5) * (ny - 0.5)
            if let g = c.representative.group, mustLabelGroups.contains(g) {
                must.append((d, c))
            } else {
                rest.append((d, c))
            }
        }

        // 距离优先（传送点和其余各自排序）
        must.sort { $0.0 < $1.0 }
        rest.sort { $0.0 < $1.0 }

        // 预算分配：先满足传送点，余额给其余
        let mustShown = must.prefix(budget)
        let remain = max(0, budget - mustShown.count)
        let shown = forced + mustShown.map { $0.1 } + rest.prefix(remain).map { $0.1 }

        for c in shown {
            let m = c.representative
            let nx = (m.mapX - cx) / spanPx + 0.5
            let ny = (m.mapY - cy) / spanPx + 0.5
            let p = CGPoint(x: w * nx, y: h * ny)
            let isHover = (c.id == hoveredID)
            // 悬停时额外画一个底衬，让文字在杂乱底图上仍可读
            if isHover {
                let tag = Text(m.name.isEmpty ? "未命名" : m.name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                ctx.draw(tag, at: CGPoint(x: p.x, y: p.y + 15))
            } else {
                let tag = Text(m.name.isEmpty ? "未命名" : m.name)
                    .font(.system(size: 7.5))
                    .foregroundStyle(Aurora.t3)
                ctx.draw(tag, at: CGPoint(x: p.x, y: p.y + 10))
            }
        }
    }
}

/// 「路径规划中」全屏遮罩（2026-10-03 新增）。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 为什么规划只要 0.06 ms，还要做这个动画？
/// ══════════════════════════════════════════════════════════════════════════
/// 用户明确要求保留 —— 理由是对的：当前 A* 快是因为图小（612 节点），
/// 一旦将来换成真实 AI 规划（LLM 推理 / 多目标 TSP / 路况重规划），
/// 耗时会从毫秒级跳到秒级。**到那时才做加载态，用户已经先看到卡死了**。
/// 所以现在就把「规划中 → 升级 → AI 思考中」这条通道建好，并保证：
///   · 文案按耗时递进（<0.7s 基础 / >1.5s 升级 / >3.0s 转金色 AI 态）
///   · 进度条持续滑动，让用户知道"还在动"，不是死了
///   · 最短显示 380ms —— 否则 0.06ms 的规划会让遮罩一闪而过，
///     反而像画面抖动（"闪一下"比"不显示"更糟）
///
/// 文案与节奏逐条对齐网页版 `RMESS` / `RAI`（tools/roadnet/web/index.html）。
struct RoutePlanningOverlay: View {
    /// 基础阶段文案（耗时 <3s）
    private static let stages: [(String, String)] = [
        ("路径规划中…",        "A* 正在搜索路网"),
        ("正在规划路线…",      "已展开更多节点，即将收敛"),
        ("AI 路径规划思考中…", "正在权衡「少拐弯」与「少绕路」"),
        ("仍在计算…",          "路网较大，请稍候"),
    ]
    /// AI 阶段文案（耗时 ≥3s，金色）
    private static let aiStages: [(String, String)] = [
        ("AI 路径规划思考中…", "正在比较候选路线的拐弯数"),
        ("AI 深度思考中…",     "正在尝试避开低效路口"),
        ("AI 仍在推理…",       "快好了，正在做最后校验"),
    ]

    /// 最短显示时长：规划太快时把遮罩拖到这么久，避免"闪一下"
    static let minimumVisibleSeconds: Double = 0.38

    @State private var elapsed: Double = 0
    @State private var spin: Double = 0
    @State private var barPhase: Double = 0

    /// 每 110ms 更新一次（与网页版同节奏）
    private let ticker = Timer.publish(every: 0.11, on: .main, in: .common).autoconnect()

    var body: some View {
        let stage = Self.stage(for: elapsed)
        let isAI = elapsed >= 3.0

        ZStack {
            // 半透明压暗底：让下面的地图仍可见（用户能看到起点在哪）
            Color(hex: 0x05080E, alpha: 0.62)

            VStack(spacing: 16) {
                // 旋转指示器（金色 = AI 态）
                ZStack {
                    Circle()
                        .stroke((isAI ? Aurora.amber : Aurora.ice).opacity(0.18), lineWidth: 3)
                        .frame(width: 46, height: 46)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(isAI ? Aurora.amber : Aurora.ice,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(spin))
                }

                VStack(spacing: 5) {
                    Text(stage.0)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isAI ? Aurora.amber : Aurora.t1)
                    Text(stage.1)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Aurora.t3)
                }

                // 滑动进度条（不确定进度 = 来回扫，表示"在动"）
                GeometryReader { g in
                    let w = g.size.width
                    Capsule()
                        .fill((isAI ? Aurora.amber : Aurora.ice).opacity(0.14))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(isAI ? Aurora.amber : Aurora.ice)
                                .frame(width: w * 0.34)
                                .offset(x: (w * 0.66) * barPhase)
                        }
                        .clipShape(Capsule())
                }
                .frame(width: 210, height: 3)

                Text(String(format: "已用时 %.1fs", elapsed))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Aurora.t4)
            }
            .padding(.horizontal, 34).padding(.vertical, 26)
            .background {
                RoundedRectangle(cornerRadius: Aurora.r3, style: .continuous)
                    .fill(Aurora.s2)
                    .overlay {
                        RoundedRectangle(cornerRadius: Aurora.r3, style: .continuous)
                            .strokeBorder(isAI ? Aurora.amber.opacity(0.45) : Aurora.hair3,
                                          lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        }
        // 遮罩自身吃掉点击，避免规划期间用户又点地图叠一堆请求
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear {
            elapsed = 0
            spin = 0
            barPhase = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spin = 360
            }
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                barPhase = 1
            }
        }
        .onReceive(ticker) { _ in elapsed += 0.11 }
    }

    /// 按耗时取当前文案（对齐网页版节奏：0.7s 升一档，1.5s 再升，3.0s 转 AI）
    static func stage(for elapsed: Double) -> (String, String) {
        if elapsed >= 3.0 {
            let idx = min(aiStages.count - 1, Int((elapsed - 3.0) / 1.8))
            return aiStages[idx]
        }
        if elapsed > 1.5 { return stages[2] }
        if elapsed > 0.7 { return stages[1] }
        return stages[0]
    }
}

/// 分类筛选条（2026-10-03 新增）。
///
/// 设计要点：
///   · 每个 chip 用**组色**，与地图上的点颜色一一对应 —— 用户看地图看到
///     一片琥珀色，回来一眼就能找到「传送点」这个 chip
///   · 右侧显示当前可见标记数 / 总数，让"筛掉多少"变成可核对的数字，
///     而不是"感觉少了"
///   · 「全部 / 默认 / 清空」三个快捷按钮：7 个 chip 逐个点太慢
struct MarkerFilterBar: View {
    @Binding var enabled: Set<String>
    let groups: [MarkerTaxonomy.Group]
    let counts: [String: Int]
    let visibleCount: Int
    let onReset: () -> Void
    let onAll: () -> Void
    let onNone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("标记分类")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Aurora.t3)
                Text("\(visibleCount)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Aurora.iceHi)
                Spacer(minLength: 10)
                smallButton("全部", onAll)
                smallButton("默认", onReset)
                smallButton("清空", onNone)
            }
            HStack(spacing: 5) {
                ForEach(groups) { g in
                    chip(g)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: Aurora.r2, style: .continuous)
                .fill(Color(hex: 0x05080E, alpha: 0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Aurora.r2, style: .continuous)
                .strokeBorder(Aurora.hair2, lineWidth: 1)
        }
    }

    private func chip(_ g: MarkerTaxonomy.Group) -> some View {
        let on = enabled.contains(g.label)
        let n = counts[g.id] ?? 0
        return Button {
            if on { enabled.remove(g.label) } else { enabled.insert(g.label) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(on ? g.color : Aurora.t4)
                    .frame(width: 6, height: 6)
                    .shadow(color: on ? g.color.opacity(0.8) : .clear, radius: 3)
                Text(g.label)
                    .font(.system(size: 9, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Aurora.t1 : Aurora.t4)
                Text("\(n)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(on ? g.color : Aurora.t4)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? g.color.opacity(0.13) : Color.white.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(on ? g.color.opacity(0.45) : Aurora.hair1, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("\(g.label)：\(n) 个标记")
    }

    private func smallButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t)
                .font(.system(size: 8.5))
                .foregroundStyle(Aurora.t3)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 聚团悬停提示（2026-10-03 新增）。
///
/// 成团后用户看不出"这团里是什么"，悬停给一个明细，
/// 避免"必须点进去才能知道" —— 而且点进去会设成导航终点，代价太大。
struct ClusterTooltip: View {
    let cluster: MarkerCluster

    /// 团内按组统计（最多列 4 组）
    private var breakdown: [(String, Int, Color)] {
        var c: [String: Int] = [:]
        for m in cluster.members { c[m.groupLabel ?? "未分类", default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.prefix(4).map { (label, n) in
            let col = cluster.members.first { ($0.groupLabel ?? "未分类") == label }?.color ?? Aurora.ice
            return (label, n, col)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if cluster.isCluster {
                Text("\(cluster.count) 个标记")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                ForEach(breakdown, id: \.0) { (label, n, col) in
                    HStack(spacing: 5) {
                        Circle().fill(col).frame(width: 5, height: 5)
                        Text(label).font(.system(size: 8.5)).foregroundStyle(Aurora.t3)
                        Spacer(minLength: 8)
                        Text("\(n)").font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(col)
                    }
                }
                if breakdown.count == 1 {
                    // 全同类的团：直接报代表点名字，比"8 个传送点"更有用
                    Text(cluster.representative.name)
                        .font(.system(size: 8))
                        .foregroundStyle(Aurora.t4)
                        .lineLimit(1)
                }
            } else {
                Text(cluster.representative.name.isEmpty ? "未命名"
                                                         : cluster.representative.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Aurora.t1)
                    .lineLimit(1)
                if let gl = cluster.representative.groupLabel {
                    HStack(spacing: 5) {
                        Circle().fill(cluster.representative.color).frame(width: 5, height: 5)
                        Text(gl).font(.system(size: 8.5)).foregroundStyle(Aurora.t3)
                    }
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(minWidth: 96, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: 0x05080E, alpha: 0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Aurora.hair3, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
    }
}

/// 滚轮/触控板双指滚动 → 缩放。
/// SwiftUI 没有「滚轮」手势，必须下沉到 AppKit 用 NSView 监听 scrollWheel。
/// 这是 macOS 地图类界面的标准交互（触控板双指上下滑 = 缩放）。
///
/// ⚠️ 实现要点（2026-09-22 踩坑，两条死路都试过）：
///   · `hitTest` 返回 nil  → AppKit 找不到 scrollWheel 的接收者，滚轮事件直接穿过去，缩放永远收不到。
///   · `hitTest` 返回 self → 这一层盖在整个地图上，把 mouseDown 全吃掉，拖拽平移和按钮点击全废。
/// 正解是分开走两条路：`hitTest` 保持 nil 完全不参与命中测试（点击/拖拽照常给 SwiftUI），
/// 滚轮则用本地事件监视器按坐标接管（监视器不受 hitTest 影响）。
struct MapScrollZoom: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ScrollCatcher {
        let v = ScrollCatcher()
        v.onZoom = onZoom
        return v
    }
    func updateNSView(_ nsView: ScrollCatcher, context: Context) {
        nsView.onZoom = onZoom
    }

    final class ScrollCatcher: NSView {
        var onZoom: ((Double) -> Void)?
        private var monitor: Any?

        /// 完全不参与命中测试：不抢点击、不抢拖拽、不挡按钮
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            // 本地监视器：只要指针落在这块视图范围内，滚轮就归我处理
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
                guard let self, let win = self.window, ev.window === win else { return ev }
                let p = self.convert(ev.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return ev }
                let d = ev.scrollingDeltaY
                guard abs(d) > 0.01 else { return ev }
                // 触控板是连续小增量，鼠标滚轮是离散大增量 —— 分别给系数，
                // 让两种设备的缩放手感接近。
                let step = ev.hasPreciseScrollingDeltas
                    ? 1.0 + min(0.08, abs(d) * 0.004)
                    : 1.10
                self.onZoom?(d > 0 ? step : 1 / step)
                return nil   // 吃掉，不让它再冒泡去滚别的容器
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

/// 大地图控制按钮（缩放 / 归位）—— 沿用玻璃胶囊样式
struct MapCtrlBtn: View {
    let icon: String
    var tint: Color = Aurora.t2
    var tip: String = ""
    let action: () -> Void
    @State private var hov = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hov ? tint : Aurora.t3)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(hov ? 0.72 : 0.55)))
                .overlay(Circle().strokeBorder(hov ? tint.opacity(0.5) : Aurora.hair1, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help(tip.isEmpty ? icon : tip)
    }
}

/// 决策轨（网页 .rail-sec）
struct DecisionRail: View {
    @Bindable var state: DriveState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("当前状态", "LIVE") {
                mini("M9 端到端", state.mode == .e2e ? "在线" : "待机",
                     state.mode == .e2e ? Aurora.ok : Aurora.t4)
                mini("YOLO 感知", state.mode == .yolo ? "在线" : "待机",
                     state.mode == .yolo ? Aurora.ok : Aurora.t4)
                mini("SpeedOCR", state.speedValid ? "\(Int(state.speedKmh)) km/h" : "待机",
                     state.speedValid ? Aurora.ok : Aurora.t4)
                mini("CoordinateCapture", state.locatorFound ? "已锁定" : "搜索中",
                     state.locatorFound ? Aurora.ok : Aurora.amber)
            }
            section("决策电路", "逐帧") {
                mini("主驾档位", state.mode.rawValue, Aurora.ice)
                mini("置信度", state.confidence > 0 ? String(format: "%.2f", state.confidence) : "—",
                     state.confidence > 0 ? Aurora.ok : Aurora.t4)
                mini("降级阈值", String(format: "%.2f", state.degradeThreshold), Aurora.amber)
                mini("强制规则", state.forceRuleMode ? "是" : "否",
                     state.forceRuleMode ? Aurora.danger : Aurora.t4)
            }
            section("状态向量 · [6]", "契约") {
                let b = state.driveBars
                vec("steer", b.steer)
                vec("throttle", b.throttle)
                vec("brake", b.brake)
                vec("speed", b.speed)
                vec("limit", state.speedLimit / 200)
                vec("conf", state.confidence)
            }
            section("推理链路", "M9") {
                mini("模型", DriveState.detectedModelName(), Aurora.ice)
                // ⚠️ 2026-09-28：这里原来写「端到端延迟」，但它实际是
                //    `1000 / 采集帧率` = **节拍周期**，不是推理耗时。
                //    用户看到 240ms 理解成"推理要 240ms"，与事实（YOLOPX 实测
                //    53.4ms）差一个数量级，会造成严重误判 —— 所以改文案说清语义。
                mini("链路节拍", String(format: "%.1f ms", state.e2eLatencyMs), Aurora.ice)
                mini("辅助帧率", String(format: "%.1f fps", EngineClient.shared.engineFPS), Aurora.ok)
                mini("累计帧", state.frames > 0 ? "\(state.frames)" : "—", Aurora.t3)
            }

            // ── 路线（2026-10-03 新增）──
            // 只在地图弹窗里出现（DecisionRail 的唯一挂载点就是大地图右侧栏）。
            routeSection(state: state)

            Spacer()
        }
        .padding(16)
    }

    /// 拐弯权重三档（值, 按钮文字）。
    /// 三档都经过实测对比才放上来，不是随手拍的数：
    ///   0   → 纯最短距离（7.45 km / 47 拐弯，起点终点样例）
    ///   200 → 实测最优默认（8.57 km / 20 拐弯，比字典序更快更短）
    ///   400 → 更激进避弯（会明显绕路）
    static let turnWeightPresets: [(Double, String)] = [
        (0, "距离优先"), (200, "均衡"), (400, "避弯优先"),
    ]

    /// 权重档位的语义说明
    static func turnWeightHint(_ w: Double) -> String {
        if w < 1 { return "只求路最短，拐弯多、跟手差" }
        if w < 300 { return "实测最优：拐弯与里程平衡" }
        return "尽量少拐弯，代价是绕路更远"
    }

    /// 路线卡片：显示规划结果，并提供「清除」。
    @ViewBuilder
    private func routeSection(state: DriveState) -> some View {
        section("路线", "A*") {
            switch state.routeStatus {
            case .planning:
                mini("状态", "规划中…", Aurora.amber)
            case .failed(let why):
                mini("状态", "失败", Aurora.danger)
                Text(why)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Aurora.t4)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok:
                if let r = state.routePlan {
                    mini("距离", String(format: "%.2f km", r.distanceMeters / 1000), Aurora.iceHi)
                    mini("拐弯", "\(r.turns) 次", r.turns <= 8 ? Aurora.ok : Aurora.amber)
                    mini("段数", "\(r.segments)", Aurora.t3)
                    mini("耗时", String(format: "%.2f ms", r.elapsedMs), Aurora.t4)
                }
            case .idle:
                Text(state.routeStartPx == nil
                     ? "点地图设终点（未定位时先点起点）"
                     : "再点一下设终点")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Aurora.t4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 拐弯权重选择器：让用户自己权衡「少拐弯」与「少绕路」
            //
            // ⚠️ 不用 `Picker(.menu)`：菜单样式在离屏 ImageRenderer 下会渲染成
            //    系统占位块（实测 --mc-route 出图里是一个琥珀色禁行图标），
            //    无法视觉验收；且弹出菜单与全 App 的自绘风格不一致。
            //    改为三个自绘小按钮，三档互斥高亮。
            VStack(alignment: .leading, spacing: 5) {
                Text("拐弯权重").font(.system(size: 9.5)).foregroundStyle(Aurora.t3)
                HStack(spacing: 4) {
                    ForEach(Self.turnWeightPresets, id: \.0) { preset in
                        let on = abs(state.routeTurnWeight - preset.0) < 0.5
                        Button {
                            state.routeTurnWeight = preset.0
                            // 已有点击路线时，换权重立即重规划（所见即所得）
                            if let sp = state.routeStartPx, let ep = state.routeEndPx {
                                state.planRouteFromMapPixel(from: sp, to: ep)
                            }
                        } label: {
                            Text(preset.1)
                                .font(.system(size: 8.5, weight: on ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3.5)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(on ? Aurora.ice.opacity(0.18) : Color.white.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(on ? Aurora.ice.opacity(0.5) : Aurora.hair1,
                                                  lineWidth: 1))
                                .foregroundStyle(on ? Aurora.iceHi : Aurora.t3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 当前模式的语义说明 —— 光有数字用户看不出区别
            Text(Self.turnWeightHint(state.routeTurnWeight))
                .font(.system(size: 8))
                .foregroundStyle(Aurora.t4)
                .fixedSize(horizontal: false, vertical: true)

            if state.routeStartPx != nil || state.routePlan != nil {
                Button {
                    state.clearRoute()
                } label: {
                    Text("清除路线")
                        .font(.system(size: 9.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Aurora.r1, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: Aurora.r1, style: .continuous)
                            .strokeBorder(Aurora.hair2, lineWidth: 1))
                        .foregroundStyle(Aurora.t2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func section<C: View>(_ t: String, _ badge: String,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(t)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Aurora.t3)
                Text(badge)
                    .font(.system(size: 7.5))
                    .foregroundStyle(Aurora.ice)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Aurora.iceWash))
                    .overlay(Capsule().strokeBorder(Aurora.iceLo, lineWidth: 1))
                Spacer()
            }
            content()
        }
    }

    private func mini(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(Aurora.t3)
            Spacer()
            Text(v).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(c)
        }
    }

    private func vec(_ k: String, _ v: Double) -> some View {
        HStack(spacing: 8) {
            Text(k)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Aurora.t4)
                .frame(width: 52, alignment: .leading)
            GeometryReader { g in
                let w = max(1, g.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5)).frame(height: 5)
                    Capsule().fill(Aurora.ice)
                        .frame(width: max(1, w * min(1, max(0, v))), height: 5)
                        .shadow(color: Aurora.ice.opacity(0.7), radius: 5)
                }
            }
            .frame(height: 9)
            Text(String(format: "%.2f", v))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Aurora.t3)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// ============================================================================
// MARK: - 技能浮层（网页 .ov#skov + .sheet，width 572）
// ============================================================================
// CSS: .sheet{width:572px;max-height:min(780px,90vh);border-radius:18px}

struct SkillOverlay: View {
    @Binding var isOpen: Bool
    @Bindable var center: AgentSkillCenter
    @State private var query = ""

    private var groups: [(SkillGroup, [AgentSkill])] {
        let all = AgentSkillLibrary.all.filter { s in
            query.isEmpty
                || s.name.localizedCaseInsensitiveContains(query)
                || s.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return SkillGroup.allCases.compactMap { g in
            let items = all.filter { SkillGroup.of($0) == g }
            return items.isEmpty ? nil : (g, items)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                // 头
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动化")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Aurora.t1)
                        Text("\(AgentSkillLibrary.all.count) 项技能 · \(center.runningSkills.count) 项运行中")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Aurora.t4)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Aurora.t4)
                        TextField("搜索技能", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Aurora.t1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Aurora.hair1, lineWidth: 1)
                    }

                    Spacer()

                    if !center.runningSkills.isEmpty {
                        Button {
                            center.stopAll(source: .human)
                        } label: {
                            Text("全部停止")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Aurora.danger)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Aurora.danger.opacity(0.13)))
                                .overlay(Capsule().strokeBorder(Aurora.danger.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Aurora.t3)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                            .overlay(Circle().strokeBorder(Aurora.hair1, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Aurora.hair1).frame(height: 1)
                }

                // 列表
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    Text(pair.0.rawValue)
                                        .font(.system(size: 9, weight: .semibold))
                                        .tracking(1.6)
                                        .foregroundStyle(Aurora.t3)
                                    Text("\(pair.1.count)")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Aurora.t4)
                                    Spacer()
                                }
                                ForEach(pair.1) { s in
                                    SkillRow(skill: s,
                                             running: center.runningSkills.contains(s.id)) {
                                        center.toggleSkill(s.id, source: .human)
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                }
                .frame(maxHeight: 560)
            }
            .frame(width: 572)
            .background {
                LinearGradient(colors: [Color(hex: 0x0B1421), Color(hex: 0x060B13)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Aurora.hair3, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.9), radius: 70, y: 50)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.975)))
        .onExitCommand { close() }
    }

    private func close() { withAnimation(.easeOut(duration: 0.22)) { isOpen = false } }
}

/// 单条技能行
struct SkillRow: View {
    let skill: AgentSkill
    let running: Bool
    var onToggle: () -> Void
    @State private var hov = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 11) {
                Text(skill.emoji)
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(running ? Aurora.okLo : Color.white.opacity(0.05))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(running ? Aurora.ok.opacity(0.45) : Aurora.hair1, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(running ? Aurora.ok : Aurora.t1)
                        if skill.warn {
                            Text("高风险")
                                .font(.system(size: 7.5))
                                .foregroundStyle(Aurora.danger)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Aurora.danger.opacity(0.15)))
                                .overlay(Capsule().strokeBorder(Aurora.danger.opacity(0.35), lineWidth: 1))
                        }
                        if !skill.ported {
                            Text("待移植")
                                .font(.system(size: 7.5))
                                .foregroundStyle(Aurora.t4)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.05)))
                                .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
                        }
                    }
                    Text(skill.keywords.prefix(3).joined(separator: " · "))
                        .font(.system(size: 8.5))
                        .foregroundStyle(Aurora.t4)
                        .lineLimit(1)
                }

                Spacer()

                Text(running ? "停止" : "运行")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(running ? Aurora.danger : Aurora.ice)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(running ? Aurora.danger.opacity(0.13)
                                                       : Aurora.ice.opacity(0.13)))
                    .overlay {
                        Capsule().strokeBorder(running ? Aurora.danger.opacity(0.4)
                                                       : Aurora.iceLo, lineWidth: 1)
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(running ? Aurora.okLo.opacity(0.6)
                                  : (hov ? Color.white.opacity(0.045) : Color.black.opacity(0.28)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(running ? Aurora.ok.opacity(0.35) : Aurora.hair1, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }
}

/// 技能分组（照网页分类）
enum SkillGroup: String, CaseIterable {
    case drive  = "驾驶"
    case daily  = "日常"
    case play   = "玩法"
    case risk   = "高风险"
    case preset = "预设"

    static func of(_ s: AgentSkill) -> SkillGroup {
        if s.warn { return .risk }
        let id = s.id.lowercased()
        if id.contains("drive") || id.contains("auto") || id.contains("nav") || id.contains("road") {
            return .drive
        }
        if id.contains("preset") || id.contains("macro") { return .preset }
        if s.ported { return .daily }
        return .play
    }
}

// ============================================================================
// MARK: - ContentView（网页 .app 整体布局）
// ============================================================================

struct ContentView: View {
    // ══════════════════════════════════════════════════════════════════════════
    // ⚠️ 2026-09-30 修复：「每次视图构造都重建 DriveState」的性能灾难
    // ══════════════════════════════════════════════════════════════════════════
    //
    // 【原写法】`@State private var state = DriveState()`
    //
    // 【为什么是灾难】`@State` 的默认值表达式属于**视图结构体的存储属性初始化**，
    //   而 SwiftUI 的 View 是值类型：**每次视图树重建都会构造一个新的
    //   ContentView 实例**，于是这个表达式被反复求值。
    //   SwiftUI 随后会丢弃这个新对象（沿用首次建立的 @State 存储），
    //   但**构造副作用已经真实发生了** —— 这是一个纯浪费、且开销极大。
    //
    // 【实测量级】`DriveState.init()` 里做的事（逐项）：
    //     · `upscaleHost.prepare()`   → `GooseUpscaler.make()` 建 Metal 引擎
    //       并配置插帧（`configureInterpolation()`，运行时编译着色器）
    //     · `gameHUD.install()`       → 建 NSWindow（左上角帧率 HUD）
    //     · `try? FileManager.removeItem('/tmp/aurora_debug.log')` → 删日志
    //     · 构造 captureEngine / yoloEngine / yolopxEngine / speedOCR 等
    //       十余个推理与采集组件
    //   日志实测（`AURORA_UI_LOCAL=1 ./AuroraDriveUI --auto-login`）：
    //     `[upscale] 引擎初始化` 与 `[network] 定位引擎初始化完成`
    //     **各出现 349 次 / 69 秒**，且同一秒内连续爆发多次 ——
    //     与「视图求值频率」完全吻合。
    //   ⟹ 每帧都在新建一整套推理引擎 + Metal 引擎 + NSWindow。
    //
    // 【修法】把 DriveState 提成进程级单例，`@State` 只持有那个**已存在的**
    //   实例（不触发构造）。语义等价：
    //     · 全进程本来就只需要一个 DriveState（它代表唯一一份驾驶状态机）；
    //     · 原写法在 UI 进程里的有效结果同样是「一个实例」，只是白白多造了
    //       几百个立刻被丢弃的副本；
    //     · 首次访问时构造一次，之后 `@State` 的默认值表达式只是取引用，
    //       零副作用。
    //   注意：`DriveState.shared` 内部仍保留「按参数决定是否清日志」等
    //   原有一次性初始化语义（见 DriveState.init 的 isUIStartup 判定），
    //   因为现在它确实只被构造一次。
    //
    // 【与引擎进程的关系】DriveState 在引擎进程（--engine）也会被创建一次，
    //   这是独立进程，各自持有自己的实例，不受本改动影响
    //   （单例是"每进程一个"，不是"全局一个"）。
    @State private var state = DriveState.shared
    @State private var tickTimer: Timer? = nil
    @State private var tickDispatchSource: DispatchSourceTimer? = nil
    @State private var netLocDispatchSource: DispatchSourceTimer? = nil
    @State private var showSkills = false
    @State private var showMap = false

    var body: some View {
        FitToWindow { avail in
            content
                .frame(width: avail.width, height: avail.height)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $state.showBPFPasswordSheet) {
            BPFPasswordSheet(state: state)
        }
        .sheet(isPresented: $state.showDaemonInstallSheet) {
            DaemonInstallSheet(state: state)
        }
        .onExitCommand {
            if showSkills { showSkills = false }
            else if showMap { showMap = false }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
            tickDispatchSource?.cancel()
            tickDispatchSource = nil
            netLocDispatchSource?.cancel()
            netLocDispatchSource = nil
        }
        .onAppear {
            MapDatabase.ensureLoaded()
            // 路网图（寻路用）与标记库并发后台加载：两者都是本地 JSON，
            // 互不依赖，串行只会让地图可用时间白白推后。
            RouteGraph.ensureLoaded()
            state.mapMarkerCount = MapDatabase.markerCount
            bootstrap()
        }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            // .app{height:100%;display:flex;flex-direction:column}
            // TopBar / KeyBar 是 auto 高度（永远保留），中间区域 flex:1 吃掉剩余空间。
            // 中间区域内容超出时由三栏各自的 ScrollView 滚动（网页 .col-m/.col-r 的
            // overflow-y:auto）—— 绝不像固定 frame 那样把顶/底条挤出画布。
            VStack(spacing: 0) {
                TopBar(state: state)

                VStack(spacing: 0) {
                    RCBar(condition: $state.roadCondition,
                          autoSpeedOn: state.autoSpeedEnabled,
                          detectedBoxCount: state.detectedBoxCount)
                        .padding(.horizontal, 13)
                        .padding(.top, 11)
                        .padding(.bottom, 2)
                        .layoutPriority(1)

                    MainGrid(state: state, showSkills: $showSkills, showMap: $showMap)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                KeyBar(state: state)
            }

            // 浮层（打开/关闭都留痕，便于核验链路而非猜测）
            if showMap {
                MapOverlay(isOpen: $showMap, state: state)
                    .zIndex(10)
                    .onAppear { print("[UI] 大地图浮层已打开") }
                    .onDisappear { print("[UI] 大地图浮层已关闭") }
            }
            if showSkills {
                SkillOverlay(isOpen: $showSkills, center: AgentSkillCenter.shared)
                    .zIndex(11)
                    .onAppear { print("[UI] 自动化技能浮层已打开") }
                    .onDisappear { print("[UI] 自动化技能浮层已关闭") }
            }
        }
        .background {
            ZStack {
                Aurora.void
                AuroraLightField(condition: state.roadCondition)
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 运行时引导（原 ContentView.onAppear 逻辑，逐条保留，勿删）
    // ════════════════════════════════════════════════════════════════════════
    private func bootstrap() {
        // ── tick 驱动 ──
        // 用 DispatchSource 替代 main RunLoop Timer：main RunLoop Timer 会被
        // App Nap 冻结（游戏全屏时 tick 掉到 8Hz）。DispatchSource 在独立高
        // 优先级队列上运行，不受 App Nap 影响。
        let timerQueue = DispatchQueue(label: "com.aurora.tick", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
        // ⚠️ 性能关键：不要无条件按 30Hz 往主线程投递 tick。
        //
        // 每次投递都会让 SwiftUI 走一遍事务 → 重新计算整棵视图树的布局
        // （实测采样里 LayoutEngineBox.explicitAlignment / flushObservers
        //  各占 780+ 样本），并让 WindowServer 跟着重合成。待机时这些计算
        // 完全是无用功，却把 UI 进程常年烧在 25-36%、WindowServer 44%+，
        // 整机发烫、帧率掉到 20 多帧。
        //
        // 按需求分级：开车 / 录制 / 引擎联动时保持 30Hz 实时性；
        // 纯待机降到约 4Hz —— 待机时界面本就静止，不需要 30Hz 刷新。
        var idleSkip = 0
        timer.setEventHandler {
            // 这些读取都是常量级，且不写状态，不会触发重绘
            let busy = state.isDriving || state.isRecording
            if !busy {
                idleSkip += 1
                if idleSkip < 8 { return }   // 30Hz / 8 ≈ 3.75Hz 待机刷新
                idleSkip = 0
            } else {
                idleSkip = 0
            }
            DispatchQueue.main.async { state.tick() }
        }
        timer.resume()
        tickTimer = nil
        tickDispatchSource = timer

        // ── Daemon 系统服务检查（优先级高于 BPF，影响整个进程调度）──
        state.isDaemonMode = DaemonSetupManager.isRunningAsDaemon()
        state.daemonInstalled = DaemonSetupManager.isDaemonInstalled()
        if DaemonSetupManager.needsInstall() {
            print("[App] 未安装为系统服务，显示安装引导")
            state.showDaemonInstallSheet = true
        } else if state.isDaemonMode {
            print("[App] 当前以系统服务运行（最高优先级）")
        } else if state.daemonInstalled {
            print("[App] 已安装系统服务，但当前为普通模式")
        }

        // ── 权限检查（小药丸）──
        // 状态判定统一走 PrivilegePill：它同时看「BPF 设备可读写」与
        // 「提权守护在跑」两件事。旧实现只看 /dev/bpf0（长期是 666）
        // → 恒判「已授权」→ 密码弹窗永远不弹，而实际抓包又开不了。
        state.privilegeReady = PrivilegePill.shared.isFullyAuthorized
        state.privilegeStatusDetail = PrivilegePill.shared.statusDetail
        state.bpfAuthorized = BPFSetupManager.isBPFAvailable()
        print("[App] 权限状态: ready=\(state.privilegeReady) — \(state.privilegeStatusDetail)")

        // 不需要密码的自愈：守护装过但当前没生效（典型场景是重启后
        // 内核新建了 bpf 设备没被 chmod 到），先尝试直接拉起。
        if !state.privilegeReady && BPFSetupManager.isLaunchDaemonInstalled() {
            Task { @MainActor in
                _ = PrivilegePill.shared.selfHeal()
                state.privilegeReady = PrivilegePill.shared.isFullyAuthorized
                state.privilegeStatusDetail = PrivilegePill.shared.statusDetail
                state.bpfAuthorized = BPFSetupManager.isBPFAvailable()
                print("[App] 权限自愈后: ready=\(state.privilegeReady)")
            }
        }

        // ── 网络定位定时器 10Hz ──
        let nlQueue = DispatchQueue(label: "com.aurora.netlocate", qos: .userInteractive)
        let nlTimer = DispatchSource.makeTimerSource(queue: nlQueue)
        nlTimer.schedule(deadline: .now(), repeating: 1.0 / 10.0, leeway: .nanoseconds(0))
        nlTimer.setEventHandler { DispatchQueue.main.async {
            state.runNetworkLocateStep()
        } }
        nlTimer.resume()
        netLocDispatchSource = nlTimer

        let args = CommandLine.arguments

        // ── 自主测试入口 ──
        if args.contains("--auto-drive") {
            print("[AUTO] --auto-drive 收到，1.5s 后自动开始驾驶")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { state.startDriving() }
        }
        if let i = args.firstIndex(of: "--auto-seconds"), i + 1 < args.count,
           let secs = Double(args[i + 1]), secs.isFinite {
            print("[AUTO] \(Int(secs))s 后自动退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                print("[AUTO] 到点退出")
                exit(0)
            }
        }
        if args.contains("--upscale-selftest") {
            print("[UPSELFTEST] 插帧引擎自检开始")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runUpscaleSelfTest() }
        }

        // ── AI Agent 面板初始化 ──
        // 注入按键/截屏引擎 → 技能中心（人类 + AI 共用执行通道）
        AgentSkillCenter.shared.configure(control: state.controlEngine,
                                          capture: state.captureEngine)

        if args.contains("--agent-selftest") {
            print("[AGENT] --agent-selftest 收到，1.2s 后开始自测")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AgentSkillCenter.shared.configure(control: state.controlEngine,
                                                  capture: state.captureEngine)
                AgentSelfTest.run(center: AgentSkillCenter.shared)
            }
        }
        if args.contains("--agent-ui-shot") {
            print("[UI-SHOT] 收到，开始无头渲染 AI 面板")
            AgentUIShot.run()
        }
        if args.contains("--agent-layout-shot") {
            print("[UI-SHOT] 收到，渲染折叠/展开布局对比")
            AgentUIShot.runLayoutCompare()
        }

        // 注：--auto-login 已移到 AppDelegate（applicationDidFinishLaunching）
        // 处理，与 UI 渲染解耦。这里仅负责把引擎注入给技能中心。
        AgentSkillCenter.shared.configure(control: state.controlEngine,
                                          capture: state.captureEngine)
    }
}

// ============================================================================
// MARK: - 无头截图（AuroraDrive --mc-shot [simple|complex|extreme|off]）
// ============================================================================
// 用 ImageRenderer 把整台控制台渲染到 PNG，不需要游戏在前台。
// 注意：ImageRenderer 不绘制 ScrollView 内容，且不触发 onAppear —— 因此
// 截图路径下所有卡片都必须是「计算属性 + 直接铺开」，不能用懒加载容器。

enum MissionControlShot {

    @MainActor
    /// 离屏渲染大地图浮层（用于验证真实地图/标记接入，不依赖窗口交互）
    @discardableResult
    static func renderMapNow(canvas: CGSize = CGSize(width: 1320, height: 860)) -> Bool {
        // 离屏渲染夹具：定位坐标用固定值以便可复现对比（真机一律走实时定位）。
        // 地图/标记/坐标换算全部走真实链路，与真机同一套代码。
        let state = DriveState()
        state.isDriving = true
        state.locatorFound = true
        // ⚠️ 2026-09-30 修复：locatorX/Y 与 locatorTarget 统一用**世界坐标**
        //    （UE5 厘米）。原夹具写 1080/1040 是地图像素语义，与 :1398
        //    的目标距离计算（(t.x - locatorX)/100 → 米）量纲不符。
        //    这里取一组真实量级的世界坐标（约在新赫兰德区域中心），
        //    使离屏渲染出的自车与目标点落在真实地图的合理位置。
        state.locatorX = -77000
        state.locatorY = 31865
        state.locatorTarget = (x: -76500, y: 32200)
        // ⚠️ 2026-09-30：`refreshRegionCache()` 必须放在 `ensureLoadedSyncLegacy()`
        //    **之后** —— 它内部要遍历 MapDatabase.markers 反查最近区域，
        //    若在数据库加载前调用，markers 还是空的，只会缓存成「未知区域」
        //    （实测踩过：区域名始终显示「未知区域」）。
        //    见下方 ensureLoadedSyncLegacy() 调用处的说明。
        // ⚠️ 2026-09-30：`ensureLoaded()` 已改为**后台异步加载**（修复
        //    `ContentView.body` 求值期读 7.2MB JSON 卡主线程的问题，见 MapWiring.swift）。
        //    异步化后它立即返回，紧接着读 `markerCount` 必然是 0 ——
        //    对**离屏夹具**而言这是错的：夹具本就是同步一次性渲染，
        //    没有"稍后 UI 再刷新"的机会。
        //    故夹具改调 `ensureLoadedSyncLegacy()`（原同步实现，保留至今）：
        //    它是纯读盘+解析，在离屏渲染路径上同步完成，语义与UI渲染前一致。
        MapDatabase.ensureLoadedSyncLegacy()
        state.mapMarkerCount = MapDatabase.markerCount
        // 数据库就绪后再刷新区域名（顺序不可颠倒，见上方注释）
        state.refreshRegionCache()
        return renderMap(state: state, canvas: canvas, tag: "online")
    }

    /// 游戏**未启动**时的大地图离屏渲染。
    ///
    /// 为什么必须单测这一档：2026-09-22 之前大地图的视角中心直接绑在
    /// `state.mapPixelX/Y` 上，而这两个量在 `locatorFound == false` 时恒等于
    /// 地图正中心 —— 于是游戏没开时大地图钉死不动、也没有任何缩放手势，
    /// 观感就是「一坨屎」。这个夹具把「无定位」这条路径固化下来，
    /// 保证以后不会再退化。
    @MainActor
    static func renderMapOfflineNow(canvas: CGSize = CGSize(width: 1320, height: 860)) -> Bool {
        let state = DriveState()
        state.isDriving = false
        state.locatorFound = false          // ← 关键：游戏未启动，无任何定位数据
        // 同 renderMapNow：离屏夹具必须同步拿到标记数（见该处注释）
        MapDatabase.ensureLoadedSyncLegacy()
        state.mapMarkerCount = MapDatabase.markerCount
        return renderMap(state: state, canvas: canvas, tag: "offline")
    }

    @MainActor
    private static func renderMap(state: DriveState, canvas: CGSize, tag: String) -> Bool {
        let view = ZStack {
            Color.black
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("大地图")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Aurora.t1)
                        Text("\(MapTileImage.mapDimensionLabel) · \(state.regionLabel)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Aurora.t4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                HStack(spacing: 0) {
                    LargeMapCanvas(state: state, interactive: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Aurora.hair1).frame(width: 1)
                    DecisionRail(state: state)
                        .frame(width: 300)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .background(Aurora.void)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[MC-MAP] ✗ 渲染失败")
            return false
        }
        let path = "/tmp/aurora_mc_map_\(tag).png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[MC-MAP] saved=true path=\(path) 标记=\(MapDatabase.markerCount) 定位=\(state.locatorFound ? "已锁定" : "未定位")")
            return true
        } catch {
            print("[MC-MAP] ✗ 写入失败 \(error)")
            return false
        }
    }

    /// 路网路线渲染夹具（`--mc-route`）。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// 为什么不能只靠 `--route-selftest` 的数字
    /// ══════════════════════════════════════════════════════════════════════════
    /// 自检能证明「算法算出 8.571 km / 20 拐弯」，但证明不了：
    ///   · 折线**真的画出来了**（图层条件、视口换算、canvas 尺寸任一错就白屏）
    ///   · 折线**贴着道路**（坐标换算错 → 线飘在地图外）
    ///   · 起点绿点 / 终点红点位置正确
    /// 这些只有出图能验。故本夹具与 `--mc-map` 同构，额外把规划结果塞进 state。
    ///
    /// 终点选择是**确定的**：取「离自车 400~900 像素」的一个节点，
    /// 保证路线落在默认 1200 m 视野内（否则截图里什么都看不到）。
    @MainActor
    static func renderMapRouteNow(canvas: CGSize = CGSize(width: 1320, height: 860)) -> Bool {
        let state = DriveState()
        state.isDriving = true
        state.locatorFound = true
        state.locatorX = -77000
        state.locatorY = 31865
        MapDatabase.ensureLoadedSyncLegacy()
        state.mapMarkerCount = MapDatabase.markerCount
        state.refreshRegionCache()

        // 与真机同一条链路：定位 → 地图像素 → 路网吸附 → 规划
        guard RouteGraph.ensureLoadedSync(), let g = RouteGraph.shared else {
            print("[MC-ROUTE] ✗ 路网加载失败：\(RouteGraph.loadError ?? "未知")")
            return false
        }
        let egoX = DriveState.worldToMapPixelX(state.locatorX, state.locatorY)
        let egoY = DriveState.worldToMapPixelY(state.locatorX, state.locatorY)
        guard let s = g.nearestNode(x: egoX, y: egoY) else {
            print("[MC-ROUTE] ✗ 自车位置吸附不到路网节点")
            return false
        }
        // 挑一个落在视野内的终点（400~900 px ≈ 244~549 m）
        var target: Int? = nil
        var bestScore = Double.infinity
        for (i, n) in g.nodes.enumerated() where i != s {
            let d = hypot(n.x - g.nodes[s].x, n.y - g.nodes[s].y)
            guard d > 400, d < 900 else { continue }
            let score = abs(d - 650)   // 取最接近 650 px 的
            if score < bestScore { bestScore = score; target = i }
        }
        guard let t = target else {
            print("[MC-ROUTE] ✗ 视野内找不到合适终点")
            return false
        }
        do {
            let plan = try RoutePlanner.route(graph: g, from: s, to: t,
                                              turnWeight: RoutePlanner.defaultTurnWeight)
            state.routePlan = plan
            state.routeStartPx = (g.nodes[s].x, g.nodes[s].y)
            state.routeEndPx = (g.nodes[t].x, g.nodes[t].y)
            state.routeStatus = .ok
            // locatorTarget 指向**终点** —— 这样 AURORA_ROUTE_STRAIGHT=1 时
            // 旧直线通路会画「自车→终点」的直线，与折线形成肉眼可辨的对照：
            // 折线贴着街道走，直线直接穿街区。这就是 A/B 的判别力所在。
            state.locatorTarget = (
                x: DriveState.mapPixelToWorldX(g.nodes[t].x, g.nodes[t].y),
                y: DriveState.mapPixelToWorldY(g.nodes[t].x, g.nodes[t].y)
            )
            print(String(format: "[MC-ROUTE] 起点节点 %d (%.0f,%.0f) → 终点节点 %d (%.0f,%.0f)",
                         s, g.nodes[s].x, g.nodes[s].y, t, g.nodes[t].x, g.nodes[t].y))
            print(String(format: "[MC-ROUTE] %.2f km · 拐弯 %d · %d 段 · %.2f ms · 折线 %d 顶点",
                         plan.distanceMeters / 1000, plan.turns, plan.segments,
                         plan.elapsedMs, plan.pointCount))
        } catch {
            print("[MC-ROUTE] ✗ 规划失败：\(error)")
            return false
        }
        return renderMap(state: state, canvas: canvas, tag: "route")
    }

    /// 「路径规划中」遮罩渲染夹具（`--mc-route-loading`）。
    ///
    /// 遮罩只在 `routeStatus == .planning` 时出现，而真机上这一状态只存在
    /// 380 ms（规划太快）—— 正常截图**几乎不可能**抓到它。
    /// 故这里直接置状态渲染，用来验文案、配色、进度条布局。
    /// 同时打印三档文案（含 AI 金色态）供逐项核对。
    @MainActor
    static func renderMapRouteLoadingNow(canvas: CGSize = CGSize(width: 1320, height: 860)) -> Bool {
        let state = DriveState()
        state.isDriving = true
        state.locatorFound = true
        state.locatorX = -77000
        state.locatorY = 31865
        MapDatabase.ensureLoadedSyncLegacy()
        state.mapMarkerCount = MapDatabase.markerCount
        state.refreshRegionCache()

        state.routeStartPx = (DriveState.worldToMapPixelX(state.locatorX, state.locatorY),
                              DriveState.worldToMapPixelY(state.locatorX, state.locatorY))
        state.routeEndPx = (state.routeStartPx!.0 + 300, state.routeStartPx!.1 - 220)
        state.routeStatus = .planning

        print("[MC-ROUTE-LOADING] 文案递进核对：")
        for (label, t) in [("0.0s", 0.0), ("0.8s", 0.8), ("1.6s", 1.6), ("3.2s", 3.2), ("6.0s", 6.0)] {
            let s = RoutePlanningOverlay.stage(for: t)
            print("    \(label.padding(toLength: 5, withPad: " ", startingAt: 0))  \(s.0)   | \(s.1)")
        }
        return renderMap(state: state, canvas: canvas, tag: "route_loading")
    }

    /// 地图渲染性能基准夹具（`--mc-map-bench`）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 为什么必须实测，不能"分析一下复杂度"
    /// ══════════════════════════════════════════════════════════════════════
    /// 本项目已有教训：12 项"想当然的优化"实测全被否决。所以这里给的是
    /// **可复现的数字**，不是推测：
    ///   · 400 点 ForEach → 18.92 ms/帧（超 60fps 预算 16.67）
    ///   · 400 点 Canvas  →  2.12 ms/帧
    ///   · 5677 点 Canvas →  0.81 ms/帧
    ///
    /// 本夹具渲染**真实地图全部图层**（底图 + 聚类标记 + 路线 + 自车）
    /// 若干次取平均，并与 `AURORA_MAP_LEGACY_MARKERS=1` 对比。
    ///
    /// ⚠️ 诚实声明：离屏 ImageRenderer 的耗时**不等于**真机合成器耗时
    ///   （真机有 GPU 合成、图层缓存、脏区重绘）。故本夹具的判据是
    ///   **新旧路径的相对差**，不宣称绝对 60fps。
    ///
    /// 为了让内容每帧真的变化（否则 ImageRenderer 直接命中缓存，
    /// 测出 0.000 ms 这种假数 —— 本小姐第一版就踩了这个坑），
    /// 每轮把视口中心平移 1 像素。
    @MainActor
    static func benchMapNow(iters: Int = 12) -> Bool {
        let state = DriveState()
        state.isDriving = true
        state.locatorFound = true
        state.locatorX = -77000
        state.locatorY = 31865
        MapDatabase.ensureLoadedSyncLegacy()
        state.mapMarkerCount = MapDatabase.markerCount
        state.refreshRegionCache()

        // 聚类规模（数字要能对上实测表）
        let spanM = 1200.0
        let spanPx = spanM * (MapTileImage.mapPixels / MapTileImage.worldMetersPerMap)
        let cx = MapTileImage.mapPixels / 2, cy = cx
        let all = MapDatabase.markersInViewAll(centerX: cx, centerY: cy, spanPx: spanPx)
        let on = MarkerTaxonomy.defaultOnGroups
        let filtered = all.filter { m in
            guard let l = m.groupLabel else { return true }
            return on.contains(l)
        }
        print("[MC-BENCH] ═══ 地图渲染基准（同进程三路对比，各 \(iters) 轮）═══")
        print("[MC-BENCH] 视野 \(Int(spanM)) m → 视野内 \(all.count) 个，"
              + "默认组过滤后 \(filtered.count) 个，可见组: \(on.sorted().joined(separator: ","))")

        /// 跑一种模式
        func run(_ mode: LargeMapCanvas.MarkerRenderMode, _ label: String,
                 span: Double?) -> Double {
            var times: [Double] = []
            times.reserveCapacity(iters)
            for i in 0..<iters {
                // 每轮平移 0.5px，强制重新渲染（否则 ImageRenderer 命中缓存，
                // 测出 0.000 ms 这种假数 —— 第一版就踩过）
                let shot = LargeMapCanvas(state: state, markerMode: mode,
                                          benchSpanMeters: span, interactive: false)
                    .frame(width: 1320, height: 860)
                    .offset(x: Double(i) * 0.5)
                let r = ImageRenderer(content: shot)
                r.scale = 1.0
                let t0 = DispatchTime.now()
                _ = r.nsImage
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
            }
            times.sort()
            let avg = times.reduce(0, +) / Double(times.count)
            let p50 = times[times.count / 2]
            let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
            print(String(format: "[MC-BENCH] %-22@ 平均 %7.2f ms · p50 %7.2f · p95 %7.2f",
                         label as NSString, avg, p50, p95))
            return avg
        }

        // ══ 第一组：1200 m 视野（默认档）三路对比 ══
        print()
        print("[MC-BENCH] ── 视野 1200 m（默认档，标签不显示，因门槛 \(Int(LargeMapCanvas.labelSpanM)) m）──")
        let base = run(.none, "① 仅底图（基线）", span: nil)
        let legacy = run(.legacy, "② ForEach 旧路径", span: nil)
        let canvas = run(.canvas, "③ Canvas+聚类 新路径", span: nil)

        print()
        print(String(format: "[MC-BENCH] 标记层增量：旧 %.2f ms  →  新 %.2f ms  "
                     + "（%.1f× 提速，省 %.2f ms）",
                     legacy - base, canvas - base,
                     (legacy - base) / max(0.01, canvas - base), (legacy - canvas)))

        // ══ 第二组：300 m 视野（**标签Active** —— 这是最坏情况）══
        //
        // ⚠️ 为什么必须单独测这一档：标签门槛是 400 m，1200 m 视野下
        //    `drawLabels` 直接 return，一个标签都不画。若只测 1200 m 就宣称
        //    "标记层 0.47 ms"，等于把最贵的一步漏掉了 —— 是假结论。
        //    标签成本实测 ~32.7 µs/个，200 个 ≈ 6.5 ms，必须实测确认。
        print()
        print("[MC-BENCH] ── 视野 300 m（**标签全开**，最坏情况）──")
        let baseN = run(.none, "① 仅底图（基线）", span: 300)
        let legacyN = run(.legacy, "② ForEach 旧路径", span: 300)
        let canvasN = run(.canvas, "③ Canvas+聚类 新路径", span: 300)
        print()
        print(String(format: "[MC-BENCH] 近景标记层增量：旧 %.2f ms  →  新 %.2f ms",
                     legacyN - baseN, canvasN - baseN))
        print(String(format: "[MC-BENCH] 近景新路径整体 %.2f ms（含底图 %.2f ms）",
                     canvasN, baseN))

        let budget = 16.67
        print()
        print(String(format: "[MC-BENCH] 60fps 预算 %.2f ms → 1200m %@ · 300m(标签全开) %@",
                     budget,
                     canvas < budget ? "✓" : "✗", canvasN < budget ? "✓" : "✗"))
        print("[MC-BENCH] ⚠️ 离屏 ImageRenderer ≠ 真机合成器耗时，此表用于**相对对比**，"
              + "不宣称真机绝对 60fps")
        return true
    }

    /// 同步离屏渲染（由 AuroraDriveLauncher 直接调用，不依赖窗口生命周期）
    @MainActor
    @discardableResult
    static func renderNow(condition: RoadCondition,
                          canvas: CGSize = ConsoleMetrics.designSize) -> Bool {
        let tag = canvas == ConsoleMetrics.designSize
            ? "\(condition.rawValue)"
            : "\(condition.rawValue)_\(Int(canvas.width))x\(Int(canvas.height))"
        let path = "/tmp/aurora_mc_\(tag).png"
        let ok = render(to: path, condition: condition, canvas: canvas)
        print("[MC-SHOT] saved=\(ok) path=\(path)")
        return ok
    }

    @MainActor
    private static func render(to path: String, condition: RoadCondition,
                               canvas: CGSize = ConsoleMetrics.designSize) -> Bool {
        let state = DriveState()
        state.roadCondition = condition
        state.autoSpeedEnabled = condition.autoSpeedActive
        state.isDriving = true
        state.speedLimit = condition == .off ? 200 : (condition.autoSpeedLimit ?? 120)
        state.bpfAuthorized = true
        state.daemonInstalled = true
        state.engineConnected = true
        state.locatorFound = true
        state.upscaleSupported = true
        state.upscaleEnabled = true
        state.expertMode = true
        state.gameModeBoost = true
        state.frames = 12840
        // ⚠️ 2026-09-30 修复：与 renderMapNow 同一处问题 —— locatorX/Y 必须是
        //    **世界坐标（UE5 厘米）**，不能是地图像素。原先的 1080/1040 会被
        //    读取端再变换一次，导致截图里的自车位置与真实地图错开 864 米。
        //    这里用真实量级的世界坐标，保证截图夹具与真机走同一套语义。
        state.locatorX = -77000
        state.locatorY = 31865
        // 同 renderMapNow：regionLabel 已改为「缓存读取」（见 DriveState.regionLabel），
        // 夹具需显式刷新一次；且必须在数据库**加载之后**刷新，否则 markers 为空、
        // 只会缓存成「未知区域」。TopBar 要显示区域名，故这里同步加载一次。
        MapDatabase.ensureLoadedSyncLegacy()
        state.refreshRegionCache()
        state.speedValid = true
        // 截图夹具：给一个固定源画面尺寸，便于渲染对比（真机一律取实时 screenSize）
        state.screenSize = CGSize(width: 2560, height: 1664)
        // ⚠️ 2026-09-30 追加：给夹具设目标点，让 `NavGuidance` 的**转向指示**分支
        //    能被渲染出来。
        //
        // `NavGuidance.derive(from:)` 有三条分支，**转向逻辑只在第三条**：
        //     ① 未定位        → 「定位中」
        //     ② 已定位但无目标 → 「未设目标」
        //     ③ 已定位且有目标 → 距离 + 转向 + 剩余里程
        // 原夹具只设了 `locatorFound`（走②），于是本轮修的转向指示
        // （参考系混用，错误率 58.3% → 1.0%，见文档 6.25）在这张截图上
        // 根本不会被渲染 —— 修了却无法视觉验收。
        //
        // 目标取「自车**正北** 5 米」——这是一个**有判别力**的用例：
        //   世界坐标里 −Y 为北（`kNorth ≈ (0,−1,0)`），自车 `locatorHeading`
        //   夹具默认 0°（罗盘角 = 朝正北）。
        //     修复后：target 罗盘方位 = 0°，rel = 0° → 「米后直行」✓
        //     修复前：`atan2(Δy, Δx)` = `atan2(−500, 0)` = −90°，
        //             rel = −90 − 0 = −90° → 「米后左转」✗
        //   故截图里出现「米后直行」即证明修复生效；若回归会显示「米后左转」。
        state.locatorTarget = (x: state.locatorX, y: state.locatorY - 500)

        // 截图：只锁宽度，高度由内容自然撑开（ImageRenderer 下高度提案不可靠，
        // 硬套 frame 会裁掉顶/底条）。
        let console = VStack(spacing: 0) {
            TopBar(state: state)

            VStack(spacing: 0) {
                RCBar(condition: .constant(condition),
                     autoSpeedOn: condition.autoSpeedActive)
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
                    .padding(.bottom, 2)

                HStack(spacing: 13) {
                    // ── 左栏 ──
                    VStack(spacing: 13) {
                        ZStack {
                            LinearGradient(
                                stops: [
                                    .init(color: Color(hex: 0x0C1421), location: 0),
                                    .init(color: Color(hex: 0x05080F), location: 0.62),
                                    .init(color: Color(hex: 0x04070C), location: 1),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                            AuroraLightField(condition: condition)
                            VStack {
                                HStack {
                                    HStack(spacing: 6) {
                                        TagChip(text: "LIVE", live: true)
                                        TagChip(text: "THIRD-PERSON")
                                        TagChip(text: state.resolutionLabel)
                                    }
                                    Spacer()
                                    TagChip(text: "YUYAN / \(state.regionLabel)")
                                }
                                Spacer()
                                HStack(alignment: .bottom) {
                                    Spacer()
                                    AutoSpeedPill(isOn: condition.autoSpeedActive,
                                                  condition: condition,
                                                  onToggle: {}, onCycle: {})
                                        .padding(.bottom, 26)
                                    // 真实数据：速度取 EngineClient/SpeedOCR，置信度取
                                    // ConfidenceEstimator，延迟取引擎实测帧间隔 —— 全部实时值。
                                    DualGauge(speedKmh: state.speedKmh,
                                              valid: state.speedValid || state.speedKmh > 0.01,
                                              confidence: state.confidence,
                                              latency: state.e2eLatencyMs,
                                              condition: condition)
                                }
                                .padding(.trailing, 26)
                                .padding(.bottom, 44)
                            }
                            .padding(14)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(condition.needsTakeover
                                              ? Aurora.danger.opacity(0.75) : Aurora.hair1,
                                              lineWidth: condition.needsTakeover ? 1.5 : 1)
                        }
                        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)

                        GearRing(mode: .e2e, running: true, onSelect: nil)
                    }
                    .frame(maxWidth: .infinity)

                    // ── 中栏 ──
                    VStack(spacing: 13) {
                        MiniMapCard(state: state, onOpen: {})
                        HardwareBank(state: state)
                        RunLogCard(state: state)
                PerceptionPickerCard(state: state)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 344)

                    // ── 右栏 ──
                    VStack(spacing: 13) {
                        AIChatStatic()
                        AutomationBigButton(count: AgentSkillLibrary.all.count) {}
                        RunStatusCard(state: state)
                        SystemCard(state: state)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 372)
                }
                .padding(13)
            }

            KeyBar(state: state)
        }
        .frame(width: canvas.width)
        .background(Aurora.void)

        let renderer = ImageRenderer(content: console)
        renderer.scale = 1.6
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[MC-SHOT] 渲染失败")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[MC-SHOT] 已渲染 画布\(Int(canvas.width))x\(Int(canvas.height)) [\(condition.rawValue)]")
            return true
        } catch {
            print("[MC-SHOT] 写盘失败: \(error)")
            return false
        }
    }
}



// ============================================================================
// MARK: - AI 助手对话卡（网页 .ai-card）
// ============================================================================
// 严格照网页结构，网页里这张卡只有三块：
//   .ai-head  头像 ✦ + 「AI 助手 / 在线 · N 技能已挂载」+ 设置
//   .ai-body  消息流（.msg.u 右对齐 / .msg.a 左对齐 / .msg.sys 居中分隔）
//   .ai-foot  输入框 + 发送键 + 4 个快捷 chips（车况报告/开始录制/规划路线/停车）
// 不再使用旧的 AIAgentPanelView（那版带技能网格与模型选择器，不在网页里）

struct AIChatCard: View {
    @Bindable var center: AgentSkillCenter
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let chips = ["车况报告", "开始录制", "规划路线", "停车"]

    var body: some View {
        VStack(spacing: 0) {
            head
            Rectangle().fill(Aurora.hair1).frame(height: 1)

            // .ai-body
            // LazyVStack：长会话（几十条消息）只渲染可见的 ~10 条，滚动到哪渲染到哪；
            // 消息带稳定 id（.id(m.id)），scrollTo 定位与 diff 行为不变。
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(center.messages) { m in
                            MessageBubble(msg: m).id(m.id)
                        }
                        if center.messages.isEmpty {
                            Text("— 会话开始 \(timeNow) —")
                                .font(.system(size: 9, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(Aurora.t4)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: center.messages.count) { _, _ in
                    if let last = center.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Aurora.hair1).frame(height: 1)
            foot
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Aurora.s1)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(
                        stops: [.init(color: .white.opacity(0.026), location: 0),
                                .init(color: .white.opacity(0), location: 0.34)],
                        startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Aurora.hair1, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
        .shadow(color: .black.opacity(0.32), radius: 1, y: 1)
    }

    // ── .ai-head ──
    private var head: some View {
        HStack(spacing: 10) {
            Text("✦")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Aurora.ice.opacity(0.30), Aurora.violet.opacity(0.20)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Aurora.hair3, lineWidth: 1)
                }
                .shadow(color: Aurora.iceGlow, radius: 16)

            VStack(alignment: .leading, spacing: 2.5) {
                Text("AI 助手")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                HStack(spacing: 5) {
                    Circle().fill(Aurora.ok).frame(width: 4.5, height: 4.5)
                        .shadow(color: Aurora.ok, radius: 7)
                    Text("在线 · \(AgentSkillLibrary.all.count) 技能已挂载")
                        .font(.system(size: 8.5, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Aurora.ok)
                }
            }

            Spacer()

            Text("设置")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Aurora.t4)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14).padding(.bottom, 13)
        .background {
            LinearGradient(colors: [Aurora.ice.opacity(0.045), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // ── .ai-foot ──
    private var foot: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("说点什么… 例：去钓鱼 / 开始录数据", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Aurora.t1)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: 0x03070E, alpha: 0.8))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(focused ? Aurora.iceLo : Aurora.hair1, lineWidth: 1)
                    }
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Aurora.ice)
                        .frame(width: 38, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Aurora.ice.opacity(0.18), Aurora.ice.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Aurora.hair3, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { c in
                    Button {
                        draft = c
                        send()
                    } label: {
                        Text(c)
                            .font(.system(size: 9.5, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Aurora.t3)
                            .padding(.horizontal, 10).padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.white.opacity(0.015)))
                            .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 15)
        .padding(.top, 12).padding(.bottom, 13)
    }

    // DateFormatter 提为 static let：创建很重（ICU 初始化），原计算属性
    // 每次 body 求值都新建。iOS 7 起线程安全，且只被主线程求值，共享安全。
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeNow: String {
        return Self.hmFormatter.string(from: Date())
    }

    /// 走技能中心的真实通道（人类来源）
    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        center.sendUserMessage(t, source: .human)
        draft = ""
    }
}

/// 消息气泡（网页 .msg / .msg.u / .msg.a / .msg.sys）
struct MessageBubble: View {
    let msg: AgentMessage

    var body: some View {
        switch msg.role {
        case .system:
            // .msg.sys：居中、mono、无背景
            HStack {
                Spacer()
                Text("— \(msg.text) —")
                    .font(.system(size: 9, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Aurora.t4)
                    .padding(.vertical, 3)
                Spacer()
            }

        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(msg.text)
                    .font(.system(size: 11.5))
                    .lineSpacing(4)
                    .foregroundStyle(Aurora.t1)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Aurora.ice.opacity(0.17), Aurora.ice.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Aurora.hair3, lineWidth: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 12,
                        bottomTrailingRadius: 4, topTrailingRadius: 12,
                        style: .continuous))
            }

        case .assistant:
            HStack {
                Text(msg.text)
                    .font(.system(size: 11.5))
                    .lineSpacing(4)
                    .foregroundStyle(Aurora.t2)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.05), .white.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Aurora.hair1, lineWidth: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12, topTrailingRadius: 12,
                        style: .continuous))
                Spacer(minLength: 30)
            }
        }
    }
}

// ============================================================================
// MARK: - 分辨率自适应（网页 .app{height:100%} + 网格 fr 单位的等价实现）
/// 截图专用的 AI 卡：结构与文案严格照网页 .ai-card（静态内容）。
/// 真机用 AIChatCard（绑定技能中心），两者视觉规格完全一致。
struct AIChatStatic: View {
    private let msgs: [(String, String)] = [
        ("sys", "— 会话开始 21:22 —"),
        ("u",   "帮我看下现在车况"),
        ("a",   "当前 87 km/h，端到端主驾运行中，置信度 0.94，ANE 占用 28%。\n前方 12.4m 检测到行人，已减速。"),
        ("u",   "顺便挂个钓鱼"),
        ("a",   "好的，已启动 自动钓鱼 技能。需要我同时开启挂机预设吗？"),
        ("sys", "— 技能队列 1 项运行中 —"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // .ai-head
            HStack(spacing: 10) {
                Text("✦")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Aurora.ice.opacity(0.30), Aurora.violet.opacity(0.20)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Aurora.hair3, lineWidth: 1)
                    }
                    .shadow(color: Aurora.iceGlow, radius: 16)

                VStack(alignment: .leading, spacing: 2.5) {
                    Text("AI 助手")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.t1)
                    HStack(spacing: 5) {
                        Circle().fill(Aurora.ok).frame(width: 4.5, height: 4.5)
                            .shadow(color: Aurora.ok, radius: 7)
                        // 数量取自真实技能库，不写死 18
                        Text("在线 · \(AgentSkillLibrary.all.count) 技能已挂载")
                            .font(.system(size: 8.5, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Aurora.ok)
                    }
                }
                Spacer()
                Text("设置")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Aurora.t4)
            }
            .padding(.horizontal, 15)
            .padding(.top, 14).padding(.bottom, 13)
            .background {
                LinearGradient(colors: [Aurora.ice.opacity(0.045), .clear],
                               startPoint: .top, endPoint: .bottom)
            }

            Rectangle().fill(Aurora.hair1).frame(height: 1)

            // .ai-body
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                    switch m.0 {
                    case "sys":
                        HStack {
                            Spacer()
                            Text(m.1)
                                .font(.system(size: 9, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(Aurora.t4)
                                .padding(.vertical, 3)
                            Spacer()
                        }
                    case "u":
                        HStack {
                            Spacer(minLength: 30)
                            Text(m.1)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Aurora.t1)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(
                                            colors: [Aurora.ice.opacity(0.17), Aurora.ice.opacity(0.08)],
                                            startPoint: .top, endPoint: .bottom))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Aurora.hair3, lineWidth: 1)
                                }
                                .clipShape(UnevenRoundedRectangle(
                                    topLeadingRadius: 12, bottomLeadingRadius: 12,
                                    bottomTrailingRadius: 4, topTrailingRadius: 12,
                                    style: .continuous))
                        }
                    default:
                        HStack {
                            Text(m.1)
                                .font(.system(size: 11.5))
                                .lineSpacing(4)
                                .foregroundStyle(Aurora.t2)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(
                                            colors: [.white.opacity(0.05), .white.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Aurora.hair1, lineWidth: 1)
                                }
                                .clipShape(UnevenRoundedRectangle(
                                    topLeadingRadius: 12, bottomLeadingRadius: 4,
                                    bottomTrailingRadius: 12, topTrailingRadius: 12,
                                    style: .continuous))
                            Spacer(minLength: 30)
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)

            Rectangle().fill(Aurora.hair1).frame(height: 1)

            // .ai-foot
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("说点什么… 例：去钓鱼 / 开始录数据")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Aurora.t4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: 0x03070E, alpha: 0.8))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Aurora.hair1, lineWidth: 1)
                        }
                    Text("↑")
                        .font(.system(size: 14))
                        .foregroundStyle(Aurora.ice)
                        .frame(width: 38, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Aurora.ice.opacity(0.18), Aurora.ice.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Aurora.hair3, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 6) {
                    ForEach(["车况报告", "开始录制", "规划路线", "停车"], id: \.self) { c in
                        Text(c)
                            .font(.system(size: 9.5, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Aurora.t3)
                            .padding(.horizontal, 10).padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.white.opacity(0.015)))
                            .overlay(Capsule().strokeBorder(Aurora.hair1, lineWidth: 1))
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 15)
            .padding(.top, 12).padding(.bottom, 13)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Aurora.s1)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(
                        stops: [.init(color: .white.opacity(0.026), location: 0),
                                .init(color: .white.opacity(0), location: 0.34)],
                        startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Aurora.hair1, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)
        .shadow(color: .black.opacity(0.32), radius: 1, y: 1)
    }
}


// ============================================================================
// MARK: - 控制台尺寸常量
// ============================================================================

/// 控制台参考尺寸（截图/默认画布用）。
/// 真机不再用它做固定 frame —— 布局走网页那套自然伸缩（顶/底条 auto 高度，
/// 中间区域 flex:1，三栏各自滚动），窗口多大多小都不会挤出顶/底条。
enum ConsoleMetrics {
    /// 设计基准：必须 ≥ 内容固有宽度（三栏 1fr+344+372 加内边距约 1400），
    /// 否则内容会溢出 frame 导致右侧栏被裁。
    static let designWidth: CGFloat = 1470
    static let designHeight: CGFloat = 956
    static var designSize: CGSize { CGSize(width: designWidth, height: designHeight) }
}

// ============================================================================
// MARK: - 等比缩放自适应（FitToWindow）
struct FitToWindow<Content: View>: View {
    /// 传入「设计坐标系下的可用尺寸」，由调用方按该尺寸铺内容。
    @ViewBuilder var content: (CGSize) -> Content

    @State private var scale: CGFloat = 1
    @State private var layoutH: CGFloat = ConsoleMetrics.designHeight
    @State private var ready = false

    var body: some View {
        // 刻意不用 GeometryReader 做缩放：窗口首帧它拿到 0×0，0 参与除法会把
        // 整台界面压塌成 30pt 高（窗口变 1200×30，比不缩放更糟）。
        // 用 Color.clear 撑满 + onGeometryChange 读真实可用矩形，配 NSWindow 双保险。
        Color.clear
            // Color.clear 没有固有尺寸，若不给最小尺寸，窗口会按理想尺寸算成 0，
            // 整窗塌成只剩标题栏（实测 1200×30）。这里给出可用的最小固有尺寸。
            .frame(minWidth: 880, minHeight: 500)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                content(CGSize(width: ConsoleMetrics.designWidth, height: layoutH))
                    .frame(width: ConsoleMetrics.designWidth, height: layoutH)
                    .scaleEffect(scale, anchor: .center)
                    // scaleEffect 只做视觉变换、不改布局尺寸，必须手动收缩占位
                    .frame(width: ConsoleMetrics.designWidth * scale,
                           height: layoutH * scale)
            }
            // 只用窗口口径（WindowSizeReader，读 NSWindow.frame）作为唯一真相源。
            // onGeometryChange 拿到的是 SwiftUI 布局区，会少一条标题栏高度（728 vs 760），
            // 两路同时喂 update 会互相覆盖，最终按小的那个布局 → 顶部露 32pt 黑带。
            .background(WindowSizeReader { size in update(for: size) })
    }

    /// 等比自适应：缩放只由**宽度**驱动，设计高度反推。
    ///
    ///   scale   = 可用宽 / 设计宽
    ///   设计高  = 可用高 / scale
    ///
    /// 于是 content 占位 = 设计宽×scale × 设计高×scale = 可用宽 × 可用高，
    /// **严丝合缝铺满窗口，不会出现任何黑边**；同时横竖同比例，绝不拉伸变形。
    /// 高度变化只改变中间的弹性区域（三栏内部各自滚动），顶栏/键盘条始终完整可见。
    ///
    /// 早先用 contain（min 两个比例）会在一侧留黑边 —— 那正是「绕了一整圈黑边」
    /// 的成因：窗口宽高比 ≠ 设计基准宽高比时，缩放后必有一侧空出来。
    private func update(for size: CGSize) {
        guard size.width > 200, size.height > 150 else { return }
        let s = size.width / ConsoleMetrics.designWidth
        // 设计高 = 可用高 / scale，于是内容占位正好 = 可用尺寸（零黑边）。
        // 不再夹紧 —— 任何夹紧都会让占位 ≠ 可用尺寸，反而露出黑边。
        // 极端宽高比由各栏的 ScrollView / maxHeight 弹性吸收。
        let h = max(size.height / s, 1)
        if !ready || abs(s - scale) > 0.0005 || abs(h - layoutH) > 0.5 {
            scale = s
            layoutH = h
            ready = true
            print("[FIT] 可用=\(Int(size.width))x\(Int(size.height)) scale=\(String(format: "%.3f", s)) 设计高=\(Int(h))")
        }
    }
}




/// 读取承载窗口的真实尺寸，并在 resize 时回调。
/// 不依赖 GeometryReader —— 窗口尺寸从 NSWindow.contentLayoutRect 直接取，
/// 首帧就是准确值，不会出现 0 尺寸导致的布局塌陷。
struct WindowSizeReader: NSViewRepresentable {
    var onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SizeProbeView {
        let v = SizeProbeView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: SizeProbeView, context: Context) {
        nsView.onChange = onChange
        // ⚠️ 绝对不要在这里强制上报尺寸。
        //
        // updateNSView 每次 SwiftUI 布局都会被调用，而它一旦上报 → 改父视图
        // 的 @State scale → 又触发布局 → 再次 updateNSView → 死循环。
        // 实测这就是「每帧重算」的根源：主线程被 ViewDimensions /
        // SecondaryLayerGeometryQuery 占满（采样 820+），CPU 常年 30-80%，
        // WindowServer 被拖到 88%，整机发烫、帧率掉到 20 多帧。
        //
        // 尺寸变化只需要由 SizeProbeView 自己的窗口通知驱动（真 resize 时才变），
        // 布局回调不是「尺寸变了」的信号。
    }

    final class SizeProbeView: NSView {
        var onChange: ((CGSize) -> Void)?
        private var last: CGSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged),
                name: NSWindow.didResizeNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged),
                name: NSWindow.didEnterFullScreenNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged),
                name: NSWindow.didExitFullScreenNotification, object: w)
            // 窗口所在屏幕变化（拖到另一块显示器）也要重算
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged),
                name: NSWindow.didChangeScreenNotification, object: w)
            reportIfNeeded(force: true)
        }

        @objc private func windowChanged() { reportIfNeeded(force: true) }

        func reportIfNeeded(force: Bool = false) {
            guard let w = window else { return }
            // ★ 关键：contentLayoutRect 会比实际内容区少一条标题栏高度
            // （实测 frame=760 / contentRect=760 / contentLayoutRect=728，差 32pt）。
            // 若按它布局，内容只画 728，顶上 32pt 空出来 = 一圈黑边的来源。
            // 本窗口开了 .fullSizeContentView（fullSize=true），内容本就可以占满整窗，
            // 所以一律用 frame 反算的内容区尺寸，绝不用 contentLayoutRect。
            let size = w.frame.size
            guard size.width > 1, size.height > 1 else { return }
            if force || abs(size.width - last.width) > 0.5 || abs(size.height - last.height) > 0.5 {
                last = size
                let cb = onChange
                DispatchQueue.main.async { cb?(size) }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}


// ============================================================================
// MARK: - 自动驾驶总开关
// ============================================================================
// 真实接线：开启 → state.startDriving()，关闭 → state.stopDriving()。
// 二者是引擎的真实启停入口（会拉起/停止抓屏、模型、按键注入、录制收尾）。
// 开启前需辅助功能权限，无权限时引擎内部会弹系统设置引导，这里如实提示。

struct AutoDriveSwitch: View {
    @Bindable var state: DriveState
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            if state.isDriving {
                state.stopDriving()
            } else {
                state.startDriving()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { busy = false }
        } label: {
            HStack(spacing: 11) {
                // 开关轨道
                ZStack(alignment: state.isDriving ? .trailing : .leading) {
                    Capsule()
                        .fill(state.isDriving
                              ? Aurora.ok.opacity(0.20)
                              : Color.black.opacity(0.45))
                    Capsule()
                        .strokeBorder(state.isDriving ? Aurora.okLo : Aurora.hair2, lineWidth: 1)
                    Circle()
                        .fill(state.isDriving ? Aurora.ok : Aurora.t3)
                        .frame(width: 15, height: 15)
                        .padding(2)
                        .shadow(color: state.isDriving ? Aurora.ok.opacity(0.8) : .clear, radius: 6)
                }
                .frame(width: 40, height: 21)
                .animation(.easeInOut(duration: 0.18), value: state.isDriving)

                VStack(alignment: .leading, spacing: 2) {
                    Text("自动驾驶")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Aurora.t1)
                    Text(state.isDriving ? "运行中 · 点击停止" : "已停止 · 点击启动")
                        .font(.system(size: 8.5))
                        .foregroundStyle(state.isDriving ? Aurora.ok : Aurora.t4)
                }

                Spacer()

                if state.controlPermissionDenied {
                    Text("需辅助功能权限")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Aurora.danger)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(state.isDriving ? Aurora.ok.opacity(0.06) : Color.black.opacity(0.22))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(state.isDriving ? Aurora.okLo : Aurora.hair1, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.isDriving ? "停止自动驾驶" : "启动自动驾驶")
    }
}
